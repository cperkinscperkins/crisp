# Benchmarks — Competitive comparisons

This directory exists to answer the question:

> **How does Crisp-compiled code compare to hand-tuned implementations
>  written directly in CUDA / SYCL / OpenCL, and to industry libraries
>  like CUB and CUTLASS?**

Different question from regression detection — see [`../performance/`](../performance/)
for that.

## Philosophy

- **External-facing.**  Numbers from here are appropriate to share in
  papers, talks, blog posts, "Crisp 1.0 release."  They tell a story
  about Crisp's competitive position.
- **Ratio is the unit of comparison.**  Absolute GB/s shifts every time
  we switch GPUs (we rotate through cloud pods — RTX 4090, A40,
  Blackwell, etc.).  But `crisp_kernel_time / cuda_kernel_time` is
  fair across runs *within the same pod*, because both implementations
  saw the same hardware that day.
- **Apples-to-Apples vs Optimal Ceilings.** We explicitly categorize competitors:
  1. **Crisp**: The Crisp kernel being tested.
  2. **Hand-written Native (e.g. CUDA Apples)**: A C++/CUDA kernel mirroring Crisp's algorithm exactly. This isolates codegen overhead without algorithmic differences.
  3. **Vendor Optimal (e.g. CUBLAS)**: The highly-tuned vendor library. This provides the absolute hardware ceiling (e.g., using Tensor Cores).

## Directory Layout & Chapters

Benchmarks are organized topologically by algorithm and "Chapter" (representing increasingly complex optimization techniques).

```text
benchmarks/
  matmul/
    chap0_sync/             # Basic synchronous tiling (no tensor cores)
    chap1_async_linear/     # Asynchronous linear pipelining
    chap1.5_async_block/    # (NVIDIA-only) Block-level async (TMA) + tf32 MMA tensor cores
    chap2_pipelined_block/  # (NVIDIA-only) Deep software pipelining + tf32 MMA
    chap3_wgmma/            # (NVIDIA-only) Hopper warpgroup async MMA (wgmma) — the tensor-core headline
    intel_prefetch/         # (Intel-only) Register-ring + Subgroup2DBlockPrefetch pipeline
    crisp/                  # The Crisp C++ runner harnesses (chap0/chap1 only)
  results/                  # Output directory for raw JSON sweeps
  scripts/
    crisp_bench/
      harness.py            # Reusable JSON sweep definitions
      matmul.py             # Driver to execute matmul sweeps
      report.py             # Generates Markdown tables from JSONs
```

## How to Run & Generate Reports

The benchmarking system is automated via Python scripts that execute parameter sweeps across sizes and precision flags.

### 1. Run the Benchmarks

**Run everything at once (recommended).** The `--sweep-all` flag runs the full
precision matrix (Fast, IEEE+FTZ, IEEE) in a single invocation — no need to call
it once per precision:
```bash
# For NVIDIA (default platform)
python scripts/crisp_bench/matmul.py --sweep-all
```
`matmul.py` is the unified cross-platform driver. It determines what to build and run depending on the `--platform` argument.

For each precision it sweeps **every chapter** (chap0, chap1, chap1.5, chap2,
chap3) × **every competitor** (Crisp, CUDA_Apples, SYCL_Apples, CUBLAS_Optimal,
OneMKL_Optimal) × **every size** (default `256,512,1024,2048,4096`), dropping all
the JSONs into `results/`.  Any target whose source or compiler is missing (e.g.
SYCL/OneMKL without `icpx`) is quietly skipped.  So one command = the whole matmul
story.  Useful knobs: `--sizes=...`, `--iters=N`, `--warmup=N`.

**Two Crisp launch paths.**  The simple chapters (chap0, chap1) share one fixed
`crisp/bench_harness.cu` launcher — a single 45-slot param layout (2 SLM tiles +
A/B/C), kernel picked at runtime by the `CRISP_MATMUL_PTX` env var.  The advanced
chapters (chap1.5 TMA, chap2 rings, chap3 wgmma) can't use it — they have their own
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

**Intel Local Benchmarking (WSL2 + Docker).** For Intel GPUs (e.g. BMG, Arc), we test locally using a Docker container passing through the Windows WSL2 GPU device. Use `bench-intel.sh` to build the required image and run `matmul.py --platform=intel` inside it:
```bash
# Run full precision sweep (sizes 256, 512, 1024)
./scripts/bench-intel.sh

# Run specific sizes for a specific precision
./scripts/bench-intel.sh 256,512,1024 100 fast
```
The results are mapped back directly into `benchmarks/results/` just like native local runs.

### 2. Generate the Markdown Report
The `.json` files are machine-readable but hard to digest. To print a pretty Markdown table comparing all algorithms:
```bash
# Outputs the Markdown report directly to stdout
python scripts/crisp_bench/report.py

# Or pipe it to a file
python scripts/crisp_bench/report.py --output benchmarks/REPORT.md

```

### 3. Cleanup Old Results
As you run benchmarks across different GPUs and flags, the `results/` folder will grow. Keep it tidy with the culling script, which prunes everything except the 5 most recent runs for each unique configuration:
```bash
python scripts/cull-old-benchmarks.py --dry-run
python scripts/cull-old-benchmarks.py
```

## Precision and FTZ (Flush-To-Zero)

We test across three distinct math configurations to accurately map performance ceilings:
1. `IEEE + Preserve Denormals` (`--precision=ieee`): The strictest math mode. Very accurate, but denormals cause massive GPU stalls.
2. `IEEE + FTZ` (`--precision=ieee --ftz`): The sweet spot. Precise for normal numbers, but flushes subnormals to zero to avoid pipeline stalls.
3. `Fast Math` (`--precision=fast`): Peak throughput mode. Allows reassociation and enables Tensor Cores (TF32) on NVIDIA.

## Hardware variance

Absolute metrics (GB/s, TFLOPS) shift drastically depending on L2 size, memory subsystems, and background load. **Never claim "Crisp is X GB/s" without naming the GPU. Always quote ratios when comparing across runs.**
