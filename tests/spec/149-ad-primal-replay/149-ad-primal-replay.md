Endeavor 149 — AD Primal Replay
================================

STATUS: DONE, 2026-08-13.  All seven rungs pass, five of them on a NUMBER from BMG rather than a
clean compile:

    01 hand-staged        A: 1.5 vs 1.5   B: 2.0 vs 2.0    diff=0.0
    02 non-invertible     A: 1.5 vs 1.5   B: 2.0 vs 2.0    diff=0.0
    04 computed fill      A: 6.0 vs 6.0   B: 4.0 vs 4.0    diff=0.0
    05 loop-carried       A: 5.5 vs 5.5   B: 6.0 vs 6.0    diff=0.0
    06 cross-subgroup     A: 1.5 vs 1.5   B: 2.0 vs 2.0    diff=0.0
    03, 07                refuse, each naming what made replay unsafe

Suite: 981/981 plain, 981/981 under --differentiate, 211/211 negative, 291/291 unit.  Bug 037 is
CLOSED.  The mechanism lives in overlays/crisp-compiler-overlay.lisp pending a fold into
src/autodiff.lisp; the overlay carries a note saying exactly where its one wrapper belongs.

WHAT THIS DID NOT FIX: 140/01 and 140/02, the kernels that motivated the endeavour, still do not
differentiate — but no longer for this reason.  Their own skip notes named TWO blockers, "needs
PRIMAL REPLAY ... AND address it through the instruction's ABI layout".  Replay is done; the
second half is not.  They now fail with the wgmma VJP's own complaint, that a flat
`(make-scratch-vector float 512)` has no compile-time (Mt Kt) for the backward to interpret the
core-matrix layout with.  That is a separate piece of work and wants its own endeavour.

The prose below was written at the close of 146 so the reasoning would not be lost.  It has been
amended in two places by what the opening spike measured; see "What the spike established".


The sentence the whole endeavour turns on
------------------------------------------

It is already in the source, in three places including BUG 037's header:

> **A backward kernel replays the forward's BINDINGS but not its STATEMENTS — the staged
> tiles are empty.**

The backward is a SEPARATE kernel.  It re-declares the forward's `let` bindings, so `A-tile`
exists as an allocation — but it never re-runs the `set!`s that filled it.  So inside the
backward, `A-tile` is allocated and EMPTY.

That matters because the chain rule needs PRIMAL values:

    dA = dC.B^T      <- needs B's actual numbers
    dB = A^T.dC      <- needs A's actual numbers


How the engine copes today
---------------------------

The VJP sidesteps the empty tile by reading the GLOBAL SOURCE instead.  It can do that only
because `load-tile-at` RECORDS where the tile came from — "this tile is A at origin (y,x)" —
a mapping `*ad-tile-src-map*` keeps and the compiler can invert.

That is why the well-covered path insists on `load-tile-at` staging, and why 142/01, 145/12,
145/18 and friends all produce correct numbers.

When the mapping is absent, the engine REFUSES rather than guessing
(`%vjp-check-staged-tile-primals`, src/autodiff.lisp):

    cannot differentiate: the backward needs the PRIMAL value of <TILE>, a scratch tile that
    is not filled by load-tile-at, so its contents cannot be recovered (a backward kernel
    replays the forward's bindings but not its statements).

That refusal is CORRECT and should be preserved until replay exists — a silent zero here
would be far worse.  It is the "before" state these TDD specs are written against.


Where it bites: 140/01 and 140/02
----------------------------------

They stage by hand, in wgmma's swizzled core-matrix order:

    (let ((core (+ (+ (+ (* (/ r 8) 64) (* (/ k 4) 32)) (* (rem r 8) 4)) (rem k 4))))
      (set! (~ A-tile core) (~ A r k)))

Now the VJP has NEITHER route:

  - it cannot read `A-tile` — empty in the backward
  - it cannot recover a source mapping — that is arbitrary user index arithmetic, and the
    compiler cannot invert a swizzle it did not author

NOTE these two are DOUBLY gated: they are sm_90a, so even with replay working their gradient
VALUES need endeavour 147's CUDA runtime for VERIFY-AUTODIFF.  The specs below are
deliberately BMG-shaped so the capability can be proven on hardware we own, independently.


What "primal replay" means
---------------------------

Re-run the forward's staging STATEMENTS at the top of the backward, so the tiles hold their
primal values again.  The VJP then reads the tile directly and inverts nothing.

In standard AD vocabulary this is RECOMPUTATION — the classic alternative to saving values.


The design fork — this is why it is an endeavour and not a patch
-----------------------------------------------------------------

1. **WHICH statements?**  Only those feeding a tile that some VJP actually consumes.  That
   needs a dependency analysis, not a blanket re-run.  `%vjp-check-staged-tile-primals`
   already computes something close: it tests whether the backward body MENTIONS the tile.

2. **ONLY PURE STAGING IS SAFE TO REPLAY.**  Re-running a statement that also writes GLOBAL
   memory would corrupt results — the forward's effect would happen twice.  The analysis must
   distinguish "fills a local tile" from "has an observable effect", and REFUSE (loudly) when
   it cannot.  Spec 03 below encodes that constraint.

3. **RECOMPUTE vs SAVE is a genuine tradeoff.**  Replay costs time; the alternative — stash
   the staged tiles in the forward and read them back — costs memory.  Neither is obviously
   right, and the choice may want to be per-kernel.  Worth deciding deliberately rather than
   defaulting.

4. **BARRIERS.**  Replayed staging needs its synchronisation replayed coherently: a
   `sync-workgroup` between the fill and the read exists for a reason and cannot simply be
   dropped from the replayed copy.

5. **Interaction with the ANF hoist.**  146 learned repeatedly that ANF moves things before
   the walk sees them (with-warp-specialization's role bodies; prefetch-tile's coordinate
   tuple; ring-get views).  Whatever identifies "the staging statements" must run where the
   structure is still intact.


Why this is worth doing beyond MMA
-----------------------------------

Nothing about this is MMA-specific.  It is the general capability "the backward may recompute
a forward intermediate", which is what lets AD handle any kernel that builds a value it later
consumes.  140/01-02 are simply the first users to ask for it.


What the spike established
---------------------------

Before writing any mechanism, `%ad-check-unresolved-primals` was neutered and rung 01 compiled
with the refusal lifted, so the rest of the backward could be read.  Three things came out of
it, and they change the plan above more than a little.

**1.  THIS IS A PRIMAL-ONLY ENDEAVOUR.  The adjoint side is already complete.**  The emitted
backward already allocates and zeroes `A-TILE_ADJ`, already runs the product VJP, already
scatters into the tile adjoint, and already carries that adjoint out to `A_GRAD` by walking the
staging statements in reverse:

    (set! %anf-t-19_adj (+ %anf-t-19_adj (* %anf-t-20 %anf-t-21_adj)))  ; dA-tile = B-tile.dC
    (set! (~ a-tile_adj i) (+ (~ a-tile_adj i) %anf-t-19_adj))
    ...
    (set! %anf-t-9_adj (+ %anf-t-9_adj (~ a-tile_adj i)))               ; staging loop, reversed
    (set! (~ a-tile_adj i) 0.0)
    (atomic-add! (~ a_grad i) %anf-t-9_adj)

The ONLY defect is that `%anf-t-19` and `%anf-t-20` are bound to `(~ A-TILE i)` — reads of a
tile nobody filled.  Nothing else needs building.

**2.  THE BACKWARD ALREADY CONTAINS THE STAGING STATEMENTS**, walked in reverse for the adjoint.
Replay is therefore not synthesis of new structure; it is a SECOND, FORWARD-DIRECTION copy of
statements the backward already carries.  Which immediately raises the hazard rung 04 exists
for: that copy must be injected where the walk CANNOT see it, or the staging gets differentiated
twice and every gradient through it doubles, silently.

**3.  THE INSERTION POINT IS A SEAM THAT ALREADY EXISTS.**  The primal binding is emitted by
`%gfw-process-let` — the same place `%ad-rewrite-primal-bindings` performs 037's source-recovery
rewrite today.  So replay is the FALLBACK at that seam when the source map has no entry, and
"scope-aware placement" costs nothing extra: `%gfw-process-dotimes` rebuilds each loop with its
own binding, so a per-iteration re-stage lands at the right depth by construction.  Design fork
#1 above ("WHICH statements?") is answered by where the walk already is, not by a new analysis.

Design fork #3 (RECOMPUTE vs SAVE) is CLOSED: recompute.  Saving would grow the forward kernel's
signature, which propagates into hoist codegen, launch argument lists and both VERIFY-AUTODIFF
runtimes — a cross-cutting change for an unmeasured tradeoff.  Recompute stays inside the
backward kernel.


One hazard the original notes missed
-------------------------------------

Rung 03 guards what a replayed statement WRITES.  There is a symmetric hazard in what it READS,
and it is worse, because nothing about it looks wrong.

The backward is a separate launch.  Global memory is not restored to the state the forward found
it in, so a staging statement that reads a mutated global recomputes from the wrong numbers —
silently, plausibly, and differently depending on how the gradient kernel was driven.

Under `--differentiate` input parameters are read-only, which makes the rule cheap: the globals
the forward may have mutated are exactly the `&out` parameters, known from the signature.  A
replayed statement may read inputs, scratch and constants; a read of an `&out` makes the slice
unreplayable.  That is rung 07.


The TDD ladder
--------------

Each rung is BMG-shaped so it can end in a NUMBER rather than a compile, and each tests ONE
thing — 146's lesson about debugging an AD gap through a kernel with three other features in it.
All seven currently FAIL; the five positives fail with the correct refusal quoted above.

  01  minimal — two hand-staged tiles multiplied elementwise.  The smallest kernel whose
      backward needs a staged tile's primal.  No MMA, no swizzle, no rings.

  02  non-invertible — the same shape but staged through an index permutation the compiler
      cannot invert.  Proves replay works where SOURCE RECOVERY provably cannot, which is
      140/01's actual situation reduced to something BMG can run.

  03  safety, WRITES — staging that also writes global memory.  Replaying it would double the
      write.  Asserts the compiler REFUSES rather than silently corrupting.  NEGATIVE by design
      and should stay negative forever.

  04  computed fill — the staged value is A*A, which exists nowhere in global memory, so replay
      must re-run ARITHMETIC and not merely re-issue loads.  Also the double-differentiation
      tripwire: a square makes a doubled gradient (12.0 vs 6.0) impossible to miss, where a
      copy-staged tile can hide it.

  05  loop-carried — the tile is RE-STAGED each iteration, so there is no such thing as "the"
      primal value of it.  This is 140/02's scheduling shape with the tensor cores removed, and
      it is the ONLY rung that can tell a correctly-placed replay from one hoisted to the top of
      the kernel: probing A[5] (staged on the second iteration) gives 5.5 when placed right and
      1.5 — same slot, wrong iteration — when hoisted.

  06  cross-subgroup — a 64-wide REVERSAL, so slot 5 is written by thread 58 and read by thread
      5.  The replayed staging must carry its `sync-workgroup`.  Rung 02's pair-swap cannot test
      this: adjacent lanes are always in the same subgroup and a dropped barrier would pass
      there, repeatedly, which is worse than failing.

  07  safety, READS — staging that reads an `&out` parameter (see the hazard above).  NEGATIVE
      by design.  Twin of 03.

Rule 1 from endeavour 146 applies throughout: a clean compile is not the deliverable.  01, 02,
04, 05 and 06 must each end in a gradient-checked number on BMG; 03 and 07 must each end in a
diagnostic that names what made replay unsafe.


Two things about running these
-------------------------------

VERIFY-AUTODIFF fires only when the RUNNER is given `--differentiate` — a spec's own
`COMPILE-WITH[... --differentiate]` line does not trigger it.  So:

    sbcl --script tests/run-specs.lisp --filter=149 --differentiate

Without that flag these rungs report on compilation alone and never produce a number.

`group=` defaults to 1 — ONE thread.  Every staging rung here sets it explicitly, because at
group=1 a single thread fills every slot and then reads every slot: no tile value crosses a
thread boundary, the `sync-workgroup` is decorative, and a replay mechanism that got the
cross-thread case wrong would pass anyway.  A control kernel with rung 01's exact directive and
no staging at all was run on BMG to confirm the harness itself is sound
(`A: analytical=1.5 numerical=1.5 diff=0.0; B: analytical=2.0 numerical=2.0 diff=0.0`), so when
these rungs eventually produce a wrong number, the directive is not the suspect.
