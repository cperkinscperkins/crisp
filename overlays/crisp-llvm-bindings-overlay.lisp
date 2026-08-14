;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; FROM: src/llvm-bindings.lisp
;;;
;;; BUG 033.  LLVMInstructionSetDebugLoc does an UNCHECKED unwrap<Instruction>(Inst),
;;; so handing it anything that is not an Instruction is undefined behaviour — on
;;; Windows it dereferences a garbage vtable and the process dies with "Memory fault
;;; at #x6".  LLVM's IRBuilder CONSTANT-FOLDS, so an arithmetic build call over two
;;; compile-time constants returns a Constant rather than an Instruction, and Crisp
;;; then tried to hang a debug location on it.
;;;
;;; LLVMIsAInstruction is the standard C-API cast-check: it returns the value when it
;;; IS an Instruction and NULL otherwise.  Used by %ATTACH-DEBUG-LOC to skip the attach.
(cffi:defcfun ("LLVMIsAInstruction" llvm-is-a-instruction) :pointer
  "Returns VAL if it is an Instruction, or a NULL pointer if it is not.
   The LLVM C API's checked-cast idiom; see BUG 033."
  (val :pointer))
