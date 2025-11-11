;; src/codegen.lisp

(in-package :crisp.compiler)

(defun generate-llvm-ir (semantic-func)
  "This is the 'Code Generator' (Pass 3).
   It walks the 'Typed AST' and calls the LLVM API."
  
  (let ((module (llvm-module-create (symbol-name (semantic-function-name semantic-func))))
        (builder (llvm-create-builder)))
    (unwind-protect
         (let* ((i32-type (llvm-int32-type))
                (fn-type (llvm-function-type i32-type (null-pointer) 0 nil))
                (llvm-func (llvm-add-function module (symbol-name (semantic-function-name semantic-func)) fn-type))
                (entry-block (llvm-append-basic-block llvm-func "entry")))
           
           (llvm-position-builder-at-end builder entry-block)
           
           ;; This is the only "smart" part
           ;; We walk the blueprint's body
           (dolist (node (semantic-function-body semantic-func))
             (generate-llvm-instruction builder node))

           ;; ... (print module to string) ...
           (let ((ir-string (llvm-print-module-to-string module)))
            (format t "--- Generated LLVM IR: ---~%~a~%" ir-string)
             ;; We must free the string LLVM gave us
            (llvm-dispose-message ir-string)
            (format t "--------------------------~%"))

           ))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module)))

(defun generate-llvm-instruction (builder node)
  "Generates code for a single semantic node."
  (etypecase node
    ;; Case 1: We're a 'return' node
    (semantic-return
     (let ((value-node (semantic-return-value-node node)))
       (llvm-build-ret builder (generate-llvm-value builder value-node))))
    
    ;; (Future case: (semantic-add ...))
    ))

(defun generate-llvm-value (builder node)
  "Generates code for a 'value' node."
  (etypecase node
    ;; Case 1: We're a literal '7'
    (semantic-literal
     (llvm-const-int (llvm-int32-type) (semantic-literal-value node) nil))
    
    ;; (Future case: (semantic-variable-read ...))
    ))