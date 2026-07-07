This endeavor picks up where 132-mma-fundamentals left off.

That endeavor implemented the core MMA fundamentals that Crisp uses and exposes.

But it only did so for PTX.  In this endeavor we do the same, but for SPIR-V.



- make-register-tile
- mma-accumulate-via-tile
- - accum-op
- load-fragment
- mma-accumulate
- inner-dimension / outer-dimension
- :mma-shapes from the hardware profile.

As was documented, the goal was to realize a basic synchronous MMA tile multiplication.


```lisp
(with-template-type (T)
  (def-type mat-a (matrix T :address-space :global :align :compact :contiguous-term :row-major))
  (def-type mat-b (matrix T :address-space :global :align :compact :contiguous-term :col-major))
  (def-type mat-c (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function tiled_matmul (A B &out C)
    (declare #'((mat-a T) (mat-b T) (mat-c T))
             (global-size :derive-from C :strategy :strided))
    (let ((A-tile (make-scratch-matrix A (64 16)))          ; SLM: TM×TK
          (B-tile (make-scratch-matrix B (16 64)))          ; SLM: TK×TN
          (C-tile (make-register-tile T (64 64) (identity T)))) ; registers: TM×TN
      (tile-stride C C-tile (grid-y grid-x)                 ; each workgroup owns one C tile
        (do-times (grid-k (num-k-tiles A B A-tile))         ; grid-k = tile index
          (load-tile A A-tile (grid-y grid-k))              ; SYNCHRONOUS
          (load-tile B B-tile (grid-k grid-x))
          (sync-workgroup)
          (mma-accumulate-via-tile (16 8 16) C-tile A-tile B-tile (acc)
            (accum-op))                                     ; walks 64×64 in 16×8×16 steps
          (sync-workgroup))                                 ; safe to overwrite SLM
        (store-tile C-tile C (grid-y grid-x))))))
```