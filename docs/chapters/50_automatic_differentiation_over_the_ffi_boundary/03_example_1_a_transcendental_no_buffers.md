# Example 1 — A transcendental, no buffers


A foreign C function computing `sin`:

```c
/* libmath.c */  float c_sinf(float x) { return sinf(x); }
```

Forward: `y = sin(x)`. Backward (chain rule): `dx = dy * cos(x)`.

Forward FFI signature `#'(float => float)` derives VJP signature `#'(float float => float)`:
primal `x`, seed `dy`, returns `dx`.

```
;; Declare the foreign function and name its backward.
(def-foreign-function c_sinf #'(float => float) c-sinf-bwd)

;; The backward is an ordinary def-function whose signature matches the derived VJP.
(def-function c-sinf-bwd ((x float) (dy float))
  (declare #'(float float => float))
  (* dy (cos x)))                       ;; dx = dy * cos(x)

;; Now c_sinf is differentiable wherever it is called from a --differentiate kernel.
(def-type cell-f (cell float :address-space :global))

(def-kernel use_sinf (x &out y)
  (declare #'(float &out cell-f))
  (set! (~ y) (c_sinf x)))
```

A two-input forward (e.g. `#'(float float => float)`) is identical in shape: the VJP takes both
primals plus the seed and returns both partials in order — `#'(float float float => float float)`.

