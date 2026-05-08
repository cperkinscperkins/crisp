;;; src/environment.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Environment & Declaration Parsing
;;; =========================================================

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

(defun bind-keyword-args (full-env explicit-args key-idx name)
  "Helper for resolve-argument-bindings. Handles &key argument parsing.
   Returns (values active-env remainder-env error-message)"
  (let ((arg-count (length explicit-args)))
    (when (< arg-count key-idx)
          (return-from bind-keyword-args
                       (values nil nil (format nil "Keyword Instantiation: Not enough positional arguments. Expected at least ~a, got ~a" key-idx arg-count))))

    (let ((pos-env (subseq full-env 0 key-idx))
          (key-args (subseq explicit-args key-idx))
          (key-active-env '())
          (provided-params '()))

      (unless (evenp (length key-args))
        (return-from bind-keyword-args
                     (values nil nil (format nil "Keyword Instantiation: Odd number of keyword arguments: ~a" (length key-args)))))

      ;; Parse (Key Val) pairs
      (loop for (k-type v-type) on key-args by #'cddr
            for i from 0
            do (progn
                ;; k-type must be (keyword :val)
                (unless (and (listp k-type) (eq (first k-type) 'keyword) (= (length k-type) 2))
                  (return-from bind-keyword-args
                               (values nil nil (format nil "Keyword Instantiation: Expected keyword literal, got ~a" k-type))))

                (let* ((key-kw (second k-type))
                       (param-name (intern (string-upcase (symbol-name key-kw)) (symbol-package name)))
                       ;; Verify this param exists in the key section of full-env
                       (param-entry (find param-name (subseq full-env key-idx) :key #'parameter-def-name)))

                  (unless param-entry
                    (return-from bind-keyword-args
                                 (values nil nil (format nil "Keyword Instantiation: Unknown keyword argument ~s for function ~s" key-kw name))))

                  (push param-name provided-params)
                  ;; Add to active-env: Key (ignored) + Value (bound to param-name)
                  ;; Key param name: _k_i
                  (push (make-parameter-def :name (intern (format nil "_K~d" i) (symbol-package name)) :type 'keyword :kind :in) key-active-env)
                  (push (make-parameter-def :name param-name :type v-type :kind (parameter-def-kind param-entry)
                                            :is-key t :default-value (parameter-def-default-value param-entry)) key-active-env))))

      (let* ((active-env (append pos-env (nreverse key-active-env)))
             ;; Remainder = All keys declared - Provided (Preserve Order!)
             (all-keys (subseq full-env key-idx))
             (remainder-env (remove-if (lambda (p) (member (parameter-def-name p) provided-params)) all-keys)))
        (values active-env remainder-env nil)))))

(defun inject-defaults (remainder-env defaults)
  "Helper for resolve-argument-bindings. Generates bindings for missing parameters."
  (let ((bindings-list '()))
    (loop for p in remainder-env
          for pname = (parameter-def-name p)
          do (let ((def-entry (assoc pname defaults)))
               (when def-entry
                     (log:info "Type-Checking Default Value Injection: ~a = ~a" pname (cdr def-entry))
                     (push (list pname (cdr def-entry)) bindings-list))))
    ;; Use nreverse to keep binding order consistent with definition order
    (nreverse bindings-list)))

(defun resolve-argument-bindings (generic-def explicit-arg-types)
  "Resolves the active environment and default bindings for a generic instantiation.
   Returns (values active-env injected-bindings error-message)."
  (let* ((name (generic-function-def-name generic-def))
         (full-env (generic-function-def-env generic-def))
         (arg-count (length explicit-arg-types))
         (key-idx (generic-function-def-keys generic-def))
         (defaults (generic-function-def-defaults generic-def))
         (active-env nil)
         (remainder-env nil)
         (error-msg nil))

    ;; 1. Determine Active & Remainder Environment
    (if key-idx
        ;; Keyword Logic
        (multiple-value-setq (active-env remainder-env error-msg)
                             (bind-keyword-args full-env explicit-arg-types key-idx name))
        ;; Optional Logic
        (progn
         (setf active-env (subseq full-env 0 arg-count))
         (setf remainder-env (subseq full-env arg-count))))

    (when error-msg
          (return-from resolve-argument-bindings (values nil nil error-msg)))

    ;; 2. Validation
    (let ((active-param-types (mapcar #'parameter-def-type active-env)))
      (unless (types-list-compatible-p explicit-arg-types active-param-types)
        (return-from resolve-argument-bindings
                     (values nil nil (format nil "Lazy Instantiation Mismatch: ~a called with ~a, expected prefix of ~a" name explicit-arg-types active-param-types)))))

    ;; 3. Inject Defaults
    (let ((injected-bindings (inject-defaults remainder-env defaults)))
      (values active-env injected-bindings nil))))

(defun instantiate-generic-function (generic-def explicit-arg-types context location)
  "Instantiates a lazy generic function variant for the given argument types."
  (multiple-value-bind (active-env injected-bindings error-message)
      (resolve-argument-bindings generic-def explicit-arg-types)

    (when error-message
          (log:warn "~a" error-message)
          (return-from instantiate-generic-function nil))

    (let* ((name (generic-function-def-name generic-def))
           (declarations (generic-function-def-declarations generic-def))
           ;; Robustly filter declarations from body
           (body (loop for f in (generic-function-def-body generic-def)
                         unless (and (listp f) (eq (car f) 'declare))
                       collect f)))

      ;; Apply injected bindings (Defaults)
      (when injected-bindings
            (setf body (list `(let* ,injected-bindings ,@body))))

      (let* ((active-param-names (mapcar #'parameter-def-name active-env))
             (active-param-types (mapcar #'parameter-def-type active-env))
             (mangled-name (mangle-function-variant-name name active-param-types)))

        (log:info "Lazy Instantiating ~s (Arity ~a) with types ~s" mangled-name (length explicit-arg-types) active-param-types)

        ;; Compile the specific variant
        (let ((ast-node (internal-compile-function mangled-name
                                                   active-env
                                                   (generic-function-def-return-types generic-def)
                                                   active-param-names
                                                   body
                                                   declarations
                                                   (or (generic-function-def-source-location generic-def) location)
                                                   context)))

          ;; Register the signature now that compilation succeeded (and return types might differ/be inferred?)
          ;; Note: Generic def return types are authoritative if present, but AST might have inferred them.
          (let* ((final-ret-types (or (generic-function-def-return-types generic-def)
                                      (semantic-function-return-type ast-node))) ;; If list mismatch, might need validation.
                                                                                (sig (make-function-signature
                                                                                      :name mangled-name
                                                                                      :parameters active-env
                                                                                      :return-types final-ret-types
                                                                                      :source-location (or (generic-function-def-source-location generic-def) location))))

            (log:info "Registering Lazy Signature: ~s -> ~s" mangled-name final-ret-types)
            ;; Append to existing signatures (thread safety? single threaded)
            (setf (gethash mangled-name *function-table*)
              (append (gethash mangled-name *function-table*) (list sig)))

            sig))))))


(defun %find-entry-point-declaration (declare-forms)
  "Helper: Returns T if any declare form contains an entry-point declaration."
  (loop for f in declare-forms
          thereis (loop for decl-spec in (rest f)
                          thereis (and (consp decl-spec)
                                       (string-equal (first decl-spec) "ENTRY-POINT")))))

(defun %validate-kernel-return-type (return-types)
  "Helper: Validates that kernel return types are void. Signals error if non-void."
  (when return-types
        (let ((non-void-types (remove-if (lambda (x)
                                           (or (null x)
                                               (and (symbolp x)
                                                    (string-equal x "VOID"))))
                                  return-types)))
          (when non-void-types
                (error "Kernels cannot declare they return values. Found: ~a. Kernels must return void (nil)."
                  return-types)))))

(defun %register-generic-function (name params env return-types declare-forms extracted-defaults key-idx body location)
  "Helper: Registers a generic function (with &optional or &key parameters) for lazy instantiation."
  (log:info "Registering GENERIC function template: ~s (Lazy Instantiation Mode)" name)
  (setf (gethash name *generic-functions*)
    (make-generic-function-def
     :name name
     :params params
     :env env
     :return-types return-types
     :declarations (loop for f in declare-forms append (rest f))
     :defaults extracted-defaults
     :keys key-idx
     :body (nthcdr (length declare-forms) body)
     :source-location location)))

(defun %register-standard-function (name env return-types declare-forms location)
  "Helper: Registers a standard function signature (eager registration)."
  (let* ((is-entry-point (%find-entry-point-declaration declare-forms)))

    ;; Validate kernel return type
    (when is-entry-point
          (%validate-kernel-return-type return-types))

    ;; Create and register signature
    (let ((sig (make-function-signature
                :name name
                :parameters env ;; STORE FULL PARAMETER-DEF STRUCTS (Name + Type)
                :return-types return-types
                :source-location location)))

      (finish-output *error-output*)
      (setf (gethash name *function-table*)
        (append (gethash name *function-table*) (list sig))))))



;;; Redefine register-function-signature to inject validation
(defun register-function-signature (form location)
  (let* ((name (second form))
         (params (third form))
         (body (cdddr form))
         (declare-forms (loop for f in body
                              while (and (listp f) (eq (car f) 'declare))
                              collect f)))

    (finish-output *error-output*)
    ;; Debug logging
    ;; (log:info "REGISTER-FUNC (Overlay): ~s" name)

    (multiple-value-bind (env return-types optional-idx extracted-defaults key-idx)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))

      ;; --- NEW VALIDATION ---
      (validate-dependent-brand-types declare-forms env)
      ;; ----------------------

      (cond
       ((or optional-idx key-idx)
         (%register-generic-function name params env return-types declare-forms
                                     extracted-defaults key-idx body location))
       (t
         (%register-standard-function name env return-types declare-forms location))))))

(defvar *template-registry* (make-hash-table :test 'eq)
        "Maps template names to their generator macros.")

(defvar *kernel-declared-signatures* (make-hash-table :test 'eq)
        "Maps kernel names to their declared (high-level) parameter types, before explosion.")
(defun register-overload (alias real-name)
  "Registers the signature(s) of `real-name` under `alias` to generic overloading/aliasing."
  (let ((real-sigs (gethash real-name *function-table*))
        (alias-sigs (gethash alias *function-table*)))
    (unless real-sigs
      (error "Cannot register overload: function ~a not found." real-name))
    (setf (gethash alias *function-table*)
      (append alias-sigs real-sigs))))




(defun inject-implicit-arguments (name explicit-env)
  "Injects implicit arguments into the environment for carrier functions.
   Types in *implicit-arg-map* are already in the correct form:
   mangled symbols for tensors (no integers to mangle-type-spec),
   canonical lists for cells (preserved for hoist metadata)."
  (let* ((implicit-info (gethash name *implicit-arg-map*))
         (implicit-env
          (when implicit-info
            (loop for (param-name . param-type) in implicit-info
                  collect (make-parameter-def
                           :name param-name
                           :type param-type
                           :kind :in)))))
    (append implicit-env explicit-env)))                      

(defun scan-for-carriers (name body)
  "Performs a single-pass look-ahead to detect if the function is a carrier.

   This logic is ONLY executed in single-pass mode. It serves two purposes:
   1. Early originator detection - finds make-scratch-cell BEFORE env is built
   2. Upward carrier propagation - copies implicit args from callees to callers

   In multi-pass mode, this analysis is handled by analyze-signatures-pass."
  (when (single-pass-mode-p)
        (with-peek-scratch-counter
         (let ((*scanning-function-name* name))
           (setf (compiler-context-scanning-function-name *compiler-context*) name)
           (multiple-value-bind (is-originator callees) (shallow-analyze-body body)
             (when (or is-originator (some (lambda (callee)
                                             (or (gethash callee *implicit-arg-map*)
                                                 (member callee *side-channel-originators*)))
                                       callees))
                   (log:debug "Single-pass: Pre-scan of ~s found call to a carrier/originator. Marking as carrier." name)

                   ;; Union all implicit args from ALL callees
                   (let ((all-implicits nil))
                     (dolist (callee callees)
                       (let ((callee-imps (gethash callee *implicit-arg-map*)))
                         (when callee-imps
                               (setf all-implicits (union all-implicits callee-imps :test #'equal)))))

                     (when all-implicits
                           (setf (gethash name *implicit-arg-map*) all-implicits)))))))))


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
                                          (find #\_ (symbol-name ptype))
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

;; --- #'(...) Syntax Parsers ---


(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s).
   Extended: (array T N) is returned as-is (not mangled) before the generic path."
  (cond
   ;; (array T N) — return as a list spec unchanged, not mangled
   ((%array-type-p spec)
    spec)

   ;; 0. Type Aliases
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved)
       (if (and (consp resolved) (eq (first resolved) 'common-lisp:function))
           (let* ((sig (if (listp (second resolved)) (second resolved) (rest resolved)))
                     (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                              (string-equal (symbol-name x) "=>")))
                                             sig))
                     (param-types (if arrow-pos (subseq sig 0 arrow-pos) sig))
                     (return-types (if arrow-pos (nthcdr (1+ arrow-pos) sig) nil)))
             `(:function-type ,return-types :params ,(mapcar #'parse-type-specifier param-types)))
           spec)))

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
     (let* ((brand-name (first spec))
               (var-ref (second spec))
               (brand-def (is-brand-type-p brand-name)))
       (if (gethash brand-name *parameterized-brand-names*)
           (progn
             (log:info "PARSE: Parameterized brand application (~a ~a) - deferring resolution"
                       brand-name var-ref)
             spec)
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

   ;; Function Type: #'(int => int) — raw (function ...) form from reader
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                    (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (let ((canonical (expand-storage-handle-type-specifier spec)))
       (cond
         ;; Incomplete: any positional slot is nil (e.g. (cell elem nil) or
         ;; (tensor elem N nil nil ct)).  Don't mangle — return as a list
         ;; so downstream incomplete-type-p / implicit-template detection
         ;; can recognize it as polymorphic.
         ((and (listp canonical) (some #'null (rest canonical)))
          canonical)
         ((valid-type-p canonical)
           (let ((base (first canonical))
                    (params (rest canonical)))
             (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params))))
         (t (error 'crisp-unknown-type-error :type-name spec)))))

   ;; Function Type/Literal (already parsed to :function-type or :function-literal)
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (let* ((base (first spec))
               (raw-params (rest spec))
               (arity (get-template-arity base))
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

(defun analyze-return-type-from-spec (fn-spec)
  "Parses '(int int => int int)' and returns a list of types."
  (let ((arrow-pos (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) fn-spec)))
    (if arrow-pos
        (let ((return-types-list (nthcdr (1+ arrow-pos) fn-spec)))
          (if (null return-types-list)
              '(nil)
              (loop for type-spec in return-types-list
                    collect (cond
                             ((null type-spec) 'nil)
                             (t (parse-type-specifier type-spec))))))
        '(nil))))

(defun analyze-environment-from-spec (params fn-spec)
  "Builds the environment from the signature. Returns (values env optional-start-index defaults-alist)."
  (let ((arrow-pos (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) fn-spec)))
    (let ((param-type-specs (subseq fn-spec 0 (or arrow-pos (length fn-spec))))
          (env '())
          (defaults '())
          (optional-start nil)
          (key-start nil)
          (out-start nil)
          (idx 0))
      (log:debug "Analyzing spec params: ~s, specs: ~s" params param-type-specs)

      (loop while (and params param-type-specs)
            do (let ((p (first params))
                     (ts (first param-type-specs)))

                 ;; (format *error-output* "DEBUG ANALYZE-ENV: Param ~s TS ~s~%" p ts)
                 (finish-output *error-output*)

                 (cond
                  ;; Handle &optional in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&OPTIONAL"))
                    ;; If type spec also has &optional, skip it.
                    (when (and (symbolp ts) (string-equal (symbol-name ts) "&OPTIONAL"))
                          (pop param-type-specs))
                    (when optional-start (error "Multiple &optional keywords found."))
                    (when key-start (error "&optional cannot appear after &key."))
                    (setf optional-start idx)
                    (pop params))

                  ;; Handle &key in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&KEY"))
                    (unless (and (symbolp ts) (string-equal (symbol-name ts) "&KEY"))
                      (error "Signature Mismatch: &key present in parameter list but found ~s in type declaration." ts))
                    (when key-start (error "Multiple &key keywords found."))
                    (setf key-start idx)
                    (setf params (cdr params))
                    (setf param-type-specs (cdr param-type-specs)))

                  ;; Handle &out in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                    (unless (and (symbolp ts) (string-equal (symbol-name ts) "&OUT"))
                      (error "Signature Mismatch: &out present in parameter list but found ~s in type declaration." ts))
                    (when out-start (error "Multiple &out keywords found."))
                    (when optional-start (error "&out cannot appear after &optional."))
                    (when key-start (error "&out cannot appear after &key."))
                    (setf out-start idx)
                    (pop params)
                    (pop param-type-specs))

                  ;; Handle markers in types (Error)
                  ((and (symbolp ts)
                        (or (string-equal (symbol-name ts) "&OPTIONAL")
                            (string-equal (symbol-name ts) "&KEY")
                            (string-equal (symbol-name ts) "&OUT")))
                    (error "Signature Mismatch: ~s present in type declaration but missing in parameter list." ts))

                  ;; Handle &key specialized syntax (:key type)
                  ((and key-start (keywordp ts))
                    (let ((name p) (def-val nil)
                                   (val-type (second param-type-specs)))
                      ;; Extract (name default) from params
                      (when (listp p)
                            (setf name (first p))
                            (setf def-val (second p))
                            (push (cons name def-val) defaults))

                      ;; Validate param-type-specs has enough elements
                      (unless val-type
                        (error "Signature Mismatch: &key keyword ~s missing type." ts))

                      ;; Validate name match (optional strictness, but good for sanity)
                      (unless (string-equal (symbol-name name) (symbol-name ts))
                        (log:warn "Signature key name mismatch: Param ~s vs Keyword spec ~s" name ts))

                      (push (make-parameter-def :name name
                                                :type (parse-type-specifier val-type)
                                                :kind :in
                                                :is-key t
                                                :default-value def-val) env)
                      (incf idx)
                      (pop params)
                      (pop param-type-specs) ;; Pop keyword
                      (pop param-type-specs))) ;; Pop value type

                  ;; Normal parameter (symbol or (name default))
                  (t
                    (let ((name p) (def-val nil))
                      ;; Extract (name default)
                      (when (listp p)
                            (setf name (first p))
                            (setf def-val (second p))
                            ;; Store default
                            (push (cons name def-val) defaults))

                      (push (make-parameter-def
                             :name name
                             :type (parse-type-specifier ts)
                             :kind (cond (out-start :out) (t :in))
                             :is-optional (not (null optional-start))
                             :is-key (not (null key-start))
                             :default-value def-val)
                            env)
                      (incf idx)
                      (pop params)
                      (pop param-type-specs))))))

      (when (or params param-type-specs)
            (error 'crisp-signature-arity-error :expected (length fn-spec) :inferred (length env) :source-location nil))

      (values (nreverse env) optional-start (nreverse defaults) key-start))))

(defun analyze-return-type-from-list (declarations)
  "Finds and returns the return-type(s) from a (return-type ...) decl."
  (let ((found (assoc 'return-type declarations)))
    (when found
          (let ((type-names (rest found)))
            ;; Special case for `(function ...)` syntax which is handled elsewhere
            (when (eq (first type-names) 'function)
                  (return-from analyze-return-type-from-list nil))
            (loop for type-name in type-names
                  collect (cond ((null type-name) 'nil)
                                ((valid-type-p type-name) type-name)
                                (t (error 'crisp-unknown-type-error :type-name type-name))))))))

(defun analyze-environment-from-list (params declarations)
  "Builds the environment from standard CL (type type-spec vars...) declarations."
  (let ((env (make-hash-table))
        (type-decls (loop for d in declarations
                            when (and (consp d) (eq (first d) 'type))
                          collect d)))

    ;; Check for missing declarations if no function signature
    (when (and params (null type-decls) (not (assoc 'function declarations)))
          (warn "Missing type declarations for parameters: ~a" params)
          ;; Return environment of (param nil)?? Or error?
          ;; Original code errored. Let's error.
          (error "Missing type declarations for parameters: ~a" params))

    ;; Parse declarations
    (dolist (decl type-decls)
      (let* ((args (rest decl))
             (first-arg (first args))
             (last-arg (car (last args)))
             (type-spec nil)
             (vars nil))

        ;; Heuristic: Check if first arg is a valid type (Standard  type TYPE VARS...)
        (if (valid-type-p first-arg)
            (setf type-spec first-arg
              vars (rest args))
            ;; Heuristic: Check if last arg is a valid type (Crisp Style: type VARS... TYPE)
            (if (valid-type-p last-arg)
                (setf type-spec last-arg
                  vars (butlast args))
                ;; Fallback/Error
                (error 'crisp-unknown-type-error :type-name first-arg)))

        ;; Validation: Type must be valid (Redundant if we just checked, but good for safety)
        (unless (valid-type-p type-spec)
          (error 'crisp-unknown-type-error :type-name type-spec))

        (dolist (var vars)
          (when (gethash var env)
                (error "Duplicate type declaration for variable ~a" var))
          (setf (gethash var env) (parse-type-specifier type-spec)))))

    ;; Convert hash table to list of parameter-defs, preserving order from params
    (loop for p in params
          collect (make-parameter-def
                   :name p
                   :type (or (gethash p env) t) ;; Default to T if not declared
                   :kind :in))))



(defun %validate-grid-function-return-type (return-types)
  "Validates that a grid function has a void return type.
   Grid functions are void by definition; declaring a return type is an error."
  (when return-types
    (let ((non-void-types (remove-if (lambda (x)
                                       (or (null x)
                                           (and (symbolp x)
                                                (string-equal x "VOID"))))
                             return-types)))
      (when non-void-types
        (error "Grid functions cannot declare a return type. Found: ~a. Grid functions must return void (nil)."
          return-types)))))

