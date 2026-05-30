/*
 * CUB library sum reduction benchmark.
 * Uses cub::DeviceReduce::Sum — the industry-standard optimized reduction.
 *
 * Usage: ./sum_reduce_cub [N] [warmup] [iterations]
 *
 * Output: JSON to stdout with timing statistics.
 *
 * Compile: nvcc -O3 -o sum_reduce_cub sum_reduce_cub.cu
 * (CUB ships with CUDA toolkit >= 11.0, no extra includes needed)
 */

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <numeric>
#include <chrono>

#include <cub/cub.cuh>

#define CUDA_CHECK(call) do {                                                  \
    cudaError_t _e = (call);                                                   \
    if (_e != cudaSuccess) {                                                   \
        fprintf(stderr, "CUDA error at %s:%d — %s\n",                          \
                __FILE__, __LINE__, cudaGetErrorString(_e));                   \
        exit(1);                                                               \
    }                                                                          \
} while(0)

int main(int argc, char** argv) {
    int N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int iterations = argc > 3 ? atoi(argv[3]) : 100;

    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    float* d_input;
    float* d_output;
    CUDA_CHECK(cudaMalloc(&d_input, N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_output, sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_input, h_input, N * sizeof(float), cudaMemcpyHostToDevice));

    void* d_temp = nullptr;
    size_t temp_bytes = 0;
    CUDA_CHECK(cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N));
    CUDA_CHECK(cudaMalloc(&d_temp, temp_bytes));

    // Warmup
    for (int i = 0; i < warmup; i++) {
        CUDA_CHECK(cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N));
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    // Measured runs — kernel time (GPU events) + wall time (host chrono)
    std::vector<float> kernel_times(iterations);
    std::vector<double> wall_times(iterations);
    cudaEvent_t start, stop;
    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));

    float result = 0.0f;
    for (int i = 0; i < iterations; i++) {
        auto wall_start = std::chrono::high_resolution_clock::now();

        CUDA_CHECK(cudaEventRecord(start));
        CUDA_CHECK(cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N));
        CUDA_CHECK(cudaEventRecord(stop));
        CUDA_CHECK(cudaEventSynchronize(stop));
        CUDA_CHECK(cudaMemcpy(&result, d_output, sizeof(float), cudaMemcpyDeviceToHost));

        auto wall_end = std::chrono::high_resolution_clock::now();
        CUDA_CHECK(cudaEventElapsedTime(&kernel_times[i], start, stop));
        wall_times[i] = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
    }

    float expected = (float)N;
    bool correct = fabs(result - expected) < expected * 1e-4f;

    // Kernel statistics
    std::sort(kernel_times.begin(), kernel_times.end());
    float k_median = kernel_times[iterations / 2];
    float k_min    = kernel_times[0];
    float k_sum    = std::accumulate(kernel_times.begin(), kernel_times.end(), 0.0f);
    float k_mean   = k_sum / iterations;
    float k_var    = 0.0f;
    for (float t : kernel_times) k_var += (t - k_mean) * (t - k_mean);
    float k_stddev = sqrtf(k_var / iterations);
    float throughput_gb = (N * sizeof(float) / 1e9f) / (k_median / 1e3f);

    // Wall statistics
    std::sort(wall_times.begin(), wall_times.end());
    double w_median = wall_times[iterations / 2];
    double w_min    = wall_times[0];

    printf("{\n");
    printf("  \"algorithm\": \"reduction\",\n");
    printf("  \"implementation\": \"cub\",\n");
    printf("  \"N\": %d,\n", N);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": %s,\n", correct ? "true" : "false");
    printf("  \"result\": %.1f,\n", result);
    printf("  \"expected\": %.1f,\n", expected);
    printf("  \"kernel_median_us\": %.2f,\n", k_median * 1000.0f);
    printf("  \"kernel_min_us\": %.2f,\n", k_min * 1000.0f);
    printf("  \"kernel_mean_us\": %.2f,\n", k_mean * 1000.0f);
    printf("  \"kernel_stddev_us\": %.2f,\n", k_stddev * 1000.0f);
    printf("  \"throughput_gb_s\": %.2f,\n", throughput_gb);
    printf("  \"wall_median_us\": %.2f,\n", w_median);
    printf("  \"wall_min_us\": %.2f\n", w_min);
    printf("}\n");

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(d_input);
    cudaFree(d_output);
    cudaFree(d_temp);
    delete[] h_input;

    return correct ? 0 : 1;
}
