(in-package :cl-user)

(defpackage :crisp.test.cas-loop-exits
  (:use :cl :parachute))

(in-package :crisp.test.cas-loop-exits)

;;; Endeavour 184 -- the CAS retry loop under atomic-binop! must LEAVE once its CAS succeeds.
;;;
;;; Before 184 the loop was (dotimes+ (r (+ global-size 1)) (when (= done 0) ...)): correct, but every
;;; contender ran all global-size + 1 iterations even when it won on the first try -- a flat
;;; per-launch cost (1.1 ms on BMG, 7.8 ms on H100) whatever the input size.
;;;
;;; The claim is structural, on the UNOPTIMIZED IR of a kernel whose only loop around a cmpxchg is the
;;; retry loop (175/38, grid-reduce! :cas).  A dotimes reaches its exit block only CONDITIONALLY --
;;; the stride guard and the bound check are both cond-brs -- so an UNCONDITIONAL `br label %dt_exit`
;;; exists only where something leaves the loop early.  return-from-loop is the only thing that does.

(defun %count-lines-matching (ir needle)
  "Number of lines of IR that contain NEEDLE."
  (let ((n 0))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (when (search needle line) (incf n))))
    n))

(define-test cas-loop-exits-on-success
  (let ((ir (crisp.spec-runner::compile-crisp-file-to-ir-string
             "tests/spec/175-reductions/38-grid-reduce-cas-metal.crisp")))
    (true (plusp (%count-lines-matching ir "cmpxchg"))
          "175/38 should contain the cmpxchg of the CAS retry loop.")
    (true (plusp (%count-lines-matching ir "br label %dt_exit"))
          "The CAS retry loop has no unconditional branch to its exit: it cannot leave once its CAS succeeds, so every contender runs the full global-size + 1 iterations.")))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'cas-loop-exits-on-success))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "cas-loop-exits: ~d test(s) failed -- the CAS retry loop does not leave on success (184)."
           (length failures))))
