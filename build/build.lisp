;; build/build.lisp
(in-package :cl-user)

(require :uiop)

(defun run-build-script (script-name)
  (format t "~%~%;;; ----------------------------------------------------------------------~%")
  (format t ";;; Running: ~a~%" script-name)
  (format t ";;; ----------------------------------------------------------------------~%")
  (uiop:run-program (list "sbcl" "--non-interactive" "--load" script-name)
    :output :interactive
    :error-output :interactive) ; signals error on non-zero exit
  (format t ";;; [DONE] ~a~%" script-name))

(format t ";;; ======================================================================~%")
(format t ";;; CRISP MASTER BUILD~%")
(format t ";;; ======================================================================~%")

(run-build-script "build/build-compiler.lisp")
(run-build-script "build/build-hoist-l0.lisp")
(run-build-script "build/build-hoist-cuda.lisp")

(format t "~%;;; ======================================================================~%")
(format t ";;; ALL BUILDS COMPLETE~%")
(format t ";;; ======================================================================~%")
(uiop:quit 0)
