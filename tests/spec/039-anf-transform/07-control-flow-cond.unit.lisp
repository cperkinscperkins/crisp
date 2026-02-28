;; tests/spec/039-anf-transform/07-control-flow-cond.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.control-flow-cond
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.control-flow-cond)

(define-test anf-control-flow-cond-test
             :parent :crisp.tests)

(define-test (anf-control-flow-cond-test transform-cond-atomic-predicates)
             "Cond forms with atomic predicates pass the predicates through. Bodies are ANF'd."
             (is equal '(cond (a (let ((t-1 (foo x))) t-1)) (b (let ((t-2 (bar y))) t-2)) (else 0))
                 (anf-transform '(cond (a (foo x)) (b (bar y)) (else 0)))))

(define-test (anf-control-flow-cond-test transform-cond-complex-predicates)
             "Cond forms with complex predicates ANF the predicate *inside* the clause list so it only evaluates if reached."
             ;; Note: hoisting a condition OUT of the cond entirely would break short-circuiting.
             ;; The predicate must be ANF'd locally within the predicate position if supported by the AST,
             ;; or the `cond` must be macroexpanded into nested `if` forms.
             ;; Here we expect the predicate to be hoisted into a let *within* the clause predicate position.
             (is equal '(cond ((let ((t-1 (> x 10))) t-1) x)
                              (else (let ((t-2 (* x 2))) t-2)))
                 (anf-transform '(cond ((> x 10) x) (else (* x 2))))))

(define-test (anf-control-flow-cond-test transform-cond-in-call)
             "Cond form inside a call has its entire result hoisted."
             (is equal '(let ((t-1 (cond (flag 1) (else 0)))) (+ 10 t-1))
                 (anf-transform '(+ 10 (cond (flag 1) (else 0))))))
