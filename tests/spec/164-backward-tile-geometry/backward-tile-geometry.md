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

THE ONE REAL ITEM
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

Post-149 `SKIP-WITH[--differentiate]` ledger went 8 -> 1 in 163.  The one survivor is 154/03,
whose note now names the SLM budget described above.
