/*
 * Benchmark harness for Crisp-compiled PTX sum reduction.
 * Loads the PTX, allocates memory, runs warmup+measured iterations,
 * outputs JSON timing results — same format as the CUDA/CUB benchmarks.
 *
 * Usage: ./sum_reduce_crisp [N] [warmup] [iterations]
 *
 * Compile: nvcc -O3 bench_harness.cu -lcuda -o sum_reduce_crisp
 *
 * Expects sum-reduce.ptx in the same directory.
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

#define CUDA_CHECK(call) do { \
    CUresult _r = (call); \
    if (_r != CUDA_SUCCESS) { \
        const char* _e; cuGetErrorString(_r, &_e); \
        fprintf(stderr, "CUDA error at %s:%d — %s\n", __FILE__, __LINE__, _e); \
        exit(1); \
    } \
} while(0)

std::string read_ptx_file(const char* filename) {
    std::ifstream file(filename);
    if (!file) {
        fprintf(stderr, "Failed to open PTX file: %s\n", filename);
        exit(1);
    }
    return std::string((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
    int N          = argc > 1 ? atoi(argv[1]) : 1000000;
    int warmup     = argc > 2 ? atoi(argv[2]) : 50;
    int iterations = argc > 3 ? atoi(argv[3]) : 100;

    // Find PTX file (same directory as binary, or current dir)
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

    // CUDA init
    CUDA_CHECK(cuInit(0));
    CUdevice device;
    CUDA_CHECK(cuDeviceGet(&device, 0));
    CUcontext context;
    CUDA_CHECK(cuCtxCreate(&context, 0, device));

    // Load PTX module
    CUmodule module;
    CUDA_CHECK(cuModuleLoadData(&module, ptx_text.c_str()));
    CUfunction kernel;
    CUDA_CHECK(cuModuleGetFunction(&kernel, module, "sum_reduce"));

    // Allocate: input vector (6-tuple) + result cell (3-tuple)
    // Input: N floats, iota-initialized to 1.0f
    float* h_input = new float[N];
    for (int i = 0; i < N; i++) h_input[i] = 1.0f;

    CUdeviceptr d_input;
    CUDA_CHECK(cuMemAlloc(&d_input, N * sizeof(float)));
    CUDA_CHECK(cuMemcpyHtoD(d_input, h_input, N * sizeof(float)));

    // Result cell: single float, zero-initialized
    CUdeviceptr d_result;
    CUDA_CHECK(cuMemAlloc(&d_result, sizeof(float)));

    // Kernel params: input tensor 6-tuple + result cell 3-tuple = 9 args
    uint64_t input_byte_size = N * sizeof(float);
    uint64_t input_off0 = 0;
    uint64_t input_str0 = 1;
    uint64_t input_ext0 = (uint64_t)N;
    uint64_t input_length = (uint64_t)N;

    uint64_t result_byte_size = sizeof(float);
    uint64_t result_offset = 0;

    // Helper: reset result to zero and launch
    auto run_once = [&]() {
        float zero = 0.0f;
        cuMemcpyHtoD(d_result, &zero, sizeof(float));

        void* params[9] = {
            &d_input, &input_byte_size, &input_off0,
            &input_str0, &input_ext0, &input_length,
            &d_result, &result_byte_size, &result_offset,
        };

        // Launch: 256 blocks x 256 threads (= 65536 global threads)
        CUDA_CHECK(cuLaunchKernel(kernel,
            256, 1, 1,    // grid
            256, 1, 1,    // block
            0, 0,         // shared mem, stream
            params, nullptr));
    };

    // Warmup
    for (int i = 0; i < warmup; i++) {
        run_once();
    }
    CUDA_CHECK(cuCtxSynchronize());

    // Measured runs
    std::vector<float> times(iterations);
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    for (int i = 0; i < iterations; i++) {
        cudaEventRecord(start);
        run_once();
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&times[i], start, stop);
    }

    // Read result
    float result;
    CUDA_CHECK(cuMemcpyDtoH(&result, d_result, sizeof(float)));

    float expected = (float)N;
    bool correct = fabs(result - expected) < expected * 1e-3f;

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
    printf("  \"implementation\": \"crisp\",\n");
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
    cuMemFree(d_input);
    cuMemFree(d_result);
    delete[] h_input;

    return correct ? 0 : 1;
}
