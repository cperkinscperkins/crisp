# def-qint ✅


```lisp
(def-qint q-a :base char :accum int)
```

`:base` and `:accum` are ordinary integer types: `char` or `uchar` for the 8-bit types the tensor
hardware reads, but any integer types are legal. The accumulator must hold a full product of two base
values, so it is at least twice the base's width, and it is signed if the base is.

`def-qint` defines:

- the base type `q-a` and the accumulator type `q-a-accum`
- the conversion function `to-q-a` (see [Conversions](#conversions) below)
- these type accessors:

```lisp
(base q-a)        ; => q-a
(accum q-a)       ; => q-a-accum
(base q-a-accum)  ; => q-a
(accum q-a-accum) ; => q-a-accum
```

These types are nominal. Two `def-qint`s with identical parameters still cannot be mixed, because the
scale is a property of the data, not of the type:

```lisp
(def-qint q-fahrenheit :base char :accum int)
(def-qint q-celsius    :base char :accum int)
```

Mixing `q-fahrenheit` and `q-celsius` is a compile-time error, which prevents you from accidentally
combining data with different scales. In practice that means one `def-qint` per differently scaled tensor
in a kernel.

`(def-qint q-a :base char :accum int)` expands to:

```lisp
(def-derived-type q-a char :subst :no)
(def-derived-type q-a-accum int :subst :no)
(set-accum q-a q-a-accum)
;; plus: q-a is registered as a quantized base type, and q-a-accum as its accumulator
```

That last registration is what refuses the plain arithmetic operators on these types (see
[Refused at compile time](#refused-at-compile-time)). A pair built by hand with `def-derived-type` and
`set-accum` keeps them.

