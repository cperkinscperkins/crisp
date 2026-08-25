;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;;; ============================================================================
;;;; Endeavour 155 — LLVM VALUE INSPECTION, for distributing tile address arithmetic.
;;;;
;;;; A cooperative-matrix tile's fragment coordinate is emitted as `add i32 <base>, <const>` --
;;;; the tile's origin plus a compile-time fragment offset.  Codegen then computes
;;;; (base + const) * dim * stride PER FRAGMENT, and since the stride is a runtime value and Xe
;;;; has no native 64-bit multiply, each one becomes an emulated mul/mach/macl sequence.  Measured
;;;; on a 256x256 bf16 matmul: 311 mul + 224 macl + 75 mach against SIXTEEN dpas.
;;;;
;;;; Distributing it -- base*dim*stride once per tile, plus const*dim*stride which strength-reduces
;;;; to shifts -- needs codegen to SEE that the coordinate is an add-with-constant.  These are the
;;;; bindings for that; LLVM's own reassociation will not do it, since distributing a multiply over
;;;; an add is not obviously profitable without knowing the base is loop-invariant.
;;;; ============================================================================

(defcfun ("LLVMGetInstructionOpcode" llvm-get-instruction-opcode) :int
  "Opcode of an instruction value (LLVMOpcode enum; Add = 11)."
  (inst :pointer))

(defcfun ("LLVMIsAInstruction" llvm-is-a-instruction) :pointer
  "The value as an Instruction, or NULL if it is not one."
  (val :pointer))

(defcfun ("LLVMIsAConstantInt" llvm-is-a-constant-int) :pointer
  "The value as a ConstantInt, or NULL if it is not one."
  (val :pointer))

(defcfun ("LLVMGetOperand" llvm-get-operand) :pointer
  "Operand N of a user (instruction/constant-expr)."
  (val :pointer) (index :unsigned-int))

(defcfun ("LLVMConstIntGetSExtValue" llvm-const-int-get-sext-value) :long-long
  "The sign-extended value of a ConstantInt."
  (val :pointer))

;; Endeavour 156 Step 2: :xe-native refuses a non-zero fragment init rather than guessing the
;; per-lane encoding of the initial value, and this is how it recognises the zero case.
(defcfun ("LLVMIsNull" llvm-is-null) :boolean
  "T if VAL is a null/zero constant."
  (val :pointer))
