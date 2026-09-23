;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-09-22 — endeavour 175 folded into src/.
;;;;
;;;; Four things did NOT move, and that is deliberate:
;;;;   * the REDUCE-WARP and REDUCE-WORKGROUP defmacros, and the two eval-whens that
;;;;     FMAKUNBOUND them.  Both constructs became analyzed forms so the VJP registry could
;;;;     see them (BUG 081); the macros existed only because an overlay cannot un-write its
;;;;     own earlier definition.  Folding them in would have resurrected dead code AND made
;;;;     anf-transform expand the form again before the backward walk.
;;;;   * the three eval-whens that copied MACRO-FUNCTION between packages.  src/package.lisp
;;;;     exports the two WHEN-THREAD-IN-* macros from :crisp.compiler and imports them into
;;;;     :crisp-language, so there is one symbol rather than two.
;;;;   * %WARP-SPEC-CHECK-SYNC, whose live copy was a pure pass-through (the BUG 082 revert),
;;;;     so folding it meant changing nothing.
;;;;   * the eleven chained REGISTER-OPS-ANALYZERS wrappers, collapsed into one block of 13
;;;;     registrations at the end of the real function in src/analysis/ops.lisp.

(in-package :crisp.compiler)
