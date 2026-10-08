;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-03 -- endeavour 178 (reduce-vec) folded into src/:
;;;;   * reduce-vec                          -> %reduce-vec-partial-name, %reduce-vec-expand, defmacro reduce-vec,
;;;;                                            %analyze-check-reduce-vec-element (src/analysis/ops.lisp), registered
;;;;                                            in register-ops-analyzers' pair list; #:reduce-vec exported from
;;;;                                            :crisp.compiler and imported by :crisp-language (src/package.lisp),
;;;;                                            replacing the overlay's MACRO-FUNCTION copy and wrapper
;;;;   * AD pre-pass expands REDUCE-VEC      -> %expand-stride-macros-in-form (src/macros.lisp)
;;;;   * BUG 103/105 loop-carried set!       -> %ad-literal-symbol-p, %ad-loop-carried-tainted, %ad-stale-primal-reads,
;;;;                                            %ad-check-loop-carried-primals, %gfw-process-set!, %gfw-process-dotimes
;;;;                                            (src/autodiff.lisp)
;;;;   * BUG 104 strings are ANF-atomic      -> anf-is-atomic? (src/anf-transform.lisp)

(in-package :crisp.compiler)

;;;; ===========================================================================================
;;;; Endeavour 180 -- loop unrolling.  tests/spec/180-loop-unroll/loop-unroll.md
;;;;
;;;;   (dotimes (k n) (declare (unroll 4)) ...)      unroll by 4, LLVM adds the remainder loop
;;;;   (dotimes (k 8) (declare (unroll t)) ...)      unroll fully (constant trip count only)
;;;;   (loop-vector-stride v (i) (declare (unroll nil)) ...)   never unroll
;;;;   (reduce-vec #'+ v 0.0 out :unroll 2)          passed to its loop-vector-stride
;;;;
;;;; Unrolling is CODEGEN ONLY: the declaration becomes !llvm.loop metadata on the loop's latch
;;;; branch and LLVM does the work.  The analyzer strips the declaration off the body and records it
;;;; on the node (semantic-dotimes-unroll); ANF and AD see the declaration as an inert form.
;;;; loop-vector-stride with no declaration gets the STREAM DEFAULT: a byte budget in flight per
;;;; thread, per target (*stream-unroll-bytes-in-flight*).
;;;; ===========================================================================================

;; src/analysis/control.lisp
(defun %declaration-spec-named-p (spec name)
  "Endeavour 180.  T when SPEC, one spec of a (declare ...) form, is a list headed by a symbol
   named NAME (compared by name, so the reading package does not matter)."
  (and (consp spec) (symbolp (car spec)) (string-equal (symbol-name (car spec)) name)))

;; src/analysis/control.lisp
(defun %parse-unroll-spec (spec head location)
  "Endeavour 180.  Parses one (unroll V) declaration SPEC on the loop headed HEAD.  V is a positive
   integer literal (unroll by V), t (unroll fully) or nil (never unroll).  Returns (:count V),
   (:full) or (:disable); anything else is a compile error."
  (unless (and (consp (cdr spec)) (null (cddr spec)))
    (error 'crisp-compiler-error
      :message (format nil "~(~a~): malformed unroll declaration ~s -- expected (unroll N), (unroll t) or (unroll nil)."
                       head spec)
      :source-location location))
  (let ((v (second spec)))
    (cond ((and (integerp v) (plusp v)) (list :count v))
          ((and (symbolp v) (string= (symbol-name v) "T")) (list :full))
          ((and (symbolp v) (string= (symbol-name v) "NIL")) (list :disable))
          (t (error 'crisp-compiler-error
               :message (format nil "~(~a~): in (unroll ~s), the unroll factor must be a positive integer literal, t (unroll fully) or nil (never unroll)."
                                head v)
               :source-location location)))))

;; src/analysis/control.lisp
(defun %split-loop-body-declarations (body-forms head location)
  "Endeavour 180.  Splits the leading (declare ...) forms off a counted loop's BODY-FORMS.  A loop
   body accepts ONE declaration: (unroll V) -- or (%unroll-default VEC), which only
   loop-vector-stride's expansion writes.  Any other declaration, or a second unroll, is a compile
   error naming the loop HEAD.  Returns (values remaining-body spec), where spec is NIL (none),
   (:count N), (:full), (:disable) or (:stream VEC-FORM)."
  (let* ((decls (loop for f in body-forms
                      while (and (consp f) (symbolp (car f))
                                 (string-equal (symbol-name (car f)) "DECLARE"))
                      collect f))
         (rest (nthcdr (length decls) body-forms))
         (spec nil))
    (dolist (s (loop for d in decls append (rest d)))
      (cond
       ((%declaration-spec-named-p s "UNROLL")
        (when (and spec (not (eq (first spec) :stream)))
          (error 'crisp-compiler-error
            :message (format nil "~(~a~): more than one unroll declaration on one loop -- write one (unroll ...)."
                             head)
            :source-location location))
        (setf spec (%parse-unroll-spec s head location)))
       ((%declaration-spec-named-p s "%UNROLL-DEFAULT")
        (unless spec (setf spec (list :stream (second s)))))
       (t
        (error 'crisp-compiler-error
          :message (format nil "~(~a~): only (unroll ...) may be declared at the start of a loop body, but found (declare ~s)."
                           head s)
          :source-location location))))
    (log:debug "180: ~a body declarations ~s -> unroll ~s" head decls spec)
    (values rest spec)))

;; src/analysis/control.lisp
(defun %loop-trip-count-constant-p (node)
  "Endeavour 180.  T when every operand of the counted loop NODE (a semantic-dotimes or
   semantic-loop-variant) is a literal, so its trip count is known at compile time."
  (flet ((lit-or-absent (n) (or (null n) (semantic-literal-p n))))
    (and (lit-or-absent (semantic-dotimes-limit-node node))
         (lit-or-absent (semantic-dotimes-stride-node node))
         (or (not (semantic-loop-variant-p node))
             (and (lit-or-absent (semantic-loop-variant-init-node node))
                  (lit-or-absent (semantic-loop-variant-factor-node node)))))))

;; src/analysis/control.lisp
(defun %stream-element-bytes (vec-form env context location)
  "Endeavour 180.  The size in bytes of VEC-FORM's element type, or NIL when it is not a
   registered scalar type (a struct element, say).  Used for loop-vector-stride's stream default;
   never an error -- an unknown size only means no default."
  (handler-case
      (let* ((elem (resolve-type-alias
                    (semantic-node-type
                     (analyze-expression (list (intern "~" (find-package :crisp-language)) vec-form 0)
                                         env context location))))
             (ct (and (symbolp elem) (gethash elem *crisp-types*)))
             (bits (and ct (crisp-type-size ct))))
        (when (and bits (plusp bits)) (ceiling bits 8)))
    (error (e)
      (log:debug "180: no stream default for ~s -- element size unknown (~a)" vec-form e)
      nil)))

;; src/analysis/control.lisp
(defun %resolve-unroll-spec (spec node head env context location)
  "Endeavour 180.  Turns the parsed SPEC of the loop NODE into what the node keeps: checks that
   (unroll t) has a constant trip count, and sizes the stream default from the vector's element
   type -- (:stream VEC-FORM) becomes (:stream BYTES), or NIL when the size is unknown."
  (ecase (first spec)
    ((:count :disable) spec)
    (:full
     (unless (%loop-trip-count-constant-p node)
       (error 'crisp-compiler-error
         :message (format nil "~(~a~): (unroll t) unrolls a loop fully, so its trip count must be a compile-time constant -- here it is computed at run time.  Use (unroll N) for a factor."
                          head)
         :source-location location))
     spec)
    (:stream
     (let ((bytes (%stream-element-bytes (second spec) env context location)))
       (when bytes (list :stream bytes))))))

;; src/analysis/control.lisp
(defun %analyze-loop-with-unroll (analyzer expr env context location)
  "Endeavour 180.  Runs the counted-loop ANALYZER on EXPR with its body's leading declarations
   stripped, then records the unroll request on the node it returns.  The loop's own analysis
   never sees a declaration."
  (multiple-value-bind (body spec)
      (%split-loop-body-declarations (cddr expr) (car expr) location)
    (let ((node (funcall analyzer
                         (if (eq body (cddr expr)) expr (list* (car expr) (cadr expr) body))
                         env context location)))
      (when (and spec (semantic-dotimes-p node))
        (setf (semantic-dotimes-unroll node)
              (%resolve-unroll-spec spec node (car expr) env context location)))
      node)))

;; src/analysis/control.lisp -- fold: strip the declarations inside analyze-dotimes-expression itself.
(defvar *180-analyze-dotimes-expression* (fdefinition 'analyze-dotimes-expression)
  "Endeavour 180 overlay: the pre-180 dotimes analyzer, wrapped by the redefinition below.")

;; src/analysis/control.lisp
(defun analyze-dotimes-expression (expr env context location)
  "Analyzes (dotimes (var limit [stride]) body...).
   VAR is bound as the limit's type (int, ulong, etc.) in the body.
   STRIDE is optional; defaults to literal 1 of the limit's type.
   Endeavour 180: a leading (declare (unroll ...)) in the body is the loop's unroll request.
   Returns a semantic-dotimes node (type void)."
  (%analyze-loop-with-unroll *180-analyze-dotimes-expression* expr env context location))

;; src/analysis/control.lisp -- fold: strip the declarations inside analyze-loop-variant-expression itself.
(defvar *180-analyze-loop-variant-expression* (fdefinition 'analyze-loop-variant-expression)
  "Endeavour 180 overlay: the pre-180 loop-variant analyzer, wrapped by the redefinition below.")

;; src/analysis/control.lisp
(defun analyze-loop-variant-expression (expr env context location)
  "Analyzes a dotimes-family variant (dec-times, do-times-by-doubling, ... and the + forms;
   endeavour 172).  Endeavour 180: a leading (declare (unroll ...)) in the body is the loop's
   unroll request.  Returns a semantic-loop-variant."
  (%analyze-loop-with-unroll *180-analyze-loop-variant-expression* expr env context location))

;; src/analysis/control.lisp
(defun %check-context-declarations (decl-specs location)
  "Checks DECL-SPECS for (grid-level) and (workgroup-level) declarations.
   Enforces that:
   - (grid-level) requires *in-dispatch-context* and cannot be nested.
   - (workgroup-level) cannot be nested inside another workgroup-level context.
   - (unroll ...) is refused (endeavour 180): it belongs to a loop body, and a let used to drop it
     silently.
   Returns (values has-grid-level has-workgroup-level)."
  (let ((has-grid-level (find "GRID-LEVEL" decl-specs
                          :key (lambda (x) (when (consp x) (symbol-name (car x))))
                          :test #'string-equal))
        (has-workgroup-level (find "WORKGROUP-LEVEL" decl-specs
                               :key (lambda (x) (when (consp x) (symbol-name (car x))))
                               :test #'string-equal)))

    (when (find-if (lambda (s) (%declaration-spec-named-p s "UNROLL")) decl-specs)
      (%refuse-misplaced-unroll location))

    (when has-grid-level
          (unless *in-dispatch-context*
            (error 'crisp-compiler-error
              :message "Grid-level context cannot appear in a thread-level function. A dispatch context (def-kernel or def-grid-function) is required."
              :source-location location))
          (when *in-grid-level-context*
                (error 'crisp-compiler-error
                  :message "Grid-level contexts cannot be nested. Sequential usage is allowed but nesting is not."
                  :source-location location)))

    (when has-workgroup-level
          (when *in-workgroup-level-context*
                (error 'crisp-compiler-error
                  :message "Workgroup-level contexts cannot be nested inside another workgroup-level context."
                  :source-location location)))

    (values has-grid-level has-workgroup-level)))

;; src/analysis/control.lisp
(defun %refuse-misplaced-unroll (location)
  "Endeavour 180.  The error for a (declare (unroll ...)) anywhere but the head of a loop body."
  (error 'crisp-compiler-error
    :message "(declare (unroll ...)) is allowed only at the start of a loop body -- dotimes and its variants, or loop-vector-stride."
    :source-location location))

;; src/analysis/control.lisp
(defun analyze-declare-expression (expr env context location)
  "Endeavour 180.  A (declare ...) analyzed as an expression is out of place: declarations are
   taken off the head of a let, a function or a loop body before the body is analyzed.  An
   unroll declaration gets its own message; any other is the unsupported form it always was."
  (declare (ignore env context))
  (if (find-if (lambda (s) (%declaration-spec-named-p s "UNROLL")) (rest expr))
      (%refuse-misplaced-unroll location)
      (error 'crisp-unsupported-form-error :form (car expr) :source-location (append location '(0)))))

;; src/analysis/control.lisp -- fold: add the DECLARE registration to register-control-analyzers.
(defvar *180-register-control-analyzers* (fdefinition 'register-control-analyzers)
  "Endeavour 180 overlay: the pre-180 register-control-analyzers, wrapped below.")

;; src/analysis/control.lisp
(defun register-control-analyzers ()
  "Registers the control-flow analyzers (see the pre-180 definition).  Endeavour 180 adds DECLARE,
   so a misplaced (declare (unroll ...)) is named rather than reported as an unsupported form."
  (funcall *180-register-control-analyzers*)
  (dolist (pkg (list (find-package :crisp-language) (find-package :crisp.compiler)))
    (setf (gethash (intern "DECLARE" pkg) *expression-analyzers*) #'analyze-declare-expression)))

;; src/codegen.lisp
(defparameter *stream-unroll-bytes-in-flight* '((:spirv . 16) (:ptx . nil))
  "Endeavour 180.  The loop-vector-stride stream default, per target: the bytes each thread should
   have in flight, so the unroll factor is BYTES / element size.  MEASURED, not guessed
   (loop-unroll.md, probes 1, 2 and 4):
     :spirv  16 -- BMG reaches ~99% of the read peak at 16 bytes/thread (fp32 x4, fp64 x2); one
                   load per trip (4 bytes) reaches 57%.  More never hurt, and gained < 1%.
     :ptx    NIL -- no hint.  LLVM's NVPTX target already runtime-unrolls the loop x4 and ptxas
                   unrolls again (16 loads per trip in SASS); a hint would leave the unrolled loop
                   marked unroll.disable, which reaches the PTX as .pragma \"nounroll\" and stops
                   ptxas -- a regression, not a default.
   A target not listed gets no default.")

;; src/codegen.lisp
(defparameter *stream-unroll-max-factor* 8
  "Endeavour 180.  The largest factor the stream default picks.  Probe 1 measured up to x8; a
   1-byte element would otherwise ask for x16, which no probe has run.")

;; src/codegen.lisp
(defun %effective-loop-unroll (spec)
  "Endeavour 180.  What the codegen emits for a loop's unroll SPEC on the current *target-backend*:
   (values :count N), (values :full), (values :disable), or NIL for no metadata.  An explicit
   request is emitted as written on every target; the stream default, (:stream BYTES), is a factor
   only where *stream-unroll-bytes-in-flight* gives a budget and the factor is above 1."
  (case (first spec)
    (:count (values :count (second spec)))
    (:full (values :full))
    (:disable (values :disable))
    (:stream
     (let* ((budget (cdr (assoc *target-backend* *stream-unroll-bytes-in-flight*)))
            (bytes (second spec))
            (n (and budget bytes (plusp bytes)
                    (min *stream-unroll-max-factor* (max 1 (floor budget bytes))))))
       (log:debug "180: stream default on ~s, ~a-byte elements, budget ~a -> x~a"
                  *target-backend* bytes budget n)
       (when (and n (> n 1)) (values :count n))))
    (t nil)))

;; src/codegen.lisp
(defun %attach-loop-unroll-metadata (latch-br module spec)
  "Endeavour 180.  Attaches !llvm.loop to LATCH-BR, a loop's back-edge branch, for the unroll SPEC
   (see %effective-loop-unroll).  The loop ID is LLVM's distinct, self-referential node:
     !L = distinct !{!L, !P}     !P = !{!\"llvm.loop.unroll.count\", i32 N}   (or .full / .disable)
   LLVM-C cannot create a distinct node directly, so operand 0 starts as a temporary placeholder
   that is then replaced with the node itself -- which LLVM turns into a distinct node.  Returns
   LATCH-BR."
  (multiple-value-bind (kind n) (%effective-loop-unroll spec)
    (when kind
      (let* ((ctx (crisp.llvm-bindings::llvm-get-module-context module))
             (prop-name (ecase kind
                          (:count "llvm.loop.unroll.count")
                          (:full "llvm.loop.unroll.full")
                          (:disable "llvm.loop.unroll.disable")))
             (prop (cffi:with-foreign-object (ops :pointer 2)
                     (setf (cffi:mem-aref ops :pointer 0)
                           (crisp.llvm-bindings::llvm-md-string-in-context2 ctx prop-name (length prop-name)))
                     (when (eq kind :count)
                       (setf (cffi:mem-aref ops :pointer 1)
                             (crisp.llvm-bindings::llvm-value-as-metadata
                              (crisp.llvm-bindings::llvm-const-int (crisp.llvm-bindings::llvm-int32-type) n nil))))
                     (crisp.llvm-bindings::llvm-md-node-in-context2 ctx ops (if (eq kind :count) 2 1))))
             (temp (crisp.llvm-bindings::llvm-temporary-md-node ctx (cffi:null-pointer) 0))
             (loop-id (cffi:with-foreign-object (ops :pointer 2)
                        (setf (cffi:mem-aref ops :pointer 0) temp
                              (cffi:mem-aref ops :pointer 1) prop)
                        (crisp.llvm-bindings::llvm-md-node-in-context2 ctx ops 2)))
             (kind-id (crisp.llvm-bindings::llvm-get-md-kind-id-in-context ctx "llvm.loop" 9)))
        (crisp.llvm-bindings::llvm-metadata-replace-all-uses-with temp loop-id)
        (crisp.llvm-bindings::llvm-set-metadata
         latch-br kind-id (crisp.llvm-bindings::llvm-metadata-as-value ctx loop-id))
        (log:debug "180: !llvm.loop ~a~@[ ~a~] on a latch (~s)" prop-name n *target-backend*))))
  latch-br)

;; src/analysis/control.lisp
(defun %expand-loop-vector-stride-form (expr location)
  "Pure expansion of (loop-vector-stride VEC (VAR) BODY...).
   Refactored to use %build-exact-iter-count-form for consistency with
   the rest of Group A.  Same behaviour as the earlier rewrite — single
   counter dotimes, body runs unconditionally.
   Endeavour 180: leading (declare ...) forms of BODY belong to the LOOP, so they move to the head
   of the dotimes body, where (declare (unroll ...)) is understood.  With no unroll declaration the
   dotimes gets (declare (%unroll-default VEC)) -- the stream default, sized by VEC's element type
   when the dotimes is analyzed.  (unroll t) is refused here: the trip count depends on the
   vector's length and the grid, so it is never a compile-time constant."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
      :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
      :source-location location))
  (let* ((vec-form (second expr))
         (var-name (first (third expr)))
         (loop-decls (loop for f in (cdddr expr)
                           while (and (consp f) (symbolp (car f))
                                      (string-equal (symbol-name (car f)) "DECLARE"))
                           collect f))
         (body-forms (nthcdr (length loop-decls) (cdddr expr)))
         (unroll-specs (loop for d in loop-decls
                             append (remove-if-not (lambda (s)
                                                     (and (consp s) (symbolp (car s))
                                                          (string-equal (symbol-name (car s)) "UNROLL")))
                                                   (rest d))))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (iters-sym (gensym "ITERS"))
         (k-sym (gensym "K"))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
         (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (i-binding (list var-name
                          (list plus-sym gid-sym
                                (list mul-sym k-sym gsize-sym))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let (list let-sym (list i-binding) inner-body))
         (dotimes-form (list* dotimes-sym (list k-sym iters-sym)
                              (append loop-decls
                                      (unless unroll-specs
                                        (list (list declare-sym
                                                    (list (intern "%UNROLL-DEFAULT" cl-pkg) vec-form))))
                                      (list inner-let))))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       gid-sym gsize-sym len-sym cl-pkg)))
                          dotimes-form))
         (expansion (list let-sym
                          (list (list gid-sym (list get-gid-sym 0))
                                (list gsize-sym (list get-gsize-sym 0))
                                (list len-sym (list len-tilde-sym vec-form)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    (when (find-if (lambda (s) (and (= (length s) 2) (symbolp (second s))
                                    (string-equal (symbol-name (second s)) "T")))
                   unroll-specs)
      (error 'crisp-compiler-error
        :message "loop-vector-stride: (unroll t) unrolls a loop fully, so its trip count must be a compile-time constant -- a loop-vector-stride's depends on the vector's length and the grid.  Use (unroll N) for a factor."
        :source-location location))
    (log:debug "180: loop-vector-stride over ~s, loop declarations ~s~:[, stream default~;~]"
               vec-form loop-decls unroll-specs)
    expansion))

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
   :last-man-standing, as for grid-reduce!.
   Endeavour 180: :unroll V is the loop's, not grid-reduce!'s -- it becomes (declare (unroll V)) at
   the head of the loop-vector-stride body, which validates V.  Without it the loop gets the
   loop-vector-stride stream default."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
    (unless (eq (%reduction-call-shape form) :single)
      (fail "reduce-vec: reduces ONE vector with one function, (reduce-vec fn vec identity out-cell &key strategy).  To reduce several variables at once, fold them yourself in a loop-vector-stride and pass them to grid-reduce! with clauses."))
    (unless (>= (length form) 5)
      (fail "reduce-vec: expected (reduce-vec fn vec identity out-cell &key strategy message), got ~s." form))
    (destructuring-bind (fn vec identity out &rest all-keys) (rest form)
      (unless (evenp (length all-keys))
        (fail "reduce-vec: the keyword arguments ~s are not key/value pairs." all-keys))
      (let* ((unroll-given (loop for (k v) on all-keys by #'cddr thereis (and (eq k :unroll) (list v))))
             ;; Endeavour 180: :unroll belongs to the loop-vector-stride, never to grid-reduce!.
             (keys (loop for (k v) on all-keys by #'cddr unless (eq k :unroll) append (list k v)))
             (op (car form))
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
                      ,@(when unroll-given
                          `((,(intern "DECLARE" pkg) (,(intern "UNROLL" pkg) ,(first unroll-given)))))
                      (set! ,p ,(%175-apply-binop fn p `(~ ,vec ,i))))
                    (,(intern "GRID-REDUCE!" pkg) ,fn ,p ,identity ,out ,@keys))))
          (log:debug "178: ~s -> ~s" form expansion)
          expansion)))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-dotimes) builder module var-env di-builder di-scope location-map)
  "Generates IR for (dotimes (var limit [stride]) body...).
   Uses alloca+branch loop pattern (consistent with semantic-if).
   LLVM mem2reg promotes the alloca to a phi node during optimization.
   Endeavour 180: the back-edge branch carries !llvm.loop when the loop has an unroll request
   (%attach-loop-unroll-metadata)."
  (let* ((limit-node  (semantic-dotimes-limit-node node))
         (stride-node (semantic-dotimes-stride-node node))
         (var-name    (semantic-dotimes-var-name node))
         (body        (semantic-dotimes-body node))
         ;; Determine LLVM type and signed/unsigned comparison from limit type
         (limit-type  (get-single-value-type limit-node))
         (limit-ct    (gethash limit-type *crisp-types*))
         (is-unsigned (and limit-ct (eq (crisp-type-category limit-ct) :unsigned-int)))
         (cmp-pred    (if is-unsigned +llvm-int-ult+ +llvm-int-slt+))
         (llvm-type   (crisp-type-to-llvm-type limit-type module))
         ;; Current function
         (current-fn  (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         ;; Generate limit value in current block
         (limit-val   (generate-node-ir limit-node builder module var-env di-builder di-scope location-map))
         ;; Generate stride value (or constant 1)
         (stride-val  (if stride-node
                          (generate-node-ir stride-node builder module var-env di-builder di-scope location-map)
                          (llvm-const-int llvm-type 1 0)))
         ;; Endeavour 172 -- BUG: (dotimes (i n 0) ...) never terminated.  A stride that cannot
         ;; advance the loop variable runs ZERO iterations rather than spinning forever.  Folds
         ;; away for the constant strides that every existing dotimes has.
         (stride-ok   (llvm-build-icmp builder (if is-unsigned +llvm-int-ne+ +llvm-int-sgt+)
                                       stride-val (llvm-const-int llvm-type 0 0) "dt_stride_ok"))
         ;; Alloca for the loop variable; initialize to 0
         (i-alloca    (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
         (_           (llvm-build-store builder (llvm-const-int llvm-type 0 0) i-alloca))
         ;; Basic blocks
         (check-block (llvm-append-basic-block current-fn "dt_check"))
         (body-block  (llvm-append-basic-block current-fn "dt_body"))
         (exit-block  (llvm-append-basic-block current-fn "dt_exit")))
    (declare (ignore _))
    ;; Branch from current block into loop check -- but only if the stride can advance it
    (llvm-build-cond-br builder stride-ok check-block exit-block)
    ;; --- Check Block: if i < limit goto body else goto exit ---
    (llvm-position-builder-at-end builder check-block)
    (let* ((i-val   (llvm-build-load2 builder llvm-type i-alloca "i"))
           (cond-v  (llvm-build-icmp builder cmp-pred i-val limit-val "dt_cond")))
      (llvm-build-cond-br builder cond-v body-block exit-block))
    ;; --- Body Block ---
    (llvm-position-builder-at-end builder body-block)
    (let ((body-env (alexandria:copy-hash-table var-env)))
      ;; Expose the loop variable via the alloca so var-read loads from it
      (setf (gethash var-name body-env) i-alloca)
      ;; Generate body expressions
      (dolist (body-node body)
        (generate-node-ir body-node builder module body-env di-builder di-scope location-map))
      ;; Increment: i += stride
      (let* ((i-cur  (llvm-build-load2 builder llvm-type i-alloca "i_cur"))
             (i-next (llvm-build-add builder i-cur stride-val "i_next")))
        (llvm-build-store builder i-next i-alloca)))
    ;; Branch back to check (unless body already terminated, e.g. explicit return)
    ;; Endeavour 180: the back-edge is the loop's latch -- it carries the unroll request, if any.
    (unless (terminator-p (llvm-get-insert-block builder))
      (%attach-loop-unroll-metadata (llvm-build-br builder check-block) module
                                    (semantic-dotimes-unroll node)))
    ;; --- Exit Block ---
    (llvm-position-builder-at-end builder exit-block)
    ;; dotimes returns void
    (values nil nil)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-loop-variant) builder module var-env di-builder di-scope location-map)
  "Generates a dotimes-variant loop (endeavour 172) as a GUARDED, BOTTOM-TESTED loop:
     entry:  operands; GUARD -> pre | exit      (runtime D3 gates: bad operands = zero trips)
     pre:    start value, loop invariants; -> body   (divisions happen only past the guard)
     body:   BODY; next = step(i); cont = test(i) -> body | exit
   Every step is overflow-safe, so termination does not depend on the operand values:
     :dec-times      guard N/=0, s/=0   start ((N-1)/s)*s      cont i >= s       next i - s
     :dec-by-factor  guard N/=0, f>1    start N                cont next /= 0    next i / f
     :multiply       guard init/=0, f>1, init<=N; lim = N/f;   cont i <= lim     next i * f
     :power-up       guard N>1          start 1, lim=(N-1)/2   cont i <= lim     next i * 2
     :power-down     guard N>1          start 2^(W-1-clz(N-1)) cont next /= 0    next i / 2
   The loop variable lives in an alloca (mem2reg promotes it), as in dotimes.
   Endeavour 180: the latch branch carries !llvm.loop when the loop has an unroll request."
  (let* ((kind (semantic-loop-variant-kind node))
         (var-name (semantic-loop-variant-var-name node))
         (llvm-type (crisp-type-to-llvm-type (semantic-loop-variant-var-type node) module))
         (width (crisp.llvm-bindings::llvm-get-int-type-width llvm-type))
         (current-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
    (flet ((gen (n) (when n
                      (%loop-variant-coerce
                       builder
                       (generate-node-ir n builder module var-env di-builder di-scope location-map)
                       llvm-type)))
           (k (v) (llvm-const-int llvm-type v 0))
           (cmp (pred a b) (llvm-build-icmp builder pred a b "lv_cmp"))
           (all (&rest cs) (reduce (lambda (a b) (crisp.llvm-bindings::llvm-build-and builder a b "lv_guard")) cs)))
      (let* ((n-val (gen (semantic-loop-variant-limit-node node)))
             (s-val (or (gen (semantic-loop-variant-stride-node node)) (k 1)))
             (init-val (or (gen (semantic-loop-variant-init-node node)) (k 1)))
             (f-val (or (gen (semantic-loop-variant-factor-node node)) (k 2)))
             (guard (ecase kind
                      (:dec-times (all (cmp +llvm-int-ne+ n-val (k 0)) (cmp +llvm-int-ne+ s-val (k 0))))
                      (:dec-by-factor (all (cmp +llvm-int-ne+ n-val (k 0)) (cmp +llvm-int-ugt+ f-val (k 1))))
                      (:multiply (all (cmp +llvm-int-ne+ init-val (k 0)) (cmp +llvm-int-ugt+ f-val (k 1))
                                      (cmp +llvm-int-ule+ init-val n-val)))
                      ((:power-up :power-down) (cmp +llvm-int-ugt+ n-val (k 1)))))
             (i-alloca (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
             (pre-block (llvm-append-basic-block current-fn "lv_pre"))
             (body-block (llvm-append-basic-block current-fn "lv_body"))
             (exit-block (llvm-append-basic-block current-fn "lv_exit"))
             (lim nil))
        (log:debug "loop-variant codegen: ~s var ~a i~d" kind var-name width)
        (llvm-build-cond-br builder guard pre-block exit-block)
        ;; --- pre: start value + loop invariants (divisions are safe past the guard) ---
        (llvm-position-builder-at-end builder pre-block)
        (let ((start
                (ecase kind
                  (:dec-times
                   (llvm-build-mul builder
                                   (llvm-build-udiv builder (llvm-build-sub builder n-val (k 1) "lv_nm1")
                                                    s-val "lv_q")
                                   s-val "lv_start"))
                  (:dec-by-factor n-val)
                  (:multiply
                   (setf lim (llvm-build-udiv builder n-val f-val "lv_lim"))
                   init-val)
                  (:power-up
                   (setf lim (crisp.llvm-bindings::llvm-build-l-shr builder (llvm-build-sub builder n-val (k 1) "lv_nm1")
                                               (k 1) "lv_lim"))
                   (k 1))
                  (:power-down
                   (let* ((nm1 (llvm-build-sub builder n-val (k 1) "lv_nm1"))
                          (clz (%hw-call builder module (format nil "llvm.ctlz.i~d" width) llvm-type
                                         (list nm1 (llvm-const-int (llvm-int1-type) 0 0)) "lv_clz"))
                          (sh (llvm-build-sub builder (k (1- width)) clz "lv_sh")))
                     (crisp.llvm-bindings::llvm-build-shl builder (k 1) sh "lv_start"))))))
          (llvm-build-store builder start i-alloca))
        (llvm-build-br builder body-block)
        ;; --- body ---
        (llvm-position-builder-at-end builder body-block)
        (let ((body-env (alexandria:copy-hash-table var-env)))
          (setf (gethash var-name body-env) i-alloca)
          (dolist (body-node (semantic-loop-variant-body node))
            (generate-node-ir body-node builder module body-env di-builder di-scope location-map)))
        ;; --- latch: step + continue test, overflow-safe ---
        (unless (terminator-p (llvm-get-insert-block builder))
          (let* ((i-cur (llvm-build-load2 builder llvm-type i-alloca "i_cur"))
                 (next nil)
                 (cont nil))
            (ecase kind
              (:dec-times
               (setf next (llvm-build-sub builder i-cur s-val "i_next")
                     cont (cmp +llvm-int-uge+ i-cur s-val)))
              ((:dec-by-factor :power-down)
               (setf next (if (eq kind :power-down)
                              (crisp.llvm-bindings::llvm-build-l-shr builder i-cur (k 1) "i_next")
                              (llvm-build-udiv builder i-cur f-val "i_next"))
                     cont (cmp +llvm-int-ne+ next (k 0))))
              ((:multiply :power-up)
               (setf next (if (eq kind :power-up)
                              (crisp.llvm-bindings::llvm-build-shl builder i-cur (k 1) "i_next")
                              (llvm-build-mul builder i-cur f-val "i_next"))
                     cont (cmp +llvm-int-ule+ i-cur lim))))
            (llvm-build-store builder next i-alloca)
            ;; Endeavour 180: the bottom test is the latch -- it carries the unroll request, if any.
            (%attach-loop-unroll-metadata (llvm-build-cond-br builder cont body-block exit-block)
                                          module (semantic-loop-variant-unroll node))))
        (llvm-position-builder-at-end builder exit-block)
        (values nil nil)))))


;;; --- Endeavour 180 spec validators: count the loads in the SHIPPED module ---------------------

;; src/mma.lisp (beside the other SPIR-V validators)
(defun %spv-scalar-load-count (spv-path width)
  "Endeavour 180.  The number of OpLoad instructions in SPV-PATH whose result is the WIDTH-bit
   float type (32 or 64), read from `llvm-spirv --to-text`; NIL when llvm-spirv is unavailable.
   In the specs' streaming kernels (B[i] = 2*A[i]) every such load is a load of A, so the count is
   the loads per trip of the unrolled loop plus its remainder loop's one."
  (let ((txt (%spv-disasm spv-path)))
    (when txt
      (let ((float-ids nil) (loads 0))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (when (and (>= (length toks) 4) (string= (second toks) "TypeFloat")
                                (string= (fourth toks) (princ-to-string width)))
                       (push (third toks) float-ids)))))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (when (and (>= (length toks) 3) (string= (second toks) "Load")
                                (member (third toks) float-ids :test #'string=))
                       (incf loads)))))
        (log:debug "180: ~a has ~d f~d load(s)" spv-path loads width)
        loads))))

;; src/mma.lisp
(defun %validate-spv-stream-loads (spv-path width lo hi what)
  "Endeavour 180.  T when SPV-PATH has between LO and HI (inclusive; HI NIL = no limit) WIDTH-bit
   float loads; prints WHAT on failure.  Skips (T) when llvm-spirv is unavailable."
  (let ((n (%spv-scalar-load-count spv-path width)))
    (cond ((null n)
           (format t "  (llvm-spirv unavailable -- load-count check skipped)~%") t)
          ((and (>= n lo) (or (null hi) (<= n hi))) t)
          (t (format t "FAIL: ~d f~d load(s) in the shipped SPIR-V; expected ~a.~%" n width what)
             nil))))

;; src/mma.lisp
(defun validate-spv-stream-unrolled-x4 (spv-path)
  "Endeavour 180: the float stream loop is unrolled x4 -- at least 4 float loads (body), at most 5
   (plus the remainder loop's one)."
  (%validate-spv-stream-loads spv-path 32 4 5 "4 or 5 (x4 body + remainder) -- the stream default did not unroll"))

;; src/mma.lisp
(defun validate-spv-stream-unrolled-x8 (spv-path)
  "Endeavour 180: the float stream loop is unrolled x8 -- 8 or 9 float loads."
  (%validate-spv-stream-loads spv-path 32 8 9 "8 or 9 (x8 body + remainder) -- (unroll 8) did not reach the loop"))

;; src/mma.lisp
(defun validate-spv-stream-double-unrolled-x2 (spv-path)
  "Endeavour 180: the double stream loop is unrolled x2 (16 bytes in flight) -- 2 or 3 double loads,
   never the 4+ a fixed x4 would give."
  (%validate-spv-stream-loads spv-path 64 2 3 "2 or 3 (x2 body + remainder) -- the default is a byte budget, 16 bytes = 2 doubles"))

;; src/mma.lisp
(defun validate-spv-stream-not-unrolled (spv-path)
  "Endeavour 180: (unroll nil) -- exactly one float load, the loop as it was."
  (%validate-spv-stream-loads spv-path 32 1 1 "exactly 1 -- (unroll nil) did not stop the unrolling"))

;; src/codegen.lisp (beside compile-to-ptx)
(defun validate-ptx-has-nounroll-pragma (ptx-path)
  "Endeavour 180: {llvm.loop.unroll.disable} reached the PTX as .pragma \"nounroll\", so ptxas
   leaves the loop alone too."
  (let ((txt (and (probe-file ptx-path) (uiop:read-file-string ptx-path))))
    (cond ((null txt) (format t "FAIL: no PTX at ~a~%" ptx-path) nil)
          ((search ".pragma \"nounroll\"" txt) t)
          (t (format t "FAIL: no .pragma \"nounroll\" in the PTX -- (unroll nil) was lost.~%") nil))))

;; src/codegen.lisp (beside compile-to-ptx) -- SUPERSEDES the 1-argument copy above: PTX validators
;; take (FILE PTX-TEXT), unlike the SPIR-V ones (run-spec-ptx-in-process).
(defun validate-ptx-has-nounroll-pragma (file ptx-text)
  "Endeavour 180: {llvm.loop.unroll.disable} reached the PTX as .pragma \"nounroll\", so ptxas
   leaves the loop alone too."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((search ".pragma \"nounroll\"" ptx-text) t)
        (t (format t "FAIL: no .pragma \"nounroll\" in the PTX -- (unroll nil) was lost.~%") nil)))

;; src/mma.lisp -- SUPERSEDES the copy above: scoped to the FORWARD kernel.  Under the runner's
;; --differentiate pass the validator is handed the _grad module, which holds the forward kernel AND
;; the gradient kernel, and the backward's loads are not the stream loop's.
(defun %spv-scalar-load-count (spv-path width)
  "Endeavour 180.  The number of OpLoad instructions in SPV-PATH whose result is the WIDTH-bit
   float type (32 or 64), read from `llvm-spirv --to-text`; NIL when llvm-spirv is unavailable.
   Counts only inside functions NOT named *_grad, so a --differentiate module (forward + gradient
   kernel) counts the forward kernel alone.  In the specs' streaming kernels (B[i] = 2*A[i]) every
   such load is a load of A: the loads per trip of the unrolled loop plus its remainder loop's one."
  (let ((txt (%spv-disasm spv-path)))
    (when txt
      (let ((float-ids nil) (names (make-hash-table :test 'equal)) (loads 0) (counting nil))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 4) (string= (second toks) "TypeFloat")
                                 (string= (fourth toks) (princ-to-string width)))
                            (push (third toks) float-ids))
                           ((and (>= (length toks) 4) (string= (second toks) "Name"))
                            (setf (gethash (third toks) names) (string-trim "\"" (fourth toks))))))))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 4) (string= (second toks) "Function"))
                            (let ((nm (gethash (fourth toks) names "")))
                              (setf counting (not (search "_grad" nm :test #'char-equal)))))
                           ((and (>= (length toks) 2) (string= (second toks) "FunctionEnd"))
                            (setf counting nil))
                           ((and counting (>= (length toks) 3) (string= (second toks) "Load")
                                 (member (third toks) float-ids :test #'string=))
                            (incf loads))))))
        (log:debug "180: ~a has ~d f~d load(s) outside *_grad functions" spv-path loads width)
        loads))))

;;; --- BUG 107 (found by endeavour 180): kernel-arg metadata ids collided above !99 ---

;; src/compiler.lisp
(defun %max-metadata-id (ir-text)
  "BUG 107.  The highest numbered metadata id defined in IR-TEXT (a line starting `!N = `), or -1
   when there is none."
  (let ((best -1))
    (with-input-from-string (in ir-text)
      (loop for line = (read-line in nil) while line
            do (when (and (> (length line) 1) (char= (cl:char line 0) #\!) (digit-char-p (cl:char line 1)))
                 (let ((end (position-if-not #'digit-char-p line :start 1)))
                   (when (and end (search " = " line :start2 end :end2 (min (length line) (+ end 3))))
                     (setf best (max best (parse-integer line :start 1 :end end))))))))
    best))

;; src/compiler.lisp
(defun inject-spir-kernel-metadata (ir-text)
  "Inject OpenCL kernel metadata for all SPIR kernels found in IR text.
Returns modified IR text with metadata.

Endeavour 156: PRESERVES any metadata LLVM already attached to the kernel (attribute-group refs,
!dbg, !intel_reqd_sub_group_size) instead of overwriting it -- see the comment above.

BUG 107: the kernel-arg metadata is numbered from above the highest id already in IR-TEXT, not
from a fixed !100."
  (let ((kernels (find-spir-kernels ir-text)))
    (if (null kernels)
        ir-text
        (let ((result ir-text)
              ;; BUG 107: never 100 -- a module that already numbers past !99 (debug info; or, since
              ;; endeavour 180, one !llvm.loop node per annotated loop) would get a duplicate id.
              (metadata-id-base (max 100 (1+ (%max-metadata-id ir-text))))
              (all-metadata-defs ""))

          (dolist (kernel-info kernels)
            (destructuring-bind (func-name func-start brace-pos) kernel-info
              (log:info "Injecting metadata for kernel: ~a" func-name)

              (let ((params (extract-kernel-params result func-start brace-pos)))
                (log:info "  Parameters: ~a" params)

                (multiple-value-bind (metadata-refs metadata-defs next-id)
                    (generate-kernel-metadata params metadata-id-base)

                  (let* (;; Search for @funcname( to find the definition, not occurrences
                         ;; of func-name inside struct type names like S_file_funcname_TYPE
                         (at-name-str (format nil "@~a(" func-name))
                         (kernel-sig-start (search at-name-str result))
                         (new-brace-pos (when kernel-sig-start
                                          (position #\{ result :start kernel-sig-start)))
                         ;; Search for ) only AFTER kernel-sig-start to stay within the signature
                         (close-paren-pos (when (and kernel-sig-start new-brace-pos)
                                            (position #\) result
                                                      :start kernel-sig-start
                                                      :end new-brace-pos
                                                      :from-end t))))

                    (log:info "  at-name-str=~s kernel-sig-start=~a new-brace-pos=~a close-paren-pos=~a"
                              at-name-str kernel-sig-start new-brace-pos close-paren-pos)

                    (if (null close-paren-pos)
                        (log:warn "inject-spir-kernel-metadata: could not find ) for ~a, skipping" func-name)
                        ;; Endeavour 156: keep the existing tail (#N, !dbg, !intel_reqd_sub_group_size,
                        ;; anything else LLVM attached) and append our refs after it.
                        (let ((existing (string-trim '(#\Space #\Tab)
                                                     (subseq result (1+ close-paren-pos) new-brace-pos))))
                          (log:debug "  preserving existing kernel metadata for ~a: ~s" func-name existing)
                          (setf result (concatenate 'string
                                         (subseq result 0 (1+ close-paren-pos))
                                         (if (string= existing "")
                                             ""
                                             (concatenate 'string " " existing))
                                         metadata-refs
                                         " "
                                         (string #\{)
                                         (subseq result (1+ new-brace-pos))))
                          (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                          (setf metadata-id-base next-id))))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))
