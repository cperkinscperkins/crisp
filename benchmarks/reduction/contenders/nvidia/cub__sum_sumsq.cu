// cub -- workload sum_sumsq.  A reduction contender: see common.cuh for the protocol and timing.
#include <cub/cub.cuh>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;
struct P { float s; float q; };
struct ToP { __host__ __device__ P operator()(float x) const { return P{x, x * x}; } };
struct AddP { __host__ __device__ P operator()(P a, P b) const { return P{a.s + b.s, a.q + b.q}; } };

static void *d_temp = nullptr;
static size_t temp_bytes = 0;
static P *d_out = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    // ONE pass: each element transformed to (x, x*x), the pairs reduced by one DeviceReduce::Reduce.
    cub::TransformInputIterator<P, ToP, const float *> it(in, ToP());
    if (!d_out) {
        cudaMalloc(&d_out, sizeof(P));
        cub::DeviceReduce::Reduce(nullptr, temp_bytes, it, d_out, (int)n, AddP(), P{0.0f, 0.0f}, s);
        cudaMalloc(&d_temp, temp_bytes);
    }
    cub::DeviceReduce::Reduce(d_temp, temp_bytes, it, d_out, (int)n, AddP(), P{0.0f, 0.0f}, s);
}
static void fetch(double *outs) { P v; cudaMemcpy(&v, d_out, sizeof v, cudaMemcpyDeviceToHost); outs[0] = v.s; outs[1] = v.q; }

#include "common.cuh"
