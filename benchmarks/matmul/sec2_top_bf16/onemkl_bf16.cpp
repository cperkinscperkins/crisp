/*
 * OneMKL BFloat16 Optimal reference for SYCL (Intel Ceiling).
 * Uses oneapi::mkl::blas::row_major::gemm with bfloat16 inputs and float output.
 *
 * Build: icpx -fsycl -O3 onemkl_bf16.cpp -qmkl -o onemkl_bf16
 */
#include <sycl/sycl.hpp>
#include <oneapi/mkl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <chrono>

using bfloat16 = sycl::ext::oneapi::bfloat16;

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};

    bfloat16* A = sycl::malloc_device<bfloat16>((size_t)M * K, q);
    bfloat16* B = sycl::malloc_device<bfloat16>((size_t)K * N, q);
    float* C = sycl::malloc_device<float>((size_t)M * N, q);

    std::vector<bfloat16> h_A((size_t)M * K, bfloat16(1.0f));
    std::vector<bfloat16> h_B((size_t)K * N, bfloat16(1.0f));
    std::vector<float> h_C((size_t)M * N, 0.0f);

    q.memcpy(A, h_A.data(), (size_t)M * K * sizeof(bfloat16)).wait();
    q.memcpy(B, h_B.data(), (size_t)K * N * sizeof(bfloat16)).wait();
    q.memcpy(C, h_C.data(), (size_t)M * N * sizeof(float)).wait();

    auto launch = [&]() {
        return oneapi::mkl::blas::row_major::gemm(
            q,
            oneapi::mkl::transpose::nontrans,
            oneapi::mkl::transpose::nontrans,
            M, N, K,
            1.0f,
            A, K,
            B, N,
            0.0f,
            C, N
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
        kt[i] = (t1 - t0) / 1e3; // nanoseconds -> microseconds
    }

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2];
    double k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    q.memcpy(h_C.data(), C, (size_t)M * N * sizeof(float)).wait();

    double maxerr = 0.0;
    double expected = (double)K;
    for (size_t i = 0; i < (size_t)M * N; i++) {
        maxerr = std::max(maxerr, std::fabs((double)h_C[i] - expected));
    }
    bool correct = maxerr < (expected * 1e-2);

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul_top_bf16\",\n  \"implementation\": \"onemkl_bf16\",\n");
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
