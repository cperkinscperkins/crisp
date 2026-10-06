// onemkl -- workload argmax.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <oneapi/mkl.hpp>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;
struct VI { float v; uint64_t i; };

static std::int64_t *d_idx = nullptr;
static const float *h_in = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    // iamax = first index of the largest |x|; non-negative data make it argmax.
    if (!d_idx) d_idx = sycl::malloc_device<std::int64_t>(1, q);
    oneapi::mkl::blas::column_major::iamax(q, (std::int64_t)n, in, 1, d_idx).wait();
    h_in = in;
}
static void fetch(sycl::queue &q, double *outs) {
    std::int64_t i; q.memcpy(&i, d_idx, sizeof i).wait();
    float v; q.memcpy(&v, h_in + i, sizeof v).wait();
    outs[0] = v; outs[1] = (double)i;
}

#include "common.hpp"
