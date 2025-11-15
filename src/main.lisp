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
             
             ;; This is the core loop for files.
             (let (;; Bind *package* so cl:read reads symbols
                   ;; into the sandboxed :crisp-language package.
                   ;; This is still a critical piece of the design.
                   (*package* (find-package :crisp-language)))
               (loop
                 ;; Use the standard Common Lisp `read` function.
                 ;; It will signal an `end-of-file` condition
                 ;; when it reaches the end, which is handled below.
                 (let ((form (read stream nil :eof)))

                   (when (eq form :eof)
                     (return))
                     

                   ;; Temporarily pass `nil` as the location. Your compiler
                   ;; will need to handle this (e.g., by passing it
                   ;; down to the semantic forms, which will also have
                   ;; a `nil` location for now).
                   (let ((raw-form form)
                         (location nil))
                     
                     (crisp.compiler:compile-toplevel-form raw-form location)) ))))
           
        ;; main compiler error handler   
        (crisp.compiler:crisp-compiler-error (c)
          (print-compiler-error c filename)
          (uiop:quit 1))

        ;; Standard end-of-file condition from cl:read
        (end-of-file ()
          nil) ; This is a clean exit, just stop the loop.
          
        ;; This is our placeholder error handler for everything else
        ;; (e.g., file-not-found, package errors).
        (error (c)
          (format *error-output* "~&Error: ~a~%" c)
          (uiop:quit 1)))
          
      (format *error-output* "; ...Compilation finished.~%")
      (uiop:quit 0))))
