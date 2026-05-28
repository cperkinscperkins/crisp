/*
 * Hand-written CUDA sum reduction benchmark.
 * Classic tree-reduce: each block reduces to a single value via shared memory,
 * then a second pass reduces the block results.
 *
 * Usage: ./sum_reduce [N] [warmup] [iterations]
 *
 * Output: JSON to stdout with timing statistics.
 *
 * Compile: nvcc -O3 -o sum_reduce sum_reduce.cu
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <vector>
#include <numeric>
#include <chrono>

#define BLOCK_SIZE 256

__global__ void reduce_sum(const float* __restrict__ input, float* __restrict__ output, int n) {
    __shared__ float sdata[BLOCK_SIZE];

    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;

    float val = 0.0f;
    if (i < n) val = input[i];
    if (i + blockDim.x < n) val += input[i + blockDim.x];
    sdata[tid] = val;
    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    if (tid == 0) output[blockIdx.x] = sdata[0];
}

struct ReduceState {
    float *d_partial, *d_partial2;
    float *h_partial;
    int blocks, blocks2;

    ReduceState(int n) {
        blocks  = (n + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
        blocks2 = (blocks + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
        cudaMalloc(&d_partial,  blocks  * sizeof(float));
        cudaMalloc(&d_partial2, blocks2 * sizeof(float));
        h_partial = new float[std::max(blocks, blocks2)];
    }
    ~ReduceState() {
        cudaFree(d_partial);
        cudaFree(d_partial2);
        delete[] h_partial;
    }
};

float gpu_reduce(const float* d_input, int n, ReduceState& st) {
    reduce_sum<<<st.blocks, BLOCK_SIZE>>>(d_input, st.d_partial, n);

    if (st.blocks > 1) {
        reduce_sum<<<st.blocks2, BLOCK_SIZE>>>(st.d_partial, st.d_partial2, st.blocks);
        int final_count = st.blocks2;
        cudaMemcpy(st.h_partial, st.d_partial2,
                   final_count * sizeof(float), cudaMemcpyDeviceToHost);
        float sum = 0.0f;
        for (int i = 0; i < final_count; i++) sum += st.h_partial[i];
        return sum;
    }

    float result;
    cudaMemcpy(&result, st.d_partial, sizeof(float), cudaMemcpyDeviceToHost);
    return result;
}

int main(int argc, char** argv) {
    int N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int iterations = argc > 3 ? atoi(argv[3]) : 100;

    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    float* d_input;
    cudaMalloc(&d_input, N * sizeof(float));
    cudaMemcpy(d_input, h_input, N * sizeof(float), cudaMemcpyHostToDevice);

    ReduceState state(N);

    // Warmup
    for (int i = 0; i < warmup; i++) {
        gpu_reduce(d_input, N, state);
    }
    cudaDeviceSynchronize();

    // Measured runs — kernel time (GPU events) + wall time (host chrono)
    std::vector<float> kernel_times(iterations);
    std::vector<double> wall_times(iterations);
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    float result = 0.0f;
    for (int i = 0; i < iterations; i++) {
        auto wall_start = std::chrono::high_resolution_clock::now();

        cudaEventRecord(start);
        result = gpu_reduce(d_input, N, state);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        auto wall_end = std::chrono::high_resolution_clock::now();
        cudaEventElapsedTime(&kernel_times[i], start, stop);
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
    printf("  \"implementation\": \"cuda\",\n");
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
    delete[] h_input;

    return correct ? 0 : 1;
}
