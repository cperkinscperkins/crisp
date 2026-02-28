;; tests/spec/039-anf-transform/06-control-flow-basic.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.anf.control-flow-basic
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:anf-transform))

(in-package :crisp.test.anf.control-flow-basic)

(define-test anf-control-flow-basic-test
             :parent :crisp.tests)

(define-test (anf-control-flow-basic-test transform-if-atomic-condition)
             "If forms with atomic conditions pass through, but branches are recursively ANF transformed."
             (is equal '(if cond-var (let ((t-1 (+ a b))) t-1) (let ((t-2 (- c d))) t-2))
                 (anf-transform '(if cond-var (+ a b) (- c d))))
             (is equal '(if T 1 2)
                 (anf-transform '(if T 1 2))))

(define-test (anf-control-flow-basic-test transform-if-complex-condition)
             "If forms with complex conditions hoist the condition, branches are recursively ANF'd."
             (is equal '(let ((t-1 (> x 10))) (if t-1 (let ((t-2 (* x 2))) t-2) x))
                 (anf-transform '(if (> x 10) (* x 2) x))))

(define-test (anf-control-flow-basic-test transform-if-in-call)
             "If the IF form is an argument to a call, its entire result is hoisted."
             (is equal '(let ((t-1 (if flag (let ((t-2 (+ a 1))) t-2) (let ((t-3 (- b 1))) t-3)))) (* 10 t-1))
                 (anf-transform '(* 10 (if flag (+ a 1) (- b 1))))))

(define-test (anf-control-flow-basic-test transform-when-unless)
             "When and unless forms hoist conditions identically to if. Only the true/false branch exists."
             (is equal '(when flag (let ((t-1 (foo x))) t-1))
                 (anf-transform '(when flag (foo x))))
             (is equal '(let ((t-1 (is-valid? data))) (unless t-1 (let ((t-2 (bail))) t-2)))
                 (anf-transform '(unless (is-valid? data) (bail)))))

(define-test (anf-control-flow-basic-test transform-compile-time-variants)
             "Compile time variants (if+, when+, unless+) are handled exactly like their runtime counterparts."
             (is equal '(let ((t-1 (> N 0))) (if+ t-1 1 0))
                 (anf-transform '(if+ (> N 0) 1 0)))
             (is equal '(let ((t-1 (is-set? opt-arg))) (when+ t-1 (let ((t-2 (do-thing))) t-2)))
                 (anf-transform '(when+ (is-set? opt-arg) (do-thing)))))
