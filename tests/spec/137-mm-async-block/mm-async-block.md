This endeavor is a continuation of our last one ( .\tests\spec\136-mm-async\mm-async.md).

We are working our way through the MMA "Chapters" in .\docs\topology.md . In the last endeavor we added basic linear async DMA operations, and began modified the (make-async-barrier) routine to both take keys alowing a uses to specify the exact DMA they want govered, and preparing it for the optimal when those keys aren't used.

[x] Chapter 1 - async tile   cp.async and OpGroupAsyncCopy
[ ] Chapter 1.5 - async tiles  with CuTensorMap and LSC 2D Block Loads in Intel Xe

Now we are working on "Chapter 1.5" . 

Here is some of the work that needs to be done. Each entry most likely needs at least one TDD test.

[ ] DEFALTS: when no --ir-target-arch is provided, let's assume it is sm_80 if Nvidia and DG2 if Intel.
[ ] :mode :block support for (make-async-barrier :type :global :mode XXXX)
[ ] we should throw a compilation error when :block can't be realized
     For PTX, that would be if --ir-target-arch is not provided (or is earler than sm_90)
     For Intel, that would be if --ir-target-arch is Gen12.
[ ] (make-async-barrier) with NO :type / :mode should choose whatever matches the elected (or default if none) architecture.
[ ] CuTensorMap will require an implicit argument added to the kernel like we already do for scratch memory.
[ ] if a sub-function is the one caling make-asynch-barrier, then the CuTensorMap will also have to be added 
as an implicit argument to it interfact and ALL OF ITS CALLERS, just like we do now with scratch memory in sub-functions.  We will definitely need some tests for this.
[ ] We should definitely test the full MMA with the :block async copies.
[ ] And benchmark.


================================================================================
DEV PLAN (recorded 2026-07-12 for continuity — see also memory endeavor-136/137)
================================================================================

## The central insight: the two backends are NOT symmetric for :block

| aspect            | NVIDIA :block (TMA)                          | Intel :block (LSC 2D)                        |
|-------------------|----------------------------------------------|----------------------------------------------|
| instruction       | cp.async.bulk.tensor + **mbarrier**          | OpSubgroup2DBlockLoadINTEL (SPV_INTEL_2d_block_io) |
| host descriptor   | **YES — CUtensorMap** (host cuTensorMapEncodeTiled, implicit kernel arg) | **NONE** — block params (base/width/height/pitch/coords) are in-kernel |
| min arch          | **sm_90+** (Hopper/Blackwell); sm_89 Ada CANNOT | DG2+ (not Gen12)                          |
| metal verify      | needs a **Hopper/Blackwell pod**             | **local B580** ✓                             |

=> Checklist items #5 (CuTensorMap implicit arg) and #6 (thread it through sub-fns + all
   callers) are **NVIDIA-ONLY**. Intel :block skips all descriptor machinery.
=> Two consequences: (a) :block on PTX RESURRECTS the mbarrier completion path (we kept the
   `cell-node` branch of semantic-make-async-barrier alive in 136 exactly for this — it is
   NOT a phantom for :block). (b) :block should FIX the 136 BMG regression (async :linear
   LOST to sync there because a 32x8 tile = 32 tiny per-row OpGroupAsyncCopy; LSC 2D loads
   the whole 2D strided tile in one message — the whole point of :block).

## Groundwork facts (verified 2026-07-12)
- `--ir-target-arch` is NOT implemented yet (documented in topology.md only). PTX arch comes
  solely from compile-to-ptx `compute-capability` default "sm_80". So Phase 0 must build the
  flag + storage first.
- Mode-dispatch threading (how load-tile learns the barrier's :mode): the scan pass tracks
  `(compiler-context-current-binding-name *compiler-context*)` when scanning a let binding —
  the SAME mechanism scratch tensors use for their unique names (analysis/core.lisp ~525). So
  make-async-barrier's scan/analyze records binding-name -> resolved-mode in a compile-side
  table (like *implicit-arg-map*); load-tile looks the barrier symbol up there. No env dig.
- CuTensorMap side-channel model = the scratch-tensor implicit-arg machinery:
  *side-channel-originators* / *implicit-arg-map* / propagate-implicit-arguments (Pass 1.5,
  analysis/core.lisp) already threads scratch args through sub-functions + all callers.

## Phases (each TDD)

PHASE 0 — front-end, defaults, gating (backend-agnostic, NO metal):
  0a. Implement `--ir-target-arch=<ID>` : parse in main.lisp, store in a new global
      (*ir-target-arch* defvar or a compiler-session field so it's readable during ANALYSIS),
      default sm_80 (ptx) / dg2 (spv) when unset [item 1], thread to compile-to-ptx.
  0b. Arch capability helpers: `%arch-supports-block-p` (sm_90+ for nvidia; not gen12 for intel),
      `%arch-vendor` etc.
  0c. Accept `:mode :block` in %parse-async-barrier-keys (drop the hard error) [item 2].
  0d. Error when :block unrealizable: PTX arch < sm_90 -> error; Intel gen12 -> error [item 3]
      (negative tests).
  0e. Mode-dispatch threading: record barrier binding-name -> resolved mode (scan side);
      load-tile/await consult it to pick lowering. (the core plumbing 136 deferred.)
  0f. Bare `(make-async-barrier)` -> arch-appropriate default: :block on capable arch else
      :linear [item 4]. NB consequence: with defaults, keyless barrier is :linear on NVIDIA
      (sm_80 default can't TMA) but :block on Intel (dg2 can).
  Tests: arch-default resolution, :block-parse, negative arch-gating (2), bare-default, threading.

PHASE 1 — Intel LSC 2D Block Load (simplest, LOCAL BMG verify) — DO FIRST:
  - SPV codegen: :block load-tile -> OpSubgroup2DBlockLoadINTEL; enable SPV_INTEL_2d_block_io
    in the llvm-spirv ext flags (we already do this for coop-matrix, compiler.lisp ~522). No
    descriptor. In-kernel block params (base ptr, memory width/height/pitch from the tensor;
    block x/y from tile coords).
  - Full 2D-tile matmul with :block, metal-verified on B580 [item 7 partial]. Expect it to
    beat the 136 :linear (and ideally the sync floor) at the tall-thin tile.

PHASE 2 — NVIDIA TMA / CuTensorMap (heavy machinery; needs sm_90+ pod):
  - CUtensorMap as side-channel implicit arg (extend *side-channel-originators* /
    *implicit-arg-map* / propagate-implicit-arguments — the scratch model) [item 5].
  - Sub-function threading + ALL callers (propagate-implicit-arguments already does this for
    scratch; extend + test) [item 6].
  - PTX codegen: cp.async.bulk.tensor...mbarrier + mbarrier completion (resurrect mbarrier
    barrier path).
  - Hoist (crisp-hoist-cuda): emit cuTensorMapEncodeTiled host-side (from tensor dims/strides +
    tile box), pass descriptor to launch as a __grid_constant__ / side-channel arg.
  - Metal-verify on Hopper/Blackwell pod (sm_120 Blackwell e.g. the old RTX PRO 4000 pod works;
    RTX 4000 Ada sm_89 does NOT) [item 7].

PHASE 3 — benchmark both :block variants (benchmarks/matmul + performance/) [item 8].

ORDER: Phase 0 -> Phase 1 (Intel, local) -> Phase 2 (NVIDIA TMA, needs pod) -> Phase 3.
Rationale: Intel-first is locally verifiable (fast iterate), simpler (no descriptor),
de-risks the :block front-end before the CuTensorMap lift, and doesn't block on provisioning
sm_90+ hardware.
