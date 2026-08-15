Endeavor 150 — Fused Epilogue
==============================

STATUS: PLANNED, 2026-08-14.  No mechanism written yet.  This document records the audit that
motivated the endeavour, the design decision it turns on, and the TDD ladder.


Why this endeavour exists
--------------------------

141 measured Crisp's wgmma matmul at **67% of cuBLAS** at scale.  On a bare matmul we are behind,
and we are not going to out-tune NVIDIA's hand-written assembly at their own game.  So the
question "why not just call cuBLAS fifteen endeavours ago" is a fair one, and it deserves an
answer that is not about GFLOPS.

The answer is that cuBLAS structurally cannot run **arbitrary user code on the accumulator while
it is still in registers**.  cuBLASLt offers a fixed enum of epilogues — bias, relu, gelu, a few
combinations.  If the activation you want is not on that list, you pay a full HBM round trip:
write C, read C, write C.  At 4096² fp32 that is a 64MB matrix written, read, and written again.

A compiler can fuse anything.  That is the differentiator, and it is the thing this project has
been building toward through fifteen endeavours of MMA plumbing.  Today it does not work.


The audit — what actually exists today
---------------------------------------

Probed against a fresh `bin/crisp-compile.exe` on 2026-08-14.  Probe kernels are in
`put_temp_files_here/accum-probe/`.

**The `accum` binding is bound but unusable.**  `mma-accumulate-via-tile`'s body form takes an
accum-binding — `(mma-accumulate-via-tile (M N K) C-tile A B (acc) BODY…)` — and `%subst-accum`
(src/mma.lisp:872) does correctly substitute the symbol with the per-fragment variable.  But
nothing downstream can consume the result:

    PTX  (set! acc (* acc 2.0))       -> Type mismatch for operator '*'.
                                         Cannot operate on REGISTER-FRAGMENT-ACC-F32-16X8 and FLOAT.
    SPV  (set! acc (* acc 2.0))       -> Type mismatch for operator '*'.
                                         Cannot operate on (COOP-MATRIX FLOAT 16 8 2) and FLOAT.
    PTX  (set! (r0~ acc) …)           -> Unsupported form 'R0~' found in function body.

The error naming the fragment's real type is the proof that substitution works.  The gap is
entirely in what a fragment VALUE supports.

**No spec has ever used the binding.**  Repo-wide, the only two call sites that pass a binding are
132-mma-fundamentals/09-accum-op-body.crisp and 133-mma-spv/09-accum-op-body.crisp, and both bind
`(acc)` and never mention `acc` in the body.  They test `(accum-op)` — the firing count — which
DOES work, and 132/09 proves it on metal (`MMA-SCALE: 2`, `HOIST-EXPECT: MMA_CORRECT`).
There is also a negative test on the binding's shape, errors/03-bad-accum-binding.crisp.

**`relu` does not exist.**  Neither does `max` or `min`.  Every `(relu C-tile)` in docs/topology.md
— lines 743, 867, 1016, 1099, 1250 — is pseudocode.

**The register-tile / fragment API has no element access and no elementwise ops.**  The registered
forms (src/mma.lisp:1514-1533) are make / fill / load / store / mma-accumulate.  So an activation
cannot be written on `acc` OR on `C-tile`.  Both fusion points are equally empty.

**`:epilogue` is real.**  `%mmts-split-epilogue` (src/analysis/control.lisp:3762) splits a
`matrix-multiply-tile-stride` body at the `:epilogue` marker; forms after it run once per output
tile with the C-tile complete.  The splice works and is tested — there is simply no tile-level
elementwise op to call inside it.

**`store-tile :transformF` works and is tested.**  A user-supplied unary function applied per
element inside the store loop (src/analysis/control.lisp:363-398), tested at
111-load-and-store-tile/08-store-transformF.crisp.  This is Crisp's ONLY working fusion mechanism
today, and it is the model for everything below.

So there are three candidate fusion sites, and the one that works is the third:

    per-fragment, in registers     acc binding             bound, nothing can consume it
    per-tile, post-K-loop          :epilogue splice        splice real, no op to call
    per-element, at store          store-tile :transformF  WORKS, tested


The design decision: one primitive, three sites
------------------------------------------------

The tempting design is operator overloading — make `(* acc 2.0)` and `(max acc 0.0)` typecheck on
fragments and tiles.  That is the wrong shape: it means overloading every arithmetic operator
across two backends and two aggregate types, and it drags in scalar builtins we do not have.

Instead, **generalise the idiom `:transformF` already established**: a user-supplied unary function
applied per element.  One primitive, applied at all three altitudes.

The consequences are what make this worth doing:

  - **ReLU stops being a compiler feature.**  It is an ordinary Crisp function.  `(if (> x 0.0) x 0.0)`
    is expressible TODAY with no new scalar builtins.  The "simple ReLU for the lazy" ships as a
    library function, not a primitive.
  - **The user writes `gelu`, `silu`, `leaky-relu`, `clamp-and-scale` without touching the compiler.**
    That is precisely the axis where cuBLASLt's fixed enum loses, and it is the whole argument for
    having built a compiler.
  - One mechanism to make differentiable, not N operator rules.

Scalar `max` / `min` are still worth adding (real `fmax` lowering, cheap, AD-able) but they are a
convenience, not a prerequisite.


The scope boundary: elementwise is safe, layout-aware is not
-------------------------------------------------------------

This decides how big the endeavour is, and it should be settled before any code is written.

**Elementwise is layout-agnostic, and that is what makes P0/P1 tractable.**  A fragment is
warp-collective: each lane holds 4 floats of a 16×8 accumulator.  Applying `relu` to each register
independently is IDENTICAL to applying it to the logical matrix.  We never need to know which
logical (row, col) a register holds.  On PTX that is fieldwise over the 4-float record; on SPV,
cooperative matrices support per-component access for exactly this reason, while the
component→element mapping is deliberately implementation-defined.

  TO CONFIRM: that our llvm-spirv path emits coop-matrix component access cleanly.  Not verified.

**The moment you leave elementwise, that breaks.**  Bias-add needs each register's COLUMN index.
Row-wise max / softmax needs cross-lane reduction.  Both require committing to a documented
per-vendor fragment→coordinate map, and on SPV the abstraction is opaque BY DESIGN, so it may not
be portably expressible at all.  145 also left us [[mma-fragment-layout-untestable-by-roundtrip]]:
that map cannot be validated by round-tripping.

Bias-add is the most-requested companion to ReLU in real epilogues, so it will be asked for in
week one.  It is P4, and it does not gate P0-P3.


The partial-sum rule — and a compiler check that should come out of it
-----------------------------------------------------------------------

Fusing on `acc` is only CORRECT when the single `mma-accumulate-via-tile` call performs the
COMPLETE K-contraction.  In the staged pattern — `matrix-multiply-tile-stride`'s `grid-k` loop
calling via-tile once per K-step — `acc` holds a PARTIAL sum, and a non-linear activation applied
to a partial sum is simply wrong:

    two K-steps contributing -5 then +3
      correct:            relu(-5 + 3) = relu(-2) = 0
      fused per K-step:   relu(-5) = 0, then 0 + 3 = 3, relu(3) = 3     <- wrong, and silently so

Note the failure is worse than a misplaced final clamp: clamping a negative running sum to zero
destroys the value the next K-step needs to add to.

docs/topology.md:752-758 already states the rule in prose.  This endeavour can make it a
**compile-time check**: the compiler knows structurally whether a via-tile call sits in the
reduction body or the epilogue body, because `%mmts-split-epilogue` already performs that exact
split.  Fusing a non-linear function on `acc` inside a K-loop is therefore detectable, and should
warn or refuse rather than produce a silently wrong matmul.  Rung 07 encodes this.

(145 P3a widened the correct case: via-tile now walks ALL native K-steps inside a staged operand,
src/mma.lisp:930-934.  So "one call = complete contraction" covers more shapes than it once did.)


Autodiff is not optional
-------------------------

An UNFUSED activation is differentiable today, so fusing it must not regress that.  `d/dx relu`
is a step function, which means the backward pass needs the PRE-ACTIVATION primal — which is
exactly what 149 (ad-primal-replay) just landed.  That is the strongest argument that 150 is the
right NEXT endeavour: the machinery it depends on is a day old.

Per 145's retraction, the rule belongs in the VJP registry, so the lowering choice stays inside
the VJP rather than leaking out as a language contract.

**Gradient-checking across a kink.**  ReLU's derivative is discontinuous at 0, and finite
differences straddling the kink give a meaningless numerical gradient.  Any VERIFY-AUTODIFF rung
here must choose pre-activation values comfortably far from zero relative to `h` (149 used h=0.5,
which is a large straddle), and must probe BOTH sides — positive, where the gradient flows, and
negative, where it must be exactly 0.0.  A rung that only probes the positive side would pass with
the activation's derivative ignored entirely.


The TDD ladder
--------------

Each rung tests ONE thing, and is BMG- or CUDA-shaped where a number is possible rather than a
clean compile.  Rule 1 from 146 applies throughout: a clean compile is not the deliverable.

P0/P1 — the primitive, forward

  01  fragment map, scale ×2, PTX.  The minimal thing: a via-tile body that applies `(* x 2.0)`
      to `acc`.  Deliberately reuses the EXISTING validator — C = 2·(A·B) is exactly what
      `MMA-SCALE: 2` + `HOIST-EXPECT: MMA_CORRECT` already checks for 132/09, so rung 01 needs no
      harness work and its pass/fail is unambiguous on hardware.

  02  the same on SPV / BMG.  Proves the coop-matrix component path, which is the half of the
      backend story that is NOT confirmed yet.

  03  tile map in `:epilogue`, scale ×2.  Same validator, second site.  Proves the primitive is
      genuinely one mechanism at two altitudes and not two implementations.

  04  ReLU on `acc`, with operands chosen to produce negatives.  This is the first rung the
      current on-metal harness CANNOT check — `MMA-SCALE` expresses a scalar multiplier, not an
      activation.  See "Open questions" #3; the harness work lands here.

  05  a user-defined activation that is NOT relu — leaky-relu or a clamp, written as a plain
      Crisp `def-function` in the spec itself.  This rung IS the endeavour's thesis: arbitrary
      user code fused in registers, no compiler change.  If only 04 passes we have reimplemented
      cuBLASLt's enum.

  06  NEGATIVE — a fused function with the wrong arity (not unary).  Should refuse cleanly.

  07  NEGATIVE — a non-linear function fused on `acc` inside a `matrix-multiply-tile-stride`
      K-loop (the partial-sum rule above).  Must warn or refuse, naming the partial sum.  This
      rung should stay negative forever.

P2 — autodiff

  08  fused ReLU differentiates, numeric check on metal.  Probe points on BOTH sides of the kink,
      both far from it relative to `h`: a positive pre-activation where the gradient must flow,
      and a negative one where it must be exactly 0.0.  Sited OFF the ring-pipelined path — see
      "Practical cautions".

  09  fused epilogue on a K-looped / staged matmul differentiates.  This is the rung that leans
      on 149's primal replay, since the backward needs the pre-activation value of a staged
      reduction.

P3 — the number that justifies the arc

  10  NOT a spec — a benchmark.  **Crisp fused matmul+activation vs cuBLAS matmul + separate
      activation kernel.**  The unfused baseline pays a 3×N² HBM round trip that the fused kernel
      does not generate.  Whether that beats a 67%-efficiency matmul is shape-dependent and is a
      MEASUREMENT, not an argument ([[145-method-measure-dont-classify]]).  Use 141's harness.
      This is the endeavour's real definition of done.

P4 — deferred, may want its own endeavour

  11  layout-aware epilogues: bias-add along N, row-wise reductions.  Requires a documented
      per-vendor fragment→coordinate map.  Decide SPV portability before committing.


Open questions to settle before writing code
---------------------------------------------

1. **Surface syntax.**  What is the form actually called?  `map-tile!` / `transform-tile!` /
   something echoing `:transformF`.  It must read the same on a fragment and on a register tile.

2. **In-place or returning?**  `fill-tile` mutates in place; `mma-accumulate` returns a new value
   via `set!`.  The fragment path is SSA-shaped today, the tile path is not.  Pick one and make
   both sites match.

3. **Harness: how does the host reference apply the activation?**  `MMA-SCALE` is a scalar
   multiplier — enough for rungs 01-03, useless for 04-05.  Options: an `MMA-EPILOGUE: relu`
   directive with a small fixed set of host-side references, or shift on-metal activation checking
   onto VERIFY-AUTODIFF, which already runs real numbers.  Rung 04 cannot be written until this
   is decided.

4. **Double application.**  A user could fuse the same activation on `acc` AND in `:transformF` on
   the store.  Probably user error rather than something to prevent, but decide whether it warns.

5. **Scalar `max` / `min`** — add now or later?  Not blocking, since relu is expressible with `if`.

6. **Does the fused epilogue interact with BUG 036's C-tile reset?**  The reset is per output tile
   and the `:epilogue` splice is post-reduction per tile, so they should compose — but this is an
   assumption, not a verified fact.


Practical cautions
------------------

**BUG 044 is open** — ring-pipelined MMA BACKWARD is wrong on BMG (analytical 84.32 vs expected
1.2).  If rung 08's on-metal gradient check is built on the ring-pipelined path we will not be
able to distinguish a new bug from that one.  Either fix 044 first or deliberately site 08 and 09
off the ring path.

**BUG 043 is open** — single-pass `--differentiate` serves the forward's `:physical-signature` for
the backward.  Worth knowing before debugging anything odd under `--single-pass`.

**VERIFY-AUTODIFF fires only when the RUNNER gets `--differentiate`** — a spec's own
`COMPILE-WITH[… --differentiate]` line does not trigger it:

    sbcl --script tests/run-specs.lisp --filter=150 --differentiate

**`group=` defaults to 1** — ONE thread.  MMA is a sub-group collective, so a group=1
VERIFY-AUTODIFF silently gives a zero gradient (145 P6 learned this).  Every rung here that
verifies a gradient must set it explicitly.


Definition of done
------------------

plan/definition-of-done.md applies in full.  Items with teeth for this endeavour:

  - docs/topology.md corrected — the `(relu C-tile)` pseudocode at 743 / 867 / 1016 / 1099 / 1250
    either becomes real or is labelled, and 752-758's fusion guidance points at the mechanism that
    exists.  This documentation debt is what started the endeavour and should not survive it.
  - status emojis in docs/ideal_001.md, including any new error.
  - regenerate reference.md, call_graph.md, chapters, globals table.
  - negative specs under 150-fused-epilogue/errors/ for rungs 06 and 07.
  - `ci-stop.txt` advanced to 150-fused-epilogue when the ladder is green.
  - the P3 benchmark RECORDED, not just run.
