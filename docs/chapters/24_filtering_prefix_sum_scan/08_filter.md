# `filter` 📝

```
  (filter input-vec predicateF result-vec)
  (filter-soa input-soa-vec propertyExpression predicateF result-soa-vec)
```

The `filter` macro takes an input vector of type T, and a predicate function `#(T => bool)`, as
well as a vector to hold the results. It returns the actual number of matches found.
It is up to the caller to anticipate the size of the result vector. But even if it is too small
the return count is correct.

```
(let ((numbers #(1 2 3 4 5 6 7 8 9))
      (result  #(0 0 0 0 0 0 0 0 0))
      (count (filter number #'even? result)))
  ; at this point.  count will be 4
  ; and result could be something like #(6 8 2 4 0 0 0 0 0 0)
```

The variant `filter-soa` has an additional `propertyExpression` symbol argument. That particular property
of the struct `element-type` will be passed to the predicate function. Note that the type `T` of
the predicate function `#(T => bool`) must match the type of the struct property and both be
determinable at compile time. (ie the exact property being referenced can't be a runtime variable).

#### possible implementation of filter
```
;; -- filter --
(defmacro filter (input-vec predicateF result-vec)
  (c-t-assert (is-type-of predicateF (predicate-type (element-type input-vec))) "type mismatch between predicateF and input-vec")
  (c-t-assert (is-type-of (element-type input-vec) (element-type result-vec)) "type mismatch between input-vec and result-vec")
  `(let ((local-wg-matches (make-scratch-vector uint :match-workgroup-size))
        (local-id (get-local-id))
        (global-counter 0)
        (wg-offset 0)
        (is-a-match nil))
     (declare (global-mem global-counter) (local wg-offset) (grid-level))
     (with-global-linear-id (i)
      ;; STEP 1: local match detection
      (set! is-a-match (when (< i (length~ ,input-vec)) (funcall predicateF (~ ,input-vec i)))
      (set! (~ local-wg-matches (get-local-linear-id)) (select-if is-a-match 1 0))
      (sync-workgroup)
      ;; local-wg-matches = #(0 1 0 1 1 0 ...)

      ;; STEP 2: Reorder
      (let ((count (exclusive-scan-workgroup local-wg-matches)))
            ;; local-wg-matches is now #(0 0 1 1 2 3)

        ;; STEP 3 - get global write offset
        (when-thread-in-group-is 0
          ;; add this workgroups count to global
          (set! wg-offset (atomic-add! global-counter count))))
      
      ;; STEP 4 - write results to global memory
      (sync-workgroup)

      (when is-a-match
        (let ((final-write-pos (+ (~ local-wg-matches local-id) wg-offset)))
          (when (< final-write-pos (length~ ,result-vec))
           (set! (~ ,result-vec final-write-pos) (~ ,input-vec i)))))))
      (return global-counter)))
```


