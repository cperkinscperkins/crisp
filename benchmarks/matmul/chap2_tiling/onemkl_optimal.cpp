/*
 * OneMKL Optimal reference for SYCL (Intel Ceiling).
 * Uses oneapi::mkl::blas::column_major::gemm to provide the absolute hardware ceiling.
 *
 * Build: icpx -fsycl -O3 onemkl_optimal.cpp -qmkl -o onemkl_optimal
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

    auto launch = [&]() {
        // Crisp benchmark uses Row-Major A, B, C.
        // OneMKL GEMM supports row-major.
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

    for (int i = 0; i < warmup; i++) {
        launch().wait();
    }

    std::vector<double> kt(iters);
    for (int i = 0; i < iters; i++) {
        auto ev = launch();
        ev.wait();
        auto t0 = ev.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto t1 = ev.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (double)(t1 - t0) / 1000.0;   // ns -> us
    }

    q.memcpy(h_C.data(), C, (size_t)M * N * sizeof(float)).wait();
    double expected = (double)K, maxerr = 0.0;
    for (size_t i = 0; i < (size_t)M * N; i++)
        maxerr = std::max(maxerr, (double)std::fabs(h_C[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"onemkl\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q);
    sycl::free(B, q);
    sycl::free(C, q);
    return correct ? 0 : 1;
}
