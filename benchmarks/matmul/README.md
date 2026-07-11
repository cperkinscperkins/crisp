# Matmul benchmark — Crisp tensor-core GEMM vs CUDA (NVIDIA) and SYCL (Intel/BMG)

`C[M x N] = A[M x K] . B[K x N]`, tf32.  Both backends run the SAME Crisp macro —
`matrix-multiply-tile-stride` (Endeavor 135) — over the Endeavor-132 MMA forms
(`make-register-tile`, `mma-accumulate-via-tile`, `load-tile`/`store-tile`, `inner-dimension`).
The macro owns the grid-stride tile walk, the K-loop, and the auto-store; the body just
stages + accumulates.

Because the tensor-core shape genuinely differs per vendor, there are TWO kernels (not a
shape swap):
- **NVIDIA** (`matmul.crisp`): `(16 8 8)` tf32 MMA, **B col-major**, 64×64 register tile
  (one warp / tile → 32 `mma.sync.aligned.m16n8k8` per K-step).
- **Intel BMG** (`matmul_bmg.crisp`): `(8 16 8)` XMX shape, **B row-major** (SPV/DPAS has no
  ColumnMajor-B coop builtin), 32×32 register tile (one 16-lane sub-group / tile).  64×64
  spills BMG's sub-group registers ~5×; 32×32 was swept as the BMG sweet spot.

## Layout
```
matmul/
  crisp/matmul.crisp          NVIDIA kernel  (compiles to matmul.ptx)
  crisp/matmul_bmg.crisp      Intel/BMG kernel  (compiles to matmul_bmg.spv)
  crisp/bench_harness.cu      CUDA-Driver-API launcher (2-D grid, timing, A=B=1 correctness)
  crisp/bench_harness_l0.cpp  Level-Zero launcher (2-D grid, ze-event timing, correctness)
  cuda/matmul.cu              hand CUDA reference (16x16 shared-mem tiled, fp32 baseline)
  sycl/matmul.cpp             hand SYCL reference (16x16 shared-mem tiled, fp32 baseline)
  run.py                      NVIDIA: build + run crisp vs cuda, print GFLOPS
```
The Intel side is driven by `scripts/bench-intel.sh matmul` (Docker + BMG passthrough) →
`scripts/bench-intel-driver.py`, which builds Crisp(L0) + the SYCL reference and compares.

## Correctness oracle
Inputs are `A = B = 1.0`, so every `C[i][j] == K` exactly (1.0 is representable in
tf32; K is exact in fp32 accumulation for the sizes here). Each binary asserts
`max|C - K| < K·1e-3` and exits non-zero on failure — so "correct" is a hard gate,
not eyeballing.

## Running — NVIDIA (CUDA box, e.g. RunPod)
```
python run.py --sizes=256,512,1024        # crisp (matmul.crisp) vs cuda
```
Sizes must satisfy `M % 64 == 0`, `N % 64 == 0`, `K % 8 == 0` (64×64 tile).

## Running — Intel BMG (Docker on the dev box)
```
./scripts/bench-intel.sh matmul                    # sizes default to 256,512,1024
./scripts/bench-intel.sh matmul 256,512,1024 100   # crisp (matmul_bmg.crisp) vs sycl
```
Sizes must be multiples of 32 (the BMG tile).  Runs in the oneAPI Docker image with
`/dev/dxg` BMG passthrough; builds Crisp→SPV + the SYCL reference and prints a GFLOPS table.

## Results

### Initial 16×8 baseline (RunPod, RTX, 2026-07-05) — CORRECT
`ok=True` at all sizes on the first real run (no harness tweaks needed):

| MxNxK | crisp GFLOPS | cuda GFLOPS | crisp/cuda |
|-------|-------------:|------------:|-----------:|
| 256   | 77.5         | 1216.5      | 15.7×      |
| 512   | 70.8         | 1737.5      | 24.5×      |
| 1024  | 70.3         | 1865.8      | 26.5×      |

Correctness confirmed on metal (the whole tf32 MMA path computes A·B).  Crisp
**plateaued at ~70 GFLOPS** = memory-bound: one 16×8 output tile per warp, re-staging
A/B from global each K-step (tiny arithmetic intensity), so the tensor cores starved.

### Bigger register tiles — 64×64 (RunPod, RTX, 2026-07-05) — CORRECT
`matmul.crisp` now uses a **64×64** register tile (4×8 = 32 accumulator fragments, 32
`mma.sync` per K-step).  Pure source change — no compiler work.  Per K-step it stages
1024 global floats (64×8 A + 8×64 B) that feed 32 MMAs instead of 1.

| MxNxK | crisp GFLOPS | 16×8 was | cuda GFLOPS | crisp/cuda |
|-------|-------------:|---------:|------------:|-----------:|
| 256   | 45.6         | 77.5     | 1309.1      | 28.7×      |
| 512   | 185.5        | 70.8     | 1738.2      | 9.4×       |
| 1024  | **429.4**    | 70.3     | 1844.7      | **4.3×**   |

`ok=True` at all sizes.  **At 1024, +6.1× over the 16×8 baseline — almost exactly the
predicted ~6× arithmetic-intensity win**; crisp/cuda collapsed 26.5× → 4.3×.  The 256
*regression* is occupancy, not the kernel: 256² with 64×64 tiles = only 16 workgroups,
so most SMs idle (512 → 64 blocks, 1024 → 256 blocks; GFLOPS climbs as the grid fills
the machine).  Bigger tiles trade workgroup count for per-warp work — they want big
problems.

`ptxas -v` (sm_80, original monolithic accumulator): **181 registers, 0 spills**, but a
**4896-byte stack frame** — the 64×64 accumulator was one monolithic loop-carried
aggregate (`{{4×float}×32}`) rewritten wholesale each K-step, which SROA can't scalarize
(survives as a struct-typed PHI), so NVPTX dropped it to `.local`.  Not spilling — a
structural residency problem, unchanged even under `opt -O3`.

**FIXED 2026-07-05 (register residency).** The `let` that binds a `make-register-tile`
now explodes it into N individual per-fragment mutable variables (each a small
`{4×float}` set! independently), so mem2reg/SROA keep them in registers.  Verified
in-process (`opt -O3` → `llc`): the 64×64 matmul went from a 1024-byte `.local` depot +
~200 local ld/st to **zero `.local`, 0 ld.local, 0 st.local** — fully register-resident,
32 `mma.sync` / 32 `ld.shared` intact.  The `register-tile` / `mma-accumulate-via-tile`
source API is unchanged.  Re-measure on RunPod to see the GFLOPS lift.  Remaining levers:
block-level SLM reuse, then async load-tile / pipelining / warp-specialization.

### macro rewrite (Endeavor 135) — both backends, on metal (2026-07-10)
Both kernels rewritten onto `matrix-multiply-tile-stride`.  **All `ok=True`**; the tf32-MMA
path computes A·B correctly on both vendors.  References are the naive **fp32** tiled kernels
(`cuda/matmul.cu` / `sycl/matmul.cpp`) — NOT cuBLAS/oneMKL — so this is Crisp-tensor-cores vs a
straightforward hand-written baseline, both far below the cards' tensor peak.

**NVIDIA RTX 4000 Ada (RunPod), 64×64 tile:**

| MxNxK | crisp GFLOPS | cuda GFLOPS | crisp/cuda |
|-------|-------------:|------------:|-----------:|
| 256   | 124          | 1235        | 0.10       |
| 512   | 500          | 1621        | 0.31       |
| 1024  | **1899**     | 1823        | **1.04**   |

**Intel Arc B580 / BMG (Docker), 32×32 tile:**

| MxNxK | crisp GFLOPS | sycl GFLOPS | crisp/sycl |
|-------|-------------:|------------:|-----------:|
| 256   | 114          | 1317        | 0.09       |
| 512   | 416          | 1466        | 0.28       |
| 1024  | **1493**     | 1531        | **0.97**   |

Same shape on both: **latency-bound and far behind at small N** (the synchronous Chapter-0
staging + grid-stride overhead dominates a tiny problem), **converging to ≈parity at 1024**
(1.04× on RTX, 0.97× on BMG).  The small-N gap is what the async chapters (pipelined /
warp-specialized loads) exist to close.  Correctness oracle (A=B=1 → C=K) is a hard gate on
every run.

## Remaining levers
Block-level SLM reuse, then async `load-tile` / pipelining / warp-specialization (the "three
chapters" in `docs/topology.md`).  A tf32-MMA / cuBLAS / oneMKL "best-known" reference is the
natural follow-on for a peak-vs-peak ratio.
