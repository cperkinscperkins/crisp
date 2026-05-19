;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; ==========================================================================
;; Endeavor 107 — make stride macros AD-able by expanding them BEFORE the
;; AD pipeline walks the kernel body.
;;
;; Background
;; ----------
;; loop-vector-stride / tensor-stride / grid-stride were implemented as
;; expression analyzers (run during the analysis phase of forward
;; compilation).  But %generate-backward-kernel-ast in src/macros.lisp
;; walks the kernel's RAW source body through `anf-transform` BEFORE the
;; analyzer phase runs.  When the AD pass sees `(tensor-stride A (i) ...)`,
;; it never expands the macro — it falls through to "Function X is not
;; differentiable" once the walk reaches some opcode inside the unexpanded
;; body.  Result: every test that used a stride macro had to be tagged
;; `forward-only`, even when its chain rule was otherwise well-defined.
;;
;; Fix
;; ---
;; Extract the analyzer-time expansion logic into source-to-source helper
;; functions:
;;   %expand-tensor-stride-form         (form ct location)        → expansion
;;   %expand-grid-stride-form           (form location)           → expansion
;;   %expand-loop-vector-stride-form    (form location)           → expansion
;;
;; The analyzers call these helpers (passing the env-resolved CT).  A new
;; AD pre-pass — %expand-stride-macros-in-form — walks the kernel body and
;; rewrites every stride form into its expansion before anf-transform sees
;; it.  The pre-pass resolves CT statically via the kernel's signature-types
;; (no env needed for the bare-symbol case which covers all of 092/093/105).
;;
;; Forward IR is unchanged in shape (the analyzers still drive the forward
;; compile).  Backward IR sees an `if + dotimes + let + set!` tree which AD
;; already knows how to walk.

;; --------------------------------------------------------------------------
;; Source-to-source expansion helpers.  Pure: no env, no analyze-expression.
;; Each takes the source form + (for tensor-stride) the resolved CT, and
;; returns the expanded source form ready for either analyze-expression
;; (forward path) or anf-transform (backward path).

(defun %expand-tensor-stride-form (expr ct location)
  "Pure expansion of (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).
   CT must be :last or :first (already resolved by caller).  Returns the
   expanded let+dotimes+if+let tree.  Validates form shape only — strict-
   tag vs CT agreement and tensor-arity checks are the caller's job."
  (let* ((strict-p   (keywordp (third expr)))
         (bindings   (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings (listp bindings) (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message (if strict-p
                          "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                          "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
             :source-location location))
    (let* ((n (length bindings))
           (t-sym (gensym "T"))
           (gid-sym (gensym "GID"))
           (gsize-sym (gensym "GSIZE"))
           (len-sym (gensym "LEN"))
           (k-sym (gensym "K"))
           (flat-sym (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (declare-sym (intern "DECLARE" cl-pkg))
           (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
           (dotimes-sym (intern "DOTIMES" cl-pkg))
           (if-sym (intern "IF" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
           (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym (intern "LENGTH~" cl-pkg))
           (extents-tilde (intern "EXTENTS~" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (extent-bindings
            (loop for esym in extents-syms
                  for i from 0
                  collect (list esym (list aref-sym (list extents-tilde t-sym) i))))
           (stride-bindings (%ts-build-stride-bindings extents-syms ct))
           (decode-bindings (if (= n 1)
                                (list (list (first bindings) flat-sym))
                                (%ts-build-decode-bindings flat-sym bindings
                                                           (mapcar #'first stride-bindings)
                                                           ct))))
      (let* ((inner-body
              (if (= (length body-forms) 1)
                  (first body-forms)
                  (cons progn-sym body-forms)))
             (inner-let (list let-sym decode-bindings inner-body))
             (inner-if (list if-sym (list lt-sym flat-sym len-sym) inner-let))
             (flat-let (list let-sym
                             (list (list flat-sym (list plus-sym k-sym gid-sym)))
                             inner-if))
             (dotimes-form (list dotimes-sym
                                 (list k-sym len-sym gsize-sym)
                                 flat-let))
             (outer-let
              (list* let-sym
                     (append (list (list t-sym tensor-form)
                                   (list gid-sym (list get-gid-sym 0))
                                   (list gsize-sym (list get-gsize-sym 0))
                                   (list len-sym (list len-tilde-sym t-sym)))
                             extent-bindings
                             stride-bindings)
                     (list (list declare-sym (list grid-level-sym))
                           dotimes-form))))
        outer-let))))

(defun %expand-grid-stride-form (expr location)
  "Pure expansion of (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  No type
   info needed — grid-stride is always rightmost-binding-gets-warp."
  (unless (and (>= (length expr) 4)
               (listp (second expr)) (listp (third expr))
               (every #'symbolp (third expr))
               (>= (length (second expr)) 1)
               (= (length (second expr)) (length (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed grid-stride: expected (grid-stride (SIZE ...) (BINDING ...) BODY...) with size and binding arity matching and >= 1"
           :source-location location))
  (let* ((size-forms (second expr))
         (bindings (third expr))
         (body-forms (cdddr expr))
         (n (length bindings))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (if-sym (intern "IF" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
         (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (lt-sym (intern "<" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (k-sym (gensym "K"))
         (flat-sym (gensym "FLAT"))
         (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings (loop for esym in extents-syms
                              for form in size-forms
                              collect (list esym (list to-ulong-sym form))))
         (len-form (if (= n 1)
                       (first extents-syms)
                       (reduce (lambda (a b) (list mul-sym a b)) extents-syms)))
         (stride-bindings (%ts-build-stride-bindings extents-syms :last))
         (decode-bindings (if (= n 1)
                              (list (list (first bindings) flat-sym))
                              (%ts-build-decode-bindings flat-sym bindings
                                                         (mapcar #'first stride-bindings)
                                                         :last)))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let (list let-sym decode-bindings inner-body))
         (inner-if (list if-sym (list lt-sym flat-sym len-sym) inner-let))
         (flat-let (list let-sym
                         (list (list flat-sym (list plus-sym k-sym gid-sym)))
                         inner-if))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym gsize-sym)
                             flat-let))
         (outer-let
          (list* let-sym
                 (append (list (list gid-sym (list get-gid-sym 0))
                               (list gsize-sym (list get-gsize-sym 0)))
                         size-bindings
                         (list (list len-sym len-form))
                         stride-bindings)
                 (list (list declare-sym (list grid-level-sym))
                       dotimes-form))))
    outer-let))

(defun %expand-loop-vector-stride-form (expr location)
  "Pure expansion of (loop-vector-stride VEC (VAR) BODY...).  Mirrors the
   original analyzer expansion but uses IF instead of WHEN so the AD
   backward walker recognises the conditional (107 fix)."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form (second expr))
         (var-name (first (third expr)))
         (body-forms (cdddr expr))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (k-sym (gensym "K"))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (if-sym (intern "IF" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
         (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (lt-sym (intern "<" cl-pkg))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-if (list if-sym (list lt-sym var-name len-sym) inner-body))
         (inner-let (list let-sym
                          (list (list var-name (list plus-sym k-sym gid-sym)))
                          inner-if))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym gsize-sym)
                             inner-let))
         (expansion (list let-sym
                          (list (list gid-sym (list get-gid-sym 0))
                                (list gsize-sym (list get-gsize-sym 0))
                                (list len-sym (list len-tilde-sym vec-form)))
                          (list declare-sym (list grid-level-sym))
                          dotimes-form)))
    expansion))

;; --------------------------------------------------------------------------
;; CT resolution helpers — used by both analyzer (env-based) and AD pre-pass
;; (signature-types-based).

(defun %resolve-tensor-form-ct (tensor-form type-resolver-fn)
  "Returns the static :contiguous-term keyword (:last/:first) of TENSOR-FORM,
   or NIL when it can't be determined.  TYPE-RESOLVER-FN: (sym -> static-type-or-nil).
   Only works when TENSOR-FORM is a bare symbol (the common case)."
  (when (and tensor-form (symbolp tensor-form) type-resolver-fn)
    (let ((ty (funcall type-resolver-fn tensor-form)))
      (when ty
        (let* ((canon (%ts-canonicalize-tensor-type ty))
               (raw (when (listp canon) (%get-tensor-ct canon))))
          (cond
            ((keywordp raw) raw)
            ((symbolp raw) (intern (symbol-name raw) :keyword))
            (t nil)))))))

(defun %tensor-stride-resolve-ct (expr type-resolver-fn location)
  "Determines the effective CT for expanding a tensor-stride EXPR.
   Handles both safe and strict variants:
     - Safe: returns the tensor's static CT, or :last with log:warn if
       it can't be resolved.
     - Strict: validates LAYOUT-TAG agrees with the tensor's static CT
       (when known) and returns the tag-implied CT."
  (let* ((strict-p (keywordp (third expr)))
         (layout-tag (when strict-p (third expr)))
         (bindings (if strict-p (fourth expr) (third expr)))
         (n (length bindings))
         (tensor-form (second expr))
         (static-ct (%resolve-tensor-form-ct tensor-form type-resolver-fn))
         (tag-ct (when strict-p (%ts-layout-tag-to-ct layout-tag n location))))
    (cond
      ((not strict-p)
       (or static-ct
           (progn
             (log:warn "tensor-stride: cannot statically determine contiguous-term for ~S; defaulting to :last (use the strict variant to make the layout explicit)"
                       tensor-form)
             :last)))
      ((null static-ct) tag-ct)
      ((eq tag-ct static-ct) tag-ct)
      (t (error 'crisp-compiler-error
                :message (format nil "tensor-stride: layout-tag ~S implies contiguous-term ~S but the tensor's static type has contiguous-term ~S"
                                 layout-tag tag-ct static-ct)
                :source-location location)))))

;; --------------------------------------------------------------------------
;; Recursive walker — used by the AD pre-pass.

(defun %make-kernel-param-type-resolver (params types)
  "Returns a closure (sym -> static-type-or-nil) built from the kernel's
   PARAMS and their declared TYPES.  Used by the AD pre-pass to resolve
   tensor-stride CT without an env."
  (let ((map (make-hash-table :test 'eq)))
    (loop for p in params for ty in types
          when (symbolp p) do (setf (gethash p map) ty))
    (lambda (sym) (and (symbolp sym) (gethash sym map)))))

(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites any tensor-stride / grid-stride /
   loop-vector-stride forms into their expansions.  TYPE-RESOLVER-FN is
   used to determine tensor-stride's CT (a closure from
   %make-kernel-param-type-resolver, or NIL).  Inserts the expansion in
   place — the result is fed to anf-transform by %generate-backward-kernel-ast."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%expand-stride-macros-in-form sub type-resolver-fn location)) form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "TENSOR-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (ct (%tensor-stride-resolve-ct walked type-resolver-fn location)))
            (%expand-tensor-stride-form walked ct location)))
         ((string-equal op-name "GRID-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-grid-stride-form walked location)))
         ((string-equal op-name "LOOP-VECTOR-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-loop-vector-stride-form walked location)))
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                        (cdr form)))))))))

;; --------------------------------------------------------------------------
;; Refactored analyzers — call the shared helpers, passing an env-based
;; resolver.  Forward IR shape is unchanged.

(defun analyze-tensor-stride-expression (expr env context location)
  "Analyzes (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).
   Delegates expansion to %expand-tensor-stride-form (shared with the AD
   pre-pass).  Env-based CT resolution: pre-analyzes the tensor form to
   read its static type."
  (let* ((tensor-form (second expr))
         (env-resolver
          (lambda (sym)
            (when (symbolp sym)
              (handler-case
                  (let ((node (analyze-expression sym env context (append location '(1)))))
                    (semantic-node-type node))
                (error () nil)))))
         (static-ct (%resolve-tensor-form-ct tensor-form env-resolver))
         ;; Strict variant validation reuses %tensor-stride-resolve-ct.  For the
         ;; safe variant fall back to %tensor-stride-resolve-ct's default chain.
         (ct (%tensor-stride-resolve-ct expr env-resolver location))
         ;; Bindings-arity vs declared-N check (env path only — pre-pass relies
         ;; on the type-resolver miss for non-symbol tensor forms).
         (strict-p (keywordp (third expr)))
         (bindings (if strict-p (fourth expr) (third expr)))
         (n (length bindings))
         (canon (and (symbolp tensor-form)
                     (let ((ty (funcall env-resolver tensor-form)))
                       (and ty (%ts-canonicalize-tensor-type ty)))))
         (declared-n (when (and (listp canon) (>= (length canon) 3))
                       (third canon))))
    (declare (ignore static-ct))
    (when (and (integerp declared-n) (/= declared-n n))
      (error 'crisp-compiler-error
             :message (format nil
                              "tensor-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                              declared-n n)
             :source-location location))
    (analyze-expression (%expand-tensor-stride-form expr ct location)
                        env context location)))

(defun analyze-grid-stride-expression (expr env context location)
  "Analyzes (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  Delegates to
   %expand-grid-stride-form."
  (analyze-expression (%expand-grid-stride-form expr location)
                      env context location))

(defun analyze-loop-vector-stride-expression (expr env context location)
  "Analyzes (loop-vector-stride VEC (VAR) BODY...).  Delegates to
   %expand-loop-vector-stride-form."
  (analyze-expression (%expand-loop-vector-stride-form expr location)
                      env context location))

;; ==========================================================================
;; 107 — structure-preserving AD walker.
;;
;; Whole-function replacement of generate-backward-walk.  Previously the
;; dispatch loop only handled flat-anf bindings + set! forms; control-flow
;; forms (dotimes, if, let) fell through to (t nil) and their bodies were
;; never AD-walked.  That meant a kernel body wrapped in tensor-stride /
;; loop-vector-stride / grid-stride had its inner chain rule silently
;; dropped — backward kernel compiled but produced zero gradients.
;;
;; New version: process-form recursively dispatches.  For each control-flow
;; form it captures the inner backward emissions, then wraps them in a
;; mirrored construct so the backward kernel's structure matches the
;; forward's.  E.g.  forward `(dotimes (k N) BODY)` becomes backward
;; `(dotimes (k N) BACKWARD-OF-BODY)`, with the same iteration count.  Let
;; bindings are preserved verbatim so primals remain available in scope.

(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                               &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   107: now structure-preserving — recursively handles dotimes/if/let
   forms encountered in flat-anf, emitting backward constructs that mirror
   the forward structure.  Single-value bindings, multi-value bindings, and
   set! handling unchanged from the original implementation."
  (let* ((record-temp-entries
          (loop for form in flat-anf
                when (and (consp form) (= (length form) 2)
                          (symbolp (car form))
                          (consp (cadr form))
                          (symbolp (caadr form))
                          (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                (let* ((temp-sym (car form))
                       (expr (cadr form))
                       (record-name (second expr))
                       (pkg (or kernel-pkg (symbol-package temp-sym))))
                  (when (or (%crisp-record-type-p record-name)
                            (%crisp-struct-type-p record-name))
                    (let* ((fields (%get-record-runtime-fields record-name))
                           (field-alist
                            (loop for (fname ftype) in fields
                                  collect (cons (symbol-name fname)
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                        pkg)))))
                      (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (let ((ht (when (or record-temp-entries *record-param-field-adjs*)
                      (make-hash-table :test 'eq))))
            (when ht
              (when *record-param-field-adjs*
                (maphash (lambda (k v) (setf (gethash k ht) v))
                         *record-param-field-adjs*))
              (dolist (entry record-temp-entries)
                (setf (gethash (car entry) ht) (cdr entry))))
            ht)))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym  in inputs
                     for typ  in input-types
                     when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht)))

        (labels ((local-adj (v)
                   (or (gethash v adjoint-map)
                       (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                          (or kernel-pkg (symbol-package v)))))
                         (setf (gethash v adjoint-map) adv)
                         adv)))
                 (emit (form)
                   (push form backward-forms))

                 (hof-inline-backward (fn args v)
                   (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                     (unless hof-data
                       (error "HOF ~A not found in *differentiable-hof-store*" fn))
                     (let* ((param-syms   (getf hof-data :param-syms))
                            (fn-param-idx (getf hof-data :fn-param-idx))
                            (body-forms   (getf hof-data :body-forms))
                            (fn-arg       (nth fn-param-idx args))
                            (concrete-fn  (cond
                                            ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                             (cadr fn-arg))
                                            ((symbolp fn-arg) fn-arg)
                                            (t nil))))
                       (unless concrete-fn
                         (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                       (let* ((fn-param      (nth fn-param-idx param-syms))
                              (subst-alist
                               (loop for p in param-syms
                                     for a in args
                                     for i from 0
                                     unless (= i fn-param-idx)
                                     collect (cons p a)))
                              (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                              (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                     subst-body))
                              (anf-body      (mapcar #'anf-transform concrete-body))
                              (hof-flat      (flatten-anf-body anf-body))
                              (hof-flat-norm
                               (let ((last-f (car (last hof-flat))))
                                 (if (or (symbolp last-f)
                                         (and (consp last-f) (eq (first last-f) 'return)))
                                     hof-flat
                                     (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                            (symbol-package v))))
                                       (append (butlast hof-flat)
                                               (list (list ret-sym last-f) ret-sym))))))
                              (return-vars   (%extract-return-vars hof-flat-norm)))
                         (dolist (rv return-vars)
                           (setf (gethash rv adjoint-map) (local-adj v)))
                         (dolist (hf-form (reverse hof-flat-norm))
                           (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                             (let ((hv    (car hf-form))
                                   (hexpr (cadr hf-form)))
                               (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                              :hof-handler-fn #'hof-inline-backward
                                                              :error-on-unknown t
                                                              :tensor-inputs-ht nil))))))))

                 ;; 107: process a single form, dispatching on shape.
                 ;; EMIT-FN receives each emitted backward form.  Recurses on
                 ;; let/dotimes/if bodies.
                 (process-form (form emit-fn)
                   (cond
                     ;; (declare ...) — skip silently
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "DECLARE")) nil)

                     ;; set! — must come BEFORE the single/multi-value cases
                     ;; (set! is a list with first element a symbol)
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "SET!"))
                      (let ((place (cadr form))
                            (val   (caddr form)))
                        (when (and (consp place) (eq (car place) '~) (symbolp val))
                          (let ((target  (cadr place))
                                (indices (cddr place)))
                            (cond
                              ((member target outputs)
                               (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                       (symbol-package target))))
                                 (funcall emit-fn `(set! ,(local-adj val)
                                                         (+ ,(local-adj val) (~ ,tgt-grad ,@indices))))))
                              ((member target inputs)
                               (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                                      target target))
                              (t nil))))))

                     ;; let — preserve bindings, recurse into body, emit chain
                     ;; rule for each binding after body.  Bindings stay scoped
                     ;; so primals remain available to the chain rule inside.
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "LET"))
                      (let* ((bindings (cadr form))
                             (body (cddr form))
                             (local-forms nil))
                        (cl:flet ((local-emit (f) (push f local-forms)))
                          ;; Walk body backwards
                          (dolist (b (reverse body))
                            (process-form b #'local-emit))
                          ;; Walk bindings backwards: each is a (v expr)
                          ;; treated as a single-value binding for chain rule.
                          (dolist (b (reverse bindings))
                            (when (and (consp b) (= (length b) 2) (symbolp (car b)))
                              (process-form b #'local-emit))))
                        (funcall emit-fn `(let ,bindings ,@(nreverse local-forms)))))

                     ;; dotimes — same iteration in backward.  No chain rule on
                     ;; the binding (k is an induction variable, not data-dependent).
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "DOTIMES"))
                      (let* ((binding (cadr form))
                             (body (cddr form))
                             (local-forms nil))
                        (cl:flet ((local-emit (f) (push f local-forms)))
                          (dolist (b (reverse body))
                            (process-form b #'local-emit)))
                        (funcall emit-fn `(dotimes ,binding ,@(nreverse local-forms)))))

                     ;; if — recurse on then/else branches, preserve condition.
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "IF"))
                      (let* ((cond-form (cadr form))
                             (then-form (caddr form))
                             (else-form (cadddr form))
                             (then-local nil)
                             (else-local nil))
                        (when then-form
                          (process-form then-form (lambda (f) (push f then-local))))
                        (when (and else-form (not (null else-form)))
                          (process-form else-form (lambda (f) (push f else-local))))
                        (let ((then-body (cond
                                           ((null then-local) nil)
                                           ((= (length then-local) 1) (first then-local))
                                           (t `(progn ,@(nreverse then-local)))))
                              (else-body (cond
                                           ((null else-local) nil)
                                           ((= (length else-local) 1) (first else-local))
                                           (t `(progn ,@(nreverse else-local))))))
                          (funcall emit-fn
                                   (if else-body
                                       `(if ,cond-form ,(or then-body 'nil) ,else-body)
                                       `(if ,cond-form ,(or then-body 'nil)))))))

                     ;; progn — recurse on body
                     ((and (consp form) (symbolp (car form))
                           (string-equal (symbol-name (car form)) "PROGN"))
                      (dolist (sub (reverse (cdr form)))
                        (process-form sub emit-fn)))

                     ;; Single-value binding: (v expr).  Must come AFTER the
                     ;; control-flow cases (otherwise a 2-element form like
                     ;; `(if cond)` would match this — though that's not a
                     ;; well-formed if; the real conflict is multi-value
                     ;; matching IF-shaped 3-element forms).
                     ((and (listp form) (= (length form) 2) (symbolp (car form)))
                      (%handle-single-value-backward (car form) (cadr form)
                                                     adjoint-map emit-fn #'local-adj
                                                     :hof-handler-fn #'hof-inline-backward
                                                     :error-on-unknown t
                                                     :tensor-inputs-ht tensor-inputs-ht))

                     ;; Multi-value binding: (v0 v1 ... expr).  AFTER control
                     ;; flow.
                     ((and (listp form) (>= (length form) 3)
                           (symbolp (car form))
                           (every #'symbolp (butlast form)))
                      (let* ((result-vars (butlast form))
                             (expr        (car (last form))))
                        (when (and (consp expr)
                                   (symbolp (car expr))
                                   (gethash (car expr) *differentiable-functions*))
                          (let* ((fn   (car expr))
                                 (args (cdr expr))
                                 (info (gethash fn *differentiable-functions*))
                                 (bkwd (getf info :bkwd-name))
                                 (n-fp (getf info :n-float-params))
                                 (pkg  (symbol-package (car result-vars)))
                                 (t-adjs (mapcar #'local-adj result-vars)))
                            (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                   emit-fn #'local-adj "BW")))))

                     ;; Everything else: skip
                     (t nil))))

          (let ((reversed-body (reverse flat-anf)))
            (dolist (form reversed-body)
              (process-form form #'emit)))

          ;; Emit gradient output writes for all inputs.  Unchanged from src.
          (loop for in in inputs
                for in-type in input-types do
                  (let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                             (or kernel-pkg (symbol-package in))))
                         (canon-type (canonicalize-type-specifier
                                      (if (listp in-type) in-type (list in-type))))
                         (is-cell-input
                          (and (consp canon-type)
                               (string-equal (symbol-name (first canon-type)) "CELL")))
                         (is-tensor-input
                          (or (%crisp-float-tensor-type-p in-type)
                              (%crisp-integer-tensor-type-p in-type)))
                         (is-scalar-wrapped
                          (and (not is-cell-input) (not is-tensor-input)
                               (or (%crisp-integer-scalar-type-p in-type)
                                   (%crisp-float-type-p in-type)))))
                    (cond
                      (is-tensor-input nil)
                      (is-cell-input     (emit `(set! (~ ,in-grad) ,(local-adj in))))
                      (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,(local-adj in))))
                      (t                 (emit `(set! ,in-grad ,(local-adj in)))))))

          ;; Zero-init bindings.  Unchanged from src.
          (cl:flet ((promotes-to-double-p (t-spec)
                      (let ((promoted (%promote-to-float-adjoint t-spec)))
                        (or (eq promoted 'double)
                            (and (consp promoted) (eq (second promoted) 'double))))))
            (let* ((any-output-double
                    (some #'promotes-to-double-p output-types))
                   (typed-zero-for
                    (lambda (orig-sym)
                      (let* ((idx (position orig-sym inputs))
                             (in-type (when idx (nth idx input-types))))
                        (cond
                          (in-type
                           (if (promotes-to-double-p in-type) '(as double 0.0) 0.0))
                          (any-output-double '(as double 0.0))
                          (t 0.0)))))
                   (local-bindings (loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv ,(funcall typed-zero-for v))))
                   (result `(let ,local-bindings
                              ,@(nreverse backward-forms))))
              result)))))))

;; --------------------------------------------------------------------------
;; %generate-backward-kernel-ast — whole-function replacement.  Only addition
;; is the AD pre-pass that rewrites stride macros in the kernel body BEFORE
;; anf-transform sees them.  All other behaviour preserved verbatim.

(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-
   boundary accessor calls route adj into the SROA'd field's adj sym.
   Endeavor 107: pre-expands stride macros (tensor-stride / grid-stride /
   loop-vector-stride) in the kernel body so AD walks the expansion."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms
                            struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let* ((subst-body
                (mapcar (lambda (form)
                          (%substitute-record-accessors form record-subs-ht record-type-ht))
                        raw-body))
               ;; 107: AD pre-pass — rewrite stride macros into their expansions
               ;; using a kernel-param-based type resolver for tensor-stride CT.
               ;; The resolver is built from the ORIGINAL inputs/input-types
               ;; (not flat-inputs) so tensor-stride forms over a record param
               ;; resolve against the record's type before SROA renaming.  In
               ;; practice the tensor expression is a bare param name; the
               ;; resolver handles that cleanly.
               (kernel-type-resolver (%make-kernel-param-type-resolver inputs input-types))
               (expanded-body
                (mapcar (lambda (form)
                          (%expand-stride-macros-in-form form kernel-type-resolver nil))
                        subst-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                              (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                              (loop for entry in struct-shadow-info
                                    for p = (first entry)
                                    collect (nth (position p flat-inputs :test #'eq)
                                                 flat-input-types)))))
              (if (and (null augmented-diff-flat-inputs)
                       (null struct-shadow-info))
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  (let* ((anf-body      (mapcar #'anf-transform expanded-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         (struct-shadow-ht
                          (when struct-shadow-info
                            (let ((ht (make-hash-table :test 'eq)))
                              (dolist (entry struct-shadow-info)
                                (setf (gethash (first entry) ht)
                                      (cons (second entry)
                                            (fourth entry))))
                              (%register-shadow-anf-intermediates flat-anf ht)
                              ht)))
                         (kernel-record-param-field-adjs-ht
                          (when (> (hash-table-count record-subs-ht) 0)
                            (let ((ht (make-hash-table :test 'eq)))
                              (maphash
                               (lambda (rsym field-alist)
                                 (let ((adj-alist
                                        (loop for entry in field-alist
                                              for fname = (car entry)
                                              for fsym  = (cdr entry)
                                              unless (eq fname :%nested-leaf%)
                                              collect (cons (symbol-name fname)
                                                            (intern (format nil "~A_ADJ" (symbol-name fsym))
                                                                    pkg)))))
                                   (setf (gethash rsym ht) adj-alist)))
                               record-subs-ht)
                              ht)))
                         (raw-backward-walk
                          (let ((*struct-kernel-param-shadows* struct-shadow-ht)
                                (*record-param-field-adjs* kernel-record-param-field-adjs-ht))
                            (generate-backward-walk flat-anf
                                                    augmented-diff-flat-inputs outputs
                                                    augmented-diff-flat-input-types output-types
                                                    :kernel-pkg pkg)))
                         (backward-walk-1
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                         (backward-walk-2
                          (if struct-shadow-info
                              (let ((all-leaves
                                     (loop for entry in struct-shadow-info
                                           append (%collect-all-leaf-adj-syms (fourth entry)))))
                                (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                              backward-walk-1))
                         (backward-walk
                          (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
                         (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))
                    `(progn
                      (eval-when (:compile-toplevel :load-toplevel :execute)
                        (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                          (loop for p in ',bwd-params
                                   for t-spec in ',bwd-types
                                   collect (cons p t-spec))))
                      (def-kernel-exact ,bwd-name ,exploded-params
                                        (declare #'(,@exploded-types))
                                        (let (,@all-reassembly)
                                          (let (,@forward-bindings)
                                            ,backward-walk))
                                        (return)))))))))))))

;; --------------------------------------------------------------------------
;; src/autodiff.lisp
;; 107 iteration-local adjoint reset fix.
;;
;; Bug: the structure-preserving walker mirrored forward (dotimes ...) into
;; backward (dotimes ...) correctly, but did not re-zero adjoint allocas that
;; belong to variables bound INSIDE the loop body.  The chain rule emits
;; `(set! adj (+ adj ...))` (accumulate), and the adj allocas are hoisted to
;; the function entry block with a one-time store-of-zero — so across
;; iterations they accumulate stale per-iteration contributions and produce
;; wrong gradients whenever a thread executes more than one iteration of the
;; backward dotimes (e.g. any grid-stride / tensor-stride kernel run with
;; gsize < len, which is the normal case).
;;
;; Fix: at the top of the backward dotimes body, store the appropriately-
;; typed zero into every adj that corresponds to a variable bound somewhere
;; inside the iteration body.  Vars bound outside the loop (kernel params,
;; outer let* bindings) are NOT iter-local — their adjoints are real
;; gradient accumulators and must persist across iterations.
;;
;; %collect-locally-bound-vars walks a list of body forms and returns the
;; set of symbols introduced by single-/multi-value bindings, the dotimes
;; induction var, and any let bindings inside (recurses through let,
;; dotimes, if, progn).
;;
;; The DOTIMES case in process-form runs the body walk first (so chain
;; rule populates adjoint-map), then emits a `(set! adv ZERO)` for each
;; iter-local var whose adj is actually used.  any-output-double is
;; precomputed once at the top of the function (used to pick `0.0` vs
;; `(as double 0.0)`) instead of being computed only at the post-walk
;; let-wrap stage.

(defun %collect-locally-bound-vars (body-forms)
  "Returns a list of distinct symbols introduced as bindings anywhere
   inside BODY-FORMS (a list of forms).  Includes single-value bindings
   `(v expr)`, multi-value bindings `(v0 v1 ... expr)`, the induction var
   of nested DOTIMES, and the bound vars of nested LET.  Recurses through
   LET / DOTIMES / IF / PROGN bodies.  SET! and DECLARE introduce no
   bindings, so they are not scanned.  Used by the AD walker to identify
   adjoint allocas that must be reset at the top of each backward
   loop iteration."
  (let ((vars nil))
    (labels ((push-var (v)
               (when (and (symbolp v) (not (member v vars :test #'eq)))
                 (push v vars)))
             (scan (form)
               (cond
                 ((or (null form) (symbolp form) (not (consp form))) nil)
                 ((not (symbolp (car form))) nil)
                 ((or (string-equal (symbol-name (car form)) "DECLARE")
                      (string-equal (symbol-name (car form)) "SET!")) nil)
                 ((string-equal (symbol-name (car form)) "LET")
                  (dolist (b (cadr form))
                    (when (and (consp b) (symbolp (car b)))
                      (push-var (car b))))
                  (dolist (b (cddr form)) (scan b)))
                 ((string-equal (symbol-name (car form)) "DOTIMES")
                  (let ((binding (cadr form)))
                    (when (and (consp binding) (symbolp (car binding)))
                      (push-var (car binding))))
                  (dolist (b (cddr form)) (scan b)))
                 ((string-equal (symbol-name (car form)) "IF")
                  (when (caddr form) (scan (caddr form)))
                  (when (cadddr form) (scan (cadddr form))))
                 ((string-equal (symbol-name (car form)) "PROGN")
                  (dolist (sub (cdr form)) (scan sub)))
                 ;; Single-value binding: (v expr)
                 ((and (= (length form) 2) (symbolp (car form)))
                  (push-var (car form)))
                 ;; Multi-value binding: (v0 v1 ... expr) where all but last are syms
                 ((and (>= (length form) 3)
                       (every #'symbolp (butlast form)))
                  (dolist (v (butlast form)) (push-var v)))
                 (t nil))))
      (dolist (f body-forms) (scan f)))
    (nreverse vars)))

;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                               &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   107: structure-preserving — recursively handles dotimes/if/let forms
   encountered in flat-anf, emitting backward constructs that mirror the
   forward structure.  Now also re-zeroes iteration-local adjoints at the
   top of each backward dotimes body, so the chain-rule `adj += ...`
   pattern does not accumulate across iterations of a grid-stride /
   tensor-stride loop."
  (let* ((record-temp-entries
          (loop for form in flat-anf
                when (and (consp form) (= (length form) 2)
                          (symbolp (car form))
                          (consp (cadr form))
                          (symbolp (caadr form))
                          (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                (let* ((temp-sym (car form))
                       (expr (cadr form))
                       (record-name (second expr))
                       (pkg (or kernel-pkg (symbol-package temp-sym))))
                  (when (or (%crisp-record-type-p record-name)
                            (%crisp-struct-type-p record-name))
                    (let* ((fields (%get-record-runtime-fields record-name))
                           (field-alist
                            (loop for (fname ftype) in fields
                                  collect (cons (symbol-name fname)
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                        pkg)))))
                      (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (let ((ht (when (or record-temp-entries *record-param-field-adjs*)
                      (make-hash-table :test 'eq))))
            (when ht
              (when *record-param-field-adjs*
                (maphash (lambda (k v) (setf (gethash k ht) v))
                         *record-param-field-adjs*))
              (dolist (entry record-temp-entries)
                (setf (gethash (car entry) ht) (cdr entry))))
            ht)))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym  in inputs
                     for typ  in input-types
                     when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht)))

        ;; 107: precompute any-output-double so the DOTIMES iter-zero-reset
        ;; case can pick the correctly-typed literal.  Same logic the
        ;; post-walk let-wrap uses for intermediate adjoints (anything not
        ;; an input gets `(as double 0.0)` if any kernel output is double-
        ;; promoted, else `0.0`).
        (cl:flet ((promotes-to-double-p (t-spec)
                    (let ((promoted (%promote-to-float-adjoint t-spec)))
                      (or (eq promoted 'double)
                          (and (consp promoted) (eq (second promoted) 'double))))))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (intermediate-zero (if any-output-double '(as double 0.0) 0.0)))

            (labels ((local-adj (v)
                       (or (gethash v adjoint-map)
                           (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                              (or kernel-pkg (symbol-package v)))))
                             (setf (gethash v adjoint-map) adv)
                             adv)))
                     (emit (form)
                       (push form backward-forms))

                     (hof-inline-backward (fn args v)
                       (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                         (unless hof-data
                           (error "HOF ~A not found in *differentiable-hof-store*" fn))
                         (let* ((param-syms   (getf hof-data :param-syms))
                                (fn-param-idx (getf hof-data :fn-param-idx))
                                (body-forms   (getf hof-data :body-forms))
                                (fn-arg       (nth fn-param-idx args))
                                (concrete-fn  (cond
                                                ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                 (cadr fn-arg))
                                                ((symbolp fn-arg) fn-arg)
                                                (t nil))))
                           (unless concrete-fn
                             (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                           (let* ((fn-param      (nth fn-param-idx param-syms))
                                  (subst-alist
                                   (loop for p in param-syms
                                         for a in args
                                         for i from 0
                                         unless (= i fn-param-idx)
                                         collect (cons p a)))
                                  (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                  (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                         subst-body))
                                  (anf-body      (mapcar #'anf-transform concrete-body))
                                  (hof-flat      (flatten-anf-body anf-body))
                                  (hof-flat-norm
                                   (let ((last-f (car (last hof-flat))))
                                     (if (or (symbolp last-f)
                                             (and (consp last-f) (eq (first last-f) 'return)))
                                         hof-flat
                                         (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                (symbol-package v))))
                                           (append (butlast hof-flat)
                                                   (list (list ret-sym last-f) ret-sym))))))
                                  (return-vars   (%extract-return-vars hof-flat-norm)))
                             (dolist (rv return-vars)
                               (setf (gethash rv adjoint-map) (local-adj v)))
                             (dolist (hf-form (reverse hof-flat-norm))
                               (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                 (let ((hv    (car hf-form))
                                       (hexpr (cadr hf-form)))
                                   (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                  :hof-handler-fn #'hof-inline-backward
                                                                  :error-on-unknown t
                                                                  :tensor-inputs-ht nil))))))))

                     (process-form (form emit-fn)
                       (cond
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DECLARE")) nil)

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "SET!"))
                          (let ((place (cadr form))
                                (val   (caddr form)))
                            (when (and (consp place) (eq (car place) '~) (symbolp val))
                              (let ((target  (cadr place))
                                    (indices (cddr place)))
                                (cond
                                  ((member target outputs)
                                   (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                           (symbol-package target))))
                                     (funcall emit-fn `(set! ,(local-adj val)
                                                             (+ ,(local-adj val) (~ ,tgt-grad ,@indices))))))
                                  ((member target inputs)
                                   (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                                          target target))
                                  (t nil))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LET"))
                          (let* ((bindings (cadr form))
                                 (body (cddr form))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit))
                              (dolist (b (reverse bindings))
                                (when (and (consp b) (= (length b) 2) (symbolp (car b)))
                                  (process-form b #'local-emit))))
                            (funcall emit-fn `(let ,bindings ,@(nreverse local-forms)))))

                         ;; 107 iter-local fix: after walking the body, emit a
                         ;; (set! adj ZERO) at the top of the backward body for
                         ;; each iteration-local variable whose adjoint is
                         ;; actually used by the chain rule.  Without this,
                         ;; adjoints leak across iterations and grad values
                         ;; scale with iteration count.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DOTIMES"))
                          (let* ((binding (cadr form))
                                 (body (cddr form))
                                 (local-vars (%collect-locally-bound-vars body))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit)))
                            (let ((zero-resets
                                   (loop for v in local-vars
                                         for adv = (gethash v adjoint-map)
                                         when adv
                                         collect `(set! ,adv ,intermediate-zero))))
                              (funcall emit-fn
                                       `(dotimes ,binding
                                          ,@zero-resets
                                          ,@(nreverse local-forms))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "IF"))
                          (let* ((cond-form (cadr form))
                                 (then-form (caddr form))
                                 (else-form (cadddr form))
                                 (then-local nil)
                                 (else-local nil))
                            (when then-form
                              (process-form then-form (lambda (f) (push f then-local))))
                            (when (and else-form (not (null else-form)))
                              (process-form else-form (lambda (f) (push f else-local))))
                            (let ((then-body (cond
                                               ((null then-local) nil)
                                               ((= (length then-local) 1) (first then-local))
                                               (t `(progn ,@(nreverse then-local)))))
                                  (else-body (cond
                                               ((null else-local) nil)
                                               ((= (length else-local) 1) (first else-local))
                                               (t `(progn ,@(nreverse else-local))))))
                              (funcall emit-fn
                                       (if else-body
                                           `(if ,cond-form ,(or then-body 'nil) ,else-body)
                                           `(if ,cond-form ,(or then-body 'nil)))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "PROGN"))
                          (dolist (sub (reverse (cdr form)))
                            (process-form sub emit-fn)))

                         ((and (listp form) (= (length form) 2) (symbolp (car form)))
                          (%handle-single-value-backward (car form) (cadr form)
                                                         adjoint-map emit-fn #'local-adj
                                                         :hof-handler-fn #'hof-inline-backward
                                                         :error-on-unknown t
                                                         :tensor-inputs-ht tensor-inputs-ht))

                         ((and (listp form) (>= (length form) 3)
                               (symbolp (car form))
                               (every #'symbolp (butlast form)))
                          (let* ((result-vars (butlast form))
                                 (expr        (car (last form))))
                            (when (and (consp expr)
                                       (symbolp (car expr))
                                       (gethash (car expr) *differentiable-functions*))
                              (let* ((fn   (car expr))
                                     (args (cdr expr))
                                     (info (gethash fn *differentiable-functions*))
                                     (bkwd (getf info :bkwd-name))
                                     (n-fp (getf info :n-float-params))
                                     (pkg  (symbol-package (car result-vars)))
                                     (t-adjs (mapcar #'local-adj result-vars)))
                                (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                       emit-fn #'local-adj "BW")))))

                         (t nil))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                                 (or kernel-pkg (symbol-package in))))
                             (canon-type (canonicalize-type-specifier
                                          (if (listp in-type) in-type (list in-type))))
                             (is-cell-input
                              (and (consp canon-type)
                                   (string-equal (symbol-name (first canon-type)) "CELL")))
                             (is-tensor-input
                              (or (%crisp-float-tensor-type-p in-type)
                                  (%crisp-integer-tensor-type-p in-type)))
                             (is-scalar-wrapped
                              (and (not is-cell-input) (not is-tensor-input)
                                   (or (%crisp-integer-scalar-type-p in-type)
                                       (%crisp-float-type-p in-type)))))
                        (cond
                          (is-tensor-input nil)
                          (is-cell-input     (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (t                 (emit `(set! ,in-grad ,(local-adj in)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          (cond
                            (in-type
                             (if (promotes-to-double-p in-type) '(as double 0.0) 0.0))
                            (any-output-double '(as double 0.0))
                            (t 0.0)))))
                     (local-bindings (loop for v being the hash-keys of adjoint-map
                                           using (hash-value adv)
                                           collect `(,adv ,(funcall typed-zero-for v))))
                     (result `(let ,local-bindings
                                ,@(nreverse backward-forms))))
                result))))))))

