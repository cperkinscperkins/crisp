/*
 * CUTLASS 4.x BLACKWELL BLOCK-SCALED GEMM -- the PEER for the NVFP4 / MXFP4 / MXFP8 lanes on a B200
 * (endeavour 209).  Built from CUTLASS's examples/72_blackwell_narrow_precision_gemm, with the
 * contract of the Crisp block kernels and of common/cublaslt_blockscaled.cuh:
 *     A  M x K codes, row-major          B  K x N codes, column-major (both K-contiguous)
 *     SA / SB  scales in the :blocked-128x4 layout (CUTLASS's Sm1xx SF layout is the same atom)
 *     C  M x N fp32 row-major, D = A.B (alpha 1, beta 0), no output quantization
 * One source; each lane's wrapper defines CB_BLOCK_NVFP4 / CB_BLOCK_MXFP4 / CB_BLOCK_MXFP8.
 *
 * The fill and the block-scaled oracle are common/fill_cuda.cuh's, as for every contender.  The
 * scale buffer is written in OUR layout and handed to CUTLASS through ITS layout object; the two
 * must describe the same bytes, so the size CUTLASS asks for is checked against ours and a
 * mismatch is a failure, not a guess.  (The verifier then catches any disagreement inside.)
 *
 *   -DCFG_TILE_M / -DCFG_TILE_N       MMA tile (default 128 x 256); K tile 128 bytes (256 fp4 / 128 fp8 codes)
 *   -DCFG_CLUSTER_M / -DCFG_CLUSTER_N cluster (default 1 x 1); M=256 with cluster M=2 is the 2-SM MMA
 *
 * --expt-relaxed-constexpr is REQUIRED (CUTLASS's own CMake passes it): the block-scaled mainloop calls
 * a constexpr host function from device code.  matmul.py adds it for this peer.
 *
 * Build: nvcc -O3 -std=c++17 --expt-relaxed-constexpr -arch=sm_100a -I<cutlass>/include -I<cutlass>/tools/util/include <wrapper>.cu
 */
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#ifndef CFG_TILE_M
#define CFG_TILE_M 128
#endif
#ifndef CFG_TILE_N
#define CFG_TILE_N 256
#endif
#ifndef CFG_CLUSTER_M
#define CFG_CLUSTER_M 1
#endif
#ifndef CFG_CLUSTER_N
#define CFG_CLUSTER_N 1
#endif

#if defined(CB_BLOCK_NVFP4)
#define CB_NAME "nvfp4"
#define CB_BASE "fp4"
#define CB_SCALE "fp8-e4m3"
#define CB_VEC 16
#elif defined(CB_BLOCK_MXFP4)
#define CB_NAME "mxfp4"
#define CB_BASE "fp4"
#define CB_SCALE "fp8-e8m0"
#define CB_VEC 32
#elif defined(CB_BLOCK_MXFP8)
#define CB_NAME "mxfp8"
#define CB_BASE "fp8-e4m3"
#define CB_SCALE "fp8-e8m0"
#define CB_VEC 32
#define CB_KTILE 128           // 128 fp8 codes = 128 bytes; a 256-code K tile overflows shared memory
#else
#error "define one of CB_BLOCK_NVFP4 / CB_BLOCK_MXFP4 / CB_BLOCK_MXFP8"
#endif
#ifndef CB_KTILE
#define CB_KTILE 256           // 256 fp4 codes = 128 bytes
#endif

#define CFG_STR2(x) #x
#define CFG_STR(x) CFG_STR2(x)
#define CFG_NAME "sm100_" CB_NAME "_" CFG_STR(CFG_TILE_M) "x" CFG_STR(CFG_TILE_N) "x" CFG_STR(CB_KTILE) "_c" \
                 CFG_STR(CFG_CLUSTER_M) CFG_STR(CFG_CLUSTER_N)

#if __has_include(<cutlass/cutlass.h>)
#include <cuda_runtime.h>
#include "fill_cuda.cuh"
#include <cutlass/cutlass.h>
#include <cutlass/numeric_types.h>
#include <cutlass/gemm/device/gemm_universal_adapter.h>
#include <cutlass/gemm/collective/collective_builder.hpp>
#include <cutlass/epilogue/collective/collective_builder.hpp>
#include <cutlass/gemm/kernel/gemm_universal.hpp>
#include <cutlass/util/packed_stride.hpp>
#define HAS_CUTLASS 1
#else
#define HAS_CUTLASS 0
#endif

static int cb_fail_json(const char *where, const char *what, int M, int N, int K) {
    fprintf(stderr, "cutlass_peer_sm100_bs [%s]: %s FAILED (%s) at M=%d N=%d K=%d -- this config did NOT run.\n",
            CFG_NAME, where, what, M, N, K);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
    printf("  \"correct\": false,\n  \"error\": \"%s %s\"\n}\n", where, what);
    return 2;
}

int main(int argc, char **argv) {
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

#if HAS_CUTLASS
    using namespace cute;
    auto wall_start = std::chrono::high_resolution_clock::now();

#if defined(CB_BLOCK_NVFP4)
    using ElementA = cutlass::nv_float4_t<cutlass::float_e2m1_t>;
    using ElementB = cutlass::nv_float4_t<cutlass::float_e2m1_t>;
    static constexpr int AlignA = 32, AlignB = 32;
#elif defined(CB_BLOCK_MXFP4)
    using ElementA = cutlass::mx_float4_t<cutlass::float_e2m1_t>;
    using ElementB = cutlass::mx_float4_t<cutlass::float_e2m1_t>;
    static constexpr int AlignA = 32, AlignB = 32;
#else
    using ElementA = cutlass::mx_float8_t<cutlass::float_e4m3_t>;
    using ElementB = cutlass::mx_float8_t<cutlass::float_e4m3_t>;
    static constexpr int AlignA = 16, AlignB = 16;
#endif
    // NO SOURCE OPERAND (ElementC = void): D = A.B with beta 0, exactly the contract.  With a float C
    // the epilogue's carve-out leaves no shared memory for the A/B/SF stages of a 256-code K tile
    // ("Smem usage is too high"); the source would only ever have been multiplied by zero.
    using ElementC = void;
    using ElementD = float;
    using ElementAccumulator = float;
    using LayoutA = cutlass::layout::RowMajor;
    using LayoutB = cutlass::layout::ColumnMajor;
    using LayoutC = cutlass::layout::RowMajor;
    static constexpr int AlignC = 128 / cutlass::sizeof_bits<ElementD>::value;

    using MmaTileShape = Shape<Int<CFG_TILE_M>, Int<CFG_TILE_N>, Int<CB_KTILE>>;
    using ClusterShape = Shape<Int<CFG_CLUSTER_M>, Int<CFG_CLUSTER_N>, _1>;

    using CollectiveEpilogue = typename cutlass::epilogue::collective::CollectiveBuilder<
        cutlass::arch::Sm100, cutlass::arch::OpClassBlockScaledTensorOp,
        MmaTileShape, ClusterShape,
        cutlass::epilogue::collective::EpilogueTileAuto,
        ElementAccumulator, ElementAccumulator,
        ElementC, LayoutC, AlignC,
        ElementD, LayoutC, AlignC,
        cutlass::epilogue::collective::EpilogueScheduleAuto
    >::CollectiveOp;

    using CollectiveMainloop = typename cutlass::gemm::collective::CollectiveBuilder<
        cutlass::arch::Sm100, cutlass::arch::OpClassBlockScaledTensorOp,
        ElementA, LayoutA, AlignA,
        ElementB, LayoutB, AlignB,
        ElementAccumulator,
        MmaTileShape, ClusterShape,
        cutlass::gemm::collective::StageCountAutoCarveout<
            static_cast<int>(sizeof(typename CollectiveEpilogue::SharedStorage))>,
        cutlass::gemm::collective::KernelScheduleAuto
    >::CollectiveOp;

    using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
        Shape<int, int, int, int>, CollectiveMainloop, CollectiveEpilogue, void>;
    using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;
    using Mainloop  = typename Gemm::GemmKernel::CollectiveMainloop;
    using SfConfig  = typename Mainloop::Sm1xxBlkScaledConfig;
    using ElemAData = typename Gemm::ElementA;
    using ElemBData = typename Gemm::ElementB;
    using ElemSF    = typename Mainloop::ElementSF;

    // ---- buffers: OUR codes and OUR :blocked-128x4 scales ------------------------------------
    const uint64_t nA = (uint64_t)M * K, nB = (uint64_t)K * N;
    const uint64_t epb = (std::string(CB_BASE) == "fp4") ? 2 : 1;
    const uint64_t bSA = crisp_bench::mf_scales_bytes(M, K, CB_VEC), bSB = crisp_bench::mf_scales_bytes(N, K, CB_VEC);
    uint8_t *dA, *dB, *dSA, *dSB; float *dC;
    cudaMalloc(&dA, nA / epb); cudaMalloc(&dB, nB / epb);
    cudaMalloc(&dSA, bSA);     cudaMalloc(&dSB, bSB);
    cudaMalloc(&dC, (size_t)M * N * sizeof(float));
    crisp_bench::cuda_fill_mf_codes(dA, nA, crisp_bench::FILL_MOD_A, CB_BASE);
    crisp_bench::cuda_fill_mf_codes(dB, nB, crisp_bench::FILL_MOD_B, CB_BASE);
    crisp_bench::cuda_fill_mf_scales(dSA, M, K, CB_VEC, CB_SCALE);
    crisp_bench::cuda_fill_mf_scales(dSB, N, K, CB_VEC, CB_SCALE);

    using StrideA = typename Gemm::GemmKernel::StrideA;
    using StrideB = typename Gemm::GemmKernel::StrideB;
    using StrideC = typename Gemm::GemmKernel::StrideC;
    using StrideD = typename Gemm::GemmKernel::StrideD;
    StrideA sA = cutlass::make_cute_packed_stride(StrideA{}, make_shape(M, K, 1));
    StrideB sB = cutlass::make_cute_packed_stride(StrideB{}, make_shape(N, K, 1));
    StrideC sC = cutlass::make_cute_packed_stride(StrideC{}, make_shape(M, N, 1));
    StrideD sD = cutlass::make_cute_packed_stride(StrideD{}, make_shape(M, N, 1));
    auto layout_SFA = SfConfig::tile_atom_to_shape_SFA(make_shape(M, N, K, 1));
    auto layout_SFB = SfConfig::tile_atom_to_shape_SFB(make_shape(M, N, K, 1));
    // THE LAYOUT CHECK: CUTLASS's SF buffer must be exactly the size of ours (one byte per scale).
    const uint64_t cSA = (uint64_t)size(filter_zeros(layout_SFA)), cSB = (uint64_t)size(filter_zeros(layout_SFB));
    if (cSA != bSA || cSB != bSB) {
        char msg[160];
        snprintf(msg, sizeof msg, "SF sizes CUTLASS %llu/%llu vs blocked-128x4 %llu/%llu",
                 (unsigned long long)cSA, (unsigned long long)cSB, (unsigned long long)bSA, (unsigned long long)bSB);
        return cb_fail_json("scale layout", msg, M, N, K);
    }

    typename Gemm::Arguments args{
        cutlass::gemm::GemmUniversalMode::kGemm,
        {M, N, K, 1},
        {reinterpret_cast<ElemAData *>(dA), sA, reinterpret_cast<ElemBData *>(dB), sB,
         reinterpret_cast<ElemSF *>(dSA), layout_SFA, reinterpret_cast<ElemSF *>(dSB), layout_SFB},
        {{1.0f, 0.0f}, nullptr, sC, dC, sD}
    };

    Gemm gemm_op;
    size_t workspace_size = Gemm::get_workspace_size(args);
    void *workspace = nullptr;
    if (workspace_size > 0) cudaMalloc(&workspace, workspace_size);
    cutlass::Status st = gemm_op.can_implement(args);
    if (st != cutlass::Status::kSuccess) return cb_fail_json("can_implement", cutlassGetStatusString(st), M, N, K);
    st = gemm_op.initialize(args, workspace);
    if (st != cutlass::Status::kSuccess) return cb_fail_json("initialize", cutlassGetStatusString(st), M, N, K);

    for (int i = 0; i < warmup; i++) {
        st = gemm_op.run();
        if (st != cutlass::Status::kSuccess) return cb_fail_json("run(warmup)", cutlassGetStatusString(st), M, N, K);
    }
    cudaError_t ce = cudaDeviceSynchronize();
    if (ce != cudaSuccess) return cb_fail_json("warmup", cudaGetErrorString(ce), M, N, K);
    std::vector<float> kt(iters);
    cudaEvent_t s, e;
    cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s);
        st = gemm_op.run();
        cudaEventRecord(e);
        cudaEventSynchronize(e);
        if (st != cutlass::Status::kSuccess) return cb_fail_json("run", cutlassGetStatusString(st), M, N, K);
        cudaEventElapsedTime(&kt[i], s, e);
    }
    ce = cudaGetLastError();
    if (ce != cudaSuccess) return cb_fail_json("timed loop", cudaGetErrorString(ce), M, N, K);

    const crisp_bench::VerifyResult vr = crisp_bench::cuda_verify(
        dC, "f32", (uint64_t)M, (uint64_t)N, (uint64_t)K,
        crisp_bench::rm(K), crisp_bench::cm(K), crisp_bench::rm(N), {}, CB_VEC);

    std::sort(kt.begin(), kt.end());
    const double k_med = kt[iters / 2] * 1000.0, k_min = kt[0] * 1000.0;
    const double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;
    const double wall_time_ms = std::chrono::duration<double, std::milli>(
        std::chrono::high_resolution_clock::now() - wall_start).count();
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", vr.verified ? "true" : "false", vr.max_abs_err);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dSA); cudaFree(dSB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return vr.verified ? 0 : 1;
#else
    fprintf(stderr, "cutlass_peer_sm100_bs [%s]: CUTLASS headers not found at build time -- this contender "
                    "did NOT run.  Run scripts/setup-third-party.sh cutlass.\n", CFG_NAME);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"correct\": false,\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    (void)M; (void)N; (void)K; (void)warmup; (void)iters;
    return 2;
#endif
}
