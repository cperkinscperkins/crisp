// benchmarks/matmul/common/fill_cuda.cuh -- the shared matmul fill + verify, CUDA runtime.
//
// Used by every CUDA harness: cuBLAS, cuBLASLt, CUTLASS, the CUDA controls, and the Crisp CUDA fixture.
// The convention itself (A = flat%5, B = flat%3; fp64 scaled by the precision oracle; strided
// verification) lives in fill_verify.h -- this file is only how a CUDA device fills and reads back.
//
// POINTERS ARE void* device pointers from cudaMalloc (or a CUdeviceptr cast to void*), so every harness
// calls the same functions regardless of how it spells its element type.  The encoding is named
// explicitly: "f32" | "f64" | "f16" | "bf16".  Naming the wrong one fails verification, never silently.
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
__global__ void crisp_fill_u16_kernel(uint16_t *p, uint64_t n, uint32_t mod,
                                    uint16_t p0, uint16_t p1, uint16_t p2, uint16_t p3, uint16_t p4) {
    const uint64_t i = (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    if (i < n) {
        const uint32_t r = (uint32_t)(i % mod);
        p[i] = r == 0 ? p0 : r == 1 ? p1 : r == 2 ? p2 : r == 3 ? p3 : p4;
    }
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
inline void cuda_zero(void *ptr, size_t bytes) {
    detail::cuda_must(cudaMemset(ptr, 0, bytes), "zero");
}

// Strided verification of C (M x N) through its strides; reads back only the sampled spans.
// `enc` is C's encoding: "f32" (everything but fp64) or "f64" (which also switches on the oracle's scale
// and tolerance).  POST applies a section-4 activation to the expected value.
inline VerifyResult cuda_verify(const void *C, const char *enc, uint64_t M, uint64_t N, uint64_t K,
                                Strides a, Strides b, Strides c,
                                const std::function<double(double)> &post = {}) {
    const bool f64 = std::string(enc) == "f64";
    ReadSpan read = [&](uint64_t first, uint64_t count, std::vector<double> &out) {
        if (f64) {
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
    return verify_sampled(M, N, K, a, b, c, read, scale, 64, post, f64 ? FILL_F64_RTOL : FILL_RTOL);
}

// The two layouts the CUDA harnesses use (M x K A, K x N B, M x N C):
//   cuBLAS / cuBLASLt   : all column-major
//   controls / CUTLASS  : A row-major, B column-major, C row-major
inline Strides cm(uint64_t rows)  { return {1, rows}; }      // column-major, `rows` leading dimension
inline Strides rm(uint64_t cols)  { return {cols, 1}; }      // row-major, `cols` per row

}  // namespace crisp_bench
