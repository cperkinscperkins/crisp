# Endeavour 196 — matmul contest gaps

Started 2026-10-27.  Branch `matmul-contest`.  Run overnight 2026-10-27/28 while Chris was away ("take
this endeavor as far as you can ... if there are things you think need decisions, just make them and
record them").

## For review (morning of 2026-10-28)

**Done.**  (a) `(store-tile (to-half D) C ...)`; (b) the vectorized Ampere `cp.async` load-tile; (b2) the
per-warp fit-check; (c) the GPU MODE submission.  Plus two things the contest flushed out: a
pre-existing `await` race (D-196-11) and an autodiff refusal (D-196-12).  Ranked: H100 340 us (#41/43),
A100 4962 us (#59/60), L4 7117 us (#25/25); B200 never completed -- every B200 job, including a
pure-torch probe, hit the runner's hard timeout.  Beauty entry: H100 86 ms.  Reports regenerated
(`contests/gpu-mode/REPORT*.md`; `report.py` now prints TFLOPS for a compute-bound workload).

**Decisions to review** (each detailed below):

| | decision |
|---|---|
| D-196-1..4 | `(to-half D)` on the store SOURCE; fused, never materialized; legal only as a store source; to-half / to-bfloat16 only (agreed shape) |
| D-196-5 | PTX only; SPIR-V refuses with a message (no Intel need yet) |
| D-196-6 | the submission launches through the CUDA driver API, not inline asm (65 parameters > 30 asm operands) |
| D-196-7 | vectorized cp.async chooses by a uniform RUN-TIME layout test (your option 1) and vectorizes 32-bit types too (option 3) |
| D-196-8 | 16-byte base alignment is ASSUMED (no `offsets~` accessor exists to test it) |
| D-196-9 | a sub-4-byte element in the per-element path copies synchronously instead of being refused |
| D-196-10 | the register fit-check charges a `:warps` tile per warp |
| D-196-11 | `await` on a `:linear` barrier = `wait_group` + `bar.sync` (a PRE-196 race, 2.8% wrong outputs on A100) |
| D-196-12 | `--differentiate` of a converted store is refused by name; the 196 specs `SKIP-WITH[--differentiate]` |

Not done, deliberately: wgmma transB (kept on scramble as agreed -- now worth ~39 us on H100);
`ldmatrix` (the A100/L4 7x gap); tcgen05.  All on `plan/scramble.md` with `.maxntid` and `offsets~`.

**To fold** (all overlays are unfolded; each definition carries a `;; src/...` comment):

- `src/mma.lisp`: `%196-peel-store-conversion`, `%196-wrap-conversion`, `analyze-store-fragment`,
  `%196-convert-store-fragment-sources`, `%explode-rewrite-body-form` (wrapper -> one COND clause after
  STORE-TILE), `%wgmma-store-rewrite-origin`, `%wgmma-store-rewrite`, `%196-refuse-converted-non-accumulator`,
  `analyze-store-tile-mma`, `analyze-store-tile-at-mma`, `*196-tile-warp-shares*`, `%196-tile-warp-shares`,
  `%explode-register-tiles` (wrapper -> bind the special in its LET*), `%register-tile-fit-check`.
- `src/analysis/control.lisp`: `analyze-%cp-async-copy-elem-expression`, `%196-expand-async-load-tile-vec-form`,
  `%196-static-tile-dims`, `%196-cp-async-vec-width`, `analyze-load-tile-at-expression`,
  `analyze-await-expression` (wrapper -> fold into its cp.async branch).
- `src/autodiff.lisp`: `%tlc-bwd-adj-name` (wrapper -> one COND clause).
- `tests/run-specs.lisp`: `%196-validate-ptx-store-narrowed`, `validate-ptx-store-to-half`,
  `-to-bfloat16`, `validate-ptx-cp-async-16`, `validate-ptx-cp-async-wait-then-barrier`.
- After the fold: regenerate reference.md / call graph / globals / specials (they read src, so the overlay
  functions are not in them yet).  Chapters were regenerated from `docs/ideal_001.md` already.

Suites with every overlay (final, 2026-10-28): unit 392/392, spine 1598/1598, negative 391/391; the 196
directory also 11/11 under `--debug`, `--single-pass` and `--differentiate`.  One spine run segfaulted
mid-way in an unrelated CUDA spec (`06-cuda-multi-workgroup`, 2598 runs in); the rerun was clean.

Bugs logged on the way: BUG 143 (a LET binding named `T` dies with a COMMON-LISP package-lock error) and
BUG 144 (`CHECK-FAIL-FLAGS` on a CRLF spec keeps a `\r` on its last flag -- it bit `errors/03` here;
other CRLF negative specs may be passing on the wrong target, unverified).

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

## (b) 16-bit Ampere `cp.async` -- DONE (overlay)

On sm_80 / sm_89 (A100, L4) there is no TMA, so `load-tile ... :barrier BAR` with the default (`:linear`)
barrier lowers to `cp.async` -- one per ELEMENT, and PTX `cp.async` moves only 4, 8 or 16 bytes, so a
half tile was refused ("element type HALF needs 4 or 8 bytes").  Chris chose the run-time check plus
vectorizing 32-bit types too (options 1 + 3, 2026-10-27).

- The last (contiguous) tile dimension is walked in 16-byte chunks, one `cp.async ... 16` each (8 halves,
  4 floats, 2 doubles); a chunk that runs off the tile or the source is copied per element with the
  identity fill, exactly as before.
- **D-196-7 The layout test is a uniform run-time `if`, once per load-tile**: source and tile stride 1 in
  the last dimension, every other stride a multiple of the chunk, the origin's last coordinate a multiple
  of the chunk.  Failing it runs the old per-element nest.  It is NOT a compile-time requirement or a type
  declaration -- a row stride is a run-time value (K), and the per-element nest is always correct.
- **D-196-8 Base alignment is assumed, not tested.**  A chunk is 16-byte aligned if the tensor's base
  address (pointer + offsets) is.  No Crisp form exposes a tensor's offsets (`offsets~` does not exist;
  `strides~` does), so this is an assumption: allocations (cudaMalloc, torch) are 256-byte aligned and
  the hoist passes offset 0.  A view at an odd element offset would fault -- revisit if `offsets~`
  appears.
- **D-196-9 Sub-4-byte elements in the per-element path copy synchronously** (`%cp-async-copy-elem` without
  a byte count on a 2-byte element analyses as `set!`).  Correct, just not asynchronous -- better than the
  old refusal, and it only runs on edges or when the layout test fails.
- A transposed load (`:transpose`) keeps the per-element nest (its walk is not contiguous in the source).

Mechanism: `analyze-load-tile-at-expression` (the `:linear` PTX branch picks
`%196-expand-async-load-tile-vec-form` with the chunk width from the tile's element type),
`analyze-%cp-async-copy-elem-expression` (optional BYTES; sync fallback).  Codegen already had the
`.16` intrinsic.  Spec `05` (validator `validate-ptx-cp-async-16`): fp16 Ch4 kernel on sm_80 with the
contest's (K N) row-major B; PTX has `cp.async.ca.shared.global [..], [..], 16`, synchronous
`st.shared.b16` for the edge path, 32 fp16 `m16n8k16` MMAs.

Note: the existing 32-bit `:linear` kernels (endeavour 136, tf32) now take the vector path too.

Suites with the (a) + (b) overlay, 2026-10-28: unit 392/392, spine 1594/1594, negative 389/389.

**Flattened chunk walk (second cut).**  The first cut kept the cooperative nest's thread mapping (local id
0 over tile ROWS, the last dimension serial per thread).  A100 measured the 1-warp kernel at 6.78 ms
(25 TFLOPS): under that mapping a 16-row B slice in a 128-thread workgroup keeps 16 threads busy, each
issuing 16 chunks in sequence, and a warp's 32 copies land in 32 different rows.  The vector nest now
spreads ALL chunks of the tile over ALL threads by linear local id -- chunk q = lid, lid + nthreads, ...
in row-major order -- so consecutive threads copy consecutive 16-byte chunks of a row.  The per-element
fallback nest is unchanged.

Suites with (a) + (b) flattened + (b2), 2026-10-28: unit 392/392, spine 1596/1596, negative 390/390.

**Static tile extents.**  The flattened walk divides and takes remainders by the tile extents; read
through `extents~` they are run-time values, and a 64-bit divide by a variable costs dozens of
instructions per chunk (A100: the 1-warp kernel went 6.8 -> 9.6 ms).  When the tile is a
`make-scratch-matrix` / `-ring` binding with a literal shape (`*mma-scratch-tile-dims*`, published by the
enclosing LET), the walk now uses the literals, so the divides become shifts.

- **D-196-11 `await` on a `:linear` barrier synchronises the workgroup** (PTX: `cp.async.wait_group N` then
  `bar.sync 0`).  `wait_group` covers only the calling thread's own copies, and a cooperative load-tile
  spreads the tile over every thread; CUDA's canonical form is `cp_async_wait_all(); __syncthreads()`.
  Found on A100: the 4-warp kernel with the flattened walk got 2.8% of outputs wrong (584,777 of 21M),
  every 1-warp kernel was right.  This is a PRE-196 bug -- the row-per-thread walk had it too, any
  multi-warp kernel reading another warp's rows was exposed -- that the flattened walk made common.
  Inside a warp-specialized block the old behaviour is kept (a CTA barrier there waits for warps that
  never arrive).  Mechanism: wrapper on `analyze-await-expression`.  Spec `07`
  (`validate-ptx-cp-async-wait-then-barrier`).

## (a2) autodiff of a converted store -- REFUSED by name (D-196-12)

- **D-196-12** `--differentiate` on `(store-tile (to-half D) C ...)` is refused with a message naming the
  gap.  The math is easy -- a precision cast is the identity on value, so the adjoint of `(to-half D)` is
  D's adjoint, the rule `%ad-widening-conversion-form-p` already applies to scalars -- but the accumulator
  backward asks "is the store source a register / wgmma accumulator SYMBOL" in several places (the
  activity scan that mints `<tile>_ADJ`, `%mma-ad-register-accumulator-tile-p`, the wgmma store path).
  Resolving only the adjoint's name moved the failure to "Unknown variable C-TILE_ADJ".  Before 196 a
  16-bit-output kernel could not be written at all, so nothing regressed.
- Every 196 spec carries `SKIP-WITH[--differentiate]` naming this gap; `errors/04` pins the refusal.
  When the backward sees through the conversion: delete `errors/04` and the skips.  On `plan/scramble.md`.

## (b2) the register fit-check charges a distributed tile per warp -- DONE (overlay)

- **D-196-10** `(make-register-tile float (128 128) 0.0 :warps '(true true true true))` was refused
  ("needs 512 registers/thread") although each of the four warps allocates only a quarter of it (128
  registers): `%register-tile-fit-check` counted the whole tile per thread.  It now divides by the number
  of true warps.  Found building a 4-warp A100 / L4 kernel (each staged A / B slice feeds four warps --
  half the global traffic per FLOP of the 1-warp 64x64 kernel).
- Mechanism: a wrapper on `%explode-register-tiles` publishes `*196-tile-warp-shares*` (M N ELEM N-TRUE per
  register tile in the LET); the redefined fit-check looks its tile up there.  Fold: bind the special in
  the original's LET*.  Spec `06` (compiles, fp16 MMA), `errors/03` (the same tile without :warps is still
  refused).

## (c) contest wrapper

- **D-196-6 The submission launches through the CUDA driver API, not inline asm.**  A TMA kernel has 65
  parameters (two tensor-map pointers, 9 per tensor, 12 per scratch ring) and an `asm` statement takes
  at most 30 operands.  `package_matmul.py` reads the parameter ABI (order, scratch literals, tensor-map
  encodings) out of the CUDA hoist and generates a `load_inline` launcher: `dlopen("libcuda.so.1")`,
  `cuModuleLoadDataEx`, `cuLaunchKernel`.  TMA descriptors are cached by (pointer, dims, strides, box) --
  a descriptor is a pure function of those, so it is never overwritten.
- **JIT block size.**  The PTX carries no `.maxntid`, so ptxas may use up to 255 registers a thread, and
  the 288-thread 2wg_deep block failed to launch ("too many resources requested for launch").  The
  launcher passes `CU_JIT_THREADS_PER_BLOCK` (= `__launch_bounds__`).  Worth a compiler follow-up:
  `(local-size :set-to N)` could emit `.maxntid N` / `.reqntid N` itself.
- B for wgmma: `b.t()` copied into a persistent (N K) buffer (stable address, so the TMA descriptor stays
  cached).

### H100 measurements (popcorn, scored case 4096x5120x4096)

| arm | us |
|---|---|
| v1 full call (torch `b.t()` copy + 2wg_deep) -- benchmark mode | 465 |
| torch `b.t()` copy alone | **160** |
| 2wg_deep kernel alone | **306** (~560 TFLOPS; bit-exact) |
| torch `a @ b` (cuBLAS) | 220 |

The kernel matches the benchmark suite (545 TFLOPS at 4096^3).  torch's transposing copy is a strided
element copy -- 84 MB in 160 us -- so the first fix is a tiled Crisp transpose (`transpose_b.crisp`,
coalesced on both sides through a 64x65 shared tile).  The real fix is wgmma transB (scramble.md).

| v2 arm | us |
|---|---|
| Crisp transpose (`transpose_b.crisp`) | **39** (exact vs `b.t().contiguous()`) |
| v2 full call (Crisp transpose + 2wg_deep) | **343.5** (bit-exact) |

So transB would now buy ~39 us (11%); the rest of the gap to cuBLAS (308 vs 220) is the kernel.

TMA multicast tried (`matmul_h100_2wg_mc.crisp`: `(cluster-size :set-to (2 2))`, `:cluster` empty ring,
`:multicast true` loads): correct (bit-exact) but **slower** -- 366 vs 309 us at the scored case, 90 vs 83
at 2048.  The 64x128 benchmark kernel gained +15% from multicast; the 2wg_deep tile already reuses each
TMA load across two warpgroups, and the 2x2 cluster adds cross-block barrier waits.  Not used.

Leaderboard 2026-10-27 (#1 / median, us): H100 205 / 221, B200 92 / 114, A100 596 / 683, L4 1990 / 2255.
The field is cuBLAS-speed; most entries call it.

## (c) contest wrapper -- notes

- B: `b.t().contiguous()` in the wrapper (agreed); wgmma transB=1 is on scramble.md.
- Per GPU: H100 wgmma (`2wg_deep`, sm_90a); B200 TMA + mma.sync (sm_100, compiles); A100/L4 after (b).
- tcgen05 (B200) is a separate future endeavour (scramble.md).

## H100 follow-up: where the 2wg_deep kernel's time goes (2026-10-28)

`popcorn --profile` produced no NCU report (even for pure torch: "No kernels were profiled",
CUPTI_ERROR_MULTIPLE_SUBSCRIBERS) -- so timing probes instead: hand-edited PTX arms, side by side in one
diag submission.  Builders: `contests/gpu-mode/06-matmul-v2/build_diag_h100_probe{,2,3}.py` (every rewrite
asserts its match counts; checked arms zero C first).

| arm (us) | 4096x5120x4096 | 2048x3072x2048 | what |
|---|---:|---:|---|
| kernel | 304-310 | 80-83 | as shipped |
| w1 | 309.1 (vs 310.1) | 81.9 (vs 82.6) | wgmma wait depth 1, previous-slot release -- **nothing** |
| noepi | 232-238 | 52-55 | epilogue stores predicated off (timing floor) |
| **pk** | **251.8** (vs 304.4), exact | **60.2** (vs 80.7), exact | each half pair -> one `st.global.b32` |
| pers | 299.6 (vs 303.7), exact | 79.9 (vs 79.9) | same PTX, grid 32x4 / 8x12: tile-stride walks 5 / 2 tiles |
| **pk + pers** | **244.0**, exact | **57.5**, exact | both |
| torch (cuBLAS) | 225-229 | 39-41 | |

- **The epilogue was 23% of the kernel** (72 us): 128 scalar `st.global.b16` per thread, not overlapped with
  anything (1 CTA/SM, 196 KB smem).  The accumulator layout gives each thread adjacent column PAIRS, and
  the lowering (`%wgmma-store-rewrite-origin`) emits them as separate element `set!`s with INT index math;
  LLVM's store vectorizer cannot pair them (the column is `or base, 1` sign-extended, and it cannot prove
  C is 4-byte aligned anyway).  Packing recovers 73% of it.  The fp32-output benchmark kernels store the
  same way (pairs of `st.global.f32`), so packing should lift section 2's H100 numbers too -- unmeasured.
- **Wait depth is not the problem** (my prior said it was).  The mainloop alone (noepi) is within 3-6% of
  cuBLAS's whole call.
- **Persistence** is worth 3% once the stores are packed; a launcher-only change (tile-stride already walks).
- Minor: the ring slot is `__crisp_idiv_floor_ulong_qr` = `x & 3` behind a non-inlined `.func` call on
  every k-step -- the BMG noinline-int-helper policy (BUG 120) applies on PTX too.  Not measured.

Projection for the scored case: pk + pers + Crisp transpose ~283 us (v2: 340); add transB ~244 us.
#1 is 205, median 221.  The probe PTX is hand-edited, so it is not an entry: the entry waits for the
compiler to emit packed stores.

Proposed order (for discussion): (1) packed pair stores in the wgmma and mma.sync accumulator store
lowerings (with a uniform alignment check + scalar fallback); (2) persistent launch in the packager;
(3) wgmma transB; (4) later: stmatrix + TMA-store epilogue for the last ~12-20 us, then the mainloop.

### Probe 4: stmatrix + TMA-store epilogue (2026-10-28, popcorn 968478)

`contests/gpu-mode/06-matmul-v2/build_diag_h100_probe4.py`, on the ranked v4 transB kernel.  Hand-edited
PTX: each consumer's epilogue (the guarded block of 64 `st.global.v2.b16`) becomes, per warp and per
128-column half of its 16 x 256 slab: 8 `stmatrix.x4` into a 4 KB 128B-swizzled staging buffer (two
16 x 64 boxes), `fence.proxy.async` + `bar.warp.sync`, then lane 0 issues two `cp.async.bulk.tensor`
stores through a C tensor map (box {64, 16}, SWIZZLE_128B) and commits.  Warp-level syncs only; staging
= 8 warps x 4 KB after the ring (smem 230400 of 232448).  The exit block waits `wait_group.read 0`.

| us | 4096x5120x4096 | 2048x3072x2048 |
|---|---:|---:|
| tb (v4 as ranked) | 257.6 | 62.1 |
| **tbe** (TMA-store epilogue) | **229.6**, exact | **51.5**, exact |
| tb_pers | 253.0 | 60.1 |
| tbe_pers | 228.7, exact | 47.8, exact |
| torch (cuBLAS) | 221.7 | 40.1 |

- **-28 us (11%)**, bit-exact first run; 96.5% of cuBLAS's whole call.  Would rank ~29/43 (the board from
  #10 to #28 is 218.7-227.4).  Below the old "noepi" floor (232-238) -- that arm kept the scalar store
  code, and with it the spills: ptxas (12.4, `--maxntid 288`) gives the v4 kernel 168 regs + **480 B
  spill stores**; the probe 166 regs, **0 spills**.
- **Persistence adds ~1 us** at the scored case once the store is asynchronous (7% at 2048).  The
  non-persistent CTA exits after the staging is read; the writes drain under the next CTA's prologue.
- So the TMA-store epilogue does not need persistent launch first.
