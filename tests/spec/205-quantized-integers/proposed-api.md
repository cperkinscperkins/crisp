# Quantized Integers and Microfloat Blocks: Proposed API

Status: sections 2, 3 and 6 implemented in endeavours 202-205 (overlays not folded).  Section 4 is 206.
Replaces `docs/ideal_001.md` lines 9389-9872 once agreed.
Probe evidence: `put_temp_files_here/q205/FINDINGS.md`.

## 1. What changes from the current design

| Topic | Current design | Proposed |
|---|---|---|
| Base types | Opaque `qb8`, `qb16`, ... with no sign | Real primitives: `:base char`, `:base uchar` |
| Type mechanism | `def-type` aliases (not actually nominal) | `def-derived-type ... :subst :no` plus a compiler-known role |
| Zero-point | Float argument on every conversion | Removed for the first cut; zero-point is 0 |
| `scale` meaning | Unclear; `(to-q 23.204 0.0 50.0)` only makes sense if 50 is a range | Step size: `real = scale * q` |
| `+` / `-` | Base and accumulator | Accumulator only; `+!` / `-!` take base values |
| Accumulator back to base | Only through float | `(to-XXXX accum multiplier)`, a direct saturating narrow |
| Mixed-sign products | Not expressible | Declared with `def-qint-product` |
| Hardware whitelist | Checked at `def-qint` | Checked at MMA forms, via `:mma-shapes` |
| `to-float` / `to-float-accum` | Two names | One overloaded `to-float` |
| Autodiff | Not mentioned | Defined in section 6, implemented last |
| Microfloat block layout | Struct with inline scale | Record over two handles (agreed 2026-10-31) |

Unchanged: nominal typing, `*!` as the only multiply, `max` / `min`, no automatic promotion, no
hardware emulation at the MMA forms, and `set-derived` as the deliberate escape hatch.

## 2. Quantized integers

### The model

```
real = scale * q
```

`scale` is a runtime float that the kernel author passes where it is needed.  Operations that stay
inside the integer world need no scale at all.

### def-qint

```lisp
(def-qint q-a :base char :accum int)
```

defines the base type `q-a`, the accumulator `q-a-accum`, the function `to-q-a`, and these type
accessors:

```lisp
(base q-a)        ; => q-a
(accum q-a)       ; => q-a-accum
(base q-a-accum)  ; => q-a
(accum q-a-accum) ; => q-a-accum
```

It expands into two `:subst :no` derived types and a `(set-accum q-a q-a-accum)`.

Two `def-qint`s with identical parameters still cannot mix, because scale is a property of the data.
In practice that means one `def-qint` per differently scaled tensor in a kernel.

### Mixed-sign products

```lisp
(def-qint q-act :base uchar :accum int)
(def-qint q-wt  :base char  :accum int)
(def-qint-product q-dot (q-act q-wt) :accum int)  ; expands to (set-accum (q-act q-wt) q-dot)

(accum q-act q-wt) ; => q-dot
```

`(*! act wt)` is an error unless a product was declared.  `(accum T)` means `(accum T T)`.
Argument order matters: `(q-act q-wt)` does not also declare `(q-wt q-act)`.

### Conversions

```lisp
(to-q-a x scale)        ; float => q-a.  round(x / scale), saturating
(to-float q scale)      ; q-a => float.  scale * q
(to-float acc scale)    ; accumulator => float
(to-q-a acc multiplier) ; accumulator => q-a.  round(acc * multiplier), saturating
```

- Rounding is round-to-nearest, ties to even.
- The result of `to-float` has the type of its `scale` argument.
- An accumulator's scale is the product of its operands' scales: `s_a * s_b`.
- `multiplier` is `s_accum / s_output`.

Raw casts stay available for debugging and bit-level work, and they apply no scale:

```lisp
(to int q)  ; the integer value of q
(to q-a 5)  ; raw integer into q-a.  A float source is refused
```

### Operations

`B` is a base type and `A` is an accumulator.

| Form | Result | Notes |
|---|---|---|
| `(*! B B)` | `A` | Same type, or a declared product |
| `(+! B B)`, `(-! B B)` | `A` | Widening add and subtract |
| `(+! A B)`, `(-! A B)` | `A` | Accumulate a base value |
| `(widen B)` | `A` | Same scale; for initializing an accumulator |
| `(+ A A)`, `(- A A)` | `A` | Same accumulator type, wraps on overflow |
| `(max B B)`, `(min B B)` | `B` | Scale independent |
| `(max A A)`, `(min A A)` | `A` | |
| `< <= > >= = /=` | `bool` | Same type only |

Overflow rule: **narrowing saturates, accumulators do not.**  An `int` accumulator holds 131,072
worst-case `char` x `char` products, or 65,793 `uchar` x `char` products.

`+!` and `-!` are the exposed add and subtract, matching `*!`.  Rule: each argument widens to its
accumulator type, then they combine, so `(+! a b)` and `(+! acc b)` both work.  There is no widening
add instruction behind them: `ptxas` refuses `add.s8` and `add.wide.s16`, so `(+! a b)` lowers exactly
like `(+ (widen a) (widen b))`.  For basic types `+!` is `+`, as `*!` is `*`.

The separation also keeps the plain forms for the compiler: `(* char char) => char` is `mul.lo.s16`
and the widening product is `mul.wide.s16`.  User code on quantized types is refused `+`, `-` and `*`
on base values, but internal lowering works on the underlying `char`, which keeps them.

To add two quantized tensors, as in a residual connection:

```lisp
;; same type, so same scale
(to-q-a (+! x y) 1.0)

;; different scales: go through float
(to-q-out (+ (to-float x s-x) (to-float y s-y)) s-out)
```

### Refused at compile time

| Form | Message says |
|---|---|
| `(* B B)` | Use `*!` |
| `(+ B B)`, `(- B B)` | Use `+!` / `-!` |
| `(/ q q)` | Convert to float |
| `(to-float q)` | Needs a scale |
| `(to q-a 1.5)` | Use `to-q-a` with a scale |
| `(+ q-a q-b)` | Different quantized types |
| `(*! q-a q-b)` undeclared | Declare `def-qint-product` |

## 3. Tile-level path: where the hardware is

Scalar `*!` is an ordinary integer multiply and is legal on every target.  Tensor hardware is reached
only through the existing MMA forms, which gain integer elements:

```lisp
(def-qint q-a :base char :accum int)
(def-type in-mat  (matrix q-a :address-space :global :align :compact :contiguous-term :row-major))
(def-type out-mat (matrix q-a :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel qmatmul (A B mult &out C)
  (declare #'(in-mat in-mat float &out out-mat)
           (global-size :set-to 32) (local-size :set-to 32))
  (let ((D (make-register-tile (accum q-a) (16 16) 0)))
    (mma-accumulate-via-tile (8 16 32) D A B)   ; XMX.  K=32 is the int8 shape
    (store-tile (to-q-a D mult) C (0 0))))      ; same shape as (to-half D)
```

`mult` is `s_A * s_B / s_C`.  **As built, this exact kernel is refused on BMG:** a SPIR-V store is one
whole fragment, so narrow in a second step over an int matrix (D-205-1).  On NVIDIA the kernel uses
`make-wgmma-accumulator` and `store-tile-at`, and the direct narrowing form works, because integer
MMA there is `wgmma` only.

A shape and element combination missing from the profile's typed `:mma-shapes` is a compile-time
error at the MMA form, never a slow fallback.  So `(def-qint q :base short :accum long)` is legal, and
it only fails if that type reaches an MMA form on hardware without that combination.

## 4. Microfloat blocks

Built in endeavour 206: see `tests/spec/206-microfloat-blocks/microfloat-blocks.md`, which is the
reference.  This section is the sketch it started from.  What changed: `fake-quant-NAME` is new, and a block
cannot be a kernel parameter.

### Base types

`fp4` (E2M1), `fp8-e4m3`, `fp8-e5m2`, `fp8-e8m0`.  The design's `fp16` and `fp32` are dropped because
they duplicate `half` and `float`, and `f8-e8m0` is renamed to match the others.

### def-microfloat-block

```lisp
(def-microfloat-block mf-w :base fp4 :scale fp8-e4m3 :accum float :shape (16))
```

`mf-w` is a record over two handles, which is how Blackwell's block-scaled multiply and NVFP4
checkpoints both organize the data:

```lisp
;; conceptually
(def-record mf-w
  (codes  ...)   ; packed: two fp4 codes per byte
  (scales ...))  ; one fp8-e4m3 per block

(let ((w (make-mf-w :codes c :scales s))) ...)
```

Requires records that can hold handles, which fail today.

### Operations

```lisp
(quantize-to-mf-w   float-vec &out w)
(dequantize-from-mf-w w &out float-vec)
(to-float w i)   ; decoded and scaled element i
(~ w i)          ; raw code at element i
(accum mf-w)     ; => float
(base mf-w)      ; => fp4
(scale mf-w)     ; => fp8-e4m3
```

Blocks cannot be added.  `+` and `-` belong to the accumulator, which is an ordinary float.

Removed from the design: `max` / `min` on base codes, because codes from different blocks have
different scales and comparing them means nothing.  `mfb-mult-add` also goes for now, because the
design's `OpFMulAdd` target is not a real path.

### Execution

| Target | Path |
|---|---|
| H100, BMG | `dequantize-from` into `half`, then existing MMA.  This is conversion, not emulation |
| Blackwell | `tcgen05.mma` block-scaled forms.  Needs tensor memory; a later endeavour |

`(*! MFB MFB)` is reserved for the native path and refused elsewhere, with a message pointing at
`dequantize-from`.

## 5. Type accessors, and why not def-type-function

`accum`, `base` and `scale` are a compiler registry that the type resolver reads, in the spirit of
`(index-t S)` for brands.  For basic types, `(accum T)` is `T`, as `ideal_001.md:9084` already says.
A general `def-type-function` needs a compile-time evaluator and stays deferred.  When it comes, it
fills the same registry.

## 6. Autodiff

Implemented in 205, verified on BMG against hand-derived gradients (`fd=off`).  Integer MMA itself has
no backward and refuses loudly (D-205-2): training runs in float through `to-q` and `to-float`.

The true derivative of rounding is zero, so the useful answer is a straight-through estimator (STE):
backward treats the rounding as if it were not there.

| Form | Backward rule | Exact? |
|---|---|---|
| `(to-q x s)` | `dq/dx = 1/s`, `dq/ds = -x/s^2`; zero when saturated | STE |
| `(to-float q s)` | `d/dq = s`, `d/ds = q` | Exact |
| `(*! a b)` | Product rule | Exact |
| `(widen q)` | Identity | Exact |
| `(+ A A)`, `(- A A)` | Linear | Exact |
| `(to-q A m)` | `dq/dA = m`; zero when saturated | STE |

Adjoints of quantized values are `float`, using the existing promoted-adjoint path.  The fake-quant
pattern `(to-float (to-q x s) s)` then gives `d/ds = q - x/s`, the Learned Step Size gradient.

Testing: `VERIFY-AUTODIFF` compares against finite differences, which see the true step function, so
STE gradients will not match by design.  Those specs need hand-derived expected values on the
backward kernel.

## 7. Open questions

1. **Symmetric only: agreed for the first cut.**  Costs classic asymmetric `uint8` activations.  They
   can be handled by hand: with symmetric weights, `sum((a - za) * b) = sum(a * b) - za * sum(b)`, an
   accumulator subtraction of a precomputed term.  A zero-point key can be added later without
   breaking anything.
2. **Mixed-sign hardware: settled by 204.**  Exact on BMG in all four sign pairs, and on the H100 for
   `uchar` x `char` through `wgmma` at PTX 8.4.
3. **Block `&out`: settled by 206.**  `quantize-to` is one call, and a record's handles are written through it.
4. **Global scale: deferred.**  NVFP4 exports can carry an optional per-tensor scale besides the block scales.
5. **Per-instance scales.**  Brands could tie values to a specific scale at compile time.  Left out
   of the first cut; nominal types are enough at kernel scale.

## 8. Build order

| Endeavour | Delivers |
|---|---|
| 202 | Derived types through handles, casts, `:enforce :always`, operators that refuse rather than ignore an overload |
| 203 | Done in overlay: `(accum T)` / `(base T)`, `set-accum`, real `*!`, `+!`, `-!`, `widen`, `to-sat` |
| 204 | Done in overlay: integer MMA.  Exact on BMG and, through `wgmma`, on H100 |
| 205 | Done in overlay: `def-qint`, `def-qint-product`, conversions, tile narrowing, autodiff.  See `quantized-integers-205.md` |
| 206 | Done in overlay: records holding handles, microfloat blocks, conversion path, `fake-quant`.  See `microfloat-blocks.md` |
| Later | Native Blackwell `tcgen05` |
