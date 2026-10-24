# Matrix Multiply with pipelining ✅


We use rings to set up a load/execute pipeline. 

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function pipeline-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 
    ;; NB: the ring depth (3) is a repeated LITERAL — :ring-count needs a compile-time integer
    ;; and Crisp has no constant form, so a `(let ((pipeline-stages 3)) … :ring-count
    ;; pipeline-stages)` binding would NOT compile.  We keep it as a plain 3 throughout.
    (let ((A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count 3))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count 3))
          (C-tile (make-register-tile T (128 128) 0.0))
          ;; :arrivals 2 — each slot tracks its stage's A-load + B-load.  REQUIRED for :block, and
          ;; NOT inferable (the prologue and the main loop both load the ring), so you state it.
          (barrier-ring (make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2))
          (n-k-steps    (/ (inner-dimension A B) 128)))

      ;; Outer loops for C-tile (X and Y coordinates).  tile-stride binds grid-y / grid-x as
      ;; TILE-IDs — exactly what load-tile consumes — and a register C-tile's shape must be given
      ;; as the compile-time (M N) size-list (the register tile SROA-explodes, so its symbol is
      ;; gone by tile-stride time).
      (tile-stride C (128 128) (grid-y grid-x)

        ;; 1. PROLOGUE: fill the pipeline for the current C-tile.  Plain dotimes: ring-get takes a
        ;; runtime index, so it serves both the prologue and the main loop.  (to-ulong i) — a
        ;; dotimes counter is int, but tile-IDs / ring indices are ulong.
        (dotimes (i 3)
          ;; Stride along K, keeping Y and X locked to the current block.
          (load-tile A (ring-get A-tile-ring (to-ulong i)) (grid-y (to-ulong i)) :barrier (ring-get barrier-ring (to-ulong i)))
          (load-tile B (ring-get B-tile-ring (to-ulong i)) ((to-ulong i) grid-x) :barrier (ring-get barrier-ring (to-ulong i))))

        ;; 2. MAIN K-LOOP.  The ring slot is just (mod grid-k 3) — no mutable ring-idx / set!.
        (dotimes (grid-k n-k-steps)
          (let ((slot (mod grid-k (to-ulong 3))))

            ;; Wait for the current stage's data to arrive in SLM.
            (await (ring-get barrier-ring slot))

            ;; Execute the math from SLM into registers.
            (let ((A-tile (ring-get A-tile-ring slot))
                  (B-tile (ring-get B-tile-ring slot)))
              (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
                ;; STAGED (this loop calls us once per K-step) -> my-accum is a PARTIAL sum;
                ;; fuse activation in the epilogue below, on the completed C-tile, not here.
                (accum-op)))

            ;; Every thread must be DONE reading this slot's SLM before the prefetch below
            ;; overwrites it — the ring wraps onto the slot we just consumed.  This sync goes
            ;; BEFORE the prefetch (issuing it after would race the overwrite against the reads).
            (sync-workgroup)

            ;; Issue the fetch for the NEXT chunk of K (grid-k + 3) into the slot we just freed,
            ;; so it lands while the following stage computes.  The guard is uniform (it depends
            ;; only on the K-loop counter), but a dotimes counter reads as :unknown uniformity, so
            ;; load-tile's internal sync-workgroup would be flagged divergent — assert it with
            ;; to-workgroup-uniform (which must be a let initializer).
            (let ((next-k (+ grid-k (to-ulong 3))))
              (let ((more-k? (to-workgroup-uniform (< next-k n-k-steps))))
                (when more-k? ;; don't fetch past the end of K
                  (load-tile A (ring-get A-tile-ring slot) (grid-y next-k) :barrier (ring-get barrier-ring slot))
                  (load-tile B (ring-get B-tile-ring slot) (next-k grid-x) :barrier (ring-get barrier-ring slot)))))))

        :epilogue
        ;; 3. EPILOGUE: C-tile is complete — fuse activation on the finished tile, then store.
        (relu C-Tile)                        ;; <-- the RIGHT place to fuse (complete C-tile)
        (store-tile C-Tile C (grid-y grid-x))))))
```

