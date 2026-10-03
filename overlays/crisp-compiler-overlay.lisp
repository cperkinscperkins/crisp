;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-02 -- endeavour 177 (reduction-ad) folded into src/:
;;;;   * BUG 099 copy-binding clause      -> %handle-single-value-backward (src/autodiff.lisp)
;;;;   * BUG 101 active-threads gate      -> %175-vjp-reduce-warp (src/autodiff.lisp)
;;;;   * BUG 100 versioned in-place writes -> %ad-version-in-place-writes, %ad-assemble-primal-replay and
;;;;     the two edits in %generate-backward-kernel-ast (src/macros.lisp)
;;;;   * 177 dependent-reduction AD        -> *reduction-vjps*, %check-reduction-vjp etc. (src/analysis/ops.lisp),
;;;;     %177-vjp-dependent-reduction (src/autodiff.lisp)
;;;; The three overlay WRAPPERS were inlined rather than moved: register-function-signature
;;;; (src/environment.lisp), anf-normalize (src/anf-transform.lisp), %check-dependent-combiner
;;;; (src/analysis/ops.lisp).  The VJP re-registrations were dropped -- src's own registration covers them.
;;;; *176-generic-scratch-range* moved from the tail of the GENERATED src/specials.lisp to
;;;; src/analysis/core.lisp, where regeneration cannot delete it.

(in-package :crisp.compiler)

;;;; ===========================================================================
;;;; Endeavour 178 -- reduce-vec: a whole-vector grid reduction.
;;;;
;;;;   (reduce-vec fn vec identity out-cell &key strategy message
;;;;               local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)
;;;;
;;;; Sugar over grid-reduce!: each thread folds its grid-stride share of VEC into a private
;;;; partial (seeded with IDENTITY, so a thread that owns no element contributes the identity),
;;;; and the partials go through grid-reduce! with the same :strategy and scratch keys.
;;;; ===========================================================================

;; src/analysis/ops.lisp
(defun %reduce-vec-partial-name (vec out pkg)
  "Endeavour 178.  The DETERMINISTIC name of reduce-vec's per-thread partial, e.g. DATA-INTO-OUT.
   Deterministic, never a gensym, because the implicit scratch grid-reduce! allocates is named after
   the variable it reduces (%implicit-scratch-binding-name), and Pass 1 and Pass 2 must agree on that
   name.  Naming it after the vector AND the result cell keeps two reduce-vec calls in one kernel --
   a sum and a max of the same vector, say -- from sharing scratch, and names the buffers readably in
   the generated host code."
  (flet ((part (x default)
           (if (and x (symbolp x)) (symbol-name x) default)))
    (intern (format nil "~a-INTO-~a" (part vec "REDUCE-VEC") (part out "OUT")) pkg)))

;; src/analysis/ops.lisp
(defun %reduce-vec-expand (form)
  "Endeavour 178.  The expansion of (reduce-vec FN VEC IDENTITY OUT-CELL &key STRATEGY ...):

     (let ((P IDENTITY))
       (%check-reduce-vec-element \"reduce-vec\" VEC P)
       (loop-vector-stride VEC (I) (set! P (FN P (~ VEC I))))
       (grid-reduce! FN P IDENTITY OUT-CELL :strategy STRATEGY ...scratch keys...))

   A literal #'op is applied directly (%175-apply-binop), so the fold is differentiable.  Refuses a
   multi-variable call (out of scope), a missing argument, a non-literal or unknown strategy (there is
   no second stage: it needs a second kernel launch) and a key the strategy does not use -- naming
   reduce-vec rather than leaving grid-reduce! to name itself.  The default strategy is
   :last-man-standing, as for grid-reduce!."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
    (unless (eq (%reduction-call-shape form) :single)
      (fail "reduce-vec: reduces ONE vector with one function, (reduce-vec fn vec identity out-cell &key strategy).  To reduce several variables at once, fold them yourself in a loop-vector-stride and pass them to grid-reduce! with clauses."))
    (unless (>= (length form) 5)
      (fail "reduce-vec: expected (reduce-vec fn vec identity out-cell &key strategy message), got ~s." form))
    (destructuring-bind (fn vec identity out &rest keys) (rest form)
      (unless (evenp (length keys))
        (fail "reduce-vec: the keyword arguments ~s are not key/value pairs." keys))
      (let* ((op (car form))
             (pkg (or (and (symbolp op) (symbol-package op)) (find-package :crisp-language)))
             (strategy-given (loop for (k v) on keys by #'cddr thereis (and (eq k :strategy) (list v))))
             (strategy (if strategy-given (first strategy-given) :last-man-standing))
             (entry nil))
        (unless (keywordp strategy)
          (fail "reduce-vec: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy))
        (setf entry (assoc strategy *176-grid-reduce-strategies*))
        (unless entry
          (fail "reduce-vec: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  There is no second-stage strategy: it needs a second kernel launch, which one call cannot arrange." strategy))
        (loop for (k nil) on keys by #'cddr
              unless (or (eq k :strategy) (member k (third entry)))
                do (fail "reduce-vec: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy (third entry)))
        (let* ((p (%reduce-vec-partial-name vec out pkg))
               (i (intern (format nil "~a-I" (symbol-name p)) pkg))
               (expansion
                 `(let ((,p ,identity))
                    (%check-reduce-vec-element "reduce-vec" ,vec ,p)
                    (loop-vector-stride ,vec (,i)
                      (set! ,p ,(%175-apply-binop fn p `(~ ,vec ,i))))
                    (,(intern "GRID-REDUCE!" pkg) ,fn ,p ,identity ,out ,@keys))))
          (log:debug "178: ~s -> ~s" form expansion)
          expansion)))))

;; src/analysis/ops.lisp
(defmacro reduce-vec (&whole form &rest args)
  "(reduce-vec fn vec identity out-cell &key strategy message ...): reduce every element of the rank-1
   VEC with binop FN and IDENTITY into OUT-CELL.  Each thread grid-strides VEC into a private partial;
   the partials go through grid-reduce! with :strategy (:atomic, :cas or :last-man-standing, the
   default) and the same optional scratch keys.  See %reduce-vec-expand."
  (declare (ignore args))
  (%reduce-vec-expand form))

;; OVERLAY ONLY -- on fold-back DELETE this block and add #:reduce-vec to the three package.lisp sites
;; (the :crisp.compiler export, the :crisp-language :import-from, the :crisp.main import) beside
;; #:grid-reduce!.  An overlay must not touch export lists (package variance at build time).
(let ((ccs (intern "REDUCE-VEC" (find-package :crisp.compiler)))
      (cls (intern "REDUCE-VEC" (find-package :crisp-language))))
  (unless (eq cls ccs)
    (setf (macro-function cls) (macro-function ccs))))

;; src/analysis/ops.lisp
(defun %analyze-check-reduce-vec-element (expr env context location)
  "Analyzer for (%check-reduce-vec-element OP-NAME VEC PARTIAL), which reduce-vec's expansion carries.
   VEC must be rank 1 (reduce-vec does not flatten matrices or tensors), and its element type must be
   the identity's -- the partial is seeded with the identity and folded with the elements, and the
   implicit scratch is typed from the identity, so a mismatch would reduce through mistyped memory.
   Emits nothing."
  (destructuring-bind (op-name vec partial) (rest expr)
    (let* ((vec-type (semantic-node-type (analyze-expression vec env context location)))
           (rank (%get-tensor-arity vec-type)))
      (log:debug "178: ~a over ~s : ~s (rank ~s)" op-name vec vec-type rank)
      (unless (eql rank 1)
        (error 'crisp-compiler-error
               :message (format nil "~a: ~s must be a vector (a rank-1 tensor), but its type ~s ~a.  reduce-vec does not flatten matrices or tensors."
                                op-name vec vec-type
                                (if rank (format nil "has rank ~d" rank) "is not a tensor"))
               :source-location location))
      (let ((elem (resolve-type-alias (semantic-node-type
                                       (analyze-expression `(~ ,vec 0) env context location))))
            (ptype (resolve-type-alias (semantic-node-type
                                        (analyze-expression partial env context location)))))
        (unless (if (and (symbolp elem) (symbolp ptype))
                    (string-equal (symbol-name elem) (symbol-name ptype))
                    (equal elem ptype))
          (error 'crisp-compiler-error
                 :message (format nil "~a: the elements of ~s are ~(~a~) but the identity is ~(~a~).  The identity must have the vector's element type -- write it as a ~(~a~)."
                                  op-name vec elem ptype elem)
                 :source-location location)))))
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

;; src/analysis/ops.lisp  (fold-back: add ("%CHECK-REDUCE-VEC-ELEMENT" %analyze-check-reduce-vec-element)
;; to the 175/176 pair list in register-ops-analyzers, and delete this wrapper)
(defvar *178-orig-register-ops-analyzers* (fdefinition 'register-ops-analyzers))
(defun register-ops-analyzers ()
  "Overlay wrapper (endeavour 178): the src registration, plus %check-reduce-vec-element under both packages."
  (funcall *178-orig-register-ops-analyzers*)
  (dolist (pkg (list (find-package :crisp.compiler) (find-package :crisp-language)))
    (setf (gethash (intern "%CHECK-REDUCE-VEC-ELEMENT" pkg) *expression-analyzers*)
          '%analyze-check-reduce-vec-element)))

;; 178: the check's op-name is a KEYWORD, not a string -- ANF cannot normalize a string literal
;; ("Unsupported form for anf-transform") under --differentiate.
;; src/analysis/ops.lisp
(defun %reduce-vec-expand (form)
  "Endeavour 178.  The expansion of (reduce-vec FN VEC IDENTITY OUT-CELL &key STRATEGY ...):

     (let ((P IDENTITY))
       (%check-reduce-vec-element :reduce-vec VEC P)
       (loop-vector-stride VEC (I) (set! P (FN P (~ VEC I))))
       (grid-reduce! FN P IDENTITY OUT-CELL :strategy STRATEGY ...scratch keys...))

   A literal #'op is applied directly (%175-apply-binop), so the fold is differentiable.  Refuses a
   multi-variable call (out of scope), a missing argument, a non-literal or unknown strategy (there is
   no second stage: it needs a second kernel launch) and a key the strategy does not use -- naming
   reduce-vec rather than leaving grid-reduce! to name itself.  The default strategy is
   :last-man-standing, as for grid-reduce!."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
    (unless (eq (%reduction-call-shape form) :single)
      (fail "reduce-vec: reduces ONE vector with one function, (reduce-vec fn vec identity out-cell &key strategy).  To reduce several variables at once, fold them yourself in a loop-vector-stride and pass them to grid-reduce! with clauses."))
    (unless (>= (length form) 5)
      (fail "reduce-vec: expected (reduce-vec fn vec identity out-cell &key strategy message), got ~s." form))
    (destructuring-bind (fn vec identity out &rest keys) (rest form)
      (unless (evenp (length keys))
        (fail "reduce-vec: the keyword arguments ~s are not key/value pairs." keys))
      (let* ((op (car form))
             (pkg (or (and (symbolp op) (symbol-package op)) (find-package :crisp-language)))
             (strategy-given (loop for (k v) on keys by #'cddr thereis (and (eq k :strategy) (list v))))
             (strategy (if strategy-given (first strategy-given) :last-man-standing))
             (entry nil))
        (unless (keywordp strategy)
          (fail "reduce-vec: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy))
        (setf entry (assoc strategy *176-grid-reduce-strategies*))
        (unless entry
          (fail "reduce-vec: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  There is no second-stage strategy: it needs a second kernel launch, which one call cannot arrange." strategy))
        (loop for (k nil) on keys by #'cddr
              unless (or (eq k :strategy) (member k (third entry)))
                do (fail "reduce-vec: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy (third entry)))
        (let* ((p (%reduce-vec-partial-name vec out pkg))
               (i (intern (format nil "~a-I" (symbol-name p)) pkg))
               (expansion
                 `(let ((,p ,identity))
                    (%check-reduce-vec-element :reduce-vec ,vec ,p)
                    (loop-vector-stride ,vec (,i)
                      (set! ,p ,(%175-apply-binop fn p `(~ ,vec ,i))))
                    (,(intern "GRID-REDUCE!" pkg) ,fn ,p ,identity ,out ,@keys))))
          (log:debug "178: ~s -> ~s" form expansion)
          expansion)))))


;; 178: op-name is now a keyword; print it lower-case.
;; src/analysis/ops.lisp
(defun %analyze-check-reduce-vec-element (expr env context location)
  "Analyzer for (%check-reduce-vec-element OP-NAME VEC PARTIAL), which reduce-vec's expansion carries.
   VEC must be rank 1 (reduce-vec does not flatten matrices or tensors), and its element type must be
   the identity's -- the partial is seeded with the identity and folded with the elements, and the
   implicit scratch is typed from the identity, so a mismatch would reduce through mistyped memory.
   Emits nothing."
  (destructuring-bind (op-name vec partial) (rest expr)
    (let* ((vec-type (semantic-node-type (analyze-expression vec env context location)))
           (rank (%get-tensor-arity vec-type)))
      (log:debug "178: ~a over ~s : ~s (rank ~s)" op-name vec vec-type rank)
      (unless (eql rank 1)
        (error 'crisp-compiler-error
               :message (format nil "~(~a~): ~s must be a vector (a rank-1 tensor), but its type ~s ~a.  reduce-vec does not flatten matrices or tensors."
                                op-name vec vec-type
                                (if rank (format nil "has rank ~d" rank) "is not a tensor"))
               :source-location location))
      (let ((elem (resolve-type-alias (semantic-node-type
                                       (analyze-expression `(~ ,vec 0) env context location))))
            (ptype (resolve-type-alias (semantic-node-type
                                        (analyze-expression partial env context location)))))
        (unless (if (and (symbolp elem) (symbolp ptype))
                    (string-equal (symbol-name elem) (symbol-name ptype))
                    (equal elem ptype))
          (error 'crisp-compiler-error
                 :message (format nil "~(~a~): the elements of ~s are ~(~a~) but the identity is ~(~a~).  The identity must have the vector's element type -- write it as a ~(~a~)."
                                  op-name vec elem ptype elem)
                 :source-location location)))))
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

;; src/macros.lisp
;; Endeavour 178: one new clause -- REDUCE-VEC is expanded here (then walked), because its expansion
;; CONTAINS a loop-vector-stride that this pre-pass must rewrite.  Left unexpanded, ANF later macroexpands
;; reduce-vec and meets the raw loop-vector-stride, and AD dies with "Function SET! is not differentiable".
(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites tensor-stride / grid-stride /
   loop-vector-stride / tile-stride / hardware-stride / workgroup-stride
   forms into their expansions.  Endeavor 113: also normalises
   request-load-tile-at -> load-tile-at and await-request -> nil
   for the backward pass."
  (cond
   ((atom form) form)
   ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%expand-stride-macros-in-form sub type-resolver-fn location)) form))
   (t
     (let ((op-name (symbol-name (car form))))
       (cond
        ((string-equal op-name "TENSOR-STRIDE")
          (%expand-tensor-stride-op form type-resolver-fn location))
        ((string-equal op-name "GRID-STRIDE")
          (%expand-grid-stride-op form type-resolver-fn location))
        ((string-equal op-name "LOOP-VECTOR-STRIDE")
          (%expand-loop-vector-stride-op form type-resolver-fn location))
        ((string-equal op-name "TILE-STRIDE")
          (%expand-tile-stride-op form type-resolver-fn location))
        ((string-equal op-name "HARDWARE-STRIDE")
          (%expand-hardware-stride-op form type-resolver-fn location))
        ((string-equal op-name "WORKGROUP-STRIDE")
          (%expand-workgroup-stride-op form type-resolver-fn location))
        ;; 178: reduce-vec hides a loop-vector-stride -- expand it, then walk the expansion.
        ((string-equal op-name "REDUCE-VEC")
          (log:debug "178: AD pre-pass expanding ~s" form)
          (%expand-stride-macros-in-form (%reduce-vec-expand form) type-resolver-fn location))
        ((string-equal op-name "LET")
          (%expand-let-stride-op form type-resolver-fn location))
        (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                    (cdr form)))))))))

;;;; ===========================================================================
;;;; Endeavour 178 -- BUG: a SET! of a scalar local inside a loop had NO backward.
;;;;
;;;; MEASURED on BMG (VERIFY-AUTODIFF): (let ((p 0.0)) (dotimes (i 8) (set! p (+ p (~ A i))))
;;;; (set! (~ out) p)) gave d out/dA[5] = 0.0 (FD: 1.0) -- for dotimes, for loop-vector-stride, and
;;;; through grid-reduce! (reduce-vec's whole expansion).  The SAME update outside a loop was right,
;;;; because BUG 100 versions top-level in-place writes into fresh bindings; a loop-carried variable
;;;; cannot be versioned, so its set! reached %gfw-process-set!, which handled only (set! (~ t ..) v)
;;;; and dropped (set! v x) on the floor.  The emitted backward loop body had t3 = p + t2's adjoint
;;;; rule but nothing feeding t3_adj, which is reset to zero every iteration -- a silent zero.
;;;;
;;;; THE RULE: v := x overwrites v, so  x_adj += v_adj ; v_adj := 0.
;;;;
;;;; THE LIMIT (refused, loudly): the backward replays a loop in FORWARD order and never re-runs the
;;;; loop's SET!s, so inside the backward loop a loop-carried variable holds a STALE primal.  The rule
;;;; above is exact when the body's derivatives never read that primal -- a linear fold (+, -), which
;;;; is all grid-reduce!'s VJPs accept.  A nonlinear fold (* p x, max) would read it, so
;;;; %ad-check-loop-carried-primals refuses it instead of producing a different wrong number.
;;;; ===========================================================================

;; src/autodiff.lisp
(defun %ad-literal-symbol-p (sym)
  "Endeavour 178.  T if SYM is a Crisp typed literal spelled as a symbol (2ul, 1.5f, -3.0d): the CL
   reader interns those as symbols, so they must not be given an adjoint."
  (and (symbolp sym)
       (let ((name (symbol-name sym)))
         (and (> (length name) 0)
              (or (digit-char-p (char name 0))
                  (and (> (length name) 1)
                       (member (char name 0) '(#\- #\+ #\.))
                       (digit-char-p (char name 1))))))))

;; src/autodiff.lisp
(defun %gfw-process-set! (form emit-fn local-adj-fn inputs outputs scratch-tile-syms intermediate-zero kernel-pkg)
  "Backward of a SET! statement.
     (set! (~ OUT i..) v)      -- OUT an output: v_adj += OUT_GRAD[i..]
     (set! (~ IN i..) v)       -- IN an input: refused (only outputs may be written)
     (set! (~ TILE i..) v)     -- a scratch tile: v_adj += TILE_ADJ[i..], then TILE_ADJ[i..] := 0
     (set! V x)                -- ENDEAVOUR 178: a scalar local.  x_adj += V_adj, then V_adj := 0
                                  (V is overwritten, so its adjoint before the write is zero).
   A scalar set! reaches here only where BUG 100's versioning could not turn it into a binding --
   in practice a LOOP-CARRIED variable; see %ad-check-loop-carried-primals for the limit."
  (let ((place (cadr form))
        (val (caddr form)))
    (cond
      ((and (consp place) (eq (car place) '~) (symbolp val))
       (let ((target (cadr place))
             (indices (cddr place)))
         (cond
           ((member target outputs)
            (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                    (symbol-package target))))
              (funcall emit-fn `(set! ,(funcall local-adj-fn val)
                                      (+ ,(funcall local-adj-fn val) (~ ,tgt-grad ,@indices))))))
           ((member target inputs)
            (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                   target target))
           ((and scratch-tile-syms (gethash target scratch-tile-syms))
            (let ((tgt-adj (%tlc-bwd-adj-name target inputs outputs local-adj-fn kernel-pkg)))
              (funcall emit-fn `(set! ,(funcall local-adj-fn val)
                                      (+ ,(funcall local-adj-fn val) (~ ,tgt-adj ,@indices))))
              (funcall emit-fn `(set! (~ ,tgt-adj ,@indices) ,intermediate-zero))))
           (t nil))))
      ;; 178: (set! V x) of a scalar local
      ((and place (symbolp place) (not (keywordp place)) (not (%ad-literal-symbol-p place))
            (not (member place inputs)) (not (member place outputs)))
       (unless (eq val place)                       ; (set! v v) is a no-op
         (let ((v-adj (funcall local-adj-fn place)))
           (when (and val (symbolp val) (not (keywordp val)) (not (%ad-literal-symbol-p val)))
             (let ((x-adj (funcall local-adj-fn val)))
               (log:debug "178: scalar set! ~a := ~a -> ~a += ~a ; ~a := 0" place val x-adj v-adj v-adj)
               (funcall emit-fn `(set! ,x-adj (+ ,x-adj ,v-adj)))))
           (funcall emit-fn `(set! ,v-adj ,intermediate-zero)))))
      (t nil))))

;; src/autodiff.lisp
(defun %ad-loop-carried-tainted (body local-vars)
  "Endeavour 178.  The variables of a loop BODY whose value depends on a LOOP-CARRIED one: every
   symbol a scalar SET! in BODY writes that is not bound inside the loop (not in LOCAL-VARS), closed
   over the body's bindings -- a binding (x e) whose E mentions a tainted symbol taints X."
  (let ((tainted '()))
    (labels ((walk-sets (f)
               (when (consp f)
                 (when (and (symbolp (car f)) (string-equal (symbol-name (car f)) "SET!")
                            (symbolp (second f)) (second f) (not (keywordp (second f)))
                            (not (member (second f) local-vars)))
                   (pushnew (second f) tainted))
                 (mapc #'walk-sets (cdr f))))
             (mentions-p (e)
               (cond ((symbolp e) (member e tainted))
                     ((consp e) (or (mentions-p (car e)) (mentions-p (cdr e))))
                     (t nil)))
             (spread (f)
               ;; returns T if it tainted something new
               (let ((changed nil))
                 (when (consp f)
                   (when (and (= (length f) 2) (symbolp (car f)) (car f)
                              (not (member (car f) tainted)) (mentions-p (second f)))
                     (push (car f) tainted) (setf changed t))
                   (when (and (symbolp (car f)) (string-equal (symbol-name (car f)) "SET!")
                              (symbolp (second f)) (not (member (second f) tainted))
                              (mentions-p (third f)))
                     (push (second f) tainted) (setf changed t))
                   (dolist (sub (if (listp (cdr f)) (cdr f) nil))
                     (when (spread sub) (setf changed t)))
                   (when (consp (car f)) (when (spread (car f)) (setf changed t))))
                 changed)))
      (mapc #'walk-sets body)
      (when tainted
        (loop while (some #'identity (mapcar #'spread body)))))
    tainted))

;; src/autodiff.lisp
(defun %ad-stale-primal-reads (forms tainted)
  "Endeavour 178.  The TAINTED primal symbols the emitted backward FORMS read outside a LET binding's
   value (where the primal replay recomputes them).  Head positions are skipped: they name operators."
  (let ((found '()))
    (labels ((walk (f)
               (cond
                 ((symbolp f) (when (member f tainted) (pushnew f found)))
                 ((consp f)
                  (if (and (symbolp (car f)) (string-equal (symbol-name (car f)) "LET")
                           (listp (second f)))
                      (mapc #'walk (cddr f))             ; skip the replayed binding values
                      (mapc #'walk (if (listp (cdr f)) (cdr f) nil)))))))
      (mapc #'walk forms))
    found))

;; src/autodiff.lisp
(defun %ad-check-loop-carried-primals (binding body local-vars backward-forms)
  "Endeavour 178.  Refuse a loop whose backward body reads a loop-carried primal.  The backward
   replays a loop in FORWARD order and does not re-run the loop's SET!s, so such a primal is STALE:
   the gradient would be silently wrong.  A linear fold (p := p + x) reads none and passes."
  (let ((tainted (%ad-loop-carried-tainted body local-vars)))
    (when tainted
      (let ((stale (%ad-stale-primal-reads backward-forms tainted)))
        (log:debug "178: loop ~a carries ~a; backward reads ~a" binding tainted stale)
        (when stale
          (error 'crisp-compiler-error
                 :message (format nil "Cannot differentiate this loop: ~{~(~a~)~^, ~} ~:[is~;are~] updated by set! across iterations (loop ~(~s~)), and the gradient of the loop body depends on ~:[its~;their~] value at each iteration.  The backward pass replays a loop without those per-iteration values, so the gradient would be wrong.  A running sum (set! p (+ p x)) is supported; a running product, min or max is not yet."
                                  stale (cdr stale) binding (cdr stale))
                 :source-location nil))))))

;; src/autodiff.lisp
(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  "Unchanged except that it publishes the loop variable in *ad-loop-vars* while walking the
   body, so a VJP dispatched inside can ask what coordinate it is being evaluated at.  A
   pipelined ring operand needs this: its primal lives at the CONSUMING iteration, and the
   forward's load sites record other stages' origins.

   ENDEAVOUR 149: a tile re-staged each iteration has no single primal value, so its replay
   belongs HERE -- inside the loop body, ahead of the consumers, evaluated afresh for each
   value of the loop variable.  That falls out of emitting at this scope: the replayed
   statements close over BINDING exactly as the forward's did.

   ENDEAVOUR 172: emits the forward loop's own head (less any +), so a dec-times / by-factor /
   power-step loop replays with its own iteration sequence rather than as a dotimes.

   ENDEAVOUR 178: refuses a loop whose backward body would read a STALE loop-carried primal
   (%ad-check-loop-carried-primals) -- a nonlinear fold over a variable set! across iterations."
  (let ((local-forms nil)
        (inherited-replay-requests (copy-list *ad-replay-pending*))
        (*ad-loop-vars* (if (and (consp binding) (symbolp (car binding)))
                            (cons (car binding) *ad-loop-vars*)
                            *ad-loop-vars*)))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit)))
    (%ad-check-loop-carried-primals binding body local-vars local-forms)
    (let ((zero-resets
           (loop for v in local-vars
                 for adv = (gethash v adjoint-map)
                   when adv
                 collect `(set! ,adv ,intermediate-zero)))
          (replay (%ad-replay-forms-for-scope body inherited-replay-requests)))
      (funcall emit-fn `(,(%dotimes-backward-head (car form)) ,binding ,@zero-resets ,@replay ,@(nreverse local-forms))))))

;; 178: cl:char, not char -- in :crisp.compiler CHAR is the Crisp type ("undefined function").
;; src/autodiff.lisp
(defun %ad-literal-symbol-p (sym)
  "Endeavour 178.  T if SYM is a Crisp typed literal spelled as a symbol (2ul, 1.5f, -3.0d): the CL
   reader interns those as symbols, so they must not be given an adjoint."
  (and (symbolp sym)
       (let ((name (symbol-name sym)))
         (and (> (length name) 0)
              (or (digit-char-p (cl:char name 0))
                  (and (> (length name) 1)
                       (member (cl:char name 0) '(#\- #\+ #\.))
                       (digit-char-p (cl:char name 1))))))))

;; src/anf-transform.lisp
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

;; 178: print the loop binding unpretty -- the pretty printer broke the message across lines.
;; src/autodiff.lisp
(defun %ad-check-loop-carried-primals (binding body local-vars backward-forms)
  "Endeavour 178.  Refuse a loop whose backward body reads a loop-carried primal.  The backward
   replays a loop in FORWARD order and does not re-run the loop's SET!s, so such a primal is STALE:
   the gradient would be silently wrong.  A linear fold (p := p + x) reads none and passes."
  (let ((tainted (%ad-loop-carried-tainted body local-vars)))
    (when tainted
      (let ((stale (%ad-stale-primal-reads backward-forms tainted)))
        (log:debug "178: loop ~a carries ~a; backward reads ~a" binding tainted stale)
        (when stale
          (error 'crisp-compiler-error
                 :message (format nil "Cannot differentiate this loop: ~{~(~a~)~^, ~} ~:[is~;are~] updated by set! across iterations (loop ~(~a~)), and the gradient of the loop body depends on ~:[its~;their~] value at each iteration.  The backward pass replays a loop without those per-iteration values, so the gradient would be wrong.  A running sum (set! p (+ p x)) is supported; a running product, min or max is not yet."
                                  stale (cdr stale) (write-to-string binding :pretty nil) (cdr stale))
                 :source-location nil))))))
