In the previous endeavor (109) we realized tile-stride and hardware-stride and their helper macros...except for the load-tile and store-tile helpers.

In this endeavor (111) we are going to implement the load-tile and store-tile helpers.

Helper Design Docs & API
------------------------

The stride macros and their helpers are documented in docs\chapters\14_control_flow\11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride.md

and the load-tile and store-tile helpers are in the following chapter here:
docs\chapters\14_control_flow\12_load_tile_store_tile.md

### Helper API

The API of these functions, and their async variants are

```
;; Helpers
(load-tile <problem-space-tensor> <tile> &key (identity 0) transpose)
(request-load-tile <problem-space-tensor> <tile> &key (identity 0) transpose) => dag-token



;; Helpers
(store-tile <problem-space-tensor> <tile> &key transformF transpose)
(request-store-tile <problem-space-tensor> <tile> &key transpose) => dag-token


(await-request dag-token)
```

The tile will simply lift the data right out of the source-M, whether it is
`:col-major` or `:row-major`, and so have the same layout, just smaller.  

But the `:transpose` argument can be used to change that. If `true` then
the `x` and `y` coordinates will be swapped. For tensors with an arity of three or greater, the `:transpose` keyword accepts a permutation list (such as `'(0 2 1)`) to explicitly dictate how the axes are reordered when mapping to local memory. Providing a simple boolean `true` serves as a convenient shorthand for this list, defaulting to swapping only the two innermost dimensions while preserving the outer batch structure.


The helper has a big advantage because it works with tensors of any N and is stride aware.  All it needs is the problem space tensor and the tile tensor and it's in business. Also the :contiguous-term is known at the kernel boundary and if the stride macro is in a sub-function that allows an incomplete type, Crisp monomorphically specializes it to fit the tensor :contiguous-term. So that also means row-major vs col-major stuff is always handled (I think. Please correct me if I'm wrong) which means coalesced access. 

General Tile Forms
-----------------

But note that beyond the helper macros, Crisp has a design for tile loading forms generally.

docs\chapters\10_storage_handle_types\18_matrices.md
docs\chapters\10_storage_handle_types\16_async_memory_operations.md
### General Tile Form API

```
;; General
(load-tile-coords source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose)
(request-load-tile-coords source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose) => request token

;; General
(store-tile-coords dest-tensor source-tile (... tensor-row-y tensor-col-x) &key transformF transpose)
(request-store-tile-coords dest-tensor source-tile (... tensor-row-y tensor-col-x) &key transpose) => request token
```


Bounds Checking: The macro implementation for both store-tile and store-tile-coords must implicitly generate the bounds-checking logic (if (and (< y max-y) (< x max-x)) ...) to prevent rogue threads from writing past the tensor boundaries.

The Async transformF Limitation: Notice I omitted transformF from the request-store-tile async variants. If you are leveraging hardware async copy capabilities (like SYCL's async_work_group_copy or hardware DMA), those units only know how to move raw bytes. They do not have access to the ALUs to run a custom Lisp closure (transformF) mid-flight. If a user needs to transform data, they must do it synchronously before initiating the async DMA store.

Reversing Transpose: If the user loaded the tile with :transpose t to avoid bank conflicts during compute, they will likely need to write it back with :transpose t so it lands in global memory in the correct layout. Keeping the key on the store side ensures symmetry.


Planning
========

Test and implementation of these nine (9) routines.

Is async the same SPV and PTX? 


Claude Points Out Problem
=========================

1. The big structural question: does tile-stride actually have an outer-tile loop?
109's implementation note (and the docs' "implementation note" at the bottom of 14/11) says tile-stride is just tensor-stride with the helpers re-mapping coordinates — every problem-space coord visited once, no outer/inner split.

But load-tile's semantics in 14/12 — "cooperative, each thread sets one value, ends with (local-barrier)" — really wants a per-outer-tile hook: one call populates one tile, the workgroup cooperates, then a barrier. If tile-stride has no outer-tile-iter structure, a bare (load-tile PS T) in the body would either fire once per problem-coord (wrong: redundant + barrier-per-coord-deadlock-risk) or need a clever rewrite that hoists it out of the inner loop.

This is the biggest design question of 111. I think we either need to give tile-stride a real outer-tile loop structure (which would let load-tile/store-tile attach cleanly), or define very carefully what one call to load-tile means under the current tensor-stride-style iteration. Worth nailing down before any code.


Chris Replies
=============
Ouch. You are correct.

I think we should make it so that `tile-stride` is strictly the outer loop.
If we revise the design then `tile-stride` does not evaluate its body per-element. It evaluates its body once per tile.

It strides the entire workgroup across the global problem space. The body of the macro represents the cooperative operations of the workgroup for that specific tile.


When a user calls (load-tile ...), that macro cannot assume a 1:1 mapping where each thread executes exactly one memory operation. Instead, load-tile must generate a cooperative loop (often called a block-stride or workgroup-stride loop) under the hood.

Inside the load-tile expansion, each thread uses its local_id as the starting index and strides forward by the local_range (the workgroup size) until the entire tile is populated.

Scenario A: Tile is larger than Workgroup

Example: Tile is 64x64 (4096 elements), Workgroup is 16x16 (256 threads).

Behavior: The generated loop inside load-tile will iterate 16 times per thread. Thread (0,0) loads element (0,0), then element (0,16), then (0,32), etc.

Result: The tile is loaded perfectly, and memory access remains perfectly coalesced because adjacent threads in the warp/wavefront are still accessing adjacent memory addresses on every iteration.

Scenario B: Tile is smaller than Workgroup

Example: Tile is 16x16 (256 elements), Workgroup is 32x32 (1024 threads).

Behavior: The generated loop evaluates its bounds check immediately. 768 threads realize their local_id is out-of-bounds for the tile size and simply skip the load instruction. 256 threads load one element each.

Result: The tile is loaded safely. The idle threads simply wait at the (local-barrier) that terminates the load-tile operation.

Why this makes Path 1 robust
Because load-tile and store-tile encapsulate this cooperative loop, tile-stride doesn't need to care about the thread-to-element mapping.

tile-stride loops over the global problem space, moving the "window" by TILE_DIM on each iteration.

load-tile takes the current window coordinate, looks at the workgroup size, and cooperatively loops the threads to fill the local memory.

The user's math executes.

store-tile cooperatively loops the threads to write the local memory back to the global window.



load-tile and store-tile fit perfectly here because they are tile-level actions.

What happens to the math?
If the user is just doing a layout conversion (like your convert-layout example), there is no math. They just load and store. If they are doing a tiled matrix multiplication, they would write an explicit inner loop inside the tile-stride body to iterate over the local memory tile and do the math.

Typical workflow:
```
(tile-stride source-tensor '(TILE_DIM TILE_DIM) (t-y t-x)
  
  (load-tile source-tensor local-tile)  ;; <-- has local-barrier at end
  
  (workgroup-stride local-tile (l-y l-x)
    ;; All threads cooperatively chew through the math on the local tile
    (set! (aref local-tile l-y l-x) 
          (activation-function (aref local-tile l-y l-x))))
  

  (store-tile dest-tensor local-tile)) ;; <-- store-tile has local-barrier at beginning and end
```


Hey, Claude. So what would backtracking look like?


Claude Rumbles
==============
What "backtracking" concretely means
Under the new model, the semantics of tile-stride bindings change: they go from "this thread's problem-space coord" to "the tile-index this workgroup is processing." That's a breaking semantic shift, not a tweak. The downstream effects:

1. Implementation changes (in src/analysis/control.lisp)

%expand-tile-stride-form — full rewrite. Currently 40 lines that delegate to %expand-tensor-stride-form; the new version generates a real outer loop over the tile grid (for tile_y in 0..ceil(extent/tile_size)), and the body is expanded once per outer-tile-iteration with workgroup-cooperative inner machinery available. The free-ride on tensor-stride goes away.
%expand-hardware-stride-form :workgroup-idx — same kind of rewrite. :warp-idx is unaffected (it's already 1D linear).
%tile-helpers-rewrite — most of it goes away. tile-coords no longer makes sense (the binding is no longer a coord-in-problem-space, so "where am I in the current tile" has no per-thread answer at the outer level). tile-indices becomes redundant (the binding is the tile index). tensor-coords survives but its signature changes: (tensor-coords tile-idx local-coord) where local-coord comes from a workgroup-stride binding, not from a tile-stride binding.
analyze-tile-stride-expression — arity validation tweaks.
New: workgroup-stride macro for the explicit cooperative inner loop (Chris's example uses it).
New: load-tile / store-tile body walker that knows the surrounding tile-stride's tile shape, binding names, and emits the cooperative-loop expansion + barrier.
AD pre-pass walker (%expand-stride-macros-in-form) — unchanged in structure, just calls the new expansions.
Rough size: ~2-3 days of refactor, similar in scope to the 109 endeavor itself.

2. Test rewrites in tests/spec/109-tile-stride-hardware-stride/

Counted 19 files. Of those:

Stale, need full rewrite (~13 tests): 01-04 (basic tile-stride), 05-06 (strict), 07-10 (helpers — and tile-coords/tile-indices largely go away), 11 (workgroup-idx), 14 (strict-with-helpers), 15 (diff), 16 (hoist).
Probably survive unchanged (~4): 12-13 (:warp-idx — its semantics don't change), errors/01-03 (arity/tag checks).
errors/02 probably still works since it's about layout-tag-vs-CT conflicts at the type level.
A half-day to a day to rewrite the bodies.

3. AD impact

This is the most uncertain piece. Under the new model the backward pass for a tile-stride body needs:

Backward outer loop with the same tile-index iteration.
load-tile (forward, global→local) reverses to store-tile of adjoints (local→global, with scatter-add semantics).
store-tile (forward, local→global) reverses to load-tile of adjoints (global→local).
Math in between reverses normally — workgroup-stride's inner loop is just a dotimes-equivalent, which 107 already handles.
The good news: under the new model the AD walker may actually be cleaner, because load-tile/store-tile are semantic units the walker can flip atomically, instead of having to recognize the per-coord pattern. The bad news: writing the reverse rules for them is genuinely new work — call it 1-2 days plus debugging, and it's pre-requisite for any VERIFY-AUTODIFF test on a tiled kernel.

4. Doc updates

docs/chapters/14_control_flow/11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride.md — tile-stride and hardware-stride :workgroup-idx sections need rewrites; helper macro section shrinks substantially.
docs/chapters/14_control_flow/12_load_tile_store_tile.md — clarify the outer-loop contract; the "cooperative, one value per thread" wording becomes "cooperative, generated as a workgroup-stride loop under the hood."
docs/chapters/10_storage_handle_types/18_matrices.md — convert-layout example. You said ignore for now.
New chapter or section needed for workgroup-stride.
A few hours.

5. Memory snippet

The memory note for endeavor 109 says "tile-stride + hardware-stride complete." Under backtrack, that snippet needs an addendum: "outer-loop semantics revisited in endeavor 111." Trivial.

Total
Rough estimate: 4-6 days of work to backtrack 109 cleanly. Breakdown:

Restructure tile-stride + hardware-stride :workgroup-idx: 2-3 days
Rewrite ~13 tests: 0.5-1 day
AD support for new helpers: 1-2 days
Doc updates: a few hours
Why doing it now is right
Two reasons this is cheap:

109 just landed yesterday. No downstream code depends on the wrong semantics yet — no other endeavor has used tile-stride in anger. The test suite at 693 includes 109, but the 109 tests are self-contained.
The new model is conceptually cleaner (one tile per outer iter, helpers compose at the right level). Building 111 on the wrong foundation would have meant either grafting outer-loop machinery into 111 itself (ugly) or living with non-cooperative load/store-tile (wrong).
What I'd suggest as a sequencing
Phase 0 (this work): Restructure 109. Don't introduce load-tile/store-tile yet. Just fix tile-stride's outer-loop semantics + introduce workgroup-stride as a separate primitive. Rewrite the 109 tests to use the new shape. Verify AD still works (the outer loop is now a dotimes equivalent, which 107 handles).
Phase 1 (endeavor 111a): Sync load-tile / store-tile / load-tile-coords / store-tile-coords, plus AD rules for them. Plus the convergence checker for "no async/cooperative ops inside divergent branches."
Phase 2 (endeavor 111b): Async variants + request-token type + per-target lowering.
The Phase 0 work doesn't need a new endeavor directory — it's a "fix 109" patch. The decision to do it now or merge it into 111 is stylistic; I'd lean toward keeping it in 111 (rename to "111-tile-stride-revisit-and-load-store-tile" or similar) so the chronological record reflects that the model changed when load-tile/store-tile were attempted, not preemptively.


Claude — Revised Backtracking Estimate (after Chris's design updates)
=====================================================================

After reading the updated 14/11 (helpers shrunk to just `tile-indices`; hardware-stride
also restructured as an outer loop) and 13_workgroup_stride.md, the scope of the
backtrack is wider than the previous estimate. Roughly: **109 is mostly undone, plus
workgroup-stride is a net-new primitive that Phase 0 has to deliver**.

Issues I want to flag in the updated design
-------------------------------------------

These are doc/scope items, not blockers — but they affect Phase 0's surface area:

1. **12_load_tile_store_tile.md is stale.** Two specific spots:
   - Line 33: "`<problem-space-tensor>` is the original `<tensor>` of the `tile-stride`"
     is overly restrictive — the typical workflow example writes `store-tile` against
     a *different* tensor than the tile-stride's source. Loosen to "any compatible
     tensor."
   - Line 53: "each thread setting one value" — wrong under the new model. Should
     read "cooperative; generated as a workgroup-strided loop, so each thread does
     0+ loads depending on tile-vs-workgroup sizing" (per Chris's Scenario A/B).

2. **`load-tile` inside `hardware-stride :warp-idx` is a category error.**
   `load-tile` is a workgroup-cooperative primitive (uses `local_id`, ends with
   `(local-barrier)`). Inside `:warp-idx` only one warp is processing the current
   chunk, but a workgroup-wide barrier would expect all warps to sync — deadlock.
   Decision needed: (a) disallow + compile error, (b) context-dispatched to emit
   warp-cooperative code when inside `:warp-idx`, (c) introduce a separate
   `load-warp-tile` family. **Recommendation: (a) for Phase 1, upgrade to (b) later
   if demand.**

3. **`tile-indices` naming in hardware-stride.** Inside `:workgroup-idx` it returns
   the workgroup index; inside `:warp-idx` it returns the warp index. Same
   divide-by-chunk operation, but "tile" is a misnomer there. Either accept the
   dual meaning (with a doc sentence) or rename to a neutral `chunk-indices`.
   Cosmetic.

4. **Ragged-edge semantics migrate from tile-stride to load-tile/store-tile.**
   Under the new model, `tile-stride`'s outer iter just steps by tile-size past the
   extent; bounds-checking lives inside `load-tile` (`:identity` fill) and
   `store-tile` (skip). The 109 "naive striding, user's responsibility" model is
   gone. Doc cleanup item.

5. **`local-tile` shape must equal the tile-size.** Compiler check + clear error.
   Easy to forget.

6. **`:strategy :tiled` parameterization.** Tile-size and workgroup-size are now
   decoupled (Scenario A/B). The host-side strategy declaration needs to
   communicate *both*. Out of scope for Phase 0, but flagged for the eventual
   `:tiled` hoist work.

7. **`workgroup-stride` doesn't inject an end-barrier (per 13 line 51).** Clean
   choice, but means `load-tile`/`store-tile` must explicitly inject barriers
   around their internal workgroup-stride-shaped expansion. The AD-pass walker has
   to preserve those barriers across the rewrite. Implementation note.


Revised scope of backtracking
-----------------------------

Three pieces of work, not one:

### A. tile-stride restructure
- `%expand-tile-stride-form` full rewrite. Bindings now carry tile *origin coord
  in problem space* (per updated 14/11), body executes once per tile, outer loop
  iterates `0, tile-size, 2·tile-size, …` over each axis up to `(ceil extent
  tile-size) * tile-size`. No free-ride on `%expand-tensor-stride-form` — has its
  own loop.
- `%tile-helpers-rewrite` shrinks to just `tile-indices` (= floor binding /
  tile-size). `tile-coords` and `tensor-coords` removed from the helper table.
- `analyze-tile-stride-expression` validation tweaks (tile-arity vs binding
  arity, etc.).

### B. hardware-stride restructure (was undercounted in my prior estimate)
- `%expand-hardware-stride-form :workgroup-idx` full rewrite. Now an outer loop
  over workgroup chunks; binding = global origin coord of the chunk =
  `(* group-id local-size)` per dim. Body runs once per workgroup. No longer
  delegates to `%expand-tensor-stride-form`.
- `:warp-idx` also rewrites: binding = global origin of the warp's chunk (1D),
  body runs once per warp.
- Both share the same arity-validation + body-walk machinery as tile-stride.

### C. workgroup-stride — NET-NEW PRIMITIVE
- New macro per [13_workgroup_stride.md](docs/chapters/14_control_flow/13_workgroup_stride.md).
- Iterates the local tile cooperatively across the workgroup threads using
  `get-local-id` / `get-local-size`. Coalesced on the tile's contiguous dim.
- Handles tile-size > workgroup-size (block-stride loop) and tile-size <
  workgroup-size (lane-mask).
- No end-barrier (intentional — user inserts `(local-barrier)` explicitly).
- New helpers in its scope: `(warp-id)`, `(warp-lane)`, `(warp-count)` — these
  are *new* SPIR-V/PTX builtins that need codegen plumbing.
  - `warp-lane` = `__spirv_BuiltInSubgroupLocalInvocationId` on SPV; `%laneid` on
    PTX.
  - `warp-id` = `__spirv_BuiltInSubgroupId` on SPV; needs `local_id / warp_size`
    on PTX.
  - `warp-count` = `__spirv_BuiltInNumSubgroups` on SPV; `local_size / warp_size`
    elsewhere.
- This piece pulls in part of the warp-builtins endeavor that was previously
  carrying an IOU (the hardcoded `(to-ulong 32)` warp size in 109). May or may
  not get the full `(get-warp-size)` implemented in Phase 0 — fine to keep the
  placeholder if not.

This is genuinely a new ~1-1.5 days of work on top of A and B.


Updated test-rewrite count
--------------------------

Under the new model, of the 19 tests in
[tests/spec/109-tile-stride-hardware-stride/](tests/spec/109-tile-stride-hardware-stride/):

- **Delete entirely**: `07-tile-coords.crisp` and `09-tensor-coords.crisp`
  (helpers removed from the language).
- **Full rewrite, body semantics changed (~14 tests)**: 01-06 (all the basic
  tile-stride tests now need an inner workgroup-stride to populate elements),
  08 (tile-indices test — helper survives but its inputs change), 10 (helpers
  combined), 11-14 (hardware-stride — all four bindings now mean tile/chunk
  origin, not problem-coord; `:warp-idx` tests need rewriting too), 15
  (VERIFY-AUTODIFF kernel), 16 (TEST-HOIST[L0] kernel).
- **Survive unchanged (~3)**: errors/01 (arity mismatch — still a syntactic
  check), errors/02 (layout-tag vs CT conflict), errors/03 (warp-idx binding
  count).

So 16 of 19 stale (was previously estimated at 13). Plus new tests for
workgroup-stride and the new warp builtins.


Updated AD impact
-----------------

Better than my prior estimate, actually. Under the new outer-loop model:

- `tile-stride` expands to a nested `dotimes` (one per axis) over tile-grid
  coords. AD already handles `dotimes` from endeavor 107.
- `workgroup-stride` is similar — a dotimes over local-id-strided iteration. AD
  should handle once we wire `get-local-id`/`get-local-size` into the
  per-iteration-adjoint-reset machinery (likely a minor extension of the 107
  pattern).
- `hardware-stride` outer loop is the same shape.

So the AD work shrinks to "make sure AD's stride-pre-pass walker calls the new
`%expand-tile-stride-form` and `%expand-hardware-stride-form`." Probably a
few hours, not 1-2 days, *for Phase 0*. The full AD-rules-for-load-tile/store-tile
work still belongs in Phase 1.


Revised effort estimate
-----------------------

Phase 0 (this backtrack) — **6-9 days**, broken down:

| Piece | Effort |
|-------|--------|
| A. tile-stride restructure | 1-2 days |
| B. hardware-stride restructure | 1-2 days |
| C. workgroup-stride primitive + warp builtins | 1.5-2 days |
| Rewrite 16 of 19 109 tests | 1 day |
| Add workgroup-stride tests | 0.5 day |
| AD pre-pass wiring | 0.5 day |
| Doc updates (14/11 done, 12, 13, possibly 18) | 0.5 day |

That's most of a working week. The previous "4-6 days" estimate didn't account
for hardware-stride or workgroup-stride being net-new work. Confirms Chris's
read: **this undoes nearly all of 109**.

Phase 1 (sync load-tile family) and Phase 2 (async) estimates unchanged from prior.


Recommendation on endeavor naming
---------------------------------

Rename `tests/spec/111-load-and-store-tile/` to something like
`tests/spec/111-tile-stride-and-load-store-tile/`, with the planning broken into:

- 111a: tile-stride / hardware-stride restructure + workgroup-stride + warp
  builtins (Phase 0).
- 111b: sync load-tile / store-tile / load-tile-coords / store-tile-coords
  (Phase 1).
- 111c: async variants (Phase 2).

Memory snippet for 109 gets an addendum: "outer-loop semantics revisited in 111;
implementation in 109 was per-coord and superseded."

One question before I touch any code: under the new model, do you want **109's
spec directory left in place as a historical record** (with its current tests as
they were, even though they no longer compile), or do you want me to **rewrite
109's tests in place** to reflect the new model? Either is defensible — the
former preserves the chronological scaffolding-history of the project, the latter
keeps the test suite green for anyone running specs through 109. I'd lean toward
rewriting in place since the spine is meant to be the current best understanding
of each feature, not a fossil record.