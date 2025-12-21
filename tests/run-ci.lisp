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

;; Switch into the compiler package
(in-package :crisp.compiler)

;; Initialize the compiler for the test run.
(format t "~&; --- Initializing compiler for test run...~%")
(initialize-compiler :log-level :info)
(initialize-templates)

;; Run all Parachute tests
(format t "~&; --- Running Parachute tests ---~%")
(load "tests/all-tests.lisp")
(load "tests/test-structs.lisp")
(load "tests/test-struct-layout.lisp")
(load "tests/test-runtime-checks.lisp")
(unless (parachute:test :crisp.tests)
  (format *error-output* "~&~%*** Crisp CI Tests FAILED! ***~%")
  (uiop:quit 1))

;; switch back to cl-user just in case
(in-package :cl-user)

(uiop:quit 0)