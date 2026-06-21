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
    (let ((op (car form)))
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
       ;; GPU builtins (uniform / divergent roots)
       ((%uni-builtin-state op))
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
