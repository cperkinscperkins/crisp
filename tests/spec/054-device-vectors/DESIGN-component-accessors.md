# Device Vector Component Accessors — Design Notes

## Syntax

```crisp
(x~ v)              ; extract x (index 0)
(y~ v)              ; extract y (index 1)
(z~ v)              ; extract z (index 2)
(w~ v)              ; extract w (index 3)

(set! (x~ v) val)   ; replace x component, rebind v to new vector
(set! (y~ v) val)   ; replace y component, rebind v to new vector
```

## Why Not `(~ v 0)`?

`(~ v index)` is reserved for the future **vector Storage Handle** (buffer of
vectors), where `(~ someVec i)` will dereference element `i` from a stored
buffer — analogous to how `(~ someCell)` dereferences a scalar cell today.
Using it for SSA component extraction would collide with that future meaning.

`x~`/`y~`/`z~`/`w~` are distinct affordances that operate on register-level
SSA values, not memory.  GPU programmers will recognise them immediately
(`.x/.y/.z/.w` is universal across GLSL, HLSL, OpenCL, Metal).

## Semantic Model

Device vector components are **SSA values** — there is no "pointer to element
N of a register vector".  LLVM's `extractelement` / `insertelement`
instructions (SPIR-V `OpCompositeExtract` / `OpCompositeInsert`) operate on
values, not addresses.

Therefore:
- `(x~ v)` → `extractelement` — returns a scalar
- `(set! (x~ v) val)` → `insertelement` + **rebind v** to the new vector.
  `v` is SSA-updated, not mutated in place.

This is honest about what hardware actually does and avoids the fiction of
in-place mutation for register values.

## Implementation Plan

### 1. New LLVM binding (`crisp-llvm-bindings-overlay.lisp`)

```lisp
(defcfun ("LLVMBuildExtractElement" llvm-build-extract-element) :pointer
  (builder :pointer) (vec-val :pointer) (index :pointer) (name :string))
```

`LLVMBuildInsertElement` is already bound.

### 2. Analysis (`crisp-compiler-overlay.lisp`)

Register `x~`, `y~`, `z~`, `w~` as expression analyzers
(via `def-expression-analyzer`) pointing to a single handler
`analyze-dvec-component-ref`:

- Validate the argument is a `:device-vector` type
- Check component index is in range for the vector's width
  (e.g. `w~` on `float2` → error)
- Return `(make-semantic-extract-value :type <component-scalar-type>
                                       :aggregate-node <arg-node>
                                       :index <0-3> ...)`

Type of `(x~ v)` where `v: ushort2` → `ushort`.
Type of `(x~ v)` where `v: float4` → `float`.

### 3. Codegen — extend `semantic-extract-value` (`crisp-compiler-overlay.lisp`)

Current codegen uses `llvm-build-extract-value` (for LLVM struct aggregates).
Device vectors are LLVM *vector* types and require `llvm-build-extract-element`.

Redefine `generate-node-ir` for `semantic-extract-value`:
- If aggregate type is `:device-vector` → `llvm-build-extract-element`
- Otherwise → existing `llvm-build-extract-value` (struct aggregate path)

Same pattern for `semantic-insert-value`:
- If aggregate type is `:device-vector` → `llvm-build-insert-element`
- Otherwise → existing `llvm-build-insert-value`

### 4. Codegen — extend `semantic-set!` (`crisp-compiler-overlay.lisp`)

`analyze-set!-expression` already handles `(set! (x~ v) val)` by
re-analyzing `(x~ v)` with `:write` mode, producing
`semantic-set! { target: semantic-extract-value, value: ... }`.

Add a third case to `generate-node-ir` for `semantic-set!`:

```
((semantic-extract-value-p target-node)
  sub-case A — aggregate is semantic-var-read (local variable):
    1. load current vector from alloca
    2. llvm-build-insert-element → new vector
    3. store new vector back to alloca
    → returns new vector value

  sub-case B — aggregate is semantic-aref (cell deref, test 27):
    1. re-run semantic-aref codegen → (values loaded-vec nil cell-ptr)
    2. llvm-build-insert-element → new vector
    3. llvm-build-store new vector to cell-ptr
    → returns new vector value)
```

## Test Sequence (TDD)

| File | What it tests |
|------|--------------|
| `15-component-read.crisp` | `x~` on float2 → float |
| `17-all-accessors.crisp` | `y~`/`z~`/`w~` on wider vectors |
| `19-component-in-expr.crisp` | `(+ (x~ v) (y~ v))` |
| `21-component-set.crisp` | `(set! (x~ v) newx)` rebinds local v |
| `23-component-of-literal.crisp` | `x~` on inline `##(3.0f 4.0)` |
| `25-set-multi-components.crisp` | sequential `set! x~` then `set! y~` |
| `27-component-set-in-cell.crisp` | `(set! (x~ (~ cell)) 5.0)` — cell read-modify-write |
| `errors/04-accessor-on-scalar.crisp` | `x~` on plain `float` → error |
| `errors/05-accessor-out-of-range.crisp` | `w~` on `float2` → error |
| `errors/06-set-component-in-read-only-cell.crisp` | write to read-only cell → error |

## Future: SSA-in-Storage-Handle Generalisation

Test 27 (`set! (x~ (~ cell)) val`) is the first instance of a general pattern:

> **modify one structured sub-element of a value that lives in a storage handle**

The same load-modify-store sequence will be needed for:
- Vector storage handle: `(set! (x~ (~ vec-handle i)) val)` — element of a
  stored vector buffer
- Matrix: `(set! (~ matrix i j) val)` — an element within a stored matrix row
- Tensor: likewise

Sub-case B in `semantic-set!` above is the seed of this generalisation.
When future storage handles arrive, the same pattern should be extended
rather than duplicated.
