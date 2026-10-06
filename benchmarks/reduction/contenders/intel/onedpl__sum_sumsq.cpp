// onedpl -- workload sum_sumsq.  A reduction contender: see common.hpp for the protocol and timing.
#include <oneapi/dpl/execution>
#include <oneapi/dpl/algorithm>
#include <oneapi/dpl/numeric>
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;

struct P { float s; float q; };
static P h_out{0, 0};
static void launch(sycl::queue &q, const float *in, size_t n) {
    // ONE pass: transform each element to (x, x*x) and reduce the pairs.
    h_out = oneapi::dpl::transform_reduce(oneapi::dpl::execution::make_device_policy(q), in, in + n, P{0.0f, 0.0f},
                                          [](P a, P b) { return P{a.s + b.s, a.q + b.q}; },
                                          [](float x) { return P{x, x * x}; });
}
static void fetch(sycl::queue &, double *outs) { outs[0] = h_out.s; outs[1] = h_out.q; }

#include "common.hpp"
