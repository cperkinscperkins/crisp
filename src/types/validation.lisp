;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/types/validation.lisp
(in-package :crisp.compiler)

;; Template Helpers (Type System Level)
;; ====================================

(defun excluded-template-base-type-p (base-type)
  "Returns true if the base-type should be excluded from struct template processing.
   Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations."
  (member base-type '(function quote common-lisp:function common-lisp:quote)))


;; Type Equivalence
;; ================

(defun resolve-type-alias (type-spec)
  "Fully resolves a type alias chain, returning the underlying type.
   Includes cycle detection to prevent infinite loops.
   SIGNALS ERROR if a cycle is detected."

  (if (and (symbolp type-spec)
           (boundp '*crisp-type-aliases*)
           (gethash type-spec *crisp-type-aliases*))
      ;; It's an alias - resolve with cycle detection
      (cl:let ((seen (make-hash-table :test 'eq)))
        (loop for name = type-spec then (gethash name *crisp-type-aliases*)
              while (and (symbolp name)
                         (gethash name *crisp-type-aliases*)
                         (not (gethash name seen)))
              do
                (setf (gethash name seen) t)
              finally
                (if (gethash name seen)
                    ;; CYCLE DETECTED - ABORT IMMEDIATELY
                    (error "Recursive type alias detected: Type alias '~a' refers to itself directly or indirectly." name)
                    (cl:return name))))
      ;; Not an alias - return as-is
      type-spec))


(defun expand-storage-handle-type-specifier (spec)
  "Expands legacy/shorthand storage handle specs (cell, vector, etc) into their canonical struct form.
   e.g. (cell int) -> (cell int :global :read-write)
   e.g. (cell int :address-space :local) -> (cell int :local :read-write)
   
   ROBUSTNESS FIX (Regression Analysis):
   - Explicitly extracts known keys (:address-space, :access) and IGNORES others (like :direction).
   - Normalizes address-space symbols (GLOBAL) to keywords (:GLOBAL) to prevent type errors.
   - Ensures output is always a clean positional list for template instantiation."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cl:cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (cl:let ((base (first spec)))
       (if (and (symbolp base) (member (symbol-name base) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (if (null (rest spec))
               ;; Disallow bare (cell)
               (error 'crisp-incomplete-type-error :type-spec spec)

               (cl:let* ((args (rest spec))
                         (element-type (first args))
                         (rest-args (rest args)))

                 (if (null rest-args)
                     ;; Case: (CELL INT) -> Defaults
                     (list base element-type :global :read-write)

                     ;; Robust Parsing Logic
                     (cl:let ((addr :global)
                              (acc :read-write)
                              (remaining rest-args))
                       (cl:loop while remaining do
                         (cl:let ((item (pop remaining)))
                           (cl:cond
                             ;; 1. Address Space Flags/Keywords
                             ((cl:member (string item) '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC") :test #'string-equal)
                              (setf addr (intern (string-upcase (string item)) :keyword)))

                             ;; 2. Access Flags/Keywords
                             ((cl:member (string item) '("READ-WRITE" "READ-ONLY" "WRITE-ONLY" "READABLE" "WRITEABLE") :test #'string-equal)
                              (setf acc (intern (string-upcase (string item)) :keyword)))

                             ;; 3. Explicit Keys
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (cl:unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (cl:unless remaining (error "Missing value for :ACCESS in ~s" spec))
                              (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))

                             ;; 4. Ignored Keys (Legacy compatibility if needed, strict otherwise)
                             ;; We MUST error on unknown keys to pass bad-type-constructor-02
                             (t
                              (error "Invalid type option: ~s in spec ~s" item spec)))))

                       ;; Return canonical positional form
                       (list base element-type addr acc)))))
           spec)))
    (t spec)))


;; Helper: Parse Template Param Spec
(defun parse-template-parameter-spec (param)
  "Parses (Name [Type] [Default]) -> (list Name Type Default)"
  (cl:if (consp param)
         (cl:case (length param)
           (1 (list (first param) 'T nil))
           (2 (list (first param) (second param) nil))
           (3 (list (first param) (second param) (third param)))
           (t (error "Invalid template parameter spec: ~a" param)))
         (list param 'T nil)))


;; 1. Permissive validate-template-arg
(defun validate-template-arg (arg type name)
  (cl:cond
    ((eq type 'T) t)
    ((typep arg type) t)
    ;; Permissive Fix: If arg is SYMBOL (but not keyword) and Type accepts the KEYWORD version
    ((cl:and (symbolp arg)
       (not (keywordp arg))
       (typep (intern (symbol-name arg) :keyword) type))
     t)
    (t (error "Template argument mismatch for ~a. Expected type ~a, got ~a (~a)"
         name type arg (type-of arg)))))

(defun canonicalize-type-specifier (spec)
  "Canonicalizes type specifiers."

  ;; DEBUG LOGGING
  ;; (when (symbolp spec) (format *error-output* "[canonicalize] Processing symbol: ~a~%" spec))

  ;; First, apply storage handle expansion
  (cl:when (consp spec)
    (setf spec (expand-storage-handle-type-specifier spec)))

  (cl:let ((base (if (consp spec) (cl:first spec) spec))
           (args (if (consp spec) (rest spec) nil)))
    (cl:cond
      ((symbolp base)
       ;; 1. Check Template Aliases (def-type)
       (cl:let ((alias-def (gethash base *crisp-template-aliases*)))
         (cl:if alias-def
                (cl:let ((params (car alias-def))
                         (type-spec (cdr alias-def)))
                  ;; Instantiate the alias
                  (cl:if params
                         (cl:let* ((arity (length params))
                                   (required-args (subseq args 0 (min (length args) arity)))
                                   (rest-args (subseq args (length required-args)))
                                   (substitutions (pairlis params required-args)))
                           ;; Apply substitution to the base spec
                           (cl:let ((expanded-base (sublis substitutions type-spec)))
                             ;; Append any extra args (overrides) to the result if it's a list
                             (cl:if (and rest-args (consp expanded-base))
                                    (canonicalize-type-specifier (append expanded-base rest-args))
                                    (canonicalize-type-specifier expanded-base))))
                         ;; No params? Just return the aliased type + args??
                         (cl:if args
                                (canonicalize-type-specifier (append (cl:if (consp type-spec) type-spec (list type-spec)) args))

                                ;; FIX: Use resolve-type-alias cycle detection here! 
                                (cl:let ((resolved (resolve-type-alias base)))
                                  (cl:if (equal resolved base)
                                         ;; Cycle detected (A->A), return base as canonical 
                                         (progn
                                          (log:warn "[canonicalize-type-specifier] Alias Cycle detected for ~a, returning base." base)
                                          (list base))
                                         ;; Recurse safely
                                         (canonicalize-type-specifier resolved))))))

                ;; 2. Standard Templates (With Validation)
                (cl:let* ((template-data (first (gethash base *template-registry*)))
                          (raw-params (and template-data (template-data-parameters template-data))))
                  (cl:if raw-params
                         (cl:let* ((parsed-params (mapcar #'parse-template-parameter-spec raw-params))
                                   (full-args (cl:loop for (p-name p-type p-default) in parsed-params
                                              for i from 0
                                              for arg = (if (< i (length args))
                                                            (nth i args)
                                                            (or p-default
                                                                (error "Missing required type argument for template ~a: ~a (index ~d)" base p-name i)))
                                              do (validate-template-arg arg p-type p-name)
                                              collect arg)))
                           (cons base full-args))

                         ;; Not a template, return as is (normalized to list)
                         (cl:if (consp spec) spec (list spec)))))))
      ((consp spec) spec)
      (t (list spec)))))


(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling."
  ;; Resolve aliases FIRST, then run all other checks on resolved types
  (cl:let ((t1 (resolve-type-alias t1))
           (t2 (resolve-type-alias t2)))
    (cl:cond
      ((or (equal t1 t2)
           (and (symbolp t1) (symbolp t2) (string-equal (symbol-name t1) (symbol-name t2))))
       t)
      ;; Treat VOID and NIL as equivalent return types
      ((or (and (symbolp t1) (string-equal t1 "VOID") (null t2))
           (and (null t1) (symbolp t2) (string-equal t2 "VOID")))
       t)
      ;; Handle parameterized struct (POINT FLOAT) vs mangled name POINT_FLOAT
      ((and (consp t1) (symbolp t2))
       (let* ((expanded (if (member (symbol-name (cl:first t1)) '("CELL") :test #'string-equal)
                            (canonicalize-type-specifier t1)
                            t1))
              (base-type (cl:first expanded))
              (params (rest expanded)))
         (if (and (symbolp base-type)
                  (not (excluded-template-base-type-p base-type)))
             (progn
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
              (cl:let ((mangled (mangle-template-struct-name base-type params)))
                (cl:cond
                  ((eq mangled t2) t)
                  ((string-equal (symbol-name mangled) (symbol-name t2)) t)
                  (t nil))))
             nil)))
      ((and (symbolp t1) (consp t2))
       (types-equivalent-p t2 t1))
      ;; Parameterized struct vs parameterized struct
      ((and (cl:consp t1) (cl:consp t2))
       (cl:let ((e1 (cl:if (cl:member (cl:symbol-name (cl:first t1)) '("CELL") :test #'cl:string-equal)
                           (canonicalize-type-specifier t1)
                           t1))
                (e2 (cl:if (cl:member (cl:symbol-name (cl:first t2)) '("CELL") :test #'cl:string-equal)
                           (canonicalize-type-specifier t2)
                           t2)))
         (cl:equal e1 e2)))
      ;; Keyword vs Enum
      ((and (or (member t1 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t1) (member (symbol-name t1) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t2 *crisp-enums*)) t)
      ((and (or (member t2 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t2) (member (symbol-name t2) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t1 *crisp-enums*)) t)
      ;; Handle mismatched wrapping (e.g. (INT) vs INT)
      ((and (consp t1) (= (length t1) 1) (valid-type-p (cl:first t1)) (types-equivalent-p (cl:first t1) t2)) t)
      ((and (consp t2) (= (length t2) 1) (valid-type-p (cl:first t2)) (types-equivalent-p t1 (cl:first t2))) t)
      (t nil))))

(defun get-template-arity (name)
  "Returns the arity (number of type parameters) for a registered template, or nil."
  (or (and (boundp '*template-arity-lookup-fn*)
           (funcall *template-arity-lookup-fn* name))
      ;; Fallback to registry if lookup fn not ready
      (cl:let ((entries (gethash name *template-registry*)))
        (cl:when entries
          (length (template-data-parameters (cl:first entries)))))))

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
      ((gethash type-spec *crisp-enums*) t)
      ((gethash type-spec *function-table*) t)
      ;; Check derived types
      ((gethash type-spec *type-derivation-graph*) t)
      ;; Check aliases (Fix for regression)
      ((gethash type-spec *crisp-type-aliases*) t)
      ;; Should we check pending definitions? Yes.
      ((and (boundp '*pending-struct-definitions*)
            (find type-spec *pending-struct-definitions* :key #'first)) t)
      ;; In Multipass/Deferred mode, any symbol could be a forward reference.
      ;; We accept it now and let resolve-type-to-llvm catch errors later.
      ((and (boundp '*defer-struct-validation*) *defer-struct-validation*) t)
      ((member type-spec '(keyword symbol quote)) t)
      (t
       (log:debug "valid-basic-type-p CHECK FAILED for: ~s (pkg: ~a)" type-spec
                  (if (symbolp type-spec) (package-name (symbol-package type-spec)) "N/A"))
       (log:debug "  Available types keys: ~a" (alexandria:hash-table-keys *crisp-types*))
       nil))))

(defun valid-function-type-p (type-spec)
  "Checks if type-spec is a valid function literal or descriptor."
  (or (and (consp type-spec) (eq (cl:first type-spec) :function-literal)
           (= (length type-spec) 2) (symbolp (second type-spec)))
      (and (consp type-spec) (eq (cl:first type-spec) :function-type))))


(defun %instantiate-template-if-needed (base-type template-args mangled-name)
  "Helper: Attempts to instantiate a template if not already instantiated.
   Returns T if template exists/instantiated successfully, NIL otherwise."
  (cl:let ((templates (or (gethash base-type *template-registry*)
                          (cl:let ((found nil))
                            (maphash (cl:lambda (k v)
                                       (cl:when (and (symbolp k)
                                                     (string-equal (symbol-name k)
                                                                   (symbol-name base-type)))
                                         (cl:setf found v)))
                                     *template-registry*)
                            found))))
    (cl:cond
      ;; No templates found for this base type
      ((null templates) nil)

      ;; Template instantiator not available
      ((not (and (boundp '*template-instantiator-fn*)
                 *template-instantiator-fn*))
       (log:warn "Template instantiator not bound/found")
       nil)

      ;; Instantiate the template
      (t
       (funcall *template-instantiator-fn* base-type template-args
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
       ;; Return T if template was found and instantiated
       t))))

(defun %validate-template-instantiation (base-type template-args)
  "Helper: Validates a template instantiation, checking if it's already defined
   or can be instantiated. Returns T if valid, NIL otherwise."
  (cl:let ((mangled-name (mangle-template-struct-name base-type template-args)))
    (or (gethash mangled-name *crisp-structs*)
        (%instantiate-template-if-needed base-type template-args mangled-name))))

(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, etc)."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (rest expanded)))
      (cl:cond
        ;; Base type must be a symbol
        ((not (symbolp base-type)) nil)

        ;; Exclude special forms (FUNCTION, QUOTE, etc.)
        ((excluded-template-base-type-p base-type) nil)

        ;; Handle valid struct/type with optional keyword properties
        ;; e.g., (INT) or (INT :BITS 32) are valid
        ;; but (INT INT) is NOT valid
        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params) ;; (INT) wrapper
                  (keywordp (first params)))) ;; (INT :BITS 32) properties
                                             t)

        ;; Standard template instantiation
        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

        ;; Default: invalid
        (t nil)))))

(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
   Handles simple types, parameterized types, and function literals/types."
  (or (valid-basic-type-p type-spec)
      (valid-function-type-p type-spec)
      (valid-parameterized-type-p type-spec)
      ;; Check aliases
      (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
      (and (listp type-spec)
           (symbolp (first type-spec))
           (or (gethash (first type-spec) *crisp-type-aliases*)
               (gethash (first type-spec) *crisp-template-aliases*)))))

;; Alias for backward compatibility / simplicity
(defun type-equal-p (t1 t2)
  (types-equivalent-p t1 t2))

;; LLVM Resolution
;; ===============

(defun encode-address-space (as)
  "Maps a keyword address space to an integer, sensitive to *target-backend*."
  (cl:let ((backend (if (boundp '*target-backend*) *target-backend* :generic))
           (as-key (if (keywordp as) as (intern (symbol-name as) :keyword))))
    (case backend
      (:spirv
       (case as-key
         (:private 0)
         (:global 1)
         (:constant 2)
         (:local 3)
         (:generic 4)
         (t (if (integerp as) as 0))))
      (:ptx
       (case as-key
         (:generic 0)
         (:global 1)
         (:shared 3)
         (:local 3)
         (:constant 4)
         (:private 5)
         (t (if (integerp as) as 0))))
      (t
       (case as-key
         (:private 0)
         (:global 1)
         (:constant 2)
         (:local 3)
         (:generic 4)
         (t (if (integerp as) as 0)))))))

(defparameter *resolve-depth* 0)


(defun find-template-robust (name)
  (or (cl:gethash name *template-registry*)
      (cl:let ((found nil))
        (maphash (cl:lambda (k v)
                   (cl:when (and (symbolp k)
                                 (string-equal (symbol-name k) (symbol-name name)))
                     (cl:setf found v)))
                 *template-registry*)
        found)))

(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference."
  (cl:let ((*resolve-depth* (1+ *resolve-depth*)))
    (cl:when (> *resolve-depth* 50)
      (cl:error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    (cl:cond
      ;; Derived Type - resolve to base type (MUST come before *crisp-types* check)
      ;; Only match if it's ACTUALLY a derived type (has an original-type), not a base type node
      ;; Handle package mismatches by trying both current package and CRISP-LANGUAGE
      ((cl:and (cl:symbolp type-spec)
               (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                         (node-alt (when (not node-direct)
                                     (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                            (cl:find-package :crisp-language))
                                                 *type-derivation-graph*)))
                         (node (or node-direct node-alt)))
                 (and node (type-node-original-type node))))
       (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                 (node-alt (when (not node-direct)
                             (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                    (cl:find-package :crisp-language))
                                         *type-derivation-graph*)))
                 (actual-type (if node-direct type-spec
                                (cl:intern (cl:symbol-name type-spec)
                                           (cl:find-package :crisp-language))))
                 (base-type (get-type-base actual-type)))
         (resolve-type-to-llvm base-type)))

      ;; Built-in Scalar
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-types*))
       (cl:funcall (crisp-type-llvm-type-fn (cl:gethash type-spec *crisp-types*))))

      ;; Type Alias (Symbol)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-type-aliases*))
       (resolve-type-to-llvm (cl:gethash type-spec *crisp-type-aliases*)))

      ;; C-Pointer with properties: e.g. (c-pointer :address-space :global)
      ((cl:and (cl:consp type-spec) (cl:eq (cl:first type-spec) 'c-pointer))
       (cl:let* ((args (cl:rest type-spec))
                 (as-key (cl:getf args :address-space))
                 (as-val (encode-address-space as-key)))
         (llvm-pointer-type (llvm-int8-type) as-val)))

      ;; Struct (Pre-existing)
      ((cl:and (cl:symbolp type-spec) (find-struct-definition-by-name type-spec))
       (ensure-struct-llvm-type type-spec))

      ;; Enumerations (map to i32)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-enums*))
       (llvm-int32-type))

      ;; Keyword/Symbol/Quote (map to i32) - Handle Symbol and List forms
      ((cl:or (cl:member type-spec '(keyword symbol quote))
         (cl:and (cl:consp type-spec) (cl:member (cl:first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ;; We handle both (CELL ...) and CELL_INT_... here to support on-demand logic.
      ((cl:or (cl:and (cl:consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (cl:first type-spec)))
         (cl:and (cl:symbolp type-spec)
           (cl:let ((parts (unmangle-template-struct-name type-spec)))
             (cl:and parts (cl:consp parts) (find-template-robust (cl:first parts))))))

       ;; FIX: Ensure we use the CANONICALIZED specifier to instantiate/resolve
       ;; This leverages existing logic in expand-storage-handle-type-specifier
       ;; to clean up keywords and defaults.
       (cl:let* ((canonical (canonicalize-type-specifier type-spec))
                 (is-cons (cl:consp canonical))
                 (unmangled (cl:if is-cons canonical (unmangle-template-struct-name canonical)))
                 (base (cl:first unmangled))
                 (raw-args (cl:rest unmangled))
                 (mangled (mangle-template-struct-name base raw-args)))

         (cl:unless (find-struct-definition-by-name mangled)
           (cl:let ((crisp.compiler::*defer-struct-validation* nil))
             (ensure-template-instantiation base raw-args
                                            (cl:lambda (form location)
                                              (cl:eval form)
                                              (cl:when (cl:and (boundp '*current-module*) *current-module*)
                                                (compile-toplevel-form form location
                                                                       *current-module*
                                                                       *current-builder*
                                                                       *current-di-builder*
                                                                       *current-di-compile-unit*
                                                                       *current-location-map*))))))
         ;; Verify
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:error "Type Resolution: FAILED to instantiate struct ~a" mangled))

         ;; Recurse using the MANGLED name
         (resolve-type-to-llvm mangled)))

      ;; Generic List Wrapper
      ((cl:consp type-spec)
       (resolve-type-to-llvm (cl:first type-spec)))

      (t
       (cl:let ((alias-match (cl:loop for k being the hash-keys of *crisp-type-aliases*
                               when (cl:string-equal (cl:symbol-name k) (cl:symbol-name type-spec))
                               return k)))
         (cl:if alias-match
                (resolve-type-to-llvm (cl:gethash alias-match *crisp-type-aliases*))
                (cl:error "Cannot resolve type to LLVM: ~a" type-spec)))))))

(defun incomplete-type-p (type-spec)
  "Checks if a type specifier is incomplete (missing required compile-time properties).
   Returns T if incomplete, NIL if complete."
  (cl:cond
    ((symbolp type-spec)
     ;; A bare symbol is incomplete if:
     ;; 1. It's a template with arity > 0
     ;; 2. It's a struct with required :c-t fields (and no defaults)
     (cl:let ((arity (get-template-arity type-spec))
              (struct-def (find-struct-definition-by-name type-spec)))
       (log:debug "Checking incompleteness for symbol ~a. Arity: ~a. StructDef: ~a" type-spec arity struct-def)
       (or (and arity (> arity 0))
           (and struct-def
                (loop for m in (crisp-struct-definition-members struct-def)
                        thereis (cl:let* ((is-ct (and (consp m) (eq (third m) :c-t)))
                                          (default-val (and is-ct (fourth m))))
                                  (cl:when (and is-ct (null default-val))
                                    (log:debug "  Incomplete due to C-T member: ~a" m)
                                    t)))))))

    ((consp type-spec)
     (cl:let* ((canon (canonicalize-type-specifier type-spec))
               (base (cl:first canon))
               (args (rest canon)))
       (if (symbolp base)
           (cl:let ((arity (get-template-arity base)))
             (log:debug "Checking completeness for ~a (Arity: ~a)" base arity)
             (cl:cond
               ;; 1. Check Template Arity (Positional Args)
               ((and arity (< (length args) arity))
                (log:info "Type ~a is incomplete: missing template args (got ~d, need ~d)" type-spec (length args) arity)
                t)

               ;; 2. Check Compile-Time Struct Members (Keyword Args)
               (t
                (cl:let ((struct-def (find-struct-definition-by-name base)))
                  (if struct-def
                      (cl:let ((prop-args (if arity (subseq args arity) args)))
                        (log:debug "Checking properties for ~a. PropArgs: ~a" base prop-args)

                        ;; Map provided properties
                        (cl:let ((provided-props (make-hash-table :test 'eq)))
                          (cl:let ((ptr prop-args))
                            (loop while ptr do
                                    (cl:let ((key (cl:first ptr))
                                             (val (second ptr)))
                                      (cl:when (keywordp key)
                                        (setf (gethash key provided-props) val))
                                      (setf ptr (cddr ptr)))))

                          ;; Check required :c-t members
                          (loop for m in (crisp-struct-definition-members struct-def)
                                  thereis (cl:let* ((name (cl:first m))
                                                    (is-ct (and (consp m) (eq (third m) :c-t)))
                                                    (default-val (and is-ct (fourth m)))
                                                    (key (intern (symbol-name name) :keyword)))
                                            ;; It is incomplete if:
                                            ;; - It is a CT member
                                            ;; - It has NO default value
                                            ;; - It is NOT provided in args
                                            (and is-ct
                                                 (null default-val)
                                                 (not (gethash key provided-props)))))))
                      ;; Struct not found? Assume complete or invalid elsewhere.
                      nil)))))
           nil))) ;; Not a symbol base?
    (t nil)))
