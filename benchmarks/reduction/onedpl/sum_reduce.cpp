/*
 * oneDPL library sum reduction benchmark.
 * Uses oneapi::dpl::reduce — Intel's optimised parallel primitives library,
 * the analog of NVIDIA's CUB for the Intel side.
 *
 * Usage: ./sum_reduce_onedpl [N] [warmup] [iterations]
 *
 * Output: JSON to stdout — same schema as the CUDA / SYCL / Crisp harnesses.
 *
 * Compile (inside Docker container with oneAPI):
 *   icpx -fsycl -O3 sum_reduce.cpp -o sum_reduce_onedpl
 *
 * Timing note: oneDPL's algorithms return a result directly rather than a
 * SYCL event, so we can't extract GPU-event-precise kernel timestamps the
 * way the hand-written harnesses can.  We measure via std::chrono around
 * the reduce + final sync; this captures kernel time + a small amount of
 * host overhead.  This is the same timing approach the CUB harness on the
 * NVIDIA side could use (and does, when using CUB's higher-level APIs).
 */

#include <oneapi/dpl/execution>
#include <oneapi/dpl/algorithm>
#include <oneapi/dpl/numeric>

#include <sycl/sycl.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <vector>

int main(int argc, char** argv) {
    int N          = argc > 1 ? std::atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? std::atoi(argv[2]) : 50;
    int iterations = argc > 3 ? std::atoi(argv[3]) : 100;

    sycl::queue q(sycl::gpu_selector_v,
                  sycl::property::queue::enable_profiling{});
    auto dev = q.get_device();
    std::fprintf(stderr, "Device: %s\n",
                 dev.get_info<sycl::info::device::name>().c_str());

    // ------------------------------------------------------------------
    // Allocate input
    // ------------------------------------------------------------------
    float* d_input = sycl::malloc_device<float>(N, q);
    {
        std::vector<float> h_input(N, 1.0f);
        q.memcpy(d_input, h_input.data(), N * sizeof(float)).wait();
    }

    auto policy = oneapi::dpl::execution::make_device_policy(q);

    // ------------------------------------------------------------------
    // Warmup
    // ------------------------------------------------------------------
    float dummy = 0.0f;
    for (int i = 0; i < warmup; i++) {
        dummy += oneapi::dpl::reduce(policy, d_input, d_input + N, 0.0f);
    }
    q.wait();
    (void)dummy;  // keep the loop alive against DCE

    // ------------------------------------------------------------------
    // Measured runs
    // ------------------------------------------------------------------
    std::vector<double> kernel_times_us(iterations);
    std::vector<double> wall_times_us(iterations);
    float result = 0.0f;

    for (int i = 0; i < iterations; i++) {
        q.wait();
        auto wall_start = std::chrono::high_resolution_clock::now();
        // Both kernel and wall time captured by chrono around the reduce
        // + sync.  oneDPL doesn't expose a SYCL event we can use for
        // GPU-only timing; this is the best we can do with the public API.
        result = oneapi::dpl::reduce(policy, d_input, d_input + N, 0.0f);
        q.wait();
        auto wall_end = std::chrono::high_resolution_clock::now();
        double dur = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
        kernel_times_us[i] = dur;
        wall_times_us[i]   = dur;
    }

    float expected = (float)N;
    bool correct = std::fabs(result - expected) < expected * 1e-3f;

    // ------------------------------------------------------------------
    // Stats + JSON output
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
    std::printf("  \"implementation\": \"onedpl\",\n");
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
    return correct ? 0 : 1;
}
