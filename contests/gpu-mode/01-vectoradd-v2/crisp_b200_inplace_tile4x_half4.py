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
        "	.reg .pred 	%%cr_p<10>;\n"
        "	.reg .b16 	%%cr_rs<13>;\n"
        "	.reg .b32 	%%cr_r<51>;\n"
        "	.reg .b64 	%%cr_rd<54>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd16, %1;\n"
        "	mov.b64 	%%cr_rd17, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd17;\n"
        "	mov.b64 	%%cr_rd18, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd18;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd19, %%cr_r2;\n"
        "	mul.wide.u32 	%%cr_rd20, %%cr_r1, 1024;\n"
        "	or.b64 	%%cr_rd3, %%cr_rd20, %%cr_rd19;\n"
        "	shr.u64 	%%cr_rd4, %%cr_rd16, 2;\n"
        "	or.b64 	%%cr_rd21, %%cr_rd20, 1023;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd21, %%cr_rd4;\n"
        "	@%%cr_p1 bra 	$L__BB38_4;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%cr_rd50, %%cr_rd3, 3;\n"
        "	add.s64 	%%cr_rd51, %%cr_rd2, %%cr_rd50;\n"
        "	ld.global.v2.b32 	{%%cr_r27, %%cr_r28}, [%%cr_rd51];\n"
        "	add.s64 	%%cr_rd52, %%cr_rd1, %%cr_rd50;\n"
        "	ld.global.v2.b32 	{%%cr_r29, %%cr_r30}, [%%cr_rd52];\n"
        "	add.rn.f16x2 	%%cr_r31, %%cr_r28, %%cr_r30;\n"
        "	add.rn.f16x2 	%%cr_r32, %%cr_r27, %%cr_r29;\n"
        "	ld.global.v2.b32 	{%%cr_r33, %%cr_r34}, [%%cr_rd51+2048];\n"
        "	ld.global.v2.b32 	{%%cr_r35, %%cr_r36}, [%%cr_rd52+2048];\n"
        "	add.rn.f16x2 	%%cr_r37, %%cr_r34, %%cr_r36;\n"
        "	add.rn.f16x2 	%%cr_r38, %%cr_r33, %%cr_r35;\n"
        "	ld.global.v2.b32 	{%%cr_r39, %%cr_r40}, [%%cr_rd51+4096];\n"
        "	ld.global.v2.b32 	{%%cr_r41, %%cr_r42}, [%%cr_rd52+4096];\n"
        "	add.rn.f16x2 	%%cr_r43, %%cr_r40, %%cr_r42;\n"
        "	add.rn.f16x2 	%%cr_r44, %%cr_r39, %%cr_r41;\n"
        "	ld.global.v2.b32 	{%%cr_r45, %%cr_r46}, [%%cr_rd51+6144];\n"
        "	ld.global.v2.b32 	{%%cr_r47, %%cr_r48}, [%%cr_rd52+6144];\n"
        "	add.rn.f16x2 	%%cr_r49, %%cr_r46, %%cr_r48;\n"
        "	add.rn.f16x2 	%%cr_r50, %%cr_r45, %%cr_r47;\n"
        "	st.global.v2.b32 	[%%cr_rd51], {%%cr_r32, %%cr_r31};\n"
        "	st.global.v2.b32 	[%%cr_rd51+2048], {%%cr_r38, %%cr_r37};\n"
        "	st.global.v2.b32 	[%%cr_rd51+4096], {%%cr_r44, %%cr_r43};\n"
        "	st.global.v2.b32 	[%%cr_rd51+6144], {%%cr_r50, %%cr_r49};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_4:                             // %%else\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd3, %%cr_rd4;\n"
        "	and.b64 	%%cr_rd53, %%cr_rd16, -4;\n"
        "	@%%cr_p2 bra 	$L__BB38_3;\n"
        "	bra.uni 	$L__BB38_5;\n"
        "$L__BB38_3:                             // %%then152\n"
        "	shl.b64 	%%cr_rd26, %%cr_rd3, 3;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd2, %%cr_rd26;\n"
        "	ld.global.v2.b32 	{%%cr_r3, %%cr_r4}, [%%cr_rd27];\n"
        "	add.s64 	%%cr_rd28, %%cr_rd1, %%cr_rd26;\n"
        "	ld.global.v2.b32 	{%%cr_r5, %%cr_r6}, [%%cr_rd28];\n"
        "	add.rn.f16x2 	%%cr_r7, %%cr_r4, %%cr_r6;\n"
        "	add.rn.f16x2 	%%cr_r8, %%cr_r3, %%cr_r5;\n"
        "	st.global.v2.b32 	[%%cr_rd27], {%%cr_r8, %%cr_r7};\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_5:                             // %%else153\n"
        "	sub.s64 	%%cr_rd23, %%cr_rd3, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd23, %%cr_rd53;\n"
        "	setp.lt.u64 	%%cr_p3, %%cr_rd24, %%cr_rd16;\n"
        "	@%%cr_p3 bra 	$L__BB38_16;\n"
        "	bra.uni 	$L__BB38_6;\n"
        "$L__BB38_16:                            // %%then188\n"
        "	shl.b64 	%%cr_rd25, %%cr_rd24, 1;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd1, %%cr_rd25;\n"
        "	add.s64 	%%cr_rd6, %%cr_rd2, %%cr_rd25;\n"
        "	ld.global.b16 	%%cr_rs1, [%%cr_rd6];\n"
        "	ld.global.b16 	%%cr_rs2, [%%cr_rd5];\n"
        "	add.rn.f16 	%%cr_rs3, %%cr_rs1, %%cr_rs2;\n"
        "	st.global.b16 	[%%cr_rd6], %%cr_rs3;\n"
        "$L__BB38_6:                             // %%ifcont154\n"
        "	add.s64 	%%cr_rd7, %%cr_rd3, 256;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd7, %%cr_rd4;\n"
        "	@%%cr_p4 bra 	$L__BB38_7;\n"
        "	bra.uni 	$L__BB38_8;\n"
        "$L__BB38_7:                             // %%then220\n"
        "	shl.b64 	%%cr_rd33, %%cr_rd7, 3;\n"
        "	add.s64 	%%cr_rd34, %%cr_rd2, %%cr_rd33;\n"
        "	ld.global.v2.b32 	{%%cr_r9, %%cr_r10}, [%%cr_rd34];\n"
        "	add.s64 	%%cr_rd35, %%cr_rd1, %%cr_rd33;\n"
        "	ld.global.v2.b32 	{%%cr_r11, %%cr_r12}, [%%cr_rd35];\n"
        "	add.rn.f16x2 	%%cr_r13, %%cr_r10, %%cr_r12;\n"
        "	add.rn.f16x2 	%%cr_r14, %%cr_r9, %%cr_r11;\n"
        "	st.global.v2.b32 	[%%cr_rd34], {%%cr_r14, %%cr_r13};\n"
        "	bra.uni 	$L__BB38_9;\n"
        "$L__BB38_8:                             // %%else221\n"
        "	sub.s64 	%%cr_rd30, %%cr_rd7, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd31, %%cr_rd30, %%cr_rd53;\n"
        "	setp.lt.u64 	%%cr_p5, %%cr_rd31, %%cr_rd16;\n"
        "	@%%cr_p5 bra 	$L__BB38_17;\n"
        "	bra.uni 	$L__BB38_9;\n"
        "$L__BB38_17:                            // %%then256\n"
        "	shl.b64 	%%cr_rd32, %%cr_rd31, 1;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd1, %%cr_rd32;\n"
        "	add.s64 	%%cr_rd9, %%cr_rd2, %%cr_rd32;\n"
        "	ld.global.b16 	%%cr_rs4, [%%cr_rd9];\n"
        "	ld.global.b16 	%%cr_rs5, [%%cr_rd8];\n"
        "	add.rn.f16 	%%cr_rs6, %%cr_rs4, %%cr_rs5;\n"
        "	st.global.b16 	[%%cr_rd9], %%cr_rs6;\n"
        "$L__BB38_9:                             // %%ifcont222\n"
        "	add.s64 	%%cr_rd10, %%cr_rd3, 512;\n"
        "	setp.lt.u64 	%%cr_p6, %%cr_rd10, %%cr_rd4;\n"
        "	@%%cr_p6 bra 	$L__BB38_10;\n"
        "	bra.uni 	$L__BB38_11;\n"
        "$L__BB38_10:                            // %%then288\n"
        "	shl.b64 	%%cr_rd40, %%cr_rd10, 3;\n"
        "	add.s64 	%%cr_rd41, %%cr_rd2, %%cr_rd40;\n"
        "	ld.global.v2.b32 	{%%cr_r15, %%cr_r16}, [%%cr_rd41];\n"
        "	add.s64 	%%cr_rd42, %%cr_rd1, %%cr_rd40;\n"
        "	ld.global.v2.b32 	{%%cr_r17, %%cr_r18}, [%%cr_rd42];\n"
        "	add.rn.f16x2 	%%cr_r19, %%cr_r16, %%cr_r18;\n"
        "	add.rn.f16x2 	%%cr_r20, %%cr_r15, %%cr_r17;\n"
        "	st.global.v2.b32 	[%%cr_rd41], {%%cr_r20, %%cr_r19};\n"
        "	bra.uni 	$L__BB38_12;\n"
        "$L__BB38_11:                            // %%else289\n"
        "	sub.s64 	%%cr_rd37, %%cr_rd10, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd38, %%cr_rd37, %%cr_rd53;\n"
        "	setp.lt.u64 	%%cr_p7, %%cr_rd38, %%cr_rd16;\n"
        "	@%%cr_p7 bra 	$L__BB38_18;\n"
        "	bra.uni 	$L__BB38_12;\n"
        "$L__BB38_18:                            // %%then324\n"
        "	shl.b64 	%%cr_rd39, %%cr_rd38, 1;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd1, %%cr_rd39;\n"
        "	add.s64 	%%cr_rd12, %%cr_rd2, %%cr_rd39;\n"
        "	ld.global.b16 	%%cr_rs7, [%%cr_rd12];\n"
        "	ld.global.b16 	%%cr_rs8, [%%cr_rd11];\n"
        "	add.rn.f16 	%%cr_rs9, %%cr_rs7, %%cr_rs8;\n"
        "	st.global.b16 	[%%cr_rd12], %%cr_rs9;\n"
        "$L__BB38_12:                            // %%ifcont290\n"
        "	add.s64 	%%cr_rd13, %%cr_rd3, 768;\n"
        "	setp.lt.u64 	%%cr_p8, %%cr_rd13, %%cr_rd4;\n"
        "	@%%cr_p8 bra 	$L__BB38_13;\n"
        "	bra.uni 	$L__BB38_14;\n"
        "$L__BB38_13:                            // %%then356\n"
        "	shl.b64 	%%cr_rd47, %%cr_rd13, 3;\n"
        "	add.s64 	%%cr_rd48, %%cr_rd2, %%cr_rd47;\n"
        "	ld.global.v2.b32 	{%%cr_r21, %%cr_r22}, [%%cr_rd48];\n"
        "	add.s64 	%%cr_rd49, %%cr_rd1, %%cr_rd47;\n"
        "	ld.global.v2.b32 	{%%cr_r23, %%cr_r24}, [%%cr_rd49];\n"
        "	add.rn.f16x2 	%%cr_r25, %%cr_r22, %%cr_r24;\n"
        "	add.rn.f16x2 	%%cr_r26, %%cr_r21, %%cr_r23;\n"
        "	st.global.v2.b32 	[%%cr_rd48], {%%cr_r26, %%cr_r25};\n"
        "	bra.uni 	$L__BB38_2;\n"
        "$L__BB38_14:                            // %%else357\n"
        "	sub.s64 	%%cr_rd44, %%cr_rd13, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd45, %%cr_rd44, %%cr_rd53;\n"
        "	setp.ge.u64 	%%cr_p9, %%cr_rd45, %%cr_rd16;\n"
        "	@%%cr_p9 bra 	$L__BB38_2;\n"
        "// %%bb.15:                              // %%then392\n"
        "	shl.b64 	%%cr_rd46, %%cr_rd45, 1;\n"
        "	add.s64 	%%cr_rd14, %%cr_rd1, %%cr_rd46;\n"
        "	add.s64 	%%cr_rd15, %%cr_rd2, %%cr_rd46;\n"
        "	ld.global.b16 	%%cr_rs10, [%%cr_rd15];\n"
        "	ld.global.b16 	%%cr_rs11, [%%cr_rd14];\n"
        "	add.rn.f16 	%%cr_rs12, %%cr_rs10, %%cr_rs11;\n"
        "	st.global.b16 	[%%cr_rd15], %%cr_rs12;\n"
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
