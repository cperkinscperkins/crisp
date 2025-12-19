(require :uiop)
(load "~/quicklisp/setup.lisp")

;; Silence quickload output
(let ((*standard-output* (make-broadcast-stream)))
  (ql:quickload :cffi)
  (ql:quickload :log4cl)
  (ql:quickload :alexandria))

;; Mock packages if they don't exist to allow reading symbols without error
(unless (find-package :crisp.llvm-bindings)
  (defpackage :crisp.llvm-bindings (:use :cl :cffi)))

(unless (find-package :crisp.compiler)
  (defpackage :crisp.compiler
    (:use :cl :cffi :alexandria :log4cl)))

(unless (find-package :crisp.tests)
  (defpackage :crisp.tests (:use :cl)))

(defun check-syntax (filename)
  (unless (probe-file filename)
    (format t "Error: File '~a' not found.~%" filename)
    (uiop:quit 1))

  (with-open-file (stream filename)
    (let ((*readtable* (copy-readtable nil))
          (*package* (find-package :crisp.compiler)))
      (loop for i from 1
            for pos = (file-position stream)
            for form = (handler-case (read stream nil 'eof)
                         (error (c)
                           (format t "FAIL at form ~a (approx char pos ~a): ~a~%" i pos c)
                           (uiop:quit 1)))
            until (eq form 'eof)
            do (let ((name (if (listp form) (first form) form)))
                 ;; Optional: print progress
                 ;; (format t "Form ~a @ ~a: ~a~%" i pos name)
                 (when (and (listp form) (eq (first form) 'defun))
                       ;; (format t "  DEFUN: ~a~%" (second form))
                       nil)))))
  (format t "Syntax OK: ~a~%" filename))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (if (null args)
        (progn
         (format t "Usage: sbcl --script scripts/check-syntax.lisp <filename>~%")
         (uiop:quit 1))
        (check-syntax (first args)))))

(main)
