;; tests/spec/039-anf-transform/03-nested-calls.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-nested-calls-test
                       :parent :crisp.tests)

(parachute:define-test (anf-nested-calls-test transform-nested-math)
                       "Nested mathematical operations are hoisted into sequential let bindings."
                       (parachute:is equal '(let ((t-1 (+ a b)) (t-2 (- c d))) (* t-1 t-2))
                                     (anf-transform '(* (+ a b) (- c d))))
                       (parachute:is equal '(let ((t-1 (* y z))) (+ x t-1))
                                     (anf-transform '(+ x (* y z))))
                       (parachute:is equal '(let ((t-1 (- a b)) (t-2 (/ t-1 c)) (t-3 (* t-2 d))) (+ t-3 e))
                                     (anf-transform '(+ (* (/ (- a b) c) d) e))))

(parachute:define-test (anf-nested-calls-test transform-nested-functions)
                       "Nested function calls are hoisted."
                       (parachute:is equal '(let ((t-1 (bar x))) (foo t-1 y))
                                     (anf-transform '(foo (bar x) y)))
                       (parachute:is equal '(let ((t-1 (baz z)) (t-2 (bar t-1))) (foo x t-2))
                                     (anf-transform '(foo x (bar (baz z))))))
