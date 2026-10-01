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

;;;; ===========================================================================
;;;; Endeavour 176 Phase 2a -- the INDEPENDENT multi-variable form, by per-clause expansion.
;;;;
;;;;   (reduce-warp      ((fn var id) ...) &optional active-threads)
;;;;   (reduce-workgroup ((fn var id &key return-vec local-scratch-vec) ...) &key message)
;;;;   (grid-reduce!     ((fn var id return-cell &key local-scratch-vec global-scratch-vec) ...)
;;;;                     &key strategy message)
;;;;
;;;; Shape decides the form (reductions-excerpt.md): a clause LIST first is independent; #'f then a
;;;; clause list is dependent (Phase 3, refused for now); #'f then a variable is the single form.
;;;; Phase 2a expands an independent call into a PROGN of single-variable calls, one per clause --
;;;; correct, and AD for free, since every piece is an analyzed form with its own VJP.  The SAME
;;;; expansion is applied in every pass that walks source: the analyzers, the Pass-1 scanner (so each
;;;; clause's implicit scratch is registered), and the ANF transform (so the backward walk only ever
;;;; meets single forms -- the VJPs read (second form) as the function).  grid-reduce! is a macro, so it
;;;; needs it only in its own expander.  Fusing the clauses (one sweep / one barrier sequence / one
;;;; election) is Phase 2b, checked by independent-fusion.unit.lisp.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new)
(defun %function-form-p (x)
  "T when X is #'f, i.e. (function f)."
  (and (consp x) (symbolp (car x)) (string-equal (symbol-name (car x)) "FUNCTION")))

;; src/analysis/ops.lisp  (new)
(defun %reduction-call-shape (form)
  "Endeavour 176.  :independent when FORM's first argument is a list of clauses; :dependent when it is
   #'f followed by a list of clauses; :single otherwise.  Decided by shape alone, so it works in every
   pass, before anything is analyzed."
  (let ((a1 (second form)) (a2 (third form)))
    (cond ((and (consp a1) (consp (car a1))) :independent)
          ((and (%function-form-p a1) (consp a2) (consp (car a2))) :dependent)
          (t :single))))

;; src/analysis/ops.lisp  (new)
(defparameter *176-independent-forms*
  ;; name           min-clause-length  clause keys                               call keys
  '(("REDUCE-WARP"      3 ()                                       ())
    ("REDUCE-WORKGROUP" 3 (:return-vec :local-scratch-vec)          (:message))
    ("GRID-REDUCE!"     4 (:local-scratch-vec :global-scratch-vec)  (:strategy :message)))
  "Endeavour 176.  For each construct with an independent form: the clause's positional length, the keys a
   clause may carry (per-variable resources), and the keys the call may carry (per-reduction).")

;; src/analysis/ops.lisp  (new)
(defun %independent-reduction-form-p (form)
  "T when FORM is an independent reduce-warp / reduce-workgroup / grid-reduce! call."
  (and (consp form) (symbolp (car form))
       (assoc (symbol-name (car form)) *176-independent-forms* :test #'string-equal)
       (eq (%reduction-call-shape form) :independent)))

;; src/analysis/ops.lisp  (new)
(defun %independent-reduction-expand (form)
  "Endeavour 176 Phase 2a.  An independent reduction FORM as a PROGN of single-variable calls of the same
   operator (same symbol, so same package), one per clause.  Validates first: each clause's shape and
   keys, the call's keys, and that no variable appears in two clauses.  The per-reduction arguments --
   reduce-warp's ACTIVE-THREADS, the call's :strategy / :message -- go to every single call."
  (let* ((op (car form))
         (name (symbol-name op))
         (spec (assoc name *176-independent-forms* :test #'string-equal))
         (min-len (second spec))
         (clause-keys (third spec))
         (call-keys (fourth spec))
         (op-name (string-downcase name))
         (clauses (second form))
         (rest (cddr form))
         (seen '()))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      ;; the call's own arguments after the clause list
      (if (string-equal name "REDUCE-WARP")
          (when (> (length rest) 1)
            (fail "~a: an independent call is (reduce-warp (clause ...) &optional active-threads); got extra arguments ~s." op-name (rest rest)))
          (progn
            (unless (evenp (length rest))
              (fail "~a: the call's keyword arguments ~s are not key/value pairs." op-name rest))
            (loop for (k nil) on rest by #'cddr
                  unless (member k call-keys)
                    do (fail "~a: ~s is not a key of an independent call, which takes ~{~s~^, ~}.~@[  (A shared :atomic-counter / :election-flag-cell comes with the fused lowering.)~]"
                             op-name k call-keys (member k '(:atomic-counter :election-flag-cell))))))
      (let ((singles
              (loop for clause in clauses
                    collect
                    (progn
                      (unless (and (consp clause) (>= (length clause) min-len)
                                   (evenp (- (length clause) min-len))
                                   (%function-form-p (first clause))
                                   (symbolp (second clause)) (second clause))
                        (fail "~a: malformed clause ~s.  An independent clause is (fn var identity~a~@[ &key ~{~(~s~)~^ ~}~])."
                              op-name clause (if (= min-len 4) " return-cell" "") clause-keys))
                      (let ((var (second clause)))
                        (when (member var seen)
                          (fail "~a: the variable ~a appears in more than one clause.  Each clause overwrites its variable with its own result, so a variable may be reduced by only one clause." op-name var))
                        (push var seen))
                      (loop for (k nil) on (nthcdr min-len clause) by #'cddr
                            unless (member k clause-keys)
                              do (fail "~a: unknown clause key ~s in ~s.  A clause takes ~:[no keys~;~:*~{~s~^, ~}~]." op-name k clause clause-keys))
                      `(,op ,@clause ,@rest)))))
        (log:debug "176: independent ~a -> ~d single calls" op-name (length singles))
        `(progn ,@singles)))))

;; src/analysis/ops.lisp  (new)
(defun %refuse-dependent-form (form)
  "Endeavour 176: the dependent form is Phase 3.  Refuse it clearly rather than mis-parse it."
  (error 'crisp-compiler-error
         :message (format nil "~(~a~): the dependent form -- a combining function followed by a list of clauses -- is not implemented yet (endeavour 176 Phase 3)."
                          (car form))
         :source-location nil))

;; src/analysis/ops.lisp  (supersedes the stage-B copy: a key given as NIL counts as MISSING -- the
;; reduce-workgroup VJP emits :local-scratch-vec NIL when the forward's scratch was implicit)
(defun %implicit-scratch-missing-keys (expr)
  "The scratch keys of reduction form EXPR that Crisp can supply and the caller left out (or passed as
   NIL), in table order; NIL when EXPR is not such a reduction or supplies them all.  Walks the keyword
   tail as pairs rather than with GETF, so a malformed tail is left for the expander to report."
  (let ((spec (%implicit-scratch-spec (car expr))))
    (when spec
      (let ((tail (nthcdr (second spec) expr)))
        (remove-if (lambda (key)
                     (loop for (k v) on tail by #'cddr thereis (and (eq k key) v)))
                   (third spec))))))

;; src/analysis/ops.lisp  (supersedes: drops a NIL-valued scratch key before supplying the implicit one)
(defun %implicit-scratch-form (expr elem-type)
  "Endeavour 176.  Reduction form EXPR with its missing scratch supplied: a LET binding each missing
   buffer, around EXPR with the corresponding keys appended (any NIL-valued copy of such a key removed).
   Used by BOTH the Pass-1 scan-operator methods and the analyzers, so the two passes see the same form
   (and the same scratch order)."
  (let* ((spec (%implicit-scratch-spec (car expr)))
         (var (third expr))
         (missing (%implicit-scratch-missing-keys expr))
         (names (mapcar (lambda (k) (%implicit-scratch-binding-name var k)) missing))
         (tail (loop for (k v) on (nthcdr (second spec) expr) by #'cddr
                     unless (and (member k missing) (null v)) append (list k v))))
    `(let ,(mapcar (lambda (name key) (list name (%implicit-scratch-alloc-form key elem-type))) names missing)
       (,@(subseq expr 0 (second spec))
        ,@tail
        ,@(loop for key in missing for name in names append (list key name))))))

;; src/analysis/ops.lisp  (supersedes: an independent call is scanned as its per-clause expansion)
(defun %scan-reduction-maybe-implicit (op args next)
  "Pass 1.  An independent call is scanned as its per-clause expansion.  Otherwise scan the
   implicit-scratch form of reduction (OP . ARGS) when Crisp will supply its scratch, or call NEXT (the
   default scan).  An identity whose type is not visible is scanned as-is and refused by the analyzer."
  (let ((expr (cons op args)))
    (if (%independent-reduction-form-p expr)
        (scan-form (ignore-errors (%independent-reduction-expand expr)))
        (let* ((missing (%implicit-scratch-missing-keys expr))
               (elem-type (and missing (symbolp (third expr)) (%identity-scan-type (fourth expr)))))
          (if elem-type
              (progn
                (log:debug "176: Pass 1 implicit scratch ~s for ~s (element type ~s)" missing op elem-type)
                (scan-form (%implicit-scratch-form expr elem-type)))
              (funcall next))))))

;; src/analysis/ops.lisp  (new) -- REDUCE-WARP has no scratch, but its independent form must be scanned
;; as its expansion too (a clause list read as a call would be scanned as nonsense).
(macrolet ((def-warp-scanners ()
             `(progn
                ,@(loop for pkg in '(:crisp.compiler :crisp-language)
                        collect `(defmethod scan-operator ((op (eql (intern "REDUCE-WARP" (find-package ,pkg)))) args)
                                   (let ((expr (cons op args)))
                                     (if (%independent-reduction-form-p expr)
                                         (scan-form (ignore-errors (%independent-reduction-expand expr)))
                                         (call-next-method))))))))
  (def-warp-scanners))

;; src/analysis/ops.lisp  (supersedes: shape dispatch)
(defun %analyze-reduce-warp (expr env context location)
  "Analyzer for reduce-warp -- expands and delegates.  176: an independent call is analyzed as its
   per-clause expansion; the dependent form is refused until Phase 3."
  (case (%reduction-call-shape expr)
    (:independent (analyze-expression (%independent-reduction-expand expr) env context location))
    (:dependent   (%refuse-dependent-form expr))
    (t            (analyze-expression (%reduce-warp-expand expr) env context location))))

;; src/analysis/ops.lisp  (supersedes: shape dispatch)
(defun %analyze-reduction-maybe-implicit (expr env context location expander)
  "Endeavour 176.  Analyze reduction EXPR: an independent call as its per-clause expansion; the dependent
   form is refused until Phase 3; otherwise supply its scratch when the caller left it out, else analyze
   (EXPANDER EXPR) exactly as before."
  (case (%reduction-call-shape expr)
    (:independent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%independent-reduction-expand expr) env context location)))
    (:dependent
     (%refuse-dependent-form expr)))
  (let ((missing (%implicit-scratch-missing-keys expr))
        (var (third expr)))
    (if (or (null missing) (not (symbolp var)))
        (analyze-expression (funcall expander expr) env context location)
        (let* ((op-name (string-downcase (symbol-name (car expr))))
               (identity (fourth expr))
               (elem-type (%identity-scan-type identity)))
          (unless elem-type
            (error 'crisp-compiler-error
                   :message (format nil "~a: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass ~{~s~^ ~} yourself."
                                    op-name identity missing)
                   :source-location location))
          (%check-identity-matches-variable op-name var identity elem-type env context location)
          (log:debug "176: implicit scratch ~s for ~a over ~s (element type ~s)" missing op-name var elem-type)
          (analyze-expression (%implicit-scratch-form expr elem-type) env context location)))))

;; src/analysis/ops.lisp  (supersedes the Phase 1 copy: shape dispatch before the single-form checks)
(defun %grid-reduce!-expand (form)
  "Endeavour 176.  The expansion of grid-reduce!.  An INDEPENDENT call (a clause list) becomes a PROGN of
   single grid-reduce! calls (%independent-reduction-expand); the dependent form is refused until Phase 3.
   A single call (grid-reduce! FN VAR IDENTITY RETURN-CELL &key STRATEGY ...) becomes the construct STRATEGY
   names, minus :strategy -- refusing a missing argument, a non-literal or unknown strategy, and a key the
   chosen construct does not take.  The target is interned in the CALL's package, because the reductions
   are distinct symbols in :crisp-language and :crisp.compiler (each registered in both)."
  (case (%reduction-call-shape form)
    (:independent (return-from %grid-reduce!-expand (%independent-reduction-expand form)))
    (:dependent   (%refuse-dependent-form form)))
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

;; src/anf-transform.lisp  (176 Phase 2a, supersedes the BUG 096 copy above: independent reductions split first)
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
       ;; 176: an INDEPENDENT reduce-warp / reduce-workgroup (a clause list) is split into single-variable
       ;; calls first, so the backward walk only ever meets the single form its VJPs expect.  (grid-reduce!
       ;; is a macro: the block above already expanded it.)
       (when (%independent-reduction-form-p expr)
         (return-from anf-normalize (anf-normalize (%independent-reduction-expand expr) is-nested?)))
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

;;;; ===========================================================================
;;;; Endeavour 176 Phase 2b -- FUSED lowering of the independent form.
;;;;
;;;; The FORWARD (analyzers + Pass-1 scanner, which must see the same form so the scratch counter
;;;; replays) lowers an independent call with its work done ONCE for all clauses: one shuffle sweep,
;;;; one workgroup barrier sequence, and -- for :last-man-standing -- ONE election (one ticket per
;;;; workgroup, one counter, one flag).  The AD path (ANF) keeps the Phase-2a per-clause SPLIT, so the
;;;; backward walk uses the existing per-variable VJPs: independent clauses do not interact, so the
;;;; split computes the same values and its adjoints are exact.  No new VJP, no new place-writing
;;;; operator.  Checked by independent-fusion.unit.lisp.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (supersedes: an independent grid-reduce! call may carry the ONE shared
;; :atomic-counter / :election-flag-cell -- last-man only, checked in %fused-grid-reduce-form)
(defparameter *176-independent-forms*
  '(("REDUCE-WARP"      3 ()                                       ())
    ("REDUCE-WORKGROUP" 3 (:return-vec :local-scratch-vec)          (:message))
    ("GRID-REDUCE!"     4 (:local-scratch-vec :global-scratch-vec)
                          (:strategy :message :atomic-counter :election-flag-cell)))
  "Endeavour 176.  For each construct with an independent form: the clause's positional length, the keys a
   clause may carry (per-variable resources), and the keys the call may carry (per-reduction).")

;; src/analysis/ops.lisp  (new)
(defun %clause-key (clause min-len key)
  "The value of KEY among CLAUSE's keywords (after its MIN-LEN positional elements), or NIL."
  (loop for (k v) on (nthcdr min-len clause) by #'cddr when (eq k key) return v))

;; src/analysis/ops.lisp  (new)
(defun %fused-reduce-warp-form (expr)
  "Endeavour 176 Phase 2b.  An independent reduce-warp as ONE butterfly: per iteration, every clause's
   variable is combined with its shuffle partner.  Same steps as %reduce-warp-expand, k variables at once;
   ACTIVE-THREADS applies to every clause (its lanes past the count take that clause's identity)."
  (%independent-reduction-expand expr)            ; validation only
  (let* ((clauses (second expr))
         (active-threads (third expr))
         (s (gensym "RW-S")))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (loop for (nil var identity) in clauses
                 collect `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         ,@(loop for (fn var) in clauses
                 collect `(set! ,var ,(%175-apply-binop fn `(shuffle-xor ,var ,s) var))))
       (compiler-no-op))))

;; src/analysis/ops.lisp  (new)
(defun %fused-reduce-workgroup-form (expr &optional env context location)
  "Endeavour 176 Phase 2b.  An independent reduce-workgroup as ONE sweep: a fused warp reduction of every
   clause, one barrier, one halving loop that combines every clause's per-warp partials, one read-back,
   and one leader block for every :return-vec -- %reduce-workgroup-expand's steps, k variables at once.
   A clause without :local-scratch-vec gets implicit scratch typed from ITS identity (a LET around the
   whole form, deterministic names, so the Pass-1 scan and the analyzer see the same buffers).  With ENV
   (the analyzer) each implicitly-scratched clause's identity is also checked against its variable."
  (%independent-reduction-expand expr)            ; validation only
  (let* ((op (car expr))
         (clauses (second expr))
         (implicit '())
         (scratch
           (loop for clause in clauses
                 collect (destructuring-bind (fn var identity &rest keys) clause
                           (declare (ignore fn keys))
                           (or (%clause-key clause 3 :local-scratch-vec)
                               (let ((elem-type (%identity-scan-type identity)))
                                 (unless elem-type
                                   (error 'crisp-compiler-error
                                          :message (format nil "reduce-workgroup: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass :local-scratch-vec in that clause yourself." identity)
                                          :source-location location))
                                 (when env
                                   (%check-identity-matches-variable "reduce-workgroup" var identity elem-type
                                                                     env context location))
                                 (let ((name (%implicit-scratch-binding-name var :local-scratch-vec)))
                                   (push (list name (%implicit-scratch-alloc-form :local-scratch-vec elem-type))
                                         implicit)
                                   name))))))
         (return-vecs (loop for clause in clauses collect (%clause-key clause 3 :return-vec)))
         (s (gensym "RWG-S")) (nw (gensym "RWG-NW")) (lid (gensym "RWG-LID"))
         (warp-op (intern "REDUCE-WARP" (or (symbol-package op) (find-package :crisp-language))))
         (body
           `(progn
              (,warp-op ,(loop for (fn var identity) in clauses collect (list fn var identity)))
              (when-thread-in-warp-is 0
                ,@(loop for (nil var) in clauses for sc in scratch
                        collect `(set! (~ ,sc (to-int (warp-id))) ,var)))
              (sync-workgroup)
              (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
                    (,lid (to-int (get-local-linear-id))))
                (dec-times-by-half+ (,s (/ ,nw 2ul))
                  (when (< ,lid (to-int ,s))
                    ,@(loop for (fn) in clauses for sc in scratch
                            collect `(set! (~ ,sc ,lid)
                                           ,(%175-apply-binop fn `(~ ,sc ,lid) `(~ ,sc (+ ,lid (to-int ,s)))))))
                  (sync-workgroup))
                ,@(loop for (nil var) in clauses for sc in scratch
                        collect `(set! ,var (~ ,sc 0))))
              ,@(when (some #'identity return-vecs)
                  `((when-thread-in-group-is 0
                      ,@(loop for (nil var) in clauses for rv in return-vecs
                              when rv collect `(set! (~ ,rv (to-int (get-workgroup-id 0))) ,var)))))
              (compiler-no-op))))
    (if implicit `(let ,(nreverse implicit) ,body) body)))

;; src/analysis/ops.lisp  (new)
(defun %analyze-check-reduction-identity (expr env context location)
  "Analyzer for (%check-reduction-identity OP-NAME VAR IDENTITY TYPE): the identity-vs-variable type check
   for a fused grid-reduce!, whose macro expansion has no environment to do it in.  Emits nothing."
  (destructuring-bind (op-name var identity type) (rest expr)
    (%check-identity-matches-variable op-name var identity type env context location))
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

;; src/analysis/ops.lisp  (new)
(defun %fused-grid-reduce-form (form)
  "Endeavour 176 Phase 2b.  An independent grid-reduce!, lowered with its work done once for all clauses.
   Phase 1 is ONE independent reduce-workgroup (itself fused).  Phase 2 by :strategy --
     :atomic / :cas          one leader block applying each clause's atomic / CAS to its return cell;
     :last-man-standing      every partial written, ONE ticket from ONE counter, ONE election flag, and
                             the last workgroup's ONE fused sweep writing every return cell.
   Scratch a clause or the call leaves out is implicit (typed from each identity; the shared counter and
   flag are uint and named after the first clause's variable).  Refuses an unknown strategy, a key the
   strategy does not use, and (for :atomic) an operator with no hardware atomic -- each with the message
   the single-variable form gives."
  (%independent-reduction-expand form)            ; clause shape, clause keys, duplicates, call keys
  (let* ((op (car form))
         (pkg (or (symbol-package op) (find-package :crisp-language)))
         (clauses (second form))
         (rest (cddr form))
         (strategy-given (loop for (k v) on rest by #'cddr thereis (and (eq k :strategy) (list v))))
         (strategy (if strategy-given (first strategy-given) :last-man-standing))
         (rwg (intern "REDUCE-WORKGROUP" pkg)))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (unless (keywordp strategy)
        (fail "grid-reduce!: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy))
      (unless (member strategy '(:atomic :cas :last-man-standing))
        (fail "grid-reduce!: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  For a two-kernel reduction use grid-reduce-second-stage! in the second kernel." strategy))
      ;; keys the strategy does not use -- call level, then clause level
      (let ((call-ok (if (eq strategy :last-man-standing)
                         '(:strategy :message :atomic-counter :election-flag-cell)
                         '(:strategy :message)))
            (clause-ok (if (eq strategy :last-man-standing)
                           '(:local-scratch-vec :global-scratch-vec)
                           '(:local-scratch-vec))))
        (loop for (k nil) on rest by #'cddr
              unless (member k call-ok)
                do (fail "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy call-ok))
        (dolist (clause clauses)
          (loop for (k nil) on (nthcdr 4 clause) by #'cddr
                unless (member k clause-ok)
                  do (fail "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~} per clause." k strategy clause-ok))))
      (ecase strategy
        ((:atomic :cas)
         (when (eq strategy :atomic)
           (dolist (clause clauses)
             (unless (%grid-atomic-op-name (first clause))
               (fail "grid-reduce-atomic!: ~s has no native hardware atomic, so there is no instruction for phase 2 to emit.  Only +, min and max qualify -- the hardware provides exactly those.  For an arbitrary commutative operator use grid-reduce-cas! (a CAS loop; no extra memory, high contention) or grid-reduce-last-man! (a global scratch buffer; no contention)." (first clause)))))
         `(progn
            (,rwg ,(loop for clause in clauses
                         collect (destructuring-bind (fn var identity out &rest keys) clause
                                   (declare (ignore out))
                                   `(,fn ,var ,identity ,@keys))))
            (when-thread-in-group-is 0
              ,@(loop for (fn var nil out) in clauses
                      collect (if (eq strategy :atomic)
                                  `(,(intern (%grid-atomic-op-name fn) (find-package :crisp.compiler)) (~ ,out 0) ,var)
                                  `(atomic-binop! (~ ,out 0) ,fn ,var))))
            (compiler-no-op)))
        (:last-man-standing
         (let ((lets '()) (checks '())
               (v1 (second (first clauses))))
           (labels ((supply (given var identity key)
                      ;; GIVEN scratch, or an implicit LET binding with a deterministic name, typed from
                      ;; IDENTITY (the counter and flag are always uint)
                      (or given
                          (let ((elem-type (if (member key '(:atomic-counter :election-flag-cell))
                                               'uint
                                               (%identity-scan-type identity))))
                            (unless elem-type
                              (fail "grid-reduce!: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass that clause's scratch yourself." identity))
                            (let ((name (%implicit-scratch-binding-name var key)))
                              (push (list name (%implicit-scratch-alloc-form key elem-type)) lets)
                              (unless (member key '(:atomic-counter :election-flag-cell))
                                (pushnew `(%check-reduction-identity "grid-reduce!" ,var ,identity ,elem-type)
                                         checks :test #'equal))
                              name)))))
             (let* ((svs (loop for c in clauses
                               collect (supply (%clause-key c 4 :local-scratch-vec) (second c) (third c) :local-scratch-vec)))
                    (gvs (loop for c in clauses
                               collect (supply (%clause-key c 4 :global-scratch-vec) (second c) (third c) :global-scratch-vec)))
                    (ctr (supply (getf rest :atomic-counter) v1 nil :atomic-counter))
                    (flag (supply (getf rest :election-flag-cell) v1 nil :election-flag-cell))
                    (lid (gensym "LM-LID"))
                    (ng (gensym "LM-NG"))
                    (vals (loop repeat (length clauses) collect (gensym "LM-VAL")))
                    (body
                      `(progn
                         ,@(reverse checks)
                         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                                       "grid-reduce!: the number of workgroups exceeds local_work_size, so the last-man final sweep cannot cover every partial in one pass.")
                         ;; Phase 1 -- ONE fused workgroup reduction of every clause
                         (,rwg ,(loop for c in clauses for sv in svs
                                      collect `(,(first c) ,(second c) ,(third c) :local-scratch-vec ,sv)))
                         ;; every partial written, then ONE ticket, ONE election
                         (when-thread-in-group-is 0
                           ,@(loop for c in clauses for gv in gvs
                                   collect `(set! (~ ,gv (to-int (get-workgroup-id 0))) ,(second c))))
                         (mem-fence)
                         (when-thread-in-group-is 0
                           (set! (~ ,flag)
                                 (if (= (atomic-add! (~ ,ctr) 1u)
                                        (- (to-uint (get-num-groups 0)) 1u))
                                     1u 0u)))
                         (sync-workgroup)
                         ;; the LAST workgroup sweeps every clause's partials in ONE fused reduction
                         (when+ (= (~ ,flag) 1u)
                           (let ((,lid (to-int (get-local-linear-id)))
                                 (,ng  (to-int (get-num-groups 0))))
                             (let ,(loop for c in clauses for gv in gvs for val in vals
                                         collect `(,val (if (< ,lid ,ng) (~ ,gv ,lid) ,(third c))))
                               (,rwg ,(loop for c in clauses for sv in svs for val in vals
                                            collect `(,(first c) ,val ,(third c) :local-scratch-vec ,sv)))
                               (when-thread-in-group-is 0
                                 ,@(loop for c in clauses for val in vals
                                         collect `(set! (~ ,(fourth c) 0) ,val))))))
                         (compiler-no-op))))
               (if lets `(let ,(nreverse lets) ,body) body)))))))))

;; src/analysis/ops.lisp  (new)
(defun %independent-reduction-split-for-ad (form)
  "Endeavour 176 Phase 2b.  The AD path's view of an independent call: the Phase-2a per-clause SPLIT, so the
   backward walk meets only single forms with their own VJPs.  A shared :atomic-counter /
   :election-flag-cell is DROPPED here -- the split runs one election per clause, and elections must not
   share a counter; each single then gets its own implicit one."
  (let ((rest (loop for (k v) on (cddr form) by #'cddr
                    unless (member k '(:atomic-counter :election-flag-cell)) append (list k v))))
    (%independent-reduction-expand (list* (car form) (second form)
                                          (if (string-equal (symbol-name (car form)) "REDUCE-WARP")
                                              (cddr form)
                                              rest)))))

;; src/analysis/ops.lisp  (supersedes the 2a copy: an independent call is scanned as its FUSED form --
;; the same form the analyzer sees, so the scratch counter replays)
(defun %scan-reduction-maybe-implicit (op args next)
  "Pass 1.  An independent reduce-workgroup is scanned as its fused form (%fused-reduce-workgroup-form).
   Otherwise scan the implicit-scratch form of reduction (OP . ARGS) when Crisp will supply its scratch, or
   call NEXT (the default scan).  An identity whose type is not visible is scanned as-is and refused by the
   analyzer."
  (let ((expr (cons op args)))
    (if (%independent-reduction-form-p expr)
        (scan-form (ignore-errors (%fused-reduce-workgroup-form expr)))
        (let* ((missing (%implicit-scratch-missing-keys expr))
               (elem-type (and missing (symbolp (third expr)) (%identity-scan-type (fourth expr)))))
          (if elem-type
              (progn
                (log:debug "176: Pass 1 implicit scratch ~s for ~s (element type ~s)" missing op elem-type)
                (scan-form (%implicit-scratch-form expr elem-type)))
              (funcall next))))))

;; src/analysis/ops.lisp  (supersedes the 2a copy: scanned as the fused form)
(macrolet ((def-warp-scanners ()
             `(progn
                ,@(loop for pkg in '(:crisp.compiler :crisp-language)
                        collect `(defmethod scan-operator ((op (eql (intern "REDUCE-WARP" (find-package ,pkg)))) args)
                                   (let ((expr (cons op args)))
                                     (if (%independent-reduction-form-p expr)
                                         (scan-form (ignore-errors (%fused-reduce-warp-form expr)))
                                         (call-next-method))))))))
  (def-warp-scanners))

;; src/analysis/ops.lisp  (supersedes the 2a copy: independent -> FUSED)
(defun %analyze-reduce-warp (expr env context location)
  "Analyzer for reduce-warp -- expands and delegates.  176: an independent call is lowered FUSED (one
   butterfly for every clause, %fused-reduce-warp-form); the dependent form is refused until Phase 3."
  (case (%reduction-call-shape expr)
    (:independent (analyze-expression (%fused-reduce-warp-form expr) env context location))
    (:dependent   (%refuse-dependent-form expr))
    (t            (analyze-expression (%reduce-warp-expand expr) env context location))))

;; src/analysis/ops.lisp  (supersedes the 2a copy: independent -> FUSED)
(defun %analyze-reduction-maybe-implicit (expr env context location expander)
  "Endeavour 176.  Analyze reduction EXPR: an independent reduce-workgroup FUSED
   (%fused-reduce-workgroup-form, with its identity checks); the dependent form is refused until Phase 3;
   otherwise supply its scratch when the caller left it out, else analyze (EXPANDER EXPR) as before."
  (case (%reduction-call-shape expr)
    (:independent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%fused-reduce-workgroup-form expr env context location) env context location)))
    (:dependent
     (%refuse-dependent-form expr)))
  (let ((missing (%implicit-scratch-missing-keys expr))
        (var (third expr)))
    (if (or (null missing) (not (symbolp var)))
        (analyze-expression (funcall expander expr) env context location)
        (let* ((op-name (string-downcase (symbol-name (car expr))))
               (identity (fourth expr))
               (elem-type (%identity-scan-type identity)))
          (unless elem-type
            (error 'crisp-compiler-error
                   :message (format nil "~a: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass ~{~s~^ ~} yourself."
                                    op-name identity missing)
                   :source-location location))
          (%check-identity-matches-variable op-name var identity elem-type env context location)
          (log:debug "176: implicit scratch ~s for ~a over ~s (element type ~s)" missing op-name var elem-type)
          (analyze-expression (%implicit-scratch-form expr elem-type) env context location)))))

;; src/analysis/ops.lisp  (176 Phase 2b, supersedes: independent -> FUSED)
(defun %grid-reduce!-expand (form)
  "Endeavour 176.  The expansion of grid-reduce!.  An INDEPENDENT call (a clause list) becomes a PROGN of
   single grid-reduce! calls (%independent-reduction-expand); the dependent form is refused until Phase 3.
   A single call (grid-reduce! FN VAR IDENTITY RETURN-CELL &key STRATEGY ...) becomes the construct STRATEGY
   names, minus :strategy -- refusing a missing argument, a non-literal or unknown strategy, and a key the
   chosen construct does not take.  The target is interned in the CALL's package, because the reductions
   are distinct symbols in :crisp-language and :crisp.compiler (each registered in both)."
  (case (%reduction-call-shape form)
    (:independent (return-from %grid-reduce!-expand (%fused-grid-reduce-form form)))      ; 176 Phase 2b
    (:dependent   (%refuse-dependent-form form)))
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

;; src/anf-transform.lisp  (176 Phase 2b, supersedes: the per-clause split moved ABOVE macroexpansion)
(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list).
   Phase 1c: added opaque pass-through for load-tile-at / store-tile-at
   and their internal *-bwd / bare load-tile / store-tile variants."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       ;; 176 Phase 2b: an INDEPENDENT reduce-warp / reduce-workgroup / grid-reduce! is SPLIT per clause
       ;; here, BEFORE macroexpansion -- the forward lowers it fused, but the backward walk must meet only
       ;; single forms, whose VJPs it already has.  Independent clauses do not interact, so the split
       ;; computes the same values.  (Before the macro block, or grid-reduce!'s macro would hand ANF the
       ;; fused lowering.)
       (when (%independent-reduction-form-p expr)
         (return-from anf-normalize (anf-normalize (%independent-reduction-split-for-ad expr) is-nested?)))
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

;; src/analysis/ops.lisp  (176 Phase 2b, supersedes src: %CHECK-REDUCTION-IDENTITY registered)
(defun register-ops-analyzers ()
  "Registers all expression analyzer functions.
Redefined for 082-atomics to add atomic RMW op analyzers.
Endeavor 109: adds mod / rem under both :crisp-language and :crisp.compiler."
  (def-expression-analyzer + analyze-add-expression)
  (def-expression-analyzer - analyze-sub-expression)
  (def-expression-analyzer * analyze-mul-expression)
  (def-expression-analyzer / analyze-div-expression)
  (def-expression-analyzer sin analyze-sin-expression)
  (def-expression-analyzer cos analyze-cos-expression)
  ;; Endeavor 128: transcendentals
  (def-expression-analyzer exp   analyze-exp-expression)
  (def-expression-analyzer log   analyze-log-expression)
  (def-expression-analyzer log2  analyze-log2-expression)
  (def-expression-analyzer tan   analyze-tan-expression)
  (def-expression-analyzer asin  analyze-asin-expression)
  (def-expression-analyzer acos  analyze-acos-expression)
  (def-expression-analyzer atan  analyze-atan-expression)
  (def-expression-analyzer pow   analyze-pow-expression)
  (def-expression-analyzer atan2 analyze-atan2-expression)
  ;; Endeavour 170: the hardware math ops (and the internal AD helper ops) all share one analyzer.
  (dolist (sym (append *hw-op-symbols* *hw-internal-op-symbols*))
    (setf (gethash sym *expression-analyzers*) 'analyze-hw-op-expression))
  ;; Endeavour 173: the four warp shuffles, under both :crisp-language and :crisp.compiler.
  ;; Not def-expression-analyzer, which quotes one literal operator symbol -- these must be
  ;; interned into both packages at run time (user source reads in :crisp-language, where an
  ;; unregistered spelling is silently minted as a fresh symbol rather than reported).
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry *shuffle-op-names*)
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) '%analyze-shuffle)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) '%analyze-shuffle)))))
  (def-expression-analyzer < analyze-lt-expression)
  (def-expression-analyzer > analyze-gt-expression)
  (def-expression-analyzer <= analyze-le-expression)
  (def-expression-analyzer >= analyze-ge-expression)
  (def-expression-analyzer = analyze-eq-expression)
  (def-expression-analyzer != analyze-neq-expression)

  ;; 082-atomics: register under crisp.compiler package symbols
  (def-expression-analyzer atomic-add!  analyze-atomic-add!-expression)
  (def-expression-analyzer atomic-sub!  analyze-atomic-sub!-expression)
  (def-expression-analyzer atomic-inc!  analyze-atomic-inc!-expression)
  (def-expression-analyzer atomic-dec!  analyze-atomic-dec!-expression)
  (def-expression-analyzer atomic-min!  analyze-atomic-min!-expression)
  (def-expression-analyzer atomic-max!  analyze-atomic-max!-expression)
  (def-expression-analyzer atomic-xchg! analyze-atomic-xchg!-expression)
  (def-expression-analyzer atomic-set!  analyze-atomic-set!-expression)

  ;; 082-atomics: also register under crisp-language package symbols.
  (let ((lang (find-package :crisp-language)))
    (when lang
      (dolist (pair '(("ATOMIC-ADD!"  analyze-atomic-add!-expression)
                      ("ATOMIC-SUB!"  analyze-atomic-sub!-expression)
                      ("ATOMIC-INC!"  analyze-atomic-inc!-expression)
                      ("ATOMIC-DEC!"  analyze-atomic-dec!-expression)
                      ("ATOMIC-MIN!"  analyze-atomic-min!-expression)
                      ("ATOMIC-MAX!"  analyze-atomic-max!-expression)
                      ("ATOMIC-XCHG!" analyze-atomic-xchg!-expression)
                      ("ATOMIC-SET!"  analyze-atomic-set!-expression)))
        (setf (gethash (intern (first pair) lang) *expression-analyzers*)
              (second pair)))))

  ;; 109: mod / rem.  Register under both packages.  In :crisp-language
  ;; these names are fresh symbols (the package :uses nothing).  In
  ;; :crisp.compiler they shadow cl:mod / cl:rem.
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry '(("MOD" . analyze-mod-expression)
                     ("REM" . analyze-rem-expression)))
      (let* ((name (car entry))
             (fn-name (cdr entry))
             (sym-cl (intern name cl-pkg))
             (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) fn-name)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn-name)))))

  (def-expression-analyzer to  analyze-value-cast-expression)
  (def-expression-analyzer as  analyze-generic-as-expression)
  (def-expression-analyzer as-bits analyze-bitcast-expression)
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)

  ;; Register cast operators dynamically
  (log:info "Registering cast operators. *crisp-types* count: ~a" (hash-table-count *crisp-types*))
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (when (symbolp type-name)
          (let* ((type-str (symbol-name type-name))
                 (pkg (symbol-package type-name))
                 (to-name (intern (concatenate 'string "TO-" type-str) pkg))
                 (as-name (intern (concatenate 'string "AS-" type-str) pkg)))
            (log:debug "Registering cast/bitcast: ~s / ~s" to-name as-name)
            (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
            (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression))))

  ;; Float-to-int
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-truncate-expression)
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression)

  ;; ---- Endeavour 175: reductions, atomics, and the warp-collective check ----
  ;; Registered under BOTH packages by name, which is why none of these needed a
  ;; package.lisp change -- an analyzer is found by symbol name, not by an exported
  ;; symbol.  (The two WHEN-THREAD-IN-* macros DID need one: MACRO-FUNCTION is per
  ;; symbol, so those are exported from :crisp.compiler and imported into
  ;; :crisp-language rather than registered here.)
  ;;
  ;; MIN and MAX are in this list because Crisp had no scalar min/max at all; they are
  ;; not reductions, but they arrived with them.
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (dolist (pair '(
                        ("%WARP-COLLECTIVE-CHECK"    %analyze-warp-collective-check)
                        ("REDUCE-WARP"               %analyze-reduce-warp)
                        ("REDUCE-WORKGROUP"          %analyze-reduce-workgroup)
                        ("GRID-REDUCE-ATOMIC!"       %analyze-grid-reduce-atomic)
                        ("GRID-REDUCE-LAST-MAN!"     %analyze-grid-reduce-last-man)
                        ("GRID-REDUCE-SECOND-STAGE!" %analyze-grid-reduce-second-stage)
                        ("GRID-REDUCE-CAS!"          %analyze-grid-reduce-cas)
                        ("ATOMIC-CAS!"               analyze-atomic-cas!-expression)
                        ("%ATOMIC-CAS-OK!"           %analyze-atomic-cas-ok!-expression)
                        ("ATOMIC-BINOP!"             %analyze-atomic-binop!)
                        ("ATOMIC-OP!"                %analyze-atomic-op!)
                        ("MIN"                       %analyze-min-expression)
                        ("MAX"                       %analyze-max-expression)
                        ;; 176: typed constants for reduction identities (and anything else).
                        ("TYPE-MIN"                  %analyze-type-min)
                        ("TYPE-MAX"                  %analyze-type-max)
                        ("TYPE-INFINITY"             %analyze-type-infinity)
                        ;; 176 Phase 2b: the identity check a fused grid-reduce! expansion carries.
                        ("%CHECK-REDUCTION-IDENTITY" %analyze-check-reduction-identity)))
          (setf (gethash (intern (first pair) pkg) *expression-analyzers*)
                (second pair)))))))


;;;; ===========================================================================
;;;; Endeavour 175 — reductions and atomics: analyzers and expanders.
;;;; ===========================================================================

;;;; ===========================================================================
;;;; Endeavour 176 Phase 3 -- the DEPENDENT multi-variable form.
;;;;
;;;;   (reduce-warp      combiner ((var identity) ...) &optional active-threads)
;;;;   (reduce-workgroup combiner ((var identity &key return-vec local-scratch-vec) ...) &key message)
;;;;   (grid-reduce!     combiner ((var identity return-cell &key local-scratch-vec global-scratch-vec) ...)
;;;;                     &key strategy message atomic-counter election-flag-cell)      ; last-man only
;;;;
;;;; The combiner takes two k-value states and returns one: #'(T1..Tk T1..Tk => T1..Tk), state A then
;;;; state B, each in clause order (checked against the clauses' variable types).  Lowered FUSED from the
;;;; start, like Phase 2b: every combine step calls the combiner ONCE with all k values, through a
;;;; multi-value LET.  AUTODIFF is refused LOUDLY (BUG 098): the variables interact inside a user
;;;; function, so the per-clause split the independent form uses does not apply.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new)
(defparameter *176-dependent-forms*
  ;; name           min-clause-length  clause keys                               call keys
  '(("REDUCE-WARP"      2 ()                                       ())
    ("REDUCE-WORKGROUP" 2 (:return-vec :local-scratch-vec)          (:message))
    ("GRID-REDUCE!"     3 (:local-scratch-vec :global-scratch-vec)
                          (:strategy :message :atomic-counter :election-flag-cell)))
  "Endeavour 176.  For each construct with a dependent form: the clause's positional length (var identity,
   plus return-cell at grid level), the keys a clause may carry, and the keys the call may carry.")

;; src/analysis/ops.lisp  (new)
(defun %dependent-reduction-form-p (form)
  "T when FORM is a dependent reduce-warp / reduce-workgroup / grid-reduce! call."
  (and (consp form) (symbolp (car form))
       (assoc (symbol-name (car form)) *176-dependent-forms* :test #'string-equal)
       (eq (%reduction-call-shape form) :dependent)))

;; src/analysis/ops.lisp  (new)
(defun %dependent-reduction-validate (form)
  "Endeavour 176 Phase 3.  Validate a dependent call FORM: the call's own arguments, each clause's shape and
   keys, and that no variable appears in two clauses.  Returns the clause list."
  (let* ((op (car form))
         (name (symbol-name op))
         (spec (assoc name *176-dependent-forms* :test #'string-equal))
         (min-len (second spec))
         (clause-keys (third spec))
         (call-keys (fourth spec))
         (op-name (string-downcase name))
         (clauses (third form))
         (rest (cdddr form))
         (seen '()))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (if (string-equal name "REDUCE-WARP")
          (when (> (length rest) 1)
            (fail "~a: a dependent call is (reduce-warp combiner (clause ...) &optional active-threads); got extra arguments ~s." op-name (rest rest)))
          (progn
            (unless (evenp (length rest))
              (fail "~a: the call's keyword arguments ~s are not key/value pairs." op-name rest))
            (loop for (k nil) on rest by #'cddr
                  unless (member k call-keys)
                    do (fail "~a: ~s is not a key of a dependent call, which takes ~{~s~^, ~}." op-name k call-keys))))
      (dolist (clause clauses)
        (unless (and (consp clause) (>= (length clause) min-len)
                     (evenp (- (length clause) min-len))
                     (symbolp (first clause)) (first clause))
          (fail "~a: malformed clause ~s.  A dependent clause is (var identity~a~@[ &key ~{~(~s~)~^ ~}~])."
                op-name clause (if (= min-len 3) " return-cell" "") clause-keys))
        (let ((var (first clause)))
          (when (member var seen)
            (fail "~a: the variable ~a appears in more than one clause.  Each clause names one value of the state, so a variable may appear only once." op-name var))
          (push var seen))
        (loop for (k nil) on (nthcdr min-len clause) by #'cddr
              unless (member k clause-keys)
                do (fail "~a: unknown clause key ~s in ~s.  A clause takes ~:[no keys~;~:*~{~s~^, ~}~]." op-name k clause clause-keys)))
      clauses)))

;; src/analysis/ops.lisp  (new)
(defun %combiner-call (combiner args)
  "The form calling COMBINER on ARGS: a direct call for a literal #'f (better code, and FUNCALL is not
   differentiable), else FUNCALL -- as %175-apply-binop does for the two-argument case."
  (if (%function-form-p combiner)
      (cons (second combiner) args)
      (list* 'funcall combiner args)))

;; src/analysis/ops.lisp  (new)
(defun %check-dependent-combiner (op-name combiner clauses env context location)
  "Endeavour 176 Phase 3.  A literal #'COMBINER must have a signature #'(T1..Tk T1..Tk => T1..Tk) where Ti is
   the type of clause i's variable -- state A then state B, each in clause order.  Refused otherwise,
   showing the signature the clauses need and the one(s) the combiner has.  An unknown function is left
   for the ordinary call analysis to report."
  (when (%function-form-p combiner)
    (let* ((fname (second combiner))
           (sigs (gethash fname *function-table*))
           (norm (lambda (ty) (let ((r (resolve-type-alias ty))) (if (symbolp r) (symbol-name r) r))))
           (var-types (mapcar (lambda (c)
                                (resolve-type-alias
                                 (semantic-node-type (analyze-expression (first c) env context location))))
                              clauses))
           (want-params (append var-types var-types)))
      (when sigs
        (unless (find-if (lambda (sig)
                           (let ((ps (mapcar #'parameter-def-type (function-signature-parameters sig)))
                                 (rs (remove nil (function-signature-return-types sig))))
                             (and (= (length ps) (length want-params))
                                  (= (length rs) (length var-types))
                                  (every (lambda (a b) (equal (funcall norm a) (funcall norm b))) ps want-params)
                                  (every (lambda (a b) (equal (funcall norm a) (funcall norm b))) rs var-types))))
                         sigs)
          (error 'crisp-compiler-error
                 :message (format nil "~a: the combiner must be #'(~{~(~a~)~^ ~} ~{~(~a~)~^ ~} => ~{~(~a~)~^ ~}) to reduce these clauses -- two states, A then B, each in clause order -- but ~(~a~) is ~{#'(~{~(~a~)~^ ~} => ~{~(~a~)~^ ~})~^ or ~}."
                                  op-name var-types var-types var-types fname
                                  (mapcar (lambda (sig)
                                            (list (mapcar #'parameter-def-type (function-signature-parameters sig))
                                                  (remove nil (function-signature-return-types sig))))
                                          sigs))
                 :source-location location))))))

;; src/analysis/ops.lisp  (new)
(defun %fused-reduce-warp-dependent-form (expr)
  "Endeavour 176 Phase 3.  A dependent reduce-warp as one butterfly: per iteration, every variable is
   shuffled, then the combiner is called ONCE with (partner's state, own state) and its k results replace
   the state.  ACTIVE-THREADS gives lanes past the count the IDENTITY STATE."
  (let* ((combiner (second expr))
         (clauses (%dependent-reduction-validate expr))
         (active-threads (fourth expr))
         (s (gensym "RWD-S"))
         (others (loop repeat (length clauses) collect (gensym "RWD-OTHER")))
         (news (loop repeat (length clauses) collect (gensym "RWD-NEW"))))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (loop for (var identity) in clauses
                 collect `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         (let ,(loop for (var) in clauses for o in others collect `(,o (shuffle-xor ,var ,s)))
           (let ((,@news ,(%combiner-call combiner (append others (mapcar #'first clauses)))))
             ,@(loop for (var) in clauses for n in news collect `(set! ,var ,n)))))
       (compiler-no-op))))

;; src/analysis/ops.lisp  (new)
(defun %fused-reduce-workgroup-dependent-form (expr &optional env context location)
  "Endeavour 176 Phase 3.  A dependent reduce-workgroup: a dependent reduce-warp, every variable's per-warp
   partial written to its own scratch, one barrier, one halving loop whose step calls the combiner ONCE on
   (own partials, partner partials), one read-back, one leader block for every :return-vec.  Implicit
   scratch per clause is typed from its identity (with ENV, also checked against the variable)."
  (let* ((op (car expr))
         (combiner (second expr))
         (clauses (%dependent-reduction-validate expr))
         (implicit '())
         (scratch
           (loop for clause in clauses
                 collect (destructuring-bind (var identity &rest keys) clause
                           (declare (ignore keys))
                           (or (%clause-key clause 2 :local-scratch-vec)
                               (let ((elem-type (%identity-scan-type identity)))
                                 (unless elem-type
                                   (error 'crisp-compiler-error
                                          :message (format nil "reduce-workgroup: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass :local-scratch-vec in that clause yourself." identity)
                                          :source-location location))
                                 (when env
                                   (%check-identity-matches-variable "reduce-workgroup" var identity elem-type
                                                                     env context location))
                                 (let ((name (%implicit-scratch-binding-name var :local-scratch-vec)))
                                   (push (list name (%implicit-scratch-alloc-form :local-scratch-vec elem-type))
                                         implicit)
                                   name))))))
         (return-vecs (loop for clause in clauses collect (%clause-key clause 2 :return-vec)))
         (s (gensym "RWGD-S")) (nw (gensym "RWGD-NW")) (lid (gensym "RWGD-LID"))
         (news (loop repeat (length clauses) collect (gensym "RWGD-NEW")))
         (warp-op (intern "REDUCE-WARP" (or (symbol-package op) (find-package :crisp-language))))
         (body
           `(progn
              (,warp-op ,combiner ,(loop for (var identity) in clauses collect (list var identity)))
              (when-thread-in-warp-is 0
                ,@(loop for (var) in clauses for sc in scratch
                        collect `(set! (~ ,sc (to-int (warp-id))) ,var)))
              (sync-workgroup)
              (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
                    (,lid (to-int (get-local-linear-id))))
                (dec-times-by-half+ (,s (/ ,nw 2ul))
                  (when (< ,lid (to-int ,s))
                    (let ((,@news ,(%combiner-call combiner
                                                   (append (loop for sc in scratch collect `(~ ,sc ,lid))
                                                           (loop for sc in scratch
                                                                 collect `(~ ,sc (+ ,lid (to-int ,s))))))))
                      ,@(loop for sc in scratch for n in news collect `(set! (~ ,sc ,lid) ,n))))
                  (sync-workgroup))
                ,@(loop for (var) in clauses for sc in scratch
                        collect `(set! ,var (~ ,sc 0))))
              ,@(when (some #'identity return-vecs)
                  `((when-thread-in-group-is 0
                      ,@(loop for (var) in clauses for rv in return-vecs
                              when rv collect `(set! (~ ,rv (to-int (get-workgroup-id 0))) ,var)))))
              (compiler-no-op))))
    (if implicit `(let ,(nreverse implicit) ,body) body)))

;; src/analysis/ops.lisp  (new)
(defun %fused-grid-reduce-dependent-form (form)
  "Endeavour 176 Phase 3.  A dependent grid-reduce!: :last-man-standing only (:atomic and :cas commit one
   word at a time, so they cannot keep a state together -- a Crisp limitation; packing a small state into
   one 64-bit CAS is possible in principle).  Phase 1 is a dependent reduce-workgroup; every variable's
   partial is written, ONE ticket from ONE counter decides the last workgroup, which runs a dependent
   reduce-workgroup over the partials and writes every return cell.  Scratch left out is implicit."
  (let* ((op (car form))
         (pkg (or (symbol-package op) (find-package :crisp-language)))
         (combiner (second form))
         (clauses (%dependent-reduction-validate form))
         (rest (cdddr form))
         (strategy-given (loop for (k v) on rest by #'cddr thereis (and (eq k :strategy) (list v))))
         (strategy (if strategy-given (first strategy-given) :last-man-standing))
         (rwg (intern "REDUCE-WORKGROUP" pkg))
         (lets '()) (checks '())
         (v1 (first (first clauses))))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (unless (keywordp strategy)
        (fail "grid-reduce!: :strategy ~s must be known at compile time -- write :last-man-standing (the only strategy a dependent reduction allows)." strategy))
      (unless (eq strategy :last-man-standing)
        (fail "grid-reduce!: a dependent reduction works only with :last-man-standing, not ~s.  :atomic and :cas commit one word at a time, so they cannot keep a state's values together (a Crisp limitation: packing a small state into one 64-bit CAS is possible in principle, but Crisp does not do it)." strategy))
      (labels ((supply (given var identity key)
                 (or given
                     (let ((elem-type (if (member key '(:atomic-counter :election-flag-cell))
                                          'uint
                                          (%identity-scan-type identity))))
                       (unless elem-type
                         (fail "grid-reduce!: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass that clause's scratch yourself." identity))
                       (let ((name (%implicit-scratch-binding-name var key)))
                         (push (list name (%implicit-scratch-alloc-form key elem-type)) lets)
                         (unless (member key '(:atomic-counter :election-flag-cell))
                           (pushnew `(%check-reduction-identity "grid-reduce!" ,var ,identity ,elem-type)
                                    checks :test #'equal))
                         name)))))
        (let* ((svs (loop for c in clauses
                          collect (supply (%clause-key c 3 :local-scratch-vec) (first c) (second c) :local-scratch-vec)))
               (gvs (loop for c in clauses
                          collect (supply (%clause-key c 3 :global-scratch-vec) (first c) (second c) :global-scratch-vec)))
               (ctr (supply (getf rest :atomic-counter) v1 nil :atomic-counter))
               (flag (supply (getf rest :election-flag-cell) v1 nil :election-flag-cell))
               (lid (gensym "LMD-LID"))
               (ng (gensym "LMD-NG"))
               (vals (loop repeat (length clauses) collect (gensym "LMD-VAL")))
               (body
                 `(progn
                    ,@(reverse checks)
                    (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                                  "grid-reduce!: the number of workgroups exceeds local_work_size, so the last-man final sweep cannot cover every partial in one pass.")
                    (,rwg ,combiner ,(loop for c in clauses for sv in svs
                                           collect `(,(first c) ,(second c) :local-scratch-vec ,sv)))
                    (when-thread-in-group-is 0
                      ,@(loop for c in clauses for gv in gvs
                              collect `(set! (~ ,gv (to-int (get-workgroup-id 0))) ,(first c))))
                    (mem-fence)
                    (when-thread-in-group-is 0
                      (set! (~ ,flag)
                            (if (= (atomic-add! (~ ,ctr) 1u)
                                   (- (to-uint (get-num-groups 0)) 1u))
                                1u 0u)))
                    (sync-workgroup)
                    (when+ (= (~ ,flag) 1u)
                      (let ((,lid (to-int (get-local-linear-id)))
                            (,ng  (to-int (get-num-groups 0))))
                        (let ,(loop for c in clauses for gv in gvs for val in vals
                                    collect `(,val (if (< ,lid ,ng) (~ ,gv ,lid) ,(second c))))
                          (,rwg ,combiner ,(loop for c in clauses for sv in svs for val in vals
                                                 collect `(,val ,(second c) :local-scratch-vec ,sv)))
                          (when-thread-in-group-is 0
                            ,@(loop for c in clauses for val in vals
                                    collect `(set! (~ ,(third c) 0) ,val))))))
                    (compiler-no-op))))
          (if lets `(let ,(nreverse lets) ,body) body))))))

;; src/analysis/ops.lisp  (new)
(defun %refuse-dependent-autodiff (form)
  "BUG 098.  The AD path meets a dependent reduction: refuse LOUDLY.  Its variables interact inside a user
   combiner, so the per-clause split the independent form uses does not apply, and a scratch-based
   cross-thread reduction differentiated mechanically is silently wrong."
  (error 'crisp-compiler-error
         :message (format nil "~(~a~): dependent reductions are not differentiable yet (BUG 098) -- the variables interact inside the combiner ~s, so the backward pass has no rule for them.  Keep this kernel out of differentiation."
                          (car form) (second form))
         :source-location nil))

;; src/analysis/ops.lisp  (supersedes the Phase 2b copy: dependent shape scanned as its fused form)
(defun %scan-reduction-maybe-implicit (op args next)
  "Pass 1.  An independent or dependent reduce-workgroup is scanned as its fused form (the same form the
   analyzer sees).  Otherwise scan the implicit-scratch form of reduction (OP . ARGS) when Crisp will
   supply its scratch, or call NEXT (the default scan)."
  (let ((expr (cons op args)))
    (cond
      ((%independent-reduction-form-p expr)
       (scan-form (ignore-errors (%fused-reduce-workgroup-form expr))))
      ((%dependent-reduction-form-p expr)
       (scan-form (ignore-errors (%fused-reduce-workgroup-dependent-form expr))))
      (t
       (let* ((missing (%implicit-scratch-missing-keys expr))
              (elem-type (and missing (symbolp (third expr)) (%identity-scan-type (fourth expr)))))
         (if elem-type
             (progn
               (log:debug "176: Pass 1 implicit scratch ~s for ~s (element type ~s)" missing op elem-type)
               (scan-form (%implicit-scratch-form expr elem-type)))
             (funcall next)))))))

;; src/analysis/ops.lisp  (supersedes the Phase 2b copy: dependent shape scanned as its fused form)
(macrolet ((def-warp-scanners ()
             `(progn
                ,@(loop for pkg in '(:crisp.compiler :crisp-language)
                        collect `(defmethod scan-operator ((op (eql (intern "REDUCE-WARP" (find-package ,pkg)))) args)
                                   (let ((expr (cons op args)))
                                     (cond
                                       ((%independent-reduction-form-p expr)
                                        (scan-form (ignore-errors (%fused-reduce-warp-form expr))))
                                       ((%dependent-reduction-form-p expr)
                                        (scan-form (ignore-errors (%fused-reduce-warp-dependent-form expr))))
                                       (t (call-next-method)))))))))
  (def-warp-scanners))

;; src/analysis/ops.lisp  (supersedes the Phase 2b copy: dependent -> FUSED, combiner checked)
(defun %analyze-reduce-warp (expr env context location)
  "Analyzer for reduce-warp -- expands and delegates.  176: an independent call is lowered fused
   (%fused-reduce-warp-form); a dependent call has its combiner checked against the clauses and is lowered
   fused (%fused-reduce-warp-dependent-form).  Every dependent form reaches this analyzer, so the
   combiner check covers reduce-workgroup and grid-reduce! too."
  (case (%reduction-call-shape expr)
    (:independent (analyze-expression (%fused-reduce-warp-form expr) env context location))
    (:dependent
     (%check-dependent-combiner "reduce-warp" (second expr) (%dependent-reduction-validate expr)
                                env context location)
     (analyze-expression (%fused-reduce-warp-dependent-form expr) env context location))
    (t (analyze-expression (%reduce-warp-expand expr) env context location))))

;; src/analysis/ops.lisp  (supersedes the Phase 2b copy: dependent -> FUSED)
(defun %analyze-reduction-maybe-implicit (expr env context location expander)
  "Endeavour 176.  Analyze reduction EXPR: an independent or dependent reduce-workgroup FUSED (with its
   identity checks); otherwise supply its scratch when the caller left it out, else analyze
   (EXPANDER EXPR) as before."
  (case (%reduction-call-shape expr)
    (:independent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%fused-reduce-workgroup-form expr env context location) env context location)))
    (:dependent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%fused-reduce-workgroup-dependent-form expr env context location) env context location))))
  (let ((missing (%implicit-scratch-missing-keys expr))
        (var (third expr)))
    (if (or (null missing) (not (symbolp var)))
        (analyze-expression (funcall expander expr) env context location)
        (let* ((op-name (string-downcase (symbol-name (car expr))))
               (identity (fourth expr))
               (elem-type (%identity-scan-type identity)))
          (unless elem-type
            (error 'crisp-compiler-error
                   :message (format nil "~a: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass ~{~s~^ ~} yourself."
                                    op-name identity missing)
                   :source-location location))
          (%check-identity-matches-variable op-name var identity elem-type env context location)
          (log:debug "176: implicit scratch ~s for ~a over ~s (element type ~s)" missing op-name var elem-type)
          (analyze-expression (%implicit-scratch-form expr elem-type) env context location)))))

;; src/analysis/ops.lisp  (176 Phase 3, supersedes: dependent -> FUSED last-man)
(defun %grid-reduce!-expand (form)
  "Endeavour 176.  The expansion of grid-reduce!.  An INDEPENDENT call (a clause list) becomes a PROGN of
   single grid-reduce! calls (%independent-reduction-expand); the dependent form is refused until Phase 3.
   A single call (grid-reduce! FN VAR IDENTITY RETURN-CELL &key STRATEGY ...) becomes the construct STRATEGY
   names, minus :strategy -- refusing a missing argument, a non-literal or unknown strategy, and a key the
   chosen construct does not take.  The target is interned in the CALL's package, because the reductions
   are distinct symbols in :crisp-language and :crisp.compiler (each registered in both)."
  (case (%reduction-call-shape form)
    (:independent (return-from %grid-reduce!-expand (%fused-grid-reduce-form form)))      ; 176 Phase 2b
    (:dependent   (return-from %grid-reduce!-expand (%fused-grid-reduce-dependent-form form))))   ; 176 Phase 3
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

;; src/anf-transform.lisp  (176 Phase 3, supersedes: a dependent reduction is refused on the AD path)
(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list).
   Phase 1c: added opaque pass-through for load-tile-at / store-tile-at
   and their internal *-bwd / bare load-tile / store-tile variants."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       ;; 176 Phase 2b: an INDEPENDENT reduce-warp / reduce-workgroup / grid-reduce! is SPLIT per clause
       ;; here, BEFORE macroexpansion -- the forward lowers it fused, but the backward walk must meet only
       ;; single forms, whose VJPs it already has.  Independent clauses do not interact, so the split
       ;; computes the same values.  (Before the macro block, or grid-reduce!'s macro would hand ANF the
       ;; fused lowering.)
       (when (%independent-reduction-form-p expr)
         (return-from anf-normalize (anf-normalize (%independent-reduction-split-for-ad expr) is-nested?)))
       ;; 176 Phase 3 / BUG 098: a DEPENDENT reduction has no backward rule yet -- refuse loudly.
       (when (%dependent-reduction-form-p expr)
         (%refuse-dependent-autodiff expr))
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
