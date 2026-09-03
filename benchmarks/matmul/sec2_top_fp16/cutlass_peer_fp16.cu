/*
 * CUTLASS 3.x Hopper TMA warp-specialized fp16 GEMM — the PEER for §2.1 (NVIDIA).
 *
 * Twin of sec2_top_bf16/cutlass_peer_bf16.cu; the ONLY intended difference is ElementA/ElementB
 * (cutlass::half_t vs cutlass::bfloat16_t).  If you change one, change both.
 *
 * WHY THIS ONE IS CONFIGURABLE AND THE tf32 PEER IS NOT.  sec2_top/cutlass_peer.cu hardcodes a
 * single 64x256x32 tile.  That is fine for a single ceiling-vs-peer row, but the premise of this
 * chapter is that NO ONE KERNEL FITS ALL N -- established on Intel, where the fp16 chapter
 * carries eleven Crisp variants and a sign-flip table.  A peer pinned to one shape cannot be
 * evidence for or against that premise on NVIDIA; it can only report how ONE shape does.
 *
 * So the tile and cluster are -D parameters and the driver instantiates several.  CUTLASS is the
 * right contender to sweep because, unlike cuBLAS, it does NOT choose for you: the shape is a
 * template argument, exactly as Crisp's is a source-level choice.  That makes the sweep do double
 * duty -- it measures the peer honestly AND maps the shape-vs-N ladder that tells us what Crisp's
 * own 16-bit variants should target.
 *
 *   -DCFG_TILE_M/-DCFG_TILE_N/-DCFG_TILE_K          CTA tile (default 128x128x64)
 *   -DCFG_CLUSTER_M/-DCFG_CLUSTER_N/-DCFG_CLUSTER_K threadblock cluster (default 1x1x1)
 *
 * The resolved configuration is printed into the result JSON as "config", so a number in the
 * report can be traced to the shape that produced it without consulting the build command.
 *
 * SCHEDULES ARE LEFT ON Auto DELIBERATELY.  Naming KernelTmaWarpSpecialized explicitly (as the
 * tf32 peer does) pins a schedule that is not valid for every tile in the sweep, and a schedule /
 * tile mismatch surfaces as a compile error deep in a template instantiation.  Auto lets CUTLASS
 * pick the cooperative or pingpong variant each tile actually wants.  Pin one only to answer a
 * specific question, and then say which in the config string.
 *
 * STATUS RETURNS ARE CHECKED HERE, AND THE tf32 PEER DOES NOT CHECK THEM.  can_implement() and
 * initialize() and run() each return a cutlass::Status and the original discards all three.  For
 * a single fixed shape that is merely sloppy; for a SWEEP it is a correctness hazard, because
 * some tile/cluster combinations are legitimately not implementable on a given problem and the
 * discarded status is the only place CUTLASS says so.  Unchecked, such a config runs anyway and
 * reports a time for a GEMM that did not happen.  This tree has published a fabricated CUTLASS
 * row once already; every status is checked and every failure exits non-zero.
 *
 * Build: nvcc -O3 -std=c++17 -arch=sm_90a -I<cutlass>/include cutlass_peer_fp16.cu -o <bin>
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
#define CFG_TILE_N 128
#endif
#ifndef CFG_TILE_K
#define CFG_TILE_K 64
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

    // OPERAND fp16, ACCUMULATOR f32, C f32 — the same computation cuBLAS is asked for in
    // cublas_ceiling_fp16.cu and the same one Crisp's tensor-core path performs.  Alignment is
    // 8 ELEMENTS (= 128 bits) for a 16-bit type; the tf32 peer's 4 is 128 bits of a 32-bit type,
    // so this number tracks the element width and is not a free parameter.
    using ElementA = cutlass::half_t;
    using LayoutA  = cutlass::layout::RowMajor;
    using ElementB = cutlass::half_t;
    using LayoutB  = cutlass::layout::ColumnMajor;
    using ElementC = float;
    using LayoutC  = cutlass::layout::RowMajor;
    using ElementAccumulator = float;
    static constexpr int AlignA = 8;
    static constexpr int AlignB = 8;
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
    // CUTLASS 3.x STRIDES ARE 3-ELEMENT (row, col, BATCH).  This file previously passed the
    // 2-element form, which is why no CUTLASS contender in this tree had ever compiled.
    // make_cute_packed_stride derives each stride from the kernel's own StrideX tag, so the
    // ColumnMajor B operand does not need its batch term hand-derived (the easy one to get wrong).
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

    // A config that cannot run must be a VISIBLE GAP, never a timed no-op.  See the header.
    auto bail = [&](const char* where, cutlass::Status st) {
        fprintf(stderr, "cutlass_peer_fp16 [%s]: %s FAILED (%s) at M=%d N=%d K=%d — this config "
                        "did NOT run.\n", CFG_NAME, where, cutlassGetStatusString(st), M, N, K);
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
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return correct ? 0 : 1;
#else
    /* FAIL LOUDLY.  See sec2_top/cutlass_peer.cu for the full history: a build without the
       CUTLASS headers used to print an error and return 0, which looked to the driver exactly
       like a successful run measuring 0.0 TFLOPS, and the published table then asserted CUTLASS
       had been measured on hardware where it never ran.  A contender that cannot run must be a
       VISIBLE GAP. */
    fprintf(stderr, "cutlass_peer_fp16 [%s]: CUTLASS headers not found at build time — this "
                    "contender did NOT run.  Run scripts/setup-third-party.sh cutlass.\n", CFG_NAME);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"correct\": false,\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    return 2;
#endif
}
