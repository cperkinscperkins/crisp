(in-package :cl-user)

(defpackage :crisp.hoist.cuda
  (:documentation "CUDA hoisting tool - generates C++ launcher code using CUDA Driver API")
  (:use :common-lisp :crisp.hoist)
  (:export #:main))
