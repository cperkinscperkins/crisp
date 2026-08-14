;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145),
;;;; and again 2026-08-09 (endeavour 146).
;;;;
;;;; To add one: APPEND a complete definition with a `;; src/<file>.lisp` comment
;;;; above it saying where it belongs.  Do not patch definitions already here.
;;;; Note that macros and structs CANNOT be overridden this way -- they are not
;;;; late-bound -- and must be patched in src/ directly.
;;;;
;;;; A NOTE ON WRAPPERS, learned the hard way in 146.  Capturing an original with
;;;;     (defvar *orig-foo* (symbol-function 'foo))
;;;; and then redefining FOO works beautifully in an overlay and does NOT survive
;;;; copy-paste into src/ -- there is no "original" there to capture.  Each such
;;;; wrapper has to be MERGED INTO the real function body when it is folded back.
;;;; If you reach for that pattern, note in the header which src function the
;;;; wrapper's body ultimately belongs inside.
;;;;
;;;; IN FLIGHT: endeavour 149, AD PRIMAL REPLAY.  One wrapper is used, on
;;;; GENERATE-BACKWARD-WALK; see the note above %AD-REPLAY-FINISH for exactly where
;;;; its two lines belong when this is folded into src/autodiff.lisp.

(in-package :crisp.compiler)


;;; -------------------------------------------------------------------
;;; The top-level sequence.
;;;
;;; WHEN FOLDING INTO src/: this wrapper exists only because the kernel's top-level
;;; statement sequence is walked INSIDE generate-backward-walk (src/autodiff.lisp,
;;; the `(dolist (form reversed-body) (process-form form #'emit))` near its end).
;;; The two things it does belong in that function directly:
;;;
;;;   - at the TOP of generate-backward-walk, alongside the existing
;;;     `(setf *ad-tile-src-map* ...)`:
;;;         (setf *ad-replay-pending* nil
;;;               *ad-output-syms*   outputs)
;;;   - where `result` is built, replace it with (%ad-replay-finish result flat-anf).
;;;
;;; No part of %AD-REPLAY-FINISH itself needs to change when it moves.
;;; -------------------------------------------------------------------

;; src/autodiff.lisp
(defun %ad-replay-finish (result flat-anf)
  "Closes the kernel's top-level sequence: splices any remaining replay into the head
   of the assembled backward RESULT, and refuses if a primal is still unaccounted for.

   This is where the pre-149 refusal now lives.  Reaching it means no scope, top-level
   included, contained statements that fill the tile -- a tile built by something the
   backward genuinely cannot reconstruct.  Refusing is still strictly better than the
   alternative it replaced: a backward that reads an empty tile and returns zero."
  (let ((replay (%ad-replay-forms-for-scope flat-anf)))
    (when *ad-replay-pending*
      (error 'crisp-compiler-error
             :message (format nil "cannot differentiate: the backward needs the PRIMAL value of ~a, a scratch tile that is not filled by load-tile-at, so its contents cannot be recovered (a backward kernel replays the forward's bindings but not its statements).  Tiles staged with load-tile-at are read back from their global source automatically, and hand-staged tiles are refilled by replaying the statements that stage them -- but no statement in this kernel fills ~:*~a.  Restructure so the value the gradient needs comes from a staged or global operand, or mark the kernel forward-only.  See plan/bugs.md #037."
                               (first *ad-replay-pending*))
             :source-location nil))
    (cond
      ((null replay) result)
      ((and (consp result) (symbolp (car result))
            (string= (symbol-name (car result)) "LET"))
       (log:debug "149: splicing ~a top-level replay statement(s) into the backward"
                  (length replay))
       (list* (first result) (second result) (append replay (cddr result))))
      (t `(progn ,@replay ,result)))))

;; src/autodiff.lisp -- see the folding note above; this wrapper's body belongs
;; INSIDE generate-backward-walk.
(defvar *%ad-orig-generate-backward-walk* nil
  "The pre-149 GENERATE-BACKWARD-WALK, captured once so the overlay can wrap it.")

(unless *%ad-orig-generate-backward-walk*
  (setf *%ad-orig-generate-backward-walk* (symbol-function 'generate-backward-walk)))

(setf (fdefinition 'generate-backward-walk)
      (lambda (flat-anf inputs outputs input-types output-types &rest keys)
        (setf *ad-replay-pending* nil
              *ad-output-syms* outputs)
        (let ((result (apply *%ad-orig-generate-backward-walk*
                             flat-anf inputs outputs input-types output-types keys)))
          (%ad-replay-finish result flat-anf))))
