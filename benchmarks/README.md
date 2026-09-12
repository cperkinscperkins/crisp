# Benchmarks — Competitive comparisons

This directory exists to answer the question:

> **How does Crisp-compiled code compare to hand-tuned implementations
>  written directly in CUDA / SYCL / OpenCL, and to industry libraries
>  like CUB and CUTLASS?**

Different question from regression detection — see [`../performance/`](../performance/)
for that.

## Philosophy

- **External-facing.**  These numbers are meant for papers, talks, and the 1.0 release.
- **Ratios travel; absolutes don't.**  We rotate through cloud pods, so TFLOPS shifts run to
  run.  `crisp_time / competitor_time` stays fair *within* a pod, because both saw the same
  hardware that day.
- **Four contender classes**, so every number says what it is measuring:

  | class | what it is | what it isolates |
  |---|---|---|
  | **Crisp** | the kernel under test | — |
  | **Control** (CUDA_Apples, SYCL_Apples) | C++ mirroring Crisp's algorithm exactly | codegen overhead, with algorithm held constant |
  | **Peer** (CUTLASS, SYCL-TLA; CUB for reductions) | a template library at the *same altitude* as Crisp — the user picks the tile shape and pipeline depth | whether Crisp's chosen schedule is competitive with a tuned one |
  | **Ceiling** (cuBLAS, oneMKL, oneDNN) | a closed vendor library free to dispatch any kernel it likes | the absolute hardware limit |

  **Peer is the real competitor.**  Control is too easy a target and Ceiling too hard: a hand-
  rolled mirror has no scheduling, and a vendor library may switch algorithms per shape.  Peer is
  the honest comparison, because Crisp is *outside-in* the same way — the user supplies the
  geometry, so a Peer column measures like against like.  It is also the hardest column to keep
  working, and cells read `N/A*` where a peer genuinely does not implement a path (SYCL-TLA has
  no tf32 DPAS on Xe2) rather than being quietly dropped.
- **Provenance over tidiness.**  Where a column is a best-of over several builds, the cell names
  the build that won; a number the reader cannot reproduce is not a result.

## Directory Layout & Chapters

Benchmarks are organized topologically by algorithm and "Chapter" (representing increasingly complex optimization techniques).

Each chapter exists at up to **three element widths**, as sibling directories with a suffix.
The bare name is 32-bit (tf32 on the matrix engines), `_bf16` is 16-bit, `_f64` is IEEE double.
The suffix is part of the *chapter key* recorded in every result file, which is how the report
separates the three ladders — they are **not** comparable cell-for-cell, because the register
budget forces different tile geometry at each width.

```text
benchmarks/
  matmul/
    # §1 — MMA Techniques (the technique ladder, with a Control)
    chap0_naive/                # Ch 0: Naive scalar loops (no tensor cores)
    chap1_handrolled_mma/       # Ch 1: Hand-rolled tensor core instructions
    chap2_tiling/               # Ch 2: Synchronous hardware tiling (matrix-multiply-tile-stride)
    chap3_async/                # Ch 3: Asynchronous staging (cp.async / OpGroupAsyncCopy)
    chap4_cheap_fetch/          # Ch 4: Cheap fetch (TMA CUtensorMap / register-resident load)
    chap5_multistage_ring/      # Ch 5: Multi-stage pipeline (SMEM ring / register ring prefetch)
    chap6_warp_specialization/  # Ch 6: Warp specialization (sm_90+ asynchronous staging)
    chap7_wgmma/                # Ch 7: Wide math (Hopper WGMMA 64x256)

    chap0_naive_bf16/ ...       # §1.5 — the same ladder in bfloat16, chap0..chap7
    chap0_naive_f64/  ...       # §1c  — the same ladder at IEEE double, chap0..chap6
                                #        Ch 7 is ABSENT BY HARDWARE: wgmma covers
                                #        fp16/bf16/tf32/fp8/int8, and there is no fp64
                                #        warpgroup MMA in any form.

    # §2 — Top MMA Benchmarks (all contender classes)
    sec2_top/                   # tf32/fp32  (Crisp vs Apples vs CUTLASS vs cuBLAS/oneMKL)
    sec2_top_bf16/              # bf16       (native 270+ TFLOPS matrix engines)
    sec2_top_fp16/              # fp16       (shares one implementation with bf16)
    sec2_top_f64/               # fp64 DMMA  (Crisp vs CUTLASS DMMA/SIMT vs cuBLAS 64F)

    # §3 — Situational Techniques
    sec3_cluster_multicast/     # TMA multicast controlled pairs (64x128 vs 64x256)
    sec3_mma_lowering/          # Intel :xe-native vs :coop-matrix, matched geometry

    # §4 — MMA + Activation (fused epilogues)
    sec4_fused_relu/            # Ch 1: Standard epilogue (fused ReLU)
    sec4_fused_custom/          # Ch 2: Custom epilogue (arbitrary user function)

    _probe_*/  _variant_*/      # FENCED experiments, not canonical results.  A leading
    _iso/  _kdepth/             # underscore keeps them out of the report; several hold
                                # deliberately-wrong kernels used to isolate one effect.

  results/                      # Canonical JSON benchmark results
  results/scratch/              # Runs the report NEVER reads (see --scratch)
scripts/
  hw-profile/                   # Device query programs -> a def-hardware-profile (see below)
  crisp_bench/
    harness.py                  # Reusable JSON sweep definitions & dataclasses
    hwprofile.py                # Hardware-profile gate: device -> validated profile
    matmul.py                   # Driver to execute matmul sweeps
    report.py                   # Markdown report generator (produces REPORT.md)
```

## How to Run & Generate Reports

The benchmarking system is automated via Python scripts that execute parameter sweeps across sizes and precision flags.

> **Build the compiler first** (`sbcl --non-interactive --load .\build\build.lisp`) — the sweep
> invokes `bin/crisp-compile`, it does not build it.
>
> **The first thing every sweep does is check the hardware profile**, before any compile. On a
> device Crisp has no validated profile for it stops immediately with instructions rather than
> burning a pod rental on numbers that would be wrong. See [Hardware Profiles](#hardware-profiles).

### 1. Run the Benchmarks

**Run everything at once (recommended).** The `--sweep-all` flag runs the full
precision matrix (Fast, IEEE+FTZ, IEEE) in a single invocation — no need to call
it once per precision:
```bash
# For NVIDIA (default platform)
python scripts/crisp_bench/matmul.py --sweep-all
```
`matmul.py` is the unified cross-platform driver. It determines what to build and run depending on the `--platform` argument.

It sweeps **every chapter** — the tf32 ladder chap0..chap7, its `_bf16` twin, and the `_f64`
ladder chap0..chap6, plus every `sec2_*`/`sec3_*`/`sec4_*` group — × **every competitor** × **every
size**, dropping the JSONs into `results/`, **at the one precision each ladder's rule allows** (16/32-bit
at `fast`, 64-bit at `ieee`; the `ieee`+FTZ pass runs no matmul).  Fenced `_` directories are left
out unless named in `--chapters`.  Any target whose source or compiler is missing (e.g. SYCL/OneMKL
without `icpx`) is skipped with a message.  See [Harness Ground Rules](#harness-ground-rules).

**Sizes are named presets, not a literal default.**  `--sizes` defaults to `canonical`:

| preset | sizes |
|---|---|
| `small` | 256, 512, 1024 |
| `medium` | 2048, 4096 |
| `large` | 8192, 16384 |
| `xl` | 32768, 40960 |
| `canonical` | 256 … 16384, **plus 32768 on NVIDIA** (default) |
| `all` | canonical + 40960 on NVIDIA |
| `devmax` | the largest N this card can hold — resolved per ladder, see below |

**Sizes are also bounded by device memory, per ladder.**  Every matrix in this suite lives in
device memory (there is no out-of-core path yet), so a size that does not fit is an allocation
failure *after* the compile has been paid for — and on the largest sizes the compile is the
expensive part.  The harness therefore drops sizes it can prove will not fit, and says so:

```
  [chap0_naive_f64] skipping 40960: needs more than 60% of 80 GB at 24 B/element (ceiling N=46208)
```

The ceiling is **per ladder**, because one size list drives three element widths:

| ladder | device bytes per element position (A+B+C) | ceiling on an 80 GB H100 |
|---|---|---|
| bf16 / fp16 | 8 — A, B at 2 B; C accumulates in fp32 | ~80064 |
| tf32 / fp32 | 12 | ~65344 |
| fp64 | 24 | ~46208 |

A single fp32 answer would run the f64 ladder off the end of HBM while leaving a third of the
card unused on the 16-bit one.  The 60% headroom (`MATMUL_VRAM_HEADROOM`) is not idle slack: the
three matrices are the floor, and cuBLAS, CUTLASS and the fixtures all allocate on top of them.

`devmax` asks for the biggest rung this card can hold, rounded down to a multiple of 4096 so the
ladder stays legible.  It is deliberately **not** in `canonical`: a device-specific size is a
within-device statement, and the shared rungs are what let ratios travel between pods.  When VRAM
cannot be queried (any non-NVIDIA device today) nothing is clamped and `devmax` resolves to
nothing, rather than guessing a ceiling.

Presets and explicit sizes mix freely: `--sizes=small,8192`.  Other knobs: `--iters=N`
(default 100), `--warmup=N` (default 20), `--chapters=a,b` to restrict, `--scratch` to write
to `results/scratch/` where the report will not read it.

**Two Crisp launch paths.**  The simple chapters (chap0, chap1) share one fixed
`crisp/bench_harness.cu` launcher — a single 45-slot param layout (2 SLM tiles +
A/B/C), kernel picked at runtime by the `CRISP_MATMUL_PTX` env var.  The advanced
chapters (chap4 TMA, chap5 rings, chap6 warp-spec, chap7 wgmma) can't use it — they have their own
param layouts (CuTensorMap descriptors, ring tiles, >48KB dynamic SMEM, 128+
threads).  For those, `matmul.py` passes `crisp_grid_tile=...` to `run_target`,
which routes through `run_crisp_autobench`: it runs `crisp-hoist-cuda --mma-bench`
to auto-generate a *per-kernel* harness (reading the real params + col-major B +
the `cuFuncSetAttribute` SMEM opt-in straight from the kernel's metacrisp), then
nvcc-compiles and runs it.  Note: this compiles once per kernel and reuses the
PTX/metacrisp across all sizes/precisions, so the auto-bench chapters report the
same Crisp throughput at every precision (the kernel is tf32 regardless — the
`fast` column is the honest tensor-core-vs-tensor-core comparison; under `ieee`
cuBLAS drops to fp32, so Crisp's tf32 wgmma "beats" it, which is apples-to-oranges).

**Targeted single-config runs** (when you only want one precision):
```bash
# Fast Math (peak throughput, enables Tensor Cores for CUBLAS)
python scripts/crisp_bench/matmul.py --precision=fast

# Strict IEEE math + Flush-to-Zero (high accuracy, prevents denormal stalls)
python scripts/crisp_bench/matmul.py --precision=ieee --ftz
```

**On a remote GPU (RunPod).** `bench-on-pod.sh` SSHes in, installs deps, builds
the compiler, and runs the sweep remotely (it calls `matmul.py --sweep-all` for
you):
```bash
./scripts/bench-on-pod.sh <host> <port> <branch> ~/.ssh/id_ed25519 --bench=matmul


./scripts/bench-on-pod.sh <host> <port> <branch> ~/.ssh/id_ed25519 256,512,1024,2048,4096 100 --bench=matmul

```
> ⚠️  `--bench` **defaults to `reduction`** — pass `--bench=matmul` for the matmul
> suite (or run the script twice, once per benchmark, to cover both algorithms).

*Note: after a remote sweep, use `bash scripts/pull-runpod-results.sh` to download
the JSON files back to your local `results/` folder.*

```
$ ./scripts/pull-runpod-results.sh 103.207.149.79 16881  ~/.ssh/id_ed25519
```

**Intel Local Benchmarking (WSL2 + Docker).** For Intel GPUs (e.g. BMG, Arc), we test locally using a Docker container passing through the Windows WSL2 GPU device. Use `bench-intel.sh` to build the required image and run `matmul.py --platform=intel` inside it. 



```bash
# Run full precision sweep at the canonical sizes (256 … 16384)
./scripts/bench-intel.sh

# Run specific sizes for a specific precision
./scripts/bench-intel.sh 4096,8192 100 fast
```
The results are mapped back directly into `benchmarks/results/` just like native local runs.



### 2. Generate the Markdown Report
The `.json` files are machine-readable but hard to digest. To build the comparison tables:
```bash
# Regenerate the checked-in report (this is the one you usually want)
python scripts/crisp_bench/report.py --output benchmarks/REPORT.md

# Without --output it prints to stdout and writes NOTHING
python scripts/crisp_bench/report.py | less
```

> ⚠️  **`--output` is not optional if you mean to update `REPORT.md`.**  Bare `report.py`
> prints to stdout and leaves the file untouched, so a "regeneration" that scrolled past can
> look successful while the report on disk is unchanged.

The report reads only `results/`, never `results/scratch/`, and separates the ladders by the
chapter-key suffix — so a `_f64` run lands in §1c/§2c automatically, with no flag to remember.

### 3. Cleanup Old Results
As you run benchmarks across different GPUs and flags, the `results/` folder will grow. Keep it tidy with the culling script, which prunes everything except the 5 most recent runs for each unique configuration:
```bash
python scripts/cull-old-benchmarks.py --dry-run
python scripts/cull-old-benchmarks.py
```

## Harness Ground Rules

These are **requirements**, and `scripts/crisp_bench/matmul.py` enforces them unless a row says
otherwise.  Status as of 2026-09-12.  The plain call is the right call:

```bash
./scripts/bench-intel.sh                       # Intel
python scripts/crisp_bench/matmul.py --sweep-all --auto-profile   # NVIDIA pod
```

Flag names: `matmul.py` takes `--precision=fast|ieee` and `--ftz` (or `--sweep-all` for all three
passes), and translates them into the compiler's own `--math-precision=fast|ieee` and
`--denormal-handling=preserve|ftz`.

### Precision — one precision per matmul ladder

`--sweep-all` is the one universal call: it runs three passes, and each suite takes only the passes
its rule allows.  The harness prints the rule at the top of each pass.

| suite | element width | runs at | status |
|---|---|---|---|
| matmul | 16-bit (bf16 / fp16) | `fast` only | **Enforced** (`matmul_precision_ok`) |
| matmul | 32-bit (tf32 / fp32) | `fast` only | **Enforced** |
| matmul | 64-bit (fp64 — NVIDIA only; BMG has no fp64 MMA) | `ieee` + preserve only | **Enforced** |
| matmul | — | `ieee` + FTZ | runs **nothing** — that pass exists for scalar suites |
| reduction | — | `fast`, `ieee`, `ieee` + FTZ | **NOT IMPLEMENTED.** `benchmarks/reduction/run.py` passes no precision or denormal flags at all. |

`report.py` reads the same rule back: `fast` for 16/32-bit, `ieee` (falling back to `fast`) for fp64.

### Sizes

- **The matmul ladder runs to 16384 on every device, BMG included, §1 included.**  Behaviour
  changes at those sizes, which is the reason to measure them.  (Until 2026-09-11 `bench-intel.sh`
  stopped at 8192.)
- **Above 16384, as far as device memory allows**, per ladder (see the per-width table under
  *Run the Benchmarks*).  BMG reports 11.6 GB; its 1 GiB *single-allocation* cap is lifted in the
  Crisp L0 fixture by the relaxed-allocation-limits extension, and SYCL has run bf16 at 32768 on
  BMG.  **Enforced on both vendors:** NVIDIA memory comes from `nvidia-smi`, Intel from Level Zero
  (`scripts/hw-profile/query-l0.cpp`, built with the fixture's toolchain).  BMG: 11.6 GiB, so the
  ceiling is N ≈ 24,900 for tf32 and ≈ 30,500 for bf16.  Caveat: inside the Docker container the
  driver also caps a **single allocation at 1 GiB**, which the fixture lifts and the generated L0
  harness does not — so a chap1–3 point above 16384 tf32 would fail to allocate.
- A size can still be **declined by the pacer** (below) when it cannot finish inside its timeout.
  That is printed as a `SKIP` line with the reason, so the gap in the table is attributable.

### Iteration counts — fewer at larger sizes

Every (chapter, contender) walks its size ladder smallest first, and each point's measured
per-iteration time predicts the next one's (× (N/N_prev)³, matmul's work growth).

| size | warmup + iterations |
|---|---|
| ≤ 1024 on Intel, ≤ 2048 on NVIDIA | the requested counts (default 20 + 100) |
| above that | scaled down by (ref/N)³ — floor 2 + 5 — **and further** to a time budget of about 50 ms of warmup and 500 ms of timed loop (plan/benchmark-harness.md §3) |
| iteration predicted ≥ 1 s | floor **1 + 3**: JIT, first touch and cache fill are all paid inside the first launch, and a median of 3 is enough when each sample takes seconds |

A fast kernel is unaffected until its iterations get slow; a slow one stops paying for samples it
does not need.  The counts that actually ran are recorded in each result point
(`configuration.warmup` / `configuration.iters`).  **Enforced** in every sweep function
(`SizePacer`).

Measured example, BMG `chap0_naive` (no tensor cores): 22.8 s per iteration at 8192 — the old fixed
2 + 5 made that one point cost ~160 s; it is now 1 + 3, ~92 s.

### Verification

Correctness is checked at **every** size, and is **never** a full O(N³) host reference at large N.
Per harness, as read from the source:

| harness | check | cost at N=16384 |
|---|---|---|
| Crisp L0 fixture (`crisp/bench_harness_l0.cpp`) | strided 64×64 spot check, stops at first failure | < 1 s |
| Crisp CUDA fixture (`crisp/bench_harness.cu`) | strided 64×64 spot check | < 1 s |
| SYCL / CUDA Apples, oneMKL, controls | A = B = 1, every element of C must equal K — one O(N²) pass | < 1 s |
| Crisp CUDA auto-bench (`crisp-hoist-cuda --mma-bench`) | full host reference | `matmul.py` kills the child at its BENCH line above `VERIFY_MAX_N` = 2048, so the reference never runs |
| Crisp L0 generated harness (`crisp-hoist-l0 --mma-test`) | strided 64×64 sample over the whole of C, operands recomputed from the fill | < 1 s — so it is verified at **every** size |

**Which BMG kernels use the generated L0 harness.**  The reviewed fixture cannot bind SLM tensor
arguments, so `chap1_handrolled_mma`, `chap2_tiling` and `chap3_async` — tf32 and bf16, half the
section-1 ladder — are measured through the generated harness.  Until 2026-09-12 that harness
checked only the top-left 64×64 corner (blind to every other tile), `matmul.py` killed it before
the check above N=2048 (so those rungs were recorded unverified from 4096 up), a hard cap kept it
at or below 8192, its warmup was hardcoded to 20, and `chap2_tiling`/`chap3_async` tf32 were not
even enabled for it — `chap2_tiling` tf32 had recorded **zero** BMG points since 2026-08-22.  All
five are fixed; the check is negative-tested (`--mma-scale=2` → `MMA_WRONG`).

**Verification is not a time cost at large N on either vendor.**  Measured on BMG, `chap0_naive`
at 8192: kernel 22.8 s per iteration, everything else — allocation, fill, copies and the spot
check — 1.4 s.  Slow large points are slow *kernels*.

### Time limits

- **No benchmark process may run longer than 5 minutes** (`BENCH_TIMEOUT = 300`), and above
  N = 16384, 150 s.  Of 3,152 points recorded on every device before 2026-09-12 the longest timed
  loop was 148 s and none exceeded 300 s.  **Enforced.**  (It was 900 s, sized for the CUDA
  auto-bench's host reference, and on 2026-09-12 cost two `chap0_naive` points at 16384 fifteen
  minutes each for nothing.)
- **A point predicted to exceed its timeout is not attempted**, and neither is any larger size for
  that contender.  A point that fails after using most of its timeout stops the ladder the same
  way.  **Enforced** (`SizePacer`).  On BMG this declines `chap0_naive` at 16384 up front:
  predicted ~730 s from the measured 8192 point.

### Fenced chapters

- `_`-prefixed directories (`_probe_*`, `_variant_*`, `_iso`, `_kdepth`) are diagnostics, some
  numerically wrong by construction.  **They run only when named in `--chapters`**, and **their
  results always go to `results/scratch/`**, whatever flags were passed.  **Enforced** (`_skip` in
  `matmul.py`; `BenchmarkSweep.save` in `harness.py`).

### SYCL runtime adapter (Intel)

- **Every SYCL contender runs on the Unified Runtime's V1 Level Zero adapter**
  (`SYCL_UR_USE_LEVEL_ZERO_V2=0`, set in `scripts/bench-intel-entrypoint.sh`).  **Enforced** for
  `bench-intel.sh` runs.
- Why: the V2 adapter, the default in the container's oneAPI 2025.3, loses the device
  intermittently on BMG/WSL2.  Measured 2026-09-12: oneMKL tf32 at N=8192 failed with
  `UR_RESULT_ERROR_DEVICE_LOST` in 5 of 12 runs on V2 and 0 of 12 on V1, and each sweep dropped a
  different random set of competitor points.  oneMKL tf32/bf16, SYCL-TLA bf16 and SYCL_Apples ran
  at identical throughput on both adapters (within 1%), so the switch changes no number.
- Crisp's L0 harnesses do not use the SYCL runtime.  A native (non-Docker) Intel run does not get
  this setting; export it yourself.

### Hardware profile

- Every sweep compiles against a profile matched to the device, and every result records which
  profile and how it was obtained.  **Enforced** — see [Hardware Profiles](#hardware-profiles).

## Precision and FTZ (Flush-To-Zero)

`--sweep-all` runs three math configurations:

1. `IEEE + Preserve Denormals` (`--precision=ieee`): The strictest math mode. Very accurate, but denormals cause massive GPU stalls.
2. `IEEE + FTZ` (`--precision=ieee --ftz`): The sweet spot. Precise for normal numbers, but flushes subnormals to zero to avoid pipeline stalls.
3. `Fast Math` (`--precision=fast`): Peak throughput mode. Allows reassociation and enables Tensor Cores (TF32) on NVIDIA.

### But the three-way sweep does NOT apply to MMA

That matrix maps a *scalar* math pipeline, and it is the right frame for the reduction suite and
for algorithms added later.  It is **not** how the matmul numbers are read, and the difference
matters because MMA is the bulk of the benchmarking today.

**The MMA ladders are reported at one configuration each:**

| ladder | reported at | why |
|---|---|---|
| tf32 (§1, §2) | `fast` | tf32 on the matrix engines **is** the fast-math path |
| bf16 / fp16 (§1.5, §2) | `fast` | same |
| **fp64 (§1c, §2c)** | **`ieee`** | fp64 exists to be *correct*; DMMA is bit-identical IEEE double, so `fast` would answer a question nobody asked |

Two independent reasons the other cells are not results:

- **Under `ieee`, the comparison stops being like-for-like.**  cuBLAS drops to fp32 while the
  Crisp kernel is still tf32 on tensor cores, so Crisp "wins" — apples to oranges.  Only the
  `fast` column is a tensor-core-vs-tensor-core comparison.
- **The auto-bench chapters do not vary with precision at all.**  They compile once per kernel
  and reuse that PTX across every size and precision, so the advanced chapters report the *same*
  Crisp throughput in all three columns.  Three passes there produce one number, thrice.

So matmul runs at exactly one precision per ladder, and `matmul.py` enforces it — see
[Harness Ground Rules](#harness-ground-rules).

## Hardware Profiles

A **hardware profile** tells the compiler the bounds and capabilities of the target — SIMD
width, compute units, register budget, SLM cap, L2 size, which MMA shapes exist.  Crisp ships
two, `bmg` (Intel Arc B580 / Xe2) and `h100` (NVIDIA **H100 PCIe**, 114 SMs), and the sweep
passes one on every compile.

**Benchmarks refuse to run on hardware Crisp has no validated profile for.**  That is
deliberate.  `:compute-units` *overrides* the device SM query when the launch grid is sized, so
a profile for the wrong part does not merely leave performance on the table — it produces
numbers that are wrong in a way no verifier catches.  An H100 PCIe profile on a 132-SM part
under-dispatches every kernel by ~14%, silently.

If the gate stops you, it names the device and prints a starting-point profile:

```
================================================================================
 Hardware detected: NVIDIA H200
================================================================================
Crisp has no validated hardware profile for this device.
Known profiles: bmg, h100 -- none of them describes it.
...
```

### Custom Profiles

1. **Query the device.**  The programs in [`../scripts/hw-profile/`](../scripts/hw-profile/)
   print a paste-ready `def-hardware-profile` from *measured* values — `query-cuda.cu` for
   NVIDIA, `query-l0.cpp` for Intel.  See that directory's `README.md`; it explains the build,
   and which keys each program can and cannot answer.
2. **Fill in what the query cannot reach.**  Every emitted key is tagged with its provenance,
   and the tiers are not cosmetic:

   | tier | meaning | what to do |
   |---|---|---|
   | **QUERIED** | read off the device | trust it |
   | **ARCH** | an ISA fact, not a device property | look it up **for your part** |
   | **MEASURED** | only a sweep can answer it | **omit it** — absent is safe |

   Do not guess on the MEASURED tier.  `:tile-visit-strip-width 4` is **+63% on BMG** at
   N=2048 and **−14.4% on H100** at W=16; there is no rule that predicts which, so a wrong
   guess costs more than leaving it out.  Two ARCH keys also bite silently: Intel's
   `:max-registers-per-thread` is a selectable mode **list** `(128 256)` — a scalar forfeits
   large-GRF, worth 1.55–2.01x — and `:mma-shapes` must list *every* element width the part
   supports, because an unlisted shape is a hard compile error that refuses those kernels.
3. **Use it.**  Crisp compiles multiple files, so the profile can live in its own:
   ```bash
   crisp-compile my-profile.crisp kernel.crisp --hardware-profile=my-device
   ```
   A profile defined in a file **replaces** a built-in of the same name outright — there is no
   key-by-key merge — so naming yours `bmg` discards the shipped one, measured keys included.
   Pick a distinct name.
4. **Register it with the harness.**  Add the device to `DEVICE_PROFILE_MAP` in
   [`../scripts/crisp_bench/hwprofile.py`](../scripts/crisp_bench/hwprofile.py).  Being in that
   table is a *claim that the profile was validated against that device*, so a part that merely
   resembles a listed one does not belong there: H100 PCIe and H100 NVL are the same die and
   differ only in SM count, and that single key is enough to mis-size every dispatch.

### Generating a profile on the machine (`--auto-profile`)

On a rented pod you rarely get to choose the part — RunPod has H100 PCIe one day and H100 NVL
or H200 the next — and until 2026-09-12 a new device cost an edit, a push, a re-clone and a
rebuild before the first kernel compiled, because the harness passed only the
`--hardware-profile` *flag* and never a profile **source file**.  Crisp has always supported the
cheaper route; the harness just never used it:

```bash
crisp-compile my-profile.crisp kernel.crisp --hardware-profile=my-device
```

So the sweep can now build the profile itself:

```bash
# Query this device, write benchmarks/profiles/<device>.crisp, compile everything against it
python scripts/crisp_bench/matmul.py --sweep-all --auto-profile

# ...or supply one you wrote by hand
python scripts/crisp_bench/matmul.py --sweep-all --profile-file=benchmarks/profiles/h200.crisp
```

`--auto-profile` builds and runs [`../scripts/hw-profile/query-cuda.cu`](../scripts/hw-profile/),
which prints a paste-ready `def-hardware-profile` **named after the device** (`h100-nvl`, `h200`)
with every key tagged QUERIED / ARCH / MEASURED.  It looks for `nvcc` under `/usr/local/cuda/bin`
as well as on `PATH`, because cloud images generally do not put it there.  NVIDIA only — the
Intel probe needs Level Zero headers the benchmark container lacks, and `bmg` is already
validated, so the case does not arise.

> **A generated profile is QUERIED, not VALIDATED, and the results say so.**
> The MEASURED tier stays absent — `:tile-visit-strip-width` above all, which is +63% on BMG and
> −14.4% on H100 and which no query can answer.  Absent selects linear, which is safe but not
> tuned.  Every result file records `profile_provenance` (`builtin` / `file` / `auto` / `none`)
> and `REPORT.md` prints it in the device table with a footnote.  This distinction is the whole
> point of the gate; automating the easy half must not quietly erase it.
>
> For a **Hopper** part the gap is small: `query-cuda.cu` answers the QUERIED tier and states the
> ARCH tier correctly for sm_90, so an H200 profile is really `h100` with `:compute-units` and
> `:l2-cache-size` corrected.  For a part on a **different architecture** it is not — `:mma-shapes`
> and `:wgmma-shapes` become real decisions, and the generated file should be reviewed, not
> trusted.

To promote a generated profile to a validated builtin: sweep its measured keys, add them, move
the form into `register-builtin-hardware-profiles` (`src/mma.lisp`), and add the device to
`DEVICE_PROFILE_MAP`.

### Escape hatches

```bash
# Sweep with NO profile.  Results are stamped unprofiled and are NOT comparable
# to published Crisp figures.
python scripts/crisp_bench/matmul.py --allow-unprofiled

# Exercise the gate without the hardware (useful before renting a pod)
python scripts/crisp_bench/matmul.py --pretend-device="NVIDIA H200"
python scripts/crisp_bench/matmul.py --pretend-device="NVIDIA H200" --auto-profile   # and the way out
```

Every result file records which profile it was compiled against, under
`run_metadata.hardware`: `hardware_profile` and `profile_matched`.  A sweep that cannot say
which profile produced it cannot be compared with one that can.

## External Benchmark Dependencies

Crisp itself has zero runtime or external library dependencies. However, to run peer comparison suites against vendor template libraries (e.g. `SYCL-TLA` / CUTLASS for SYCL), header-only dependencies are placed in `third_party/` (ignored by git):

### Intel SYCL-TLA (CUTLASS for SYCL)
To benchmark against Intel's official SYCL Tensor Linear Algebra library (`intel/sycl-tla`):
```bash
mkdir -p third_party
git clone https://github.com/intel/sycl-tla.git third_party/sycl-tla
```
When running in Docker via `scripts/bench-intel.sh` or `matmul.py`, `third_party/sycl-tla` is automatically mounted and included during peer kernel compilation.

## Hardware variance

Absolute metrics (GB/s, TFLOPS) shift drastically depending on L2 size, memory subsystems, and background load. **Never claim "Crisp is X GB/s" without naming the GPU. Always quote ratios when comparing across runs.**

