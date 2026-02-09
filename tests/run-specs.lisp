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
              :info)))

;; Configure logging before loading if possible
(ql:quickload "log4cl" :silent t)
(log:config :sane :stream *error-output* *log-level*)
(log:info "Initializing Spec Runner with log level: ~a" *log-level*)

;; Inline build/build.lisp logic without terminating process
(require "asdf")
(push *default-pathname-defaults* ql:*local-project-directories*)
;; Load the compiler system
(asdf:load-system :crisp)
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
                          #:die) ;; Shadow die (conflict with uiop)
  (:shadowing-import-from :common-lisp
                          #:cond #:when #:unless #:let #:return))

(defpackage :crisp.tests
  (:use :cl :crisp.compiler :crisp.llvm-bindings :parachute)
  ;; We are using both :cl and :crisp.compiler, both of which define
  ;; symbols like 'char', 'float', 'truncate', etc. We must tell the
  ;; test package which ones to use. Since we are testing the compiler,
  ;; we want to use the compiler's versions.
  (:shadowing-import-from :crisp.compiler
                          #:internal-def-function
                          #:generate-llvm-ir
                          #:generate-location-map
                          #:visit-toplevel-form
                          #:char #:short #:float #:double #:truncate #:floor
                          #:ceil #:round
                          #:ceil #:round
                          #:let #:return)
  (:shadowing-import-from :common-lisp #:cond #:when #:unless))

;; Register the keyword-named suite that spec-local unit tests expect.
;; We define it in CRISP.COMPILER since most unit tests live there or expect it visible.
(in-package :crisp.compiler)
(parachute:define-test :crisp.tests)

(in-package :crisp.spec-runner)


;; Initialize the compiler to ensure types and built-ins are loaded
(initialize-compiler :log-level cl-user::*log-level*)
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)

;; Configuration Globals
(defvar *use-binary* nil)
(defvar *compile-debug* nil)
(defvar *compile-single-pass* nil)
(defvar *compile-differentiate* nil)
(defvar *test-filter* nil)
(defvar *only-unit-tests* nil)
(defvar *skip-unit-tests* nil)
(defvar *keep-work* nil)
;; cl-user::*log-level* is defined at the top

(defun get-binary-path ()
  (let ((exe (merge-pathnames "bin/crisp-compile.exe" (uiop:getcwd)))
        (unix (merge-pathnames "bin/crisp-compile" (uiop:getcwd))))
    (cond
     ((probe-file exe)
       (log:debug "Found binary at: ~a" exe)
       exe)
     ((probe-file unix)
       (log:debug "Found binary at: ~a" unix)
       unix)
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
            (log:debug "DEBUG BINARY: Cmd: ~a ~a~%Exit Code: ~a~%Error: ~a~%" bin args exit-code error-output))
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

    ;; 3. Hoist Tests (TEST-HOIST[backend]: validator)
    (let ((hoist-directives (parse-test-hoist directives)))
      (dolist (directive hoist-directives)
        (let ((backend (car directive))
              (validator-name (cdr directive)))
          (format t "~&Running Spec: ~a (Hoist[~a] -> ~a)... " (pathname-name file) backend validator-name)
          (finish-output)
          (let ((cpp-files (run-spec-with-hoist file backend)))
            ;; Use find-symbol to look up the existing function symbol
            (let ((validator-sym (find-symbol (string-upcase validator-name) :crisp.spec-runner)))
              (if (fboundp validator-sym)
                  (unless (funcall validator-sym file cpp-files)
                    (setf all-passed nil))
                  (progn
                   (format t "FAIL (Validator ~a not found)~%" validator-name)
                   (setf all-passed nil))))))

        ;; Cleanup Hoist Files on Success
        (when (and all-passed (not *keep-work*))
              (let* ((base-name (pathname-name file))
                     (dir (pathname-directory file))
                     (cpp-files (directory (make-pathname :directory dir :name :wild :type "cpp" :defaults file)))
                     (exe-files (directory (make-pathname :directory dir :name :wild :type "exe" :defaults file)))
                     (spv-files (directory (make-pathname :directory dir :name :wild :type "spv" :defaults file)))
                     (meta-files (directory (make-pathname :directory dir :name :wild :type "metacrisp" :defaults file)))
                     (all-files (append cpp-files exe-files spv-files meta-files)))
                (dolist (f all-files)
                  (when (and (stringp (pathname-name f))
                             (uiop:string-prefix-p base-name (pathname-name f)))
                        (delete-file f)))))))

    all-passed))


(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active."
   (let ((*use-binary* (or *use-binary* (member "--use-binary" flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass" flags :test #'string=)))
        (*compile-debug* (or *compile-debug* (member "--debug" flags :test #'string=)))
        (*compile-differentiate* (or *compile-differentiate* (member "--differentiate" flags :test #'string=)))
        (emit-metadata (member "--metadata" flags :test #'string=))

        ;; Determine IR Target from flags (default to nil/generic)
        (ir-target (cond
                    ((member "--ir-target=spv" flags :test #'string=) :spirv)
                    ((member "--ir-target=ptx" flags :test #'string=) :ptx)
                    ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                    ((member "--metadata" flags :test #'string=) :spirv) ;; Metadata usually implies SPIR-V for now
                    (t nil))))

    ;; Skip SPIRV tests if SKIP_SPIRV_TESTS env var is set
    (when (and (eq ir-target :spirv) (uiop:getenv "SKIP_SPIRV_TESTS"))
          (format t "SKIP (SPIRV tests disabled via SKIP_SPIRV_TESTS)~%")
          (return-from run-single-spec-pass t)) ;; Return success to not fail the build

    ;; Dispatch based on configuration
    (if *use-binary*
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
         ((eq ir-target :ptx) (run-spec-ptx-binary file))
         ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
         (t (run-spec-binary file)))

        ;; In-Process Runner
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
         ((eq ir-target :ptx) (run-spec-ptx-in-process file))
         ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
         (t (run-spec-lisp-loader file))))))

(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (let ((*standard-output* (make-broadcast-stream))) ; Discard stdout (redirect to null)
    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*) ;; Standard cleanup
                  (with-open-file (stream filepath)
                    (let ((*package* (find-package :crisp.compiler)))
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
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
  "Compiles a .crisp file to .spv and returns the output path and metadata paths if successful."
  (let ((out-path (make-pathname :type "spv" :defaults filepath))
        (meta-base-path (make-pathname :type "metacrisp" :defaults filepath))
        (meta-paths nil)
        (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*)
                  ;; FIX: Set *package* to :crisp-language to match binary compiler behavior
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :spirv)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-spirv module out-path)

               (when emit-metadata
                     (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file filepath meta-base-path
                                                                   :output-targets (list (list :spv out-path))
                                                                   :forms forms))))
             (crisp.llvm-bindings:llvm-dispose-builder builder)
             (crisp.llvm-bindings:llvm-dispose-module module)))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        nil)))

(defun run-spec-with-hoist (file backend)
  "Compiles .crisp file with --hoist=backend flag and returns list of generated .cpp files."
  (let* ((hoist-arg (format nil "--hoist=~a" backend))
         (bin (get-binary-path))
         (args (list hoist-arg
                     (format nil "--log-level=~a" cl-user::*log-level*)
                     (uiop:native-namestring file))))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string :error-output :string :ignore-error-status t)
      (if (zerop exit-code)
          ;; Find generated .cpp files matching this test's base name
          (let ((base-name (pathname-name file)))
            (remove-if-not
                (lambda (path) (alexandria:starts-with-subseq base-name (pathname-name path)))
                (directory (make-pathname :name :wild
                                          :type "cpp"
                                          :defaults file))))
          (progn
           (format *error-output* "FAIL (Hoist Compilation failed with exit code ~a)~%~a~%" exit-code error-output)
           nil)))))

;;; L0 Validators for TEST-HOIST directives

(defun validate-l0-empty-kernel (crisp-file cpp-files)
  "Validates minimal C++ generation (Phase 1 check)."
  (if (null cpp-files)
      (progn
       (format t "FAIL: No C++ files generated~%")
       nil)
      (progn
       (format t "Generated ~a C++ file(s)~%" (length cpp-files))
       (dolist (cpp cpp-files)
         (format t "  - ~a~%" (file-namestring cpp)))
       (format t "PASS~%")
       t)))

(defun validate-l0-cell-address-space (crisp-file cpp-files)
  "Validates C++ files compile and contain correct LOCAL memory setup (nullptr value)."
  (declare (ignore crisp-file))
  (if (null cpp-files)
      (progn
       (format t "FAIL: No C++ files to validate~%")
       nil)
      ;; We check for nullptr in the generated code
      (let ((passed t))
        (dolist (cpp cpp-files)
          (let ((content (uiop:read-file-string cpp)))
            ;; Check for LOCAL pointer setup in Arg 3
            (unless (and (search "Arg 3: Local Pointer" content)
                         (search "nullptr" content :start2 (search "Arg 3: Local Pointer" content)))
              (format t "FAIL: ~a does not contain expected Local Pointer setup (nullptr)~%" (file-namestring cpp))
              (setf passed nil))))
        (when passed
              (format t "PASS: C++ contains correct Local Address Space setup.~%"))
        passed)))

;; Updated Validator: Tries Native (MinGW) first, then Docker
(defun resolve-clang-executable ()
  "Finds clang++.exe in PATH or common locations."
  (if (uiop:os-windows-p)
      (if (probe-file #P"C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe")
          #P"C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe"
          "clang++") ;; Fallback to path on windows if specific one missing
      "clang++")) ;; On Linux/CI, just use clang++ from path

(defun resolve-ze-loader ()
  "Finds ze_loader.dll in System32."
  (let ((path #P"C:/Windows/System32/ze_loader.dll"))
    (when (probe-file path) path)))

(defun resolve-l0-include-dir ()
  "Finds Level Zero include directory."
  (let ((candidates (list #P"C:/Users/cperk/Documents/level-zero/include"
                          (uiop:getenv "CRISP_L0_INCLUDE"))))
    (find-if (lambda (p) (and p (probe-file p))) candidates)))

(defun validate-l0-host-run (crisp-file cpp-files)
  "Validates C++ files compile AND run. Links against system ze_loader.dll."
  (if (null cpp-files)
      (progn (format t "FAIL: No C++ files to validate~%") nil)

      (let ((clang-exe (resolve-clang-executable))
            (l0-include (resolve-l0-include-dir))
            (ze-loader (resolve-ze-loader)))

        (log:debug "clang=~s inc=~s loader=~s" clang-exe l0-include ze-loader)

        (unless (and clang-exe l0-include ze-loader)
          (format t "FAIL: Missing native toolchain components. Falling back to validate-l0-compile-only (Docker)...~%")
          (return-from validate-l0-host-run (validate-l0-compile-only crisp-file cpp-files)))

        (dolist (cpp cpp-files)
          (let ((exe-path (make-pathname :type "exe" :defaults cpp)))
            ;; 1. Compile & Link
            (multiple-value-bind (output error-output exit-code)
                (uiop:run-program
                  (list (uiop:native-namestring clang-exe)
                        (uiop:native-namestring cpp)
                        "-I" (namestring l0-include)
                        (uiop:native-namestring ze-loader) ;; Link directly to DLL
                        "-static"
                        "-o" (uiop:native-namestring exe-path))
                  :output :string :error-output :string :ignore-error-status t)
              (declare (ignore output))

              (if (not (zerop exit-code))
                  (progn
                   (format t "FAIL: ~a compilation error~%~a~%" (file-namestring cpp) error-output)
                   (return-from validate-l0-host-run nil))

                  ;; 2. Run
                  (progn
                   (format t "Compiling ~a -> ~a... OK~%" (file-namestring cpp) (file-namestring exe-path))
                   (multiple-value-bind (run-out run-err run-code)
                       (uiop:run-program (uiop:native-namestring exe-path)
                         :output :string :error-output :string :ignore-error-status t)
                     (format t "Output:~%~a~%" run-out)
                     (format t "Output:~%~a~%" run-out)
                     (if (zerop run-code)
                         ;; Check Expectations
                         (let ((expectations (parse-hoist-expect (extract-test-directives crisp-file)))
                               (passed t))
                           (when expectations
                                 (dolist (exp expectations)
                                   (unless (search exp run-out)
                                     (format t "FAIL: Expectation not found in output: '~a'~%" exp)
                                     (setf passed nil))))

                           (if passed
                               (progn
                                (format t "PASS: ~a ran successfully!~%" (file-namestring cpp))
                                t)
                               nil))
                         (progn
                          (format t "FAIL: ~a execution failed (Code ~a)~%Error: ~a~%"
                            (file-namestring exe-path) run-code run-err)
                          (return-from validate-l0-host-run nil)))))))))
        t)))


(defun validate-l0-compile-only (crisp-file cpp-files)
  "Validates C++ files compile. Tries Native Clang first, then Docker."
  (let ((clang-exe (resolve-clang-executable))
        (l0-include (resolve-l0-include-dir))
        (docker-available (zerop (nth-value 2 (uiop:run-program '("docker" "--version") :ignore-error-status t :output nil)))))
    (log:debug "clang-exe=~s l0-include=~s docker-available=~s" clang-exe l0-include docker-available)

    (cond
     ;; Case 0: No files to validate
     ((null cpp-files)
       (format t "FAIL: No C++ files to validate (Hoist failed?)~%")
       nil)

     ;; Case 1: Native Tools Available
     ((and clang-exe l0-include)
       (format t "Validating with Native Clang: ~a~%" clang-exe)
       (dolist (cpp cpp-files)
         (multiple-value-bind (output error-output exit-code)
             (uiop:run-program
               (list clang-exe "-fsyntax-only"
                     "-I" (namestring l0-include)
                     "-std=c++17"
                     (uiop:native-namestring cpp))
               :output :string :error-output :string :ignore-error-status t)
           (declare (ignore output))
           (unless (zerop exit-code)
             (format t "FAIL: ~a compilation error~%~a~%" (file-namestring cpp) error-output)
             (return-from validate-l0-compile-only nil))
           (format t "PASS: ~a compiles (Native)~%" (file-namestring cpp))))
       t)

     ;; Case 2: Docker Available
     (docker-available
       (format t "Native tools not found. Validating with Docker...~%")
       (dolist (cpp cpp-files)
         (let* ((workspace-path "/workspace")
                (relative-path (enough-namestring cpp (uiop:getcwd)))
                (docker-path (format nil "~a/~a" workspace-path (substitute #\/ #\\ (namestring relative-path))))
                (cmd (append
                       (list "docker" "run" "--rm"
                             "-v" (format nil "~a:~a" (substitute #\/ #\\ (namestring (uiop:getcwd))) workspace-path))
                       (when l0-include
                             (list "-v" (format nil "~a:/usr/local/include" (substitute #\/ #\\ (namestring l0-include)))))
                       (list "crisp-c-validator"
                             "g++" "-fsyntax-only" "-I/usr/local/include" "-std=c++17" docker-path))))
           (multiple-value-bind (output error-output exit-code)
               (uiop:run-program cmd :output :string :error-output :string :ignore-error-status t)
             (declare (ignore output))
             (unless (zerop exit-code)
               (format t "FAIL: ~a compilation error~%~a~%" (file-namestring cpp) error-output)
               (return-from validate-l0-compile-only nil))
             (format t "PASS: ~a compiles (Docker)~%" (file-namestring cpp)))))
       t)

     ;; Case 3: No tools
     (t
       (format t "FAIL: Neither Native Clang (with L0 headers) nor Docker available.~%")
       (format t "      Checked Clang: ~a~%" clang-exe)
       (format t "      Checked L0 Inc: ~a~%" l0-include)
       nil))))


(defun run-spec-spirv-in-process (file &key (emit-metadata nil) (validator nil))
  (block :runner
    (handler-bind ((error (lambda (e)
                            (format *error-output* "FAIL (Condition: ~a)~%" e)
                            (return-from :runner nil))))
      (multiple-value-bind (out-path meta-paths)
          (compile-crisp-file-to-spirv file :emit-metadata emit-metadata)
        (if out-path
            (let ((res (if validator
                           (progn
                            (log:info "Running Validator: ~a" validator)
                            ;; Determine validation target
                            (let ((val-arg (cond
                                            ((and (listp meta-paths) (= (length meta-paths) 1)) (first meta-paths))
                                            (t meta-paths))))

                              (if (or (and (pathnamep val-arg) (probe-file val-arg))
                                      (and (listp val-arg) (every #'probe-file val-arg)))
                                  (progn
                                   ;; Dispatch validator
                                   (if (fboundp validator)
                                       (if (funcall validator val-arg)
                                           (progn (format t "Validator PASS. ") t)
                                           (progn (format *error-output* "Validator FAIL. ") nil))
                                       (progn
                                        ;; Try finding it in crisp.compiler package if symbol has no package
                                        (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                                          (if (and sym (fboundp sym))
                                              (if (funcall sym val-arg)
                                                  (progn (format t "Validator PASS. ") t)
                                                  (progn (format *error-output* "Validator FAIL. ") nil))
                                              (progn (format *error-output* "Validator fn ~a not found. " validator) nil))))))
                                  (progn (format *error-output* "FAIL (Metadata Missing: ~a)~%" val-arg) nil))))
                           (progn
                            (format t "PASS (Generated ~a)~%" (file-namestring out-path))
                            t))))

              ;; Cleanup generated artifacts
              (unless *keep-work*
                (when (probe-file out-path) (delete-file out-path))
                (dolist (mp (if (listp meta-paths) meta-paths (list meta-paths)))
                  (when (probe-file mp) (delete-file mp))))

              res)
            (progn (format *error-output* "FAIL (No SPV generated)~%") nil))))))


(defun run-spec-spirv-binary (file &key (emit-metadata nil) (validator nil))
  "Runs the binary compiler with --ir-target=spv. Optionally emits metadata and runs a validator."
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "spv" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=spv"
                    (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when emit-metadata (push "--metadata" args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         ;; File generated - now run validator if provided
         (let ((res (if validator
                        (progn
                         (format t "(Validator: ~a)... " validator)
                         ;; For metadata validators, collect .metacrisp files matching this test
                         (let* ((all-meta-files (directory (make-pathname :directory (pathname-directory file)
                                                                          :name :wild
                                                                          :type "metacrisp")))
                                ;; Filter to only files matching this test's name prefix
                                (meta-files (remove-if-not
                                                (lambda (mf)
                                                  (uiop:string-prefix-p (pathname-name file)
                                                                        (pathname-name mf)))
                                                all-meta-files))
                                ;; Match in-process behavior: single file -> pathname, multiple -> list
                                (val-arg (if emit-metadata
                                             (cond
                                              ((null meta-files) out-path)
                                              ((= (length meta-files) 1) (first meta-files))
                                              (t meta-files))
                                             out-path))
                                (sym (find-symbol (symbol-name validator) :crisp.compiler)))
                           (if (and sym (fboundp sym))
                               (if (funcall sym val-arg)
                                   (progn (format t "Validator PASS.~%") t)
                                   (progn (format *error-output* "Validator FAIL.~%") nil))
                               (progn (format *error-output* "Validator fn ~a not found.~%" validator) nil))))
                        (progn (format t "PASS (Generated .spv)~%") t))))
           ;; Cleanup
           (when (probe-file out-path)
                 (unless *keep-work* (delete-file out-path)))
           (dolist (mf (directory (make-pathname :directory (pathname-directory file)
                                                 :name :wild
                                                 :type "metacrisp")))
             (when (uiop:string-prefix-p (pathname-name file) (pathname-name mf))
                   (unless *keep-work* (delete-file mf))))
           res))
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
             (unless *keep-work* (delete-file out-path))
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
         (unless *keep-work* (delete-file out-path))
         t)
       (t
         (format *error-output* "FAIL (No PTX generated)~%~a~%" error-output)
         nil)))))

;; LLVM IR Runner Functions
(defun compile-crisp-file-to-llvmir (filepath)
  "Compiles a .crisp file to .ll and returns the output path if successful."
  (let ((out-path (make-pathname :type "ll" :defaults filepath))
        (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let ((crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*)
                  (with-open-file (stream filepath)
                    (let ((*package* (find-package :crisp.compiler)))
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (crisp.compiler:compile-module forms module builder nil nil nil)
             ;; Write LLVM IR to file
             (let ((ir-string (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                                (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                                  (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))))
               (with-open-file (stream out-path :direction :output :if-exists :supersede)
                 (write-string ir-string stream))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path) out-path nil)))

(defun run-spec-llvmir-in-process (file &key (validator nil))
  "Compiles to LLVM IR (.ll file) and optionally runs a validator."
  (handler-case
      (let ((out-path (compile-crisp-file-to-llvmir file)))
        (if out-path
            (let ((res (if validator
                           (progn
                            (format t "(Validator: ~a)... " validator)
                            (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                              (if (and sym (fboundp sym))
                                  (if (funcall sym out-path)
                                      (progn (format t "Validator PASS. ") t)
                                      (progn (format *error-output* "Validator FAIL. ") nil))
                                  (progn (format *error-output* "Validator fn ~a not found. " validator) nil))))
                           (progn (format t "PASS (Generated ~a)~%" (file-namestring out-path)) t))))
              (when (probe-file out-path)
                    (unless *keep-work* (delete-file out-path)))
              res)
            (progn (format *error-output* "FAIL (No LLVM IR generated)~%") nil)))
    (error (e)
      (format *error-output* "FAIL (Condition: ~a)~%" e) nil)))


;; Add validator support to binary mode LLVM IR compilation
(defun run-spec-llvmir-binary (file &key (validator nil))
  "Runs the binary compiler with --ir-target=llvmir. Optionally runs a validator."
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "ll" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=llvmir"
                    (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         ;; File generated - now run validator if provided
         (let ((res (if validator
                        (progn
                         (format t "(Validator: ~a)... " validator)
                         (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                           (if (and sym (fboundp sym))
                               (if (funcall sym out-path)
                                   (progn (format t "Validator PASS.~%") t)
                                   (progn (format *error-output* "Validator FAIL.~%") nil))
                               (progn (format *error-output* "Validator fn ~a not found.~%" validator) nil))))
                        (progn (format t "PASS (Generated .ll)~%") t))))
           (when (probe-file out-path)
                 (unless *keep-work* (delete-file out-path)))
           res))
       (t
         (format *error-output* "FAIL (No LLVM IR generated)~%~a~%" error-output)
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


;; UNIT TESTS IN SPEC DIRECTORIES    

(defun read-crisp-file (filepath)
  "Reads all forms from a .crisp file."
  (with-open-file (stream filepath)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          collect form)))

;; Helper to parse Parachute output
(defun check-parachute-failure (output)
  "Returns T if Parachute output indicates failure."
  (let ((pos (search "Failed:" output)))
    (when pos
          (let* ((rest (subseq output (+ pos 7)))
                 (num-str (string-trim '(#\Space #\Tab) rest))
                 (num (parse-integer num-str :junk-allowed t)))
            (and num (> num 0))))))

;; Used for .unit.lisp files - just load and let Parachute run
(defun run-unit-test-loader (file)
  (let ((output-shuttle (make-string-output-stream)))
    (handler-case
        (progn
         (let ((*standard-output* output-shuttle)
               (*error-output* output-shuttle)
               (*debug-io* output-shuttle))
           (load file))

         (let ((output (get-output-stream-string output-shuttle)))
           (if (check-parachute-failure output)
               (progn
                (format *error-output* "~&FAIL (Tests Failed)~%~a~%" output)
                nil)
               (progn
                (format t "PASS~%")
                t))))
      (error (e)
        (format *error-output* "FAIL~%  Error: ~a~%" e)
        nil))))

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

    ;; Filter by stop-target and global test filter
    (dolist (file unit-files)
      (let ((dir-name (get-parent-directory-name file)))
        (when (and (or (not stop-target)
                       (string<= dir-name stop-target))
                   (or (not *test-filter*)
                       (search *test-filter* (namestring file))))
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
                                   ((string= flag-str "--differentiate") *compile-differentiate*)
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
                                      (let ((v-str (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed (1+ colon)))))
                                        (if (starts-with v-str "#'")
                                            (subseq v-str 2) ;; Remove #' prefix if present
                                            v-str)))))
                (when (and content (> (length content) 0))
                      ;; Split by space to get individual flags
                      (let ((flags (uiop:split-string content :separator " ")))
                        (push (list flags (when validator (read-from-string validator))) runs)))))))
    (nreverse runs)))

(defun parse-test-hoist (directive-lines)
  "Parses TEST-HOIST[backend]: validator-name directives.
   Returns a list of (backend . validator-name) pairs."
  (let ((directives nil))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "TEST-HOIST[")
              (let* ((end-bracket (position #\] trimmed))
                     (backend-str (when end-bracket (subseq trimmed 11 end-bracket)))
                     (colon (position #\: trimmed :start (or end-bracket 0)))
                     (validator (when colon (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed (1+ colon))))))
                (when (and backend-str validator)
                      (push (cons (intern (string-upcase backend-str) :keyword) validator) directives))))))
    (nreverse directives)))

(defun parse-hoist-expect (directive-lines)
  "Parse HOIST-EXPECT: <string> lines.
   Returns list of expected strings."
  (let ((expectations '()))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "HOIST-EXPECT:")
              (let ((value (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 13))))
                (push value expectations)))))
    (nreverse expectations)))

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
             ((string= arg "--only-unit-tests") (setf *only-unit-tests* t))
             ((string= arg "--skip-unit-tests") (setf *skip-unit-tests* t))
             ((string= arg "--keep-work") (setf *keep-work* t))
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
    (unless *skip-unit-tests*
      (let ((unit-files (discover-unit-tests spec-dir stop-target)))
        (unless (run-unit-tests unit-files)
          (format t "~&Unit Tests Failed.~%")
          (uiop:quit 1))))

    (when *only-unit-tests*
          (format t "~&Only run unit tests requested. Exiting.~%")
          (uiop:quit 0))

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
                         (push (format nil "~a/~a" dir-name (pathname-name file)) failed-files))

                       ;; Test failed but we expected pass
                       (t
                         (push (format nil "~a/~a" dir-name (pathname-name file)) failed-files)))))))

    (format t "~&---------------------------~%")
    (format t "Run Configuration: Binary=~a, Debug=~a, SinglePass=~a~@[, Filter=~a~]~%"
      *use-binary* *compile-debug* *compile-single-pass* *test-filter*)
    (format t "Spec Summary: ~a/~a Passed.~%" passed total)
    (when failed-files
          (format t "Failed Specs:~%~{  - ~a~%~}" (nreverse failed-files)))

    (if (= passed total)
        (uiop:quit 0)
        (uiop:quit 1))))

;; Load overlay if present (for safe patching)
(let ((overlay (merge-pathnames "overlays/spec-runner-overlay.lisp" (uiop:getcwd))))
  (when (probe-file overlay)
        (format t "Loading overlay: ~a~%" overlay)
        (load overlay)))

(main)
