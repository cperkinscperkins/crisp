;;; src/analysis/control.lisp
(in-package :crisp.compiler)

(defun ensure-branch-compatibility (then-node else-node location)
  "Unifies types of then/else branches. Returns (values unified-type new-then new-else)."
  (let ((t-type (semantic-node-type then-node)))
    (unless else-node
      ;; Propagate THEN type if no ELSE (implicitly returns void/nil or 0? 
      ;; Actually, for IF expression correctness, missing else implies value is unlikely to be used
      ;; unless it matches the implicit else value (int 0). 
      ;; For now, just return t-type. 
      (return-from ensure-branch-compatibility (values t-type then-node nil)))

    (let ((e-type (semantic-node-type else-node))
          (t-single (get-single-value-type then-node))
          (e-single (get-single-value-type else-node)))
      (if (equal t-type e-type)
          (values t-type then-node else-node)
          (let ((promoted (get-promoted-type t-single e-single)))
            (cond
             (promoted
               ;; Insert Casts
               (values promoted
                 (if (equal t-type promoted) then-node (create-implicit-cast then-node promoted location))
                 (if (equal e-type promoted) else-node (create-implicit-cast else-node promoted location))))

             ;; Special Case: Literal 0 (Int) can promote to any Pointer -> NULL
             ((and (eq t-single 'int) (typep then-node 'semantic-literal) (= (semantic-literal-value then-node) 0)
                   (listp e-type) (member (first e-type) '(ptr array)))
               (values e-type (create-implicit-cast then-node e-type location) else-node))

             ((and (eq e-single 'int) (typep else-node 'semantic-literal) (= (semantic-literal-value else-node) 0)
                   (listp t-type) (member (first t-type) '(ptr array)))
               (values t-type then-node (create-implicit-cast else-node t-type location)))

             ;; Void Compatibility: If one branch is NIL (void), unify to NIL (void).
             ;; This supports (when ...) and (unless ...) which return NIL on one path.
             ((or (null t-single) (null e-single))
               (values '(nil) then-node else-node))

             (t
               (error "Branch type mismatch in IF expression. Then: ~a, Else: ~a" t-type e-type))))))))

(defun analyze-if-expression-impl (expr env context location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env context (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    (let* ((then-node (analyze-expression (third expr) env context (append location '(2))))
           (else-node (if (fourth expr) (analyze-expression (fourth expr) env context (append location '(3))) nil)))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location)))))

(defun analyze-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant nil))

(defun analyze-static-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant t))

(defun analyze-when-expression (expr env context location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (when cond body...) -> (if cond (progn body...) nil)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond ,body) env context location)))

(defun analyze-static-when-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond ,body) env context location)))

(defun analyze-unless-expression (expr env context location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (unless cond body...) -> (if cond nil (progn body...))
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond nil ,body) env context location)))

(defun analyze-static-unless-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond nil ,body) env context location)))



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

(defun analyze-function-literal (expr env context location)
  "Analyzes (function x) or #'(...)"
  (declare (ignore env))
  (let ((fn-name (second expr)))
    ;; Check if the function exists (simplistic check for now)
    (unless (or (fboundp fn-name) (gethash fn-name *function-table*))
      (log:warn "Function literal ~a refers to unknown function (at compile time)." fn-name))

    (make-semantic-literal
     :value-type `(:function-literal ,fn-name)
     :value fn-name
     :source-location location)))

(defun analyze-funcall-expression (expr env context location)
  "Analyzes a (funcall f args...) form."
  (let* ((func-expr (second expr))
         (args-exprs (cddr expr))
         (func-node (analyze-expression func-expr env context location))
         (func-type (semantic-node-type func-node)))

    ;; Check if the function expression resolved to a function type or literal.
    ;; e.g. (:function-type (int) :params (int int)) 
    ;; or (:function-literal +)

    (let ((signature-return-type nil)
          (signature-params nil))

      (cond
       ;; Case 1: Function Type (e.g. from a parameter)
       ((and (listp func-type) (eq (first func-type) :function-type))
         (setf signature-return-type (second func-type)) ; (int)
         (setf signature-params (getf (cddr func-type) :params))) ;; Case 2: Function Literal (e.g. #'+)
       ((and (listp func-type) (eq (first func-type) :function-literal))
         (let ((name (second func-type)))
           ;; Sub-case 2a: It is a primitive/special-form with an analyzer (e.g. +)
           (when (gethash name *expression-analyzers*)
                 ;; Re-dispatch as if it were a direct call: (+ a b)
                 (let ((new-expr (cons name args-exprs)))
                   (return-from analyze-funcall-expression
                                (funcall (gethash name *expression-analyzers*) new-expr env context location))))

           ;; Sub-case 2b: It is a user function. Lower to direct semantic-call.
           (let* ((arg-nodes (loop for arg in args-exprs collect (analyze-expression arg env context location)))
                  (arg-types (mapcar #'semantic-node-type arg-nodes))
                  (signatures (gethash name *function-table*))
                  (match (find-if (lambda (sig)
                                    (equal arg-types (mapcar #'parameter-def-type (function-signature-parameters sig))))
                             signatures)))
             (unless match
               (error "No matching signature for funcall of literal ~a with types ~a. Table count: ~a" name arg-types (hash-table-count *function-table*)))

             (return-from analyze-funcall-expression
                          (make-semantic-call
                           :name name
                           :type (function-signature-return-types match)
                           :args arg-nodes
                           :signature match
                           :source-location location)))))

       (t
         (error "First argument to funcall must be a function type or literal. Got ~a" func-type)))

      ;; Continued Case 1 logic (Function Type)
      ;; Verify argument count
      (unless (= (length args-exprs) (length signature-params))
        (error 'crisp-signature-arity-error :expected (length signature-params) :inferred (length args-exprs)))

      ;; Analyze and check arguments
      (let ((arg-nodes
             (loop for arg-expr in args-exprs
                   for expected-type in signature-params
                   for i from 0
                   collect (let ((node (analyze-expression arg-expr env context location)))
                             ;; Type check
                             (unless (equal (semantic-node-type node) expected-type)
                               (error 'crisp-type-error :expected expected-type :inferred (semantic-node-type node) :source-location location))
                             node))))
        (make-semantic-funcall
         :func-node func-node
         :type signature-return-type ; e.g. (int)
         :args arg-nodes
         :source-location location)))))

(defun analyze-quote (expr env context location)
  (declare (ignore env))
  (let ((val (second expr)))
    (cond
     ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
     ((symbolp val) (make-semantic-literal :value-type 'symbol :value val :source-location location))
     (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))

(defun analyze-sizeof-expression (expr env context location)
  (declare (ignore env context))
  (unless (= (length expr) 2)
    (error "sizeof expects exactly 1 argument: (sizeof type)"))
  (let* ((raw-type (second expr))
         (type-spec (parse-type-specifier raw-type)))
    (unless (valid-type-p type-spec)
      (error 'crisp-unknown-type-error :type-name raw-type :source-location location))
    (make-semantic-sizeof :type 'ulong
                          :target-type type-spec
                          :source-location location)))

(defun analyze-compiler-no-op (expr env context location)
  "Analyzes a (compiler-no-op) form, which results in a void literal.
   Used by compile-time macros (c-t-assert, c-t-output) to emit no code."
  (declare (ignore expr env context))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-nested-def-function (expr env context location)
  "Analyzes a nested `(def-function ...)` expression (e.g. from a template)."
  (declare (ignore env))
  (unless (compiler-context-allow-nested-def-function context)
    (error "Unsupported form 'DEF-FUNCTION' found in function body."))

  (unless (and *current-module* *current-builder*)
    (error "Cannot compile nested def-function without active LLVM context."))

  ;; Compile the function as a top-level form
  (compile-toplevel-form expr location *current-module* *current-builder* *current-di-builder* *current-di-compile-unit* *current-location-map*)

  ;; Return a void literal so it doesn't affect the expression value
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-template-instantiation (expr env context location)
  "Analyzes a `(template-instantiation ...)` form, allowing nested def-functions."
  (let ((old-allow (compiler-context-allow-nested-def-function context))
        (body (second expr)))
    (setf (compiler-context-allow-nested-def-function context) t)
    (unwind-protect
        (progn
         (log:info "ANALYZE-TEMPLATE-INSTANTIATION: Body=~a" body)
         ;; Eval the body to ensure macros (defmacro) and struct definitions (eval-when)
         ;; are registered in the current environment BEFORE analysis proceeds.
         ;; This allows subsequent forms in the function to usage the newly defined macros.
         ;; This allows subsequent forms in the function to usage the newly defined macros.
         (eval body)

         (let ((sym (find-symbol "MAKE-POINT_FLOAT" "CRISP-LANGUAGE")))
           (if sym
               (log:info "Check: MAKE-POINT_FLOAT in CRISP-LANGUAGE. Macro? ~a" (macro-function sym))
               (log:info "Check: MAKE-POINT_FLOAT NOT FOUND in CRISP-LANGUAGE")))

         ;; The body is typically a PROGN or a single form.
         ;; We analyze it recursively to generate IR for functions.
         (analyze-expression body env context location))
      ;; Cleanup
      (setf (compiler-context-allow-nested-def-function context) old-allow))))

(defun analyze-eval-when (expr env context location)
  "Analyzes (eval-when ...) forms by ignoring them in the runtime IR.
   Side effects (like struct registration) should have already occurred during macro expansion."
  (declare (ignore expr env context))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-is-set-expression (expr env context location)
  "Analyzes (is-set? var). Returns 1 (true) if var is bound in env, 0 (false) otherwise."
  (let ((var (second expr)))
    (unless (symbolp var)
      (error "is-set? expects a symbol, got ~s" var))
    ;; Since this is a compile-time check for optional parameters in specialized templates,
    ;; the 'env' contains *only* the parameters present for this specific specialization.
    (if (find-variable-in-env var env)
        (make-semantic-literal :value-type 'int :value 1 :source-location location)
        (make-semantic-literal :value-type 'int :value 0 :source-location location))))





(defun analyze-length-tilde-expression (expr env context location)
  "Analyzes (length~ arr).
   For (array T N): returns compile-time constant N as ulong literal.
   For tensor/vector/matrix types: dispatches to the runtime length~ accessor.
   Signals crisp-compiler-error if argument is none of the above."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "length~ expects exactly 1 argument: (length~ arr)"
           :source-location location))
  (let* ((arg-node  (analyze-expression (second expr) env context location))
         (raw-type  (semantic-node-type arg-node))
         (arg-type  (resolve-type-alias
                     (if (and (listp raw-type) (= (length raw-type) 1) (listp (first raw-type)))
                         (first raw-type)
                         raw-type)))
         ;; Expand vector/matrix sugar so we can inspect the canonical form
         (expanded  (expand-storage-handle-type-specifier (resolve-type-alias arg-type)))
         ;; A type is tensor-like if it's a mangled tensor symbol, a canonical (tensor ...) list,
         ;; or if expanding it yields a (tensor ...) list (i.e. vector/matrix sugar).
         (is-tensor (let ((resolved (resolve-type-alias arg-type)))
                      (or (and (symbolp resolved)
                               (let* ((parts (unmangle-template-struct-name resolved))
                                      (base  (first parts)))
                                 (and base (string-equal (symbol-name base) "TENSOR"))))
                          (and (listp resolved)
                               (symbolp (first resolved))
                               (string-equal (symbol-name (first resolved)) "TENSOR"))
                          ;; VECTOR / MATRIX expand to (tensor ...) via expand-storage-handle-type-specifier
                          (and (listp expanded)
                               (symbolp (first expanded))
                               (string-equal (symbol-name (first expanded)) "TENSOR"))))))
    (cond
     ;; Tensor / vector / matrix: delegate to the runtime length~ accessor
     (is-tensor
      (log:info "length~~: tensor/vector/matrix type ~a -> delegating to runtime accessor" arg-type)
      (analyze-function-call 'length~ expr env context location))
     ;; Fixed-size array: compile-time constant
     ((%array-type-p arg-type)
      (let* ((n-raw (third arg-type))
             (n     (etypecase n-raw
                      (integer n-raw)
                      (symbol  (parse-integer (symbol-name n-raw))))))
        (log:info "length~~: array type ~a -> N=~a" arg-type n)
        (make-semantic-literal :value-type 'ulong
                               :value      (coerce n '(unsigned-byte 64))
                               :source-location location)))
     ;; Neither: error
     (t
      (error 'crisp-compiler-error
             :message (format nil "length~~ requires an (array T N), tensor, vector, or matrix type, got ~a"
                              arg-type)
             :source-location location)))))


(defun analyze-dotimes-expression (expr env context location)
  "Analyzes (dotimes (var limit [stride]) body...).
   VAR is bound as the limit's type (int, ulong, etc.) in the body.
   STRIDE is optional; defaults to literal 1 of the limit's type.
   Returns a semantic-dotimes node (type void)."
  (unless (and (>= (length expr) 2) (listp (second expr)) (>= (length (second expr)) 2))
    (error 'crisp-compiler-error
           :message "Malformed dotimes: expected (dotimes (var limit [stride]) body...)"
           :source-location location))
  (let* ((binding    (second expr))
         (var-name   (first binding))
         (limit-form (second binding))
         (stride-form (third binding))   ;; NIL when omitted
         (body-forms (cddr expr))
         ;; Analyze limit
         (limit-node (analyze-expression limit-form env context (append location '(0))))
         (limit-type (get-single-value-type limit-node))
         (limit-ct   (gethash limit-type *crisp-types*)))
    ;; Validate: limit must be a registered integer type
    (unless (and limit-ct (member (crisp-type-category limit-ct)
                                  '(:signed-int :unsigned-int)))
      (error 'crisp-compiler-error
             :message (format nil "dotimes limit must be an integer type, got ~a" limit-type)
             :source-location location))
    ;; Analyze stride if provided
    (let ((stride-node (when stride-form
                         (analyze-expression stride-form env context (append location '(0 1))))))
      ;; Extend env: bind var as the limit's type
      (let* ((body-env  (cons (make-parameter-def :name var-name :type limit-type :kind :local) env))
             (body-nodes (analyze-body-expressions body-forms body-env context (append location '(1)))))
        (make-semantic-dotimes :type 'void
                               :var-name var-name
                               :limit-node limit-node
                               :stride-node stride-node
                               :body body-nodes
                               :source-location location)))))



(defun analyze-loop-vector-stride-expression (expr env context location)
  "Analyzes (loop-vector-stride VEC (VAR) BODY...).
   VEC must be a vector/matrix/tensor expression; VAR is bound to the element index (ulong).
   Expands at analysis time to:
     (let ((gid   (get-global-id 0))
           (gsize (get-global-work-size 0))
           (len   (length~ VEC)))
       (declare (grid-level))
       (dotimes (k len gsize)
         (let ((VAR (+ k gid)))
           (when (< VAR len)
             BODY...))))
   The (declare (grid-level)) enforces dispatch context and prevents nesting."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form   (second expr))
         (var-name   (first (third expr)))
         (body-forms (cdddr expr))
         ;; Gensym internal names to prevent variable capture
         (gid-sym   (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym   (gensym "LEN"))
         (k-sym     (gensym "K"))
         ;; Use crisp-language symbols so the analyzer dispatch table recognises them
         (cl-pkg         (find-package :crisp-language))
         (let-sym        (intern "LET"                  cl-pkg))
         (declare-sym    (intern "DECLARE"              cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL"           cl-pkg))
         (dotimes-sym    (intern "DOTIMES"              cl-pkg))
         (when-sym       (intern "WHEN"                 cl-pkg))
         (get-gid-sym    (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym  (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym  (intern "LENGTH~"              cl-pkg))
         (plus-sym       (intern "+"                    cl-pkg))
         (lt-sym         (intern "<"                    cl-pkg)))
    (let* ((inner-when
            ;; (when (< VAR len__) body...)
            (list* when-sym
                   (list lt-sym var-name len-sym)
                   body-forms))
           (inner-let
            ;; (let ((VAR (+ k__ gid__))) <inner-when>)
            (list let-sym
                  (list (list var-name (list plus-sym k-sym gid-sym)))
                  inner-when))
           (dotimes-form
            ;; (dotimes (k__ len__ gsize__) <inner-let>)
            (list dotimes-sym
                  (list k-sym len-sym gsize-sym)
                  inner-let))
           (expansion
            ;; (let ((gid__ ...) (gsize__ ...) (len__ ...))
            ;;   (declare (grid-level))
            ;;   <dotimes-form>)
            (list let-sym
                  (list (list gid-sym   (list get-gid-sym 0))
                        (list gsize-sym (list get-gsize-sym 0))
                        (list len-sym   (list len-tilde-sym vec-form)))
                  (list declare-sym (list grid-level-sym))
                  dotimes-form)))
      (analyze-expression expansion env context location))))



;; ==========================================================================
;; Endeavor 105 — tensor-stride and grid-stride.
;;
;; Phase A (this commit): safe `tensor-stride` analyzer.  Mirrors
;; analyze-loop-vector-stride-expression in src/analysis/control.lisp but
;; generalizes to N dimensions.  Form:
;;
;;   (tensor-stride T (b0 b1 ... b_{N-1}) BODY...)
;;
;; Expands to a single linear dotimes over total length, then decodes
;; multi-D coords from the flat index.  Decode direction depends on the
;; tensor's static contiguous-term (CT):
;;   :last  — warp varies last binding (row-major-style).
;;            flat = i0*s0 + i1*s1 + ... + i_{N-1}
;;            s_k = product(extents[k+1..N-1]); s_{N-1} = 1
;;   :first — warp varies first binding (col-major-style).
;;            flat = i_{N-1}*s_{N-1} + ... + i_0
;;            s_k = product(extents[0..k-1]); s_0 = 1
;;
;; Decode without `mod` (no user-facing op): i = flat / s; rem = flat - i*s.

(defun %ts-build-decode-bindings (flat-sym binding-syms stride-syms ct)
  "Builds the let* binding list that decodes FLAT-SYM into BINDING-SYMS using
   STRIDE-SYMS (per-iteration-strides for each dim, length N or N-1) under
   contiguous-term CT (:last or :first).

   For CT :last:  i0 = flat/s0; rem1 = flat - i0*s0; i1 = rem1/s1; ...; i_{N-1} = rem_{N-1}
   For CT :first: i_{N-1} = flat/s_{N-1}; rem1 = flat - i_{N-1}*s_{N-1}; ...; i_0 = rem_{N-1}"
  (let* ((cl-pkg  (find-package :crisp-language))
         (div-sym (intern "/"  cl-pkg))
         (sub-sym (intern "-"  cl-pkg))
         (mul-sym (intern "*"  cl-pkg))
         (n       (length binding-syms))
         (ordered-bindings (if (eq ct :first)
                               (reverse binding-syms)
                               binding-syms)))
    ;; ordered-bindings[k] gets stride-syms[k] for k < N-1; last gets rem.
    ;; For N=1, no decode needed — caller handles that case separately.
    (let ((bindings nil)
          (current-flat flat-sym))
      (loop for k from 0 below (1- n)
            for bsym = (nth k ordered-bindings)
            for s    = (nth k stride-syms)
            for next-rem = (gensym "REM")
            do (push (list bsym (list div-sym current-flat s)) bindings)
               (push (list next-rem (list sub-sym current-flat
                                          (list mul-sym bsym s)))
                     bindings)
               (setf current-flat next-rem))
      ;; Last binding takes the final remainder
      (push (list (nth (1- n) ordered-bindings) current-flat) bindings)
      (nreverse bindings))))

(defun %ts-build-stride-bindings (extents-syms ct)
  "Returns a list of (stride-sym stride-form) bindings for the per-iteration
   strides, in dim-index order (s_0 .. s_{N-2}).  For N=1, returns NIL.

   For CT :last:  s_k = product(E_{k+1} .. E_{N-1})
   For CT :first: s_k = product(E_0     .. E_{k-1})  but iteration uses these
                  in reverse, so we build s_{N-1} .. s_1 instead.
   Returned bindings have the same indexing convention as %ts-build-decode-bindings."
  (let* ((cl-pkg  (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (n       (length extents-syms))
         (result  nil))
    (when (= n 1)
      (return-from %ts-build-stride-bindings nil))
    (case ct
      (:last
       ;; ordered-bindings[k] corresponds to dim k; needs s_k = E_{k+1} * .. * E_{N-1}
       (loop for k from 0 below (1- n)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms (1+ k))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result)))
      (:first
       ;; ordered-bindings is reversed; ordered-bindings[k] corresponds to dim N-1-k.
       ;; Needs s = E_0 * .. * E_{N-2-k} for k = 0 .. N-2.
       (loop for k from 0 below (1- n)
             for dim-idx = (- n 2 k)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms 0 (1+ dim-idx))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result))))
    (nreverse result)))

(defun %ts-canonicalize-tensor-type (raw-type)
  "Resolves RAW-TYPE down to the canonical 6-tuple (TENSOR elem N addr aln ct).
   Mirrors %083-require-2d-tensor's normalisation but is arity-agnostic.
   Returns the 6-tuple, or NIL when RAW-TYPE isn't a tensor."
  (let* ((resolved (resolve-type-alias raw-type))
         (resolved (if (and (listp resolved) (= (length resolved) 1) (listp (first resolved)))
                       (first resolved)
                       resolved))
         (canon (cond
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (string-equal (symbol-name (first resolved)) "TENSOR"))
                   resolved)
                  ((symbolp resolved)
                   (let ((u (unmangle-template-struct-name resolved)))
                     (if (and (listp u) (symbolp (first u))
                              (string-equal (symbol-name (first u)) "TENSOR"))
                         u nil)))
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (member (symbol-name (first resolved))
                                '("VECTOR" "MATRIX") :test #'string-equal))
                   (canonicalize-type-specifier resolved))
                  (t nil))))
    canon))

(defun %ts-layout-tag-to-ct (tag n location)
  "Maps a strict layout-tag to its effective contiguous-term (:last or :first).
   Validates the tag and (for :row-major / :col-major) the 2D restriction."
  (case tag
    (:row-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :row-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :last)
    (:col-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :col-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :first)
    (:contiguous-last  :last)
    (:contiguous-first :first)
    (otherwise
     (error 'crisp-compiler-error
            :message (format nil "tensor-stride: unknown layout-tag ~S (expected :row-major, :col-major, :contiguous-last, or :contiguous-first)" tag)
            :source-location location))))

(defun analyze-tensor-stride-expression (expr env context location)
  "Analyzes the tensor-stride form, both variants:
     safe:   (tensor-stride T (BINDINGS...) BODY...)
     strict: (tensor-stride T LAYOUT-TAG (BINDINGS...) BODY...)

   For an N-D tensor with contiguous-term CT, expands to a single linear
   dotimes over total length, then decodes multi-D coords from the flat
   index.  Strict variant: validates LAYOUT-TAG against the tensor's static
   CT — disagreement is a compile-time error.

   The (declare (grid-level)) enforces dispatch context and prevents nesting."
  ;; Distinguish safe vs strict by whether (third expr) is a keyword.
  (let* ((strict-p   (keywordp (third expr)))
         (layout-tag (when strict-p (third expr)))
         (bindings   (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings
                 (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message (if strict-p
                          "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                          "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
             :source-location location))
  (let* ((n           (length bindings))
         ;; Pre-analyze tensor expression to read its static type — only the
         ;; type info is used; the form will be re-analyzed inside the let.
         (probe-node  (analyze-expression tensor-form env context (append location '(1))))
         (raw-type    (semantic-node-type probe-node))
         (canon-type  (%ts-canonicalize-tensor-type raw-type))
         (declared-n  (when (and (listp canon-type) (>= (length canon-type) 3))
                        (third canon-type)))
         ;; %get-tensor-ct may return the CT slot as a non-keyword symbol
         ;; (when canon-type came from unmangling).  Normalise to keyword.
         (static-ct-raw (if (listp canon-type)
                            (%get-tensor-ct canon-type)
                            :last))
         (static-ct   (cond
                        ((keywordp static-ct-raw) static-ct-raw)
                        ((symbolp static-ct-raw)
                         (intern (symbol-name static-ct-raw) :keyword))
                        (t :last)))
         (tag-ct      (when strict-p
                        (%ts-layout-tag-to-ct layout-tag n location)))
         ;; Strict variant: validate tag agrees with the tensor's static CT.
         (ct          (cond
                        ((not strict-p) static-ct)
                        ((null static-ct) tag-ct)
                        ((eq tag-ct static-ct) tag-ct)
                        (t
                         (error 'crisp-compiler-error
                                :message (format nil
                                                 "tensor-stride: layout-tag ~S implies contiguous-term ~S but the tensor's static type has contiguous-term ~S"
                                                 layout-tag tag-ct static-ct)
                                :source-location location)))))
    ;; Validate: declared-N must match bindings count when known.
    (when (and (integerp declared-n) (/= declared-n n))
      (error 'crisp-compiler-error
             :message (format nil
                              "tensor-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                              declared-n n)
             :source-location location))
    ;; Gensym names for internal vars
    (let* ((t-sym     (gensym "T"))
           (gid-sym   (gensym "GID"))
           (gsize-sym (gensym "GSIZE"))
           (len-sym   (gensym "LEN"))
           (k-sym     (gensym "K"))
           (flat-sym  (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           ;; Use crisp-language symbols for the recognised operators
           (cl-pkg         (find-package :crisp-language))
           (let-sym        (intern "LET"                  cl-pkg))
           (let*-sym       (intern "LET"                  cl-pkg))
           (declare-sym    (intern "DECLARE"              cl-pkg))
           (grid-level-sym (intern "GRID-LEVEL"           cl-pkg))
           (dotimes-sym    (intern "DOTIMES"              cl-pkg))
           (if-sym         (intern "IF"                   cl-pkg))
           (progn-sym      (intern "PROGN"                cl-pkg))
           (get-gid-sym    (intern "GET-GLOBAL-ID"        cl-pkg))
           (get-gsize-sym  (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym  (intern "LENGTH~"              cl-pkg))
           (extents-tilde  (intern "EXTENTS~"             cl-pkg))
           (aref-sym       (intern "~"                    cl-pkg))
           (plus-sym       (intern "+"                    cl-pkg))
           (lt-sym         (intern "<"                    cl-pkg))
           ;; extent reads: (~ (extents~ T) i)
           (extent-bindings
            (loop for esym in extents-syms
                  for i from 0
                  collect (list esym (list aref-sym
                                           (list extents-tilde t-sym)
                                           i))))
           (stride-bindings (%ts-build-stride-bindings extents-syms ct))
           (decode-bindings (if (= n 1)
                                ;; 1D: single binding gets the flat directly
                                (list (list (first bindings) flat-sym))
                                (%ts-build-decode-bindings
                                 flat-sym bindings
                                 (mapcar #'first stride-bindings)
                                 ct))))
      (let* ((inner-let
              ;; (let* (<decode-bindings>) BODY...)
              (list* let*-sym decode-bindings body-forms))
             (inner-when
              ;; (if (< flat len) <inner-let>) — using IF instead of WHEN so
              ;; the AD backward walker recognises the conditional (it has
              ;; an IF branch but no WHEN branch in %handle-single-value-backward).
              (list if-sym (list lt-sym flat-sym len-sym) inner-let))
             (flat-let
              ;; (let ((flat (+ k gid))) <inner-when>)
              (list let-sym
                    (list (list flat-sym (list plus-sym k-sym gid-sym)))
                    inner-when))
             (dotimes-form
              ;; (dotimes (k len gsize) <flat-let>)
              (list dotimes-sym
                    (list k-sym len-sym gsize-sym)
                    flat-let))
             (outer-let
              ;; (let* ((__t T) (gid ...) (gsize ...) (len ...) <extents> <strides>)
              ;;   (declare (grid-level))
              ;;   <dotimes-form>)
              (list* let*-sym
                     (append (list (list t-sym tensor-form)
                                   (list gid-sym   (list get-gid-sym 0))
                                   (list gsize-sym (list get-gsize-sym 0))
                                   (list len-sym   (list len-tilde-sym t-sym)))
                             extent-bindings
                             stride-bindings)
                     (list (list declare-sym (list grid-level-sym))
                           dotimes-form))))
        (analyze-expression outer-let env context location))))))

;; ==========================================================================
;; Phase C — grid-stride.  No tensor: a size-list and a bindings-list.
;; Total iteration = product of sizes.  Iteration is always row-major
;; (rightmost binding gets the warp).  Equivalent to safe tensor-stride
;; with CT=:last, but bypasses tensor introspection.
;;
;;   (grid-stride (<size-list>) (<bindings>) BODY...)

(defun analyze-grid-stride-expression (expr env context location)
  "Analyzes (grid-stride (SIZE-LIST) (BINDINGS) BODY...).
   Both lists must have the same arity (>= 1).  Expands to a single linear
   dotimes over the total iteration count (product of sizes), then decodes
   multi-D coords with rightmost-binding-gets-warp ordering."
  (unless (and (>= (length expr) 4)
               (listp (second expr))
               (listp (third expr))
               (every #'symbolp (third expr))
               (>= (length (second expr)) 1)
               (= (length (second expr)) (length (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed grid-stride: expected (grid-stride (SIZE ...) (BINDING ...) BODY...) with size and binding arity matching and >= 1"
           :source-location location))
  (let* ((size-forms  (second expr))
         (bindings    (third expr))
         (body-forms  (cdddr expr))
         (n           (length bindings))
         (cl-pkg      (find-package :crisp-language))
         (let-sym         (intern "LET"                  cl-pkg))
         (let*-sym        (intern "LET"                  cl-pkg))
         (declare-sym     (intern "DECLARE"              cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"           cl-pkg))
         (dotimes-sym     (intern "DOTIMES"              cl-pkg))
         (if-sym          (intern "IF"                   cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym        (intern "+"                    cl-pkg))
         (mul-sym         (intern "*"                    cl-pkg))
         (lt-sym          (intern "<"                    cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG"             cl-pkg))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (k-sym           (gensym "K"))
         (flat-sym        (gensym "FLAT"))
         (extents-syms    (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings   (loop for esym in extents-syms
                                for form in size-forms
                                collect (list esym (list to-ulong-sym form))))
         (len-form        (if (= n 1)
                              (first extents-syms)
                              (reduce (lambda (a b) (list mul-sym a b))
                                      extents-syms)))
         (stride-bindings (%ts-build-stride-bindings extents-syms :last))
         (decode-bindings (if (= n 1)
                              (list (list (first bindings) flat-sym))
                              (%ts-build-decode-bindings
                               flat-sym bindings
                               (mapcar #'first stride-bindings)
                               :last)))
         (inner-let       (list* let*-sym decode-bindings body-forms))
         (inner-if        (list if-sym (list lt-sym flat-sym len-sym) inner-let))
         (flat-let        (list let-sym
                                (list (list flat-sym (list plus-sym k-sym gid-sym)))
                                inner-if))
         (dotimes-form    (list dotimes-sym
                                (list k-sym len-sym gsize-sym)
                                flat-let))
         (outer-let
          (list* let*-sym
                 (append (list (list gid-sym   (list get-gid-sym 0))
                               (list gsize-sym (list get-gsize-sym 0)))
                         size-bindings
                         (list (list len-sym len-form))
                         stride-bindings)
                 (list (list declare-sym (list grid-level-sym))
                       dotimes-form))))
    (analyze-expression outer-let env context location)))



(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride
   and (endeavor 105) tensor-stride."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  ;; length~
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  ;; dotimes
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression)))
  ;; loop-vector-stride — dual-package registration
  (let ((sym-cl (intern "LOOP-VECTOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "LOOP-VECTOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-loop-vector-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-loop-vector-stride-expression)))
  ;; tensor-stride (105 Phase A) — dual-package registration
  (let ((sym-cl (intern "TENSOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TENSOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tensor-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tensor-stride-expression)))
  ;; grid-stride (105 Phase C) — dual-package registration
  (let ((sym-cl (intern "GRID-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "GRID-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-grid-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-grid-stride-expression))))

