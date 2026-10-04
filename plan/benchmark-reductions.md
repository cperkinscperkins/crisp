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
| **2** | Argument-plan writer + generic L0 fixture + `reduction.py`; sum f32 on BMG, verified; reproducibility check; the change-the-input probe. | a sum number we trust, plus a demonstrated catch of a stale-state run |
| **3** | Ladder (§1) + strategy rollup (§1b) on BMG; `report.py` renders them. | `REPORT-reduction.md` §1/§1b for BMG |
| **4** | Workloads + contenders (§2) on BMG: sum+sumsq, argmax, Welford (LSE, dot if they fit), SYCL/oneDPL/oneMKL, compile times. | §2 for BMG |
| **5** | CUDA fixture; H100 ladder, rollup and contenders (CUB, cuBLAS) in one batched pod session. | §1/§1b/§2 for H100 |
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
