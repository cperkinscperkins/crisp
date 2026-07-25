# Endeavor 143 — Intel Benchmark Modernization

Kicked off 2026-07-24 (after 142 mma-prefetch's compiler work: prefetch-tile + register-tile-ring +
unroll-by-ring-count, all metal-correct on BMG).  142's *compiler* side is essentially done; THIS
endeavor is the benchmarking infrastructure so the Intel prefetch story (and Q1) can be measured and
reported the same way the NVIDIA side is.

## Goal
Bring the Intel benchmarking (`scripts/bench-intel.sh` + `bench-intel-driver.py`, run in Docker with
BMG passthrough) up to parity with the NVIDIA system (`benchmarks/` + `scripts/crisp_bench/*.py`):
**JSON results in the shared schema + precision sweep + explicit precision flags always + `report.py`
compatibility** (a `## Hardware: Intel BMG` section appears automatically).

## Constraints (from Chris)
- The Windows BMG host has **NO OneAPI / MSVC** and we keep it that way.  ALL Intel benchmarking runs
  in a **Linux Docker container** (`scripts/Dockerfile.bench-intel`, oneAPI + L0 via `/dev/dxg`), for
  **both Crisp and SYCL**.  `bench-intel.sh` (host wrapper) + `bench-intel-entrypoint.sh` (in-container
  build + driver) stay; the modernization is in the driver layer.
- **Explicit precision flags ALWAYS** — never rely on compiler defaults (policy from the reduction /
  precision-report work).  Crisp: `--math-precision=fast|ieee` + `--denormal-handling=ftz|preserve`.
  SYCL/icpx: `-ffast-math` / `-fno-fast-math` (+ ftz control); document any Intel-side caveat.

## Settled decisions (Chris, 2026-07-24)
- **Reuse the JSON schema verbatim** — `scripts/crisp_bench/harness.py::BenchmarkSweep` is already
  GPU-agnostic (`hardware.gpu_model` tags the platform; `SYCL_Apples`/`OneMKL_Optimal` already in the
  competitor vocabulary).  Intel JSON drops into `benchmarks/results/`; `report.py` grows the BMG
  section with no changes.  Mapping from the L0 harness binary's stdout: `gflops`→`tflops` (÷1000),
  `kernel_median_us`→`kernel_execution_ms` (÷1000); `device`/`end_to_end` compile times already tracked.
- **Plumbing-first, incremental** (NOT a big-bang full ladder).  Reuse existing Intel kernels for the
  base chapters; add the 142 prefetch pipeline as a new chapter later (that's also how Q1 gets answered:
  prefetch-chapter vs sync-chapter, in the report).
- **Intel chapters** — Intel has no TMA/wgmma, so NVIDIA chapter numbers don't transfer.  Ladder:
  `chap0_sync` (coop-matrix) → `chap1_async` (OpGroupAsyncCopy) → `chap_intel_prefetch` (142 — the
  headline).  chap0/chap1 stay NUMBERED (same concepts as NVIDIA, aids the cross-platform read); the
  prefetch chapter is NAMED, not numbered ("chapter Intel", i.e. slug `chap_intel_prefetch`), so it does
  NOT read as rung-N on the shared ladder (no false "Intel ch4 < NVIDIA ch3" comparison).
- **Competitors** — start **Crisp vs SYCL_Apples** (both build today); add `OneMKL_Optimal`
  (`oneapi::mkl::blas::gemm`) as a fast-follow once the pipeline works.

## DECISION (Chris, 2026-07-24): approach (A) — extend matmul.py into ONE cross-platform driver.
matmul.py already runs SYCL_Apples + OneMKL_Optimal (icpx) + emits the JSON schema + sweeps precision;
only the Crisp path was NVIDIA-only.  So the work is a `--platform=intel` axis, not a second driver.
The Intel path runs INSIDE the Docker container (bench-intel.sh → entrypoint → matmul.py --platform=intel).
NVIDIA unchanged (native on the RunPod).

## PROGRESS (2026-07-24) — core plumbing DONE + natively proven on the BMG
- [DONE] `--platform=intel` in matmul.py.  Platform-tagged HW metadata (`_apply_hw`, HW_BY_PLATFORM →
  gpu_model "Intel BMG").  Intel branch of the chapter list: Crisp (L0) + SYCL_Apples + OneMKL_Optimal
  (the last two REUSE the existing icpx run_target — they auto-skip when icpx is absent, e.g. this
  Windows smoke test).  build_harness (nvcc) skipped on Intel.
- [DONE] Intel Crisp path = the FIXED L0 harness (mirrors NVIDIA chap0/chap1 CRISP_MATMUL_PTX):
  `build_l0_harness` compiles benchmarks/matmul/crisp/bench_harness_l0.cpp ONCE (it launches the
  (M/32,N/32) tile-grid the matmul_bmg kernels need + emits {gflops, kernel_median_us}); per precision
  the kernel recompiles to SPV (bmg, explicit --math-precision/--denormal-handling); `run_l0_fixed_sweep`
  runs the harness per size via CRISP_MATMUL_SPV and builds a BenchmarkSweep.  C++ compiler resolved:
  icpx (container) / clang++ (Windows native), link ze_loader.  NOTE the FIRST attempt used the hoist
  --mma-bench path — WRONG for tiled kernels: it launches the kernel's default 1-workgroup grid, so a
  256³ matmul only computes one 32×32 tile → NOT MMA_CORRECT.  The fixed harness is the tiled-kernel path.
- [PROVEN natively] `matmul.py --platform=intel --sizes=256,512 --precision=fast` on this BMG:
  chap0_sync Crisp 256³=122 / 512³=460 GFLOPS; chap1_async 256³=90 / 512³=328.  JSON in the shared
  schema, `report.py --results-dir=...` renders a `## Hardware: Intel BMG` section (ladder + tables +
  compile times) with ZERO report changes.

## Remaining
- [DONE] Wired `bench-intel.sh` + `bench-intel-entrypoint.sh` → `matmul.py --platform=intel` (retired the
  bench-intel-driver.py call).  CLI became matmul-focused: `bench-intel.sh [sizes] [iters] [precision]`
  (precision "all" → --sweep-all).  Entrypoint exports CRISP_USE_SYSTEM_TOOLS=true (Linux crisp-compile
  finds llc/llvm-spirv on PATH) + runs matmul.py in-container; JSON → benchmarks/results (bind-mounted).
  bash -n clean; NOT run in Docker from the Windows host — Chris runs the container sweep to validate the
  SYCL_Apples + OneMKL_Optimal (icpx) targets end-to-end.
- [DONE] report.py platform-aware (derives platform from gpu_model): `_platform_of` / `_vendor_label`
  (cuBLAS↔oneMKL) / `_vendor_competitor` (CUBLAS_Optimal↔OneMKL_Optimal) / `_chapter_label`
  (INTEL_CHAPTER_LABEL overrides: chap0 "coop-matrix XMX tf32", chap1 "OpGroupAsyncCopy XMX tf32") /
  `_is_mma_chapter` (Intel = always tf32).  Summary header/column, per-chapter labels, IEEE annotation,
  and the compile-times footnote (SPIR-V/icpx vs PTX/nvcc) all switch by section.  chap_intel_prefetch
  added to CHAPTER_ORDER/LABEL.  Verified: Intel section renders oneMKL/XMX/SPIR-V; NVIDIA UNCHANGED.
- [ ] Step 4: chap_intel_prefetch (142 register-ring pipeline) — needs its own harness (different param
  layout than the fixed one) or a --grid-tile L0 hoist path.  This answers Q1.
- [ ] Docs: benchmarks/README.md Intel section + bench-intel.sh header (header done; README pending).

## Plan (original order of work)
- [ ] **Step 0 — locate the Intel matmul kernels.**  The old driver references
      `benchmarks/matmul/crisp/matmul_bmg.crisp` + `matmul_bmg_async.crisp`, but `crisp/` now holds
      NVIDIA kernels and `sycl/` has only a compiled `matmul_sycl` binary (no source).  Find the current
      Intel matmul crisp source + SYCL source (candidates: `performance/matmul-bmg/`, git history, or
      seed `chap0_sync` from endeavor-142's metal-correct `12-ring-kloop`/`matmul_bmg`).  Decide the
      Intel chapter dir layout (parallel to the NVIDIA `benchmarks/matmul/chapN/`, e.g.
      `benchmarks/matmul/intel/chap0_sync/` OR a per-chapter tag in the driver — pick one, document it).
- [ ] **Step 1 — driver emits JSON.**  `bench-intel-driver.py`: wrap each (chapter, competitor, size)
      result in a `BenchmarkSweep` SweepPoint and `.save()` to `benchmarks/results/`, tagging
      `gpu_model` from the L0 device name (the driver already probes `Device:` off stderr).  Keep the
      stdout table too (handy live view).  Verify a resulting JSON is picked up by `report.py`.
- [ ] **Step 2 — precision sweep + explicit flags.**  Loop `fast / ieee+ftz / ieee` like
      `matmul.py --sweep-all`.  Recompile per precision: Crisp `.spv` with `--math-precision` +
      `--denormal-handling`; SYCL binary with the matching icpx flags.  Record `precision` +
      `denormal_handling` in the JSON.  (NOTE: like the NVIDIA tf32 chapters, an all-DPAS Intel kernel
      may be precision-inert — verify + annotate rather than assume.)
- [ ] **Step 3 — chapters wired.**  `chap0_sync` + `chap1_async` from the existing/located kernels,
      Crisp + SYCL_Apples.  Confirm `report.py` renders the BMG section (ladder + per-chapter tables).
- [ ] **Step 4 — `chap_intel_prefetch`.**  Add the 142 prefetch-overlapped pipeline kernel as the named
      Intel chapter → **answers Q1** (prefetch ON vs OFF / vs chap0 sync, at real scale).  This is where
      the endeavor-142 measurement finally lands.
- [ ] **Step 5 — `OneMKL_Optimal`** vendor ceiling (`oneapi::mkl::blas::gemm` harness).
- [ ] **Step 6 — docs.**  Update `benchmarks/README.md` (Intel section: Docker flow, chapters, flags)
      and `scripts/bench-intel.sh` header (JSON/precision/args like the new system).

## Open items to resolve during Step 0/1
- Chapter directory convention: mirror `benchmarks/matmul/chapN/` under an `intel/` subtree, or reuse
  the flat crisp/sycl dirs with a chapter field in the driver's ALGORITHMS table?  (Lean: an `intel/`
  subtree so NVIDIA + Intel kernels don't collide in one dir.)
- The L0 bench harness (`bench_harness_l0.cpp`) emits `gflops` + `kernel_median_us` — confirm it takes
  size args (M,N,K) and that Crisp `.spv` precision is baked at compile time (so precision sweep =
  recompile), not a runtime knob.
- `--mma-bench` (the endeavor-142 L0 hoist timing path) vs the standalone `bench_harness_l0.cpp` — decide
  which drives `chap_intel_prefetch` (the hoist `--mma-bench` reads real kernel params; the fixed
  harness may not fit the register-ring param layout).  Likely the hoist `--mma-bench` for the prefetch
  chapter, matching how the NVIDIA advanced chapters route through `crisp-hoist-cuda --mma-bench`.

## Success = one command in Docker sweeps Intel matmul across precisions, drops JSON into
`benchmarks/results/`, and `report.py` prints a `## Hardware: Intel BMG` section with the
`chap0_sync → chap1_async → chap_intel_prefetch` ladder — Crisp vs SYCL (vs OneMKL later).

