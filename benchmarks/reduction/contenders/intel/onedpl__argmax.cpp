// onedpl -- workload argmax.  A reduction contender: see common.hpp for the protocol and timing.
#include <oneapi/dpl/execution>
#include <oneapi/dpl/algorithm>
#include <oneapi/dpl/numeric>
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"best", "f32"}, {"best_at", "u64"}};
static const size_t N_OUTPUTS = 2;
struct VI { float v; uint64_t i; };

static size_t h_idx = 0;
static const float *h_in = nullptr;
static void launch(sycl::queue &q, const float *in, size_t n) {
    // max_element returns the FIRST maximum -- the same tie-break as the Crisp kernel.
    h_idx = oneapi::dpl::max_element(oneapi::dpl::execution::make_device_policy(q), in, in + n) - in;
    h_in = in;
}
static void fetch(sycl::queue &q, double *outs) { float v; q.memcpy(&v, h_in + h_idx, sizeof v).wait(); outs[0] = v; outs[1] = (double)h_idx; }

#include "common.hpp"
