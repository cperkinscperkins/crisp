/*
 * Section 2 top, int8 (Endeavour 207) -- THE NVIDIA LIBRARY PEER: cuBLASLt IMMA, s8 x s8 -> s32.
 *
 * Same contract as the Crisp kernels: A is M x K s8 row-major, B is K x N s8 column-major (N x K
 * row-major), C is M x N s32, no scales, no post-ops -- the raw MMA.  In cuBLAS's column-major terms
 * that is the "TN" problem: A is stored K x M (transa = T), B is stored K x N (transb = N).  TN is the
 * layout cuBLASLt's int8 kernels are built for (both operands K-contiguous), so this is the library at
 * its best, not handicapped by a transpose.
 *
 * alpha / beta are int32 because the scale type follows the compute type (CUBLAS_COMPUTE_32I).
 * C comes back column-major M x N, so the verifier is told so; the values are exact small integers
 * and the gate requires max_abs_err == 0.
 *
 * Build: nvcc -O3 -arch=<sm> cublaslt_int8.cu -lcublasLt -o cublaslt_int8
 */
#include <cublasLt.h>
#include <cuda_runtime.h>
#include "../common/fill_cuda.cuh"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <algorithm>
#include <vector>
#include <chrono>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)
#define LK(call) do { cublasStatus_t _s=(call); if(_s!=CUBLAS_STATUS_SUCCESS){ \
    fprintf(stderr,"cuBLASLt error %s:%d status=%d\n",__FILE__,__LINE__,(int)_s); exit(1);} } while(0)

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc>1?atoi(argv[1]):1024, N = argc>2?atoi(argv[2]):1024, K = argc>3?atoi(argv[3]):1024;
    int warmup = argc>4?atoi(argv[4]):20, iters = argc>5?atoi(argv[5]):100;

    int8_t *dA, *dB; int32_t *dC;
    CK(cudaMalloc(&dA, (size_t)M * K)); CK(cudaMalloc(&dB, (size_t)K * N));
    CK(cudaMalloc(&dC, (size_t)M * N * sizeof(int32_t)));
    crisp_bench::cuda_fill_encoded(dA, (uint64_t)M * K, crisp_bench::FILL_MOD_A, "s8");
    crisp_bench::cuda_fill_encoded(dB, (uint64_t)K * N, crisp_bench::FILL_MOD_B, "s8");

    cublasLtHandle_t lt; LK(cublasLtCreate(&lt));
    cublasLtMatmulDesc_t op;
    LK(cublasLtMatmulDescCreate(&op, CUBLAS_COMPUTE_32I, CUDA_R_32I));
    cublasOperation_t opT = CUBLAS_OP_T, opN = CUBLAS_OP_N;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &opT, sizeof(opT)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &opN, sizeof(opN)));
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    LK(cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_8I,  K, M, K));   // A^T stored K x M
    LK(cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_8I,  K, N, K));
    LK(cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_32I, M, N, M));

    size_t wsBytes = 32ull * 1024 * 1024;
    void* dWs = nullptr; CK(cudaMalloc(&dWs, wsBytes));
    cublasLtMatmulPreference_t pref;
    LK(cublasLtMatmulPreferenceCreate(&pref));
    LK(cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES,
                                            &wsBytes, sizeof(wsBytes)));
    cublasLtMatmulHeuristicResult_t heur{};
    int nAlgo = 0;
    LK(cublasLtMatmulAlgoGetHeuristic(lt, op, Adesc, Bdesc, Cdesc, Cdesc, pref, 1, &heur, &nAlgo));
    if (nAlgo == 0) {
        fprintf(stderr, "cuBLASLt: no int8 algorithm for M=%d N=%d K=%d (TN, s8 s8 -> s32)\n", M, N, K);
        return 2;
    }
    int32_t alpha = 1, beta = 0;
    auto launch = [&]() {
        LK(cublasLtMatmul(lt, op, &alpha, dA, Adesc, dB, Bdesc, &beta,
                          dC, Cdesc, dC, Cdesc, &heur.algo, dWs, wsBytes, 0));
    };
    for (int i = 0; i < warmup; i++) launch();
    CK(cudaDeviceSynchronize());
    std::vector<float> kt(iters);
    cudaEvent_t s, e; cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e);
    }
    // A row-major M x K, B column-major K x N, C column-major M x N.
    const crisp_bench::VerifyResult vr = crisp_bench::cuda_verify(
        dC, "s32", (uint64_t)M, (uint64_t)N, (uint64_t)K,
        crisp_bench::rm(K), crisp_bench::cm(K), crisp_bench::cm(M));
    const bool correct = vr.verified && vr.max_abs_err == 0.0;
    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters/2]*1000.0, k_min = kt[0]*1000.0;
    double gops = (2.0*M*N*K)/(k_med/1e6)/1e9;
    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double,std::milli>(wall_end-wall_start).count();
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublaslt-imma-s8s8s32\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", vr.max_abs_err);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gops);
    cublasLtMatmulPreferenceDestroy(pref);
    cublasLtMatrixLayoutDestroy(Adesc); cublasLtMatrixLayoutDestroy(Bdesc); cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(op);
    cublasLtDestroy(lt);
    cudaFree(dWs); cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct ? 0 : 1;
}
