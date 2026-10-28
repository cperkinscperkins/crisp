;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;; src/llvm-bindings.lisp  (Endeavour 195: put beside LLVMSetOrdering, the 193 block)
(cffi:defcfun ("LLVMSetAtomicSyncScopeID" llvm-set-atomic-sync-scope-id) :void
  "Sets the sync scope of an atomic instruction (here: a `load atomic` / `store atomic`) to SSID, from
   llvm-get-sync-scope-id.  Endeavour 195 -- LLVMBuildLoad2 / LLVMBuildStore take no scope, so an atomic
   load or store is built plain and then given its ordering (LLVMSetOrdering) and scope (this)."
  (inst :pointer)
  (ssid :unsigned-int))
