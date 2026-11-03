# def-qint-product ✅


Two different quantized types do not multiply unless their product has been declared:

```lisp
(def-qint q-act :base uchar :accum int)
(def-qint q-wt  :base char  :accum int)
(def-qint-product q-dot (q-act q-wt) :accum int)  ; expands to (set-accum (q-act q-wt) q-dot)

(accum q-act q-wt) ; => q-dot
```

Argument order matters: `(q-act q-wt)` does not also declare `(q-wt q-act)`. This is how a mixed-sign
product (unsigned activations, signed weights) is written, and the tensor hardware supports it.

