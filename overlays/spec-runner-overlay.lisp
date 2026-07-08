;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;;; ===================================================================
;;; Endeavor 134 — on-metal MMA correctness via the hoist's --mma-test mode.
;;;
;;; A spec declares:
;;;   ;; MMA-DIMS: M N K
;;;   ;; HOIST-HARDWARE-PROFILE: bmg          (so the SPV picks the vendor shape)
;;;   ;; TEST-HOIST[L0]: validate-l0-mma-run
;;;   ;; HOIST-EXPECT: MMA_CORRECT
;;; The dispatch first runs run-spec-with-hoist (→ .spv + .metacrisp + default .cpp);
;;; validate-l0-mma-run then re-hoists the .metacrisp in --mma-test=M,N,K mode (which
;;; regenerates the .cpp as a host-reference C=A·B correctness test) and delegates to the
;;; stock validate-l0-host-run (compile + run + HOIST-EXPECT "MMA_CORRECT").  Skip-gating is
;;; inherited (SKIP_L0_HOIST / missing toolchain → validate-l0-host-run falls back/skips).
;;; ===================================================================

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
