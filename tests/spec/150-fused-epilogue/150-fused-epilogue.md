Endeavor 150 — Fused Epilogue
==============================

STATUS: 2026-08-15 — FEATURE COMPLETE AND GREEN ON BOTH VENDORS.  What remains is the P3
benchmark (rung 11) and the fold out of the overlay into src/.

    Intel BMG      16/16 forward, 16/16 --differentiate   (local)
    NVIDIA H100    all phases green                       (pod)
    Full suite     995/995 forward, 995/995 --differentiate, 213/213 negative, 0 unit failures

Four on-metal forward numbers and six on-metal gradient checks — three per vendor, each pinning
the activation's derivative on BOTH sides of the kink.

This document records the audit that motivated the endeavour, the design decision it turns on,
the ladder, and the two bugs the ladder caught in the implementation of its own feature.

ci-stop.txt is now `150-fused-epilogue`, advanced once the ladder went green — which is the
right order: 150 sat after the gate on purpose while its specs were deliberately red.

IMPLEMENTATION — 10/10 FORWARD AND 10/10 UNDER --differentiate (2026-08-15).  The fused epilogue
now differentiates, with the activation's derivative pinned on BOTH sides of the kink:

    08 (probe above the kink)   analytical=1.1994476  numerical=1.1992188   PASS
    09 (probe below the kink)   analytical=0.0        numerical=0.0         PASS
    10 (staged, above kink)     analytical=1.2        numerical=1.1992188   PASS

THE 08/09 PAIR EARNED ITS KEEP TWICE, which is worth recording because the design was argued for
in the spec headers before either rung had ever run.

  - It caught the ORIGINAL defect: the walk dropped the activation entirely, so 09 read the
    un-activated 1.1994476 against a correct FD of 0.0.
  - It caught the FIRST FIX being wrong in the opposite direction.  That version recomputed P
    from the forward-staged tiles, which are EMPTY in a backward kernel, so P was all zeros,
    f'(0 - 7 < 0) = 0, and every gradient through the activation died.  Rung 09 went GREEN on
    that bug — a backward that propagates nothing is indistinguishable from a correctly-blocked
    gradient — and only rung 08, expecting a non-zero 1.2 through the same kernel, exposed it.

    That failure mode was predicted in writing before the fix was attempted, including which
    rung would go spuriously green.  A single-sided gradient check would have shipped it.

The fix was to re-stage the operands from their GLOBAL sources inside the prefix (the same
reason %mma-vjp-scalar-lowering reads globals), then recompute P and scale.  Cost stays entirely
inside the backward; the forward kernel is untouched and its on-metal numbers are byte-identical.

THE FORWARD IS COMPLETE.  All ten specs pass, four of them on NUMBERS from BMG rather than a
clean compile.  Rung 03's `60 60 60` is the placement discriminator paying off: p1 = 11 and
p2 = 19 for that element, so a correctly-placed epilogue gives 2*(11+19) = 60, while a map
wrongly spliced into the reduction body would give 4*11 + 2*19 = 82.  The number says the
epilogue ran ONCE, post-reduction.

THE BACKWARD IGNORES THE ACTIVATION'S DERIVATIVE.  Rung 09:

    08 (row 2, above kink)   analytical=1.1994476  numerical=1.1992188   PASS
    10 (staged, above kink)  analytical=1.2        numerical=1.1992188   PASS
    09 (row 1, below kink)   analytical=1.1994476  numerical=0.0         FAIL

Read the FD column: rung 09's numerical gradient is 0.0, which is CORRECT — the forward really
does clamp row 1, so perturbing A[1][0] does not move f.  The analytical side returns
1.1994476, which is the UN-ACTIVATED answer (the same value rung 08 gets where g'=1).  So the
forward fuses correctly and the backward propagates as though g' were 1 everywhere instead of a
step function.  That is precisely the failure rung 09's header predicted and chose its probe
point to catch, by colliding deliberately with 145/09.

AND NOTE WHAT 08 AND 10 DO NOT PROVE.  Both probe where g' = 1, so an activation-ignoring
backward passes them too.  Their green is necessary, not sufficient — which is the whole reason
09 exists.  When the VJP lands, rung 10 likely wants a below-kink twin for the same reason.

SUITE STATUS 2026-08-15, with everything above in place:

    E2E forward          995/995
    E2E --differentiate  995/995
    Negative             213/213

errors/07's refusal is IN.  Note it became urgent the moment map-elements! started working: the
rung used to fail with "Unsupported form MAP-ELEMENTS!" (wrong message, right outcome), and once
the form existed the same kernel COMPILED and produced a silently wrong matmul.  The check is
narrow on purpose — only a map on THE ACCUMULATOR is refused (the mmts C-tile itself, or a
via-tile accum binding inside the reduction body), so a legitimate per-step map on some other
register tile is untouched, and rungs 03 and 10 (whose maps are in the :epilogue) are unaffected.

REMAINING: rung 11, the fused-vs-cuBLAS benchmark, which is the endeavour's real definition of
done; rung 01's MMA_CORRECT on any Ampere-or-later card (nvcc is not available on the dev box);
and the fold of everything out of overlays/crisp-compiler-overlay.lisp into src/.

A NOTE FOR THE FOLD.  `return` is SHADOWED in :crisp.compiler — it is Crisp's RETURN macro, not
cl:return, and an escape written with it compiles into a call to the nonexistent function
CRISP.COMPILER::EXPLICIT-RETURN.  That cost one debugging cycle here and was nearly repeated a
second time in %mmts-accumulator-map-target, which is why both walkers use SOME/MAPC rather than
an escape.  It belongs on the documented gotcha list beside `char`.


A GENERAL AD GAP FOUND ON THE WAY: `funcall` is not differentiable
------------------------------------------------------------------

Measured, not inferred (probe kernels in put_temp_files_here/150-vjp/):

    (set! (~ C i) (funcall #'relu7 (~ A i)))   -> backward FAILS to compile:
                                                  "Function FUNCALL is not differentiable."
    (set! (~ C i) (relu7 (~ A i)))             -> PASS [l0] analytical=1.0 numerical=1.0 diff=0.0

So the AD engine walks a DIRECT call into a user function happily — including through relu's
`if` kink, which is the exact shape this endeavour needs — and has no rule for the indirect
form.  This is NOT specific to 150.  Filed as BUG 045.

CORRECTION, recorded because it was written here wrongly first: the obvious follow-on worry —
that store-tile's `:transformF` is in the same boat, since its lowering builds a funcall — is
FALSE.  Both 111/08 and a float twin of it compile clean under --differentiate.  The claim was
checked instead of reasoned about, which is the 030-sweep lesson; the confirmed blast radius is
only a hand-written `funcall` in a differentiable data path.

CONSEQUENCE FOR 150, already applied: map-elements! now lowers its call DIRECTLY, reading the
name off the `#'FOO` it was given, instead of routing through funcall.  Forward stayed 10/10
with byte-identical on-metal numbers.  It does not fix rung 09 — the AD walk sees the
source-level (map-elements! V #'f) form, not the lowering — but it removes a guaranteed
blocker from the path the VJP will have to emit into.


THE VJP'S ONE HARD PROBLEM: the map is IN PLACE
------------------------------------------------

The chain rule needs   adj[e] *= f'(P[e])   where P is the PRE-activation value.  But
map-elements! overwrites the fragment, so after the forward runs P is gone, and a backward that
replays the forward's statements (149) replays the map too and lands on f(P), not P.

Three ways out, and the choice should be deliberate rather than defaulted into:

  (a) RECOMPUTE P in the backward — re-run the reduction into scratch, apply f' from that.
      Self-contained and correct at any shape; costs a second MMA.  The via-tile VJP's scalar
      lowering already sets the precedent of "correct-but-slow is the right default".
  (b) REPLAY UP TO, BUT NOT INCLUDING, the map — cheapest if 149's replay can be told where to
      stop.  Needs a look at whether the replay seam admits a cut point.
  (c) SAVE P in the forward — rejected in 149 for good reasons (it grows the forward's
      signature, which propagates into hoist codegen, launch argument lists and both
      VERIFY-AUTODIFF runtimes).  Recorded here only so it is not rediscovered.

CONFIRMED — the `_GRAD` twin is exactly what the VJP needs, and it already exists.  Compiling a
kernel that calls a user function directly mints, with no prompting:

    define spir_func float @shifted_relu_7_float(float)                    ; the forward
    define spir_func float @shifted_relu_7_grad_float_float(float, float)  ; (primal, seed) -> d_primal

Its body recomputes the function's own internals (`y = x - 7`, `y > 0`) from the primal input,
so the VJP needs to supply only (primal-element, incoming-adjoint) and gets the outgoing adjoint
back.  The Crisp-level name is `<NAME>_GRAD` (src/autodiff.lisp:2553).  Both twins are present
in rung 09's backward module ALREADY — nothing new has to be generated.


WHAT RUNG 09'S BACKWARD ACTUALLY CONTAINS (measured, and better news than feared)
----------------------------------------------------------------------------------

    CooperativeMatrixLengthKHR inside the BACKWARD kernel : 0
    CooperativeMatrixLengthKHR inside the FORWARD kernel  : 1

So the map is not replayed-then-mis-differentiated; it is **absent from the backward entirely**.
The walk skips the form, and the adjoint runs straight from the C_GRAD seed into the MMA VJP:

    load C_GRAD -> c-tile_adj        (the seed)
    ... a-tile_bwacc / b-tile_bwacc MulAdds ...      (dA, dB)
    atomicrmw fadd                                   (gradient scatter)

with no activation anywhere in between.  That is a CLEANER starting point than the alternative:
there is no replayed map to fight, and the fix is purely additive — insert the adjoint step
between the seed and the MMA VJP.

THE PLAN (option (a), recompute):

  1. A new pairwise primitive, `%map-elements-vjp!` (adj-target, primal-target, #'F_GRAD),
     lowering exactly like map-elements! but walking TWO fragments in lockstep:
     `adj[i] <- F_GRAD(primal[i], adj[i])`.  PTX unrolls fieldwise, SPV loops with two
     OpAccessChains.  Self-contained and reuses everything already built.
  2. A VJP for MAP-ELEMENTS! that finds V's producing statement in `:flat-anf` (the same way
     %vjp-store-fragment and %mma-ad-tile-source-map resolve things), re-emits it into a fresh
     tile to recover the pre-activation P, then emits the pairwise update.

Step 1 is self-contained; step 2 is the delicate half, because it re-emits a producer.

STEP 1 IS DONE AND IN THE OVERLAY.  STEP 2 IS DIAGNOSED BUT NOT LANDED — the attempt is saved
at put_temp_files_here/150-vjp/append3.lisp + append4.lisp and reverted from the overlay so the
tree stays at 10/10 forward, 9/10 differentiate.  Two findings from it, both worth keeping.

FINDING 1 — `return` is SHADOWED in :crisp.compiler, and the symptom names nothing useful.
The first attempt used (return ...) to escape a dolist.  In that package `return` is Crisp's own
RETURN macro (src/macros.lisp:80-84), expanding to (explicit-return VALUE), so the escape became
a call to a function that does not exist:

    The function CRISP.COMPILER::EXPLICIT-RETURN is undefined.

That message names neither the function it happened in nor `return`, and it fires BEFORE any
logging in the VJP can run — which is what made it look like a problem with the emitted source
rather than with the code emitting it.  Diagnosed by adding a log:info and observing it never
fired at all.  This belongs with the already-recorded `char` shadowing gotcha; `return` is the
second member of that list.  Fixed by using FIND-IF instead of an escape (append4.lisp).

FINDING 2 — the real blocker is SCOPE, and it has a clean fix.  With the shadowing fixed, the
VJP emits exactly the intended form:

    (PROGN
      (LET ((C-TILE_PRIMAL (MAKE-REGISTER-TILE FLOAT (16 8) 0.0)))
        (MMA-ACCUMULATE-VIA-TILE (16 8 8) C-TILE_PRIMAL A B)
        (%MAP-ELEMENTS-VJP! C-TILE_ADJ C-TILE_PRIMAL (FUNCTION DOUBLE-VAL_GRAD)))
      <core backward>)

and then fails with `Unknown variable C-TILE_ADJ`.  The reason: C-TILE_PRIMAL is bound by the
VJP's own inner LET, while C-TILE_ADJ is bound by the walk in an OUTER scope.  %explode-register-
tiles builds its `tiles` alist per-LET, so the inner explosion knows only the primal and the
outer knows only the adjoint.  The %MAP-ELEMENTS-VJP! clause requires BOTH in one alist, so it
never fires, and the whole-tile name survives to codegen where only $F0/$F1 exist.

THE FIX, for whoever picks this up: give %map-elements-vjp! an optional FRAGMENT INDEX argument.
An explosion that can resolve only one of the two operands rewrites that side to its fragment
and records the index; the other explosion, running at its own level, uses the same index for
its side.  That lets the form be rewritten in two passes instead of demanding both names at
once.  Nothing else about step 2 is in doubt — the chain rule, the recompute-P choice, the
_GRAD twin and the emitted shape are all confirmed correct.

Everything lives in overlays/crisp-compiler-overlay.lisp pending a fold into src/ — note the
slot-reuse caveat recorded there for the :map node.

--- earlier status, kept for the record ---

8/10 green, and rungs 04 and 05 are verified ON METAL (BMG).

    rung 02   BUFFER c: 22 36 20 ...     hand-predicted 11,18,10 x2  = 22 36 20
    rung 04   BUFFER c: 0 6 0 ...        hand-predicted relu(x-12)   = 0 6 0
    rung 05   BUFFER c: -0.5 6 -1 ...    hand-predicted leaky(x-12)  = -0.5 6 -1

Every digit matches the arithmetic derived in rung 04's header before any code was written, which
validates the lowering, the threshold placement AND the fill-pattern analysis in one shot.  Rung
05 is the thesis: an activation the compiler has never heard of, carrying its own if/else,
fused into the register-resident epilogue and correct on hardware.

DONE: the PTX fieldwise path (rung 01, verified in emitted PTX — four `add.rn.f32` after the
mma.sync, zero call instructions, so the callee is fully inlined); the SPV component-loop path
(rungs 02/04/05); the arity refusal (errors/06).
REMAINING: the register-TILE path (rungs 03 and 10 — currently `Unknown variable C-TILE`, because
a tile is exploded into per-fragment vars and the body rewriter does not yet know this form);
the partial-sum refusal (errors/07); the AD rungs (08/09/10, which need the runner's
--differentiate and have not been exercised yet).

Everything lives in overlays/crisp-compiler-overlay.lisp pending a fold into src/ — note the
slot-reuse caveat recorded there for the :map node.

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

  CONFIRMED 2026-08-14 by spike, against our own bin/llvm-spirv.exe (LLVM 22.0.0git).  The
  idiom, and the disassembled proof, are recorded below under "The SPV element-access idiom".

**The moment you leave elementwise, that breaks.**  Bias-add needs each register's COLUMN index.
Row-wise max / softmax needs cross-lane reduction.  Both require committing to a documented
per-vendor fragment→coordinate map, and on SPV the abstraction is opaque BY DESIGN, so it may not
be portably expressible at all.  145 also left us [[mma-fragment-layout-untestable-by-roundtrip]]:
that map cannot be validated by round-tripping.

Bias-add is the most-requested companion to ReLU in real epilogues, so it will be asked for in
week one.  It is P4, and it does not gate P0-P3.


The SPV element-access idiom — CONFIRMED
-----------------------------------------

This was the one genuinely unknown piece of the design: whether our llvm-spirv path can express
per-component access on an opaque cooperative matrix at all.  It can.  Spiked directly against
bin/llvm-spirv.exe (LLVM 22.0.0git) with a hand-written module; artifacts in
put_temp_files_here/150-spv/.

THE IDIOM.  A coop matrix is an LLVM TARGET EXTENSION TYPE,
`target("spirv.CooperativeMatrixKHR", float, 3, rows, cols, use)`, and ops are calls to
specially-named `__spirv_*` externals that the translator lowers.  Two more of those give
element access:

    %len = call i32 @__spirv_CooperativeMatrixLengthKHR(<coop matrix value>)
    %ep  = call ptr @__spirv_AccessChain(ptr %matrix_alloca, i64 %idx)
    ; then an ordinary load / arithmetic / store on %ep

THE HAPPY ACCIDENT that makes this cheap: our codegen ALREADY places each tile fragment in an
`alloca` of the coop type, with load/store around it —

    %"c-tile$f0" = alloca target("spirv.CooperativeMatrixKHR", float, 3, 8, 16, 2), align 8

which is exactly the pointer `OpAccessChain` needs.  No restructuring required.

THE PROOF, from `llvm-spirv --to-text` on the spike:

    CooperativeMatrixLengthKHR 10 20 19
    AccessChain 21 24 17 23
    Load 9 25 24 2 4
    FMul 9 27 25 26
    Store 24 27 2 4
    CooperativeMatrixStoreKHR 7 28 29 30 0

Both builtins became NATIVE INSTRUCTIONS.  That distinction is the whole point of checking: a
`__spirv_*` call that survives translation as a call gets Import linkage and fails at device
link with L0 UNLINKED — the trap this project already hit once with the SPIR-V builtins.

ONE CONSEQUENCE FOR THE LOWERING, and it makes SPV differ from PTX.
`OpCooperativeMatrixLengthKHR` yields a RUNTIME value: how many components an invocation holds
is implementation-defined and deliberately not a compile-time constant.  So the SPV map must be
a LOOP over [0, len), where the PTX map is an unrolled fieldwise rewrite.  That is not a
limitation to work around — it is the same fact that makes elementwise fusion portable in the
first place (we never learn which logical element we hold, so we cannot accidentally depend on
it), and it is why layout-aware epilogues stay out of scope.


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

NVIDIA TWINS (20-25) — added 2026-08-15, numbered from 20 to leave rungs 11/12 free.

Rungs 02-05 and 08-10 are all BMG-shaped, so on an NVIDIA pod they skip and only rung 01 ever
touched hardware.  These are their PTX counterparts.  Shapes diverge genuinely — NVIDIA tf32
(16 8 8) vs Intel XMX (8 16 8) — which is why they are separate files, the same split as
135/03 vs 135/04.

  20  tile map in :epilogue, scale x2, MMA_CORRECT   (twin of 03)
  21  thresholded relu on acc, BUFFER c: 0 0 6       (twin of 04)
  22  user leaky activation, BUFFER c: -0.5 -1 6     (twin of 05)
  23  gradient FLOWS above the kink, expect 0.28     (twin of 08)
  24  gradient BLOCKED below the kink, expect 0.0    (twin of 09)
  25  staged :epilogue gradient, expect 0.28         (twin of 10)

NOTE THE PERMUTED NUMBERS IN 21/22.  Their pre-activation row is 11, 10, 18 where the Intel
twins' is 11, 18, 10 — the same three values reordered, because NVIDIA's canonical B is
COL-major so the buffer index is k + 8j instead of 8k + j.  That is the layout difference
showing up in the expected output, and it is why the values were re-derived rather than copied.

THE AD TWINS DECLARE B ROW-MAJOR, deliberately diverging from 21/22 and following 145/10, the
existing PTX autodiff twin.  With col-major B the mn cross-term makes the output rows overlap
in value, so no row sits cleanly on one side of a kink — which is what the whole above/below
design depends on.  Recorded here because it is the first thing to suspect if 23-25 return
wrong numbers: see rung 23's header for the ordered check-list.

23-25 ARE NEW GROUND.  145 P7 established NVIDIA parity for MMA FORWARD (MMA_CORRECT on a
Blackwell pod); no MMA kernel has previously had its GRADIENT checked against a number on
NVIDIA.  The emitted backward looks structurally right — 7 call sites for the _GRAD twin,
8 mma.sync (more than the backward alone needs, so the recompute prefix is present) and 10
setp/selp for the inlined step function — but structure is not a number.

FINAL POD RESULT, H100 80GB HBM3, 2026-08-15 — ALL PHASES GREEN:

    specs (binary)                     ok
    specs (binary, --differentiate)    ok
    negative specs                     ok

So the ladder is complete on BOTH vendors, forward and backward, on real hardware.  The
corrected 21/22 expectations (4 0 3 and 4 -2 3) were confirmed by that run, which also
validates the back-derivation from the first run's measured output.

The detail from the first pod run, kept because it is where the interesting evidence is:

    23-relu-gradient-flows-ptx     PASS [cuda]  analytical=0.27989197  numerical=0.27978516
    24-relu-gradient-blocked-ptx   PASS [cuda]  analytical=0.0         numerical=0.0
    25-staged-epilogue-gradient    PASS [cuda]  analytical=0.28        numerical=0.27978516

That is the first time an MMA kernel's GRADIENT has been checked against a number on NVIDIA —
145 P7 established forward parity (MMA_CORRECT) and stopped there.  Both sides of the kink, and
through a staged K-loop, on hardware, with no compiler change needed for the vendor switch.

Rung 20 (MMA_CORRECT) passed.  Rungs 21 and 22 FAILED, and the cause was MY ARITHMETIC, not the
compiler: I predicted a col-major index for B (k + 8j) when the indexing actually in use is
ROW-MAJOR (8k + j).  Back-derived from the measured output and confirmed exactly —

    pre-activation row 0 = 16, 8, 15   (not the predicted 11, 10, 18)
    21  relu(x-12):        16->4   8->0    15->3     actual: 4 0 3
    22  leaky(x-12, 0.5):  16->4   8->-2   15->3     actual: 4 -2 3

both expectations corrected.

THE LAYOUT LESSON, worth carrying: declaring b-mat :col-major selects the MMA VARIANT; it does
not change the stride the test harness lays B out with, which is row-major.  Nothing is
inconsistent — kernel and host reference use the SAME strides, which is exactly why rungs 01
and 20 report MMA_CORRECT — but a HAND-COMPUTED expectation has to follow the strides actually
in use, not the declared contiguous-term.  The AD twins (23-25) were unaffected because they
declare B row-major already, for an unrelated reason (see above).

Note this is the failure mode a BUFFER expectation is FOR: it is the only check in the ladder
that can disagree with the host reference, and here it caught a wrong prediction while
MMA_CORRECT next door was perfectly happy.

LOCAL STATE with the twins in: 16/16 forward, 16/16 --differentiate, with 4 CUDA hoist phases
and 3 CUDA VERIFY-AUTODIFF phases skipping for want of nvcc.  Those 7 are what a pod run adds.

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
