;; tests/spec/039-anf-transform/01-atoms.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.atoms
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.atoms)

(define-test anf-atoms-test
             :parent :crisp.tests)

(define-test (anf-atoms-test transform-number-literal)
             "Number literals should pass through ANF unchanged."
             (is equal '42 (anf-transform '42))
             (is equal '3.14 (anf-transform '3.14)))

(define-test (anf-atoms-test transform-boolean-literal)
             "Boolean literals should pass through ANF unchanged."
             (is equal 'NIL (anf-transform 'NIL))
             (is equal 'T (anf-transform 'T)))

(define-test (anf-atoms-test transform-keyword)
             "Keywords should pass through ANF unchanged."
             (is equal ':foo (anf-transform ':foo)))

(define-test (anf-atoms-test transform-symbol)
             "Symbols (variables) should pass through ANF unchanged."
             (is equal 'x (anf-transform 'x))
             (is equal 'my-var (anf-transform 'my-var)))

#|
temporarily disabled.
We need to get first order functions (#'+) included in the ANF transform test coverage
but planning to do so later.  This serves as a reminder for now.

(define-test (anf-atoms-test transform-function-ref)
             "Function references should pass through ANF unchanged."
             (is equal '(function +) (anf-transform '(function +))))
|#
