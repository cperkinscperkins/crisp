// common.hpp -- the shared harness for the Intel (SYCL) reduction contenders.
//
// Each contender is a small .cpp that defines:
//     static const Output OUTPUTS[];                        // names/types, matching the Crisp
//     static const size_t N_OUTPUTS;                        //   kernel's BENCH-EXPECT outputs
//     static void launch(sycl::queue &q, const float *in, size_t n);   // the reduction; must wait
//     static void fetch(sycl::queue &q, double *outs);      // copy the results to the host
// and then #includes this file, which supplies main().  One file per (library, workload) so each
// contender's DEVICE COMPILE TIME is its own (library templates are where compile time goes).
//
// The protocol and the results format are reduce_fixture_l0.cpp's, so scripts/crisp_bench/
// reduction.py verifies a contender exactly as it verifies Crisp:
//   generate input (seed 1) + double-precision statistics; warmup; timed calls; read back -> "A";
//   regenerate (seed 2); one more call; read back -> "B".
//
// TIMING differs, deliberately and visibly.  A library call (oneDPL above all) may submit several
// kernels and hands back no single event, so a contender is timed by the HOST CLOCK around
// launch() -- which waits.  That includes the submission overhead a Crisp kernel timestamp does
// not.  `launch_overhead_us` (an empty single_task, same clock) is reported so it can be read off;
// it is negligible from ~64 MiB up and dominant at 1 MiB.
//
// Usage:  <exe> --mb=<MiB of input> --warmup=<n> --iters=<n> --results=<file>

#include <sycl/sycl.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// struct Output { const char *name; const char *elem; };  -- defined by each contender, before
// this header, because its OUTPUTS[] table is (elem: "f32" | "u64").

static inline uint32_t gen_bits(uint64_t i, uint32_t seed, int shift) {
    return ((uint32_t)i * 2654435761u + seed * 0x9E3779B9u) >> shift;
}

static void contender_fill(sycl::queue &q, float *dev, size_t n, uint32_t seed, std::ofstream &res,
                           const char *tag) {
    const size_t chunk = (64u << 20) / sizeof(float);
    std::vector<float> host(std::min(chunk, n));
    double sum = 0, sumsq = 0, mn = INFINITY, mx = -INFINITY;
    uint64_t argmin = 0, argmax = 0;
    for (size_t base = 0; base < n; base += chunk) {
        const size_t m = std::min(chunk, n - base);
        for (size_t j = 0; j < m; ++j) {
            const double v = (double)gen_bits(base + j, seed, 29);
            host[j] = (float)v;
            sum += v; sumsq += v * v;
            if (v < mn) { mn = v; argmin = base + j; }
            if (v > mx) { mx = v; argmax = base + j; }
        }
        q.memcpy(dev + base, host.data(), m * sizeof(float)).wait();
    }
    char line[512];
    std::snprintf(line, sizeof line,
                  "stats %s input count=%llu sum=%.17g sumsq=%.17g min=%.17g argmin=%llu max=%.17g argmax=%llu\n",
                  tag, (unsigned long long)n, sum, sumsq, mn, (unsigned long long)argmin, mx,
                  (unsigned long long)argmax);
    res << line;
}

static void contender_readback(sycl::queue &q, std::ofstream &res, const char *tag) {
    double outs[8] = {0};
    fetch(q, outs);
    for (size_t k = 0; k < N_OUTPUTS; ++k) {
        char v[64];
        if (!std::strcmp(OUTPUTS[k].elem, "u64")) std::snprintf(v, sizeof v, "%llu", (unsigned long long)outs[k]);
        else std::snprintf(v, sizeof v, "%.9g", (float)outs[k]);
        res << "out " << tag << " " << OUTPUTS[k].name << " " << OUTPUTS[k].elem << " " << v << "\n";
    }
}

int main(int argc, char **argv) {
    size_t mb = 64;
    int warmup = 5, iters = 50;
    std::string results;
    for (int i = 1; i < argc; ++i) {
        if (!std::strncmp(argv[i], "--mb=", 5)) mb = std::strtoull(argv[i] + 5, nullptr, 10);
        else if (!std::strncmp(argv[i], "--warmup=", 9)) warmup = std::atoi(argv[i] + 9);
        else if (!std::strncmp(argv[i], "--iters=", 8)) iters = std::max(1, std::atoi(argv[i] + 8));
        else if (!std::strncmp(argv[i], "--results=", 10)) results = argv[i] + 10;
    }
    if (results.empty()) { std::fprintf(stderr, "--results=<file> required\n"); return 1; }
    std::ofstream res(results);
    sycl::queue q{sycl::gpu_selector_v};
    auto dev = q.get_device();
    res << "device " << dev.get_info<sycl::info::device::name>() << "\n";
    res << "eus " << dev.get_info<sycl::info::device::max_compute_units>() << "\n";
    res << "groups 0\njit_ms 0\n";

    const size_t n = (mb << 20) / sizeof(float);
    float *in = sycl::malloc_device<float>(n, q);
    contender_fill(q, in, n, 1, res, "A");

    // Submission overhead on the same clock, so a reader can subtract it at small sizes.
    std::vector<double> ov;
    for (int i = 0; i < 20; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        q.single_task([] {}).wait();
        ov.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count());
    }
    std::sort(ov.begin(), ov.end());
    res << "launch_overhead_us " << ov[ov.size() / 2] << "\n";

    for (int i = 0; i < warmup; ++i) launch(q, in, n);
    std::vector<double> us(iters);
    const auto w0 = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        launch(q, in, n);
        us[i] = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
    }
    const double wall = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - w0).count() / iters;
    res << "time_us";
    for (double u : us) res << " " << u;
    res << "\nwall_us " << wall << "\n";
    contender_readback(q, res, "A");

    contender_fill(q, in, n, 2, res, "B");
    launch(q, in, n);
    contender_readback(q, res, "B");
    sycl::free(in, q);
    return 0;
}
