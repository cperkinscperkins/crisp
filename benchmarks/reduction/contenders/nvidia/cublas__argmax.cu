// cublas -- workload argmax.  A reduction contender: see common.cuh for the protocol and timing.
#include <cublas_v2.h>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;

static cublasHandle_t h = nullptr;
static int *d_idx = nullptr;
static const float *h_in = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    // isamax = first index of the largest |x|, ONE-BASED (BLAS); non-negative data make it argmax.
    if (!h) { cublasCreate(&h); cublasSetPointerMode(h, CUBLAS_POINTER_MODE_DEVICE); cudaMalloc(&d_idx, sizeof(int)); }
    cublasSetStream(h, s);
    cublasIsamax(h, (int)n, in, 1, d_idx);
    h_in = in;
}
static void fetch(double *outs) {
    int i1; cudaMemcpy(&i1, d_idx, sizeof i1, cudaMemcpyDeviceToHost);
    const int i = i1 - 1;
    float v; cudaMemcpy(&v, h_in + i, sizeof v, cudaMemcpyDeviceToHost);
    outs[0] = v; outs[1] = (double)i;
}

#include "common.cuh"
