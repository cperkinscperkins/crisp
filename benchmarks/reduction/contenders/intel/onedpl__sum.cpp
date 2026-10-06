// onedpl -- workload sum.  A reduction contender: see common.hpp for the protocol and timing.
#include <oneapi/dpl/execution>
#include <oneapi/dpl/algorithm>
#include <oneapi/dpl/numeric>
#include <sycl/sycl.hpp>
#include <cfloat>
#include <cstdint>

struct Output { const char *name; const char *elem; };
static const Output OUTPUTS[] = {{"result", "f32"}};
static const size_t N_OUTPUTS = 1;

static double h_out = 0;
static void launch(sycl::queue &q, const float *in, size_t n) {
    h_out = oneapi::dpl::reduce(oneapi::dpl::execution::make_device_policy(q), in, in + n, 0.0f);
}
static void fetch(sycl::queue &, double *outs) { outs[0] = h_out; }

#include "common.hpp"
