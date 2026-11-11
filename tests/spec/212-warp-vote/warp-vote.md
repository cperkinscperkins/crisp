# Endeavour 212 — warp-ballot / warp-any? / warp-all?

Branch `resume-gpumode`, 2026-11-10.  Part B of `plan/proposal-warp-ballot-and-shifts.md`.

## Why

The sort_v2 radix sort's downsweep ranks keys with two 4-bit splits.  A CUDA probe (diagp_ballot.py, H100
submission 970446) measured the alternative: one 8-bit ranking from 8 warp ballots, CUB-style.  At equal
occupancy it was 233 us per pass faster than a CUDA port of the current splits, and 95 us per pass faster
than Crisp v1j.  Verdict: GO.  Crisp had no ballot.

## Decisions

- **Chris, 2026-11-10:** `warp-ballot` returns `uint`.  A profile whose warp is wider than 32 lanes is a
  compile error until such a target exists (option a).
- **Made while implementing (for review): the predicate is a CONDITION, not a `bool`.**  The design doc
  wrote `predicate:bool`, but Crisp's comparisons are typed `int` inside the compiler (0 / 1; `if`
  lowers its condition as `icmp ne cond, 0`).  A strict bool check would refuse
  `(let ((p (< a b))) (warp-ballot p))`.  So a vote takes what `if` takes: a comparison, or any integer
  scalar, read as nonzero-is-true.  A float is refused (errors/02).
  - `warp-any?` / `warp-all?` give a 0 / 1 `int`, exactly as a comparison does.  So `(when (warp-any? ..) ..)`
    and `(to-ulong (warp-all? ..))` work like any condition.
- **The width rule applies to `warp-ballot` only.**  A bool answer fits any warp, so `warp-any?` and
  `warp-all?` are not width-limited.
- **No member-mask argument.**  A vote is a warp collective, so every lane of the warp reaches it, and the
  mask is always the full warp (errors/03).

## Implementation (overlay, to fold)

- **Analysis:** `analyze-212-vote-op` (src/analysis/ops.lisp), registered by `*212-vote-op-names*` from a
  whole-function copy of `%185-register-math-op-analyzers`.
  - It checks the arity, the predicate type, and the ballot's width.
  - It calls `%shuffle-check-not-divergent`.  That gives the shuffles' collective rule verbatim: the
    refusal in lane-divergent code, the loop-exit record, and the call-site summary (`%194-note`).
  - It produces a `semantic-hw-op` (`%212-warp-ballot` / `-any` / `-all`).
- **Collective list:** `*warp-collective-operator-names*` gains the three names (whole-value
  `defparameter`).  That gives SPIR-V subgroup-size pinning (errors/05), the BUG 141 nested-loop rule, and
  the call-graph reach.
- **Uniformity:** `calculate-uniformity-state` (whole-function copy, script-extracted) has a vote clause
  ahead of the generic `semantic-hw-op` clause.  A vote is `:warp-uniform`, or `:uniform` when its
  predicate is.  `%212-vote-node-p` is the type test.
- **Lowering:** `%hw-lower` methods call `%212-vote-lower`.  The predicate is coerced to i1 first
  (`%212-pred-i1`: icmp ne 0).
  - PTX: `llvm.nvvm.vote.{ballot,any,all}.sync` with mask -1.
  - SPIR-V: `__spirv_GroupNonUniformBallot`, then component 0 of its `<4 x i32>`;
    `__spirv_GroupNonUniformAny` / `All`.  Subgroup scope 3.  The backend adds the GroupNonUniformBallot
    and GroupNonUniformVote capabilities itself.
  - any / all are zext'ed to i32.  There is no helper function, because the BUG-120 noinline trick is for
    integer arithmetic bodies, not group ops.
- **AD:** the three names join the zero-gradient integer list in `%185-math-backward` (whole-function
  copy of the 211 copy).
- **Validators:** in `overlays/spec-runner-overlay.lisp`.
  - `validate-ptx-212-vote`: all three `vote.sync` forms, each with mask -1, and no `shfl.sync`.
  - `validate-spv-212-vote`: the three ops and both capabilities, and no shuffle.

## Specs

| spec | what it checks |
|---|---|
| 01-ballot-metal | masks 10 / 31 / 0 / 8192; popcount(all-lanes ballot) = warp-size; same mask in every lane; low 16 bits (BMG) |
| 02-ballot-rank-metal | the CUB rank idiom: 2 ballots -> peers -> rank 0 0 0 1 1 1 2 2, peer counts (BMG) |
| 03-any-all-metal | any / all, including none / every-lane edges (BMG) |
| 04-vote-result-is-warp-uniform-metal | a branch on warp-any?, a branch on a ballot mask, and a loop exit on warp-all? each hold a shuffle (BMG) |
| 05-lowering-ptx-spv-metal | PTX / SPIR-V validators above, plus a mask and a bool in one expression (BMG) |
| 06-vote-diff | VERIFY-AUTODIFF: d/dA = 17 with all three votes on the active path (BMG: analytical 17.0, numerical 17.0) |
| errors/01-vote-in-divergent-branch | "warp-ballot is a warp collective" |
| errors/02-ballot-float-predicate | "the predicate must be a condition" |
| errors/03-vote-arity | "takes one argument" |
| errors/04-ballot-warp-over-32 | a 64-lane `def-hardware-profile` in the file: SPIR-V refused "does not fit the 32-bit mask"; PTX (32 by architecture) passes |
| errors/05-vote-unpinned-subgroup | "cannot be pinned" on SPIR-V: proves the votes are in the collective list |

Every metal spec stores only width-independent values, so the same expectations hold on 16-lane BMG and
32-lane NVIDIA.  The CUDA hoists run where nvcc exists; the H100 run is the sort itself.

## Log

- 2026-11-10: specs first, red with "Unsupported form 'WARP-BALLOT'".
- 2026-11-10: overlay in, then 11/11 pass.
  - BMG metal: every buffer exact on the first run.  The first expectations listed 6 or 8 elements;
    the hoist harness prints 4 per buffer, so they were split into 4-element buffers.
  - `--differentiate`: 11/11, VERIFY-AUTODIFF analytical 17.0 = numerical 17.0.
  - PTX by hand: one `vote.sync.ballot.b32` / `.any.pred` / `.all.pred` per vote, mask -1, no shfl.
  - SPIR-V by hand: `GroupNonUniformBallot` / `Any` / `All` and both capabilities.
- Controls (compile-only, put_temp_files_here/212/ctl):
  - The spelling errors/02 recommends, `(warp-ballot (> x 0.0))`, compiles.  So does an integer
    predicate `(logand lane 2u)`, which becomes `setp.ne` then `vote`.
  - A ballot mask ANDed with a per-lane bit is lane-varying.  A shuffle under it is refused, so the
    inference is not over-generous.

## Payoff: sort_v2 v1k (ballot-ranked downsweep)

Source: put_temp_files_here/gpumode/sort/v1k_downsweep.crisp (arms: contests/gpu-mode/07-sort-v2/
sort_radix_v1k*.crisp).  Every arm BMG bit-exact (put_temp_files_here/sort/cl_sort.py, 42 cases).
Same-machine A/Bs under eval.py's procedure, H100, 100M, mean of 8 (diagab_212.py):

| arm | what | us |
|---|---|---:|
| v1j | two 4-bit splits (the current best) | 3690 / 3698 |
| v1k | ballots; key loaded inside the ranking loop; wcnt 4096 words (60.5 KB shared) | 4787 |
| v1k2 | v1k, wcnt 2048 (52 KB: 4 workgroups per SM instead of 3) | 3956 / 3955 |
| **v1k3** | v1k2 + the tile loaded FIRST (v1j's 128-bit loads), ranking reads shared memory | **3165 (-14.3%)** |
| torch.sort | CUB | 5327 / 5337 |

- **v1k -> v1k2: occupancy.**  8 KB of shared memory cost 830 us, through 3 vs 4 workgroups per SM.
- **v1k2 -> v1k3: latency in a serial loop.**  The per-round sync-warp keeps a global load from being
  hoisted, so each of the 16 rounds waited for a DRAM / L2 load.
- **The 16-lane trap, found on BMG by v1k's first build:** `(lognot ballot)` sets bits 16..31.  `peers`
  starts from FULL, the warp's real lanes; spec 02's z buffer pins it.
- **Not folded yet: the wcnt size differs per target** (8 x 256 on NVIDIA, 16 x 256 on BMG).
  - `(make-scratch-vector smem-vec (* 256 (/ 256 (warp-size))))` compiles, but the L0 hoister rejects the
    metadata: ":size-expr (* 256 (/ 256 (WARP-SIZE))) is neither an integer nor a list of 1 integers".
    (warp-size) is not folded before the size expression is written out.
  - A literal 4096 on both targets costs the H100 a workgroup per SM (v1k vs v1k2).
  - A literal 2048 overruns shared memory on BMG.

## Scratch sizes may name (warp-size) (Chris: option 1, 2026-11-10)

- `%fold-scratch-size-expr` (src/analysis/structs.lisp, new) folds a make-scratch-* size to an integer for
  the target being compiled.  It handles integer literals, `+ - * /`, `(warp-size)`
  (`%173-warp-size`: 32 on PTX, the profile's `:simd-width` on SPIR-V), and per-dimension lists element
  by element.
  - Anything else is returned unchanged: keywords such as `:match-workgroup-size`, runtime names, a
    division by zero.
- `%extract-scratch-size-expr` (whole-function replacement) returns the folded value.  Its three callers
  get it: the Pass 1 scan, the analyzer, and the AD rebuild of a scratch form.
- Spec 07-scratch-sized-by-warp-size-metal: red first (both hoists failed), then BMG gives
  100 101 102 103.  By hand: metacrisp `:size-expr 8` on PTX (2 warps x 4) and `16` on BMG (4 x 4).  The
  CUDA hoist sizes the buffer at 32 bytes.
- **The sort is folded: sort_radix.crisp = v1k3**, wcnt = `(* 256 (/ 256 (warp-size)))`.
  - BMG bit-exact (42 cases), with wcnt folded to 4096.
  - crisp_sort_v1.py / diag_sort_v1.py rebuilt.  Their PTX and ABI are byte-identical to the measured
    v1k3 arm (downsweep smem 52352 bytes on NVIDIA).
