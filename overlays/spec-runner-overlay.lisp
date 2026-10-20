;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; tests/run-specs.lisp -- NEW (endeavour 190)
(defun parse-hoist-kernel (directive-lines)
  "Parse HOIST-KERNEL: file|source (Endeavour 190).  Returns \"file\", \"source\" or nil.
   `source` forwards --hoist-kernel=source to the hoist compile: the L0 launcher then embeds the
   .crisp text and compiles it at run time through the compile API (c-api/include/crisp.h)."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "HOIST-KERNEL:")
        (let ((v (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 13))))
          (when (plusp (length v)) (return (string-downcase v))))))))

;; tests/run-specs.lisp -- NEW (endeavour 190)
(defun %hoist-kernel-source-p (file)
  "T when FILE's L0 hoist should use --hoist-kernel=source: its HOIST-KERNEL directive says so, or
   the runner was started with --hoist-kernel=source (the A6(A) pass: every L0 hoist spec through
   the compile API, same expectations).  A spec saying HOIST-KERNEL: file opts out of the pass."
  (let* ((directives (extract-test-directives file))
         (directive (parse-hoist-kernel directives)))
    (cond ((equal directive "source") t)
          ((equal directive "file") nil)
          ;; The pass is about RUNNING the launcher: a spec whose L0 validator only inspects the
          ;; generated .cpp text checks file-mode text (literal argument indices, which source mode
          ;; rewrites to crisp_slot[N]), so it keeps file mode.
          (t (and (member "--hoist-kernel=source" (uiop:command-line-arguments) :test #'string=)
                  (%l0-hoist-runs-launcher-p directives))))))

;; tests/run-specs.lisp -- NEW (endeavour 190)
(defun %l0-hoist-runs-launcher-p (directive-lines)
  "T when a TEST-HOIST[L0] directive in DIRECTIVE-LINES names a validator that compiles AND RUNS the
   launcher on metal (validate-l0-host-run, validate-l0-mma-run)."
  (some (lambda (line)
          (let ((trimmed (string-left-trim ";; " line)))
            (and (starts-with trimmed "TEST-HOIST[L0]:")
                 (some (lambda (v) (search v trimmed)) '("validate-l0-host-run" "validate-l0-mma-run")))))
        directive-lines))

;; tests/run-specs.lisp -- REPLACES run-spec-with-hoist (endeavour 190: --hoist-kernel=source via the HOIST-KERNEL directive or the runner's --hoist-kernel=source option)
(defun run-spec-with-hoist (file backend &optional bc-files)
  "Compiles .crisp file with --hoist=backend flag and returns list of generated output files.
   For L0: discovers .cpp files.  For CUDA: discovers .cu files.
   Checks SKIP_<BACKEND>_HOIST env var (e.g. SKIP_L0_HOIST=true) to skip
   gracefully on machines that don't have the target SDK.
   Endeavor 122: BC-FILES (foreign .bc) are prepended to the compiler args so
   FFI device functions are linked into the hoisted kernel."
  ;; Endeavor 144: an L0 hoist compiles the kernel to SPIR-V first, so it is impossible
  ;; without the translator — skip rather than report a hoist "failure" (a CUDA-only box has
  ;; no llvm-spirv, since bin/ is gitignored).  Same detection as the three SPIR-V compile
  ;; entry points, so the whole harness agrees on what this machine can do.
  (when (and (string-equal (symbol-name backend) "L0")
             (not (spirv-toolchain-available-p)))
    (format t "SKIP (no SPIR-V toolchain on this machine)~%")
    (return-from run-spec-with-hoist :skipped))
  ;; Check for SKIP env var (e.g. SKIP_L0_HOIST, SKIP_CUDA_HOIST)
  (let ((skip-env (uiop:getenv (format nil "SKIP_~a_HOIST" (symbol-name backend)))))
    (when (and skip-env (string-not-equal skip-env "false"))
      (format t "SKIP (~a hoist disabled via SKIP_~a_HOIST)~%" backend (symbol-name backend))
      (return-from run-spec-with-hoist :skipped)))
  ;; Endeavor 140 reconcile: auto-skip the L0 backend on non-Intel hardware — the CUDA
  ;; validators already skip-gate on nvcc, but L0 had no equivalent, so -bmg (Intel Level-Zero)
  ;; tests HARD-FAILED on NVIDIA pods.  Skips on NVIDIA (H100/B300), still RUNS on Intel (BMG)
  ;; where the GPU is detected — real Intel regressions are not masked.
  (when (and (string-equal (symbol-name backend) "L0")
             (not (%intel-l0-gpu-available-p)))
    (format t "SKIP (Intel L0 GPU not available — mirrors the CUDA nvcc skip-gate)~%")
    (return-from run-spec-with-hoist :skipped))
  (let* ((hoist-arg (format nil "--hoist=~a" backend))
         (bin (get-binary-path))
         (args (append (mapcar #'uiop:native-namestring bc-files)
                       (list hoist-arg
                             (format nil "--log-level=~a" cl-user::*log-level*))
                       ;; Endeavor 126: forward the denormal mode (HOIST-DENORMAL directive)
                       ;; so an on-metal test can observe flush-to-zero vs preserve.
                       (when *compile-denormal-handling*
                         (list (format nil "--denormal-handling=~a"
                                       (string-downcase (symbol-name *compile-denormal-handling*)))))
                       ;; Endeavor 128: forward the precision mode (HOIST-PRECISION directive)
                       ;; so an on-metal test can exercise the fast native_* transcendental path.
                       (when *compile-math-precision*
                         (list (format nil "--math-precision=~a"
                                       (string-downcase (symbol-name *compile-math-precision*)))))
                       ;; Endeavor 130: forward the SELECTED hardware profile
                       ;; (HOIST-HARDWARE-PROFILE directive) so the metacrisp carries
                       ;; it and the launcher uses its :compute-units for grid sizing.
                       (when *compile-hardware-profile*
                         (list (format nil "--hardware-profile=~a" *compile-hardware-profile*)))
                       ;; Endeavor 137: forward HOIST-ARCH so a :block (TMA) kernel passes the
                       ;; sm_90+ gate at hoist time and emits the sm_90a PTX + CUtensorMap path.
                       (let ((arch (parse-hoist-arch (extract-test-directives file))))
                         (when arch (list (format nil "--ir-target-arch=~a" arch))))
                       ;; Endeavour 190: the dogfood launcher -- embed the source, compile it at run
                       ;; time through the C API.  L0 only (the CUDA hoister has no source mode yet).
                       ;; (never with foreign .bc libraries: a launcher cannot embed those)
                       (when (and (string-equal (symbol-name backend) "L0")
                                  (null bc-files)
                                  (%hoist-kernel-source-p file))
                         (list "--hoist-kernel=source"))
                       (list (uiop:native-namestring file))))
         (file-ext (if (string-equal (symbol-name backend) "CUDA") "cu" "cpp")))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output))
      (if (zerop exit-code)
          (let ((base-name (pathname-name file)))
            (remove-if-not
                (lambda (path) (alexandria:starts-with-subseq base-name (pathname-name path)))
                (directory (make-pathname :name :wild
                                          :type file-ext
                                          :defaults file))))
          (progn
           (format *error-output* "FAIL (Hoist Compilation failed with exit code ~a)~%~a~%" exit-code error-output)
           nil)))))

;;; L0 Validators for TEST-HOIST directives

;; tests/run-specs.lisp -- NEW (endeavour 190)
(defun %compile-api-link-args ()
  "The clang arguments that let a launcher call the compile API: its header and its import library
   (bin/libcrisp.dll.a on Windows, bin/libcrisp.so elsewhere), or NIL when the library is not
   built (bash c-api/build.sh)."
  (let* ((root (uiop:getcwd))
         (include (merge-pathnames "c-api/include/" root))
         (lib (merge-pathnames (if (uiop:os-windows-p) "bin/libcrisp.dll.a" "bin/libcrisp.so") root)))
    (when (probe-file lib)
      (list "-I" (uiop:native-namestring include) (uiop:native-namestring lib)))))

;; tests/run-specs.lisp -- NEW (endeavour 190)
(defun %run-launcher-with-bin-on-path (exe-path)
  "Runs the launcher EXE-PATH with <repo>/bin prepended to ITS PATH -- a compile-API launcher must
   find crisp.dll (Windows) at run time, and crisp.dll finds crisp-compile beside itself.  The
   runner's OWN environment is never modified: the child gets an explicit :environment (setenv in a
   long-lived runner was a suspect in an unexplained crash late in a full pass).
   Returns (values STDOUT STDERR EXIT-CODE), like uiop:run-program with :output :string."
  (let* ((bin (uiop:native-namestring (merge-pathnames "bin/" (uiop:getcwd))))
         (sep (if (uiop:os-windows-p) ";" ":"))
         (env (loop for e in (sb-ext:posix-environ)
                    collect (if (and (> (length e) 5) (string-equal "PATH=" e :end2 5))
                                (format nil "~a~a~a~a" (subseq e 0 5) bin sep (subseq e 5))
                                e)))
         (out (make-string-output-stream))
         (err (make-string-output-stream))
         (proc (sb-ext:run-program (uiop:native-namestring exe-path) nil
                                   :environment env :search nil :wait t
                                   :output out :error err)))
    (values (get-output-stream-string out) (get-output-stream-string err)
            (sb-ext:process-exit-code proc))))

;; tests/run-specs.lisp -- REPLACES validate-l0-host-run (endeavour 190: a source-mode launcher links the compile API library)
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
          (let* ((exe-path (make-pathname :type "exe" :defaults cpp))
                 ;; Endeavour 190: a --hoist-kernel=source launcher calls the compile API
                 (api-p (search "#include \"crisp.h\"" (uiop:read-file-string cpp)))
                 (api-args (when api-p (%compile-api-link-args))))
            (when (and api-p (null api-args))
              (format t "FAIL: ~a needs the compile API library -- build it: bash c-api/build.sh~%" (file-namestring cpp))
              (return-from validate-l0-host-run nil))
            ;; 1. Compile & Link
            (multiple-value-bind (output error-output exit-code)
                (uiop:run-program
                  (append
                   (list (uiop:native-namestring clang-exe)
                         (uiop:native-namestring cpp)
                         "-I" (namestring l0-include))
                   api-args
                   (list (uiop:native-namestring ze-loader)
                         "-static"
                         "-o" (uiop:native-namestring exe-path)))
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
                       (if api-p
                           (%run-launcher-with-bin-on-path exe-path)
                           (uiop:run-program (uiop:native-namestring exe-path)
                             :output :string :error-output :string :ignore-error-status t))
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
                               (return-from validate-l0-host-run nil)))
                         (progn
                          (format t "FAIL: ~a execution failed (Code ~a)~%Error: ~a~%"
                            (file-namestring exe-path) run-code run-err)
                          (return-from validate-l0-host-run nil)))))))))
        t)))


