;; src/llvm-bindings.lisp
(in-package :crisp.llvm-bindings)



;; Find the LLVM C library
(define-foreign-library libllvm
  (:windows "LLVM-C.dll")
  (:unix (:or "libLLVM-21.so" "libLLVM.so"))
  (:darwin "libLLVM.dylib")
  (t (:default "libLLVM")))

(use-foreign-library libllvm)



;; --- Core Module and Context ---
(defcfun ("LLVMModuleCreateWithName" llvm-module-create) :pointer
  (module-id :string))

(defcfun ("LLVMPrintModuleToString" llvm-print-module-to-string) :pointer
  (module :pointer))

(defcfun ("LLVMDisposeModule" llvm-dispose-module) :void
  (module :pointer))

(defcfun ("LLVMDisposeMessage" llvm-dispose-message) :void
  (message :pointer))

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

(defcfun ("LLVMBuildLoad2" llvm-build-load) :pointer
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