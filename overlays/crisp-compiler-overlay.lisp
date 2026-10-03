;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-03 -- endeavour 178 (reduce-vec) folded into src/:
;;;;   * reduce-vec                          -> %reduce-vec-partial-name, %reduce-vec-expand, defmacro reduce-vec,
;;;;                                            %analyze-check-reduce-vec-element (src/analysis/ops.lisp), registered
;;;;                                            in register-ops-analyzers' pair list; #:reduce-vec exported from
;;;;                                            :crisp.compiler and imported by :crisp-language (src/package.lisp),
;;;;                                            replacing the overlay's MACRO-FUNCTION copy and wrapper
;;;;   * AD pre-pass expands REDUCE-VEC      -> %expand-stride-macros-in-form (src/macros.lisp)
;;;;   * BUG 103/105 loop-carried set!       -> %ad-literal-symbol-p, %ad-loop-carried-tainted, %ad-stale-primal-reads,
;;;;                                            %ad-check-loop-carried-primals, %gfw-process-set!, %gfw-process-dotimes
;;;;                                            (src/autodiff.lisp)
;;;;   * BUG 104 strings are ANF-atomic      -> anf-is-atomic? (src/anf-transform.lisp)

(in-package :crisp.compiler)
