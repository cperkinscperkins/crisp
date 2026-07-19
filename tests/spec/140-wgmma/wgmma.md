In this endeavor we add NVIDIA Hopper `wgmma` (warpgroup async MMA) support — the 4th-gen
tensor-core instruction — as the lever to close most of the ~5x gap to cuBLAS that Chapter 3
(warp specialization, endeavor 139) left open.

This is "Chapter 4".  It extends endeavor 139 and stays on the same branch.  It will also be
documented in docs/topology.md (the new forms below).

================================================================================
DEV PLAN (recorded 2026-07-19 — decisions + sequence; agreed with Chris)
================================================================================

## Why this endeavor

Chapter 3 (139) got the warp-specialized `:block` matmul to ~83 GFLOPS at 4096 (ws2 = 1 producer +
2 consumers, the fastest Crisp matmul), beating the 138 ring.  But cuBLAS is still ~5.2x ahead
(433K vs 83K @4096).  Benchmarking established the remaining gap is NOT tile shape — it is the
INSTRUCTION: we emit Ampere-era warp-level `mma.sync.m16n8k8` (via @llvm.nvvm.mma...); cuBLAS uses
Hopper `wgmma.mma_async`.  Closing that is this endeavor.

## What wgmma is (vs our current mma.sync)

`wgmma.mma_async` differs from `mma.sync.m16n8k8` in four fundamental ways:
  1. WARPGROUP-scoped — one instruction spans a warpgroup (4 warps / 128 threads), with the
     accumulator spread across all 128 threads.  One `m64n128k8` produces 64x128 = 8192 outputs vs
     mma.sync's 16x8 = 128 (~64x more/instruction), and the big accumulator over 128 threads means
     ~N/2 registers/thread instead of our 250 — THIS is the occupancy story that closes the gap.
  2. Operands read straight from SMEM via 64-bit MATRIX DESCRIPTORS — no ldmatrix/register staging.
  3. ASYNC — wgmma.fence + wgmma.mma_async + wgmma.commit_group + wgmma.wait_group, so the MMA
     overlaps other work (like cp.async).
  4. sm_90a only (we already auto-upgrade from 137).

Emission: likely INLINE ASM (137's established pattern for Hopper-specific ops), though LLVM 21.1.6
does carry @llvm.nvvm.wgmma.* intrinsics.  Decide in Step 0.

## NODE STRATEGY — prototype reuses the mma node, clean up after correctness (2026-07-19)

A dedicated `semantic-wgmma-accumulate` defstruct would be the clean design, but a NEW struct can't
be late-bound in an overlay (must be patched into semantic.lisp + 2 core.lisp etypecases) — so it
would block every prototype iteration on a patch round-trip, which is painful while wgmma correctness
is still METAL-uncertain.  DECISION: for Steps 0-1 (prototype), REUSE the existing
`semantic-mma-accumulate` node (slots c/a/b-node + type + source-location) and DISPATCH to wgmma
codegen by the accumulator TYPE (a minted WGMMA-ACC-F32-64xN record; N/K recovered from a dims
table).  This keeps Step 0/1 entirely in the overlay — no struct patch, fast metal iteration.  ONCE
wgmma is metal-correct, graduate to a clean dedicated `semantic-wgmma-accumulate` node (one patch to
Chris, informed by what the codegen actually needed).  The user forms are unaffected either way.

## KEY IMPLEMENTATION FACTS (from studying src/mma.lisp, endeavor 132/139)

- make-register-tile mints a RECORD type `REGISTER-TILE-ACC-F32-MxN` (fields = (M/16)x(N/8) fragment
  records) via `register-struct-definition` (a runtime call -> OVERLAY-friendly), and rewrites to
  `(%construct-struct tile-name (make-register-fragment 16 8 init) ...)`.  make-wgmma-accumulator is
  the analog: mint `WGMMA-ACC-F32-64xN` with N/2 flat f32 fields (the wgmma D accumulator is N/2 f32
  regs/thread), rewrite to %construct-struct of N/2 zero floats.
- mma.sync is emitted as the NVVM INTRINSIC `@llvm.nvvm.mma.m16n8k8.row.col.tf32` in `%emit-nvvm-mma`
  (mma.lisp:257): extract A(4)/B(2)/C(4) fp32 regs from the fragment records, call, reconstruct.  The
  wgmma emitter is the analog but INLINE ASM: build 2 SMEM matrix descriptors + fence/mma_async/
  commit/wait, in/out the N/2 accumulator regs.
- Analyzers are dispatched from a TABLE at mma.lisp:~932 (name-string -> analyzer fn).  Register
  MAKE-WGMMA-ACCUMULATOR + WGMMA-ACCUMULATE-VIA-TILE there (overlay the registration fn).
- store-tile already overloads on register-tile type (analyze-store-tile-mma); add a wgmma-accumulator
  branch that stores the N/2 f32 regs at the warpgroup thread->element mapping.
- SMEM tile ADDRESS (needed for the descriptor) — Step 1 detail: recover the addrspace(3) base of the
  A/B scratch tiles (how load-fragment-a gets at the SLM tile).

## AGREED SURFACE (2026-07-19)

Two NEW forms, mirroring the make-register-tile / mma-accumulate-via-tile pair:

    (make-wgmma-accumulator float (64 N) 0.0)      ; the D matrix, 128-thread warpgroup layout
    (wgmma-accumulate-via-tile (64 N 8) D A B)     ; D += A·B ; A, B are SMEM tiles

- DEDICATED accumulator constructor (NOT a :flag on make-register-tile) — the warpgroup (128-thread)
  layout is a genuinely different thread->element mapping than the warp-scoped (32-thread) register
  tiles, and store-tile must dispatch on it.  `store-tile D C (...)` surface is UNCHANGED — it
  detects the wgmma accumulator and uses the warpgroup store mapping.  (Chris agreed dedicated.)
- Distinct macro `wgmma-accumulate-via-tile` (NOT overloading mma-accumulate-via-tile) — agreed;
  interface may still be adjusted as we learn.

## SHAPE RULES — grounded in machine truth, not fantasy-flexible

- M is FIXED at 64 (wgmma is always m64).  Reject anything else.
- N is a multiple of 8, 8..256 (the m64nNk8 family).  Pin the EXACT ISA-valid set when implementing.
- K is determined by the operand DTYPE, not free: tf32 -> 8, f16/bf16 -> 16, int8 -> 32, etc.  The
  macro reads element types off the A/B/D tiles and validates K against them.

## DTYPE — tf32 first, but the surface is dtype-driven

Because K and the wgmma variant come FROM the tile element types, the surface does not change when
we add f16/bf16 later — we just implement the extra (dtype -> K, wgmma variant, accumulator/
descriptor bits) rows.  First implementation is tf32-only.  Keep an eye toward f16/bf16 (k16).
Eventually Crisp will support quantized integers + microfloat blocks; we EXPECT to revisit the
descriptor + accumulator INTERNALS for sub-byte / block types, but the two forms above should
survive that.  (Chris's direction.)

## DEFERRED — but flagged

1. ASYNC control.  wgmma is async — even a single one needs fence/commit_group/wait_group.  Steps
   1-2: `wgmma-accumulate-via-tile` is SYNCHRONOUS (wraps fence/commit/wait itself, one accumulate =
   one complete op).  K-loop OVERLAP (Step 3) needs batched commit/wait — design THAT interface when
   it is concrete.
   >>> CHRIS'S IDEA (2026-07-19): leverage the existing `:mode` key on make-async-barrier /
       make-async-barrier-ring.  Worth pursuing: wgmma's commit_group/wait_group(depth) is
       STRUCTURALLY like cp.async's (the 138 :linear path already has commit_group + wait_group with
       a group-count/depth), NOT like the mbarrier.  So a `(make-async-barrier :mode :wgmma)` that
       lowers to wgmma.commit_group/wait_group, consumed by the existing `await` surface, could reuse
       the async-barrier + await machinery for wgmma's async completion.  Leading candidate for the
       Step-3 async interface; pin it then.
2. local-size constraint.  A warpgroup is 128 threads, so a wgmma kernel's local-size must be a
   multiple of 128 (one or more warpgroups).  Steps 1-4 use exactly one warpgroup (local-size 128);
   the multi-warpgroup + warp-spec-producer combination is Step 5.

## TDD SEQUENCE (all on the 139 branch; only Step 0 + front-end bits are pod-free — wgmma
## correctness is METAL-BOUND: bad descriptor/accumulator bits are silent MMA_WRONG, invisible in PTX)

    [x] 0  front-end scaffolding DONE 2026-07-19 — ALL OVERLAY (crisp-compiler-overlay.lisp).
           make-wgmma-accumulator (mints WGMMA-ACC-F32-64xN record = N/2 flat f32 fields, via
           register-struct-definition + %construct-struct), analyze-wgmma-accumulate (reuses
           semantic-mma-accumulate typed as the accumulator; codegen dispatches by %wgmma-acc-type-p),
           analyze-wgmma-accumulate-via-tile (-> (set! D (wgmma-accumulate D A B)), no fragment walk),
           %check-wgmma-shape (M=64, N mult-of-8 in [8,256], K=8), register-mma-analyzers overridden
           with the 3 entries, generate-node-ir (semantic-mma-accumulate) overridden with a wgmma
           branch = NO-OP STUB (returns the accumulator; Step 1 fills the real emission).
           - NO package.lisp patch needed: register-mma-analyzers interns the form names in
             crisp-language and the kernel reader resolves to the same symbols — the "Unsupported
             form" gotcha did NOT bite (unlike 138's ring-get).  Confirmed by direct compile.
           - Decision on emission: INLINE ASM (137 pattern) for Step 1 — leaning that way; final call
             when I build the descriptor.
           - Tests: 00-wgmma-forms (compile smoke, stub) + errors/01-03 (bad M / N / K — each gives
             the exact wgmma message).  Verified via direct crisp-compile (ci-stop is 139, so the
             runner skips 140 until Chris advances it).  110/110 on the 13x MMA specs (the
             register-mma-analyzers + mma codegen overrides did not regress 132/135/137/138/139).
    [ ] 1  (THE CRUX) a minimal single m64n64k8 wgmma: one warpgroup (local-size 128), A/B from a
           PLAIN SMEM copy (no TMA, no async, no warp-spec), accumulate -> store.  TDD: tiny fixed
           matmul, MMA_CORRECT on H100.  Isolates the instruction + descriptor + accumulator layout +
           store — the correctness core.
    [ ] 2  wgmma fed from a TMA-staged tile (:block) — get the descriptor/swizzle agreement right
           (NOTE: our TMA currently uses CU_TENSOR_MAP_SWIZZLE_NONE — hoist-cuda/main.lisp:926,
           metadata.lisp:580).  Single-tile :block wgmma matmul, MMA_CORRECT.
    [ ] 3  ASYNC wgmma (commit_group/wait_group, likely via the :mode :wgmma idea) over a multi-K
           loop.  Pin the async interface here.
    [ ] 4  grid-strided GEMM + BENCHMARK vs cuBLAS.  Where the big jump should show.
    [ ] 5  fold in WARP SPECIALIZATION — producer warp feeding a consumer WARPGROUP (the full Hopper
           CUTLASS shape).  Multi-warpgroup CTAs.

## RISKS (honesty up front)

- The SMEM matrix descriptor (64-bit bit-pack: base addr, leading/stride byte offsets, swizzle mode,
  base offset) is the classic Hopper footgun — wrong bits = silent MMA_WRONG, not a compile error.
  METAL-BOUND debugging; IR shows structure only.
- The warpgroup accumulator thread->element mapping must match the ISA exactly or the store scrambles
  — again only metal tells.
- Scope: comparable to 132 (MMA fundamentals) + 137 (TMA) combined, and more pod-dependent.

## Reconciliation note
AntiGravity is concurrently improving the benchmarking on a separate branch — merge conflicts in
benchmarks/matmul/ are expected.  Chris wants THIS assistant (not AG) to do that reconciliation, AFTER
the warp-spec + wgmma work is done.  Until then, keep everything on the 139 branch.
