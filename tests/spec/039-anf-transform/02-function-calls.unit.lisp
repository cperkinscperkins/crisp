;; tests/spec/039-anf-transform/02-function-calls.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.function-calls
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.function-calls)

(define-test anf-flat-calls-test
             :parent :crisp.tests)

(define-test (anf-flat-calls-test transform-flat-math)
             "Flat mathematical operations with atomic arguments pass through unchanged."
             (is equal '(+ a b) (anf-transform '(+ a b)))
             (is equal '(- x 1) (anf-transform '(- x 1)))
             (is equal '(* 2 3) (anf-transform '(* 2 3)))
             (is equal '(/ a b) (anf-transform '(/ a b))))

(define-test (anf-flat-calls-test transform-flat-function-call)
             "Calls to standard functions with atomic arguments pass through unchanged."
             (is equal '(foo a b c) (anf-transform '(foo a b c)))
             (is equal '(foo a b c d) (anf-transform '(foo a b c d)))
             (is equal '(foo a b c d e) (anf-transform '(foo a b c d e)))
             (is equal '(bar 42) (anf-transform '(bar 42)))
             (is equal '(baz) (anf-transform '(baz))))

(define-test (anf-flat-calls-test transform-bitwise-ops)
             "Hardware bitwise operations with atomic arguments pass through unchanged."
             (is equal '(op-popcount x) (anf-transform '(op-popcount x)))
             (is equal '(op-find-msb y) (anf-transform '(op-find-msb y))))
