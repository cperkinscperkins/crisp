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
| L4 | `precomputed_convolve_sgemm` -- a chain | 2.34e-3 rms (40x40 crop) | ONLY the chain: (ci, ky, kx) bit-exact |
| B200 | `precomputed_convolve_sgemm` -- a chain | 2.35e-3 rms (40x40 crop) | ONLY the chain: (ci, ky, kx) bit-exact (and the B200 queue works again) |

Why the H100 reference is so far off: a sequential fp32 sum of 131K terms of std ~1 drifts ~2e-3 rms
(reproduced in pure Python: put_temp_files_here/.../accum.py), and the checker's floor near zero is 1e-3.
Blocked sums (row, channel, total) are 25x more accurate -- and fail on the H100 for exactly that reason.

Consequences:
- No single kernel passes on both H100 and A100.  Every submission picks its kernel per GPU: the A100 is the
  only FFT-reference GPU; H100, L4 and B200 all want the chain.
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

## H100 progress (diag_conv2d_timing.py: one runner, eval.py's procedure, scored case; all bit-exact vs ref)
| kernel | what changed | ms | TFLOPS | regs | blocks/SM |
|---|---|---:|---:|---:|---:|
| cuDNN reference | | 74.7 / 75.1 | 22.7 | | |
| beauty chain (benchmark 970639) | one thread per output | 436 | 3.9 | | |
| conv_tiled (v1, benchmark 970638) | 8 ch x 4 px per thread | 82.3 | 20.6 | 108 | 2 |
| conv_tiled8 | 8 ch x 8 px | 111.3 | 15.3 | 158 | 1 |
| conv_tiled_p | v1 + staging pipelined one stage ahead, kx unroll 4 | **66.9** | 25.4 | 104 | 2 |
| conv_tiled_p32 | p with 32-bit indices | 73.1 | 23.2 | 86 | 2 |
| conv_tiled_p32r | p32 held to 80 registers | 73.0 | 23.3 | 80 (8 B spill) | 3 |
| conv_tiled_p32e | p32 on a host-chosen grid + conv_edge for the thin strips | 79.4 | 21.4 | 96 | 2 |
| conv_tiled_pe | p on the host-chosen grid + conv_edge | 74.1 | 22.9 | 124 | 2 |

**Chosen: conv_tiled_p** -- bit-exact, 11% under cuDNN's own time on the same runner.  What the arms say:
- 32-bit indices: -18% on the BMG, +9% on the H100.  SASS: the innermost loop grows 44.5 -> 48 instructions per
  32 FFMA -- each shared address becomes a LEA instead of folding into an immediate offset.  The BMG is not a
  proxy for Hopper codegen.
- A third workgroup per SM (p32r) bought nothing: the H100 is not occupancy-bound here.
- The edge kernel (one thread per output, a 131K-long dependent chain each, ~57K threads) is latency-bound and
  costs more than the 15% tile waste it removes.  Folding the edge outputs into the main grid as its FIRST
  workgroups (so they overlap the tiled work) is the untried version.
- conv_tiled_p's innermost loop is ~72% FFMA (44.5 instructions / 32 FFMA) but the kernel runs at ~38% of fp32
  peak; the rest is stall time a profiler would have to name (barrier skew, register-bank conflicts, LDS
  latency).  That needs ncu on an H100 -- a pod rental, not done.
SASS of v1's hot loop (docker ptxas sm_90): 46 instructions per 32 FFMA -- the loop is fine; the losses were
exposed global latency per (ci, ky) stage (fixed by the pipeline), occupancy, and tile waste (225 = 7 x 32 + 1
and 28 x 8 + 1: ~15% of workgroups compute one useful line).

Trap found on the way: `(let ((S ..)) (dotimes+ (s ..) (< s S)))` -- Lisp reads s and S as ONE symbol; the
pipelined kernel computed all zeros until the stage count was renamed NS.

## Diagnostics (all --mode test; the table comes back as the RuntimeError)
- `diag_conv2d_accuracy.py` -- ours / reference vs a float64 conv2d, mismatch counts.
- `diag_conv2d_orders.py` -- which cuDNN kernels the reference launches (torch.profiler) and whether a
  (ci, ky, kx) or (ky, kx, ci) FMA chain reproduces it bit for bit.

## FFT lane (A100) -- `conv2d_fft.crisp`, entry `crisp_conv2d_perf.py` (Chris chose option (a), 2026-11-11)
Overlap-save on 64 x 64 tiles (V = 65 - K valid outputs per tile side), four launches: `fft_fwd` on W
(mode 1, conjugated) and on X (mode 0), `cgemm` per frequency bin, `fft_inv`.  No complex type: spectra
are planar (separate re / im arrays) and stored in a scrambled bin order shared by X, W and Y (rows
bit-reversed), so no stage unscrambles.  The twiddle table comes from the host (no libdevice).
`crisp_conv2d_perf.py` is ONE performant file for all GPUs: FFT where cc is (8, 0), conv_tiled_p elsewhere.
Both .crisp files compile as one module (package_conv2d.py `merged_source` drops the repeated def-types).

BMG: 0 mismatches vs conv2d_accurate on all 6 test shapes and all 4 benchmark shapes (contest rule), float64
samples max 2.5e-4 on the scored case.  A100 (diag_conv2d_fft.py, scored case, vs the reference):
| version | total | wfft | xfft | cgemm | ifft | mismatches |
|---|---:|---:|---:|---:|---:|---:|
| v1, 64-bit indices (leaderboard: 3.20 ms, **#7 / 23**) | 3.21 ms | 0.84 | 0.47 | 1.55 | 0.38 | 0 (max 8.9e-4, rms 1.6e-4) |
| v1, 32-bit index twins (make_fft32.py) | 3.22 ms | 0.80 | 0.46 | 1.66 | 0.34 | 0 |
| v2 "8": radix-8 transforms (gen_fft8.py -> conv2d_fft8.crisp) | 2.46 ms | 0.46 | 0.28 | 1.55 | 0.20 | 0 (rms 1.58e-4) |
| v3 "8g2": + cgemm2 (512 threads, two tile blocks share each Wf line) (**leaderboard 2.29 ms**) | 2.29 ms | 0.46 | 0.28 | 1.39 | 0.20 | 0 |
Radix-8: each 64-point FFT = 8 x 8 (two register DFT8 steps, a `def-function` returning 16 values --
spelled `=> float ... float`, not `(values ...)`), 4 barriers per tile instead of 12; spectra digit-swapped.
Shared tile r * 73 + c + c / 8 (put_temp_files_here/conv2d/banks.py): lanes on rows for row steps
(conflict-free for odd strides), on columns for column steps.
cgemm SASS (sm_80): 218 instructions per 112 FFMA, 49 of them IMAD (64-bit address math per load);
cgemm2 191 / 25 IMAD.  Each `(~ v (+ idx 2112ul))` is `gep i8 base, (idx + c) * 4` with plain mul/add, so
no constant offset folds into the load (see FOR DISCUSSION).  32-bit indices made cgemm slower.
Floors on the scored case: cgemm 0.70 ms at fp32 peak; transforms ~0.3 ms of DRAM traffic.

## FOR DISCUSSION (Chris), round 2 -- after the A100 lane reached 2.29 ms (#6; #5 is 1.40 ms)
1. **3xTF32 tensor-core cgemm** (cgemm is 1.39 of 2.29 ms; its fp32 floor is 0.70).  The Ampere
   `mma-accumulate-via-tile (16 8 8)` float (TF32) path exists, so no new instruction support -- but our
   spectra are bin-innermost (that is what makes the FFT writes and today's cgemm coalesced), and the MMA
   path stages contiguous 16 x 8 tiles.  Needs a bin-major layout or a gather-staging scheme, plus the
   big / small operand split (could be written by the forward FFT).  Endeavour-sized; maybe 0.5-0.8 ms.
2. **Codegen: element addresses that fold constant offsets.**  `(~ v (+ i 2112ul))` lowers to
   `gep i8 base, (i + 2112) * 4` with a plain mul/add, so every load pays its own 64-bit address math (25-49
   IMAD per 112 FFMA in cgemm's loop) instead of an immediate offset.  A typed
   `getelementptr inbounds float` (or nuw/nsw on the index arithmetic) would likely fold them -- a src
   change that touches every kernel, so: IR corpus + suites, your call.
3. **The complex-number endeavour, informed by this lane:** what the FFT actually used was planar float
   arrays, a 16-value `def-function` (dft8), a host twiddle table, and a complex multiply written out four
   times.  A `complex` record + `cmul`/`conj` + a DFT8 building block would cover all of it; the A|D
   convention question (Wirtinger) is untouched by the contest.

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
