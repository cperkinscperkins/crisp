# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_warp_reduce.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 (float32 vector sum reduction)
#   ;;
#   ;; Strategy (warp_atomic):
#   ;;   Phase 1: float4 (128-bit) vector loads in loop-vector-stride with 4 accumulators (16 bytes/iter)
#   ;;   Phase 2: Warp shuffle-xor reduction across 32 lanes (5 instructions in registers)
#   ;;   Phase 3: Warp leader (lane 0) atomic-adds warp sum directly to global result cell.
#   ;;
#   ;; Advantages:
#   ;;   - Zero shared memory allocation (no pointer or address-space issues)
#   ;;   - Zero workgroup barriers (bar.sync)
#   ;;   - Maximum memory throughput from 128-bit vector loads
#   ;;   - Minimal atomics: only 1 atomic per warp (e.g. 512 blocks * 8 warps = 4,096 atomics for 52M elements)
#
#   (def-type in-vec   (vector float :address-space :global :align :compact))
#   (def-type out-cell (cell float :address-space :global))
#
#   (def-kernel vectorsum_kernel (input result)
#     (declare #'(in-vec out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((lane (to-ulong (warp-lane)))
#           (n    (length~ input))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input float4 :length n4))
#           (a0   0.0)
#           (a1   0.0)
#           (a2   0.0)
#           (a3   0.0))
#       ;; Phase 1: 128-bit vector grid-stride loop with 4 accumulators
#       (loop-vector-stride in4 (i)
#         (let ((v (~ in4 i)))
#           (set! a0 (+ a0 (x~ v)))
#           (set! a1 (+ a1 (y~ v)))
#           (set! a2 (+ a2 (z~ v)))
#           (set! a3 (+ a3 (w~ v)))))
#       ;; Tail for elements beyond n4 * 4
#       (let ((tail_start (* n4 4ul))
#             (gid (to-ulong (get-global-id 0))))
#         (let ((t (+ tail_start gid)))
#           (when (< t n)
#             (set! a0 (+ a0 (~ input t))))))
#       ;; Sum the 4 accumulators
#       (let ((acc (+ (+ a0 a1) (+ a2 a3))))
#         ;; Phase 2: Intra-warp reduction with shuffle-xor (32 -> 1)
#         (dec-times-by-half+ (m (/ (to-ulong (warp-size)) 2ul))
#           (set! acc (+ acc (shuffle-xor acc m))))
#         ;; Phase 3: Warp leader issues atomic-add to global result cell
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
        "	.reg .pred 	%%cr_p<10>;\n"
        "	.reg .b32 	%%cr_r<111>;\n"
        "	.reg .b64 	%%cr_rd<81>;\n"
        "// %%cr_bb.0:                               // %%cr_entry\n"
        "	mov.b64 	%%cr_rd38, %2;\n"
        "	mov.b64 	%%cr_rd41, %0;\n"
        "	mov.b64 	%%cr_rd42, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd41;\n"
        "	mov.b64 	%%cr_rd43, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd43;\n"
        "	shr.u64 	%%cr_rd44, %%cr_rd42, 4;\n"
        "	mov.u32 	%%cr_r33, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r34, %%ntid.x;\n"
        "	mov.u32 	%%cr_r35, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r35;\n"
        "	mul.wide.u32 	%%cr_rd7, %%cr_r33, %%cr_r34;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd7, %%cr_rd6;\n"
        "	mov.u32 	%%cr_r36, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd10, %%cr_r36, %%cr_r34;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd8, %%cr_rd44;\n"
        "	mov.b64 	%%cr_rd75, 0;\n"
        "	@%%cr_p1 bra 	$L__BB43_5;\n"
        "// %%cr_bb.1:                               // %%cr_else\n"
        "	not.b64 	%%cr_rd45, %%cr_rd8;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd44, %%cr_rd45;\n"
        "	or.b64 	%%cr_rd46, %%cr_rd11, %%cr_rd10;\n"
        "	and.b64 	%%cr_rd47, %%cr_rd46, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd47, 0;\n"
        "	@%%cr_p2 bra 	$L__BB43_3;\n"
        "	bra.uni 	$L__BB43_2;\n"
        "$L__BB43_3:\n"
        "	div.u64 	%%cr_rd74, %%cr_rd11, %%cr_rd10;\n"
        "	bra.uni 	$L__BB43_4;\n"
        "$L__BB43_2:\n"
        "	cvt.u32.u64 	%%cr_r37, %%cr_rd10;\n"
        "	cvt.u32.u64 	%%cr_r38, %%cr_rd11;\n"
        "	div.u32 	%%cr_r39, %%cr_r38, %%cr_r37;\n"
        "	cvt.u64.u32 	%%cr_rd74, %%cr_r39;\n"
        "$L__BB43_4:\n"
        "	add.s64 	%%cr_rd75, %%cr_rd74, 1;\n"
        "$L__BB43_5:                             // %%cr_ifcont\n"
        "	and.b64 	%%cr_rd3, %%cr_rd38, -4;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd75, 0;\n"
        "	mov.b32 	%%cr_r106, 0f00000000;\n"
        "	mov.b32 	%%cr_r107, %%cr_r106;\n"
        "	mov.b32 	%%cr_r108, %%cr_r106;\n"
        "	mov.b32 	%%cr_r109, %%cr_r106;\n"
        "	@%%cr_p3 bra 	$L__BB43_12;\n"
        "// %%cr_bb.6:                               // %%cr_dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r33;\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r34;\n"
        "	cvt.u64.u32 	%%cr_rd9, %%cr_r36;\n"
        "	and.b64 	%%cr_rd80, %%cr_rd75, 3;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd75, 4;\n"
        "	mov.b32 	%%cr_r109, 0f00000000;\n"
        "	mov.b64 	%%cr_rd78, 0;\n"
        "	mov.b32 	%%cr_r108, %%cr_r109;\n"
        "	mov.b32 	%%cr_r107, %%cr_r109;\n"
        "	mov.b32 	%%cr_r106, %%cr_r109;\n"
        "	@%%cr_p4 bra 	$L__BB43_9;\n"
        "// %%cr_bb.7:                               // %%cr_dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd18, %%cr_rd75, -4;\n"
        "	shl.b64 	%%cr_rd50, %%cr_rd7, 4;\n"
        "	add.s64 	%%cr_rd51, %%cr_rd50, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd19, %%cr_rd51, 12;\n"
        "	shl.b64 	%%cr_rd76, %%cr_rd6, 4;\n"
        "	shl.b64 	%%cr_rd21, %%cr_rd10, 6;\n"
        "	mad.lo.s64 	%%cr_rd52, %%cr_rd9, 3, %%cr_rd4;\n"
        "	mul.lo.s64 	%%cr_rd53, %%cr_rd52, %%cr_rd5;\n"
        "	shl.b64 	%%cr_rd54, %%cr_rd53, 4;\n"
        "	add.s64 	%%cr_rd55, %%cr_rd54, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd22, %%cr_rd55, 12;\n"
        "	add.s64 	%%cr_rd56, %%cr_rd4, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd57, %%cr_rd56, %%cr_rd5;\n"
        "	shl.b64 	%%cr_rd58, %%cr_rd57, 4;\n"
        "	add.s64 	%%cr_rd23, %%cr_rd1, %%cr_rd58;\n"
        "	shl.b64 	%%cr_rd59, %%cr_rd9, 1;\n"
        "	add.s64 	%%cr_rd60, %%cr_rd59, %%cr_rd4;\n"
        "	mul.lo.s64 	%%cr_rd61, %%cr_rd60, %%cr_rd5;\n"
        "	shl.b64 	%%cr_rd62, %%cr_rd61, 4;\n"
        "	add.s64 	%%cr_rd63, %%cr_rd62, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd63, 8;\n"
        "	mov.b32 	%%cr_r109, 0f00000000;\n"
        "	mov.b64 	%%cr_rd78, 0;\n"
        "	mov.b32 	%%cr_r108, %%cr_r109;\n"
        "	mov.b32 	%%cr_r107, %%cr_r109;\n"
        "	mov.b32 	%%cr_r106, %%cr_r109;\n"
        "$L__BB43_8:                             // %%cr_dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd64, %%cr_rd19, %%cr_rd76;\n"
        "	ld.global.v4.b32 	{%%cr_r44, %%cr_r45, %%cr_r46, %%cr_r47}, [%%cr_rd64+-12];\n"
        "	add.rn.f32 	%%cr_r48, %%cr_r106, %%cr_r44;\n"
        "	add.rn.f32 	%%cr_r49, %%cr_r107, %%cr_r45;\n"
        "	add.rn.f32 	%%cr_r50, %%cr_r108, %%cr_r46;\n"
        "	add.rn.f32 	%%cr_r51, %%cr_r109, %%cr_r47;\n"
        "	add.s64 	%%cr_rd65, %%cr_rd23, %%cr_rd76;\n"
        "	ld.global.v4.b32 	{%%cr_r52, %%cr_r53, %%cr_r54, %%cr_r55}, [%%cr_rd65];\n"
        "	add.rn.f32 	%%cr_r56, %%cr_r48, %%cr_r52;\n"
        "	add.rn.f32 	%%cr_r57, %%cr_r49, %%cr_r53;\n"
        "	add.rn.f32 	%%cr_r58, %%cr_r50, %%cr_r54;\n"
        "	add.rn.f32 	%%cr_r59, %%cr_r51, %%cr_r55;\n"
        "	add.s64 	%%cr_rd66, %%cr_rd24, %%cr_rd76;\n"
        "	ld.global.v4.b32 	{%%cr_r60, %%cr_r61, %%cr_r62, %%cr_r63}, [%%cr_rd66+-8];\n"
        "	add.rn.f32 	%%cr_r64, %%cr_r56, %%cr_r60;\n"
        "	add.rn.f32 	%%cr_r65, %%cr_r57, %%cr_r61;\n"
        "	add.rn.f32 	%%cr_r66, %%cr_r58, %%cr_r62;\n"
        "	add.rn.f32 	%%cr_r67, %%cr_r59, %%cr_r63;\n"
        "	add.s64 	%%cr_rd67, %%cr_rd22, %%cr_rd76;\n"
        "	ld.global.v4.b32 	{%%cr_r68, %%cr_r69, %%cr_r70, %%cr_r71}, [%%cr_rd67+-12];\n"
        "	add.rn.f32 	%%cr_r106, %%cr_r64, %%cr_r68;\n"
        "	add.rn.f32 	%%cr_r107, %%cr_r65, %%cr_r69;\n"
        "	add.rn.f32 	%%cr_r108, %%cr_r66, %%cr_r70;\n"
        "	add.rn.f32 	%%cr_r109, %%cr_r67, %%cr_r71;\n"
        "	add.s64 	%%cr_rd78, %%cr_rd78, 4;\n"
        "	add.s64 	%%cr_rd76, %%cr_rd76, %%cr_rd21;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd18, %%cr_rd78;\n"
        "	@%%cr_p5 bra 	$L__BB43_8;\n"
        "$L__BB43_9:                             // %%cr_dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd80, 0;\n"
        "	@%%cr_p6 bra 	$L__BB43_12;\n"
        "// %%cr_bb.10:                              // %%cr_dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd68, %%cr_rd78, %%cr_rd9, %%cr_rd4;\n"
        "	mad.lo.s64 	%%cr_rd69, %%cr_rd68, %%cr_rd5, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd70, %%cr_rd69, 4;\n"
        "	add.s64 	%%cr_rd71, %%cr_rd70, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd79, %%cr_rd71, 8;\n"
        "	shl.b64 	%%cr_rd31, %%cr_rd10, 4;\n"
        "$L__BB43_11:                            // %%cr_dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.v4.b32 	{%%cr_r72, %%cr_r73, %%cr_r74, %%cr_r75}, [%%cr_rd79+-8];\n"
        "	add.rn.f32 	%%cr_r106, %%cr_r106, %%cr_r72;\n"
        "	add.rn.f32 	%%cr_r107, %%cr_r107, %%cr_r73;\n"
        "	add.rn.f32 	%%cr_r108, %%cr_r108, %%cr_r74;\n"
        "	add.rn.f32 	%%cr_r109, %%cr_r109, %%cr_r75;\n"
        "	add.s64 	%%cr_rd80, %%cr_rd80, -1;\n"
        "	add.s64 	%%cr_rd79, %%cr_rd79, %%cr_rd31;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd80, 0;\n"
        "	@%%cr_p7 bra 	$L__BB43_11;\n"
        "$L__BB43_12:                            // %%cr_dt_exit\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	add.s64 	%%cr_rd72, %%cr_rd3, %%cr_rd8;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd72, %%cr_rd38;\n"
        "	@%%cr_p8 bra 	$L__BB43_14;\n"
        "// %%cr_bb.13:                              // %%cr_then114\n"
        "	shl.b64 	%%cr_rd73, %%cr_rd72, 2;\n"
        "	add.s64 	%%cr_rd36, %%cr_rd1, %%cr_rd73;\n"
        "	ld.global.b32 	%%cr_r76, [%%cr_rd36];\n"
        "	add.rn.f32 	%%cr_r106, %%cr_r106, %%cr_r76;\n"
        "$L__BB43_14:                            // %%cr_ifcont116\n"
        "	add.rn.f32 	%%cr_r77, %%cr_r107, %%cr_r106;\n"
        "	add.rn.f32 	%%cr_r78, %%cr_r108, %%cr_r109;\n"
        "	add.rn.f32 	%%cr_r79, %%cr_r78, %%cr_r77;\n"
        "	shfl.sync.bfly.b32 	%%cr_r80, %%cr_r79, 16, 31, -1;\n"
        "	add.rn.f32 	%%cr_r81, %%cr_r79, %%cr_r80;\n"
        "	shfl.sync.bfly.b32 	%%cr_r82, %%cr_r81, 8, 31, -1;\n"
        "	add.rn.f32 	%%cr_r83, %%cr_r81, %%cr_r82;\n"
        "	shfl.sync.bfly.b32 	%%cr_r84, %%cr_r83, 4, 31, -1;\n"
        "	add.rn.f32 	%%cr_r85, %%cr_r83, %%cr_r84;\n"
        "	shfl.sync.bfly.b32 	%%cr_r86, %%cr_r85, 2, 31, -1;\n"
        "	add.rn.f32 	%%cr_r87, %%cr_r85, %%cr_r86;\n"
        "	shfl.sync.bfly.b32 	%%cr_r88, %%cr_r87, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p9, %%cr_r1, 0;\n"
        "	@%%cr_p9 bra 	$L__BB43_16;\n"
        "// %%cr_bb.15:                              // %%cr_then143\n"
        "	mov.b64 	%%cr_rd39, %4;\n"
        "	add.rn.f32 	%%cr_r32, %%cr_r87, %%cr_r88;\n"
        "	add.s64 	%%cr_rd37, %%cr_rd2, %%cr_rd39;\n"
        "	atom.global.add.f32 	%%cr_r89, [%%cr_rd37], %%cr_r32;\n"
        "$L__BB43_16:                            // %%cr_ifcont145\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(in_ptr), "l"(bytes), "l"(len), "l"(out_ptr), "l"(zero)
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

    int64_t needed_blocks = (N + (BLOCK_SIZE * 16) - 1) / (BLOCK_SIZE * 16);
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
