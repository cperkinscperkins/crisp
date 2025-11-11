(defsystem "crisp"
  :description "A Lisp-based compiler for GPGPU programming."
  :author "cperkinscperkins"
  :license "MIT"
  :version "0.0.1"

  ;; --- Dependencies ---
  :depends-on ("cffi")

  ;; --- File Definitions ---
  ;; load components in exactly this order
  :serial t
  :components (;(:file "src/llvm-bindings") ; (From Target #3.5)
               ;(:file "src/compiler")      ; (Future semantic analysis)
               ;(:file "src/codegen")       ; (Future LLVM IR generator)
               (:file "src/main"))         ; ("hello world" main function)

  ;; --- Build Instructions ---
  ;; how to build "crisp-compile" exe from (asdf:make "crisp")

  ;; This is the operation that builds a program
  :build-operation "program-op"
  
  ;; This is the name of the file to create
  :build-pathname "bin/crisp-compile"
  
  ;; This is the Lisp function to run when the
  ;; executable is launched.
  :entry-point "crisp.main:main")