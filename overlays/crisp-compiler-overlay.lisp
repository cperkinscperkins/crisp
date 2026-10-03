;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-02 -- endeavour 177 (reduction-ad) folded into src/:
;;;;   * BUG 099 copy-binding clause      -> %handle-single-value-backward (src/autodiff.lisp)
;;;;   * BUG 101 active-threads gate      -> %175-vjp-reduce-warp (src/autodiff.lisp)
;;;;   * BUG 100 versioned in-place writes -> %ad-version-in-place-writes, %ad-assemble-primal-replay and
;;;;     the two edits in %generate-backward-kernel-ast (src/macros.lisp)
;;;;   * 177 dependent-reduction AD        -> *reduction-vjps*, %check-reduction-vjp etc. (src/analysis/ops.lisp),
;;;;     %177-vjp-dependent-reduction (src/autodiff.lisp)
;;;; The three overlay WRAPPERS were inlined rather than moved: register-function-signature
;;;; (src/environment.lisp), anf-normalize (src/anf-transform.lisp), %check-dependent-combiner
;;;; (src/analysis/ops.lisp).  The VJP re-registrations were dropped -- src's own registration covers them.
;;;; *176-generic-scratch-range* moved from the tail of the GENERATED src/specials.lisp to
;;;; src/analysis/core.lisp, where regeneration cannot delete it.

(in-package :crisp.compiler)
