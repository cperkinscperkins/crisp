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

  ;; load libllvm when exe runs, not when built.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)
  
  (let* ((all-args (uiop:command-line-arguments))
         (flags (remove-if-not (lambda (arg) (char= (char arg 0) #\-)) all-args))
         (files (remove-if (lambda (arg) (char= (char arg 0) #\-)) all-args))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=))))
    
    (unless (= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <filename.crisp>~%")
      (uiop:quit 1))
      
    (let* ((filename (first files))
           (filepath (uiop:truename* filename)))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filename)))
             (builder (crisp.llvm-bindings:llvm-create-builder))
             ;; Only create the DIBuilder if the debug flag is present.
             (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
             (di-compile-unit (when debug-p
                                (let ((di-file (crisp.llvm-bindings:llvm-di-builder-create-file di-builder (file-namestring filepath) (directory-namestring filepath))))
                                  (crisp.llvm-bindings:llvm-di-builder-create-compile-unit di-builder 32768 di-file "Crisp Compiler" nil "" 0)))))
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
                                      (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit)
                                      (incf toplevel-index)))) 
                         ;; --- MULTI-PASS MODE (DEFAULT) ---
                         (let* ((*package* (find-package :crisp-language))
                                (forms (loop for form = (read stream nil :eof) until (eq form :eof) collect form)))
                           (crisp.compiler:compile-module forms module builder di-builder di-compile-unit))))
                   
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
