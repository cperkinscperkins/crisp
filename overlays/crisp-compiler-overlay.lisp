;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-07 -- endeavour 180 (loop unrolling) and BUG 107 folded into src/:
;;;;   * unroll declarations       -> %declaration-spec-named-p, %parse-unroll-spec,
;;;;                                  %split-loop-body-declarations, %loop-trip-count-constant-p,
;;;;                                  %stream-element-bytes, %resolve-unroll-spec, %analyze-loop-with-unroll;
;;;;                                  analyze-dotimes-expression / analyze-loop-variant-expression are now the
;;;;                                  wrappers, the pre-180 analyzers renamed %analyze-dotimes-core /
;;;;                                  %analyze-loop-variant-core (src/analysis/control.lisp)
;;;;   * misplaced unroll          -> %check-context-declarations, %refuse-misplaced-unroll,
;;;;                                  analyze-declare-expression, registered in register-control-analyzers
;;;;   * stream default            -> %expand-loop-vector-stride-form (control.lisp), %reduce-vec-expand (ops.lisp)
;;;;   * !llvm.loop emission       -> *stream-unroll-bytes-in-flight*, *stream-unroll-max-factor*,
;;;;                                  %effective-loop-unroll, %attach-loop-unroll-metadata, and both counted-loop
;;;;                                  generate-node-ir methods (src/codegen.lisp)
;;;;   * spec validators           -> %spv-scalar-load-count, %validate-spv-stream-loads, validate-spv-stream-*,
;;;;                                  validate-ptx-has-nounroll-pragma (src/mma.lisp)
;;;;   * BUG 107                   -> %max-metadata-id, inject-spir-kernel-metadata (src/compiler.lisp)

(in-package :crisp.compiler)
