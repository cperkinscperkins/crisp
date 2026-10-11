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


;;;; ENDEAVOUR 184 cas-lowering, step 3 -- every alloca in the ENTRY block.
;;;; SROA and mem2reg promote only entry-block allocas.  Crisp built each alloca at the current insert
;;;; point, so every variable bound inside a branch (let, loop counter, if-result slot, ...) stayed in
;;;; memory after -O3 -- e.g. the CAS retry loop's counter round-tripped through .local each iteration.

;; src/llvm-bindings.lisp  (next to LLVMBuildAlloca -- the raw call, under a new name)
(defcfun ("LLVMBuildAlloca" %llvm-build-alloca-at-insert-point) :pointer
  "The raw LLVMBuildAlloca: an alloca at BUILDER's insert point.  Codegen should call
   llvm-build-alloca, which places it in the entry block.  Endeavour 184."
  (builder :pointer)
  (type    :pointer)
  (name    :string))

;; src/llvm-bindings.lisp
(defcfun ("LLVMGetFirstInstruction" llvm-get-first-instruction) :pointer
  "The first instruction of basic block BB, or a null pointer if BB is empty.  Endeavour 184."
  (bb :pointer))

;; src/llvm-bindings.lisp  -- REPLACES the LLVMBuildAlloca defcfun of this name.
(defun llvm-build-alloca (builder type name)
  "Builds a static alloca of TYPE at the TOP of the ENTRY block of the function BUILDER is in, and
   leaves BUILDER where it was.  Endeavour 184: SROA and mem2reg promote only entry-block allocas,
   so an alloca built at the insert point inside a branch or loop stayed in memory after -O3.  This
   is where clang puts them too.
   Moving a static alloca to the entry block does not change what it means: it never had a fresh
   address per execution on our GPU targets -- the backends give a non-entry static alloca one fixed
   frame slot -- and every caller stores its initial value at the original point, after the alloca."
  (let* ((fn    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (entry (llvm-get-entry-basic-block fn))
         (first (llvm-get-first-instruction entry))
         (tmp   (llvm-create-builder)))
    (unwind-protect
         (progn
           (if (cffi:null-pointer-p first)
               (llvm-position-builder-at-end tmp entry)
               (llvm-position-builder-before tmp first))
           (%llvm-build-alloca-at-insert-point tmp type name))
      (llvm-dispose-builder tmp))))
