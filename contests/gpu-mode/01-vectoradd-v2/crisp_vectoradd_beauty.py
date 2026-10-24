# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_beauty.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 01: vectoradd_v2 (Beauty Contestant)
#   ;; Idiomatic Crisp: Vectorized views with loop-vector-stride
#   (def-type half-vec (vector half :address-space :global :align :compact))
#
#   (def-kernel vector_add_f16 (A B &out C)
#     (declare #'(half-vec half-vec &out half-vec => nil)
#              (global-size :derive-from A :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((n  (length~ A))
#           (n4 (/ n 4ul))
#           (a4 (make-vector A half4 :length n4))
#           (b4 (make-vector B half4 :length n4))
#           (c4 (make-vector C half4 :length n4)))
#       ;; 64-bit vectorized grid-stride loop
#       (loop-vector-stride a4 (i)
#         (set! (~ c4 i) (+ (~ a4 i) (~ b4 i))))
#       ;; Tail for non-multiples of 4
#       (let ((tail (+ (* n4 4ul) (get-global-id 0))))
#         (when (< tail n)
#           (set! (~ C tail) (+ (~ A tail) (~ B tail)))))))
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
void crisp_vector_add_f16_kernel(
    uint64_t a_ptr,
    uint64_t b_ptr,
    uint64_t c_ptr,
    uint64_t len
) {
    uint64_t bytes = len * 2ULL;
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<9>;\n"
        "	.reg .b16 	%%cr_rs<4>;\n"
        "	.reg .b32 	%%cr_r<38>;\n"
        "	.reg .b64 	%%cr_rd<99>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd46, %2;\n"
        "	mov.b64 	%%cr_rd48, %0;\n"
        "	mov.b64 	%%cr_rd49, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd48;\n"
        "	mov.b64 	%%cr_rd50, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd50;\n"
        "	mov.b64 	%%cr_rd51, %4;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd51;\n"
        "	shr.u64 	%%cr_rd52, %%cr_rd49, 3;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%ntid.x;\n"
        "	mov.u32 	%%cr_r3, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd53, %%cr_r1, %%cr_r2;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd53, %%cr_rd7;\n"
        "	mov.u32 	%%cr_r4, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd10, %%cr_r4, %%cr_r2;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd8, %%cr_rd52;\n"
        "	mov.b64 	%%cr_rd93, 0;\n"
        "	@%%cr_p1 bra 	$L__BB38_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd54, %%cr_rd8;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd52, %%cr_rd54;\n"
        "	or.b64 	%%cr_rd55, %%cr_rd11, %%cr_rd10;\n"
        "	and.b64 	%%cr_rd56, %%cr_rd55, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd56, 0;\n"
        "	@%%cr_p2 bra 	$L__BB38_3;\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_3:\n"
        "	div.u64 	%%cr_rd92, %%cr_rd11, %%cr_rd10;\n"
        "	bra.uni 	$L__BB38_4;\n"
        "$L__BB38_2:\n"
        "	cvt.u32.u64 	%%cr_r5, %%cr_rd10;\n"
        "	cvt.u32.u64 	%%cr_r6, %%cr_rd11;\n"
        "	div.u32 	%%cr_r7, %%cr_r6, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd92, %%cr_r7;\n"
        "$L__BB38_4:\n"
        "	add.s64 	%%cr_rd93, %%cr_rd92, 1;\n"
        "$L__BB38_5:                             // %%ifcont\n"
        "	and.b64 	%%cr_rd4, %%cr_rd46, -4;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd93, 0;\n"
        "	@%%cr_p3 bra 	$L__BB38_12;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r1;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r2;\n"
        "	cvt.u64.u32 	%%cr_rd9, %%cr_r4;\n"
        "	and.b64 	%%cr_rd97, %%cr_rd93, 3;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd93, 4;\n"
        "	mov.b64 	%%cr_rd96, 0;\n"
        "	@%%cr_p4 bra 	$L__BB38_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd18, %%cr_rd93, -4;\n"
        "	add.s64 	%%cr_rd59, %%cr_rd5, %%cr_rd9;\n"
        "	mad.lo.s64 	%%cr_rd60, %%cr_rd59, %%cr_rd6, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd61, %%cr_rd60, 3;\n"
        "	add.s64 	%%cr_rd19, %%cr_rd3, %%cr_rd61;\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd10, 5;\n"
        "	add.s64 	%%cr_rd21, %%cr_rd2, %%cr_rd61;\n"
        "	add.s64 	%%cr_rd22, %%cr_rd1, %%cr_rd61;\n"
        "	shl.b64 	%%cr_rd62, %%cr_rd9, 1;\n"
        "	add.s64 	%%cr_rd63, %%cr_rd62, %%cr_rd5;\n"
        "	mul.lo.s64 	%%cr_rd64, %%cr_rd63, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd65, %%cr_rd64, 3;\n"
        "	shl.b64 	%%cr_rd66, %%cr_rd7, 3;\n"
        "	add.s64 	%%cr_rd67, %%cr_rd65, %%cr_rd66;\n"
        "	add.s64 	%%cr_rd23, %%cr_rd3, %%cr_rd67;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd2, %%cr_rd67;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd1, %%cr_rd67;\n"
        "	mad.lo.s64 	%%cr_rd68, %%cr_rd9, 3, %%cr_rd5;\n"
        "	mul.lo.s64 	%%cr_rd69, %%cr_rd68, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd70, %%cr_rd69, 3;\n"
        "	add.s64 	%%cr_rd71, %%cr_rd70, %%cr_rd66;\n"
        "	add.s64 	%%cr_rd26, %%cr_rd3, %%cr_rd71;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd2, %%cr_rd71;\n"
        "	add.s64 	%%cr_rd28, %%cr_rd1, %%cr_rd71;\n"
        "	shl.b64 	%%cr_rd72, %%cr_rd8, 3;\n"
        "	add.s64 	%%cr_rd29, %%cr_rd3, %%cr_rd72;\n"
        "	add.s64 	%%cr_rd30, %%cr_rd2, %%cr_rd72;\n"
        "	add.s64 	%%cr_rd31, %%cr_rd1, %%cr_rd72;\n"
        "	mov.b64 	%%cr_rd94, 0;\n"
        "	mov.b64 	%%cr_rd96, %%cr_rd94;\n"
        "$L__BB38_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd73, %%cr_rd31, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r8, %%cr_r9}, [%%cr_rd73];\n"
        "	add.s64 	%%cr_rd74, %%cr_rd30, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r10, %%cr_r11}, [%%cr_rd74];\n"
        "	add.rn.f16x2 	%%cr_r12, %%cr_r9, %%cr_r11;\n"
        "	add.rn.f16x2 	%%cr_r13, %%cr_r8, %%cr_r10;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd29, %%cr_rd94;\n"
        "	st.global.v2.b32 	[%%cr_rd75], {%%cr_r13, %%cr_r12};\n"
        "	add.s64 	%%cr_rd76, %%cr_rd22, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r14, %%cr_r15}, [%%cr_rd76];\n"
        "	add.s64 	%%cr_rd77, %%cr_rd21, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r16, %%cr_r17}, [%%cr_rd77];\n"
        "	add.rn.f16x2 	%%cr_r18, %%cr_r15, %%cr_r17;\n"
        "	add.rn.f16x2 	%%cr_r19, %%cr_r14, %%cr_r16;\n"
        "	add.s64 	%%cr_rd78, %%cr_rd19, %%cr_rd94;\n"
        "	st.global.v2.b32 	[%%cr_rd78], {%%cr_r19, %%cr_r18};\n"
        "	add.s64 	%%cr_rd79, %%cr_rd25, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r20, %%cr_r21}, [%%cr_rd79];\n"
        "	add.s64 	%%cr_rd80, %%cr_rd24, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r22, %%cr_r23}, [%%cr_rd80];\n"
        "	add.rn.f16x2 	%%cr_r24, %%cr_r21, %%cr_r23;\n"
        "	add.rn.f16x2 	%%cr_r25, %%cr_r20, %%cr_r22;\n"
        "	add.s64 	%%cr_rd81, %%cr_rd23, %%cr_rd94;\n"
        "	st.global.v2.b32 	[%%cr_rd81], {%%cr_r25, %%cr_r24};\n"
        "	add.s64 	%%cr_rd82, %%cr_rd28, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r26, %%cr_r27}, [%%cr_rd82];\n"
        "	add.s64 	%%cr_rd83, %%cr_rd27, %%cr_rd94;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r28, %%cr_r29}, [%%cr_rd83];\n"
        "	add.rn.f16x2 	%%cr_r30, %%cr_r27, %%cr_r29;\n"
        "	add.rn.f16x2 	%%cr_r31, %%cr_r26, %%cr_r28;\n"
        "	add.s64 	%%cr_rd84, %%cr_rd26, %%cr_rd94;\n"
        "	st.global.v2.b32 	[%%cr_rd84], {%%cr_r31, %%cr_r30};\n"
        "	add.s64 	%%cr_rd96, %%cr_rd96, 4;\n"
        "	add.s64 	%%cr_rd94, %%cr_rd94, %%cr_rd20;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd18, %%cr_rd96;\n"
        "	@%%cr_p5 bra 	$L__BB38_8;\n"
        "$L__BB38_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd97, 0;\n"
        "	@%%cr_p6 bra 	$L__BB38_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd85, %%cr_rd96, %%cr_rd9, %%cr_rd5;\n"
        "	mad.lo.s64 	%%cr_rd86, %%cr_rd85, %%cr_rd6, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd98, %%cr_rd86, 3;\n"
        "	shl.b64 	%%cr_rd38, %%cr_rd10, 3;\n"
        "$L__BB38_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	add.s64 	%%cr_rd87, %%cr_rd1, %%cr_rd98;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r32, %%cr_r33}, [%%cr_rd87];\n"
        "	add.s64 	%%cr_rd88, %%cr_rd2, %%cr_rd98;\n"
        "	ld.global.nc.v2.b32 	{%%cr_r34, %%cr_r35}, [%%cr_rd88];\n"
        "	add.rn.f16x2 	%%cr_r36, %%cr_r33, %%cr_r35;\n"
        "	add.rn.f16x2 	%%cr_r37, %%cr_r32, %%cr_r34;\n"
        "	add.s64 	%%cr_rd89, %%cr_rd3, %%cr_rd98;\n"
        "	st.global.v2.b32 	[%%cr_rd89], {%%cr_r37, %%cr_r36};\n"
        "	add.s64 	%%cr_rd98, %%cr_rd98, %%cr_rd38;\n"
        "	add.s64 	%%cr_rd97, %%cr_rd97, -1;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd97, 0;\n"
        "	@%%cr_p7 bra 	$L__BB38_11;\n"
        "$L__BB38_12:                            // %%dt_exit\n"
        "	add.s64 	%%cr_rd90, %%cr_rd4, %%cr_rd8;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd90, %%cr_rd46;\n"
        "	@%%cr_p8 bra 	$L__BB38_14;\n"
        "// %%bb.13:                              // %%then166\n"
        "	shl.b64 	%%cr_rd91, %%cr_rd90, 1;\n"
        "	add.s64 	%%cr_rd43, %%cr_rd3, %%cr_rd91;\n"
        "	add.s64 	%%cr_rd44, %%cr_rd2, %%cr_rd91;\n"
        "	add.s64 	%%cr_rd45, %%cr_rd1, %%cr_rd91;\n"
        "	ld.global.nc.b16 	%%cr_rs1, [%%cr_rd45];\n"
        "	ld.global.nc.b16 	%%cr_rs2, [%%cr_rd44];\n"
        "	add.rn.f16 	%%cr_rs3, %%cr_rs1, %%cr_rs2;\n"
        "	st.global.b16 	[%%cr_rd43], %%cr_rs3;\n"
        "$L__BB38_14:                            // %%ifcont168\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(a_ptr), "l"(bytes), "l"(len), "l"(b_ptr), "l"(c_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B, torch::Tensor C) {
    int64_t N = A.numel();
    if (N <= 0) return C;

    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(
            &blocks_per_sm, crisp_vector_add_f16_kernel, BLOCK_SIZE, 0);
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 1) : 1024;
    }

    int64_t needed_blocks = (N + (BLOCK_SIZE * 4) - 1) / (BLOCK_SIZE * 4);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    crisp_vector_add_f16_kernel<<<grid_x, BLOCK_SIZE>>>(
        reinterpret_cast<uint64_t>(A.data_ptr()),
        reinterpret_cast<uint64_t>(B.data_ptr()),
        reinterpret_cast<uint64_t>(C.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return C;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B, torch::Tensor C);"""

_crisp_mod = load_inline(
    name="crisp_vectoradd_f16_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vector_add_f16"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    A, B, output = data
    return _crisp_mod.launch_crisp_vector_add_f16(A, B, output)
