# Endeavour 215 -- 16-byte epilogue stores for tcgen05 accumulators

2026-11-11, branch gpumode-convolv.  Overlay (not folded).

## Why
The B200 matmul_v2 study (contests/gpu-mode/06-matmul-v2/README.md, after 214 was parked) priced v7's
226 us on the scored 4096 x 5120 x 4096 one piece at a time.  Removing the epilogue's stores took it
to 147.5 us: a THIRD of the kernel, and not bandwidth (C is 42 MB, ~5 us of HBM).  The tcgen05 32x32b
layout gives each thread a whole accumulator ROW, but `store-tile` wrote it as endeavour 197's packed
pairs -- 128 `st.global.b32` per thread for a 256-column tile, each warp instruction touching 32 rows.
Regrouping them into `st.global.v4.b32` by hand (`pair_probe/make_wide_stores.py`) gave 171.0 us, exact.

## What
`%tcgen05-store-rewrite-origin` (src/mma.lisp) gets a wide arm in front of the pair arm.  Per 32-column
chunk:

| arm | guard (run-time) | stores per 32 elements |
|---|---|---|
| wide (new) | `(%run-ok-p P0 P1)`: P1 one element past P0 (so the row's stride is 1) and P0 16-byte aligned | 4 `%store-run`s of 8: 16-bit C 4 x `st.global.v4.b32`; f32 C 8 x `st.global.v4.b32` (LLVM 21 prints f32 as .b32) |
| pair (197) | `(%pair-ok-p P0 P1)` | 16 `%store-pair`s |
| scalar | -- | 32 `set!`s |

New internal forms (no language surface, so no error specs):
- `(%run-ok-p P0 P1)` -> `semantic-run-ok-p`; `(%store-run P0 .. P7 V0 .. V7)` -> `semantic-store-run`, which
  falls back to plain `set!`s when the values do not already have the element type (197's rule, single-value
  types per 210).
- Both structs `:include` the 197 ones (`semantic-pair-ok-p`, `semantic-store-pair`), so the two core
  etypecases (`semantic-node-type`, `semantic-node-source-location`) take them unchanged; only
  `generate-node-ir` has new, more specific methods.  Registered by redefining
  `register-197-pair-store-analyzers` (it runs inside `initialize-compiler`).
- Codegen: `%store-run` stores `<16/bytes x T>` vectors aligned to 16 at element offsets `k * 16/bytes`.

Every tcgen05 `store-tile` / `store-tile-at` takes the new arm -- `:transformF`, conversions, derived integer
accumulators -- since they all go through this one rewrite.  wgmma is unaffected: a wgmma fragment owns
only two adjacent columns per thread.

## Specs
| spec | checks |
|---|---|
| 01-tcgen05-store-f32-v4 | `validate-ptx-tcgen05-vector-stores-f32`: 32 `st.global.v4.b32`; pair (`st.global.v2.b32`, or `st.global.b64` -- BUG 162) and scalar arms present |
| 02-tcgen05-store-f16-v4 | `validate-ptx-tcgen05-vector-stores-f16`: 16 `st.global.v4.b32`; pair (`st.global.b32`) and scalar (`st.global.b16`) arms present |
Both carry 208's `TEST-HOIST[CUDA]` metal check (runs where a B200 is present).  Validators live in
overlays/spec-runner-overlay.lisp (fold target tests/run-specs.lisp).  Checked by hand: the guard is
`and.b64 .., 15`; a chunk's four v4 stores sit at +0/+16/+32/+48; `cvt.rn.f16x2.f32 d, e1, e0` puts
element 0 in the low half, i.e. memory order.

**BUG 162 (found here, not caused here).**  Run after 210's two :transformF specs in the same image, spec 01
compiles to different, worse PTX (325 vs 69 .b64 registers; the pair arm as packed `st.global.b64`) than run
alone.  The exe is a fresh process per file, so submissions are unaffected.  01's validator accepts either
spelling of the 8-byte pair store until BUG 162 is found.

## Metal (popcorn B200; matmul_v2 requires an exact match against cuBLAS)
Diag 970772 (`contests/gpu-mode/06-matmul-v2/build_diag_b200_215.py`), the kernels built by the compiler with
this overlay, all arms exact (bad = 0) -- including both fallbacks, forced by carving a contiguous C out of a
larger buffer at +2 bytes (scalar arm) and +4 bytes (pair arm):

| arm | 4096 x 5120 x 4096 (scored) | 9472 x 2048 x 4096 | 8192^3 |
|---|---:|---:|---:|
| v7 before 215 | 226 | 161 | 872 |
| **v7, 16-byte stores** | **175.1** | **123.9** | **763.1** |
| v7, C at +4 B (pair arm) | 256.9 | 177.1 | 973.9 |
| v7, C at +2 B (scalar arm) | 468.0 | 298.0 | 1356.8 |
| **128 x 128 tile, 16-byte stores** | **152.6** | 150.6 | 941.1 |
| cuBLAS | 118.8 | 98.3 | 647.2 |

The compiler's version beats the hand-edited PTX that priced it (787.5 us at 8192^3).  The fallbacks cost
what they should and stay exact.

**matmul v9** (`crisp_matmul_v9.py`: the B200 picks 128 x 256 or 128 x 128 by wave fill, see
`DISPATCH_V9`): test 970773 passed; leaderboard 970774 **156.1 us** (public; secret 154.7) -- v7 was 230.2.
Rank **41 / 53** (was 48; #40 155.4, #31 115.0).
