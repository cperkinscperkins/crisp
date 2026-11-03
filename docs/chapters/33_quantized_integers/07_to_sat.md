# `to-sat` ✅


`(to-sat T x)` converts a float or double `x` to the integer type `T`: round to nearest, ties to even,
saturating, and NaN to `0`. It works on the plain integer types as well as quantized ones, and is what
`to-q-a` lowers to. Read it as `(to T x)` with saturation.

```lisp
(to-sat char 300.0)  ; => 127
(to-sat char 2.5)    ; => 2
(to-sat uchar -4.0)  ; => 0
```

On NVIDIA it is `cvt.rni` followed by a NaN select, so that PTX's NaN-ignoring `max` / `min` cannot leak
the low clamp. `to-sat` has no gradient: an integer result is piecewise constant.

