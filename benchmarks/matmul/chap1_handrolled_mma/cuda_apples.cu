/*
 * Hand-written CUDA reference matmul using SMEM staging + Tensor Cores (nvcuda::wmma).
 * Section 1 Chapter 1 Control baseline for NVIDIA.
 * Exact 1-to-1 mirror of Crisp's chap1_handrolled_mma:
 *   - 1 warp (32 threads) per 64x64 output tile
 *   - Explicit SMEM staging (64x8 As, 8x64 Bs) via element-wise loads
 *   - Barrier synchronization around SMEM reads/writes (__syncthreads)
 *   - wmma::load_matrix_sync from SMEM -> wmma::mma_sync -> wmma::store_matrix_sync to C
 *
 * Compile: nvcc -O3 -arch=sm_80 cuda_apples.cu -o cuda_apples
 * Run:     ./cuda_apples [M] [N] [K] [warmup] [iters]
 */
#include <cuda_runtime.h>
#include <mma.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>

using namespace nvcuda;

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

// 1 warp (32 threads) computes one 64x64 tile (4x4 fragments of 16x16x8)
__global__ void matmul_wmma_smem(const float* A, const float* B, float* C, int M, int N, int K) {
    __shared__ float As[64][8];
    __shared__ float Bs[8][64];

    int tile_r = blockIdx.y * 64;
    int tile_c = blockIdx.x * 64;
    int lid = threadIdx.x; // 0..31

    wmma::fragment<wmma::accumulator, 16, 16, 8, float> c[4][4];
    #pragma unroll
    for (int r = 0; r < 4; r++) {
        #pragma unroll
        for (int col = 0; col < 4; col++) {
            wmma::fill_fragment(c[r][col], 0.0f);
        }
    }

    for (int k = 0; k < K; k += 8) {
        // 1. Cooperative element-wise loads from Global Memory to SMEM (16 floats per thread)
        #pragma unroll
        for (int i = 0; i < 16; i++) {
            int idx = lid + i * 32; // 0..511
            int r = idx / 8, c_sub = idx % 8;
            As[r][c_sub] = (tile_r + r < M && k + c_sub < K) ? A[(tile_r + r) * K + (k + c_sub)] : 0.0f;
        }
        #pragma unroll
        for (int i = 0; i < 16; i++) {
            int idx = lid + i * 32; // 0..511
            int r = idx / 64, c_sub = idx % 64;
            Bs[r][c_sub] = (k + r < K && tile_c + c_sub < N) ? B[(tile_c + c_sub) * K + (k + r)] : 0.0f; // B is col-major
        }

        // 2. Barrier: ensure SMEM is fully written
        __syncthreads();

        // 3. Load from SMEM into WMMA fragments and compute
        wmma::fragment<wmma::matrix_a, 16, 16, 8, wmma::precision::tf32, wmma::row_major> a[4];
        #pragma unroll
        for (int r = 0; r < 4; r++) {
            wmma::load_matrix_sync(a[r], &As[r * 16][0], 8);
        }

        wmma::fragment<wmma::matrix_b, 16, 16, 8, wmma::precision::tf32, wmma::col_major> b[4];
        #pragma unroll
        for (int col = 0; col < 4; col++) {
            wmma::load_matrix_sync(b[col], &Bs[0][col * 16], 64);
        }

        #pragma unroll
        for (int r = 0; r < 4; r++) {
            #pragma unroll
            for (int col = 0; col < 4; col++) {
                wmma::mma_sync(c[r][col], a[r], b[col], c[r][col]);
            }
        }

        // 4. Barrier before next iteration's SMEM writes
        __syncthreads();
    }

    #pragma unroll
    for (int r = 0; r < 4; r++) {
        #pragma unroll
        for (int col = 0; col < 4; col++) {
            wmma::store_matrix_sync(C + (tile_r + r * 16) * N + (tile_c + col * 16), c[r][col], N, wmma::mem_row_major);
        }
    }
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

    dim3 block(32, 1, 1);
    dim3 grid((N + 63) / 64, (M + 63) / 64);
    auto launch = [&](){ matmul_wmma_smem<<<grid,block>>>(dA,dB,dC,M,N,K); };

    for(int i=0;i<warmup;i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<iters;i++){
        cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i],s,e);
    }

    CK(cudaMemcpy(hC.data(),dC,hC.size()*4,cudaMemcpyDeviceToHost));
    double expected = (double)K, maxerr = 0.0;
    for(size_t i=0;i<hC.size();i++) maxerr = std::max(maxerr, (double)std::fabs(hC[i]-expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(),kt.end());
    double k_med = kt[iters/2] * 1000.0;
    double k_min = kt[0] * 1000.0;
    double gflops = (2.0*M*N*K)/(k_med/1e6)/1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"cuda_apples\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    return correct ? 0 : 1;
}
