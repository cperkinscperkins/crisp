/*
 * CUTLASS 3.x Hopper TMA WGMMA GEMM (Peer Contender for NVIDIA).
 * Section 2 Peer Contender: C++ template-instantiated Tensor Core GEMM.
 *
 * Compiles with: nvcc -O3 -std=c++17 -arch=sm_90a -I<cutlass_path>/include cutlass_gemm.cu -o cutlass_gemm
 * Run: ./cutlass_gemm [M] [N] [K] [warmup] [iters]
 */
#include <iostream>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#if __has_include(<cutlass/cutlass.h>)
#include <cuda_runtime.h>
#include <cutlass/cutlass.h>
#include <cutlass/numeric_types.h>
#include <cutlass/gemm/device/gemm_universal_adapter.h>
#include <cutlass/gemm/collective/collective_builder.hpp>
#include <cutlass/epilogue/collective/collective_builder.hpp>
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
    using ElementA = cutlass::tfloat32_t;
    using LayoutA  = cutlass::layout::RowMajor;
    using ElementB = cutlass::tfloat32_t;
    using LayoutB  = cutlass::layout::ColumnMajor;
    using ElementC = float;
    using LayoutC  = cutlass::layout::RowMajor;
    using ElementAccumulator = float;

    using CollectiveEpilogue = typename cutlass::epilogue::collective::CollectiveBuilder<
        cutlass::arch::Sm90, cutlass::arch::OpClassTensorOp,
        cute::Shape<cute::_64, cute::_256, cute::_32>,
        cute::Shape<cute::_1, cute::_1, cute::_1>,
        cutlass::epilogue::collective::EpilogueTileAuto,
        ElementAccumulator, ElementAccumulator,
        ElementC, LayoutC, 4,
        ElementC, LayoutC, 4,
        cutlass::epilogue::collective::EpilogueScheduleAuto
    >::CollectiveOp;

    using CollectiveMainloop = typename cutlass::gemm::collective::CollectiveBuilder<
        cutlass::arch::Sm90, cutlass::arch::OpClassTensorOp,
        ElementA, LayoutA, 4,
        ElementB, LayoutB, 4,
        ElementAccumulator,
        cute::Shape<cute::_64, cute::_256, cute::_32>,
        cute::Shape<cute::_1, cute::_1, cute::_1>,
        cutlass::gemm::collective::StageCountAutoCarveout<sizeof(typename CollectiveEpilogue::SharedStorage)>,
        cutlass::gemm::KernelTmaWarpSpecialized
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
    cudaMalloc(&dA, sizeof(ElementA) * M * K);
    cudaMalloc(&dB, sizeof(ElementB) * K * N);
    cudaMalloc(&dC, sizeof(ElementC) * M * N);

    cudaMemcpy(dA, hA.data(), sizeof(ElementA) * M * K, cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB.data(), sizeof(ElementB) * K * N, cudaMemcpyHostToDevice);

    Gemm gemm_op;
    typename Gemm::Arguments args{
        cutlass::gemm::GemmUniversalMode::kGemm,
        {M, N, K},
        {dA, {K, cute::_1{}}, dB, {K, cute::_1{}}},
        {{}, dC, {N, cute::_1{}}, dC, {N, cute::_1{}}}
    };

    size_t workspace_size = Gemm::get_workspace_size(args);
    void* workspace = nullptr;
    if (workspace_size > 0) cudaMalloc(&workspace, workspace_size);

    gemm_op.can_implement(args);
    gemm_op.initialize(args, workspace);

    for (int i = 0; i < warmup; i++) gemm_op.run();
    cudaDeviceSynchronize();

    std::vector<float> kt(iters);
    cudaEvent_t s, e;
    cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s);
        gemm_op.run();
        cudaEventRecord(e);
        cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e);
    }

    cudaMemcpy(hC.data(), dC, sizeof(ElementC) * M * N, cudaMemcpyDeviceToHost);
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
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    if (workspace) cudaFree(workspace);
    return correct ? 0 : 1;
#else
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cutlass\",\n  \"error\": \"CUTLASS headers not found\"\n}\n");
    return 0;
#endif
}
