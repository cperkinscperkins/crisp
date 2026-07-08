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
  matmul-bmg/       Chapter-0 synchronous SLM-staged tiled matmul
                    (single sub-group, 8x16 tile, large K).  Runtime is
                    dominated by the K-loop's sync staging — the floor the
                    MMA "chapters" (async / pipelined / warp-specialized)
                    will improve on.  Needs --hardware-profile=bmg (per-test
                    compile_flags in check.py).
  stride-suite/     (future) Microbenches for each stride macro
                    (loop-vector / tensor / grid / tile / hardware /
                    workgroup).  Detects regressions in the specific
                    codegen we worked on in endeavors 105/107/109/110.
  invariant-load/   (future) Microbench that re-reads input many times,
                    catches regressions in the read-only kernel-param
                    inference path.
  scratch-tensor/   (future) Microbench for local memory codegen.
  baseline.json     Ratcheted per-test best kernel times (committed).
  check.py          Runs all tests, diffs vs baseline, ratchets on
                    improvement, exits 1 on regression.
  README.md         This file.
```

Currently implemented: `reduction-bmg`, `vec-copy-bmg`, `matmul-bmg`.

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
   `zeEventQueryKernelTimestamp` for timing, printing a compact JSON
   of the metrics (e.g. `kernel_median_us`, `throughput_gb_s` or
   `gflops`). `device_compile_s` is added by `check.py` itself.
4. Register the test in `check.py`'s `TESTS` list with its per-metric
   `tolerance`. The first run seeds `baseline.json` automatically
   (no need to hand-write the baseline).
5. If the kernel needs extra compiler flags (e.g. a hardware profile),
   add `"compile_flags": ["--hardware-profile=bmg"]` to the entry —
   `check.py` applies them to the compile step for you.

### Metric direction

`check.py` decides "lower is better" vs "higher is better" from the
metric name: anything containing `throughput`, `gflops`, `tflops`,
`gb_s`, or `gbps` is higher-is-better; everything else (`*_us`,
`device_compile_s`, latencies) is lower-is-better. Name new metrics
accordingly so the ratchet points the right way.

## Running

```
python performance/check.py                 # run all, diff vs baseline
python performance/check.py --test=matmul-bmg
python performance/check.py --update        # loud diff even for non-regressions
python performance/check.py --seed          # bootstrap baseline (see caveat)
```

You do **not** pass compiler flags here — a test that needs
`--hardware-profile=bmg` (or any other flag) declares it in its
`TESTS` entry's `compile_flags`, and `check.py` applies it
automatically. Just run `python performance/check.py`.

Default behavior is "run and fail if regressed."  Manual update is
not normally needed because of the ratchet; `--update` just prints
the diff loudly. `--seed` reseeds *every* metric of the selected
test(s) — handy to bootstrap, but it will overwrite good ratchet
history, so don't use it to "accept" a single drifted metric (delete
that one metric from `baseline.json` and let the next run re-seed it
instead).
