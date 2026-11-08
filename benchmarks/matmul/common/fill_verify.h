// benchmarks/matmul/common/fill_verify.h -- ONE fill + verify convention for every matmul harness.
//
// WHY.  The matmul harnesses were balkanized: the Crisp fixtures filled A = i%5, B = i%3 and checked a
// strided sample, while ~40 competitor harnesses filled A = B = 1 and scanned ALL of C for the value K.
// Both filled on the CPU and copied to the device, which is what capped the large sizes: measured
// 2026-09-13 on an H100, the CPU fill at N=77824 took 201 s of a 219 s setup.  The A = B = 1 check was
// also the weaker one -- every cell of C equals K, so a kernel that swaps rows or columns still passes.
//
// THE CONVENTION (every runtime implements the same formula; the device fill lives in that runtime's
// header, the host side lives here):
//
//     A[flat] = flat % 5          B[flat] = flat % 3
//
// where `flat` is the operand's own storage index.  The values 0..4 are exact in f32, f64, f16 and bf16,
// so the reference is an exact comparison rather than a tolerance argument, and there are no denormals,
// so the timed loop is unaffected by the change of values.
//
// VERIFICATION never reads A or B back.  It RECOMPUTES them from the formula, through each operand's
// strides, so it is correct for row-major and column-major harnesses alike (cuBLAS and oneMKL's
// column_major API lay C out differently from the Crisp fixtures).  It reads back only the ~64 sampled
// spans of C, never the whole matrix.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <vector>

namespace crisp_bench {

constexpr uint32_t FILL_MOD_A = 5;
constexpr uint32_t FILL_MOD_B = 3;

inline double fill_a(uint64_t flat) { return (double)(flat % FILL_MOD_A); }
inline double fill_b(uint64_t flat) { return (double)(flat % FILL_MOD_B); }

// fp64 KEEPS ITS PRECISION ORACLE.  The fp64 contenders used to fill with v = 1 + 2^-25 (see
// sec2_top_f64/f64_oracle.h): a value single precision cannot represent, so a library that quietly
// computes in fp32/tf32 is caught -- plain small integers would be exact in fp32 and hide it.  So an
// fp64 operand is filled with (flat % mod) * v, the expected product carries v^2, and the check runs at
// the oracle's relative tolerance.  Addressing coverage AND precision detection, one fill.
constexpr double FILL_F64_SCALE = 1.0 + 1.0 / 33554432.0;     // 1 + 2^-25, exactly
constexpr double FILL_F64_RTOL  = 1e-10;
constexpr double FILL_RTOL      = 1e-3;                        // f32 / tf32 / f16 / bf16

// ---- Endeavour 209: BLOCK-SCALED operands (NVFP4 / MXFP4 / MXFP8) -------------------------------
// The CODES follow the convention above: logical element `flat` holds flat % 5 (A) or flat % 3 (B).
// 0..4 are exact in e2m1 (fp4), e4m3 and e5m2, so nothing changes for the codes.
//
// THE SCALES MUST NOT BE 1.  A kernel that never applies its scales (or applies A's to B, or reads
// the 128x4 layout wrong) passes against unit scales.  So every scale is a power of two that VARIES
// with both its row and its K-block:
//
//     scale(r, kb) = 2 ^ ((r + 2*kb) % 3 - 1)          in {0.5, 1, 2}
//
// r is the row of the scaled matrix (M for A, N for B) and kb = k / vec.  Powers of two keep every
// product exact (codes <= 4 and 2, scales <= 2 each: |term| <= 32 in quarter steps), so the check
// stays the plain FILL_RTOL comparison.  The device writes these through the :blocked-128x4 layout;
// the host recomputes them from the formula -- which is what tests the layout.
#if defined(__CUDACC__)
#define CRISP_BENCH_HD __host__ __device__
#else
#define CRISP_BENCH_HD
#endif
CRISP_BENCH_HD inline int mf_scale_exp(uint64_t r, uint64_t kb) { return (int)((r + 2 * kb) % 3) - 1; }
inline double mf_scale(uint64_t r, uint64_t kb) { return std::ldexp(1.0, mf_scale_exp(r, kb)); }

// 16-bit operands are filled as RAW 16-bit PATTERNS, not by converting a float on the device.
// Storing a float into a half/bfloat16 tensor element in a Crisp kernel produced wrong values on
// 2026-09-13 (both widths; f32 was correct; plan/bugs.md BUG 059) -- so the host encodes the five fill values once and
// every runtime's device fill just writes the chosen pattern.  The values 0..4 are exact in both.
//   bf16: the top 16 bits of the IEEE f32.        f16: IEEE 754 binary16.
inline uint16_t pattern16_bf16(float v) {
    uint32_t b; std::memcpy(&b, &v, 4); return (uint16_t)(b >> 16);
}
inline uint16_t pattern16_f16(float v) {
    uint32_t x; std::memcpy(&x, &v, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    int32_t  exp  = (int32_t)((x >> 23) & 0xFF) - 127 + 15;
    uint32_t man  = x & 0x7FFFFFu;
    if (((x >> 23) & 0xFF) == 0 && man == 0) return (uint16_t)sign;   // +/-0
    if (exp <= 0)  return (uint16_t)sign;
    if (exp >= 31) return (uint16_t)(sign | 0x7C00u);
    return (uint16_t)(sign | ((uint32_t)exp << 10) | (man >> 13));
}
// Patterns for fill values 0..4, in the encoding named by `elem` ("bf16" or "f16").
inline void fill_patterns16(const char *elem, uint16_t out[5]) {
    const bool bf = elem[0] == 'b';
    for (int v = 0; v < 5; ++v) out[v] = bf ? pattern16_bf16((float)v) : pattern16_f16((float)v);
}

// flat storage index of logical element (i, j) = i * s0 + j * s1.
//   row-major M x N : { N, 1 }        column-major M x N : { 1, M }
struct Strides { uint64_t s0, s1; };

struct VerifyResult {
    bool     verified    = true;
    double   max_abs_err = 0.0;
    uint64_t checked     = 0;
    double   max_rel_err = 0.0;     // relative to the expected value at the worst cell
};

// Copy `count` elements of C starting at storage index `first` into `out` as doubles.  The harness
// supplies it, because only the harness knows its runtime and C's element width.
using ReadSpan = std::function<void(uint64_t first, uint64_t count, std::vector<double> &out)>;

// Endeavour 207 -- the REQUANTIZE oracle, as a POST for verify_sampled: s8 = sat8(rne(float(acc) * m)).
// The multiply is done in fp32 on purpose, because that is what the kernel does (Crisp's to-q and
// cuBLASLt's float alpha alike); the accumulator itself is exact below 2^24, which every size here is.
inline std::function<double(double)> requant_s8(float m) {
    return [m](double acc) {
        const float p = static_cast<float>(acc) * m;
        const float r = std::nearbyint(p);              // default rounding mode: nearest, ties to even
        return (double)std::max(-128.0f, std::min(127.0f, r));
    };
}

// DIAGNOSTIC K-STEP FILL (endeavour 209, F-209-4; benchmarking only, never in a canonical run).
// CRISP_BENCH_FILL_KSTEP="ks[:rowmul]" fills A[i][k] = (k / ks + 1) + rowmul * (i % 64) and B = 1
// (no fp64 precision scale), so a wrong C element's signed error DECODES: each A value read from the
// wrong place contributes (k-step it came from - k-step it should have) + rowmul * (row delta).
// On a 2-slot ring, -2 per element = stale data (read before the load landed), +2 = overwritten
// (released too early), +-1 = the other slot.  Only the Crisp CUDA fixture honors it (row-major A).
struct KstepFill { uint64_t ks = 0, rowmul = 0; };
inline KstepFill kstep_fill() {
    KstepFill f;
    const char *s = std::getenv("CRISP_BENCH_FILL_KSTEP");
    if (s && *s) {
        char *end = nullptr;
        f.ks = std::strtoull(s, &end, 10);
        if (end && *end == ':') f.rowmul = std::strtoull(end + 1, nullptr, 10);
    }
    return f;
}

// A strided ~64 x 64 sample over the WHOLE of C (M x N), C = scale * (A . B), A is M x K, B is K x N.
// Stops at the first mismatch, like the fixtures always have.
inline VerifyResult verify_sampled(uint64_t M, uint64_t N, uint64_t K,
                                   Strides a, Strides b, Strides c,
                                   const ReadSpan &read_span,
                                   double scale = 1.0, uint64_t smax = 64,
                                   const std::function<double(double)> &post = {},
                                   double rtol = FILL_RTOL,
                                   uint64_t mf_vec = 0) {        // 209: >0 = block-scaled, scales per mf_vec
    VerifyResult r;
    if (M == 0 || N == 0) return r;
    // DIAGNOSTIC MODE (endeavour 209, F-209-4; benchmarking only, never in a canonical run):
    // CRISP_BENCH_VERIFY_DIAG=1 checks EVERY element instead of a 64 x 64 sample, does not stop at the
    // first mismatch, and prints the mismatch count plus the first 32 positions to stderr -- where a
    // wrong kernel is wrong (a tile edge, one fragment, one K-step) is the evidence a race leaves.
    const bool diag = std::getenv("CRISP_BENCH_VERIFY_DIAG") != nullptr;
    uint64_t diag_bad = 0;
    if (diag) smax = std::max(M, N);
    const uint64_t si = std::max<uint64_t>(1, (M + smax - 1) / smax);
    const uint64_t sj = std::max<uint64_t>(1, (N + smax - 1) / smax);

    // K-step fill (above): C[i][j] = sum_k (k/ks + 1) + rowmul * (i%64) * K, independent of j.
    const KstepFill kf = kstep_fill();
    double kstep_base = 0.0;
    if (kf.ks) for (uint64_t k = 0; k < K; ++k) kstep_base += (double)(k / kf.ks + 1);
    std::vector<std::pair<long long, uint64_t>> diag_hist;   // signed error -> count (diag only)

    auto expected = [&](uint64_t i, uint64_t j) {
        double acc = 0.0;
        if (kf.ks)
            acc = kstep_base + (double)kf.rowmul * (double)(i % 64) * (double)K;
        else if (mf_vec)
            for (uint64_t k = 0; k < K; ++k)
                acc += fill_a(i * a.s0 + k * a.s1) * mf_scale(i, k / mf_vec)
                     * fill_b(k * b.s0 + j * b.s1) * mf_scale(j, k / mf_vec);
        else
        for (uint64_t k = 0; k < K; ++k)
            acc += fill_a(i * a.s0 + k * a.s1) * fill_b(k * b.s0 + j * b.s1);
        // POST is the section-4 activation applied after the multiply (ReLU, or the custom quadratic
        // tail).  Empty for a plain matmul.
        return post ? post(scale * acc) : scale * acc;
    };
    auto check = [&](uint64_t i, uint64_t j, double got) {
        ++r.checked;
        const double want = expected(i, j);
        const double err  = std::fabs(got - want);
        const double rel  = err / std::max(1e-300, std::fabs(want));
        if (err > r.max_abs_err) r.max_abs_err = err;
        if (rel > r.max_rel_err) r.max_rel_err = rel;
        // Under the k-step fill every value is an exact integer (f32 sums stay below 2^24), so any
        // error of a whole unit is a wrong read; a relative 1e-3 would hide a -2 in a sum of 10^5.
        if (kf.ks ? (err > 0.5) : (err > rtol * std::max(1.0, std::fabs(want)))) {
            r.verified = false;
            if (diag) {
                const long long se = std::llround(got - want);
                auto it = std::find_if(diag_hist.begin(), diag_hist.end(),
                                       [se](const std::pair<long long, uint64_t> &p) { return p.first == se; });
                if (it == diag_hist.end()) diag_hist.push_back({se, 1}); else ++it->second;
            }
            if (diag && diag_bad++ < 32)
                std::fprintf(stderr, "DIAG mismatch C[%llu][%llu] got %.17g want %.17g (err %.3g)\n",
                             (unsigned long long)i, (unsigned long long)j, got, want, err);
        }
    };

    std::vector<double> span;
    // Read along whichever axis is CONTIGUOUS in C's storage, so each read is one short span.
    if (c.s1 <= c.s0) {                       // row-major: a sampled ROW is contiguous
        for (uint64_t i = 0; i < M && (r.verified || diag); i += si) {
            const uint64_t first = i * c.s0;
            read_span(first, (N - 1) * c.s1 + 1, span);
            for (uint64_t j = 0; j < N && (r.verified || diag); j += sj) check(i, j, span[j * c.s1]);
        }
    } else {                                  // column-major: a sampled COLUMN is contiguous
        for (uint64_t j = 0; j < N && (r.verified || diag); j += sj) {
            const uint64_t first = j * c.s1;
            read_span(first, (M - 1) * c.s0 + 1, span);
            for (uint64_t i = 0; i < M && (r.verified || diag); i += si) check(i, j, span[i * c.s0]);
        }
    }
    if (diag) {
        // The signed-error histogram, most frequent first (with the k-step fill, each value decodes).
        std::sort(diag_hist.begin(), diag_hist.end(),
                  [](const std::pair<long long, uint64_t> &x, const std::pair<long long, uint64_t> &y) {
                      return x.second > y.second; });
        for (size_t h = 0; h < diag_hist.size() && h < 40; ++h)
            std::fprintf(stderr, "DIAGHIST err %lld count %llu\n", diag_hist[h].first,
                         (unsigned long long)diag_hist[h].second);
    }
    if (diag)
        std::fprintf(stderr, "DIAG %llu of %llu checked elements wrong (max_abs_err %.3g)\n",
                     (unsigned long long)diag_bad, (unsigned long long)r.checked, r.max_abs_err);
    return r;
}

}  // namespace crisp_bench
