# Endeavour 198 -- wgmma transB (`:b-major :mn`)

Branch `matmul-contest`, 2026-10-28.  Step 3 of the plan in `../197-packed-stores/packed-stores.md`
(step 2, persistent launch, deferred by Chris in favour of this).

## Why

GPU MODE matmul_v2's `b` is (K N), N-contiguous -- the plain `a @ b` layout.  wgmma read B only as (N K)
(K-major), so the H100 entry ran a 39 us Crisp transpose before the 256 us kernel.  The 16-bit wgmma can
read an MN-major B directly with transB=1.

## API (decided with Chris)

`(wgmma-accumulate-via-tile (64 N K) D A B :swizzle :128b :b-major :mn)`, B staged `(K N)`.  Default
`:k` = today's `(N K)`.  Explicit rather than inferred from B's shape: a square tile (N = K-block) is
ambiguous.  Refused with a named message: tf32 (no transpose immediate), no `:swizzle :128b`, N not a
multiple of 64, a `(N K)` tile under `:mn`, any value but `:k` / `:mn`.  A `(K N)` 16-bit B *without*
the keyword now names `:b-major :mn` in its error (161/errors/02 updated).

## Mechanism

**TMA (a load-tile geometry rule, independent of wgmma).**  A `:128b`-swizzled box is at most 128 bytes
wide.  A wider tile -- `(64 256)` half = 512 bytes -- is issued as `count` boxes of 128 bytes: box j to
`dst + j * box-bytes` at x `x0 + j * inner`, all on the one mbarrier (expect_tx = the whole tile, as
before).  `resolve-tma-descriptors` narrows the recorded box, so the hoist (and the contest packager,
which reads the hoist) encodes `{64, 64}`.  A K-major tile already 128 bytes wide (the old `(256 64)` B)
is untouched.

**wgmma.**  `:b-major :mn` rides in `*wgmma-node-swizzle*` (4th element) to codegen, which builds B's
descriptor MN-major (CUTLASS `make_gmma_desc<Major::MN>`, B128):

| field | K-major (A, and B by default) | MN-major B |
|---|---|---|
| LBO | 16 B | one TMA box = K-block rows x 128 B = **8192** |
| SBO | 1024 B (8 rows) | **1024** B (8 K rows) |
| k16 slice advance | 32 B | **2048** B (16 rows x 128 B) |
| swizzle | 128B | 128B |

and the instruction's transB immediate = 1 (`*wgmma-16-trans*` bound to (0 1) for that instruction).

## Decisions

| # | decision |
|---|---|
| D-198-1 | Explicit `:b-major :mn` (Chris).  CUTLASS Major::K / Major::MN vocabulary. |
| D-198-2 | The TMA box split is keyed on geometry alone (`:128b`, inner > 128 B), not on wgmma -- any wide swizzled tile now loads correctly instead of failing tensor-map encoding. |
| D-198-3 | The split needs the tile's static dims (`*mma-scratch-tile-dims*`, via `%196-static-tile-dims`).  Without them the load is one copy -- logged at debug.  Rung 02 pins the ring case by counting copies. |
| D-198-4 | No new struct: `:b-major` travels in the existing per-node side table; codegen dispatch (`semantic-mma-accumulate`) redefined to read the 4th element. |
| D-198-5 | The contest's v4 entry drops the transpose kernel; `crisp_matmul_v3.py` kept as submitted. |

## Rungs

| rung | pins |
|---|---|
| 01 | (64 128) half B: transB=1 on every wgmma, MN-major descriptor (LBO 8192), 3 TMA copies (A + 2 B boxes) |
| 02 | contest geometry, bf16, B in a ring: 5 TMA copies (A + 4 boxes) -- the static-dims-through-ring-get path |
| errors/01-05 | tf32; no swizzle; N = 32; `:b-major :row`; `(N K)` tile under `:mn` |

## Results

H100 (popcorn diag 968422), us:

| | 4096x5120x4096 | 2048x3072x2048 |
|---|---:|---:|
| v2 path (Crisp transpose + 2wg_deep, packed stores) | 290.0 | 76.4 |
| **transB kernel** (b as given) | **255.3**, bit-exact | **62.9**, bit-exact |
| torch / cuBLAS | 220.5 | 39.7 |

Bit-exact on the first metal run.  The whole H100 call is now the kernel: 86% of cuBLAS at the scored case.
