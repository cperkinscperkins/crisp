;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/types/validation.lisp
#|
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
        |#

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
#|
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

             |#

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
#|
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

             |#

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
#|
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

         |#


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
#|
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
            |#


;;;; ===========================================================================
;;;; Fix: clear *brand-instance-cache* in initialize-compiler
;;;;
;;;; *brand-instance-cache* maps (brand-name . var-name) -> gensym.
;;;; initialize-compiler clears *type-derivation-graph* (via
;;;; initialize-type-hierarchy) but did NOT clear *brand-instance-cache*.
;;;;
;;;; This means that after initialize-compiler, stale gensyms remain in the
;;;; cache.  When a subsequent compilation reuses the same (brand-name . var)
;;;; pair, resolve-brand-type returns the stale gensym WITHOUT calling
;;;; register-derived-type.  The gensym is then absent from the fresh type
;;;; graph, so is-substitutable-for? returns NIL, types-compatible-p falls
;;;; through to unmangle-template-struct-name, which crashes on uninterned
;;;; symbols with (intern name NIL) -> "The name NIL does not designate any
;;;; package."
;;;;
;;;; Fix: add (clrhash *brand-instance-cache*) alongside the other resets.
;;;;
;;;; Destination: src/compiler.lisp
;;;; ===========================================================================

;; src/compiler.lisp
#|
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system to use stderr (important for stdout IR capture)
  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy) ;; Initialize type derivation graph (DAG)
  (clrhash *function-table*) ;; Reset function table
  (clrhash *crisp-structs*) ;; Reset struct definitions
  (clrhash *crisp-type-aliases*) ;; Reset type aliases
  (clrhash *crisp-template-aliases*) ;; Reset template aliases
  (clrhash *generic-functions*) ;; Reset generic functions
  (clrhash *kernel-declared-signatures*) ;; Reset kernel signatures
  (when (boundp '*record-definitions*) (clrhash *record-definitions*)) ;; Reset records (if defined)

  (setf *compiled-kernels* nil) ;; Reset compiled kernels list

  (initialize-expression-analyzers) ;; In analysis.lisp, but usually registered.
  ;; Note: analysis.lisp initializes *expression-analyzers* entries via def-expression-analyzer.
  ;; Wait, where is initialize-expression-analyzers defined?
  ;; It is usually in analysis.lisp.
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Register intrinsic `die`
  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache.
  ;; CRITICAL: must be cleared whenever *type-derivation-graph* is reset.
  ;; Stale gensyms in the cache are no longer registered in the fresh graph,
  ;; causing is-substitutable-for? to return NIL and crashing unmangle.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))

  ;; Initialize built-in structs (storage)
  (register-builtins))
  |#


;;;; ===========================================================================
;;;; Fix: guard unmangle-template-struct-name against uninterned gensyms
;;;;
;;;; Brand instance gensyms (e.g. #:TOKEN-T-204) are uninterned symbols
;;;; (symbol-package = NIL).  When types-compatible-p check 6 calls
;;;; unmangle-template-struct-name on such a gensym, the no-underscore branch
;;;; executes (cl:intern name NIL) which signals "The name NIL does not
;;;; designate any package."
;;;;
;;;; These gensyms can never be mangled struct names, so the correct result
;;;; for an uninterned symbol is NIL (no unmangle possible).
;;;;
;;;; Destination: src/mangling.lisp
;;;; ===========================================================================

;; src/mangling.lisp
#|
(cl:defun unmangle-template-struct-name (symbol)
  "Attempts to reverse mangling for known parameterized types like CELL.
   Returns the list form (e.g. (CELL FLOAT :GLOBAL :READ-WRITE)) or NIL.
   Returns NIL immediately for uninterned symbols (gensyms produced by
   brand instance differentiation) since they cannot be mangled struct names."
  (cl:when (cl:symbolp symbol)
    ;; Uninterned gensyms (brand instance types like #:TOKEN-T-204) have no
    ;; package and can never be a mangled struct name.  Return NIL early to
    ;; avoid the (intern name NIL) crash that follows.
    (cl:unless (cl:symbol-package symbol)
      (cl:return-from unmangle-template-struct-name nil))
    (cl:let ((name (cl:symbol-name symbol)))
      (cl:if (cl:find #\_ name)
          (cl:let* ((parts (split-string name #\_))
                    (base (cl:first parts))
                    (reconstructed (reconstruct-template-args (cl:rest parts) (cl:symbol-package symbol))))
            (cl:if base
                (cl:let ((base-sym (cl:intern base (cl:symbol-package symbol))))
                  `(,base-sym ,@reconstructed))
                nil))
          ;; No underscore: symbol is a bare type name (e.g. SHIRT -> (SHIRT))
          `(,(cl:intern name (cl:symbol-package symbol)))))))
|#

;;;; ===========================================================================
;;;; Fix: detect-and-register-implicit-template guard is too broad
;;;;
;;;; The previous overlay guarded incomplete-type-p with:
;;;;   (not (and (symbolp ptype) (find-struct-definition-by-name ptype)))
;;;;
;;;; This blocked ALL registered struct types — including legitimate incomplete
;;;; types like PANTS (required :c-t field) and SHIRT (template with arity > 0)
;;;; — from being recognized as implicit template parameters.
;;;;
;;;; Effect:
;;;;   - 011-incomplete-types/02: SIZE~ accessor for shirt template not found
;;;;     for SHIRT_INT_STITCHING-C_BLACK arguments.
;;;;   - 011-incomplete-types/03: remeasure(p: PANTS) treated as concrete;
;;;;     OP-ONLY-BLUE call with bare PANTS fails type check.
;;;;
;;;; Root cause: the guard should only block MANGLED/INSTANTIATED types — those
;;;; that have already been concretely specialized, like FAKE-CELL_INT.  These
;;;; always contain an underscore (_) in their name because the mangling scheme
;;;; encodes template arguments with underscores.  Bare base names like PANTS
;;;; and SHIRT never contain underscores and must remain eligible to be treated
;;;; as incomplete types (i.e., implicit template parameters).
;;;;
;;;; Fix: add (cl:find #\_ (cl:symbol-name ptype)) to the guard, so only
;;;; mangled concrete types are excluded.
;;;;
;;;; Destination: src/environment.lisp
;;;; ===========================================================================

;; src/environment.lisp
#|
(defun detect-and-register-implicit-template (name explicit-env return-type params body declarations)
  "Detects if a function is an implicit template (e.g. has function-type args
   or incomplete-type parameters), and if so registers it as a template and
   returns T.  Otherwise returns NIL.

   A type is treated as incomplete only if incomplete-type-p says so AND the
   type is NOT a mangled/instantiated concrete struct (i.e. its name contains
   an underscore AND has a registered struct definition).  Bare base names such
   as PANTS and SHIRT have no underscore and remain eligible as implicit
   template parameters even though they are in *crisp-structs*."
  (when (or (find 'crisp-system-generated body
                  :key (lambda (x) (if (listp x) (car x) x)) :test #'eq)
            (find 'crisp-system-generated declarations
                  :key (lambda (x) (if (listp x) (car x) x)) :test #'eq))
        (return-from detect-and-register-implicit-template nil))

  (let ((implicit-args
          (loop for p in explicit-env
                for pname = (parameter-def-name p)
                for ptype = (parameter-def-type p)
                  when (or (and (listp ptype) (eq (first ptype) :function-type))
                           ;; Only exclude as complete if it is a MANGLED concrete type.
                           ;; Mangled instantiated types (FAKE-CELL_INT, SHIRT_INT_...) have '_'
                           ;; in their name.  Bare template/base names (PANTS, SHIRT) do not,
                           ;; so they remain incomplete and eligible as implicit template params.
                           (and (incomplete-type-p ptype)
                                (not (and (symbolp ptype)
                                          (cl:find #\_ (cl:symbol-name ptype))
                                          (find-struct-definition-by-name ptype)))))
                collect p)))
    (when implicit-args
          (log:info "Detected implicit template candidates in function ~a: ~a" name implicit-args)
          ;; REMOVE from function table because register-function-signature already put it there!
          (remhash name *function-table*)

          ;; Convert to template
          (let* ((template-params
                   (loop for i from 0 repeat (length implicit-args)
                         collect (intern (format nil "<IMPLICIT-F-~a>" i))))
                 (subst-map
                   (loop for p in implicit-args
                         for tparam in template-params
                         collect (cons (parameter-def-name p) tparam)))
                 ;; Reconstruct environment with template params substituted in
                 (new-env
                   (loop for p in explicit-env
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
                 (signature-list
                   (append (mapcar #'parameter-def-type new-env) '(=>) return-type))
                 ;; Reconstruct the def-function form for the template registry
                 (new-def-form
                   `(def-function ,name ,params (declare (function ,signature-list)) ,@body)))

            (log:info "Registering implicit template ~a with params ~a" name template-params)
            (register-template name template-params nil new-def-form signature-list)
            t))))
            |#

;; ============================================================
;; FIX: extract-positional-from-keyword-args
;; src/types/validation.lisp  (originally in this overlay, lines 9-29)
;;
;; Two calling conventions exist for type specs with more args than arity:
;;
;; 1. LABELED style (CELL-like user records, e.g. fake-cell):
;;      (fake-cell int :address-space :global :access :read-write)  arity=3
;;      -> label-strip -> (int :global :read-write)   [3 = arity] -> USE IT
;;
;; 2. POSITIONAL+C-T style (template structs with compile-time overrides):
;;      (shirt int :blue :stitching-c :black)  arity=2
;;      -> label-strip -> (int :stitching-c :black)   [3 != arity] -> FALLBACK
;;      -> head-truncate -> (int :blue)                              -> USE IT
;;
;; Disambiguation heuristic: try label-stripping first.  If the result has
;; exactly NUM-PARAMS elements the labeled convention was used.  Otherwise
;; the extra args are c-t overrides; take only the first NUM-PARAMS args.
;; ============================================================
;; src/types/validation.lisp
#|
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

            |#

;;;; ===========================================================================
;;;; Fix: Brand instance type tracking and safe cross-instance arithmetic blocking
;;;;
;;;; Problem (with :descendant registration, original):
;;;;   resolve-brand-type registers gensym instances as :descendant of the brand
;;;;   type.  This means GENSYM-A.ancestors = [brand-name] and GENSYM-B.ancestors
;;;;   = [brand-name].  find-common-promoted-type(GENSYM-A, GENSYM-B) finds
;;;;   brand-name as a common ancestor and allows (+ GENSYM-A GENSYM-B).  This is
;;;;   WRONG for --differentiate: two different variable instances of the same
;;;;   brand should NOT compose in arithmetic.
;;;;
;;;; Problem (with :ancestor registration, the failed attempt):
;;;;   GENSYM.ancestors = [], so GENSYM cannot substitute for brand-name.
;;;;   Return-type checks like "Expected (TOKEN-T) but inferred (TOKEN-T-213)"
;;;;   fail because the function body produces a gensym but the declared return
;;;;   type is the brand name.
;;;;
;;;; Solution:
;;;;   1. Keep :descendant registration (gensym IS-A brand → return-type checks
;;;;      pass via is-substitutable-for?(gensym, brand)).
;;;;   2. Track all gensym brand instances in *brand-instance-types* (gensym ->
;;;;      brand-name).
;;;;   3. Override resolve-dominance to:
;;;;        a. Block same-brand cross-instance arithmetic (GENSYM-A + GENSYM-B
;;;;           where both have the same brand → NIL).
;;;;        b. Preserve brand instance type when mixing with compatible base types
;;;;           (GENSYM-A * int → GENSYM-A, not brand-name, when brand dominates
;;;;           int via the :ancestor relationship).
;;;;
;;;; src/types/brand.lisp (new state var)
;;;; ===========================================================================
#|
(defvar *brand-instance-types* (make-hash-table :test 'equal)
  "Maps gensym brand-instance type names (created by resolve-brand-type) to
   the brand-name they instantiate.  Consulted by resolve-dominance to block
   cross-instance arithmetic and to preserve instance types in arithmetic
   with the brand's base type.
   Cleared alongside *brand-instance-cache* in initialize-compiler.")
   |#

;; src/types/brand.lisp
#|
(defun resolve-brand-type (brand-name var-ref)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref).
   On first call for a given pair, creates a new type node in the DAG
   as a :descendant of brand-name, caches it, and returns it.
   On subsequent calls, returns the cached gensym.

   The :descendant relationship means:
   - The gensym CAN substitute for brand-name (return-type / signature checks work)
   - Two different gensyms cannot substitute for each other (instance safety)
   - Cross-instance arithmetic is blocked by resolve-dominance using
     *brand-instance-types* rather than relying on the DAG structure."
  (cl:let* ((cache-key (cons brand-name var-ref))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let ((gensym-name (gensym (format nil "~a-" brand-name))))
          ;; Register as a derived type: descendant of the brand type.
          ;; This establishes: gensym -> brand-name in the ancestor chain,
          ;; so the gensym is substitutable for the brand (a subtype).
          (register-derived-type gensym-name brand-name :descendant)
          ;; Track this gensym in *brand-instance-types* so resolve-dominance
          ;; can identify it and apply brand-aware arithmetic rules.
          (setf (gethash gensym-name *brand-instance-types*) brand-name)
          ;; Cache for this compilation run's lifetime.
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a)"
                    gensym-name brand-name var-ref)
          gensym-name))))
          |#

;; src/compiler.lisp
#|
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system to use stderr (important for stdout IR capture)
  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy) ;; Initialize type derivation graph (DAG)
  (clrhash *function-table*) ;; Reset function table
  (clrhash *crisp-structs*) ;; Reset struct definitions
  (clrhash *crisp-type-aliases*) ;; Reset type aliases
  (clrhash *crisp-template-aliases*) ;; Reset template aliases
  (clrhash *generic-functions*) ;; Reset generic functions
  (clrhash *kernel-declared-signatures*) ;; Reset kernel signatures
  (when (boundp '*record-definitions*) (clrhash *record-definitions*)) ;; Reset records (if defined)

  (setf *compiled-kernels* nil) ;; Reset compiled kernels list

  (initialize-expression-analyzers) ;; In analysis.lisp, but usually registered.
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Register intrinsic `die`
  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache and brand instance type tracking.
  ;; CRITICAL: must be cleared whenever *type-derivation-graph* is reset.
  ;; Stale gensyms in the cache are no longer registered in the fresh graph,
  ;; causing is-substitutable-for? to return NIL and crashing unmangle.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Initialize built-in structs (storage)
  (register-builtins))
  |#

;; src/types/hierarchy.lisp
#|
(defun resolve-dominance (type-a type-b)
  "Determines which type dominates in arithmetic operations.
   Returns the dominant type, or NIL if they cannot mix.

   Standard rules:
   - If same type, return it
   - If one can substitute for the other, return the more general (target)

   Brand instance rules (applied when standard substitutability fails):
   - If both are brand instances of the SAME brand (but different variables),
     they CANNOT mix -> return NIL.  This enforces instance isolation under
     --differentiate.
   - If one is a brand instance and the brand dominates the other type (via
     find-common-promoted-type), the brand INSTANCE dominates (not just the
     brand-name), preserving instance-specific type information through
     arithmetic (e.g. (* (~ A) 2) -> same gensym type as (~ A)).

   Fallback:
   - find-common-promoted-type for all other cases."
  (cl:cond
    ((eq type-a type-b) type-a)

    ;; Check substitutability (one dominates)
    ((is-substitutable-for? type-a type-b) type-b) ; B is more general
    ((is-substitutable-for? type-b type-a) type-a) ; A is more general

    ;; Brand instance dominance rules
    (t
     (cl:let ((brand-a (and (boundp '*brand-instance-types*)
                            (gethash type-a *brand-instance-types*)))
              (brand-b (and (boundp '*brand-instance-types*)
                            (gethash type-b *brand-instance-types*))))
       (cl:cond
         ;; Both are instances of the SAME brand -> incompatible, cannot mix
         ((and brand-a brand-b (eq brand-a brand-b))
          (log:debug "resolve-dominance: blocking cross-instance mix of ~a and ~a (both brand ~a)"
                     type-a type-b brand-a)
          nil)

         ;; A is a brand instance; check if the brand (not the gensym) dominates B.
         ;; If so, preserve the instance-specific type by returning type-a, not brand-a.
         ((and brand-a
               (find-common-promoted-type brand-a type-b))
          (log:debug "resolve-dominance: brand instance ~a dominates ~a (via brand ~a)"
                     type-a type-b brand-a)
          type-a)

         ;; B is a brand instance; check if the brand dominates A.
         ((and brand-b
               (find-common-promoted-type brand-b type-a))
          (log:debug "resolve-dominance: brand instance ~a dominates ~a (via brand ~a)"
                     type-b type-a brand-b)
          type-b)

         ;; Normal: find common promoted type using reachability intersection
         (t
          (cl:let ((common-type (find-common-promoted-type type-a type-b)))
            (log:debug "resolve-dominance: common promoted type for ~a + ~a = ~a"
                       type-a type-b common-type)
            common-type)))))))
            |#

;;;; ===========================================================================
;;;; Add value-t and index-t brands to the real CELL template
;;;; ===========================================================================
;;;
;;; By adding (brand value-t To :subst :ancestor :enforce :diff) to cell's
;;; def-record, every instantiated cell type (e.g. CELL_INT_GLOBAL_READ-WRITE)
;;; gets a value-t brand entry in *brand-definitions*.  When --differentiate is
;;; active that brand is live, letting analyze-aref-expression issue per-variable
;;; gensym types and thereby block cross-instance arithmetic via resolve-dominance.
;;;
;;; index-t is included for completeness (mirrors fake-cell); it brands offset
;;; (index) values but is not yet exercised by any current test.

;; src/compiler.lisp
#|
(defun register-builtins ()
  "Registers built-in types and structs like 'storage' and 'cell' using def-struct
   semantics.  Cell now carries value-t and index-t brands for --differentiate mode."
  (log:info "Registering built-in structs...")

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
                             (def-record storage
                                         (address (c-pointer :address-space Addr))
                                         (byte-size ulong)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t :read-write))))

  ;; CELL: opaque handle to a storage slice, with brands for --differentiate.
  ;;   value-t To  - brands element reads so different cell vars produce distinct types
  ;;   index-t ulong - brands offset values (not yet used by tests)
  ;; Both brands use :subst :descendant (brand IS-A the base type, substitutable for it),
  ;; :enforce :diff (only active when *differentiate-p* is T).
  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
                             (def-record cell
                                         (brand value-t To :subst :descendant :enforce :diff)
                                         (brand index-t ulong :subst :descendant :enforce :diff)
                                         (parent (storage Addr))
                                         (offset ulong)
                                         (element-type type-spec :c-t To)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t Acc))))

  ;; bytes~ helper: compile-time sizeof for cell element type.
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
                     '(def-function bytes~ (c)
                                    (declare (function ((cell To Addr Acc) => ulong)))
                                    (declare (crisp-system-generated))
                                    (return (sizeof To)))
                     '((cell To Addr Acc) => ulong))

  (log:info "Built-in structs registered."))
  |#

;;;; ===========================================================================
;;;; Brand-aware analyze-aref-expression for real cell reads
;;;; ===========================================================================
;;;
;;; When --differentiate is active and a real cell type has an active value-t
;;; brand, (~ cell-var) now returns a per-variable gensym type rather than the
;;; raw element type.  This threads instance identity through arithmetic so that
;;; resolve-dominance can block cross-instance operations such as (+ (~ A) (~ B)).
;;;
;;; The original code path is preserved for:
;;;   - Write-mode access (set! targets): no brand resolution, raw elem-type used.
;;;   - Inactive brands (no --differentiate): brand-def is found but brand-active-p
;;;     is NIL, so resolved-type falls back to elem-type.
;;;   - Missing target-sym (complex subexpressions): brand resolution skipped.

;; src/analysis/structs.lisp
#|
(defun analyze-aref-expression (expr env context location)
  "Analyzes a cell dereference expression (~ cell-var [index]).
   For real cell types with an active value-t brand and a known target-sym,
   returns a per-instance gensym type to enable --differentiate tracking."
  (let* ((op (first expr))
         (target-sym (if (symbolp (second expr)) (second expr) nil))
         (array-node (analyze-expression (second expr) env context (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env context (append location '(2)))
                         ;; Default to index 0 if not provided (e.g. `(~ ptr)`)
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    ;; Check for invalid READ access on &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
          (let ((binding (find-variable-in-env target-sym env)))
            (when (and binding (eq (parameter-def-kind binding) :out))
                  (error 'crisp-illegal-access-error
                    :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." target-sym)
                    :source-location location))))

    (if elem-type
        (progn
         ;; Check for VOID element type
         (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "VOID"))
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "T"))
                            (and (consp elem-type)
                                 (let ((head (first elem-type)))
                                   (or (eq head 'void) (eq head 'T)
                                       (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
           (when is-void
                 (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

         ;; Brand-aware type resolution: when --differentiate is active, the cell
         ;; has an active value-t brand, and we know the source variable (target-sym),
         ;; resolve to a per-instance gensym type so arithmetic across different
         ;; instances is blocked by resolve-dominance.
         ;;
         ;; Skip brand resolution for write-mode (set! target); set! does not
         ;; type-check the value against the target, so the raw elem-type suffices.
         (let* ((cell-type (semantic-node-type array-node))
                (brand-def (and target-sym
                                (not (eq *analysis-access-mode* :write))
                                (find-brand-for-owner 'value-t cell-type)))
                (resolved-type (if (and brand-def (brand-active-p brand-def))
                                   (progn
                                     (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a"
                                               cell-type target-sym)
                                     (resolve-brand-type 'value-t target-sym))
                                   elem-type)))
           (make-semantic-aref :type resolved-type
                               :array-node array-node
                               :index-node index-node
                               :source-location location)))
        ;; Fallback: If not an array/pointer, and op is ~, try as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))

              |#
;; NOTE: this first analyze-aref-expression is superseded by the redefinition below.

;;;; ===========================================================================
;;;; Fix: resolve-brand-type -- handle parameterized brands
;;;; ===========================================================================
;;;
;;; When the same brand name (e.g. value-t) is used across multiple template
;;; specialisations with DIFFERENT base types (cell long, cell float, etc.),
;;; register-brand-definition marks value-t as *parameterized*, removes its DAG
;;; ancestor, and skips future DAG registrations.  This means VALUE-T-212 only
;;; has value-t in its ancestor chain, value-t has NO ancestors, and therefore
;;; VALUE-T-212 is NOT substitutable for the concrete element type (long, float…).
;;; Return-type checks then fail with "Expected (LONG) but inferred (VALUE-T-212)".
;;;
;;; Fix: accept an optional BASE-TYPE argument.  When brand-name is parameterized
;;; and a BASE-TYPE is known, register the gensym as a descendant of BASE-TYPE
;;; directly (bypassing the parameterised, ancestor-less brand name).  The gensym
;;; is still recorded in *brand-instance-types* under BRAND-NAME so that
;;; resolve-dominance can block cross-instance arithmetic.

;; src/types/brand.lisp
#|
(defun resolve-brand-type (brand-name var-ref &optional base-type)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref).

   On first call, creates a new type node in the DAG:
   - If brand-name is parameterised AND base-type is supplied, the gensym is
     registered as a :descendant of base-type so it is substitutable for the
     concrete element type in return-type checks.
   - Otherwise the gensym is registered as a :descendant of brand-name.

   In both cases the gensym is stored in *brand-instance-types* under brand-name
   so that resolve-dominance can identify and block cross-instance arithmetic.

   On subsequent calls for the same (brand-name . var-ref) pair, returns the
   cached gensym."
  (cl:let* ((cache-key (cons brand-name var-ref))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let* ((gensym-name (gensym (format nil "~a-" brand-name)))
                  (is-parameterized (and base-type
                                         (boundp '*parameterized-brand-names*)
                                         (gethash brand-name *parameterized-brand-names*)))
                  (ancestor (if is-parameterized base-type brand-name)))
          ;; Register gensym in the type DAG under the chosen ancestor.
          (register-derived-type gensym-name ancestor :descendant)
          ;; Track under brand-name (not ancestor) so resolve-dominance works.
          (setf (gethash gensym-name *brand-instance-types*) brand-name)
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a) [ancestor: ~a~a]"
                    gensym-name brand-name var-ref ancestor
                    (if is-parameterized " (parameterized-bypass)" ""))
          gensym-name))))
          |#

;;;; ===========================================================================
;;;; Fix: resolve-dominance -- brand instances checked BEFORE substitutability
;;;; ===========================================================================
;;;
;;; With :subst :descendant, a brand instance (VALUE-T-212) IS substitutable for
;;; its base type (int).  The OLD resolve-dominance evaluated substitutability
;;; FIRST, so (resolve-dominance VALUE-T-212 int) returned INT (more general),
;;; losing the brand identity.  Test 15 (value-t-dominates) expects VALUE-T-212
;;; to survive (* v1 2) unchanged.
;;;
;;; Fix: evaluate brand-instance rules BEFORE substitutability:
;;;   1. eq  -> trivially same type
;;;   2. both same-brand instances -> NIL (cross-instance blocked)
;;;   3. one brand instance, one plain -> brand instance always dominates
;;;   4. both non-brand -> standard substitutability / find-common-promoted-type

;; src/types/hierarchy.lisp
#|
(defun resolve-dominance (type-a type-b)
  "Determines which type dominates in arithmetic operations.
   Returns the dominant type, or NIL if the types cannot mix.

   Brand-instance rules are applied BEFORE substitutability so that a brand
   instance always wins over the plain type it descends from:
   - Same type: return it.
   - Both instances of the SAME brand (different vars): cannot mix -> NIL.
   - One brand instance, one non-brand: brand instance dominates.
   - Neither is a brand instance: standard substitutability /
     find-common-promoted-type."
  (cl:cond
    ((eq type-a type-b) type-a)

    (t
     (cl:let ((brand-a (and (boundp '*brand-instance-types*)
                            (gethash type-a *brand-instance-types*)))
              (brand-b (and (boundp '*brand-instance-types*)
                            (gethash type-b *brand-instance-types*))))
       (cl:cond
         ;; Both brand instances of the SAME brand -> cannot mix
         ((and brand-a brand-b (eq brand-a brand-b))
          (log:debug "resolve-dominance: blocking cross-instance mix of ~a and ~a (both brand ~a)"
                     type-a type-b brand-a)
          nil)

         ;; A is a brand instance, B is not -> A dominates unconditionally
         ((and brand-a (not brand-b))
          (log:debug "resolve-dominance: brand instance ~a dominates non-brand ~a"
                     type-a type-b)
          type-a)

         ;; B is a brand instance, A is not -> B dominates unconditionally
         ((and brand-b (not brand-a))
          (log:debug "resolve-dominance: brand instance ~a dominates non-brand ~a"
                     type-b type-a)
          type-b)

         ;; Neither is a brand instance -> standard type rules
         ((is-substitutable-for? type-a type-b)
          (log:debug "resolve-dominance: ~a substitutable for ~a -> ~a dominates"
                     type-a type-b type-b)
          type-b)
         ((is-substitutable-for? type-b type-a)
          (log:debug "resolve-dominance: ~a substitutable for ~a -> ~a dominates"
                     type-b type-a type-a)
          type-a)
         (t
          (log:debug "resolve-dominance: find-common-promoted-type ~a ~a"
                     type-a type-b)
          (find-common-promoted-type type-a type-b)))))))

          |#

;;;; ===========================================================================
;;;; Fix: analyze-aref-expression -- pass elem-type to resolve-brand-type
;;;; ===========================================================================
;;;
;;; The previous version called (resolve-brand-type 'value-t target-sym) without
;;; the element type.  With parameterised brands the gensym ended up as a
;;; descendant of value-t (which has no ancestors), breaking return-type checks.
;;; Pass elem-type as the optional BASE-TYPE so the fixed resolve-brand-type can
;;; register against the concrete type when needed.

;; src/analysis/structs.lisp
#|
(defun analyze-aref-expression (expr env context location)
  "Analyzes a cell dereference expression (~ cell-var [index]).
   For real cell types with an active value-t brand and a known target-sym,
   returns a per-instance gensym type instead of the raw element type, so that
   arithmetic across different cell variables is blocked by resolve-dominance
   when --differentiate is active.

   Passes elem-type to resolve-brand-type as optional BASE-TYPE so that
   parameterised brands (value-t appearing with multiple element types in the
   same compilation) still produce gensyms that are substitutable for the
   concrete element type in return-type checks."
  (let* ((op (first expr))
         (target-sym (if (symbolp (second expr)) (second expr) nil))
         (array-node (analyze-expression (second expr) env context (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env context (append location '(2)))
                         ;; Default to index 0 if not provided (e.g. `(~ ptr)`)
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    ;; Check for invalid READ access on &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
          (let ((binding (find-variable-in-env target-sym env)))
            (when (and binding (eq (parameter-def-kind binding) :out))
                  (error 'crisp-illegal-access-error
                    :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." target-sym)
                    :source-location location))))

    (if elem-type
        (progn
         ;; Check for VOID element type
         (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "VOID"))
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "T"))
                            (and (consp elem-type)
                                 (let ((head (first elem-type)))
                                   (or (eq head 'void) (eq head 'T)
                                       (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
           (when is-void
                 (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

         ;; Brand-aware type resolution: when --differentiate is active, the cell
         ;; has an active value-t brand, and we know the source variable (target-sym),
         ;; resolve to a per-instance gensym type so arithmetic across different
         ;; instances is blocked by resolve-dominance.
         ;;
         ;; Skip brand resolution for write-mode (set! target); set! does not
         ;; type-check the value against the target, so the raw elem-type suffices.
         ;;
         ;; elem-type is passed as BASE-TYPE so resolve-brand-type can bypass the
         ;; parameterised brand's missing ancestor chain and register the gensym
         ;; directly as a descendant of the concrete element type.
         (let* ((cell-type (semantic-node-type array-node))
                (brand-def (and target-sym
                                (not (eq *analysis-access-mode* :write))
                                (find-brand-for-owner 'value-t cell-type)))
                (resolved-type (if (and brand-def (brand-active-p brand-def))
                                   (progn
                                     (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a [elem: ~a]"
                                               cell-type target-sym elem-type)
                                     (resolve-brand-type 'value-t target-sym elem-type))
                                   elem-type)))
           (make-semantic-aref :type resolved-type
                               :array-node array-node
                               :index-node index-node
                               :source-location location)))
        ;; Fallback: If not an array/pointer, and op is ~, try as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))
              |#

;;;; ===========================================================================
;;;; Fix2: resolve-brand-type -- base-type always used as ancestor when provided
;;;; ===========================================================================
;;;
;;; The previous version checked *parameterized-brand-names* to decide whether
;;; to register the gensym against brand-name or base-type.  This is fragile:
;;; the first invocation may happen BEFORE the brand is marked as parameterized
;;; (because a second cell element type hasn't been compiled yet), so the gensym
;;; ends up as a descendant of brand-name.  When the brand is later marked
;;; parameterised, brand-name's ancestor link is severed, leaving the gensym
;;; with no path to the concrete element type.  Return-type checks then fail.
;;;
;;; Fix: whenever base-type is supplied, ALWAYS register the gensym directly
;;; as a :descendant of base-type (bypassing brand-name entirely) and include
;;; base-type in the cache key.  This means:
;;;
;;;   - VALUE-T-212 -> long   (substitutable for long in return-type checks)
;;;   - VALUE-T-456 -> float  (substitutable for float in return-type checks)
;;;
;;; Both are still tracked in *brand-instance-types* under brand-name so that
;;; resolve-dominance can block cross-instance arithmetic regardless of element type.
;;;
;;; For callers that do NOT supply base-type (fake-cell, future use), old
;;; behaviour is preserved: register as descendant of brand-name.

;; src/types/brand.lisp
#|
(defun resolve-brand-type (brand-name var-ref &optional base-type)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref [, base-type]).

   When BASE-TYPE is supplied the gensym is registered as a :descendant of
   BASE-TYPE directly.  This keeps the gensym substitutable for the concrete
   element type even if brand-name later becomes parameterised.  The cache key
   incorporates base-type so that the same variable name appearing with different
   element types in different functions produces distinct gensyms.

   When BASE-TYPE is NIL, the gensym is registered as a :descendant of
   brand-name (original behaviour, used by fake-cell / template brands).

   In all cases the gensym is stored in *brand-instance-types* under brand-name
   so that resolve-dominance can block cross-instance arithmetic."
  (cl:let* ((cache-key (if base-type
                           (list brand-name var-ref base-type)
                           (cons brand-name var-ref)))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let* ((gensym-name (gensym (format nil "~a-" brand-name)))
                  (ancestor (or base-type brand-name)))
          ;; Register gensym directly against the chosen ancestor.
          (register-derived-type gensym-name ancestor :descendant)
          ;; Track under brand-name so resolve-dominance works across all
          ;; element types of the same brand name.
          (setf (gethash gensym-name *brand-instance-types*) brand-name)
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a) [ancestor: ~a]"
                    gensym-name brand-name var-ref ancestor)
          gensym-name))))
          |#

;;;; ===========================================================================
;;;; Fix A: register-builtins -- remove index-t brand from real cell
;;;; ===========================================================================
;;;
;;; The index-t brand on the real cell conflicted with fake-cell's index-t brand.
;;; Real cell registers index-t with CRISP.COMPILER::ULONG, but fake-cell
;;; registers it with CRISP-LANGUAGE::ULONG.  The eq check in register-derived-type's
;;; idempotency guard fails because they are different symbol objects even though
;;; they print the same.  Tests 037-cell-branded/01 and 07 fail with:
;;;   "Cannot define derived type INDEX-T: type already exists with DIFFERENT definition"
;;;
;;; Fix: remove the index-t brand from real cell entirely.  The index-t brand on
;;; fake-cell is still exercised by the fake-cell tests; real cell only needs
;;; value-t for --differentiate tracking.

;; src/compiler.lisp
#|
(defun register-builtins ()
  "Registers built-in types and structs like 'storage' and 'cell' using def-struct
   semantics.  Cell carries the value-t brand for --differentiate mode."
  (log:info "Registering built-in structs...")

  ;; Clear brand-specific state that is NOT cleared by initialize-compiler.
  ;; initialize-compiler clears *brand-definitions* but not the extra tables
  ;; introduced in the overlay.  Without this, the in-process test runner leaks
  ;; state from one test into the next (e.g., *parameterized-brand-names* from
  ;; test 01-fake-cell persists into test 02-fake-cell-value-t-no-compose,
  ;; causing value-t to be treated as parameterized when it isn't in isolation).
  (when (boundp '*parameterized-brand-names*) (clrhash *parameterized-brand-names*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  (when (boundp '*brand-cache-last-function*) (setf *brand-cache-last-function* nil))

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
                             (def-record storage
                                         (address (c-pointer :address-space Addr))
                                         (byte-size ulong)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t :read-write))))

  ;; CELL: opaque handle to a storage slice.
  ;;   value-t To -- brands element reads so different cell vars produce distinct types
  ;;   when --differentiate is active.  Only :read-write cells activate brand tracking;
  ;;   :read-only/:write-only cells have the brand registered but analyze-aref-expression
  ;;   skips instance differentiation for them (see Fix C).
  ;;
  ;; NOTE: index-t intentionally REMOVED from real cell to avoid package-symbol conflict
  ;;   with fake-cell's index-t brand (CRISP.COMPILER::ULONG vs CRISP-LANGUAGE::ULONG).
  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
                             (def-record cell
                                         (brand value-t To :subst :descendant :enforce :diff)
                                         (parent (storage Addr))
                                         (offset ulong)
                                         (element-type type-spec :c-t To)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t Acc))))

  ;; bytes~ helper: compile-time sizeof for cell element type.
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
                     '(def-function bytes~ (c)
                                    (declare (function ((cell To Addr Acc) => ulong)))
                                    (declare (crisp-system-generated))
                                    (return (sizeof To)))
                     '((cell To Addr Acc) => ulong))

  (log:info "Built-in structs registered."))
  |#

;;;; ===========================================================================
;;;; Fix B: register-brand-definition -- guard against non-symbol base-type
;;;; ===========================================================================
;;;
;;; When a cell is instantiated with a compound element type such as (point int),
;;; the template substitution produces a brand form like:
;;;   (brand value-t (POINT INT) :subst :descendant :enforce :diff)
;;; The brand-definition struct has (:type symbol) on its base-type slot.
;;; Calling make-brand-definition with a list as base-type raises a type error.
;;;
;;; Fix: if the raw brand-form is a list (not pre-parsed) and its third element
;;; (the base-type position) is not a symbol, skip registration gracefully.
;;; Non-symbol element types cannot be meaningfully branded: the brand infrastructure
;;; expects a single symbol for DAG registration and alias lookup.

;; src/types/brand.lisp
#|
(defun register-brand-definition (struct-name brand-form)
  "Registers a brand declaration from within a struct definition.
   When the brand is active: registers as a derived type in the DAG.
   When inactive: registers as a type alias (transparent erasure).
   Parameterized brands (base type varies across template specializations,
   and the brand is NOT used as a concrete struct member type) skip global
   registration and are resolved lazily per-owner.
   Brands that conflict in base type AND appear as a concrete struct member
   in the existing owner are always an error (cannot be parameterized).

   Non-symbol base types (e.g., compound types like (POINT INT)) are silently
   skipped: they cannot be registered in the type DAG."
  ;; Guard: compound element types (cell (point int), etc.) produce brand forms
  ;; like (brand value-t (POINT INT) ...).  The brand-definition struct requires
  ;; a symbol for base-type; skip registration rather than crashing.
  (when (and (listp brand-form) (not (brand-definition-p brand-form)))
    (let ((raw-base-type (third brand-form)))
      (unless (symbolp raw-base-type)
        (log:info "Skipping brand registration for ~a: base-type ~a is not a symbol (compound element types cannot be branded)"
                  struct-name raw-base-type)
        (return-from register-brand-definition nil))))

  (cl:let* ((brand-def (if (brand-definition-p brand-form)
                           brand-form
                           (parse-brand-declaration brand-form)))
            (brand-name (brand-definition-brand-name brand-def))
            (base-type (brand-definition-base-type brand-def))
            (subst-mode (brand-definition-subst-mode brand-def))
            (is-parameterized (gethash brand-name *parameterized-brand-names*))
            ;; Set to T when this brand is already globally registered (same base-type,
            ;; different owner struct).  In that case we store the per-owner entry in
            ;; *brand-definitions* but skip calling register-derived-type again.
            ;; This prevents subst-mode conflicts when multiple structs share a brand
            ;; name with the same element type but declare different :subst modes
            ;; (e.g., real cell uses :descendant, fake-cell uses :ancestor).
            (skip-global nil))

    ;; Check for name collisions
    (cl:when (gethash brand-name *crisp-structs*)
          (error "Brand name collision: ~a is already defined as a struct." brand-name))
    (cl:when (gethash brand-name *function-table*)
          (error "Brand name collision: ~a is already defined as a function." brand-name))
    (cl:when (and (gethash brand-name *crisp-types*)
               (not (is-brand-type-p brand-name)))
          (error "Brand name collision: ~a is already defined as a non-brand type." brand-name))

    ;; Examine any existing registration for the same brand name.
    (cl:unless is-parameterized
      (cl:let ((existing (is-brand-type-p brand-name)))
        (cl:when existing
          (cl:cond
            ;; Different base-type: conflict or parameterize
            ((not (eq (brand-definition-base-type existing) base-type))
             (cl:let* ((existing-owner (brand-definition-owner-struct existing))
                       (existing-struct-def (find-struct-definition-by-name existing-owner))
                       (brand-used-as-member-p
                         (and existing-struct-def
                              (some (lambda (m) (eq (second m) brand-name))
                                    (crisp-struct-definition-members existing-struct-def)))))
               (if brand-used-as-member-p
                   (error "Cannot define derived type ~a: type already exists with DIFFERENT definition (Original: ~a, New: ~a)."
                          brand-name
                          (brand-definition-base-type existing)
                          base-type)
                   (progn
                    (log:info "Brand ~a detected as PARAMETERIZED: base ~a (from ~a) vs ~a (from ~a)"
                              brand-name
                              (brand-definition-base-type existing) existing-owner
                              base-type struct-name)
                    (setf is-parameterized t)
                    (setf (gethash brand-name *parameterized-brand-names*) t)
                    (remhash brand-name *crisp-type-aliases*)))))

            ;; Same base-type, different owner: brand already globally registered.
            ;; Skip global re-registration to avoid subst-mode conflicts.
            ;; This handles the case where real cell registers value-t with
            ;; :descendant and fake-cell later registers value-t with :ancestor
            ;; for the same element type.  The first owner's subst-mode wins;
            ;; subsequent owners just get a per-owner *brand-definitions* entry.
            ((not (eq (brand-definition-owner-struct existing) struct-name))
             (log:info "Brand ~a already globally registered (first owner: ~a); skipping global re-registration for ~a (same base-type ~a)"
                       brand-name (brand-definition-owner-struct existing) struct-name base-type)
             (setf skip-global t))

            ;; Same base-type, same owner: idempotent, nothing to do
            (t nil)))))

    ;; Store the owner struct
    (setf (brand-definition-owner-struct brand-def) struct-name)

    ;; Store in *brand-definitions* keyed by (brand-name . struct-type)
    (setf (gethash (cons brand-name struct-name) *brand-definitions*) brand-def)
    (log:info "Registered brand definition: ~a for struct ~a (base: ~a, subst: ~a, enforce: ~a~a)"
              brand-name struct-name base-type subst-mode
              (brand-definition-enforce-mode brand-def)
              (cond (is-parameterized ", PARAMETERIZED")
                    (skip-global ", SKIP-GLOBAL")
                    (t "")))

    ;; Register the type based on active/inactive status.
    ;; Skip global registration for parameterized brands (resolved lazily per owner)
    ;; and for brands already globally registered by another owner (skip-global).
    (cond
      (is-parameterized
       (log:info "Brand ~a is PARAMETERIZED - skipping global type registration (resolved lazily per owner)"
                 brand-name))
      (skip-global
       (log:info "Brand ~a - skip global type registration (already registered by first owner with same base-type ~a)"
                 brand-name base-type))
      ((brand-active-p brand-def)
       (log:info "Brand ~a is ACTIVE - registering as derived type of ~a with :subst ~a"
                 brand-name base-type subst-mode)
       (register-derived-type brand-name base-type subst-mode))
      (t
       (log:info "Brand ~a is INACTIVE - registering as type alias for ~a"
                 brand-name base-type)
       (setf (gethash brand-name *crisp-type-aliases*) base-type)))))

       |#

;;;; ===========================================================================
;;;; Fix C: analyze-aref-expression -- only brand-track :read-write cells
;;;; ===========================================================================
;;;
;;; The previous version applied value-t brand tracking to ALL cell reads when
;;; --differentiate was active, including :read-only and :write-only cells.
;;; This caused failures in pre-branding tests like:
;;;   022-def-kernel/05,07,11  (cell long :access :read-only inputs)
;;;   029-hoist-l0/08,09       (cell inputs with :read-only)
;;;
;;; Design rationale: :read-only and :write-only cells represent constants,
;;; masks, or non-differentiated inputs.  Only :read-write cells participate
;;; in the differentiation pass and need per-instance brand tracking.
;;;
;;; The owner struct name encodes the access mode (e.g., CELL_INT_GLOBAL_READ-WRITE
;;; vs CELL_LONG_GLOBAL_READ-ONLY).  We check for "READ-WRITE" in the owner
;;; struct's symbol name to determine whether to activate brand tracking.

;; src/analysis/structs.lisp
#|
(defun analyze-aref-expression (expr env context location)
  "Analyzes a cell dereference expression (~ cell-var [index]).
   For real cell types with an active value-t brand and a known target-sym,
   returns a per-instance gensym type instead of the raw element type, so that
   arithmetic across different cell variables is blocked by resolve-dominance
   when --differentiate is active.

   Brand tracking is ONLY applied for :read-write cells.  :read-only and
   :write-only cells skip brand tracking (their owner struct name does not
   contain 'READ-WRITE'), preserving the behaviour of pre-branding kernels
   that use read-only cells for constants and non-differentiated inputs.

   Passes elem-type to resolve-brand-type as optional BASE-TYPE so that
   parameterised brands (value-t appearing with multiple element types in the
   same compilation) still produce gensyms that are substitutable for the
   concrete element type in return-type checks."
  (let* ((op (first expr))
         (target-sym (if (symbolp (second expr)) (second expr) nil))
         (array-node (analyze-expression (second expr) env context (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env context (append location '(2)))
                         ;; Default to index 0 if not provided (e.g. `(~ ptr)`)
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    ;; Check for invalid READ access on &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
          (let ((binding (find-variable-in-env target-sym env)))
            (when (and binding (eq (parameter-def-kind binding) :out))
                  (error 'crisp-illegal-access-error
                    :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." target-sym)
                    :source-location location))))

    (if elem-type
        (progn
         ;; Check for VOID element type
         (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "VOID"))
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "T"))
                            (and (consp elem-type)
                                 (let ((head (first elem-type)))
                                   (or (eq head 'void) (eq head 'T)
                                       (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
           (when is-void
                 (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

         ;; Brand-aware type resolution for --differentiate mode.
         ;; Only applies to :read-write cell types.  The owner struct name encodes
         ;; the access mode (e.g., CELL_INT_GLOBAL_READ-WRITE vs READ-ONLY).
         ;; Read-only / write-only cells fall through to plain elem-type.
         (let* ((cell-type (semantic-node-type array-node))
                (brand-def (and target-sym
                                (not (eq *analysis-access-mode* :write))
                                (find-brand-for-owner 'value-t cell-type)))
                ;; Check that the owning cell struct is :read-write (not :read-only/:write-only)
                (is-rw-cell (and brand-def
                                 (let ((owner (brand-definition-owner-struct brand-def)))
                                   (and (symbolp owner)
                                        (search "READ-WRITE" (symbol-name owner))))))
                (resolved-type (if (and is-rw-cell (brand-active-p brand-def))
                                   (progn
                                     (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a [elem: ~a]"
                                               cell-type target-sym elem-type)
                                     (resolve-brand-type 'value-t target-sym elem-type))
                                   elem-type)))
           (make-semantic-aref :type resolved-type
                               :array-node array-node
                               :index-node index-node
                               :source-location location)))
        ;; Fallback: If not an array/pointer, and op is ~, try as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))

              |#

;;;; ===========================================================================
;;;; Fix: clear *partial-template-instantiations* and their CL dispatch macros
;;;;      in initialize-compiler.
;;;;
;;;; When an incomplete struct template is instantiated (one with :c-t fields
;;;; that lack a default value), %instantiate-structure-template stores info in
;;;; *partial-template-instantiations* and installs a CL macro for MAKE-X%DISPATCH
;;;; so that dispatch can find the partial mangled type at call-site expansion.
;;;;
;;;; initialize-templates (called inside initialize-compiler) clears
;;;; *template-registry* and *instantiated-templates* but does NOT clear
;;;; *partial-template-instantiations* or the installed CL macros.
;;;;
;;;; Consequence when tests run in-process (07 before errors/02):
;;;;   - Test 07 (arity=1, FAKE-CELL_INT is incomplete) installs
;;;;     MAKE-FAKE-CELL%DISPATCH as a CL macro that dispatches to FAKE-CELL_INT.
;;;;   - initialize-compiler is called before test 02, but the CL macro and
;;;;     hash entry are NOT cleared.
;;;;   - Test 02 (arity=3, FAKE-CELL_INT_GLOBAL_READ-WRITE is COMPLETE) runs.
;;;;     Its with-template-type redefines GEN-FAKE-CELL to arity=3, but
;;;;     MAKE-FAKE-CELL%DISPATCH is still the arity=1 CL macro from test 07.
;;;;   - (make-fake-cell ...) expands via MAKE-FAKE-CELL -> MAKE-FAKE-CELL%DISPATCH
;;;;     -> %dispatch-incomplete-template -> MAKE-FAKE-CELL_INT -> UNKNOWN TYPE.
;;;;
;;;; Fix: extend initialize-compiler to also iterate *partial-template-instantiations*,
;;;; remove each installed MAKE-X%DISPATCH CL macro, and then clear the hash.
;;;;
;;;; src/compiler.lisp
#|
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system to use stderr (important for stdout IR capture)
  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy) ;; Initialize type derivation graph (DAG)
  (clrhash *function-table*) ;; Reset function table
  (clrhash *crisp-structs*) ;; Reset struct definitions
  (clrhash *crisp-type-aliases*) ;; Reset type aliases
  (clrhash *crisp-template-aliases*) ;; Reset template aliases
  (clrhash *generic-functions*) ;; Reset generic functions
  (clrhash *kernel-declared-signatures*) ;; Reset kernel signatures
  (when (boundp '*record-definitions*) (clrhash *record-definitions*)) ;; Reset records (if defined)

  (setf *compiled-kernels* nil) ;; Reset compiled kernels list

  (initialize-expression-analyzers) ;; In analysis.lisp, but usually registered.
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Register intrinsic `die`
  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache and brand instance type tracking.
  ;; CRITICAL: must be cleared whenever *type-derivation-graph* is reset.
  ;; Stale gensyms in the cache are no longer registered in the fresh graph,
  ;; causing is-substitutable-for? to return NIL and crashing unmangle.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Clear partial template instantiations and their CL dispatch macros.
  ;; When an incomplete struct template (one with unresolved :c-t fields) is
  ;; instantiated, %instantiate-structure-template stores partial info in
  ;; *partial-template-instantiations* AND installs a CL macro for MAKE-X%DISPATCH.
  ;; initialize-templates only clears *template-registry* and *instantiated-templates*;
  ;; it does NOT touch *partial-template-instantiations* or the CL macros.
  ;; Without this cleanup, stale dispatch macros survive initialize-compiler and
  ;; misdirect MAKE-X calls in subsequent tests.
  (when (boundp '*partial-template-instantiations*)
    (loop for template-name being the hash-keys of *partial-template-instantiations*
          do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                         (symbol-package template-name))))
               (when (macro-function dispatch-sym)
                 (log:info "INITIALIZE-COMPILER: clearing stale CL dispatch macro ~a" dispatch-sym)
                 ;; Use fmakunbound to remove the macro definition cleanly.
                 ;; (setf (macro-function sym) nil) is not valid in SBCL.
                 (fmakunbound dispatch-sym))))
    (clrhash *partial-template-instantiations*))

  ;; Initialize built-in structs (storage)
  (register-builtins))

  |#

;;;; ===========================================================================
;;;; Fix3: resolve-brand-type -- normalize base-type to canonical package
;;;; ===========================================================================
;;;
;;; When a cell is declared with a user-defined struct element type (e.g.
;;; `(cell point :address-space :global :access :read-write)`), the mangled cell
;;; type symbol is created in the crisp.compiler package (the package of the
;;; built-in CELL template).  Later, get-array-element-type calls
;;; unmangle-template-struct-name on that symbol to recover the element type.
;;; unmangle-template-struct-name uses the *cell type symbol's* package
;;; (crisp.compiler) when re-interning the argument tokens, so the returned
;;; element type is crisp.compiler::POINT.
;;;
;;; However, def-struct reads its name from source with *package* = crisp-language
;;; (Fix D), so *crisp-structs* stores crisp-language::POINT.  These are two
;;; distinct CL symbols with the same name -- gethash uses eq and finds nothing.
;;; register-derived-type then signals "original type does not exist (single-pass
;;; semantics violation)" when trying to register VALUE-T-N as a descendant of
;;; the crisp.compiler::POINT that is NOT in any registry.
;;;
;;; Diagnostic confirmation (put_temp_files_here/diag-41.lisp):
;;;   Part 1: mangle/unmangle produces crisp.compiler::POINT from crisp-language::POINT
;;;   Part 2: *crisp-structs* stores crisp-language::POINT (Fix D effect)
;;;   Part 3: gethash exact-eq fails; name-based scan succeeds -> CONFIRMED
;;;
;;; Fix: in resolve-brand-type, before calling register-derived-type, normalize
;;; base-type to the canonical symbol by scanning *type-derivation-graph* and
;;; *crisp-structs* by name (string=).  This is safe because by the time
;;; analyze-aref-expression (Fix C) calls resolve-brand-type in pass 2, the
;;; register-brand-definition for the cell has already run (pass 1), which adds
;;; crisp-language::POINT to *type-derivation-graph* via the VALUE-T registration.
;;; The name-based scan therefore finds it.
;;;
;;; Destination: src/types/brand.lisp

;; src/types/brand.lisp
#|
(defun resolve-brand-type (brand-name var-ref &optional base-type)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref [, base-type]).

   When BASE-TYPE is supplied the gensym is registered as a :descendant of
   BASE-TYPE directly.  BASE-TYPE is first normalized against the type registries
   to handle package mismatches: unmangle-template-struct-name creates symbols in
   crisp.compiler (the cell type's package) while user structs are stored in
   crisp-language (Fix D reads source files in that package).  A name-based scan
   of *type-derivation-graph* then *crisp-structs* finds the canonical symbol.

   When BASE-TYPE is NIL, the gensym is registered as a :descendant of
   brand-name (original behaviour, used by fake-cell / template brands).

   In all cases the gensym is stored in *brand-instance-types* under brand-name
   so that resolve-dominance can block cross-instance arithmetic."
  (cl:let* ((cache-key (if base-type
                           (list brand-name var-ref base-type)
                           (cons brand-name var-ref)))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let* ((gensym-name (gensym (format nil "~a-" brand-name)))
                  ;; Normalize base-type to the canonical symbol in the type
                  ;; registries.  Fast path: symbol already findable by eq.
                  ;; Slow path: name-based scan for package-mismatch cases.
                  (canonical-base
                   (when (and base-type (symbolp base-type))
                     (or
                      ;; Fast path: already canonical
                      (and (or (gethash base-type *type-derivation-graph*)
                               (gethash base-type *crisp-types*)
                               (gethash base-type *crisp-structs*))
                           base-type)
                      ;; Slow path: same-named symbol in a different package
                      (let ((name (symbol-name base-type)))
                        (or (block found
                              (maphash (lambda (k v)
                                         (declare (ignore v))
                                         (when (and (symbolp k)
                                                    (string= (symbol-name k) name))
                                           (return-from found k)))
                                       *type-derivation-graph*)
                              nil)
                            (block found
                              (maphash (lambda (k v)
                                         (declare (ignore v))
                                         (when (and (symbolp k)
                                                    (string= (symbol-name k) name))
                                           (return-from found k)))
                                       *crisp-structs*)
                              nil))))))
                  (ancestor (or canonical-base base-type brand-name)))
          (when (and base-type canonical-base (not (eq base-type canonical-base)))
            (log:info "resolve-brand-type: normalized ~s -> ~s (package mismatch)"
                      base-type canonical-base))
          ;; Register gensym directly against the chosen ancestor.
          (register-derived-type gensym-name ancestor :descendant)
          ;; Track under brand-name so resolve-dominance works across all
          ;; element types of the same brand name.
          (setf (gethash gensym-name *brand-instance-types*) brand-name)
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a) [ancestor: ~a]"
                    gensym-name brand-name var-ref ancestor)
          gensym-name))))

          |#
