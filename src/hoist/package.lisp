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
   #:metacrisp-hardware-profile

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
   #:generate-cpp-dvec-typedefs

   ;; Helpers shared by both hoisters (moved from hoist-l0 / hoist-cuda, 2026-10-16)
   #:*mma-test-dims*
   #:*mma-input-counter*
   #:*mma-scale*
   #:*hoist-current-structs*
   #:%mma-out-dir-p
   #:%array-type-p
   #:%array-element-type
   #:%array-size
   #:%struct-base-type
   #:record-base-type
   #:find-record-def
   #:record-type-p
   #:tensor-type-p
   #:%tensor-compact-extents-strides
   #:%dispatch-sym-to-cpp-var
   #:%find-struct-def
   #:struct-type-p
   #:%struct-emit-fields

   ;; Endeavour 190: --hoist-kernel=source, shared by both hoisters (source-mode.lisp)
   #:*hoist-kernel-source-mode*
   #:*hoist-kernel-sources*
   #:*hoist-kernel-flags*
   #:*hoist-current-kernel-name*
   #:*hoist-current-signature*
   #:*hoist-current-dispatch-info*
   #:%hk-extract-args
   #:%hk-c-string
   #:%hk-source-literal
   #:%hk-emit-embedded-sources
   #:%hk-param-roles
   #:%hk-slot-total
   #:%hk-check-argument-count
   #:%hk-emit-compile-and-slot-map
   #:%hk-strided-occupancy-p
   #:%hk-emit-launch-inputs
   #:%hk-emit-scratch-checks
   #:%hk-replace-all))
