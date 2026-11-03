# Operations ✅


| Form | Result | Notes |
|---|---|---|
| `(*! B B)` | `A` | Same type, or a declared product |
| `(+! B B)`, `(-! B B)` | `A` | Widening add and subtract |
| `(+! A B)`, `(-! A B)` | `A` | Accumulate a base value |
| `(widen B)` | `A` | The same value at the accumulator type.  For initializing an accumulator |
| `(+ A A)`, `(- A A)` | `A` | Same accumulator type.  Wraps on overflow |
| `(max B B)`, `(min B B)` | `B` | Scale independent |
| `(max A A)`, `(min A A)` | `A` | |
| `< <= > >= = !=` | `bool` | Same type only |

The overflow rule: **narrowing saturates, accumulators do not.** An `int` accumulator holds 131,072
worst-case `char` x `char` products, or 65,793 `uchar` x `char` products.

`+!` and `-!` are the add and subtract for base values, matching `*!`. Each argument widens to its
accumulator type, then they combine, so `(+! a b)` and `(+! acc b)` both work. There is no widening add
instruction behind them (`ptxas` refuses `add.s8` and `add.wide.s16`), so `(+! a b)` lowers exactly like
`(+ (widen a) (widen b))`. For the basic types `+!` is `+`, just as `*!` is `*`.

`*!` runs each operand's own extension (`sext` for `char`, `zext` for `uchar`), then multiplies at the
accumulator's width. On NVIDIA that becomes `mul.wide.s16`.

For all other math operations, convert your `qint` to a floating-point value, perform the calculation on
that, and convert back. Quantized integers have no automatic type promotion.

To add two quantized tensors, as in a residual connection:

```lisp
;; same type, so same scale
(to-q-a (+! x y) 1.0)

;; different scales: go through float
(to-q-out (+ (to-float x s-x) (to-float y s-y)) s-out)
```

