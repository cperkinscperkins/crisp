;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/package.lisp


;;; ---
;;; Package Architecture Note
;;;
;;; This file defines all packages for the Crisp system.
;;; 1. :crisp.compiler - Implementation source of truth.
;;; 2. :crisp-language - User sandbox.
;;; ---


(defpackage :crisp.llvm-bindings
  (:use :cl :cffi)
  (:export
   ;; Core Module and Context
   #:llvm-module-create
   #:llvm-print-module-to-string
   #:llvm-dispose-module
   #:llvm-dispose-message
   #:llvm-get-module-context
   #:llvm-type-of
   #:llvm-print-value-to-string
   ;; Types
   #:llvm-void-type
   #:llvm-int32-type-in-context #:llvm-int64-type-in-context
   #:llvm-int32-type #:llvm-int8-type #:llvm-int8-type-in-context #:llvm-int16-type #:llvm-int64-type #:llvm-int16-type
   #:llvm-type-kind-is-pointer?
   #:llvm-get-type-kind
   #:llvm-get-type-by-name
   #:llvm-print-type-to-string
   #:llvm-pointer-type
   #:llvm-get-pointer-address-space
   #:llvm-size-of
   #:llvm-half-type #:llvm-bfloat-type #:llvm-float-type #:llvm-double-type
   #:llvm-void-type
   #:llvm-function-type
   #:llvm-function-type
   #:llvm-struct-type-in-context
   #:llvm-struct-create-named
   #:llvm-struct-set-body
   #:llvm-get-type-by-name
   #:llvm-array-type


   ;; Functions
   #:llvm-add-function
   #:llvm-delete-function
   #:llvm-count-basic-blocks
   #:llvm-get-insert-block
   #:llvm-get-basic-block-parent
   #:llvm-get-named-function
   #:llvm-append-basic-block
   #:llvm-get-basic-block-terminator

   ;; Builder
   #:llvm-create-builder
   #:llvm-position-builder-at-end
   #:llvm-dispose-builder
   #:llvm-build-call2
   ;; Instructions
   #:llvm-const-int
   #:llvm-const-pointer-null
   #:llvm-const-null
   #:llvm-const-real
   #:llvm-build-ret
   ;; Alloca
   #:llvm-get-param
   #:llvm-build-alloca
   #:llvm-build-load #:llvm-build-load2 #:llvm-build-store #:llvm-build-gep2 #:llvm-build-struct-gep2 #:llvm-build-in-bounds-gep2
   #:llvm-build-extract-value #:llvm-build-insert-value #:llvm-build-insert-element #:llvm-build-extract-element #:llvm-get-undef
   #:llvm-vector-type
   #:llvm-build-ret-void
   #:llvm-build-add
   #:llvm-build-fadd
   #:llvm-build-sub
   #:llvm-build-fsub
   #:llvm-build-mul
   #:llvm-build-fmul
   #:llvm-build-sdiv
   #:llvm-build-fdiv
   #:llvm-build-icmp
   #:llvm-build-fcmp
   #:llvm-build-br
   #:llvm-build-cond-br
   #:llvm-build-phi
   #:llvm-add-incoming

   ;; Predicates
   #:+llvm-int-eq+ #:+llvm-int-ne+
   #:+llvm-int-ugt+ #:+llvm-int-uge+ #:+llvm-int-ult+ #:+llvm-int-ule+
   #:+llvm-int-sgt+ #:+llvm-int-sge+ #:+llvm-int-slt+ #:+llvm-int-sle+
   #:+llvm-real-oeq+ #:+llvm-real-ogt+ #:+llvm-real-oge+ #:+llvm-real-olt+
   #:+llvm-real-ole+ #:+llvm-real-one+

   #:llvm-build-struct-gep
   #:llvm-build-struct-gep2
   #:llvm-build-gep2
   #:llvm-build-gep
   #:llvm-build-in-bounds-gep2
   ;; Casting
   #:llvm-build-sext
   #:llvm-build-zext
   #:llvm-build-fp-ext
   #:llvm-build-si-to-fp
   #:llvm-build-ui-to-fp
   #:llvm-build-fp-to-si
   #:llvm-build-fp-to-ui
   #:llvm-build-trunc #:llvm-build-fp-trunc
   #:llvm-build-zext #:llvm-build-sext
   #:llvm-build-ptr-to-int
   #:llvm-build-int-to-ptr
   #:llvm-size-of
   #:llvm-build-int-to-ptr
   #:llvm-build-bit-cast
   #:llvm-build-addrspace-cast
   ;; DWARF Debug Info
   #:llvm-create-di-builder
   #:llvm-di-builder-finalize
   #:llvm-dispose-di-builder
   #:llvm-di-builder-create-compile-unit
   #:llvm-di-builder-create-file
   #:llvm-di-builder-create-function
   #:llvm-set-subprogram
   #:llvm-di-builder-create-debug-location
   #:llvm-instruction-set-debug-loc
   #:llvm-di-builder-create-basic-type
   #:llvm-di-builder-create-subroutine-type
   #:llvm-builder-set-debug-location
   ;; Calling Convention and Metadata (for SPIR-V kernels)
   #:llvm-set-target
   #:llvm-set-function-call-conv
   #:llvm-get-function-call-conv
   #:llvm-set-metadata
   #:llvm-md-kind-id-in-context
   #:llvm-md-string-in-context2
   #:llvm-value-as-metadata
   #:llvm-md-node-in-context2))

(defpackage :crisp.utils
  (:use :cl)
  (:export #:let-d
           #:dump-env
           #:advise-function
           #:initialize-advisements))

(defpackage :crisp.compiler
  (:use :cl :cffi :crisp.llvm-bindings
        :crisp.utils)

  ;; Shadow all symbols that conflict with the COMMON-LISP package.
  (:shadow #:char
           #:short
           #:float
           #:double
           #:truncate
           #:floor
           #:ceil
           #:round

           ;; We enable Unified Let by defining our own let macro
           #:let
           ;; We enable custom Branching by defining our own macros
           #:when #:unless #:cond
           ;; We handle RETURN specially
           #:return)

  (:export
   #:compile-toplevel-form
   #:compile-module
   #:generate-location-map
   #:initialize-crisp-types
   #:initialize-type-hierarchy
   #:is-substitutable-for?
   #:resolve-dominance
   #:get-type-base
   #:register-derived-type
   #:types-assignable-p ;; <--- NEW
   #:analyze-return-type-from-spec
   #:analyze-environment-from-spec
   #:parse-function-declarations
   #:analyze-return-type-from-list
   #:analyze-environment-from-list
   #:initialize-compiler
   #:initialize-expression-analyzers
   #:initialize-templates
   #:compile-crisp-form-to-ir-string
   #:compile-to-spirv
   #:compile-to-ptx
   #:validate-def-record-explosion
   #:validate-def-record-explosion-ir
   #:validate-scratch-cell-explosion
   #:validate-multiple-scratch-cells

   #:anf-transform ;; <--- NEW

   ;; laungage symbols
   #:def-function
   #:def-function
   #:def-kernel
   #:def-kernel-exact
   #:marshall-cell
   #:marshall-tensor
   #:%marshall-tensor
   #:marshall-vector
   #:marshall-matrix
   #:%make-ct-array
   #:def-type ;; <--- NEW
   #:with-template-type ;; <--- NEW

   ;; Structs
   #:register-struct-definition
   #:lookup-struct-definition
   #:parse-struct-member-spec
   #:make-crisp-struct-definition
   #:crisp-struct-definition-members

   ;; Enumerations
   #:def-enumeration
   #:address-space
   #:access
   #:align
   #:is-address-space?
   #:is-access?
   #:is-align?

   ;; Global Compiler State
   #:*types*
   #:*functions*
   #:*structs*
   #:*enums*
   #:*compiler-session* ;; <--- NEW
   #:*current-module*
   #:*current-builder*
   #:*compile-single-pass*
   #:*defer-struct-validation* ;; <--- NEW
   #:finalize-struct-definitions ;; <--- NEW

   #:def-struct
   #:def-record
   #:def-derived-type
   #:set-derived
   #:brand
   #:with-struct-accessors
   #:def-setter
   #:*crisp-structs*
   #:return
   #:declare
   #:return-type
   #:*target-backend* ;; <--- NEW

   ;; Built-in Types
   #:cell
   #:tensor
   #:storage
   #:type
   #:make-scratch-cell
   #:make-scratch-vector
   #:make-scratch-matrix
   #:make-scratch-tensor
   #:|=>| ;; Correct arrow

   ;; New Unified Let
   #:let

   ;; All Crisp types
   #:char #:short #:int #:long
   #:cell #:c-pointer #:storage #:voidp
   #:uchar #:ushort #:uint #:ulong
   #:half #:bfloat16 #:float #:double

   ;; Accessors
   #:address~ #:byte-size~ #:address-space~ #:access~
   #:parent~ #:offset~ #:element-type~
   #:bytes~ #:sizeof
   ;; Tensor accessors
   #:num-dims~ #:length~ #:strides~ #:extents~

   ;; All cast/conversion operators
   #:to-char #:as-char
   #:to-short #:as-short
   #:to-int #:as-int
   #:to-long #:as-long
   #:to-float #:as-float
   #:to-double #:as-double
   #:to-uchar #:as-uchar
   #:to-ushort #:as-ushort
   #:to-uint #:as-uint
   #:to-ulong #:as-ulong
   #:truncate #:floor #:ceil #:round

   ;; error conditions
   #:crisp-compiler-error
   #:crisp-unexpected-eof-error
   #:crisp-type-error
   #:crisp-unknown-type-error
   #:crisp-signature-arity-error
   #:error-source-location
   #:type-error-expected
   #:type-error-inferred
   #:crisp-unknown-variable
   #:unknown-variable-name
   #:crisp-illegal-access-error

   ;; Semantic Node types
   #:semantic-function #:semantic-return #:semantic-literal
   #:semantic-explicit-return
   #:semantic-param #:semantic-var-read #:semantic-add
   #:semantic-value-cast #:semantic-bitcast
   #:semantic-fp-truncate-cast #:semantic-call #:semantic-let
   #:semantic-extract-value #:semantic-progn

   ;; Accessors for semantic nodes
   #:semantic-function-body
   #:semantic-return-value-node
   #:function-signature-parameters ;; <--- NEW EXPORT
   #:semantic-let-bindings
   #:semantic-let-body

   #:set! #:~ #:~ref~

   #:to #:as

   ;; Developer Utilities
   #:compile-crisp-form-to-ir-string

   ;; Macros
   #:when #:unless #:cond #:if+ #:when+ #:unless+ #:else
   #:c-t-assert #:c-t-output #:compiler-no-op
   #:!= #:is-set?
   #:die #:r-t-assert #:r-t-assert-0))

(defpackage :crisp.main
  (:use :cl)

  (:export :main))


(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :crisp-language)
        (let ((sym (find-symbol "SET!" :crisp-language)))
          (when (and sym (not (eq (symbol-package sym) (find-package :crisp.compiler))))
                (unintern sym :crisp-language)))))

(defpackage :crisp-language
  (:use) ;; <--- THIS IS KEY. It means "use nothing from Common Lisp."

  ;; --- 1. Import from CRISP.COMPILER ---
  (:import-from :crisp.compiler
                #:def-function
                #:def-kernel
                #:def-kernel-exact
                #:marshall-cell
                #:marshall-tensor
                #:marshall-vector
                #:marshall-matrix
                #:%make-ct-array
                #:when #:unless #:if+ #:when+ #:unless+
                #:def-struct
                #:def-derived-type
                #:set-derived
                #:brand
                #:def-record
                #:with-struct-accessors
                #:def-setter
                #:return
                #:declare
                #:declare
                #:with-template-type
                #:def-type ;; <--- NEW
                #:return-type
                #:type
                #:make-scratch-cell
                #:make-scratch-vector
                #:make-scratch-matrix
                #:make-scratch-tensor
                #:def-enumeration
                #:address-space
                #:is-set?
                #:access
                #:align
                #:is-address-space?
                #:is-access?
                #:is-align?
                #:|=>|
                #:c-t-assert #:c-t-output

                ;; All Crisp types
                #:char #:short #:int #:long
                #:cell
                #:tensor
                #:storage #:c-pointer #:voidp
                #:uchar #:ushort #:uint #:ulong
                #:half #:bfloat16 #:float #:double

                ;; Accessors
                #:address~ #:byte-size~ #:address-space~ #:access~
                #:parent~ #:offset~ #:element-type~
                #:bytes~ #:sizeof
                ;; Tensor accessors
                #:num-dims~ #:length~ #:strides~ #:extents~

                ;; All cast/conversion operators
                #:to-char #:as-char
                #:to-short #:as-short
                #:to-int #:as-int
                #:to-long #:as-long
                #:to-float #:as-float
                #:to-double #:as-double
                #:to-uchar #:as-uchar
                #:to-ushort #:as-ushort
                #:to-uint #:as-uint
                #:to-ulong #:as-ulong
                #:truncate #:floor #:ceil #:round
                #:sin #:cos

                ;; NEW: Unified Let from Compiler
                #:let
                #:set! #:~ #:~ref~

                ;; Generic Casts
                #:to #:as

                ;; NEW: Branching Macros
                #:when #:unless #:cond #:if+ #:else
                #:!=
                #:die #:r-t-assert #:r-t-assert-0)

  ;; --- 2. Import *only* the "safe" CL data symbols ---
  (:import-from :common-lisp
                #:t #:nil
                #:&optional #:&key #:&rest #:&body
                #:lambda)

  ;; --- 3. Import *only* the "safe" CL forms ---
  ;; We must "shadow" (copy) them into our package
  (:shadowing-import-from :common-lisp
                          #:if #:case ;; We keep IF and CASE as CL symbols for now
                          ;; We do NOT import let/let* because we have our own
                          ;; We do NOT import when/unless/cond because we have our own
                          #:progn
                          #:funcall
                          #:+ #:- #:* #:/ #:= #:/= #:< #:> #:<= #:>= #:equal ;; and so on...
                          #:not #:and #:or
                          #:defmacro ;; We need defmacro to build the language
   )

  ;; --- 4. Macro Meta-Language Utilities ---
  (:shadowing-import-from :common-lisp
                          #:car #:cdr #:first #:rest
                          #:second #:third #:fourth #:fifth #:sixth #:seventh #:eighth #:ninth #:tenth
                          #:nth #:reverse #:append #:length
                          #:mapcar #:mapc)

  (:export
   ;; Export everything we imported
   #:def-function #:return #:declare #:return-type #:type
   #:char #:short #:int #:long #:float #:double #:half #:bfloat16
   #:cell
   #:uchar #:ushort #:uint #:ulong
   #:to-char #:to-short #:to-int #:to-long #:to-float #:to-double #:as-char #:as-short #:as-int #:as-long #:as-float #:as-double
   #:to-uchar #:to-ushort #:to-uint #:to-ulong #:as-uchar #:as-ushort #:as-uint #:as-ulong
   #:to #:as
   #:truncate #:floor #:ceil #:round
   #:sin #:cos

   #:if #:when #:unless #:cond #:case #:progn #:let #:funcall
   #:if+ #:else
   #:c-t-assert #:c-t-output
   #:die #:r-t-assert #:r-t-assert-0
   #:type-equal-p
   #:+ #:- #:* #:/ #:= #:!= #:< #:> #:<= #:>= #:equal

   #:defmacro

   #:car #:cdr #:first #:rest
   #:second #:third #:fourth #:fifth #:sixth #:seventh #:eighth #:ninth #:tenth
   #:nth #:reverse #:append #:length #:mapcar #:mapc
   #:gensym #:intern #:symbol-name #:string #:concatenate #:format
   #:null #:atom #:consp #:listp #:symbolp #:not #:and #:or

   #:setf ;; <--- NEW EXPORT

   ;; Our custom laungage symbols
   #:def-kernel #:def-kernel-exact #:def-function #:def-grid-function
   #:marshall-cell
   #:marshall-tensor
   #:marshall-vector
   #:marshall-matrix
   #:%make-ct-array
   #:def-orchestration #:def-qint #:def-microfloat-block
   #:def-type ;; <--- NEW
   #:with-template-type ;; <--- NEW

   #:def-type-alias #:def-struct #:def-derived-type #:def-record #:with-struct-accessors #:def-setter
   #:brand
   #:declare

   #:return-type #:type
   ;; All Crisp types
   #:char #:short #:int #:long
   #:cell
   #:uchar #:ushort #:uint #:ulong
   #:half #:bfloat16 #:float #:double

   ;; Loops
   #:loop-vector-stride #:loop-soa-stride
   #:thread-stride #:workgroup-stride
   #:dotimes #:dotimes*

   ;; Memory
   #:vector #:matrix #:tensor
   ;; Storage Handle
   #:make-scratch-cell
   #:make-scratch-vector
   #:make-scratch-matrix
   #:make-scratch-tensor
   #:cell #:voidp
   #:parent~ #:offset~ #:element-type~
   #:bytes~ #:sizeof
   ;; Tensor accessors
   #:num-dims~ #:length~ #:strides~ #:extents~

   ;; Enumerations
   #:def-enumeration
   #:address-space
   #:access
   #:align
   #:is-address-space?
   #:is-access?
   #:is-align?

   ;; Compiler/Codegen
   #:emit-llvm
   #:compile-function #:store-chunk #:load-tile #:store-tile
   #:~ #:set! #:length~ #:~ref~

   ;; Ops
   #:*! #:identity-of #:zero #:accum #:base))
