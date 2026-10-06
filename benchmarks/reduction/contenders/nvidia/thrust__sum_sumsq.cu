// thrust -- workload sum_sumsq.  A reduction contender: see common.cuh for the protocol and timing.
#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include <thrust/transform_reduce.h>
#include <thrust/extrema.h>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;
struct P { float s; float q; };
struct ToP { __host__ __device__ P operator()(float x) const { return P{x, x * x}; } };
struct AddP { __host__ __device__ P operator()(P a, P b) const { return P{a.s + b.s, a.q + b.q}; } };

static P h_out{0, 0};
static void launch(cudaStream_t s, const float *in, size_t n) {
    // ONE pass: transform_reduce over (x, x*x).
    h_out = thrust::transform_reduce(thrust::cuda::par.on(s), in, in + n, ToP(), P{0.0f, 0.0f}, AddP());
}
static void fetch(double *outs) { outs[0] = h_out.s; outs[1] = h_out.q; }

#include "common.cuh"
