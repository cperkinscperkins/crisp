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
- **Same algorithm, same launch policy.**  The CUDA reference for a
  given algorithm should mirror Crisp's algorithm exactly — same
  phases, same occupancy heuristic, same blocksize.  We're comparing
  *codegen quality on the same algorithm*, not "Crisp's choice of
  algorithm vs CUDA's choice of algorithm."
- **Library references are also valuable.**  CUB / CUTLASS / SYCL-TLA
  represent "best known" for their respective stacks.  They use
  different algorithms than ours and that's fine — they answer "how
  much performance is on the table beyond an apples-to-apples
  comparison."

## Directory layout

```
benchmarks/
  <algorithm>/
    crisp/         Crisp source (.crisp) + CUDA-Driver-API harness (.cu)
    cuda/          Hand-written CUDA reference (.cu).  Mirrors Crisp's
                   algorithm exactly — same phases, same launch policy.
    cub/           CUB library reference (.cu)
    sycl/          (future) SYCL DPC++ reference
    opencl/        (future) OpenCL reference
    run.py         Build + run + format JSON output for this algorithm
    README.md      Algorithm description, expected results
  results/         (future) Raw JSON output, dated
  README.md        This file
```

Currently implemented:
- [reduction/](reduction/) — sum reduction (the canonical first algorithm)

## How to read benchmark output

Each `run.py` produces JSON-shaped tables.  The numbers you should
look at:

1. **Kernel time (median, microseconds)** — GPU-event-measured time
   for just the kernel.  Excludes host overhead.  This is the
   "codegen quality" metric.
2. **Throughput GB/s** — derived from kernel time and bytes
   processed.  Compare against the GPU's published peak memory
   bandwidth to know how saturated you are.
3. **Wall time (median)** — host-side end-to-end, including
   readback.  Sanity check that the kernel time is plausible
   under real use.
4. **Ratio `crisp/cuda`** — the headline number.  Tells you how
   close Crisp got to a hand-written implementation of the same
   algorithm on the same machine.

Compile times are reported but lightly weighted — they're useful
context (Crisp's `crisp-compile` device-only time vs nvcc) but
not the headline.

## Hardware variance

The reduction benchmark has been measured on three different cloud
GPUs across three weeks.  Absolute Crisp GB/s changed by 50% across
runs (286 → 292 → 426).  Same code, same algorithm.  The shifts come
from:

- L2 size and partitioning (Ada / Ampere / Blackwell each differ)
- Memory subsystem width
- Occupancy of texture cache vs L1
- Background load on the pod

**Conclusion: never claim "Crisp is X GB/s" without naming the GPU.
 Always quote ratios when comparing across runs.**

See [`docs/benchmarks.md`](../docs/benchmarks.md) for the running
commentary on each measured run.

## Adding a new algorithm

1. Create `benchmarks/<algo>/`
2. Write the Crisp kernel: `crisp/<name>.crisp`
3. Write a CUDA-Driver-API harness for it: `crisp/bench_harness.cu`
4. Write the hand-tuned CUDA reference: `cuda/<name>.cu`.  **Must
   mirror Crisp's algorithm exactly** — same phases, same launch
   policy, same occupancy.  This is the apples-to-apples reference.
5. (Optional) Add a CUB / CUTLASS / SYCL reference for industry
   comparison
6. Write `<algo>/run.py` that builds and runs all three and prints
   the comparison table
7. Add the algorithm to the list above

## Adding a new platform

To add SYCL / OpenCL / Triton / Mojo as a comparison platform:

1. Create `benchmarks/<algo>/<platform>/`
2. Implement the same algorithm
3. Extend `<algo>/run.py` to build and run it
4. Note any platform-specific build requirements (toolchain, Docker
   image, etc.) in the algorithm's README

For Intel-side comparisons, the practical constraint is GPU
passthrough.  On Linux, native runs work.  On Windows, where most
Crisp dev happens, the SYCL DPC++ toolchain runs in Docker — both
Crisp's SPV path and SYCL's path execute inside the container.
That makes the comparison fair (same conditions for both) at the
cost of absolute peak performance.
