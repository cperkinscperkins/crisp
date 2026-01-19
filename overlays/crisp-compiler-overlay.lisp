;; overlays/crisp-compiler-overlay.lisp

;; Phase 1: Add --hoist flag support to compiler
(in-package :crisp.main)

;; src/main.lisp - Updated parse-cli-args to include hoist parsing
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

         ;; Hoist Parsing (NEW)
         (hoist-flags (remove-if-not (lambda (f) (alexandria:starts-with-subseq "--hoist=" f)) flags))
         (hoist-targets (mapcar (lambda (f)
                                  (let ((val (string-upcase (subseq f (length "--hoist=")))))
                                    ;; Normalize: L0, l0, levelzero all → :L0
                                    (cond
                                     ((or (string= val "L0") (string= val "LEVELZERO")) :L0)
                                     ((or (string= val "OPENCL") (string= val "CL")) :OPENCL)
                                     ((string= val "CUDA") :CUDA)
                                     (t (intern val :keyword)))))
                            hoist-flags))

         ;; Auto-enable metadata if --hoist is specified
         (metadata-p (or (member "--metadata" flags :test #'string=)
                         (and hoist-targets t))))

    ;; Initialize the compiler system
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p)

    (unless (= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <filename.crisp>~%")
      (uiop:quit 1))

    ;; Auto-set --ir-target=spv if --hoist is specified but no IR target given
    (when (and hoist-targets (null targets))
          (format *error-output* "; Auto-enabling --ir-target=spv (required for hoisting)~%")
          (setf targets '(:spirv)))

    (values files nil debug-p single-pass-p targets metadata-p hoist-targets)))


;; src/main.lisp - Helper to get hoister binary path
(defun get-hoister-binary-path (hoist-id)
  "Returns path to crisp-hoist-{id}.exe (or .bin on Unix)"
  (let* ((bin-name (format nil "crisp-hoist-~(~a~)" hoist-id))
         (exe-path (merge-pathnames (format nil "bin/~a.exe" bin-name) (uiop:getcwd)))
         (unix-path (merge-pathnames (format nil "bin/~a" bin-name) (uiop:getcwd))))
    (cond
     ((probe-file exe-path) exe-path)
     ((probe-file unix-path) unix-path)
     (t (format *error-output* "~&ERROR: Hoister binary not found: ~a~%" bin-name)
        nil))))


;; src/main.lisp - Invoke hoister for a single metacrisp file
(defun invoke-hoister (hoist-id metacrisp-file)
  "Invokes crisp-hoist-{id}.exe with the given .metacrisp file"
  (let ((hoister-bin (get-hoister-binary-path hoist-id)))
    (if hoister-bin
        (progn
         (format *error-output* "; Invoking hoister: ~a ~a~%"
           (file-namestring hoister-bin)
           (file-namestring metacrisp-file))
         (let ((exit-code (uiop:run-program
                            (list (uiop:native-namestring hoister-bin)
                                  (uiop:native-namestring metacrisp-file))
                            :output *error-output*
                            :error-output *error-output*
                            :ignore-error-status t)))
           (if (zerop exit-code)
               (format *error-output* "; Hoister completed successfully.~%")
               (progn
                (format *error-output* "~&ERROR: Hoister exited with code ~a~%" exit-code)
                (uiop:quit exit-code)))))
        (progn
         (format *error-output* "~&ERROR: Cannot invoke hoister '~a' - binary not found.~%" hoist-id)
         (format *error-output* "~&       Please build the hoister: sbcl --load build/build-hoist-~(~a~).lisp~%" hoist-id)
         (uiop:quit 1)))))


;; src/main.lisp - Updated compile-files signature
(defun compile-files (files output-file debug-p single-pass-p targets metadata-p hoist-targets)
  "Compiles the given files, iterating over requested targets, then invokes hoisters."
  (declare (ignore output-file)) ; Handled per-target
  (let* ((filename (first files))
         (filepath (uiop:truename* filename))
         ;; Default to :generic (stdout) if no targets specified
         (passes (if targets targets '(:generic))))

    (let ((generated-outputs nil)
          (captured-forms nil)
          (generated-metacrisp-files nil)) ; NEW: Track metacrisp files for hoisting
      (dolist (target-backend passes)
        (let ((crisp.compiler:*target-backend* target-backend)
              (crisp.compiler::*emit-metadata* metadata-p))
          (format *error-output* "~&; --- Starting Pass for Target: ~a ---~%" target-backend)

          (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filename)))
                 (builder (crisp.llvm-bindings:llvm-create-builder))
                 ;; Only create the DIBuilder if the debug flag is present.
                 (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
                 (di-compile-unit (when debug-p (initialize-debug-context di-builder filepath))))
            (unwind-protect
                (handler-case
                    (progn
                     (with-open-file (stream filename)
                       (if single-pass-p
                           ;; --- SINGLE-PASS MODE ---
                           (let ((toplevel-index 0)
                                 (*package* (find-package :crisp-language)))
                             (loop for form = (read stream nil :eof)
                                   until (eq form :eof)
                                   do (let ((location (list toplevel-index))
                                            (crisp.compiler::*single-pass-call-stack* nil))
                                        (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit nil)
                                        (incf toplevel-index))))
                           ;; --- MULTI-PASS MODE (DEFAULT) ---
                           (let* ((*package* (find-package :crisp-language))
                                  (forms (loop for form = (read stream nil :eof) until (eq form :eof) collect form))
                                  (location-map (when debug-p (crisp.compiler:generate-location-map forms))))
                             (setf captured-forms forms)
                             (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map))))

                     ;; Output Generation
                     (case target-backend
                       (:spirv
                        (let ((out-path (make-pathname :type "spv" :defaults filepath)))
                          (crisp.compiler:compile-to-spirv module out-path)
                          (push (list :spv out-path) generated-outputs)))
                       (:ptx
                        (let ((out-path (make-pathname :type "ptx" :defaults filepath)))
                          (crisp.compiler:compile-to-ptx module out-path)
                          (push (list :ptx out-path) generated-outputs)))
                       (:llvmir
                        (let ((out-path (make-pathname :type "ll" :defaults filepath)))
                          (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                            (unwind-protect
                                (with-open-file (stream out-path :direction :output :if-exists :supersede)
                                  (write-string (cffi:foreign-string-to-lisp ir-ptr) stream))
                              (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))
                          (push (list :llvmir out-path) generated-outputs)))
                       ;; Default/Generic: Print IR to stdout
                       (t
                        (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                          (unwind-protect
                              (format t "--- Generated LLVM IR (~a): ---~%~a~%" target-backend (cffi:foreign-string-to-lisp ir-ptr))
                            (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))))

                  ;; Error Handling
                  (crisp.compiler:crisp-compiler-error (c)
                                                       (print-compiler-error c filename)
                                                       (uiop:quit 1))
                  (end-of-file ()
                               (print-compiler-error (make-condition 'crisp.compiler:crisp-unexpected-eof-error) filename)
                               (uiop:quit 1))
                  (error (c)
                    (print-compiler-error c filename)
                    (uiop:quit 1)))

              ;; Cleanup resources
              (when debug-p
                    (crisp.llvm-bindings:llvm-di-builder-finalize di-builder)
                    (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
              (crisp.llvm-bindings:llvm-dispose-builder builder)
              (crisp.llvm-bindings:llvm-dispose-module module)))))

      ;; Metadata Generation (Once, after collecting all outputs)
      (when metadata-p
            (let ((meta-paths
                   (crisp.compiler::generate-metadata-for-file filepath
                                                               (make-pathname :type "metacrisp" :defaults filepath)
                                                               :output-targets (reverse generated-outputs)
                                                               :forms captured-forms)))
              ;; Track generated metacrisp files for hoisting
              (setf generated-metacrisp-files
                (if (listp meta-paths) meta-paths (list meta-paths)))))

      (format *error-output* "; ...All compilation passes finished.~%")

      ;; NEW: Invoke hoisters if specified
      (when hoist-targets
            (format *error-output* "~&; --- Starting Hoisting Phase ---~%")
            (dolist (hoist-id hoist-targets)
              (dolist (metacrisp-file generated-metacrisp-files)
                (when (probe-file metacrisp-file)
                      (invoke-hoister hoist-id metacrisp-file))))
            (format *error-output* "; ...All hoisting finished.~%")))))


;; src/main.lisp - Updated main() to pass hoist-targets
(defun main ()
  "Main entry point for the crisp-compile executable."
  (let ((args (uiop:command-line-arguments)))
    (multiple-value-bind (source-files output-file debug-p single-pass-p targets metadata-p hoist-targets)
        (parse-cli-args args)
      (compile-files source-files output-file debug-p single-pass-p targets metadata-p hoist-targets))))
