/*
 * Hand-written SYCL reference matmul (Naive loops, no coop-matrix / joint_matrix or shared local memory).
 * Section 1 Chapter 0 baseline for Intel.
 *
 * Compile: icpx -fsycl -O3 sycl_apples.cpp -o sycl_apples
 * Run:     ./sycl_apples [M] [N] [K] [warmup] [iters]
 */
#include <sycl/sycl.hpp>
#include <iostream>
#include <vector>
#include <numeric>
#include <algorithm>
#include <chrono>
#include <cmath>

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc > 1 ? std::atoi(argv[1]) : 256;
    int N = argc > 2 ? std::atoi(argv[2]) : 256;
    int K = argc > 3 ? std::atoi(argv[3]) : 256;
    int warmup = argc > 4 ? std::atoi(argv[4]) : 20;
    int iters = argc > 5 ? std::atoi(argv[5]) : 100;

    sycl::queue q{sycl::default_selector_v, sycl::property::queue::enable_profiling()};

    std::vector<float> hA(M * K, 1.0f);
    std::vector<float> hB(K * N, 1.0f);
    std::vector<float> hC(M * N, 0.0f);

    float *dA = sycl::malloc_device<float>(M * K, q);
    float *dB = sycl::malloc_device<float>(K * N, q);
    float *dC = sycl::malloc_device<float>(M * N, q);

    q.memcpy(dA, hA.data(), sizeof(float) * M * K).wait();
    q.memcpy(dB, hB.data(), sizeof(float) * K * N).wait();

    auto launch = [&]() {
        return q.submit([&](sycl::handler& h) {
            h.parallel_for(sycl::range<2>(M, N), [=](sycl::id<2> idx) {
                int row = idx[0];
                int col = idx[1];
                float acc = 0.0f;
                for (int k = 0; k < K; k++) {
                    acc += dA[row * K + k] * dB[k * N + col]; // Row-major A and B
                }
                dC[row * N + col] = acc;
            });
        });
    };

    for (int i = 0; i < warmup; i++) {
        launch().wait();
    }

    std::vector<double> times_ms;
    for (int i = 0; i < iters; i++) {
        auto e = launch();
        e.wait();
        auto start = e.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto end = e.get_profiling_info<sycl::info::event_profiling::command_end>();
        times_ms.push_back((end - start) / 1e6);
    }

    q.memcpy(hC.data(), dC, sizeof(float) * M * N).wait();

    double expected = (double)K, maxerr = 0.0;
    for (size_t i = 0; i < hC.size(); i++) maxerr = std::max(maxerr, (double)std::fabs(hC[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(times_ms.begin(), times_ms.end());
    double k_med = times_ms[iters / 2];
    double k_min = times_ms[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e3) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    std::cout << "{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"sycl_apples\",\n";
    std::cout << "  \"M\": " << M << ", \"N\": " << N << ", \"K\": " << K << ",\n";
    std::cout << "  \"correct\": " << (correct ? "true" : "false") << ",\n  \"max_abs_err\": " << maxerr << ",\n";
    std::cout << "  \"wall_time_ms\": " << wall_time_ms << ",\n";
    std::cout << "  \"kernel_median_us\": " << k_med * 1000.0 << ",\n  \"kernel_min_us\": " << k_min * 1000.0 << ",\n";
    std::cout << "  \"gflops\": " << gflops << "\n}\n";

    sycl::free(dA, q); sycl::free(dB, q); sycl::free(dC, q);
    return correct ? 0 : 1;
}
