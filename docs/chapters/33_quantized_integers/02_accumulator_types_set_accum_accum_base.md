# Accumulator Types: set-accum, accum, base ✅


`set-accum` declares the accumulator of a type, or of the product of two types:

```lisp
(set-accum q-a q-a-accum)          ; (accum q-a) is q-a-accum
(set-accum (q-act q-wt) q-dot)     ; (accum q-act q-wt) is q-dot
```

The rules:

- All the types are numeric.
- The accumulator holds a full product: it is at least as wide as the operand widths added together, so
  every product is exact.
- The accumulator is signed if either operand is.
- A type has one accumulator.

`(accum T)`, `(accum A B)`, `(base T)` and, for microfloat blocks, `(scale T)` can be used in any type
position: a signature, a `def-type`, the element of a storage handle, the element of a register tile or
`wgmma` accumulator, and inside templates. `(accum T)` means `(accum T T)`.

For the basic types (`float`, `int` etc) `(accum T)` and `(base T)` are just `T`, and the widening
operations are their plain forms: `*!` is `*`.

`accum`, `base` and `scale` are a registry the compiler's type resolver reads, in the spirit of
`(index-t S)` for brands. They are not built with `def-type-function`, which needs a compile-time
evaluator and is still 📝. When it comes, it will fill the same registry.

