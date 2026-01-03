;; src/llvm-bindings.lisp
(in-package :crisp.llvm-bindings)


;; Find the LLVM C library
(define-foreign-library libllvm
                        (:windows "C:/Program Files/LLVM/bin/LLVM-C.dll")
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

(defcfun ("LLVMGetModuleContext" llvm-get-module-context) :pointer
         (module :pointer))

(defcfun ("LLVMTypeOf" llvm-type-of) :pointer
         "Obtain the type of a value."
         (val :pointer))

(defcfun ("LLVMPrintTypeToString" llvm-print-type-to-string) :string
         (type :pointer))

(defcfun ("LLVMPrintValueToString" llvm-print-value-to-string) :string
         (val :pointer))

;; --- Types ---
(defcfun ("LLVMInt32TypeInContext" llvm-int32-type-in-context) :pointer
         (context :pointer))
(defcfun ("LLVMInt64TypeInContext" llvm-int64-type-in-context) :pointer
         (context :pointer))

(defcfun ("LLVMInt32Type" llvm-int32-type) :pointer)
(defcfun ("LLVMInt8Type" llvm-int8-type) :pointer)

(defcfun ("LLVMInt8TypeInContext" llvm-int8-type-in-context) :pointer
         (context :pointer))
(defcfun ("LLVMInt1Type" llvm-int1-type) :pointer)
(defcfun ("LLVMInt16Type" llvm-int16-type) :pointer)

(defcfun ("LLVMPointerType" llvm-pointer-type) :pointer
         (type :pointer)
         (address-space :unsigned-int))

(defcfun ("LLVMGetPointerAddressSpace" llvm-get-pointer-address-space) :unsigned-int
         (type :pointer))

(defcfun ("LLVMSizeOf" llvm-size-of) :pointer
         (type :pointer))
(defcfun ("LLVMInt64Type" llvm-int64-type) :pointer)

(defcfun ("LLVMHalfType" llvm-half-type) :pointer
         "Get a 16-bit floating-point type.")
(defcfun ("LLVMBFloatType" llvm-bfloat-type) :pointer
         "Get a 16-bit brain floating-point type.")
(defcfun ("LLVMFloatType" llvm-float-type) :pointer
         "Get a 32-bit floating-point type.")
(defcfun ("LLVMDoubleType" llvm-double-type) :pointer
         "Get a 64-bit floating-point type.")

(defcfun ("LLVMVoidType" llvm-void-type) :pointer
         "Get a void type.")

(defcfun ("LLVMGetTypeKind" llvm-get-type-kind) :int
         (ty :pointer))

(defconstant +llvm-void-type-kind+ 0)
(defconstant +llvm-half-type-kind+ 1)
(defconstant +llvm-float-type-kind+ 2)
(defconstant +llvm-double-type-kind+ 3)
;; 4-7 are other FP types and Label
(defconstant +llvm-integer-type-kind+ 8)
(defconstant +llvm-function-type-kind+ 9)
(defconstant +llvm-struct-type-kind+ 10)
(defconstant +llvm-array-type-kind+ 11)
(defconstant +llvm-pointer-type-kind+ 12)
(defconstant +llvm-vector-type-kind+ 13)

(defun llvm-type-kind-is-pointer? (ty)
  (= (llvm-get-type-kind ty) +llvm-pointer-type-kind+))


(defcfun ("LLVMFunctionType" llvm-function-type) :pointer
         (return-type :pointer)
         (param-types :pointer) ; We'll pass an array of types
         (param-count :int)
         (is-var-arg :boolean))

(defcfun ("LLVMStructTypeInContext" llvm-struct-type-in-context) :pointer
         "Create a new structure type in a context."
         (context :pointer)
         (element-types :pointer)
         (element-count :unsigned-int)
         (packed :boolean))

(defcfun ("LLVMStructCreateNamed" llvm-struct-create-named) :pointer
         "Create a new named structure type in a context."
         (context :pointer)
         (name :string))

(defcfun ("LLVMStructSetBody" llvm-struct-set-body) :void
         "Sets the elements of a named structure type."
         (struct-ty :pointer)
         (element-types :pointer) ; Array of types
         (element-count :unsigned-int)
         (packed :boolean))

(defcfun ("LLVMGetTypeByName" llvm-get-type-by-name) :pointer
         "Obtain a type from a module by its registered name."
         (module :pointer)
         (name :string))

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

(defcfun ("LLVMDeleteFunction" llvm-delete-function) :void
         "Deletes a function from its parent module."
         (fn :pointer))

(defcfun ("LLVMCountBasicBlocks" llvm-count-basic-blocks) :unsigned-int
         "Counts the number of basic blocks in a function."
         (fn :pointer))

;; --- Basic Blocks ---
(defcfun ("LLVMAppendBasicBlock" llvm-append-basic-block) :pointer
         (function :pointer)
         (name :string))

(defcfun ("LLVMGetBasicBlockTerminator" llvm-get-basic-block-terminator) :pointer
         (block :pointer))


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
(defcfun ("LLVMConstPointerNull" llvm-const-pointer-null) :pointer
         (type :pointer))

(defcfun ("LLVMConstNull" llvm-const-null) :pointer
         (type :pointer))

(defcfun ("LLVMConstInt" llvm-const-int) :pointer
         (int-type :pointer)
         (value :uint64)
         (sign-extend :boolean))

(defcfun ("LLVMConstReal" llvm-const-real) :pointer
         (real-type :pointer)
         (value :double))

(defcfun ("LLVMBuildRet" llvm-build-ret) :pointer
         (builder :pointer)
         (value :pointer))

(defcfun ("LLVMBuildRetVoid" llvm-build-ret-void) :pointer
         (builder :pointer))


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

(defcfun ("LLVMGetUndef" llvm-get-undef) :pointer
         "Get an undefined value of a given type."
         (type :pointer))

(defcfun ("LLVMBuildLoad" llvm-build-load) :pointer
         (builder :pointer)
         (pointer :pointer)
         (name :string))

(defcfun ("LLVMBuildLoad2" llvm-build-load2) :pointer
         (builder :pointer)
         (type :pointer)
         (pointer :pointer)
         (name :string))

(defcfun ("LLVMBuildInsertValue" llvm-build-insert-value) :pointer
         "Builds an instruction to insert a value into a struct."
         (builder :pointer)
         (agg-val :pointer)
         (elt-val :pointer)
         (index :unsigned-int)
         (name :string))

(defcfun ("LLVMBuildExtractValue" llvm-build-extract-value) :pointer
         "Builds an instruction to extract a value from a struct."
         (builder :pointer)
         (agg-val :pointer)
         (index :unsigned-int)
         (name :string))

;; --- Math ---
(defcfun ("LLVMBuildAdd" llvm-build-add) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildFAdd" llvm-build-fadd) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildSub" llvm-build-sub) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildFSub" llvm-build-fsub) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildMul" llvm-build-mul) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildFMul" llvm-build-fmul) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildSDiv" llvm-build-sdiv) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildFDiv" llvm-build-fdiv) :pointer
         (builder :pointer)
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

;; --- Casting ---
(defcfun ("LLVMBuildSExt" llvm-build-sext) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildZExt" llvm-build-zext) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildFPExt" llvm-build-fp-ext) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildSIToFP" llvm-build-si-to-fp) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildUIToFP" llvm-build-ui-to-fp) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildFPToSI" llvm-build-fp-to-si) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildFPToUI" llvm-build-fp-to-ui) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildTrunc" llvm-build-trunc) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildFPTrunc" llvm-build-fp-trunc) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))


(defcfun ("LLVMBuildPtrToInt" llvm-build-ptr-to-int) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))


(defcfun ("LLVMBuildIntToPtr" llvm-build-int-to-ptr) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildBitCast" llvm-build-bit-cast) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildAddrSpaceCast" llvm-build-addrspace-cast) :pointer
         (builder :pointer)
         (val :pointer)
         (dest-ty :pointer)
         (name :string))

(defcfun ("LLVMBuildStructGEP" llvm-build-struct-gep) :pointer
         (builder :pointer)
         (ptr :pointer)
         (idx :unsigned-int)
         (name :string))

(defcfun ("LLVMBuildStructGEP2" llvm-build-struct-gep2) :pointer
         (builder :pointer)
         (type :pointer)
         (ptr :pointer)
         (idx :unsigned-int)
         (name :string))

(defcfun ("LLVMBuildGEP2" llvm-build-gep2) :pointer
         (builder :pointer)
         (type :pointer)
         (ptr :pointer)
         (indices :pointer)
         (num-indices :unsigned-int)
         (name :string))

(defcfun ("LLVMBuildGEP" llvm-build-gep) :pointer
         (builder :pointer)
         (ptr :pointer)
         (indices :pointer)
         (num-indices :unsigned-int)
         (name :string))

(defcfun ("LLVMBuildInBoundsGEP2" llvm-build-in-bounds-gep2) :pointer
         (builder :pointer)
         (type :pointer)
         (ptr :pointer)
         (indices :pointer)
         (num-indices :unsigned-int)
         (name :string))

;; --- Comparisons ---
(defcfun ("LLVMBuildICmp" llvm-build-icmp) :pointer
         (builder :pointer)
         (op :unsigned-int) ;; LLVMIntPredicate
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

(defcfun ("LLVMBuildFCmp" llvm-build-fcmp) :pointer
         (builder :pointer)
         (op :unsigned-int) ;; LLVMRealPredicate
         (lhs :pointer)
         (rhs :pointer)
         (name :string))

;; LLVMIntPredicate
(defconstant +llvm-int-eq+ 32)
(defconstant +llvm-int-ne+ 33)
(defconstant +llvm-int-ugt+ 34)
(defconstant +llvm-int-uge+ 35)
(defconstant +llvm-int-ult+ 36)
(defconstant +llvm-int-ule+ 37)
(defconstant +llvm-int-sgt+ 38)
(defconstant +llvm-int-sge+ 39)
(defconstant +llvm-int-slt+ 40)
(defconstant +llvm-int-sle+ 41)

;; LLVMRealPredicate
(defconstant +llvm-real-oeq+ 1)
(defconstant +llvm-real-ogt+ 2)
(defconstant +llvm-real-oge+ 3)
(defconstant +llvm-real-olt+ 4)
(defconstant +llvm-real-ole+ 5)
(defconstant +llvm-real-one+ 6)
(defconstant +llvm-real-ord+ 7)
(defconstant +llvm-real-uno+ 8)
(defconstant +llvm-real-ueq+ 9)
(defconstant +llvm-real-ugt+ 10)
(defconstant +llvm-real-uge+ 11)
(defconstant +llvm-real-ult+ 12)
(defconstant +llvm-real-ule+ 13)
(defconstant +llvm-real-une+ 14)

;; --- Branching ---
(defcfun ("LLVMBuildBr" llvm-build-br) :pointer
         (builder :pointer)
         (dest :pointer))

(defcfun ("LLVMBuildCondBr" llvm-build-cond-br) :pointer
         (builder :pointer)
         (if :pointer)
         (then :pointer)
         (else :pointer))

(defcfun ("LLVMBuildPhi" llvm-build-phi) :pointer
         "Builds a PHI node."
         (builder :pointer)
         (type :pointer)
         (name :string))

(defcfun ("LLVMAddIncoming" llvm-add-incoming) :void
         "Adds incoming values to a PHI node."
         (phi-node :pointer)
         (incoming-values :pointer)
         (incoming-blocks :pointer)
         (count :unsigned-int))

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
              (lang :unsigned-int) ; LLVMDWARFSourceLanguage
              (file llvm-metadata-ref)
              (producer :string)
              (producer-length :unsigned-int)
              (is-optimized :boolean)
              (flags :string)
              (flags-length :unsigned-int)
              (runtime-ver :unsigned-int)
              (split-name :string)
              (split-name-length :unsigned-int)
              (kind :unsigned-int) ; LLVMDWARFEmissionKind
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
              (flags :unsigned-int)) ; LLVMDIFlags

(cffi:defcfun ("LLVMDIBuilderCreateSubroutineType" llvm-di-builder-create-subroutine-type) llvm-metadata-ref
              "Creates a new DISubroutineType."
              (builder llvm-di-builder-ref)
              (file llvm-metadata-ref)
              (parameter-types :pointer) ; Array of LLVMMetadataRef
              (num-parameter-types :unsigned-int)
              (flags :unsigned-int)) ; LLVMDIFlags

(cffi:defcfun ("LLVMDIBuilderCreateDebugLocation" llvm-di-builder-create-debug-location) llvm-metadata-ref
              "Creates a new DILocation metadata node."
              (context :pointer)
              (line :unsigned-int)
              (column :unsigned-int)
              (scope llvm-metadata-ref)
              (inlined-at llvm-metadata-ref))

(cffi:defcfun ("LLVMInstructionSetDebugLoc" llvm-instruction-set-debug-loc) :void
              "Sets the debug location for the given instruction."
              (inst :pointer)
              (loc :pointer))


;; --- Generic Metadata (for specific annotations like kernel args) ---

(defcfun ("LLVMGlobalSetMetadata" llvm-global-set-metadata) :void
         "Sets a metadata attachment to a global value (e.g. Function)."
         (global :pointer)
         (kind :unsigned-int)
         (md :pointer))

(defcfun ("LLVMGetMDKindIDInContext" llvm-get-md-kind-id-in-context) :unsigned-int
         "Obtains the ID for a metadata kind (e.g. 'kernel_arg_addr_space')."
         (context :pointer)
         (name :string)
         (slen :unsigned-int))

(defcfun ("LLVMMDNodeInContext2" llvm-md-node-in-context2) :pointer
         "Creates a metadata node in the context."
         (context :pointer)
         (mds :pointer) ; Array of LLVMMetadataRef
         (count :unsigned-int))

(defcfun ("LLVMValueAsMetadata" llvm-value-as-metadata) :pointer
         "Wraps a Value (like a ConstantInt) as Metadata."
         (val :pointer))
