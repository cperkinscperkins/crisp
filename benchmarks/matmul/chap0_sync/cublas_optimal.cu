// cuBLAS tf32 GEMM peak reference (argv M N K) — C = A·B at tf32 tensor-core precision.
// Matches the Crisp benchmark's FLOP count (2·M·N·K) so GFLOPS are directly comparable.
// nvcc -arch=sm_90a cublas_bench.cu -lcublas -o cublas_bench
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
  int M = argc > 1 ? atoi(argv[1]) : 1024;
  int N = argc > 2 ? atoi(argv[2]) : 1024;
  int K = argc > 3 ? atoi(argv[3]) : 1024;

  float *dA, *dB, *dC;
  cudaMalloc(&dA, (size_t)M * K * sizeof(float));
  cudaMalloc(&dB, (size_t)K * N * sizeof(float));
  cudaMalloc(&dC, (size_t)M * N * sizeof(float));
  cudaMemset(dA, 0, (size_t)M * K * sizeof(float));
  cudaMemset(dB, 0, (size_t)K * N * sizeof(float));

  cublasHandle_t h;
  cublasCreate(&h);
  float alpha = 1.0f, beta = 0.0f;

  // tf32 tensor cores via CUBLAS_COMPUTE_32F_FAST_TF32.  Layout is irrelevant for a peak
  // throughput reference (same 2·M·N·K FLOPs); we treat everything column-major NxN.
  auto gemm = [&]() {
    cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &alpha,
                 dA, CUDA_R_32F, M, dB, CUDA_R_32F, K, &beta,
                 dC, CUDA_R_32F, M, CUBLAS_COMPUTE_32F_FAST_TF32, CUBLAS_GEMM_DEFAULT);
  };

  for (int i = 0; i < 20; i++) gemm();
  cudaDeviceSynchronize();

  cudaEvent_t s, e;
  cudaEventCreate(&s); cudaEventCreate(&e);
  cudaEventRecord(s);
  for (int i = 0; i < 100; i++) gemm();
  cudaEventRecord(e); cudaEventSynchronize(e);
  float ms = 0.0f; cudaEventElapsedTime(&ms, s, e);

  double gflops = (2.0 * M * N * K * 100) / (ms * 1.0e6);
  printf("CUBLAS %dx%dx%d: %.1f GFLOPS (%.5f ms/iter)\n", M, N, K, gflops, ms / 100);

  cublasDestroy(h);
  cudaFree(dA); cudaFree(dB); cudaFree(dC);
  return 0;
}
