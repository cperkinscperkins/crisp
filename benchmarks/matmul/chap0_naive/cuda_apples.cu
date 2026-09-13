/*
 * Hand-written CUDA reference matmul (Naive fp32 loops, no shared memory or tensor cores)
 * Section 1 Chapter 0 baseline.
 *
 * Compile: nvcc -O3 -arch=sm_80 cuda_apples.cu -o cuda_apples
 * Run:     ./cuda_apples [M] [N] [K] [warmup] [iters]
 */
#include <cuda_runtime.h>
#include "../common/fill_cuda.cuh"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

// A row-major [M x K], B col-major [K x N] (B[k + col*K]), C row-major [M x N].
__global__ void matmul_naive(const float* A, const float* B, float* C, int M, int N, int K) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (row < M && col < N) {
        float acc = 0.0f;
        for (int k = 0; k < K; k++) {
            acc += A[row * K + k] * B[k + col * K];
        }
        C[row * N + col] = acc;
    }
}

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc>1?atoi(argv[1]):256, N = argc>2?atoi(argv[2]):256, K = argc>3?atoi(argv[3]):256;
    int warmup = argc>4?atoi(argv[4]):20, iters = argc>5?atoi(argv[5]):100;

    float *dA,*dB,*dC;
    CK(cudaMalloc(&dA,((size_t)M * K)*4)); CK(cudaMalloc(&dB,((size_t)K * N)*4)); CK(cudaMalloc(&dC,((size_t)M * N)*4));
    crisp_bench::cuda_fill_encoded(dA, (uint64_t)M * K, crisp_bench::FILL_MOD_A, "f32");
    crisp_bench::cuda_fill_encoded(dB, (uint64_t)K * N, crisp_bench::FILL_MOD_B, "f32");

    dim3 block(16, 16), grid((N+15)/16, (M+15)/16);
    auto launch = [&](){ matmul_naive<<<grid,block>>>(dA,dB,dC,M,N,K); };

    for(int i=0;i<warmup;i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<iters;i++){ cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i],s,e); }

    const crisp_bench::VerifyResult vr = crisp_bench::cuda_verify(dC, "f32", (uint64_t)M, (uint64_t)N, (uint64_t)K, crisp_bench::rm(K), crisp_bench::cm(K), crisp_bench::rm(N));
    double maxerr = vr.max_abs_err;
    bool correct = vr.verified;

    std::sort(kt.begin(),kt.end());
    float k_med=kt[iters/2], k_min=kt[0];
    double gflops=(2.0*M*N*K)/(k_med/1e3)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cuda\",\n");
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M,N,K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med*1000.0, k_min*1000.0);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct?0:1;
}
