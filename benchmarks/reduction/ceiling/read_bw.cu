// read_bw.cu -- the CUDA twin of read_bw.cpp: the measured READ-bandwidth ceiling on NVIDIA.
//
// Same method, same output: a reduction stripped to its memory traffic, swept over load width
// (float, float4), block size and grid size (multiples of the SM count, plus one thread per
// element/vector), best MEDIAN kept; every timed launch verified (the partials must sum to the
// host's total of the input); peak = best median over sizes at least 4x the L2.  See read_bw.cpp
// for the reasoning; this file differs only in the API.
//
// Build:  nvcc -O3 -o read_bw read_bw.cu
// Run:    ./read_bw [--sizes-mb=...] [--iters=20] [--warmup=3] [--pattern=hash|ones] [--json=out.json]

#include <cuda_runtime.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    std::fprintf(stderr, "CUDA error %s at %s\n", cudaGetErrorString(e_), #x); std::exit(2); } } while (0)

struct Config { int vec; int wg; int groups; };   // groups 0 = one thread per element/vector

template <int VEC>
__global__ void read_kernel(const float *in, float *partial, size_t n_elems) {
    const size_t n_vec = n_elems / VEC;
    const size_t gid = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    const size_t stride = (size_t)gridDim.x * blockDim.x;
    float acc = 0.0f;
    if (VEC == 4) {
        const float4 *v = reinterpret_cast<const float4 *>(in);
        for (size_t i = gid; i < n_vec; i += stride) { float4 x = v[i]; acc += x.x + x.y + x.z + x.w; }
    } else {
        for (size_t i = gid; i < n_vec; i += stride) acc += in[i];
    }
    partial[gid] = acc;
}

__global__ void fill_hash(float *in, size_t n, uint32_t seed) {
    const size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) in[i] = (float)(((uint32_t)i * 2654435761u + seed * 0x9E3779B9u) >> 29);
}

static std::vector<size_t> parse_list(const char *s) {
    std::vector<size_t> v;
    while (*s) {
        v.push_back(std::strtoull(s, nullptr, 10));
        const char *c = std::strchr(s, ',');
        if (!c) break;
        s = c + 1;
    }
    return v;
}

int main(int argc, char **argv) {
    std::vector<size_t> sizes_mb = {16, 64, 256, 1024, 4096};
    int iters = 20, warmup = 3;
    std::string json_path, pattern = "hash";
    for (int i = 1; i < argc; ++i) {
        if (!std::strncmp(argv[i], "--sizes-mb=", 11)) sizes_mb = parse_list(argv[i] + 11);
        else if (!std::strncmp(argv[i], "--iters=", 8)) iters = std::atoi(argv[i] + 8);
        else if (!std::strncmp(argv[i], "--warmup=", 9)) warmup = std::atoi(argv[i] + 9);
        else if (!std::strncmp(argv[i], "--json=", 7)) json_path = argv[i] + 7;
        else if (!std::strncmp(argv[i], "--pattern=", 10)) pattern = argv[i] + 10;
    }
    cudaDeviceProp p;
    CK(cudaGetDeviceProperties(&p, 0));
    const int sms = p.multiProcessorCount;
    const size_t mem = p.totalGlobalMem, l2 = (size_t)p.l2CacheSize;
    int drv = 0; cudaDriverGetVersion(&drv);
    std::fprintf(stderr, "device: %s  SMs %d  mem %.1f GB  L2 %.1f MB\n", p.name, sms, mem / 1e9, l2 / 1e6);

    std::vector<Config> cfgs;
    for (int vec : {1, 4})
        for (int wg : {256, 512, 1024})
            for (int mult : {0, 1, 2, 4, 8, 16})
                cfgs.push_back({vec, wg, mult * sms});

    cudaEvent_t e0, e1;
    CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));
    std::string out = "{\n  \"kind\": \"read-bandwidth-ceiling\",\n";
    out += std::string("  \"device\": \"") + p.name + "\",\n";
    out += "  \"driver\": \"" + std::to_string(drv) + "\",\n";
    out += "  \"compute_units\": " + std::to_string(sms) + ",\n";
    out += "  \"global_mem_bytes\": " + std::to_string(mem) + ",\n";
    out += "  \"cache_bytes\": " + std::to_string(l2) + ",\n";
    out += "  \"timestamp\": " + std::to_string((long long)std::time(nullptr)) + ",\n";
    out += "  \"iters\": " + std::to_string(iters) + ",\n";
    out += "  \"pattern\": \"" + pattern + "\",\n  \"sizes\": [\n";

    double peak = 0;
    bool first = true;
    for (size_t mb : sizes_mb) {
        const size_t bytes = mb * 1024ull * 1024ull;
        if (bytes > mem / 3) { std::fprintf(stderr, "skip %zu MB: over a third of device memory\n", mb); continue; }
        const size_t n = bytes / sizeof(float);
        float *in = nullptr, *partial = nullptr;
        const size_t max_global = ((n + 255) / 256) * 256 + (size_t)16 * sms * 1024;
        CK(cudaMalloc(&in, bytes));
        CK(cudaMalloc(&partial, max_global * sizeof(float)));
        double expected = 0;
        if (pattern == "hash") {
            fill_hash<<<(unsigned)((n + 255) / 256), 256>>>(in, n, 1);
            CK(cudaDeviceSynchronize());
            for (size_t i = 0; i < n; ++i) expected += (double)(((uint32_t)i * 2654435761u + 0x9E3779B9u) >> 29);
        } else {
            std::vector<float> ones(1 << 20, 1.0f);
            for (size_t off = 0; off < n; off += ones.size())
                CK(cudaMemcpy(in + off, ones.data(), std::min(ones.size(), n - off) * sizeof(float), cudaMemcpyHostToDevice));
            expected = (double)n;
        }
        Config bestc{0, 0, 0};
        double best_med = 0, best_best = 0, best_ms = 0;
        std::fprintf(stderr, "\n%zu MB:\n", mb);
        for (const auto &c : cfgs) {
            const size_t n_vec = n / c.vec;
            const unsigned blocks = c.groups ? (unsigned)c.groups : (unsigned)((n_vec + c.wg - 1) / c.wg);
            auto run = [&]() {
                if (c.vec == 4) read_kernel<4><<<blocks, c.wg>>>(in, partial, n);
                else            read_kernel<1><<<blocks, c.wg>>>(in, partial, n);
            };
            for (int i = 0; i < warmup; ++i) run();
            CK(cudaDeviceSynchronize());
            std::vector<double> ms;
            for (int i = 0; i < iters; ++i) {
                CK(cudaEventRecord(e0)); run(); CK(cudaEventRecord(e1)); CK(cudaEventSynchronize(e1));
                float t = 0; CK(cudaEventElapsedTime(&t, e0, e1)); ms.push_back(t);
            }
            const size_t global = (size_t)blocks * c.wg;
            std::vector<float> h(global);
            CK(cudaMemcpy(h.data(), partial, global * sizeof(float), cudaMemcpyDeviceToHost));
            double sum = 0; for (float f : h) sum += f;
            const bool ok = (sum == expected);
            std::sort(ms.begin(), ms.end());
            const double gb = bytes / 1e9, med = gb / (ms[ms.size() / 2] * 1e-3), best = gb / (ms.front() * 1e-3);
            std::fprintf(stderr, "  vec%d wg%-4d groups %-6s  best %8.1f GB/s  median %8.1f GB/s  %s\n",
                         c.vec, c.wg, c.groups ? std::to_string(c.groups).c_str() : "per-el", best, med,
                         ok ? "ok" : "WRONG-SUM (discarded)");
            if (ok && med > best_med) { best_med = med; best_best = best; best_ms = ms[ms.size() / 2]; bestc = c; }
        }
        CK(cudaFree(in)); CK(cudaFree(partial));
        const bool past = bytes >= 4 * l2;
        if (past) peak = std::max(peak, best_med);
        if (!first) out += ",\n";
        first = false;
        out += "    {\"mb\": " + std::to_string(mb) + ", \"bytes\": " + std::to_string(bytes) +
               ", \"past_cache\": " + (past ? "true" : "false") +
               ", \"best_config\": {\"vec\": " + std::to_string(bestc.vec) + ", \"wg\": " + std::to_string(bestc.wg) +
               ", \"groups\": " + std::to_string(bestc.groups) + "}, \"median_gbs\": " + std::to_string(best_med) +
               ", \"best_gbs\": " + std::to_string(best_best) + ", \"median_ms\": " + std::to_string(best_ms) + "}";
        std::fprintf(stderr, "  => best median %.1f GB/s%s\n", best_med, past ? "" : "  [fits in cache]");
    }
    out += "\n  ],\n  \"peak_read_gbs\": " + std::to_string(peak) + "\n}\n";
    std::fprintf(stderr, "\nPEAK READ (median, sizes >= 4x L2): %.1f GB/s\n", peak);
    if (json_path.empty()) std::fputs(out.c_str(), stdout);
    else { FILE *f = std::fopen(json_path.c_str(), "w"); if (!f) return 1; std::fputs(out.c_str(), f); std::fclose(f); }
    return 0;
}
