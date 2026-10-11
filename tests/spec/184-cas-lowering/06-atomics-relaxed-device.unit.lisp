(in-package :cl-user)

(defpackage :crisp.test.atomics-relaxed-device
  (:use :cl :parachute))

(in-package :crisp.test.atomics-relaxed-device)

;;; Endeavour 184 step 2 -- every Crisp atomic is RELAXED at DEVICE scope.  Ordering is never implied
;;; by an atomic; it comes only from an explicit mem-fence (as last-man-standing already does, 183).
;;;
;;; Before 184 every atomic was seq_cst at system scope (082 chose it believing it "matches CUDA
;;; atomicAdd" -- it does not; atomicAdd is relaxed at device scope).  On NVPTX that put a fence.sc.sys
;;; before every cmpxchg attempt; on SPIR-V every atomic was CrossDevice / SequentiallyConsistent.
;;;
;;; DEVICE is the floor, not a preference: fence-fence synchronisation with a relaxed atomic needs the
;;; atomic's scope to include the fences' (mem-fence is device scope on both backends).  The scope is
;;; spelled "device" -- NVPTX and llvm-spirv both honour it; llvm-spirv silently turns "agent" into
;;; CrossDevice.
;;;
;;; The kernels cover both emission sites: the atomicrmw builder (082: integer add on a cell, float
;;; add, xchg) and the cmpxchg builder (175/38: grid-reduce! :cas).

(defparameter *specs*
  '("tests/spec/082-atomics/01-atomic-add-cell.crisp"
    "tests/spec/082-atomics/07-atomic-xchg-cell.crisp"
    "tests/spec/082-atomics/08-atomic-add-float.crisp"
    "tests/spec/175-reductions/38-grid-reduce-cas-metal.crisp"))

(defun %atomic-lines (ir)
  "Every line of IR that is an atomicrmw or cmpxchg instruction."
  (let ((lines '()))
    (with-input-from-string (s ir)
      (loop for line = (read-line s nil) while line
            do (when (or (search " atomicrmw " line) (search " cmpxchg " line))
                 (push line lines))))
    (nreverse lines)))

(define-test atomics-are-relaxed-at-device-scope
  (dolist (spec *specs*)
    (let ((lines (%atomic-lines (crisp.spec-runner::compile-crisp-file-to-ir-string spec))))
      (true lines (format nil "~a should contain at least one atomic." spec))
      (dolist (line lines)
        (true (search "syncscope(\"device\")" line)
              (format nil "~a: atomic is not at device scope: ~a" spec line))
        (true (search "monotonic" line)
              (format nil "~a: atomic is not relaxed (monotonic): ~a" spec line))
        (false (search "seq_cst" line)
               (format nil "~a: atomic is still seq_cst: ~a" spec line))))))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'atomics-are-relaxed-at-device-scope))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "atomics-relaxed-device: ~d test(s) failed -- an atomic is not relaxed at device scope (184 step 2)."
           (length failures))))
