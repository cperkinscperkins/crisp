;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; ---------------------------------------------------------------------------
;;; Endeavour 185 (math-ops): instruction builders the integer division / bit-op lowerings need.
;;; FROM: src/llvm-bindings.lisp (append beside LLVMBuildAnd / LLVMBuildOr / LLVMBuildShl).
;;; Referenced from the compiler as crisp.llvm-bindings::NAME (no export change needed).
;;; ---------------------------------------------------------------------------
(cffi:defcfun ("LLVMBuildSelect" llvm-build-select) :pointer
  (builder :pointer) (if-val :pointer) (then-val :pointer) (else-val :pointer) (name :string))
(cffi:defcfun ("LLVMBuildXor" llvm-build-xor) :pointer
  (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(cffi:defcfun ("LLVMBuildSRem" llvm-build-srem) :pointer
  (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(cffi:defcfun ("LLVMBuildURem" llvm-build-urem) :pointer
  (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(cffi:defcfun ("LLVMBuildAShr" llvm-build-a-shr) :pointer
  (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(cffi:defcfun ("LLVMBuildNot" llvm-build-not) :pointer
  (builder :pointer) (val :pointer) (name :string))
(cffi:defcfun ("LLVMGetEnumAttributeKindForName" llvm-get-enum-attribute-kind-for-name) :unsigned-int
  (name :string) (slen :size))
(cffi:defcfun ("LLVMCreateEnumAttribute" llvm-create-enum-attribute) :pointer
  (context :pointer) (kind-id :unsigned-int) (val :uint64))
(cffi:defcfun ("LLVMBuildFRem" llvm-build-frem) :pointer
  (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
