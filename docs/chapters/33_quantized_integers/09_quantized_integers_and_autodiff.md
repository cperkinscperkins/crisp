# Quantized Integers and Autodiff ✅


The true derivative of rounding is zero, which is useless for training. So Crisp uses a
*straight-through estimator* (STE): going backward, rounding is treated as if it were not there.

| Form | Backward rule | Exact? |
|---|---|---|
| `(to-q x s)` | `dq/dx = 1/s`, `dq/ds = -x/s^2`; zero when saturated | STE |
| `(to-float q s)` | `d/dq = s`, `d/ds = q` | Exact |
| `(*! a b)` | Product rule | Exact |
| `(widen q)` | Identity | Exact |
| `(+ A A)`, `(- A A)` | Linear | Exact |
| `(to-q A m)` | `dq/dA = m`, `dq/dm = A`; zero when saturated | STE |
| `(max B B)`, `(min B B)` | Follows the winner | Exact |

The adjoint of a quantized value is a `float`, and the gradient buffer of a quantized kernel input is a
`float` tensor.

The usual training pattern is *fake quantization*: the forward pass rounds through the quantized type,
and the backward pass sees through it.

```lisp
(def-qint q-a :base char :accum int)
(def-type fc (cell float :address-space :global))

(def-kernel fake_quant (x s &out y)
  (declare #'(fc fc &out fc => nil))
  (set! (~ y) (to-float (to-q-a (~ x) (~ s)) (~ s))))
```

Here `dy/dx = 1`, and `dy/ds = q - x/s`, the Learned Step Size gradient.

Training happens in float, with `to-q` and `to-float`. The integer path is for inference:

- Integer MMA has no backward, and says so: `integer MMA has no backward`. Its backward would multiply
  float adjoints by int8 operands, which no hardware form accepts.
- A raw cast of an active value, `(to q-a x)` or a one-argument `(to-q-a x)`, has no gradient and is
  refused.

> Testing note: `VERIFY-AUTODIFF` compares against finite differences, which see the true step function,
> so an STE gradient cannot match them. Specs of these gradients use `fd=off` with hand-derived
> `expect.` values.



