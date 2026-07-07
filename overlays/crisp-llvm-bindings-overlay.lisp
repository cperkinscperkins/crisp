;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; ===================================================================
;;; Endeavor 133 (MMA on SPV) — target-extension types, for the opaque
;;; SPIR-V cooperative-matrix type target("spirv.CooperativeMatrixKHR",
;;; <elem>, <scope>, <rows>, <cols>, <use>).  llvm-spirv (our bundled build)
;;; lowers this + the __spirv_CooperativeMatrix{Load,MulAdd,Store}KHR builtins
;;; to OpCooperativeMatrix*KHR under SPV_KHR_cooperative_matrix.
;;; FROM: src/llvm-bindings.lisp
;;; ===================================================================

(defcfun ("LLVMTargetExtTypeInContext" llvm-target-ext-type-in-context) :pointer
  "Build a target-extension type target(NAME, <type-params…>, <int-params…>).
   TYPE-PARAMS is a C array of LLVMTypeRef (count TYPE-PARAM-COUNT); INT-PARAMS is a
   C array of unsigned (count INT-PARAM-COUNT)."
  (ctx :pointer) (name :string)
  (type-params :pointer) (type-param-count :unsigned-int)
  (int-params :pointer) (int-param-count :unsigned-int))


