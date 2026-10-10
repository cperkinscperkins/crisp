// reduce_fixture_cuda.cpp -- the CUDA twin of reduce_fixture_l0.cpp.  ONE fixture for every Crisp
// reduction kernel on NVIDIA: it reads the SAME argument plan (scripts/crisp_bench/metacrisp.py),
// carries it out with the CUDA driver API on a PTX module, times the kernel, and writes the SAME
// results format.  The contract -- plan directives, the launch protocol, the results lines -- is
// documented once, in reduce_fixture_l0.cpp's header; only the differences are noted here.
//
// DIFFERENCES FROM THE L0 FIXTURE
//   * Local scratch.  CUDA has no per-argument local allocation: a kernel gets ONE dynamic shared
//     block, sized at launch, and each scratch argument's pointer slot carries a BYTE OFFSET into it.
//     That is what crisp-hoist-cuda emits (bug 034, *cuda-shared-scratch-offset*) and what the
//     VERIFY-AUTODIFF CUDA runner reproduces (%cuda-scratch-offset): 16-byte-aligned running offsets.
//     A plan's `slot <i> slm <bytes>` therefore becomes an offset here, not a size.
//   * Timing.  CUDA events around the kernel alone (the per-launch fills are recorded before the
//     start event), so a microsecond kernel is not swamped by launch overhead.  The matmul CUDA
//     fixture uses the host clock, which is fine for millisecond GEMMs and not for this.
//   * `groups eu` means the SM count (CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT).
//   * `groups occupancy R [cap=N] [cu=N]` follows crisp-hoist-cuda's :strided formula:
//     cuOccupancyMaxActiveBlocksPerMultiprocessor x SMs (or cu=) x R, capped at cap=.
//   * `jit_ms` times cuModuleLoadData: the driver's PTX -> SASS compile.
//
// USAGE  reduce_fixture_cuda <plan> <results> [--skip-each-fill] [--dirty-once-before-relaunch]
// BUILD  g++ -O2 -std=c++17 reduce_fixture_cuda.cpp -I$CUDA_HOME/include -L$CUDA_HOME/lib64/stubs -lcuda

#include <cuda.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#define CU_OK(expr, what)                                                              \
    do {                                                                               \
        CUresult _r = (expr);                                                          \
        if (_r != CUDA_SUCCESS) {                                                      \
            const char *_es = nullptr; cuGetErrorString(_r, &_es);                     \
            std::cerr << "CUDA error " << _r << " (" << (_es ? _es : "?")              \
                      << ") at " << what << "\n";                                      \
            return 2;                                                                  \
        }                                                                              \
    } while (0)

struct Buffer {
    int id = -1;
    std::string name, elem, init, fill_hex;
    uint64_t count = 0;
    std::string count_expr;          // @groups[*k], resolved once the grid is known (endeavour 181)
    bool readback = false;
    CUdeviceptr dev = 0;
    std::vector<uint8_t> fill;       // one element's bytes
    std::vector<uint8_t> pattern;    // `count` copies of fill, for the per-launch H2D
};

struct Slot {
    std::string kind;                // slm | u64 | ptr
    uint64_t value = 0;
    std::string expr;                // @groups[*k], resolved once the grid is known (endeavour 181)
};

// "@groups" or "@groups*<k>" -> GROUPS (x k) in OUT.  False if E is not of that form.
static bool resolve_groups_expr(const std::string &e, uint64_t groups, uint64_t &out) {
    if (e.rfind("@groups", 0) != 0) return false;
    const std::string rest = e.substr(7);
    uint64_t k = 1;
    if (!rest.empty()) {
        if (rest[0] != '*') return false;
        k = std::stoull(rest.substr(1));
    }
    out = groups * k;
    return true;
}

static size_t elem_bytes(const std::string &e) {
    if (e == "f64" || e == "i64" || e == "u64") return 8;
    if (e == "f32" || e == "i32" || e == "u32") return 4;
    if (e == "f16" || e == "bf16" || e == "i16" || e == "u16") return 2;
    if (e == "i8" || e == "u8") return 1;
    return 0;
}

static std::vector<uint8_t> unhex(const std::string &h) {
    std::vector<uint8_t> out;
    for (size_t i = 0; i + 1 < h.size(); i += 2) out.push_back((uint8_t)std::stoul(h.substr(i, 2), nullptr, 16));
    return out;
}

static std::map<std::string, std::string> kv(std::istringstream &in) {
    std::map<std::string, std::string> m;
    std::string tok;
    while (in >> tok) {
        auto eq = tok.find('=');
        if (eq != std::string::npos) m[tok.substr(0, eq)] = tok.substr(eq + 1);
    }
    return m;
}

static float half_to_float(uint16_t h) {
    const uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, f = h & 0x3ff;
    float v;
    if (e == 0) v = std::ldexp((float)f, -24);
    else if (e == 31) v = f ? std::numeric_limits<float>::quiet_NaN() : std::numeric_limits<float>::infinity();
    else v = std::ldexp((float)(f | 0x400), (int)e - 25);
    return s ? -v : v;
}

// Identical to the L0 fixture's: the host statistics and the device data must agree.
static inline uint32_t gen_bits(uint64_t i, uint32_t seed, int shift) {
    return ((uint32_t)i * 2654435761u + seed * 0x9E3779B9u) >> shift;
}

static void encode(const std::string &e, double v, uint8_t *dst) {
    if (e == "f32") { float x = (float)v; std::memcpy(dst, &x, 4); }
    else if (e == "f64") { std::memcpy(dst, &v, 8); }
    else if (e == "i32") { int32_t x = (int32_t)v; std::memcpy(dst, &x, 4); }
    else if (e == "u32") { uint32_t x = (uint32_t)v; std::memcpy(dst, &x, 4); }
    else if (e == "i64") { int64_t x = (int64_t)v; std::memcpy(dst, &x, 8); }
    else if (e == "u64") { uint64_t x = (uint64_t)v; std::memcpy(dst, &x, 8); }
    else if (e == "bf16") { float x = (float)v; uint32_t b; std::memcpy(&b, &x, 4); uint16_t h = (uint16_t)(b >> 16); std::memcpy(dst, &h, 2); }
    else { std::memset(dst, 0, elem_bytes(e)); }
}

static std::string decode(const std::string &e, const uint8_t *p) {
    char buf[64];
    if (e == "f32") { float x; std::memcpy(&x, p, 4); std::snprintf(buf, sizeof buf, "%.9g", x); }
    else if (e == "f64") { double x; std::memcpy(&x, p, 8); std::snprintf(buf, sizeof buf, "%.17g", x); }
    else if (e == "i32") { int32_t x; std::memcpy(&x, p, 4); std::snprintf(buf, sizeof buf, "%d", x); }
    else if (e == "u32") { uint32_t x; std::memcpy(&x, p, 4); std::snprintf(buf, sizeof buf, "%u", x); }
    else if (e == "i64") { long long x; std::memcpy(&x, p, 8); std::snprintf(buf, sizeof buf, "%lld", x); }
    else if (e == "u64") { unsigned long long x; std::memcpy(&x, p, 8); std::snprintf(buf, sizeof buf, "%llu", x); }
    else if (e == "f16") { uint16_t h; std::memcpy(&h, p, 2); std::snprintf(buf, sizeof buf, "%.6g", half_to_float(h)); }
    else if (e == "bf16") { uint16_t h; std::memcpy(&h, p, 2); uint32_t b = (uint32_t)h << 16; float x; std::memcpy(&x, &b, 4); std::snprintf(buf, sizeof buf, "%.6g", x); }
    else std::snprintf(buf, sizeof buf, "?");
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: " << argv[0] << " <plan> <results> [--skip-each-fill] [--dirty-once-before-relaunch]\n";
        return 1;
    }
    bool skip_each_fill = false, dirty_once = false;
    for (int i = 3; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--skip-each-fill")) skip_each_fill = true;
        else if (!std::strcmp(argv[i], "--dirty-once-before-relaunch")) dirty_once = true;
        else { std::cerr << "unknown option " << argv[i] << "\n"; return 1; }
    }

    // ---- plan (same format as the L0 fixture; `module` and `spv` are synonyms) ---------------
    std::string module_path, kname, groups_spec = "eu", generator = "hash";
    uint32_t local[3] = {1, 1, 1};
    int warmup = 3, iters = 20, shift = 29;
    std::vector<Buffer> buffers;
    std::map<int, Slot> slots;
    {
        std::ifstream pf(argv[1]);
        if (!pf) { std::cerr << "cannot open plan " << argv[1] << "\n"; return 1; }
        std::string line;
        while (std::getline(pf, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            std::istringstream in(line);
            std::string word;
            in >> word;
            if (word == "module" || word == "spv") { std::getline(in >> std::ws, module_path); }
            else if (word == "kernel") in >> kname;
            else if (word == "local") in >> local[0] >> local[1] >> local[2];
            else if (word == "groups") std::getline(in >> std::ws, groups_spec);
            else if (word == "warmup") in >> warmup;
            else if (word == "iters") in >> iters;
            else if (word == "buildflags") { std::string ignored; std::getline(in, ignored); }
            else if (word == "generator") {
                in >> generator;
                auto m = kv(in);
                if (m.count("shift")) shift = std::stoi(m["shift"]);
            } else if (word == "buffer") {
                Buffer b;
                in >> b.id;
                auto m = kv(in);
                b.name = m["name"]; b.elem = m["elem"]; b.init = m["init"];
                if (!m["count"].empty() && m["count"][0] == '@') b.count_expr = m["count"];
                else b.count = std::stoull(m["count"]);
                b.fill_hex = m.count("fill") ? m["fill"] : "";
                b.readback = m.count("readback") && m["readback"] == "1";
                b.fill = unhex(b.fill_hex);
                if (!elem_bytes(b.elem)) { std::cerr << "buffer " << b.name << ": unknown elem " << b.elem << "\n"; return 1; }
                if (!b.fill.empty() && b.fill.size() != elem_bytes(b.elem)) {
                    std::cerr << "buffer " << b.name << ": fill size mismatch\n"; return 1;
                }
                if ((int)buffers.size() != b.id) { std::cerr << "buffer ids must be dense and ordered\n"; return 1; }
                buffers.push_back(b);
            } else if (word == "slot") {
                int i; Slot s;
                std::string v;
                in >> i >> s.kind >> v;
                if (!v.empty() && v[0] == '@') s.expr = v;
                else s.value = std::stoull(v);
                slots[i] = s;
            } else { std::cerr << "plan: unknown directive '" << word << "'\n"; return 1; }
        }
    }
    if (module_path.empty() || kname.empty()) { std::cerr << "plan needs module and kernel\n"; return 1; }
    if (generator != "hash") { std::cerr << "unknown generator " << generator << "\n"; return 1; }
    iters = std::max(1, iters);
    for (int i = 0; i < (int)slots.size(); ++i)
        if (!slots.count(i)) { std::cerr << "plan: slot " << i << " missing\n"; return 1; }

    std::ofstream res(argv[2]);
    if (!res) { std::cerr << "cannot open results " << argv[2] << "\n"; return 1; }

    std::string ptx;
    {
        std::ifstream f(module_path, std::ios::binary);
        if (!f) { std::cerr << "cannot open " << module_path << "\n"; return 1; }
        ptx.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }

    // ---- device, context, module -------------------------------------------------------------
    CU_OK(cuInit(0), "cuInit");
    CUdevice dev; CU_OK(cuDeviceGet(&dev, 0), "cuDeviceGet");
    char dname[256] = {0};
    cuDeviceGetName(dname, sizeof dname, dev);
    int sms = 0;
    CU_OK(cuDeviceGetAttribute(&sms, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, dev), "SM count");
    res << "device " << dname << "\n" << "eus " << sms << "\n";

    CUcontext ctx; CU_OK(cuDevicePrimaryCtxRetain(&ctx, dev), "cuDevicePrimaryCtxRetain");
    CU_OK(cuCtxSetCurrent(ctx), "cuCtxSetCurrent");
    CUmodule module_;
    const auto jit0 = std::chrono::steady_clock::now();
    CU_OK(cuModuleLoadData(&module_, ptx.c_str()), "cuModuleLoadData (PTX JIT)");
    const double jit_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - jit0).count();
    res << "jit_ms " << jit_ms << "\n";
    CUfunction kernel; CU_OK(cuModuleGetFunction(&kernel, module_, kname.c_str()), "cuModuleGetFunction");

    // ---- dynamic shared size FIRST: the occupancy query below needs it.  Endeavour 181 moved the grid
    //      ahead of the buffers, so a buffer (a last-man kernel's partials) may be sized by the group count.
    std::vector<unsigned long long> values(slots.size(), 0);
    std::vector<void *> params(slots.size(), nullptr);
    size_t shared_bytes = 0;
    for (auto &kvs : slots)
        if (kvs.second.kind == "slm") {
            const size_t off = 16 * ((shared_bytes + 15) / 16);
            values[kvs.first] = off;
            shared_bytes = off + (size_t)kvs.second.value;
        }
    if (shared_bytes > 48 * 1024)
        CU_OK(cuFuncSetAttribute(kernel, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, (int)shared_bytes),
              "dynamic shared size");

    // ---- grid size: a fixed count, SM-relative, or the CUDA hoist's occupancy formula --------
    // occupancy R: cuOccupancyMaxActiveBlocksPerMultiprocessor (this kernel, this block size, this
    // dynamic shared size) x SMs (or the profile's :compute-units, cu=) x R; then capped at cap=.
    uint32_t groups = 0, max_resident = 0;
    {
        std::istringstream gs(groups_spec);
        std::string mode;
        gs >> mode;
        if (mode == "occupancy") {
            double ratio = 1.0;
            gs >> ratio;
            auto m = kv(gs);
            int per_sm = 0;
            CU_OK(cuOccupancyMaxActiveBlocksPerMultiprocessor(&per_sm, kernel,
                      (int)(local[0] * local[1] * local[2]), shared_bytes), "occupancy query");
            const uint64_t units = m.count("cu") ? std::stoull(m["cu"]) : (uint64_t)sms;
            max_resident = (uint32_t)(per_sm * units);
            double g = (double)max_resident * ratio;
            groups = g < 1.0 ? 1u : (uint32_t)g;
            if (m.count("cap") && groups > std::stoul(m["cap"])) groups = (uint32_t)std::stoul(m["cap"]);
        } else if (mode == "eu") groups = (uint32_t)sms;
        else if (mode.rfind("eu*", 0) == 0) groups = (uint32_t)sms * (uint32_t)std::stoul(mode.substr(3));
        else groups = (uint32_t)std::stoul(mode);
    }
    res << "groups " << groups << "\n" << "max_resident " << max_resident << "\n";

    // ---- symbolic sizes, now that the grid is known (endeavour 181) ---------------------------
    for (auto &b : buffers)
        if (!b.count_expr.empty() && !resolve_groups_expr(b.count_expr, groups, b.count)) {
            std::cerr << "buffer " << b.name << ": bad count " << b.count_expr << "\n"; return 1;
        }
    for (auto &kvs : slots)
        if (!kvs.second.expr.empty() && !resolve_groups_expr(kvs.second.expr, groups, kvs.second.value)) {
            std::cerr << "slot " << kvs.first << ": bad value " << kvs.second.expr << "\n"; return 1;
        }

    // ---- buffers -------------------------------------------------------------------------------
    for (auto &b : buffers) {
        const size_t eb = elem_bytes(b.elem);
        CU_OK(cuMemAlloc(&b.dev, std::max<size_t>(b.count * eb, 4)), ("cuMemAlloc " + b.name).c_str());
        if (!b.fill.empty()) {
            b.pattern.resize(b.count * eb);
            for (uint64_t j = 0; j < b.count; ++j) std::memcpy(b.pattern.data() + j * eb, b.fill.data(), eb);
        }
    }
    const size_t chunk_bytes = 64ull << 20;
    void *staging = nullptr;
    CU_OK(cuMemAllocHost(&staging, chunk_bytes), "cuMemAllocHost staging");

    auto generate = [&](uint32_t seed, const char *tag) -> int {
        for (auto &b : buffers) {
            if (b.init != "gen") continue;
            const size_t eb = elem_bytes(b.elem);
            const uint64_t per_chunk = chunk_bytes / eb;
            double sum = 0, sumsq = 0, mn = INFINITY, mx = -INFINITY;
            uint64_t argmin = 0, argmax = 0;
            for (uint64_t base = 0; base < b.count; base += per_chunk) {
                const uint64_t n = std::min<uint64_t>(per_chunk, b.count - base);
                uint8_t *dst = (uint8_t *)staging;
                for (uint64_t j = 0; j < n; ++j) {
                    const double v = (double)gen_bits(base + j, seed, shift);
                    encode(b.elem, v, dst + j * eb);
                    sum += v; sumsq += v * v;
                    if (v < mn) { mn = v; argmin = base + j; }
                    if (v > mx) { mx = v; argmax = base + j; }
                }
                CU_OK(cuMemcpyHtoD(b.dev + base * eb, staging, n * eb), "input H2D");
            }
            char line[512];
            std::snprintf(line, sizeof line,
                          "stats %s %s count=%llu sum=%.17g sumsq=%.17g min=%.17g argmin=%llu max=%.17g argmax=%llu\n",
                          tag, b.name.c_str(), (unsigned long long)b.count, sum, sumsq, mn,
                          (unsigned long long)argmin, mx, (unsigned long long)argmax);
            res << line;
        }
        return 0;
    };
    auto fill_once = [&](unsigned char byte) -> int {
        for (auto &b : buffers)
            if (b.init == "once-zero")
                CU_OK(cuMemsetD8(b.dev, byte, b.count * elem_bytes(b.elem)), ("once fill " + b.name).c_str());
        return 0;
    };

    if (generate(1, "A")) return 2;
    if (fill_once(0)) return 2;

    // ---- arguments: every slot is 8 bytes (pointer, u64, or a shared-memory byte offset) --------
    for (auto &kvs : slots) {
        const int i = kvs.first;
        const Slot &s = kvs.second;
        if (s.kind == "slm") {
            // offset assigned above, with the dynamic shared size
        } else if (s.kind == "u64") {
            values[i] = s.value;
        } else if (s.kind == "ptr") {
            if (s.value >= buffers.size()) { std::cerr << "slot " << i << ": no buffer " << s.value << "\n"; return 1; }
            values[i] = (unsigned long long)buffers[s.value].dev;
        } else { std::cerr << "slot " << i << ": unknown kind " << s.kind << "\n"; return 1; }
        params[i] = &values[i];
    }

    CUevent ev0, ev1;
    CU_OK(cuEventCreate(&ev0, CU_EVENT_DEFAULT), "eventCreate");
    CU_OK(cuEventCreate(&ev1, CU_EVENT_DEFAULT), "eventCreate");

    auto launch = [&](double *us_out) -> int {
        if (!skip_each_fill)
            for (auto &b : buffers)
                if ((b.init == "each-fill" || b.init == "each-poison") && !b.pattern.empty())
                    CU_OK(cuMemcpyHtoDAsync(b.dev, b.pattern.data(), b.pattern.size(), 0), "per-launch fill");
        CU_OK(cuEventRecord(ev0, 0), "record start");
        CU_OK(cuLaunchKernel(kernel, groups, 1, 1, local[0], local[1], local[2],
                             (unsigned)shared_bytes, 0, params.data(), nullptr), "cuLaunchKernel");
        CU_OK(cuEventRecord(ev1, 0), "record stop");
        CU_OK(cuEventSynchronize(ev1), "event sync");
        CU_OK(cuCtxSynchronize(), "ctx sync");
        if (us_out) {
            float ms = 0;
            CU_OK(cuEventElapsedTime(&ms, ev0, ev1), "elapsed");
            *us_out = (double)ms * 1000.0;
        }
        return 0;
    };
    auto readback = [&](const char *tag) -> int {
        for (auto &b : buffers) {
            if (!b.readback) continue;
            const size_t eb = elem_bytes(b.elem);
            std::vector<uint8_t> host(b.count * eb);
            CU_OK(cuMemcpyDtoH(host.data(), b.dev, host.size()), "readback");
            res << "out " << tag << " " << b.name << " " << b.elem;
            for (uint64_t j = 0; j < b.count; ++j) res << " " << decode(b.elem, host.data() + j * eb);
            res << "\n";
        }
        return 0;
    };

    for (int i = 0; i < warmup; ++i)
        if (launch(nullptr)) return 2;
    std::vector<double> us(iters);
    const auto wall0 = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i)
        if (launch(&us[i])) return 2;
    const double wall_us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - wall0).count() / iters;
    res << "time_us";
    for (double u : us) res << " " << u;
    res << "\nwall_us " << wall_us << "\n";
    if (readback("A")) return 2;

    if (generate(2, "B")) return 2;
    if (dirty_once && fill_once(1)) return 2;
    if (launch(nullptr)) return 2;
    if (readback("B")) return 2;

    res.close();
    for (auto &b : buffers) cuMemFree(b.dev);
    cuMemFreeHost(staging);
    cuEventDestroy(ev0);
    cuEventDestroy(ev1);
    cuModuleUnload(module_);
    cuDevicePrimaryCtxRelease(dev);
    return 0;
}
