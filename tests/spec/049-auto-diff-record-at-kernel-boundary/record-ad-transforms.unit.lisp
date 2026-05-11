;; tests/spec/049-auto-diff-record-at-kernel-boundary/record-ad-transforms.unit.lisp
;;
;; Unit tests for the Option B record-at-kernel-boundary AD helpers.
;; These pin down the internal transforms that the E2E tests only cover indirectly.

(in-package :crisp.tests)

(define-test record-ad-transforms-test
  "Tests for 049 record-at-kernel-boundary AD transform helpers.")

;;; Helper: evaluate a form in the :crisp-language package so symbols
;;; are registered under the canonical crisp-language:: prefix.
(defun %eval-in-crisp-language (form-string)
  (cl:let ((*package* (find-package :crisp-language)))
    (eval (read-from-string form-string))))

;;; =========================================================
;;; %crisp-float-type-p
;;; =========================================================

(define-test (record-ad-transforms-test float-type-detection)
  "Float category types are detected; integer/record types are not."
  (true  (crisp.compiler::%crisp-float-type-p 'float))
  (true  (crisp.compiler::%crisp-float-type-p 'double))
  (false (crisp.compiler::%crisp-float-type-p 'int))
  (false (crisp.compiler::%crisp-float-type-p 'uint))
  (false (crisp.compiler::%crisp-float-type-p 'ulong)))

;;; =========================================================
;;; %crisp-record-type-p
;;; =========================================================

(define-test (record-ad-transforms-test record-type-detection)
  "Records are detected; scalars and cells are not."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-test-rec (a float) (b int))")
  (true  (crisp.compiler::%crisp-record-type-p 'crisp-language::unit-test-rec))
  ;; Parameterized form
  (true  (crisp.compiler::%crisp-record-type-p '(crisp-language::unit-test-rec)))
  ;; Scalars and cells are not records
  (false (crisp.compiler::%crisp-record-type-p 'float))
  (false (crisp.compiler::%crisp-record-type-p 'int)))

;;; =========================================================
;;; %get-record-runtime-fields
;;; =========================================================

(define-test (record-ad-transforms-test runtime-fields-basic)
  "Runtime fields returned; c-t fields excluded."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-test-rec2 (x float) (y int))")
  (cl:let ((fields (crisp.compiler::%get-record-runtime-fields 'crisp-language::unit-test-rec2)))
    (is = 2 (length fields))
    (is string= "X" (symbol-name (cl:first (cl:first fields))))
    (is string= "Y" (symbol-name (cl:first (cl:second fields))))))

(define-test (record-ad-transforms-test runtime-fields-excludes-ct)
  "c-t fields are excluded from runtime fields."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-test-rec3 (x float) (y float) (earnestness float :c-t 2.0))")
  (cl:let ((fields (crisp.compiler::%get-record-runtime-fields 'crisp-language::unit-test-rec3)))
    (is = 2 (length fields))
    (false (find "EARNESTNESS" fields :key (lambda (f) (symbol-name (cl:first f))) :test #'string=))))

(define-test (record-ad-transforms-test runtime-fields-parameterized-type)
  "Parameterized type spec also works."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-test-rec4 (x float) (y float) (k float :c-t 1.0))")
  (cl:let ((fields (crisp.compiler::%get-record-runtime-fields '(crisp-language::unit-test-rec4 :k 3.0))))
    (is = 2 (length fields))
    (false (find "K" fields :key (lambda (f) (symbol-name (cl:first f))) :test #'string=))))

;;; =========================================================
;;; %substitute-record-accessors
;;; =========================================================

(define-test (record-ad-transforms-test substitute-raw-accessor)
  "(~x~ vp) is substituted when vp is a known record param."
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-sym (intern "VP" pkg))
             (vp-x-sym (intern "VP_X" pkg))
             (vp-y-sym (intern "VP_Y" pkg))
             (record-subs-ht (make-hash-table :test 'eq))
             (record-type-ht (make-hash-table :test 'eq))
             (tilde-x-tilde (intern "~X~" pkg))
             (tilde-y-tilde (intern "~Y~" pkg)))
    (setf (gethash vp-sym record-subs-ht)
          (list (cons (intern "X" pkg) vp-x-sym)
                (cons (intern "Y" pkg) vp-y-sym)))
    (setf (gethash vp-sym record-type-ht) 'crisp-language::unit-test-rec2)

    ;; (~x~ vp) -> vp_x
    (is eq vp-x-sym
      (crisp.compiler::%substitute-record-accessors (list tilde-x-tilde vp-sym)
                                                    record-subs-ht record-type-ht))
    ;; (~y~ vp) -> vp_y
    (is eq vp-y-sym
      (crisp.compiler::%substitute-record-accessors (list tilde-y-tilde vp-sym)
                                                    record-subs-ht record-type-ht))
    ;; (~x~ other) where other is NOT a record param -> unchanged
    (cl:let* ((other-sym (intern "OTHER" pkg))
               (form (list tilde-x-tilde other-sym)))
      (is equal form
        (crisp.compiler::%substitute-record-accessors form record-subs-ht record-type-ht)))))

(define-test (record-ad-transforms-test substitute-nested-form)
  "Substitution recurses into nested forms."
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-sym  (intern "VP" pkg))
             (vp-x-sym (intern "VP_X" pkg))
             (vp-y-sym (intern "VP_Y" pkg))
             (record-subs-ht (make-hash-table :test 'eq))
             (record-type-ht (make-hash-table :test 'eq))
             (tx (intern "~X~" pkg))
             (ty (intern "~Y~" pkg))
             (mul-sym (intern "*" :crisp.compiler)))
    (setf (gethash vp-sym record-subs-ht)
          (list (cons (intern "X" pkg) vp-x-sym)
                (cons (intern "Y" pkg) vp-y-sym)))
    (setf (gethash vp-sym record-type-ht) 'crisp-language::unit-test-rec2)
    ;; (* (~x~ vp) (~y~ vp)) -> (* vp_x vp_y)
    (cl:let ((result (crisp.compiler::%substitute-record-accessors
                       (list mul-sym (list tx vp-sym) (list ty vp-sym))
                       record-subs-ht record-type-ht)))
      (is eq mul-sym (cl:first result))
      (is eq vp-x-sym (cl:second result))
      (is eq vp-y-sym (cl:third result)))))

;;; =========================================================
;;; %fix-record-grad-cell-emissions
;;; =========================================================

(define-test (record-ad-transforms-test fix-grad-emissions-basic)
  "(set! vp_x_GRAD expr) becomes (set! (~ vp_x_GRAD) expr) for grad-cell syms."
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-x-grad (intern "VP_X_GRAD" pkg))
             (adj-sym   (intern "VP_X_ADJ"  pkg))
             (grad-cell-syms (list vp-x-grad))
             ;; Use crisp.compiler::set! to match what %fix-record-grad-cell-emissions checks
             (form (list 'set! vp-x-grad adj-sym))
             (result (crisp.compiler::%fix-record-grad-cell-emissions form grad-cell-syms)))
    (is eq 'set! (cl:first result))
    ;; second element should be (~ vp_x_GRAD)
    (is equal (list '~ vp-x-grad) (cl:second result))
    (is eq adj-sym (cl:third result))))

(define-test (record-ad-transforms-test fix-grad-emissions-non-grad-unchanged)
  "(set! some-other-var expr) is not changed when not a grad-cell sym."
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-x-grad  (intern "VP_X_GRAD" pkg))
             (other-sym  (intern "OTHER_VAR"  pkg))
             (adj-sym    (intern "ADJ"  pkg))
             (grad-cell-syms (list vp-x-grad))
             (form (list 'set! other-sym adj-sym)))
    (is equal form
      (crisp.compiler::%fix-record-grad-cell-emissions form grad-cell-syms))))

;;; =========================================================
;;; %expand-record-kernel-inputs
;;; =========================================================

(define-test (record-ad-transforms-test expand-basic-record)
  "A v-point record (x float, y float) expands to two scalar inputs with two grad cells."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-vp (x float) (y float))")
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-sym (intern "VP" pkg)))
    (multiple-value-bind (flat-ins flat-types reassembly grad-params grad-types
                          subs-ht type-ht grad-syms)
        (crisp.compiler::%expand-record-kernel-inputs (list vp-sym)
                                                      (list 'crisp-language::unit-vp)
                                                      pkg)
      ;; Two scalar inputs replacing one record
      (is = 2 (length flat-ins))
      (is = 2 (length flat-types))
      ;; Both fields resolve to float
      (true (every #'crisp.compiler::%crisp-float-type-p flat-types))
      ;; One reassembly binding
      (is = 1 (length reassembly))
      ;; Two grad cell outputs (both fields are float)
      (is = 2 (length grad-params))
      (is = 2 (length grad-syms))
      ;; subs-ht has an entry for vp
      (true (gethash vp-sym subs-ht)))))

(define-test (record-ad-transforms-test expand-int-field-no-grad)
  "Post 101 endeavor: int fields ALSO produce gradient cell outputs (with
   float-element type promotion).  Renamed in spirit — both fields differentiate."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-mixed (x float) (y int))")
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-sym (intern "VP2" pkg)))
    (multiple-value-bind (flat-ins flat-types reassembly grad-params grad-types
                          subs-ht type-ht grad-syms)
        (crisp.compiler::%expand-record-kernel-inputs (list vp-sym)
                                                      (list 'crisp-language::unit-mixed)
                                                      pkg)
      ;; Still two scalar inputs
      (is = 2 (length flat-ins))
      ;; Both fields now produce grad cells (101: int → cell of float)
      (is = 2 (length grad-params))
      (is = 2 (length grad-syms)))))

(define-test (record-ad-transforms-test expand-ct-field-excluded)
  "c-t fields do not appear as scalar inputs or grad outputs."
  (initialize-compiler)
  (%eval-in-crisp-language "(def-record unit-ct-rec (x float) (y float) (k float :c-t 1.0))")
  (cl:let* ((pkg (find-package :crisp-language))
             (vp-sym (intern "VP3" pkg)))
    (multiple-value-bind (flat-ins flat-types reassembly grad-params grad-types
                          subs-ht type-ht grad-syms)
        (crisp.compiler::%expand-record-kernel-inputs (list vp-sym)
                                                      (list 'crisp-language::unit-ct-rec)
                                                      pkg)
      ;; Only 2 runtime fields (x and y), not 3
      (is = 2 (length flat-ins))
      (is = 2 (length grad-params))
      ;; No "K" in the flat inputs
      (false (find "VP3_K" flat-ins
                   :key #'symbol-name :test #'string=)))))

(define-test (record-ad-transforms-test expand-non-record-passthrough)
  "Non-record scalar inputs pass through unchanged with no grad cell."
  (initialize-compiler)
  (cl:let* ((pkg (find-package :crisp-language))
             (scale-sym (intern "SCALE" pkg)))
    (multiple-value-bind (flat-ins flat-types reassembly grad-params grad-types
                          subs-ht type-ht grad-syms)
        (crisp.compiler::%expand-record-kernel-inputs (list scale-sym) (list 'float) pkg)
      (is = 1 (length flat-ins))
      (is eq scale-sym (cl:first flat-ins))
      ;; No record reassembly
      (is = 0 (length reassembly))
      ;; No record grad cells (non-record scalar gets its own grad through existing path)
      (is = 0 (length grad-params)))))
