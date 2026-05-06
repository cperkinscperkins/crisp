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
      (let ((seen (make-hash-table :test 'eq)))
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




(defun %bare-storage-handle-value-error (item spec)
  "Raises an intelligent error when a bare address-space/access/align value
   is found in a storage handle type spec, suggesting the correct key-value form."
  (cond
    ((member (string item)
                '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':address-space ~(~a~)'?"
            item spec item))
    ((member (string item)
                '("READ-WRITE" "READ-ONLY" "WRITE-ONLY" "READABLE" "WRITEABLE")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':access ~(~a~)'?"
            item spec item))
    ((member (string item)
                '("STRIDED" "COMPACT")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':align ~(~a~)'?"
            item spec item))
    (t
     (error "Unknown keyword ~s in type spec ~s." item spec))))





(defun expand-storage-handle-type-specifier (spec)
  "Expands storage handle type specs into canonical positional forms.
   Cell   → (cell  elem addr)              [3-tuple].
   Vector → (tensor elem 1 addr align ct)  [6-tuple, sugar for tensor N=1].
   Matrix → (tensor elem 2 addr align ct)  [6-tuple, sugar for tensor N=2].
   Tensor → (tensor elem N addr align ct)  [6-tuple].
   ct defaults to :last; :row-major/:col-major are matrix-only aliases for :last/:first."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (let ((base (first spec)))
       (if (and (symbolp base)
                (member (symbol-name base)
                        '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (progn
             (when (null (rest spec))
               (error 'crisp-incomplete-type-error :type-spec spec))

             (let* ((args         (rest spec))
                    (element-type (first args))
                    (rest-args    (rest args)))

               (cond

                ;; ── VECTOR ──────────────────────────────────────────
                ((string-equal (symbol-name base) "VECTOR")
                 (let* ((addr      :global)
                        (aln       :compact)
                        (ct        :last)
                        (remaining rest-args))
                   (when (and remaining (not (keywordp (first remaining))))
                     (error "Invalid type option ~s in vector spec ~s. Vector takes no arity argument; use (tensor ~s N) for N > 2."
                            (first remaining) spec element-type))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          ;; :access has been removed; skip the value but signal a warning
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((member v '(:row-major :col-major))
                               (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last or :first." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (%bare-storage-handle-value-error item spec)))))
                   (list (find-symbol "TENSOR" :crisp.compiler)
                         element-type 1 addr aln ct)))

                ;; ── MATRIX ──────────────────────────────────────────
                ((string-equal (symbol-name base) "MATRIX")
                 (let* ((addr      :global)
                        (aln       :compact)
                        (ct        :last)
                        (remaining rest-args))
                   (when (and remaining (not (keywordp (first remaining))))
                     (error "Invalid type option ~s in matrix spec ~s. Matrix takes no arity argument; use (tensor ~s N) for arbitrary arity."
                            (first remaining) spec element-type))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((eq v :row-major) (setf ct :last))
                              ((eq v :col-major) (setf ct :first))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major, or :col-major." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (%bare-storage-handle-value-error item spec)))))
                   (list (find-symbol "TENSOR" :crisp.compiler)
                         element-type 2 addr aln ct)))

                ;; ── TENSOR ──────────────────────────────────────────
                ((string-equal (symbol-name base) "TENSOR")
                 (let* ((n-arg        (and rest-args
                                           (not (keywordp (first rest-args)))
                                           (first rest-args)))
                        (rest-after-n (if n-arg (rest rest-args) rest-args))
                        (addr         :global)
                        (aln          :compact)
                        (ct           :last)
                        (remaining    rest-after-n))
                   (unless n-arg
                     (error 'crisp-incomplete-type-error :type-spec spec))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ;; bare address-space values (canonical form idempotency)
                         ((member (string item)
                                  '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                  :test #'string-equal)
                          (setf addr (intern (string-upcase (string item)) :keyword)))
                         ;; bare access values — ignore silently (canonical idempotency for old forms)
                         ((member (string item)
                                  '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                    "READABLE" "WRITEABLE")
                                  :test #'string-equal)
                          (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
                         ;; bare align values (canonical form idempotency)
                         ((member (string item) '("COMPACT" "COMPACT-OFFSET" "STRIDED")
                                  :test #'string-equal)
                          (setf aln (intern (string-upcase (string item)) :keyword)))
                         ;; bare contiguous-term values (canonical form idempotency)
                         ((member (string item) '("LAST" "FIRST")
                                  :test #'string-equal)
                          (setf ct (intern (string-upcase (string item)) :keyword)))
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((eq v :row-major)
                               (let ((n (if (integerp n-arg) n-arg
                                            (ignore-errors (parse-integer (string n-arg))))))
                                 (unless (eql n 2)
                                   (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                               (setf ct :last))
                              ((eq v :col-major)
                               (let ((n (if (integerp n-arg) n-arg
                                            (ignore-errors (parse-integer (string n-arg))))))
                                 (unless (eql n 2)
                                   (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                               (setf ct :first))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major (2D only), or :col-major (2D only)." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (error "Invalid type option: ~s in tensor spec ~s" item spec)))))
                   (list base element-type n-arg addr aln ct)))

                ;; ── CELL ────────────────────────────────────────────
                (t
                 (if (null rest-args)
                     (list base element-type :global)
                     (let ((addr      :global)
                           (remaining rest-args))
                       (loop while remaining do
                         (let ((item (pop remaining)))
                           (cond
                             ((member (string item)
                                      '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                      :test #'string-equal)
                              (setf addr (intern (string-upcase (string item)) :keyword)))
                             ((member (string item)
                                      '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                        "READABLE" "WRITEABLE")
                                      :test #'string-equal)
                              (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                              (pop remaining)
                              (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                             ((string-equal (string item) "DIRECTION")
                              (when remaining (pop remaining)))
                             (t (error "Invalid type option: ~s in spec ~s" item spec)))))
                       (list base element-type addr)))))))
           spec)))))

;; Helper: Parse Template Param Spec
(defun parse-template-parameter-spec (param)
  "Parses (Name [Type] [Default]) -> (list Name Type Default)"
  (if (consp param)
         (case (length param)
           (1 (list (first param) 'T nil))
           (2 (list (first param) (second param) nil))
           (3 (list (first param) (second param) (third param)))
           (t (error "Invalid template parameter spec: ~a" param)))
         (list param 'T nil)))


;; 1. Permissive validate-template-arg
(defun validate-template-arg (arg type name)
  (cond
    ((eq type 'T) t)
    ((typep arg type) t)
    ;; Permissive Fix: If arg is SYMBOL (but not keyword) and Type accepts the KEYWORD version
    ((and (symbolp arg)
       (not (keywordp arg))
       (typep (intern (symbol-name arg) :keyword) type))
     t)
    (t (error "Template argument mismatch for ~a. Expected type ~a, got ~a (~a)"
         name type arg (type-of arg)))))




(defun canonicalize-type-specifier (spec)
  "Canonicalizes type specifiers.
   Extended: (array T N) is returned as-is before the template path, preventing
   mangle to ARRAY_LONG_5 via the get-template-arity=2 path."

  ;; Early exit for (array T N): never mangle, preserve as list
  (when (and (consp spec) (%array-type-p spec))
    (return-from canonicalize-type-specifier spec))

  ;; First, apply storage handle expansion
  (when (consp spec)
    (setf spec (expand-storage-handle-type-specifier spec)))

  ;; After expansion, check again (in case alias expanded to array)
  (when (and (consp spec) (%array-type-p spec))
    (return-from canonicalize-type-specifier spec))

  (let ((base (if (consp spec) (first spec) spec))
           (args (if (consp spec) (rest spec) nil)))
    (cond
      ((symbolp base)
       ;; 1. Check Template Aliases (def-type)
       (let ((alias-def (gethash base *crisp-template-aliases*)))
         (if alias-def
                (let ((params (car alias-def))
                         (type-spec (cdr alias-def)))
                  (if params
                         (let* ((arity (length params))
                                   (required-args (subseq args 0 (min (length args) arity)))
                                   (rest-args (subseq args (length required-args)))
                                   (substitutions (pairlis params required-args)))
                           (let ((expanded-base (sublis substitutions type-spec)))
                             (if (and rest-args (consp expanded-base))
                                    (canonicalize-type-specifier (append expanded-base rest-args))
                                    (canonicalize-type-specifier expanded-base))))
                         (if args
                                (canonicalize-type-specifier (append (if (consp type-spec) type-spec (list type-spec)) args))
                                (let ((resolved (resolve-type-alias base)))
                                  (if (equal resolved base)
                                         (progn
                                          (log:warn "[canonicalize-type-specifier] Alias Cycle detected for ~a, returning base." base)
                                          (list base))
                                         (canonicalize-type-specifier resolved))))))

                ;; 2. Standard Templates (With Validation)
                (let* ((template-data (first (gethash base *template-registry*)))
                          (raw-params (and template-data (template-data-parameters template-data))))
                  (if raw-params
                         (let* ((parsed-params (mapcar #'parse-template-parameter-spec raw-params))
                                   (clean-args (extract-positional-from-keyword-args args (length parsed-params)))
                                   (full-args (loop for (p-name p-type p-default) in parsed-params
                                              for i from 0
                                              for arg = (if (< i (length clean-args))
                                                            (nth i clean-args)
                                                            (or p-default
                                                                (error "Missing required type argument for template ~a: ~a (index ~d)" base p-name i)))
                                              do (validate-template-arg arg p-type p-name)
                                              collect arg)))
                           (cons base full-args))

                         ;; Not a template, return as is (normalized to list)
                         (if (consp spec) spec (list spec)))))))
      ((consp spec) spec)
      (t (list spec)))))




(defun %type-atom-equal-p (a b)
  "Package-agnostic atom comparison for type specs.
   Symbols compared by name (string-equal); others compared by equal."
  (or (equal a b)
      (and (symbolp a) (symbolp b)
           (string-equal (symbol-name a) (symbol-name b)))))

(defun %type-spec-equal-p (t1 t2)
  "Recursive package-agnostic comparison of type spec trees.
   Used in types-equivalent-p for the cons-vs-cons case."
  (cond
    ((and (null t1) (null t2)) t)
    ((or (null t1) (null t2)) nil)
    ((and (consp t1) (consp t2))
     (and (%type-spec-equal-p (car t1) (car t2))
          (%type-spec-equal-p (cdr t1) (cdr t2))))
    (t (%type-atom-equal-p t1 t2))))

    


(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling.
   FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels
   before mangling comparison. This supports def-type aliases for any template type.
   FIX2: Use %type-spec-equal-p (package-agnostic) for cons-vs-cons case.
   FIX3: Use compiler-session check instead of broken (boundp '*current-module*)."
  (let ((t1 (resolve-type-alias t1))
           (t2 (resolve-type-alias t2)))
    (cond
      ((or (equal t1 t2)
           (and (symbolp t1) (symbolp t2) (string-equal (symbol-name t1) (symbol-name t2))))
       t)
      ((or (and (symbolp t1) (string-equal t1 "VOID") (null t2))
           (and (null t1) (symbolp t2) (string-equal t2 "VOID")))
       t)
      ((and (consp t1) (symbolp t2))
       (let* ((expanded (canonicalize-type-specifier t1))
              (base-type (first expanded))
              (params (rest expanded)))
         (if (and (symbolp base-type)
                  (not (excluded-template-base-type-p base-type)))
             (progn
              (when (gethash base-type *template-registry*)
                (let ((instantiated-form
                          (funcall *template-instantiator-fn* base-type params
                            (lambda (form location)
                              (let ((is-wrapper
                                     (and (consp form)
                                          (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "DEF-FUNCTION")
                                          (symbolp (second form))
                                          (search "_WRAPPER" (symbol-name (second form))
                                                  :test #'char-equal))))
                                (if (and (not is-wrapper)
                                         *compiler-session*
                                         (compiler-session-module *compiler-session*))
                                    (compile-toplevel-form form location
                                                           *current-module*
                                                           *current-builder*
                                                           *current-di-builder*
                                                           *current-di-compile-unit*
                                                           *current-location-map*)
                                    (eval form)))))))
                  instantiated-form
                  t))
              (let ((mangled (mangle-template-struct-name base-type params)))
                (cond
                  ((eq mangled t2) t)
                  ((string-equal (symbol-name mangled) (symbol-name t2)) t)
                  (t nil))))
             nil)))
      ((and (symbolp t1) (consp t2))
       (types-equivalent-p t2 t1))
      ;; Parameterized struct vs parameterized struct — use package-agnostic comparison
      ((and (consp t1) (consp t2))
       (let ((e1 (canonicalize-type-specifier t1))
                (e2 (canonicalize-type-specifier t2)))
         (%type-spec-equal-p e1 e2)))
      ((and (or (member t1 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t1) (member (symbol-name t1) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t2 *crisp-enums*)) t)
      ((and (or (member t2 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t2) (member (symbol-name t2) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t1 *crisp-enums*)) t)
      ((and (consp t1) (= (length t1) 1) (valid-type-p (first t1)) (types-equivalent-p (first t1) t2)) t)
      ((and (consp t2) (= (length t2) 1) (valid-type-p (first t2)) (types-equivalent-p t1 (first t2))) t)
      (t nil))))


(defun get-template-arity (name)
  "Returns the arity (number of type parameters) for a registered template, or nil."
  (or (and (boundp '*template-arity-lookup-fn*)
           (funcall *template-arity-lookup-fn* name))
      ;; Fallback to registry if lookup fn not ready
      (let ((entries (gethash name *template-registry*)))
        (when entries
          (length (template-data-parameters (first entries)))))))

(defun type-lists-equivalent-p (l1 l2)
  (and (= (length l1) (length l2))
       (every #'types-equivalent-p l1 l2)))

;; Predicates
;; ==========

(defun valid-basic-type-p (type-spec)
  "Checks if type-spec is a valid basic symbol type (built-in, struct, or function reference)."
  (when (and (symbolp type-spec) (not (keywordp type-spec)))
    (cond
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
  "Checks if type-spec is a valid function literal or descriptor.
Extended to also accept raw (function ...) forms from the Crisp reader
(i.e., #'(float float => float) which the CL reader gives as (function ...))."
  (or (and (consp type-spec) (eq (first type-spec) :function-literal)
           (= (length type-spec) 2) (symbolp (second type-spec)))
      (and (consp type-spec) (eq (first type-spec) :function-type))
      ;; Raw function type from #'(...) reader expansion: (function (... => ...))
      ;; Note: must return T (boolean), not the member result, to satisfy valid-type-p's type decl.
      (and (consp type-spec) (eq (first type-spec) 'common-lisp:function))))



(defun %instantiate-template-if-needed (base-type template-args mangled-name)
  "Helper: Attempts to instantiate a template if not already instantiated.
   Returns T if template exists/instantiated successfully, NIL otherwise.
   FIX3: Use (and *compiler-session* (compiler-session-module *compiler-session*))
   instead of (boundp '*current-module*) — the latter always returns NIL because
   *current-module* is a define-symbol-macro, not a defvar special variable."
  (let ((templates (or (gethash base-type *template-registry*)
                          (let ((found nil))
                            (maphash (lambda (k v)
                                       (when (and (symbolp k)
                                                     (string-equal (symbol-name k)
                                                                   (symbol-name base-type)))
                                         (setf found v)))
                                     *template-registry*)
                            found))))
    (cond
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
           ;; Skip the constructor _WRAPPER function when compiling to IR.
           ;; The wrapper has compile-time fields (e.g. type-spec) whose LLVM
           ;; mapping is void — valid as return type but INVALID as a parameter.
           ;; The wrapper is never called at GPU runtime, so it needs no IR body.
           ;; We still eval it so the overload gets registered in *function-table*.
           (let ((is-wrapper
                  (and (consp form)
                       (symbolp (car form))
                       (string-equal (symbol-name (car form)) "DEF-FUNCTION")
                       (symbolp (second form))
                       (search "_WRAPPER" (symbol-name (second form))
                               :test #'char-equal))))
             (if (and (not is-wrapper)
                      *compiler-session*
                      (compiler-session-module *compiler-session*))
                 (compile-toplevel-form form nil
                                        *current-module*
                                        *current-builder*
                                        *current-di-builder*
                                        *current-di-compile-unit*
                                        *current-location-map*)
                 (eval form)))))
       ;; Return T if template was found and instantiated
       t))))

(defun %validate-template-instantiation (base-type template-args)
  "Helper: Validates a template instantiation, checking if it's already defined
   or can be instantiated. Returns T if valid, NIL otherwise."
  (let ((mangled-name (mangle-template-struct-name base-type template-args)))
    (or (gethash mangled-name *crisp-structs*)
        (%instantiate-template-if-needed base-type template-args mangled-name))))




(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, array, etc).
   Extended to recognise (array T N), reject nested arrays, and accept symbol counts
   (e.g. the symbol |5| produced by unmangle-template-struct-name)."
  (when (consp type-spec)
    (let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (first expanded))
              (params (rest expanded)))
      (cond
        ((not (symbolp base-type)) nil)
        ((excluded-template-base-type-p base-type) nil)

        ;; (array T N) — compile-time fixed array type
        ;; count may be an integer (from source) or a symbol like |5| (from unmangle)
        ((%array-type-p expanded)
         (let* ((elem-type (first params))
                   (count-raw (second params))
                   (count (cond
                            ((integerp count-raw) count-raw)
                            ((and (symbolp count-raw)
                                  (ignore-errors (parse-integer (symbol-name count-raw)))))
                            (t nil))))
           ;; Nesting is illegal
           (when (%array-type-p elem-type)
             (error 'crisp-compiler-error
                    :message (format nil "Array type cannot be nested: ~s is illegal. Use def-struct or a cell instead."
                                     type-spec)))
           ;; Validate: exactly 2 args, valid non-array element type, positive integer count
           (and (= (length params) 2)
                (valid-basic-type-p elem-type)
                count
                (> count 0))))

        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params)
                  (keywordp (first params))))
         t)

        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

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
  (let ((backend (if (boundp '*target-backend*) *target-backend* :generic))
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
  (or (gethash name *template-registry*)
      (let ((found nil))
        (maphash (lambda (k v)
                   (when (and (symbolp k)
                                 (string-equal (symbol-name k) (symbol-name name)))
                     (setf found v)))
                 *template-registry*)
        found)))



(defun %array-type-p (type-spec)
  "Returns T if TYPE-SPEC is a list form whose head is the symbol ARRAY.
   Used throughout the array implementation to identify (array T N) type specs."
  (and (consp type-spec)
       (symbolp (first type-spec))
       (string-equal (symbol-name (first type-spec)) "ARRAY")))



(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference.
   Extended to handle (array T N) → LLVM [N x T_llvm].
   Extended to normalize VECTOR/MATRIX sugar to TENSOR before dispatch,
   and to canonicalize type alias values before recursing."
  (let ((*resolve-depth* (1+ *resolve-depth*)))
    (when (> *resolve-depth* 50)
      (error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    ;; ── Early-out: VECTOR/MATRIX sugar → TENSOR ──────────────────────────────
    ;; VECTOR and MATRIX are not in *template-registry*, so the normal
    ;; "Parameterized Structs" branch cannot handle them.  Expand to TENSOR first
    ;; so the rest of the dispatch sees a canonical (tensor ...) form.
    (when (and (consp type-spec)
                     (symbolp (first type-spec))
                     (member (symbol-name (first type-spec))
                                '("VECTOR" "MATRIX") :test #'string-equal))
      (log:info "resolve-type-to-llvm: expanding ~a sugar to TENSOR" (first type-spec))
      (return-from resolve-type-to-llvm
        (resolve-type-to-llvm (expand-storage-handle-type-specifier type-spec))))

    (cond
      ;; (array T N) → [N x T_llvm]
      ((%array-type-p type-spec)
       (let* ((elem-type (second type-spec))
                 (count-raw (third type-spec))
                 (count (etypecase count-raw
                          (integer count-raw)
                          (symbol  (parse-integer (symbol-name count-raw))))))
         (log:info "resolve-type-to-llvm: (array ~a ~a) -> [~a x ...]" elem-type count count)
         (crisp.llvm-bindings::llvm-array-type (resolve-type-to-llvm elem-type) count)))

      ;; Derived Type - resolve to base type (MUST come before *crisp-types* check)
      ((and (symbolp type-spec)
         (let* ((node-direct (gethash type-spec *type-derivation-graph*))
                   (node-alt (when (not node-direct)
                               (gethash (intern (symbol-name type-spec)
                                                      (find-package :crisp-language))
                                           *type-derivation-graph*)))
                   (node (or node-direct node-alt)))
           (and node (type-node-original-type node))))
       (let* ((node-direct (gethash type-spec *type-derivation-graph*))
                 (node-alt (when (not node-direct)
                             (gethash (intern (symbol-name type-spec)
                                                    (find-package :crisp-language))
                                         *type-derivation-graph*)))
                 (actual-type (if node-direct type-spec
                                  (intern (symbol-name type-spec)
                                             (find-package :crisp-language))))
                 (base-type (get-type-base actual-type)))
         (resolve-type-to-llvm base-type)))

      ;; Built-in Scalar
      ((and (symbolp type-spec) (gethash type-spec *crisp-types*))
       (funcall (crisp-type-llvm-type-fn (gethash type-spec *crisp-types*))))

      ;; Type Alias (Symbol) — canonicalize alias value before recursing so that
      ;; aliases pointing to (vector ...) / (matrix ...) are normalized to TENSOR.
      ((and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
       (resolve-type-to-llvm
        (canonicalize-type-specifier (gethash type-spec *crisp-type-aliases*))))

      ;; C-Pointer with properties: e.g. (c-pointer :address-space :global)
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer))
       (let* ((args (rest type-spec))
                 (as-key (getf args :address-space))
                 (as-val (encode-address-space as-key)))
         (llvm-pointer-type (llvm-int8-type) as-val)))

      ;; Struct (Pre-existing)
      ((and (symbolp type-spec) (find-struct-definition-by-name type-spec))
       (ensure-struct-llvm-type type-spec))

      ;; Enumerations (map to i32)
      ((and (symbolp type-spec) (gethash type-spec *crisp-enums*))
       (llvm-int32-type))

      ;; Keyword/Symbol/Quote (map to i32)
      ((or (member type-spec '(keyword symbol quote))
         (and (consp type-spec) (member (first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ((or (and (consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (first type-spec)))
         (and (symbolp type-spec)
           (let ((parts (unmangle-template-struct-name type-spec)))
             (and parts (consp parts) (find-template-robust (first parts))))))
       (let* ((canonical (canonicalize-type-specifier type-spec))
                 (is-cons (consp canonical))
                 (unmangled (if is-cons canonical (unmangle-template-struct-name canonical)))
                 (base (first unmangled))
                 (raw-args (rest unmangled))
                 (mangled (mangle-template-struct-name base raw-args)))
         (unless (find-struct-definition-by-name mangled)
           (let ((crisp.compiler::*defer-struct-validation* nil))
             (ensure-template-instantiation base raw-args
                                            (lambda (form location)
                                              (eval form)
                                              (when (and (boundp '*current-module*) *current-module*)
                                                (compile-toplevel-form form location
                                                                       *current-module*
                                                                       *current-builder*
                                                                       *current-di-builder*
                                                                       *current-di-compile-unit*
                                                                       *current-location-map*))))))
         (unless (find-struct-definition-by-name mangled)
           (error "Type Resolution: FAILED to instantiate struct ~a" mangled))
         (resolve-type-to-llvm mangled)))

      ;; Generic List Wrapper
      ((consp type-spec)
       (resolve-type-to-llvm (first type-spec)))

      (t
       (let ((alias-match (loop for k being the hash-keys of *crisp-type-aliases*
                               when (string-equal (symbol-name k) (symbol-name type-spec))
                               return k)))
         (if alias-match
                ;; Canonicalize before recursing (same fix as Type Alias branch above)
                (resolve-type-to-llvm
                 (canonicalize-type-specifier (gethash alias-match *crisp-type-aliases*)))
                (error "Cannot resolve type to LLVM: ~a" type-spec)))))))

(defun incomplete-type-p (type-spec)
  "Checks if a type specifier is incomplete (missing required compile-time properties).
   Returns T if incomplete, NIL if complete."
  (cond
    ((symbolp type-spec)
     ;; A bare symbol is incomplete if:
     ;; 1. It's a template with arity > 0
     ;; 2. It's a struct with required :c-t fields (and no defaults)
     (let ((arity (get-template-arity type-spec))
              (struct-def (find-struct-definition-by-name type-spec)))
       (log:debug "Checking incompleteness for symbol ~a. Arity: ~a. StructDef: ~a" type-spec arity struct-def)
       (or (and arity (> arity 0))
           (and struct-def
                (loop for m in (crisp-struct-definition-members struct-def)
                        thereis (let* ((is-ct (and (consp m) (eq (third m) :c-t)))
                                          (default-val (and is-ct (fourth m))))
                                  (when (and is-ct (null default-val))
                                    (log:debug "  Incomplete due to C-T member: ~a" m)
                                    t)))))))

    ((consp type-spec)
     (let* ((canon (canonicalize-type-specifier type-spec))
               (base (first canon))
               (args (rest canon)))
       (if (symbolp base)
           (let ((arity (get-template-arity base)))
             (log:debug "Checking completeness for ~a (Arity: ~a)" base arity)
             (cond
               ;; 1. Check Template Arity (Positional Args)
               ((and arity (< (length args) arity))
                (log:info "Type ~a is incomplete: missing template args (got ~d, need ~d)" type-spec (length args) arity)
                t)

               ;; 2. Check Compile-Time Struct Members (Keyword Args)
               (t
                (let ((struct-def (find-struct-definition-by-name base)))
                  (if struct-def
                      (let ((prop-args (if arity (subseq args arity) args)))
                        (log:debug "Checking properties for ~a. PropArgs: ~a" base prop-args)

                        ;; Map provided properties
                        (let ((provided-props (make-hash-table :test 'eq)))
                          (let ((ptr prop-args))
                            (loop while ptr do
                                    (let ((key (first ptr))
                                             (val (second ptr)))
                                      (when (keywordp key)
                                        (setf (gethash key provided-props) val))
                                      (setf ptr (cddr ptr)))))

                          ;; Check required :c-t members
                          (loop for m in (crisp-struct-definition-members struct-def)
                                  thereis (let* ((name (first m))
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


(defun extract-positional-from-keyword-args (args num-params)
  "Extract NUM-PARAMS positional template args from ARGS when (length ARGS) > NUM-PARAMS.

   Two conventions are supported:
   1. Labeled style: (:label value) pairs identify template params by a descriptive name.
      e.g. (int :address-space :global :access :read-write) with arity 3
           => (int :global :read-write)
   2. Positional+c-t style: first NUM-PARAMS args are positional template args;
      any remaining args are compile-time field overrides handled elsewhere.
      e.g. (int :blue :stitching-c :black) with arity 2
           => (int :blue)

   Disambiguation: label-strip the entire list.  If the result has exactly
   NUM-PARAMS elements, the labeled convention was used and that result is
   returned.  Otherwise the positional+c-t convention was used and the first
   NUM-PARAMS elements of ARGS are returned unchanged."
  (if (<= (length args) num-params)
      args
      ;; Try label-stripping the full arg list.
      (let* ((stripped
              (let ((result nil)
                       (remaining args))
                (loop while remaining
                      for item = (pop remaining)
                      do (if (and (keywordp item) remaining)
                             ;; Keyword label: skip label, push next item as value
                             (push (pop remaining) result)
                             ;; Non-keyword (or trailing keyword): push as positional
                             (push item result)))
                (nreverse result))))
        (if (= (length stripped) num-params)
            ;; Label-stripping produced the right count -> labeled convention
            stripped
            ;; Label-stripping gave wrong count -> positional+c-t convention;
            ;; take only the first num-params args as template args.
            (subseq args 0 num-params)))))
