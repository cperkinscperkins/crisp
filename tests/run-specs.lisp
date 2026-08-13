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
              :off)))

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

;; Endeavor 103 (phase 2): pure CL parser, no foreign deps -- safe to load
;; unconditionally.  The OpenCL runner that consumes parsed specs is loaded
;; lazily via %vad-ensure-runner-loaded when --verify-autodiff is active.
(load (merge-pathnames "tests/verify-autodiff-parse.lisp" (uiop:getcwd)))

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
(defvar *compile-math-precision* nil
  "Endeavor 126: --math-precision mode (:fast / :ieee / nil) for a precision
   TEST-WITH run; forwarded to initialize-compiler by compile-crisp-file-to-ir-string.")
(defvar *compile-force-math-precision* nil
  "Endeavor 126: --force-math-precision mode (:fast / :ieee / nil) — the hard lock
   (force > with-precision > declaim > math). Forwarded to initialize-compiler.")
(defvar *compile-denormal-handling* nil
  "Endeavor 126: effective denormal mode (:ftz / :preserve / nil) for a precision
   TEST-WITH run; forwarded to initialize-compiler by compile-crisp-file-to-ir-string.")
(defvar *compile-hardware-profile* nil
  "Endeavor 130: hardware-profile name (string / nil) to SELECT via --hardware-profile
   during a hoist run (HOIST-HARDWARE-PROFILE directive), so the metacrisp carries the
   active profile and the CUDA launcher uses its :compute-units for grid sizing.")
(defvar *test-filter* nil)
(defvar *only-unit-tests* nil)
(defvar *skip-unit-tests* nil)
(defvar *keep-work* nil)
(defvar *no-quit* nil)

(defvar *vad-runner-status* nil
  "Cached load state of tests/verify-autodiff-runner.lisp.
   NIL -> not yet attempted; :ready -> runner loaded;
   :unavailable -> load failed (likely no OpenCL ICD).
   Endeavor 103.  VERIFY-AUTODIFF directives are processed during the
   --differentiate pass; this caches the load result so OpenCL-less hosts
   skip cleanly after one warning.")


(defvar *compile-runtime-checks* nil
  "When T, pass :runtime-checks t to initialize-compiler in the in-process runner.")
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
                 (when *compile-differentiate* '("--differentiate"))
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


;;; ============================================================
;;; Endeavor 122 (FFI) harness.
;;;
;;; An FFI spec carries an `;; FFI-LINK: <source>.c` directive. Because the
;;; .bc linking lives in the compiler binary (main.lisp), not the in-process
;;; path, FFI specs are run by: building the C source to a .bc for each
;;; requested device target (clang) and invoking crisp-compile.exe with the .bc
;;; linked. Targets come from the spec's TEST-WITH[--ir-target=...] directives.
;;; ============================================================

(defun parse-ffi-link (directive-lines)
  "Parse `FFI-LINK: <c-source>` from header directives. Returns the C source
   filename string (e.g. \"add.c\"), or NIL if absent."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "FFI-LINK:")
        (return (string-trim '(#\Space #\Tab #\Return #\Newline)
                             (subseq trimmed (length "FFI-LINK:"))))))))

(defun %ffi-requested-targets (directives)
  "Device targets (\"ptx\"/\"spv\") requested via TEST-WITH[--ir-target=...].
   Returns NIL when none are specified."
  (let ((targets '()))
    (dolist (run (parse-test-with directives))
      (dolist (flag (first run))
        (cond ((string= flag "--ir-target=ptx") (pushnew "ptx" targets :test #'string=))
              ((string= flag "--ir-target=spv") (pushnew "spv" targets :test #'string=)))))
    (nreverse targets)))

(defun %clang-available-p ()
  "T if a `clang` is on PATH (needed to build FFI .bc artifacts)."
  (ignore-errors
    (zerop (nth-value 2 (uiop:run-program '("clang" "--version")
                                          :ignore-error-status t
                                          :output nil :error-output nil)))))

(defun %ffi-build-bc (c-path target)
  "Compile C-PATH to a .bc for TARGET (\"ptx\"|\"spv\") via clang. Returns the
   .bc pathname on success, NIL on failure (logging clang's stderr)."
  (let* ((triple (cond ((string= target "ptx") "nvptx64-nvidia-cuda")
                       ((string= target "spv") "spir64-unknown-unknown")
                       (t (error "FFI: unknown target ~a" target))))
         (bc-path (make-pathname :name (format nil "~a_~a" (pathname-name c-path) target)
                                 :type "bc" :defaults c-path)))
    (multiple-value-bind (out err code)
        (uiop:run-program (list "clang" (format nil "--target=~a" triple)
                                "-emit-llvm" "-c"
                                (uiop:native-namestring c-path)
                                "-o" (uiop:native-namestring bc-path))
          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore out))
      (if (and (zerop code) (probe-file bc-path))
          bc-path
          (progn
           (format *error-output* "~&FFI: clang failed building ~a for ~a (exit ~a)~%~a~%"
                   c-path target code err)
           nil)))))

(defun %ffi-expand-env (str)
  "Expand $VAR and ${VAR} occurrences in STR using environment variables (unset
   -> empty). Used to resolve prebuilt-library paths like
   $CUDA_HOME/nvvm/libdevice/libdevice.10.bc."
  (let ((result str))
    ;; ${VAR}
    (loop for start = (search "${" result)
          while start do
            (let ((end (position #\} result :start start)))
              (unless end (return))
              (let ((val (or (uiop:getenv (subseq result (+ start 2) end)) "")))
                (setf result (concatenate 'string (subseq result 0 start) val (subseq result (1+ end)))))))
    ;; $VAR
    (let ((scan 0))
      (loop for start = (position #\$ result :start scan)
            while start do
              (let* ((rest (subseq result (1+ start)))
                     (vend (or (position-if-not (lambda (c) (or (alphanumericp c) (char= c #\_))) rest)
                               (length rest)))
                     (val (or (uiop:getenv (subseq rest 0 vend)) "")))
                (setf result (concatenate 'string (subseq result 0 start) val (subseq rest vend)))
                (setf scan (+ start (length val))))))
    result))

(defun %ffi-resolve-prebuilt-bc (source crisp-file)
  "Resolve a pre-built .bc FFI-LINK SOURCE (possibly containing $ENV vars) to an
   existing absolute path, or NIL if it cannot be found. Relative paths are taken
   relative to the spec's directory."
  (let ((expanded (%ffi-expand-env source)))
    ;; Must resolve to a concrete .bc path (guards empty/unset env expansions,
    ;; which would otherwise merge to the spec directory).
    (when (uiop:string-suffix-p expanded ".bc")
      (let* ((p (ignore-errors (pathname expanded)))
             (path (cond ((null p) nil)
                         ((uiop:absolute-pathname-p p) p)
                         (t (merge-pathnames expanded
                                             (make-pathname :directory (pathname-directory crisp-file)))))))
        (when (and path (probe-file path)) (truename path))))))

(defun run-spec-ffi-runs (crisp-file directives bc-fn delete-bc-p)
  "Shared FFI run loop. BC-FN maps a target string -> the .bc path to link (or
   NIL on failure). DELETE-BC-P: clean up the returned .bc afterward (true for
   clang-built sources; false for prebuilt libs we must not delete). Returns T
   if all runs pass."
  (let* ((requested (%ffi-requested-targets directives))
         (hoist-dirs (parse-test-hoist directives))
         (requested (if (and (null requested) (null hoist-dirs))
                        '("ptx")
                        requested))
         ;; Endeavor 128 (Phase 3): a HOIST-PRECISION directive selects fast vs ieee
         ;; for the FFI compile-check + hoist (e.g. fast PTX transcendentals ->
         ;; __nv_fast_*). Bound here since FFI specs bypass run-spec-file's hoist path.
         (*compile-math-precision* (or (parse-hoist-precision directives) *compile-math-precision*))
         ;; Drop spv compile-checks on a machine that cannot do them, exactly as the other
         ;; SPIR-V entry points do.  (L0 hoist is skipped separately via SKIP_L0_HOIST.)
         ;;
         ;; Endeavor 144: this used to test SKIP_SPIRV_TESTS *only*, so on a CUDA-only box —
         ;; where bin/ is gitignored and llvm-spirv is simply absent — the 7 FFI specs FAILED
         ;; with the translator's exit 127 instead of skipping.  Now it also auto-detects, so
         ;; the harness needs no env var to notice what the machine can do.  This was the fifth
         ;; SPIR-V entry point; the other four are run-single-spec-pass,
         ;; run-spec-compile-with-pass, run-spec-expect-stderr-pass and run-spec-with-hoist.
         (skip-spv (or (and (uiop:getenv "SKIP_SPIRV_TESTS") t)
                       (not (spirv-toolchain-available-p))))
         (compile-targets (if skip-spv
                              (remove "spv" requested :test #'string=)
                              requested))
         (bin (get-binary-path))
         (all-ok t)
         (artifacts '()))

    (when (and skip-spv (member "spv" requested :test #'string=))
      (format t "~&Running Spec: ~a (FFI[spv])... SKIP (no SPIR-V toolchain on this machine)~%"
              (pathname-name crisp-file)))

    ;; 1. Compile-check runs (TEST-WITH[--ir-target=...]).
    (dolist (target compile-targets)
      (format t "~&Running Spec: ~a (FFI[~a])... " (pathname-name crisp-file) target)
      (finish-output)
      (let ((bc (funcall bc-fn target)))
        (if (null bc)
            (progn (format t "FAIL (no .bc)~%") (setf all-ok nil))
            (let* ((out-type (if (string= target "spv") "spv" "ptx"))
                   ;; Endeavor 123 (FFI-AD): under --differentiate the binary emits
                   ;; the backward kernel as <name>_grad.<type> (mirrors line ~608).
                   (out-name (if *compile-differentiate*
                                 (format nil "~a_grad" (pathname-name crisp-file))
                                 (pathname-name crisp-file)))
                   (out-path (make-pathname :name out-name
                                            :type out-type :defaults crisp-file)))
              (when delete-bc-p (push bc artifacts))
              (when (probe-file out-path) (delete-file out-path))
              (multiple-value-bind (out err code)
                  (uiop:run-program (append
                                     (list (uiop:native-namestring bin)
                                           (uiop:native-namestring bc)
                                           (uiop:native-namestring crisp-file)
                                           (format nil "--ir-target=~a" target)
                                           (format nil "--log-level=~a" cl-user::*log-level*))
                                     ;; Endeavor 123: forward the global differentiate
                                     ;; flag so FFI specs compile their backward kernel
                                     ;; (with the .bc linked) like any other spec.
                                     (when *compile-differentiate* (list "--differentiate"))
                                     ;; Endeavor 128 (Phase 3): forward the precision mode
                                     ;; (HOIST-PRECISION) so the compile-check exercises the
                                     ;; fast PTX path (__nv_fast_*).
                                     (when *compile-math-precision*
                                       (list (format nil "--math-precision=~a"
                                                     (string-downcase (symbol-name *compile-math-precision*))))))
                    :output :string :error-output :string :ignore-error-status t)
                (declare (ignore out))
                (cond
                 ((not (zerop code))
                  (format t "FAIL (compile exit ~a)~%~a~%" code err) (setf all-ok nil))
                 ((not (probe-file out-path))
                  (format t "FAIL (no ~a produced)~%" out-type) (setf all-ok nil))
                 (t (format t "PASS~%") (push out-path artifacts))))))))

    ;; 2. On-metal hoist runs (TEST-HOIST[backend]: validator), with the .bc
    ;; linked. Skipped under --differentiate (foreign calls aren't AD-able).
    (when (and hoist-dirs (not *compile-differentiate*))
      (dolist (hd hoist-dirs)
        (let* ((backend (car hd))
               (validator-name (cdr hd))
               (target (if (string-equal (symbol-name backend) "CUDA") "ptx" "spv")))
          (format t "~&Running Spec: ~a (FFI-Hoist[~a] -> ~a)... "
                  (pathname-name crisp-file) backend validator-name)
          (finish-output)
          (let ((bc (funcall bc-fn target)))
            (if (null bc)
                (progn (format t "FAIL (no .bc)~%") (setf all-ok nil))
                (progn
                 (when delete-bc-p (push bc artifacts))
                 (let ((cpp-files (run-spec-with-hoist crisp-file backend (list bc))))
                   (cond
                    ((eq cpp-files :skipped) nil) ; SKIP counts as pass
                    ((null cpp-files) (setf all-ok nil))
                    (t (let ((vsym (find-symbol (string-upcase validator-name) :crisp.spec-runner)))
                         (if (and vsym (fboundp vsym))
                             (unless (funcall vsym crisp-file cpp-files) (setf all-ok nil))
                             (progn (format t "FAIL (Validator ~a not found)~%" validator-name)
                                    (setf all-ok nil)))))))))))))

    ;; Cleanup: built .bc (if delete-bc-p) plus this spec's hoist/output artifacts.
    (unless *keep-work*
      (dolist (a artifacts) (when (probe-file a) (ignore-errors (delete-file a))))
      (let ((base-name (pathname-name crisp-file))
            (dir (pathname-directory crisp-file)))
        (dolist (type '("cpp" "cu" "exe" "spv" "ptx" "metacrisp"))
          (dolist (f (directory (make-pathname :directory dir :name :wild :type type :defaults crisp-file)))
            (when (and (stringp (pathname-name f))
                       (uiop:string-prefix-p base-name (pathname-name f)))
              (ignore-errors (delete-file f)))))))
    all-ok))

(defun run-spec-ffi (crisp-file source directives)
  "Run an FFI spec. SOURCE is the FFI-LINK value: either a co-located C file
   compiled per target via clang, OR a pre-built .bc (possibly with $ENV vars,
   e.g. $CUDA_HOME/nvvm/libdevice/libdevice.10.bc) linked directly. A missing
   prebuilt lib or an unavailable clang SKIPs (as a pass)."
  ;; Treat as a pre-built .bc when the source ends in .bc (raw or after $ENV
  ;; expansion) or names an env var ($...) — a .c source has neither.
  (if (or (uiop:string-suffix-p source ".bc")
          (uiop:string-suffix-p (%ffi-expand-env source) ".bc")
          (find #\$ source))
      ;; --- Pre-built .bc (e.g. libdevice via $CUDA_HOME) ---
      (let ((bc (%ffi-resolve-prebuilt-bc source crisp-file)))
        (if (null bc)
            (progn (format t "~&Running Spec: ~a (FFI)... SKIP (prebuilt library not found: ~a)~%"
                           (pathname-name crisp-file) source)
                   t)
            (run-spec-ffi-runs crisp-file directives
                               (lambda (target) (declare (ignore target)) bc) nil)))
      ;; --- C source compiled per target via clang ---
      (let ((c-path (make-pathname :directory (pathname-directory crisp-file)
                                   :name (pathname-name source)
                                   :type (or (pathname-type source) "c")
                                   :defaults crisp-file)))
        (cond
         ((not (%clang-available-p))
          (format t "~&Running Spec: ~a (FFI)... SKIP (clang unavailable)~%" (pathname-name crisp-file))
          t)
         ((not (probe-file c-path))
          (format t "~&Running Spec: ~a (FFI)... FAIL (C source ~a not found)~%"
                  (pathname-name crisp-file) c-path)
          nil)
         (t (run-spec-ffi-runs crisp-file directives
                               (lambda (target) (%ffi-build-bc c-path target)) t))))))

(defun run-spec-file (file)
  (let ((directives (extract-test-directives file))
        (all-passed t))

    ;; Check if we should skip this file entirely based on current flags
    (when (parse-skip-with directives)
          (format t "~&Running Spec: ~a (Default)... SKIP (Skipped due to SKIP-WITH matches active flags)~%" (pathname-name file))
          (return-from run-spec-file :skipped))

    ;; Endeavor 122 (FFI): specs with an FFI-LINK directive are run exclusively
    ;; through the FFI path (build .bc + link via the binary per device target).
    ;; The normal in-process runs don't link the .bc, so they're skipped here.
    (let ((ffi-source (parse-ffi-link directives)))
      (when ffi-source
        (return-from run-spec-file (run-spec-ffi file ffi-source directives))))

    ;; 1. Default Run (Current Global Flags)
    ;; SKIP-DEFAULT-PASS opts a spec OUT of the no-flags (GENERIC) run, validating it
    ;; ONLY through its TEST-WITH target passes.  For target-specific features with no
    ;; valid GENERIC lowering — e.g. an MMA kernel that emits an NVVM/PTX-only intrinsic
    ;; (@llvm.nvvm.mma.*) which the host GENERIC validator can't compile.
    (if (parse-skip-default-pass directives)
        (format t "~&Running Spec: ~a (Default)... SKIP (SKIP-DEFAULT-PASS: target-specific spec)~%" (pathname-name file))
        (progn
          (format t "~&Running Spec: ~a (Default)... " (pathname-name file))
          (finish-output) ;; Ensure "Running Spec..." is printed before runner output
          (unless (run-single-spec-pass file '())
            (setf all-passed nil))))

    ;; 2. Extra Runs (TEST-WITH flags)
    (let ((extra-runs (parse-test-with directives)))
      (dolist (run extra-runs)
        (destructuring-bind (flags &optional validator) run
          (format t "~&Running Spec: ~a (Extra ~a~@[ : ~a~])... " (pathname-name file) flags validator)
          (finish-output)
          (unless (run-single-spec-pass file flags validator)
            (setf all-passed nil)))))

    ;; 2.5 Expect-Stderr Runs (EXPECT-STDERR[flags]: "substring") -- Endeavor 126.
    ;; Compile with the flags and assert a warning appears on stderr. For CLI
    ;; warnings that don't change the IR (so a TEST-WITH validator can't see them).
    (dolist (run (parse-expect-stderr directives))
      (destructuring-bind (flags . substr) run
        (format t "~&Running Spec: ~a (Expect-Stderr ~a : ~s)... " (pathname-name file) flags substr)
        (finish-output)
        (unless (run-spec-expect-stderr-pass file flags substr)
          (setf all-passed nil))))

    ;; 2.6 Compile-With Runs (COMPILE-WITH[flags]: PASS | FAIL "substr") -- Endeavor 130.
    ;; Compile via the binary with FLAGS active and assert the outcome (exit 0, or
    ;; exit!=0 + substring).  The flag-carrying test path for --hardware-profile
    ;; validation (bounds / not-found), which the negative runner can't inject.
    (dolist (run (parse-compile-with directives))
      (destructuring-bind (flags expect substr) run
        (format t "~&Running Spec: ~a (Compile-With ~a : ~a~@[ ~s~])... " (pathname-name file) flags expect substr)
        (finish-output)
        (unless (run-spec-compile-with-pass file flags expect substr)
          (setf all-passed nil))))

    ;; 3. Hoist Tests (TEST-HOIST[backend]: validator)
    (let ((hoist-directives (parse-test-hoist directives)))
      (if (and hoist-directives *compile-differentiate*)
          (format t "~&Running Spec: ~a (Hoist)... SKIP (--differentiate active)~%" (pathname-name file))
          (dolist (directive hoist-directives)
            (let ((backend (car directive))
                  (validator-name (cdr directive)))
              (format t "~&Running Spec: ~a (Hoist[~a] -> ~a)... " (pathname-name file) backend validator-name)
              (finish-output)
              (let* ((*compile-denormal-handling* (or (parse-hoist-denormal directives)
                                                      *compile-denormal-handling*))
                     (*compile-math-precision* (or (parse-hoist-precision directives)
                                                   *compile-math-precision*))
                     (*compile-hardware-profile* (or (parse-hoist-hardware-profile directives)
                                                     *compile-hardware-profile*))
                     (hoist-result (run-spec-with-hoist file backend)))
                (unless (eq hoist-result :skipped)
                  (let ((cpp-files hoist-result))
                    ;; Use find-symbol to look up the existing function symbol
                    (let ((validator-sym (find-symbol (string-upcase validator-name) :crisp.spec-runner)))
                      (if (fboundp validator-sym)
                          (unless (funcall validator-sym file cpp-files)
                            (setf all-passed nil))
                          (progn
                           (format t "FAIL (Validator ~a not found)~%" validator-name)
                           (setf all-passed nil))))))))

            ;; Cleanup Hoist Files on Success
            (when (and all-passed (not *keep-work*))
                  (let* ((base-name (pathname-name file))
                         (dir (pathname-directory file))
                         (cpp-files (directory (make-pathname :directory dir :name :wild :type "cpp" :defaults file)))
                         (cu-files  (directory (make-pathname :directory dir :name :wild :type "cu"  :defaults file)))
                         (exe-files (directory (make-pathname :directory dir :name :wild :type "exe" :defaults file)))
                         (spv-files (directory (make-pathname :directory dir :name :wild :type "spv" :defaults file)))
                         (ptx-files (directory (make-pathname :directory dir :name :wild :type "ptx" :defaults file)))
                         (meta-files (directory (make-pathname :directory dir :name :wild :type "metacrisp" :defaults file)))
                         (all-files (append cpp-files cu-files exe-files spv-files ptx-files meta-files)))
                    (dolist (f all-files)
                      (when (and (stringp (pathname-name f))
                                 (uiop:string-prefix-p base-name (pathname-name f)))
                            (delete-file f))))))))

    ;; 4. Verify-Autodiff (VERIFY-AUTODIFF: ...) -- endeavor 103
    ;; Runs only when --differentiate is the active pass: the directive is
    ;; one more check layered onto the AD machinery, so it fires when AD is
    ;; being exercised.  Untagged specs skip the check at parse time (nil).
    (when *compile-differentiate*
      (let ((vad-spec (cl-user::parse-verify-autodiff directives)))
        (when vad-spec
          (format t "~&Running Spec: ~a (Verify-Autodiff)... " (pathname-name file))
          (finish-output)
          (unless (run-verify-autodiff-pass file vad-spec)
            (setf all-passed nil)))))

    all-passed))


(defun run-spec-runtime-checks-pass (file validator)
  "Compiles FILE with *runtime-checks-enabled* = T, then calls VALIDATOR(file ir-string).
   Called when TEST-WITH[--runtime-checks] is present in the spec directives."
  (handler-case
      (let ((*compile-runtime-checks* t))
        (let ((ir-string (compile-crisp-file-to-ir-string file)))
          (if validator
              (let* ((validator-str (if (symbolp validator)
                                        (symbol-name validator)
                                        (string validator)))
                     (sym (find-symbol (string-upcase validator-str) :crisp.spec-runner)))
                (if (and sym (fboundp sym))
                    (if (funcall sym file ir-string)
                        (progn (format t "PASS~%") t)
                        (progn (format *error-output* "FAIL (Validator ~a)~%" validator) nil))
                    (progn (format *error-output* "FAIL (Validator ~a not found)~%" validator) nil)))
              (progn (format t "PASS~%") t))))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))




(defun %precision-flag-value (flags prefix)
  "Return the :fast / :ieee mode for flag PREFIX (e.g. \"--math-precision=\") in
   FLAGS, or NIL if absent. Force and math are parsed SEPARATELY so the compiler
   knows which is the hard lock (declaim/with-precision precedence)."
  (let ((v (loop for f in flags
                 when (and (>= (length f) (length prefix))
                           (string= prefix (subseq f 0 (length prefix))))
                 return (subseq f (length prefix)))))
    (cond ((null v) nil)
          ((string-equal v "fast") :fast)
          ((string-equal v "ieee") :ieee)
          (t nil))))

(defun %denormal-mode-from-flags (flags)
  "Extract the denormal mode (:ftz / :preserve / nil) from FLAGS."
  (let ((v (loop with prefix = "--denormal-handling="
                 for f in flags
                 when (and (>= (length f) (length prefix))
                           (string= prefix (subseq f 0 (length prefix))))
                 return (subseq f (length prefix)))))
    (cond ((null v) nil)
          ((string-equal v "ftz") :ftz)
          ((string-equal v "preserve") :preserve)
          (t nil))))

(defun run-spec-precision-pass (file flags validator)
  "Compiles FILE with the precision + denormal flags active, then hands the LLVM IR
   to VALIDATOR. Used by TEST-WITH[--force-math-precision=KEY] / [--math-precision=KEY]
   / [--denormal-handling=KEY] (Endeavor 126). Modes are parsed from FLAGS and
   forwarded to the compiler via the *compile-* specials -> initialize-compiler."
  (handler-case
      (let* ((math   (%precision-flag-value flags "--math-precision="))
             (force  (%precision-flag-value flags "--force-math-precision="))
             (denorm (%denormal-mode-from-flags flags))
             (*compile-math-precision* (or math *compile-math-precision*))
             (*compile-force-math-precision* (or force *compile-force-math-precision*))
             (*compile-denormal-handling* (or denorm *compile-denormal-handling*)))
      (let ((ir-string (compile-crisp-file-to-ir-string file)))
        (if validator
            (let ((sym (find-symbol (string-upcase (string validator)) :crisp.spec-runner)))
              (if (and sym (fboundp sym))
                  (if (funcall sym file ir-string)
                      (progn (format t "PASS~%") t)
                      (progn (format *error-output* "FAIL (Validator ~a)~%" validator) nil))
                  (progn (format *error-output* "FAIL (Validator ~a not found)~%" validator) nil)))
            (progn (format t "PASS~%") t))))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

;;; -------------------------------------------------------------------
;;; Endeavor 144 — SPIR-V toolchain availability, for the FLAG-CARRYING directives.
;;;
;;; `run-single-spec-pass` honors SKIP_SPIRV_TESTS (see the check near its top), but
;;; COMPILE-WITH / EXPECT-STDERR invoke the binary directly with their own flags and had no
;;; such guard.  On a CUDA-only box (a runpod H100) `bin/` is gitignored, so `llvm-spirv` is
;;; absent and EVERY `--ir-target=spv` compile dies with exit 127 — which surfaced as 14
;;; "failures" that were really an environment gap (2026-07-28 pod run).
;;;
;;; Detected rather than gated on SKIP_SPIRV_TESTS: an env var has to be remembered on every
;;; new pod, whereas probing is self-correcting.  The explicit env var is still honored, so a
;;; box WITH the toolchain can still opt out.  Same spirit as the L0-hoist and FFI skips.
;;; -------------------------------------------------------------------

(defvar *spirv-toolchain-available* :unknown
  "Cached tri-state: :unknown until first probed, then T / NIL.  Probing runs a process, so
   it is done once per runner invocation.")

(defun spirv-toolchain-available-p ()
  "T when the SPIR-V translator can actually be INVOKED (not merely named).  Probes
   `llvm-spirv --version` through the compiler's own resolver, so it honors the same
   bin/-then-PATH search and CRISP_LLVM_SPIRV override the real compile path uses.  Any
   failure to launch (missing file, not on PATH, not executable) reads as unavailable."
  (when (eq *spirv-toolchain-available* :unknown)
    (setf *spirv-toolchain-available*
          (handler-case
              (let ((tool (crisp.compiler::resolve-tool-executable "llvm-spirv")))
                (and tool
                     (zerop (nth-value 2
                              (uiop:run-program (list (uiop:native-namestring tool) "--version")
                                                :output nil :error-output nil
                                                :ignore-error-status t)))))
            (error () nil))))
  *spirv-toolchain-available*)

(defun %spv-flags-unsupported-p (flags)
  "T when FLAGS ask for a SPIR-V compile that this machine cannot perform — so the caller
   should SKIP rather than FAIL.  Honors SKIP_SPIRV_TESTS as an explicit override."
  (and (member "--ir-target=spv" flags :test #'string=)
       (or (and (uiop:getenv "SKIP_SPIRV_TESTS") t)
           (not (spirv-toolchain-available-p)))))

(defun run-spec-expect-stderr-pass (file flags expected-substring)
  "Endeavor 126: compile FILE through the binary with FLAGS active; PASS iff the
   compile SUCCEEDS (exit 0) AND EXPECTED-SUBSTRING appears on stderr. Used to lock
   in CLI *warnings* (force-override, fast+preserve) which are emitted with a raw
   `format` to *error-output* (not log4cl, so `--log-level=off` does not suppress
   them) and which leave the IR unchanged — invisible to an IR-grep validator.
   Runs the compile itself (independent of --differentiate). No --ir-target is
   passed, so the binary emits generic LLVM IR to stdout (no artifact file to clean
   up); exit 0 confirms the warning is non-fatal, and the warning fires during CLI
   parsing regardless of target."
  (when (%spv-flags-unsupported-p flags)
    (format t "SKIP (no SPIR-V toolchain on this machine)~%")
    (return-from run-spec-expect-stderr-pass t))
  (let* ((bin (get-binary-path))
         (args (append flags
                       (list (format nil "--log-level=~a" cl-user::*log-level*)
                             (uiop:native-namestring file)))))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (compile exit ~a; expected success + stderr ~s)~%~a~%"
                 exit-code expected-substring error-output)
         nil)
       ((search expected-substring error-output)
         (format t "PASS (stderr: ~s)~%" expected-substring)
         t)
       (t
         (format *error-output* "FAIL (stderr missing ~s)~%--- got stderr ---~%~a~%"
                 expected-substring error-output)
         nil)))))

(defun run-spec-compile-with-pass (file flags expect substring)
  "Endeavor 130: compile FILE through the binary with FLAGS active and assert the
   outcome.  EXPECT is :pass (require exit 0) or :fail (require exit != 0 AND
   SUBSTRING on stderr).  This is the flag-carrying test path for hardware-profile
   validation — the negative runner can't inject a --hardware-profile flag, and the
   check fires during analysis (so no --ir-target is needed, hence no artifact).

   Endeavor 144: a spv-targeted run SKIPs on a machine with no SPIR-V translator (see
   %spv-flags-unsupported-p) instead of failing with the toolchain's exit 127."
  (when (%spv-flags-unsupported-p flags)
    (format t "SKIP (no SPIR-V toolchain on this machine)~%")
    (return-from run-spec-compile-with-pass t))
  (let* ((bin (get-binary-path))
         (args (append flags
                       (list (format nil "--log-level=~a" cl-user::*log-level*)
                             (uiop:native-namestring file)))))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output))
      (ecase expect
        (:pass
         (if (zerop exit-code)
             (progn (format t "PASS (compiled)~%") t)
             (progn (format *error-output* "FAIL (expected success with ~{~a~^ ~}, exit ~a)~%~a~%"
                            flags exit-code error-output)
                    nil)))
        (:fail
         (cond
          ((zerop exit-code)
            (format *error-output* "FAIL (expected failure with ~{~a~^ ~} + ~s, but compile SUCCEEDED)~%"
                    flags substring)
            nil)
          ((search substring error-output)
            (format t "PASS (failed with ~s)~%" substring)
            t)
          (t
            (format *error-output* "FAIL (failed but stderr missing ~s)~%--- got stderr ---~%~a~%"
                    substring error-output)
            nil)))))))

(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active.
   Extended: --runtime-checks routes to run-spec-runtime-checks-pass;
   --*-math-precision=KEY routes to run-spec-precision-pass."
  ;; NEW: --runtime-checks is handled as a dedicated path — compile with
  ;; runtime assertions enabled and call the validator with the IR string.
  (when (member "--runtime-checks" flags :test #'string=)
    (format t "(RT-Checks)... ")
    (return-from run-single-spec-pass
      (run-spec-runtime-checks-pass file validator)))

  ;; Endeavor 126: precision runs — compile and hand the IR to a precision validator.
  (when (some (lambda (f) (or (search "--force-math-precision=" f)
                              (search "--math-precision=" f)
                              (search "--denormal-handling=" f)))
              flags)
    (format t "(Precision)... ")
    (return-from run-single-spec-pass
      (run-spec-precision-pass file flags validator)))

  ;; Original dispatch (unchanged from base run-specs.lisp):
  (let ((*use-binary*         (or *use-binary*         (member "--use-binary"    flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass"  flags :test #'string=)))
        (*compile-debug*       (or *compile-debug*       (member "--debug"        flags :test #'string=)))
        (*compile-differentiate* (or *compile-differentiate* (member "--differentiate" flags :test #'string=)))
        ;; Endeavor 137: honor --ir-target-arch=<ID> in TEST-WITH flags so the in-process
        ;; PTX/SPV compile gates + compute-capability match the CLI (else :block gates on sm_80).
        (crisp.compiler::*ir-target-arch*
          (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
            (if af
                (intern (string-upcase (subseq af (length "--ir-target-arch="))) :keyword)
                crisp.compiler::*ir-target-arch*)))
        (emit-metadata (member "--metadata" flags :test #'string=))
        (ir-target (cond
                     ((member "--ir-target=spv"    flags :test #'string=) :spirv)
                     ((member "--ir-target=ptx"    flags :test #'string=) :ptx)
                     ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                     ((member "--metadata"         flags :test #'string=) :spirv)
                     (t nil))))

    ;; Endeavor 144: skip a SPIR-V pass when this machine cannot do one — either because
    ;; SKIP_SPIRV_TESTS says so, or because the translator is not actually invocable (a
    ;; CUDA-only box: bin/ is gitignored, so llvm-spirv is simply absent).  Detection keeps
    ;; the three SPIR-V entry points (here, COMPILE-WITH, EXPECT-STDERR) consistent.
    (when (and (eq ir-target :spirv)
               (or (and (uiop:getenv "SKIP_SPIRV_TESTS") t)
                   (not (spirv-toolchain-available-p))))
      (format t "SKIP (no SPIR-V toolchain on this machine)~%")
      (return-from run-single-spec-pass t))

    (if *use-binary*
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-binary file :validator validator :flags flags))
          ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
          (t (run-spec-binary file)))
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-in-process file :validator validator))
          ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
          (t (run-spec-lisp-loader file))))))




(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string.
   Extended to support *compile-runtime-checks*."
  (let ((*standard-output* (make-broadcast-stream)))
    (let ((crisp.compiler::*struct-name-prefix*
           (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                   (crisp.compiler:initialize-compiler
                    :log-level cl-user::*log-level*
                    :differentiate *compile-differentiate*
                    :runtime-checks *compile-runtime-checks*
                    :math-precision (or *compile-math-precision* :ieee)
                    :force-math-precision *compile-force-math-precision*
                    :denormal-handling (or *compile-denormal-handling* :preserve))
                   (with-open-file (stream filepath)
                     (let ((*package* (find-package :crisp-language)))
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
                      (crisp.compiler:compile-toplevel-form
                       form (list toplevel-index) module builder nil nil nil)
                      (incf toplevel-index)))
                  (crisp.compiler:compile-module forms module builder nil nil nil))
              (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                  (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))))


(defun validate-has-llvm-trap (file ir-string)
  "Validator for TEST-WITH[--runtime-checks]: verifies that llvm.trap
   appears in the generated IR, confirming that r-t-assert forms were
   emitted (not elided) when --runtime-checks is active."
  (declare (ignore file))
  (if (search "llvm.trap" ir-string)
      (progn
        (format t "PASS (llvm.trap found)~%")
        t)
      (progn
        (format t "FAIL: llvm.trap not found in IR (expected from r-t-assert under --runtime-checks)~%")
        nil)))

(defun validate-fast-math (file ir-string)
  "Validator for TEST-WITH[--*-math-precision=fast] (Endeavor 126): FP ops must
   carry per-instruction fast-math flags. LLVM prints `fast` when ALL flags are set,
   otherwise the individual keywords (reassoc/contract/...); a contracted a*b+c may
   also appear as llvm.fmuladd. Any of these confirms fast precision reached the IR."
  (declare (ignore file))
  (let ((ir (string-downcase ir-string)))
    (if (or (search "fmul fast" ir) (search "fadd fast" ir)
            (search "reassoc" ir)   (search "fmuladd" ir))
        (progn (format t "PASS (fast-math flags present)~%") t)
        (progn (format t "FAIL: no fast-math flags on FP ops (expected under fast precision)~%") nil))))

(defun validate-ieee-precision (file ir-string)
  "Validator for TEST-WITH[--*-math-precision=ieee] (Endeavor 126): FP ops must be
   plain — no fast-math flags, no reassoc/contraction — matching strict IEEE. (The
   test kernel's name is neutral, so a bare `fast` substring implies a fast-math flag.)"
  (declare (ignore file))
  (let ((ir (string-downcase ir-string)))
    (if (and (search "fmul float" ir)
             (not (search "fast" ir))
             (not (search "reassoc" ir))
             (not (search "fmuladd" ir)))
        (progn (format t "PASS (plain FP ops, no fast-math)~%") t)
        (progn (format t "FAIL: expected plain fmul/fadd with no fast-math flags~%") nil))))

(defun validate-mixed-fast-ieee (file ir-string)
  "Endeavor 126 pass 5: per-region precision — the IR must contain BOTH a fast FP op
   (`fmul fast`) AND a plain one (`fmul float`), proving with-precision scoped
   precision to just its region while the rest of the kernel used the other mode."
  (declare (ignore file))
  (let ((ir (string-downcase ir-string)))
    (if (and (search "fmul fast" ir) (search "fmul float" ir))
        (progn (format t "PASS (mixed: fast region + plain region coexist)~%") t)
        (progn (format t "FAIL: expected BOTH `fmul fast` and `fmul float` (per-region scoping)~%") nil))))

(defun validate-all-fast (file ir-string)
  "Endeavor 126 pass 5: force override — ALL FP ops fast, none plain (force beats
   with-precision, so an ieee region is compiled fast too)."
  (declare (ignore file))
  (let ((ir (string-downcase ir-string)))
    (if (and (search "fmul fast" ir) (not (search "fmul float" ir)))
        (progn (format t "PASS (all fast — force overrode the region)~%") t)
        (progn (format t "FAIL: expected all `fmul fast`, no plain `fmul float`~%") nil))))

(defun validate-denormal-ftz (file ir-string)
  "Validator for TEST-WITH[--denormal-handling=ftz] (Endeavor 126): the
   `denormal-fp-math` function attribute must select flush-to-zero (preserve-sign)."
  (declare (ignore file))
  (if (search "denormal-fp-math\"=\"preserve-sign" ir-string)
      (progn (format t "PASS (denormal-fp-math = flush-to-zero)~%") t)
      (progn (format t "FAIL: expected denormal-fp-math=preserve-sign (ftz)~%") nil)))

(defun validate-denormal-preserve (file ir-string)
  "Validator for TEST-WITH[--denormal-handling=preserve] (Endeavor 126): the
   `denormal-fp-math` attribute must select strict IEEE (ieee) subnormal handling."
  (declare (ignore file))
  (if (search "denormal-fp-math\"=\"ieee" ir-string)
      (progn (format t "PASS (denormal-fp-math = ieee/preserve)~%") t)
      (progn (format t "FAIL: expected denormal-fp-math=ieee (preserve)~%") nil)))

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



;; Ensure SBCL knows these are special at compile time so dynamic bindings are followed.
(declaim (special *compile-differentiate* *log-level* *keep-work*))

(defun compile-crisp-file-to-spirv (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .spv and returns the output path and metadata paths if successful."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "spv" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type "metacrisp" :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V, passing differentiate flag so *differentiate-p* is set
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
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

;;; === Endeavor 103: Verify-Autodiff on-metal pass ======================

(defun %vad-ensure-runner-loaded ()
  "Lazy-loads the OpenCL runner.  Returns :READY if available,
   :UNAVAILABLE if the load fails (e.g. no OpenCL ICD on host).
   Caches the result in *VAD-RUNNER-STATUS*."
  (unless *vad-runner-status*
    (setf *vad-runner-status*
          (handler-case
              (progn
               (load (merge-pathnames "tests/verify-autodiff-runner.lisp"
                                      (uiop:getcwd)))
               :ready)
            (error (e)
              (format *error-output*
                      "~&VERIFY-AUTODIFF: runner load failed (~a) -- on-metal tests will skip.~%"
                      e)
              :unavailable))))
  *vad-runner-status*)

(defun %vad-find-kernel-name (file)
  "Scans FILE for the first (def-kernel <name> ...) form and returns
   <name> as a string.  Returns NIL if no def-kernel is found.

   Uses literal text scanning (not the Crisp reader) so this works on
   files that contain reader macros / typed literals that would require
   the full Crisp loader to parse."
  (with-open-file (s file :direction :input)
    (let ((content (make-string (file-length s))))
      (read-sequence content s)
      (let ((idx (search "def-kernel" content :test #'char-equal)))
        (when idx
          (let ((start (+ idx (length "def-kernel"))))
            ;; Skip whitespace
            (loop while (and (< start (length content))
                             (member (aref content start)
                                     '(#\Space #\Tab #\Newline #\Return)))
                  do (incf start))
            ;; Read identifier chars (kernel names are C-style: no dashes).
            (let ((end start))
              (loop while (and (< end (length content))
                               (or (alphanumericp (aref content end))
                                   (char= (aref content end) #\_)))
                    do (incf end))
              (when (> end start)
                (subseq content start end)))))))))

(defun %vad-metacrisp-path (file kernel-name &key grad)
  "Predicts the metacrisp path for FILE's forward (default) or backward
   (when GRAD is T) kernel.  The compiler names them
       <basename>[_grad]_<lowercased-kernel-name>.metacrisp"
  (make-pathname :name (format nil "~a~:[~;_grad~]_~a"
                               (pathname-name file)
                               grad
                               (string-downcase kernel-name))
                 :type "metacrisp"
                 :defaults file))

(defun %vad-read-implicit-params (file kernel-name &key grad)
  "Reads the forward or backward kernel's metacrisp file for FILE and
   extracts its :implicit-params, returning a list of plists each
       (:base START :n-elements N :elem-bytes BYTES :arg-width 6)
   for use by VERIFY-AUTODIFF.  Returns NIL if the file is missing, has
   no :kernels block, or the matching kernel has no implicit params.

   The compiler emits implicit-params for local-mem scratch tiles -- in
   the forward they come from a (let ((tile (make-scratch-vector ...))))
   that participates in load-tile-at / store-tile-at; in the
   backward the AD pass adds a paired tile_ADJ shadow for each.  Each
   implicit param's :range pair gives its inclusive arg-slot span and
   :size-expr is the element count of the underlying tensor.  Element
   type comes from the second sub-form of :type, e.g. (tensor float 1
   ...) -> float -> 4 bytes."
  (let* ((meta-path (%vad-metacrisp-path file kernel-name :grad grad))
         (wanted-name (if grad
                          (format nil "~a_grad" kernel-name)
                          kernel-name)))
    (unless (probe-file meta-path)
      (return-from %vad-read-implicit-params nil))
    (let ((forms (with-open-file (s meta-path :direction :input)
                   (loop for f = (read s nil :eof)
                         until (eq f :eof) collect f))))
      (dolist (form forms)
        (when (and (consp form) (eq (first form) :kernels))
          (dolist (kern (rest form))
            (when (and (eq (first kern) :name)
                       (string-equal (second kern) wanted-name))
              (let ((implicit (getf kern :implicit-params)))
                (return-from %vad-read-implicit-params
                  (loop for p in implicit
                        for range = (getf p :range)
                        for size = (getf p :size-expr)
                        for type-spec = (getf p :type)
                        for elem-type = (second type-spec)
                        for elem-bytes = (case elem-type
                                           ((float)  4)
                                           ((double) 8)
                                           ((int ulong long) 8)
                                           (t (error "%vad-read-implicit-params: unsupported elem-type ~A in ~A"
                                                     elem-type type-spec)))
                        ;; Endeavor 145 (P6): a 2-D scratch tile's :size-expr is a LIST
                        ;; (ROWS COLS), not an integer.  Carry :rows / :cols through for
                        ;; the 9-arg matrix binding and make :n-elements their product so
                        ;; every consumer still sees an element count.
                        for dims = (and (listp size) size)
                        collect (list :base (first range)
                                      :n-elements (if dims (reduce #'* dims) size)
                                      :rows (and dims (first dims))
                                      :cols (and dims (second dims))
                                      :elem-bytes elem-bytes
                                      :arg-width (1+ (- (second range) (first range))))))))))))))

(defun %vad-compile-spv (file &key differentiate precision denormal)
  "Compiles FILE to SPV via the crisp-compile binary.
   When DIFFERENTIATE is T, passes --differentiate and expects
   <basename>_grad.spv.  PRECISION (:fast/:ieee) and DENORMAL (:ftz/:preserve),
   when given, are forwarded as --math-precision / --denormal-handling so the
   fwd + bwd kernels are compiled under the same FP mode (Endeavor 128 Phase 5).
   Returns the output pathname on success, NIL on error."
  (let* ((bin (get-binary-path))
         (base-name (if differentiate
                        (format nil "~a_grad" (pathname-name file))
                        (pathname-name file)))
         (out-path (make-pathname :name base-name :type "spv" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=spv"
                     ;; --metadata emits a sibling .metacrisp s-expression
                     ;; file with the kernel's :physical-signature,
                     ;; :declared-signature, and :implicit-params.  The
                     ;; verify-autodiff runner needs the implicit-params
                     ;; list to bind backward-kernel local-scratch tiles.
                     "--metadata"
                     (format nil "--log-level=~a" cl-user::*log-level*))))
    ;; Endeavor 145 (P6): an MMA kernel's shape comes from the active hardware profile, so
    ;; the verify compile must SELECT it exactly as the hoist path does — otherwise
    ;; mma-accumulate-via-tile falls back to the NVIDIA default and rejects the spec's
    ;; shape.  Driven by the spec's HOIST-HARDWARE-PROFILE directive.
    (when *compile-hardware-profile*
      (push (format nil "--hardware-profile=~a" *compile-hardware-profile*) args))
    (when differentiate (push "--differentiate" args))
    (when precision
      (push (format nil "--math-precision=~a" (string-downcase (symbol-name precision))) args))
    (when denormal
      (push (format nil "--denormal-handling=~a" (string-downcase (symbol-name denormal))) args))
    (when (probe-file out-path) (delete-file out-path))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
        (format *error-output* "~&VERIFY-AUTODIFF: ~a compile failed (exit ~a)~%~a~%"
                (if differentiate "backward" "forward") exit-code error-output)
        nil)
       ((not (probe-file out-path))
        (format *error-output* "~&VERIFY-AUTODIFF: ~a SPV not produced at ~a~%"
                (if differentiate "backward" "forward") out-path)
        nil)
       (t out-path)))))

(defun %vad-format-results (results)
  "Renders RESULTS (per-input plists) as a single human-readable string."
  (with-output-to-string (s)
    (loop for r in results
          for first-p = t then nil
          do (unless first-p (write-string "; " s))
             (format s "~A: analytical=~a numerical=~a diff=~a"
                     (getf r :name)
                     (getf r :analytical)
                     (getf r :numerical)
                     (getf r :diff)))))

(defun %vad-check-expected (expected-grads results atol)
  "Returns a list of failure-message strings (NIL on full match).  Each
   EXPECTED-GRADS entry (NAME . VALUE) must have a corresponding RESULTS
   entry, and |expected - analytical| < ATOL."
  (let ((failures nil))
    (dolist (e expected-grads)
      (let* ((name (car e))
             (expected (cdr e))
             (result (find name results
                           :key (lambda (r) (getf r :name))
                           :test #'string=)))
        (cond
         ((null result)
          (push (format nil "no analytical result for ~A" name) failures))
         (t
          (let ((expect-diff (abs (- expected (getf result :analytical)))))
            (unless (< expect-diff atol)
              (push (format nil
                            "~A: analytical=~a expected=~a diff=~a > atol=~a"
                            name (getf result :analytical) expected
                            expect-diff atol)
                    failures)))))))
    (nreverse failures)))

(defun run-verify-autodiff-pass (file spec)
  "Runs an on-metal VERIFY-AUTODIFF pass for FILE with SPEC (a plist
   produced by CL-USER::PARSE-VERIFY-AUTODIFF).  Returns T on PASS,
   NIL on FAIL.  Treats a missing OpenCL runner as SKIP (returns T)
   so non-GPU CI doesn't fail.

   Phase 5a scope (endeavor 103): N scalar cell inputs, one scalar cell
   output.  Tensor / record / struct inputs come in later phases.
   Endeavor 145 (P6): 2-D matrix inputs and outputs, and the spec's
   HOIST-HARDWARE-PROFILE is honoured so an MMA kernel compiles with its shape."
  (let ((*compile-hardware-profile*
          (or (parse-hoist-hardware-profile (extract-test-directives file))
              *compile-hardware-profile*)))
   (case (%vad-ensure-runner-loaded)
    (:unavailable
     (format t "SKIP (OpenCL runner unavailable)~%")
     t)
    (:ready
     (let* ((inputs (getf spec :inputs))
            (atol (getf spec :atol))
            (h (getf spec :h))
            (seed-grad (getf spec :seed-grad))
            (at-points (getf spec :at-points))
            (structs (getf spec :structs))
            (output-vec (getf spec :output-vec))
            ;; Endeavor 145 (P6): a 2-D matrix output.  ROWS*COLS also feeds
            ;; output-vec-length so every buffer-sized path in the runner (read-y,
            ;; zero, seed) keeps working; output-mat-dims only widens the ABI.
            (output-mat (getf spec :output-mat))
            (group-size (or (getf spec :group-size) 1))
            (group-count (or (getf spec :group-count) 1))
            (expected-grads (getf spec :expected-grads))
            ;; Endeavor 128 (Phase 5): compile fwd + bwd under a chosen FP mode.
            (precision (getf spec :precision))
            (denormal (getf spec :denormal))
            (kernel-name (%vad-find-kernel-name file))
            ;; Coerce numeric values to single-floats, but preserve integer
            ;; scalars (the runner uses INTEGERP to classify scalar-ulong)
            ;; and pass list values through unchanged for vector inputs.
            (coerced-inputs
             (mapcar (lambda (entry)
                       (let ((v (cdr entry)))
                         (cons (car entry)
                               (cond
                                ;; Endeavor 145 (P6): a MATRIX value is a list of ROW
                                ;; lists — coerce one level deeper, or (float row) blows
                                ;; up on the row itself.
                                ((and (listp v) v (listp (first v)))
                                 (mapcar (lambda (row)
                                           (mapcar (lambda (x) (cl:float x 1.0)) row))
                                         v))
                                ((listp v)    (mapcar (lambda (x) (cl:float x 1.0)) v))
                                ((integerp v) v)
                                (t            (cl:float v 1.0))))))
                     inputs)))
       (cond
        ((null kernel-name)
         (format *error-output* "FAIL (No def-kernel found in ~a)~%" file)
         nil)
        ((null inputs)
         (format *error-output* "FAIL (No inputs in directive)~%")
         nil)
        (t
         (let* ((fwd-spv (%vad-compile-spv file :differentiate nil :precision precision :denormal denormal))
                (bwd-spv (and fwd-spv (%vad-compile-spv file :differentiate t :precision precision :denormal denormal)))
                (result nil))
           (unwind-protect
                (setf result
                      (cond
                       ((not (and fwd-spv bwd-spv))
                        (format *error-output* "FAIL (Compile step failed)~%")
                        nil)
                       (t
                        (handler-case
                            (multiple-value-bind (pass-p results)
                                (cl-user::verify-autodiff
                                 (uiop:native-namestring fwd-spv)
                                 (uiop:native-namestring bwd-spv)
                                 kernel-name
                                 :inputs coerced-inputs
                                 :at-points at-points
                                 :structs structs
                                 :output-vec-length (if output-mat
                                                        (* (first output-mat) (second output-mat))
                                                        output-vec)
                                 :output-mat-dims output-mat
                                 :group-size group-size
                                 :group-count group-count
                                 :fwd-implicit-params
                                 (%vad-read-implicit-params file kernel-name :grad nil)
                                 :bwd-implicit-params
                                 (%vad-read-implicit-params file kernel-name :grad t)
                                 :seed-grad (cl:float seed-grad 1.0)
                                 :h (cl:float h 1.0)
                                 :atol atol
                                 :verbose nil)
                              (cond
                               ((not pass-p)
                                (format *error-output*
                                        "FAIL (FD vs analytical | atol=~a): ~A~%"
                                        atol (%vad-format-results results))
                                nil)
                               (expected-grads
                                (let ((failures (%vad-check-expected expected-grads results atol)))
                                  (cond
                                   ((null failures)
                                    (format t "PASS (~A)~%" (%vad-format-results results))
                                    t)
                                   (t
                                    (format *error-output* "FAIL (~{~A~^; ~})~%" failures)
                                    nil))))
                               (t
                                (format t "PASS (~A)~%" (%vad-format-results results))
                                t)))
                          (error (e)
                             (uiop:print-backtrace :condition e)
                             (format *error-output* "FAIL (Runner error: ~a)~%" e)
                             nil)))))
             ;; Cleanup: VERIFY-AUTODIFF produces fwd/bwd .spv files plus
             ;; the .metacrisp metadata files (since 1c.2.f.3 added
             ;; --metadata to the compile so the runner can read
             ;; implicit-params).  Delete all of them on completion
             ;; (success OR failure) so stale outputs can't mask later
             ;; runs.  Skipped under --keep-work.
             (unless *keep-work*
               (when (and fwd-spv (probe-file fwd-spv)) (delete-file fwd-spv))
               (when (and bwd-spv (probe-file bwd-spv)) (delete-file bwd-spv))
               (let ((fwd-meta (%vad-metacrisp-path file kernel-name :grad nil))
                     (bwd-meta (%vad-metacrisp-path file kernel-name :grad t)))
                 (when (probe-file fwd-meta) (delete-file fwd-meta))
                 (when (probe-file bwd-meta) (delete-file bwd-meta)))))
           result))))))))

;;; ======================================================================

(defun %intel-l0-gpu-available-p ()
  "T if an Intel GPU (PCI vendor 0x8086) is present so TEST-HOIST[L0] can actually run on metal.
   Explicit override: CRISP_L0_AVAILABLE=true|false.  Linux: scan /sys/class/drm/*/device/vendor.
   Non-Linux (can't probe): assume available so local runs are unchanged (the explicit SKIP_L0_HOIST
   env still applies in run-spec-with-hoist)."
  (let ((ov (uiop:getenv "CRISP_L0_AVAILABLE")))
    (cond
      ((and ov (string-equal ov "false")) nil)
      ((and ov (plusp (length ov))) t)                 ; any non-empty, non-"false" value forces on
      ((not (uiop:os-unix-p)) t)                        ; Windows/local: don't auto-skip
      (t (and (ignore-errors
                (some (lambda (vf)
                        (let ((v (with-open-file (s vf :if-does-not-exist nil)
                                   (and s (read-line s nil "")))))
                          (and v (search "0x8086" v))))
                      (directory #P"/sys/class/drm/*/device/vendor")))
              t)))))

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

(defun parse-strategy-expect (directive-lines &optional target)
  "Parse STRATEGY-EXPECT: or STRATEGY-EXPECT[target]: <string> lines.
   Returns list of expected strings to find in generated C++ source content."
  (let ((expectations '())
        (prefix-generic "STRATEGY-EXPECT:")
        (prefix-target (when target (format nil "STRATEGY-EXPECT[~a]:" target))))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (cond
         ((and prefix-target (starts-with trimmed prefix-target))
          (let ((value (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed (length prefix-target)))))
            (push value expectations)))
         ((starts-with trimmed prefix-generic)
          (let ((value (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed (length prefix-generic)))))
            (push value expectations))))))
    (nreverse expectations)))

(defun validate-l0-strategy-content (crisp-file cpp-files)
  "Validates generated C++ files contain expected strategy dispatch strings.
   Reads STRATEGY-EXPECT: directives from the .crisp file.
   Does not require compilation or hardware — checks C++ source content only."
  (when (null cpp-files)
    (format t "FAIL: No C++ files to validate~%")
    (return-from validate-l0-strategy-content nil))
  (let* ((directives (extract-test-directives crisp-file))
         (expectations (parse-strategy-expect directives "L0"))
         (passed t))
    (when (null expectations)
      (format t "PASS: No STRATEGY-EXPECT directives (trivial pass).~%")
      (return-from validate-l0-strategy-content t))
    (dolist (cpp cpp-files)
      (let ((content (uiop:read-file-string cpp)))
        (dolist (exp expectations)
          (unless (search exp content)
            (format t "FAIL: Expected string not found in ~a:~%  '~a'~%" (file-namestring cpp) exp)
            (setf passed nil)))))
    (when passed
      (format t "PASS: All ~a strategy expectations met.~%" (length expectations)))
    passed))

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
                        (uiop:native-namestring ze-loader)
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


(defun validate-l0-compile-only (crisp-file cpp-files)
  "Validates C++ files compile. Tries Native Clang first, then Docker."
  (let ((clang-exe (resolve-clang-executable))
        (l0-include (resolve-l0-include-dir))
        (docker-available (handler-case
                             (zerop (nth-value 2 (uiop:run-program '("docker" "--version") :ignore-error-status t :output nil)))
                           (error () nil))))
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
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "spv" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=spv"
                     (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))
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
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ptx" :defaults filepath))
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for PTX
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :ptx))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-ptx
                module out-path
                :compute-capability (crisp.compiler::ptx-compute-capability-string))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        out-path
        nil)))

(defun run-spec-ptx-in-process (file &key (validator nil))
  (handler-case
      (let ((out-path (compile-crisp-file-to-ptx file)))
        (if out-path
            (let ((res (if validator
                           (let* ((ptx-content (uiop:read-file-string out-path))
                                  (sym (if (symbolp validator) validator
                                           (find-symbol (string-upcase (string validator)) :crisp.spec-runner))))
                             (if (and sym (fboundp sym))
                                 (funcall sym file ptx-content)
                                 (progn
                                   (format *error-output* "FAIL: Validator ~a not found~%" validator)
                                   nil)))
                           t)))
              (when res
                (format t "PASS (Generated ~a)~%" (file-namestring out-path)))
              (unless *keep-work* (delete-file out-path))
              res)
            (progn (format *error-output* "FAIL (No PTX generated)~%") nil)))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

(defun run-spec-ptx-binary (file &key (validator nil) (flags nil))
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "ptx" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=ptx" (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))
    ;; Endeavor 137: forward --ir-target-arch=<ID> from the TEST-WITH flags to the binary — a
    ;; separate crisp-compile.exe process can't see the in-process *ir-target-arch* dynamic
    ;; binding, so a :block (sm_90+) test gates on the default sm_80 without this.
    (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
      (when af (push af args)))

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
         (let ((res (if validator
                        (let* ((ptx-content (uiop:read-file-string out-path))
                               (sym (if (symbolp validator) validator
                                        (find-symbol (string-upcase (string validator)) :crisp.spec-runner))))
                          (if (and sym (fboundp sym))
                              (funcall sym file ptx-content)
                              (progn
                                (format *error-output* "FAIL: Validator ~a not found~%" validator)
                                nil)))
                        t)))
           (when res
             (format t "PASS (Generated .ptx)~%"))
           (unless *keep-work* (delete-file out-path))
           res))
       (t
         (format *error-output* "FAIL (No PTX generated)~%~a~%" error-output)
         nil)))))

;; LLVM IR Runner Functions

(defun compile-crisp-file-to-llvmir (filepath)
  "Compiles a .crisp file to .ll and returns the output path if successful.
   Reads source in :crisp-language package to match compile-crisp-file-to-spirv."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ll" :defaults filepath))
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let ((crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
                  (with-open-file (stream filepath)
                    ;; NOTE: use :crisp-language (not :crisp.compiler) so that
                    ;; Crisp forms like (return ...) are read as crisp-language::return,
                    ;; not as a CL function call.
                    (let ((*package* (find-package :crisp-language)))
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
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "ll" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=llvmir"
                     (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))

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
  (handler-bind ((error (lambda (e) (sb-debug:print-backtrace :count 30 :stream *terminal-io*) (format *terminal-io* "FAIL (Condition: ~a)~%" e) (return-from run-spec-lisp-loader nil))))
      (let ((ir-string (compile-crisp-file-to-ir-string file)))
        (if (validate-ir-with-clang ir-string)
            (progn (format t "PASS~%") t)
            (progn (format *error-output* "FAIL (Invalid IR)~%") nil)))))

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

(defun parse-skip-default-pass (directive-lines)
  "Returns T if the spec carries a SKIP-DEFAULT-PASS directive — opts out of the
   no-flags (GENERIC) Default run, validated only via its TEST-WITH target passes.
   For target-specific specs whose feature has no valid GENERIC lowering (e.g. an MMA
   kernel emitting an NVVM/PTX-only intrinsic the host GENERIC validator can't compile)."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "SKIP-DEFAULT-PASS")
        (return t)))))

(defun parse-skip-with (directive-lines)
  "Parses SKIP-WITH[--flag]: 'message' directives.
   Returns T if any directive matches the CURRENT active flags."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "SKIP-WITH[")
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
                            (return-from parse-skip-with t))))))))
  nil)

(defun parse-compile-with (directive-lines)
  "Parses COMPILE-WITH[--flag ...]: PASS | FAIL \"substring\" directives (Endeavor 130).
   Returns a list of (flags expect substring): compile the spec through the binary with
   FLAGS active and require exit 0 (:pass) or exit != 0 + SUBSTRING on stderr (:fail).
   The flag-carrying test path for hardware-profile validation."
  (let ((runs '()))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "COMPILE-WITH[")
          (let* ((end-bracket (position #\] trimmed))
                 (content (when end-bracket (subseq trimmed (length "COMPILE-WITH[") end-bracket)))
                 (colon (position #\: trimmed :start (or end-bracket 0)))
                 (rest (when colon (string-trim '(#\Space #\Tab #\Return #\Newline)
                                                (subseq trimmed (1+ colon))))))
            (when (and content rest (> (length content) 0) (>= (length rest) 4))
              (let ((flags (remove "" (uiop:split-string content :separator " ") :test #'string=)))
                (cond
                  ((string-equal (subseq rest 0 4) "PASS")
                   (push (list flags :pass nil) runs))
                  ((string-equal (subseq rest 0 4) "FAIL")
                   (let* ((q1 (position #\" rest))
                          (q2 (when q1 (position #\" rest :from-end t))))
                     (when (and q1 q2 (> q2 q1))
                       (push (list flags :fail (subseq rest (1+ q1) q2)) runs)))))))))))
    (nreverse runs)))

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

(defun parse-expect-stderr (directive-lines)
  "Parses EXPECT-STDERR[--flag1 --flag2]: \"substring\" directives (Endeavor 126).
   Returns a list of (flags . substring) pairs. Each run compiles the spec with the
   given flags and requires SUBSTRING to appear on stderr AND a successful compile.
   For CLI *warnings* (e.g. --force-math-precision override, fast+preserve) that leave
   the IR unchanged and so cannot be caught by a TEST-WITH IR-grep validator."
  (let ((runs '()))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "EXPECT-STDERR[")
          (let* ((end-bracket (position #\] trimmed))
                 (content (when end-bracket (subseq trimmed (length "EXPECT-STDERR[") end-bracket)))
                 (colon (position #\: trimmed :start (or end-bracket 0)))
                 (rest (when colon (string-trim '(#\Space #\Tab #\Return #\Newline)
                                                (subseq trimmed (1+ colon)))))
                 ;; Strip the surrounding double-quotes around the expected substring.
                 (substr (when (and rest (>= (length rest) 2)
                                    (char= (cl:char rest 0) #\")
                                    (char= (cl:char rest (1- (length rest))) #\"))
                           (subseq rest 1 (1- (length rest))))))
            (when (and content substr (> (length content) 0))
              (let ((flags (remove "" (uiop:split-string content :separator " ") :test #'string=)))
                (push (cons flags substr) runs)))))))
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

(defun parse-hoist-denormal (directive-lines)
  "Parse HOIST-DENORMAL: ftz|preserve (Endeavor 126). Returns :ftz / :preserve / nil.
   Sets --denormal-handling for the hoist compile so an on-metal test can observe
   flush-to-zero vs preserve subnormal handling."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "HOIST-DENORMAL:")
        (let ((v (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 15))))
          (cond ((string-equal v "ftz") (return :ftz))
                ((string-equal v "preserve") (return :preserve))))))))

(defun parse-hoist-precision (directive-lines)
  "Parse HOIST-PRECISION: fast|ieee (Endeavor 128). Returns :fast / :ieee / nil.
   Sets --math-precision for the hoist compile so an on-metal test can exercise the
   fast native_* transcendental path (vs precise ieee) on real hardware."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "HOIST-PRECISION:")
        (let ((v (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 16))))
          (cond ((string-equal v "fast") (return :fast))
                ((string-equal v "ieee") (return :ieee))))))))

(defun parse-hoist-hardware-profile (directive-lines)
  "Parse HOIST-HARDWARE-PROFILE: <name> (Endeavor 130). Returns the profile name
   string or nil.  Forwarded as --hardware-profile=<name> to the hoist compile so
   the metacrisp carries the active profile and the launcher uses its :compute-units."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "HOIST-HARDWARE-PROFILE:")
        (let ((v (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 23))))
          (when (plusp (length v)) (return v)))))))

(defun parse-hoist-arch (directive-lines)
  "Parse HOIST-ARCH: <id> (Endeavor 137).  Returns the arch id string (e.g. \"sm_90\") or nil.
   Forwarded as --ir-target-arch=<id> to the hoist compile so a :block (TMA) kernel passes the
   sm_90+ gate at hoist time (the metal run needs the sm_90a PTX / CUtensorMap path)."
  (dolist (line directive-lines nil)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "HOIST-ARCH:")
        (let ((v (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 11))))
          (when (plusp (length v)) (return v)))))))

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

(defun validate-ptx-mbarrier (file ptx-string)
  "Validates the async load-tile idiom (Endeavor 136 Chapter 1): a cooperative
   cp.async copy into shared memory, closed with cp.async.commit_group, and an
   (await ...) that lowers to cp.async.wait_group.  This replaces the earlier
   mbarrier-based lowering (mbarrier.init / cp.async.mbarrier.arrive /
   mbarrier.test_wait) which under-copied N-D tiles and was never metal-correct."
  (declare (ignore file))
  (let ((expected '("cp.async.ca.shared.global"
                    "cp.async.commit_group"
                    "cp.async.wait_group")))
    (dolist (exp expected)
      (unless (search exp ptx-string)
        (format *error-output* "FAIL: Expected PTX string not found:~%  '~a'~%" exp)
        (return-from validate-ptx-mbarrier nil)))
    t))

(defun validate-ptx-tma (file ptx-string)
  "Endeavor 137 (Chapter 1.5, Phase 2a) — validates the NVIDIA :block TMA lowering: a per-CTA
   SLM mbarrier (mbarrier.init) plus a bulk descriptor-driven copy
   (cp.async.bulk.tensor...mbarrier::complete_tx::bytes).  This is the compile-shape check;
   the real CUtensorMap descriptor + on-metal correctness land in Phase 2b."
  (declare (ignore file))
  (let ((expected '("cp.async.bulk.tensor"
                    "mbarrier.init")))
    (dolist (exp expected)
      (unless (search exp ptx-string)
        (format *error-output* "FAIL: Expected PTX string not found:~%  '~a'~%" exp)
        (return-from validate-ptx-tma nil)))
    t))

(defun validate-ptx-distributed-mma (file ptx-string)
  "Endeavor 139 (Chapter 3, decision A) — a warp-distributed register tile.  The kernel's 32x16 tile
   is 4 fragments split across 2 consumer warps, so each warp computes only 2 (not the full 4).
   Endeavor 139 step-4 perf made the distribution a STATIC per-warp switch (compile-time fragment
   coordinates so ptxas can CSE the SMEM operand loads).  That emits both warp arms — n-true*per-warp
   = 4 mma.sync in the text — which ptxas then EITHER keeps as-is (2 arms x 2) OR merges back to the
   per-warp 2 with the loads hoisted.  Both are correct distributions, so accept per-warp (2) or the
   both-arms total (4); reject the un-distributed / redundant counts (0, or >= 8 = every warp doing
   the whole tile in every arm)."
  (declare (ignore file))
  (let ((count 0) (start 0))
    (loop for pos = (search "mma.sync" ptx-string :start2 start)
          while pos do (incf count) (setf start (+ pos 8)))
    (if (or (= count 2) (= count 4))
        t
        (progn (format *error-output*
                       "FAIL: expected 2 (per-warp) or 4 (both static arms) mma.sync for a 4-frag/2-warp tile, got ~a~%"
                       count)
               nil))))

(defun validate-ptx-wgmma (file ptx-string)
  "Endeavor 140 (Chapter 4) — the Hopper wgmma path lowered: assert the async warpgroup MMA
   instruction (wgmma.mma_async.sync.aligned.m64n64k8.f32.tf32.tf32) plus its fence / commit_group /
   wait_group bracketing are all present in the PTX.  (Correctness = the metal MMA_CORRECT hoist.)"
  (declare (ignore file))
  (dolist (needle '("wgmma.mma_async.sync.aligned.m64n64k8.f32.tf32.tf32"
                    "wgmma.fence.sync.aligned"
                    "wgmma.commit_group.sync.aligned"
                    "wgmma.wait_group.sync.aligned")
                  t)
    (unless (search needle ptx-string)
      (format *error-output* "FAIL: wgmma PTX missing ~s~%" needle)
      (return-from validate-ptx-wgmma nil))))

(defun validate-warp-roles (file ir-string)
  "Endeavor 139 (Chapter 3) — the warp-specialization role SKELETON.  Asserts BOTH role bodies
   lowered: the producer marker (40001) and the consumer marker (40002) both survive to the IR.
   (Neither block was dropped.)  Target-agnostic — works on the PTX or the SPV/IR string.  The
   branch-actually-split-the-warps proof is the metal test 01b, not this shape check."
  (declare (ignore file))
  (dolist (marker '("40001" "40002") t)
    (unless (search marker ir-string)
      (format *error-output* "FAIL: warp-role marker ~a absent — a role body did not lower~%" marker)
      (return-from validate-warp-roles nil))))

(defun validate-ptx-linear-ring (file ptx-string)
  "Endeavor 138 (Chapter 2) — validates the :linear (cp.async) RING pipeline lowering: each
   load-tile commits a group (cp.async.commit_group), and (await) keeps stages in flight via
   cp.async.wait_group with a NON-ZERO depth (= (ring-count-1)*arrivals).  The pre-138 lowering
   emitted wait_group(0) (wait for everything = no overlap), so a non-zero depth is the proof the
   ring actually pipelines."
  (declare (ignore file))
  (unless (search "cp.async.commit_group" ptx-string)
    (format *error-output* "FAIL: no cp.async.commit_group (async staging absent)~%")
    (return-from validate-ptx-linear-ring nil))
  ;; find every `cp.async.wait_group <n>` and require at least one with n > 0.
  (let ((found-nonzero nil) (start 0))
    (loop
      (let ((pos (search "cp.async.wait_group" ptx-string :start2 start)))
        (unless pos (return))
        (let* ((after (+ pos (length "cp.async.wait_group")))
               (num-start (position-if #'digit-char-p ptx-string :start after
                                       :end (min (length ptx-string) (+ after 16)))))
          (when num-start
            (let ((n (parse-integer ptx-string :start num-start :junk-allowed t)))
              (when (and n (> n 0)) (setf found-nonzero t))))
          (setf start after))))
    (unless found-nonzero
      (format *error-output* "FAIL: cp.async.wait_group depth is 0 everywhere — the :linear ring is not pipelining (expected (ring-count-1)*arrivals > 0)~%")
      (return-from validate-ptx-linear-ring nil))
    t))

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


;; --- CUDA validators (no hardware required) ---

(defun validate-cuda-generation (crisp-file cu-files)
  "Validates that .cu files were generated and contain core CUDA Driver API calls."
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            (dolist (marker '("cuInit" "cuModuleLoadData" "cuModuleGetFunction"
                              "cuLaunchKernel" "kernelParams"))
              (unless (search marker content)
                (format t "FAIL: ~a missing expected marker '~a'~%"
                        (file-namestring cu) marker)
                (setf passed nil)))))
        (when passed
          (format t "PASS: .cu file generated with all CUDA Driver API markers~%"))
        passed)))

(defun validate-cuda-cell-args (crisp-file cu-files)
  "Validates that cell parameter generates cuMemAlloc + cuMemcpyHtoD and 3 kernelParams slots."
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            (unless (search "cuMemAlloc" content)
              (format t "FAIL: ~a missing cuMemAlloc for cell~%" (file-namestring cu))
              (setf passed nil))
            (unless (search "cuMemcpyHtoD" content)
              (format t "FAIL: ~a missing cuMemcpyHtoD for cell~%" (file-namestring cu))
              (setf passed nil))
            (unless (search "kernelParams[3]" content)
              (format t "FAIL: ~a should have kernelParams[3] (cell = 3 args)~%" (file-namestring cu))
              (setf passed nil))))
        (when passed
          (format t "PASS: .cu has correct cell arg structure (cuMemAlloc + cuMemcpyHtoD + 3 params)~%"))
        passed)))

(defun validate-cuda-tensor-args (crisp-file cu-files)
  "Validates that tensor params produce correct arg count in kernelParams.
   Two rank-1 tensors = 6 args each = kernelParams[12]."
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            (unless (search "kernelParams[12]" content)
              (format t "FAIL: ~a expected kernelParams[12] for two rank-1 tensors (6 args each)~%"
                      (file-namestring cu))
              (setf passed nil))
            (unless (search "cuLaunchKernel" content)
              (format t "FAIL: ~a missing cuLaunchKernel~%" (file-namestring cu))
              (setf passed nil))))
        (when passed
          (format t "PASS: .cu has correct tensor arg count (kernelParams[12]) and launch~%"))
        passed)))

(defun validate-cuda-shared-mem (crisp-file cu-files)
  "Validates that a kernel with a local tile emits:
   - shared-memory offset = 0 for the tile ptr (the tensor form `_ptr = 0ULL;`)
   - sharedMemBytes = 32 in cuLaunchKernel (4-element ulong tile; Endeavor 136 made the
     async barrier a phantom, so there is no longer a +8-byte mbarrier)
   - kernelParams[18] (tile 6 + v 6 + out 6; the phantom barrier contributes no params)"
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            (unless (search "_ptr = 0ULL;" content)
              (format t "FAIL: ~a missing shared-mem offset=0 for tile ptr~%" (file-namestring cu))
              (setf passed nil))
            (let ((launch-pos (search "cuLaunchKernel" content)))
              (when launch-pos
                (let ((launch-region (subseq content launch-pos
                                             (min (+ launch-pos 300) (length content)))))
                  (unless (search "32, 0," launch-region)
                    (format t "FAIL: ~a cuLaunchKernel should have sharedMemBytes=32 for 4-element tile (phantom barrier)~%"
                            (file-namestring cu))
                    (setf passed nil)))))
            (unless (search "kernelParams[18]" content)
              (format t "FAIL: ~a expected kernelParams[18] for tile+v+out (phantom barrier, no param)~%" (file-namestring cu))
              (setf passed nil))))
        (when passed
          (format t "PASS: .cu local tile test passed~%"))
        passed)))


;; --- Compile+run validators (require nvcc + NVIDIA GPU) ---


(defun resolve-nvcc-executable ()
  "Finds nvcc on PATH or in common CUDA toolkit locations.
   Returns the path string, or NIL if not found."
  (or
   ;; Check PATH
   (let ((on-path (uiop:run-program
                    (if (uiop:os-windows-p)
                        '("where" "nvcc")
                        '("which" "nvcc"))
                    :output :string :ignore-error-status t)))
     (when (and (stringp on-path) (> (length (string-trim '(#\Space #\Newline #\Return) on-path)) 0))
       (string-trim '(#\Space #\Newline #\Return) on-path)))
   ;; Linux: check common CUDA paths
   (loop for pattern in '("/usr/local/cuda/bin/nvcc"
                          "/usr/local/cuda-12.4/bin/nvcc"
                          "/usr/local/cuda-12.8/bin/nvcc"
                          "/usr/local/cuda-12.6/bin/nvcc")
         when (probe-file pattern)
         return pattern)
   ;; Windows: check standard NVIDIA install
   (when (uiop:os-windows-p)
     (let ((candidate "C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.4/bin/nvcc.exe"))
       (when (probe-file candidate) candidate)))))

(defun validate-cuda-compile-only (crisp-file cu-files)
  "Validates .cu files compile with nvcc.  SKIPs if nvcc not available."
  (declare (ignore crisp-file))
  (let ((nvcc (resolve-nvcc-executable)))
    (cond
     ((null cu-files)
      (format t "FAIL: No .cu files generated~%")
      nil)

     ((null nvcc)
      (format t "SKIP (nvcc not available)~%")
      t)

     (t
      (dolist (cu cu-files)
        (let ((exe-path (make-pathname :type #+windows "exe" #-windows nil
                                       :defaults cu)))
          (multiple-value-bind (output error-output exit-code)
              (uiop:run-program
                (list nvcc
                      (uiop:native-namestring cu)
                      "-lcuda"
                      "-o" (uiop:native-namestring exe-path))
                :output :string :error-output :string :ignore-error-status t)
            (declare (ignore output))
            (unless (zerop exit-code)
              (format t "FAIL: nvcc compilation error for ~a~%~a~%"
                      (file-namestring cu) error-output)
              (return-from validate-cuda-compile-only nil))
            (format t "PASS: ~a compiles with nvcc~%" (file-namestring cu)))))
      t))))


(defun validate-cuda-host-run (crisp-file cu-files)
  "Validates .cu files compile with nvcc AND run successfully on a CUDA GPU.
   Checks HOIST-EXPECT: directives against program stdout.
   SKIPs gracefully if nvcc is not available (e.g. Windows dev machine, CI without GPU)."
  (let ((nvcc (resolve-nvcc-executable)))
    (cond
     ((null cu-files)
      (format t "FAIL: No .cu files generated~%")
      nil)

     ((null nvcc)
      (format t "SKIP (nvcc not available)~%")
      t)

     (t
      (dolist (cu cu-files)
        (let ((exe-path (make-pathname :type #+windows "exe" #-windows nil
                                       :defaults cu)))
          ;; 1. Compile
          (multiple-value-bind (output error-output exit-code)
              (uiop:run-program
                (list nvcc
                      (uiop:native-namestring cu)
                      "-lcuda"
                      "-o" (uiop:native-namestring exe-path))
                :output :string :error-output :string :ignore-error-status t)
            (declare (ignore output))
            (unless (zerop exit-code)
              (format t "FAIL: nvcc compilation error for ~a~%~a~%"
                      (file-namestring cu) error-output)
              (return-from validate-cuda-host-run nil))
            (format t "Compiled ~a -> ~a... OK~%" (file-namestring cu) (file-namestring exe-path)))

          ;; 2. Run
          (multiple-value-bind (run-out run-err run-code)
              (uiop:run-program (uiop:native-namestring exe-path)
                :output :string :error-output :string :ignore-error-status t)
            (format t "Output:~%~a~%" run-out)
            (unless (zerop run-code)
              (format t "FAIL: ~a execution failed (Code ~a)~%Error: ~a~%"
                      (file-namestring exe-path) run-code run-err)
              (return-from validate-cuda-host-run nil))

            ;; 3. Check HOIST-EXPECT
            (let ((expectations (parse-hoist-expect (extract-test-directives crisp-file)))
                  (passed t))
              (when expectations
                (dolist (exp expectations)
                  (unless (search exp run-out)
                    (format t "FAIL: Expectation not found in output: '~a'~%" exp)
                    (setf passed nil))))
              (if passed
                  (format t "PASS: ~a ran successfully on CUDA!~%" (file-namestring cu))
                  (return-from validate-cuda-host-run nil))))))
      t))))



(defun validate-cuda-strategy-content (crisp-file cu-files)
  "Validates generated .cu files contain expected strategy dispatch strings."
  (when (null cu-files)
    (format t "FAIL: No .cu files to validate~%")
    (return-from validate-cuda-strategy-content nil))
  (let* ((directives (extract-test-directives crisp-file))
         (expectations (parse-strategy-expect directives "CUDA"))
         (passed t))
    (when (null expectations)
      (format t "PASS: No STRATEGY-EXPECT directives (trivial pass).~%")
      (return-from validate-cuda-strategy-content t))
    (dolist (cu cu-files)
      (let ((content (uiop:read-file-string cu)))
        (dolist (exp expectations)
          (unless (search exp content)
            (format t "FAIL: Expected string not found in ~a:~%  '~a'~%"
                    (file-namestring cu) exp)
            (setf passed nil)))))
    (when passed
      (format t "PASS: All ~a strategy expectations met.~%" (length expectations)))
    passed))

    

(defun validate-cuda-hw-profile-grid (crisp-file cu-files)
  "Endeavor 130 Phase 5: validate that an active hardware profile's :compute-units
   OVERRIDES the runtime SM-count query in the :strided grid-size heuristic.
   Honors STRATEGY-EXPECT (positive substrings, e.g. the exact `int _numSMs = 8;`)
   AND asserts the device query (CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT) is ABSENT."
  (when (null cu-files)
    (format t "FAIL: No .cu files to validate~%")
    (return-from validate-cuda-hw-profile-grid nil))
  (let* ((directives   (extract-test-directives crisp-file))
         (expectations (parse-strategy-expect directives "CUDA"))
         (passed t))
    (dolist (cu cu-files)
      (let ((content (uiop:read-file-string cu)))
        ;; Positive expectations (the literal override assignment).
        (dolist (exp expectations)
          (unless (search exp content)
            (format t "FAIL: Expected string not found in ~a:~%  '~a'~%"
                    (file-namestring cu) exp)
            (setf passed nil)))
        ;; Negative: the device query must be gone when the profile overrides.
        (when (search "CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT" content)
          (format t "FAIL: ~a still queries the device SM count; profile :compute-units should override it.~%"
                  (file-namestring cu))
          (setf passed nil))))
    (when passed
      (format t "PASS: hardware-profile :compute-units overrides the device SM query.~%"))
    passed))



(defun parse-mma-dims (directive-lines)
  "Parse `MMA-DIMS: M N K` -> (list M N K), or NIL."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "MMA-DIMS:")
        (let ((nums (remove "" (uiop:split-string
                                (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 9))
                                :separator " ")
                            :test #'string=)))
          (return-from parse-mma-dims
            (ignore-errors (mapcar #'parse-integer nums))))))))

(defun parse-mma-scale (directive-lines)
  "Parse `MMA-SCALE: N` -> integer, or 1 (default).  For kernels that fire the MMA more than
   once per fragment (e.g. accum-op body), the reference expects C = N·(A·B)."
  (dolist (line directive-lines 1)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "MMA-SCALE:")
        (return-from parse-mma-scale
          (or (ignore-errors (parse-integer (string-trim '(#\Space #\Tab #\Return #\Newline)
                                                          (subseq trimmed 10))))
              1))))))

(defun %crisp-hoist-l0-binary ()
  "Path to crisp-hoist-l0.exe (alongside the compiler binary)."
  (merge-pathnames (format nil "bin/crisp-hoist-l0~a" (if (uiop:os-windows-p) ".exe" ""))
                   (uiop:getcwd)))

(defun validate-l0-mma-run (file cpp-files)
  "Endeavor 134: re-hoist each kernel in --mma-test=M,N,K mode (host-reference C=A·B check),
   then compile+run via validate-l0-host-run (which checks HOIST-EXPECT: MMA_CORRECT)."
  (let* ((directives (extract-test-directives file))
         (dims (parse-mma-dims directives))
         (scale (parse-mma-scale directives)))
    (unless (and dims (= (length dims) 3) (every #'integerp dims))
      (format t "FAIL: validate-l0-mma-run requires an `MMA-DIMS: M N K` directive~%")
      (return-from validate-l0-mma-run nil))
    (let ((hoist (%crisp-hoist-l0-binary)))
      (unless (probe-file hoist)
        (format t "FAIL: crisp-hoist-l0 binary not found at ~a~%" hoist)
        (return-from validate-l0-mma-run nil))
      (dolist (cpp cpp-files)
        (let* ((base (pathname-name cpp))                       ; <spec>_<kernel>_L0
               (mc-name (if (and (>= (length base) 3)
                                 (string-equal (subseq base (- (length base) 3)) "_L0"))
                            (subseq base 0 (- (length base) 3))
                            base))
               (metacrisp (make-pathname :name mc-name :type "metacrisp" :defaults cpp)))
          (unless (probe-file metacrisp)
            (format t "FAIL: metacrisp not found for ~a (expected ~a)~%"
                    (file-namestring cpp) (file-namestring metacrisp))
            (return-from validate-l0-mma-run nil))
          (multiple-value-bind (out err code)
              (uiop:run-program (append (list (uiop:native-namestring hoist)
                                              (format nil "--mma-test=~{~d~^,~}" dims))
                                        (when (and scale (/= scale 1))
                                          (list (format nil "--mma-scale=~d" scale)))
                                        (list (uiop:native-namestring metacrisp)))
                :output :string :error-output :string :ignore-error-status t)
            (declare (ignore out))
            (unless (zerop code)
              (format t "FAIL: crisp-hoist-l0 --mma-test failed (code ~a):~%~a~%" code err)
              (return-from validate-l0-mma-run nil))))))
    ;; The .cpp files are now the MMA test harnesses; compile + run + check MMA_CORRECT.
    (validate-l0-host-run file cpp-files)))

(defun %crisp-hoist-cuda-binary ()
  "Path to crisp-hoist-cuda.exe (alongside the compiler binary)."
  (merge-pathnames (format nil "bin/crisp-hoist-cuda~a" (if (uiop:os-windows-p) ".exe" ""))
                   (uiop:getcwd)))

(defun validate-cuda-mma-run (file cu-files)
  "Endeavor 134 (CUDA/PTX twin): re-hoist each kernel in --mma-test=M,N,K mode
   (host-reference C=A·B check), then compile+run via validate-cuda-host-run
   (which checks HOIST-EXPECT: MMA_CORRECT).  Skip-gated by nvcc availability."
  (let* ((directives (extract-test-directives file))
         (dims (parse-mma-dims directives))
         (scale (parse-mma-scale directives)))
    (unless (and dims (= (length dims) 3) (every #'integerp dims))
      (format t "FAIL: validate-cuda-mma-run requires an `MMA-DIMS: M N K` directive~%")
      (return-from validate-cuda-mma-run nil))
    (let ((hoist (%crisp-hoist-cuda-binary)))
      (unless (probe-file hoist)
        (format t "FAIL: crisp-hoist-cuda binary not found at ~a~%" hoist)
        (return-from validate-cuda-mma-run nil))
      (dolist (cu cu-files)
        (let* ((base (pathname-name cu))                       ; <spec>_<kernel>_CUDA
               (mc-name (if (and (>= (length base) 5)
                                 (string-equal (subseq base (- (length base) 5)) "_CUDA"))
                            (subseq base 0 (- (length base) 5))
                            base))
               (metacrisp (make-pathname :name mc-name :type "metacrisp" :defaults cu)))
          (unless (probe-file metacrisp)
            (format t "FAIL: metacrisp not found for ~a (expected ~a)~%"
                    (file-namestring cu) (file-namestring metacrisp))
            (return-from validate-cuda-mma-run nil))
          (multiple-value-bind (out err code)
              (uiop:run-program (append (list (uiop:native-namestring hoist)
                                              (format nil "--mma-test=~{~d~^,~}" dims))
                                        (when (and scale (/= scale 1))
                                          (list (format nil "--mma-scale=~d" scale)))
                                        (list (uiop:native-namestring metacrisp)))
                :output :string :error-output :string :ignore-error-status t)
            (declare (ignore out))
            (unless (zerop code)
              (format t "FAIL: crisp-hoist-cuda --mma-test failed (code ~a):~%~a~%" code err)
              (return-from validate-cuda-mma-run nil))))))
    ;; The .cu files are now the MMA test harnesses; compile + run + check MMA_CORRECT.
    (validate-cuda-host-run file cu-files)))

;; --- Endeavor 136 SPV Chapter 1: OpGroupAsyncCopy opcode-presence + on-metal check ---

(defun %llvm-spirv-binary ()
  "Resolve llvm-spirv exactly as the compiler does (crisp.compiler::resolve-tool-executable):
   the bundled bin/ copy, else CRISP_USE_SYSTEM_TOOLS -> PATH, else a bare name.  This is the
   same tool the compiler used to PRODUCE the .spv, so if the .spv exists this resolves to a
   usable disassembler."
  (crisp.compiler::resolve-tool-executable "llvm-spirv"))

(defun %spv-contains-opcode-p (crisp-file opcode)
  "Disassemble CRISP-FILE's .spv with `llvm-spirv --to-text` and return T iff the SPIR-V
   textual form contains OPCODE (e.g. \"GroupAsyncCopy\").  TDD driver for SPV async: the
   sync fallback produces no such opcode, so the check is RED until the async path is emitted.

   Degrades gracefully: returns T (SKIP, don't fail) when the check can't be performed on
   this box — no .spv could be produced, or no llvm-spirv/SPV-disasm is available (e.g. a CI
   runner without the SPV toolchain).  Returns NIL *only* when the .spv WAS disassembled and
   the opcode is definitively ABSENT.  The dev box (BMG + bundled llvm-spirv) is the real
   regression guard; boxes without the SPV toolchain skip it like the metal tests do.

   Disassembles the .spv the hoist already produced (compiling one to a TEMP path only if
   absent), and NEVER deletes the shared .spv — the L0 harness reads it at runtime."
  (let* ((hoist-spv (make-pathname :name (pathname-name crisp-file) :type "spv" :defaults crisp-file))
         (own-compile-p nil)
         (spv (if (probe-file hoist-spv)
                  hoist-spv
                  ;; no hoist artifact — compile our own to a distinct temp path (best effort;
                  ;; get-binary-path throws when there's no binary, e.g. an in-process run — treat
                  ;; that as "can't produce a .spv" and skip rather than crashing the test).
                  (handler-case
                      (let ((tmp (make-pathname :name (format nil "~a-opchk" (pathname-name crisp-file))
                                                :type "spv" :defaults crisp-file))
                            (bin (get-binary-path)))
                        (setf own-compile-p t)
                        (multiple-value-bind (o e code)
                            (uiop:run-program (list (uiop:native-namestring bin)
                                                    (uiop:native-namestring crisp-file)
                                                    "--ir-target=spv"
                                                    (format nil "--log-level=~a" cl-user::*log-level*))
                              :output :string :error-output :string :ignore-error-status t)
                          (declare (ignore o e))
                          (cond ((and (zerop code) (probe-file hoist-spv))
                                 (rename-file hoist-spv tmp) tmp)
                                (t nil))))
                    (error () nil)))))     ; couldn't produce a .spv -> skip below
    (unless spv
      (format t "(opcode check skipped: no .spv produced) ")
      (return-from %spv-contains-opcode-p t))
    (let* ((spt (make-pathname :type "spt" :defaults spv))
           (llvm-spirv (%llvm-spirv-binary))
           (disasm-ok
            (handler-case
                (multiple-value-bind (o e code)
                    (uiop:run-program (list (uiop:native-namestring llvm-spirv) "--to-text"
                                            (uiop:native-namestring spv)
                                            "-o" (uiop:native-namestring spt))
                      :output :string :error-output :string :ignore-error-status t)
                  (declare (ignore o e))
                  (and (zerop code) (probe-file spt)))
              ;; run-program throws if the executable itself can't be found -> treat as "can't check"
              (error () nil))))
      (prog1
          (cond
            (disasm-ok (and (search opcode (uiop:read-file-string spt)) t))
            (t (format t "(opcode check skipped: llvm-spirv unavailable) ")
               t))    ; can't disassemble on this box -> SKIP (don't block), let host-run proceed
        (unless *keep-work*
          (when (probe-file spt) (delete-file spt))
          ;; only delete a .spv WE created on a temp path; never the shared hoist artifact
          (when (and own-compile-p (probe-file spv)) (delete-file spv)))))))

(defun validate-l0-async-copy (file cpp-files)
  "Endeavor 136 SPV Chapter 1 (1D): assert the .spv actually uses OpGroupAsyncCopy
   (not the sync fallback), THEN compile+run the L0 harness and check HOIST-EXPECT."
  (if (not (%spv-contains-opcode-p file "GroupAsyncCopy"))
      (progn (format t "FAIL: SPV has no OpGroupAsyncCopy (sync fallback still active)~%") nil)
      (validate-l0-host-run file cpp-files)))

(defun validate-l0-mma-async (file cpp-files)
  "Endeavor 136 SPV Chapter 1 (2D): assert per-row OpGroupAsyncCopy in the .spv, THEN
   run the --mma-test host-reference check (MMA_CORRECT)."
  (if (not (%spv-contains-opcode-p file "GroupAsyncCopy"))
      (progn (format t "FAIL: SPV has no OpGroupAsyncCopy (sync fallback still active)~%") nil)
      (validate-l0-mma-run file cpp-files)))


;; tests/run-specs.lisp
(defun validate-ptx-tma-grad (file ptx-string)
  "Endeavor 145 / BUG 038 — validates that the BACKWARD of a TMA-staging sub-function actually
   scatters a gradient, rather than merely compiling.

   137/04 cannot be gradient-checked numerically ANYWHERE: VERIFY-AUTODIFF has only :l0 and
   :opencl runtimes so it cannot drive a PTX backward, and the kernel cannot be lowered on
   SPV/GENERIC at all because a :block load inside a device sub-function falls back to a sync
   path needing `get-local-id`.  The mechanism it exercises IS proven numerically, by 145/17
   (void sub-function, exact gradient on BMG); what is unproven here is only that the TMA
   staging variant reaches the same place.

   So this validator asserts the one thing structural evidence CAN establish, and asserts it
   rather than leaving it to be eyeballed.  Before the 038 fix the backward kernel was EMPTY —
   zero global writes — because a void sub-function call was silently dropped by the AD walk.
   The fix inlines the callee, so the `load-tile` inside `stage` now produces its
   %load-tile-at-bwd edge: read the tile's adjoint from SHARED, atomically accumulate it into
   the GLOBAL source.  That pair of opcodes is the signature of a gradient actually flowing
   through the sub-function, and its ABSENCE is the exact regression that hid for a whole
   endeavor.

   Deliberately NOT a correctness proof — a wrong-but-present scatter would pass.  It is a
   guard against the backward silently becoming empty again."
  (declare (ignore file))
  (unless (search "tma_subfn_grad" ptx-string)
    (format *error-output* "FAIL: no backward kernel 'tma_subfn_grad' in the PTX.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; The gradient scatter itself.  f32 atomic add into global = adjoint accumulation.
  (unless (search "atom.global.add.f32" ptx-string)
    (format *error-output*
            "FAIL: backward has NO gradient scatter (expected 'atom.global.add.f32').~%~
             This is BUG 038's signature: an empty backward that still compiles.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; ...sourced from the staged tile in shared memory, which is what makes it the tile's
  ;; adjoint rather than some unrelated accumulation.
  (unless (search "ld.shared" ptx-string)
    (format *error-output*
            "FAIL: gradient scatter is not fed from shared memory — the staged tile's adjoint~%~
             is not what is being accumulated.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; The forward TMA staging must still be there: the point is that AD did not cost us the
  ;; descriptor-driven copy.
  (unless (search "cp.async.bulk.tensor" ptx-string)
    (format *error-output* "FAIL: forward TMA staging (cp.async.bulk.tensor) lost under --differentiate.~%")
    (return-from validate-ptx-tma-grad nil))
  t)

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
             ((string= arg "--differentiate") (setf *compile-differentiate* t))
             ((string= arg "--only-unit-tests") (setf *only-unit-tests* t))
             ((string= arg "--skip-unit-tests") (setf *skip-unit-tests* t))
             ((string= arg "--keep-work") (setf *keep-work* t))
             ((string= arg "--no-quit") (setf *no-quit* t))
             ((and (> (length arg) 9) (string= (subseq arg 0 9) "--filter="))
               (setf *test-filter* (subseq arg 9)))))

    ;; Re-initialize with user-requested log level
    (initialize-compiler :log-level cl-user::*log-level*
                         :differentiate *compile-differentiate*)

    (format t "~&Locating specs in ~a~%" spec-dir)
    (format t "Configuration: Binary: ~a, Debug: ~a, Single-Pass: ~a, Differentiate: ~a~%"
      *use-binary* *compile-debug* *compile-single-pass* *compile-differentiate*)
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
          (unless *no-quit* (uiop:quit 0))
          (return-from main))

    (format t "~&~%=== Running E2E Spec Tests ===~%")
    (format t "~&Locating specs in ~a~%" spec-dir)
    (when stop-target
          (format t "Stop Target Active: Running tests up to directory '~a'~%" stop-target))

    ;; Sort mainly to ensure numerical order of directories (010-... before 011-...)
    (setf spec-files (sort spec-files #'string< :key #'namestring))

    (loop for file in spec-files do
            (when (or (not *test-filter*) (search *test-filter* (namestring file)))
                  (let* ((dir-name (get-parent-directory-name file))
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

                    ;; Force garbage collection to prevent OOM during large test suites (e.g. coverage runs)
                    (sb-ext:gc :full t)

                    ;; Run test and check expectation
                    (let ((test-passed (run-spec-file file)))
                      (when (search "multipass" (pathname-name file))
                            (format t "DEBUG MAIN: File: ~a. TestPassed: ~a. ExpectFail: ~a~%"
                              (pathname-name file) test-passed expect-failure))

                      (cond
                       ;; Test was skipped
                       ((eq test-passed :skipped)
                         (incf passed))

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
    (format t "Run Configuration: Binary=~a, Debug=~a, SinglePass=~a, Differentiate=~a~@[, Filter=~a~]~%"
      *use-binary* *compile-debug* *compile-single-pass* *compile-differentiate* *test-filter*)
    (format t "Spec Summary: ~a/~a Passed.~%" passed total)
    (when failed-files
          (format t "Failed Specs:~%~{  - ~a~%~}" (nreverse failed-files)))

    (if (= passed total)
        (unless *no-quit* (uiop:quit 0))
        (if *no-quit*
            (error "Spec Summary: ~a/~a Passed." passed total)
            (uiop:quit 1)))))

;; Load overlay if present (for safe patching)
(let ((overlay (merge-pathnames "overlays/spec-runner-overlay.lisp" (uiop:getcwd))))
  (when (probe-file overlay)
        (format t "Loading overlay: ~a~%" overlay)
        (load overlay)))

(main)
