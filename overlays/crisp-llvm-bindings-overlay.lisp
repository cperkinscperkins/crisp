;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; src/llvm-bindings.lisp — device vector support
(defcfun ("LLVMVectorType" llvm-vector-type) :pointer
  "Create a fixed-length vector type wrapping ELEMENT-TYPE with ELEMENT-COUNT lanes."
  (element-type :pointer)
  (element-count :unsigned-int))

(defcfun ("LLVMBuildInsertElement" llvm-build-insert-element) :pointer
  "Insert ELT-VAL into VEC-VAL at position INDEX (an i32 LLVM value).
   Returns the updated vector value."
  (builder    :pointer)
  (vec-val    :pointer)
  (elt-val    :pointer)
  (index      :pointer)   ; must be an i32 LLVM value, e.g. (llvm-const-int (llvm-int32-type) N nil)
  (name       :string))

