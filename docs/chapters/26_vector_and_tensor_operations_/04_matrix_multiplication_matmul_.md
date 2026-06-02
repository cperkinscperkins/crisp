# matrix multiplication (matmul) ⚠️


Matrix multiplication (`matmul`) is an operation that takes two matrices and produces a new matrix.
Each element in the resulting matrix is the dot product of a row from the first matrix and a column from the second matrix. 
It's the fundamental operation for transforming data in linear algebra, used for tasks like 
rotating and scaling vectors in 3D graphics or applying weights in a neural network.

### matmul

`(matmul A B)`

Crisp provides a `matmul` function. It takes two arguments, they are both matrices,
which are just 2D `tensor`. Note using `matmul` requires that the calling kernel
is enqueued with an arity of 2.

Note also that the inner dimensions must match.  For example multipling
a `2x3` matrix by a `3x4` is allowed, because the "inner" number is `3`.
But conversely, multiplying a `3x4` by a `2x3` matrix is NOT allowed because
the inner dimension (`4` and `2`) are not equal.


### OPTIMIZING DEMONSTRATION

Below are possible implementations of dot product and `matmul`

Note that the `matmul-naive` implementation is easy to write and understand
but is not maximally performant. It may not always use coalesced access
and it makes too many "small" writes to global memory.

But the `matmul` implementation below it solves both of those problems
simply by using tiles.  The `load-tile` macro is, once again, demonstrating
its value.

The version of `matmul` below is not our final one. We'll visit it again when we cover
the hardware accellerated types that have a widened accumulator, quantized integers and microfloats.

``` 
(with-template-type (T A)
  (declare (type-is T #'is-scalar?)
           (value-is A #'is-alignment?))

  ;; -- dot-prod-grid --                     
  (def-grid-function dot-prod-grid (A B &out RESULT)
    (declare #((in-vec T) (in-vec T) (single-result T))
              (global-size :derive-from A :strategy :strided)) 
    (when-thread-is 0
      (r-t-assert (= (length~ A) (length~ B)) "lengths must match")) 
    (let ((C-scratch (make-scratch-vector (length~ A) :name "dot product")))  
      (map-stride #'* (A B) C-scratch)
      (reduce-vec-atomic #'+ C-scratch 0 RESULT)))

  ;; -- dot-prod-seq --
  (def-function dot-prod-seq (A B)
    (declare #((in-vec T) (in-vec T) => T))

    (let ((sum 0))
      (dotimes (i (length~ A))
        (set! sum (+ sum (* (~ A i) (~ B i)))))
      (return sum))))

#|
  matmul-naive
  This is a very simple, easy to read version of matmul that uses
  thread-stride and dot-prod-seq to easily multiply two matrices.
  But it won't coalece unless A is row-major and B is col-major.
  And, even then, it will still be slow, because A and B
  are most likely using :global memory, so this routine has many
  individual accesses, which will be slow. 

  Using tiles (below) both guarantees coalesced access
  and also means access to global memory is done in larger passes
  which is more performant.
|#
(with-template-type (T)
  (declare (type-is T #'is-scalar? T))

  ;; -- matmul-naive --       
  (def-grid-function matmul-naive (A B)
    (declare #(matrix matrix => matrix) (global-size :dims 2))
    (let ((inner-A (num-cols A))
          (inner-B (num-rows B))
          (outer-A (num-rows A))
          (outer-B (num-cols B)))
      (when-thread-is 0
        (r-t-assert (= inner-A inner-B) "inner dimensions must match!"))
      
      (let ((vec (make-result-vector A (* outer-A outer-B)))
            (res (make-tensor vec outer-A outer-B )))
                (thread-stride '(outer-A outerB) :global-size (x y)   
                  (set! (~ res x y) (dot-prod-seq (row x A) (col y B)))) 
                (return res)))))       

#|
  matmul - performant.
|#

;; same TILE_DIM as used by convert-layout 
(def-const TILE_DIM 32 ulong)

;; helpers (not fully defined yet)
;;   make-tile variants will call make-tile-scratch-vector themselves.
;; (make-tile-scratch-vector T)
;; (make-tile dim T) ;; <-- will do performance padding? Unsure.
;; (make-tile dim-y dim-x T) 

(with-template-type (T)
  (declare (type-is T #'is-scalar?))

  ;; -- matmul --
  (def-grid-function matmul (A B C)
    (declare #(matrix matrix matrix => nil)
             (local-size :set-to `(,TILE_DIM ,TILE_DIM)) 
             (global-size :derive-from C             
                          :strategy :tiled           
                          :tile-shape TILE_DIM       ; Tile size is TILE_DIM x TILE_DIM
                          :dims 2
                          :msg "Launch one workgroup per output tile of C"))

    (let ((tile-A (make-tile TILE_DIM T))
          (tile-B (make-tile TILE_DIM T))
          (local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
          (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1))
          (acc 0.0)) ; Per-thread accumulator register

      ;; main loop over the tiles in the inner dimension
      (dotimes (tile-num (ceil (num-cols A) TILE_DIM))

        ;; adaptive, coalesced loading
        ;; Use the 'load-tile' macro to handle the complexity.
        (load-tile A tile-A group-id-y tile-num
                   :transpose (= (get-layout A) :col-major))

        (load-tile B tile-B tile-num group-id-x
                   :transpose (= (get-layout B) :row-major))
        
        (local-barrier)

        ;; This part is now simple and fast, both local tiles are row-major.
        (dotimes (k TILE_DIM)
          (set! acc (+ acc (* (~ tile-A local-id-y k)
                              (~ tile-B local-id-x k)))))

        (local-barrier))

      ;; store final result. coalesced access
      (let ((c-row (+ (* group-id-y TILE_DIM) local-id-y))
            (c-col (+ (* group-id-x TILE_DIM) local-id-x)))
        (when (and (< c-row (num-rows C)) (< c-col (num-cols C)))
          (set! (~ C c-row c-col) acc))))))
                           
```

