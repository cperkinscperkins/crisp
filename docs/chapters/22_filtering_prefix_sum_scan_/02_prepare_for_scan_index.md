# `prepare-for-scan--index`

```
(prepare-for-scan--index input-vec predicateF (<localScratchVar>) ...)
```
This is a macro much like `prepare-for-scan--value` above, except the `predicateF` is type is `#(ulong => bool)`
and it is called with THE INDEX into `input-vec`.

See an example of using it in `word_search` below.


POssible Implementation:
```
;; -- prepare-for-scan--value --
(defmacro prepare-for-scan--value (input-vec predicateF (local-flags-var) &body body)
  ;; Ensure predicate matches input vector type
  (c-t-assert (is-type-of predicateF (predicate-type (element-type input-vec))) "Predicate type mismatch")

  ;; Generate the code
  `(let (;; Allocate the local memory using the name provided by the user
          (,local-flags-var (make-scratch-vector uint :match-workgroup-size))
          (local-id (get-local-id))
          (global-id (get-global-id)))

      ;; Generate Flags in Parallel 
      (when (< global-id (length~ ,input-vec)) ; Only active threads participate
        ;; Apply predicate
        (let ((match? (funcall ,predicateF (~ ,input-vec global-id))))
          ;; Store 1 or 0 in the user-provided local memory buffer
          (set! (~ ,local-flags-var local-id) (if match? 1 0))))

      ;; Ensure all flags are written before the user's code runs
      (local-barrier)

      ;; Splice in the body provided by the user
      ,@body))
```

