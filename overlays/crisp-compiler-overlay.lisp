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


;;;; ===================================================================================
;;;; ENDEAVOUR 179 -- reduction launch state.  D1: every last-man election resets its own ticket
;;;; counter, so the kernel can be launched twice.  D2: :atomic / :cas outputs are recorded as
;;;; needing the identity before every launch, and the metacrisp says so (:launch-init).
;;;; Fold notes: whole-function copies, script-extracted from src/; each differs from src/ only
;;;; by the lines marked 179.
;;;; ===================================================================================

;; src/compiler.lisp  (NEW -- next to *implicit-scratch-size-expr-map*)
(defvar *reduction-launch-init* (make-hash-table :test 'equal)
  "Endeavour 179.  (KERNEL-NAME . PARAM-NAME) -> the :launch-init plist for that kernel parameter,
   e.g. (:identity 0.0).  Filled during analysis by the :atomic / :cas reduction lowerings, which
   combine INTO their return cell, so the host must put the identity there before every launch.
   Read by generate-declared-signature.  A PERSISTENT global cleared by initialize-compiler, like
   *implicit-scratch-size-expr-map*: metadata emission runs after compile-module returns.")

;; src/analysis/ops.lisp  (NEW -- 179)
(defun %reduction-identity-value (form)
  "Endeavour 179.  The compile-time value of reduction identity FORM, for the metacrisp: a number,
   :infinity / :-infinity, or NIL when Crisp cannot see a constant.  Recognises a numeric literal,
   a suffixed literal (0ul, 1.5f), (type-min T), (type-max T), (type-infinity T) and (- X).
   Infinity is a keyword because SBCL cannot print it readably."
  (cond
    ((realp form) form)
    ((and (symbolp form) form (not (keywordp form)))
     (let ((lit (ignore-errors (%try-parse-typed-literal form nil))))
       (and lit (semantic-literal-p lit) (realp (semantic-literal-value lit))
            (semantic-literal-value lit))))
    ((and (consp form) (symbolp (car form)))
     (let ((head (symbol-name (car form))))
       (cond
         ((and (string= head "-") (= (length form) 2))
          (let ((v (%reduction-identity-value (second form))))
            (cond ((realp v) (- v))
                  ((eq v :infinity) :-infinity)
                  ((eq v :-infinity) :infinity))))
         ((string-equal head "TYPE-MIN")
          (let ((lit (ignore-errors (%analyze-type-min form nil nil nil))))
            (and lit (semantic-literal-value lit))))
         ((string-equal head "TYPE-MAX")
          (let ((lit (ignore-errors (%analyze-type-max form nil nil nil))))
            (and lit (semantic-literal-value lit))))
         ((string-equal head "TYPE-INFINITY")
          (and (ignore-errors (%type-extreme-scalar-info form nil)) :infinity)))))))

;; src/analysis/ops.lisp  (NEW -- 179)
(defun %note-reduction-launch-init (op return-cell identity)
  "Endeavour 179.  Records that RETURN-CELL, a reduction's return cell, must hold IDENTITY before every
   launch -- true of :atomic and :cas, which combine INTO it, and which cannot initialise it themselves
   (knowing who is first would need a grid-wide sync).  Recorded against the kernel being compiled,
   for generate-declared-signature to emit as :launch-init.  Only a kernel's own parameter can be
   described in the metacrisp; anything else is logged as a warning, because a host that launches the
   kernel twice must then reset that cell without being told."
  (let* ((cc *compiler-context*)
         (fn (and cc (compiler-context-current-compiling-function cc))))
    (cond
      ((null fn)
       (log:debug "179: ~a outside a compiling function; nothing recorded" op))
      ((not (symbolp return-cell))
       (log:warn "~a in ~(~a~): the return cell ~s is not a plain kernel parameter, so the metacrisp cannot say it must hold the identity before each launch.  A host that launches this kernel twice must reset it itself."
                 op fn return-cell))
      ((not (gethash fn *kernel-declared-signatures*))
       (log:warn "~a in ~(~a~): ~(~a~) is not a kernel, so the metacrisp cannot say that ~(~a~) must hold the identity before each launch."
                 op fn fn return-cell))
      (t
       (let ((value (%reduction-identity-value identity))
             (key (cons (string-upcase (symbol-name fn)) (string-downcase (symbol-name return-cell)))))
         (setf (gethash key *reduction-launch-init*)
               (if value
                   (list :identity value)
                   (list :identity-form (let ((*package* (find-package :crisp-language)))
                                          (prin1-to-string identity)))))
         (log:debug "179: ~a in ~a: ~a must hold ~s before each launch"
                    op fn return-cell (gethash key *reduction-launch-init*)))))))

;; src/metadata.lisp  (NEW -- 179)
(defun %reduction-launch-init-for (kernel-name param-name)
  "Endeavour 179.  The :launch-init plist recorded for KERNEL-NAME's parameter PARAM-NAME, or NIL."
  (gethash (cons (string-upcase (string kernel-name)) (string-downcase (string param-name)))
           *reduction-launch-init*))

;; src/analysis/ops.lisp  (REPLACES %grid-reduce-last-man-expand -- 179: counter self-reset)
(defun %grid-reduce-last-man-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081)."
  (multiple-value-bind (fn var identity return-vec sv gv ctr flag)
      (%grid-reduce-last-man-parts expr)
    (dolist (pair (list (list return-vec "a return-vec" "the single global element the grid reduces into")
                        (list sv ":local-scratch-vec" "one element per warp, for the per-workgroup reduction")
                        (list gv ":global-scratch-vec" "one element per WORKGROUP, holding the partials")
                        (list ctr ":atomic-counter"   "a zero-initialised GLOBAL uint cell, used to draw tickets")
                        (list flag ":election-flag-cell" "a LOCAL uint cell, broadcasting the ticket result from thread 0 to its workgroup")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-last-man!: ~a is required -- ~a.  It must be allocated in the CALLER's scope: scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters."
                                (second pair) (third pair))
               :source-location nil)))
    (let ((lid (gensym "LM-LID"))
          (ng  (gensym "LM-NG"))
          (val (gensym "LM-VAL")))
      `(progn
         ;; The final sweep is ONE reduce-workgroup, so every partial must fit in one workgroup.
         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                       "grid-reduce-last-man!: the number of workgroups exceeds local_work_size, so the final sweep cannot cover every partial in one pass")
         ;; Phase 1 -- every thread of this workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
         ;; Phase 2 -- publish this workgroup's partial.
         (when-thread-in-group-is 0
           (set! (~ ,gv (to-int (get-workgroup-id 0))) ,var))
         ;; The store must be visible before the counter announces this workgroup has arrived.
         ;; OUTSIDE the election because a fence in divergent control flow is refused (BUG 082,
         ;; over-strict but load-bearing for sync-wait).  Ordering survives regardless: it is
         ;; thread 0's OWN program order that carries it -- store, then fence, then atomic.
         (mem-fence)
         (when-thread-in-group-is 0
           ;; atomic-add! yields the value BEFORE the addition, so exactly one workgroup in the
           ;; grid draws num_groups-1.  Verified on hardware, not assumed.
           (set! (~ ,flag)
                 (if (= (atomic-add! (~ ,ctr) 1u)
                        (- (to-uint (get-num-groups 0)) 1u))
                     1u 0u)))
         ;; Publish the verdict to the rest of the workgroup.
         (sync-workgroup)
         ;; Uniform by construction -- every thread reads the same cell after a barrier.  It has
         ;; to be when+ rather than when: the body contains a reduce-workgroup, and a workgroup
         ;; collective inside a merely thread-divergent conditional is refused.
         ;; THE LOSERS FALL STRAIGHT THROUGH HERE AND RETIRE.
         (when+ (= (~ ,flag) 1u)
           (let ((,lid (to-int (get-local-linear-id)))
                 (,ng  (to-int (get-num-groups 0))))
             (let ((,val (if (< ,lid ,ng) (~ ,gv ,lid) ,identity)))
               (reduce-workgroup ,fn ,val ,identity :local-scratch-vec ,sv)
               (when-thread-in-group-is 0
                 (set! (~ ,return-vec 0) ,val)
                 ;; 179: put the ticket counter back for the next launch.  Safe here: every workgroup
                 ;; has already drawn its ticket -- that is how this one knows it is last.
                 (set! (~ ,ctr) 0u)))))
         (compiler-no-op)))))


;; src/analysis/ops.lisp  (REPLACES %fused-grid-reduce-form -- 179: counter self-reset + launch-init)
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
         ;; 179: :atomic / :cas combine INTO each clause's return cell -- record that it needs
         ;; the identity before every launch.
         (dolist (clause clauses)
           (%note-reduction-launch-init "grid-reduce!" (fourth clause) (third clause)))
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
                                         collect `(set! (~ ,(fourth c) 0) ,val))
                                 ;; 179: put the ticket counter back for the next launch.  Safe here: every workgroup
                                 ;; has already drawn its ticket -- that is how this one knows it is last.
                                 (set! (~ ,ctr) 0u)))))
                         (compiler-no-op))))
               (if lets `(let ,(nreverse lets) ,body) body)))))))))


;; src/analysis/ops.lisp  (REPLACES %fused-grid-reduce-dependent-form -- 179: counter self-reset)
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
                                    collect `(set! (~ ,(third c) 0) ,val))
                            ;; 179: put the ticket counter back for the next launch.  Safe here: every workgroup
                            ;; has already drawn its ticket -- that is how this one knows it is last.
                            (set! (~ ,ctr) 0u)))))
                    (compiler-no-op))))
          (if lets `(let ,(nreverse lets) ,body) body))))))


;; src/analysis/ops.lisp  (REPLACES %grid-reduce-atomic-expand -- 179: launch-init)
(defun %grid-reduce-atomic-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (see the section header)."
  (multiple-value-bind (fn var identity return-vec scratch) (%grid-reduce-atomic-parts expr)
    (let ((atomic (%grid-atomic-op-name fn)))
      (unless return-vec
        (error 'crisp-compiler-error
               :message "grid-reduce-atomic!: a return-vec is required -- it is the single global element the grid accumulates into.  Call it as (grid-reduce-atomic! #'+ var identity return-vec :local-scratch-vec sv)."
               :source-location nil))
      (unless scratch
        (error 'crisp-compiler-error
               :message "grid-reduce-atomic!: :local-scratch-vec is required in this build.  Auto-generating it needs VAR's element type at analysis time, which Crisp cannot yet supply.  Pass e.g. (make-scratch-vector float :match-num-warps-per-workgroup)."
               :source-location nil))
      (unless atomic
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-atomic!: ~s has no native hardware atomic, so there is no instruction for phase 2 to emit.  Only +, min and max qualify -- the hardware provides exactly those.  For an arbitrary commutative operator use grid-reduce-cas! (a CAS loop; no extra memory, high contention) or grid-reduce-last-man! (a global scratch buffer; no contention)."
                                fn)
               :source-location nil))
      ;; 179: the atomic combines INTO return-vec, which must hold the identity before every launch.
      (%note-reduction-launch-init "grid-reduce-atomic!" return-vec identity)
      `(progn
         ;; Phase 1 -- every thread of the workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,scratch)
         ;; Phase 2 -- ONE leader per workgroup contributes that total to the grid cell.  Electing
         ;; a single thread is what makes the atomic correct: without it all 64 would add the same
         ;; workgroup total and the result would be scaled by the workgroup size.
         (when-thread-in-group-is 0
           (,(intern atomic (find-package :crisp.compiler)) (~ ,return-vec 0) ,var))
         (compiler-no-op)))))


;; src/analysis/ops.lisp  (REPLACES %grid-reduce-cas-expand -- 179: launch-init)
(defun %grid-reduce-cas-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081)."
  (multiple-value-bind (fn var identity return-vec sv) (%grid-reduce-cas-parts expr)
    (dolist (pair (list (list fn "a binop") (list var "a var to reduce")
                        (list identity "an identity") (list return-vec "a return-vec")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-cas!: ~a is required.  The form is (grid-reduce-cas! fn var identity return-vec :local-scratch-vec sv)."
                                (second pair))
               :source-location nil)))
    (unless sv
      (error 'crisp-compiler-error
             :message "grid-reduce-cas!: :local-scratch-vec is required -- one element per warp, for the per-workgroup reduction.  It must be allocated in the CALLER's scope: scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters, so Crisp cannot generate it for you here."
             :source-location nil))
    ;; 179: the CAS loop combines INTO return-vec, which must hold the identity before every launch.
    (%note-reduction-launch-init "grid-reduce-cas!" return-vec identity)
    `(progn
       ;; Phase 1 -- every thread of the workgroup ends up holding the workgroup's total.
       (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
       ;; Phase 2 -- one leader per workgroup folds that total into the single result cell.
       ;; The CAS loop, its derived bound and its exhaustion assert all live in atomic-binop!.
       (when-thread-in-group-is 0
         (atomic-binop! (~ ,return-vec 0) ,fn ,var))
       (compiler-no-op))))


;; src/metadata.lisp  (REPLACES generate-declared-signature -- 179: :launch-init)
(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared-signature plist for a kernel's metadata.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Count implicit params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t)
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              (setf entry (append entry (list :type (strip-package-qualifiers type))))
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              (when (%storage-handle-type-p type)
                (let* ((canonical (canonicalize-type-specifier type))
                       (base (if (consp canonical) (first canonical) canonical))
                       (is-cell   (and (symbolp base) (string-equal (symbol-name base) "CELL")))
                       (is-tensor (and (symbolp base) (string-equal (symbol-name base) "TENSOR")))
                       ;; CELL 3-tuple:   (cell elem ADDR)         — addr at index 2
                       ;; TENSOR 6-tuple: (tensor elem N ADDR aln ct) — addr at index 3
                       (as (if (and (consp canonical) is-cell (>= (length canonical) 3))
                               (nth 2 canonical)
                               (if (consp canonical)
                                   (let ((found (member :address-space canonical)))
                                     (if found (second found) :global))
                                   :global))))
                  (setf entry (append entry (list :address-space as)))
                  (when is-tensor
                    (let* ((n (if (integerp (third canonical))
                                  (third canonical)
                                  (parse-integer (symbol-name (third canonical)))))
                           ;; TENSOR 6-tuple: (tensor T N addr ALN ct) — aln at index 4
                           (alg (or (nth 4 canonical) :compact)))
                      (setf entry (append entry (list :rank n :align alg)))))))

              (setf entry (append entry (list :range (list start end))))
              ;; 179: a reduction output the host must set to the identity before every launch.
              (let ((launch-init (%reduction-launch-init-for (function-signature-name sig) name)))
                (when launch-init
                  (setf entry (append entry (list :launch-init launch-init)))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))


;; src/compiler.lisp  (REPLACES initialize-compiler -- 179: clear *reduction-launch-init*)
(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil)
                                 (math-precision :ieee) (force-math-precision nil)
                                 (denormal-handling :preserve)
                                 (hardware-profile nil))
  "Initializes the compiler state.
   Extended to clear *grid-functions* for def-grid-function support."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Endeavor 130: record the requested hardware profile (a name string) and clear
  ;; the profile registry (the current file's def-hardware-profile forms re-register).
  (setf *requested-hardware-profile* hardware-profile)
  (clrhash *hardware-profiles*)
  ;; Endeavor 126: force is the hard lock; the effective starting precision is
  ;; force (if given) else the --math-precision flag. declaim/with-precision may
  ;; later mutate *math-precision* only when *force-math-precision* is NIL.
  (setf *force-math-precision* force-math-precision)
  (setf *math-precision* (or force-math-precision math-precision))
  (setf *denormal-handling* denormal-handling)
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

  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)
  (clrhash *foreign-functions*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
        (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  ;; 101 endeavor: clear parameterized-brand-names too — left-over state from a
  ;; prior test (e.g. value-t marked parameterized after cell+fake-cell both
  ;; defined value-t) was bleeding into later tests in 037-cell-branded, masking
  ;; the brand-instance mismatch that errors/02 and errors/04 expect to detect.
  (when (boundp '*parameterized-brand-names*) (clrhash *parameterized-brand-names*))

  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)
  ;; 179: clear the reduction launch-init side table (same lifetime)
  (clrhash *reduction-launch-init*)

  ;; Endeavor 137: clear the CUtensorMap descriptor metadata side table.  This is a PERSISTENT
  ;; global (not rebound per-module) so it survives to metadata-emission time, which runs after
  ;; compile-module returns — same lifetime as *implicit-scratch-size-expr-map*.
  (when (boundp '*tma-descriptor-info*)
    (clrhash *tma-descriptor-info*))
  (when (boundp '*tma-resolved*)
    (clrhash *tma-resolved*))

  ;; clear dispatch declarations side table
  (clrhash *kernel-dispatch-declarations*)

  ;; clear grid-function registry
  (clrhash *grid-functions*)

  (register-builtins)
  (register-mma-types)              ; Endeavor 132 — MMA fundamentals (src/mma.lisp)

  (log:info "Compiler initialized. differentiate=~a" differentiate))

