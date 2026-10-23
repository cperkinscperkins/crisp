# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_b200_2xfloat4.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge: vectorsum_v2 (B200 Tuned: 2x float4 with FP64 accumulation)
#   ;; Uses def-hardware-profile for B200, 2x float4 vector loads (32B/iteration)
#   ;; with 8 independent FP64 accumulators to saturate B200 memory bandwidth,
#   ;; followed by warp shuffle-xor reduction in double and atom.global.add.f64.
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
#   (def-type out-cell (cell double :address-space :global))
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
#           (a0     (to-double 0.0)) (a1 (to-double 0.0)) (a2 (to-double 0.0)) (a3 (to-double 0.0))
#           (b0     (to-double 0.0)) (b1 (to-double 0.0)) (b2 (to-double 0.0)) (b3 (to-double 0.0))
#           (stride (* 2ul gs)))
#       ;; Main 2x float4 loop (stride = 2 * gs)
#       (let ((iters (if (>= gid n4) 0ul (+ 1ul (/ (- (- n4 1ul) gid) stride))))
#             (idx gid))
#         (dotimes (k iters)
#           (let ((v0 (~ in4 idx)))
#             (set! a0 (+ a0 (to-double (x~ v0))))
#             (set! a1 (+ a1 (to-double (y~ v0))))
#             (set! a2 (+ a2 (to-double (z~ v0))))
#             (set! a3 (+ a3 (to-double (w~ v0)))))
#           (let ((idx1 (+ idx gs)))
#             (when (< idx1 n4)
#               (let ((v1 (~ in4 idx1)))
#                 (set! b0 (+ b0 (to-double (x~ v1))))
#                 (set! b1 (+ b1 (to-double (y~ v1))))
#                 (set! b2 (+ b2 (to-double (z~ v1))))
#                 (set! b3 (+ b3 (to-double (w~ v1)))))))
#           (set! idx (+ idx stride))))
#       ;; Tail for elements beyond n4 * 4
#       (let ((tail_start (* n4 4ul)))
#         (let ((t (+ tail_start gid)))
#           (when (< t n)
#             (set! a0 (+ a0 (to-double (~ input t)))))))
#       ;; Sum the 8 accumulators in double
#       (let ((acc (+ (+ (+ a0 a1) (+ a2 a3))
#                     (+ (+ b0 b1) (+ b2 b3)))))
#         ;; Intra-warp reduction with shuffle-xor in double
#         (dec-times-by-half+ (m (/ (to-ulong (warp-size)) 2ul))
#           (set! acc (+ acc (shuffle-xor acc m))))
#         ;; Warp leader issues atomic-add.f64 to global double result cell
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
    uint64_t bytes = len * 4ULL;
    uint64_t zero = 0ULL;
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<8>;\n"
        "	.reg .b32 	%%cr_r<38>;\n"
        "	.reg .b64 	%%cr_rd<146>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd59, %1;\n"
        "	mov.b64 	%%cr_rd62, %0;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd62;\n"
        "	mov.b64 	%%cr_rd63, %2;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd63;\n"
        "	mov.u32 	%%cr_r4, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r5, %%ntid.x;\n"
        "	mov.u32 	%%cr_r6, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r6;\n"
        "	mul.wide.u32 	%%cr_rd64, %%cr_r4, %%cr_r5;\n"
        "	add.s64 	%%cr_rd6, %%cr_rd64, %%cr_rd5;\n"
        "	mov.u32 	%%cr_r7, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd8, %%cr_r7, %%cr_r5;\n"
        "	shr.u64 	%%cr_rd9, %%cr_rd59, 2;\n"
        "	shl.b64 	%%cr_rd10, %%cr_rd8, 1;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd6, %%cr_rd9;\n"
        "	mov.b64 	%%cr_rd121, 0;\n"
        "	@%%cr_p1 bra 	$L__BB43_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd65, %%cr_rd6;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd9, %%cr_rd65;\n"
        "	or.b64 	%%cr_rd66, %%cr_rd11, %%cr_rd10;\n"
        "	and.b64 	%%cr_rd67, %%cr_rd66, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd67, 0;\n"
        "	@%%cr_p2 bra 	$L__BB43_3;\n"
        "	bra.uni 	$L__BB43_2;\n"
        "$L__BB43_3:\n"
        "	div.u64 	%%cr_rd120, %%cr_rd11, %%cr_rd10;\n"
        "	bra.uni 	$L__BB43_4;\n"
        "$L__BB43_2:\n"
        "	cvt.u32.u64 	%%cr_r8, %%cr_rd10;\n"
        "	cvt.u32.u64 	%%cr_r9, %%cr_rd11;\n"
        "	div.u32 	%%cr_r10, %%cr_r9, %%cr_r8;\n"
        "	cvt.u64.u32 	%%cr_rd120, %%cr_r10;\n"
        "$L__BB43_4:\n"
        "	add.s64 	%%cr_rd121, %%cr_rd120, 1;\n"
        "$L__BB43_5:                             // %%ifcont\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd121, 0;\n"
        "	mov.b64 	%%cr_rd132, 0d0000000000000000;\n"
        "	mov.b64 	%%cr_rd131, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd130, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd129, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd128, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd127, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd126, %%cr_rd132;\n"
        "	mov.b64 	%%cr_rd125, %%cr_rd132;\n"
        "	@%%cr_p3 bra 	$L__BB43_10;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	cvt.u64.u32 	%%cr_rd3, %%cr_r4;\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r7;\n"
        "	shl.b64 	%%cr_rd71, %%cr_rd6, 4;\n"
        "	or.b64 	%%cr_rd17, %%cr_rd71, 12;\n"
        "	shl.b64 	%%cr_rd18, %%cr_rd8, 5;\n"
        "	add.s64 	%%cr_rd72, %%cr_rd3, %%cr_rd7;\n"
        "	mad.lo.s64 	%%cr_rd122, %%cr_rd72, %%cr_rd4, %%cr_rd5;\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd122, 4;\n"
        "	mov.b64 	%%cr_rd125, 0d0000000000000000;\n"
        "	mov.b64 	%%cr_rd124, 0;\n"
        "	mov.b64 	%%cr_rd123, %%cr_rd1;\n"
        "	mov.b64 	%%cr_rd126, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd127, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd128, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd129, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd130, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd131, %%cr_rd125;\n"
        "	mov.b64 	%%cr_rd132, %%cr_rd125;\n"
        "	bra.uni 	$L__BB43_7;\n"
        "$L__BB43_9:                             // %%ifcont74\n"
        "                                        //   in Loop: Header=BB43_7 Depth=1\n"
        "	cvt.f64.f32 	%%cr_rd74, %%cr_r11;\n"
        "	add.rn.f64 	%%cr_rd132, %%cr_rd132, %%cr_rd74;\n"
        "	cvt.f64.f32 	%%cr_rd75, %%cr_r12;\n"
        "	add.rn.f64 	%%cr_rd131, %%cr_rd131, %%cr_rd75;\n"
        "	cvt.f64.f32 	%%cr_rd76, %%cr_r13;\n"
        "	add.rn.f64 	%%cr_rd130, %%cr_rd130, %%cr_rd76;\n"
        "	cvt.f64.f32 	%%cr_rd77, %%cr_r14;\n"
        "	add.rn.f64 	%%cr_rd129, %%cr_rd129, %%cr_rd77;\n"
        "	add.s64 	%%cr_rd124, %%cr_rd124, 1;\n"
        "	add.s64 	%%cr_rd123, %%cr_rd123, %%cr_rd18;\n"
        "	add.s64 	%%cr_rd122, %%cr_rd122, %%cr_rd10;\n"
        "	setp.lt.u64 	%%cr_p5, %%cr_rd124, %%cr_rd121;\n"
        "	@%%cr_p5 bra 	$L__BB43_7;\n"
        "	bra.uni 	$L__BB43_10;\n"
        "$L__BB43_7:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd73, %%cr_rd123, %%cr_rd17;\n"
        "	ld.global.v4.b32 	{%%cr_r11, %%cr_r12, %%cr_r13, %%cr_r14}, [%%cr_rd73+-12];\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd122, %%cr_rd9;\n"
        "	@%%cr_p4 bra 	$L__BB43_8;\n"
        "	bra.uni 	$L__BB43_9;\n"
        "$L__BB43_8:                             // %%then72\n"
        "                                        //   in Loop: Header=BB43_7 Depth=1\n"
        "	add.s64 	%%cr_rd78, %%cr_rd123, %%cr_rd20;\n"
        "	ld.global.v4.b32 	{%%cr_r15, %%cr_r16, %%cr_r17, %%cr_r18}, [%%cr_rd78];\n"
        "	cvt.f64.f32 	%%cr_rd79, %%cr_r15;\n"
        "	add.rn.f64 	%%cr_rd128, %%cr_rd128, %%cr_rd79;\n"
        "	cvt.f64.f32 	%%cr_rd80, %%cr_r16;\n"
        "	add.rn.f64 	%%cr_rd127, %%cr_rd127, %%cr_rd80;\n"
        "	cvt.f64.f32 	%%cr_rd81, %%cr_r17;\n"
        "	add.rn.f64 	%%cr_rd126, %%cr_rd126, %%cr_rd81;\n"
        "	cvt.f64.f32 	%%cr_rd82, %%cr_r18;\n"
        "	add.rn.f64 	%%cr_rd125, %%cr_rd125, %%cr_rd82;\n"
        "	bra.uni 	$L__BB43_9;\n"
        "$L__BB43_10:                            // %%dt_exit\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	and.b64 	%%cr_rd83, %%cr_rd59, -4;\n"
        "	add.s64 	%%cr_rd84, %%cr_rd83, %%cr_rd6;\n"
        "	setp.lt.u64 	%%cr_p6, %%cr_rd84, %%cr_rd59;\n"
        "	@%%cr_p6 bra 	$L__BB43_11;\n"
        "	bra.uni 	$L__BB43_12;\n"
        "$L__BB43_11:                            // %%then115\n"
        "	shl.b64 	%%cr_rd85, %%cr_rd84, 2;\n"
        "	add.s64 	%%cr_rd44, %%cr_rd1, %%cr_rd85;\n"
        "	ld.global.b32 	%%cr_r19, [%%cr_rd44];\n"
        "	cvt.f64.f32 	%%cr_rd86, %%cr_r19;\n"
        "	add.rn.f64 	%%cr_rd132, %%cr_rd132, %%cr_rd86;\n"
        "$L__BB43_12:                            // %%ifcont117\n"
        "	add.rn.f64 	%%cr_rd87, %%cr_rd131, %%cr_rd132;\n"
        "	add.rn.f64 	%%cr_rd88, %%cr_rd130, %%cr_rd129;\n"
        "	add.rn.f64 	%%cr_rd89, %%cr_rd88, %%cr_rd87;\n"
        "	add.rn.f64 	%%cr_rd90, %%cr_rd128, %%cr_rd127;\n"
        "	add.rn.f64 	%%cr_rd91, %%cr_rd126, %%cr_rd125;\n"
        "	add.rn.f64 	%%cr_rd92, %%cr_rd90, %%cr_rd91;\n"
        "	add.rn.f64 	%%cr_rd93, %%cr_rd92, %%cr_rd89;\n"
        "	cvt.u32.u64 	%%cr_r20, %%cr_rd93;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r21}, %%cr_rd93; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r22, %%cr_r20, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r23, %%cr_r21, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd94, %%cr_r22;\n"
        "	cvt.u64.u32 	%%cr_rd95, %%cr_r23;\n"
        "	shl.b64 	%%cr_rd96, %%cr_rd95, 32;\n"
        "	or.b64 	%%cr_rd97, %%cr_rd96, %%cr_rd94;\n"
        "	add.rn.f64 	%%cr_rd98, %%cr_rd93, %%cr_rd97;\n"
        "	cvt.u32.u64 	%%cr_r24, %%cr_rd98;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r25}, %%cr_rd98; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r26, %%cr_r24, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r27, %%cr_r25, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd99, %%cr_r26;\n"
        "	cvt.u64.u32 	%%cr_rd100, %%cr_r27;\n"
        "	shl.b64 	%%cr_rd101, %%cr_rd100, 32;\n"
        "	or.b64 	%%cr_rd102, %%cr_rd101, %%cr_rd99;\n"
        "	add.rn.f64 	%%cr_rd103, %%cr_rd98, %%cr_rd102;\n"
        "	cvt.u32.u64 	%%cr_r28, %%cr_rd103;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r29}, %%cr_rd103; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r30, %%cr_r28, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r31, %%cr_r29, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd104, %%cr_r30;\n"
        "	cvt.u64.u32 	%%cr_rd105, %%cr_r31;\n"
        "	shl.b64 	%%cr_rd106, %%cr_rd105, 32;\n"
        "	or.b64 	%%cr_rd107, %%cr_rd106, %%cr_rd104;\n"
        "	add.rn.f64 	%%cr_rd108, %%cr_rd103, %%cr_rd107;\n"
        "	cvt.u32.u64 	%%cr_r32, %%cr_rd108;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r33}, %%cr_rd108; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r34, %%cr_r32, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r35, %%cr_r33, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd109, %%cr_r34;\n"
        "	cvt.u64.u32 	%%cr_rd110, %%cr_r35;\n"
        "	shl.b64 	%%cr_rd111, %%cr_rd110, 32;\n"
        "	or.b64 	%%cr_rd112, %%cr_rd111, %%cr_rd109;\n"
        "	add.rn.f64 	%%cr_rd58, %%cr_rd108, %%cr_rd112;\n"
        "	cvt.u32.u64 	%%cr_r36, %%cr_rd58;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r37}, %%cr_rd58; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r2, %%cr_r36, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r3, %%cr_r37, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p7, %%cr_r1, 0;\n"
        "	@%%cr_p7 bra 	$L__BB43_14;\n"
        "// %%bb.13:                              // %%then153\n"
        "	mov.b64 	%%cr_rd60, %3;\n"
        "	cvt.u64.u32 	%%cr_rd113, %%cr_r3;\n"
        "	shl.b64 	%%cr_rd114, %%cr_rd113, 32;\n"
        "	cvt.u64.u32 	%%cr_rd115, %%cr_r2;\n"
        "	or.b64 	%%cr_rd116, %%cr_rd114, %%cr_rd115;\n"
        "	add.rn.f64 	%%cr_rd117, %%cr_rd58, %%cr_rd116;\n"
        "	add.s64 	%%cr_rd118, %%cr_rd2, %%cr_rd60;\n"
        "	atom.global.add.f64 	%%cr_rd119, [%%cr_rd118], %%cr_rd117;\n"
        "$L__BB43_14:                            // %%ifcont155\n"
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
    if (!input.is_contiguous()) {
        input = input.contiguous();
    }

    auto d_out = torch::zeros({1}, input.options().dtype(torch::kFloat64));

    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (num_sms > 0) ? (num_sms * 2) : 256;
    }

    int64_t needed_blocks = (N + (BLOCK_SIZE * 8) - 1) / (BLOCK_SIZE * 8);
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(d_out.data_ptr()),
        static_cast<uint64_t>(N)
    );
    output.copy_(d_out.to(torch::kFloat32));
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
