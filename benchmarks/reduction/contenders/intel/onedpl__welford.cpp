// onedpl -- workload welford.  A reduction contender: see common.hpp for the protocol and timing.
#include <oneapi/dpl/execution>
#include <oneapi/dpl/algorithm>
#include <oneapi/dpl/numeric>
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"count", "u64"}, {"mean", "f32"}, {"m2", "f32"}};
static const size_t N_OUTPUTS = 3;
struct W { uint64_t n; float mean; float m2; };
// Chan's parallel merge -- the same formula as the Crisp kernel's welford-combine.
static inline W welford_merge(W a, W b) {
    const uint64_t n = a.n + b.n;
    const float nf = (float)(n > 0 ? n : 1), d = b.mean - a.mean;
    return W{n, a.mean + d * (float)b.n / nf, a.m2 + b.m2 + d * d * ((float)a.n * (float)b.n) / nf};
}

static W h_out{0, 0, 0};
static void launch(sycl::queue &q, const float *in, size_t n) {
    h_out = oneapi::dpl::transform_reduce(oneapi::dpl::execution::make_device_policy(q), in, in + n, W{0, 0.0f, 0.0f},
                                          [](W a, W b) { return welford_merge(a, b); },
                                          [](float x) { return W{1, x, 0.0f}; });
}
static void fetch(sycl::queue &, double *outs) { outs[0] = (double)h_out.n; outs[1] = h_out.mean; outs[2] = h_out.m2; }

#include "common.hpp"
