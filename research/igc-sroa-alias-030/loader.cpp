/*
 * Level Zero host for the IGC SROA-aliasing bug reproducer.
 *
 * Loads bug.spv, launches kernel `bug` with one work-item, and prints
 * the 8 output bytes interpreted as two float32 values.
 *
 *   ./loader bug.spv
 *
 * Build:
 *   g++ -std=c++17 -O0 -o loader loader.cpp -I<level-zero>/include -lze_loader
 *
 * Expected output (per IR semantics, confirmed by NVPTX backend):
 *   out = {4.0, 3.0}
 *
 * Observed on Intel Arc B580, driver 32.0.101.8737 (Win11):
 *   out = {4.0, 4.0}
 */

#include <ze_api.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <cstdint>
#include <cstring>

#define CHECK(call) do {                                                       \
    ze_result_t _r = (call);                                                   \
    if (_r != ZE_RESULT_SUCCESS) {                                             \
        std::cerr << "FAIL: " #call " -> 0x" << std::hex << _r << std::endl;   \
        return 1;                                                              \
    }                                                                          \
} while (0)

static std::vector<uint8_t> read_file(const char* path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("cannot open SPV file");
    size_t n = f.tellg();
    std::vector<uint8_t> data(n);
    f.seekg(0);
    f.read(reinterpret_cast<char*>(data.data()), n);
    return data;
}

// Matches `%PT = type { float, i32 }` in bug.ll.  Total size 8 bytes,
// alignment 4 (LLVM default for {float, i32}).
struct PT {
    float x;
    int32_t y;
};

int main(int argc, char** argv) {
    const char* spv_path = (argc > 1) ? argv[1] : "bug.spv";

    auto spv = read_file(spv_path);
    std::cout << "Loaded " << spv_path << " (" << spv.size() << " bytes)\n";

    CHECK(zeInit(ZE_INIT_FLAG_GPU_ONLY));

    uint32_t n_drivers = 0;
    CHECK(zeDriverGet(&n_drivers, nullptr));
    if (n_drivers == 0) { std::cerr << "no L0 drivers\n"; return 1; }
    ze_driver_handle_t driver;
    n_drivers = 1;
    CHECK(zeDriverGet(&n_drivers, &driver));

    uint32_t n_devices = 0;
    CHECK(zeDeviceGet(driver, &n_devices, nullptr));
    if (n_devices == 0) { std::cerr << "no L0 devices\n"; return 1; }
    ze_device_handle_t device;
    n_devices = 1;
    CHECK(zeDeviceGet(driver, &n_devices, &device));

    ze_device_properties_t devProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };
    CHECK(zeDeviceGetProperties(device, &devProps));
    std::cout << "Device: " << devProps.name << "\n";

    ze_context_desc_t ctxDesc = { ZE_STRUCTURE_TYPE_CONTEXT_DESC };
    ze_context_handle_t ctx;
    CHECK(zeContextCreate(driver, &ctxDesc, &ctx));

    ze_module_desc_t modDesc = {
        ZE_STRUCTURE_TYPE_MODULE_DESC, nullptr,
        ZE_MODULE_FORMAT_IL_SPIRV,
        spv.size(), spv.data(),
        nullptr, nullptr
    };
    ze_module_handle_t mod;
    ze_module_build_log_handle_t buildLog = nullptr;
    ze_result_t br = zeModuleCreate(ctx, device, &modDesc, &mod, &buildLog);
    if (br != ZE_RESULT_SUCCESS) {
        std::cerr << "zeModuleCreate failed: 0x" << std::hex << br << "\n";
        if (buildLog) {
            size_t logSize = 0;
            zeModuleBuildLogGetString(buildLog, &logSize, nullptr);
            std::vector<char> logStr(logSize);
            zeModuleBuildLogGetString(buildLog, &logSize, logStr.data());
            std::cerr << "Build log:\n" << logStr.data() << "\n";
        }
        return 1;
    }

    ze_kernel_desc_t kDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };
    kDesc.pKernelName = "bug";
    ze_kernel_handle_t kernel;
    CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    // USM allocs for seed (4 bytes) and out (8 bytes)
    ze_device_mem_alloc_desc_t devMemDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };
    ze_host_mem_alloc_desc_t   hostMemDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };
    float* seed = nullptr;
    uint8_t* out = nullptr;
    CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc, sizeof(float), 4,
                            device, reinterpret_cast<void**>(&seed)));
    CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc, 8, 4,
                            device, reinterpret_cast<void**>(&out)));
    *seed = 1.0f;
    std::memset(out, 0, 8);

    // Kernel args: arg0 = PT by value, arg1 = seed_ptr, arg2 = out_ptr
    PT p = { 3.0f, 4 };
    CHECK(zeKernelSetArgumentValue(kernel, 0, sizeof(PT), &p));
    CHECK(zeKernelSetArgumentValue(kernel, 1, sizeof(void*), &seed));
    CHECK(zeKernelSetArgumentValue(kernel, 2, sizeof(void*), &out));

    CHECK(zeKernelSetGroupSize(kernel, 1, 1, 1));
    ze_group_count_t groupCount = { 1, 1, 1 };

    ze_command_list_desc_t clDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };
    ze_command_list_handle_t cl;
    CHECK(zeCommandListCreate(ctx, device, &clDesc, &cl));

    ze_command_queue_desc_t cqDesc = { ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC };
    ze_command_queue_handle_t cq;
    CHECK(zeCommandQueueCreate(ctx, device, &cqDesc, &cq));

    CHECK(zeCommandListAppendLaunchKernel(cl, kernel, &groupCount, nullptr, 0, nullptr));
    CHECK(zeCommandListClose(cl));
    CHECK(zeCommandQueueExecuteCommandLists(cq, 1, &cl, nullptr));
    CHECK(zeCommandQueueSynchronize(cq, UINT64_MAX));

    std::cout << "Raw bytes: ";
    for (int i = 0; i < 8; i++) {
        std::cout << std::hex << "0x" << static_cast<int>(out[i]) << " ";
    }
    std::cout << std::dec << "\n";

    float out0, out1;
    std::memcpy(&out0, out + 0, 4);
    std::memcpy(&out1, out + 4, 4);
    std::cout << "out[0] = " << out0 << "  (expected 4.0)\n";
    std::cout << "out[1] = " << out1 << "  (expected 3.0)\n";

    if (out0 == 4.0f && out1 == 3.0f) {
        std::cout << "PASS\n";
    } else {
        std::cout << "FAIL (bug reproduces)\n";
    }

    zeMemFree(ctx, seed);
    zeMemFree(ctx, out);
    zeKernelDestroy(kernel);
    zeModuleDestroy(mod);
    zeCommandListDestroy(cl);
    zeCommandQueueDestroy(cq);
    zeContextDestroy(ctx);
    return 0;
}
