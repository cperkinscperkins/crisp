# `any?` 📝

```
(any? someVec &out result &optional predicateF)
```
`any?` checks to see if any of the values in `someVec` are true and, if so, sets its result to `true`.

Possible Implementation
```
;; -- any? --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function any? (someVec &out result-vec &optional (predicateF (gen-to-bool T)))
    (declare #'((in-vec T A) &out (single-result int) &optional (predicate-type T))
      (global-size :derive-from someVec :strategy :strided))
      
    ;; this thread checks its strides
    (let ((partial-result 0)) 
      (loop-vector-stride someVec (i)
        (when (funcall predicateF (~ someVec i))
          (set! partial-result 1))))

    (reduce-to-1-cas #'logior partial-result 0 result-vec)))
```

