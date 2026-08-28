// SYCL-TLA PEER, fp16.  A verbatim port of sec2_top_bf16/sycl_tla_peer.cpp with the operand
// element type changed and nothing else -- same TiledMMA, same tile shape, same pipeline depth.
//
// WHY IT EXISTS.  The fp16 section had an EMPTY Peer column, so Crisp's fp16 numbers had only a
// Control (hand SYCL) and a Ceiling (oneMKL) to sit between, and the one contender that actually
// reaches the matrix engines at full rate was missing.  SYCL-TLA does implement fp16 on Xe2 (it
// is TF32 it does not implement), so the gap was ours, not the peer's.
//
// The bf16 twin is the reference; if these two disagree by more than the run-to-run spread on
// anything other than the element type, this port is suspect.  THEY DO -- see below.
//
// FIRST MEASUREMENT, AND AN UNRESOLVED DISCREPANCY.  Against its bf16 reference, measured in the
// SAME session (2026-08-27):
//
//     N        256    512   1024   2048   4096   8192
//     bf16     0.3    3.7   26.0  101.3  194.5  234.0
//     fp16     0.3    2.7   20.6  107.9  169.5  237.6
//     delta    0%   -27%   -21%    +7%   -13%    +2%
//
// Four of six sizes differ by more than the 3.1% run-to-run spread, and they differ in BOTH
// directions, so it is not a constant offset.  Two readings, and this file does not choose
// between them:
//   * REAL.  fp16 and bf16 take different upconversion sequences into the DPAS operand format,
//     so a per-size difference is physically possible.  Note the sycl-tla builder comment says
//     f16 is the DEFAULT because "upconversion sequences are typically faster" -- which predicts
//     fp16 should be the FASTER of the two, and at 512/1024/4096 it is slower.  That is the
//     direction that does not fit.
//   * ARTEFACT.  This suite builds SYCL-TLA with JIT, not AOT (`ocloc` is absent from the bench
//     image, and the driver says so on every run).  A JIT contender re-tunes per build, so some
//     of this spread may be compilation variance rather than a property of either kernel.
//
// DO NOT quote the fp16 peer against the bf16 peer as though the difference were established.
// Resolving it wants ocloc in the image so both peers are AOT, then a repeat.
/*
 * SYCL-TLA Peer Contender for BFloat16 Top GEMM (§2 BF16) on Intel BattleMage (Arc B580).
 * Built with the genuine Intel SYCL-TLA (CUTLASS 3.x / CuTe for SYCL) library.
 *
 * Implements:
 *   - CuTe TiledMMA (XE_DPAS_TT<8, float, half_t>)
 *   - CollectiveMMA (MainloopXeL1Staged<2>) with 2-stage prefetch
 *   - CollectiveEpilogue (IntelXeGeneric, LinearCombination)
 *   - GemmUniversalAdapter
 */

#include "cutlass/epilogue/collective/default_epilogue.hpp"
#include "cutlass/epilogue/collective/xe_epilogue.hpp"
#include "cutlass/epilogue/fusion/xe_callbacks.hpp"
#include "cutlass/gemm/device/gemm_universal.h"
#include "cutlass/gemm/device/gemm_universal_adapter.h"
#include "cutlass/gemm/collective/collective_mma.hpp"
#include "cutlass/util/GPU_Clock.hpp"

#include <cute/tensor.hpp>
#include <iostream>
#include <vector>
#include <chrono>
#include <algorithm>
#include <cmath>

#include "cutlass/util/device_memory.h"
#include "cutlass/util/packed_stride.hpp"

using namespace cute;

// Layout definitions
using LayoutA = cutlass::layout::RowMajor;
using LayoutB = cutlass::layout::RowMajor;
using LayoutC = cutlass::layout::RowMajor;
using LayoutD = cutlass::layout::RowMajor;

using ElementInputA = cutlass::half_t;
using ElementInputB = cutlass::half_t;
using ElementOutput = float;
using ElementAccumulator = float;
using ElementComputeEpilogue = float;

using StrideA = cutlass::gemm::TagToStrideA_t<LayoutA>;
using StrideB = cutlass::gemm::TagToStrideB_t<LayoutB>;
using StrideC = cutlass::gemm::TagToStrideC_t<LayoutC>;
using StrideD = cutlass::gemm::TagToStrideC_t<LayoutD>;

using TileShape = Shape<_256, _256, _32>;
using TiledMma = typename TiledMMAHelper<
    MMA_Atom<XE_DPAS_TT<8, float, cute::half_t>>,
    Layout<TileShape>,
    Layout<Shape<_8, _4, _1>, Stride<_4, _1, _0>>>::TiledMMA;

constexpr int PipelineStages = 2;
using GEMMDispatchPolicy = cutlass::gemm::MainloopXeL1Staged<PipelineStages>;
using EpilogueDispatchPolicy = cutlass::epilogue::IntelXeGeneric;

using EpilogueOp = cutlass::epilogue::fusion::LinearCombination<
    ElementOutput, ElementComputeEpilogue,
    ElementAccumulator, ElementAccumulator,
    cutlass::FloatRoundStyle::round_to_nearest>;

using FusionCallbacks = cutlass::epilogue::fusion::FusionCallbacks<
    EpilogueDispatchPolicy, EpilogueOp, TileShape,
    decltype(tile_shape(TiledMma()))>;

using CollectiveEpilogue = cutlass::epilogue::collective::CollectiveEpilogue<
    EpilogueDispatchPolicy,
    TileShape,
    void,
    ElementAccumulator,
    StrideC,
    ElementOutput,
    StrideD,
    FusionCallbacks,
    void,
    void>;

using CollectiveMainloop = cutlass::gemm::collective::CollectiveMma<
    GEMMDispatchPolicy,
    TileShape,
    ElementInputA,
    StrideA,
    ElementInputB,
    StrideB,
    TiledMma,
    void, void, void, cute::identity,
    void, void, void, cute::identity>;

using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
    Shape<int, int, int, int>,
    CollectiveMainloop,
    CollectiveEpilogue>;

using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;

int main(int argc, char const **argv) {
    try {
        auto wall_start = std::chrono::high_resolution_clock::now();
        int M      = argc > 1 ? atoi(argv[1]) : 256;
        int N      = argc > 2 ? atoi(argv[2]) : 256;
        int K      = argc > 3 ? atoi(argv[3]) : 256;
        int warmup = argc > 4 ? atoi(argv[4]) : 20;
        int iters  = argc > 5 ? atoi(argv[5]) : 100;

        auto problem_size = GemmKernel::ProblemShape{M, N, K, 1};

        auto stride_A = cutlass::make_cute_packed_stride(StrideA{}, cute::make_shape(M, K, 1));
        auto stride_B = cutlass::make_cute_packed_stride(StrideB{}, cute::make_shape(N, K, 1));
        auto stride_C = cutlass::make_cute_packed_stride(StrideC{}, cute::make_shape(M, N, 1));
        auto stride_D = cutlass::make_cute_packed_stride(StrideD{}, cute::make_shape(M, N, 1));

        cutlass::device_memory::allocation<ElementInputA> block_A(M * K);
        cutlass::device_memory::allocation<ElementInputB> block_B(K * N);
        cutlass::device_memory::allocation<ElementOutput> block_C(M * N);
        cutlass::device_memory::allocation<ElementOutput> block_D(M * N);

        std::vector<ElementInputA> host_A(M * K, ElementInputA(1.0f));
        std::vector<ElementInputB> host_B(K * N, ElementInputB(1.0f));
        std::vector<ElementOutput> host_C(M * N, 0.0f);

        cutlass::device_memory::copy_to_device(block_A.get(), host_A.data(), host_A.size());
        cutlass::device_memory::copy_to_device(block_B.get(), host_B.data(), host_B.size());
        cutlass::device_memory::copy_to_device(block_C.get(), host_C.data(), host_C.size());

        cutlass::KernelHardwareInfo hw_info;

        typename Gemm::GemmKernel::Arguments arguments{
            cutlass::gemm::GemmUniversalMode::kGemm,
            problem_size,
            {block_A.get(), stride_A, block_B.get(), stride_B},
            {{1.0f, 0.0f}, block_C.get(), stride_C, block_D.get(), stride_D},
            hw_info
        };

        Gemm gemm_op;
        size_t workspace_size = Gemm::get_workspace_size(arguments);
        cutlass::device_memory::allocation<uint8_t> workspace(workspace_size);

        if (gemm_op.can_implement(arguments) != cutlass::Status::kSuccess) {
            std::cerr << "SYCL-TLA cannot implement GEMM for size: " << M << "x" << N << "x" << K << std::endl;
            return 1;
        }

        if (gemm_op.initialize(arguments, workspace.get()) != cutlass::Status::kSuccess) {
            std::cerr << "SYCL-TLA initialize failed" << std::endl;
            return 1;
        }

        for (int i = 0; i < warmup; i++) {
            gemm_op.run();
        }
        compat::wait();

        std::vector<double> kt(iters);
        for (int i = 0; i < iters; i++) {
            GPU_Clock timer;
            timer.start();
            gemm_op.run();
            compat::wait();
            kt[i] = timer.seconds() * 1e6; // microseconds
        }

        // ---- CORRECTNESS, added 2026-08-27.  This harness had NONE. -------------------
        // A = B = 1.0 above, so every element of D must equal exactly K.  Same oracle the Crisp
        // fixture uses.  Checked AFTER the timing loop so it cannot perturb the measurement.
        //
        // WHY IT WAS ADDED.  This contender reported 236 TFLOPS fp16 at N=8192 while oneMKL
        // reported 111 and Crisp 106 -- both of which verify every point.  Depending on whether
        // the B580's fp16 XMX peak is ~116 TF (INT8/2) or ~233-270 TF, that reading is either
        // impossible or merely excellent, and spec sheets do not settle it: on Alchemist the
        // INT8:fp16 ratio was 4:1, not 2:1.  An unverified number cannot arbitrate, and this was
        // the only contender in the suite without a check -- which is exactly the shape of the
        // chap2_tiling failure, where the second-best number in a section came from a kernel that
        // stored nothing.
        bool tla_ok = true; double tla_max_err = 0.0; long tla_checked = 0;
        {
            compat::wait();
            std::vector<ElementOutput> host_D(size_t(M) * size_t(N));
            cutlass::device_memory::copy_to_host(host_D.data(), block_D.get(), host_D.size());
            const double expect = double(K);
            const double tol    = expect * 1e-3;
            const size_t si = (M > 64 ? size_t(M) / 64 : 1), sj = (N > 64 ? size_t(N) / 64 : 1);
            for (size_t i = 0; i < size_t(M) && tla_ok; i += si)
                for (size_t j = 0; j < size_t(N); j += sj) {
                    double got = double(host_D[i * size_t(N) + j]);
                    double err = std::abs(got - expect);
                    if (err > tla_max_err) tla_max_err = err;
                    ++tla_checked;
                    if (err > tol) { tla_ok = false; break; }
                }
        }
        std::cerr << (tla_ok ? "MMA_CORRECT" : "MMA_WRONG")
                  << " (peer self-check: expect " << double(K)
                  << ", max_abs_err " << tla_max_err
                  << ", samples " << tla_checked << ")" << std::endl;
        // --------------------------------------------------------------------------------

        std::sort(kt.begin(), kt.end());
        double k_med = kt[iters / 2];
        double k_min = kt[0];
        double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

        auto wall_end = std::chrono::high_resolution_clock::now();
        double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

        printf("{\n  \"algorithm\": \"matmul_top_fp16\",\n  \"implementation\": \"sycl_tla_fp16\",\n");
        printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
        // REPORT THE REAL VERDICT.  This line used to hardcode correct=true -- the harness
        // ASSERTED a correctness it never checked.  scripts/crisp_bench/matmul.py run_sweep
        // already DROPS any point whose harness reports correct=false, so that gate was
        // working the whole time; it was being lied to.  That is how this contender came to
        // report 236 TFLOPS at N=8192 while writing an all-zero output matrix.
        printf("  \"correct\": %s,\n  \"max_abs_err\": %.6g,\n",
               tla_ok ? "true" : "false", tla_max_err);
        printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
        printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
        printf("  \"gflops\": %.2f\n}\n", gflops);

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "SYCL-TLA exception: " << e.what() << std::endl;
        return 1;
    }
}
