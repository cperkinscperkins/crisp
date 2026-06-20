(in-package :cl-user)

(defpackage :crisp.test.uniformity-logic
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:analyze-expression
                #:make-compiler-context
                #:calculate-uniformity-state
                #:semantic-node-type
                #:semantic-literal-value
                #:semantic-let-body
                #:crisp-compiler-error))

(in-package :crisp.test.uniformity-logic)

(define-test uniformity-logic)

(define-test (uniformity-logic literals-are-uniform)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression 1 env ctx nil))
         (state (calculate-uniformity-state expr env)))
    (is eq :uniform state)))

(define-test (uniformity-logic get-workgroup-id-is-uniform)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(get-workgroup-id 0) env ctx nil))
         (state (calculate-uniformity-state expr env)))
    (is eq :uniform state)))

(define-test (uniformity-logic get-local-id-is-divergent)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(get-local-id 0) env ctx nil))
         (state (calculate-uniformity-state expr env)))
    (is eq :divergent state)))

(define-test (uniformity-logic contagion-uniform-plus-uniform)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(+ (get-workgroup-id 0) (get-workgroup-size 0)) env ctx nil))
         (state (calculate-uniformity-state expr env)))
    (is eq :uniform state)))

(define-test (uniformity-logic contagion-uniform-plus-divergent)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(+ (get-workgroup-id 0) (get-local-id 0)) env ctx nil))
         (state (calculate-uniformity-state expr env)))
    (is eq :divergent state)))

(define-test (uniformity-logic provably-uniform-intrinsic)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr1 (analyze-expression '(provably-uniform? (get-workgroup-id 0)) env ctx nil))
         (expr2 (analyze-expression '(provably-uniform? (get-local-id 0)) env ctx nil)))
    (is eq 'boolean (semantic-node-type expr1))
    (true (semantic-literal-value expr1))
    (false (semantic-literal-value expr2))))

(define-test (uniformity-logic provably-divergent-intrinsic)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr1 (analyze-expression '(provably-divergent? (get-local-id 0)) env ctx nil))
         (expr2 (analyze-expression '(provably-divergent? (get-workgroup-id 0)) env ctx nil)))
    (true (semantic-literal-value expr1))
    (false (semantic-literal-value expr2))))

(define-test (uniformity-logic uniformity-tracked-in-let)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(let ((u (get-workgroup-id 0))
                                          (d (get-local-id 0)))
                                      (uniformity-state u)) env ctx nil))
         (val (semantic-literal-value (first (last (semantic-let-body expr))))))
    (is eq :uniform val)))

(define-test (uniformity-logic to-workgroup-uniform-creates-uniform)
  (let* ((env nil)
         (ctx (make-compiler-context))
         (expr (analyze-expression '(let ((u (to-workgroup-uniform (get-local-id 0))))
                                      (uniformity-state u)) env ctx nil))
         (val (semantic-literal-value (first (last (semantic-let-body expr))))))
    (is eq :uniform val)))

(define-test (uniformity-logic if-plus-fails-divergent)
  (let ((env nil)
        (ctx (make-compiler-context)))
    (fail (analyze-expression '(if+ (= (get-local-id 0) 0) 1 0) env ctx nil)
          'crisp-compiler-error)))

(define-test (uniformity-logic if-plus-succeeds-uniform)
  (let ((env nil)
        (ctx (make-compiler-context)))
    (finish (analyze-expression '(if+ (= (get-workgroup-id 0) 0) 1 0) env ctx nil))))

(define-test (uniformity-logic when-plus-fails-divergent)
  (let ((env nil)
        (ctx (make-compiler-context)))
    (fail (analyze-expression '(when+ (= (get-local-id 0) 0) 1) env ctx nil)
          'crisp-compiler-error)))

(define-test (uniformity-logic dotimes-plus-fails-divergent)
  (let ((env nil)
        (ctx (make-compiler-context)))
    (fail (analyze-expression '(dotimes+ (i (get-local-id 0)) 1) env ctx nil)
          'crisp-compiler-error)))

(define-test (uniformity-logic dotimes-plus-succeeds-uniform)
  (let ((env nil)
        (ctx (make-compiler-context)))
    (finish (analyze-expression '(dotimes+ (i (get-workgroup-id 0)) 1) env ctx nil))))
