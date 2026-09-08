// The §2 fp64 correctness oracle — SHARED by every f64 contender so the arms cannot drift.
//
// WHY THIS FILE EXISTS AT ALL.  Every other matmul benchmark in this tree uses A = B = 1.0 and
// checks C == K.  That oracle is worthless for a 64-bit endeavour: 1.0 is exact in fp64, fp32,
// tf32 AND fp16, so a kernel that silently computed the whole GEMM in single precision passes it
// with max_abs_err exactly 0.  The premise of endeavour 165 is IEEE double; an oracle that cannot
// tell double from float is a green light with no information in it.
//
// THE DISCRIMINATOR.  Fill A and B with v = 1 + 2^-25.
//
//   * In fp32, 2^-25 is BELOW half an ulp at 1.0 (fp32's half-ulp is 2^-24), so v rounds to
//     exactly 1.0.  tf32 (10-bit mantissa) and fp16 round it to 1.0 even more decisively.
//     A single-precision path therefore computes exactly K.
//   * In fp64, v is exact, and C = K * v^2 = K * (1 + 2^-24 + 2^-50).  Every bit of that is
//     representable (the mantissa spans 51 bits, fp64 has 52), so the expected value is EXACT
//     for the sizes we run — no reference GEMM needed, on host or device.
//
//   fp32 path  -> relative error 2^-24 = 5.96e-08
//   fp64 path  -> relative error <= K*DBL_EPSILON ~ 3.6e-12 at K=16384, and far less in
//                 practice because a blocked GEMM does not accumulate sequentially.
//
// A relative tolerance of 1e-10 sits between them with ~28x headroom above honest fp64 rounding
// and rejects a single-precision path by ~596x.  The gap is wide enough that we do not have to
// be clever about accumulation order.
//
// LAYOUT-INSENSITIVE ON PURPOSE.  Every element of A and B is the same value, so row-major vs
// column-major operands give bit-identical results.  The contenders here disagree about layout
// (cuBLAS runs N/N column-major, the CUTLASS peer runs row-major A / column-major B to mirror
// the tf32 peer); the oracle must not care, or it would be measuring the layout instead of the
// arithmetic.
//
// DIAGNOSIS, NOT JUST A VERDICT.  crisp_f64_oracle_diagnose() recognises the fp32 signature and
// says so.  "incorrect" sends you looking for a bug in the harness; "computed at single
// precision" names what actually happened.
#pragma once

#include <cmath>
#include <cstddef>

#define CRISP_F64_ORACLE_RTOL 1e-10

// v = 1 + 2^-25.  Computed with ldexp rather than written as a decimal literal so it cannot be
// mistranscribed into a value that fp32 does NOT round away.
static inline double crisp_f64_oracle_value(void) {
    return 1.0 + ldexp(1.0, -25);
}

// C[i][j] for an all-v times all-v GEMM of inner dimension K.  Exact in fp64.
static inline double crisp_f64_oracle_expected(int K) {
    const double v = crisp_f64_oracle_value();
    return (double)K * v * v;
}

// What a single-precision (or tf32, or fp16) path produces instead: v rounds to 1.0, so C == K.
static inline double crisp_f64_oracle_fp32_result(int K) {
    return (double)K;
}

// Scan C, returning the worst absolute and relative deviation from the exact fp64 answer.
static inline bool crisp_f64_oracle_check(const double* C, size_t n, int K,
                                          double* out_maxabs, double* out_maxrel) {
    const double expected = crisp_f64_oracle_expected(K);
    double maxabs = 0.0;
    for (size_t i = 0; i < n; i++) {
        const double d = std::fabs(C[i] - expected);
        if (d > maxabs) maxabs = d;
    }
    const double maxrel = (expected != 0.0) ? (maxabs / std::fabs(expected)) : maxabs;
    if (out_maxabs) *out_maxabs = maxabs;
    if (out_maxrel) *out_maxrel = maxrel;
    return maxrel < CRISP_F64_ORACLE_RTOL;
}

// Name the failure mode rather than merely reporting one.  The fp32 signature is a relative
// error of 2^-24; we accept a decade either side of it before claiming that specific diagnosis.
static inline const char* crisp_f64_oracle_diagnose(double maxrel) {
    if (maxrel < CRISP_F64_ORACLE_RTOL) return "fp64";
    const double fp32_sig = ldexp(1.0, -24);
    if (maxrel > fp32_sig * 0.1 && maxrel < fp32_sig * 10.0)
        return "computed at SINGLE precision (fp32/tf32 signature) — not fp64";
    return "wrong by an amount that is neither fp64 rounding nor the fp32 signature";
}
