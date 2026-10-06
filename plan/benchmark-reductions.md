# Benchmarking Reductions — Plan

Drafted 2026-10-03, from Chris's opening notes (kept verbatim at the bottom) and the discussion
that followed.  Not an endeavour: benchmarking should not need compiler changes.  The one place
it does, the kernel's state across re-launches, is split out as endeavour 179
(`tests/spec/179-reduction-launch-state/`).

---

## 1. What the reduction suite has to show

1. **The ladder.** Steps from hand-written code to Crisp's language features, the same way the
   MMA ladder steps through techniques.  It exists to find **where the best strategy changes
   with size**, the way the MMA ladder found wgmma isn't always the best.
2. **The showcase.** Multi-variable reductions in **one pass over memory**: sum + sum-of-squares
   (independent), argmax and Welford (dependent).  A bandwidth-bound workload that reads memory
   once where a peer reads it twice should show up as ~2x.
3. **Compile time, in every table.**  Device-only, measured the same way as for MMA.  CUB is
   header templates throughout, so the gap should be at least as large as against CUTLASS.
4. **The ceiling is the memory bus, not a library.**  The headline metric is GB/s and
   **% of measured peak read bandwidth**.  The peak comes from a measured read-only stream
   kernel on each device, never from a spec sheet.

---

## 2. Workloads

| workload | kind | Crisp form | peer (NVIDIA / Intel) | top of line | priority |
|---|---|---|---|---|---|
| sum (f32, f64; bf16 in / f32 acc) | single | `grid-reduce!` / `reduce-vec` | CUB `DeviceReduce::Sum` / `sycl::reduction`, oneDPL `reduce` | measured bandwidth | **must** |
| sum + sum-of-squares | independent multi | one `grid-reduce!`, two clauses | CUB custom tuple op, or two passes / SYCL with two reducers in one kernel | measured bandwidth | **must — showcase** |
| argmax | dependent multi | `grid-reduce!` with a combiner | CUB `DeviceReduce::ArgMax` / oneDPL `max_element` | cuBLAS/oneMKL `i?amax` (on \|x\|, so near but not exact) | **must** |
| Welford (count, mean, M2) | dependent multi | `grid-reduce!` with a combiner | CUB custom op on a struct / SYCL custom combiner | none: hand-written | **must** |
| log-sum-exp (max, sum-exp) | dependent multi | combiner | CUB custom op | none | candidate |
| dot (two inputs) | single | `grid-reduce!` | — | cuBLAS / oneMKL `dot` | candidate |

**Be honest about SYCL:** `sycl::reduction` can take several reducers in one `parallel_for`, so
SYCL is a one-pass peer for sum + sum-of-squares.  It belongs in the table, and the claim
against it is ergonomics and compile time, not bandwidth.  The 2x bandwidth claim is against
CUB used naively, and should be worded that way.

`reduce-vec` gets **one row**, not a ladder.  It expands to `grid-reduce!`, so the claim is "the
one-liner costs nothing": one comparison against the matching `grid-reduce!` step, which should
be identical.

Autodiff (the gradient of a reduction is a broadcast) is out of scope.  It may come later.

---

## 3. Report shape

`benchmarks/REPORT.md` becomes a short **index**: one headline table per suite plus provenance.
The detail moves to `benchmarks/REPORT-matmul.md` (today's content) and
`benchmarks/REPORT-reduction.md`.  `report.py` already groups results by `benchmark_suite`, so
this mostly means writing separate output files.

### § 1 — Reduction Ladder  (sum f32 · one device per vendor)

| # | step | what it adds | apples (.cu / .cpp) |
|---|---|---|---|
| 0 | one atomic per element | baseline | yes |
| 1 | hand-written shared-memory tree | in-workgroup combine | yes |
| 2 | + hand-written warp shuffle | registers, not shared memory | yes |
| 3 | + grid-stride, `:occupancy` | several elements per thread (≈ today's `sum-reduce.crisp`) | yes |
| 4 | `grid-reduce!` (default `:last-man-standing`) | the language does Phase 1 + 2 | the CUDA "threadFenceReduction" last-block pattern |
| 5 | `reduce-vec` | the one-liner | — |

Rows are steps, columns are sizes, and the cell is GB/s (% of peak).  Same rollup-plus-detail
layout as the MMA chapters.

### § 1b — Strategy Rollup  (sum f32 · same devices)

Rows are the 8 combinations of Phase 1 {`reduce-warp`, `reduce-workgroup`} × Phase 2
{`:atomic`, `:cas`, `:last-man-standing`, second-stage}.  Columns are sizes, with the **winner in
each column in bold**.  This is where a size crossover shows up.  Per-thread accumulation
(Phase 0) stays fixed here and only varies on the ladder.

The strategy rules keep this from growing into an N-dimensional matrix.  `:atomic` handles only
`+`/`min`/`max`, and dependent reductions only support last-man.  So only sum (and the independent
sum + sum-of-squares) has a strategy choice to show.  Argmax, Welford and LSE get no rollup.

**Reproducibility column:** run twice and compare the bits.  Float atomics give different
answers from run to run; last-man and second-stage should be reproducible.  It costs one extra
launch, and matmul never had this axis.

### § 2 — Contenders  (every workload · every device available)

Each workload at the default strategy: Crisp vs peer vs top of line (where one exists), GB/s,
% of peak, **device compile time**.

---

## 4. Harness

### Driver
New `scripts/crisp_bench/reduction.py`, alongside `matmul.py`, reached through
`scripts/bench.py --suite=reduction`.  `matmul.py` is not generalised.  Helpers move into
`harness.py` only when reduction.py actually needs them (`time_compile`,
`run_bench_proc`, `SizePacer`, the VRAM query).

### Fixtures, driven by the metacrisp
No hoist changes for benchmarking.  One **generic fixture per backend** (L0 C++, CUDA) for
every reduction kernel.

- **Python** reads the metacrisp (`:physical-signature`, `:declared-signature`,
  `:implicit-params` with `:size-expr`, `:records` for the tensor expansion) and writes a flat
  **argument plan**: one entry per physical slot, in order.  Python also resolves the symbolic
  sizes (`:match-num-warps-per-workgroup`, the per-workgroup partials, …).
- **C++** reads the plan, allocates and binds the arguments, initialises each one **before every
  timed launch** as the plan says, times the launches, and writes the output cells to a file.
  It never parses s-expressions.
- **Python** checks the outputs against an fp64 numpy reference.  Workload-specific checks
  live here, so the fixture never changes per workload.

Argument plan sketch (format to be settled in Phase 2):

```json
{ "kernel": "grid_sum", "local": [256,1,1], "groups": [80,1,1],
  "args": [
    {"slot": 0, "kind": "local",  "bytes": 32},
    {"slot": 1, "kind": "tensor", "role": "input",  "elem": "f32", "n": 268435456, "init": "data"},
    {"slot": 7, "kind": "cell",   "role": "output", "elem": "f32", "init": {"per_launch": "identity", "value": 0.0}},
    {"slot": 13,"kind": "cell",   "role": "scratch","elem": "u32", "init": {"per_launch": "zero"}}
  ] }
```

Python can only fill in `init.per_launch` if the metacrisp says which arguments need it.
That is endeavour 179.

### Measurement hazards specific to reductions
1. **State left over between launches.** last-man's ticket counter never resets (BUG 084 hit
   it in VERIFY-AUTODIFF).  `:atomic`/`:cas` accumulate into the output cell.  Without a reset,
   later iterations are **fast and wrong**, and checking the final output does not catch it
   (last-man's stale result is still the correct answer from launch 1).  Verify on the last
   timed launch, and have one probe that changes the input between launches and expects the
   new answer.
2. **Cache.** H100 L2 ≈ 50 MB; BMG L2 = 18 MB (`:L2-CACHE-SIZE` in its profile).  Sizes that fit
   in L2 measure the cache on repeated runs.  Treat them as a separate **latency** group,
   reported as time per launch, not GB/s.
3. **Small sizes matter on purpose.** Launch overhead dominates there, which is where one-pass
   last-man should beat a two-kernel library.
4. **L0 timing.** Check that the coalesced re-submit timing bug from the MMA work cannot affect
   the new fixture (memory: `l0-mma-bench-timing-bug`).
5. **Intel runs in Docker**, as for MMA.

### Sizes
Grouped by **bytes**: latency (fits in L2), bandwidth (64 MB – 1 GB), capacity (a large fraction
of queried VRAM).  The exact lists live in `reduction.py`, not in shell scripts.

---

## 5. Devices

- §1 / §1b: one representative device per vendor: **BMG** and **H100**.
- §2: every device available; in practice BMG and H100.
- **Optional H200 run** at the end.  It has about the same compute as H100 but ~40% more
  bandwidth (HBM3e), so it directly tests whether Crisp's "% of peak" stays the same on a faster
  bus.  That says more for reductions than it did for MMA.  Only worth doing if a pod is cheap.

Pod sessions follow the CLAUDE.md rules: one batched script, results written on the pod, compact
JSON pulled back.  Before asking for a pod, say what will run and what would make the rental a
waste.

---

## 6. Phases

| phase | work | exit check |
|---|---|---|
| **0** ✅ 2026-10-03 (deletions await Chris) | Housekeeping.  Check `plan/intel-bench-modernize.md`, `plan/benchmark-data-audit.md`, `plan/dummy-report.md` for open items (findings to `put_temp_files_here/`); Chris decides delete or archive.  Retire `benchmarks/reduction/run.py`; keep the hand-written kernel and the CUB/SYCL sources as starting points.  Measured read-bandwidth kernel on BMG. | a measured BMG peak in GB/s |
| **1** | **Endeavour 179**: kernel state across re-launches (self-reset and/or metacrisp init annotations). | its own spec dir |
| **2** ✅ 2026-10-03 | Argument-plan writer + generic L0 fixture + `reduction.py`; sum f32 on BMG, verified; reproducibility check; the change-the-input probe. | a sum number we trust, plus a demonstrated catch of a stale-state run |
| **3** ✅ 2026-10-03 (BMG; second-stage pending a 2-kernel plan) | Ladder (§1) + strategy rollup (§1b) on BMG; `report.py` renders them. | `REPORT-reduction.md` §1/§1b for BMG |
| **4** ✅ 2026-10-05 (BMG; small-size timing parity open; LSE/dot not done) | Workloads + contenders (§2) on BMG: sum+sumsq, argmax, Welford (LSE, dot if they fit), SYCL/oneDPL/oneMKL, compile times. | §2 for BMG |
| **5** ✅ 2026-10-06 (H100 NVL; ladder, rollup, workloads, CUB/Thrust/cuBLAS) | CUDA fixture; H100 ladder, rollup and contenders (CUB, cuBLAS) in one batched pod session. | §1/§1b/§2 for H100 |
| **6** | Report split: index + `REPORT-matmul.md` + `REPORT-reduction.md`.  Can be done any time after phase 3. | — |

Phases 2–4 are local (BMG in Docker), so nothing waits for a pod until phase 5.

---

### Result schema: what reduction JSON must record (from the phase 0 audit)

`put_temp_files_here/bench-phase0/plan-audit.md` checked `plan/benchmark-data-audit.md` against
today's result files.  Still open, and things the reduction suite cannot do without:

- **`bandwidth_gbps` filled in** (NULL in every matmul row; it is the reduction headline).
- **Contender class as a field** (crisp / control / peer / top), not inferred from name prefixes.
- **Dispatch recorded**: groups, local size, the `:occupancy` factor; these are the reduction's
  own variables.
- **A missing size recorded as missing** (clamped by VRAM), not silently absent.

### Measured ceilings

| device | env | peak read (median) | best config | source |
|---|---|---|---|---|
| BMG (Arc B580, `0xe20b`), driver 1.15.39122 | Docker | **454.5 GB/s** (3 GB); 453.6 (1 GB), 449.9 (256 MB) | `float4`, wg 256, 160 groups (= SYCL's 160 compute units) | `benchmarks/results/ceiling_intel_hash_1791074983.json`, 2026-10-03 |

- Spec sheet is 456 GB/s, so the measured read peak is 99.7% of it.  It is verified, not
  assumed: every timed launch's partials must sum to the host's total of the input.
- **The data pattern does not matter on BMG.**  All-1.0f (compressible) and scattered small
  integers (`--pattern=hash`) gave the same medians.  Hash is the default anyway, so a future
  device with compression can't flatter the ceiling.
- 16 MB (fits in the 18.9 MB L2) reads at ~860 GB/s: the latency/cache group really is a
  different regime.
- 4 GB was skipped (over a third of the 12.5 GB device); 3 GB is the largest size measured.
- Probe: `benchmarks/reduction/ceiling/read_bw.cpp`; runner: `scripts/bench-ceiling-intel.sh`.
  H100 needs a CUDA twin in phase 5.

### Phase 2 as built (2026-10-03)

| piece | file |
|---|---|
| metacrisp reader + argument-plan writer | `scripts/crisp_bench/metacrisp.py` |
| generic L0 fixture | `benchmarks/reduction/fixture/reduce_fixture_l0.cpp` |
| driver | `scripts/crisp_bench/reduction.py` (via `bench.py --suite=reduction`, or `CRISP_BENCH_SUITE=reduction scripts/bench-intel.sh`) |
| kernels | `benchmarks/reduction/step4_grid_reduce/{sum,sum_atomic}.crisp`, declaring `BENCH-WORKLOAD` / `BENCH-EXPECT` |

Decisions made while building it:
- **The plan is text, not JSON**, so the C++ fixture needs no parser beyond `istringstream`.
- **The ABI comes from the parameter TYPE**, not the `:physical-signature` labels.  The labels
  for implicit cells read `(ULONG VOIDP ULONG)` where the runtime binds `(ptr, byte_size, offset)`.
  That's probably a metadata bug; not fixed.
- **Outputs are POISONED (NaN) before every launch** unless their `:launch-init` names an
  identity.  A last-man output the kernel never wrote is then NaN, not a stale-but-plausible
  number.
- **Every run verifies TWICE**: the last timed launch (input A), then a relaunch on different
  data (input B).  The reference comes from the fixture's own double-precision input statistics,
  so the Docker image doesn't need numpy.
- **Device compile time = `crisp-compile` → SPIR-V**, matching what the SYCL contenders' device-only
  compile measures; the driver JIT is recorded separately (`jit_ms`).
- `--stale-demo` proves the harness catches stale state.  Both cases are CAUGHT: `:atomic`
  without its per-launch identity gives ~13× the sum; last-man with a dirtied counter gives NaN.

First numbers (BMG, Docker, `fast`, 160 groups × 256, scratch): both strategies plateau at
**~261 GB/s = 57% of the measured peak** from 64 MiB up.  The SYCL ceiling probe with the same
scalar loads and geometry reaches 437 GB/s, so the gap is in the per-thread loop, not Phase 2.
Leading theory: no unrolling, so too few loads in flight at 1/8 occupancy.  That's ladder step 3's
question; test it in phase 3.  At 1 MiB the strategies differ: `:atomic` 5.6 µs vs last-man 13.6 µs.
Native Windows runs are ~1.5× slower (175 GB/s); use them for correctness only.

### Phase 3 results (2026-10-03, BMG, Docker, `fast`) -- `benchmarks/REPORT-reduction.md`

Ladder (GB/s at 1 GiB, % of 454.5 measured peak; max relative error):

| step | | 1 GiB | rel err |
|---|---|---|---|
| 0 | one atomic per element | 2.3 (0.5%) at ≤64 MiB, larger skipped | 3e-3 |
| 1 | SLM tree, 1 atomic/group (per element) | 44 (10%) | 5e-4 |
| 2 | warp shuffles, 1 atomic/group (per element) | 54 (12%) | 4e-4 |
| 3 | + grid-stride | 262 (58%) | 3e-7 |
| 3b | + unrolled ×4 (hand) | **453 (100%)** | 4e-7 |
| 4 | `grid-reduce!` (last-man / atomic) | 260 / 262 (57-58%) | 2e-8 / 3e-7 |
| 5 | `reduce-vec` | 261 (57%), = step 4 | 2e-8 |

**The finding: the stride loop needs loads in flight, and Crisp's stride loop has one.**
- The shipped SPIR-V (`llvm-spirv -r`) has ONE global load per `loop-vector-stride` trip: `default<O3>`
  does not unroll it for the SPIR-V target.
- More work-groups do not help (640 and 1280 groups are no faster than 160).  160 × 256 already
  fills the hardware threads: SYCL's 160 "compute units" are EUs, not Xe-cores (an earlier "1/8
  occupied" guess was wrong).  The only lever left is loads in flight PER THREAD.
- Unrolling ×4 into ONE accumulator, additions in the original order
  (`_probe_loop/c_unroll_one_acc`), is exactly as fast as four accumulators: 452.4 vs 452.5 GB/s.
  **So the fix needs no reassociation and gives bit-identical results.**
- Walking the index by addition instead of `gid + k*gsize` (a 64-bit multiply) is worth ~6% alone
  (`_probe_loop/a_add_index`).
- This caps every `loop-vector-stride` / `reduce-vec` / `grid-reduce!`-after-a-stride-fold kernel
  at ~57% of peak on BMG.  **Compiler decision for Chris** (options in the session notes:
  `llvm.loop.unroll.count` on the stride loop, runtime unrolling in the SPIR-V opt pipeline, or
  unrolling in the expansion itself).

Strategy rollup (median µs; `:atomic` is fastest at every size):
- `:last-man-standing` costs a fixed ~8 µs more than `:atomic` (13.6 vs 5.7 µs at 1 MiB), lost in
  the noise from 64 MiB up.  It is ~15× more accurate (rel err 2e-8 vs 3e-7): partials are summed
  in one tree, not by 160 atomic adds in arbitrary order.
- **`:cas` has a ~2.2 ms floor** (2237 µs at 1 MiB, for 160 CAS operations ≈ 14 µs each, serialised);
  per-warp CAS (2560 operations) ~8.2 ms.  Far beyond normal contention; suspect the
  `atomic-binop!` lowering on BMG.  Not investigated yet.
- Per-warp atomics (no work-group barrier) are slower than per-group: 21 vs 5.7 µs at 1 MiB.

Accuracy is a reduction result in its own right: an fp32 cell taking millions of atomic adds is off
by up to 3e-3.  Verification tolerance is therefore 1e-4 by default (catches one missing
contribution in 2560), with an explicit, commented `BENCH-RTOL: 1e-2` on the per-element steps;
the measured error is always reported.

### Phase 5 prepared (2026-10-03) -- NVIDIA, not yet run

- `benchmarks/reduction/fixture/reduce_fixture_cuda.cpp`: the CUDA twin, same plan, same results
  format.  Local scratch slots carry BYTE OFFSETS into one dynamic shared block (as
  crisp-hoist-cuda emits -- checked against its output); CUDA-event timing; `groups eu` = SMs.
- `benchmarks/reduction/ceiling/read_bw.cu`: the CUDA twin of the ceiling probe.
- `reduction.py --platform=nvidia`: PTX + the CUDA fixture.  The plan's module line is now
  `module` (the L0 fixture accepts the old `spv` too).
- Compile-checked locally in `nvidia/cuda:12.4.1-devel-ubuntu22.04`: both build (`-Wall`
  clean); all 21 reduction kernels compile to PTX and assemble with `ptxas -arch=sm_90`.
- `bench-on-pod.sh --bench=reduction`: ceiling -> stale demo (fatal if not caught) -> sweep ->
  `_probe_unroll` to scratch.  Not run on hardware yet.

### Phase 5 first run -- H100 80GB HBM3 (2026-10-04, RunPod)

All points verified; the stale demo CAUGHT both cases on CUDA.  Ceiling **3103.1 GB/s** measured
(92.6% of the 3350 spec; `ceiling_nvidia_hash_1791156465.json`).

**On NVIDIA the first lever is GRID SIZE, not unrolling.**  `groups eu` = 1 block per SM =
1/8 occupancy on H100 (on BMG, 160 "compute units" x 256 already filled the device).  The canonical
H100 results (`results_NVIDIA_H100_*`) were taken at 132 groups and are occupancy-starved -- do
not read them as Crisp's H100 performance.  The follow-up (scratch, 4 GiB):

| kernel | 132 groups | follow-up |
|---|---|---|
| `grid-reduce! :atomic` | 24% | **92.9%** at 1056 (8 blocks/SM) |
| step 3b (hand unroll) | 49% | **95.0%** at 1056 |
| step 3 (hand SLM tree) | 12% | 76% at 1056 |
| per-warp atomics | 28% | 79% at 1056 |
| last-man / `reduce-vec` | 28% | **50.8%** at 256 (its cap) |

- **Last-man is structurally capped on NVIDIA**: groups <= local size (256) means at most ~2
  blocks/SM.  A 1024-wide local size would allow 1024 groups.  Design question.
- The PTX path ALREADY unrolls the stride loop (LLVM NVPTX x4, then ptxas -> 16 loads/trip) and
  strength-reduces the index: endeavour 180's unroll gap is SPIR-V-specific.
- Open puzzles: step 3 vs step 4 (identical Phase-0 SASS, 76% vs 93% at full occupancy); last-man
  step 4 (50.8%) vs the hand x4 probe (86.5%) at the same 256 groups.
- `:cas` floor ~1.4 ms per work-group / ~4 ms per warp on H100 too: slow on BOTH vendors, so
  suspect Crisp's `atomic-binop!` lowering, not the hardware.

### Phase 5 results -- H100 NVL (2026-10-06, RunPod) -- `REPORT-reduction.md`

Ceiling **3702.3 GB/s** measured.  Stale demo CAUGHT both; 165 points, all verified.  Grid from
the occupancy policy (132 SMs x 8 = 1056 resident at local 256).  % of peak at 4 GiB; device
compile (source -> PTX):

| workload | Crisp | CUB | Thrust | cuBLAS |
|---|---|---|---|---|
| sum | 42% · 0.19 s | 101% · 2.6 s | 87% · 3.5 s | 64% (asum) · 1.2 s |
| sum + sumsq | 33% · 0.23 s | 100% · 2.3 s | 87% · 2.3 s | 35% (2 passes) · 1.0 s |
| argmax | 52% · 0.24 s | 98% · 3.7 s | 57% · 3.9 s | 70% (isamax) · 1.0 s |
| Welford | 40% · 0.26 s | 69% · 2.2 s | 70% · 2.8 s | -- |

- **Crisp's language forms here are all last-man** (the `grid-reduce!`/`reduce-vec` default, and
  the ONLY strategy for dependent reductions), and last-man is capped at groups <= local size (256)
  -- a quarter of the 1056 resident groups.  That cap is the whole gap: the same sum with
  `:strategy :atomic` reaches **91%** (ladder step 4 atomic), hand-unrolled step 3b 96%.
- **Fix candidate (compiler):** let last-man's final sweep loop over the partials in chunks of the
  local size (a strided sweep in the elected work-group) instead of requiring one partial per
  thread.  That removes the cap, so last-man can use the full occupancy grid.
- **Compile: Crisp 0.19-0.26 s vs CUB 2.2-3.7 s and Thrust 2.3-3.9 s (10-15x); cuBLAS 1.0-1.2 s**
  (its calls are thin API calls over a precompiled library).
- Small sizes ARE comparable on NVIDIA (event-timed both sides): at 1 MiB everyone is launch-bound
  (Crisp 99, CUB 126, cuBLAS 98 GB/s for sum).
- One-pass multi-variable: Crisp's sum+sumsq is level with cuBLAS's two calls today (33% vs 35%);
  CUB's one-pass `TransformInputIterator` reaches 100%.  The last-man fix is the lever.

### Phase 5 completion -- prepared 2026-10-06, needs one pod session

- NVIDIA contenders: `benchmarks/reduction/contenders/nvidia/<lib>__<workload>.cu` + `common.cuh`
  -- CUB (`DeviceReduce::Sum`, `Reduce` over a `TransformInputIterator` for sum+sumsq and Welford,
  `ArgMax`), Thrust (`reduce`, `transform_reduce`, `max_element`), cuBLAS (`Sasum`, `Sasum`+`Sdot`,
  `Isamax` 1-based -> 0-based; device pointer mode so calls stay async).
- **Timed by CUDA events on the stream**, which bracket every kernel a library launches: like for
  like with Crisp's CUDA fixture, so NVIDIA small sizes ARE comparable (Thrust adds its small host
  copy-back; recorded per point).  Device compile = `nvcc -ptx`.  Built with `-arch=native`.
- All 11 build and the 4 workload kernels' PTX assembles (`ptxas -arch=sm_90`) in the local
  `nvidia/cuda:12.4.1-devel` image.  `bench-on-pod.sh --bench=reduction` now runs ceiling ->
  stale demo -> ladder/rollup/workloads (occupancy policy) -> contenders.

### Phase 4 results -- BMG, Docker, `fast` (2026-10-05) -- `REPORT-reduction.md` §2

Kernels: `benchmarks/reduction/workloads/{sum,sum_sumsq,argmax,welford}.crisp` (language forms).
Contenders: `benchmarks/reduction/contenders/intel/<lib>__<workload>.cpp` + `common.hpp` (same
data, same A/B verification, same results format), via `reduction.py --contenders`.  All verified.

% of the 454.5 GB/s measured peak at 3 GiB; device compile (source -> SPIR-V):

| workload | Crisp | SYCL reduction | oneDPL | oneMKL |
|---|---|---|---|---|
| sum | 58% · 0.57 s | 94% · 1.9 s | 96% · 2.9 s | 94% (asum) · 2.6 s |
| sum + sumsq | 58% · 0.58 s | 94% (2 reducers, 1 pass) · 2.0 s | 95% (1 pass) · 3.0 s | **48% (2 passes)** · 2.7 s |
| argmax | 57% · 0.62 s | 89% · 1.9 s | 95% · 3.3 s | **38% (iamax)** · 2.5 s |
| Welford | 56% · 0.62 s | 92% · 1.9 s | 96% · 3.0 s | -- |

- **At large sizes every peer is at 89-96% and Crisp at 56-58%: the SPIR-V stride-loop gap
  (endeavour 180) is the whole difference.**  Probe 2 measured `reduce-vec` at 98.4% with the unroll
  hint, so after 180 Crisp should be on par with the peers, at 3-5x less compile time.
- **Compile time: Crisp 0.57-0.62 s vs 1.85-3.3 s device-only for the contenders (3-5.5x).**
- One-pass multi-variable vs a two-call BLAS: Crisp's sum+sumsq beats oneMKL's asum+dot today (58%
  vs 48%), and would be ~2x after 180.  SYCL and oneDPL also do it in one pass -- the claim against
  them is compile time and expression, not bandwidth.
- oneMKL `iamax` is slow on BMG (38%): a one-pass argmax in any of the others beats it 1.5-2.5x.
- **Small sizes are not comparable yet**: contenders are host-clock timed and the WSL L0 submission
  overhead (an empty `single_task`) measured 63-296 µs and noisy -- it swamps 1-64 MiB.  Crisp's
  1 MiB times (8-12 µs kernel) are not a fair win.  Fix candidates: event-profiled timing where a
  library returns one event (SYCL reduction, oneMKL), or host-clock timing of Crisp too.

### Dispatch policy (2026-10-05): the hoist's own formula, queried, not a table

The fixtures now launch what a real Crisp host would: for a `:strided` kernel,
`groups = R x max_resident_workgroups`, with the denominator QUERIED exactly as the hoists do
(CUDA `cuOccupancyMaxActiveBlocksPerMultiprocessor` x SMs; L0 hardware threads, halved on spill,
divided by `ceil(local / SIMD width)`; the profile's `:compute-units` replaces the device's own
count when present).  R is the kernel's declared `:occupancy` (default 1.0, as in the hoist), or
`reduction.py --occupancy` for sweeps.  Last-man kernels are capped at their local size.  Order:
`--groups` > `BENCH-GROUPS` > occupancy > `eu`.  Plan syntax: `groups occupancy R [cap=N] [cu=N]`.

Why no per-vendor or per-platform table: the BMG's "160 = one group per EU" was R=2 x 80 by
coincidence, and the H100's 1056 is R=1 x (8 per SM x 132).  A queried denominator is right on day
one for any RunPod part, or for Crescent Island.

**R sweep on BMG** (Docker, scratch; max_resident = 80 at local size 256):
- 1 GiB: R=0.5 collapses to 28% for every non-unrolled kernel; R >= 1 all ~58% (Phase 0 bound);
  step 3b ~99% for R >= 1.
- 1 MiB: atomic-heavy kernels prefer FEWER groups -- per-warp atomics 8.1 µs at R=0.5 vs 43 µs at
  R=4; `:atomic` is best at R=1 (4.3 µs).
- **R=1 is the best or tied single value at every size** (and is what gave 93% on H100).  A small-size
  refinement would have to depend on the size; a constant can't do it.
- Last-man DEGRADES with more groups (46% at 256 vs 58% at 80) where `:atomic` at 320 does not.
- Endeavour 143's "R=2 optimal for sum_reduce" does not reproduce for these kernels (R=2 ties large,
  loses small): consistent with its own note that the optimum is per kernel.

The canonical H100 rows (`results_NVIDIA_H100_*`, 132 groups) predate this policy and are STALE:
re-run at the next pod session.

### Carried forward from endeavour 143

- **"What should max occupancy mean?"** (143's deferred #3).  For grid-stride kernels the optimum
  kept landing at or beyond the largest grid the API can express.  The ladder's grid-stride step
  should sweep the grid size rather than trust one occupancy formula.  The phase 0 ceiling probe
  sweeps it too (multiples of the compute units, plus one work-item per element).
- 143's deferred #2: `bench_harness_l0.cpp` sizes its grid as `totalEUs`, ~2x off the hoist's
  formula.  Don't copy that sizing into the reduction fixture.

## 7. Open questions

- Argument-plan format: JSON next to the metacrisp, or env vars like `l0_fixture_env`?  JSON
  seems the only sane option for a variable number of arguments.
- Does the ladder's step 4 compare against a hand-written last-block CUDA/SYCL kernel, or does
  that step only compare with itself?
- bf16 input / f32 accumulator: is this a Crisp kernel we can write today, or does it need a
  conversion in the loop that the ladder steps don't have?
- How many sizes per group, keeping pod minutes in mind?

---

## Appendix — Chris's opening notes (2026-10-03, verbatim)

The benchmark system has been worked and reworked quite a bit.  In ./benchmarks/reduction we have our original benchmarking code for benchmarking ersatz reductions.  I'm not sure there is much to be preserved there and we'll likely be replacing it entirely.

The Benchmark System
=====================

The benchmarking we have now was mostly developed for the MMA benchmarks. There are interesting things about those:

- they have an "MMA Techniques" section where a ladder of MMA techniques are benchmarked against one another (on Intel and on NVidia). This allows us to see the relative advantage of using shared memory, tensor maps, pipelining, warp specialization, prefetch and more.
- The "Techniques" section also compares .crisp against  .cpp(SYCL)/.cu(CUDA) using the same technique so we can detect diversions there.
- Then there is teh section of "contenders". For MMA this was SYCL/CUDA, SYCL-TLA/CUTLASS (peer), and OneMKL/CuBLAS (top of line).
- Across lots of sizes. Lots of data types ( fp32, fp62, bf16, fp16 )
- Compile time ( of device code, less interested in total) is very important to hightlight, because Crisp is MUCH faster than others ( ~33x faster than CUTLASS )
- We don't have dedicated machines for benchmarking, so tests are run on the machinery we have and collected in .json files and then collated to develop REPORT.md
- Even for BMG (which we do have locally), we still use Docker for all because we don't have OneAPI excpet via Docker.
- scripts/bench-intel.sh  & scripts/bench-on-pod.sh are the main entrypoints, with
  scripts/pull-runpod-results.sh and scripts/crisp_bench/report.py  assisting to developt the report.

Benchmark Observations
=====================
- Over time we've accreted some other benchmark things. Other scripts, descriptions of work to be done (and probably already done) under ./plan  .  Maybe these should be deleted.
- Adding reductions to the report will likely mean its own "ladder" , plus a section comparing "peers" and "optimal".
- Probably REPORT.md is going to have to be broken out into new sections or possibly sub-documents.
- the interface for the scripts might have to change, rather than assuming everything is always benching MMA. Not sure.
- We'll need to choose a good set of reductions. Crisp supports multi-variable reductions, including dependent and independent. So we should plan on benching some of those
- Is reduce-vec worth benchmarking? It's pretty handy.
