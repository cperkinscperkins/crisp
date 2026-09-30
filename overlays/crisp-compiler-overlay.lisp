;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-09-22 — endeavour 175 folded into src/.
;;;;
;;;; Four things did NOT move, and that is deliberate:
;;;;   * the REDUCE-WARP and REDUCE-WORKGROUP defmacros, and the two eval-whens that
;;;;     FMAKUNBOUND them.  Both constructs became analyzed forms so the VJP registry could
;;;;     see them (BUG 081); the macros existed only because an overlay cannot un-write its
;;;;     own earlier definition.  Folding them in would have resurrected dead code AND made
;;;;     anf-transform expand the form again before the backward walk.
;;;;   * the three eval-whens that copied MACRO-FUNCTION between packages.  src/package.lisp
;;;;     exports the two WHEN-THREAD-IN-* macros from :crisp.compiler and imports them into
;;;;     :crisp-language, so there is one symbol rather than two.
;;;;   * %WARP-SPEC-CHECK-SYNC, whose live copy was a pure pass-through (the BUG 082 revert),
;;;;     so folding it meant changing nothing.
;;;;   * the eleven chained REGISTER-OPS-ANALYZERS wrappers, collapsed into one block of 13
;;;;     registrations at the end of the real function in src/analysis/ops.lisp.

(in-package :crisp.compiler)


;; src/analysis/control.lisp  (new -- place just before analyze-if-expression-impl)
(defun %if-explicit-nil-else-is-false-p (expr then-node)
  "BUG 092.  True when the IF form EXPR was written WITH an else and that else is NIL, and its
   THEN branch THEN-NODE produces a scalar value a false 0 can unify with.  That is the shape
   CL's AND expands to -- (and X Y) => (IF X (AND Y) NIL) -- and it used to be analyzed as having
   NO else, so the false path never stored the IF's result and -O3 deleted X outright.

   Deliberately narrow:
     * (if x y) with no else at all is unchanged -- only a WRITTEN nil counts;
     * a void THEN (a statement IF, e.g. a SET! body) is unchanged -- NIL there means 'no value';
     * a THEN whose type cannot promote with int (struct, tensor, ...) is unchanged, since a 0
       else would be a type error; ensure-branch-compatibility keeps its old void-branch rule.
   The int 0 literal is promoted to THEN's type by ensure-branch-compatibility, the same path any
   mixed-type IF takes."
  (and (cdddr expr)
       (null (fourth expr))
       (let ((t-single (get-single-value-type then-node)))
         (and t-single
              (symbolp t-single)
              (get-promoted-type t-single 'int)
              t))))

;; src/analysis/control.lisp
(defun analyze-if-expression-impl (expr env context location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    ;; No runtime divergence — analyze the live branch without setting the divergent flag.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env context (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    ;; Calculate uniformity state of the condition
    (let ((cond-uniformity (calculate-uniformity-state cond-node env)))

      ;; Phase 1d: both branches will be analyzed → runtime divergence.  Bind
      ;; *in-divergent-conditional* to T for the branch analyses so that any
      ;; load-tile-at / store-tile-at inside either branch is rejected.
      ;;
      ;; Endeavor 138: ...but ONLY when the condition can actually diverge.  A
      ;; workgroup-UNIFORM condition takes every thread down the same branch, so an internal
      ;; sync-workgroup cannot deadlock and the tile op is safe.  We already compute
      ;; COND-UNIFORMITY and already trust it for *divergent-scope-depth* (right below); using
      ;; it here too is what makes this check's own advice ("use a non-divergent condition")
      ;; actually achievable — previously a uniform guard was rejected identically, which made
      ;; the guarded prefetch of a pipelined ring loop (`(when (< next-k n-k-steps) ...)`,
      ;; uniform in the K-loop counter) impossible to express.
      (let* ((*in-divergent-conditional* (if (eq cond-uniformity :uniform)
                                             *in-divergent-conditional*
                                             t))
             (*divergent-scope-depth* (if (not (eq cond-uniformity :uniform))
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
             (then-node (analyze-expression (third expr) env context (append location '(2))))
             (else-node
               (cond
                 ((fourth expr)
                  (analyze-expression (fourth expr) env context (append location '(3))))
                 ;; BUG 092: an else that is WRITTEN but is NIL -- (if x y nil), which is exactly
                 ;; what CL's AND expands to -- is a false VALUE when THEN produces one.  It used to
                 ;; be indistinguishable from a missing else, leaving the false path unstored.
                 ((%if-explicit-nil-else-is-false-p expr then-node)
                  (log:debug "BUG 092: explicit NIL else of a value IF analyzed as false (int 0): ~s" expr)
                  (make-semantic-literal :value-type 'int :value 0
                                         :source-location (append location '(3))))
                 (t nil))))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location))))))


;; src/analysis/control.lisp  (new -- place just before analyze-if-expression-impl.
;;  SUPERSEDES %if-explicit-nil-else-is-false-p above, which was drafted on a wrong premise:
;;  the running compiler expands (and X Y) to (IF X Y) -- there is no written NIL to detect.)
(defun %if-missing-else-is-false-p (expr then-node)
  "BUG 092.  True when the IF form EXPR has no else, or a NIL else, and its THEN branch THEN-NODE
   produces a scalar value that a false 0 can unify with.  In CL, (if x y) means (if x y nil):
   the false path has a value, and it is false.  Crisp analyzed a missing else as NO branch, so the
   false path never stored the IF's result -- and CL's AND expands to exactly (IF X Y), so every
   (and X Y) used as a value read an uninitialised slot on the X-false path.  -O3 then deleted X
   outright, or (in the tile bounds checks) turned the path into an llvm.assume with no store.

   Deliberately narrow:
     * a void THEN (a statement IF, e.g. a SET! body) is unchanged -- there is no value to supply;
     * a THEN whose type cannot promote with int (struct, tensor, ...) is unchanged, since a 0
       else would be a type error; ensure-branch-compatibility keeps its old void-branch rule.
   The int 0 literal is promoted to THEN's type by ensure-branch-compatibility, the same path any
   mixed-type IF takes."
  (and (null (fourth expr))
       (let ((t-single (get-single-value-type then-node)))
         (and t-single
              (symbolp t-single)
              (get-promoted-type t-single 'int)
              t))))

;; src/analysis/control.lisp  (supersedes the copy above -- only the helper call and its comment changed)
(defun analyze-if-expression-impl (expr env context location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    ;; No runtime divergence — analyze the live branch without setting the divergent flag.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env context (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    ;; Calculate uniformity state of the condition
    (let ((cond-uniformity (calculate-uniformity-state cond-node env)))

      ;; Phase 1d: both branches will be analyzed → runtime divergence.  Bind
      ;; *in-divergent-conditional* to T for the branch analyses so that any
      ;; load-tile-at / store-tile-at inside either branch is rejected.
      ;;
      ;; Endeavor 138: ...but ONLY when the condition can actually diverge.  A
      ;; workgroup-UNIFORM condition takes every thread down the same branch, so an internal
      ;; sync-workgroup cannot deadlock and the tile op is safe.  We already compute
      ;; COND-UNIFORMITY and already trust it for *divergent-scope-depth* (right below); using
      ;; it here too is what makes this check's own advice ("use a non-divergent condition")
      ;; actually achievable — previously a uniform guard was rejected identically, which made
      ;; the guarded prefetch of a pipelined ring loop (`(when (< next-k n-k-steps) ...)`,
      ;; uniform in the K-loop counter) impossible to express.
      (let* ((*in-divergent-conditional* (if (eq cond-uniformity :uniform)
                                             *in-divergent-conditional*
                                             t))
             (*divergent-scope-depth* (if (not (eq cond-uniformity :uniform))
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
             (then-node (analyze-expression (third expr) env context (append location '(2))))
             (else-node
               (cond
                 ((fourth expr)
                  (analyze-expression (fourth expr) env context (append location '(3))))
                 ;; BUG 092: a MISSING (or NIL) else is a false VALUE when THEN produces a scalar
                 ;; one -- CL semantics, where (if x y) means (if x y nil).  CL's AND expands to
                 ;; exactly (IF X Y), and the false path used to be left unstored.
                 ((%if-missing-else-is-false-p expr then-node)
                  (log:debug "BUG 092: missing/NIL else of a value IF analyzed as false (int 0): ~s" expr)
                  (make-semantic-literal :value-type 'int :value 0
                                         :source-location (append location '(3))))
                 (t nil))))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location))))))
