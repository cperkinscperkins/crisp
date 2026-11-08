/*
 * CUTLASS 4.x BLACKWELL (SM100, tcgen05) dense GEMM -- the PEER for section 2 on a B200 (endeavour 209).
 *
 * ONE source for every dense format, so the B200 peer rows differ only in the format: each lane
 * directory has a two-line wrapper that defines one of
 *     CB_ELEM_TF32   fp32 buffers, tf32 MMA, fp32 C        (sec2_top)
 *     CB_ELEM_BF16   bf16 A/B, fp32 accumulator and C       (sec2_top_bf16)
 *     CB_ELEM_F16    fp16 A/B, fp32 accumulator and C       (sec2_top_fp16)
 *     CB_ELEM_S8     s8 A/B, s32 accumulator and C          (sec2_top_int8)
 * and includes this file.  The computation is the one cuBLAS / cuBLASLt and Crisp are asked for in
 * the same directory: A row-major, B column-major (K-contiguous, "TN"), C row-major.
 *
 * The Hopper peers (cutlass_peer*.cu, Sm90 collective) need wgmma and cannot run here; this is
 * their Blackwell counterpart, the same apparatus with cutlass::arch::Sm100:
 *   * the fill and the strided verification are common/fill_cuda.cuh's, as for every contender;
 *   * can_implement / initialize / run are all checked, and a config that cannot run exits
 *     non-zero with "correct": false -- never a timed no-op (see sec2_top_bf16/cutlass_peer_bf16.cu);
 *   * schedules are KernelScheduleAuto / EpilogueScheduleAuto.
 *
 * THE SWEEP IS ALSO THE 1-SM vs 2-SM QUESTION.  The SM100 builder chooses cta_group::1 or ::2 from
 * the MMA tile and cluster: an M=256 tile on a cluster of 2 along M is the 2-SM MMA, which Crisp
 * does not emit (endeavour 208 built cta_group::1 only).  Sweeping both shapes measures how much of
 * any Crisp gap that instruction is.
 *
 *   -DCFG_TILE_M / -DCFG_TILE_N       MMA tile (default 128 x 256); K is 128 BYTES of the element
 *   -DCFG_CLUSTER_M / -DCFG_CLUSTER_N cluster (default 1 x 1)
 *
 * Build: nvcc -O3 -std=c++17 -arch=sm_100a -I<cutlass>/include -I<cutlass>/tools/util/include <wrapper>.cu
 * Run:   ./<bin> [M] [N] [K] [warmup] [iters]
 */
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
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

#if defined(CB_ELEM_TF32)
#define CB_ELEM_NAME "tf32"
#define CB_FILL "f32"
#define CB_VERIFY "f32"
#define CB_KTILE 32
#elif defined(CB_ELEM_BF16)
#define CB_ELEM_NAME "bf16"
#define CB_FILL "bf16"
#define CB_VERIFY "f32"
#define CB_KTILE 64
#elif defined(CB_ELEM_F16)
#define CB_ELEM_NAME "f16"
#define CB_FILL "f16"
#define CB_VERIFY "f32"
#define CB_KTILE 64
#elif defined(CB_ELEM_S8)
#define CB_ELEM_NAME "s8"
#define CB_FILL "s8"
#define CB_VERIFY "s32"
#define CB_KTILE 128
#else
#error "define one of CB_ELEM_TF32 / CB_ELEM_BF16 / CB_ELEM_F16 / CB_ELEM_S8"
#endif

#define CFG_STR2(x) #x
#define CFG_STR(x) CFG_STR2(x)
#define CFG_NAME "sm100_" CB_ELEM_NAME "_" CFG_STR(CFG_TILE_M) "x" CFG_STR(CFG_TILE_N) "x" CFG_STR(CB_KTILE) \
                 "_c" CFG_STR(CFG_CLUSTER_M) CFG_STR(CFG_CLUSTER_N)

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
    fprintf(stderr, "cutlass_peer_sm100 [%s]: %s FAILED (%s) at M=%d N=%d K=%d -- this config did NOT run.\n",
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
    auto wall_start = std::chrono::high_resolution_clock::now();

#if defined(CB_ELEM_TF32)
    using ElementA = cutlass::tfloat32_t;  using ElementB = cutlass::tfloat32_t;
    using ElementC = float;                using ElementAccumulator = float;
    using ElementCompute = float;
#elif defined(CB_ELEM_BF16)
    using ElementA = cutlass::bfloat16_t;  using ElementB = cutlass::bfloat16_t;
    using ElementC = float;                using ElementAccumulator = float;
    using ElementCompute = float;
#elif defined(CB_ELEM_F16)
    using ElementA = cutlass::half_t;      using ElementB = cutlass::half_t;
    using ElementC = float;                using ElementAccumulator = float;
    using ElementCompute = float;
#else
    using ElementA = int8_t;               using ElementB = int8_t;
    using ElementC = int32_t;              using ElementAccumulator = int32_t;
    using ElementCompute = float;          // alpha = 1, beta = 0 -- exact
#endif
    using LayoutA = cutlass::layout::RowMajor;
    using LayoutB = cutlass::layout::ColumnMajor;
    using LayoutC = cutlass::layout::RowMajor;
    static constexpr int AlignA = 128 / cutlass::sizeof_bits<ElementA>::value;
    static constexpr int AlignB = 128 / cutlass::sizeof_bits<ElementB>::value;
    static constexpr int AlignC = 128 / cutlass::sizeof_bits<ElementC>::value;

    using MmaTileShape = cute::Shape<cute::Int<CFG_TILE_M>, cute::Int<CFG_TILE_N>, cute::Int<CB_KTILE>>;
    using ClusterShape = cute::Shape<cute::Int<CFG_CLUSTER_M>, cute::Int<CFG_CLUSTER_N>, cute::_1>;

    using CollectiveEpilogue = typename cutlass::epilogue::collective::CollectiveBuilder<
        cutlass::arch::Sm100, cutlass::arch::OpClassTensorOp,
        MmaTileShape, ClusterShape,
        cutlass::epilogue::collective::EpilogueTileAuto,
        ElementAccumulator, ElementCompute,
        ElementC, LayoutC, AlignC,
        ElementC, LayoutC, AlignC,
        cutlass::epilogue::collective::EpilogueScheduleAuto
    >::CollectiveOp;

    using CollectiveMainloop = typename cutlass::gemm::collective::CollectiveBuilder<
        cutlass::arch::Sm100, cutlass::arch::OpClassTensorOp,
        ElementA, LayoutA, AlignA,
        ElementB, LayoutB, AlignB,
        ElementAccumulator,
        MmaTileShape, ClusterShape,
        cutlass::gemm::collective::StageCountAutoCarveout<
            static_cast<int>(sizeof(typename CollectiveEpilogue::SharedStorage))>,
        cutlass::gemm::collective::KernelScheduleAuto
    >::CollectiveOp;

    using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
        cute::Shape<int, int, int, int>, CollectiveMainloop, CollectiveEpilogue>;
    using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;

    ElementA *dA; ElementB *dB; ElementC *dC;
    cudaMalloc(&dA, sizeof(ElementA) * (size_t)M * K);
    cudaMalloc(&dB, sizeof(ElementB) * (size_t)K * N);
    cudaMalloc(&dC, sizeof(ElementC) * (size_t)M * N);
    crisp_bench::cuda_fill_encoded(dA, (uint64_t)M * K, crisp_bench::FILL_MOD_A, CB_FILL);
    crisp_bench::cuda_fill_encoded(dB, (uint64_t)K * N, crisp_bench::FILL_MOD_B, CB_FILL);

    using StrideA = typename Gemm::GemmKernel::StrideA;
    using StrideB = typename Gemm::GemmKernel::StrideB;
    using StrideC = typename Gemm::GemmKernel::StrideC;
    using StrideD = typename Gemm::GemmKernel::StrideD;
    StrideA sA = cutlass::make_cute_packed_stride(StrideA{}, cute::make_shape(M, K, 1));
    StrideB sB = cutlass::make_cute_packed_stride(StrideB{}, cute::make_shape(N, K, 1));
    StrideC sC = cutlass::make_cute_packed_stride(StrideC{}, cute::make_shape(M, N, 1));
    StrideD sD = cutlass::make_cute_packed_stride(StrideD{}, cute::make_shape(M, N, 1));

    typename Gemm::Arguments args{
        cutlass::gemm::GemmUniversalMode::kGemm,
        {M, N, K, 1},
        {dA, sA, dB, sB},
        {{ElementCompute(1), ElementCompute(0)}, dC, sC, dC, sD}
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
        dC, CB_VERIFY, (uint64_t)M, (uint64_t)N, (uint64_t)K,
        crisp_bench::rm(K), crisp_bench::cm(K), crisp_bench::rm(N));

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

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return vr.verified ? 0 : 1;
#else
    // FAIL LOUDLY (see sec2_top/cutlass_peer.cu): a contender that cannot run is a VISIBLE GAP.
    fprintf(stderr, "cutlass_peer_sm100 [%s]: CUTLASS headers not found at build time -- this contender "
                    "did NOT run.  Run scripts/setup-third-party.sh cutlass.\n", CFG_NAME);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"correct\": false,\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    (void)M; (void)N; (void)K; (void)warmup; (void)iters;
    return 2;
#endif
}
