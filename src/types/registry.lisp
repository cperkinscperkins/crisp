;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/types/registry.lisp
(in-package :crisp.compiler)

;; Global Compiler State
;; =====================

(defvar *generic-functions* (make-hash-table :test 'equal)
        "Registry of generic function templates (functions with &optional or &key parameters) 
   that are instantiated lazily. Key: function name symbol. Value: generic-function-def struct.")

(defvar *function-table* (make-hash-table)
        "A hash table mapping function names (symbols) to a list of
  FUNCTION-SIGNATURE structs. This supports overloading.")


(defvar *call-graph* nil
        "A hash table representing the call graph of functions.
  Keys are caller function names, values are lists of callee names.")

(defvar *template-instantiator-fn* nil
        "Hook for template instantiation.
   Called as (funcall *template-instantiator-fn* name arg-types callback).
   The callback is (funcall callback form location).")

(defvar *template-registry* (make-hash-table)
        "Maps template names (symbols) to a LIST of template-data structs.
This supports overloading templates by arity or other factors.")

(defvar *instantiated-templates* (make-hash-table :test 'equal)
        "Tracks which specializations have already been generated.")

(defvar *side-channel-originators* '(make-scratch-cell)
        "A list of function names that trigger the implicit side-channel argument passing mechanism.")

(defvar *originator-functions* nil
        "A hash table containing the names of all functions that directly use a side-channel originator.")

(defvar *implicit-arg-map* (make-hash-table)
        "A hash table mapping function names to the implicit side-channel arguments they require.")

(defvar *runtime-checks-enabled* nil
        "If true, runtime assertions (r-t-assert) are compiled.")

;;; =========================================================
;;; Branded Types - Infrastructure
;;; =========================================================


(defvar *brand-definitions* (make-hash-table :test 'equal)
        "Maps (brand-name . struct-type) to brand-definition records.
   Populated when def-struct / def-record with brand declarations are processed.")

;; NEW struct to hold brand metadata (this is a CL struct, not a Crisp def-struct)
(cl:defstruct brand-definition
  "Stores the definition of a branded type declared inside a struct/record."
  (brand-name nil :type symbol) ; e.g., TOKEN-T
  (base-type nil :type symbol) ; e.g., ULONG
  (subst-mode nil :type symbol) ; :no, :equal, :descendant, :ancestor
  (enforce-mode :diff :type symbol) ; :always or :diff
  (owner-struct nil :type symbol)) ; e.g., SERVER

;;; =========================================================
;;; --differentiate flag support (branded types prerequisite)
;;; =========================================================

(defvar *differentiate-p* nil
        "If T, enable differentiation mode. Activates branded type enforcement
   for brands declared with :enforce :diff (the default).")

(defvar *lax-kernel-rules-p* nil
        "If T, bypass strict requirements on kernels (like forcing &out for differentiable kernels) in order to cleanly test legacy tests.")


;; (defvar *current-module* nil) -> Moved to session
(define-symbol-macro *current-module* (compiler-session-module *compiler-session*))
;; (defvar *current-builder* nil) -> Moved to session
(define-symbol-macro *current-builder* (compiler-session-builder *compiler-session*))
;; (defvar *current-di-builder* nil) -> Moved to session
(define-symbol-macro *current-di-builder* (compiler-session-di-builder *compiler-session*))
;; (defvar *current-di-compile-unit* nil) -> Moved to session
(define-symbol-macro *current-di-compile-unit* (compiler-session-di-compile-unit *compiler-session*))
;; (defvar *current-location-map* nil) -> Moved to session
(define-symbol-macro *current-location-map* (compiler-session-location-map *compiler-session*))


(defvar *compiled-kernels* nil "List of kernel names (symbols) compiled in the current session.")
(defvar *emit-metadata* nil "If T, generate .metacrisp file.")


;; Type System Globals
;; ===================

(defvar *target-backend* :generic
        "The active target backend for compilation. 
   Supported values: :generic, :cpu, :spirv, :ptx.")

(defvar *crisp-types* (make-hash-table)
        "A hash table mapping type names (symbols) to CRISP-TYPE structs.")

(defvar *crisp-structs* (make-hash-table)
        "A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.")

(defvar *crisp-type-aliases* (make-hash-table)
        "A hash table mapping alias symbols to their target type specifiers.")

(defvar *crisp-template-aliases* (make-hash-table)
        "A hash table mapping template alias names to (params . body-type-spec).")

;; Recursive / Multipass Support Globals
(defvar *defer-struct-validation* nil
        "If T, register-struct-definition will not error on unknown types but instead queue the definition.")

(defvar *pending-struct-definitions* nil
        "A list of (name members category) tuples that are waiting for types to be defined.")


(defvar *crisp-enums* (make-hash-table :test 'eq))

(defvar *expression-analyzers* (make-hash-table)
        "A dispatch table mapping operator symbols to their analyzer functions.")

(defmacro def-expression-analyzer (operator handler-fn)
  "A helper macro to register an operator's analyzer function."
  `(setf (gethash ',operator *expression-analyzers*) ',handler-fn))

;; Initialization
;; ==============

(defun initialize-crisp-types ()
  "Populates the *crisp-types* hash table with built-in scalar types."
  (clrhash *crisp-types*)
  (cl:let ((types
            `(;; Signed Integers
              (char ,#'llvm-int8-type 8 :signed-int)
              (short ,#'llvm-int16-type 16 :signed-int)
              (int ,(lambda () (llvm-int32-type)) 32 :signed-int)
              (long ,#'llvm-int64-type 64 :signed-int)
              ;; Unsigned Integers
              (uchar ,#'llvm-int8-type 8 :unsigned-int)
              (ushort ,#'llvm-int16-type 16 :unsigned-int)
              (uint ,(lambda () (llvm-int32-type)) 32 :unsigned-int)
              (ulong ,#'llvm-int64-type 64 :unsigned-int)
              ;; Floating Point
              (half ,#'llvm-half-type 16 :float)
              (bfloat16 ,#'llvm-bfloat-type 16 :float)
              (float ,#'llvm-float-type 32 :float)
              (double ,#'llvm-double-type 64 :float)
              ;; Void
              (void ,#'llvm-void-type 0 :void)
              (voidp ,(lambda () (llvm-pointer-type (llvm-int8-type) 0)) 64 :pointer)
              ;; Meta Types
              (type-spec ,#'llvm-void-type 0 :meta)
              ;; Pointer
              (c-pointer ,(lambda () (llvm-pointer-type (llvm-int8-type) 0)) 8 :pointer))))
    (loop for (name llvm-fn size category) in types
          do (setf (gethash name *crisp-types*)
               (make-crisp-type :name name
                                :llvm-type-fn llvm-fn
                                :size size
                                :category category)))))
