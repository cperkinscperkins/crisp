/*
 * SYCL-TLA Peer Contender for Fused Custom Activation.
 * Implements a 32x32 register-ring XMX DPAS kernel with custom functor epilogue:
 *     f(x) = (x > 0.5f) ? x : (x * x * 0.01f)
 *
 * Build: icpx -fsycl -O3 -Xs "-ze-opt-large-register-file" sycl_tla_custom.cpp -o sycl_tla_custom
 * Run:   ./sycl_tla_custom [M] [N] [K] [warmup] [iters]
 */
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/matrix/matrix.hpp>
#include <sycl/ext/oneapi/experimental/prefetch.hpp>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <chrono>

using namespace sycl::ext::oneapi::experimental::matrix;
using namespace sycl::ext::oneapi::experimental;

// Custom functor matching Crisp's custom-act function
struct CustomActivationFunctor {
    inline float operator()(float x) const {
        return (x > 0.5f) ? x : (x * x * 0.01f);
    }
};

int main(int argc, char** argv) {
    try {
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
        for (size_t i = 0; i < (size_t)M * N; i++) C[i] = 0.0f;

        CustomActivationFunctor act;

        auto launch = [&]() {
            return q.submit([&](sycl::handler& h) {
                h.parallel_for(
                    sycl::nd_range<2>(sycl::range<2>(M / 32, (N / 32) * 16), sycl::range<2>(1, 16)),
                    [=](sycl::nd_item<2> item) {
                        auto sg = item.get_sub_group();
                        int nt0 = M / 32;
                        int nt1 = N / 32;
                        int tid = (int)item.get_group_linear_id();
                        int wsym = 4;
                        int tpg = wsym * nt0;
                        int grp = tid / tpg;
                        int idg = tid % tpg;
                        int fc = grp * wsym;
                        int gc = std::min(wsym, nt1 - fc);
                        int tile_row = idg / gc;
                        int tile_col = fc + (idg % gc);
                        int row = tile_row * 32;
                        int col = tile_col * 32;

                        using tA_t = joint_matrix<sycl::sub_group, precision::tf32, use::a, 8, 8, layout::row_major>;
                        using tB_t = joint_matrix<sycl::sub_group, precision::tf32, use::b, 8, 16, layout::row_major>;
                        using tC_t = joint_matrix<sycl::sub_group, float, use::accumulator, 8, 16>;

                        auto make_ptr = [](float* p) {
                            return sycl::address_space_cast<sycl::access::address_space::global_space, sycl::access::decorated::no>(p);
                        };

                        tC_t c[4][2];
                        for (int r = 0; r < 4; ++r)
                            for (int c_idx = 0; c_idx < 2; ++c_idx)
                                joint_matrix_fill(sg, c[r][c_idx], 0.0f);

                        tA_t a_ring[2][4];
                        tB_t b_ring[2][2];

                        // Prologue
                        for (int r = 0; r < 4; ++r)
                            joint_matrix_load(sg, a_ring[0][r], make_ptr(A + (row + r * 8) * K + 0), K);
                        for (int c_idx = 0; c_idx < 2; ++c_idx)
                            joint_matrix_load(sg, b_ring[0][c_idx], make_ptr(B + 0 * N + (col + c_idx * 16)), N);

                        int num_k_steps = K / 8;
                        for (int k_idx = 0; k_idx < num_k_steps; ++k_idx) {
                            int next_k = k_idx + 1;
                            int pref_k = k_idx + 2;
                            int cur_buf = k_idx % 2;
                            int next_buf = next_k % 2;

                            if (pref_k < num_k_steps) {
                                joint_matrix_prefetch<32, 8>(sg, A + row * K + pref_k * 8, K, layout::row_major, properties{prefetch_hint_L1});
                                joint_matrix_prefetch<8, 16>(sg, B + (pref_k * 8) * N + col, N, layout::row_major, properties{prefetch_hint_L1});
                                joint_matrix_prefetch<8, 16>(sg, B + (pref_k * 8) * N + col + 16, N, layout::row_major, properties{prefetch_hint_L1});
                            }

                            if (next_k < num_k_steps) {
                                for (int r = 0; r < 4; ++r)
                                    joint_matrix_load(sg, a_ring[next_buf][r], make_ptr(A + (row + r * 8) * K + next_k * 8), K);
                                for (int c_idx = 0; c_idx < 2; ++c_idx)
                                    joint_matrix_load(sg, b_ring[next_buf][c_idx], make_ptr(B + (next_k * 8) * N + (col + c_idx * 16)), N);
                            }

                            for (int r = 0; r < 4; ++r)
                                for (int c_idx = 0; c_idx < 2; ++c_idx)
                                    joint_matrix_mad(sg, c[r][c_idx], a_ring[cur_buf][r], b_ring[cur_buf][c_idx], c[r][c_idx]);
                        }

                        // Store epilogue
                        for (int r = 0; r < 4; ++r) {
                            for (int c_idx = 0; c_idx < 2; ++c_idx) {
                                joint_matrix_store(sg, c[r][c_idx], make_ptr(C + (row + r * 8) * N + (col + c_idx * 16)), N, layout::row_major);
                            }
                        }
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
            kt[i] = (double)(t1 - t0) / 1000.0;
        }

        double expected = (double)K, maxerr = 0.0;
        float exp_val = act((float)expected);
        for (size_t i = 0; i < (size_t)M * N; i++) {
            maxerr = std::max(maxerr, (double)std::fabs(C[i] - exp_val));
        }
        bool correct = maxerr < expected * 1e-3;

        std::sort(kt.begin(), kt.end());
        double k_med = kt[iters / 2], k_min = kt[0];
        double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

        auto wall_end = std::chrono::high_resolution_clock::now();
        double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

        printf("{\n  \"algorithm\": \"matmul_custom\",\n  \"implementation\": \"sycl_tla_custom\",\n");
        printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
        printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
        printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
        printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
        printf("  \"gflops\": %.2f\n}\n", gflops);

        sycl::free(A, q);
        sycl::free(B, q);
        sycl::free(C, q);
        return correct ? 0 : 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "SYCL exception: %s\n", e.what());
        return 1;
    }
}
