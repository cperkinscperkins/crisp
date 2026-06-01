/*
 * Hand-written SYCL DPC++ sum reduction benchmark.
 *
 * Mirrors Crisp's algorithm exactly so the comparison is
 * "same algorithm, same launch policy, different source language":
 *   Phase 1: grid-stride accumulation — each work-item accumulates a stripe
 *   Phase 2: workgroup tree-reduce in shared local memory (halving stride, 8 rounds)
 *   Phase 3: one fetch_add per workgroup to the global result cell
 *
 * Launch policy mirrors Crisp's :strategy :strided :occupancy R for L0:
 *   global = (numEUs * occupancy) workgroups × blockSize work-items
 *
 * Usage: ./sum_reduce_sycl [N] [warmup] [iterations] [occupancy]
 *   occupancy = 0.0..1.0 ratio for grid sizing (default: 1.0 = max).
 *
 * Output: JSON to stdout — same schema as the CUDA / Crisp harnesses so
 * the bench-intel-driver.py comparison table absorbs it directly.
 *
 * Compile (inside Docker container with oneAPI):
 *   icpx -fsycl -O3 sum_reduce.cpp -o sum_reduce_sycl
 */

#include <sycl/sycl.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <vector>

constexpr size_t BLOCK_SIZE = 256;

int main(int argc, char** argv) {
    int    N          = argc > 1 ? std::atoi(argv[1]) : 1000000;
    int    warmup     = argc > 2 ? std::atoi(argv[2]) : 50;
    int    iterations = argc > 3 ? std::atoi(argv[3]) : 100;
    double occupancy  = argc > 4 ? std::atof(argv[4]) : 1.0;
    if (occupancy <= 0.0 || occupancy > 1.0) {
        std::fprintf(stderr, "occupancy must be in (0.0, 1.0], got %f\n", occupancy);
        return 1;
    }

    // ------------------------------------------------------------------
    // Queue + device
    // ------------------------------------------------------------------
    sycl::queue q(sycl::gpu_selector_v,
                  sycl::property::queue::enable_profiling{});
    auto dev = q.get_device();
    std::fprintf(stderr, "Device: %s\n",
                 dev.get_info<sycl::info::device::name>().c_str());

    // numEUs ~ max_compute_units on Intel.  Matches the L0 harness heuristic.
    uint32_t numEUs    = dev.get_info<sycl::info::device::max_compute_units>();
    uint32_t baseGroups = std::max(1u, numEUs);
    uint32_t gridSize   = std::max(1u, (uint32_t)(baseGroups * occupancy));

    size_t global = (size_t)gridSize * BLOCK_SIZE;
    std::fprintf(stderr, "Grid: %u groups (numEUs=%u × occupancy=%.2f), block=%zu, total=%zu\n",
                 gridSize, numEUs, occupancy, (size_t)BLOCK_SIZE, global);

    // ------------------------------------------------------------------
    // Allocate input + result
    // ------------------------------------------------------------------
    float* d_input  = sycl::malloc_device<float>(N, q);
    float* d_result = sycl::malloc_shared<float>(1, q);

    {
        std::vector<float> h_input(N, 1.0f);
        q.memcpy(d_input, h_input.data(), N * sizeof(float)).wait();
    }

    // ------------------------------------------------------------------
    // Kernel: grid-stride accumulate + workgroup tree-reduce + atomic
    // ------------------------------------------------------------------
    auto launch = [&]() {
        return q.submit([&](sycl::handler& h) {
            sycl::local_accessor<float, 1> slm(sycl::range<1>(BLOCK_SIZE), h);
            int    N_local = N;
            float* in      = d_input;
            float* out     = d_result;

            h.parallel_for(sycl::nd_range<1>(sycl::range<1>(global),
                                              sycl::range<1>(BLOCK_SIZE)),
                           [=](sycl::nd_item<1> item) {
                int gid     = (int)item.get_global_id(0);
                int lid     = (int)item.get_local_id(0);
                int gstride = (int)item.get_global_range(0);

                // Phase 1: grid-stride accumulate into register
                float acc = 0.0f;
                for (int i = gid; i < N_local; i += gstride) {
                    acc += in[i];
                }

                // Phase 2: workgroup tree-reduce in SLM
                slm[lid] = acc;
                for (int stride = BLOCK_SIZE / 2; stride > 0; stride >>= 1) {
                    item.barrier(sycl::access::fence_space::local_space);
                    if (lid < stride) {
                        slm[lid] += slm[lid + stride];
                    }
                }

                // Phase 3: one atomic-add per workgroup
                if (lid == 0) {
                    sycl::atomic_ref<float,
                                     sycl::memory_order::relaxed,
                                     sycl::memory_scope::device,
                                     sycl::access::address_space::global_space>
                        ref(out[0]);
                    ref.fetch_add(slm[0]);
                }
            });
        });
    };

    // ------------------------------------------------------------------
    // Warmup
    // ------------------------------------------------------------------
    for (int i = 0; i < warmup; i++) {
        *d_result = 0.0f;
        launch().wait();
    }

    // ------------------------------------------------------------------
    // Measured runs
    // ------------------------------------------------------------------
    std::vector<double> kernel_times_us(iterations);
    std::vector<double> wall_times_us(iterations);

    for (int i = 0; i < iterations; i++) {
        *d_result = 0.0f;
        auto wall_start = std::chrono::high_resolution_clock::now();
        sycl::event ev = launch();
        ev.wait();
        auto wall_end = std::chrono::high_resolution_clock::now();

        uint64_t start_ns = ev.get_profiling_info<sycl::info::event_profiling::command_start>();
        uint64_t end_ns   = ev.get_profiling_info<sycl::info::event_profiling::command_end>();
        kernel_times_us[i] = (double)(end_ns - start_ns) / 1000.0;
        wall_times_us[i]   = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
    }

    float result   = *d_result;
    float expected = (float)N;
    bool  correct  = std::fabs(result - expected) < expected * 1e-3f;

    // ------------------------------------------------------------------
    // Stats + JSON output (same schema as bench_harness.cu / .cpp)
    // ------------------------------------------------------------------
    std::sort(kernel_times_us.begin(), kernel_times_us.end());
    double k_median = kernel_times_us[iterations / 2];
    double k_min    = kernel_times_us[0];
    double k_sum    = std::accumulate(kernel_times_us.begin(), kernel_times_us.end(), 0.0);
    double k_mean   = k_sum / iterations;
    double k_var    = 0.0;
    for (double t : kernel_times_us) k_var += (t - k_mean) * (t - k_mean);
    double k_stddev = std::sqrt(k_var / iterations);
    double throughput_gb = ((double)N * sizeof(float) / 1e9) / (k_median / 1e6);

    std::sort(wall_times_us.begin(), wall_times_us.end());
    double w_median = wall_times_us[iterations / 2];
    double w_min    = wall_times_us[0];

    std::printf("{\n");
    std::printf("  \"algorithm\": \"reduction\",\n");
    std::printf("  \"implementation\": \"sycl\",\n");
    std::printf("  \"backend\": \"sycl\",\n");
    std::printf("  \"N\": %d,\n", N);
    std::printf("  \"warmup\": %d,\n", warmup);
    std::printf("  \"iterations\": %d,\n", iterations);
    std::printf("  \"correct\": %s,\n", correct ? "true" : "false");
    std::printf("  \"result\": %.1f,\n", result);
    std::printf("  \"expected\": %.1f,\n", expected);
    std::printf("  \"kernel_median_us\": %.2f,\n", k_median);
    std::printf("  \"kernel_min_us\": %.2f,\n", k_min);
    std::printf("  \"kernel_mean_us\": %.2f,\n", k_mean);
    std::printf("  \"kernel_stddev_us\": %.2f,\n", k_stddev);
    std::printf("  \"throughput_gb_s\": %.2f,\n", throughput_gb);
    std::printf("  \"wall_median_us\": %.2f,\n", w_median);
    std::printf("  \"wall_min_us\": %.2f\n", w_min);
    std::printf("}\n");

    sycl::free(d_input, q);
    sycl::free(d_result, q);
    return correct ? 0 : 1;
}
