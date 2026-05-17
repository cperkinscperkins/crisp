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
  (multiple-value-bind (pass-p results)
      (verify-autodiff (concatenate 'string *spec-dir* "01-square.spv")
                       (concatenate 'string *spec-dir* "01-square_grad.spv")
                       *fwd-name*
                       :inputs '(("x" . 3.0))
                       :seed-grad 1.0
                       :h 1e-3
                       :atol 1e-2
                       :verbose t)
    (format t "~%=== 3. Result ===~%")
    (dolist (r results)
      (format t "   ~A: analytical=~a numerical=~a diff=~a~%"
              (getf r :name)
              (getf r :analytical)
              (getf r :numerical)
              (getf r :diff)))
    (if pass-p
        (format t "~%~%  VERIFICATION SUCCESSFUL!  The backward kernel computes the correct gradient.~%")
        (error "VERIFICATION FAILED! See per-input differences above."))))

(main)
(uiop:quit 0)
