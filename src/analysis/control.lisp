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

(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression."
  (unless (and (>= (length expr) 2) (listp (cadr expr)))
    (error "Malformed let form: ~a" expr))

  (let ((binding-forms (cadr expr))
        (body-forms (cddr expr)))
    ;; Implement let* scoping by sequentially building the environment.
    (multiple-value-bind (final-env analyzed-bindings)
        (let ((current-env env)
              (bindings-list '()))
          (loop for binding in binding-forms
                for i from 0 do
                  (log:debug "Analyzing let binding form: ~s" binding)

                  ;; Determine if this is a "flat" MVB binding like (a b (val))
                  ;; or a standard nested binding like ((a b) (val)) or (a (val)).
                  (let ((is-flat-mvb (and (> (length binding) 2)
                                          (not (listp (first binding))))))

                    (let* ((binding-vars (if is-flat-mvb
                                             (butlast binding)
                                             (if (and (= (length binding) 2) (listp (first binding)))
                                                 (first binding)
                                                 (list (first binding)))))
                           (init-form (first (last binding)))
                           ;; Track binding name for make-scratch-cell unique ID generation
                           (current-binding-name (if (= (length binding-vars) 1) (first binding-vars) nil))
                           ;; Analyze the value form
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
                       ;; Case 1: Single variable binding (standard let)
                       ((= (length binding-vars) 1)
                         (let* ((var-name (first binding-vars))
                                ;; For a single binding, we implicitly take the first return value's type.
                                (var-type (get-single-value-type init-node)))
                           (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a" var-name var-type)
                           (push (cons var-name init-node) bindings-list)
                           (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env))))

                       ;; Case 2: Multiple variable binding (destructuring)
                       ((> (length binding-vars) 1)
                         (unless (listp init-node-types)
                           (error "Cannot destructure a single-value return into multiple variables at ~a. Got type ~a for binding ~a."
                             (semantic-node-source-location init-node) init-node-types binding))
                         (unless (>= (length init-node-types) (length binding-vars))
                           (error "Not enough return values from ~a to bind ~a variables at ~a" init-form (length binding-vars) (semantic-node-source-location init-node)))

                         ;; The init-node (the function call) is analyzed once.
                         ;; We then create `extract-value` nodes for each variable.
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
          ;; The loop builds the bindings list in reverse, so we reverse it back.
          (values current-env (reverse bindings-list)))

      (let* ((analyzed-body (analyze-body-expressions body-forms final-env context (append location '(2))))
             (last-body-node (first (last analyzed-body)))
             (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
        (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                   analyzed-bindings analyzed-body return-type)
        (make-semantic-let :type return-type
                           :bindings analyzed-bindings
                           :body analyzed-body
                           :source-location location)))))

(defun analyze-progn-expression (expr env context location)
  "Analyzes a `(progn ...)` expression."
  (let ((body (cdr expr))
        (nodes '()))
    (dolist (form body)
      (push (analyze-expression form env context location) nodes))
    (setf nodes (nreverse nodes))
    ;; Determine type from the last node
    (let ((last-node (first (last nodes))))
      (make-semantic-progn
       :type (if last-node (semantic-node-type last-node) 'void)
       :body nodes
       :source-location location))))
#|
(defun analyze-return-expression (expr env context location)
  "Analyzes a `(return ...)` expression."
  (let* ((value-forms (rest expr))
         (value-nodes (loop for form in value-forms
                            for i from 1
                            collect (analyze-expression form env context (append location (list i)))))

         ;; Flatten types to check against signature
         (all-inferred-types (if value-nodes
                                 (loop for node in value-nodes
                                         append (let ((t-spec (semantic-node-type node)))
                                                  (if (and (listp t-spec) (not (valid-type-p t-spec)))
                                                      t-spec
                                                      (list t-spec))))
                                 '(nil)))

         ;; Context
         (current-func (compiler-context-current-compiling-function context))
         (sig (if current-func (first (gethash current-func *function-table*)) nil))
         (declared-ret (if sig (function-signature-return-types sig) nil))

         ;; Check for invalid return (Deferred Error 04)
         ;; If declared return is NIL (void), we cannot return values.
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
          ;; Only error if the value is NOT nil. (return nil) is allowed for void.
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

                                     |#

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

(defun register-control-analyzers ()
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
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when))
