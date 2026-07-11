/*
 * Benchmark harness for the Crisp-compiled PTX tiled matmul.
 *   C[M x N] = A[M x K] . B[K x N]   (tf32, m16n8k8, one warp per 64x64 output tile)
 *
 * Loads matmul.ptx and launches the `matmul` kernel over a (M/64 x N/64) grid of
 * 32-thread workgroups (matching the kernel's grid-stride tile assignment via
 * get-workgroup-id).  Inputs are A = B = 1.0, so every C[i][j] == K — a trivially
 * checkable correctness oracle (1.0 is exact in tf32, and K is exact in fp32 accum).
 *
 * Param layout (45 slots, from the Crisp CUDA hoist): the two SLM scratch tiles come
 * first (b_tile 8x64, a_tile 64x8 — each a 9-tuple: ptr/byte_size/off0/off1/str0/str1/
 * ext0/ext1/length), then A, B, C (same 9-tuple; ptr is a device pointer).
 *
 * Compile: nvcc -O3 -arch=sm_80 bench_harness.cu -lcuda -o matmul_crisp
 * Run:     ./matmul_crisp [M] [N] [K] [warmup] [iters]
 */
#include <cuda.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <vector>
#include <numeric>
#include <fstream>
#include <string>
#include <chrono>

#define CUDA_CHECK(call) do { \
    CUresult _r = (call); \
    if (_r != CUDA_SUCCESS) { const char* _e; cuGetErrorString(_r, &_e); \
        fprintf(stderr, "CUDA error at %s:%d — %s\n", __FILE__, __LINE__, _e); exit(1); } \
} while(0)

int main(int argc, char** argv) {
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;
    if (M % 64 || N % 64 || K % 8) {
        fprintf(stderr, "M and N must be %%64, K must be %%8 (got %d %d %d)\n", M, N, K);
        return 1;
    }

    const char* cands[] = { "matmul.ptx", "benchmarks/matmul/crisp/matmul.ptx" };
    std::string ptx; const char* used = nullptr;
    for (auto* c : cands) { std::ifstream f(c); if (f.good()) {
        used = c; ptx.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()); break; } }
    if (!used) { fprintf(stderr, "Cannot find matmul.ptx\n"); return 1; }

    CUDA_CHECK(cuInit(0));
    CUdevice dev; CUDA_CHECK(cuDeviceGet(&dev, 0));
    char name[256]; CUDA_CHECK(cuDeviceGetName(name, sizeof(name), dev));
    fprintf(stderr, "Device: %s\n", name);
    CUcontext ctx; CUDA_CHECK(cuCtxCreate(&ctx, 0, dev));
    CUmodule mod; CUDA_CHECK(cuModuleLoadData(&mod, ptx.c_str()));
    CUfunction kernel; CUDA_CHECK(cuModuleGetFunction(&kernel, mod, "matmul"));

    // --- host inputs: A = B = 1.0 (row-major A [MxK], col-major B [KxN]) ---
    std::vector<float> hA((size_t)M*K, 1.0f), hB((size_t)K*N, 1.0f), hC((size_t)M*N, 0.0f);

    CUdeviceptr dA, dB, dC;
    CUDA_CHECK(cuMemAlloc(&dA, hA.size()*sizeof(float)));
    CUDA_CHECK(cuMemAlloc(&dB, hB.size()*sizeof(float)));
    CUDA_CHECK(cuMemAlloc(&dC, hC.size()*sizeof(float)));
    CUDA_CHECK(cuMemcpyHtoD(dA, hA.data(), hA.size()*sizeof(float)));
    CUDA_CHECK(cuMemcpyHtoD(dB, hB.data(), hB.size()*sizeof(float)));

    // --- SLM scratch tiles (implicit params; ptr = shared-mem offset) ---
    // Order matches the hoist: b_tile (8x64) first, then a_tile (64x8).  Each is a
    // compact 2D tensor 9-tuple; str0 = row stride (= cols), str1 = 1.
    uint64_t bt_ptr=0, bt_bytes=8*64*sizeof(float), bt_o0=0,bt_o1=0, bt_s0=64,bt_s1=1, bt_e0=8, bt_e1=64, bt_len=512;
    uint64_t at_ptr=0, at_bytes=64*8*sizeof(float), at_o0=0,at_o1=0, at_s0=8,at_s1=1, at_e0=64,at_e1=8, at_len=512;
    const unsigned sharedBytes = (unsigned)(bt_bytes + at_bytes);   // 4096

    // --- global matrix tuples (2D tensor 9-tuple) ---
    // A: row-major MxK  -> str0=K (row), str1=1 (col)
    uint64_t A_bytes=hA.size()*4, A_o0=0,A_o1=0, A_s0=(uint64_t)K,A_s1=1, A_e0=(uint64_t)M,A_e1=(uint64_t)K, A_len=hA.size();
    // B: col-major KxN  -> str0=1 (row), str1=K (col)
    uint64_t B_bytes=hB.size()*4, B_o0=0,B_o1=0, B_s0=1,B_s1=(uint64_t)K, B_e0=(uint64_t)K,B_e1=(uint64_t)N, B_len=hB.size();
    // C: row-major MxN  -> str0=N, str1=1
    uint64_t C_bytes=hC.size()*4, C_o0=0,C_o1=0, C_s0=(uint64_t)N,C_s1=1, C_e0=(uint64_t)M,C_e1=(uint64_t)N, C_len=hC.size();

    void* params[45] = {
        &bt_ptr,&bt_bytes,&bt_o0,&bt_o1,&bt_s0,&bt_s1,&bt_e0,&bt_e1,&bt_len,
        &at_ptr,&at_bytes,&at_o0,&at_o1,&at_s0,&at_s1,&at_e0,&at_e1,&at_len,
        &dA,&A_bytes,&A_o0,&A_o1,&A_s0,&A_s1,&A_e0,&A_e1,&A_len,
        &dB,&B_bytes,&B_o0,&B_o1,&B_s0,&B_s1,&B_e0,&B_e1,&B_len,
        &dC,&C_bytes,&C_o0,&C_o1,&C_s0,&C_s1,&C_e0,&C_e1,&C_len,
    };

    // matrix-multiply-tile-stride (endeavor 135) derives grid-y from workgroup-id 0 (ctaid.x)
    // and grid-x from workgroup-id 1 (ctaid.y), so launch a 2-D grid = (M/64, N/64):
    //   gridDim.x = M/64 row-tiles  (grid-y),  gridDim.y = N/64 col-tiles (grid-x).
    // (Was a 1-D linearized grid of (M/64)*(N/64) for the hand-rolled gy=wg/ntx kernel.)
    unsigned gridX = (unsigned)(M/64);
    unsigned gridY = (unsigned)(N/64);
    fprintf(stderr, "Grid: %u x %u blocks x 32 threads, shared=%u B, MxNxK=%dx%dx%d\n",
            gridX, gridY, sharedBytes, M, N, K);

    auto launch = [&](){ CUDA_CHECK(cuLaunchKernel(kernel, gridX,gridY,1, 32,1,1, sharedBytes, 0, params, nullptr)); };

    for (int i=0;i<warmup;i++) launch();
    CUDA_CHECK(cuCtxSynchronize());

    std::vector<float> kt(iters);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for (int i=0;i<iters;i++){ cudaEventRecord(s); launch(); cudaEventRecord(e); cudaEventSynchronize(e);
        cudaEventElapsedTime(&kt[i], s, e); }

    CUDA_CHECK(cuMemcpyDtoH(hC.data(), dC, hC.size()*sizeof(float)));
    double expected = (double)K;                          // A=B=1 -> C[i][j] = K
    double maxerr = 0.0;
    for (size_t i=0;i<hC.size();i++) maxerr = std::max(maxerr, (double)fabs(hC[i]-expected));
    bool correct = maxerr < expected*1e-3;

    std::sort(kt.begin(), kt.end());
    float k_med = kt[iters/2], k_min = kt[0];
    // 2*M*N*K flops
    double gflops = (2.0*M*N*K) / (k_med/1e3) / 1e9;

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"crisp\",\n");
    printf("  \"M\": %d, \"N\": %d, \"K\": %d,\n", M, N, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct?"true":"false", maxerr);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med*1000.0, k_min*1000.0);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    cudaEventDestroy(s); cudaEventDestroy(e);
    cuMemFree(dA); cuMemFree(dB); cuMemFree(dC);
    return correct ? 0 : 1;
}
