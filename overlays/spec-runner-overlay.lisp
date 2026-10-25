;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-10-24 -- endeavour 192's validators folded into tests/run-specs.lisp.

;; tests/run-specs.lisp (endeavour 193)
(defun parse-hoist-flags (directive-lines)
  "Parse HOIST-FLAGS: <flag> <flag> ... (Endeavour 193).  Returns the flags as a list of strings
   (each must start with --), forwarded verbatim to the hoist compile.  Several lines append."
  (let ((flags '()))
    (dolist (line directive-lines (nreverse flags))
      (let ((trimmed (string-left-trim ";; " line)))
        (when (starts-with trimmed "HOIST-FLAGS:")
          (dolist (f (uiop:split-string (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq trimmed 12))
                                        :separator '(#\Space #\Tab)))
            (when (plusp (length f))
              (unless (alexandria:starts-with-subseq "--" f)
                (error "HOIST-FLAGS: ~s is not a --flag" f))
              (push f flags))))))))

;; tests/run-specs.lisp (endeavour 193) -- replaces validate-has-llvm-trap, which pinned the BUG 136
;; lowering (llvm.trap -> OpUnreachable, deleted by IGC).
(defun validate-has-die-check (file ir-string)
  "Validator for TEST-WITH[--runtime-checks]: verifies that a runtime check was emitted (not
   elided) and lowers through die -- a CAS on the module-scope die record -- and not llvm.trap."
  (declare (ignore file))
  (cond ((search "llvm.trap" ir-string)
         (format t "FAIL: llvm.trap found in IR -- a runtime check must lower through die (BUG 136)~%")
         nil)
        ((search "cmpxchg ptr addrspace(1) @__crisp_die_record" ir-string)
         (format t "PASS (die-record CAS found, no llvm.trap)~%")
         t)
        (t
         (format t "FAIL: no die-record CAS in IR (expected from a runtime check under --runtime-checks)~%")
         nil)))

;; tests/run-specs.lisp (endeavour 193)
(defun validate-ptx-wait-checks-die-record (file ptx-string)
  "Endeavour 193 Phase E: in a kernel that can die, the mbarrier try_wait spin also loads the die
   record, so a consumer whose producer died stops waiting instead of hanging."
  (declare (ignore file))
  (let ((has-wait (search "mbarrier.try_wait" ptx-string))
        (loads (count-if (lambda (line) (and (search "ld." line) (search "__crisp_die_record" line)))
                         (uiop:split-string ptx-string :separator '(#\Newline)))))
    (cond ((not has-wait)
           (format t "FAIL: no mbarrier.try_wait in the PTX~%") nil)
          ((zerop loads)
           (format t "FAIL: the try_wait spin does not load __crisp_die_record (a dead producer would hang it)~%") nil)
          (t (format t "PASS (try_wait present; ~d die-record load~:p)~%" loads) t))))

;; tests/run-specs.lisp (endeavour 193) -- FOLD: the one parse-hoist-flags clause in the args list.
(defun run-spec-with-hoist (file backend &optional bc-files)
  "Compiles .crisp file with --hoist=backend flag and returns list of generated output files.
   For L0: discovers .cpp files.  For CUDA: discovers .cu files.
   Checks SKIP_<BACKEND>_HOIST env var (e.g. SKIP_L0_HOIST=true) to skip
   gracefully on machines that don't have the target SDK.
   Endeavor 122: BC-FILES (foreign .bc) are prepended to the compiler args so
   FFI device functions are linked into the hoisted kernel.
   Endeavour 193: also forwards the HOIST-FLAGS directive's flags."
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
                       ;; Endeavour 193: HOIST-FLAGS -- extra compiler flags for the hoist compile
                       ;; (--runtime-checks, --logging-output), so a metal spec can run the kernel
                       ;; built the way the flag builds it.
                       (parse-hoist-flags (extract-test-directives file))
                       ;; Endeavour 190: the dogfood launcher -- embed the source, compile it at run
                       ;; time through the C API (L0 and CUDA).
                       ;; (never with foreign .bc libraries: a launcher cannot embed those)
                       (when (and (null bc-files)
                                  (%hoist-kernel-source-p file (symbol-name backend)))
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

