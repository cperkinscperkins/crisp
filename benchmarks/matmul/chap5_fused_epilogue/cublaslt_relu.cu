/*
 * Chapter 5 (Endeavor 150) — THE STRONG BASELINE: cuBLASLt fusing ReLU itself.
 *
 * cublasLtMatmul with CUBLASLT_EPILOGUE_RELU.  This is the contender that makes the chapter
 * honest.  Beating "cuBLAS + a separate ReLU kernel" at plain relu would prove nothing —
 * NVIDIA can fuse relu, and a benchmark that ignores that is a strawman.  So the chapter runs
 * both, and they answer different questions:
 *
 *   THIS FILE            can Crisp's general mechanism stay competitive with a vendor kernel
 *                        hand-tuned for this exact epilogue?  Losing here is acceptable and
 *                        expected to some degree; the gap is the price of generality.
 *   cublas_optimal.cu    what does an activation cost when the vendor CANNOT fuse it?  That
 *                        is the case for anything off the fixed menu, which is most real
 *                        activations, and it is where the round trip shows up.
 *
 * The claim this endeavour actually makes is NOT "we beat cuBLAS at relu".  It is: the set of
 * activations you can fuse is unbounded, and for anything outside the vendor's enum the
 * comparison is against cublas_optimal.cu, not this file.
 *
 * A = B = 1 so every C == K exactly; relu(K) == K, so the epilogue is a numerical no-op on
 * this data but still runs.  Correctness is checked so a misconfigured Lt descriptor cannot
 * quietly produce a fast wrong answer — the most likely failure mode here.
 *
 * nvcc -arch=sm_90a cublaslt_fused.cu -lcublasLt -o cublaslt_fused
 */
#include <cublasLt.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
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

    const size_t total = (size_t)M * N;
    std::vector<float> hA((size_t)M*K,1.0f), hB((size_t)K*N,1.0f), hC(total,0.0f);
    float *dA,*dB,*dC;
    CK(cudaMalloc(&dA,hA.size()*4)); CK(cudaMalloc(&dB,hB.size()*4)); CK(cudaMalloc(&dC,total*4));
    CK(cudaMemcpy(dA,hA.data(),hA.size()*4,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB,hB.data(),hB.size()*4,cudaMemcpyHostToDevice));

    cublasLtHandle_t lt; LK(cublasLtCreate(&lt));

#ifdef FAST_MATH
    cublasComputeType_t comp = CUBLAS_COMPUTE_32F_FAST_TF32;
#else
    cublasComputeType_t comp = CUBLAS_COMPUTE_32F;
#endif

    cublasLtMatmulDesc_t op;
    LK(cublasLtMatmulDescCreate(&op, comp, CUDA_R_32F));
    cublasOperation_t opN = CUBLAS_OP_N;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &opN, sizeof(opN)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &opN, sizeof(opN)));
    // The whole point of this contender:
    cublasLtEpilogue_t ep = CUBLASLT_EPILOGUE_RELU;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_EPILOGUE, &ep, sizeof(ep)));

    // Column-major layouts, matching cublas_optimal.cu's GemmEx call.  With A = B = 1 the
    // result is K everywhere regardless of layout, so the correctness gate is layout-agnostic.
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    LK(cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_32F, M, K, M));
    LK(cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_32F, K, N, K));
    LK(cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_32F, M, N, M));

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
        fprintf(stderr, "cuBLASLt: no algorithm supports this configuration (M=%d N=%d K=%d, EPILOGUE_RELU)\n",
                M, N, K);
        return 2;
    }

    float alpha = 1.0f, beta = 0.0f;
    auto launch = [&]() {
        LK(cublasLtMatmul(lt, op, &alpha, dA, Adesc, dB, Bdesc, &beta,
                          dC, Cdesc, dC, Cdesc, &heur.algo, dWs, wsBytes, 0));
    };

    for (int i = 0; i < warmup; i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i = 0; i < iters; i++) {
        cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e);
    }

    CK(cudaMemcpy(hC.data(),dC,total*4,cudaMemcpyDeviceToHost));
    double expected=(double)K, maxerr=0.0;
    for(size_t i=0;i<total;i++) maxerr=std::max(maxerr,(double)fabs(hC[i]-expected));
    bool correct = maxerr < expected*1e-3;

    std::sort(kt.begin(),kt.end());
    double k_med = kt[iters/2]*1000.0, k_min = kt[0]*1000.0;
    double gflops = (2.0*M*N*K)/(k_med/1e6)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double,std::milli>(wall_end-wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cublaslt+relu-fused\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N,M,K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cublasLtMatmulPreferenceDestroy(pref);
    cublasLtMatrixLayoutDestroy(Adesc); cublasLtMatrixLayoutDestroy(Bdesc); cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(op);
    cublasLtDestroy(lt);
    cudaFree(dWs); cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct ? 0 : 1;
}
