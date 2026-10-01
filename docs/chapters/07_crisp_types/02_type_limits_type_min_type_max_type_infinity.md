# Type Limits: `type-min`, `type-max`, `type-infinity` ✅


Three forms give a numeric type's limits as a constant of that type.  They cost nothing at run time, and
they exist mainly to be reduction identities (see *Reductions: Shop Local, Act Global*), but they are
ordinary constants usable anywhere.

| Form | Integer `T` | Floating-point `T` |
| :--- | :--- | :--- |
| `(type-min T)` | the most negative value (`0` for unsigned) | the most negative **finite** value |
| `(type-max T)` | the most positive value | the most positive **finite** value |
| `(type-infinity T)` | a compilation error -- integers have no infinity | positive infinity |

```lisp
(type-min int)        ; -2147483648
(type-max ulong)      ; 18446744073709551615
(type-max float)      ; 3.4028235e38
(type-infinity float) ; +inf -- negate it for -inf: (- (type-infinity float))
```

For floating-point types, `type-min` and `type-max` are the finite extremes in **every** precision
context.  `(type-min float)` is about -3.4e38: it is *not* C's `FLT_MIN`, which is the smallest positive
normal.  They are finite because `:fast` precision lets the compiler assume no value is ever infinite --
an infinite constant there is undefined.  `(type-infinity T)` is for `:ieee` code; used where the
precision in effect is `:fast` (by flag, `declaim` or a `with-precision` region) it compiles with a
**warning**, not an error, because precision can be forced from the command line.

`T` must be a numeric scalar type; anything else (a vector type, say) is a compilation error.

