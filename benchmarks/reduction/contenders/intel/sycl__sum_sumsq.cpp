// sycl -- workload sum_sumsq.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;

static float *d_out = nullptr;   // [sum, sumsq]
static void launch(sycl::queue &q, const float *in, size_t n) {
    if (!d_out) d_out = sycl::malloc_device<float>(2, q);
    float *ds = d_out, *dq = d_out + 1;
    // TWO reducers in ONE parallel_for: SYCL's own one-pass answer to sum + sum of squares.
    q.parallel_for(sycl::range<1>(n),
                   sycl::reduction(ds, 0.0f, sycl::plus<float>(), sycl::property::reduction::initialize_to_identity{}),
                   sycl::reduction(dq, 0.0f, sycl::plus<float>(), sycl::property::reduction::initialize_to_identity{}),
                   [=](sycl::id<1> i, auto &s, auto &sq) { const float x = in[i]; s += x; sq += x * x; }).wait();
}
static void fetch(sycl::queue &q, double *outs) { float v[2]; q.memcpy(v, d_out, sizeof v).wait(); outs[0] = v[0]; outs[1] = v[1]; }

#include "common.hpp"
