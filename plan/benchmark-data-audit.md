# What the result files do NOT record (and should)

Audit, 2026-08-20.  Every current `benchmarks/results/*.json` against what
`plan/mma-chapter-ladder.md` and `plan/benchmark-harness.md` need.  Measured over 239 result rows.

## The current schema

```json
{ "run_metadata": { "timestamp", "hardware": { "gpu_model", "arch_target", "environment" } },
  "benchmark_suite", "chapter", "competitor", "precision", "denormal_handling",
  "results": [ { "configuration": { m, n, k, warmup, iters },
                 "metrics": { "compile_time": {...}, "runtime": {...}, "throughput": {...} } } ] }
```

---

## Gaps, worst first

### 1. The correctness verdict is COMPUTED AND THEN DISCARDED

`matmul.py:283` sets `"correct": ("MMA_CORRECT" in out)` and line 195 uses it to *drop* a failing
row — but it never reaches the JSON.  **0 of 239 rows carry any correctness field.**

So the report cannot say "this number came from a kernel that was verified", and a dropped row and
a never-run row are indistinguishable after the fact.  For a document whose entire claim is
"measured, not asserted", that is the wrong thing to throw away.

### 2. `bandwidth_gbps` is NULL in all 239 rows

Declared in the schema, never populated.  Matmul is compute-bound so TFLOPS is the right metric —
but **the reduction suite is bandwidth-bound and TFLOPS is meaningless there**.  The field exists
and is dead; the next suite needs it alive.

### 3. Debug runs share a directory with real ones

`warmup`/`iters` are recorded but nothing declares which values are standard, so no tool can
filter.  Resolved in the harness doc by writing overridden runs to `benchmarks/results/scratch/`
rather than by adding a field — a directory needs no vocabulary and cannot be forgotten.

**A related axis this audit initially missed: COMMITTED vs FRESH.**  Because data is copied back
per device, a results directory holds a mixture of files from the repository and files from the
run just performed.  Nothing distinguishes them, so a report cannot say "H200's numbers are six
days old and came from a different Crisp SHA".  `run_metadata.timestamp` exists and would answer
this if it were rendered; `crisp_git_sha` (gap 7) is what makes it actionable.

### 4. The tile shape is passed and then dropped

`run_target(..., crisp_grid_tile="64,128")` reaches the auto-bench and never reaches the output.
**Chapter 4's entire finding is about tile shape** (+15.7% at 64×128, −7% at 64×256) and the tile
is not in the data that supports it.  Anyone re-reading those files cannot tell the two runs apart
except by chapter name.

### 5. Contender CLASS is inferred from name prefixes

`report.py` decides class with `_is_crisp()`, `startswith("CUBLAS")`, `"Apples" in name`.  The
three-class scheme (Ceiling / Peer / Control) makes this worse, not better: adding CUTLASS means
editing string predicates in two files, and `SYCL-TLA` will not match any existing pattern.

**Class should be a field on the row**, written by whoever declares the target.

### 6. Occupancy inputs are not recorded, though they are free

`ptxas -v` gives registers/thread and shared bytes at compile time.  We used them to explain the
cluster-of-four cliff — computed by hand, on a pod, after the fact:

| tile | regs | CTA/SM | resident |
|---|---|---|---|
| 64×256 | 165 | 2 | 264 |
| 64×128 | 96 | 4 | 528 |

That analysis is not reproducible from the committed data.  Recording `registers_per_thread` and
`shared_bytes` costs nothing at build time and makes every future occupancy argument checkable.

### 7. No reproducibility metadata

Missing: `cuda_version`, `driver_version`, `crisp_git_sha`, `sm_count`, `memory_gb`.

- **cuBLAS version matters enormously** to a ceiling number.  A ceiling that moved between runs is
  currently indistinguishable from a Crisp regression.
- **`memory_gb` is required** by the harness plan to compute per-device size caps.
- **`sm_count`** is needed for the residency-wave arithmetic in gap 6.
- **`crisp_git_sha`** is what lets "this number came from that compiler" ever be checked.

### 8. `kernel_execution_ms` is collected but never rendered

Not a collection gap — a presentation one, listed because it was nearly filed as the former.
Every row already carries `kernel_execution_ms`, and no table shows it.  TFLOPS is derived and
abstract; milliseconds are what a reader actually understands.  Cost to fix: rendering only.

### 9. `wall_time_ms` is 0 in 113 of 239 rows

Half populated.  Either fill it or drop it; a field that is sometimes real is worse than one that
is never real, because a reader cannot tell which.

### 10. Section and chapter ORDER live only in `report.py`

The ladder's headline ratio is **vs the previous chapter**, which requires an order.  That order is
a hardcoded Python list.  A result file cannot say where it sits, so the data cannot be
re-rendered by anything but that one script.

### 11. A MISSING size is indistinguishable from a size that was never configured

Found while restructuring the mock-up report to one table per chapter with rows = N.  Those tables
contain `n/a` cells for **three different reasons**, and the schema records none of them:

| why the cell is empty | example |
|---|---|
| too slow to be worth an iteration | matmul ch 0 at N=32768 — 14.7 s/iter |
| does not fit in device memory | Intel ch 7 at N=16384; reduction 4 G on BMG |
| the chapter is blocked / unimplemented | Intel ch 6, warp specialization |

A reader cannot tell "we measured this and it was hopeless" from "we never ran it" from "it cannot
run here" — and those are three completely different statements about the compiler.  The third is
arguably the most important row in an Intel table, and right now it is an absence.

Absence is not a measurement.  Each of these should be a **present row with a reason**:

```json
{ "configuration": { "m": 32768, "n": 32768, "k": 32768 },
  "skipped": { "reason": "time-budget", "detail": "14.7 s/iter exceeds 10 s cap" } }
```

with `reason` drawn from a closed set: `time-budget` | `device-memory` | `unimplemented` |
`failed-verification`.  The last one matters most: **a kernel that ran and gave a wrong answer must
never render as a blank cell**, which is what gap 1 currently allows.

---

## Proposed schema additions

```json
{
  "crisp_git_sha": "9bc20d4",
  "run_metadata": {
    "hardware": { "gpu_model", "arch_target", "environment",
                  "sm_count": 132, "memory_gb": 94,
                  "driver_version": "550.90", "toolkit_version": "12.4" }
  },
  "section": 1,
  "chapter": "ch5-several-fetches-in-flight",
  "chapter_index": 5,
  "competitor": "Crisp",
  "competitor_class": "crisp | ceiling | peer | control",
  "results": [{
    "skipped": null,
    "configuration": { "m","n","k","warmup","iters", "tile": "64,128" },
    "metrics": {
      "correctness": { "verified": true, "method": "host-reference", "verified_at_n": 2048 },
      "kernel": { "registers_per_thread": 96, "shared_bytes": 81920, "ctas_per_sm": 4 },
      "throughput": { "tflops": 190.7, "bandwidth_gbps": null }
    }
  }]
}
```

Cheap to add, all known at build or launch time: **1, 4, 5, 6, 7, 11**.
Rendering only, no new data: **8** (kernel ms), and the capture date in gap 3.
Needs a decision: **2** (which suites report bandwidth), **9** (fill `wall_time_ms` or delete it),
**10** (where chapter order lives).

Note there is no `canonical` field: gap 3 is solved by a directory, not by a flag.
