Endeavor 149 — AD Primal Replay
================================

STATUS: not started.  Written at the close of 146 so the reasoning is not lost.  These specs
are BEYOND `tests/ci-stop.txt`, so nothing here runs yet and nothing here is red in CI.


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


The TDD ladder
--------------

Each rung is BMG-shaped so it can end in a NUMBER rather than a compile.  All three currently
FAIL, and the first two fail with the correct refusal quoted above — that refusal is the
starting line, not a bug.

  01  minimal — two hand-staged tiles multiplied elementwise.  The smallest kernel whose
      backward needs a staged tile's primal.  No MMA, no swizzle, no rings.

  02  non-invertible — the same shape but staged through an index permutation the compiler
      cannot invert.  Proves replay works where SOURCE RECOVERY provably cannot, which is
      140/01's actual situation reduced to something BMG can run.

  03  safety — staging that also writes global memory.  Replaying it would double the write.
      Asserts the compiler REFUSES rather than silently corrupting.  This one is a NEGATIVE
      test by design and should stay negative forever.

Rule 1 from endeavour 146 applies throughout: a clean compile is not the deliverable.  01 and
02 must end in a gradient-checked number on BMG; 03 must end in a diagnostic.
