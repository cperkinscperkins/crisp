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

### Phase 2 — the four gaps, cheapest blast-radius first.

Phase 0 chose the order.  Each is a generic AD gap, so each unblocks specs beyond the one
being worked:

1. **Gap 1 — inert constructors** (140/03, 142/10, 142/12).  145 P1 did exactly this for
   shape queries; the pattern exists.  Cheapest.
2. **Gap 2 — `rem`** (140/01, 140/02).  Small rule.  Pairs naturally with 132/08's missing
   `to-float`; both are index/conversion arithmetic, not MMA.
3. **Gap 3 — sub-function walk into warp roles** (139/02, 05, 06).  Medium.
4. **Gap 4 — view adjoints at the AD boundary** (142/00, 01, 11).  Hardest, and it also
   closes 135/09 in Bucket E.

One spec at a time within each gap (Rule 3), numeric proof or an honest skip (Rule 1), and
if a fix starts to require teaching the ANF pass about a scheduling construct, stop (Rule 2).

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
