# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_lastman.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 -- FP32 loads/accumulators, FP64 cross-thread sum, last-workgroup write.
#   ;;
#   ;; Strategy:
#   ;;   Phase 1: float4 (128-bit) grid-stride loads into 4 FP32 accumulators per thread.
#   ;;   Phase 2: each thread's sum is widened to double ONCE; warp shuffle-xor reduction in double.
#   ;;   Phase 3: each warp leader atomic-adds its double into a persistent scratch cell (`partial`).
#   ;;   Phase 4: the last workgroup to arrive (ticket) swaps `partial` back to 0.0d, writes the float
#   ;;            result, and resets the ticket -- both scratch cells are ready for the next launch, so
#   ;;            the host does no per-call zeroing or conversion.
#   ;;
#   ;; Why FP64 only across threads (contest BUG-002): leaderboard mode re-seeds every timing repetition
#   ;; (hundreds of offset/scale draws). Thousands of FP32 atomics into one cell fail rtol=1e-5 on ~6% of
#   ;; draws; per-thread FP32 runs are short and stay >100x inside tolerance once the cross-thread sum is
#   ;; double (put_temp_files_here/vectorsum_mc.c).
#   ;;
#   ;; Hand-rolled last-man because when-is-last-workgroup is not implemented yet, and grid-reduce!'s
#   ;; return cell must have the reduced value's type (double here; the contest wants float).
#
#   (def-type in-vec      (vector float :address-space :global :align :compact))
#   (def-type acc-cell    (cell double :address-space :global))
#   (def-type ticket-cell (cell uint :address-space :global))
#   (def-type out-cell    (cell float :address-space :global))
#
#   (def-kernel vectorsum_kernel (input partial ticket result)
#     (declare #'(in-vec acc-cell ticket-cell out-cell => nil)
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
#       ;; Phase 1: 128-bit vector grid-stride loop, FP32 accumulators
#       (loop-vector-stride in4 (i)
#         (let ((v (~ in4 i)))
#           (set! a0 (+ a0 (x~ v)))
#           (set! a1 (+ a1 (y~ v)))
#           (set! a2 (+ a2 (z~ v)))
#           (set! a3 (+ a3 (w~ v)))))
#       ;; Tail: the 0..3 elements float4 cannot cover
#       (let ((t (+ (* n4 4ul) (to-ulong (get-global-id 0)))))
#         (when (< t n)
#           (set! a0 (+ a0 (~ input t)))))
#       ;; Phase 2 + 3: widen once, warp butterfly in double, one atomic per warp
#       (let ((acc (to-double (+ (+ a0 a1) (+ a2 a3)))))
#         (dec-times-by-half+ (m (/ (to-ulong (warp-size)) 2ul))
#           (set! acc (+ acc (shuffle-xor acc m))))
#         (when (= lane 0ul)
#           (atomic-add! (~ partial) acc)))
#       ;; Phase 4: every warp of this group has added; thread 0 releases, takes a ticket, and the
#       ;; last arrival acquires, publishes the float, and resets both scratch cells.
#       (sync-workgroup)
#       (when-thread-in-group-is 0
#         (mem-fence)
#         (let ((arrived (to-ulong (atomic-inc! (~ ticket)))))
#           (when (= arrived (- (get-num-groups 0) 1ul))
#             (mem-fence)
#             (set! (~ result) (to-float (atomic-xchg! (~ partial) 0.0d)))
#             (atomic-xchg! (~ ticket) 0u))))))
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
    uint64_t zero = 0ULL;
    uint64_t one = 1ULL;
    uint64_t four = 4ULL;
    uint64_t eight = 8ULL;
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<12>;\n"
        "	.reg .b32 	%%cr_r<132>;\n"
        "	.reg .b64 	%%cr_rd<120>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd41, %2;\n"
        "	mov.b64 	%%cr_rd46, %0;\n"
        "	mov.b64 	%%cr_rd47, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd46;\n"
        "	mov.b64 	%%cr_rd48, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd48;\n"
        "	mov.b64 	%%cr_rd49, %5;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd49;\n"
        "	mov.b64 	%%cr_rd50, %7;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd50;\n"
        "	shr.u64 	%%cr_rd51, %%cr_rd47, 4;\n"
        "	mov.u32 	%%cr_r37, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r38, %%ntid.x;\n"
        "	mov.u32 	%%cr_r39, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r39;\n"
        "	mul.wide.u32 	%%cr_rd9, %%cr_r37, %%cr_r38;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd9, %%cr_rd8;\n"
        "	mov.u32 	%%cr_r40, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd12, %%cr_r40, %%cr_r38;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd10, %%cr_rd51;\n"
        "	mov.b64 	%%cr_rd114, 0;\n"
        "	@%%cr_p1 bra 	$L__BB53_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd52, %%cr_rd10;\n"
        "	add.s64 	%%cr_rd13, %%cr_rd51, %%cr_rd52;\n"
        "	or.b64 	%%cr_rd53, %%cr_rd13, %%cr_rd12;\n"
        "	and.b64 	%%cr_rd54, %%cr_rd53, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd54, 0;\n"
        "	@%%cr_p2 bra 	$L__BB53_3;\n"
        "	bra.uni 	$L__BB53_2;\n"
        "$L__BB53_3:\n"
        "	div.u64 	%%cr_rd113, %%cr_rd13, %%cr_rd12;\n"
        "	bra.uni 	$L__BB53_4;\n"
        "$L__BB53_2:\n"
        "	cvt.u32.u64 	%%cr_r41, %%cr_rd12;\n"
        "	cvt.u32.u64 	%%cr_r42, %%cr_rd13;\n"
        "	div.u32 	%%cr_r43, %%cr_r42, %%cr_r41;\n"
        "	cvt.u64.u32 	%%cr_rd113, %%cr_r43;\n"
        "$L__BB53_4:\n"
        "	add.s64 	%%cr_rd114, %%cr_rd113, 1;\n"
        "$L__BB53_5:                             // %%ifcont\n"
        "	and.b64 	%%cr_rd5, %%cr_rd41, -4;\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r38;\n"
        "	cvt.u64.u32 	%%cr_rd11, %%cr_r40;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd114, 0;\n"
        "	mov.b32 	%%cr_r127, 0f00000000;\n"
        "	mov.b32 	%%cr_r128, %%cr_r127;\n"
        "	mov.b32 	%%cr_r129, %%cr_r127;\n"
        "	mov.b32 	%%cr_r130, %%cr_r127;\n"
        "	@%%cr_p3 bra 	$L__BB53_12;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r37;\n"
        "	and.b64 	%%cr_rd119, %%cr_rd114, 3;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd114, 4;\n"
        "	mov.b32 	%%cr_r130, 0f00000000;\n"
        "	mov.b64 	%%cr_rd117, 0;\n"
        "	mov.b32 	%%cr_r129, %%cr_r130;\n"
        "	mov.b32 	%%cr_r128, %%cr_r130;\n"
        "	mov.b32 	%%cr_r127, %%cr_r130;\n"
        "	@%%cr_p4 bra 	$L__BB53_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd20, %%cr_rd114, -4;\n"
        "	shl.b64 	%%cr_rd57, %%cr_rd9, 4;\n"
        "	add.s64 	%%cr_rd58, %%cr_rd57, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd21, %%cr_rd58, 12;\n"
        "	shl.b64 	%%cr_rd115, %%cr_rd8, 4;\n"
        "	shl.b64 	%%cr_rd23, %%cr_rd12, 6;\n"
        "	mad.lo.s64 	%%cr_rd59, %%cr_rd11, 3, %%cr_rd6;\n"
        "	mul.lo.s64 	%%cr_rd60, %%cr_rd59, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd61, %%cr_rd60, 4;\n"
        "	add.s64 	%%cr_rd62, %%cr_rd61, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd24, %%cr_rd62, 12;\n"
        "	add.s64 	%%cr_rd63, %%cr_rd6, %%cr_rd11;\n"
        "	mul.lo.s64 	%%cr_rd64, %%cr_rd63, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd65, %%cr_rd64, 4;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd1, %%cr_rd65;\n"
        "	shl.b64 	%%cr_rd66, %%cr_rd11, 1;\n"
        "	add.s64 	%%cr_rd67, %%cr_rd66, %%cr_rd6;\n"
        "	mul.lo.s64 	%%cr_rd68, %%cr_rd67, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd69, %%cr_rd68, 4;\n"
        "	add.s64 	%%cr_rd70, %%cr_rd69, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd26, %%cr_rd70, 8;\n"
        "	mov.b32 	%%cr_r130, 0f00000000;\n"
        "	mov.b64 	%%cr_rd117, 0;\n"
        "	mov.b32 	%%cr_r129, %%cr_r130;\n"
        "	mov.b32 	%%cr_r128, %%cr_r130;\n"
        "	mov.b32 	%%cr_r127, %%cr_r130;\n"
        "$L__BB53_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd71, %%cr_rd21, %%cr_rd115;\n"
        "	ld.global.v4.b32 	{%%cr_r48, %%cr_r49, %%cr_r50, %%cr_r51}, [%%cr_rd71+-12];\n"
        "	add.rn.f32 	%%cr_r52, %%cr_r127, %%cr_r48;\n"
        "	add.rn.f32 	%%cr_r53, %%cr_r128, %%cr_r49;\n"
        "	add.rn.f32 	%%cr_r54, %%cr_r129, %%cr_r50;\n"
        "	add.rn.f32 	%%cr_r55, %%cr_r130, %%cr_r51;\n"
        "	add.s64 	%%cr_rd72, %%cr_rd25, %%cr_rd115;\n"
        "	ld.global.v4.b32 	{%%cr_r56, %%cr_r57, %%cr_r58, %%cr_r59}, [%%cr_rd72];\n"
        "	add.rn.f32 	%%cr_r60, %%cr_r52, %%cr_r56;\n"
        "	add.rn.f32 	%%cr_r61, %%cr_r53, %%cr_r57;\n"
        "	add.rn.f32 	%%cr_r62, %%cr_r54, %%cr_r58;\n"
        "	add.rn.f32 	%%cr_r63, %%cr_r55, %%cr_r59;\n"
        "	add.s64 	%%cr_rd73, %%cr_rd26, %%cr_rd115;\n"
        "	ld.global.v4.b32 	{%%cr_r64, %%cr_r65, %%cr_r66, %%cr_r67}, [%%cr_rd73+-8];\n"
        "	add.rn.f32 	%%cr_r68, %%cr_r60, %%cr_r64;\n"
        "	add.rn.f32 	%%cr_r69, %%cr_r61, %%cr_r65;\n"
        "	add.rn.f32 	%%cr_r70, %%cr_r62, %%cr_r66;\n"
        "	add.rn.f32 	%%cr_r71, %%cr_r63, %%cr_r67;\n"
        "	add.s64 	%%cr_rd74, %%cr_rd24, %%cr_rd115;\n"
        "	ld.global.v4.b32 	{%%cr_r72, %%cr_r73, %%cr_r74, %%cr_r75}, [%%cr_rd74+-12];\n"
        "	add.rn.f32 	%%cr_r127, %%cr_r68, %%cr_r72;\n"
        "	add.rn.f32 	%%cr_r128, %%cr_r69, %%cr_r73;\n"
        "	add.rn.f32 	%%cr_r129, %%cr_r70, %%cr_r74;\n"
        "	add.rn.f32 	%%cr_r130, %%cr_r71, %%cr_r75;\n"
        "	add.s64 	%%cr_rd117, %%cr_rd117, 4;\n"
        "	add.s64 	%%cr_rd115, %%cr_rd115, %%cr_rd23;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd20, %%cr_rd117;\n"
        "	@%%cr_p5 bra 	$L__BB53_8;\n"
        "$L__BB53_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd119, 0;\n"
        "	@%%cr_p6 bra 	$L__BB53_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd75, %%cr_rd117, %%cr_rd11, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd76, %%cr_rd75, %%cr_rd7, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd77, %%cr_rd76, 4;\n"
        "	add.s64 	%%cr_rd78, %%cr_rd77, %%cr_rd1;\n"
        "	add.s64 	%%cr_rd118, %%cr_rd78, 8;\n"
        "	shl.b64 	%%cr_rd33, %%cr_rd12, 4;\n"
        "$L__BB53_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.v4.b32 	{%%cr_r76, %%cr_r77, %%cr_r78, %%cr_r79}, [%%cr_rd118+-8];\n"
        "	add.rn.f32 	%%cr_r127, %%cr_r127, %%cr_r76;\n"
        "	add.rn.f32 	%%cr_r128, %%cr_r128, %%cr_r77;\n"
        "	add.rn.f32 	%%cr_r129, %%cr_r129, %%cr_r78;\n"
        "	add.rn.f32 	%%cr_r130, %%cr_r130, %%cr_r79;\n"
        "	add.s64 	%%cr_rd119, %%cr_rd119, -1;\n"
        "	add.s64 	%%cr_rd118, %%cr_rd118, %%cr_rd33;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd119, 0;\n"
        "	@%%cr_p7 bra 	$L__BB53_11;\n"
        "$L__BB53_12:                            // %%dt_exit\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	add.s64 	%%cr_rd79, %%cr_rd5, %%cr_rd10;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd79, %%cr_rd41;\n"
        "	@%%cr_p8 bra 	$L__BB53_14;\n"
        "// %%bb.13:                              // %%then130\n"
        "	shl.b64 	%%cr_rd80, %%cr_rd79, 2;\n"
        "	add.s64 	%%cr_rd38, %%cr_rd1, %%cr_rd80;\n"
        "	ld.global.b32 	%%cr_r80, [%%cr_rd38];\n"
        "	add.rn.f32 	%%cr_r127, %%cr_r127, %%cr_r80;\n"
        "$L__BB53_14:                            // %%ifcont132\n"
        "	mov.b64 	%%cr_rd42, %4;\n"
        "	mov.u32 	%%cr_r2, %%ntid.y;\n"
        "	mov.u32 	%%cr_r3, %%tid.y;\n"
        "	mov.u32 	%%cr_r4, %%tid.z;\n"
        "	add.rn.f32 	%%cr_r81, %%cr_r128, %%cr_r127;\n"
        "	add.rn.f32 	%%cr_r82, %%cr_r129, %%cr_r130;\n"
        "	add.rn.f32 	%%cr_r83, %%cr_r82, %%cr_r81;\n"
        "	cvt.f64.f32 	%%cr_rd81, %%cr_r83;\n"
        "	cvt.u32.u64 	%%cr_r84, %%cr_rd81;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r85}, %%cr_rd81; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r86, %%cr_r84, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r87, %%cr_r85, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd82, %%cr_r86;\n"
        "	cvt.u64.u32 	%%cr_rd83, %%cr_r87;\n"
        "	shl.b64 	%%cr_rd84, %%cr_rd83, 32;\n"
        "	or.b64 	%%cr_rd85, %%cr_rd84, %%cr_rd82;\n"
        "	add.rn.f64 	%%cr_rd86, %%cr_rd81, %%cr_rd85;\n"
        "	cvt.u32.u64 	%%cr_r88, %%cr_rd86;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r89}, %%cr_rd86; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r90, %%cr_r88, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r91, %%cr_r89, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd87, %%cr_r90;\n"
        "	cvt.u64.u32 	%%cr_rd88, %%cr_r91;\n"
        "	shl.b64 	%%cr_rd89, %%cr_rd88, 32;\n"
        "	or.b64 	%%cr_rd90, %%cr_rd89, %%cr_rd87;\n"
        "	add.rn.f64 	%%cr_rd91, %%cr_rd86, %%cr_rd90;\n"
        "	cvt.u32.u64 	%%cr_r92, %%cr_rd91;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r93}, %%cr_rd91; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r94, %%cr_r92, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r95, %%cr_r93, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd92, %%cr_r94;\n"
        "	cvt.u64.u32 	%%cr_rd93, %%cr_r95;\n"
        "	shl.b64 	%%cr_rd94, %%cr_rd93, 32;\n"
        "	or.b64 	%%cr_rd95, %%cr_rd94, %%cr_rd92;\n"
        "	add.rn.f64 	%%cr_rd96, %%cr_rd91, %%cr_rd95;\n"
        "	cvt.u32.u64 	%%cr_r96, %%cr_rd96;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r97}, %%cr_rd96; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r98, %%cr_r96, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r99, %%cr_r97, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd97, %%cr_r98;\n"
        "	cvt.u64.u32 	%%cr_rd98, %%cr_r99;\n"
        "	shl.b64 	%%cr_rd99, %%cr_rd98, 32;\n"
        "	or.b64 	%%cr_rd100, %%cr_rd99, %%cr_rd97;\n"
        "	add.rn.f64 	%%cr_rd39, %%cr_rd96, %%cr_rd100;\n"
        "	cvt.u32.u64 	%%cr_r100, %%cr_rd39;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r101}, %%cr_rd39; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r35, %%cr_r100, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r36, %%cr_r101, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p9, %%cr_r1, 0;\n"
        "	@%%cr_p9 bra 	$L__BB53_16;\n"
        "// %%bb.15:                              // %%then159\n"
        "	cvt.u64.u32 	%%cr_rd101, %%cr_r36;\n"
        "	shl.b64 	%%cr_rd102, %%cr_rd101, 32;\n"
        "	cvt.u64.u32 	%%cr_rd103, %%cr_r35;\n"
        "	or.b64 	%%cr_rd104, %%cr_rd102, %%cr_rd103;\n"
        "	add.rn.f64 	%%cr_rd105, %%cr_rd39, %%cr_rd104;\n"
        "	add.s64 	%%cr_rd106, %%cr_rd2, %%cr_rd42;\n"
        "	atom.global.add.f64 	%%cr_rd107, [%%cr_rd106], %%cr_rd105;\n"
        "$L__BB53_16:                            // %%ifcont161\n"
        "	cvt.u32.u64 	%%cr_r102, %%cr_rd7;\n"
        "	cvt.u32.u64 	%%cr_r103, %%cr_rd8;\n"
        "	bar.sync 	0;\n"
        "	mul.lo.s32 	%%cr_r104, %%cr_r2, %%cr_r102;\n"
        "	mul.lo.s32 	%%cr_r105, %%cr_r104, %%cr_r4;\n"
        "	mad.lo.s32 	%%cr_r106, %%cr_r3, %%cr_r102, %%cr_r103;\n"
        "	or.b32 	%%cr_r107, %%cr_r105, %%cr_r106;\n"
        "	setp.ne.b32 	%%cr_p10, %%cr_r107, 0;\n"
        "	@%%cr_p10 bra 	$L__BB53_18;\n"
        "// %%bb.17:                              // %%then181\n"
        "	mov.b64 	%%cr_rd43, %6;\n"
        "	membar.gl;\n"
        "	add.s64 	%%cr_rd40, %%cr_rd3, %%cr_rd43;\n"
        "	atom.global.add.u32 	%%cr_r108, [%%cr_rd40], 1;\n"
        "	cvt.u64.u32 	%%cr_rd108, %%cr_r108;\n"
        "	add.s64 	%%cr_rd109, %%cr_rd11, -1;\n"
        "	setp.eq.b64 	%%cr_p11, %%cr_rd109, %%cr_rd108;\n"
        "	@%%cr_p11 bra 	$L__BB53_19;\n"
        "	bra.uni 	$L__BB53_18;\n"
        "$L__BB53_19:                            // %%then204\n"
        "	mov.b64 	%%cr_rd44, %8;\n"
        "	membar.gl;\n"
        "	add.s64 	%%cr_rd110, %%cr_rd2, %%cr_rd42;\n"
        "	atom.global.exch.b64 	%%cr_rd111, [%%cr_rd110], 0;\n"
        "	cvt.rn.f32.f64 	%%cr_r109, %%cr_rd111;\n"
        "	add.s64 	%%cr_rd112, %%cr_rd4, %%cr_rd44;\n"
        "	st.global.b32 	[%%cr_rd112], %%cr_r109;\n"
        "	atom.global.exch.b32 	%%cr_r110, [%%cr_rd40], 0;\n"
        "$L__BB53_18:                            // %%ifcont183\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(in_ptr), "l"(bytes), "l"(len), "l"(partial_ptr), "l"(zero), "l"(ticket_ptr), "l"(zero), "l"(out_ptr), "l"(zero)
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
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_vectorsum_kernel, BLOCK_SIZE, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * 4) : 1024;
    }
    int64_t needed_blocks = (N + (BLOCK_SIZE * 16) - 1) / (BLOCK_SIZE * 16);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    uint64_t partial = reinterpret_cast<uint64_t>(scratch.data_ptr());
    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE>>>(
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
