/*
 * onemkl_int8.cpp -- oneMKL int8 GEMM peer (Endeavour 207).
 *
 * C (s32) = A (s8) x B (s8), all row-major, on the GPU queue.
 * argv[6] picks the oneMKL entry point:
 *   "gemm" (default) -- oneapi::mkl::blas::row_major::gemm<int8,int8,int32,float>
 *   "bias"           -- oneapi::mkl::blas::row_major::gemm_bias with zero offsets
 * Exact integer result, so the strided verifier must report max_abs_err 0.
 */
#include <sycl/sycl.hpp>
#include "../common/fill_sycl.hpp"
#include <oneapi/mkl.hpp>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;
    const bool use_bias = argc > 6 && std::strcmp(argv[6], "bias") == 0;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};

    std::int8_t*  A = sycl::malloc_device<std::int8_t>((size_t)M * K, q);
    std::int8_t*  B = sycl::malloc_device<std::int8_t>((size_t)K * N, q);
    std::int32_t* C = sycl::malloc_device<std::int32_t>((size_t)M * N, q);
    std::int32_t* co = sycl::malloc_device<std::int32_t>(1, q);
    q.fill(co, std::int32_t(0), 1).wait();

    crisp_bench::sycl_fill(q, A, (size_t)M * K, crisp_bench::FILL_MOD_A);
    crisp_bench::sycl_fill(q, B, (size_t)K * N, crisp_bench::FILL_MOD_B);
    crisp_bench::sycl_zero(q, C, (size_t)M * N);

    using oneapi::mkl::transpose;
    auto launch = [&]() {
        if (use_bias)
            return oneapi::mkl::blas::row_major::gemm_bias(
                q, transpose::nontrans, transpose::nontrans, oneapi::mkl::offset::fix,
                M, N, K, 1.0f,
                A, K, std::int8_t(0),
                B, N, std::int8_t(0),
                0.0f, C, N, co);
        return oneapi::mkl::blas::row_major::gemm(
            q, transpose::nontrans, transpose::nontrans,
            M, N, K, 1.0f, A, K, B, N, 0.0f, C, N);
    };

    for (int i = 0; i < warmup; i++) launch().wait();

    std::vector<double> kt(iters);
    for (int i = 0; i < iters; i++) {
        auto ev = launch();
        ev.wait();
        auto t0 = ev.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto t1 = ev.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (t1 - t0) / 1e3;
    }
    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2];
    double k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    const crisp_bench::VerifyResult vr =
        crisp_bench::sycl_verify(q, C, (uint64_t)M, (uint64_t)N, (uint64_t)K);
    bool correct = vr.verified;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul_top_int8\",\n  \"implementation\": \"%s\",\n",
           use_bias ? "onemkl_int8_bias" : "onemkl_int8");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", vr.max_abs_err);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q); sycl::free(B, q); sycl::free(C, q); sycl::free(co, q);
    return correct ? 0 : 1;
}
