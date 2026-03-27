(in-package :cl-user)

(defpackage :crisp.hoist
  (:documentation "Common infrastructure for all Crisp hoisting tools")
  (:use :common-lisp)
  (:export
   ;; Metacrisp parsing
   #:parse-metacrisp-file
   #:metacrisp-kernels
   #:metacrisp-aliases
   #:metacrisp-structs
   #:metacrisp-records

   ;; Code generation base
   #:generate-preamble
   #:generate-typedefs
   #:generate-structs
   #:generate-main-scaffold

   ;; Utilities
   #:crisp-type-to-cpp-type
   #:format-cpp-identifier

   ;; Cell type helpers
   #:resolve-type-alias
   #:cell-type-p
   #:cell-base-type

   ;; Device vector type support
   #:%dvec-parse
   #:%dvec-cpp-scalar-type
   #:%emit-dvec-typedef
   #:%collect-dvec-types
   #:generate-cpp-dvec-typedefs))
