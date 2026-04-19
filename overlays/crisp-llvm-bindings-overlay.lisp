;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;; src/llvm-bindings.lisp
(cffi:defcfun ("LLVMGetIntTypeWidth" llvm-get-int-type-width) :unsigned-int
  "Returns the bit-width of an LLVM integer type (e.g. 32 for i32, 64 for i64)."
  (int-ty :pointer))


