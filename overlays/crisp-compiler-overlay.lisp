;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; ============================================================
;;; 091-def-grid-function: New state variables
;;; ============================================================

;; src/compiler.lisp
(defvar *grid-functions* (make-hash-table :test #'eq)
  "Maps grid function name → T.
   Used to enforce that grid functions can only be called from
   dispatch contexts (def-kernel or def-grid-function bodies).")

;; src/analysis/core.lisp
(defvar *in-grid-level-context* nil
  "T when the analyzer is currently inside a (declare (grid-level)) let/progn scope.
   Grid-level contexts cannot be nested inside each other.")

;; src/analysis/core.lisp
(defvar *in-workgroup-level-context* nil
  "T when the analyzer is currently inside a (declare (workgroup-level)) let/progn scope.
   Workgroup-level contexts cannot be nested inside each other.")


;;; ============================================================
;;; 091-def-grid-function: initialize-compiler
;;; Extended to clear *grid-functions* between compilations.
;;; ============================================================

;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil))
  "Initializes the compiler state.
   Extended to clear *grid-functions* for def-grid-function support."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
  (clrhash *crisp-template-aliases*)
  (clrhash *generic-functions*)
  (clrhash *kernel-declared-signatures*)
  (when (boundp '*record-definitions*) (clrhash *record-definitions*))

  (setf *compiled-kernels* nil)

  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
        (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)

  ;; clear dispatch declarations side table
  (clrhash *kernel-dispatch-declarations*)

  ;; clear grid-function registry
  (clrhash *grid-functions*)

  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))


;;; ============================================================
;;; 091-def-grid-function: %validate-grid-function-return-type
;;; ============================================================

;; src/environment.lisp
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


;;; ============================================================
;;; 091-def-grid-function: internal-def-function
;;; Extended to handle (grid-function) declaration:
;;;   - sets *in-dispatch-context* = T
;;;   - validates void return type
;;; ============================================================

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params*, *boundary-array-params*, and
   *in-dispatch-context* to enforce kernel-boundary rules.
   Extended to capture global-size/local-size/num-groups dispatch declarations.
   Extended (091) to handle (grid-function) declaration: sets dispatch context,
   validates void return type, and marks function in *grid-functions*."
  (log:info "Analyzing function ~s" name)

  (when (and *differentiate-p*
             (not (find "NON-DIFFERENTIABLE" declarations
                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                        :test #'string-equal)))
        (log:info "Applying ANF to function body")
        (let* ((progn-body `(progn ,@body))
               (anf-body (anf-normalize progn-body nil))
               (unwrapped-body (if (and (consp anf-body) (eq (car anf-body) 'progn))
                                   (cdr anf-body)
                                   (list anf-body))))
          (setf body unwrapped-body)))

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d)
                                            (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))

      ;; Void return type enforcement for grid functions
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))

      ;; Extract and store dispatch declarations for entry-point kernels
      (when is-entry-p
        (let ((global-size-decl (find "GLOBAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (local-size-decl  (find "LOCAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (num-groups-decl  (find "NUM-GROUPS" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal)))
          (when (or global-size-decl local-size-decl num-groups-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))))

      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))


;;; ============================================================
;;; 091-def-grid-function: analyze-function-call
;;; Extended to block grid-function calls from thread-level contexts.
;;; ============================================================

;; src/analysis/core.lisp
(defun analyze-function-call (op expr env context location)
  "Analyzes a function call expression.
   Checks for struct immutability violations via %check-struct-mutating-call.
   Extended (091): grid functions can only be called from a dispatch context."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Grid function dispatch-context check
  (when (and (gethash op *grid-functions*)
             (not *in-dispatch-context*))
    (error 'crisp-compiler-error
      :message (format nil "Grid function '~(~a~)' cannot be called outside a dispatch context. Use def-kernel or def-grid-function to provide a dispatch context.")
      :source-location location))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      ;; Struct mutating function check
      (%check-struct-mutating-call op explicit-arg-nodes env context location)

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))

            (when *differentiate-p*
              (let ((sig-params (function-signature-parameters augmented-signature)))

                ;; 1. Brand parameter type checking
                (loop for param in sig-params
                      for arg-node in final-arg-nodes
                      for param-type = (parameter-def-type param)
                      do (let ((brand-def (is-brand-type-p param-type)))
                           (when (and brand-def (brand-active-p brand-def))
                             (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                        sig-params final-arg-nodes)))
                               (when owner-var
                                 (let* ((expected-type (resolve-brand-type param-type owner-var))
                                           (actual-type (get-single-value-type arg-node)))
                                   (unless (or (eq actual-type expected-type)
                                               (is-substitutable-for? actual-type expected-type))
                                     (error 'crisp-type-error
                                       :expected (list expected-type)
                                       :inferred (list actual-type)
                                       :source-location location))))))))

                ;; 2. Brand return type refinement
                (setf refined-return-types
                  (loop for ret-type in (function-signature-return-types augmented-signature)
                        collect (let ((brand-def (is-brand-type-p ret-type)))
                                  (if (and brand-def (brand-active-p brand-def))
                                      (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                 sig-params final-arg-nodes)))
                                        (if owner-var
                                            (resolve-brand-type ret-type owner-var)
                                            ret-type))
                                      ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))


;;; ============================================================
;;; 091-def-grid-function: %strip-execution-context-declares
;;; Helper: strips leading declare forms from a body list and
;;; returns (values body-without-declares all-declaration-specs).
;;; ============================================================

;; src/analysis/control.lisp
(defun %strip-execution-context-declares (body-forms)
  "Strips leading (declare ...) forms from BODY-FORMS.
   Returns (values remaining-body all-decl-specs).
   Uses string-equal matching so package of 'declare doesn't matter."
  (let ((decl-forms (loop for f in body-forms
                          while (and (listp f)
                                     (symbolp (car f))
                                     (string-equal (symbol-name (car f)) "DECLARE"))
                          collect f))
        )
    (values (nthcdr (length decl-forms) body-forms)
            (loop for d in decl-forms append (rest d)))))


;;; ============================================================
;;; 091-def-grid-function: %check-context-declarations
;;; Helper: enforces grid-level / workgroup-level nesting rules.
;;; ============================================================

;; src/analysis/control.lisp
(defun %check-context-declarations (decl-specs location)
  "Checks DECL-SPECS for (grid-level) and (workgroup-level) declarations.
   Enforces that:
   - (grid-level) requires *in-dispatch-context* and cannot be nested.
   - (workgroup-level) cannot be nested inside another workgroup-level context.
   Returns (values has-grid-level has-workgroup-level)."
  (let ((has-grid-level (find "GRID-LEVEL" decl-specs
                              :key (lambda (x) (when (consp x) (symbol-name (car x))))
                              :test #'string-equal))
        (has-workgroup-level (find "WORKGROUP-LEVEL" decl-specs
                                   :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                   :test #'string-equal)))

    (when has-grid-level
      (unless *in-dispatch-context*
        (error 'crisp-compiler-error
          :message "Grid-level context cannot appear in a thread-level function. A dispatch context (def-kernel or def-grid-function) is required."
          :source-location location))
      (when *in-grid-level-context*
        (error 'crisp-compiler-error
          :message "Grid-level contexts cannot be nested. Sequential usage is allowed but nesting is not."
          :source-location location)))

    (when has-workgroup-level
      (when *in-workgroup-level-context*
        (error 'crisp-compiler-error
          :message "Workgroup-level contexts cannot be nested inside another workgroup-level context."
          :source-location location)))

    (values has-grid-level has-workgroup-level)))


;;; ============================================================
;;; 091-def-grid-function: analyze-let-expression
;;; Extended to strip leading (declare ...) forms from the body,
;;; check for grid-level / workgroup-level declarations, and
;;; bind the appropriate context vars for the body analysis.
;;; ============================================================

;; src/analysis/control.lisp
(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression.
   Extended (091): strips leading declare forms from the body, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules."
  (unless (and (>= (length expr) 2) (listp (cadr expr)))
    (error "Malformed let form: ~a" expr))

  (let* ((binding-forms (cadr expr))
         (raw-body (cddr expr)))

    ;; Strip leading declares and check for execution-context declarations
    (multiple-value-bind (body-forms decl-specs)
        (%strip-execution-context-declares raw-body)
      (multiple-value-bind (has-grid-level has-workgroup-level)
          (%check-context-declarations decl-specs location)

        ;; Bind context vars for the body analysis
        (let ((*in-grid-level-context* (or *in-grid-level-context* has-grid-level))
              (*in-workgroup-level-context* (or *in-workgroup-level-context* has-workgroup-level)))

          ;; Implement let* scoping by sequentially building the environment.
          (multiple-value-bind (final-env analyzed-bindings)
              (let ((current-env env)
                    (bindings-list '()))
                (loop for binding in binding-forms
                      for i from 0 do
                        (log:debug "Analyzing let binding form: ~s" binding)

                        (let ((is-flat-mvb (and (> (length binding) 2)
                                                (not (listp (first binding))))))

                          (let* ((binding-vars (if is-flat-mvb
                                                   (butlast binding)
                                                   (if (and (= (length binding) 2) (listp (first binding)))
                                                       (first binding)
                                                       (list (first binding)))))
                                 (init-form (first (last binding)))
                                 (current-binding-name (if (= (length binding-vars) 1) (first binding-vars) nil))
                                 (init-node
                                  (let ((old-name (compiler-context-current-binding-name context)))
                                    (when current-binding-name
                                          (setf (compiler-context-current-binding-name context) current-binding-name))
                                    (unwind-protect
                                        (analyze-expression init-form current-env context
                                                            (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1))))
                                      (when current-binding-name
                                            (setf (compiler-context-current-binding-name context) old-name)))))
                                 (init-node-types (semantic-node-type init-node)))

                            (cond
                             ((= (length binding-vars) 1)
                               (let* ((var-name (first binding-vars))
                                      (var-type (get-single-value-type init-node)))
                                 (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a" var-name var-type)
                                 (push (cons var-name init-node) bindings-list)
                                 (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env))))

                             ((> (length binding-vars) 1)
                               (unless (listp init-node-types)
                                 (error "Cannot destructure a single-value return into multiple variables at ~a. Got type ~a for binding ~a."
                                   (semantic-node-source-location init-node) init-node-types binding))
                               (unless (>= (length init-node-types) (length binding-vars))
                                 (error "Not enough return values from ~a to bind ~a variables at ~a" init-form (length binding-vars) (semantic-node-source-location init-node)))

                               (loop for var-name in binding-vars
                                     for j from 0 do
                                       (let* ((var-type (nth j init-node-types))
                                              (extract-node (make-semantic-extract-value
                                                             :type var-type
                                                             :aggregate-node init-node
                                                             :index j
                                                             :source-location (semantic-node-source-location init-node))))
                                         (push (cons var-name extract-node) bindings-list)
                                         (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env)))))
                             (t (error "Malformed let binding: ~a" binding))))))
                (values current-env (reverse bindings-list)))

            (let* ((analyzed-body (analyze-body-expressions body-forms final-env context (append location '(2))))
                   (last-body-node (first (last analyzed-body)))
                   (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
              (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                         analyzed-bindings analyzed-body return-type)
              (make-semantic-let :type return-type
                                 :bindings analyzed-bindings
                                 :body analyzed-body
                                 :source-location location))))))))


;;; ============================================================
;;; 091-def-grid-function: analyze-progn-expression
;;; Extended to strip leading (declare ...) forms from the body,
;;; check for grid-level / workgroup-level declarations, and
;;; bind the appropriate context vars for the body analysis.
;;; ============================================================

;; src/analysis/control.lisp
(defun analyze-progn-expression (expr env context location)
  "Analyzes a `(progn ...)` expression.
   Extended (091): strips leading declare forms, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules."
  (let ((raw-body (cdr expr)))

    ;; Strip leading declares and check for execution-context declarations
    (multiple-value-bind (body-forms decl-specs)
        (%strip-execution-context-declares raw-body)
      (multiple-value-bind (has-grid-level has-workgroup-level)
          (%check-context-declarations decl-specs location)

        ;; Bind context vars for the body analysis
        (let ((*in-grid-level-context* (or *in-grid-level-context* has-grid-level))
              (*in-workgroup-level-context* (or *in-workgroup-level-context* has-workgroup-level))
              (nodes '()))
          (dolist (form body-forms)
            (push (analyze-expression form env context location) nodes))
          (setf nodes (nreverse nodes))
          (let ((last-node (first (last nodes))))
            (make-semantic-progn
             :type (if last-node (semantic-node-type last-node) 'void)
             :body nodes
             :source-location location)))))))
