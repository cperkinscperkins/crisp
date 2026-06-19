(in-package :cl-user)

;; Pre-load Quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
        (load quicklisp-init)))

(require "asdf")
(require "uiop")

(defpackage :crisp.error-runner
  (:use :cl :uiop))

(in-package :crisp.error-runner)

;; Configuration
(defvar *use-binary* t) ;; Always use binary for processed isolation
(defvar *debug* nil)
(defvar *no-quit* (member "--no-quit" sb-ext:*posix-argv* :test #'string=))

(defun get-binary-path ()
  (let ((exe (merge-pathnames "bin/crisp-compile.exe" (uiop:getcwd)))
        (unix (merge-pathnames "bin/crisp-compile" (uiop:getcwd))))
    (cond
     ((probe-file exe) exe)
     ((probe-file unix) unix)
     (t (error "Could not locate crisp-compile binary")))))

(defun read-check-fail-header (file)
  "Reads the first 5 lines of the file looking for ;; CHECK-FAIL: \"Expected Error\""
  (with-open-file (stream file :direction :input :if-does-not-exist :error)
    (loop for i from 0 below 5
          for line = (read-line stream nil nil)
          while line do
            (let ((pos (search ";; CHECK-FAIL:" line)))
              (when pos
                    (let ((start (position #\" line :start pos))
                          (end (position #\" line :from-end t)))
                      (when (and start end (> end start))
                            (return (subseq line (1+ start) end)))))))))

(defun run-error-check (file expected-error)
  (let ((bin (get-binary-path))
        (args (list (uiop:native-namestring file) "--log-level=off")))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)

      (if (zerop exit-code)
          (values nil (format nil "Compiler SUCCEEDED but should have FAILED."))
          (let ((combined (concatenate 'string output error-output)))
            (if (search expected-error combined)
                (values t nil)
                (values nil (format nil "Expected error '~a' not found. Got:~%~a" expected-error combined))))))))

(defun get-ci-stop-target ()
  "Reads tests/ci-stop.txt to determine the last directory to run."
  (let ((path (merge-pathnames "tests/ci-stop.txt" (uiop:getcwd))))
    (when (probe-file path)
          (let ((content (string-trim '(#\Space #\Newline #\Return) (uiop:read-file-string path))))
            (unless (zerop (length content))
              content)))))

(defun get-parent-directory-name (path)
  "Extract the numbered spec directory name."
  (let ((dirs (pathname-directory path)))
    (dolist (dir (reverse dirs))
      (when (and (stringp dir)
                 (>= (length dir) 4)
                 (digit-char-p (cl:char dir 0))
                 (digit-char-p (cl:char dir 1))
                 (digit-char-p (cl:char dir 2))
                 (char= (cl:char dir 3) #\-))
            (return-from get-parent-directory-name dir)))
    (car (last dirs))))


(defun main ()
  (let* ((spec-dir (merge-pathnames "tests/spec/" (uiop:getcwd)))
         ;; Find all .crisp files
         (all-files (directory (merge-pathnames "**/*.crisp" spec-dir)))
         (error-files '())
         (total 0)
         (passed 0)
         (failed-tests '())
         (stop-target (get-ci-stop-target))
         (stop-triggered nil))

    ;; Filter for files inside an 'errors' directory
    (dolist (f all-files)
      (let ((dirs (pathname-directory f)))
        (when (member "errors" dirs :test #'string=)
              (push f error-files))))

    (setf error-files (sort error-files #'string< :key #'namestring))

    (format t "~&Running Negative Tests (scanned from ~a)~%" spec-dir)
    (when stop-target
          (format t "Stop Target Active: Running tests up to directory '~a'~%" stop-target))

    (dolist (file error-files)
      (let ((dir-name (get-parent-directory-name file)))
        (when (and stop-target (string> dir-name stop-target))
              (unless stop-triggered
                (format t "~&--- Reached Stop Target (~a). Stopping. ---~%" stop-target)
                (setf stop-triggered t))
              (return))

        (let ((expected (read-check-fail-header file)))
          (if expected
              (progn
               (incf total)
               (format t "Running ~a... " (pathname-name file))
               (finish-output)
               (multiple-value-bind (success msg) (run-error-check file expected)
                 (if success
                     (progn (format t "PASS~%") (incf passed))
                     (progn
                      (format t "FAIL~%  ~a~%" msg)
                      (push (cons (pathname-name file) msg) failed-tests)))))
              (format t "Skipping ~a (No CHECK-FAIL header)~%" (pathname-name file))))))

    (format t "~&---------------------------~%")
    (format t "Negative Test Summary: ~a/~a Passed.~%" passed total)

    (when failed-tests
          (format t "Failures:~%")
          (dolist (f failed-tests)
            (format t "  - ~a: ~a~%" (car f) (cdr f))))

    (if (and (> total 0) (= passed total))
        (unless *no-quit* (uiop:quit 0))
        (if *no-quit*
            (error "Negative Test Summary: ~a/~a Passed." passed total)
            (uiop:quit 1)))))

(main)
