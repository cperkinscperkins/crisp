We've been working our way through the MMA "Chapter" in .\docs\topology.md . Note in the last endeavor we had to pivot a bit to do the whole async tile loading NVidia only, and we'll come back around for Intel.  We updated topology.md with the updated APIs and description.

Now we are on to Chapter 2: pipelining the async loads via rings (make-async-barrier-ring and make-scratch-matrix-ring, and others).

This is covered in topology.md

For this endeavor we'll likely

[ ] write TDD tests and implement make-async-barrier-ring
[ ] write TDD tests and implement the make-scratch-XXXX-ring variants for the Storage Handles.
[ ] make a test that roughly matches the "Chapter 2" MMA code and make sure that it works.
[ ] add a benchmark.

Presumably we'll need an H100 or equivalent at some point. Let me know when. They are a lot more expensive to rent  than the consumer grade GPUs, so let's try to keep that time focused.

Also, just a minor thing, the run-on-pod.sh script runs fine, but it doesn't seem to present a summary of all the test results at the end anymore. It just outputs each test pass individually, which makes an early failure much harder to find. We should likely fix that too.

================================================================================
DEV PLAN (recorded 2026-07-15 — decisions + status; see also memory endeavor-138)
================================================================================

## Why this endeavor should pay

137 ended with `:block` TMA at 18.5x sync but **plateauing at 4096** (75 -> 80 TFLOPS) while
cuBLAS kept climbing (365 -> 436).  The cause is occupancy: `load -> await -> compute` is
strictly serial in one warp.  **Rings are exactly the fix** — overlap stage k+N's DMA with
stage k's compute.  This is where the naive-TMA ceiling should break, and the 137 sweep +
cuBLAS scoreboard (benchmarks/matmul/README.md) is already set up to show it.

## DECISION 1 — a ring IS a rank+1 scratch tensor  (agreed: "given the way GPUs work, it'd have to be B")

Rejected (a): N separate scratch allocations + a runtime pointer-select among N implicit args.
Chose (b): **ONE allocation of N x slot; `ring-get` is an offset view.**

The elegant part: (b) falls out for free, because a ring of N x (d0 d1) tiles *is* a rank-3
scratch tensor `(N d0 d1)` with **dim 0 = the ring slot**.  So:

    (make-scratch-matrix-ring float (64 8) :ring-count 3)  ==>  (make-scratch-tensor float 3 (3 64 8))

`make-scratch-{vector,matrix,tensor}-ring` are therefore just **macros** over
`make-scratch-tensor` — rings inherit the ENTIRE existing scratch path (allocation,
implicit-arg registration, size-expr, metacrisp, hoist), cost **ONE implicit arg regardless of
ring depth**, and keep the slots contiguous in SLM.  [DONE — validated: the compile error moved
from MAKE-SCRATCH-MATRIX-RING to RING-GET.]

`ring-get` cannot be a pure macro (it needs the ring's compile-time extents from a *runtime*
value), so it is an analyzer form like `load-tile`: resolve the ring's type -> slot rank ->
build a dim-0 slice view.  A **runtime** index is fine: the tensor struct's `offset~` is a
runtime field — `position-tile-at` already moves a window that way.

## DECISION 2 — `make-async-barrier-ring` takes `:mode`  (topology.md signature overlooked it)

...which exposes a real wrinkle: **a `:linear` ring means something different per backend.**

| backend / mode   | ring slots are...            | `await (ring-get r i)` lowers to            |
|------------------|------------------------------|---------------------------------------------|
| PTX `:block`     | N real SLM mbarriers         | try_wait.parity on slot i (137 machinery)   |
| SPV `:linear`    | N `target("spirv.Event")` slots | OpGroupWaitEvents on slot i              |
| PTX `:linear`    | **PHANTOM** (137: no object) | **`wait_group(ring-count - 1)`** — the ring depth IS the group count |

PTX `:linear` is the subtle one: per-slot `wait_group(0)` would wait for *everything* and
destroy the overlap the ring exists for.  The canonical cp.async pipelining idiom is
`commit_group` per stage + `wait_group(N-1)` (keep the N most recent groups in flight).

## DECISION 4 — `:arrivals` is EXPLICIT on a barrier ring  (agreed: "Definitely A. 100%")

**137's scan-inferred mbarrier arrival count does not survive rings.**  137 tallies the `:block`
loads naming a barrier, which is sound only because such a kernel has ONE stage in the text.  A
ring is loaded from the prologue *and* the main loop, so the textual tally (2 + 2 = 4) is **not**
the per-stage arrival count (2).  An mbarrier completes on (arrivals met) AND (tx bytes met), so a
wrong count is **too high → the kernel HANGS; too low → it reads a half-arrived tile**.  Grouping
loads "per phase" statically is fragile and fails *silently on silicon*, so we ask:

```
(make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2)   ; A+B share each slot
```

- **Required for `:mode :block`**; ~~ignored for `:linear`~~.  **REVISED 2026-07-16 (03b):** now
  **required for EVERY barrier ring, both modes** — `:linear` needs it too, as the loads-per-stage
  factor in `cp.async.wait_group((ring-count-1)*arrivals)` (each `:linear` load-tile commits one
  group).  Requiring it for both also keeps an arch-automatic ring kernel portable (same number
  whether the arch resolves to `:block` on sm_90 or `:linear` on sm_80).  A single
  `make-async-barrier` KEEPS its inference — no new surface where the old rule is still sound.
- Rejected alternatives: (B) init count 1 + first-load-arrives / rest bare `expect_tx` — still
  needs "which load is first in this stage", i.e. the same grouping problem; (C) keep the tally
  and forbid a prologue — rules out pipelining itself.
- Docs: topology.md "Rings"; the full rationale lives in `%check-barrier-ring-arrivals`.

**Bug this caught before it reached the H100:** await re-inits the mbarrier from the *await*
node's load-count, and that lookup required a symbol — so `(await (ring-get bars 0))` fell back to
**1** while creation used `:arrivals`.  Stage 2+ would re-arm expecting 1 arrival, receive N, and
complete on the first → torn tile.  Fixed with `barrier-load-count-of` (resolves symbol *or*
`(ring-get R i)` → ring; one table serves every consumer).
**Lesson:** `:arrivals 1` cannot prove the wiring — 1 is also the default.  Probe with 3.

## DECISION 3 — defer `:initial-state :signaled/:waiting` to Chapter 3

It only appears in the warp-specialization example (its sole consumer), and topology.md already
carries a "Q:" on it.  Out of scope for 138.

## NOTE — `do-times+` / `do-times` in topology.md's ring example DO NOT EXIST

Crisp has `dotimes`.  Per Chris: `dotimes+` is just `dotimes` plus a compile-time assertion
that the bound N is known at compile time — orthogonal, can land later.  And since `ring-get`
handles a runtime index anyway, plain `dotimes` serves BOTH the prologue and the main loop, so
138 does not need `do-times+` at all.

## TDD sequence — note ~80% needs NO H100

    [x] 01  make-scratch-*-ring + ring-get, COMPILE-TIME index (ring mechanics, no async)
            IR-verified the 3 slots are DISTINCT (bumps 0/16/32 bytes), not merely compiling.
    [x] 02  ring-get with a RUNTIME index (the `(mod (+ i 1) stages)` case)
            Needed NO new code — the offset-node path already carried it.  IR-verified genuinely
            runtime (zext -> mul -> GEP on an SSA operand, not constant-folded).
    [x] 03  make-async-barrier-ring + :mode + :arrivals, on `:block`
            PTX-verified: [2 x i64] mbarrier ring, per-slot init/expect_tx/try_wait/re-init.
            load-tile/await needed ZERO changes.  + errors/01 (missing :arrivals), errors/02 (0).
    [x] 03b  :linear rings — PTX DONE (wait_group((N-1)*arrivals)); SPV guarded (error, needs
            per-slot spirv.Event, deferred).  :arrivals now REQUIRED for all rings.  PTX metal
            still unverified (cheap sm_80+ pod, no H100).
    [~] 04  the Chapter-2 pipelined `:block` matmul (prologue + main loop)
            COMPILE + PTX-verified pod-free: [2 x i64] mbarrier ring, both init counts = 2
            (:arrivals, creation AND re-init), 6 cp.async.bulk.tensor, 2 .ptr .global descriptors.
            Hand-rolled tile-stride + (dotimes grid-k ...) (= what matrix-multiply-tile-stride
            lowers to) for the prologue slot the macro has no room for.  Metal (MMA_CORRECT) still
            NEEDS H100 — the phase-across-wrap correctness is the one thing PTX can't confirm.
    [ ] 05  benchmark vs 137's sync/:linear/:block + cuBLAS                  <-- NEEDS H100

## 04 build notes — the compiler wrinkles it surfaced (all pod-free, all fixed)

- **tile-stride binds TILE-IDs, not element origins.**  I briefly re-doubted this off
  `%expand-tile-stride-form`'s stale "origins" docstring; the delegate it calls
  (`%expand-workgroup-strided-outer-loop-with-ts-syms`) is truth ("bound to a tile-ID"), and
  137/05 is metal-proof.  topology.md's Chapter-2 example was CONCEPTUALLY right all along.
- **register C-tile → tile-spec must be the compile-time (M N) size-list**, not the C-tile symbol
  (register tiles SROA-explode).  `(tile-stride C (128 128) (grid-y grid-x) ...)`.
- **:ring-count needs an integer LITERAL** — a `(let ((stages 3)) … :ring-count stages)` binding
  does not compile.  Repeat the literal.  (topology.md's example was wrong on this; now fixed.)
- **ring-get's index was int-only** — `(* index slot-elems)` broke on a ulong index (tile-ID or
  `(mod grid-k n)`); 01/02 never hit it.  Fixed in structs.lisp: coerce both to ulong.
- **BUG: a uniform guard was rejected as thread-divergent** (control.lisp).  The if-analyzer
  computed `cond-uniformity` and trusted it for `*divergent-scope-depth*`, but set
  `*in-divergent-conditional*` to T *unconditionally* — so load-tile's internal sync-workgroup was
  flagged even under a uniform guard, and the error's own "use a non-divergent condition" advice
  was unachievable.  Fixed to honor the uniformity.  A dotimes counter still reads :unknown, so
  the kernel asserts the guard with `to-workgroup-uniform` (must be a let initializer).
- **topology.md's sync was on the wrong side** — it prefetched then synced, racing the overwrite
  against the reads of the slot the ring wraps onto.  04 (and the corrected doc) sync BEFORE the
  prefetch.

Only 04/05 need Hopper.  Build 01-03 pod-free, then ONE focused H100 session for correctness
+ benchmark.  (137 metal workflow: crisp-compile --ir-target=ptx --ir-target-arch=sm_90
--hoist=cuda -> crisp-hoist-cuda --mma-bench=M,N,K --grid-tile=64 -> nvcc -arch=sm_90a -lcuda.)

## Carry-overs from 137 that need care (the real risk — not the allocation)

1. ~~**mbarrier init count.**~~  RESOLVED — and it turned out to be deeper than "count per ring":
   no textual tally is correct through a ring at all.  See DECISION 4 (`:arrivals`).
2. **Phase.**  137's "await re-inits the mbarrier" should carry over (each slot is awaited
   before its next load), BUT the prologue puts `ring-count` transfers in flight
   simultaneously — that overlap needs verifying, not assuming.

## Also done

  [x] run-on-pod.sh summary.  Root cause: the stream filter grepped `Failed:`, but the runner
      emits `Failed Specs:` (space before the colon) + `  - <name>` lines — neither matched, so
      the failure LIST was silently dropped.  Now: per-phase verdict + named failures, one
      aggregate RUN SUMMARY at the bottom, and a non-zero exit on failure (usable as a gate).

