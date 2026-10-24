# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (vectorsum_beauty.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 02: vectorsum_v2 (Beauty Contestant)
#   ;; Idiomatic Crisp: Vectorized float4 loop-vector-stride + reduce-warp + atomic-add!
#   (def-type in-vec   (vector float :address-space :global :align :compact))
#   (def-type out-cell (cell double :address-space :global))
#
#   (def-kernel vectorsum_kernel (input result)
#     (declare #'(in-vec out-cell => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((lane (to-ulong (warp-lane)))
#           (acc  (to-double 0.0))
#           (n    (length~ input))
#           (n4   (/ n 4ul))
#           (in4  (make-vector input float4 :length n4)))
#       ;; 128-bit vectorized grid-stride loop
#       (loop-vector-stride in4 (i)
#         (let ((v (~ in4 i)))
#           (set! acc (+ acc (+ (to-double (x~ v)) (to-double (y~ v)))))
#           (set! acc (+ acc (+ (to-double (z~ v)) (to-double (w~ v)))))))
#       ;; Tail for non-multiples of 4
#       (let ((tail (+ (* n4 4ul) (get-global-id 0))))
#         (when (< tail n)
#           (set! acc (+ acc (to-double (~ input tail))))))
#       ;; Idiomatic Crisp warp reduction and atomic accumulation
#       (reduce-warp #'+ acc (to-double 0.0))
#       (when (= lane 0ul)
#         (atomic-add! (~ result) acc))))
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
        "	.reg .pred 	%%cr_p<9>;\n"
        "	.reg .b32 	%%cr_r<42>;\n"
        "	.reg .b64 	%%cr_rd<122>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd36, %2;\n"
        "	mov.b64 	%%cr_rd39, %0;\n"
        "	mov.b64 	%%cr_rd40, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd1, %%cr_rd39;\n"
        "	mov.b64 	%%cr_rd41, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd41;\n"
        "	shr.u64 	%%cr_rd42, %%cr_rd40, 4;\n"
        "	mov.u32 	%%cr_r4, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r5, %%ntid.x;\n"
        "	mov.u32 	%%cr_r6, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r6;\n"
        "	mul.wide.u32 	%%cr_rd43, %%cr_r4, %%cr_r5;\n"
        "	add.s64 	%%cr_rd7, %%cr_rd43, %%cr_rd6;\n"
        "	mov.u32 	%%cr_r7, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd9, %%cr_r7, %%cr_r5;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd7, %%cr_rd42;\n"
        "	mov.b64 	%%cr_rd113, 0;\n"
        "	@%%cr_p1 bra 	$L__BB43_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd44, %%cr_rd7;\n"
        "	add.s64 	%%cr_rd10, %%cr_rd42, %%cr_rd44;\n"
        "	or.b64 	%%cr_rd45, %%cr_rd10, %%cr_rd9;\n"
        "	and.b64 	%%cr_rd46, %%cr_rd45, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd46, 0;\n"
        "	@%%cr_p2 bra 	$L__BB43_3;\n"
        "	bra.uni 	$L__BB43_2;\n"
        "$L__BB43_3:\n"
        "	div.u64 	%%cr_rd112, %%cr_rd10, %%cr_rd9;\n"
        "	bra.uni 	$L__BB43_4;\n"
        "$L__BB43_2:\n"
        "	cvt.u32.u64 	%%cr_r8, %%cr_rd9;\n"
        "	cvt.u32.u64 	%%cr_r9, %%cr_rd10;\n"
        "	div.u32 	%%cr_r10, %%cr_r9, %%cr_r8;\n"
        "	cvt.u64.u32 	%%cr_rd112, %%cr_r10;\n"
        "$L__BB43_4:\n"
        "	add.s64 	%%cr_rd113, %%cr_rd112, 1;\n"
        "$L__BB43_5:                             // %%ifcont\n"
        "	and.b64 	%%cr_rd3, %%cr_rd36, -4;\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd113, 0;\n"
        "	mov.b64 	%%cr_rd120, 0d0000000000000000;\n"
        "	@%%cr_p3 bra 	$L__BB43_11;\n"
        "// %%bb.6:                               // %%dt_body.preheader\n"
        "	and.b64 	%%cr_rd16, %%cr_rd113, 1;\n"
        "	setp.eq.b64 	%%cr_p4, %%cr_rd113, 1;\n"
        "	mov.b64 	%%cr_rd120, 0d0000000000000000;\n"
        "	mov.b64 	%%cr_rd118, 0;\n"
        "	@%%cr_p4 bra 	$L__BB43_9;\n"
        "// %%bb.7:                               // %%dt_body.preheader.new\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r4;\n"
        "	cvt.u64.u32 	%%cr_rd5, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd8, %%cr_r7;\n"
        "	and.b64 	%%cr_rd17, %%cr_rd113, -2;\n"
        "	shl.b64 	%%cr_rd53, %%cr_rd7, 4;\n"
        "	or.b64 	%%cr_rd18, %%cr_rd53, 12;\n"
        "	shl.b64 	%%cr_rd19, %%cr_rd9, 5;\n"
        "	add.s64 	%%cr_rd54, %%cr_rd4, %%cr_rd8;\n"
        "	mad.lo.s64 	%%cr_rd55, %%cr_rd54, %%cr_rd5, %%cr_rd6;\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd55, 4;\n"
        "	mov.b64 	%%cr_rd120, 0d0000000000000000;\n"
        "	mov.b64 	%%cr_rd118, 0;\n"
        "	mov.b64 	%%cr_rd114, %%cr_rd1;\n"
        "$L__BB43_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd56, %%cr_rd114, %%cr_rd18;\n"
        "	ld.global.v4.b32 	{%%cr_r11, %%cr_r12, %%cr_r13, %%cr_r14}, [%%cr_rd56+-12];\n"
        "	cvt.f64.f32 	%%cr_rd57, %%cr_r11;\n"
        "	cvt.f64.f32 	%%cr_rd58, %%cr_r12;\n"
        "	add.rn.f64 	%%cr_rd59, %%cr_rd57, %%cr_rd58;\n"
        "	add.rn.f64 	%%cr_rd60, %%cr_rd120, %%cr_rd59;\n"
        "	cvt.f64.f32 	%%cr_rd61, %%cr_r13;\n"
        "	cvt.f64.f32 	%%cr_rd62, %%cr_r14;\n"
        "	add.rn.f64 	%%cr_rd63, %%cr_rd61, %%cr_rd62;\n"
        "	add.rn.f64 	%%cr_rd64, %%cr_rd63, %%cr_rd60;\n"
        "	add.s64 	%%cr_rd65, %%cr_rd114, %%cr_rd20;\n"
        "	ld.global.v4.b32 	{%%cr_r15, %%cr_r16, %%cr_r17, %%cr_r18}, [%%cr_rd65];\n"
        "	cvt.f64.f32 	%%cr_rd66, %%cr_r15;\n"
        "	cvt.f64.f32 	%%cr_rd67, %%cr_r16;\n"
        "	add.rn.f64 	%%cr_rd68, %%cr_rd66, %%cr_rd67;\n"
        "	add.rn.f64 	%%cr_rd69, %%cr_rd64, %%cr_rd68;\n"
        "	cvt.f64.f32 	%%cr_rd70, %%cr_r17;\n"
        "	cvt.f64.f32 	%%cr_rd71, %%cr_r18;\n"
        "	add.rn.f64 	%%cr_rd72, %%cr_rd70, %%cr_rd71;\n"
        "	add.rn.f64 	%%cr_rd120, %%cr_rd72, %%cr_rd69;\n"
        "	add.s64 	%%cr_rd118, %%cr_rd118, 2;\n"
        "	add.s64 	%%cr_rd114, %%cr_rd114, %%cr_rd19;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd17, %%cr_rd118;\n"
        "	@%%cr_p5 bra 	$L__BB43_8;\n"
        "$L__BB43_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd16, 0;\n"
        "	@%%cr_p6 bra 	$L__BB43_11;\n"
        "// %%bb.10:                              // %%dt_body.epil\n"
        "	mad.lo.s64 	%%cr_rd73, %%cr_rd118, %%cr_rd9, %%cr_rd7;\n"
        "	shl.b64 	%%cr_rd74, %%cr_rd73, 4;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd1, %%cr_rd74;\n"
        "	ld.global.v4.b32 	{%%cr_r19, %%cr_r20, %%cr_r21, %%cr_r22}, [%%cr_rd75];\n"
        "	cvt.f64.f32 	%%cr_rd76, %%cr_r19;\n"
        "	cvt.f64.f32 	%%cr_rd77, %%cr_r20;\n"
        "	add.rn.f64 	%%cr_rd78, %%cr_rd76, %%cr_rd77;\n"
        "	add.rn.f64 	%%cr_rd79, %%cr_rd120, %%cr_rd78;\n"
        "	cvt.f64.f32 	%%cr_rd80, %%cr_r21;\n"
        "	cvt.f64.f32 	%%cr_rd81, %%cr_r22;\n"
        "	add.rn.f64 	%%cr_rd82, %%cr_rd80, %%cr_rd81;\n"
        "	add.rn.f64 	%%cr_rd120, %%cr_rd82, %%cr_rd79;\n"
        "$L__BB43_11:                            // %%dt_exit\n"
        "	mov.u32 	%%cr_r1, %%laneid;\n"
        "	add.s64 	%%cr_rd83, %%cr_rd3, %%cr_rd7;\n"
        "	setp.ge.u64 	%%cr_p7, %%cr_rd83, %%cr_rd36;\n"
        "	@%%cr_p7 bra 	$L__BB43_13;\n"
        "// %%bb.12:                              // %%then113\n"
        "	shl.b64 	%%cr_rd84, %%cr_rd83, 2;\n"
        "	add.s64 	%%cr_rd32, %%cr_rd1, %%cr_rd84;\n"
        "	ld.global.b32 	%%cr_r23, [%%cr_rd32];\n"
        "	cvt.f64.f32 	%%cr_rd85, %%cr_r23;\n"
        "	add.rn.f64 	%%cr_rd120, %%cr_rd120, %%cr_rd85;\n"
        "$L__BB43_13:                            // %%lv_pre\n"
        "	cvt.u32.u64 	%%cr_r24, %%cr_rd120;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r25}, %%cr_rd120; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r26, %%cr_r24, 16, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r27, %%cr_r25, 16, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd86, %%cr_r26;\n"
        "	cvt.u64.u32 	%%cr_rd87, %%cr_r27;\n"
        "	shl.b64 	%%cr_rd88, %%cr_rd87, 32;\n"
        "	or.b64 	%%cr_rd89, %%cr_rd88, %%cr_rd86;\n"
        "	add.rn.f64 	%%cr_rd90, %%cr_rd120, %%cr_rd89;\n"
        "	cvt.u32.u64 	%%cr_r28, %%cr_rd90;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r29}, %%cr_rd90; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r30, %%cr_r28, 8, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r31, %%cr_r29, 8, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd91, %%cr_r30;\n"
        "	cvt.u64.u32 	%%cr_rd92, %%cr_r31;\n"
        "	shl.b64 	%%cr_rd93, %%cr_rd92, 32;\n"
        "	or.b64 	%%cr_rd94, %%cr_rd93, %%cr_rd91;\n"
        "	add.rn.f64 	%%cr_rd95, %%cr_rd90, %%cr_rd94;\n"
        "	cvt.u32.u64 	%%cr_r32, %%cr_rd95;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r33}, %%cr_rd95; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r34, %%cr_r32, 4, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r35, %%cr_r33, 4, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd96, %%cr_r34;\n"
        "	cvt.u64.u32 	%%cr_rd97, %%cr_r35;\n"
        "	shl.b64 	%%cr_rd98, %%cr_rd97, 32;\n"
        "	or.b64 	%%cr_rd99, %%cr_rd98, %%cr_rd96;\n"
        "	add.rn.f64 	%%cr_rd100, %%cr_rd95, %%cr_rd99;\n"
        "	cvt.u32.u64 	%%cr_r36, %%cr_rd100;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r37}, %%cr_rd100; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r38, %%cr_r36, 2, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r39, %%cr_r37, 2, 31, -1;\n"
        "	cvt.u64.u32 	%%cr_rd101, %%cr_r38;\n"
        "	cvt.u64.u32 	%%cr_rd102, %%cr_r39;\n"
        "	shl.b64 	%%cr_rd103, %%cr_rd102, 32;\n"
        "	or.b64 	%%cr_rd104, %%cr_rd103, %%cr_rd101;\n"
        "	add.rn.f64 	%%cr_rd35, %%cr_rd100, %%cr_rd104;\n"
        "	cvt.u32.u64 	%%cr_r40, %%cr_rd35;\n"
        "	{ .reg .b32 tmp; mov.b64 {tmp, %%cr_r41}, %%cr_rd35; }\n"
        "	shfl.sync.bfly.b32 	%%cr_r2, %%cr_r40, 1, 31, -1;\n"
        "	shfl.sync.bfly.b32 	%%cr_r3, %%cr_r41, 1, 31, -1;\n"
        "	setp.ne.b32 	%%cr_p8, %%cr_r1, 0;\n"
        "	@%%cr_p8 bra 	$L__BB43_15;\n"
        "// %%bb.14:                              // %%then136\n"
        "	mov.b64 	%%cr_rd37, %4;\n"
        "	cvt.u64.u32 	%%cr_rd105, %%cr_r3;\n"
        "	shl.b64 	%%cr_rd106, %%cr_rd105, 32;\n"
        "	cvt.u64.u32 	%%cr_rd107, %%cr_r2;\n"
        "	or.b64 	%%cr_rd108, %%cr_rd106, %%cr_rd107;\n"
        "	add.rn.f64 	%%cr_rd109, %%cr_rd35, %%cr_rd108;\n"
        "	add.s64 	%%cr_rd110, %%cr_rd2, %%cr_rd37;\n"
        "	atom.global.add.f64 	%%cr_rd111, [%%cr_rd110], %%cr_rd109;\n"
        "$L__BB43_15:                            // %%ifcont138\n"
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

    int64_t needed_blocks = (N + (BLOCK_SIZE * 4) - 1) / (BLOCK_SIZE * 4);
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
