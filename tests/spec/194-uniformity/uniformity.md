# Endeavour 194 — two-level uniformity (workgroup vs warp)

Started and run overnight 2026-10-25/26 while Chris was away ("just go ahead and do the whole
endeavor ... make [decisions] and record [them]").  Everything below marked **D-194-n** is a decision
taken without him, for review.

## Why

It came out of the prefixsum single-pass work (`contests/gpu-mode/05-prefixsum-v2/prefixsum_fallback.crisp`,
findings in `put_temp_files_here/psum/FINDINGS.md`):

- **F2 (a bug).** `to-warp-uniform` answered `:uniform`, the same as `to-workgroup-uniform`.  So every
  proof that needs WORKGROUP uniformity accepted a value that only one warp agrees on.  A `sync-workgroup`
  under a warp-0-only `when` compiled to a `bar.sync` reached by one warp.
- **P1–P3 (the same hole, wider).**
  - **P1, P2:** a loop whose trip count differs per thread only tainted variables.  The barrier and
    shuffle checks never saw it, so `(dotimes (i (get-local-id 0)) (sync-workgroup))` compiled, and so
    did a shuffle in that loop.
  - **P3:** a `set!` inside a warp-only branch left the variable `:uniform`.
- **F7 (a bug).** Neither form actually broadcast.
  - `to-workgroup-uniform` emitted a barrier and passed each thread's OWN value through.
  - `to-warp-uniform` emitted a `__syncwarp` and did the same.
  - So both were unchecked assertions, contrary to ideal_001, which specifies a broadcast.
- **F1 (too strict).** Any `return-from-loop` made its loop divergent (184 D4), so a loop whose exit is
  WARP-uniform could not hold warp collectives.  The prefixsum lookback paid 0.77 ms for the workaround.
- **F3 / D4.** A barrier or collective inside a called function was checked only in the callee's own
  (convergent) context, never at the call site.
- **D3.** Warp-uniform values ought to be inferred (`reduce-warp` results, function results), not asserted.

## The model

Two questions at every program point:

| question | needed by |
|---|---|
| does every thread of the WORKGROUP arrive? (`*in-divergent-conditional*`) | barriers: `sync-workgroup`, `sync-wait`, `to-workgroup-uniform`, tile ops, calls reaching one |
| does every lane of the WARP arrive? (`*in-lane-divergent*`, new) | warp collectives: shuffles, `reduce-warp`, `to-warp-uniform`, `sync-warp`, calls reaching one |

Uniformity values: `:uniform` > `:warp-uniform` (new) > `:divergent`.  `:unknown` proves nothing.

Entering a scope governed by a condition, bound or exit of a given level:

- `:uniform` changes nothing.
- `:warp-uniform` sets the workgroup flag only: barriers are refused, collectives are allowed.
- Anything else sets both flags.

The rule applies to `if`/`when`/`unless`/`cond`, plain loop bounds (`dotimes` and the 172 variants),
and `return-from-loop` exits.  One helper, `%194-call-in-scope`, implements it.

## What changed (overlay: `overlays/crisp-compiler-overlay.lisp`, the 194 chunk)

| piece | src file on fold | what |
|---|---|---|
| `*in-lane-divergent*`, `*194-divergence-reason*`, `*194-loop-level*`, `*194-loop*`, `*194-fn-summary*`, `*194-function-summaries*`, `%194-loop-record`, `%194-fn-summary` | control.lisp / core.lisp | new state (two `defstruct`s -- new, not redefinitions) |
| `%194-level`, `%194-meet`, `%194-current-level`, `%uniformity-join` | core.lisp | the lattice; join gains `:warp-uniform` |
| `calculate-uniformity-state` | core.lisp | `to-warp-uniform` -> `:warp-uniform`; `warp-id` -> `:warp-uniform`; full-width `shuffle` from a uniform lane -> `:warp-uniform`; struct construction / field extraction / ct-arrays / views as uniform as their parts; a value `let` as uniform as its last form; generated accessors (`NAME~`) as uniform as their args; other calls from the callee summary; `(/ tid K)` (D-194-15) |
| `analyze-if-expression-impl` | control.lisp | two-level scope (was: one flag) |
| `%analyze-dotimes-core`, `%analyze-loop-variant-core` | control.lisp | a non-uniform bound now SETS the divergence flags (P1/P2), not only taints |
| `%analyze-loop-with-unroll`, `analyze-return-from-loop-expression`, `%194-judge-loop` | control.lisp | each exit records its level; barriers / collectives in the loop judged when it ends |
| `%warp-spec-check-sync`, `%shuffle-check-not-divergent`, `%tlc-check-not-divergent` | control.lisp | two-level checks; every barrier / collective recorded (`%194-note`) |
| `analyze-to-workgroup-uniform`, `analyze-to-warp-uniform` | control.lisp | they are collectives now; `to-warp-uniform` limited to `*shuffle-value-types*` |
| `%analyze-set!-simple-variable` | structs.lisp | set! in a warp-level scope / of a warp-uniform value -> `:warp-uniform` |
| `internal-compile-function` (wrapper) | core.lisp | fresh divergence context per function body; records its summary |
| `analyze-return-expression` (wrapper) | control.lisp | records each return's uniformity (D3) |
| `analyze-function-call` (wrapper) | core.lisp | a call reaches what its callee reaches (D4/F3) |
| `%analyze-reduce-warp` (wrapper) | ops.lisp | reduced variables become `:warp-uniform` (D3) |
| `initialize-compiler` (wrapper) | compiler.lisp | clears the summaries |
| `analyze-let-expression` (wrapper), `*194-lane-index-names*`, `%194-lane-index-form-p` | control.lisp | tracks names holding the local thread index (D-194-15) |
| `%194-lane-index-node-p`, `%194-one-dimensional-workgroup-p`, `%194-warp-index-division-p` | core.lisp | `(/ tid K)` -> `:warp-uniform` (D-194-15) |
| `generate-node-ir` for `semantic-to-workgroup-uniform` / `-to-warp-uniform`, `%194-workgroup-slot`, `%194-workgroup-barrier` | codegen.lisp | F7: the broadcasts |

The wrappers use the `(defvar *194-orig-X* (fdefinition 'X))` pattern.  On fold, put each one's body
into its src function and drop the `*194-orig-*` variables (as 193 did).

## Specs

On metal: BMG via `TEST-HOIST[L0]`, local.  `TEST-HOIST[CUDA]` is wired but not run here, since there's
no NVIDIA card on this machine.

| spec | checks |
|---|---|
| 01-to-workgroup-uniform-broadcasts-metal | F7: every thread holds thread 0's value; drives a `dotimes+` with a barrier |
| 02-to-warp-uniform-broadcasts-metal | F7: lane 0's value in every lane of both warps; drives a plain loop with a shuffle |
| 03-collective-in-warp-uniform-branch-metal | a shuffle under a warp-uniform `when` |
| 04-collective-in-warp-exit-loop-metal | F1: shuffle in a loop whose exit is warp-uniform; the two warps leave on different iterations |
| 06-reduce-warp-result-is-warp-uniform-metal | D3: a `reduce-warp` result decides an early exit and a branch, each holding a shuffle |
| 07-function-result-and-callee-collective-metal | D3 + D4 through calls |
| errors/01–14 | F2, P1, P2, P3, to-workgroup-uniform in a warp branch, if+ on a warp value, per-lane exit + shuffle, barrier + warp exit, calls reaching a barrier / collective, to-warp-uniform in a lane branch / of a float4, barrier + uniform exit (D-194-6), nested collective + exit on SPIR-V (D-194-7) |

## Found on the way

- **BUG 141 (BMG).** A loop holding a `return-from-loop` is mis-executed when it also holds:
  - a barrier, even when the exit is never taken; or
  - a warp collective inside a NESTED loop (`reduce-warp`'s butterfly).

  The LLVM IR is correct.  A flat shuffle in such a loop is fine.  Probes are in
  `put_temp_files_here/194/probes/`.  This drove D-194-6 and D-194-7.
- **BUG 109 again:** `reduce-warp`, inside a loop, of a value made by a per-lane `if` comes out
  per-lane on BMG.  Specs 06/07 use an arithmetic indicator, `(to-ulong (= lane 0ul))`.
- **BUG 142:** `(as-bits ...)` is unreachable from source (not exported).
- **Kernel parameters were `:unknown` in their own kernel body.**  Entry re-binds each storage handle
  as a struct construction, and `calculate-uniformity-state` had no clause for struct construction,
  field extraction or ct-arrays.  So every extent read as `:unknown`, and so did `tile-stride`'s hidden
  loop.  Fixed here; it was found as D1 fallout (below).

## Decisions for review (D-194-n)

1. **D-194-1: the lattice.**
   - `:warp-uniform` sits between `:uniform` and `:divergent`.
   - `:unknown` still proves nothing, so it scopes as divergent.
   - `provably-uniform?` and the `+` forms keep meaning WORKGROUP-uniform.
2. **D-194-2: `if+` / `when+` / `dotimes+` and `(declare (uniform p))` parameters need workgroup
   uniformity.**  A warp-uniform value no longer satisfies them.
   - `120-uniform/06` asserted the opposite.  It now uses `to-workgroup-uniform` (the file name is
     historical).
   - Its unit test `to-warp-uniform-creates-uniform` became `...-creates-warp-uniform`.
   - ideal_001's "Warp level loop uniformity ... that's what `dotimes+` checks" was rewritten to match.
3. **D-194-3: `to-workgroup-uniform` broadcasts from local thread 0, always with TWO barriers** (before
   the store, after it).
   - The first barrier protects the slot when the site runs again in a loop.  Skipping it outside
     loops would need node identity to survive AD/ANF, and the doc already calls the form heavy-handed.
   - The slot is an internal `addrspace(3)` global per site: `.shared` on PTX, a Workgroup OpVariable
     on SPIR-V.  Verified on BMG.
   - **Caveat:** the contest packager (`ptx_entry_to_inline_asm`) copies only the entry body, so a
     module-scope `.shared` would be lost.  A contest kernel should use `(declare (uniform ...))`
     instead.
4. **D-194-4: `to-warp-uniform` broadcasts lane 0 with a full-width index shuffle.**
   - It takes only `*shuffle-value-types*`; anything else is refused at analysis.
   - It is NOT added to the SPIR-V subgroup-pinning list: a lane-0 broadcast is right at any width.
5. **D-194-5 (D1): a loop bound that is not provably uniform scopes as divergent, like a condition.**
   - Fallout: `tile-stride`'s hidden loop, whose bound came from extents that read as `:unknown`.
   - Fixed by better inference (struct/field/ct-array/accessor uniformity), not by a looser rule.
   - Remaining fallout: see *Suite results*.
6. **D-194-6: a barrier stays refused in ANY loop holding a `return-from-loop`, even when every exit is
   workgroup-uniform.**  The execution model allows it, but BMG mis-executes it (BUG 141).
   - The original plan relaxed this too.  `errors/13` now pins the refusal.
7. **D-194-7: on any target but PTX (SPIR-V, or `:generic` IR that may become SPIR-V), a warp collective
   in a nested loop, or behind a call, inside a loop holding a `return-from-loop` is refused (BUG 141).**
   - PTX keeps the full relaxation.
   - Calls count as nested because IGC inlines them, and the callee's collective may itself be in a loop.
8. **D-194-8: function summaries are keyed by name and merged across overloads.**
   - A summary's result uniformity is argument-independent: parameters are `:unknown` inside a body
     unless declared or inferred uniform, which keeps it sound.
   - A callee not compiled yet at the call site is unchecked, and that is logged.
9. **D-194-9: each function body is analysed in a fresh divergence context** (the
   `internal-compile-function` wrapper).  A template instantiated mid-caller no longer inherits the
   caller's branch flags.
10. **D-194-10: `sync-warp` is a warp collective.**  It needs only its warp converged.  It used to be
    refused under ANY divergent conditional; now a warp-uniform condition allows it.
11. **D-194-11: `reduce-warp` inference covers the single and independent-clause forms only.**  The
    dependent form is not inferred.
12. **D-194-12: a full-width `shuffle` (index op) from a uniform/warp-uniform lane is `:warp-uniform`**
    (`:uniform` when the value is).  `warp-id` is `:warp-uniform`.
13. **D-194-13: refusal wording.**
    - The original conditional message is kept verbatim, because negative specs pin its phrases.
    - New cases get their own messages: a warp-only branch, a non-uniform loop bound, a call reaching
      a barrier or collective, and an exit-loop judgement.
14. **D-194-14: `184-cas-lowering/errors/03-barrier` now uses `(dotimes (i 10ul) ...)`.**  Its `(= i g)`
    compared an int with a ulong, a type error the old up-front barrier refusal used to mask.
15. **D-194-15: `(/ tid K)` is inferred `:warp-uniform`.**
    - It applies when `tid` is the local thread index (`get-local-linear-id`, or `get-local-id 0`, through
      casts or a let-bound name), the kernel declares a 1-D `local-size`, and `K` is a literal the warp
      size divides.
    - "Warp 0 does X" is written this way in ~20 contest kernels.  With the new call-site check (D4) and
      no inference, every one of them was refused (`prefixsum_pass1` was the first seen).
    - Provenance comes from an `analyze-let-expression` wrapper (`*194-lane-index-names*`).
    - Multi-dimensional workgroups are not inferred: sub-group mapping there is implementation-defined.
    - Specs 08 and errors/15.
16. **D-194-16: three existing specs relied on things being accidentally `:unknown`, and were edited.**
    - `120-uniform/errors/07` read `(~ IN 0)`, a kernel argument at a uniform index, which Endeavour
      124's rule makes `:uniform`.  It now uses an atomic read.
    - `157-split-barrier/errors/divergent-split` gated on a `tile-stride` coordinate, which is
      workgroup-uniform by construction.  It now uses `get-local-id`.
    - `120-uniform/06` (D-194-2).
17. **Inference added along the way (not decisions so much as fixes):**
    - A struct construction, field extraction or ct-array is as uniform as its parts, so kernel tensor
      parameters are `:uniform` in their own body.
    - A `let` used as a value is as uniform as its last form (ANF / `--differentiate`).
    - A generated accessor (`NAME~`) is as uniform as its arguments.
    - A view (`make-matrix` / `make-vector` / ... over a handle) is as uniform as its source and its
      runtime fields (135/09 re-views its parameters before a `matrix-multiply-tile-stride`).
    - Without these, D-194-5 refused every barrier in a `tile-stride` (forward and `_GRAD`).

## The prefixsum payoff

`contests/gpu-mode/05-prefixsum-v2/prefixsum_packed_rfl.crisp` ends its lookback walk with a warp-uniform
`return-from-loop`, where the done flag used to leave up to ~47 empty iterations per tile.

Leaderboard 2026-10-26, public score:

| GPU | before (packed) | now | rank before | rank now |
|---|---:|---:|---:|---:|
| H100 | 1075.6 µs | 757.0 µs | #24 | #10 |
| B200 | 622.5 µs | 461.3 µs | #25 | #15 |
| A100 | 1952.0 µs | 1692.5 µs | #23 | #21 |
| L4 | 9275.7 µs | 9147.4 µs | #21 | #13 |

All 50 contest kernels were compiled for PTX with the new compiler.  The only refusal is AG's
`prefixsum_lookback.crisp`, which never compiled.

## Suite results

Logs are in `put_temp_files_here/194/`; local machine with a BMG for the L0 on-metal specs.

| run | unit | E2E | negative |
|---|---|---|---|
| baseline, before 194 (`ci-stop` = 193) | 392/392 | 1554/1554 | 367/367 |
| r1: first full 194 | 392/392 | aborted: 3 spec unit files failed | 378/381 |
| r2: + struct/accessor inference, spec fixes | 392/392 | 1559/1574 | 380/382 |
| r3: + let-value / `tid/32` inference, non-PTX rule | 392/392 | 1575/1576 | 382/382 |
| **r4: + view inference (final)** | **392/392** | **1576/1576** | **382/382** |

What the D-194-5 fallout came down to, in order:
1. The `tile-stride` hidden loop (kernel tensors were `:unknown`).
2. `_GRAD` kernels (ANF `let` values).
3. "Warp 0 does X" (`tid / 32`).
4. Re-viewed parameters (`make-matrix`).

Each was fixed by inferring what was true, not by loosening a rule.  Three specs had passed only because
something was accidentally `:unknown` (D-194-16).

## Not verified

- ~~CUDA on metal~~ -- VERIFIED 2026-10-26 by Chris on an H100 PCIe (`run-on-pod.sh ... 194-uniformity`):
  22/22, binary run too.  That includes spec 01's static `.shared` broadcast slot alongside the CUDA
  hoist's dynamic shared memory.
- ~~`--debug`, `--single-pass`, `--differentiate` passes~~ -- CI clean (Chris pushed 2026-10-26).
- The contest packager (`contests/ptx_packager.py`) now refuses an entry whose body references
  module-scope PTX it cannot carry: a `.shared` / `.global` / `.const` variable, or a call.  NVPTX
  normally DEMOTES a `__crisp_wgu_N` slot into the kernel; `nvcc` accepts that `.shared` declaration
  inside the inline asm (sm_80 and sm_90 checked).  So `to-workgroup-uniform` kernels package fine,
  and only a slot shared by several functions is refused.  Not run on a GPU through the packager.
- The prefixsum lookback rewritten with `return-from-loop`: not done yet (next step after review).

## Fold notes

- Fold the 194 chunk of `overlays/crisp-compiler-overlay.lisp` into the src files named above.  Two
  `defstruct`s are new, not redefinitions.
- Regenerate the chapters, `reference.md`, the call graph and specials AFTER the fold, since the
  generators read src.
- `tests/ci-stop.txt` -> `194-uniformity`.
