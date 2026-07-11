Endeavor 135 — the `matrix-multiply-tile-stride` macro
======================================================

Authority: `docs/topology.md` (the design doc) specifies this macro and sketches the whole
MMA optimization arc (Chapters 1–3). This endeavor implements the macro to match that spec.
Where the doc is ambiguous, this file flags it as an OPEN QUESTION rather than inventing.

Documented signature (topology.md §"matrix-multiply-tile-stride")
-----------------------------------------------------------------
The doc shows a 4-arg-then-bindings form; per the OQ2 resolution we add an explicit `k-step`:
```lisp
(matrix-multiply-tile-stride <matrix> <matrix-tile> <inner-dim-scalar> <k-step>
                             (grid-y grid-x grid-k)
  BODY...)
```
The doc's original (pre-k-step) shape:
```lisp
(matrix-multiply-tile-stride <matrix> <matrix-tile> <inner-dim-scalar> (grid-y grid-x grid-k)
  BODY...)
```
- `<matrix>`      — the output C tensor.
- `<matrix-tile>` — the C register tile (make-register-tile) this workgroup accumulates into.
- `<inner-dim-scalar>` — K, the contraction extent (from `inner-dimension`).
- `(grid-y grid-x grid-k)` — bindings visible in BODY. grid-y/grid-x identify the owned
  C-tile; grid-k is the FASTEST-changing (loops over K). BODY runs in the innermost (grid-k)
  context.
- It's an ENVELOPE/body macro (peer of `tile-stride`): the USER writes the staging + MMA in
  BODY. The chapters vary the BODY, not the macro call.

Goal / motivation
-----------------
Chapter 0 today is hand-rolled (benchmarks/matmul/crisp/matmul.crisp + 132/06 + the perf
kernel): the `get-workgroup-id → gy/gx`, the `dotimes` over K, the sync + store boilerplate.
The macro folds that into one form so (a) tiled matmul is a first-class thing a user writes,
and (b) the chapters become readable variants of the SAME envelope. It pairs with
`mma-accumulate-via-tile` (which handles the within-tile MMA stepping).

The "before" (hand-rolled, benchmarks/matmul — Chapter 0, sync)
---------------------------------------------------------------
```lisp
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat) (local-size :set-to 32))
  (let ((wg  (to-int (get-workgroup-id 0)))
        (ntx (/ (to-int (num-cols C)) 64)))
    (let ((gy (/ wg ntx)) (gx (rem wg ntx))
          (A-tile (make-scratch-matrix float (64 8)))
          (B-tile (make-scratch-matrix float (8 64)))
          (C-tile (make-register-tile float (64 64) 0.0))
          (K      (to-int (inner-dimension A B))))
      (dotimes (kt (/ K 8))
        (load-tile-at A A-tile ((* gy 64) (* kt 8)))
        (load-tile-at B B-tile ((* kt 8) (* gx 64)))
        (sync-workgroup)
        (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
        (sync-workgroup))
      (store-tile C-tile C (gy gx)))))
```

The "after" — Chapter 0 via the macro (sync body)
--------------------------------------------------
Mirrors topology.md's Chapter-1 example but with a SYNC body (no barrier/await):
```lisp
(def-grid-function matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (global-size :derive-from C :strategy :strided))
  (let ((A-tile (make-scratch-matrix float (64 8)))
        (B-tile (make-scratch-matrix float (8 64)))
        (C-tile (make-register-tile float (64 64) 0.0))
        (K      (inner-dimension A B)))
    (matrix-multiply-tile-stride C C-tile K (grid-y grid-x grid-k)
      (load-tile A A-tile (grid-y grid-k))     ; sync (no :barrier) — see OQ4
      (load-tile B B-tile (grid-k grid-x))
      (sync-workgroup)
      (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
      (sync-workgroup))))
    ;; store: see OQ1 — does the macro emit it, or does the body/tail?
```

Open questions
--------------
OQ1. **Store placement.** RESOLVED (2026-07-08): the macro AUTO-STORES. It owns the grid-y/
   grid-x spatial loops, so it owns the write-back; it emits `store-tile C-tile C (grid-y
   grid-x)` after the grid-k reduction completes, per owned C-tile. The body does NOT store.
   Custom epilogue (ReLU/bias before store) → drop to the lower-level `tile-stride` and write
   the store yourself. topology.md's "store after the macro" was pseudocode hand-waving.

OQ2. **grid-k granularity / K-step.** RESOLVED (2026-07-08): add an explicit `<k-step>` arg
   (see signature). k-step = the K-extent of the staging A-tile/B-tile. The macro loops grid-k
   `K / k-step` times. In the topology.md 128×128-tile examples, **k-step = 128**; in
   benchmarks/matmul (tiles (64 8)/(8 64)), k-step = 8. CONTRACT: k-step must equal the tiles'
   declared K-extent — the macro can't see the tiles (they live in the body) to verify it, so
   it's a documented contract (optionally a `--runtime-checks` assertion). grid-k is a logical
   tile index (0..K/k-step-1); see OQ4 for how it becomes an element offset.

OQ3. **Multi-tile grid-stride vs one-tile-per-workgroup.** LEAN (my call, confirm if wrong):
   support the striding loop — a workgroup owns >=1 C-tile, striding across the grid; it's the
   name and the occupancy knob. The auto-store (OQ1) then runs per owned tile inside that loop.
   Chapter 0 today is one-tile (grid == #tiles), which is just the degenerate case.

OQ4. **Tile-load API — FINDING, needs your reconciliation (2026-07-08).** The impl does NOT
   match the doc, and NOT in the direction expected:
   - `load-tile-at` is NOT purged. It's the element-coord workhorse; its expander adds an
     element origin (`src[k] = origin[k] + tile-coord[k]`). Used in 111/113/benchmarks/132-06/
     133-12/perf + run-specs.
   - `load-tile-at` also exists (macros.lisp + analyzer + exported). Element coords.
   - `load-tile` exists but is BARE SUGAR that rewrites TO `load-tile-at` (111/10 comment),
     injecting the enclosing tile-stride's origin. So today's `load-tile` is ELEMENT-based, not
     tile-ID-based. There is NO true logical-tile-ID load form yet; matmul kernels hand-scale
     (`((* gy 64) (* kt 8))`).
   So the doc's "load-tile = tile IDs / load-tile-at = element" is INTENT, not impl. Fork:
   - (a) introduce genuine tile-ID semantics now (a scaling layer) — matches the doc, but real
     new work beyond the macro.
   - (b) have `matrix-multiply-tile-stride` bind grid-y/grid-x/grid-k as already-scaled ELEMENT
     origins, body keeps the existing element forms; defer the tile-ID API to the async chapters.
   Also decide: is `load-tile` WITHOUT `:barrier` the synchronous form (Ch0), WITH `:barrier`
   the async form (Ch1)?  → **awaiting decision; gates the P1 body shape.**

OQ5. **Relationship to `tile-stride`.** LEAN (my homework, will verify): build
   `matrix-multiply-tile-stride` ON `tile-stride` — reuse its outer C-tile envelope (+ the
   auto-store lives there), add the grid-k K-loop inside. Need to re-read tile-stride's expander
   to confirm it composes.

Scope of THIS endeavor (proposal)
---------------------------------
135 = the macro + Chapter-0 (sync) only. It is "just sugar": the macro-expanded sync kernel
must be IR-equivalent to the hand-rolled Chapter-0 kernel. The async `load-tile`/barrier body,
rings, and warp-specialization are the later chapter endeavors (already sketched in
topology.md); 135 must leave room for them but not build them.

Test plan (reuse 134)
---------------------
- Correctness: macro-expanded kernel gated by the existing `--mma-test` host-reference
  (MMA-DIMS + TEST-HOIST[L0|CUDA]) on both backends.
- Equivalence (the real acceptance test): diff the macro expansion's PTX/SPV against the
  hand-rolled Chapter-0 kernel — should be the same instructions ("it's just sugar").
- Perf: no new number for sync (it IS Chapter 0); performance/matmul-bmg stands. Rewrite the
  benchmarks/matmul + performance/matmul-bmg kernels to use the macro (dogfood) — still green,
  same perf.

Proposed phasing (draft)
------------------------
- P1: macro front-end + expansion for the SYNC body, matching the documented signature; prove
  IR-equivalent to the hand-rolled kernel; wire correctness on both backends. Resolve OQ1–OQ5
  first (they're mostly small once decided).
- P2: dogfood — rewrite benchmarks/matmul + performance/matmul-bmg on the macro; confirm green
  + same perf.
- P3: docs — register-fragment / make-register-fragment / store-fragment (doc-debt item) +
  the Intel col-major / VNNI note (why B col-major is awkward on DPAS). Reconcile the doc's
  `load-tile`/`load-tile-at` vs the impl's `load-tile-at` naming.

Definition of done
------------------
plan/definition-of-done.md. Plus: benchmarks/matmul + performance/matmul-bmg rebuilt on the
macro, green + same perf; topology.md's `matrix-multiply-tile-stride` section reconciled with
what actually shipped (esp. OQ1–OQ4 resolutions).


=======================================================================
STATUS — P1 complete (2026-07-10)
=======================================================================

What shipped
------------
`matrix-multiply-tile-stride` implemented as SUGAR over the (now grid-correct) `tile-stride`:

  (matrix-multiply-tile-stride C C-tile K <k-step> (grid-y grid-x grid-k) BODY...)
    =>
  (tile-stride C <C-tile-dims> (grid-y grid-x)
    (dotimes (grid-k (/ (to-ulong K) (to-ulong <k-step>)))  BODY...)
    (store-tile C-tile C ((to-int grid-y) (to-int grid-x))))     ; AUTO-STORE

All 6 specs green (unit + 01 envelope + 02 grid-stride + 03 CUDA + 04 BMG + 2 negatives).
02 and 04 verified MMA_CORRECT on real BMG (L0); 03 PTX shows mma.sync.m16n8k8; CUDA hoist
SKIPs locally (no nvcc).  Full suite 880/880 E2E, 253 unit, 195 neg — no regressions.

OQ resolutions (as built)
-------------------------
- OQ1 (store): AUTO-STORE, confirmed. Macro emits it after the grid-k reduction.
- OQ2 (k-step): explicit `<k-step>` arg = the staging tiles' shared K-extent; loop = K/k-step.
- OQ3 (grid-stride): supported — one workgroup owns >=1 C-tile (02 exercises it, 4 tiles / 1 WG).
- OQ4 (load coords): grid-y/grid-x/grid-k are TILE-IDs; load-tile/store-tile scale by the tile
  extent.  This required fixing tile-stride (see below).
- OQ5 (build on tile-stride): YES — after the tile-stride grid-term fix.  The macro is a
  straight lowering onto tile-stride's outer loop + an inner grid-k loop + auto-store.

Prerequisite fix — tile-stride / hardware-stride :workgroup-idx now bind GRID terms
-----------------------------------------------------------------------------------
The shared strided-loop engine (%expand-workgroup-strided-outer-loop-with-ts-syms) bound its
loop vars to ELEMENT origins (start=gid*ts, stride=ts*ng, over extent E).  That double-scaled
against load-tile/store-tile (which scale a grid coord by the tile extent) — latent, masked by
single-tile-only tests.  Fixed to bind TILE-IDs: start=gid, stride=ng, iters over
NT=ceil(E/ts).  Enforced on metal by NEW numeric multi-tile copy tests 109/15 (tile-stride) +
109/16 (:workgroup-idx), both MMA-shape-free, dual-backend (BMG verified).  Reconciled the
stale element-origin comments in 109/01,02,03,08 and 111/13's grid-x scaling.

Register-tile vs scratch C-tile (implementation note)
-----------------------------------------------------
A register-tile C-tile is a record-of-fragments (SROA-exploded to C-tile$Fi by
%explode-register-tiles in analyze-let-with-tile-explosion) with NO extents~.  So:
- Register-tile matmuls are PRE-LOWERED in the let-wrapper, BEFORE the explosion, using the
  tile's compile-time (M N) as a size-list tile-spec — so the auto-store/mma become visible to
  the explosion's rewrite.
- Scratch (real-tensor) C-tile goes the ordinary expression-analyzer path (tile-tensor spec).
Auto-store tile-IDs are coerced to int (the register store scales by an INT fragment count).

fill-tile (accumulator-reset sugar) — SHIPPED 2026-07-10
-------------------------------------------------------
`(fill-tile <tile> <value>)` sets every element of a tile to VALUE.  Two paths, dispatched
like store-tile:
- Register tile (record-of-fragments): reset each fragment to a fragment-of-VALUE, handled
  in the SROA explosion (%explode-rewrite-body-form gains a FILL-TILE clause + %emit-per-frag-fill).
  Register fragments are f32 → VALUE must be float.
- Scratch/SLM tile: workgroup-collective fill (analyze-fill-tile-expression → workgroup-stride
  set!).  NO barrier inserted — caller syncs before reading.
Specs: 07 (scratch fill, BUFFER 7 7 7 7) + 08 (register grid-stride matmul, 2 tiles, reset via
fill-tile — MMA_CORRECT on BMG; without the reset tile 2 would accumulate onto tile 1).  02
rewritten to use it in the reset position.  All BMG-verified.

:strided operand coverage — 09 (2026-07-10)
-------------------------------------------
09-strided-matmul-bmg: matmul where A, B AND C are :strided matrices, obtained by
REINTERPRETING the compact kernel params via make-matrix with an explicit :strides key
(forces :align :strided) — so the hoist side is unchanged (--mma-test still fills the compact
params).  Strides = the compact row-major strides, so numerically identical but TYPED :strided,
which routes element access / load-tile staging / the auto-store through the STRIDED flat-index
path instead of the compact direct path.  MMA_CORRECT on BMG.  (make-matrix width/height must
be literals, so dims are fixed to MMA-DIMS 8 16 16.)  Really a load-tile/store-tile × :strided
integration check under the macro — the align/ct combinatorics proper live in 097/109/111.

P2 dogfood — 2026-07-10
-----------------------
- **performance/matmul-bmg** (single-tile microbench, local BMG): rewritten onto the macro,
  IR-equivalent for the single 8x16 tile.  `python performance/check.py --test=matmul-bmg` →
  correct (A=B=1 => C==K gate) + kernel_median_us 890 vs baseline 868 (+2.5%, within the 10%
  tolerance; the delta is the macro's outer-loop-once setup + noise).  DONE + verified.
- **benchmarks/matmul** (64x64 grid-stride GEMM, CUDA/RunPod): kernel rewritten onto the macro;
  body is IR-equivalent to the hand-rolled (load-tile/store-tile tile-IDs map 1:1).  The macro
  derives grid-y/grid-x from workgroup-id 0/1 (ctaid.x/.y — confirmed in the generated PTX,
  32 mma.sync.m16n8k8), so bench_harness.cu changed from a 1-D linearized grid to a 2-D
  grid = (M/64, N/64).  grid == #tiles so no accumulator reset needed.  **VERIFIED on RTX 4000
  Ada (RunPod) 2026-07-10:** all ok=True at 256/512/1024; the 2-D mapping is correct.  Perf at
  parity — 1899 GFLOPS at 1024 vs naive CUDA 1823 (crisp/cuda 0.96; even faster in wall time,
  1130 vs 1178 us).  The macro rewrite preserved the 64x64 GEMM's performance.
- **scripts/bench-on-pod.sh**: added a `--bench=reduction|matmul` selector (default reduction,
  per-bench default sizes) so ONE pod script drives both benchmarks.

P2 dogfood COMPLETE — both benchmark kernels ride the macro, metal-validated on BMG + RTX.

Deferred (next)
---------------
- P3 docs: reconcile topology.md; register-fragment doc-debt; [x]add fill-tile to topology.md.
- AD across the macro (all P1 specs are forward-only).

Overlay (for merge)
-------------------
overlays/crisp-compiler-overlay.lisp holds: the tile-ID engine fix (-> src/analysis/control.lisp),
the macro parse/lower + scratch analyzer (-> control.lisp + register-control-analyzers), the
register-tile pre-lowering + analyze-let-with-tile-explosion wrapper (-> src/mma.lisp), and the
initialize-expression-analyzers wrapper (drop after the two registrations move to src).
