Endeavor 110 — workgroup-stride
================================

Following endeavor 109 Phase 0, where tile-stride and hardware-stride were
restructured as outer loops over chunk origins, this endeavor introduces the
**workgroup-stride** primitive: the cooperative inner loop that the workgroup
runs to walk a tile's coordinates.

`workgroup-stride` is the building block for `load-tile` / `store-tile`
(endeavor 111), but is a useful primitive in its own right — any kernel that
needs the workgroup to cooperatively process a local tile will use it.

See [chapter 13](../../../docs/chapters/14_control_flow/13_workgroup_stride.md)
for the full design.

### Semantics (recap)

- Iterates the bindings (local coords within a tile) cooperatively across all
  threads of the workgroup, using `(get-local-id k)` as the starting offset
  per dim and `(get-local-work-size k)` as the step.
- If tile-size > workgroup-size, each thread iterates multiple times.
- If tile-size < workgroup-size, threads with local-id beyond the tile extent
  skip via the bounds check.
- Does NOT inject an end barrier (intentional, per chapter 13) — the caller
  inserts `(local-barrier)` explicitly when needed.

### Helper builtins (the warp-aware logic helpers)

- `(warp-id)` — index of the current warp within the workgroup
- `(warp-lane)` — lane within the warp (0–warp-size−1)
- `(warp-count)` — total warps in the current workgroup

These map to SPIR-V `SubgroupId`, `SubgroupLocalInvocationId`, and
`NumSubgroups` respectively.

### Test Plan

#### Phase A — workgroup-stride basics
- `01-basic-1d.crisp` — 1D, tile-size == workgroup-size, one slot per thread
- `02-basic-2d.crisp` — 2D matrix
- `03-tile-larger-than-workgroup.crisp` — Scenario A: each thread iterates >1
- `04-tile-smaller-than-workgroup.crisp` — Scenario B: OOB threads skip

#### Phase B — warp helpers
- `05-warp-id.crisp` — write `(warp-id)` per slot
- `06-warp-lane.crisp` — write `(warp-lane)` per slot
- `07-warp-count.crisp` — write `(warp-count)` once

#### errors/
- `01-arity-mismatch.crisp` — bindings arity ≠ tile arity

### Implementation notes

- workgroup-stride is implemented via overlay (`%expand-workgroup-stride-form`)
  and registered as an expression analyzer.
- AD pre-pass walker (`%expand-stride-macros-in-form` in `src/macros.lisp`) is
  extended to recognize workgroup-stride so the form is fully expanded before
  ANF transform sees it.
- warp builtins follow the existing GPU-builtin plumbing pattern: registered
  in the analyzer table, recognized by `%gpu-builtin-info`, dispatched in the
  `generate-node-ir` method for `semantic-gpu-builtin`.

### Phase 0 caveat (test-only)

For runtime verification without `load-tile`/`store-tile`, the tests here
write to a `:global` vector directly inside the workgroup-stride body. The
chapter doc describes the intended use as walking a `:local` or `:private`
tile; this is purely a test-harness shortcut and will be cleaned up once
load-tile/store-tile land in endeavor 111.
