;; tests/spec/039-anf-transform/08-let.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.let
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.let)

(define-test anf-let-test
             :parent :crisp.tests)

(define-test (anf-let-test transform-let-simple)
             "Let forms with flat bindings and flat bodies pass through unchanged."
             (is equal '(let ((x (+ a b)) (y (* x c))) (foo y))
                 (anf-transform '(let ((x (+ a b)) (y (* x c))) (foo y)))))

(define-test (anf-let-test transform-let-complex-bindings)
             "Let forms where the binding value is heavily nested hoists the inner expressions."
             (is equal '(let ((t-1 (* y z)) (x (+ w t-1))) (foo x))
                 (anf-transform '(let ((x (+ w (* y z)))) (foo x)))))

(define-test (anf-let-test transform-let-complex-body)
             "Let forms with complex bodies have their bodies ANF transformed."
             (is equal '(let ((x 10)) (let ((t-1 (+ x x))) (* t-1 2)))
                 (anf-transform '(let ((x 10)) (* (+ x x) 2)))))

(define-test (anf-let-test transform-let-multivalue)
             "Multi-value let bindings support ANF."
             (is equal '(let ((t-1 (+ a b)) (q r (foo t-1))) (+ q r))
                 (anf-transform '(let ((q r (foo (+ a b)))) (+ q r)))))
