// onemkl -- workload sum_sumsq.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <oneapi/mkl.hpp>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"total", "f32"}, {"total_sq", "f32"}};
static const size_t N_OUTPUTS = 2;

static float *d_out = nullptr;   // [asum, dot]
static void launch(sycl::queue &q, const float *in, size_t n) {
    // What a BLAS user writes: TWO calls, so TWO passes over memory (asum, then dot(x, x)).
    if (!d_out) d_out = sycl::malloc_device<float>(2, q);
    auto e1 = oneapi::mkl::blas::column_major::asum(q, (std::int64_t)n, in, 1, d_out);
    auto e2 = oneapi::mkl::blas::column_major::dot(q, (std::int64_t)n, in, 1, in, 1, d_out + 1);
    e1.wait(); e2.wait();
}
static void fetch(sycl::queue &q, double *outs) { float v[2]; q.memcpy(v, d_out, sizeof v).wait(); outs[0] = v[0]; outs[1] = v[1]; }

#include "common.hpp"
