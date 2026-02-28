;; tests/spec/039-anf-transform/05-set.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.set
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.set)

(define-test anf-set-test
             :parent :crisp.tests)

(define-test (anf-set-test transform-set-var)
             "Variable assignment (set!) with an atomic value passes through unchanged."
             (is equal '(set! x 10) (anf-transform '(set! x 10)))
             (is equal '(set! my-var y) (anf-transform '(set! my-var y))))

(define-test (anf-set-test transform-set-var-complex)
             "Variable assignment with a complex value hoists the value."
             (is equal '(let ((t-1 (+ a b))) (set! x t-1))
                 (anf-transform '(set! x (+ a b))))
             (is equal '(let ((t-1 (foo y))) (set! x t-1))
                 (anf-transform '(set! x (foo y)))))

(define-test (anf-set-test transform-set-accessor)
             "Accessor assignment with an atomic value and flat parent passes through."
             (is equal '(set! (~ c) 42) (anf-transform '(set! (~ c) 42)))
             (is equal '(set! (x~ p) v) (anf-transform '(set! (x~ p) v))))

(define-test (anf-set-test transform-set-accessor-complex-value)
             "Accessor assignment with a complex value hoists the value."
             (is equal '(let ((t-1 (* 2 n))) (set! (~ c) t-1))
                 (anf-transform '(set! (~ c) (* 2 n))))
             (is equal '(let ((t-1 (get-val))) (set! (x~ p) t-1))
                 (anf-transform '(set! (x~ p) (get-val)))))

(define-test (anf-set-test transform-set-nested-accessor-atomic-value)
             "Accessor assignment with a complex parent hoists the parent."
             (is equal '(let ((t-1 (get-cell))) (set! (~ t-1) 10))
                 (anf-transform '(set! (~ (get-cell)) 10)))
             (is equal '(let ((t-1 (make-point))) (set! (y~ t-1) 0))
                 (anf-transform '(set! (y~ (make-point)) 0))))

(define-test (anf-set-test transform-set-nested-accessor-complex-value)
             "Accessor assignment with a complex parent AND complex value hoists both left-to-right."
             (is equal '(let ((t-1 (get-cell)) (t-2 (* x y))) (set! (~ t-1) t-2))
                 (anf-transform '(set! (~ (get-cell)) (* x y)))))
