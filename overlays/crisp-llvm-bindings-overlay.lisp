;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)



;;; Endeavour 180 -- loop unrolling.  A loop ID (!llvm.loop) is a DISTINCT, self-referential node,
;;; !0 = distinct !{!0, !props...}.  LLVM-C has no constructor for a distinct node, so the codegen
;;; builds it the standard way: a temporary placeholder as operand 0, then replaces the
;;; placeholder with the node itself -- LLVM turns a uniqued node that references itself into a
;;; distinct one (MDNode::handleChangedOperand, "self-reference cycles").

;; src/llvm-bindings.lisp
(defcfun ("LLVMTemporaryMDNode" llvm-temporary-md-node) :pointer
         "Creates a temporary metadata node (a placeholder to be replaced with
          LLVMMetadataReplaceAllUsesWith).  DATA is an array of LLVMMetadataRef."
         (context :pointer)
         (data :pointer)
         (count :size))

;; src/llvm-bindings.lisp
(defcfun ("LLVMMetadataReplaceAllUsesWith" llvm-metadata-replace-all-uses-with) :void
         "Replaces every use of the TEMPORARY metadata node TEMP with REPLACEMENT, then deletes TEMP."
         (temp :pointer)
         (replacement :pointer))
