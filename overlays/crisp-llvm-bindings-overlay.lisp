;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)


;;;; ============================================================
;;;; Bindings needed for bug 028 cleanup pass:
;;;; iterate module functions, inspect return types, delete dead ones.
;;;; src/llvm-bindings.lisp
;;;; ============================================================

(defcfun ("LLVMGetFirstFunction" llvm-get-first-function) :pointer
  "Returns the first function in a module, or NULL if none."
  (module :pointer))

(defcfun ("LLVMGetNextFunction" llvm-get-next-function) :pointer
  "Returns the next function after FN in the module, or NULL at end."
  (fn :pointer))

(defcfun ("LLVMGlobalGetValueType" llvm-global-get-value-type) :pointer
  "Returns the value type of a global (for a function: its function type,
   not a pointer-to-function type). Works correctly with opaque pointers."
  (global :pointer))

(defcfun ("LLVMGetReturnType" llvm-get-return-type) :pointer
  "Returns the return type of a function type."
  (function-ty :pointer))

(defcfun ("LLVMGetFirstUse" llvm-get-first-use) :pointer
  "Returns the first use of VAL, or a null pointer if VAL has no uses.
   Use cffi:null-pointer-p on the result to test for 'no uses'."
  (val :pointer))

(defcfun ("LLVMGetValueName" llvm-get-value-name) :string
  "Returns the name of a value (e.g. a function name). Empty string if unnamed."
  (val :pointer))

(defun llvm-type-kind-is-array? (ty)
  "Returns T if TY is an LLVM array type ([N x T])."
  (= (llvm-get-type-kind ty) +llvm-array-type-kind+))


