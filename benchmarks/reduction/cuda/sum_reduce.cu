/*
 * Hand-written CUDA sum reduction benchmark.
 *
 * Algorithm mirrors Crisp's sum_reduce_tree exactly so the comparison is
 * "same algorithm, same launch policy, different source language":
 *   Phase 1: grid-stride accumulation — each thread accumulates a stripe
 *   Phase 2: workgroup tree-reduce in shared memory (halving stride, 8 rounds)
 *   Phase 3: thread 0 of each block atomicAdds its partial sum to result
 *
 * Launch: cudaOccupancyMaxActiveBlocksPerMultiprocessor with an optional
 * derating factor (matches Crisp's :strategy :strided :occupancy <ratio>).
 *
 * Usage: ./sum_reduce [N] [warmup] [iterations] [occupancy]
 *   occupancy = 0.0..1.0 ratio for grid sizing (default: 1.0 = max occupancy)
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

#define CUDA_CHECK(call) do {                                                  \
    cudaError_t _e = (call);                                                   \
    if (_e != cudaSuccess) {                                                   \
        fprintf(stderr, "CUDA error at %s:%d — %s\n",                          \
                __FILE__, __LINE__, cudaGetErrorString(_e));                   \
        exit(1);                                                               \
    }                                                                          \
} while(0)

__global__ void reduce_grid_stride_atomic(const float* __restrict__ input,
                                          float* __restrict__ result,
                                          int n) {
    __shared__ float sdata[BLOCK_SIZE];

    int lid     = threadIdx.x;
    int gid     = blockIdx.x * blockDim.x + threadIdx.x;
    int gstride = gridDim.x * blockDim.x;

    // Phase 1: grid-stride accumulation into a register
    float acc = 0.0f;
    for (int i = gid; i < n; i += gstride) {
        acc += input[i];
    }

    // Phase 2: workgroup tree-reduce in shared memory
    sdata[lid] = acc;
    for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        __syncthreads();
        if (lid < stride) {
            sdata[lid] += sdata[lid + stride];
        }
    }

    // Phase 3: one atomicAdd per workgroup
    if (lid == 0) {
        atomicAdd(result, sdata[0]);
    }
}

int main(int argc, char** argv) {
    int    N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int    warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int    iterations = argc > 3 ? atoi(argv[3]) : 100;
    double occupancy  = argc > 4 ? atof(argv[4]) : 1.0;
    if (occupancy <= 0.0 || occupancy > 1.0) {
        fprintf(stderr, "occupancy must be in (0.0, 1.0], got %f\n", occupancy);
        return 1;
    }

    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    float* d_input;
    float* d_result;
    CUDA_CHECK(cudaMalloc(&d_input, N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_result, sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_input, h_input, N * sizeof(float), cudaMemcpyHostToDevice));

    // Occupancy-based grid sizing — mirrors what Crisp's CUDA hoist emits
    // for :strategy :strided :occupancy <ratio>.
    int blocksPerSM;
    CUDA_CHECK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &blocksPerSM, reduce_grid_stride_atomic, BLOCK_SIZE, 0));
    int numSMs;
    CUDA_CHECK(cudaDeviceGetAttribute(&numSMs, cudaDevAttrMultiProcessorCount, 0));
    int gridSize = (int)((blocksPerSM * numSMs) * occupancy);
    if (gridSize < 1) gridSize = 1;
    fprintf(stderr, "Grid: %d blocks (blocksPerSM=%d * numSMs=%d * occupancy=%.2f), block=%d\n",
            gridSize, blocksPerSM, numSMs, occupancy, BLOCK_SIZE);

    auto run_once = [&]() {
        // Reset result before each launch (atomicAdd accumulates)
        CUDA_CHECK(cudaMemsetAsync(d_result, 0, sizeof(float)));
        reduce_grid_stride_atomic<<<gridSize, BLOCK_SIZE>>>(d_input, d_result, N);
        CUDA_CHECK(cudaGetLastError());
    };

    // Warmup
    for (int i = 0; i < warmup; i++) {
        run_once();
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
        run_once();
        CUDA_CHECK(cudaEventRecord(stop));
        CUDA_CHECK(cudaEventSynchronize(stop));

        // Readback inside wall time (matches crisp harness)
        CUDA_CHECK(cudaMemcpy(&result, d_result, sizeof(float), cudaMemcpyDeviceToHost));

        auto wall_end = std::chrono::high_resolution_clock::now();
        CUDA_CHECK(cudaEventElapsedTime(&kernel_times[i], start, stop));
        wall_times[i] = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
    }

    float expected = (float)N;
    bool correct = fabs(result - expected) < expected * 1e-3f;

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
    cudaFree(d_result);
    delete[] h_input;

    return correct ? 0 : 1;
}
