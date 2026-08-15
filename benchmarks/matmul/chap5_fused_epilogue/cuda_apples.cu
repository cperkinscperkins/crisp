/*
 * Chapter 5 (Endeavor 150) — APPLES-TO-APPLES for a matmul WITH A FUSED ACTIVATION, CUDA.
 *
 * Byte-for-byte chap1_async_linear/cuda_apples.cu — the same cuda::pipeline / memcpy_async
 * tiled kernel — with ONE LINE ADDED: ReLU applied to the accumulator before the store,
 * while it is still in a register.
 *
 *     acc = acc > 0.0f ? acc : 0.0f;
 *
 * WHAT THIS CONTENDER IS FOR.  Fusing an epilogue into a kernel you are already hand-writing
 * is trivial — one line here too.  So this is not a test of whether fusion is possible; it is
 * the check on whether CRISP's generated fusion costs anything against a human doing it by
 * hand in the same algorithm.  If Crisp tracks this, the abstraction is free.
 *
 * The interesting comparisons are elsewhere: cublaslt_fused.cu (the vendor CAN fuse relu, so
 * that is the strong baseline) and cublas_optimal.cu (the vendor CANNOT fuse an arbitrary
 * activation, so it pays a second launch — which is the case this whole endeavour is about).
 *
 * A = B = 1 so every C == K exactly, matching the Intel twin and the shared Crisp harness.
 * That makes ReLU a numerical no-op but NOT a timing one — the instruction executes
 * regardless of the value.  Activation correctness is established on metal by the spec
 * ladder (rungs 21/22 check mixed-sign data against hand-computed output), not here.
 */
#include <cuda_runtime.h>
#include <cuda/pipeline>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

#define TS 16
// A row-major [M x K], B col-major [K x N] (B[k + j*K]), C row-major [M x N].
__global__ void matmul_tiled_async_relu(const float* A, const float* B, float* C, int M, int N, int K) {
    __shared__ float As[TS][TS];
    __shared__ float Bs[TS][TS];

    int row = blockIdx.y*TS + threadIdx.y;
    int col = blockIdx.x*TS + threadIdx.x;
    float acc = 0.0f;

    cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();

    for (int t = 0; t < K; t += TS) {
        pipe.producer_acquire();

        if (row < M && t+threadIdx.x < K) {
            cuda::memcpy_async(&As[threadIdx.y][threadIdx.x], &A[row*K + (t+threadIdx.x)], sizeof(float), pipe);
        } else {
            As[threadIdx.y][threadIdx.x] = 0.0f;
        }

        if (col < N && t+threadIdx.y < K) {
            cuda::memcpy_async(&Bs[threadIdx.y][threadIdx.x], &B[(t+threadIdx.y) + col*K], sizeof(float), pipe);
        } else {
            Bs[threadIdx.y][threadIdx.x] = 0.0f;
        }

        pipe.producer_commit();
        pipe.consumer_wait();
        __syncthreads();

        for (int k = 0; k < TS; k++) {
            acc += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        }

        pipe.consumer_release();
        __syncthreads();
    }

    acc = acc > 0.0f ? acc : 0.0f;          // <-- the fused epilogue, by hand
    if (row < M && col < N) C[row*N + col] = acc;
}

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc>1?atoi(argv[1]):256, N = argc>2?atoi(argv[2]):256, K = argc>3?atoi(argv[3]):256;
    int warmup = argc>4?atoi(argv[4]):20, iters = argc>5?atoi(argv[5]):100;

    std::vector<float> hA((size_t)M*K,1.0f), hB((size_t)K*N,1.0f), hC((size_t)M*N,0.0f);
    float *dA,*dB,*dC;
    CK(cudaMalloc(&dA,hA.size()*4)); CK(cudaMalloc(&dB,hB.size()*4)); CK(cudaMalloc(&dC,hC.size()*4));
    CK(cudaMemcpy(dA,hA.data(),hA.size()*4,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB,hB.data(),hB.size()*4,cudaMemcpyHostToDevice));

    dim3 block(TS,TS), grid((N+TS-1)/TS, (M+TS-1)/TS);
    auto launch = [&](){ matmul_tiled_async_relu<<<grid,block>>>(dA,dB,dC,M,N,K); };

    for(int i=0;i<warmup;i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<iters;i++){ cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i],s,e); }

    CK(cudaMemcpy(hC.data(),dC,hC.size()*4,cudaMemcpyDeviceToHost));
    double expected=(double)K, maxerr=0.0;      // A=B=1 => C == K, and relu(K) == K
    for(size_t i=0;i<hC.size();i++) maxerr=std::max(maxerr,(double)fabs(hC[i]-expected));
    bool correct = maxerr < expected*1e-3;

    std::sort(kt.begin(),kt.end());
    double k_med = kt[iters/2]*1000.0, k_min = kt[0]*1000.0;   // ms -> us
    double gflops = (2.0*M*N*K)/(k_med/1e6)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double,std::milli>(wall_end-wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cuda+relu-fused\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N,M,K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct ? 0 : 1;
}
