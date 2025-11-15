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
                 (let ((ir-ptr (llvm-print-module-to-string module)))
                   ;; Use unwind-protect to guarantee we free the pointer
                   (unwind-protect
                        ;; manually convert the C string pointer to a Lisp string
                        (let ((lisp-string (cffi:foreign-string-to-lisp ir-ptr)))
                          (format t "--- Generated LLVM IR: ---~%~a~%" lisp-string)
                          (format t "--------------------------~%"))
                     ;; free the original pointer LLVM gave us
                     (llvm-dispose-message ir-ptr)))))))
      
      ;; --- 6. Cleanup (The "finally" block) ---
      ;; This runs no matter what.
      (format t "Cleaning up...~%")
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))


;; EXPORTS TO CRISP LANGUAGE
;; ==========================

(defmacro def-function (name params &body body)
  "Defines a new, thread-level Crisp function."
  ;; Find the :source-location argument (our new plumbing)
  ;; It's a bit hacky, but works for now.
  (let* ((source-location (getf body :source-location))
         ;; Re-build the body *without* the :source-location key/value
         (real-body (loop for (key val) on body by #'cddr
                          unless (eq key :source-location)
                          append (list key val))))
    (format T "which package?: ~a ~%" *package*)             
    (format T "name: ~a  params: ~a  body: ~a ~%source-location: ~a  real-body: ~a~%"
               name params body source-location real-body)
    ;; Handle declarations (this part is tricky, let's simplify)
    (let* ((declare-forms
              (loop for form in real-body
                    while (and (listp form) (eq (car form) 'declare))
                    collect form))
            (declarations (loop for form in declare-forms append (rest form)))
            (body-forms (nthcdr (length declare-forms) real-body)))

      `(internal-def-function
        ',name
        ',params
        ',declarations            ;  '(((type a b int)) ((return-type int)))
        ',body-forms              ;  '((+ a b))
        ,source-location))))


;; INTERNAL TO COMPILER
;; ====================

(defun compile-toplevel-form (form location)
  "Analyzes and compiles a single top-level form."
  (format *error-output* "c-t-f form: ~a~% location: ~a~%" form location)
  ;; For now, we only handle def-function
  (when (and (consp form) (eq (car form) 'def-function))
    ;; We need to inject the :source-location into the macro call.
    (let ((form-with-location (append form (list :source-location `',location))))
      ;; IMPORTANT: We must expand the macro *while we are in the
      ;; :crisp-language package* to ensure symbols like '=>' are
      ;; resolved correctly. `eval` would switch the package back
      ;; to :crisp.compiler, breaking our symbol checks.
      (let ((expanded-form (macroexpand-1 form-with-location)))
        ;; Now we can safely eval the result of the expansion.
        (generate-llvm-ir (eval expanded-form))))))

;; --- Error Conditions ---

(define-condition crisp-compiler-error (error)
  ((source-location :initarg :source-location :reader error-source-location
                    :initform nil))
  (:report (lambda (condition stream)
             (format stream "A Crisp compilation error occurred~@[ at ~a~]."
                     (error-source-location condition)))))

(define-condition crisp-type-error (crisp-compiler-error)
  ((message :initarg :message :initform "Type mismatch!" :reader type-error-message)
   (expected :initarg :expected :reader type-error-expected)
   (inferred :initarg :inferred :reader type-error-inferred))
  (:report (lambda (condition stream)
             (format stream "Type mismatch! Expected ~a but inferred ~a."
                     (type-error-expected condition)
                     (type-error-inferred condition)))))

(define-condition crisp-signature-arity-error (crisp-compiler-error)
  ((expected :initarg :expected :reader arity-error-expected)
   (inferred :initarg :inferred :reader arity-error-inferred))
  (:report (lambda (condition stream)
             (format stream "Arity mismatch! Function param list has ~a arguments but type signature declared ~a."
                     (arity-error-inferred condition)
                     (arity-error-expected condition)))))

(define-condition crisp-unsupported-form-error (crisp-compiler-error)
  ((form :initarg :form :reader unsupported-form))
  (:report (lambda (condition stream)
             (format stream "Unsupported form '~a' found in function body."
                     (unsupported-form condition)))))


(define-condition crisp-unknown-variable (crisp-compiler-error)
  ((name :initarg :name :reader unknown-variable-name))
  (:report (lambda (condition stream)
             (format stream "Unknown variable ~a."
                     (unknown-variable-name condition)))))

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name         ; 'my-func
  param-list   ; A list of types
  return-type  ; The *validated* type, e.g., 'i32
  body         ; A list of *other* semantic nodes
  source-location
  )

;; blueprint for a 'return' statement
(defstruct semantic-return
  return-type  ; 'i32
  value-node   ; The node for the value being returned
  source-location
  )

;; blueprint for a literal
(defstruct semantic-literal
  value-type   ; 'i32
  value        ; 7
  source-location
  )

;; Represents a function parameter (e.g., 'a' and its type 'i32)
(defstruct semantic-param
  name
  type
  source-location)

;; Represents reading a variable (e.g., 'a' or 'b')
(defstruct semantic-var-read
  name
  type
  source-location)

;; Represents a function call (e.g., '(+ a b)')
(defstruct semantic-add
  type     ; The *result* type (e.g., 'i32)
  left-arg   ; The 'semantic-var-read' node for 'a'
  right-arg  ; The 'semantic-var-read' node for 'b'
  source-location)


;; ---------------------------------
;; The Brain (Semantic Analyzer)
;; ---------------------------------

;; Internal handlers
;; -----------------
;; *  (def-function wow () (declare (return-type int)) 7) 
;; *  (def-function adds (a  b ) (declare (type a b int) (return-type int)) (+ a b)) 
;; *  (def-function with-arrow (a b) (declare #'(int int => int)) (+ a b))
;; (generate-llvm-ir ...)

(defun internal-def-function (name params declarations body location)
  "This is the 'Semantic Analyzer' (Pass 2)."
  (format t "Compiler: Analyzing function ~a...~%" name)
  
  ;; 1. Check for #'(...) syntax
  (let ((fn-decl (find 'function declarations :key #'car)))
    (if fn-decl
        ;; --- Path A: Found #'(...) syntax ---
        (let* ((fn-spec (second fn-decl)) 
               (return-type (analyze-return-type-from-spec fn-spec))
               (env (analyze-environment-from-spec params fn-spec)))
          
          ;; Run the rest of the compiler using THESE variables
          (analyze-and-build-function name params body env return-type declarations location))
        
        ;; --- Path B: Use (type ...) and (return-type ...) ---
        (let* ((return-type (analyze-return-type-from-list declarations))
               (env (analyze-environment-from-list params declarations)))
          
          ;; Run the rest of the compiler using THESE variables
          (analyze-and-build-function name params body env return-type declarations location)))))

(defun analyze-and-build-function (name params body env return-type declarations location)
  "This is the shared 'guts' of the analyzer."

  (format T "anaylze-and-build-function name: ~a  params: ~a~% body: ~a~%  declarations: ~a~% location: ~a ~%" name params body declarations location)
  
  ;; Handle the case where a function promises a return value but has no body.
  (when (and (not (eq return-type 'nil)) (null body))
    (error 'crisp-type-error :expected return-type :inferred 'nil :source-location location))

  
  ;; 3. Analyze the Body
  (let* ((body-nodes (analyze-body-expressions body env location))
         (return-node (first (last body-nodes))) 
         (inferred-type (if return-node (semantic-node-type return-node) 'nil)))

    (format T " body-nodes: ~a~%  return-node: ~a~%  inferred-type: ~a  return-type: ~a" body-nodes return-node inferred-type return-type)

    ;; 4. Check Types
    (unless (equal inferred-type return-type)
      (error 'crisp-type-error 
             :expected return-type
             :inferred inferred-type
             ;; Get the location from the struct we just built
             :source-location (if return-node
                                  (semantic-node-source-location return-node)  ;; was semantic-return-source-location
                                  location)))

    ;; 5. Build and return the "blueprint"
    (make-semantic-function
     :name name
     :param-list (loop for (param-name param-type) in env
                       collect (make-semantic-param :name param-name
                                                    :type param-type
                                                    :source-location location))
     :return-type return-type
     :body (list (make-semantic-return
                  :return-type return-type
                  :value-node return-node
                  :source-location (if return-node ; Get location from return node
                                       (semantic-node-source-location return-node)
                                       location))) ; Fallback
     :source-location location)))


;; ### Helpers

;; --- #'(...) Syntax Parsers ---

(defun analyze-return-type-from-spec (fn-spec)
  "Parses '(int int => int)' and returns 'i32'."
  (let ((arrow (member '=> fn-spec :test #'string=)))
    (cond
      ((and arrow (rest arrow)) ; e.g. '(=> int)
       (let ((return-types (rest arrow)))
         (when (> (length return-types) 1)
           (error "Multiple return values are not yet supported."))
         (let ((type (first return-types)))
           (cond
             ((eq type 'int) 'i32)
             ((null type) 'nil) ; Handles (=> nil) for void
             (t type)))))
      ((and arrow (not (rest arrow))) ; e.g. '(int =>)
       'nil)
      (t ; No arrow
       'nil))))

(defun analyze-environment-from-spec (params fn-spec)
  "Builds the environment '((a i32) (b i32))'
   from '(a b)' and '(int int => int)'."
  (let ((param-types (loop for type in fn-spec 
                           until (string= type '=>) 
                           collect (if (eq type 'int) 'i32 type))))
    (format T "params: ~a  param-types: ~a~%" params param-types)
    (unless (= (length params) (length param-types)) 
      (error 'crisp-signature-arity-error
             :expected (length param-types) 
             :inferred (length params) 
             :source-location nil)) ; Can't get location easily here yet
    (mapcar #'list params param-types)))


;; --- (type ...) Syntax Parsers (The Fallback) ---

(defun analyze-return-type-from-list (declarations)
  "Finds and returns the return-type from a (return-type ...) decl."
  (let ((found (assoc 'return-type declarations)))
    (if found
        (let ((type (second found)))
          (cond ((eq type 'int) 'i32)
                ((null type) 'nil)
                (t type)))
        'nil)))

(defun analyze-environment-from-list (params declarations)
  "Builds the environment from a (type ...) decl."
  (let ((type-decl (assoc 'type declarations)))
    ;; This function should ONLY handle (type ...) declarations.
    ;; If a #'(...) is present, another path handles it. If neither are,
    ;; and params exist, it's an error.
    (when (and params (not type-decl) (not (assoc 'function declarations)))
      (error "Missing type declarations for parameters: ~a" params))

    (when (and params type-decl)
      (unless (= (length params) (length (butlast (rest type-decl))))
        (error 'crisp-signature-arity-error
               :expected (length (butlast (rest type-decl)))
               :inferred (length params)))
      (let* ((param-names (butlast (rest type-decl) 1))
            (param-type (first (last type-decl)))
            (real-type (if (eq param-type 'int) 'i32 param-type)))
        (mapcar #'(lambda (name) (list name real-type))
                param-names)))))


(defun analyze-parameters (params)
  "Builds the environment (a symbol table)."
  ;; For now, just a simple list.
  ;; '((a i32) (b i32))
  (mapcar #'(lambda (p) (list (first p) (second p))) params))

(defun analyze-body-expressions (body-list env location)
  "Recursively analyzes a list of expressions."
  (loop for expr in body-list
        for i from 0
        collect (analyze-expression expr env (append location (list i)))))

(defun analyze-expression (expr env location)
  "Recursively analyzes a *single* expression."
  (format t "analyze-expression expr: ~a location: ~a~%" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
    (error 'crisp-unsupported-form-error :form expr :source-location location))

  (cond
    ;; Case 1: It's a literal, like 7
    ((integerp expr)
     (make-semantic-literal :value-type 'i32 :value expr :source-location location))

    ;; Case 1.5: It's a keyword symbol, like :foo
    ((keywordp expr)
     (error 'crisp-unsupported-form-error :form expr :source-location location))


    ;; Case 2: It's a variable, like 'a'
    ((symbolp expr)
     (let ((found (assoc expr env)))
       (if found
           (make-semantic-var-read :name expr :type (second found) :source-location location)
           (error 'crisp-unknown-variable 
                  :name expr
                  :source-location location))))

    ;; Case 3: It's a function call, like '(+ a b)'
    ((listp expr)
     (let ((op (first expr)))
       (cond
         ((eq op '+)
          ;; Pass the appended location to the children.
          (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
                 (right-node (analyze-expression (third expr) env (append location '(2))))
                 (left-type (semantic-node-type left-node))
                 (right-type (semantic-node-type right-node)))
            
            ;; (This is a stub, a real one would be smarter)
            (unless (and (eq left-type 'i32) (eq right-type 'i32))
              (error "Can only add i32 types for now!")) ; TODO: Update to condition
            
            (make-semantic-add :type 'i32
                               :left-arg left-node
                               :right-arg right-node
                               :source-location location)))
         
         (t (error 'crisp-unsupported-form-error
                   :form op
                   :source-location (append location '(0)))))))
    
    (t (error 'crisp-unsupported-form-error
              :form expr
              :source-location location))))


;; --- Helper to get the type from any node ---
(defun semantic-node-type (node)
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))))


(defun semantic-node-source-location (node)
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-add (semantic-add-source-location node))))