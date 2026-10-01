# Matrix Multiply with Pipelining via Warp Specialization ✅


```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function warp-specialized-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 

    ;; ring depth 3 is a repeated LITERAL (:ring-count needs a compile-time integer — see Chapter 2).
    (let ((A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count 3))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count 3))
          ;; C-tile lives on the 2 CONSUMER warps only (warp 0 is the producer, holds no fragment).
          ;; 128x128 with (16 8 8) = 8x16 = 128 fragments; 2 consumers -> 64 each (evenly divides).
          (C-tile (make-register-tile T (128 128) 0.0 :warps '(false true true)))
          (M N (outer-dimensions A B))
          (K (inner-dimension A B))
          (n-k-steps (/ K 128))   ; k-step is the 128-wide staging tile; producer & consumer share this count
          
        ;; 1. The Barriers.  Both are ring depth 3; :arrivals is how many transfers land on each
        ;; slot per stage (Chapter 2 makes it required for every barrier ring).
        ;; empty starts 'signaled' so the Producer can immediately begin fetching; the Consumer
        ;;   arrives it ONCE per slot (its single `signal`), so :arrivals 1.
        (empty-barrier-ring (make-async-barrier-ring :ring-count 3 :arrivals 1 :initial-state :signaled))
        ;; full starts 'waiting' so the Consumer doesn't read garbage; the Producer's two loads
        ;;   (A + B) arrive it, so :arrivals 2.
        (full-barrier-ring  (make-async-barrier-ring :ring-count 3 :arrivals 2 :initial-state :waiting)))

    ;; Outer loop
    (tile-stride C C-tile (grid-y grid-x) 
      
      ;; Split the execution!  The compiler physically maps these to different warps.
      ;; :consumer 2 (not 3) so the 128-fragment C-tile divides evenly across the consumers;
      ;; the workgroup is (1 + 2) * warp-size = 3 warps.
      (with-warp-specialization (:producer 1 :consumer 2)
        
        ;; ==========================================
        ;; THE PRODUCER BLOCK (Memory only)
        ;; ==========================================
        (:producer
          (let ((ring-idx 0))
            (dotimes (grid-k n-k-steps)
              
              ;; 1. Wait for the Consumer to say this SLM slot is empty/safe.
              (await (ring-get empty-barrier-ring ring-idx))
              
              ;; 2. Issue the hardware fetch. 
              ;; The hardware DMA engine will AUTOMATICALLY signal the full-barrier when the bytes arrive.
              (load-tile A (ring-get A-tile-ring ring-idx) (grid-y grid-k) :barrier (ring-get full-barrier-ring ring-idx))
              (load-tile B (ring-get B-tile-ring ring-idx) (grid-k grid-x) :barrier (ring-get full-barrier-ring ring-idx))
              
              ;; 3. Move to the next ring slot
              (set! ring-idx (mod (+ ring-idx 1) 3)))))
        
        ;; ==========================================
        ;; THE CONSUMER BLOCK (Math only)
        ;; ==========================================
        (:consumer
          (let ((ring-idx 0))
            (dotimes (grid-k n-k-steps)
              
              ;; 1. Wait for the hardware DMA to say the bytes have arrived.
              (await (ring-get full-barrier-ring ring-idx))
              
              ;; 2. Execute the pure math
              (let ((A-tile (ring-get A-tile-ring ring-idx))
                    (B-tile (ring-get B-tile-ring ring-idx)))
                (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
                  (accum-op)))
              
              ;; 3. Manually signal to the Producer that we are done reading this slot.
              (signal (ring-get empty-barrier-ring ring-idx))
              
              ;; 4. Move to the next ring slot
              (set! ring-idx (mod (+ ring-idx 1) 3)))
          
          ;; EPILOGUE (Only the Consumer writes back to Global Memory!)
          (add-bias C-tile bias-tile) ;; <-- fictional operation for illustrative purposes
          (relu C-tile)
          (store-tile C-tile C  (grid-y grid-x)))))))))

```


