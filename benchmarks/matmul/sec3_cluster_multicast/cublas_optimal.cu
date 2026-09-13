// cuBLAS tf32 GEMM peak reference (argv M N K) — C = A·B at tf32 tensor-core precision.
// Matches the Crisp benchmark's FLOP count (2·M·N·K) so GFLOPS are directly comparable.
// nvcc -arch=sm_90a cublas_bench.cu -lcublas -o cublas_bench
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include "../common/fill_cuda.cuh"
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
  // Shared fill (common/fill_cuda.cuh).  This used to zero A and B and never check C, so its
  // "correct" was only ever the harness default -- a Ceiling number with no verification behind it.
  crisp_bench::cuda_fill_encoded(dA, (uint64_t)M * K, crisp_bench::FILL_MOD_A, "f32");
  crisp_bench::cuda_fill_encoded(dB, (uint64_t)K * N, crisp_bench::FILL_MOD_B, "f32");

  cublasHandle_t h;
  cublasCreate(&h);
  float alpha = 1.0f, beta = 0.0f;

  int warmup = argc > 4 ? atoi(argv[4]) : 20;
  int iters = argc > 5 ? atoi(argv[5]) : 100;

  // Precision toggles
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

  for (int i = 0; i < warmup; i++) gemm();
  cudaDeviceSynchronize();

  cudaEvent_t s, e;
  cudaEventCreate(&s); cudaEventCreate(&e);
  cudaEventRecord(s);
  for (int i = 0; i < iters; i++) gemm();
  cudaEventRecord(e); cudaEventSynchronize(e);
  float ms = 0.0f; cudaEventElapsedTime(&ms, s, e);

  float iter_ms = ms / iters;

  // cuBLAS is column-major: A(i,k) at k*M + i, B(k,j) at j*K + k, C(i,j) at j*M + i.
  const crisp_bench::VerifyResult vr = crisp_bench::cuda_verify(
      dC, "f32", (uint64_t)M, (uint64_t)N, (uint64_t)K,
      crisp_bench::cm(M), crisp_bench::cm(K), crisp_bench::cm(M));
  double gflops = (2.0 * M * N * K) / (iter_ms * 1e-3) / 1e9;

  printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublas\",\n");
  printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M,N,K);
  printf("  \"correct\": %s,\n  \"verified\": %s,\n  \"max_abs_err\": %.3e,\n  \"verify_samples\": %llu,\n",
         vr.verified ? "true" : "false", vr.verified ? "true" : "false", vr.max_abs_err,
         (unsigned long long)vr.checked);
  printf("  \"kernel_median_us\": %.2f,\n", iter_ms * 1000.0);
  printf("  \"gflops\": %.2f\n}\n", gflops);

  cublasDestroy(h);
  cudaFree(dA); cudaFree(dB); cudaFree(dC);
  return vr.verified ? 0 : 1;
}
