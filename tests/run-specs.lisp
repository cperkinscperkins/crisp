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

(defun %cleanup-spec-device-modules (file)
  "Deletes the device modules and metadata that FILE's COMPILE-WITH / TEST-WITH
   passes emitted next to the source: <base>.spv, <base>_grad.spv and their .ptx
   and .metacrisp twins.  Prefix-matched on the spec's base name, so the _grad
   companions go too.

   WHY THIS EXISTS.  run-single-spec-pass -- the executor for COMPILE-WITH and
   TEST-WITH -- never deleted anything.  The FFI path, the hoist path and
   VERIFY-AUTODIFF each clean up after themselves, so the compile passes had been
   relying, silently and by accident, on VERIFY-AUTODIFF's: it deletes its fwd/bwd
   .spv, and those are THE SAME PATHS the compile passes write.  So a spec with a
   VERIFY-AUTODIFF directive looked tidy, and a spec without one -- every
   compile-only and every negative spec -- left its .spv behind forever.

   That accident also made the symptom read backwards.  Running 149 WITH
   --differentiate left 2 files and WITHOUT it left 12, because --differentiate is
   what lets VERIFY-AUTODIFF run and sweep up on the compile passes' behalf.

   The residue was invisible because tests/spec/.gitignore ignores every emitted
   type, so `git status` never showed it accumulating.  Left alone it can also mask
   a later run: a stale .spv beside a spec that no longer compiles still satisfies
   anything that merely probes for the file.

   Callers skip this when the spec FAILED, matching the hoist block's convention
   that a failure leaves its evidence on disk, and skip it under --keep-work.

   DO NOT WIDEN THE TYPE LIST WITHOUT CHECKING `git ls-files`.  It is limited to
   spv / ptx / metacrisp because those have ZERO tracked files under tests/spec --
   they are always throwaway.  `.ll` is NOT safe: nine of them are checked in as
   fixtures under 099-incomplete-types-revisited.  tests/spec/.gitignore lists
   *.ll, which makes them look disposable, but .gitignore does not apply to files
   already tracked -- so adding \"ll\" here would delete repo content on every
   green run, and `git status` would report it as a deletion rather than a stray."
  (let ((base (pathname-name file))
        (dir (pathname-directory file)))
    (dolist (type '("spv" "ptx" "metacrisp"))
      (dolist (f (directory (make-pathname :directory dir :name :wild
                                           :type type :defaults file)))
        (when (and (stringp (pathname-name f))
                   (uiop:string-prefix-p base (pathname-name f)))
          (ignore-errors (delete-file f)))))))

(defun run-spec-file (file)
  (let* ((directives (extract-test-directives file))
         (is-adv (search "adversarial" (namestring file)))
         (needs-diff (loop for d in directives thereis (or (search "differentiate" d :test #'char-equal)
                                                           (search "autodiff" d :test #'char-equal))))
         (*compile-differentiate* (if (and is-adv needs-diff) t *compile-differentiate*))
         (all-passed t)
         (vad-skipped nil)
         (hoist-skipped nil))

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
                (if (eq hoist-result :skipped)
                    (setf hoist-skipped t)
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
          (let ((vad-result (run-verify-autodiff-pass file vad-spec)))
            (cond
             ((eq vad-result :skipped) (setf vad-skipped t))
             ((not vad-result) (setf all-passed nil)))))))

    ;; 5. Cleanup: the device modules this spec's compile passes emitted.  Every
    ;; other path already tidies up after itself; the COMPILE-WITH / TEST-WITH
    ;; passes never did.  See %cleanup-spec-device-modules for why that went
    ;; unnoticed for so long.  Deliberately LAST, after every pass for this file
    ;; has finished: a validator may read <base>.spv during a later pass of the
    ;; same spec (%spv-contains-opcode-p), and the hoist path shares its artifact
    ;; across steps, so deleting per-pass would pull the rug out from under both.
    (when (and all-passed (not *keep-work*))
      (%cleanup-spec-device-modules file))

    (multiple-value-bind (known-issue-id known-issue-scope) (parse-known-issue directives)
      (if known-issue-id
          (let ((expect-fail-dir (eq (parse-test-expect directives) :fail)))
            (if all-passed
                (let ((scope-skipped-p
                       (cond
                        ((string-equal known-issue-scope "verify-autodiff")
                         (or vad-skipped (not *compile-differentiate*)))
                        ((string-equal known-issue-scope "differentiate")
                         (not *compile-differentiate*))
                        ((string-equal known-issue-scope "hoist")
                         (or hoist-skipped (and (parse-test-hoist directives) *compile-differentiate*)))
                        (t nil))))
                  (if scope-skipped-p
                      (progn
                        (format t "KNOWN-ISSUE ~a hidden (scope ~a was skipped)~%" known-issue-id known-issue-scope)
                        :skipped)
                      (if expect-fail-dir
                          (progn
                            (format t "KNOWN-FAIL (~a)~%" known-issue-id)
                            :known-fail)
                          (progn
                            (format t "UNEXPECTED-PASS (Known Issue ~a passed unexpectedly!)~%" known-issue-id)
                            :unexpected-pass))))
                (if expect-fail-dir
                    (progn
                      (format t "UNEXPECTED-PASS (Known Issue ~a compiler correctly failed!)~%" known-issue-id)
                      :unexpected-pass)
                    (progn
                      (format t "KNOWN-FAIL (~a)~%" known-issue-id)
                      :known-fail))))
          all-passed))))


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



(in-package :crisp.compiler)

;; tests/run-specs.lisp
(defun %152-backward-metacrisp-p (txt)
  "T if TXT is a BACKWARD kernel's metacrisp.  The AD pass names its kernel <name>_grad
   and writes it to its own file, so the kernel name is the reliable tell."
  (and txt (search "_grad\"" txt)))

;; tests/run-specs.lisp
(defun %152-assert-no-schedule-leak (txt what)
  "Endeavour 146's thesis as an assertion: a backward kernel must NOT carry the
   forward's scheduling declarations.  cluster-size is data movement -- it changes when
   and where bytes arrive, not what is computed -- so a derivative has no use for it and
   its presence would mean a schedule had leaked into the math."
  (cond
    ((search ":cluster-size" txt)
     (format *error-output* "FAIL (~a): the BACKWARD kernel's metacrisp carries :cluster-size.  Scheduling declarations must not propagate into a derivative -- cluster-size says where bytes arrive, not what is computed.~%" what)
     nil)
    ((search ":effective-cluster-size" txt)
     (format *error-output* "FAIL (~a): the BACKWARD kernel's metacrisp carries :effective-cluster-size.~%" what)
     nil)
    (t t)))

;; tests/run-specs.lisp
(defun %152-degrade-check (metacrisp-path)
  "Rung 05.  On a FORWARD metacrisp: assert the degrade was recorded (declaration kept,
   effective extent collapsed to 1).  On a BACKWARD one: assert the schedule did not leak."
  (let* ((p (if (listp metacrisp-path) (first metacrisp-path) metacrisp-path))
         (txt (and p (probe-file p) (uiop:read-file-string p))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: metacrisp not found (~a).~%" metacrisp-path) nil)
      ((%152-backward-metacrisp-p txt)
       (%152-assert-no-schedule-leak txt "rung 05 backward"))
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record -- the DECLARATION should survive even when the cluster degrades.~%") nil)
      ((not (search ":effective-cluster-size (1 1 1)" txt))
       (format *error-output* "FAIL: expected :effective-cluster-size (1 1 1) on a target without cluster support; the degrade was not recorded.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun %152-extent-check (metacrisp-path)
  "Rung 03.  On a FORWARD metacrisp: assert both records exist and the cluster actually
   formed.  On a BACKWARD one: assert the schedule did not leak."
  (let* ((p (if (listp metacrisp-path) (first metacrisp-path) metacrisp-path))
         (txt (and p (probe-file p) (uiop:read-file-string p))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: metacrisp not found (~a).~%" metacrisp-path) nil)
      ((%152-backward-metacrisp-p txt)
       (%152-assert-no-schedule-leak txt "rung 03 backward"))
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record.~%") nil)
      ((not (search ":effective-cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :effective-cluster-size record -- without it a degraded cluster is indistinguishable from a working one.~%") nil)
      ((search ":effective-cluster-size (1 1 1)" txt)
       (format *error-output* "FAIL: :effective-cluster-size is (1 1 1) on a cluster-capable target -- the cluster did NOT form, though the kernel still computes correctly.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (metacrisp-path)
  "Rung 05, metadata-path arity (one argument: the .metacrisp path)."
  (%152-degrade-check metacrisp-path))



(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (file &optional ignored)
  "Rung 05, PTX-path arity (FILE plus emitted text, which is ignored)."
  (declare (ignore ignored))
  (crisp.compiler::%152-degrade-check (%152-find-metacrisp file)))

;; tests/run-specs.lisp
(defun validate-metacrisp-cluster-extent (file &optional ignored)
  "Rung 03, PTX-path arity (FILE plus emitted text, which is ignored)."
  (declare (ignore ignored))
  (crisp.compiler::%152-extent-check (%152-find-metacrisp file)))

(in-package :crisp.spec-runner)



(defun %152-index-of (needle hay)
  "Character index of NEEDLE in HAY, or NIL."
  (search needle hay))

(defun %152-find-metacrisp (file)
  "The .metacrisp for the kernel THIS pass compiled, next to FILE.

   Under --differentiate the compiler emits only the backward kernel's sidecar
   (<stem>_grad_<kernel>.metacrisp); otherwise the forward's.  Both can be present on disk at
   once because the runner does not clean them up, so choose deliberately instead of taking
   whatever `directory` lists first."
  (let* ((dir  (make-pathname :name nil :type nil :defaults file))
         (stem (pathname-name file))
         (hits (directory (merge-pathnames (format nil "~a*.metacrisp" stem) dir)))
         (gradp (lambda (p) (search "_grad" (pathname-name p))))
         (want  (if *compile-differentiate*
                    (remove-if-not gradp hits)
                    (remove-if gradp hits))))
    (or (first want) (first hits))))




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
        ;; Endeavour 155: honor --hardware-profile=<NAME> in TEST-WITH flags.  Without this the
        ;; flag is SILENTLY DROPPED, and a spec that names a profile compiles without one -- which
        ;; fails with "load-tile into a register-tile requires a hardware profile" while the same
        ;; command line succeeds by hand.  This is the THIRD instance of the class: endeavour 137
        ;; added --ir-target-arch here for the same reason, and 152 found run-spec-ptx-binary
        ;; forwarding exactly one flag and dropping the rest.  Flags in a TEST-WITH list are a
        ;; promise; anything not forwarded should be refused, not ignored.
        (*compile-hardware-profile*
          (let ((hf (find-if (lambda (f) (and (stringp f) (search "--hardware-profile=" f))) flags)))
            (if hf (subseq hf (length "--hardware-profile=")) *compile-hardware-profile*)))
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
          ((eq ir-target :ptx)    (run-spec-ptx-in-process file :emit-metadata emit-metadata :validator validator))
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




;; NOTE: compile-crisp-file-to-ptx and compile-crisp-file-to-llvmir have the same omission.  They
;; are deliberately NOT changed here -- no spec currently needs a profile on those paths, and
;; changing an entry point that no failing test exercises is how silent breakage gets introduced.
;; When one does need it, this is the pattern.
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
                                                      :differentiate *compile-differentiate*
                                                      ;; Endeavour 155: the missing argument -- see header.
                                                      :hardware-profile *compile-hardware-profile*)
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
  "Lazy-loads the on-metal AD runner.  Returns :READY if the file loaded,
   :UNAVAILABLE if the load itself failed.  Caches the result in
   *VAD-RUNNER-STATUS*.

   Endeavor 147: :READY no longer implies a usable GPU.  Each runtime's
   bindings load tolerantly and set an availability flag, so the file loads
   on a machine with none of them; which runtime (if any) a given spec can
   actually use is decided per spec by CL-USER::AD-SELECT-RUNTIME."
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
                        ;; Endeavor 147: a :kind :tensor-map implicit param (the
                        ;; CUtensorMap descriptor Crisp mints for a :block TMA
                        ;; kernel) carries NO :type key.  The old code read
                        ;; (second (getf p :type)) -> NIL and fell into the
                        ;; unsupported-elem-type ERROR below, so a TMA spec
                        ;; CRASHED here rather than reaching the device.  Pass it
                        ;; through with its own shape instead; its physical width
                        ;; is 1 (a single descriptor pointer), which keeps every
                        ;; downstream arg-base offset correct.
                        when (eq (getf p :kind) :tensor-map)
                          collect (let ((range (getf p :range)))
                                    (list :kind :tensor-map
                                          :name (getf p :name)
                                          :describes (getf p :describes)
                                          :element-type (getf p :element-type)
                                          :rank (getf p :rank)
                                          :box-dims (getf p :box-dims)
                                          :layout (or (getf p :layout) :row-major)
                                          :swizzle (or (getf p :swizzle) :none)
                                          :base (first range)
                                          :arg-width (1+ (- (second range) (first range)))))
                        else
                        collect
                        (let* ((range (getf p :range))
                               (size (getf p :size-expr))
                               (type-spec (getf p :type))
                               (elem-type (second type-spec))
                               (elem-bytes
                                 (case elem-type
                                   ((float)  4)
                                   ((double) 8)
                                   ((int ulong long) 8)
                                   (t (error "%vad-read-implicit-params: unsupported elem-type ~A in ~A"
                                             elem-type type-spec))))
                               ;; Endeavor 145 (P6): a 2-D scratch tile's :size-expr is a
                               ;; LIST (ROWS COLS), not an integer.  Carry :rows / :cols
                               ;; through for the 9-arg matrix binding and make
                               ;; :n-elements their product so every consumer still sees
                               ;; an element count.
                               (dims (and (listp size) size)))
                          (list :base (first range)
                                :n-elements (if dims (reduce #'* dims) size)
                                :rows (and dims (first dims))
                                :cols (and dims (second dims))
                                ;; 147/08: a RING is a rank-3 scratch tensor whose
                                ;; :size-expr is (SLOTS ROWS COLS), so :rows/:cols
                                ;; describe it wrongly and its descriptor is 12 slots
                                ;; wide.  Carry the whole dims list so the binder can
                                ;; build a rank-N tensor record instead of guessing.
                                :dims dims
                                :elem-bytes elem-bytes
                                :arg-width (1+ (- (second range) (first range)))))))))))))))

(defun %vad-compile-spv (file &key differentiate precision denormal
                                   (target "spv") arch)
  "Compiles FILE to a device module via the crisp-compile binary.

   TARGET is the --ir-target value and also the output extension: \"spv\"
   for the SPIR-V runtimes (:l0 / :opencl) and \"ptx\" for :cuda
   (endeavor 147).  ARCH, when given, is forwarded as --ir-target-arch —
   an sm_90a kernel (TMA / wgmma) will not compile without it, and the
   spec's own HOIST-ARCH directive is the source of truth.

   When DIFFERENTIATE is T, passes --differentiate and expects
   <basename>_grad.<target>.  PRECISION (:fast/:ieee) and DENORMAL
   (:ftz/:preserve), when given, are forwarded as --math-precision /
   --denormal-handling so the fwd + bwd kernels are compiled under the
   same FP mode (Endeavor 128 Phase 5).
   Returns the output pathname on success, NIL on error."
  (let* ((bin (get-binary-path))
         (base-name (if differentiate
                        (format nil "~a_grad" (pathname-name file))
                        (pathname-name file)))
         (out-path (make-pathname :name base-name :type target :defaults file))
         (args (list (uiop:native-namestring file)
                     (format nil "--ir-target=~a" target)
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
    ;; Endeavor 147: forward HOIST-ARCH.  The hoist path has always done this
    ;; (see run-spec-with-hoist); the verify path never did, because it only
    ;; ever targeted SPV.  A :block / wgmma kernel needs sm_90a here or the
    ;; compile fails the arch gate long before any gradient is computed.
    (when arch
      (push (format nil "--ir-target-arch=~a" arch) args))
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
        (format *error-output* "~&VERIFY-AUTODIFF: ~a ~:@(~a~) not produced at ~a~%"
                (if differentiate "backward" "forward") target out-path)
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
     (format t "SKIP (on-metal AD runner unavailable)~%")
     :skipped)
    (:ready
     (let* ((pinned-runtime (getf spec :runtime))
            (selected-runtime (cl-user::ad-select-runtime pinned-runtime))
            (inputs (getf spec :inputs))
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
        ;; Endeavor 147: no usable on-metal runtime.  A SPEC-PINNED backend
        ;; that is absent skips loudly (naming what it wanted) so a CUDA-only
        ;; box does not look like it verified an Intel kernel, and vice versa.
        ((null selected-runtime)
         (if pinned-runtime
             (format t "SKIP (VERIFY-AUTODIFF pinned to ~A; not available here)~%"
                     pinned-runtime)
             (format t "SKIP (no on-metal AD runtime available)~%"))
         :skipped)
        (t
         (let* ((cl-user::*ad-runtime* selected-runtime)
                ;; :cuda consumes PTX; :l0 / :opencl consume SPIR-V.
                (target (if (eq selected-runtime :cuda) "ptx" "spv"))
                (arch (parse-hoist-arch (extract-test-directives file)))
                (fwd-spv (%vad-compile-spv file :differentiate nil :precision precision
                                                :denormal denormal :target target :arch arch))
                (bwd-spv (and fwd-spv (%vad-compile-spv file :differentiate t :precision precision
                                                             :denormal denormal :target target :arch arch)))
                (result nil))
           ;; *ad-runtime* lives in the LAZILY-loaded runner, so at compile time
           ;; of this file the symbol is not yet proclaimed special and a plain
           ;; LET would bind it LEXICALLY — leaving the runner reading its own
           ;; global :l0 and silently verifying on the wrong runtime.  This
           ;; declaration makes the binding dynamic, which is the whole point.
           (declare (special cl-user::*ad-runtime*))
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
                                    (format t "PASS [~(~A~)] (~A)~%" selected-runtime (%vad-format-results results))
                                    t)
                                   (t
                                    (format *error-output* "FAIL (~{~A~^; ~})~%" failures)
                                    nil))))
                               (t
                                (format t "PASS [~(~A~)] (~A)~%" selected-runtime (%vad-format-results results))
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

#|
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
            |#


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
                                            ;; Endeavour 155: no metadata was requested, so the
                                            ;; thing worth validating is the MODULE.  See header.
                                            ((null meta-paths) out-path)
                                            ((and (listp meta-paths) (null (remove nil meta-paths))) out-path)
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
    ;; Endeavour 155: forward the selected hardware profile.  run-single-spec-pass binds it from
    ;; a TEST-WITH --hardware-profile= flag; without this push the BINARY path would still drop
    ;; it, so --use-binary and the in-process runner would disagree about which profile is active.
    (when *compile-hardware-profile*
      (push (format nil "--hardware-profile=~a" *compile-hardware-profile*) args))

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


(defun compile-crisp-file-to-ptx (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .ptx and returns (values out-path meta-paths).
   Endeavor 152: honours :emit-metadata, mirroring compile-crisp-file-to-spirv."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ptx" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type nil :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
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
             (let ((crisp.compiler:*target-backend* :ptx)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-ptx
                module out-path
                :compute-capability (crisp.compiler::ptx-compute-capability-string))
               (when emit-metadata
                 (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file
                        filepath meta-base-path
                        :output-targets (list (list :ptx out-path))
                        :forms forms)))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        (values nil nil))))

(defun run-spec-ptx-in-process (file &key (emit-metadata nil) (validator nil))
  "Endeavor 152: accepts :emit-metadata so a spec combining --metadata with --ir-target=ptx
   actually gets a sidecar.  The validator keeps the PTX-path arity (FILE PTX-TEXT); validators
   that assert on metadata locate the sidecar themselves."
  (handler-case
      (multiple-value-bind (out-path meta-paths)
          (compile-crisp-file-to-ptx file :emit-metadata emit-metadata)
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
              ;; Clean BOTH artifacts.  Leaving sidecars behind is what made this failure look
              ;; intermittent in the first place.
              (unless *keep-work*
                (when (probe-file out-path) (delete-file out-path))
                (dolist (mp (if (listp meta-paths) meta-paths (list meta-paths)))
                  (when (and mp (probe-file mp)) (delete-file mp))))
              res)
            (progn (format *error-output* "FAIL (No PTX generated)~%") nil)))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))


(defun validate-ptx-cluster-dims (file ptx-string)
  "Endeavor 152 rung 01/02 — the kernel's cluster shape must reach the PTX.

   A kernel can declare (cluster-size ...) and compile perfectly while emitting no
   cluster directive at all -- that was the behaviour before this endeavor, since an
   unrecognised declare clause is silently ignored.  The kernel would then launch
   unclustered, compute the correct answer, and lose every bit of the bandwidth
   reduction the declaration was written for.  No correctness test can see that, so
   this validator reads the emitted instruction instead."
  (declare (ignore file))
  (let ((missing '()))
    (dolist (exp '(".explicitcluster" ".reqnctapercluster"))
      (unless (search exp ptx-string) (push exp missing)))
    (cond
      (missing
       (format *error-output* "FAIL: PTX carries no cluster directive; missing ~{~a~^ and ~}.~%  A kernel declaring cluster-size that emits no .reqnctapercluster will launch UNCLUSTERED and still be numerically correct.~%"
               (nreverse missing))
       nil)
      (t t))))

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
    ;; Endeavor 152: forward --metadata too.  A spec that wants to assert on the
    ;; .metacrisp *and* pin an arch carries both flags; dropping this one meant the
    ;; metacrisp was never written and the validator failed on a missing file.
    (when (find-if (lambda (f) (and (stringp f) (string= f "--metadata"))) flags)
      (push "--metadata" args))

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

(defun parse-known-issue (directive-lines)
  "Parses KNOWN-ISSUE[scope]: <ID> or KNOWN-ISSUE: <ID> from header comments.
   Returns (values id scope), where scope is a string (e.g. \"verify-autodiff\") or NIL."
  (dolist (line directive-lines)
    (let ((trimmed (string-left-trim ";; " line)))
      (when (starts-with trimmed "KNOWN-ISSUE")
        (let* ((end-bracket (position #\] trimmed))
               (colon (position #\: trimmed :start (or end-bracket 0)))
               (scope (when end-bracket (subseq trimmed 12 end-bracket)))
               (id (when colon (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed (1+ colon))))))
          (return-from parse-known-issue (values id scope))))))
  (values nil nil))

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



(defun validate-ptx-cluster-barrier (file ptx-string)
  "Endeavor 152 rung 20 — a :mode :cluster barrier must be a REAL mbarrier object.
   Asserts only that; the remote arrive that distinguishes it is rung 21's job."
  (declare (ignore file))
  (if (search "mbarrier.init" ptx-string)
      t
      (progn (format *error-output* "FAIL: no mbarrier.init — a :cluster barrier must allocate a real mbarrier, as :block does.~%")
             nil)))


;; tests/run-specs.lisp
(defun validate-ptx-cluster-ring-arrivals (file ptx-string)
  "Endeavor 152 rung 22 — :arrivals is per-workgroup and the COMPILER multiplies.

   The kernel declares a 2-workgroup cluster, a :block `full` ring with :arrivals 1, and a
   :cluster `empty` ring with :arrivals 2.  So the emitted mbarrier init counts must be:
       full  -> 1   (NOT scaled: a multicast completes on each destination's OWN barrier)
       empty -> 4   (2 per workgroup x 2 workgroups arriving all-to-all)
   Both halves are asserted.  Scaling the wrong one is as fatal as scaling neither: a `full`
   barrier initialised to 2 would never complete, and an `empty` initialised to 2 would complete
   early and let a workgroup overwrite a slot a peer was still reading."
  (declare (ignore file))
  (let ((has1 (search "mov.b32 	%r11, 1;" ptx-string))
        (has4 (search ", 4;" ptx-string)))
    (declare (ignorable has1))
    (cond
      ((null (search "mbarrier.init" ptx-string))
       (format *error-output* "FAIL: no mbarrier.init at all.~%") nil)
      ((null has4)
       (format *error-output* "FAIL: no init count of 4 — the :cluster ring's :arrivals 2 was not scaled by the group extent 2.  The barrier would complete one full round of arrivals early.~%") nil)
      (t t))))


(defun validate-ptx-cluster-remote-arrive (file ptx-string)
  "Endeavor 152 rung 21 — `signal` on a :cluster barrier must arrive on PEERS.

   UPDATED after a hardware finding.  The first version looked for `mapa.shared::cluster`, which
   was the form Crisp emitted -- and that form DOES NOT MAP.  Compiling NVIDIA's own
   cluster_group::map_shared_rank() shows the required sequence goes through a GENERIC address:

       cvta.shared.u64    <generic>, <shared offset>
       mapa.u64           <peer>,    <generic>, <rank>
       cvta.to.shared.u64 <shared>,  <peer>
       mbarrier.arrive.shared::cluster.b64 _, [<shared>];

   Handing `mapa` a raw shared-window offset silently yields an UNMAPPED address, so the arrive
   lands on the caller's own barrier -- exactly the silent-local-arrive failure this validator
   exists to catch.  On an H100 that surfaced as
       Invalid __shared__ read ... Address 0x0 is not located in executing CTA.

   So the assertion is now on the CONVERSION, not merely on the presence of a mapa: a `mapa` that
   is not bracketed by the generic round-trip is the bug, not the fix."
  (declare (ignore file))
  (let ((cvta-in  (search "cvta.shared.u64" ptx-string))
        (mapa     (search "mapa.u64" ptx-string))
        (cvta-out (search "cvta.to.shared.u64" ptx-string))
        (arr      (search "mbarrier.arrive.shared::cluster" ptx-string))
        (oldform  (search "mapa.shared::cluster" ptx-string)))
    (cond
      (oldform
       (format *error-output* "FAIL: emits `mapa.shared::cluster` on a raw shared offset.  That form does not map -- the arrive would land on the CALLER'S OWN barrier while the peer waits forever.  Use the generic round-trip (cvta.shared.u64 -> mapa.u64 -> cvta.to.shared.u64).~%") nil)
      ((null arr)
       (format *error-output* "FAIL: no `mbarrier.arrive.shared::cluster` -- the arrive is not cluster-scoped.~%") nil)
      ((null mapa)
       (format *error-output* "FAIL: no `mapa.u64` -- nothing maps the barrier into a peer's view, so any arrive is local.~%") nil)
      ((or (null cvta-in) (null cvta-out))
       (format *error-output* "FAIL: `mapa.u64` is present but not bracketed by the generic conversion (cvta.shared.u64 in, cvta.to.shared.u64 out).  mapa operates on GENERIC addresses; a raw shared offset yields an unmapped result.~%") nil)
      ((> mapa arr)
       (format *error-output* "FAIL: the cluster arrive precedes the mapa that computes its peer address.~%") nil)
      (t t))))


;;; =====================================================================
;;; Endeavor 152 step 10 — validators for N-D multicast
;;; =====================================================================

(defun %152-all-indices (needle hay)
  "Every start position of NEEDLE in HAY."
  (let ((hits '())
        (start 0))
    (loop for pos = (search needle hay :start2 start)
          while pos
          do (push pos hits)
             (setf start (1+ pos)))
    (nreverse hits)))


(defun %152-mask-constants (ptx-string)
  "The distinct 16-bit constants moved into a register in this PTX, as integers.

   The ctaMask is a .b16 operand, so `mov.b16 %rsN, K` is where a multicast group's PATTERN
   becomes visible.  Reading them back is how a test can tell TWO DIFFERENT groups from two
   copies of the same one."
  (let ((out '()))
    (dolist (p (%152-all-indices "mov.b16" ptx-string) (sort (remove-duplicates out) #'<))
      (let* ((comma (position #\, ptx-string :start p))
             (eol   (position #\Newline ptx-string :start p)))
        (when (and comma eol (< comma eol))
          (let* ((tail (string-trim " ;	" (subseq ptx-string (1+ comma) eol)))
                 (v    (ignore-errors (parse-integer tail :junk-allowed t))))
            (when v (push v out))))))))

(defun %152-multicast-mask-operands (ptx-string)
  "The final operand of every `.multicast::cluster` copy -- i.e. each copy's ctaMask."
  (let ((out '()))
    (dolist (p (%152-all-indices "multicast::cluster" ptx-string) (nreverse out))
      (let* ((eol  (position #\Newline ptx-string :start p))
             (line (subseq ptx-string p eol))
             (tok  (string-trim " ;" (subseq line (1+ (or (position #\Space line :from-end t) 0))))))
        (push tok out)))))


(defun validate-ptx-multicast (file ptx-string)
  "Endeavor 152 rung 10 — assert the multicast MECHANISM engaged, not merely that the kernel
   compiled.

   This is the assertion that cannot be replaced by a correctness test.  A load-tile which
   quietly declined to multicast produces BYTE-IDENTICAL results -- each workgroup simply does
   its own fetch of the same tile -- so only the emitted instruction can distinguish a working
   multicast from a fallback.

   Four things are checked, and the last is the one that took the research:
     1. the bulk-tensor copy carries `.multicast::cluster`
     2. the leader is elected from `%cluster_ctarank` (one WORKGROUP issues, not one thread)
     3. `mbarrier.arrive.expect_tx` is present
     4. expect_tx PRECEDES the multicast copy in the emitted text -- i.e. it sits OUTSIDE the
        ctarank guard.  Every destination workgroup must announce the bytes it expects to
        RECEIVE on its own mbarrier; only the issuing one runs the copy.  Emitting expect_tx
        inside the guard would leave every non-issuing workgroup waiting forever on a barrier
        that was never told to expect anything -- a hang, not a wrong number."
  (declare (ignore file))
  (let* ((mc  (%152-index-of "multicast::cluster" ptx-string))
         ;; Step 10a: the leader is elected from the workgroup's CLUSTER POSITION.  For a 1-D
         ;; cluster that used to be %cluster_ctarank; for an N-D group it is a per-axis
         ;; %cluster_ctaid.<a> test, since the leader is the workgroup at 0 on every GROUP
         ;; axis rather than at rank 0 of the whole cluster.  Accept either -- the property
         ;; being asserted is "a WORKGROUP leader is elected, not a thread leader", and both
         ;; spellings establish it.
         (rank (or (%152-index-of "%cluster_ctarank" ptx-string)
                   (%152-index-of "%cluster_ctaid" ptx-string)))
         (etx (%152-index-of "mbarrier.arrive.expect_tx" ptx-string)))
    (cond
      ((null mc)
       (format *error-output* "FAIL: no `.multicast::cluster` in the emitted PTX -- the load did NOT multicast.  It would still compute the correct answer, at the bandwidth :multicast was written to avoid.~%")
       nil)
      ((null rank)
       (format *error-output* "FAIL: `.multicast::cluster` is emitted but neither %cluster_ctarank nor %cluster_ctaid is ever read, so no WORKGROUP leader is elected.  Every workgroup would issue the same multicast.~%")
       nil)
      ((null etx)
       (format *error-output* "FAIL: no mbarrier.arrive.expect_tx -- destination workgroups would never be told how many bytes to await.~%")
       nil)
      ((> etx mc)
       (format *error-output* "FAIL: mbarrier.arrive.expect_tx appears AFTER the multicast copy, which means it is inside the leader guard.  Non-issuing workgroups would wait on a barrier that was never told to expect anything -- a hang.~%")
       nil)
      (t t))))

(defun validate-ptx-multicast-2d (file ptx-string)
  "A 2-D cluster must give its two operands DIFFERENT multicast groups.

   THIS IS THE ASSERTION THAT MATTERS.  A lowering that multicast the WHOLE cluster for both
   operands would still emit two `.multicast::cluster` copies, still elect a leader, still run
   -- and would be WRONG, delivering one cluster column's B tile to a workgroup that wanted a
   different one.  This kernel only stores A, so no output check can see it.  The distinguishing
   evidence is that the two ctaMasks are DIFFERENT and are computed per workgroup.

   IT DELIBERATELY DOES NOT PIN AN INSTRUCTION SPELLING.  The first version of this validator
   required `shl.b16` / `mov.b16`, and failed against perfectly correct PTX: the in-process
   compile shifts in 32 bits then truncates (`shl.b32` + `cvt.u16.u32`) where the CLI compile
   narrows the shift to 16 (`mov.b16` + `shl.b16`).  Same IR, different optimisation level.
   Pinning the spelling tested LLVM's instruction selection rather than Crisp's grouping, so
   these checks are structural instead."
  (declare (ignore file))
  (let* ((copies (length (%152-all-indices "multicast::cluster" ptx-string)))
         (masks  (%152-multicast-mask-operands ptx-string))
         (ax     (search "%cluster_ctaid.x" ptx-string))
         (ay     (search "%cluster_ctaid.y" ptx-string)))
    (cond
      ((< copies 2)
       (format *error-output* "FAIL: expected TWO `.multicast::cluster` copies (one per operand), found ~a.~%" copies)
       nil)
      ((notevery (lambda (m) (and (plusp (length m)) (char= (aref m 0) #\%))) masks)
       (format *error-output* "FAIL: a ctaMask is an IMMEDIATE ~a, so that group is fixed at compile time.  In a 2-D cluster the group is a slice whose position depends on the workgroup, so the mask must be computed.~%" masks)
       nil)
      ((< (length (remove-duplicates masks :test (function string=))) 2)
       (format *error-output* "FAIL: both multicast copies use the SAME ctaMask register ~a.  A 2-D cluster needs one group per operand -- a shared mask means one workgroup's tile is delivered to another.~%" masks)
       nil)
      ((not (and ax ay))
       (format *error-output* "FAIL: both cluster axes must be consulted (x seen: ~a, y seen: ~a).  Each operand's group is positioned by the axis it is NOT grouped along.~%"
               (and ax t) (and ay t))
       nil)
      (t
       (format t "  [multicast-2d] ~a copies, distinct computed masks ~a, both cluster axes read.~%"
               copies masks)
       t))))


(defun %152-check-cluster-product (ptx-string expected)
  "Parse `.reqnctapercluster X, Y, Z` and check X*Y*Z."
  (let ((p (search ".reqnctapercluster" ptx-string)))
    (if (null p)
        (progn (format *error-output* "FAIL: no .reqnctapercluster directive in the emitted PTX.~%") nil)
        (let* ((eol  (position #\Newline ptx-string :start p))
               (raw  (subseq ptx-string p eol))
               ;; Drop the trailing "// @kernel_name" -- a kernel called cluster_of_4 puts
               ;; a digit in that comment, which would be scraped as a fourth dimension.
               (line (let ((c (search "//" raw))) (if c (subseq raw 0 c) raw)))
               (nums (let ((acc '()) (i 0))
                       (loop while (< i (length line))
                             ;; aref, not char: in :crisp.compiler `char` is the CRISP TYPE,
                             ;; not cl:char -- a documented trap in this codebase.
                             do (let ((c (aref line i)))
                                  (if (digit-char-p c)
                                      (multiple-value-bind (v j) (parse-integer line :start i :junk-allowed t)
                                        (push v acc) (setf i (or j (length line))))
                                      (incf i))))
                       (nreverse acc)))
               ;; the leading digits of "reqnctapercluster" are not present, so nums are the dims
               (prod (reduce #'* nums :initial-value 1)))
          (if (= prod expected)
              (progn (format t "  [cluster-extent] ~a -> product ~a.~%" nums prod) t)
              (progn (format *error-output* "FAIL: expected a cluster of ~a workgroups, but .reqnctapercluster says ~a (product ~a).~%"
                             expected nums prod)
                     nil))))))

(defun validate-ptx-cluster-extent-4 (file ptx-string)
  "A cluster of 4 reaches the PTX as `.reqnctapercluster` with a product of 4."
  (declare (ignore file))
  (%152-check-cluster-product ptx-string 4))

(defun validate-ptx-cluster-extent-8 (file ptx-string)
  "A cluster of 8 reaches the PTX as `.reqnctapercluster` with a product of 8.

   8 is worth its own rung because it is the largest PORTABLE cluster: the CUDA programming
   guide guarantees support up to 8, and anything beyond is opt-in per architecture.  It is
   also where a 16-bit ctaMask still has room -- a 16-CTA cluster fills it exactly."
  (declare (ignore file))
  (%152-check-cluster-product ptx-string 8))


;;; BUG 049 — a cluster-REACH kernel must REFUSE grid padding, not perform it.
(defun validate-cuda-cluster-no-pad (crisp-file cu-files)
  "The generated launcher for a multicast / :mode :cluster kernel must refuse a non-divisible
   grid instead of padding it up.

   WHY THIS IS ASSERTED ON THE GENERATED C++ AND NOT ON A RUN.  The failure it guards against is
   `unspecified launch failure` at ONE problem size -- N=256, where a 64x256 tile gives a 4x1 grid
   and a (2 2) cluster must pad the second axis, making half of every cluster padding.  Every
   larger size runs correctly, so a passing benchmark proves nothing; the evidence that the guard
   exists is in the emitted host code.

   Padding is still CORRECT, and still emitted, for a clustered kernel that does NOT use its
   cluster's reach -- surplus blocks really do just exit.  Spec 04 covers that side."
  (declare (ignore crisp-file))
  (let ((ok nil))
    (dolist (cu cu-files ok)
      (let ((content (uiop:read-file-string cu)))
        (when (search "reqnctapercluster" content)  ; not every emitted file is the kernel
          nil)
        (cond
          ((search "padding cannot be made safe here" content)
           (if (search "_px = ((gridX" content)
               (progn (format *error-output*
                        "FAIL: ~a emits BOTH the cluster-reach refusal AND the padding arithmetic.~%"
                        (file-namestring cu))
                      (return nil))
               (progn (format t "  [cluster-no-pad] ~a refuses padding, as required.~%"
                              (file-namestring cu))
                      (setf ok t))))
          ((search "_px = ((gridX" content)
           (format *error-output*
             "FAIL: ~a PADS the grid, but this kernel uses its cluster's reach.  Padded blocks are cluster members that a multicast addresses and a cluster barrier waits on, and they exit immediately -- this is BUG 049 and it manifests as `unspecified launch failure`.~%"
             (file-namestring cu))
           (return nil)))))))

;;; Endeavor 152 — (sync-cluster)
(defun validate-ptx-sync-cluster (file ptx-string)
  "On a Hopper target `(sync-cluster)` must lower to the cluster rendezvous, NOT a workgroup one.

   The distinction matters and is invisible in output: a `bar.sync` synchronises the threads of
   ONE workgroup, so a kernel that meant to rendezvous its whole cluster would run, produce
   plausible numbers, and simply not synchronise the peers it was written to synchronise."
  (declare (ignore file))
  (let ((cluster (search "barrier.cluster" ptx-string)))
    (if cluster
        (progn (format t "  [sync-cluster] emits barrier.cluster on sm_90.~%") t)
        (progn (format *error-output*
                 "FAIL: no `barrier.cluster` in the emitted PTX -- (sync-cluster) did not lower to a cluster rendezvous.~%")
               nil))))

(defun validate-ptx-sync-cluster-degrade (file ptx-string)
  "On a target with no clusters, `(sync-cluster)` must DEGRADE to a workgroup barrier -- and must
   not leave a `barrier.cluster` instruction behind in a module whose arch cannot execute one.

   The degrade is exact rather than approximate: a cluster of one workgroup IS a workgroup, and
   NVIDIA's cluster_group::sync() carries no separate __syncthreads(), so a cluster barrier
   already covers intra-workgroup convergence."
  (declare (ignore file))
  (let ((cluster (search "barrier.cluster" ptx-string))
        (bar     (search "bar.sync" ptx-string)))
    (cond
      (cluster (format *error-output*
                 "FAIL: `barrier.cluster` emitted for a pre-Hopper target, which cannot execute it.~%")
               nil)
      ((null bar) (format *error-output*
                    "FAIL: (sync-cluster) degraded to NOTHING -- expected a workgroup barrier (bar.sync).~%")
                  nil)
      (t (format t "  [sync-cluster] degrades to bar.sync, no cluster instruction left behind.~%") t))))


(defun validate-ptx-wgmma-group (file ptx-string)
  "Endeavour 154 — assert the wgmma k-slices are issued as WELL-FORMED GROUPS.

   THIS IS THE ASSERTION A CORRECTNESS TEST CANNOT MAKE.  The pre-154 lowering emitted
   `fence / mma_async / commit_group / wait_group 0` for EVERY k8 slice, so a K-block of 32
   emitted four of each.  That code is CORRECT -- it computes exactly the right answer -- but
   `wait_group 0` waits for ALL outstanding groups, so each async MMA was fully awaited before
   the next issued and the async in `mma_async` was defeated.  Measured cost on an H100 NVL:
   4.3% to 10.8% depending on size.  No numeric check can see it; only the emitted instruction
   sequence can.

   A well-formed group is:  fence, TWO OR MORE mma_async, commit_group, wait_group.

   The emitted opcodes must be a whole number of such groups and nothing else.  ONE group is the
   single-warpgroup case; a kernel with two consumer warpgroups emits TWO, which is equally
   correct -- the invariant is the SHAPE of each group, not how many there are.  Requiring >= 2
   mma_async per group is what stops a spec decaying into a vacuous pass: with a single-slice
   K-block the grouping property is untestable, and this must say so rather than go green."
  (declare (ignore file))
  (let ((ops '()) (pos 0))
    (loop
      (let ((i (search "wgmma." ptx-string :start2 pos)))
        (unless i (return))
        (let* ((end (or (position #\Newline ptx-string :start i) (length ptx-string)))
               (line (subseq ptx-string i end)))
          (push (cond ((eql 0 (search "wgmma.fence" line))        :fence)
                      ((eql 0 (search "wgmma.mma_async" line))    :mma)
                      ((eql 0 (search "wgmma.commit_group" line)) :commit)
                      ((eql 0 (search "wgmma.wait_group" line))   :wait)
                      (t :other))
                ops))
        (setf pos (1+ i))))
    (setf ops (nreverse (remove :other ops)))
    (if (null ops)
        (progn (format *error-output* "FAIL: no wgmma opcodes in the emitted PTX at all.~%") nil)
        (let ((rest ops) (groups 0))
          (loop
            (when (null rest) (return t))
            (unless (eq (first rest) :fence)
              (format *error-output* "FAIL: expected a wgmma.fence to open group ~a, got ~a.  Full opcode sequence: ~a~%"
                      (1+ groups) (first rest) ops)
              (return nil))
            (pop rest)
            (let ((n 0))
              (loop while (eq (first rest) :mma) do (pop rest) (incf n))
              (cond
                ((< n 2)
                 (format *error-output* "FAIL: group ~a has ~a wgmma.mma_async.  A group must hold TWO OR MORE, otherwise the grouping property is untestable -- use a MULTI-SLICE K-block (:swizzle :128b with K>8).  Pre-154 codegen produced exactly this shape: one mma per fence/commit/wait quadruple.~%"
                         (1+ groups) n)
                 (return nil))
                ((not (and (eq (first rest) :commit) (eq (second rest) :wait)))
                 (format *error-output* "FAIL: group ~a is not closed by commit_group then wait_group; found ~a then ~a.  Full opcode sequence: ~a~%"
                         (1+ groups) (first rest) (second rest) ops)
                 (return nil))
                (t (pop rest) (pop rest) (incf groups)))))))))

;; Endeavour 155.  The spec runner resolves validator names in DIFFERENT packages depending on
;; which pass invokes them — :crisp.compiler for the --ir-target=spv binary path, and
;; :crisp.spec-runner for the in-process paths.  Endeavour 152 hit this with
;; validate-cluster-degrade-warning and settled it the same way: define the name in BOTH,
;; delegating to ONE shared body so the two can never drift.

(defun validate-spv-bf16-coop (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-BF16-COOP" :crisp.compiler) spv-path))

(defun validate-spv-fp16-coop (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-FP16-COOP" :crisp.compiler) spv-path))

(defun validate-spv-tile-address-arith (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-TILE-ADDRESS-ARITH" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
;; Endeavour 157.  Same two-package delegation as the 155 coop validators: the spec runner resolves
;; validator names in its own package, while the implementation lives in :crisp.compiler.
(defun validate-spv-split-barrier (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-SPLIT-BARRIER" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
(defun validate-spv-fused-barrier-unchanged (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-FUSED-BARRIER-UNCHANGED" :crisp.compiler) spv-path))

;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 154 item 3 — scope the wgmma store validator to the forward kernel.
;;;; Was failing the whole --differentiate pass on a property the forward kernel still satisfies.

;; overlays/spec-runner-overlay.lisp
(defun %ptx-forward-entry-text (ptx-string)
  "The text of the FIRST non-gradient `.visible .entry` in PTX-STRING, or the whole string when no
   entry can be located.

   Under --differentiate a module carries the forward kernel AND its AD-minted twin, whose name ends
   in `_grad`.  Any validator asserting a property of the forward kernel by searching module text
   will otherwise see the twin's instructions too, and the twin is appended AFTER -- so every
   `search ... :from-end t` and every `:start2` bound silently spans both.

   Falling back to the whole string rather than erroring keeps a malformed or unexpected module a
   problem for the CALLER's assertion to report, which produces a message about the property under
   test instead of one about this helper."
  (let ((marker ".visible .entry")
        (starts '()))
    (let ((i (search marker ptx-string)))
      (loop while i do
        (push i starts)
        (setf i (search marker ptx-string :start2 (1+ i)))))
    (setf starts (nreverse starts))
    (if (null starts)
        ptx-string
        (loop for (start . rest) on starts
              for end = (or (first rest) (length ptx-string))
              ;; The entry's name runs from after the marker to the opening paren of its parameter
              ;; list.  A `_grad` suffix identifies the AD twin.
              for head = (subseq ptx-string start (min end (+ start 200)))
              for name = (string-trim " " (subseq head (length marker)
                                                  (or (position #\( head) (length head))))
              unless (let ((n (string-downcase (string-trim " " name))))
                       (and (>= (length n) 5) (string= "_grad" (subseq n (- (length n) 5)))))
                return (subseq ptx-string start end)
              finally (return ptx-string)))))

;; overlays/spec-runner-overlay.lisp  (REPLACES validate-ptx-wgmma-store-direct -- forward scoping)
(defun validate-ptx-wgmma-store-direct (file ptx-string)
  "Endeavour 154 item 3 — assert a wgmma accumulator stored via `store-tile-at` took the
   REGISTER-DIRECT path, not the cooperative element-loop path.

   WHY THIS NEEDS ASSERTING.  `store-tile-at` had no wgmma overload before 154; a wgmma
   accumulator handed to it fell through to the generic cooperative store, which stages through
   memory and brackets the copy with `sync-workgroup` on both sides.  For a warpgroup-private
   accumulator that is both wrong in shape and pointless in cost -- yet it can still produce the
   right answer, so a metal MMA_CORRECT check alone would not notice which path ran.

   The distinguishing signature is the BARRIER.  The register-direct store emits the
   accumulator straight to global with no workgroup synchronization at all, so no `bar.sync`
   may appear after the final `wgmma.wait_group`.  The cooperative path always emits one.

   SCOPED TO THE FORWARD KERNEL.  Under --differentiate the module also carries the AD-minted
   `_grad` twin, which legitimately uses barriers and is emitted after the forward kernel -- so an
   unscoped search reported the twin's barriers as a forward-kernel regression.  The claim is about
   the forward kernel, so the text examined is the forward kernel's."
  (declare (ignore file))
  (let* ((ptx-string (%ptx-forward-entry-text ptx-string))
         (last-wait (search "wgmma.wait_group" ptx-string :from-end t)))
    (cond
      ((null last-wait)
       (format *error-output* "FAIL: no wgmma.wait_group in the emitted PTX -- no wgmma ran, so this spec is not testing the store path it claims to.~%")
       nil)
      ((search "bar.sync" ptx-string :start2 last-wait)
       (format *error-output* "FAIL: a `bar.sync` appears AFTER the last wgmma.wait_group, which is the cooperative staged-store signature.  The wgmma accumulator store must be register-direct -- store-tile-at fell through to the generic path instead of the wgmma overload.~%")
       nil)
      (t t))))



(defun validate-spv-prefetch-partitioned (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-PREFETCH-PARTITIONED" :crisp.compiler) spv-path))

(defun validate-spv-prefetch-unpartitioned (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-PREFETCH-UNPARTITIONED" :crisp.compiler) spv-path))


(defun main ()
  (let* ((script-path (or *load-pathname* *compile-file-pathname*))
         (run-adversarial (member "--adversarial" (uiop:command-line-arguments) :test #'string=))
         ;; Assume tests/run-specs.lisp -> tests/spec/ (or tests/adversarial/)
         (spec-dir (if run-adversarial
                       (merge-pathnames "tests/adversarial/" (uiop:getcwd))
                       (merge-pathnames "tests/spec/" (uiop:getcwd))))
         (spec-files (directory (merge-pathnames "**/*.crisp" spec-dir)))
         (total 0)
         (passed 0)
         (adv-known-failures 0)
         (adv-unexpected-passes 0)
         (adv-actual-failures 0)
         (adv-passes 0)
         (adv-skipped 0)
         (failed-files '())
         (stop-target (if run-adversarial nil (get-ci-stop-target)))
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
                         (incf passed)
                         (incf adv-skipped))

                       ;; Test was intercepted as a known failure
                       ((eq test-passed :known-fail)
                         (incf passed)
                         (incf adv-known-failures))

                       ;; Test was intercepted as an unexpected pass
                       ((eq test-passed :unexpected-pass)
                         (push (format nil "~a/~a" dir-name (pathname-name file)) failed-files)
                         (incf adv-unexpected-passes))

                       ;; Test passed and we expected it to pass
                       ((and test-passed (not (eq test-passed :known-fail)) (not expect-failure))
                         (incf passed)
                         (incf adv-passes))

                       ;; Test failed and we expected it to fail
                       ((and (not test-passed) expect-failure)
                         (format t " (Expected failure)~%")
                         (incf passed)
                         (incf adv-known-failures))

                       ;; Test passed but we expected failure
                       ((and test-passed expect-failure)
                         (format *error-output* " ERROR: Test passed but was expected to fail!~%")
                         (push (format nil "~a/~a" dir-name (pathname-name file)) failed-files)
                         (incf adv-unexpected-passes))

                       ;; Test failed but we expected pass
                       (t
                         (push (format nil "~a/~a" dir-name (pathname-name file)) failed-files)
                         (incf adv-actual-failures)))))))

    (format t "~&---------------------------~%")
    (if run-adversarial
        (progn
          (format t "Adversarial Test Summary:~%")
          (format t "  Total Tests:       ~a~%" total)
          (format t "  Known Failures:    ~a~%" adv-known-failures)
          (format t "  Unexpected Passes: ~a~%" adv-unexpected-passes)
          (format t "  Actual Failures:   ~a~%" adv-actual-failures)
          (format t "  True Passes:       ~a~%" adv-passes)
          (when (> adv-skipped 0)
            (format t "  Skipped:           ~a~%" adv-skipped)))
        (progn
          (format t "Run Configuration: Binary=~a, Debug=~a, SinglePass=~a, Differentiate=~a~@[, Filter=~a~]~%"
            *use-binary* *compile-debug* *compile-single-pass* *compile-differentiate* *test-filter*)
          (format t "Spec Summary: ~a/~a Passed.~%" passed total)))
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
