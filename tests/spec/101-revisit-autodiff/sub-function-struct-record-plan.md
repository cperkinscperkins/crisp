Plan: Sub-Function Record (and later Struct) Parameter Differentiation
======================================================================

Scope of this plan
------------------

Continuation of endeavor 101 ("if there's math, do it"). The original 101
work widened the *kernel-level* differentiability set to include integer
scalars, integer cells, integer tensors, and integer record fields. This
plan extends the gap-closure to `def-function`s that take a `def-record`
or `def-struct` parameter (e.g. `dist(point, point) => int` from
`031/03-derived-equal-subst-struct.crisp`).

After investigation we now know records and structs behave very
differently in the existing compiler, so the work splits cleanly:

- **Part 1 (records): the primary scope of this plan.** Near-trivial
  given the existing infrastructure. Half a day.
- **Part 2 (structs): deferred.** Larger architectural decision; we'll
  re-assess after Part 1 lands.


Reuse of endeavor 052
---------------------

**This builds on top of endeavor 052** (`tests/spec/052-differentiate-sub-functions/`),
which already established the sub-function autodiff infrastructure:

- `*differentiable-functions*` registry — `name → (:bkwd-name :n-float-params :n-return)`.
- `%generate-backward-function-ast` (autodiff.lisp:705) — produces the `_GRAD` companion.
- `%generate-backward-function-walk` (autodiff.lisp:830) — function-level backward body.
- Multi-value return convention: `(fn_GRAD a b t_grad) -> (values a_delta b_delta)`.
- HOF support via monomorphization (tests 052/11, 052/13).
- Mutation-on-active-path errors (052/errors/04, 052/errors/06).
- Reachability / "off the critical path" handling (052/08, 052/10).

052's `differentiating-sub-functions.md` already finalized the
**value-return** convention (multiple values, NOT `&out`). This plan
follows that decision.

The 052 plan's "Phase E" was *intended* to cover struct/record property
accessors (tests 052/21 and 052/25). Investigation showed those tests
pass via a different path — accessor-name special-casing inline — never
exercising 052's `_GRAD` pipeline for the user-overloaded body. So the
general "sub-function with struct/record param" case was never actually
wired through 052's infrastructure.

This plan closes that gap by widening 052's existing pipeline for records,
then re-assessing structs separately.


Investigation summary (2026-05-11)
----------------------------------

### Probe results

- Sub-function with **scalar float** params: works (052 infrastructure).
- Sub-function with **non-accessor name + record param**: fails at "Function
  X is not differentiable". Pre-registration gate rejects it.
- Sub-function with **non-accessor name + struct param**: same failure.
- 052/21, 052/25, 049/11 (overloaded accessors `x~`, `y~` taking
  struct/record params): *do compile* under `--differentiate`, but
  inspection of the IR shows **no `_GRAD` companion is ever generated**
  for the user body. The kernel-side backward walker handles `(x~ pt)`
  inline as a primitive accessor rule, bypassing the user-overloaded
  function entirely. **Possible latent bug** — see "Investigation
  prerequisite" below.

### Key empirical finding: records SROA, structs don't

Compiling a probe with both a record-param function and a struct-param
function (without `--differentiate`) produces this LLVM IR:

```
define float @dist_point_point(float, float, float, float)      ; record → SROA'd
define float @sdist_spoint_spoint(%SPOINT %0, %SPOINT %1)        ; struct → struct value
```

And call sites:
```
call float @dist_point_point(float %X_val, float %Y_val, float %X_val20, float %Y_val21)
call float @sdist_spoint_spoint(%SPOINT %spa22, %SPOINT %spb23)
```

So **records are auto-SROA'd at every function boundary**: parameter and
call site both. By the time the function body is compiled, a record param
is indistinguishable from a sequence of float scalars. **Structs are
not** — they're passed as struct values.

This is the load-bearing finding for splitting the plan.

### Root cause for records (the only remaining gate)

Pre-registration at [`src/analysis/core.lisp:1582-1596`](../../src/analysis/core.lisp#L1582-L1596)
looks at the **declared** parameter types (`point`, `point`) before SROA
fires, sees no `%crisp-float-type-p` matches, and skips registration.
A symmetric gate exists at [`src/autodiff.lisp:728-751`](../../src/autodiff.lisp#L728-L751)
inside the `_GRAD` generator.

If the gate counted a record param as N float fields (its post-SROA
shape), the downstream pipeline already handles those N floats correctly.


===============================================================
PART 1 — RECORDS (primary scope)
===============================================================

Architectural approach
----------------------

**Widen the pre-registration and `_GRAD` generator gates only.** That's
likely the entire fix for records, because:

- The function body, post-SROA, is already a float-scalar function from
  the compiler's perspective.
- 052's pipeline (registry, `_GRAD` companion, backward walker,
  multi-value return, call-site chain rule) already handles float-scalar
  functions correctly.
- Call sites already pass per-field scalars (we saw `dist_point_point(X_val, Y_val, ...)`),
  so the chain rule has all the symbols it needs to accumulate
  per-field deltas back into the kernel's `p1_x_grad`, `p1_y_grad`,
  etc.

This is essentially a "the SROA pass did all the hard work already; the
gate just hasn't caught up to that" fix.

Concrete implementation targets
-------------------------------

### 1. Widen pre-registration gate

File: `src/analysis/core.lisp` (~line 1582-1596).

For each non-`&OUT` param `pd`:

- If `%crisp-float-type-p (pd-type)` → counts as 1 (existing).
- If `%crisp-integer-scalar-type-p (pd-type)` → counts as 1 (101 add).
- If `%crisp-record-type-p (pd-type)` → counts as the number of float
  fields in the record (via 049 helpers like `%get-record-runtime-fields`).
- If tensor/cell-typed → counts as 1.
- Struct: deferred (Part 2).

`n-differentiable-params > 0` becomes the new gate.

### 2. Widen `_GRAD` generator gate

File: `src/autodiff.lisp` (~line 705-825).

Same widening at the `float-param-entries` collection. The
`(when (zerop n-float-params) ... return)` early-out at line 749 must
not fire for record params.

After the gate passes, verify whether the rest of the function
(backward walker, multi-value return emit, call-site chain rule)
just works given that the function body is already float-scalar
post-SROA. **Strong prior that it does**, but verify on probe J before
declaring the gate-fix sufficient.

### 3. Possible body-emission tweak (likely unnecessary)

If, after fixes 1 and 2, the function body / `_GRAD` companion is
correctly generated and the call site accumulates properly — done.

If something downstream still references the *declared* type instead of
the *post-SROA* shape, lift that to use the SROA shape. We'll find out
empirically on probe J.

Test strategy
-------------

### Probe-driven TDD

Build incrementally, locking each step before moving on:

1. **probe-J** shape: `def-function dist (p:point => float)`, single
   record param, float return. Verify _GRAD is generated, signature is
   the SROA'd float form, call site accumulates per-field.
2. **probe-G** shape: two record params, float return.
3. **probe-H** shape: int-fielded record + int return (exercises 101's
   int-promotion alongside record-destructure).
4. **031/03** itself: derived type `:subst :equal` over struct. Wait,
   031/03's struct is `def-struct`, not `def-record`. We'll need a
   record-only equivalent (perhaps adapt 031/22 which IS a record
   variant).

### Spine-of-specs sweep (records cluster)

Remove `SKIP-WITH[--differentiate]` from the 4 *record* tests in 031:

| Test | Type | Subst |
|------|------|-------|
| 031/20 | record | (no subst) |
| 031/22 | record | :equal |
| 031/24 | record | :descendant |
| 031/26 | record | :ancestor |

The `:subst` variants don't introduce a new AD wrinkle (Chris confirmed
the kernel differentiation uses ANF-walk provenance, not branding —
brands were removed from Storage Handles, kept in spec for other
purposes). So these should fall out from the same gate fix.

### Validator lock

The `validate-no-sroa-grad-leak` validator from earlier in 101 already
locks the kernel-side declared-signature invariant. It passes trivially
on the forward suite (no `_grad` entries) and should now also pass on
the new tests under `--differentiate`. No new validator strictly
needed.

If we want extra coverage, add a `validate-sub-fn-grad-arity` that
checks the `_GRAD` companion's return arity equals the sum of
differentiable-field counts of its params. Optional; punt unless
something subtle goes wrong.

Risk assessment (Part 1)
------------------------

- **Low** — record SROA does the structural heavy lifting; this is a
  gate fix.
- **Possible follow-on**: if some downstream step references declared
  types instead of post-SROA types, that's a secondary fix.
  Budget a couple hours.

Effort estimate (Part 1)
------------------------

- Investigation prerequisite (accessor anomaly, see below): 1-2 hours.
- Gate widening (1, 2): 1-2 hours.
- Verify body emission and call-site work as-is: 1 hour.
- Sweep + iteration on the 4 record tests: 2-3 hours.
- Validator lock test (optional): 1 hour.

Total: **half a day to a day** end-to-end. Significant downward
revision from the earlier ~2-day estimate, thanks to the SROA discovery.


===============================================================
PART 2 — STRUCTS (deferred; re-assess after Part 1)
===============================================================

Why this is bigger
------------------

Structs are *not* SROA'd at function boundaries. A `def-function
sdist (p:spoint => float)` compiles to a function that genuinely takes
a struct value (`%SPOINT`). The backward companion would need to either:

- **(a) Also SROA-expand structs at function boundaries for AD purposes**
  — a behavior change with possible spillover into non-AD code paths.
  Likely the cleanest if the impact is contained, since it makes the
  AD path symmetric with records and reuses Part 1's gate work.
- **(b) Add struct-value-aware AD machinery** — the backward function
  takes a struct value and returns a "struct delta" (Gemini's term in
  052's discussion doc). Member-wise accumulation at the call site.
  Larger surface area; new code paths.
- **(c) Punt entirely** — emit a clear error when a struct param hits
  the differentiable path; document the limitation.

Tests blocked
-------------

The 4 *struct* variants in 031:

| Test | Type | Subst |
|------|------|-------|
| 031/01 | struct | (no subst) |
| 031/03 | struct | :equal |
| 031/05 | struct | :descendant |
| 031/07 | struct | :ancestor |

Plus 052/21 indirectly (if we want the overloaded-accessor body to
actually be differentiated rather than bypassed — currently it just
happens to compile via the inline-accessor path).

Re-assessment trigger
---------------------

After Part 1 lands and the 4 record tests are passing, re-look at the
struct case with fresh eyes:

- How invasive is option (a) really? Maybe small.
- Does (c) leave users with a workable workaround (e.g., "use a record
  instead of a struct for differentiable params")?
- Does the accessor-inline anomaly investigation change the picture?

No code on structs until that re-assessment.


===============================================================
Investigation prerequisite (covers BOTH parts)
===============================================================

Before Part 1 code: confirm whether the existing 052 accessor-inline
path silently computes wrong gradients for non-trivial overloaded `x~`
bodies. IR shows `x__point_GRAD` is never generated for 052/21 —
suggesting only the primitive `~x~` chain rule fires, ignoring the
user-overloaded body.

Quick test: write a kernel where an overloaded `x~` body does
something non-trivial (e.g., `(* (~x~ pt) 7.0)`) and verify the
end-to-end numerical gradient against a hand-computed reference.

- **If correct**: the inline path is doing the right thing somehow,
  flag it as understood-but-surprising and proceed.
- **If wrong**: separate bug to fix on its own; don't bundle into
  this plan, but acknowledge it exists so Part 1 tests don't rely
  on the broken accessor path.

~1-2 hours.


===============================================================
Open questions (after Chris's replies)
===============================================================

1. ~~`_GRAD` return convention~~ — **resolved by 052**: multiple values.

2. ~~Call-site arg shape~~ — **resolved by the SROA discovery**: for
   records, call sites already pass per-field scalars, so the chain
   rule has the symbols it needs. For structs (Part 2), this becomes
   a real question again, contingent on the (a)/(b)/(c) decision.

3. ~~Brand-preserving destructure~~ — **resolved by Chris**: AD uses
   ANF-walk provenance, not branding. Brands removed from Storage
   Handles; kept in spec for other purposes. No special wrinkle here.

4. ~~HOF + record-param composition~~ — **resolved**: by the time
   monomorphization fires, the function param is replaced with a
   concrete call. The resulting specialized function is just a
   regular def-function with record params — Part 1's gate fix
   covers it.

All four open questions collapse. The remaining unknowns are:

- The accessor-inline anomaly (investigation prerequisite).
- Empirical confirmation that no downstream step references declared
  types instead of post-SROA shapes for records (likely fine, verify).


===============================================================
Out-of-scope (both parts)
===============================================================

- Hoist support under `--differentiate` (separate cluster).
- Kernels with no inputs (trivial-diff cluster).
- Records returned *from* sub-functions (potential 102 follow-on if
  it surfaces).
- Fixing the overloaded-accessor gradient correctness if found wrong —
  flag as separate work.


===============================================================
Files modified (anticipated, Part 1 only)
===============================================================

| File | How |
|------|-----|
| `overlays/crisp-compiler-overlay.lisp` | APPEND — widened pre-reg gate, widened `_GRAD` generator gate, any record-shape helpers needed |
| `tests/spec/101-revisit-autodiff/05*-08*.crisp` | NEW — probe-J / G / H equivalents as TDD tests |
| `tests/spec/031-def-derived-type/20-*.crisp`, `22-*`, `24-*`, `26-*` | EDIT — remove SKIP-WITH lines as tests pass |
