# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_b200_inplace_half4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectoradd_v2 (B200 In-Place Variant 1: Direct 1x half4 per thread)
#   ;; Uses def-hardware-profile for B200 and in-place read-modify-write (B A) so A += B
#   ;; reuses A's L2 cache lines and TLB entries without allocating a third 537 MB buffer.
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
#     (let ((gid (get-global-id 0))
#           (n   (length~ B))
#           (n4  (/ n 4ul))
#           (b4  (make-vector B half4 :length n4))
#           (a4  (make-vector A half4 :length n4)))
#       (if (< gid n4)
#           (set! (~ a4 gid) (+ (~ a4 gid) (~ b4 gid)))
#           (let ((tail (+ (* n4 4ul) (- gid n4))))
#             (when (< tail n)
#               (set! (~ A tail) (+ (~ A tail) (~ B tail))))))))
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
        "	.reg .pred 	%%p<3>;\n"
        "	.reg .b16 	%%rs<4>;\n"
        "	.reg .b32 	%%r<10>;\n"
        "	.reg .b64 	%%rd<19>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%rd7, %1;\n"
        "	mov.b64 	%%rd8, %0;\n"
        "	cvta.to.global.u64 	%%rd1, %%rd8;\n"
        "	mov.b64 	%%rd9, %2;\n"
        "	cvta.to.global.u64 	%%rd2, %%rd9;\n"
        "	mov.u32 	%%r1, %%ctaid.x;\n"
        "	mov.u32 	%%r2, %%ntid.x;\n"
        "	mov.u32 	%%r3, %%tid.x;\n"
        "	cvt.u64.u32 	%%rd10, %%r3;\n"
        "	mul.wide.u32 	%%rd11, %%r1, %%r2;\n"
        "	add.s64 	%%rd3, %%rd11, %%rd10;\n"
        "	shr.u64 	%%rd4, %%rd7, 2;\n"
        "	setp.ge.u64 	%%p1, %%rd3, %%rd4;\n"
        "	@%%p1 bra 	$L__BB38_2;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%rd16, %%rd3, 3;\n"
        "	add.s64 	%%rd17, %%rd2, %%rd16;\n"
        "	ld.global.v2.b32 	{%%r4, %%r5}, [%%rd17];\n"
        "	add.s64 	%%rd18, %%rd1, %%rd16;\n"
        "	ld.global.v2.b32 	{%%r6, %%r7}, [%%rd18];\n"
        "	add.rn.f16x2 	%%r8, %%r5, %%r7;\n"
        "	add.rn.f16x2 	%%r9, %%r4, %%r6;\n"
        "	st.global.v2.b32 	[%%rd17], {%%r9, %%r8};\n"
        "	bra.uni 	$L__BB38_3;\n"
        "$L__BB38_2:                             // %%else\n"
        "	and.b64 	%%rd12, %%rd7, -4;\n"
        "	sub.s64 	%%rd13, %%rd3, %%rd4;\n"
        "	add.s64 	%%rd14, %%rd13, %%rd12;\n"
        "	setp.lt.u64 	%%p2, %%rd14, %%rd7;\n"
        "	@%%p2 bra 	$L__BB38_4;\n"
        "	bra.uni 	$L__BB38_3;\n"
        "$L__BB38_4:                             // %%then77\n"
        "	shl.b64 	%%rd15, %%rd14, 1;\n"
        "	add.s64 	%%rd5, %%rd1, %%rd15;\n"
        "	add.s64 	%%rd6, %%rd2, %%rd15;\n"
        "	ld.global.b16 	%%rs1, [%%rd6];\n"
        "	ld.global.b16 	%%rs2, [%%rd5];\n"
        "	add.rn.f16 	%%rs3, %%rs1, %%rs2;\n"
        "	st.global.b16 	[%%rd6], %%rs3;\n"
        "$L__BB38_3:                             // %%ifcont\n"
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
    int64_t needed_blocks = ((N >> 2) + (N & 3) + BLOCK_SIZE - 1) / BLOCK_SIZE;
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
