# Endeavour 202: Derived Types Through Handles

First preliminary for quantized integers (see `../205-quantized-integers/proposed-api.md`).
Quantized elements are derived types, and they have to survive a trip through memory.  They did not.

## Root causes

Each was confirmed before any fix.

**Reads through a handle.**  `(~ a)` returned `CRISP.COMPILER::Q-C` while the type is registered as
`CRISP-LANGUAGE::Q-C`.  Traced by wrapping `get-promoted-type`: the operand showed `in-types NIL`.
The unmangler interned element tokens into the template's package, and `CELL` lives in crisp.compiler.
`get-promoted-type` matched the two by name, then the `*crisp-types*` lookup missed, giving the
baffling "Cannot operate on Q-C and Q-C".  The same bad symbol caused the failed `(to int q)` cast and
the `The value NIL` crash in `to-float` and `max`.

**`:enforce :always`.**  `analyze-function-call` wrapped its brand checks in `(when *differentiate-p*
...)`, although each check already asks `brand-active-p`.  So `:always` behaved like `:diff`.

**Operator definitions.**  `analyze-expression` tries `*expression-analyzers*` before `*function-table*`,
so a user `(def-function + ...)` compiled and was never called.  Measured per operator: `+ - * / *! <
<= > >= = max min` are all dead.  `/=` is not, because it has no analyzer.  Accessors (`~`, `X~`,
`~REF~`) are deliberately overloadable and stay legal.  A corpus scan found no real definitions of the
refused names.

**Host ABI.**  Found by the metal spec, not predicted.  Metadata carried `(vector q-c ...)`, and a hoist
has no type registry, so the generated C++ declared an undefined `q_c`.

## Fixes (overlay; target file noted on each)

| Function | File | Change |
|---|---|---|
| `%unmangled-symbol` (new) | `src/mangling.lisp` | Prefer the registered `:crisp-language` type |
| `reconstruct-one-arg`, `reconstruct-template-args` | `src/mangling.lisp` | Use it |
| `*unoverloadable-operators*`, `%refuse-operator-definition` (new) | `src/environment.lisp` | Refuse at the definition |
| `register-function-signature` | `src/environment.lisp` | Call it |
| `analyze-function-call` | `src/analysis/core.lisp` | Drop the `*differentiate-p*` gate |
| `%host-visible-type` (new) | `src/metadata.lisp` | Derived numeric to primitive |
| `serialize-aliases`, `generate-declared-signature` | `src/metadata.lisp` | Use it |

Fold note: `%unmangled-symbol` reads `*crisp-types*`.  `src/session` precedes `src/mangling` in
`crisp.asd`, so the order is safe.

## Verified by hand

- LLVM IR: `load i8`, `add i8`, `sext i8 to i32`, `sitofp i8`, `icmp sgt i8`.
- PTX `sm_90`: `ld.global.s8`, `max.s16`, `st.global.b8`.
- BMG on metal: spec 08 reports `BUFFER o: 45`.

## Not covered

- `TEST-HOIST[CUDA]` on spec 08 skips locally (no `nvcc`).  It needs a pod run.
- `--differentiate` and `--single-pass` passes are left to CI.
- `:subst :no` still permits `(* q q)` and `(+ q q)` on same-type derived values.  That is correct for
  derived types.  The `def-qint` role table in 205 is what refuses them.
- A `def-record` inside a vector compiles, against `ideal_001.md:1220`.  Unrelated; left alone.
