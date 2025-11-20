;; src/package.lisp


;;; ---
;;; Package Architecture Note
;;;
;;; This file defines all packages for the Crisp system. The package
;;; definitions are ordered carefully to resolve dependencies.
;;;
;;; The most complex interaction is between `:crisp.compiler` and
;;; `:crisp-language`. The goal is to create a "protected" user
;;; environment (`:crisp-language`) while the compiler implementation
;;; lives in its own package (`:crisp.compiler`).
;;;
;;; 1. :crisp.compiler
;;;    - This is the "implementation" package.
;;;    - It contains all internal logic (analyzers, codegen, etc.).
;;;    - It is the *source of truth* for core language symbols.
;;;      It defines and EXPORTS symbols like `def-function`, `declare`,
;;;      `return-type`, and `int`.
;;;
;;; 2. :crisp-language
;;;    - This is the "user sandbox" package.
;;;    - It `(:use)`s *nothing* from Common Lisp.
;;;    - It SHADOWING-IMPORTs "safe" CL symbols (+, if, defmacro).
;;;    - It IMPORTs the core language symbols (`def-function`, `declare`, etc.)
;;;      *from* `:crisp.compiler`.
;;;
;;; This design breaks the circular dependency we had before.
;;;
;;; --- The Compilation Flow ---
;;; 1. `crisp.main` binds `*package*` to the `:crisp-language` package.
;;; 2. We read the user's .crisp file. All symbols (like `def-function`)
;;;    are read into the `:crisp-language` package.
;;; 3. The compiler's internal functions (in `:crisp.compiler`) can now
;;;    use direct `(eq ...)` checks, because the symbols they check
;;;    against (e.g., `'declare`) are the *exact same symbols* that
;;;    `:crisp-language` imported.
;;;
;;; This ensures that `crisp-language::declare` is `eq` to
;;; `crisp.compiler::declare`, solving all our package-mismatch errors.
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
   ;; Types
   #:llvm-void-type
   #:llvm-int8-type
   #:llvm-int16-type
   #:llvm-int32-type
   #:llvm-int64-type
   #:llvm-half-type
   #:llvm-bfloat-type
   #:llvm-float-type
   #:llvm-double-type
   #:llvm-function-type
   ;; Functions
   #:llvm-add-function
   #:llvm-get-named-function
   #:llvm-get-insert-block
   #:llvm-get-basic-block-parent
   ;; Basic Blocks
   #:llvm-append-basic-block
   ;; Builder
   #:llvm-create-builder
   #:llvm-position-builder-at-end
   #:llvm-dispose-builder
   #:llvm-build-call2
   ;; Instructions
   #:llvm-const-int
   #:llvm-build-ret
   ;; Alloca
   #:llvm-get-param
   #:llvm-build-alloca
   #:llvm-build-store
   #:llvm-build-load2
   #:llvm-build-add
   #:llvm-build-fadd
   ;; Casting
   #:llvm-build-sext
   #:llvm-build-zext
   #:llvm-build-fp-ext
   #:llvm-build-si-to-fp
   #:llvm-build-ui-to-fp
   #:llvm-build-fp-to-si
   #:llvm-build-fp-to-ui
   #:llvm-build-trunc
   #:llvm-build-bit-cast
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
   #:llvm-builder-set-debug-location))

(defpackage :crisp.compiler
  (:use :cl :cffi :crisp.llvm-bindings)

  ;; Shadow all symbols that conflict with the COMMON-LISP package.
  ;; This ensures that when we use 'char', we mean 'crisp.compiler::char',
  ;; not 'cl:char'.
  (:shadow #:char
           #:short
           #:float
           #:double
           #:truncate
           #:floor
           #:ceil
           #:round)



  (:export #:test-llvm-hello-world
           #:def-function
           #:compile-toplevel-form
           #:compile-module
           #:generate-location-map
           #:initialize-crisp-types
           #:initialize-compiler
           #:initialize-expression-analyzers


           ;; laungage symbols
           #:declare
           #:return-type
           #:type
           "|=>|"
           ;; All Crisp types
           #:char #:short #:int #:long
           #:uchar #:ushort #:uint #:ulong
           #:half #:bfloat16 #:float #:double

           ;; All cast/conversion operators
           #:to-char #:as-char
           #:to-short #:as-short
           #:to-int #:as-int
           #:to-long #:as-long
           #:to-float #:as-float
           #:to-double #:as-double
           #:truncate #:floor #:ceil #:round


           ;; error conditions
           #:crisp-compiler-error
           #:crisp-unexpected-eof-error
           #:crisp-type-error
           #:error-source-location
           #:type-error-expected
           #:type-error-inferred
           #:crisp-unknown-variable
           #:unknown-variable-name))

(defpackage :crisp.main
  (:use :cl)

  (:export :main))


(defpackage :crisp-language
  (:use) ;; <--- THIS IS KEY. It means "use nothing from Common Lisp."

  (:import-from :crisp.compiler
   #:def-function
   #:declare
   #:return-type
   #:type
   "|=>|"
   ;; All Crisp types
   #:char #:short #:int #:long
   #:uchar #:ushort #:uint #:ulong
   #:half #:bfloat16 #:float #:double

   ;; All cast/conversion operators
   #:to-char #:as-char
   #:to-short #:as-short
   #:to-int #:as-int
   #:to-long #:as-long
   #:to-float #:as-float
   #:to-double #:as-double
   #:truncate #:floor #:ceil #:round)

  ;; --- 1. Import *only* the "safe" CL data symbols ---
  (:import-from :common-lisp
   #:t #:nil
   #:&optional #:&key #:&rest
   #:lambda)

  ;; --- 2. Import *only* the "safe" CL forms ---
  ;; We must "shadow" (copy) them into our package
  ;; so the user can type (if ...) instead of (cl:if ...)
  (:shadowing-import-from :common-lisp
   #:if #:when #:unless #:cond #:case
   #:let #:let*
   #:progn
   #:+ #:- #:* #:/ #:= #:/= #:< #:> #:<= #:>=
   #:equal ;; and so on...
   #:defmacro  ;; We need defmacro to build the language
   ) 

  ;; --- 3. Export *all* of our Crisp primitives ---
  (:export
   ;; Our new "safe" built-ins
   #:if #:when #:unless #:cond #:case
   #:let #:let*
   #:progn
   #:+ #:- #:* #:/ #:= #:/= #:< #:> #:<= #:>=
   #:equal 
   #:defmacro  

   ;; Our custom laungage symbols
   #:def-kernel #:def-function #:def-grid-function
   #:def-orchestration #:def-qint #:def-microfloat-block
   #:def-type-alias #:def-struct
   #:declare
   #:return-type #:type
   ;; All Crisp types
   #:char #:short #:int #:long
   #:uchar #:ushort #:uint #:ulong
   #:half #:bfloat16 #:float #:double

   ;; All cast/conversion operators
   #:to-char #:as-char
   #:to-short #:as-short
   #:to-int #:as-int
   #:to-long #:as-long
   #:to-float #:as-float
   #:to-double #:as-double
   #:truncate #:floor #:ceil #:round


   ;; Our looping constructs
   #:loop-vector-stride #:loop-soa-stride
   #:thread-stride #:workgroup-stride
   #:dotimes #:dotimes*

   ;; Our memory tools
   #:vector #:matrix #:tensor
   #:storage ;; (or whatever we call it)
   #:make-scratch-vector #:make-tile
   #:load-chunk #:store-chunk #:load-tile #:store-tile
   #:~ #:set! #:length~

   ;; Our new ops
   #:*! #:identity-of #:zero #:accum #:base
   
   ;; ...and every other function we add.
   ))