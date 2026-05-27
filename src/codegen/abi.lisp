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
  ;; Mangle list-form storage handle types FIRST
  (let ((canonical-spec (if (and (consp type-spec)
                                 (symbolp (first type-spec))
                                 (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
                            (progn
                             (log:debug "crisp-type-to-llvm-type: Mangling storage handle list form: ~s" type-spec)
                             (mangle-template-struct-name (first type-spec) (rest type-spec)))
                            type-spec)))
    (let ((result
           (cond
            ;; Function Types (Passed as opaque pointers)
            ((and (listp canonical-spec)
                  (or (eq (first canonical-spec) :function-type)
                      (eq (first canonical-spec) :function-literal)))
              (llvm-pointer-type (llvm-int8-type) 0))

            ;; Context-Aware Optimizations (Optional, but preserves existing behavior)
            ((eq canonical-spec 'int)
              (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
            ((eq canonical-spec 'long)
              (or *cached-int64-type* (llvm-int64-type-in-context (llvm-get-module-context module))))
            ((or (eq canonical-spec 'keyword) (eq canonical-spec 'symbol))
              (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
            ((eq canonical-spec 'voidp)
              (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module)) 0))

            ;; Delegate everything else to the central type resolver
            (t
              (resolve-type-to-llvm canonical-spec)))))
      ;; Defensive check
      (when (or (null result) (cffi:null-pointer-p result))
            (error "Failed to resolve LLVM type for type-spec: ~s (canonical: ~s)" type-spec canonical-spec))
      result)))

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

(defun %record-base-from-list-form (type-spec)
  "If TYPE-SPEC is a non-storage list form like (V-POINT :EARNESTNESS 3.0),
   returns the base symbol V-POINT if it resolves to a user record type.
   Otherwise returns NIL.  Plain symbols and storage list forms return NIL."
  (when (and (consp type-spec)
             (symbolp (first type-spec))
             ;; Not a storage handle list form
             (not (member (symbol-name (first type-spec))
                          '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                          :test #'string-equal)))
    (let* ((base (first type-spec))
           (type-rec (or (gethash base *crisp-types*)
                         (let ((alt (intern (symbol-name base) (find-package :crisp-language))))
                           (gethash alt *crisp-types*)))))
      (when (and type-rec (eq (crisp-type-category type-rec) :record))
        base))))




;;;; ============================================================
;;;; def-record SROA for (array T N) fields at kernel boundary.
;;;; An array field in a record must be exploded to N individual
;;;; scalar parameters rather than passed as a bare [N x T] type
;;;; (which is invalid at an OpenCL/SPIR-V kernel entry point).
;;;; ============================================================

;; src/codegen/abi.lisp
(defun get-expanded-types (type-spec module)
  "Returns a list of LLVM types for a given Crisp type spec.
   For cell/storage, returns exploded ptr+i64 types. For records, explodes recursively.
   For (array T N), explodes to N copies of T's expanded types (SROA for record fields).
   For others, returns (type).
   If *target-backend* is :spirv or :ptx, upgrades pointers to Global Address Space (1)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (is-storage-list (and (consp type-spec)
                               (symbolp (first type-spec))
                               (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                       :test #'string-equal)))
         (lookup-spec (cond
                        (record-base record-base)
                        (is-storage-list
                         (let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
                           mangled))
                        (t type-spec)))
         (ignored (ignore-errors (resolve-type-to-llvm lookup-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when (and record-base (symbolp lookup-spec))
                         (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt *crisp-types*)))
                       (when (and is-storage-list (symbolp lookup-spec))
                         (let ((alt-symbol (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt-symbol *crisp-types*)))))
         (struct-def (lookup-struct-definition lookup-spec))
         (actual-key (cond
                       ((gethash lookup-spec *crisp-types*) lookup-spec)
                       ((and (or record-base is-storage-list) (symbolp lookup-spec))
                        (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                          (if (gethash alt *crisp-types*) alt lookup-spec)))
                       (t lookup-spec)))
         (expanded
          (progn
            (log:debug "GET-EXPANDED-TYPES: type-spec=~s lookup=~s found-type=~a found-struct=~a category=~a"
                       type-spec actual-key
                       (if type-rec "YES" "NO")
                       (if struct-def "YES" "NO")
                       (when type-rec (crisp-type-category type-rec)))
            (cond
              ;; Case 1: Record Type -> Explode recursively
              ((and type-rec (eq (crisp-type-category type-rec) :record))
               (when struct-def
                 (let* ((members (crisp-struct-definition-members struct-def))
                        (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members)))
                   (mapcan (lambda (m) (get-expanded-types (second m) module)) runtime-members))))
              ;; Case 1.5: (array T N) field — explode to N individual T values (SROA)
              ((%array-type-p lookup-spec)
               (let* ((elem-type (second lookup-spec))
                      (count-raw (third lookup-spec))
                      (count (etypecase count-raw
                               (integer count-raw)
                               (symbol (parse-integer (symbol-name count-raw))))))
                 (log:info "get-expanded-types: SROA array ~a -> ~a x ~a" lookup-spec count elem-type)
                 (loop repeat count append (get-expanded-types elem-type module))))
              ;; Case 2: Standard Type (Struct/Scalar) -> Return as is
              (t (list (crisp-type-to-llvm-type actual-key module)))))))

    (if (and (or (eq *target-backend* :spirv) (eq *target-backend* :ptx))
             (is-global-storage-handle-p type-spec))
        (mapcar (lambda (ty)
                  (if (llvm-type-kind-is-pointer? ty)
                      (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module))
                                         (encode-address-space :global))
                      ty))
                expanded)
        expanded)))

(defun explode-value (builder agg-val type-spec)
  "Extracts components from an aggregate value if necessary. Returns a list of LLVM values.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).
   For (array T N) fields: extracts N individual element values (SROA)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (values '()))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (extracted (llvm-build-extract-value builder agg-val i (format nil "~a_val" (first m)))))
                    (setf values (append values (explode-value builder extracted member-type)))))
         values))
      ;; (array T N): extract each element individually (SROA for record fields)
      ((%array-type-p lookup-spec)
       (let* ((count-raw (third lookup-spec))
              (count (etypecase count-raw
                       (integer count-raw)
                       (symbol (parse-integer (symbol-name count-raw))))))
         (loop for i from 0 below count
               collect (llvm-build-extract-value builder agg-val i (format nil "arr_elem_~a" i)))))
      (t (list agg-val)))))

(defun implode-value (builder components type-spec module)
  "Combines components into an aggregate value if necessary. Returns a single LLVM value.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).
   For (array T N) fields: assembles N scalar components into an array value (SROA)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (record-type (crisp-type-to-llvm-type lookup-spec module))
              (agg (llvm-get-undef record-type))
              (current-components components))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (member-val (implode-value builder current-components member-type module))
                         (consumed-count (length (get-expanded-types member-type module))))
                    (setf agg (llvm-build-insert-value builder agg member-val i (format nil "~a_ins" (first m))))
                    (setf current-components (subseq current-components consumed-count))))
         agg))
      ;; (array T N): assemble N scalar components back into an array value (SROA)
      ((%array-type-p lookup-spec)
       (let* ((elem-type (second lookup-spec))
              (count-raw (third lookup-spec))
              (count (etypecase count-raw
                       (integer count-raw)
                       (symbol (parse-integer (symbol-name count-raw)))))
              (arr-llvm-type (crisp-type-to-llvm-type lookup-spec module))
              (result (llvm-get-undef arr-llvm-type))
              (current-components components))
         (loop for i from 0 below count
               do (let* ((elem-val (implode-value builder current-components elem-type module))
                         (consumed (length (get-expanded-types elem-type module))))
                    (setf result (llvm-build-insert-value builder result elem-val i
                                                         (format nil "arr_build_~a" i)))
                    (setf current-components (subseq current-components consumed))))
         result))
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



(defun create-llvm-function-type (module return-types param-nodes &optional is-entry-point fn-name)
  "Calculates the LLVM function type, handling parameter explosion.
   When IS-ENTRY-POINT is non-NIL and *TARGET-BACKEND* is :PTX, demotes
   shared (addrspace 3) and local (addrspace 5) pointer params to i64
   so the resulting kernel image will be accepted by the CUDA driver
   (see header comment in this overlay).  After demotion, runs the
   PTX-entry verifier as a belt-and-suspenders check.  FN-NAME is used
   only in the verifier's error message."
  (let* ((return-type (get-llvm-return-type module return-types))
         (expanded-param-types
          (mapcan (lambda (p)
                    (let ((type-spec (semantic-param-type p))
                          (expanded (get-expanded-types (semantic-param-type p) module)))
                      (log:debug "PARAM: ~a TYPE: ~a EXPANDED-COUNT: ~a"
                                 (semantic-param-name p)
                                 type-spec
                                 (length expanded))
                      expanded))
                  param-nodes))
         (expanded-param-types
          (if (and (eq *target-backend* :ptx) is-entry-point)
              (mapcar #'%ptx-entry-demote-type expanded-param-types)
              expanded-param-types)))
    (when (and (eq *target-backend* :ptx) is-entry-point)
      (%verify-ptx-entry-expanded-types expanded-param-types
                                        (or fn-name "<unknown>")))
    (let* ((param-count (length expanded-param-types))
           (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
      (loop for i from 0
            for type in expanded-param-types
            do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))
      (llvm-function-type return-type param-types-array param-count nil))))
