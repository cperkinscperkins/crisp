# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_tile8_fastwg.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 -- Persistent 32 KB contiguous-tile loop + single-barrier workgroup reduction.
#   ;;
#   ;; Strategy:
#   ;;   Phase 1: Each workgroup of 256 threads loops over contiguous 32 KB tiles (8 float4s/thread = 2,048 float4s
#   ;;            = 8,192 floats per tile) with 128-bit `ld.global.cs.nc.L2::256B.v4.f32` loads.
#   ;;            Unlike strided unroll-8 (which needs 8 separate runtime-stride 64-bit registers), all 8 loads in a
#   ;;            tile use constant immediate offsets (-28672 .. +0) off a single 64-bit pointer register!
#   ;;   Phase 2: Any remainder float4s (< 2,048) and 0..3 scalar tail elements are accumulated cleanly.
#   ;;   Phase 3: Each thread widens its FP32 sum (`a0+a1+a2+a3`) to FP64 ONCE, performs a 32-lane warp butterfly
#   ;;            reduction in registers, and warp leaders write 8 doubles to a 64-byte shared memory array.
#   ;;   Phase 4: After ONE `sync-workgroup` (`bar.sync 0`), thread 0 pairwise-sums the 8 warp doubles in shared
#   ;;            memory (zero loop barriers!), performs 1 `atom.global.add.f64`, and the last workgroup writes
#   ;;            the `float` result and resets both scratch cells.
#
#   (def-type in-vec      (vector float :address-space :global :align :compact :cache (:str-eaming :prefetch 256)))
#   (def-type acc-cell    (cell double :address-space :global))
#   (def-type ticket-cell (cell uint :address-space :global))
#   (def-type out-cell    (cell float :address-space :global))
#   (def-type warp-smem   (vector double :address-space :local :align :compact))
#
#   (def-kernel vectorsum_kernel (input &out partial ticket result)
#     (declare #'(in-vec &out acc-cell ticket-cell out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((bid    (to-ulong (get-workgroup-id 0)))
#           (tid    (to-ulong (get-local-id 0)))
#           (ng     (to-ulong (get-num-groups 0)))
#           (lane   (to-ulong (warp-lane)))
#           (wid    (/ tid 32ul))
#           (n      (length~ input))
#           (n4     (/ n 4ul))
#           (ntiles (/ n4 2048ul))
#           (in4    (make-vector input float4 :length n4))
#           (wsums  (make-scratch-vector warp-smem 8))
#           (a0     0.0)
#           (a1     0.0)
#           (a2     0.0)
#           (a3     0.0))
#       ;; Phase 1: Full 32 KB contiguous tiles (2,048 float4s = 8,192 floats per tile)
#       (let ((iters (if (>= bid ntiles) 0ul (+ 1ul (/ (- (- ntiles 1ul) bid) ng))))
#             (base  (+ (* bid 2048ul) tid))
#             (step  (* ng 2048ul)))
#         (dotimes (k iters)
#           (let ((v0 (~ in4 base))
#                 (v1 (~ in4 (+ base 256ul)))
#                 (v2 (~ in4 (+ base 512ul)))
#                 (v3 (~ in4 (+ base 768ul)))
#                 (v4 (~ in4 (+ base 1024ul)))
#                 (v5 (~ in4 (+ base 1280ul)))
#                 (v6 (~ in4 (+ base 1536ul)))
#                 (v7 (~ in4 (+ base 1792ul))))
#             (set! a0 (+ a0 (+ (+ (x~ v0) (x~ v1)) (+ (x~ v2) (x~ v3)))))
#             (set! a1 (+ a1 (+ (+ (y~ v0) (y~ v1)) (+ (y~ v2) (y~ v3)))))
#             (set! a2 (+ a2 (+ (+ (z~ v0) (z~ v1)) (+ (z~ v2) (z~ v3)))))
#             (set! a3 (+ a3 (+ (+ (w~ v0) (w~ v1)) (+ (w~ v2) (w~ v3)))))
#             (set! a0 (+ a0 (+ (+ (x~ v4) (x~ v5)) (+ (x~ v6) (x~ v7)))))
#             (set! a1 (+ a1 (+ (+ (y~ v4) (y~ v5)) (+ (y~ v6) (y~ v7)))))
#             (set! a2 (+ a2 (+ (+ (z~ v4) (z~ v5)) (+ (z~ v6) (z~ v7)))))
#             (set! a3 (+ a3 (+ (+ (w~ v4) (w~ v5)) (+ (w~ v6) (w~ v7))))))
#           (set! base (+ base step))))
#       ;; Phase 2: Remainder float4s (when n4 is not a multiple of 2,048) + 0..3 scalar tail
#       (let ((rem_start (* ntiles 2048ul))
#             (gid (+ (* bid 256ul) tid))
#             (gs  (* ng 256ul)))
#         (let ((rem_idx (+ rem_start gid)))
#           (when (< rem_idx n4)
#             (let ((rem_iters (+ 1ul (/ (- (- n4 1ul) rem_idx) gs))))
#               (dotimes (r rem_iters)
#                 (declare (unroll nil))
#                 (let ((v (~ in4 rem_idx)))
#                   (set! a0 (+ a0 (x~ v)))
#                   (set! a1 (+ a1 (y~ v)))
#                   (set! a2 (+ a2 (z~ v)))
#                   (set! a3 (+ a3 (w~ v))))
#                 (set! rem_idx (+ rem_idx gs))))))
#         (let ((t (+ (* n4 4ul) gid)))
#           (when (< t n)
#             (set! a0 (+ a0 (~ input t))))))
#       ;; Phase 3: Widen once per thread + warp butterfly in FP64
#       (let ((acc (to-double (+ (+ a0 a1) (+ a2 a3)))))
#         (dec-times-by-half+ (m 16ul)
#           (set! acc (+ acc (shuffle-xor acc m))))
#         (when (= lane 0ul)
#           (set! (~ wsums wid) acc)))
#       (sync-workgroup)
#       ;; Phase 4: Warp 0 reduces the 8 warp sums in shared memory + thread 0 atomic-adds + last-man ticket write
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
        "	.reg .b32 	%%cr_r<148>;\n"
        "	.reg .b64 	%%cr_rd<133>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd40, %2;\n"
        "	mov.b64 	%%cr_rd47, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd47;\n"
        "	mov.b64 	%%cr_rd48, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd48;\n"
        "	mov.b64 	%%cr_rd49, %5;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd49;\n"
        "	mov.b64 	%%cr_rd50, %7;\n"
        "	cvta.to.global.u64 	%%cr_rd5, %%cr_rd50;\n"
        "	mov.u32 	%%cr_r30, %%ctaid.x;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r30;\n"
        "	mov.u32 	%%cr_r31, %%tid.x;\n"
        "	mov.u32 	%%cr_r32, %%nctaid.x;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r32;\n"
        "	shr.u64 	%%cr_rd10, %%cr_rd40, 13;\n"
        "	setp.le.u64 	%%cr_p1, %%cr_rd10, %%cr_rd6;\n"
        "	mov.b64 	%%cr_rd127, 0;\n"
        "	@%%cr_p1 bra 	$L__BB72_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd51, %%cr_rd6;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd10, %%cr_rd51;\n"
        "	and.b64 	%%cr_rd52, %%cr_rd11, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd52, 0;\n"
        "	@%%cr_p2 bra 	$L__BB72_3;\n"
        "	bra.uni 	$L__BB72_2;\n"
        "$L__BB72_3:\n"
        "	div.u64 	%%cr_rd126, %%cr_rd11, %%cr_rd8;\n"
        "	bra.uni 	$L__BB72_4;\n"
        "$L__BB72_2:\n"
        "	cvt.u32.u64 	%%cr_r33, %%cr_rd8;\n"
        "	cvt.u32.u64 	%%cr_r34, %%cr_rd11;\n"
        "	div.u32 	%%cr_r35, %%cr_r34, %%cr_r33;\n"
        "	cvt.u64.u32 	%%cr_rd126, %%cr_r35;\n"
        "$L__BB72_4:\n"
        "	add.s64 	%%cr_rd127, %%cr_rd126, 1;\n"
        "$L__BB72_5:                             // %%ifcont\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r31;\n"
        "	shr.u64 	%%cr_rd9, %%cr_rd40, 2;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd127, 0;\n"
        "	mov.b32 	%%cr_r146, 0f00000000;\n"
        "	mov.b32 	%%cr_r145, %%cr_r146;\n"
        "	mov.b32 	%%cr_r144, %%cr_r146;\n"
        "	mov.b32 	%%cr_r143, %%cr_r146;\n"
        "	@%%cr_p3 bra 	$L__BB72_8;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	shl.b64 	%%cr_rd54, %%cr_rd6, 15;\n"
        "	shl.b64 	%%cr_rd55, %%cr_rd7, 4;\n"
        "	or.b64 	%%cr_rd56, %%cr_rd54, %%cr_rd55;\n"
        "	add.s64 	%%cr_rd57, %%cr_rd56, %%cr_rd2;\n"
        "	add.s64 	%%cr_rd128, %%cr_rd57, 28672;\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd8, 15;\n"
        "	mov.b32 	%%cr_r143, 0f00000000;\n"
        "	mov.b64 	%%cr_rd129, 0;\n"
        "	mov.b32 	%%cr_r144, %%cr_r143;\n"
        "	mov.b32 	%%cr_r145, %%cr_r143;\n"
        "	mov.b32 	%%cr_r146, %%cr_r143;\n"
        "$L__BB72_7:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd58, %%cr_rd128, -28672;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r38, %%cr_r39, %%cr_r40, %%cr_r41}, [%%cr_rd58];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd59, %%cr_rd128, -24576;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r42, %%cr_r43, %%cr_r44, %%cr_r45}, [%%cr_rd59];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd60, %%cr_rd128, -20480;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r46, %%cr_r47, %%cr_r48, %%cr_r49}, [%%cr_rd60];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd61, %%cr_rd128, -16384;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r50, %%cr_r51, %%cr_r52, %%cr_r53}, [%%cr_rd61];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd62, %%cr_rd128, -12288;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r54, %%cr_r55, %%cr_r56, %%cr_r57}, [%%cr_rd62];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd63, %%cr_rd128, -8192;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r58, %%cr_r59, %%cr_r60, %%cr_r61}, [%%cr_rd63];\n"
        "	// end inline asm\n"
        "	add.s64 	%%cr_rd64, %%cr_rd128, -4096;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r62, %%cr_r63, %%cr_r64, %%cr_r65}, [%%cr_rd64];\n"
        "	// end inline asm\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r66, %%cr_r67, %%cr_r68, %%cr_r69}, [%%cr_rd128];\n"
        "	// end inline asm\n"
        "	add.rn.f32 	%%cr_r70, %%cr_r38, %%cr_r42;\n"
        "	add.rn.f32 	%%cr_r71, %%cr_r46, %%cr_r50;\n"
        "	add.rn.f32 	%%cr_r72, %%cr_r70, %%cr_r71;\n"
        "	add.rn.f32 	%%cr_r73, %%cr_r146, %%cr_r72;\n"
        "	add.rn.f32 	%%cr_r74, %%cr_r39, %%cr_r43;\n"
        "	add.rn.f32 	%%cr_r75, %%cr_r47, %%cr_r51;\n"
        "	add.rn.f32 	%%cr_r76, %%cr_r74, %%cr_r75;\n"
        "	add.rn.f32 	%%cr_r77, %%cr_r145, %%cr_r76;\n"
        "	add.rn.f32 	%%cr_r78, %%cr_r40, %%cr_r44;\n"
        "	add.rn.f32 	%%cr_r79, %%cr_r48, %%cr_r52;\n"
        "	add.rn.f32 	%%cr_r80, %%cr_r78, %%cr_r79;\n"
        "	add.rn.f32 	%%cr_r81, %%cr_r144, %%cr_r80;\n"
        "	add.rn.f32 	%%cr_r82, %%cr_r41, %%cr_r45;\n"
        "	add.rn.f32 	%%cr_r83, %%cr_r49, %%cr_r53;\n"
        "	add.rn.f32 	%%cr_r84, %%cr_r82, %%cr_r83;\n"
        "	add.rn.f32 	%%cr_r85, %%cr_r143, %%cr_r84;\n"
        "	add.rn.f32 	%%cr_r86, %%cr_r54, %%cr_r58;\n"
        "	add.rn.f32 	%%cr_r87, %%cr_r62, %%cr_r66;\n"
        "	add.rn.f32 	%%cr_r88, %%cr_r86, %%cr_r87;\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r73, %%cr_r88;\n"
        "	add.rn.f32 	%%cr_r89, %%cr_r55, %%cr_r59;\n"
        "	add.rn.f32 	%%cr_r90, %%cr_r63, %%cr_r67;\n"
        "	add.rn.f32 	%%cr_r91, %%cr_r89, %%cr_r90;\n"
        "	add.rn.f32 	%%cr_r145, %%cr_r77, %%cr_r91;\n"
        "	add.rn.f32 	%%cr_r92, %%cr_r56, %%cr_r60;\n"
        "	add.rn.f32 	%%cr_r93, %%cr_r64, %%cr_r68;\n"
        "	add.rn.f32 	%%cr_r94, %%cr_r92, %%cr_r93;\n"
        "	add.rn.f32 	%%cr_r144, %%cr_r81, %%cr_r94;\n"
        "	add.rn.f32 	%%cr_r95, %%cr_r57, %%cr_r61;\n"
        "	add.rn.f32 	%%cr_r96, %%cr_r65, %%cr_r69;\n"
        "	add.rn.f32 	%%cr_r97, %%cr_r95, %%cr_r96;\n"
        "	add.rn.f32 	%%cr_r143, %%cr_r85, %%cr_r97;\n"
        "	add.s64 	%%cr_rd129, %%cr_rd129, 1;\n"
        "	add.s64 	%%cr_rd128, %%cr_rd128, %%cr_rd18;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd129, %%cr_rd127;\n"
        "	@%%cr_p4 bra 	$L__BB72_7;\n"
        "$L__BB72_8:                             // %%dt_exit\n"
        "	shl.b64 	%%cr_rd66, %%cr_rd10, 11;\n"
        "	shl.b64 	%%cr_rd67, %%cr_rd6, 8;\n"
        "	add.s64 	%%cr_rd23, %%cr_rd67, %%cr_rd7;\n"
        "	add.s64 	%%cr_rd25, %%cr_rd66, %%cr_rd23;\n"
        "	setp.ge.u64 	%%cr_p5, %%cr_rd25, %%cr_rd9;\n"
        "	@%%cr_p5 bra 	$L__BB72_14;\n"
        "// %%bb.9:                               // %%then239\n"
        "	shl.b64 	%%cr_rd24, %%cr_rd8, 8;\n"
        "	not.b64 	%%cr_rd68, %%cr_rd25;\n"
        "	add.s64 	%%cr_rd26, %%cr_rd9, %%cr_rd68;\n"
        "	or.b64 	%%cr_rd69, %%cr_rd26, %%cr_rd24;\n"
        "	and.b64 	%%cr_rd70, %%cr_rd69, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p6, %%cr_rd70, 0;\n"
        "	@%%cr_p6 bra 	$L__BB72_11;\n"
        "	bra.uni 	$L__BB72_10;\n"
        "$L__BB72_11:\n"
        "	div.u64 	%%cr_rd130, %%cr_rd26, %%cr_rd24;\n"
        "	bra.uni 	$L__BB72_12;\n"
        "$L__BB72_10:\n"
        "	cvt.u32.u64 	%%cr_r98, %%cr_rd24;\n"
        "	cvt.u32.u64 	%%cr_r99, %%cr_rd26;\n"
        "	div.u32 	%%cr_r100, %%cr_r99, %%cr_r98;\n"
        "	cvt.u64.u32 	%%cr_rd130, %%cr_r100;\n"
        "$L__BB72_12:\n"
        "	shl.b64 	%%cr_rd72, %%cr_rd25, 4;\n"
        "	add.s64 	%%cr_rd131, %%cr_rd2, %%cr_rd72;\n"
        "	shl.b64 	%%cr_rd31, %%cr_rd8, 12;\n"
        "	mov.b64 	%%cr_rd132, -1;\n"
        "$L__BB72_13:                            // %%dt_body251\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.v4.f32 {%%cr_r101, %%cr_r102, %%cr_r103, %%cr_r104}, [%%cr_rd131];\n"
        "	// end inline asm\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r146, %%cr_r101;\n"
        "	add.rn.f32 	%%cr_r145, %%cr_r145, %%cr_r102;\n"
        "	add.rn.f32 	%%cr_r144, %%cr_r144, %%cr_r103;\n"
        "	add.rn.f32 	%%cr_r143, %%cr_r143, %%cr_r104;\n"
        "	add.s64 	%%cr_rd132, %%cr_rd132, 1;\n"
        "	add.s64 	%%cr_rd131, %%cr_rd131, %%cr_rd31;\n"
        "	setp.lt.u64 	%%cr_p7, %%cr_rd132, %%cr_rd130;\n"
        "	@%%cr_p7 bra 	$L__BB72_13;\n"
        "$L__BB72_14:                            // %%ifcont241\n"
        "	mov.b64 	%%cr_rd45, %0;\n"
        "	mov.b64 	%%cr_rd46, %9;\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	and.b64 	%%cr_rd74, %%cr_rd40, -4;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd74, %%cr_rd23;\n"
        "	setp.lt.u64 	%%cr_p8, %%cr_rd75, %%cr_rd40;\n"
        "	@%%cr_p8 bra 	$L__BB72_15;\n"
        "	bra.uni 	$L__BB72_16;\n"
        "$L__BB72_15:                            // %%then292\n"
        "	shl.b64 	%%cr_rd76, %%cr_rd75, 2;\n"
        "	add.s64 	%%cr_rd77, %%cr_rd2, %%cr_rd76;\n"
        "	// begin inline asm\n"
        "	ld.global.cs.nc.L2::256B.f32 %%cr_r105, [%%cr_rd77];\n"
        "	// end inline asm\n"
        "	add.rn.f32 	%%cr_r146, %%cr_r146, %%cr_r105;\n"
        "$L__BB72_16:                            // %%ifcont294\n"
        "	add.s64 	%%cr_rd1, %%cr_rd45, %%cr_rd46;\n"
        "	add.rn.f32 	%%cr_r106, %%cr_r145, %%cr_r146;\n"
        "	add.rn.f32 	%%cr_r107, %%cr_r144, %%cr_r143;\n"
        "	add.rn.f32 	%%cr_r108, %%cr_r107, %%cr_r106;\n"
        "	cvt.f64.f32 	%%cr_rd78, %%cr_r108;\n"
        "	cvt.u32.u64 	%%cr_r109, %%cr_rd78;\n"
        "	mov.b64 	{_, %%cr_r110}, %%cr_rd78;\n"
        "	shfl.sync.bfly.b32 	%%cr_r111, %%cr_r109, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r112, %%cr_r110, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd79, %%cr_r111;\n"
        "	cvt.u64.u32 	%%cr_rd80, %%cr_r112;\n"
        "	shl.b64 	%%cr_rd81, %%cr_rd80, 32;\n"
        "	or.b64 	%%cr_rd82, %%cr_rd81, %%cr_rd79;\n"
        "	add.rn.f64 	%%cr_rd83, %%cr_rd78, %%cr_rd82;\n"
        "	cvt.u32.u64 	%%cr_r113, %%cr_rd83;\n"
        "	mov.b64 	{_, %%cr_r114}, %%cr_rd83;\n"
        "	shfl.sync.bfly.b32 	%%cr_r115, %%cr_r113, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r116, %%cr_r114, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd84, %%cr_r115;\n"
        "	cvt.u64.u32 	%%cr_rd85, %%cr_r116;\n"
        "	shl.b64 	%%cr_rd86, %%cr_rd85, 32;\n"
        "	or.b64 	%%cr_rd87, %%cr_rd86, %%cr_rd84;\n"
        "	add.rn.f64 	%%cr_rd88, %%cr_rd83, %%cr_rd87;\n"
        "	cvt.u32.u64 	%%cr_r117, %%cr_rd88;\n"
        "	mov.b64 	{_, %%cr_r118}, %%cr_rd88;\n"
        "	shfl.sync.bfly.b32 	%%cr_r119, %%cr_r117, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r120, %%cr_r118, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd89, %%cr_r119;\n"
        "	cvt.u64.u32 	%%cr_rd90, %%cr_r120;\n"
        "	shl.b64 	%%cr_rd91, %%cr_rd90, 32;\n"
        "	or.b64 	%%cr_rd92, %%cr_rd91, %%cr_rd89;\n"
        "	add.rn.f64 	%%cr_rd93, %%cr_rd88, %%cr_rd92;\n"
        "	cvt.u32.u64 	%%cr_r121, %%cr_rd93;\n"
        "	mov.b64 	{_, %%cr_r122}, %%cr_rd93;\n"
        "	shfl.sync.bfly.b32 	%%cr_r123, %%cr_r121, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r124, %%cr_r122, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd94, %%cr_r123;\n"
        "	cvt.u64.u32 	%%cr_rd95, %%cr_r124;\n"
        "	shl.b64 	%%cr_rd96, %%cr_rd95, 32;\n"
        "	or.b64 	%%cr_rd97, %%cr_rd96, %%cr_rd94;\n"
        "	add.rn.f64 	%%cr_rd37, %%cr_rd93, %%cr_rd97;\n"
        "	cvt.u32.u64 	%%cr_r125, %%cr_rd37;\n"
        "	mov.b64 	{_, %%cr_r126}, %%cr_rd37;\n"
        "	shfl.sync.bfly.b32 	%%cr_r28, %%cr_r125, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r29, %%cr_r126, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p9, %%cr_r1, 0;\n"
        "	@%%cr_p9 bra 	$L__BB72_18;\n"
        "// %%bb.17:                              // %%then321\n"
        "	cvt.u64.u32 	%%cr_rd98, %%cr_r29;\n"
        "	shl.b64 	%%cr_rd99, %%cr_rd98, 32;\n"
        "	cvt.u64.u32 	%%cr_rd100, %%cr_r28;\n"
        "	or.b64 	%%cr_rd101, %%cr_rd99, %%cr_rd100;\n"
        "	add.rn.f64 	%%cr_rd102, %%cr_rd37, %%cr_rd101;\n"
        "	shr.u64 	%%cr_rd103, %%cr_rd7, 2;\n"
        "	and.b64 	%%cr_rd104, %%cr_rd103, 248;\n"
        "	add.s64 	%%cr_rd105, %%cr_rd1, %%cr_rd104;\n"
        "	st.shared.b64 	[%%cr_rd105], %%cr_rd102;\n"
        "$L__BB72_18:                            // %%ifcont323\n"
        "	cvt.u32.u64 	%%cr_r127, %%cr_rd7;\n"
        "	bar.sync 	0;\n"
        "	setp.ne.b32 	%%cr_p10, %%cr_r127, 0;\n"
        "	@%%cr_p10 bra 	$L__BB72_20;\n"
        "// %%bb.19:                              // %%then336\n"
        "	mov.b64 	%%cr_rd42, %6;\n"
        "	mov.b64 	%%cr_rd41, %4;\n"
        "	ld.shared.b64 	%%cr_rd106, [%%cr_rd1];\n"
        "	ld.shared.b64 	%%cr_rd107, [%%cr_rd1+8];\n"
        "	add.rn.f64 	%%cr_rd108, %%cr_rd106, %%cr_rd107;\n"
        "	ld.shared.b64 	%%cr_rd109, [%%cr_rd1+16];\n"
        "	ld.shared.b64 	%%cr_rd110, [%%cr_rd1+24];\n"
        "	add.rn.f64 	%%cr_rd111, %%cr_rd109, %%cr_rd110;\n"
        "	add.rn.f64 	%%cr_rd112, %%cr_rd108, %%cr_rd111;\n"
        "	ld.shared.b64 	%%cr_rd113, [%%cr_rd1+32];\n"
        "	ld.shared.b64 	%%cr_rd114, [%%cr_rd1+40];\n"
        "	add.rn.f64 	%%cr_rd115, %%cr_rd113, %%cr_rd114;\n"
        "	ld.shared.b64 	%%cr_rd116, [%%cr_rd1+48];\n"
        "	ld.shared.b64 	%%cr_rd117, [%%cr_rd1+56];\n"
        "	add.rn.f64 	%%cr_rd118, %%cr_rd116, %%cr_rd117;\n"
        "	add.rn.f64 	%%cr_rd119, %%cr_rd115, %%cr_rd118;\n"
        "	add.rn.f64 	%%cr_rd120, %%cr_rd112, %%cr_rd119;\n"
        "	add.s64 	%%cr_rd38, %%cr_rd3, %%cr_rd41;\n"
        "	atom.global.add.f64 	%%cr_rd121, [%%cr_rd38], %%cr_rd120;\n"
        "	membar.gl;\n"
        "	add.s64 	%%cr_rd39, %%cr_rd4, %%cr_rd42;\n"
        "	atom.global.add.u32 	%%cr_r128, [%%cr_rd39], 1;\n"
        "	cvt.u64.u32 	%%cr_rd122, %%cr_r128;\n"
        "	add.s64 	%%cr_rd123, %%cr_rd8, -1;\n"
        "	setp.eq.b64 	%%cr_p11, %%cr_rd123, %%cr_rd122;\n"
        "	@%%cr_p11 bra 	$L__BB72_21;\n"
        "	bra.uni 	$L__BB72_20;\n"
        "$L__BB72_21:                            // %%then409\n"
        "	mov.b64 	%%cr_rd43, %8;\n"
        "	membar.gl;\n"
        "	atom.global.exch.b64 	%%cr_rd124, [%%cr_rd38], 0;\n"
        "	cvt.rn.f32.f64 	%%cr_r129, %%cr_rd124;\n"
        "	add.s64 	%%cr_rd125, %%cr_rd5, %%cr_rd43;\n"
        "	st.global.b32 	[%%cr_rd125], %%cr_r129;\n"
        "	atom.global.exch.b32 	%%cr_r130, [%%cr_rd39], 0;\n"
        "$L__BB72_20:                            // %%ifcont338\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(0ULL), "l"(in_ptr), "l"(len), "l"(partial_ptr), "l"(0ULL), "l"(ticket_ptr), "l"(0ULL), "l"(out_ptr), "l"(0ULL), "l"(smem_ptr)
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
    int64_t needed_blocks = (N + (BLOCK_SIZE * 32) - 1) / (BLOCK_SIZE * 32);
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
