# Endeavour 177: reduction-ad

Reductions generally, and multi-variable reductions specifically, have been keeping abreast of the
matching autodifferentiation support as they've moved along.

The one exception was for the dependent multi-variable variant, which uses a first order reduction
function that takes 2N args and returns N values.  Today a dependent reduction under `--differentiate` is
refused loudly (BUG 098).  This endeavour makes it differentiable.


## The decision (2026-10-01): a LOCAL VJP for the whole reduction

The user supplies one function per combiner: given **this thread's own input state**, the **final result
state**, and the **result's adjoint**, return **this thread's input adjoint**.

    own state       (x1 .. xk)       -- what this thread contributed, before the reduction
    result state    (r1 .. rk)       -- the reduced state
    result adjoint  (r1-bar .. rk-bar)
                 =>  (x1-bar .. xk-bar)

For argmax:

```lisp
(def-function argmax-combine (val-a idx-a val-b idx-b)
  (declare #'(float ulong float ulong => float ulong)
           (reduction-vjp argmax-local-vjp))          ; <-- the one new declaration
  (if (or (> val-a val-b)
          (and (= val-a val-b) (< idx-a idx-b)))
      (return val-a idx-a)
      (return val-b idx-b)))

(def-function argmax-local-vjp (v i rv ri rv-bar ri-bar)
  (declare #'(float ulong float ulong float ulong => float ulong))
  ;; the winning thread gets the gradient of the value; indices get none
  (if (= i ri)
      (return rv-bar 0ul)
      (return 0.0 0ul)))
```

### Why this shape (the options considered)

1. **A VJP for the combiner** -- `(A, B, C-bar) -> (A-bar, B-bar)` per combine step.  Textbook, but it does
   not remove the hard part: the backward pass would still have to replay the whole reduction tree (warp
   butterfly, workgroup halving, last-man's cross-workgroup step), keep or recompute every intermediate
   state, and walk the tree in reverse.  And Crisp can probably differentiate the combiner itself (it is
   an ordinary def-function), so the user VJP would buy little.
2. **A local VJP for the whole reduction** -- CHOSEN.  The backward pass needs no tree:
   * **reduce-warp / reduce-workgroup** are all-reduces: every thread ends up holding the same result, so
     the result's adjoint is the SUM of the per-thread output adjoints -- the existing `+` reduction, which
     already has a VJP.  Then each thread applies the local rule.
   * **grid-reduce!** writes the result to its return cell; the result's adjoint is that cell's adjoint,
     and the result itself is read back from the cell.  Then each thread applies the local rule.
   * Nothing new to replay: the result is the forward's own output.
   This is the same move 175 made for `+` -- a semantic rule, not a mechanical walk through the reduction.
3. **Built-in rules for selection combiners** (argmax / argmin: "the winner gets the gradient") -- not
   needed for a first cut; a possible later sugar on top of 2.

### The limitation (to document)

A thread's adjoint must be computable from ITS OWN input and the RESULT.  That holds for the reductions
people actually write: selections (argmax, argmin, max, min -- "am I the winner?"), sums, counts and
means, Welford-style variance (the mean and count are in the result), log-sum-exp (`exp(x - R)`), and
products (`R / x`, except where `x = 0`).  It fails only when the gradient needs information the result
threw away (a second-largest value, say) -- rare for associative reductions, and the user then shapes
the state to keep it.


## Design

### The declaration

`(declare (reduction-vjp NAME))` on the **combiner**: declared once, used by every reduction that names
that combiner, in any of the three constructs.  It mirrors endeavour 123's FFI VJPs (the backward function
named next to the forward one), but as a declaration, because the combiner is an ordinary def-function.

### The VJP's signature

With the combiner `#'(T1 .. Tk T1 .. Tk => T1 .. Tk)`, the local VJP is

    #'(T1 .. Tk   T1 .. Tk   A1 .. Ak  =>  A1 .. Ak)
       own state  result     result     own-state
                             adjoint    adjoint

where `Ai` is the adjoint type of `Ti` (`float` for `float`; for integer components, whatever Crisp's AD
uses for integer adjoints -- see Phase 0).  Checked against the combiner at the call site, like the
combiner's own signature check (Phase 3 of 176).

### Backward lowering, per construct

The forward lowering is unchanged (fused).  On the AD path:

* **The own state must survive the reduction.**  The reduction overwrites each variable with the result,
  so the AD path takes a SNAPSHOT of the clause variables just before it -- `(let ((x1-0 x1) ...) <the
  reduction>)` -- and the local VJP reads the snapshot.  (Phase 0 confirms the backward pass sees primal
  values this way.)
* **reduce-warp** (dependent, all-reduce): result adjoint = an independent `(reduce-warp ((#'+ x1-bar 0) ...))`
  of the per-lane adjoints of the clause variables; then each lane calls the local VJP on (snapshot,
  result, result adjoint), and the returned adjoints REPLACE the clause variables' adjoints (the reduction
  consumes and produces each variable in place -- the same rule 175's VJPs follow).
  * **active-threads**: lanes past the count contributed the identity, not their own value; their
    variables' original values must get ZERO adjoint.  (Falls out if the AD path keeps the forward's
    `(if (< lane n) v identity)` substitution as ordinary code -- to confirm.)
* **reduce-workgroup**: as reduce-warp, with the adjoint sum an independent `reduce-workgroup` of `+`.
  `:return-vec` -- 175's single-variable VJP refuses it today ("a second output"); keep that refusal for
  the dependent form unless it turns out to be free.
* **grid-reduce!** (dependent, last-man): result = the return cells (read back), result adjoint = the
  return cells' adjoints; each thread calls the local VJP on (snapshot, result, result adjoint).  No sum:
  there is exactly one copy of the result.

### Refusals that remain (loud)

* A dependent reduction whose combiner declares no `reduction-vjp`: BUG 098's refusal, its message now
  naming the declaration that would fix it.
* A `reduction-vjp` whose signature does not match the combiner and the clauses.
* A combiner given as a function VALUE rather than a literal `#'f` (no declaration to find).


## Phase 0: probes (no implementation) -- DONE 2026-10-01

Probes and the AST dumper live in `put_temp_files_here/177/` (`dump-grad.lisp` prints the `_GRAD` kernel
the AD path builds).  Every claim below about a gradient was MEASURED on the BMG with VERIFY-AUTODIFF.

- [x] **Primal values across an in-place reduction.**  The backward's primal replay is a LET of the
      forward's BINDINGS only; it never runs the reduction.  So in the backward, a reduced variable holds
      its PRE-reduction value everywhere -- which is what the local VJP's "own state" wants, but the
      RESULT state is simply not there, and every later nonlinear use of the variable is differentiated
      against the wrong primal.  That last part is a shipped 175 bug, not a 177 gap: **BUG 100(b)**,
      56.0 against 896.0.  The same probes found two more silent wrong gradients underneath the snapshot
      idea: a copy binding `(let ((v0 v)) ..)` drops v0's adjoint (**BUG 099**, 1.2 vs 2.4), and a scalar
      `set!` is invisible to AD altogether (**BUG 100(a)**, 2.4 vs 8.11).  The snapshot as drafted read
      28.0 against 56.0.
- [x] **Integer adjoint type.**  A LOCAL's adjoint is `float` whatever its type (`(I_ADJ 0.0)` for a ulong
      local); only an integer KERNEL PARAMETER gets the 085 promotion (`(IA_ADJ (AS DOUBLE 0.0))`).
- [x] **The declaration.**  An unknown `(declare (reduction-vjp f))` on a def-function is accepted
      SILENTLY today -- nothing validates def-function declarations.  The def-function macro holds the
      declaration list at expansion time (`src/macros.lisp`, beside the forward-only check), before any
      kernel that uses the combiner is expanded, so a small name -> vjp registry populated there (cleared
      by `initialize-compiler`) is enough for the AD path to find it.
- [x] **active-threads.**  175's reduce-warp VJP gives a PADDING lane the full gradient (16.0 against
      0.0; the active lane passes) -- **BUG 101**.  Padding lanes hold the result, so their output
      adjoints rightly enter the sum, but their INPUT adjoint must be zero.  177's lowering must gate the
      VJP's results by `(< lane n)`, and 175's single-variable VJPs need the same gate.

### What Phase 0 changes in the design

The backward lowering above assumed the backward could see both the pre-reduction values (snapshot) and the
result.  It sees only the first.  Two ways to get the result:

* **(A) Fix BUG 100 generally**: version in-place scalar writes on the AD path so the replay runs them in
  order -- the reduction is replayed in the backward (one extra collective), the result is just the next
  version of the variable, and BUG 100(a)/(b) close with it.  177 then needs no snapshot at all.
* **(B) 177-local**: the dependent VJP lowering re-runs the (fused) dependent reduction itself, on copies of
  the pre-reduction values, to get the result.  Narrow; leaves 099/100 open.

Either way the integer adjoint is `float`, and the gate for padding lanes is required.

**Decided (Chris, 2026-10-02): fix 099 and 101 first, then (A) as 177's Phase 1.**

## Phase 0.5: BUG 099 and BUG 101 (TDD; fixes in the overlay)

- [x] TDD, red on BMG first: 124/15 copy binding (3.0 vs 6.0), 124/16 copy chain (0.0 vs 6.0), 175/63 padding
      lane (16.0 vs 0.0), 175/64 active lane (16.0 -- the guard against a gate that zeroes everything),
      176/19 padding lane through the independent split (48.0 vs 0.0)
- [x] 099: a copy-binding clause at the head of `%handle-single-value-backward`, scoped to scalar dataflow
- [x] 101: `%175-vjp-reduce-warp` zeroes the input adjoint of lanes at or past active-threads
- [x] all five green on BMG
- [x] unit 341/341, E2E 1329/1329, negative 296/296; `--differentiate` 124 16/16, 175 79/79


## Phase 1: reduce-warp

- [ ] TDD: argmax with a reduction-vjp, VERIFY-AUTODIFF -- the winner's value gets 1, a non-winner 0, the
      index nothing
- [ ] TDD: active-threads (padding lanes contribute nothing)
- [ ] implementation


## Phase 2: reduce-workgroup

- [ ] TDD: argmax across warps, VERIFY-AUTODIFF
- [ ] TDD: a NON-selection combiner -- (count, sum) for a mean, or Welford -- to prove the rule is not
      argmax-specific (d mean / dx = 1/n)
- [ ] implementation


## Phase 3: grid-reduce!

- [ ] TDD: argmax across workgroups (last-man), VERIFY-AUTODIFF
- [ ] implementation


## Negative tests

- [ ] dependent reduction, no reduction-vjp, under --differentiate (the BUG 098 message, now naming the fix)
- [ ] reduction-vjp signature mismatch
- [ ] combiner passed as a value, not a literal #'f


## Phase 4: wrap-up

- [ ] `[CUDA]`-pinned VERIFY-AUTODIFF twins, for the CUDA pod run that follows this endeavour
- [ ] docs: the dependent section of the reductions doc (the AD paragraph), the reduction-vjp declaration,
      the limitation
- [ ] retire 176/errors/11 (it pins the refusal this endeavour lifts) and the BUG 098 SKIP-WITHs on
      176/15-18 -- or keep them as the "no reduction-vjp declared" cases
- [ ] BUG 098 closed; fold; definition of done
