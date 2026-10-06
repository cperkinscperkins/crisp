// thrust -- workload sum.  A reduction contender: see common.cuh for the protocol and timing.
#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include <thrust/transform_reduce.h>
#include <thrust/extrema.h>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static double h_out = 0;
static void launch(cudaStream_t s, const float *in, size_t n) {
    h_out = thrust::reduce(thrust::cuda::par.on(s), in, in + n, 0.0f);
}
static void fetch(double *outs) { outs[0] = h_out; }

#include "common.cuh"
