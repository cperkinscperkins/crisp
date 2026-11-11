# conv2d_v2 (leaderboard #537) -- working notes, branch gpumode-convolv (2026-11-11)

## The problem
`Y = conv2d(X, W)`, fp32, no padding, stride 1.  X (B, C, H, H), W (C, C, K, K), Y (B, C, O, O), O = H-K+1.
Checked at rtol = atol = 1e-3 against `F.conv2d` inside `DeterministicContext` (cuDNN TF32 off,
deterministic on).  Ranked by the LAST benchmark only: size 256, K = 32, C = 128, batch 1 (seed 6252):
225 x 225 x 128 outputs, each a 131,072-term dot product = 1.699 TFLOP as a direct convolution.

## Finding 1: what "correct" means depends on the GPU (diag_conv2d_orders.py, diag_conv2d_accuracy.py)
The reference's own error decides who passes, and cuDNN's heuristic picks a different algorithm per GPU.

| GPU | cuDNN kernel the reference runs | ref vs float64 (scored case) | what passes |
|---|---|---|---|
| H100 | `implicit_convolve_sgemm` -- one sequential fp32 FMA chain per output | 2.35e-3 rms, 4e-2 max | ONLY that chain: (ci, ky, kx) order is BIT-EXACT (0 mismatches); the exact answer mismatches 4837 elements |
| A100 | FFT: `fft2d_r2c_32x32`, `gcgemm_64x32`, `fft2d_c2r_32x32` | 1.1e-4 rms | anything ACCURATE: the float64 answer passes; the H100 chain fails 4846 |
| L4 | (pending) | | |
| B200 | (pending -- the B200 queue has been timing out since 10-28) | | |

Why the H100 reference is so far off: a sequential fp32 sum of 131K terms of std ~1 drifts ~2e-3 rms
(reproduced in pure Python: put_temp_files_here/.../accum.py), and the checker's floor near zero is 1e-3.
Blocked sums (row, channel, total) are 25x more accurate -- and fail on the H100 for exactly that reason.

Consequences:
- No single kernel passes on both H100 and A100.  Every submission picks its kernel per GPU.
- On H100: FFT, TF32 / 3xTF32 tensor cores, split-K and blocked sums are all ruled out.  The ceiling is fp32
  FMA throughput: 0.85e12 FMAs >= ~25 ms.  The leaderboard's 0.6 ms / 6 ms H100 entries cannot pass today's
  reference (they predate it, or their runner's cuDNN chose another algorithm).
- On A100 (and wherever cuDNN uses FFT): FFT methods are allowed -- that is how #1 gets 855 us there.

## Standings snapshot (2026-11-11, /api/leaderboard/537)
| GPU | entrants | #1 | #2 | #3 | median |
|---|---:|---:|---:|---:|---:|
| H100 | 33 | 595 us | 651 us | 6.1 ms | 47 ms |
| A100 | 22 | 855 us | 895 us | 1.04 ms | 5.3 ms |
| L4 | 14 | 4.7 ms | 5.1 ms | 21.7 ms | 114 ms |
| B200 | 24 | 479 us | 524 us | 902 us | 6.4 ms |

## Entries
- **Beauty** `conv2d_beauty.crisp` -> `crisp_conv2d_beauty.py`: one thread per output, one FMA chain in
  (ci, ky, kx) order.  H100 test 970628 passed (before the order was known to matter, with blocked sums the
  small test cases passed; benchmark 970629 failed 4856 mismatches -> finding 1).
- **v1 tiled (H100 lane)** `conv2d_tiled.crisp` -> `crisp_conv2d_tiled.py`: 8 channels x 4 pixels per thread
  (eight float4 accumulators, each lane its own chain), (ci, ky) staged in shared memory, W pre-transposed
  to (ci, ky, kx, co).  No new compiler features.

## Local verification on the BMG (B580, OpenCL; put_temp_files_here/conv2d/cl_conv.py, cl_time.py)
The tiled kernel and the beauty's chain compute the SAME fp32 FMA chain per output, so they must agree bit for
bit on any IEEE GPU: 0 differences over 6 cases / 2.1M outputs (C = 16 and 48 against the 32-channel tile,
K = 4..32, O not a multiple of 8 or 32).  Negative control (chain vs accurate kernel): 90%+ of elements differ.
Timing at the scored size (BMG peak fp32 ~13.7 TFLOPS):
| kernel | time | TFLOPS |
|---|---:|---:|
| naive chain (beauty), 128/K32/C64 | 105 ms | 0.75 |
| tiled v1, 128/K32/C64 | 21.7 ms | 3.64 |
| tiled v1, scored 256/K32/C128 | 312 ms | 5.44 |
w_transpose was 22 ms (scattered writes); a 32 x 33 shared-memory tile transpose made it 0.76 ms.

## Diagnostics (all --mode test; the table comes back as the RuntimeError)
- `diag_conv2d_accuracy.py` -- ours / reference vs a float64 conv2d, mismatch counts.
- `diag_conv2d_orders.py` -- which cuDNN kernels the reference launches (torch.profiler) and whether a
  (ci, ky, kx) or (ky, kx, ci) FMA chain reproduces it bit for bit.

## FOR DISCUSSION (Chris): the performant entry needs two lanes, and only one needs new capability

### H100 lane -- no new API.  In progress (`conv2d_tiled.crisp`).
The reference fixes the arithmetic: 0.85e12 fp32 FMAs, each output one chain in (ci, ky, kx) order.  The
work is a well-tiled SIMT implicit GEMM; today's Crisp expresses it (float4 `op-fma`, `##(...)`, scratch,
`dotimes+`).  Ceiling ~25 ms (fp32 FMA peak).  The board's H100 median is 47 ms; everything faster than
~25 ms on that board predates today's reference.  Levers after v1: bigger per-thread tile (8 x 8),
double-buffered staging, sliding the staged rows across ky instead of reloading them.

### A100 / FFT-reference lane -- this is where the leaderboard is, and where new capability would pay
Where cuDNN uses FFT, accuracy is allowed, so convolve by FFT (overlap-save):
  1. X: 7 x 7 tiles of 64 x 64 (stride 33 -- K = 32 leaves 33 valid outputs per tile) -> rfft2 -> 2112 bins
     x 128 ci x 49 tiles (106 MB).
  2. W: 16384 filters zero-padded to 64 x 64 -> rfft2 -> 2112 bins x 128 co x 128 ci (277 MB).
  3. Per bin a complex GEMM: Y^ (128 co x 49 tiles) = W^ (128 x 128) . X^ (128 x 49): 13.6 GFLOP real.
  4. irfft2 per (co, tile), keep the 33 x 33 valid corner -> Y.
  ~15 GFLOP + ~0.7 GB of traffic instead of 1.7 TFLOP.  Estimate A100 2-3 ms in plain fp32 SIMT (board
  median 5.3 ms, #1 855 us); stage 3 on tensor cores in 3xTF32 (fp32-accurate) would take ~0.3 ms off.

Options, cheapest first:
  (a) NO compiler change: write the four kernels by hand -- complex as `float2`, 64-point FFTs in shared
      memory (radix-2/4 butterflies, twiddles from `cos`/`sin` or a `def-const-vec` table), stage 3 as a
      SIMT batched GEMM.  Large authoring effort; likely shakes out compiler bugs (float2 in scratch,
      shuffles of float2, ...).
  (b) A small language layer: a `complex` element type (or blessed float2 helpers: complex-mul, conj) and
      an FFT building block over a scratch tile -- e.g. `(fft-tile! tile :inverse)` for power-of-two
      extents, twiddles folded at compile time.  FFT is linear, so its VJP is the inverse transform --
      it would differentiate cleanly, a nice A|D story for the docs.
  (c) A 3xTF32 MMA lane (`mma-accumulate-via-tile` with fp32-accurate split operands): helps stage 3 here
      and any fp32 GEMM that must match fp32 (matmul contests, conv on Hopper is still NOT one -- the
      chain order rules it out).
My recommendation: (a) first, as a probe that tells us which of (b)'s pieces are actually missing, but
only after you have weighed in -- it is the bigger lane by far (four new kernels), and the per-GPU rule
means it never helps the H100.
