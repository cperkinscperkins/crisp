;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-09-30 -- endeavour 176 folded into src/: BUGs 090-095, implicit scratch for the
;;;; reductions, scratch defaults and body scratch in generic functions, type-min / type-max /
;;;; type-infinity.  The L0 hoister overlay (overlays/hoist-l0) was folded in the same pass.
;;;;
;;;; Two things did NOT move, deliberately:
;;;;   * %IF-EXPLICIT-NIL-ELSE-IS-FALSE-P -- the first BUG 092 draft, superseded by
;;;;     %if-missing-else-is-false-p and called by nothing.
;;;;   * *GRID-ATOMIC-OPERATOR-MAP* -- carried into the overlay by accident with a script-extracted copy
;;;;     of register-ops-analyzers; src/analysis/ops.lisp already defines it, unchanged.

(in-package :crisp.compiler)
