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
