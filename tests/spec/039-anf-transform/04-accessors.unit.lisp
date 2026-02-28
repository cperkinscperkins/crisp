;; tests/spec/039-anf-transform/04-accessors.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-accessors-test
                       :parent :crisp.tests)

(parachute:define-test (anf-accessors-test transform-flat-accessors)
                       "Accessors with an atomic parent pass through unchanged."
                       (parachute:is equal '(~ c) (anf-transform '(~ c)))
                       (parachute:is equal '(x~ p) (anf-transform '(x~ p)))
                       (parachute:is equal '(length~ v) (anf-transform '(length~ v)))
                       (parachute:is equal '(~ref~ t) (anf-transform '(~ref~ t))))

(parachute:define-test (anf-accessors-test transform-nested-accessors)
                       "Accessors whose parent is a complex expression hoist the parent."
                       (parachute:is equal '(let ((t-1 (get-cell))) (~ t-1))
                                     (anf-transform '(~ (get-cell))))
                       (parachute:is equal '(let ((t-1 (get-point))) (x~ t-1))
                                     (anf-transform '(x~ (get-point))))
                       (parachute:is equal '(let ((t-1 (get-vector))) (length~ t-1))
                                     (anf-transform '(length~ (get-vector)))))

(parachute:define-test (anf-accessors-test transform-accessors-in-call)
                       "Accessors are treated as complex expressions themselves if they need to be atomic arguments to other calls."
                       (parachute:is equal '(let ((t-1 (~ c))) (+ t-1 5))
                                     (anf-transform '(+ (~ c) 5)))
                       (parachute:is equal '(let ((t-1 (x~ p)) (t-2 (y~ p))) (+ t-1 t-2))
                                     (anf-transform '(+ (x~ p) (y~ p)))))

(parachute:define-test (anf-accessors-test transform-nested-accessors-in-call)
                       "Deeply nested accessors in a call hoist everything in sequence."
                       (parachute:is equal '(let ((t-1 (get-point)) (t-2 (x~ t-1))) (+ 10 t-2))
                                     (anf-transform '(+ 10 (x~ (get-point))))))
