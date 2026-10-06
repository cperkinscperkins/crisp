// sycl -- workload welford.  A reduction contender: see common.hpp for the protocol and timing.
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

static W *d_out = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    if (!d_out) d_out = sycl::malloc_device<W>(1, q);
    auto comb = [](W a, W b) { return welford_merge(a, b); };
    q.parallel_for(sycl::range<1>(n), sycl::reduction(d_out, W{0, 0.0f, 0.0f}, comb, sycl::property::reduction::initialize_to_identity{}),
                   [=](sycl::id<1> i, auto &r) { r.combine(W{1, in[i], 0.0f}); }).wait();
}
static void fetch(sycl::queue &q, double *outs) { W v; q.memcpy(&v, d_out, sizeof v).wait(); outs[0] = (double)v.n; outs[1] = v.mean; outs[2] = v.m2; }

#include "common.hpp"
