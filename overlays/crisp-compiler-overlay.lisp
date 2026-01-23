;; overlays/crisp-compiler-overlay.lisp
;; Overlay for crisp.compiler package
;; This file is loaded with warning muffling (see crisp.asd)
;; All code has been promoted to src/ - this file is kept for the .asd hook

(in-package :crisp.compiler)

;; src/main.lisp - CLI Argument Parsing Update (Hoisting Defaults)
(in-package :crisp.main) ;; Need to switch to MAIN package for this override!

(defun parse-cli-args (args)
  "Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets)."
  (let* ((flags (remove-if-not (lambda (arg) (char= (char arg 0) #\-)) args))
         (files (remove-if (lambda (arg) (char= (char arg 0) #\-)) args))
         (log-level-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--log-level=" f)) flags))
         (log-level (if log-level-flag
                        (intern (string-upcase (subseq log-level-flag (length "--log-level="))) :keyword)
                        :info))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=)))
         (runtime-checks-p (member "--runtime-checks" flags :test #'string=))

         ;; Target Parsing
         (target-flags (remove-if-not (lambda (f) (alexandria:starts-with-subseq "--ir-target=" f)) flags))
         (targets (mapcar (lambda (f)
                            (let ((val (string-upcase (subseq f (length "--ir-target=")))))
                              (cond
                               ((string= val "SPV") :spirv)
                               ((string= val "SPIRV") :spirv)
                               ((string= val "PTX") :ptx)
                               (t (intern val :keyword)))))
                      target-flags))
         ;; Hoist Parsing
         (hoist-flags (remove-if-not (lambda (f) (alexandria:starts-with-subseq "--hoist=" f)) flags))
         (hoist-targets (mapcar (lambda (f)
                                  (let ((val (string-upcase (subseq f (length "--hoist=")))))
                                    (cond
                                     ((or (string= val "L0") (string= val "LEVELZERO")) :L0)
                                     ((or (string= val "OPENCL") (string= val "CL")) :OPENCL)
                                     ((string= val "CUDA") :CUDA)
                                     (t (intern val :keyword)))))
                            hoist-flags))
         ;; Auto-enable metadata if --hoist is specified
         (metadata-p (or (member "--metadata" flags :test #'string=)
                         (and hoist-targets t))))

    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p)

    (unless (= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <filename.crisp>~%")
      (uiop:quit 1))

    ;; --- Hoisting Logic ---
    (when (member :L0 hoist-targets)
      (if (null targets)
          ;; Case 1: Helpful Default (L0 -> SPV)
          (progn
           (format *error-output* "; Auto-enabling --ir-target=spv (required for --hoist=L0)~%")
           (setf targets '(:spirv)))
          ;; Case 2: Validation (L0 requires SPV)
          (unless (member :spirv targets)
            (format *error-output* "ERROR: --hoist=L0 requires --ir-target=spv. Found targets: ~a~%" targets)
            (uiop:quit 1))))

    (values files nil debug-p single-pass-p targets metadata-p hoist-targets)))

