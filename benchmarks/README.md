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

For each precision it sweeps **every chapter** — the tf32 ladder chap0..chap7, its `_bf16`
twin, and the `_f64` ladder chap0..chap6, plus every `sec2_*`/`sec3_*`/`sec4_*` group —
× **every competitor** (Crisp, CUDA_Apples, SYCL_Apples, CUTLASS, CUBLAS_Optimal,
OneMKL_Optimal) × **every size**, dropping all the JSONs into `results/`.  Any target whose
source or compiler is missing (e.g. SYCL/OneMKL without `icpx`) is quietly skipped.  So one
command = the whole matmul story.

**Sizes are named presets, not a literal default.**  `--sizes` defaults to `canonical`:

| preset | sizes |
|---|---|
| `small` | 256, 512, 1024 |
| `medium` | 2048, 4096 |
| `large` | 8192, 16384 |
| `xl` | 32768, 40960 |
| `canonical` | 256 … 16384, **plus 32768 on NVIDIA** (default) |
| `all` | canonical + 40960 on NVIDIA |

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

So `--sweep-all` is harmless but largely redundant for matmul; `--precision=fast` plus a
`--precision=ieee` pass for the 64-bit ladder is the honest minimum.  `--sweep-all` does cover
both, which is why the pod script uses it.

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

### Escape hatches

```bash
# Sweep with NO profile.  Results are stamped unprofiled and are NOT comparable
# to published Crisp figures.
python scripts/crisp_bench/matmul.py --allow-unprofiled

# Exercise the gate without the hardware (useful before renting a pod)
python scripts/crisp_bench/matmul.py --pretend-device="NVIDIA H200"
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

