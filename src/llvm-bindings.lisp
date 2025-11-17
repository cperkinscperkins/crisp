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

;; --- Debug Info ---
(cffi:defctype llvm-metadata-ref :pointer)
(cffi:defctype llvm-di-builder-ref :pointer)

(cffi:defcfun ("LLVMCreateDIBuilder" llvm-create-di-builder) llvm-di-builder-ref
  "Creates a new DIBuilder."
  (M :pointer))

(cffi:defcfun ("LLVMDIBuilderFinalize" llvm-di-builder-finalize) :void
  "Constructs the DWARF metadata for the given DIBuilder."
  (builder llvm-di-builder-ref))

(cffi:defcfun ("LLVMDisposeDIBuilder" llvm-dispose-di-builder) :void
  "Disposes of a DIBuilder. This should be called to avoid memory leaks."
  (builder llvm-di-builder-ref))

(cffi:defcfun ("LLVMDIBuilderCreateFile" llvm-di-builder-create-file) llvm-metadata-ref
  "Creates a new DIFile."
  (builder llvm-di-builder-ref)
  (filename :string)
  (filename-length :unsigned-int)
  (directory :string)
  (directory-length :unsigned-int))

(cffi:defcfun ("LLVMDIBuilderCreateCompileUnit" llvm-di-builder-create-compile-unit) llvm-metadata-ref
  "Creates a new DICompileUnit."
  (builder llvm-di-builder-ref)
  (lang :unsigned-int)        ; LLVMDWARFSourceLanguage
  (file llvm-metadata-ref)
  (producer :string)
  (producer-length :unsigned-int)
  (is-optimized :boolean)
  (flags :string)
  (flags-length :unsigned-int)
  (runtime-ver :unsigned-int)
  (split-name :string)
  (split-name-length :unsigned-int)
  (kind :unsigned-int)          ; LLVMDWARFEmissionKind
  (dwo-id :unsigned-int)
  (split-debug-inline :boolean)
  (debug-info-for-profiling :boolean)
  (sys-root :string)
  (sys-root-length :unsigned-int)
  (sdk :string)
  (sdk-length :unsigned-int))

(cffi:defcfun ("LLVMDIBuilderCreateFunction" llvm-di-builder-create-function) llvm-metadata-ref
  "Creates a new DISubprogram for a function."
  (builder llvm-di-builder-ref)
  (scope llvm-metadata-ref)
  (name :string)
  (name-len :unsigned-int)
  (linkage-name :string)
  (linkage-name-len :unsigned-int)
  (file llvm-metadata-ref)
  (line-no :unsigned-int)
  (ty llvm-metadata-ref)
  (is-local-to-unit :boolean)
  (is-definition :boolean)
  (scope-line :unsigned-int)
  (flags :unsigned-int) ; LLVMDIFlags
  (is-optimized :boolean))

(cffi:defcfun ("LLVMSetSubprogram" llvm-set-subprogram) :void
  "Sets the subprogram for a function."
  (func :pointer)
  (sp llvm-metadata-ref))

(cffi:defcfun ("LLVMDIBuilderCreateBasicType" llvm-di-builder-create-basic-type) llvm-metadata-ref
  "Creates a new DIBasicType."
  (builder llvm-di-builder-ref)
  (name :string)
  (name-len :unsigned-int)
  (size-in-bits :uint64)
  (encoding :unsigned-int) ; LLVMDWARFTypeEncoding
  (flags :unsigned-int))    ; LLVMDIFlags

(cffi:defcfun ("LLVMDIBuilderCreateSubroutineType" llvm-di-builder-create-subroutine-type) llvm-metadata-ref
  "Creates a new DISubroutineType."
  (builder llvm-di-builder-ref)
  (file llvm-metadata-ref)
  (parameter-types :pointer) ; Array of LLVMMetadataRef
  (num-parameter-types :unsigned-int)
  (flags :unsigned-int)) ; LLVMDIFlags

(cffi:defcfun ("LLVMBuilderSetDebugLocation" llvm-builder-set-debug-location) :void
  "Sets the debug location for the next instruction."
  (builder :pointer)
  (line :unsigned-int)
  (col :unsigned-int)
  (scope llvm-metadata-ref))

(cffi:defcfun ("LLVMDIBuilderCreateLexicalBlock" llvm-di-builder-create-lexical-block) llvm-metadata-ref
  "Creates a new lexical block."
  (builder llvm-di-builder-ref)
  (scope llvm-metadata-ref)
  (file llvm-metadata-ref)
  (line :unsigned-int)
  (column :unsigned-int))
