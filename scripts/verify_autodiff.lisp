;;;; scripts/verify_autodiff.lisp
;;;;
;;;; Ad-hoc on-metal AD verification for tests/spec/044-autodiff-execution/01-square.crisp.
;;;; Thin wrapper over the reusable runner at tests/verify-autodiff-runner.lisp.
;;;;
;;;; Run with: sbcl --non-interactive --load scripts/verify_autodiff.lisp
;;;;
;;;; For per-spec verification via test directive, see endeavor 103.

(in-package :cl-user)

(load "tests/verify-autodiff-runner.lisp")

(defparameter *spec-dir* "tests/spec/044-autodiff-execution/")
(defparameter *fwd-name* "cell_square")

(defun compile-square-kernels ()
  (format t "~%=== 1. Compiling Crisp Kernels ===~%")
  (uiop:run-program (list "bin/crisp-compile.exe"
                          "--ir-target=spv"
                          (concatenate 'string *spec-dir* "01-square.crisp"))
                    :output t :error-output t)
  (uiop:run-program (list "bin/crisp-compile.exe"
                          "--differentiate" "--ir-target=spv"
                          (concatenate 'string *spec-dir* "01-square.crisp"))
                    :output t :error-output t)
  (format t "Compilation complete.~%"))

(defun main ()
  (compile-square-kernels)
  (format t "~%=== 2. Running verify-autodiff for cell_square ===~%")
  (multiple-value-bind (pass-p analytical numerical diff)
      (verify-autodiff (concatenate 'string *spec-dir* "01-square.spv")
                       (concatenate 'string *spec-dir* "01-square_grad.spv")
                       *fwd-name*
                       :x 3.0
                       :seed-grad 1.0
                       :h 1e-3
                       :atol 1e-2
                       :verbose t)
    (format t "~%=== 3. Result ===~%")
    (format t "   Numerical Gradient (Central Difference): ~a~%" numerical)
    (format t "   Analytical Gradient (Backward kernel):   ~a~%" analytical)
    (format t "   Difference: ~a~%" diff)
    (if pass-p
        (format t "~%~%  VERIFICATION SUCCESSFUL!  The backward kernel computes the correct gradient.~%")
        (error "VERIFICATION FAILED! Output deviation of ~a exceeds tolerance" diff))))

(main)
(uiop:quit 0)
