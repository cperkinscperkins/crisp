# Matmul benchmark — Crisp tensor-core GEMM vs CUDA

`C[M x N] = A[M x K] . B[K x N]`, tf32, on NVIDIA (sm_80+).

The Crisp kernel is a **grid-stride tiled matmul**: one warp (32 threads) per 64×64
output tile (= a 4×8 grid of 32 m16n8k8 accumulator fragments), selected by
`get-workgroup-id`; each K-step (K-tile = the MMA shape's K = 8) stages the tile's
64×8 A row-block and 8×64 B col-block from global into SLM via sync `load-tile-at`,
reused across all 32 fragment MMAs, then accumulated via 32
`mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32`. Built from the Endeavor-132 MMA
forms: `make-register-tile`, `load-fragment-a/b`, `mma-accumulate` (via
`mma-accumulate-via-tile`), `store-tile`, `inner-dimension`.

## Layout
```
matmul/
  crisp/matmul.crisp         the Crisp kernel  (compiles to matmul.ptx — verified)
  crisp/bench_harness.cu     CUDA-Driver-API launcher: known inputs, timing, correctness
  cuda/matmul.cu             hand CUDA reference (16x16 shared-mem tiled, fp32 baseline)
  run.py                     build + run both, print GFLOPS + crisp/cuda ratio
```

## Correctness oracle
Inputs are `A = B = 1.0`, so every `C[i][j] == K` exactly (1.0 is representable in
tf32; K is exact in fp32 accumulation for the sizes here). Each binary asserts
`max|C - K| < K·1e-3` and exits non-zero on failure — so "correct" is a hard gate,
not eyeballing.

## Running (on a CUDA box — e.g. RunPod, NOT the Intel/BMG dev box)
```
python run.py --sizes=256,512,1024
# or by hand:
crisp-compile --ir-target=ptx crisp/matmul.crisp        # -> crisp/matmul.ptx
nvcc -O3 -arch=sm_80 crisp/bench_harness.cu -lcuda -o crisp/matmul_crisp
nvcc -O3 -arch=sm_80 cuda/matmul.cu -o cuda/matmul_cuda
(cd crisp && ./matmul_crisp 256 256 256)
```
Sizes must satisfy `M % 64 == 0`, `N % 64 == 0`, `K % 8 == 0`.

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

## ⚠️ Status (draft — first RunPod iteration expected)
- The **Crisp kernel + PTX are verified** locally (`mma.sync` in the K-loop, `%ctaid`
  grid-stride, SLM staging). BMG (Intel) can't run it — the MMA is NVVM/PTX-only.
- `bench_harness.cu` was authored on a non-CUDA box. Its 45-slot param array is taken
  verbatim from the Crisp CUDA hoist, but the **first real run may need tweaks** to the
  strides / SLM-tile tuple values. Most likely suspects if `correct=false`: B's
  col-major strides (`B_s0=1, B_s1=K`), and the SLM scratch tuple order (`b_tile` before
  `a_tile`, matching the hoist).
- `cuda/matmul.cu` is a **straightforward fp32 tiled baseline**, not the same algorithm
  as Crisp's tf32-MMA path. It's an apples-ish reference to start; a tf32-MMA reference
  and/or cuBLAS ("best known") are the natural follow-ons for a fair ratio.
- The Crisp kernel now stages one **64×64 output tile per warp** (32 accumulator
  fragments, A/B reused across all 32 MMAs per K-step) — the first arithmetic-intensity
  lever. Still expect it slower than a real GEMM until block-level SLM reuse + async
  pipelining land. The correctness oracle (A=B=1 → C=K) remains the hard gate.
