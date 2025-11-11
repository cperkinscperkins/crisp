;; src/compiler.lisp
(in-package :crisp.compiler)

;; TEST THAT LLVM SHARED LIB IS WORKING
;; ====================================

(defun test-llvm-hello-world ()
  "The 'Target #5' test.
  Manually builds the LLVM IR for the function:
  define i32 @return_7() {
    ret i32 7
  }"

  ;; We need to wrap everything in `unwind-protect`
  ;; to make sure we don't leak C memory if Lisp errors.
  (let ((module (llvm-module-create "my_hello_module"))
        (builder (llvm-create-builder)))
    (unwind-protect
         (progn
           ;; --- 1. Define the Function Type ---
           ;; We need a function that takes (void) and returns i32
           ;; (Note: We pass a null pointer for 'no params')
           (let* ((i32-type (llvm-int32-type))
                  (fn-type (llvm-function-type i32-type 
                                               (null-pointer) 0 nil)))
             
             ;; --- 2. Create the Function ---
             (let ((my-func (llvm-add-function module "return_7" fn-type)))

               ;; --- 3. Create the Code Block ---
               (let ((entry-block (llvm-append-basic-block my-func "entry")))
                 ;; Tell the "builder" to write code at the
                 ;; end of our new block
                 (llvm-position-builder-at-end builder entry-block)

                 ;; --- 4. Generate the Code ---
                 ;; (let ((const-7 (llvm-const-int i32-type 7 nil)))
                 ;;   (llvm-build-ret builder const-7))
                 
                 ;; Simpler version:
                 (llvm-build-ret builder (llvm-const-int i32-type 7 nil))

                 ;; --- 5. Print the result ---
                 (let ((ir-string (llvm-print-module-to-string module)))
                   (format t "--- Generated LLVM IR: ---~%~a~%" ir-string)
                   ;; We must free the string LLVM gave us
                   (llvm-dispose-message ir-string)
                   (format t "--------------------------~%"))))))
      
      ;; --- 6. Cleanup (The "finally" block) ---
      ;; This runs no matter what.
      (format t "Cleaning up...~%")
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))


;; EXPORTS TO CRISP LANGUAGE
;; ==========================

(defmacro def-function (name params &body body)
  "Defines a new, thread-level Crisp function."
  
  ;; 1. Parse the (declare ...) form
  ;; We find the (declare ...) form, which we assume is first.
  (let* ((declarations (if (and (listp (first body))
                                (eq (caar body) 'declare))
                           (cdar body) ; Get the list of declarations
                           nil))
         ;; The "real" body is whatever is left.
         (real-body (if declarations
                        (rest body)
                        body)))

    ;; 2. "Invert" the AST
    ;; We return a *new* Lisp form that's just a simple,
    ;; internal "constructor." 
    `(internal-def-function
      ',name          ; Quote the name (e.g., 'my-func)
      ',params        ; Quote the param list (e.g., '())
      ',declarations  ; Quote the declarations (e.g., '((return-type int)))
      ',real-body)))  ; Quote the body (e.g., '(7))


;; INTERNAL TO COMPILER
;; ====================

(defun internal-def-function (name params declarations body)
  
  (format t "Compiler: Saw function ~a~%" name)
  ;; ... (Later, this will call the LLVM Gen) ...
  )