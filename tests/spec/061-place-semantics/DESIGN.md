# Place Semantics for Struct Accessors

**Status**: Design / Pre-implementation  
**Catalyst**: Bug 028 (IGC miscompiles SPIR-V functions with TypeArray return types)  
**Branch**: TBD

---

## The Problem

When a `def-struct` has an array-typed field, the compiler generates an accessor function
that returns the array by value:

```llvm
define [4 x i64] @values__data_arr(%DATA-ARR %0) {
  ...
  ret [4 x i64] %extract_0
}
```

In SPIR-V this becomes a function with `TypeArray` as its return type. IGC (Intel Graphics
Compiler) silently miscompiles such functions — the array elements all read back as zero at
runtime. LLVM-IR and SPIR-V are both correct; the bug is in IGC's JIT.

This is documented as Crisp bug 028.

---

## The Architectural Direction: Unify Get/Set via Place Semantics

The root cause of bug 028 is that accessors commit early to "produce a value." Instead,
accessors should produce a **place** — a pointer to the field in the struct's memory — and
let the surrounding context decide whether to load (get) or store (set).

In LLVM IR terms: a GEP result. A pointer can be loaded from (get) or stored to (set).
No array value ever has to cross a function boundary as a return type.

This also unifies the currently-split get and set code paths. Right now:

- Read: accessor call returns a value
- Write: `set!` reconstructs the write target separately, working backwards

With place semantics, both paths share one representation: a pointer. `set!` stores through
it; a read loads through it.

---

## Scope

### Where it applies

**`def-struct`** — memory-backed, always in an alloca. GEP is natural and correct.

### Where it does NOT apply

**`def-record`** — register-based. Members use `extractvalue`/`insertvalue`, not GEP.
Records stay as-is; they undergo SROA and have no memory address to GEP from.

---

## Accessor Taxonomy

There are three kinds of accessor in Crisp, and place semantics applies differently to each.

### Non-overloadable raw accessors (`~x~`, `~~ref~~`, raw `~`)

These are guaranteed to be direct field access — always a GEP, no user logic.
These are the **primary target** for place semantics. They should reliably produce a
pointer to the field and propagate it through nested chains.

### Overloadable accessors (`x~`, `values~`, `~`)

These are arbitrary user-defined (or compiler-generated) functions. They *usually* delegate
to the non-overloadable variant, but are not required to. They remain as function calls.
For the common case (delegation to raw accessor), the GEP will be produced at the
non-overloadable level.

### `def-setter`

Defines a custom set path for an overloadable accessor:

```crisp
(def-setter x~ (p val)
  (declare #'(point float => nil))
  (set! (~x~ p) (- val)))
```

The user can do anything here — call a different accessor, call none at all. `def-setter`
is always respected and never replaced by a raw store through a place pointer. The
`set!` codegen checks for a registered setter before falling back to any default path.

---

## The Nested Accessor Problem

The real payoff — and the real complexity — is nested accessor chains involving cells.

```crisp
(set! (x~ (~ someCell)) 42)
```

Trace with place semantics:

1. `(~ someCell)` — cell dereference. Produces a pointer into GPU memory (addrspace(1))
   pointing to the struct. **Does not load the struct.**
2. `(x~ ptr)` — field accessor chains off that pointer. GEP for the `x` field. Produces
   a pointer into GPU memory pointing to `x`. **Does not load the field.**
3. `(set! ... 42)` — stores 42 directly to that GPU memory pointer.

Without place semantics, step 1 loads the struct into a local copy. Step 2 extracts `x`
from that copy. The `set!` stores to the local copy. The write never reaches GPU memory.
This is the class of bug described in bug 029.

Even with `def-setter` in the picture:

```crisp
(set! (x~ (~ someCell)) 42)
; def-setter for x~ calls: (set! (~x~ p) (- val))
```

The `~x~` call inside the setter also needs to write through the cell's pointer, not into
a local copy. If `p` (the point) was passed by value to the setter, the write is lost.
This requires that `p` be passed as a pointer (or the setter be inlined) so the raw
`~x~` accessor can GEP and store back into GPU memory.

This is an open design question for layer 2 implementation. The key insight is that
**pointer propagation must not be broken at any link in the chain**, including across
function call boundaries to `def-setter`.

---

## Implementation Layers

### Layer 1 — Workaround for bug 028 (targeted, overlay-only)

In the `generate-node-ir` for `semantic-aref` (Case 2, the fixed-size array path), add a
branch: when the `array-node` is a function call to a compiler-generated struct accessor
whose return type is `(array T N)`, detect this and emit a direct two-level GEP into the
struct's alloca rather than calling the accessor function.

This eliminates the array-returning function call at the specific site that triggers the
IGC bug. The accessor function (`values__data_arr`) may still be generated and exported,
but it is no longer called for the element-access pattern that tests 15 and 18 use.

Tests 15 and 18 (`validate-l0-compile-only`) can be promoted to `validate-l0-host-run`
once this is verified correct on hardware.

**Effort**: moderate. Overlay. Does not require patching `macros.lisp`.

### Layer 2 — Generalized place semantics for non-overloadable accessors

Make non-overloadable raw accessors (`~x~`, `~~ref~~`) produce a GEP pointer at codegen
rather than a loaded value. All use sites (reads and writes) resolve through the pointer.

Touches:
- `generate-node-ir` for struct-accessor function calls (non-overloadable path)
- `set!` codegen: after `def-setter` check fails, fall back to store-through-pointer
- Argument passing: when a field value is passed to a function expecting a value type,
  load from the pointer at the call site

This is an architectural change, not a bug fix. Deserves its own branch and TDD cycle.

### Layer 3 — Clean up generated accessor functions

Once layer 2 is in place, the compiler-generated `def-function` accessors that return
array types (or any aggregate type) may be redundant. Evaluate whether they can be
removed or replaced with inline-only forms. Not a priority until layer 2 is stable.

---

## Open Questions

### Nested setter + cell: the hard case

If `def-setter` receives `p` (the point struct) as a **value** parameter copied off the
cell pointer, then `(set! (~x~ p) ...)` inside the setter writes to that local copy.
The cell in GPU memory is never updated. The write is silently lost — the same class of
bug as 029.

Two possible resolutions:

1. **Pass a pointer into the setter**: change the calling convention for setters so that
   when the target was reached via a cell dereference, the setter receives a pointer to
   the struct in GPU memory rather than a copy. This requires knowing, at the call site,
   whether the accessor chain includes a cell dereference — non-trivial.

2. **Inline the setter at the call site**: when the target is a cell-backed struct, the
   compiler inlines the setter body so the raw `~x~` accessor can GEP and store into
   GPU memory directly. Inlining is more predictable but a bigger compiler change.

This is likely **mandatory** to resolve correctly, not optional. Currently untested.

### SPIR-V `Function`-storage-class pointer restriction

Under the SPIR-V `Kernel` capability (which Crisp uses), `Function`-storage-class pointers
**cannot cross function boundaries**. This means:

- Passing a GEP result (which points into a `Function`-class alloca) into a `def-setter`
  as an argument is **illegal in SPIR-V**.
- This makes option 1 above (pass pointer into setter) potentially invalid, depending on
  whether the pointer is into function-local memory or addrspace(1) GPU memory.
- addrspace(1) (global/USM) pointers *can* cross boundaries — so a pointer into cell
  memory is fine. A pointer into a local struct copy is not.

This restriction may **mandate inlining** for setters in the nested cell case, rather than
being a choice.

### Overloadable accessors and place propagation

It is unlikely that the overloadable accessor layer (`x~`, `values~`) can reliably
propagate place pointers. These are opaque function calls — they may or may not delegate
to the raw accessor layer, and the compiler cannot assume their behavior. They remain as
value-returning function calls. Place semantics applies only below them, at the raw
non-overloadable layer.

---

## Test Plan

Layer 1 tests (existing, promoted):
- `060-array/15-hoist-struct-with-array` — `validate-l0-compile-only` → `validate-l0-host-run`
- `060-array/18-hoist-cell-of-struct-with-array` — remains `compile-only` (bug 029 still open)

Layer 2 tests (new, to be written):
- Read through non-overloadable accessor chain
- Write through non-overloadable accessor chain
- Nested: cell → struct → field read
- Nested: cell → struct → field write (the hard case)
- `def-setter` with cell-backed struct
