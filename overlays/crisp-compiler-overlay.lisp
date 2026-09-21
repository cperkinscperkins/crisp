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
