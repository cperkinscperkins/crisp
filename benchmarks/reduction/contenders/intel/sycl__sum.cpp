// sycl -- workload sum.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static float *d_out = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    if (!d_out) d_out = sycl::malloc_device<float>(1, q);
    q.parallel_for(sycl::range<1>(n), sycl::reduction(d_out, 0.0f, sycl::plus<float>(), sycl::property::reduction::initialize_to_identity{}),
                   [=](sycl::id<1> i, auto &s) { s += in[i]; }).wait();
}
static void fetch(sycl::queue &q, double *outs) { float v; q.memcpy(&v, d_out, sizeof v).wait(); outs[0] = v; }

#include "common.hpp"
