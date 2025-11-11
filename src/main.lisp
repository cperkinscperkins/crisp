;; src/main.lisp

;; This defines the package name from the :entry-point
(defpackage :crisp.main
  (:use :cl)
  (:export :main))

(in-package :crisp.main)

;; This defines the function from the :entry-point
(defun main ()
  (format t "Hello, Crisp Compiler v0.0.1!~%"))