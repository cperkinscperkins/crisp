;; tests/spec/147-cuda-verify-autodiff/directive-parsing.unit.lisp
;;
;; Unit tests for endeavor 147's VERIFY-AUTODIFF backend pin and the
;; runtime-selection policy behind it.
;;
;; These exist because NOTHING ELSE COVERS THEM ON CI.  Every spec-level
;; VERIFY-AUTODIFF check needs a GPU and skips on a CI runner, so the
;; directive grammar and the auto-selection policy — both of which are pure
;; functions with real error paths — would otherwise ship untested.

(in-package :crisp.tests)

;; The parse helpers live in :CL-USER and are loaded by run-specs.lisp at
;; startup.  Load them here too so this file is self-contained under any
;; runner (loading is idempotent: the file is defuns and defparameters).
(unless (find-symbol "%VAD-MATCH-DIRECTIVE" :cl-user)
  (load (merge-pathnames "tests/verify-autodiff-parse.lisp" (uiop:getcwd))))

(define-test verify-autodiff-directive-test
  "Endeavor 147: VERIFY-AUTODIFF[BACKEND] parsing and runtime selection.")

;;; --- %vad-match-directive: the grammar ------------------------------

(define-test (verify-autodiff-directive-test bare-form-has-no-pin)
  "A bare VERIFY-AUTODIFF: yields its body and NO pinned runtime."
  (multiple-value-bind (body runtime)
      (cl-user::%vad-match-directive "VERIFY-AUTODIFF: x=3.0 atol=1e-3")
    (is string= "x=3.0 atol=1e-3" body)
    (is eq nil runtime)))

(define-test (verify-autodiff-directive-test pinned-forms-yield-keywords)
  "VERIFY-AUTODIFF[BACKEND]: pins the named runtime and strips the bracket."
  (dolist (case '(("CUDA" :cuda) ("L0" :l0) ("OPENCL" :opencl)))
    (multiple-value-bind (body runtime)
        (cl-user::%vad-match-directive
         (format nil "VERIFY-AUTODIFF[~a]: x=3.0 atol=1e-3" (first case)))
      (is string= "x=3.0 atol=1e-3" body)
      (is eq (second case) runtime))))

(define-test (verify-autodiff-directive-test backend-name-is-case-insensitive)
  "Backend names match case-insensitively, like the rest of the directives."
  (is eq :cuda (nth-value 1 (cl-user::%vad-match-directive
                             "VERIFY-AUTODIFF[cuda]: x=3.0 atol=1e-3"))))

(define-test (verify-autodiff-directive-test non-directive-lines-are-ignored)
  "A line that is not a VERIFY-AUTODIFF directive returns NIL, not an error."
  (is eq nil (cl-user::%vad-match-directive "TEST-EXPECT: PASS"))
  (is eq nil (cl-user::%vad-match-directive "HOIST-ARCH: sm_90"))
  ;; Prefix-similar but distinct: must not be mistaken for the bare form.
  (is eq nil (cl-user::%vad-match-directive "VERIFY-AUTODIFF-SOMETHING: x=1.0")))

;;; --- %vad-match-directive: the error paths --------------------------
;;;
;;; These matter more than they look.  A directive whose whole job is to
;;; catch silent wrongness must not itself fail silently: a typo'd backend
;;; that quietly stopped verifying anything would be the worst possible
;;; failure mode, so every malformed pin is an ERROR rather than a NIL.

(define-test (verify-autodiff-directive-test unknown-backend-is-an-error)
  "An unrecognised backend name errors rather than silently not matching."
  (fail (cl-user::%vad-match-directive "VERIFY-AUTODIFF[NOPE]: x=3.0 atol=1e-3")))

(define-test (verify-autodiff-directive-test unterminated-bracket-is-an-error)
  "A missing ] errors rather than being read as a bare directive."
  (fail (cl-user::%vad-match-directive "VERIFY-AUTODIFF[CUDA x=3.0 atol=1e-3")))

(define-test (verify-autodiff-directive-test missing-colon-is-an-error)
  "The colon after the bracket is required."
  (fail (cl-user::%vad-match-directive "VERIFY-AUTODIFF[CUDA] x=3.0 atol=1e-3")))

;;; --- parse-verify-autodiff: the pin reaches the spec plist ----------

(define-test (verify-autodiff-directive-test pin-is-threaded-into-the-spec)
  "The parsed spec carries :runtime, and the rest of the body still parses."
  (let ((bare   (cl-user::parse-verify-autodiff
                 '(";; VERIFY-AUTODIFF: x=3.0 atol=1e-3 expect.x=6.0")))
        (pinned (cl-user::parse-verify-autodiff
                 '(";; VERIFY-AUTODIFF[CUDA]: x=3.0 atol=1e-3 expect.x=6.0"))))
    (is eq nil   (getf bare :runtime))
    (is eq :cuda (getf pinned :runtime))
    ;; The pin must not disturb anything else about the directive.
    (is equal (getf bare :inputs)         (getf pinned :inputs))
    (is equal (getf bare :expected-grads) (getf pinned :expected-grads))
    (is =     (getf bare :atol)           (getf pinned :atol))))

(define-test (verify-autodiff-directive-test at-most-one-directive-per-spec)
  "Two VERIFY-AUTODIFF lines in one spec is still an error, pinned or not."
  (fail (cl-user::parse-verify-autodiff
         '(";; VERIFY-AUTODIFF: x=3.0 atol=1e-3"
           ";; VERIFY-AUTODIFF[CUDA]: x=3.0 atol=1e-3"))))

;;; --- Runtime selection policy ---------------------------------------

(define-test (verify-autodiff-directive-test runner-loads-without-a-gpu)
  "The on-metal runner must LOAD on any machine, GPU or not.

   This is the invariant endeavor 147 Phase 0 established, and it is worth
   a test of its own: before it, one missing shared library took the whole
   runner down and turned all 58 VERIFY-AUTODIFF checks into skips —
   including on the CUDA pod, where they should have been running."
  (finish (load (merge-pathnames "tests/verify-autodiff-runner.lisp" (uiop:getcwd)))))

(define-test (verify-autodiff-directive-test cuda-is-excluded-from-auto-select)
  "A bare directive must NEVER auto-select CUDA.

   Measured on an H100: with :cuda in the auto list, the Intel spec
   145/18-ring-staged-vjp-bmg — BMG profile, BMG fragment shape — was picked
   up by the CUDA runtime and died on a kernel-parameter mismatch.  It was
   right to fail and far worse to pass.  A spec runs on CUDA only if it says
   so.  If someone widens this list, this test is the tripwire."
  (let ((autos (symbol-value (find-symbol "*AD-AUTO-RUNTIMES*" :cl-user))))
    (false (member :cuda autos))
    (true  (member :l0 autos))))

(define-test (verify-autodiff-directive-test selection-returns-nil-when-nothing-is-available)
  "With no runtime available, selection yields NIL so the caller SKIPs.

   This is exactly the CI configuration — no Level Zero, no CUDA, no OpenCL
   ICD — and the path that must not signal."
  (progv (list (find-symbol "*AD-AUTO-RUNTIMES*" :cl-user)
               (find-symbol "*CUDA-LIBRARY-LOADED*" :cl-user)
               (find-symbol "*L0-LIBRARY-LOADED*" :cl-user)
               (find-symbol "*OPENCL-LIBRARY-LOADED*" :cl-user))
      (list '() nil nil nil)
    (is eq nil (funcall (find-symbol "AD-SELECT-RUNTIME" :cl-user)))
    (is eq nil (funcall (find-symbol "AD-SELECT-RUNTIME" :cl-user) :cuda))
    (is eq nil (funcall (find-symbol "AD-SELECT-RUNTIME" :cl-user) :l0))))
