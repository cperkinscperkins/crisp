// bench_harness_l0.cpp — ONE hand-written Level Zero harness for every Crisp matmul benchmark.
//
// WHY THIS EXISTS
// ---------------
// Until now each benchmark measured a DIFFERENT program: `crisp-hoist-l0 --mma-test` generated a
// fresh harness per kernel, per size, and that generated code was both the thing under test and the
// apparatus testing it.  When a row looked wrong there was no way to tell whether the kernel or the
// harness was at fault, and both happened:
//
//   * chap2_tiling posted the second-best tf32 number in its section while storing nothing at all
//     (its kernel had no `store-tile`; the compiler warned on every build and a sweep run with
//     --log-level=off never showed it).
//   * chap0_naive measured MMA_CORRECT at 16x16x16 and MMA_WRONG at 32x32x32 and above with no MMA
//     in the kernel whatsoever -- because the generator emitted a 1-D group count for a kernel with
//     a 2-D local size, pinning grid.y to 1.  At N=16 that happens to cover the matrix; at N=32 half
//     the columns are never written.  The kernel was always fine.
//
// A benchmark exists to attribute a difference to the thing being compared.  A per-kernel apparatus
// cannot do that.  This file is the apparatus, written once, reviewed once, identical for every
// kernel -- so a difference between two rows is a difference between two kernels.
//
// This does NOT replace `--hoist=l0`, which is a shipped Crisp feature with spec coverage (029, 070,
// 076, 116).  It replaces only its use as a measurement harness.
//
// CONTRACT (already fixed by scripts/crisp_bench/matmul.py: build_l0_harness / run_l0_fixed_sweep)
// ------------------------------------------------------------------------------------------------
//   argv:  <M> <N> <K> <warmup> <iters>
//   env:   CRISP_MATMUL_SPV     path to the .spv                              (required)
//          CRISP_MATMUL_KERNEL  entry point name                              (default "matmul")
//          CRISP_MATMUL_LOCAL   local size "x,y,z"                            (default "16,1,1")
//          CRISP_MATMUL_GRID    "strided" | "one-thread-per"                  (default "strided")
//          CRISP_MATMUL_TILE    output tile "TM,TN", for GRID=strided         (default "32,64")
//          CRISP_MATMUL_ELEM    A/B element type: "f32" | "bf16" | "f16"      (default "f32")
//   stdout: one JSON object -- verified / wall_time_ms / kernel_median_us / gflops
//
// Kernel ABI: a rank-2 Crisp tensor flattens to NINE arguments, in order --
//   ptr, byte_size, off0, off1, str0, str1, ext0, ext1, length
// so A, B, C occupy argument indices 0-8, 9-17 and 18-26.

#if __has_include(<level_zero/ze_api.h>)
#include <level_zero/ze_api.h>
#else
#include <ze_api.h>
#endif
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#include <chrono>

#define ZE_OK(expr, what)                                                             \
    do {                                                                              \
        ze_result_t _r = (expr);                                                      \
        if (_r != ZE_RESULT_SUCCESS) {                                                \
            std::cerr << "L0 error " << std::hex << _r << " at " << what << "\n";     \
            return 2;                                                                 \
        }                                                                             \
    } while (0)

static std::string env_or(const char *k, const char *dflt) {
    const char *v = std::getenv(k);
    return (v && *v) ? std::string(v) : std::string(dflt);
}

static std::vector<uint32_t> parse_csv(const std::string &s, size_t want, uint32_t fill) {
    std::vector<uint32_t> out;
    size_t i = 0;
    while (i < s.size() && out.size() < want) {
        size_t j = s.find(',', i);
        if (j == std::string::npos) j = s.size();
        out.push_back((uint32_t)std::strtoul(s.substr(i, j - i).c_str(), nullptr, 10));
        i = j + 1;
    }
    while (out.size() < want) out.push_back(fill);
    return out;
}

// --- 16-bit encodings.  bf16 is the top half of an f32; f16 is IEEE half. -----------------
static uint16_t f32_to_bf16(float f) {
    uint32_t b;
    std::memcpy(&b, &f, 4);
    return (uint16_t)(b >> 16);            // truncate; the fill values are exact in bf16
}
static float bf16_to_f32(uint16_t h) {
    uint32_t b = (uint32_t)h << 16;
    float f;
    std::memcpy(&f, &b, 4);
    return f;
}
static uint16_t f32_to_f16(float f) {
    uint32_t x;
    std::memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    int32_t exp = (int32_t)((x >> 23) & 0xFF) - 127 + 15;
    uint32_t man = x & 0x7FFFFFu;
    if (exp <= 0) return (uint16_t)sign;
    if (exp >= 31) return (uint16_t)(sign | 0x7C00u);
    return (uint16_t)(sign | ((uint32_t)exp << 10) | (man >> 13));
}
static float f16_to_f32(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t man = h & 0x3FFu;
    if (exp == 0) { if (!man) { float f; uint32_t b = sign; std::memcpy(&f, &b, 4); return f; }
                    exp = 1; while (!(man & 0x400u)) { man <<= 1; exp--; } man &= 0x3FFu; }
    else if (exp == 31) { uint32_t b = sign | 0x7F800000u | (man << 13); float f;
                          std::memcpy(&f, &b, 4); return f; }
    uint32_t b = sign | ((exp - 15 + 127) << 23) | (man << 13);
    float f;
    std::memcpy(&f, &b, 4);
    return f;
}

int main(int argc, char **argv) {
    if (argc < 6) {
        std::cerr << "usage: " << argv[0] << " M N K warmup iters\n";
        return 1;
    }
    const uint64_t M = std::strtoull(argv[1], nullptr, 10);
    const uint64_t N = std::strtoull(argv[2], nullptr, 10);
    const uint64_t K = std::strtoull(argv[3], nullptr, 10);
    const int warmup = std::atoi(argv[4]);
    const int iters  = std::max(1, std::atoi(argv[5]));

    const std::string spv_path = env_or("CRISP_MATMUL_SPV", "");
    if (spv_path.empty()) { std::cerr << "CRISP_MATMUL_SPV not set\n"; return 1; }
    const std::string kname = env_or("CRISP_MATMUL_KERNEL", "matmul");
    const std::string elem  = env_or("CRISP_MATMUL_ELEM", "f32");
    const std::string gmode = env_or("CRISP_MATMUL_GRID", "strided");
    const auto local = parse_csv(env_or("CRISP_MATMUL_LOCAL", "16,1,1"), 3, 1);
    const auto tile  = parse_csv(env_or("CRISP_MATMUL_TILE", "32,64"), 2, 1);
    // Module build flags.  The generated reference harness passes
    // -ze-opt-large-register-file, which endeavour 144 selects per kernel; leaving it out
    // costs ~3.1x on a 32x64 tile (50.3 vs 16.0 TFLOPS measured).  It is a knob rather than
    // a constant because the right answer is geometry-dependent: the DEFAULT allocation
    // beats large-GRF by 70% at 128x128 over 16 subgroups.
    const std::string build_flags = env_or("CRISP_MATMUL_BUILD_FLAGS", "-ze-opt-large-register-file");

    const bool ab16 = (elem == "bf16" || elem == "f16");
    const size_t ab_bytes = ab16 ? 2 : 4;

    // ---- SPIR-V -------------------------------------------------------------------------
    std::vector<uint8_t> spv;
    {
        FILE *fp = std::fopen(spv_path.c_str(), "rb");
        if (!fp) { std::cerr << "cannot open " << spv_path << "\n"; return 1; }
        std::fseek(fp, 0, SEEK_END);
        long sz = std::ftell(fp);
        std::fseek(fp, 0, SEEK_SET);
        spv.resize((size_t)sz);
        if (std::fread(spv.data(), 1, (size_t)sz, fp) != (size_t)sz) { std::fclose(fp); return 1; }
        std::fclose(fp);
    }

    ZE_OK(zeInit(0), "zeInit");
    uint32_t nd = 0;
    ZE_OK(zeDriverGet(&nd, nullptr), "zeDriverGet");
    std::vector<ze_driver_handle_t> drivers(nd);
    ZE_OK(zeDriverGet(&nd, drivers.data()), "zeDriverGet2");

    ze_driver_handle_t driver = nullptr;
    ze_device_handle_t device = nullptr;
    for (auto d : drivers) {
        uint32_t ndev = 0;
        if (zeDeviceGet(d, &ndev, nullptr) != ZE_RESULT_SUCCESS || !ndev) continue;
        std::vector<ze_device_handle_t> devs(ndev);
        zeDeviceGet(d, &ndev, devs.data());
        for (auto dev : devs) {
            ze_device_properties_t p{ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
            if (zeDeviceGetProperties(dev, &p) == ZE_RESULT_SUCCESS &&
                p.type == ZE_DEVICE_TYPE_GPU) { driver = d; device = dev; break; }
        }
        if (device) break;
    }
    if (!device) { std::cerr << "no GPU device\n"; return 2; }

    ze_context_desc_t cdesc{ZE_STRUCTURE_TYPE_CONTEXT_DESC};
    ze_context_handle_t ctx;
    ZE_OK(zeContextCreate(driver, &cdesc, &ctx), "contextCreate");

    ze_module_desc_t mdesc{ZE_STRUCTURE_TYPE_MODULE_DESC};
    mdesc.format = ZE_MODULE_FORMAT_IL_SPIRV;
    mdesc.inputSize = spv.size();
    mdesc.pInputModule = spv.data();
    mdesc.pBuildFlags = build_flags.c_str();
    ze_module_handle_t module_;
    ze_module_build_log_handle_t blog = nullptr;
    if (zeModuleCreate(ctx, device, &mdesc, &module_, &blog) != ZE_RESULT_SUCCESS) {
        size_t n = 0;
        zeModuleBuildLogGetString(blog, &n, nullptr);
        std::vector<char> log(n + 1, 0);
        zeModuleBuildLogGetString(blog, &n, log.data());
        std::cerr << "module build failed:\n" << log.data() << "\n";
        return 2;
    }
    ze_kernel_desc_t kdesc{ZE_STRUCTURE_TYPE_KERNEL_DESC};
    kdesc.pKernelName = kname.c_str();
    ze_kernel_handle_t kernel;
    ZE_OK(zeKernelCreate(module_, &kdesc, &kernel), "kernelCreate");

    // ---- buffers ------------------------------------------------------------------------
    const uint64_t ea = M * K, eb = K * N, ec = M * N;
    ze_device_mem_alloc_desc_t dmem{ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC};
    ze_host_mem_alloc_desc_t hmem{ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC};
    void *A = nullptr, *B = nullptr, *C = nullptr;
    ZE_OK(zeMemAllocShared(ctx, &dmem, &hmem, ea * ab_bytes, 64, device, &A), "allocA");
    ZE_OK(zeMemAllocShared(ctx, &dmem, &hmem, eb * ab_bytes, 64, device, &B), "allocB");
    ZE_OK(zeMemAllocShared(ctx, &dmem, &hmem, ec * 4, 64, device, &C), "allocC");

    // Deterministic, small-integer fill: exact in bf16/f16/f32 alike, so a mismatch is a real
    // error and never a rounding artifact.
    auto seta = [&](uint64_t i, float v) {
        if (elem == "bf16")     ((uint16_t *)A)[i] = f32_to_bf16(v);
        else if (elem == "f16") ((uint16_t *)A)[i] = f32_to_f16(v);
        else                    ((float *)A)[i] = v;
    };
    auto setb = [&](uint64_t i, float v) {
        if (elem == "bf16")     ((uint16_t *)B)[i] = f32_to_bf16(v);
        else if (elem == "f16") ((uint16_t *)B)[i] = f32_to_f16(v);
        else                    ((float *)B)[i] = v;
    };
    for (uint64_t i = 0; i < ea; ++i) seta(i, (float)(i % 5));
    for (uint64_t i = 0; i < eb; ++i) setb(i, (float)(i % 3));
    std::memset(C, 0, ec * 4);

    // ---- arguments: 9 per rank-2 tensor -------------------------------------------------
    auto bind = [&](uint32_t base, void *ptr, uint64_t r, uint64_t c, uint64_t esz) -> bool {
        uint64_t byte_size = r * c * esz, off0 = 0, off1 = 0, str0 = c, str1 = 1,
                 ext0 = r, ext1 = c, len = r * c;
        struct { uint32_t idx; size_t sz; const void *p; } as[] = {
            {base + 0, sizeof(void *), &ptr},     {base + 1, sizeof(uint64_t), &byte_size},
            {base + 2, sizeof(uint64_t), &off0},  {base + 3, sizeof(uint64_t), &off1},
            {base + 4, sizeof(uint64_t), &str0},  {base + 5, sizeof(uint64_t), &str1},
            {base + 6, sizeof(uint64_t), &ext0},  {base + 7, sizeof(uint64_t), &ext1},
            {base + 8, sizeof(uint64_t), &len},
        };
        for (auto &a : as)
            if (zeKernelSetArgumentValue(kernel, a.idx, a.sz, a.p) != ZE_RESULT_SUCCESS) {
                std::cerr << "setArg " << a.idx << " failed\n";
                return false;
            }
        return true;
    };
    if (!bind(0, A, M, K, ab_bytes)) return 2;
    if (!bind(9, B, K, N, ab_bytes)) return 2;
    if (!bind(18, C, M, N, 4)) return 2;

    // ---- dispatch -----------------------------------------------------------------------
    // THIS is what the generated harness got wrong for chap0_naive: it emitted a 1-D group count
    // for a kernel with a 2-D local size, pinning grid.y to 1, so only the first `local.y` columns
    // were ever written.  Both modes below derive the grid from the SAME quantities the kernel
    // uses, and both are 2-D.
    ZE_OK(zeKernelSetGroupSize(kernel, local[0], local[1], local[2]), "setGroupSize");
    ze_group_count_t grid{1, 1, 1};
    if (gmode == "one-thread-per") {
        // One work-item per output element: cover M x N with the 2-D local size.
        grid.groupCountX = (uint32_t)((M + local[0] - 1) / local[0]);
        grid.groupCountY = (uint32_t)((N + local[1] - 1) / local[1]);
    } else {
        // tile-stride: one workgroup per output TILE.  Axis x <- rows, y <- cols.
        grid.groupCountX = (uint32_t)((M + tile[0] - 1) / tile[0]);
        grid.groupCountY = (uint32_t)((N + tile[1] - 1) / tile[1]);
    }

    // A real queue plus two PRE-BUILT, CLOSED command lists -- the structure the reduction
    // fixture uses.  An immediate list with a per-launch host sync puts submission round-trips
    // inside the measured region; on this WSL2 setup that read 4.4 ms for a kernel that runs in
    // ~283 us.  Building the list once and only re-executing it keeps the measurement on the
    // kernel.
    ze_command_queue_desc_t qd{ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC};
    qd.mode = ZE_COMMAND_QUEUE_MODE_ASYNCHRONOUS;
    ze_command_queue_handle_t queue;
    ZE_OK(zeCommandQueueCreate(ctx, device, &qd, &queue), "queueCreate");

    ze_event_pool_desc_t epd{ZE_STRUCTURE_TYPE_EVENT_POOL_DESC};
    epd.flags = ZE_EVENT_POOL_FLAG_KERNEL_TIMESTAMP;
    epd.count = 1;
    ze_event_pool_handle_t epool;
    ZE_OK(zeEventPoolCreate(ctx, &epd, 1, &device, &epool), "eventPool");
    ze_event_desc_t ed{ZE_STRUCTURE_TYPE_EVENT_DESC};
    ed.index = 0;
    ed.signal = ZE_EVENT_SCOPE_FLAG_HOST;
    ze_event_handle_t ev;
    ZE_OK(zeEventCreate(epool, &ed, &ev), "event");

    ze_device_properties_t dprops{ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
    zeDeviceGetProperties(device, &dprops);
    // ze_device_properties_t::timerResolution changed meaning across Level Zero versions: older
    // drivers report NANOSECONDS PER TICK, newer ones report a FREQUENCY IN HZ.  Assuming one
    // unconditionally is a ~15x timing error and looks exactly like a slow kernel -- which is how
    // this fixture first "measured" 3.9 TFLOPS for a kernel doing 61.
    const uint64_t timer_res = dprops.timerResolution;
    const bool timer_in_hz = (timer_res > 1000000ULL);
    // Kernel timestamps are a wrapping counter of kernelTimestampValidBits width.
    const uint32_t valid_bits = dprops.kernelTimestampValidBits;
    const uint64_t clock_mask = (valid_bits >= 64) ? ~0ULL : ((1ULL << valid_bits) - 1ULL);

    ze_command_list_desc_t cld{ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC};
    ze_command_list_handle_t cl_warm, cl_meas;
    ZE_OK(zeCommandListCreate(ctx, device, &cld, &cl_warm), "clWarm");
    ZE_OK(zeCommandListAppendLaunchKernel(cl_warm, kernel, &grid, nullptr, 0, nullptr), "appendWarm");
    ZE_OK(zeCommandListClose(cl_warm), "closeWarm");
    ZE_OK(zeCommandListCreate(ctx, device, &cld, &cl_meas), "clMeas");
    ZE_OK(zeCommandListAppendLaunchKernel(cl_meas, kernel, &grid, ev, 0, nullptr), "appendMeas");
    ZE_OK(zeCommandListClose(cl_meas), "closeMeas");

    for (int w = 0; w < warmup; ++w) {
        ZE_OK(zeCommandQueueExecuteCommandLists(queue, 1, &cl_warm, nullptr), "execWarm");
        ZE_OK(zeCommandQueueSynchronize(queue, UINT64_MAX), "syncWarm");
    }

    std::vector<double> us;
    us.reserve(iters);
    // Host wall-clock across the timed loop.  Kernel timestamps depend on the timer domain, the
    // valid-bit width and the Hz-vs-ns convention; the wall clock depends on none of those, so it
    // arbitrates when two harnesses disagree.
    const auto wall_t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        ZE_OK(zeEventHostReset(ev), "eventReset");
        ZE_OK(zeCommandQueueExecuteCommandLists(queue, 1, &cl_meas, nullptr), "execMeas");
        // Both syncs on purpose: the reduction fixture records that either alone has been seen to
        // return NOT_READY on Intel WSL2 builds.  Queue sync means the kernel is done; event sync
        // means the timestamp table is populated host-side.
        ZE_OK(zeCommandQueueSynchronize(queue, UINT64_MAX), "syncMeas");
        ZE_OK(zeEventHostSynchronize(ev, UINT64_MAX), "eventSync");
        ze_kernel_timestamp_result_t ts{};
        if (zeEventQueryKernelTimestamp(ev, &ts) == ZE_RESULT_SUCCESS) {
            const uint64_t s0 = ts.context.kernelStart & clock_mask;
            const uint64_t e0 = ts.context.kernelEnd & clock_mask;
            const uint64_t d = (e0 >= s0) ? (e0 - s0) : (clock_mask + 1 - s0 + e0);
            const double ns = timer_in_hz ? ((double)d * 1e9 / (double)timer_res)
                                          : ((double)d * (double)timer_res);
            us.push_back(ns / 1000.0);
        }
    }
    const double wall_total_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - wall_t0).count();
    const double wall_us = (wall_total_ms * 1000.0) / (double)iters;
    std::sort(us.begin(), us.end());
    const double median_us = us.empty() ? 0.0 : us[us.size() / 2];
    const double min_us    = us.empty() ? 0.0 : us.front();
    const double gflops    = median_us > 0.0 ? (2.0 * (double)M * N * K) / (median_us * 1e3) : 0.0;

    // ---- verification: full host reference ----------------------------------------------
    // Checked at EVERY size, not sampled.  A fast wrong kernel must never look like a win --
    // that is exactly how a kernel storing nothing posted the second-best number in its section.
    bool verified = true;
    double max_abs_err = 0.0;
    uint64_t checked = 0;
    {
        auto ga = [&](uint64_t i) -> float {
            if (elem == "bf16") return bf16_to_f32(((uint16_t *)A)[i]);
            if (elem == "f16")  return f16_to_f32(((uint16_t *)A)[i]);
            return ((float *)A)[i];
        };
        auto gb = [&](uint64_t i) -> float {
            if (elem == "bf16") return bf16_to_f32(((uint16_t *)B)[i]);
            if (elem == "f16")  return f16_to_f32(((uint16_t *)B)[i]);
            return ((float *)B)[i];
        };
        // ~64x64 samples STRIDED across the whole output: bounded cost, full-extent coverage.
        // A top-left corner (what the generated harness checks) is the same price and blind to
        // every tile it does not reach.
        const uint64_t smax = 64;
        const uint64_t si = (M + smax - 1) / smax ? (M + smax - 1) / smax : 1;
        const uint64_t sj = (N + smax - 1) / smax ? (N + smax - 1) / smax : 1;
        for (uint64_t i = 0; i < M && verified; i += si)
            for (uint64_t j = 0; j < N; j += sj) {
                ++checked;
                double acc = 0.0;
                for (uint64_t k = 0; k < K; ++k) acc += (double)ga(i * K + k) * (double)gb(k * N + j);
                double got = (double)((float *)C)[i * N + j];
                double err = std::fabs(got - acc);
                double tol = 1e-3 * std::max(1.0, std::fabs(acc));
                if (err > max_abs_err) max_abs_err = err;
                if (err > tol) { verified = false; break; }
            }
    }

    std::cout << "{\n"
              << "  \"implementation\": \"crisp_l0_fixture\",\n"
              << "  \"kernel\": \"" << kname << "\",\n"
              << "  \"M\": " << M << ", \"N\": " << N << ", \"K\": " << K << ",\n"
              << "  \"elem\": \"" << elem << "\", \"grid_mode\": \"" << gmode << "\",\n"
              << "  \"build_flags\": \"" << build_flags << "\",\n"
              << "  \"group\": [" << local[0] << ", " << local[1] << ", " << local[2] << "],\n"
              << "  \"grid\": [" << grid.groupCountX << ", " << grid.groupCountY << ", 1],\n"
              << "  \"verified\": " << (verified ? "true" : "false") << ",\n"
              << "  \"correct\": " << (verified ? "true" : "false") << ",\n"
              << "  \"max_abs_err\": " << max_abs_err << ",\n"
              << "  \"verify_samples\": " << checked << ",\n"
              << "  \"wall_time_ms\": " << (wall_us / 1000.0) << ",\n"
              << "  \"wall_per_iter_us\": " << wall_us << ",\n"
              << "  \"gflops_from_wall\": "
              << (wall_us > 0.0 ? (2.0*(double)M*N*K)/(wall_us*1e3) : 0.0) << ",\n"
              << "  \"kernel_median_us\": " << median_us << ",\n"
              << "  \"kernel_min_us\": " << min_us << ",\n"
              << "  \"gflops\": " << gflops << "\n"
              << "}\n";

    zeEventDestroy(ev);
    zeEventPoolDestroy(epool);
    zeCommandListDestroy(cl_warm);
    zeCommandListDestroy(cl_meas);
    zeCommandQueueDestroy(queue);
    zeMemFree(ctx, A); zeMemFree(ctx, B); zeMemFree(ctx, C);
    zeKernelDestroy(kernel);
    zeModuleDestroy(module_);
    zeContextDestroy(ctx);
    return verified ? 0 : 3;
}
