# Endeavour 209 — MMA benchmarking on the B200 (tcgen05), plus the H100 re-run

Started 2026-11-06, after 208 (tcgen05) was folded.  Agreed with Chris the same day:

1. **Ladder:** tcgen05 is chapter 7's Blackwell answer, not a new rung.  Ch 7 asks "can one
   instruction do more math?"; Hopper answers wgmma, Blackwell answers tcgen05.  Each device prints
   the other's gate ("requires sm_90a" / "requires sm_100a").  The accumulator-ring kernel
   (epilogue overlapping the next tile) is optional: a possible Ch 8 or a §3 controlled pair.
2. **The B200 runs the full sweep**, §1 chapters 0-7 included, as every new device has.
3. **No deferred contenders.**  The Blackwell CUTLASS peer (SM100 collective builders, CUTLASS 4.8
   in third_party) is built now, as is the cuBLASLt block-scaled ceiling.
4. **Report:** regenerate as we go.

## Steps

| # | Step | State |
|---|------|-------|
| 1 | Harness: arch `sm_100a` on cc 10.x; CUTLASS arch from the detected device | done |
| 2 | Fixture: persistent grid, per-scratch element width; C tensormap REFUSED (D-209-2) | done |
| 3 | Fixture: microfloat operands (packed codes, scales in `:blocked-128x4`, oracle) | done |
| 4 | Crisp B200 kernels: Ch 7 tcgen05 (tf32, bf16); §2 tf32/bf16/fp16/int8/requant/NVFP4/MXFP4/MXFP8 | done (§4 fused: F-209-2) |
| 5 | Contenders: cuBLASLt block-scaled ceiling; CUTLASS SM100 peers (tf32, 16-bit, int8, block-scaled) | done |
| 6 | Local proof (below) | done |
| 7 | B200 smoke + tuning rental (`_b200_tune` + every B200 lane, small/mid sizes, --scratch) | done (round 1 2026-11-06; round 2 after BUG 157 2026-11-07, D-209-8) |
| 8 | B200 full sweep | done 2026-11-07 (87 min, ~$11.60, 83 result files; F-209-4, F-209-5) |
| 9 | H100 re-run (BUG 156 await on wgmma rings; F-209-1 A/B; F-209-4 A/B; tf32 re-measured) | done 2026-11-07 (47 min, ~$3.10): F-209-1 measured; F-209-4 narrowed; F-209-6, F-209-7 found |
| 10 | report.py: B200 device, per-generation Ch 7, block-scaled sections | done (regenerate after 8) |

## What was built (2026-11-06)

- **matmul.py**: cc 10.x -> `sm_100a`; CUTLASS `-arch` from the device; the TENSOR-CORE GATE (a
  Crisp kernel whose code uses `wgmma-` / `tcgen05-` forms prints `GATE: ... requires sm_90a /
  sm_100a` on the other generation and is not run); fixture env: fixed grid from `(global-size
  :set-to N)` (multi-workgroup only, D-209-4), `@bytes` per scratch, block-matrix operands (`ELEM=mf`,
  `MF=base:scale:vec`, `ARG_SA/_SB` by `:scales-of`); lanes: `chap7_tcgen05`, `chap7_tcgen05_bf16`,
  `matmul_b200*.crisp` in sec2_top / _bf16 / _fp16 / _int8 / sec4_int8_requant, new
  `sec2_top_nvfp4` / `_mxfp4` / `_mxfp8`, fenced `_b200_tune`; on a B200 the Sm90 CUTLASS peers
  give way to the SM100 ones (4 configs incl. the 2-SM MMA).
- **bench_harness.cu**: fixed grid; `@bytes`; block operands (codes, two scales vectors bound as
  rank-1 tensors, byte-space tensormaps); refuses a C tensormap.
- **common/**: `fill_verify.h` block-scaled oracle (D-209-3); `fill_cuda.cuh` code + scale fills;
  `cutlass_peer_sm100.cuh` (dense) and `cutlass_peer_sm100_bs.cuh` (block-scaled, sourceless
  epilogue, checks its SF size against ours); `cublaslt_blockscaled.cuh`.  Per-lane 3-line wrappers.
- **Kernels**: `scripts/crisp_bench/gen_b200.py` generates every §2 B200 kernel and the tuning
  variants from ONE template (persistent 148 x 192, accumulator ring; block lanes single acc).
- **report.py**: Ch 7 names the instruction measured (`desc_nv_by_key`); int8 is slim only without
  a peer; three block-scaled sections.

## Local proof (2026-11-06)

- All 31 B200 Crisp kernels (+ chapter 7 x 2) compile against `benchmarks/profiles/b200.crisp` at
  `sm_100a` and assemble with ptxas 12.8, 0 spills; MMA kinds checked in the PTX (tf32 / f16 / i8 /
  mxf4nvf4 / mxf4 / mxf8f6f4; fp16 idesc decodes to f16 inputs, M128 N256).  All 23 ladder kernels
  the B200 also runs assemble at `sm_100a` (one pre-existing 60-byte spill, `matmul_int8_sync`).
- `bench_harness.cu` builds for `sm_100a` and `sm_90`; the 4 dense SM100 peers + the 2-SM config
  build; the 3 cuBLASLt block-scaled ceilings build; the scale-layout inverse is exact against
  the 208 hoist's `mf_blk` on 4 shapes; `fill_verify.h` still compiles host-only (Intel fixture).
- H100 apparatus unchanged: the NVIDIA run list is identical to HEAD's (60 rows, dry walk with
  every GPU call stubbed) and `cuda_fixture_env` is identical on all 60 existing NVIDIA kernels.
- The regenerated report differs from the committed one only in chapter 7's wording on Hopper; a
  synthetic B200 result set renders every new section.
- NOT provable locally: anything at run time.  That is step 7.

## Fixture gaps found 2026-11-06 (cuda_fixture_env on specs 208/06 and 208/16)

- `global-size :set-to N` is not read: grid falls back to the default 32x64 tile.
- A `:via :tma` store's C tensormap (`8:c:16:64`) is bound as if it were B's.
- C is always 4 bytes (f32/s32) except f64 / requant: a bf16 C is neither sized nor verified.
- `matrix nvfp4` (any def-microfloat-block) is not an element type: defaults to f32.
- Scratch is sized at A/B's element width; a block kernel's code and scale rings are `uchar`
  (the metacrisp records each scratch's element type).
- `--ir-target-arch=sm_100` is refused by tcgen05 (needs `sm_100a`); the harness detects `sm_100`.
- The CUTLASS peers hard-code `-arch=sm_90a` and the Sm90 collective.

## Step 7 — the smoke + tuning rental (ready once a branch is pushed)

What runs: every B200 lane (Crisp, cuBLAS(Lt) ceiling, CUDA control, SM100 CUTLASS peers) plus the 21
`_b200_tune` variants, at N = 256, 1024, 4096, 8192, into `results/scratch/` (`--scratch`).  Every
point is verified by the fixture, so this is the first run-time proof of the fixture's block-scaled
path, the persistent grid and the tcgen05 lanes, and it picks the ring depth / shape to promote.
GPU: one B200 (`--image cu128`), `--max-minutes 120` => at most **$15.98** at $7.99/hr.  Wasted if:
the branch is not pushed (the pod clones it), or the compiler build fails on the pod (LLVM 21 is
installed by bench-on-pod; 208 never built the compiler ON a B200 pod -- it shipped PTX).

    ./scripts/pod-session.sh --gpu "NVIDIA B200" --image cu128 --max-minutes 120 -- \
      bash -c 'scripts/bench-on-pod.sh {host} {port} <branch> ~/.ssh/id_ed25519 256,1024,4096,8192 50 \
                 --bench=matmul --scratch \
                 --chapters=_b200_tune,chap7_tcgen05,chap7_tcgen05_bf16,sec2_top,sec2_top_bf16,sec2_top_fp16,sec2_top_int8,sec4_int8_requant,sec2_top_nvfp4,sec2_top_mxfp4,sec2_top_mxfp8 &&
               scripts/pull-runpod-results.sh {host} {port}'

## Step 7 results — smoke + tuning, B200, 2026-11-06 (34 min, ~$4.60, pod confirmed gone)

66 sweeps, **every point verified** (fixture block-scaled path, fixed grid, every tcgen05 lane, both
CUTLASS SM100 peers, cuBLASLt NVFP4 / MXFP8).  Table: put_temp_files_here/209/smoke-summary.txt
(results: put_temp_files_here/209/smoke/, scratch only).  TFLOPS (TOPS for int8) at N=8192:

| lane | Crisp persistent r4 | Crisp tile grid r4 | Crisp Ch 7 (tile grid r2) | cuBLAS(Lt) | best CUTLASS |
|---|---:|---:|---:|---:|---:|
| tf32 | 293 | 717 | 767 | 1036 | 964 (256x256 2-SM) |
| bf16 | 543 | 1224 | 1304 | 1993 | 1770 (2-SM) |
| fp16 | 543 | 1224 | — | 1993 | 1808 (2-SM) |
| int8 | 984 | 2048 | — | 3727 | 3442 (2-SM) |
| requant | 574 | 1222 | — | 4125 | — |
| nvfp4 | 1066 (r4) | not built | — | 5532 | 3434 (2-SM) |
| mxfp4 | 1272 (r4) | not built | — | **no algorithm** (status 7, CUDA 12.8) | 3587 (2-SM) |
| mxfp8 | 899 (r4) | not built | — | 3080 | 1659 (2-SM) |

**F-209-3 — the persistent kernels lose most of their workgroups.**  tile-stride strides each dimension
by its OWN group count (`src/analysis/control.lisp`, START_i = GID_i*TS_i, STRIDE_i = TS_i*NG_i).
A persistent 1-D launch of 148 workgroups has NG_1 = 1, so only the workgroups whose x id < M/128 own a row of
tiles: 32 of 148 work at 4096, 64 at 8192.  The ratios match (tile grid / persistent = 3.8x at
4096, 2.3x at 8192).  208's specs never saw it: 2 workgroups, 2 row-tiles.  Correct results, silent
loss -- a trap for any persistent author.  **BUG 157, fixed in the overlay 2026-11-06** (Chris
chose the compiler fix; chapter 6 takes the new rule too and is re-measured, option (i)): a rank-2
compile-time tile-stride in a kernel with a fixed 1-D global size takes endeavour 144's flat
column-strip walk (`%expand-tile-stride-swizzled`) at the profile's strip width or 1.  Specs 01 / 02
here (01 fails with `CRISP_TILE_VISIT=linear`); IR corpus moved only fixed-size rank-2 kernels
(28 jobs incl. matrix-multiply-tile-stride and 208's tcgen05 specs, all explained); suites green
(1807 / 492).  Tuning round 2 sweeps the strip width through a `;; BENCH-TILE-VISIT: grouped:N`
line the harness exports as `CRISP_TILE_VISIT` for that kernel only.  D-209-4 stays until chapter
6's one-workgroup declaration itself is fixed (F-209-1): honoring it would still launch one
workgroup, whatever the walk.

Other readings: Ch 7 (ring 2: 96 KB of ring, so two workgroups per SM) beats the ring-4 tile grid (one
workgroup per SM) -- a second resident workgroup overlaps one tile's epilogue with another's mainloop, which is
what the accumulator ring was meant to do.  The 2-SM CUTLASS configs win at 4096-8192 almost
everywhere; Crisp has no cta_group::2.  Below 4096 Crisp trails CUTLASS 2x (bf16 1024: 78 vs 174).

## Step 7b results — tuning round 2 after BUG 157, B200, 2026-11-07 (14 min, ~$1.90, pod confirmed gone)

`round2-on-pod.sh` on the pushed branch (7067c201): the 58 `_b200_tune` variants + Ch 7 x 2 at
N = 1024 / 4096 / 8192 / 16384, every point verified; then 208-tcgen05 on metal (**39 / 39**, its
codegen moved with BUG 157) and these 209 specs on CUDA (**2 / 2** -- the flat walk verified on
NVIDIA hardware, not only the BMG).  Table: put_temp_files_here/209/round2-summary.txt.  TFLOPS
(TOPS for int8) at 8192 / 16384; "p" = persistent, rN = ring depth, wN = strip width:

| lane | best persistent | best tile grid | Ch 7 | round-1 persistent (8192) | cuBLAS(Lt) 8192 | best CUTLASS 8192 |
|---|---:|---:|---:|---:|---:|---:|
| tf32 | 660 / 697 (r4_w4) | **766 / 773** (r2) | 755 / 767 | 293 | 1036 | 964 |
| bf16 | 1208 / 1338 (r4_w4) | **1300 / 1439** (r2) | 1293 / 1436 | 543 | 1993 | 1770 |
| fp16 | 1208 / 1340 (r4_w4) | **1304 / 1474** (r2) | — | 543 | 1993 | 1808 |
| int8 | 2113 / 2529 (r4_w4) | **2111 / 2606** (r2) | — | 984 | 3727 | 3442 |
| requant | 1252 / 1779 (r4) | **1234 / 1879** (r2) | — | 574 | 4125 | — |
| nvfp4 | **2277 / 2870** (r4_w2) | 2131 / 2698 (r3) | — | 1066 | 5532 | 3434 |
| mxfp4 | **2662 / 3548** (r4_w2) | 2474 / 2968 (r3) | — | 1272 | no algorithm | 3587 |
| mxfp8 | **1868 / 2274** (r4_w2) | 1659 / 1811 (r3) | — | 899 | 3080 | 1659 |

Readings:
- **BUG 157 is worth 2.1-2.6x on metal.**  Same kernel, same ring (p_r4_w1 vs round 1's persistent
  r4), only the walk changed: tf32 293 -> 652, bf16 543 -> 1183, int8 984 -> 2052 at 8192.
- **Dense lanes: the tile grid at ring 2 wins** at 4096 / 8192 / 16384 (int8 ties p_r4_w4 at 8192;
  requant's persistent leads by 1.4% at 8192 only).  Two resident workgroups per SM overlap one
  tile's epilogue with the other's mainloop, and beat one persistent workgroup with a 2-slot
  accumulator ring: tf32 +11-16%, bf16 / fp16 +8-10%, int8 +0-3%.  It is chapter 7's shape, and it measures the same as chapter 7.
- **Block lanes: persistent ring 4 wins** by 7-13% at 8192 and 6-26% at 16384.  Theory, unmeasured:
  their accumulator plus scale columns exceed half of tensor memory, so a second tile-grid
  workgroup cannot co-reside (D-209-5's reason for ONE accumulator).  Strip width 2 vs 1 is noise
  at 8192 and +1..8% at 16384.
- **Strip width** helps the dense persistent kernels at 16384 (bf16 w1 1232 -> w4 1338), barely at 8192.
- **Ring depth 4 > 3** for every persistent kernel.
- Against the peers at 8192: tf32 74% of cuBLAS, bf16/fp16 65%, int8 57%, nvfp4 41%, mxfp8 61%
  (and ahead of the 128-code-K-tile CUTLASS peer, D-209-6), mxfp4 74% of CUTLASS.  The 16384 peers
  are first measured in step 8.
- N = 1024 is 40-90 TFLOPS for every variant: 64 tiles on 148 SMs; launch- and latency-bound.

Promoted (D-209-8): `gen_b200.py`'s defaults; each lane kernel is now byte-identical to its winner.

## Step 9 results — H100 re-run, 2026-11-07 (47 min, ~$3.10, pod confirmed gone)

A/B pairs (scratch, put_temp_files_here/209/step9-ab-summary.txt) then the full sweep (75 result
files).  TFLOPS (TOPS for int8):

**F-209-1 measured -- the surplus grid costs up to 29%.**  Identical PTX per pair, grid only:

| pair (surplus) | 2048 | 4096 | 8192 | 16384 |
|---|---:|---:|---:|---:|
| chap5 tf32 (2x): declared / undeclared | 91.1 / 52.0 | 96.6 / 82.9 | 76.9 / 67.0 | 60.5 / 59.8 |
| sec2 tf32 (8x) | 183.8 / 180.3 | 200.5 / 199.9 | 186.6 / 185.1 | 185.7 / 186.6 |
| sec2 bf16 (8x) | 326.9 / 311.0 | 375.7 / 363.8 | 362.3 / 355.0 | 366.8 / 363.1 |
| 2wg_deep bf16 (16x) | 475.1 / 424.6 | 726.5 / 659.4 | 800.1 / 643.8 | 641.9 / 629.8 |
| int8 (16x) | 680.4 / 581.4 | 1187.5 / 1020.7 | 1442.2 / 1117.0 | 1268.9 / 1245.3 |

Not proportional to the surplus (sec2 tf32 at 8x barely moves): it costs where the idle
workgroups crowd out a second resident working one.  D-209-9 stands.

**F-209-4 is NOT B200-specific and NOT the walk.**  On the H100, chapter 6 f64 fails on BUG 157's
flat walk (1024..8192, err 3-6), on the per-axis walk (`ws_linear`: 4096 and 16384, err 7 / 6), and
as the declared kernel in the full sweep (1024 / 2048 / 4096, err 3); sec2_top_f64 warpspec fails at
1024..8192.  Every walk, both GPUs, different sizes from run to run: a race in this kernel family or
in how it is compiled.  T3 (Blackwell) and the walk are ruled out; T2 (BUG 156's per-slot phase
bits -- this is one of the 13 kernels BUG 156 moved) is the lead; T1 (a latent race in the kernel,
with the old H100 pass predating today's GPU fill) is still open.  Chapter 6 tf32 / bf16 pass.

**F-209-6 -- sec3 cluster kernels fail to LAUNCH through the fixture** (CUDA error 1, invalid
argument, every size; both Crisp kernels; empty result files saved, "NO ROW" printed).  Not D-209-9:
the old H100 / H200 sec3 rows were the pre-fixture hoisted harness, so this is their first fixture
run.  Cause (from the code, not yet run): the kernel has 32 B of STATIC shared memory (two mbarriers,
`.visible .shared __crisp_mbar_1/2`) on top of exactly 49152 B dynamic.  The driver's default dynamic
limit is 48 KB minus static, so the launch needs the opt-in; the fixture opts in only when DYNAMIC
alone exceeds 48 KB, while the hoisted harness always calls cuFuncSetAttribute(MAX_DYNAMIC, 49152).
No other fixture kernel has static shared memory.  The fixture's dry-run sits after cuInit (its
comment says before), so this could not be checked without a GPU.

**F-209-7 -- the single-warpgroup wgmma kernels read 30-37% below their 09-12 numbers.**  chap7_wgmma /
sec2_top bf16 at 8192: 569 -> 361; tf32 at 8192: 274 -> 187 (and 2048: 260 -> 184).  Meanwhile
2wg_deep rose (614 -> 761) and int8 / requant rose.  The 09-12 numbers were the OLD hoisted harness
and a two-month-older compiler, so the drop is confounded: apparatus, compiler drift, and BUG 156
(which moved these kernels and was first run on Hopper here).  The A/B shows it is not the grid
(sec2 bf16 declared 362 / undeclared 355).  The asymmetry (2wg_deep up under the same apparatus
change) argues against the apparatus being the whole story.  Not yet attributed.

## Findings

**F-209-1 — kernels with no declared global-size are launched on a 32 x 64 tile grid.**  The fixture
takes its grid from the metacrisp's `:tile-shape`, which exists only when the kernel declares
`(global-size :derive-from C :strategy :strided)` (then it is inferred from tile-stride, endeavour
143).  27 NVIDIA benchmark kernels declare no global-size, so the fixture uses its default
`CRISP_MATMUL_TILE=32,64`: for a 64 x 256 tile that is 8x the workgroups it has tiles for, for 128 x 256 it
is 16x.  tile-stride strides over whatever grid it gets, so the extra workgroups find no tile and exit --
results are CORRECT, which is why nothing caught it -- but each still runs its prologue, and the
idle ones dispatch AFTER the working ones (blockIdx order), on SMs a 192 KB ring lets hold one workgroup.
Affected H100 rows: chap5 (2x), chap7_wgmma / _bf16 (8x), sec2_top tf32 / bf16 / fp16 (8x; the
2wg_deep variants 16x), sec2_top_int8 (16x; sync 2x / w8 8x), sec4_int8_requant (16x), sec3, sec4
fused (4-8x).  The f64 64 x 32 kernels get the right workgroup count with the axes mismatched.  Size of
the effect: unmeasured -- an A/B on the H100 re-run (step 9).  Every B200 kernel declares its grid.
Survey: put_temp_files_here/209/f209-1-scope.txt.

**F-209-2 — §4 fused epilogues have no B200 Crisp kernel.**  `map-elements!` on a tcgen05
accumulator is refused ("unsupported target type TCGEN05-ACC-F32-128X256"; implemented for MMA
fragments and register tiles).  The sec4_fused_relu / _custom Crisp kernels are wgmma, so on a B200
they print the gate and only the cuBLAS(Lt) rows run.  Closing it is a compiler feature (lower
`map-elements!` on a tensor-memory accumulator as ld / apply / st, or fuse it into the epilogue's
store) -- Chris's call whether it belongs to this endeavour.  sec3_cluster_multicast is gated the
same way (its kernels are wgmma; 152 found multicast a negative on Hopper).

**F-209-4 — chapter 6 f64 (warp-specialized) FAILS verification on the B200 at N = 1024..8192.**
Step 8: `chap6_warp_specialization_f64` and `sec2_top_f64 Crisp_V_warpspec` (same kernel family)
have max_abs_err 1-9 at 1024 / 2048 / 4096 / 8192; 256, 512, 16384, 32768 pass (err ~1e-13..1e-11).
H100 (old run, before BUG 156 / BUG 157) passed every size with err 0.  Every other f64 chapter,
and chapter 6 tf32 / bf16, pass on the B200.  What is known:
- BUG 157 MOVES this kernel: it declares `:set-to 96` (one workgroup), so it now takes the flat
  walk, and the PTX differs from `CRISP_TILE_VISIT=linear` (2244 lines).
- The fixture launches it on a (N/32) x (N/64) grid (D-209-4, F-209-1) for (N/64) x (N/32) tiles
  of 64 x 32.  OLD walk: half the workgroups idle, the rest do 2 tiles.  FLAT walk: every
  workgroup does exactly 1 tile (the flatten uses both ids and both counts, so coverage holds).
- Integer-sized errors against otherwise-exact results = a few partial products lost or doubled,
  not a missed tile (that would be off by the whole dot product).  Shape of a ring race.
Theories, untested: (T1) a latent race in chapter 6 f64's producer / consumer ring, exposed by
twice as many working workgroups (more residency, more memory pressure); (T2) BUG 156's per-slot
phase bits are wrong for this ring shape (H100's pass predates them); (T3) Blackwell-specific
timing.  BMG has no f64 lane, so it cannot be tested locally.  Proposed test, folded into step 9's
H100 rental: both kernels at 256..8192 with the flat walk and with `CRISP_TILE_VISIT=linear`.
H100 flat fails + linear passes -> T1 / T2 (walk-exposed, not B200); H100 flat passes -> T3 or
needs a B200 A/B.

**F-209-5 — report.py §2 publishes unverified points.**  The §2 emitter's `_best`, `_best_named`
and variant gather never read `configuration.verified` (§1 and the 16-bit rollup already drop
them -- "UNVERIFIED POINTS ARE NOT NUMBERS").  So the regenerated report shows F-209-4's failing
points as the B200 f64 envelope and best single.  It also shows, and has for months, the H100 /
H200 tf32 points at N >= 4096 from the pre-fixture path (12 iterations, no check: verified false,
max_abs_err None) -- step 9 re-measures those through the fixture.  Proposed fix: filter in those
three places.

## Decisions (D-209-n)

- **D-209-1.** B200 kernels live beside their H100 twins in the existing lane directories
  (`sec2_top/matmul_b200.crisp`, ...), selected by the detected arch as 207 did for int8; the
  chapter-7 answer gets its own directories (`chap7_tcgen05`, `chap7_tcgen05_bf16`), so the
  report can place them as chapter 7.
- **D-209-2.** Every B200 §2 C is fp32 (s32 for int8; s8 for requant), as every contender's is.
  So the fixture REFUSES a C tensormap (`:via :tma` store) rather than binding one: a 16-bit
  TMA-stored C is not a comparable row.
- **D-209-3.** The block-scaled oracle uses power-of-two scales that vary by row AND K-block,
  `2^((r + 2kb) % 3 - 1)`: unit scales would pass a kernel that ignores them.
- **D-209-4.** The fixture launches `(global-size :set-to N)` as declared only when N names MORE
  than one workgroup.  Chapter 6 (tf32 / bf16 / f64) declares one workgroup (`:set-to 96`, block 96) and has
  always been launched on a tile grid; honoring it would serialize those rows.  Pending F-209-1.
- **D-209-5.** B200 §2 kernels are PERSISTENT (one workgroup per SM, 148 x 192) with a 2-slot
  tensor-memory accumulator ring, ring depth 4; the block lanes keep ONE accumulator (two
  256-column slots plus the scales' columns exceed 512) and ring depth 3.  These are starting
  points: `_b200_tune` measures ring 3 / 4 and the tile-grid shape, and the winner is promoted.
- **D-209-6.** The block-scaled CUTLASS peer runs with NO source operand (`ElementC = void`, D =
  A.B): with an fp32 C the epilogue carve-out leaves no shared memory for the mainloop.  Same
  computation; it needs `--expt-relaxed-constexpr` (CUTLASS's CMake passes it) and a 128-code K tile
  for MXFP8.
- **D-209-8.** (2026-11-07, round 2) The dense B200 lanes (tf32 / bf16 / fp16 / int8 / requant) are
  TILE-GRID kernels at ring depth 2 (two workgroups per SM, one accumulator); the block lanes
  (NVFP4 / MXFP4 / MXFP8) stay PERSISTENT at ring depth 4, strip width 2.  Supersedes D-209-5's
  starting points.  All eight compile and pass ptxas for sm_100a with 0 spills (102 / 106-108 / 64
  registers).
- **D-209-9.** (2026-11-07, F-209-1) Every NVIDIA benchmark kernel DECLARES its tile grid,
  `(global-size :derive-from C :strategy :strided)`: inserted in the 25 that had none, and it
  replaces chapter 6's `(global-size :set-to 96)` (four kernels: chapter 6 tf32 / bf16 / f64 and
  sec2_top_f64 warpspec), which named ONE workgroup -- the thread count written as the grid.  Local
  proof (put_temp_files_here/209/f2091/): the 25 compile to byte-identical PTX for sm_90a, so the
  launch grid is the only change; the 4 chapter 6 kernels leave BUG 157's flat walk for the per-axis
  walk on a matched grid; every metacrisp now carries the tile-stride's `:tile-shape`.  The A/B is
  measured, not assumed: fenced `_f2091_ab{,_bf16,_int8}/` hold `<x>_declared` / `<x>_undeclared`
  pairs (sec2 tf32 8x, chap5 2x, sec2 bf16 8x, 2wg_deep 16x, int8 16x surplus), identical PTX per pair.
  D-209-4 is now inert (no published kernel declares a one-workgroup `:set-to`); it stays as a guard.
- **D-209-10.** (2026-11-07, F-209-2) `map-elements!` on a tcgen05 accumulator is a compiler
  feature with its own specs and A|D coverage, so it is endeavour 210 (plan/scramble.md, Tiles /
  tensors), not a 209 step.  §4's B200 rows stay cuBLASLt-only until then.
- **D-209-11.** (2026-11-07, F-209-5, Chris) No report filter: the fix is SOLID DATA.  Step 9
  re-measures the H100 tf32 points through the fixture; F-209-4's B200 points are re-measured once
  it is understood.  Until then the regenerated report carries those points.
- **D-209-12.** (2026-11-07, F-209-4) The F-209-4 A/B rides step 9: fenced `_f2094_f64_ab/` holds
  chapter 6 f64 exactly as step 8 ran it (`ws_flat`) and the same kernel with
  `;; BENCH-TILE-VISIT: linear` (`ws_linear`, different PTX).  Both launch on the 32 x 64 default
  grid, as in step 8.  The declared chapter 6 f64 (D-209-9) is the third arm, in the full sweep.
- **D-209-7.** The B200's int8 lane gets a CUTLASS SM100 peer (the builder takes `int8_t`); the
  Hopper int8 lane still has none.  The report shows a Peer column only where one was measured.

