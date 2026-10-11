(in-package :cl-user)

(defpackage :crisp.test.allocas-in-entry-block
  (:use :cl :parachute))

(in-package :crisp.test.allocas-in-entry-block)

;;; Endeavour 184 step 3 -- every alloca is in its function's ENTRY block.
;;;
;;; SROA and mem2reg promote only entry-block allocas.  Crisp used to build each alloca at the
;;; current insert point, so a variable bound inside a branch or a loop -- a let, a loop counter, an
;;; if-result slot -- stayed in memory after -O3.  The CAS retry loop of 175/38, which sits inside
;;; when-thread-in-group-is 0, round-tripped its counter through .local on every iteration.
;;;
;;; The claim is on the UNOPTIMIZED IR (after -O3 a promoted alloca is simply gone, which proves
;;; nothing about where it was built).  The kernels bind variables inside branches and loops: the CAS
;;; loop (175/38), early exits in dotimes (184/01), and a 172 loop variant (172/06).

(defparameter *specs*
  '("tests/spec/175-reductions/38-grid-reduce-cas-metal.crisp"
    "tests/spec/184-cas-lowering/01-return-from-loop-dotimes-metal.crisp"
    "tests/spec/172-do-times-variants/06-do-power-step-metal.crisp"))

(defun %label-line-p (line)
  "T when LINE is a basic-block label, e.g. \"dt_body:\" or \"then12:\" (optionally followed by a comment)."
  (let ((colon (position #\: line)))
    (and colon (plusp colon)
         (not (find #\Space line :end colon))
         (not (char= (char line 0) #\;))
         (let ((rest (string-trim " " (subseq line (1+ colon)))))
           (or (string= rest "") (char= (char rest 0) #\;))))))

(defun %non-entry-allocas (ir)
  "List of (function-line . alloca-line) for every alloca outside its function's entry block."
  (let ((bad '()) (fn nil) (in-entry nil) (seen-instr nil))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (cond ((and (>= (length line) 6) (string= "define" line :end2 6))
                      (setf fn line in-entry t seen-instr nil))
                     ((null fn))
                     ((and (plusp (length line)) (char= (char line 0) #\}))
                      (setf fn nil))
                     ((%label-line-p line)
                      ;; A label before any instruction names the entry block itself.
                      (when seen-instr (setf in-entry nil)))
                     ((string= (string-trim " " line) ""))
                     (t
                      (setf seen-instr t)
                      (when (and (not in-entry) (search " = alloca " line))
                        (push (cons fn line) bad))))))
    (nreverse bad)))

(define-test allocas-are-in-the-entry-block
  (dolist (spec *specs*)
    (let ((bad (%non-entry-allocas (crisp.spec-runner::compile-crisp-file-to-ir-string spec))))
      (true (null bad)
            (format nil "~a: ~d alloca(s) outside the entry block -- SROA/mem2reg cannot promote them.  First: ~a"
                    spec (length bad) (cdr (first bad)))))))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'allocas-are-in-the-entry-block))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "allocas-in-entry-block: ~d test(s) failed -- an alloca is outside its function's entry block (184 step 3)."
           (length failures))))
