;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; src/llvm-bindings.lisp
;;; Array type support for (array T N)
(defcfun ("LLVMArrayType" llvm-array-type) :pointer
  "Create a fixed-size array type with COUNT elements of ELEMENT-TYPE.
   Corresponds to LLVM's [COUNT x ELEMENT-TYPE]."
  (element-type :pointer)
  (count :unsigned-int))

;; NOTE: Add #:llvm-array-type to the (:export ...) list in src/package.lisp
;; for :crisp.llvm-bindings to make this symbol accessible without :: qualification.

