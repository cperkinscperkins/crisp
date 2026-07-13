/*
 * Level-Zero benchmark harness for the Crisp BMG matmul (matmul_bmg.crisp):
 * C[N x N] = A . B (square), tf32, via the matrix-multiply-tile-stride macro.
 * The Intel analog of ./bench_harness.cu (CUDA driver API) — loads matmul_bmg.spv,
 * launches a 2-D grid of (N/64, N/64) sub-groups (one 64x64 output tile each), times
 * with ze kernel-timestamp events, gates correctness on A=B=1 => every C == K, and
 * prints a JSON line the Intel driver parses.
 *
 * Square problem so it matches the driver's [size warmup iters] call shape.
 *
 * Build:  icpx -O3 bench_harness_l0.cpp -lze_loader -o matmul_crisp_l0
 *   (native: clang++ bench_harness_l0.cpp -I<l0-include> <ze_loader> -o ...)
 * Run:    ./matmul_crisp_l0 [size] [warmup] [iters]
 */
// Docker/Linux installs the L0 headers under level_zero/ (on the system include path);
// the native Windows build points -I directly at the include dir (ze_api.h at the root).
#if __has_include(<level_zero/ze_api.h>)
#include <level_zero/ze_api.h>
#else
#include <ze_api.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
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
} while (0)

// Tile geometry — must match matmul_bmg.crisp.
static constexpr int TM = 32;   // C register tile rows  (A-tile rows)
static constexpr int TN = 32;   // C register tile cols  (B-tile cols)
static constexpr int KS = 8;    // k-step (A-tile cols / B-tile rows)
static constexpr uint32_t SUBGROUP = 16;

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
    fprintf(stderr, "Cannot find matmul_bmg.spv\n");
    exit(1);
}

// Set the 9 kernel args for one 2-D tensor/tile: ptr, byte_size, off0, off1,
// str0, str1, ext0, ext1, length.  A global tensor passes a real pointer; an SLM
// scratch tile passes (byte_size, nullptr) in the pointer slot instead.
static void set_tensor_args(ze_kernel_handle_t k, int& ai, bool slm, void** ptr,
                            uint64_t bytes, uint64_t s0, uint64_t s1,
                            uint64_t e0, uint64_t e1, uint64_t len) {
    uint64_t off0 = 0, off1 = 0;
    if (slm) L0_CHECK(zeKernelSetArgumentValue(k, ai++, (size_t)bytes, nullptr));
    else     L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(void*), ptr));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &bytes));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &off0));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &off1));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &s0));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &s1));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &e0));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &e1));
    L0_CHECK(zeKernelSetArgumentValue(k, ai++, sizeof(uint64_t), &len));
}

int main(int argc, char** argv) {
    int Size   = argc > 1 ? atoi(argv[1]) : 256;
    int warmup = argc > 2 ? atoi(argv[2]) : 20;
    int iters  = argc > 3 ? atoi(argv[3]) : 100;
    const int M = Size, N = Size, K = Size;
    if (M % TM || N % TN || K % KS) {
        fprintf(stderr, "size %d must be a multiple of %d (and K a multiple of %d)\n", Size, TM, KS);
        return 1;
    }

    L0_CHECK(zeInit(ZE_INIT_FLAG_GPU_ONLY));
    uint32_t driverCount = 0;
    L0_CHECK(zeDriverGet(&driverCount, nullptr));
    if (!driverCount) { fprintf(stderr, "No L0 drivers\n"); return 1; }
    std::vector<ze_driver_handle_t> drivers(driverCount);
    L0_CHECK(zeDriverGet(&driverCount, drivers.data()));
    ze_driver_handle_t driver = drivers[0];

    uint32_t deviceCount = 0;
    L0_CHECK(zeDeviceGet(driver, &deviceCount, nullptr));
    if (!deviceCount) { fprintf(stderr, "No L0 devices\n"); return 1; }
    std::vector<ze_device_handle_t> devices(deviceCount);
    L0_CHECK(zeDeviceGet(driver, &deviceCount, devices.data()));
    ze_device_handle_t device = devices[0];

    ze_device_properties_t devProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };
    L0_CHECK(zeDeviceGetProperties(device, &devProps));
    fprintf(stderr, "Device: %s\n", devProps.name);

    ze_context_desc_t ctxDesc = { ZE_STRUCTURE_TYPE_CONTEXT_DESC };
    ze_context_handle_t ctx;
    L0_CHECK(zeContextCreate(driver, &ctxDesc, &ctx));

    // Endeavor 136: CRISP_MATMUL_SPV picks the kernel (sync vs async) without a rebuild.
    const char* env_spv = getenv("CRISP_MATMUL_SPV");
    auto spv = env_spv
        ? read_spv({ env_spv })
        : read_spv({ "matmul_bmg.spv", "benchmarks/matmul/crisp/matmul_bmg.spv" });
    ze_module_desc_t modDesc = {};
    modDesc.stype = ZE_STRUCTURE_TYPE_MODULE_DESC;
    modDesc.format = ZE_MODULE_FORMAT_IL_SPIRV;
    modDesc.inputSize = spv.size();
    modDesc.pInputModule = spv.data();
    ze_module_handle_t mod;
    ze_module_build_log_handle_t buildLog;
    ze_result_t modRes = zeModuleCreate(ctx, device, &modDesc, &mod, &buildLog);
    if (modRes != ZE_RESULT_SUCCESS) {
        size_t logSize = 0;
        zeModuleBuildLogGetString(buildLog, &logSize, nullptr);
        std::vector<char> logBuf(logSize);
        zeModuleBuildLogGetString(buildLog, &logSize, logBuf.data());
        fprintf(stderr, "zeModuleCreate FAILED 0x%x -- log:\n%s\n", (unsigned)modRes, logBuf.data());
        return 1;
    }
    if (buildLog) zeModuleBuildLogDestroy(buildLog);

    ze_kernel_desc_t kDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };
    kDesc.pKernelName = "matmul";
    ze_kernel_handle_t kernel;
    L0_CHECK(zeKernelCreate(mod, &kDesc, &kernel));

    ze_device_mem_alloc_desc_t devMemDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };
    ze_host_mem_alloc_desc_t   hostMemDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };
    float* d_a = nullptr; float* d_b = nullptr; float* d_c = nullptr;
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc, (size_t)M * K * sizeof(float), sizeof(float), device, (void**)&d_a));
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc, (size_t)K * N * sizeof(float), sizeof(float), device, (void**)&d_b));
    L0_CHECK(zeMemAllocShared(ctx, &devMemDesc, &hostMemDesc, (size_t)M * N * sizeof(float), sizeof(float), device, (void**)&d_c));
    for (size_t i = 0; i < (size_t)M * K; i++) d_a[i] = 1.0f;
    for (size_t i = 0; i < (size_t)K * N; i++) d_b[i] = 1.0f;
    for (size_t i = 0; i < (size_t)M * N; i++) d_c[i] = 0.0f;

    // Arg order matches the hoist's metacrisp physical signature.  Scratch tiles first
    // (VERIFY against matmul_bmg's metacrisp: perf-bmg emitted B-tile before A-tile), then
    // A, B, C.  B-tile = KS x TN, A-tile = TM x KS.
    int ai = 0;
    set_tensor_args(kernel, ai, true,  nullptr, (uint64_t)KS * TN * sizeof(float), TN, 1, KS, TN, (uint64_t)KS * TN);  // B-tile (8x64)
    set_tensor_args(kernel, ai, true,  nullptr, (uint64_t)TM * KS * sizeof(float), KS, 1, TM, KS, (uint64_t)TM * KS);  // A-tile (64x8)
    set_tensor_args(kernel, ai, false, (void**)&d_a, (uint64_t)M * K * sizeof(float), K, 1, M, K, (uint64_t)M * K);    // A (MxK)
    set_tensor_args(kernel, ai, false, (void**)&d_b, (uint64_t)K * N * sizeof(float), N, 1, K, N, (uint64_t)K * N);    // B (KxN)
    set_tensor_args(kernel, ai, false, (void**)&d_c, (uint64_t)M * N * sizeof(float), N, 1, M, N, (uint64_t)M * N);    // C (MxN)

    L0_CHECK(zeKernelSetGroupSize(kernel, SUBGROUP, 1, 1));
    // grid-y = workgroup-id 0 (rows), grid-x = workgroup-id 1 (cols).
    ze_group_count_t groupCount = { (uint32_t)(M / TM), (uint32_t)(N / TN), 1 };

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
    evDesc.index = 0; evDesc.signal = ZE_EVENT_SCOPE_FLAG_HOST; evDesc.wait = ZE_EVENT_SCOPE_FLAG_HOST;
    ze_event_handle_t tsEvent;
    L0_CHECK(zeEventCreate(eventPool, &evDesc, &tsEvent));

    uint64_t timerRes = devProps.timerResolution;
    uint64_t validBits = devProps.kernelTimestampValidBits;
    uint64_t clockMask = (validBits >= 64) ? ~0ULL : ((1ULL << validBits) - 1ULL);
    bool timerInHz = (timerRes > 1000000ULL);
    auto durNs = [&](const ze_kernel_timestamp_result_t& ts) -> double {
        uint64_t s = ts.context.kernelStart & clockMask;
        uint64_t e = ts.context.kernelEnd & clockMask;
        uint64_t delta = (e >= s) ? (e - s) : (clockMask + 1 - s + e);
        return timerInHz ? (double)delta * 1e9 / (double)timerRes : (double)delta * (double)timerRes;
    };

    ze_command_list_desc_t clDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };
    ze_command_list_handle_t clWarm, clMeas;
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &clWarm));
    L0_CHECK(zeCommandListAppendLaunchKernel(clWarm, kernel, &groupCount, nullptr, 0, nullptr));
    L0_CHECK(zeCommandListClose(clWarm));
    L0_CHECK(zeCommandListCreate(ctx, device, &clDesc, &clMeas));
    L0_CHECK(zeCommandListAppendLaunchKernel(clMeas, kernel, &groupCount, tsEvent, 0, nullptr));
    L0_CHECK(zeCommandListClose(clMeas));

    auto runWarm = [&]() {
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &clWarm, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
    };
    auto runMeas = [&]() {
        L0_CHECK(zeEventHostReset(tsEvent));
        L0_CHECK(zeCommandQueueExecuteCommandLists(cmdQueue, 1, &clMeas, nullptr));
        L0_CHECK(zeCommandQueueSynchronize(cmdQueue, UINT64_MAX));
        L0_CHECK(zeEventHostSynchronize(tsEvent, UINT64_MAX));
    };

    runWarm();
    {
        bool ok = true;
        for (size_t i = 0; i < (size_t)M * N; i++)
            if (std::fabs(d_c[i] - (float)K) > (float)K * 1e-2f) { ok = false; break; }
        if (!ok) { fprintf(stderr, "Smoke FAILED: C[0]=%.1f expected=%d\n", d_c[0], K); return 1; }
    }
    for (int i = 0; i < warmup; i++) runWarm();

    std::vector<double> kt(iters);
    for (int i = 0; i < iters; i++) {
        runMeas();
        ze_kernel_timestamp_result_t ts = {};
        L0_CHECK(zeEventQueryKernelTimestamp(tsEvent, &ts));
        kt[i] = durNs(ts) / 1000.0;
    }

    double expected = (double)K, maxerr = 0.0;
    for (size_t i = 0; i < (size_t)M * N; i++) maxerr = std::max(maxerr, (double)std::fabs(d_c[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    // Endeavor 136: CRISP_IMPL_NAME tags sync ("crisp") vs async ("crisp-async") runs.
    const char* impl_name = getenv("CRISP_IMPL_NAME");
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"%s\",\n",
           impl_name ? impl_name : "crisp");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    zeCommandListDestroy(clMeas); zeCommandListDestroy(clWarm);
    zeEventDestroy(tsEvent); zeEventPoolDestroy(eventPool);
    zeMemFree(ctx, d_a); zeMemFree(ctx, d_b); zeMemFree(ctx, d_c);
    zeKernelDestroy(kernel); zeModuleDestroy(mod);
    zeCommandQueueDestroy(cmdQueue); zeContextDestroy(ctx);
    return correct ? 0 : 1;
}
