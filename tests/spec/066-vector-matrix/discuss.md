# 066-vector-matrix: Dev Plan

## Overview

`vector` and `matrix` are the 1D and 2D specializations of `tensor`.
This feature implements them as **syntactic sugar** — the compiler normalizes
`(vector T)` → `(tensor T 1 ...)` and `(matrix T)` → `(tensor T 2 ...)` at
parse time.  All downstream codegen, aref dispatch, and accessor logic are
inherited from the tensor implementation (064-tensor) unchanged.

## Design Decision: Syntactic Sugar

`(vector T)` is NOT a separate type from `(tensor T 1)`. It expands to the
identical 6-tuple canonical form `(tensor T 1 :global :read-write :compact)`.

Rationale:
- N (arity) is always a compile-time constant. The same type-spec machinery
  that distinguishes `(tensor T 1)` from `(tensor T 2)` handles all N.
- No overloading use case requires distinguishing `(vector T)` from a 1D
  tensor — they are semantically identical.
- `def-derived-type` already provides the right tool if a user wants a
  named subtype: `(def-derived-type my-vec (vector float))`.
- Simpler implementation: one def-record template (tensor) handles all arities.

One acknowledged cost: error messages may display `(tensor int 1 ...)` rather
than `(vector int)`. A pretty-printer round-trip can address this later.

## Implementation Plan

### Change 1 — `expand-storage-handle-type-specifier` (src/types/validation.lisp)

Add VECTOR and MATRIX branches ahead of the generic CELL/VECTOR/MATRIX
fallthrough.  Both branches:
  - Require at least one arg (element type) — error otherwise (incomplete).
  - Inject N=1 (vector) or N=2 (matrix) as the second positional arg.
  - Error if a second positional (non-keyword) arg is present:
      `(vector int 3)` → "vector type takes no arity argument; use tensor for N>2"
      `(matrix int 5)` → "matrix type takes no arity argument; use tensor for N>2"
  - Parse ONLY key-value pairs: `:address-space :local`, `:access :read-only`,
    `:align :compact`. Bare values (`:local`, `:read-only`) are NOT valid and
    should produce an intelligent error, e.g.:
      "Unknown keyword ':LOCAL' in vector type spec. Did you mean ':address-space :local'?"
    The bare→key mapping for the suggestion:
      "GLOBAL"/"LOCAL"/"PRIVATE"/"CONSTANT"/"GENERIC"  → :address-space
      "READ-WRITE"/"READ-ONLY"/"WRITE-ONLY"            → :access
      "STD140"/"COMPACT"                               → :align
  - NOTE: the existing tensor expansion path also has a bare-value matching
    branch (lines ~87-97 in validation.lisp). That branch should be replaced
    with the same intelligent error at the same time, for consistency.
  - Return `(tensor T N addr acc aln)` — head is `tensor`, not `vector`/`matrix`.

### Change 2 — `%incomplete-storage-handle-p` (src/macros.lisp)

Currently written only for the cell 3-arg form `(cell T :global :read-write)`.
For the tensor 5-arg form `(tensor T N addr acc aln)` it incorrectly returns T
(incomplete), which would cause a false error when vector/matrix appear in a
`def-kernel` parameter list.

Fix: add a branch — if base is "TENSOR" and (length args) = 5, return NIL
(complete).

### No other changes needed

- `register-builtins`: no change — tensor template already handles N=1 and N=2.
- `analyze-aref-expression`: no change — already counts exactly N index forms.
- `generate-node-ir (semantic-aref)`: no change — tensor codegen is generic over N.
- `get-array-element-type`: no change — handles TENSOR head.
- `%storage-handle-type-p`: no change — already checks "TENSOR".

### Future (not in this batch)
- `set! (length~ m)` for matrix/tensor → compile-time error (N>1 check in
  `analyze-set!-expression`). The affirmative vector case (test 08) works
  without this; only the negative enforcement requires new work.
- Pretty-printer: render `(tensor T 1 ...)` as `(vector T)` in error messages.
- `make-vector` / `make-matrix` constructor helpers.
- Vector/matrix-specific math helpers (dot, transpose, etc.).

## Test Files

| File | What it tests |
|------|---------------|
| `01-vec-arg.crisp` | `(vector int)` as param; `(vector T)` template |
| `02-vec-props.crisp` | `num-dims~`=1, `length~`, `offset~`/`strides~`/`extents~` as (array ulong 1) |
| `03-vec-accessor.crisp` | `(~ v i)` 1D read; templated variant |
| `04-vec-type-constructors.crisp` | `:local`, `:read-only` kwargs; template with address-space |
| `05-mat-arg.crisp` | `(matrix int)` as param; `(matrix T)` template |
| `06-mat-props.crisp` | `num-dims~`=2, strides/extents as (array ulong 2) |
| `07-mat-accessor.crisp` | `(~ m row col)` 2D read; templated variant |
| `08-vec-set-length.crisp` | `(set! (length~ v) n)` valid for vector |
| `errors/vec-wrong-arity.crisp` | `(vector int 3)` → error |
| `errors/mat-wrong-arity.crisp` | `(matrix int 5)` → error |

## Skipped (covered by 064-tensor)
- Passthrough (address-space~/access~): same code path as tensor.
- bytes~ helper: same template, same N.
- set!/overload-accessor/overload-setter: identical machinery.
- tensor-of-struct variants: element-type complexity already proven.
