;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

;;; EMPTY as of 2026-10-27 -- endeavour 195 folded LLVMSetAtomicSyncScopeID into src/llvm-bindings.lisp.

(in-package :crisp.llvm-bindings)


;;; ---------------------------------------------------------------------------
;;; Endeavour 210 (2026-11-08): a TYPE attribute (byval(<ty>)) for the by-value
;;; __grid_constant__ CUtensorMap kernel parameter.
;;; FROM: src/llvm-bindings.lisp (new, beside LLVMCreateEnumAttribute)
(cffi:defcfun ("LLVMCreateTypeAttribute" llvm-create-type-attribute) :pointer
  "Create a type attribute (byval, sret, elementtype, ...) of kind KIND-ID carrying TYPE-REF.
   Endeavour 210: byval([128 x i8]) on a kernel's TMA descriptor parameter."
  (context :pointer) (kind-id :unsigned-int) (type-ref :pointer))
