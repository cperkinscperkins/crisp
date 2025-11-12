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
  
  ;; 1. NEW: Find all (declare ...) forms at the start of the body.
  (let* ((declarations
           (loop for form in body
                 while (and (listp form) (eq (car form) 'declare))
                 collect (rest form))) ; Collect '((type a b int), (return-type int))
         
         (real-body (nthcdr (length declarations) body))) ; The "real" code

    ;; 2. "Invert" the AST (this is the same as before)
    ;;    We're just passing a cleaner 'params' list now.
    `(internal-def-function
      ',name          ;  'my-add
      ',params        ;  '(a b)
      ',declarations  ; '(((type a b int)) ((return-type int)))
      ',real-body)))  ;  '((+ a b))


;; INTERNAL TO COMPILER
;; ====================

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name         ; 'my-func
  param-list   ; A list of types
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

;; Represents a function parameter (e.g., 'a' and its type 'i32)
(defstruct semantic-param
  name
  type)

;; Represents reading a variable (e.g., 'a' or 'b')
(defstruct semantic-var-read
  name
  type)

;; Represents a function call (e.g., '(+ a b)')
(defstruct semantic-add
  type     ; The *result* type (e.g., 'i32)
  left-arg   ; The 'semantic-var-read' node for 'a'
  right-arg  ; The 'semantic-var-read' node for 'b'
  )

;; Internal handlers
;; -----------------
;; *  (def-function wow () (declare (return-type int)) 7) = > #S(semantic-function ...)
;; *  (def-function yowza (a  b ) (declare (type a b int) (return-type int)) (+ a b))  => #S(semantic-function ...)
(defun internal-def-function (name params declarations body)
  "This is the 'Semantic Analyzer' (Pass 2)."
  
  (format t "Compiler: Analyzing function ~a...~%" name)
  
  ;; 1. Analyze Declarations
  (let ((return-type (analyze-return-type declarations))
        
        ;; 2. NEW: Build the environment from params AND declarations
        (env (analyze-environment params declarations)))

    ;; 3. Analyze the Body (this code is now unchanged)
    (let* ((body-nodes (analyze-body-expressions body env))
           (return-node (first (last body-nodes))) 
           (inferred-type (semantic-node-type return-node)))

      ;; 4. Check Types (unchanged)
      (unless (equal inferred-type return-type)
        (error "Type mismatch! Declared ~a but got ~a" 
               return-type inferred-type))

      ;; 5. Build and return the "blueprint" (this is now simpler)
      ;;    The param-list is now built from the 'env'
      (make-semantic-function
       :name name
       :param-list (loop for (param-name param-type) in env
                         collect (make-semantic-param :name param-name
                                                      :type param-type))
       :return-type return-type
       :body (list (make-semantic-return
                    :return-type return-type
                    :value-node return-node))))))


;; --- NEW: The "Brain's" Upgraded Helpers ---

(defun analyze-return-type (declarations)
  "Finds and returns the return-type from a declare list."
  ;; This 'assoc' is robust and finds the 'return-type'
  ;; anywhere in the declarations list.
  (let ((found (assoc 'return-type (first declarations)))) ; (Stub: assumes one declare block)
    (if found
        (let ((type (second found)))
          (if (eq type 'int) 'i32 type))
        nil))) ; (We'll make this smarter later)

(defun analyze-environment (params declarations)
  "Builds the environment (symbol table) from params and declare forms."
  ;; This is the new "brain" for parameters.
  ;; For now, we'll implement a simple version.
  (format t "Building environment...~a ~a ~%" params declarations)
  
  ;; 1. Find the (type ...) declaration
  ;;    (This is a stub; a real one would search all declarations)
  (let ((type-decl (assoc 'type (first declarations))))
    
    (if (not type-decl)
        (error "Missing (declare (type ...)) for parameters."))
    
    ;; type-decl is '(type a b int)'
    (let* ((param-names (butlast (rest type-decl) 1))
           (param-type (first (last type-decl))))
      
      ;; 2. Map 'int' to 'i32'
      (let ((real-type (if (eq param-type 'int) 'i32 param-type)))
        
        ;; 3. Build the environment list
        ;;    e.g., '((a i32) (b i32))
        (mapcar #'(lambda (name) (list name real-type))
                param-names)))))



(defun analyze-parameters (params)
  "Builds the environment (a symbol table)."
  ;; For now, just a simple list.
  ;; '((a i32) (b i32))
  (mapcar #'(lambda (p) (list (first p) (second p))) params))

(defun analyze-body-expressions (body-list env)
  "Recursively analyzes a list of expressions."
  (mapcar #'(lambda (expr) (analyze-expression expr env)) body-list))

(defun analyze-expression (expr env)
  "Recursively analyzes a *single* expression."
  (cond
    ;; Case 1: It's a literal, like 7
    ((integerp expr)
     (make-semantic-literal :value-type 'i32 :value expr))

    ;; Case 2: It's a variable, like 'a'
    ((symbolp expr)
     (let ((found (assoc expr env)))
       (if found
           (make-semantic-var-read :name expr :type (second found))
           (error "Unknown variable: ~a" expr))))

    ;; Case 3: It's a function call, like '(+ a b)'
    ((listp expr)
     (let ((op (first expr)))
       (cond
         ((eq op '+)
          ;; This is the new logic for '+'
          (let* ((left-node (analyze-expression (second expr) env))
                 (right-node (analyze-expression (third expr) env))
                 (left-type (semantic-node-type left-node))
                 (right-type (semantic-node-type right-node)))
            
            ;; (This is a stub, a real one would be smarter)
            (unless (and (eq left-type 'i32) (eq right-type 'i32))
              (error "Can only add i32 types for now!"))
            
            (make-semantic-add :type 'i32 ; The result type
                               :left-arg left-node
                               :right-arg right-node)))
         
         (t (error "Unknown operator: ~a" op)))))
    
    (t (error "Unknown expression: ~a" expr))))


;; --- Helper to get the type from any node ---
(defun semantic-node-type (node)
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))))