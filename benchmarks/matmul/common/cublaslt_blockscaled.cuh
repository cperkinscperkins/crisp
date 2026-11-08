/*
 * Section 2, BLOCK-SCALED (endeavour 209) -- THE NVIDIA LIBRARY CEILING: cuBLASLt with block scales.
 *
 * ONE source for the three block formats; each lane directory has a two-line wrapper defining
 *     CB_BLOCK_NVFP4   fp4 (e2m1) codes, a ue4m3 scale per 16   (sec2_top_nvfp4)
 *     CB_BLOCK_MXFP4   fp4 (e2m1) codes, a ue8m0 scale per 32   (sec2_top_mxfp4)
 *     CB_BLOCK_MXFP8   fp8 (e4m3) codes, a ue8m0 scale per 32   (sec2_top_mxfp8)
 *
 * Same contract as the Crisp block kernels: A is M x K codes row-major, B is K x N codes
 * column-major (both K-contiguous), each with its scales in the :blocked-128x4 layout (which is
 * cuBLASLt's own scale layout -- the fill is common/fill_cuda.cuh's, as for the Crisp fixture), and
 * C is M x N fp32 with no post-ops.  In cuBLAS's column-major terms that is "TN", the only layout
 * the block-scaled kernels take.  C comes back column-major and the verifier is told so.
 *
 * The oracle is fill_verify.h's block-scaled one: codes 0..4 / 0..2 and power-of-two scales that
 * vary by row and K-block, so a library that applied the scales wrongly would fail.
 *
 * MXFP4 needs CUDA 12.8 cuBLASLt on sm_100; a configuration cuBLASLt has no algorithm for is a
 * VISIBLE GAP ("correct": false, exit 2), never a number.
 *
 * Build: nvcc -O3 -arch=sm_100a <wrapper>.cu -lcublasLt -o <bin>
 */
#include <cublasLt.h>
#include <cuda_runtime.h>
#include "fill_cuda.cuh"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#if defined(CB_BLOCK_NVFP4)
#define CB_NAME "nvfp4"
#define CB_BASE "fp4"
#define CB_SCALE "fp8-e4m3"
#define CB_VEC 16
#define CB_CODE_T CUDA_R_4F_E2M1
#define CB_SCALE_MODE CUBLASLT_MATMUL_MATRIX_SCALE_VEC16_UE4M3
#elif defined(CB_BLOCK_MXFP4)
#define CB_NAME "mxfp4"
#define CB_BASE "fp4"
#define CB_SCALE "fp8-e8m0"
#define CB_VEC 32
#define CB_CODE_T CUDA_R_4F_E2M1
#define CB_SCALE_MODE CUBLASLT_MATMUL_MATRIX_SCALE_VEC32_UE8M0
#elif defined(CB_BLOCK_MXFP8)
#define CB_NAME "mxfp8"
#define CB_BASE "fp8-e4m3"
#define CB_SCALE "fp8-e8m0"
#define CB_VEC 32
#define CB_CODE_T CUDA_R_8F_E4M3
#define CB_SCALE_MODE CUBLASLT_MATMUL_MATRIX_SCALE_VEC32_UE8M0
#else
#error "define one of CB_BLOCK_NVFP4 / CB_BLOCK_MXFP4 / CB_BLOCK_MXFP8"
#endif

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)
#define LK(call) do { cublasStatus_t _s=(call); if(_s!=CUBLAS_STATUS_SUCCESS){ \
    fprintf(stderr,"cuBLASLt error %s:%d status=%d\n",__FILE__,__LINE__,(int)_s); return cb_gap("cublasLt", M, N, K);} } while(0)

static int cb_gap(const char *what, int M, int N, int K) {
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublaslt-blockscaled-%s\",\n", CB_NAME);
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n  \"correct\": false,\n  \"error\": \"%s\"\n}\n", M, N, K, what);
    return 2;
}

int main(int argc, char **argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc > 1 ? atoi(argv[1]) : 1024, N = argc > 2 ? atoi(argv[2]) : 1024, K = argc > 3 ? atoi(argv[3]) : 1024;
    int warmup = argc > 4 ? atoi(argv[4]) : 20, iters = argc > 5 ? atoi(argv[5]) : 100;

    const uint64_t nA = (uint64_t)M * K, nB = (uint64_t)K * N;
    const uint64_t epb = (std::string(CB_BASE) == "fp4") ? 2 : 1;
    uint8_t *dA, *dB, *dSA, *dSB; float *dC;
    const uint64_t bSA = crisp_bench::mf_scales_bytes(M, K, CB_VEC), bSB = crisp_bench::mf_scales_bytes(N, K, CB_VEC);
    CK(cudaMalloc(&dA, nA / epb)); CK(cudaMalloc(&dB, nB / epb));
    CK(cudaMalloc(&dSA, bSA));     CK(cudaMalloc(&dSB, bSB));
    CK(cudaMalloc(&dC, (size_t)M * N * sizeof(float)));
    crisp_bench::cuda_fill_mf_codes(dA, nA, crisp_bench::FILL_MOD_A, CB_BASE);
    crisp_bench::cuda_fill_mf_codes(dB, nB, crisp_bench::FILL_MOD_B, CB_BASE);
    crisp_bench::cuda_fill_mf_scales(dSA, M, K, CB_VEC, CB_SCALE);
    crisp_bench::cuda_fill_mf_scales(dSB, N, K, CB_VEC, CB_SCALE);

    cublasLtHandle_t lt; LK(cublasLtCreate(&lt));
    cublasLtMatmulDesc_t op;
    LK(cublasLtMatmulDescCreate(&op, CUBLAS_COMPUTE_32F, CUDA_R_32F));
    cublasOperation_t opT = CUBLAS_OP_T, opN = CUBLAS_OP_N;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &opT, sizeof(opT)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &opN, sizeof(opN)));
    cublasLtMatmulMatrixScale_t smode = CB_SCALE_MODE;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_A_SCALE_MODE, &smode, sizeof(smode)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_B_SCALE_MODE, &smode, sizeof(smode)));
    // cuBLAS's "A" in a TN problem is our A (stored K x M, i.e. row-major M x K): its scales are
    // indexed by M, exactly the :blocked-128x4 vector of our A.  Likewise B by N.
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_A_SCALE_POINTER, &dSA, sizeof(dSA)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_B_SCALE_POINTER, &dSB, sizeof(dSB)));

    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    LK(cublasLtMatrixLayoutCreate(&Adesc, CB_CODE_T, K, M, K));    // A^T stored K x M
    LK(cublasLtMatrixLayoutCreate(&Bdesc, CB_CODE_T, K, N, K));
    LK(cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_32F, M, N, M));

    size_t wsBytes = 32ull * 1024 * 1024;
    void *dWs = nullptr; CK(cudaMalloc(&dWs, wsBytes));
    cublasLtMatmulPreference_t pref;
    LK(cublasLtMatmulPreferenceCreate(&pref));
    LK(cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &wsBytes, sizeof(wsBytes)));
    cublasLtMatmulHeuristicResult_t heur{};
    int nAlgo = 0;
    cublasStatus_t hs = cublasLtMatmulAlgoGetHeuristic(lt, op, Adesc, Bdesc, Cdesc, Cdesc, pref, 1, &heur, &nAlgo);
    if (hs != CUBLAS_STATUS_SUCCESS || nAlgo == 0) {
        fprintf(stderr, "cuBLASLt: no %s algorithm for M=%d N=%d K=%d (TN, block-scaled, f32 D), status=%d\n",
                CB_NAME, M, N, K, (int)hs);
        return cb_gap("no algorithm", M, N, K);
    }
    float alpha = 1.0f, beta = 0.0f;
    auto launch = [&]() -> cublasStatus_t {
        return cublasLtMatmul(lt, op, &alpha, dA, Adesc, dB, Bdesc, &beta,
                              dC, Cdesc, dC, Cdesc, &heur.algo, dWs, wsBytes, 0);
    };
    for (int i = 0; i < warmup; i++) LK(launch());
    CK(cudaDeviceSynchronize());
    std::vector<float> kt(iters);
    cudaEvent_t s, e; cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s); LK(launch()); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e);
    }
    CK(cudaGetLastError());

    // A row-major M x K, B column-major K x N, C column-major M x N; scales per CB_VEC along K.
    const crisp_bench::VerifyResult vr = crisp_bench::cuda_verify(
        dC, "f32", (uint64_t)M, (uint64_t)N, (uint64_t)K,
        crisp_bench::rm(K), crisp_bench::cm(K), crisp_bench::cm(M), {}, CB_VEC);

    std::sort(kt.begin(), kt.end());
    const double k_med = kt[iters / 2] * 1000.0, k_min = kt[0] * 1000.0;
    const double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;
    const double wall_time_ms = std::chrono::duration<double, std::milli>(
        std::chrono::high_resolution_clock::now() - wall_start).count();
    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublaslt-blockscaled-%s\",\n", CB_NAME);
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", vr.verified ? "true" : "false", vr.max_abs_err);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cublasLtMatmulPreferenceDestroy(pref);
    cublasLtMatrixLayoutDestroy(Adesc); cublasLtMatrixLayoutDestroy(Bdesc); cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(op);
    cublasLtDestroy(lt);
    cudaFree(dWs); cudaFree(dA); cudaFree(dB); cudaFree(dSA); cudaFree(dSB); cudaFree(dC);
    return vr.verified ? 0 : 1;
}
