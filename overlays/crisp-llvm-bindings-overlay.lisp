;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; src/llvm-bindings.lisp
;;; IGC SROA-aliasing workaround (endeavor 103 phase B, 2026-05-16).
;;; Needed by the var-read codegen overlay to mark adjoint-scalar loads
;;; `volatile`, inhibiting the SROA-promotion miscompilation observed on
;;; Intel Arc / IGC.  See put_temp_files_here/igc-bug-report/ for the
;;; minimal reproducer and bug report.
;;; Internal (not exported) — callers in :crisp.compiler use the
;;; double-colon form `crisp.llvm-bindings::llvm-set-volatile`.  Avoided
;;; an `(export ...)` here because that triggers an SBCL package-variance
;;; warning against the defpackage in src/package.lisp (CLAUDE.md asks us
;;; not to patch src).
(cffi:defcfun ("LLVMSetVolatile" llvm-set-volatile) :void
  (memory-access-inst :pointer)
  (is-volatile :int))
