/*
 * Chapter 6 (Endeavor 150) — NVIDIA plain-library baseline, CUSTOM activation.
 *
 * cuBLAS GEMM followed by a SEPARATE ReLU kernel over C.  This is the cost structure a user
 * pays whenever their activation is not on cuBLASLt's fixed epilogue menu: a second launch
 * and a full HBM round trip of C.
 *
 * READ THIS TOGETHER WITH cublaslt_fused.cu, which IS allowed to fuse relu.  Comparing Crisp
 * only against this file would be a strawman for plain relu — the vendor can do better — so
 * the chapter runs both:
 *
 *   cublaslt_fused.cu   the vendor fusing relu itself. The STRONG baseline. Their turf.
 *   cublas_optimal.cu   the vendor unable to fuse. What ANY off-menu activation costs.
 *
 * WHAT IS TIMED.  The window runs from before the GEMM launch to after the ReLU launch on the
 * same stream, so it includes the inter-launch gap — which is part of what fusion removes.
 * A mid-point event reports the GEMM alone as gemm_median_us, so the round-trip cost is
 * visible directly in one run rather than inferred across runs.
 *
 * A = B = 1 so every C == K exactly, matching the Intel twin and the Crisp harness; relu is a
 * numerical no-op on that data but still executes.  (The chapter-0 cuBLAS reference memsets to
 * zero and skips correctness; this one checks, because a silently-wrong baseline is worse than
 * no baseline.)
 *
 * nvcc -arch=sm_90a cublas_optimal.cu -lcublas -o cublas_optimal
 */
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

// The activation as its OWN kernel — the cost fusion removes.
__global__ void act_pass(float* C, size_t n) {
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) { float v = C[i]; C[i] = v > 0.5f ? v : v * v * 0.01f; }
}

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc>1?atoi(argv[1]):1024, N = argc>2?atoi(argv[2]):1024, K = argc>3?atoi(argv[3]):1024;
    int warmup = argc>4?atoi(argv[4]):20, iters = argc>5?atoi(argv[5]):100;

    const size_t total = (size_t)M * N;
    std::vector<float> hA((size_t)M*K,1.0f), hB((size_t)K*N,1.0f), hC(total,0.0f);
    float *dA,*dB,*dC;
    CK(cudaMalloc(&dA,hA.size()*4)); CK(cudaMalloc(&dB,hB.size()*4)); CK(cudaMalloc(&dC,total*4));
    CK(cudaMemcpy(dA,hA.data(),hA.size()*4,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB,hB.data(),hB.size()*4,cudaMemcpyHostToDevice));

    cublasHandle_t h; cublasCreate(&h);
    float alpha = 1.0f, beta = 0.0f;

#ifdef FAST_MATH
    cublasComputeType_t comp = CUBLAS_COMPUTE_32F_FAST_TF32;
#else
    cublasComputeType_t comp = CUBLAS_COMPUTE_32F;
#endif

    auto gemm = [&]() {
        cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &alpha,
                     dA, CUDA_R_32F, M, dB, CUDA_R_32F, K, &beta,
                     dC, CUDA_R_32F, M, comp, CUBLAS_GEMM_DEFAULT);
    };
    const int RB = 256;
    dim3 rblock(RB), rgrid((unsigned)((total + RB - 1) / RB));
    auto relu = [&]() { act_pass<<<rgrid, rblock>>>(dC, total); };

    for (int i = 0; i < warmup; i++) { gemm(); relu(); }
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters), gt(iters);
    cudaEvent_t s, mid, e;
    cudaEventCreate(&s); cudaEventCreate(&mid); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s);
        gemm();
        cudaEventRecord(mid);      // same stream: orders after the GEMM
        relu();
        cudaEventRecord(e);
        cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e);     // GEMM + gap + ReLU
        cudaEventElapsedTime(&gt[i], s, mid);   // GEMM alone
    }

    CK(cudaMemcpy(hC.data(),dC,total*4,cudaMemcpyDeviceToHost));
    double expected=(double)K, maxerr=0.0;
    for(size_t i=0;i<total;i++) maxerr=std::max(maxerr,(double)fabs(hC[i]-expected));
    bool correct = maxerr < expected*1e-3;

    std::sort(kt.begin(),kt.end());
    std::sort(gt.begin(),gt.end());
    double k_med = kt[iters/2]*1000.0, k_min = kt[0]*1000.0, g_med = gt[iters/2]*1000.0;
    // Same numerator as the fused kernel's, so the two are directly comparable.
    double gflops = (2.0*M*N*K)/(k_med/1e6)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double,std::milli>(wall_end-wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublas+custom\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N,M,K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gemm_median_us\": %.2f,\n", g_med);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cublasDestroy(h);
    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct ? 0 : 1;
}
