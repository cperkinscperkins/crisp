We've had a couple of A|D issues occur lately with some of them being deferred.

In this endeavor, we are going to try to address them.  We will likely need new TDD tests for this, plus a few of the tests that are currently marked SKIP-WITH[--differentiate] should be able to be enabled.  

- [~] if+/when+/dotimes+ aren't recognized in AD backward walk
- [ ] folded boolean literal materialized as a backward let-binding; boolean has no LLVM type.
- [ ] 120-uniform/02-defmacro-usage  and 03-subfunction
- [ ] 123-ffi-ad/04-ffi-long-return.crisp    Mixed precision issue.


=====================================================================
INVESTIGATION + PLAN (2026-06-28). The four items above are THREE root causes
(item 3 = the test manifestations of items 1+2):

  A  value-producing if/if+/let not differentiated (the real shape of item 1)
  B  folded boolean literal in the backward (item 2)        — blocks 120/02
  C  mixed precision: float input + double-promoted output  — blocks 123/04

Plus a separate blocker for 120/03 ("integer sub-function differentiability":
ulong-param def-functions get NO backward companion — see Phase A2).
=====================================================================

Phase A1 — value-if / value-let backward — DONE 2026-06-28. Suite 779/779
forward & --differentiate; negatives 183/183.

Root cause (deeper than item 1's label): the backward walk only handled
STATEMENT if (branches contain set!, via %gfw-process-if). A VALUE-producing
if/if+ — `(set! place (if cond a b))`, a let-bound if, or a function returning
`(if+ ...)` — is ANF'd to a binding `(%t (if[+] cond then else))`. That hit
%handle-single-value-backward's IF clause which returned NIL → the seed reached
the if-RESULT's adjoint but never flowed through the branches:
  - plain value-if  → SILENT zero gradient (verified: x_adj never updated)
  - if+/when+ value → hard error "Function IF+ is not differentiable"
Branches with sub-exprs are ANF-wrapped in a LET (e.g. (* (~ x) 2.0) ->
(let ((t (~ x))) (* t 2.0))), so value-if requires value-LET handling too.

Fix (src/autodiff.lisp, edited directly):
  - %handle-single-value-backward dispatches value-if/if+/when[+]/unless[+] and
    value-let to new handlers.
  - %backward-value-expr: recursive value-expr backward (symbol-copy, literal,
    if, let, else delegate to the leaf handler).
  - %handle-value-if-backward: seed flows into whichever branch (emits a plain
    `if`; if+'s uniformity is irrelevant to the backward), each arm carrying its
    value's chain rule into V_adj.
  - %handle-value-let-backward: recompute binds (forward) + BRANCH-LOCAL adjoints
    for bind temps (scoped to the emitted let, not the global adjoint-map) +
    push V_adj through body then each bind. (Local adj zero-init is 0.0 float;
    double-chain interaction deferred to Phase C.)
  Gotcha fixed: (symbol-package v) can be NIL (gensym temps) -> intern crash;
  use (or (symbol-package v) (find-package :crisp.compiler)).

Tests (124-ad-issues/, VERIFY-AUTODIFF on the BMG):
  01-value-if-then (then-branch grad 2.0), 02-value-if-else (else grad 1.0),
  03-value-ifplus (if+ with a let-wrapped branch, grad 2.0). All numeric on metal.

Phase A2 — integer sub-function differentiability — INVESTIGATED, NOT SHIPPED
(2026-06-28). Reverted; suite back to 779/779.

Root of 120/03 blockage: the multi-pass pre-registration gate
(analysis/core.lisp ~L2072) registers a def-function as differentiable only when
%count-differentiable-contributions > 0 OR it has a tensor/cell param. ulong/long
params count 0 -> B/C registered as NEITHER differentiable NOR inert -> the kernel
errors "B is not differentiable".

Tried the minimal fix: make %count-differentiable-contributions count integer
scalars as 1 (via %crisp-integer-scalar-type-p). RESULT — two problems, so reverted:
  1. BLAST RADIUS: regressed 4 tests whose sub-functions take int INDEX/SIZE params
     (060-array/11, 060-array/17, 111/14, 113/04). Treating every int param as an
     active differentiable value changes the sub-fn _GRAD ABI (extra returned
     deltas) and breaks index-param call sites. Need an active-vs-index distinction
     (data-flow "activeness"), not a blanket count.
  2. INSUFFICIENT for 120/03 anyway — it is blocked by a STACK:
       (a) integer sub-fn registration (this gate),
       (b) MIXED PRECISION (Phase C): C returns ulong -> seed double, but sub-fn
           adjoint inits/returns are hardcoded float -> C's _GRAD fails
           "Expected FLOAT but inferred DOUBLE" -> C unregistered -> B fails,
       (c) INTERPROCEDURAL UNIFORMITY: C's if+ needs `x` uniform; B doesn't
           propagate it (even an int variant fails: "Function C requires parameter
           X to be :uniform, but inferred state was UNKNOWN"). The test author left
           `(declare (uniform x))` commented with "I would prefer WITHOUT".

CONCLUSION: 120/03-subfunction is a deeply-entangled aspirational test (3 subsystems).
A2-as-blanket is the wrong shape. Recommend deferring full integer-sub-fn diff as its
own endeavor (needs activeness analysis + Phase C + interprocedural uniformity), and
proceeding with the more self-contained B and C.

Phase B — folded boolean literal — DONE 2026-06-28. Suite 780/780 both passes;
negatives 183/183.

Root cause: `provably-uniform?` / `provably-divergent?` (analysis/control.lisp)
returned a semantic-literal with :value-type 'boolean and value t/NIL. But Crisp
has NO boolean type — it represents booleans as int (comparisons fold to int 1/0;
the if-DCE at control.lisp ~L470 treats 0/NIL as false). The 'boolean literal
works only while FOLDED (forward analysis folds the if). In a backward kernel, the
forward-recompute keeps the flat-anf binding (%t (provably-divergent? a)) and tries
to alloca %t : boolean -> resolve-type-to-llvm has no BOOLEAN -> "Cannot resolve
type to LLVM: BOOLEAN".

Fix (analysis/control.lisp): both predicates now return :value-type 'int with
value 1/0 (Crisp's int-for-bool), matching comparisons and try-constant-fold. The
if-DCE already treats 0/NIL as false, so fold behaviour is unchanged; the value is
now materializable. (uniformity-state still returns a 'keyword literal — same latent
issue if ever materialized, but no test hits it; left as-is.)

Tests: un-SKIP'd 120/02-defmacro-usage (compile test; provably-divergent?), added
124/04-uniform-pred-fold (provably-uniform? companion). Updated the 120
uniformity-logic.unit.lisp intrinsic assertions to the int 1/0 representation
(type check made package-robust via symbol-name string-equal, since `int` is not
cl:int the way `boolean` was cl:boolean).

Phase C — mixed precision (double / long outputs) — DONE 2026-06-29 (kernel walk).
Suite 782/782 both passes; negatives 183/183.

Root cause: double/long-output AD was broadly broken (no existing differentiable
double spec; even an all-double (* x x) failed "Expected FLOAT but inferred DOUBLE").
Two bugs in generate-backward-walk's adjoint typing:
  1. promotes-to-double-p called %promote-to-float-adjoint, which leaves a
     NON-integer type ALIAS unresolved (a (cell double) alias came back as the bare
     alias symbol) -> any-output-double was NIL -> every adjoint init'd to float 0.0
     while the chain ran in double. Fix: canonicalize before checking for a double
     element.
  2. Even with any-output-double, a FLOAT input's adjoint stayed float (typed-zero-for
     only promoted inputs that promote-to-double themselves), clashing with the double
     intermediates at the (set! x_adj (+ x_adj intermediate)) boundary. Fix: under
     any-output-double the WHOLE chain runs in double — float/int inputs get double
     adjoints too — and the narrower float grad cell is reconciled by a `to-float`
     down-cast at the grad-cell write (cell/scalar inputs only). Crisp `+` widens a
     float operand into a double accumulator, so the FFI VJP's float delta flows in
     correctly.

IR verified (mixed float-in/double-out, y=x^2): float primals fpext'd into the
double chain, accumulation in double, `fptrunc double ... to float` at the x_grad
store. dy/dx = 2x.

Tests: un-SKIP'd 123/04-ffi-long-return (now compiles under --differentiate); added
124/05-double-output (all-double) and 124/06-mixed-precision (compile-shape + manual
IR — VERIFY-AUTODIFF supports only cell float, so double outputs can't be numerically
checked on metal).

Remaining:
- Phase A2 (deferred): integer sub-function differentiability for 120/03 — large,
  3-subsystem effort: (a) active-vs-index analysis (to avoid the 4-test regression),
  (b) SUB-FUNCTION-walk double typing (the %generate-backward-function-walk
  adjoint-bindings still hardcode 0.0 — the analogue of Phase C's fix, needed for
  ulong/long sub-fn companions), (c) interprocedural uniformity (if+ in C needs
  uniform x propagated from B).