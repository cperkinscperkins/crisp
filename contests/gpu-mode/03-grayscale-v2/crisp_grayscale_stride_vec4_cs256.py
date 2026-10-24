# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (grayscale_stride_vec4_cs256.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 03: grayscale_v2 (Persistent Grid-Stride float4 3:1 Packet + Endeavour 192 Cache Hints)
#   ;; Uses `loop-vector-stride` over `out4` with `:cache (:str-eaming :prefetch 256)` on `in-vec`
#   ;; (`ld.global.cs.nc.L2::256B.v4.f32`) and `:cache :str-eaming` on `out-vec` (`st.global.cs.v4.f32`).
#
#   (def-type in-vec  (vector float :address-space :global :align :compact :cache (:str-eaming :prefetch 256)))
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
#     (let ((n    (length~ output))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input  float4 :length (* n4 3ul)))
#           (out4 (make-vector output float4 :length n4)))
#       (loop-vector-stride out4 (i)
#         (let ((i3 (* i 3ul))
#               (v0 (~ in4 i3))
#               (v1 (~ in4 (+ i3 1ul)))
#               (v2 (~ in4 (+ i3 2ul)))
#               (y0 (rgb-to-y (x~ v0) (y~ v0) (z~ v0)))
#               (y1 (rgb-to-y (w~ v0) (x~ v1) (y~ v1)))
#               (y2 (rgb-to-y (z~ v1) (w~ v1) (x~ v2)))
#               (y3 (rgb-to-y (y~ v2) (z~ v2) (w~ v2))))
#           (set! (~ out4 i) ##(y0 y1 y2 y3))))))
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
    uint64_t out_bytes = out_len * 4ULL;
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<5>;\n"
        "	.reg .b32 	%%cr_r<32>;\n"
        "	.reg .b64 	%%cr_rd<42>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd22, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd22;\n"
        "	mov.b64 	%%cr_rd23, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd23;\n"
        "	mov.b64 	%%cr_rd24, %2;\n"
        "	shr.u64 	%%cr_rd25, %%cr_rd24, 4;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%ntid.x;\n"
        "	mov.u32 	%%cr_r3, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd26, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd27, %%cr_r1, %%cr_r2;\n"
        "	add.s64 	%%cr_rd3, %%cr_rd27, %%cr_rd26;\n"
        "	mov.u32 	%%cr_r4, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd4, %%cr_r4, %%cr_r2;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd3, %%cr_rd25;\n"
        "	mov.b64 	%%cr_rd38, 0;\n"
        "	@%%cr_p1 bra 	$L__BB39_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd28, %%cr_rd3;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd25, %%cr_rd28;\n"
        "	or.b64 	%%cr_rd29, %%cr_rd5, %%cr_rd4;\n"
        "	and.b64 	%%cr_rd30, %%cr_rd29, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd30, 0;\n"
        "	@%%cr_p2 bra 	$L__BB39_3;\n"
        "	bra.uni 	$L__BB39_2;\n"
        "$L__BB39_3:\n"
        "	div.u64 	%%cr_rd37, %%cr_rd5, %%cr_rd4;\n"
        "	bra.uni 	$L__BB39_4;\n"
        "$L__BB39_2:\n"
        "	cvt.u32.u64 	%%cr_r5, %%cr_rd4;\n"
        "	cvt.u32.u64 	%%cr_r6, %%cr_rd5;\n"
        "	div.u32 	%%cr_r7, %%cr_r6, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd37, %%cr_r7;\n"
        "$L__BB39_4:\n"
        "	add.s64 	%%cr_rd38, %%cr_rd37, 1;\n"
        "$L__BB39_5:                             // %%ifcont\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd38, 0;\n"
        "	@%%cr_p3 bra 	$L__BB39_8;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	shl.b64 	%%cr_rd32, %%cr_rd3, 4;\n"
        "	add.s64 	%%cr_rd40, %%cr_rd2, %%cr_rd32;\n"
        "	shl.b64 	%%cr_rd12, %%cr_rd4, 4;\n"
        "	mad.lo.s64 	%%cr_rd39, %%cr_rd3, 48, %%cr_rd1;\n"
        "	mul.lo.s64 	%%cr_rd14, %%cr_rd4, 48;\n"
        "	mov.b64 	%%cr_rd41, 0;\n"
        "$L__BB39_7:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd33, %%cr_rd39, 16;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r8, %%cr_r9, %%cr_r10, %%cr_r11}, [%%cr_rd33];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd34, %%cr_rd39, 32;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r12, %%cr_r13, %%cr_r14, %%cr_r15}, [%%cr_rd34];\n"
        "	// end inline asm\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r16, %%cr_r17, %%cr_r18, %%cr_r19}, [%%cr_rd39];\n"
        "	// end inline asm\n"
        "	mul.rn.f32 	%%cr_r24, %%cr_r18, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r25, %%cr_r17, 0f3F1645A2, %%cr_r24;\n"
        "	fma.rn.f32 	%%cr_r20, %%cr_r16, 0f3E99096C, %%cr_r25;\n"
        "	mul.rn.f32 	%%cr_r26, %%cr_r9, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r27, %%cr_r8, 0f3F1645A2, %%cr_r26;\n"
        "	fma.rn.f32 	%%cr_r21, %%cr_r19, 0f3E99096C, %%cr_r27;\n"
        "	mul.rn.f32 	%%cr_r28, %%cr_r12, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r29, %%cr_r11, 0f3F1645A2, %%cr_r28;\n"
        "	fma.rn.f32 	%%cr_r22, %%cr_r10, 0f3E99096C, %%cr_r29;\n"
        "	mul.rn.f32 	%%cr_r30, %%cr_r15, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r31, %%cr_r14, 0f3F1645A2, %%cr_r30;\n"
        "	fma.rn.f32 	%%cr_r23, %%cr_r13, 0f3E99096C, %%cr_r31;\n"
        "	// begin inline asm\n"
        "	st.global.cs.v4.f32 [%%cr_rd40], {%%cr_r20, %%cr_r21, %%cr_r22, %%cr_r23};\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd41, %%cr_rd41, 1;\n"
        "	add.s64 	%%cr_rd40, %%cr_rd40, %%cr_rd12;\n"
        "	add.s64 	%%cr_rd39, %%cr_rd39, %%cr_rd14;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd41, %%cr_rd38;\n"
        "	@%%cr_p4 bra 	$L__BB39_7;\n"
        "$L__BB39_8:                             // %%dt_exit\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(in_ptr), "l"(out_ptr), "l"(out_bytes)
        : "memory"
    );
}

torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output) {
    int64_t N = output.numel();
    if (N <= 0) return output;

    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_grayscale_kernel, BLOCK_SIZE, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 4) : 1024;
    }
    int64_t needed_blocks = (N + (BLOCK_SIZE * 16) - 1) / (BLOCK_SIZE * 16);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

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
