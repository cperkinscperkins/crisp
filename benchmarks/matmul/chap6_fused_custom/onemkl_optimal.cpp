/*
 * Chapter 6 (Endeavor 150) — INTEL CEILING for a matmul WITH A CUSTOM ACTIVATION.
 *
 * oneMKL GEMM followed by a SEPARATE kernel applying an activation oneMKL cannot fuse.
 *
 * NOTE THE ASYMMETRY WITH CHAPTER 5.  There, oneMKL pays a second kernel because oneMKL BLAS
 * has no epilogue parameter at all.  Here it would pay one even if it had: the activation is a
 * quadratic tail, not a standard eltwise primitive.  oneDNN (not oneMKL) is the Intel library
 * with post-op fusion, and is the contender that makes this chapter honest.  This is the baseline the fused
 * Crisp kernel has to beat, and it is deliberately the *realistic* one: oneMKL has no fused
 * epilogue to offer, so an activation costs a second launch and a full HBM round trip of C.
 *
 * WHAT IS TIMED, and why it is not just the sum of two kernels.  The measured window runs
 * from the GEMM's command_start to the ReLU's command_end, so it includes the gap between
 * the two launches.  That gap is part of what fusion removes; charging only the two kernel
 * bodies would flatter this baseline.  The per-GEMM time is reported separately as
 * gemm_median_us so the split is visible rather than inferred.
 *
 * The ReLU pass depends on the GEMM explicitly via depends_on rather than relying on queue
 * ordering — the queue is out-of-order by default, and without the dependency the activation
 * could be scheduled against a half-written C.
 *
 * ON THE DATA: A = B = 1, matching every other chapter and the shared Crisp L0 harness, so
 * every C == K and the correctness gate is exact.  That makes ReLU a numerical no-op here —
 * but it is NOT a timing no-op: the instructions are emitted and executed regardless of the
 * values, so the comparison stays honest.  Whether the activation actually computes the right
 * thing is established elsewhere, on metal, by the endeavour's spec ladder (rungs 04/05 on
 * Intel and 21/22 on NVIDIA check real mixed-sign values against hand-computed output).
 *
 * Build: icpx -fsycl -O3 onemkl_optimal.cpp -qmkl -o onemkl_optimal
 * Run:   ./onemkl_optimal [M] [N] [K] [warmup] [iters]
 */
#include <sycl/sycl.hpp>
#include <oneapi/mkl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <chrono>

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};

    float* A = sycl::malloc_device<float>((size_t)M * K, q);
    float* B = sycl::malloc_device<float>((size_t)K * N, q);
    float* C = sycl::malloc_device<float>((size_t)M * N, q);

    std::vector<float> h_A((size_t)M * K, 1.0f);
    std::vector<float> h_B((size_t)K * N, 1.0f);
    std::vector<float> h_C((size_t)M * N, 0.0f);

    q.memcpy(A, h_A.data(), (size_t)M * K * sizeof(float)).wait();
    q.memcpy(B, h_B.data(), (size_t)K * N * sizeof(float)).wait();
    q.memcpy(C, h_C.data(), (size_t)M * N * sizeof(float)).wait();

#ifdef FAST_MATH
    auto comp_mode = oneapi::mkl::blas::compute_mode::float_to_tf32;
#else
    auto comp_mode = oneapi::mkl::blas::compute_mode::standard;
#endif

    const size_t total = (size_t)M * N;

    auto gemm_launch = [&]() {
        return oneapi::mkl::blas::row_major::gemm(
            q,
            oneapi::mkl::transpose::nontrans,
            oneapi::mkl::transpose::nontrans,
            M, N, K,
            1.0f,
            A, K,
            B, N,
            0.0f,
            C, N,
            comp_mode
        );
    };

    // The activation as its OWN kernel — the cost fusion removes.
    auto relu_launch = [&](sycl::event dep) {
        return q.submit([&](sycl::handler& h) {
            h.depends_on(dep);
            h.parallel_for(sycl::range<1>(total), [=](sycl::id<1> i) {
                float v = C[i];
                C[i] = v > 0.5f ? v : v * v * 0.01f;
            });
        });
    };

    for (int i = 0; i < warmup; i++) {
        auto e1 = gemm_launch();
        relu_launch(e1).wait();
    }

    std::vector<double> kt(iters);      // GEMM start -> ReLU end (the honest pair cost)
    std::vector<double> gt(iters);      // GEMM alone, so the split is visible
    for (int i = 0; i < iters; i++) {
        auto e1 = gemm_launch();
        auto e2 = relu_launch(e1);
        e2.wait();
        auto g0 = e1.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto g1 = e1.get_profiling_info<sycl::info::event_profiling::command_end>();
        auto r1 = e2.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (double)(r1 - g0) / 1000.0;   // ns -> us, includes the inter-launch gap
        gt[i] = (double)(g1 - g0) / 1000.0;
    }

    q.memcpy(h_C.data(), C, (size_t)M * N * sizeof(float)).wait();
    double expected = (double)K, maxerr = 0.0;      // A=B=1 => C == K, and relu(K) == K
    for (size_t i = 0; i < total; i++)
        maxerr = std::max(maxerr, (double)std::fabs(h_C[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    std::sort(gt.begin(), gt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double g_med = gt[iters / 2];
    // Same numerator as the fused kernel's, so the two are directly comparable.
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"onemkl+custom\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gemm_median_us\": %.2f,\n", g_med);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q);
    sycl::free(B, q);
    sycl::free(C, q);
    return correct ? 0 : 1;
}
