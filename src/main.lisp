;; src/main.lisp
(in-package :crisp.main)

(defun main ()
  "Main entry point for the crisp-compile executable."

  ;; load libllvm when exe runs, not when built.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)
  
  ;; Get command-line arguments.
  ;; uiop:command-line-arguments is a portable way to get them.
  (let ((args (uiop:command-line-arguments)))
    
    (unless (= (length args) 1)
      (format *error-output* "Usage: crisp-compile <filename.crisp>~%")
      (uiop:quit 1))
      
    (let ((filename (first args)))
      (handler-case
          ;; with-open-file handles the pathname string just fine.
          (with-open-file (stream filename)
            (format *error-output* "; Compiling ~a...~%" filename)
            
            ;; This is the core loop for a file-based compiler.
            (loop
              ;; Use Eclector to read one form.
              ;; The nil and :eof args make it return :eof at the end
              ;; instead of signaling an end-of-file error.
              (let ((form (eclector.reader:read stream nil :eof)))
              
                (when (eq form :eof)
                  (return))
                  
                ;; --- This is where we will hook in the compiler ---
                ;; For now, just print the form to prove we read it.
                (print form)
                ;; (compile-toplevel-form form) ; <-- This is the next step
                )))
          
        ;; This `end-of-file` handler is just for the loop,
        ;; in case we didn't use the :eof argument correctly.
        (end-of-file ()
          nil)
          
        ;; This is our placeholder error handler for everything else
        ;; (e.g., file-not-found, read errors).
        (error (c)
          (format *error-output* "~&Error: ~a~%" c)
          (uiop:quit 1)))
          
      (format *error-output* "; ...Compilation finished.~%")
      (uiop:quit 0))))