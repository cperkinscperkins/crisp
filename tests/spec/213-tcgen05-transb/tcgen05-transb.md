# Endeavour 213 -- tcgen05 `:b-major :mn` (a `(K N)` B read MN-major)

2026-11-11, branch gpumode-convolv.  The Blackwell twin of endeavour 198 (wgmma `:b-major :mn`).

## Why
GPU MODE matmul_v2's `b` is `(K N)`, N-contiguous -- Major::MN for the tensor core.  `tcgen05` read B only
as `(N K)`, so the B200 entry (v6) ran a transpose kernel first.  B200 diag (clear_l2_cache, scored
4096 x 5120 x 4096): full v6 250.9 us = transpose 33.8 + tcgen05 kernel 226.3; cuBLAS 139.3.

## What
`(tcgen05-accumulate-via-tile (128 N K) D A B :swizzle :128b :b-major :mn [:on-complete BAR])` with B a
`(K N)` half / bfloat16 tile.  Three pieces, all in the overlay (fold targets marked):
- **analyzer** (`analyze-tcgen05-accumulate-via-tile-base`, src/mma.lisp): `:b-major` is `:k` or `:mn`;
  `:mn` needs 16-bit operands and a `(K N)` B tile; a `(K N)` tile without the option is refused with a
  hint.  The flag reaches the `%tcgen05-mma` node through `*213-tcgen05-b-mn*` (plist `:b-mn`).
- **instruction descriptor** (`%208-gen-mma-plain`, src/codegen.lisp): bit 16 (transpose B).
- **B's shared-memory descriptor** (`%213-smem-desc-mn`): 198's MN-major layout (LBO = one 64-wide TMA
  box = K x 128 B = 8192, SBO 1024) with the Blackwell version (bit 46) and SWIZZLE_128B (2 at [61,64));
  the k16 slice advances 16 rows = 2048 bytes.
The TMA side needed nothing: `load-tile` already issues a wide `(K N)` tile as 64-wide boxes (198).

## Specs
| spec | checks |
|---|---|
| 01-tcgen05-transb-fp16 | `validate-ptx-tcgen05-transb`: 4 kind::f16 MMAs, idesc 136380432, MN desc 4611756662083026944 (A keeps 4611756662049538048), 3 TMA copies |
| 02-tcgen05-transb-ring | `validate-ptx-tcgen05-transb-ring`: the contest kernel's shape -- idesc 138477584, MN desc, 5 TMA copies |
| errors/01-04 | tf32 operand; `(N K)` tile under `:mn`; unknown value; `(K N)` tile without the option |
Validators live in overlays/spec-runner-overlay.lisp (fold target tests/run-specs.lisp).

## Metal (B200, GPU MODE matmul_v2 -- exact match against cuBLAS required)
- `contests/gpu-mode/06-matmul-v2/matmul_b200_tcgen05_mn.crisp` = v6's kernel with B `(K N)` and
  `:b-major :mn`; `crisp_matmul_v7.py`.
- test 970695: all 5 pass (256^3 goes through the tcgen05 path).  leaderboard 970696: **230.2 us**
  (v6 265.4 us), every benchmark exact.  Rank 48 / 53 (unchanged; #47 is 201 us, median 114).

## Not done / next (for Chris)
- The rest of the B200 gap is structural: the leaders use 2-SM MMA (`cta_group::2`, 256-row tiles) with
  persistent / cluster scheduling; Crisp has neither.  At the scored size our kernel runs at ~760 TFLOPS
  (1262 at 8192^3): 640 tiles on 148 SMs and short K per tile.
- `:a-major :mn` (bit 15) would be the same three pieces for A; nothing needs it yet.
- Generated docs (reference, call graph, globals, specials) are regenerated at the fold.
