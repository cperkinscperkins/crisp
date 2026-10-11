;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)


;;;; ENDEAVOUR 184 cas-lowering, step 2 -- sync-scoped atomics.  Every Crisp atomic is relaxed at
;;;; DEVICE scope; the plain builders above can only say "system" or "single thread".

;; src/llvm-bindings.lisp  (next to LLVMBuildAtomicRMW)
(defcfun ("LLVMBuildAtomicRMWSyncScope" llvm-build-atomic-rmw-sync-scope) :pointer
  "LLVMBuildAtomicRMW with an explicit sync scope SSID (from llvm-get-sync-scope-id).  Endeavour 184."
  (builder  :pointer)
  (op       :int)
  (ptr      :pointer)
  (val      :pointer)
  (ordering :int)
  (ssid     :unsigned-int))

;; src/llvm-bindings.lisp  (next to LLVMBuildAtomicCmpXchg)
(defcfun ("LLVMBuildAtomicCmpXchgSyncScope" llvm-build-atomic-cmpxchg-sync-scope) :pointer
  "LLVMBuildAtomicCmpXchg with an explicit sync scope SSID (from llvm-get-sync-scope-id).  Endeavour 184."
  (builder          :pointer)
  (ptr              :pointer)
  (cmp              :pointer)
  (new              :pointer)
  (success-ordering :int)
  (failure-ordering :int)
  (ssid             :unsigned-int))

;; src/llvm-bindings.lisp
(defcfun ("LLVMGetSyncScopeID" llvm-get-sync-scope-id) :unsigned-int
  "The context's ID for the sync scope NAME (registering it if new).  NAME-LENGTH is its length in
   bytes.  Endeavour 184."
  (context     :pointer)
  (name        :string)
  (name-length :size))
