# Endeavour 205: Quantized Integers

Delivers the integer half of `proposed-api.md`: `def-qint`, `def-qint-product`, conversions, tile
narrowing, and autodiff.  Microfloat blocks are 206.

```lisp
(def-qint q-a :base char :accum int)      ; q-a, q-a-accum, to-q-a, (accum q-a), (base q-a-accum)
(def-qint-product q-dot (q-act q-wt) :accum int)

(to-q-a x scale)        ; float => q-a.  round(x / scale), ties to even, saturating
(to-float q scale)      ; q-a or accumulator => float.  scale * q
(to-q-a acc multiplier) ; accumulator => q-a.  round(acc * multiplier), saturating
(to q-a 5)              ; raw.  No scale, no saturation, and a float source is refused
```

## How it is built

A `def-qint` is two `:subst :no` derived types, a `set-accum`, and a role.  The role table
(`*qint-roles*`) is what makes these types different from a hand-built `set-accum` pair: only types
in it are refused the plain operators, so 203's types keep working.

`to-q-a` needs both arities: `(to q-a x)` already expands to a one-argument `(to-q-a x)`, which stays
the raw cast, and two arguments is the scaled conversion.

## Decisions (D-205-n, for review)

1. **Tile narrowing on BMG is two steps, and the direct form is refused.**  A SPIR-V store is one
   `CooperativeMatrixStoreKHR` of a whole fragment, with no per-element hook.  Doing it for the author
   means a hidden staging tile.  I assumed SLM, which is closed, but private memory and a conversion on
   the cooperative matrix itself are both untried, so this is a choice and not a proven limit.  So
   `(store-tile (to-q-a D m) C ..)` works on NVIDIA, and on BMG the message says to store into an int
   matrix and narrow its elements (spec 10).  This differs from section 3 of the draft, where one
   kernel shape serves both.  `to-half` is refused the same way on SPIR-V, where D-196-5 recorded it as "no Intel need yet".
   **Worth your review.**
2. **Integer MMA has no backward, and says so.**  Its backward multiplies float adjoints by int8
   operands, which no hardware form accepts.  Training happens in float with `to-q` and `to-float`,
   and the integer path is for inference.  Before this refusal, PTX quietly compiled a `_grad` kernel
   and SPIR-V died in `llvm-spirv` with an exit code.  `(to-q D m)` on a tile is refused the same way.
3. **The narrowing product is in float.**  An `int` accumulator above 2^24 loses low bits, but the
   output has only 8, so only a value within a few ulps of a tie could round differently.
4. **`(to-q A m)` also differentiates in `m`**, with `dq/dm = A`.  The draft listed only `dq/dA`.
5. **`max` and `min` gained a backward rule for every scalar type**, because `(max B B)` is in the API
   and `max` had no rule at all, even on floats.  It follows the winner.  This is a general AD addition.
6. **`to-float` with a scale takes qints only**, and `to-double`, `to-half` and `to-bfloat16` refuse a
   qint rather than drop the scale.  Any float cast given a stray second argument is now an error; it
   used to be ignored.
7. **`fd=off` on `VERIFY-AUTODIFF`.**  The runner required finite differences to agree even when
   `expect.` values were given, so a straight-through estimator could never pass.  `fd=off` requires
   at least one `expect.`, so it cannot pass vacuously.

## Verified by hand

- BMG values against hand-derived expectations: specs 02-08, including ties to even, both rails, and a
  `uchar` sign check where a wrong extension would produce a distinct value.
- BMG gradients, on metal, against hand derivations: specs 11-18.  Fake-quant gives `dy/dx = 1` and
  `dy/ds = 0.4`.  At the rail, `dy/dx = 0` and `dy/ds = 127`.
- `numerical=0.0` in those runs is the true step function, and it is why FD cannot be the check.
- IR: `sext` or `zext` by the type's sign, `sitofp` or `uitofp`, then `llvm.rint` and
  `llvm.fpto[su]i.sat`.
- PTX: spec 09 has `wgmma ... .s32.u8.s8`, then `cvt.rn.f32.s32`, `min.f32`, `max.f32`,
  `cvt.rzi.s16.f32` and `st.global.b8`.  `rint` folds away at multiplier 1, since the operand is
  already integral.  `ptxas -arch=sm_90a` and `nvcc -c` accept it.
- The gradient buffer of a quantized input is a `float` tensor (spec 19).

## A trap the specs pin

`%backward-skip-fn-p-145p1` treats any `TO-` name ending in `INT`, `CHAR` and so on as gradient-inert.
`(def-qint q-int ..)` would have been a silent zero gradient by name alone.  The backward clause runs
first; spec 16 holds it there.

## Not covered

- **Nothing here has run on NVIDIA.**  Specs 02-08 and 09 have CUDA hoists.  Spec 09 is the important
  one: the direct narrowing store, and it can only be proven on an H100.
- Spec 09 narrows at multiplier 1.0, because the harness reference has no multiplier.  Multipliers are
  covered on scalars by spec 04, on BMG.
- A raw cast of an active value has no gradient rule and fails loudly: `(to q-a acc)` as `Function TO
  is not differentiable`, and `(to-q-a acc)` as `a raw cast has no gradient`.  Spec errors/22 pins the
  second, because the name-suffix trap below applied to it too.

## The --differentiate sweep

I left this pass to CI on 202-204, and running it here found four failing specs that had been waiting:

| Spec | Cause | Action |
|---|---|---|
| 202/02 | A derived float keeps its type as an adjoint | BUG 150, `SKIP-WITH` |
| 202/05, 203/02, 203/05 | A raw `(to T x)` of an active integer has no rule | `SKIP-WITH` |

All four are loud errors, not wrong gradients.  None comes from 205.

## For the fold

- `def-binary-op-analyzer` is a macro: patch it in `src/analysis/ops.lisp` and drop the four
  re-instantiations.
- `generate-backward-walk`'s wrapper becomes one line at the top of the function; drop
  `*generate-backward-walk-204*`.
- `%185-math-backward` and `%register-accum-analyzers` each appear several times.  Fold the last copy.
- Export `def-qint` and `def-qint-product` through `src/package.lisp`.
- `tests/verify-autodiff-parse.lisp` and `tests/run-specs.lisp` were edited directly for `fd=off`.
