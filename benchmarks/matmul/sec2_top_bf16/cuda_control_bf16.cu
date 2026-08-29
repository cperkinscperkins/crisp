/*
 * Hand-written CUDA bf16 matmul — the CONTROL for §2.2 (NVIDIA).
 *
 * Twin of sec2_top/cuda_control.cu.  Deliberately the SAME algorithm — 16x16 shared-memory tiles
 * driven by a 3-stage cuda::pipeline — with exactly one thing changed: the operand element type.
 * Keeping the algorithm fixed is what makes the tf32 -> bf16 ratio in the report attributable to
 * the datatype rather than to a rewrite, the same discipline the Intel 16-bit ladder used.
 *
 * NO TENSOR CORES, ON PURPOSE.  This is the Control class: what a competent person writes without
 * reaching for MMA.  Operands are widened to float and accumulated in float, so the oracle below
 * is exact and the accumulator matches every other contender in the chapter.
 *
 * KNOWN CAVEAT, RECORDED BEFORE THE FIRST RUN so the number is read correctly.  cuda::memcpy_async
 * only takes the accelerated cp.async path at 4/8/16-byte granularity; here each thread stages a
 * SINGLE 2-byte half, so the "async" copy is expected to degrade to a synchronous one and the
 * pipeline to buy little or nothing.  That is a true property of naively porting this kernel to
 * 16-bit and belongs in the Control column.  If it measures degenerate rather than merely slow,
 * the fix is a __nv_bfloat162 (4-byte) staging variant as a SECOND control, not an edit to this one --
 * this file's value is that it is the tf32 control with one variable moved.
 */
#include <cuda_runtime.h>
#include <cuda_bf16.h>
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

typedef __nv_bfloat16 elem_t;
__device__ __forceinline__ float to_f32(elem_t x) { return __bfloat162float(x); }

// A row-major [M x K], B col-major [K x N] (B[k + j*K]), C row-major [M x N] float.
__global__ void matmul_tiled_pipelined_16(const elem_t* A, const elem_t* B, float* C, int M, int N, int K) {
    __shared__ elem_t As[STAGES][TS][TS];
    __shared__ elem_t Bs[STAGES][TS][TS];

    int row = blockIdx.y*TS + threadIdx.y;
    int col = blockIdx.x*TS + threadIdx.x;
    float acc = 0.0f;

    cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();

    const elem_t zero = elem_t(0.0f);

    int t = 0;
    for (int s = 0; s < STAGES - 1 && t < K; s++, t += TS) {
        pipe.producer_acquire();
        if (row < M && t+threadIdx.x < K) {
            cuda::memcpy_async(&As[s][threadIdx.y][threadIdx.x], &A[(size_t)row*K + (t+threadIdx.x)], sizeof(elem_t), pipe);
        } else {
            As[s][threadIdx.y][threadIdx.x] = zero;
        }
        if (col < N && t+threadIdx.y < K) {
            cuda::memcpy_async(&Bs[s][threadIdx.y][threadIdx.x], &B[(size_t)(t+threadIdx.y) + (size_t)col*K], sizeof(elem_t), pipe);
        } else {
            Bs[s][threadIdx.y][threadIdx.x] = zero;
        }
        pipe.producer_commit();
    }

    for (int compute_t = 0; compute_t < K; compute_t += TS) {
        int compute_stage = (compute_t / TS) % STAGES;
        int load_stage = (t / TS) % STAGES;

        if (t < K) {
            pipe.producer_acquire();
            if (row < M && t+threadIdx.x < K) {
                cuda::memcpy_async(&As[load_stage][threadIdx.y][threadIdx.x], &A[(size_t)row*K + (t+threadIdx.x)], sizeof(elem_t), pipe);
            } else {
                As[load_stage][threadIdx.y][threadIdx.x] = zero;
            }
            if (col < N && t+threadIdx.y < K) {
                cuda::memcpy_async(&Bs[load_stage][threadIdx.y][threadIdx.x], &B[(size_t)(t+threadIdx.y) + (size_t)col*K], sizeof(elem_t), pipe);
            } else {
                Bs[load_stage][threadIdx.y][threadIdx.x] = zero;
            }
            pipe.producer_commit();
            t += TS;
        }

        pipe.consumer_wait();
        __syncthreads();

        for (int k = 0; k < TS; k++) {
            acc += to_f32(As[compute_stage][threadIdx.y][k]) * to_f32(Bs[compute_stage][k][threadIdx.x]);
        }

        pipe.consumer_release();
        __syncthreads();
    }

    if (row < M && col < N) C[(size_t)row*N + col] = acc;
}

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M = argc>1?atoi(argv[1]):256, N = argc>2?atoi(argv[2]):256, K = argc>3?atoi(argv[3]):256;
    int warmup = argc>4?atoi(argv[4]):20, iters = argc>5?atoi(argv[5]):100;

    std::vector<elem_t> hA((size_t)M*K, elem_t(1.0f)), hB((size_t)K*N, elem_t(1.0f));
    std::vector<float>  hC((size_t)M*N, 0.0f);
    elem_t *dA,*dB; float *dC;
    CK(cudaMalloc(&dA,hA.size()*sizeof(elem_t)));
    CK(cudaMalloc(&dB,hB.size()*sizeof(elem_t)));
    CK(cudaMalloc(&dC,hC.size()*sizeof(float)));
    CK(cudaMemcpy(dA,hA.data(),hA.size()*sizeof(elem_t),cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB,hB.data(),hB.size()*sizeof(elem_t),cudaMemcpyHostToDevice));

    dim3 block(TS,TS), grid((N+TS-1)/TS, (M+TS-1)/TS);
    auto launch = [&](){ matmul_tiled_pipelined_16<<<grid,block>>>(dA,dB,dC,M,N,K); };

    for(int i=0;i<warmup;i++) launch();
    CK(cudaDeviceSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<iters;i++){ cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i],s,e); }

    CK(cudaMemcpy(hC.data(),dC,hC.size()*sizeof(float),cudaMemcpyDeviceToHost));
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
