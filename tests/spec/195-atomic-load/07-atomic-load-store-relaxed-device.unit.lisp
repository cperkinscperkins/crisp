(in-package :cl-user)

(defpackage :crisp.test.atomic-load-store-relaxed-device
  (:use :cl :parachute))

(in-package :crisp.test.atomic-load-store-relaxed-device)

;;; Endeavour 195 -- atomic-load and atomic-store! lower to LLVM `load atomic` / `store atomic`,
;;; RELAXED (monotonic) at DEVICE scope: the 184 rule, "atomics order nothing, fences do" (D-195-2).
;;;
;;; The test reads the LLVM IR of the 195 specs and requires that
;;;   - each spec has at least one atomic load AND one atomic store (the feature really emitted), and
;;;   - every atomic load / store line carries syncscope("device") and monotonic, never seq_cst.
;;; A missing sync scope would default to system scope ("" in LLVM), which NVPTX lowers to
;;; ld.relaxed.sys and llvm-spirv to CrossDevice -- correct, but not the scope every other Crisp
;;; atomic uses.

(defparameter *specs*
  '(("tests/spec/195-atomic-load/01-atomic-load-store-uint-metal.crisp"          :load t)
    ("tests/spec/195-atomic-load/02-atomic-load-store-64-and-int-metal.crisp"    :load t)
    ("tests/spec/195-atomic-load/03-atomic-load-store-float-metal.crisp"         :load t)
    ("tests/spec/195-atomic-load/04-atomic-load-store-local-metal.crisp"         :load t)
    ("tests/spec/195-atomic-load/05-publish-poll-across-workgroups-metal.crisp"  :load t)
    ;; 06 only publishes (atomic-load is refused under --differentiate, and 06 differentiates)
    ("tests/spec/195-atomic-load/06-int-store-in-differentiated-kernel.crisp"    :load nil))
  "Each spec, and whether it must contain an atomic LOAD (every one must contain an atomic store).")

(defun %lines-containing (ir needle)
  "Every line of IR containing NEEDLE."
  (let ((lines '()))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (when (search needle line) (push line lines))))
    (nreverse lines)))

(define-test atomic-load-store-are-relaxed-at-device-scope
  (dolist (entry *specs*)
    ;; compile-crisp-file-to-ir-string honours *compile-differentiate*, and under `run-specs
    ;; --differentiate` the atomic-loads here are refused by design (D-195-7).  This test is about the
    ;; FORWARD lowering, so it always compiles forward (as 167's unit test does).
    (let* ((spec   (first entry))
           (ir     (let ((crisp.spec-runner::*compile-differentiate* nil))
                     (crisp.spec-runner::compile-crisp-file-to-ir-string spec)))
           (loads  (%lines-containing ir " load atomic "))
           (stores (%lines-containing ir " store atomic ")))
      (when (getf (rest entry) :load)
        (true loads (format nil "~a should contain an atomic load." spec)))
      (true stores (format nil "~a should contain an atomic store." spec))
      (dolist (line (append loads stores))
        (true (search "syncscope(\"device\")" line)
              (format nil "~a: atomic load/store is not at device scope: ~a" spec line))
        (true (search "monotonic" line)
              (format nil "~a: atomic load/store is not relaxed (monotonic): ~a" spec line))
        (false (search "seq_cst" line)
               (format nil "~a: atomic load/store is seq_cst: ~a" spec line))))))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'atomic-load-store-are-relaxed-at-device-scope))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "atomic-load-store-relaxed-device: ~d test(s) failed -- an atomic load/store is not relaxed at device scope (195)."
           (length failures))))
