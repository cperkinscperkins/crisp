(in-package :cl-user)

(defpackage :crisp.test.and-result-stored
  (:use :cl :parachute))

(in-package :crisp.test.and-result-stored)

;;; BUG 092 -- a structural check on the UNOPTIMIZED IR, so the broken shape is caught before -O3
;;; hides it (at -O3 the symptom is a deleted comparison, which is much harder to assert on).
;;;
;;; Every value-producing IF allocates a result slot named %if_result<N>.  In the and-as-IF-test
;;; kernel (07) every IF is a value IF -- the `and`s and the (if .. 1 0)s around them -- so every
;;; slot must be stored on BOTH branches: at least two stores.  Before the fix, each `and` slot
;;; had exactly one (the then branch).

(defun %if-result-store-counts (ir)
  "Alist of (slot-name . store-count) for every %if_result* alloca in IR."
  (let ((slots '()))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (let ((p (search "%if_result" line)))
                 (when (and p (search "= alloca" line))
                   (let ((end (position #\Space line :start p)))
                     (push (cons (subseq line p end) 0) slots))))))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (when (search "store " line)
                 (dolist (slot slots)
                   (when (search (format nil "ptr ~a," (car slot)) line)
                     (incf (cdr slot)))))))
    slots))

(define-test and-result-stored-on-both-paths
  (let* ((ir (crisp.spec-runner::compile-crisp-file-to-ir-string
              "tests/spec/006-branching/07-and-as-if-test-metal.crisp"))
         (slots (%if-result-store-counts ir)))
    (true slots "The kernel should allocate IF result slots.")
    (dolist (slot slots)
      (true (>= (cdr slot) 2)
            (format nil "IF result slot ~a is stored ~a time(s); a value IF must store it on both branches."
                    (car slot) (cdr slot))))))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'and-result-stored-on-both-paths))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "and-result-stored: ~d test(s) failed -- an IF result slot is left unstored on one branch (BUG 092)."
           (length failures))))
