// cuBLAS bf16 GEMM peak reference (argv M N K) — the NVIDIA CEILING for §2.2.
//
// Twin of sec2_top_fp16/cublas_ceiling_fp16.cu; the ONLY intended difference is the operand type
// (CUDA_R_16BF vs CUDA_R_16F) and the host element type.  If you change one, change both.
//
// SHAPE OF THE COMPARISON.  bf16 operands, **f32 accumulate**, f32 C — matching what Crisp's
// tensor-core path does and what the Intel side's onemkl_bf16.cpp does (bf16 A/B, float C).
// A 16-bit C would measure a different computation and is not comparable.
//
// -DFAST_MATH HAS NOTHING TO SELECT HERE, and that differs from the fp16 twin's reason.  For
// fp16 inputs cuBLAS does offer a reduced-accumulate compute type (CUBLAS_COMPUTE_16F), which
// the twin declines on purpose.  For bf16 inputs there is no such type at all — bf16 GEMM
// accumulates in f32 by construction — so the flag is accepted and is a no-op by the library's
// own design, not by our choice.  Both files therefore measure an f32-accumulate GEMM in both
// precision modes, which is what makes the fp16 and bf16 ceilings comparable to each other.
//
// nvcc -O3 -arch=sm_90 cublas_ceiling_bf16.cu -lcublas -o cublas_ceiling_bf16
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

int main(int argc, char** argv) {
  auto wall_start = std::chrono::high_resolution_clock::now();
  int M      = argc > 1 ? atoi(argv[1]) : 1024;
  int N      = argc > 2 ? atoi(argv[2]) : 1024;
  int K      = argc > 3 ? atoi(argv[3]) : 1024;
  int warmup = argc > 4 ? atoi(argv[4]) : 20;
  int iters  = argc > 5 ? atoi(argv[5]) : 100;

  // A = B = 1 => C = K exactly.  1.0 is exact in bf16 and the accumulation is f32, so this
  // oracle is as hard here as it is in the tf32 chapter.  The tf32 ceiling memsets its inputs
  // to zero and checks NOTHING; a ceiling that never verifies can be mis-specified into a
  // different (faster) computation and read as a legitimate number, which is the failure this
  // benchmark tree has been burned by twice.  Verified ceilings only.
  std::vector<__nv_bfloat16> hA((size_t)M * K, __float2bfloat16(1.0f));
  std::vector<__nv_bfloat16> hB((size_t)K * N, __float2bfloat16(1.0f));
  std::vector<float>  hC((size_t)M * N, 0.0f);

  __nv_bfloat16 *dA, *dB; float *dC;
  CK(cudaMalloc(&dA, hA.size() * sizeof(__nv_bfloat16)));
  CK(cudaMalloc(&dB, hB.size() * sizeof(__nv_bfloat16)));
  CK(cudaMalloc(&dC, hC.size() * sizeof(float)));
  CK(cudaMemcpy(dA, hA.data(), hA.size() * sizeof(__nv_bfloat16), cudaMemcpyHostToDevice));
  CK(cudaMemcpy(dB, hB.data(), hB.size() * sizeof(__nv_bfloat16), cudaMemcpyHostToDevice));

  cublasHandle_t h;
  cublasCreate(&h);
  float alpha = 1.0f, beta = 0.0f;

  auto gemm = [&]() {
    cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &alpha,
                 dA, CUDA_R_16BF, M, dB, CUDA_R_16BF, K, &beta,
                 dC, CUDA_R_32F, M, CUBLAS_COMPUTE_32F, CUBLAS_GEMM_DEFAULT);
  };

  for (int i = 0; i < warmup; i++) gemm();
  CK(cudaDeviceSynchronize());

  std::vector<float> kt(iters);
  cudaEvent_t s, e;
  cudaEventCreate(&s); cudaEventCreate(&e);
  for (int i = 0; i < iters; i++) {
    cudaEventRecord(s); gemm(); cudaEventRecord(e); cudaEventSynchronize(e);
    cudaEventElapsedTime(&kt[i], s, e);
  }

  CK(cudaMemcpy(hC.data(), dC, hC.size() * sizeof(float), cudaMemcpyDeviceToHost));
  double expected = (double)K, maxerr = 0.0;
  for (size_t i = 0; i < hC.size(); i++) maxerr = std::max(maxerr, (double)std::fabs(hC[i] - expected));
  bool correct = maxerr < expected * 1e-3;

  std::sort(kt.begin(), kt.end());
  double k_med = kt[iters / 2] * 1000.0, k_min = kt[0] * 1000.0;
  double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

  auto wall_end = std::chrono::high_resolution_clock::now();
  double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

  printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublas\",\n");
  printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
  printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
  printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
  printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
  printf("  \"gflops\": %.2f\n}\n", gflops);

  cublasDestroy(h);
  cudaFree(dA); cudaFree(dB); cudaFree(dC);
  return correct ? 0 : 1;
}
