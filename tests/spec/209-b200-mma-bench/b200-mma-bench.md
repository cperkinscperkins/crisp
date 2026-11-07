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
| 7 | B200 smoke + tuning rental (`_b200_tune` + every B200 lane, small/mid sizes, --scratch) | needs a pushed branch |
| 8 | B200 full sweep | |
| 9 | H100 re-run (BUG 156 await on wgmma rings; F-209-1 A/B) | |
| 10 | report.py: B200 device, per-generation Ch 7, block-scaled sections | done (regenerate after 8) |

## What was built (2026-11-06)

- **matmul.py**: cc 10.x -> `sm_100a`; CUTLASS `-arch` from the device; the TENSOR-CORE GATE (a
  Crisp kernel whose code uses `wgmma-` / `tcgen05-` forms prints `GATE: ... requires sm_90a /
  sm_100a` on the other generation and is not run); fixture env: fixed grid from `(global-size
  :set-to N)` (multi-CTA only, D-209-4), `@bytes` per scratch, block-matrix operands (`ELEM=mf`,
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

## Findings

**F-209-1 — kernels with no declared global-size are launched on a 32 x 64 tile grid.**  The fixture
takes its grid from the metacrisp's `:tile-shape`, which exists only when the kernel declares
`(global-size :derive-from C :strategy :strided)` (then it is inferred from tile-stride, endeavour
143).  27 NVIDIA benchmark kernels declare no global-size, so the fixture uses its default
`CRISP_MATMUL_TILE=32,64`: for a 64 x 256 tile that is 8x the CTAs it has tiles for, for 128 x 256 it
is 16x.  tile-stride strides over whatever grid it gets, so the extra CTAs find no tile and exit --
results are CORRECT, which is why nothing caught it -- but each still runs its prologue, and the
idle ones dispatch AFTER the working ones (blockIdx order), on SMs a 192 KB ring lets hold one CTA.
Affected H100 rows: chap5 (2x), chap7_wgmma / _bf16 (8x), sec2_top tf32 / bf16 / fp16 (8x; the
2wg_deep variants 16x), sec2_top_int8 (16x; sync 2x / w8 8x), sec4_int8_requant (16x), sec3, sec4
fused (4-8x).  The f64 64 x 32 kernels get the right CTA count with the axes mismatched.  Size of
the effect: unmeasured -- an A/B on the H100 re-run (step 9).  Every B200 kernel declares its grid.
Survey: put_temp_files_here/209/f209-1-scope.txt.

**F-209-2 — §4 fused epilogues have no B200 Crisp kernel.**  `map-elements!` on a tcgen05
accumulator is refused ("unsupported target type TCGEN05-ACC-F32-128X256"; implemented for MMA
fragments and register tiles).  The sec4_fused_relu / _custom Crisp kernels are wgmma, so on a B200
they print the gate and only the cuBLAS(Lt) rows run.  Closing it is a compiler feature (lower
`map-elements!` on a tensor-memory accumulator as ld / apply / st, or fuse it into the epilogue's
store) -- Chris's call whether it belongs to this endeavour.  sec3_cluster_multicast is gated the
same way (its kernels are wgmma; 152 found multicast a negative on Hopper).

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
  than one CTA.  Chapter 6 (tf32 / bf16 / f64) declares one CTA (`:set-to 96`, block 96) and has
  always been launched on a tile grid; honoring it would serialize those rows.  Pending F-209-1.
- **D-209-5.** B200 §2 kernels are PERSISTENT (one CTA per SM, 148 x 192) with a 2-slot
  tensor-memory accumulator ring, ring depth 4; the block lanes keep ONE accumulator (two
  256-column slots plus the scales' columns exceed 512) and ring depth 3.  These are starting
  points: `_b200_tune` measures ring 3 / 4 and the tile-grid shape, and the winner is promoted.
- **D-209-6.** The block-scaled CUTLASS peer runs with NO source operand (`ElementC = void`, D =
  A.B): with an fp32 C the epilogue carve-out leaves no shared memory for the mainloop.  Same
  computation; it needs `--expt-relaxed-constexpr` (CUTLASS's CMake passes it) and a 128-code K tile
  for MXFP8.
- **D-209-7.** The B200's int8 lane gets a CUTLASS SM100 peer (the builder takes `int8_t`); the
  Hopper int8 lane still has none.  The report shows a Peer column only where one was measured.

