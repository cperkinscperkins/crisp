# Matmul benchmark — Crisp tensor-core GEMM vs CUDA

`C[M x N] = A[M x K] . B[K x N]`, tf32, on NVIDIA (sm_80+).

The Crisp kernel is a **grid-stride tiled matmul**: one warp (32 threads) per 16×8
output tile, selected by `get-workgroup-id`; each K-step (K-tile = the MMA shape's
K = 8) is staged from global into SLM via sync `load-tile-coords`, then one
`mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32` accumulates it. Built from the
Endeavor-132 MMA forms: `make-register-tile`, `load-fragment-a/b`, `mma-accumulate`
(via `mma-accumulate-via-tile`), `store-tile`, `inner-dimension`.

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
Sizes must satisfy `M % 16 == 0`, `N % 8 == 0`, `K % 8 == 0`.

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
- The Crisp kernel is **single-tile-per-warp** with no output reuse — expect it to be
  slower than the reference until we add per-thread output tiling / bigger register
  tiles. The first goal is **correctness on metal**; the ratio is a starting data point.
