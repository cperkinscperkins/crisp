/*
 * Performance regression harness for the Chapter-0 synchronous SLM-staged matmul
 * on BMG (L0).  Endeavor 134 bookend.
 *
 * Internal-facing: numbers go to performance/baseline.json for ratchet
 * comparison.  See performance/README.md.
 *
 * Kernel: C[8x16] = A[8xK] . B[Kx16], tf32, single sub-group / one 8x16 XMX tile,
 * but LARGE K (hardcoded below).  The runtime is dominated by the K-loop's
 * SYNCHRONOUS staging (sync load-tile-coords + sync-workgroup per K-step) — the
 * exact thing the three MMA "chapters" (async / pipelined / warp-specialized)
 * optimize.  So kernel_median_us here is the "Chapter 0" floor they improve on.
 *
 * Inputs A = B = 1.0, so every C[i][j] == K exactly (a hard correctness gate,
 * not eyeballing).
 *
 * Build (Windows native, MinGW clang++):
 *   clang++ harness.cpp -I<l0-include> <ze_loader.dll> -static -o harness.exe
 *
 * Usage: ./harness.exe [warmup] [iterations]
 */

#include <ze_api.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <fstream>
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
    fprintf(stderr, "Cannot find matmul.spv\n");
    exit(1);
}

int main(int argc, char** argv) {
    int warmup     = argc > 1 ? atoi(argv[1]) : 50;
    int iterations = argc > 2 ? atoi(argv[2]) : 100;

    // Fixed problem: 8x16 output tile, large contraction.  K must be a multiple
    // of 8 (the XMX K-step).  Big enough that the K-loop staging dominates over
    // launch overhead, small enough that a single sub-group stays representative.
    constexpr int M = 8, Nn = 16, K = 2048;
    constexpr uint32_t SUBGROUP = 16;         // local-size in matmul.crisp

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
        "matmul.spv",
        "performance/matmul-bmg/matmul.spv",
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
    kDesc.pKernelName = "matmul";
    ze_kernel_handle_t kernel;
    L0_CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    // --- Allocate A[MxK], B[KxN], C[MxN] (USM shared) ---
    ze_device_mem_alloc_desc_t devMemDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };
    ze_host_mem_alloc_desc_t   hostMemDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };

    float* d_a = nullptr; float* d_b = nullptr; float* d_c = nullptr;
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              (size_t)M * K * sizeof(float), sizeof(float), device, (void**)&d_a));
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              (size_t)K * Nn * sizeof(float), sizeof(float), device, (void**)&d_b));
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc,
                              (size_t)M * Nn * sizeof(float), sizeof(float), device, (void**)&d_c));
    for (int i = 0; i < M * K;  i++) d_a[i] = 1.0f;
    for (int i = 0; i < K * Nn; i++) d_b[i] = 1.0f;
    for (int i = 0; i < M * Nn; i++) d_c[i] = 0.0f;

    // --- Kernel arg layout (45 args; matches the hoist's metacrisp order:
    //     b-tile[0..8], a-tile[9..17], A[18..26], B[27..35], C[36..44]).
    //     Each 2-D tile/tensor = ptr, byte_size, off0, off1, str0, str1,
    //     ext0, ext1, length.  SLM tiles pass ptr as a local-mem size+nullptr. ---
    // SLM b-tile: 8x16
    uint64_t bt_bytes = 8 * 16 * sizeof(float);
    uint64_t bt_off0 = 0, bt_off1 = 0, bt_str0 = 16, bt_str1 = 1, bt_ext0 = 8, bt_ext1 = 16, bt_len = 128;
    // SLM a-tile: 8x8
    uint64_t at_bytes = 8 * 8 * sizeof(float);
    uint64_t at_off0 = 0, at_off1 = 0, at_str0 = 8, at_str1 = 1, at_ext0 = 8, at_ext1 = 8, at_len = 64;
    // A[MxK] row-major
    uint64_t a_bytes = (uint64_t)M * K * sizeof(float);
    uint64_t a_off0 = 0, a_off1 = 0, a_str0 = K, a_str1 = 1, a_ext0 = M, a_ext1 = K, a_len = (uint64_t)M * K;
    // B[KxN] row-major
    uint64_t b_bytes = (uint64_t)K * Nn * sizeof(float);
    uint64_t b_off0 = 0, b_off1 = 0, b_str0 = Nn, b_str1 = 1, b_ext0 = K, b_ext1 = Nn, b_len = (uint64_t)K * Nn;
    // C[MxN] row-major
    uint64_t c_bytes = (uint64_t)M * Nn * sizeof(float);
    uint64_t c_off0 = 0, c_off1 = 0, c_str0 = Nn, c_str1 = 1, c_ext0 = M, c_ext1 = Nn, c_len = (uint64_t)M * Nn;

    int ai = 0;
    // b-tile (SLM)
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, (size_t)bt_bytes, nullptr));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_bytes));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_off1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_str1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_ext1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &bt_len));
    // a-tile (SLM)
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, (size_t)at_bytes, nullptr));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_bytes));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_off1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_str1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_ext1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &at_len));
    // A
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(void*),    &d_a));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_bytes));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_off1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_str1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_ext1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &a_len));
    // B
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(void*),    &d_b));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_bytes));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_off1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_str1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_ext1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &b_len));
    // C
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(void*),    &d_c));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_bytes));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_off0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_off1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_str0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_str1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_ext0));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_ext1));
    L0_CHECK(zeKernelSetArgumentValue(kernel, ai++, sizeof(uint64_t), &c_len));

    L0_CHECK(zeKernelSetGroupSize(kernel, SUBGROUP, 1, 1));
    ze_group_count_t groupCount = { 1, 1, 1 };   // single workgroup / one output tile

    // --- Queue + timestamp event ---
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
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListWarmup, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
    };
    auto run_measured = [&]() {
        L0_CHECK(zeEventHostReset(tsEvent));
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdListMeasured, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
        L0_CHECK(zeEventHostSynchronize(tsEvent, UINT64_MAX));
    };

    // Smoke check: A=B=1 => every C == K
    run_warmup();
    {
        bool ok = true;
        for (int i = 0; i < M * Nn; i++)
            if (std::fabs(d_c[i] - (float)K) > (float)K * 1e-2f) { ok = false; break; }
        if (!ok) {
            fprintf(stderr, "Smoke FAILED: C[0]=%.1f expected=%d\n", d_c[0], K);
            return 1;
        }
    }

    for (int i = 0; i < warmup; i++) run_warmup();

    std::vector<double> kernel_us(iterations);
    for (int i = 0; i < iterations; i++) {
        run_measured();
        ze_kernel_timestamp_result_t ts = {};
        L0_CHECK(zeEventQueryKernelTimestamp(tsEvent, &ts));
        kernel_us[i] = eventDurationNs(ts) / 1000.0;
    }

    bool correct = true;
    for (int i = 0; i < M * Nn; i++)
        if (std::fabs(d_c[i] - (float)K) > (float)K * 1e-3f) { correct = false; break; }

    std::sort(kernel_us.begin(), kernel_us.end());
    double k_median = kernel_us[iterations / 2];
    double k_min    = kernel_us[0];
    // 2*M*N*K flops (tiny — this is a staging microbench, not a peak-GFLOPS run).
    double gflops = (2.0 * M * Nn * K) / (k_median / 1e6) / 1e9;

    printf("{\n");
    printf("  \"test\": \"matmul-bmg\",\n");
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, Nn, K);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": %s,\n", correct ? "true" : "false");
    printf("  \"kernel_median_us\": %.3f,\n", k_median);
    printf("  \"kernel_min_us\": %.3f,\n", k_min);
    printf("  \"gflops\": %.4f\n", gflops);
    printf("}\n");

    zeCommandListDestroy(cmdListMeasured);
    zeCommandListDestroy(cmdListWarmup);
    zeEventDestroy(tsEvent);
    zeEventPoolDestroy(eventPool);
    zeMemFree(ctx, d_a);
    zeMemFree(ctx, d_b);
    zeMemFree(ctx, d_c);
    zeKernelDestroy(kernel);
    zeModuleDestroy(mod);
    zeCommandQueueDestroy(cmdQueue);
    zeContextDestroy(ctx);

    return correct ? 0 : 1;
}
