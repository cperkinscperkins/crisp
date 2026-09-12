# Chapter 1 — Basic Matrix Multiply with async tile loading


We use basic async tile loading to hide some of the memory latency when fetching tiles.

We also use the highly performant `mma-accumulate-via-tile` to perform the matrix multiply.

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function basic-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided))  
    (let ((A-tile (make-scratch-matrix A (128 128)))
          (B-tile (make-scratch-matrix B (128 128)))
          (C-tile (make-register-tile T (128 128) 0.0))
          (K (inner-dimension A B))
          (k-step   128)
          (barrier (make-async-barrier))) ;; arch-automatic: :block on sm_90+, else :linear
    (matrix-multiply-tile-stride C C-tile K k-step (grid-y grid-x grid-k)

      (load-tile A A-tile (grid-y grid-k) :barrier barrier) 
      (load-tile B B-tile (grid-k grid-x) :barrier barrier )
      (await barrier) 
      
        (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
            ;; accum-op is available here; call it to fire the DPAS/MMA for THIS K-step.
            ;; NOTE: this is the STAGED pattern — the macro's grid-k loop calls us once per
            ;; K-step, so my-accum is a PARTIAL sum here.  Do NOT fuse activation on it; the
            ;; activation goes in the :epilogue below, on the completed C-tile.
            (accum-op))
        ;; (Another barrier usually goes here before the next 'k' iteration overwrites SLM)
        (sync-workgroup)
      :epilogue
        ;; K-loop done — C-tile is complete.  Fuse the epilogue on the finished tile, then store.
        (relu C-tile)
        (add-bias C-tile bias-tile)          ;; <-- fictional operation for illustration
        (store-tile C-tile C (grid-y grid-x))))))
```


