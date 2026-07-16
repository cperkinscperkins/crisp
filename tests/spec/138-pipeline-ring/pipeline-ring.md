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
    [ ] 02  ring-get with a RUNTIME index (the `(mod (+ i 1) stages)` case)
    [ ] 03  make-async-barrier-ring + :mode, + a `:linear` load into a ring slot
            (`:linear` runs on ANY arch -> testable locally / BMG, NO Hopper)
    [ ] 04  the Chapter-2 pipelined `:block` matmul (prologue + main loop)   <-- NEEDS H100
    [ ] 05  benchmark vs 137's sync/:linear/:block + cuBLAS                  <-- NEEDS H100

Only 04/05 need Hopper.  Build 01-03 pod-free, then ONE focused H100 session for correctness
+ benchmark.  (137 metal workflow: crisp-compile --ir-target=ptx --ir-target-arch=sm_90
--hoist=cuda -> crisp-hoist-cuda --mma-bench=M,N,K --grid-tile=64 -> nvcc -arch=sm_90a -lcuda.)

## Carry-overs from 137 that need care (the real risk — not the allocation)

1. **mbarrier init count.**  137 counts `:block` loads per barrier *binding symbol*; but
   `(ring-get bar-ring i)` is NOT a symbol.  Needs counting per *ring* instead (every slot
   serves the same A+B loads per stage, so one count covers all slots).
2. **Phase.**  137's "await re-inits the mbarrier" should carry over (each slot is awaited
   before its next load), BUT the prologue puts `ring-count` transfers in flight
   simultaneously — that overlap needs verifying, not assuming.

## Also done

  [x] run-on-pod.sh summary.  Root cause: the stream filter grepped `Failed:`, but the runner
      emits `Failed Specs:` (space before the colon) + `  - <name>` lines — neither matched, so
      the failure LIST was silently dropped.  Now: per-phase verdict + named failures, one
      aggregate RUN SUMMARY at the bottom, and a non-zero exit on failure (usable as a gate).

