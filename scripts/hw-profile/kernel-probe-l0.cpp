// Endeavor 144 Phase 0 — Level Zero KERNEL property probe.
//
// Loads a .spv and dumps ze_kernel_properties_t for each kernel: register spill,
// private memory, SLM, and the subgroup/workgroup requirements.  Written to test one
// specific inference: the L0 hoist derates occupancy 2x when spillMemSize > 0
// (hoist-l0/main.lisp:561-562), and 143 recorded _hw_threads=640 on a B580 whose
// undreated formula gives 5*4*8*8 = 1280.  640 == 1280/2, which would mean the
// intel_prefetch benchmark kernel SPILLS.  This confirms or refutes that.
//
// Build:
//   clang++ kernel-probe.cpp -I C:/Users/cperk/Documents/level-zero/include \
//           C:/Windows/System32/ze_loader.dll -static -o kernel-probe.exe
// Run:
//   kernel-probe.exe <file.spv> [more.spv ...]

#include <ze_api.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

#define CHECK(x) do { ze_result_t _r = (x); if (_r != ZE_RESULT_SUCCESS) { \
    std::printf("FAIL %s -> 0x%x\n", #x, (unsigned)_r); return 1; } } while (0)

static std::vector<uint8_t> read_file(const char* path) {
    std::vector<uint8_t> data;
    FILE* f = std::fopen(path, "rb");
    if (!f) return data;
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    data.resize((size_t)n);
    if (std::fread(data.data(), 1, (size_t)n, f) != (size_t)n) data.clear();
    std::fclose(f);
    return data;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: kernel-probe <file.spv> [...]\n"); return 2; }

    CHECK(zeInit(0));

    uint32_t driverCount = 1;
    ze_driver_handle_t driver{};
    CHECK(zeDriverGet(&driverCount, &driver));

    // first GPU device
    uint32_t devCount = 0;
    CHECK(zeDeviceGet(driver, &devCount, nullptr));
    std::vector<ze_device_handle_t> devs(devCount);
    CHECK(zeDeviceGet(driver, &devCount, devs.data()));
    ze_device_handle_t dev = nullptr;
    for (uint32_t i = 0; i < devCount; ++i) {
        ze_device_properties_t p = {};
        p.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES;
        if (zeDeviceGetProperties(devs[i], &p) == ZE_RESULT_SUCCESS
            && p.type == ZE_DEVICE_TYPE_GPU) { dev = devs[i]; break; }
    }
    if (!dev) { std::printf("FAIL no GPU device\n"); return 1; }

    ze_context_desc_t ctxDesc = {};
    ctxDesc.stype = ZE_STRUCTURE_TYPE_CONTEXT_DESC;
    ze_context_handle_t ctx{};
    CHECK(zeContextCreate(driver, &ctxDesc, &ctx));

    for (int a = 1; a < argc; ++a) {
        std::vector<uint8_t> spv = read_file(argv[a]);
        std::printf("=====================================================\n");
        std::printf("%s  (%zu bytes)\n", argv[a], spv.size());
        std::printf("=====================================================\n");
        if (spv.empty()) { std::printf("  FAIL could not read\n"); continue; }

        // Endeavor 144 Phase 4 experiment: build the SAME .spv under each IGC register-file
        // mode and compare spillMemSize.  `-ze-opt-large-register-file` asks IGC for the
        // 256-GRF-per-thread allocation instead of the default 128.
        static const char* kFlagSets[] = { "", "-ze-opt-large-register-file" };
        for (const char* flags : kFlagSets) {
        std::printf("  ---- build flags: %s ----\n", flags[0] ? flags : "(default, 128 GRF)");

        ze_module_desc_t modDesc = {};
        modDesc.stype        = ZE_STRUCTURE_TYPE_MODULE_DESC;
        modDesc.format       = ZE_MODULE_FORMAT_IL_SPIRV;
        modDesc.inputSize    = spv.size();
        modDesc.pInputModule = spv.data();
        modDesc.pBuildFlags  = flags;

        ze_module_handle_t mod{};
        ze_module_build_log_handle_t buildLog{};
        ze_result_t br = zeModuleCreate(ctx, dev, &modDesc, &mod, &buildLog);
        if (br != ZE_RESULT_SUCCESS) {
            std::printf("  zeModuleCreate FAILED 0x%x\n", (unsigned)br);
            size_t logSize = 0;
            if (zeModuleBuildLogGetString(buildLog, &logSize, nullptr) == ZE_RESULT_SUCCESS
                && logSize > 1) {
                std::string log(logSize, '\0');
                zeModuleBuildLogGetString(buildLog, &logSize, log.data());
                std::printf("  build log: %s\n", log.c_str());
            }
            if (buildLog) zeModuleBuildLogDestroy(buildLog);
            continue;
        }
        if (buildLog) zeModuleBuildLogDestroy(buildLog);

        uint32_t nNames = 0;
        CHECK(zeModuleGetKernelNames(mod, &nNames, nullptr));
        std::vector<const char*> names(nNames);
        CHECK(zeModuleGetKernelNames(mod, &nNames, names.data()));

        for (uint32_t k = 0; k < nNames; ++k) {
            ze_kernel_desc_t kd = {};
            kd.stype = ZE_STRUCTURE_TYPE_KERNEL_DESC;
            kd.pKernelName = names[k];
            ze_kernel_handle_t kern{};
            if (zeKernelCreate(mod, &kd, &kern) != ZE_RESULT_SUCCESS) {
                std::printf("  kernel '%s': create FAILED\n", names[k]);
                continue;
            }

            ze_kernel_properties_t kp = {};
            kp.stype = ZE_STRUCTURE_TYPE_KERNEL_PROPERTIES;
            if (zeKernelGetProperties(kern, &kp) == ZE_RESULT_SUCCESS) {
                std::printf("  kernel '%s'\n", names[k]);
                std::printf("    numKernelArgs         %u\n", kp.numKernelArgs);
                std::printf("    requiredGroupSize     %u %u %u\n",
                            kp.requiredGroupSizeX, kp.requiredGroupSizeY, kp.requiredGroupSizeZ);
                std::printf("    requiredSubgroupSize  %u\n", kp.requiredSubgroupSize);
                std::printf("    requiredNumSubGroups  %u\n", kp.requiredNumSubGroups);
                std::printf("    maxSubgroupSize       %u\n", kp.maxSubgroupSize);
                std::printf("    maxNumSubgroups       %u\n", kp.maxNumSubgroups);
                std::printf("    localMemSize          %u bytes  (SLM)\n", kp.localMemSize);
                std::printf("    privateMemSize        %u bytes  (per-thread private)\n",
                            kp.privateMemSize);
                std::printf("    spillMemSize          %u bytes  <<< REGISTER SPILL\n",
                            kp.spillMemSize);
                std::printf("    ==> hoist 2x occupancy derate would %s\n",
                            kp.spillMemSize > 0 ? "FIRE (kernel spills)" : "NOT fire (no spill)");
            }
            zeKernelDestroy(kern);
        }
        zeModuleDestroy(mod);
        }   // end flag-set loop
        std::printf("\n");
    }

    zeContextDestroy(ctx);
    return 0;
}
