In endeavor 175 we implemented reductions in Crisp. Followed by support for multi-variable reductions and their auto-differentiation.

Crisp doesn't have a one-size-fits-all approach to reductions but instead has some "first stage" and "second stage" forms that can be composed by the user.

.\tests\spec\175-reductions\reductions-excerpt.md    has an update excerpt of their documentation.

In this endeavor we'll be implementing reduce-vec.  Tis builds on the reductions we've already implemented.  I've excerpted its API below.

The existing reduction routines support `&key` args for scratch memory that have default values.   `reduce-vec` might  be able to just benefit from those, but we might want to pass them through so that it has those same `&key` args.  Let's discuss this, as it might also be strategy dependent.


Plan
=====

- [x] discuss any API changes. Make them (here and in ideal_001.md)
- [x] write TDD tests, including tests for autodifferentiation
- [x] implement -- FOLDED into src/ 2026-10-03 (overlay empty; see "Fold-back" below)
- [x] test on-metal, as required -- BMG done (forward + VERIFY-AUTODIFF)
- [x] test on NVIDIA (A100, 2026-10-03): 08 forward BUFFER out: 6; 175-177 [CUDA] AD specs all PASS [cuda]
- [x] 13-diff-reduce-vec-sum-cuda: A100 re-run PASS [cuda] analytical=1.0 numerical=1.0.  First run CRASHED the --differentiate phase (BUG 106: CUDA VAD has no :global
      scratch, and the refusal's CRLF ~-continuation broke FORMAT).  Message fixed; spec moved to :atomic
- [x] fold the overlay into src/, regenerate reference/call graph/chapters/globals -- suites on the folded build:
      unit 341/341, negative 311/311, E2E 1376/1376, --differentiate 1376/1376


API decisions (agreed 2026-10-03)
=================================

    (reduce-vec someFunction vec identity out-cell
                &key strategy message
                     local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)

- `&out` dropped from the signature: out-cell is positional, as in grid-reduce!.
- The &key set is EXACTLY grid-reduce!'s, passed straight through.  Not strategy-dependent from
  reduce-vec's side: a key the strategy does not use is refused (the check names reduce-vec).
- Default strategy :last-man-standing (as grid-reduce!).  :strategy must be a literal keyword.
- VECTORS ONLY (rank 1).  No matrices/tensors -- a compilation error, not a silent flatten.
- The identity must have the vector's element type (a compilation error otherwise).  No widening
  (e.g. half -> float); that would make fn #'(T E => T), a different contract.
- No multi-variable form -- refused, pointing at grid-reduce! with clauses.
- AD: #'+ under every strategy, exactly as grid-reduce!.  min/max/custom refused under --differentiate.


What it is
==========

A macro (src/analysis/ops.lisp beside grid-reduce!) expanding to

    (let ((A-INTO-OUT identity))                         ; deterministic name -- see below
      (%check-reduce-vec-element :reduce-vec A A-INTO-OUT) ; rank-1 + element-type check, emits nothing
      (loop-vector-stride A (A-INTO-OUT-I)
        (set! A-INTO-OUT (fn A-INTO-OUT (~ A A-INTO-OUT-I))))
      (grid-reduce! fn A-INTO-OUT identity out ...keys...))

The partial's name is DETERMINISTIC (vector + result cell), never a gensym: grid-reduce!'s implicit
scratch is named after the variable it reduces, and Pass 1 and Pass 2 must agree on that name.  Using
the result cell too keeps two calls over one vector from sharing a counter (spec 06 checks the host code
has a-into-total_* and a-into-biggest_* buffers).


What it took (it was NOT just sugar)
====================================

The forward was sugar, as expected.  Autodiff was not:

1. The AD pre-pass that rewrites stride macros (%expand-stride-macros-in-form) never looked inside the
   reduce-vec macro, so ANF later met a raw loop-vector-stride: "Function SET! is not differentiable".
   It now expands REDUCE-VEC and walks the result.

2. BUG 103 (plan/bugs.md): a scalar set! INSIDE A LOOP had no backward at all -- a SILENT ZERO.  Measured
   on BMG for dotimes, loop-vector-stride and the hand-written reduce-vec expansion; pre-existing, never
   caught because no VERIFY-AUTODIFF spec had a loop-carried scalar.  Fixed: x_adj += V_adj, V_adj := 0.

3. BUG 105: that rule is exact only for LINEAR folds -- the backward replays loops forward with a stale
   loop-carried primal.  A nonlinear loop-carried variable (running product) is now REFUSED loudly
   (178/errors/09) instead of giving a different wrong number.  Reductions are unaffected: grid-reduce!'s
   VJPs differentiate + only.

4. BUG 104: a string reaching ANF (reduce-vec/grid-reduce! :message inside a LET) died under --differentiate.

Test infrastructure: VERIFY-AUTODIFF gained a 1-D generator, `A=N@START:STEP` (tests/verify-autodiff-parse.lisp,
documented in docs/tests.md), so the AD specs use 300-element vectors over 128 threads.  The L0 hoist harness
gives an input vector only 4 elements (0 1 2 3), so the FORWARD metal specs prove striding with a 2-thread
grid (spec 02: 0+2 and 1+3) rather than a long vector.


Measured on BMG (2026-10-03)
============================

    01 default (last-man)        BUFFER out: 6       02 stride (2 threads, 2 each)  6
    03 :atomic + :message        6                   04 :cas #'max                  3
    05 custom uint binop         3                   06 two calls, one kernel       6 / 3
    07 explicit scratch keys     6
    10 AD sum (default)          at.A=257 (thread 1, 3rd iteration)   analytical=1.0 numerical=1.0
    11 AD :atomic                at.A=200                              1.0 / 1.0
    12 AD :cas                   at.A=299 (last element)               1.0 / 1.0
    14 AD loop-carried sum       1.0 / 1.0       15 AD loop-carried difference   -1.0 / -0.9999995


Fold-back (overlays/crisp-compiler-overlay.lisp -> src/) -- DONE 2026-10-03
=======================================================

Only the LAST copy of each function is live (the overlay appends corrections):

- src/analysis/ops.lisp:  %reduce-vec-partial-name, %reduce-vec-expand (2nd copy), defmacro reduce-vec,
  %analyze-check-reduce-vec-element (2nd copy); add ("%CHECK-REDUCE-VEC-ELEMENT" %analyze-check-reduce-vec-element)
  to register-ops-analyzers' pair list and DROP the overlay wrapper; DROP the macro-function copy block and add
  #:reduce-vec to the TWO package.lisp sites #:grid-reduce! uses (:crisp.compiler export, :crisp-language import).
- src/macros.lisp:        %expand-stride-macros-in-form (the REDUCE-VEC clause).
- src/autodiff.lisp:      %ad-literal-symbol-p (2nd copy), %gfw-process-set!, %ad-loop-carried-tainted,
  %ad-stale-primal-reads, %ad-check-loop-carried-primals (2nd copy), %gfw-process-dotimes.
- src/anf-transform.lisp: anf-is-atomic?.




DOCS
====

## **The Vector API**

### `reduce-vec` ✅ (see docs/ideal_001.md for the current text)

Because reducing a 1D vector or tensor is so common, Crisp provides a high-level wrapper that automatically handles the grid-stride loops and applies the combinations for you:

`(reduce-vec someFunction vec identity &out out-cell &key strategy)`

Instead of manually writing the strided loops and managing the scratchpads, you simply tell `reduce-vec` which Macro Strategy to employ:


The `strategy` is one of `:atomic`, `:cas` or `:last-man-standing`, exactly as for `grid-reduce!`.
The "second stage" isn't available because it requires a second kernel enqueue.


```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0 result-cell :strategy :last-man-standing )

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*

