# Plan: Autodiff of Sub-Functions (Feature 052)

## Status: In Progress

## Finalized Decisions

- **Backward sub-function suffix**: `_GRAD` (consistent with backward kernel suffix)
- **`def-function` with `&out`**: Deferred. Mutation detection will catch it as an error for now.
- **HOFs** (tests 11, 13): In scope. Monomorphization is already a Crisp feature; the
  specialized concrete function is what gets differentiated.
- **System-generated accessors** (`~x~`, unoverloaded `x~`): Already handled by existing AD
  machinery. Only user-overloaded `x~` (tests 21, 25) needs a new `_GRAD` companion.

---

## Core Insight

`generate-backward-walk` (in `src/autodiff.lisp`) handles primitive ops (`+`, `-`, `*`, `/`,
`sin`, `cos`, `~`). For any other call — e.g. `(%ANF-T-2 (some-operation %ANF-T-0 %ANF-T-1))`
— it falls through to `(t nil)` and silently does nothing.

Two additions fix this:
1. A `_GRAD` companion generated for each `def-function` when `*differentiate-p*` is T.
2. A new case in `generate-backward-walk` that recognizes known-differentiable function calls
   and emits a call to their `_GRAD` companion.

---

## Phase A — Infrastructure (all `defun`s, overlayable)

### A1: `*differentiable-functions*` registry
Append to `overlays/crisp-compiler-overlay.lisp`.

```lisp
;; src/compiler.lisp
(defvar *differentiable-functions* (make-hash-table :test 'eq))
```

Map: `name → (:bkwd-name sym :n-float-params N :n-return M)`

- `:bkwd-name` — the `_GRAD` companion symbol
- `:n-float-params` — number of float-typed parameters (= number of delta return values)
- `:n-return` — number of forward return values (= number of `t_grad` inputs to `_GRAD`)

Clear in `initialize-compiler` (overlay).

### A2: `%generate-backward-function-walk`
Append to overlay. Analogous to `generate-backward-walk` but for sub-functions.

Key differences vs. `generate-backward-walk`:
- No `(set! (~ C) val)` to seed the output adjoint. Instead, identify the return
  variable(s) from the *last element* of the flat ANF:
    - `(return v0 v1 ...)` → seed `v0_adj = t_grad0`, `v1_adj = t_grad1`, ...
    - Plain symbol `v` → seed `v_adj = t_grad0`
- Final emission: `(return adj_param0 adj_param1 ...)` for all float-typed params
  (rather than cell writes).

### A3: `%generate-backward-function-ast`
Append to overlay. Given `(name params declarations body-forms)`:

1. Parse param types from declarations (reuse existing `parse-function-declarations`).
2. Identify float-typed params (the differentiable ones).
3. Determine number of return values from the declaration's `=>` clause.
4. Compute `bkwd-name = name_GRAD`.
5. Build backward signature:
   - Inputs: all original params + `t_grad0 [t_grad1 ...]` (one per return value)
   - Return: `(values delta0 delta1 ...)` one per float param
6. ANF-transform `body-forms`, flatten, call `%generate-backward-function-walk`.
7. Register in `*differentiable-functions*`.
8. Return `(def-function bkwd-name bkwd-params (declare ...) bkwd-body)` form.

**Mutation check** (covers `errors/04-mutation.crisp`):
Walk `body-forms` before the above. If any `(set! (~ p) ...)` where `p` is a cell-typed
parameter, signal:
```
Cannot differentiate: function ~A mutates cell parameter ~A.
```

### A4: `flatten-anf-body` fix
Append to overlay (redefine). One-line fix:

```lisp
;; Change:  (if (and (consp b) (= (length b) 2))  (push b flat))
;; To:      (when (and (consp b) (>= (length b) 2)) (push b flat))
```

Without this, multi-value bindings `(x y (fn a b))` (length 3) are silently dropped,
making multi-value sub-functions (test 03) invisible to the backward walker.

---

## Phase B — `generate-backward-walk` Extension (overlay, redefine)

Append to overlay, redefining `generate-backward-walk` with new cases in the inner `cond`:

### B1: Known differentiable single-value sub-function call
Pattern: `(v (fn arg1 arg2 ...))` where `fn` is in `*differentiable-functions*` with `:n-return 1`.

Emit a nested let with the `_GRAD` call and adjoint accumulation:
```lisp
(let ((delta0 delta1) (fn_GRAD arg1 arg2 v_adj))
  ;; for each arg that is a symbol:
  (set! arg0_adj (+ arg0_adj delta0))
  (set! arg1_adj (+ arg1_adj delta1)))
```

Only emit adjoint updates for symbolic (non-literal) arguments.

### B2: Multi-value binding
Pattern: `(x y (fn arg1 arg2 ...))` — result vars are all but the last element, call is the last.

Same as B1 but seeds multiple `t_grad`s. Requires the `flatten-anf-body` fix (A4) to
even appear in the flat ANF.

### B3: Unknown function call → error (covers `errors/02-black-box.crisp`)
Pattern: `(v (fn ...))` where `fn` is not a primitive and not in `*differentiable-functions*`.

```
Function ~A is not differentiable. Mark the kernel as 'forward-only' if
differentiation is not needed.
```

### B4: Mutation of input cell → error (covers `errors/06-mutation-more.crisp`)
Pattern: `(set! (~ p) ...)` where `p` is a kernel *input* (not an output).

```
Cannot differentiate: mutation of input parameter ~A in kernel ~A.
```

---

## Phase C — `def-function` Macro Patch

**Cannot use overlay** (macros can't be late-bound). Requires a direct patch to
`src/macros.lisp`.

The patch is modest — same pattern as `def-kernel` already uses for its backward kernel:

```lisp
(defmacro def-function (name params &rest body-and-location)
  ;; ... all existing validation unchanged ...
  (let* (;; ... all existing let bindings unchanged ...
         (bkwd-form
          (when (and *differentiate-p*
                     (not (%fn-name-is-grad-p name))   ;; don't re-generate for _GRAD fns
                     (not is-system))                  ;; skip system-generated accessors
            (%generate-backward-function-ast name params declarations body-forms))))
    `(progn
       (internal-def-function ',name ',params ',declarations ',body-forms ,source-location)
       ,@(when bkwd-form (list bkwd-form)))))
```

Helper `%fn-name-is-grad-p`: returns T if the function name ends with `_GRAD`.

`*differentiate-p*` is available at macro expansion time — confirmed by the same pattern
in `%check-differentiate-kernel-signature` used by `def-kernel`.

---

## Phase D — HOF Support (Tests 11, 13)

Monomorphization is an existing Crisp feature. When `(funcall #'+ a b)` appears in a
`def-function` body, the monomorphizer creates a specialized concrete function.

The backward walker in `%generate-backward-function-walk` needs to handle `funcall` forms.
For a monomorphized HOF, after specialization the body contains only concrete calls —
AD proceeds normally.

Key investigation needed when implementing: confirm the ordering of monomorphization vs.
the AD pass at macro expansion time.

---

## Phase E — Struct/Record Property Accessors (Tests 19, 21, 23, 25)

- **Test 19** (unoverloaded `x~`): handled by existing AD machinery. No new work.
- **Test 21** (overloaded `x~`): `x~` is a user `def-function`. Phase C generates its
  `_GRAD` companion. The kernel backward walker calls it via Phase B.
- **Tests 23, 25**: same pattern but with record types (already have scalar explosion
  from feature 049).

---

## Test Coverage Summary

| Test | Phase(s) |
|------|----------|
| 01 — basic sub-function | A, B1, C |
| 03 — multi-value return | A, A4, B2, C |
| 05 — fan-out (two sub-fn calls, same input var) | A, B1, C |
| 06 — chain depth `f(g(h(x)))` | A, B1, C |
| 07 — same var passed twice | A, B1, C |
| 08 — constant sub-function | A, B1, C |
| 09 — 4-arg fn, 2 active / 2 literal | A, B1, C |
| 10 — inactive sub (result not used) | A, B1, C |
| 11 — HOF funcall #'+ | D |
| 13 — HOF + template | D |
| 15 — branch in kernel body | A, B1, C (recomputation strategy) |
| 17 — branch in sub-fn on active var | A, B1, C (recomputation strategy) |
| 19 — struct property accessor (unoverloaded) | existing system |
| 21 — overloaded struct prop function | A, B1, C, E |
| 23 — record property accessor | existing system + E |
| 25 — overloaded record prop function | A, B1, C, E |
| errors/02 — black-box (`bytes~`) | B3 |
| errors/04 — mutation in sub-function | A3 mutation check |
| errors/06 — mutation in kernel body | B4 |
| errors/08 — recursion in sub-function | existing `check-for-recursion-cycles` |

---

## Implementation Order

1. **A1** — `*differentiable-functions*` var + clear in `initialize-compiler`
2. **A4** — `flatten-anf-body` fix (needed early, unblocks multi-value)
3. **A2** — `%generate-backward-function-walk`
4. **A3** — `%generate-backward-function-ast` (including mutation check)
5. **C**  — `def-function` macro patch (written to file, applied by Chris)
6. **B1** — extend `generate-backward-walk` for single-value sub-fn calls
7. Test 01 passing → checkpoint
8. **B2** — extend for multi-value + **A4** already done → test 03
9. **B3** — black-box error → errors/02
10. **B4** — kernel mutation error → errors/06
11. **A3 mutation check** → errors/04
12. Tests 05–10, 15, 17 (should mostly fall out from B1/B2)
13. **E** — tests 19, 21, 23, 25
14. **D** — HOF tests 11, 13

---

## Files Modified

| File | How |
|------|-----|
| `overlays/crisp-compiler-overlay.lisp` | APPEND — all new defuns (A1–A4, B, E) |
| `src/macros.lisp` | PATCH — `def-function` macro (Phase C) |
| `tests/ci-stop.txt` | UPDATE when all 052 tests pass |
