// read_bw.cpp -- the measured READ-bandwidth ceiling for the reduction suite.
//
// A reduction reads every input byte once and writes almost nothing, so the honest ceiling for its
// GB/s is the fastest a device can stream bytes IN -- measured here, never taken from a spec sheet.
// This is the denominator of the report's "% of measured peak" column.
//
// The probe is a reduction stripped to its memory traffic: each work-item strides over the input,
// accumulates, and writes ONE partial.  The partial array is (global size) floats -- negligible bytes
// -- and it keeps the loads live: the input is all 1.0f, so the host requires sum(partials) == N.  A
// configuration that "ran fast" without reading every element fails that check and is discarded.
//
// Several configurations are swept per size and the best is the ceiling: load width (scalar float,
// float4), work-group size, and grid size (a multiple of the device's compute units, plus one
// work-item per element/vector).  Timing is SYCL event profiling (kernel only), as the matmul SYCL
// apples are timed.
//
// Build:  icpx -fsycl -O3 -o read_bw read_bw.cpp
// Run:    ./read_bw [--sizes-mb=64,256,1024,4096] [--iters=20] [--warmup=3] [--json=out.json]
//                   [--pattern=ones|hash]
//
// Output: a human table on stderr; one JSON object on stdout (or --json file).

#include <sycl/sycl.hpp>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

struct Config {
    int vec;            // 1 = float, 4 = float4
    size_t wg;          // work-group size
    size_t groups;      // number of work-groups (0 = one work-item per element/vector)
};

struct Measurement {
    Config cfg;
    double best_ms = 0, median_ms = 0, best_gbs = 0, median_gbs = 0;
    bool verified = false;
};

static std::vector<size_t> parse_list(const char* s) {
    std::vector<size_t> v;
    while (*s) {
        v.push_back(std::strtoull(s, nullptr, 10));
        const char* c = std::strchr(s, ',');
        if (!c) break;
        s = c + 1;
    }
    return v;
}

template <int VEC>
static sycl::event launch(sycl::queue& q, const float* in, float* partial, size_t n_elems, size_t wg, size_t groups) {
    using V = sycl::vec<float, VEC>;
    const size_t n_vec = n_elems / VEC;
    const size_t global = groups ? groups * wg : ((n_vec + wg - 1) / wg) * wg;
    const V* inv = reinterpret_cast<const V*>(in);
    return q.parallel_for(sycl::nd_range<1>(global, wg), [=](sycl::nd_item<1> it) {
        const size_t gid = it.get_global_id(0);
        const size_t stride = it.get_global_range(0);
        float acc = 0.0f;
        for (size_t i = gid; i < n_vec; i += stride) {
            V x = inv[i];
            for (int k = 0; k < VEC; ++k) acc += x[k];
        }
        partial[gid] = acc;
    });
}

static Measurement measure(sycl::queue& q, const float* in, float* partial, size_t n_elems, Config cfg,
                           int warmup, int iters, double expected) {
    Measurement m;
    m.cfg = cfg;
    const size_t n_vec = n_elems / cfg.vec;
    const size_t global = cfg.groups ? cfg.groups * cfg.wg : ((n_vec + cfg.wg - 1) / cfg.wg) * cfg.wg;
    auto run = [&]() {
        return cfg.vec == 4 ? launch<4>(q, in, partial, n_elems, cfg.wg, cfg.groups)
                            : launch<1>(q, in, partial, n_elems, cfg.wg, cfg.groups);
    };
    for (int i = 0; i < warmup; ++i) run().wait();
    std::vector<double> ms;
    for (int i = 0; i < iters; ++i) {
        auto e = run();
        e.wait();
        auto t0 = e.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto t1 = e.get_profiling_info<sycl::info::event_profiling::command_end>();
        ms.push_back((t1 - t0) * 1e-6);
    }
    // Verify the LAST timed launch: the partials must sum to the host-computed total of the input.
    std::vector<float> h(global);
    q.memcpy(h.data(), partial, global * sizeof(float)).wait();
    double sum = 0;
    for (float f : h) sum += f;
    m.verified = (sum == expected);

    std::sort(ms.begin(), ms.end());
    m.best_ms = ms.front();
    m.median_ms = ms[ms.size() / 2];
    const double gb = n_elems * sizeof(float) / 1e9;
    m.best_gbs = gb / (m.best_ms * 1e-3);
    m.median_gbs = gb / (m.median_ms * 1e-3);
    return m;
}

static std::string json_escape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        o += c;
    }
    return o;
}

int main(int argc, char** argv) {
    std::vector<size_t> sizes_mb = {16, 64, 256, 1024, 4096};
    int iters = 20, warmup = 3;
    std::string json_path;
    std::string pattern = "ones";  // "ones" (all 1.0f) or "hash" (scattered small integers 0..7)
    for (int i = 1; i < argc; ++i) {
        if (!std::strncmp(argv[i], "--pattern=", 10)) pattern = argv[i] + 10;
        if (!std::strncmp(argv[i], "--sizes-mb=", 11)) sizes_mb = parse_list(argv[i] + 11);
        else if (!std::strncmp(argv[i], "--iters=", 8)) iters = std::atoi(argv[i] + 8);
        else if (!std::strncmp(argv[i], "--warmup=", 9)) warmup = std::atoi(argv[i] + 9);
        else if (!std::strncmp(argv[i], "--json=", 7)) json_path = argv[i] + 7;
    }

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling()};
    auto dev = q.get_device();
    const std::string name = dev.get_info<sycl::info::device::name>();
    const std::string driver = dev.get_info<sycl::info::device::driver_version>();
    const size_t cus = dev.get_info<sycl::info::device::max_compute_units>();
    const size_t max_wg = dev.get_info<sycl::info::device::max_work_group_size>();
    const uint64_t mem = dev.get_info<sycl::info::device::global_mem_size>();
    const uint64_t l2 = dev.get_info<sycl::info::device::global_mem_cache_size>();
    std::fprintf(stderr, "device: %s  driver %s  CUs %zu  max-wg %zu  mem %.1f GB  cache %.1f MB\n",
                 name.c_str(), driver.c_str(), cus, max_wg, mem / 1e9, l2 / 1e6);

    // Configurations: every combination below, skipping work-groups the device refuses.
    std::vector<Config> cfgs;
    for (int vec : {1, 4})
        for (size_t wg : {256, 512, 1024})
            if (wg <= max_wg)
                for (size_t mult : {0, 1, 2, 4, 8, 16})  // 0 = one work-item per element/vector
                    cfgs.push_back({vec, wg, mult ? mult * cus : 0});

    std::string out = "{\n  \"kind\": \"read-bandwidth-ceiling\",\n";
    out += "  \"device\": \"" + json_escape(name) + "\",\n";
    out += "  \"driver\": \"" + json_escape(driver) + "\",\n";
    out += "  \"compute_units\": " + std::to_string(cus) + ",\n";
    out += "  \"global_mem_bytes\": " + std::to_string(mem) + ",\n";
    out += "  \"cache_bytes\": " + std::to_string(l2) + ",\n";
    out += "  \"timestamp\": " + std::to_string(static_cast<long long>(std::time(nullptr))) + ",\n";
    out += "  \"iters\": " + std::to_string(iters) + ",\n";
    out += "  \"pattern\": \"" + pattern + "\",\n  \"sizes\": [\n";

    double peak = 0;
    bool first_size = true;
    for (size_t mb : sizes_mb) {
        const size_t bytes = mb * 1024ull * 1024ull;
        if (bytes > mem / 3) {
            std::fprintf(stderr, "skip %zu MB: over a third of device memory\n", mb);
            continue;
        }
        const size_t n = bytes / sizeof(float);
        float* in = sycl::malloc_device<float>(n, q);
        size_t max_global = ((n + 255) / 256) * 256 + 16 * cus * 1024;
        float* partial = sycl::malloc_device<float>(max_global, q);
        // Constant data may be cheaper to read than real data: discrete Xe2 can compress device memory
        // losslessly, and an all-1.0f buffer compresses almost perfectly.  "hash" fills scattered small
        // integers (exact float sums) so the ceiling can be measured on data that does not compress.
        double expected = 0;
        if (pattern == "hash") {
            q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) {
                in[i] = static_cast<float>((static_cast<uint32_t>(i[0]) * 2654435761u) >> 29);
            }).wait();
            for (size_t i = 0; i < n; ++i)
                expected += static_cast<double>((static_cast<uint32_t>(i) * 2654435761u) >> 29);
        } else {
            q.fill(in, 1.0f, n).wait();
            expected = static_cast<double>(n);
        }

        Measurement best;
        std::fprintf(stderr, "\n%zu MB:\n", mb);
        for (const auto& c : cfgs) {
            Measurement m = measure(q, in, partial, n, c, warmup, iters, expected);
            std::fprintf(stderr, "  vec%d wg%-4zu groups %-6s  best %8.1f GB/s  median %8.1f GB/s  %s\n",
                         c.vec, c.wg, c.groups ? std::to_string(c.groups).c_str() : "per-el",
                         m.best_gbs, m.median_gbs, m.verified ? "ok" : "WRONG-SUM (discarded)");
            if (m.verified && m.median_gbs > best.median_gbs) best = m;
        }
        sycl::free(in, q);
        sycl::free(partial, q);

        const bool past_cache = bytes >= 4 * l2;
        if (past_cache) peak = std::max(peak, best.median_gbs);
        if (!first_size) out += ",\n";
        first_size = false;
        out += "    {\"mb\": " + std::to_string(mb) + ", \"bytes\": " + std::to_string(bytes) +
               ", \"past_cache\": " + (past_cache ? "true" : "false") +
               ", \"best_config\": {\"vec\": " + std::to_string(best.cfg.vec) +
               ", \"wg\": " + std::to_string(best.cfg.wg) + ", \"groups\": " + std::to_string(best.cfg.groups) +
               "}, \"median_gbs\": " + std::to_string(best.median_gbs) +
               ", \"best_gbs\": " + std::to_string(best.best_gbs) +
               ", \"median_ms\": " + std::to_string(best.median_ms) + "}";
        std::fprintf(stderr, "  => best median %.1f GB/s (vec%d wg%zu groups %zu)%s\n", best.median_gbs,
                     best.cfg.vec, best.cfg.wg, best.cfg.groups, past_cache ? "" : "  [fits in cache]");
    }
    // The ceiling is the best MEDIAN over sizes at least 4x the cache: DRAM, not cache.
    out += "\n  ],\n  \"peak_read_gbs\": " + std::to_string(peak) + "\n}\n";
    std::fprintf(stderr, "\nPEAK READ (median, sizes >= 4x cache): %.1f GB/s\n", peak);

    if (json_path.empty()) {
        std::fputs(out.c_str(), stdout);
    } else {
        FILE* f = std::fopen(json_path.c_str(), "w");
        if (!f) { std::perror(json_path.c_str()); return 1; }
        std::fputs(out.c_str(), f);
        std::fclose(f);
    }
    return 0;
}
