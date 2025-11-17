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

;; Global Compiler State
;; ---------------------

(defvar *function-table* (make-hash-table)
  "A hash table mapping function names (symbols) to a list of
  FUNCTION-SIGNATURE structs. This supports overloading.")

(defvar *single-pass-call-stack* nil
  "A list of function names currently in the compilation stack, used to
  detect recursion in single-pass mode.")

(defvar *call-graph* nil
  "A hash table representing the call graph of functions.
  Keys are caller function names, values are lists of callee names.")

(defvar *current-compiling-function* nil)

(defstruct function-signature
  "Represents the full signature of a Crisp function."
  (name nil :type symbol)
  (parameters nil :type list)
  (return-types nil :type list)
  (source-location nil :type list)
  (is-template-p nil :type boolean)
  (template-params nil :type list))


;; EXPORTS TO CRISP LANGUAGE
;; ==========================

(defmacro def-function (name params &rest body-and-location)
  "Defines a new, thread-level Crisp function."
  ;; Find the position of our injected :source-location keyword.
  (let* ((loc-pos (position :source-location body-and-location))
         ;; The source location is the value right after the keyword.
         (source-location (when loc-pos (nth (1+ loc-pos) body-and-location)))
         ;; The "real" body is everything before the keyword.
         (body (if loc-pos (subseq body-and-location 0 loc-pos) body-and-location)))
    (format T "which package?: ~a ~%" *package*)             
    (format T "name: ~a  params: ~a  body: ~a ~%source-location: ~a~%"
               name params body source-location)
    ;; Handle declarations (this part is tricky, let's simplify)
    (let* ((declare-forms
              (loop for form in body
                    while (and (listp form) (eq (car form) 'declare))
                    collect form))
            (declarations (loop for form in declare-forms append (rest form)))
            (body-forms (nthcdr (length declare-forms) body)))

      `(internal-def-function
        ',name
        ',params
        ',declarations            ;  '(((type a b int)) ((return-type int)))
        ',body-forms              ;  '((+ a b))
        ,source-location))))


;; INTERNAL TO COMPILER
;; ====================

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

(define-condition crisp-call-type-error (crisp-compiler-error)
  ((message :initarg :message :reader type-error-message)
   (expected :initarg :expected :reader type-error-expected)
   (inferred :initarg :inferred :reader type-error-inferred))
  (:report (lambda (condition stream)
             (format stream "Expected ~a but got ~a."
                     (type-error-expected condition)
                     (type-error-inferred condition))))) 

(define-condition crisp-unexpected-eof-error (crisp-compiler-error)
  ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "Unexpected end of file. This usually means a parenthesis or quote is missing."))))

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

(define-condition crisp-recursion-error (crisp-compiler-error)
  ((form :initarg :form :reader recursive-form))
  (:report (lambda (condition stream)
             (format stream "Recursion is not allowed. Call to '~a' is recursive." (recursive-form condition)))))


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

(defstruct semantic-call
  "Represents a call to a user-defined function."
  name            ; The symbol name of the function being called
  type            ; The return type of the function
  args            ; A list of semantic nodes for the arguments
  source-location
  )


;; ---------------------------------
;; The Brain (Semantic Analyzer)
;; ---------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Multi-Pass Orchestration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun compile-module (forms module builder)
  "Orchestrates the multi-pass compilation of a list of top-level forms."
  ;; Pass 1: Gather all function signatures first.
  (let ((*call-graph* (make-hash-table)))
    (analyze-signatures-pass forms)
    ;; Pass 2: Now that all signatures are known, compile the function bodies.
    (compile-forms-pass forms module builder)
    ;; After analysis, check the constructed graph for cycles.
    (check-for-recursion-cycles)))


(defun analyze-signatures-pass (forms)
  "Pass 1: Iterates through forms to find and register function signatures."
  (loop for form in forms
        for i from 0
        do (let ((location (list i))) ; Simplified location for now
             (cond
               ((and (consp form) (eq (car form) 'def-function))
                (register-function-signature form location))
               ;; TODO: Add handlers for with-template-type, def-struct, etc.
               ))))

(defun compile-forms-pass (forms module builder)
  "Pass 2: Iterates through forms to perform full analysis and codegen."
  (loop for form in forms
        for i from 0
        do (let ((location (list i))) ; Simplified location for now
             (cond
               ((and (consp form) (eq (car form) 'def-function))
                (compile-toplevel-form form location module builder))
               ;; TODO: Add handlers for with-template-type, etc.
               ))))

(defun compile-toplevel-form (form location module builder)
  "Analyzes and compiles a single top-level form (used in Pass 2)."
  (format *error-output* "c-t-f form: ~a~% location: ~a~%" form location)
  ;; For now, we only handle def-function
  (when (and (consp form) (eq (car form) 'def-function))
    ;; In single-pass mode, the signature won't be registered yet.
    ;; We check and register it here to ensure forward calls work.
    ;; In multi-pass mode, this check prevents re-registration.
    (unless (gethash (second form) *function-table*)
      (register-function-signature form location))

    (let ((*current-compiling-function* (second form)))
      (push *current-compiling-function* *single-pass-call-stack*)
      (unwind-protect
           (let ((form-with-location (append form (list :source-location `',location))))
             (let ((expanded-form (macroexpand-1 form-with-location)))
               (generate-llvm-ir (eval expanded-form) module builder)))
        (pop *single-pass-call-stack*)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Recursion Cycle Detection
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Internal handlers
;; -----------------
;; *  (def-function wow () (declare (return-type int)) 7) 
;; *  (def-function adds (a  b ) (declare (type a b int) (return-type int)) (+ a b)) 
;; *  (def-function with-arrow (a b) (declare #'(int int => int)) (+ a b))
;; (generate-llvm-ir ...)

(defun check-for-recursion-cycles ()
  "Iterates through the call graph to find any recursive cycles."
  (format T "check-for-recursion-cycles.  call-graph: ~a~%" *call-graph*)
  (let ((visited (make-hash-table)))
    (loop for caller being the hash-keys of *call-graph*
          do (unless (gethash caller visited)
               (detect-cycle-from-node caller visited (make-hash-table))))))

(defun detect-cycle-from-node (node visited visiting)
  "Performs a DFS from the given node to detect a cycle."
  (setf (gethash node visiting) t)

  (let ((callees (gethash node *call-graph*)))
    (dolist (callee callees)
      (cond
        ;; If the callee is in the current 'visiting' path, we found a cycle.
        ((gethash callee visiting)
         (let ((sig (first (gethash callee *function-table*))))
           (error 'crisp-recursion-error
                  :form callee
                  :source-location (when sig (function-signature-source-location sig)))))

        ;; If the callee has not been visited at all yet, recurse.
        ((not (gethash callee visited))
         (detect-cycle-from-node callee visited visiting)))))

  ;; We're done with this node's path. Remove it from 'visiting'
  ;; and add it to 'visited' so we don't check it again.
  (remhash node visiting)
  (setf (gethash node visited) t))


(defun register-function-signature (form location)
  "Extracts and registers a function's signature without analyzing its body."
  (let* ((name (second form))
         (params (third form))
         (body (cdddr form))
         (declare-forms (loop for f in body while (and (listp f) (eq (car f) 'declare)) collect f))
         (declarations (loop for f in declare-forms append (rest f)))
         (fn-decl (find 'function declarations :key #'car))
         (param-types (if fn-decl
                          (loop for type in (second fn-decl) until (string= type '=>) collect (if (eq type 'int) 'i32 type))
                          (mapcar #'(lambda (p) 'i32) params))) ; Simplified fallback
         (return-type (if fn-decl
                          (analyze-return-type-from-spec (second fn-decl))
                          (analyze-return-type-from-list declarations))))
    (setf (gethash name *function-table*)
          (list (make-function-signature :name name :parameters param-types :return-types (list return-type) :source-location location)))))


(defun internal-def-function (name params declarations body location)
  "This is the 'Semantic Analyzer' (Pass 2)."
  (format t "Compiler: Analyzing function ~a...~%" name)
  (let* ((fn-decl (find 'function declarations :key #'car))
         (return-type (if fn-decl
                          (analyze-return-type-from-spec (second fn-decl))
                          (analyze-return-type-from-list declarations)))
         (env (if fn-decl
                  (analyze-environment-from-spec params (second fn-decl))
                  (analyze-environment-from-list params declarations))))

    ;; Handle the case where a function promises a return value but has no body.
    (when (and (not (eq return-type 'nil)) (null body))
      (error 'crisp-type-error :expected return-type :inferred 'nil :source-location location))

    ;; 2. Analyze the Body
    (let* ((body-nodes (analyze-body-expressions body env location))
           (return-node (first (last body-nodes)))
           (inferred-type (if return-node (semantic-node-type return-node) 'nil)))

      (format T " body-nodes: ~a~%  return-node: ~a~%  inferred-type: ~a  return-type: ~a" body-nodes return-node inferred-type return-type)

      ;; 3. Check Types
      (unless (equal inferred-type return-type)
        (error 'crisp-type-error
               :expected return-type
               :inferred inferred-type
               :source-location (if return-node
                                    (semantic-node-source-location return-node)
                                    location)))

      ;; 4. Build and return the "blueprint"
      (make-semantic-function
       :name name
       :param-list (loop for (param-name param-type) in env
                         collect (make-semantic-param :name param-name :type param-type :source-location location))
       :return-type return-type
       :body (list (make-semantic-return
                    :return-type return-type
                    :value-node return-node
                    :source-location (if return-node (semantic-node-source-location return-node) location)))
       :source-location location))))


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


(defvar *expression-analyzers* (make-hash-table)
  "A dispatch table mapping operator symbols to their analyzer functions.")

(defmacro def-expression-analyzer (operator handler-fn)
  "A helper macro to register an operator's analyzer function."
  `(setf (gethash ',operator *expression-analyzers*) ',handler-fn))

(defun analyze-add-expression (expr env location)
  "Analyzes a `(+ ...)` expression."
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2))))
         (left-type (semantic-node-type left-node))
         (right-type (semantic-node-type right-node)))

    ;; (This is a stub, a real one would be smarter)
    (unless (and (eq left-type 'i32) (eq right-type 'i32))
      (error 'crisp-type-error
             :expected 'i32
             :inferred (if (not (eq left-type 'i32)) left-type right-type)
             :source-location location))

    (make-semantic-add :type 'i32
                       :left-arg left-node
                       :right-arg right-node
                       :source-location location)))

(def-expression-analyzer + analyze-add-expression)

(defun analyze-function-call (op expr env location)
  "Analyzes a call to a user-defined function."
  (format T "analyze-function-call.  call-graph: ~a  current-compiling-function: ~a~%" *call-graph* *current-compiling-function*)
  (if *call-graph*
      ;; --- Multi-pass mode ---
      ;; Record the dependency in the call graph for later cycle detection.
      (when *current-compiling-function*
        (pushnew op (gethash *current-compiling-function* *call-graph*)))
      ;; --- Single-pass mode ---
      (when (member op *single-pass-call-stack*)
        (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; 1. Analyze the arguments passed to the call.
  (let* ((arg-forms (rest expr))
         (arg-nodes (loop for arg-form in arg-forms
                          for i from 1
                          collect (analyze-expression arg-form env (append location (list i)))))
         (arg-types (mapcar #'semantic-node-type arg-nodes))
         ;; 2. Get the function signature(s) from the table.
         (signatures (gethash op *function-table*))
         ;; 3. Find the matching overload (for now, we assume one).
         ;;    TODO: A real implementation would loop through signatures
         ;;    and find the one that matches the arg-types.
         (signature (first signatures)))

    ;; 4. Perform Arity and Type Checking
    (unless (= (length arg-types) (length (function-signature-parameters signature)))
      (error 'crisp-signature-arity-error
             :expected (length (function-signature-parameters signature))
             :inferred (length arg-types)
             :source-location location))

    (unless (equal arg-types (function-signature-parameters signature))
      (error 'crisp-call-type-error
             :message (format nil "Incorrect argument types for call to '~a'." op)
             :expected (function-signature-parameters signature)
             :inferred arg-types
             :source-location location))

    ;; 5. Build the semantic-call node.
    (make-semantic-call :name op
                        :type (first (function-signature-return-types signature))
                        :args arg-nodes
                        :source-location location)))


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
       (format T "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)
       (let ((handler (gethash op *expression-analyzers*)))
         (cond
           ;; Is there a specific handler for this operator (e.g., '+')?
           (handler (funcall handler expr env location))
           ;; Is it a call to a known user-defined function?
           ((gethash op *function-table*)
            (analyze-function-call op expr env location))
           ;; Otherwise, we don't know what this is.
           (t (error 'crisp-unsupported-form-error
                     :form op
                     :source-location (append location '(0))))))))
    
    (t (error 'crisp-unsupported-form-error
              :form expr
              :source-location location))))


;; --- Helper to get the type from any node ---
(defun semantic-node-type (node)
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-call (semantic-call-type node))))


(defun semantic-node-source-location (node)
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-call (semantic-call-source-location node))))