# `copy` 📝


`(copy input-vec output-vec)`

Copies from input to output. Use `vector` as a view if you need offsets or partials.

Possible Implementation
```
;; -- copy --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function copy (in &out out)
    (declare #'((in-vec T A) &out (out-vec T A)))
    (r-t-assert-0 (= (length~ in) (length~ out)) "lengths must be the same")
    (loop-vector-stride in (i)
      (set~ (~ out i) (~ in i)))))
```

