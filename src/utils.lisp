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

(defun advise-function (fn-symbol)
  "Replaces a function's definition with a logging wrapper.
  The wrapper logs arguments on entry and return values on exit.
  It correctly handles multiple return values."
  (let ((original-fn (symbol-function fn-symbol)))
    ;; Avoid advising a function more than once.
    (when (get fn-symbol :advised)
      (log:warn "Function ~s is already advised. Skipping." fn-symbol)
      (return-from advise-function))

    (setf (symbol-function fn-symbol)
          (lambda (&rest args)
            (log:debug "-> Entering ~s with args: ~s" fn-symbol args)
            (let ((return-vals (multiple-value-list (apply original-fn args))))
              (log:debug "<- Exiting ~s with return: ~s" fn-symbol return-vals)
              (values-list return-vals))))
    (setf (get fn-symbol :advised) t)))

(defun initialize-advisements ()
  "Advises a hard-coded list of functions for debugging purposes."
  (let ((functions-to-advise
          ;; Add function symbols here, e.g., 'crisp.compiler::analyze-expression
          '( crisp.compiler::analyze-signatures-pass))) 
          ;'( )))
    (dolist (fn-sym functions-to-advise)
      (advise-function fn-sym))))