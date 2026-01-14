(in-package :cl-user)

;; Pre-load Quicklisp because 'sbcl --script' skips .sbclrc
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
        (load quicklisp-init)))

;; Parse log level early to suppress noise during system load
(defvar *log-level*
        (let ((arg (find-if (lambda (x) (and (stringp x) (>= (length x) 12) (string= (subseq x 0 12) "--log-level=")))
                       sb-ext:*posix-argv*)))
          (if arg
              (intern (string-upcase (subseq arg (length "--log-level="))) :keyword)
              :error)))

;; Configure logging before loading if possible
(ql:quickload "log4cl" :silent t)
(if (eq *log-level* :off)
    (log:config :off)
    (log:config :sane :stream *error-output* *log-level*))

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
(initialize-compiler :log-level cl-user::*log-level*)
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)

;; Configuration Globals
(defvar *use-binary* nil)
(defvar *compile-debug* nil)
(defvar *compile-single-pass* nil)
(defvar *test-filter* nil)
;; cl-user::*log-level* is defined at the top

(defun get-binary-path ()
  (let ((exe (merge-pathnames "bin/crisp-compile.exe" (uiop:getcwd)))
        (unix (merge-pathnames "bin/crisp-compile" (uiop:getcwd))))
    (cond
     ((probe-file exe) exe)
     ((probe-file unix) unix)
     (t (error "Could not locate crisp-compile binary at ~a or ~a" exe unix)))))

(defun cleanup-ir-string (output)
  "Extracts the IR from the compiler stdout."
  (let ((marker-prefix "--- Generated LLVM IR")
        (marker-suffix "---"))
    (let ((prefix-pos (search marker-prefix output)))
      (if prefix-pos
          (let ((suffix-pos (search marker-suffix output :start2 (+ prefix-pos (length marker-prefix)))))
            (if suffix-pos
                (string-trim '(#\Space #\Newline #\Return) (subseq output (+ suffix-pos (length marker-suffix))))
                output))
          output))))

(defun run-spec-binary (file)
  ;; Filter out known incompatible tests for flags (REMOVED - now handled by FAIL-WITH)

  (let ((bin (get-binary-path))
        (args (list (uiop:native-namestring file))))
    (when *compile-debug* (push "--debug" args))
    (when *compile-single-pass* (push "--single-pass" args))
    ;; Put flags first? parser logic says flags first usually.
    ;; Actually main.lisp uses (parse-cli-args) which separates flags/files. Order doesn't matter much.
    ;; But let's be safe: exe [flags] [file]
    (setf args (append (when *compile-debug* '("--debug"))
                 (when *compile-single-pass* '("--single-pass"))
                 (list (format nil "--log-level=~a" cl-user::*log-level*))
                 (list (uiop:native-namestring file))))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (when (search "multipass" (namestring file))
            (format t "DEBUG BINARY: Cmd: ~a ~a~%Exit Code: ~a~%Error: ~a~%" bin args exit-code error-output))
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


(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active."
  (let ((*use-binary* (or *use-binary* (member "--use-binary" flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass" flags :test #'string=)))
        (*compile-debug* (or *compile-debug* (member "--debug" flags :test #'string=)))
        (emit-metadata (member "--metadata" flags :test #'string=))

        ;; Determine IR Target from flags (default to nil/generic)
        (ir-target (cond
                    ((member "--ir-target=spv" flags :test #'string=) :spirv)
                    ((member "--ir-target=ptx" flags :test #'string=) :ptx)
                    ((member "--metadata" flags :test #'string=) :spirv) ;; Metadata usually implies SPIR-V for now
                    (t nil))))

    ;; Dispatch based on configuration
    (if *use-binary*
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-binary file)) ;; Binary doesn't support metadata/validator yet in harness
         ((eq ir-target :ptx) (run-spec-ptx-binary file))
         (t (run-spec-binary file)))

        ;; In-Process Runner
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
         ((eq ir-target :ptx) (run-spec-ptx-in-process file))
         (t (run-spec-lisp-loader file))))))

(defun run-spec-file (file)
  (let ((directives (extract-test-directives file))
        (all-passed t))

    ;; 1. Default Run (Current Global Flags)
    (format t "~&Running Spec: ~a (Default)... " (pathname-name file))
    (finish-output) ;; Ensure "Running Spec..." is printed before runner output
    (unless (run-single-spec-pass file '())
      (setf all-passed nil))

    ;; 2. Extra Runs (TEST-WITH flags)
    (let ((extra-runs (parse-test-with directives)))
      (dolist (run extra-runs)
        (destructuring-bind (flags &optional validator) run
          (format t "~&Running Spec: ~a (Extra ~a~@[ : ~a~])... " (pathname-name file) flags validator)
          (finish-output)
          (unless (run-single-spec-pass file flags validator)
            (setf all-passed nil)))))

    all-passed))


(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (let ((*standard-output* (make-broadcast-stream))) ; Discard stdout (redirect to null)
    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*) ;; Standard cleanup
                  (with-open-file (stream filepath)
                    (loop for form = (read stream nil :eof)
                          until (eq form :eof)
                          collect form)))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (if *compile-single-pass*
                 (let ((toplevel-index 0)
                       (crisp.compiler:*current-module* nil))
                   (loop for form in forms do
                           (crisp.compiler:compile-toplevel-form form (list toplevel-index) module builder nil nil nil)
                           (incf toplevel-index)))
                 (crisp.compiler:compile-module forms module builder nil nil nil))

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

(defun compile-crisp-file-to-spirv (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .spv and returns the output path if successful."
  (let ((out-path (make-pathname :type "spv" :defaults filepath))
        (meta-path (make-pathname :type "metacrisp" :defaults filepath))
        (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))
    (when (probe-file meta-path) (delete-file meta-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*)
                  (with-open-file (stream filepath)
                    (loop for form = (read stream nil :eof)
                          until (eq form :eof)
                          collect form)))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :spirv)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-spirv module out-path)

               (when emit-metadata
                     (crisp.compiler::generate-metadata-for-file filepath meta-path))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        out-path
        nil)))

(defun run-spec-spirv-in-process (file &key (emit-metadata nil) (validator nil))
  (handler-case
      (let ((out-path (compile-crisp-file-to-spirv file :emit-metadata emit-metadata)))
        (if out-path
            (let ((res (if validator
                           (let ((meta-path (make-pathname :type "metacrisp" :defaults file)))
                             (format t "(Validator: ~a)... " validator)
                             (if (probe-file meta-path)
                                 (progn
                                  ;; Dispatch validator with just the meta-path
                                  (if (fboundp validator)
                                      (if (funcall validator meta-path)
                                          (progn (format t "Validator PASS. ") t)
                                          (progn (format *error-output* "Validator FAIL. ") nil))
                                      (progn
                                       ;; Try finding it in crisp.compiler package if symbol has no package
                                       (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                                         (if (and sym (fboundp sym))
                                             (if (funcall sym meta-path)
                                                 (progn (format t "Validator PASS. ") t)
                                                 (progn (format *error-output* "Validator FAIL. ") nil))
                                             (progn (format *error-output* "Validator fn ~a not found. " validator) nil))))))
                                 (progn (format *error-output* "FAIL (No Metadata Generated)~%") nil)))
                           (progn
                            (format t "PASS (Generated ~a)~%" (file-namestring out-path))
                            t))))

              ;; Cleanup generated artifacts
              (when (probe-file out-path) (delete-file out-path))
              (let ((meta-path (make-pathname :type "metacrisp" :defaults file)))
                (when (probe-file meta-path) (delete-file meta-path)))

              res)
            (progn (format *error-output* "FAIL (No SPV generated)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun run-spec-spirv-binary (file)
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "spv" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=spv" (format nil "--log-level=~a" cl-user::*log-level*))))
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


;; tests/run-specs.lisp - Add PTX runner functions (after line 224)

(defun compile-crisp-file-to-ptx (filepath)
  "Compiles a .crisp file to .ptx and returns the output path if successful."
  (let ((out-path (make-pathname :type "ptx" :defaults filepath))
        (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for PTX
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*)
                  (with-open-file (stream filepath)
                    (loop for form = (read stream nil :eof)
                          until (eq form :eof)
                          collect form)))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :ptx))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-ptx module out-path)))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        out-path
        nil)))

(defun run-spec-ptx-in-process (file)
  (handler-case
      (let ((out-path (compile-crisp-file-to-ptx file)))
        (if out-path
            (progn
             (format t "PASS (Generated ~a)~%" (file-namestring out-path))
             ;; Optional: Cleanup generated file
             (delete-file out-path)
             t)
            (progn (format *error-output* "FAIL (No PTX generated)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun run-spec-ptx-binary (file)
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "ptx" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=ptx" (format nil "--log-level=~a" cl-user::*log-level*))))
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
         (format t "PASS (Generated .ptx)~%")
         (delete-file out-path)
         t)
       (t
         (format *error-output* "FAIL (No PTX generated)~%~a~%" error-output)
         nil)))))


(defun get-ci-stop-target ()
  "Reads tests/ci-stop.txt to determine the last directory to run."
  (let ((path (merge-pathnames "tests/ci-stop.txt" (uiop:getcwd))))
    (when (probe-file path)
          (let ((content (string-trim '(#\Space #\Newline #\Return) (uiop:read-file-string path))))
            (unless (zerop (length content))
              content)))))

(defun get-parent-directory-name (path)
  "Extract the numbered spec directory name (e.g., '001-def-function') from path.
   Ignores subdirectories like 'errors/'."
  (let ((dirs (pathname-directory path)))
    ;; Find the first directory matching NNN-* pattern
    (dolist (dir (reverse dirs))
      (when (and (stringp dir)
                 (>= (length dir) 4)
                 (digit-char-p (cl:char dir 0))
                 (digit-char-p (cl:char dir 1))
                 (digit-char-p (cl:char dir 2))
                 (char= (cl:char dir 3) #\-))
            (return-from get-parent-directory-name dir)))
    ;; Fallback to last directory if no numbered dir found
    (car (last dirs))))

(defun discover-unit-tests (spec-dir stop-target)
  "Find all *.unit.lisp files in spec tree up to stop-target"
  (let ((unit-files (directory (merge-pathnames "**/*.unit.lisp" spec-dir)))
        (filtered-files nil))

    ;; Filter by stop-target
    (dolist (file unit-files)
      (let ((dir-name (get-parent-directory-name file)))
        (when (or (not stop-target)
                  (string<= dir-name stop-target))
              (push file filtered-files))))

    (sort (nreverse filtered-files) #'string< :key #'namestring)))

;; UNIT TESTS IN SPEC DIRECTORIES    


(defun read-crisp-file (filepath)
  "Reads all forms from a .crisp file."
  (with-open-file (stream filepath)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          collect form)))

;; Used for .unit.lisp files - just load and let Parachute run
(defun run-unit-test-loader (file)
  (handler-case
      (progn
       (let ((*standard-output* (make-broadcast-stream)))
         (load file))
       (format t "PASS~%")
       t)
    (error (e)
      (format t "FAIL~%  Error: ~a~%" e)
      nil)))

;; Used for .crisp specs - generic backend (IR validation)
(defun run-spec-lisp-loader (file)
  (handler-case
      (let ((ir-string (compile-crisp-file-to-ir-string file)))
        (if (validate-ir-with-clang ir-string)
            (progn (format t "PASS~%") t)
            (progn (format *error-output* "FAIL (Invalid IR)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun discover-unit-tests (spec-dir stop-target)
  "Find all *.unit.lisp files in spec tree up to stop-target"
  (let ((unit-files (directory (merge-pathnames "**/*.unit.lisp" spec-dir)))
        (filtered-files nil))

    ;; Filter by stop-target
    (dolist (file unit-files)
      (let ((dir-name (get-parent-directory-name file)))
        (when (or (not stop-target)
                  (string<= dir-name stop-target))
              (push file filtered-files))))

    (sort (nreverse filtered-files) #'string< :key #'namestring)))

;; UNIT TESTS IN SPEC DIRECTORIES    

(defun run-unit-tests (unit-files)
  "Run discovered unit tests using Parachute"
  (when unit-files
        ;; Load Parachute test framework
        (ql:quickload "parachute" :silent t)
        (format t "~&~%=== Running Unit Tests ===~%"))

  (let ((total 0)
        (passed 0)
        (failed-files nil))

    (dolist (file unit-files)
      (format t "~&Unit Test: ~a... " (file-namestring file))
      (finish-output)
      (incf total)
      (if (run-unit-test-loader file)
          (incf passed)
          (push (file-namestring file) failed-files)))

    (when unit-files
          (format t "~&---------------------------~%")
          (format t "Unit Tests: ~a/~a Passed.~%" passed total)
          (when failed-files
                (format t "Failed Unit Tests:~%~{  - ~a~%~}" (nreverse failed-files))))

    ;; Return success if all passed
    (= passed total)))

;; Directive parsing for test expectations
;; Extract header comments from test files containing directives like:
;; TEST-EXPECT: PASS
;; FAIL-WITH[--single-pass]: "error message"

(defun extract-test-directives (file)
  "Extract directive comment lines from file header.
   Stops at first line starting with '(' (non-comment Lisp form)."
  (with-open-file (stream file)
    (loop for line = (read-line stream nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return #\Newline) line)
          until (and (> (length trimmed) 0)
                     (not (starts-with trimmed ";"))
                     (cl:char= (cl:char trimmed 0) #\())
            when (starts-with trimmed ";;")
          collect line)))

(defun starts-with (str prefix)
  "Check if string starts with prefix."
  (and (>= (length str) (length prefix))
       (string= str prefix :end1 (length prefix))))

(defun parse-test-expect (directive-lines)
  "Parse TEST-EXPECT directive from header comments.
   Returns :PASS, :FAIL, or NIL if not specified."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "TEST-EXPECT:")
            (let ((value (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 12))))
              (cond
               ((string-equal value "PASS") (return-from parse-test-expect :pass))
               ((string-equal value "FAIL") (return-from parse-test-expect :fail))
               (t (warn "Unknown TEST-EXPECT value: ~a" value)
                  (return-from parse-test-expect nil)))))))
  nil)

(defun parse-fail-with (directive-lines)
  "Parses FAIL-WITH[--flag]: 'message' directives.
   Returns T if any directive matches the CURRENT active flags."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "FAIL-WITH[")
            (let* ((end-bracket (position #\] trimmed))
                   (colon (position #\: trimmed :start (or end-bracket 0)))
                   (flag-str (when end-bracket (subseq trimmed 10 end-bracket))))

              (when (and flag-str (> (length flag-str) 0))
                    ;; Check if flag is active
                    (let ((active (cond
                                   ((string= flag-str "--single-pass") *compile-single-pass*)
                                   ((string= flag-str "--debug") *compile-debug*)
                                   ((string= flag-str "--use-binary") *use-binary*)
                                   (t nil)))) ;; Ignore unknown flags for now
                      (when active
                            (return-from parse-fail-with t))))))))
  nil)

(defun parse-test-with (directive-lines)
  "Parses TEST-WITH[--flag1 --flag2] : validator-name directives.
   Returns a list of runs, where each run is (flags validator-fn)."
  (let ((runs '()))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "TEST-WITH[")
              (let* ((end-bracket (position #\] trimmed))
                     (content (when end-bracket (subseq trimmed 10 end-bracket)))
                     (colon (position #\: trimmed :start (or end-bracket 0)))
                     (validator (when colon
                                      (let ((v-str (string-trim '(#\Space #\Tab) (subseq trimmed (1+ colon)))))
                                        (if (starts-with v-str "#'")
                                            (subseq v-str 2) ;; Remove #' prefix if present
                                            v-str)))))
                (when (and content (> (length content) 0))
                      ;; Split by space to get individual flags
                      (let ((flags (uiop:split-string content :separator " ")))
                        (push (list flags (when validator (read-from-string validator))) runs)))))))
    (nreverse runs)))

(defun should-expect-failure-p (file)
  "Determine if test should be expected to fail."
  (let* ((directives (extract-test-directives file))
         (expect (parse-test-expect directives))
         (fail-with (parse-fail-with directives))
         (in-errors-dir (member "errors" (pathname-directory file) :test #'string-equal)))

    (cond
     ;; Explicit FAIL-WITH matches active flag -> Expect FAIL
     (fail-with t)

     ;; Explicit directive overrides directory
     ((eq expect :fail) t)
     ((eq expect :pass) nil)

     ;; Check filter
     ((and *test-filter* (not (search *test-filter* (namestring file))))
       nil) ;; Should not happen if filtered in loop, but whatever.

     ;; No directive, use directory
     (in-errors-dir t)
     (t nil))))


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
    (format t "DEBUG: Raw Args: ~a~%" (uiop:command-line-arguments))
    (loop for arg in (uiop:command-line-arguments) do
            (cond
             ((string= arg "--use-binary") (setf *use-binary* t))
             ((string= arg "--debug") (setf *compile-debug* t))
             ((string= arg "--single-pass") (setf *compile-single-pass* t))
             ((and (> (length arg) 9) (string= (subseq arg 0 9) "--filter="))
               (setf *test-filter* (subseq arg 9)))))

    ;; Re-initialize with user-requested log level
    (initialize-compiler :log-level cl-user::*log-level*)

    (format t "~&Locating specs in ~a~%" spec-dir)
    (format t "Configuration: Binary: ~a, Debug: ~a, Single-Pass: ~a~%"
      *use-binary* *compile-debug* *compile-single-pass*)
    (format t "DEBUG: Symbols EQ? single-pass: ~a~%"
      (eq '*compile-single-pass* (find-symbol "*COMPILE-SINGLE-PASS*" :crisp.compiler)))

    ;; Discover and run unit tests first
    (let ((unit-files (discover-unit-tests spec-dir stop-target)))
      (run-unit-tests unit-files))

    (format t "~&~%=== Running E2E Spec Tests ===~%")
    (format t "~&Locating specs in ~a~%" spec-dir)
    (when stop-target
          (format t "Stop Target Active: Running tests up to directory '~a'~%" stop-target))

    ;; Sort mainly to ensure numerical order of directories (010-... before 011-...)
    (setf spec-files (sort spec-files #'string< :key #'namestring))

    (loop for file in spec-files do
            (when (or (not *test-filter*) (search *test-filter* (namestring file)))
                  (let ((dir-name (get-parent-directory-name file))
                        (expect-failure (should-expect-failure-p file)))

                    ;; Check stop target
                    (when (and stop-target (string> dir-name stop-target))
                          (unless stop-triggered
                            (format t "~&--- Reached Stop Target (~a). Stopping. ---~%" stop-target)
                            (setf stop-triggered t))
                          (cl:return))

                    (format t "Running Spec: ~a... " (pathname-name file))
                    (finish-output)
                    (incf total)

                    ;; Run test and check expectation
                    (let ((test-passed (run-spec-file file)))
                      (when (search "multipass" (pathname-name file))
                            (format t "DEBUG MAIN: File: ~a. TestPassed: ~a. ExpectFail: ~a~%"
                              (pathname-name file) test-passed expect-failure))

                      (cond
                       ;; Test passed and we expected it to pass
                       ((and test-passed (not expect-failure))
                         (incf passed))

                       ;; Test failed and we expected it to fail
                       ((and (not test-passed) expect-failure)
                         (format t " (Expected failure)~%")
                         (incf passed))

                       ;; Test passed but we expected failure
                       ((and test-passed expect-failure)
                         (format *error-output* " ERROR: Test passed but was expected to fail!~%")
                         (push (pathname-name file) failed-files))

                       ;; Test failed but we expected pass
                       (t
                         (push (pathname-name file) failed-files)))))))

    (format t "~&---------------------------~%")
    (format t "Spec Summary: ~a/~a Passed.~%" passed total)
    (when failed-files
          (format t "Failed Specs:~%~{  - ~a~%~}" (nreverse failed-files)))

    (if (= passed total)
        (uiop:quit 0)
        (uiop:quit 1))))

(main)
