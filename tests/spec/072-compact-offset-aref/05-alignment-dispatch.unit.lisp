;; tests/spec/072-compact-offset-aref/05-alignment-dispatch.unit.lisp
;;
;; Unit tests for the three-tier alignment dispatch.
;; Verifies :compact (no offset, no stride), :compact-offset (offset, no stride),
;; and :strided (offset + stride) at the sub-function level.

(in-package :cl-user)

(defpackage :crisp.test.compact-offset
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:compile-crisp-form-to-ir-string
                #:initialize-compiler))

(in-package :crisp.test.compact-offset)

(define-test compact-offset-dispatch
  "Three-tier alignment dispatch tests.")

(defun %compile-aref-ir (form)
  (initialize-compiler :log-level :warn)
  (let ((*package* (find-package :crisp-language)))
    (compile-crisp-form-to-ir-string (eval `(quote ,form)) :target :llvmir)))

(defun %has-stride-mul (ir)
  "Returns T if IR contains a stride multiply (mul i64 without ptrtoint)."
  (let ((pos 0))
    (loop
      (let ((m (search "mul i64" ir :start2 pos)))
        (unless m (return nil))
        (let* ((eol (or (position #\newline ir :start m) (length ir)))
               (line (subseq ir m eol)))
          (unless (search "ptrtoint" line) (return t)))
        (setf pos (1+ m))))))

(defun %has-offset-load (ir)
  "Returns T if IR loads from offset field (field index 1: i32 0, i32 1)."
  (not (null (search ", i32 0, i32 1" ir))))

;;; ── :compact — no offset, no stride ─────────────────────────────────

(define-test (compact-offset-dispatch compact-no-stride-mul)
  "compact vector GET: no stride multiply"
  (let ((ir (%compile-aref-ir
             '(def-function cv-get (v i)
                 (declare #'((vector long :align :compact) long => long))
               (~ v i)))))
    (false (%has-stride-mul ir) "compact must not have stride mul")))

(define-test (compact-offset-dispatch compact-no-offset-load)
  "compact vector GET: no offset field read"
  (let ((ir (%compile-aref-ir
             '(def-function cv-get2 (v i)
                 (declare #'((vector long :align :compact) long => long))
               (~ v i)))))
    (false (%has-offset-load ir) "compact must not load from offset field")))

;;; ── :compact-offset — offset present, no stride ──────────────────────

(define-test (compact-offset-dispatch compact-offset-no-stride-mul)
  ":compact-offset vector GET: no stride multiply"
  (let ((ir (%compile-aref-ir
             '(def-function cov-get (v i)
                 (declare #'((vector long :align :compact-offset) long => long))
               (~ v i)))))
    (false (%has-stride-mul ir) "compact-offset must not have stride mul")))

(define-test (compact-offset-dispatch compact-offset-has-offset-load)
  ":compact-offset vector GET: offset field IS read"
  (let ((ir (%compile-aref-ir
             '(def-function cov-get2 (v i)
                 (declare #'((vector long :align :compact-offset) long => long))
               (~ v i)))))
    (true (%has-offset-load ir) "compact-offset must load from offset field")))

;;; ── :strided — both offset and stride ────────────────────────────────

(define-test (compact-offset-dispatch strided-has-stride-mul)
  ":strided vector GET: stride multiply present"
  (let ((ir (%compile-aref-ir
             '(def-function sv-get (v i)
                 (declare #'((vector long :align :strided) long => long))
               (~ v i)))))
    (true (%has-stride-mul ir) "strided must have stride mul")))

;;; Run tests
(test 'compact-offset-dispatch)
