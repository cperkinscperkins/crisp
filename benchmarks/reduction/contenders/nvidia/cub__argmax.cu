// cub -- workload argmax.  A reduction contender: see common.cuh for the protocol and timing.
#include <cub/cub.cuh>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;

static void *d_temp = nullptr;
static size_t temp_bytes = 0;
static cub::KeyValuePair<int, float> *d_out = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    // ArgMax returns the FIRST maximum -- the same tie-break as the Crisp kernel.
    if (!d_out) {
        cudaMalloc(&d_out, sizeof(*d_out));
        cub::DeviceReduce::ArgMax(nullptr, temp_bytes, in, d_out, (int)n, s);
        cudaMalloc(&d_temp, temp_bytes);
    }
    cub::DeviceReduce::ArgMax(d_temp, temp_bytes, in, d_out, (int)n, s);
}
static void fetch(double *outs) {
    cub::KeyValuePair<int, float> v; cudaMemcpy(&v, d_out, sizeof v, cudaMemcpyDeviceToHost);
    outs[0] = v.value; outs[1] = (double)v.key;
}

#include "common.cuh"
