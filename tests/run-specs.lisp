(in-package :cl-user)

;; Pre-load Quicklisp because 'sbcl --script' skips .sbclrc
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
        (load quicklisp-init)))

;; Inline build/build.lisp logic without terminating process
(require "asdf")
(push *default-pathname-defaults* ql:*local-project-directories*)
(asdf:clear-system "crisp")
(asdf:load-system "crisp" :force t)
(ql:quickload "crisp")

;; Load the LLVM foreign library (defined in src/llvm-bindings.lisp but not auto-loaded)
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)

(defpackage :crisp.spec-runner
  (:use :cl :crisp.compiler :uiop)
  (:shadowing-import-from :crisp.compiler
                          #:internal-def-function
                          #:generate-llvm-ir
                          #:char #:short #:float #:double #:truncate #:floor
                          #:ceil #:round
                          #:cond #:when #:unless ;; Shadow conditionals
                          #:die ;; Shadow die (conflict with uiop)
                          #:let #:return))

(in-package :crisp.spec-runner)

;; Initialize the compiler to ensure types and built-ins are loaded
(initialize-compiler :log-level :info)
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)

(defun run-spec-file (file)
  (format t "~&Running Spec: ~a... " (pathname-name file))
  (finish-output)
  (handler-case
      (let ((ir-string (compile-crisp-file-to-ir-string file)))
        (if (validate-ir-with-clang ir-string)
            (progn (format t "PASS~%") t)
            (progn (format *error-output* "FAIL (Invalid IR)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (let ((*standard-output* (make-broadcast-stream))) ; Discard stdout (redirect to null)
    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level :warn) ;; Standard cleanup
                  (with-open-file (stream filepath)
                    (loop for form = (read stream nil :eof)
                          until (eq form :eof)
                          collect form)))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (crisp.compiler:compile-module forms module builder nil nil nil)
             (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
               (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                 (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))))

(defun validate-ir-with-clang (ir-string)
  "Uses clang to validate LLVM IR."
  (uiop:with-temporary-file (:stream stream :pathname path :type "ll")
    (write-string ir-string stream)
    (finish-output stream)
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (list "clang" "-x" "ir" "-c" (uiop:native-namestring path)
                                "-o" (uiop:native-namestring (uiop:null-device-pathname)))
          :output nil
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (if (zerop exit-code)
          t
          (progn
           (format t "~%LLVM Verification Error:~%~a~%" error-output)
           nil)))))

(defun main ()
  (let* ((script-path (or *load-pathname* *compile-file-pathname*))
         ;; Assume tests/run-specs.lisp -> tests/spec/
         (spec-dir (merge-pathnames "tests/spec/" (uiop:getcwd)))
         (spec-files (directory (merge-pathnames "**/*.crisp" spec-dir)))
         (total 0)
         (passed 0)
         (failed-files '()))

    (format t "~&Locating specs in ~a~%" spec-dir)
    ;; Sort mainly to ensure numerical order of directories (010-... before 011-...)
    (setf spec-files (sort spec-files #'string< :key #'namestring))

    (loop for file in spec-files do
            (incf total)
            (if (run-spec-file file)
                (incf passed)
                (push (pathname-name file) failed-files)))

    (format t "~&---------------------------~%")
    (format t "Spec Summary: ~a/~a Passed.~%" passed total)
    (when failed-files
          (format t "Failed Specs:~%~{  - ~a~%~}" (nreverse failed-files)))

    (if (= passed total)
        (uiop:quit 0)
        (uiop:quit 1))))

(main)
