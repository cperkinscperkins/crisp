# 072 — Compact-Offset Tensor Aref

## Background

In 071 the `:compact` aref optimization was implemented.  `:compact` eliminates
both stride reads *and* offset reads from the flat-index formula because it
guarantees offset=0 at the kernel boundary.

This feature adds a third alignment tier:

| `:align` | flat index formula |
|---|---|
| `:compact` | `i` (N=1) or Horner on extents — no offsets, no strides |
| `:compact-offset` | Horner on extents + offset sum — no strides |
| `:strided` | full offset + stride reads (safe fallback) |

`:compact-offset` is the alignment used when data is densely packed (strides are
fixed by extents) but the starting offset may be non-zero — e.g. a sub-view of a
`:compact` allocation.


## Semantics Contract

- `:compact` at a kernel boundary: caller guarantees all offsets are zero.
  Violation is a logic error; runtime checks may be added under future debug flags.
- `:compact-offset` at a kernel boundary: strides are compact (= Horner on
  extents), but offsets may be non-zero.  Caller must supply correct offsets.
- Sub-view derivation rule: slicing a `:compact` tensor produces a `:compact-offset`
  tensor (compact strides, non-zero offset).


## Implementation

### `src/enums.lisp`
`(def-enumeration align :compact :compact-offset :strided)`

### `src/types/validation.lisp`
All three vector/matrix/tensor branches accept `:compact-offset` in both the bare
and keyed forms.

### `src/analysis/structs.lisp` (via overlay)
- `%get-tensor-align`: returns `:compact-offset` for the new value
- `%build-tensor-compact-flat-index-form`: **updated** — drops offset terms entirely
- `%build-tensor-compact-offset-flat-index-form`: **new** — Horner + offset sum
  (moved from old `%build-tensor-compact-flat-index-form`)
- `analyze-aref-expression`: three-way cond dispatch


## Spec Tests

| File | What it checks |
|---|---|
| `01-compact-offset-vector-get-ir.crisp` | IR: `:compact-offset` vector GET has no stride mul, HAS offset read |
| `02-compact-offset-vector-set-ir.crisp` | IR: `:compact-offset` vector SET same |
| `03-compact-offset-round-trip.crisp` | Hardware: `:compact-offset` with non-zero offset produces correct result |
| `04-compact-no-offset-ir.crisp` | IR regression: `:compact` vector GET still has no offset read (071 strengthened) |
| `05-alignment-dispatch.unit.lisp` | Unit: all three tiers dispatch correctly |


## Validators (in `src/metadata-val.lisp`)

- `validate-072-01-compact-offset-vector-get-ir`
  - DOES contain `add i64` (offset addition present)
  - Does NOT contain stride mul (no `%071-has-stride-mul`)
  - DOES load from offset field (i32 0, i32 1 in struct GEP)

- `validate-072-02-compact-offset-vector-set-ir`
  - Same checks as 01

- `validate-072-04-compact-no-offset-ir`
  - Does NOT contain stride mul
  - Does NOT load from offset field  ← the strengthened 071 check


## Files to Touch

| File | Change |
|---|---|
| `src/enums.lisp` | Add `:compact-offset` |
| `src/types/validation.lisp` | Accept `:compact-offset` in all three branches |
| `overlays/crisp-compiler-overlay.lisp` | New/updated helper fns + `analyze-aref-expression` |
| `src/metadata-val.lisp` | Add validators 01, 02, 04 |
| `tests/ci-stop.txt` | Update to `072-compact-offset-aref` (after green) |
