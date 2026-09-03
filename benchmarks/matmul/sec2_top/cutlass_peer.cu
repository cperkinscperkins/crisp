/*
 * CUTLASS 3.x Hopper TMA warp-specialized tf32 GEMM — the PEER for §2 (NVIDIA).
 *
 * Structural twin of sec2_top_fp16/cutlass_peer_fp16.cu and sec2_top_bf16/cutlass_peer_bf16.cu;
 * the only intended differences are ElementA/ElementB (cutlass::tfloat32_t), the 128-bit
 * alignment in elements (4 for a 32-bit type, 8 for a 16-bit one) and the default K tile.
 *
 * THIS FILE WAS REWRITTEN 2026-08-29 (endeavour 159) AFTER IT RAN FOR THE FIRST TIME, and what
 * it measured on first contact is the reason for every change below.  Three defects, each of
 * which made the published Peer column wrong in a different way:
 *
 * 1. IT HAD NEVER COMPILED, ANYWHERE.  CUTLASS 3.x takes a 3-ELEMENT stride (row, col, BATCH)
 *    and this file passed the 2-element form, so nvcc rejected it:
 *        no instance of constructor "cute::tuple<T...>::tuple [with T=<int64_t, C<1>, int64_t>]"
 *    Every CUTLASS build in this tree failed the same way, tf32 and 16-bit alike.  Strides now
 *    come from cutlass::make_cute_packed_stride, which derives them from the kernel's own StrideX
 *    tag -- so the ColumnMajor B operand's batch term is not hand-derived.  That header lives in
 *    tools/util/include, which the build must therefore ALSO carry as an include path.
 *
 * 2. THE PINNED SCHEDULE COST ~1.4x, AND COUPLED TO THE TILE.  This file named
 *    cutlass::gemm::KernelTmaWarpSpecialized explicitly.  Measured on an H100 NVL, that schedule
 *    does not merely fail to help a large tile -- it COLLAPSES it, by 6x to 14x:
 *
 *        tf32 TFLOPS @4096   64x256x32   128x128x32   128x256x32   256x128x32
 *        pinned                  219.3        180.8         22.9         39.8
 *        KernelScheduleAuto      208.9        258.7        316.5        297.2
 *
 *    Pinned, the shipped 64x256x32 looked like the best tile available, and it was -- under that
 *    schedule.  On Auto the ranking inverts and the best configuration is 1.40-1.44x the shipped
 *    number at every size from 2048 up.  The peer was under-reporting CUTLASS by ~1.4x, which is
 *    the sort of error that makes a Crisp/peer ratio flattering for no earned reason.  Auto now,
 *    so CUTLASS picks the cooperative or pingpong variant each tile actually wants.
 *
 * 3. IT DISCARDED EVERY cutlass::Status.  can_implement(), initialize() and run() each return one
 *    and all three returns were dropped.  For one fixed shape that is sloppy; for the config
 *    sweep this file now supports it is a correctness hazard, because a non-implementable config
 *    would run anyway and report a time for a GEMM that did not happen.  All checked; every
 *    failure exits non-zero and prints correct:false, which the driver turns into a dropped point
 *    with a printed reason rather than a silent zero.
 *
 * Corrected, the tf32 peer reaches 74-82% of cuBLAS at 2048-8192, which is finally in the same
 * band as the 16-bit peers (76-85%) instead of the 52-57% it used to report.
 *
 *   -DCFG_TILE_M/-DCFG_TILE_N/-DCFG_TILE_K          CTA tile (default 128x256x32)
 *   -DCFG_CLUSTER_M/-DCFG_CLUSTER_N/-DCFG_CLUSTER_K threadblock cluster (default 1x1x1)
 *
 * The resolved configuration is printed into the result JSON as "config", so a number in the
 * report can be traced to the shape that produced it without consulting the build command.
 *
 * Build: nvcc -O3 -std=c++17 -arch=sm_90a -I<cutlass>/include -I<cutlass>/tools/util/include \
 *             cutlass_peer.cu -o <bin>
 * Run:   ./<bin> [M] [N] [K] [warmup] [iters]
 */
#include <iostream>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#ifndef CFG_TILE_M
#define CFG_TILE_M 128
#endif
#ifndef CFG_TILE_N
#define CFG_TILE_N 256
#endif
#ifndef CFG_TILE_K
#define CFG_TILE_K 32
#endif
#ifndef CFG_CLUSTER_M
#define CFG_CLUSTER_M 1
#endif
#ifndef CFG_CLUSTER_N
#define CFG_CLUSTER_N 1
#endif
#ifndef CFG_CLUSTER_K
#define CFG_CLUSTER_K 1
#endif

#define CFG_STR2(x) #x
#define CFG_STR(x) CFG_STR2(x)
#define CFG_NAME CFG_STR(CFG_TILE_M) "x" CFG_STR(CFG_TILE_N) "x" CFG_STR(CFG_TILE_K) \
                 "_c" CFG_STR(CFG_CLUSTER_M) CFG_STR(CFG_CLUSTER_N) CFG_STR(CFG_CLUSTER_K)

#if __has_include(<cutlass/cutlass.h>)
#include <cuda_runtime.h>
#include <cutlass/cutlass.h>
#include <cutlass/numeric_types.h>
#include <cutlass/gemm/device/gemm_universal_adapter.h>
#include <cutlass/gemm/collective/collective_builder.hpp>
#include <cutlass/epilogue/collective/collective_builder.hpp>
#include <cutlass/util/packed_stride.hpp>
#define HAS_CUTLASS 1
#else
#define HAS_CUTLASS 0
#endif

int main(int argc, char** argv) {
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

#if HAS_CUTLASS
    auto wall_start = std::chrono::high_resolution_clock::now();

    // OPERAND tf32, ACCUMULATOR f32, C f32 — the same computation cublas_ceiling.cu is asked for
    // and the same one Crisp's tensor-core path performs.  Alignment is 4 ELEMENTS (= 128 bits)
    // for a 32-bit type; the 16-bit peers use 8.  It tracks the element width, it is not a free
    // parameter.
    using ElementA = cutlass::tfloat32_t;
    using LayoutA  = cutlass::layout::RowMajor;
    using ElementB = cutlass::tfloat32_t;
    using LayoutB  = cutlass::layout::ColumnMajor;
    using ElementC = float;
    using LayoutC  = cutlass::layout::RowMajor;
    using ElementAccumulator = float;
    static constexpr int AlignA = 4;
    static constexpr int AlignB = 4;
    static constexpr int AlignC = 4;

    using TileShape    = cute::Shape<cute::Int<CFG_TILE_M>, cute::Int<CFG_TILE_N>, cute::Int<CFG_TILE_K>>;
    using ClusterShape = cute::Shape<cute::Int<CFG_CLUSTER_M>, cute::Int<CFG_CLUSTER_N>, cute::Int<CFG_CLUSTER_K>>;

    using CollectiveEpilogue = typename cutlass::epilogue::collective::CollectiveBuilder<
        cutlass::arch::Sm90, cutlass::arch::OpClassTensorOp,
        TileShape, ClusterShape,
        cutlass::epilogue::collective::EpilogueTileAuto,
        ElementAccumulator, ElementAccumulator,
        ElementC, LayoutC, AlignC,
        ElementC, LayoutC, AlignC,
        cutlass::epilogue::collective::EpilogueScheduleAuto
    >::CollectiveOp;

    using CollectiveMainloop = typename cutlass::gemm::collective::CollectiveBuilder<
        cutlass::arch::Sm90, cutlass::arch::OpClassTensorOp,
        ElementA, LayoutA, AlignA,
        ElementB, LayoutB, AlignB,
        ElementAccumulator,
        TileShape, ClusterShape,
        cutlass::gemm::collective::StageCountAutoCarveout<sizeof(typename CollectiveEpilogue::SharedStorage)>,
        cutlass::gemm::collective::KernelScheduleAuto
    >::CollectiveOp;

    using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
        cute::Shape<int,int,int>,
        CollectiveMainloop,
        CollectiveEpilogue
    >;

    using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;

    std::vector<ElementA> hA((size_t)M * K, ElementA(1.0f));
    std::vector<ElementB> hB((size_t)K * N, ElementB(1.0f));
    std::vector<ElementC> hC((size_t)M * N, ElementC(0.0f));

    ElementA *dA; ElementB *dB; ElementC *dC;
    cudaMalloc(&dA, sizeof(ElementA) * (size_t)M * K);
    cudaMalloc(&dB, sizeof(ElementB) * (size_t)K * N);
    cudaMalloc(&dC, sizeof(ElementC) * (size_t)M * N);

    cudaMemcpy(dA, hA.data(), sizeof(ElementA) * (size_t)M * K, cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB.data(), sizeof(ElementB) * (size_t)K * N, cudaMemcpyHostToDevice);

    Gemm gemm_op;
    // CUTLASS 3.x STRIDES ARE 3-ELEMENT (row, col, BATCH).  See defect 1 in the header.
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
        {M, N, K},
        {dA, sA, dB, sB},
        {{1.0f, 0.0f}, dC, sC, dC, sD}
    };

    size_t workspace_size = Gemm::get_workspace_size(args);
    void* workspace = nullptr;
    if (workspace_size > 0) cudaMalloc(&workspace, workspace_size);

    // A config that cannot run must be a VISIBLE GAP, never a timed no-op.  See defect 3.
    auto bail = [&](const char* where, cutlass::Status st) {
        fprintf(stderr, "cutlass_peer [%s]: %s FAILED (%s) at M=%d N=%d K=%d — this config did "
                        "NOT run.\n", CFG_NAME, where, cutlassGetStatusString(st), M, N, K);
        printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
        printf("  \"config\": \"%s\",\n", CFG_NAME);
        printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
        printf("  \"correct\": false,\n");
        printf("  \"error\": \"%s %s\"\n}\n", where, cutlassGetStatusString(st));
        return 2;
    };

    cutlass::Status st = gemm_op.can_implement(args);
    if (st != cutlass::Status::kSuccess) return bail("can_implement", st);
    st = gemm_op.initialize(args, workspace);
    if (st != cutlass::Status::kSuccess) return bail("initialize", st);

    for (int i = 0; i < warmup; i++) {
        st = gemm_op.run();
        if (st != cutlass::Status::kSuccess) return bail("run(warmup)", st);
    }
    cudaDeviceSynchronize();

    std::vector<float> kt(iters);
    cudaEvent_t s, e;
    cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s);
        st = gemm_op.run();
        cudaEventRecord(e);
        cudaEventSynchronize(e);
        if (st != cutlass::Status::kSuccess) return bail("run", st);
        cudaEventElapsedTime(&kt[i], s, e);
    }

    cudaMemcpy(hC.data(), dC, sizeof(ElementC) * (size_t)M * N, cudaMemcpyDeviceToHost);
    double expected = (double)K, maxerr = 0.0;
    for (size_t i = 0; i < hC.size(); i++) maxerr = std::max(maxerr, (double)std::fabs(hC[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2] * 1000.0;
    double k_min = kt[0] * 1000.0;
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return correct ? 0 : 1;
#else
    /* FAIL LOUDLY.  This used to print the error and `return 0`, so a build without the CUTLASS
       headers looked to the driver exactly like a successful run that happened to measure 0.0
       TFLOPS at every size.  Combined with the CUB/CUBLAS classification bug that put cuBLAS in
       the peer column, the published table then asserted CUTLASS had been measured and matched
       cuBLAS exactly -- at every size, on hardware where it had never run at all.

       A contender that cannot run must be a VISIBLE GAP, not a silent zero.  stderr so the
       reason survives in the log; non-zero exit so the driver records the point as failed. */
    fprintf(stderr, "cutlass_peer [%s]: CUTLASS headers not found at build time — this contender "
                    "did NOT run.  Run scripts/setup-third-party.sh cutlass.\n", CFG_NAME);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"correct\": false,\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    return 2;
#endif
}
