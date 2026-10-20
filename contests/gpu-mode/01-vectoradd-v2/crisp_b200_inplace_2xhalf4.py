# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_b200_inplace_2xhalf4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectoradd_v2 (B200 In-Place Variant 2: Direct 2x half4 = 16B per thread)
#   ;; Uses def-hardware-profile for B200 and in-place read-modify-write (B A) with 2x half4
#   ;; per thread at constant +256 stride ([+2048] immediate displacement), halving CTA count.
#
#   (def-hardware-profile b200
#     :simd-width 32
#     :compute-units 148
#     :max-registers-per-cu 65536
#     :max-registers-per-thread 255
#     :max-total-threads-per-block 1024
#     :max-work-group-dims '(1024 1024 64)
#     :max-shared-memory-per-block 227KB
#     :l2-cache-size 128MB
#     :native-cache-line-size 128
#     :mma-shapes '((16 8 8) (16 8 4) (16 8 16) (:double 8 8 4)))
#
#   (def-type in-vec    (vector half :address-space :global :align :compact))
#   (def-type inout-vec (vector half :address-space :global :align :compact))
#
#   (def-kernel vector_add_f16 (B A)
#     (declare #'(in-vec inout-vec => nil)
#              (global-size :derive-from B :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((bid  (to-ulong (get-workgroup-id 0)))
#           (tid  (to-ulong (get-local-id 0)))
#           (base (+ (* bid 512ul) tid))
#           (n    (length~ B))
#           (n4   (/ n 4ul))
#           (b4   (make-vector B half4 :length n4))
#           (a4   (make-vector A half4 :length n4)))
#       (if (< (+ (* bid 512ul) 511ul) n4)
#           (let ((v0 (+ (~ a4 base)           (~ b4 base)))
#                 (v1 (+ (~ a4 (+ base 256ul)) (~ b4 (+ base 256ul)))))
#             (set! (~ a4 base)           v0)
#             (set! (~ a4 (+ base 256ul)) v1))
#           (progn
#             (if (< base n4)
#                 (set! (~ a4 base) (+ (~ a4 base) (~ b4 base)))
#                 (let ((tail0 (+ (* n4 4ul) (- base n4))))
#                   (when (< tail0 n)
#                     (set! (~ A tail0) (+ (~ A tail0) (~ B tail0))))))
#             (let ((idx1 (+ base 256ul)))
#               (if (< idx1 n4)
#                   (set! (~ a4 idx1) (+ (~ a4 idx1) (~ b4 idx1)))
#                   (let ((tail1 (+ (* n4 4ul) (- idx1 n4))))
#                     (when (< tail1 n)
#                       (set! (~ A tail1) (+ (~ A tail1) (~ B tail1)))))))))))
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
    uint64_t len
) {
    asm volatile(
        "{\n"
        "	.reg .pred 	%%p<6>;\n"
        "	.reg .b16 	%%rs<7>;\n"
        "	.reg .b32 	%%r<27>;\n"
        "	.reg .b64 	%%rd<34>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%rd10, %1;\n"
        "	mov.b64 	%%rd11, %0;\n"
        "	cvta.to.global.u64 	%%rd1, %%rd11;\n"
        "	mov.b64 	%%rd12, %2;\n"
        "	cvta.to.global.u64 	%%rd2, %%rd12;\n"
        "	mov.u32 	%%r1, %%ctaid.x;\n"
        "	mov.u32 	%%r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%rd13, %%r2;\n"
        "	mul.wide.u32 	%%rd14, %%r1, 512;\n"
        "	add.s64 	%%rd3, %%rd14, %%rd13;\n"
        "	shr.u64 	%%rd4, %%rd10, 2;\n"
        "	or.b64 	%%rd15, %%rd14, 511;\n"
        "	setp.ge.u64 	%%p1, %%rd15, %%rd4;\n"
        "	@%%p1 bra 	$L__BB38_4;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%rd30, %%rd3, 3;\n"
        "	add.s64 	%%rd31, %%rd2, %%rd30;\n"
        "	ld.global.v2.b32 	{%%r15, %%r16}, [%%rd31];\n"
        "	add.s64 	%%rd32, %%rd1, %%rd30;\n"
        "	ld.global.v2.b32 	{%%r17, %%r18}, [%%rd32];\n"
        "	add.rn.f16x2 	%%r19, %%r16, %%r18;\n"
        "	add.rn.f16x2 	%%r20, %%r15, %%r17;\n"
        "	ld.global.v2.b32 	{%%r21, %%r22}, [%%rd31+2048];\n"
        "	ld.global.v2.b32 	{%%r23, %%r24}, [%%rd32+2048];\n"
        "	add.rn.f16x2 	%%r25, %%r22, %%r24;\n"
        "	add.rn.f16x2 	%%r26, %%r21, %%r23;\n"
        "	st.global.v2.b32 	[%%rd31], {%%r20, %%r19};\n"
        "	st.global.v2.b32 	[%%rd31+2048], {%%r26, %%r25};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_4:                             // %%else\n"
        "	setp.lt.u64 	%%p2, %%rd3, %%rd4;\n"
        "	and.b64 	%%rd33, %%rd10, -4;\n"
        "	@%%p2 bra 	$L__BB38_3;\n"
        "	bra.uni 	$L__BB38_5;\n"
        "$L__BB38_3:                             // %%then100\n"
        "	shl.b64 	%%rd20, %%rd3, 3;\n"
        "	add.s64 	%%rd21, %%rd2, %%rd20;\n"
        "	ld.global.v2.b32 	{%%r3, %%r4}, [%%rd21];\n"
        "	add.s64 	%%rd22, %%rd1, %%rd20;\n"
        "	ld.global.v2.b32 	{%%r5, %%r6}, [%%rd22];\n"
        "	add.rn.f16x2 	%%r7, %%r4, %%r6;\n"
        "	add.rn.f16x2 	%%r8, %%r3, %%r5;\n"
        "	st.global.v2.b32 	[%%rd21], {%%r8, %%r7};\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_5:                             // %%else101\n"
        "	sub.s64 	%%rd17, %%rd3, %%rd4;\n"
        "	add.s64 	%%rd18, %%rd17, %%rd33;\n"
        "	setp.lt.u64 	%%p3, %%rd18, %%rd10;\n"
        "	@%%p3 bra 	$L__BB38_10;\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_10:                            // %%then136\n"
        "	shl.b64 	%%rd19, %%rd18, 1;\n"
        "	add.s64 	%%rd5, %%rd1, %%rd19;\n"
        "	add.s64 	%%rd6, %%rd2, %%rd19;\n"
        "	ld.global.b16 	%%rs1, [%%rd6];\n"
        "	ld.global.b16 	%%rs2, [%%rd5];\n"
        "	add.rn.f16 	%%rs3, %%rs1, %%rs2;\n"
        "	st.global.b16 	[%%rd6], %%rs3;\n"
        "$L__BB38_6:                             // %%ifcont102\n"
        "	add.s64 	%%rd7, %%rd3, 256;\n"
        "	setp.lt.u64 	%%p4, %%rd7, %%rd4;\n"
        "	@%%p4 bra 	$L__BB38_7;\n"
        "	bra.uni 	$L__BB38_8;\n"
        "$L__BB38_7:                             // %%then168\n"
        "	shl.b64 	%%rd27, %%rd7, 3;\n"
        "	add.s64 	%%rd28, %%rd2, %%rd27;\n"
        "	ld.global.v2.b32 	{%%r9, %%r10}, [%%rd28];\n"
        "	add.s64 	%%rd29, %%rd1, %%rd27;\n"
        "	ld.global.v2.b32 	{%%r11, %%r12}, [%%rd29];\n"
        "	add.rn.f16x2 	%%r13, %%r10, %%r12;\n"
        "	add.rn.f16x2 	%%r14, %%r9, %%r11;\n"
        "	st.global.v2.b32 	[%%rd28], {%%r14, %%r13};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_8:                             // %%else169\n"
        "	sub.s64 	%%rd24, %%rd7, %%rd4;\n"
        "	add.s64 	%%rd25, %%rd24, %%rd33;\n"
        "	setp.ge.u64 	%%p5, %%rd25, %%rd10;\n"
        "	@%%p5 bra 	$L__BB38_2;\n"
        "// %%bb.9:                               // %%then204\n"
        "	shl.b64 	%%rd26, %%rd25, 1;\n"
        "	add.s64 	%%rd8, %%rd1, %%rd26;\n"
        "	add.s64 	%%rd9, %%rd2, %%rd26;\n"
        "	ld.global.b16 	%%rs4, [%%rd9];\n"
        "	ld.global.b16 	%%rs5, [%%rd8];\n"
        "	add.rn.f16 	%%rs6, %%rs4, %%rs5;\n"
        "	st.global.b16 	[%%rd9], %%rs6;\n"
        "$L__BB38_2:                             // %%ifcont\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(b_ptr), "l"(len), "l"(a_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B) {
    int64_t N = A.numel();
    if (N <= 0) return A;

    constexpr int BLOCK_SIZE = 256;
    int64_t needed_blocks = ((N >> 2) + (N & 3) + 511) / 512;
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);

    crisp_vector_add_f16_kernel<<<grid_x, BLOCK_SIZE>>>(
        reinterpret_cast<uint64_t>(A.data_ptr()),
        reinterpret_cast<uint64_t>(B.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return A;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B);"""

_crisp_mod = load_inline(
    name="crisp_vectoradd_f16_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vector_add_f16"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    A, B, _ = data
    return _crisp_mod.launch_crisp_vector_add_f16(A, B)
