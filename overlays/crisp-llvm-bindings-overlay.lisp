;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; --- START PATCHES ---;; src/llvm-bindings.lisp - Add LLVMSetTarget binding
(cffi:defcfun ("LLVMSetTarget" llvm-set-target) :void
              "Set the target triple for a module."
              (module :pointer)
              (triple :string))
