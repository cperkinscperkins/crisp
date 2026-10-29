# Endeavour 197 -- packed accumulator stores

Branch `matmul-contest`, 2026-10-28.  Follows 196 (`../196-matmul-contest/matmul-contest.md`, last section).

## Why

Timing probes on the H100 contest kernel (`2wg_deep`, 4096x5120x4096) found the epilogue was **23% of the
kernel**: 72 of 310 us, 128 scalar `st.global.b16` per thread, exposed (1 CTA/SM).  A hand-packed PTX arm
(each column pair -> one 4-byte store) ran 304 -> 252 us, bit-exact.  wgmma wait depth 1 was worth nothing.

## The plan (agreed 2026-10-28)

1. Packed pair stores in the accumulator store lowerings -- wgmma (this rung set), then `mma.sync`.
2. Persistent launch.  Proposed: in Crisp, not the contest packager -- `tile-stride` over a 1-D grid
   walking the linearised tile space (balanced; also fixes the L0 1-D-grid serialisation trap).  To confirm.
3. wgmma transB (the 39 us B transpose).
4. Later: `stmatrix` + TMA-store epilogue; then the mainloop.

## Mechanism (step 1)

Two internal forms, emitted only by the lowering:

- `(%pair-ok-p P0 P1)` -> int: `addr(P1) - addr(P0) == elem-bytes` and `addr(P0) % (2 * elem-bytes) == 0`.
  Pointer arithmetic on the two element addresses, so it covers strides AND the tensor's base offset
  (which Crisp cannot see -- no `offsets~`).  A non-packable element type analyses to literal 0.
- `(%store-pair P0 P1 LO HI)` -> one `store <2 x T>` at P0, align 2 x elem-bytes.  If LO / HI do not
  already have P0's element type, it analyses as `(progn (set! P0 LO) (set! P1 HI))`, so conversions and
  type errors stay set!'s own.

`%wgmma-store-rewrite-origin` (both store-tile spellings route through it) emits
`(if (%pair-ok-p first-pair) (progn pair-stores...) (progn the-old-scalar-stores...))`.  ONE test per
thread covers every pair: the thread's other pairs are 8k columns and/or 8 rows away, i.e. an even number
of elements on both axes once the first pair is adjacent (unit last stride) and 2-element aligned.

PTX: half / bf16 pairs -> `st.global.v2.b16`; float pairs -> `st.global.v2.b32` (NVPTX prints float
stores bit-typed).  The scalar fallback stays in the PTX (twice the epilogue code; it never runs for an
aligned contiguous C).

## Decisions

| # | decision |
|---|---|
| D-197-1 | A run-time guard, not an assumption: C's base offset is invisible to Crisp, and the contest's `c` could in principle be a view.  The guard costs ~4 integer ops per thread per store-tile. |
| D-197-2 | Two new semantic structs, defined in the overlay (a NEW defstruct appends safely); `semantic-node-type` / `-source-location` extended by wrapper (fold = two etypecase clauses each). |
| D-197-3 | The fallback reuses the exact pre-197 scalar emission, so a failed guard is byte-for-byte the old behaviour. |
| D-197-4 | mma.sync guards per fragment, wgmma per store (see below). |
| D-197-5 | NVPTX prints float stores bit-typed (`st.global.b32`, `.v2.b32`); the 197 validators match both spellings.  196's no-f32-store check looks for `.f32` only -- weaker than it reads, left as is. |

## Rungs

| rung | pins |
|---|---|
| 01 | wgmma `store-tile-at (to-half D)`: `st.global.v2.b16` present, scalar `b16` fallback present, 196's round-to-nearest / no-f32 checks |
| 02 | wgmma f32 `store-tile-at D`: `st.global.v2.b32`, scalar fallback; runs under --differentiate |
| 03 | grid-index `store-tile (to-bfloat16 D)`: the other entry point, the other 16-bit type |
| 04 | mma.sync register tile `store-tile (to-half C-tile)`: per fragment 2 x `st.global.v2.b16` + the 4 scalar fallback stores |
| 05 | mma.sync f32 register tile: 2 x `st.global.v2.b32` + 4 scalar per fragment; runs under --differentiate |

`analyze-store-fragment` (mma.sync, `src/mma.lisp`) guards per FRAGMENT (D-197-4): the store-tile walk
emits one store-fragment per fragment, each lowered alone, so a per-tile guard would mean threading the
thread's first-fragment coordinates (runtime under a 2-D warp grid) through `%emit-per-frag-store`.
Per fragment: one test, two pair stores instead of four.

## Results

H100, scored case, compiler-emitted (submission 968393, side by side, us):

| | 4096x5120x4096 | 2048x3072x2048 |
|---|---:|---:|
| old (pre-197 PTX) | 308.4 | 82.3 |
| **new** | **256.3**, bit-exact | **62.9** |
| hand-packed probe | 254.4 | 61.8 |
| torch / cuBLAS | 220.3 | 40.3 |

The compiler matches the hand-packed probe within 1%.

A100, the 4-warp mma.sync contest kernel (submission 968400): old 4953.1 / new **4919.3** us at the scored
case, 709.6 / 702.5 at 2048 -- bit-exact, ~1%.  Expected: that kernel is mainloop-bound (7x off cuBLAS,
`ldmatrix` is its gap), so its epilogue was never the cost.

Suites (final build): unit 392/392, spine 1603/1603, negative 391/391.  One earlier spine run segfaulted
inside a BMG metal run (`12-ring-kloop-metal`, Hoist[L0]) -- not this code's path; the rerun was clean.
196's segfault was likewise a one-off.
