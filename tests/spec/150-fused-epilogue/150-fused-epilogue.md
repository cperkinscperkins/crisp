Endeavor 150 — Fused Epilogue
==============================

STATUS: 2026-08-14 — TDD LADDER COMPLETE, IMPLEMENTATION NOT STARTED.  This document records the
audit that motivated the endeavour, the design decision it turns on, and the ladder.

ci-stop.txt is still `149-ad-primal-replay` and MUST STAY THERE until the ladder is green — 150
sits after the gate on purpose, so ten deliberately-red specs do not redden CI.  Advancing it is
the last step of the endeavour, not the first.

THE TDD LADDER IS COMPLETE — all ten specs written (01-05, errors/06-07, 08-10) and verified RED
for the right reason.  Every one fails with exactly `Unsupported form 'MAP-ELEMENTS!' found in
function body.` and nothing else, which establishes that the rest of each kernel is already
sound: types, shapes, hardware profile, the matrix-multiply-tile-stride structure and its
:epilogue split, and the fused activations' own `def-function` bodies, which compile clean in
value position (`let` + `if`).  The only missing thing is the primitive.

Rung 11 is a benchmark rather than a spec.  Rung 12 (layout-aware) is deliberately NOT written —
see its entry.

The ONE harness change this needed is DONE and verified: the L0 buffer-print cap, raised
100 -> 512 in overlays/hoist-l0/crisp-hoist-l0-overlay.lisp (see open question #3).  Verified
end-to-end by running the validator's own invocation,
`crisp-hoist-l0.exe --mma-test=16,16,8 <spec>.metacrisp`, against 133/11:

    if (128 <= 512) {  ... BUFFER a:
    if (128 <= 512) {  ... BUFFER b:
    if (256 <= 512) {  ... BUFFER c:          <- 256 elements; at the old cap this never printed
    std::cout << (mma_ok ? "MMA_CORRECT" : "MMA_WRONG")

which also confirms on real generated output that the buffer prints and the MMA verdict coexist
in one run.  The overlay diffs against the src original in exactly two places: the docstring and
the literal.  The CUDA hoist needed NO change — it has never had such a gate.


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

**Why the language already suits this** (per Chris, 2026-08-14): Crisp realises first-order
functions through TEMPLATE MONOMORPHIZATION.  That matters more than it first appears:

  - There is no function-pointer indirection at the call site — which is a hard requirement, since
    an indirect call inside a per-fragment MMA epilogue would be ruinous on either vendor.
  - Each fused call site sees a CONCRETE callee.  So the P2 VJP differentiates a known function
    body rather than an opaque function value — the difference between "write a VJP" and "solve
    higher-order AD".  The backward walk already carries a `hof-handler-fn` and an `:hof` property
    on sub-function info (src/autodiff.lisp:550-559), so HOFs are not new ground for the engine.
  - The per-fragment body is spliced N times for an N-fragment tile, so N call sites monomorphize
    to the same specialization.

The design was drawn to match `:transformF`, which already relies on this; the alignment is
therefore not a coincidence, but it was confirmed rather than assumed.


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
split.  Rung 07 encodes this as a refusal.

CORRECTION, and it makes the rule SIMPLER rather than more complicated.  The intuitive statement
— "non-linear activations are wrong on a partial sum" — is too weak.  The corruption comes from
the accumulator being re-transformed on EVERY step, not from the shape of the function, so even
a linear map is wrong (this is exactly the 2·p1+2·p2 vs 4·p1+2·p2 arithmetic that rung 03 uses
to detect misplacement).  The only function that survives per-K-step application is the
identity.  So the check is STRUCTURAL — any map on `acc` inside a staged reduction body is
refused — and needs no notion of linearity at all.  Rung 07 uses a linear function deliberately,
to pin that.

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

  01  fragment map, scale ×2, PTX.  [01-fragment-map-scale-ptx.crisp — WRITTEN, red]
      The minimal thing: a via-tile body that applies `(* x 2.0)` to `acc`.  Deliberately reuses
      the EXISTING validator — C = 2·(A·B) is exactly what `MMA-SCALE: 2` + `MMA_CORRECT` already
      checks for 132/09, so rung 01 needs no harness work and its pass/fail is unambiguous on
      hardware.  Note the A/B against 132/09, which reaches the SAME number by firing
      `(accum-op)` twice: that spec proves the body controls the MMA firing COUNT, this one that
      the body can transform the accumulator's VALUE.  Both halves of the body API, one number.

  02  the same on SPV / BMG.  [02-fragment-map-scale-bmg.crisp — WRITTEN, red]
      Proves the coop-matrix component path, which is the half of the backend story that is NOT
      confirmed yet — and settles it at rung 2 rather than rung 9.
      SECOND JOB: its C-tile is 16×16 against an (8 16 8) XMX shape, so it decomposes into TWO
      fragments and the per-fragment body must run on both.  An implementation that mapped only
      the first fragment leaves the second unscaled and the host reference says MMA_WRONG.
      Rung 01's 16×8 tile is exactly one fragment and cannot see this.

  03  tile map in `:epilogue`, scale ×2.  [03-tile-map-epilogue-bmg.crisp — WRITTEN, red]
      Same validator, second altitude.  Proves the primitive is genuinely one mechanism and not
      two implementations that happen to share a name.
      THIS IS ALSO THE PLACEMENT RUNG, which is why it is built on the STAGED pattern: K=16 at
      k-step 8 gives TWO K-steps, so with p1/p2 the two contributions,

          correct   (once, post-reduction):   2·p1 + 2·p2      = MMA-SCALE 2
          misplaced (per K-step):             4·p1 + 2·p2      = MMA_WRONG

      A one-K-step kernel would pass with the placement wrong — 149's rung-05 trap.  ×2 is
      linear on purpose: it keeps rung 03 about PLACEMENT and leaves the "activation on a partial
      sum" refusal to rung 07, one thing each.

  04  ReLU on `acc`, checked with `HOIST-EXPECT: BUFFER c:` (open question #3).  Unblocked once
      the buffer cap is raised; needs no new directive.

      MUST USE A SHIFTED ACTIVATION — this is a trap worth stating plainly.  The MMA harness
      fills its inputs `A[i] = i % 5` and `B[i] = i % 3` (src/hoist-l0/main.lisp:1512-1517),
      both NON-NEGATIVE, so A·B is non-negative everywhere and a plain `relu` is the IDENTITY on
      this data.  A naive ReLU rung would therefore pass whether or not the epilogue fired, which
      is the worst possible outcome for a TDD rung.  Fuse a THRESHOLDED form instead —
      `(if (> (- x 20.0) 0.0) (- x 20.0) 0.0)` or similar — so the activation supplies its own
      kink and both branches are exercised against the existing fill.  (Changing the harness fill
      to produce negatives is the alternative, but it churns the reference numbers of ~35 MMA
      specs for no gain.)

  05  a user-defined activation that is NOT relu — leaky-relu or a clamp, written as a plain
      Crisp `def-function` in the spec itself.  This rung IS the endeavour's thesis: arbitrary
      user code fused in registers, no compiler change.  If only 04 passes we have reimplemented
      cuBLASLt's enum.  Note this rung is the reason #3 resolved toward hand-computed BUFFER
      values: no fixed table of host-side activations could ever validate it.

  06  NEGATIVE — a fused function with the wrong arity (not unary).  Must refuse cleanly rather
      than crash inside the monomorphized specialization.
      [errors/06-non-unary-fused-fn.crisp — WRITTEN, red]

  07  NEGATIVE — a map on `acc` inside a `matrix-multiply-tile-stride` K-loop (the partial-sum
      rule above).  Must refuse, naming the partial sum and pointing at :epilogue.  Should stay
      negative forever.  Uses a LINEAR function on purpose — see the rule above for why "no
      non-linear activations" is the wrong, too-weak statement of this.
      [errors/07-map-on-partial-sum.crisp — WRITTEN, red]

  Both negatives currently fail with `Unsupported form 'MAP-ELEMENTS!'` rather than their
  CHECK-FAIL substrings — the correct pre-implementation state, since the negative runner
  requires BOTH a non-zero exit and the expected substring.

P2 — autodiff.  All three share one activation, one dataset and one threshold, so they differ
only in what they are asking.  Data is 145/09's, deliberately, so the numbers are comparable to
a shipped spec.

  08  gradient FLOWS above the kink — probe row 2, expect 1.2.
      [08-relu-gradient-flows-bmg.crisp — WRITTEN, red]
      NECESSARY BUT NOT SUFFICIENT ALONE: a saturated-on ReLU is transparent, so an
      implementation that ignored the activation in the backward also prints 1.2.  Its real job
      is to be 09's non-zero control against the zero-seed hazard.

  09  gradient is BLOCKED below the kink — probe row 1, expect 0.0.  THE DISCRIMINATOR.
      [09-relu-gradient-blocked-bmg.crisp — WRITTEN, red]
      Probes the SAME point on the SAME data as the shipped 145/09, which expects 1.2 there.
      The entire difference is the activation's derivative, so the most likely failure mode
      (activation ignored in the backward) shows up as 145/09's answer.

  10  the same check through a STAGED K-loop, activation in `:epilogue` — expect 1.2.
      [10-staged-epilogue-gradient-bmg.crisp — WRITTEN, red]
      Identical data/threshold/probe to 08, so if 08 passes and 10 fails the gap is specifically
      in recovering a pre-activation primal from a loop-carried ACCUMULATION.  This asks 149's
      replay for something new: all seven of its rungs replay STAGING, none an accumulation.  A
      refusal that names what it cannot recover is an acceptable outcome here and a good input
      to the next endeavour; a silent zero is not.  Sited off the ring path (BUG 044).

  WHY THE THRESHOLD IS 7.0.  With A[m][k] = 0.01*(16m+k) and B[k][n] = 0.01*(16k+n),
  C[m][n] = 1e-4*(30720m + 256mn + 19840 + 120n), which separates by output row: row 1 spans
  5.056..5.620 and row 2 spans 8.128..9.076.  A threshold of 7.0 sits in that gap with margins
  of 1.38 and 1.128, while an h=0.5 perturbation moves any element by at most 0.075.  So nothing
  crosses the kink, the FD stays valid, and h does not have to shrink into fp32 noise.

P3 — the number that justifies the arc

  11  NOT a spec — a benchmark.  **Crisp fused matmul+activation vs cuBLAS matmul + separate
      activation kernel.**  The unfused baseline pays a 3×N² HBM round trip that the fused kernel
      does not generate.  Whether that beats a 67%-efficiency matmul is shape-dependent and is a
      MEASUREMENT, not an argument ([[145-method-measure-dont-classify]]).  Use 141's harness.
      This is the endeavour's real definition of done.

P4 — deferred, may want its own endeavour

  12  layout-aware epilogues: bias-add along N, row-wise reductions.  Requires a documented
      per-vendor fragment→coordinate map.  Decide SPV portability before committing.
      NOT WRITTEN — deliberately.  Writing rungs against a fragment→coordinate map we have not
      decided is how a spec ends up encoding an accidental contract.


Open questions to settle before writing code
---------------------------------------------

1. **Surface syntax.**  What is the form actually called?  `map-tile!` / `transform-tile!` /
   something echoing `:transformF`.  It must read the same on a fragment and on a register tile.

   PROVISIONALLY `(map-elements! <fragment-or-tile> #'<unary-fn>)`, which is what rungs 01-03 are
   written against.  Chosen only so the specs could be drafted; it is one form, so a rename is
   cheap.  The `!` follows `set!` / `atomic-add!`, and the argument order follows
   `:transformF #'fn`.  What must NOT change is that the identical form works at BOTH altitudes —
   rung 01 fuses it on a fragment, rung 03 on a register tile, and if those ever need different
   spellings the "one primitive" claim has quietly failed.

2. **In-place or returning?**  `fill-tile` mutates in place; `mma-accumulate` returns a new value
   via `set!`.  The fragment path is SSA-shaped today, the tile path is not.  Pick one and make
   both sites match.

   The provisional `!` commits to IN-PLACE, matching `fill-tile` at the tile site.  At the
   fragment site the compiler can lower it to `set! acc (…)` over a local, so SSA is not an
   obstacle — but this should be confirmed rather than assumed.

3. **Harness: how does the host reference apply the activation?**  RESOLVED — no new directive.
   Use the `BUFFER` expectation that already exists, and raise one cap.

   `MMA-SCALE` is a scalar multiplier, enough for rungs 01-03 and useless for 04-05.  But the
   generated harness ALREADY prints every buffer AND the MMA verdict in the same run:
   `generate-cpp-main` (src/hoist-l0/main.lisp:422-431) emits `BUFFER <name>: …` for each
   allocation, and only THEN appends the `MMA_CORRECT` / `MMA_WRONG` reference check.  And
   `HOIST-EXPECT` is matched with `(search exp run-out)` — a SUBSTRING test, with multiple
   HOIST-EXPECT lines ANDed (tests/run-specs.lisp:2738-2744).

   So `HOIST-EXPECT: BUFFER c: 12 12 12` pins the first few elements of a 128-element tile and
   needs no new machinery.  Roughly 30 specs already use `BUFFER` expectations.

   THE ONE BLOCKER was a cap: the buffer print is gated on `size <= 100` elements, and the
   smallest single MMA output tile is 128 on BOTH vendors (16×8 NVIDIA, 8×16 Intel), so C was
   never printed.  DONE — raised to 512 in overlays/hoist-l0/crisp-hoist-l0-overlay.lisp, a
   general improvement rather than a ReLU-specific hack, and verified on generated output (see
   STATUS).  It turned out to be ONE line in ONE file, not two: the CUDA hoist prints every
   buffer unconditionally and has never had this gate, so the change only brings L0 into line
   with what CUDA already did.

   WHY THIS BEATS AN `MMA-EPILOGUE:` DIRECTIVE.  A directive with a fixed table of host-side
   activations is literally the cuBLASLt enum this endeavour exists to beat — and it could never
   validate rung 05, whose whole point is a user activation the compiler has never heard of.
   Hand-computed expected values are activation-agnostic by construction.

   WHY NOT VERIFY-AUTODIFF.  It cannot validate a FORWARD value: the finite difference is
   computed from the same forward kernel, so a wrong forward yields a self-consistently wrong
   gradient that still passes.  (It IS a valid detector for a missing ReLU specifically, since
   a skipped activation changes the gradient at a negative pre-activation — but that is rung 08's
   job, not rung 04's.)

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
