;; tests/spec/123-ffi-ad/pass3-handle-passive.unit.lisp
;;
;; Endeavor 123 (FFI-AD) Pass 3: a (c-handle ...) parameter of a foreign function
;; must be PASSIVE in the derived VJP — it contributes no returned gradient
;; (not an active scalar) and no shadow pointer (not active memory). This asserts
;; that directly at registration: %register-foreign-backward must place the
;; handle index in NEITHER :active-scalar-indices NOR :pointer-param-indices.
;;
;; (An on-kernel handle test under --differentiate is currently blocked by an
;; unrelated make-c-handle gap: its (c-pointer ...) type argument is ANF-flattened
;; during backward-kernel regeneration and rejected as an "Unsupported form". The
;; VJP passivity ABI verified here is independent of that.)

(in-package :cl-user)

(defpackage :crisp.test.ffi-ad-pass3
  (:use :cl :parachute))

(in-package :crisp.test.ffi-ad-pass3)

(define-test ffi-ad-pass3)

(define-test (ffi-ad-pass3 handle-param-is-passive)
  "Mixed signature #'(float int c-pointer c-handle => int): float+int are active
   scalars, the c-pointer is active memory, the c-handle is passive."
  (crisp.compiler::initialize-compiler :differentiate t)
  (let ((c-name (intern "TEST_FFI_AD_HANDLE" :crisp.compiler))
        ;; Read the signature in :crisp-language so the type-head symbols
        ;; (c-pointer / c-handle / float / int) are the ones the compiler
        ;; recognises -- quoting them here would intern them in this test
        ;; package, where parse-type-specifier does not resolve them. (Same
        ;; reason as uniformity-logic.unit.lisp; see [[unit-test-gating-quirk]].)
        (sig (let ((*package* (find-package :crisp-language)))
               (read-from-string
                "(float int (c-pointer :address-space :global) (c-handle (c-pointer :address-space :global)) => int)"))))
    (crisp.compiler::register-foreign-function
     c-name sig (intern "TEST_FFI_AD_HANDLE_BWD" :crisp.compiler))
    (let ((info (gethash c-name crisp.compiler::*differentiable-functions*)))
      (true info "foreign function should be registered as differentiable")
      ;; float(0) + int(1) are active scalars; pointer(2) and handle(3) are not.
      (is equal '(0 1) (getf info :active-scalar-indices))
      ;; the c-pointer(2) is active memory; the handle(3) is NOT.
      (is equal '(2) (getf info :pointer-param-indices))
      ;; one returned gradient per active scalar (the handle adds none).
      (is = 2 (getf info :n-float-params))
      (is = 1 (getf info :n-return))
      ;; explicit: index 3 (the handle) appears in neither list — fully passive.
      (false (member 3 (getf info :active-scalar-indices)))
      (false (member 3 (getf info :pointer-param-indices))))))

;; Run tests. The spec runner (run-unit-tests) only flags a unit file when it
;; signals an error during load -- a plain Parachute assertion failure does not
;; signal -- so we explicitly raise on any failure to make this file gate CI.
;; (See [[unit-test-gating-quirk]].)
(let ((report (test 'ffi-ad-pass3)))
  (let ((failures (parachute:tests-with-status :failed report)))
    (when failures
      (error "ffi-ad-pass3: ~d unit assertion(s) failed" (length failures)))))
