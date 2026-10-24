# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (grayscale_direct_2xvec4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 03: grayscale_v2 (Direct 2x float4 = 8 Pixels / Thread, Constant Displacement)
#   ;; Each 256-thread CTA processes 512 float4 output packets (2,048 pixels = 24 KB RGB input + 8 KB output),
#   ;; halving total CTA count to 131,072 for 16384x16384 and folding all 6 `ld.global.nc.v4.b32` loads
#   ;; onto a single base pointer register (`[+0..+32]` and `[+12288..+12320]`).
#
#   (def-type in-vec  (vector float :address-space :global :align :compact))
#   (def-type out-vec (vector float :address-space :global :align :compact :cache :str-eaming))
#
#   (def-function rgb-to-y (r g b)
#     (declare #'(float float float => float))
#     (op-fma 0.2989 r (op-fma 0.5870 g (* 0.1140 b))))
#
#   (def-kernel grayscale_kernel (input &out output)
#     (declare #'(in-vec &out out-vec => nil)
#              (global-size :derive-from output :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((bid  (to-ulong (get-workgroup-id 0)))
#           (tid  (to-ulong (get-local-id 0)))
#           (base (+ (* bid 512ul) tid))
#           (n    (length~ output))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input  float4 :length (* n4 3ul)))
#           (out4 (make-vector output float4 :length n4)))
#       (if (< (+ (* bid 512ul) 511ul) n4)
#           (let ((i3a (* base 3ul))
#                 (i3b (+ i3a 768ul))
#                 (a0  (~ in4 i3a))
#                 (a1  (~ in4 (+ i3a 1ul)))
#                 (a2  (~ in4 (+ i3a 2ul)))
#                 (b0  (~ in4 i3b))
#                 (b1  (~ in4 (+ i3b 1ul)))
#                 (b2  (~ in4 (+ i3b 2ul)))
#                 (ya0 (rgb-to-y (x~ a0) (y~ a0) (z~ a0)))
#                 (ya1 (rgb-to-y (w~ a0) (x~ a1) (y~ a1)))
#                 (ya2 (rgb-to-y (z~ a1) (w~ a1) (x~ a2)))
#                 (ya3 (rgb-to-y (y~ a2) (z~ a2) (w~ a2)))
#                 (yb0 (rgb-to-y (x~ b0) (y~ b0) (z~ b0)))
#                 (yb1 (rgb-to-y (w~ b0) (x~ b1) (y~ b1)))
#                 (yb2 (rgb-to-y (z~ b1) (w~ b1) (x~ b2)))
#                 (yb3 (rgb-to-y (y~ b2) (z~ b2) (w~ b2))))
#             (set! (~ out4 base)           ##(ya0 ya1 ya2 ya3))
#             (set! (~ out4 (+ base 256ul)) ##(yb0 yb1 yb2 yb3)))
#           (when (< base n4)
#             (let ((i3a (* base 3ul))
#                   (a0  (~ in4 i3a))
#                   (a1  (~ in4 (+ i3a 1ul)))
#                   (a2  (~ in4 (+ i3a 2ul)))
#                   (ya0 (rgb-to-y (x~ a0) (y~ a0) (z~ a0)))
#                   (ya1 (rgb-to-y (w~ a0) (x~ a1) (y~ a1)))
#                   (ya2 (rgb-to-y (z~ a1) (w~ a1) (x~ a2)))
#                   (ya3 (rgb-to-y (y~ a2) (z~ a2) (w~ a2))))
#               (set! (~ out4 base) ##(ya0 ya1 ya2 ya3)))))))
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
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<3>;\n"
        "	.reg .b32 	%%cr_r<75>;\n"
        "	.reg .b64 	%%cr_rd<18>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd5, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd5;\n"
        "	mov.b64 	%%cr_rd6, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd6;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r2;\n"
        "	mul.wide.u32 	%%cr_rd8, %%cr_r1, 512;\n"
        "	add.s64 	%%cr_rd3, %%cr_rd8, %%cr_rd7;\n"
        "	mov.b64 	%%cr_rd9, %2;\n"
        "	shr.u64 	%%cr_rd4, %%cr_rd9, 2;\n"
        "	or.b64 	%%cr_rd10, %%cr_rd8, 511;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd10, %%cr_rd4;\n"
        "	@%%cr_p1 bra 	$L__BB39_2;\n"
        "// %%bb.1:                               // %%then\n"
        "	mad.lo.s64 	%%cr_rd16, %%cr_rd3, 48, %%cr_rd1;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r35, %%cr_r36, %%cr_r37, %%cr_r38}, [%%cr_rd16];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r39, %%cr_r40, %%cr_r41, %%cr_r42}, [%%cr_rd16+16];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r43, %%cr_r44, %%cr_r45, %%cr_r46}, [%%cr_rd16+32];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r47, %%cr_r48, %%cr_r49, %%cr_r50}, [%%cr_rd16+12288];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r51, %%cr_r52, %%cr_r53, %%cr_r54}, [%%cr_rd16+12304];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r55, %%cr_r56, %%cr_r57, %%cr_r58}, [%%cr_rd16+12320];\n"
        "	mul.rn.f32 	%%cr_r59, %%cr_r37, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r60, %%cr_r36, 0f3F1645A2, %%cr_r59;\n"
        "	fma.rn.f32 	%%cr_r27, %%cr_r35, 0f3E99096C, %%cr_r60;\n"
        "	mul.rn.f32 	%%cr_r61, %%cr_r40, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r62, %%cr_r39, 0f3F1645A2, %%cr_r61;\n"
        "	fma.rn.f32 	%%cr_r28, %%cr_r38, 0f3E99096C, %%cr_r62;\n"
        "	mul.rn.f32 	%%cr_r63, %%cr_r43, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r64, %%cr_r42, 0f3F1645A2, %%cr_r63;\n"
        "	fma.rn.f32 	%%cr_r29, %%cr_r41, 0f3E99096C, %%cr_r64;\n"
        "	mul.rn.f32 	%%cr_r65, %%cr_r46, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r66, %%cr_r45, 0f3F1645A2, %%cr_r65;\n"
        "	fma.rn.f32 	%%cr_r30, %%cr_r44, 0f3E99096C, %%cr_r66;\n"
        "	mul.rn.f32 	%%cr_r67, %%cr_r49, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r68, %%cr_r48, 0f3F1645A2, %%cr_r67;\n"
        "	fma.rn.f32 	%%cr_r31, %%cr_r47, 0f3E99096C, %%cr_r68;\n"
        "	mul.rn.f32 	%%cr_r69, %%cr_r52, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r70, %%cr_r51, 0f3F1645A2, %%cr_r69;\n"
        "	fma.rn.f32 	%%cr_r32, %%cr_r50, 0f3E99096C, %%cr_r70;\n"
        "	mul.rn.f32 	%%cr_r71, %%cr_r55, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r72, %%cr_r54, 0f3F1645A2, %%cr_r71;\n"
        "	fma.rn.f32 	%%cr_r33, %%cr_r53, 0f3E99096C, %%cr_r72;\n"
        "	mul.rn.f32 	%%cr_r73, %%cr_r58, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r74, %%cr_r57, 0f3F1645A2, %%cr_r73;\n"
        "	fma.rn.f32 	%%cr_r34, %%cr_r56, 0f3E99096C, %%cr_r74;\n"
        "	shl.b64 	%%cr_rd17, %%cr_rd3, 4;\n"
        "	add.s64 	%%cr_rd14, %%cr_rd2, %%cr_rd17;\n"
        "	// begin inline asm\n"
        "	st.global.cs.v4.f32 [%%cr_rd14], {%%cr_r27, %%cr_r28, %%cr_r29, %%cr_r30};\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd15, %%cr_rd14, 4096;\n"
        "	// begin inline asm\n"
        "	st.global.cs.v4.f32 [%%cr_rd15], {%%cr_r31, %%cr_r32, %%cr_r33, %%cr_r34};\n"
        "	// end inline asm\n"
        "	bra.uni 	$L__BB39_3;\n"
        "$L__BB39_2:                             // %%else\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd3, %%cr_rd4;\n"
        "	@%%cr_p2 bra 	$L__BB39_4;\n"
        "	bra.uni 	$L__BB39_3;\n"
        "$L__BB39_4:                             // %%then181\n"
        "	mad.lo.s64 	%%cr_rd12, %%cr_rd3, 48, %%cr_rd1;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r7, %%cr_r8, %%cr_r9, %%cr_r10}, [%%cr_rd12+16];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r11, %%cr_r12, %%cr_r13, %%cr_r14}, [%%cr_rd12+32];\n"
        "	ld.global.nc.v4.b32 	{%%cr_r15, %%cr_r16, %%cr_r17, %%cr_r18}, [%%cr_rd12];\n"
        "	mul.rn.f32 	%%cr_r19, %%cr_r17, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r20, %%cr_r16, 0f3F1645A2, %%cr_r19;\n"
        "	fma.rn.f32 	%%cr_r3, %%cr_r15, 0f3E99096C, %%cr_r20;\n"
        "	mul.rn.f32 	%%cr_r21, %%cr_r8, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r22, %%cr_r7, 0f3F1645A2, %%cr_r21;\n"
        "	fma.rn.f32 	%%cr_r4, %%cr_r18, 0f3E99096C, %%cr_r22;\n"
        "	mul.rn.f32 	%%cr_r23, %%cr_r11, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r24, %%cr_r10, 0f3F1645A2, %%cr_r23;\n"
        "	fma.rn.f32 	%%cr_r5, %%cr_r9, 0f3E99096C, %%cr_r24;\n"
        "	mul.rn.f32 	%%cr_r25, %%cr_r14, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r26, %%cr_r13, 0f3F1645A2, %%cr_r25;\n"
        "	fma.rn.f32 	%%cr_r6, %%cr_r12, 0f3E99096C, %%cr_r26;\n"
        "	shl.b64 	%%cr_rd13, %%cr_rd3, 4;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd2, %%cr_rd13;\n"
        "	// begin inline asm\n"
        "	st.global.cs.v4.f32 [%%cr_rd11], {%%cr_r3, %%cr_r4, %%cr_r5, %%cr_r6};\n"
        "	// end inline asm\n"
        "$L__BB39_3:                             // %%ifcont\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(in_ptr), "l"(out_ptr), "l"(out_len)
        : "memory"
    );
}

torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output) {
    int64_t N = output.numel();
    if (N <= 0) return output;

    constexpr int BLOCK_SIZE = 256;
    int64_t needed_blocks = (N + (BLOCK_SIZE * 8) - 1) / (BLOCK_SIZE * 8);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);

    crisp_grayscale_kernel<<<grid_x, BLOCK_SIZE>>>(
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
