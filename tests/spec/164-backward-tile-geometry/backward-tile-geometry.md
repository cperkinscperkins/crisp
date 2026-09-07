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


STEP 2 — THE NUMERIC RUNGS (2026-09-06)
----------------------------------------

**Group B was never "passing" — it was SKIPPED.**  A filtered run reporting zero failures shows
`SKIP (Skipped due to SKIP-WITH matches active flags)` for each spec, and a skip counts toward
the total.  Worth stating plainly because "138 and 142 pass" is true and means nothing.

Of the five, only **142/12** already carried a live directive.  Removing its skip produced a
number on BMG immediately, for free:

    PASS [l0] (A: analytical=1.2 numerical=1.1953125 diff=0.0047)

**137/03** already carried a `VERIFY-AUTODIFF[CUDA]` rung (`expect.A=1.0`).  A CUDA-pinned check
degrades gracefully off-NVIDIA — `SKIP (VERIFY-AUTODIFF pinned to CUDA; not available here)` —
while the spec still compiles and passes its PTX validator, so its skip came off too.

**137/05, 138/04, 138/05** had none, so three were WRITTEN: `expect.A=0.28`, from
`dA[m,k] = sum_n B[k,n]` with `B[i][j] = 0.01*(i*8+j)` and Nt=8.  Absolute, never
FD-vs-analytical agreement.

164/01 — THE RUNG THAT SAVED A RENTAL
--------------------------------------

All three declare a **col-major B**, and **no spec in the suite paired a col-major operand with a
live VERIFY-AUTODIFF** — so there was no precedent for the expected value.  Reading the runner
gave a model: it writes every matrix input as a flat ROW-MAJOR ramp and binds it as row-major,
its only col-major awareness being for TMA descriptors.  That predicts the kernel sees the
transpose, `B_kernel[k][n] = 0.01*(n*K+k)`, giving **19.2** at (1,0).

**Tested on BMG before spending anything.  Measured 1.1994476 — i.e. 1.2, the row-major answer.
The model was wrong by 16x.**  Had that gone into the three `[CUDA]` directives, the rental would
have produced three failures indistinguishable from a compiler bug.

164/01 now pins the contract permanently — *a col-major global staged through a scratch tile
yields the same gradient as a row-major one* — and records what it does NOT settle: 1.2 is
consistent both with the layout being handled correctly and with it being silently ignored.  One
data point cannot separate those, and the rung says so rather than over-claiming.

A TRAP WORTH KNOWING: PROSE BECOMES A DIRECTIVE
-----------------------------------------------

164/01 first FAILED the plain pass because a comment line reading
`;; TEST-HOIST[CUDA] + HOIST-EXPECT: MMA_CORRECT, which compares ...` was parsed as a REAL
directive, so the rung tried to run a CUDA hoist test it never wanted.  **The runner scans
comments for directive names; do not spell one in prose.**  Fixed, and the file now says so.

LEDGER AND STATE
----------------

MMA-range `SKIP-WITH[--differentiate]`: **17 -> 3** (140/01, 140/02, 154/03).
**1063/1063 plain and --differentiate, 233/233 negative.  Zero compiler changes — every fix so
far in this endeavour has been spec-level.**

PENDING ON HARDWARE: four `[CUDA]` numeric checks, verifiable in ONE batched pod run —
137/03 (`expect.A=1.0`), 137/05, 138/04, 138/05 (`expect.A=0.28`).

STEP 2 VERIFIED ON AN H100 NVL (2026-09-06)
--------------------------------------------

One batched pod run.  All four `[CUDA]` gradient checks EXECUTED and passed:

    137/03-tma-codegen-ptx        PASS [cuda]  analytical=1.0   numerical=1.0        diff=0.0
    137/05-block-mma-matmul       PASS [cuda]  analytical=0.28  numerical=0.27978516
    138/04-pipelined-block-matmul PASS [cuda]  analytical=0.28  numerical=0.28027344
    138/05-linear-ring-pipeline   PASS [cuda]  analytical=0.28  numerical=0.28027344

Suite on NVIDIA: **1063/1063 plain, 1063/1063 --differentiate, 233/233 negative.**

**The three 0.28 expectations were derived, not copied**, from `dA[m,k] = sum_n B[k,n]` with
`B[i][j] = 0.01*(i*8+j)`, and they rest on the col-major contract 164/01 established on BMG.
They came back right, which retro-validates that whole chain: had 164/01 not been written first,
these would have carried 19.2 and failed here for a reason that looked like a compiler defect.

The 70 `SKIP (no on-metal AD runtime available)` lines are the BMG-targeted checks — the pod has
no Intel GPU, so those defer correctly.  Worth noting because "all green" alone would not
distinguish "ran and passed" from "skipped"; the four that mattered report `PASS [cuda]`.

**Group B is now fully verified on a NUMBER.**  MMA-range ledger: **17 -> 3**
(140/01, 140/02 out of scope; 154/03 the tile-geometry item).  Still ZERO compiler changes in
this endeavour.

STEP 3 — FIRST CUT: DEAD SCRATCH IS NOT ALLOCATED (2026-09-06)
---------------------------------------------------------------

**The open question is answered: the emission is a FLAT SEQUENCE with no loop**, so re-tiling
the backward would need a loop structure it does not produce.  But measuring first showed
re-tiling is not where the first 262 KB is.

**The SLM breakdown accounts for 720896 EXACTLY** — eight 64x256 buffers are 73% of it:

| buffer | bytes | needed |
|---|---|---|
| `%ANF-T-26`, `%ANF-T-36` | 131072 | **DEAD** — the replayed wgmma accumulators |
| `%ANF-T-26_ADJ`, `%ANF-T-36_ADJ` | 131072 | **DEAD** — adjoints OF the dead accumulators |
| `D0_ADJ_VJPDC`, `D1_ADJ_VJPDC` | 131072 | copies of D0_ADJ/D1_ADJ, which are ALREADY SLM |
| `D0_ADJ`, `D1_ADJ` | 131072 | needed |
| rings + ring adjoints + forward rings | 196608 | needed (but see below) |

Each dead symbol occurs exactly TWICE in the whole backward — its own binding and a
`(fill-tile V 0.0)` — and nowhere else.  The tile VJP takes dC from C_GRAD and its operands from
the global sources, so the forward's accumulator is never read.

**FIXED: `%ad-prune-dead-scratch` drops a scratch binding whose symbol appears nowhere but its
own binding and fill-tile forms.**  Conservative by construction: any read, any write, any use as
an argument keeps it, and register tiles are left alone (SROA-exploded later, liveness not
decidable here).  Applied after `%ad-replay-finish`, so replay has already spliced in whatever it
needs.

    720896 -> 458752 bytes.  Exactly the 262144 predicted, to the byte.

1063/1063 --differentiate with **71** gradient checks passing (was 69; 142/12 and 164/01 now run).

**THIS CORRECTS 163 PHASE 14.**  That phase gave an oversized accumulator an SLM adjoint instead
of a register one — which moved these two dead buffers out of registers and into shared memory,
turning a register-budget refusal into a shared-memory one.  Relocating dead storage was the
wrong remedy.  The Phase 14 rule itself stands (a LIVE oversized accumulator does belong in SLM);
it simply no longer has dead tenants to relocate.

STILL OVER: 458752 vs 232448.  TWO CANDIDATES REMAIN, both measured
-------------------------------------------------------------------

1. **`_VJPDC` is a redundant copy — 131072 B.**  The scalar lowering allocates a fresh
   `(make-scratch-matrix float (mt nt))` and does `(store-tile c-adj dc (0 0))`.  Since 163
   Phase 12 an oversized accumulator's adjoint is ALREADY an SLM matrix, so the copy is
   pure duplication: `dc` could simply BE `c-adj`.  Would give **327680**.

2. **The ring ADJOINTS may now be dead in substance — ~96 KB.**  BUG 044's fix made a `:ring`
   operand scatter its stage contribution DIRECTLY into the global gradient, so the slot adjoint
   is never written; the load-site scatter then adds zero.  They are not SYNTACTICALLY dead (the
   scatter still names them), which is why the pruner keeps them — but if that scatter is
   provably a no-op it could be elided along with them.  Would give roughly **231680**, i.e.
   just inside the 232448 budget.

That second one is arithmetic on paper, not a measurement, and should be verified before being
believed.  If both hold, 154/03 fits WITHOUT any backward re-tiling — and the loop structure the
emission lacks would not be needed at all.

STEP 3 — SECOND CUT: THE REDUNDANT dC COPY (2026-09-06)
--------------------------------------------------------

`%mma-vjp-scalar-lowering` allocated `<c-adj>_VJPDC` and did `(store-tile c-adj dc (0 0))` to get
dC into SLM so it could be an MMA operand.  Since 163 Phase 12, an accumulator that does not fit
the register budget ALREADY has an SLM adjoint — so that buffer was a byte-for-byte duplicate and
the store copied SLM to SLM for nothing.

**FIXED: `dc` now ALIASES `c-adj` when the accumulator does not fit registers.**  Safe because
`dc` is read-only in both loops (`(~ dc m n)`); nothing writes it.  It asks the SAME predicate
`%mma-ad-adj-init` used to choose the adjoint's representation, so the two decisions cannot drift
apart — the failure mode 146 documented when they did.

    458752 -> 327680 bytes.  Exactly the 131072 predicted, again to the byte.

1063/1063 --differentiate, 71 gradient checks.  No regression.

CANDIDATE 2 WAS WRONG — THE RING ADJOINTS ARE NOT DEAD
--------------------------------------------------------

The previous section guessed the ring adjoints were "dead in substance" (~96 KB) and would bring
the total to ~231680, just inside budget.  **That was arithmetic on paper and it does not hold.**
Measured, `A0-RING_ADJ` has FOUR occurrences:

    (A0-RING_ADJ (MAKE-SCRATCH-TENSOR FLOAT 3 (2 64 32)))    ; binding
    (FILL-TILE A0-RING_ADJ 0.0)                              ; zeroed
    (%LOAD-TILE-AT-BWD A_GRAD (RING-GET A0-RING_ADJ SLOT) …)  ; READ by the scatter
    (WORKGROUP-STRIDE (RING-GET A0-RING_ADJ SLOT) (%VJP_M %VJP_K) …)  ; ITERATION-SPACE DONOR

It is true that BUG 044's fix means the slot adjoint is never WRITTEN — the VJP accumulates in a
local and atomic-adds straight to the global gradient — so the scatter adds zero and is a no-op in
EFFECT.  But it is not syntactically dead, and the buffer is additionally serving as the
`workgroup-stride` shape donor.  Eliding it therefore needs TWO coordinated changes, not a
pruning pass:

  1. suppress the load-site scatter for a ring operand whose VJP already went direct-to-global —
     the same "two decisions must agree" discipline as the accumulator rules;
  2. give the VJP loops an iteration space that is not the buffer being eliminated.

WHERE STEP 3 STANDS
-------------------

    720896  ->  458752  (dead scratch pruned)   ->  327680  (dC copy aliased)
    budget 232448 — still 95232 over, a 55% reduction so far.

Both cuts landed EXACTLY on their predicted byte counts, which is good evidence the SLM model is
right.  Neither needed the backward re-tiling this endeavour was opened to do, and the flat
emission still has no loop.  The remaining 95232 is the point at which re-tiling — or the
two-part ring-adjoint elision above — actually has to be decided on its merits.
