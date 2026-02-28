;; tests/spec/039-anf-transform/07-control-flow-cond.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-control-flow-cond-test
                       :parent :crisp.tests)

(parachute:define-test (anf-control-flow-cond-test transform-cond-atomic-predicates)
                       "Cond forms with atomic predicates pass the predicates through. Bodies are ANF'd."
                       (parachute:is equal '(cond (a (let ((t-1 (foo x))) t-1)) (b (let ((t-2 (bar y))) t-2)) (else 0))
                                     (anf-transform '(cond (a (foo x)) (b (bar y)) (else 0)))))

(parachute:define-test (anf-control-flow-cond-test transform-cond-complex-predicates)
                       "Cond forms with complex predicates ANF the predicate *inside* the clause list so it only evaluates if reached."
                       (parachute:is equal '(cond ((let ((t-1 (> x 10))) t-1) x)
                                                  (else (let ((t-2 (* x 2))) t-2)))
                                     (anf-transform '(cond ((> x 10) x) (else (* x 2))))))

(parachute:define-test (anf-control-flow-cond-test transform-cond-in-call)
                       "Cond form inside a call has its entire result hoisted."
                       (parachute:is equal '(let ((t-1 (cond (flag 1) (else 0)))) (+ 10 t-1))
                                     (anf-transform '(+ 10 (cond (flag 1) (else 0))))))
