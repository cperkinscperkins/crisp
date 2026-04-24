;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;; src/llvm-bindings.lisp — 082-atomics
;; LLVMBuildAtomicRMW: emit an atomic read-modify-write instruction.
;; op is LLVMAtomicRMWBinOp enum (int): xchg=0 add=1 sub=2 max=7 min=8 fadd=11 etc.
;; ordering is LLVMAtomicOrdering enum (int): seq_cst=7
;; single-thread: 0 for multi-threaded (GPU), 1 for single-threaded.
(defcfun ("LLVMBuildAtomicRMW" llvm-build-atomic-rmw) :pointer
  (builder     :pointer)
  (op          :int)
  (ptr         :pointer)
  (val         :pointer)
  (ordering    :int)
  (single-thread :int))
