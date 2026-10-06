// cub -- workload welford.  A reduction contender: see common.cuh for the protocol and timing.
#include <cub/cub.cuh>
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

static void *d_temp = nullptr;
static size_t temp_bytes = 0;
static W *d_out = nullptr;
static void launch(cudaStream_t s, const float *in, size_t n) {
    cub::TransformInputIterator<W, ToW, const float *> it(in, ToW());
    if (!d_out) {
        cudaMalloc(&d_out, sizeof(W));
        cub::DeviceReduce::Reduce(nullptr, temp_bytes, it, d_out, (int)n, MergeW(), W{0ull, 0.0f, 0.0f}, s);
        cudaMalloc(&d_temp, temp_bytes);
    }
    cub::DeviceReduce::Reduce(d_temp, temp_bytes, it, d_out, (int)n, MergeW(), W{0ull, 0.0f, 0.0f}, s);
}
static void fetch(double *outs) { W v; cudaMemcpy(&v, d_out, sizeof v, cudaMemcpyDeviceToHost); outs[0] = (double)v.n; outs[1] = v.mean; outs[2] = v.m2; }

#include "common.cuh"
