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
                                             (:file "src/semantic")
                                             (:file "src/compiler") ; 3. Uses FFI, defines compiler
                                             (:file "src/codegen") ; 4. Uses compiler, defines codegen
                                             (:file "src/templates") ; 5. with-template-type macro
                                             (:file "src/main")) ; 6. Uses compiler, defines main

           ;; --- Build Instructions ---
           ;; how to build "crisp-compile" exe from (asdf:make "crisp")

           ;; This is the operation that builds a program
           :build-operation "program-op"

           ;; This is the name of the file to create
           :build-pathname "bin/crisp-compile"

           ;; This is the Lisp function to run when the
           ;; executable is launched.
           :entry-point "crisp.main:main")