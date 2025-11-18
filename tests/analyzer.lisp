;;; tests/analyzer.lisp

(in-package :crisp.compiler)

(defun run-analyzer-tests ()
  "Runs all internal tests for the semantic analyzer."
  (test-analyze-return-type-from-spec)
  (test-analyze-environment-from-spec)
  (test-analyze-return-type-from-list)
  (test-analyze-environment-from-list)
  (format t "~&; --- Analyzer tests passed! ---~%"))

(defun test-analyze-return-type-from-spec ()
  (format t "~&;   Testing analyze-return-type-from-spec...~%")
  ;; Valid types
  (assert (eq 'float (analyze-return-type-from-spec '(int => float))))
  (assert (eq 'ulong (analyze-return-type-from-spec '(char => ulong))))
  ;; Nil return type
  (assert (eq 'nil (analyze-return-type-from-spec '(int => nil))))
  (assert (eq 'nil (analyze-return-type-from-spec '(int =>))))
  (assert (eq 'nil (analyze-return-type-from-spec '(int))))

  ;; Invalid type
  (handler-case (analyze-return-type-from-spec '(int => foobar))
    (crisp-unknown-type-error (c)
      (assert (eq 'foobar (unknown-type-name c)))
      (format t "~&;     [PASS] Caught expected unknown type error for 'foobar'~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch unknown type error.")))
  (format t "~&;   ...test-analyze-return-type-from-spec PASSED~%"))

(defun test-analyze-environment-from-spec ()
  (format t "~&;   Testing analyze-environment-from-spec...~%")
  ;; Valid
  (let ((env (analyze-environment-from-spec '(a b) '(int float => nil))))
    (assert (equal '((a int) (b float)) env)))

  ;; Arity mismatch
  (handler-case (analyze-environment-from-spec '(a) '(int float => nil))
    (crisp-signature-arity-error (c)
      (assert (= 2 (arity-error-expected c)))
      (assert (= 1 (arity-error-inferred c)))
      (format t "~&;     [PASS] Caught expected arity error~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch arity mismatch error.")))

  ;; Invalid type
  (handler-case (analyze-environment-from-spec '(a) '(bar => nil))
    (crisp-unknown-type-error (c)
      (assert (eq 'bar (unknown-type-name c)))
      (format t "~&;     [PASS] Caught expected unknown type error for 'bar'~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch unknown type error.")))
  (format t "~&;   ...test-analyze-environment-from-spec PASSED~%"))

(defun test-analyze-return-type-from-list ()
  (format t "~&;   Testing analyze-return-type-from-list...~%")
  ;; Valid
  (assert (eq 'float (analyze-return-type-from-list '((return-type float)))))
  (assert (eq 'nil (analyze-return-type-from-list '((return-type nil)))))

  ;; Invalid
  (handler-case (analyze-return-type-from-list '((return-type baz)))
    (crisp-unknown-type-error (c)
      (assert (eq 'baz (unknown-type-name c)))
      (format t "~&;     [PASS] Caught expected unknown type error for 'baz'~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch unknown type error.")))

  ;; Should ignore function spec
  (assert (null (analyze-return-type-from-list '((function (int => int))))))
  (format t "~&;   ...test-analyze-return-type-from-list PASSED~%"))

(defun test-analyze-environment-from-list ()
  (format t "~&;   Testing analyze-environment-from-list...~%")
  ;; Valid
  (let ((env (analyze-environment-from-list '(a b) '((type a b float)))))
    (assert (equal '((a float) (b float)) env)))

  ;; Arity mismatch
  (handler-case (analyze-environment-from-list '(a) '((type a b int)))
    (crisp-signature-arity-error (c)
      (assert (= 2 (arity-error-expected c)))
      (assert (= 1 (arity-error-inferred c)))
      (format t "~&;     [PASS] Caught expected arity error~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch arity mismatch error.")))

  ;; Invalid type
  (handler-case (analyze-environment-from-list '(a) '((type a quux)))
    (crisp-unknown-type-error (c)
      (assert (eq 'quux (unknown-type-name c)))
      (format t "~&;     [PASS] Caught expected unknown type error for 'quux'~%"))
    (:no-error (&rest args)
      (declare (ignore args))
      (error "Failed to catch unknown type error.")))
  (format t "~&;   ...test-analyze-environment-from-list PASSED~%"))