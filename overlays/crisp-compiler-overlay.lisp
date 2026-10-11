;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)

(in-package :crisp.compiler)


;;;; ===========================================================================================
;;;; ENDEAVOUR 184 cas-lowering, step 1 -- (return-from-loop)
;;;;   Decisions D1-D6: tests/spec/184-cas-lowering/cas-lowering.md
;;;; ===========================================================================================

;; src/semantic.lisp  (new struct -- next to semantic-while)
(defstruct semantic-return-from-loop
  "Represents (return-from-loop): leave the innermost lexically enclosing dotimes-family loop.
   Endeavour 184.  Takes no value and yields none (type void)."
  type
  source-location)

;; src/analysis/control.lisp  (defvars -- near *in-divergent-conditional*)
(defvar *loop-exit-context* nil
  "Endeavour 184: what (return-from-loop) would leave, while a loop body is analysed.
   NIL    -- no enclosing dotimes-family loop: return-from-loop is refused (D3).
   :PLAIN -- dotimes or a non-+ 172 variant: return-from-loop is allowed.
   :PLUS  -- a + loop, which promises a uniform trip count: refused (D2).
   Bound by %analyze-loop-with-unroll, which every dotimes-family analyser goes through.")

(defvar *in-early-exit-loop* nil
  "Endeavour 184 D4: T while analysing the body of a loop that can exit early, or anything nested in
   one.  A barrier there is refused: a thread that has left never reaches a later iteration's barrier.")

;; src/codegen.lisp  (defvar -- near the loop codegen)
(defvar *loop-exit-targets* nil
  "Endeavour 184: a stack of one-element boxes, one per dotimes-family loop being generated, innermost
   first.  The first (return-from-loop) in a loop creates that loop's early-exit block and stores it
   in the box; the loop's :around method then branches that block to the loop's exit.")

;; src/analysis/control.lisp
(defun %rfl-head-name (form)
  "The SYMBOL-NAME of FORM's head when FORM is a cons headed by a symbol, else NIL.  Endeavour 184."
  (and (consp form) (symbolp (car form)) (symbol-name (car form))))

;; src/analysis/control.lisp
(defun %rfl-free-in-forms-p (forms)
  "Endeavour 184: T when the SURFACE forms FORMS contain a (return-from-loop) that belongs to the loop
   whose body they are -- one not inside a nested dotimes-family loop, which would own it instead.
   Lexical, like the construct: it does not look inside called functions.  Quoted data is skipped."
  (labels ((walk (x)
             (let ((h (%rfl-head-name x)))
               (cl:cond
                 ((not (consp x)) nil)
                 ((and h (string= h "RETURN-FROM-LOOP")) t)
                 ((and h (string= h "QUOTE")) nil)
                 ((and h (member h *dotimes-family-names* :test #'string=)) nil)
                 (t (loop for tail on x thereis (walk (car tail))))))))
    (some #'walk forms)))

;; src/analysis/control.lisp
(defun %rfl-plus-loop-p (expr)
  "T when EXPR is headed by a + loop (dotimes+, dec-times+, ...).  Endeavour 184 D2."
  (let ((h (%rfl-head-name expr)))
    (and h (plusp (length h)) (char= (cl:char h (1- (length h))) #\+))))

;; src/analysis/control.lisp  -- WRAPPER.  Fold-back: put the D2 check and the four bindings into
;; %analyze-loop-with-unroll itself, around its call to ANALYZER.
(defvar *184-orig-analyze-loop-with-unroll* (fdefinition '%analyze-loop-with-unroll))
(defun %analyze-loop-with-unroll (analyzer expr env context location)
  "Endeavour 180: strips the body's leading declarations, records the unroll request, and calls
   ANALYZER.  Endeavour 184: every dotimes-family loop comes through here, so this is where
   return-from-loop learns which loop it is in.
     D2 -- a + loop whose own body exits early is refused: a + loop promises a uniform trip count.
     D4 -- a loop whose own body exits early is analysed as DIVERGENT: a thread that has left never
           reaches a later iteration's barrier, so barriers and collectives inside are refused."
  (let ((plus-p (%rfl-plus-loop-p expr))
        (exits-p (%rfl-free-in-forms-p (cddr expr))))
    (log:debug "184 loop ~a: plus-p=~a exits-early=~a" (%rfl-head-name expr) plus-p exits-p)
    (when (and plus-p exits-p)
      (error 'crisp-compiler-error
        :message (format nil "return-from-loop cannot appear in ~(~a~).  A + loop promises a uniform trip count -- every thread of the workgroup runs the same iterations -- and an early exit taken per thread breaks that promise.  Use the plain form, ~(~a~), for a loop that may end early."
                         (%rfl-head-name expr)
                         (subseq (%rfl-head-name expr) 0 (1- (length (%rfl-head-name expr)))))
        :source-location location))
    (let ((*loop-exit-context* (if plus-p :plus :plain))
          (*in-early-exit-loop* (or *in-early-exit-loop* exits-p))
          (*in-divergent-conditional* (or *in-divergent-conditional* exits-p))
          (*divergent-scope-depth* (if exits-p (1+ *divergent-scope-depth*) *divergent-scope-depth*)))
      (funcall *184-orig-analyze-loop-with-unroll* analyzer expr env context location))))

;; src/analysis/control.lisp
(defun analyze-return-from-loop-expression (expr env context location)
  "Analyzes (return-from-loop).  Endeavour 184 D1-D3: legal only in the body of a dotimes or a non-+
   172 variant, lexically.  Returns a semantic-return-from-loop node (type void)."
  (declare (ignore env context))
  (unless (= (length expr) 1)
    (error 'crisp-compiler-error
      :message (format nil "return-from-loop takes no arguments, got ~a.  It leaves the loop and yields no value -- store a result in a variable before leaving." (1- (length expr)))
      :source-location location))
  (cl:case *loop-exit-context*
    (:plain
     (make-semantic-return-from-loop :type 'void :source-location location))
    (:plus
     ;; Normally refused at the loop by %analyze-loop-with-unroll; this is the backstop.
     (error 'crisp-compiler-error
       :message "return-from-loop cannot appear in a + loop.  A + loop promises a uniform trip count, and an early exit taken per thread breaks that promise.  Use the plain form for a loop that may end early."
       :source-location location))
    (t
     (error 'crisp-compiler-error
       :message "return-from-loop has no enclosing loop.  It leaves the innermost dotimes-family loop (dotimes, dec-times, do-power-step, ...) that LEXICALLY contains it.  A function called from inside a loop cannot leave its caller's loop."
       :source-location location))))

;; src/analysis/control.lisp
(defun %rfl-wrap-stride-analyzer (name analyzer)
  "Endeavour 184 D3: wraps the analyser of the stride loop NAME so that a return-from-loop belonging to
   it is refused.  A stride loop expands into a hidden dotimes; without this, return-from-loop would
   silently leave that hidden loop."
  (lambda (expr env context location)
    (when (%rfl-free-in-forms-p (cdr expr))
      (error 'crisp-compiler-error
        :message (format nil "return-from-loop cannot leave a stride loop (~(~a~)).  The stride loop decides which elements each thread visits, and leaving it early would silently skip elements.  To stop early over part of the work, write a dotimes inside the stride body and leave that." name)
        :source-location location))
    (funcall analyzer expr env context location)))

;; src/analysis/control.lisp  -- WRAPPER.  Fold-back: add the RETURN-FROM-LOOP registration and the
;; stride-loop wrapping to the end of register-control-analyzers.
(defvar *184-orig-register-control-analyzers* (fdefinition 'register-control-analyzers))
(defun register-control-analyzers ()
  "Registers the control-flow analysers.  Endeavour 184: also return-from-loop, and wraps every
   *-STRIDE loop's analyser with the D3 check."
  (prog1 (funcall *184-orig-register-control-analyzers*)
    (dolist (pkg (list (find-package :crisp-language) (find-package :crisp.compiler)))
      (when pkg
        (setf (gethash (intern "RETURN-FROM-LOOP" pkg) *expression-analyzers*)
              #'analyze-return-from-loop-expression)))
    (let ((wrapped '()))
      (maphash (lambda (sym fn)
                 (declare (ignore fn))
                 (let ((n (symbol-name sym)))
                   (when (and (> (length n) 7) (string= "-STRIDE" n :start2 (- (length n) 7)))
                     (push sym wrapped))))
               *expression-analyzers*)
      (dolist (sym wrapped)
        (setf (gethash sym *expression-analyzers*)
              (%rfl-wrap-stride-analyzer (symbol-name sym) (gethash sym *expression-analyzers*))))
      (log:debug "184: return-from-loop registered; stride analysers wrapped: ~a" wrapped))))

;; src/analysis/control.lisp  -- WRAPPER.  Fold-back: add the *in-early-exit-loop* clause to the cond in
;; %warp-spec-check-sync, after the fence exemption and before *in-divergent-conditional*.
(defvar *184-orig-warp-spec-check-sync* (fdefinition '%warp-spec-check-sync))
(defun %warp-spec-check-sync (builtin-kw name-str location)
  "Endeavour 184 D4: a barrier inside a loop that can exit early gets its own message (the divergent-
   conditional one would name if / when / unless / cond, which is not where the problem is).  Fences
   stay exempt: they wait for no one.  Everything else is the original check."
  (when (and *in-early-exit-loop*
             (not (member builtin-kw '(:mem-fence :mem-fence-workgroup))))
    (error 'crisp-compiler-error
      :message (format nil "~a cannot appear inside a loop that can exit early (one containing return-from-loop).  A thread that has left the loop never reaches this barrier on a later iteration, so the threads still inside wait for it forever.  Move the barrier out of the loop, or end the loop by its bound instead of by return-from-loop." name-str)
      :source-location location))
  (funcall *184-orig-warp-spec-check-sync* builtin-kw name-str location))

;; src/analysis/core.lisp  -- WRAPPER.  Fold-back: add
;;   (semantic-return-from-loop (semantic-return-from-loop-type node))
;; to the etypecase in semantic-node-type.
(defvar *184-orig-semantic-node-type* (fdefinition 'semantic-node-type))
(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.  Endeavour 184: semantic-return-from-loop."
  (if (semantic-return-from-loop-p node)
      (semantic-return-from-loop-type node)
      (funcall *184-orig-semantic-node-type* node)))

;; src/analysis/core.lisp  -- WRAPPER.  Fold-back: add
;;   (semantic-return-from-loop (semantic-return-from-loop-source-location node))
;; to the etypecase in semantic-node-source-location.
(defvar *184-orig-semantic-node-source-location* (fdefinition 'semantic-node-source-location))
(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.  Endeavour 184: semantic-return-from-loop."
  (if (semantic-return-from-loop-p node)
      (semantic-return-from-loop-source-location node)
      (funcall *184-orig-semantic-node-source-location* node)))

;; src/codegen.lisp
(defun %184-call-with-loop-exit-target (builder thunk)
  "Endeavour 184: generates a dotimes-family loop by calling THUNK with a fresh box pushed on
   *loop-exit-targets*.  If the body used (return-from-loop), the box holds the early-exit block;
   once the loop is generated -- the builder then sits at the loop's exit block -- that block is
   branched to the exit.  Returns THUNK's values."
  (let* ((box (list nil))
         (*loop-exit-targets* (cons box *loop-exit-targets*)))
    (multiple-value-prog1 (funcall thunk)
      (let ((early (car box)))
        (when early
          (let ((exit (llvm-get-insert-block builder)))
            (log:debug "184: loop has an early exit; joining it to the loop exit")
            (llvm-position-builder-at-end builder early)
            (llvm-build-br builder exit)
            (llvm-position-builder-at-end builder exit)))))))

;; src/codegen.lisp  -- Fold-back: wrap the body of the semantic-dotimes method instead.
(defmethod generate-node-ir :around ((node semantic-dotimes) builder module var-env
                                     di-builder di-scope location-map)
  "Endeavour 184: gives (return-from-loop) in this loop's body a target.  See
   %184-call-with-loop-exit-target."
  (declare (ignore module var-env di-builder di-scope location-map))
  (%184-call-with-loop-exit-target builder (lambda () (call-next-method))))

;; src/codegen.lisp  -- Fold-back: wrap the body of the semantic-loop-variant method instead.
(defmethod generate-node-ir :around ((node semantic-loop-variant) builder module var-env
                                     di-builder di-scope location-map)
  "Endeavour 184: gives (return-from-loop) in this loop's body a target.  See
   %184-call-with-loop-exit-target."
  (declare (ignore module var-env di-builder di-scope location-map))
  (%184-call-with-loop-exit-target builder (lambda () (call-next-method))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-return-from-loop) builder module var-env
                             di-builder di-scope location-map)
  "Generates (return-from-loop): an unconditional branch to the innermost loop's early-exit block
   (created on first use), then a fresh block with no predecessors for whatever the body emits after
   it -- so every later `terminator-p` check in the loop codegen still sees an open block, and the
   dead code is removed by the optimiser.  Endeavour 184."
  (declare (ignore module var-env di-builder di-scope location-map))
  (let ((box (first *loop-exit-targets*)))
    (unless box
      (error "Compiler error: return-from-loop reached codegen outside any loop (the analyser should have refused it)."))
    (let ((fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
      (unless (car box)
        (setf (car box) (llvm-append-basic-block fn "loop_early_exit")))
      (llvm-build-br builder (car box))
      (llvm-position-builder-at-end builder (llvm-append-basic-block fn "after_return_from_loop"))
      (values nil nil))))

;; src/autodiff.lisp  -- WRAPPER.  Fold-back: put the D5 check at the top of %gfw-process-dotimes.
(defvar *184-orig-gfw-process-dotimes* (fdefinition '%gfw-process-dotimes))
(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  "Endeavour 184 D5: a loop that can exit early is refused -- the backward pass replays the loop in
   reverse and needs each thread's trip count, which return-from-loop makes data-dependent.  A real
   gap, refused rather than differentiated wrongly.  Otherwise the original."
  (when (%rfl-free-in-forms-p body)
    (error 'crisp-compiler-error
      :message (format nil "--differentiate: a loop that can exit early (~(~a~) containing return-from-loop) is not differentiable yet.  The backward pass replays the loop in reverse, and to do that it needs each thread's per-thread trip count, which an early exit makes data-dependent.  Crisp refuses rather than replaying the wrong iterations.  End the loop by its bound to differentiate it."
                       (%rfl-head-name form))
      :source-location nil))
  (funcall *184-orig-gfw-process-dotimes* form emit-fn process-form-fn binding body local-vars
           adjoint-map intermediate-zero))

;; src/analysis/ops.lisp
(defun %atomic-binop-expand (expr)
  "The forward lowering: a bounded CAS retry loop that returns the prior value.
   Endeavour 184: the loop LEAVES on success with (return-from-loop).  Before 184 it was a dotimes+
   guarded by (when (= done 0) ...), so every contender ran all global-size + 1 iterations even when it
   won on the first try.  It is a plain dotimes now: a + loop promises a uniform trip count, which an
   early exit breaks (184 D2) -- and it always runs inside per-thread code anyway."
  (unless (= (length expr) 4)
    (error 'crisp-compiler-error
           :message (format nil "atomic-binop!: expected 3 arguments (location binop-f arg), got ~a.  The form is (atomic-binop! location #'op arg)."
                            (1- (length expr)))
           :source-location nil))
  (multiple-value-bind (loc fn arg) (%atomic-binop-parts expr)
    (let ((a    (gensym "AB-ARG"))
          (prev (gensym "AB-PREV"))
          (done (gensym "AB-DONE"))
          (r    (gensym "AB-R"))
          (old  (gensym "AB-OLD"))
          (new  (gensym "AB-NEW")))
      ;; ARG is bound ONCE outside the loop: it may be an arbitrary expression, and re-evaluating
      ;; it per retry would be both wasteful and wrong if it had side effects.
      `(let ((,a ,arg))
         ;; PREV is seeded from a read so it has the element type without needing a typed zero.
         ;; It is overwritten by the successful iteration; the seed value is never returned,
         ;; because the assert below refuses to let the loop finish unsuccessfully.
         (let ((,prev (~ ,@(cdr loc))))
           (let ((,done 0))
             ;; The bound is the contender count + 1 (175): a CAS fails only because another
             ;; thread's CAS succeeded, and each contender succeeds once.  get-global-LINEAR-size:
             ;; get-global-size has no analyzer.
             (dotimes (,r (+ (to-int (get-global-linear-size)) 1))
               (let ((,old (~ ,@(cdr loc))))
                 (let ((,new ,(%175-apply-binop fn old a)))
                   ;; The success FLAG, not the returned value -- see %atomic-cas-ok!.
                   (when (= (%atomic-cas-ok! ,loc ,old ,new) 1)
                     ;; On success memory held exactly OLD, which is what we read ourselves,
                     ;; so the "value before" needs nothing from the CAS itself.
                     (set! ,prev ,old)
                     (set! ,done 1)
                     (return-from-loop)))))
             (r-t-assert-0 (= ,done 1)
                           "atomic-binop!: the bounded CAS retry loop exhausted without succeeding, so this update was LOST.  The bound is global_size + 1, which is sound when each thread performs the operation once; it can be exceeded if atomic-binop! runs inside a loop, so that total successes on this location exceed the grid size.")
             ,prev))))))

;; src/analysis/ops.lisp
(defun %atomic-op-expand (expr)
  "The forward lowering: a bounded CAS retry loop returning the prior value.
   Mirrors %atomic-binop-expand exactly, minus the value argument -- including 184's early exit."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message (format nil "atomic-op!: expected 2 arguments (location op-f), got ~a.  The form is (atomic-op! location #'op), and the function is UNARY -- for a two-argument operator use (atomic-binop! location #'op arg)."
                            (1- (length expr)))
           :source-location nil))
  (multiple-value-bind (loc fn) (%atomic-op-parts expr)
    (let ((prev (gensym "AO-PREV"))
          (done (gensym "AO-DONE"))
          (r    (gensym "AO-R"))
          (old  (gensym "AO-OLD"))
          (new  (gensym "AO-NEW")))
      ;; No ARG to bind once here -- that is the whole difference from atomic-binop!.
      `(let ((,prev (~ ,@(cdr loc))))
         (let ((,done 0))
           ;; See %atomic-binop-expand for the bound and for why this is a plain dotimes.
           (dotimes (,r (+ (to-int (get-global-linear-size)) 1))
             (let ((,old (~ ,@(cdr loc))))
               (let ((,new ,(%175-apply-unop fn old)))
                 (when (= (%atomic-cas-ok! ,loc ,old ,new) 1)
                   (set! ,prev ,old)
                   (set! ,done 1)
                   (return-from-loop)))))
           (r-t-assert-0 (= ,done 1)
                         "atomic-op!: the bounded CAS retry loop exhausted without succeeding, so this update was LOST.  The bound is global_size + 1, which is sound when each thread performs the operation once; it can be exceeded if atomic-op! runs inside a loop, so that total successes on this location exceed the grid size.")
           ,prev)))))
