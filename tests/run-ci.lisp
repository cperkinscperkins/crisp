;; tests/run-ci.lisp
(in-package :cl-user)

;; load the crisp system using Quicklisp
(unless (find-package :ql)
  (let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file quicklisp-init)
          (load quicklisp-init))))

(format t "~&; --- Loading Crisp system via Quicklisp...~%")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")

;; ql:quickload will find crisp.asd, see the dependencies,
;; download dependencies, and then load crisp.
(ql:quickload '("crisp" "parachute"))
(format t "~&; --- System loaded successfully.~%")
;; FORCE LOAD CORE.LISP due to ASDF/Cache issues
;; (load "src/analysis/core.lisp")

;; Switch into the compiler package
(in-package :crisp.compiler)

;; Initialize the compiler for the test run.
(format t "~&; --- Initializing compiler for test run...~%")
(initialize-compiler :log-level :error)
(initialize-templates)

;; Run all Parachute tests
(format t "~&; --- Running Parachute tests ---~%")
(load "tests/all-tests.lisp")
(load "tests/test-structs.lisp")
(load "tests/test-struct-layout.lisp")
(load "tests/test-runtime-checks.lisp")
(load "tests/test-def-kernel.lisp")
(load "tests/test-storage-handles.lisp")
(load "tests/spec/049-auto-diff-record-at-kernel-boundary/record-ad-transforms.unit.lisp")
(load "tests/spec/052-differentiate-sub-functions/sub-func-ad.unit.lisp")
(let ((report (parachute:test :crisp.tests)))
  (unless (eq (parachute:status report) :passed)
    (format *error-output* "~&~%*** Crisp CI Tests FAILED! ***~%")
    (uiop:quit 1)))

;; switch back to cl-user just in case
(in-package :cl-user)


(format t "~&; --- ALL TESTS PASSED ---~%")
(uiop:quit 0)