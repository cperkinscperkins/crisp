/*
 * SYCL DPC++ reference matmul for the Intel benchmark: C[N x N] = A . B (square).
 * The Intel analog of ../cuda/matmul.cu — a hand-written 16x16 shared-memory tiled
 * fp32 kernel (a straightforward baseline; oneMKL GEMM is the "best-known" library
 * comparison to add later).  Row-major A / B / C to match the BMG Crisp kernel
 * (matmul_bmg.crisp uses B :row-major, since SPV/DPAS has no ColumnMajor-B).
 *
 * A = B = 1.0 so every C[i][j] == K exactly (a hard correctness gate).
 *
 * Square problem so it matches the driver's [size warmup iters] call shape.
 *
 * Build: icpx -fsycl -O3 matmul.cpp -o matmul_sycl
 * Run:   ./matmul_sycl [size] [warmup] [iters]
 */
#include <sycl/sycl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <chrono>

constexpr int TS = 16;

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v,
                  sycl::property::queue::enable_profiling{}};

    float* A = sycl::malloc_shared<float>((size_t)M * K, q);
    float* B = sycl::malloc_shared<float>((size_t)K * N, q);
    float* C = sycl::malloc_shared<float>((size_t)M * N, q);
    for (size_t i = 0; i < (size_t)M * K; i++) A[i] = 1.0f;
    for (size_t i = 0; i < (size_t)K * N; i++) B[i] = 1.0f;

    const int GM = ((M + TS - 1) / TS) * TS;
    const int GN = ((N + TS - 1) / TS) * TS;

    auto launch = [&]() {
        return q.submit([&](sycl::handler& h) {
            sycl::local_accessor<float, 2> As({TS, TS}, h);
            sycl::local_accessor<float, 2> Bs({TS, TS}, h);
            h.parallel_for(
                sycl::nd_range<2>(sycl::range<2>(GM, GN), sycl::range<2>(TS, TS)),
                [=](sycl::nd_item<2> it) {
                    int row = it.get_global_id(0);
                    int col = it.get_global_id(1);
                    int ly = it.get_local_id(0), lx = it.get_local_id(1);
                    float acc = 0.0f;
                    for (int t = 0; t < K; t += TS) {
                        As[ly][lx] = (row < M && t + lx < K) ? A[row * K + (t + lx)] : 0.0f;
                        Bs[ly][lx] = (col < N && t + ly < K) ? B[(t + ly) * N + col] : 0.0f;
                        it.barrier(sycl::access::fence_space::local_space);
                        for (int k = 0; k < TS; k++) acc += As[ly][k] * Bs[k][lx];
                        it.barrier(sycl::access::fence_space::local_space);
                    }
                    if (row < M && col < N) C[row * N + col] = acc;
                });
        });
    };

    for (int i = 0; i < warmup; i++) launch();
    q.wait();

    std::vector<double> kt(iters);
    for (int i = 0; i < iters; i++) {
        auto ev = launch();
        ev.wait();
        auto t0 = ev.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto t1 = ev.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (double)(t1 - t0) / 1000.0;   // ns -> us
    }

    double expected = (double)K, maxerr = 0.0;
    for (size_t i = 0; i < (size_t)M * N; i++)
        maxerr = std::max(maxerr, (double)std::fabs(C[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"sycl\",\n");
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
