# Benchmark harness — proposed reorganisation

Draft, 2026-08-20.  Companion to `plan/mma-chapter-ladder.md`: that document says what the
chapters *are*, this one says how they get *run*.  Nothing here is implemented yet.

---

## The four problems

1. **Two entry points that mix two axes.**  `bench-intel.sh` (Docker) and `bench-on-pod.sh`
   (RunPod) each know about *transport* AND *which suite*.  `bench-on-pod.sh` has grown to seven
   positional arguments plus a `--bench=` flag.
2. **Sizes, warmup and iters are passed by hand**, as positional slots 5/6/7.  A caller who
   forgets one silently produces numbers that look canonical and are not.
3. **Every benchmark runs all three precisions**, including tensor-core chapters where the flag
   changes nothing measurable.
4. **Fixed iteration counts** make large sizes cost N³ time, so "large" has been avoided rather
   than measured.

A fifth, discovered while sizing this document, turns out to be the binding one — see
*Verification does not scale*, below.

---

## 1. Precision: keep EXPLICIT, drop EXHAUSTIVE

These are two different properties and the current system conflates them.

> The reason none of us can remember the defaults is an excellent reason to **pass every flag on
> every run**.  It is not a reason to **run every combination**.

**Keep:** every invocation names `--math-precision=` and `--denormal-handling=` explicitly.  No
run ever depends on a default.

**Drop:** the automatic three-way sweep for chapters where the numerics do not depend on it.

`mma-accumulate-via-tile` lowers to **tf32 tensor cores — 10 mantissa bits — regardless of the
precision flag**.  The flags only touch the surrounding math.  The report already half-concedes
this: `MMA_CHAPTERS` are given a tf32 ceiling because an IEEE fp32 comparison would be
apples-to-oranges.  So a three-precision sweep on those chapters costs 3x the runtime to
re-measure the same kernel.

**But this is not "MMA never needs precision".**  Section 1 chapter 0 is *naive fp32 with no
tensor cores*, and there `ieee` vs `fast` genuinely changes the numerics.  Reductions are the same
— accumulation order and denormals matter a great deal.

**So the precision set is a property of the CHAPTER**, declared in its config:

| chapter kind | precisions |
|---|---|
| tensor-core (tf32) mainloop | `fast` only |
| scalar fp32 (ch 0), reductions | `fast`, `ieee`, `ieee+ftz` |

Whether a *correctness* run should still exercise all three is a separate question, and the answer
is yes — but that belongs in the spec suite, which already does it, not in the benchmark.

---

## 2. Sizes and counts: config, not arguments — and debug runs go elsewhere

> **Sizes, warmup and iteration counts are properties of the SUITE, defined in config.**  An
> override exists for debugging, and **an overridden run is written to
> `benchmarks/results/scratch/`**, which the report never reads.

### Why a directory and not a flag

An earlier draft proposed tagging overridden runs `"canonical": false` and having the report
filter them out.  That was the wrong mechanism, for a reason worth recording: **it required
explaining the word "canonical" twice and still did not land.**  A concept that needs a glossary
entry to keep results honest is a concept that will be forgotten at the moment it matters.

A separate directory needs no vocabulary.  The default glob cannot see scratch runs, so they
cannot leak into a table.  Promoting one to canonical means moving a file — which is a deliberate
act, and that is a feature.

The general principle is the one already applied to the compiler: **make the mistake unavailable
rather than detectable.**

### The failure this prevents

During endeavour 152 a run with `--sizes=1024,2048,4096 --warmup=5 --iters=30` deposited results
in `benchmarks/results/` that were **8-18% below house protocol**, size-dependent, and
indistinguishable from canonical data.  They were nearly reported as a headline; what caught them
was being asked for a report, not anything in the system.

The same directory produced two further contaminations that week — an H100 **PCIe** row averaged
into an H100 **NVL** table, and a **cuBLAS** run averaged in with a **Crisp** run because a query
did not filter competitor.  A fourth occurred later while verifying the mock-up report.  All four
were *a query that forgot a filter*.

This also removes the reason `bench-on-pod.sh` carries seven positional arguments.

## 3. Iterations from a TIME BUDGET, not a fixed count

Measure one iteration, then choose the counts:

```
warmup = clamp(3,  20, ceil( 50ms / measured_ms))
iters  = clamp(3, 100, ceil(500ms / measured_ms))
```

Small kernels still get 20/100 because noise needs averaging out.  Large kernels get 3/3 because a
280 ms kernel does not need 100 samples to be stable.  Cost per size becomes roughly constant
instead of growing as N³:

| N | ms/iter | warmup+iters | wall per kernel |
|---|---|---|---|
| 1024 | 0.01 | 20 + 100 | 0.02 s |
| 4096 | 0.55 | 20 + 100 | 0.07 s |
| 8192 | 4.4 | 12 + 100 | 0.5 s |
| 16384 | 35 | 3 + 15 | 0.6 s |
| 32768 | 281 | 3 + 3 | **1.7 s** |
| 40960 | 550 | 3 + 3 | **3.3 s** |

Under the current fixed 20/100, N=32768 alone would cost 34 s and N=40960 about 66 s — which is
why "large" has been avoided.  Under a budget the whole large bucket is a few seconds per kernel.

**This also removes the last honest reason to pass `--iters` by hand.**

---

## 4. How big is "large"?

### It is suite-specific, because the scaling is

- **Matmul**: memory grows as N², compute as N³.  Filling 80 GB needs N≈47000, where a single
  iteration is ~3.5 minutes.  **Bounded by time, not memory.**
- **Reduction**: O(N) work on O(N) data.  17 GB still runs in ~5 ms.  **Bounded by memory.**

Any single global definition of "large" is wrong for one of them.

### It is also DEVICE-specific

Largest N with three matrices at a 60% headroom factor:

| device | largest N |
|---|---|
| H100 / H200 80 GB | ~62000 |
| A100 40 GB | ~44000 |
| Intel BMG ~12 GB | ~23000 |

So the size list is **computed per device**, not hardcoded — the cap is the largest configured
size that fits.  A cross-device comparison is then only valid at sizes both devices ran, which the
report must respect rather than paper over.

### Proposed matmul buckets

| bucket | N | why this bucket exists |
|---|---|---|
| small | 512, 1024 | launch overhead and occupancy dominate; where warp specialization wins |
| medium | 2048, 4096 | the machine saturates (~0.97 residency waves at 2048 for the 64×128 tile) |
| large | 8192, 16384 | steady state |
| xl | 32768, 40960 | device permitting — and see below |

**Why xl earns its place, having first argued against it:** the ladder's central open question is
whether Crisp's 67% of cuBLAS *changes with size*.  At large N the kernel is more compute-bound and
less sensitive to wave quantisation, so the gap plausibly narrows — and that is exactly the regime
the industry cares about.  Under the time budget it costs seconds.  The earlier proposal to cap at
16384 was reasoning from the fixed-iteration scheme this document replaces.

---

## 5. Verification does not scale — and it is the actual ceiling

**This is the constraint that really blocks large sizes**, and it is not a benchmarking problem at
all.

The auto-bench validates MMA correctness with a **host reference matmul**:

| N | host reference work |
|---|---|
| 4096 | 137 GFLOP |
| 8192 | 1.1 TFLOP |
| 16384 | 8.8 TFLOP |

On a CPU that is minutes to hours.  It is why the chapter-2 probe crawled at 4096 during endeavour
152 — the GPU kernel took 36 ms and the verification took the rest.

**Correctness and performance are welded together and should not be.**  Proposed split:

- **Verify at a SMALL size** (`MMA_CORRECT` at N ≤ 2048, where a host reference is seconds).  A
  kernel that is correct at 1024 and 2048 is not going to become incorrect at 16384 for reasons a
  full reference would catch — the tile loops are the same code.
- **Benchmark at any size**, with no reference computation.
- **Optionally spot-check** a handful of output elements at large N — O(K) per element rather than
  O(N³) — to catch gross addressing errors.
- If a full large-N reference is ever wanted, it should be a **GPU** reference (cuBLAS), not a host
  loop.

Without this, sizes above ~8192 are unreachable no matter how the iteration counts are chosen.

---

## 6. Script structure: separate transport from suite

The two axes are independent and should stop being tangled:

| axis | values |
|---|---|
| **transport** — where it runs | local native, Docker (Intel), RunPod (NVIDIA) |
| **suite** — what runs | matmul, reduction, … |

Proposed shape:

```
scripts/bench.py --suite=matmul --target=pod --host=... [--devices=all]
scripts/bench.py --suite=reduction --target=docker
```

- **Transport scripts become thin** and know nothing about suites: provision, sync, build, invoke,
  collect.
- **Suite config carries** sizes, precision set, contenders, and which device class it runs on.
- Adding the reduction ladder later costs a **config file**, not a third script with its own
  positional arguments.

The reduction suite is not hypothetical — it is next after MMA, it will have its own ladder and its
own compete-with-the-top requirements, and it is bandwidth-bound where matmul is compute-bound.
Designing the harness around one suite again would guarantee a third rewrite.

---

## 7. Which devices, per section

From the ladder document, restated here because it is a harness concern:

| section | devices |
|---|---|
| §1 Techniques | **one representative per vendor** — a technique delta is a property of the technique, not the device |
| §2 Top Benchmarks | **every device available** — "how fast is Crisp on an H200" is the question |
| §3 Situational | one representative; these are controlled pairs |
| §4 Activation | follows §2 |

Which device is "representative" should be **written down** rather than being whichever pod was
available that day.

---

## Open questions

- Where does suite config live — Python module, or a data file the shell scripts can also read?
- Should `canonical: false` runs be written to a separate directory rather than tagged?  Tagging
  is less disruptive; a separate directory is harder to get wrong.
- Does the time budget need a per-suite override?  A bandwidth-bound reduction may want a longer
  measurement window than a compute-bound matmul.
- Is a cuBLAS-based GPU reference worth building for large-N verification, or is small-N
  verification plus spot-checks sufficient?  The latter is much cheaper and probably enough.
- BMG's exact memory should be **queried**, not assumed from a spec sheet, before it caps a size
  list.
