;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)





;; ======================================================================
;; Endeavor 167 — matrix-multiply-tile-stride :let / :prologue / :body
;; ======================================================================

;; tests/run-specs.lisp
(defun validate-let-single-reset (file ir-string)
  "Validator for 167/04: a register accumulator bound in the macro's :let section must be
   zero-initialised EXACTLY ONCE per output tile.

   Measured 2026-09-17: a register tile bound inside tile-stride already emits its zero
   CompositeConstruct + store in the grid-x loop body, before the K loop -- the same slot
   %mmts-lower drops its BUG 036 fill-tile into.  So on the :let path the binding IS the
   reset, and an additional macro-emitted fill would be a redundant full-tile zero-write on
   the hot path of every converted benchmark: correct, invisible to MMA_CORRECT, pure cost.

   Metal cannot see the difference, so it is asserted here on the IR.  Counts the zero-valued
   accumulator CompositeConstruct in the SPIR-V coop-matrix lowering; one is right, two means
   the macro double-reset a tile that resets itself, zero means nothing reset it at all."
  (declare (ignore file))
  (let ((needle "@__spirv_CompositeConstruct_2_8_16(float 0.000000e+00)")
        (count 0)
        (start 0))
    (loop for pos = (search needle ir-string :start2 start)
          while pos
          do (incf count) (setf start (+ pos (length needle))))
    (cond
      ((= count 1)
       (format t "PASS (accumulator zero-init appears exactly once)~%")
       t)
      ((zerop count)
       (format t "FAIL (no accumulator zero-init found -- nothing resets the C-tile)~%")
       nil)
      (t
       (format t "FAIL (accumulator zero-init appears ~d times -- the macro emitted a reset for a :let-bound tile that already resets itself)~%" count)
       nil))))
