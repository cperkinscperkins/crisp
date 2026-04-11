# 068-tensor-kernel-boundary: Dev Plan

## Overview

This feature brings tensor, vector, and matrix to the kernel boundary.
There are two paths:

- **def-kernel**: The user declares Storage Handle params normally.
  The compiler auto-SROA-explodes them to scalars and generates marshalling.
- **def-kernel-exact**: The user declares all scalar args explicitly and
  calls `marshall-vector` / `marshall-matrix` to assemble the Storage Handle.
  (Analogous to the existing `marshall-cell`.)

`marshall-tensor` for N>2 in def-kernel-exact is **deferred** to the next
endeavor. def-kernel auto-expansion will support arbitrary N.

## SROA Layout

For a tensor param `v` of type `(tensor T N ...)`:

| Scalar arg          | Type                          |
|---------------------|-------------------------------|
| `v_PTR`             | `(c-pointer :address-space A)` |
| `v_BYTE_SIZE`       | `ulong`                       |
| `v_OFFSET_0..N-1`   | `ulong` × N                   |
| `v_STRIDE_0..N-1`   | `ulong` × N                   |
| `v_EXTENT_0..N-1`   | `ulong` × N                   |
| `v_LENGTH`          | `ulong`                       |

Total: `2 + 3N + 1` scalar args.

- Vector (N=1): 6 scalar args
- Matrix (N=2): 9 scalar args
- Tensor N=3: 12 scalar args

## marshall-vector / marshall-matrix Signatures

Both are macros, modelled on the existing `marshall-cell` macro.

```lisp
;; vector (N=1): 7 args after the type
(marshall-vector type-alias byte-size ptr offset-0 stride-0 extent-0 length)

;; matrix (N=2): 10 args after the type
(marshall-matrix type-alias byte-size ptr
                 offset-0 offset-1
                 stride-0 stride-1
                 extent-0 extent-1
                 length)
```

The type-alias must be a complete type spec (fully specified addr/access/align).
Both macros expand to `(MAKE-TENSOR_...) :parent (MAKE-STORAGE_...) :offset ...`
using the same template instantiation pattern as `marshall-cell`.

## Implementation Plan

### Key: %incomplete-storage-handle-p sees RAW type specs

`%validate-kernel-parameters` calls `%incomplete-storage-handle-p` on the type
spec BEFORE `expand-storage-handle-type-specifier` runs. It uses
`%resolve-alias-strict` (alias expansion only, no sugar expansion). So:

- `(vector int)` → base="VECTOR", args=(int), length=1 ≠ 3 → **incomplete** ✓
- `(vector int :address-space :global)` → is-kw present but missing :access → **incomplete** ✓
- `(vector int :address-space :global :access :read-write)` → both present → complete ✓
- `(def-type my-v (vector int :address-space :global :access :read-write))` + use alias → `%resolve-alias-strict` expands it → complete ✓

The `%incomplete-storage-handle-p` patch from 066 (tensor 5-arg → complete) only
applies to already-expanded forms (post `expand-storage-handle-type-specifier`).
It does NOT interfere with the validation path here.

### Change 1 — `%explode-kernel-params` (src/macros.lisp)

Add a TENSOR branch after the CELL branch (line ~348). For a param `p` of
canonical type `(tensor T N addr acc aln)`:
- Generate `p_PTR`, `p_BYTE_SIZE`, then `p_OFFSET_k`, `p_STRIDE_k`, `p_EXTENT_k`
  for k in 0..N-1, then `p_LENGTH`.
- N comes from `(nth 2 canonical)` — always a compile-time integer.
- Address-space `A` comes from `(nth 3 canonical)`.
- Push types: ptr type for PTR, ulong for everything else.
- Push reassembly binding:
  `(p (marshall-tensor-internal type p_BYTE_SIZE p_PTR offsets strides extents p_LENGTH))`
  or emit the appropriate `marshall-vector` / `marshall-matrix` call.

NOTE: This same function is also the auto-expansion path for `def-kernel`, so
supporting arbitrary N here means `def-kernel` works for all tensor arities.

### Change 2 — `marshall-vector` macro (src/macros.lisp)

New defmacro analogous to `marshall-cell`:
- Validates type-alias is a complete tensor N=1 spec (error otherwise).
- Instantiates tensor template + storage template.
- Expands to MAKE-TENSOR constructor with virtual-array fields for offsets/strides/extents.

### Change 3 — `marshall-matrix` macro (src/macros.lisp)

Same as Change 2 but for N=2. Error if type-alias is not a complete tensor N=2 spec.

## Test Files

| File | What |
|------|------|
| `01-k-exact-marshall-vector.crisp` | def-kernel-exact + marshall-vector, basic |
| `02-k-exact-marshall-matrix.crisp` | def-kernel-exact + marshall-matrix, basic |
| `03-k-exact-templated-vector.crisp` | def-kernel-exact templated with marshall-vector |
| `04-def-kernel-vector.crisp` | def-kernel with vector param (auto-SROA) |
| `05-def-kernel-matrix.crisp` | def-kernel with matrix param |
| `06-def-kernel-tensor-n3.crisp` | def-kernel with tensor N=3 param |
| `07-def-kernel-templated-vector.crisp` | templated def-kernel + gen- |
| `errors/incomplete-tensor-in-kernel.crisp` | `(tensor int 3)` missing addr/access in def-kernel → error |
| `errors/incomplete-vector-in-kernel.crisp` | `(vector int)` missing addr/access in def-kernel → error |
| `errors/incomplete-matrix-in-kernel.crisp` | `(matrix int)` missing addr/access in def-kernel → error |
| `errors/incomplete-vector-partial-in-kernel.crisp` | `(vector int :address-space :global)` missing access → error |
| `errors/k-exact-storage-handle.crisp` | Storage handle directly in def-kernel-exact → error |
| `errors/marshall-vector-wrong-n.crisp` | marshall-vector with N=2 type → error |

## Deferred

- `marshall-tensor` for arbitrary N in def-kernel-exact (next endeavor after this one).
- `make-scratch-vector` / `make-scratch-matrix` (side-channel Storage Handles).
