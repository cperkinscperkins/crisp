# The Optimal Intel Pipelined MMA


This is the shipped kernel from `tests/spec/142-mma-prefetch/14-pipeline-bench.crisp`, which runs
MMA_CORRECT on an Arc B580.  It stretches the synchronous baseline into an LSC 2D block-prefetch
pipeline: a register-tile ring double-buffers the operands while prefetches run two K-steps ahead.

```lisp
(def-hardware-profile bmg :simd-width 16 :mma-shapes ((8 16 8)))

(def-type a-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (global-size :derive-from C :strategy :strided)
           (local-size :set-to 16))                       ; Intel MMA wants a subgroup of 16
  (let ((n-k-steps (/ (inner-dimension A B) (to-ulong 8))))

    (tile-stride C (32 32) (grid-y grid-x)
      ;; Ping-pong REGISTER double buffering — make-register-tile-ring, not a scratch ring.
      ;; Operand tiles are M x K and K x N, so A and B have different shapes.
      (let ((A-ring (make-register-tile-ring float (32 8) :ring-count 2 :operand :a))
            (B-ring (make-register-tile-ring float (8 32) :ring-count 2 :operand :b))
            (C-tile (make-register-tile float (32 32) 0.0)))

        ;; --- prologue: prime the pump for k=0 and k=1 ---
        (prefetch-tile A (grid-y 0) :size (32 8))
        (prefetch-tile B (0 (* grid-x (to-ulong 2))) :size (8 16))
        (prefetch-tile A (grid-y 1) :size (32 8))
        (prefetch-tile B (1 (* grid-x (to-ulong 2))) :size (8 16))
        (load-tile A (ring-get A-ring 0) (grid-y 0))
        (load-tile B (ring-get B-ring 0) (0 grid-x))

        (dotimes (grid-k n-k-steps)
          (let ((next-k     (+ grid-k (to-ulong 1)))
                (prefetch-k (+ grid-k (to-ulong 2))))

            ;; 1. prefetch a future K — lowers to OpSubgroup2DBlockPrefetchINTEL (into L1).
            ;;    The guard is asserted uniform: a barrier lands inside it in the backward pass.
            (let ((more-prefetch? (to-workgroup-uniform (< prefetch-k n-k-steps))))
              (when more-prefetch?
                (prefetch-tile A (grid-y prefetch-k) :size (32 8))
                (prefetch-tile B (prefetch-k (* grid-x (to-ulong 2))) :size (8 16))))

            ;; 2. register load for the NEXT k — OpSubgroup2DBlockLoadINTEL (L1 -> GRF).
            (let ((more-k? (to-workgroup-uniform (< next-k n-k-steps))))
              (when more-k?
                (load-tile A (ring-get A-ring (mod next-k (to-ulong 2))) (grid-y next-k))
                (load-tile B (ring-get B-ring (mod next-k (to-ulong 2))) (next-k grid-x))))

            ;; 3. DPAS on the CURRENT k while the other slot is still loading.
            (mma-accumulate-via-tile (8 16 8) C-tile
                                     (ring-get A-ring (mod grid-k (to-ulong 2)))
                                     (ring-get B-ring (mod grid-k (to-ulong 2))))))
        :epilogue
        (store-tile C-tile C (grid-y grid-x))))))
```

Three things in there are load-bearing and easy to get wrong:

- **The slot index is `(mod grid-k 2)`, not a mutable counter.**  A register-ring slot must fold
  to a compile-time integer — the GRF is not runtime-indexable — and `(mod <loop-var>
  <ring-count>)` folds when the compiler unrolls the loop.  A `setf`-updated `ring-idx` does not.
- **The MMA shape is `(8 16 8)`**, Intel XMX, not NVIDIA tf32 `(16 8 8)`.  It must match the
  profile's `:mma-shapes`.
- **Each guard gets its own `let` binding through `to-workgroup-uniform`.**  Bound in the
  enclosing `let*` instead, ANF hoists the whole `when` into a value binding and the AD checker
  reports a thoroughly misleading "`LOAD-TILE-AT` is not differentiable".

