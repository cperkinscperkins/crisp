(in-package :cl-user)

(defpackage :crisp.test.independent-fusion
  (:use :cl :parachute))

(in-package :crisp.test.independent-fusion)

;;; ENDEAVOUR 176 Phase 2b -- the independent form's EFFICIENCY claims, checked on the unoptimized IR.
;;;
;;; The reductions doc promises that an independent call does its work ONCE for all its clauses: one
;;; shuffle sweep at warp level, one barrier sequence at workgroup level, and one last-man ELECTION (one
;;; ticket per workgroup) at grid level.  A correct-but-unfused implementation -- one single-variable
;;; reduction per clause -- passes every metal spec but doubles each of these.
;;;
;;; Each test compiles the SAME kernel with one clause and with two, and requires the structural counts
;;; to be EQUAL.  Comparing against itself keeps the check independent of unrelated code and of how many
;;; barriers one reduction happens to use.

(defparameter *kernel-template*
  "(def-type vec-t (vector float :address-space :global :align :compact))
   (def-type out-c (cell float :address-space :global))
   (def-kernel fusion_probe (&out out o1 o2)
     (declare #'(&out vec-t out-c out-c => nil)
              (global-size :set-to ~a)
              (local-size  :set-to 64))
     (let ((a (to-float (get-global-linear-id)))
           (b (to-float (get-global-linear-id))))
       ~a
       (set! (~~ out 0) a)))")

(defun %ir-for (group-count body)
  "Compile the probe kernel with BODY (a string) and return its unoptimized LLVM IR."
  (uiop:with-temporary-file (:pathname p :type "crisp" :keep nil)
    (with-open-file (s p :direction :output :if-exists :supersede)
      (format s *kernel-template* group-count body))
    (crisp.spec-runner::compile-crisp-file-to-ir-string p)))

(defun %count-lines (ir predicate)
  (with-input-from-string (s ir)
    (loop for line = (read-line s nil) while line count (funcall predicate line))))

(defun %loops (ir)
  "Loop bodies emitted by the reduction sweeps (dec-times-by-half+ lowers to lv_* blocks)."
  (%count-lines ir (lambda (l) (and (> (length l) 7) (string= "lv_body" l :end2 7)
                                    (char= (char l (1- (length l))) #\:)))))

(defun %barriers (ir)
  (%count-lines ir (lambda (l) (and (search "call " l) (search "ControlBarrier" l)))))

(defun %atomics (ir)
  (%count-lines ir (lambda (l) (search "atomicrmw" l))))

(define-test independent-warp-is-one-sweep
  (let ((one (%ir-for 64 "(reduce-warp ((#'+ a 0.0)))"))
        (two (%ir-for 64 "(reduce-warp ((#'+ a 0.0) (#'max b (type-min float))))")))
    (is = (%loops one) (%loops two) "two clauses must share ONE shuffle sweep")))

(define-test independent-workgroup-is-one-barrier-sequence
  (let ((one (%ir-for 64 "(reduce-workgroup ((#'+ a 0.0)))"))
        (two (%ir-for 64 "(reduce-workgroup ((#'+ a 0.0) (#'max b (type-min float))))")))
    (is = (%barriers one) (%barriers two) "two clauses must share ONE barrier sequence")
    (is = (%loops one) (%loops two) "two clauses must share the warp sweep and the halving sweep")))

(define-test independent-last-man-is-one-election
  (let ((one (%ir-for 256 "(grid-reduce! ((#'+ a 0.0 o1)))"))
        (two (%ir-for 256 "(grid-reduce! ((#'+ a 0.0 o1) (#'+ b 0.0 o2)))")))
    (is = (%atomics one) (%atomics two) "two clauses must draw ONE ticket per workgroup")
    (is = (%barriers one) (%barriers two) "two clauses must share one barrier sequence")))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the tests here and signal on failure.
(let* ((report (test '(independent-warp-is-one-sweep
                       independent-workgroup-is-one-barrier-sequence
                       independent-last-man-is-one-election)))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "independent-fusion: ~d test(s) failed -- an independent reduction is not fused (176 Phase 2b)."
           (length failures))))
