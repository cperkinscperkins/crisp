;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; ======================================================================
;; Endeavor 116/117 — CUDA hoist spec runner support + cross-platform robustness
;; ======================================================================
;;
;; - run-spec-with-hoist: discovers .cu files for CUDA backend;
;;   skips hoist tests when SKIP_<BACKEND>_HOIST env var is set
;; - validate-l0-compile-only: fixed to not crash when Docker is missing
;;   (old code called uiop:run-program on "docker" which signals an error
;;   on systems where docker binary doesn't exist, e.g. RunPod pods)
;; - Content validators (no hardware): validate-cuda-generation,
;;   validate-cuda-cell-args, validate-cuda-tensor-args, validate-cuda-shared-mem
;; - Compile+run validators: validate-cuda-host-run, validate-cuda-compile-only
;;   These SKIP gracefully when nvcc is not available (e.g. Windows dev machine)


;; --- run-spec-with-hoist: backend-aware file discovery ---
;; src/run-specs.lisp (whole-function redefine)

(defun run-spec-with-hoist (file backend)
  "Compiles .crisp file with --hoist=backend flag and returns list of generated output files.
   For L0: discovers .cpp files.  For CUDA: discovers .cu files.
   Checks SKIP_<BACKEND>_HOIST env var (e.g. SKIP_L0_HOIST=true) to skip
   gracefully on machines that don't have the target SDK."
  ;; Check for SKIP env var (e.g. SKIP_L0_HOIST, SKIP_CUDA_HOIST)
  (let ((skip-env (uiop:getenv (format nil "SKIP_~a_HOIST" (symbol-name backend)))))
    (when (and skip-env (string-not-equal skip-env "false"))
      (format t "SKIP (~a hoist disabled via SKIP_~a_HOIST)~%" backend (symbol-name backend))
      (return-from run-spec-with-hoist :skipped)))
  (let* ((hoist-arg (format nil "--hoist=~a" backend))
         (bin (get-binary-path))
         (args (list hoist-arg
                     (format nil "--log-level=~a" cl-user::*log-level*)
                     (uiop:native-namestring file)))
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


;; --- nvcc resolution ---

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


;; --- Content validators (no hardware) ---

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
   - shared-memory offset = 0 for the tile ptr
   - non-zero sharedMemBytes in cuLaunchKernel
   - kernelParams[18] (tile 6 + v 6 + out 6)"
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            (unless (search "_ptr = 0;" content)
              (format t "FAIL: ~a missing shared-mem offset=0 for tile ptr~%" (file-namestring cu))
              (setf passed nil))
            (let ((launch-pos (search "cuLaunchKernel" content)))
              (when launch-pos
                (let ((launch-region (subseq content launch-pos
                                             (min (+ launch-pos 300) (length content)))))
                  (unless (search "32," launch-region)
                    (format t "FAIL: ~a cuLaunchKernel should have sharedMemBytes=32 for 4-element ulong tile~%"
                            (file-namestring cu))
                    (setf passed nil)))))
            (unless (search "kernelParams[18]" content)
              (format t "FAIL: ~a expected kernelParams[18] for tile+v+out~%" (file-namestring cu))
              (setf passed nil))))
        (when passed
          (format t "PASS: .cu has correct shared-mem setup (offset=0, 32 bytes, 18 params)~%"))
        passed)))


;; --- Compile+run validators (require nvcc + NVIDIA GPU) ---

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
