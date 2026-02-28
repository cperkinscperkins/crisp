;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

(defun run-unit-tests (unit-files)
  "Run discovered unit tests using Parachute"
  (when unit-files
        (ql:quickload "parachute" :silent t)
        (format t "~&~%=== Loading Unit Tests ===~%"))

  (let ((failed-load-files nil))
    (dolist (file unit-files)
      (format t "~&Loading Unit Test: ~a... " (file-namestring file))
      (finish-output)
      (handler-case
          (let ((*standard-output* (make-broadcast-stream))
                (*error-output* (make-broadcast-stream)))
            (load file))
        (error (e)
          (push (file-namestring file) failed-load-files)
          (format t "FAIL~%  Error: ~a~%" e))
        (:no-error (r)
                   (declare (ignore r))
                   (format t "PASS~%"))))

    (when failed-load-files
          (format t "~&---------------------------~%")
          (format t "Failed to Load Unit Tests:~%~{  - ~a~%~}" (nreverse failed-load-files))
          (return-from run-unit-tests nil))

    (format t "~&~%=== Executing Unit Tests ===~%")
    (let ((report (parachute:test 'crisp.compiler::crisp.tests)))
      (if (parachute:tests-with-status :failed report)
          nil
          t))))
