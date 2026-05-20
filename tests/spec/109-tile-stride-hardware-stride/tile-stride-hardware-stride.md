Now we are going to finish the remaining"stride" macros.  They are outlined in
docs\chapters\14_control_flow\11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride.md

In 093 we added loop-vector-stride to Crisp. Then in 105 we added support tensor-stride and grid-stride

Now we'll work on tile-stride and hardware-stride.  These shouldn't be too
dissimilar from tensor-stride, but both of these define "helper" macros within
their body, which none of the other strides do.

We'll want similar testing as we've seen in 093 and 105, covering the basics but also testing of the helpers. Some tests should include hoist testing.  Most tests should be working correctly on the --differentiate pass, and we'll undoubtedly want a few that use VERIFY-AUTODIFF to test the differentiation "on metal". As usual, I usually prefer to start with the TDD tests defined first and then realize their implementation "in order", so we should take dependencies into account when planning the tests.

Note that docs\chapters\14_control_flow\07_hoisting_and_enqueing_a_kernel.md discusses the :strategy declaration, of which `:strategy :tiled` and `:tile-shape` are key to communicationg tile and global size expectations out from the kernel to the metadata and hoisting code. I don't believe the `:tiled` strategy is supported yet, but that's fine, we can address it later. 


Design decisions agreed for this endeavor
-----------------------------------------

1. **Helper naming is plural**: `tile-coords`, `tile-indices`, `tensor-coords`. The chapter doc
   (14/11) has been updated for consistency.

2. **Helper semantics** (confirmed with Chris):
   - `tile-indices x` = `(floor x tile-size)`   — which tile is this binding in?
   - `tile-coords x`  = `(mod x tile-size)`     — where am I inside that tile?
   - `tensor-coords (idx) (t)` = `(+ (* idx tile-size) t)` — round-trip back to the
     problem-space coordinate.
   Bindings are no different than `tensor-stride`: they walk the entire problem space,
   each coordinate visited exactly once. The helpers slice the binding into
   tile-index + tile-coord views.

3. **Ragged edges**: tensor extents that aren't a multiple of the tile size are handled by
   *naive striding* (option (c)) — the stride loop simply visits every coordinate as in
   `tensor-stride`, and any ragged-edge bounds checking is the user's responsibility (typically
   via `check-thread-bounds`). When `--runtime-checks` is active, the compiler may insert an
   assertion. The chapter doc 14/11 should be updated with a "Ragged edges" subsection.

4. **`:tiled` hoist strategy**: chapter 14/07 documents the host-side counterpart to
   `tile-stride` via `(global-size :strategy :tiled :tile-shape '(...))`. The two chapters
   should cross-reference each other. Some tile-stride tests will use the `:tiled` strategy
   declaration; if the hoist generator does not yet implement `:tiled`, the hoist-flavored
   test (Phase E #15) may have to be compile-only until the generator catches up.

5. **`load-tile` / `store-tile` deferred**: documented in chapters 10/15 and 10/18 but
   implementation is out of scope for endeavor 109 (the async `request-load-tile`/
   `request-store-tile` variants pull in even more). They will be a follow-on endeavor.

6. **Implementation note** (from chapter 14/11 line 153-156): tile-stride and
   hardware-stride share the same iteration loop as tensor-stride; the chunking
   variants only affect how the helper macros convert coordinates. This means the
   implementation should mostly free-ride on the tensor-stride codegen, with new work
   limited to arity validation + scoped helper macro injection.


Test Plan (in TDD dependency order)
-----------------------------------

### Phase A — tile-stride basics (no helpers)
Exercises the stride loop with a tile size declared but body that doesn't use the helpers.

- `01-basic-1d.crisp`        — tile-stride on a vector, size-list
- `02-basic-2d.crisp`        — tile-stride on a matrix, size-list (twin of 105/02)
- `03-basic-3d.crisp`        — tile-stride on a 3D tensor, size-list
- `04-tile-tensor.crisp`     — tile-stride with a tile-tensor argument instead of size-list

### Phase B — tile-stride strict variants
Layout-tag plumbing. (2 of 4 tags; 105 already covered the symmetry across all four.)

- `05-strict-row-major.crisp`        — `:row-major` tag
- `06-strict-contiguous-first.crisp` — `:contiguous-first` tag

### Phase C — helper macros (the new wrinkle)
- `07-tile-coords.crisp`     — write `tile-coords` result into a scratch tensor, verify it is `mod`
- `08-tile-indices.crisp`    — same for `tile-indices`, verify it is `floor`
- `09-tensor-coords.crisp`   — round-trip: `tensor-coords(tile-indices, tile-coords) == binding`
- `10-helpers-combined.crisp` — neighbor-tile pattern; intentionally ragged extents (e.g. 30
   with tile 8 → 8,8,8,6) exercised with `check-thread-bounds`

### Phase D — hardware-stride
- `11-hw-workgroup-idx-2d.crisp` — `:workgroup-idx` with 2D enqueue (declare both
   `global-size :set-to '(8 8)` and `local-size :set-to '(4 4)`)
- `12-hw-warp-idx-1d.crisp`      — `:warp-idx` with `local-size` = warp size; 1D vector + 1 binding
- `13-hw-warp-idx-flatten-2d.crisp` — `:warp-idx` with **2D global-size + 1 binding**; locks
   in the rule that warp iteration is always linear over the flattened global execution space
- `14-hw-strict-with-helpers.crisp` — strict variant + tile-coords/tile-indices

### Phase E — on-metal
- `15-diff-tile-stride.crisp`   — VERIFY-AUTODIFF on a tile-stride float-scale kernel
   (per-element output, analog of 107/01)
- `16-hoist-tile-stride.crisp`  — TEST-HOIST[L0]; declares `(global-size :strategy :tiled
   :tile-shape '(...))`. May need to defer the hoist directive if `:tiled` not yet
   implemented in the hoist generator; falls back to compile-only.

### errors/
- `01-arity-mismatch.crisp`              — tile size-list arity ≠ binding arity
- `02-strict-tag-conflict.crisp`         — `:row-major` tag vs a known `:col-major` CT
- `03-hw-warp-idx-binding-count.crisp`   — `:warp-idx` with >1 binding (illegal; warp
   iteration is always linear, so binding count must be exactly 1 regardless of global-size arity)

Total: 16 + 3 = 19 tests.

Doc updates that should accompany the implementation
----------------------------------------------------

- Add "Ragged edges" subsection to chapter 14/11
- Cross-reference 14/07 (`:tiled` strategy) ↔ 14/11 (tile-stride)
- Confirm plural helper naming everywhere in 14/11 (in progress)


Known limitations carried forward:
----------------------------------

- :warp-idx warp size is hardcoded (to-ulong 32) — should become (get-warp-size) (SPIR-V SubgroupSize) when that builtin is implemented. Correct on NVIDIA/Intel, incorrect on AMD (warp size 64).
- :tiled hoist strategy still not implemented in the hoist generator (109/16 uses :set-to 4 for now).
- Negative test 02 expects tensor-stride: prefix because tile-stride delegates layout-tag-vs-CT checks. Cosmetic; can be fixed later by replicating the check in tile-stride.
