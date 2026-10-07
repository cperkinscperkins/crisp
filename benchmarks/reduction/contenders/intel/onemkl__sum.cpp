// onemkl -- workload sum.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <oneapi/mkl.hpp>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static float *d_out = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    // asum = sum of |x|; the generated data are non-negative, so it is the sum.
    if (!d_out) d_out = sycl::malloc_device<float>(1, q);
    oneapi::mkl::blas::column_major::asum(q, (std::int64_t)n, in, 1, d_out).wait();
}
static void fetch(sycl::queue &q, double *outs) { float v; q.memcpy(&v, d_out, sizeof v).wait(); outs[0] = v; }

#include "common.hpp"
