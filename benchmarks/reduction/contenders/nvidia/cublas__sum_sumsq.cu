// cublas -- workload sum_sumsq.  A reduction contender: see common.cuh for the protocol and timing.
#include <cublas_v2.h>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;
struct P { float s; float q; };
struct ToP { __host__ __device__ P operator()(float x) const { return P{x, x * x}; } };
struct AddP { __host__ __device__ P operator()(P a, P b) const { return P{a.s + b.s, a.q + b.q}; } };

static cublasHandle_t h = nullptr;
static float *d_out = nullptr;   // [asum, dot]
static void launch(cudaStream_t s, const float *in, size_t n) {
    // What a BLAS user writes: TWO calls, so TWO passes over memory (asum, then dot(x, x)).
    if (!h) { cublasCreate(&h); cublasSetPointerMode(h, CUBLAS_POINTER_MODE_DEVICE); cudaMalloc(&d_out, 2 * sizeof(float)); }
    cublasSetStream(h, s);
    cublasSasum(h, (int)n, in, 1, d_out);
    cublasSdot(h, (int)n, in, 1, in, 1, d_out + 1);
}
static void fetch(double *outs) { float v[2]; cudaMemcpy(v, d_out, sizeof v, cudaMemcpyDeviceToHost); outs[0] = v[0]; outs[1] = v[1]; }

#include "common.cuh"
