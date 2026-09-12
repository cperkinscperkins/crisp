# Matrix Vector Multiply `(m*v M v)` 📝

```
(mat-vec-mult someMatrix someVec &out outVec &optional scratchVec)
```
The basic operation is `y = M * x`, where `M` is a 2D matrix, `x` is a 1D vector, and the output `y` is a 1D vector.

Possible Implementation
```
;; -- mat-vec-mult --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function mat-vec-mult (M x-vec &out out-vec 
                      &optional (m-row-scratch (make-scratch-vector T (num-cols M)))
                                (x-vec-scratch (make-scratch-vector T (length~ x-vec))))
    (declare #'((matrix (in-vec T A)) (in-vec T A) &out (out-vec T A) &optional (scratch-vec-type T) (scratch-vec-type T)))
    (r-t-assert-0 (= (num-rows M) (length~ out-vec)) "output vector must match matrix row count")
    (r-t-assert-0 (= (num-cols M) (length~ x-vec)) "input vector length must match matrix col count")
    ;; matrix is not bigger than local-size * num-groups
    (r-t-assert-0 (<= (num-cols M) (local-work-size) ) "matrix width must not be greater than local-size")
    (r-t-assert-0 (<= (num-rows M) (get-num-groups)) "matrix height must not be greater than num work groups")

    (in-each-group (i)
      (when (< i (num-rows M))
        (copy (row i M) m-row-scratch) ;; each workgroup takes a row.
        (copy x-vec  x-vec-scratch)

        (let ((res-view (make-vector out-vec 1 i)))
          (dot-prod-grid m-row-scratch x-vec-scratch res-view))))))
            
```

