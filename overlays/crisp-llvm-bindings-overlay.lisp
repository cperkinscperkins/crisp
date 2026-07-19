;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; src/llvm-bindings.lisp
;;; Endeavor 139 (Chapter 3, step 4) — two bindings the multi-lap phase counter needs to hoist
;;; its per-ring visit counter into the function's entry block (an alloca must live in the entry
;;; block to persist across loop iterations rather than re-allocate each pass).
;;;   LLVMGetEntryBasicBlock    — the function's entry (first) block.
;;;   LLVMPositionBuilderBefore — insert before an instruction (we insert before the entry
;;;                               block's terminator, i.e. after param setup, before the body br).
(defcfun ("LLVMGetEntryBasicBlock" llvm-get-entry-basic-block) :pointer
  (func :pointer))

(defcfun ("LLVMPositionBuilderBefore" llvm-position-builder-before) :void
  (builder :pointer)
  (instr :pointer))

;; NOTE: intentionally NOT exported.  Exporting from an overlay mutates the
;; package's export list, which makes src/package.lisp's DEFPACKAGE signal a
;; package-variance warning (fatal under ASDF).  Callers use the ::-qualified
;; name instead.


