# Endeavour 196 — matmul contest gaps

Started 2026-10-27.  Branch `matmul-contest`.

## Why

GPU MODE's open "getting started" set is eight pmpp_v2 leaderboards (537-544).  We had entries for
five.  Of the three left (conv2d_v2, matmul_v2, sort_v2) Chris picked **matmul_v2 (#540)**: it is the
one that exercises Crisp's MMA / tile-stride / TMA work instead of another memory-bound loop, and
conv2d is a matmul with a reshape in front.

The task: `c = a @ b`, fp16 in, fp16 out, `a` (M K) row-major, `b` (K N) row-major.  Scored case
(kernelbot ranks the LAST benchmark only): **4096 x 5120 x 4096** (172 GFLOP).  B200 #1 at 92 us.

Feasibility work (popcorn probe + compile checks, `put_temp_files_here/matmul_probe/FINDINGS.md`)
found three gaps between our matmul benchmarks and this contest.  One endeavour for all three, since
they are of a piece:

| | gap | blocks |
|---|---|---|
| (a) | an f32 accumulator cannot be stored into a 16-bit matrix | every GPU |
| (b) | Ampere `cp.async` refuses 16-bit elements ("HALF needs 4 or 8 bytes") | A100, L4 |
| (c) | the contest wrapper: B transpose, per-GPU kernel choice, tiny test shapes | entry |

## Correctness is bit-exact (the probe)

`eval.py` re-checks correctness on the benchmark inputs, with rtol 1e-5 / atol 1e-8.  fp16 outputs
are ~1024, so every one of 21M outputs must equal torch's `a @ b` bit for bit.

`exact_probe.py` (popcorn `--mode test`, no Crisp), mismatches vs `ref_kernel` on the scored case:

| arm | H100 | A100 | L4 | B200 |
|---|---|---|---|---|
| `mma.sync` m16n8k16 f32-acc, sequential K, `cvt.rn` | **0** | **0** | **0** | timed out |
| fp32 (TF32 off) / fp32 one-thread-per-output | 766k | 1.48M | 1.47M | |
| torch with B pre-transposed (`bT`) | 0 | **2.86M** | 0 | |

Tensor-core accumulation in K order reproduces cuBLAS exactly; IEEE fp32 accumulation does not.
Consequences for every kernel we enter: **tensor cores only, no split-K, no fp32 fallback even for the
tiny test shapes, round-to-nearest-even on the way out.**  The A100 `bT` row shows cuBLAS itself
picks a different (non-reproducible) algorithm for another layout -- the reference is only matchable
in the order it actually uses.

## (a) `(store-tile (to-half D) C ...)` -- DONE (overlay)

```lisp
(store-tile    (to-half D) C (grid-y grid-x))      ; register tile or wgmma accumulator
(store-tile-at (to-half D) C (row col))            ; wgmma accumulator, absolute origin
(store-tile    (to-bfloat16 D) C (grid-y grid-x))
```

`store-tile` takes SOURCE then DEST.  `(to-half D)` reads "D's elements converted to half" (Chris,
2026-10-27); D itself stays f32.

Decisions:

- **D-196-1 The conversion goes on the SOURCE, written by the author.**  set! keeps its rule that an
  element holds exactly its own type; nothing narrows implicitly.  `to-half` is an existing word
  (convert, round-to-nearest-even) -- unlike `as`, which in Crisp means reinterpret, so a keyword
  spelling `:as half` was rejected for reading as a bit cast.
- **D-196-2 Fused, never materialized.**  The store rewrites wrap each per-element read in the
  conversion: one `cvt.rn` per element at the store, no half copy of the tile, no extra registers.
- **D-196-3 Legal only as a store source** (store-tile, store-tile-at, store-fragment).  No general
  elementwise conversion of whole tiles.  Elsewhere `(to-half D)` keeps today's refusal --
  "Unsupported value cast from WGMMA-ACC-F32-64X64 to HALF" (codegen, no source location; left as
  is).  `(to-half X)` on a non-accumulator store source is refused at analysis, naming the rule.
- **D-196-4 to-half and to-bfloat16 only.**  The two narrowings a 16-bit MMA needs.
- **D-196-5 PTX only for now.**  On SPIR-V the store is one CooperativeMatrixStoreKHR of the whole
  fragment, which would need an OpFConvert of the cooperative matrix first; refused with a message
  saying so.  (No Intel need yet; BMG fp16 benchmarks store f32.)

Mechanism (`overlays/crisp-compiler-overlay.lisp`, all destined for `src/mma.lisp`):
`%196-peel-store-conversion` strips the conversion off a store source; `analyze-store-fragment`,
`%wgmma-store-rewrite(-origin)`, `analyze-store-tile-mma`, `analyze-store-tile-at-mma` thread it to
the element reads; a wrapper on `%explode-rewrite-body-form` handles the exploded register tile by
wrapping the FRAG of every store-fragment `%emit-per-frag-store` emits (that function reused, not
copied).

Specs: `01` register tile -> half, `02` register tile -> bf16, `03` wgmma store-tile -> half,
`04` wgmma store-tile-at -> half.  Validator `validate-ptx-store-to-half` / `-bfloat16` is
two-sided: `cvt.rn` present, 16-bit global stores, no f32 global store, no other rounding mode.
PTX checked by hand: 4 `cvt.rn.f16.f32` + 4 `st.global.b16` per lane for one 16x8 fragment; 32 + 32
per thread for a 64x64 wgmma tile.

Metal: the contest submission itself (popcorn), against the bit-exact reference.

Suites with the (a) overlay, 2026-10-27: unit 392/392, spine 1593/1593 (ci-stop moved to 196),
negative 389/389.

Noted for later: the stores are scalar `st.global.b16`; column pairs could pack to `cvt.rn.f16x2.f32`
+ `st.global.b32`.

## (b) 16-bit Ampere `cp.async` -- TODO

## (c) contest wrapper -- TODO

- B: `b.t().contiguous()` in the wrapper (agreed); wgmma transB=1 is on scramble.md.
- Per GPU: H100 wgmma (`2wg_deep`, sm_90a); B200 TMA + mma.sync (sm_100, compiles); A100/L4 after (b).
- tcgen05 (B200) is a separate future endeavour (scramble.md).
