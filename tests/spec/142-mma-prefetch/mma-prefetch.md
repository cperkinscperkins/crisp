We've been working our way through the MMA optimization chapters of ./docs/topology.md .  Most of that work has been focused on juggling shared local memory as one would do on NVidia hardware.

For this endeavor, we are optimizing for Intel hardware, using  "prefetch" to grab huge swaths of memory directly
into the GRF. There is an example of the aspirational example code in the topology.md doc. But I'm putting a copy below.  It introduces `make-register-tile-ring` and `prefetch-tile`.  If you'll recall, we did rings for barriers and scratch memory handles back in endeavor 138.

[ ] Is the example code correct for the problem?
[ ] Is teh example code achievable?
[ ] our current `load-tile` in Crisp is synchronous, and the asynchronous variant takes a `:barrier` arg. This seems at odds
    with the aspirational example code, which does NOT use a `:barrier` key but expects `load-tile` to be asynchronous. maybe. Yes or No? If yes, how should we address this?
[ ] does `prefetch-tile` need a destination?  I guess not, it just prepares it so the `load-tile` can run smoothly.
[ ] would having a hardware profile (`def-hardware-profile` and the `--harware-profile` compilation flag) make the compilation better? (I'm guessing yes).
[ ] Are there yet other Intel optimizations we should do, possibly as future endeavors?
   A:  2D Block Stores (OpSubgroup2DBlockStoreINTEL) for writing the C-tile back to global memory efficiently
   A2: supporting different DPAS depths (but our hardware profile has those, IIRC)

[ ] What should happen if targeting PTX?  ( compilation error, presumably for `prefetch-tile` )
[ ] What TDD tests and in what order?





At the end of this I'm going to leave an excerpted discussion with Gemini about this. I'm including it because it touches on the challenges, but also the eventual Crisp solutions. We won't be tackling those solutions today but awareness of the direction we are plotting is useful.


Aspirational Example Code
=========================


```
(with-template-type (T)
  ;; NOTE 'T' cannot be any type. Intel has limits, and some of them are widening types, I think.
  ;; In any case, a type constraint would appear here, but Crisp doesn't support them yet.


  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function intel-prefetch-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) &out (mat T))
               (global-size :derive-from C :strategy :strided)) 

    ;; Ping-Pong Register Double Buffering. 
    ;; Notice: We use make-register-tile-ring, NOT scratch-matrix-ring.
    (let ((pipeline-stages 2) 
          (A-reg-ring (make-register-tile-ring T (128 128) :ring-count pipeline-stages))
          (B-reg-ring (make-register-tile-ring T (128 128) :ring-count pipeline-stages))
          (C-tile (make-register-tile T (128 128) (identity T)))
          (M N (outer-dimensions A B))
          (K (inner-dimension A B)))

      ;; ==========================================
      ;; THE PROLOGUE (Prime the Pump)
      ;; ==========================================
      ;; 1. Fire cache prefetches for k=0 and k=1
      (prefetch-tile A (grid-y 0) :size (128 128))
      (prefetch-tile B (0 grid-x) :size (128 128))
      (prefetch-tile A (grid-y 1) :size (128 128))
      (prefetch-tile B (1 grid-x) :size (128 128))

      ;; 2. Issue the actual register block-loads for k=0
      (load-tile A (ring-get A-reg-ring 0) (grid-y 0))
      (load-tile B (ring-get B-reg-ring 0) (0 grid-x))

      (tile-stride C C-tile (grid-y grid-x) 
        
        ;; ==========================================
        ;; THE K-LOOP PIPELINE
        ;; ==========================================
        (let ((ring-idx 0))
          (do-times (grid-k K)
            (let ((next-k (+ grid-k 1))
                  (prefetch-k (+ grid-k 2))
                  (next-ring-idx (mod next-k pipeline-stages)))

              ;; 1. Issue prefetch for future K.
              ;; This lowers to OpSubgroup2DBlockPrefetchINTEL (Fire and forget into L1)
              (when (< prefetch-k K)
                (prefetch-tile A (grid-y prefetch-k) :size (128 128))
                (prefetch-tile B (prefetch-k grid-x) :size (128 128)))

              ;; 2. Issue register load for the NEXT k.
              ;; This lowers to OpSubgroup2DBlockLoadINTEL (L1 -> GRF).
              ;; The hardware scoreboard tracks this dependency automatically.
              (when (< next-k K)
                (load-tile A (ring-get A-reg-ring next-ring-idx) (grid-y next-k))
                (load-tile B (ring-get B-reg-ring next-ring-idx) (next-k grid-x)))

              ;; 3. Compute on the CURRENT k.
              ;; DPAS executes against the 'ping' registers while the 'pong' registers are loading.
              (mma-accumulate-via-tile (16 8 8) C-tile 
                                       (ring-get A-reg-ring ring-idx) 
                                       (ring-get B-reg-ring ring-idx))
              
              ;; 4. Swap buffers
              (setf ring-idx next-ring-idx))))

        :epilogue
          (relu C-tile) 
          (store-tile C-tile C (grid-y grid-x))))))
```


Discussion With Gemini
======================

PROBLEMS WITH INTEL
-------------------

You are absolutely right. The hardware scoreboard is elegant when it works, but because it gives you enough rope to manage the pipeline manually in software, it also gives you a hundred different ways to hang the execution unit.
When you get this wrong in Crisp, you don't get a crash or a compiler error. You just get a silent, catastrophic drop in TFLOPS because the Xe Core is spending 80% of its clock cycles sitting in a stalled state.
Here are the most common ways this specific ping-pong pipeline breaks down:
1. The Math is Too Fast (Load-to-Use Starvation)
This is the most common reason a 2-stage (Ping-Pong) pipeline fails. Intel's DPAS (Dot Product Accumulate Systolic) instructions are incredibly fast—on modern Xe architectures, a single XVE can execute hundreds of matrix operations per clock cycle.
If the DPAS unit finishes crunching the Ping register in 15 clock cycles, but the load-tile for the Pong register takes 40 clock cycles to arrive from the L1 cache, your ping-pong buffer is too shallow. The thread loops around, attempts to read Pong, and hits a hard scoreboard stall. To fix it, you have to deepen the pipeline to 3 or 4 stages so the math unit always has a backlog of loaded registers to chew on.
2. Register Spilling (The Greedy Pipeline)
So you decide to fix the problem above by changing pipeline-stages to 4. You have now solved the load-to-use starvation, but you created a worse problem.
Intel GPUs have a hard physical limit on the General Register File (GRF)—often 128 or 256 registers per thread. By allocating 4 massive matrix tiles to your register ring, you blow past the GRF ceiling. The compiler won't stop you; it will just silently "spill" the extra registers into SLM (Shared Local Memory) or Global Memory. Suddenly, your asynchronous L1 load-tile is writing to RAM, and your DPAS math is reading from RAM. The scoreboard will stall on almost every single instruction.
3. L1 Cache Thrashing (The Over-Eager Prefetch)
In your Crisp draft, you issue prefetches for K+2. What happens if you get aggressive and prefetch K+4 or K+8?
The LSC (Load Store Cache) will dutifully fetch all that future data into the L1 cache. However, the L1 cache is relatively small. By prefetching too far ahead, the K+8 data evicts the K+1 data that you actually need for the very next loop iteration. When your load-tile fires for K+1, it misses the L1 cache entirely and has to go all the way back to global memory (a "Long Scoreboard Stall"). You successfully prefetched, but you sabotaged your own loads.
4. Write-After-Write (WAW) Hazards
If you botch the loop unrolling or ring-buffer indexing in the compiler lowering, you might accidentally issue a load-tile targeting ring-idx 0 while the DPAS math is still reading from ring-idx 0.
The hardware scoreboard tracks writes as well as reads. It will see that a memory load is trying to overwrite a register that hasn't been safely consumed yet. It will stall the memory issue entirely to protect the data, completely destroying the asynchronous concurrency you were trying to build.


DETECTING
---------
You have the right intuition, but the approaches differ drastically based on whether you want to measure the hardware reality (runtime) or mathematically guarantee the software boundaries (compile-time).
Because Crisp is bounded and not Turing complete, you have a massive advantage here. Here is exactly how both approaches shake out:
1. The Runtime Reality (Why --runtime-checks won't work)
Injecting software-level hazard detection code (like a --runtime-checks flag that inserts assert-like branches in SPIR-V) cannot detect scoreboard stalls.
When the hardware scoreboard stalls a thread, the thread is literally asleep. The software cannot "observe" its own stall because it is not executing. You could insert clock-cycle checks before and after an instruction (%start = clock(), %end = clock()), but that pollutes the very instruction pipeline you are trying to measure and fundamentally alters the compiler's register allocation pass.
The Reliable Runtime Method:
You have to use hardware performance counters. Intel Xe architectures have HW-assisted stall sampling built into the silicon. Tools like Intel VTune Profiler or the GTPin instrumentation framework specifically query the SCOREBOARD ID and PIPESTALL hardware counters. This tracks exactly which instruction pointer triggered a stall and why, completely out-of-band from your kernel code.
2. The Compile-Time Advantage (Crisp's Superpower)
Because Crisp enforces rigid, static shapes and bounded loops without arbitrary pointer chasing, it can absolutely analyze these hazards statically before it ever emits a line of LLVM-IR or SPIR-V.
By tying your def-hardware-profile limits to a static analysis pass, Crisp can proactively block 3 of the 4 hazards we discussed:
Register Spilling (100% Detectable): Crisp knows the exact byte-width of type T, the shape of (128 128), and the pipeline-stages depth. The compiler can easily sum the total physical bytes of the live make-register-tile-ring buffers. If that sum exceeds the hardware profile's GRF ceiling (e.g., 256 registers on Battlemage), Crisp can throw a hard compilation error before the backend ever attempts to register-allocate.
Write-After-Write / Ring Collisions (100% Detectable): Because you explicitly define the software pipeline boundaries (ring-idx vs next-ring-idx), Crisp's data-flow analysis can verify the dependency graph. It can statically guarantee that a load-tile operation is never scheduled to target a ring buffer index that is currently locked by a live mma-accumulate-via-tile instruction.
L1 Cache Thrashing (Highly Detectable): Just like register counting, Crisp can calculate the spatial footprint of your prefetches. If you prefetch K+8 of a 128x128 TF32 tile, Crisp can calculate that you are requesting hundreds of kilobytes. If the hardware profile states the L1 cache is only 128KB, the compiler can emit a warning that your prefetch depth mathematically guarantees cache evictions.
The One Static Blindspot:
The only hazard Crisp cannot perfectly analyze statically is Load-to-Use Starvation (the math finishing faster than the load). You cannot perfectly predict runtime memory latency (LSC fabric congestion, global memory bandwidth contention) against DPAS math cycles without a cycle-accurate hardware simulator. However, Crisp could easily emit a heuristic warning if the pipeline depth is dangerously shallow (e.g., pipeline-stages = 1 for a global memory load).