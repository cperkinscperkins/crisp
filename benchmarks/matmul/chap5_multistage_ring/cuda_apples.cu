/*
 * Hand-written CUDA reference matmul for Chapter 2 (Pipelined Block).
 * Uses a multi-stage cuda::pipeline to overlap memory loads with math.
 */
#include <cuda_runtime.h>
#include <cuda/pipeline>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>

#define CK(call) do { cudaError_t _r=(call); if(_r!=cudaSuccess){ \
    fprintf(stderr,"CUDA error %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(_r)); exit(1);} } while(0)

#define TS 16
#define STAGES 3

// A row-major [M x K], B col-major [K x N] (B[k + j*K]), C row-major [M x N].
__global__ void matmul_tiled_pipelined(const float* A, const float* B, float* C, int M, int N, int K) {
    __shared__ float As[STAGES][TS][TS];
    __shared__ float Bs[STAGES][TS][TS];
    
    int row = blockIdx.y*TS + threadIdx.y;
    int col = blockIdx.x*TS + threadIdx.x;
    float acc = 0.0f;
    
    cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();

    // Prologue: fill initial stages
    int t = 0;
    for (int s = 0; s < STAGES - 1 && t < K; s++, t += TS) {
        pipe.producer_acquire();
        if (row < M && t+threadIdx.x < K) {
            cuda::memcpy_async(&As[s][threadIdx.y][threadIdx.x], &A[row*K + (t+threadIdx.x)], sizeof(float), pipe);
        } else {
            As[s][threadIdx.y][threadIdx.x] = 0.0f;
        }
        if (col < N && t+threadIdx.y < K) {
            cuda::memcpy_async(&Bs[s][threadIdx.y][threadIdx.x], &B[(t+threadIdx.y) + col*K], sizeof(float), pipe);
        } else {
            Bs[s][threadIdx.y][threadIdx.x] = 0.0f;
        }
        pipe.producer_commit();
    }

    // Main loop
    for (int compute_t = 0; compute_t < K; compute_t += TS) {
        int compute_stage = (compute_t / TS) % STAGES;
        int load_stage = (t / TS) % STAGES;
        
        // Load next tile if still in bounds
        if (t < K) {
            pipe.producer_acquire();
            if (row < M && t+threadIdx.x < K) {
                cuda::memcpy_async(&As[load_stage][threadIdx.y][threadIdx.x], &A[row*K + (t+threadIdx.x)], sizeof(float), pipe);
            } else {
                As[load_stage][threadIdx.y][threadIdx.x] = 0.0f;
            }
            if (col < N && t+threadIdx.y < K) {
                cuda::memcpy_async(&Bs[load_stage][threadIdx.y][threadIdx.x], &B[(t+threadIdx.y) + col*K], sizeof(float), pipe);
            } else {
                Bs[load_stage][threadIdx.y][threadIdx.x] = 0.0f;
            }
            pipe.producer_commit();
            t += TS;
        }
        
        // Wait for the compute stage to be ready
        pipe.consumer_wait();
        __syncthreads();
        
        for (int k = 0; k < TS; k++) {
            acc += As[compute_stage][threadIdx.y][k] * Bs[compute_stage][k][threadIdx.x];
        }
        
        pipe.consumer_release();
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
    auto launch = [&](){ matmul_tiled_pipelined<<<grid,block>>>(dA,dB,dC,M,N,K); };

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
