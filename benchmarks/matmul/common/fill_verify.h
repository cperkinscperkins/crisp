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
#include <cstring>
#include <functional>
#include <vector>

namespace crisp_bench {

constexpr uint32_t FILL_MOD_A = 5;
constexpr uint32_t FILL_MOD_B = 3;

inline double fill_a(uint64_t flat) { return (double)(flat % FILL_MOD_A); }
inline double fill_b(uint64_t flat) { return (double)(flat % FILL_MOD_B); }

// 16-bit operands are filled as RAW 16-bit PATTERNS, not by converting a float on the device.
// Storing a float into a half/bfloat16 tensor element in a Crisp kernel produced wrong values on
// 2026-09-13 (both widths; f32 was correct) -- so the host encodes the five fill values once and
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
};

// Copy `count` elements of C starting at storage index `first` into `out` as doubles.  The harness
// supplies it, because only the harness knows its runtime and C's element width.
using ReadSpan = std::function<void(uint64_t first, uint64_t count, std::vector<double> &out)>;

// A strided ~64 x 64 sample over the WHOLE of C (M x N), C = scale * (A . B), A is M x K, B is K x N.
// Stops at the first mismatch, like the fixtures always have.
inline VerifyResult verify_sampled(uint64_t M, uint64_t N, uint64_t K,
                                   Strides a, Strides b, Strides c,
                                   const ReadSpan &read_span,
                                   double scale = 1.0, uint64_t smax = 64) {
    VerifyResult r;
    if (M == 0 || N == 0) return r;
    const uint64_t si = std::max<uint64_t>(1, (M + smax - 1) / smax);
    const uint64_t sj = std::max<uint64_t>(1, (N + smax - 1) / smax);

    auto expected = [&](uint64_t i, uint64_t j) {
        double acc = 0.0;
        for (uint64_t k = 0; k < K; ++k)
            acc += fill_a(i * a.s0 + k * a.s1) * fill_b(k * b.s0 + j * b.s1);
        return scale * acc;
    };
    auto check = [&](uint64_t i, uint64_t j, double got) {
        ++r.checked;
        const double want = expected(i, j);
        const double err  = std::fabs(got - want);
        if (err > r.max_abs_err) r.max_abs_err = err;
        if (err > 1e-3 * std::max(1.0, std::fabs(want))) r.verified = false;
    };

    std::vector<double> span;
    // Read along whichever axis is CONTIGUOUS in C's storage, so each read is one short span.
    if (c.s1 <= c.s0) {                       // row-major: a sampled ROW is contiguous
        for (uint64_t i = 0; i < M && r.verified; i += si) {
            const uint64_t first = i * c.s0;
            read_span(first, (N - 1) * c.s1 + 1, span);
            for (uint64_t j = 0; j < N && r.verified; j += sj) check(i, j, span[j * c.s1]);
        }
    } else {                                  // column-major: a sampled COLUMN is contiguous
        for (uint64_t j = 0; j < N && r.verified; j += sj) {
            const uint64_t first = j * c.s1;
            read_span(first, (M - 1) * c.s0 + 1, span);
            for (uint64_t i = 0; i < M && r.verified; i += si) check(i, j, span[i * c.s0]);
        }
    }
    return r;
}

}  // namespace crisp_bench
