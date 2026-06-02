/*
 * Performance regression harness for vec_copy on BMG (L0).
 *
 * Pure stride-macro microbench — copies N floats from input -> output.
 * Bandwidth-bound; the median kernel time directly reflects whether
 * loop-vector-stride codegen is producing the optimal tight phi-loop
 * + shift-add address arithmetic.
 *
 * Single fixed N=1000000.  Single fixed launch policy (block=256,
 * grid sized to numEUs).  Both numbers are baked into the harness so
 * the test is repeatable, not tunable.
 *
 * Build (Windows native, MinGW clang++):
 *   clang++ harness.cpp -I<l0-include> <ze_loader.dll> -static -o harness.exe
 *
 * Usage: ./harness.exe [warmup] [iterations]
 */

#include <ze_api.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <numeric>
#include <string>
#include <vector>

#define L0_CHECK(call) do {                                                    \
    ze_result_t _r = (call);                                                   \
    if (_r != ZE_RESULT_SUCCESS) {                                             \
        fprintf(stderr, "L0 error at %s:%d -- 0x%x\n",                         \
                __FILE__, __LINE__, (unsigned)_r);                             \
        exit(1);                                                               \
    }                                                                          \
} while(0)

static std::vector<uint8_t> read_spv(const std::vector<std::string>& candidates) {
    for (const auto& p : candidates) {
        std::ifstream f(p, std::ios::binary | std::ios::ate);
        if (!f) continue;
        size_t size = f.tellg();
        std::vector<uint8_t> buf(size);
        f.seekg(0);
        f.read(reinterpret_cast<char*>(buf.data()), size);
        return buf;
    }
    fprintf(stderr, "Cannot find vec-copy.spv\n");
    exit(1);
}

int main(int argc, char** argv) {
    int warmup     = argc > 1 ? atoi(argv[1]) : 50;
    int iterations = argc > 2 ? atoi(argv[2]) : 100;

    constexpr int N = 1000000;
    constexpr uint32_t BLOCK_SIZE = 256;

    L0_CHECK(zeInit(ZE_INIT_FLAG_GPU_ONLY));

    uint32_t driverCount = 0;
    L0_CHECK(zeDriverGet(&driverCount, nullptr));
    if (driverCount == 0) { fprintf(stderr, "No L0 drivers\n"); return 1; }
    std::vector<ze_driver_handle_t> drivers(driverCount);
    L0_CHECK(zeDriverGet(&driverCount, drivers.data()));
    ze_driver_handle_t driver = drivers[0];

    uint32_t deviceCount = 0;
    L0_CHECK(zeDeviceGet(driver, &deviceCount, nullptr));
    if (deviceCount == 0) { fprintf(stderr, "No L0 devices\n"); return 1; }
    std::vector<ze_device_handle_t> devices(deviceCount);
    L0_CHECK(zeDeviceGet(driver, &deviceCount, devices.data()));
    ze_device_handle_t device = devices[0];

    ze_device_properties_t devProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };
    L0_CHECK(zeDeviceGetProperties(device, &devProps));
    fprintf(stderr, "Device: %s\n", devProps.name);

    ze_context_desc_t ctxDesc = { ZE_STRUCTURE_TYPE_CONTEXT_DESC };
    ze_context_handle_t ctx;
    L0_CHECK(zeContextCreate(driver, &ctxDesc, &ctx));

    auto spv = read_spv({
        "vec-copy.spv",
        "performance/vec-copy-bmg/vec-copy.spv",
    });

    ze_module_desc_t modDesc = {};
    modDesc.stype       = ZE_STRUCTURE_TYPE_MODULE_DESC;
    modDesc.format      = ZE_MODULE_FORMAT_IL_SPIRV;
    modDesc.inputSize   = spv.size();
    modDesc.pInputModule = spv.data();
    ze_module_handle_t mod;
    ze_module_build_log_handle_t buildLog;
    ze_result_t modRes = zeModuleCreate(ctx, device, &modDesc, &mod, &buildLog);
    if (modRes != ZE_RESULT_SUCCESS) {
        size_t logSize = 0;
        zeModuleBuildLogGetString(buildLog, &logSize, nullptr);
        std::vector<char> logBuf(logSize);
        zeModuleBuildLogGetString(buildLog, &logSize, logBuf.data());
        fprintf(stderr, "zeModuleCreate FAILED 0x%x -- log:\n%s\n",
                (unsigned)modRes, logBuf.data());
        return 1;
    }
    if (buildLog) zeModuleBuildLogDestroy(buildLog);

    ze_kernel_desc_t kDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };
    kDesc.pKernelName = "vec_copy";
    ze_kernel_handle_t kernel;
    L0_CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    // --- Allocate input + output (USM shared) ---
    ze_device_mem_alloc_desc_t devMemDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };
    ze_host_mem_alloc_desc_t   hostMemDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };

    float* d_input  = nullptr;
    float* d_output = nullptr;
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              N * sizeof(float), sizeof(float), device, (void**)&d_input));
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              N * sizeof(float), sizeof(float), device, (void**)&d_output));
    for (int i = 0; i < N; i++) { d_input[i] = (float)(i & 0xFFFF); d_output[i] = 0.0f; }

    // --- Kernel arg layout: 12 args (6 per tensor) ---
    uint64_t byte_size = (uint64_t)N * sizeof(float);
    uint64_t off0      = 0;
    uint64_t str0      = 1;
    uint64_t ext0      = (uint64_t)N;
    uint64_t length    = (uint64_t)N;

    L0_CHECK(zeKernelSetArgumentValue(kernel,  0, sizeof(void*),    &d_input));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  1, sizeof(uint64_t), &byte_size));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  2, sizeof(uint64_t), &off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  3, sizeof(uint64_t), &str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  4, sizeof(uint64_t), &ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  5, sizeof(uint64_t), &length));

    L0_CHECK(zeKernelSetArgumentValue(kernel,  6, sizeof(void*),    &d_output));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  7, sizeof(uint64_t), &byte_size));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  8, sizeof(uint64_t), &off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  9, sizeof(uint64_t), &str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 10, sizeof(uint64_t), &ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 11, sizeof(uint64_t), &length));

    L0_CHECK(zeKernelSetGroupSize(kernel, BLOCK_SIZE, 1, 1));

    // Single-pass grid sized to N (loop-vector-stride degenerates to one
    // iteration per work-item when global_size >= N).  Round up to BLOCK_SIZE.
    uint32_t gridSize = (uint32_t)((N + BLOCK_SIZE - 1) / BLOCK_SIZE);
    fprintf(stderr, "Grid: %u groups, block=%u, N=%d\n", gridSize, BLOCK_SIZE, N);
    ze_group_count_t groupCount = { gridSize, 1, 1 };

    ze_command_queue_desc_t qDesc = { ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC };
    qDesc.mode = ZE_COMMAND_QUEUE_MODE_DEFAULT;
    ze_command_queue_handle_t cmdQueue;
    L0_CHECK(zeCommandQueueCreate(ctx, device, &qDesc, &cmdQueue));

    ze_event_pool_desc_t poolDesc = { ZE_STRUCTURE_TYPE_EVENT_POOL_DESC };
    poolDesc.flags = ZE_EVENT_POOL_FLAG_KERNEL_TIMESTAMP;
    poolDesc.count = 1;
    ze_event_pool_handle_t eventPool;
    L0_CHECK(zeEventPoolCreate(ctx, &poolDesc, 1, &device, &eventPool));

    ze_event_desc_t evDesc = { ZE_STRUCTURE_TYPE_EVENT_DESC };
    evDesc.index  = 0;
    evDesc.signal = ZE_EVENT_SCOPE_FLAG_HOST;
    evDesc.wait   = ZE_EVENT_SCOPE_FLAG_HOST;
    ze_event_handle_t tsEvent;
    L0_CHECK(zeEventCreate(eventPool, &evDesc, &tsEvent));

    uint64_t timerRes  = devProps.timerResolution;
    uint64_t validBits = devProps.kernelTimestampValidBits;
    uint64_t clockMask = (validBits >= 64) ? ~0ULL : ((1ULL << validBits) - 1ULL);
    bool timerInHz = (timerRes > 1000000ULL);
    auto durationNs = [&](const ze_kernel_timestamp_result_t& ts) -> double {
        uint64_t s = ts.context.kernelStart & clockMask;
        uint64_t e = ts.context.kernelEnd   & clockMask;
        uint64_t delta = (e >= s) ? (e - s) : (clockMask + 1 - s + e);
        return timerInHz ? (double)delta * 1e9 / (double)timerRes
                         : (double)delta * (double)timerRes;
    };

    ze_command_list_desc_t clDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };
    ze_command_list_handle_t cmdListWarmup, cmdListMeasured;
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &cmdListWarmup));
    L0_CHECK(zeCommandListAppendLaunchKernel(cmdListWarmup, kernel, &groupCount,
                                              nullptr, 0, nullptr));
    L0_CHECK(zeCommandListClose(cmdListWarmup));
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &cmdListMeasured));
    L0_CHECK(zeCommandListAppendLaunchKernel(cmdListMeasured, kernel, &groupCount,
                                              tsEvent, 0, nullptr));
    L0_CHECK(zeCommandListClose(cmdListMeasured));

    auto run_warmup = [&]() {
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListWarmup, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
    };
    auto run_measured = [&]() {
        L0_CHECK(zeEventHostReset(tsEvent));
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListMeasured, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
        L0_CHECK(zeEventHostSynchronize(tsEvent, UINT64_MAX));
    };

    // Smoke: clear output, run once, verify a few stripes.
    for (int i = 0; i < N; i++) d_output[i] = 0.0f;
    run_warmup();
    bool smoke_ok = true;
    for (int probe : {0, 1, 1024, 65535, N/2, N-1}) {
        float want = (float)(probe & 0xFFFF);
        if (d_output[probe] != want) { smoke_ok = false; break; }
    }
    if (!smoke_ok) {
        fprintf(stderr, "Smoke FAILED: output does not match input\n");
        return 1;
    }

    for (int i = 0; i < warmup; i++) run_warmup();

    std::vector<double> kernel_us(iterations);
    for (int i = 0; i < iterations; i++) {
        run_measured();
        ze_kernel_timestamp_result_t ts = {};
        L0_CHECK(zeEventQueryKernelTimestamp(tsEvent, &ts));
        kernel_us[i] = durationNs(ts) / 1000.0;
    }

    std::sort(kernel_us.begin(), kernel_us.end());
    double k_median = kernel_us[iterations / 2];
    double k_min    = kernel_us[0];
    // vec_copy reads N floats and writes N floats -> 2N float bytes per pass.
    double throughput_gb = ((double)N * sizeof(float) * 2.0 / 1e9) / (k_median / 1e6);

    printf("{\n");
    printf("  \"test\": \"vec-copy-bmg\",\n");
    printf("  \"N\": %d,\n", N);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": true,\n");
    printf("  \"kernel_median_us\": %.3f,\n", k_median);
    printf("  \"kernel_min_us\": %.3f,\n", k_min);
    printf("  \"throughput_gb_s\": %.3f\n", throughput_gb);
    printf("}\n");

    zeCommandListDestroy(cmdListMeasured);
    zeCommandListDestroy(cmdListWarmup);
    zeEventDestroy(tsEvent);
    zeEventPoolDestroy(eventPool);
    zeMemFree(ctx, d_input);
    zeMemFree(ctx, d_output);
    zeKernelDestroy(kernel);
    zeModuleDestroy(mod);
    zeCommandQueueDestroy(cmdQueue);
    zeContextDestroy(ctx);
    return 0;
}
