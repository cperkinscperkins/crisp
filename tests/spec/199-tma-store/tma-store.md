# Endeavour 199 -- `store-tile-at ... :via :tma` (stmatrix + TMA-store epilogue)

Branch `matmul-contest`, 2026-10-28.  Follows probe 4 in `../196-matmul-contest/matmul-contest.md`.

## Why

After 197 (packed stores) and 198 (transB) the H100 contest kernel's epilogue was still 64
`st.global.v2.b16` per thread, each half-filling a 32-byte sector behind ~5 integer instructions of address
math, with every CTA in a wave stopping its tensor cores to write 8.4 MB at once.  Under 288 threads the
scalar fallback branch also made ptxas spill 480 B per thread.  Probe 4 (hand-edited PTX, popcorn 968478)
replaced it with stmatrix + TMA stores: 257.6 -> 229.6 us, exact, and persistence added only ~1 us on top.

## API (decided with Chris)

`(store-tile-at (to-half D) C (ROW COL) :via :tma)` -- explicit, naming the mechanism.  The staging buffer
and its swizzle are the compiler's.  Without `:via` the store is the direct one (197's packed pairs).

Refused with a named message: a non-PTX target; a source that is not a wgmma accumulator; no
`to-half` / `to-bfloat16` (stmatrix moves 16-bit elements); a destination that is not a symbol, holds a
different element type, or is `:col-major`; N not a multiple of 64; no `(local-size :set-to N)`; a store
pass 1 did not see (single-pass compile, store outside the kernel body); a tensor that is also
`:block`-loaded in the same kernel (one descriptor per tensor); any `:via` value but `:tma`.

## Mechanism

Per warp (it owns 16 of the accumulator's 64 rows), per pair of 64-column boxes:

1. `cvt.rn.f16x2.f32` / `cvt.rn.bf16x2.f32` of each column pair (members 4j+2h, 4j+2h+1 for n8 block j,
   row half h -- the m16n8 C fragment, which is exactly stmatrix's fragment);
2. 8 `stmatrix.sync.aligned.m8n8.x4` into the warp's 4 KB slice = two 16x64 boxes laid out
   SWIZZLE_128B (16-byte chunk c of row r at chunk c ^ (r mod 8));
3. `fence.proxy.async.shared::cta`, `bar.warp.sync`;
4. lane 0: one `cp.async.bulk.tensor.2d.global.shared::cta.bulk_group` per box, `commit_group`.

Lane 0 runs `cp.async.bulk.wait_group.read 0` before a slice is rewritten and once at the end of the store.

| piece | where |
|---|---|
| C's descriptor | pass 1 registers `C_TENSORMAP_FROM_FN` (the load naming, so `%tma-lookup-descriptor-ptr` finds it), marked `:store-box (16 64)`; `resolve-tma-descriptors` resolves it without a tile.  The hoist encodes box {64, 16}, SWIZZLE_128B, row-major. |
| staging | pass 1 registers `__TMA_STAGE_FROM_FN`, an implicit LOCAL scratch vector of half; analysis sizes it from the kernel's local-size: floor(threads / 128) x 16 KB + 1 KB.  The hoist allocates it like any scratch tile, so metadata, the CUDA launcher and the contest packager budget it with no new plumbing.  Codegen aligns its base up to 1 KB and indexes the slice by warp number. |
| node | `semantic-wgmma-tma-store` (analysis) -> inline PTX (codegen). |

## Decisions

| # | decision |
|---|---|
| D-199-1 | Explicit `:via :tma` (Chris), not inferred: it changes the kernel's shared-memory use. |
| D-199-2 | ONE staging buffer per kernel, sliced by warp number and sized from the declared local-size, instead of one per store site.  Pass 1 cannot correlate store sites with their analysis reliably (forms are copied and rewritten), and per-warp slices need no correlation.  Cost: a compile-time local-size is required. |
| D-199-3 | Per-warp 16-row TMA boxes: only warp-level syncs, no warpgroup named barrier.  32 TMA stores per CTA tile (2 KB each) instead of 8 larger ones -- the probe measured this shape. |
| D-199-4 | The final read-wait is at the end of each store, not at kernel exit: self-contained and independent of control flow.  It waits for a 4 KB shared-memory read, not for the global write.  Measured equal to the probe (which waited at exit): 228.0 vs 227.5 us. |
| D-199-5 | 16-bit outputs only (stmatrix is b16).  An f32 C (the benchmark suite's kernels) keeps the direct store; a st.shared.v2 staging path for f32 is future work. |
| D-199-7 | CI follow-up (198/01 under `--differentiate`): the MMA backward minted dB (Kt x Nt = 64 x 128) as a 256-register tile and failed the fit check.  Pre-existing -- a K-major 64x128 fails identically; endeavour 163 gave only dC a fallback.  `%mma-vjp-mma-admissible-p` now also asks `%mma-ad-accumulator-fits-registers-p` of dA and dB, so an oversized backward takes the existing scalar lowering (Chris: the backward of an MMA is the same whatever the forward's optimisation; it must not fail on a storage choice).  64x64 and ring (198/02) gradient PTX byte-identical. |
| D-199-6 | The staging buffer is allocated FIRST in the dynamic window (it is pushed last onto the implicit-arg list); its size is a multiple of 1 KB, so the user's 128B-swizzled tiles stay 1 KB-aligned. |

## Rungs

| rung | pins |
|---|---|
| 01 | 64x128 half, one warpgroup: 8 stmatrix, 2 TMA stores, 32 cvt.rn.f16x2, no st.global |
| 02 | contest geometry in bf16: two consumer warpgroups + producer, tile-stride, rings: 32 stmatrix, 8 TMA stores, 128 cvt.rn.bf16x2 |
| 03 | 64x64: one box -- the odd-box edge (4 stmatrix, 1 TMA store) |
| errors/01-07 | f32 source; `:via :ldg`; no local-size; N = 32; bf16 into half; `:col-major` C; a scratch tile as source |

AD: the rungs carry the D-196-12 SKIP (a converted store source is not differentiable yet).

## Results

H100 (popcorn diag 968483), us, 4096x5120x4096 / 2048x3072x2048:

| | scored | 2048 |
|---|---:|---:|
| v4 (transB, packed st.global) | 255.5 | 62.1 |
| **`:via :tma`** (compiler) | **228.0**, bit-exact | **51.6**, bit-exact |
| probe 4 (hand-edited PTX) | 227.5 | 51.2 |
| torch (cuBLAS) | 219.5 | 39.8 |

ptxas 12.4 (`--maxntid 288`): 0 spills (v4: 480 B).  Shared memory 230400 B (192 KB ring + 33 KB staging).
