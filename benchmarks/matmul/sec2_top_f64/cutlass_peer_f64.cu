/*
 * CUTLASS fp64 tensor-core GEMM — the PEER for §2 (NVIDIA) at 64 bits.
 *
 * WHY THIS IS THE 2.x DEVICE API AND NOT A COPY OF sec2_top/cutlass_peer.cu.
 *
 * The tf32 and 16-bit peers are CUTLASS 3.x: CollectiveBuilder on arch::Sm90 with
 * OpClassTensorOp.  That machinery is built on Hopper's WARPGROUP MMA (wgmma), and **there is no
 * fp64 wgmma** -- Hopper's warpgroup instruction covers fp16/bf16/tf32/fp8/int8 and stops there.
 * So the Sm90 collective builder has no dispatch policy for `double` and a typedef swap on the
 * existing peer cannot work, however plausible it looks.
 *
 * fp64 tensor cores are reached through the SM80-class DMMA path (`mma.sync.aligned.m8n8k4.f64`),
 * which in CUTLASS is the 2.x `device::Gemm` with arch::Sm80.  Those kernels compile and run on
 * sm_90 -- the instruction exists there -- they simply are not warpgroup kernels.  This file is
 * therefore a sibling of the tf32 peer in ROLE, not in code.
 *
 * THE INSTRUCTION SHAPE IS NOT A TUNING KNOB.  8x8x4 is the only fp64 tensor-core shape CUTLASS
 * can target here, and it is also the only one our LLVM can emit (verified: LLVM 21.1.5 lowers
 * llvm.nvvm.mma.m8n8k4.row.col.f64 to a real instruction, and silently turns the sm_90 f64
 * shapes -- m16n8k4/k8/k16 -- into an `.extern .func` call).  It is hardcoded below on purpose;
 * only the threadblock/warp tiling and the stage count are swept.
 *
 * THE ORACLE IS NOT A = B = 1.  See f64_oracle.h.  A 1.0 oracle passes identically whether the
 * GEMM ran in fp64 or fp32, which is exactly the distinction this endeavour exists to make.
 *
 * LAYOUT.  Row-major A, column-major B, row-major C -- mirroring the tf32 peer so the two peers
 * differ in element type and dispatch path rather than in data layout.  The oracle is
 * layout-insensitive by construction, so this choice cannot flatter or penalise the result.
 *
 * A CONFIG THAT CANNOT RUN MUST BE A VISIBLE GAP, NEVER A TIMED NO-OP.  Inherited wholesale from
 * the tf32 peer's defect 3, and doubly relevant here: the whole point of writing this contender
 * before the ladder is to discover early whether CUTLASS has an fp64 path on this hardware at
 * all.  "It did not build" and "it built and ran at 0 GFLOPS" must not look alike.
 *
 * nvcc -O3 -std=c++17 -arch=sm_90a -I<cutlass>/include -I<cutlass>/tools/util/include
 *      cutlass_peer_f64.cu -o cutlass_peer_f64
 */
#include <iostream>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "f64_oracle.h"

#ifndef CFG_TILE_M
#define CFG_TILE_M 64
#endif
#ifndef CFG_TILE_N
#define CFG_TILE_N 64
#endif
#ifndef CFG_TILE_K
#define CFG_TILE_K 16
#endif
#ifndef CFG_WARP_M
#define CFG_WARP_M 32
#endif
#ifndef CFG_WARP_N
#define CFG_WARP_N 32
#endif
#ifndef CFG_WARP_K
#define CFG_WARP_K 16
#endif
#ifndef CFG_STAGES
#define CFG_STAGES 4
#endif

#define CFG_STR2(x) #x
#define CFG_STR(x) CFG_STR2(x)
#define CFG_NAME CFG_STR(CFG_TILE_M) "x" CFG_STR(CFG_TILE_N) "x" CFG_STR(CFG_TILE_K) \
                 "w" CFG_STR(CFG_WARP_M) "x" CFG_STR(CFG_WARP_N) "s" CFG_STR(CFG_STAGES)

#if __has_include(<cutlass/cutlass.h>)
#include <cuda_runtime.h>
#include <cutlass/cutlass.h>
#include <cutlass/numeric_types.h>
#include <cutlass/layout/matrix.h>
#include <cutlass/gemm/gemm.h>
#include <cutlass/gemm/device/gemm.h>
#include <cutlass/epilogue/thread/linear_combination.h>
#include <cutlass/gemm/threadblock/threadblock_swizzle.h>
#endif

int main(int argc, char** argv) {
#if __has_include(<cutlass/cutlass.h>)
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 1024;
    int N      = argc > 2 ? atoi(argv[2]) : 1024;
    int K      = argc > 3 ? atoi(argv[3]) : 1024;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    // OPERANDS fp64, ACCUMULATOR fp64, C fp64 — the same computation cublas_ceiling_f64.cu is
    // asked for.  Unlike the tf32 peer there is no operand/accumulator split to get wrong: DMMA
    // is IEEE double throughout, which is why the DMMA-vs-vector question is about speed only.
    using ElementA           = double;
    using LayoutA            = cutlass::layout::RowMajor;
    using ElementB           = double;
    using LayoutB            = cutlass::layout::ColumnMajor;
    using ElementC           = double;
    using LayoutC            = cutlass::layout::RowMajor;
    using ElementAccumulator = double;

    using ThreadblockShape = cutlass::gemm::GemmShape<CFG_TILE_M, CFG_TILE_N, CFG_TILE_K>;
    using WarpShape        = cutlass::gemm::GemmShape<CFG_WARP_M, CFG_WARP_N, CFG_WARP_K>;
    // The ONLY fp64 tensor-core shape.  Not swept — see the header.
    using InstructionShape = cutlass::gemm::GemmShape<8, 8, 4>;

    using EpilogueOp = cutlass::epilogue::thread::LinearCombination<
        ElementC, 1, ElementAccumulator, ElementAccumulator>;

    using Gemm = cutlass::gemm::device::Gemm<
        ElementA, LayoutA,
        ElementB, LayoutB,
        ElementC, LayoutC,
        ElementAccumulator,
        cutlass::arch::OpClassTensorOp,
        cutlass::arch::Sm80,
        ThreadblockShape, WarpShape, InstructionShape,
        EpilogueOp,
        cutlass::gemm::threadblock::GemmIdentityThreadblockSwizzle<>,
        CFG_STAGES>;

    const double v = crisp_f64_oracle_value();
    std::vector<ElementA> hA((size_t)M * K, v);
    std::vector<ElementB> hB((size_t)K * N, v);
    std::vector<ElementC> hC((size_t)M * N, 0.0);

    ElementA *dA; ElementB *dB; ElementC *dC;
    cudaMalloc(&dA, sizeof(ElementA) * (size_t)M * K);
    cudaMalloc(&dB, sizeof(ElementB) * (size_t)K * N);
    cudaMalloc(&dC, sizeof(ElementC) * (size_t)M * N);
    cudaMemcpy(dA, hA.data(), sizeof(ElementA) * (size_t)M * K, cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB.data(), sizeof(ElementB) * (size_t)K * N, cudaMemcpyHostToDevice);

    // Leading dimensions follow from the layouts above: row-major A is K wide, column-major B is
    // K tall, row-major C is N wide.
    const int lda = K, ldb = K, ldc = N;
    cutlass::TensorRef<ElementA const, LayoutA> refA(dA, LayoutA(lda));
    cutlass::TensorRef<ElementB const, LayoutB> refB(dB, LayoutB(ldb));
    cutlass::TensorRef<ElementC const, LayoutC> refC(dC, LayoutC(ldc));
    cutlass::TensorRef<ElementC,       LayoutC> refD(dC, LayoutC(ldc));

    typename Gemm::Arguments args(
        cutlass::gemm::GemmCoord(M, N, K),
        refA, refB, refC, refD,
        typename EpilogueOp::Params(ElementAccumulator(1.0), ElementAccumulator(0.0)));

    Gemm gemm_op;

    size_t workspace_size = Gemm::get_workspace_size(args);
    void* workspace = nullptr;
    if (workspace_size > 0) cudaMalloc(&workspace, workspace_size);

    auto bail = [&](const char* where, cutlass::Status st) {
        fprintf(stderr, "cutlass_peer_f64 [%s]: %s FAILED (%s) at M=%d N=%d K=%d — this config "
                        "did NOT run.\n", CFG_NAME, where, cutlassGetStatusString(st), M, N, K);
        printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
        printf("  \"config\": \"%s\",\n", CFG_NAME);
        printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
        printf("  \"correct\": false,\n");
        printf("  \"error\": \"%s %s\"\n}\n", where, cutlassGetStatusString(st));
        return 2;
    };

    cutlass::Status st = Gemm::can_implement(args);
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
    double maxerr = 0.0, maxrel = 0.0;
    bool correct = crisp_f64_oracle_check(hC.data(), hC.size(), K, &maxerr, &maxrel);
    const char* diagnosis = crisp_f64_oracle_diagnose(maxrel);
    if (!correct)
        fprintf(stderr, "cutlass_peer_f64 [%s]: ORACLE FAILED at M=%d N=%d K=%d — %s "
                        "(max_rel_err %.3e, tolerance %.1e)\n",
                CFG_NAME, M, N, K, diagnosis, maxrel, (double)CRISP_F64_ORACLE_RTOL);

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
    printf("  \"max_rel_err\": %.3e,\n  \"precision_diagnosis\": \"%s\",\n", maxrel, diagnosis);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return correct ? 0 : 1;
#else
    /* FAIL LOUDLY — see the tf32 peer's defect 3.  A contender that cannot build must be a
       VISIBLE GAP, not a silent zero that the report reads as a measured result. */
    (void)argc; (void)argv;
    fprintf(stderr, "cutlass_peer_f64 [%s]: CUTLASS headers not found at build time — this "
                    "contender did NOT run.  Run scripts/setup-third-party.sh cutlass.\n", CFG_NAME);
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n");
    printf("  \"config\": \"%s\",\n", CFG_NAME);
    printf("  \"correct\": false,\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    return 2;
#endif
}
