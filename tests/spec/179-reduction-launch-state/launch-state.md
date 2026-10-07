Endeavour 179 — reduction launch state
=======================================

Opened 2026-10-03, as phase 1 of `plan/benchmark-reductions.md`.

Benchmarking launches the same kernel many times in a row.  Some reduction kernels keep state in
memory across launches, and the host must reset it or the next launch is wrong.  Today that
requirement is **not recorded anywhere a host program can read it**.  This endeavour either
removes the requirement (the kernel resets itself) or records it in the metacrisp, so a fixture,
a hoist, or a user's own host code can honour it.

This is not only a benchmark concern.  Any host program that calls a last-man-standing reduction
twice gets a stale answer on the second call.


Observations (from source, 2026-10-03)
--------------------------------------

| construct | state that persists across launches | after a second launch |
|---|---|---|
| `grid-reduce-last-man!` (and `grid-reduce!` default, `reduce-vec` default, dependent multi) | `:atomic-counter`, a global uint.  `atomic-add!` draws tickets; **nothing ever resets it** (`src/analysis/ops.lisp`, `%grid-reduce-last-man-expand`). | The counter starts at `num_groups`, so no workgroup draws the winning ticket, nobody sweeps, and **the output cell keeps launch 1's value**.  If the input didn't change, that value is still correct, so checking the final output passes. |
| `grid-reduce-atomic!` / `:atomic` | the **output cell** itself (accumulated into) | output = k × answer after k launches |
| `grid-reduce-cas!` / `:cas` | the **output cell** itself (CAS-combined into) | output = answer combined k times (`+` → k×; `max` → harmless) |
| `grid-reduce-second-stage!` | global partials, **overwritten** every launch | safe |
| `:election-flag-cell` | local memory, recreated per launch | safe |
| `:local-scratch-vec` | local memory | safe |

History: BUG 084 (endeavour 175) hit the counter in VERIFY-AUTODIFF, which re-launches the forward
kernel for each finite-difference probe.  The fix went into **the test harness**
(`%vad-zero-global-scratch` runs from `launch-kernel-1d`), not the kernel or the metacrisp.  The
generated L0 hoist zeroes implicit scratch once, at setup.

The last-man VJP (`%175-vjp-grid-reduce-last-man`) ignores the counter, so nothing below affects
autodiff.


Decisions (2026-10-03, with Chris)
----------------------------------

- **D1 = (a)**: the kernel resets its own counter.
- **D2**: agreed.  `:launch-init (:identity <value>)` on `:atomic`/`:cas` output parameters.
- **D3**: **no new directive.**  The general "launch it twice" tool is a benchmarking concern; the
  benchmark fixture's change-the-input probe covers it.  For the spine, VERIFY-AUTODIFF already
  re-launches the forward kernel once per finite-difference probe.  The runner now zeroes global
  scratch **once at bind** instead of before every launch, so the existing last-man
  VERIFY-AUTODIFF specs in 175–178 are the on-metal relaunch tests (documented in
  `docs/tests.md`, "Global scratch is zeroed once").

### Red state, measured 2026-10-03 (BMG, after the runner change, before any compiler change)

| spec (`--differentiate`) | strategy | result |
|---|---|---|
| 175/26-diff-grid-reduce-last-man | last-man | **FAIL** analytical=1.0 numerical=0.0 |
| 176/08-diff-grid-reduce | default (last-man) | **FAIL** analytical=1.0 numerical=0.0 |
| 176/14-diff-grid-reduce-independent | default (last-man) | **FAIL** analytical=1.0 numerical=0.0 |
| 178/10-diff-reduce-vec-sum | default (last-man) | **FAIL** analytical=1.0 numerical=0.0 |
| 175/31-diff-grid-reduce-second-stage | second-stage | PASS (control) |
| 175/40-diff-grid-reduce-cas | cas | PASS (control) |
| 178/11-diff-reduce-vec-atomic | atomic | PASS (control) |

`launch-state.unit.lisp`: the five D1 tests fail on the reset count with the "draws a ticket"
assertion passing (so the probes are sound), the four D2 annotation tests fail, and
`last-man-output-needs-nothing` passes.

Three lowering sites draw a ticket and each needs the reset (`src/analysis/ops.lisp`):
`%grid-reduce-last-man-expand` (single), `%fused-grid-reduce-form` (independent),
`%fused-grid-reduce-dependent-form` (dependent).

The options as originally written:
--------------------------------

### D1 — the last-man counter: the kernel resets it, or the host does?

**(a) Self-reset (recommended).**  The workgroup that draws the winning ticket stores `0u` to the
counter after its final sweep.  This is safe because every other workgroup has already done its
`atomic-add!`; that's how the winner knows it's last.  The cost is one store per launch.  This is
the classic CUDA `threadFenceReduction` sample pattern.  Last-man kernels become relaunchable with
no host involvement, BUG 084's harness re-zero becomes belt-and-braces, and there's no metadata to
get wrong.

Caveat: the counter must start at zero on the very first launch.  The hoist already zero-inits
implicit scratch once, so that holds.  A user who supplies an explicit `:atomic-counter` still
has to zero it once, which is the documented contract today.

**(b) Host resets, recorded in the metacrisp.**  The counter's `:implicit-params` entry gains
an annotation (see D2), and every host program (hoist, VAD, fixtures) zeroes it before each
launch.  This touches more code and leaves every host program able to get it wrong.

### D2 — atomic/cas output cells: record "must hold identity before each launch"

The kernel **cannot** reset these itself: knowing who is first needs a grid-wide sync, which is
the thing these strategies avoid.  So the host must do it, whatever D1 decides, and the
metacrisp is the place to say so.

Proposed shape (names open): on the `:declared-signature` entry of the output parameter,

```lisp
(:name "out" :type out-cell :direction :out ... :launch-init (:identity "0.0f"))
```

and, if D1 = (b), on the counter's `:implicit-params` entry `:launch-init :zero`.

Scope limit for the first cut: annotate only when the reduction's return cell **is** a kernel
parameter (or a parameter accessed at a fixed index).  A return cell reached through
arithmetic on a parameter gets a kernel-level note, or an error, rather than a guess.  Which
one: open.

What about when the identity doesn't fit in a literal (a struct identity in dependent multi)?
Dependent multi is last-man only, so (a) covers it; D2 only concerns `:atomic` / `:cas`,
whose operators (`+`, `min`, `max`) always have scalar identities.  That's worth stating as a
claim and testing.

### D3 — how do specs launch a kernel twice?

None of the existing spec directives launch more than once.  The observable claim, "launch
twice with a different input, get the second answer", needs either:

- a new directive, e.g. `;; HOIST-RELAUNCH: input <- ...` on a `TEST-HOIST[L0]` spec
  (a spec-runner change, protects real users), or
- coverage only through the benchmark fixture's change-the-input probe (no runner change, but
  then only the benchmark suite checks it).

Recommendation: the directive.  This is a correctness contract, so it belongs in the spine.


Plan
====

- [x] decide D1, D2, D3 (with Chris)
- [x] write TDD tests: `launch-state.unit.lisp` (D1 IR reset ×5 forms, D2 `:launch-init` ×4 +
      one absence check); on-metal = the existing 175–178 last-man VERIFY-AUTODIFF specs via the
      runner change
- [ ] negative: whichever "can't annotate this return cell" case D2 chooses to refuse (open)
- [x] VERIFY-AUTODIFF runner zeroes global scratch once at bind (`tests/verify-autodiff-runner.lisp`)
      + `docs/tests.md`
- [x] bump `tests/ci-stop.txt` to `179-reduction-launch-state`
- [x] implement (overlays) -- see "Implementation" below
- [x] on-metal BMG: 175/26, 176/08, 176/14, 178/10 green (analytical=1.0 numerical=1.0); controls
      175/31, 175/40, 178/11, 178/12 still green
- [ ] CUDA: last-man self-reset on NVIDIA (next pod; 176/07 forward + a [CUDA] VAD spec if one fits)
- [x] update `reductions-excerpt.md` + `ideal_001.md`: "Launching the Kernel Again" after the
      Phase 2 trade-off matrix (chapters regenerate at fold)
- [ ] decide whether BUG 084's harness re-zero stays (belt and braces) or goes
- [x] fold into src/, regenerate reference / call graph, suites -- 2026-10-06, see "Fold-back" below


Implementation (overlay, 2026-10-03)
====================================

Appended to `overlays/crisp-compiler-overlay.lisp`, one block, each form tagged with its target
file.  The seven replaced functions were **script-extracted** from src/
(`put_temp_files_here/179/extract.py` + `transform.py`), so each differs from src/ only by the
lines marked `179`, and the fold-back diff will show exactly that.

| form | target | change |
|---|---|---|
| `*reduction-launch-init*` (defvar) | src/compiler.lisp | NEW: `(kernel . param)` → `:launch-init` plist |
| `%reduction-identity-value` | src/analysis/ops.lisp | NEW: identity → number / `:infinity` / NIL (literals, suffixed literals, `type-min/max/infinity`, `(- x)`) |
| `%note-reduction-launch-init` | src/analysis/ops.lisp | NEW: records against `compiler-context-current-compiling-function`; warns if the return cell is not a kernel's own parameter |
| `%reduction-launch-init-for` | src/metadata.lisp | NEW: lookup |
| `%grid-reduce-last-man-expand` | src/analysis/ops.lisp | D1: `(set! (~ ,ctr) 0u)` after the final sweep, thread 0 of the elected workgroup |
| `%fused-grid-reduce-form` | src/analysis/ops.lisp | D1 same, in the last-man branch; D2 note per clause in the `:atomic`/`:cas` branch |
| `%fused-grid-reduce-dependent-form` | src/analysis/ops.lisp | D1 same |
| `%grid-reduce-atomic-expand` | src/analysis/ops.lisp | D2 note |
| `%grid-reduce-cas-expand` | src/analysis/ops.lisp | D2 note |
| `generate-declared-signature` | src/metadata.lisp | D2: `:launch-init` on the entry |
| `initialize-compiler` | src/compiler.lisp | `(clrhash *reduction-launch-init*)` |

Checked by hand, not only by the tests:
- IR (single last-man): the `store i32 0, ptr addrspace(1)` is in the block that stores the result,
  after the final-sweep loop exits, inside the `when+` election branch.
- metacrisp: `:cas` min with `(type-max float)` → `(:identity 3.4028235e38)`; `:atomic` max with
  `(- (type-max float))` → `(:identity -3.4028235e38)`; a last-man `+` output carries nothing.

Suites on the overlay build (2026-10-03, BMG): unit 341/341, E2E 1376/1376 (includes
`launch-state.unit.lisp`), negative 311/311.  `--differentiate` was run only for the 8
VERIFY-AUTODIFF specs above; the full `--differentiate` pass is left to CI.

Still open: the non-parameter return cell is a **warning**, not an error (D2's "refuse or note").


Fold-back (2026-10-06)
======================

Folded by `put_temp_files_here/179/fold.py`: the SAME exact-anchor insertions `transform.py` made
to the overlay copies, applied to the src files themselves (src was verified unchanged since the
extraction), line endings following the surrounding text, all-or-nothing.  Every one of the 11
forms in src is identical to its overlay copy (compared after CRLF normalisation), with exactly
one definition each.

| form | now in |
|---|---|
| `*reduction-launch-init*` | `src/compiler.lisp`, after `*implicit-scratch-size-expr-map*` |
| `initialize-compiler` (+ clrhash) | `src/compiler.lisp` |
| `%reduction-launch-init-for` | `src/metadata.lisp`, before `generate-declared-signature` |
| `generate-declared-signature` (+ `:launch-init`) | `src/metadata.lisp` |
| `%reduction-identity-value`, `%note-reduction-launch-init` | `src/analysis/ops.lisp`, before `%grid-atomic-op-name` |
| `%grid-reduce-atomic-expand`, `%grid-reduce-cas-expand`, `%grid-reduce-last-man-expand`, `%fused-grid-reduce-form`, `%fused-grid-reduce-dependent-form` | `src/analysis/ops.lisp` (in place) |

`overlays/crisp-compiler-overlay.lisp` is back to its 20-line header.  The overlay was emptied
BEFORE the build and the suites, so they tested the folded src.  Regenerated: `docs/reference.md`,
`docs/call_graph.md`, `docs/globals_matrix*.csv`, `docs/chapters/` (the Phase 2 trade-off chapter
picks up "Launching the Kernel Again").

Suites on the folded build (overlay empty), BMG: unit 341/341, E2E 1376/1376 (incl.
`launch-state.unit.lisp`), negative 311/311; the 179 on-metal checks under `--differentiate` --
175/26, 176/08, 176/14, 178/10 (last-man relaunch) and the controls 175/31, 175/40, 178/11, 178/12 --
all PASS, analytical = numerical = 1.0.
