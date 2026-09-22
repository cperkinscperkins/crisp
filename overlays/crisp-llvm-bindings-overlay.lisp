;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)


;;; FROM: src/llvm-bindings.lisp  (beside LLVMBuildAtomicRMW, ~line 822)
;;; Endeavour 175 — atomic compare-and-swap, the primitive under atomic-binop!.
;;;
;;; Unlike LLVMBuildAtomicRMW this returns a STRUCT { T, i1 } -- the value that was loaded and
;;; whether the swap happened -- so the caller extracts field 0 for Crisp's "returns the value
;;; before" convention.  Two orderings, one for the success path and one for failure; the failure
;;; ordering may not be stronger than the success one, and LLVM verifies that.
;;;
;;; NOTE FOR FLOAT: cmpxchg accepts only integer or pointer operands, so a float CAS must bitcast
;;; the pointer and both values to an integer of the same width and bitcast the result back.  That
;;; is not a limitation of this binding; it is what the instruction allows.
(defcfun ("LLVMBuildAtomicCmpXchg" llvm-build-atomic-cmpxchg) :pointer
  (builder          :pointer)
  (ptr              :pointer)
  (cmp              :pointer)
  (new              :pointer)
  (success-ordering :int)
  (failure-ordering :int)
  (single-thread    :int))
