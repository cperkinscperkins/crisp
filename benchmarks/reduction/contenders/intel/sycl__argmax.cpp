// sycl -- workload argmax.  A reduction contender: see common.hpp for the protocol and timing.
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;
struct VI { float v; uint64_t i; };

static VI *d_out = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    if (!d_out) d_out = sycl::malloc_device<VI>(1, q);
    auto comb = [](VI a, VI b) { return (a.v > b.v || (a.v == b.v && a.i < b.i)) ? a : b; };
    q.parallel_for(sycl::range<1>(n), sycl::reduction(d_out, VI{-FLT_MAX, UINT64_MAX}, comb, sycl::property::reduction::initialize_to_identity{}),
                   [=](sycl::id<1> i, auto &r) { r.combine(VI{in[i], (uint64_t)i[0]}); }).wait();
}
static void fetch(sycl::queue &q, double *outs) { VI v; q.memcpy(&v, d_out, sizeof v).wait(); outs[0] = v.v; outs[1] = (double)v.i; }

#include "common.hpp"
