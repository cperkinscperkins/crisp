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

;;; ADV-007 (adversarial, 2026-10-12): Crisp has one equality, =.  The unsupported-form error names the
;;; Crisp spelling for the Common Lisp forms an author (or an agent) is most likely to reach for.
(defparameter *unsupported-form-hints*
  '(("EQ" . "compare values, including enum keywords, with =")
    ("EQL" . "compare values, including enum keywords, with =")
    ("EQUAL" . "compare values, including enum keywords, with =")
    ("EQUALP" . "compare values, including enum keywords, with =")
    ("/=" . "not-equal is !=")
    ("SETF" . "assign with set!, e.g. (set! x v) or (set! (~ v i) x)")
    ("SETQ" . "assign with set!")
    ("AREF" . "index a storage handle with ~, e.g. (~ v i)")
    ("DEFUN" . "define functions at top level with def-function")
    ("LET*" . "Crisp's let is already sequential; use let")
    ("PROGN" . "a function or let body is already a sequence of forms")
    ("INCF" . "write (set! x (+ x 1))")
    ("DECF" . "write (set! x (- x 1))")
    ("DOLIST" . "loop with dotimes or one of the stride macros")
    ("LOOP" . "loop with dotimes or one of the stride macros")
    ("WHILE" . "every Crisp loop is bounded, so kernels always terminate -- loop with dotimes or one of the stride macros, and leave early with return-from-loop"))
  "Common Lisp operator name -> what to write in Crisp instead.  Appended to the
   unsupported-form error (ADV-007).  Endeavour 200: WHILE -- an author never writes an unbounded
   loop; the compiler's own spin (sync-wait) is %while, which no user form names.")

(defun %unsupported-form-hint (form)
  "The Crisp alternative for FORM's operator name, or NIL."
  (let ((name (cond ((symbolp form) (symbol-name form))
                    ((and (consp form) (symbolp (car form))) (symbol-name (car form))))))
    (and name (cdr (assoc name *unsupported-form-hints* :test #'string-equal)))))

(define-condition crisp-unsupported-form-error (crisp-compiler-error)
    ((form :initarg :form :reader unsupported-form))
  (:report (lambda (condition stream)
             (format stream "Unsupported form '~a' found in function body."
               (unsupported-form condition))
             (let ((hint (%unsupported-form-hint (unsupported-form condition))))
               (when hint (format stream "  Crisp has no ~a: ~a." (unsupported-form condition) hint))))))

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

(define-condition crisp-incomplete-type-error (crisp-compiler-error)
    ((type-spec :initarg :type-spec :reader incomplete-type-spec))
  (:report (lambda (condition stream)
             (format stream "Invalid incomplete type specifier: ~a." (incomplete-type-spec condition)))))
