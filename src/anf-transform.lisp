;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)

(defvar *anf-counter* 0)

(defun anf-fresh-temp ()
  (intern (format nil "%ANF-T-~D" (incf *anf-counter*))))

;; Endeavour 178: a STRING is atomic.  MEASURED: (let ((p 0.0)) (loop-vector-stride ..)
;; (grid-reduce! #'+ p 0.0 out :strategy :atomic :message "a sum")) died under --differentiate with
;; "Unsupported form for anf-transform: \"a sum\"" -- the reserved :message key of every reduction
;; reaches ANF as an argument once the call sits inside a LET.  A string is a constant, like a number.
(defun anf-is-atomic? (expr)
  "Returns true if EXPR is considered an atomic value in ANF.  178: strings included."
  (or (numberp expr)
      (stringp expr)
      (keywordp expr)
      (symbolp expr)
      (and (consp expr) (eq (car expr) 'function))))


(defun anf-normalize-args (args)
  "Returns (VALUES normalized-args bindings-list)"
  (if (null args)
      (values nil nil)
      (multiple-value-bind (anf-car car-bindings) (anf-normalize (car args) t)
        (multiple-value-bind (anf-cdr cdr-bindings) (anf-normalize-args (cdr args))
          (values (cons anf-car anf-cdr)
            (append car-bindings cdr-bindings))))))

(defun anf-normalize-place (place)
  "Returns (VALUES normalized-place bindings)
   Normalizes a place for mutation (e.g. the left side of a set!).
   An atomic place stays unchanged, while accessors have their parent argument hoisted."
  (cond
   ((symbolp place) (values place nil))
   ((consp place)
     (let ((acc (car place))
           (args (cdr place)))
       (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
         (values `(,acc ,@anf-args) bindings))))
   (t (error "Invalid place in set!: ~S" place))))




(defun %anf-normalize-set! (expr is-nested?)
  (let ((place (cadr expr))
        (value (caddr expr)))
    (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
      (multiple-value-bind (new-val val-bindings) (anf-normalize value t)
        (let ((set-expr `(set! ,new-place ,new-val))
              (all-bindings (append place-bindings val-bindings)))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp (append all-bindings `((,temp ,set-expr)))))
              (values set-expr all-bindings)))))))

(defun %anf-normalize-if (op expr is-nested?)
  (multiple-value-bind (cond-expr cond-bindings) (anf-normalize (cadr expr) t)
    (let* ((true-branch (%anf-transform (caddr expr)))
           (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
           (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
           (anf-if (if false-branch
                       `(,op ,cond-expr ,true-branch ,false-branch)
                       `(,op ,cond-expr ,true-branch))))
      (if is-nested?
          (let ((temp (anf-fresh-temp)))
            (values temp (append cond-bindings `((,temp ,anf-if)))))
          (values anf-if cond-bindings)))))

(defun %anf-normalize-if+ (op expr is-nested?)
  (let* ((cond-expr (cadr expr))
         (true-branch (%anf-transform (caddr expr)))
         (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
         (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
         (anf-if (if false-branch
                     `(,op ,cond-expr ,true-branch ,false-branch)
                     `(,op ,cond-expr ,true-branch))))
    (if is-nested?
        (let ((temp (anf-fresh-temp)))
          (values temp `((,temp ,anf-if))))
        (values anf-if nil))))

(defun %anf-normalize-cond (expr is-nested?)
  (let ((anf-clauses (mapcar (lambda (clause)
                               (let* ((pred (car clause))
                                      (body (cadr clause))
                                      (anf-pred (if (eq pred 'else)
                                                    'else
                                                    (%anf-transform pred)))
                                      (anf-body (%anf-transform body)))
                                 `(,anf-pred ,anf-body)))
                             (cdr expr))))
    (let ((anf-cond `(cond ,@anf-clauses)))
      (if is-nested?
          (let ((temp (anf-fresh-temp)))
            (values temp `((,temp ,anf-cond))))
          (values anf-cond nil)))))

(defun %anf-normalize-let (expr is-nested?)
  (let* ((orig-bindings (cadr expr))
         (body-and-decls (cddr expr))
         (decls (loop for f in body-and-decls while (and (listp f) (eq (car f) 'declare)) collect f))
         (body-forms (nthcdr (length decls) body-and-decls))
         (new-bindings nil))
    (dolist (bind orig-bindings)
      (let* ((vars (if (listp (car bind)) (car bind) (butlast bind)))
             (val (if (listp (car bind)) (cadr bind) (car (last bind)))))
        (multiple-value-bind (new-val val-bindings) (anf-normalize val nil)
          (setf new-bindings (append new-bindings val-bindings))
          (setf new-bindings (append new-bindings (list `(,@vars ,new-val)))))))
    (let* ((anf-body (mapcar #'%anf-transform body-forms))
           (hoisted-decls (loop for d in decls collect `(declare ,d)))
           (anf-progn (if (> (length anf-body) 1) `(progn ,@anf-body) (car anf-body))))
      (if is-nested?
          (let ((temp (anf-fresh-temp)))
            (values temp (append new-bindings hoisted-decls `((,temp ,anf-progn)))))
          (values anf-progn (append new-bindings hoisted-decls))))))

;;; ---------------------------------------------------------------------------
;;; Endeavour 172 -- the dotimes family: dec-times, dec-times-by-half / -by-factor,
;;; do-times-by-doubling / -by-multiply, do-power-step, dec-power-step, each with a +
;;; variant.  Decisions D1-D7: tests/spec/172-do-times-variants/do-times-variants.md
;;; ---------------------------------------------------------------------------
(defparameter *dotimes-family-names*
  '("DOTIMES" "DOTIMES+"
    "DEC-TIMES" "DEC-TIMES+"
    "DEC-TIMES-BY-HALF" "DEC-TIMES-BY-HALF+"
    "DEC-TIMES-BY-FACTOR" "DEC-TIMES-BY-FACTOR+"
    "DO-TIMES-BY-DOUBLING" "DO-TIMES-BY-DOUBLING+"
    "DO-TIMES-BY-MULTIPLY" "DO-TIMES-BY-MULTIPLY+"
    "DO-POWER-STEP" "DO-POWER-STEP+"
    "DEC-POWER-STEP" "DEC-POWER-STEP+")
  "Endeavour 172: the head names of the counted-loop family.  Every member has the shape
   (HEAD (VAR OPERAND...) BODY...): VAR is bound in BODY, the operands are evaluated once
   before the loop.  ANF and the AD walker treat all of them exactly like dotimes.")

(defun %dotimes-family-head-p (head)
  "True when HEAD names a counted-loop family member (dotimes, dec-times, ... and their
   + variants), compared by symbol name so the reading package does not matter."
  (and head (symbolp head)
       (member (symbol-name head) *dotimes-family-names* :test #'string-equal)
       t))

(defun %dotimes-backward-head (head)
  "The head the AD backward walk emits for a forward counted loop HEAD: the plain (non +)
   form, since the backward kernel re-checks nothing about uniformity.  DOTIMES and DOTIMES+
   map to the dotimes symbol exactly as before endeavour 172."
  (let* ((nm (symbol-name head))
         (base (string-right-trim "+" nm)))
    (if (string-equal base "DOTIMES")
        'dotimes
        (intern base (symbol-package head)))))

(defun %anf-normalize-dotimes (op expr is-nested?)
  "ANF-normalizes a counted-loop family form (OP (VAR OPERAND...) BODY...).  Each operand is
   normalized to an atom (its bindings hoisted ahead of the loop, in order); the body is
   transformed in place, never hoisted.  When IS-NESTED? the loop is bound to a fresh temp."
  (let* ((binding (cadr expr))
         (var (car binding))
         (operands (cdr binding))
         (body (cddr expr))
         (new-operands nil)
         (hoisted nil))
    (dolist (o operands)
      (multiple-value-bind (new-o o-bindings) (anf-normalize o t)
        (push new-o new-operands)
        (setf hoisted (append hoisted o-bindings))))
    (let* ((anf-body (mapcar #'%anf-transform body))
           (anf-loop `(,op (,var ,@(nreverse new-operands)) ,@anf-body)))
      (log:debug "ANF counted loop ~a: ~d operand(s), ~d hoisted binding(s)"
                 op (length operands) (length hoisted))
      (if is-nested?
          (let ((temp (anf-fresh-temp)))
            (values temp (append hoisted `((,temp ,anf-loop)))))
          (values anf-loop hoisted)))))

(defun %anf-normalize-while (op expr is-nested?)
  (let* ((condition (cadr expr))
         (body (cddr expr)))
    (multiple-value-bind (new-condition condition-bindings) (anf-normalize condition t)
      (let* ((anf-body (mapcar #'%anf-transform body))
             (anf-while `(,op ,new-condition ,@anf-body)))
        (if is-nested?
            (let ((temp (anf-fresh-temp)))
              (values temp (append condition-bindings `((,temp ,anf-while)))))
            (values anf-while condition-bindings))))))

(defun %anf-normalize-atomic (op expr is-nested?)
  (let ((place (cadr expr))
        (rest-args (cddr expr)))
    (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
      (multiple-value-bind (anf-args arg-bindings) (anf-normalize-args rest-args)
        (let ((call `(,op ,new-place ,@anf-args))
              (all-bindings (append place-bindings arg-bindings)))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp (append all-bindings `((,temp ,call)))))
              (values call all-bindings)))))))

;;; anf-normalize's tables and its one repeated tail (refactor-oct, 2026-10-16) -- moved out of its
;;; body, unchanged.

(defparameter *anf-unexpanded-macros*
  '(when when+ unless unless+ cond cond+ if if+ return dotimes dotimes+ while set! declare progn let
    template-instantiation def-function def-kernel def-kernel-exact make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor as quote compiler-no-op
    make-cell make-vector make-matrix make-tensor)
  "Operators anf-normalize handles ITSELF.  When one of them is also a macro, it must not be
   macroexpanded before the dispatch below sees it.")

(defparameter *anf-opaque-statement-names*
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
  "Forms anf-normalize passes through WHOLE (bound to a temp when nested): their coordinate / dimension
   tuples are not expressions to flatten, and the backward walk meets them as single statements.")

(defparameter *anf-atomic-op-names*
  '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
    "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!"
    ;; Endeavour 175 -- see the header above anf-normalize.
    "ATOMIC-CAS!" "%ATOMIC-CAS-OK!" "ATOMIC-BINOP!" "ATOMIC-OP!")
  "The place-writing atomic operators, normalized by %anf-normalize-atomic.")

(defun %anf-bind-if-nested (form bindings is-nested?)
  "The tail every anf-normalize clause shares: return FORM with its BINDINGS -- or, when IS-NESTED?, bind
   it to a fresh temp (appended after BINDINGS) and return the temp.  Callers normalize FORM's
   sub-forms BEFORE calling this, so the temp is minted after theirs, as it always was."
  (if is-nested?
      (let ((temp (anf-fresh-temp)))
        (values temp (append bindings `((,temp ,form)))))
      (values form bindings)))

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
       ;; 176 Phase 3 / BUG 098, endeavour 177: a DEPENDENT reduction whose combiner declares a
       ;; reduction-vjp passes through as an opaque STATEMENT (its clauses are not expressions to
       ;; normalize) -- its VJP takes it from there.  Any other dependent reduction is refused loudly.
       (when (%dependent-reduction-form-p expr)
         (if (and (member (symbol-name (car expr)) *177-differentiable-dependent-forms* :test #'string-equal)
                  (%dependent-reduction-vjp expr))
             (progn (log:debug "177: dependent ~a passes through ANF for its reduction-vjp" (car expr))
                    (return-from anf-normalize (values expr nil)))
             (%refuse-dependent-autodiff expr)))
       (when (and (symbolp op)
                  (macro-function op)
                  (not (member op *anf-unexpanded-macros*)))
             (multiple-value-bind (expanded changed) (macroexpand-1 expr)
               (when changed
                     (return-from anf-normalize (anf-normalize expanded is-nested?)))))
       (cond
        ((and (symbolp op)
              (member (symbol-name op) *anf-opaque-statement-names* :test #'string=))
          (%anf-bind-if-nested expr nil is-nested?))
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
          (%anf-bind-if-nested expr nil is-nested?))
        ((eq op 'return)
          (multiple-value-bind (new-args bindings) (anf-normalize-args (cdr expr))
            (%anf-bind-if-nested `(return ,@new-args) bindings is-nested?)))
        ((eq op 'as)
          (let ((type-spec (cadr expr))
                (val (caddr expr)))
            (multiple-value-bind (new-val bindings) (anf-normalize val t)
              (%anf-bind-if-nested `(as ,type-spec ,new-val) bindings is-nested?))))
        ((eq op 'make-scratch-cell)
          (%anf-bind-if-nested `(make-scratch-cell ,(cadr expr)) nil is-nested?))
        ((member op '(make-scratch-vector make-scratch-matrix make-scratch-tensor))
          (%anf-bind-if-nested `(,op ,@(cdr expr)) nil is-nested?))
        ((member op '(make-cell make-vector make-matrix make-tensor))
          (let* ((source (cadr expr))
                 (rest-args (cddr expr)))
            (multiple-value-bind (new-source source-bindings)
                (anf-normalize source t)
              (%anf-bind-if-nested `(,op ,new-source ,@rest-args) source-bindings is-nested?))))
        ((member op '(quote template-instantiation compiler-no-op def-function def-kernel def-kernel-exact eval-when))
          (%anf-bind-if-nested expr nil is-nested?))
        ((eq op 'progn)
          (%anf-bind-if-nested `(progn ,@(mapcar #'%anf-transform (cdr expr))) nil is-nested?))
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
              (member (symbol-name op) *anf-atomic-op-names* :test #'string=))
          (%anf-normalize-atomic op expr is-nested?))
        (t
          (let ((args (cdr expr)))
            (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
              (%anf-bind-if-nested `(,op ,@anf-args) bindings is-nested?)))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))



(defun %strip-ctx-declares (expr)
  "Recursively strip (declare (grid-level)) and (declare (workgroup-level))
from let/progn bodies before ANF transform."
  (if (not (consp expr))
      expr
      (let ((op (car expr)))
        (cond
         ((and (symbolp op) (string-equal (symbol-name op) "LET"))
          (let* ((bindings (cadr expr))
                 (body (cddr expr))
                 (stripped (remove-if
                              (lambda (f)
                                (and (consp f)
                                     (symbolp (car f))
                                     (string-equal (symbol-name (car f)) "DECLARE")
                                     (consp (cdr f))
                                     (consp (cadr f))
                                     (symbolp (caadr f))
                                     (member (symbol-name (caadr f))
                                             '("GRID-LEVEL" "WORKGROUP-LEVEL")
                                             :test #'string=)))
                              body)))
            `(let ,bindings ,@(mapcar #'%strip-ctx-declares stripped))))
         ((and (symbolp op) (string-equal (symbol-name op) "PROGN"))
          `(progn ,@(mapcar #'%strip-ctx-declares (cdr expr))))
         (t expr)))))

(defun %anf-transform (expr)
  "Internal helper for recursive ANF transformation.
Pre-strips execution-context declares so anf-normalize never sees them."
  (multiple-value-bind (normalized bindings) (anf-normalize (%strip-ctx-declares expr) nil)
    (if bindings
        `(let ,bindings ,normalized)
        normalized)))

;;; ---------------------------------------------------------------------------
;;; ADV-001 / ADV-002 (adversarial, 2026-10-12): SILENTLY WRONG GRADIENTS when a let rebinds a name
;;; already in scope inside a differentiated body.  %anf-normalize-let FLATTENS nested lets into one
;;; binding list, so an inner x became a second binding of the SAME symbol, and the AD walk -- which
;;; keys adjoints by name (X_ADJ) -- merged the two variables' adjoints (6.0 for a true 4.0; 0.0 for
;;; 4.0).  anf-transform therefore alpha-renames every let / counted-loop binding that would collide:
;;;   - its name is already bound by an enclosing let / loop in this form, or
;;;   - its own initial value mentions that name (shadowing a PARAMETER, which ANF cannot see).
;;; The new name is NAME%SHn.  Renaming preserves semantics; only the AD pipeline consumes this.
;;; Specs: tests/spec/124-ad-issues/20..23 (VERIFY-AUTODIFF).
;;; ---------------------------------------------------------------------------
(defvar *ad-shadow-rename-counter* 0
  "Counter for the NAME%SHn symbols minted by %alpha-rename-shadowed-lets (ADV-001).")

(defun %fresh-shadow-name (sym)
  "A fresh symbol NAME%SHn in SYM's package, for a renamed shadowing binding."
  (intern (format nil "~a%SH~d" (symbol-name sym) (incf *ad-shadow-rename-counter*))
          (or (symbol-package sym) *package*)))

(defun %renamable-var-p (sym)
  "T for a symbol that names a lexical variable: not a keyword, not NIL / T."
  (and (symbolp sym) sym (not (eq sym t)) (not (keywordp sym))))

(defun %alpha-rename-shadowed-lets (form &optional env bound)
  "Returns FORM with shadowing let / counted-loop bindings alpha-renamed (ADV-001).
   ENV is an alist old-symbol -> new-symbol for renamings in scope; BOUND lists the names bound
   by enclosing lets / loops of this form.  Operator positions are never renamed."
  (labels ((ren (f env bound) (%alpha-rename-shadowed-lets f env bound))
           (ren-args (args env bound) (mapcar (lambda (a) (ren a env bound)) args))
           (bind-var (var init env bound)
             ;; Returns (values new-var env bound) for one binder.
             (if (and (%renamable-var-p var)
                      ;; src/analysis/control.lisp's helper; argument order is (form sym)
                      (or (member var bound) (%form-mentions-symbol-p init var)))
                 (let ((new (%fresh-shadow-name var)))
                   (log:debug "alpha-rename: shadowing binding ~a -> ~a" var new)
                   (values new (acons var new env) (cons new bound)))
                 (values var
                         (if (assoc var env) (acons var var env) env) ; un-shadow an outer renaming
                         (cons var bound)))))
    (cond
      ((symbolp form) (let ((hit (assoc form env))) (if hit (cdr hit) form)))
      ((atom form) form)
      ((and (symbolp (car form)) (member (symbol-name (car form)) '("QUOTE" "FUNCTION") :test #'string=))
       form)
      ;; (let (BIND...) BODY...)  -- sequential; BIND is (var val), (v1 v2 ... val) or ((v1 v2) val)
      ((and (symbolp (car form)) (string-equal (symbol-name (car form)) "LET") (listp (second form)))
       (let ((new-binds '()))
         (dolist (b (second form))
           (if (and (consp b) (cdr b))
               (let* ((listy (listp (car b)))
                      (vars (if listy (car b) (butlast b)))
                      (init (if listy (second b) (car (last b))))
                      (new-init (ren init env bound))
                      (new-vars '()))
                 (dolist (v vars)
                   (multiple-value-bind (nv nenv nbound) (bind-var v init env bound)
                     (push nv new-vars) (setf env nenv bound nbound)))
                 (setf new-vars (nreverse new-vars))
                 (push (if listy (list new-vars new-init) (append new-vars (list new-init))) new-binds))
               (push b new-binds)))
         `(,(car form) ,(nreverse new-binds) ,@(ren-args (cddr form) env bound))))
      ;; counted loops: (HEAD (VAR OPERAND...) BODY...)
      ((and (%dotimes-family-head-p (car form)) (consp (second form)) (symbolp (car (second form))))
       (let* ((var (car (second form)))
              (operands (ren-args (cdr (second form)) env bound)))
         (multiple-value-bind (nv nenv nbound) (bind-var var nil env bound)
           `(,(car form) (,nv ,@operands) ,@(ren-args (cddr form) nenv nbound)))))
      ;; anything else: keep the operator, rename inside the arguments
      ((symbolp (car form)) `(,(car form) ,@(ren-args (cdr form) env bound)))
      (t (ren-args form env bound)))))

(defun anf-transform (expr)
  "Transforms a Crisp expression into A-Normal Form.
   ADV-001: first alpha-renames let bindings that shadow a name in scope, because ANF flattens
   nested lets and the AD walk keys adjoints by name (see %alpha-rename-shadowed-lets)."
  (let ((*anf-counter* 0))
    (%anf-transform (%alpha-rename-shadowed-lets expr))))


(defun anf-transform-module (forms)
  "Iterates over top-level forms, running ANF transform on function/kernel bodies."
  (mapcar (lambda (form)
            (if (consp form)
                (let ((op (car form)))
                  (cond
                   ((member op '(def-function def-kernel def-kernel-exact))
                     ;; (op name args decls ...body)
                     (let* ((name (cadr form))
                            (args (caddr form))
                            (body-start 3)
                            (decls (loop for i from body-start below (length form)
                                         for f = (nth i form)
                                         while (and (consp f) (eq (car f) 'declare))
                                         collect f))
                            (actual-body-start (+ body-start (length decls)))
                            (body (nthcdr actual-body-start form))
                            (anf-body (mapcar #'anf-transform body)))
                       `(,op ,name ,args ,@decls ,@anf-body)))
                   ((eq op 'with-template-type)
                     ;; (with-template-type (params) inner-form)
                     `(with-template-type ,(cadr form) ,@(anf-transform-module (cddr form))))
                   (t form)))
                form))
      forms))



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