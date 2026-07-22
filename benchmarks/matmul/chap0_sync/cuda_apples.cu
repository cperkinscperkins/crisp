/*
 * Hand-written CUDA reference matmul: C[M x N] = A[M x K] . B[K x N].
 * Same operand layout as the Crisp kernel (A row-major, B COL-major, C row-major),
 * A = B = 1.0 so every C[i][j] == K.  Standard 16x16 shared-memory tiled kernel
 * (fp32) — a straightforward baseline; cuBLAS / a tf32-MMA reference are the
 * "best-known" comparisons to add later.
 *
 * Compile: nvcc -O3 -arch=sm_80 matmul.cu -o matmul_cuda
 * Run:     ./matmul_cuda [M] [N] [K] [warmup] [iters]
 */
#include <cuda_runtime.h>
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
__global__ void matmul_tiled(const float* A, const float* B, float* C, int M, int N, int K) {
    __shared__ float As[TS][TS];
    __shared__ float Bs[TS][TS];
    int row = blockIdx.y*TS + threadIdx.y;
    int col = blockIdx.x*TS + threadIdx.x;
    float acc = 0.0f;
    for (int t = 0; t < K; t += TS) {
        As[threadIdx.y][threadIdx.x] = (row < M && t+threadIdx.x < K) ? A[row*K + (t+threadIdx.x)] : 0.0f;
        Bs[threadIdx.y][threadIdx.x] = (col < N && t+threadIdx.y < K) ? B[(t+threadIdx.y) + col*K] : 0.0f;
        __syncthreads();
        for (int k = 0; k < TS; k++) acc += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        __syncthreads();
    }
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
    auto launch = [&](){ matmul_tiled<<<grid,block>>>(dA,dB,dC,M,N,K); };

    for(int i=0;i<warmup;i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<iters;i++){ cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i],s,e); }

    CK(cudaMemcpy(hC.data(),dC,hC.size()*4,cudaMemcpyDeviceToHost));
    double expected=(double)K, maxerr=0.0;
    for(size_t i=0;i<hC.size();i++) maxerr=std::max(maxerr,(double)fabs(hC[i]-expected));
    bool correct = maxerr < expected*1e-3;

    std::sort(kt.begin(),kt.end());
    float k_med=kt[iters/2], k_min=kt[0];
    double gflops=(2.0*M*N*K)/(k_med/1e3)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cuda\",\n");
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M,N,K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med*1000.0, k_min*1000.0);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct?0:1;
}
