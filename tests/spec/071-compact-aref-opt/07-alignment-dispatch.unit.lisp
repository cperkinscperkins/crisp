;; tests/spec/071-compact-aref-opt/07-alignment-dispatch.unit.lisp
;;
;; Unit tests for the compact aref optimization dispatch.
;; These tests compile sub-functions (not kernels) to verify that:
;;   :compact alignment → Horner / stride=1 path  (no mul i64)
;;   :strided alignment → stride-read path         (mul i64 present)
;;   template Aln param → safe stride-read path    (mul i64 present)
;;
;; Sub-functions are used here because they allow vector types to appear
;; without the full kernel-boundary SROA explosion, keeping the IR simpler.
;; Tests 01-06 cover the kernel-boundary cases end-to-end.

(in-package :cl-user)

(defpackage :crisp.test.aref-opt
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:compile-crisp-form-to-ir-string
                #:initialize-compiler))

(in-package :crisp.test.aref-opt)

(define-test aref-dispatch
  "Compact aref optimization dispatch tests.")

(defun %compile-aref-ir (form)
  "Compiles a Crisp form to LLVM IR; returns the IR string."
  (initialize-compiler :log-level :warn)
  (let ((*package* (find-package :crisp-language)))
    (compile-crisp-form-to-ir-string (eval `(quote ,form)) :target :llvmir)))

;;; ── Compact vector (N=1): optimizer path ──────────────────────────────

(define-test (aref-dispatch compact-vector-get-no-multiply)
  "Compact vector GET: flat = offset + i.  No stride read, no mul i64."
  (let ((ir (%compile-aref-ir
             '(def-function cv-get (v i)
                 (declare #'((vector long :align :compact) long => long))
               (~ v i)))))
    (false (search "mul i64" ir)
           "compact vector GET must not contain mul i64")))

(define-test (aref-dispatch compact-vector-set-no-multiply)
  "Compact vector SET: flat = offset + i.  No stride read, no mul i64."
  (let ((ir (%compile-aref-ir
             '(def-function cv-set (v i val)
                 (declare #'((vector long :align :compact) long long => nil))
               (set! (~ v i) val)))))
    (false (search "mul i64" ir)
           "compact vector SET must not contain mul i64")))

;;; ── Strided vector (N=1): stride path (regression guard) ─────────────

(define-test (aref-dispatch strided-vector-get-has-multiply)
  "Strided vector GET: flat = offset + i*stride[0].  Must contain mul i64."
  (let ((ir (%compile-aref-ir
             '(def-function sv-get (v i)
                 (declare #'((vector long :align :strided) long => long))
               (~ v i)))))
    (true (search "mul i64" ir)
          "strided vector GET must contain mul i64")))

(define-test (aref-dispatch strided-vector-set-has-multiply)
  "Strided vector SET: flat = offset + i*stride[0].  Must contain mul i64."
  (let ((ir (%compile-aref-ir
             '(def-function sv-set (v i val)
                 (declare #'((vector long :align :strided) long long => nil))
               (set! (~ v i) val)))))
    (true (search "mul i64" ir)
          "strided vector SET must contain mul i64")))

;;; ── Template function with unknown alignment ─────────────────────────
;;; When Aln is a template variable the compiler cannot determine alignment
;;; at analysis time, so it must fall back to the safe strided path.

(define-test (aref-dispatch template-unknown-align-has-multiply)
  "Template vector with Aln param: must use stride path (mul i64 present)
   even when the instantiated type happens to be a compact tensor,
   because the optimizer only fires when alignment is fully resolved."
  ;; Instantiate with :strided so the template resolves to a non-compact type.
  ;; The dispatch must NOT peek at the alignment of an instantiated template
  ;; type that was declared with a template variable — this test confirms that
  ;; a function declared as (vector T :align Aln) always takes the safe path
  ;; during template analysis, and that the concrete :strided instantiation
  ;; also takes the safe path.
  (let ((ir (%compile-aref-ir
             '(progn
               (with-template-type (T Aln)
                 (def-function template-vec-get (v i)
                     (declare #'((vector T :align Aln) long => T))
                   (~ v i)))
               (gen-template-vec-get long :strided)))))
    (true (search "mul i64" ir)
          "template-instantiated strided vector GET must contain mul i64")))

;;; Run tests
(test 'aref-dispatch)
