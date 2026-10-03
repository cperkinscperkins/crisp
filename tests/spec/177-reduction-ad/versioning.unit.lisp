(in-package :cl-user)

(defpackage :crisp.test.ad-versioning
  (:use :cl :parachute))

(in-package :crisp.test.ad-versioning)

;;; ENDEAVOUR 177 Phase 1a (BUG 100) -- the AD path's VERSIONING of in-place scalar writes, checked as the
;;; pure function it is: flat ANF in, flat ANF (plus the statements to replay) out.
;;;
;;;     (SET! V e)                ->  (V%V1 e)                             later reads use V%V1
;;;     (REDUCE-WARP #'+ V 0.0)   ->  (V%V1 V) (REDUCE-WARP #'+ V%V1 0.0)  later reads use V%V1
;;;
;;; and the primal replay SPLIT after each copy so the reduction re-runs there.  The VERIFY-AUTODIFF specs
;;; (124/17-18, 175/65-67, 177/01-09) measure the gradients; this pins the shapes, including the cases that
;;; must be LEFT ALONE -- a variable rebound later, or used in a later multi-value binding (renaming would
;;; break the EQ lookup %collect-forward-primal-bindings relies on), and a set! of a tensor PLACE.

(defun %anf (string)
  "Read STRING as a list of flat-ANF forms in the compiler's package."
  (let ((*package* (find-package :crisp.compiler)))
    (read-from-string (concatenate 'string "(" string ")"))))

(defun %sym (name)
  (intern name (find-package :crisp.compiler)))

(defun %version (string)
  (multiple-value-list (crisp.compiler::%ad-version-in-place-writes (%anf string))))

(define-test set-of-a-scalar-becomes-a-binding
  (destructuring-bind (flat stmts) (%version "(V (~ X)) (%T1 (* V V)) (SET! V %T1) (R (* V 2.0))")
    (is equal (%anf "(V (~ X)) (%T1 (* V V)) (V%V1 %T1) (R (* V%V1 2.0))") flat
        "the set! is a binding of the next version, and the later read uses it")
    (is eq nil stmts "a set! needs no replayed statement -- it is an ordinary binding")))

(define-test a-reduction-becomes-a-copy-and-a-replayed-statement
  (destructuring-bind (flat stmts) (%version "(V (~ X)) (REDUCE-WARP #'+ V 0.0) (R (* V V))")
    (is equal (%anf "(V (~ X)) (V%V1 V) (REDUCE-WARP #'+ V%V1 0.0) (R (* V%V1 V%V1))") flat)
    (is = 1 (length stmts))
    (is eq (%sym "V%V1") (car (first stmts)) "the replay is keyed on the copy's binding")))

(define-test a-dependent-reduction-copies-every-clause-variable
  (destructuring-bind (flat stmts)
      (%version "(V (~ X)) (I (TO-ULONG 3)) (REDUCE-WARP #'COMB ((V 0.0) (I 0ul)) 8) (R (+ V 1.0))")
    (is equal (%anf "(V (~ X)) (I (TO-ULONG 3)) (V%V1 V) (I%V2 I)
                     (REDUCE-WARP #'COMB ((V%V1 0.0) (I%V2 0ul)) 8) (R (+ V%V1 1.0))")
        flat)
    (is eq (%sym "I%V2") (car (first stmts)) "keyed on the LAST copy, so every copy precedes it")))

(define-test a-variable-rebound-later-is-left-alone
  (let ((in "(V (~ X)) (SET! V 1.0) (V (* 2.0 3.0)) (R V)"))
    (is equal (%anf in) (first (%version in)))))

(define-test a-variable-in-a-later-multi-value-binding-is-left-alone
  (let ((in "(V (~ X)) (REDUCE-WARP #'+ V 0.0) (M N (OUTER V 3))"))
    (is equal (%anf in) (first (%version in)))))

(define-test a-set-of-a-tensor-place-is-left-alone
  (let ((in "(V (~ X)) (SET! (~ OUT 0) V)"))
    (is equal (%anf in) (first (%version in)))))

(define-test the-replay-is-split-after-the-copy
  (let* ((stmt (first (%anf "(REDUCE-WARP #'+ V%V1 0.0)")))
         (out (crisp.compiler::%ad-assemble-primal-replay
               (%anf "(V (~ X)) (V%V1 V) (R (* V%V1 V%V1))")
               (list (cons (%sym "V%V1") stmt))
               :body)))
    (is equal (first (%anf "(LET ((V (~ X)) (V%V1 V)) (REDUCE-WARP #'+ V%V1 0.0) (LET ((R (* V%V1 V%V1))) :BODY))"))
        out)))

(define-test a-statement-whose-copy-was-dropped-is-skipped
  (let* ((stmt (first (%anf "(REDUCE-WARP #'+ V%V1 0.0)")))
         (out (crisp.compiler::%ad-assemble-primal-replay
               (%anf "(V (~ X))") (list (cons (%sym "V%V1") stmt)) :body)))
    (is equal (first (%anf "(LET ((V (~ X))) :BODY)")) out)))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the tests here and signal on failure.
(let* ((report (test '(set-of-a-scalar-becomes-a-binding
                       a-reduction-becomes-a-copy-and-a-replayed-statement
                       a-dependent-reduction-copies-every-clause-variable
                       a-variable-rebound-later-is-left-alone
                       a-variable-in-a-later-multi-value-binding-is-left-alone
                       a-set-of-a-tensor-place-is-left-alone
                       the-replay-is-split-after-the-copy
                       a-statement-whose-copy-was-dropped-is-skipped)))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "ad-versioning: ~d test(s) failed -- the AD path's versioning of in-place writes (BUG 100) changed shape."
           (length failures))))
