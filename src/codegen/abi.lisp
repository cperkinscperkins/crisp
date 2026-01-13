;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/codegen/abi.lisp
(in-package :crisp.compiler)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CFFI Type Definitions for LLVM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(cffi:defctype llvm-type-ref :pointer)
(cffi:defctype llvm-value-ref :pointer)

(defparameter *cached-int32-type* nil)
(defparameter *cached-int64-type* nil)

(defun get-llvm-return-type (module return-type-names)
  "Determines the LLVM return type from a list of Crisp type names.
  Handles single values, void, and multiple values (by creating a struct)."
  (log:debug "get-llvm-return-type: ~s" return-type-names)
  (cond
   ;; Case 0: Void return (NIL or empty list)
   ((or (null return-type-names) (equal return-type-names '(nil)))
     (llvm-void-type))
   ;; Case 1: Multiple return values. Create a struct.
   ((> (length return-type-names) 1)
     (let* ((context (llvm-get-module-context module))
            (count (length return-type-names))
            (type-array (cffi:foreign-alloc 'llvm-type-ref :count count))
            (packed nil))
       (loop for i from 0 for type-name in return-type-names
             do (setf (cffi:mem-aref type-array 'llvm-type-ref i)
                  (crisp-type-to-llvm-type type-name module)))
       (prog1 (llvm-struct-type-in-context context type-array count packed)
         (cffi:foreign-free type-array))))
   ;; Case 2: Single return value.
   ((= (length return-type-names) 1) (crisp-type-to-llvm-type (first return-type-names) module))
   ;; Case 3: Should not happen, but treat as void.
   (t (llvm-void-type))))

(defun crisp-type-to-llvm-type (type-spec module)
  "Resolves a Crisp type specifier (simple or parameterized) to an LLVM type."
  (cond
   ;; Function Types (Passed as opaque pointers)
   ((and (listp type-spec)
         (or (eq (first type-spec) :function-type)
             (eq (first type-spec) :function-literal)))
     (llvm-pointer-type (llvm-int8-type) 0))

   ;; Context-Aware Optimizations (Optional, but preserves existing behavior)
   ((eq type-spec 'int)
     (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
   ((eq type-spec 'long)
     (or *cached-int64-type* (llvm-int64-type-in-context (llvm-get-module-context module))))
   ((or (eq type-spec 'keyword) (eq type-spec 'symbol))
     (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
   ((eq type-spec 'voidp)
     (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module)) 0))

   ;; Delegate everything else to the central type resolver
   (t
     (resolve-type-to-llvm type-spec))))

(defun is-global-storage-handle-p (type-spec)
  "Returns true if the type-spec represents a handle to global memory."
  (let* ((canon (canonicalize-type-specifier type-spec))
         (base (if (consp canon) (first canon) canon)))
    (and (symbolp base)
         (member (symbol-name base) '("CELL" "STORAGE" "VECTOR" "MATRIX") :test #'string-equal)
         ;; If it's a generic buffer type, assume global unless specified otherwise
         (or (not (consp canon))
             (member :global canon)
             (not (or (member :local canon) (member :private canon) (member :generic canon)))))))

(defun get-expanded-types (type-spec module)
  "Returns a list of LLVM types for a given Crisp type spec.
   For 'cell', returns (ptr i64). For 'storage', returns (ptr i64). For others, returns (type).
   
   If *target-backend* is :spirv or :ptx, upgrade pointers in storage handles to Global Address Space (1)."
  (let* ((expanded
          (let ((type-rec (gethash type-spec *crisp-types*)))
            (cond
             ;; Case 1: Record Type -> Explode recursively
             ((and type-rec (eq (crisp-type-category type-rec) :record))
               (let* ((struct-def (gethash type-spec *crisp-structs*))
                      (members (crisp-struct-definition-members struct-def))
                      ;; Filter out compile-time members (e.g. :c-t tagged)
                      (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members)))
                 (mapcan (lambda (m) (get-expanded-types (second m) module)) runtime-members)))

             ;; Case 2: Standard Type (Struct/Scalar) -> Return as is
             (t (list (crisp-type-to-llvm-type type-spec module)))))))

    ;; Post-Processing: Apply Address Spaces for GPU Backends
    (if (and (or (eq *target-backend* :spirv) (eq *target-backend* :ptx))
             (is-global-storage-handle-p type-spec))
        (mapcar (lambda (ty)
                  (if (llvm-type-kind-is-pointer? ty)
                      ;; Upgrade to Global Address Space
                      (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module)) (encode-address-space :global))
                      ty))
            expanded)
        expanded)))

(defun explode-value (builder agg-val type-spec)
  "Extracts components from an aggregate value if necessary.
   Returns a list of LLVM values."
  (let ((type-rec (gethash type-spec *crisp-types*)))
    (cond
     ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (gethash type-spec *crisp-structs*))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (values '()))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         ;; Extract the member from the aggregate
                         (extracted (llvm-build-extract-value builder agg-val i (format nil "~a_val" (first m)))))
                    ;; Recursively explode the member (in case it's a nested record)
                    (setf values (append values (explode-value builder extracted member-type)))))
         values))
     (t (list agg-val)))))

(defun implode-value (builder components type-spec module)
  "Combines components into an aggregate value if necessary.
   Returns a single LLVM value."
  (let ((type-rec (gethash type-spec *crisp-types*)))
    (cond
     ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (gethash type-spec *crisp-structs*))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (record-type (crisp-type-to-llvm-type type-spec module))
              (agg (llvm-get-undef record-type))
              (current-components components))

         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         ;; Implode the member first (consumes N components)
                         (member-val (implode-value builder current-components member-type module))
                         ;; Advance the component list by the number of components consumed
                         (consumed-count (length (get-expanded-types member-type module))))
                    ;; Insert the imploded member into the record
                    (setf agg (llvm-build-insert-value builder agg member-val i (format nil "~a_ins" (first m))))
                    (setf current-components (subseq current-components consumed-count))))
         agg))
     (t (first components)))))

(defun extract-primary-value (builder value type-spec)
  "If the type indicates an MVR (multiple return value) struct, extract the first element.
   Otherwise return the value as is.
   Used when a single-value context receives an MVR result."
  (log:info "EXTRACT-PRIMARY: value=~s type=~s listp=~s" value type-spec (listp type-spec))
  (if (and (listp type-spec)
           (not (valid-type-p type-spec))
           (> (length type-spec) 1))
      ;; It is a multi-value return type (e.g. from semantic-truncate: (int float))
      ;; The value is a struct { i32, float }
      ;; We extract index 0.
      (let ((extracted (llvm-build-extract-value builder value 0 "primary")))
        extracted)
      ;; It is a single value
      value))

(defun create-llvm-function-type (module return-types param-nodes)
  "Calculates the LLVM function type, handling parameter explosion."
  (let* ((return-type (get-llvm-return-type module return-types))
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types (semantic-param-type p) module)) param-nodes))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))
    (llvm-function-type return-type param-types-array param-count nil)))
