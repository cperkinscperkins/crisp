# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (prefixsum_pass1_tile8.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 05: prefixsum_v2 -- 8 Elements Per Thread (2048 elements/CTA)
#   ;; Pass 1: Local block-scan + write block totals
#   ;; Block size = 256 threads. Each thread loads and scans 8 elements (2048 elements per CTA).
#
#   (def-type in-vec  (vector float :address-space :global :align :compact))
#   (def-type out-vec (vector float :address-space :global :align :compact))
#   (def-type sum-vec (vector float :address-space :global :align :compact))
#   (def-type smem-vec (vector float :address-space :local :align :compact))
#
#   ;; Intra-warp inclusive scan using Kogge-Stone with shuffle-up
#   (def-function warp-scan (x lane)
#     (declare #'(float ulong => float))
#     (let ((s x))
#       (do-power-step+ (off 32ul)
#         (let ((t (shuffle-up s off)))
#           (set! s (+ s (if (>= lane off) t 0.0)))))
#       (return s)))
#
#   (def-kernel prefixsum_pass1_tile8 (input &out output block-sums)
#     (declare #'(in-vec &out out-vec sum-vec => nil)
#              (local-size :set-to 256))
#     (let ((tid   (to-ulong (get-local-id 0)))
#           (bid   (to-ulong (get-workgroup-id 0)))
#           (lane  (to-ulong (warp-lane)))
#           (wid   (/ tid 32ul))
#           (n     (length~ input))
#           (warp-totals (make-scratch-vector smem-vec 8))
#           (base-idx (+ (* bid 2048ul) (* tid 8ul))))
#       ;; 1. Load 8 elements per thread with bounds checks
#       (let ((x0 (if (< base-idx n) (~ input base-idx) 0.0))
#             (x1 (if (< (+ base-idx 1ul) n) (~ input (+ base-idx 1ul)) 0.0))
#             (x2 (if (< (+ base-idx 2ul) n) (~ input (+ base-idx 2ul)) 0.0))
#             (x3 (if (< (+ base-idx 3ul) n) (~ input (+ base-idx 3ul)) 0.0))
#             (x4 (if (< (+ base-idx 4ul) n) (~ input (+ base-idx 4ul)) 0.0))
#             (x5 (if (< (+ base-idx 5ul) n) (~ input (+ base-idx 5ul)) 0.0))
#             (x6 (if (< (+ base-idx 6ul) n) (~ input (+ base-idx 6ul)) 0.0))
#             (x7 (if (< (+ base-idx 7ul) n) (~ input (+ base-idx 7ul)) 0.0)))
#         ;; 2. Serial intra-thread inclusive scan
#         (let ((s0 x0)
#               (s1 (+ x0 x1))
#               (s2 (+ (+ x0 x1) x2))
#               (s3 (+ (+ (+ x0 x1) x2) x3))
#               (s4 (+ (+ (+ (+ x0 x1) x2) x3) x4))
#               (s5 (+ (+ (+ (+ (+ x0 x1) x2) x3) x4) x5))
#               (s6 (+ (+ (+ (+ (+ (+ x0 x1) x2) x3) x4) x5) x6))
#               (s7 (+ (+ (+ (+ (+ (+ (+ x0 x1) x2) x3) x4) x5) x6) x7)))
#           ;; 3. Warp scan on thread sums (s7)
#           (let ((ws (warp-scan s7 lane)))
#             ;; Exclusive warp prefix is (ws - s7)
#             (let ((w-excl (- ws s7)))
#               (when (= lane 31ul)
#                 (set! (~ warp-totals wid) ws))
#               (sync-workgroup)
#               ;; Warp 0 scans the 8 warp totals (all 32 lanes participate)
#               (when (= wid 0ul)
#                 (let ((wt (if (< lane 8ul) (~ warp-totals lane) 0.0)))
#                   (let ((scanned-wt (warp-scan wt lane)))
#                     (when (< lane 8ul)
#                       (set! (~ warp-totals lane) (- scanned-wt wt))))))
#               (sync-workgroup)
#               ;; Total CTA prefix for this thread = block-warp-exclusive + thread-warp-exclusive
#               (let ((cta-excl (+ (~ warp-totals wid) w-excl)))
#                 ;; 4. Write out scanned values to output
#                 (when (< base-idx n)
#                   (set! (~ output base-idx) (+ s0 cta-excl)))
#                 (when (< (+ base-idx 1ul) n)
#                   (set! (~ output (+ base-idx 1ul)) (+ s1 cta-excl)))
#                 (when (< (+ base-idx 2ul) n)
#                   (set! (~ output (+ base-idx 2ul)) (+ s2 cta-excl)))
#                 (when (< (+ base-idx 3ul) n)
#                   (set! (~ output (+ base-idx 3ul)) (+ s3 cta-excl)))
#                 (when (< (+ base-idx 4ul) n)
#                   (set! (~ output (+ base-idx 4ul)) (+ s4 cta-excl)))
#                 (when (< (+ base-idx 5ul) n)
#                   (set! (~ output (+ base-idx 5ul)) (+ s5 cta-excl)))
#                 (when (< (+ base-idx 6ul) n)
#                   (set! (~ output (+ base-idx 6ul)) (+ s6 cta-excl)))
#                 (when (< (+ base-idx 7ul) n)
#                   (set! (~ output (+ base-idx 7ul)) (+ s7 cta-excl)))
#                 ;; 5. Thread 255 writes block total sum
#                 (when (= tid 255ul)
#                   (set! (~ block-sums bid) (+ s7 cta-excl))))))))
#       (return)))
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
void crisp_prefixsum_pass1_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t block_sums_ptr,
    uint64_t in_len,
    uint64_t num_blocks,
    uint64_t in_bytes
) {
    extern __shared__ __align__(128) unsigned char crisp_smem[];
    uint64_t smem_ptr = static_cast<uint64_t>(__cvta_generic_to_shared(crisp_smem));
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<31>;\n"
        "	.reg .b32 	%%cr_r<91>;\n"
        "	.reg .b64 	%%cr_rd<55>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd43, %2;\n"
        "	mov.b64 	%%cr_rd46, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd46;\n"
        "	mov.b64 	%%cr_rd47, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd47;\n"
        "	mov.b64 	%%cr_rd48, %4;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd48;\n"
        "	mov.u32 	%%cr_r1, %%tid.x;\n"
        "	mov.u32 	%%cr_r40, %%ctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd50, %%cr_r40, 2048;\n"
        "	mul.wide.u32 	%%cr_rd51, %%cr_r1, 8;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd50, %%cr_rd51;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd8, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd9, %%cr_rd8, 2;\n"
        "	mov.b32 	%%cr_r83, 0f00000000;\n"
        "	mov.b32 	%%cr_r82, %%cr_r83;\n"
        "	@%%cr_p1 bra 	$L__BB44_2;\n"
        "// %%bb.1:                               // %%then\n"
        "	add.s64 	%%cr_rd10, %%cr_rd2, %%cr_rd9;\n"
        "	ld.global.nc.b32 	%%cr_r82, [%%cr_rd10];\n"
        "$L__BB44_2:                             // %%ifcont\n"
        "	or.b64 	%%cr_rd11, %%cr_rd8, 1;\n"
        "	setp.ge.u64 	%%cr_p2, %%cr_rd11, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd12, %%cr_rd11, 2;\n"
        "	@%%cr_p2 bra 	$L__BB44_4;\n"
        "// %%bb.3:                               // %%then66\n"
        "	add.s64 	%%cr_rd13, %%cr_rd2, %%cr_rd12;\n"
        "	ld.global.nc.b32 	%%cr_r83, [%%cr_rd13];\n"
        "$L__BB44_4:                             // %%ifcont68\n"
        "	or.b64 	%%cr_rd14, %%cr_rd8, 2;\n"
        "	setp.ge.u64 	%%cr_p3, %%cr_rd14, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd15, %%cr_rd14, 2;\n"
        "	mov.b32 	%%cr_r85, 0f00000000;\n"
        "	mov.b32 	%%cr_r84, %%cr_r85;\n"
        "	@%%cr_p3 bra 	$L__BB44_6;\n"
        "// %%bb.5:                               // %%then85\n"
        "	add.s64 	%%cr_rd16, %%cr_rd2, %%cr_rd15;\n"
        "	ld.global.nc.b32 	%%cr_r84, [%%cr_rd16];\n"
        "$L__BB44_6:                             // %%ifcont87\n"
        "	or.b64 	%%cr_rd17, %%cr_rd8, 3;\n"
        "	setp.ge.u64 	%%cr_p4, %%cr_rd17, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd17, 2;\n"
        "	@%%cr_p4 bra 	$L__BB44_8;\n"
        "// %%bb.7:                               // %%then104\n"
        "	add.s64 	%%cr_rd19, %%cr_rd2, %%cr_rd18;\n"
        "	ld.global.nc.b32 	%%cr_r85, [%%cr_rd19];\n"
        "$L__BB44_8:                             // %%ifcont106\n"
        "	or.b64 	%%cr_rd20, %%cr_rd8, 4;\n"
        "	setp.ge.u64 	%%cr_p5, %%cr_rd20, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd21, %%cr_rd20, 2;\n"
        "	mov.b32 	%%cr_r87, 0f00000000;\n"
        "	mov.b32 	%%cr_r86, %%cr_r87;\n"
        "	@%%cr_p5 bra 	$L__BB44_10;\n"
        "// %%bb.9:                               // %%then123\n"
        "	add.s64 	%%cr_rd22, %%cr_rd2, %%cr_rd21;\n"
        "	ld.global.nc.b32 	%%cr_r86, [%%cr_rd22];\n"
        "$L__BB44_10:                            // %%ifcont125\n"
        "	or.b64 	%%cr_rd23, %%cr_rd8, 5;\n"
        "	setp.ge.u64 	%%cr_p6, %%cr_rd23, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd24, %%cr_rd23, 2;\n"
        "	@%%cr_p6 bra 	$L__BB44_12;\n"
        "// %%bb.11:                              // %%then142\n"
        "	add.s64 	%%cr_rd25, %%cr_rd2, %%cr_rd24;\n"
        "	ld.global.nc.b32 	%%cr_r87, [%%cr_rd25];\n"
        "$L__BB44_12:                            // %%ifcont144\n"
        "	mov.b64 	%%cr_rd44, %0;\n"
        "	mov.b64 	%%cr_rd45, %5;\n"
        "	cvt.u64.u32 	%%cr_rd49, %%cr_r1;\n"
        "	mov.u32 	%%cr_r41, %%laneid;\n"
        "	or.b64 	%%cr_rd26, %%cr_rd8, 6;\n"
        "	setp.ge.u64 	%%cr_p7, %%cr_rd26, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd27, %%cr_rd26, 2;\n"
        "	mov.b32 	%%cr_r89, 0f00000000;\n"
        "	mov.b32 	%%cr_r88, %%cr_r89;\n"
        "	@%%cr_p7 bra 	$L__BB44_14;\n"
        "// %%bb.13:                              // %%then161\n"
        "	add.s64 	%%cr_rd28, %%cr_rd2, %%cr_rd27;\n"
        "	ld.global.nc.b32 	%%cr_r88, [%%cr_rd28];\n"
        "$L__BB44_14:                            // %%ifcont163\n"
        "	add.s64 	%%cr_rd1, %%cr_rd44, %%cr_rd45;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r41;\n"
        "	shr.u64 	%%cr_rd7, %%cr_rd49, 5;\n"
        "	or.b64 	%%cr_rd29, %%cr_rd8, 7;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd29, %%cr_rd43;\n"
        "	shl.b64 	%%cr_rd30, %%cr_rd29, 2;\n"
        "	@%%cr_p8 bra 	$L__BB44_16;\n"
        "// %%bb.15:                              // %%then180\n"
        "	add.s64 	%%cr_rd31, %%cr_rd2, %%cr_rd30;\n"
        "	ld.global.nc.b32 	%%cr_r89, [%%cr_rd31];\n"
        "$L__BB44_16:                            // %%ifcont182\n"
        "	cvt.u32.u64 	%%cr_r49, %%cr_rd6;\n"
        "	add.rn.f32 	%%cr_r18, %%cr_r82, %%cr_r83;\n"
        "	add.rn.f32 	%%cr_r19, %%cr_r18, %%cr_r84;\n"
        "	add.rn.f32 	%%cr_r20, %%cr_r19, %%cr_r85;\n"
        "	add.rn.f32 	%%cr_r21, %%cr_r20, %%cr_r86;\n"
        "	add.rn.f32 	%%cr_r22, %%cr_r21, %%cr_r87;\n"
        "	add.rn.f32 	%%cr_r23, %%cr_r22, %%cr_r88;\n"
        "	add.rn.f32 	%%cr_r24, %%cr_r23, %%cr_r89;\n"
        "	shfl.sync.up.b32 	%%cr_r50, %%cr_r24, 1, 0, -1;\n"
        "	setp.eq.b32 	%%cr_p9, %%cr_r49, 0;\n"
        "	selp.f32 	%%cr_r51, 0f00000000, %%cr_r50, %%cr_p9;\n"
        "	add.rn.f32 	%%cr_r52, %%cr_r24, %%cr_r51;\n"
        "	shfl.sync.up.b32 	%%cr_r53, %%cr_r52, 2, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p10, %%cr_r49, 2;\n"
        "	selp.f32 	%%cr_r54, 0f00000000, %%cr_r53, %%cr_p10;\n"
        "	add.rn.f32 	%%cr_r55, %%cr_r52, %%cr_r54;\n"
        "	shfl.sync.up.b32 	%%cr_r56, %%cr_r55, 4, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p11, %%cr_r49, 4;\n"
        "	selp.f32 	%%cr_r57, 0f00000000, %%cr_r56, %%cr_p11;\n"
        "	add.rn.f32 	%%cr_r58, %%cr_r55, %%cr_r57;\n"
        "	shfl.sync.up.b32 	%%cr_r59, %%cr_r58, 8, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p12, %%cr_r49, 8;\n"
        "	selp.f32 	%%cr_r60, 0f00000000, %%cr_r59, %%cr_p12;\n"
        "	add.rn.f32 	%%cr_r61, %%cr_r58, %%cr_r60;\n"
        "	shfl.sync.up.b32 	%%cr_r62, %%cr_r61, 16, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p13, %%cr_r49, 16;\n"
        "	selp.f32 	%%cr_r63, 0f00000000, %%cr_r62, %%cr_p13;\n"
        "	add.rn.f32 	%%cr_r25, %%cr_r61, %%cr_r63;\n"
        "	setp.ne.b32 	%%cr_p14, %%cr_r49, 31;\n"
        "	shl.b64 	%%cr_rd52, %%cr_rd7, 2;\n"
        "	add.s64 	%%cr_rd32, %%cr_rd1, %%cr_rd52;\n"
        "	@%%cr_p14 bra 	$L__BB44_18;\n"
        "// %%bb.17:                              // %%then266\n"
        "	st.shared.b32 	[%%cr_rd32], %%cr_r25;\n"
        "$L__BB44_18:                            // %%ifcont268\n"
        "	sub.rn.f32 	%%cr_r26, %%cr_r25, %%cr_r24;\n"
        "	bar.sync 	0;\n"
        "	setp.gt.u32 	%%cr_p15, %%cr_r1, 31;\n"
        "	@%%cr_p15 bra 	$L__BB44_23;\n"
        "// %%bb.19:                              // %%then281\n"
        "	shl.b64 	%%cr_rd53, %%cr_rd6, 2;\n"
        "	add.s64 	%%cr_rd33, %%cr_rd1, %%cr_rd53;\n"
        "	mov.b32 	%%cr_r90, 0f00000000;\n"
        "	@%%cr_p12 bra 	$L__BB44_20;\n"
        "	bra.uni 	$L__BB44_21;\n"
        "$L__BB44_20:                            // %%then288\n"
        "	ld.shared.b32 	%%cr_r90, [%%cr_rd33];\n"
        "$L__BB44_21:                            // %%ifcont290\n"
        "	setp.gt.u32 	%%cr_p17, %%cr_r49, 7;\n"
        "	shfl.sync.up.b32 	%%cr_r67, %%cr_r90, 1, 0, -1;\n"
        "	selp.f32 	%%cr_r68, 0f00000000, %%cr_r67, %%cr_p9;\n"
        "	add.rn.f32 	%%cr_r69, %%cr_r90, %%cr_r68;\n"
        "	shfl.sync.up.b32 	%%cr_r70, %%cr_r69, 2, 0, -1;\n"
        "	selp.f32 	%%cr_r71, 0f00000000, %%cr_r70, %%cr_p10;\n"
        "	add.rn.f32 	%%cr_r72, %%cr_r69, %%cr_r71;\n"
        "	shfl.sync.up.b32 	%%cr_r73, %%cr_r72, 4, 0, -1;\n"
        "	selp.f32 	%%cr_r74, 0f00000000, %%cr_r73, %%cr_p11;\n"
        "	add.rn.f32 	%%cr_r75, %%cr_r72, %%cr_r74;\n"
        "	shfl.sync.up.b32 	%%cr_r76, %%cr_r75, 8, 0, -1;\n"
        "	selp.f32 	%%cr_r77, 0f00000000, %%cr_r76, %%cr_p12;\n"
        "	add.rn.f32 	%%cr_r78, %%cr_r75, %%cr_r77;\n"
        "	shfl.sync.up.b32 	%%cr_r79, %%cr_r78, 16, 0, -1;\n"
        "	@%%cr_p17 bra 	$L__BB44_23;\n"
        "// %%bb.22:                              // %%then307\n"
        "	add.rn.f32 	%%cr_r80, %%cr_r78, 0f00000000;\n"
        "	sub.rn.f32 	%%cr_r31, %%cr_r80, %%cr_r90;\n"
        "	st.shared.b32 	[%%cr_rd33], %%cr_r31;\n"
        "$L__BB44_23:                            // %%ifcont283\n"
        "	setp.lt.u64 	%%cr_p22, %%cr_rd8, %%cr_rd43;\n"
        "	bar.sync 	0;\n"
        "	ld.shared.b32 	%%cr_r81, [%%cr_rd32];\n"
        "	add.rn.f32 	%%cr_r27, %%cr_r26, %%cr_r81;\n"
        "	@%%cr_p22 bra 	$L__BB44_24;\n"
        "	bra.uni 	$L__BB44_25;\n"
        "$L__BB44_24:                            // %%then334\n"
        "	add.s64 	%%cr_rd34, %%cr_rd3, %%cr_rd9;\n"
        "	add.rn.f32 	%%cr_r28, %%cr_r82, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd34], %%cr_r28;\n"
        "$L__BB44_25:                            // %%ifcont336\n"
        "	@%%cr_p2 bra 	$L__BB44_27;\n"
        "// %%bb.26:                              // %%then353\n"
        "	add.s64 	%%cr_rd35, %%cr_rd3, %%cr_rd12;\n"
        "	add.rn.f32 	%%cr_r32, %%cr_r18, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd35], %%cr_r32;\n"
        "$L__BB44_27:                            // %%ifcont355\n"
        "	@%%cr_p3 bra 	$L__BB44_29;\n"
        "// %%bb.28:                              // %%then373\n"
        "	add.s64 	%%cr_rd36, %%cr_rd3, %%cr_rd15;\n"
        "	add.rn.f32 	%%cr_r33, %%cr_r19, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd36], %%cr_r33;\n"
        "$L__BB44_29:                            // %%ifcont375\n"
        "	@%%cr_p4 bra 	$L__BB44_31;\n"
        "// %%bb.30:                              // %%then393\n"
        "	add.s64 	%%cr_rd37, %%cr_rd3, %%cr_rd18;\n"
        "	add.rn.f32 	%%cr_r34, %%cr_r20, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd37], %%cr_r34;\n"
        "$L__BB44_31:                            // %%ifcont395\n"
        "	@%%cr_p5 bra 	$L__BB44_33;\n"
        "// %%bb.32:                              // %%then413\n"
        "	add.s64 	%%cr_rd38, %%cr_rd3, %%cr_rd21;\n"
        "	add.rn.f32 	%%cr_r35, %%cr_r21, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd38], %%cr_r35;\n"
        "$L__BB44_33:                            // %%ifcont415\n"
        "	@%%cr_p6 bra 	$L__BB44_35;\n"
        "// %%bb.34:                              // %%then433\n"
        "	add.s64 	%%cr_rd39, %%cr_rd3, %%cr_rd24;\n"
        "	add.rn.f32 	%%cr_r36, %%cr_r22, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd39], %%cr_r36;\n"
        "$L__BB44_35:                            // %%ifcont435\n"
        "	@%%cr_p7 bra 	$L__BB44_37;\n"
        "// %%bb.36:                              // %%then453\n"
        "	add.s64 	%%cr_rd40, %%cr_rd3, %%cr_rd27;\n"
        "	add.rn.f32 	%%cr_r37, %%cr_r23, %%cr_r27;\n"
        "	st.global.b32 	[%%cr_rd40], %%cr_r37;\n"
        "$L__BB44_37:                            // %%ifcont455\n"
        "	add.rn.f32 	%%cr_r38, %%cr_r24, %%cr_r27;\n"
        "	@%%cr_p8 bra 	$L__BB44_39;\n"
        "// %%bb.38:                              // %%then473\n"
        "	add.s64 	%%cr_rd41, %%cr_rd3, %%cr_rd30;\n"
        "	st.global.b32 	[%%cr_rd41], %%cr_r38;\n"
        "$L__BB44_39:                            // %%ifcont475\n"
        "	setp.ne.b32 	%%cr_p30, %%cr_r1, 255;\n"
        "	@%%cr_p30 bra 	$L__BB44_41;\n"
        "// %%bb.40:                              // %%then491\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r40;\n"
        "	shl.b64 	%%cr_rd54, %%cr_rd5, 2;\n"
        "	add.s64 	%%cr_rd42, %%cr_rd4, %%cr_rd54;\n"
        "	st.global.b32 	[%%cr_rd42], %%cr_r38;\n"
        "$L__BB44_41:                            // %%ifcont493\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(0ULL), "l"(in_ptr), "l"(in_len), "l"(out_ptr), "l"(block_sums_ptr), "l"(smem_ptr)
        : "memory"
    );
}

__global__ __launch_bounds__(256)
void crisp_prefixsum_pass2_kernel(
    uint64_t out_ptr,
    uint64_t block_sums_ptr,
    uint64_t in_len,
    uint64_t num_blocks,
    uint64_t in_bytes
) {
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<10>;\n"
        "	.reg .b32 	%%cr_r<21>;\n"
        "	.reg .b64 	%%cr_rd<35>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd14, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd14;\n"
        "	mov.u32 	%%cr_r3, %%ctaid.x;\n"
        "	setp.eq.b32 	%%cr_p1, %%cr_r3, 0;\n"
        "	@%%cr_p1 bra 	$L__BB24_17;\n"
        "// %%bb.1:                               // %%then\n"
        "	mov.b64 	%%cr_rd13, %2;\n"
        "	mov.b64 	%%cr_rd12, %1;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd2, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd15, %%cr_r3, 2048;\n"
        "	shl.b32 	%%cr_r4, %%cr_r2, 3;\n"
        "	cvt.u64.u32 	%%cr_rd16, %%cr_r4;\n"
        "	add.s64 	%%cr_rd3, %%cr_rd15, %%cr_rd16;\n"
        "	cvta.to.global.u64 	%%cr_rd17, %%cr_rd13;\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd2, 2;\n"
        "	add.s64 	%%cr_rd19, %%cr_rd17, %%cr_rd18;\n"
        "	ld.global.b32 	%%cr_r1, [%%cr_rd19+-4];\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd3, %%cr_rd12;\n"
        "	@%%cr_p2 bra 	$L__BB24_2;\n"
        "	bra.uni 	$L__BB24_3;\n"
        "$L__BB24_2:                             // %%then43\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd3, 2;\n"
        "	add.s64 	%%cr_rd4, %%cr_rd1, %%cr_rd20;\n"
        "	ld.global.b32 	%%cr_r5, [%%cr_rd4];\n"
        "	add.rn.f32 	%%cr_r6, %%cr_r1, %%cr_r5;\n"
        "	st.global.b32 	[%%cr_rd4], %%cr_r6;\n"
        "$L__BB24_3:                             // %%ifcont45\n"
        "	or.b64 	%%cr_rd21, %%cr_rd3, 1;\n"
        "	setp.ge.u64 	%%cr_p3, %%cr_rd21, %%cr_rd12;\n"
        "	@%%cr_p3 bra 	$L__BB24_5;\n"
        "// %%bb.4:                               // %%then67\n"
        "	shl.b64 	%%cr_rd22, %%cr_rd21, 2;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd1, %%cr_rd22;\n"
        "	ld.global.b32 	%%cr_r7, [%%cr_rd5];\n"
        "	add.rn.f32 	%%cr_r8, %%cr_r1, %%cr_r7;\n"
        "	st.global.b32 	[%%cr_rd5], %%cr_r8;\n"
        "$L__BB24_5:                             // %%ifcont69\n"
        "	or.b64 	%%cr_rd23, %%cr_rd3, 2;\n"
        "	setp.ge.u64 	%%cr_p4, %%cr_rd23, %%cr_rd12;\n"
        "	@%%cr_p4 bra 	$L__BB24_7;\n"
        "// %%bb.6:                               // %%then94\n"
        "	shl.b64 	%%cr_rd24, %%cr_rd23, 2;\n"
        "	add.s64 	%%cr_rd6, %%cr_rd1, %%cr_rd24;\n"
        "	ld.global.b32 	%%cr_r9, [%%cr_rd6];\n"
        "	add.rn.f32 	%%cr_r10, %%cr_r1, %%cr_r9;\n"
        "	st.global.b32 	[%%cr_rd6], %%cr_r10;\n"
        "$L__BB24_7:                             // %%ifcont96\n"
        "	or.b64 	%%cr_rd25, %%cr_rd3, 3;\n"
        "	setp.ge.u64 	%%cr_p5, %%cr_rd25, %%cr_rd12;\n"
        "	@%%cr_p5 bra 	$L__BB24_9;\n"
        "// %%bb.8:                               // %%then121\n"
        "	shl.b64 	%%cr_rd26, %%cr_rd25, 2;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd1, %%cr_rd26;\n"
        "	ld.global.b32 	%%cr_r11, [%%cr_rd7];\n"
        "	add.rn.f32 	%%cr_r12, %%cr_r1, %%cr_r11;\n"
        "	st.global.b32 	[%%cr_rd7], %%cr_r12;\n"
        "$L__BB24_9:                             // %%ifcont123\n"
        "	or.b64 	%%cr_rd27, %%cr_rd3, 4;\n"
        "	setp.ge.u64 	%%cr_p6, %%cr_rd27, %%cr_rd12;\n"
        "	@%%cr_p6 bra 	$L__BB24_11;\n"
        "// %%bb.10:                              // %%then148\n"
        "	shl.b64 	%%cr_rd28, %%cr_rd27, 2;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd1, %%cr_rd28;\n"
        "	ld.global.b32 	%%cr_r13, [%%cr_rd8];\n"
        "	add.rn.f32 	%%cr_r14, %%cr_r1, %%cr_r13;\n"
        "	st.global.b32 	[%%cr_rd8], %%cr_r14;\n"
        "$L__BB24_11:                            // %%ifcont150\n"
        "	or.b64 	%%cr_rd29, %%cr_rd3, 5;\n"
        "	setp.ge.u64 	%%cr_p7, %%cr_rd29, %%cr_rd12;\n"
        "	@%%cr_p7 bra 	$L__BB24_13;\n"
        "// %%bb.12:                              // %%then175\n"
        "	shl.b64 	%%cr_rd30, %%cr_rd29, 2;\n"
        "	add.s64 	%%cr_rd9, %%cr_rd1, %%cr_rd30;\n"
        "	ld.global.b32 	%%cr_r15, [%%cr_rd9];\n"
        "	add.rn.f32 	%%cr_r16, %%cr_r1, %%cr_r15;\n"
        "	st.global.b32 	[%%cr_rd9], %%cr_r16;\n"
        "$L__BB24_13:                            // %%ifcont177\n"
        "	or.b64 	%%cr_rd31, %%cr_rd3, 6;\n"
        "	setp.ge.u64 	%%cr_p8, %%cr_rd31, %%cr_rd12;\n"
        "	@%%cr_p8 bra 	$L__BB24_15;\n"
        "// %%bb.14:                              // %%then202\n"
        "	shl.b64 	%%cr_rd32, %%cr_rd31, 2;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd1, %%cr_rd32;\n"
        "	ld.global.b32 	%%cr_r17, [%%cr_rd10];\n"
        "	add.rn.f32 	%%cr_r18, %%cr_r1, %%cr_r17;\n"
        "	st.global.b32 	[%%cr_rd10], %%cr_r18;\n"
        "$L__BB24_15:                            // %%ifcont204\n"
        "	or.b64 	%%cr_rd33, %%cr_rd3, 7;\n"
        "	setp.ge.u64 	%%cr_p9, %%cr_rd33, %%cr_rd12;\n"
        "	@%%cr_p9 bra 	$L__BB24_17;\n"
        "// %%bb.16:                              // %%then229\n"
        "	shl.b64 	%%cr_rd34, %%cr_rd33, 2;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd1, %%cr_rd34;\n"
        "	ld.global.b32 	%%cr_r19, [%%cr_rd11];\n"
        "	add.rn.f32 	%%cr_r20, %%cr_r1, %%cr_r19;\n"
        "	st.global.b32 	[%%cr_rd11], %%cr_r20;\n"
        "$L__BB24_17:                            // %%ifcont\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(out_ptr), "l"(in_len), "l"(block_sums_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_prefixsum(torch::Tensor input, torch::Tensor output) {
    int64_t N = input.numel();
    if (N <= 0) return output;

    constexpr int BLOCK_THREADS = 256;
    constexpr int ELEMENTS_PER_BLOCK = 2048;
    int64_t num_blocks = (N + ELEMENTS_PER_BLOCK - 1) / ELEMENTS_PER_BLOCK;

    static torch::Tensor block_sums_buffer;
    if (!block_sums_buffer.defined() || block_sums_buffer.numel() < num_blocks) {
        block_sums_buffer = torch::empty({num_blocks}, input.options().dtype(torch::kFloat32));
    }

    uint64_t in_ptr = reinterpret_cast<uint64_t>(input.data_ptr());
    uint64_t out_ptr = reinterpret_cast<uint64_t>(output.data_ptr());
    uint64_t bs_ptr = reinterpret_cast<uint64_t>(block_sums_buffer.data_ptr());
    uint64_t in_bytes = static_cast<uint64_t>(N * sizeof(float));

    // Pass 1: Local block scan and compute block sums
    crisp_prefixsum_pass1_kernel<<<num_blocks, BLOCK_THREADS, 32>>>(
        in_ptr, out_ptr, bs_ptr, static_cast<uint64_t>(N), static_cast<uint64_t>(num_blocks), in_bytes
    );

    // Scan block sums using PyTorch cumsum
    torch::Tensor valid_bs = block_sums_buffer.slice(0, 0, num_blocks);
    valid_bs.copy_(torch::cumsum(valid_bs, 0));

    // Pass 2: Add scanned block prefix to elements
    if (num_blocks > 1) {
        crisp_prefixsum_pass2_kernel<<<num_blocks, BLOCK_THREADS, 0>>>(
            out_ptr, bs_ptr, static_cast<uint64_t>(N), static_cast<uint64_t>(num_blocks), in_bytes
        );
    }

    return output;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_prefixsum(torch::Tensor input, torch::Tensor output);"""

_crisp_mod = load_inline(
    name="crisp_crisp_prefixsum_tile8_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_prefixsum"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_prefixsum(inp, out)
