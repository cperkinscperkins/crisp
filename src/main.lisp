;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/main.lisp
(in-package :crisp.main)


(defun print-compiler-error (c filename)
  "Prints a formatted compiler error to *error-output*."
  (format *error-output* "~&~%Crisp compilation failed in ~a~@[ at ~a~]:~%  ~a~&"
    filename
    (ignore-errors (crisp.compiler:error-source-location c))
    c))

(defun initialize-debug-context (module di-builder filepath)
  "Creates and returns the top-level DICompileUnit for a file."
  (let* ((f (file-namestring filepath))
         (d (directory-namestring filepath))
         (flags "") ;; will eventually have to support some pass through flags.
         (di-file (crisp.llvm-bindings:llvm-di-builder-create-file di-builder f (length f) d (length d)))
         (producer "Crisp Compiler"))

    ;; Set Module Flags for Debug Info Version (Required by LLVM/llc)
    ;; Key: "Debug Info Version", Value: 3 (DEBUG_METADATA_VERSION)
    ;; Behavior: 1 (Warning). (Note: C API Error=0, Warning=1, Require=2)
    (let ((key "Debug Info Version")
          (val (crisp.llvm-bindings::llvm-value-as-metadata
                (crisp.llvm-bindings:llvm-const-int (crisp.llvm-bindings:llvm-int32-type) 3 nil))))
      (crisp.llvm-bindings::llvm-add-module-flag module 1 key (length key) val))

    ;; Set Module Flags for DWARF Version (Optional but good)
    (let ((key "Dwarf Version")
          (val (crisp.llvm-bindings::llvm-value-as-metadata
                (crisp.llvm-bindings:llvm-const-int (crisp.llvm-bindings:llvm-int32-type) 4 nil))))
      (crisp.llvm-bindings::llvm-add-module-flag module 1 key (length key) val))

    (crisp.llvm-bindings:llvm-di-builder-create-compile-unit
     di-builder
     39 ; DW_LANG_OpenCL (was 12 C99)
     di-file
     producer (length producer)
     nil ; isOptimized
     flags (length flags)
     0 ; runtimeVersion
     (cffi:null-pointer) 0 ; splitName
     1 ; DW_Emission_Kind_Full
     0 ; DWOId
     nil ; splitDebugInlining
     nil ; debugInfoForProfiling
     (cffi:null-pointer) 0 ; sysroot
     (cffi:null-pointer) 0 ; sdk
     )))



(defun parse-cli-args (args)
  "Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets).
Supports one or more .crisp source files: the last file is treated as the primary (determines output name)."
  (let* ((flags (remove-if-not (lambda (arg) (char= (cl:char arg 0) #\-)) args))
         (files (remove-if (lambda (arg) (char= (cl:char arg 0) #\-)) args))
         ;; Endeavor 122 (FFI): foreign-library bitcode files are passed
         ;; alongside the .crisp sources; split them out here.
         (bc-files (remove-if-not (lambda (f) (string-equal (pathname-type f) "bc")) files))
         (source-files (remove-if (lambda (f) (string-equal (pathname-type f) "bc")) files))
         (log-level-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--log-level=" f)) flags))
         (log-level (if log-level-flag
                        (intern (string-upcase (subseq log-level-flag (length "--log-level="))) :keyword)
                        :off))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=)))
         (runtime-checks-p (member "--runtime-checks" flags :test #'string=))
         (differentiate-p (member "--differentiate" flags :test #'string=))

         ;; Endeavor 126: precision axis. --force-math-precision overrides
         ;; --math-precision (and, later, all in-source precision choices).
         (force-prec-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--force-math-precision=" f)) flags))
         (math-prec-flag  (find-if (lambda (f) (alexandria:starts-with-subseq "--math-precision=" f)) flags))
         ;; Parsed SEPARATELY (not pre-resolved) so the compiler knows which is the
         ;; hard lock: force > with-precision > declaim > math > default(:ieee).
         (math-precision-mode
          (let ((v (when math-prec-flag (subseq math-prec-flag (length "--math-precision=")))))
            (cond ((null v) :ieee)
                  ((string-equal v "fast") :fast)
                  ((string-equal v "ieee") :ieee)
                  (t (format *error-output* "ERROR: unknown math precision '~a' (expected ieee|fast).~%" v)
                     (uiop:quit 1)))))
         (force-precision-mode
          (let ((v (when force-prec-flag (subseq force-prec-flag (length "--force-math-precision=")))))
            (cond ((null v) nil)
                  ((string-equal v "fast") :fast)
                  ((string-equal v "ieee") :ieee)
                  (t (format *error-output* "ERROR: unknown forced math precision '~a' (expected ieee|fast).~%" v)
                     (uiop:quit 1)))))
         (denorm-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--denormal-handling=" f)) flags))
         (denormal-handling
          (let ((v (when denorm-flag (subseq denorm-flag (length "--denormal-handling=")))))
            (cond ((null v) :preserve)   ; Endeavor 126: default subnormal handling
                  ((string-equal v "ftz") :ftz)
                  ((string-equal v "preserve") :preserve)
                  (t (format *error-output* "ERROR: unknown denormal handling '~a' (expected ftz|preserve).~%" v)
                     (uiop:quit 1)))))

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

    ;; Endeavor 126: --force-math-precision overrides all in-source precision intent.
    (when force-prec-flag
      (format *error-output* "WARNING: --force-math-precision overrides all in-source precision choices; use for testing/validation only.~%"))

    ;; Endeavor 126: `fast` precision flushes denormals; a competing `preserve` request
    ;; is not honored under `fast` (denorm is not per-region on SPIR-V) — warn, don't silently flush.
    ;; (Flag-level check; a declaim-set fast + preserve is a later refinement.)
    (when (and (eq (or force-precision-mode math-precision-mode) :fast) (eq denormal-handling :preserve))
      (format *error-output* "WARNING: `fast` precision flushes denormals; the `preserve` request is not honored under `fast` -- use `ieee` if you need denormal preservation.~%"))

    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p
                                        :differentiate differentiate-p
                                        :math-precision math-precision-mode
                                        :force-math-precision force-precision-mode
                                        :denormal-handling denormal-handling)

    ;; Require at least one source file; support multiple files.
    (unless (>= (length source-files) 1)
      (format *error-output* "Usage: crisp-compile [flags] [lib1.bc ...] <file1.crisp> [file2.crisp ...]~%")
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

    (when (member :CUDA hoist-targets)
          (if (null targets)
              (progn
               (format *error-output* "; Auto-enabling --ir-target=ptx (required for --hoist=CUDA)~%")
               (setf targets '(:ptx)))
              (unless (member :ptx targets)
                (format *error-output* "ERROR: --hoist=CUDA requires --ir-target=ptx. Found targets: ~a~%" targets)
                (uiop:quit 1))))

    ;; Endeavor 122 (FFI): linking a foreign .bc requires lowering to a real
    ;; device target (ptx or spv). The .bc is target-specific (triple, datalayout,
    ;; calling convention) and llvmir/generic output cannot bind it.
    (when (and bc-files
               (or (null targets)
                   (notevery (lambda (tg) (member tg '(:ptx :spirv))) targets)))
      (format *error-output* "ERROR: linking a foreign .bc requires --ir-target=ptx or --ir-target=spv (not llvmir/generic).~%")
      (uiop:quit 1))

    (values source-files nil debug-p single-pass-p targets metadata-p hoist-targets bc-files)))

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

(defun invoke-hoister (hoist-id metacrisp-file)
  "Invokes crisp-hoist-{id}.exe with the given .metacrisp file"
  (let ((hoister-bin (get-hoister-binary-path hoist-id)))
    (if hoister-bin
        (progn
         (format *error-output* "; Invoking hoister: ~a ~a~%"
           (file-namestring hoister-bin)
           (file-namestring metacrisp-file))
         ;; uiop:run-program with :ignore-error-status t returns exit code as first value
         (let ((exit-code (uiop:wait-process
                            (uiop:launch-program
                              (list (uiop:native-namestring hoister-bin)
                                    (uiop:native-namestring metacrisp-file))
                              :output :interactive
                              :error-output :interactive))))
           (if (zerop exit-code)
               (format *error-output* "; Hoister completed successfully.~%")
               (progn
                (format *error-output* "~&ERROR: Hoister exited with code ~a~%" exit-code)
                (uiop:quit exit-code)))))
        (progn
         (format *error-output* "~&ERROR: Cannot invoke hoister '~a' - binary not found.~%" hoist-id)
         (format *error-output* "~&       Please build the hoister: sbcl --load build/build-hoist-~(~a~).lisp~%" hoist-id)
         (uiop:quit 1)))))




(defun link-foreign-bitcode (module bc-files)
  "Endeavor 122 (FFI): parse each .bc in BC-FILES and link it into MODULE so
   that def-foreign-function calls resolve to real definitions at compile time.
   Quits with a clear error on read/parse/link failure."
  (when bc-files
    (let ((ctx (crisp.llvm-bindings::llvm-get-module-context module)))
      (flet ((msg-string (msg)
               (let ((p (cffi:mem-ref msg :pointer)))
                 (if (cffi:null-pointer-p p)
                     "<no message>"
                     (prog1 (cffi:foreign-string-to-lisp p)
                       (crisp.llvm-bindings::llvm-dispose-message p))))))
        (dolist (bc bc-files)
          (let ((path (namestring (uiop:truename* bc))))
            (format *error-output* "; --- Linking foreign bitcode: ~a ---~%" path)
            (cffi:with-foreign-objects ((mbuf :pointer) (msg :pointer) (srcmod :pointer))
              (unless (zerop (crisp.llvm-bindings::llvm-create-memory-buffer-with-contents-of-file path mbuf msg))
                (format *error-output* "ERROR: FFI cannot read bitcode ~a: ~a~%" path (msg-string msg))
                (uiop:quit 1))
              ;; parse-ir consumes the memory buffer; link-modules2 consumes srcmod.
              (unless (zerop (crisp.llvm-bindings::llvm-parse-ir-in-context ctx (cffi:mem-ref mbuf :pointer) srcmod msg))
                (format *error-output* "ERROR: FFI cannot parse bitcode ~a: ~a~%" path (msg-string msg))
                (uiop:quit 1))
              (unless (zerop (crisp.llvm-bindings::llvm-link-modules2 module (cffi:mem-ref srcmod :pointer)))
                (format *error-output* "ERROR: FFI cannot link bitcode ~a into the kernel module.~%" path)
                (uiop:quit 1)))))))))

(defun compile-files (files output-file debug-p single-pass-p targets metadata-p hoist-targets &optional bc-files)
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

                     ;; Endeavor 122 (FFI): link any foreign .bc libraries into the
                     ;; freshly-built module (per target) before opt/output, so
                     ;; foreign calls resolve and can be optimized/inlined.
                     (link-foreign-bitcode module bc-files)

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

(defun main ()
  "Main entry point for the crisp-compile executable."
  (let ((args (uiop:command-line-arguments)))
    (multiple-value-bind (source-files output-file debug-p single-pass-p targets metadata-p hoist-targets bc-files)
        (parse-cli-args args)
      (compile-files source-files output-file debug-p single-pass-p targets metadata-p hoist-targets bc-files))))




