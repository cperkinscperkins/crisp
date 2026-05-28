/*
 * Benchmark harness for Crisp-compiled PTX sum reduction (TREE-REDUCE version).
 * Same structure as bench_harness.cu but loads sum-reduce-tree.ptx and calls
 * the sum_reduce_tree kernel.
 *
 * Usage: ./sum_reduce_crisp_tree [N] [warmup] [iterations]
 *
 * Compile: nvcc -O3 bench_harness_tree.cu -lcuda -o sum_reduce_crisp_tree
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
    int N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int iterations = argc > 3 ? atoi(argv[3]) : 100;

    const char* ptx_candidates[] = {
        "sum-reduce-tree.ptx",
        "benchmarks/reduction/crisp/sum-reduce-tree.ptx",
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
        fprintf(stderr, "Cannot find sum-reduce-tree.ptx\n");
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
    CUDA_CHECK(cuModuleGetFunction(&kernel, module, "sum_reduce_tree"));

    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    CUdeviceptr d_input;
    CUDA_CHECK(cuMemAlloc(&d_input, N * sizeof(float)));
    CUDA_CHECK(cuMemcpyHtoD(d_input, h_input, N * sizeof(float)));

    CUdeviceptr d_result;
    CUDA_CHECK(cuMemAlloc(&d_result, sizeof(float)));

    uint64_t input_byte_size = N * sizeof(float);
    uint64_t input_off0 = 0;
    uint64_t input_str0 = 1;
    uint64_t input_ext0 = (uint64_t)N;
    uint64_t input_length = (uint64_t)N;
    uint64_t result_byte_size = sizeof(float);
    uint64_t result_offset = 0;

    // Shared memory for the scratch vector: 256 floats = 1024 bytes
    const unsigned int sharedMemBytes = 256 * sizeof(float);

    auto run_once = [&]() {
        float zero = 0.0f;
        cuMemcpyHtoD(d_result, &zero, sizeof(float));

        void* params[9] = {
            &d_input, &input_byte_size, &input_off0,
            &input_str0, &input_ext0, &input_length,
            &d_result, &result_byte_size, &result_offset,
        };

        CUDA_CHECK(cuLaunchKernel(kernel,
            256, 1, 1,
            256, 1, 1,
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
    printf("  \"implementation\": \"crisp_tree\",\n");
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
