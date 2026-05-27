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

#include <cub/cub.cuh>

int main(int argc, char** argv) {
    int N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int iterations = argc > 3 ? atoi(argv[3]) : 100;

    // Host data: fill with 1.0f so expected sum = N
    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    float* d_input;
    float* d_output;
    cudaMalloc(&d_input, N * sizeof(float));
    cudaMalloc(&d_output, sizeof(float));
    cudaMemcpy(d_input, h_input, N * sizeof(float), cudaMemcpyHostToDevice);

    // Determine temp storage requirements
    void* d_temp = nullptr;
    size_t temp_bytes = 0;
    cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N);
    cudaMalloc(&d_temp, temp_bytes);

    // Warmup
    for (int i = 0; i < warmup; i++) {
        cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N);
    }
    cudaDeviceSynchronize();

    // Measured runs
    std::vector<float> times(iterations);
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    for (int i = 0; i < iterations; i++) {
        cudaEventRecord(start);
        cub::DeviceReduce::Sum(d_temp, temp_bytes, d_input, d_output, N);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&times[i], start, stop);
    }

    // Read result
    float result;
    cudaMemcpy(&result, d_output, sizeof(float), cudaMemcpyDeviceToHost);

    float expected = (float)N;
    bool correct = fabs(result - expected) < expected * 1e-4f;

    // Statistics
    std::sort(times.begin(), times.end());
    float median = times[iterations / 2];
    float min_t  = times[0];
    float sum_t  = std::accumulate(times.begin(), times.end(), 0.0f);
    float mean   = sum_t / iterations;
    float var    = 0.0f;
    for (float t : times) var += (t - mean) * (t - mean);
    float stddev = sqrtf(var / iterations);
    float throughput_gb = (N * sizeof(float) / 1e9f) / (median / 1e3f);

    // JSON output
    printf("{\n");
    printf("  \"algorithm\": \"reduction\",\n");
    printf("  \"implementation\": \"cub\",\n");
    printf("  \"N\": %d,\n", N);
    printf("  \"warmup\": %d,\n", warmup);
    printf("  \"iterations\": %d,\n", iterations);
    printf("  \"correct\": %s,\n", correct ? "true" : "false");
    printf("  \"result\": %.1f,\n", result);
    printf("  \"expected\": %.1f,\n", expected);
    printf("  \"kernel_median_us\": %.2f,\n", median * 1000.0f);
    printf("  \"kernel_min_us\": %.2f,\n", min_t * 1000.0f);
    printf("  \"kernel_mean_us\": %.2f,\n", mean * 1000.0f);
    printf("  \"kernel_stddev_us\": %.2f,\n", stddev * 1000.0f);
    printf("  \"throughput_gb_s\": %.2f\n", throughput_gb);
    printf("}\n");

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(d_input);
    cudaFree(d_output);
    cudaFree(d_temp);
    delete[] h_input;

    return correct ? 0 : 1;
}
