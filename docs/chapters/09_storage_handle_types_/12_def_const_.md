# def-const ✅


`def-const` is used to define an immutable expression in global file scope that the compiler will inject in place whereever it encounters it. The Lisp practice is that `def-const` expressions have a `+` sign on either side.

In CRISP `def-const` can only be used for scalar values. It cannot be used for constant vectors (see `def-const-vec` in the next section). 
Due to inference, `def-const` expressions do not typically need type information declared, it is optional.

```
(def-const +PI+ 3.141592654)       ; type will be inferred
;OR
(def-const +PI+ 3.141592654 float) ; type is explicit
;OR
(def-const +PI+ 3.141592654)
(declare (type +PI+ float))        ; type is explicit

;; -- circle-area --
(def-function circle-area (r)
   (declare #'(float => float))
  (* r r +PI+))
```

