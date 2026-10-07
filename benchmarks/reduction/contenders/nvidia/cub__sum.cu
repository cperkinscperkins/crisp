// cub -- workload sum.  A reduction contender: see common.cuh for the protocol and timing.
#include <cub/cub.cuh>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static void *d_temp = nullptr;
static size_t temp_bytes = 0;
static float *d_out = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    if (!d_out) {
        cudaMalloc(&d_out, sizeof(float));
        cub::DeviceReduce::Sum(nullptr, temp_bytes, in, d_out, (int)n, s);
        cudaMalloc(&d_temp, temp_bytes);
    }
    cub::DeviceReduce::Sum(d_temp, temp_bytes, in, d_out, (int)n, s);
}
static void fetch(double *outs) { float v; cudaMemcpy(&v, d_out, sizeof v, cudaMemcpyDeviceToHost); outs[0] = v; }

#include "common.cuh"
