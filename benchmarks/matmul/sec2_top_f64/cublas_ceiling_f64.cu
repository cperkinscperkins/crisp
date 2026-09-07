// cuBLAS fp64 GEMM peak reference (argv M N K) — the NVIDIA CEILING for §2 at 64 bits.
//
// Sibling of sec2_top_bf16/cublas_ceiling_bf16.cu.  Same timing loop, same JSON, same
// verify-or-fail discipline.  Two things are genuinely different and both are deliberate.
//
// 1. THE ORACLE IS NOT A = B = 1.  See f64_oracle.h.  The 1.0 oracle every other contender in
//    this tree uses cannot distinguish fp64 from fp32, which makes it useless for the one
//    endeavour whose entire premise is IEEE double.
//
// 2. -DPEDANTIC SELECTS A REAL SECOND COMPUTATION, and this is the most valuable measurement
//    in the file.  cuBLAS's default CUBLAS_COMPUTE_64F is free to use the fp64 tensor cores
//    (DMMA, `mma.sync...f64`); CUBLAS_COMPUTE_64F_PEDANTIC forbids the library from choosing a
//    faster path and pins it to vector fp64 FMA.  Both compute the SAME IEEE double result --
//    DMMA is not an approximation, unlike tf32 -- so the ratio between the two arms is a clean
//    measurement of what fp64 tensor cores are worth on this part.
//
//    That ratio is the ceiling of Crisp's entire 64-bit MMA ladder, measured by NVIDIA's own
//    tuned code, and it is available before we write a single chapter.  On an H100 the vendor
//    figures imply about 2x (67 vs 34 TFLOPS) -- an order of magnitude less headroom than the
//    16-bit ladder had.  If it measures nearer 1.3x, the 64-bit ladder is a data-movement story
//    from top to bottom and chapter 1 is a formality.  Worth knowing first.
//
//    -DFAST_MATH is accepted and does nothing here.  There is no reduced-precision fp64 compute
//    type in cuBLAS to select; the precision axis for fp64 is the DMMA/no-DMMA choice above,
//    which is a SPEED choice and not an accuracy one.  (nvcc's -ftz likewise has nothing to act
//    on: PTX has no .ftz for f64 at all.)
//
// MEMORY.  Three fp64 matrices plus host copies: 8 bytes/element x 2 (host + device).  N=8192 is
// ~1.6 GB host and ~1.6 GB device; N=16384 is ~6.4 GB host.  Size the §2 sweep accordingly.
//
// nvcc -O3 -arch=sm_90 cublas_ceiling_f64.cu -lcublas -o cublas_ceiling_f64
// nvcc -O3 -arch=sm_90 -DPEDANTIC cublas_ceiling_f64.cu -lcublas -o cublas_ceiling_f64_pedantic
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "f64_oracle.h"

#ifdef PEDANTIC
#define CFG_NAME "64F_PEDANTIC"
#else
#define CFG_NAME "64F"
#endif

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

#define CKB(call) do { cublasStatus_t _s=(call); if(_s!=CUBLAS_STATUS_SUCCESS){ \
    fprintf(stderr,"cublas_ceiling_f64 [%s]: cuBLAS error %d at %s:%d — this contender did NOT " \
                   "run.\n", CFG_NAME, (int)_s, __FILE__, __LINE__); \
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublas\",\n"); \
    printf("  \"config\": \"%s\",\n  \"correct\": false,\n", CFG_NAME); \
    printf("  \"error\": \"cublas status %d\"\n}\n", (int)_s); \
    return 2;} } while(0)

int main(int argc, char** argv) {
  auto wall_start = std::chrono::high_resolution_clock::now();
  int M      = argc > 1 ? atoi(argv[1]) : 1024;
  int N      = argc > 2 ? atoi(argv[2]) : 1024;
  int K      = argc > 3 ? atoi(argv[3]) : 1024;
  int warmup = argc > 4 ? atoi(argv[4]) : 20;
  int iters  = argc > 5 ? atoi(argv[5]) : 100;

  const double v = crisp_f64_oracle_value();
  std::vector<double> hA((size_t)M * K, v);
  std::vector<double> hB((size_t)K * N, v);
  std::vector<double> hC((size_t)M * N, 0.0);

  double *dA, *dB, *dC;
  CK(cudaMalloc(&dA, hA.size() * sizeof(double)));
  CK(cudaMalloc(&dB, hB.size() * sizeof(double)));
  CK(cudaMalloc(&dC, hC.size() * sizeof(double)));
  CK(cudaMemcpy(dA, hA.data(), hA.size() * sizeof(double), cudaMemcpyHostToDevice));
  CK(cudaMemcpy(dB, hB.data(), hB.size() * sizeof(double), cudaMemcpyHostToDevice));

  cublasHandle_t h;
  CKB(cublasCreate(&h));
  double alpha = 1.0, beta = 0.0;

#ifdef PEDANTIC
  cublasComputeType_t comp = CUBLAS_COMPUTE_64F_PEDANTIC;
#else
  cublasComputeType_t comp = CUBLAS_COMPUTE_64F;
#endif

  // The FIRST call is checked; the timing loop is not, so a status check cannot perturb the
  // measurement.  An unchecked cublasGemmEx that rejects its own arguments returns instantly and
  // reads as an extraordinary GFLOPS number -- the failure this tree has been burned by before.
  CKB(cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &alpha,
                   dA, CUDA_R_64F, M, dB, CUDA_R_64F, K, &beta,
                   dC, CUDA_R_64F, M, comp, CUBLAS_GEMM_DEFAULT));

  auto gemm = [&]() {
    cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &alpha,
                 dA, CUDA_R_64F, M, dB, CUDA_R_64F, K, &beta,
                 dC, CUDA_R_64F, M, comp, CUBLAS_GEMM_DEFAULT);
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

  CK(cudaMemcpy(hC.data(), dC, hC.size() * sizeof(double), cudaMemcpyDeviceToHost));
  double maxerr = 0.0, maxrel = 0.0;
  bool correct = crisp_f64_oracle_check(hC.data(), hC.size(), K, &maxerr, &maxrel);
  const char* diagnosis = crisp_f64_oracle_diagnose(maxrel);
  if (!correct)
    fprintf(stderr, "cublas_ceiling_f64 [%s]: ORACLE FAILED at M=%d N=%d K=%d — %s "
                    "(max_rel_err %.3e, tolerance %.1e)\n",
            CFG_NAME, M, N, K, diagnosis, maxrel, (double)CRISP_F64_ORACLE_RTOL);

  std::sort(kt.begin(), kt.end());
  double k_med = kt[iters / 2] * 1000.0, k_min = kt[0] * 1000.0;
  double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

  auto wall_end = std::chrono::high_resolution_clock::now();
  double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

  printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublas\",\n");
  printf("  \"config\": \"%s\",\n", CFG_NAME);
  printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
  printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
  printf("  \"max_rel_err\": %.3e,\n  \"precision_diagnosis\": \"%s\",\n", maxrel, diagnosis);
  printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
  printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
  printf("  \"gflops\": %.2f\n}\n", gflops);

  cublasDestroy(h);
  cudaFree(dA); cudaFree(dB); cudaFree(dC);
  return correct ? 0 : 1;
}
