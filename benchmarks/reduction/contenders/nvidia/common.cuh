// common.cuh -- the shared harness for the NVIDIA (CUDA) reduction contenders.  The CUDA twin of
// contenders/intel/common.hpp: same data generator, same double-precision statistics, same A/B
// protocol, same results format, so scripts/crisp_bench/reduction.py verifies a contender exactly
// as it verifies Crisp.
//
// Each contender .cu defines, BEFORE including this file:
//     struct Output { const char *name; const char *elem; };   static const Output OUTPUTS[];
//     static const size_t N_OUTPUTS;
//     static void launch(cudaStream_t s, const float *in, size_t n);   // enqueue the reduction
//     static void fetch(double *outs);                                 // results to the host
//
// TIMING: CUDA events recorded on the stream around launch().  Stream order makes the pair bracket
// EVERY kernel a library enqueues between them, so a multi-kernel library call is timed exactly
// like a Crisp kernel (reduce_fixture_cuda.cpp also uses events).  One exception, recorded in the
// results as `timing_note`: a call that returns its result to the HOST (Thrust's reduce /
// transform_reduce / max_element) blocks, so its stop event also covers that small copy-back.
//
// Usage:  <exe> --mb=<MiB of input> --warmup=<n> --iters=<n> --results=<file>

#include <cuda_runtime.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    std::fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); std::exit(2); } } while (0)

static inline uint32_t gen_bits(uint64_t i, uint32_t seed, int shift) {
    return ((uint32_t)i * 2654435761u + seed * 0x9E3779B9u) >> shift;
}

__global__ void contender_empty_kernel() {}

static void contender_fill(float *dev, size_t n, uint32_t seed, std::ofstream &res, const char *tag) {
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
        CK(cudaMemcpy(dev + base, host.data(), m * sizeof(float), cudaMemcpyHostToDevice));
    }
    char line[512];
    std::snprintf(line, sizeof line,
                  "stats %s input count=%llu sum=%.17g sumsq=%.17g min=%.17g argmin=%llu max=%.17g argmax=%llu\n",
                  tag, (unsigned long long)n, sum, sumsq, mn, (unsigned long long)argmin, mx,
                  (unsigned long long)argmax);
    res << line;
}

static void contender_readback(std::ofstream &res, const char *tag) {
    double outs[8] = {0};
    fetch(outs);
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
    cudaDeviceProp p;
    CK(cudaGetDeviceProperties(&p, 0));
    res << "device " << p.name << "\neus " << p.multiProcessorCount << "\ngroups 0\njit_ms 0\n";

    const size_t n = (mb << 20) / sizeof(float);
    float *in = nullptr;
    CK(cudaMalloc(&in, n * sizeof(float)));
    contender_fill(in, n, 1, res, "A");

    cudaStream_t s = 0;                       // the default stream: Thrust's thrust::device uses it
    cudaEvent_t e0, e1;
    CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));

    // An empty kernel on the same clock: the floor any single launch pays.
    std::vector<double> ov;
    for (int i = 0; i < 20; ++i) {
        CK(cudaEventRecord(e0, s));
        contender_empty_kernel<<<1, 1, 0, s>>>();
        CK(cudaEventRecord(e1, s));
        CK(cudaEventSynchronize(e1));
        float ms = 0; CK(cudaEventElapsedTime(&ms, e0, e1));
        ov.push_back(ms * 1000.0);
    }
    std::sort(ov.begin(), ov.end());
    res << "launch_overhead_us " << ov[ov.size() / 2] << "\n";

    for (int i = 0; i < warmup; ++i) { launch(s, in, n); CK(cudaStreamSynchronize(s)); }
    std::vector<double> us(iters);
    for (int i = 0; i < iters; ++i) {
        CK(cudaEventRecord(e0, s));
        launch(s, in, n);
        CK(cudaEventRecord(e1, s));
        CK(cudaEventSynchronize(e1));
        float ms = 0; CK(cudaEventElapsedTime(&ms, e0, e1));
        us[i] = ms * 1000.0;
    }
    CK(cudaDeviceSynchronize());
    res << "time_us";
    for (double u : us) res << " " << u;
    res << "\nwall_us 0\n";
    contender_readback(res, "A");

    contender_fill(in, n, 2, res, "B");
    launch(s, in, n);
    CK(cudaDeviceSynchronize());
    contender_readback(res, "B");
    CK(cudaFree(in));
    return 0;
}
