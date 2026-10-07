// thrust -- workload argmax.  A reduction contender: see common.cuh for the protocol and timing.
#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include <thrust/transform_reduce.h>
#include <thrust/extrema.h>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;

static size_t h_idx = 0;
static const float *h_in = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    // max_element returns the FIRST maximum.
    h_idx = thrust::max_element(thrust::cuda::par.on(s), in, in + n) - in;
    h_in = in;
}
static void fetch(double *outs) { float v; cudaMemcpy(&v, h_in + h_idx, sizeof v, cudaMemcpyDeviceToHost); outs[0] = v; outs[1] = (double)h_idx; }

#include "common.cuh"
