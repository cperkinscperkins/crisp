# Performance — Regression detection

This directory exists to answer the question:

> **Did the change I just made slow Crisp down?**

Different question from competitive comparison — see
[`../benchmarks/`](../benchmarks/) for that.

## Philosophy

- **Internal-facing.**  Numbers from here are for contributors and
  the build system.  They are not appropriate to share externally,
  and they don't tell a story about Crisp's competitive position.
- **No external reference required.**  A perf test compares Crisp
  to a stored *Crisp* number from a previous run.  There's no
  CUDA / SYCL / CUB version of the test.  The kernel can be
  artificial, microbench-scale, or specifically constructed to
  exercise one codegen path — none of which make sense in
  `benchmarks/`.
- **Fixed hardware.**  Cloud GPU rotation is fatal for regression
  detection.  Perf tests must run on a known machine.  Default
  target: **Intel BMG natively on Windows** (the dev machine),
  using the L0 / SPV path.  Native, not Docker — Crisp already
  runs on BMG without any container.
- **Ratchet baselines.**  Each test has a stored best-known time.
  When a run beats the baseline, the baseline lowers automatically.
  When a run is slower than the baseline by more than the threshold,
  the check fails.  No manual "update baseline" step on
  improvements; only on intentional regressions.

## Why ratchet over fixed baselines

Fixed baselines (commit the number, update it manually) work well
when there's a clear "official" target — e.g. "Crisp 1.0 ships at
X GB/s on Y GPU."  We're nowhere near 1.0.  Right now most weeks
contain at least one perf-improving change; manually bumping a
baseline file for every one is busywork.

The ratchet model is:

- `baseline.json` stores the lowest kernel time we've ever seen
  for each test
- A run that beats the baseline silently updates it
- A run that's >10% slower than the baseline fails the check
- The threshold is per-test (some tests are inherently noisier)

The risk of ratchet: if a noisy test happens to get a very fast
"lucky" run, the baseline gets set unreasonably low and subsequent
honest runs fail.  Mitigation: warmup + median-of-N reporting (we
already do this) + a reasonably generous regression threshold.

For Crisp 1.0 we'll snapshot then-current baselines as
`baseline-v1.0.json` (frozen, never ratcheted) and keep ratcheting
the live file.  That gives us "Crisp 1.0 reference" semantics
without giving up the developer ergonomics.

## Directory layout

```
performance/
  reduction-bmg/    Same kernel as benchmarks/reduction/crisp/, but
                    with an L0 harness producing JSON output suitable
                    for diffing.
  stride-suite/     (future) Microbenches for each stride macro
                    (loop-vector / tensor / grid / tile / hardware /
                    workgroup).  Detects regressions in the specific
                    codegen we worked on in endeavors 105/107/109/110.
  invariant-load/   (future) Microbench that re-reads input many times,
                    catches regressions in the read-only kernel-param
                    inference path.
  scratch-tensor/   (future) Microbench for local memory codegen.
  baseline.json     Ratcheted per-test best kernel times (committed).
  check.py          (future) Runs all tests, diffs vs baseline,
                    exits 1 on regression.
  README.md         This file.
```

Currently implemented: none — this is the framing commit.

## What goes in a perf test (vs a benchmark)

A perf test is welcome to be:

- **Tiny** — a 30-line kernel that exercises one feature.  Doesn't
  need to be a "real algorithm."
- **Synthetic** — adversarial inputs that stress one codegen path
  (e.g. a loop with no unroll-friendly trip count, just to make sure
  the unroll heuristic doesn't get worse).
- **Codegen-shaped** — measure something tied to a Crisp design
  choice (stride macro pattern, hoist app argument marshalling,
  shared-mem demotion) rather than to an algorithm choice.
- **Hardware-quirky** — measure something specific to BMG (e.g. SLM
  bank conflicts, EU occupancy under different launch sizes).
  These won't translate to NVIDIA and that's fine — perf tests
  don't need to.

A perf test should NOT be:

- A duplicate of a benchmark.  Exception: `reduction-bmg/` mirrors
  `benchmarks/reduction/crisp/` because reduction is a useful
  canonical kernel for *both* purposes.  The harness is different,
  the output is different, the role is different.
- Dependent on cloud hardware.  Perf tests run locally on BMG.
- A perf-vs-CUDA / perf-vs-SYCL test.  Those belong in
  `benchmarks/`.

## Adding a new perf test

1. Create `performance/<test-name>/`
2. Write the kernel: `<name>.crisp` (or copy from `benchmarks/`)
3. Write an L0 harness `harness.cpp` using
   `zeEventQueryKernelTimestamp` for timing, prints same JSON
   shape as the benchmark harnesses
4. Add an entry to `baseline.json` with an initial estimated
   threshold.  The first real run will set the actual baseline.
5. Register the test in `check.py`

## Running

Once `check.py` exists (TBD):

```
python performance/check.py             # run all, diff vs baseline
python performance/check.py --update    # ratchet baseline (only lowers)
python performance/check.py --test=reduction-bmg
```

Default behavior is "run and fail if regressed."  Manual update is
not normally needed because of ratchet; the `--update` flag exists
for cases where you intentionally improved a baseline and want
explicit visibility of the new number.
