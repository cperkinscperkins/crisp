We've spent a lot of effort on the Crisp A|D functionality. But we have, and will likely continue to,
deferred the hoisting of the differentiated kernels. This is because the audience that is 
doing and using kernel differentiation today most likely already has a setup and don't necessarily
"need" example code.  Perhaps that is misguided, but regardless, hoisting of differentiated kernels
is not a critical need at this time.

BUT, the A|D functionality does need to be tested, and it should be tested "on metal".  In the past
we've just used an ersatz script for that ( sbcl --non-interactive --load scripts/verify_autodiff.lisp ).  Ironically, that script is failing. Awesome.

For this endeavor we want to bring some testing of the A|D system into the test running system.

My current proposal is:

- get that verify_autodiff.lisp script working again
- introduce a new test directive ( VERIFY-AUTODIFF ) and maybe some sort of "expectation" like
  we have for hoisting (e.g. ;; HOIST-EXPECT: BUFFER out: 0 1 2 3 )
- - perhaps the directive could put the expectation after the colon, rather than introduce a second directive
- realize that directive.  I think just using Common Lisp and OpenCL would suffice, since it's the 
  math that we are checking.  But if you think testing with L0 and/or C++ is important, we'll discuss.
- select SOME existing tests that we think should be tested on metal and add the directive/expectations to them.
- write some tests that we know we want to test various aspects of the A|D on metal.
- - where to put them?  Here in 103 is good, but in some cases maybe with a different endeavor if it has more gravity.


Claude Plans
============
Phase 1 — Generalize the runner. Take verify_autodiff.lisp from hardcoded-to-square into a reusable function: (verify-autodiff fwd-spv-path bwd-spv-path kernel-name &key inputs seed-grads atol). Returns (values pass-p analytical numerical diff). The script's existing logic stays, just parameterized. Output goes to return values, not just (format t ...), so the spec runner can capture and assert.

Phase 2 — Directive grammar (scalars only). Keep it minimal at first:


;; VERIFY-AUTODIFF: x=3.0 atol=1e-3
;; VERIFY-AUTODIFF: x=3.0 y=2.0 atol=1e-3
;; VERIFY-AUTODIFF: x=3.0 expected: x_grad=6.0 atol=1e-3
Default mode: finite-difference comparison (no expected needed). Optional expected: clause when you want both checks. Tolerance is mandatory. Mirrors how HOIST-EXPECT is parsed in overlays/spec-runner-overlay.lisp.

Phase 3 — Wire into run-specs. When a spec file has the directive, the runner compiles both fwd (--ir-target=spv) and bwd (--differentiate --ir-target=spv), then calls verify-autodiff. Report as an extra check on the same test, same format as the existing HOIST-EXPECT extra-check output. Gate behind OpenCL availability — if OpenCL.dll won't load, skip with a clear message (so non-GPU CI doesn't break).

Phase 4 — Tag scalar tests. Re-tag 044/01-square as the first user of the directive (proves the loop closes). Then 044/02 if there is one, and one record-at-boundary test from 049. Three tests is enough to validate the harness shape before scaling.

Phase 5 — Tensor support. This is where the math gets interesting. Two reasonable models:

Point-FD: perturb a single element of an input tensor, compare against the analytical gradient at that same element. One FD call per tagged element. Cheap.
Full Jacobian: FD across every element. Bounded but quadratic in tensor size. Probably overkill.
I'd start with point-FD with an explicit element index in the directive: ;; VERIFY-AUTODIFF: x[0]=3.0 perturb=x[2] atol=1e-3. Skip this phase until phase 4 lands and the scalar story is proven.

Phase 6 — Record / struct / sub-function cases. Pick representative tests from 049, 056, 052. The runner mostly doesn't care about the source shape — it sees flat SPV args. Mostly a matter of expressing the eval point correctly in the directive (per-field for records, struct constructor for structs).

Status (2026-05-14)
===================
- Phases 1-3 done.  Spec-runner integration runs under --differentiate.
- Phase 4 deferred (no obvious tagging candidates at the time).
- Phase 5a (multi-scalar-input) done.  044/02-product validates two-input case.
- Phase 5b (1D vector input + atomic-fadd backward) done.  103/01-vec-sq-lit validates.
- Cleanup: tagged-spec compile artifacts (.spv) are now deleted on completion.
- Documentation: harness described in docs/tests.md.
- Phase-4-light tagging round done: six 043/* tests tagged.  All pass on metal.
- Phase A (records-at-boundary, phase 6 partial): runner support landed
  (:scalar-float-plain kind, bind-float-scalar-arg, dot-in-name heuristic,
  apply-primals rebind).  But the on-metal pass on 049/03 surfaced a real
  Crisp AD compiler bug -- see findings below.
- Bug fix: silent-pass propagation in run-verify-autodiff-pass (unwind-protect
  cleanup form's return leaked through).  Fixed by capturing result into an
  explicit binding before unwind-protect.

Fixed Bug: record-at-boundary backward kernel adj routing
=========================================================
The backward kernel for `(def-kernel f (vp &out c) (declare #'(v-point ...)) ...)`
was routing accessor-call adjoints into the collective `vp_adj` rather than
the per-field SROA'd adjs (`vp_x_adj`, `vp_y_adj`).  The collective never
propagated to per-field, so the input-grad-write step wrote 0s.

Root cause: `%generate-backward-kernel-ast` (src/macros.lisp) never bound
`*record-param-field-adjs*` for record-at-boundary kernel inputs, even though
the equivalent sub-function path (`%generate-backward-function-ast` in
src/autodiff.lisp) does set it.  Without the binding, the record-aware
accessor rule in `%handle-single-value-backward` falls through to the generic
accessor rule (which routes to `vp_adj`).

A second, related issue: `generate-backward-walk` was unconditionally
re-binding `*record-param-field-adjs*` from its own flat-anf %construct-struct
scan, shadowing any outer binding.

Fix (2026-05-14):
  - Overlay: `%generate-backward-kernel-ast` builds a kernel-record-param-
    field-adjs-ht from `record-subs-ht` (filtering `:%nested-leaf%`
    sentinels) and dyn-binds `*record-param-field-adjs*` around the call to
    `generate-backward-walk`.
  - src/autodiff.lisp: `generate-backward-walk` now MERGES its construct-
    struct-derived entries with the outer binding instead of shadowing it.

Result: 049/03 now produces analytical = 4.0 / 3.0 (correct), matching the
finite-difference numerical gradient within 3e-4.  All 6 specs in 049 pass
under --differentiate.  Default suite still 649/649 green.

049 cluster is now a rich source of on-metal coverage; phase 4 record-tagging
follow-on can proceed.

A few open questions before I'd start writing:

Where does the runner live? I'd say tests/runners/verify-autodiff.lisp (a sibling of the existing spec-runner machinery) rather than scripts/, since it's now part of the test apparatus. scripts/verify_autodiff.lisp becomes a thin wrapper that calls into it for ad-hoc runs.
Opt-in flag? Running OpenCL kernels is slower than the existing IR/metadata checks. Worth a --verify-autodiff flag on run-specs.lisp so the directive is parsed but execution is gated, like --metadata already gates extra-metadata checks. Default off, on in a dedicated CI job.
OpenCL extension request. Tensor backward kernels emit atomicrmw fadd. clBuildProgram will need the -cl-std= and possibly the extension enabled in the build options. We'll discover this when phase 5 hits a tensor test, but worth pre-registering as a known gotcha.

