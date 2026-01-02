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

;; Configuration Globals
(defvar *use-binary* nil)
(defvar *compile-debug* nil)
(defvar *compile-single-pass* nil)

(defun get-binary-path ()
  (let ((exe (merge-pathnames "bin/crisp-compile.exe" (uiop:getcwd)))
        (unix (merge-pathnames "bin/crisp-compile" (uiop:getcwd))))
    (cond
     ((probe-file exe) exe)
     ((probe-file unix) unix)
     (t (error "Could not locate crisp-compile binary at ~a or ~a" exe unix)))))

(defun cleanup-ir-string (output)
  "Extracts the IR from the compiler stdout."
  (let ((marker "--- Generated LLVM IR: ---"))
    (let ((pos (search marker output)))
      (if pos
          (string-trim '(#\Space #\Newline #\Return) (subseq output (+ pos (length marker))))
          output))))

(defun run-spec-binary (file)
  ;; Filter out known incompatible tests for flags
  (when (and *compile-single-pass* (search "multipass" (pathname-name file)))
        (format t "~&Skipping ~a (Incompatible with --single-pass)~%" (pathname-name file))
        (return-from run-spec-binary t))

  (let ((bin (get-binary-path))
        (args (list (uiop:native-namestring file))))
    (when *compile-debug* (push "--debug" args))
    (when *compile-single-pass* (push "--single-pass" args))
    ;; Put flags first? parser logic says flags first usually.
    ;; Actually main.lisp uses (parse-cli-args) which separates flags/files. Order doesn't matter much.
    ;; But let's be safe: exe [flags] [file]
    (setf args (append (when *compile-debug* '("--debug"))
                 (when *compile-single-pass* '("--single-pass"))
                 (list (uiop:native-namestring file))))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       (t
         (let ((clean-ir (cleanup-ir-string output)))
           (cond
            ((= (length clean-ir) 0)
              (format *error-output* "FAIL (Empty IR)~%~a~%" error-output)
              nil)
            ((validate-ir-with-clang clean-ir)
              (format t "PASS~%")
              t)
            (t
              (format *error-output* "FAIL (Invalid IR via Binary)~%~a~%" error-output)
              nil))))))))

(defun run-spec-file (file)
  (format t "~&Running Spec: ~a... " (pathname-name file))
  (finish-output)

  (let ((is-spirv (search "spirv" (directory-namestring file) :test #'string-equal)))
    (if *use-binary*
        (if is-spirv
            (run-spec-spirv-binary file)
            (run-spec-binary file))
        (if is-spirv
            (run-spec-spirv-in-process file)
            (handler-case
                (let ((ir-string (compile-crisp-file-to-ir-string file)))
                  (if (validate-ir-with-clang ir-string)
                      (progn (format t "PASS~%") t)
                      (progn (format *error-output* "FAIL (Invalid IR)~%") nil)))
              (error (e)
                (format *error-output* "FAIL (Condition: ~a)~%" e)
                nil))))))

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

(defun compile-crisp-file-to-spirv (filepath)
  "Compiles a .crisp file to .spv and returns the output path if successful."
  (let ((out-path (make-pathname :type "spv" :defaults filepath))
        (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V
                  (crisp.compiler:initialize-compiler :log-level :warn)
                  (with-open-file (stream filepath)
                    (loop for form = (read stream nil :eof)
                          until (eq form :eof)
                          collect form)))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :spirv))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-spirv module out-path)))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        out-path
        nil)))

(defun run-spec-spirv-in-process (file)
  (handler-case
      (let ((out-path (compile-crisp-file-to-spirv file)))
        (if out-path
            (progn
             (format t "PASS (Generated ~a)~%" (file-namestring out-path))
             ;; Optional: Cleanup generated file
             (delete-file out-path)
             t)
            (progn (format *error-output* "FAIL (No SPV generated)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun run-spec-spirv-binary (file)
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "spv" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=spv")))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         (format t "PASS (Generated .spv)~%")
         (delete-file out-path)
         t)
       (t
         (format *error-output* "FAIL (No SPV generated)~%~a~%" error-output)
         nil)))))

(defun get-ci-stop-target ()
  "Reads tests/ci-stop.txt to determine the last directory to run."
  (let ((path (merge-pathnames "tests/ci-stop.txt" (uiop:getcwd))))
    (when (probe-file path)
          (let ((content (string-trim '(#\Space #\Newline #\Return) (uiop:read-file-string path))))
            (unless (zerop (length content))
              content)))))

(defun get-parent-directory-name (path)
  (car (last (pathname-directory path))))

(defun main ()
  (let* ((script-path (or *load-pathname* *compile-file-pathname*))
         ;; Assume tests/run-specs.lisp -> tests/spec/
         (spec-dir (merge-pathnames "tests/spec/" (uiop:getcwd)))
         (spec-files (directory (merge-pathnames "**/*.crisp" spec-dir)))
         (total 0)
         (passed 0)
         (failed-files '())
         (stop-target (get-ci-stop-target))
         (stop-triggered nil))

    ;; Parse Arguments
    (loop for arg in (uiop:command-line-arguments) do
            (cond
             ((string= arg "--use-binary") (setf *use-binary* t))
             ((string= arg "--debug") (setf *compile-debug* t))
             ((string= arg "--single-pass") (setf *compile-single-pass* t))))

    (format t "~&Locating specs in ~a~%" spec-dir)
    (format t "Configuration: Binary: ~a, Debug: ~a, Single-Pass: ~a~%"
      *use-binary* *compile-debug* *compile-single-pass*)

    (format t "~&Locating specs in ~a~%" spec-dir)
    (when stop-target
          (format t "Stop Target Active: Running tests up to directory '~a'~%" stop-target))

    ;; Sort mainly to ensure numerical order of directories (010-... before 011-...)
    (setf spec-files (sort spec-files #'string< :key #'namestring))

    (loop for file in spec-files do
            ;; Skip files in 'errors' subdirectories
            (unless (member "errors" (pathname-directory file) :test #'string=)
              (let ((dir-name (get-parent-directory-name file)))
                (when (and stop-target (string> dir-name stop-target))
                      (unless stop-triggered
                        (format t "~&--- Reached Stop Target (~a). Stopping. ---~%" stop-target)
                        (setf stop-triggered t))
                      (cl:return)))

              (incf total)
              (if (run-spec-file file)
                  (incf passed)
                  (push (pathname-name file) failed-files))))

    (format t "~&---------------------------~%")
    (format t "Spec Summary: ~a/~a Passed.~%" passed total)
    (when failed-files
          (format t "Failed Specs:~%~{  - ~a~%~}" (nreverse failed-files)))

    (if (= passed total)
        (uiop:quit 0)
        (uiop:quit 1))))

(main)
