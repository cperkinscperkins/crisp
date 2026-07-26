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



---

## Phase 2 (2026-07-26) — the first Intel numbers were wrong, twice over

Two independent defects, found by cross-checking Crisp against its own `sycl_apples.cpp` mirror.
That cross-check is the durable lesson: **chap0 agreed with its mirror to 2.5%, intel_prefetch
diverged 10x.** Two implementations of the same algorithm on the same silicon do not differ 10x.
When they do, suspect the harness before believing the number.

### 1. Timing — reported GFLOPS inflated by exactly `iters`
The generated `--mma-bench` harness submitted the same closed command list N times and synced once,
commented "they serialize". Level Zero **coalesces re-submission of an in-flight command list**: a
probe measured a constant ~3.07 ms of wall time for N = 1, 2, 5, 10, 25, 50, 100 submits of a 1024^3
GEMM. Correctness could not catch it — every iteration reads the same A/B and writes the same C, so
`MMA_CORRECT` passes either way.

Fixed in `overlays/hoist-l0/crisp-hoist-l0-overlay.lisp` (`generate-kernel-launch`): per-launch L0
kernel-timestamp events, median of N — the method `benchmarks/matmul/crisp/bench_harness_l0.cpp`
already used, which is why chap0/chap1 were never affected. The CUDA twin is NOT affected (it
re-issues `cuLaunchKernel` per iteration on an in-order stream), so all H100 numbers stand.

Also fixed: `run_l0_autobench` in `scripts/crisp_bench/matmul.py` reported `device_compile_ms = 0.0`.

### 2. Dispatch — a 1-D grid under a 2-D tile-stride loop
`:strided` emitted `{_hw_threads / wg_total, 1, 1}` and ignored `:tile-shape`. Under an N-D
`tile-stride` loop the axes with extent 1 are **serialized inside each workgroup** — at 1024 only the
32 column-tiles had any parallelism out of 640 resident hardware threads. Separately, `_hw_threads`
counts SIMD16 hardware threads but was divided by the workgroup size in *work-items* (16x low).
The two do not compose: `(640,1)` measured identical to `(40,1)`, so fixing the units alone bought
nothing.

Fixed via `%l0-emit-group-count` + new `%l0-emit-tile-grid-group-count`: when `:tile-shape` is
present the grid is the rank-N tile grid, axis k <- dimension k. API semantics recorded in
`docs/ideal_001.md` under `:strategy` / `:tile-shape` / `:occupancy` (chapters regenerated).

### Net effect, intel_prefetch @1024 fast/tf32
| | TFLOPS | vs oneMKL (11.97) |
|---|---:|---:|
| as first reported | 69.65 | 581.8% (fiction) |
| after timing fix | 1.40 | 11.7% |
| after dispatch fix | **10.36** | **~87%** |

For reference the hand-written SYCL mirror is 6.88, so Crisp now runs ~1.5x its own apples-to-apples
mirror. `benchmarks/REPORT.md` predates all of this and must be regenerated.

### Open / follow-up
- `tests/spec/089-strategy/14-hoist-strided` and `20-derive-from-vector-strided-occupancy` expect the
  literal string `zeDeviceGetComputeProperties`, which the compiler has never emitted (it calls
  `zeDeviceGetProperties`; the string appears only in source comments). **Pre-existing failures**, not
  caused by this work. Decide whether the specs' expectation is wrong or the implementation should
  additionally query compute properties — the latter is real: `maxGroupCountX/Y/Z` from
  `zeDeviceGetComputeProperties` would be the natural clamp for a tile grid on very large problems,
  which exact-cover dispatch now makes reachable.
- The units error means any **1-D `:strided`** kernel (no tile-shape) was dispatching 16x under on
  BMG. `benchmarks/reduction/` is exactly that shape and may have a second free win sitting in it.
- CUDA's `%cuda-emit-group-count` has not been checked for the same shape bug.


---

## DEFERRED STACK (as of 2026-07-26) — keep this short

Explicit list so these don't live only in conversation. Roughly ordered by how much they'd cost
to forget.

### Blocked on CUDA measurement (deliberate — do not resolve early)
1. **`:occupancy` API shape.** BMG says the knob loses everywhere tested (reduction: 0.15 is
   3.3–4.9x slower than 1.0, monotonic). NVIDIA may disagree — the "≈0.2 for reductions" figure
   originated there. The deeper gap: `:occupancy` is ONE scalar in kernel source but the right
   value is kernel × device. A single number cannot serve both vendors. Options: per-target
   values, a `def-hardware-profile` default the kernel overrides, or drop the knob.
2. **`sum-reduce.crisp` declares `:occupancy 0.15`** — a large pessimization on BMG, possibly
   correct on NVIDIA. Blocked on (1); the same file feeds both benchmark paths.
3. **Re-baseline `reduction-bmg`** (`kernel_median_us/best = 22.568`). Blocked on (2). Expect
   roughly 8.8 µs once occupancy is settled — reset ONCE, not twice.
4. **`%cuda-emit-group-count`** — never inspected for the same 1-D-grid-under-N-D-loop bug that
   cost 7.6x on L0. First thing to check on the pod. Note CUDA *timing* is already correct.

### Deferred by choice, no blocker
5. **`matrix-multiply-tile-stride` tile-shape inference.** Inference reaches 39 of 61 kernels;
   the other 22 (20 of them mmts, incl. matmul chap0/1/2) specify the tile via a tile TENSOR whose
   extents the parser cannot read. Usually knowable from an enclosing
   `make-register-tile float (32 32)`. Deferred so both tile-spec forms can be done in one pass
   across both backends after CUDA.
6. **Remaining `zeDeviceGetComputeProperties` validations.** We now clamp `maxGroupCountX/Y/Z`.
   Unused from the same struct: `maxTotalGroupSize` / `maxGroupSizeX/Y/Z` (would validate
   local-size — currently only caught as an opaque `zeKernelSetGroupSize` failure) and
   `subGroupSizes` (would validate a hardware profile's `:simd-width` against the device).

### Small corrections, cheap, easy to lose
7. ~~`src/hoist-l0/main.lisp:485-488` stale `zeDeviceGetComputeProperties` comment~~ **DONE
   2026-07-26** — corrected at source (comment-only, so no overlay was possible). It was the
   origin of the doc error and both bad specs.
8. **[DECLINED by user — "no big deal, just a rebuild from time to time"]**
   `build/build-{compiler,hoist-l0,hoist-cuda}.lisp` hardcode `bin/*.exe` in their
   delete-old-executable step regardless of platform, so every container build eats the host
   Windows binaries. One line each:
   `(format nil "bin/crisp-compile~a" (if (uiop:os-windows-p) ".exe" ""))`.
   User's call: "no big deal, just a rebuild from time to time."
9. `benchmarks/reduction/crisp/bench_harness_l0.cpp` — ~~printed `totalEUs × 8 × occupancy`
   while computing `totalEUs × occupancy`~~ **message DONE 2026-07-26**. STILL OPEN: its
   `baseGroups = totalEUs` heuristic disagrees with the corrected hoist formula by 2x
   (160 vs 80 max-resident groups at R=1.0); reconcile when (1) is settled.
10. **64M reduction data point** never completed (killed mid-run). User: don't worry about it.


---

## Phase 3 (2026-07-26) — :tile-shape inference + final BMG state

`:tile-shape` is now inferred from the `tile-stride` form (see the compiler overlay). Coverage
39/61; the remaining 22 use a tile-tensor spec — deferred item (5).

**Verification:** specs 933/933. All four BMG performance ratchets pass.

**benchmarks/REPORT.md regenerated, Intel BMG, fast/tf32 @1024:**

| Chapter | Crisp | oneMKL | % |
|---|---:|---:|---:|
| chap0_sync | 1.5 | 12.0 | 12.5% |
| chap1_async_linear | 0.8 | 12.0 | 6.6% |
| intel_prefetch | **10.4** | 12.0 | **86.5%** |

intel_prefetch is 150.7% of its own `sycl_apples.cpp` mirror. Its `:tile-shape` declaration was
REMOVED before this run, so the number is produced by inference — 10.36 vs 10.48 hand-declared,
i.e. equivalent. chap0/chap1 unchanged as predicted (mmts + their own hand-written harness).

**`performance/matmul-bmg` needs NO re-baseline.** It declares `(global-size :set-to 16)` with no
`:strategy`, uses `matrix-multiply-tile-stride`, and drives its own harness.cpp — three independent
reasons tonight's work can't touch it. Measured 890.7/891.5 µs vs an 868.6 baseline: a consistent
~2.5% drift, inside the 10% gate, and present across both runs rather than noise. Not investigated;
predates tonight as far as we can tell.

**Ratchet gotcha:** `device_compile_s` read 0.753 (FAIL, "206% regression") immediately after a
compiler rebuild, then 0.276 warm. It is process-startup dominated, so a freshly written 57 MB
.exe pays cold file cache + AV scan. Re-run warm before believing a compile-time regression. The
ratchet correctly did NOT record the bad value.


---

## Phase 4 (2026-07-26) — CUDA/H100: deferred items 1-4 resolved

**(4) `%cuda-emit-launch` HAS the same axis bug** — its `:strided` branch emits
`gridY = 1, gridZ = 1` and references `tile-shape` zero times, exactly as L0 did. Differences:
CUDA has NO units bug (`cuOccupancyMaxActiveBlocksPerMultiprocessor` x `numSMs` is dimensionally
correct and per-kernel register-aware), and the bug is MASKED for every benchmarked chapter by the
`--mma-bench` out-tile override above it (`gridX=ceil(M/tm), gridY=ceil(N/tn)`), which is why
chap1.5/2/3 numbers are sound. Same latent flaw in `:exact` + tensor derive-from (flat `_length`
/ tile-x, gridY=1). NOT YET FIXED — the L0 fix ports over nearly unchanged.

The out-tile override's comment ("gridX = row-tiles, gridY = col-tiles") independently confirms
**axis x <- dim 0**, now agreed by three sources: BMG measurement (1.31x), the hand-written L0
harness, and this.

**H100 limits: `maxGridDim X/Y/Z = 2147483647 / 65535 / 65535`.** Unlike BMG's uniform UINT32_MAX,
the Y/Z ceiling is REACHABLE — a 32-tile cover exceeds gridDimY at N ~ 2.1M. So the
strided-clamps / exact-errors guard has real teeth on NVIDIA, and axis assignment affects
reachability (whichever dim lands on Y hits its limit 32768x sooner).

**(1)(2)(3) `:occupancy` RESOLVED — no API change needed.** Both vendors want ~1.0; see
docs/ideal_001.md for both curves. The worry that occupancy is kernel x device and one scalar
can't serve both did NOT materialize, so no per-target values and no profile default.
`:occupancy 0.15` removed from BOTH sum-reduce.crisp copies AND from the hardcoded
`constexpr double OCCUPANCY` in `performance/reduction-bmg/harness.cpp` (it was duplicated in
three places).

**reduction-bmg re-baselined:** kernel_median_us 22.568 -> **5.928** (3.8x), throughput
174.8 -> **674.8 GB/s**. (>DRAM because a 1M-float reduction is 4 MB, L2-resident.)

**Pod note:** 12 spec failures on the pod are ALL `--ir-target=spv`, failing with `llvm-spirv`
exit 127 — the SPIRV-LLVM-Translator is a separate project, not part of `apt install llvm-21`, and
`run-on-pod.sh` also strips the repo's bundled `tools/llvm-spirv-linux`. Environmental, not a
regression; ALL CUDA specs passed. `run-on-pod.sh`'s header wrongly claims SPIR-V checks are
"skipped" — they run and fail.

### Deferred stack now
- (5) `matrix-multiply-tile-stride` tile-shape inference — 22 kernels. STILL OPEN, and now more
  attractive: do it together with the CUDA dispatch port below.
- (NEW) Port the tile-grid dispatch fix to `%cuda-emit-launch`, incl. the 65535 Y/Z clamp.
- (6) remaining zeDeviceGetComputeProperties validations (maxTotalGroupSize, subGroupSizes).
- (9-partial) `benchmarks/reduction/crisp/bench_harness_l0.cpp` `baseGroups = totalEUs` still
  disagrees ~2x with the corrected hoist formula (160 vs 80 groups at R=1.0). NOTE: 160 measured
  FASTER than 80 on BMG, i.e. oversubscription beat resident-capacity for the reduction too —
  same pattern as the tiled case. Worth revisiting what "max occupancy" should even mean.
