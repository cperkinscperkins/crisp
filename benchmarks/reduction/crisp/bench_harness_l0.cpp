/*
 * Benchmark harness for Crisp-compiled SPV sum reduction (Intel L0 path).
 *
 * Mirrors crisp/bench_harness.cu (the CUDA Driver-API harness for PTX) in
 * structure and output, so the same comparison tooling absorbs both.
 *
 * Loads sum-reduce.spv and launches the sum_reduce kernel via L0.
 * Uses zeEventQueryKernelTimestamp for GPU-side kernel timing and
 * std::chrono for wall-time.  Output is JSON to stdout — same schema as
 * the CUDA / SYCL harnesses.
 *
 * Usage: ./sum_reduce_crisp_l0 [N] [warmup] [iterations] [occupancy]
 *   occupancy = 0.0..1.0 ratio for grid sizing (default: 1.0 = max).
 *               Mirrors what the Crisp L0 hoist would emit for
 *               (global-size :derive-from input :strategy :strided :occupancy R).
 *
 * Compile (inside Docker container with oneAPI + L0):
 *   icpx -O3 bench_harness_l0.cpp -lze_loader -o sum_reduce_crisp_l0
 *
 * ============================================================================
 * KNOWN ISSUE (2026-05-30, open):
 *
 *   Kernel launches return ZE_RESULT_ERROR_DEVICE_LOST (0x70000001) on BMG
 *   via WSL2 L0 passthrough.  The SPV module loads cleanly (zeModuleCreate
 *   succeeds — IGC accepts the IR), zeKernelCreate succeeds, all argument
 *   sets return ZE_RESULT_SUCCESS, but the first kernel launch hangs and
 *   the driver resets the device.
 *
 *   The Crisp SPV signature for sum_reduce is:
 *     %0  ptr addrspace(3)  -- SLM (scratch vector pointer)
 *     %1..%5  i64           -- SLM 5-tuple (byte_size, off0, str0, ext0, length)
 *     %6  ptr addrspace(1)  -- input
 *     %7..%11  i64          -- input 5-tuple
 *     %12 ptr addrspace(1)  -- result
 *     %13..%14 i64          -- result 2-tuple
 *
 *   Candidate causes worth investigating:
 *     - SLM arg convention: passing `(nullptr, sizeBytes)` to
 *       zeKernelSetArgumentValue is the documented way to bind SLM, but
 *       Intel's L0 driver may want SLM size declared differently when the
 *       compiled kernel already declares its SLM use internally (the
 *       endeavor 115 demote+restore pass for PTX may have a SPV analogue
 *       we're not handling).
 *     - readonly attribute on the SLM pointer: opt -O3 marks %0 as
 *       readonly, which is wrong (the kernel writes to SLM during Phase 2
 *       tree-reduce).  If IGC honours readonly literally, the write becomes
 *       UB and the device hangs.  Fix: either disable opt -O3's
 *       per-param readonly inference, or run without opt for SPV path.
 *     - L0 argument-set convention differs from CUDA: the existing spec
 *       runner (endeavor 112) sets args via a different path that we
 *       haven't mirrored here.  Compare scripts/l0-smoke.lisp.
 *
 *   Next step: reproduce with the SYCL DPC++ path (Phase B) — if SYCL on
 *   BMG works for a hand-written reduction, we have a working baseline to
 *   diff against.  Then come back to this harness with that knowledge.
 * ============================================================================
 */

#include <level_zero/ze_api.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <numeric>
#include <string>
#include <vector>

#define L0_CHECK(call) do {                                                    \
    ze_result_t _r = (call);                                                   \
    if (_r != ZE_RESULT_SUCCESS) {                                             \
        fprintf(stderr, "L0 error at %s:%d — 0x%x\n",                          \
                __FILE__, __LINE__, (unsigned)_r);                             \
        exit(1);                                                               \
    }                                                                          \
} while(0)

static std::vector<uint8_t> read_spv_file(const std::vector<std::string>& candidates) {
    for (const auto& path : candidates) {
        std::ifstream f(path, std::ios::binary | std::ios::ate);
        if (!f) continue;
        size_t size = f.tellg();
        std::vector<uint8_t> buf(size);
        f.seekg(0);
        f.read(reinterpret_cast<char*>(buf.data()), size);
        fprintf(stderr, "Loaded SPV: %s (%zu bytes)\n", path.c_str(), size);
        return buf;
    }
    fprintf(stderr, "Cannot find sum-reduce.spv in any candidate location\n");
    exit(1);
}

int main(int argc, char** argv) {
    int    N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int    warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int    iterations = argc > 3 ? atoi(argv[3]) : 100;
    double occupancy  = argc > 4 ? atof(argv[4]) : 1.0;
    if (occupancy <= 0.0 || occupancy > 1.0) {
        fprintf(stderr, "occupancy must be in (0.0, 1.0], got %f\n", occupancy);
        return 1;
    }

    // ------------------------------------------------------------------
    // L0 init
    // ------------------------------------------------------------------
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
    ze_device_compute_properties_t compProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };
    L0_CHECK(zeDeviceGetComputeProperties(device, &compProps));
    fprintf(stderr, "Device: %s  numEUs=%u  numSlices=%u  numSubslicesPerSlice=%u  numEUsPerSubslice=%u\n",
            devProps.name, devProps.numEUsPerSubslice * devProps.numSubslicesPerSlice * devProps.numSlices,
            devProps.numSlices, devProps.numSubslicesPerSlice, devProps.numEUsPerSubslice);

    ze_context_desc_t ctxDesc = { ZE_STRUCTURE_TYPE_CONTEXT_DESC };
    ze_context_handle_t ctx;
    L0_CHECK(zeContextCreate(driver, &ctxDesc, &ctx));

    // ------------------------------------------------------------------
    // Load SPV module + kernel
    // ------------------------------------------------------------------
    auto spv = read_spv_file({
        "sum-reduce.spv",
        "benchmarks/reduction/crisp/sum-reduce.spv",
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
        fprintf(stderr, "zeModuleCreate FAILED 0x%x — build log:\n%s\n", (unsigned)modRes, logBuf.data());
        return 1;
    }
    if (buildLog) zeModuleBuildLogDestroy(buildLog);

    ze_kernel_desc_t kDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };
    kDesc.pKernelName = "sum_reduce";
    ze_kernel_handle_t kernel;
    L0_CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    // ------------------------------------------------------------------
    // Allocate USM input + result
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Set kernel args (15 total — mirrors PTX harness layout)
    //   scratch slm (6): ptr, byte_size, off0, str0, ext0, length
    //   input     (6):   ptr, byte_size, off0, str0, ext0, length
    //   result    (3):   ptr, byte_size, offset
    // ------------------------------------------------------------------
    const uint32_t blockSize = 256;

    uint64_t slm_ptr       = 0;
    uint64_t slm_byte_size = blockSize * sizeof(float);
    uint64_t slm_off0      = 0;
    uint64_t slm_str0      = 1;
    uint64_t slm_ext0      = blockSize;
    uint64_t slm_length    = blockSize;

    uint64_t in_byte_size = (uint64_t)N * sizeof(float);
    uint64_t in_off0      = 0;
    uint64_t in_str0      = 1;
    uint64_t in_ext0      = (uint64_t)N;
    uint64_t in_length    = (uint64_t)N;

    uint64_t res_byte_size = sizeof(float);
    uint64_t res_offset    = 0;

    // SLM (arg 0) is a `ptr addrspace(3)` in the kernel — L0 convention:
    // pass nullptr as pValue with the size set to the SLM byte count,
    // and the runtime allocates that much workgroup-local memory.
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

    // ------------------------------------------------------------------
    // Set group size + compute group count
    //
    // Occupancy mirror: Crisp's L0 hoist for :strategy :strided :occupancy R
    // sizes the grid via device EU count × an estimated workgroups-per-EU
    // headroom, scaled by R.  Same shape as the CUDA path's
    // cuOccupancyMaxActiveBlocksPerMultiprocessor() × R.
    // ------------------------------------------------------------------
    L0_CHECK(zeKernelSetGroupSize(kernel, blockSize, 1, 1));

    uint32_t totalEUs = devProps.numSlices * devProps.numSubslicesPerSlice * devProps.numEUsPerSubslice;
    // Conservative heuristic for reduction with SLM: 1 workgroup per EU is
    // already 4-8x oversubscribed (each EU runs 4-8 hardware threads).
    // Scale by occupancy.  Tighter than CUDA's "blocks per SM ~32" because
    // BMG has fewer SMs than NVIDIA's count.
    uint32_t baseGroups = std::max(1u, totalEUs);
    uint32_t gridSize   = std::max(1u, (uint32_t)(baseGroups * occupancy));
    fprintf(stderr, "Grid: %u groups (totalEUs=%u × 8 × occupancy=%.2f), block=%u\n",
            gridSize, totalEUs, occupancy, blockSize);

    ze_group_count_t groupCount = { gridSize, 1, 1 };

    // ------------------------------------------------------------------
    // Command list + queue + event pool for kernel-time measurement
    // ------------------------------------------------------------------
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
    ze_event_handle_t timestampEvent;
    L0_CHECK(zeEventCreate(eventPool, &evDesc, &timestampEvent));

    // Timestamp resolution (kernel events return device clocks; convert via this).
    uint64_t timerResNs   = devProps.timerResolution;          // device clock period in ns (on newer drivers; legacy returns Hz)
    uint64_t kernelClockBits = devProps.kernelTimestampValidBits;
    uint64_t kernelClockMask = (kernelClockBits >= 64) ? ~0ULL : ((1ULL << kernelClockBits) - 1ULL);
    // Newer Intel L0 drivers report timerResolution as ns directly; older
    // ones report it as Hz.  Detect by magnitude — anything > 1e6 is Hz.
    bool timerInHz = (timerResNs > 1000000ULL);
    if (timerInHz) {
        fprintf(stderr, "timerResolution reported as %lu Hz\n", (unsigned long)timerResNs);
    } else {
        fprintf(stderr, "timerResolution reported as %lu ns/tick\n", (unsigned long)timerResNs);
    }

    auto eventDurationNs = [&](const ze_kernel_timestamp_result_t& ts) -> double {
        uint64_t startTick = ts.context.kernelStart & kernelClockMask;
        uint64_t endTick   = ts.context.kernelEnd   & kernelClockMask;
        uint64_t delta     = (endTick >= startTick)
                             ? (endTick - startTick)
                             : (kernelClockMask + 1 - startTick + endTick);
        if (timerInHz) {
            return (double)delta * 1e9 / (double)timerResNs;
        } else {
            return (double)delta * (double)timerResNs;
        }
    };

    // Single reusable command list (don't recreate per iter — that hides
    // queue/event semantics).  For warmup we use it directly; for measured
    // iters the caller arranges its own sync.
    ze_command_list_desc_t clDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };
    ze_command_list_handle_t cmdListWarmup;
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &cmdListWarmup));
    L0_CHECK(zeCommandListAppendLaunchKernel(cmdListWarmup, kernel, &groupCount,
                                              nullptr, 0, nullptr));
    L0_CHECK(zeCommandListClose(cmdListWarmup));

    ze_command_list_handle_t cmdListMeasured;
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &cmdListMeasured));
    L0_CHECK(zeCommandListAppendLaunchKernel(cmdListMeasured, kernel, &groupCount,
                                              timestampEvent, 0, nullptr));
    L0_CHECK(zeCommandListClose(cmdListMeasured));

    auto run_warmup = [&]() {
        *d_result = 0.0f;
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListWarmup, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
    };

    auto run_measured = [&]() {
        *d_result = 0.0f;
        L0_CHECK(zeEventHostReset(timestampEvent));
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListMeasured, nullptr));
        // Belt-and-suspenders: queue sync first (kernel definitely done),
        // then event sync (signal definitely propagated host-side, timestamp
        // table populated).  Either alone has been observed to return
        // NOT_READY on Intel WSL2 builds.
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
        L0_CHECK(zeEventHostSynchronize(timestampEvent, UINT64_MAX));
    };

    // ------------------------------------------------------------------
    // Smoke test: confirm kernel produces correct result before measuring
    // ------------------------------------------------------------------
    run_warmup();
    {
        float smoke = *d_result;
        fprintf(stderr, "Smoke: result=%.1f expected=%.1f (delta=%.3f%%)\n",
                smoke, (float)N, 100.0 * (smoke - (float)N) / (float)N);
        if (std::fabs(smoke - (float)N) > (float)N * 1e-2f) {
            fprintf(stderr, "Smoke check FAILED — kernel result is wrong; bailing out\n");
            return 1;
        }
    }

    // ------------------------------------------------------------------
    // Warmup
    // ------------------------------------------------------------------
    for (int i = 0; i < warmup; i++) run_warmup();

    // ------------------------------------------------------------------
    // Measured runs
    // ------------------------------------------------------------------
    std::vector<double> kernel_times_us(iterations);
    std::vector<double> wall_times_us(iterations);

    for (int i = 0; i < iterations; i++) {
        auto wall_start = std::chrono::high_resolution_clock::now();
        run_measured();

        ze_kernel_timestamp_result_t ts = {};
        L0_CHECK(zeEventQueryKernelTimestamp(timestampEvent, &ts));
        double kernelNs = eventDurationNs(ts);

        auto wall_end = std::chrono::high_resolution_clock::now();

        kernel_times_us[i] = kernelNs / 1000.0;
        wall_times_us[i]   = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
    }

    float result = *d_result;
    float expected = (float)N;
    bool correct = std::fabs(result - expected) < expected * 1e-3f;

    // ------------------------------------------------------------------
    // Stats + JSON output (same schema as bench_harness.cu)
    // ------------------------------------------------------------------
    std::sort(kernel_times_us.begin(), kernel_times_us.end());
    double k_median = kernel_times_us[iterations / 2];
    double k_min    = kernel_times_us[0];
    double k_sum    = std::accumulate(kernel_times_us.begin(), kernel_times_us.end(), 0.0);
    double k_mean   = k_sum / iterations;
    double k_var    = 0.0;
    for (double t : kernel_times_us) k_var += (t - k_mean) * (t - k_mean);
    double k_stddev = std::sqrt(k_var / iterations);
    double throughput_gb = ((double)N * sizeof(float) / 1e9) / (k_median / 1e6);

    std::sort(wall_times_us.begin(), wall_times_us.end());
    double w_median = wall_times_us[iterations / 2];
    double w_min    = wall_times_us[0];

    printf("{\n");
    printf("  \"algorithm\": \"reduction\",\n");
    printf("  \"implementation\": \"crisp\",\n");
    printf("  \"backend\": \"l0\",\n");
    printf("  \"N\": %d,\n", N);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": %s,\n", correct ? "true" : "false");
    printf("  \"result\": %.1f,\n", result);
    printf("  \"expected\": %.1f,\n", expected);
    printf("  \"kernel_median_us\": %.2f,\n", k_median);
    printf("  \"kernel_min_us\": %.2f,\n", k_min);
    printf("  \"kernel_mean_us\": %.2f,\n", k_mean);
    printf("  \"kernel_stddev_us\": %.2f,\n", k_stddev);
    printf("  \"throughput_gb_s\": %.2f,\n", throughput_gb);
    printf("  \"wall_median_us\": %.2f,\n", w_median);
    printf("  \"wall_min_us\": %.2f\n", w_min);
    printf("}\n");

    // ------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------
    zeCommandListDestroy(cmdListMeasured);
    zeCommandListDestroy(cmdListWarmup);
    zeEventDestroy(timestampEvent);
    zeEventPoolDestroy(eventPool);
    zeMemFree(ctx, d_input);
    zeMemFree(ctx, d_result);
    zeKernelDestroy(kernel);
    zeModuleDestroy(mod);
    zeCommandQueueDestroy(cmdQueue);
    zeContextDestroy(ctx);

    return correct ? 0 : 1;
}
