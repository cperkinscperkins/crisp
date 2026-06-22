;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; Endeavor 120 — uniformity
;;;
;;; Two changes:
;;;   A. AD inert-function skip: calls to functions that are intentionally
;;;      non-differentiable (no differentiable params -> zero gradient) and to
;;;      the compile-time uniformity intrinsics are gradient-inert and must be
;;;      silently skipped in the backward walk, instead of erroring.
;;;   B. Interprocedural uniformity inference (Option 1, conservative meet):
;;;      a whole-program pre-pass that infers parameter uniformity from call
;;;      sites so users don't have to write (declare (uniform x)) when the
;;;      argument provably traces back to a uniform kernel argument.
;;; ============================================================

;; src/types/registry.lisp  (new module-scoped registries)
(defvar *inert-functions* (make-hash-table :test 'eq)
  "Set of user functions intentionally skipped from _GRAD generation because
   they have no differentiable parameters (their gradient is identically
   zero). Calls to these are gradient-inert and are silently skipped during
   the AD backward walk -- in contrast to genuinely non-differentiable
   functions, whose _GRAD generation errored and which must still error if
   called from a differentiable kernel. Cleared per-module in
   analyze-signatures-pass.")

(defvar *fn-normalized-info* (make-hash-table :test 'eq)
  "Per-module map: function name -> plist (:params :body :entry-point-p),
   captured during analyze-signatures-pass from the macro-expanded
   def-function forms. Consumed by infer-param-uniformity. Cleared per-module.")

(defvar *inferred-param-uniformity* (make-hash-table :test 'eq)
  "Per-module map: function name -> alist (param-name . :uniform|:divergent|
   :unknown), the result of infer-param-uniformity. Applied (upgrade-only) to
   the body-compilation environment by inject-implicit-arguments. Cleared
   per-module.")

(defvar *uni-meet-table* nil
  "Dynamic: hash callee-name -> (hash param-name -> accumulated meet state).
   Bound for the duration of infer-param-uniformity.")

;;; ------------------------------------------------------------
;;; A. AD inert-function skip
;;; ------------------------------------------------------------

;; src/autodiff.lisp
(defun %generate-backward-function-ast (name params declarations body-forms)
  "Generates the backward companion (def-function NAME_GRAD ...) for a
differentiable user function."
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  (when (%trivial-accessor-body-p body-forms)
        (log:info "AUTODIFF: ~a is a trivial field-extraction accessor — skipping _GRAD generation." name)
        (return-from %generate-backward-function-ast nil))
  (let* ((pkg (symbol-package name)))
    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)
      (let* ((float-param-entries
              (loop for pd in env
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-float-type-p (parameter-def-type pd)))
                    collect pd))
             (float-param-syms (mapcar #'parameter-def-name float-param-entries))
             (record-param-info (%collect-record-param-info env pkg))
             (all-diff-param-syms-for-return (%collect-all-diff-param-syms-for-return env record-param-info))
             (record-param-field-adjs-ht (%build-record-param-field-adjs-ht record-param-info))
             (n-float-params
              (loop for pd in env
                      when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                      sum (%count-differentiable-contributions (parameter-def-type pd))))
             (return-types-non-void (remove nil return-types))
             (n-return (length return-types-non-void))
             (fn-param-entries
              (loop for pd in env for i from 0
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-function-type-p (parameter-def-type pd)))
                    collect (cons i pd)))
             (is-hof (consp fn-param-entries)))

        (when (and (zerop n-float-params)
                   (not (%has-tensor-diff-param-p env)))
              (log:info "AUTODIFF: ~a has no differentiable params — skipping _GRAD generation (marking gradient-inert)." name)
              ;; Endeavor 120: record that this skip is *intentional* (zero
              ;; gradient), so calls to it are silently skipped in the backward
              ;; walk rather than erroring.
              (setf (gethash name *inert-functions*) t)
              (return-from %generate-backward-function-ast nil))

        (if is-hof
            (%register-hof-differentiable-function name env float-param-syms fn-param-entries n-return body-forms)
            (%generate-backward-companion-ast-body name params env declarations body-forms pkg n-float-params n-return
                                                   return-types-non-void record-param-info record-param-field-adjs-ht all-diff-param-syms-for-return))))))

;; src/autodiff.lisp
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
   ((and (consp expr) (member (car expr) '(+ - * / sin cos) :test #'eq))
     (%handle-math-and-trig-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (eq (car expr) '~))
     (%handle-tilde-backward v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms))
   ((and (consp expr)
         (symbolp (car expr))
         (gethash (car expr) *differentiable-functions*))
     (%handle-sub-fn-call-backward v expr emit-fn local-adj-fn hof-handler-fn))
   ((%is-accessor-p expr)
     (%handle-accessor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
         *record-param-field-adjs*
         (gethash v *record-param-field-adjs*))
     (%handle-constructor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
     nil)
   ((and (consp expr) (symbolp (car expr))
         (string= (symbol-name (car expr)) "IF"))
     nil)
   ((and (consp expr) (symbolp (car expr))
         (%backward-skip-fn-p (car expr)))
     nil)
   ;; Endeavor 120: gradient-inert calls.
   ;;  - *inert-functions*: user functions with no differentiable params
   ;;    (zero gradient), recorded by %generate-backward-function-ast.
   ;;  - the compile-time uniformity intrinsics, which fold to constants and
   ;;    carry no gradient.
   ((and (consp expr) (symbolp (car expr))
         (or (gethash (car expr) *inert-functions*)
             (member (symbol-name (car expr))
                     '("PROVABLY-UNIFORM?" "PROVABLY-DIVERGENT?" "UNIFORMITY-STATE"
                       "TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
                     :test #'string=)))
     nil)
   ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
           (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
   (t nil)))

;;; ------------------------------------------------------------
;;; B. Interprocedural uniformity inference (pre-pass)
;;; ------------------------------------------------------------

;; src/analysis/core.lisp  (new helpers)
(defun %uni-param-names (params)
  "Extract ordered parameter names from a def-function parameter list,
   handling both plain symbols and (name type ...) interleaved specs."
  (loop for p in params
        collect (if (consp p) (first p) p)))

(defun %uni-combine (states)
  "Taint-max over a list of uniformity STATES. :divergent dominates, then
   :unknown, otherwise :uniform. (Empty list -> :uniform.)"
  (cond ((null states) :uniform)
        ((member :divergent states) :divergent)
        ((member :unknown states) :unknown)
        (t :uniform)))

(defun %uni-builtin-state (op)
  "Return :uniform or :divergent if OP is a recognized GPU builtin operator,
   else NIL. Matched by symbol-name so it is package-agnostic."
  (let ((n (symbol-name op)))
    (cond ((member n '("GET-LOCAL-ID" "GET-GLOBAL-ID") :test #'string=) :divergent)
          ((member n '("GET-WORKGROUP-ID" "GET-WORKGROUP-SIZE" "GET-WARP-SIZE"
                       "GET-GLOBAL-SIZE" "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                       "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET")
                   :test #'string=) :uniform)
          (t nil))))

(defun %uni-contribute (callee param-name state)
  "Meet STATE into *uni-meet-table*[CALLEE][PARAM-NAME]."
  (let ((tbl (or (gethash callee *uni-meet-table*)
                 (setf (gethash callee *uni-meet-table*) (make-hash-table :test 'eq)))))
    (multiple-value-bind (existing present) (gethash param-name tbl)
      (setf (gethash param-name tbl)
            (if present (%uni-combine (list existing state)) state)))))

(defun %uni-analyze-let (form env)
  "Uniformity walk of a (let (bindings...) body...) form. Crisp let is
   let*-like, so bindings extend ENV sequentially. Multi-value bindings bind
   each var to :unknown (conservative). Returns the state of the last body
   form."
  (let ((bindings (second form))
        (body (cddr form))
        (new-env env))
    (dolist (b bindings)
      (cond
       ((and (consp b) (= (length b) 2) (symbolp (first b)))
        (let ((st (%uni-analyze (second b) new-env)))
          (setf new-env (acons (first b) st new-env))))
       ((consp b)
        ;; multi-value bind: walk the init (last element) for nested calls;
        ;; the bound vars are conservatively :unknown.
        (%uni-analyze (car (last b)) new-env)
        (dolist (vv (butlast b))
          (when (symbolp vv) (setf new-env (acons vv :unknown new-env)))))
       (t nil)))
    (let ((last-state :uniform))
      (dolist (f body last-state)
        (setf last-state (%uni-analyze f new-env))))))

(defun %uni-analyze (form env)
  "Lightweight uniformity walk of a raw body FORM under ENV (an alist
   name -> state). Returns FORM's uniformity state; as a side effect,
   contributes call-site argument states to *uni-meet-table* for every call
   to a known user function (see infer-param-uniformity)."
  (cond
   ((null form) :uniform)
   ((integerp form) :uniform)
   ((floatp form) :uniform)
   ((keywordp form) :uniform)
   ((symbolp form)
    (let ((cell (assoc form env)))
      (if cell (cdr cell) :unknown)))
   ((consp form)
    (let* ((op (car form))
           ;; Compute builtin state up front. NOTE: crisp.compiler's `cond`
           ;; macro drops the value of a clause that has only a test and no
           ;; body, so we must NOT rely on the bare `((%uni-builtin-state op))`
           ;; idiom — give the builtin clause an explicit body (`(bs bs)`).
           (bs (and (symbolp op) (%uni-builtin-state op))))
      (cond
       ((not (symbolp op))
        ;; e.g. ((lambda ...) ...) — just recurse for nested calls.
        (dolist (a (cdr form)) (when (consp a) (%uni-analyze a env)))
        :unknown)
       ;; let / let* : sequential scoping
       ((string-equal (symbol-name op) "LET")
        (%uni-analyze-let form env))
       ;; arithmetic / comparison contagion
       ((member (symbol-name op)
                '("+" "-" "*" "/" "SIN" "COS"
                  "<" ">" "<=" ">=" "=" "/=" "MOD" "REM")
                :test #'string=)
        (%uni-combine (mapcar (lambda (a) (%uni-analyze a env)) (cdr form))))
       ;; forced-uniform constructs
       ((member (symbol-name op) '("TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM") :test #'string=)
        (dolist (a (cdr form)) (%uni-analyze a env))
        :uniform)
       ;; type conversions are uniformity-transparent (Endeavor 120 gap #6).
       ;; (to-*-uniform handled above, so a TO-/AS- prefix here is a cast.)
       ((and (> (length (symbol-name op)) 3)
             (or (string= (subseq (symbol-name op) 0 3) "TO-")
                 (string= (subseq (symbol-name op) 0 3) "AS-")))
        (%uni-combine (mapcar (lambda (a) (%uni-analyze a env)) (cdr form))))
       ;; GPU builtins (uniform / divergent roots). Explicit body required —
       ;; see the cond-quirk note above.
       (bs bs)
       ;; call to a known user function: contribute argument uniformities
       ((gethash op *fn-normalized-info*)
        (let* ((callee-params (%uni-param-names (getf (gethash op *fn-normalized-info*) :params)))
               (args (cdr form))
               (arg-states (mapcar (lambda (a) (%uni-analyze a env)) args)))
          ;; Only contribute when arity matches positionally — exploded
          ;; storage-handle calls or arity mismatches are left uninferred
          ;; (safe: callee param stays :unknown).
          (when (= (length args) (length callee-params))
            (loop for pname in callee-params
                  for st in arg-states
                  do (%uni-contribute op pname st)))
          :unknown))
       ;; anything else: recurse to discover nested calls; value :unknown
       (t
        (dolist (a (cdr form)) (when (consp a) (%uni-analyze a env)))
        :unknown))))
   (t :unknown)))

(defun %uni-topo-order (nodes)
  "Topological order of NODES (function-name symbols) by *call-graph* edges
   caller->callee, callers first. Recursion is banned so this is a DAG; any
   leftover (cyclic) nodes are appended at the end."
  (let ((indeg (make-hash-table :test 'eq))
        (succ (make-hash-table :test 'eq))
        (nodeset (make-hash-table :test 'eq)))
    (dolist (n nodes)
      (setf (gethash n nodeset) t)
      (setf (gethash n indeg) 0))
    (dolist (caller nodes)
      (let ((callees (remove-duplicates
                      (loop for c in (gethash caller *call-graph*)
                            when (and (gethash c nodeset) (not (eq c caller)))
                            collect c))))
        (setf (gethash caller succ) callees)
        (dolist (c callees) (incf (gethash c indeg)))))
    (let ((queue (loop for n in nodes when (zerop (gethash n indeg)) collect n))
          (order '()))
      (loop while queue do
        (let ((n (pop queue)))
          (push n order)
          (dolist (c (gethash n succ))
            (when (zerop (decf (gethash c indeg)))
              (push c queue)))))
      (dolist (n nodes)
        (unless (member n order) (push n order)))
      (nreverse order))))

(defun infer-param-uniformity ()
  "Endeavor 120 (Option 1): conservative interprocedural uniformity inference.
   Seeds kernel (entry-point) parameters as :uniform, then propagates argument
   uniformity down the call graph (callers processed before callees). A
   function parameter is inferred :uniform only when EVERY observed call site
   passes a provably-uniform argument. Results are stored in
   *inferred-param-uniformity* and applied (upgrade-only) to the
   body-compilation environment by inject-implicit-arguments.

   Generic/template functions are skipped: their call sites can be created
   lazily during Pass 2, so the pre-pass cannot see all of them, and an
   incorrectly-inferred :uniform would be unsafe."
  (let ((nodes (loop for k being the hash-keys of *fn-normalized-info* collect k)))
    (let ((*uni-meet-table* (make-hash-table :test 'eq))
          (order (%uni-topo-order nodes)))
      (dolist (name order)
        (let* ((info (gethash name *fn-normalized-info*))
               (params (%uni-param-names (getf info :params)))
               (entry-point-p (getf info :entry-point-p))
               (body (getf info :body))
               (lazy-p (or (and (boundp '*generic-functions*) (gethash name *generic-functions*))
                           (and (boundp '*template-registry*) (gethash name *template-registry*))))
               (param-states
                (cond
                 (entry-point-p
                  (loop for p in params collect (cons p :uniform)))
                 (lazy-p
                  (loop for p in params collect (cons p :unknown)))
                 (t
                  (let ((tbl (gethash name *uni-meet-table*)))
                    (loop for p in params
                          collect (cons p (if tbl
                                              (multiple-value-bind (s present) (gethash p tbl)
                                                (if present s :unknown))
                                              :unknown))))))))
          (setf (gethash name *inferred-param-uniformity*) param-states)
          ;; Walk the body to contribute argument uniformities to callees,
          ;; using this function's own resolved parameter environment.
          (let ((env param-states))
            (dolist (f body)
              (%uni-analyze f env)))))
      (log:debug "Endeavor 120 inferred param uniformity: ~s"
                 (loop for k being the hash-keys of *inferred-param-uniformity*
                       using (hash-value vv) collect (cons k vv))))))

;; src/analysis/core.lisp
(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052).
Also scans *template-registry* for HOF templates after walk-code-forms.

Endeavor 120: also captures each function's macro-expanded params/body and
runs infer-param-uniformity once the call graph is complete."
  ;; Endeavor 120: reset per-module uniformity/inert state.
  (clrhash *inert-functions*)
  (clrhash *fn-normalized-info*)
  (clrhash *inferred-param-uniformity*)
  ;; Step 1: Pre-populate from top-level def-function forms.
  (%pre-register-differentiable-fns forms)
  ;; Step 2: Walk all forms (registers templates, signatures, etc.)
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                               (body (cdddr form))
                               (body-forms (loop for f in body
                                                 unless (and (listp f) (eq (car f) 'declare))
                                                 collect f))
                               (decls (loop for f in body
                                            when (and (listp f) (eq (car f) 'declare))
                                            append (rest f)))
                               (entry-point-p (loop for d in decls
                                                    thereis (and (listp d) (symbolp (first d))
                                                                 (string-equal (symbol-name (first d)) "ENTRY-POINT")))))
                       ;; Endeavor 120: capture normalized info for inference.
                       (setf (gethash name *fn-normalized-info*)
                             (list :params (third form) :body body-forms :entry-point-p entry-point-p))
                       (register-function-signature form location)
                       (let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees))))))
  ;; Step 3: After walk-code-forms, scan template registry for HOF templates.
  (%pre-register-hof-templates)
  ;; Endeavor 120: interprocedural uniformity inference (call graph is ready).
  (infer-param-uniformity))

;; src/environment.lisp
(defun inject-implicit-arguments (name explicit-env)
  "Injects implicit arguments into the environment for carrier functions.
   Types in *implicit-arg-map* are already in the correct form:
   mangled symbols for tensors (no integers to mangle-type-spec),
   canonical lists for cells (preserved for hoist metadata).

   Endeavor 120: also stamps interprocedurally-inferred :uniform onto the
   returned parameter-defs. Upgrade-only — it never downgrades a parameter
   already marked :uniform by an explicit (declare (uniform ...)) or by
   entry-point status, and it does not touch the stored function signature, so
   call-site uniformity constraints are unaffected."
  (let* ((implicit-info (gethash name *implicit-arg-map*))
         (implicit-env
          (when implicit-info
            (loop for (param-name . param-type) in implicit-info
                  collect (make-parameter-def
                           :name param-name
                           :type param-type
                           :kind :in))))
         (env (append implicit-env explicit-env))
         (inferred (gethash name *inferred-param-uniformity*)))
    (when inferred
      (dolist (p env)
        (let ((cell (assoc (parameter-def-name p) inferred)))
          (when (and cell (eq (cdr cell) :uniform)
                     (not (eq (parameter-def-uniformity p) :uniform)))
            (log:debug "Endeavor 120: inferred ~a.~a as :uniform" name (parameter-def-name p))
            (setf (parameter-def-uniformity p) :uniform)))))
    env))

;;; ------------------------------------------------------------
;;; Endeavor 120 gap #1: let-binding uniformity propagation
;;;
;;; analyze-let-expression created each binding's parameter-def with the
;;; default :uniformity :unknown, so a variable bound to a uniform root (or to
;;; (to-workgroup-uniform ...)) read back as :unknown -- breaking if+/dotimes+
;;; and rendering the to-*-uniform forms decorative. Fix: stamp each binding's
;;; :uniformity from the init expression's calculated uniformity state (computed
;;; in the pre-binding environment, matching let*'s sequential scoping).
;;; ------------------------------------------------------------

;;; Endeavor 120 gap #4: to-*-uniform may only be the direct initializer of a
;;; let binding. *to-uniform-allowed* is bound T by analyze-let-expression only
;;; when the binding's init-form is syntactically a to-*-uniform call; the
;;; analyzers below error otherwise.
(defvar *to-uniform-allowed* nil
  "T only while analyzing a let-binding initializer that is itself a direct
   to-warp-uniform / to-workgroup-uniform form.")

(defun %to-uniform-form-p (form)
  "T if FORM is a direct (to-warp-uniform ...) or (to-workgroup-uniform ...)."
  (and (consp form) (symbolp (car form))
       (member (symbol-name (car form))
               '("TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
               :test #'string=)))

;; src/analysis/control.lisp
(defun analyze-to-workgroup-uniform (expr env context location)
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-workgroup-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-workgroup-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-workgroup-uniform expects 1 argument" :source-location location))
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (make-semantic-to-workgroup-uniform :type type :value-node val-node :source-location location)))

;; src/analysis/control.lisp
(defun analyze-to-warp-uniform (expr env context location)
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-warp-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-warp-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-warp-uniform expects 1 argument" :source-location location))
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (make-semantic-to-warp-uniform :type type :value-node val-node :source-location location)))

;; src/analysis/control.lisp
(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression.
   Extended (091): strips leading declare forms from the body, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules.
   Extended (120): propagates each binding's uniformity from its init."
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
                                        ;; Endeavor 120 gap #4: permit to-*-uniform only when it
                                        ;; is the direct initializer of this binding.
                                        (let ((*to-uniform-allowed* (%to-uniform-form-p init-form)))
                                          (analyze-expression init-form current-env context
                                                              (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1)))))
                                      (when current-binding-name
                                            (setf (compiler-context-current-binding-name context) old-name)))))
                                 (init-node-types (semantic-node-type init-node))
                                 ;; Endeavor 120: uniformity of the init, computed in the
                                 ;; pre-binding environment (let* sequential scope).
                                 (init-uniformity (calculate-uniformity-state init-node current-env)))

                            (cond
                             ((= (length binding-vars) 1)
                               (let* ((var-name (first binding-vars))
                                      (var-type (get-single-value-type init-node)))
                                 (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a Uniformity: ~a" var-name var-type init-uniformity)
                                 (push (cons var-name init-node) bindings-list)
                                 (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                             :uniformity init-uniformity)
                                                         current-env))))

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
                                         (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                                     :uniformity init-uniformity)
                                                                 current-env)))))
                             (t (error "Malformed let binding: ~a" binding))))))
                (values current-env (reverse bindings-list)))

            ;; Endeavor 120 gap #2/#3: apply (declare (uniform v)) hints from the
            ;; let block. Only let-bound variables are eligible (so the hint
            ;; cannot leak into an outer scope's shared parameter-def). A hint on
            ;; a provably-divergent binding is an error -- the user can always use
            ;; a plain if/when/dotimes instead, so an unsafe assertion buys
            ;; nothing.
            (let ((let-bound-names (mapcar #'car analyzed-bindings)))
              (dolist (uvar (loop for d in decl-specs
                                  when (and (consp d) (symbolp (car d))
                                            (string-equal (symbol-name (car d)) "UNIFORM"))
                                  append (rest d)))
                (cond
                 ((not (member uvar let-bound-names))
                  (log:warn "(declare (uniform ~s)) ignored: not a variable bound by this let." uvar))
                 (t
                  (let ((pd (find-variable-in-env uvar final-env)))
                    (cond
                     ((null pd)
                      (log:warn "(declare (uniform ~s)): binding not found." uvar))
                     ((eq (parameter-def-uniformity pd) :divergent)
                      (error 'crisp-compiler-error
                        :message (format nil "(declare (uniform ~a)) is invalid: ~a is provably divergent in this scope. Use a plain if/when/dotimes instead."
                                         uvar uvar)
                        :source-location location))
                     (t
                      (log:debug "Endeavor 120: (declare (uniform ~a)) -> :uniform (was ~a)"
                                 uvar (parameter-def-uniformity pd))
                      (setf (parameter-def-uniformity pd) :uniform))))))))

            (let* ((analyzed-body (analyze-body-expressions body-forms final-env context (append location '(2))))
                   (last-body-node (first (last analyzed-body)))
                   (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
              (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                         analyzed-bindings analyzed-body return-type)
              (make-semantic-let :type return-type
                                 :bindings analyzed-bindings
                                 :body analyzed-body
                                 :source-location location))))))))

;;; ------------------------------------------------------------
;;; Endeavor 120 gap #6: type conversions are uniformity-transparent
;;;
;;; (to-ulong x), (to-float x), (as-int x), etc. all produce semantic-cast
;;; nodes (base struct; to-* / as-* share the :include hierarchy). Previously
;;; these hit the :unknown fallback, so a uniform value run through a
;;; conversion (extremely common: `(< (get-workgroup-id 0) (to-ulong 4))`)
;;; collapsed to :unknown and if+/dotimes+/when+ rejected it. A cast carries
;;; the uniformity of its operand unchanged.
;;; ------------------------------------------------------------

;; src/analysis/core.lisp
(defun calculate-uniformity-state (node env)
  "Recursively determines the uniformity state of an analyzed semantic AST node.
   Returns :uniform, :divergent, or :unknown.
   - Literals are :uniform.
   - Variables are looked up in the env for their stored uniformity. If env lookup
     fails or missing, defaults to :unknown. Kernel arguments are initialized to :uniform.
   - GPU Builtins: get-workgroup-id is :uniform, get-local-id/get-global-id are :divergent.
   - Math operations (add, sub, mul, etc): if all args are :uniform, it is :uniform.
     If any arg is :divergent, it is :divergent. Otherwise :unknown.
   - Casts/conversions (to-*, as-*) are passthrough: same uniformity as the operand.
   - Memory reads (aref) are :divergent (or :unknown) unless explicitly cast."
  (etypecase node
    (semantic-literal :uniform)
    (semantic-device-vec-literal
     (let ((states (mapcar (lambda (el) (calculate-uniformity-state el env))
                           (semantic-device-vec-literal-elements node))))
       (cond
         ((some (lambda (s) (eq s :divergent)) states) :divergent)
         ((every (lambda (s) (eq s :uniform)) states) :uniform)
         (t :unknown))))
    (semantic-var-read
     (let ((v (find-variable-in-env (semantic-var-read-name node) env)))
       (if v
           (parameter-def-uniformity v)
           :unknown)))
    (semantic-add
     (let ((ls (calculate-uniformity-state (semantic-add-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-add-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sub
     (let ((ls (calculate-uniformity-state (semantic-sub-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-sub-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-mul
     (let ((ls (calculate-uniformity-state (semantic-mul-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-mul-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-div
     (let ((ls (calculate-uniformity-state (semantic-div-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-div-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sin
     (calculate-uniformity-state (semantic-sin-arg node) env))
    (semantic-cos
     (calculate-uniformity-state (semantic-cos-arg node) env))
    ;; Endeavor 120: casts/conversions (to-*, as-*) are passthrough. Covers all
    ;; semantic-cast subtypes (value-cast, bitcast, fp-truncate-cast, truncate).
    (semantic-cast
     (calculate-uniformity-state (semantic-cast-arg node) env))
    ((or semantic-lt semantic-gt semantic-le semantic-ge semantic-eq semantic-neq)
     (let ((ls (calculate-uniformity-state (slot-value node 'left-arg) env))
           (rs (calculate-uniformity-state (slot-value node 'right-arg) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-if
     (let ((cs (calculate-uniformity-state (semantic-if-condition-node node) env))
           (ts (calculate-uniformity-state (semantic-if-then-node node) env))
           (es (calculate-uniformity-state (semantic-if-else-node node) env)))
       (cond ((or (eq cs :divergent) (eq ts :divergent) (eq es :divergent)) :divergent)
             ((and (eq cs :uniform) (eq ts :uniform) (eq es :uniform)) :uniform)
             (t :unknown))))
    (semantic-let
     :unknown)
    (semantic-gpu-builtin
     (let ((name (semantic-gpu-builtin-builtin-name node)))
       (cond ((member name '(:get-global-id :get-local-id)) :divergent)
             ((member name '(:get-workgroup-id :get-workgroup-size :get-warp-size :sync-workgroup :get-global-size :get-num-groups)) :uniform)
             (t :unknown))))
    (semantic-to-workgroup-uniform :uniform)
    (semantic-to-warp-uniform :uniform)
    ;; Memory reads and anything else
    (t :unknown)))

;;; ------------------------------------------------------------
;;; Endeavor 120 gap #5: set! taint inside a divergent block
;;;
;;; Mutating a variable via set! inside a divergent control-flow region
;;; (where *divergent-scope-depth* > 0, set by if/when/cond with a non-uniform
;;; condition) permanently taints that variable :divergent for the remainder of
;;; the scope -- different threads take different paths, so the value diverges.
;;; Assigning a divergent value taints likewise (contagion). The uniformity is
;;; stored on the shared parameter-def, so a subsequent if+ on the variable
;;; correctly observes the taint.
;;; ------------------------------------------------------------

;; src/analysis/structs.lisp
(defun %analyze-set!-simple-variable (target-form value-node env location)
  "Helper to analyze simple variable assignment (set! target-form value-node).
   Endeavor 120 (gap #5): taints the variable :divergent when mutated inside a
   divergent block, or when assigned a divergent value."
  (let ((var-info (find-variable-in-env target-form env)))
    (unless var-info
      (error 'crisp-unknown-variable :name target-form :source-location location))
    (let ((var-type (parameter-def-type var-info))
          (val-type (semantic-node-type value-node)))
      (unless (types-compatible-p val-type var-type)
        (error 'crisp-type-error :expected var-type :inferred val-type
               :source-location location)))
    ;; Endeavor 120: uniformity taint on mutation.
    (let ((val-uni (calculate-uniformity-state value-node env)))
      (cond
       ((> *divergent-scope-depth* 0)
        (log:debug "Endeavor 120: set! ~a inside divergent scope -> :divergent" target-form)
        (setf (parameter-def-uniformity var-info) :divergent))
       ((eq val-uni :divergent)
        (log:debug "Endeavor 120: set! ~a := divergent value -> :divergent" target-form)
        (setf (parameter-def-uniformity var-info) :divergent))))
    (make-semantic-set!
     :target-node (make-semantic-var-read
                   :name target-form
                   :type (parameter-def-type var-info)
                   :source-location location)
     :value-node value-node
     :source-location location)))
