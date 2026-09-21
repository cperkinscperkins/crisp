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
  (%shuffle-check-not-divergent (or (second expr) "this warp collective") location)
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

(defmacro reduce-warp (fn var identity &optional active-threads)
  "Reduce VAR across the current warp with the commutative binop FN, leaving the result in
   VAR in EVERY lane of the warp.  IDENTITY seeds the lanes outside ACTIVE-THREADS."
  (%reduce-warp-check-active-threads active-threads)
  (let ((s (gensym "RW-S")))
    `(progn
       (%warp-collective-check "reduce-warp")
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
         (set! ,var (funcall ,fn (shuffle-xor ,var ,s) ,var)))
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
  `(when (= (to-int (get-local-id 0)) ,id)
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
