;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-07 -- endeavour 180 (loop unrolling) and BUG 107 folded into src/:
;;;;   * unroll declarations       -> %declaration-spec-named-p, %parse-unroll-spec,
;;;;                                  %split-loop-body-declarations, %loop-trip-count-constant-p,
;;;;                                  %stream-element-bytes, %resolve-unroll-spec, %analyze-loop-with-unroll;
;;;;                                  analyze-dotimes-expression / analyze-loop-variant-expression are now the
;;;;                                  wrappers, the pre-180 analyzers renamed %analyze-dotimes-core /
;;;;                                  %analyze-loop-variant-core (src/analysis/control.lisp)
;;;;   * misplaced unroll          -> %check-context-declarations, %refuse-misplaced-unroll,
;;;;                                  analyze-declare-expression, registered in register-control-analyzers
;;;;   * stream default            -> %expand-loop-vector-stride-form (control.lisp), %reduce-vec-expand (ops.lisp)
;;;;   * !llvm.loop emission       -> *stream-unroll-bytes-in-flight*, *stream-unroll-max-factor*,
;;;;                                  %effective-loop-unroll, %attach-loop-unroll-metadata, and both counted-loop
;;;;                                  generate-node-ir methods (src/codegen.lisp)
;;;;   * spec validators           -> %spv-scalar-load-count, %validate-spv-stream-loads, validate-spv-stream-*,
;;;;                                  validate-ptx-has-nounroll-pragma (src/mma.lisp)
;;;;   * BUG 107                   -> %max-metadata-id, inject-spir-kernel-metadata (src/compiler.lisp)

(in-package :crisp.compiler)

;;;; ---------------------------------------------------------------------------------------
;;;; ENDEAVOUR 181 -- last-man strided final sweep (A).  tests/spec/181-last-man-sweep/
;;;; ---------------------------------------------------------------------------------------

;; src/analysis/ops.lisp
(defun %181-strided-sweep-form (lid ng ls fold-at)
  "Endeavour 181.  Last-man's final sweep, run by every thread of the elected workgroup: thread LID folds
   partials LID, LID+LS, LID+2*LS, ... below NG into accumulator(s) the caller has bound to the IDENTITY,
   so one workgroup of LS threads covers any number of workgroups.  LID, NG and LS are symbols bound to
   ints.  FOLD-AT is called with the symbol holding the partial index P and returns a LIST of the forms
   that fold partial P in (spliced into the guarding WHEN).

   A COUNTED loop over ceil(NG/LS) strides with a closed-form index -- not a loop-carried P -- keeps the
   AD pass out of it (compare BUG 103/105), and the trip count is uniform (NG and LS are the same in
   every thread), hence dotimes+.  The fold order is fixed by (NG, LS) alone, so last-man stays
   reproducible.

   The first partial is folded by the loop like every other, NOT read into the accumulator before it as
   the pre-181 one-pass sweep did.  Seeding with (if (< lid ng) (~ gv lid) identity) and then looping
   compiled to correct LLVM IR (checked at -O3) that BMG executed wrongly: the seed was dropped, in some
   specs and not others depending on unrelated code shape, while the loop's own folds were never wrong.
   Same signature as BUG 030 (IGC).  See tests/spec/181-last-man-sweep/last-man-sweep.md, D2."
  (let ((k (gensym "LM-K"))
        (p (gensym "LM-P")))
    `(dotimes+ (,k (/ (+ ,ng (- ,ls 1)) ,ls))
       (let ((,p (+ ,lid (* ,k ,ls))))
         (when (< ,p ,ng)
           ,@(funcall fold-at p))))))

;; src/analysis/ops.lisp
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
                    (ls (gensym "LM-LS"))
                    (vals (loop repeat (length clauses) collect (gensym "LM-VAL")))
                    (body
                      `(progn
                         ,@(reverse checks)
                         ;; 181: one partial per workgroup in EVERY clause's buffer (the sweep is strided,
                         ;; so the local size no longer caps the group count)
                         ,@(loop for gv in (remove-duplicates gvs)
                                 collect `(r-t-assert-0 (<= (get-num-groups 0) (length~ ,gv))
                                                        "grid-reduce!: a last-man :global-scratch-vec has fewer elements than there are workgroups; it needs one per workgroup (:match-num-workgroups)."))
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
                                 (,ng  (to-int (get-num-groups 0)))
                                 (,ls  (to-int (get-local-linear-size))))
                             (let ,(loop for c in clauses for val in vals
                                         collect `(,val ,(third c)))
                               ;; 181: fold every partial, strided, every clause in one loop
                               ,(%181-strided-sweep-form
                                 lid ng ls
                                 (lambda (p)
                                   (loop for c in clauses for gv in gvs for val in vals
                                         collect `(set! ,val ,(%175-apply-binop (first c) val `(~ ,gv ,p))))))
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

;; src/analysis/ops.lisp
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
               (ls (gensym "LMD-LS"))
               (vals (loop repeat (length clauses) collect (gensym "LMD-VAL")))
               (news (loop repeat (length clauses) collect (gensym "LMD-NEW")))
               (body
                 `(progn
                    ,@(reverse checks)
                    ;; 181: one partial per workgroup in EVERY clause's buffer (the sweep is strided,
                    ;; so the local size no longer caps the group count)
                    ,@(loop for gv in (remove-duplicates gvs)
                            collect `(r-t-assert-0 (<= (get-num-groups 0) (length~ ,gv))
                                                   "grid-reduce!: a last-man :global-scratch-vec has fewer elements than there are workgroups; it needs one per workgroup (:match-num-workgroups)."))
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
                            (,ng  (to-int (get-num-groups 0)))
                            (,ls  (to-int (get-local-linear-size))))
                        (let ,(loop for c in clauses for val in vals
                                    collect `(,val ,(second c)))
                          ;; 181: fold every partial, strided -- ONE combiner call per partial index,
                          ;; carrying every variable of the state together
                          ,(%181-strided-sweep-form
                            lid ng ls
                            (lambda (p)
                              (list
                               `(let ((,@news ,(%combiner-call combiner
                                                              (append vals
                                                                      (loop for gv in gvs collect `(~ ,gv ,p))))))
                                  ,@(loop for val in vals for n in news collect `(set! ,val ,n))))))
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

;; src/analysis/ops.lisp
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
          (ls  (gensym "LM-LS"))
          (val (gensym "LM-VAL")))
      `(progn
         ;; 181: workgroup g writes partial g, so the partials buffer must have a slot per workgroup.
         ;; (The final sweep is strided, so the local size no longer caps the group count.)
         (r-t-assert-0 (<= (get-num-groups 0) (length~ ,gv))
                       "grid-reduce-last-man!: the :global-scratch-vec has fewer elements than there are workgroups; it needs one per workgroup (:match-num-workgroups)")
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
                 (,ng  (to-int (get-num-groups 0)))
                 (,ls  (to-int (get-local-linear-size))))
             (let ((,val ,identity))
               ,(%181-strided-sweep-form lid ng ls
                                         (lambda (p)
                                           (list `(set! ,val ,(%175-apply-binop fn val `(~ ,gv ,p))))))
               (reduce-workgroup ,fn ,val ,identity :local-scratch-vec ,sv)
               (when-thread-in-group-is 0
                 (set! (~ ,return-vec 0) ,val)
                 ;; 179: put the ticket counter back for the next launch.  Safe here: every workgroup
                 ;; has already drawn its ticket -- that is how this one knows it is last.
                 (set! (~ ,ctr) 0u)))))
         (compiler-no-op)))))

;; src/analysis/ops.lisp
(defun %implicit-scratch-alloc-form (key elem-type)
  "The allocation form for scratch KEY: the same forms a caller writes by hand (see 175/25).  The
   global partials are sized :match-num-workgroups, one slot per workgroup -- last-man's workgroup g
   writes slot g, and since 181 its final sweep is strided, so the group count is no longer capped at
   the local size (which is what made the pre-181 :match-workgroup-size enough)."
  (ecase key
    (:local-scratch-vec  `(make-scratch-vector ,elem-type :match-num-warps-per-workgroup))
    (:global-scratch-vec `(make-scratch-vector ,elem-type :match-num-workgroups :address-space :global))
    (:atomic-counter     '(make-scratch-cell uint :address-space :global))
    (:election-flag-cell '(make-scratch-cell uint))))

;;;; ---------------------------------------------------------------------------------------
;;;; ENDEAVOUR 182 -- the NVIDIA register budget for streaming kernels.
;;;; tests/spec/182-nvidia-register-budget/register-budget.md
;;;; ---------------------------------------------------------------------------------------

;; src/hardware-profile.lisp
(defparameter *hardware-profile-schema*
  '((:simd-width                  . :pos-int)
    (:compute-units               . :pos-int)
    (:max-registers-per-cu        . :pos-int)
    (:max-registers-per-thread    . :pos-int-or-modes)  ; 144 D4: scalar OR (mode ...)
    (:max-total-threads-per-block . :pos-int)
    (:max-concurrent-kernels      . :pos-int)
    (:native-cache-line-size      . :pos-int)   ; bytes
    (:max-shared-memory-per-block . :size)      ; KB/MB/GB/TB literal -> bytes
    (:l2-cache-size               . :size)
    (:tile-visit-strip-width      . :pos-int)   ; 144 Phase 1: measured; absent/1 => linear
    (:max-work-group-dims         . :dims3)     ; (x y z) positive ints
    (:mma-shapes                  . :mma-shapes)   ; FRAGMENT granularity: (M N K) triples
    (:wgmma-shapes                . :mma-shapes)   ; 161: WARPGROUP granularity
    (:mma-lowerings               . :lowerings)    ; 156: ordered; first is the default
    (:stream-occupancy-target     . :pos-int))     ; 182: MEASURED; threads per CU for stream kernels
  "Endeavor 130: canonical hardware-profile keys and their value types.

   Endeavour 182 added :stream-occupancy-target -- MEASURED, threads per compute unit that a kernel
   with a stream loop (loop-vector-stride) should target on this device.  On PTX it becomes launch
   bounds (.maxntid + .minnctapersm = target / workgroup size), which sets ptxas's register budget.
   Absent => no bound (ptxas's default, full occupancy).  H100 SXM: 1024 (half occupancy at 64
   registers beat full occupancy at 32 for every streaming reduction, 2026-10-08).

   Endeavour 161 added :wgmma-shapes, and it is a SEPARATE KEY rather than more entries in
   :mma-shapes for a concrete reason.  :mma-shapes is FRAGMENT granularity -- (8 16 8) for Intel
   XMX, (16 8 8) for NVIDIA mma.sync -- and roughly eighteen call sites read it as such,
   including the register-tile fragment decomposition (%mma-fragment-mn) and %spv-mma-shape.
   wgmma's (64 N K) is WARPGROUP granularity: M is 64 because a warpgroup is 128 threads, and N
   runs to 256.  Mixing warpgroup triples into :mma-shapes would feed those dims to fragment math.

   GRANULARITY IS A DIFFERENT AXIS FROM ELEMENT TYPE.  Endeavour 155 typed the ENTRIES, adding
   the 4-list (half 8 16 16) beside the bare (8 16 8), because a triple alone cannot say what
   element type it is a shape FOR.  A triple cannot say what LEVEL it describes either, and that
   is what this key adds.  The entry GRAMMAR is deliberately reused unchanged -- the value type
   is still :mma-shapes -- so %mma-shape-entry-dims and %mma-shape-for-elem apply verbatim and a
   part may write (bfloat16 64 256 16) here exactly as it would there.

   Both keys are OPTIONAL.  A profile that declares neither behaves precisely as before.

   Endeavour 156 added :mma-lowerings -- the code-generation strategies this hardware can drive
   its matrix engines with, most-preferred first.  Absent means (:coop-matrix), the portable
   SPV_KHR_cooperative_matrix path every backend has had until now.

   Endeavor 144 added two.  :max-registers-per-thread became :pos-int-or-modes (D4) -- a scalar
   for a fixed per-thread allocation, or an ascending list of selectable modes for hardware whose
   register file is a JIT-time choice.  :tile-visit-strip-width (Phase 1 revision) is the
   MEASURED column-strip width for grouped tile-stride visit order on this machine; 1 or absent
   means walk linearly.  It is deliberately a measured constant rather than a derived one -- see
   the block comment in src/hardware-profile.lisp for the two-device data that refuted the
   derivation.")

;; src/analysis/core.lisp  (beside *kernel-dispatch-declarations*)
(defvar *kernel-occupancy-targets* (make-hash-table :test 'equal)
  "Endeavour 182.  Kernel name -> its DECLARED (occupancy-target N) value: a positive integer, or NIL
   for an explicit opt-out.  A kernel ABSENT from the table declared nothing, so the hardware profile's
   :stream-occupancy-target applies if the kernel streams.  Written by internal-def-function for every
   entry point it analyzes (and removed when the declaration is gone), so a recompile cannot see a stale
   entry.")

;; src/analysis/core.lisp
(defvar *stream-functions* (make-hash-table :test 'equal)
  "Endeavour 182.  Function name -> T when its own body contains a stream loop (a loop-vector-stride,
   which reduce-vec expands to).  Recorded by %expand-loop-vector-stride-form against
   *analyzing-function*.  A stream loop in a separately defined grid function marks THAT function, not
   the kernel calling it -- such a kernel gets no automatic bound (declare one).")

;; src/analysis/core.lisp
(defvar *analyzing-function* nil
  "Endeavour 182.  The name of the function internal-def-function is analyzing, or NIL.")

;; src/analysis/core.lisp
(defun %declared-local-size-dims (declarations)
  "Endeavour 182.  The compile-time workgroup extents from a (local-size :set-to X) among DECLARATIONS --
   X an integer, a list of integers, or a quoted list -- as a list of 1-3 integers; NIL when the kernel
   declares none, or one not fixed at compile time."
  (let* ((decl (find "LOCAL-SIZE" declarations
                     :key (lambda (x) (when (and (consp x) (symbolp (car x))) (symbol-name (car x))))
                     :test #'string-equal))
         (v (and decl (getf (rest decl) :set-to)))
         (v (if (and (consp v) (symbolp (car v)) (string-equal (symbol-name (car v)) "QUOTE")) (second v) v)))
    (cond ((and (integerp v) (plusp v)) (list v))
          ((and (consp v) (<= 1 (length v) 3) (every (lambda (n) (and (integerp n) (plusp n))) v)) v)
          (t nil))))

;; src/analysis/core.lisp
(defun %parse-occupancy-target-decl (name declarations)
  "Endeavour 182.  Validates kernel NAME's (occupancy-target N) among DECLARATIONS.  Returns
   (values present-p value): PRESENT-P is NIL when there is no such declaration; VALUE is a positive
   integer (threads per compute unit) or NIL (opt out of the profile's automatic bound)."
  (let ((decl (find "OCCUPANCY-TARGET" declarations
                    :key (lambda (x) (when (and (consp x) (symbolp (car x))) (symbol-name (car x))))
                    :test #'string-equal)))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error
                    :message (format nil "Kernel ~a: ~?" name fmt args)
                    :source-location nil)))
      (cond
        ((null decl) (values nil nil))
        ((/= (length (rest decl)) 1)
         (fail "(occupancy-target ...) takes exactly one value -- threads per compute unit, or nil to turn the hardware profile's automatic bound off -- got ~s." (list decl)))
        (t
         (let ((v (second decl)))
           (cond
             ((null v) (values t nil))
             ((not (and (integerp v) (plusp v)))
              (fail "(occupancy-target ~s): the target must be a positive integer literal (threads per compute unit) or nil.  It becomes a launch bound in the PTX, so it has to be known at compile time." (list v)))
             (t
              (let ((dims (%declared-local-size-dims declarations)))
                (unless dims
                  (fail "(occupancy-target ~a) needs a compile-time workgroup size -- declare (local-size :set-to ...) -- because the target is THREADS per compute unit and the launch bound is a number of workgroups." (list v)))
                (let ((wg (reduce #'* dims)))
                  (when (< v wg)
                    (fail "(occupancy-target ~a) is less than one workgroup of ~a threads, so no launch bound can express it.  Use at least ~a, or nil." (list v wg wg))))
                (values t v))))))))))

;; src/analysis/core.lisp  (FOLD: the binding and the occupancy parse go inside internal-def-function,
;; next to the cluster-size parse; this wrapper shape cannot be pasted into src/)
(defvar *182-internal-def-function-base* (fdefinition 'internal-def-function))

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Endeavour 182 wrapper: binds *analyzing-function* (so a stream loop can be attributed to the function
   it is in) and, for an entry point, records its (occupancy-target ...) in *kernel-occupancy-targets*,
   then analyzes as before."
  (let ((entry-p (loop for d in declarations
                       thereis (and (listp d) (symbolp (first d))
                                    (string-equal (symbol-name (first d)) "ENTRY-POINT")))))
    (when name
      (remhash name *stream-functions*)
      (when entry-p
        (multiple-value-bind (present value) (%parse-occupancy-target-decl name declarations)
          (if present
              (setf (gethash name *kernel-occupancy-targets*) value)
              (remhash name *kernel-occupancy-targets*)))))
    (let ((*analyzing-function* name))
      (funcall *182-internal-def-function-base* name params declarations body location))))

;; src/analysis/control.lisp  (FOLD: one line at the top of %expand-loop-vector-stride-form)
(defvar *182-expand-lvs-base* (fdefinition '%expand-loop-vector-stride-form))

;; src/analysis/control.lisp
(defun %expand-loop-vector-stride-form (&rest args)
  "Endeavour 182 wrapper: notes that the function being analyzed contains a stream loop, then expands
   as before."
  (when *analyzing-function*
    (setf (gethash *analyzing-function* *stream-functions*) t))
  (apply *182-expand-lvs-base* args))

;; src/codegen.lisp
(defun %effective-occupancy-target (kname)
  "Endeavour 182.  The threads-per-compute-unit target for entry point KNAME, and where it came from:
   (values N :declared), (values N :profile), or NIL.  A declaration always wins -- including
   (occupancy-target nil), which turns the bound off.  The profile's :stream-occupancy-target applies
   only to a kernel whose own body has a stream loop."
  (multiple-value-bind (declared present) (gethash kname *kernel-occupancy-targets*)
    (cond (present (if declared (values declared :declared) nil))
          ((gethash kname *stream-functions*)
           (let ((n (getf (active-hardware-profile) :stream-occupancy-target)))
             (if n (values n :profile) nil)))
          (t nil))))

;; src/codegen.lisp
(defun %apply-occupancy-bound (func kname module)
  "Endeavour 182.  On PTX, stamps entry point FUNC with the launch bounds for its occupancy target:
   \"nvvm.maxntid\" (the workgroup extents) and \"nvvm.minctasm\" (target / workgroup size, the minimum
   number of resident workgroups per compute unit), which LLVM lowers to .maxntid / .minnctapersm.
   ptxas derives its register budget from them.  Nothing on other backends: launch bounds are a PTX
   construct.  A PROFILE target this kernel cannot express (no compile-time workgroup size, or a
   workgroup bigger than the target) is skipped with a note; a DECLARED one was refused at analysis."
  (when (eq *target-backend* :ptx)
    (multiple-value-bind (target source) (%effective-occupancy-target kname)
      (when target
        (let* ((decls (gethash kname *kernel-dispatch-declarations*))
               (local-decl (getf decls :local-size))
               (dims (and local-decl (%declared-local-size-dims (list local-decl))))
               (wg (and dims (reduce #'* dims))))
          (if (or (null wg) (< target wg))
              (log:info "Kernel ~a: ~(~a~) occupancy target ~a not applied (workgroup ~a)"
                        kname source target (or wg "not fixed at compile time"))
              (let ((ctx (llvm-get-module-context module)))
                (flet ((stamp (key val)
                         (llvm-add-attribute-at-index
                          func +llvm-attribute-function-index+
                          (llvm-create-string-attribute ctx key (length key) val (length val)))))
                  (let ((maxntid (format nil "~{~a~^,~}" dims))
                        (minctasm (format nil "~a" (floor target wg))))
                    (log:info "Kernel ~a: ~(~a~) occupancy target ~a -> .maxntid ~a, .minnctapersm ~a"
                              kname source target maxntid minctasm)
                    (stamp "nvvm.maxntid" maxntid)
                    (stamp "nvvm.minctasm" minctasm))))))))))

;; src/codegen.lisp  (FOLD: %apply-cluster-dims-attribute's caller calls %apply-occupancy-bound next to it)
(defvar *182-apply-cluster-dims-base* (fdefinition '%apply-cluster-dims-attribute))

;; src/codegen.lisp
(defun %apply-cluster-dims-attribute (func semantic-function module)
  "Endeavor 152 (see src/codegen.lisp); endeavour 182 wrapper: also stamps the entry point's launch
   bounds for its occupancy target."
  (prog1 (funcall *182-apply-cluster-dims-base* func semantic-function module)
    (%apply-occupancy-bound func (semantic-function-name semantic-function) module)))

;; src/mma.lisp  (spec validators, beside validate-ptx-has-nounroll-pragma)
(defun %ptx-minnctapersm (ptx-text)
  "Endeavour 182.  The integer of the first .minnctapersm directive in PTX-TEXT, or NIL."
  (let ((p (search ".minnctapersm" ptx-text)))
    (and p (parse-integer ptx-text :start (+ p (length ".minnctapersm")) :junk-allowed t))))

;; src/mma.lisp
(defun %validate-ptx-minnctapersm (ptx-text expected)
  (let ((got (%ptx-minnctapersm ptx-text)))
    (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
          ((eql got expected)
           (or (search ".maxntid" ptx-text)
               (progn (format t "FAIL: .minnctapersm ~a without a .maxntid~%" got) nil)))
          (t (format t "FAIL: expected .minnctapersm ~a in the PTX, found ~a.~%" expected got) nil))))

;; src/mma.lisp
(defun validate-ptx-minnctapersm-4 (file ptx-text)
  "Endeavour 182: the entry carries launch bounds with .minnctapersm 4 (and a .maxntid)."
  (declare (ignore file))
  (%validate-ptx-minnctapersm ptx-text 4))

;; src/mma.lisp
(defun validate-ptx-minnctapersm-2 (file ptx-text)
  "Endeavour 182: the entry carries launch bounds with .minnctapersm 2 (and a .maxntid)."
  (declare (ignore file))
  (%validate-ptx-minnctapersm ptx-text 2))

;; src/mma.lisp
(defun validate-ptx-no-minnctapersm (file ptx-text)
  "Endeavour 182: the entry carries NO launch bounds -- ptxas keeps its default register budget."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((or (search ".minnctapersm" ptx-text) (search ".maxntid" ptx-text))
         (format t "FAIL: unexpected launch bounds (.maxntid / .minnctapersm) in the PTX.~%") nil)
        (t t)))
