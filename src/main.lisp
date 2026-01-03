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
    (crisp.compiler:error-source-location c)
    c))

(defun initialize-debug-context (di-builder filepath)
  "Creates and returns the top-level DICompileUnit for a file."
  (let* ((f (file-namestring filepath))
         (d (directory-namestring filepath))
         (flags "") ;; will eventually have to support some pass through flags.
         (di-file (crisp.llvm-bindings:llvm-di-builder-create-file di-builder f (length f) d (length d)))
         (producer "Crisp Compiler"))
    (crisp.llvm-bindings:llvm-di-builder-create-compile-unit
     di-builder
     12 ; DW_LANG_C99 (Temporarily using C99 to debug CI failure. Was 32768/0x8000)
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
  "Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets)."
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
                      target-flags)))

    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p)

    (unless (= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <filename.crisp>~%")
      (uiop:quit 1))

    (values files nil debug-p single-pass-p targets)))

(defun compile-files (files output-file debug-p single-pass-p targets)
  "Compiles the given files, iterating over requested targets."
  (declare (ignore output-file)) ; Handled per-target
  (let* ((filename (first files))
         (filepath (uiop:truename* filename))
         ;; Default to :generic (stdout) if no targets specified
         (passes (if targets targets '(:generic))))

    (dolist (target-backend passes)
      (let ((crisp.compiler:*target-backend* target-backend))
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
                           (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map))))

                   ;; Output Generation
                   (case target-backend
                     (:spirv
                      (let ((out-path (make-pathname :type "spv" :defaults filepath)))
                        (crisp.compiler:compile-to-spirv module out-path)))
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
                  (format *error-output* "~&An unexpected error occurred: ~a~%" c)
                  (uiop:quit 1)))
            ;; Cleanup
            (when di-builder (crisp.llvm-bindings:llvm-di-builder-finalize di-builder))
            (when di-builder (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
            (crisp.llvm-bindings:llvm-dispose-builder builder)
            (crisp.llvm-bindings:llvm-dispose-module module)))))

    (format *error-output* "; ...All compilation passes finished.~%")))

(defun main ()
  "Main entry point for the crisp-compile executable."
  (let ((args (uiop:command-line-arguments)))
    (multiple-value-bind (source-files output-file debug-p single-pass-p targets)
        (parse-cli-args args)
      (compile-files source-files output-file debug-p single-pass-p targets))))
