/*
 * SYCL Joint Matrix Half (fp16) Control reference for BattleMage.
 *
 * Implements a 32x32 register-ring tiled kernel using:
 *  - sycl::ext::oneapi::experimental::matrix::joint_matrix (XMX FP16 DPAS)
 *  - joint_matrix_prefetch (Subgroup2DBlockPrefetchINTEL)
 *  - joint_matrix_load / joint_matrix_store
 *  - W=4 column strip mining swizzle matching Crisp L2 locality
 *
 * Build: icpx -fsycl -O3 -Xs "-ze-opt-large-register-file" sycl_control_fp16.cpp -o sycl_control_fp16
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
using fp16_t = sycl::half;

int main(int argc, char** argv) {
    try {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};

    fp16_t* A = sycl::malloc_device<fp16_t>((size_t)M * K, q);
    fp16_t* B = sycl::malloc_device<fp16_t>((size_t)K * N, q);
    float* C = sycl::malloc_device<float>((size_t)M * N, q);

    std::vector<fp16_t> h_A((size_t)M * K, fp16_t(1.0f));
    std::vector<fp16_t> h_B((size_t)K * N, fp16_t(1.0f));
    std::vector<float> h_C((size_t)M * N, 0.0f);

    q.memcpy(A, h_A.data(), (size_t)M * K * sizeof(fp16_t)).wait();
    q.memcpy(B, h_B.data(), (size_t)K * N * sizeof(fp16_t)).wait();
    q.memcpy(C, h_C.data(), (size_t)M * N * sizeof(float)).wait();

    int n_tiles_m = M / 32;
    int n_tiles_n = N / 32;
    int total_tiles = n_tiles_m * n_tiles_n;
    constexpr int STRIP_WIDTH = 4;

    sycl::range<1> local{16};
    sycl::range<1> global{(size_t)total_tiles * 16};

    auto make_ptr = [](auto* p) {
        return sycl::address_space_cast<sycl::access::address_space::global_space, sycl::access::decorated::no>(p);
    };

    auto launch = [&]() {
        return q.submit([&](sycl::handler& h) {
            h.parallel_for(sycl::nd_range<1>(global, local), [=](sycl::nd_item<1> item)
                [[intel::reqd_sub_group_size(16)]] {
                auto sg = item.get_sub_group();
                int linear_tile = item.get_group(0);

                int tiles_per_strip = n_tiles_m * STRIP_WIDTH;
                int strip_idx = linear_tile / tiles_per_strip;
                int tile_in_strip = linear_tile % tiles_per_strip;
                int tile_m = tile_in_strip / STRIP_WIDTH;
                int tile_n = strip_idx * STRIP_WIDTH + (tile_in_strip % STRIP_WIDTH);

                if (tile_m < n_tiles_m && tile_n < n_tiles_n) {
                    int row = tile_m * 32;
                    int col = tile_n * 32;

                    using tC_t = joint_matrix<sycl::sub_group, float, use::accumulator, 8, 16>;
                    using tA_t = joint_matrix<sycl::sub_group, fp16_t, use::a, 8, 16, layout::row_major>;
                    using tB_t = joint_matrix<sycl::sub_group, fp16_t, use::b, 16, 16, layout::ext_intel_packed>;

                    tC_t c[4][2];
                    for (int r = 0; r < 4; ++r)
                        for (int c_idx = 0; c_idx < 2; ++c_idx)
                            joint_matrix_fill(sg, c[r][c_idx], 0.0f);

                    tA_t a_ring[2][4];
                    tB_t b_ring[2][2];

                    // Prologue load stage 0
                    for (int r = 0; r < 4; ++r)
                        joint_matrix_load(sg, a_ring[0][r], make_ptr(A + (row + r * 8) * K + 0), K);
                    for (int c_idx = 0; c_idx < 2; ++c_idx)
                        joint_matrix_load(sg, b_ring[0][c_idx], make_ptr(B + 0 * N + (col + c_idx * 16)), N);

                    int num_k_steps = K / 16;
                    for (int k_idx = 0; k_idx < num_k_steps; ++k_idx) {
                        int next_k = k_idx + 1;
                        int pref_k = k_idx + 2;
                        int cur_buf = k_idx % 2;
                        int next_buf = next_k % 2;

                        if (pref_k < num_k_steps) {
                            joint_matrix_prefetch<32, 16>(sg, A + row * K + pref_k * 16, K, layout::row_major, properties{prefetch_hint_L1});
                            joint_matrix_prefetch<16, 16>(sg, B + (pref_k * 16) * N + col, N, layout::row_major, properties{prefetch_hint_L1});
                            joint_matrix_prefetch<16, 16>(sg, B + (pref_k * 16) * N + col + 16, N, layout::row_major, properties{prefetch_hint_L1});
                        }

                        if (next_k < num_k_steps) {
                            for (int r = 0; r < 4; ++r)
                                joint_matrix_load(sg, a_ring[next_buf][r], make_ptr(A + (row + r * 8) * K + next_k * 16), K);
                            for (int c_idx = 0; c_idx < 2; ++c_idx)
                                joint_matrix_load(sg, b_ring[next_buf][c_idx], make_ptr(B + (next_k * 16) * N + (col + c_idx * 16)), N);
                        }

                        for (int r = 0; r < 4; ++r)
                            for (int c_idx = 0; c_idx < 2; ++c_idx)
                                joint_matrix_mad(sg, c[r][c_idx], a_ring[cur_buf][r], b_ring[cur_buf][c_idx], c[r][c_idx]);
                    }

                    for (int r = 0; r < 4; ++r)
                        for (int c_idx = 0; c_idx < 2; ++c_idx)
                            joint_matrix_store(sg, c[r][c_idx], make_ptr(C + (row + r * 8) * N + (col + c_idx * 16)), N, layout::row_major);
                }
            });
        });
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
        kt[i] = (t1 - t0) / 1e3;
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

    printf("{\n  \"algorithm\": \"matmul_top_fp16\",\n  \"implementation\": \"sycl_control_fp16\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q);
    sycl::free(B, q);
    sycl::free(C, q);

    return correct ? 0 : 1;
    } catch (const sycl::exception& e) {
        std::cerr << "SYCL Exception: " << e.what() << std::endl;
        return 1;
    }
}
