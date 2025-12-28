;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)

;; Errors
;; ======

(define-condition crisp-compiler-error (error)
    ((source-location :initarg :source-location :reader error-source-location
                      :initform nil)
     (message :initarg :message :reader error-message :initform nil))
  (:report (lambda (condition stream)
             (if (error-message condition)
                 (format stream "~a~@[ at ~a~]." (error-message condition) (error-source-location condition))
                 (format stream "A Crisp compilation error occurred~@[ at ~a~]."
                   (error-source-location condition))))))

(define-condition crisp-type-error (crisp-compiler-error)
    ((message :initarg :message :initform "Type mismatch!" :reader type-error-message)
     (expected :initarg :expected :reader type-error-expected :initform nil)
     (inferred :initarg :inferred :reader type-error-inferred :initform nil))
  (:report (lambda (condition stream)
             ;; If we have specific expected/inferred types, use the standard format.
             ;; Otherwise, just print the message.
             (if (or (type-error-expected condition)
                     (type-error-inferred condition))
                 (format stream "~a Expected ~a but inferred ~a."
                   (type-error-message condition)
                   (type-error-expected condition)
                   (type-error-inferred condition))
                 (format stream "~a" (type-error-message condition))))))

(define-condition crisp-unknown-type-error (crisp-compiler-error)
    ((type-name :initarg :type-name :reader unknown-type-name))
  (:report (lambda (condition stream)
             (format stream "Unknown type '~a'." (unknown-type-name condition)))))

(define-condition crisp-call-type-error (crisp-compiler-error)
    ((message :initarg :message :reader type-error-message)
     (expected :initarg :expected :reader type-error-expected)
     (inferred :initarg :inferred :reader type-error-inferred))
  (:report (lambda (condition stream)
             (format stream "Expected ~a but got ~a."
               (type-error-expected condition)
               (type-error-inferred condition)))))

(define-condition crisp-unexpected-eof-error (crisp-compiler-error)
    ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "Unexpected end of file. This usually means a parenthesis or quote is missing."))))

(define-condition crisp-signature-arity-error (crisp-compiler-error)
    ((expected :initarg :expected :reader arity-error-expected)
     (inferred :initarg :inferred :reader arity-error-inferred))
  (:report (lambda (condition stream)
             (format stream "Arity mismatch! Function param list has ~a arguments but type signature declared ~a."
               (arity-error-inferred condition)
               (arity-error-expected condition)))))

(define-condition crisp-unsupported-form-error (crisp-compiler-error)
    ((form :initarg :form :reader unsupported-form))
  (:report (lambda (condition stream)
             (format stream "Unsupported form '~a' found in function body."
               (unsupported-form condition)))))

(define-condition crisp-recursion-error (crisp-compiler-error)
    ((form :initarg :form :reader recursive-form))
  (:report (lambda (condition stream)
             (format stream "Recursion is not allowed. Call to '~a' is recursive." (recursive-form condition)))))

(define-condition crisp-unknown-variable (crisp-compiler-error)
    ((name :initarg :name :reader unknown-variable-name))
  (:report (lambda (condition stream)
             (format stream "Unknown variable ~a."
               (unknown-variable-name condition)))))

(define-condition crisp-illegal-overload-error (crisp-compiler-error)
    ((name :initarg :name :reader overload-error-name))
  (:report (lambda (condition stream)
             (format stream "Overloading ~a is not allowed."
               (overload-error-name condition)))))

(define-condition crisp-illegal-access-error (crisp-compiler-error)
    ()
  (:report (lambda (condition stream)
             (format stream "Illegal access: ~a~@[ (Location: ~a)~]"
               (error-message condition)
               (error-source-location condition)))))
