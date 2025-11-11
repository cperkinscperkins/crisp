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

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name         ; 'my-func
  param-types  ; A list of types
  return-type  ; The *validated* type, e.g., 'i32
  body         ; A list of *other* semantic nodes
  )

;; blueprint for a 'return' statement
(defstruct semantic-return
  return-type  ; 'i32
  value-node   ; The node for the value being returned
  )

;; blueprint for a literal
(defstruct semantic-literal
  value-type   ; 'i32
  value        ; 7
  )



(defun internal-def-function (name params declarations body)
  "This is the 'Semantic Analyzer' (Pass 2).
   It walks the Lisp AST and returns a 'Typed AST'."

   (format t "Compiler: Saw function ~a ~a ~a ~a~%" name params declarations body)
  
  ;; Analyze Declarations
  (let ((return-type (analyze-return-type declarations))) ; This returns 'i32
  
    ;; Analyze Body
    (let* ((body-nodes (analyze-body-expressions body))
           (inferred-type (get-type-of (first body-nodes))))
      
      ;; Check Types
      (unless (equal inferred-type return-type)
        (error "Type mismatch!"))

      ;; Build and return the "blueprint"
      (make-semantic-function
       :name name
       :return-type return-type
       :body (list (make-semantic-return
                    :return-type return-type
                    :value-node (first body-nodes)))))))

;; -- Helper stubs  - VERY HARDCODED
(defun analyze-return-type (declarations)
  (if (equal declarations '((return-type int))) 'i32 nil))

(defun analyze-body-expressions (body)
  (if (equal body '(7))
      (list (make-semantic-literal :value-type 'i32 :value 7))
      nil))

(defun get-type-of (something)
    'i32)