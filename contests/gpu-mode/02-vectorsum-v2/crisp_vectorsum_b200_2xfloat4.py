# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_b200_2xfloat4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 (B200 Tuned: 2x float4 = 32B per thread)
#   ;; Uses def-hardware-profile for B200, 2x float4 vector loads (32B/iteration)
#   ;; with 8 independent FP32 accumulators to saturate B200 memory bandwidth,
#   ;; followed by warp shuffle-xor reduction and direct warp atomic add.
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
#   (def-type in-vec   (vector float :address-space :global :align :compact))
#   (def-type out-cell (cell float :address-space :global))
#
#   (def-kernel vectorsum_b200_kernel (input result)
#     (declare #'(in-vec out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((gid    (to-ulong (get-global-id 0)))
#           (gs     (to-ulong (get-global-work-size 0)))
#           (lane   (to-ulong (warp-lane)))
#           (n      (length~ input))
#           (n4     (/ n 4ul))
#           (in4    (make-vector input float4 :length n4))
#           (a0     0.0) (a1 0.0) (a2 0.0) (a3 0.0)
#           (b0     0.0) (b1 0.0) (b2 0.0) (b3 0.0)
#           (stride (* 2ul gs)))
#       ;; Main 2x float4 loop (stride = 2 * gs)
#       (let ((iters (if (>= gid n4) 0ul (+ 1ul (/ (- (- n4 1ul) gid) stride))))
#             (idx gid))
#         (dotimes (k iters)
#           (let ((v0 (~ in4 idx)))
#             (set! a0 (+ a0 (x~ v0)))
#             (set! a1 (+ a1 (y~ v0)))
#             (set! a2 (+ a2 (z~ v0)))
#             (set! a3 (+ a3 (w~ v0))))
#           (let ((idx1 (+ idx gs)))
#             (when (< idx1 n4)
#               (let ((v1 (~ in4 idx1)))
#                 (set! b0 (+ b0 (x~ v1)))
#                 (set! b1 (+ b1 (y~ v1)))
#                 (set! b2 (+ b2 (z~ v1)))
#                 (set! b3 (+ b3 (w~ v1))))))
#           (set! idx (+ idx stride))))
#       ;; Tail for elements beyond n4 * 4
#       (let ((tail_start (* n4 4ul)))
#         (let ((t (+ tail_start gid)))
#           (when (< t n)
#             (set! a0 (+ a0 (~ input t))))))
#       ;; Sum the 8 accumulators
#       (let ((acc (+ (+ (+ a0 a1) (+ a2 a3))
#                     (+ (+ b0 b1) (+ b2 b3)))))
#         ;; Intra-warp reduction with shuffle-xor (32 -> 1)
#         (dec-times-by-half+ (m (/ (to-ulong (warp-size)) 2ul))
#           (set! acc (+ acc (shuffle-xor acc m))))
#         ;; Warp leader atomic-adds directly to global output
#         (when (= lane 0ul)
#           (atomic-add! (~ result) acc)))))
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
void crisp_vectorsum_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t len
) {
    uint64_t smem_ptr = 0ULL;
    uint64_t bytes = len * 4ULL;
    uint64_t four = 4ULL;
    uint64_t zero = 0ULL;
    uint64_t one = 1ULL;
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<12>;\n"
        "	.reg .b32 	%%cr_r<163>;\n"
        "	.reg .b64 	%%cr_rd<77>;\n"
        "// %%cr_bb.0:                               // %%cr_entry\n"
        "	mov.b64 	%%cr_rd39, %1;\n"
        "	mov.b64 	%%cr_rd42, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd42;\n"
        "	mov.b64 	%%cr_rd43, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd43;\n"
        "	mov.u32 	%%cr_r69, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r70, %%ntid.x;\n"
        "	mov.u32 	%%cr_r71, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd73, %%cr_r71;\n"
        "	mul.wide.u32 	%%cr_rd6, %%cr_r69, %%cr_r70;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd6, %%cr_rd73;\n"
        "	mov.u32 	%%cr_r72, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd9, %%cr_r72, %%cr_r70;\n"
        "	shr.u64 	%%cr_rd10, %%cr_rd39, 2;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd7, %%cr_rd10;\n"
        "	mov.b64 	%%cr_rd72, 0;\n"
        "	@%%cr_p1 bra 	$L__BB43_5;\n"
        "// %%cr_bb.1:                               // %%cr_else\n"
        "	shl.b64 	%%cr_rd11, %%cr_rd9, 1;\n"
        "	not.b64 	%%cr_rd44, %%cr_rd7;\n"
        "	add.s64 	%%cr_rd12, %%cr_rd10, %%cr_rd44;\n"
        "	or.b64 	%%cr_rd45, %%cr_rd12, %%cr_rd11;\n"
        "	and.b64 	%%cr_rd46, %%cr_rd45, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd46, 0;\n"
        "	@%%cr_p2 bra 	$L__BB43_3;\n"
        "	bra.uni 	$L__BB43_2;\n"
        "$L__BB43_3:\n"
        "	div.u64 	%%cr_rd71, %%cr_rd12, %%cr_rd11;\n"
        "	bra.uni 	$L__BB43_4;\n"
        "$L__BB43_2:\n"
        "	cvt.u32.u64 	%%cr_r73, %%cr_rd11;\n"
        "	cvt.u32.u64 	%%cr_r74, %%cr_rd12;\n"
        "	div.u32 	%%cr_r75, %%cr_r74, %%cr_r73;\n"
        "	cvt.u64.u32 	%%cr_rd71, %%cr_r75;\n"
        "$L__BB43_4:\n"
        "	add.s64 	%%cr_rd72, %%cr_rd71, 1;\n"
        "$L__BB43_5:                             // %%cr_ifcont\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd72, 0;\n"
        "	mov.b32 	%%cr_r146, 0f00000000;\n"
        "	mov.b32 	%%cr_r147, %%cr_r146;\n"
        "	mov.b32 	%%cr_r148, %%cr_r146;\n"
        "	mov.b32 	%%cr_r149, %%cr_r146;\n"
        "	mov.b32 	%%cr_r125, %%cr_r146;\n"
        "	mov.b32 	%%cr_r124, %%cr_r146;\n"
        "	mov.b32 	%%cr_r123, %%cr_r146;\n"
        "	mov.b32 	%%cr_r122, %%cr_r146;\n"
        "	@%%cr_p3 bra 	$L__BB43_17;\n"
        "// %%cr_bb.6:                               // %%cr_dt_body.preheader\n"
        "	and.b64 	%%cr_rd18, %%cr_rd72, 1;\n"
        "	setp.eq.b64 	%%cr_p4, %%cr_rd72, 1;\n"
        "	mov.b32 	%%cr_r122, 0f00000000;\n"
        "	mov.b64 	%%cr_rd76, %%cr_rd7;\n"
        "	mov.b32 	%%cr_r123, %%cr_r122;\n"
        "	mov.b32 	%%cr_r124, %%cr_r122;\n"
        "	mov.b32 	%%cr_r125, %%cr_r122;\n"
        "	mov.b32 	%%cr_r149, %%cr_r122;\n"
        "	mov.b32 	%%cr_r148, %%cr_r122;\n"
        "	mov.b32 	%%cr_r147, %%cr_r122;\n"
        "	mov.b32 	%%cr_r146, %%cr_r122;\n"
        "	@%%cr_p4 bra 	$L__BB43_14;\n"
        "// %%cr_bb.7:                               // %%cr_dt_body.preheader.new\n"
        "	cvt.u64.u32 	%%cr_rd3, %%cr_r69;\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r70;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r72;\n"
        "	and.b64 	%%cr_rd75, %%cr_rd72, -2;\n"
        "	shl.b64 	%%cr_rd47, %%cr_rd7, 4;\n"
        "	or.b64 	%%cr_rd20, %%cr_rd47, 12;\n"
        "	shl.b64 	%%cr_rd21, %%cr_rd9, 6;\n"
        "	add.s64 	%%cr_rd48, %%cr_rd3, %%cr_rd8;\n"
        "	mul.lo.s64 	%%cr_rd22, %%cr_rd48, %%cr_rd4;\n"
        "	shl.b64 	%%cr_rd23, %%cr_rd9, 2;\n"
        "	shl.b64 	%%cr_rd49, %%cr_rd8, 1;\n"
        "	add.s64 	%%cr_rd50, %%cr_rd49, %%cr_rd3;\n"
        "	mul.lo.s64 	%%cr_rd51, %%cr_rd50, %%cr_rd4;\n"
        "	shl.b64 	%%cr_rd52, %%cr_rd51, 4;\n"
        "	shl.b64 	%%cr_rd53, %%cr_rd73, 4;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd52, %%cr_rd53;\n"
        "	add.s64 	%%cr_rd54, %%cr_rd22, %%cr_rd73;\n"
        "	shl.b64 	%%cr_rd55, %%cr_rd54, 4;\n"
        "	or.b64 	%%cr_rd25, %%cr_rd55, 12;\n"
        "	mad.lo.s64 	%%cr_rd56, %%cr_rd8, 3, %%cr_rd3;\n"
        "	mul.lo.s64 	%%cr_rd26, %%cr_rd56, %%cr_rd4;\n"
        "	shl.b64 	%%cr_rd57, %%cr_rd26, 4;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd57, %%cr_rd53;\n"
        "	mov.b32 	%%cr_r122, 0f00000000;\n"
        "	mov.b64 	%%cr_rd74, %%cr_rd1;\n"
        "	mov.b32 	%%cr_r123, %%cr_r122;\n"
        "	mov.b32 	%%cr_r124, %%cr_r122;\n"
        "	mov.b32 	%%cr_r125, %%cr_r122;\n"
        "	mov.b32 	%%cr_r149, %%cr_r122;\n"
        "	mov.b32 	%%cr_r148, %%cr_r122;\n"
        "	mov.b32 	%%cr_r147, %%cr_r122;\n"
        "	mov.b32 	%%cr_r146, %%cr_r122;\n"
        "	bra.uni 	$L__BB43_8;\n"
        "$L__BB43_12:                            // %%cr_ifcont71.1\n"
        "                                        //   in Loop: Header=BB43_8 Depth=1\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r10, %%cr_r88;\n"
        "	add.rn.f32 	%%cr_r147, %%cr_r11, %%cr_r89;\n"
        "	add.rn.f32 	%%cr_r148, %%cr_r12, %%cr_r90;\n"
        "	add.rn.f32 	%%cr_r149, %%cr_r13, %%cr_r91;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd75, -2;\n"
        "	add.s64 	%%cr_rd74, %%cr_rd74, %%cr_rd21;\n"
        "	add.s64 	%%cr_rd73, %%cr_rd73, %%cr_rd23;\n"
        "	setp.eq.b64 	%%cr_p7, %%cr_rd75, 0;\n"
        "	@%%cr_p7 bra 	$L__BB43_13;\n"
        "$L__BB43_8:                             // %%cr_dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd58, %%cr_rd74, %%cr_rd20;\n"
        "	ld.global.v4.b32 	{%%cr_r80, %%cr_r81, %%cr_r82, %%cr_r83}, [%%cr_rd58+-12];\n"
        "	add.s64 	%%cr_rd59, %%cr_rd22, %%cr_rd73;\n"
        "	setp.lt.u64 	%%cr_p5, %%cr_rd59, %%cr_rd10;\n"
        "	@%%cr_p5 bra 	$L__BB43_9;\n"
        "	bra.uni 	$L__BB43_10;\n"
        "$L__BB43_9:                             // %%cr_then69\n"
        "                                        //   in Loop: Header=BB43_8 Depth=1\n"
        "	add.s64 	%%cr_rd60, %%cr_rd74, %%cr_rd25;\n"
        "	ld.global.v4.b32 	{%%cr_r84, %%cr_r85, %%cr_r86, %%cr_r87}, [%%cr_rd60+-12];\n"
        "	add.rn.f32 	%%cr_r125, %%cr_r125, %%cr_r84;\n"
        "	add.rn.f32 	%%cr_r124, %%cr_r124, %%cr_r85;\n"
        "	add.rn.f32 	%%cr_r123, %%cr_r123, %%cr_r86;\n"
        "	add.rn.f32 	%%cr_r122, %%cr_r122, %%cr_r87;\n"
        "$L__BB43_10:                            // %%cr_ifcont71\n"
        "                                        //   in Loop: Header=BB43_8 Depth=1\n"
        "	add.rn.f32 	%%cr_r10, %%cr_r146, %%cr_r80;\n"
        "	add.rn.f32 	%%cr_r11, %%cr_r147, %%cr_r81;\n"
        "	add.rn.f32 	%%cr_r12, %%cr_r148, %%cr_r82;\n"
        "	add.rn.f32 	%%cr_r13, %%cr_r149, %%cr_r83;\n"
        "	add.s64 	%%cr_rd61, %%cr_rd74, %%cr_rd24;\n"
        "	ld.global.v4.b32 	{%%cr_r88, %%cr_r89, %%cr_r90, %%cr_r91}, [%%cr_rd61];\n"
        "	add.s64 	%%cr_rd62, %%cr_rd26, %%cr_rd73;\n"
        "	setp.ge.u64 	%%cr_p6, %%cr_rd62, %%cr_rd10;\n"
        "	@%%cr_p6 bra 	$L__BB43_12;\n"
        "// %%cr_bb.11:                              // %%cr_then69.1\n"
        "                                        //   in Loop: Header=BB43_8 Depth=1\n"
        "	add.s64 	%%cr_rd63, %%cr_rd74, %%cr_rd27;\n"
        "	ld.global.v4.b32 	{%%cr_r92, %%cr_r93, %%cr_r94, %%cr_r95}, [%%cr_rd63];\n"
        "	add.rn.f32 	%%cr_r125, %%cr_r125, %%cr_r92;\n"
        "	add.rn.f32 	%%cr_r124, %%cr_r124, %%cr_r93;\n"
        "	add.rn.f32 	%%cr_r123, %%cr_r123, %%cr_r94;\n"
        "	add.rn.f32 	%%cr_r122, %%cr_r122, %%cr_r95;\n"
        "	bra.uni 	$L__BB43_12;\n"
        "$L__BB43_13:                            // %%cr_dt_exit.loopexit.unr-lcssa.loopexit\n"
        "	add.s64 	%%cr_rd76, %%cr_rd6, %%cr_rd73;\n"
        "$L__BB43_14:                            // %%cr_dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p8, %%cr_rd18, 0;\n"
        "	@%%cr_p8 bra 	$L__BB43_17;\n"
        "// %%cr_bb.15:                              // %%cr_dt_body.epil\n"
        "	shl.b64 	%%cr_rd64, %%cr_rd76, 4;\n"
        "	add.s64 	%%cr_rd65, %%cr_rd1, %%cr_rd64;\n"
        "	ld.global.v4.b32 	{%%cr_r96, %%cr_r97, %%cr_r98, %%cr_r99}, [%%cr_rd65];\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r146, %%cr_r96;\n"
        "	add.rn.f32 	%%cr_r147, %%cr_r147, %%cr_r97;\n"
        "	add.rn.f32 	%%cr_r148, %%cr_r148, %%cr_r98;\n"
        "	add.rn.f32 	%%cr_r149, %%cr_r149, %%cr_r99;\n"
        "	add.s64 	%%cr_rd33, %%cr_rd76, %%cr_rd9;\n"
        "	setp.ge.u64 	%%cr_p9, %%cr_rd33, %%cr_rd10;\n"
        "	@%%cr_p9 bra 	$L__BB43_17;\n"
        "// %%cr_bb.16:                              // %%cr_then69.epil\n"
        "	shl.b64 	%%cr_rd66, %%cr_rd33, 4;\n"
        "	add.s64 	%%cr_rd67, %%cr_rd1, %%cr_rd66;\n"
        "	ld.global.v4.b32 	{%%cr_r100, %%cr_r101, %%cr_r102, %%cr_r103}, [%%cr_rd67];\n"
        "	add.rn.f32 	%%cr_r125, %%cr_r125, %%cr_r100;\n"
        "	add.rn.f32 	%%cr_r124, %%cr_r124, %%cr_r101;\n"
        "	add.rn.f32 	%%cr_r123, %%cr_r123, %%cr_r102;\n"
        "	add.rn.f32 	%%cr_r122, %%cr_r122, %%cr_r103;\n"
        "$L__BB43_17:                            // %%cr_dt_exit\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	and.b64 	%%cr_rd68, %%cr_rd39, -4;\n"
        "	add.s64 	%%cr_rd69, %%cr_rd68, %%cr_rd7;\n"
        "	setp.lt.u64 	%%cr_p10, %%cr_rd69, %%cr_rd39;\n"
        "	@%%cr_p10 bra 	$L__BB43_18;\n"
        "	bra.uni 	$L__BB43_19;\n"
        "$L__BB43_18:                            // %%cr_then108\n"
        "	shl.b64 	%%cr_rd70, %%cr_rd69, 2;\n"
        "	add.s64 	%%cr_rd34, %%cr_rd1, %%cr_rd70;\n"
        "	ld.global.b32 	%%cr_r104, [%%cr_rd34];\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r146, %%cr_r104;\n"
        "$L__BB43_19:                            // %%cr_ifcont110\n"
        "	add.rn.f32 	%%cr_r105, %%cr_r147, %%cr_r146;\n"
        "	add.rn.f32 	%%cr_r106, %%cr_r148, %%cr_r149;\n"
        "	add.rn.f32 	%%cr_r107, %%cr_r106, %%cr_r105;\n"
        "	add.rn.f32 	%%cr_r108, %%cr_r125, %%cr_r124;\n"
        "	add.rn.f32 	%%cr_r109, %%cr_r123, %%cr_r122;\n"
        "	add.rn.f32 	%%cr_r110, %%cr_r108, %%cr_r109;\n"
        "	add.rn.f32 	%%cr_r111, %%cr_r110, %%cr_r107;\n"
        "	shfl.sync.bfly.b32 	%%cr_r112, %%cr_r111, 16, 31, -1;\n"
        "	add.rn.f32 	%%cr_r113, %%cr_r111, %%cr_r112;\n"
        "	shfl.sync.bfly.b32 	%%cr_r114, %%cr_r113, 8, 31, -1;\n"
        "	add.rn.f32 	%%cr_r115, %%cr_r113, %%cr_r114;\n"
        "	shfl.sync.bfly.b32 	%%cr_r116, %%cr_r115, 4, 31, -1;\n"
        "	add.rn.f32 	%%cr_r117, %%cr_r115, %%cr_r116;\n"
        "	shfl.sync.bfly.b32 	%%cr_r118, %%cr_r117, 2, 31, -1;\n"
        "	add.rn.f32 	%%cr_r119, %%cr_r117, %%cr_r118;\n"
        "	shfl.sync.bfly.b32 	%%cr_r120, %%cr_r119, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p11, %%cr_r1, 0;\n"
        "	@%%cr_p11 bra 	$L__BB43_21;\n"
        "// %%cr_bb.20:                              // %%cr_then145\n"
        "	mov.b64 	%%cr_rd40, %3;\n"
        "	add.rn.f32 	%%cr_r68, %%cr_r119, %%cr_r120;\n"
        "	add.s64 	%%cr_rd38, %%cr_rd2, %%cr_rd40;\n"
        "	atom.global.add.f32 	%%cr_r121, [%%cr_rd38], %%cr_r68;\n"
        "$L__BB43_21:                            // %%cr_ifcont147\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(in_ptr), "l"(len), "l"(out_ptr), "l"(zero)
        : "memory"
    );
}

torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output) {
    int64_t N = input.numel();
    if (N <= 0) return output.dim() > 0 ? output.squeeze(0) : output;

    output.zero_();

    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(
            &blocks_per_sm, crisp_vectorsum_kernel, BLOCK_SIZE, 128);
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 4) : 1024;
    }

    int64_t needed_blocks = (N + (BLOCK_SIZE * 32) - 1) / (BLOCK_SIZE * 32);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE, 128>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output.dim() > 0 ? output.squeeze(0) : output;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output);"""

_crisp_mod = load_inline(
    name="crisp_vectorsum_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vectorsum"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_vectorsum(inp, out)
