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
          (let ((toplevel-index 0)
                ;; Bind *package* so cl:read reads symbols
                ;; into the sandboxed :crisp-language package.
                (*package* (find-package :crisp-language)))
            (loop for form = (read stream nil :eof)
                  until (eq form :eof)
                  do (progn
                      ;; The "location" for a top-level form is a list
                      ;; containing its index in the file.
                      ;; e.g., the first form is at `(0)`, the second at `(1)`.
                      (let ((location (list toplevel-index)))
                        (crisp.compiler:compile-toplevel-form form location))
                      (incf toplevel-index)))))
           
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
