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
[ ] Need to document in topology.md the final `prefetch-tile` and `make-register-tile-ring`.  Further, if we adjust `load-tile` we should document that too.




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


TDD Plan (phases -> spec files)
===============================

All specs live in `tests/spec/142-mma-prefetch/` (ci-stop advances here as each goes green; today
ci-stop = 140-wgmma).  Target is Intel/SPV: compile tests use `--ir-target=spv`; metal tests use
`TEST-HOIST[L0]: validate-l0-mma-run` + `HOIST-EXPECT: MMA_CORRECT` on BMG (auto-skips on non-Intel
HW via the L0 skip-gate).  Every Intel-prefetch form REQUIRES a hardware profile
(`--hardware-profile=bmg` / `HOIST-HARDWARE-PROFILE: bmg`); compiling one without a profile is a hard
error.  PTX target -> hard error for `prefetch-tile` and register-`load-tile`.  (`bmg` is currently
`def-hardware-profile`'d inline in each spec, as the 133/134 specs do; a real built-in `bmg` is a
nice-to-have we can add.)

DESIGN INVARIANTS to keep now so Phase C's static analysis isn't fought later:
 - `make-register-tile-ring` records `(shape, ring-count, dtype)` as compile-time metadata (a registry,
   like `*register-tile-dims*` / `*wgmma-acc-dims*`).  -> feeds the spill / L1 / shallow checks.
 - lowering PRESERVES per-op `(ring, index-expr)` structure through to codegen — never flatten
   `ring-get` to an opaque register/pointer before a data-flow pass could read it.  -> feeds the WAW check.
 - hardware profile is required, so the analysis always has its GRF/L1 limits.

--- Phase A — block-load into registers + register-MMA (no ring, no prefetch) ---
The minimal new capability: `load-tile` overloaded on a register-tile dest -> Subgroup2DBlockLoadINTEL
(global->GRF, hardware-async, no :barrier), then mma reads that register-tile.  No ring yet (that's the
double-buffer, Phase B).  Groundwork: add `:l1-cache-size` to the def-hardware-profile schema + `bmg`
(GRF ceiling already exists as `:max-registers-per-thread`; decide the tile-bytes->registers conversion).
 00-block-load-compile.crisp         load-tile A -> a make-register-tile -> Subgroup2DBlockLoadINTEL appears
     in the SPV IR (overload dispatch on dest-type + SPV).  IR-grep validator, compile-only.
     COMPILE-WITH[--hardware-profile=bmg --ir-target=spv]: PASS, SKIP-DEFAULT-PASS, SKIP-WITH[--differentiate]/[--debug].
 01-register-mma-metal.crisp         load A,B (one K-block) into register-tiles -> mma-accumulate -> store C.
     MMA-DIMS / HOIST-HARDWARE-PROFILE: bmg / TEST-HOIST[L0] / HOIST-EXPECT: MMA_CORRECT.  (Phase A capstone.)
 errors/01-no-hardware-profile.crisp register-load-tile without --hardware-profile -> compile error.
 errors/02-register-load-on-ptx.crisp load-tile into a register-tile with --ir-target=ptx -> compile error.

--- Phase B — rings + prefetch + pipeline ---
 10-register-tile-ring-forms.crisp   make-register-tile-ring + ring-get parse; ring (shape,count,dtype)
     metadata registered; ring-tiles feed load-tile + mma.  compile-only.
 11-prefetch-tile-compile.crisp      prefetch-tile (no dest) -> Subgroup2DBlockPrefetchINTEL in the SPV IR.
 12-prefetch-pipeline-metal.crisp    the full intel-prefetch-matrix-multiply (prologue + K-loop + epilogue);
     TEST-HOIST[L0] / HOIST-EXPECT: MMA_CORRECT.  + wire into the benchmark suite (Intel chapter) vs Phase A.
 errors/03-prefetch-on-ptx.crisp     prefetch-tile with --ir-target=ptx -> compile error.

--- Phase C — static safety net (the "Crisp superpower") ---
 errors/04-register-spill.crisp      ring config whose live GRF bytes exceed bmg's ceiling -> hard error.
 errors/05-ring-collision.crisp      load-tile targets a ring index still live in an mma read -> WAW error.
 12-l1-thrash-warning.crisp          over-eager prefetch (K+8) beyond bmg L1 -> EXPECT-STDERR warning.
 13-shallow-pipeline-warning.crisp   pipeline-stages=1 for a global load -> EXPECT-STDERR warning.
 (+ positive counterparts: a valid config compiles clean, no warning.)
 DECIDE before Phase B: user-managed ring-idx (example; needs the WAW *verify*) vs compiler-managed
 rotation (WAW impossible by construction).  Groundwork supports both.

--- Phase D — 2D block store + docs ---
 20-block-store-metal.crisp          store-tile register-tile -> global via Subgroup2DBlockStoreINTEL;
     MMA_CORRECT with the block-store epilogue; update 11 to use it.
 + topology.md: document prefetch-tile / make-register-tile-ring / the load-tile register overload.


IMPLEMENTATION NOTES — Phase A (discovered 2026-07-23/24)
=========================================================
KEY: register-tiles are NOT analyzed as a whole var — a pre-pass, `%explode-rewrite-body-form`
(src/mma.lisp), SROA-explodes each into fragment vars (V$Fi) and rewrites the forms that use it.
It had clauses for MMA-ACCUMULATE-VIA-TILE / STORE-TILE / FILL-TILE but NOT LOAD-TILE — so
load-tile into a register-tile fell through to the whole-tile var -> "Unknown variable A-TILE".
The overload therefore lives HERE, not in the load-tile analyzer.

DONE + verified locally:
 - Added a LOAD-TILE clause to %explode-rewrite-body-form (mirrors store-tile: DEST = third form,
   `(assoc (third form) tiles)`).  Front-end guards fire there: no --hardware-profile -> error;
   non-SPV target -> "Intel/SPV-only" error.  -> tests 02, 03 GREEN; 00 reaches the codegen stub;
   133/11 (register matmul) unregressed.  `%emit-per-frag-block-load` is the stub.

REMAINING (metal-bound — needs a BMG pod to verify MMA_CORRECT):
 1. make-register-tile[-ring] `:operand` (a|b|acc, default acc) -> coop-matrix Use (0/1/2).  Today
    the register-tile is Accumulator-only: `%ensure-register-tile-type` mints
    register-tile-acc-f32-MxN of register-fragment-acc-f32-16x8 (Use 2), and make-register-fragment
    (src/mma.lisp:82) hardcodes Use 2 / shape from %spv-mma-shape.  A/B operands need A/B fragment
    TYPES (Use 0 -> M×K, Use 1 -> K×N) + operand stored in the tile metadata (extend *register-tile-dims*).
 2. `%emit-per-frag-block-load`: per-fragment Subgroup2DBlockLoadINTEL global->GRF, using the tile's
    Use/layout.  (Phase-A shortcut option: reuse per-fragment CooperativeMatrixLoadKHR (load-fragment-a/b)
    for a first metal-correct baseline, then swap to the 2D block load in Phase B for prefetchability.)
 3. mma-accumulate-via-tile reading register-tile operands (pre-loaded) instead of global A/B — today
    11-matmul-bmg hands the mma GLOBAL matrices; the register-resident-operand path is new.
 Then 01-register-mma-metal -> HOIST-EXPECT: MMA_CORRECT on BMG.

METAL LOOP (confirmed working locally on this Windows+BMG machine, 2026-07-24):
  crisp-compile --hoist=l0 --hardware-profile=bmg --ir-target=spv <k>   # -> <k>_<kernel>.metacrisp + _L0.cpp
  crisp-hoist-l0 --mma-test=M,N,K <metacrisp>                           # regen .cpp as C=A.B harness
  clang++ <cpp> -I C:/Users/cperk/Documents/level-zero/include C:/Windows/System32/ze_loader.dll -static -o e.exe
  ./e.exe | grep MMA_CORRECT                                            # 133/11 -> MMA_CORRECT
(clang++ = C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe)

PROGRESS (2026-07-24):
  [DONE] make-register-fragment gains :operand (a|b|acc, default acc) -> coop-matrix Use 0/1/2 + shape
         (A sm×sk / B sk×sn / Acc sm×sn, matching load-fragment-a/b).  :acc default metal-confirmed
         unchanged (133/11 MMA_CORRECT).
  [DONE] operand-aware register-tile tiling.  %frag-mn-for-operand returns per-operand frag dims
         (:a sm×sk / :b sk×sn / :acc sm×sn on :spirv; 16×8 elsewhere).  %explode-register-tiles reads
         (getf ... :operand :acc), sizes nfrags via %frag-mn-for-operand, carries operand as the 7th
         element of each tiles entry, and threads it to make-register-fragment.  %emit-per-frag-store /
         -fill accept + ignore the operand field (was the destructuring-bind arg-count break).
  [DONE] %emit-per-frag-block-load (real): per fragment -> (set! Tile$Fk (load-fragment-a/b SRC (coords)))
         with operand-selected frag-fn and (n-rows n-cols) tiling from %frag-mn-for-operand.  Reuses
         CooperativeMatrixLoad for the first MMA_CORRECT; swaps to Subgroup2DBlockLoad in Phase B.
  [DONE] %emit-per-frag-accumulate register-operand variant: takes the tiles list; when a/b are
         register-tiles it reads the pre-loaded fragment vars directly (nth into the tile's syms)
         instead of (load-fragment-a/b ...).  Guards n-true>1 register operands with an error.
  [DONE] load-tile OVERLOAD in the explosion pass (%explode-rewrite-body-form LOAD-TILE clause): dest is a
         register-tile -> %emit-per-frag-block-load; errors without an active hardware profile; errors on
         non-:spirv backends ("Intel/SPV-only").  02 (no-profile) + 03 (ptx) fail correctly.
  [GREEN] 01-register-mma-metal -> MMA_CORRECT on local BMG (C = A.B host-reference verified).  All 4
         Phase A specs pass (00 compile, 01 metal, 02 FAIL profile, 03 FAIL Intel).  133/11 unregressed.
  ==> Phase A COMPLETE.  Next: Phase B — make-register-tile-ring, prefetch-tile (Subgroup2DBlockPrefetch),
      the pipelined loop, and swap CooperativeMatrixLoad -> Subgroup2DBlockLoad for the real async path.

PHASE B PROGRESS (2026-07-24):
  RING DESIGN DECISION (Chris): (a) USER-managed ring index — ring-get takes an explicit index, lowering
    PRESERVES (ring, index-expr) structure so Phase C can VERIFY the WAW hazard.  (b) compiler-managed
    rotation is a possible FUTURE endeavor (Chris will revisit the macros) but may be overfitted; (a)
    gives the freedom some users need, and keeps the WAW hazard expressible (the Phase-C "superpower").
  DE-RISK (empirical): local llvm-spirv (LLVM 22) SUPPORTS --spirv-ext=+SPV_INTEL_2d_block_io (bogus ext
    -> "Unknown extension"; the real one passes).  Probed the exact ABI through llvm-as -> llvm-spirv
    --to-text -> confirmed OpSubgroup2DBlockPrefetchINTEL + Capability Subgroup2DBlockIOINTEL emitted from:
      void __spirv_Subgroup2DBlockPrefetchINTEL(i32 ElementSize, i32 BlockWidth, i32 BlockHeight,
        i32 BlockCount, ptr addrspace(1) SrcBase, i32 MemWidth, i32 MemHeight, i32 MemPitch, <2 x i32> Coord)
      spir_func, UNMANGLED __spirv_ name (same convention as the coop-matrix calls).  This ABI convention
      carries all three 2d_block_io ops (prefetch / load / store) — foundational for the rest of Phase B.
  [DONE] prefetch-tile.  (prefetch-tile SRC (COORD-Y COORD-X) :size (H W)) -> Subgroup2DBlockPrefetchINTEL.
    Reuses the coop-op node with a NEW :prefetch kind (no new semantic node -> no etypecase churn): void
    statement, reads no matrix / writes no reg, warms L1 for the H×W block at origin (ty*H, tx*W).
    - src/mma.lisp: analyze-prefetch-tile (guards: active-hardware-profile required, *target-backend*
      :spirv only) + registered "PREFETCH-TILE" in register-mma-analyzers.
    - src/codegen.lisp: %block-prefetch helper (the intrinsic call) + :prefetch branch in the coop-op
      generate-node-ir ecase (mirrors :store: ptr+stride from %coop-tensor-ptr+stride, then emit).
    - src/compiler.lisp: %module-uses-2d-block-io-p predicate + adds --spirv-ext=+SPV_INTEL_2d_block_io
      to the llvm-spirv flags only when a Subgroup2DBlock* call is present.
    Specs 11-prefetch-tile-compile (COMPILE-WITH bmg+spv PASS) + 13-prefetch-on-ptx (FAIL "Intel").  6/6
    in-dir.  MANUALLY verified: 2 Subgroup2DBlockPrefetchINTEL opcodes (A+B) + capability + extension in
    the .spt.  01 still MMA_CORRECT.  TODO(green): validate-spv-prefetch IR-grep to guard against silent
    drop (COMPILE-WITH PASS proves it translates, not that it's present — manual grep covers it for now).
  [DONE] 10-register-tile-ring-forms: make-register-tile-ring + ring-get for REGISTER tiles.  A register
    ring = :ring-count INDEPENDENT slot-sets of SROA-exploded fragment vars (<ring>$S<slot>$F<i>) — the
    GRF is NOT runtime-indexable (unlike the SLM scratch ring in topology.md ~L950 whose ring-get is a
    base+i*stride view).  So ring-get into a register ring REQUIRES a compile-time integer slot.
    - src/mma.lisp: %register-tile-ring-init-form-p recognizer; %resolve-tile-ref (resolves a bare tile
      symbol OR (ring-get RING const-slot) to a per-slot entry, ERRORS on a non-constant register slot /
      out-of-range / bare-ring-ref); %explode-register-tiles explodes the ring binding into rc slot-sets +
      records a :ring tiles entry (RSYM :ring m n (slot0-syms slot1-syms ...) operand) = the compile-time
      metadata Phase C reads; the LOAD-TILE explosion clause + %emit-per-frag-accumulate a/b operands now
      go through %resolve-tile-ref, so a ring slot feeds both load-tile and mma.
    Spec 10-register-tile-ring-forms (COMPILE-WITH bmg+spv PASS, ring-count=2 ping-pong, slots 0+1 loaded
    + accumulated).  7/7 in-dir.  MANUALLY verified in the .spt: 6 CooperativeMatrixLoad (both slots' A+B
    frags = distinct storage) + 4 MulAdd (2 mma x 2 C-frags).  133/11 + 142/01 unregressed.
  [NEXT] swap the Phase-A CooperativeMatrixLoad shortcut in %emit-per-frag-block-load -> real
    Subgroup2DBlockLoadINTEL (so the prefetched L1 data is what the load consumes).
  [NEXT] 12-prefetch-pipeline-metal: prologue + K-loop (STATIC slots via unroll/phase, no set!) +
    epilogue -> MMA_CORRECT + bench.  The runtime-slot-into-static-GRF puzzle lives here.