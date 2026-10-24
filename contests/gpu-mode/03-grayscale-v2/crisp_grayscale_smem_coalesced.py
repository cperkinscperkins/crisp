# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (grayscale_smem_coalesced.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 03: grayscale_v2 (Stride-1 Coalesced Global float4 Load + Conflict-Free Shared Memory De-Interleave)
#   ;; Each 256-thread CTA loads 768 contiguous float4 vectors (3,072 floats = 12 KB) using 3 stride-1 coalesced
#   ;; global float4 loads (`tid`, `tid+256`, `tid+512`), stores them to shared memory, and each thread computes
#   ;; 4 pixels at `tid + {0, 256, 512, 768}` reading `sflt[3*tid + offset]` (`gcd(3, 32) = 1`, zero bank conflicts!)
#   ;; and writing 4 stride-1 coalesced global outputs.
#
#   (def-type in-vec   (vector float :address-space :global :align :compact))
#   (def-type out-vec  (vector float :address-space :global :align :compact))
#   (def-type smem-vec (vector float :address-space :local  :align :compact))
#
#   (def-function rgb-to-y (r g b)
#     (declare #'(float float float => float))
#     (op-fma 0.2989 r (op-fma 0.5870 g (* 0.1140 b))))
#
#   (def-kernel grayscale_kernel (input &out output)
#     (declare #'(in-vec &out out-vec => nil)
#              (global-size :derive-from output :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((bid   (to-ulong (get-workgroup-id 0)))
#           (tid   (to-ulong (get-local-id 0)))
#           (obase (+ (* bid 1024ul) tid))
#           (n     (length~ output))
#           (n4    (/ n 4ul))
#           (in4   (make-vector input float4 :length (* n4 3ul)))
#           (sflt  (make-scratch-vector smem-vec 3072))
#           (svec4 (make-vector sflt float4 :length 768))
#           (in-base (+ (* bid 768ul) tid))
#           (c0 (~ in4 in-base))
#           (c1 (~ in4 (+ in-base 256ul)))
#           (c2 (~ in4 (+ in-base 512ul))))
#       (set! (~ svec4 tid)           c0)
#       (set! (~ svec4 (+ tid 256ul)) c1)
#       (set! (~ svec4 (+ tid 512ul)) c2)
#       (sync-workgroup)
#       (let ((s3  (* tid 3ul))
#             (y0  (rgb-to-y (~ sflt s3)            (~ sflt (+ s3 1ul))    (~ sflt (+ s3 2ul))))
#             (y1  (rgb-to-y (~ sflt (+ s3 768ul))  (~ sflt (+ s3 769ul))  (~ sflt (+ s3 770ul))))
#             (y2  (rgb-to-y (~ sflt (+ s3 1536ul)) (~ sflt (+ s3 1537ul)) (~ sflt (+ s3 1538ul))))
#             (y3  (rgb-to-y (~ sflt (+ s3 2304ul)) (~ sflt (+ s3 2305ul)) (~ sflt (+ s3 2306ul)))))
#         (set! (~ output obase)           y0)
#         (set! (~ output (+ obase 256ul)) y1)
#         (set! (~ output (+ obase 512ul)) y2)
#         (set! (~ output (+ obase 768ul)) y3))))
# -------------------------------------------------------------------------

import torch
from torch.utils.cpp_extension import load_inline
from task import input_t, output_t

CUDA_SOURCE = r"""
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <cstdint>
#include <algorithm>

__global__ __launch_bounds__(256)
void crisp_grayscale_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t out_len
) {
    extern __shared__ __align__(128) unsigned char crisp_smem[];
    uint64_t smem_ptr = static_cast<uint64_t>(__cvta_generic_to_shared(crisp_smem));
    asm volatile(
        "{\n"
        "	.reg .b32 	%%cr_r<27>;\n"
        "	.reg .b64 	%%cr_rd<26>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd1, %0;\n"
        "	mov.b64 	%%cr_rd2, %3;\n"
        "	add.s64 	%%cr_rd3, %%cr_rd1, %%cr_rd2;\n"
        "	mov.b64 	%%cr_rd4, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd5, %%cr_rd4;\n"
        "	mov.b64 	%%cr_rd6, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd7, %%cr_rd6;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r2;\n"
        "	mul.wide.u32 	%%cr_rd9, %%cr_r1, 768;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd9, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd11, %%cr_rd10, 4;\n"
        "	add.s64 	%%cr_rd12, %%cr_rd5, %%cr_rd11;\n"
        "	ld.global.nc.v2.b64 	{%%cr_rd13, %%cr_rd14}, [%%cr_rd12];\n"
        "	ld.global.nc.v2.b64 	{%%cr_rd15, %%cr_rd16}, [%%cr_rd12+4096];\n"
        "	ld.global.nc.v2.b64 	{%%cr_rd17, %%cr_rd18}, [%%cr_rd12+8192];\n"
        "	mul.wide.u32 	%%cr_rd19, %%cr_r2, 16;\n"
        "	add.s64 	%%cr_rd20, %%cr_rd3, %%cr_rd19;\n"
        "	st.shared.v2.b64 	[%%cr_rd20], {%%cr_rd13, %%cr_rd14};\n"
        "	st.shared.v2.b64 	[%%cr_rd20+4096], {%%cr_rd15, %%cr_rd16};\n"
        "	st.shared.v2.b64 	[%%cr_rd20+8192], {%%cr_rd17, %%cr_rd18};\n"
        "	bar.sync 	0;\n"
        "	mul.wide.u32 	%%cr_rd21, %%cr_r2, 4;\n"
        "	sub.s64 	%%cr_rd22, %%cr_rd20, %%cr_rd21;\n"
        "	ld.shared.b32 	%%cr_r3, [%%cr_rd22];\n"
        "	ld.shared.b32 	%%cr_r4, [%%cr_rd22+4];\n"
        "	ld.shared.b32 	%%cr_r5, [%%cr_rd22+8];\n"
        "	mul.rn.f32 	%%cr_r6, %%cr_r5, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r7, %%cr_r4, 0f3F1645A2, %%cr_r6;\n"
        "	fma.rn.f32 	%%cr_r8, %%cr_r3, 0f3E99096C, %%cr_r7;\n"
        "	ld.shared.b32 	%%cr_r9, [%%cr_rd22+3072];\n"
        "	ld.shared.b32 	%%cr_r10, [%%cr_rd22+3076];\n"
        "	ld.shared.b32 	%%cr_r11, [%%cr_rd22+3080];\n"
        "	mul.rn.f32 	%%cr_r12, %%cr_r11, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r13, %%cr_r10, 0f3F1645A2, %%cr_r12;\n"
        "	fma.rn.f32 	%%cr_r14, %%cr_r9, 0f3E99096C, %%cr_r13;\n"
        "	ld.shared.b32 	%%cr_r15, [%%cr_rd22+6144];\n"
        "	ld.shared.b32 	%%cr_r16, [%%cr_rd22+6148];\n"
        "	ld.shared.b32 	%%cr_r17, [%%cr_rd22+6152];\n"
        "	mul.rn.f32 	%%cr_r18, %%cr_r17, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r19, %%cr_r16, 0f3F1645A2, %%cr_r18;\n"
        "	fma.rn.f32 	%%cr_r20, %%cr_r15, 0f3E99096C, %%cr_r19;\n"
        "	ld.shared.b32 	%%cr_r21, [%%cr_rd22+9216];\n"
        "	ld.shared.b32 	%%cr_r22, [%%cr_rd22+9220];\n"
        "	ld.shared.b32 	%%cr_r23, [%%cr_rd22+9224];\n"
        "	mul.rn.f32 	%%cr_r24, %%cr_r23, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r25, %%cr_r22, 0f3F1645A2, %%cr_r24;\n"
        "	fma.rn.f32 	%%cr_r26, %%cr_r21, 0f3E99096C, %%cr_r25;\n"
        "	mul.wide.u32 	%%cr_rd23, %%cr_r1, 4096;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd7, %%cr_rd23;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd24, %%cr_rd21;\n"
        "	st.global.b32 	[%%cr_rd25], %%cr_r8;\n"
        "	st.global.b32 	[%%cr_rd25+1024], %%cr_r14;\n"
        "	st.global.b32 	[%%cr_rd25+2048], %%cr_r20;\n"
        "	st.global.b32 	[%%cr_rd25+3072], %%cr_r26;\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(0ULL), "l"(in_ptr), "l"(out_ptr), "l"(smem_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output) {
    int64_t N = output.numel();
    if (N <= 0) return output;

    constexpr int BLOCK_SIZE = 256;
    int64_t needed_blocks = (N + (BLOCK_SIZE * 4) - 1) / (BLOCK_SIZE * 4);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);

    crisp_grayscale_kernel<<<grid_x, BLOCK_SIZE, 12288>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output);"""

_crisp_mod = load_inline(
    name="crisp_grayscale_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_grayscale"],
    extra_cuda_cflags=["-O3"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_grayscale(inp, out)
