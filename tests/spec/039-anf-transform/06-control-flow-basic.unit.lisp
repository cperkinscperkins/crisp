;; tests/spec/039-anf-transform/06-control-flow-basic.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-control-flow-basic-test
                       :parent :crisp.tests)

(parachute:define-test (anf-control-flow-basic-test transform-if-atomic-condition)
                       "If forms with atomic conditions pass through, but branches are recursively ANF transformed."
                       (parachute:is equal '(if cond-var (+ a b) (- c d))
                                     (anf-transform '(if cond-var (+ a b) (- c d))))
                       (parachute:is equal '(if T 1 2)
                                     (anf-transform '(if T 1 2))))

(parachute:define-test (anf-control-flow-basic-test transform-if-complex-condition)
                       "If forms with complex conditions hoist the condition, branches are recursively ANF'd."
                       (parachute:is equal '(let ((%anf-t-1 (> x 10))) (if %anf-t-1 (* x 2) x))
                                     (anf-transform '(if (> x 10) (* x 2) x))))

(parachute:define-test (anf-control-flow-basic-test transform-if-in-call)
                       "If the IF form is an argument to a call, its entire result is hoisted."
                       (parachute:is equal '(let ((%anf-t-1 (if flag (+ a 1) (- b 1)))) (* 10 %anf-t-1))
                                     (anf-transform '(* 10 (if flag (+ a 1) (- b 1))))))

(parachute:define-test (anf-control-flow-basic-test transform-when-unless)
                       "When and unless forms hoist conditions identically to if. Only the true/false branch exists."
                       (parachute:is equal '(when flag (foo x))
                                     (anf-transform '(when flag (foo x))))
                       (parachute:is equal '(let ((%anf-t-1 (is-valid? data))) (unless %anf-t-1 (bail)))
                                     (anf-transform '(unless (is-valid? data) (bail)))))

(parachute:define-test (anf-control-flow-basic-test transform-compile-time-variants)
                       "Compile time variants (if+, when+, unless+) are handled exactly like their runtime counterparts, EXCEPT their conditions are completely untouched by ANF."
                       (parachute:is equal '(if+ (> N 0) 1 0)
                                     (anf-transform '(if+ (> N 0) 1 0)))
                       (parachute:is equal '(when+ (is-set? opt-arg) (do-thing))
                                     (anf-transform '(when+ (is-set? opt-arg) (do-thing)))))
