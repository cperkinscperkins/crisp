# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source (histogram_beauty.crisp):
# -------------------------------------------------------------------------
#   ;; GPU MODE Challenge 04: histogram_v2 (Beauty Contestant)
#   ;; Counts occurrences of uint8 values [0..255] into 256 int64 bins.
#   ;; Uses a 256-bin workgroup-privatized shared-memory histogram to absorb
#   ;; atomic contention before flushing to global memory.
#
#   (def-type in-vec   (vector uchar :address-space :global :align :compact))
#   (def-type out-vec  (vector ulong :address-space :global :align :compact))
#   (def-type smem-vec (vector uint  :address-space :local  :align :compact))
#
#   (def-kernel histogram_kernel (input &out output)
#     (declare #'(in-vec &out out-vec => nil)
#              (global-size :derive-from input :strategy :strided)
#              (local-size  :set-to 256))
#     (let ((shist (make-scratch-vector smem-vec 256))
#           (tid   (to-ulong (get-local-id 0))))
#       (set! (~ shist tid) 0u)
#       (sync-workgroup)
#       (loop-vector-stride input (i)
#         (atomic-inc! (~ shist (to-ulong (~ input i)))))
#       (sync-workgroup)
#       (let ((cnt (~ shist tid)))
#         (when (> cnt 0u)
#           (atomic-add! (~ output tid) (to-ulong cnt))))
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
void crisp_histogram_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t in_len
) {
    extern __shared__ __align__(128) unsigned char crisp_smem[];
    uint64_t smem_ptr = static_cast<uint64_t>(__cvta_generic_to_shared(crisp_smem));
    asm volatile(
        "{\n"
        "	.reg .pred 	%%cr_p<9>;\n"
        "	.reg .b32 	%%cr_r<26>;\n"
        "	.reg .b64 	%%cr_rd<120>;\n"
        "// %%bb.0:                               // %%entry\n"
        "	mov.b64 	%%cr_rd55, %0;\n"
        "	mov.b64 	%%cr_rd56, %4;\n"
        "	add.s64 	%%cr_rd1, %%cr_rd55, %%cr_rd56;\n"
        "	mov.b64 	%%cr_rd57, %1;\n"
        "	cvta.to.global.u64 	%%cr_rd2, %%cr_rd57;\n"
        "	mov.b64 	%%cr_rd58, %3;\n"
        "	cvta.to.global.u64 	%%cr_rd3, %%cr_rd58;\n"
        "	mov.u32 	%%cr_r1, %%tid.x;\n"
        "	cvt.u64.u32 	%%cr_rd4, %%cr_r1;\n"
        "	mul.wide.u32 	%%cr_rd59, %%cr_r1, 4;\n"
        "	add.s64 	%%cr_rd5, %%cr_rd1, %%cr_rd59;\n"
        "	st.shared.b32 	[%%cr_rd5], 0;\n"
        "	mov.b64 	%%cr_rd60, %2;\n"
        "	bar.sync 	0;\n"
        "	mov.u32 	%%cr_r2, %%ctaid.x;\n"
        "	mov.u32 	%%cr_r3, %%ntid.x;\n"
        "	mul.wide.u32 	%%cr_rd8, %%cr_r2, %%cr_r3;\n"
        "	add.s64 	%%cr_rd61, %%cr_rd8, %%cr_rd4;\n"
        "	mov.u32 	%%cr_r4, %%nctaid.x;\n"
        "	mul.wide.u32 	%%cr_rd10, %%cr_r4, %%cr_r3;\n"
        "	setp.ge.u64 	%%cr_p1, %%cr_rd61, %%cr_rd60;\n"
        "	mov.b64 	%%cr_rd107, 0;\n"
        "	@%%cr_p1 bra 	$L__BB57_5;\n"
        "// %%bb.1:                               // %%else\n"
        "	not.b64 	%%cr_rd62, %%cr_rd61;\n"
        "	add.s64 	%%cr_rd11, %%cr_rd60, %%cr_rd62;\n"
        "	or.b64 	%%cr_rd63, %%cr_rd11, %%cr_rd10;\n"
        "	and.b64 	%%cr_rd64, %%cr_rd63, -4294967296;\n"
        "	setp.ne.b64 	%%cr_p2, %%cr_rd64, 0;\n"
        "	@%%cr_p2 bra 	$L__BB57_3;\n"
        "	bra.uni 	$L__BB57_2;\n"
        "$L__BB57_3:\n"
        "	div.u64 	%%cr_rd106, %%cr_rd11, %%cr_rd10;\n"
        "	bra.uni 	$L__BB57_4;\n"
        "$L__BB57_2:\n"
        "	cvt.u32.u64 	%%cr_r5, %%cr_rd10;\n"
        "	cvt.u32.u64 	%%cr_r6, %%cr_rd11;\n"
        "	div.u32 	%%cr_r7, %%cr_r6, %%cr_r5;\n"
        "	cvt.u64.u32 	%%cr_rd106, %%cr_r7;\n"
        "$L__BB57_4:\n"
        "	add.s64 	%%cr_rd107, %%cr_rd106, 1;\n"
        "$L__BB57_5:                             // %%ifcont\n"
        "	setp.eq.b64 	%%cr_p3, %%cr_rd107, 0;\n"
        "	@%%cr_p3 bra 	$L__BB57_12;\n"
        "// %%bb.6:                               // %%dt_body.lr.ph\n"
        "	cvt.u64.u32 	%%cr_rd6, %%cr_r2;\n"
        "	cvt.u64.u32 	%%cr_rd7, %%cr_r3;\n"
        "	cvt.u64.u32 	%%cr_rd9, %%cr_r4;\n"
        "	and.b64 	%%cr_rd118, %%cr_rd107, 7;\n"
        "	setp.lt.u64 	%%cr_p4, %%cr_rd107, 8;\n"
        "	mov.b64 	%%cr_rd117, 0;\n"
        "	@%%cr_p4 bra 	$L__BB57_9;\n"
        "// %%bb.7:                               // %%dt_body.lr.ph.new\n"
        "	and.b64 	%%cr_rd18, %%cr_rd107, -8;\n"
        "	mad.lo.s64 	%%cr_rd67, %%cr_rd9, 7, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd115, %%cr_rd67, %%cr_rd7, %%cr_rd2;\n"
        "	shl.b64 	%%cr_rd20, %%cr_rd10, 3;\n"
        "	mad.lo.s64 	%%cr_rd68, %%cr_rd9, 6, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd114, %%cr_rd68, %%cr_rd7, %%cr_rd2;\n"
        "	mad.lo.s64 	%%cr_rd69, %%cr_rd9, 5, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd113, %%cr_rd69, %%cr_rd7, %%cr_rd2;\n"
        "	shl.b64 	%%cr_rd70, %%cr_rd9, 2;\n"
        "	add.s64 	%%cr_rd71, %%cr_rd70, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd112, %%cr_rd71, %%cr_rd7, %%cr_rd2;\n"
        "	mad.lo.s64 	%%cr_rd72, %%cr_rd9, 3, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd111, %%cr_rd72, %%cr_rd7, %%cr_rd2;\n"
        "	shl.b64 	%%cr_rd73, %%cr_rd9, 1;\n"
        "	add.s64 	%%cr_rd74, %%cr_rd73, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd110, %%cr_rd74, %%cr_rd7, %%cr_rd2;\n"
        "	add.s64 	%%cr_rd75, %%cr_rd6, %%cr_rd9;\n"
        "	mad.lo.s64 	%%cr_rd109, %%cr_rd75, %%cr_rd7, %%cr_rd2;\n"
        "	add.s64 	%%cr_rd108, %%cr_rd2, %%cr_rd8;\n"
        "	mov.b64 	%%cr_rd117, 0;\n"
        "$L__BB57_8:                             // %%dt_body\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	add.s64 	%%cr_rd76, %%cr_rd108, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r8, [%%cr_rd76];\n"
        "	mul.wide.u32 	%%cr_rd77, %%cr_r8, 4;\n"
        "	add.s64 	%%cr_rd78, %%cr_rd1, %%cr_rd77;\n"
        "	atom.shared.add.u32 	%%cr_r9, [%%cr_rd78], 1;\n"
        "	add.s64 	%%cr_rd79, %%cr_rd109, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r10, [%%cr_rd79];\n"
        "	mul.wide.u32 	%%cr_rd80, %%cr_r10, 4;\n"
        "	add.s64 	%%cr_rd81, %%cr_rd1, %%cr_rd80;\n"
        "	atom.shared.add.u32 	%%cr_r11, [%%cr_rd81], 1;\n"
        "	add.s64 	%%cr_rd82, %%cr_rd110, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r12, [%%cr_rd82];\n"
        "	mul.wide.u32 	%%cr_rd83, %%cr_r12, 4;\n"
        "	add.s64 	%%cr_rd84, %%cr_rd1, %%cr_rd83;\n"
        "	atom.shared.add.u32 	%%cr_r13, [%%cr_rd84], 1;\n"
        "	add.s64 	%%cr_rd85, %%cr_rd111, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r14, [%%cr_rd85];\n"
        "	mul.wide.u32 	%%cr_rd86, %%cr_r14, 4;\n"
        "	add.s64 	%%cr_rd87, %%cr_rd1, %%cr_rd86;\n"
        "	atom.shared.add.u32 	%%cr_r15, [%%cr_rd87], 1;\n"
        "	add.s64 	%%cr_rd88, %%cr_rd112, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r16, [%%cr_rd88];\n"
        "	mul.wide.u32 	%%cr_rd89, %%cr_r16, 4;\n"
        "	add.s64 	%%cr_rd90, %%cr_rd1, %%cr_rd89;\n"
        "	atom.shared.add.u32 	%%cr_r17, [%%cr_rd90], 1;\n"
        "	add.s64 	%%cr_rd91, %%cr_rd113, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r18, [%%cr_rd91];\n"
        "	mul.wide.u32 	%%cr_rd92, %%cr_r18, 4;\n"
        "	add.s64 	%%cr_rd93, %%cr_rd1, %%cr_rd92;\n"
        "	atom.shared.add.u32 	%%cr_r19, [%%cr_rd93], 1;\n"
        "	add.s64 	%%cr_rd94, %%cr_rd114, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r20, [%%cr_rd94];\n"
        "	mul.wide.u32 	%%cr_rd95, %%cr_r20, 4;\n"
        "	add.s64 	%%cr_rd96, %%cr_rd1, %%cr_rd95;\n"
        "	atom.shared.add.u32 	%%cr_r21, [%%cr_rd96], 1;\n"
        "	add.s64 	%%cr_rd97, %%cr_rd115, %%cr_rd4;\n"
        "	ld.global.nc.b8 	%%cr_r22, [%%cr_rd97];\n"
        "	mul.wide.u32 	%%cr_rd98, %%cr_r22, 4;\n"
        "	add.s64 	%%cr_rd99, %%cr_rd1, %%cr_rd98;\n"
        "	atom.shared.add.u32 	%%cr_r23, [%%cr_rd99], 1;\n"
        "	add.s64 	%%cr_rd117, %%cr_rd117, 8;\n"
        "	add.s64 	%%cr_rd115, %%cr_rd115, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd114, %%cr_rd114, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd113, %%cr_rd113, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd112, %%cr_rd112, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd111, %%cr_rd111, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd110, %%cr_rd110, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd109, %%cr_rd109, %%cr_rd20;\n"
        "	add.s64 	%%cr_rd108, %%cr_rd108, %%cr_rd20;\n"
        "	setp.ne.b64 	%%cr_p5, %%cr_rd18, %%cr_rd117;\n"
        "	@%%cr_p5 bra 	$L__BB57_8;\n"
        "$L__BB57_9:                             // %%dt_exit.loopexit.unr-lcssa\n"
        "	setp.eq.b64 	%%cr_p6, %%cr_rd118, 0;\n"
        "	@%%cr_p6 bra 	$L__BB57_12;\n"
        "// %%bb.10:                              // %%dt_body.epil.preheader\n"
        "	mad.lo.s64 	%%cr_rd100, %%cr_rd117, %%cr_rd9, %%cr_rd6;\n"
        "	mad.lo.s64 	%%cr_rd101, %%cr_rd100, %%cr_rd7, %%cr_rd4;\n"
        "	add.s64 	%%cr_rd119, %%cr_rd2, %%cr_rd101;\n"
        "$L__BB57_11:                            // %%dt_body.epil\n"
        "                                        // =>This Inner Loop Header: Depth=1\n"
        "	.pragma \"nounroll\";\n"
        "	ld.global.nc.b8 	%%cr_r24, [%%cr_rd119];\n"
        "	mul.wide.u32 	%%cr_rd102, %%cr_r24, 4;\n"
        "	add.s64 	%%cr_rd103, %%cr_rd1, %%cr_rd102;\n"
        "	atom.shared.add.u32 	%%cr_r25, [%%cr_rd103], 1;\n"
        "	add.s64 	%%cr_rd119, %%cr_rd119, %%cr_rd10;\n"
        "	add.s64 	%%cr_rd118, %%cr_rd118, -1;\n"
        "	setp.ne.b64 	%%cr_p7, %%cr_rd118, 0;\n"
        "	@%%cr_p7 bra 	$L__BB57_11;\n"
        "$L__BB57_12:                            // %%dt_exit\n"
        "	bar.sync 	0;\n"
        "	ld.shared.b32 	%%cr_rd52, [%%cr_rd5];\n"
        "	setp.eq.b64 	%%cr_p8, %%cr_rd52, 0;\n"
        "	@%%cr_p8 bra 	$L__BB57_14;\n"
        "// %%bb.13:                              // %%then91\n"
        "	shl.b64 	%%cr_rd104, %%cr_rd4, 3;\n"
        "	add.s64 	%%cr_rd53, %%cr_rd3, %%cr_rd104;\n"
        "	atom.global.add.u64 	%%cr_rd105, [%%cr_rd53], %%cr_rd52;\n"
        "$L__BB57_14:                            // %%ifcont93\n"
        "	bra.uni $L__crisp_inline_exit;\n"
        "                                        // -- End function\n"
        "$L__crisp_inline_exit:\n"
        "}\n"
        : : "l"(0ULL), "l"(in_ptr), "l"(in_len), "l"(out_ptr), "l"(smem_ptr)
        : "memory"
    );
}

torch::Tensor launch_crisp_histogram(torch::Tensor input, torch::Tensor output) {
    int64_t N = input.numel();
    output.zero_();
    constexpr int BLOCK_SIZE = 256;
    static int max_grid = 0;
    if (max_grid <= 0) {
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_histogram_kernel, BLOCK_SIZE, 1024);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms) : 512;
    }
    int64_t needed = (N + (BLOCK_SIZE * 16) - 1) / (BLOCK_SIZE * 16);
    if (needed < 1) needed = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed, max_grid));

    crisp_histogram_kernel<<<grid_x, BLOCK_SIZE, 1024>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output;
}
"""
CPP_SOURCE = r"""torch::Tensor launch_crisp_histogram(torch::Tensor input, torch::Tensor output);"""

_crisp_mod = load_inline(
    name="crisp_crisp_histogram_beauty_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_histogram"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_histogram(inp, out)
