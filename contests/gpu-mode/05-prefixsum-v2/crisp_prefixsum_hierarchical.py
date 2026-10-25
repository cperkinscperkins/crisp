# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (prefixsum_pass1.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 05: prefixsum_v2
#   ;; Hierarchical Prefix Sum (Float32 in, Float32 out)
#   ;;
#   ;; Pass 1: Local block-scan + write block totals
#   ;; Block size = 256 threads. Each thread loads and scans 4 elements (1 float4 = 1024 elements per CTA).
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
#   (def-kernel prefixsum_pass1 (input &out output block-sums)
#     (declare #'(in-vec &out out-vec sum-vec => nil)
#              (local-size :set-to 256))
#     (let ((tid   (to-ulong (get-local-id 0)))
#           (bid   (to-ulong (get-workgroup-id 0)))
#           (lane  (to-ulong (warp-lane)))
#           (wid   (/ tid 32ul))
#           (n     (length~ input))
#           (warp-totals (make-scratch-vector smem-vec 8))
#           (base-idx (+ (* bid 1024ul) (* tid 4ul))))
#       ;; 1. Load 4 elements per thread
#       (let ((x0 (if (< base-idx n) (~ input base-idx) 0.0))
#             (x1 (if (< (+ base-idx 1ul) n) (~ input (+ base-idx 1ul)) 0.0))
#             (x2 (if (< (+ base-idx 2ul) n) (~ input (+ base-idx 2ul)) 0.0))
#             (x3 (if (< (+ base-idx 3ul) n) (~ input (+ base-idx 3ul)) 0.0)))
#         ;; Serial intra-thread inclusive scan
#         (let ((s0 x0)
#               (s1 (+ x0 x1))
#               (s2 (+ (+ x0 x1) x2))
#               (s3 (+ (+ (+ x0 x1) x2) x3)))
#           ;; Warp scan on thread sums (s3)
#           (let ((ws (warp-scan s3 lane)))
#             ;; Exclusive warp prefix is (ws - s3)
#             (let ((w-excl (- ws s3)))
#               (when (= lane 31ul)
#                 (set! (~ warp-totals wid) ws))
#               (sync-workgroup)
#               ;; Warp 0 scans the 8 warp totals (all 32 lanes participate to satisfy warp-uniform shfl mask)
#               (when (= wid 0ul)
#                 (let ((wt (if (< lane 8ul) (~ warp-totals lane) 0.0)))
#                   (let ((scanned-wt (warp-scan wt lane)))
#                     (when (< lane 8ul)
#                       (set! (~ warp-totals lane) (- scanned-wt wt))))))
#               (sync-workgroup)
#               ;; Total CTA prefix for this thread = block-warp-exclusive + thread-warp-exclusive
#               (let ((cta-excl (+ (~ warp-totals wid) w-excl)))
#                 ;; Write out scanned values to output
#                 (when (< base-idx n)
#                   (set! (~ output base-idx) (+ s0 cta-excl)))
#                 (when (< (+ base-idx 1ul) n)
#                   (set! (~ output (+ base-idx 1ul)) (+ s1 cta-excl)))
#                 (when (< (+ base-idx 2ul) n)
#                   (set! (~ output (+ base-idx 2ul)) (+ s2 cta-excl)))
#                 (when (< (+ base-idx 3ul) n)
#                   (set! (~ output (+ base-idx 3ul)) (+ s3 cta-excl)))
#                 ;; Thread 255 writes the total block sum
#                 (when (= tid 255ul)
#                   (set! (~ block-sums bid) (+ s3 cta-excl))))))))
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
        "	.reg .pred 	%%cr_p<23>;\n"
        "	.reg .b32 	%%cr_r<67>;\n"
        "	.reg .b64 	%%cr_rd<39>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd27, %2;\n"
        "	mov.b64 	%%cr_rd30, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd30;\n"
        "	mov.b64 	%%cr_rd31, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd31;\n"
        "	mov.b64 	%%cr_rd32, %4;\n"
        "	cvta.to.global.u64 	%%cr_rd4, %%cr_rd32;\n"
        "	mov.u32 	%%cr_r1, %%tid.x;\n"
        "	mov.u32 	%%cr_r24, %%ctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd34, %%cr_r24, 1024;\n"
        "	mul.wide.u32 	%%cr_rd35, %%cr_r1, 4;\n"
        "	add.s64 	%%cr_rd8, %%cr_rd34, %%cr_rd35;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd8, %%cr_rd27;\n"
        "	shl.b64 	%%cr_rd9, %%cr_rd8, 2;\n"
        "	mov.b32 	%%cr_r63, 0f00000000;\n"
        "	mov.b32 	%%cr_r62, %%cr_r63;\n"
        "	@%%cr_p1 bra 	$L__BB44_2;\n"
        "// %%bb.1:                               // %%then\n"
        "	add.s64 	%%cr_rd10, %%cr_rd2, %%cr_rd9;\n"
        "	ld.global.nc.b32 	%%cr_r62, [%%cr_rd10];\n"
        "$L__BB44_2:                             // %%ifcont\n"
        "	or.b64 	%%cr_rd11, %%cr_rd8, 1;\n"
        "	setp.ge.u64 	%%cr_p2, %%cr_rd11, %%cr_rd27;\n"
        "	shl.b64 	%%cr_rd12, %%cr_rd11, 2;\n"
        "	@%%cr_p2 bra 	$L__BB44_4;\n"
        "// %%bb.3:                               // %%then66\n"
        "	add.s64 	%%cr_rd13, %%cr_rd2, %%cr_rd12;\n"
        "	ld.global.nc.b32 	%%cr_r63, [%%cr_rd13];\n"
        "$L__BB44_4:                             // %%ifcont68\n"
        "	mov.b64 	%%cr_rd28, %0;\n"
        "	mov.b64 	%%cr_rd29, %5;\n"
        "	cvt.u64.u32 	%%cr_rd33, %%cr_r1;\n"
        "	mov.u32 	%%cr_r25, %%laneid;\n"
        "	or.b64 	%%cr_rd14, %%cr_rd8, 2;\n"
        "	setp.ge.u64 	%%cr_p3, %%cr_rd14, %%cr_rd27;\n"
        "	shl.b64 	%%cr_rd15, %%cr_rd14, 2;\n"
        "	mov.b32 	%%cr_r65, 0f00000000;\n"
        "	mov.b32 	%%cr_r64, %%cr_r65;\n"
        "	@%%cr_p3 bra 	$L__BB44_6;\n"
        "// %%bb.5:                               // %%then85\n"
        "	add.s64 	%%cr_rd16, %%cr_rd2, %%cr_rd15;\n"
        "	ld.global.nc.b32 	%%cr_r64, [%%cr_rd16];\n"
        "$L__BB44_6:                             // %%ifcont87\n"
        "	add.s64 	%%cr_rd1, %%cr_rd28, %%cr_rd29;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r25;\n"
        "	shr.u64 	%%cr_rd7, %%cr_rd33, 5;\n"
        "	or.b64 	%%cr_rd17, %%cr_rd8, 3;\n"
        "	setp.ge.u64 	%%cr_p4, %%cr_rd17, %%cr_rd27;\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd17, 2;\n"
        "	@%%cr_p4 bra 	$L__BB44_8;\n"
        "// %%bb.7:                               // %%then104\n"
        "	add.s64 	%%cr_rd19, %%cr_rd2, %%cr_rd18;\n"
        "	ld.global.nc.b32 	%%cr_r65, [%%cr_rd19];\n"
        "$L__BB44_8:                             // %%ifcont106\n"
        "	cvt.u32.u64 	%%cr_r29, %%cr_rd6;\n"
        "	add.rn.f32 	%%cr_r10, %%cr_r62, %%cr_r63;\n"
        "	add.rn.f32 	%%cr_r11, %%cr_r10, %%cr_r64;\n"
        "	add.rn.f32 	%%cr_r12, %%cr_r11, %%cr_r65;\n"
        "	shfl.sync.up.b32 	%%cr_r30, %%cr_r12, 1, 0, -1;\n"
        "	setp.eq.b32 	%%cr_p5, %%cr_r29, 0;\n"
        "	selp.f32 	%%cr_r31, 0f00000000, %%cr_r30, %%cr_p5;\n"
        "	add.rn.f32 	%%cr_r32, %%cr_r12, %%cr_r31;\n"
        "	shfl.sync.up.b32 	%%cr_r33, %%cr_r32, 2, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p6, %%cr_r29, 2;\n"
        "	selp.f32 	%%cr_r34, 0f00000000, %%cr_r33, %%cr_p6;\n"
        "	add.rn.f32 	%%cr_r35, %%cr_r32, %%cr_r34;\n"
        "	shfl.sync.up.b32 	%%cr_r36, %%cr_r35, 4, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p7, %%cr_r29, 4;\n"
        "	selp.f32 	%%cr_r37, 0f00000000, %%cr_r36, %%cr_p7;\n"
        "	add.rn.f32 	%%cr_r38, %%cr_r35, %%cr_r37;\n"
        "	shfl.sync.up.b32 	%%cr_r39, %%cr_r38, 8, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p8, %%cr_r29, 8;\n"
        "	selp.f32 	%%cr_r40, 0f00000000, %%cr_r39, %%cr_p8;\n"
        "	add.rn.f32 	%%cr_r41, %%cr_r38, %%cr_r40;\n"
        "	shfl.sync.up.b32 	%%cr_r42, %%cr_r41, 16, 0, -1;\n"
        "	setp.lt.u32 	%%cr_p9, %%cr_r29, 16;\n"
        "	selp.f32 	%%cr_r43, 0f00000000, %%cr_r42, %%cr_p9;\n"
        "	add.rn.f32 	%%cr_r13, %%cr_r41, %%cr_r43;\n"
        "	setp.ne.b32 	%%cr_p10, %%cr_r29, 31;\n"
        "	shl.b64 	%%cr_rd36, %%cr_rd7, 2;\n"
        "	add.s64 	%%cr_rd20, %%cr_rd1, %%cr_rd36;\n"
        "	@%%cr_p10 bra 	$L__BB44_10;\n"
        "// %%bb.9:                               // %%then142\n"
        "	st.shared.b32 	[%%cr_rd20], %%cr_r13;\n"
        "$L__BB44_10:                            // %%ifcont144\n"
        "	sub.rn.f32 	%%cr_r14, %%cr_r13, %%cr_r12;\n"
        "	bar.sync 	0;\n"
        "	setp.gt.u32 	%%cr_p11, %%cr_r1, 31;\n"
        "	@%%cr_p11 bra 	$L__BB44_15;\n"
        "// %%bb.11:                              // %%then157\n"
        "	shl.b64 	%%cr_rd37, %%cr_rd6, 2;\n"
        "	add.s64 	%%cr_rd21, %%cr_rd1, %%cr_rd37;\n"
        "	mov.b32 	%%cr_r66, 0f00000000;\n"
        "	@%%cr_p8 bra 	$L__BB44_12;\n"
        "	bra.uni 	$L__BB44_13;\n"
        "$L__BB44_12:                            // %%then164\n"
        "	ld.shared.b32 	%%cr_r66, [%%cr_rd21];\n"
        "$L__BB44_13:                            // %%ifcont166\n"
        "	setp.gt.u32 	%%cr_p13, %%cr_r29, 7;\n"
        "	shfl.sync.up.b32 	%%cr_r47, %%cr_r66, 1, 0, -1;\n"
        "	selp.f32 	%%cr_r48, 0f00000000, %%cr_r47, %%cr_p5;\n"
        "	add.rn.f32 	%%cr_r49, %%cr_r66, %%cr_r48;\n"
        "	shfl.sync.up.b32 	%%cr_r50, %%cr_r49, 2, 0, -1;\n"
        "	selp.f32 	%%cr_r51, 0f00000000, %%cr_r50, %%cr_p6;\n"
        "	add.rn.f32 	%%cr_r52, %%cr_r49, %%cr_r51;\n"
        "	shfl.sync.up.b32 	%%cr_r53, %%cr_r52, 4, 0, -1;\n"
        "	selp.f32 	%%cr_r54, 0f00000000, %%cr_r53, %%cr_p7;\n"
        "	add.rn.f32 	%%cr_r55, %%cr_r52, %%cr_r54;\n"
        "	shfl.sync.up.b32 	%%cr_r56, %%cr_r55, 8, 0, -1;\n"
        "	selp.f32 	%%cr_r57, 0f00000000, %%cr_r56, %%cr_p8;\n"
        "	add.rn.f32 	%%cr_r58, %%cr_r55, %%cr_r57;\n"
        "	shfl.sync.up.b32 	%%cr_r59, %%cr_r58, 16, 0, -1;\n"
        "	@%%cr_p13 bra 	$L__BB44_15;\n"
        "// %%bb.14:                              // %%then183\n"
        "	add.rn.f32 	%%cr_r60, %%cr_r58, 0f00000000;\n"
        "	sub.rn.f32 	%%cr_r19, %%cr_r60, %%cr_r66;\n"
        "	st.shared.b32 	[%%cr_rd21], %%cr_r19;\n"
        "$L__BB44_15:                            // %%ifcont159\n"
        "	setp.lt.u64 	%%cr_p18, %%cr_rd8, %%cr_rd27;\n"
        "	bar.sync 	0;\n"
        "	ld.shared.b32 	%%cr_r61, [%%cr_rd20];\n"
        "	add.rn.f32 	%%cr_r15, %%cr_r14, %%cr_r61;\n"
        "	@%%cr_p18 bra 	$L__BB44_16;\n"
        "	bra.uni 	$L__BB44_17;\n"
        "$L__BB44_16:                            // %%then210\n"
        "	add.s64 	%%cr_rd22, %%cr_rd3, %%cr_rd9;\n"
        "	add.rn.f32 	%%cr_r16, %%cr_r62, %%cr_r15;\n"
        "	st.global.b32 	[%%cr_rd22], %%cr_r16;\n"
        "$L__BB44_17:                            // %%ifcont212\n"
        "	@%%cr_p2 bra 	$L__BB44_19;\n"
        "// %%bb.18:                              // %%then229\n"
        "	add.s64 	%%cr_rd23, %%cr_rd3, %%cr_rd12;\n"
        "	add.rn.f32 	%%cr_r20, %%cr_r10, %%cr_r15;\n"
        "	st.global.b32 	[%%cr_rd23], %%cr_r20;\n"
        "$L__BB44_19:                            // %%ifcont231\n"
        "	@%%cr_p3 bra 	$L__BB44_21;\n"
        "// %%bb.20:                              // %%then249\n"
        "	add.s64 	%%cr_rd24, %%cr_rd3, %%cr_rd15;\n"
        "	add.rn.f32 	%%cr_r21, %%cr_r11, %%cr_r15;\n"
        "	st.global.b32 	[%%cr_rd24], %%cr_r21;\n"
        "$L__BB44_21:                            // %%ifcont251\n"
        "	add.rn.f32 	%%cr_r22, %%cr_r12, %%cr_r15;\n"
        "	@%%cr_p4 bra 	$L__BB44_23;\n"
        "// %%bb.22:                              // %%then269\n"
        "	add.s64 	%%cr_rd25, %%cr_rd3, %%cr_rd18;\n"
        "	st.global.b32 	[%%cr_rd25], %%cr_r22;\n"
        "$L__BB44_23:                            // %%ifcont271\n"
        "	setp.ne.b32 	%%cr_p22, %%cr_r1, 255;\n"
        "	@%%cr_p22 bra 	$L__BB44_25;\n"
        "// %%bb.24:                              // %%then287\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r24;\n"
        "	shl.b64 	%%cr_rd38, %%cr_rd5, 2;\n"
        "	add.s64 	%%cr_rd26, %%cr_rd4, %%cr_rd38;\n"
        "	st.global.b32 	[%%cr_rd26], %%cr_r22;\n"
        "$L__BB44_25:                            // %%ifcont289\n"
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
        "	.reg .pred 	%%cr_p<6>;\n"
        "	.reg .b32 	%%cr_r<13>;\n"
        "	.reg .b64 	%%cr_rd<23>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd10, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd10;\n"
        "	mov.u32 	%%cr_r3, %%ctaid.x;\n"
        "	setp.eq.b32 	%%cr_p1, %%cr_r3, 0;\n"
        "	@%%cr_p1 bra 	$L__BB24_9;\n"
        "// %%bb.1:                               // %%then\n"
        "	mov.b64 	%%cr_rd9, %2;\n"
        "	mov.b64 	%%cr_rd8, %1;\n"
        "	mov.u32 	%%cr_r2, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd2, %%cr_r3;\n"
        "	mul.wide.u32 	%%cr_rd11, %%cr_r3, 1024;\n"
        "	shl.b32 	%%cr_r4, %%cr_r2, 2;\n"
        "	cvt.u64.u32 	%%cr_rd12, %%cr_r4;\n"
        "	add.s64 	%%cr_rd3, %%cr_rd11, %%cr_rd12;\n"
        "	cvta.to.global.u64 	%%cr_rd13, %%cr_rd9;\n"
        "	shl.b64 	%%cr_rd14, %%cr_rd2, 2;\n"
        "	add.s64 	%%cr_rd15, %%cr_rd13, %%cr_rd14;\n"
        "	ld.global.b32 	%%cr_r1, [%%cr_rd15+-4];\n"
        "	setp.lt.u64 	%%cr_p2, %%cr_rd3, %%cr_rd8;\n"
        "	@%%cr_p2 bra 	$L__BB24_2;\n"
        "	bra.uni 	$L__BB24_3;\n"
        "$L__BB24_2:                             // %%then43\n"
        "	shl.b64 	%%cr_rd16, %%cr_rd3, 2;\n"
        "	add.s64 	%%cr_rd4, %%cr_rd1, %%cr_rd16;\n"
        "	ld.global.b32 	%%cr_r5, [%%cr_rd4];\n"
        "	add.rn.f32 	%%cr_r6, %%cr_r1, %%cr_r5;\n"
        "	st.global.b32 	[%%cr_rd4], %%cr_r6;\n"
        "$L__BB24_3:                             // %%ifcont45\n"
        "	or.b64 	%%cr_rd17, %%cr_rd3, 1;\n"
        "	setp.ge.u64 	%%cr_p3, %%cr_rd17, %%cr_rd8;\n"
        "	@%%cr_p3 bra 	$L__BB24_5;\n"
        "// %%bb.4:                               // %%then67\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd17, 2;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd1, %%cr_rd18;\n"
        "	ld.global.b32 	%%cr_r7, [%%cr_rd5];\n"
        "	add.rn.f32 	%%cr_r8, %%cr_r1, %%cr_r7;\n"
        "	st.global.b32 	[%%cr_rd5], %%cr_r8;\n"
        "$L__BB24_5:                             // %%ifcont69\n"
        "	or.b64 	%%cr_rd19, %%cr_rd3, 2;\n"
        "	setp.ge.u64 	%%cr_p4, %%cr_rd19, %%cr_rd8;\n"
        "	@%%cr_p4 bra 	$L__BB24_7;\n"
        "// %%bb.6:                               // %%then94\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd19, 2;\n"
        "	add.s64 	%%cr_rd6, %%cr_rd1, %%cr_rd20;\n"
        "	ld.global.b32 	%%cr_r9, [%%cr_rd6];\n"
        "	add.rn.f32 	%%cr_r10, %%cr_r1, %%cr_r9;\n"
        "	st.global.b32 	[%%cr_rd6], %%cr_r10;\n"
        "$L__BB24_7:                             // %%ifcont96\n"
        "	or.b64 	%%cr_rd21, %%cr_rd3, 3;\n"
        "	setp.ge.u64 	%%cr_p5, %%cr_rd21, %%cr_rd8;\n"
        "	@%%cr_p5 bra 	$L__BB24_9;\n"
        "// %%bb.8:                               // %%then121\n"
        "	shl.b64 	%%cr_rd22, %%cr_rd21, 2;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd1, %%cr_rd22;\n"
        "	ld.global.b32 	%%cr_r11, [%%cr_rd7];\n"
        "	add.rn.f32 	%%cr_r12, %%cr_r1, %%cr_r11;\n"
        "	st.global.b32 	[%%cr_rd7], %%cr_r12;\n"
        "$L__BB24_9:                             // %%ifcont\n"
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
    constexpr int ELEMENTS_PER_BLOCK = 1024;
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
    name="crisp_crisp_prefixsum_hierarchical_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_prefixsum"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_prefixsum(inp, out)
