/*
 * Benchmark harness for Crisp-compiled PTX sum reduction.
 * Loads sum-reduce.ptx and calls the sum_reduce kernel.
 *
 * Usage: ./sum_reduce_crisp [N] [warmup] [iterations] [occupancy]
 *   occupancy = 0.0..1.0 ratio for grid sizing (default: 1.0 = max occupancy)
 *               Mirrors what the Crisp CUDA hoist would emit for
 *               (global-size :derive-from input :strategy :strided :occupancy R).
 *
 * Compile: nvcc -O3 bench_harness.cu -lcuda -o sum_reduce_crisp
 */

#include <cuda.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <numeric>
#include <fstream>
#include <string>
#include <chrono>

#define CUDA_CHECK(call) do { \
    CUresult _r = (call); \
    if (_r != CUDA_SUCCESS) { \
        const char* _e; cuGetErrorString(_r, &_e); \
        fprintf(stderr, "CUDA error at %s:%d — %s\n", __FILE__, __LINE__, _e); \
        exit(1); \
    } \
} while(0)

int main(int argc, char** argv) {
    int    N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int    warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int    iterations = argc > 3 ? atoi(argv[3]) : 100;
    double occupancy  = argc > 4 ? atof(argv[4]) : 1.0;
    if (occupancy <= 0.0 || occupancy > 1.0) {
        fprintf(stderr, "occupancy must be in (0.0, 1.0], got %f\n", occupancy);
        return 1;
    }

    const char* ptx_candidates[] = {
        "sum-reduce.ptx",
        "benchmarks/reduction/crisp/sum-reduce.ptx",
    };
    std::string ptx_text;
    const char* ptx_used = nullptr;
    for (auto* c : ptx_candidates) {
        std::ifstream test(c);
        if (test.good()) {
            ptx_used = c;
            ptx_text = std::string((std::istreambuf_iterator<char>(test)),
                                    std::istreambuf_iterator<char>());
            break;
        }
    }
    if (!ptx_used) {
        fprintf(stderr, "Cannot find sum-reduce.ptx\n");
        return 1;
    }

    CUDA_CHECK(cuInit(0));
    CUdevice device;
    CUDA_CHECK(cuDeviceGet(&device, 0));
    CUcontext context;
    CUDA_CHECK(cuCtxCreate(&context, 0, device));

    CUmodule module;
    CUDA_CHECK(cuModuleLoadData(&module, ptx_text.c_str()));
    CUfunction kernel;
    CUDA_CHECK(cuModuleGetFunction(&kernel, module, "sum_reduce"));

    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    CUdeviceptr d_input;
    CUDA_CHECK(cuMemAlloc(&d_input, N * sizeof(float)));
    CUDA_CHECK(cuMemcpyHtoD(d_input, h_input, N * sizeof(float)));

    CUdeviceptr d_result;
    CUDA_CHECK(cuMemAlloc(&d_result, sizeof(float)));

    // Scratch vector (implicit param — comes FIRST in PTX kernel sig).
    // make-scratch-vector :match-workgroup-size with lsize=256, float → 256 floats = 1024 bytes.
    uint64_t slm_ptr        = 0;     // shared-memory offset, demoted from addrspace(3) ptr to i64
    uint64_t slm_byte_size  = 256 * sizeof(float);
    uint64_t slm_off0       = 0;
    uint64_t slm_str0       = 1;
    uint64_t slm_ext0       = 256;
    uint64_t slm_length     = 256;

    // Input tensor (declared param, 6-tuple)
    uint64_t input_byte_size = N * sizeof(float);
    uint64_t input_off0 = 0;
    uint64_t input_str0 = 1;
    uint64_t input_ext0 = (uint64_t)N;
    uint64_t input_length = (uint64_t)N;

    // Result cell (declared param, 3-tuple)
    uint64_t result_byte_size = sizeof(float);
    uint64_t result_offset = 0;

    // Shared memory for the scratch vector
    const unsigned int sharedMemBytes = (unsigned int)slm_byte_size;
    const int blockSize = 256;

    // Compute grid size via occupancy (mirrors what the Crisp CUDA hoist would emit
    // for :strategy :strided :occupancy R).
    int blocksPerSM;
    CUDA_CHECK(cuOccupancyMaxActiveBlocksPerMultiprocessor(
        &blocksPerSM, kernel, blockSize, sharedMemBytes));
    int numSMs;
    CUDA_CHECK(cuDeviceGetAttribute(&numSMs, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device));
    unsigned int gridX = (unsigned int)((blocksPerSM * numSMs) * occupancy);
    if (gridX < 1) gridX = 1;
    fprintf(stderr, "Grid: %u blocks (blocksPerSM=%d * numSMs=%d * occupancy=%.2f), block=%d\n",
            gridX, blocksPerSM, numSMs, occupancy, blockSize);

    auto run_once = [&]() {
        float zero = 0.0f;
        cuMemcpyHtoD(d_result, &zero, sizeof(float));

        // 15 params: scratch (6) + input (6) + result (3)
        void* params[15] = {
            &slm_ptr, &slm_byte_size, &slm_off0,
            &slm_str0, &slm_ext0, &slm_length,
            &d_input, &input_byte_size, &input_off0,
            &input_str0, &input_ext0, &input_length,
            &d_result, &result_byte_size, &result_offset,
        };

        CUDA_CHECK(cuLaunchKernel(kernel,
            gridX, 1, 1,
            blockSize, 1, 1,
            sharedMemBytes, 0,
            params, nullptr));
    };

    // Warmup
    for (int i = 0; i < warmup; i++) {
        run_once();
    }
    CUDA_CHECK(cuCtxSynchronize());

    // Measured runs
    std::vector<float> kernel_times(iterations);
    std::vector<double> wall_times(iterations);
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    for (int i = 0; i < iterations; i++) {
        auto wall_start = std::chrono::high_resolution_clock::now();

        cudaEventRecord(start);
        run_once();
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float tmp;
        CUDA_CHECK(cuMemcpyDtoH(&tmp, d_result, sizeof(float)));

        auto wall_end = std::chrono::high_resolution_clock::now();
        cudaEventElapsedTime(&kernel_times[i], start, stop);
        wall_times[i] = std::chrono::duration<double, std::micro>(wall_end - wall_start).count();
    }

    float result;
    CUDA_CHECK(cuMemcpyDtoH(&result, d_result, sizeof(float)));

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
    printf("  \"implementation\": \"crisp\",\n");
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
    cuMemFree(d_input);
    cuMemFree(d_result);
    delete[] h_input;

    return correct ? 0 : 1;
}
