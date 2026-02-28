;; tests/spec/039-anf-transform/01-atoms.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test anf-atoms-test
                       :parent :crisp.tests)

(parachute:define-test (anf-atoms-test transform-number)
                       "Number literals should pass through ANF unchanged."
                       (parachute:is equal 42 (anf-transform 42))
                       (parachute:is equal 3.14 (anf-transform 3.14)))

(parachute:define-test (anf-atoms-test transform-boolean)
                       "Boolean literals should pass through ANF unchanged."
                       (parachute:is equal 'NIL (anf-transform 'NIL))
                       (parachute:is equal 'T (anf-transform 'T)))

(parachute:define-test (anf-atoms-test transform-keyword)
                       "Keywords should pass through ANF unchanged."
                       (parachute:is equal :foo (anf-transform :foo))
                       (parachute:is equal :anf-target (anf-transform :anf-target)))

(parachute:define-test (anf-atoms-test transform-symbol)
                       "Symbols (variables) should pass through ANF unchanged."
                       (parachute:is equal 'x (anf-transform 'x))
                       (parachute:is equal 'my-var (anf-transform 'my-var)))

#|
temporarily disabled.
We need to get first order functions (#'+) included in the ANF transform test coverage
but planning to do so later.  This serves as a reminder for now.

(parachute:define-test (anf-atoms-test transform-function-ref)
  "Function references should pass through ANF unchanged."
  (parachute:is equal '(function +) (anf-transform '(function +))))
|#
