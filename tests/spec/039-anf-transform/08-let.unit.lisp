;; tests/spec/039-anf-transform/08-let.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-let-test
                       :parent :crisp.tests)

(parachute:define-test (anf-let-test transform-let-simple)
                       "Let forms with flat bindings and flat bodies pass through unchanged."
                       (parachute:is equal '(let ((x (+ a b)) (y (* x c))) (foo y))
                                     (anf-transform '(let ((x (+ a b)) (y (* x c))) (foo y)))))

(parachute:define-test (anf-let-test transform-let-complex-bindings)
                       "Let forms where the binding value is heavily nested hoists the inner expressions."
                       (parachute:is equal '(let ((t-1 (* y z)) (x (+ w t-1))) (foo x))
                                     (anf-transform '(let ((x (+ w (* y z)))) (foo x)))))

(parachute:define-test (anf-let-test transform-let-complex-body)
                       "Let forms with complex bodies have their bodies ANF transformed."
                       (parachute:is equal '(let ((x 10) (t-1 (+ x x))) (* t-1 2))
                                     (anf-transform '(let ((x 10)) (* (+ x x) 2)))))

(parachute:define-test (anf-let-test transform-let-multivalue)
                       "Multi-value let bindings support ANF."
                       (parachute:is equal '(let ((t-1 (+ a b)) (q r (foo t-1))) (+ q r))
                                     (anf-transform '(let ((q r (foo (+ a b)))) (+ q r)))))
