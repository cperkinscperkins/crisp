# 071 — Compact Tensor Aref Optimization

## Goal

When the `:align` of a tensor/vector/matrix is `:compact` and known at compile
time, generate a simpler flat-index formula that avoids reading from the
tensor's runtime stride array.  When `:align` is `:strided`, or when the type
is incomplete (template / unknown alignment), keep the current safe path that
reads strides at runtime.


## Background: How Flat Index Is Computed Today

A tensor's ABI struct carries (among other things) two parallel arrays of
`N` ulongs: `strides[k]` and `extents[k]`.  The current `~` codegen reads
each `strides[k]` from the struct and computes:

```
flat = offset[0] + i_0 * strides[0]
     + offset[1] + i_1 * strides[1]
     ...
     + offset[N-1] + i_{N-1} * strides[N-1]
```

(Offsets are usually zero at the kernel boundary but are preserved for
generality.)

For `:compact` tensors the stride pattern is fixed:

```
strides[N-1] = 1
strides[k]   = extents[k+1] * extents[k+2] * ... * extents[N-1]   (k < N-1)
```


## Optimized Compact Path

### N = 1 (vector)

`strides[0] = 1` always.  The flat index collapses to:

```
flat = offset[0] + i_0
```

Zero stride-array reads, zero multiplies.  This is the highest-value case
because vectors are the most common tensor type.

### N = 2 (matrix)

Using Horner's method on extents:

```
flat = (i_0 * extents[1] + i_1) + offset_total
```

One extent read, one multiply, one add.  Current path: two stride reads, two
multiplies.  Saves one memory load and one multiply per access.

### N ≥ 3 (general compact tensor)

Generalised Horner:

```
flat = (...((i_0 * ext_1 + i_1) * ext_2 + i_2) * ext_3 + i_3 ...)
```

Always N-1 multiplies, N-1 adds, N-1 extent reads — vs N stride reads and N
multiplies in the general path.


## Dispatch Rule

| Situation | Path |
|---|---|
| Type fully resolved, `:align :compact` | Compact (Horner / stride=1) |
| Type fully resolved, `:align :strided` | Strided (current) |
| Incomplete type / template (Aln unknown) | Strided (current, safe) |


## Implementation Plan

### 1. `src/analysis/structs.lisp` — `analyze-aref-expression`

The tensor branch currently calls `%build-tensor-flat-index-form`.  The fix:

- After resolving the tensor type, extract the `:align` c-t property.
- If `:compact`, call a new `%build-tensor-compact-flat-index-form` that
  emits the Horner formula using extents accessors.
- Otherwise call the existing `%build-tensor-flat-index-form` (unchanged).

The align value is the 6th element of the expanded tensor type tuple:
`(tensor elem N addr access align)`.  It is also accessible via `get-array-align`
or by extracting position 5 from the expanded type list.

### 2. New helper: `%build-tensor-compact-flat-index-form`

For N=1: returns `(+ (~ (offset~ v) 0) (to-ulong i_0))` (no stride access).
For N≥2: returns the Horner expression built from extents accessors.

The offset accessor is `(~ (offsets~ v) k)` and the extent accessor is
`(~ (extents~ v) k)` — same accessors already used in the strided path.

### 3. No `generate-node-ir` changes needed

The semantic-aref node structure is the same; only the flat-index expression
differs.  The existing IR emitter handles both paths identically.

### 4. Overlay vs source

Implement via the overlay pattern (append to `overlays/crisp-compiler-overlay.lisp`)
rather than patching `src/analysis/structs.lisp` directly:
- Redefine `analyze-aref-expression` to dispatch on align for the tensor path
- Define `%build-tensor-compact-flat-index-form` as a new function


## Spec Tests

| File | What it checks |
|---|---|
| `01-compact-vector-get-ir.crisp` | IR: compact vector GET has no `mul i64` |
| `02-compact-vector-set-ir.crisp` | IR: compact vector SET has no `mul i64` |
| `03-compact-matrix-get-ir.crisp` | IR: compact matrix GET has exactly one `mul i64` (Horner) |
| `04-compact-vector-round-trip.crisp` | Hardware: compact GET+SET correctness |
| `05-strided-vector-ir.crisp` | IR regression: strided GET still has `mul i64` |
| `06-strided-vector-round-trip.crisp` | Hardware: strided GET+SET correctness |
| `07-alignment-dispatch.unit.lisp` | Unit: dispatch for compact/strided/template-unknown |


### IR Validator approach

Each validator receives the LLVM-IR string for the compiled file.

- **`validate-071-01-compact-vector-get-ir`** and **`validate-071-02-compact-vector-set-ir`**:
  - Does NOT contain `mul i64` in the kernel function body.
  - DOES contain `add i64` (the offset addition).

- **`validate-071-03-compact-matrix-get-ir`**:
  - Contains exactly one `mul i64` in the kernel body (the single
    Horner multiply `i_0 * ext_1`).
  - Does NOT load from the strides array field (field index 2 of the
    TENSOR struct type).

- **`validate-071-05-strided-vector-ir`**:
  - DOES contain `mul i64` (the stride multiply is present).


## Files to Touch

| File | Change |
|---|---|
| `overlays/crisp-compiler-overlay.lisp` | Redefine `analyze-aref-expression`; add `%build-tensor-compact-flat-index-form` |
| `src/metadata-val.lisp` | Add validators 01, 02, 03, 05 |
| `tests/ci-stop.txt` | Update to `071-compact-aref-opt` (after green) |
