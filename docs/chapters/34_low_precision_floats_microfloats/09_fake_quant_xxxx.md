# fake-quant-XXXX ✅


```lisp
(fake-quant-XXXX x &out y)
```

Sends each element of `x` through the format, block by block: it chooses the scale, encodes, decodes,
and writes the float result into `y`. Backward, it is straight through: `dy/dx = 1`. The scale is held
constant, the usual choice.

```lisp
(def-microfloat-block mf :base fp4 :scale fp8-e4m3 :accum float :shape (4))

(def-kernel fq (a &out b)
  (declare #'(mf-floats &out mf-floats) (global-size :set-to 4) (local-size :set-to 4))
  (fake-quant-mf a b))
```

