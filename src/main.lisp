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
            (let ((client (make-instance 'eclector-cst:cst-client))
                  ;; Bind *package* so Eclector reads symbols
                  ;; into the sandboxed :crisp-language package.
                  (*package* (find-package :crisp-language)))
                (format *error-output* "got client ~a~%" client)
              ;; bind the client to Eclector's special variable.
              (let ((eclector.base:*client* client))
                (loop
                  ;; call read with the arguments it expects:
                  ;;    (stream &optional eof-error-p eof-value)
                  (let ((form-cst (eclector-cst:read stream nil :eof)))

                    (format *error-output* "form-cst: ~a~%" form-cst)
                  
                    (when (eq form-cst :eof)
                      (return))
                      
                    (let ((raw-form (cst:raw form-cst))
                          (location form-cst))
                      
                      (crisp.compiler:compile-toplevel-form raw-form location)) )))))
          
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