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

;;; Forms are given as STRINGS and read in the :crisp-language package, exactly
;;; as the compiler reads .crisp source. (Quoting forms here would intern the
;;; operator symbols in this test package, where the compiler does not recognise
;;; them as builtins.) GPU builtins also require a dispatch context.

(defun ck-node (str)
  "Read STR in :crisp-language, analyze it in a fresh dispatch context, return
   the semantic node."
  (let ((crisp.compiler::*in-dispatch-context* t)
        (*package* (find-package :crisp-language)))
    (analyze-expression (read-from-string str) nil (make-compiler-context) nil)))

(defun ck (str)
  "Calculated uniformity state of STR."
  (calculate-uniformity-state (ck-node str) nil))

(defun ck-let-tail (str)
  "Literal value of the last body node of a let STR (the body ends in a
   (uniformity-state ...) call, which folds to a literal at analysis time)."
  (semantic-literal-value (first (last (semantic-let-body (ck-node str))))))

(define-test uniformity-logic)

;;; ---- roots & contagion -------------------------------------------------

(define-test (uniformity-logic literals-are-uniform)
  (is eq :uniform (ck "1")))

(define-test (uniformity-logic get-workgroup-id-is-uniform)
  (is eq :uniform (ck "(get-workgroup-id 0)")))

(define-test (uniformity-logic get-local-id-is-divergent)
  (is eq :divergent (ck "(get-local-id 0)")))

;; All 087 builtins constant across the workgroup are :uniform...
(define-test (uniformity-logic workgroup-constant-builtins-are-uniform)
  (is eq :uniform (ck "(get-num-groups 0)"))
  (is eq :uniform (ck "(get-local-work-size 0)"))
  (is eq :uniform (ck "(get-global-work-size 0)"))
  (is eq :uniform (ck "(get-global-offset 0)"))
  (is eq :uniform (ck "(get-total-threads)")))

;; ...and every per-work-item id is :divergent.
(define-test (uniformity-logic per-item-builtins-are-divergent)
  (is eq :divergent (ck "(get-global-id-abs 0)"))
  (is eq :divergent (ck "(get-local-linear-id)"))
  (is eq :divergent (ck "(get-global-linear-id)")))

(define-test (uniformity-logic contagion-uniform-plus-uniform)
  (is eq :uniform (ck "(+ (get-workgroup-id 0) (get-num-groups 0))")))

(define-test (uniformity-logic contagion-uniform-plus-divergent)
  (is eq :divergent (ck "(+ (get-workgroup-id 0) (get-local-id 0))")))

;;; ---- conversions are uniformity-transparent (gap #6) -------------------

(define-test (uniformity-logic conversion-of-uniform-is-uniform)
  (is eq :uniform (ck "(to-ulong (get-workgroup-id 0))")))

(define-test (uniformity-logic conversion-of-divergent-is-divergent)
  (is eq :divergent (ck "(to-ulong (get-local-id 0))")))

;;; ---- intrinsics fold to booleans --------------------------------------

(define-test (uniformity-logic provably-uniform-intrinsic)
  (let ((u (ck-node "(provably-uniform? (get-workgroup-id 0))"))
        (d (ck-node "(provably-uniform? (get-local-id 0))")))
    (is eq 'boolean (semantic-node-type u))
    (true  (semantic-literal-value u))
    (false (semantic-literal-value d))))

(define-test (uniformity-logic provably-divergent-intrinsic)
  (let ((d (ck-node "(provably-divergent? (get-local-id 0))"))
        (u (ck-node "(provably-divergent? (get-workgroup-id 0))")))
    (true  (semantic-literal-value d))
    (false (semantic-literal-value u))))

;;; ---- let-binding uniformity propagation (gap #1) ----------------------

(define-test (uniformity-logic uniformity-tracked-in-let)
  (is eq :uniform
      (ck-let-tail "(let ((u (get-workgroup-id 0)) (d (get-local-id 0))) (uniformity-state u))")))

(define-test (uniformity-logic divergent-tracked-in-let)
  (is eq :divergent
      (ck-let-tail "(let ((u (get-workgroup-id 0)) (d (get-local-id 0))) (uniformity-state d))")))

(define-test (uniformity-logic to-workgroup-uniform-creates-uniform)
  (is eq :uniform
      (ck-let-tail "(let ((u (to-workgroup-uniform (get-local-id 0)))) (uniformity-state u))")))

(define-test (uniformity-logic to-warp-uniform-creates-uniform)
  (is eq :uniform
      (ck-let-tail "(let ((u (to-warp-uniform (get-local-id 0)))) (uniformity-state u))")))

;;; ---- + variants enforce uniformity ------------------------------------

(define-test (uniformity-logic if-plus-fails-divergent)
  (fail (ck-node "(if+ (< (get-local-id 0) (to-ulong 4)) 1 0)")
        'crisp-compiler-error))

(define-test (uniformity-logic if-plus-succeeds-uniform)
  (finish (ck-node "(if+ (< (get-workgroup-id 0) (to-ulong 4)) 1 0)")))

(define-test (uniformity-logic when-plus-fails-divergent)
  (fail (ck-node "(when+ (< (get-local-id 0) (to-ulong 4)) 1)")
        'crisp-compiler-error))

(define-test (uniformity-logic dotimes-plus-fails-divergent)
  (fail (ck-node "(dotimes+ (i (get-local-id 0)) 1)")
        'crisp-compiler-error))

(define-test (uniformity-logic dotimes-plus-succeeds-uniform)
  (finish (ck-node "(dotimes+ (i (get-workgroup-id 0)) 1)")))

;;; ---- pre-pass meet helper (the cond-quirk-prone path) -----------------

(define-test (uniformity-logic uni-combine-meet)
  (is eq :uniform   (crisp.compiler::%uni-combine '(:uniform :uniform)))
  (is eq :divergent (crisp.compiler::%uni-combine '(:uniform :divergent)))
  (is eq :divergent (crisp.compiler::%uni-combine '(:divergent :unknown)))
  (is eq :unknown   (crisp.compiler::%uni-combine '(:uniform :unknown))))

(define-test (uniformity-logic uni-builtin-state-roots)
  (is eq :divergent (crisp.compiler::%uni-builtin-state 'get-global-id))
  (is eq :divergent (crisp.compiler::%uni-builtin-state 'get-local-id))
  (is eq :uniform   (crisp.compiler::%uni-builtin-state 'get-workgroup-id))
  (is eq :uniform   (crisp.compiler::%uni-builtin-state 'get-num-groups)))

;; Run tests. The spec runner (run-unit-tests) only flags a unit file when it
;; signals an error during load -- a plain Parachute assertion failure does not
;; signal -- so we explicitly raise on any failure to make this file actually
;; gate CI.
(let ((report (test 'uniformity-logic)))
  (let ((failures (parachute:tests-with-status :failed report)))
    (when failures
      (error "uniformity-logic: ~d unit assertion(s) failed" (length failures)))))
