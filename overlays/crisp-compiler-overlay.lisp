;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/types/validation.lisp
(defun extract-positional-from-keyword-args (args num-params)
  "When a type spec has more args than template params, keyword labels are present.
   Extracts positional values by stripping keyword labels.
   e.g. (INT :address-space :GLOBAL :access :READ-WRITE) with 3 params
        => (INT :GLOBAL :READ-WRITE)
   Only applied when (length args) > num-params, otherwise returns args unchanged."
  (if (<= (length args) num-params)
      args
      ;; More args than params: keyword labels must be present.
      ;; Walk the list: keyword followed by a value = label/value pair (keep value).
      ;; Non-keyword = positional (keep as-is).
      (let ((result nil)
            (remaining args))
        (loop while remaining
              for item = (pop remaining)
              do (if (and (keywordp item) remaining)
                     ;; Keyword label: skip it, take the next element as value
                     (push (pop remaining) result)
                     ;; Positional arg
                     (push item result)))
        (nreverse result))))

;; src/templates.lisp
(defun strip-keyword-labels (type-list template-params)
  "Strips keyword LABEL pairs from a type specifier list, keeping keyword VALUES.
   A keyword is treated as a label (and stripped) only when the element following
   it is a template parameter.  Keyword values (concrete types like :global) are kept.
   e.g. (fake-cell T :address-space addr :access acc) with params (T addr acc)
        => (fake-cell T addr acc)
   But  (cell T :global :read-write) with params (T)
        => (cell T :global :read-write)  -- :global and :read-write are values, kept."
  (let ((result nil))
    (loop for (elem . rest) on type-list
          do (cond
              ;; Keyword followed by a template param = label. Skip the keyword.
              ;; The template param itself will be collected on the next iteration.
              ((and (keywordp elem)
                    rest
                    (member (car rest) template-params))
               nil)
              (t (push elem result))))
    (nreverse result)))

;; src/templates.lisp
(defun match-template-arg (raw-sig-type arg-type inference-map template-params)
  "Recursively matches sig-type against arg-type, updating inference-map."
  (let ((sig-type (normalize-template-sig-type raw-sig-type)))
    (cond
     ;; 1. Template Parameter (e.g. T)
     ((member sig-type template-params)
       (let ((existing (gethash sig-type inference-map)))
         (if existing
             (equal existing arg-type)
             (progn (setf (gethash sig-type inference-map) arg-type) t))))

     ;; 2. Match Function Literal against a Function Type Pattern
     ;; Special Case: Only if we are looking for a function type and find a literal func-name.
     ((and (listp sig-type) (eq (first sig-type) :function-type)
           (listp arg-type) (eq (first arg-type) :function-literal))
       (let* ((name (second arg-type))
              (signatures (gethash name *function-table*)))
         (loop for sig in signatures
                 ;; Try to match this overload
                 when (match-function-signature sig-type sig inference-map template-params)
                 return t)))

     ;; 3. Generic List Pattern - Handles (vector T) AND (:function-type ...)
     ((listp sig-type)
       (or
        ;; A. Dependent Type Match: (token-t s) matches token-t OR token-t-123 (gensym)
        (and (symbolp (first sig-type)) (symbolp arg-type)
             (let ((sig-name (symbol-name (first sig-type)))
                   (arg-name (symbol-name arg-type)))
               (or (string-equal sig-name arg-name)
                   (and (> (length arg-name) (length sig-name))
                        (string-equal sig-name (subseq arg-name 0 (length sig-name)))
                        (cl:char= (cl:char arg-name (length sig-name)) #\-)))))

        ;; B. Standard recursive list match
        (match-list-structure sig-type arg-type inference-map template-params)
        ;; C. Unmangle struct names to lists for matching (e.g. CELL_FLOAT -> (CELL FLOAT ...))
        ;;    Strip keyword labels from sig-type since mangled names are purely positional.
        ;;    e.g. sig (fake-cell T :address-space addr :access acc) stripped to (fake-cell T addr acc)
        ;;         matches unmangled (FAKE-CELL INT GLOBAL READ-WRITE)
        (and (symbolp arg-type)
             (let ((unmangled (unmangle-template-struct-name arg-type)))
               (when unmangled
                     (let ((stripped (strip-keyword-labels sig-type template-params)))
                       (log:debug "match-template-arg unmangle path: sig=~s stripped=~s unmangled=~s"
                                  sig-type stripped unmangled)
                       (when (match-list-structure stripped unmangled inference-map template-params)
                         ;; Post-process: mangling loses keyword-ness (format "~a" :GLOBAL => "GLOBAL").
                         ;; For template params that were preceded by keyword labels in the original
                         ;; sig-type, convert the inferred plain symbol back to a keyword.
                         (loop for (elem . rest) on sig-type
                               when (and (keywordp elem) rest (member (car rest) template-params))
                               do (let* ((param (car rest))
                                         (val (gethash param inference-map)))
                                    (when (and val (symbolp val) (not (keywordp val)))
                                      (log:debug "keywordify inferred param ~s: ~s => :~a" param val (symbol-name val))
                                      (setf (gethash param inference-map)
                                            (intern (symbol-name val) :keyword)))))
                         t)))))
        ;; D. Check for Template Aliases (e.g. (out-c T) -> (cell T ...))
        (let ((alias-def (and (symbolp (first sig-type))
                              (gethash (first sig-type) *crisp-template-aliases*))))
          (when alias-def
                (let* ((alias-params (car alias-def))
                       (alias-body (cdr alias-def))
                       (args (rest sig-type))
                       (arity (length alias-params))
                       (required-args (subseq args 0 (min (length args) arity)))
                       (rest-args (subseq args (length required-args)))
                       (substitutions (pairlis alias-params required-args))
                       (expanded-base (sublis substitutions alias-body))
                       ;; If base expanded to a list, we append the rest args
                       (expanded-sig (if (and rest-args (consp expanded-base))
                                         (append expanded-base rest-args)
                                         expanded-base)))
                  (match-template-arg (canonicalize-type-specifier expanded-sig) arg-type inference-map template-params))))))

     ;; Check for Symbol Alias (e.g. out-c)
     ((and (symbolp sig-type)
           (gethash sig-type *crisp-template-aliases*))
       (let* ((alias-def (gethash sig-type *crisp-template-aliases*))
              (alias-body (cdr alias-def)))
         (match-template-arg (canonicalize-type-specifier alias-body) arg-type inference-map template-params)))

     ;; 4. Concrete Type (int)
     (t (or (equal sig-type arg-type)
            (and (symbolp sig-type) (symbolp arg-type)
                 (string-equal (symbol-name sig-type) (symbol-name arg-type)))

            ;; Implicit Template Expansion: SERVER -> (SERVER T)
            ;; Only if direct match fails.
            (and (symbolp sig-type)
                 (gethash sig-type *template-registry*)
                 (let* ((tmpl (first (gethash sig-type *template-registry*)))
                        (params (mapcar (lambda (p) (if (consp p) (first p) p)) (template-data-parameters tmpl))))
                   (when params
                         (match-template-arg (cons sig-type params) arg-type inference-map template-params)))))))))

;; src/types/validation.lisp
(defun canonicalize-type-specifier (spec)
  "Canonicalizes type specifiers."

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
                                   ;; FIX: Strip keyword labels when args has more items than params
                                   ;; e.g. (INT :address-space :GLOBAL :access :READ-WRITE) => (INT :GLOBAL :READ-WRITE)
                                   (clean-args (extract-positional-from-keyword-args args (length parsed-params)))
                                   (full-args (cl:loop for (p-name p-type p-default) in parsed-params
                                              for i from 0
                                              for arg = (if (< i (length clean-args))
                                                            (nth i clean-args)
                                                            (or p-default
                                                                (error "Missing required type argument for template ~a: ~a (index ~d)" base p-name i)))
                                              do (validate-template-arg arg p-type p-name)
                                              collect arg)))
                           (cons base full-args))

                         ;; Not a template, return as is (normalized to list)
                         (cl:if (consp spec) spec (list spec)))))))
      ((consp spec) spec)
      (t (list spec)))))

;; src/environment.lisp
(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s)."
  (cond
   ;; 0. Type Aliases -- FIX: Use resolve-type-alias for cycle detection
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved)
       spec))

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (alias-def (gethash alias-name *crisp-template-aliases*))
            (params (car alias-def))
            (body-spec (cdr alias-def))
            (arity (length params))
            (required-args (subseq args 0 (min (length args) arity)))
            (rest-args (subseq args (length required-args)))
            (substitutions (pairlis params required-args)))
       (let ((expanded (sublis substitutions body-spec)))
         (let ((final-spec (if (and rest-args (consp expanded))
                               (append expanded rest-args)
                               (if rest-args
                                   (cons expanded rest-args)
                                   expanded))))
           (parse-type-specifier final-spec)))))

   ;; 0.15 Brand Type Application: (brand-name var-ref)
   ((and (listp spec)
         (= (length spec) 2)
         (symbolp (first spec))
         (symbolp (second spec))
         (is-brand-type-p (first spec)))
     (cl:let* ((brand-name (first spec))
               (var-ref (second spec))
               (brand-def (is-brand-type-p brand-name)))
       (log:info "PARSE: Brand type application (~a ~a) -> ~a [~a]"
                 brand-name var-ref brand-name
                 (if (brand-active-p brand-def) "active" "inactive"))
       brand-name))

   ;; 0.2 Simple Alias as List Head (e.g. (int-cell :access :read-only))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-type-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (expanded-base (gethash alias-name *crisp-type-aliases*)))
       (let ((final-spec (if (listp expanded-base)
                             (append expanded-base args)
                             (cons expanded-base args))))
         (log:info "EXPAND-ALIAS-HEAD: ~a -> ~a" spec final-spec)
         (parse-type-specifier final-spec))))

   ;; Standard symbol: e.g. 'int'
   ((and (symbolp spec) (valid-type-p spec)) spec)

   ;; Storage Handle Symbols (e.g. CELL, VECTOR...)
   ((and (symbolp spec) (member (symbol-name spec) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Promoting symbol ~a to list (~a)" spec spec)
     (parse-type-specifier (list spec)))

   ;; Function Type: #'(int => int)
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                   (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (let ((canonical (expand-storage-handle-type-specifier spec)))
       (if (valid-type-p canonical)
           (let ((base (first canonical))
                 (params (rest canonical)))
             (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params)))
           (error 'crisp-unknown-type-error :type-name spec))))

   ;; Function Type/Literal
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ;; FIX: Strip keyword labels when present (more args than template arity)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (let* ((base (first spec))
            (raw-params (rest spec))
            (arity (get-template-arity base))
            ;; Strip keyword labels if more args than arity
            (params (if (and arity (> (length raw-params) arity))
                        (extract-positional-from-keyword-args raw-params arity)
                        raw-params)))
       (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))
