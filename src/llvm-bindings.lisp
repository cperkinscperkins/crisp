;; src/llvm-bindings.lisp
(in-package :crisp.llvm-bindings)



;; Find the LLVM C library
(define-foreign-library libllvm
  (:windows "LLVM-C.dll")
  (:unix (:or "libLLVM-21.so" "libLLVM.so"))
  (:darwin "libLLVM.dylib")
  (t (:default "libLLVM")))

;; We don't load this here, because otherwise the build will
;; not succeed.  This library is loaded as part of main.
;; (use-foreign-library libllvm)



;; --- Core Module and Context ---
(defcfun ("LLVMModuleCreateWithName" llvm-module-create) :pointer
  (module-id :string))

(defcfun ("LLVMPrintModuleToString" llvm-print-module-to-string) :pointer
  (module :pointer))

(defcfun ("LLVMDisposeModule" llvm-dispose-module) :void
  (module :pointer))

(defcfun ("LLVMDisposeMessage" llvm-dispose-message) :void
  (message :pointer))

(defcfun ("LLVMTypeOf" llvm-type-of) :pointer
  "Obtain the type of a value."
  (val :pointer))

;; --- Types ---
(defcfun ("LLVMInt32Type" llvm-int32-type) :pointer)

(defcfun ("LLVMFunctionType" llvm-function-type) :pointer
  (return-type :pointer)
  (param-types :pointer) ; We'll pass an array of types
  (param-count :int)
  (is-var-arg :boolean))

;; --- Functions ---
(defcfun ("LLVMAddFunction" llvm-add-function) :pointer
  (module :pointer)
  (name :string)
  (type :pointer))

(defcfun ("LLVMGetInsertBlock" llvm-get-insert-block) :pointer
  (builder :pointer))

(defcfun ("LLVMGetBasicBlockParent" llvm-get-basic-block-parent) :pointer
  (block :pointer))

(defcfun ("LLVMGetNamedFunction" llvm-get-named-function) :pointer
  (module :pointer)
  (name :string))

;; --- Basic Blocks ---
(defcfun ("LLVMAppendBasicBlock" llvm-append-basic-block) :pointer
  (function :pointer)
  (name :string))

;; --- Builder ---
(defcfun ("LLVMCreateBuilder" llvm-create-builder) :pointer)

(defcfun ("LLVMPositionBuilderAtEnd" llvm-position-builder-at-end) :void
  (builder :pointer)
  (block :pointer))

(defcfun ("LLVMDisposeBuilder" llvm-dispose-builder) :void
  (builder :pointer))

(defcfun ("LLVMBuildCall2" llvm-build-call2) :pointer
  "Builds a call instruction."
  (builder :pointer)
  (fn-type :pointer)
  (fn :pointer)
  (args :pointer)
  (num-args :unsigned-int)
  (name :string))

;; --- Instructions ---
(defcfun ("LLVMConstInt" llvm-const-int) :pointer
  (int-type :pointer)
  (value :uint64)
  (sign-extend :boolean))

(defcfun ("LLVMBuildRet" llvm-build-ret) :pointer
  (builder :pointer)
  (value :pointer))

;; --- Parameters ---
(defcfun ("LLVMGetParam" llvm-get-param) :pointer
  (function :pointer)
  (index :uint))

;; --- Memory (The "Alloca Trick") ---
(defcfun ("LLVMBuildAlloca" llvm-build-alloca) :pointer
  (builder :pointer)
  (type :pointer)
  (name :string))

(defcfun ("LLVMBuildStore" llvm-build-store) :pointer
  (builder :pointer)
  (value :pointer)
  (pointer :pointer))

(defcfun ("LLVMBuildLoad" llvm-build-load) :pointer
  (builder :pointer)
  (pointer :pointer)
  (name :string))

(defcfun ("LLVMBuildLoad2" llvm-build-load2) :pointer
  (builder :pointer)
  (type :pointer)
  (pointer :pointer)
  (name :string))
  
;; --- Math ---
(defcfun ("LLVMBuildAdd" llvm-build-add) :pointer
  (builder :pointer)
  (lhs :pointer)
  (rhs :pointer)
  (name :string))
