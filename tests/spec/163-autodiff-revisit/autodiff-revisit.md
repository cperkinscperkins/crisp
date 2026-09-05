When adding features to Crisp we usually try to address autodifferentiation at the same time. But that is not always possible.

We've been adding MMA support for some time now. Asynchronous tile loads, prefetch, wgmma, DSMEM, barriers and split barriers and more.  In edneavors 145, 146, 146 and 149 we addressed autodifferentiation for those new MMA techniques. With great difficulty, truth be told.  Part of the problem is that our AutoDiff works by doing an ANF transform and chain rule replacement on a forward kernel to produce a backwards one, but many of these MMA techniques are delicate data moving dances and they are resistent to that sort of transformation. But they don't need to be, fundamentally the overall math is the same, regardless of the optimization used, and therefore the derivative can likewise be the same - the derivative does NOT have to participte in this optmization at all. 

In this endeavor (163-autodiff-revisit) I want to review the work done since endeavor 149 and make sure everything is auto differentiating correctly. Several of those tests had SKIP-WITH[--autodifferentiate] put on them for expediency. Hopefully they are easy to address.

Be careful to not get caught in the trap of being unable to see the forest for the trees. Use the VJP "shortcuts" to preserve the math of the derivative kernel and avoid having to autodifferentiate data moving forms at all.


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


TASKS
======

- inventory the tests which are using SKIP-WITH[-differntiate] since endeavor 149.
- identify those that should be autodifferentiable.
- fix / implement what is needed to make the AD work for those tests
- remove the SKIP-WITH from them.
- use this endeavor to add any ADDITIONAL tests that might be needed (for example, if we need to extend the primal replay mechanism or something)

PHASE 0 — INVENTORY (2026-09-03)
=================================

Scope taken as: every spec directory from 149 onward.  **60 specs, 8 carrying
`SKIP-WITH[--differentiate]`.**

The thesis is already 87% demonstrated by the shipped suite
---------------------------------------------------------

52 of those 60 specs differentiate today, with no skip and no `forward-only`:

| dir | specs | diff-skips |
|---|---|---|
| 149-ad-primal-replay | 7 | 0 |
| 150-fused-epilogue | 14 | 0 |
| 152-DSMEM-Cluster | 18 | 1 |
| 154-nvidia-perf | 3 | 1 |
| 155-typed-mma-shapes | 4 | **4** |
| 156-workgroup-cooperation | 1 | 0 |
| 157-split-barrier | 2 | 0 |
| 158-prefetch-warps | 2 | 0 |
| 159-nvidia-16bit | 2 | **2** |
| 160-wgmma-16bit | 2 | 0 |
| 161-wgmma-shape-validation | 2 | 0 |
| 162-scratch-element-width | 3 | 0 |

Split barriers, workgroup cooperation, prefetch-warps, wgmma-16bit, DSMEM
clusters (17/18) and the whole fused-epilogue set **already see through their own
schedule**.  The scheduling machinery mostly IS transparent to AD.  That is the
forest, and it is measured, not assumed.

The 8 skips are FOUR defects
----------------------------

Not one of them asks for a derivative of a staging strategy.

**A — register-tile adjoint scoping.**  `155/01, 02, 04` + half of `03`.
AD mints no adjoint for a register tile bound INSIDE a `tile-stride` body
(`Unknown variable C-TILE_ADJ`); hoisting the identical bindings to the enclosing
`let` compiles clean.  The spec notes record a **tf32 twin failing identically**,
so this is neither an MMA defect nor a 16-bit defect.  Plain scoping.

**B — `ring-get` erases the operand's compile-time shape.**  `154/03`, and the
same blocker on `140/01` and `140/02`.  The tile-multiply / wgmma VJP cannot
resolve `(Mt Nt Kt)`.  149 explicitly deferred this to "its own endeavour" — this
is that endeavour, and it is the marquee case for the thesis: a *staging* form
leaked into the differentiator's view of the *math*.

**C — BUG 054, element type lost when minting fragments.**  `159/01, 02`.
AD mints TF32 fragments for fp16/bf16 operands and reads the wrong bytes.
A silent WRONG GRADIENT — the worst failure class in this endeavour.

**D — AD places `sync-workgroup` inside a divergent region.**  second half of
`155/03`.  The divergence checker refuses it, correctly: it would deadlock.
Sits behind A.

**Not a defect:** `152/23` is a negative arch-gate test whose `COMPILE-WITH FAIL`
IS the assertion.  By our own rule that a skip directive is a gap claim, that
directive is mis-shaped and should simply go.

B and C are one defect in two hats
----------------------------------

In both, the VJP **re-derives** operand metadata — shape in B, element type in C —
instead of **inheriting** it from the forward operand.  That is exactly the leak
the thesis names.  Prefer ONE mechanism (the VJP asks the forward operand for its
properties; staging forms forward that query to their backing store) over two
point-fixes: then `ring-get`, TMA staging and any future staging form become
transparent for free.

Skips do not catch everything
-----------------------------

A `SKIP-WITH` only marks a COMPILE-TIME gap.  These compile clean and produce
WRONG NUMBERS, so no skip names them — but they are AD defects in this
endeavour's territory:

- **BUG 044** — ring-pipelined MMA *backward* wrong on BMG (analytical 84.32 vs
  expected 1.2).  Ring + AD; plausibly the same root as B, and should be pulled
  in alongside it.
- **BUG 043** — under `--single-pass --differentiate` the backward kernel is
  served the FORWARD's `:physical-signature`.

Older, still open, still AD: **BUG 045** (`funcall` not differentiable, though a
direct call to the same function is) and **BUG 047** (a scratch CELL bound in a
def-kernel `let` crashes under `--differentiate`).

**The inventory for this endeavour is therefore `skips ∪ open AD bugs`**, not
skips alone.  Scoped to skips only, BUG 044 survives the endeavour and stays
silently wrong.

Order of work
-------------

1. **A** — 4 specs off one fix, and it touches no MMA machinery, so it builds
   harness confidence cheaply.  ← STARTED
2. **C** — on severity; a silent wrong gradient outranks a compile refusal.
3. **B** + **BUG 044** — the real work, done as one mechanism.
4. **D** — falls out behind A.
5. `152/23` — delete the mis-shaped directive.

Standing caution
----------------

The skip notes are **hypotheses, not findings**.  The 030+ sweep had three bug
notes whose observations held up for months while their stated CAUSE was wrong.
These notes are better than most — several say "MEASURED, not assumed" and name
their control — but re-run the control before building on it: the tf32 twin for
A, and B's message on the shipped chap3 kernel.


PHASE 1 — DEFECT A: FIXED (2026-09-03)
=======================================

Reproduced first, cause measured, then fixed.  The 2x2 control that settles what it was:

|            | bound INSIDE tile-stride    | hoisted to enclosing let        |
|------------|-----------------------------|---------------------------------|
| **bf16**   | `Unknown variable C-TILE_ADJ` | llvm-spirv exit 13 (defect C)  |
| **tf32**   | `Unknown variable C-TILE_ADJ` | **exit 0, `_grad.spv` emitted** |

Element type is irrelevant; BINDING POSITION is the whole trigger.  Confirms the spec notes'
"a tf32 twin fails identically", and corrects their "hoisting compiles clean" — hoisting
clears AD and then trips a SECOND, unrelated defect (see below).

ROOT CAUSE (measured, not inferred)
-----------------------------------

The adjoint was never the missing piece.  `(C-TILE_ADJ (MAKE-REGISTER-TILE FLOAT (8 16) 0.0))`
is present in the debug ANF in BOTH cases.  What differed was DISPATCH:

|                                    | hoisted | inside |
|------------------------------------|---------|--------|
| 145-P3b register-accumulator clause fires | 4  | **0** |
| `%LOAD-REGISTER-TILE-ACC` emitted        | 18 | **0** |
| generic `%STORE-TILE-AT-BWD` emitted     | 2  | **42** |
| `C-TILE_ADJ$F` fragments after explosion  | 114 | **4** |

`%mma-ad-register-tile-p` and `%mma-ad-register-accumulator-tile-p` scanned flat-anf with
`(loop for form in flat-anf thereis ...)` — the TOP LEVEL only.  `flatten-anf-body` flattens
LET and PROGN but leaves DOTIMES / IF / WHEN bodies NESTED, and `tile-stride` expands to a
workgroup-strided outer LOOP.  So a tile bound in its body is invisible to that scan, the
accumulator clause never fires, the store falls through to the generic `%STORE-TILE-AT-BWD` —
which `%explode-rewrite-body-form` does NOT rewrite (its list is `%LOAD-REGISTER-TILE-ACC`,
`FILL-TILE`, `LOAD-TILE`, `MMA-ACCUMULATE-VIA-TILE`, `STORE-TILE`) — so it kept the WHOLE-TILE
symbol, indexed it as memory, and the name died with the SROA explosion.

THE FIX WAS ALREADY IN THE FILE.  `%mma-ad-walk-forms` exists for exactly this blind spot and
says so in its own docstring.  145 P3b applied it to the tile MAPS and left the two role
PREDICATES on the flat scan; this finishes that job.  Both predicates now delegate to a shared
`%mma-ad-register-tile-binding-exists-p`, preserving the original `thereis` semantics exactly.
No new derivative and no new backward machinery — a scheduling construct's nesting had hidden
the math, which is the thesis.

In `overlays/crisp-compiler-overlay.lisp` (three defuns, headed by the full analysis).

RESULT.  All four 155 rungs now CLEAR THE AD STAGE — `Unknown variable C-TILE_ADJ` is gone.
Regression sweep after the fix: **1060/1060 E2E, 232/232 negative, 291/291 unit.**

The skips STAY for now: the rungs still fail, on the defects below.

A2 IS NOT A NEW DEFECT — IT IS **C** (BUG 054), AND C IS BIGGER THAN 159
------------------------------------------------------------------------

`155/01, 02, 04` now fail at llvm-spirv, and it is NOT a missing extension (adding
`+SPV_KHR_bfloat16` changes nothing).  The real message:

    FunctionPointers: Can't translate function pointer:
      declare ... @__spirv_CooperativeMatrixMulAddKHR(half 8x16, half 16x16, float 8x16, i32)

Reading the backward IR, all four calls target that ONE symbol with DIFFERENT signatures:

- forward call            -> `half 8x16`, `half 16x16`   (correct)
- **3 backward-minted calls -> `float 8x8`, `float 8x16`** (TF32 fragment shapes)

A symbol can be declared once, so LLVM bitcasts the function pointer and llvm-spirv refuses.
That IS BUG 054 — "AD mints TF32 fragments for 16-bit operands" — on the SPV backend.  Same
root cause, two symptoms: **PTX reads the wrong bytes silently; SPV fails to compile.**

Two consequences for the plan:

1. **C now unblocks FIVE specs**, not two: `155/01, 02, 04` + `159/01, 02`.
2. **SPV is the better oracle for C.**  A deterministic local compile error beats chasing a
   numeric gradient on rented NVIDIA hardware.  Develop C against SPV, confirm on PTX after.

Lead worth following: the minted `8x8` is the TF32 NATIVE fragment shape, so the AD path is
reaching `%frag-mn` / `%frag-mn-for-operand` WITHOUT an element type.  155 Phase C introduced
`*register-tile-elems*` for precisely this reason ("the load-tile expansion has only the tile
entry, which does not record it") — the AD-minted tiles are most likely absent from that map.

STILL OPEN AFTER A
------------------

- `155/01, 02, 04` — blocked on **C** alone.
- `155/03` — different failure now, a raw `The value is not of type SYMBOL` (ring variant),
  reached only because A no longer masks it.  Its documented divergence issue is behind that.
- Stale skip TEXT on all four rungs still blames the register-tile adjoint gap, which is
  fixed.  Retext before removal, so no future sweep re-derives a solved cause.


PHASE 2 — DEFECT C (BUG 054): FIXED.  FIVE SPECS UN-SKIPPED (2026-09-03)
=========================================================================

`%mma-via-tile-backward` built every backward temporary with a hardcoded FLOAT.  Three of the
five are the OPERANDS of the two backward GEMMs and must carry the forward's element type; the
two accumulators were already correct, since XMX and the tensor cores take 16-bit operands and
accumulate in fp32.  `%mma-ad-tile-dims-map` now records each tile's element type as a FOURTH
entry element -- every consumer read only SECOND and THIRD, so the extension is backward
compatible -- and the VJP stages its operands in it.

ONE CAUSE, TWO FACES.  The bug had been filed as two unrelated problems.  On PTX it reads the
wrong bytes and returns a silent wrong gradient (BUG 054 as filed).  On SPV it fails to compile,
because `%coop-call` caches the coop-matrix declaration by NAME alone: a module holding a half
FORWARD and a float BACKWARD calls one symbol at two signatures, LLVM bitcasts the callee, and
llvm-spirv refuses.  BUG 054's own SCOPE line ("the sync-MMA VJP only") was wrong -- another
bug-note CAUSE/SCOPE claim that did not survive contact, exactly as the standing caution warns.

VERIFIED BY READING THE EMITTED CODE, not exit codes:

- SPV backward -- all coop-matrix calls now `(half 8x16)` A, `(half 16x16)` B, `(float 8x16)`
  accumulator, matching the single declare.  No `float 8x8` remains.
- PTX backward -- `_grad.ptx` carries ONLY `m16n8k16.row.col.f32.f16.f16.f32`, and `.bf16.bf16`
  for the bf16 rung.  No tf32 variant survives.

SAFETY PROPERTY: when the operand element IS float, the emission is byte-for-byte what it was.
Every tf32 kernel is untouched, which is what made this safe to land on a green suite.

UN-SKIPPED: **155/01, 155/02, 155/04, 159/01, 159/02** -- and confirmed the removal took effect,
rather than assuming: under `--differentiate` the runner now reports no skip for any of the five,
while 155/03 still reports `SKIP (Skipped due to SKIP-WITH matches active flags)`.

FULL SWEEP
----------

| pass | result |
|---|---|
| in-process, plain | 1060/1060 |
| in-process, `--differentiate` | 1060/1060 |
| `--use-binary` | 1060/1060 |
| `--use-binary --debug` | 1060/1060 |
| `--use-binary --differentiate` | 1060/1060 |
| `--use-binary --single-pass` | 1059/1060 — **pre-existing BUG 043** |
| negative | 232/232 |
| unit | 291/291 |

The single-pass failure is `050-differentiate-and-metadata/03-record-at-boundary`, which holds
no MMA or register-tile forms at all.  NOT taken on the ledger's word: the fix was stashed, the
compiler rebuilt at HEAD, and the identical validator failure reproduced there.

TWO FINDINGS UNCOVERED, NEITHER FIXED HERE
------------------------------------------

1. **`%coop-call`'s name-only declaration cache** (src/codegen.lisp) is a latent hazard for any
   module that legitimately mixes coop-matrix element types.  Homogeneous operands remove
   today's collision but not the trap.  A cheap guard would be to refuse when an existing
   declaration's type differs from the requested one, turning an obscure llvm-spirv message into
   a Crisp diagnostic.
2. **`--debug --differentiate` on a 16-bit kernel** dies in llvm-as with `Metadata id is already
   used` (`!101` emitted twice).  Newly REACHABLE, not newly broken -- the 16-bit backward never
   compiled at all before -- and no CI pass combines those two flags.

REMAINING IN THIS ENDEAVOUR
---------------------------

- **B** — `ring-get` erases operand shape: `154/03`, `140/01`, `140/02`, plus **BUG 044**.
- **D** — `155/03`: now a raw `The value is not of type SYMBOL` on the ring path, with the
  documented divergence issue behind it.  Shares the ring theme with B, so worth doing together.
- `152/23` — delete the mis-shaped directive on the negative arch-gate test.


PHASE 3 — ON-METAL NUMERIC GRADIENT CHECK: BLOCKED BY A DRIVER GAP (2026-09-03)
===============================================================================

BUG 054's own note said the fix "needs an on-metal numeric gradient check to confirm".  Phase 2
verified the backward by READING the emitted code, which proves it SELECTS the right
instructions but not that it computes the right NUMBER.  Rung `01-fp16-mma-gradient-bmg.crisp`
is that check: the fp16 twin of 145/09, same absolute assertion (`dA[1,0] = sum_n B[0,n] = 1.2`).

It does not pass, and the reason is a DRIVER gap.  Three findings, in the order they appeared:

1. **FIXED — the SPIR-V ext list never requested `SPV_EXT_shader_atomic_float16_add`.**  A
   16-bit kernel's backward would not TRANSLATE (llvm-spirv exit 18).  The gradient SCATTER
   accumulates into `A_GRAD` / `B_GRAD`, which carry the INPUT's element type, so any 16-bit
   kernel under `--differentiate` emits a half-typed `atomicrmw fadd`.  New predicate
   `%ll-uses-fp16-atomic-fadd-p`; it text-scans the emitted .ll because its siblings scan
   FUNCTION NAMES and `atomicrmw` is an instruction, and a module walk would need four LLVM
   bindings that do not exist.  `%inject-cache-control-decorations` already text-scans the same
   file, so this follows local precedent.  Fires only when a half atomic fadd is present, so
   fp32/tf32 flag lists are byte-identical.

2. **FIXED — VERIFY-AUTODIFF could not read a 16-bit kernel's implicit params.**
   `%vad-read-implicit-params`' elem-bytes table knew float/double/int/ulong/long and errored on
   the first `half` scratch tile.  A 16-bit backward is mostly such tiles.  Same SHAPE of harness
   gap that 145 P6 fixed when it taught the runner about 2-D matrices.

3. **THE WALL — BMG's driver refuses a module that declares the extension.**

       InvalidModule: Invalid SPIR-V module: input SPIR-V module uses extension
       'SPV_EXT_shader_atomic_float16_add' which were disabled by --spirv-ext option

   That is IGC's embedded SPIR-V reader at MODULE-LOAD time, not llvm-spirv — the same kernel
   translates standalone and yields a .spv that declares the extension.  It is the exact shape
   of the bf16 gap in 155/02's header.  **CONTROL:** the tf32 twin 145/09, whose scatter uses
   fp32 atomics, still verifies on this same box (analytical=1.1994, numerical=1.1990).  The ONLY
   difference is the atomic's element width.

So on Intel, **fp16 covers the forward but bf16 AND fp16 both fail the backward on metal** — bf16
at the type, fp16 at the atomic.

THE OPEN DECISION
-----------------

**(a) Accumulate 16-bit gradients in fp32** — promote the `_GRAD` tensors, or the scatter.
Removes half atomics entirely, is vendor-neutral, and is numerically BETTER: fp16 atomic
accumulation over many contributions loses precision badly.  There is precedent — the adjoint
minting already promotes element types "so gradients use correct FP precision".  Cost: it
changes the AD ABI for 16-bit kernels, since the host would allocate fp32 gradient buffers.

**(b) Keep half atomics and verify on NVIDIA**, which has them natively.  Correct, but costs a
rented pod and leaves Intel unable to differentiate any 16-bit kernel on metal.

**(a) is the recommendation**, and it is a design decision rather than a patch, so it is left
open rather than taken unilaterally.

STATE.  ci-stop stays at **162** and the rung is RED ON PURPOSE beyond it, with its
VERIFY-AUTODIFF directive left ACTIVE rather than skipped — it is the assertion the rung exists
to make, and it should start passing the moment (a) lands.  Suite after Phases 1-3:
**1060/1060 plain, 1060/1060 --differentiate, 232/232 negative.**

WHAT IS AND IS NOT PROVEN ABOUT BUG 054
---------------------------------------

PROVEN: the backward now emits 16-bit MMA with matching declares on SPV, and only
`m16n8k16...f16.f16` / `.bf16.bf16` on PTX.  The tf32 path is byte-for-byte unchanged.
NOT PROVEN: that a 16-bit MMA gradient equals its analytical value on hardware.  That is what
this rung is for, and it stays open until the decision above is made.


PHASE 4 — PATH (a) SHIPPED: 16-BIT WEIGHTS, 32-BIT GRADIENTS (2026-09-04)
=========================================================================

Approved as the industry-standard rule — PyTorch AMP keeps fp32 master gradients for fp16
forward weights, for the same two reasons that apply here: fp16 atomic accumulation is lossy,
and BMG's SPIR-V reader will not load a module declaring SPV_EXT_shader_atomic_float16_add.

The promotion had to land at TWO altitudes; the first alone was not enough.

**Part 1 — kernel-boundary `_GRAD` slots.**  `%compute-backward-kernel-params` promoted INTEGER
tensors to float and passed ANY float tensor through, silently including half and bfloat16.  A
narrow-float clause now sits ahead of that passthrough, mirroring the integer one; the bare
scalar branch gets the same treatment.  Confirmed in the metacrisp: `a_grad` / `b_grad` became
`tensor float 2` while `a` / `b` stayed `matrix half`.

**Part 2 — the `_ADJ` SLM tiles.**  Part 1 alone left the SPIR-V still declaring the fp16 atomic
extension with `AtomicFAddEXT` result type `TypeFloat 502 16`.  The remaining half atomics were
on the OPERAND ADJOINT tiles (`a-tile_adj` / `b-tile_adj`, `tensor half 2 :local`), which
accumulate contributions in shared memory before the scatter.  `%promote-scratch-init-for-ad`
had the identical omission — integers only — and now promotes narrow floats too.

**Why this does not undo defect C.**  An operand ADJOINT is never an MMA operand; per
`%mma-ad-adj-init`'s own contract every consumer indexes it as MEMORY.  The tiles that ARE MMA
operands — dC / A^T / B^T — are minted by `%mma-via-tile-backward` from the forward tile's
element type and never pass through either promoter, so they stay 16-bit.  Verified on the
emitted SPIR-V: `TypeFloat 16` with TWO cooperative matrices using it beside a 32-bit
accumulator, and only `SPV_EXT_shader_atomic_float_add` declared.

**THE DRIVER WALL IS GONE.**  The 16-bit backward now LOADS AND RUNS on BMG.  That was Phase 3's
blocker and it is closed.

REGRESSION.  1061/1061 plain, **1060/1061 --differentiate** (the sole failure is rung 01 below),
232/232 negative, 291/291 unit.  The tf32 twin 145/09 still verifies on metal, which is the
control that matters: a float element is not narrow, so every fp32/tf32 signature is unchanged.

WHAT STILL BLOCKS THE NUMBER
----------------------------

One HARNESS gap: VERIFY-AUTODIFF's runner cannot WRITE an fp16 input buffer.  It sizes every
matrix input at 4 bytes/element (`(:matrix-float (* 4 (getf desc :length)))`) and does no
fp32->fp16 conversion, so A and B arrive as float bit patterns reinterpreted as half pairs.

A SHORTCUT WAS TRIED AND REJECTED — recorded so nobody retries it.  Making the GLOBAL matrices
`float` and letting `load-tile-at` convert into half tiles compiles cleanly and is WRONG: the
emitted forward contains no `fptrunc` and not one `store half`, only
`store float ... ptr addrspace(3)`.  That is **BUG 057**, a silent-wrongness bug in the FORWARD
staging path, filed separately and NOT the same defect as 054.  It also means the shortcut
cannot serve as a test at any point.

So finishing the numeric check needs one of:
  (i)  **extend the runner** to write fp16 input buffers — descriptor carries an element width
       read from the metacrisp declared-signature, byte-size and buffer-write honour it, plus a
       small IEEE fp16 encoder.  Reusable by 159 / 160 and every future 16-bit AD spec.
  (ii) **fix BUG 057** — make load-tile-at convert on an element-width mismatch (or refuse it).
       Fixes a real silent bug AND lets a float-boundary kernel exercise the 16-bit MMA with no
       harness change at all.

(ii) fixes a live defect as a side effect, so it is the better value; (i) is the more general
capability.  They are not exclusive.

STATE.  ci-stop is at **163**, so rung 01 is the endeavour's live TDD frontier and is RED with
its VERIFY-AUTODIFF directive ACTIVE.  Its header records all four walls and which are down.


PHASE 5 — THE NUMBER, ON METAL (2026-09-04)
============================================

    PASS [l0] (A: analytical=1.2000704 numerical=1.2003174 diff=2.47e-4)   expected 1.2

**Rung 01 is GREEN.**  A 16-bit MMA gradient now agrees with both its finite difference AND its
absolute analytical value on real hardware.  That is what BUG 054's own note asked for and what
Phase 2 could not supply: reading the emitted code proved the backward SELECTS 16-bit
instructions, this proves it computes the right NUMBER.

For scale, the pre-fix backward produced **16.49** here, and a run with mis-fed inputs produced
**2089472.0**.  The assertion is absolute, not FD-vs-analytical agreement, so neither could have
slipped through.

TWO MORE FIXES, both on the harness side
----------------------------------------

**BUG 057 — refused, not converted.**  `%tlc-check-elem-match` runs from
`analyze-load-tile-at-expression`, which gates every lowering (sync staging, cp.async, NVIDIA
TMA, SPV async), so one check covers all of them.  An implicit `fptrunc` was rejected as the fix:
it would bury per-element casts inside a bulk staging loop whose whole purpose is speed, and
silently change the numerics of a load the user reads as a copy.  Negative rung under `errors/`,
deliberately MMA-free — the first draft staged into an MMA and passed for the wrong reason,
because the negative runner compiles for GENERIC with no profile and the MMA shape check fired
first.

Two implementation notes worth keeping.  The types come from a PURE env lookup rather than
re-analysing the operands, so no side effect is duplicated.  And the first cut NEVER FIRED: a
kernel PARAM's type is not a list, it is the generated record name
`TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST`, while a let-bound tile's type IS a list —
`get-array-element-type` already handles both and replaced the bespoke extractor.

**VERIFY-AUTODIFF can now feed 16-bit inputs.**  A host-side IEEE binary16 encoder
(`%vad-f32->f16-bits`, round-half-to-even so the expected value does not shift depending on which
side narrowed) plus `write-half-vector`, and a per-input element width read from the FORWARD
`.metacrisp`.  Three things had to be right and each failed first:

  - the width must be read AFTER the compiles — the metacrisp does not exist when the enclosing
    `let*` runs, which is why it is `setf` in the `(t ...)` clause and cleared in an
    `unwind-protect` rather than bound in the `let*`;
  - a `let*` on that special would have bound it LEXICALLY anyway, the same compile-order trap
    the neighbouring `(declare (special cl-user::*ad-runtime*))` exists to dodge;
  - `%vad-make-descriptors` copies SELECTED keys out of the classifier's plist, so `:elem-bytes`
    was silently dropped until it was named there too;
  - and a `:declared-signature` entry's `:type` is the ALIAS SYMBOL (`A-MAT`), not the expanded
    shape — the expansion only appears in the _grad metacrisp — so the reader resolves through
    the file's own `(:aliases ...)` block.

A METHOD NOTE.  `scripts/check-parens.lisp` reported **balance 0** on a defun the READER could
not read: it is not string-aware, and the missing paren was masked.  A string-aware counter found
depth 1 immediately.  When check-parens and the reader disagree, believe the reader.

STATE
-----

**1062/1062 plain, 1062/1062 --differentiate, 1062/1062 --use-binary --debug, 233/233 negative,
291/291 unit.**  ci-stop is at 163 and the whole endeavour directory is green.

Files touched outside the usual overlay route: `tests/verify-autodiff-runner.lisp` and
`tests/run-specs.lisp` were edited DIRECTLY rather than via the spec-runner overlay.  The change
needed three lines inside a 459-line function and one inside a 158-line one; duplicating those
into an overlay to change four lines would have been worse for review and worse to fold back.
