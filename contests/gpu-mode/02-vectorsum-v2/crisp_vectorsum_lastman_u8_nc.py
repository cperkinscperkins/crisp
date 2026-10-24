# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_lastman_wg_u8_nc.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 -- FP32 loads/accumulators (.nc only, no .cs), FP64 cross-thread sum, last-workgroup write.
#   ;;
#   ;; Strategy:
#   ;;   - Designed for GPUs with large L2 caches relative to the benchmark sizes (B200: 128 MB L2; L4: 48 MB L2),
#   ;;     where benchmark cases N = 1.64M..26.2M (6.5 MB..104.9 MB) reside in L2 across timing repetitions.
#   ;;   - Declares `input` before `&out` without `:cache :str-eaming` so Crisp emits `ld.global.nc.v4.b32`
#   ;;     (keeping L2 residency AND allowing LLVM to fold constant offsets into `[%rd+-12]`).
#   ;;   - Uses single-barrier workgroup reduction (32-lane warp butterfly + 1 `bar.sync 0` + thread-0 8-way sum).
#
#   (def-type in-vec      (vector float :address-space :global :align :compact))
#   (def-type acc-cell    (cell double :address-space :global))
#   (def-type ticket-cell (cell uint :address-space :global))
#   (def-type out-cell    (cell float :address-space :global))
#   (def-type warp-smem   (vector double :address-space :local :align :compact))
#
#   (def-kernel vectorsum_kernel (input &out partial ticket result)
#     (declare #'(in-vec &out acc-cell ticket-cell out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((tid  (to-ulong (get-local-id 0)))
#           (lane (to-ulong (warp-lane)))
#           (wid  (/ tid 32ul))
#           (ng   (to-ulong (get-num-groups 0)))
#           (n    (length~ input))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input float4 :length n4))
#           (wsums (make-scratch-vector warp-smem 8))
#           (a0   0.0)
#           (a1   0.0)
#           (a2   0.0)
#           (a3   0.0))
#       ;; Phase 1: 128-bit vector grid-stride loop, FP32 accumulators (unroll 8, .nc loads)
#       (loop-vector-stride in4 (i)
#         (declare (unroll 8))
#         (let ((v (~ in4 i)))
#           (set! a0 (+ a0 (x~ v)))
#           (set! a1 (+ a1 (y~ v)))
#           (set! a2 (+ a2 (z~ v)))
#           (set! a3 (+ a3 (w~ v)))))
#       ;; Tail: the 0..3 elements float4 cannot cover
#       (let ((t (+ (* n4 4ul) (to-ulong (get-global-id 0)))))
#         (when (< t n)
#           (set! a0 (+ a0 (~ input t)))))
#       ;; Phase 2 + 3: widen once, warp butterfly in double, single-barrier workgroup sum
#       (let ((acc (to-double (+ (+ a0 a1) (+ a2 a3)))))
#         (dec-times-by-half+ (m 16ul)
#           (set! acc (+ acc (shuffle-xor acc m))))
#         (when (= lane 0ul)
#           (set! (~ wsums wid) acc)))
#       (sync-workgroup)
#       ;; Phase 4: thread 0 sums the 8 warp doubles, atomic-adds, and last workgroup writes float
#       (when (= tid 0ul)
#         (let ((wsum (+ (+ (+ (~ wsums 0ul) (~ wsums 1ul))
#                           (+ (~ wsums 2ul) (~ wsums 3ul)))
#                        (+ (+ (~ wsums 4ul) (~ wsums 5ul))
#                           (+ (~ wsums 6ul) (~ wsums 7ul))))))
#           (atomic-add! (~ partial) wsum)
#           (mem-fence)
#           (let ((arrived (to-ulong (atomic-inc! (~ ticket)))))
#             (when (= arrived (- ng 1ul))
#               (mem-fence)
#               (set! (~ result) (to-float (atomic-xchg! (~ partial) 0.0d)))
#               (atomic-xchg! (~ ticket) 0u)))))))
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
    uint64_t partial_ptr,
    uint64_t ticket_ptr,
    uint64_t out_ptr,
    uint64_t len
) {
    uint64_t bytes = len * 4ULL;
    extern __shared__ __align__(128) unsigned char crisp_smem[];
    uint64_t smem_ptr = static_cast<uint64_t>(__cvta_generic_to_shared(crisp_smem));
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<12>;\n"
        "	.reg .b32 	%%cr_r<156>;\n"
        "	.reg .b64 	%%cr_rd<155>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd45, %3;\n"
        "	mov.b64 	%%cr_rd52, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd52;\n"
        "	mov.b64 	%%cr_rd53, %4;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd53;\n"
        "	mov.b64 	%%cr_rd54, %6;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd54;\n"
        "	mov.b64 	%%cr_rd55, %2;\n"
        "	mov.b64 	%%cr_rd56, %8;\n"
        "	cvta.to.global.u64 	%%cr_rd5, %%cr_rd56;\n"
        "	mov.u32 	%%cr_r34, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r34;\n"
        "	mov.u32 	%%cr_r35, %%nctaid.x;\n"
        "	shr.u64 	%%cr_rd57, %%cr_rd55, 4;\n"
        "	mov.u32 	%%cr_r36, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r37, %%ntid.x;\n"
        "	mul.wide.u32 	%%cr_rd58, %%cr_r36, %%cr_r37;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd58, %%cr_rd6;\n"
        "	mul.wide.u32 	%%cr_rd12, %%cr_r35, %%cr_r37;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd11, %%cr_rd57;\n"
        "	mov.b64 	%%cr_rd149, 0;\n"
        "	@%%cr_p1 bra 	$L__BB72_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd59, %%cr_rd11;\n"
        "	add.s64 	%%cr_rd13, %%cr_rd57, %%cr_rd59;\n"
        "	or.b64 	%%cr_rd60, %%cr_rd13, %%cr_rd12;\n"
        "	and.b64 	%%cr_rd61, %%cr_rd60, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd61, 0;\n"
        "	@%%cr_p2 bra 	$L__BB72_3;\n"
        "	bra.uni 	$L__BB72_2;\n"
        "$L__BB72_3:\n"
        "	div.u64 	%%cr_rd148, %%cr_rd13, %%cr_rd12;\n"
        "	bra.uni 	$L__BB72_4;\n"
        "$L__BB72_2:\n"
        "	cvt.u32.u64 	%%cr_r38, %%cr_rd12;\n"
        "	cvt.u32.u64 	%%cr_r39, %%cr_rd13;\n"
        "	div.u32 	%%cr_r40, %%cr_r39, %%cr_r38;\n"
        "	cvt.u64.u32 	%%cr_rd148, %%cr_r40;\n"
        "$L__BB72_4:\n"
        "	add.s64 	%%cr_rd149, %%cr_rd148, 1;\n"
        "$L__BB72_5:                             // %%ifcont\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r35;\n"
        "	and.b64 	%%cr_rd8, %%cr_rd45, -4;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd149, 0;\n"
        "	mov.b32 	%%cr_r151, 0f00000000;\n"
        "	mov.b32 	%%cr_r152, %%cr_r151;\n"
        "	mov.b32 	%%cr_r153, %%cr_r151;\n"
        "	mov.b32 	%%cr_r154, %%cr_r151;\n"
        "	@%%cr_p3 bra 	$L__BB72_12;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd9, %%cr_r36;\n"
        "	cvt.u64.u32 	%%cr_rd10, %%cr_r37;\n"
        "	and.b64 	%%cr_rd153, %%cr_rd149, 7;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd149, 8;\n"
        "	mov.b32 	%%cr_r154, 0f00000000;\n"
        "	mov.b64 	%%cr_rd152, 0;\n"
        "	mov.b32 	%%cr_r153, %%cr_r154;\n"
        "	mov.b32 	%%cr_r152, %%cr_r154;\n"
        "	mov.b32 	%%cr_r151, %%cr_r154;\n"
        "	@%%cr_p4 bra 	$L__BB72_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd20, %%cr_rd149, -8;\n"
        "	add.s64 	%%cr_rd64, %%cr_rd9, %%cr_rd7;\n"
        "	mad.lo.s64 	%%cr_rd65, %%cr_rd64, %%cr_rd10, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd21, %%cr_rd65, 4;\n"
        "	shl.b64 	%%cr_rd22, %%cr_rd12, 7;\n"
        "	shl.b64 	%%cr_rd66, %%cr_rd7, 1;\n"
        "	add.s64 	%%cr_rd67, %%cr_rd66, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd68, %%cr_rd67, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd69, %%cr_rd68, 4;\n"
        "	shl.b64 	%%cr_rd70, %%cr_rd6, 4;\n"
        "	add.s64 	%%cr_rd23, %%cr_rd69, %%cr_rd70;\n"
        "	mad.lo.s64 	%%cr_rd71, %%cr_rd7, 3, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd72, %%cr_rd71, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd73, %%cr_rd72, 4;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd73, %%cr_rd70;\n"
        "	shl.b64 	%%cr_rd74, %%cr_rd7, 2;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd74, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd76, %%cr_rd75, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd77, %%cr_rd76, 4;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd77, %%cr_rd70;\n"
        "	mad.lo.s64 	%%cr_rd78, %%cr_rd7, 5, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd79, %%cr_rd78, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd80, %%cr_rd79, 4;\n"
        "	add.s64 	%%cr_rd26, %%cr_rd80, %%cr_rd70;\n"
        "	mad.lo.s64 	%%cr_rd81, %%cr_rd7, 6, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd82, %%cr_rd81, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd83, %%cr_rd82, 4;\n"
        "	add.s64 	%%cr_rd27, %%cr_rd83, %%cr_rd70;\n"
        "	mad.lo.s64 	%%cr_rd84, %%cr_rd7, 7, %%cr_rd9;\n"
        "	mul.lo.s64 	%%cr_rd85, %%cr_rd84, %%cr_rd10;\n"
        "	shl.b64 	%%cr_rd86, %%cr_rd85, 4;\n"
        "	add.s64 	%%cr_rd28, %%cr_rd86, %%cr_rd70;\n"
        "	shl.b64 	%%cr_rd29, %%cr_rd11, 4;\n"
        "	mov.b32 	%%cr_r154, 0f00000000;\n"
        "	mov.b64 	%%cr_rd152, 0;\n"
        "	mov.b64 	%%cr_rd150, %%cr_rd2;\n"
        "	mov.b32 	%%cr_r153, %%cr_r154;\n"
        "	mov.b32 	%%cr_r152, %%cr_r154;\n"
        "	mov.b32 	%%cr_r151, %%cr_r154;\n"
        "$L__BB72_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	add.s64 	%%cr_rd87, %%cr_rd150, %%cr_rd29;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r45, %%cr_r46, %%cr_r47, %%cr_r48}, [%%cr_rd87];\n"
        "	add.rn.f32 	%%cr_r49, %%cr_r151, %%cr_r45;\n"
        "	add.rn.f32 	%%cr_r50, %%cr_r152, %%cr_r46;\n"
        "	add.rn.f32 	%%cr_r51, %%cr_r153, %%cr_r47;\n"
        "	add.rn.f32 	%%cr_r52, %%cr_r154, %%cr_r48;\n"
        "	add.s64 	%%cr_rd88, %%cr_rd150, %%cr_rd21;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r53, %%cr_r54, %%cr_r55, %%cr_r56}, [%%cr_rd88];\n"
        "	add.rn.f32 	%%cr_r57, %%cr_r49, %%cr_r53;\n"
        "	add.rn.f32 	%%cr_r58, %%cr_r50, %%cr_r54;\n"
        "	add.rn.f32 	%%cr_r59, %%cr_r51, %%cr_r55;\n"
        "	add.rn.f32 	%%cr_r60, %%cr_r52, %%cr_r56;\n"
        "	add.s64 	%%cr_rd89, %%cr_rd150, %%cr_rd23;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r61, %%cr_r62, %%cr_r63, %%cr_r64}, [%%cr_rd89];\n"
        "	add.rn.f32 	%%cr_r65, %%cr_r57, %%cr_r61;\n"
        "	add.rn.f32 	%%cr_r66, %%cr_r58, %%cr_r62;\n"
        "	add.rn.f32 	%%cr_r67, %%cr_r59, %%cr_r63;\n"
        "	add.rn.f32 	%%cr_r68, %%cr_r60, %%cr_r64;\n"
        "	add.s64 	%%cr_rd90, %%cr_rd150, %%cr_rd24;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r69, %%cr_r70, %%cr_r71, %%cr_r72}, [%%cr_rd90];\n"
        "	add.rn.f32 	%%cr_r73, %%cr_r65, %%cr_r69;\n"
        "	add.rn.f32 	%%cr_r74, %%cr_r66, %%cr_r70;\n"
        "	add.rn.f32 	%%cr_r75, %%cr_r67, %%cr_r71;\n"
        "	add.rn.f32 	%%cr_r76, %%cr_r68, %%cr_r72;\n"
        "	add.s64 	%%cr_rd91, %%cr_rd150, %%cr_rd25;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r77, %%cr_r78, %%cr_r79, %%cr_r80}, [%%cr_rd91];\n"
        "	add.rn.f32 	%%cr_r81, %%cr_r73, %%cr_r77;\n"
        "	add.rn.f32 	%%cr_r82, %%cr_r74, %%cr_r78;\n"
        "	add.rn.f32 	%%cr_r83, %%cr_r75, %%cr_r79;\n"
        "	add.rn.f32 	%%cr_r84, %%cr_r76, %%cr_r80;\n"
        "	add.s64 	%%cr_rd92, %%cr_rd150, %%cr_rd26;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r85, %%cr_r86, %%cr_r87, %%cr_r88}, [%%cr_rd92];\n"
        "	add.rn.f32 	%%cr_r89, %%cr_r81, %%cr_r85;\n"
        "	add.rn.f32 	%%cr_r90, %%cr_r82, %%cr_r86;\n"
        "	add.rn.f32 	%%cr_r91, %%cr_r83, %%cr_r87;\n"
        "	add.rn.f32 	%%cr_r92, %%cr_r84, %%cr_r88;\n"
        "	add.s64 	%%cr_rd93, %%cr_rd150, %%cr_rd27;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r93, %%cr_r94, %%cr_r95, %%cr_r96}, [%%cr_rd93];\n"
        "	add.rn.f32 	%%cr_r97, %%cr_r89, %%cr_r93;\n"
        "	add.rn.f32 	%%cr_r98, %%cr_r90, %%cr_r94;\n"
        "	add.rn.f32 	%%cr_r99, %%cr_r91, %%cr_r95;\n"
        "	add.rn.f32 	%%cr_r100, %%cr_r92, %%cr_r96;\n"
        "	add.s64 	%%cr_rd94, %%cr_rd150, %%cr_rd28;\n"
        "	ld.global.nc.v4.b32 	{%%cr_r101, %%cr_r102, %%cr_r103, %%cr_r104}, [%%cr_rd94];\n"
        "	add.rn.f32 	%%cr_r151, %%cr_r97, %%cr_r101;\n"
        "	add.rn.f32 	%%cr_r152, %%cr_r98, %%cr_r102;\n"
        "	add.rn.f32 	%%cr_r153, %%cr_r99, %%cr_r103;\n"
        "	add.rn.f32 	%%cr_r154, %%cr_r100, %%cr_r104;\n"
        "	add.s64 	%%cr_rd152, %%cr_rd152, 8;\n"
        "	add.s64 	%%cr_rd150, %%cr_rd150, %%cr_rd22;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd20, %%cr_rd152;\n"
        "	@%%cr_p5 bra 	$L__BB72_8;\n"
        "$L__BB72_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd153, 0;\n"
        "	@%%cr_p6 bra 	$L__BB72_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd95, %%cr_rd152, %%cr_rd7, %%cr_rd9;\n"
        "	mad.lo.s64 	%%cr_rd96, %%cr_rd95, %%cr_rd10, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd97, %%cr_rd96, 4;\n"
        "	add.s64 	%%cr_rd154, %%cr_rd2, %%cr_rd97;\n"
        "	shl.b64 	%%cr_rd36, %%cr_rd12, 4;\n"
        "$L__BB72_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.nc.v4.b32 	{%%cr_r105, %%cr_r106, %%cr_r107, %%cr_r108}, [%%cr_rd154];\n"
        "	add.rn.f32 	%%cr_r151, %%cr_r151, %%cr_r105;\n"
        "	add.rn.f32 	%%cr_r152, %%cr_r152, %%cr_r106;\n"
        "	add.rn.f32 	%%cr_r153, %%cr_r153, %%cr_r107;\n"
        "	add.rn.f32 	%%cr_r154, %%cr_r154, %%cr_r108;\n"
        "	add.s64 	%%cr_rd154, %%cr_rd154, %%cr_rd36;\n"
        "	add.s64 	%%cr_rd153, %%cr_rd153, -1;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd153, 0;\n"
        "	@%%cr_p7 bra 	$L__BB72_11;\n"
        "$L__BB72_12:                            // %%dt_exit\n"
        "	mov.b64 	%%cr_rd50, %0;\n"
        "	mov.b64 	%%cr_rd51, %10;\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	add.s64 	%%cr_rd98, %%cr_rd8, %%cr_rd11;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd98, %%cr_rd45;\n"
        "	@%%cr_p8 bra 	$L__BB72_14;\n"
        "// %%bb.13:                              // %%then146\n"
        "	shl.b64 	%%cr_rd99, %%cr_rd98, 2;\n"
        "	add.s64 	%%cr_rd41, %%cr_rd2, %%cr_rd99;\n"
        "	ld.global.nc.b32 	%%cr_r109, [%%cr_rd41];\n"
        "	add.rn.f32 	%%cr_r151, %%cr_r151, %%cr_r109;\n"
        "$L__BB72_14:                            // %%ifcont148\n"
        "	add.s64 	%%cr_rd1, %%cr_rd50, %%cr_rd51;\n"
        "	add.rn.f32 	%%cr_r110, %%cr_r152, %%cr_r151;\n"
        "	add.rn.f32 	%%cr_r111, %%cr_r153, %%cr_r154;\n"
        "	add.rn.f32 	%%cr_r112, %%cr_r111, %%cr_r110;\n"
        "	cvt.f64.f32 	%%cr_rd100, %%cr_r112;\n"
        "	cvt.u32.u64 	%%cr_r113, %%cr_rd100;\n"
        "	mov.b64 	{_, %%cr_r114}, %%cr_rd100;\n"
        "	shfl.sync.bfly.b32 	%%cr_r115, %%cr_r113, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r116, %%cr_r114, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd101, %%cr_r115;\n"
        "	cvt.u64.u32 	%%cr_rd102, %%cr_r116;\n"
        "	shl.b64 	%%cr_rd103, %%cr_rd102, 32;\n"
        "	or.b64 	%%cr_rd104, %%cr_rd103, %%cr_rd101;\n"
        "	add.rn.f64 	%%cr_rd105, %%cr_rd100, %%cr_rd104;\n"
        "	cvt.u32.u64 	%%cr_r117, %%cr_rd105;\n"
        "	mov.b64 	{_, %%cr_r118}, %%cr_rd105;\n"
        "	shfl.sync.bfly.b32 	%%cr_r119, %%cr_r117, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r120, %%cr_r118, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd106, %%cr_r119;\n"
        "	cvt.u64.u32 	%%cr_rd107, %%cr_r120;\n"
        "	shl.b64 	%%cr_rd108, %%cr_rd107, 32;\n"
        "	or.b64 	%%cr_rd109, %%cr_rd108, %%cr_rd106;\n"
        "	add.rn.f64 	%%cr_rd110, %%cr_rd105, %%cr_rd109;\n"
        "	cvt.u32.u64 	%%cr_r121, %%cr_rd110;\n"
        "	mov.b64 	{_, %%cr_r122}, %%cr_rd110;\n"
        "	shfl.sync.bfly.b32 	%%cr_r123, %%cr_r121, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r124, %%cr_r122, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd111, %%cr_r123;\n"
        "	cvt.u64.u32 	%%cr_rd112, %%cr_r124;\n"
        "	shl.b64 	%%cr_rd113, %%cr_rd112, 32;\n"
        "	or.b64 	%%cr_rd114, %%cr_rd113, %%cr_rd111;\n"
        "	add.rn.f64 	%%cr_rd115, %%cr_rd110, %%cr_rd114;\n"
        "	cvt.u32.u64 	%%cr_r125, %%cr_rd115;\n"
        "	mov.b64 	{_, %%cr_r126}, %%cr_rd115;\n"
        "	shfl.sync.bfly.b32 	%%cr_r127, %%cr_r125, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r128, %%cr_r126, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd116, %%cr_r127;\n"
        "	cvt.u64.u32 	%%cr_rd117, %%cr_r128;\n"
        "	shl.b64 	%%cr_rd118, %%cr_rd117, 32;\n"
        "	or.b64 	%%cr_rd119, %%cr_rd118, %%cr_rd116;\n"
        "	add.rn.f64 	%%cr_rd42, %%cr_rd115, %%cr_rd119;\n"
        "	cvt.u32.u64 	%%cr_r129, %%cr_rd42;\n"
        "	mov.b64 	{_, %%cr_r130}, %%cr_rd42;\n"
        "	shfl.sync.bfly.b32 	%%cr_r32, %%cr_r129, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r33, %%cr_r130, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p9, %%cr_r1, 0;\n"
        "	@%%cr_p9 bra 	$L__BB72_16;\n"
        "// %%bb.15:                              // %%then175\n"
        "	cvt.u64.u32 	%%cr_rd120, %%cr_r33;\n"
        "	shl.b64 	%%cr_rd121, %%cr_rd120, 32;\n"
        "	cvt.u64.u32 	%%cr_rd122, %%cr_r32;\n"
        "	or.b64 	%%cr_rd123, %%cr_rd121, %%cr_rd122;\n"
        "	add.rn.f64 	%%cr_rd124, %%cr_rd42, %%cr_rd123;\n"
        "	shr.u64 	%%cr_rd125, %%cr_rd6, 2;\n"
        "	and.b64 	%%cr_rd126, %%cr_rd125, 248;\n"
        "	add.s64 	%%cr_rd127, %%cr_rd1, %%cr_rd126;\n"
        "	st.shared.b64 	[%%cr_rd127], %%cr_rd124;\n"
        "$L__BB72_16:                            // %%ifcont177\n"
        "	cvt.u32.u64 	%%cr_r131, %%cr_rd6;\n"
        "	bar.sync 	0;\n"
        "	setp.ne.b32 	%%cr_p10, %%cr_r131, 0;\n"
        "	@%%cr_p10 bra 	$L__BB72_18;\n"
        "// %%bb.17:                              // %%then190\n"
        "	mov.b64 	%%cr_rd47, %7;\n"
        "	mov.b64 	%%cr_rd46, %5;\n"
        "	ld.shared.b64 	%%cr_rd128, [%%cr_rd1];\n"
        "	ld.shared.b64 	%%cr_rd129, [%%cr_rd1+8];\n"
        "	add.rn.f64 	%%cr_rd130, %%cr_rd128, %%cr_rd129;\n"
        "	ld.shared.b64 	%%cr_rd131, [%%cr_rd1+16];\n"
        "	ld.shared.b64 	%%cr_rd132, [%%cr_rd1+24];\n"
        "	add.rn.f64 	%%cr_rd133, %%cr_rd131, %%cr_rd132;\n"
        "	add.rn.f64 	%%cr_rd134, %%cr_rd130, %%cr_rd133;\n"
        "	ld.shared.b64 	%%cr_rd135, [%%cr_rd1+32];\n"
        "	ld.shared.b64 	%%cr_rd136, [%%cr_rd1+40];\n"
        "	add.rn.f64 	%%cr_rd137, %%cr_rd135, %%cr_rd136;\n"
        "	ld.shared.b64 	%%cr_rd138, [%%cr_rd1+48];\n"
        "	ld.shared.b64 	%%cr_rd139, [%%cr_rd1+56];\n"
        "	add.rn.f64 	%%cr_rd140, %%cr_rd138, %%cr_rd139;\n"
        "	add.rn.f64 	%%cr_rd141, %%cr_rd137, %%cr_rd140;\n"
        "	add.rn.f64 	%%cr_rd142, %%cr_rd134, %%cr_rd141;\n"
        "	add.s64 	%%cr_rd43, %%cr_rd3, %%cr_rd46;\n"
        "	atom.global.add.f64 	%%cr_rd143, [%%cr_rd43], %%cr_rd142;\n"
        "	membar.gl;\n"
        "	add.s64 	%%cr_rd44, %%cr_rd4, %%cr_rd47;\n"
        "	atom.global.add.u32 	%%cr_r132, [%%cr_rd44], 1;\n"
        "	cvt.u64.u32 	%%cr_rd144, %%cr_r132;\n"
        "	add.s64 	%%cr_rd145, %%cr_rd7, -1;\n"
        "	setp.eq.b64 	%%cr_p11, %%cr_rd145, %%cr_rd144;\n"
        "	@%%cr_p11 bra 	$L__BB72_19;\n"
        "	bra.uni 	$L__BB72_18;\n"
        "$L__BB72_19:                            // %%then263\n"
        "	mov.b64 	%%cr_rd48, %9;\n"
        "	membar.gl;\n"
        "	atom.global.exch.b64 	%%cr_rd146, [%%cr_rd43], 0;\n"
        "	cvt.rn.f32.f64 	%%cr_r133, %%cr_rd146;\n"
        "	add.s64 	%%cr_rd147, %%cr_rd5, %%cr_rd48;\n"
        "	st.global.b32 	[%%cr_rd147], %%cr_r133;\n"
        "	atom.global.exch.b32 	%%cr_r134, [%%cr_rd44], 0;\n"
        "$L__BB72_18:                            // %%ifcont192\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(0ULL), "l"(in_ptr), "l"(bytes), "l"(len), "l"(partial_ptr), "l"(0ULL), "l"(ticket_ptr), "l"(0ULL), "l"(out_ptr), "l"(0ULL), "l"(smem_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output) {
    int64_t N = input.numel();
    if (!input.is_contiguous()) {
        input = input.contiguous();
    }
    // [0] = double partial sum, [1] low 4 bytes = uint ticket. The kernel resets both to zero.
    static torch::Tensor scratch;
    if (!scratch.defined()) {
        scratch = torch::zeros({2}, input.options().dtype(torch::kFloat64));
    }
    if (N <= 0) {
        output.zero_();
        return output.dim() > 0 ? output.squeeze(0) : output;
    }

    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_vectorsum_kernel, BLOCK_SIZE, 64);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 1) : 1024;
    }
    int64_t needed_blocks = (N + (BLOCK_SIZE * 16) - 1) / (BLOCK_SIZE * 16);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    uint64_t partial = reinterpret_cast<uint64_t>(scratch.data_ptr());
    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE, 64>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        partial,
        partial + 8ULL,
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output.dim() > 0 ? output.squeeze(0) : output;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output);"""

_crisp_mod = load_inline(
    name="crisp_vectorsum_lastman_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vectorsum"],
    extra_cuda_cflags=["-O3"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_vectorsum(inp, out)
