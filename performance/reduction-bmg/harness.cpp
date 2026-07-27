/*
 * Performance regression harness for sum_reduce on BMG (L0).
 *
 * Internal-facing: numbers from here go to performance/baseline.json for
 * ratchet comparison.  See performance/README.md.
 *
 * Unlike benchmarks/reduction/crisp/bench_harness_l0.cpp (which is
 * cross-platform-comparison shaped and accepts an occupancy CLI arg),
 * this harness:
 *   - hardcodes occupancy=2.0 (matches the :occupancy declaration in
 *     sum-reduce.crisp; the perf test must be repeatable, not tunable).
 *     :occupancy is a ratio against MAX RESIDENT WORKGROUPS for this kernel,
 *     so 2.0 means 2x oversubscribed — the measured optimum, not a typo.
 *   - hardcodes N=1000000 (single representative size — anything below
 *     this is dominated by launch overhead, anything above adds noise
 *     without isolating new codegen paths)
 *   - prints a compact JSON with only the fields check.py ratchets on
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
    fprintf(stderr, "Cannot find sum-reduce.spv\n");
    exit(1);
}

int main(int argc, char** argv) {
    int warmup     = argc > 1 ? atoi(argv[1]) : 50;
    int iterations = argc > 2 ? atoi(argv[2]) : 100;

    constexpr int N = 1000000;
    // Endeavor 143: was 0.15, to match a since-removed :occupancy declaration.  Measured
    // 2026-07-26 on BOTH vendors, that derate was a large pessimization -- BMG 3.3x slower
    // at 1M / 4.9x at 16M, H100 2.4x at 16M / 2.9x at 64M -- so the kernel now uses the 1.0
    // default and this mirrors it.  A later sweep with the 1.0 cap LIFTED found the true
    // optimum at R=2.0 (2x oversubscribed): BMG N=1M 11.54 us at 1.0 vs 8.84 at 2.0;
    // N=16M 307.0 vs 192.5.  Past 2x it degrades again (16x -> 22.98 us at 1M), so this
    // is a real interior optimum, not 'more is always better'.
    constexpr double OCCUPANCY = 2.0;   // matches :occupancy 2.0 in sum-reduce.crisp
    constexpr uint32_t BLOCK_SIZE = 256;

    // --- L0 init ---
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

    // --- Load SPV module ---
    auto spv = read_spv({
        "sum-reduce.spv",
        "performance/reduction-bmg/sum-reduce.spv",
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
    kDesc.pKernelName = "sum_reduce";
    ze_kernel_handle_t kernel;
    L0_CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    // --- Allocate input + result (USM shared) ---
    ze_device_mem_alloc_desc_t devMemDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };
    ze_host_mem_alloc_desc_t   hostMemDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };

    float* d_input = nullptr;
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              N * sizeof(float), sizeof(float), device, (void**)&d_input));
    for (int i = 0; i < N; i++) d_input[i] = 1.0f;

    float* d_result = nullptr;
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              sizeof(float), sizeof(float), device, (void**)&d_result));
    *d_result = 0.0f;

    // --- Kernel arg layout (15 total — see Crisp's 6-tuple-per-handle convention) ---
    // SLM (6): ptr, byte_size, off0, str0, ext0, length
    // input (6): same
    // result (3): ptr, byte_size, offset
    uint64_t slm_byte_size = BLOCK_SIZE * sizeof(float);
    uint64_t slm_off0      = 0;
    uint64_t slm_str0      = 1;
    uint64_t slm_ext0      = BLOCK_SIZE;
    uint64_t slm_length    = BLOCK_SIZE;

    uint64_t in_byte_size = (uint64_t)N * sizeof(float);
    uint64_t in_off0      = 0;
    uint64_t in_str0      = 1;
    uint64_t in_ext0      = (uint64_t)N;
    uint64_t in_length    = (uint64_t)N;

    uint64_t res_byte_size = sizeof(float);
    uint64_t res_offset    = 0;

    L0_CHECK(zeKernelSetArgumentValue(kernel,  0, (size_t)slm_byte_size, nullptr));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  1, sizeof(uint64_t), &slm_byte_size));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  2, sizeof(uint64_t), &slm_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  3, sizeof(uint64_t), &slm_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  4, sizeof(uint64_t), &slm_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  5, sizeof(uint64_t), &slm_length));

    L0_CHECK(zeKernelSetArgumentValue(kernel,  6, sizeof(void*),    &d_input));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  7, sizeof(uint64_t), &in_byte_size));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  8, sizeof(uint64_t), &in_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel,  9, sizeof(uint64_t), &in_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 10, sizeof(uint64_t), &in_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 11, sizeof(uint64_t), &in_length));

    L0_CHECK(zeKernelSetArgumentValue(kernel, 12, sizeof(void*),    &d_result));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 13, sizeof(uint64_t), &res_byte_size));
    L0_CHECK(zeKernelSetArgumentValue(kernel, 14, sizeof(uint64_t), &res_offset));

    L0_CHECK(zeKernelSetGroupSize(kernel, BLOCK_SIZE, 1, 1));

    // Endeavor 143: :occupancy is a fraction of the device's MAXIMUM RESIDENT WORKGROUPS for
    // this kernel -- the same denominator the L0 hoist and both CUDA paths use.  This harness
    // previously used `totalEUs` (one workgroup per EU), which ignores numThreadsPerEU and the
    // workgroup size entirely and came out 2x different on BMG (160 vs 80 at R=1.0).  One name,
    // one meaning.  Values ABOVE 1.0 are legal and deliberately so: they oversubscribe, which
    // measured faster in every case tested.
    uint32_t hwThreads       = devProps.numSlices * devProps.numSubslicesPerSlice
                             * devProps.numEUsPerSubslice * devProps.numThreadsPerEU;
    uint32_t simdW           = devProps.physicalEUSimdWidth ? devProps.physicalEUSimdWidth : 16;
    uint32_t threadsPerGroup = (BLOCK_SIZE + simdW - 1) / simdW;
    if (threadsPerGroup < 1) threadsPerGroup = 1;
    uint32_t maxResident     = std::max(1u, hwThreads / threadsPerGroup);
    uint32_t gridSize        = std::max(1u, (uint32_t)(maxResident * OCCUPANCY));
    fprintf(stderr, "Grid: %u groups (maxResident=%u x occ=%.2f), block=%u\n",
            gridSize, maxResident, (double)OCCUPANCY, BLOCK_SIZE);

    ze_group_count_t groupCount = { gridSize, 1, 1 };

    // --- Queue + event pool ---
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

    uint64_t timerRes    = devProps.timerResolution;
    uint64_t validBits   = devProps.kernelTimestampValidBits;
    uint64_t clockMask   = (validBits >= 64) ? ~0ULL : ((1ULL << validBits) - 1ULL);
    bool timerInHz = (timerRes > 1000000ULL);

    auto eventDurationNs = [&](const ze_kernel_timestamp_result_t& ts) -> double {
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
        *d_result = 0.0f;
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListWarmup, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
    };
    auto run_measured = [&]() {
        *d_result = 0.0f;
        L0_CHECK(zeEventHostReset(tsEvent));
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListMeasured, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
        L0_CHECK(zeEventHostSynchronize(tsEvent, UINT64_MAX));
    };

    // Smoke check
    run_warmup();
    if (std::fabs(*d_result - (float)N) > (float)N * 1e-2f) {
        fprintf(stderr, "Smoke FAILED: result=%.1f expected=%d\n", *d_result, N);
        return 1;
    }

    for (int i = 0; i < warmup; i++) run_warmup();

    std::vector<double> kernel_us(iterations);
    for (int i = 0; i < iterations; i++) {
        run_measured();
        ze_kernel_timestamp_result_t ts = {};
        L0_CHECK(zeEventQueryKernelTimestamp(tsEvent, &ts));
        kernel_us[i] = eventDurationNs(ts) / 1000.0;
    }

    float result = *d_result;
    bool correct = std::fabs(result - (float)N) < (float)N * 1e-3f;

    std::sort(kernel_us.begin(), kernel_us.end());
    double k_median = kernel_us[iterations / 2];
    double k_min    = kernel_us[0];
    double throughput_gb = ((double)N * sizeof(float) / 1e9) / (k_median / 1e6);

    printf("{\n");
    printf("  \"test\": \"reduction-bmg\",\n");
    printf("  \"N\": %d,\n", N);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": %s,\n", correct ? "true" : "false");
    printf("  \"kernel_median_us\": %.3f,\n", k_median);
    printf("  \"kernel_min_us\": %.3f,\n", k_min);
    printf("  \"throughput_gb_s\": %.3f\n", throughput_gb);
    printf("}\n");

    zeCommandListDestroy(cmdListMeasured);
    zeCommandListDestroy(cmdListWarmup);
    zeEventDestroy(tsEvent);
    zeEventPoolDestroy(eventPool);
    zeMemFree(ctx, d_input);
    zeMemFree(ctx, d_result);
    zeKernelDestroy(kernel);
    zeModuleDestroy(mod);
    zeCommandQueueDestroy(cmdQueue);
    zeContextDestroy(ctx);

    return correct ? 0 : 1;
}
