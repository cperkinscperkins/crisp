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
       (if (gethash brand-name *parameterized-brand-names*)
           ;; Parameterized brand: keep as (brand-name var-ref) for lazy resolution
           ;; in parse-function-declarations where we have the environment.
           (progn
             (log:info "PARSE: Parameterized brand application (~a ~a) - deferring resolution"
                       brand-name var-ref)
             spec)
           ;; Non-parameterized brand: resolve to brand name (original behavior)
           (progn
             (log:info "PARSE: Brand type application (~a ~a) -> ~a [~a]"
                       brand-name var-ref brand-name
                       (if (brand-active-p brand-def) "active" "inactive"))
             brand-name))))

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

;;; =========================================================
;;; Parameterized Brand Support
;;; =========================================================
;;;
;;; When a brand's base type is a template parameter (e.g., (brand value-t T ...)),
;;; different template specializations register the same brand name with different
;;; base types. This makes global type registration impossible.
;;;
;;; Solution: detect the conflict reactively in register-brand-definition,
;;; skip global registration, and resolve (brand-name var) lazily in
;;; parse-function-declarations where we have the environment context.

(defvar *parameterized-brand-names* (make-hash-table :test 'eq)
  "Set of brand names whose base type varies across template specializations.
   These brands skip global type registration and are resolved lazily per-owner.")

;; src/types/brand.lisp
(defun resolve-owner-type-to-mangled (type-spec)
  "Resolves a type specifier (which may be an alias like FC-INT) to its
   canonical mangled form (like FAKE-CELL_INT_GLOBAL_READ-WRITE).
   Used for looking up per-owner brand definitions."
  (cl:let ((canonical (canonicalize-type-specifier type-spec)))
    (cl:cond
      ((and (listp canonical) (> (length canonical) 1))
       (mangle-template-struct-name (first canonical) (rest canonical)))
      ((and (listp canonical) (= (length canonical) 1))
       (first canonical))
      (t canonical))))

;; src/types/brand.lisp
(defun find-brand-for-owner (brand-name owner-type)
  "Looks up a brand definition for the given brand name and owner type.
   Resolves type aliases (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE)
   before lookup."
  (or (gethash (cons brand-name owner-type) *brand-definitions*)
      ;; Try resolving the owner type alias
      (cl:let ((resolved (resolve-owner-type-to-mangled owner-type)))
        (cl:when (and resolved (not (eq resolved owner-type)))
          (log:debug "Brand lookup: resolved owner ~a -> ~a" owner-type resolved)
          (gethash (cons brand-name resolved) *brand-definitions*)))))

;; src/types/brand.lisp
(defun resolve-parameterized-brand-in-env (brand-spec env)
  "Resolves a parameterized brand application (brand-name var-ref) using
   the function environment. Returns the concrete base type for the brand
   based on the variable's owner type.
   For inactive brands, returns the base type directly (transparent).
   For active brands, returns the base type (instance differentiation
   happens later in analyze-function-call)."
  (cl:let* ((brand-name (first brand-spec))
            (var-ref (second brand-spec)))
    ;; Find the variable in the environment
    (cl:let ((param (find var-ref env :key #'parameter-def-name)))
      (if param
          (cl:let* ((owner-type (parameter-def-type param))
                    (brand-def (find-brand-for-owner brand-name owner-type)))
            (if brand-def
                (cl:let ((base-type (brand-definition-base-type brand-def)))
                  (log:info "Resolved parameterized brand (~a ~a): owner ~a -> base type ~a"
                            brand-name var-ref owner-type base-type)
                  base-type)
                (progn
                  (log:warn "No brand definition found for (~a . ~a), returning brand-name as fallback"
                            brand-name owner-type)
                  brand-name)))
          (progn
            (log:warn "Variable ~a not found in env for parameterized brand ~a, returning spec as-is"
                      var-ref brand-name)
            brand-spec)))))

;; src/types/brand.lisp
(defun register-brand-definition (struct-name brand-form)
  "Registers a brand declaration from within a struct definition.
   When the brand is active: registers as a derived type in the DAG.
   When inactive: registers as a type alias (transparent erasure).
   Parameterized brands (base type varies across template specializations)
   skip global registration and are resolved lazily per-owner."
  (cl:let* ((brand-def (if (brand-definition-p brand-form)
                           brand-form
                           (parse-brand-declaration brand-form)))
            (brand-name (brand-definition-brand-name brand-def))
            (base-type (brand-definition-base-type brand-def))
            (subst-mode (brand-definition-subst-mode brand-def))
            (is-parameterized (gethash brand-name *parameterized-brand-names*)))

    ;; Check for name collisions
    (cl:when (gethash brand-name *crisp-structs*)
          (error "Brand name collision: ~a is already defined as a struct." brand-name))
    (cl:when (gethash brand-name *function-table*)
          (error "Brand name collision: ~a is already defined as a function." brand-name))
    (cl:when (and (gethash brand-name *crisp-types*)
               (not (is-brand-type-p brand-name)))
          (error "Brand name collision: ~a is already defined as a non-brand type." brand-name))

    ;; Detect parameterized brands reactively: same brand name, different base type, different owner
    (cl:unless is-parameterized
      (cl:let ((existing (is-brand-type-p brand-name)))
        (cl:when (and existing
                      (not (eq (brand-definition-base-type existing) base-type)))
          ;; Different base type from a different owner struct = parameterized brand
          (log:info "Brand ~a detected as PARAMETERIZED: base ~a (from ~a) vs ~a (from ~a)"
                    brand-name
                    (brand-definition-base-type existing) (brand-definition-owner-struct existing)
                    base-type struct-name)
          (setf is-parameterized t)
          (setf (gethash brand-name *parameterized-brand-names*) t)
          ;; Remove previous global registration (alias table for inactive brands)
          (remhash brand-name *crisp-type-aliases*))))

    ;; Store the owner struct
    (setf (brand-definition-owner-struct brand-def) struct-name)

    ;; Store in *brand-definitions* keyed by (brand-name . struct-type)
    (setf (gethash (cons brand-name struct-name) *brand-definitions*) brand-def)
    (log:info "Registered brand definition: ~a for struct ~a (base: ~a, subst: ~a, enforce: ~a~a)"
              brand-name struct-name base-type subst-mode
              (brand-definition-enforce-mode brand-def)
              (if is-parameterized ", PARAMETERIZED" ""))

    ;; Register the type based on active/inactive status
    ;; SKIP global registration for parameterized brands
    (if is-parameterized
        (log:info "Brand ~a is PARAMETERIZED - skipping global type registration (resolved lazily per owner)"
                  brand-name)
        (if (brand-active-p brand-def)
            (progn
             (log:info "Brand ~a is ACTIVE - registering as derived type of ~a with :subst ~a"
                       brand-name base-type subst-mode)
             (register-derived-type brand-name base-type subst-mode))
            (progn
             (log:info "Brand ~a is INACTIVE - registering as type alias for ~a"
                       brand-name base-type)
             (setf (gethash brand-name *crisp-type-aliases*) base-type))))))

;; src/environment.lisp
(defun parse-function-declarations (params declarations)
  "Parses a function's declarations and returns its environment and return type.
   Supports interleaved type syntax: ((p type)).
   Post-processes return types to resolve parameterized brand applications."
  (log:debug "PARSE PARAMS: ~s Type: ~a Length: ~a" params (type-of params) (length params))

  ;; Defensive patch: unwrap double nested params (bug in def-record)
  (when (and (= (length params) 1) (listp (first params)) (listp (first (first params))) (symbolp (first (first (first params)))))
        (log:warn "Deeply nested params detected! Unwrapping.")
        (setf params (first params)))

  (let* ((fn-decl (find "FUNCTION" declarations :key (lambda (x) (symbol-name (car x))) :test #'string-equal))

         (return-types (if fn-decl
                           (analyze-return-type-from-spec (second fn-decl))
                           (analyze-return-type-from-list declarations)))

         (env nil)
         (optional-idx nil)
         (defaults nil)
         (key-idx nil))

    ;; Analyze Environment (and Optional Index)
    (cond
     ;; Case 1: #'(...) signature
     (fn-decl
       (log:debug "PARSE CASE 1: Function decl found: ~s" fn-decl)
       (multiple-value-setq (env optional-idx defaults key-idx)
                            (analyze-environment-from-spec params (second fn-decl))))

     ;; Case 2: Interleaved syntax ((a int) (b float))
     ((some #'listp params)
       (log:debug "PARSE CASE 2: Interleaved syntax detected. Params: ~s" params)
       (setf env (loop for p in params
                       collect (if (listp p)
                                   (progn
                                    (unless (>= (length p) 2)
                                      (error "Invalid parameter spec: ~a" p))
                                    (let ((name (first p)) (type (second p)))
                                      (unless (valid-type-p type)
                                        (error 'crisp-unknown-type-error :type-name type))
                                      (let ((parsed (parse-type-specifier type)))
                                        (make-parameter-def :name name :type parsed :kind :in))))
                                   (error "Mixed bare and typed parameters not allowed.")))))

     ;; Case 3: Standard declarations
     (t
       (log:debug "PARSE CASE 3: Standard declarations. Params: ~s" params)
       (setf env (analyze-environment-from-list params declarations))))

    ;; Post-process: resolve parameterized brand applications in return types.
    ;; A parameterized brand application looks like (BRAND-NAME VAR-REF) where
    ;; BRAND-NAME is in *parameterized-brand-names*. We resolve it using the
    ;; environment to find the variable's owner type and the per-owner base type.
    (when env
      (setf return-types
            (mapcar (lambda (rt)
                      (if (and (listp rt) (= (length rt) 2)
                               (symbolp (first rt)) (symbolp (second rt))
                               (gethash (first rt) *parameterized-brand-names*))
                          (resolve-parameterized-brand-in-env rt env)
                          rt))
                    return-types)))

    (values env return-types optional-idx defaults key-idx)))

;; src/types/brand.lisp
(defun validate-dependent-brand-types (declare-forms env)
  "Verifies that any parameters typed as (brand var) refer to a valid owner parameter.
   Scans the raw declarations to find dependencies that parse-type-specifier might have flattened.
   Supports shared brands (same brand name defined on multiple structs).
   Uses find-brand-for-owner for alias resolution (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE)."
  (loop for decl in declare-forms do
          (labels ((scan (form)
                         (cl:cond
                          ((and (listp form)
                                (symbolp (car form))
                                (is-brand-type-p (car form))
                                (= (length form) 2)
                                (symbolp (second form)))
                            ;; Found (BRAND VAR) candidate
                            (cl:let ((brand-name (car form))
                                  (var-ref (second form)))
                              ;; Check var exists in env
                              (cl:let ((param (find var-ref env :key #'parameter-def-name)))
                                (cl:unless param
                                  (error "Brand dependency ~a refers to unknown parameter ~a." form var-ref))

                                (cl:let ((owner-type (parameter-def-type param)))
                                  ;; Check if this specific (Brand . OwnerType) pair is defined
                                  ;; Uses find-brand-for-owner which resolves aliases
                                  (cl:unless (find-brand-for-owner brand-name owner-type)
                                    ;; Not defined for this specific owner.
                                    ;; Retrieve *any* definition to give a helpful error message.
                                    (cl:let ((any-def (is-brand-type-p brand-name)))
                                      (error "Brand dependency mismatch: ~a is defined for owner ~a, but ~a is of type ~a (and no shared definition found)."
                                        brand-name
                                        (if any-def (brand-definition-owner-struct any-def) "UNKNOWN")
                                        var-ref owner-type)))))))
                          ((consp form)
                            (scan (car form))
                            (scan (cdr form))))))
            (scan decl))))

;; src/types/brand.lisp
(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner
   for the given BRAND-NAME. Uses find-brand-for-owner for alias resolution."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (find-brand-for-owner brand-name param-type)
        do (cl:return (if (typep an 'semantic-var-read)
                          (semantic-var-read-name an)
                          nil))))

;; src/types/validation.lisp
(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling.
   FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels
   before mangling comparison. This supports def-type aliases for any template type."
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
      ;; FIX: Always canonicalize, not just for CELL - handles keyword label stripping
      ((and (consp t1) (symbolp t2))
       (let* ((expanded (canonicalize-type-specifier t1))
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
      ;; FIX: Always canonicalize both sides
      ((and (cl:consp t1) (cl:consp t2))
       (cl:let ((e1 (canonicalize-type-specifier t1))
                (e2 (canonicalize-type-specifier t2)))
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

;; src/analysis/structs.lisp
(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, or cell type. Returns NIL if unknown.
   FIX: Only return element type for known array-like types (cell, vector, matrix, tensor, ptr, array),
   not for arbitrary parameterized struct types like (fake-cell int ...)."
  (let ((type (resolve-type-alias type)))
    (cond
     ((listp type)
       ;; Only treat as array-like if the base is a known array/cell type
       (let ((base (first type)))
         (if (and (symbolp base)
                  (member (symbol-name base) '("CELL" "VECTOR" "MATRIX" "TENSOR" "PTR" "ARRAY" "POINTER") :test #'string-equal))
             (second type)
             nil)))
     ((symbolp type)
       ;; Check if it is a Mangled Cell
       (let ((unmangled (unmangle-template-struct-name type)))
         (if (and (consp unmangled) (eq (first unmangled) 'cell))
             (second unmangled)
             nil)))
     (t nil))))

;; src/analysis/control.lisp
(defun analyze-return-expression (expr env context location)
  "Analyzes a `(return ...)` expression.
   FIX: A 1-element list whose sole element is a symbol (e.g. (INDEX-T)) is always
   treated as a return-types list, not a parameterized type. This mirrors the fix
   in validate-return-types."
  (let* ((value-forms (rest expr))
         (value-nodes (loop for form in value-forms
                            for i from 1
                            collect (analyze-expression form env context (append location (list i)))))

         ;; Flatten types to check against signature
         ;; FIX: Also treat 1-element symbol lists as return-type lists, not parameterized types
         (all-inferred-types (if value-nodes
                                 (loop for node in value-nodes
                                         append (let ((t-spec (semantic-node-type node)))
                                                  (if (and (listp t-spec)
                                                           (or (not (valid-type-p t-spec))
                                                               (and (= (length t-spec) 1)
                                                                    (symbolp (first t-spec)))))
                                                      t-spec
                                                      (list t-spec))))
                                 '(nil)))

         ;; Context
         (current-func (compiler-context-current-compiling-function context))
         (sig (if current-func (first (gethash current-func *function-table*)) nil))
         (declared-ret (if sig (function-signature-return-types sig) nil))

         ;; Check for invalid return (Deferred Error 04)
         (is-kernel (member '(entry-point) (compiler-context-declarations context) :test #'equal))
         (invalid-return-p (and declared-ret
                                (or (null declared-ret) (equal declared-ret '(nil)))
                                value-nodes
                                is-kernel
                                (not (every (lambda (n)
                                              (let ((t-spec (semantic-node-type n)))
                                                (or (eq t-spec :void)
                                                    (eq t-spec 'void)
                                                    (equal t-spec '(void))
                                                    (equal t-spec '(nil))
                                                    (null t-spec))))
                                         value-nodes)))))

    (when invalid-return-p
          (let* ((node (first value-nodes))
                 (is-explicit-nil (and (= (length value-nodes) 1)
                                       (or (and (typep node 'semantic-literal)
                                                (null (semantic-literal-value node)))
                                           (and (typep node 'semantic-progn)
                                                (equal (semantic-node-type node) '(nil))
                                                (null (semantic-progn-body node)))))))
            (unless is-explicit-nil
              (error 'crisp-compiler-error :message (format nil "Invalid Return: Function declared to return VOID/NIL but returned a value. Declared: ~a" declared-ret) :source-location location))))

    (let ((return-types all-inferred-types))

      ;; Truncation Logic
      (when (and declared-ret (not (equal declared-ret '(nil))))
            (let ((num-declared (length declared-ret))
                  (num-inferred (length all-inferred-types)))

              (when (> num-inferred num-declared)
                    (log:info "Truncating return values for ~a. declared: ~a inferred: ~a" current-func declared-ret all-inferred-types)
                    (let ((new-nodes '())
                          (captured 0))
                      (loop for node in value-nodes
                            while (< captured num-declared)
                            do (let* ((type (semantic-node-type node))
                                      (is-mv (and (listp type) (not (valid-type-p type))))
                                      (count (if is-mv (length type) 1)))
                                 (cond
                                  (is-mv
                                    (loop for i from 0 below count
                                          while (< captured num-declared)
                                          do (push (make-semantic-extract-value :type (nth i type) :aggregate-node node :index i :source-location (semantic-node-source-location node)) new-nodes)
                                            (incf captured)))
                                  (t
                                    (push node new-nodes)
                                    (incf captured)))))
                      (setf value-nodes (nreverse new-nodes))
                      (setf return-types declared-ret)))))

      (make-semantic-explicit-return :type return-types
                                     :value-nodes value-nodes
                                     :source-location location))))

;; src/templates.lisp
(defun match-template-arg (raw-sig-type arg-type inference-map template-params)
  "Recursively matches sig-type against arg-type, updating inference-map.
   FIX: Resolves type aliases (e.g., FC-INT -> (FAKE-CELL INT ...)) before matching
   list structures, so def-type aliases work with template inference."
  (let ((sig-type (normalize-template-sig-type raw-sig-type)))
    (cond
     ;; 1. Template Parameter (e.g. T)
     ((member sig-type template-params)
       (let ((existing (gethash sig-type inference-map)))
         (if existing
             (equal existing arg-type)
             (progn (setf (gethash sig-type inference-map) arg-type) t))))

     ;; 2. Match Function Literal against a Function Type Pattern
     ((and (listp sig-type) (eq (first sig-type) :function-type)
           (listp arg-type) (eq (first arg-type) :function-literal))
       (let* ((name (second arg-type))
              (signatures (gethash name *function-table*)))
         (loop for sig in signatures
                 when (match-function-signature sig-type sig inference-map template-params)
                 return t)))

     ;; 3. Generic List Pattern
     ((listp sig-type)
       (or
        ;; A. Dependent Type Match
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

        ;; D. Resolve type aliases and try matching (use raw resolved form, not canonical,
        ;; to preserve keyword labels for element-by-element matching with sig-type)
        ;; e.g., FC-INT -> (FAKE-CELL INT :ADDRESS-SPACE :GLOBAL :ACCESS :READ-WRITE)
        (and (symbolp arg-type)
             (let ((resolved (resolve-type-alias arg-type)))
               (when (and resolved (not (eq resolved arg-type)) (listp resolved))
                     (log:debug "Template match: resolved alias ~a -> ~a" arg-type resolved)
                     (match-list-structure sig-type resolved inference-map template-params))))

        ;; E. Check for Template Aliases (e.g. (out-c T) -> (cell T ...))
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
                       (expanded-sig (if (and rest-args (consp expanded-base))
                                         (append expanded-base rest-args)
                                         expanded-base)))
                  (match-template-arg (canonicalize-type-specifier expanded-sig) arg-type inference-map template-params))))))

     ;; 4. Check for Symbol Alias (e.g. out-c)
     ((and (symbolp sig-type)
           (gethash sig-type *crisp-template-aliases*))
       (let* ((alias-def (gethash sig-type *crisp-template-aliases*))
              (alias-body (cdr alias-def)))
         (match-template-arg (canonicalize-type-specifier alias-body) arg-type inference-map template-params)))

     ;; 5. Concrete Type (int)
     (t (or (equal sig-type arg-type)
            (and (symbolp sig-type) (symbolp arg-type)
                 (string-equal (symbol-name sig-type) (symbol-name arg-type)))

            ;; Implicit Template Expansion: SERVER -> (SERVER T)
            (and (symbolp sig-type)
                 (gethash sig-type *template-registry*)
                 (let* ((tmpl (first (gethash sig-type *template-registry*)))
                        (params (mapcar (lambda (p) (if (consp p) (first p) p)) (template-data-parameters tmpl))))
                   (when params
                         (match-template-arg (cons sig-type params) arg-type inference-map template-params)))))))))

;;; =========================================================
;;; FIX: register-brand-definition - member-type check for parameterized brands
;;; Fixes tests 035-brand/errors/30 and 035-brand/errors/32
;;; =========================================================

;; src/types/brand.lisp
(defun register-brand-definition (struct-name brand-form)
  "Registers a brand declaration from within a struct definition.
   When the brand is active: registers as a derived type in the DAG.
   When inactive: registers as a type alias (transparent erasure).
   Parameterized brands (base type varies across template specializations,
   and the brand is NOT used as a concrete struct member type) skip global
   registration and are resolved lazily per-owner.
   Brands that conflict in base type AND appear as a concrete struct member
   in the existing owner are always an error (cannot be parameterized)."
  (cl:let* ((brand-def (if (brand-definition-p brand-form)
                           brand-form
                           (parse-brand-declaration brand-form)))
            (brand-name (brand-definition-brand-name brand-def))
            (base-type (brand-definition-base-type brand-def))
            (subst-mode (brand-definition-subst-mode brand-def))
            (is-parameterized (gethash brand-name *parameterized-brand-names*)))

    ;; Check for name collisions
    (cl:when (gethash brand-name *crisp-structs*)
          (error "Brand name collision: ~a is already defined as a struct." brand-name))
    (cl:when (gethash brand-name *function-table*)
          (error "Brand name collision: ~a is already defined as a function." brand-name))
    (cl:when (and (gethash brand-name *crisp-types*)
               (not (is-brand-type-p brand-name)))
          (error "Brand name collision: ~a is already defined as a non-brand type." brand-name))

    ;; When a brand conflict is detected (same name, different base type), determine
    ;; whether it is an illegal redefinition or a legitimate parameterized brand.
    ;;
    ;; Rule: A conflict is ILLEGAL if the brand appears as a concrete member type
    ;; in the existing owner struct.  The brand is PARAMETERIZED (allowed) only
    ;; when it appears solely in function signatures (not in member lists).
    ;;
    ;; Example - ILLEGAL (token-t IS a member of server):
    ;;   (def-struct server (brand token-t ulong ...) (active-token token-t) ...)
    ;;   (def-struct virtual-server (brand token-t float ...) ...)  ;; ERROR
    ;;
    ;; Example - ALLOWED (value-t is NOT a member of fake-cell):
    ;;   (def-record fake-cell (brand value-t T ...) (length index-t) ...)
    ;;   ;; value-t used only in function sigs => parameterized brand, ok
    (cl:unless is-parameterized
      (cl:let ((existing (is-brand-type-p brand-name)))
        (cl:when (and existing
                      (not (eq (brand-definition-base-type existing) base-type)))
          (cl:let* ((existing-owner (brand-definition-owner-struct existing))
                    (existing-struct-def (find-struct-definition-by-name existing-owner))
                    (brand-used-as-member-p
                      (and existing-struct-def
                           (some (lambda (m) (eq (second m) brand-name))
                                 (crisp-struct-definition-members existing-struct-def)))))
            (if brand-used-as-member-p
                ;; Brand is a concrete member type - conflict is an illegal redefinition
                (error "Cannot define derived type ~a: type already exists with DIFFERENT definition (Original: ~a, New: ~a)."
                       brand-name
                       (brand-definition-base-type existing)
                       base-type)
                ;; Brand is not a member type - parameterized brand (varies by template instance)
                (progn
                 (log:info "Brand ~a detected as PARAMETERIZED: base ~a (from ~a) vs ~a (from ~a)"
                           brand-name
                           (brand-definition-base-type existing) existing-owner
                           base-type struct-name)
                 (setf is-parameterized t)
                 (setf (gethash brand-name *parameterized-brand-names*) t)
                 ;; Remove previous global registration (alias table for inactive brands)
                 (remhash brand-name *crisp-type-aliases*)))))))

    ;; Store the owner struct
    (setf (brand-definition-owner-struct brand-def) struct-name)

    ;; Store in *brand-definitions* keyed by (brand-name . struct-type)
    (setf (gethash (cons brand-name struct-name) *brand-definitions*) brand-def)
    (log:info "Registered brand definition: ~a for struct ~a (base: ~a, subst: ~a, enforce: ~a~a)"
              brand-name struct-name base-type subst-mode
              (brand-definition-enforce-mode brand-def)
              (if is-parameterized ", PARAMETERIZED" ""))

    ;; Register the type based on active/inactive status.
    ;; SKIP global registration for parameterized brands (resolved lazily per owner).
    (if is-parameterized
        (log:info "Brand ~a is PARAMETERIZED - skipping global type registration (resolved lazily per owner)"
                  brand-name)
        (if (brand-active-p brand-def)
            (progn
             (log:info "Brand ~a is ACTIVE - registering as derived type of ~a with :subst ~a"
                       brand-name base-type subst-mode)
             (register-derived-type brand-name base-type subst-mode))
            (progn
             (log:info "Brand ~a is INACTIVE - registering as type alias for ~a"
                       brand-name base-type)
             (setf (gethash brand-name *crisp-type-aliases*) base-type))))))

;;; =========================================================
;;; FIX: analyze-generic-as-expression - brand application in cast type
;;; Fixes test 037-cell-branded/03-fake-cell-offset.crisp
;;; =========================================================

;; src/analysis/ops.lisp
(defun analyze-generic-as-expression (expr env context location)
  "Analyzes the generic (as type value) form.
   Extended to handle brand application forms like (index-t fc) where
   index-t is a brand, resolving to the concrete target type before validation."
  (let* ((raw-type-form (second expr))
         (value-form (third expr))

         ;; Pre-resolution: detect brand application (brand-name var-ref).
         ;; e.g. (as (index-t fc) delta) with active brand index-t resolves to
         ;; (as index-t delta), and with inactive brand resolves to (as ulong delta).
         (type-form
           (if (and (listp raw-type-form)
                    (= (length raw-type-form) 2)
                    (symbolp (first raw-type-form))
                    (symbolp (second raw-type-form))
                    (is-brand-type-p (first raw-type-form)))
               (let* ((brand-name (first raw-type-form))
                      (var-ref (second raw-type-form))
                      (brand-def (is-brand-type-p brand-name))
                      ;; Try to find per-owner brand def using var's type from env
                      (param (find var-ref env :key #'parameter-def-name))
                      (owner-type (and param (parameter-def-type param)))
                      (per-owner-def (and owner-type
                                          (find-brand-for-owner brand-name owner-type)))
                      (effective-brand-def (or per-owner-def brand-def)))
                 (cond
                  ;; Active brand, globally registered in *crisp-types* (non-parameterized):
                  ;; cast to the brand type name directly.
                  ((and effective-brand-def
                        (brand-active-p effective-brand-def)
                        (gethash brand-name *crisp-types*))
                    (log:info "AS: resolved brand application (~a ~a) -> active brand ~a"
                              brand-name var-ref brand-name)
                    brand-name)
                  ;; Active brand, parameterized (not globally registered):
                  ;; use the per-owner base type.
                  ((and effective-brand-def
                        (brand-active-p effective-brand-def))
                    (let ((base (brand-definition-base-type effective-brand-def)))
                      (log:info "AS: resolved brand application (~a ~a) -> parameterized active base ~a"
                                brand-name var-ref base)
                      base))
                  ;; Inactive brand: resolve to the alias or base type.
                  ((and effective-brand-def
                        (not (brand-active-p effective-brand-def)))
                    (let ((base (or (gethash brand-name *crisp-type-aliases*)
                                    (brand-definition-base-type effective-brand-def))))
                      (log:info "AS: resolved brand application (~a ~a) -> inactive base ~a"
                                brand-name var-ref base)
                      base))
                  ;; No brand def found: leave as-is (will fail the valid-type-p check later)
                  (t
                    (log:warn "AS: brand application (~a ~a) - no brand def found, leaving as-is"
                              (first raw-type-form) (second raw-type-form))
                    raw-type-form)))
               raw-type-form))

         (orig-type-name (if (or (symbolp type-form) (listp type-form))
                             type-form
                             (error "Generic AS expects a type specifier, got ~a" type-form)))
         ;; Generic 'AS' alias resolution
         (type-name (loop for name = orig-type-name then (gethash name *crisp-type-aliases*)
                          while (and (symbolp name) (gethash name *crisp-type-aliases*))
                          finally (cl:return name)))
         (target-type (if (symbolp type-name) (gethash type-name *crisp-types*) nil))
         (arg-node (analyze-expression value-form env context (append location '(2)))))

    (unless (or target-type (valid-type-p type-name))
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; No casting of voidp
    (when (or (eq type-name 'voidp)
              (and target-type (eq (crisp-type-category target-type) :void)))
          (error 'crisp-compiler-error :message "Cannot cast to 'voidp'. Use a specific pointer type or handle." :source-location location))

    (make-semantic-value-cast :type type-name :arg arg-node :source-location location)))

;;;; ===========================================================================
;;;; Fix for 037-cell-branded/07-fake-cell-incomplete.crisp
;;;; Incomplete struct template dispatch via MAKE-X%DISPATCH CL macro.
;;;;
;;;; When a struct template has :c-t fields with no default (incomplete), we
;;;; store partial instantiation info and install a CL macro for MAKE-X%DISPATCH.
;;;; When that macro is expanded (at Crisp analysis time), the dispatch converts
;;;; positional args back to keyword args and calls the partial struct's own
;;;; constructor directly (which validates the required incomplete CT values).
;;;;
;;;; The return type is the PARTIAL mangled type (e.g. FAKE-CELL_INT), which has
;;;; 1 template type arg and therefore allows template resolvers for ~ and set-~
;;;; (also arity 1) to correctly infer T=INT from FAKE-CELL_INT.
;;;; ===========================================================================

;; src/templates.lisp
(defvar *partial-template-instantiations* (make-hash-table :test 'eq)
  "Maps template name symbols to lists of partial instantiation plists.
   Each plist has keys:
     :partial-mangled-name - symbol for the partial concrete type (e.g. FAKE-CELL_INT)
     :data-members         - ordered data-member specs (excluding brand forms)")

;; src/templates.lisp
(defun %dispatch-incomplete-template (template-name all-args)
  "Called at CL macro expansion time when MAKE-X%DISPATCH expands for an incomplete
   struct template. Maps positional args back to keyword args and calls the partial
   struct's constructor with all values (including the required incomplete CT ones).
   Returns a direct constructor call whose result type is the partial mangled type
   (e.g. FAKE-CELL_INT), preserving correct arity for template function resolution."
  (let* ((partials (gethash template-name *partial-template-instantiations*))
         (partial  (or (first partials)
                       (error "DISPATCH-INCOMPLETE: No partial instantiation for ~a" template-name)))
         (partial-mangled  (getf partial :partial-mangled-name))
         (data-members     (getf partial :data-members))
         ;; Constructor for the partial type (e.g. MAKE-FAKE-CELL_INT)
         (constructor-name (intern (format nil "MAKE-~a" partial-mangled)
                                   (symbol-package template-name)))
         ;; Map positional args back to keyword args using data-member names
         (keyword-call-args
           (loop for m in data-members
                 for i from 0
                 for member-name = (first m)
                 for kw = (intern (symbol-name member-name) :keyword)
                 when (< i (length all-args))
                 collect kw
                 and collect (nth i all-args))))
    (log:info "DISPATCH-INCOMPLETE: ~a -> ~a with keyword args ~a"
              template-name constructor-name keyword-call-args)
    `(,constructor-name ,@keyword-call-args)))

;; src/templates.lisp
(defun %instantiate-structure-template (name body substitutions concrete-types)
  "Instantiates a struct template with the given substitutions and concrete types.
   For incomplete templates (those with :c-t fields lacking a default value), stores
   partial instantiation info in *partial-template-instantiations* and installs a CL
   macro for MAKE-X%DISPATCH so dispatch can complete the type at call-site expansion.
   For complete templates, generates the wrapper def-function and registers the overload
   as before."
  (let* ((mangled-name       (mangle-template-struct-name name concrete-types))
         (substituted-body   (sublis substitutions (subst mangled-name name body)))
         (members            (cddr substituted-body))
         (data-members       (remove-if (lambda (m)
                                          (and (consp m)
                                               (string-equal (symbol-name (car m)) "BRAND")))
                                        members))
         (all-parsed-members (mapcar #'parse-struct-member-spec data-members))
         ;; Remove only INCOMPLETE :c-t fields (nil fourth) from the wrapper param list
         (parsed-members     (remove-if (lambda (m)
                                          (and (consp m) (eq (third m) :c-t) (not (fourth m))))
                                        all-parsed-members))
         (param-names        (mapcar #'first parsed-members))
         (wrapper-name       (intern (format nil "MAKE-~a_WRAPPER" mangled-name)
                                     (symbol-package name)))
         (constructor-alias  (intern (format nil "MAKE-~a%DISPATCH" name)
                                     (symbol-package name)))
         (mangled-constructor (intern (format nil "MAKE-~a" mangled-name)
                                      (symbol-package name)))
         (keyword-args       (loop for pname in param-names
                                   collect (intern (symbol-name pname) :keyword)
                                   collect pname))
         (incomplete-fields  (remove-if-not (lambda (m)
                                              (and (consp m) (eq (third m) :c-t) (null (fourth m))))
                                            all-parsed-members)))
    ;; Side-effect: for incomplete types, store partial info and install dispatch macro
    (when incomplete-fields
      (log:info "INSTANTIATE-STRUCT-TEMPLATE: ~a is incomplete (missing CT: ~a), storing partial"
                mangled-name (mapcar #'first incomplete-fields))
      (push (list :partial-mangled-name mangled-name
                  :data-members         data-members)
            (gethash name *partial-template-instantiations*))
      ;; Install MAKE-X%DISPATCH as a CL macro (once per template name)
      (unless (macro-function constructor-alias)
        (let ((tname name))
          (setf (macro-function constructor-alias)
                (lambda (whole-form env)
                  (declare (ignore env))
                  (%dispatch-incomplete-template tname (rest whole-form)))))))
    `(progn
       ,substituted-body
       ;; Wrapper + overload registration only for complete types
       ,@(unless incomplete-fields
           `((def-function ,wrapper-name ,parsed-members
                           (declare (return-type ,mangled-name))
                           (return (,mangled-constructor ,@keyword-args)))
             (eval-when (:compile-toplevel :load-toplevel :execute)
               (register-overload ',constructor-alias ',wrapper-name)))))))


;;;; ===========================================================================
;;;; Fix for analyze-struct-construction: use get-single-value-type
;;;;
;;;; When an arg to a struct constructor is a function call (e.g. (parent~ c-in)),
;;;; (semantic-node-type node) returns the raw return-types list ((STORAGE GLOBAL))
;;;; rather than the single type (STORAGE GLOBAL).  get-single-value-type
;;;; correctly unwraps that wrapper so type comparison succeeds.
;;;;
;;;; Destination: src/analysis/structs.lisp
;;;; ===========================================================================

;; src/analysis/structs.lisp
(defun analyze-struct-construction (expr env context location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form.
   Supports implicit promotion of base-type values to branded member types
   in struct constructors (the birthplace of branded values).
   Uses get-single-value-type to normalize function-call return type lists
   (e.g. ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)) before type comparison."
  (let* ((type-name (second expr))
         (args (cddr expr))
         (struct-def (lookup-struct-definition type-name)))
    (unless struct-def
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Validate argument count against original members (excluding compile-time properties)
    (let* ((all-members (crisp-struct-definition-members struct-def))
           (members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) all-members)))
      (unless (= (length args) (length members))
        (error "Struct constructor for ~a expects ~a arguments, got ~a."
          type-name (length members) (length args)))

      ;; Analyze arguments
      (let ((arg-nodes
             (loop for arg in args
                   for member in members
                   for i from 0
                   collect (let ((node (analyze-expression arg env context (append location (list (+ 2 i)))))
                                 (expected-type (second member)))
                             ;; get-single-value-type unwraps ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)
                             ;; for function-call nodes whose semantic-call-type is a return-types list
                             (let ((arg-type (get-single-value-type node)))
                               (log:debug "STRUCT-CTOR ~a member ~a: arg-type=~a expected=~a"
                                          type-name (first member) arg-type expected-type)
                               ;; Type check with branded type promotion
                               (unless (type-equal-p arg-type expected-type)
                                 (cl:let ((brand-def (is-brand-type-p expected-type)))
                                   (if brand-def
                                       ;; Branded member: check numeric compatibility with base type
                                       (cl:let* ((base-type (brand-definition-base-type brand-def))
                                                 (arg-cat (numeric-type-category arg-type))
                                                 (base-cat (numeric-type-category base-type)))
                                         (if (and arg-cat base-cat)
                                             ;; Compatible numeric types - wrap in a value cast to the base type
                                             (progn
                                              (log:debug "Constructor promotion: ~a -> ~a (base ~a) for member ~a"
                                                         arg-type expected-type base-type (first member))
                                              (setf node (make-semantic-value-cast
                                                          :type base-type
                                                          :arg node
                                                          :source-location (append location (list (+ 2 i))))))
                                             ;; Not numeric-compatible
                                             (error 'crisp-type-error
                                               :expected expected-type
                                               :inferred arg-type
                                               :source-location location)))
                                       ;; Not a branded member -> real type error
                                       (error 'crisp-type-error
                                         :expected expected-type
                                         :inferred arg-type
                                         :source-location location))))
                               node)))))

        (make-semantic-struct-construction
         :type type-name
         :args arg-nodes
         :source-location location)))))


;;;; ===========================================================================
;;;; Fix for detect-and-register-implicit-template: concrete structs are complete
;;;;
;;;; When SET-~ is instantiated with T=INT its param c has type FAKE-CELL_INT.
;;;; FAKE-CELL_INT is registered in *crisp-structs* (it's a concrete struct), but
;;;; it has a :c-t member (access) with no default -- so incomplete-type-p returns T.
;;;; This causes detect-and-register-implicit-template to (wrongly) treat SET-~ as
;;;; an implicit template, removing it from *function-table* before the overload can
;;;; be used, causing "No matching function overload found for SET-~".
;;;;
;;;; Fix: in the implicit-args collection loop, guard the incomplete-type-p check
;;;; with (not (find-struct-definition-by-name ptype)).  A type with a registered
;;;; concrete struct definition IS a complete type for function-signature purposes.
;;;;
;;;; Destination: src/environment.lisp
;;;; ===========================================================================

;; src/environment.lisp
(defun detect-and-register-implicit-template (name explicit-env return-type params body declarations)
  "Detects if a function is an implicit template (e.g. has function-type args),
   and if so, registers it as a template and returns T. Otherwise returns NIL.

   A type is treated as incomplete only if incomplete-type-p says so AND the type
   does NOT have a registered concrete struct definition.  Concrete registered
   structs (like FAKE-CELL_INT) are fully resolved types even when they contain
   :c-t members with no default value."
  (when (or (find 'crisp-system-generated body :key (lambda (x) (if (listp x) (car x) x)) :test #'eq)
            (find 'crisp-system-generated declarations :key (lambda (x) (if (listp x) (car x) x)) :test #'eq))
        (return-from detect-and-register-implicit-template nil))

  (let ((implicit-args (loop for p in explicit-env
                             for pname = (parameter-def-name p)
                             for ptype = (parameter-def-type p)
                               when (or (and (listp ptype) (eq (first ptype) :function-type))
                                        ;; Only treat as incomplete if it has no registered struct definition.
                                        ;; Concrete mangled types like FAKE-CELL_INT are complete types.
                                        (and (incomplete-type-p ptype)
                                             (not (and (symbolp ptype)
                                                       (find-struct-definition-by-name ptype)))))
                             collect p)))
    (when implicit-args
          (log:info "Detected implicit template candidates in function ~a: ~a" name implicit-args)
          ;; REMOVE from function table because register-function-signature already put it there!
          (remhash name *function-table*)

          ;; Convert to template
          (let* ((template-params (loop for i from 0 repeat (length implicit-args) collect (intern (format nil "<IMPLICIT-F-~a>" i))))
                 (subst-map (loop for p in implicit-args
                                  for tparam in template-params
                                  collect (cons (parameter-def-name p) tparam)))
                 ;; Reconstruct environment with template params
                 (new-env (loop for p in explicit-env
                                collect (let ((match (assoc (parameter-def-name p) subst-map)))
                                          (if match
                                              (make-parameter-def
                                               :name (parameter-def-name p)
                                               :type (cdr match)
                                               :kind (parameter-def-kind p)
                                               :is-optional (parameter-def-is-optional p)
                                               :is-key (parameter-def-is-key p)
                                               :default-value (parameter-def-default-value p)
                                               :source-location (parameter-def-source-location p))
                                              p))))
                 ;; Construct signature for inference
                 (signature-list (append (mapcar #'parameter-def-type new-env) '(=>) return-type))
                 ;; Reconstruct body form using signature
                 (new-def-form `(def-function ,name ,params (declare (function ,signature-list)) ,@body)))

            (log:info "Registering implicit template ~a with params ~a" name template-params)
            (register-template name template-params nil new-def-form signature-list)
            t))))
