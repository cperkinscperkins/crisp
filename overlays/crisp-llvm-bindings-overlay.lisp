;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; ---------------------------------------------------------------------------
;;; Endeavor 122 (FFI) Pass 1: bitcode/IR loading + module linking.
;;; FROM: src/llvm-bindings.lisp (move these there at cleanup time).
;;;
;;; These three LLVM-C entry points let the compiler pull a third-party .bc
;;; (e.g. libdevice, libclc, or a user library) into the kernel module so that
;;; a (def-foreign-function ...) call can be resolved at compile time. All three
;;; return an LLVMBool (int): 0 = success, non-zero = failure (with a malloc'd
;;; message written to the out-message pointer, freed via llvm-dispose-message).
;;; ---------------------------------------------------------------------------

(defcfun ("LLVMCreateMemoryBufferWithContentsOfFile"
          llvm-create-memory-buffer-with-contents-of-file) :int
  "Read PATH into a new LLVMMemoryBuffer. Writes the buffer to OUT-MEM-BUF and,
   on failure, an error string to OUT-MESSAGE. Returns 0 on success."
  (path :string)
  (out-mem-buf :pointer)   ; LLVMMemoryBufferRef*
  (out-message :pointer))  ; char**

(defcfun ("LLVMParseIRInContext" llvm-parse-ir-in-context) :int
  "Parse the IR/bitcode in MEM-BUF (consuming it) into a new module in CONTEXT.
   Writes the module to OUT-MODULE and, on failure, an error string to
   OUT-MESSAGE. Returns 0 on success. NOTE: takes ownership of MEM-BUF."
  (context :pointer)
  (mem-buf :pointer)       ; LLVMMemoryBufferRef (consumed)
  (out-module :pointer)    ; LLVMModuleRef*
  (out-message :pointer))  ; char**

(defcfun ("LLVMLinkModules2" llvm-link-modules2) :int
  "Link the SRC module into DEST (consuming SRC). External declarations in DEST
   are resolved against definitions in SRC. Returns 0 on success."
  (dest :pointer)
  (src :pointer))          ; LLVMModuleRef (consumed)

;; NOTE: do NOT (export ...) these from the overlay -- mutating the package's
;; export list makes a later recompile of src/package warn about export variance
;; (fatal under the build's warnings-as-errors). During development, consumers
;; reference them as crisp.llvm-bindings::NAME. At cleanup time, move the defcfun
;; forms to src/llvm-bindings.lisp and add the exports to src/package.lisp.


