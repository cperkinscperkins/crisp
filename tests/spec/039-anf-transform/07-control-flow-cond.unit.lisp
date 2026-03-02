;; tests/spec/039-anf-transform/07-control-flow-cond.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-control-flow-cond-test
                       :parent :crisp.tests)

(parachute:define-test (anf-control-flow-cond-test transform-cond-atomic-predicates)
                       "Cond forms with atomic predicates pass the predicates through. Bodies are ANF'd."
                       (parachute:is equal '(cond (a (foo x)) (b (bar y)) (else 0))
                                     (anf-transform '(cond (a (foo x)) (b (bar y)) (else 0)))))

(parachute:define-test (anf-control-flow-cond-test transform-cond-complex-predicates)
                       "Cond forms with complex predicates ANF the predicate *inside* the clause list so it only evaluates if reached."
                       (parachute:is equal '(cond ((let ((%anf-t-1 (get-val))) (> %anf-t-1 10)) x)
                                                  (else (* x 2)))
                                     (anf-transform '(cond ((> (get-val) 10) x) (else (* x 2))))))

(parachute:define-test (anf-control-flow-cond-test transform-cond-in-call)
                       "Cond form inside a call has its entire result hoisted."
                       (parachute:is equal '(let ((%anf-t-1 (cond (flag 1) (else 0)))) (+ 10 %anf-t-1))
                                     (anf-transform '(+ 10 (cond (flag 1) (else 0))))))
