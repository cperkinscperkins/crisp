Endeavor 146 — MMA Autodiff, Continued
======================================

145 closed on its declared scope, not on the general claim.  That was a deliberate call:
the overlays had grown into the thousands of lines and there was a vacation coming, so the
right move was to cauterize and revisit.  This is the revisit.

145 was also where the method went wrong before it went right.  The failure mode, stated
plainly so we do not repeat it: **we treated each scheduling optimization as a new
mathematical primitive needing its own chain rule.**  Every time an optimization's lowering
did not survive the ANF-transform / chain-rule-replacement walk, the response was to dive
into that lowering.  More and more tests acquired `SKIP-WITH[--differentiate]` labels.  The
turn came late, with the **VJP registry** — the lowering is chosen *inside* the VJP, so it
cannot leak out as a language contract — and that one change retracted three separate claims
that had been written down as fundamental limits of the language.

This endeavor is the rest of that turn.


The thesis
----------

> **Warp specialization, pipelining, prefetch, rings, TMA and wgmma do not change what the
> kernel computes.  They change *when and where the bytes arrive*.  The math is still
> C = A·B.**

There is no wgmma VJP, no warp-specialization VJP, no prefetch VJP.  There is **the
tile-level VJP that 145 already shipped and gradient-checked four separate ways on metal.**

So every "forward-only" skip in the table below should reduce to the same shape of work:
make the differentiator see *through* the schedule to the math, then reuse the VJP that
already exists.  Where that fails, the defect is that a scheduling construct leaked into
the differentiator's view of the math — **not** that the construct needs its own derivative.

This is the forest.  When a task starts to feel like inventing a derivative for a *staging
strategy*, we have walked into the trees and should stop.


The skip inventory
------------------

There are ~160 `SKIP-WITH[--differentiate]` files in the suite.  Most are pre-MMA
(metadata, hoist, IR-text, signature tests) and are correctly skipped forever.  The ones
that matter triage into five buckets.

**Phase 0 has been run** (2026-08-08, `put_temp_files_here/triage-146.sh`, results in
`put_temp_files_here/triage-146-results.md`).  Every Bucket B and D spec was compiled with
its own target flags plus `--differentiate`, from a scratch copy.  The measured columns
below are real; the bucket assignments have been corrected where the measurement disagreed
with the hypothesis.

### Bucket A — correctly skipped forever (~20)

Negative tests, arch gates, dispatch-shape specs, hoist/metadata specs, kernels with no
`&out`.  The `COMPILE-WITH … FAIL` *is* the assertion, or there is genuinely nothing to
differentiate.

  137/01, 137/02 (arch gates) · 142/02, 142/03, 142/13 (negative) · 145/07 (the
  `--differentiate` behaviour is the test) · 132/07 (compile-time budget error) ·
  089/19-26 (dispatch shape) · 109/15, 109/16 (grid semantics) · 116/04, 116/07 ·
  120/06 (no `&out`) · 130/11, 130/12

**Action: none.**  Do not spend time here.  These are not debt.

**Phase 0 moved three specs INTO this bucket:**

- **145/03, 145/04** — hypothesised as stale phase markers; they are not.  They fail on a
  deliberate, well-written error saying `load-fragment-acc` is a FRAGMENT-level form with no
  backward.  Only the *reason string* is stale.  **But see the open question below** — that
  error text asserts a claim 145 later retracted.
- **144/01** — a negative test (`COMPILE-WITH[--hardware-profile=small-regs]: FAIL "register
  budget"`).  Its reason string is still false and should be corrected, but there is no
  differentiate pass to un-skip.

### Bucket B — "forward-only" claims about scheduling (22)

Every one of these carries a reason string that makes a claim about the *language* —
*"wgmma is forward-only MMA"*, *"warp specialization is forward-only control flow"*,
*"forward-only prefetch pipeline"* — when the true claim is about **one lowering**.  This is
the same category of error 145 retracted three times.

| specs | count | reason string as written | measured |
| --- | --- | --- | --- |
| 139/01, 01b, 02, 03, 04, 05, 06 | 7 | "warp specialization is forward-only control flow" | 4 compile |
| 140/00, 01, 02, 03 | 4 | "wgmma is forward-only MMA" | 1 compiles |
| 142/00, 01, 10, 11, 12, 14 | 6 | "forward-only block load / MMA / ring / prefetch" | 0 compile |
| 144/01, 02, 03, 04 | 4 | "wgmma is forward-only (no autodiff)" | 4 compile |
| 126/20 | 1 | "wgmma is forward-only MMA" | compiles, 46 KB `_grad.ptx` |

126/20 is the reason to sweep by *reason string* and not by directory — it sits in an
endeavor that has nothing to do with MMA and was found only by grepping the text.

**Measured: 10 of 22 already compile under `--differentiate`**, several emitting 46-87 KB
backward artifacts.  140/00 emits a 46 KB `_grad.ptx`; 144/03-04 emit 72-87 KB.  The claim
*"wgmma is forward-only MMA"* is false on its face.

### The four gaps — and NOT ONE of them is about MMA math

The 12 failures cluster into exactly four causes:

| # | gap | specs | error |
| --- | --- | --- | --- |
| 1 | Constructors not registered gradient-inert | 140/03, 142/10, 142/12 | `MAKE-WGMMA-ACCUMULATOR` / `MAKE-REGISTER-TILE-RING is not differentiable` |
| 2 | `rem` has no AD rule | 140/01, 140/02 | `Function REM is not differentiable` |
| 3 | Sub-function walk does not reach warp-role bodies | 139/02, 05, 06 | `Function CONSUMER is not differentiable` |
| 4 | Adjoint for a tile view has nowhere to land | 142/00, 01, 11 | `Unknown variable A-TILE_ADJ` |

`CONSUMER` is a user-defined sub-function — a sub-function differentiation gap wearing a
warp-specialization costume.  `REM` is integer remainder in index arithmetic.  `A-TILE_ADJ`
is the same hole as 135/09's `C_ADJ`.

**This is the thesis confirmed by measurement.**  Four ordinary AD gaps, ~13 specs, zero of
them a property of tensor cores.  Gap 1 has an exact precedent: 145 P1 registered shape
queries as gradient-inert.  Gap 2 is a sibling of 132/08's missing `to-float`.  Gap 4 is
Bucket E's 135/09.

### Bucket C — honestly blocked, with a named exit criterion (5)

| spec | blocked on |
| --- | --- |
| 137/03, 137/05 | sm_90a TMA; `VERIFY-AUTODIFF` runs on SPV/L0, so gradient *values* are unreachable here |
| 138/04, 138/05 | the above, **and** BUG 040 on the Intel analogue |
| 145/19 | BUG 040 |

These skips are well written.  137/03 in particular cites the exact trap — *"135/01
compiled with correct-looking atomics and still returned 0.0"*.  Leave them skipped until
their stated criterion is met; do not weaken them into "it compiles, ship it."

### Bucket D — stale phase markers (17)

These cite sub-steps and phases of endeavors that **closed in May**.  The work they are
waiting for has shipped.

| specs | count | reason string, now false | measured |
| --- | --- | --- | --- |
| 111/01, 03, 05, 06, 09, 10, 11, 12, 13 | 9 | "AD rules for load-tile-at land in sub-step 1c" | **9/9 compile**, 14-29 KB `_grad.spv` |
| 113/01, 02, 03, 04 | 4 | "AD pre-rewrite … lands in phase 1" / "covered in phase 4" | **4/4 compile** |
| 116/05 | 1 | "AD pre-rewrite for load-local / store-global async lands in phase 1" | **compiles**, 64 KB `_grad.ptx` |
| 145/05 | 1 | "the backward rule is P3b" — shipped | **compiles**, 39 KB `_grad.spv` |
| ~~145/03, 145/04~~ | 2 | reclassified to Bucket A — see above | fail by design |

`%load-tile-at-bwd` has existed since 111 (src/autodiff.lisp:991-1027).  **15 of 17
compile**, and the two that don't were misfiled.  This is the *foundation layer* the Bucket
B scheduling claims rest on, and it has quietly worked since May.

Five of these specs declare no `TEST-WITH` at all (their assertions ride on `TEST-HOIST` /
`COMPILE-WITH` / `EXPECT-STDERR`), so the first triage pass compiled them for the GENERIC
target, which emits no device artifact.  Re-run against explicit targets — 113/04, 116/05,
139/01b, 144/01, 144/02 — **all five compile and emit real backward artifacts.**

### Bucket E — real AD gaps, not MMA (2)

| spec | gap |
| --- | --- |
| 132/08 | `to-float` has no AD rule (int→float conversion); already noted in 145 P1 |
| 135/09 | `C` is a reinterpreted view, so its adjoint has nowhere to land — "Unknown variable C_ADJ".  Views at the AD boundary. |

Genuine holes, genuinely out of scope for an *MMA* endeavor.  Record them; decide later
whether they earn their own endeavor.  Note that Phase 0 showed Gap 4 (`A-TILE_ADJ`) is the
same defect as 135/09 — so this bucket is no longer purely out of scope, it *intersects*
Bucket B.


Open question — a retracted claim may still be in the compiler's mouth
----------------------------------------------------------------------

145/03 and 145/04 fail with:

> `LOAD-FRAGMENT-ACC is a FRAGMENT-level MMA form and has no backward: on a single fragment
> one of the two backward GEMMs (dA = dC.B^T, dB = A^T.dC) always violates the hardware shape
> contract.`

But 145 later **retracted** "no fragment-level backward is possible" as an artifact of one
chosen lowering, and `145/13-fragment-vjp-bmg` passes.  So either the retraction never
reached `load-fragment-acc`, or this message overstates a limit that applies only to that one
form.  Either way the compiler is currently giving user-facing advice that the endeavor which
wrote it no longer believes.

**Resolve this before touching anything else in 145.**  It is the exact failure mode this
endeavor exists to stop: a lowering detail hardened into a language claim.


Method — three rules
--------------------

These exist because 145 violated all three at some point.

### Rule 1 — compiling under `--differentiate` is NOT the deliverable.  A number is.

"It differentiates!" feels like progress and is not.  A kernel can compile, emit a backward
with plausible-looking atomics, and still return a gradient of 0.0 — that is exactly what
135/01 did.  **Done means a numeric on-metal check**: `VERIFY-AUTODIFF` with a finite
difference, or a hand-computed analytical expectation.

If no numeric check is reachable on hardware we own, **the test stays skipped with an
honest reason naming the exit criterion, and we move on.**  That is a *completed triage
outcome*, not a failure.  This is the rule that stops the grinding.

### Rule 2 — when stuck, the question is "which VJP is missing?", never "how do I teach the ANF pass about this construct?"

If a fix requires the differentiator to understand `with-warp-specialization`, or a ring
slot, or a prefetch queue, **stop.**  That is the trees.  The VJP registry exists precisely
so the lowering stays inside the VJP and cannot become a language contract.  Register a VJP
for the math instead.

### Rule 3 — one spec at a time, closed before the next.

No batch phases.  145's phases were too wide and that is how the forest got lost.


Plan
----

### Phase 0 — triage.  DONE 2026-08-08.  Changed no compiler code.

Hypothesis was "most of Bucket D un-skips on the spot, and a meaningful fraction of Bucket B
already compiles."  Measured: **Bucket D 15/17 compile, Bucket B 10/22 compile**, and the 12
Bucket B failures reduce to four generic AD gaps, none of them about MMA.

Column 2 (real gradient flow) remains OPEN — a `_grad` artifact was recorded as a
first-order proxy only.  Per Rule 1 that is a candidate, not a verdict.

Two small items to sweep up while here:

- **145/07 is the one failing spec** (18/19 with `Filter=145`).  The kernel is believed
  fine and the directives mis-written.  Note the stale `07-…_grad.spv` artifact on disk for
  a spec that is supposed to *fail* under `--differentiate` — that may be the tell.  Low
  priority, but it lives in this endeavor.
- **`88-tmp-*` scratch files** are checked into `tests/spec/145-mma-autodiff/`
  (`88-tmp-inline_grad.spv`, `88-tmp-ringfwd*`, `88-tmp-subfn_grad.spv`).  Delete.

### Phase 0b — API drift inventory.

145 changed user-facing surface without documenting all of it: `src/macros.lisp` +103 and
`src/mma.lisp` +690 across the merged branch.  Do this **mechanically**, not by scouring:
enumerate top-level defining forms added or changed in the 145 merge, regenerate
`docs/reference.md`, and report what is new, what changed shape, and what has no docstring.

### Phase 1 — Bucket D.  DONE 2026-08-08.

All 15 candidates un-skipped.  **Full suite: 963/963 under `--differentiate`**, and
962/963 on the default pass with only the pre-existing 145/07 failure.  No regressions.

| specs | outcome |
| --- | --- |
| 111/01, 03, 05, 06, 09, 10, 11, 12, 13 | un-skipped, PASS, each emits `_grad.spv` |
| 113/01, 02, 03, 04 | un-skipped, PASS |
| 116/05 | un-skipped, PASS |
| 145/05 | un-skipped, PASS — an **MMA** spec now differentiating |

**On the standard of proof, stated honestly.**  Rule 1 demands a number, and these 15 did
not each get one.  They are *structural* specs — most of 111 moves `ulong` data, and an
integer copy kernel has no float gradient to finite-difference.  What they assert is that
the tile load/store forms survive the AD walk and produce a well-formed backward.

The *numeric* proof for this path already exists, in their float siblings that were never
skipped and pass in the same run:

- `111/15-ad-tile-scale-1d` — `VERIFY-AUTODIFF` analytical=2.0 numerical=1.9989012
- `111/14-ad-identity-via-tile-1d`, `113/04-ad-async-roundtrip` — same directive

So the claim being made is: *the tile AD path is numerically proven by 111/14-15 and
113/04, and these 15 specs extend the structural coverage over it.*  That is a weaker claim
than "each has a numeric check," and it is the true one.

A side effect worth noting: `sed -i` in Git Bash rewrites CRLF files to LF.  Four of the 111
specs are CRLF and came out as 40-line whitespace diffs.  Use the byte-preserving editor for
these, not stream edits.

### Phase 1b — the specs that already worked.  DONE 2026-08-09.  TEN un-skipped.

Phase 0 measured 10 of Bucket B's 22 as ALREADY COMPILING under `--differentiate`.  That sat
in the results table for the whole endeavor while attention went to the ones that FAILED.
Re-verified against HEAD — all ten still compile — and un-skipped:

  139/01, 01b, 03, 04 · 140/00 · 144/01, 02, 03, 04 · 126/20

Every one carried a reason asserting that warp specialization or wgmma is forward-only.  None
of that was ever true, and the endeavor had already disproved it elsewhere (140/03 for wgmma,
142/01 with a number on metal for MMA).  **This was the cheapest work in the endeavor and it
was available from day one.**

On the standard of proof: these are IR-grep, `EXPECT-STDERR` and negative specs.  Un-skipping
asserts that the spec's own check still holds with a backward in play — NOT a gradient value.
The reasons say so individually.

Verified they actually RUN rather than silently still skipping (a skipped spec also counts as
passed in the summary — the count alone proves nothing).  **963/963 differentiate, 962/963
default.**

> **METHOD NOTE.**  Triage produces two lists: what is broken and what already works.  The
> second list is the cheaper one and it is the easier one to forget, because nothing about it
> demands attention.  Re-read Phase 0's table before starting each phase, not just when a
> phase fails.

### Phase 1c — overlay folded back into src.  DONE 2026-08-09.

`overlays/crisp-compiler-overlay.lisp` had reached ~1360 lines / 33 definitions — the same
trajectory that caused 145 to be closed early.  Folded into `src/autodiff.lisp` and the
overlay is empty again.  Net: **+468 / -18** in src.

What moved, and how:

| kind | count | handling |
| --- | --- | --- |
| dead / duplicate | 2 | `%mma-ad-devirtualize-extent` (zero callers, left over from the abandoned per-site approach) and `%mma-vjp-scalar-lowering` (byte-identical to src after the consolidation restored it) — **dropped, not moved** |
| new helpers | 13 | copied into src, gathered under one ANF-NORMALIZATION section header |
| replaced an existing src defn | 2 | `%mma-ad-adj-init`, `%backward-skip-fn-p` |
| **wrappers** | 4 | **merged into the real function bodies** |

The wrappers were the awkward part and are worth recording.  In an overlay,

    (defvar *orig-foo* (symbol-function 'foo))

then redefining `FOO` is a clean way to extend a 500-line function without restating it.  It
does **not** survive copy-paste into src — there is no "original" left to capture.  Each had
to be merged by hand:

- `generate-backward-walk` -> one `setf` of `flat-anf` at entry through a new combined
  `%ad-normalize-anf-for-backward`, plus the ring fixup at the return site.  Two lines into a
  500-line function instead of restating it.
- `%active-scalar-vars` -> `REM`/`MOD` added to the arithmetic edge-table entry.
- `%handle-single-value-backward` -> a `%ad-rem-or-mod-form-p` clause at the head of the cond
  (kept separate from the `#'eq` member list, which tests symbols read in *this* package).
- `%backward-skip-fn-p-145p1` -> the three warp builtins added to the thread-coordinate list.

A note about this now lives in the overlay header so the next person reaches for the pattern
knowing the cost of unwinding it.

Verified after folding: **963/963 differentiate · 962/963 default · 211/211 negative ·
253/253 unit**, and every `VERIFY-AUTODIFF` numeric check still passes.

### Phase 2 — the four gaps.

One spec at a time within each gap (Rule 3), numeric proof or an honest skip (Rule 1), and
if a fix starts to require teaching the ANF pass about a scheduling construct, stop (Rule 2).

#### Gap 4 — register-tile adjoints.  DONE 2026-08-09.  142/00, 142/01, 142/11 un-skipped.

**Phase 0 mislabelled this one.**  It is not "view adjoints at the AD boundary"; it is a
register tile leaking a WHOLE-TILE reference into a backward that has no binding for it.
Proven by a forward-only probe with no differentiation anywhere:

    (let ((T-tile (make-register-tile float (16 8) 0.0)))
      (workgroup-stride T-tile (m k) (set! (~ T-tile m k) 1.0)))
    => Unknown variable T-TILE.

The AD walk is source-to-source over flat ANF and runs BEFORE semantic analysis;
`%explode-register-tiles` runs later, from the LET analyzer.  The backward replays the
forward's BINDINGS but not its STATEMENTS, and a register tile's binding does not survive
into that scope.  A scratch tile's does — which is exactly why 145 never saw this: its specs
staged operands through `make-scratch-matrix` + `load-tile-at`.  142 Phase A introduced
register-resident operands via the `load-tile` overload.

Two defects, and the second one taught the real lesson:

1. **Adjoint allocation.**  `%mma-ad-adj-init` mirrored the forward constructor, so an
   OPERAND tile got a register-tile adjoint.  But every consumer indexes it as memory — the
   scalar lowering's `workgroup-stride` + `~`, the MMA fast path's `(store-tile da-reg a-adj)`
   destination, and the downstream `%load-tile-at-bwd` scatter.  Now: operand adjoints are
   scratch matrices, accumulator (C) adjoints stay register tiles.

2. **Extent reads — and DO NOT PATCH THESE PER SITE.**  A grid-coordinate load records its
   origin scaled by `(~ (extents~ TILE) i)`.  Three independent emitters put that into the
   backward (scalar lowering origins, `%mma-ad-transposed-stage`, `%load-tile-at-bwd`
   scatter), and a fourth would do it again.  The first attempt patched them one at a time
   and was the wrong shape.  **Replaced by ONE normalization pass** over the flat ANF going
   into `generate-backward-walk`: a register tile's extents are compile-time literals, so
   substitute them once and every emitter downstream is correct by construction.  Scoped to
   register tiles, so kernels without them see byte-identical input.

Gotcha worth keeping: the substituted literal must be `(to-ulong N)`.  `extents~` yields
ULONG and a Lisp integer reads as Crisp INT, so a bare literal gives
`Cannot operate on ULONG and INT`.

**THE NUMBER (Rule 1).**  142/01 is the register-resident twin of 145/12 — same
`f(A,B) = sum(A.B)`, same shapes, same Kt=8 and therefore the same scalar lowering, differing
ONLY in whether operands stage through GRF or SLM.  On BMG:

    PASS (A: analytical=1.2 numerical=1.1988525 diff=0.0011475086)

145/12 expects 1.2.  Same schedule-independent number, measured on metal.  That is the
endeavor's thesis as a measurement rather than an argument.

Suite after: **963/963 under `--differentiate`**, 962/963 default (only 145/07).

#### Remaining, cheapest blast-radius first

1. **Gap 1 — wgmma DONE 2026-08-09 (140/03 un-skipped); rings remain (142/10, 142/12).**

   *Not* "an inert constructor to register."  `MAKE-WGMMA-ACCUMULATOR` had no registration
   AND `WGMMA-ACCUMULATE-VIA-TILE` had no VJP — "wgmma" appeared ONCE in all of
   src/autodiff.lisp, in a comment.  The obvious fix was six registry lists plus a new VJP,
   and the next MMA instruction would want seven more.  **That is the mistake this endeavor
   exists to stop.**

   Done instead by canonicalizing wgmma to the sync MMA on the ANF entering the backward
   walk — the same seam Gap 4 established — so the ONE existing VJP supplies the derivative
   and every register-tile registry applies unchanged.  A backward is under no obligation to
   use the same instruction as its forward; that is the whole content of "the schedule is
   not the math".

   Three layers, each measured rather than guessed:

   | symptom | cause | fix |
   | --- | --- | --- |
   | `MAKE-WGMMA-ACCUMULATOR is not differentiable` | no registration anywhere | canonicalize to `make-register-tile` |
   | `accumulator tile D has no compile-time (M N)` | shapes hoisted to ANF temps (`(%ANF-T-1 (64 64))`); `make-register-tile` is on the ANF converter's opaque-arg list, wgmma is not | inline temps bound to literal integer lists — general, not wgmma-specific |
   | `only tf32 (16 8 8) is supported … got (64 64 32)` | wgmma's first arg is the WARPGROUP TILE shape, not an instruction shape; `%mma-via-tile-backward` passes the forward's shape through | substitute `%spv-mma-shape`, the accessor admissibility already uses |

   The normalization chain is now three ordered steps, all removing distinctions the
   derivative does not care about: inline shape temps → canonicalize wgmma → devirtualize
   register extents.

   **No numeric proof, deliberately.**  wgmma is sm_90a-only, `VERIFY-AUTODIFF` runs on
   SPV/L0, and there is no Intel analogue because wgmma does not exist on Intel.  140/03
   asserts that it differentiates and emits a backward (259 KB `_grad.ptx`), nothing about
   gradient values — those want a Hopper pod, exactly as 137/03 insists.  145/12 and 142/01
   are the numeric proofs that the underlying tile VJP is correct; 140/03 adds only that
   wgmma reaches it.

   **Rings: 142/10 DONE 2026-08-09.  142/12 blocked on an unrelated gap.**

   A ring of register operand tiles canonicalizes to a SCRATCH MATRIX RING — a ring is
   rank+1 scratch (138), so it is Gap 4's answer ("an MMA operand's adjoint is memory")
   one dimension up, in a form the engine has understood since 138.  Three further
   defects, all found by measurement:

   - **Ring-view extents.**  Gap 4's devirtualizer matches `(~ (extents~ SYM) i)`; a ring
     operand appears as `(~ (extents~ (ring-get SYM i)) j)` and never matched.  Scoped to
     rings that were REGISTER rings in the ORIGINAL anf — a genuine scratch ring's binding
     DOES survive into the backward, which is why 138 and 145/18 work, and rewriting theirs
     would change specs that pass for the right reason.
   - **Top-level rings get no adjoint.**  TWO places pair an adjoint with a forward
     allocation: `%augment-scratch-adj-bindings`, which knows the ring constructors but only
     runs on LET forms met during the walk; and the collection inside
     `generate-backward-walk`, which handles the kernel's top-level bindings and lists no
     rings at all.  A top-level ring therefore gets none.  Pre-existing, not introduced by
     142 — 138's and 145/18's ring specs simply never name one.  Ensured on the way out,
     the same shape as `%ensure-leaf-adj-bindings` in macros.lisp.
   - **Ring constructors must NOT go through `%promote-scratch-init-for-ad`.**  It opens
     with `%scratch-tensor-canonical-spec` and knows only the four scratch tile forms;
     handed a ring it yields the stub `(TENSOR FLOAT)`.

   > **METHOD NOTE — the expensive lesson of this endeavor so far.**  That last defect cost
   > FIVE speculative attempts, every one of them re-reading `Invalid incomplete type
   > specifier: (TENSOR FLOAT)` as a problem with the emitted CODE.  It was never the code:
   > the adjoint allocator was signalling while BUILDING it.  The reason it stayed hidden is
   > that `generate-backward-walk` logs its assembled AST from INSIDE itself, so everything
   > this overlay's wrapper does afterwards was invisible.  Adding one `log:debug` to the
   > wrapper found it immediately — the absence of `146:` lines on a failing compile, against
   > eight on a succeeding one, located the error inside the wrapper's own `let*`.
   > **Log the thing you are changing before changing it again.**

   **142/12 is NOT a ring problem.**  It now fails with
   `Type mismatch for operator '/'. Cannot operate on ULONG and INT.` on its runtime loop
   bound `(/ (inner-dimension A B) (to-ulong 8))` — a type-inference gap on a differentiated
   runtime loop bound.  Related to Gap 2 (`rem`) and 132/08 (`to-float`): integer/conversion
   arithmetic, not MMA.  Track it there, not here.

   **No numeric proof for ring-fed MMA gradients yet.**  142/10 is compile-only by design.
   142/12 was to be the metal twin and does not differentiate.  142/01 proves
   register-resident MMA numerically and 145/18 proves ring STAGING; their combination
   remains unproven on hardware, and this doc should not imply otherwise.
2. **Gap 2 — `rem`/`mod` get a REAL derivative.  DONE 2026-08-09.  Specs still NOT
   un-skipped (see item 3).**

   > **RETRACTED, same day: the first attempt added `REM` to `%backward-skip-fn-p`.**
   > That was this endeavor's own anti-pattern committed in miniature.  A skip-list entry
   > is a claim about an OPERATOR; the real claim was about one USE of it (integer index
   > arithmetic).  It made `rem` contribute zero gradient ALWAYS.  Worse, it was copied
   > from `MOD`, whose 138 entry carries what amounts to a written confession — *"a float
   > mod does have a derivative … its gradient would be silently zero … a real rule
   > belongs with the other math VJPs."*  That comment was read, quoted in the commit,
   > and the shortcut copied anyway.

   The engine already had the general path, in two parts:

   - `%active-scalar-vars` (:2518) is an EDGE TABLE deciding which operand positions
     propagate activeness.  Its header: *"Structural ints fall out as 'inactive' for free
     — no special-casing."*
   - `%handle-single-value-backward` (:412) routes `+ - * /` and the transcendentals to
     `%handle-math-and-trig-backward`.  **`REM`/`MOD` were simply absent from that list,
     and that was the only reason they errored.**

   `(rem li 8)` never needed an inertness declaration: `li` descends from thread ids, not
   kernel inputs, so it is already inactive.  Nothing flows because the OPERAND is
   inactive, not because the OPERATOR is dead.

   **The rule.**  `rem(a,b) = a - b*q` with `q = trunc(a/b)`:

       d/da = 1                   ->  a_adj += v_adj
       d/db = -q = -((a - v)/b)   ->  b_adj += -((a-v)/b) * v_adj

   `q` is recovered from the already-bound result `v`, so no `trunc` primitive is needed —
   and it is EXACT for integers, because `a - v` is exactly `b*q`.  Crisp does
   mathematically accurate derivatives for integer types too; the answer being trivially
   zero downstream is the activeness analysis's conclusion to draw, not this rule's
   assumption to make.  `MOD` shares the formula (floor vs trunc differs only on negatives;
   `q = (a-v)/b` holds either way).

   **`MOD` is removed from the skip list as well** — it has been silently wrong since 138.
   The caveat there is now deleted rather than repeated, because it has stopped being true.
   145/18 (ring, uses `(mod grid-k 2)`) still gradient-checks exactly: `analytical=1.0
   numerical=1.0 diff=0.0`.

   What legitimately belongs in `%backward-skip-fn-p` is NON-VALUES — allocators, barriers,
   shape queries.  An arithmetic operator with a real derivative never did.

   **But fixing `rem` did not un-skip either spec, and that is the finding.**  Both now
   fail one layer deeper:

       mma-accumulate-via-tile: cannot differentiate this tile multiply —
       the A operand A-TILE has no compile-time shape.

   In these kernels the operand is `(make-scratch-vector float 512)` filled ELEMENT BY
   ELEMENT with wgmma's swizzled core ordering:

       (set! (~ A-tile core) (~ A r gk))

   There is no `load-tile-at`, so the VJP has no staging source to recover, and the flat
   512 carries no (Mt Kt).  This matters more than it looks: the tile VJP reads operands
   from their GLOBAL SOURCE rather than from the staged tile, because a backward replays
   the forward's BINDINGS but not its STATEMENTS — so in the backward the staged tile is
   empty.  A hand-swizzled tile has no source mapping the VJP can invert.

   Do NOT paper this over by inferring (64 8) from 512.  The layout is swizzled, not
   row-major, so indexing it as a matrix would produce a confidently WRONG gradient —
   the exact silent-wrong-answer class 145 was burned by.

   **METHOD NOTE.**  Phase 0's four-gap taxonomy was built from FIRST errors only.  It is
   a taxonomy of symptoms, not of root causes, and a gap can have layers behind it (Gap 1
   had four).  Treat the remaining gap counts as lower bounds.

3. **Hand-staged tile operands** (140/01, 140/02) — measured 2026-08-09, blocker now
   isolated to ONE thing.  Skip reasons corrected; a design decision remains.

   **The warp builtins were never registered** (fixed).  `WARP-ID` / `WARP-LANE` /
   `WARP-COUNT` were missing from the thread-coordinate table at autodiff.lisp:3077-3084,
   which has held `GET-LOCAL-ID`, `GET-WORKGROUP-ID`, `SYNC-WORKGROUP` and ~30 others since
   the beginning.  They arrived with the 111/115 warp work and were simply never added, and
   that omission alone produced `Function WARP-LANE is not differentiable`.

   > This is the LEGITIMATE use of inertness, and worth contrasting with the `rem` mistake
   > made an hour earlier.  A thread coordinate is not a function of the kernel's inputs —
   > it is structural, like a shape query — so its derivative is EXACTLY zero.  That is the
   > mathematically accurate answer.  `rem`'s derivative is 1, so calling it inert asserted
   > something FALSE.  The table is the right home for genuine non-values; the skip list was
   > the wrong home for arithmetic.

   **The scatter-fill already differentiates.**  Measured directly by compiling 140/01's
   staging on its own: Crisp's generic `set!` / `~` backward reverses

       (set! (~ A-tile core) (~ A r k))   ->   A_ADJ[r][k] += A-TILE_ADJ[core]

   straight through the user's swizzled index expression — no `load-tile-at`, no layout
   knowledge required.  This was the part that looked hardest and it was never a problem.

   **What is left is exactly one thing.**  `mma-accumulate-via-tile`'s VJP reads operand
   PRIMALS from their global source, and a backward replays the forward's BINDINGS but not
   its STATEMENTS, so the staged tile is empty there.  A hand-swizzled flat buffer has no
   source mapping to invert.

   **The fix is RECOMPUTE** — replay the operand's staging statements into the backward,
   and address the flat buffer through the instruction's ABI layout (which is not user
   invention: the compiler already implements it for the forward).  Note the adjoint
   DESTINATION needs nothing new; the generic chain above already carries it home.

   Deliberately NOT built inside 146.  "Recompute staging in the backward" is a general AD
   capability that serves any hand-staged kernel, not an MMA feature, and this endeavor has
   already been burned once by improvising a mechanism (the ring work, five iterations).
   Candidate for its own endeavor.

4. **142/12** — `Type mismatch for operator '/'. Cannot operate on ULONG and INT.` on
   `(/ (inner-dimension A B) (to-ulong 8))`.  Unaffected by the `rem` rule; still open.
   Type inference on a differentiated runtime loop bound.
5. **Gap 3 — warp specialization.  CORE SOLVED 2026-08-09/10, with a number.**

   > **Phase 0 mislabelled this too.**  `CONSUMER` is not a user-defined sub-function — it is
   > a ROLE NAME in `with-warp-specialization`.  The construct is not a macro; it is handled
   > by `analyze-with-warp-specialization-expression`, and the AD walk runs BEFORE semantic
   > analysis, so the walk read the role block `(:consumer ...)` as a call.

   **The reported error was hiding worse, silent damage.**  `anf-transform` knows a fixed set
   of control forms (`IF`, `DOTIMES`, `WITH-PRECISION`, …) whose bodies it must not hoist.
   `with-warp-specialization` was not among them, so ANF lifted the role bodies out into the
   flat statement sequence and **the warp gating vanished entirely**:

       (%ANF-T-6  (SET! (~ C W L) %ANF-T-5))   ; producer body, now unconditional
       (%ANF-T-7  (:PRODUCER %ANF-T-6))
       (WITH-WARP-SPECIALIZATION %ANF-T-3 %ANF-T-7 %ANF-T-11)

   A backward built from that would have run BOTH role bodies in every warp.  Fixing only the
   walk would have produced a plausible, compiling, WRONG gradient.

   **The fix — lowering reuse, and the technique worth keeping.**  Chris asked whether
   `--differentiate` should just use a different macro.  Right instinct, wrong mechanism: a
   flag-conditional expansion would change the FORWARD too, so the kernel being gradient-
   checked would stop being the kernel being shipped.  What the question surfaced is better:

   > **Extract the analyzer's lowering into a pure syntactic function and call it from both
   > paths.  Do not write a second copy for AD.**

   `%lower-warp-specialization` (src/analysis/control.lisp) now returns the warp-gated
   `let`/`if`; the analyzer calls it, and the AD path calls it too — from
   `src/macros.lisp`, **before `anf-transform`**, so ANF sees ordinary control flow it
   already handles and nothing downstream needs to know the construct exists.

   Contrast with `%ad-canonicalize-wgmma`, which lives in the same pipeline and is the
   OPPOSITE case: there the backward deliberately uses a *different* instruction from the
   forward (sync MMA rather than warpgroup-async), because a backward is under no obligation
   to schedule itself the way its forward did.  Warp specialization wants the *same*
   expansion, just earlier.  **Substitution vs reuse — deciding which one a construct needs
   is the design question; getting it wrong yields two lowerings that drift.**

   **THE NUMBER.**  `146/01-warp-role-grad-bmg` on BMG:

       PASS (A: analytical=2.0 numerical=2.0000038; B: analytical=3.0 numerical=3.0)

   Each role reads its own input tensor, so a dropped role shows as a zero attributable to
   THAT role.  Two lessons the spec's header records, both of which cost an iteration:
   every thread must write a DISTINCT element (a shared cell is idempotent forward but the
   backward accumulates once per thread, so the test would measure launch geometry), and the
   geometry must not assume a sub-group width (the first cut used `warp-lane` with `group=32`
   and read dB=0 under SIMD32, which looked exactly like an AD failure and was not).

   **`ring-get` on a BARRIER ring — fixed 2026-08-11, context-directed.**  `RING-GET` must
   NOT go in `%backward-skip-fn-p`: it means two different things.  On a barrier ring it
   yields a barrier (ordering, not value — inert).  On a TILE ring it yields a VIEW whose
   adjoint is slot i of the adjoint ring, which `%ad-tile-base` / `%tlc-bwd-adj-name` already
   depend on.  An operator-level claim would silently zero the gradient of every ring-staged
   tile — the same failure Gap 2 removed for rem/mod.  So `*ad-barrier-ring-syms*` records
   which rings came from a barrier constructor and `%ad-inert-ring-get-p` consults it.

   **Where the three 139 specs now stand — two DIFFERENT blockers, neither about warp roles:**

   - **139/05, /06** get past `ring-get` and hit
     `SYNC-WORKGROUP cannot appear inside a thread-divergent conditional`.
     This is a CONSEQUENCE OF LOWERING EARLY and worth stating plainly: the analyzer binds
     `*in-warp-spec-block*` around the role bodies so the divergence checker knows a role gate
     is warp-uniform, not thread-divergent.  Lowering to a bare `if` before ANF discards that
     marker, so the backward's own forward-analysis applies the ordinary divergence rule.  The
     lowering is right; the CONTEXT it carried needs to travel with it.
   - **139/02** still reports `RING-GET`, but on `TILES` — which is
     `(make-scratch-vector-ring float 8 :ring-count 2)`, i.e. a rank+1 scratch TENSOR.  That
     ring-get is a real tile view, correctly not inert; it needs a rule for the case where ANF
     hoists it into a standalone binding rather than leaving it as an argument to
     `load-tile-at` (which is why 145/18's ring staging works and this does not).

   **NONE OF THE THREE CAN BE GRADIENT-CHECKED LOCALLY, and that is now a hard fact rather
   than an inconvenience.**  `:block` barriers are NVIDIA-only
   (`137/02: COMPILE-WITH[--ir-target=spv]: FAIL "not supported on Intel"`) and
   `sync-workgroup` is forbidden inside a role block — so cross-role DATA FLOW cannot be
   expressed on Intel at all.  Every 139 spec targets PTX; 146/01 is the only SPV one and
   works precisely because its roles share no data.  Rungs 2 and 3 of the planned ladder are
   therefore CUDA-only by construction, not by choice of test.  They want a Hopper pod
   (`scripts/run-on-pod.sh`), which would also serve the Bucket C backlog waiting on the same
   hardware: 137/03, 137/05, 138/04, 138/05, 140/03.
6. **Bucket E — 135/09's `Unknown variable C_ADJ`.**  Phase 0 guessed this was the same
   defect as Gap 4.  With Gap 4 now understood, that guess is UNVERIFIED — 135/09 is a
   reinterpreted view, not a register tile.  Re-measure before assuming.

### Candidate side quest — BUG 040.

Blocks three of the five Bucket C specs.  It is a **forward** bug on Intel — MMA reading a
ring slot returns plausible-but-wrong values (small, not garbage, so likely a base-offset or
row-stride miss when a fragment load addresses a ring *view*).  Clean repro in
`plan/bugs.md`.  Zero AD weeds, and fixing it unblocks the numeric proof for ring gradients
on hardware we actually own.


Definition of done for this endeavor
------------------------------------

Every MMA-era `SKIP-WITH[--differentiate]` is in exactly one of these states:

- **Bucket A** — skipped, reason correctly describes a negative/shape/dispatch test.
- **Un-skipped** — passing, with a numeric on-metal gradient check.
- **Bucket C** — skipped, reason names a specific hardware or bug exit criterion.

No skip anywhere in the suite makes a claim about the *language* being forward-only when the
truth is that *one lowering* is.
