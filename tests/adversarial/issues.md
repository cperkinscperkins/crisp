# Adversarial Testing Issues

This file tracks bugs and edge-case failures discovered by the adversarial testing suite.

When an issue is added here, the corresponding adversarial test should be tagged with `;; KNOWN-ISSUE: <ID>`. The spec runner will intercept failures for this test and mark them as `KNOWN-FAIL` (allowing CI to pass). If the test unexpectedly passes, it will mark it as `UNEXPECTED-PASS` (failing the CI), which indicates the bug was fixed and this issue can be closed.

**When an issue is fixed, the test GRADUATES**: it moves into the spine (`tests/spec/NNN-.../`, or its `errors/` folder with a `CHECK-FAIL` for a refusal), and the issue moves to *Resolved* below with a pointer.  The adversarial folder holds only what is still open.

The descriptions below were written by whoever found the issue.  Treat the *observation* as reliable and the stated *cause* as a hypothesis: in the 2026-10-12 sweep, several causes were wrong (see Resolved).

## Active Issues

### ADV-003 / ADV-004 / ADV-011 / ADV-017 (template half): AD through an implicitly instantiated template function
* **Location:** `templates/adv-003-template-mvb.crisp`, `autodiff/adv-004-differentiate-template-branches.crisp`, `templates/adv-011-macro-template.crisp`, `templates/adv-017-scratch-template.crisp`
* **Description:** A plain kernel that calls a `(<T> (def-function ...))` template is refused under `--differentiate`: "Function MY-TEMP-CALC is not differentiable".  The simplest case -- one call, no branch, no mvb, no macro -- fails the same way, so these four are ONE gap.  Cause (verified 2026-10-12): the AD walk runs on raw forms before semantic analysis, so it sees a template, not an instantiation, and has no typed signature to build a `_GRAD` from.  A *templated kernel* instantiated with `gen-` differentiates fine (052/13), because the whole template is instantiated first.  (ADV-004's one-argument `(- x)` was BUG 095, fixed.)
* **Scope:** `[differentiate]` -- loud refusal, not a wrong answer.

### ADV-012 / ADV-013 / ADV-023: overriding a DEFAULTED compile-time property in make-XXXX
* **Location:** `compile-time/adv-012-c-t-overload.crisp`, `control-flow/adv-013-phi-unification.crisp`, `control-flow/adv-023-ct-default-override.crisp`
* **Description:** For `(def-struct my-cfg (val float) (exec mode :c-t :slow))`, `(make-my-cfg :val v :exec :fast)` silently DROPS the override: the value is typed as the bare `my-cfg` (= `:exec :slow`), and `(exec~ v)` -- a constant macro -- answers `:slow`.  So an overload on `(my-cfg :exec :fast)` never matches (012), an `if` over a `:fast` and a `:slow` value does not report the type clash (013), and a `:fast` value stores into a `:slow` cell without complaint (023).  Properties WITHOUT a default are carried into the type since ADV-018; a defaulted one needs a design decision, because the type and a *type-aware* `XXX~` accessor have to change together.  ADV-013's file still says `TEST-EXPECT: PASS`; with the fix it should be a compile error.  ADV-014's file became ADV-023 (its premise -- that the struct was incomplete -- was wrong: the default makes it complete).
* **Scope:** none (all passes).  ADV-023 is silent.

### ADV-016: Autodiff over &optional / &key functions
* **Location:** `autodiff/adv-016-autodiff-optional.crisp`
* **Description:** Same gap as bugs.md BUG 097 (no `_GRAD` companion for lazily instantiated &optional / &key variants).  The claimed SBCL teardown fault is unverified.
* **Scope:** `[differentiate]`

### ADV-017: Autodiff over a function that allocates a scratch cell
* **Location:** `autodiff/adv-017-autodiff-scratch.crisp` (the template twin is listed under ADV-003)
* **Description:** "Function MY-SCRATCH-FUNC is not differentiable".  BUG 047 (fixed 2026-10-13) was a scratch cell in a def-KERNEL `let`; this is one inside a def-FUNCTION, still refused.  The claimed SBCL teardown fault is unverified.
* **Scope:** `[differentiate]`

### ADV-022: c-t-assert inside a function body is never evaluated
* **Location:** `compile-time/adv-022-ct-assert-in-body.crisp`
* **Description:** `(c-t-assert (equal 1 2) "...")` inside a `def-function` compiles.  Silent.  See bugs.md BUG 114 for why it is not a one-line fix (the spine's in-body asserts ask about variables' TYPES).
* **Scope:** none (all passes).

## Resolved (2026-10-12 sweep)

| ID | What it was | Where it went |
|---|---|---|
| ADV-001 | Shadowing let in a differentiated body: AD 6.0, true 4.0 (silent) | Fixed (alpha-rename before ANF).  `tests/spec/124-ad-issues/20-shadowed-let-diff` |
| ADV-002 | Shadowing let inside a value-if branch: AD 0.0, true 4.0 (silent) | Same fix.  `124-ad-issues/21-shadowed-in-branch-diff`; also 22 (parameter shadow), 23 (sibling) |
| ADV-005 | Keyword passed to a template inferred `T = (keyword :forward)` | Fixed: T is the enumeration holding the keyword.  `008-enum-and-c-t-output/enum-into-template`, `errors/enum-into-template-ambiguous` |
| ADV-006 | `c-t-output` of a runtime value aborted compilation | Fixed per chapter 41 ("merely noted").  `008-enum-and-c-t-output/c-t-output-runtime-arg` |
| ADV-007 | Enum-returning sub-function + enum `if` + `eq` | Three fixes (float adjoint slot for an enum return; keyword branches unify to their enum; keyword literals take no adjoint) and a clearer error for `eq` (Crisp compares with `=`).  The test's expectation (4.0) was wrong: it is 2.0.  `124-ad-issues/19-enum-returning-sub-function` (VERIFY-AUTODIFF on BMG), `008-.../errors/enum-compare-with-eq` |
| ADV-008 | Boundary struct passed to a mutator | Was already a correct compile error; the test lacked CHECK-FAIL.  `056-struct-at-kernel-boundary/errors/13-boundary-struct-to-mutator` |
| ADV-009 | Recursive struct through a cell | Already a correct error (after fixing the test's malformed `(cell list-node :global)`).  `026-recursive-data/errors/07-no-recursion-through-cell` |
| ADV-010 | `#'x~` as a higher-order function | Works; the test used a TYPE parameter `(<F>)` where a function type `#'(record-point => float)` belongs.  `009-def-struct/12-accessor-as-function` |
| ADV-014 | Cell of an "incomplete" struct at the boundary | Premise wrong (the struct had a default).  The real case -- an element with NO default -- is now refused: `022-def-kernel/errors/16-cell-of-partial-struct`.  The file became ADV-023. |
| ADV-015 | `(cell (cell float ...) ...)` crashed in codegen | Decision: storage handles do not nest; clear error at the boundary.  `015-cell/errors/nested-storage-handle` |
| ADV-018 | Accessors on a c-t-qualified struct / its def-type alias | Fixed: make-XXXX carries required c-t values into the type; member access resolves aliases.  `018-def-type/08-def-type-ct-struct-alias`, `errors/02-ct-alias-mismatch`.  AD through such a parameter is BUG 117. |
| ADV-019 | Two instantiations under one explicit kernel name; the second silently replaced the first | Fixed: compile error.  `020-def-kernel-exact/errors/18-duplicate-instantiation-name` |
| ADV-020 | `marshall-cell` of a cell whose element is incomplete | Premise as ADV-014; real case now refused.  `020-def-kernel-exact/errors/16-marshall-cell-partial-element` |
| ADV-021 | `voidp` outside def-kernel-exact | Not a bug since endeavour 122 (FFI); docs updated.  `122-ffi/08-voidp-through-def-function` |
