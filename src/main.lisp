;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.



;; src/main.lisp
(in-package :crisp.main)


(defun main ()
  "Main entry point for the crisp-compile executable."

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
       32768 ; DW_LANG_user_lo
       di-file
       producer (length producer)
       nil ; isOptimized
       flags (length flags)
       0   ; runtimeVersion
       (cffi:null-pointer) 0 ; splitName
       1   ; DW_Emission_Kind_Full
       0   ; DWOId
       nil ; splitDebugInlining
       nil ; debugInfoForProfiling
       (cffi:null-pointer) 0 ; sysroot
       (cffi:null-pointer) 0 ; sdk
       )))

  (let* ((all-args (uiop:command-line-arguments))
         (flags (remove-if-not (lambda (arg) (char= (char arg 0) #\-)) all-args))
         (files (remove-if (lambda (arg) (char= (char arg 0) #\-)) all-args))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=))))
    
    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level (if debug-p :debug :info))

    (unless (= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <filename.crisp>~%")
      (uiop:quit 1))
      
    (let* ((filename (first files))
           (filepath (uiop:truename* filename)))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filename)))
             (builder (crisp.llvm-bindings:llvm-create-builder))
             ;; Only create the DIBuilder if the debug flag is present.
             (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
             (di-compile-unit (when debug-p (initialize-debug-context di-builder filepath)))) 
        (unwind-protect
             (handler-case
                 (progn
                   (with-open-file (stream filename)
                     (format *error-output* "; Compiling ~a...~%" filename) 
                     (if single-pass-p
                         ;; --- SINGLE-PASS MODE ---
                         (let ((toplevel-index 0)
                               (*package* (find-package :crisp-language)))
                           (loop for form = (read stream nil :eof)
                                 until (eq form :eof)
                                 do (let ((location (list toplevel-index))
                                          ;; Each top-level form gets its own stack for direct recursion check.
                                          (crisp.compiler::*single-pass-call-stack* nil))
                                      (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit nil)
                                      (incf toplevel-index)))) 
                         ;; --- MULTI-PASS MODE (DEFAULT) ---
                         (let* ((*package* (find-package :crisp-language))
                                (forms (loop for form = (read stream nil :eof) until (eq form :eof) collect form))
                                (location-map (when debug-p (crisp.compiler:generate-location-map forms))))
                           (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map))))
                   
                   ;; After the loop, print the entire module.
                   (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                     (unwind-protect
                          (format t "--- Generated LLVM IR: ---~%~a~%" (cffi:foreign-string-to-lisp ir-ptr))
                       (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))

               ;; main compiler error handler
               (crisp.compiler:crisp-compiler-error (c)
                 (print-compiler-error c filename)
                 (uiop:quit 1))

               ;; Handle unexpected EOF from the reader, which usually means
               ;; an unclosed parenthesis. We create our custom condition and
               ;; handle it directly, avoiding the debugger.
               (end-of-file (c)
                 (print-compiler-error (make-condition 'crisp.compiler:crisp-unexpected-eof-error) filename)
                 (uiop:quit 1))

               ;; This is our placeholder error handler for everything else
               ;; (e.g., file-not-found, package errors).
               (error (c)
                 (format *error-output* "~&An unexpected error occurred: ~a~%" c)
                 (uiop:quit 1)))
          ;; Cleanup
          (when di-builder (crisp.llvm-bindings:llvm-di-builder-finalize di-builder))
          (when di-builder (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module)))
      (format *error-output* "; ...Compilation finished.~%"))))
