In this next endeavor we tackle warp specialization, especially as applied to MMA on NVidia.

This is described as "Chapter 3" and is documented in .\docs\topology.md

[ ] TDD tests for general-case warp specialization - for testing on both Intel and NVidia.
[ ] implement general case warp specialization
[ ] TDD test (NVidida only): MMA optimized via warp specialized pipelining
[ ] Implement so the test passes.
[ ] Test on H100.
[ ] Benchmark.
[ ] Cry when performance is not meeting expectataion.

================================================================================
DEV PLAN (recorded 2026-07-17 — decisions + sequence; see also docs/topology.md)
================================================================================

## Why this endeavor (and the honest expectation)

138 ended with the ring pipeline at a **register/occupancy wall**: one warp per workgroup,
254 registers/thread -> ~12.5% occupancy, so pipelining (a latency-hiding lever) crossed over
to NEGATIVE at 4096.  Warp specialization is TWO levers at once:
  1. **Latency hiding** — a dedicated PRODUCER warp runs ahead keeping the ring full while the
     CONSUMER warps do nothing but MMA (never stall on memory).  This is the classic win.
  2. **Occupancy** — the C-tile is split across N consumer warps, so each warp holds 1/N the
     fragments = 1/N the registers => higher occupancy.  THIS is what actually attacks the 138
     wall, and it rides on decision A below.
Honest note: lever 1 alone may not beat the 138 ring (138 showed pipelining is only ~10% and it's
latency-bound only <=2048).  The payoff hinges on lever 2 — hence "cry" is a real possibility if we
build the handshake but skip the tile split.

## What exists vs. what's net-new

EXISTS (from 111/115): warp-id, warp-lane, warp-count, get-warp-size builtins.
NET-NEW (nothing implemented):
  1. `with-warp-specialization` — the warp-role split (analyzer + codegen).
  2. `signal` — the manual barrier arrive (consumer -> empty ring).  In the API since 137, never built.
  3. `:initial-state :signaled/:waiting` on make-async-barrier-ring — deferred from 138 TO here.

## DECISION A (agreed 2026-07-17) — register-tile warp participation is EXPLICIT

Under warp-spec only the CONSUMER warps run the MMA, so a C-tile fragment placed on the producer
warp would never be computed -> WRONG RESULT.  So make-register-tile must know which warps hold it.
We do NOT infer it from the enclosing warp-spec block (fragile coupling, and the tile is declared in
the outer let anyway).  Instead an EXPLICIT flat boolean **topology mask** (same philosophy as 138's
:arrivals — when inference is fragile, the user states it):

    (make-register-tile float (64 64) 0.0 :warps '(false true true))

- Mask is positional over the workgroup's warp layout; `true`/`false` (parser also accepts `1`/`0`).
- Default (omit :warps) = all-true = today's behavior (backward compatible).
- **Length** must equal `local-size / warp-size` — COMPILE-TIME error when local-size is static;
  else an --runtime-checks r-t-assert.  We check LENGTH (mechanical), not role-alignment (user's job).
- **Even-only**: an (M N K) fragment is M×N computed by one whole warp, so a tile is
  (tileM/fragM)x(tileN/fragN) fragments (64x64 @ (16 8 8) = 4x8 = 32).  #true warps MUST evenly
  divide the fragment count, or compile error.  => consumers in {1,2,4,8,16,32} for a 32-frag tile,
  NOT 3.  (topology.md example corrected to :consumer 2.)  No plan to relax to uneven.
- **Occupancy knob**: more consumer warps = fewer frags/warp = fewer regs/thread = higher occupancy
  = the actual lever vs the 138 wall.  BENCHMARK sweeps consumer count.
Surface: make-register-tile `:warps`, mask on tile metadata, threaded into mma-accumulate-via-tile's
fragment distribution (each true warp computes "I am the k-th true warp" via popcount), + length check.

## DECISION B (agreed) — NVIDIA warp-spec is :block-only

sync-workgroup inside a role block DEADLOCKS (only some warps reach it) — incl. load-tile's INTERNAL
workgroup sync.  On :block/TMA the load is leader-issued + mbarrier-tracked (no workgroup sync) — the
natural fit.  :linear/cp.async's cooperative copy is a workgroup collective and does NOT fit.  So the
divergence checker (120) needs a new "warp-spec scope" that FORBIDS workgroup collectives inside role
blocks; NVIDIA warp-spec matmul is :block-only.

## DECISION C (agreed) — workgroup-size check
with-warp-specialization requires local-size == (sum of role counts) * warp-size.  Compile-time when
local-size is static; else --runtime-checks.

## Backend note
General-case warp-spec (the role branch itself) is backend-agnostic (Intel + NVidia) — it's just a
warp-id-gated branch.  The MMA-optimized producer/consumer pipeline is NVIDIA-only (:block/TMA + the
handshake).  Intel's fast path is a different animal (LSC 2D block loads, no SLM/barrier) — out of scope.

## TDD sequence

    [x] 01  with-warp-specialization SKELETON — DONE 2026-07-17.  The warp-role branch, NO
            barriers.  Analyzer form (analyze-with-warp-specialization-expression, control.lisp)
            lowering to a warp-id-gated nested if with the LAST role as the else (all branches are
            void role bodies -> types match; a numeric fall-through would clash).  01-warp-spec-roles
            green on ptx (validate-warp-roles: both markers present) + spv (compile).  905/905.
            PTX folds it to `setp.lt.u32 %p1, linear_tid, 32` + selp — branch on warp 0, stable.
      >>> FIX (real latent bug): warp-id lowered to %warpid, the VOLATILE physical-SM warp register
          ("may change during execution ... should not be used for work scheduling" — PTX ISA).
          Warp specialization IS work scheduling.  Fixed warp-id PTX codegen to synthesize
          local-linear-id/32 (stable, = SPV SubgroupId): %ptx-synthesize-warp-id (codegen.lisp).
          Only 110/05 used warp-id (SPV-only compile check) — not regressed.
      >>> GOTCHA: on Windows the incremental build can keep a STALE fasl (same-second mtime) — a
          control.lisp/codegen.lisp edit silently didn't recompile until I rm'd the cached fasl
          under AppData/.../cache/common-lisp/.../src/.  When an edit "doesn't take", clear the fasl.
    [x] 01b (metal, dev BMG / L0) — DONE 2026-07-17.  Each thread writes its role marker to
            C[warp-id]: producer warp -> C[0]=40001, consumer -> C[1]=40002.  On BMG (subgroup 32
            for this kernel) got `BUFFER c: 40001 40002 2 3` (C[2],C[3] = harness init) -> the
            split is REAL on metal, and the stable-warp-id fix works on hardware.  HOIST-EXPECT
            `BUFFER c: 40001 40002`.  (buffer prints LOWERCASE param name; hoist L0 vector buffer
            is a fixed 4 elems, so index by warp-id, not thread-id.)  2/2.
    [~] 02  :initial-state + signal + the empty/full ring pair — a SIMPLE data hand-off (producer
            load-tiles a slot to SLM, consumer reads it to output).  "Hello producer/consumer", NO
            MMA.  Red test 02-producer-consumer written (pins the API; currently red at :initial-state).
            Modeled on CUTLASS (agreed): `full` = TRANSACTION mbarrier (TMA expect_tx arrives it),
            `empty` = ARRIVAL mbarrier (consumer signal arrives it), per-slot phase.  Metal = H100
            (:block/TMA needs sm_90); build + IR-verify pod-free first.
        [x] 2a divergence scope (decision B) DONE 2026-07-18 — *in-warp-spec-block* dynamic var,
            bound around the role-block analysis in analyze-with-warp-specialization;
            %tlc-check-not-divergent relaxes when set (a :block load is leader-issued, warp-safe).
            :block load-tile inside a role block now compiles.  No regression (906/906 + 201 neg;
            normal divergence rejections intact).  STILL TODO: forbid sync-workgroup + :linear loads
            in a role block (deadlock), and enforce :block-only.
        [x] 2b :initial-state + signal — DONE 2026-07-18.  :initial-state -> initial await parity
            (:waiting 0 / :signaled 1), stored on the ring + *async-barrier-initial-phase* table;
            barrier-initial-phase-of resolver.  signal = leader-guarded (lane 0) mbarrier.arrive
            (semantic-signal node + codegen).  New-node gotcha: added semantic-signal to the 2 core
            etypecases (type + source-location).
        [x] 2c phase-tracked await — DONE 2026-07-18.  semantic-nvvm-tma-wait got a `phase` field:
            NIL = 138 (try_wait.parity(0) + workgroup sync + re-init); integer = WARP-SPEC
            (try_wait.parity(phase), NO sync, NO re-init).  02 GREEN.  PTX verified: empty await
            parity 1, full await parity 0, signal = mbarrier.arrive on empty, 4 inits up front, no
            re-init.  907/907 + 201 neg; 137/138 (shared await path) unregressed.  Metal (H100)
            deferred with 4/5.  (Phase is the constant initial phase for single-step; multi-lap
            flipping is step 4.)
    [~] 03  make-register-tile :warps — decision A.
        [x] 3.1 parsing + validation + #true=1 (works: single participating warp needs no split).
                Tests 03-register-tile-warps + errors/04 (bad length), 05 (all-false).  910/910.
        [x] 3.2 the #true>=2 DISTRIBUTION DONE 2026-07-18 — net-new multi-warp fragment split.  All in
                the source-to-source explosion (%explode-register-tiles): parse :warps, size nfrags/
                #true fragments per warp, entry carries n-true/first-true; %emit-frag-loop-distributed
                computes each warp's logical fragment range (wp=warp-id-first_true; logical=wp*per-warp
                +l -> mi/nj).  IR-verified: a 32x16 #true=2 tile emits 2 mma.sync per warp (not 4).
                Test 04-register-tile-distributed (validate-ptx-distributed-mma).  913/913, 139 10/10.
                Contiguous true warps only; metal correctness = step 4.
    [x] 04  the full warp-spec MMA matmul (NVIDIA :block) — DONE 2026-07-18, METAL-CORRECT H100.
            Net-new = MULTI-LAP PHASE FLIPPING: a warp-spec ring slot is reused every ring-count
            K-steps and try_wait.parity flips each lap, but 138's re-init trick is impossible
            (producer/consumer are separate warps).  Compiler injects a per-ring VISIT COUNTER
            (entry-block i32 alloca, ++ per await) and derives parity = init XOR ((visit/ring-count)
            & 1).  Round-robin slot access makes it exact; degrades to the constant initial phase at
            visit 0 (so 139/02 single-step unchanged).  All overlay (no struct patch): phase field
            now carries (init ring-count) instead of a bare int; codegen reads the list.  Added 2
            LLVM bindings (LLVMGetEntryBasicBlock, LLVMPositionBuilderBefore) — NOT exported (that
            triggers a package-variance fatal in package.lisp; use ::-qualified).  ptxas folds the
            parity to `bfe.u32 bit1(visit)` (consumer, init 0) / `not; bfe` (producer, init 1).
            Tests: 05-warp-spec-matmul (1P+1C, MMA_CORRECT H100), 06-warp-spec-distributed
            (1P+2C split C-tile, MMA_CORRECT H100).  915/915 + 916/916 diff + 206 neg.
    [x] 05  benchmark DONE 2026-07-18 (H100).  Swept ws1/ws2/ws4 consumers vs pipe(138)/block(137)/
            cuBLAS at 1024/2048/4096.  **THE CHAPTER-2 PREDICTION WAS WRONG.**  Splitting a FIXED
            64x64 tile across consumers cuts regs/thread (250->167->128) BUT backfires: ws2/ws4 run
            at HALF of pipe (29K vs 78K @4096).  Each CTA still computes one 64x64 tile spread over
            more warps + an idle producer that reserves max regs -> per-CTA register footprint RISES
            -> fewer output-tiles-per-SM (8->4->3).  The one real win: ws1's dedicated-producer
            LATENCY HIDING = +53% @1024 (48K vs 31K), fading to break-even by 4096.  Full table +
            analysis in benchmarks/matmul/README.md (Chapter 3).  Next lever = BIGGER tiles per CTA
            (128x128 over 4 consumers, ~32 frags each = pipe's reg sweet spot, 4x output/CTA, higher
            arithmetic intensity) + register reallocation (setmaxnreg) — Chapter 4, not this sweep.

Only 04/05 need Hopper.  01-03 are pod-free (compile/IR + dev-BMG metal).

## Open design threads (to pin as we go)
- Step 2: exact mbarrier semantics of :initial-state (:signaled = start arrived so producer's first
  N awaits pass; :waiting = start un-arrived so consumer blocks).  And `signal` = a manual
  mbarrier.arrive on the empty ring's slot.
- The role branch + divergence checker: role blocks are warp-UNIFORM but workgroup-DIVERGENT; needs
  a scope kind that permits per-warp control flow but forbids workgroup collectives.
