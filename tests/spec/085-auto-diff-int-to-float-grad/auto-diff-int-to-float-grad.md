- [ ] AutoDiff fix: Redesign so gradient storage handles are always  floating point regardless of primal type, and generate zero backward kernels for integer inputs. This is the "mathematically correct" approach but requires more work.
- - [ ] Would allow re-enable of tests in 083 and other places that skip --differentiate pass for this reason


Claude Opines
=============
What currently exists:

%compute-backward-kernel-params (in src/macros.lisp) uses a differentiable-non-rec-p predicate that only passes float scalars, float tensors, and cells — integer tensors are excluded from both diff-flat-inputs AND _GRAD outputs
Line 630-632 then fires an error when diff-flat-inputs is empty
081-tensor-sub-function-ad/errors/01-non-float-tensor.crisp is an existing error test that asserts that error message — so it needs updating too
What the fix looks like:

Two separate things need to change:

"Gets a _GRAD output" predicate — expand to include integer tensors (but NOT integer scalars like loop indices). An integer tensor v: (tensor int 1 ...) would produce v_GRAD: (tensor float 1 ...). Need a helper that maps element types: int/uint/short/uchar → float, long/ulong → double.

Error condition — relax from "any empty diff-flat-inputs" to "no tensor inputs at all." All-integer-tensor kernels would generate a backward kernel where v_GRAD is float-typed but the body never writes to it (stays zero, which IS the correct gradient). The existing error test becomes a PASS.

The lift:

Core change is in src/macros.lisp — a defmacro file, so it requires a direct patch, not an overlay
%elem-type-to-float helper: ~20 lines
%compute-backward-kernel-params changes: ~30 lines
9 × SKIP-WITH removal in 083
081/errors/01-non-float-tensor.crisp needs redesigning — probably becomes a positive test verifying the float-typed grad output
2-3 new tests for the integer-gradient behavior itself
Unknown risks:

Does the backward kernel AST compile cleanly when diff-flat-inputs is empty but there are &out grad tensors?
Does the metadata path handle float grad tensors for int inputs without surprises?
These are verifiable cheaply once the core change is in — just build and run the suite.