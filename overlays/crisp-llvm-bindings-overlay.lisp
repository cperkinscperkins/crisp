;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)



;;; FROM: src/llvm-bindings.lisp
;;;
;;; Endeavor 152 fix B needs to give the `.extern .shared` window symbol an explicit
;;; alignment.  Without this the symbol takes the ABI alignment of its type -- 1 for the
;;; [0 x i8] we declare it as -- and every scratch access inherits it.
(defcfun ("LLVMSetAlignment" llvm-set-alignment) :void
  (global :pointer)
  (bytes :unsigned-int))
