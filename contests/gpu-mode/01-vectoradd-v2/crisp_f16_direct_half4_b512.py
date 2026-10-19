# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectoradd_direct_half4_b512.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectoradd_v2 (Direct 1-thread-per-half4 with local-size 512)
#   ;; Halves the total CTA count (from 262,144 to 131,072 blocks) while keeping 18 registers/thread.
#
#   (def-type in-vec  (vector half :address-space :global :align :compact))
#   (def-type out-vec (vector half :address-space :global :align :compact))
#
#   (def-kernel vector_add_f16 (A B &out C)
#     (declare #'(in-vec in-vec &out out-vec => nil)
#              (global-size :derive-from A :strategy :strided)
#              (local-size  :set-to 512))
#     (let ((gid (get-global-id 0))
#           (n   (length~ A))
#           (n4  (/ n 4ul))
#           (a4  (make-vector A half4 :length n4))
#           (b4  (make-vector B half4 :length n4))
#           (c4  (make-vector C half4 :length n4)))
#       (if (< gid n4)
#           (set! (~ c4 gid) (+ (~ a4 gid) (~ b4 gid)))
#           (let ((tail (+ (* n4 4ul) (- gid n4))))
#             (when (< tail n)
#               (set! (~ C tail) (+ (~ A tail) (~ B tail))))))))
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
        "	.reg .pred 	%%cr_p<3>;\n"
        "	.reg .b16 	%%cr_rs<4>;\n"
        "	.reg .b32 	%%cr_r<10>;\n"
        "	.reg .b64 	%%cr_rd<23>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd9, %1;\n"
        "	mov.b64 	%%cr_rd10, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd10;\n"
        "	mov.b64 	%%cr_rd11, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd11;\n"
        "	mov.b64 	%%cr_rd12, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd12;\n"
        "	mov.u32 	%%cr_r1, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r2, %%ntid.x;\n"
        "	mov.u32 	%%cr_r3, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd13, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd14, %%cr_r1, %%cr_r2;\n"
        "	add.s64 	%%cr_rd4, %%cr_rd14, %%cr_rd13;\n"
        "	shr.u64 	%%cr_rd5, %%cr_rd9, 2;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd4, %%cr_rd5;\n"
        "	@%%cr_p1 bra 	$L__BB38_2;\n"
        "// %%bb.1:                               // %%then\n"
        "	shl.b64 	%%cr_rd19, %%cr_rd4, 3;\n"
        "	add.s64 	%%cr_rd20, %%cr_rd1, %%cr_rd19;\n"
        "	ld.global.v2.b32 	{%%cr_r4, %%cr_r5}, [%%cr_rd20];\n"
        "	add.s64 	%%cr_rd21, %%cr_rd2, %%cr_rd19;\n"
        "	ld.global.v2.b32 	{%%cr_r6, %%cr_r7}, [%%cr_rd21];\n"
        "	add.rn.f16x2 	%%cr_r8, %%cr_r5, %%cr_r7;\n"
        "	add.rn.f16x2 	%%cr_r9, %%cr_r4, %%cr_r6;\n"
        "	add.s64 	%%cr_rd22, %%cr_rd3, %%cr_rd19;\n"
        "	st.global.v2.b32 	[%%cr_rd22], {%%cr_r9, %%cr_r8};\n"
        "	bra.uni 	$L__BB38_3;\n"
        "$L__BB38_2:                             // %%else\n"
        "	and.b64 	%%cr_rd15, %%cr_rd9, -4;\n"
        "	sub.s64 	%%cr_rd16, %%cr_rd4, %%cr_rd5;\n"
        "	add.s64 	%%cr_rd17, %%cr_rd16, %%cr_rd15;\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd17, %%cr_rd9;\n"
        "	@%%cr_p2 bra 	$L__BB38_4;\n"
        "	bra.uni 	$L__BB38_3;\n"
        "$L__BB38_4:                             // %%then107\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd17, 1;\n"
        "	add.s64 	%%cr_rd6, %%cr_rd3, %%cr_rd18;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd2, %%cr_rd18;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd1, %%cr_rd18;\n"
        "	ld.global.nc.b16 	%%cr_rs1, [%%cr_rd8];\n"
        "	ld.global.nc.b16 	%%cr_rs2, [%%cr_rd7];\n"
        "	add.rn.f16 	%%cr_rs3, %%cr_rs1, %%cr_rs2;\n"
        "	st.global.b16 	[%%cr_rd6], %%cr_rs3;\n"
        "$L__BB38_3:                             // %%ifcont\n"
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
    int64_t needed_blocks = ((N >> 2) + (N & 3) + BLOCK_SIZE - 1) / BLOCK_SIZE;
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
