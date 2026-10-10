// reduce_fixture_l0.cpp -- ONE Level Zero fixture for every Crisp reduction benchmark.
//
// It knows nothing about any kernel.  scripts/crisp_bench/metacrisp.py reads the kernel's
// .metacrisp and writes an ARGUMENT PLAN: which physical argument slot holds what, which device
// buffers exist, how big they are, and what each must contain -- once, or before every launch.
// This program carries the plan out, times the kernel, and reports what came back.  A difference
// between two benchmark rows is then a difference between two kernels, never two harnesses (the
// lesson of benchmarks/matmul/crisp/bench_harness_l0.cpp, whose header tells the story).
//
// USAGE
//   reduce_fixture_l0 <plan-file> <results-file> [--skip-each-fill] [--dirty-once-before-relaunch]
//
//   --skip-each-fill              do NOT re-initialise outputs before each launch (stale-state demo:
//                                 an :atomic output then accumulates across launches)
//   --dirty-once-before-relaunch  before the relaunch, write 0x01 bytes into the zero-once scratch
//                                 (stale-state demo: a last-man counter that is not zero elects nobody)
//
// PLAN (one directive per line; '#' starts a comment line)
//   module <path>                   the kernel module (.spv here; "spv" accepted as a synonym)
//   kernel <name>                   entry point
//   local <x> <y> <z>               work-group size
//   groups <n> | eu | eu*<k> | occupancy <R> [cap=<n>] [cu=<n>]
//                                   number of work-groups (1-D).  eu = the device's EU count.
//                                   occupancy: the L0 hoist's :strided formula, exactly --
//                                   hw_threads (cu = profile :compute-units replaces the queried
//                                   Xe-core count) halved on register spill, x R, divided by
//                                   ceil(local / physicalEUSimdWidth); then capped at <cap>.
//   warmup <n> / iters <n>
//   generator hash shift=<s>        input element i = ((i*2654435761 + seed*0x9E3779B9) mod 2^32) >> s
//   buildflags <flags...>           zeModuleCreate build flags (optional)
//   buffer <id> name=<n> elem=<f32|f64|i32|u32|i64|u64|f16|bf16|...> count=<n> init=<how>
//          [fill=<hex>] [readback=1]
//       init=gen          generated input; regenerated with a new seed for the relaunch
//       init=once-zero    zeroed once, before the first launch (implicit global scratch)
//       init=each-fill    filled with <fill> (one element, little-endian hex) before EVERY launch
//       init=each-poison  same mechanism; <fill> is a poison value (NaN / all-ones), so an output the
//                         kernel never wrote is visible
//   slot <i> slm <bytes>            local-memory argument
//   slot <i> u64 <value>            8-byte integer argument
//   slot <i> ptr <buffer-id>        device pointer argument
//
//   SYMBOLIC SIZES (endeavour 181).  A buffer's count= and a u64 slot's value may be @groups or
//   @groups*<k>: the number of work-groups computed below (x k).  A last-man kernel's partials buffer
//   has one element per work-group, and under `occupancy` only this fixture knows that number.
//
// PROTOCOL
//   1. generate inputs (seed 1) on the host in chunks, copy to the device; record their statistics
//   2. warmup launches, then <iters> timed launches.  Each launch is ONE command list: the per-launch
//      fills, a barrier, then the kernel carrying the timestamp event -- so the kernel time excludes
//      the fills.  Queue AND event are synchronised after every launch (either alone has been seen
//      to return early on Intel WSL2 builds; see the matmul fixture).
//   3. read back the outputs of the LAST timed launch                                -> "out A"
//   4. RELAUNCH: regenerate inputs with seed 2 and launch once more                   -> "out B"
//      A kernel that leaves state behind gets B wrong even when it got A right.
//
// RESULTS (text, one fact per line)
//   device <name> | eus <n> | jit_ms <ms> | groups <n> | time_us <v>... | wall_us <v>
//   stats <A|B> <buffer> count= sum= sumsq= min= argmin= max= argmax=      (double precision)
//   out <A|B> <buffer> <elem> <value>...

#if __has_include(<level_zero/ze_api.h>)
#include <level_zero/ze_api.h>
#else
#include <ze_api.h>
#endif
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

#define ZE_OK(expr, what)                                                             \
    do {                                                                              \
        ze_result_t _r = (expr);                                                      \
        if (_r != ZE_RESULT_SUCCESS) {                                                \
            std::cerr << "L0 error 0x" << std::hex << _r << std::dec << " at " << what << "\n"; \
            return 2;                                                                 \
        }                                                                             \
    } while (0)

struct Buffer {
    int id = -1;
    std::string name, elem, init, fill_hex;
    uint64_t count = 0;
    std::string count_expr;      // @groups[*k], resolved once the grid is known (endeavour 181)
    bool readback = false;
    void *dev = nullptr;
    std::vector<uint8_t> fill;   // one element's bytes
};

struct Slot {
    std::string kind;            // slm | u64 | ptr
    uint64_t value = 0;
    std::string expr;            // @groups[*k], resolved once the grid is known (endeavour 181)
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

// The generator, as one function so the host statistics and the device data cannot disagree.
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

    // ---- plan ------------------------------------------------------------------------------
    std::string spv_path, kname, groups_spec = "eu", build_flags, generator = "hash";
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
            if (word == "module" || word == "spv") { std::getline(in >> std::ws, spv_path); }
            else if (word == "kernel") in >> kname;
            else if (word == "local") in >> local[0] >> local[1] >> local[2];
            else if (word == "groups") std::getline(in >> std::ws, groups_spec);
            else if (word == "warmup") in >> warmup;
            else if (word == "iters") in >> iters;
            else if (word == "buildflags") std::getline(in >> std::ws, build_flags);
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
                    std::cerr << "buffer " << b.name << ": fill is " << b.fill.size() << " bytes, element is "
                              << elem_bytes(b.elem) << "\n";
                    return 1;
                }
                if ((int)buffers.size() != b.id) { std::cerr << "buffer ids must be dense and ordered\n"; return 1; }
                buffers.push_back(b);
            } else if (word == "slot") {
                int i; Slot s; std::string v;
                in >> i >> s.kind >> v;
                if (!v.empty() && v[0] == '@') s.expr = v;
                else s.value = std::stoull(v);
                slots[i] = s;
            } else { std::cerr << "plan: unknown directive '" << word << "'\n"; return 1; }
        }
    }
    if (spv_path.empty() || kname.empty()) { std::cerr << "plan needs spv and kernel\n"; return 1; }
    if (generator != "hash") { std::cerr << "unknown generator " << generator << "\n"; return 1; }
    iters = std::max(1, iters);
    for (int i = 0; i < (int)slots.size(); ++i)
        if (!slots.count(i)) { std::cerr << "plan: slot " << i << " missing\n"; return 1; }

    std::ofstream res(argv[2]);
    if (!res) { std::cerr << "cannot open results " << argv[2] << "\n"; return 1; }

    // ---- SPIR-V, driver, device --------------------------------------------------------------
    std::vector<uint8_t> spv;
    {
        std::ifstream f(spv_path, std::ios::binary);
        if (!f) { std::cerr << "cannot open " << spv_path << "\n"; return 1; }
        spv.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    ZE_OK(zeInit(0), "zeInit");
    uint32_t nd = 0;
    ZE_OK(zeDriverGet(&nd, nullptr), "zeDriverGet");
    std::vector<ze_driver_handle_t> drivers(nd);
    ZE_OK(zeDriverGet(&nd, drivers.data()), "zeDriverGet2");
    ze_driver_handle_t driver = nullptr;
    ze_device_handle_t device = nullptr;
    ze_device_properties_t dprops{ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
    for (auto d : drivers) {
        uint32_t ndev = 0;
        if (zeDeviceGet(d, &ndev, nullptr) != ZE_RESULT_SUCCESS || !ndev) continue;
        std::vector<ze_device_handle_t> devs(ndev);
        zeDeviceGet(d, &ndev, devs.data());
        for (auto dev : devs) {
            ze_device_properties_t p{ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
            if (zeDeviceGetProperties(dev, &p) == ZE_RESULT_SUCCESS && p.type == ZE_DEVICE_TYPE_GPU) {
                driver = d; device = dev; dprops = p; break;
            }
        }
        if (device) break;
    }
    if (!device) { std::cerr << "no GPU device\n"; return 2; }
    const uint32_t eus = dprops.numSlices * dprops.numSubslicesPerSlice * dprops.numEUsPerSubslice;
    res << "device " << dprops.name << "\n" << "eus " << eus << "\n";

    ze_context_desc_t cdesc{ZE_STRUCTURE_TYPE_CONTEXT_DESC};
    ze_context_handle_t ctx;
    ZE_OK(zeContextCreate(driver, &cdesc, &ctx), "contextCreate");

    // ---- module + kernel (the driver JIT is timed: it is the device-side compile) -------------
    ze_module_desc_t mdesc{ZE_STRUCTURE_TYPE_MODULE_DESC};
    mdesc.format = ZE_MODULE_FORMAT_IL_SPIRV;
    mdesc.inputSize = spv.size();
    mdesc.pInputModule = spv.data();
    mdesc.pBuildFlags = build_flags.c_str();
    ze_module_handle_t module_;
    ze_module_build_log_handle_t blog = nullptr;
    const auto jit0 = std::chrono::steady_clock::now();
    const ze_result_t mrc = zeModuleCreate(ctx, device, &mdesc, &module_, &blog);
    const double jit_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - jit0).count();
    if (mrc != ZE_RESULT_SUCCESS) {
        size_t n = 0;
        zeModuleBuildLogGetString(blog, &n, nullptr);
        std::string log(n, '\0');
        zeModuleBuildLogGetString(blog, &n, &log[0]);
        std::cerr << "zeModuleCreate failed 0x" << std::hex << mrc << std::dec << "\n" << log << "\n";
        return 2;
    }
    if (blog) zeModuleBuildLogDestroy(blog);
    res << "jit_ms " << jit_ms << "\n";
    ze_kernel_desc_t kdesc{ZE_STRUCTURE_TYPE_KERNEL_DESC};
    kdesc.pKernelName = kname.c_str();
    ze_kernel_handle_t kernel;
    ZE_OK(zeKernelCreate(module_, &kdesc, &kernel), "kernelCreate");
    ZE_OK(zeKernelSetGroupSize(kernel, local[0], local[1], local[2]), "setGroupSize");

    // ---- grid size: a fixed count, eu-relative, or the L0 hoist's occupancy formula ----------
    uint32_t groups = 0, max_resident = 0;
    {
        std::istringstream gs(groups_spec);
        std::string mode;
        gs >> mode;
        if (mode == "occupancy") {
            double ratio = 1.0;
            gs >> ratio;
            auto m = kv(gs);
            const uint64_t cores = m.count("cu") ? std::stoull(m["cu"])
                                                 : (uint64_t)dprops.numSlices * dprops.numSubslicesPerSlice;
            uint64_t hw = cores * dprops.numEUsPerSubslice * dprops.numThreadsPerEU;
            ze_kernel_properties_t kp{ZE_STRUCTURE_TYPE_KERNEL_PROPERTIES};
            if (zeKernelGetProperties(kernel, &kp) == ZE_RESULT_SUCCESS && kp.spillMemSize > 0) hw /= 2;
            const uint32_t simd = dprops.physicalEUSimdWidth ? dprops.physicalEUSimdWidth : 16;
            uint32_t tpg = (local[0] * local[1] * local[2] + simd - 1) / simd;
            if (tpg < 1) tpg = 1;
            max_resident = (uint32_t)(hw / tpg);
            uint64_t scaled = (uint64_t)((double)hw * ratio);
            if (scaled < 1) scaled = 1;
            groups = (uint32_t)(scaled / tpg);
            if (groups < 1) groups = 1;
            if (m.count("cap") && groups > std::stoul(m["cap"])) groups = (uint32_t)std::stoul(m["cap"]);
        } else if (mode == "eu") groups = eus;
        else if (mode.rfind("eu*", 0) == 0) groups = eus * (uint32_t)std::stoul(mode.substr(3));
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

    // ---- queue, event, timer ------------------------------------------------------------------
    ze_command_queue_desc_t qd{ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC};
    qd.mode = ZE_COMMAND_QUEUE_MODE_ASYNCHRONOUS;
    ze_command_queue_handle_t queue;
    ZE_OK(zeCommandQueueCreate(ctx, device, &qd, &queue), "queueCreate");
    ze_event_pool_desc_t epd{ZE_STRUCTURE_TYPE_EVENT_POOL_DESC};
    epd.flags = ZE_EVENT_POOL_FLAG_KERNEL_TIMESTAMP;
    epd.count = 1;
    ze_event_pool_handle_t epool;
    ZE_OK(zeEventPoolCreate(ctx, &epd, 1, &device, &epool), "eventPool");
    ze_event_desc_t ed{ZE_STRUCTURE_TYPE_EVENT_DESC};
    ed.index = 0;
    ed.signal = ZE_EVENT_SCOPE_FLAG_HOST;
    ze_event_handle_t ev;
    ZE_OK(zeEventCreate(epool, &ed, &ev), "event");
    // timerResolution is ns/tick on older drivers and Hz on newer ones (see the matmul fixture: a
    // ~15x error that looked exactly like a slow kernel).  Kernel timestamps wrap at validBits.
    const uint64_t timer_res = dprops.timerResolution;
    const bool timer_in_hz = (timer_res > 1000000ULL);
    const uint32_t valid_bits = dprops.kernelTimestampValidBits;
    const uint64_t clock_mask = (valid_bits >= 64) ? ~0ULL : ((1ULL << valid_bits) - 1ULL);

    ze_command_list_desc_t cld{ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC};
    auto run_list = [&](const std::function<bool(ze_command_list_handle_t)> &fill) -> bool {
        ze_command_list_handle_t cl;
        if (zeCommandListCreate(ctx, device, &cld, &cl) != ZE_RESULT_SUCCESS) return false;
        bool ok = fill(cl) && zeCommandListClose(cl) == ZE_RESULT_SUCCESS &&
                  zeCommandQueueExecuteCommandLists(queue, 1, &cl, nullptr) == ZE_RESULT_SUCCESS &&
                  zeCommandQueueSynchronize(queue, UINT64_MAX) == ZE_RESULT_SUCCESS;
        zeCommandListDestroy(cl);
        return ok;
    };

    // ---- buffers ------------------------------------------------------------------------------
    ze_device_mem_alloc_desc_t dmem{ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC};
    ze_relaxed_allocation_limits_exp_desc_t relaxed{ZE_STRUCTURE_TYPE_RELAXED_ALLOCATION_LIMITS_EXP_DESC};
    relaxed.flags = ZE_RELAXED_ALLOCATION_LIMITS_EXP_FLAG_MAX_SIZE;
    for (auto &b : buffers) {
        const size_t bytes = std::max<size_t>(b.count * elem_bytes(b.elem), 4);
        dmem.pNext = (bytes > dprops.maxMemAllocSize) ? &relaxed : nullptr;
        ZE_OK(zeMemAllocDevice(ctx, &dmem, bytes, 64, device, &b.dev), ("alloc " + b.name).c_str());
    }

    // Host staging for generated inputs, in chunks: a multi-GB input never needs a multi-GB host copy.
    const size_t chunk_bytes = 64ull << 20;
    ze_host_mem_alloc_desc_t hmem{ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC};
    void *staging = nullptr;
    ZE_OK(zeMemAllocHost(ctx, &hmem, chunk_bytes, 64, &staging), "allocStaging");

    auto generate = [&](uint32_t seed, const char *tag) -> bool {
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
                if (!run_list([&](ze_command_list_handle_t cl) {
                        return zeCommandListAppendMemoryCopy(cl, (uint8_t *)b.dev + base * eb, staging, n * eb,
                                                             nullptr, 0, nullptr) == ZE_RESULT_SUCCESS;
                    })) { std::cerr << "input copy failed for " << b.name << "\n"; return false; }
            }
            char line[512];
            std::snprintf(line, sizeof line,
                          "stats %s %s count=%llu sum=%.17g sumsq=%.17g min=%.17g argmin=%llu max=%.17g argmax=%llu\n",
                          tag, b.name.c_str(), (unsigned long long)b.count, sum, sumsq, mn,
                          (unsigned long long)argmin, mx, (unsigned long long)argmax);
            res << line;
        }
        return true;
    };

    auto fill_buffers = [&](ze_command_list_handle_t cl, bool once, uint8_t once_byte) -> bool {
        for (auto &b : buffers) {
            const size_t eb = elem_bytes(b.elem);
            if (once && b.init == "once-zero") {
                if (zeCommandListAppendMemoryFill(cl, b.dev, &once_byte, 1, b.count * eb, nullptr, 0, nullptr)
                    != ZE_RESULT_SUCCESS) return false;
            } else if (!once && (b.init == "each-fill" || b.init == "each-poison")) {
                if (zeCommandListAppendMemoryFill(cl, b.dev, b.fill.data(), eb, b.count * eb, nullptr, 0, nullptr)
                    != ZE_RESULT_SUCCESS) return false;
            }
        }
        return true;
    };

    if (!generate(1, "A")) return 2;
    if (!run_list([&](ze_command_list_handle_t cl) { return fill_buffers(cl, true, 0); })) {
        std::cerr << "zero-once fill failed\n"; return 2;
    }

    // ---- arguments ----------------------------------------------------------------------------
    for (auto &kvs : slots) {
        const int i = kvs.first;
        const Slot &s = kvs.second;
        if (s.kind == "slm") {
            ZE_OK(zeKernelSetArgumentValue(kernel, i, (size_t)s.value, nullptr), "setArg slm");
        } else if (s.kind == "u64") {
            uint64_t v = s.value;
            ZE_OK(zeKernelSetArgumentValue(kernel, i, sizeof v, &v), "setArg u64");
        } else if (s.kind == "ptr") {
            if (s.value >= buffers.size()) { std::cerr << "slot " << i << ": no buffer " << s.value << "\n"; return 1; }
            void *p = buffers[s.value].dev;
            ZE_OK(zeKernelSetArgumentValue(kernel, i, sizeof p, &p), "setArg ptr");
        } else { std::cerr << "slot " << i << ": unknown kind " << s.kind << "\n"; return 1; }
    }

    // ---- the launch: per-launch fills, barrier, kernel (timed) -------------------------------
    ze_group_count_t grid{groups, 1, 1};
    ze_command_list_handle_t cl_launch;
    ZE_OK(zeCommandListCreate(ctx, device, &cld, &cl_launch), "clLaunch");
    if (!skip_each_fill && !fill_buffers(cl_launch, false, 0)) { std::cerr << "per-launch fill failed\n"; return 2; }
    ZE_OK(zeCommandListAppendBarrier(cl_launch, nullptr, 0, nullptr), "barrier");
    ZE_OK(zeCommandListAppendLaunchKernel(cl_launch, kernel, &grid, ev, 0, nullptr), "appendLaunch");
    ZE_OK(zeCommandListClose(cl_launch), "closeLaunch");

    auto launch = [&](double *us_out) -> int {
        ZE_OK(zeEventHostReset(ev), "eventReset");
        ZE_OK(zeCommandQueueExecuteCommandLists(queue, 1, &cl_launch, nullptr), "execLaunch");
        ZE_OK(zeCommandQueueSynchronize(queue, UINT64_MAX), "syncLaunch");
        ZE_OK(zeEventHostSynchronize(ev, UINT64_MAX), "eventSync");
        if (us_out) {
            ze_kernel_timestamp_result_t ts{};
            ZE_OK(zeEventQueryKernelTimestamp(ev, &ts), "timestamp");
            const uint64_t s0 = ts.context.kernelStart & clock_mask;
            const uint64_t e0 = ts.context.kernelEnd & clock_mask;
            const uint64_t d = (e0 >= s0) ? (e0 - s0) : (clock_mask + 1 - s0 + e0);
            const double ns = timer_in_hz ? ((double)d * 1e9 / (double)timer_res) : ((double)d * (double)timer_res);
            *us_out = ns / 1000.0;
        }
        return 0;
    };

    auto readback = [&](const char *tag) -> bool {
        for (auto &b : buffers) {
            if (!b.readback) continue;
            const size_t eb = elem_bytes(b.elem);
            std::vector<uint8_t> host(b.count * eb);
            if (!run_list([&](ze_command_list_handle_t cl) {
                    return zeCommandListAppendMemoryCopy(cl, host.data(), b.dev, host.size(), nullptr, 0, nullptr)
                           == ZE_RESULT_SUCCESS;
                })) return false;
            res << "out " << tag << " " << b.name << " " << b.elem;
            for (uint64_t j = 0; j < b.count; ++j) res << " " << decode(b.elem, host.data() + j * eb);
            res << "\n";
        }
        return true;
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
    if (!readback("A")) { std::cerr << "readback A failed\n"; return 2; }

    // ---- relaunch on different data ------------------------------------------------------------
    if (!generate(2, "B")) return 2;
    if (dirty_once && !run_list([&](ze_command_list_handle_t cl) { return fill_buffers(cl, true, 1); })) {
        std::cerr << "dirty-once fill failed\n"; return 2;
    }
    if (launch(nullptr)) return 2;
    if (!readback("B")) { std::cerr << "readback B failed\n"; return 2; }

    res.close();
    zeCommandListDestroy(cl_launch);
    for (auto &b : buffers) zeMemFree(ctx, b.dev);
    zeMemFree(ctx, staging);
    zeEventDestroy(ev);
    zeEventPoolDestroy(epool);
    zeCommandQueueDestroy(queue);
    zeKernelDestroy(kernel);
    zeModuleDestroy(module_);
    zeContextDestroy(ctx);
    return 0;
}
