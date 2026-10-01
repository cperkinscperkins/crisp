;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-01 -- endeavour 176 Phases 1-3 folded into src/ (grid-reduce!, the independent and
;;;; dependent multi-variable reductions, BUG 096/097, the :fast type-infinity warning).  The spec-runner
;;;; overlay (VERIFY-AUTODIFF symbolic scratch sizes) was folded into tests/run-specs.lisp in the same pass.
;;;;
;;;; Two things did NOT move, deliberately:
;;;;   * the MACRO-FUNCTION copy that put grid-reduce! on a separate :crisp-language symbol -- src/package.lisp
;;;;     now exports GRID-REDUCE! from :crisp.compiler and imports it into :crisp-language, so there is one
;;;;     symbol and one defmacro (as for WHEN-THREAD-IN-*).
;;;;   * %REFUSE-DEPENDENT-FORM -- Phase 2's placeholder refusal of the dependent shape; Phase 3 replaced
;;;;     every caller.

(in-package :crisp.compiler)
