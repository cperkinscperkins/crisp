// cublas -- workload sum.  A reduction contender: see common.cuh for the protocol and timing.
#include <cublas_v2.h>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static cublasHandle_t h = nullptr;
static float *d_out = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    // asum = sum of |x|; the generated data are non-negative, so it is the sum.  Device pointer
    // mode keeps the call asynchronous, so the events time the kernel(s) alone.
    if (!h) { cublasCreate(&h); cublasSetPointerMode(h, CUBLAS_POINTER_MODE_DEVICE); cudaMalloc(&d_out, sizeof(float)); }
    cublasSetStream(h, s);
    cublasSasum(h, (int)n, in, 1, d_out);
}
static void fetch(double *outs) { float v; cudaMemcpy(&v, d_out, sizeof v, cudaMemcpyDeviceToHost); outs[0] = v; }

#include "common.cuh"
