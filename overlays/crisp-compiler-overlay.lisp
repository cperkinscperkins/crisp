;;;; crisp-compiler-overlay.lisp — late-bound fixes for the CRISP.COMPILER package.
;;;;
;;;; APPEND full replacement definitions here while developing; they are loaded after src/ and
;;;; win by late binding.  Do NOT patch in place -- append, and note above each one which src
;;;; file it belongs to, so it can be folded back later.
;;;;
;;;; TWO THINGS THAT BITE (both learned the hard way, endeavour 165):
;;;;
;;;;   * A HANDLER REGISTERED BY OBJECT IS NOT LATE-BOUND.  src/autodiff.lisp does
;;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile), which captures
;;;;     the function OBJECT at load time.  Redefining that defun here is DEAD CODE until you
;;;;     also re-register.  The failure is partial and therefore nasty: a callee overridden by
;;;;     name goes live while its caller stays stale.
;;;;
;;;;   * NEVER PUT A DOUBLE QUOTE INSIDE A DOCSTRING.  It closes the string early and the rest of
;;;;     the prose becomes BODY FORMS -- the first bare word is then an unbound variable, and the
;;;;     build emits no warning.  It fails only when the function is CALLED.  Cost: a red CI.
;;;;
;;;; Emptied 2026-09-20: everything folded into src/ (endeavour 173 -- the four warp shuffles,
;;;; (warp-size), the let* rejection and BUG 066's _GRAD dispatch-declaration fix -- into
;;;; src/semantic.lisp, src/package.lisp, src/analysis/core.lisp, src/analysis/ops.lisp,
;;;; src/analysis/control.lisp, src/autodiff.lisp, src/codegen.lisp and src/mma.lisp).
;;;; Previously emptied 2026-09-19 (endeavour 172) and 2026-09-18 (endeavour 167).

(in-package :crisp.compiler)


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — reduce-warp (DEVELOPMENT DRAFT -- macro, needs a real src patch)
;;; ---------------------------------------------------------------------------
;;; Belongs in src/macros.lisp, plus the three package.lisp export/import sites every other
;;; user-facing form has.  Drafted here ONLY to test it.
;;;
;;; NOTE: this must NOT call export/import.  Mutating the package at overlay load makes
;;; SBCL signal a package-variance error when build.lisp re-processes package.lisp for its
;;; later targets ("CRISP.COMPILER also exports the following symbols").  Copying the
;;; macro-function onto the :crisp-language symbol reaches the reader without touching the
;;; package's export list.  In src/ this is unnecessary -- package.lisp imports the symbol.

(defun %reduce-warp-check-active-threads (active-threads)
  "Refuses a LITERAL active-threads wider than the warp it reduces.  A runtime value is left
   alone -- same split as 173's D5 xor-mask rule, where a literal mask is checked and a runtime
   one is the reduction idiom.  The design doc calls this case undefined behaviour; there is no
   reason to leave it undefined when the value is right there at compile time, and a silently
   wrong sum is the worst of the available outcomes."
  (let ((warp (%173-warp-size)))
    (when (and (integerp active-threads) (> active-threads warp))
      (error 'crisp-compiler-error
             :message (format nil "reduce-warp: ~a active threads is wider than the warp it reduces (~a lanes under the active hardware profile). A warp reduction cannot reach beyond its own warp; to combine more threads than that, reduce within each warp and then across warps (reduce-workgroup)."
                              active-threads warp)
             :source-location nil))))

;;; The convergence diagnostic.  reduce-warp expands to shuffle-xor, so 173's D6 check fires
;;; for free -- but it names SHUFFLE-XOR, a construct the user never wrote.  This internal form
;;; is emitted FIRST in the expansion so the error names reduce-warp instead.  It is an
;;; ANALYZED form rather than part of the macro because divergence is known at analysis time,
;;; not at macroexpansion time.
(defun %analyze-warp-collective-check (expr env context location)
  "Analyzer for (%warp-collective-check \"name\") -- runs D6 and emits nothing."
  (declare (ignore env context))
  (%shuffle-check-not-divergent (or (second expr) :|this warp collective|) location)
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

(defvar *orig-175-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load.")

(defun register-ops-analyzers ()
  "Overlay wrapper: the 173 registrations, plus 175's internal convergence-check form."
  (funcall *orig-175-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "%WARP-COLLECTIVE-CHECK" pkg) *expression-analyzers*)
              '%analyze-warp-collective-check)))))

(defun %175-apply-binop (fn a b)
  "The form applying binop FN to A and B.  A LITERAL #'op is inlined as a DIRECT call rather
   than emitted as (funcall #'op a b) -- two reasons, the second decisive:

     * a direct call is simply better code than an indirect one through a function value;
     * FUNCALL IS NOT DIFFERENTIABLE.  The AD walk refuses it (\"Function FUNCALL is not
       differentiable\"), so a reduction emitting funcall cannot be differentiated at all --
       whereas (+ a b) is differentiated by the ordinary arithmetic rules.

   A non-literal FN (a variable holding a function value) still goes through funcall and is
   still not differentiable; that is a genuine AD gap, not something this can paper over."
  (if (and (consp fn) (symbolp (car fn)) (string-equal (symbol-name (car fn)) "FUNCTION"))
      (list (second fn) a b)
      (list 'funcall fn a b)))

(defmacro reduce-warp (fn var identity &optional active-threads)
  "Reduce VAR across the current warp with the commutative binop FN, leaving the result in
   VAR in EVERY lane of the warp.  IDENTITY seeds the lanes outside ACTIVE-THREADS."
  (%reduce-warp-check-active-threads active-threads)
  (let ((s (gensym "RW-S")))
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (list `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       ;; The butterfly's first stride is warp/2, resolved AT MACROEXPANSION TIME to a plain
       ;; integer literal.  Emitting (/ (warp-size) 2) instead fails two ways: (warp-size)
       ;; folds to a UINT so `/` rejects the INT 2, and even coerced, a conversion expression
       ;; is a weaker thing to hand dec-times-by-half+, whose `+` contract demands a provably
       ;; uniform limit.  A literal is uniform by construction.  Expansion runs inside
       ;; anf-transform with *target-backend* and the profile already bound, and re-runs per
       ;; target pass, so a dual-backend spec gets 16 for bmg and 32 for ptx.
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         (set! ,var ,(%175-apply-binop fn `(shuffle-xor ,var ,s) var)))
       (compiler-no-op))))

(eval-when (:load-toplevel :execute)
  (let* ((cc  (find-package :crisp.compiler))
         (cl  (find-package :crisp-language))
         (ccs (find-symbol "REDUCE-WARP" cc)))
    (when (and ccs cl)
      (let ((cls (intern "REDUCE-WARP" cl)))
        (unless (eq cls ccs)
          (setf (macro-function cls) (macro-function ccs)))))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — the VJP of a BROADCAST shuffle (lifts 173's :idx refusal).
;;; ---------------------------------------------------------------------------
;;; src/autodiff.lisp  (replaces %shuffle-backward's :idx branch)
;;;
;;; y[L] = v[base(L) + (idx mod w)]  -- every lane of a segment reads the SAME lane, so an
;;; indexed shuffle with a UNIFORM index is a BROADCAST.  The transpose of a fan-out is a
;;; fan-in:
;;;
;;;     vbar[L] += SUM over j in segment(L) of g[j]     if (L mod w) == (idx mod w)
;;;     vbar[L] += 0                                    otherwise
;;;
;;; 173 refused this, and its message asserted that "a CONSTANT target is no simpler" than a
;;; runtime one.  That claim is wrong, and the axis it picked is the wrong one.  The question
;;; is not literal-vs-runtime, it is UNIFORM-vs-LANE-VARYING:
;;;
;;;   * a UNIFORM index (every lane reads one lane) is a broadcast -- transpose is the
;;;     segment reduction above, which is exact, allocation-free and needs no atomics;
;;;   * a LANE-VARYING index is a general gather -- several lanes may read the same source and
;;;     others none, so the transpose is a true scatter-add of unknown multiplicity.  THAT is
;;;     the hard case 173 described, and it is still refused.
;;;
;;; A compile-time literal is simply the case where uniformity is free to establish.  A
;;; uniform RUNTIME index is equally differentiable in principle and is left for later: Crisp
;;; has a uniformity pre-pass (endeavour 120), but it runs after the AD walk, so consulting it
;;; here is a sequencing change rather than a new rule.  The refusal below now says so.
;;;
;;; WHY THE BUTTERFLY IS INLINE rather than a reduce-warp call.  The sum is SEGMENT-scoped --
;;; lane L must collect only its own width-w segment -- and reduce-warp reduces a whole warp.
;;; Its active-threads argument is a different concept (which lanes CONTRIBUTE, not how wide
;;; the exchange is), so it cannot express this.  The strides run w/2 .. 1 and an xor by a mask
;;; below w never leaves its segment, so passing the width through to shuffle-xor keeps each
;;; segment's reduction independent.
;;;
;;; The `let` placing the reduction OUTSIDE the conditional is the same D6 obligation the
;;; :up/:down branches document: a warp collective may not sit in divergent control flow, so
;;; the butterfly runs unconditionally in every lane and only its RESULT is gated.

(defun %175-broadcast-vjp-form (g value-adj idx tail width-form zero)
  "The adjoint statement for a broadcast shuffle.  See the section header for the derivation."
  (let* ((explicit-width (second tail))            ; (index [width]) -- width if written
         (w-lit (or (and (integerp explicit-width) explicit-width) (%173-warp-size)))
         (tot (intern "%RW-TOT" (find-package :crisp.compiler)))
         (st  (intern "%RW-S"   (find-package :crisp.compiler)))
         (xor-tail (when explicit-width (list explicit-width))))
    `(let ((,tot ,g))
       (dec-times-by-half+ (,st ,(floor w-lit 2))
         (set! ,tot (+ (shuffle-xor ,tot ,st ,@xor-tail) ,tot)))
       (set! ,value-adj
             (+ ,value-adj
                (if (= (rem (to-ulong (warp-lane)) (to-ulong ,width-form))
                       (rem (to-ulong ,idx) (to-ulong ,width-form)))
                    ,tot
                    ,zero))))))

(defun %175-raw-integer-literal (form)
  "The integer value of a raw literal FORM, or NIL.

   Needed because the AD walk sees RAW forms and Crisp spells a typed literal as a SUFFIXED
   SYMBOL: `2ul` is read by the CL reader as the symbol |2UL|, and only later does
   %try-parse-typed-literal (src/analysis/core.lisp) turn it into a ulong semantic-literal.  So
   (integerp (third expr)) is false for exactly the form this VJP is written for.

   Only the INTEGER suffixes are accepted.  A float-suffixed literal (2.0f, 3d) is not a legal
   lane index, so returning NIL for it is correct rather than merely conservative."
  (cond
    ((integerp form) form)
    ((symbolp form)
     (let* ((name (symbol-name form))
            (npos (or (position-if-not #'digit-char-p name) (length name))))
       (when (and (> npos 0)
                  (member (subseq name npos)
                          '("" "U" "L" "UL" "S" "US" "C" "UC")
                          :test #'string=))
         (parse-integer name :end npos))))
    (t nil)))

(defvar *orig-175-shuffle-backward* (fdefinition '%shuffle-backward)
  "Captured once at overlay load.")

(defun %shuffle-backward (v expr emit-fn local-adj-fn)
  "Overlay wrapper: handles the :idx (broadcast) case 173 refused; everything else unchanged."
  (if (and (eq (%shuffle-form-op expr) :idx)
           (%175-raw-integer-literal (third expr)))
      (let* ((value (second expr))
             (idx   (third expr))
             (tail  (cddr expr))
             (w     (%shuffle-form-width-form expr))
             (g     (funcall local-adj-fn v)))
        (log:debug "175 broadcast VJP: ~a := ~a" v expr)
        (if (and value (symbolp value))
            (funcall emit-fn (%175-broadcast-vjp-form
                              g (funcall local-adj-fn value) idx tail w `(- ,g ,g)))
            (log:debug "175 broadcast VJP: operand ~a is not a symbol; nothing to accumulate" value))
        t)
      (if (eq (%shuffle-form-op expr) :idx)
          ;; KEEP THE PHRASE "runtime target lane".  173-shuffles/errors/07 matches on it
          ;; (CHECK-FAIL), and "no VJP is registered for an indexed shuffle" is its FAIL-WITH
          ;; string -- rewording either silently turns that spec from a real check into a
          ;; failure, which is how this was caught.
          (error "~A: no VJP is registered for an indexed shuffle with a runtime target lane.  A CONSTANT target lane IS supported: every lane then reads the same lane, so the form is a broadcast whose transpose is a segment-wide sum, which differentiates exactly.  The distinction that matters is UNIFORM vs LANE-VARYING, not constant vs runtime -- a lane-varying index is a general gather, where several lanes may read the same source and others none, so its transpose is a scatter-add of unknown multiplicity and not a shuffle at all.  A uniform RUNTIME index is differentiable in principle, but Crisp cannot tell it apart here because the uniformity pre-pass runs after the autodiff walk.  Use a constant target lane, or shuffle-xor / shuffle-up / shuffle-down, all of which differentiate exactly; or if this kernel really is forward-only, SKIP-WITH[--differentiate]."
                 (car expr))
          (funcall *orig-175-shuffle-backward* v expr emit-fn local-adj-fn))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — thread-selection sugar (DEVELOPMENT DRAFT -- macros, need a src patch)
;;; ---------------------------------------------------------------------------
;;; Belong in src/macros.lisp (or beside reduce-warp), plus the three package.lisp sites.
;;;
;;; SCOPE.  ideal_001.md specifies a whole family -- when-thread-is / abs-when-thread-is,
;;; when-group-is, when-global-linear-id-is / when-local-linear-id-is, when-is-last-workgroup,
;;; each with 1/2/3-D variants.  NONE of it exists yet.  This endeavour implements only the two
;;; forms the reductions chapter actually uses, in their 1-D form; the rest is its own piece of
;;; work.  (The multi-dimensional grammar in the doc, `(when-thread-in-group-is x-id y-id
;;; <expr>)`, is also ambiguous for a multi-STATEMENT body -- it cannot be told apart from a
;;; 1-D election with two body forms.  That wants resolving before the N-D variants are built.)
;;;
;;; when-thread-in-warp-is is listed under "## Forgotten" in ideal_001.md: the reductions
;;; chapter uses it and nothing defines it.  Semantics adopted here, and pinned by spec 06:
;;; the body runs in the named lane of EVERY warp -- a per-warp election, not a per-workgroup
;;; one.  That is what a warp leader writing its partial into a scratchpad needs.
;;;
;;; WHY MACROS EXPANDING TO `when` ARE ENOUGH FOR THE DEADLOCK GUARANTEE.
;;;
;;; The doc promises something stronger than the generic analysis:  "The compiler will _attempt_
;;; to detect the deadlock possibility in a generic construction, but due to variables,
;;; assignments, etc that guarantee is not strong.  Whereas in when-thread-in-group-is it is a
;;; surety."
;;;
;;; *in-divergent-conditional* is set by ANY conditional whose test did not constant-fold
;;; (src/analysis/control.lisp), so expanding to `when` over a lane/local-id test sets it every
;;; time -- and %tlc-check-not-divergent then refuses sync-workgroup, while
;;; %shuffle-check-not-divergent refuses a warp collective.  The surety comes from the form
;;; being divergent BY CONSTRUCTION: there is no way to write one whose body every thread
;;; reaches, so there is no analysis for an intervening variable or assignment to defeat.
;;; Guarded by errors/03 (workgroup barrier) and errors/04 (warp collective).

(defmacro when-thread-in-warp-is (lane &body body)
  "Runs BODY only in lane LANE of EVERY warp -- a per-WARP election.
   A warp collective in BODY is refused: only one lane arrives.  See spec 06, errors/04."
  `(when (= (to-int (warp-lane)) ,lane)
     ,@body))

(defmacro when-thread-in-group-is (id &body body)
  "Runs BODY only in thread ID of the workgroup -- a per-WORKGROUP election.
   Per ideal_001.md this is an implicit (when (= someId (get-local-id 0)) ...).
   sync-workgroup in BODY is refused: only one thread arrives.  See spec 07, errors/03."
  ;; get-local-LINEAR-id, NOT (get-local-id 0), despite ideal_001.md specifying the latter.
  ;; A comparison against (get-local-id 0) is unreliable on the SPIR-V path: the LLVM IR is
  ;; structurally identical to the linear-id form -- same global, same extractelement 0, same
  ;; icmp -- yet at run time the branch is never taken, and whether it misbehaves depends on
  ;; what else in the kernel reads the builtin.  Measured on BMG; see plan/bugs.md BUG 079.
  ;; The linear id is also the better spelling for a 1-D election: it is the flattened index and
  ;; is unambiguous whatever the workgroup's dimensionality.
  `(when (= (to-int (get-local-linear-id)) ,id)
     ,@body))

(eval-when (:load-toplevel :execute)
  ;; See the reduce-warp draft above for why this copies macro-function rather than exporting:
  ;; mutating the package's export list at overlay load makes build.lisp's later targets fail
  ;; with a package-variance error.  The src patch imports these properly instead.
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (name '("WHEN-THREAD-IN-WARP-IS" "WHEN-THREAD-IN-GROUP-IS"))
      (let ((ccs (find-symbol name cc)))
        (when (and ccs cl)
          (let ((cls (intern name cl)))
            (unless (eq cls ccs)
              (setf (macro-function cls) (macro-function ccs)))))))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — reduce-workgroup (DEVELOPMENT DRAFT; measurement vehicle)
;;; ---------------------------------------------------------------------------
;;; Drafted to MEASURE option 3 for its autodiff: let the macro expand and let the ordinary
;;; backward walk reverse the expansion.  If the resulting _GRAD kernel is heavy, the construct
;;; becomes an analyzed form with a semantic VJP instead (option 1).
;;;
;;; BARRIER PLACEMENT IS CORRECTED from reductions-excerpt.md, which puts the sweep's
;;; sync-workgroup INSIDE (when (< local-id num-warps) ...).  Crisp refuses that outright -- a
;;; workgroup collective in a thread-divergent conditional deadlocks -- and the excerpt also
;;; leaves the barrier OUTSIDE the halving loop, so successive passes are not separated and a
;;; pass can read a slot the previous one has not written.  Chris confirmed ideal_001.md does
;;; not carry the mistake.  Correct shape: barrier INSIDE the loop, OUTSIDE the guard, and the
;;; loop must be the `+` (uniform) variant so every thread reaches the same barriers.
;;;
;;; num-warps is computed AT RUNTIME from get-local-linear-size / warp-size, not folded from the
;;; declared local-size.  Same reasoning as the scratch sizing (BUG 070): the enqueuer owns the
;;; geometry, so the kernel adapts rather than baking in author intent.  dec-times-by-half+
;;; accepts a runtime-uniform limit, which is what makes this possible.
;;;
;;; :local-scratch-vec IS REQUIRED IN THIS DRAFT.  Auto-generating it needs the element type of
;;; VAR at macroexpansion time, and Crisp has no macro-time type-of; the doc's reference
;;; implementation writes (make-scratch-vector (type-of someVar) ...) as if it did.  Resolving
;;; that is orthogonal to the AD question being measured, so the caller passes one.

(defmacro reduce-workgroup (fn var identity &key local-scratch-vec return-vec message)
  "Reduce VAR across the whole workgroup with the commutative binop FN, leaving the result in
   VAR in EVERY thread.  Phase 1 is a per-warp reduce-warp; phase 2 sweeps the warp partials
   through LOCAL-SCRATCH-VEC, which must hold one element per warp."
  (declare (ignore message))
  (unless local-scratch-vec
    (error 'crisp-compiler-error
           :message "reduce-workgroup: :local-scratch-vec is required in this build.  Auto-generating it needs VAR's element type at macroexpansion time, which Crisp cannot yet supply.  Pass e.g. (make-scratch-vector float :match-num-warps-per-workgroup)."
           :source-location nil))
  (let ((s (gensym "RWG-S"))
        (nw (gensym "RWG-NW"))
        (lid (gensym "RWG-LID")))
    `(progn
       ;; Phase 1 -- each warp reduces itself; every lane then holds its warp's partial.
       (reduce-warp ,fn ,var ,identity)
       (when-thread-in-warp-is 0
         (set! (~ ,local-scratch-vec (to-int (warp-id))) ,var))
       (sync-workgroup)
       ;; Phase 2 -- halving sweep over the per-warp partials.
       (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
             (,lid (to-int (get-local-linear-id))))
         (dec-times-by-half+ (,s (/ ,nw 2ul))
           ;; Divergence confined to the combine; the barrier below is reached by every thread.
           (when (< ,lid (to-int ,s))
             (set! (~ ,local-scratch-vec ,lid)
                   ,(%175-apply-binop fn
                                      `(~ ,local-scratch-vec ,lid)
                                      `(~ ,local-scratch-vec (+ ,lid (to-int ,s))))))
           (sync-workgroup))
         ;; Slot 0 now holds the workgroup total; every thread reads it.  When there is only one
         ;; warp the sweep runs zero iterations (BUG 065's gate) and slot 0 already holds the
         ;; single warp's partial, separated from these reads by the barrier above.
         (set! ,var (~ ,local-scratch-vec 0)))
       ,@(when return-vec
           (list `(when-thread-in-group-is 0
                    (set! (~ ,return-vec (to-int (get-workgroup-id 0))) ,var))))
       (compiler-no-op))))

(eval-when (:load-toplevel :execute)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (let ((ccs (find-symbol "REDUCE-WORKGROUP" cc)))
      (when (and ccs cl)
        (let ((cls (intern "REDUCE-WORKGROUP" cl)))
          (unless (eq cls ccs)
            (setf (macro-function cls) (macro-function ccs))))))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — the 173 warp builtins are gradient-inert (real gap, not a draft)
;;; ---------------------------------------------------------------------------
;;; src/autodiff.lisp  (the prefix list inside %backward-skip-fn-p-145p1)
;;;
;;; That list already carries every thread-coordinate and shape query -- GET-LOCAL-ID,
;;; GET-LOCAL-LINEAR-SIZE, GET-NUM-GROUPS, SYNC-WORKGROUP and the rest.  Endeavour 173 added
;;; four more of exactly that kind -- WARP-SIZE, WARP-ID, WARP-LANE, WARP-COUNT -- and never
;;; added them here.  A lane index carries no gradient any more than a local id does.
;;;
;;; The symptom is the misleading one this list exists to prevent:
;;;
;;;     Function WARP-SIZE is not differentiable.  Wrap the kernel in 'forward-only' ...
;;;
;;; which points away from the fix -- the kernel IS differentiable; a warp width simply has no
;;; derivative.  Compare the identical wording quoted in %backward-skip-fn-p for
;;; MAKE-ASYNC-BARRIER-RING, and [[ad-error-naming-a-coordinate]].
;;;
;;; WHY 173 DID NOT NOTICE.  Every 173 spec that uses these builtins in a differentiated kernel
;;; carries SKIP-WITH[--differentiate] for an unrelated reason, and the two that do differentiate
;;; (09, 10) use only shuffle-xor / shuffle-up / shuffle-down, whose operands are values rather
;;; than coordinates.  175 spec 09 is the first kernel to put (warp-size) in the path of the
;;; backward walk.

(defvar *orig-175-backward-skip-fn-p* (fdefinition '%backward-skip-fn-p-145p1)
  "Captured once at overlay load.")

(defun %backward-skip-fn-p-145p1 (fn-sym)
  "Overlay wrapper: the 173 warp builtins join the gradient-inert coordinate queries."
  (or (and (symbolp fn-sym)
           (member (symbol-name fn-sym)
                   '("WARP-SIZE" "WARP-ID" "WARP-LANE" "WARP-COUNT")
                   :test #'string=)
           t)
      (funcall *orig-175-backward-skip-fn-p* fn-sym)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — reduce-workgroup becomes an ANALYZED FORM with a semantic VJP.
;;; ---------------------------------------------------------------------------
;;; SUPERSEDES the reduce-workgroup macro drafted above (last definition wins; the draft's
;;; macro-function is removed below).  Option 1, chosen after MEASURING option 3.
;;;
;;; WHY THE MACRO HAD TO GO.  A macro expands inside anf-transform, before the backward walk, so
;;; AD saw only the expansion -- a butterfly, scratch writes, barriers -- and reversed it
;;; mechanically.  That is not merely heavy, it is WRONG: spec 09 measured analytical=1.0
;;; against a hardware finite difference of 64.00012.  1.0 is the derivative of the IDENTITY, so
;;; the backward pass had lost the entire reduction.
;;;
;;; The reason is general enough to be worth stating (BUG 073): the AD walk models SINGLE-THREAD
;;; dataflow.  Thread j writing sv[j] and thread i reading it is a CROSS-THREAD edge, and no
;;; per-thread reversal can see it.  reduce-warp differentiates correctly only because
;;; shuffle-xor carries an explicit VJP that models the cross-lane transpose; shared memory has
;;; no such rule.  Communication between threads needs a STATED derivative.
;;;
;;; THE STATED DERIVATIVE, and it is elementary.  reduce-workgroup is an ALL-reduce -- every
;;; thread ends up holding the total -- so the forward map is N outputs, not one:
;;;
;;;     y_t = SUM over j of x_j      for every t          dy_t/dx_j = 1
;;;     xbar_j = SUM over t of ybar_t                     (the VJP sums over OUTPUTS)
;;;
;;; An all-reduce is a fan-in followed by a fan-out; transposing reverses the order and dualises
;;; each half, giving fan-out then fan-in -- an all-reduce again.  It is SELF-TRANSPOSING, just
;;; as shuffle-xor is.  So the backward pass is the SAME OPERATION applied to the adjoint, and
;;; the VJP below simply emits another reduce-workgroup.
;;;
;;; It transforms the adjoint IN PLACE rather than accumulating, mirroring the forward, which
;;; consumes v and produces v.

(defun %reduce-workgroup-expand (expr)
  "The forward lowering of (reduce-workgroup FN VAR IDENTITY &key ...).  A plain function, not a
   macro: as a macro this expanded inside anf-transform and the backward walk never saw the
   construct.  The analyzer below calls it; the VJP registry sees the unexpanded form."
  (let* ((fn        (second expr))
         (var       (third expr))
         (identity  (fourth expr))
         (keys      (cddddr expr))
         (scratch   (getf keys :local-scratch-vec))
         (return-vec (getf keys :return-vec))
         (s   (gensym "RWG-S"))
         (nw  (gensym "RWG-NW"))
         (lid (gensym "RWG-LID")))
    (unless scratch
      (error 'crisp-compiler-error
             :message "reduce-workgroup: :local-scratch-vec is required in this build.  Auto-generating it needs VAR's element type at analysis time, which Crisp cannot yet supply.  Pass e.g. (make-scratch-vector float :match-num-warps-per-workgroup)."
             :source-location nil))
    `(progn
       ;; Phase 1 -- each warp reduces itself; every lane then holds its warp's partial.
       (reduce-warp ,fn ,var ,identity)
       (when-thread-in-warp-is 0
         (set! (~ ,scratch (to-int (warp-id))) ,var))
       (sync-workgroup)
       ;; Phase 2 -- halving sweep over the per-warp partials.  The barrier is INSIDE the loop
       ;; and OUTSIDE the guard: reductions-excerpt.md has it the other way round, which Crisp
       ;; refuses (a workgroup collective in divergent control flow) and which would also leave
       ;; successive passes unseparated.  The loop is the + variant so every thread runs the
       ;; same iteration count and meets the same barriers.
       (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
             (,lid (to-int (get-local-linear-id))))
         (dec-times-by-half+ (,s (/ ,nw 2ul))
           (when (< ,lid (to-int ,s))
             (set! (~ ,scratch ,lid)
                   ,(%175-apply-binop fn
                                      `(~ ,scratch ,lid)
                                      `(~ ,scratch (+ ,lid (to-int ,s))))))
           (sync-workgroup))
         ;; Slot 0 holds the workgroup total; every thread reads it.  With one warp the sweep
         ;; runs zero iterations (BUG 065's gate) and slot 0 already holds that warp's partial,
         ;; separated from these reads by the barrier above.
         (set! ,var (~ ,scratch 0)))
       ,@(when return-vec
           (list `(when-thread-in-group-is 0
                    (set! (~ ,return-vec (to-int (get-workgroup-id 0))) ,var))))
       (compiler-no-op))))

(defun %analyze-reduce-workgroup (expr env context location)
  "Analyzer for reduce-workgroup -- expands and delegates.  Being an ANALYZED form rather than a
   macro is what keeps the construct visible to the autodiff walk (see the section header)."
  (analyze-expression (%reduce-workgroup-expand expr) env context location))

(defvar *orig-175b-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load -- chains onto the earlier 175 wrapper.")

(defun register-ops-analyzers ()
  "Overlay wrapper: previous registrations, plus reduce-workgroup as an analyzed form."
  (funcall *orig-175b-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "REDUCE-WORKGROUP" pkg) *expression-analyzers*)
              '%analyze-reduce-workgroup)))))

;;; --- the semantic VJP -------------------------------------------------------

(defun %175-vjp-reduce-workgroup (form ctx)
  "VJP for reduce-workgroup: an all-reduce is self-transposing, so the backward pass is another
   all-reduce of the adjoint.  See the section header for the derivation and spec 09 for the
   measured value (64, against 1.0 for the mechanical reversal)."
  (let* ((fn         (second form))
         (var        (third form))
         (keys       (cddddr form))
         (scratch    (getf keys :local-scratch-vec))
         (return-vec (getf keys :return-vec))
         (local-adj  (getf ctx :local-adj)))
    (unless (and (consp fn) (symbolp (car fn))
                 (string-equal (symbol-name (car fn)) "FUNCTION")
                 (string= (symbol-name (second fn)) "+"))
      (error "reduce-workgroup: autodiff is supported only for the + reduction.  The transpose of a SUM reduction is another sum reduction, which is exact and needs nothing recorded from the forward pass.  min/max would route the adjoint to the winning thread, which requires the forward pass to stash an argmin/argmax; an arbitrary binop needs the partial derivatives of that op at every combining node, i.e. the whole combining tree and its intermediates.  Neither is recorded today.  Use the + reduction, or mark the kernel SKIP-WITH[--differentiate] if it is forward-only."))
    (when return-vec
      (error "reduce-workgroup: :return-vec is not differentiable yet.  The per-workgroup partial written to that vector is a SECOND output of this form, so a correct VJP must also collect whatever gradient flows back through it.  The expansion that writes it is hidden inside the analyzer, so the walk cannot see that store and the contribution would be silently dropped.  Refusing rather than returning an incomplete gradient.  Drop the key, or write the element yourself after the reduction."))
    (unless (and var (symbolp var))
      (return-from %175-vjp-reduce-workgroup nil))
    (let ((vbar (funcall local-adj var)))
      (log:debug "175 VJP reduce-workgroup: all-reduce of ~a" vbar)
      ;; In place, mirroring the forward -- the operation consumes v and produces v, so the
      ;; input adjoint REPLACES the output adjoint rather than accumulating onto it.
      `(reduce-workgroup ,fn ,vbar 0.0 :local-scratch-vec ,scratch))))

(eval-when (:load-toplevel :execute)
  ;; Remove the superseded MACRO from both packages so anf-transform stops expanding the form
  ;; and the VJP registry can see it.  fmakunbound, not (setf (macro-function ...) nil).
  (dolist (pkg (list (find-package :crisp.compiler) (find-package :crisp-language)))
    (when pkg
      (let ((sym (find-symbol "REDUCE-WORKGROUP" pkg)))
        (when (and sym (macro-function sym))
          (fmakunbound sym)))))
  (register-vjp "REDUCE-WORKGROUP" (function %175-vjp-reduce-workgroup)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 066's _GRAD inheritance must copy GEOMETRY ONLY.
;;; ---------------------------------------------------------------------------
;;; src/codegen.lisp  (replaces %173-ensure-grad-dispatch-decls)
;;;
;;; BUG 066 let a _GRAD kernel inherit its forward kernel's dispatch declarations so that 156's
;;; SPIR-V subgroup pinning could see a local-size.  It copied the WHOLE plist -- and that plist
;;; carries more than launch geometry.  src/metadata.lisp reads :cluster-size and
;;; :cluster-size-decl out of it, so the derivative began advertising a cluster size it was never
;;; given, which 152-DSMEM-Cluster/05 exists to forbid:
;;;
;;;     the BACKWARD kernel's metacrisp carries :cluster-size.  Scheduling declarations must not
;;;     propagate into a derivative -- cluster-size says where bytes arrive, not what is computed.
;;;
;;; That spec is right, and its principle decides the fix: a gradient kernel is LAUNCHED like its
;;; forward twin, so it inherits the launch GEOMETRY; it is not SCHEDULED like it, so everything
;;; else stays behind.  :cluster-size / :cluster-size-decl / :effective-cluster-size are
;;; data-movement decisions and :mma-lowering is a code-generation strategy -- none of them
;;; describe what is computed, and a derivative that claimed them would be making a promise
;;; nobody made to it.
;;;
;;; WHY IT WAS MISSED.  The check lives in a --metadata validator on the BACKWARD kernel, so it
;;; only runs in the --differentiate phase, which CI runs and local work usually does not.  173's
;;; overlay carried the same over-broad copy; folding it into src/ preserved it.  Found by running
;;; the full --differentiate phase after touching shared autodiff code.

(defparameter *grad-inheritable-dispatch-keys*
  '(:global-size :local-size :num-groups)
  "The dispatch-declaration keys a _GRAD kernel inherits from its forward twin: LAUNCH GEOMETRY
   only.  Deliberately a whitelist rather than a blacklist -- a new scheduling key added to the
   plist later must not start leaking into derivatives merely because nobody remembered to
   exclude it.  See 152-DSMEM-Cluster/05.")

(defun %173-ensure-grad-dispatch-decls (semantic-function)
  "BUG 066: a _GRAD kernel has no entry in *kernel-dispatch-declarations* under its OWN name, so
   %emit-spirv-subgroup-size-execution-mode read a NIL local-size for it and declined to pin --
   leaving every differentiated kernel on Intel running at a driver-chosen subgroup size while
   its forward twin was pinned.

   The gradient kernel is launched with the same GEOMETRY as its forward kernel, so it inherits
   those keys and only those; see *GRAD-INHERITABLE-DISPATCH-KEYS* for why the rest stay behind.

   If another generated-kernel suffix ever joins _GRAD, this needs widening."
  (let* ((kname (semantic-function-name semantic-function))
         (name (and kname (symbol-name kname))))
    (when (and name
               (not (gethash kname *kernel-dispatch-declarations*))
               (> (length name) 5)
               (string= "_GRAD" (subseq name (- (length name) 5))))
      (let* ((base (subseq name 0 (- (length name) 5)))
             (base-sym (find-symbol base (symbol-package kname)))
             (decls (and base-sym (gethash base-sym *kernel-dispatch-declarations*))))
        (when decls
          (let ((geom nil))
            (dolist (k *grad-inheritable-dispatch-keys*)
              (let ((v (getf decls k :%absent)))
                (unless (eq v :%absent)
                  (setf geom (append geom (list k v))))))
            (when geom
              (setf (gethash kname *kernel-dispatch-declarations*) geom)
              (log:info "175: ~a inherits launch geometry ~s from ~a (scheduling keys withheld)"
                        kname (loop for (k nil) on geom by #'cddr collect k) base-sym))))))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 076: D7 is a KERNEL property, checked by reachability.
;;; ---------------------------------------------------------------------------
;;; src/codegen.lisp (the check) — replaces the per-shuffle check in %shuffle-check-pinned.
;;;
;;; THE BUG.  173's D7 asked "is the function I am generating right now pinned?" at every shuffle
;;; emission.  For a SUB-FUNCTION the answer is always no -- %173-subgroup-pinned-p looks up
;;; *kernel-dispatch-declarations* under the helper's own name, which has no dispatch
;;; declarations -- so any warp collective inside any helper was refused, however pinnable the
;;; calling kernel was.  Subgroup size is a KERNEL execution mode; a helper does not have one.
;;;
;;; That blocked the whole point of Crisp's function-typed parameters: a def-function taking
;;; #'(T T => T) and forwarding it to reduce-warp could not be compiled at all.  Spec 11.
;;;
;;; THE FIX, and it is a scope correction rather than a relaxation.  "Does a shuffle run at a
;;; width nobody guaranteed?" is a question about a KERNEL and everything it reaches, so it is
;;; asked once per kernel, over the CALL GRAPH:
;;;
;;;     a kernel that transitively reaches a warp collective must have a pinned subgroup size.
;;;
;;; This is STRICTLY MORE COMPLETE than what it replaces.  The old check could only see shuffles
;;; in the function it happened to be generating, so a kernel whose only shuffle lived inside a
;;; helper escaped D7 entirely once helpers were allowed -- the very hole D7 exists to close.
;;; Reachability closes it.
;;;
;;; WHERE IT RUNS.  %emit-spirv-subgroup-size-execution-mode already runs once per kernel at
;;; function setup and already computes pinnability, so the decision lands beside the fact it
;;; depends on.  *call-graph* is bound in compile-module and therefore still live at codegen, and
;;; *fn-normalized-info* carries each function's body -- both are endeavour 120's tables, used
;;; here for the same interprocedural purpose (see the infer-param-uniformity call that sits
;;; immediately after the call graph is built).
;;;
;;; The scan is SYNTACTIC on purpose: it reads the stored source body rather than asking the
;;; analyzer, so it does not depend on analysis order and cannot be defeated by a form the
;;; analyzer rewrites later.  It over-approximates -- a shuffle inside a branch that never runs
;;; still counts -- which is the safe direction for a guard whose failure mode is a wrong answer.

(defparameter *warp-collective-operator-names*
  '("SHUFFLE" "SHUFFLE-UP" "SHUFFLE-DOWN" "SHUFFLE-XOR"
    "REDUCE-WARP" "REDUCE-WORKGROUP")
  "Operators whose correctness depends on the warp width the kernel actually runs at.
   reduce-warp and reduce-workgroup are listed as well as the raw shuffles: they are the forms a
   user writes, and listing them means the scan works whether or not they have been expanded.")

(defun %175-uses-warp-collective-p (x)
  "Syntactic: does X mention a warp collective anywhere?  Walks car and cdr separately so a
   dotted form cannot trip it."
  (labels ((walk (f)
             (cond
               ((and (consp f) (symbolp (car f))
                     (member (symbol-name (car f)) *warp-collective-operator-names*
                             :test #'string=))
                t)
               ((consp f) (or (walk (car f)) (walk (cdr f))))
               (t nil))))
    (walk x)))

(defun %175-fn-uses-warp-collective-p (name)
  "T if the function NAME's own body mentions a warp collective."
  (let ((info (and (hash-table-p *fn-normalized-info*) (gethash name *fn-normalized-info*))))
    (and info (%175-uses-warp-collective-p (getf info :body)))))

(defun %175-reaches-warp-collective-p (kname)
  "T if KNAME, or anything it transitively calls, mentions a warp collective.
   Cycle-safe: a recursive call graph would otherwise not terminate."
  (let ((seen (make-hash-table :test 'eq)))
    (labels ((visit (n)
               (cond
                 ((gethash n seen) nil)
                 (t (setf (gethash n seen) t)
                    (or (%175-fn-uses-warp-collective-p n)
                        (when (hash-table-p *call-graph*)
                          (loop for callee in (gethash n *call-graph*)
                                thereis (and (symbolp callee) (visit callee)))))))))
      (and (visit kname) t))))

(defun %175-check-kernel-warp-collective-pinning (semantic-function pinned-p)
  "BUG 076 / 173 D7, at kernel scope.  Refuses a SPIR-V kernel that reaches a warp collective
   without a pinned subgroup size.

   Keeps the original wording (\"cannot be pinned\"), which 173-shuffles/errors/06 matches on."
  (when (eq *target-backend* :spirv)
    (let* ((kname (semantic-function-name semantic-function))
           (info  (and kname (hash-table-p *fn-normalized-info*)
                       (gethash kname *fn-normalized-info*)))
           ;; Treat an unrecorded function as a kernel: this emitter is only reached for kernels,
           ;; and defaulting the other way would silently skip the guard.
           (entry-p (if info (getf info :entry-point-p) t)))
      (when (and entry-p (not pinned-p) kname
                 (%175-reaches-warp-collective-p kname))
        (error 'crisp-compiler-error
               :message (format nil "kernel ~a uses a warp collective (directly or through a function it calls), but its SPIR-V subgroup size cannot be pinned, so the warp width it would run at is whatever the driver chooses (8, 16 or 32 on Intel) rather than the width this kernel was compiled against. Pinning needs an active hardware profile naming a :simd-width AND a compile-time (local-size :set-to N) whose total is a whole multiple of it. Crisp refuses rather than assuming 32: a reduction written for one width and run at another returns a wrong answer instead of failing."
                                kname)
               :source-location nil)))))

(defun %shuffle-check-pinned (location)
  "NO LONGER CHECKS ANYTHING -- kept so the emit sites need no edit.  See
   %175-CHECK-KERNEL-WARP-COLLECTIVE-PINNING, which asks the same question once per KERNEL over
   the call graph instead of once per emitted shuffle inside whatever function happens to be
   under construction.  The per-shuffle form could not see past its own function and therefore
   refused every helper (BUG 076) while missing every kernel whose shuffle was in a helper.
   On fold-back, delete this and its call in %shuffle-spv."
  (declare (ignore location))
  nil)

(defvar *orig-175-emit-spirv-subgroup-size* (fdefinition '%emit-spirv-subgroup-size-execution-mode)
  "Captured once at overlay load.")

(defun %emit-spirv-subgroup-size-execution-mode (func module semantic-function)
  "Overlay wrapper: the original emission, then the kernel-scope D7 check (BUG 076), which needs
   the pinning verdict the original computes."
  (funcall *orig-175-emit-spirv-subgroup-size* func module semantic-function)
  (%175-check-kernel-warp-collective-pinning semantic-function *173-subgroup-pinned*))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 077: give the LINEAR atomics a VJP, refuse the rest.
;;; ---------------------------------------------------------------------------
;;; src/autodiff.lisp (beside the other register-vjp calls)
;;;
;;; atomic-add! into an &out parameter differentiated to ZERO, silently -- spec 16 measured
;;; analytical=0.0 where the truth is 1.0.  The machinery knew atomic-add! only as a WRITTEN
;;; PLACE (it appears in the primal-replay place collector beside SET!) and had no backward rule,
;;; so a grid-level accumulation lost its gradient entirely.  Same class as BUG 073 one level up:
;;; cross-WORKGROUP dataflow through a global atomic, invisible to a per-thread walk.
;;;
;;; THE RULE IS ALREADY WRITTEN DOWN ELSEWHERE, which is what makes this cheap.  For
;;; (set! (~ t i) v), %gfw-process-set! emits
;;;
;;;     (set! v_adj (+ v_adj (~ t_GRAD i)))
;;;
;;; and `out[i] = v` and `out[i] += v` have the SAME derivative with respect to v -- both are 1.
;;; So the linear atomics reuse that rule verbatim.
;;;
;;; ONE DIFFERENCE THAT MATTERS, and it is easy to miss by copying: in the SCRATCH branch,
;;; %gfw-process-set! also ZEROES the destination adjoint, because a set! destroys the old value
;;; and its adjoint must not flow on.  An atomic-add! does NOT destroy the old value -- it
;;; accumulates onto it -- so zeroing there would drop a real contribution.  The zeroing is
;;; deliberately absent below.
;;;
;;; WHICH ATOMICS GET A RULE, decided by whether the operation is LINEAR in its value argument:
;;;
;;;   add!  -> vbar += adj(place)          linear, coefficient +1
;;;   sub!  -> vbar -= adj(place)          linear, coefficient -1
;;;   inc! / dec!  -> :inert               no value argument; the increment is a constant, so
;;;                                        there is nothing to propagate and zero IS correct
;;;   min! / max!  -> REFUSED              the adjoint routes only to the thread that supplied
;;;                                        the winning value, which the forward pass does not
;;;                                        record (an argmin/argmax); same gap as
;;;                                        reduce-workgroup's non-+ case
;;;   exchange! / cas!  -> REFUSED         conditional or old-value-returning; not linear, and
;;;                                        the returned old value is a second output
;;;
;;; Refusing beats silence.  A wrong gradient with no diagnostic is the worst outcome available,
;;; and it is what shipped until now.

(defun %175-atomic-place-parts (place)
  "TARGET and INDICES of an atomic's place, or NIL if it is not a (~ t i...) form.
   Matched by symbol-name: a kernel's reader may intern ~ into its own package."
  (when (and (consp place) (symbolp (car place))
             (string= (symbol-name (car place)) "~"))
    (values (second place) (cddr place))))

(defun %175-vjp-atomic-linear (form ctx sign op-name)
  "Backward rule for an atomic that is LINEAR in its value argument.
   SIGN is +1 for add!, -1 for sub!."
  (let ((place (second form))
        (val   (third form)))
    (multiple-value-bind (target indices) (%175-atomic-place-parts place)
      (cond
        ;; Not a place we understand, or a non-symbol value: decline rather than guess, and let
        ;; the walk's own clauses report it.
        ((or (null target) (not (symbolp val))) nil)
        (t
         (let* ((inputs    (getf ctx :inputs))
                (outputs   (getf ctx :outputs))
                (local-adj (getf ctx :local-adj))
                (pkg       (getf ctx :kernel-pkg)))
           (when (member target inputs)
             (error "Cannot differentiate: kernel mutates input parameter ~A via (~A (~~ ~A) ...). Only output parameters may be written."
                    target op-name target))
           (let* ((tgt-adj (if (member target outputs)
                               (intern (format nil "~A_GRAD" (symbol-name target))
                                       (symbol-package target))
                               (%tlc-bwd-adj-name target inputs outputs local-adj pkg)))
                  (vadj (funcall local-adj val))
                  (contrib `(~ ,tgt-adj ,@indices)))
             (log:debug "175 VJP ~a: ~a ~a= ~a" op-name vadj (if (plusp sign) "+" "-") contrib)
             ;; NO zeroing of the destination adjoint -- see the section header.
             `(set! ,vadj ,(if (plusp sign)
                               `(+ ,vadj ,contrib)
                               `(- ,vadj ,contrib))))))))))

(defun %175-vjp-atomic-refuse (form ctx op-name why)
  "Backward rule for an atomic Crisp cannot differentiate: refuse, with the reason."
  (declare (ignore form ctx))
  (error "~A is not differentiable.  ~A~%~
          Crisp refuses rather than returning a gradient of zero, which is what it did before~%~
          BUG 077: a kernel accumulating with an atomic compiled, ran, and reported an~%~
          analytical derivative of 0.0 where the true value was 1.0, with no diagnostic.~%~
          atomic-add! and atomic-sub! DO differentiate (they are linear in their value).~%~
          If this kernel is genuinely forward-only, mark it SKIP-WITH[--differentiate]."
         op-name why))

(eval-when (:load-toplevel :execute)
  (register-vjp "ATOMIC-ADD!"
                (lambda (f c) (%175-vjp-atomic-linear f c 1 "atomic-add!")))
  (register-vjp "ATOMIC-SUB!"
                (lambda (f c) (%175-vjp-atomic-linear f c -1 "atomic-sub!")))
  ;; No value argument: the increment is a constant, so zero really is the gradient.
  (register-vjp "ATOMIC-INC!" (lambda (f c) (declare (ignore f c)) :inert))
  (register-vjp "ATOMIC-DEC!" (lambda (f c) (declare (ignore f c)) :inert))
  (register-vjp "ATOMIC-MIN!"
                (lambda (f c) (%175-vjp-atomic-refuse
                               f c "atomic-min!"
                               "Its adjoint routes only to the thread that supplied the winning value, which requires the forward pass to have recorded an argmin.  Nothing records it.")))
  (register-vjp "ATOMIC-MAX!"
                (lambda (f c) (%175-vjp-atomic-refuse
                               f c "atomic-max!"
                               "Its adjoint routes only to the thread that supplied the winning value, which requires the forward pass to have recorded an argmax.  Nothing records it.")))
  (register-vjp "ATOMIC-XCHG!"
                (lambda (f c) (%175-vjp-atomic-refuse
                               f c "atomic-xchg!"
                               "It both overwrites the place and RETURNS the old value, so it has two outputs; a correct rule must account for whatever the returned value feeds.")))
  (register-vjp "ATOMIC-SET!"
                (lambda (f c) (%175-vjp-atomic-refuse
                               f c "atomic-set!"
                               "It both overwrites the place and RETURNS the old value, so it has two outputs; a correct rule must account for whatever the returned value feeds.")))
  (register-vjp "ATOMIC-CAS!"
                (lambda (f c) (%175-vjp-atomic-refuse
                               f c "atomic-cas!"
                               "The write is CONDITIONAL on a comparison, so the derivative depends on whether the swap happened -- a fact the forward pass does not record."))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — grid-reduce-atomic! : analyzed form + monolithic VJP.
;;; ---------------------------------------------------------------------------
;;; src/analysis/ops.lisp (form + analyzer), src/autodiff.lisp (the VJP registration).
;;;
;;;   (grid-reduce-atomic! fn var identity return-vec :local-scratch-vec sv)
;;;
;;; Phase 1 reduces each workgroup (reduce-workgroup); phase 2 has one leader per workgroup
;;; accumulate that partial into return-vec[0] with a native hardware atomic.
;;;
;;; ONLY THE OPERATORS WITH A HARDWARE ATOMIC ARE LEGAL, which is a physical restriction rather
;;; than a missing feature: phase 2 is one instruction, and the hardware provides add/min/max.
;;; The doc says the same.  In practice only #'+ is reachable today because Crisp has no scalar
;;; min or max binop -- (max 3.0 7.0) fails with "Unsupported form 'MAX'" -- so two of the three
;;; legal operators do not yet exist.  The mapping below is written for all three anyway, so
;;; adding the binops is the only work required to reach them.
;;;
;;; AN ANALYZED FORM, NOT A MACRO, for the reason established by reduce-workgroup: a macro expands
;;; inside anf-transform before the backward walk, so AD would reverse the EXPANSION rather than
;;; apply a rule -- and reversing cross-thread communication silently loses it (BUG 073/077).
;;;
;;; THE VJP IS THE SIMPLEST IN THE ENDEAVOUR.  out[0] is the sum over the WHOLE GRID of x_t, so
;;;
;;;     d out / d x_t = 1   for every thread t        =>     xbar_t = outbar[0]
;;;
;;; Every thread reads one global cell.  No atomics (the transpose of a scatter-add is a GATHER,
;;; which is read-only), no barriers, no scratch.
;;;
;;; WHY A MONOLITHIC RULE RATHER THAN COMPOSITION, now that atomic-add! also has a VJP (BUG 077):
;;; composition would be correct -- the atomic's rule gives wg_total_bar = outbar in the leader
;;; and 0 elsewhere, and reduce-workgroup's all-reduce VJP then spreads it to every thread -- but
;;; that all-reduce costs a scratch sweep and a barrier per halving step in the BACKWARD kernel.
;;; The monolithic rule reaches the same answer with a single load, because it accounts for the
;;; whole fan-in at once.  Correctness is equal; the saving is the barriers, not atomic contention.

(defparameter *grid-atomic-operator-map*
  '(("+" . "ATOMIC-ADD!") ("MIN" . "ATOMIC-MIN!") ("MAX" . "ATOMIC-MAX!"))
  "Operators grid-reduce-atomic! accepts, and the native atomic each lowers to.  The hardware
   provides exactly these three; anything else has no single-instruction form.")

(defun %grid-atomic-op-name (fn)
  "The atomic operator name for a literal #'op, or NIL if OP has no hardware atomic."
  (when (and (consp fn) (symbolp (car fn))
             (string-equal (symbol-name (car fn)) "FUNCTION")
             (symbolp (second fn)))
    (cdr (assoc (symbol-name (second fn)) *grid-atomic-operator-map* :test #'string-equal))))

(defun %grid-reduce-atomic-parts (expr)
  "Destructures (grid-reduce-atomic! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec scratch)."
  (let ((keys (cdr (cdddr (cdr expr)))))   ; everything after the four positional arguments
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec))))

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
      `(progn
         ;; Phase 1 -- every thread of the workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,scratch)
         ;; Phase 2 -- ONE leader per workgroup contributes that total to the grid cell.  Electing
         ;; a single thread is what makes the atomic correct: without it all 64 would add the same
         ;; workgroup total and the result would be scaled by the workgroup size.
         (when-thread-in-group-is 0
           (,(intern atomic (find-package :crisp.compiler)) (~ ,return-vec 0) ,var))
         (compiler-no-op)))))

(defun %analyze-grid-reduce-atomic (expr env context location)
  "Analyzer for grid-reduce-atomic! -- expands and delegates."
  (analyze-expression (%grid-reduce-atomic-expand expr) env context location))

(defvar *orig-175c-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load -- chains onto the earlier 175 wrappers.")

(defun register-ops-analyzers ()
  "Overlay wrapper: previous registrations, plus grid-reduce-atomic! as an analyzed form."
  (funcall *orig-175c-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "GRID-REDUCE-ATOMIC!" pkg) *expression-analyzers*)
              '%analyze-grid-reduce-atomic)))))

(defun %175-vjp-grid-reduce-atomic (form ctx)
  "VJP: out[0] is the sum over the whole grid, so every thread's adjoint is the output cell's
   adjoint.  One global load per thread -- no atomics, no barriers, no scratch."
  (multiple-value-bind (fn var identity return-vec scratch) (%grid-reduce-atomic-parts form)
    (declare (ignore identity scratch))
    (let ((local-adj (getf ctx :local-adj)))
      (unless (string-equal (or (%grid-atomic-op-name fn) "") "ATOMIC-ADD!")
        (error "grid-reduce-atomic!: autodiff is supported only for the + reduction.  A SUM over the grid gives d out / d x = 1 for every thread, so the adjoint is a plain broadcast of the output cell.  min/max would route the adjoint only to the thread that supplied the winning value, which needs an argmin/argmax the forward pass does not record -- the same gap atomic-min!/atomic-max! have on their own (BUG 077).  Use the + reduction, or mark the kernel SKIP-WITH[--differentiate] if it is forward-only."))
      (unless (and var (symbolp var) return-vec (symbolp return-vec))
        (return-from %175-vjp-grid-reduce-atomic nil))
      (let* ((inputs  (getf ctx :inputs))
             (outputs (getf ctx :outputs))
             (pkg     (getf ctx :kernel-pkg))
             (vadj (funcall local-adj var))
             ;; The gradient HANDLE of the output tensor, not a scalar adjoint.  local-adj alone
             ;; yields a scalar here and the emitted (~ radj 0) then fails to typecheck with
             ;; "No matching function overload found for '~' with argument types (FLOAT INT)".
             ;; Same resolution the atomic VJP uses.
             (radj (if (member return-vec outputs)
                       (intern (format nil "~A_GRAD" (symbol-name return-vec))
                               (symbol-package return-vec))
                       (%tlc-bwd-adj-name return-vec inputs outputs local-adj pkg))))
        (log:debug "175 VJP grid-reduce-atomic!: ~a := (~~ ~a 0)" vadj radj)
        ;; OVERWRITE, mirroring the forward: the construct consumes VAR (the doc says its value is
        ;; indeterminate afterwards), so the input adjoint REPLACES the output adjoint.
        `(set! ,vadj (~ ,radj 0))))))

(eval-when (:load-toplevel :execute)
  (register-vjp "GRID-REDUCE-ATOMIC!" (function %175-vjp-grid-reduce-atomic)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — scalar min / max.
;;; ---------------------------------------------------------------------------
;;; src/analysis/ops.lisp
;;;
;;; Crisp had no scalar min or max: (max 3.0 7.0) failed with "Unsupported form 'MAX'".  That
;;; blocked two of grid-reduce-atomic!'s three legal operators -- the design doc specifies it as
;;; accepting exactly #'+, #'min and #'max, and only + was reachable.  It also forced every
;;; max-flavoured spec in this endeavour to define its own binop.
;;;
;;; ANALYZED FORMS THAT EXPAND, rather than new semantic nodes with their own codegen.  The
;;; alternative is the def-binary-math-analyzer / def-binary-math-codegen pair that pow and atan2
;;; use, which would mean two new structs (a patch, since structs cannot be late-bound), two
;;; etypecase clauses each, a codegen rule and an AD rule.  Expanding to a comparison costs one
;;; site and gets the rest for free: the `if` and the `>` already have codegen AND backward rules,
;;; so min/max differentiate the moment they exist.
;;;
;;; THE `let` IS NOT OPTIONAL.  (if (> a b) a b) with the raw argument forms would evaluate each
;;; argument TWICE -- once in the test, once in the branch.  Binding first makes each exactly one
;;; evaluation, which matters for cost and would matter for correctness the moment an argument
;;; were anything but pure.
;;;
;;; CODEGEN IS NOT THE CONCERN IT LOOKS LIKE.  A compare-and-branch over two bound temporaries is
;;; what LLVM turns into fcmp + select, which is one instruction on both backends.  What this does
;;; NOT reproduce is llvm.minnum/maxnum's NaN rule: those return the non-NaN operand, while a
;;; comparison returns the SECOND argument whenever either side is NaN ((> a b) is false for any
;;; NaN).  No current caller feeds NaN to a reduction, and the identity values are finite -- but
;;; that is the reason to move to the intrinsics later, not the codegen shape.
;;;
;;; DELIBERATELY BINARY.  Common Lisp's max/min are variadic; Crisp's are not, because they exist
;;; to be passed as #'(T T => T) binops to the reduction family.  The arity error says so.
;;;
;;; NOTE ON THE SYMBOLS: interning "MAX" into :crisp.compiler finds the INHERITED cl:max (the
;;; package uses :cl and does not shadow it).  Registering an analyzer under that symbol is safe
;;; -- *expression-analyzers* is consulted only when analysing Crisp source, so the compiler's own
;;; internal (max ...) calls are untouched.  This is exactly why an analyzer needs no package
;;; change where a macro would (see the reduce-warp notes).

(defun %175-minmax-expand (expr which location)
  "Expands (min a b) / (max a b) into a single-evaluation comparison.
   WHICH is :min or :max."
  (unless (= (length (rest expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "~(~a~) takes exactly two arguments, got ~a. Crisp's ~(~a~) is BINARY, unlike Common Lisp's variadic one: it exists to be passed as a #(T T => T) binop to the reduction family, which requires a fixed arity. Nest the calls to combine more than two values."
                            which (length (rest expr)) which)
           :source-location location))
  (let ((a (gensym "MM-A"))
        (b (gensym "MM-B")))
    `(let ((,a ,(second expr))
           (,b ,(third expr)))
       ;; Bound first so each argument is evaluated exactly once -- see the section header.
       (if (,(if (eq which :max) '> '<) ,a ,b) ,a ,b))))

(defun %analyze-min-expression (expr env context location)
  "Analyzer for (min a b) -- expands to a comparison and delegates."
  (analyze-expression (%175-minmax-expand expr :min location) env context location))

(defun %analyze-max-expression (expr env context location)
  "Analyzer for (max a b) -- expands to a comparison and delegates."
  (analyze-expression (%175-minmax-expand expr :max location) env context location))

(defvar *orig-175d-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load -- chains onto the earlier 175 wrappers.")

(defun register-ops-analyzers ()
  "Overlay wrapper: previous registrations, plus scalar min / max."
  (funcall *orig-175d-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "MIN" pkg) *expression-analyzers*) '%analyze-min-expression)
        (setf (gethash (intern "MAX" pkg) *expression-analyzers*) '%analyze-max-expression)))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — a FLOAT atomic min/max needs SPV_EXT_shader_atomic_float_min_max.
;;; ---------------------------------------------------------------------------
;;; src/compiler.lisp  (one clause in the ext-flags list inside compile-to-spirv)
;;;
;;; compile-to-spirv already enables SPV_EXT_shader_atomic_float_add unconditionally and
;;; SPV_EXT_shader_atomic_float16_add when the module needs it.  Float atomic MIN/MAX is a THIRD,
;;; separate extension, and without it llvm-spirv refuses the module outright:
;;;
;;;     Tool invocation failed: ... llvm-spirv.exe --spirv-ext=+SPV_EXT_shader_atomic_float_add
;;;     ... exited with error code 18
;;;
;;; a message that names the extension which IS enabled and says nothing about the one missing.
;;; Every grid-reduce-atomic! with #'min or #'max emits such an instruction, so that half of the
;;; construct was unreachable.
;;;
;;; The whole function is reproduced because the flag list is built inline inside its let*; only
;;; the clause above is new.  EXTRACTED from src rather than retyped, so the fold-back diff shows
;;; exactly that clause and nothing else.

(defun %175-ll-uses-float-atomic-minmax-p (ll-path)
  "T when the emitted .ll text at LL-PATH contains a floating-point `atomicrmw fmin`/`fmax`,
   which is what requires SPV_EXT_shader_atomic_float_min_max.

   Deliberately narrow, in the same shape as %ll-uses-fp16-atomic-fadd-p: both `atomicrmw` and
   the fp opcode must appear on the SAME line, which is how LLVM prints the instruction.  An
   INTEGER atomic min/max (atomicrmw min / umax / ...) needs no extension and must not raise the
   flag, which is why only the f-prefixed opcodes are tested."
  (when (and ll-path (probe-file ll-path))
    (with-open-file (s ll-path :direction :input :if-does-not-exist nil)
      (when s
        (loop for line = (read-line s nil nil)
              while line
              thereis (and (search "atomicrmw" line)
                           (or (search " fmin " line) (search " fmax " line))))))))

(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as -> llvm-spirv."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (bc-file     (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))
    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")
    (when (or (%module-uses-native-builtin-p module)
              (%module-uses-async-copy-builtin-p module))
      (%emit-opencl-version-metadata module))
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))
      ;; ARM A: -O3 has just discarded the decorations codegen attached, so put them back on
      ;; the FINAL address arithmetic.  Inert unless CRISP_CACHE_CONTROL is set.
      (%inject-cache-control-decorations llvm-as-input)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags (append '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                              (when (%ll-uses-fp16-atomic-fadd-p
                                     (if (probe-file ll-opt-file) ll-opt-file ll-file))
                                '("--spirv-ext=+SPV_EXT_shader_atomic_float16_add"))
                              ;; Endeavour 175: a FLOAT atomic min/max needs its own extension.
                              ;; Without it llvm-spirv exits 18 on any kernel using atomic-min! /
                              ;; atomic-max! on floats -- i.e. every grid-reduce-atomic! with
                              ;; #'min or #'max.
                              (when (%175-ll-uses-float-atomic-minmax-p
                                     (if (probe-file ll-opt-file) ll-opt-file ll-file))
                                '("--spirv-ext=+SPV_EXT_shader_atomic_float_min_max"))
                              (when (%module-uses-coop-matrix-p module)
                                '("--spirv-ext=+SPV_KHR_cooperative_matrix"))
                              (when (%module-uses-2d-block-io-p module)
                                '("--spirv-ext=+SPV_INTEL_2d_block_io"))
                              (when (%module-uses-subgroup-mma-p module)
                                '("--spirv-ext=+SPV_INTEL_subgroup_matrix_multiply_accumulate"))
                              (when (%module-uses-split-barrier-p module)
                                '("--spirv-ext=+SPV_INTEL_split_barrier"))
                              (when (%module-uses-bfloat-p module)
                                '("--spirv-ext=+SPV_KHR_bfloat16"))
                              (when (and (%cache-control-spec)
                                         (%module-uses-coop-matrix-p module))
                                '("--spirv-ext=+SPV_INTEL_cache_controls"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 081: reduce-warp becomes an ANALYZED FORM with a VJP.
;;; ---------------------------------------------------------------------------
;;; SUPERSEDES the reduce-warp macro defined earlier in this overlay (last definition wins; the
;;; macro-function is removed below).  src/analysis/ops.lisp + src/autodiff.lisp on fold-back.
;;;
;;; WHY.  As a macro, reduce-warp expanded before the backward walk and AD reversed the
;;; EXPANSION -- an in-place mutation inside a loop:
;;;
;;;     (dec-times-by-half+ (s warp/2) (set! v (+ (shuffle-xor v s) v)))
;;;
;;; The assumption was that shuffle-xor's own VJP (173) would carry it.  It does not: spec 24
;;; measured analytical=1.0 against a hardware finite difference of 16.0 -- the derivative of the
;;; IDENTITY, with the fan-out lost entirely.  Third instance of the same lesson (BUG 073, 077,
;;; 081): a construct whose cross-thread behaviour lives in its expansion rather than in a stated
;;; rule will be reversed into silence.
;;;
;;; THE STATED RULE.  A warp reduction is an ALL-reduce -- every lane ends up holding the total --
;;; so it is a fan-in followed by a fan-out, and transposing reverses the order and dualises each
;;; half: fan-out then fan-in, which is an all-reduce again.  SELF-TRANSPOSING, exactly as
;;; shuffle-xor and reduce-workgroup are.  The backward pass is another reduce-warp on the
;;; adjoint, in place.
;;;
;;; ACTIVE-THREADS IS DELIBERATELY DROPPED IN THE BACKWARD.  A partial reduce-warp seeds the
;;; inactive lanes with the identity, and their adjoints are genuinely zero; reducing the adjoint
;;; across the FULL warp is still correct, because the inactive lanes contribute nothing to the
;;; sum.  Spec 04's arithmetic is the check if this is ever revisited.

(defun %reduce-warp-expand (expr)
  "Forward lowering of (reduce-warp FN VAR IDENTITY &optional ACTIVE-THREADS).
   A plain function rather than a macro: keeping the construct unexpanded is what lets the VJP
   registry see it (BUG 081)."
  (let* ((fn (second expr))
         (var (third expr))
         (identity (fourth expr))
         (active-threads (fifth expr))
         (s (gensym "RW-S")))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (list `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       ;; Butterfly stride warp/2, resolved at ANALYSIS time to a literal: (warp-size) folds to a
       ;; UINT so `/` would reject the INT 2, and dec-times-by-half+ wants a provably uniform
       ;; limit, which a literal is by construction.
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         (set! ,var ,(%175-apply-binop fn `(shuffle-xor ,var ,s) var)))
       (compiler-no-op))))

(defun %analyze-reduce-warp (expr env context location)
  "Analyzer for reduce-warp -- expands and delegates."
  (analyze-expression (%reduce-warp-expand expr) env context location))

(defvar *orig-175e-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load -- chains onto the earlier 175 wrappers.")

(defun register-ops-analyzers ()
  "Overlay wrapper: previous registrations, plus reduce-warp as an analyzed form."
  (funcall *orig-175e-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "REDUCE-WARP" pkg) *expression-analyzers*)
              '%analyze-reduce-warp)))))

(defun %175-vjp-reduce-warp (form ctx)
  "VJP for reduce-warp: a warp all-reduce is self-transposing, so the backward pass is another
   reduce-warp of the adjoint.  See the section header."
  (let* ((fn  (second form))
         (var (third form))
         (local-adj (getf ctx :local-adj)))
    (unless (and (consp fn) (symbolp (car fn))
                 (string-equal (symbol-name (car fn)) "FUNCTION")
                 (string= (symbol-name (second fn)) "+"))
      (error "reduce-warp: autodiff is supported only for the + reduction.  The transpose of a SUM all-reduce is another sum all-reduce, which is exact and needs nothing recorded from the forward pass.  min/max would route the adjoint to the lane that supplied the winning value, which requires the forward pass to stash an argmin/argmax; an arbitrary binop needs the partial derivatives of that op at every butterfly step.  Neither is recorded.  Use the + reduction, or mark the kernel with a differentiate-skip if it is forward-only."))
    (unless (and var (symbolp var))
      (return-from %175-vjp-reduce-warp nil))
    (let ((vadj (funcall local-adj var)))
      (log:debug "175 VJP reduce-warp: all-reduce of ~a" vadj)
      ;; In place, mirroring the forward, and WITHOUT active-threads: the inactive lanes' adjoints
      ;; are zero and contribute nothing to the sum.
      `(reduce-warp ,fn ,vadj 0.0))))

(eval-when (:load-toplevel :execute)
  ;; Drop the superseded MACRO from both packages so anf-transform stops expanding the form and
  ;; the VJP registry can see it.  fmakunbound, not (setf (macro-function ...) nil).
  (dolist (pkg (list (find-package :crisp.compiler) (find-package :crisp-language)))
    (when pkg
      (let ((sym (find-symbol "REDUCE-WARP" pkg)))
        (when (and sym (macro-function sym))
          (fmakunbound sym)))))
  (register-vjp "REDUCE-WARP" (function %175-vjp-reduce-warp)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — grid-reduce-last-man! : analyzed form + monolithic VJP.
;;; ---------------------------------------------------------------------------
;;; src/analysis/ops.lisp (form + analyzer), src/autodiff.lisp (the VJP registration).
;;;
;;;   (grid-reduce-last-man! fn var identity return-vec
;;;                          :local-scratch-vec sv :global-scratch-vec gv :atomic-counter ctr)
;;;
;;; Every workgroup reduces itself, stores its partial into a GLOBAL scratch vector and bumps a
;;; global counter; the workgroup whose ticket comes back as num_groups-1 knows it arrived last
;;; and sweeps the partials into the answer.  One launch, no contention on the result cell, and
;;; unlike grid-reduce-atomic! it accepts ANY commutative operator -- the final sweep is an
;;; ordinary reduce-workgroup rather than a single hardware instruction.
;;;
;;; IT STORES THE ANSWER; grid-reduce-atomic! ACCUMULATES onto whatever the buffer held.  That is
;;; a visible behavioural difference, not an implementation detail, and spec 25 pins it.
;;;
;;; TWO DEPARTURES FROM THE DESIGN DOC'S REFERENCE IMPLEMENTATION.
;;;
;;; 1. THE LAST-MAN FLAG GETS ITS OWN CELL.  The doc parks it in localScratchVec[0] and then runs
;;;    the final reduce-workgroup over that same buffer -- whose phase-1 leader store writes slot
;;;    0.  Nothing separates the flag READS from that write, so a thread still reading the flag
;;;    can see it clobbered by a faster thread that has already entered the sweep.  A race, and an
;;;    intermittent one.  A dedicated cell costs one word of SLM and removes the interaction
;;;    entirely.  It can be auto-allocated because its type is fixed (uint) and does not depend on
;;;    VAR's -- which is exactly why the local and global scratch vectors still cannot be.
;;;
;;; 2. (get-local-id) BECOMES (get-local-linear-id).  BUG 079: a comparison against
;;;    (get-local-id 0) is unreliable on SPIR-V, and the doc's sweep indexes the partials by it.
;;;
;;; THE SWEEP IS GATED, THE BARRIERS ARE NOT NEGOTIABLE.  reduce-workgroup contains
;;; sync-workgroup, and a workgroup collective inside a thread-divergent conditional deadlocks --
;;; which is why the gate must be WORKGROUP-UNIFORM.  Every thread reads the same flag cell after
;;; a barrier, so it is uniform in fact; when+ is the form that says so to the analyzer.

(defun %grid-reduce-last-man-parts (expr)
  "Destructures (grid-reduce-last-man! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec local global counter)."
  (let ((keys (cdr (cdddr (cdr expr)))))
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec)
            (getf keys :global-scratch-vec)
            (getf keys :atomic-counter))))

(defun %grid-reduce-last-man-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081 -- three constructs have now been bitten by
   having their cross-thread behaviour live in an expansion rather than in a stated rule)."
  (multiple-value-bind (fn var identity return-vec sv gv ctr)
      (%grid-reduce-last-man-parts expr)
    (dolist (pair (list (list return-vec "a return-vec" "the single global element the grid reduces into")
                        (list sv ":local-scratch-vec" "one element per warp, for the per-workgroup reduction")
                        (list gv ":global-scratch-vec" "one element per WORKGROUP, holding the partials")
                        (list ctr ":atomic-counter"   "a zero-initialised global uint cell, used to elect the last workgroup")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-last-man!: ~a is required -- ~a.  These cannot be auto-generated because their element type follows VAR's, which is not known at analysis time."
                                (second pair) (third pair))
               :source-location nil)))
    (let ((is-last (gensym "LM-ISLAST"))
          (lid  (gensym "LM-LID"))
          (ng   (gensym "LM-NG"))
          (val  (gensym "LM-VAL")))
      `(progn
         ;; The doc's constraint: the final sweep is ONE reduce-workgroup, so every partial must
         ;; fit in one workgroup's worth of threads.
         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                       "grid-reduce-last-man!: the number of workgroups exceeds local_work_size, so the final sweep cannot cover every partial in one pass")
         ;; Phase 1 -- every thread of this workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
         ;; Phase 2 -- publish the partial, then take a ticket.
         (when-thread-in-group-is 0
           (set! (~ ,gv (to-int (get-workgroup-id 0))) ,var)
           ;; The partial must be visible to whoever sweeps it BEFORE the counter announces this
           ;; workgroup has arrived; otherwise the last workgroup can read a slot whose store is
           ;; still in flight.  Legal inside the election because a fence is not a collective
           ;; (BUG 082).
           (mem-fence)
           ;; The flag rides in the local scratch's slot 0.  A dedicated cell would be cleaner,
           ;; but a scratch allocated inside an ANALYZER's expansion is invisible to the Pass-1
           ;; scanner that builds the kernel's implicit parameters -- "Missing implicit argument
           ;; ... for make-scratch-cell".  Only scratch written in the SOURCE is threaded through.
           (set! (~ ,sv 0)
                 (if (= (atomic-add! (~ ,ctr) 1u)
                        (- (to-uint (get-num-groups 0)) 1u))
                     ,identity ,identity)))
         (sync-workgroup)
         (let ((,is-last (~ ,sv 0)))
           ;; THE SECOND BARRIER IS THE FIX FOR THE DOC'S RACE.  Every thread must finish READING
           ;; the flag before the sweep below starts WRITING the same buffer -- reduce-workgroup's
           ;; phase-1 leader store lands in slot 0.  Without this, a fast thread entering the
           ;; sweep clobbers the flag while a slow one is still reading it, intermittently.
           (sync-workgroup)
           ;; Uniform by construction: every thread read the same slot after a barrier.  when+ is
           ;; what says so to the analyzer, and it must, because the body contains barriers.
           (when+ (> ,is-last 0.5)
             (let ((,lid (to-int (get-local-linear-id)))
                   (,ng  (to-int (get-num-groups 0))))
               (let ((,val (if (< ,lid ,ng) (~ ,gv ,lid) ,identity)))
                 (reduce-workgroup ,fn ,val ,identity :local-scratch-vec ,sv)
                 (when-thread-in-group-is 0
                   (set! (~ ,return-vec 0) ,val))))))
         (compiler-no-op)))))

(defun %analyze-grid-reduce-last-man (expr env context location)
  "Analyzer for grid-reduce-last-man! -- expands and delegates."
  (analyze-expression (%grid-reduce-last-man-expand expr) env context location))

(defvar *orig-175f-register-ops-analyzers* (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load -- chains onto the earlier 175 wrappers.")

(defun register-ops-analyzers ()
  "Overlay wrapper: previous registrations, plus grid-reduce-last-man!."
  (funcall *orig-175f-register-ops-analyzers*)
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (setf (gethash (intern "GRID-REDUCE-LAST-MAN!" pkg) *expression-analyzers*)
              '%analyze-grid-reduce-last-man)))))

(defun %175-vjp-grid-reduce-last-man (form ctx)
  "VJP: out[0] is the sum over the whole grid, so every thread's adjoint is the output cell's
   adjoint -- identical to grid-reduce-atomic!'s rule, because the two constructs compute the
   same function by different schedules.  A derivative depends on WHAT is computed, not on how
   the work was divided, which is worth stating: the elaborate last-man machinery leaves no trace
   in the backward pass at all."
  (multiple-value-bind (fn var identity return-vec sv gv ctr)
      (%grid-reduce-last-man-parts form)
    (declare (ignore identity sv gv ctr))
    (let ((local-adj (getf ctx :local-adj)))
      (unless (and (consp fn) (symbolp (car fn))
                   (string-equal (symbol-name (car fn)) "FUNCTION")
                   (string= (symbol-name (second fn)) "+"))
        (error "grid-reduce-last-man!: autodiff is supported only for the + reduction.  A SUM over the grid gives d out / d x = 1 for every thread, so the adjoint is a plain broadcast of the output cell.  min/max would route the adjoint only to the thread that supplied the winning value, which needs an argmin/argmax the forward pass does not record; an arbitrary binop needs the partial derivatives of that op at every combining node.  Use the + reduction, or mark the kernel with a differentiate-skip if it is forward-only."))
      (unless (and var (symbolp var) return-vec (symbolp return-vec))
        (return-from %175-vjp-grid-reduce-last-man nil))
      (let* ((inputs  (getf ctx :inputs))
             (outputs (getf ctx :outputs))
             (pkg     (getf ctx :kernel-pkg))
             (vadj (funcall local-adj var))
             (radj (if (member return-vec outputs)
                       (intern (format nil "~A_GRAD" (symbol-name return-vec))
                               (symbol-package return-vec))
                       (%tlc-bwd-adj-name return-vec inputs outputs local-adj pkg))))
        (log:debug "175 VJP grid-reduce-last-man!: ~a := (~~ ~a 0)" vadj radj)
        `(set! ,vadj (~ ,radj 0))))))

(eval-when (:load-toplevel :execute)
  (register-vjp "GRID-REDUCE-LAST-MAN!" (function %175-vjp-grid-reduce-last-man)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 082: mem-fence is not a collective and must not be refused
;;; in divergent control flow.
;;; ---------------------------------------------------------------------------
;;; src/analysis/control.lisp  (%warp-spec-check-sync)
;;;
;;; %analyze-gpu-builtin routes :sync-workgroup, :sync-warp, :mem-fence and :sync-cluster through
;;; %warp-spec-check-sync, which -- outside a warp-specialization block -- hands all four to
;;; %tlc-check-not-divergent.  So a mem-fence inside any thread-divergent conditional is refused:
;;;
;;;     MEM-FENCE cannot appear inside a thread-divergent conditional (if / when / unless / cond).
;;;     It contains an internal sync-workgroup that would deadlock when only some threads enter.
;;;
;;; The claim in that message is FALSE for a fence.  mem-fence lowers to %ptx-membar-cta
;;; (PTX `membar.cta`) and %gen-spirv-memory-barrier (SPIR-V OpMemoryBarrier) -- both pure MEMORY
;;; fences, ordering one thread's accesses.  Neither is an execution barrier and neither requires
;;; other threads to arrive, so there is nothing to deadlock.  The message is inherited from
;;; %tlc-check-not-divergent, which was written for load-tile-at (which genuinely does contain an
;;; internal sync-workgroup).
;;;
;;; WHAT IT BLOCKS: publish-then-signal, the standard idiom for handing data between workgroups --
;;;
;;;     (when-thread-in-group-is 0
;;;       (set! (~ partials wg) value)
;;;       (mem-fence)                        ; make the store visible BEFORE announcing it
;;;       (atomic-add! (~ counter) 1u))
;;;
;;; which is exactly what grid-reduce-last-man! needs, and exactly how the design doc writes it.
;;; Hoisting the fence out of the election is a correct workaround but a worse one: it makes every
;;; thread fence to order a store only one of them performed.
;;;
;;; sync-warp KEEPS the check.  It is a warp COLLECTIVE -- every lane must arrive -- so divergence
;;; genuinely breaks it, exactly as it breaks a shuffle (173's D6).  Only the fence is exempt.

(defvar *orig-175-warp-spec-check-sync* (fdefinition '%warp-spec-check-sync)
  "Captured once at overlay load.")

(defun %warp-spec-check-sync (builtin-kw name-str location)
  "Overlay wrapper: mem-fence is a memory fence, not a collective, so it is legal in divergent
   control flow.  Everything else defers to the original check."
  (if (eq builtin-kw :mem-fence)
      nil
      (funcall *orig-175-warp-spec-check-sync* builtin-kw name-str location)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — grid-reduce-last-man!, corrected expansion (supersedes the one above).
;;; ---------------------------------------------------------------------------
;;; NO LAST-MAN FLAG, AND NO GATE ON THE SWEEP.  The design doc elects the last workgroup, stores
;;; a flag where every thread can see it, and runs the final sweep only in that workgroup.  Two
;;; things make that hard to reproduce honestly here:
;;;
;;;   * THE FLAG HAS NO TYPE.  It would live in the local scratch, whose element type follows the
;;;     reduction's -- so there is no generic way to write "1" and "0" into it.  (- var var) gives
;;;     a typed zero; nothing gives a typed one.  A dedicated uint cell would solve it, but a
;;;     scratch allocated inside an ANALYZER's expansion is invisible to the Pass-1 scanner that
;;;     builds the kernel's implicit parameters -- "Missing implicit argument ... for
;;;     make-scratch-cell".  Only scratch written in the SOURCE is threaded through.
;;;   * GATING THE SWEEP GATES BARRIERS.  reduce-workgroup contains sync-workgroup, so the gate
;;;     must be provably workgroup-uniform or the collective is refused.
;;;
;;; The observation that removes both: THREAD 0 ALREADY KNOWS.  It took the ticket, so it needs
;;; no broadcast to learn whether its workgroup was last -- only the STORE has to be elected, and
;;; a store is not a collective.  So every workgroup sweeps, and exactly one stores.
;;;
;;; IS THE UNGATED SWEEP CORRECT?  Yes, and the reason is the ticket, not the schedule.  A
;;; workgroup receiving ticket num_groups-1 is by definition the last to increment, so every other
;;; workgroup has already completed its fence-ordered store; the data it sweeps is complete.  The
;;; others sweep partial data -- global scratch is zero-initialised, so they read zeros rather
;;; than garbage -- and discard it unstored.
;;;
;;; THE COST, stated plainly: num_groups-1 workgroups perform one redundant reduce-workgroup.
;;; That is a real regression against the doc's design and it is a deliberate trade for
;;; correctness and simplicity.  It becomes recoverable the moment Crisp grows a workgroup
;;; BROADCAST -- to-workgroup-uniform is currently a pass-through that emits a barrier
;;; (codegen.lisp says so in its own docstring), not a broadcast.  Worth revisiting when the
;;; reduction benchmarks land, since this is exactly the construct the doc calls "usually the
;;; fastest".

(defun %grid-reduce-last-man-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081)."
  (multiple-value-bind (fn var identity return-vec sv gv ctr)
      (%grid-reduce-last-man-parts expr)
    (dolist (pair (list (list return-vec "a return-vec" "the single global element the grid reduces into")
                        (list sv ":local-scratch-vec" "one element per warp, for the per-workgroup reduction")
                        (list gv ":global-scratch-vec" "one element per WORKGROUP, holding the partials")
                        (list ctr ":atomic-counter"   "a zero-initialised global uint cell, used to elect the last workgroup")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-last-man!: ~a is required -- ~a.  These cannot be auto-generated: their element type follows VAR's, which is not known at analysis time, and a scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters."
                                (second pair) (third pair))
               :source-location nil)))
    (let ((ticket (gensym "LM-TICKET"))
          (lid    (gensym "LM-LID"))
          (ng     (gensym "LM-NG"))
          (val    (gensym "LM-VAL")))
      `(progn
         ;; The final sweep is ONE reduce-workgroup, so every partial must fit in one workgroup.
         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                       "grid-reduce-last-man!: the number of workgroups exceeds local_work_size, so the final sweep cannot cover every partial in one pass")
         ;; Phase 1 -- every thread of this workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
         (let ((,ticket 0u))
           (when-thread-in-group-is 0
             (set! (~ ,gv (to-int (get-workgroup-id 0))) ,var))
           ;; The partial must be visible BEFORE the counter announces this workgroup has
           ;; arrived, or the last workgroup can sweep a slot whose store is still in flight.
           ;; OUTSIDE the election: a fence inside a divergent conditional is refused (BUG 082,
           ;; over-strict but load-bearing for sync-wait).  Ordering is preserved regardless,
           ;; because it is thread 0's OWN program order that carries it -- its store precedes
           ;; its fence precedes its atomic.  The other 63 threads fence for nothing.
           (mem-fence)
           (when-thread-in-group-is 0
             ;; atomic-add! yields the value BEFORE the addition, so exactly one workgroup sees
             ;; num_groups-1.  Verified on hardware rather than assumed.
             (set! ,ticket (atomic-add! (~ ,ctr) 1u)))
           (sync-workgroup)
           ;; Phase 3 -- UNGATED sweep; see the section header for why this is not a gate.
           (let ((,lid (to-int (get-local-linear-id)))
                 (,ng  (to-int (get-num-groups 0))))
             (let ((,val (if (< ,lid ,ng) (~ ,gv ,lid) ,identity)))
               (reduce-workgroup ,fn ,val ,identity :local-scratch-vec ,sv)
               ;; Only the elected thread of the LAST workgroup stores.  Its ticket is a register
               ;; it has carried since phase 2 -- no broadcast, and a store is not a collective.
               (when-thread-in-group-is 0
                 (when (= ,ticket (- (to-uint (get-num-groups 0)) 1u))
                   (set! (~ ,return-vec 0) ,val))))))
         (compiler-no-op)))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — BUG 083: make-scratch-* silently discarded :address-space :global.
;;; ---------------------------------------------------------------------------
;;; src/analysis/structs.lisp  (%scratch-tensor-canonical-spec)
;;;
;;; Both branches of that function ended with
;;;
;;;     (append raw-spec '(:address-space :local :align :compact))
;;;
;;; with the address space HARDCODED.  So (make-scratch-vector float 4 :address-space :global)
;;; compiled, emitted metadata reading `:address-space :local`, and the L0 hoister then allocated
;;; workgroup-local SLM for it:
;;;
;;;     // LOCAL scratch tensor: gv (rank=1, float, 4 elems, 16 bytes)
;;;     zeKernelSetArgumentValue(kernel, 3, 16ULL, nullptr);
;;;
;;; -- one private copy per workgroup.  Measured consequence: four workgroups each wrote their
;;; partial into "the" buffer and the workgroup that swept it saw ONLY ITS OWN (0 0 102 0, where
;;; 102 was the sweeper's own value).  Nothing failed; the answer was quietly a quarter right.
;;;
;;; THE GLOBAL SCRATCH CELL WAS FINE ALL ALONG, which is what made this confusing: the atomic
;;; counter in the same kernel is a CELL, takes %make-global-scratch-cell's separate path, gets
;;; real device memory, and is genuinely shared -- the ticket reached num_groups-1 correctly.  So
;;; the cross-workgroup election worked while the cross-workgroup DATA did not.
;;;
;;; THE HOISTER NEEDED NO CHANGE.  %l0-emit-global-scratch-tensor-arg already exists and the
;;; dispatch already routes a non-local tensor with a :size-expr to it (device memory plus the
;;; zero-initialised host staging mirror endeavour 166 added).  Only the analyzer was dropping
;;; the address space, so honouring the key is the whole fix.
;;;
;;; FOUND BY grid-reduce-last-man!, which is the first construct in Crisp to need cross-workgroup
;;; DATA rather than just a cross-workgroup counter.

(defun %175-scratch-address-space (args)
  "The :address-space requested in a make-scratch-* arg list, defaulting to :local.
   Refuses anything but :local or :global -- a scratch buffer in :constant or a private space is
   not a thing the hoisters can allocate, and silently downgrading is what BUG 083 was."
  ;; Located by SEARCHING FOR THE KEY, not by parsing a plist tail.  Two traps rule the
  ;; alternatives out: the keyword tail starts at a different position per form ((elem size
  ;; &rest keys) for vector/matrix, (elem N size &rest keys) for the rank-N tensor), and a
  ;; SYMBOLIC SIZE is itself a keyword -- so scanning for the first keyword picks up
  ;; :match-num-warps-per-workgroup and reports "malformed property list".
  (let* ((pos (position :address-space args))
         (as  (if pos (nth (1+ pos) args) :local)))
    (unless (member as '(:local :global))
      (error 'crisp-compiler-error
             :message (format nil "make-scratch-*: :address-space must be :local or :global, got ~s. A scratch buffer is either workgroup-local (SLM) or grid-global (device memory); there is nothing else the hoisting code can allocate."
                              as)
             :source-location nil))
    as))

(defvar *orig-175-scratch-canonical-spec* (fdefinition '%scratch-tensor-canonical-spec)
  "Captured once at overlay load.")

(defun %scratch-tensor-canonical-spec (op args)
  "Overlay wrapper: honours :address-space instead of hardcoding :local.

   Implemented as a post-pass over the original's result rather than a reimplementation -- the
   original resolves aliases, implicit ranks and storage-handle expansion, none of which this
   changes.  It rewrites the address-space slot of the canonical
   (tensor elem N addr align ct) tuple only when :global was asked for."
  (let ((spec (funcall *orig-175-scratch-canonical-spec* op args))
        (as   (%175-scratch-address-space args)))
    (if (and (eq as :global)
             (consp spec)
             (symbolp (first spec))
             (string-equal (symbol-name (first spec)) "TENSOR")
             (>= (length spec) 4))
        ;; Canonical shape is (tensor elem N addr align ct); slot 3 is the address space.
        (let ((copy (copy-list spec)))
          (setf (nth 3 copy) :global)
          (log:debug "175: scratch ~a promoted to :global -> ~s" op copy)
          copy)
        spec)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — REVERTING the mem-fence divergence exemption (BUG 082).
;;; ---------------------------------------------------------------------------
;;; The exemption above is WRONG and is undone here (last definition wins).
;;;
;;; The reasoning behind it still holds in isolation: mem-fence lowers to a pure memory fence on
;;; both backends and does not wait for anyone.  But %warp-spec-check-sync is not only reached by
;;; a user-written mem-fence -- sync-wait's lowering goes through it too, and that check was the
;;; ONLY thing refusing a sync-wait inside a thread-divergent conditional.  Exempting the fence
;;; therefore made an arrival-barrier WAIT legal in divergent control flow, which deadlocks.
;;; 118-async-misc/errors/02-arrival-sync-divergent caught it immediately: it asserts the refusal
;;; and matches on the MEM-FENCE wording, which is itself the tell that the diagnostic is
;;; attributed to the wrong construct.
;;;
;;; So the over-strictness is real but the fix is not a blanket exemption: the divergence check
;;; belongs on sync-wait (which genuinely needs convergence) rather than on the fence it happens
;;; to emit.  Left OPEN in plan/bugs.md rather than half-fixed here.
;;;
;;; grid-reduce-last-man! does not need the exemption anyway.  Hoisting the fence OUT of the
;;; leader election preserves the ordering that matters, because it is thread 0's OWN program
;;; order that carries the guarantee:
;;;
;;;     (when-thread-in-group-is 0 (set! (~ gv wg) partial))   ; store
;;;     (mem-fence)                                            ; every thread, incl. thread 0
;;;     (when-thread-in-group-is 0 (set! ticket (atomic-add! ...)))
;;;
;;; The cost is that 63 other threads fence to order a store none of them made -- measurably
;;; nothing here, and honest.

(defun %warp-spec-check-sync (builtin-kw name-str location)
  "Restored to the src behaviour: every sync/fence builtin gets the divergence check."
  (funcall *orig-175-warp-spec-check-sync* builtin-kw name-str location))


;;; ---------------------------------------------------------------------------
;;; Endeavour 175 — grid-reduce-last-man! with a REAL election (supersedes both above).
;;; ---------------------------------------------------------------------------
;;; The previous expansion had every workgroup sweep the global partials and let only the last
;;; one store.  Correct, but it threw away the algorithm's entire point.
;;;
;;; WHY EARLY RETIREMENT IS THE POINT, not an optimisation.  The whole reason last-man-standing
;;; beats a second kernel launch is that the LOSING workgroups finish and RETIRE the moment they
;;; draw a losing ticket, handing their registers, SLM and occupancy slots straight back to the
;;; hardware scheduler so the remaining workgroups can launch.  A version where all N workgroups
;;; stay resident to perform a sweep that N-1 of them discard holds those slots hostage and
;;; saturates the memory path re-reading a buffer that, for the early arrivals, is still mostly
;;; zeros.  On a grid larger than the GPU can hold concurrently that is the difference between
;;; the strategy's advertised behaviour and a slower version of a two-pass reduction.
;;;
;;; (It does NOT deadlock, for the record: nothing in either shape waits on another workgroup.
;;; The counter is a ticket, not a barrier -- no one spins, so there is no cycle to close.)
;;;
;;; WHAT MADE THE ELECTION HARD, and how the caller solves it.  The whole workgroup must learn
;;; what only THREAD 0 knows (its ticket), because the final sweep is a reduce-workgroup and every
;;; thread has to reach its barriers.  That broadcast needs a scratch cell, and two things ruled
;;; out allocating one inside this expansion:
;;;
;;;   * a scratch created in an ANALYZER's expansion is invisible to the Pass-1 scanner that
;;;     builds the kernel's implicit parameters -- "Missing implicit argument ... for
;;;     make-scratch-cell";
;;;   * parking the flag in the local scratch VECTOR instead fails on type: its element type
;;;     follows the reduction's, and there is no generic way to write "1" and "0" into a buffer
;;;     of unknown type.  (- var var) gives a typed zero; nothing gives a typed one.
;;;
;;; :election-flag-cell fixes both at once.  Allocated in the CALLER's scope it is seen by Pass 1
;;; like every other scratch, and being a fixed uint it never inherits the reduction's type.  It
;;; is the same bargain :local-scratch-vec already makes, for the same reason.

(defun %grid-reduce-last-man-parts (expr)
  "Destructures (grid-reduce-last-man! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec local global counter flag)."
  (let ((keys (cdr (cdddr (cdr expr)))))
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec)
            (getf keys :global-scratch-vec)
            (getf keys :atomic-counter)
            (getf keys :election-flag-cell))))

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
                 (set! (~ ,return-vec 0) ,val)))))
         (compiler-no-op)))))
