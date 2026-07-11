;; Endeavor 135 — matrix-multiply-tile-stride: front-end wiring unit test.
;;
;; GPU-free proof that the macro expands and reaches codegen end-to-end: compile the
;; envelope smoke kernel (01) on the generic default pass and confirm (a) it produces a
;; non-empty IR string and (b) the kernel is registered.  The deeper "it's just sugar"
;; equivalence is proved on metal by the MMA twins (03 CUDA / 04 BMG) producing
;; MMA_CORRECT against the same host reference the hand-rolled 132/06 & 133/12 use.
(in-package :cl-user)

(defpackage :crisp.test.matrix-multiply-tile-stride
  (:use :cl :parachute))

(in-package :crisp.test.matrix-multiply-tile-stride)

(define-test matrix-multiply-tile-stride
  (let ((file "tests/spec/135-matrix-multiply-tile-stride/01-macro-envelope.crisp"))
    ;; Clean state, then compile the envelope kernel (generic target).
    (setf crisp.compiler::*function-table* (make-hash-table))
    (let ((ir (crisp.spec-runner::compile-crisp-file-to-ir-string file)))
      (true (and (stringp ir) (plusp (length ir)))
            "matrix-multiply-tile-stride envelope kernel should compile to IR.")
      ;; compile-crisp-file-to-ir-string reads source in :crisp-language, so the kernel
      ;; name interns there (matching the binary compiler).
      (let* ((sigs (gethash (intern "MM_ENVELOPE" :crisp-language)
                            crisp.compiler::*function-table*))
             (kernel-func (first sigs)))
        (true kernel-func "Kernel 'mm_envelope' should be registered after expansion.")))))

(test 'matrix-multiply-tile-stride)
