;; tests/spec/039-anf-transform/03-nested-calls.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-nested-calls-test
                       :parent :crisp.tests)

(parachute:define-test (anf-nested-calls-test transform-nested-math)
                       "Nested mathematical operations are hoisted into sequential let bindings."
                       (parachute:is equal '(let ((%anf-t-1 (+ a b)) (%anf-t-2 (- c d))) (* %anf-t-1 %anf-t-2))
                                     (anf-transform '(* (+ a b) (- c d))))
                       (parachute:is equal '(let ((%anf-t-1 (* y z))) (+ x %anf-t-1))
                                     (anf-transform '(+ x (* y z))))
                       (parachute:is equal '(let ((%anf-t-1 (- a b)) (%anf-t-2 (/ %anf-t-1 c)) (%anf-t-3 (* %anf-t-2 d))) (+ %anf-t-3 e))
                                     (anf-transform '(+ (* (/ (- a b) c) d) e))))

(parachute:define-test (anf-nested-calls-test transform-nested-functions)
                       "Nested function calls are hoisted."
                       (parachute:is equal '(let ((%anf-t-1 (bar x))) (foo %anf-t-1 y))
                                     (anf-transform '(foo (bar x) y)))
                       (parachute:is equal '(let ((%anf-t-1 (baz z)) (%anf-t-2 (bar %anf-t-1))) (foo x %anf-t-2))
                                     (anf-transform '(foo x (bar (baz z))))))
