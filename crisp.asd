(defsystem "crisp"
           :description "A Lisp-based compiler for GPGPU programming."
           :author "Chris Perkins cperkins.mobile@gmail.com"
           :license "MIT"
           :version "0.0.1"

           ;; --- Dependencies ---
           :depends-on (#:cffi
                        #:alexandria
                        #:log4cl
                        #:parachute
                        #:cl-ppcre)

           ;; --- File Definitions ---
           ;; load components in exactly this order
           :serial t
           :components ((:file "src/package") ; 1. Defines all packages
                                             (:file "src/llvm-bindings") ; 2. Uses one package, defines FFI
                                             (:file "src/utils")
                                             (:file "src/session") ;; NEW - Compiler Session
                                             (:file "src/struct-definitions")
                                             (:file "src/macros")
                                             (:file "src/mangling") ;; NEW
                                             (:file "src/semantic")
                                             (:file "src/errors") ; 3. Conditions
                                             (:file "src/types/definitions")
                                             (:file "src/types/registry")
                                             
                                             (:file "src/types/validation")
                                             (:file "src/types/hierarchy")
                                             (:file "src/parameters")
                                             (:file "src/types/brand")
                                             (:file "src/structs") ; 5. Struct Layout
                                             (:file "src/compiler") ; 6. Uses FFI, defines compiler
                                             (:file "src/enums")
                                             (:file "src/environment")
                                             (:file "src/type-checker")
                                             (:file "src/analysis/core")
                                             (:file "src/analysis/ops")
                                             (:file "src/analysis/control")
                                             (:file "src/analysis/structs")
                                             (:file "src/anf-transform")
                                             (:file "src/autodiff")
                                             (:file "src/codegen/abi")
                                             (:file "src/codegen") ; 7. Uses compiler, defines codegen
                                             (:file "src/templates") ; 8. with-template-type macro
                                             (:file "src/metadata") ; 9. Metadata generation
                                             (:file "src/metadata-val") ; 10. Metadata validators
                                             (:file "src/reader")
                                             (:file "src/main") ; 11. Uses compiler, defines main

                                             ;; overlays - when testings out new functions, we just
                                             ;;            amend them to the overlay for that package
                                             ;;            Common Lisp will redefine. 
                                             ;;            When the feature is done, they'll be incorporated 
                                             ;;            back to /src and the file cleared.
                                             (:file "overlays/crisp-llvm-bindings-overlay")
                                             (:file "overlays/crisp-compiler-overlay" :around-compile (lambda (thunk)
                                                                                                        (handler-bind ((warning #'muffle-warning))
                                                                                                          (funcall thunk))))
                                             (:file "overlays/crisp-language-overlay"))

           ;; --- Build Instructions ---
           ;; how to build "crisp-compile" exe from (asdf:make "crisp")

           ;; This is the operation that builds a program
           :build-operation "program-op"

           ;; This is the name of the file to create
           :build-pathname "bin/crisp-compile"

           ;; This is the Lisp function to run when the
           ;; executable is launched.
           :entry-point "crisp.main:main")