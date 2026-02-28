;; tests/spec/039-anf-transform/04-accessors.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.accessors
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.accessors)

(define-test anf-accessors-test
             :parent :crisp.tests)

(define-test (anf-accessors-test transform-flat-accessors)
             "Accessors with an atomic parent pass through unchanged."
             (is equal '(~ c) (anf-transform '(~ c)))
             (is equal '(x~ p) (anf-transform '(x~ p)))
             (is equal '(length~ v) (anf-transform '(length~ v)))
             (is equal '(~ref~ t) (anf-transform '(~ref~ t))))

(define-test (anf-accessors-test transform-nested-accessors)
             "Accessors whose parent is a complex expression hoist the parent."
             (is equal '(let ((t-1 (get-cell))) (~ t-1))
                 (anf-transform '(~ (get-cell))))
             (is equal '(let ((t-1 (get-point))) (x~ t-1))
                 (anf-transform '(x~ (get-point))))
             (is equal '(let ((t-1 (get-vector))) (length~ t-1))
                 (anf-transform '(length~ (get-vector)))))

(define-test (anf-accessors-test transform-accessors-in-call)
             "Accessors are treated as complex expressions themselves if they need to be atomic arguments to other calls."
             (is equal '(let ((t-1 (~ c))) (+ t-1 5))
                 (anf-transform '(+ (~ c) 5)))
             (is equal '(let ((t-1 (x~ p)) (t-2 (y~ p))) (+ t-1 t-2))
                 (anf-transform '(+ (x~ p) (y~ p)))))

(define-test (anf-accessors-test transform-nested-accessors-in-call)
             "Deeply nested accessors in a call hoist everything in sequence."
             (is equal '(let ((t-1 (get-point)) (t-2 (x~ t-1))) (+ 10 t-2))
                 (anf-transform '(+ 10 (x~ (get-point))))))
