;; tests/spec/039-anf-transform/09-misc.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.misc
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.misc)

(define-test anf-misc-test
             :parent :crisp.tests)

(define-test (anf-misc-test transform-declare)
             "Declare forms are completely ignored by ANF."
             (is equal '(declare (type x int))
                 (anf-transform '(declare (type x int))))
             (is equal '(declare #'(int => int))
                 (anf-transform '(declare #'(int => int)))))

(define-test (anf-misc-test transform-return)
             "Return forms normalize their argument to an atom."
             (is equal '(return x) (anf-transform '(return x)))
             (is equal '(let ((t-1 (+ a b))) (return t-1))
                 (anf-transform '(return (+ a b)))))

(define-test (anf-misc-test transform-progn)
             "Progn forms (mostly found implicitly in bodies) ANF each form sequentially."
             (is equal '(progn (let ((t-1 (foo x))) t-1) (let ((t-2 (* y 2))) t-2))
                 (anf-transform '(progn (foo x) (* y 2)))))

(define-test (anf-misc-test transform-bounded-loops)
             "Bounded loops (dotimes) hoist their bound and step, and recursively ANF their body."
             (is equal '(let ((t-1 (+ n 1))) (dotimes (i t-1) (let ((t-2 (* i 2))) (foo t-2))))
                 (anf-transform '(dotimes (i (+ n 1)) (foo (* i 2))))))
