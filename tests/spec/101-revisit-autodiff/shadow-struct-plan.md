Plan: Structs in AD via Shadow Structs
======================================

Scope
-----

Continuation of endeavor 101 ("if there's math, do it"). Earlier 101 work
unblocked records (records auto-SROA at every function boundary) and the
trivial-zero-gradient path for all-int-record kernels. Structs were
deferred because Chris's invariant says **structs are contiguous memory
and must NOT be SROA'd at function boundaries** — that distinction from
records is intentional.

This plan adopts Gemini's **Shadow Struct** proposal (recorded in
`autodiff-structs-discuss.md`) to support structs in AD without violating
the struct-vs-record architectural invariant. Forward struct memory
layout stays untouched; backward kernels reference a **parallel shadow
struct type** (`<NAME>_ADJ`) that lives in the AD pass's view of the
world.

This unblocks the following test clusters (currently SKIP'd):

- **056-struct-at-kernel-boundary**: 01, 03, 04, 09 (mirror of 048's
  record cluster).
- **031-def-derived-type**: 01, 03, 05, 07 (derived-over-struct mirror
  of 031's record cluster — 20/22/24/26 which we already unblocked).
- The silently-wrong cell-of-struct case (probe-B from our discussion)
  gets fixed cleanly via this design.


Architecture
------------

### The shadow struct rule

For every `(def-struct NAME (f0 T0) (f1 T1) ...)`, the compiler also
mints `(def-struct NAME_ADJ (f0 ADJ_T0) (f1 ADJ_T1) ...)` where
`ADJ_T<i>` is the adjoint type for `T<i>`:

- Float scalar (`float`, `double`, `half`, `bfloat16`) → same type.
- Integer scalar:
  - 8/16/32-bit (`char`, `short`, `int`, etc.) → `float`.
  - 64-bit (`long`, `ulong`) → `double`.
- Nested struct → its shadow struct (`<INNER>_ADJ`).
- Brand → resolve to base, promote per the rules above.

**Note: shadow struct ≠ byte-for-byte clone.** With integer promotion,
`(char x)` (1 byte) becomes `(x float)` (4 bytes) in the shadow. The
shadow struct's memory footprint diverges from the forward's for any
sub-32-bit field. Gemini's "perfect 1:1" claim only holds for all-float
structs.

### Eager minting

Per Chris's choice: every `def-struct` mints its shadow at expansion
time. Simple, no lazy-creation plumbing. Negligible cost in unused
struct definitions (the shadow's accessors, constructor, etc. are dead
code in non-AD builds, eliminated by LLVM).

Implementation hook: late-binding override of
`register-struct-definition` in `src/structs.lisp`. After registering
the forward struct, also generate-and-eval a `(def-struct NAME_ADJ ...)`
form for the shadow. Brand declarations on the forward are NOT copied
to the shadow (gradients of brands aren't meaningful).

### Forward kernel: unchanged

A kernel `(def-kernel k (s &out c) (declare #'(point &out out-c)) ...)`
emits its forward IR with `%POINT` as a struct-by-value parameter,
exactly as today. Forward IR signature is untouched.

### Backward kernel: shadow handles paired with forward handles

The backward kernel mirrors the forward parameter list, **paired** with
shadow types as grad slots:

```
forward:  (def-kernel k (s:point             &out c:cell-float))
backward: (def-kernel k_GRAD (s:point  c:cell-float
                              c_grad:cell-float
                              &out s_grad:cell-point_adj))
```

For storage-handle cases, the shadow rides inside the same kind of
handle:

| Forward param        | Backward grad param           |
|---------------------|-------------------------------|
| `point` (by-value)  | `cell point_adj` (&out)       |
| `cell point`        | `cell point_adj`              |
| `vector point`      | `vector point_adj`            |
| `tensor point N`    | `tensor point_adj N`          |

The forward struct stays where it is; the shadow buffer is allocated
separately by the host (see "Out of scope" → hoist work).

### Backward body: adjoint flow through shadow accessors

Inside the backward kernel, accessor adjoints route to the shadow
struct's corresponding field:

```
;; forward:  c = x~(s)
;; backward (sketch):
;;   t_adj += c_grad
;;   (set! (x~ s_grad) (+ (x~ s_grad) t_adj))   ; in shadow memory
```

For storage-handle shadows the write becomes an atomic-add at the
indexed shadow element, matching the existing tensor-grad accumulation
pattern.


Concrete implementation targets
-------------------------------

### 1. Shadow struct generation hook

**File**: `overlays/crisp-compiler-overlay.lisp` (append).

Override `register-struct-definition` (or wrap-and-call). On every
call:
1. Call the original to register the forward.
2. Build a shadow members list via type-promotion rules.
3. Generate `(def-struct NAME_ADJ ...)` and `eval` it.

Skip cases:
- Already a shadow (name ends in `_ADJ`) — avoid infinite recursion.
- Record types — records don't need shadows (already handled via SROA).
- All-brand-only structs — degenerate, skip with no shadow.

Helper: `%shadow-struct-name` (e.g. `point` → `point_adj` interned in
same package).
Helper: `%shadow-field-type` (promote per the rules above).

### 2. Backward-kernel signature: pair forward params with shadow handles

**File**: `overlays/crisp-compiler-overlay.lisp` (override `%expand-
struct-kernel-inputs` analog OR extend `%expand-record-kernel-inputs`).

For each struct-typed kernel input `s`:
- Don't destructure into field syms (unlike records).
- Add a grad-out param `s_grad` whose type wraps `<S>_ADJ` in the same
  handle shape as `s`:
  - `s:point` → `s_grad:(cell point_adj :address-space :global)` &out.
  - `s:(cell point ...)` → `s_grad:(cell point_adj ...)` &out.
  - `s:(vector point ...)` → `s_grad:(vector point_adj ...)` &out.

This is structurally similar to how float scalars get wrapped in a
cell for their grad output (per 101).

### 3. Backward walk: accessor-write rule for shadow

**File**: `overlays/crisp-compiler-overlay.lisp` (extend `%handle-
single-value-backward` or add a separate rule).

When the forward ANF has `(t (x~ s))` and `s` is a struct param with
a shadow buddy `s_grad`:
- Allocate an adjoint accumulator `t_adj` (existing).
- Emit a backward rule: `(set! (x~ s_grad) (+ (x~ s_grad) t_adj))`
  for direct-by-value struct kernel params.
- For cell-of-struct cases: `(set! (x~ (~ s_grad)) (+ (x~ (~ s_grad)) t_adj))`.
- For tensor-of-struct cases with index: atomic-add at the indexed
  position.

The shadow accessor `(x~ s_grad)` works because the shadow struct has
the same field names as the forward (just promoted types).

### 4. Constructor backward (for in-kernel make-point)

**File**: `overlays/crisp-compiler-overlay.lisp` (extend
`%handle-single-value-backward` — same case we added for records).

When forward has `(p (%construct-struct point ax ay))` in the ANF and
`p` is a temp:
- This case applies when the kernel internally builds a struct via
  make-point and then uses it.
- Adjoints from later uses of `p` get accumulated into a synthetic
  shadow `p_adj` (a local point_adj).
- Constructor backward: `ax_adj += (x~ p_adj); ay_adj += (y~ p_adj)`.

For records this works via SROA explosion at the constructor. For
structs we'd need a local shadow accumulator. Probably **defer this
case to a follow-up** — the kernel-boundary case is more common and
strictly simpler.

### 5. Gate widening

**File**: existing overlay edits.

Extend `%count-differentiable-contributions` (sub-function gate) and
`%has-diff-capable-scalar-input-p` (kernel-side relaxed-gate) to also
recognize struct types as having at least one differentiable
contribution if their shadow has any non-empty fields. Or — simpler —
treat any struct with at least one float/int field as differentiable.

This unblocks kernel macroexpansion past the existing
"no differentiable parameters" check.

### 6. Hoist note (separate, future work)

**File**: `crisp/docs/hoist-todo.md` or new comment in hoist source.

**Critical note for whoever does hoist + AD later**:
> Shadow structs do NOT have the same byte layout as their forward
> counterparts when integer fields are present (8/16/32-bit ints
> promote to float = 4 bytes; 64-bit ints promote to double = 8 bytes).
> The host-side allocator for the shadow buffer must use `sizeof(<NAME>_ADJ)`,
> not `sizeof(<NAME>)`. The metacrisp should expose both sizes so
> the hoist code generator can allocate correctly.

We are NOT doing hoist + AD work here. But the comment must land so
future-us doesn't trip.


Test strategy
-------------

### Probe-driven TDD

Add a few probe-shape tests in `101-revisit-autodiff/`:

1. **Bare struct kernel param**: `point` with float fields. Output
   cell-float. Body does `(* (x~ p) (y~ p))`. Verify backward writes
   to `p_grad`'s x and y shadow fields correctly.
2. **Mixed float+int struct fields**: shadow has promoted int field.
   Verify shadow layout and adjoint flow.
3. **Cell-of-struct kernel param**: the silently-broken case B. Verify
   the backward writes per-field to the shadow cell.

### Spine-of-specs sweep

Remove `SKIP-WITH[--differentiate]` from the 8 unblocked tests:

| Cluster | Tests |
|---------|-------|
| 056-struct-at-kernel-boundary | 01, 03, 04, 09 |
| 031-def-derived-type          | 01, 03, 05, 07 |

For 056/04 (nested structs): same recursive pattern as the records
work. The shadow struct's nested fields are themselves shadows.


Open questions
--------------

1. **Brand fields**: gradients of branded primitives — `(field token-t)`
   where `token-t` is a brand over ulong. The shadow field is `(field
   double)` (per promotion). The brand identity is lost in the shadow
   — that's mathematically correct (gradients don't carry brands)
   but might surprise users. Document.

2. **Multi-shadow types**: if `point` is used in both float and
   double-promotion contexts, do we need two shadow types? Probably
   not — adjoint type per field is determined statically from the
   forward field type, not from usage. So one shadow per forward
   struct is sufficient.

3. **Member-wise struct add**: for accumulating shadow values inside
   the backward kernel body (when a struct value is used twice in a
   sub-expression and adjoints need to merge). Not needed for the
   kernel-boundary case but worth flagging if it comes up.

4. **make-<NAME>_ADJ constructor visibility**: the auto-minted shadow
   gets a `make-point_adj` constructor by default. Users could
   accidentally call it. Probably want to mark it system-generated so
   it doesn't pollute autocomplete/error messages — but the existing
   def-struct macro doesn't have that knob. Could be addressed by a
   naming convention check in the AD pass.


Risks
-----

- **Eager minting touches every def-struct**, including ones used in
  forward-only code. Cost: increased function-table population. Likely
  small but worth quantifying after first build.
- **Sub-function struct params still unsupported**. The shadow-struct
  approach doesn't naturally extend to sub-function backward signatures
  with our current multi-value-return convention. Either: (a) sub-fn
  shadows take a shadow `&out` param instead of multi-value-return,
  or (b) defer struct sub-function params. Defer for now.
- **Cell-of-struct silent-bug** is currently masking issues in test
  suites. Fixing it might surface tests that were passing for the
  wrong reason. Survey before declaring done.


Effort estimate
---------------

- Shadow struct minting hook (1): ~half day.
- Backward kernel signature with shadow grad params (2): ~half day,
  reuse existing patterns.
- Backward walk accessor-write rule (3): ~half day.
- Gate widening (5): few hours.
- Hoist documentation note (6): 30 min.
- Test sweep + iteration: half day.

Total: **~2 days end-to-end**, ignoring sub-function struct params and
hoist work.


Out of scope (this plan)
------------------------

- **Sub-function struct params**. Different convention question
  (return-by-shadow vs &out-shadow). Follow-up endeavor.
- **Hoist + AD for structs**. Host needs shadow buffer allocation
  with the correct (different) sizeof. Documented as a future-work
  note (target #6 above).
- **In-kernel constructor backward for structs** (target #4). Less
  common pattern; defer until 056/04 nested-structs case is tackled.
- **Path B (preserve int gradients)**. We're committed to Path A
  (promote int → float adjoints) per 101's existing convention.
  Path B would require fixed-point arithmetic infrastructure we
  don't have.


Files anticipated to change
---------------------------

| File | How |
|------|-----|
| `overlays/crisp-compiler-overlay.lisp` | APPEND — shadow minting helper, override of `register-struct-definition`, extended kernel-input expansion, new backward-walk accessor rule, gate widening |
| `src/macros.lisp` (`def-struct`) | possibly PATCH — only if late-binding `register-struct-definition` doesn't work cleanly. Prefer overlay. |
| `tests/spec/101-revisit-autodiff/0Y-shadow-struct-*.crisp` | NEW — probe TDD tests |
| `tests/spec/056-struct-at-kernel-boundary/*.crisp` | EDIT — remove SKIP-WITH on 01, 03, 04, 09 |
| `tests/spec/031-def-derived-type/*.crisp` | EDIT — remove SKIP-WITH on 01, 03, 05, 07 |
| (deferred) hoist docs | NEW — note about shadow struct sizeof divergence |
