# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_b200_inplace_tile4x_half4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectoradd_v2 (B200 In-Place Variant 3: Direct 4x half4 = 32B per thread)
#   ;; Uses def-hardware-profile for B200 and in-place read-modify-write (B A) with 4x half4
#   ;; per thread at constant +256 stride ([+2048], [+4096], [+6144] immediate offsets).
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
#           (base (+ (* bid 1024ul) tid))
#           (n    (length~ B))
#           (n4   (/ n 4ul))
#           (b4   (make-vector B half4 :length n4))
#           (a4   (make-vector A half4 :length n4)))
#       (if (< (+ (* bid 1024ul) 1023ul) n4)
#           (let ((v0 (+ (~ a4 base)           (~ b4 base)))
#                 (v1 (+ (~ a4 (+ base 256ul)) (~ b4 (+ base 256ul))))
#                 (v2 (+ (~ a4 (+ base 512ul)) (~ b4 (+ base 512ul))))
#                 (v3 (+ (~ a4 (+ base 768ul)) (~ b4 (+ base 768ul)))))
#             (set! (~ a4 base)           v0)
#             (set! (~ a4 (+ base 256ul)) v1)
#             (set! (~ a4 (+ base 512ul)) v2)
#             (set! (~ a4 (+ base 768ul)) v3))
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
#                       (set! (~ A tail1) (+ (~ A tail1) (~ B tail1)))))))
#             (let ((idx2 (+ base 512ul)))
#               (if (< idx2 n4)
#                   (set! (~ a4 idx2) (+ (~ a4 idx2) (~ b4 idx2)))
#                   (let ((tail2 (+ (* n4 4ul) (- idx2 n4))))
#                     (when (< tail2 n)
#                       (set! (~ A tail2) (+ (~ A tail2) (~ B tail2)))))))
#             (let ((idx3 (+ base 768ul)))
#               (if (< idx3 n4)
#                   (set! (~ a4 idx3) (+ (~ a4 idx3) (~ b4 idx3)))
#                   (let ((tail3 (+ (* n4 4ul) (- idx3 n4))))
#                     (when (< tail3 n)
#                       (set! (~ A tail3) (+ (~ A tail3) (~ B tail3)))))))))))
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
        "	.reg .pred 	%%p<10>;\n"
        "	.reg .b16 	%%rs<13>;\n"
        "	.reg .b32 	%%r<51>;\n"
        "	.reg .b64 	%%rd<54>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%rd16, %1;\n"
        "	mov.b64 	%%rd17, %0;\n"
        "	cvta.to.global.u64 	%%rd1, %%rd17;\n"
        "	mov.b64 	%%rd18, %2;\n"
        "	cvta.to.global.u64 	%%rd2, %%rd18;\n"
        "	mov.u32 	%%r1, %%ctaid.x;\n"
        "	mov.u32 	%%r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%rd19, %%r2;\n"
        "	mul.wide.u32 	%%rd20, %%r1, 1024;\n"
        "	or.b64 	%%rd3, %%rd20, %%rd19;\n"
        "	shr.u64 	%%rd4, %%rd16, 2;\n"
        "	or.b64 	%%rd21, %%rd20, 1023;\n"
        "	setp.ge.u64 	%%p1, %%rd21, %%rd4;\n"
        "	@%%p1 bra 	$L__BB38_4;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%rd50, %%rd3, 3;\n"
        "	add.s64 	%%rd51, %%rd2, %%rd50;\n"
        "	ld.global.v2.b32 	{%%r27, %%r28}, [%%rd51];\n"
        "	add.s64 	%%rd52, %%rd1, %%rd50;\n"
        "	ld.global.v2.b32 	{%%r29, %%r30}, [%%rd52];\n"
        "	add.rn.f16x2 	%%r31, %%r28, %%r30;\n"
        "	add.rn.f16x2 	%%r32, %%r27, %%r29;\n"
        "	ld.global.v2.b32 	{%%r33, %%r34}, [%%rd51+2048];\n"
        "	ld.global.v2.b32 	{%%r35, %%r36}, [%%rd52+2048];\n"
        "	add.rn.f16x2 	%%r37, %%r34, %%r36;\n"
        "	add.rn.f16x2 	%%r38, %%r33, %%r35;\n"
        "	ld.global.v2.b32 	{%%r39, %%r40}, [%%rd51+4096];\n"
        "	ld.global.v2.b32 	{%%r41, %%r42}, [%%rd52+4096];\n"
        "	add.rn.f16x2 	%%r43, %%r40, %%r42;\n"
        "	add.rn.f16x2 	%%r44, %%r39, %%r41;\n"
        "	ld.global.v2.b32 	{%%r45, %%r46}, [%%rd51+6144];\n"
        "	ld.global.v2.b32 	{%%r47, %%r48}, [%%rd52+6144];\n"
        "	add.rn.f16x2 	%%r49, %%r46, %%r48;\n"
        "	add.rn.f16x2 	%%r50, %%r45, %%r47;\n"
        "	st.global.v2.b32 	[%%rd51], {%%r32, %%r31};\n"
        "	st.global.v2.b32 	[%%rd51+2048], {%%r38, %%r37};\n"
        "	st.global.v2.b32 	[%%rd51+4096], {%%r44, %%r43};\n"
        "	st.global.v2.b32 	[%%rd51+6144], {%%r50, %%r49};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_4:                             // %%else\n"
        "	setp.lt.u64 	%%p2, %%rd3, %%rd4;\n"
        "	and.b64 	%%rd53, %%rd16, -4;\n"
        "	@%%p2 bra 	$L__BB38_3;\n"
        "	bra.uni 	$L__BB38_5;\n"
        "$L__BB38_3:                             // %%then152\n"
        "	shl.b64 	%%rd26, %%rd3, 3;\n"
        "	add.s64 	%%rd27, %%rd2, %%rd26;\n"
        "	ld.global.v2.b32 	{%%r3, %%r4}, [%%rd27];\n"
        "	add.s64 	%%rd28, %%rd1, %%rd26;\n"
        "	ld.global.v2.b32 	{%%r5, %%r6}, [%%rd28];\n"
        "	add.rn.f16x2 	%%r7, %%r4, %%r6;\n"
        "	add.rn.f16x2 	%%r8, %%r3, %%r5;\n"
        "	st.global.v2.b32 	[%%rd27], {%%r8, %%r7};\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_5:                             // %%else153\n"
        "	sub.s64 	%%rd23, %%rd3, %%rd4;\n"
        "	add.s64 	%%rd24, %%rd23, %%rd53;\n"
        "	setp.lt.u64 	%%p3, %%rd24, %%rd16;\n"
        "	@%%p3 bra 	$L__BB38_16;\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_16:                            // %%then188\n"
        "	shl.b64 	%%rd25, %%rd24, 1;\n"
        "	add.s64 	%%rd5, %%rd1, %%rd25;\n"
        "	add.s64 	%%rd6, %%rd2, %%rd25;\n"
        "	ld.global.b16 	%%rs1, [%%rd6];\n"
        "	ld.global.b16 	%%rs2, [%%rd5];\n"
        "	add.rn.f16 	%%rs3, %%rs1, %%rs2;\n"
        "	st.global.b16 	[%%rd6], %%rs3;\n"
        "$L__BB38_6:                             // %%ifcont154\n"
        "	add.s64 	%%rd7, %%rd3, 256;\n"
        "	setp.lt.u64 	%%p4, %%rd7, %%rd4;\n"
        "	@%%p4 bra 	$L__BB38_7;\n"
        "	bra.uni 	$L__BB38_8;\n"
        "$L__BB38_7:                             // %%then220\n"
        "	shl.b64 	%%rd33, %%rd7, 3;\n"
        "	add.s64 	%%rd34, %%rd2, %%rd33;\n"
        "	ld.global.v2.b32 	{%%r9, %%r10}, [%%rd34];\n"
        "	add.s64 	%%rd35, %%rd1, %%rd33;\n"
        "	ld.global.v2.b32 	{%%r11, %%r12}, [%%rd35];\n"
        "	add.rn.f16x2 	%%r13, %%r10, %%r12;\n"
        "	add.rn.f16x2 	%%r14, %%r9, %%r11;\n"
        "	st.global.v2.b32 	[%%rd34], {%%r14, %%r13};\n"
        "	bra.uni 	$L__BB38_9;\n"
        "$L__BB38_8:                             // %%else221\n"
        "	sub.s64 	%%rd30, %%rd7, %%rd4;\n"
        "	add.s64 	%%rd31, %%rd30, %%rd53;\n"
        "	setp.lt.u64 	%%p5, %%rd31, %%rd16;\n"
        "	@%%p5 bra 	$L__BB38_17;\n"
        "	bra.uni 	$L__BB38_9;\n"
        "$L__BB38_17:                            // %%then256\n"
        "	shl.b64 	%%rd32, %%rd31, 1;\n"
        "	add.s64 	%%rd8, %%rd1, %%rd32;\n"
        "	add.s64 	%%rd9, %%rd2, %%rd32;\n"
        "	ld.global.b16 	%%rs4, [%%rd9];\n"
        "	ld.global.b16 	%%rs5, [%%rd8];\n"
        "	add.rn.f16 	%%rs6, %%rs4, %%rs5;\n"
        "	st.global.b16 	[%%rd9], %%rs6;\n"
        "$L__BB38_9:                             // %%ifcont222\n"
        "	add.s64 	%%rd10, %%rd3, 512;\n"
        "	setp.lt.u64 	%%p6, %%rd10, %%rd4;\n"
        "	@%%p6 bra 	$L__BB38_10;\n"
        "	bra.uni 	$L__BB38_11;\n"
        "$L__BB38_10:                            // %%then288\n"
        "	shl.b64 	%%rd40, %%rd10, 3;\n"
        "	add.s64 	%%rd41, %%rd2, %%rd40;\n"
        "	ld.global.v2.b32 	{%%r15, %%r16}, [%%rd41];\n"
        "	add.s64 	%%rd42, %%rd1, %%rd40;\n"
        "	ld.global.v2.b32 	{%%r17, %%r18}, [%%rd42];\n"
        "	add.rn.f16x2 	%%r19, %%r16, %%r18;\n"
        "	add.rn.f16x2 	%%r20, %%r15, %%r17;\n"
        "	st.global.v2.b32 	[%%rd41], {%%r20, %%r19};\n"
        "	bra.uni 	$L__BB38_12;\n"
        "$L__BB38_11:                            // %%else289\n"
        "	sub.s64 	%%rd37, %%rd10, %%rd4;\n"
        "	add.s64 	%%rd38, %%rd37, %%rd53;\n"
        "	setp.lt.u64 	%%p7, %%rd38, %%rd16;\n"
        "	@%%p7 bra 	$L__BB38_18;\n"
        "	bra.uni 	$L__BB38_12;\n"
        "$L__BB38_18:                            // %%then324\n"
        "	shl.b64 	%%rd39, %%rd38, 1;\n"
        "	add.s64 	%%rd11, %%rd1, %%rd39;\n"
        "	add.s64 	%%rd12, %%rd2, %%rd39;\n"
        "	ld.global.b16 	%%rs7, [%%rd12];\n"
        "	ld.global.b16 	%%rs8, [%%rd11];\n"
        "	add.rn.f16 	%%rs9, %%rs7, %%rs8;\n"
        "	st.global.b16 	[%%rd12], %%rs9;\n"
        "$L__BB38_12:                            // %%ifcont290\n"
        "	add.s64 	%%rd13, %%rd3, 768;\n"
        "	setp.lt.u64 	%%p8, %%rd13, %%rd4;\n"
        "	@%%p8 bra 	$L__BB38_13;\n"
        "	bra.uni 	$L__BB38_14;\n"
        "$L__BB38_13:                            // %%then356\n"
        "	shl.b64 	%%rd47, %%rd13, 3;\n"
        "	add.s64 	%%rd48, %%rd2, %%rd47;\n"
        "	ld.global.v2.b32 	{%%r21, %%r22}, [%%rd48];\n"
        "	add.s64 	%%rd49, %%rd1, %%rd47;\n"
        "	ld.global.v2.b32 	{%%r23, %%r24}, [%%rd49];\n"
        "	add.rn.f16x2 	%%r25, %%r22, %%r24;\n"
        "	add.rn.f16x2 	%%r26, %%r21, %%r23;\n"
        "	st.global.v2.b32 	[%%rd48], {%%r26, %%r25};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_14:                            // %%else357\n"
        "	sub.s64 	%%rd44, %%rd13, %%rd4;\n"
        "	add.s64 	%%rd45, %%rd44, %%rd53;\n"
        "	setp.ge.u64 	%%p9, %%rd45, %%rd16;\n"
        "	@%%p9 bra 	$L__BB38_2;\n"
        "// %%bb.15:                              // %%then392\n"
        "	shl.b64 	%%rd46, %%rd45, 1;\n"
        "	add.s64 	%%rd14, %%rd1, %%rd46;\n"
        "	add.s64 	%%rd15, %%rd2, %%rd46;\n"
        "	ld.global.b16 	%%rs10, [%%rd15];\n"
        "	ld.global.b16 	%%rs11, [%%rd14];\n"
        "	add.rn.f16 	%%rs12, %%rs10, %%rs11;\n"
        "	st.global.b16 	[%%rd15], %%rs12;\n"
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
    int64_t needed_blocks = ((N >> 2) + (N & 3) + 1023) / 1024;
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
