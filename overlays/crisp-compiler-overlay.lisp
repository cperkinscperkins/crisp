;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-09-30 -- endeavour 176 folded into src/: BUGs 090-095, implicit scratch for the
;;;; reductions, scratch defaults and body scratch in generic functions, type-min / type-max /
;;;; type-infinity.  The L0 hoister overlay (overlays/hoist-l0) was folded in the same pass.
;;;;
;;;; Two things did NOT move, deliberately:
;;;;   * %IF-EXPLICIT-NIL-ELSE-IS-FALSE-P -- the first BUG 092 draft, superseded by
;;;;     %if-missing-else-is-false-p and called by nothing.
;;;;   * *GRID-ATOMIC-OPERATOR-MAP* -- carried into the overlay by accident with a script-extracted copy
;;;;     of register-ops-analyzers; src/analysis/ops.lisp already defines it, unchanged.

(in-package :crisp.compiler)

;;;; ===========================================================================
;;;; BUG 096 (ANF missed CL:LET) and BUG 097 (no _GRAD for &optional / &key functions -- stopgap).
;;;; Found by CI's --differentiate pass on 006/09 and 016/07-09, 2026-09-30.
;;;; ===========================================================================

;; src/analysis/core.lisp  (new -- place just before %pre-register-differentiable-fns)
(defun %lambda-list-generic-p (params)
  "T when lambda list PARAMS has &optional or &key -- a generic function whose variants are instantiated
   lazily.  Matched by name, so the reading package does not matter."
  (some (lambda (p) (and (symbolp p) (member (symbol-name p) '("&OPTIONAL" "&KEY") :test #'string-equal)))
        params))

;; src/analysis/core.lisp  (BUG 097 stopgap: generic functions are not registered as differentiable)
(defun %pre-register-differentiable-fns (forms &optional record-info)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type.
Guards parse-function-declarations against unknown-type errors from brand types
that are not yet registered at pre-registration time.

101 widening: records / structs / derived-from-record-or-struct contribute
their runtime-field count to the differentiable-param count, and a function
with any tensor or cell parameter is differentiable (handle-grad pathway).

RECORD-INFO is an alist of (NAME-STR . FIELD-COUNT) built by
%scan-forms-for-record-info at top-level call.  Recursive calls reuse it."
  (let ((record-info (or record-info (%scan-forms-for-record-info forms))))
    (when *differentiate-p*
      (dolist (form forms)
        (cond
          ;; Top-level def-function: existing HOF-aware logic, widened gate.
          ((and (consp form) (eq (car form) 'def-function))
           (let* ((name (second form))
                  (params (third form))
                  (body-and-loc (cdddr form)))
             (multiple-value-bind (declare-forms declarations fn-body)
                 (%extract-fn-body-and-declarations body-and-loc)
               (declare (ignore declare-forms))
               (let ((is-system (member '(crisp-system-generated) declarations :test #'equal)))
                 ;; BUG 097 (stopgap): an &optional / &key function is NOT differentiable yet -- its variants
                 ;; are instantiated lazily and no _GRAD companion is generated for them, so registering it
                 ;; made the backward pass call <name>_GRAD, which does not exist.  Unregistered, a call in an
                 ;; inactive context is a constant, and one that needs a gradient fails loudly as "not
                 ;; differentiable".  The real fix -- a lazily instantiated _GRAD per variant -- is BUG 097.
                 (when (%lambda-list-generic-p params)
                   (log:info "BUG 097: ~a has &optional/&key parameters -- not registered as differentiable" name))
                 (unless (or is-system (%fn-name-is-grad-p name) (%lambda-list-generic-p params))
                   (handler-case
                       (multiple-value-bind (env return-types)
                           (parse-function-declarations params declarations)
                         (let* ((float-param-entries
                                 (loop for pd in env
                                       when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                                 (%crisp-float-type-p (parameter-def-type pd)))
                                       collect pd))
                                ;; A2: active int scalar params (reach the return
                                ;; differentiably). Structural ints stay inactive.
                                (active-set (%active-scalar-param-set
                                             (mapcar #'parameter-def-name env) fn-body))
                                ;; 101: widened — counts record/struct field
                                ;; contributions and float scalars; handle types
                                ;; (tensors, cells) contribute 0 here and flow
                                ;; grad via the &out grad-handle pathway instead.
                                ;; A2: plus ACTIVE integer scalar params.
                                (n-diff-params
                                 (loop for pd in env
                                       when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                       sum (%count-active-contributions
                                            (parameter-def-type pd) (parameter-def-name pd)
                                            active-set record-info)))
                                (n-return (length (remove nil return-types)))
                                (fn-param-entries
                                 (loop for pd in env
                                       for i from 0
                                       when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                                 (%crisp-function-type-p (parameter-def-type pd)))
                                       collect (cons i pd)))
                                (is-hof (consp fn-param-entries)))
                           ;; Gate: register if any scalar-delta contribution
                           ;; OR any handle (tensor/cell) param.
                           (when (or (> n-diff-params 0)
                                     (%has-tensor-diff-param-p env))
                             (if is-hof
                                 ;; HOF path unchanged — open Q4 deferred.
                                 (let* ((fn-param-idx (car (car fn-param-entries)))
                                        (fn-param-sym (parameter-def-name (cdr (car fn-param-entries))))
                                        (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                        (clean-body  (loop for f in fn-body
                                                           unless (and (atom f) (not (symbolp f)))
                                                           collect f))
                                        (param-syms (loop for pd in env collect (parameter-def-name pd))))
                                   (%register-hof-entry name "definition" param-syms fn-param-idx fn-param-sym float-param-syms clean-body (length float-param-entries) n-return))
                                 (%register-standard-differentiable-entry name "definition" n-diff-params n-return)))))
                     (error (e)
                       (log:debug "AUTODIFF: Skipping pre-registration of ~a -- type parse error: ~a" name e))))))))

          ;; progn: recurse, passing record-info through
          ((and (consp form) (eq (car form) 'progn))
           (%pre-register-differentiable-fns (rest form) record-info))

          ;; with-template-type: walk body for def-functions using funcall scanning.
          ;; Cannot use parse-function-declarations here -- types contain T placeholder.
          ;; HOF branch: funcall detected -> register in *differentiable-hof-store*.
          ;; Non-HOF branch: register optimistically; concrete instantiation will update
          ;;   the entry with accurate counts before the backward walk runs.
          ((and (consp form) (eq (car form) 'with-template-type))
           (dolist (bform (cddr form))
             (when (and (consp bform) (eq (car bform) 'def-function))
               (let* ((name   (second bform))
                      (params (third bform))
                      (body-and-loc (cdddr bform)))
                 (multiple-value-bind (declare-forms declarations fn-body)
                     (%extract-fn-body-and-declarations body-and-loc)
                   (declare (ignore declare-forms declarations))
                   (multiple-value-bind (fn-param-idx fn-param-sym float-param-syms)
                       (%detect-hof-param-via-funcall params fn-body)
                     (cond
                       ((and fn-param-idx (not (gethash name *differentiable-functions*)))
                        (%register-hof-entry name "template via with-template-type" params fn-param-idx fn-param-sym float-param-syms fn-body (1- (length params)) 1))
                       ((not (gethash name *differentiable-functions*))
                        (let ((n-params (count-if (lambda (p) (not (string-equal (symbol-name p) "&OUT"))) params)))
                          (%register-standard-differentiable-entry name "template via with-template-type" n-params 1 :optimistic-p t)))))))))))))))

;; src/anf-transform.lisp  (BUG 096: only change -- LET matched by name)
(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list).
   Phase 1c: added opaque pass-through for load-tile-at / store-tile-at
   and their internal *-bwd / bare load-tile / store-tile variants."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       (when (and (symbolp op)
                  (macro-function op)
                  (not (member op '(when when+ unless unless+ cond cond+ if if+ return dotimes dotimes+ while set! declare progn let
                                          template-instantiation def-function def-kernel def-kernel-exact make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor as quote compiler-no-op
                                          make-cell make-vector make-matrix make-tensor))))
             (multiple-value-bind (expanded changed) (macroexpand-1 expr)
               (when changed
                     (return-from anf-normalize (anf-normalize expanded is-nested?)))))
       (cond
        ((and (symbolp op)
              (member (symbol-name op)
                      '("LOAD-TILE-AT" "STORE-TILE-AT"
                        "%LOAD-TILE-AT-BWD" "%STORE-TILE-AT-BWD"
                        "LOAD-TILE" "STORE-TILE"
                        ;; Endeavor 132 (MMA) — store-fragment / make-register-tile carry
                        ;; coord / dim LISTS that must stay opaque to ANF.
                        "STORE-FRAGMENT" "MAKE-REGISTER-TILE" "MMA-ACCUMULATE-VIA-TILE"
                        ;; Endeavour 158: PREFETCH-TILE carries a coord tuple AND a :size
                        ;; tuple, and ANF flattened BOTH into bindings, so
                        ;;     (prefetch-tile A (grid-y grid-k) :size (32 16))
                        ;; arrived at the backward walk as
                        ;;     (LET ((%ANF-T-1 (GRID-Y GRID-K)) (%ANF-T-2 (32 16))) ...)
                        ;; where %ANF-T-1 reads as a CALL to a function named GRID-Y --
                        ;; really a tile-stride index -- reporting "Function GRID-Y is not
                        ;; differentiable".  Endeavour 146 had ALREADY placed PREFETCH-TILE
                        ;; on %backward-skip-fn-p as the pure scheduling hint it is; AD
                        ;; never got to use that entry because ANF destroyed the form
                        ;; first.  This is the third blocker 142/14's skip note predicted,
                        ;; named there as "in ANF rather than AD".
                        ;;
                        ;; Safe by construction: anf-transform runs on the AD path ONLY
                        ;; (see src/macros.lisp:982, "the forward still analyses the
                        ;; original form"), so no shipped prefetch kernel's forward
                        ;; lowering can be affected by this entry.
                        "PREFETCH-TILE")
                      :test #'string=))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'set!)
          (%anf-normalize-set! expr is-nested?))
        ((member op '(if when unless))
          (%anf-normalize-if op expr is-nested?))
        ((member op '(if+ when+ unless+))
          (%anf-normalize-if+ op expr is-nested?))
        ((eq op 'cond)
          (%anf-normalize-cond expr is-nested?))
        ;; BUG 096: match LET BY NAME.  CL macros expand into CL:LET -- (or X Y) becomes
        ;; (CL:LET ((#:g X)) (IF #:g #:g Y)) -- and an EQ test against Crisp's own LET missed it, so the
        ;; binding list fell through to the call path and was lifted into a temp as if it were an
        ;; argument.  CL:LET is treated like Crisp's sequential let; CL macro expansions do not rely on
        ;; parallel binding.
        ((and (symbolp op) (string-equal (symbol-name op) "LET"))
          (%anf-normalize-let expr is-nested?))
        ((eq op 'declare)
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'return)
          (multiple-value-bind (new-args bindings) (anf-normalize-args (cdr expr))
            (let ((anf-ret `(return ,@new-args)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append bindings `((,temp ,anf-ret)))))
                  (values anf-ret bindings)))))
        ((eq op 'as)
          (let ((type-spec (cadr expr))
                (val (caddr expr)))
            (multiple-value-bind (new-val bindings) (anf-normalize val t)
              (let ((anf-as `(as ,type-spec ,new-val)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,anf-as)))))
                    (values anf-as bindings))))))
        ((eq op 'make-scratch-cell)
          (let ((type-spec (cadr expr)))
            (let ((anf-msc `(make-scratch-cell ,type-spec)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-msc))))
                  (values anf-msc nil)))))
        ((member op '(make-scratch-vector make-scratch-matrix make-scratch-tensor))
          (let ((anf-form `(,op ,@(cdr expr))))
            (if is-nested?
                (let ((temp (anf-fresh-temp)))
                  (values temp `((,temp ,anf-form))))
                (values anf-form nil))))
        ((member op '(make-cell make-vector make-matrix make-tensor))
          (let* ((source (cadr expr))
                 (rest-args (cddr expr)))
            (multiple-value-bind (new-source source-bindings)
                (anf-normalize source t)
              (let ((anf-form `(,op ,new-source ,@rest-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append source-bindings `((,temp ,anf-form)))))
                    (values anf-form source-bindings))))))
        ((member op '(quote template-instantiation compiler-no-op def-function def-kernel def-kernel-exact eval-when))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'progn)
          (let ((anf-body (mapcar #'%anf-transform (cdr expr))))
            (let ((anf-progn `(progn ,@anf-body)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-progn))))
                  (values anf-progn nil)))))
        ;; Endeavor 126 (pass 5b): with-precision is a codegen precision annotation,
        ;; transparent to the derivative STRUCTURE. For the backward/AD pipeline, ANF
        ;; it as a progn of its body (drop the region wrapper). The FORWARD kernel
        ;; keeps the region precision (its semantic-with-precision codegen is
        ;; untouched); only the backward pipeline drops it, so the backward ops use
        ;; the ambient precision — correct for the gradient value.
        ((and (symbolp op) (string-equal (symbol-name op) "WITH-PRECISION"))
          (let ((body (cddr expr)))
            (if (= (length body) 1)
                ;; Single value form (the common case): ANF it directly so the
                ;; backward walk sees the bare expression, not a progn wrapper.
                (anf-normalize (car body) is-nested?)
                ;; Multi-form body: fall back to progn semantics.
                (anf-normalize (cons 'progn body) is-nested?))))
        ((and (symbolp op) (%dotimes-family-head-p op))
          (%anf-normalize-dotimes op expr is-nested?))
        ((and (symbolp op) (string-equal (symbol-name op) "WHILE"))
          (%anf-normalize-while op expr is-nested?))
        ((and (symbolp op)
              (member (symbol-name op)
                      '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
                        "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!"
                        ;; Endeavour 175 -- see the header above this definition.
                        "ATOMIC-CAS!" "%ATOMIC-CAS-OK!" "ATOMIC-BINOP!" "ATOMIC-OP!")
                      :test #'string=))
          (%anf-normalize-atomic op expr is-nested?))
        (t
          (let ((args (cdr expr)))
            (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
              (let ((call `(,op ,@anf-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,call)))))
                    (values call bindings)))))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))

;; src/anf-transform.lisp  (BUG 096: only change -- LET matched by name)
(defun flatten-anf-body (anf-body)
  "Flattens an ANF body into a sequential list of bindings and side-effects.
Returns a list of elements formatted as either (var expr), (var0 var1 expr) for
multi-value bindings, or just expr (for side-effects).
Accepts bindings of length >= 2 (fix: was = 2, dropping multi-value bindings)."
  (let ((flat nil))
    (labels ((walk (expr)
               (cond
                ((and (consp expr) (symbolp (car expr)) (string-equal (symbol-name (car expr)) "LET")) ; BUG 096: by name
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

;; src/codegen.lisp  (176: only change -- warn on an infinite float constant under :fast precision)
(defun %generate-scalar-literal-ir (builder value llvm-type crisp-type)
  "Helper: Generates IR for scalar (int/float) literals."
  (cond
   ;; Integer types
   ((member (crisp-type-category crisp-type) '(:signed-int :unsigned-int))
     (if (zerop value)
         (llvm-const-null llvm-type)
         (let ((val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) value) nil)))
           (if (= (crisp-type-size crisp-type) 64)
               val-i64
               (llvm-build-trunc builder val-i64 llvm-type "int_trunc")))))

   ;; Float types
   ((eq (crisp-type-category crisp-type) :float)
     (progn
       ;; 176: an INFINITE float constant under :fast precision is undefined (LLVM's ninf) -- warn rather
       ;; than refuse, because precision can be forced from the command line.  Checked HERE, at codegen,
       ;; because a (with-precision (fast) ...) region scopes *math-precision* over codegen only.
       (when (and (floatp value) (sb-ext:float-infinity-p value) (eq *math-precision* :fast))
         (log:warn "176: infinite float constant under :fast precision")
         (format *error-output* "WARNING: (type-infinity ...) yields an infinity under :fast precision, where the compiler may assume no value is infinite -- the result is undefined.  Use (type-max T) / (type-min T), or an :ieee region.~%"))
       (llvm-const-real llvm-type (coerce value 'double-float))))

   ;; Void
   ((eq (crisp-type-category crisp-type) :void)
     nil)

   (t
     (error "Codegen for literal of unknown type category: ~a" (crisp-type-name crisp-type)))))

;;;; ===========================================================================
;;;; Endeavour 176 Phase 1 -- (grid-reduce! fn var identity return-cell &key strategy message ...).
;;;;
;;;; The easy form: Phase 1 is a reduce-workgroup, Phase 2 is picked by :strategy, every scratch buffer is
;;;; implicit.  A MACRO that rewrites into the matching ANALYZED construct -- grid-reduce-atomic!,
;;;; grid-reduce-cas! or grid-reduce-last-man! -- never into a lowering, so:
;;;;   * the ANF transform and the backward walk expand it and meet a construct with a registered VJP --
;;;;     AD through grid-reduce! needs nothing of its own;
;;;;   * the Pass-1 scan expands it (the default scan-operator macroexpands) and meets the implicit-scratch
;;;;     scanners, so its scratch reaches the kernel signature.
;;;; The second-stage strategy is deliberately absent: it needs a second kernel launch, which a single
;;;; call cannot arrange (decided 2026-09-28; grid-reduce-second-stage! remains the explicit tool).
;;;;
;;;; RETURN-CELL may be a cell or a length-1 vector: the underlying constructs write (~ out 0), which Crisp
;;;; accepts for a cell (verified on BMG with grid-reduce-atomic! and -last-man!, 2026-10-01).
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new)
(defparameter *176-grid-reduce-strategies*
  '((:atomic            "GRID-REDUCE-ATOMIC!"   (:local-scratch-vec :message))
    (:cas               "GRID-REDUCE-CAS!"      (:local-scratch-vec :message))
    (:last-man-standing "GRID-REDUCE-LAST-MAN!" (:local-scratch-vec :global-scratch-vec :atomic-counter
                                                 :election-flag-cell :message)))
  "Endeavour 176.  grid-reduce!'s strategies: the :strategy keyword, the construct it becomes, and the
   keys that construct accepts (:strategy itself is consumed by grid-reduce!).")

;; src/analysis/ops.lisp  (new)
(defun %grid-reduce!-expand (form)
  "Endeavour 176.  The expansion of (grid-reduce! FN VAR IDENTITY RETURN-CELL &key STRATEGY ...): the same
   call to the construct STRATEGY names, minus :strategy.  Refuses -- before anything is analyzed -- a
   missing argument, a strategy that is not a literal keyword, an unknown strategy, and a key the chosen
   construct does not take.  The target symbol is interned in the CALL's package, because the reductions
   are distinct symbols in :crisp-language and :crisp.compiler (each registered in both)."
  (let ((op (first form)))
    (unless (>= (length form) 5)
      (error 'crisp-compiler-error
             :message (format nil "grid-reduce!: expected (grid-reduce! fn var identity return-cell &key strategy message), got ~s." form)
             :source-location nil))
    (destructuring-bind (fn var identity out &rest keys) (rest form)
      (unless (evenp (length keys))
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce!: the keyword arguments ~s are not key/value pairs." keys)
               :source-location nil))
      (let* ((strategy-given (loop for (k v) on keys by #'cddr thereis (and (eq k :strategy) (list v))))
             (strategy (if strategy-given (first strategy-given) :last-man-standing))
             (entry nil))
        (unless (keywordp strategy)
          (error 'crisp-compiler-error
                 :message (format nil "grid-reduce!: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy)
                 :source-location nil))
        (setf entry (assoc strategy *176-grid-reduce-strategies*))
        (unless entry
          (error 'crisp-compiler-error
                 :message (format nil "grid-reduce!: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  For a two-kernel reduction use grid-reduce-second-stage! in the second kernel." strategy)
                 :source-location nil))
        (let ((pass-through '()))
          (loop for (k v) on keys by #'cddr
                unless (eq k :strategy)
                  do (unless (member k (third entry))
                       (error 'crisp-compiler-error
                              :message (format nil "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy (third entry))
                              :source-location nil))
                     (push v pass-through) (push k pass-through))
          (let ((target (intern (second entry) (or (and (symbolp op) (symbol-package op))
                                                   (find-package :crisp-language)))))
            (log:debug "176: ~s -> ~s" form (list* target fn var identity out pass-through))
            `(,target ,fn ,var ,identity ,out ,@pass-through)))))))

;; src/analysis/ops.lisp  (new) -- defined on the :crisp.compiler symbol, and installed on the
;; :crisp-language one, which is what user source reads.  (At fold time: export GRID-REDUCE! from
;; :crisp.compiler and import it into :crisp-language in src/package.lisp, as the WHEN-THREAD-IN-*
;; macros are, and drop the copy below -- an overlay cannot change package exports.)
(defmacro grid-reduce! (&whole form &rest args)
  "(grid-reduce! fn var identity return-cell &key strategy message ...): a grid-wide reduction of VAR with
   binop FN and IDENTITY into RETURN-CELL.  Phase 1 is reduce-workgroup; Phase 2 is :strategy -- :atomic,
   :cas or :last-man-standing (the default).  Scratch is implicit unless passed.  See %grid-reduce!-expand."
  (declare (ignore args))
  (%grid-reduce!-expand form))

(let ((lang-sym (intern "GRID-REDUCE!" (find-package :crisp-language))))
  (unless (eq lang-sym 'grid-reduce!)
    (setf (macro-function lang-sym) (macro-function 'grid-reduce!))))
