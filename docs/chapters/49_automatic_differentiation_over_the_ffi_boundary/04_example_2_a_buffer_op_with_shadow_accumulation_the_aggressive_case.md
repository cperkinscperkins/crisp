# Example 2 — A buffer op with shadow accumulation (the aggressive case)


A foreign C function applies `sin` elementwise over a global buffer:

```c
/* libvec.c (OpenCL for spv / CUDA for ptx) */
void c_vsin(int n, __global const float *in, __global float *out) {
  for (int i = 0; i < n; ++i) out[i] = sin(in[i]);
}
```

Forward FFI `#'(int (c-pointer :global) (c-pointer :global) => nil)` derives VJP
`#'(int (c-pointer :global) (c-pointer :global) (c-pointer :global) (c-pointer :global) => float)`:

- **Primals:** `n`, `in`, `out`
- **Seeds:** none (`=> nil`)
- **Shadows:** `shadow-in` (for `in`), `shadow-out` (for `out`) — one per pointer input, in order.
  The shadow of the *output* buffer carries the incoming downstream gradient; the shadow of the
  *input* buffer is where we accumulate.
- **Returns:** `float` — the gradient for the scalar `n` (semantically 0).

```
(def-type fvec (vector float :address-space :global :align :compact))

(def-foreign-function c_vsin
  #'(int (c-pointer :global) (c-pointer :global) => nil)
  c-vsin-bwd)

;; VJP: shadow-in[i] += shadow-out[i] * cos(in[i]) ; return 0.0 for n.
(def-function c-vsin-bwd ((n int)
                          (in        (c-pointer :global))
                          (out       (c-pointer :global))
                          (shadow-in  (c-pointer :global))
                          (shadow-out (c-pointer :global)))
  (declare #'(int (c-pointer :global) (c-pointer :global)
              (c-pointer :global) (c-pointer :global) => float))
  (let ((vin  (marshall-vector in         n fvec))
        (vsi  (marshall-vector shadow-in  n fvec))
        (vso  (marshall-vector shadow-out n fvec)))
    (dotimes (i n)
      (set! (~ vsi i)
            (+ (~ vsi i) (* (~ vso i) (cos (~ vin i)))))))
  0.0)                                    ;; gradient for the int primal n
```

**Automatic shadow routing.** The user's kernel never threads shadow pointers manually. It calls the
forward function normally, passing buffer base pointers:

```lisp
(def-kernel use_vsin (n in &out out)
  (declare #'(int fvec &out fvec))
  (c_vsin n (base-ptr~ in) (base-ptr~ out)))
```

When differentiating, the compiler sees that `(base-ptr~ in)` / `(base-ptr~ out)` come from
differentiable tensors and supplies `(base-ptr~ in_GRAD)` / `(base-ptr~ out_GRAD)` as the matching
shadow arguments — the base pointers of those tensors' gradient cells. The mechanical ABI lets the
graph route the gradients blindly while the actual accumulation happens inside the VJP.



