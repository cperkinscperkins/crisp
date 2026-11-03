# Endeavour 203: Accumulator Types

Second preliminary for quantized integers (see `../205-quantized-integers/proposed-api.md`).

## What it adds

| Form | Meaning |
|---|---|
| `(set-accum q-a q-a-accum)` | Declares an accumulator.  `def-qint` will expand into this |
| `(set-accum (q-act q-wt) q-dot)` | Declares a mixed-operand product |
| `(accum T)`, `(accum A B)`, `(base T)` | Type accessors, in any type position, including templates |
| `(*! a b)`, `(+! a b)`, `(-! a b)` | Widening ops.  `(+! acc b)` accumulates a base value |
| `(widen x)` | Value at its accumulator type |
| `(to-sat T x)` | Float to integer: nearest, ties to even, saturating, NaN to 0 |

On basic types `(accum T)` and `(base T)` are `T`, and the widening ops are their plain forms.

`widen`, `+!` and `-!` were not in the build table.  They share `*!`'s code path, so they came along.

## Decisions (D-203-n, for review)

1. **`set-accum` is new, and is user-visible.**  `(accum T)` needs a non-basic type to answer for, and
   `def-qint` is not until 205.  Without it, widening could only be tested through internals.
   It also makes `def-qint` a plain expansion.
2. **`set-accum` rules.**  All types numeric.  Accumulator at least the sum of the operand widths, so
   every product is exact.  Signed if either operand is signed.  One accumulator per type.
3. **`to-sat` is the name**, read as `(to T x)` with saturation.  Float or double source only; a
   narrowing integer source is refused for now, because the requantize path goes through float.
4. **`to-sat` has no gradient**, like `round`: an integer result is piecewise constant.  The
   straight-through rule belongs to `to-XXXX` in 205, where the scale is known.
5. **Registries are keyed by symbol name**, so a type read through a handle cannot miss on its package.
   That is the bug 202 fixed, and this makes the registry immune to it either way.
6. **`*!` runs the operands' own extensions, then multiplies at the accumulator's width.**  LLVM picks
   `mul.wide.s16` from that.  There is no separate widening node, and no widening add exists to lower to.
7. **When no `set-accum` appears in a compile, the accum ops go straight to the plain operators.**  So
   a kernel not using this feature analyzes exactly as before.

## Verified by hand

- LLVM IR: `sext i8 to i32` on each operand, then `mul i32`.  `llvm.rint` then `llvm.fptosi.sat.i8.f32`.
- PTX: `mul.wide.s16` for `*!`.  `cvt.rni`, then `setp.nan` and `selp` forcing NaN to 0, so PTX's
  NaN-ignoring `max` / `min` cannot leak the low clamp.
- BMG on metal, each wrong if the op narrows: `16384 -32640 254 -254` and `383`.
- BMG on metal, `to-sat`: `127 -128 2 4`, `-2 255 0 3`, NaN `0`.
- `ptxas -arch=sm_90a` accepts both metal kernels, and `nvcc -c` accepts both CUDA harnesses.

## Not covered

- Neither metal spec has **run** on NVIDIA.  `TEST-HOIST[CUDA]` skips here; it needs a pod.
- Autodiff through a registered accumulator type.  Basic types differentiate (spec 07).  Quantized
  autodiff is the last rung of 205.
- `make-register-tile` with `(accum T)` as its element: that form does not go through
  `parse-type-specifier`.  204 picks that up.
- `(*! a b)` falls back to `*` when no accumulator is declared, so an undeclared derived pair reports
  a plain type mismatch.  205 improves that message through the `def-qint` role table.

## Fix table (overlay; target file noted on each)

| Function | File |
|---|---|
| `*accum-registry*`, `*accum-base-registry*` (new) | `src/globals.lisp` |
| `register-accum-type`, `accum-type-of`, `base-type-of`, `resolve-type-accessor` and helpers (new) | `src/types/hierarchy.lisp` |
| `set-accum` macro (new) | `src/macros.lisp` |
| `analyze-accum-op`, `analyze-widen`, `analyze-to-sat`, `%register-accum-analyzers` (new) | `src/analysis/ops.lisp` |
| `%hw-lower` for `%to-sat` (new) | `src/codegen.lisp` |
| `initialize-compiler` | `src/compiler.lisp`, clears the registries |
| `parse-type-specifier` | `src/environment.lisp`, resolves the accessor forms |
| `%185-register-math-op-analyzers` | `src/analysis/ops.lisp` |
| `%185-math-backward` | `src/autodiff.lisp` |

Fold notes: export `set-accum`, `widen`, `+!`, `-!` and `to-sat` through `src/package.lisp` as
`set-derived` is, drop the `crisp-language::` prefix on the macro, and remove `"*!"` from
`*185-math-op-names*` along with its branch in `analyze-185-math-op`.
