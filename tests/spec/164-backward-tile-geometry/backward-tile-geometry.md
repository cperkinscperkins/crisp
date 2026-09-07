164 — BACKWARD TILE GEOMETRY
============================

Opened 2026-09-06, out of endeavour 163 (autodiff-revisit).  The measurements below were taken
live at the end of 163 and are recorded here because re-deriving them is expensive.

WHY THIS IS NOT CALLED "wgmma-ad"
---------------------------------

Because **wgmma autodiff already works**, and naming this endeavour after it would send the next
reader down the wrong path.  The reference point is `tests/spec/140-wgmma/03-wgmma-tma.crisp`:

    (let ((A-tile (make-scratch-matrix float (64 32)))
          (B-tile (make-scratch-matrix float (64 32)))
          ...
      (load-tile A A-tile (0 0) :barrier bar :swizzle :128b)
      (load-tile B B-tile (0 0) :barrier bar :swizzle :128b)
      (wgmma-accumulate-via-tile (64 64 32) D A-tile B-tile :swizzle :128b)

It carries NO `SKIP-WITH[--differentiate]` and compiles clean under `--differentiate` today
(verified 2026-09-06, exit 0, with `--ir-target=ptx --ir-target-arch=sm_90 --hardware-profile=h100`).
140/02's own skip note says it plainly, and it went unread for a while:
*"140/03 differentiates, so wgmma itself is not the obstacle."*

THE HEADLINE ITEM
-----------------

`tests/spec/154-nvidia-perf/03-wgmma-two-warpgroups.crisp` stages its operands correctly — real
`load-tile ... :swizzle :128b` into `make-scratch-matrix-ring` slots, with explicit origins — and
still refuses:

    Kernel WGMMA_TWO_WG_GRAD: uses 720896 bytes of local/shared memory,
    exceeding the hardware profile's :max-shared-memory-per-block (232448 bytes).

**704 KB against 227 KB — roughly 3x what a Hopper SM has.**  This is not a defect.  The backward
is materialising the FORWARD'S TILE GEOMETRY: a 128x256 output tile over two warpgroups, with the
staged operands, their adjoints, and the VJP's transposed stages.

The forward picks 128x256 because that saturates a Hopper SM.  **dA = dC.B^T and dB = A^T.dC hold
at ANY tile size.**  The derivative can compute identical gradients in a much smaller working set
and loop.  Nothing in the math requires the backward to tile like the forward.

THIS IS THE SAME PRINCIPLE 163 CLIMBED FOUR TIMES
-------------------------------------------------

| endeavour 163 | what the derivative inherited but did not need |
|---|---|
| BUG 044 | the operand adjoint's STORAGE (a reused ring slot) |
| Phase 12 | the accumulator adjoint's STORAGE (registers) |
| Phase 14 | the replayed accumulator's STORAGE (registers) |
| **164** | **the forward's TILE GEOMETRY** |

Each time the fix was to STRIP the forward's choice rather than replicate it.  The guardrail from
163 applies unchanged: **abstraction, not replication.**  Do not build a backward that mirrors
warp specialisation, prologues, double buffering or producer roles.  If the backward should later
be pipelined, that is an optimisation over correct math, not a term in the AD generator.

STEPS
-----

**0. Decide 140/01 and 140/02 — probably NOT in scope.**  They hand-scatter into a flat
`(make-scratch-vector float 512)` with a bespoke core-matrix index formula
(core = (r/8)*64 + (k/4)*32 + (r%8)*4 + (k%4)), so the VJP has neither a compile-time (Mt Kt) nor
a `load-tile-at` source.  Inverting arbitrary user index arithmetic is not something AD can or
should do.  Since 140/03 already proves wgmma differentiates, their AD coverage is REDUNDANT;
their value is pinning the hand-scatter FORWARD layout.  Recommendation: leave their skips, which
are honest.  Rewrite them onto 140/03-style staging only if you want them differentiable for its
own sake.

**1. THE NUMERIC RUNG FIRST.**  A small wgmma matmul with `VERIFY-AUTODIFF` and a `[CUDA]` pin, so
the runtime is CUDA rather than the SPIR-V auto-select.  Use an absolute `expect.A`, not
FD-vs-analytical agreement — under BUG 054 both sides were fed the same mis-typed fragments and
agreed with each other while being wrong.  Write this BEFORE the tiling work: every real error
caught in 163 was caught by a number (044's 84.32, defect C's mis-fed 2089472), and it is the
oracle step 2 needs.  This is also the piece that makes an H100 rental pay for itself.

**2. LET THE BACKWARD CHOOSE ITS OWN GEOMETRY.**  The VJP currently takes Mt/Nt/Kt from the
forward tiles' dims-map entries.  It should be free to pick a smaller (Mt' Nt' Kt') that fits the
target's shared-memory budget, and loop over the output tile.

**THE OPEN UNKNOWN, and the first thing to establish:** whether the backward can pick its own
geometry INSIDE the existing `%mma-via-tile-backward` emission, or whether it needs a loop
structure that emission does not currently produce.  That determines whether 164 is a contained
change or a chapter.  Establish it before estimating anything else.

WHERE TO LOOK
-------------

- `%mma-via-tile-backward` (overlay) — emits the backward's LET, the transposed stages and the two
  GEMMs.  Takes Mt/Nt/Kt from `dims-map`; this is where geometry is currently inherited.
- `%mma-vjp-mma-admissible-p` — decides MMA path vs scalar lowering; requires
  `kt mod lcm(sm sn) = 0`.  A re-tiled backward changes what is admissible.
- `%mma-ad-accumulator-fits-registers-p` (overlay, from 163) — the shared predicate that decides
  register vs SLM for BOTH the adjoint and the canonicalised accumulator.  A shared-memory
  analogue may be wanted.
- `140/03-wgmma-tma.crisp` — the working reference.  Diff 154/03 against it to see what the
  geometry costs.

METHOD NOTES WORTH KEEPING
--------------------------

- **Getting a backtrace out of the compiler.**  It wraps compilation in its own `handler-case`, so
  an outer `handler-bind` never sees the condition — you get only
  `Crisp compilation failed ... <message>` with no location.  `*break-on-signals*` fires at SIGNAL
  time, before any handler unwinds.  That is how both `WGMMA_TWO_WG_GRAD` and
  `ANALYZE-INCOMPLETE-TYPE-ACCESSOR 32 (32 16)` were identified.  Set
  `sb-ext:*invoke-debugger-hook*` alongside it, and remember to set `*target-backend*` AND
  `*ir-target-arch*` (a KEYWORD, e.g. :SM_90) or you trip the arch gate instead of the bug.
- **`scripts/check-parens.lisp` is not string-aware.**  It reported balance 0 on a defun the reader
  could not read.  When it and the reader disagree, believe the reader; a string-aware counter
  found the missing paren immediately.
- **`compile-crisp-file-to-ir-string` lives in the spec runner, not the compiler.**  For an
  in-process probe call `crisp.main::compile-files`.
- **Pod discipline paid off in 163:** develop and compile-verify locally, then ONE batched
  `run-on-pod.sh`.  The 2026-09-06 run gave 1062/1062 + 233/233 with ~105 CUDA validations on an
  H100 PCIe, 23 of them MMA-on-metal.

STATE INHERITED FROM 163
------------------------

Fixed and verified there, so do not re-derive: defect A (register-tile adjoint scoping), defect C
/ BUG 054 (tf32 fragments for 16-bit operands — numerically verified), BUG 044 (ring adjoint
aliasing — numerically verified at 1.2), BUG 057 (load-tile element mismatch, now a refusal),
defect B2 (ring shape + provenance through ANF aliases), defect D (dead ANF shape temp reaching
the analyzer), and the oversized-accumulator rule (register tile -> SLM, for both the adjoint and
the canonicalised accumulator).

Post-149 `SKIP-WITH[--differentiate]` ledger went 8 -> 1 in 163.  **That count was scoped to
post-149 directories only — 163's charter — and is MISLEADING for this endeavour**, which is
about MMA backward geometry regardless of era.  The real MMA-range inventory is below.


THE ACTUAL MMA-RANGE INVENTORY (measured 2026-09-06)
-----------------------------------------------------

**17** specs at 132+ carry `SKIP-WITH[--differentiate]`, not one.  Each was RUN under
`--differentiate` with its own TEST-WITH flags, and again with its hardware profile where it
declares one.  Four groups:

**A. NOT AD GAPS AT ALL — the refusal IS the assertion (8).**  Same shape as 152/23, which 163
removed: the directive explains expected behaviour instead of claiming a gap.

| spec | what it actually reports |
|---|---|
| 132/07-fit-check-profile | `make-register-tile: a 64x64 accumulator tile needs ...` — it IS the fit-check spec |
| 133/13, 133/14 col-major-refused | `Intel cooperative-matrix (MMA) operands cannot be :col-major` |
| 137/01-block-arch-gate-nvidia | `:mode :block / :cluster needs sm_90+; got sm_80` |
| 137/02-block-arch-gate-intel | `:mode :block is not supported on Intel / SPIR-V` |
| 142/02-register-load-no-profile | requires a profile: `GRF / L1 limits drive the register-pipeline safety analysis` |
| 142/03-register-load-on-ptx | `Subgroup2DBlockLoadINTEL, which is Intel-only` |
| 142/13-prefetch-on-ptx | `Subgroup2DBlockPrefetchINTEL, ... Intel-only` |

Each should be TESTED with the directive removed (152/23 passed once removed), then removed.
Cheap, and it stops the ledger overstating the AD debt.

**B. COMPILES CLEAN — STALE SKIPS, CORRECTNESS UNVERIFIED (5).**

    137/03-tma-codegen-ptx     137/05-block-mma-matmul     138/04-pipelined-block-matmul
    138/05-linear-ring-pipeline                            142/12-ring-kloop-metal

These are the dangerous ones.  **Compiling proves nothing** — BUG 054 compiled and emitted
plausible instructions while computing garbage, and only a NUMBER caught it.  Do not simply drop
these skips.  Each needs a gradient check before its directive comes off, or it trades an honest
skip for a false green.

**C. REAL AD GAPS (3).**

| spec | cause |
|---|---|
| 140/01, 140/02 | hand-scattered flat `make-scratch-vector`; no compile-time (Mt Kt), no `load-tile-at` source.  See step 0. |
| 142/14-pipeline-bench | `SYNC-WORKGROUP cannot appear inside a thread-divergent conditional` — **the identical pattern 155/03 had**, with the same shape of kernel: `(when (< next-k n-k-steps) (load-tile ...))` and no `to-workgroup-uniform`.  163 fixed 155/03 by binding the guard through it.  Likely the same one-line spec fix; verify rather than assume. |

**D. THE HEADLINE ITEM (1).**  154/03 — and note the trap: its `TEST-WITH` is
`--ir-target=ptx --ir-target-arch=sm_90` with **NO hardware profile**, so under its own flags it
COMPILES CLEAN.  The 720896-vs-232448 SLM refusal only appears when a profile supplies
`:max-shared-memory-per-block`.  **Without a profile the compiler cannot see that the backward
does not fit an SM** — a kernel that compiles and could not launch.  That is worse than a
refusal, and it means any "does 154/03 compile?" check must pass the profile or it answers the
wrong question.

REVISED STEP ORDER
------------------

0. **Group A cleanup** — test-then-remove 8 directives that never described AD gaps.
1. **142/14** — try 155/03's `to-workgroup-uniform` fix.  Probably the cheapest real win here.
2. **The numeric rung** (was step 1) — still first among the *engineering* steps, and now doubly
   motivated: group B needs an oracle before its skips can honestly come off.
3. **Backward tile geometry** — the 154/03 item.
4. **140/01, 140/02** — still recommended OUT of scope; see step 0 in the section above.


PROGRESS
========

STEP 0 — GROUP A CLEARED (2026-09-06)
--------------------------------------

All **8** directives removed and TESTED, not assumed: **1062/1062 under `--differentiate`.**

    132/07-fit-check-profile          133/13-col-major-operand-refused-bmg
    133/14-col-major-accum-refused    137/01-block-arch-gate-nvidia
    137/02-block-arch-gate-intel      142/02-register-load-no-profile
    142/03-register-load-on-ptx       142/13-prefetch-on-ptx

None described an AD gap.  Each is a gate or negative spec whose refusal IS its assertion, and
`--differentiate` changes nothing about any of them — the same finding 163 reached for 152/23.
The MMA-range ledger is therefore 17 -> 9 on cleanup alone, before any engineering.

STEP 1 — 142/14 FIXED, AND THE `let` PLACEMENT IS LOAD-BEARING
---------------------------------------------------------------

142/14 was the predicted twin of 155/03 — `(when (< next-k n-k-steps) (load-tile ...))` with no
`to-workgroup-uniform`, refusing with
`SYNC-WORKGROUP cannot appear inside a thread-divergent conditional`.  Binding both guards
through `to-workgroup-uniform` fixes it, as predicted.

**But WHERE the binding goes decides whether it works, and getting that wrong produces a
thoroughly misleading error.**  Hoisting the guards into the ENCLOSING `let*` alongside
`next-k` / `prefetch-k` makes ANF bind the whole `when` as a VALUE:

    (%ANF-T-38 (WHEN MORE-K? (LOAD-TILE-AT A (RING-GET A-RING (MOD ...

whose value is the last `load-tile-at` — so `%handle-single-value-backward` sees a STATEMENT in
value position and reports

    Function LOAD-TILE-AT is not differentiable.

which names the wrong thing entirely and points at no gap at all.  Measured, not inferred: the
pre-change kernel produces NO such ANF binding (it failed on divergence instead), so the hoist
was caused by the restructuring.  **Wrap each `when` in its OWN `let`, as 145/19 and 155/03 do.**

This is the third member of a family worth naming: `Function GRID-Y is not differentiable`
(recorded in memory), `Function PREFETCH-K ...` (endeavour 146's note inside the skip list), and
now `Function LOAD-TILE-AT ...`.  **In every case the named function is innocent and the real
cause is ANF placing a non-value in a value position.**  Treat that message as "something got
hoisted", not as an AD coverage gap.

REMAINING MMA-RANGE LEDGER (9)
-------------------------------

| group | specs | status |
|---|---|---|
| B — compiles, UNVERIFIED | 137/03, 137/05, 138/04, 138/05, 142/12 | needs the numeric rung first |
| C — real gaps | 140/01, 140/02 | out of scope, see step 0 above |
| D — headline | 154/03 | the tile-geometry item |
