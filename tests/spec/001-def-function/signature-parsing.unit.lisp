;; tests/spec/001-def-function/signature-parsing.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.signature-parsing
  (:use :cl :parachute)
  (:shadowing-import-from :crisp.compiler #:float)
  (:import-from :crisp.compiler
                #:parse-function-declarations
                #:make-parameter-def
                #:int))

(in-package :crisp.test.signature-parsing)

(define-test signature-parsing)

(define-test (signature-parsing parse-basic-arrow)
             "Test #'(int crisp.compiler::float => crisp.compiler::int) syntax"
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(a b)
                                                              '((crisp.compiler::function (int crisp.compiler::float => crisp.compiler::int))))
               (is equalp (list (make-parameter-def :name 'a :type 'int :kind :in)
                                (make-parameter-def :name 'b :type 'float :kind :in))
                   env)
               (is equal '(int) return-types)))

(define-test (signature-parsing parse-multiple-returns)
             "Test multiple return types"
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(a b)
                                                              '((crisp.compiler::function (int crisp.compiler::int => crisp.compiler::int crisp.compiler::int))))
               (is = 2 (length env))
               (is equal '(int crisp.compiler::int) return-types)))

(define-test (signature-parsing parse-void)
             "Test void return (no => clause)"
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(a b)
                                                              '((crisp.compiler::function (int crisp.compiler::int))))
               (is = 2 (length env))
               (is equal '(nil) return-types)))

(define-test (signature-parsing parse-with-optional)
             "Test &optional parameters"
             (multiple-value-bind (env return-types optional-idx)
                 (crisp.compiler::parse-function-declarations '(a b &optional c d)
                                                              '((crisp.compiler::function (int crisp.compiler::int crisp.compiler::int crisp.compiler::int => crisp.compiler::int))))
               (is = 4 (length env))
               (is = 2 optional-idx)
               (is equal '(int) return-types)))

;; Run tests - will error if any fail
(test 'signature-parsing)
