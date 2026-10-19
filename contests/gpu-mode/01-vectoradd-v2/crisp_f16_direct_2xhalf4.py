# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_direct_2xhalf4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectoradd_v2 (Direct 2x half4 per thread, +256 stride)
#   ;; Each block of 256 threads processes 512 half4s (2048 halfs = 4 KB) at offsets +0 and +256
#   ;; using PTX constant immediate displacement [+2048], issuing both 64-bit loads before storing.
#
#   (def-type in-vec  (vector half :address-space :global :align :compact))
#   (def-type out-vec (vector half :address-space :global :align :compact))
#
#   (def-kernel vector_add_f16 (A B &out C)
#     (declare #'(in-vec in-vec &out out-vec => nil)
#              (global-size :derive-from A :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((bid  (to-ulong (get-workgroup-id 0)))
#           (tid  (to-ulong (get-local-id 0)))
#           (base (+ (* bid 512ul) tid))
#           (n    (length~ A))
#           (n4   (/ n 4ul))
#           (a4   (make-vector A half4 :length n4))
#           (b4   (make-vector B half4 :length n4))
#           (c4   (make-vector C half4 :length n4)))
#       (if (< (+ (* bid 512ul) 511ul) n4)
#           (let ((v0 (+ (~ a4 base)           (~ b4 base)))
#                 (v1 (+ (~ a4 (+ base 256ul)) (~ b4 (+ base 256ul)))))
#             (set! (~ c4 base)           v0)
#             (set! (~ c4 (+ base 256ul)) v1))
#           (progn
#             (when (< base n4)
#               (set! (~ c4 base) (+ (~ a4 base) (~ b4 base))))
#             (when (< (+ base 256ul) n4)
#               (set! (~ c4 (+ base 256ul)) (+ (~ a4 (+ base 256ul)) (~ b4 (+ base 256ul)))))
#             (let ((tail (+ (* n4 4ul) tid)))
#               (when (and (= bid 0ul) (< tail n))
#                 (set! (~ C tail) (+ (~ A tail) (~ B tail)))))))))
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
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<7>;\n"
        "	.reg .b16 	%%cr_rs<4>;\n"
        "	.reg .b32 	%%cr_r<27>;\n"
        "	.reg .b64 	%%cr_rd<33>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd16, %1;\n"
        "	mov.b64 	%%cr_rd17, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd17;\n"
        "	mov.b64 	%%cr_rd18, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd18;\n"
        "	mov.b64 	%%cr_rd19, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd19;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r2;\n"
        "	mul.wide.u32 	%%cr_rd20, %%cr_r1, 512;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd20, %%cr_rd4;\n"
        "	shr.u64 	%%cr_rd6, %%cr_rd16, 2;\n"
        "	or.b64 	%%cr_rd21, %%cr_rd20, 511;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd21, %%cr_rd6;\n"
        "	@%%cr_p1 bra 	$L__BB38_3;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%cr_rd29, %%cr_rd5, 3;\n"
        "	add.s64 	%%cr_rd30, %%cr_rd1, %%cr_rd29;\n"
        "	ld.global.v2.b32 	{%%cr_r15, %%cr_r16}, [%%cr_rd30];\n"
        "	add.s64 	%%cr_rd31, %%cr_rd2, %%cr_rd29;\n"
        "	ld.global.v2.b32 	{%%cr_r17, %%cr_r18}, [%%cr_rd31];\n"
        "	add.rn.f16x2 	%%cr_r19, %%cr_r16, %%cr_r18;\n"
        "	add.rn.f16x2 	%%cr_r20, %%cr_r15, %%cr_r17;\n"
        "	ld.global.v2.b32 	{%%cr_r21, %%cr_r22}, [%%cr_rd30+2048];\n"
        "	ld.global.v2.b32 	{%%cr_r23, %%cr_r24}, [%%cr_rd31+2048];\n"
        "	add.rn.f16x2 	%%cr_r25, %%cr_r22, %%cr_r24;\n"
        "	add.rn.f16x2 	%%cr_r26, %%cr_r21, %%cr_r23;\n"
        "	add.s64 	%%cr_rd32, %%cr_rd3, %%cr_rd29;\n"
        "	st.global.v2.b32 	[%%cr_rd32], {%%cr_r20, %%cr_r19};\n"
        "	st.global.v2.b32 	[%%cr_rd32+2048], {%%cr_r26, %%cr_r25};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_3:                             // %%else\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd5, %%cr_rd6;\n"
        "	@%%cr_p2 bra 	$L__BB38_4;\n"
        "	bra.uni 	$L__BB38_5;\n"
        "$L__BB38_4:                             // %%then130\n"
        "	shl.b64 	%%cr_rd22, %%cr_rd5, 3;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd3, %%cr_rd22;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd2, %%cr_rd22;\n"
        "	add.s64 	%%cr_rd9, %%cr_rd1, %%cr_rd22;\n"
        "	ld.global.v2.b32 	{%%cr_r3, %%cr_r4}, [%%cr_rd9];\n"
        "	ld.global.v2.b32 	{%%cr_r5, %%cr_r6}, [%%cr_rd8];\n"
        "	add.rn.f16x2 	%%cr_r7, %%cr_r4, %%cr_r6;\n"
        "	add.rn.f16x2 	%%cr_r8, %%cr_r3, %%cr_r5;\n"
        "	st.global.v2.b32 	[%%cr_rd7], {%%cr_r8, %%cr_r7};\n"
        "$L__BB38_5:                             // %%ifcont132\n"
        "	add.s64 	%%cr_rd23, %%cr_rd5, 256;\n"
        "	setp.ge.u64 	%%cr_p3, %%cr_rd23, %%cr_rd6;\n"
        "	@%%cr_p3 bra 	$L__BB38_7;\n"
        "// %%bb.6:                               // %%then161\n"
        "	shl.b64 	%%cr_rd24, %%cr_rd23, 3;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd3, %%cr_rd24;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd2, %%cr_rd24;\n"
        "	add.s64 	%%cr_rd12, %%cr_rd1, %%cr_rd24;\n"
        "	ld.global.v2.b32 	{%%cr_r9, %%cr_r10}, [%%cr_rd12];\n"
        "	ld.global.v2.b32 	{%%cr_r11, %%cr_r12}, [%%cr_rd11];\n"
        "	add.rn.f16x2 	%%cr_r13, %%cr_r10, %%cr_r12;\n"
        "	add.rn.f16x2 	%%cr_r14, %%cr_r9, %%cr_r11;\n"
        "	st.global.v2.b32 	[%%cr_rd10], {%%cr_r14, %%cr_r13};\n"
        "$L__BB38_7:                             // %%ifcont163\n"
        "	and.b64 	%%cr_rd25, %%cr_rd16, -4;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd25, %%cr_rd4;\n"
        "	setp.ne.b32 	%%cr_p4, %%cr_r1, 0;\n"
        "	setp.ge.u64 	%%cr_p5, %%cr_rd27, %%cr_rd16;\n"
        "	or.pred 	%%cr_p6, %%cr_p4, %%cr_p5;\n"
        "	@%%cr_p6 bra 	$L__BB38_2;\n"
        "// %%bb.8:                               // %%then205\n"
        "	shl.b64 	%%cr_rd28, %%cr_rd27, 1;\n"
        "	add.s64 	%%cr_rd13, %%cr_rd3, %%cr_rd28;\n"
        "	add.s64 	%%cr_rd14, %%cr_rd2, %%cr_rd28;\n"
        "	add.s64 	%%cr_rd15, %%cr_rd1, %%cr_rd28;\n"
        "	ld.global.nc.b16 	%%cr_rs1, [%%cr_rd15];\n"
        "	ld.global.nc.b16 	%%cr_rs2, [%%cr_rd14];\n"
        "	add.rn.f16 	%%cr_rs3, %%cr_rs1, %%cr_rs2;\n"
        "	st.global.b16 	[%%cr_rd13], %%cr_rs3;\n"
        "$L__BB38_2:                             // %%ifcont\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(a_ptr), "l"(len), "l"(b_ptr), "l"(c_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B, torch::Tensor C) {
    int64_t N = A.numel();
    if (N <= 0) return C;

    constexpr int BLOCK_SIZE = 256;
    int64_t needed_blocks = ((N >> 2) + 511) / 512;
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);

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
