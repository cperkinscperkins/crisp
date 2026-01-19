(in-package :cl-user)

(defpackage :crisp.hoist.l0
  (:documentation "Level Zero hoisting tool - generates C++ launcher code")
  (:use :common-lisp :crisp.hoist)
  (:export #:main))
