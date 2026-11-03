# Conversions ✅


`B` is a base type, `A` is an accumulator, and `F` is a float.

```lisp
(to-q-a x scale)        ; F => q-a.  round(x / scale), saturating
(to-float q scale)      ; B => F.    scale * q
(to-float acc scale)    ; A => F
(to-q-a acc multiplier) ; A => q-a.  round(acc * multiplier), saturating
```

- Rounding is round-to-nearest, ties to even. Saturation clamps to the base type's range, and NaN becomes
  `0`.
- The result of `to-float` has the type of its `scale` argument, which must be a float (`float`,
  `double`, ...).
- An accumulator's scale is the product of its operands' scales: `s_a * s_b`. Summing accumulators does
  not change the scale.
- `multiplier` is `s_accum / s_output`, so narrowing a matmul result into an output with scale `s_c` uses
  `s_a * s_b / s_c`.
- The narrowing product is computed in float. An `int` accumulator above 2^24 loses low bits there, but
  the output has only 8, so only a value within a few ulps of a tie could round differently.

```lisp
(def-qint q-a :base char :accum int)

(to-q-a 1.3 0.5)                 ; round(2.6) => 3
(to-float (to-q-a 1.3 0.5) 0.5)  ; => 1.5
(to-q-a (*! a b) 0.001)          ; -128 * -128 = 16384 => 16
(to-q-a (*! a b) 0.1)            ; 1638.4 saturates => 127
```

Raw casts stay available for debugging and bit-level work. They apply no scale:

```lisp
(to int q)  ; the integer value of q
(to q-a 5)  ; a raw integer into q-a.  A float source is refused
```

