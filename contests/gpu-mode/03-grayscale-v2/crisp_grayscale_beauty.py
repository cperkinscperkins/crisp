# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (grayscale_beauty.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 03: grayscale_v2 (Beauty Contestant)
#   ;; Converts contiguous (H, W, 3) RGB float32 tensor to (H, W) grayscale:
#   ;;   Y = 0.2989 * R + 0.5870 * G + 0.1140 * B
#
#   (def-type in-vec  (vector float :address-space :global :align :compact))
#   (def-type out-vec (vector float :address-space :global :align :compact))
#
#   (def-function rgb-to-y (r g b)
#     (declare #'(float float float => float))
#     (op-fma 0.2989 r (op-fma 0.5870 g (* 0.1140 b))))
#
#   (def-kernel grayscale_kernel (input &out output)
#     (declare #'(in-vec &out out-vec => nil)
#              (global-size :derive-from output :strategy :strided)
#              (local-size  :set-to 256))
#     (loop-vector-stride output (i)
#       (let ((i3 (* i 3ul)))
#         (set! (~ output i)
#               (rgb-to-y (~ input i3)
#                         (~ input (+ i3 1ul))
#                         (~ input (+ i3 2ul)))))))
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
        "	.reg .pred 	%%cr_p<8>;\n"
        "	.reg .b32 	%%cr_r<38>;\n"
        "	.reg .b64 	%%cr_rd<90>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd47, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd47;\n"
        "	mov.b64 	%%cr_rd48, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd48;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%ntid.x;\n"
        "	mov.u32 	%%cr_r3, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd6, %%cr_r1, %%cr_r2;\n"
        "	mov.b64 	%%cr_rd49, %2;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd6, %%cr_rd5;\n"
        "	mov.u32 	%%cr_r4, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd9, %%cr_r4, %%cr_r2;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd7, %%cr_rd49;\n"
        "	mov.b64 	%%cr_rd82, 0;\n"
        "	@%%cr_p1 bra 	$L__BB25_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd50, %%cr_rd7;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd49, %%cr_rd50;\n"
        "	or.b64 	%%cr_rd51, %%cr_rd10, %%cr_rd9;\n"
        "	and.b64 	%%cr_rd52, %%cr_rd51, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd52, 0;\n"
        "	@%%cr_p2 bra 	$L__BB25_3;\n"
        "	bra.uni 	$L__BB25_2;\n"
        "$L__BB25_3:\n"
        "	div.u64 	%%cr_rd81, %%cr_rd10, %%cr_rd9;\n"
        "	bra.uni 	$L__BB25_4;\n"
        "$L__BB25_2:\n"
        "	cvt.u32.u64 	%%cr_r5, %%cr_rd9;\n"
        "	cvt.u32.u64 	%%cr_r6, %%cr_rd10;\n"
        "	div.u32 	%%cr_r7, %%cr_r6, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd81, %%cr_r7;\n"
        "$L__BB25_4:\n"
        "	add.s64 	%%cr_rd82, %%cr_rd81, 1;\n"
        "$L__BB25_5:                             // %%ifcont\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd82, 0;\n"
        "	@%%cr_p3 bra 	$L__BB25_12;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd3, %%cr_r1;\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r2;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r4;\n"
        "	and.b64 	%%cr_rd87, %%cr_rd82, 3;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd82, 4;\n"
        "	mov.b64 	%%cr_rd86, 0;\n"
        "	@%%cr_p4 bra 	$L__BB25_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd17, %%cr_rd82, -4;\n"
        "	mad.lo.s64 	%%cr_rd18, %%cr_rd7, 12, 8;\n"
        "	mul.lo.s64 	%%cr_rd19, %%cr_rd9, 48;\n"
        "	add.s64 	%%cr_rd55, %%cr_rd3, %%cr_rd8;\n"
        "	mul.lo.s64 	%%cr_rd56, %%cr_rd55, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd57, %%cr_rd56, %%cr_rd5;\n"
        "	mul.lo.s64 	%%cr_rd20, %%cr_rd57, 12;\n"
        "	shl.b64 	%%cr_rd58, %%cr_rd56, 2;\n"
        "	add.s64 	%%cr_rd21, %%cr_rd2, %%cr_rd58;\n"
        "	shl.b64 	%%cr_rd83, %%cr_rd5, 2;\n"
        "	shl.b64 	%%cr_rd23, %%cr_rd9, 4;\n"
        "	shl.b64 	%%cr_rd59, %%cr_rd6, 2;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd2, %%cr_rd59;\n"
        "	mad.lo.s64 	%%cr_rd60, %%cr_rd8, 3, %%cr_rd3;\n"
        "	mul.lo.s64 	%%cr_rd61, %%cr_rd60, %%cr_rd4;\n"
        "	shl.b64 	%%cr_rd62, %%cr_rd61, 2;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd2, %%cr_rd62;\n"
        "	shl.b64 	%%cr_rd63, %%cr_rd8, 1;\n"
        "	add.s64 	%%cr_rd64, %%cr_rd63, %%cr_rd3;\n"
        "	mul.lo.s64 	%%cr_rd65, %%cr_rd64, %%cr_rd4;\n"
        "	mul.lo.s64 	%%cr_rd66, %%cr_rd5, 12;\n"
        "	mad.lo.s64 	%%cr_rd26, %%cr_rd65, 12, %%cr_rd66;\n"
        "	shl.b64 	%%cr_rd67, %%cr_rd65, 2;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd2, %%cr_rd67;\n"
        "	mad.lo.s64 	%%cr_rd68, %%cr_rd61, 12, %%cr_rd66;\n"
        "	add.s64 	%%cr_rd28, %%cr_rd68, 4;\n"
        "	mov.b64 	%%cr_rd86, 0;\n"
        "	mov.b64 	%%cr_rd84, %%cr_rd1;\n"
        "$L__BB25_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd69, %%cr_rd84, %%cr_rd18;\n"
        "	ld.global.nc.b32 	%%cr_r8, [%%cr_rd69+-8];\n"
        "	ld.global.nc.b32 	%%cr_r9, [%%cr_rd69+-4];\n"
        "	ld.global.nc.b32 	%%cr_r10, [%%cr_rd69];\n"
        "	mul.rn.f32 	%%cr_r11, %%cr_r10, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r12, %%cr_r9, 0f3F1645A2, %%cr_r11;\n"
        "	fma.rn.f32 	%%cr_r13, %%cr_r8, 0f3E99096C, %%cr_r12;\n"
        "	add.s64 	%%cr_rd70, %%cr_rd24, %%cr_rd83;\n"
        "	st.global.b32 	[%%cr_rd70], %%cr_r13;\n"
        "	add.s64 	%%cr_rd71, %%cr_rd84, %%cr_rd20;\n"
        "	ld.global.nc.b32 	%%cr_r14, [%%cr_rd71];\n"
        "	ld.global.nc.b32 	%%cr_r15, [%%cr_rd71+4];\n"
        "	ld.global.nc.b32 	%%cr_r16, [%%cr_rd71+8];\n"
        "	mul.rn.f32 	%%cr_r17, %%cr_r16, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r18, %%cr_r15, 0f3F1645A2, %%cr_r17;\n"
        "	fma.rn.f32 	%%cr_r19, %%cr_r14, 0f3E99096C, %%cr_r18;\n"
        "	add.s64 	%%cr_rd72, %%cr_rd21, %%cr_rd83;\n"
        "	st.global.b32 	[%%cr_rd72], %%cr_r19;\n"
        "	add.s64 	%%cr_rd73, %%cr_rd84, %%cr_rd26;\n"
        "	ld.global.nc.b32 	%%cr_r20, [%%cr_rd73];\n"
        "	ld.global.nc.b32 	%%cr_r21, [%%cr_rd73+4];\n"
        "	ld.global.nc.b32 	%%cr_r22, [%%cr_rd73+8];\n"
        "	mul.rn.f32 	%%cr_r23, %%cr_r22, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r24, %%cr_r21, 0f3F1645A2, %%cr_r23;\n"
        "	fma.rn.f32 	%%cr_r25, %%cr_r20, 0f3E99096C, %%cr_r24;\n"
        "	add.s64 	%%cr_rd74, %%cr_rd27, %%cr_rd83;\n"
        "	st.global.b32 	[%%cr_rd74], %%cr_r25;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd84, %%cr_rd28;\n"
        "	ld.global.nc.b32 	%%cr_r26, [%%cr_rd75+-4];\n"
        "	ld.global.nc.b32 	%%cr_r27, [%%cr_rd75];\n"
        "	ld.global.nc.b32 	%%cr_r28, [%%cr_rd75+4];\n"
        "	mul.rn.f32 	%%cr_r29, %%cr_r28, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r30, %%cr_r27, 0f3F1645A2, %%cr_r29;\n"
        "	fma.rn.f32 	%%cr_r31, %%cr_r26, 0f3E99096C, %%cr_r30;\n"
        "	add.s64 	%%cr_rd76, %%cr_rd25, %%cr_rd83;\n"
        "	st.global.b32 	[%%cr_rd76], %%cr_r31;\n"
        "	add.s64 	%%cr_rd86, %%cr_rd86, 4;\n"
        "	add.s64 	%%cr_rd84, %%cr_rd84, %%cr_rd19;\n"
        "	add.s64 	%%cr_rd83, %%cr_rd83, %%cr_rd23;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd17, %%cr_rd86;\n"
        "	@%%cr_p5 bra 	$L__BB25_8;\n"
        "$L__BB25_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd87, 0;\n"
        "	@%%cr_p6 bra 	$L__BB25_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd77, %%cr_rd86, %%cr_rd8, %%cr_rd3;\n"
        "	mad.lo.s64 	%%cr_rd78, %%cr_rd77, %%cr_rd4, %%cr_rd5;\n"
        "	shl.b64 	%%cr_rd79, %%cr_rd78, 2;\n"
        "	add.s64 	%%cr_rd89, %%cr_rd2, %%cr_rd79;\n"
        "	shl.b64 	%%cr_rd37, %%cr_rd9, 2;\n"
        "	mad.lo.s64 	%%cr_rd80, %%cr_rd78, 12, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd88, %%cr_rd80, 8;\n"
        "	mul.lo.s64 	%%cr_rd39, %%cr_rd9, 12;\n"
        "$L__BB25_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.nc.b32 	%%cr_r32, [%%cr_rd88+-8];\n"
        "	ld.global.nc.b32 	%%cr_r33, [%%cr_rd88+-4];\n"
        "	ld.global.nc.b32 	%%cr_r34, [%%cr_rd88];\n"
        "	mul.rn.f32 	%%cr_r35, %%cr_r34, 0f3DE978D5;\n"
        "	fma.rn.f32 	%%cr_r36, %%cr_r33, 0f3F1645A2, %%cr_r35;\n"
        "	fma.rn.f32 	%%cr_r37, %%cr_r32, 0f3E99096C, %%cr_r36;\n"
        "	st.global.b32 	[%%cr_rd89], %%cr_r37;\n"
        "	add.s64 	%%cr_rd89, %%cr_rd89, %%cr_rd37;\n"
        "	add.s64 	%%cr_rd88, %%cr_rd88, %%cr_rd39;\n"
        "	add.s64 	%%cr_rd87, %%cr_rd87, -1;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd87, 0;\n"
        "	@%%cr_p7 bra 	$L__BB25_11;\n"
        "$L__BB25_12:                            // %%dt_exit\n"
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
    static int max_grid = 0;
    if (max_grid <= 0) {
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_grayscale_kernel, BLOCK_SIZE, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 4) : 1024;
    }
    int64_t needed_blocks = (N + (BLOCK_SIZE * 4) - 1) / (BLOCK_SIZE * 4);
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
