/*
 * Hand-written CUDA sum reduction benchmark.
 * Classic tree-reduce: each block reduces to a single value via shared memory,
 * then a second pass reduces the block results.
 *
 * Usage: ./sum_reduce [N] [warmup] [iterations]
 *   N          = number of elements (default: 1000000)
 *   warmup     = warmup iterations (default: 50)
 *   iterations = measured iterations (default: 100)
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

#define BLOCK_SIZE 256

__global__ void reduce_sum(const float* __restrict__ input, float* __restrict__ output, int n) {
    __shared__ float sdata[BLOCK_SIZE];

    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;

    // Load two elements per thread (reduces idle threads in first iteration)
    float val = 0.0f;
    if (i < n) val = input[i];
    if (i + blockDim.x < n) val += input[i + blockDim.x];
    sdata[tid] = val;
    __syncthreads();

    // Tree reduction in shared memory
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    if (tid == 0) output[blockIdx.x] = sdata[0];
}

// Pre-allocated reduction state to avoid cudaMalloc inside timing loop.
struct ReduceState {
    float *d_partial, *d_partial2;
    int blocks, blocks2;

    ReduceState(int n) {
        blocks  = (n + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
        blocks2 = (blocks + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
        cudaMalloc(&d_partial,  blocks  * sizeof(float));
        cudaMalloc(&d_partial2, blocks2 * sizeof(float));
    }
    ~ReduceState() {
        cudaFree(d_partial);
        cudaFree(d_partial2);
    }
};

float gpu_reduce(const float* d_input, int n, ReduceState& st) {
    // First pass: N -> blocks partial sums
    reduce_sum<<<st.blocks, BLOCK_SIZE>>>(d_input, st.d_partial, n);

    // Second pass: blocks -> blocks2
    if (st.blocks > 1) {
        reduce_sum<<<st.blocks2, BLOCK_SIZE>>>(st.d_partial, st.d_partial2, st.blocks);
        // Final host reduction if blocks2 > 1
        int final_count = st.blocks2 > 1 ? st.blocks2 : 1;
        float* src = st.blocks2 > 1 ? st.d_partial2 : st.d_partial2;
        float* h = new float[final_count];
        cudaMemcpy(h, (st.blocks > 1 && st.blocks2 == 1) ? st.d_partial2 : st.d_partial2,
                   final_count * sizeof(float), cudaMemcpyDeviceToHost);
        float sum = 0.0f;
        for (int i = 0; i < final_count; i++) sum += h[i];
        delete[] h;
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

    // Host data: fill with 1.0f so expected sum = N
    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    float* d_input;
    cudaMalloc(&d_input, N * sizeof(float));
    cudaMemcpy(d_input, h_input, N * sizeof(float), cudaMemcpyHostToDevice);

    // Pre-allocate reduction buffers
    ReduceState state(N);

    // Warmup
    for (int i = 0; i < warmup; i++) {
        gpu_reduce(d_input, N, state);
    }
    cudaDeviceSynchronize();

    // Measured runs
    std::vector<float> times(iterations);
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    float result = 0.0f;
    for (int i = 0; i < iterations; i++) {
        cudaEventRecord(start);
        result = gpu_reduce(d_input, N, state);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&times[i], start, stop);
    }

    // Verify correctness
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
    printf("  \"implementation\": \"cuda\",\n");
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
    delete[] h_input;

    return correct ? 0 : 1;
}
