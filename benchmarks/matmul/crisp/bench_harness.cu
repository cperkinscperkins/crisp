// bench_harness.cu — ONE hand-written CUDA Driver-API harness for every Crisp matmul benchmark.
//
// The NVIDIA twin of bench_harness_l0.cpp, and it exists for the same reason: until now each
// NVIDIA benchmark measured a DIFFERENT program, because `crisp-hoist-cuda --mma-test` generated a
// fresh harness per kernel and that generated code was both the thing under test and the apparatus
// testing it.  The L0 header records what that cost on Intel (a kernel storing nothing posting the
// second-best number; chap0_naive reading MMA_WRONG when it was always correct).  Nothing about
// those failures was Intel-specific.
//
// This does NOT replace `--hoist=cuda`, a shipped feature with spec coverage.  It replaces only its
// use as a measurement harness.
//
// WHAT THIS ONE DOES THAT THE L0 FIXTURE DOES NOT: it binds kernels whose arguments include
// SCRATCH (SLM / __shared__) tensors.  l0_fixture_env refuses those -- on Level Zero a group-local
// argument needs zeKernelSetArgumentValue(i, bytes, nullptr) and the fixture binds A/B/C at fixed
// offsets, so it declares `_fixture_unsupported` and hands the kernel to the generated harness.
// On CUDA a scratch tensor's "pointer" argument is just a BYTE OFFSET into the dynamic shared
// block, so it can be passed as a plain integer.  That is the whole difference, and it is why the
// staged 16-bit MMA kernels (which must stage A/B through shared memory on NVIDIA -- the
// register-resident operand path is Intel-only) are measurable here.
//
// NOTHING IS ASSUMED ABOUT ARGUMENT POSITIONS.  A rank-2 Crisp tensor flattens to NINE arguments
//   ptr, byte_size, off0, off1, str0, str1, ext0, ext1, length
// but the ORDER of tensors is not the source order: for a staged kernel the compiler emits the
// scratch tiles FIRST (and among themselves in an order that is not the binding order either --
// b_tile before a_tile in the fp16 rung).  So A/B/C are NOT at 0/9/18.  Every index is passed in
// from the metacrisp, which records a :range for each parameter.  Hardcoding here would be the
// same class of error the fixture exists to eliminate.
//
// SHARED-MEMORY SIZING IS COMPUTED HERE, deliberately, and does not match the generated harness.
// hoist-cuda sizes every element at 4 bytes (elem-bytes is hardcoded for everything but
// double/int64), so a 16-bit staged kernel is launched with TWICE the dynamic shared memory it
// needs -- 1536 bytes where 768 is correct for the fp16 rung.  Shared memory per block governs
// occupancy, so that inflation silently depresses every 16-bit number.  This harness sizes from
// the real element width.  The offsets are arguments, so the kernel uses whatever we pass.
//
// CONTRACT (see scripts/crisp_bench/matmul.py: cuda_fixture_env / build_harness)
// ------------------------------------------------------------------------------------------------
//   argv:  <M> <N> <K> <warmup> <iters>
//   env:   CRISP_MATMUL_PTX      path to the .ptx                              (required)
//          CRISP_MATMUL_KERNEL   entry point name                              (default "matmul")
//          CRISP_MATMUL_LOCAL    block size "x,y,z"                            (default "32,1,1")
//          CRISP_MATMUL_GRID     "strided" | "one-thread-per"                  (default "strided")
//          CRISP_MATMUL_TILE     output tile "TM,TN", for GRID=strided         (default "32,64")
//          CRISP_MATMUL_ELEM     A/B element type: "f32" | "bf16" | "f16"      (default "f32")
//          CRISP_MATMUL_ARGC     total kernel argument count                   (default 27)
//          CRISP_MATMUL_ARG_A    A's FIRST argument index                      (default 0)
//          CRISP_MATMUL_ARG_B    B's FIRST argument index                      (default 9)
//          CRISP_MATMUL_ARG_C    C's FIRST argument index                      (default 18)
//          CRISP_MATMUL_SCRATCH  scratch tiles, "idx:ext0:ext1[,...]"          (default "")
//          CRISP_MATMUL_TENSORMAP  TMA descriptors, "idx:a|b:box0:box1[,...]" (default "")
//   stdout: one JSON object -- correct / max_abs_err / kernel_median_us / gflops
//
// The accumulator (C) is ALWAYS f32: every 16-bit MMA here accumulates in fp32, so CRISP_MATMUL_ELEM
// describes A and B only.  This matches the L0 fixture and the Crisp lowering.

#include <cuda.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#define CU_OK(expr, what)                                                              \
    do {                                                                               \
        CUresult _r = (expr);                                                          \
        if (_r != CUDA_SUCCESS) {                                                      \
            const char *_es = nullptr; cuGetErrorString(_r, &_es);                     \
            std::cerr << "CUDA error " << _r << " (" << (_es ? _es : "?")              \
                      << ") at " << what << "\n";                                      \
            return 2;                                                                  \
        }                                                                              \
    } while (0)

static const char *env_or(const char *k, const char *d) {
    const char *v = std::getenv(k);
    return (v && *v) ? v : d;
}

// --- 16-bit encodings.  bf16 is the top half of an f32; f16 is IEEE half. -----------------
// Byte-identical in behaviour to bench_harness_l0.cpp's copies, deliberately: if the two harnesses
// encoded fill values differently, an Intel row and an NVIDIA row would not be the same experiment.
static uint16_t f32_to_bf16(float f) {
    uint32_t b; std::memcpy(&b, &f, 4);
    return (uint16_t)(b >> 16);            // truncate; the fill values are exact in bf16
}
static float bf16_to_f32(uint16_t h) {
    uint32_t u = ((uint32_t)h) << 16; float f; std::memcpy(&f, &u, 4); return f;
}
static uint16_t f32_to_f16(float f) {
    uint32_t u; std::memcpy(&u, &f, 4);
    uint32_t s = (u >> 31) & 1u; int32_t e = (int32_t)((u >> 23) & 0xFFu) - 127 + 15;
    uint32_t m = u & 0x7FFFFFu;
    if (e <= 0)  return (uint16_t)(s << 15);
    if (e >= 31) return (uint16_t)((s << 15) | 0x7C00u);
    return (uint16_t)((s << 15) | ((uint32_t)e << 10) | (m >> 13));
}
static float f16_to_f32(uint16_t h) {
    uint32_t s = (uint32_t)(h >> 15) & 1u, e = (uint32_t)(h >> 10) & 0x1Fu, m = (uint32_t)h & 0x3FFu;
    uint32_t out;
    if (e == 0) {
        if (m == 0) { out = s << 31; }
        else { e = 127 - 15 + 1; while ((m & 0x400u) == 0) { m <<= 1; e--; } m &= 0x3FFu;
               out = (s << 31) | (e << 23) | (m << 13); }
    } else if (e == 31) { out = (s << 31) | 0x7F800000u | (m << 13); }
    else { out = (s << 31) | ((e - 15 + 127) << 23) | (m << 13); }
    float f; std::memcpy(&f, &out, 4); return f;
}

// A scratch tile is rank 2; a RING is rank 3 (slots x rows x cols) and flattens to twelve
// kernel arguments rather than nine.  Chapters 5 and 6 are rings, so rank is not optional.
struct Scratch { int idx; int rank; uint64_t e0, e1, e2, off; };

static std::vector<std::string> split(const std::string &s, char d) {
    std::vector<std::string> out; std::string cur; std::istringstream is(s);
    while (std::getline(is, cur, d)) if (!cur.empty()) out.push_back(cur);
    return out;
}

int main(int argc, char **argv) {
    if (argc < 6) {
        std::cerr << "usage: " << argv[0] << " <M> <N> <K> <warmup> <iters>\n";
        return 1;
    }
    const uint64_t M = std::strtoull(argv[1], nullptr, 10);
    const uint64_t N = std::strtoull(argv[2], nullptr, 10);
    const uint64_t K = std::strtoull(argv[3], nullptr, 10);
    const int warmup = std::atoi(argv[4]);
    const int iters  = std::atoi(argv[5]);

    const std::string ptx_path = env_or("CRISP_MATMUL_PTX", "");
    if (ptx_path.empty()) { std::cerr << "CRISP_MATMUL_PTX is required\n"; return 1; }
    const std::string kname = env_or("CRISP_MATMUL_KERNEL", "matmul");
    const std::string elem  = env_or("CRISP_MATMUL_ELEM", "f32");
    const std::string gmode = env_or("CRISP_MATMUL_GRID", "strided");

    unsigned local[3] = {32, 1, 1};
    {
        auto p = split(env_or("CRISP_MATMUL_LOCAL", "32,1,1"), ',');
        for (size_t i = 0; i < p.size() && i < 3; ++i) local[i] = (unsigned)std::stoul(p[i]);
    }
    uint64_t TM = 32, TN = 64;
    {
        auto p = split(env_or("CRISP_MATMUL_TILE", "32,64"), ',');
        if (p.size() >= 2) { TM = std::stoull(p[0]); TN = std::stoull(p[1]); }
    }
    const int argc_k = std::atoi(env_or("CRISP_MATMUL_ARGC", "27"));
    const int iA = std::atoi(env_or("CRISP_MATMUL_ARG_A", "0"));
    const int iB = std::atoi(env_or("CRISP_MATMUL_ARG_B", "9"));
    const int iC = std::atoi(env_or("CRISP_MATMUL_ARG_C", "18"));

    const uint64_t ebytes = (elem == "f32") ? 4 : 2;

    // Scratch tiles: "idx:ext0:ext1[,...]".  Offsets are ASSIGNED HERE, packed in ascending
    // argument order at the true element width -- see the header on why this differs from the
    // generated harness.
    std::vector<Scratch> scratch;
    uint64_t shared_bytes = 0;
    for (const auto &tok : split(env_or("CRISP_MATMUL_SCRATCH", ""), ',')) {
        auto f = split(tok, ':');
        if (f.size() < 3) continue;
        Scratch s{};
        s.idx  = std::atoi(f[0].c_str());
        s.rank = (f.size() >= 4) ? 3 : 2;
        s.e0   = std::stoull(f[1]);
        s.e1   = std::stoull(f[2]);
        s.e2   = (s.rank == 3) ? std::stoull(f[3]) : 1;
        s.off  = shared_bytes;
        shared_bytes += s.e0 * s.e1 * s.e2 * ebytes;
        scratch.push_back(s);
    }
    std::sort(scratch.begin(), scratch.end(), [](const Scratch &a, const Scratch &b) { return a.idx < b.idx; });

    CU_OK(cuInit(0), "cuInit");
    CUdevice dev; CU_OK(cuDeviceGet(&dev, 0), "cuDeviceGet");
    CUcontext ctx; CU_OK(cuCtxCreate(&ctx, 0, dev), "cuCtxCreate");

    std::string ptx_text;
    {
        std::ifstream in(ptx_path, std::ios::binary);
        if (!in) { std::cerr << "cannot open " << ptx_path << "\n"; return 1; }
        std::ostringstream ss; ss << in.rdbuf(); ptx_text = ss.str();
    }

    auto t_jit0 = std::chrono::high_resolution_clock::now();
    CUmodule module; CU_OK(cuModuleLoadData(&module, ptx_text.c_str()), "cuModuleLoadData");
    auto t_jit1 = std::chrono::high_resolution_clock::now();
    const double driver_jit_ms =
        std::chrono::duration<double, std::milli>(t_jit1 - t_jit0).count();

    auto t_k0 = std::chrono::high_resolution_clock::now();
    CUfunction kernel; CU_OK(cuModuleGetFunction(&kernel, module, kname.c_str()), "cuModuleGetFunction");
    auto t_k1 = std::chrono::high_resolution_clock::now();
    const double kernel_create_ms =
        std::chrono::duration<double, std::milli>(t_k1 - t_k0).count();

    // Opt in to >48KB dynamic shared memory when the kernel asks for it; without this the launch
    // fails rather than silently under-allocating.
    if (shared_bytes > 48u * 1024u) {
        CU_OK(cuFuncSetAttribute(kernel, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES,
                                 (int)shared_bytes), "cuFuncSetAttribute(dynamic smem)");
    }

    // ---- host buffers + fill --------------------------------------------------------------
    // Same fill as the L0 fixture: small exact integers, so bf16 truncation and f16 rounding are
    // both lossless and the reference is an exact comparison rather than a tolerance argument.
    const uint64_t nA = M * K, nB = K * N, nC = M * N;
    std::vector<uint8_t> A(nA * ebytes), B(nB * ebytes);
    std::vector<float>   C(nC, 0.0f);
    for (uint64_t i = 0; i < nA; ++i) {
        float v = (float)(i % 5);
        if      (elem == "f32")  ((float *)A.data())[i] = v;
        else if (elem == "bf16") ((uint16_t *)A.data())[i] = f32_to_bf16(v);
        else                     ((uint16_t *)A.data())[i] = f32_to_f16(v);
    }
    for (uint64_t i = 0; i < nB; ++i) {
        float v = (float)(i % 3);
        if      (elem == "f32")  ((float *)B.data())[i] = v;
        else if (elem == "bf16") ((uint16_t *)B.data())[i] = f32_to_bf16(v);
        else                     ((uint16_t *)B.data())[i] = f32_to_f16(v);
    }

    CUdeviceptr dA, dB, dC;
    CU_OK(cuMemAlloc(&dA, A.size()), "cuMemAlloc A");
    CU_OK(cuMemAlloc(&dB, B.size()), "cuMemAlloc B");
    CU_OK(cuMemAlloc(&dC, C.size() * sizeof(float)), "cuMemAlloc C");
    CU_OK(cuMemcpyHtoD(dA, A.data(), A.size()), "H2D A");
    CU_OK(cuMemcpyHtoD(dB, B.data(), B.size()), "H2D B");
    CU_OK(cuMemcpyHtoD(dC, C.data(), C.size() * sizeof(float)), "H2D C");

    // ---- kernel arguments -----------------------------------------------------------------
    // Backing store for every scalar, so &slot[i] stays valid for the whole run.
    std::vector<uint64_t> slot((size_t)argc_k, 0);
    std::vector<void *>   params((size_t)argc_k, nullptr);
    for (int i = 0; i < argc_k; ++i) params[i] = &slot[i];

    auto bind_tensor = [&](int base, CUdeviceptr ptr, uint64_t bytes,
                           uint64_t e0, uint64_t e1) {
        if (base < 0 || base + 8 >= argc_k + 1) return;
        slot[base + 0] = (uint64_t)ptr;   // ptr
        slot[base + 1] = bytes;           // byte_size
        slot[base + 2] = 0;               // off0
        slot[base + 3] = 0;               // off1
        slot[base + 4] = e1;              // str0 (row-major: row stride = ncols)
        slot[base + 5] = 1;               // str1
        slot[base + 6] = e0;              // ext0
        slot[base + 7] = e1;              // ext1
        slot[base + 8] = e0 * e1;         // length (ELEMENTS, not bytes)
    };
    bind_tensor(iA, dA, A.size(), M, K);
    bind_tensor(iB, dB, B.size(), K, N);
    bind_tensor(iC, dC, C.size() * sizeof(float), M, N);
    // A scratch tensor's "ptr" is a BYTE OFFSET into the dynamic shared block, not an address.
    auto bind_tensor3 = [&](int base, uint64_t off, uint64_t e0, uint64_t e1, uint64_t e2) {
        if (base < 0 || base + 11 >= argc_k) return;
        slot[base + 0]  = off;              // ptr (shared-memory byte offset)
        slot[base + 1]  = e0 * e1 * e2 * ebytes;
        slot[base + 2]  = 0; slot[base + 3] = 0; slot[base + 4] = 0;   // off0..2
        slot[base + 5]  = e1 * e2;          // str0 (row-major)
        slot[base + 6]  = e2;               // str1
        slot[base + 7]  = 1;                // str2
        slot[base + 8]  = e0;               // ext0 (ring slots)
        slot[base + 9]  = e1;               // ext1
        slot[base + 10] = e2;               // ext2
        slot[base + 11] = e0 * e1 * e2;     // length, in ELEMENTS
    };
    for (const auto &s : scratch) {
        if (s.rank == 3) bind_tensor3(s.idx, s.off, s.e0, s.e1, s.e2);
        else             bind_tensor(s.idx, (CUdeviceptr)s.off, s.e0 * s.e1 * ebytes, s.e0, s.e1);
    }

    // ---- CUtensorMap descriptors (TMA) ----------------------------------------------------
    // Chapters 4/5/6 fetch through cp.async.bulk.tensor, whose first kernel arguments are not
    // pointers but 128-byte CUtensorMap DESCRIPTORS built on the host.  Without these the fixture
    // can only measure the two rungs that do no TMA at all.
    //
    // The layout convention below is taken from the generated hoister
    // (%cuda-emit-tensor-map-encode, src/hoist-cuda/main.lisp) so both harnesses describe the
    // same tensor the same way:
    //   * gdim   = extents REVERSED (innermost dimension first)
    //   * gstr   = rank-1 entries, in BYTES, of the non-innermost dims
    //   * boxDim = tile dims reversed
    //   * elemStrides = all 1
    // Only the :swizzle :none path is reproduced here.  The :128b (wgmma) variant reverses those
    // choices for a K-contiguous col-major B, and no 16-bit kernel reaches it yet -- wgmma is
    // tf32-only (%check-wgmma-shape gates K=8), so a 16-bit swizzled descriptor cannot arise.
    // If that changes, this must grow the col-major branch rather than silently mis-describe.
    std::vector<CUdeviceptr> tmap_dev;
    for (const auto &tok : split(env_or("CRISP_MATMUL_TENSORMAP", ""), ',')) {
        auto f = split(tok, ':');
        if (f.size() < 4) continue;
        const int      idx  = std::atoi(f[0].c_str());
        const std::string wh = f[1];                       // "a" or "b"
        const uint64_t box0 = std::stoull(f[2]);
        const uint64_t box1 = std::stoull(f[3]);

        const bool isA = (wh == "a" || wh == "A");
        CUdeviceptr base = isA ? dA : dB;
        // Extents as this harness ALLOCATED them: A is M x K, B is K x N, both row-major.
        const uint64_t e0 = isA ? M : K;
        const uint64_t e1 = isA ? K : N;

        CUtensorMapDataType dt;
        if      (elem == "bf16") dt = CU_TENSOR_MAP_DATA_TYPE_BFLOAT16;
        else if (elem == "f16")  dt = CU_TENSOR_MAP_DATA_TYPE_FLOAT16;
        else                     dt = CU_TENSOR_MAP_DATA_TYPE_FLOAT32;

        uint64_t gdim[2] = { e1, e0 };                 // reversed: innermost first
        uint64_t gstr[1] = { e1 * ebytes };            // row stride of dim 0, in bytes
        uint32_t bdim[2] = { (uint32_t)box1, (uint32_t)box0 };   // reversed
        uint32_t estr[2] = { 1, 1 };

        CUtensorMap host_map;
        CUresult tr = cuTensorMapEncodeTiled(
            &host_map, dt, 2, (void *)base, gdim, gstr, bdim, estr,
            CU_TENSOR_MAP_INTERLEAVE_NONE, CU_TENSOR_MAP_SWIZZLE_NONE,
            CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE);
        if (tr != CUDA_SUCCESS) {
            const char *es = nullptr; cuGetErrorString(tr, &es);
            std::cerr << "cuTensorMapEncodeTiled failed for '" << wh << "' at arg " << idx
                      << ": " << (es ? es : "?") << "\n";
            return 2;
        }
        CUdeviceptr dmap;
        CU_OK(cuMemAlloc(&dmap, sizeof(CUtensorMap)), "cuMemAlloc tensormap");
        CU_OK(cuMemcpyHtoD(dmap, &host_map, sizeof(CUtensorMap)), "H2D tensormap");
        tmap_dev.push_back(dmap);
        if (idx >= 0 && idx < argc_k) slot[idx] = (uint64_t)dmap;
    }

    // ---- grid ------------------------------------------------------------------------------
    unsigned gx, gy;
    if (gmode == "one-thread-per") {
        gx = (unsigned)((N + local[0] - 1) / (local[0] ? local[0] : 1));
        gy = (unsigned)((M + (local[1] ? local[1] : 1) - 1) / (local[1] ? local[1] : 1));
    } else {
        // Axis x <- rows, y <- cols: the tile-grid convention endeavour 143 established.  Getting
        // this backwards SERIALISES an axis and was worth 7.6x, so it is stated, not inferred.
        gx = (unsigned)((M + TM - 1) / (TM ? TM : 1));
        gy = (unsigned)((N + TN - 1) / (TN ? TN : 1));
    }
    if (gx == 0) gx = 1;
    if (gy == 0) gy = 1;

    // DRY RUN: resolve and print the whole configuration WITHOUT touching CUDA.  This exists so
    // the harness can be validated on a machine with nvcc but no GPU -- every binding decision
    // (argument slots, scratch offsets, shared total) is made before cuInit, so a dry run
    // exercises all of it.  Debugging argument layout on a rented GPU is the expensive way.
    if (std::getenv("CRISP_MATMUL_DRYRUN")) {
        std::cout << "{\n"
                  << "  \"dry_run\": true,\n"
                  << "  \"kernel\": \"" << kname << "\",\n"
                  << "  \"elem\": \"" << elem << "\", \"elem_bytes\": " << ebytes << ",\n"
                  << "  \"argc\": " << argc_k << ", \"arg_a\": " << iA
                  << ", \"arg_b\": " << iB << ", \"arg_c\": " << iC << ",\n"
                  << "  \"shared_bytes\": " << shared_bytes << ",\n"
                  << "  \"scratch\": [";
        for (size_t i = 0; i < scratch.size(); ++i)
            std::cout << (i ? ", " : "") << "{\"idx\": " << scratch[i].idx
                      << ", \"rank\": " << scratch[i].rank
                      << ", \"e0\": " << scratch[i].e0
                      << ", \"e1\": " << scratch[i].e1
                      << ", \"e2\": " << scratch[i].e2
                      << ", \"off\": " << scratch[i].off << "}";
        std::cout << "],\n";
        std::cout << "  \"grid\": [" << gx << ", " << gy << ", 1], "
                  << "\"block\": [" << local[0] << ", " << local[1] << ", " << local[2] << "], "
                  << "\"tile\": [" << TM << ", " << TN << "], "
                  << "\"grid_mode\": \"" << gmode << "\""
                  << "\n}" << std::endl;
        return 0;
    }

    auto launch = [&]() -> CUresult {
        return cuLaunchKernel(kernel, gx, gy, 1, local[0], local[1], local[2],
                              (unsigned)shared_bytes, nullptr, params.data(), nullptr);
    };

    for (int i = 0; i < warmup; ++i) {
        CU_OK(launch(), "warmup launch");
    }
    CU_OK(cuCtxSynchronize(), "sync after warmup");

    // ---- timed loop ------------------------------------------------------------------------
    // Each iteration is synchronised and timed individually.  Batching submissions and dividing
    // is what inflated the L0 numbers by exactly `iters` (see the l0-mma-bench timing bug) --
    // a correctness check cannot catch that, so the shape of the loop is the defence.
    std::vector<double> us;
    us.reserve((size_t)std::max(iters, 1));
    auto t_w0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; ++i) {
        auto t0 = std::chrono::high_resolution_clock::now();
        CU_OK(launch(), "timed launch");
        CU_OK(cuCtxSynchronize(), "sync in timed loop");
        auto t1 = std::chrono::high_resolution_clock::now();
        us.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    auto t_w1 = std::chrono::high_resolution_clock::now();
    const double wall_us = iters > 0
        ? std::chrono::duration<double, std::micro>(t_w1 - t_w0).count() / iters
        : 0.0;

    std::sort(us.begin(), us.end());
    const double median_us = us.empty() ? 0.0 : us[us.size() / 2];
    const double min_us    = us.empty() ? 0.0 : us.front();
    const double gflops    = median_us > 0.0 ? (2.0 * (double)M * N * K) / (median_us * 1e3) : 0.0;

    CU_OK(cuMemcpyDtoH(C.data(), dC, C.size() * sizeof(float)), "D2H C");

    // ---- verification --------------------------------------------------------------------
    // Strided samples across the WHOLE output, not a top-left corner: a corner is the same price
    // and blind to every tile it does not reach.  A fast wrong kernel must never look like a win.
    bool verified = true;
    double max_abs_err = 0.0;
    uint64_t checked = 0;
    {
        auto ga = [&](uint64_t i) -> float {
            if (elem == "bf16") return bf16_to_f32(((uint16_t *)A.data())[i]);
            if (elem == "f16")  return f16_to_f32(((uint16_t *)A.data())[i]);
            return ((float *)A.data())[i];
        };
        auto gb = [&](uint64_t i) -> float {
            if (elem == "bf16") return bf16_to_f32(((uint16_t *)B.data())[i]);
            if (elem == "f16")  return f16_to_f32(((uint16_t *)B.data())[i]);
            return ((float *)B.data())[i];
        };
        const uint64_t smax = 64;
        uint64_t si = (M + smax - 1) / smax; if (si == 0) si = 1;
        uint64_t sj = (N + smax - 1) / smax; if (sj == 0) sj = 1;
        for (uint64_t i = 0; i < M && verified; i += si)
            for (uint64_t j = 0; j < N; j += sj) {
                ++checked;
                double acc = 0.0;
                for (uint64_t k = 0; k < K; ++k) acc += (double)ga(i * K + k) * (double)gb(k * N + j);
                double got = (double)C[i * N + j];
                double err = std::fabs(got - acc);
                double tol = 1e-3 * std::max(1.0, std::fabs(acc));
                if (err > max_abs_err) max_abs_err = err;
                if (err > tol) { verified = false; break; }
            }
    }

    std::cout << "{\n"
              << "  \"implementation\": \"crisp_cuda_fixture\",\n"
              << "  \"kernel\": \"" << kname << "\",\n"
              << "  \"M\": " << M << ", \"N\": " << N << ", \"K\": " << K << ",\n"
              << "  \"elem\": \"" << elem << "\", \"grid_mode\": \"" << gmode << "\",\n"
              << "  \"block\": [" << local[0] << ", " << local[1] << ", " << local[2] << "],\n"
              << "  \"grid\": [" << gx << ", " << gy << ", 1],\n"
              << "  \"shared_bytes\": " << shared_bytes << ",\n"
              << "  \"verified\": " << (verified ? "true" : "false") << ",\n"
              << "  \"correct\": " << (verified ? "true" : "false") << ",\n"
              << "  \"max_abs_err\": " << max_abs_err << ",\n"
              << "  \"verify_samples\": " << checked << ",\n"
              << "  \"driver_jit_ms\": " << driver_jit_ms << ",\n"
              << "  \"kernel_create_ms\": " << kernel_create_ms << ",\n"
              << "  \"wall_time_ms\": " << (wall_us / 1000.0) << ",\n"
              << "  \"wall_per_iter_us\": " << wall_us << ",\n"
              << "  \"gflops_from_wall\": "
              << (wall_us > 0.0 ? (2.0 * (double)M * N * K) / (wall_us * 1e3) : 0.0) << ",\n"
              << "  \"kernel_median_us\": " << median_us << ",\n"
              << "  \"kernel_min_us\": " << min_us << ",\n"
              << "  \"gflops\": " << gflops << "\n"
              << "}" << std::endl;

    for (CUdeviceptr t : tmap_dev) cuMemFree(t);
    cuMemFree(dA); cuMemFree(dB); cuMemFree(dC);
    cuModuleUnload(module);
    cuCtxDestroy(ctx);
    return verified ? 0 : 3;
}
