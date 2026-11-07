// benchmarks/matmul/common/fill_cuda.cuh -- the shared matmul fill + verify, CUDA runtime.
//
// Used by every CUDA harness: cuBLAS, cuBLASLt, CUTLASS, the CUDA controls, and the Crisp CUDA fixture.
// The convention itself (A = flat%5, B = flat%3; fp64 scaled by the precision oracle; strided
// verification) lives in fill_verify.h -- this file is only how a CUDA device fills and reads back.
//
// POINTERS ARE void* device pointers from cudaMalloc (or a CUdeviceptr cast to void*), so every harness
// calls the same functions regardless of how it spells its element type.  The encoding is named
// explicitly: "f32" | "f64" | "f16" | "bf16" | "s8" | "u8".  Naming the wrong one fails verification, never silently.
//
// CONTEXT.  These run in the runtime's PRIMARY context.  A harness that creates its own context through
// the driver API (the Crisp fixture did) must use the primary one instead, or these kernels cannot
// reach its allocations.
#pragma once

#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "fill_verify.h"

namespace crisp_bench {

__global__ void crisp_fill_f32_kernel(float *p, uint64_t n, uint32_t mod) {
    const uint64_t i = (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    if (i < n) p[i] = (float)(i % mod);
}

__global__ void crisp_fill_f64_kernel(double *p, uint64_t n, uint32_t mod, double scale) {
    const uint64_t i = (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    if (i < n) p[i] = (double)(i % mod) * scale;
}

// 16-bit operands: host-encoded bit patterns, never a float converted on the device (fill_patterns16).
// Endeavour 207: 8-bit integer operands.  0..4 is the same byte in s8 and u8.
__global__ void crisp_fill_u8_kernel(uint8_t *p, uint64_t n, uint32_t mod) {
    const uint64_t i = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i] = (uint8_t)(i % mod);
}

__global__ void crisp_fill_u16_kernel(uint16_t *p, uint64_t n, uint32_t mod,
                                    uint16_t p0, uint16_t p1, uint16_t p2, uint16_t p3, uint16_t p4) {
    const uint64_t i = (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    if (i < n) {
        const uint32_t r = (uint32_t)(i % mod);
        p[i] = r == 0 ? p0 : r == 1 ? p1 : r == 2 ? p2 : r == 3 ? p3 : p4;
    }
}

// ---- Endeavour 209: block-scaled operands (see fill_verify.h for the convention) -----------------
// fmt: 0 = fp4 (e2m1, two codes per byte, the EVEN element in the low nibble -- D-206-3),
//      1 = fp8 e4m3, 2 = fp8 e5m2.  v is 0..4, exact in all three.
__device__ inline uint8_t crisp_mf_code(uint32_t v, int fmt) {
    if (fmt == 0) { const uint8_t t[5] = {0x0, 0x2, 0x4, 0x5, 0x6}; return t[v]; }        // 0 1 2 3 4
    if (fmt == 1) { const uint8_t t[5] = {0x00, 0x38, 0x40, 0x44, 0x48}; return t[v]; }
    const uint8_t t[5] = {0x00, 0x3C, 0x40, 0x42, 0x44}; return t[v];
}

// One BYTE per thread.  Logical element `flat` lives in byte flat / epb, so the operand must be
// contiguous along K (A row-major, B column-major) -- the only layout the block MMAs take.
__global__ void crisp_fill_mf_codes_kernel(uint8_t *p, uint64_t nbytes, uint32_t mod, int fmt) {
    const uint64_t i = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nbytes) return;
    if (fmt == 0)
        p[i] = (uint8_t)(crisp_mf_code((uint32_t)((2 * i) % mod), 0)
                         | (crisp_mf_code((uint32_t)((2 * i + 1) % mod), 0) << 4));
    else
        p[i] = crisp_mf_code((uint32_t)(i % mod), fmt);
}

// The :blocked-128x4 scale layout (cuBLAS's / CUTLASS's): R rows padded to 128, ceil(K/vec) scales
// per row padded to 4; atoms of 128 x 4 = 512 bytes, atom (r/128, j/4) at ((r/128)*katoms + j/4)*512,
// and inside it (r%32)*16 + ((r%128)/32)*4 + j%4.  Each thread inverts that for one byte.
__global__ void crisp_fill_mf_scales_kernel(uint8_t *p, uint64_t nbytes, uint64_t katoms, int e8m0) {
    const uint64_t i = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nbytes) return;
    const uint64_t atom = i / 512, w = i % 512;
    const uint64_t r = (atom / katoms) * 128 + ((w % 16) / 4) * 32 + w / 16;
    const uint64_t j = (atom % katoms) * 4 + w % 4;
    const int e = mf_scale_exp(r, j);
    p[i] = e8m0 ? (uint8_t)(127 + e) : (uint8_t)((7 + e) << 3);   // ue8m0 | ue4m3 (positive e4m3)
}

namespace detail {
inline void cuda_must(cudaError_t rc, const char *what) {
    if (rc != cudaSuccess) {
        std::fprintf(stderr, "fill_cuda: %s failed: %s\n", what, cudaGetErrorString(rc));
        std::exit(2);
    }
}
inline dim3 fill_grid(uint64_t n, uint32_t block) {
    const uint64_t blocks = (n + block - 1) / block;
    if (blocks > 0x7fffffffULL) { std::fprintf(stderr, "fill_cuda: %llu elements exceed the 1-D grid\n",
                                               (unsigned long long)n); std::exit(2); }
    return dim3((unsigned)blocks, 1, 1);
}
}  // namespace detail

// Fill n elements of a device buffer with (flat % mod) in encoding `enc`; fp64 carries FILL_F64_SCALE.
inline void cuda_fill_encoded(void *ptr, uint64_t n, uint32_t mod, const char *enc) {
    const uint32_t B = 1024;
    const dim3 block(B, 1, 1), grid = detail::fill_grid(n, B);
    const std::string e(enc);
    if (e == "f32") {
        crisp_fill_f32_kernel<<<grid, block>>>(static_cast<float *>(ptr), n, mod);
    } else if (e == "f64") {
        crisp_fill_f64_kernel<<<grid, block>>>(static_cast<double *>(ptr), n, mod, FILL_F64_SCALE);
    } else if (e == "s8" || e == "u8") {
        crisp_fill_u8_kernel<<<grid, block>>>(static_cast<uint8_t *>(ptr), n, mod);
    } else if (e == "f16" || e == "bf16") {
        uint16_t pat[5];
        fill_patterns16(enc, pat);
        crisp_fill_u16_kernel<<<grid, block>>>(static_cast<uint16_t *>(ptr), n, mod,
                                               pat[0], pat[1], pat[2], pat[3], pat[4]);
    } else {
        std::fprintf(stderr, "fill_cuda: unknown encoding '%s'\n", enc); std::exit(2);
    }
    detail::cuda_must(cudaGetLastError(), "fill launch");
    detail::cuda_must(cudaDeviceSynchronize(), "fill synchronize");
}

// Zero a device buffer of `bytes` bytes (0.0 is all-zero bits in every encoding used here).
// Endeavour 209.  Codes of a block-matrix operand of `n` LOGICAL elements.  base: "fp4" | "fp8-e4m3"
// | "fp8-e5m2" (the metacrisp's :base).  Returns the byte count it filled.
inline uint64_t cuda_fill_mf_codes(void *ptr, uint64_t n, uint32_t mod, const char *base) {
    const std::string b(base);
    const int fmt = (b == "fp4") ? 0 : (b == "fp8-e4m3") ? 1 : (b == "fp8-e5m2") ? 2 : -1;
    if (fmt < 0) { std::fprintf(stderr, "fill_cuda: unknown block base '%s'\n", base); std::exit(2); }
    const uint64_t nbytes = fmt == 0 ? n / 2 : n;
    const uint32_t B = 1024;
    crisp_fill_mf_codes_kernel<<<detail::fill_grid(nbytes, B), dim3(B, 1, 1)>>>(
        static_cast<uint8_t *>(ptr), nbytes, mod, fmt);
    detail::cuda_must(cudaGetLastError(), "mf codes fill launch");
    detail::cuda_must(cudaDeviceSynchronize(), "mf codes fill synchronize");
    return nbytes;
}

// Bytes of the :blocked-128x4 scales of a matrix with `rows` rows and K columns, one scale per `vec`.
inline uint64_t mf_scales_bytes(uint64_t rows, uint64_t K, uint64_t vec) {
    const uint64_t katoms = ((K + vec - 1) / vec + 3) / 4;
    return ((rows + 127) / 128) * 128 * katoms * 4;
}

// Endeavour 209.  The scales of a `rows` x K block matrix.  scale: "fp8-e8m0" (MX) or "fp8-e4m3"
// (NVFP4's ue4m3).
inline void cuda_fill_mf_scales(void *ptr, uint64_t rows, uint64_t K, uint64_t vec, const char *scale) {
    const uint64_t katoms = ((K + vec - 1) / vec + 3) / 4;
    const uint64_t nbytes = mf_scales_bytes(rows, K, vec);
    const std::string s(scale);
    if (s != "fp8-e8m0" && s != "fp8-e4m3") {
        std::fprintf(stderr, "fill_cuda: unknown scale format '%s'\n", scale); std::exit(2);
    }
    const uint32_t B = 1024;
    crisp_fill_mf_scales_kernel<<<detail::fill_grid(nbytes, B), dim3(B, 1, 1)>>>(
        static_cast<uint8_t *>(ptr), nbytes, katoms, s == "fp8-e8m0" ? 1 : 0);
    detail::cuda_must(cudaGetLastError(), "mf scales fill launch");
    detail::cuda_must(cudaDeviceSynchronize(), "mf scales fill synchronize");
}

inline void cuda_zero(void *ptr, size_t bytes) {
    detail::cuda_must(cudaMemset(ptr, 0, bytes), "zero");
}

// Strided verification of C (M x N) through its strides; reads back only the sampled spans.
// `enc` is C's encoding: "f32" (every float type but fp64), "f64" (which also switches on the oracle's
// scale and tolerance) or "s32" (the 8-bit integer MMAs, Endeavour 207; exact).  POST applies a section-4 activation to the expected value.
inline VerifyResult cuda_verify(const void *C, const char *enc, uint64_t M, uint64_t N, uint64_t K,
                                Strides a, Strides b, Strides c,
                                const std::function<double(double)> &post = {},
                                uint64_t mf_vec = 0) {      // Endeavour 209: >0 = block-scaled operands
    const bool f64 = std::string(enc) == "f64";
    const bool s32 = std::string(enc) == "s32";   // Endeavour 207: the 8-bit integer MMAs' accumulator
    const bool s8  = std::string(enc) == "s8";    // Endeavour 207: a requantized (narrowed) C
    ReadSpan read = [&](uint64_t first, uint64_t count, std::vector<double> &out) {
        if (s8) {
            std::vector<int8_t> buf((size_t)count);
            detail::cuda_must(cudaMemcpy(buf.data(), static_cast<const char *>(C) + first,
                                         (size_t)count, cudaMemcpyDeviceToHost), "readback");
            out.assign(buf.begin(), buf.end());
        } else if (s32) {
            std::vector<int32_t> buf((size_t)count);
            detail::cuda_must(cudaMemcpy(buf.data(), static_cast<const char *>(C) + first * sizeof(int32_t),
                                         (size_t)count * sizeof(int32_t), cudaMemcpyDeviceToHost), "readback");
            out.assign(buf.begin(), buf.end());
        } else if (f64) {
            std::vector<double> buf((size_t)count);
            detail::cuda_must(cudaMemcpy(buf.data(), static_cast<const char *>(C) + first * sizeof(double),
                                         (size_t)count * sizeof(double), cudaMemcpyDeviceToHost), "readback");
            out.assign(buf.begin(), buf.end());
        } else {
            std::vector<float> buf((size_t)count);
            detail::cuda_must(cudaMemcpy(buf.data(), static_cast<const char *>(C) + first * sizeof(float),
                                         (size_t)count * sizeof(float), cudaMemcpyDeviceToHost), "readback");
            out.assign(buf.begin(), buf.end());
        }
    };
    const double scale = f64 ? FILL_F64_SCALE * FILL_F64_SCALE : 1.0;
    return verify_sampled(M, N, K, a, b, c, read, scale, 64, post, f64 ? FILL_F64_RTOL : FILL_RTOL, mf_vec);
}

// The two layouts the CUDA harnesses use (M x K A, K x N B, M x N C):
//   cuBLAS / cuBLASLt   : all column-major
//   controls / CUTLASS  : A row-major, B column-major, C row-major
inline Strides cm(uint64_t rows)  { return {1, rows}; }      // column-major, `rows` leading dimension
inline Strides rm(uint64_t cols)  { return {cols, 1}; }      // row-major, `cols` per row

}  // namespace crisp_bench
