;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ============================================================
;; crisp.main redefinitions — multi-file compilation support
;; src/main.lisp
;; ============================================================

(in-package :crisp.main)

(defun parse-cli-args (args)
  "Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets).
Supports one or more .crisp source files: the last file is treated as the primary (determines output name)."
  (let* ((flags (remove-if-not (lambda (arg) (char= (char arg 0) #\-)) args))
         (files (remove-if (lambda (arg) (char= (char arg 0) #\-)) args))
         (log-level-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--log-level=" f)) flags))
         (log-level (if log-level-flag
                        (intern (string-upcase (subseq log-level-flag (length "--log-level="))) :keyword)
                        :off))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=)))
         (runtime-checks-p (member "--runtime-checks" flags :test #'string=))
         (differentiate-p (member "--differentiate" flags :test #'string=))

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

    (when (and differentiate-p hoist-targets)
          (format *error-output* "ERROR: --differentiate and --hoist are incompatible and cannot be used together.~%")
          (uiop:quit 1))

    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p
                                        :differentiate differentiate-p)

    ;; Require at least one source file; support multiple files.
    (unless (>= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <file1.crisp> [file2.crisp ...]~%")
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

(defun compile-files (files output-file debug-p single-pass-p targets metadata-p hoist-targets)
  "Compiles the given files as a single unit (in order), iterating over requested targets, then invokes hoisters.
When multiple files are given, forms are read from each file in order and compiled together as if they
had been one file.  The LAST file is the primary: its name determines output file names and the debug
compile-unit filepath."
  (declare (ignore output-file)) ; Handled per-target
  ;; The last file is the primary: determines output naming and debug context.
  (let* ((filename (car (last files)))
         (filepath (uiop:truename* filename))
         ;; For error messages, show all files (list them if more than one).
         (file-display (if (= (length files) 1)
                           filename
                           (format nil "[~{~a~^, ~}]" (mapcar #'file-namestring files))))
         ;; Default to :generic (stdout) if no targets specified
         (passes (if targets targets '(:generic))))

    (let ((generated-outputs nil)
          (captured-forms nil)
          (generated-metacrisp-files nil))
      (dolist (target-backend passes)
        (let ((crisp.compiler:*target-backend* target-backend)
              (crisp.compiler::*emit-metadata* metadata-p))
          (format *error-output* "~&; --- Starting Pass for Target: ~a ---~%" target-backend)

          (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filename)))
                 (builder (crisp.llvm-bindings:llvm-create-builder))
                 ;; Only create the DIBuilder if the debug flag is present.
                 (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
                 (di-compile-unit (when debug-p (initialize-debug-context module di-builder filepath))))
            (unwind-protect
                (handler-case
                    (progn
                     (if single-pass-p
                         ;; --- SINGLE-PASS MODE (multiple files) ---
                         ;; Process each file's forms in order with a shared toplevel-index so that
                         ;; location indices are unique across the entire compilation unit.
                         (let ((toplevel-index 0)
                               (*package* (find-package :crisp-language)))
                           (dolist (f files)
                             (with-open-file (stream f)
                               (loop for form = (read stream nil :eof)
                                     until (eq form :eof)
                                     do (let ((location (list toplevel-index)))
                                          (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit nil)
                                          (incf toplevel-index))))))
                         ;; --- MULTI-PASS MODE (DEFAULT, multiple files) ---
                         ;; Read all forms from all files in order into one flat list, then compile-module.
                         (let* ((*package* (find-package :crisp-language))
                                (forms (loop for f in files
                                             appending (with-open-file (stream f)
                                                         (loop for form = (read stream nil :eof)
                                                               until (eq form :eof)
                                                               collect form))))
                                (location-map (when debug-p (crisp.compiler:generate-location-map forms))))
                           (setf captured-forms forms)
                           (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map)))

                     ;; Output Generation — keyed off the primary (last) file.
                     (let ((base-name (if crisp.compiler::*differentiate-p*
                                          (format nil "~a_grad" (pathname-name filepath))
                                          (pathname-name filepath))))
                       (case target-backend
                         (:spirv
                          (let ((out-path (make-pathname :name base-name :type "spv" :defaults filepath)))
                            (crisp.compiler:compile-to-spirv module out-path :debug-p debug-p)
                            (push (list :spv out-path) generated-outputs)))
                         (:ptx
                          (let ((out-path (make-pathname :name base-name :type "ptx" :defaults filepath)))
                            (crisp.compiler:compile-to-ptx module out-path :debug-p debug-p)
                            (push (list :ptx out-path) generated-outputs)))
                         (:llvmir
                          (let ((out-path (make-pathname :name base-name :type "ll" :defaults filepath)))
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
                              (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))))))

                  ;; Error Handling — report all files involved.
                  (crisp.compiler:crisp-compiler-error (c)
                                                       (print-compiler-error c file-display)
                                                       (uiop:quit 1))
                  (end-of-file ()
                               (print-compiler-error (make-condition 'crisp.compiler:crisp-unexpected-eof-error) file-display)
                               (uiop:quit 1))
                  (error (c)
                    (print-compiler-error c file-display)
                    (uiop:quit 1)))

              ;; Cleanup resources
              (when debug-p
                    (crisp.llvm-bindings:llvm-di-builder-finalize di-builder)
                    (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
              (crisp.llvm-bindings:llvm-dispose-builder builder)
              (crisp.llvm-bindings:llvm-dispose-module module)))))

      ;; Metadata Generation (Once, after collecting all outputs)
      (when metadata-p
            (let* ((base-name (if crisp.compiler::*differentiate-p*
                                  (format nil "~a_grad" (pathname-name filepath))
                                  (pathname-name filepath)))
                   (meta-path (make-pathname :name base-name :type "metacrisp" :defaults filepath))
                   (meta-paths
                    (crisp.compiler::generate-metadata-for-file filepath
                                                                meta-path
                                                                :output-targets (reverse generated-outputs)
                                                                :forms captured-forms)))
              ;; Track generated metacrisp files for hoisting
              (setf generated-metacrisp-files
                (if (listp meta-paths) meta-paths (list meta-paths)))))

      (format *error-output* "; ...All compilation passes finished.~%")

      ;; Invoke hoisters if specified
      (when hoist-targets
            (format *error-output* "~&; --- Starting Hoisting Phase ---~%")
            (dolist (hoist-id hoist-targets)
              (dolist (metacrisp-file generated-metacrisp-files)
                (when (probe-file metacrisp-file)
                      (invoke-hoister hoist-id metacrisp-file))))
            (format *error-output* "; ...All hoisting finished.~%")))))

;; Return to crisp.compiler package for any subsequent overlay content.
(in-package :crisp.compiler)


