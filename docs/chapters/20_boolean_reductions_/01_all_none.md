# `all?` / `none?`

```
(all? someVec &out result &optional predicateF)
(none? someVec &out result &optional predicateF)
```
`all?` checks to see if all the values in a `vector` are true and, if so, sets its result to `true`, otherwise `false`

Conversely, `none?` checks to make sure that none of the values are true, and if so, set result to `true`.

Possible Implementation
```
;; -- all? --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function all? (someVec &out result-vec &optional (predicateF (gen-to-bool T)))
    (declare #'((in-vec T A) &out (single-result int) &optional (predicate-type T))
      (global-size :derive-from someVec :strategy :strided))
      
    ;; this thread checks its strides
    (let ((partial-result 1)) 
      (loop-vector-stride someVec (i)
        (unless (funcall predicateF (~ someVec i))
          (set! partial-result 0))))

    (reduce-to-1-cas #'logand partial-result 1 result-vec)))
```

