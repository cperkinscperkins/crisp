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

Remaining:
- Phase A2: integer sub-function differentiability (ulong/long-param def-functions
  get no backward companion). Then un-SKIP 120/03-subfunction. (Shares root with
  the FFI Pass-1 %count-differentiable-contributions int-inert finding.)
- Phase B: folded boolean literal (120/02). "Cannot resolve type to LLVM: BOOLEAN".
- Phase C: mixed precision (123/04). See [[endeavor-123-ffi-ad]] / earlier notes.