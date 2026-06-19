(in-package :cl-user)

(format t "~&=== INITIALIZATION: Setting up sb-cover ===~%")
(require :sb-cover)

;; 1. Initialization
(declaim (optimize sb-cover:store-coverage-data))

;; Helper to load Quicklisp and ASDF if needed
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
        (load quicklisp-init)))
(require "asdf")

;; Ensure the local system is available
(push *default-pathname-defaults* ql:*local-project-directories*)

;; 2. Instrumentation
(format t "~&=== INSTRUMENTATION: Recompiling Crisp ===~%")
(asdf:load-system :crisp :force t)

;; 3. Execution (Aggregation)
;; We bind sb-ext:*posix-argv* to pass "--no-quit" so the scripts return
;; control cleanly instead of terminating the image.
(let ((sb-ext:*posix-argv* '("sbcl" "--no-quit")))

  (format t "~&=== EXECUTION: Running CI Tests ===~%")
  (load "tests/run-ci.lisp")

  (format t "~&=== EXECUTION: Running Negative Specs ===~%")
  (load "tests/run-error-specs.lisp")

  (format t "~&=== EXECUTION: Running Main Specs ===~%")
  ;; Main specs runs CPU-bound with no extra flags
  (load "tests/run-specs.lisp"))

;; 4. Reporting
(format t "~&=== REPORTING: Generating HTML Coverage Report ===~%")
(sb-cover:report "coverage-report/")

;; 5. Teardown
(format t "~&=== TEARDOWN: Resetting Optimization Policy ===~%")
(declaim (optimize (sb-cover:store-coverage-data 0)))

(format t "~&=== TEARDOWN: Stripping Instrumentation ===~%")
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :crisp :force t))

(format t "~&=== COVERAGE RUN COMPLETE ===~%")
(uiop:quit 0)
