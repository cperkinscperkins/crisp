;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; ======================================================================
;; Endeavor 116 — CUDA hoist spec runner support
;; ======================================================================
;;
;; Extends the spec runner to handle TEST-HOIST[CUDA] directives.
;; - run-spec-with-hoist: now discovers .cu files (not just .cpp)
;; - Four content validators that check generated .cu without hardware


;; --- src/run-specs.lisp (whole-function redefine)
;;
;; Changed: file discovery uses the hoist-output extension for the
;; backend (.cpp for L0, .cu for CUDA) instead of hardcoding .cpp.

(defun run-spec-with-hoist (file backend)
  "Compiles .crisp file with --hoist=backend flag and returns list of generated output files.
   For L0: discovers .cpp files.  For CUDA: discovers .cu files."
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
   - shared-memory offset = 0 for the tile ptr
   - non-zero sharedMemBytes in cuLaunchKernel
   - kernelParams[18] (tile 6 + v 6 + out 6)"
  (declare (ignore crisp-file))
  (if (null cu-files)
      (progn (format t "FAIL: No .cu files generated~%") nil)
      (let ((passed t))
        (dolist (cu cu-files)
          (let ((content (uiop:read-file-string cu)))
            ;; Shared offset = 0
            (unless (search "_ptr = 0;" content)
              (format t "FAIL: ~a missing shared-mem offset=0 for tile ptr~%" (file-namestring cu))
              (setf passed nil))
            ;; Non-zero sharedMemBytes in launch (should NOT be "0, 0," which means 0 shared + stream 0)
            ;; Look for the cuLaunchKernel line and check sharedMemBytes isn't 0
            (let ((launch-pos (search "cuLaunchKernel" content)))
              (when launch-pos
                (let ((launch-region (subseq content launch-pos
                                             (min (+ launch-pos 300) (length content)))))
                  ;; The 7th arg (sharedMemBytes) should be > 0 for a local-tile kernel
                  ;; Pattern: "32, 0," means 32 bytes shared, stream 0
                  (unless (search "32," launch-region)
                    (format t "FAIL: ~a cuLaunchKernel should have sharedMemBytes=32 for 4-element ulong tile~%"
                            (file-namestring cu))
                    (setf passed nil)))))
            ;; Arg count: tile(6) + v(6) + out(6) = 18
            (unless (search "kernelParams[18]" content)
              (format t "FAIL: ~a expected kernelParams[18] for tile+v+out~%" (file-namestring cu))
              (setf passed nil))))
        (when passed
          (format t "PASS: .cu has correct shared-mem setup (offset=0, 32 bytes, 18 params)~%"))
        passed)))
