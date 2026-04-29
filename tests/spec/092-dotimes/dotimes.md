# 092-dotimes

## Purpose

Implement `dotimes` as a first-class bounded loop in Crisp. It is the foundational
looping primitive upon which `loop-vector-stride` (093) will be built as a Crisp macro.

Crisp expressly forbids unbounded loops (no `while`, no recursion) for two reasons:
kernel termination guarantees and differentiability. `dotimes` is bounded by construction
and is differentiable.

## Syntax

```
(dotimes (var limit) body...)
```

- `var`   — loop variable, bound to 0, 1, 2, ..., limit-1 in turn
- `limit` — integer expression evaluated once before the loop; if 0 or negative, body never runs
- `body`  — zero or more expressions evaluated for their side effects; return value is void

## What Needs to Be Done

### 1. Semantic node — `src/semantic.lisp` (direct patch)

Add `semantic-dotimes` struct:

```lisp
(defstruct semantic-dotimes
  "Represents (dotimes (var limit) body...)."
  type          ;; always 'void
  var-name      ;; the loop variable symbol
  var-type      ;; type of var, inferred from limit (int / ulong / etc.)
  limit-node    ;; analyzed limit expression
  body          ;; list of analyzed body nodes
  source-location)
```

### 2. Expression analyzer — overlay (crisp-compiler-overlay.lisp)

`analyze-dotimes-expression`:
- Analyze the limit expression to get its type
- Validate: limit must be an integer type (int, uint, ulong, long, etc.)
- Extend env with `var` at that type (kind :local)
- Analyze body-forms with the extended env
- Return `semantic-dotimes`
- Register in both `:crisp-language` and `:crisp.compiler` packages

### 3. Codegen — overlay (crisp-compiler-overlay.lisp)

`generate-node-ir (semantic-dotimes)` using the alloca+branch pattern
(consistent with `semantic-if`; LLVM mem2reg promotes to phi nodes):

```
; current block (entry into dotimes):
  %i_alloca = alloca <var-type>
  store 0, %i_alloca
  %limit_val = [generate limit node]
  br label %dt_check_NNN

; dt_check_NNN:
  %i_val = load <var-type>, %i_alloca
  %cond   = icmp ult %i_val, %limit_val
  br i1 %cond, label %dt_body_NNN, label %dt_exit_NNN

; dt_body_NNN:
  ; body — var-name -> alloca in body var-env
  ; ...
  %i_incr = add %i_val, 1
  store %i_incr, %i_alloca
  br label %dt_check_NNN

; dt_exit_NNN:
  ; dotimes returns void — values nil nil
```

Use a global counter or gensym for the NNN suffix to keep block names unique.

### 4. ANF transform — `src/anf-transform.lisp` (already done!)

The ANF transform already handles `dotimes` at line ~190. No changes needed.

### 5. Package / exports

`dotimes` is already in both `src/package.lisp` exports and `:crisp-language` import-from.
No package changes needed.

## Tests

### Positive tests (E2E, SPIRV target)

| File | What it tests |
|------|---------------|
| 01-basic.crisp | dotimes in def-kernel; CHECK-IR for loop block names |
| 02-ulong-limit.crisp | dotimes with a ulong limit expression |
| 03-in-def-function.crisp | dotimes inside a def-function (not just kernels) |
| 04-nested-body.crisp | let + if inside dotimes body |

### Error tests

| File | Expected error |
|------|----------------|
| errors/01-float-limit.crisp | limit must be integer type |

## Notes

- `dotimes` returns `void` (like Common Lisp's `dotimes`).
- The loop variable type matches the limit type — if limit is `int`, var is `int`;
  if limit is `ulong`, var is `ulong`.
- `dotimes` is permitted anywhere (def-function, def-kernel, def-grid-function).
  It does NOT require a dispatch context.
- Signed vs unsigned comparison: use `icmp ult` (unsigned) for `ulong` limits,
  `icmp slt` (signed) for signed integer limits.
- Negative limit: `icmp ult 0, negative-cast-as-unsigned` would be true (bug!).
  Safe approach: emit `icmp sgt limit, 0` guard before loop, OR just use
  signed comparison for all types (since negative limit → 0 iterations is correct).
  Decision: use signed `icmp slt` for all integer types; for ulong use `icmp ult`.
