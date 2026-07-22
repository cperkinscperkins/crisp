;; src/llvm-bindings.lisp
(in-package :crisp.llvm-bindings)


;; Find the LLVM C library
(define-foreign-library libllvm
                        ;; 1. Check for bundled DLL in bin/ (Windows)
                        (:windows "bin/LLVM-C.dll")
                        ;; 2. Fallback to System Install (Windows)
                        (:windows "C:/Program Files/LLVM/bin/LLVM-C.dll")

                        ;; 1. Check for bundled SO in bin/ (Linux)
                        ;; 2. Fallback to System Install (Ubuntu/Debian)
                        (:unix (:or "bin/libLLVM.so" "libLLVM-21.so" "libLLVM-21.so.1" "libLLVM.so"))

                        (:darwin "libLLVM.dylib")
                        (t (:default "libLLVM")))

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

(defcfun ("LLVMSetTarget" llvm-set-target) :void
         "Set the target triple for a module."
         (module :pointer)
         (triple :string))

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

;; Endeavor 139 (Chapter 3, step 4): the multi-lap phase counter hoists its
;; per-ring visit counter alloca into the function's entry block so it persists
;; across loop iterations rather than re-allocating each pass.
(defcfun ("LLVMGetEntryBasicBlock" llvm-get-entry-basic-block) :pointer
         (func :pointer))


;; --- Builder ---
(defcfun ("LLVMCreateBuilder" llvm-create-builder) :pointer)

(defcfun ("LLVMPositionBuilderAtEnd" llvm-position-builder-at-end) :void
         (builder :pointer)
         (block :pointer))

;; Insert before an instruction (we insert before the entry block's terminator,
;; i.e. after param setup, before the body branch) — pairs with the entry-block
;; alloca hoisting above.
(defcfun ("LLVMPositionBuilderBefore" llvm-position-builder-before) :void
         (builder :pointer)
         (instr :pointer))

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

;; Endeavor 140 (Chapter 4): bitwise builders the wgmma SMEM descriptor bit-pack
;; needs — start = (addr >> 4) & 0x3FFF, then OR the compile-time LBO/SBO/swizzle
;; constant.
(defcfun ("LLVMBuildAnd" llvm-build-and) :pointer
         (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(defcfun ("LLVMBuildOr" llvm-build-or) :pointer
         (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(defcfun ("LLVMBuildLShr" llvm-build-l-shr) :pointer
         (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))
(defcfun ("LLVMBuildShl" llvm-build-shl) :pointer
         (builder :pointer) (lhs :pointer) (rhs :pointer) (name :string))

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

(defcfun ("LLVMBuildUDiv" llvm-build-udiv) :pointer
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


;;
(defcfun ("LLVMAddGlobalInAddressSpace" llvm-add-global-in-addrspace) :pointer
  (module    :pointer)
  (type      :pointer)
  (name      :string)
  (addrspace :unsigned-int))

(defcfun ("LLVMGetNamedGlobal" llvm-get-named-global) :pointer
  (module :pointer)
  (name   :string))

(defcfun ("LLVMSetLinkage" llvm-set-linkage) :void
  (global  :pointer)
  (linkage :unsigned-int))

(defcfun ("LLVMSetInitializer" llvm-set-initializer) :void
  (global      :pointer)
  (const-val   :pointer))

;; Inline assembly (Endeavor 137 TMA — mbarrier expect_tx / try_wait.parity are not NVVM
;; intrinsics in LLVM 21, so we emit them as inline PTX).  Returns a callee value to be used
;; as the function operand of LLVMBuildCall2 with a matching (void or scalar) function type.
;; Dialect 0 = ATT (the correct choice for NVPTX).  LLVMBool args are 0/1 ints.
(defcfun ("LLVMGetInlineAsm" llvm-get-inline-asm) :pointer
  (type             :pointer)
  (asm-string       :string)
  (asm-string-size  :unsigned-int)
  (constraints      :string)
  (constraints-size :unsigned-int)
  (has-side-effects :int)
  (is-align-stack   :int)
  (dialect          :int)
  (can-throw        :int))


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


;; --- Function Calling Convention ---

(defcfun ("LLVMSetFunctionCallConv" llvm-set-function-call-conv) :void
         "Sets the calling convention for a function.
          Common values: 0=C, 76=spir_kernel, 77=spir_func"
         (fn :pointer)
         (cc :unsigned-int))

(defcfun ("LLVMGetFunctionCallConv" llvm-get-function-call-conv) :unsigned-int
         "Gets the calling convention for a function."
         (fn :pointer))

;; --- Metadata Management ---

(defcfun ("LLVMSetMetadata" llvm-set-metadata) :void
         "Attaches metadata to an instruction or function.
          Use with metadata kind IDs from LLVMGetMDKindIDInContext."
         (val :pointer)
         (kind-id :unsigned-int)
         (node :pointer))

(defcfun ("LLVMGetMDKindIDInContext" llvm-md-kind-id-in-context) :unsigned-int
         "Gets or creates a metadata kind ID for the given name."
         (context :pointer)
         (name :string)
         (slen :unsigned-int))

(defcfun ("LLVMMDStringInContext2" llvm-md-string-in-context2) :pointer
         "Creates a metadata string in the given context."
         (context :pointer)
         (str :string)
         (slen :unsigned-int))

(defcfun ("LLVMAddModuleFlag" llvm-add-module-flag) :void
         (module :pointer)
         (behavior :int) ;; LLVMModFlagBehavior (1=Error, 2=Warning, 3=Require, 4=Override, 5=Append, 6=AppendUnique)
         (key :string)
         (key-len :size)
         (val :pointer))

(defcfun ("LLVMMetadataAsValue" llvm-metadata-as-value) :pointer
         (context :pointer)
         (md :pointer))



;;;  device vector support
(defcfun ("LLVMVectorType" llvm-vector-type) :pointer
  "Create a fixed-length vector type wrapping ELEMENT-TYPE with ELEMENT-COUNT lanes."
  (element-type :pointer)
  (element-count :unsigned-int))

(defcfun ("LLVMBuildInsertElement" llvm-build-insert-element) :pointer
  "Insert ELT-VAL into VEC-VAL at position INDEX (an i32 LLVM value).
   Returns the updated vector value."
  (builder    :pointer)
  (vec-val    :pointer)
  (elt-val    :pointer)
  (index      :pointer)   ; must be an i32 LLVM value, e.g. (llvm-const-int (llvm-int32-type) N nil)
  (name       :string))


(defcfun ("LLVMBuildExtractElement" llvm-build-extract-element) :pointer
  "Extract the scalar element at position INDEX (an i32 LLVM value) from
   the LLVM vector value VEC-VAL, producing a scalar result."
  (builder  :pointer)
  (vec-val  :pointer)
  (index    :pointer)   ; must be an i32 LLVM value, e.g. (llvm-const-int (llvm-int32-type) N nil)
  (name     :string))


;;; Array type support for (array T N)
(defcfun ("LLVMArrayType" llvm-array-type) :pointer
  "Create a fixed-size array type with COUNT elements of ELEMENT-TYPE.
   Corresponds to LLVM's [COUNT x ELEMENT-TYPE]."
  (element-type :pointer)
  (count :unsigned-int))



(defcfun ("LLVMGetFirstFunction" llvm-get-first-function) :pointer
  "Returns the first function in a module, or NULL if none."
  (module :pointer))

(defcfun ("LLVMGetNextFunction" llvm-get-next-function) :pointer
  "Returns the next function after FN in the module, or NULL at end."
  (fn :pointer))

(defcfun ("LLVMGlobalGetValueType" llvm-global-get-value-type) :pointer
  "Returns the value type of a global (for a function: its function type,
   not a pointer-to-function type). Works correctly with opaque pointers."
  (global :pointer))

(defcfun ("LLVMGetReturnType" llvm-get-return-type) :pointer
  "Returns the return type of a function type."
  (function-ty :pointer))

(defcfun ("LLVMGetFirstUse" llvm-get-first-use) :pointer
  "Returns the first use of VAL, or a null pointer if VAL has no uses.
   Use cffi:null-pointer-p on the result to test for 'no uses'."
  (val :pointer))

(defcfun ("LLVMGetValueName" llvm-get-value-name) :string
  "Returns the name of a value (e.g. a function name). Empty string if unnamed."
  (val :pointer))

(defun llvm-type-kind-is-array? (ty)
  "Returns T if TY is an LLVM array type ([N x T])."
  (= (llvm-get-type-kind ty) +llvm-array-type-kind+))


(defcfun ("LLVMGetIntTypeWidth" llvm-get-int-type-width) :unsigned-int
  "Returns the bit-width of an LLVM integer type (e.g. 32 for i32, 64 for i64)."
  (int-ty :pointer))


;; LLVMBuildAtomicRMW: emit an atomic read-modify-write instruction.
;; op is LLVMAtomicRMWBinOp enum (int): xchg=0 add=1 sub=2 max=7 min=8 fadd=11 etc.
;; ordering is LLVMAtomicOrdering enum (int): seq_cst=7
;; single-thread: 0 for multi-threaded (GPU), 1 for single-threaded.
(defcfun ("LLVMBuildAtomicRMW" llvm-build-atomic-rmw) :pointer
  (builder     :pointer)
  (op          :int)
  (ptr         :pointer)
  (val         :pointer)
  (ordering    :int)
  (single-thread :int))


;;; IGC SROA-aliasing workaround (endeavor 103 phase B, 2026-05-16).
;;; Needed by the var-read codegen overlay to mark adjoint-scalar loads
;;; `volatile`, inhibiting the SROA-promotion miscompilation observed on
;;; Intel Arc / IGC.  See put_temp_files_here/igc-bug-report/ for the
;;; minimal reproducer and bug report.
(cffi:defcfun ("LLVMSetVolatile" llvm-set-volatile) :void
  (memory-access-inst :pointer)
  (is-volatile :int))



(defcfun ("LLVMSetInstructionCallConv" llvm-set-instruction-call-conv) :void
         "Sets the calling convention on a CALL/INVOKE instruction.
          Common values: 0=C, 75=spir_func (LLVM 21), 76=spir_kernel."
         (inst :pointer)
         (cc :unsigned-int))

(defcfun ("LLVMGetInstructionCallConv" llvm-get-instruction-call-conv) :unsigned-int
         "Reads the calling convention from a CALL/INVOKE instruction."
         (inst :pointer))



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


;; --- Precision controls (Endeavor 126): fast-math flags + FP attributes ---
;; Confirmed present in LLVM-C.dll (LLVM 21) on 2026-07-01.

;; LLVMFastMathFlags is an unsigned bitmask. Values per llvm-c/Core.h:
(defconstant +llvm-attribute-function-index+ #xFFFFFFFF
  "LLVMAttributeFunctionIndex (~0u): attribute index for function-level attributes.")
(defconstant +llvm-fast-math-none+            0)
(defconstant +llvm-fast-math-allow-reassoc+   1)
(defconstant +llvm-fast-math-no-nans+         2)
(defconstant +llvm-fast-math-no-infs+         4)
(defconstant +llvm-fast-math-no-signed-zeros+ 8)
(defconstant +llvm-fast-math-allow-reciprocal+ 16)
(defconstant +llvm-fast-math-allow-contract+  32)
(defconstant +llvm-fast-math-approx-func+     64)
(defconstant +llvm-fast-math-all+             #x7F)

;; Per-instruction fast-math flags. Endeavor 126: this per-instruction path is the
;; ONLY one the LLVM->SPIR-V translator honors — function-level fast-math attributes
;; do NOT reach SPIR-V FPFastMathMode (verified 2026-07-01). So the `fast` precision
;; key is realized by setting these flags on every FP-math op in scope.
(defcfun ("LLVMSetFastMathFlags" llvm-set-fast-math-flags) :void
  "Set the fast-math flags (unsigned LLVMFastMathFlags bitmask) on an FP-math value."
  (fp-math-inst :pointer)
  (fmf :unsigned-int))

(defcfun ("LLVMGetFastMathFlags" llvm-get-fast-math-flags) :unsigned-int
  "Get the fast-math flags (LLVMFastMathFlags bitmask) of an FP-math value."
  (fp-math-inst :pointer))

(defcfun ("LLVMCanValueUseFastMathFlags" llvm-can-value-use-fast-math-flags) :int
  "Non-zero if VALUE is an FP-math instruction that can carry fast-math flags."
  (value :pointer))

;; String function attributes. Endeavor 126: used to stamp `denormal-fp-math`
;; (=`preserve-sign,preserve-sign` for flush, `ieee,ieee` for preserve) on kernels
;; for the denormal axis. PTX honors it directly; SPIR-V needs !spirv.ExecutionMode
;; metadata instead (deferred to pass 3).
(defcfun ("LLVMCreateStringAttribute" llvm-create-string-attribute) :pointer
  "Create a string attribute (K=V) in CONTEXT. Returns an LLVMAttributeRef."
  (context :pointer)
  (k :string)
  (k-length :unsigned-int)
  (v :string)
  (v-length :unsigned-int))

(defcfun ("LLVMAddAttributeAtIndex" llvm-add-attribute-at-index) :void
  "Add ATTR to function F at attribute index IDX (use
   +llvm-attribute-function-index+ for function-level attributes)."
  (f :pointer)
  (idx :unsigned-int)
  (attr :pointer))

(defcfun ("LLVMAddNamedMetadataOperand" llvm-add-named-metadata-operand) :void
  "Append VAL (a metadata-as-value) to the module M's named metadata NAME.
   Endeavor 126: used to add !spirv.ExecutionMode entries (DenormFlushToZero /
   DenormPreserve) so denormal handling reaches SPIR-V."
  (m :pointer)
  (name :string)
  (val :pointer))


;;; ===================================================================
;;; In-process optimizer (2026-07-06) — new-pass-manager + target-machine
;;; C API, so the compile pipeline can run `default<O3>` via the already-
;;; loaded libLLVM instead of shelling out to an `opt` binary (which isn't
;;; present on the Windows dev box).  Probed present in the shipped
;;; LLVM-C.dll (Windows) incl. a working NVPTX TargetMachine.
;;; FROM: src/llvm-bindings.lisp
;;; ===================================================================

(defcfun ("LLVMContextCreate" llvm-context-create) :pointer
  "Create a fresh LLVM context (for parsing a standalone .ll to optimize).")

(defcfun ("LLVMContextDispose" llvm-context-dispose) :void
  (context :pointer))

(defcfun ("LLVMCreatePassBuilderOptions" llvm-create-pass-builder-options) :pointer
  "Options object for LLVMRunPasses (new pass manager).")

(defcfun ("LLVMDisposePassBuilderOptions" llvm-dispose-pass-builder-options) :void
  (opts :pointer))

(defcfun ("LLVMRunPasses" llvm-run-passes) :pointer   ; LLVMErrorRef (NULL = success)
  "Run PASSES (e.g. \"default<O3>\") on MODULE using TM (may be NULL) and OPTS.
   Returns NULL on success, else an LLVMErrorRef."
  (module :pointer) (passes :string) (tm :pointer) (opts :pointer))

(defcfun ("LLVMGetErrorMessage" llvm-get-error-message) :string
  "Consume ERR and return its human-readable message."
  (err :pointer))

(defcfun ("LLVMGetTarget" llvm-get-target) :string
  "The target triple recorded in MODULE."
  (module :pointer))

(defcfun ("LLVMGetTargetFromTriple" llvm-get-target-from-triple) :int  ; 0 = success
  "Resolve TRIPLE to a registered LLVMTargetRef (written to OUT-TARGET); on
   failure writes an error string to OUT-ERR.  Returns 0 on success."
  (triple :string) (out-target :pointer) (out-err :pointer))

(defcfun ("LLVMCreateTargetMachine" llvm-create-target-machine) :pointer
  "Build a TargetMachine (for TTI/cost-model during opt)."
  (target :pointer) (triple :string) (cpu :string) (features :string)
  (opt-level :int) (reloc :int) (code-model :int))

(defcfun ("LLVMDisposeTargetMachine" llvm-dispose-target-machine) :void
  (tm :pointer))

(defcfun ("LLVMInitializeNVPTXTargetInfo" llvm-initialize-nvptx-target-info) :void)
(defcfun ("LLVMInitializeNVPTXTarget" llvm-initialize-nvptx-target) :void)
(defcfun ("LLVMInitializeNVPTXTargetMC" llvm-initialize-nvptx-target-mc) :void)



(defcfun ("LLVMGetGlobalContext" llvm-get-global-context) :pointer
  "The global LLVM context (Crisp modules are created in it).")

(defcfun ("LLVMTargetExtTypeInContext" llvm-target-ext-type-in-context) :pointer
  "Build a target-extension type target(NAME, <type-params…>, <int-params…>).
   TYPE-PARAMS is a C array of LLVMTypeRef (count TYPE-PARAM-COUNT); INT-PARAMS is a
   C array of unsigned (count INT-PARAM-COUNT)."
  (ctx :pointer) (name :string)
  (type-params :pointer) (type-param-count :unsigned-int)
  (int-params :pointer) (int-param-count :unsigned-int))