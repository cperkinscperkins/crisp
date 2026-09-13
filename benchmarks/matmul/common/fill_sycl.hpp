// benchmarks/matmul/common/fill_sycl.hpp -- the shared matmul fill + verify, SYCL runtime.
//
// Used by every SYCL-runtime harness: oneMKL, SYCL-TLA, oneDNN and the SYCL controls.  The convention
// itself (A = flat%5, B = flat%3, strided verification) lives in fill_verify.h; this file is only how
// a SYCL queue fills and reads back.  See that header for why the harnesses were unified.
//
// Works for device AND shared USM.  The memory TYPE of each harness is deliberately left as it was --
// changing it would change what a competitor is measured on, which is not this file's business.
#pragma once

#include <sycl/sycl.hpp>
#include <array>
#include <cstdint>
#include <vector>

#include "fill_verify.h"

namespace crisp_bench {

namespace detail {
template <class T>
inline void sycl_fill_values(sycl::queue &q, T *ptr, size_t n, uint32_t mod) {
    q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> id) {
        const size_t i = id[0];
        ptr[i] = (T)(i % mod);
    }).wait();
}
// 16-bit operands: write host-encoded bit patterns, never convert a float on the device (see
// fill_patterns16 in fill_verify.h).  sycl::half and bfloat16 are both exactly 16 raw bits.
inline void sycl_fill_patterns(sycl::queue &q, void *ptr, size_t n, uint32_t mod, const char *enc) {
    uint16_t pat5[5];
    fill_patterns16(enc, pat5);
    const std::array<uint16_t, 5> pat{pat5[0], pat5[1], pat5[2], pat5[3], pat5[4]};
    uint16_t *p = static_cast<uint16_t *>(ptr);
    q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> id) {
        const size_t i = id[0];
        p[i] = pat[i % mod];
    }).wait();
}
}  // namespace detail

// Fill n elements of a USM buffer with (flat % mod) in the buffer's own element encoding.
inline void sycl_fill(sycl::queue &q, float *p, size_t n, uint32_t mod)  { detail::sycl_fill_values(q, p, n, mod); }
inline void sycl_fill(sycl::queue &q, double *p, size_t n, uint32_t mod) { detail::sycl_fill_values(q, p, n, mod); }
inline void sycl_fill(sycl::queue &q, sycl::half *p, size_t n, uint32_t mod) {
    detail::sycl_fill_patterns(q, p, n, mod, "f16");
}
inline void sycl_fill(sycl::queue &q, sycl::ext::oneapi::bfloat16 *p, size_t n, uint32_t mod) {
    detail::sycl_fill_patterns(q, p, n, mod, "bf16");
}

// Fill by EXPLICIT encoding, for harnesses whose element type is a library's own wrapper (SYCL-TLA's
// tfloat32_t / bfloat16_t / half_t).  enc: "f32" (4-byte IEEE float storage), "bf16", "f16".  If the
// encoding named here is wrong for the buffer, verification fails -- it recomputes from the formula.
inline void sycl_fill_encoded(sycl::queue &q, void *ptr, size_t n, uint32_t mod, const char *enc) {
    if (enc[0] == 'f' && enc[1] == '3') detail::sycl_fill_values(q, static_cast<float *>(ptr), n, mod);
    else                                detail::sycl_fill_patterns(q, ptr, n, mod, enc);
}

// Zero an output buffer on the device.
template <class CT>
inline void sycl_zero(sycl::queue &q, CT *p, size_t n) { q.fill(p, CT(0), n).wait(); }

// Strided verification of C (M x N, row-major by default) against the formula; reads back only the
// sampled rows.  POST applies a section-4 activation to the expected value.
template <class CT>
inline VerifyResult sycl_verify(sycl::queue &q, const CT *C, uint64_t M, uint64_t N, uint64_t K,
                                const std::function<double(double)> &post = {},
                                Strides a = {0, 1}, Strides b = {0, 1}, Strides c = {0, 1}) {
    if (a.s0 == 0) a = {K, 1};                 // row-major defaults
    if (b.s0 == 0) b = {N, 1};
    if (c.s0 == 0) c = {N, 1};
    ReadSpan read = [&](uint64_t first, uint64_t count, std::vector<double> &out) {
        std::vector<CT> buf((size_t)count);
        q.memcpy(buf.data(), C + first, (size_t)count * sizeof(CT)).wait();
        out.assign(buf.begin(), buf.end());
    };
    return verify_sampled(M, N, K, a, b, c, read, 1.0, 64, post);
}

}  // namespace crisp_bench
