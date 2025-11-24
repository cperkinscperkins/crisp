;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/utils.lisp
(defpackage :crisp.utils
  (:use :cl)
  (:export #:let-d))

(in-package :crisp.utils)

(defmacro let-d (bindings &body body)
  "A debugging version of `let*`.

  It behaves exactly like `let*`, but inserts a `(log:debug ...)` statement
  after each variable is bound to log its name and value.

  Example:
    (let-d ((a 10)
            (b (* a 2)))
      b)
  Will log:
    DEBUG: let-d: A => 10
    DEBUG: let-d: B => 20"
  (if (null bindings)
      `(progn ,@body)
      (let ((var (first (first bindings)))
            (val (second (first bindings))))
        `(let ((,var ,val))
           (log:debug "let-d: ~a => ~s" ',var ,var)
           (let-d ,(rest bindings)
             ,@body)))))