;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; ============================================================
;;; Feature 052 — Autodiff of Sub-Functions
;;; ============================================================

;;; A1: Registry of differentiable functions
;;; -----------------------------------------
;;; Maps function-name symbol ->
;;;   plist (:bkwd-name sym :n-float-params N :n-return M)
;;; where N = number of float-typed input params (= number of delta return values)
;;;       M = number of forward return values (= number of t_grad inputs to _GRAD fn)
;;;
;;; src/types/registry.lisp

(defvar *differentiable-functions* (make-hash-table :test 'eq)
  "Registry of user def-functions for which a _GRAD backward companion has been generated.
Maps function-name -> (:bkwd-name sym :n-float-params N :n-return M).")

;;; A1b: Override initialize-compiler to clear the registry on each compile
;;; src/compiler.lisp

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

  ;; Feature 052: clear differentiable-functions registry on each compile.
  (clrhash *differentiable-functions*)

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
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Clear partial template instantiations and their CL dispatch macros.
  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (log:info "INITIALIZE-COMPILER: clearing stale CL dispatch macro ~a" dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  ;; Initialize built-in structs (storage)
  (register-builtins))


;;; A4: Fix flatten-anf-body to include multi-value bindings
;;; ---------------------------------------------------------
;;; The original only pushed bindings of length exactly 2, silently dropping
;;; multi-value bindings like (x y (fn a b)) which have length 3.
;;; This fix accepts any binding of length >= 2 so multi-value sub-function
;;; results survive flattening and are visible to the backward walker.
;;; src/anf-transform.lisp

(defun flatten-anf-body (anf-body)
  "Flattens an ANF body into a sequential list of bindings and side-effects.
Returns a list of elements formatted as either (var expr), (var0 var1 expr) for
multi-value bindings, or just expr (for side-effects).
Accepts bindings of length >= 2 (fix: was = 2, dropping multi-value bindings)."
  (let ((flat nil))
    (labels ((walk (expr)
               (cond
                ((and (consp expr) (eq (car expr) 'let))
                  (let ((bindings (cadr expr))
                        (body (cddr expr)))
                    (dolist (b bindings)
                      ;; Accept length >= 2: covers (var expr) and (v0 v1 ... expr)
                      (when (and (consp b) (>= (length b) 2))
                        (push b flat)))
                    (dolist (f body)
                      (unless (and (consp f) (eq (car f) 'declare))
                        (walk f)))))
                ((and (consp expr) (eq (car expr) 'progn))
                  (dolist (f (cdr expr))
                    (walk f)))
                ((and (consp expr) (eq (car expr) 'declare))
                  nil)
                (t
                  (push expr flat)))))
      (dolist (form anf-body)
        (walk form))
      (nreverse flat))))


;;; A2/A3: Backward companions for def-function
;;; ============================================

;;; Helper: is this function name already a _GRAD companion?
;;; Used to prevent recursive generation in the def-function macro patch.
;;; src/autodiff.lisp

(defun %fn-name-is-grad-p (name)
  "Returns T if NAME ends with the _GRAD suffix, indicating it is already
a backward companion and should not receive its own companion."
  (cl:let ((s (symbol-name name)))
    (cl:and (> (cl:length s) 5)
            (string= (cl:subseq s (- (cl:length s) 5)) "_GRAD"))))


;;; Helper: extract return variable(s) from the last element of a flat ANF body.
;;; The last element is either a plain symbol (implicit return) or
;;; a (return v0 v1 ...) form.
;;; src/autodiff.lisp

(defun %extract-return-vars (flat-anf)
  "Returns the list of return-value symbols from FLAT-ANF.
Handles both implicit last-expression and explicit (return v0 v1 ...) forms."
  (cl:let ((last-form (cl:car (cl:last flat-anf))))
    (cond
      ((symbolp last-form)
       (cl:list last-form))
      ((and (consp last-form) (eq (cl:first last-form) 'return))
       (cl:rest last-form))
      (t
       (error "Cannot extract return vars from flat-ANF last form: ~s" last-form)))))


;;; A2: %generate-backward-function-walk
;;; -------------------------------------
;;; Analogous to generate-backward-walk but for def-function bodies.
;;; Key differences:
;;;   - Output adjoints are seeded from T_GRAD params, not from (set! (~ C) ..) forms.
;;;   - Emits (return adj0 adj1 ...) for float params rather than cell writes.
;;; src/autodiff.lisp

(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars)
  "Generates the backward-pass body for a def-function.
FLAT-ANF       : flattened ANF of the forward function body.
FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).
T-GRAD-SYMS    : symbols for the incoming gradient inputs (one per return value).
RETURN-VARS    : symbols of the return variables (identified from FLAT-ANF last element).
Returns a (let (...) ...) form suitable as the body of the _GRAD companion function."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           (return-var-seeds (make-hash-table :test 'eq)))

    ;; Map each return-var to its t_grad seed
    (cl:loop for rv in return-vars
             for tg in t-grad-syms do
      (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (cl:let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; + : a_adj += v_adj, b_adj += v_adj
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr))
                             (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; - : a_adj += v_adj, b_adj += -v_adj
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; * : a_adj += b * v_adj, b_adj += a * v_adj
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; / : a_adj += (1/b)*v_adj, b_adj += (-a/b^2)*v_adj
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; sin : a_adj += cos(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; cos : a_adj += -sin(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; ~ (cell read): a_adj += v_adj  (identity through cell deref)
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; Known differentiable sub-function call — single return value
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn      (car expr))
                              (args    (cdr expr))
                              (info    (gethash fn *differentiable-functions*))
                              (bkwd-fn (getf info :bkwd-name))
                              (n-fp    (getf info :n-float-params))
                              (pkg     (symbol-package fn))
                              (deltas  (cl:loop for i from 0 below n-fp
                                                collect (intern (format nil "%~a_D~a" (symbol-name v) i) pkg)))
                              (v-adj   (local-adj v))
                              ;; accumulation forms for symbolic args only
                              (accum-forms
                               (cl:loop for arg in args
                                        for i from 0 below n-fp
                                        when (symbolp arg)
                                        collect `(set! ,(local-adj arg) (+ ,(local-adj arg) ,(nth i deltas))))))
                      (when accum-forms
                        (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                                 (let (,(append deltas (list `(,bkwd-fn ,@args ,v-adj))))
                                   ,@accum-forms))))))
                  ;; Unknown function call — error
                  ((and (consp expr) (symbolp (car expr)))
                    (error "Function ~A is not differentiable. ~
                            Wrap the kernel in 'forward-only' if differentiation is not needed, ~
                            or ensure all called functions are differentiable."
                           (car expr)))
                  ;; Everything else: skip silently
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn      (car expr))
                             (args    (cdr expr))
                             (info    (gethash fn *differentiable-functions*))
                             (bkwd-fn (getf info :bkwd-name))
                             (n-fp    (getf info :n-float-params))
                             (n-ret   (getf info :n-return))
                             (pkg     (symbol-package fn))
                             (deltas  (cl:loop for i from 0 below n-fp
                                               collect (intern (format nil "%MV_D~a" i) pkg)))
                             (t-adjs  (mapcar #'local-adj result-vars))
                             (accum-forms
                              (cl:loop for arg in args
                                       for i from 0 below n-fp
                                       when (symbolp arg)
                                       collect `(set! ,(local-adj arg)
                                                      (+ ,(local-adj arg) ,(nth i deltas))))))
                    (when accum-forms
                      (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                               (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adjs))))
                                 ,@accum-forms))))))))

            ;; ---- (return ...) or plain symbol: skip ---------------
            (t nil))))

    ;; Emit the return of float-param adjoints (inside labels scope)
    (emit `(return ,@(mapcar #'local-adj float-param-syms)))

    ;; Build local bindings:
    ;;   - forward single-value bindings from flat-anf (so temps like %ANF-T-3 are in scope)
    ;;   - return-var adjoints: initialised to their t_grad seed
    ;;   - all other adjoints: initialised to 0.0
    (cl:let* ((forward-bindings
               (cl:loop for form in flat-anf
                        when (and (consp form)
                                  (= (length form) 2)
                                  (symbolp (car form))
                                  (not (gethash (car form) return-var-seeds)))
                        collect form))
              (adjoint-bindings
               (cl:loop for v being the hash-keys of adjoint-map
                        using (hash-value adv)
                        collect (cl:let ((seed (gethash v return-var-seeds)))
                                  `(,adv ,(if seed seed 0.0)))))
              (all-bindings (append forward-bindings adjoint-bindings)))
      `(let ,all-bindings
         ,@(nreverse backward-forms))))))


;;; Helper: scan body-forms recursively for cell mutations of formal params.
;;; Signals an error when found, so differentiation is blocked at compile time.
;;; src/autodiff.lisp

(defun %check-fn-body-for-mutations (body-forms param-names fn-name)
  "Walks BODY-FORMS looking for (set! (~ p) ...) where p is in PARAM-NAMES.
Signals a compiler error if any mutation is detected, naming FN-NAME."
  (labels ((walk (form)
             (when (consp form)
               (when (and (eq (cl:first form) 'set!)
                          (consp (cl:second form))
                          (eq (cl:first (cl:second form)) '~)
                          (symbolp (cl:second (cl:second form)))
                          (member (cl:second (cl:second form)) param-names :test #'string-equal))
                 (error "Cannot differentiate function ~A: it mutates parameter ~A via ~
                         cell write (set! (~ ~A) ...). ~
                         This function is not valid in a differentiable kernel."
                        fn-name
                        (cl:second (cl:second form))
                        (cl:second (cl:second form))))
               (mapc #'walk (cl:rest form)))))
    (mapc #'walk body-forms)))


;;; A3: %generate-backward-function-ast
;;; ------------------------------------
;;; Produces the full (def-function name_GRAD ...) form for the backward
;;; companion of a user def-function, and registers it in *differentiable-functions*.
;;; Called from the patched def-function macro at macro-expansion time.
;;; src/autodiff.lisp

(defun %generate-backward-function-ast (name params declarations body-forms)
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable
user function. Also registers the function in *differentiable-functions*.

NAME         : the forward function name symbol.
PARAMS       : the parameter list (symbols, may include &out — deferred).
DECLARATIONS : the declaration specifiers list (as extracted by def-function macro).
BODY-FORMS   : the raw body S-expressions of the forward function.

Returns the backward def-function form, or NIL if the function has no differentiable
float params (e.g. integer-only functions)."
  (cl:let* ((pkg (symbol-package name)))

    ;; Parse the forward function signature to discover param types and return types.
    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)

      (cl:let* (;; Identify float-typed params (the differentiable ones)
                (float-param-entries
                 (cl:loop for pd in env
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-float-type-p (parameter-def-type pd)))
                          collect pd))
                (float-param-syms  (mapcar #'parameter-def-name float-param-entries))
                (n-float-params    (length float-param-syms))
                (n-return          (length return-types)))

        ;; If no differentiable params, nothing to generate.
        (when (zerop n-float-params)
          (log:info "AUTODIFF: ~a has no float params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        ;; Mutation check: error if any body form writes to a cell param.
        (%check-fn-body-for-mutations body-forms
                                      (mapcar #'parameter-def-name env)
                                      name)

        (cl:let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
                  ;; t_grad symbols — one per forward return value
                  (t-grad-syms (cl:loop for i from 0 below n-return
                                        collect (intern (format nil "T_GRAD~A" i) pkg)))
                  ;; All original param types (for the backward declare)
                  (orig-param-types (mapcar #'parameter-def-type env))
                  ;; t_grad param types (same as return types)
                  (t-grad-types return-types)
                  ;; Backward function params: originals + t_grads
                  (bkwd-params (append params t-grad-syms))
                  ;; Backward function type spec: (orig-types... t-grad-types... => float float ...)
                  (bkwd-fn-spec
                   `(function (,@orig-param-types ,@t-grad-types
                               => ,@(make-list n-float-params :initial-element 'float))))
                  (bkwd-declarations (list bkwd-fn-spec)))

          ;; Register in the differentiable-functions registry (side-effect at expansion time).
          (setf (gethash name *differentiable-functions*)
                (list :bkwd-name bkwd-name
                      :n-float-params n-float-params
                      :n-return n-return))

          (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-float-params=~a n-return=~a)"
                    bkwd-name name n-float-params n-return)

          ;; Build the backward body via ANF + backward walk.
          (cl:let* ((anf-body   (mapcar #'anf-transform body-forms))
                    (raw-flat   (flatten-anf-body anf-body))
                    ;; Normalize: if the last flat-ANF form is a compound expression
                    ;; (not a symbol or (return ...)), bind it to a fresh %ret-N symbol
                    ;; so that %extract-return-vars can identify it as the return var.
                    ;; This occurs when the function body ends with a bare expression like
                    ;; (+ a b) that ANF left as a top-level non-binding form.
                    (flat-anf
                     (cl:let ((last-f (cl:car (cl:last raw-flat))))
                       (if (or (symbolp last-f)
                               (and (consp last-f) (eq (cl:first last-f) 'return)))
                           raw-flat
                           (cl:let ((ret-sym (intern "%RET-0" pkg)))
                             (append (butlast raw-flat)
                                     (list (list ret-sym last-f)
                                           ret-sym))))))
                    (return-vars (%extract-return-vars flat-anf))
                    (bkwd-body  (%generate-backward-function-walk
                                 flat-anf float-param-syms t-grad-syms return-vars)))

            `(def-function ,bkwd-name ,bkwd-params
               ;; Use (second bkwd-fn-spec) to get the type spec list directly.
               ;; bkwd-fn-spec = (function (t1 t2 ... => r1 r2 ...))
               ;; (cdr bkwd-fn-spec) = ((t1 t2 ... => r1 r2 ...)) — a list-of-list
               ;; (second bkwd-fn-spec) = (t1 t2 ... => r1 r2 ...) — the spec list itself
               ;; #'(,@(second bkwd-fn-spec)) = (function (t1 t2 ... => r1 r2 ...)) — correct
               (declare #'(,@(second bkwd-fn-spec)))
               ,bkwd-body)))))))


;;; B1: generate-backward-walk extended for sub-function calls
;;; -----------------------------------------------------------
;;; See corrected definition with cl: prefixes below (after compile-def-function).
;;; src/autodiff.lisp


;;; Fix: valid-function-type-p — also accept raw (function ...) forms
;;; ------------------------------------------------------------------
;;; The original valid-function-type-p only checks for parsed forms
;;; (:function-type ...) and (:function-literal ...). Raw reader-macro
;;; forms like (function (float float => float)) (from #'(...) in source)
;;; are NOT matched, causing def-type validation to fail for function-type
;;; aliases like (def-type binop-t #'(float float => float)).
;;; src/types/validation.lisp

(defun valid-function-type-p (type-spec)
  "Checks if type-spec is a valid function literal or descriptor.
Extended to also accept raw (function ...) forms from the Crisp reader
(i.e., #'(float float => float) which the CL reader gives as (function ...))."
  (or (and (consp type-spec) (eq (cl:first type-spec) :function-literal)
           (= (length type-spec) 2) (symbolp (second type-spec)))
      (and (consp type-spec) (eq (cl:first type-spec) :function-type))
      ;; Raw function type from #'(...) reader expansion: (function (... => ...))
      ;; Note: must return T (boolean), not the member result, to satisfy valid-type-p's type decl.
      (and (consp type-spec) (eq (cl:first type-spec) 'common-lisp:function))))


;;; Fix: parse-type-specifier — resolve function-type aliases to :function-type form
;;; ---------------------------------------------------------------------------------
;;; Case 0 of parse-type-specifier returns the alias name (spec) for type aliases.
;;; This is correct for regular type aliases (e.g., in-ish -> CELL type). But for
;;; function-type aliases like (def-type binop-t #'(float float => float)), returning
;;; the alias name 'binop-t' means analyze-funcall-expression gets func-type = 'binop-t'
;;; instead of (:function-type ...), causing "First argument to funcall must be a
;;; function type or literal" error.
;;; Fix: when a type alias resolves to a function type, recursively parse it.
;;; src/environment.lisp

(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s).
   Extended: when a type alias resolves to a raw function type, parses it to :function-type."
  (cond
   ;; 0. Type Aliases: resolve and check. If the alias resolves to a function type,
   ;;    return the parsed :function-type form so funcall analysis works correctly.
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (cl:let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved)
       ;; If resolved is a raw function type form, parse it to :function-type
       (if (and (consp resolved) (eq (cl:first resolved) 'common-lisp:function))
           (cl:let* ((sig (if (listp (second resolved)) (second resolved) (rest resolved)))
                     (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                              (string-equal (symbol-name x) "=>")))
                                             sig))
                     (param-types (if arrow-pos (subseq sig 0 arrow-pos) sig))
                     (return-types (if arrow-pos (nthcdr (1+ arrow-pos) sig) nil)))
             `(:function-type ,return-types :params ,(mapcar #'parse-type-specifier param-types)))
           spec)))

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (cl:let* ((alias-name (first spec))
               (args (rest spec))
               (alias-def (gethash alias-name *crisp-template-aliases*))
               (params (car alias-def))
               (body-spec (cdr alias-def))
               (arity (length params))
               (required-args (subseq args 0 (min (length args) arity)))
               (rest-args (subseq args (length required-args)))
               (substitutions (pairlis params required-args)))
       (cl:let ((expanded (sublis substitutions body-spec)))
         (cl:let ((final-spec (if (and rest-args (consp expanded))
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
     (cl:let* ((alias-name (first spec))
               (args (rest spec))
               (expanded-base (gethash alias-name *crisp-type-aliases*)))
       (cl:let ((final-spec (if (listp expanded-base)
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
     (cl:let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                    (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (cl:let ((canonical (expand-storage-handle-type-specifier spec)))
       (if (valid-type-p canonical)
           (cl:let ((base (first canonical))
                    (params (rest canonical)))
             (cl:let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params)))
           (error 'crisp-unknown-type-error :type-name spec))))

   ;; Function Type/Literal (already parsed to :function-type or :function-literal)
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (cl:let* ((base (first spec))
               (raw-params (rest spec))
               (arity (get-template-arity base))
               (params (if (and arity (> (length raw-params) arity))
                           (extract-positional-from-keyword-args raw-params arity)
                           raw-params)))
       (cl:let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))


;;; Fix: %crisp-float-type-p for primitive types
;;; ---------------------------------------------
;;; The original version calls compute-base-type first, which returns NIL for
;;; primitive types like 'float (they are not in *type-derivation-graph*).
;;; This override checks *crisp-types* directly first, then falls back to
;;; compute-base-type for derived/alias types.
;;; src/autodiff.lisp

(defun %crisp-float-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp
float-category scalar type (float, double, half, bfloat16).
Checks *crisp-types* directly first (for primitives like 'float),
then falls back to compute-base-type for derived/alias types."
  (cl:let* ((direct-info (and (symbolp type-spec) (gethash type-spec *crisp-types*)))
            (base (if direct-info type-spec (compute-base-type type-spec)))
            (info (when base (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :float))))


;;; Feature 052: Override compile-def-function to generate _GRAD companions
;;; -------------------------------------------------------------------------
;;; After compiling the forward function normally, if *differentiate-p* is T
;;; and the function is not already a _GRAD companion and not system-generated,
;;; generate and compile the backward companion via recursive call.
;;;
;;; IMPORTANT: All CL-level control flow uses cl: prefixes to avoid shadowing
;;; by Crisp macros (let, loop, etc.) that are defined in this package.
;;;
;;; src/analysis/core.lisp

(defun compile-def-function (form location module builder di-builder di-compile-unit location-map)
  "Compiles a single def-function form. Handles optional parameters by generating
overloaded variants. When *differentiate-p* is T, also generates and compiles
the _GRAD backward companion after the forward function."
  ;; In single-pass mode, the signature won't be registered yet.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location))

  (cl:let* ((name (second form))
            (params (third form))
            (body-and-loc (cdddr form))
            ;; Extract declarations manually to check for optional args and system flag.
            (declare-forms (cl:loop for f in body-and-loc
                                    while (and (listp f) (eq (car f) 'declare))
                                    collect f))
            (declarations (cl:loop for f in declare-forms append (rest f)))
            (is-system (member '(crisp-system-generated) declarations :test #'equal)))

    (multiple-value-bind (explicit-env return-types optional-idx defaults key-idx)
        (parse-function-declarations params declarations)
      (declare (ignore explicit-env return-types defaults))

      (cond
       ;; --- OPTIONAL/KEY PARAMETERS: Lazy Instantiation (Generic Template) ---
       ;; We skip eager compilation here. The specific variants will be compiled
       ;; on-demand by instantiate-generic-function when called.
       ((or optional-idx key-idx)
         (log:info "Skipping eager compilation for GENERIC function template: ~a. Variants will be compiled on demand." name))

       ;; --- STANDARD Compilation (No Optionals) ---
       (t
         (%compile-standard-function form location module builder di-builder di-compile-unit location-map)
         ;; Feature 052: After compiling the forward function, generate and compile
         ;; the _GRAD backward companion when differentiating.
         (when (and *differentiate-p*
                    (not (%fn-name-is-grad-p name))
                    (not is-system))
           (cl:let* ((body-forms (nthcdr (length declare-forms) body-and-loc))
                     (bkwd-form (%generate-backward-function-ast name params declarations body-forms)))
             (when bkwd-form
               (log:info "AUTODIFF: Compiling backward companion for ~a" name)
               (compile-def-function bkwd-form location module builder
                                     di-builder di-compile-unit location-map)))))))))

;;; Fix: generate-backward-walk — replace bare let/loop/dolist with cl: prefixes
;;; ------------------------------------------------------------------------------
;;; In :crisp.compiler, `let` and `loop` are shadowed by Crisp macros. When the
;;; overlay is loaded, bare (let ...) forms at CL-execution level are processed
;;; by the Crisp let macro, which corrupts the labels form (only 2 of 3 bindings
;;; compile) and causes LOCAL-ADJ to be unresolvable at runtime.
;;; Fix: use cl:let, cl:let*, cl:loop, cl:dolist for all host-Lisp control flow.
;;; Backquoted forms that generate Crisp source code retain bare let/loop.
;;; src/autodiff.lisp

(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a list of backward ANF forms.
Extended for feature 052: handles differentiable sub-function calls,
multi-value bindings, and emits errors for non-differentiable functions
and for mutation of kernel input parameters."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))
             ;; Emit sub-function backward call and adjoint accumulation.
             ;; ARGS = the original call arguments (symbols or literals).
             ;; BKWD-FN = the _GRAD companion function symbol.
             ;; T-ADJ-FORMS = adjoint values to pass as t_grad inputs.
             ;; N-FP = number of float params (= number of deltas returned).
             ;; PKG = package for fresh temporaries.
             (emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg)
               (declare (ignore fn))
               (cl:let* ((deltas (cl:loop for i from 0 below n-fp
                                          collect (intern (format nil "%BW_D~a" i) pkg)))
                         (accum-forms
                          (cl:loop for arg in args
                                   for i from 0 below n-fp
                                   when (symbolp arg)
                                   collect `(set! ,(local-adj arg)
                                                  (+ ,(local-adj arg) ,(nth i deltas))))))
                 (when accum-forms
                   (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                            (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                              ,@accum-forms)))))))

      (cl:let ((reversed-body (reverse flat-anf)))
        (cl:dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; Primitive: +
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr)) (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; Primitive: -
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; Primitive: *
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; Primitive: /
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; Primitive: sin
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; Primitive: cos
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; Cell read: ~
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; B1: Known differentiable sub-function call
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn   (car expr))
                               (args (cdr expr))
                               (info (gethash fn *differentiable-functions*))
                               (bkwd (getf info :bkwd-name))
                               (n-fp (getf info :n-float-params))
                               (pkg  (symbol-package v)))
                      (emit-sub-fn-backward fn args bkwd (list (local-adj v)) n-fp pkg)))
                  ;; B2.5: Struct accessor (name ends in ~): treat like identity.
                  ;; e.g. (Y~ vp_y) — adjoint passes straight through to the arg.
                  ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
                        (cl:let ((fname (symbol-name (car expr))))
                          (and (> (length fname) 1)
                               (cl:char= (cl:char fname (1- (length fname))) #\~))))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; B3: Unknown function → error
                  ((and (consp expr) (symbolp (car expr)))
                    (error "~A: function ~A is not differentiable. ~
                            Mark the kernel 'forward-only' if differentiation is not needed."
                           (car form) (car expr)))
                  ;; Other compound expr: skip
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ;; Requires flatten-anf-body fix (A4) to appear here.
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn   (car expr))
                             (args (cdr expr))
                             (info (gethash fn *differentiable-functions*))
                             (bkwd (getf info :bkwd-name))
                             (n-fp (getf info :n-float-params))
                             (pkg  (symbol-package (car result-vars)))
                             (t-adjs (mapcar #'local-adj result-vars)))
                    (emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg)))))

            ;; ---- B4: Mutation of kernel input cell ----------------
            ((and (consp form) (eq (car form) 'set!))
              (cl:let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (cl:let ((target (cadr place)))
                    (cond
                      ;; Target is an output: seed its adjoint (existing behaviour)
                      ((member target outputs)
                        (cl:let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                   (symbol-package target))))
                          (emit `(set! ,(local-adj val) (+ ,(local-adj val) (~ ,tgt-grad))))))
                      ;; Target is an input: mutation error (B4)
                      ((member target inputs)
                        (error "Cannot differentiate: kernel mutates input parameter ~A ~
                                via (set! (~ ~A) ...). Only output parameters may be written."
                               target target))
                      ;; Other target: skip
                      (t nil))))))

            ;; ---- Everything else: skip ----------------------------
            (t nil))))

      ;; Emit gradient output writes for all inputs (inside labels scope)
      (cl:loop for in in inputs
               for in-type in input-types do
                 (cl:let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
                                            (symbol-package in)))
                           (canon-type (crisp.compiler::canonicalize-type-specifier
                                        (if (listp in-type) in-type (list in-type))))
                           (is-cell (eq (car canon-type) 'cell)))
                   (if is-cell
                       (emit `(set! (~ ,in-grad) ,(local-adj in)))
                       (emit `(set! ,in-grad ,(local-adj in))))))

      (cl:let* ((local-bindings (cl:loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv 0.0)))
                (result `(let ,local-bindings
                            ,@(nreverse backward-forms))))
        result))))


;;; Feature 052: Pre-registration pass
;;; ------------------------------------
;;; During analyze-signatures-pass (Pass 1), walk-code-forms calls visit-toplevel-form
;;; which expands def-kernel macros via macroexpand-1. The def-kernel macro calls
;;; %generate-backward-kernel-ast at macro-expansion time, which calls generate-backward-walk,
;;; which needs *differentiable-functions* to be populated.
;;;
;;; But *differentiable-functions* is populated by compile-def-function (Pass 2).
;;; So during Pass 1, any sub-function call in the kernel body will fail with
;;; "SOME-OPERATION is not differentiable" (B3 error).
;;;
;;; Fix: %pre-register-differentiable-fns walks all forms at the START of
;;; analyze-signatures-pass, finds all def-function forms, and pre-populates
;;; *differentiable-functions* with their signature info. This runs before
;;; walk-code-forms expands any def-kernel macro.
;;; src/analysis/core.lisp

(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS looking for def-function forms and
pre-register them in *differentiable-functions*. This runs before walk-code-forms
in analyze-signatures-pass, ensuring the registry is populated before any
def-kernel macro-expands and calls generate-backward-walk."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; def-function: pre-register if it has float params
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (multiple-value-bind (env return-types)
                 (parse-function-declarations params declarations)
               (cl:let* ((float-param-entries
                          (cl:loop for pd in env
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-float-type-p (parameter-def-type pd)))
                                   collect pd))
                         (n-float-params (length float-param-entries))
                         (n-return (length return-types)))
                 (when (> n-float-params 0)
                   (cl:let* ((pkg (symbol-package name))
                             (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                     (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                               name bkwd-name n-float-params n-return)
                     (setf (gethash name *differentiable-functions*)
                           (list :bkwd-name bkwd-name
                                 :n-float-params n-float-params
                                 :n-return n-return)))))))))

        ;; progn: recurse into sub-forms
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))))))

;; src/analysis/core.lisp
(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052)."
  ;; Feature 052: Pre-populate *differentiable-functions* before any
  ;; def-kernel macro expansion (which calls generate-backward-walk).
  (%pre-register-differentiable-fns forms)
  (walk-code-forms forms
                   (lambda (form location)
                     (cl:let* ((name (second form))
                               (body (cdddr form)))
                       (register-function-signature form location)
                       (cl:let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees)))))))


;;; =========================================================================
;;; Feature 052: HOF (Higher-Order Function) Support
;;; =========================================================================
;;;
;;; Strategy: HOF functions (def-function with a function-type parameter)
;;; cannot be differentiated in isolation. At the call site in the kernel
;;; backward walk, we substitute the concrete function literal into the HOF
;;; body, remove funcall, ANF-transform, and inline-differentiate using the
;;; kernel's own emit/local-adj/adjoint-map closures.
;;;
;;; *differentiable-hof-store* maps HOF name -> plist:
;;;   :param-syms       — all parameter symbols (including the function param)
;;;   :fn-param-idx     — index (0-based) of the function-type parameter
;;;   :fn-param-sym     — the function-type parameter symbol
;;;   :float-param-syms — symbols of float-typed params
;;;   :body-forms       — raw body S-expressions of the forward function

;;; src/compiler.lisp
(defvar *differentiable-hof-store* (make-hash-table :test 'eq)
  "Maps HOF function name to info plist for inline backward differentiation.")

;;; Updated initialize-compiler — also clears *differentiable-hof-store*.
;;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."
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

  ;; Feature 052: clear both registries on each compile.
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

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache and brand instance type tracking.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Clear partial template instantiations and their CL dispatch macros.
  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (log:info "INITIALIZE-COMPILER: clearing stale CL dispatch macro ~a" dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  ;; Initialize built-in structs (storage) — includes cell, vector, matrix templates
  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))

;;; %crisp-function-type-p — returns T if TYPE-SPEC is a :function-type form.
;;; src/autodiff.lisp
(defun %crisp-function-type-p (type-spec)
  "Returns T if TYPE-SPEC is a parsed :function-type or :function-literal specifier."
  (and (consp type-spec)
       (or (eq (cl:first type-spec) :function-type)
           (eq (cl:first type-spec) :function-literal))))

;;; %subst-form — simple tree substitution using an alist.
;;; src/autodiff.lisp
(defun %subst-form (form subst-alist)
  "Recursively substitute atoms in FORM according to SUBST-ALIST (list of (sym . replacement))."
  (cond
    ((null form) nil)
    ((atom form)
     (cl:let ((pair (cl:assoc form subst-alist)))
       (if pair (cdr pair) form)))
    (t (cl:cons (%subst-form (car form) subst-alist)
                (%subst-form (cdr form) subst-alist)))))

;;; %remove-funcall — replace (funcall fn-param ...) with (concrete-fn ...) recursively.
;;; src/autodiff.lisp
(defun %remove-funcall (form fn-param-sym concrete-fn-sym)
  "Recursively replace (funcall FN-PARAM-SYM ...) or (funcall (function X) ...)
with (CONCRETE-FN-SYM ...) in FORM."
  (cond
    ((atom form) form)
    ((and (eq (car form) 'funcall) (consp (cdr form)))
     (cl:let* ((fn-arg    (cadr form))
               (call-args (mapcar (lambda (a) (%remove-funcall a fn-param-sym concrete-fn-sym))
                                  (cddr form)))
               (resolved  (cond
                             ((eq fn-arg fn-param-sym) concrete-fn-sym)
                             ((and (consp fn-arg) (eq (car fn-arg) 'function)) (cadr fn-arg))
                             (t nil))))
       (if resolved
           `(,resolved ,@call-args)
           `(funcall ,fn-arg ,@call-args))))
    (t (mapcar (lambda (x) (%remove-funcall x fn-param-sym concrete-fn-sym)) form))))


;;; Updated %generate-backward-function-ast — detects HOF functions and
;;; stores them in *differentiable-hof-store* instead of generating a generic
;;; backward companion (which would fail on funcall).
;;; src/autodiff.lisp
(defun %generate-backward-function-ast (name params declarations body-forms)
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable
user function. Also registers the function in *differentiable-functions*.

For HOF functions (those with a function-type parameter), stores info in
*differentiable-hof-store* and registers with :hof t. Returns NIL for HOFs
since no separate _GRAD function is generated — the backward is inlined at
the kernel call site.

Returns the backward def-function form, or NIL if the function has no
differentiable float params or is a HOF."
  (cl:let* ((pkg (symbol-package name)))

    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)

      (cl:let* (;; Float-typed params (the differentiable ones)
                (float-param-entries
                 (cl:loop for pd in env
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-float-type-p (parameter-def-type pd)))
                          collect pd))
                (float-param-syms  (mapcar #'parameter-def-name float-param-entries))
                (n-float-params    (length float-param-syms))
                (n-return          (length return-types))

                ;; HOF detection: any param has a function type?
                (fn-param-entries
                 (cl:loop for pd in env
                          for i from 0
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-function-type-p (parameter-def-type pd)))
                          collect (cons i pd)))
                (is-hof (consp fn-param-entries)))

        ;; If no differentiable params, nothing to do.
        (when (zerop n-float-params)
          (log:info "AUTODIFF: ~a has no float params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        ;; If HOF: store info and register with :hof t. No _GRAD function generated.
        (when is-hof
          (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                    (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                    ;; Strip any trailing source-location atom from body-forms
                    (clean-body    (cl:loop for f in body-forms
                                            unless (and (atom f) (not (symbolp f)))
                                            collect f)))
            (log:info "AUTODIFF: ~a is HOF (fn-param=~a idx=~a) — storing for inline backward"
                      name fn-param-sym fn-param-idx)
            (setf (gethash name *differentiable-hof-store*)
                  (list :param-syms       (cl:loop for pd in env
                                                   collect (parameter-def-name pd))
                        :fn-param-idx     fn-param-idx
                        :fn-param-sym     fn-param-sym
                        :float-param-syms float-param-syms
                        :body-forms       clean-body))
            (setf (gethash name *differentiable-functions*)
                  (list :hof t
                        :n-float-params n-float-params
                        :n-return n-return))
            (return-from %generate-backward-function-ast nil)))

        ;; Non-HOF: proceed with normal backward function generation.
        ;; Mutation check: error if any body form writes to a cell param.
        (%check-fn-body-for-mutations body-forms
                                      (mapcar #'parameter-def-name env)
                                      name)

        (cl:let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
                  (t-grad-syms (cl:loop for i from 0 below n-return
                                        collect (intern (format nil "T_GRAD~A" i) pkg)))
                  (orig-param-types (mapcar #'parameter-def-type env))
                  (t-grad-types return-types)
                  (bkwd-params (append params t-grad-syms))
                  (bkwd-fn-spec
                   `(function (,@orig-param-types ,@t-grad-types
                               => ,@(make-list n-float-params :initial-element 'float)))))

          (setf (gethash name *differentiable-functions*)
                (list :bkwd-name bkwd-name
                      :n-float-params n-float-params
                      :n-return n-return))

          (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-fp=~a n-ret=~a)"
                    bkwd-name name n-float-params n-return)

          (cl:let* ((anf-body   (mapcar #'anf-transform body-forms))
                    (raw-flat   (flatten-anf-body anf-body))
                    (flat-anf
                     (cl:let ((last-f (cl:car (cl:last raw-flat))))
                       (if (or (symbolp last-f)
                               (and (consp last-f) (eq (cl:first last-f) 'return)))
                           raw-flat
                           (cl:let ((ret-sym (intern "%RET-0" pkg)))
                             (append (butlast raw-flat)
                                     (list (list ret-sym last-f)
                                           ret-sym))))))
                    (return-vars (%extract-return-vars flat-anf))
                    (bkwd-body  (%generate-backward-function-walk
                                 flat-anf float-param-syms t-grad-syms return-vars)))

            `(def-function ,bkwd-name ,bkwd-params
               (declare #'(,@(second bkwd-fn-spec)))
               ,bkwd-body)))))))


;;; Updated %pre-register-differentiable-fns — also handles HOF detection.
;;; src/analysis/core.lisp
(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Runs before walk-code-forms in analyze-signatures-pass."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (multiple-value-bind (env return-types)
                 (parse-function-declarations params declarations)
               (cl:let* ((float-param-entries
                          (cl:loop for pd in env
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-float-type-p (parameter-def-type pd)))
                                   collect pd))
                         (n-float-params (length float-param-entries))
                         (n-return (length return-types))
                         (fn-param-entries
                          (cl:loop for pd in env
                                   for i from 0
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-function-type-p (parameter-def-type pd)))
                                   collect (cons i pd)))
                         (is-hof (consp fn-param-entries)))
                 (when (> n-float-params 0)
                   (if is-hof
                       (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                 (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                 (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                 (body-forms (cl:loop for f in body-and-loc
                                                      unless (and (listp f) (eq (car f) 'declare))
                                                      collect f))
                                 (clean-body  (cl:loop for f in body-forms
                                                       unless (and (atom f) (not (symbolp f)))
                                                       collect f)))
                         (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                   name fn-param-sym fn-param-idx)
                         (setf (gethash name *differentiable-hof-store*)
                               (list :param-syms       (cl:loop for pd in env
                                                                collect (parameter-def-name pd))
                                     :fn-param-idx     fn-param-idx
                                     :fn-param-sym     fn-param-sym
                                     :float-param-syms float-param-syms
                                     :body-forms       clean-body))
                         (setf (gethash name *differentiable-functions*)
                               (list :hof t
                                     :n-float-params n-float-params
                                     :n-return n-return)))
                       (cl:let* ((pkg (symbol-package name))
                                 (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                         (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                   name bkwd-name n-float-params n-return)
                         (setf (gethash name *differentiable-functions*)
                               (list :bkwd-name bkwd-name
                                     :n-float-params n-float-params
                                     :n-return n-return))))))))))  ; closes: list setf else-cl:let* if when inner-cl:let* mvbind unless outer-cl:let* cond-clause-1

        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))))))


;;; Updated generate-backward-walk — adds HOF inline backward support (B1 HOF case).
;;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a backward ANF body (a let form).
Extended for feature 052: handles differentiable sub-function calls (B1/B2),
multi-value bindings, HOF inline backward, errors for non-differentiable
functions (B3), and mutation errors (B4)."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))
             ;; Emit _GRAD call + adjoint accumulation for a normal sub-function.
             (emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg)
               (declare (ignore fn))
               (cl:let* ((deltas (cl:loop for i from 0 below n-fp
                                          collect (intern (format nil "%BW_D~a" i) pkg)))
                         (accum-forms
                          (cl:loop for arg in args
                                   for i from 0 below n-fp
                                   when (symbolp arg)
                                   collect `(set! ,(local-adj arg)
                                                  (+ ,(local-adj arg) ,(nth i deltas))))))
                 (when accum-forms
                   (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                            (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                              ,@accum-forms))))))

             ;; HOF inline backward: substitute concrete fn, remove funcall,
             ;; ANF-transform the concrete body, process backwards using
             ;; the kernel's own closures.
             (hof-inline-backward (fn args v)
               (cl:let* ((hof-data (gethash fn *differentiable-hof-store*)))
                 (unless hof-data
                   (error "HOF ~A not found in *differentiable-hof-store*" fn))
                 (cl:let* ((param-syms   (getf hof-data :param-syms))
                           (fn-param-idx (getf hof-data :fn-param-idx))
                           (body-forms   (getf hof-data :body-forms))
                           ;; Resolve concrete function from call args
                           (fn-arg       (nth fn-param-idx args))
                           (concrete-fn  (cond
                                           ;; (function +) — inline atomic
                                           ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                            (cadr fn-arg))
                                           ;; Bare symbol
                                           ((symbolp fn-arg) fn-arg)
                                           (t nil))))
                   (unless concrete-fn
                     (error "Cannot inline-differentiate HOF ~A: ~
                             could not resolve concrete fn from arg ~A" fn fn-arg))
                   ;; Build substitution: non-fn params -> call-site args
                   (cl:let* ((fn-param      (nth fn-param-idx param-syms))
                             (subst-alist
                              (cl:loop for p in param-syms
                                       for a in args
                                       for i from 0
                                       unless (= i fn-param-idx)
                                       collect (cons p a)))
                             (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                             (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                    subst-body))
                             ;; ANF + flatten the concrete body
                             (anf-body      (mapcar #'anf-transform concrete-body))
                             (hof-flat      (flatten-anf-body anf-body))
                             ;; Normalize last form if needed
                             (hof-flat-norm
                              (cl:let ((last-f (cl:car (cl:last hof-flat))))
                                (if (or (symbolp last-f)
                                        (and (consp last-f) (eq (cl:first last-f) 'return)))
                                    hof-flat
                                    (cl:let ((ret-sym (intern (format nil "%HOF_RET_%A" (symbol-name v))
                                                               (symbol-package v))))
                                      (append (butlast hof-flat)
                                              (list (list ret-sym last-f) ret-sym))))))
                             (return-vars   (%extract-return-vars hof-flat-norm)))
                     ;; Seed return-var adjoints to v's adjoint
                     (cl:dolist (rv return-vars)
                       (setf (gethash rv adjoint-map) (local-adj v)))
                     ;; Process hof-flat-norm backwards (same primitive rules)
                     (cl:dolist (hf-form (cl:reverse hof-flat-norm))
                       (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                         (cl:let ((hv    (car hf-form))
                                  (hexpr (cadr hf-form)))
                           (cond
                             ;; +
                             ((and (consp hexpr) (eq (car hexpr) '+))
                              (cl:let ((a (cadr hexpr)) (b (caddr hexpr)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj hv)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj hv)))))))
                             ;; -
                             ((and (consp hexpr) (eq (car hexpr) '-))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                                (when b (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj))))))))
                             ;; *
                             ((and (consp hexpr) (eq (car hexpr) '*))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                             ;; /
                             ((and (consp hexpr) (eq (car hexpr) '/))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                             ;; sin
                             ((and (consp hexpr) (eq (car hexpr) 'sin))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a)
                                  (cl:let* ((a-adj (local-adj a))
                                            (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                                    (setf (gethash cos-a adjoint-map) cos-a)
                                    (emit `(set! ,cos-a (cos ,a)))
                                    (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                             ;; cos
                             ((and (consp hexpr) (eq (car hexpr) 'cos))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a)
                                  (cl:let* ((a-adj (local-adj a))
                                            (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                                    (setf (gethash sin-a adjoint-map) sin-a)
                                    (emit `(set! ,sin-a (sin ,a)))
                                    (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                             ;; ~ cell read
                             ((and (consp hexpr) (eq (car hexpr) '~))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                             ;; Nested known differentiable sub-function
                             ((and (consp hexpr)
                                   (symbolp (car hexpr))
                                   (gethash (car hexpr) *differentiable-functions*))
                              (cl:let* ((nfn   (car hexpr))
                                        (nargs (cdr hexpr))
                                        (ninfo (gethash nfn *differentiable-functions*)))
                                (if (getf ninfo :hof)
                                    (hof-inline-backward nfn nargs hv)
                                    (emit-sub-fn-backward nfn nargs
                                                          (getf ninfo :bkwd-name)
                                                          (list (local-adj hv))
                                                          (getf ninfo :n-float-params)
                                                          (symbol-package hv)))))
                             ;; Unknown → error
                             (t (error "HOF inline backward: unsupported op ~A in inlined body of ~A"
                                       (if (consp hexpr) (car hexpr) hexpr) fn))))))))))

             ) ; end labels binding list

      (cl:let ((reversed-body (reverse flat-anf)))
        (cl:dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; Primitive: +
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr)) (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; Primitive: -
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; Primitive: *
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; Primitive: /
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; Primitive: sin
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; Primitive: cos
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; Cell read: ~
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; B1: Known differentiable sub-function call
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn   (car expr))
                               (args (cdr expr))
                               (info (gethash fn *differentiable-functions*)))
                      (if (getf info :hof)
                          ;; HOF: inline backward differentiation
                          (hof-inline-backward fn args v)
                          ;; Normal: call _GRAD companion
                          (emit-sub-fn-backward fn args
                                                (getf info :bkwd-name)
                                                (list (local-adj v))
                                                (getf info :n-float-params)
                                                (symbol-package v)))))
                  ;; B2.5: Struct accessor (name ends in ~): treat like identity.
                  ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
                        (cl:let ((fname (symbol-name (car expr))))
                          (and (> (length fname) 1)
                               (cl:char= (cl:char fname (1- (length fname))) #\~))))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; Comparison/boolean ops: skip (no float adjoint contribution)
                  ((and (consp expr) (symbolp (car expr))
                        (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
                   nil)
                  ;; If form: skip (branching — no adjoint through condition)
                  ((and (consp expr) (symbolp (car expr))
                        (string= (symbol-name (car expr)) "IF"))
                   nil)
                  ;; B3: Unknown function → error
                  ((and (consp expr) (symbolp (car expr)))
                    (error "~A: function ~A is not differentiable. Mark the kernel 'forward-only' if differentiation is not needed."
                           (car form) (car expr)))
                  ;; Other compound expr: skip
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn   (car expr))
                             (args (cdr expr))
                             (info (gethash fn *differentiable-functions*))
                             (bkwd (getf info :bkwd-name))
                             (n-fp (getf info :n-float-params))
                             (pkg  (symbol-package (car result-vars)))
                             (t-adjs (mapcar #'local-adj result-vars)))
                    (emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg)))))

            ;; ---- B4: Mutation of kernel input cell ----------------
            ((and (consp form) (eq (car form) 'set!))
              (cl:let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (cl:let ((target (cadr place)))
                    (cond
                      ((member target outputs)
                        (cl:let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                   (symbol-package target))))
                          (emit `(set! ,(local-adj val) (+ ,(local-adj val) (~ ,tgt-grad))))))
                      ((member target inputs)
                        (error "Cannot differentiate: kernel mutates input parameter ~A ~
                                via (set! (~ ~A) ...). Only output parameters may be written."
                               target target))
                      (t nil))))))

            ;; ---- Everything else: skip ----------------------------
            (t nil))))

      ;; Emit gradient output writes for all inputs
      (cl:loop for in in inputs
               for in-type in input-types do
                 (cl:let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
                                            (symbol-package in)))
                           (canon-type (crisp.compiler::canonicalize-type-specifier
                                        (if (listp in-type) in-type (list in-type))))
                           (is-cell (eq (car canon-type) 'cell)))
                   (if is-cell
                       (emit `(set! (~ ,in-grad) ,(local-adj in)))
                       (emit `(set! ,in-grad ,(local-adj in))))))

      (cl:let* ((local-bindings (cl:loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv 0.0)))
                (result `(let ,local-bindings
                            ,@(nreverse backward-forms))))
        result))))


;;; Updated %generate-backward-function-walk — handles comparison ops and if forms.
;;; src/autodiff.lisp
(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars)
  "Generates the backward-pass body for a def-function.
FLAT-ANF         : flattened ANF of the forward function body.
FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).
T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).
RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).
Returns a (let (...) ...) form suitable as the body of the _GRAD companion function."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           (return-var-seeds (make-hash-table :test 'eq)))

    ;; Map each return-var to its t_grad seed
    (cl:loop for rv in return-vars
             for tg in t-grad-syms do
      (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (cl:let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; + : a_adj += v_adj, b_adj += v_adj
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr))
                             (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; - : a_adj += v_adj, b_adj += -v_adj
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; * : a_adj += b * v_adj, b_adj += a * v_adj
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; / : a_adj += (1/b)*v_adj, b_adj += (-a/b^2)*v_adj
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; sin : a_adj += cos(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; cos : a_adj += -sin(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; ~ (cell read): a_adj += v_adj  (identity through cell deref)
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; Known differentiable sub-function call — single return value
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn      (car expr))
                              (args    (cdr expr))
                              (info    (gethash fn *differentiable-functions*))
                              (bkwd-fn (getf info :bkwd-name))
                              (n-fp    (getf info :n-float-params))
                              (pkg     (symbol-package fn))
                              (deltas  (cl:loop for i from 0 below n-fp
                                                collect (intern (format nil "%~a_D~a" (symbol-name v) i) pkg)))
                              (v-adj   (local-adj v))
                              (accum-forms
                               (cl:loop for arg in args
                                        for i from 0 below n-fp
                                        when (symbolp arg)
                                        collect `(set! ,(local-adj arg) (+ ,(local-adj arg) ,(nth i deltas))))))
                      (when accum-forms
                        (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                                 (let (,(append deltas (list `(,bkwd-fn ,@args ,v-adj))))
                                   ,@accum-forms))))))
                  ;; Comparison/boolean ops: skip (no float adjoint contribution)
                  ((and (consp expr) (symbolp (car expr))
                        (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
                   nil)
                  ;; If form: skip (branching — recomputation strategy, no adjoint through condition)
                  ((and (consp expr) (symbolp (car expr))
                        (string= (symbol-name (car expr)) "IF"))
                   nil)
                  ;; Unknown function call — error
                  ((and (consp expr) (symbolp (car expr)))
                    (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable."
                           (car expr)))
                  ;; Everything else: skip silently
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn      (car expr))
                             (args    (cdr expr))
                             (info    (gethash fn *differentiable-functions*))
                             (bkwd-fn (getf info :bkwd-name))
                             (n-fp    (getf info :n-float-params))
                             (n-ret   (getf info :n-return))
                             (pkg     (symbol-package fn))
                             (deltas  (cl:loop for i from 0 below n-fp
                                               collect (intern (format nil "%MV_D~a" i) pkg)))
                             (t-adjs  (mapcar #'local-adj result-vars))
                             (accum-forms
                              (cl:loop for arg in args
                                       for i from 0 below n-fp
                                       when (symbolp arg)
                                       collect `(set! ,(local-adj arg)
                                                      (+ ,(local-adj arg) ,(nth i deltas))))))
                    (when accum-forms
                      (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                               (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adjs))))
                                 ,@accum-forms))))))))

            ;; ---- (return ...) or plain symbol: skip ---------------
            (t nil))))

    ;; Emit the return of float-param adjoints (inside labels scope)
    (emit `(return ,@(mapcar #'local-adj float-param-syms)))

    ;; Build local bindings:
    ;;   - forward single-value bindings from flat-anf (so temps like %ANF-T-3 are in scope)
    ;;   - return-var adjoints: initialised to their t_grad seed
    ;;   - all other adjoints: initialised to 0.0
    (cl:let* ((forward-bindings
               (cl:loop for form in flat-anf
                        when (and (consp form)
                                  (= (length form) 2)
                                  (symbolp (car form))
                                  (not (gethash (car form) return-var-seeds)))
                        collect form))
              (adjoint-bindings
               (cl:loop for v being the hash-keys of adjoint-map
                        using (hash-value adv)
                        collect (cl:let ((seed (gethash v return-var-seeds)))
                                  `(,adv ,(if seed seed 0.0)))))
              (all-bindings (append forward-bindings adjoint-bindings)))
      `(let ,all-bindings
         ,@(nreverse backward-forms))))))


;;; Fix: %infer-from-single-template — allow HOF-type params to fail matching
;;; when all template params are already inferred from other arguments.
;;; Without this, template inference for HOF functions fails when built-in
;;; operators (+, -, *, /) are passed as function literals, because those
;;; operators are not registered in *function-table*.
;;; src/templates.lisp
(defun %infer-from-single-template (tmpl argument-types)
  "Helper: Attempts to infer template types for a single template.
Returns NIL on failure, or (list template-data concrete-types) on success.
Extended: HOF-type sig-params are allowed to fail matching when all template
parameters have already been inferred from earlier arguments."
  (cl:let* ((raw-sig (crisp.compiler::template-data-signature tmpl))
            (sig (crisp.compiler::%unwrap-function-signature raw-sig))
            (raw-params (crisp.compiler::template-data-parameters tmpl))
            (params (mapcar (lambda (p) (if (consp p) (cl:first p) p)) raw-params))
            (sig-params (when sig (butlast sig 2))))

    (when (and sig-params (= (length sig-params) (length argument-types)))
          (cl:let ((inference-map (make-hash-table)))
            ;; Try to match each sig-param against arg-type.
            ;; If matching fails for a HOF-type parameter but all template params
            ;; are already inferred, allow it to proceed.
            (cl:let ((all-matched
                      (cl:loop for sig-param in sig-params
                               for arg-type in argument-types
                               always
                               (or (crisp.compiler::match-template-arg
                                    sig-param arg-type inference-map params)
                                   ;; Fallback: if all params already inferred, skip this param
                                   (cl:every (lambda (p) (gethash p inference-map)) params)))))
              (when all-matched
                    (cl:let ((concrete-types (cl:loop for p in params
                                                      collect (gethash p inference-map))))
                      (when (cl:every #'identity concrete-types)
                            (list (list tmpl concrete-types))))))))))

;;; Feature 052: Pre-register HOF templates from *template-registry*.
;;; Called AFTER walk-code-forms populates the template registry.
;;; Detects HOF templates by scanning the body for (funcall <param> ...) patterns.
;;; src/analysis/core.lisp

(defun %tree-has-funcall-p (tree target-sym)
  "Returns T if any subtree in TREE contains (funcall TARGET-SYM ...)."
  (cond
    ((null tree) nil)
    ((atom tree) nil)
    ;; Is this a (funcall target ...) form?
    ((and (symbolp (cl:first tree))
          (string= (symbol-name (cl:first tree)) "FUNCALL")
          (eq (cl:second tree) target-sym))
     t)
    ;; Recurse into sub-trees
    (t (cl:some (lambda (sub) (%tree-has-funcall-p sub target-sym)) tree))))

(defun %pre-register-hof-templates ()
  "When *differentiate-p* is T, scan *template-registry* for def-function templates
that use (funcall <param> ...) in their body, indicating a HOF parameter. Pre-register
each such template in *differentiable-hof-store* and *differentiable-functions*.
Must be called after walk-code-forms so *template-registry* is populated."
  (when *differentiate-p*
    (maphash
     (lambda (name templates)
       (cl:dolist (tmpl templates)
         (cl:let* ((body (template-data-body tmpl)))
           ;; Only process def-function templates (not def-kernel, def-struct, etc.)
           (when (and (consp body)
                      (symbolp (cl:first body))
                      (string= (symbol-name (cl:first body)) "DEF-FUNCTION"))
             (cl:let* ((params      (cl:third body))
                       (body-and-loc (cl:nthcdr 3 body))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f)
                                                          (symbolp (cl:first f))
                                                          (string= (symbol-name (cl:first f)) "DECLARE"))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Find which param appears as (funcall <param> ...) in the body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (return)))
               ;; If found and not already registered, pre-register as HOF
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1))))))))
     *template-registry*)))

;;; Updated analyze-signatures-pass — calls %pre-register-hof-templates after
;;; walk-code-forms so HOF templates in the template registry are registered.
;;; src/analysis/core.lisp
(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052).
Also scans *template-registry* for HOF templates after walk-code-forms."
  ;; Step 1: Pre-populate from top-level def-function forms.
  (%pre-register-differentiable-fns forms)
  ;; Step 2: Walk all forms (registers templates, signatures, etc.)
  (walk-code-forms forms
                   (lambda (form location)
                     (cl:let* ((name (second form))
                               (body (cdddr form)))
                       (register-function-signature form location)
                       (cl:let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees))))))
  ;; Step 3: After walk-code-forms, scan template registry for HOF templates.
  (%pre-register-hof-templates))

;;; Updated %pre-register-differentiable-fns v3 — also handles with-template-type.
;;; The existing version (v2) handles top-level def-function and progn, but
;;; misses HOF functions defined inside with-template-type blocks (since those
;;; are template stubs, not real def-functions, at the time this runs).
;;; v3 adds a with-template-type case that uses funcall-scanning to detect HOF
;;; params without needing type resolution (which would fail with T placeholders).
;;; src/analysis/core.lisp
(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; Top-level def-function: existing HOF-aware logic
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (multiple-value-bind (env return-types)
                 (parse-function-declarations params declarations)
               (cl:let* ((float-param-entries
                          (cl:loop for pd in env
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-float-type-p (parameter-def-type pd)))
                                   collect pd))
                         (n-float-params (length float-param-entries))
                         (n-return (length return-types))
                         (fn-param-entries
                          (cl:loop for pd in env
                                   for i from 0
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-function-type-p (parameter-def-type pd)))
                                   collect (cons i pd)))
                         (is-hof (consp fn-param-entries)))
                 (when (> n-float-params 0)
                   (if is-hof
                       (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                 (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                 (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                 (body-forms (cl:loop for f in body-and-loc
                                                      unless (and (listp f) (eq (car f) 'declare))
                                                      collect f))
                                 (clean-body  (cl:loop for f in body-forms
                                                       unless (and (atom f) (not (symbolp f)))
                                                       collect f)))
                         (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                   name fn-param-sym fn-param-idx)
                         (setf (gethash name *differentiable-hof-store*)
                               (list :param-syms       (cl:loop for pd in env
                                                                collect (parameter-def-name pd))
                                     :fn-param-idx     fn-param-idx
                                     :fn-param-sym     fn-param-sym
                                     :float-param-syms float-param-syms
                                     :body-forms       clean-body))
                         (setf (gethash name *differentiable-functions*)
                               (list :hof t
                                     :n-float-params n-float-params
                                     :n-return n-return)))
                       (cl:let* ((pkg (symbol-package name))
                                 (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                         (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                   name bkwd-name n-float-params n-return)
                         (setf (gethash name *differentiable-functions*)
                               (list :bkwd-name bkwd-name
                                     :n-float-params n-float-params
                                     :n-return n-return))))))))))

        ;; progn: recurse
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))

        ;; with-template-type: walk body for HOF def-functions using funcall scanning
        ;; (cannot use parse-function-declarations here — types contain T placeholder)
        ((and (consp form) (eq (car form) 'with-template-type))
         (cl:dolist (bform (cddr form))   ; skip 'with-template-type' and params list
           (when (and (consp bform) (eq (car bform) 'def-function))
             (cl:let* ((name        (second bform))
                       (params      (third bform))
                       (body-and-loc (cdddr bform))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f) (eq (cl:first f) 'declare))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Detect HOF param by looking for (funcall <param> ...) in body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (return)))
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a via with-template-type (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1)))))))))))

;;; Fix: %pre-register-hof-templates — (return) inside cl:loop do-body expands
;;; via Crisp return macro to (explicit-return nil), not (return-from nil nil).
;;; Replace with (cl:return) to properly exit the loop.
;;; src/analysis/core.lisp
(defun %pre-register-hof-templates ()
  "When *differentiate-p* is T, scan *template-registry* for def-function templates
that use (funcall <param> ...) in their body, indicating a HOF parameter. Pre-register
each such template in *differentiable-hof-store* and *differentiable-functions*.
Must be called after walk-code-forms so *template-registry* is populated."
  (when *differentiate-p*
    (maphash
     (lambda (name templates)
       (cl:dolist (tmpl templates)
         (cl:let* ((body (template-data-body tmpl)))
           ;; Only process def-function templates (not def-kernel, def-struct, etc.)
           (when (and (consp body)
                      (symbolp (cl:first body))
                      (string= (symbol-name (cl:first body)) "DEF-FUNCTION"))
             (cl:let* ((params      (cl:third body))
                       (body-and-loc (cl:nthcdr 3 body))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f)
                                                          (symbolp (cl:first f))
                                                          (string= (symbol-name (cl:first f)) "DECLARE"))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Find which param appears as (funcall <param> ...) in the body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (cl:return)))
               ;; If found and not already registered, pre-register as HOF
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1))))))))
     *template-registry*)))

;;; Fix: %pre-register-differentiable-fns v4 — same (return) -> (cl:return) fix
;;; in the with-template-type case loop.
;;; src/analysis/core.lisp
(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; Top-level def-function: existing HOF-aware logic
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (multiple-value-bind (env return-types)
                 (parse-function-declarations params declarations)
               (cl:let* ((float-param-entries
                          (cl:loop for pd in env
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-float-type-p (parameter-def-type pd)))
                                   collect pd))
                         (n-float-params (length float-param-entries))
                         (n-return (length return-types))
                         (fn-param-entries
                          (cl:loop for pd in env
                                   for i from 0
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-function-type-p (parameter-def-type pd)))
                                   collect (cons i pd)))
                         (is-hof (consp fn-param-entries)))
                 (when (> n-float-params 0)
                   (if is-hof
                       (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                 (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                 (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                 (body-forms (cl:loop for f in body-and-loc
                                                      unless (and (listp f) (eq (car f) 'declare))
                                                      collect f))
                                 (clean-body  (cl:loop for f in body-forms
                                                       unless (and (atom f) (not (symbolp f)))
                                                       collect f)))
                         (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                   name fn-param-sym fn-param-idx)
                         (setf (gethash name *differentiable-hof-store*)
                               (list :param-syms       (cl:loop for pd in env
                                                                collect (parameter-def-name pd))
                                     :fn-param-idx     fn-param-idx
                                     :fn-param-sym     fn-param-sym
                                     :float-param-syms float-param-syms
                                     :body-forms       clean-body))
                         (setf (gethash name *differentiable-functions*)
                               (list :hof t
                                     :n-float-params n-float-params
                                     :n-return n-return)))
                       (cl:let* ((pkg (symbol-package name))
                                 (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                         (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                   name bkwd-name n-float-params n-return)
                         (setf (gethash name *differentiable-functions*)
                               (list :bkwd-name bkwd-name
                                     :n-float-params n-float-params
                                     :n-return n-return))))))))))

        ;; progn: recurse
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))

        ;; with-template-type: walk body for HOF def-functions using funcall scanning
        ;; (cannot use parse-function-declarations here — types contain T placeholder)
        ((and (consp form) (eq (car form) 'with-template-type))
         (cl:dolist (bform (cddr form))   ; skip 'with-template-type' and params list
           (when (and (consp bform) (eq (car bform) 'def-function))
             (cl:let* ((name        (second bform))
                       (params      (third bform))
                       (body-and-loc (cdddr bform))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f) (eq (cl:first f) 'declare))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Detect HOF param by looking for (funcall <param> ...) in body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (cl:return)))
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a via with-template-type (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1)))))))))))


;;; Fix: %check-fn-body-for-mutations — fix invalid ~<space> format directive
;;; The format string had (set! (~ ~A) ...) where ~ before a space is an
;;; unknown CL format directive. Fixed with ~~ for the literal tilde.
;;; src/autodiff.lisp
(defun %check-fn-body-for-mutations (body-forms param-names fn-name)
  "Walks BODY-FORMS looking for (set! (~ p) ...) where p is in PARAM-NAMES.
Signals a compiler error if any mutation is detected, naming FN-NAME."
  (labels ((walk (form)
             (when (consp form)
               (when (and (eq (cl:first form) 'set!)
                          (consp (cl:second form))
                          (eq (cl:first (cl:second form)) '~)
                          (symbolp (cl:second (cl:second form)))
                          (member (cl:second (cl:second form)) param-names :test #'string-equal))
                 (error "Cannot differentiate function ~A: it mutates parameter ~A via cell write (set! (~~ ~A) ...). This function is not valid in a differentiable kernel."
                        fn-name
                        (cl:second (cl:second form))
                        (cl:second (cl:second form))))
               (mapc #'walk (cl:rest form)))))
    (mapc #'walk body-forms)))

;;; Fix: %pre-register-differentiable-fns v5 — guard parse-function-declarations
;;; with handler-case so brand-typed function signatures (e.g. (token-t s)) that
;;; refer to brands not yet registered don't crash the pre-registration pass.
;;; Brand-typed params are never floats, so skipping them loses no differentiation.
;;; src/analysis/core.lisp
(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type.
Guards parse-function-declarations against unknown-type errors from brand types
that are not yet registered at pre-registration time."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; Top-level def-function: existing HOF-aware logic
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (handler-case
               (multiple-value-bind (env return-types)
                   (parse-function-declarations params declarations)
                 (cl:let* ((float-param-entries
                            (cl:loop for pd in env
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-float-type-p (parameter-def-type pd)))
                                     collect pd))
                           (n-float-params (length float-param-entries))
                           (n-return (length return-types))
                           (fn-param-entries
                            (cl:loop for pd in env
                                     for i from 0
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-function-type-p (parameter-def-type pd)))
                                     collect (cons i pd)))
                           (is-hof (consp fn-param-entries)))
                   (when (> n-float-params 0)
                     (if is-hof
                         (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                   (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                   (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                   (body-forms (cl:loop for f in body-and-loc
                                                        unless (and (listp f) (eq (car f) 'declare))
                                                        collect f))
                                   (clean-body  (cl:loop for f in body-forms
                                                         unless (and (atom f) (not (symbolp f)))
                                                         collect f)))
                           (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                     name fn-param-sym fn-param-idx)
                           (setf (gethash name *differentiable-hof-store*)
                                 (list :param-syms       (cl:loop for pd in env
                                                                  collect (parameter-def-name pd))
                                       :fn-param-idx     fn-param-idx
                                       :fn-param-sym     fn-param-sym
                                       :float-param-syms float-param-syms
                                       :body-forms       clean-body))
                           (setf (gethash name *differentiable-functions*)
                                 (list :hof t
                                       :n-float-params n-float-params
                                       :n-return n-return)))
                         (cl:let* ((pkg (symbol-package name))
                                   (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                           (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                     name bkwd-name n-float-params n-return)
                           (setf (gethash name *differentiable-functions*)
                                 (list :bkwd-name bkwd-name
                                       :n-float-params n-float-params
                                       :n-return n-return)))))))
               (error (e)
                 (log:debug "AUTODIFF: Skipping pre-registration of ~a -- type parse error: ~a" name e))))))

        ;; progn: recurse
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))

        ;; with-template-type: walk body for HOF def-functions using funcall scanning
        ;; (cannot use parse-function-declarations here -- types contain T placeholder)
        ((and (consp form) (eq (car form) 'with-template-type))
         (cl:dolist (bform (cddr form))   ; skip 'with-template-type' and params list
           (when (and (consp bform) (eq (car bform) 'def-function))
             (cl:let* ((name        (second bform))
                       (params      (third bform))
                       (body-and-loc (cdddr bform))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f) (eq (cl:first f) 'declare))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Detect HOF param by looking for (funcall <param> ...) in body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (cl:return)))
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a via with-template-type (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1)))))))))))

;;; Fix: generate-backward-walk — skip system-generated functions (name contains %)
;;; before the B3 error so MAKE-X%DISPATCH and %CONSTRUCT-STRUCT don't crash AD.
;;; src/autodiff.lisp

;;; Fix: generate-backward-walk — change B3 from error to log-and-skip.
;;; All float-param user functions are pre-registered (B1 handles them).
;;; Unknown calls (built-ins like to-ulong, constructors) have no float
;;; adjoint contribution — log at debug level and skip silently.
;;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a backward ANF body (a let form).
Extended for feature 052: handles differentiable sub-function calls (B1/B2),
multi-value bindings, HOF inline backward, errors for non-differentiable
functions (B3), and mutation errors (B4)."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))
             ;; Emit _GRAD call + adjoint accumulation for a normal sub-function.
             (emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg)
               (declare (ignore fn))
               (cl:let* ((deltas (cl:loop for i from 0 below n-fp
                                          collect (intern (format nil "%BW_D~a" i) pkg)))
                         (accum-forms
                          (cl:loop for arg in args
                                   for i from 0 below n-fp
                                   when (symbolp arg)
                                   collect `(set! ,(local-adj arg)
                                                  (+ ,(local-adj arg) ,(nth i deltas))))))
                 (when accum-forms
                   (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                            (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                              ,@accum-forms))))))

             ;; HOF inline backward: substitute concrete fn, remove funcall,
             ;; ANF-transform the concrete body, process backwards using
             ;; the kernel's own closures.
             (hof-inline-backward (fn args v)
               (cl:let* ((hof-data (gethash fn *differentiable-hof-store*)))
                 (unless hof-data
                   (error "HOF ~A not found in *differentiable-hof-store*" fn))
                 (cl:let* ((param-syms   (getf hof-data :param-syms))
                           (fn-param-idx (getf hof-data :fn-param-idx))
                           (body-forms   (getf hof-data :body-forms))
                           ;; Resolve concrete function from call args
                           (fn-arg       (nth fn-param-idx args))
                           (concrete-fn  (cond
                                           ;; (function +) — inline atomic
                                           ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                            (cadr fn-arg))
                                           ;; Bare symbol
                                           ((symbolp fn-arg) fn-arg)
                                           (t nil))))
                   (unless concrete-fn
                     (error "Cannot inline-differentiate HOF ~A: ~
                             could not resolve concrete fn from arg ~A" fn fn-arg))
                   ;; Build substitution: non-fn params -> call-site args
                   (cl:let* ((fn-param      (nth fn-param-idx param-syms))
                             (subst-alist
                              (cl:loop for p in param-syms
                                       for a in args
                                       for i from 0
                                       unless (= i fn-param-idx)
                                       collect (cons p a)))
                             (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                             (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                    subst-body))
                             ;; ANF + flatten the concrete body
                             (anf-body      (mapcar #'anf-transform concrete-body))
                             (hof-flat      (flatten-anf-body anf-body))
                             ;; Normalize last form if needed
                             (hof-flat-norm
                              (cl:let ((last-f (cl:car (cl:last hof-flat))))
                                (if (or (symbolp last-f)
                                        (and (consp last-f) (eq (cl:first last-f) 'return)))
                                    hof-flat
                                    (cl:let ((ret-sym (intern (format nil "%HOF_RET_%A" (symbol-name v))
                                                               (symbol-package v))))
                                      (append (butlast hof-flat)
                                              (list (list ret-sym last-f) ret-sym))))))
                             (return-vars   (%extract-return-vars hof-flat-norm)))
                     ;; Seed return-var adjoints to v's adjoint
                     (cl:dolist (rv return-vars)
                       (setf (gethash rv adjoint-map) (local-adj v)))
                     ;; Process hof-flat-norm backwards (same primitive rules)
                     (cl:dolist (hf-form (cl:reverse hof-flat-norm))
                       (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                         (cl:let ((hv    (car hf-form))
                                  (hexpr (cadr hf-form)))
                           (cond
                             ;; +
                             ((and (consp hexpr) (eq (car hexpr) '+))
                              (cl:let ((a (cadr hexpr)) (b (caddr hexpr)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj hv)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj hv)))))))
                             ;; -
                             ((and (consp hexpr) (eq (car hexpr) '-))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                                (when b (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj))))))))
                             ;; *
                             ((and (consp hexpr) (eq (car hexpr) '*))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                             ;; /
                             ((and (consp hexpr) (eq (car hexpr) '/))
                              (cl:let* ((a (cadr hexpr)) (b (caddr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                                (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                             ;; sin
                             ((and (consp hexpr) (eq (car hexpr) 'sin))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a)
                                  (cl:let* ((a-adj (local-adj a))
                                            (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                                    (setf (gethash cos-a adjoint-map) cos-a)
                                    (emit `(set! ,cos-a (cos ,a)))
                                    (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                             ;; cos
                             ((and (consp hexpr) (eq (car hexpr) 'cos))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a)
                                  (cl:let* ((a-adj (local-adj a))
                                            (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                                    (setf (gethash sin-a adjoint-map) sin-a)
                                    (emit `(set! ,sin-a (sin ,a)))
                                    (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                             ;; ~ cell read
                             ((and (consp hexpr) (eq (car hexpr) '~))
                              (cl:let* ((a (cadr hexpr)) (v-adj (local-adj hv)))
                                (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                             ;; Nested known differentiable sub-function
                             ((and (consp hexpr)
                                   (symbolp (car hexpr))
                                   (gethash (car hexpr) *differentiable-functions*))
                              (cl:let* ((nfn   (car hexpr))
                                        (nargs (cdr hexpr))
                                        (ninfo (gethash nfn *differentiable-functions*)))
                                (if (getf ninfo :hof)
                                    (hof-inline-backward nfn nargs hv)
                                    (emit-sub-fn-backward nfn nargs
                                                          (getf ninfo :bkwd-name)
                                                          (list (local-adj hv))
                                                          (getf ninfo :n-float-params)
                                                          (symbol-package hv)))))
                             ;; Unknown → error
                             (t (error "HOF inline backward: unsupported op ~A in inlined body of ~A"
                                       (if (consp hexpr) (car hexpr) hexpr) fn))))))))))

             ) ; end labels binding list

      (cl:let ((reversed-body (reverse flat-anf)))
        (cl:dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; Primitive: +
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr)) (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; Primitive: -
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; Primitive: *
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; Primitive: /
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; Primitive: sin
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; Primitive: cos
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; Cell read: ~
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; B1: Known differentiable sub-function call
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn   (car expr))
                               (args (cdr expr))
                               (info (gethash fn *differentiable-functions*)))
                      (if (getf info :hof)
                          ;; HOF: inline backward differentiation
                          (hof-inline-backward fn args v)
                          ;; Normal: call _GRAD companion
                          (emit-sub-fn-backward fn args
                                                (getf info :bkwd-name)
                                                (list (local-adj v))
                                                (getf info :n-float-params)
                                                (symbol-package v)))))
                  ;; B2.5: Struct accessor (name ends in ~): treat like identity.
                  ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
                        (cl:let ((fname (symbol-name (car expr))))
                          (and (> (length fname) 1)
                               (cl:char= (cl:char fname (1- (length fname))) #\~))))
                    (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
                      (when (symbolp a)
                        (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; Comparison/boolean ops: skip (no float adjoint contribution)
                  ((and (consp expr) (symbolp (car expr))
                        (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
                   nil)
                  ;; If form: skip (branching — no adjoint through condition)
                  ((and (consp expr) (symbolp (car expr))
                        (string= (symbol-name (car expr)) "IF"))
                   nil)
                  ;; B3: Unknown function → error
                  ;; B3: Unknown function — log and skip (built-in or non-float user fn).
                  ;; All float-param user fns are caught by B1 via pre-registration.
                  ((and (consp expr) (symbolp (car expr)))
                   (log:debug "AUTODIFF: backward-walk skipping unknown call ~A in form ~A"
                              (car expr) (car form))
                   nil)
                  ;; Other compound expr: skip
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn   (car expr))
                             (args (cdr expr))
                             (info (gethash fn *differentiable-functions*))
                             (bkwd (getf info :bkwd-name))
                             (n-fp (getf info :n-float-params))
                             (pkg  (symbol-package (car result-vars)))
                             (t-adjs (mapcar #'local-adj result-vars)))
                    (emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg)))))

            ;; ---- B4: Mutation of kernel input cell ----------------
            ((and (consp form) (eq (car form) 'set!))
              (cl:let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (cl:let ((target (cadr place)))
                    (cond
                      ((member target outputs)
                        (cl:let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                   (symbol-package target))))
                          (emit `(set! ,(local-adj val) (+ ,(local-adj val) (~ ,tgt-grad))))))
                      ((member target inputs)
                        (error "Cannot differentiate: kernel mutates input parameter ~A ~
                                via (set! (~ ~A) ...). Only output parameters may be written."
                               target target))
                      (t nil))))))

            ;; ---- Everything else: skip ----------------------------
            (t nil))))

      ;; Emit gradient output writes for all inputs
      (cl:loop for in in inputs
               for in-type in input-types do
                 (cl:let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
                                            (symbol-package in)))
                           (canon-type (crisp.compiler::canonicalize-type-specifier
                                        (if (listp in-type) in-type (list in-type))))
                           (is-cell (eq (car canon-type) 'cell)))
                   (if is-cell
                       (emit `(set! (~ ,in-grad) ,(local-adj in)))
                       (emit `(set! ,in-grad ,(local-adj in))))))

      (cl:let* ((local-bindings (cl:loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv 0.0)))
                (result `(let ,local-bindings
                            ,@(nreverse backward-forms))))
        result))))

;;; Fix: %generate-backward-function-walk — same log-and-skip for unknown calls.
;;; src/autodiff.lisp
(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars)
  "Generates the backward-pass body for a def-function.
FLAT-ANF         : flattened ANF of the forward function body.
FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).
T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).
RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).
Returns a (let (...) ...) form suitable as the body of the _GRAD companion function."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           (return-var-seeds (make-hash-table :test 'eq)))

    ;; Map each return-var to its t_grad seed
    (cl:loop for rv in return-vars
             for tg in t-grad-syms do
      (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (cl:let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (cond
                  ;; + : a_adj += v_adj, b_adj += v_adj
                  ((and (consp expr) (eq (car expr) '+))
                    (cl:let ((a (cadr expr))
                             (b (caddr expr)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                  ;; - : a_adj += v_adj, b_adj += -v_adj
                  ((and (consp expr) (eq (car expr) '-))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                  ;; * : a_adj += b * v_adj, b_adj += a * v_adj
                  ((and (consp expr) (eq (car expr) '*))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                  ;; / : a_adj += (1/b)*v_adj, b_adj += (-a/b^2)*v_adj
                  ((and (consp expr) (eq (car expr) '/))
                    (cl:let* ((a     (cadr expr))
                              (b     (caddr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                      (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                  ;; sin : a_adj += cos(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'sin))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (cos-a (intern (format nil "~a_COS" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash cos-a adjoint-map) cos-a)
                          (emit `(set! ,cos-a (cos ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                  ;; cos : a_adj += -sin(a) * v_adj
                  ((and (consp expr) (eq (car expr) 'cos))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a)
                        (cl:let* ((a-adj (local-adj a))
                                  (sin-a (intern (format nil "~a_SIN" (symbol-name a))
                                                 (symbol-package a))))
                          (setf (gethash sin-a adjoint-map) sin-a)
                          (emit `(set! ,sin-a (sin ,a)))
                          (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                  ;; ~ (cell read): a_adj += v_adj  (identity through cell deref)
                  ((and (consp expr) (eq (car expr) '~))
                    (cl:let* ((a     (cadr expr))
                              (v-adj (local-adj v)))
                      (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                  ;; Known differentiable sub-function call — single return value
                  ((and (consp expr)
                        (symbolp (car expr))
                        (gethash (car expr) *differentiable-functions*))
                    (cl:let* ((fn      (car expr))
                              (args    (cdr expr))
                              (info    (gethash fn *differentiable-functions*))
                              (bkwd-fn (getf info :bkwd-name))
                              (n-fp    (getf info :n-float-params))
                              (pkg     (symbol-package fn))
                              (deltas  (cl:loop for i from 0 below n-fp
                                                collect (intern (format nil "%~a_D~a" (symbol-name v) i) pkg)))
                              (v-adj   (local-adj v))
                              (accum-forms
                               (cl:loop for arg in args
                                        for i from 0 below n-fp
                                        when (symbolp arg)
                                        collect `(set! ,(local-adj arg) (+ ,(local-adj arg) ,(nth i deltas))))))
                      (when accum-forms
                        (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                                 (let (,(append deltas (list `(,bkwd-fn ,@args ,v-adj))))
                                   ,@accum-forms))))))
                  ;; Comparison/boolean ops: skip (no float adjoint contribution)
                  ((and (consp expr) (symbolp (car expr))
                        (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
                   nil)
                  ;; If form: skip (branching — recomputation strategy, no adjoint through condition)
                  ((and (consp expr) (symbolp (car expr))
                        (string= (symbol-name (car expr)) "IF"))
                   nil)
                  ;; Unknown function call — error
                  ;; Unknown function call — log and skip.
                  ;; Float-param user fns are caught by B1 via pre-registration.
                  ((and (consp expr) (symbolp (car expr)))
                   (log:debug "AUTODIFF: fn-backward-walk skipping unknown call ~A" (car expr))
                   nil)
                  ;; Everything else: skip silently
                  (t nil))))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn      (car expr))
                             (args    (cdr expr))
                             (info    (gethash fn *differentiable-functions*))
                             (bkwd-fn (getf info :bkwd-name))
                             (n-fp    (getf info :n-float-params))
                             (n-ret   (getf info :n-return))
                             (pkg     (symbol-package fn))
                             (deltas  (cl:loop for i from 0 below n-fp
                                               collect (intern (format nil "%MV_D~a" i) pkg)))
                             (t-adjs  (mapcar #'local-adj result-vars))
                             (accum-forms
                              (cl:loop for arg in args
                                       for i from 0 below n-fp
                                       when (symbolp arg)
                                       collect `(set! ,(local-adj arg)
                                                      (+ ,(local-adj arg) ,(nth i deltas))))))
                    (when accum-forms
                      (emit `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                               (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adjs))))
                                 ,@accum-forms))))))))

            ;; ---- (return ...) or plain symbol: skip ---------------
            (t nil))))

    ;; Emit the return of float-param adjoints (inside labels scope)
    (emit `(return ,@(mapcar #'local-adj float-param-syms)))

    ;; Build local bindings:
    ;;   - forward single-value bindings from flat-anf (so temps like %ANF-T-3 are in scope)
    ;;   - return-var adjoints: initialised to their t_grad seed
    ;;   - all other adjoints: initialised to 0.0
    (cl:let* ((forward-bindings
               (cl:loop for form in flat-anf
                        when (and (consp form)
                                  (= (length form) 2)
                                  (symbolp (car form))
                                  (not (gethash (car form) return-var-seeds)))
                        collect form))
              (adjoint-bindings
               (cl:loop for v being the hash-keys of adjoint-map
                        using (hash-value adv)
                        collect (cl:let ((seed (gethash v return-var-seeds)))
                                  `(,adv ,(if seed seed 0.0)))))
              (all-bindings (append forward-bindings adjoint-bindings)))
      `(let ,all-bindings
         ,@(nreverse backward-forms))))))

;;; Fix: %generate-backward-function-ast — filter nil (void) from return-types.
;;; Functions declaring '=> nil' return type (void) produce return-types=(nil).
;;; Including nil as a t-grad type causes parse-type-specifier to error.
;;; Filter to return-types-non-void before computing n-return and t-grad-types.
;;; src/autodiff.lisp
(defun %generate-backward-function-ast (name params declarations body-forms)
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable
user function. Also registers the function in *differentiable-functions*.

For HOF functions (those with a function-type parameter), stores info in
*differentiable-hof-store* and registers with :hof t. Returns NIL for HOFs
since no separate _GRAD function is generated — the backward is inlined at
the kernel call site.

Returns the backward def-function form, or NIL if the function has no
differentiable float params or is a HOF."
  (cl:let* ((pkg (symbol-package name)))

    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)

      (cl:let* (;; Float-typed params (the differentiable ones)
                (float-param-entries
                 (cl:loop for pd in env
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-float-type-p (parameter-def-type pd)))
                          collect pd))
                (float-param-syms  (mapcar #'parameter-def-name float-param-entries))
                (n-float-params    (length float-param-syms))
                ;; Filter out nil (void) return types — void fns have no t-grad inputs.
                (return-types-non-void (remove nil return-types))
                (n-return          (length return-types-non-void))

                ;; HOF detection: any param has a function type?
                (fn-param-entries
                 (cl:loop for pd in env
                          for i from 0
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-function-type-p (parameter-def-type pd)))
                          collect (cons i pd)))
                (is-hof (consp fn-param-entries)))

        ;; If no differentiable params, nothing to do.
        (when (zerop n-float-params)
          (log:info "AUTODIFF: ~a has no float params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        ;; If HOF: store info and register with :hof t. No _GRAD function generated.
        (when is-hof
          (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                    (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                    ;; Strip any trailing source-location atom from body-forms
                    (clean-body    (cl:loop for f in body-forms
                                            unless (and (atom f) (not (symbolp f)))
                                            collect f)))
            (log:info "AUTODIFF: ~a is HOF (fn-param=~a idx=~a) — storing for inline backward"
                      name fn-param-sym fn-param-idx)
            (setf (gethash name *differentiable-hof-store*)
                  (list :param-syms       (cl:loop for pd in env
                                                   collect (parameter-def-name pd))
                        :fn-param-idx     fn-param-idx
                        :fn-param-sym     fn-param-sym
                        :float-param-syms float-param-syms
                        :body-forms       clean-body))
            (setf (gethash name *differentiable-functions*)
                  (list :hof t
                        :n-float-params n-float-params
                        :n-return n-return))
            (return-from %generate-backward-function-ast nil)))

        ;; Non-HOF: proceed with normal backward function generation.
        ;; Mutation check: error if any body form writes to a cell param.
        (%check-fn-body-for-mutations body-forms
                                      (mapcar #'parameter-def-name env)
                                      name)

        (cl:let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
                  (t-grad-syms (cl:loop for i from 0 below n-return
                                        collect (intern (format nil "T_GRAD~A" i) pkg)))
                  (orig-param-types (mapcar #'parameter-def-type env))
                  (t-grad-types return-types-non-void)
                  (bkwd-params (append params t-grad-syms))
                  (bkwd-fn-spec
                   `(function (,@orig-param-types ,@t-grad-types
                               => ,@(make-list n-float-params :initial-element 'float)))))

          (setf (gethash name *differentiable-functions*)
                (list :bkwd-name bkwd-name
                      :n-float-params n-float-params
                      :n-return n-return))

          (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-fp=~a n-ret=~a)"
                    bkwd-name name n-float-params n-return)

          (cl:let* ((anf-body   (mapcar #'anf-transform body-forms))
                    (raw-flat   (flatten-anf-body anf-body))
                    (flat-anf
                     (cl:let ((last-f (cl:car (cl:last raw-flat))))
                       (if (or (symbolp last-f)
                               (and (consp last-f) (eq (cl:first last-f) 'return)))
                           raw-flat
                           (cl:let ((ret-sym (intern "%RET-0" pkg)))
                             (append (butlast raw-flat)
                                     (list (list ret-sym last-f)
                                           ret-sym))))))
                    (return-vars (%extract-return-vars flat-anf))
                    (bkwd-body  (%generate-backward-function-walk
                                 flat-anf float-param-syms t-grad-syms return-vars)))

            `(def-function ,bkwd-name ,bkwd-params
               (declare #'(,@(second bkwd-fn-spec)))
               ,bkwd-body)))))))

;;; Fix: %pre-register-differentiable-fns v6 — same nil filter for n-return.
;;; src/analysis/core.lisp
(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type.
Guards parse-function-declarations against unknown-type errors from brand types
that are not yet registered at pre-registration time."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; Top-level def-function: existing HOF-aware logic
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (handler-case
               (multiple-value-bind (env return-types)
                   (parse-function-declarations params declarations)
                 (cl:let* ((float-param-entries
                            (cl:loop for pd in env
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-float-type-p (parameter-def-type pd)))
                                     collect pd))
                           (n-float-params (length float-param-entries))
                         (return-types-nv (remove nil return-types))
                           (n-return (length return-types-nv))
                           (fn-param-entries
                            (cl:loop for pd in env
                                     for i from 0
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-function-type-p (parameter-def-type pd)))
                                     collect (cons i pd)))
                           (is-hof (consp fn-param-entries)))
                   (when (> n-float-params 0)
                     (if is-hof
                         (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                   (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                   (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                   (body-forms (cl:loop for f in body-and-loc
                                                        unless (and (listp f) (eq (car f) 'declare))
                                                        collect f))
                                   (clean-body  (cl:loop for f in body-forms
                                                         unless (and (atom f) (not (symbolp f)))
                                                         collect f)))
                           (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                     name fn-param-sym fn-param-idx)
                           (setf (gethash name *differentiable-hof-store*)
                                 (list :param-syms       (cl:loop for pd in env
                                                                  collect (parameter-def-name pd))
                                       :fn-param-idx     fn-param-idx
                                       :fn-param-sym     fn-param-sym
                                       :float-param-syms float-param-syms
                                       :body-forms       clean-body))
                           (setf (gethash name *differentiable-functions*)
                                 (list :hof t
                                       :n-float-params n-float-params
                                       :n-return n-return)))
                         (cl:let* ((pkg (symbol-package name))
                                   (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                           (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                     name bkwd-name n-float-params n-return)
                           (setf (gethash name *differentiable-functions*)
                                 (list :bkwd-name bkwd-name
                                       :n-float-params n-float-params
                                       :n-return n-return)))))))
               (error (e)
                 (log:debug "AUTODIFF: Skipping pre-registration of ~a -- type parse error: ~a" name e))))))

        ;; progn: recurse
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))

        ;; with-template-type: walk body for HOF def-functions using funcall scanning
        ;; (cannot use parse-function-declarations here -- types contain T placeholder)
        ((and (consp form) (eq (car form) 'with-template-type))
         (cl:dolist (bform (cddr form))   ; skip 'with-template-type' and params list
           (when (and (consp bform) (eq (car bform) 'def-function))
             (cl:let* ((name        (second bform))
                       (params      (third bform))
                       (body-and-loc (cdddr bform))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f) (eq (cl:first f) 'declare))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Detect HOF param by looking for (funcall <param> ...) in body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (cl:return)))
               (when (and fn-param-idx
                          (not (gethash name *differentiable-functions*)))
                 (log:info "AUTODIFF: Pre-registering HOF template ~a via with-template-type (fn-param=~a idx=~a)"
                           name fn-param-sym fn-param-idx)
                 (setf (gethash name *differentiable-hof-store*)
                       (list :param-syms       params
                             :fn-param-idx     fn-param-idx
                             :fn-param-sym     fn-param-sym
                             :float-param-syms (cl:loop for p in params
                                                        for i from 0
                                                        unless (= i fn-param-idx)
                                                        collect p)
                             :body-forms       fn-body))
                 (setf (gethash name *differentiable-functions*)
                       (list :hof t
                             :n-float-params (1- (length params))
                             :n-return 1)))))))))))
