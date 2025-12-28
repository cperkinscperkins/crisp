(defsystem "crisp"
           :description "A Lisp-based compiler for GPGPU programming."
           :author "Chris Perkins cperkins.mobile@gmail.com"
           :license "MIT"
           :version "0.0.1"

           ;; --- Dependencies ---
           :depends-on (#:cffi
                        #:alexandria
                        #:log4cl
                        #:parachute)

           ;; --- File Definitions ---
           ;; load components in exactly this order
           :serial t
           :components ((:file "src/package") ; 1. Defines all packages
                                             (:file "src/llvm-bindings") ; 2. Uses one package, defines FFI
                                             (:file "src/utils")
                                             (:file "src/mangling") ;; NEW
                                             (:file "src/semantic")
                                             (:file "src/errors") ; 3. Conditions
                                             (:file "src/types") ; 4. Type System
                                             (:file "src/structs") ; 5. Struct Layout

                                             (:file "src/macros")
                                             (:file "src/compiler") ; 6. Uses FFI, defines compiler
                                             (:file "src/enums")
                                             (:file "src/environment")
                                             (:file "src/type-checker")
                                             (:file "src/analysis")
                                             (:file "src/codegen") ; 7. Uses compiler, defines codegen
                                             (:file "src/templates") ; 8. with-template-type macro
                                             (:file "src/main")) ; 9. Uses compiler, defines main

           ;; --- Build Instructions ---
           ;; how to build "crisp-compile" exe from (asdf:make "crisp")

           ;; This is the operation that builds a program
           :build-operation "program-op"

           ;; This is the name of the file to create
           :build-pathname "bin/crisp-compile"

           ;; This is the Lisp function to run when the
           ;; executable is launched.
           :entry-point "crisp.main:main")