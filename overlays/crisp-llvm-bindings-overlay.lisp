;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)


;;; ---------------------------------------------------------------------------
;;; Call-instruction calling convention.
;;;
;;; Discovered 2026-05-31 while debugging InstCombine destruction on SPV path:
;;; if a CALL instruction's calling convention does not match the callee
;;; function's calling convention, recent LLVM (opt-21) treats the call as
;;; immediate UB and InstCombine collapses the surrounding control flow to
;;; `store i1 true, ptr poison` + `br i1 poison`, eventually reducing the
;;; whole kernel to `entry: unreachable`.
;;;
;;; We have LLVMSetFunctionCallConv (sets CC on function declarations) but
;;; not the per-call-instruction equivalent.  Add it so the codegen overlay
;;; can propagate the callee's CC to call sites.
;;;
;;; FROM: src/llvm-bindings.lisp (eventual home: alongside LLVMSetFunctionCallConv)
(defcfun ("LLVMSetInstructionCallConv" llvm-set-instruction-call-conv) :void
         "Sets the calling convention on a CALL/INVOKE instruction.
          Common values: 0=C, 75=spir_func (LLVM 21), 76=spir_kernel."
         (inst :pointer)
         (cc :unsigned-int))

(defcfun ("LLVMGetInstructionCallConv" llvm-get-instruction-call-conv) :unsigned-int
         "Reads the calling convention from a CALL/INVOKE instruction."
         (inst :pointer))
