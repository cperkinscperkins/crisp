;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)


;; Global Compiler State
;; =====================

(defvar *function-table* (make-hash-table)
        "A hash table mapping function names (symbols) to a list of
  FUNCTION-SIGNATURE structs. This supports overloading.")

(defvar *single-pass-call-stack* nil
        "A list of function names currently in the compilation stack, used to
  detect recursion in single-pass mode.")

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

(defvar *current-compiling-function* nil)
(defvar *current-module* nil)
(defvar *current-builder* nil)
(defvar *current-di-builder* nil)
(defvar *current-di-compile-unit* nil)
(defvar *current-location-map* nil)
(defvar *allow-nested-def-function* nil)


;; Type System Globals
;; ===================

(defvar *crisp-types* (make-hash-table)
        "A hash table mapping type names (symbols) to CRISP-TYPE structs.")

(defvar *crisp-structs* (make-hash-table)
        "A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.")

(defstruct enumeration-def
  name
  members ; Alist of (keyword . integer)
)

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
              ;; Pointer
              (c-pointer ,(lambda () (llvm-pointer-type (llvm-int8-type) 0)) 8 :pointer))))
    (loop for (name llvm-fn size category) in types
          do (setf (gethash name *crisp-types*)
               (make-crisp-type :name name
                                :llvm-type-fn llvm-fn
                                :size size
                                :category category)))))

;; Template Helpers (Type System Level)
;; ====================================

(defun excluded-template-base-type-p (base-type)
  "Returns true if the base-type should be excluded from struct template processing.
   Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations."
  (member base-type '(function quote common-lisp:function common-lisp:quote)))

(defun mangle-template-struct-name (name params)
  "Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT"
  (log:debug "mangle-template-struct-name: name=~s (type=~a) params=~s" name (type-of name) params)
  (cl:unless name (return-from mangle-template-struct-name nil))
  (intern (format nil "~a_~{~a~^_~}" name params) (symbol-package name)))

;; Type Equivalence
;; ================

(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, handling template struct canonicalization."
  (log:debug "types-equivalent-p: ~s vs ~s" t1 t2)
  (cl:cond
    ((equal t1 t2) t)
    ;; Treat VOID and NIL as equivalent return types
    ((or (and (symbolp t1) (string-equal t1 "VOID") (null t2))
         (and (null t1) (symbolp t2) (string-equal t2 "VOID")))
     t)
    ;; Handle parameterized struct (POINT FLOAT) vs mangled name POINT_FLOAT equivalence
    ((and (consp t1) (symbolp t2))
     (cl:let ((base-type (first t1))
              (params (rest t1)))
       (if (and (symbolp base-type)
                (not (excluded-template-base-type-p base-type)))
           (progn
            ;; Trigger auto-instantiation if template exists
            (cl:when (gethash base-type *template-registry*)
              (cl:let ((instantiated-form
                        (funcall *template-instantiator-fn* base-type params
                          (lambda (form location)
                            (if (boundp '*current-module*)
                                (compile-toplevel-form form location
                                                       *current-module*
                                                       *current-builder*
                                                       *current-di-builder*
                                                       *current-di-compile-unit*
                                                       *current-location-map*)
                                (eval form))))))
                instantiated-form
                t))

            ;; Now check mangled name
            (cl:let ((mangled (mangle-template-struct-name base-type params)))
              (log:debug "types-equivalent-p: mangled=~s vs t2=~s" mangled t2)
              (log:debug "  packages: ~s vs ~s" (symbol-package mangled) (symbol-package t2))
              (cl:cond
                ((eq mangled t2) t)
                ;; Also check string equality as fallback for package issues
                ((string-equal (symbol-name mangled) (symbol-name t2))
                 (log:warn "types-equivalent-p: Matched by string, potential package mismatch: ~a vs ~a" mangled t2)
                 t)
                (t nil))))
           nil)))
    ((and (symbolp t1) (consp t2))
     (types-equivalent-p t2 t1))
    (t nil)))

(defun type-lists-equivalent-p (l1 l2)
  (and (= (length l1) (length l2))
       (every #'types-equivalent-p l1 l2)))

;; Predicates
;; ==========

(defun valid-basic-type-p (type-spec)
  "Checks if type-spec is a valid basic symbol type (built-in, struct, or function reference)."
  (cl:when (and (symbolp type-spec) (not (keywordp type-spec)))
    (cl:cond
      ((gethash type-spec *crisp-types*) t)
      ((gethash type-spec *crisp-structs*) t)
      ((gethash type-spec *function-table*) t)
      (t
       (log:debug "valid-basic-type-p CHECK FAILED for: ~s (pkg: ~a)" type-spec (package-name (symbol-package type-spec)))
       (log:debug "  Available types keys: ~a" (alexandria:hash-table-keys *crisp-types*))
       nil))))

(defun valid-function-type-p (type-spec)
  "Checks if type-spec is a valid function literal or descriptor."
  (or (and (consp type-spec) (eq (first type-spec) :function-literal)
           (= (length type-spec) 2) (symbolp (second type-spec)))
      (and (consp type-spec) (eq (first type-spec) :function-type))))

(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, etc)."
  (cl:when (consp type-spec)
    (cl:let ((base-type (first type-spec))
             (params (rest type-spec)))
      (cl:cond
        ((not (symbolp base-type)) nil) ;; Base type must be a symbol
        ((excluded-template-base-type-p base-type) nil)
        ((and (string-equal (symbol-name base-type) "CELL")
              (= (length params) 1)
              (gethash (first params) *crisp-types*))
         ;; Auto-instantiate CELL_<Type> struct if not present
         (cl:let ((mangled-name (mangle-template-struct-name base-type params)))
           (cl:unless (gethash mangled-name *crisp-structs*)
             (instantiate-cell-struct (first params)))
           t))
        ;; Generic Templated Structs: (POINT FLOAT) -> POINT_FLOAT
        ((symbolp base-type)
         (cl:let ((mangled-name (mangle-template-struct-name base-type params)))
           (or (gethash mangled-name *crisp-structs*)
               ;; Attempt Auto-Instantiation if it's a known template
               (cl:when (gethash base-type *template-registry*)
                 (log:info "Auto-instantiating struct template: ~a with params ~a" base-type params)
                 (if (and (boundp '*template-instantiator-fn*) *template-instantiator-fn*)
                     (progn
                      (funcall *template-instantiator-fn* base-type params
                        (lambda (form loc)
                          (declare (ignore loc))
                          (if (and (boundp '*current-module*) *current-module*)
                              (compile-toplevel-form form nil
                                                     *current-module*
                                                     *current-builder*
                                                     *current-di-builder*
                                                     *current-di-compile-unit*
                                                     *current-location-map*)
                              (eval form))))
                      (gethash mangled-name *crisp-structs*))
                     (progn (log:warn "Template instantiator not bound/found") nil))))))
        (t nil)))))

(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
   Handles simple types, parameterized types, and function literals/types."
  (or (valid-basic-type-p type-spec)
      (valid-function-type-p type-spec)
      (valid-parameterized-type-p type-spec)))


(defun type-equal-p (t1 t2)
  "Checks if two Crisp types are equivalent at compile-time."
  (cl:cond
    ((and (symbolp t1) (symbolp t2))
     (eq t1 t2)) ;; TODO: Handle aliases
    ((and (listp t1) (listp t2))
     (equal t1 t2))
    (t nil)))

;; LLVM Resolution
;; ===============

(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference."
  (cl:cond
    ;; Built-in Scalar
    ((and (symbolp type-spec) (gethash type-spec *crisp-types*))
     (funcall (crisp-type-llvm-type-fn (gethash type-spec *crisp-types*))))

    ;; Struct
    ((and (symbolp type-spec) (gethash type-spec *crisp-structs*))
     (ensure-struct-llvm-type type-spec))

    ;; Pointer / Cell (simple version)
    ((and (listp type-spec) (eq (first type-spec) 'cell))
     ;; For now, treats cell as generic pointer.
     ;; ideally this should match runtime struct layout
     (llvm-pointer-type (llvm-void-type) 0))

    (t (error "Cannot resolve type to LLVM: ~a" type-spec))))
