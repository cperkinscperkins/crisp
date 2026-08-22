// 154 — minimal cuBLAS tf32 GEMM baseline.
//
// Purpose: REPORT.md's NVIDIA ladder stops at 4096, so the cooperative kernel's 8192 result has
// nothing to be measured against.  This supplies the missing ceiling.
//
// Validation discipline: it is run at 4096 FIRST, where REPORT.md already records cuBLAS at
// 380.96 TFLOPS.  If this harness does not reproduce that, its 8192 number is not trustworthy
// and must not be used.
//
// Same protocol as the Crisp harness: WARMUP=20, ITERS=100, cudaEvent-timed around the loop,
// TF32 compute (CUBLAS_COMPUTE_32F_FAST_TF32) to match Crisp's `fast` precision.
//
// build: nvcc -O3 -arch=sm_90a cublas_ref.cu -o cublas_ref -lcublas
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cuda_runtime.h>
#include <cublas_v2.h>

#define CK(x)  do { cudaError_t e=(x); if(e!=cudaSuccess){ std::printf("CUDA FAIL %s: %s\n", #x, cudaGetErrorString(e)); std::exit(1);} } while(0)
#define CBK(x) do { cublasStatus_t s=(x); if(s!=CUBLAS_STATUS_SUCCESS){ std::printf("CUBLAS FAIL %s: %d\n", #x, (int)s); std::exit(1);} } while(0)

int main(int argc, char** argv) {
    int n = (argc > 1) ? std::atoi(argv[1]) : 4096;
    const int WARMUP = 20, ITERS = 100;
    size_t sz = (size_t)n * n * sizeof(float);

    float *dA, *dB, *dC;
    CK(cudaMalloc(&dA, sz)); CK(cudaMalloc(&dB, sz)); CK(cudaMalloc(&dC, sz));
    std::vector<float> h((size_t)n * n, 1.0f);
    CK(cudaMemcpy(dA, h.data(), sz, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, h.data(), sz, cudaMemcpyHostToDevice));

    cublasHandle_t handle;
    CBK(cublasCreate(&handle));
    // TF32 to match Crisp's `fast` precision — an fp32-compute comparison would be a different
    // (and much slower) ceiling and would flatter Crisp.
    CBK(cublasSetMathMode(handle, CUBLAS_TF32_TENSOR_OP_MATH));

    const float alpha = 1.0f, beta = 0.0f;
    // cuBLAS is column-major; computing C^T = B^T * A^T with swapped operands yields the
    // row-major C = A*B.  FLOP count is identical either way, which is all this measures.
    auto gemm = [&]() {
        CBK(cublasGemmEx(handle, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n,
                         &alpha, dB, CUDA_R_32F, n, dA, CUDA_R_32F, n,
                         &beta,  dC, CUDA_R_32F, n,
                         CUBLAS_COMPUTE_32F_FAST_TF32, CUBLAS_GEMM_DEFAULT_TENSOR_OP));
    };

    for (int i = 0; i < WARMUP; ++i) gemm();
    CK(cudaDeviceSynchronize());

    cudaEvent_t ev0, ev1; CK(cudaEventCreate(&ev0)); CK(cudaEventCreate(&ev1));
    CK(cudaEventRecord(ev0));
    for (int i = 0; i < ITERS; ++i) gemm();
    CK(cudaEventRecord(ev1));
    CK(cudaEventSynchronize(ev1));
    float ms = 0.f; CK(cudaEventElapsedTime(&ms, ev0, ev1));

    double gflops = (2.0 * n * n * (double)n * ITERS) / (ms * 1.0e6);
    std::printf("CUBLAS %dx%dx%d: %.1f GFLOPS (%.6f ms/iter)\n", n, n, n, gflops, ms / ITERS);

    cublasDestroy(handle);
    CK(cudaFree(dA)); CK(cudaFree(dB)); CK(cudaFree(dC));
    return 0;
}
