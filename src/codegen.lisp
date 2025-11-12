;; src/codegen.lisp
(in-package :crisp.compiler)

;; --- Main Entry Point ---

(defun generate-llvm-ir (semantic-func)
  "This is the 'Code Generator' (Pass 3).
   It walks the 'Typed AST' (blueprint) and calls the LLVM API."
  
  (let ((module (llvm-module-create (symbol-name (semantic-function-name semantic-func))))
        (builder (llvm-create-builder)))
    (unwind-protect
         ;; --- 1. Setup Types & Function Signature ---
         (let* ((i32-type (llvm-int32-type)) ; (Stub)
                
                ;; Get param types from the blueprint
                (param-types (mapcar #'(lambda (p) (get-llvm-type (semantic-param-type p)))
                                     (semantic-function-param-list semantic-func)))
                
                ;; Create an array of C pointers for CFFI
                (param-types-array (cffi:foreign-alloc :pointer :initial-contents param-types))
                
                (fn-type (llvm-function-type i32-type ; (Stub: return type)
                                             param-types-array
                                             (length param-types)
                                             nil))
                (llvm-func (llvm-add-function module (symbol-name (semantic-function-name semantic-func)) fn-type))
                (entry-block (llvm-append-basic-block llvm-func "entry")))

           (llvm-position-builder-at-end builder entry-block)
           
           ;; --- 2. The "Alloca Trick" ---
           ;; Create a new "environment" to map Lisp symbols to LLVM pointers
           (let ((env (make-hash-table)))
             
             ;; 2a. Allocate stack slots for all parameters
           (loop for param in (semantic-function-param-list semantic-func)
                 for i from 0
                 do (let* ((param-name (semantic-param-name param))
                           (llvm-type (get-llvm-type (semantic-param-type param)))
                           ;; 1. Allocate a stack slot (e.g., %a_ptr)
                           (ptr (llvm-build-alloca builder llvm-type (symbol-name param-name))))
                      
                      ;; --- BODY of the let* ---
                      ;; 2. Store the function's argument (%a) into its slot (%a_ptr)
                      (llvm-build-store builder (llvm-get-param llvm-func i) ptr)
                      
                      ;; 3. Save the pointer for later
                      (setf (gethash param-name env) ptr)))
             
             ;; --- 3. Compile the Body ---
             (dolist (node (semantic-function-body semantic-func))
               (generate-llvm-instruction builder node env))

             (cffi:foreign-free param-types-array)))
           
           ;; --- 4. Print the result ---
           (let ((ir-string (llvm-print-module-to-string module)))
             (format t "--- Generated LLVM IR: ---~%~a~%" ir-string)
             (llvm-dispose-message ir-string)
             (format t "--------------------------~%")))
      
      ;; --- 5. Cleanup ---
      (llvm-dispose-builder builder)
      (llvm-dispose-module module)))

;; --- Codegen Helpers ---

(defun get-llvm-type (type-symbol)
  "Maps our 'i32' symbol to the LLVM type."
  (if (eq type-symbol 'i32)
      (llvm-int32-type)
      (error "Unknown type: ~a" type-symbol)))

(defun generate-llvm-instruction (builder node env)
  "Generates code for a single semantic node."
  (etypecase node
    ;; Case: (semantic-return ...)
    (semantic-return
     (let ((value-node (semantic-return-value-node node)))
       ;; 1. Recursively generate the value
       (let ((llvm-value (generate-llvm-value builder value-node env)))
         ;; 2. Build the 'ret' instruction
         (llvm-build-ret builder llvm-value))))))

(defun generate-llvm-value (builder node env)
  "Recursively generates code for a 'value' node."
  (etypecase node
    ;; Case: (semantic-literal 7)
    (semantic-literal
     (llvm-const-int (get-llvm-type (semantic-literal-value-type node))
                     (semantic-literal-value node)
                     nil))
    
    ;; Case: (semantic-var-read 'a)
    (semantic-var-read
     (let* ((name (semantic-var-read-name node))
           (type (semantic-var-read-type node))
           (llvm-type (get-llvm-type type)) ; Get the LLVM type
           (ptr (gethash name env)))         ; Get the stack pointer
    
        ;; Pass the 'llvm-type' as the new second argument
        (llvm-build-load builder llvm-type ptr (symbol-name name))))

    ;; Case: (semantic-add 'a 'b)
    (semantic-add
     (let* (;; 1. Recursively generate the value for the left
            (llvm-lhs (generate-llvm-value builder (semantic-add-left-arg node) env))
            ;; 2. Recursively generate the value for the right
            (llvm-rhs (generate-llvm-value builder (semantic-add-right-arg node) env)))
       ;; 3. Build the 'add' instruction
       (llvm-build-add builder llvm-lhs llvm-rhs "add_tmp")))))