// thrust -- workload welford.  A reduction contender: see common.cuh for the protocol and timing.
#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include <thrust/transform_reduce.h>
#include <thrust/extrema.h>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"count", "u64"}, {"mean", "f32"}, {"m2", "f32"}};
static const size_t N_OUTPUTS = 3;
struct W { unsigned long long n; float mean; float m2; };
// Chan's parallel merge -- the same formula as the Crisp kernel's welford-combine.
struct MergeW {
    __host__ __device__ W operator()(W a, W b) const {
        const unsigned long long n = a.n + b.n;
        const float nf = (float)(n > 0 ? n : 1), d = b.mean - a.mean;
        return W{n, a.mean + d * (float)b.n / nf, a.m2 + b.m2 + d * d * ((float)a.n * (float)b.n) / nf};
    }
};
struct ToW { __host__ __device__ W operator()(float x) const { return W{1ull, x, 0.0f}; } };

static W h_out{0, 0, 0};
static void launch(cudaStream_t s, const float *in, size_t n) {
    h_out = thrust::transform_reduce(thrust::cuda::par.on(s), in, in + n, ToW(), W{0ull, 0.0f, 0.0f}, MergeW());
}
static void fetch(double *outs) { outs[0] = (double)h_out.n; outs[1] = h_out.mean; outs[2] = h_out.m2; }

#include "common.cuh"
