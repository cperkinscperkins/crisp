# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_lastman_wg_u8.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 -- FP32 loads/accumulators, FP64 cross-thread sum, last-workgroup write.
#   ;;
#   ;; Strategy:
#   ;;   Phase 1: float4 (128-bit) grid-stride loads (unroll 8) into 4 FP32 accumulators per thread.
#   ;;   Phase 2: each thread's sum is widened to double ONCE.
#   ;;   Phase 3: reduce-workgroup in double; thread 0 atomic-adds into a persistent scratch cell (`partial`).
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
#   (def-kernel vectorsum_kernel (input &out partial ticket result)
#     (declare #'(in-vec &out acc-cell ticket-cell out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((n    (length~ input))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input float4 :length n4))
#           (a0   0.0)
#           (a1   0.0)
#           (a2   0.0)
#           (a3   0.0))
#       ;; Phase 1: 128-bit vector grid-stride loop, FP32 accumulators
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
#       ;; Phase 2 + 3: widen once, workgroup reduction in double, ONE atomic per workgroup
#       (let ((acc (to-double (+ (+ a0 a1) (+ a2 a3)))))
#         (reduce-workgroup #'+ acc 0.0d)
#         ;; Phase 4: thread 0 adds, releases, takes a ticket; the last arrival acquires,
#         ;; publishes the float, and resets both scratch cells.
#         (when-thread-in-group-is 0
#           (atomic-add! (~ partial) acc)
#           (mem-fence)
#           (let ((arrived (to-ulong (atomic-inc! (~ ticket)))))
#             (when (= arrived (- (get-num-groups 0) 1ul))
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
        "	.reg .pred 	%%cr_p<15>;\n"
        "	.reg .b32 	%%cr_r<177>;\n"
        "	.reg .b64 	%%cr_rd<158>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd50, %3;\n"
        "	mov.b64 	%%cr_rd57, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd57;\n"
        "	mov.b64 	%%cr_rd58, %4;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd58;\n"
        "	mov.b64 	%%cr_rd59, %6;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd59;\n"
        "	mov.b64 	%%cr_rd60, %2;\n"
        "	mov.b64 	%%cr_rd61, %8;\n"
        "	cvta.to.global.u64 	%%cr_rd5, %%cr_rd61;\n"
        "	shr.u64 	%%cr_rd62, %%cr_rd60, 4;\n"
        "	mov.u32 	%%cr_r39, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r40, %%ntid.x;\n"
        "	mov.u32 	%%cr_r41, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd9, %%cr_r41;\n"
        "	mul.wide.u32 	%%cr_rd63, %%cr_r39, %%cr_r40;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd63, %%cr_rd9;\n"
        "	mov.u32 	%%cr_r42, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd12, %%cr_r42, %%cr_r40;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd10, %%cr_rd62;\n"
        "	mov.b64 	%%cr_rd151, 0;\n"
        "	@%%cr_p1 bra 	$L__BB72_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd64, %%cr_rd10;\n"
        "	add.s64 	%%cr_rd13, %%cr_rd62, %%cr_rd64;\n"
        "	or.b64 	%%cr_rd65, %%cr_rd13, %%cr_rd12;\n"
        "	and.b64 	%%cr_rd66, %%cr_rd65, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd66, 0;\n"
        "	@%%cr_p2 bra 	$L__BB72_3;\n"
        "	bra.uni 	$L__BB72_2;\n"
        "$L__BB72_3:\n"
        "	div.u64 	%%cr_rd150, %%cr_rd13, %%cr_rd12;\n"
        "	bra.uni 	$L__BB72_4;\n"
        "$L__BB72_2:\n"
        "	cvt.u32.u64 	%%cr_r43, %%cr_rd12;\n"
        "	cvt.u32.u64 	%%cr_r44, %%cr_rd13;\n"
        "	div.u32 	%%cr_r45, %%cr_r44, %%cr_r43;\n"
        "	cvt.u64.u32 	%%cr_rd150, %%cr_r45;\n"
        "$L__BB72_4:\n"
        "	add.s64 	%%cr_rd151, %%cr_rd150, 1;\n"
        "$L__BB72_5:                             // %%ifcont\n"
        "	and.b64 	%%cr_rd6, %%cr_rd50, -4;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r40;\n"
        "	cvt.u64.u32 	%%cr_rd11, %%cr_r42;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd151, 0;\n"
        "	mov.b32 	%%cr_r172, 0f00000000;\n"
        "	mov.b32 	%%cr_r173, %%cr_r172;\n"
        "	mov.b32 	%%cr_r174, %%cr_r172;\n"
        "	mov.b32 	%%cr_r175, %%cr_r172;\n"
        "	@%%cr_p3 bra 	$L__BB72_12;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r39;\n"
        "	and.b64 	%%cr_rd156, %%cr_rd151, 7;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd151, 8;\n"
        "	mov.b32 	%%cr_r175, 0f00000000;\n"
        "	mov.b64 	%%cr_rd154, 0;\n"
        "	mov.b32 	%%cr_r174, %%cr_r175;\n"
        "	mov.b32 	%%cr_r173, %%cr_r175;\n"
        "	mov.b32 	%%cr_r172, %%cr_r175;\n"
        "	@%%cr_p4 bra 	$L__BB72_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	and.b64 	%%cr_rd20, %%cr_rd151, -8;\n"
        "	shl.b64 	%%cr_rd69, %%cr_rd10, 4;\n"
        "	or.b64 	%%cr_rd21, %%cr_rd69, 12;\n"
        "	shl.b64 	%%cr_rd22, %%cr_rd12, 7;\n"
        "	mad.lo.s64 	%%cr_rd70, %%cr_rd11, 7, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd71, %%cr_rd70, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd72, %%cr_rd71, 4;\n"
        "	shl.b64 	%%cr_rd73, %%cr_rd9, 4;\n"
        "	add.s64 	%%cr_rd74, %%cr_rd72, %%cr_rd73;\n"
        "	or.b64 	%%cr_rd23, %%cr_rd74, 12;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd7, %%cr_rd11;\n"
        "	mad.lo.s64 	%%cr_rd76, %%cr_rd75, %%cr_rd8, %%cr_rd9;\n"
        "	shl.b64 	%%cr_rd24, %%cr_rd76, 4;\n"
        "	mad.lo.s64 	%%cr_rd77, %%cr_rd11, 6, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd78, %%cr_rd77, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd79, %%cr_rd78, 4;\n"
        "	add.s64 	%%cr_rd80, %%cr_rd79, %%cr_rd73;\n"
        "	or.b64 	%%cr_rd25, %%cr_rd80, 12;\n"
        "	mad.lo.s64 	%%cr_rd81, %%cr_rd11, 5, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd82, %%cr_rd81, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd83, %%cr_rd82, 4;\n"
        "	add.s64 	%%cr_rd84, %%cr_rd83, %%cr_rd73;\n"
        "	or.b64 	%%cr_rd26, %%cr_rd84, 12;\n"
        "	shl.b64 	%%cr_rd85, %%cr_rd11, 2;\n"
        "	add.s64 	%%cr_rd86, %%cr_rd85, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd87, %%cr_rd86, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd88, %%cr_rd87, 4;\n"
        "	add.s64 	%%cr_rd89, %%cr_rd88, %%cr_rd73;\n"
        "	or.b64 	%%cr_rd27, %%cr_rd89, 12;\n"
        "	shl.b64 	%%cr_rd90, %%cr_rd11, 1;\n"
        "	add.s64 	%%cr_rd91, %%cr_rd90, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd92, %%cr_rd91, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd93, %%cr_rd92, 4;\n"
        "	add.s64 	%%cr_rd28, %%cr_rd93, %%cr_rd73;\n"
        "	mad.lo.s64 	%%cr_rd94, %%cr_rd11, 3, %%cr_rd7;\n"
        "	mul.lo.s64 	%%cr_rd95, %%cr_rd94, %%cr_rd8;\n"
        "	shl.b64 	%%cr_rd96, %%cr_rd95, 4;\n"
        "	add.s64 	%%cr_rd97, %%cr_rd96, %%cr_rd73;\n"
        "	or.b64 	%%cr_rd29, %%cr_rd97, 8;\n"
        "	mov.b32 	%%cr_r175, 0f00000000;\n"
        "	mov.b64 	%%cr_rd154, 0;\n"
        "	mov.b64 	%%cr_rd152, %%cr_rd2;\n"
        "	mov.b32 	%%cr_r174, %%cr_r175;\n"
        "	mov.b32 	%%cr_r173, %%cr_r175;\n"
        "	mov.b32 	%%cr_r172, %%cr_r175;\n"
        "$L__BB72_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	add.s64 	%%cr_rd98, %%cr_rd152, %%cr_rd21;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r50, %%cr_r51, %%cr_r52, %%cr_r53}, [%%cr_rd98+-12];\n"
        "	add.rn.f32 	%%cr_r54, %%cr_r172, %%cr_r50;\n"
        "	add.rn.f32 	%%cr_r55, %%cr_r173, %%cr_r51;\n"
        "	add.rn.f32 	%%cr_r56, %%cr_r174, %%cr_r52;\n"
        "	add.rn.f32 	%%cr_r57, %%cr_r175, %%cr_r53;\n"
        "	add.s64 	%%cr_rd99, %%cr_rd152, %%cr_rd24;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r58, %%cr_r59, %%cr_r60, %%cr_r61}, [%%cr_rd99];\n"
        "	add.rn.f32 	%%cr_r62, %%cr_r54, %%cr_r58;\n"
        "	add.rn.f32 	%%cr_r63, %%cr_r55, %%cr_r59;\n"
        "	add.rn.f32 	%%cr_r64, %%cr_r56, %%cr_r60;\n"
        "	add.rn.f32 	%%cr_r65, %%cr_r57, %%cr_r61;\n"
        "	add.s64 	%%cr_rd100, %%cr_rd152, %%cr_rd28;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r66, %%cr_r67, %%cr_r68, %%cr_r69}, [%%cr_rd100];\n"
        "	add.rn.f32 	%%cr_r70, %%cr_r62, %%cr_r66;\n"
        "	add.rn.f32 	%%cr_r71, %%cr_r63, %%cr_r67;\n"
        "	add.rn.f32 	%%cr_r72, %%cr_r64, %%cr_r68;\n"
        "	add.rn.f32 	%%cr_r73, %%cr_r65, %%cr_r69;\n"
        "	add.s64 	%%cr_rd101, %%cr_rd152, %%cr_rd29;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r74, %%cr_r75, %%cr_r76, %%cr_r77}, [%%cr_rd101+-8];\n"
        "	add.rn.f32 	%%cr_r78, %%cr_r70, %%cr_r74;\n"
        "	add.rn.f32 	%%cr_r79, %%cr_r71, %%cr_r75;\n"
        "	add.rn.f32 	%%cr_r80, %%cr_r72, %%cr_r76;\n"
        "	add.rn.f32 	%%cr_r81, %%cr_r73, %%cr_r77;\n"
        "	add.s64 	%%cr_rd102, %%cr_rd152, %%cr_rd27;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r82, %%cr_r83, %%cr_r84, %%cr_r85}, [%%cr_rd102+-12];\n"
        "	add.rn.f32 	%%cr_r86, %%cr_r78, %%cr_r82;\n"
        "	add.rn.f32 	%%cr_r87, %%cr_r79, %%cr_r83;\n"
        "	add.rn.f32 	%%cr_r88, %%cr_r80, %%cr_r84;\n"
        "	add.rn.f32 	%%cr_r89, %%cr_r81, %%cr_r85;\n"
        "	add.s64 	%%cr_rd103, %%cr_rd152, %%cr_rd26;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r90, %%cr_r91, %%cr_r92, %%cr_r93}, [%%cr_rd103+-12];\n"
        "	add.rn.f32 	%%cr_r94, %%cr_r86, %%cr_r90;\n"
        "	add.rn.f32 	%%cr_r95, %%cr_r87, %%cr_r91;\n"
        "	add.rn.f32 	%%cr_r96, %%cr_r88, %%cr_r92;\n"
        "	add.rn.f32 	%%cr_r97, %%cr_r89, %%cr_r93;\n"
        "	add.s64 	%%cr_rd104, %%cr_rd152, %%cr_rd25;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r98, %%cr_r99, %%cr_r100, %%cr_r101}, [%%cr_rd104+-12];\n"
        "	add.rn.f32 	%%cr_r102, %%cr_r94, %%cr_r98;\n"
        "	add.rn.f32 	%%cr_r103, %%cr_r95, %%cr_r99;\n"
        "	add.rn.f32 	%%cr_r104, %%cr_r96, %%cr_r100;\n"
        "	add.rn.f32 	%%cr_r105, %%cr_r97, %%cr_r101;\n"
        "	add.s64 	%%cr_rd105, %%cr_rd152, %%cr_rd23;\n"
        "	ld.global.cs.v4.b32 	{%%cr_r106, %%cr_r107, %%cr_r108, %%cr_r109}, [%%cr_rd105+-12];\n"
        "	add.rn.f32 	%%cr_r172, %%cr_r102, %%cr_r106;\n"
        "	add.rn.f32 	%%cr_r173, %%cr_r103, %%cr_r107;\n"
        "	add.rn.f32 	%%cr_r174, %%cr_r104, %%cr_r108;\n"
        "	add.rn.f32 	%%cr_r175, %%cr_r105, %%cr_r109;\n"
        "	add.s64 	%%cr_rd154, %%cr_rd154, 8;\n"
        "	add.s64 	%%cr_rd152, %%cr_rd152, %%cr_rd22;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd20, %%cr_rd154;\n"
        "	@%%cr_p5 bra 	$L__BB72_8;\n"
        "$L__BB72_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd156, 0;\n"
        "	@%%cr_p6 bra 	$L__BB72_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd106, %%cr_rd154, %%cr_rd11, %%cr_rd7;\n"
        "	mad.lo.s64 	%%cr_rd107, %%cr_rd106, %%cr_rd8, %%cr_rd9;\n"
        "	shl.b64 	%%cr_rd108, %%cr_rd107, 4;\n"
        "	add.s64 	%%cr_rd109, %%cr_rd108, %%cr_rd2;\n"
        "	add.s64 	%%cr_rd155, %%cr_rd109, 8;\n"
        "	shl.b64 	%%cr_rd36, %%cr_rd12, 4;\n"
        "$L__BB72_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.cs.v4.b32 	{%%cr_r110, %%cr_r111, %%cr_r112, %%cr_r113}, [%%cr_rd155+-8];\n"
        "	add.rn.f32 	%%cr_r172, %%cr_r172, %%cr_r110;\n"
        "	add.rn.f32 	%%cr_r173, %%cr_r173, %%cr_r111;\n"
        "	add.rn.f32 	%%cr_r174, %%cr_r174, %%cr_r112;\n"
        "	add.rn.f32 	%%cr_r175, %%cr_r175, %%cr_r113;\n"
        "	add.s64 	%%cr_rd156, %%cr_rd156, -1;\n"
        "	add.s64 	%%cr_rd155, %%cr_rd155, %%cr_rd36;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd156, 0;\n"
        "	@%%cr_p7 bra 	$L__BB72_11;\n"
        "$L__BB72_12:                            // %%dt_exit\n"
        "	mov.b64 	%%cr_rd55, %0;\n"
        "	mov.b64 	%%cr_rd56, %10;\n"
        "	add.s64 	%%cr_rd110, %%cr_rd6, %%cr_rd10;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd110, %%cr_rd50;\n"
        "	@%%cr_p8 bra 	$L__BB72_14;\n"
        "// %%bb.13:                              // %%then132\n"
        "	shl.b64 	%%cr_rd111, %%cr_rd110, 2;\n"
        "	add.s64 	%%cr_rd41, %%cr_rd2, %%cr_rd111;\n"
        "	ld.global.nc.b32 	%%cr_r114, [%%cr_rd41];\n"
        "	add.rn.f32 	%%cr_r172, %%cr_r172, %%cr_r114;\n"
        "$L__BB72_14:                            // %%ifcont134\n"
        "	add.s64 	%%cr_rd1, %%cr_rd55, %%cr_rd56;\n"
        "	mov.u32 	%%cr_r1, %%ntid.y;\n"
        "	mov.u32 	%%cr_r2, %%tid.y;\n"
        "	mov.u32 	%%cr_r3, %%ntid.z;\n"
        "	mov.u32 	%%cr_r4, %%tid.z;\n"
        "	add.rn.f32 	%%cr_r115, %%cr_r173, %%cr_r172;\n"
        "	add.rn.f32 	%%cr_r116, %%cr_r174, %%cr_r175;\n"
        "	add.rn.f32 	%%cr_r117, %%cr_r116, %%cr_r115;\n"
        "	cvt.f64.f32 	%%cr_rd112, %%cr_r117;\n"
        "	cvt.u32.u64 	%%cr_r118, %%cr_rd112;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r119}, %%cr_rd112; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r120, %%cr_r118, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r121, %%cr_r119, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd113, %%cr_r120;\n"
        "	cvt.u64.u32 	%%cr_rd114, %%cr_r121;\n"
        "	shl.b64 	%%cr_rd115, %%cr_rd114, 32;\n"
        "	or.b64 	%%cr_rd116, %%cr_rd115, %%cr_rd113;\n"
        "	add.rn.f64 	%%cr_rd117, %%cr_rd112, %%cr_rd116;\n"
        "	cvt.u32.u64 	%%cr_r122, %%cr_rd117;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r123}, %%cr_rd117; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r124, %%cr_r122, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r125, %%cr_r123, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd118, %%cr_r124;\n"
        "	cvt.u64.u32 	%%cr_rd119, %%cr_r125;\n"
        "	shl.b64 	%%cr_rd120, %%cr_rd119, 32;\n"
        "	or.b64 	%%cr_rd121, %%cr_rd120, %%cr_rd118;\n"
        "	add.rn.f64 	%%cr_rd122, %%cr_rd117, %%cr_rd121;\n"
        "	cvt.u32.u64 	%%cr_r126, %%cr_rd122;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r127}, %%cr_rd122; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r128, %%cr_r126, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r129, %%cr_r127, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd123, %%cr_r128;\n"
        "	cvt.u64.u32 	%%cr_rd124, %%cr_r129;\n"
        "	shl.b64 	%%cr_rd125, %%cr_rd124, 32;\n"
        "	or.b64 	%%cr_rd126, %%cr_rd125, %%cr_rd123;\n"
        "	add.rn.f64 	%%cr_rd127, %%cr_rd122, %%cr_rd126;\n"
        "	cvt.u32.u64 	%%cr_r130, %%cr_rd127;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r131}, %%cr_rd127; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r132, %%cr_r130, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r133, %%cr_r131, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd128, %%cr_r132;\n"
        "	cvt.u64.u32 	%%cr_rd129, %%cr_r133;\n"
        "	shl.b64 	%%cr_rd130, %%cr_rd129, 32;\n"
        "	or.b64 	%%cr_rd131, %%cr_rd130, %%cr_rd128;\n"
        "	add.rn.f64 	%%cr_rd42, %%cr_rd127, %%cr_rd131;\n"
        "	cvt.u32.u64 	%%cr_r134, %%cr_rd42;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r135}, %%cr_rd42; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r35, %%cr_r134, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r36, %%cr_r135, 1, 31, -1;\n"
        "	mov.u32 	%%cr_r136, %%laneid;\n"
        "	setp.ne.b32 	%%cr_p9, %%cr_r136, 0;\n"
        "	cvt.u32.u64 	%%cr_r154, %%cr_rd8;\n"
        "	cvt.u32.u64 	%%cr_r155, %%cr_rd9;\n"
        "	@%%cr_p9 bra 	$L__BB72_16;\n"
        "// %%bb.15:                              // %%then160\n"
        "	cvt.u64.u32 	%%cr_rd132, %%cr_r36;\n"
        "	shl.b64 	%%cr_rd133, %%cr_rd132, 32;\n"
        "	cvt.u64.u32 	%%cr_rd134, %%cr_r35;\n"
        "	or.b64 	%%cr_rd135, %%cr_rd133, %%cr_rd134;\n"
        "	add.rn.f64 	%%cr_rd136, %%cr_rd42, %%cr_rd135;\n"
        "	mad.lo.s32 	%%cr_r139, %%cr_r4, %%cr_r1, %%cr_r2;\n"
        "	mad.lo.s32 	%%cr_r140, %%cr_r139, %%cr_r154, %%cr_r155;\n"
        "	shr.u32 	%%cr_r141, %%cr_r140, 2;\n"
        "	and.b32 	%%cr_r142, %%cr_r141, 134217720;\n"
        "	cvt.u64.u32 	%%cr_rd137, %%cr_r142;\n"
        "	add.s64 	%%cr_rd138, %%cr_rd1, %%cr_rd137;\n"
        "	st.shared.b64 	[%%cr_rd138], %%cr_rd136;\n"
        "$L__BB72_16:                            // %%ifcont162\n"
        "	bar.sync 	0;\n"
        "	mul.lo.s32 	%%cr_r145, %%cr_r154, %%cr_r1;\n"
        "	mul.lo.s32 	%%cr_r37, %%cr_r145, %%cr_r3;\n"
        "	mad.lo.s32 	%%cr_r146, %%cr_r2, %%cr_r154, %%cr_r155;\n"
        "	mad.lo.s32 	%%cr_r38, %%cr_r145, %%cr_r4, %%cr_r146;\n"
        "	setp.lt.u32 	%%cr_p10, %%cr_r37, 64;\n"
        "	@%%cr_p10 bra 	$L__BB72_21;\n"
        "	bra.uni 	$L__BB72_17;\n"
        "$L__BB72_21:                            // %%lv_exit225\n"
        "	setp.eq.b32 	%%cr_p13, %%cr_r38, 0;\n"
        "	@%%cr_p13 bra 	$L__BB72_22;\n"
        "	bra.uni 	$L__BB72_23;\n"
        "$L__BB72_22:                            // %%then303\n"
        "	mov.b64 	%%cr_rd52, %7;\n"
        "	mov.b64 	%%cr_rd51, %5;\n"
        "	ld.shared.b64 	%%cr_rd144, [%%cr_rd1];\n"
        "	add.s64 	%%cr_rd48, %%cr_rd3, %%cr_rd51;\n"
        "	atom.global.add.f64 	%%cr_rd145, [%%cr_rd48], %%cr_rd144;\n"
        "	membar.gl;\n"
        "	add.s64 	%%cr_rd49, %%cr_rd4, %%cr_rd52;\n"
        "	atom.global.add.u32 	%%cr_r151, [%%cr_rd49], 1;\n"
        "	cvt.u64.u32 	%%cr_rd146, %%cr_r151;\n"
        "	add.s64 	%%cr_rd147, %%cr_rd11, -1;\n"
        "	setp.eq.b64 	%%cr_p14, %%cr_rd147, %%cr_rd146;\n"
        "	@%%cr_p14 bra 	$L__BB72_24;\n"
        "	bra.uni 	$L__BB72_23;\n"
        "$L__BB72_24:                            // %%then327\n"
        "	mov.b64 	%%cr_rd53, %9;\n"
        "	membar.gl;\n"
        "	atom.global.exch.b64 	%%cr_rd148, [%%cr_rd48], 0;\n"
        "	cvt.rn.f32.f64 	%%cr_r152, %%cr_rd148;\n"
        "	add.s64 	%%cr_rd149, %%cr_rd5, %%cr_rd53;\n"
        "	st.global.b32 	[%%cr_rd149], %%cr_r152;\n"
        "	atom.global.exch.b32 	%%cr_r153, [%%cr_rd49], 0;\n"
        "$L__BB72_23:                            // %%ifcont305\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "$L__BB72_17:                            // %%lv_pre223\n"
        "	shr.u32 	%%cr_r147, %%cr_r37, 6;\n"
        "	cvt.u64.u32 	%%cr_rd157, %%cr_r147;\n"
        "	shl.b32 	%%cr_r148, %%cr_r38, 3;\n"
        "	cvt.u64.u32 	%%cr_rd139, %%cr_r148;\n"
        "	add.s64 	%%cr_rd44, %%cr_rd1, %%cr_rd139;\n"
        "	bra.uni 	$L__BB72_18;\n"
        "$L__BB72_20:                            // %%ifcont234\n"
        "                                        //   in Loop: Header=BB72_18 Depth=1\n"
        "	bar.sync 	0;\n"
        "	shr.u64 	%%cr_rd47, %%cr_rd157, 1;\n"
        "	setp.lt.u64 	%%cr_p12, %%cr_rd157, 2;\n"
        "	mov.b64 	%%cr_rd157, %%cr_rd47;\n"
        "	@%%cr_p12 bra 	$L__BB72_21;\n"
        "$L__BB72_18:                            // %%lv_body224\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	cvt.u32.u64 	%%cr_r149, %%cr_rd157;\n"
        "	setp.lt.u32 	%%cr_p11, %%cr_r38, %%cr_r149;\n"
        "	@%%cr_p11 bra 	$L__BB72_19;\n"
        "	bra.uni 	$L__BB72_20;\n"
        "$L__BB72_19:                            // %%then232\n"
        "                                        //   in Loop: Header=BB72_18 Depth=1\n"
        "	add.s32 	%%cr_r150, %%cr_r38, %%cr_r149;\n"
        "	mul.wide.u32 	%%cr_rd140, %%cr_r150, 8;\n"
        "	add.s64 	%%cr_rd46, %%cr_rd1, %%cr_rd140;\n"
        "	ld.shared.b64 	%%cr_rd141, [%%cr_rd44];\n"
        "	ld.shared.b64 	%%cr_rd142, [%%cr_rd46];\n"
        "	add.rn.f64 	%%cr_rd143, %%cr_rd141, %%cr_rd142;\n"
        "	st.shared.b64 	[%%cr_rd44], %%cr_rd143;\n"
        "	bra.uni 	$L__BB72_20;\n"
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
    int64_t needed_blocks = (N + (BLOCK_SIZE * 4) - 1) / (BLOCK_SIZE * 4);
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
