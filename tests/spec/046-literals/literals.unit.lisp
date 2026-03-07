;; tests/spec/046-literals/literals.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.literals
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:compile-crisp-form-to-ir-string))

(in-package :crisp.test.literals)

(define-test literals)

(defun %read-crisp (str)
  "Reads STR as a Crisp s-expression in the :crisp-language package,
   so that suffix symbols like |255UC| are interned there correctly."
  (let ((*package* (find-package :crisp-language)))
    (read-from-string str)))

(defun %compile-literal-fn (return-type body)
  "Compiles a trivial no-arg def-function that returns BODY with the
   given RETURN-TYPE string.  Returns the LLVM IR as a string."
  (compile-crisp-form-to-ir-string
   (%read-crisp
    (format nil "(def-function test-lit () (declare (return-type ~a)) ~a)"
            return-type body))))

;; -----------------------------------------------------------------------
;; Integer suffixes
;; -----------------------------------------------------------------------

(define-test (literals uchar-suffix)
  "255uc should compile to an i8-returning function"
  (let ((ir (%compile-literal-fn "uchar" "255uc")))
    (true (search "define i8 @test_lit" ir))))

(define-test (literals short-suffix)
  "100s should compile to an i16-returning function"
  (let ((ir (%compile-literal-fn "short" "100s")))
    (true (search "define i16 @test_lit" ir))))

(define-test (literals ushort-suffix)
  "60000us should compile to an i16-returning function"
  (let ((ir (%compile-literal-fn "ushort" "60000us")))
    (true (search "define i16 @test_lit" ir))))

(define-test (literals uint-suffix)
  "42U should compile to an i32-returning function"
  (let ((ir (%compile-literal-fn "uint" "42U")))
    (true (search "define i32 @test_lit" ir))))

(define-test (literals long-suffix)
  "1000L should compile to an i64-returning function"
  (let ((ir (%compile-literal-fn "long" "1000L")))
    (true (search "define i64 @test_lit" ir))))

(define-test (literals ulong-suffix)
  "1000UL should compile to an i64-returning function"
  (let ((ir (%compile-literal-fn "ulong" "1000UL")))
    (true (search "define i64 @test_lit" ir))))

;; -----------------------------------------------------------------------
;; Float suffixes
;; -----------------------------------------------------------------------

(define-test (literals half-suffix)
  "1.5h should compile to a half-returning function"
  (let ((ir (%compile-literal-fn "half" "1.5h")))
    (true (search "define half @test_lit" ir))))

(define-test (literals float-suffix)
  "1.5f should compile to a float-returning function"
  (let ((ir (%compile-literal-fn "float" "1.5f")))
    (true (search "define float @test_lit" ir))))

(define-test (literals bfloat16-suffix)
  "1.5bf should compile to a bfloat-returning function"
  (let ((ir (%compile-literal-fn "bfloat16" "1.5bf")))
    (true (search "define bfloat @test_lit" ir))))

;; Run tests - will error if any fail
(test 'literals)
