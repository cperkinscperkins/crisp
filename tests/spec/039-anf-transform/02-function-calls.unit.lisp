;; tests/spec/039-anf-transform/02-function-calls.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-flat-calls-test
                       :parent :crisp.tests)

(parachute:define-test (anf-flat-calls-test transform-flat-math)
                       "Flat mathematical operations with atomic arguments pass through unchanged."
                       (parachute:is equal '(+ a b) (anf-transform '(+ a b)))
                       (parachute:is equal '(- x 1) (anf-transform '(- x 1)))
                       (parachute:is equal '(* 2 3) (anf-transform '(* 2 3)))
                       (parachute:is equal '(/ a b) (anf-transform '(/ a b))))

(parachute:define-test (anf-flat-calls-test transform-flat-function-call)
                       "Calls to standard functions with atomic arguments pass through unchanged."
                       (parachute:is equal '(foo a b c) (anf-transform '(foo a b c)))
                       (parachute:is equal '(foo a b c d) (anf-transform '(foo a b c d)))
                       (parachute:is equal '(foo a b c d e) (anf-transform '(foo a b c d e)))
                       (parachute:is equal '(bar 42) (anf-transform '(bar 42)))
                       (parachute:is equal '(baz) (anf-transform '(baz))))

(parachute:define-test (anf-flat-calls-test transform-bitwise-ops)
                       "Hardware bitwise operations with atomic arguments pass through unchanged."
                       (parachute:is equal '(op-popcount x) (anf-transform '(op-popcount x)))
                       (parachute:is equal '(op-find-msb y) (anf-transform '(op-find-msb y))))
