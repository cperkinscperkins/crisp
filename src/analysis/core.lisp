;;; src/analysis/core.lisp
(in-package :crisp.compiler)

(defvar *analysis-access-mode* :read)

(defun initialize-expression-analyzers ()
  "Registers all expression analyzers."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  ;; Core/Self registration if any?
  )

;; ---------------------------------
;; The Brain (Semantic Analyzer)
;; ---------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Multi-Pass Orchestration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun compile-module (forms module builder di-builder di-compile-unit location-map)
  "Orchestrates the multi-pass compilation of a list of top-level forms."
  (log:debug "*crisp-types*: ~s~%*expression-analyzers*: ~s" (alexandria:hash-table-keys *crisp-types*) (alexandria:hash-table-keys *expression-analyzers*))
  ;; Pass 1: Gather all function signatures and build the call graph.
  (let ((*call-graph* (make-hash-table))
        (*originator-functions* (make-hash-table))
        (*implicit-arg-map* (make-hash-table))) ; Rebind for a clean state per module.
    (let ((*defer-struct-validation* t)
          (*pending-struct-definitions* nil))
      (analyze-signatures-pass forms)

      ;; Now finalize any structs that were deferred
      (finalize-struct-definitions))

    ;; Pass 1.5: Propagate implicit argument requirements up the call graph.
    (propagate-implicit-arguments)

    ;; Pass 2: Now that all signatures are known, compile the function bodies.
    (compile-forms-pass forms module builder di-builder di-compile-unit location-map)
    (check-for-recursion-cycles)))


(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers."
  (log:info "OVERLAY: propagate-implicit-arguments called with ~a originators"
            (hash-table-count *originator-functions*))
  (let ((worklist '()))
    ;; 1. Seed the worklist with all originator functions.
    ;; NOTE: Don't set their *implicit-arg-map* here - analyze-scratch-expression already did
    (loop for fn-name being the hash-keys of *originator-functions*
          do (progn
              (log:info "OVERLAY: Originator ~a has implicit-args: ~a"
                        fn-name (gethash fn-name *implicit-arg-map*))
              (push fn-name worklist)))

    ;; 2. Process the worklist until it's empty.
    (loop while worklist
          do (let* ((callee (pop worklist))
                    (callee-implicit (gethash callee *implicit-arg-map*))
                    ;; Find all functions that call the current callee.
                    (callers (loop for caller being the hash-keys of *call-graph*
                                   using (hash-value callees)
                                     when (member callee callees)
                                   collect caller)))
               (log:debug "OVERLAY: Processing callee ~a with implicit ~a, callers: ~a"
                          callee callee-implicit callers)
               (dolist (caller callers)
                 ;; If this caller isn't already marked as a carrier, copy from callee and add to worklist.
                 (unless (gethash caller *implicit-arg-map*)
                   ;; BEFORE: (setf (gethash caller *implicit-arg-map*) '(:storage))
                   ;; AFTER: Copy from callee
                   (when callee-implicit
                         (log:info "OVERLAY: Marking ~a as carrier (copied from ~a): ~a"
                                   caller callee callee-implicit)
                         (setf (gethash caller *implicit-arg-map*) callee-implicit)
                         (push caller worklist))))))))

;; --- Generic Dependency Scanner ---

(defvar *scanning-function-name* nil
        "The name of the function currently being scanned in Pass 1.")

(defvar *scan-callees* nil)
(defvar *scan-is-originator* nil)

(defgeneric scan-form (form)
  (:documentation "Scans a form to find dependencies and side-channel originators."))

(defmethod scan-form ((form t))
  ;; Base case: Atoms (symbols, numbers, etc) don't have dependencies we care about here
  nil)

(defmethod scan-form ((form cons))
  (let ((op (car form)))
    (if (symbolp op)
        (scan-operator op (cdr form))
        ;; Lambda expression or other cons-car? Walk elements.
        (dolist (f form) (scan-form f)))))

(defgeneric scan-operator (op args)
  (:documentation "Handles specific operators for dependency scanning."))

;; Default Handler (Function Calls & Macros)
(defmethod scan-operator (op args)
  (cond
   ((member op *side-channel-originators*)
     (setf *scan-is-originator* t))
   (t
     (when (and (symbolp op) (not (macro-function op)) (not (special-operator-p op)))
           (pushnew op *scan-callees*))
     (dolist (arg args) (scan-form arg)))))

;; Special Form Handlers
(defmethod scan-operator ((op (eql 'declare)) args) nil)
(defmethod scan-operator ((op (eql 'quote)) args) nil)
(defmethod scan-operator ((op (eql 'function)) args) nil)

(defmethod scan-operator ((op (eql 'let)) args)
  (let ((bindings (first args))
        (body (rest args)))
    (let ((old-binding (compiler-context-current-binding-name *compiler-context*)))
      (dolist (b bindings)
        ;; Bindings can be (var val) or var
        (when (consp b)
              ;; Set the current binding name for deep scanning
              (let ((var-name (first b)))
                (log:warn "Pass 1: Scanning let binding for ~a" var-name)
                (setf (compiler-context-current-binding-name *compiler-context*) var-name)
                (scan-form (second b))
                ;; Restore after scanning the value form
                (setf (compiler-context-current-binding-name *compiler-context*) old-binding))))
      (dolist (f body) (scan-form f)))))

(defmethod scan-operator ((op (eql 'let*)) args)
  (scan-operator 'let args))

(defmethod scan-operator ((op (eql 'if)) args)
  (dolist (arg args) (scan-form arg)))

(defmethod scan-operator ((op (eql 'go)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'return-from)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'semantic-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'explicit-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'semantic-explicit-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'progn)) args)
  (dolist (arg args) (scan-form arg)))

;; This specialized scan-operator method handles make-scratch-cell specifically
(defmethod scan-operator ((op (eql 'make-scratch-cell)) args)
  "Scans make-scratch-cell and extracts the type for *implicit-arg-map*."
  (setf *scan-is-originator* t)

  ;; Extract the type argument: (make-scratch-cell TYPE)
  (when (and args (symbolp (first args)))
        (let* ((inner-type (first args))
               (raw-spec (list 'cell inner-type))
               (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
          ;; Store in *implicit-arg-map* for this function
          ;; Use generated name (current binding) or fallback to __storage
          (let ((implicit-name (or (compiler-context-current-binding-name *compiler-context*) '__storage)))
            (log:warn "Pass 1: Detected make-scratch-cell with type ~a in ~a (Implicit Name: ~a)"
                      canonical-spec (compiler-context-scanning-function-name *compiler-context*) implicit-name)
            (let ((entry (cons implicit-name canonical-spec))
                  (existing (gethash (compiler-context-scanning-function-name *compiler-context*) *implicit-arg-map*)))
              (setf (gethash (compiler-context-scanning-function-name *compiler-context*) *implicit-arg-map*)
                (append existing (list entry)))))))

  ;; Continue scanning arguments
  (dolist (arg args) (scan-form arg)))

(defun shallow-analyze-body (forms)
  "Performs a shallow, recursive walk of a function's body.
  Returns two values:
  1. A boolean indicating if a side-channel originator was found.
  2. A list of all unique symbols found in the 'car' of lists (potential function calls)."
  (let ((*scan-callees* nil)
        (*scan-is-originator* nil))
    (dolist (form forms)
      (scan-form form))
    (values *scan-is-originator* *scan-callees*)))

(defun visit-toplevel-form (form location visitor-fn)
  "Recursively visits a top-level form, handling macros and progn.
   Visitor-fn is called as (visitor-fn form location) for def-function forms.
   Other forms are evaluated if they are not special forms handled by the walker."
  (cond
   ;; Case 1: def-function -> Visit it
   ((and (consp form) (eq (car form) 'def-function))
     (funcall visitor-fn form location))

   ;; Case 2: progn -> Recurse
   ((and (consp form) (eq (car form) 'progn))
     (loop for sub-form in (cdr form)
           for i from 0
           do (visit-toplevel-form sub-form (append location (list i)) visitor-fn)))

   ;; Case 3: Macro -> Expand and Recurse
   ((and (consp form) (symbolp (car form)) (macro-function (car form)))
     (visit-toplevel-form (macroexpand-1 form) location visitor-fn))

   ;; Case 4: Other -> Eval (for side effects like defmacro, register-template)
   (t
     (eval form))))

(defun %compile-standard-function (form location module builder di-builder di-compile-unit location-map)
  "Helper: Compiles a standard (non-generic) function definition."
  (let* ((name (second form))
         (context *compiler-context*))
    (setf (compiler-context-current-compiling-function context) name)
    (push name (compiler-context-single-pass-call-stack context))
    (unwind-protect
        (let* ((form-with-location (append form (list :source-location `',location)))
               (expanded-form (macroexpand-1 form-with-location))
               (semantic-node (eval expanded-form)))
          ;; Handle implicit templates which return nil
          (when semantic-node
                (log:info "Generating IR for function ~a in module ~a" name module)
                (generate-llvm-ir semantic-node module builder di-builder di-compile-unit location-map)))
      (pop (compiler-context-single-pass-call-stack context)))))

(defun compile-def-function (form location module builder di-builder di-compile-unit location-map)
  "Compiles a single def-function form. Handles optional parameters by generating overloaded variants."
  ;; In single-pass mode, the signature won't be registered yet.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location))

  (let* ((name (second form))
         (params (third form))
         (body-and-loc (cdddr form))
         ;; Extract declarations manually to check for optional args
         (declare-forms (loop for f in body-and-loc
                              while (and (listp f) (eq (car f) 'declare))
                              collect f)))

    (multiple-value-bind (explicit-env return-types optional-idx defaults key-idx)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))
      (declare (ignore explicit-env return-types defaults))

      (cond
       ;; --- OPTIONAL/KEY PARAMETERS: Lazy Instantiation (Generic Template) ---
       ;; We skip eager compilation here. The specific variants will be compiled
       ;; on-demand by instantiate-generic-function when called.
       ((or optional-idx key-idx)
         (log:info "Skipping eager compilation for GENERIC function template: ~a. Variants will be compiled on demand." name))

       ;; --- STANDARD Compilation (No Optionals) ---
       (t
         (%compile-standard-function form location module builder di-builder di-compile-unit location-map))))))

(defun walk-code-forms (forms visitor-fn)
  "Walks top-level forms, handling macros and progn, and calling visitor-fn on def-function."
  (loop for form in forms
        for i from 0
        do (visit-toplevel-form form (list i) visitor-fn)))

(defun analyze-signatures-pass (forms)
  "Pass 1: Iterates through forms to find and register function signatures."
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                            (body (cdddr form)))
                       ;; 1. Register the explicit signature.
                       (register-function-signature form location)
                       ;; 2. Perform shallow analysis for call graph and originators.
                       ;; FIXED: Set the function name in context so scan-operator can access it
                       (let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                                 (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees)))))))

(defun compile-forms-pass (forms module builder di-builder di-compile-unit location-map)
  "Pass 2: Iterates through forms to perform full analysis and codegen."
  (let ((*compiler-session* (make-compiler-session :module module
                                                   :builder builder
                                                   :di-builder di-builder
                                                   :di-compile-unit di-compile-unit
                                                   :location-map location-map))
        (*compiler-context* (make-compiler-context))) ; <--- Context

    ;; Pre-Pass: Ensure all templates instantiated during Pass 1 (signatures only) 
    ;; are now fully compiled to IR/Structs in this module.
    (maphash (lambda (key status)
               (when (eq status :analyzed)
                     (let ((name (car key))
                           (types (cdr key)))
                       (log:info "Pass 2: Rehydrating/Compiling template instance: ~a ~a" name types)
                       (funcall *template-instantiator-fn* name types
                         (lambda (form location)
                           (compile-toplevel-form form location module builder di-builder di-compile-unit location-map))))))
             *instantiated-templates*)

    (walk-code-forms forms
                     (lambda (form location)
                       (compile-toplevel-form form location module builder di-builder di-compile-unit location-map)))))

(defun compile-toplevel-form (form location module builder di-builder di-compile-unit location-map)
  "Analyzes and compiles a single top-level form (used in Pass 2)."
  (log:debug "Compiling top-level form at ~a: ~s" location form)

  (let ((*compiler-session* (make-compiler-session :module module :builder builder :di-builder di-builder :di-compile-unit di-compile-unit :location-map location-map))
        (*compiler-context* (make-compiler-context)))
    (visit-toplevel-form form location
                         (lambda (form location)
                           (compile-def-function form location module builder di-builder di-compile-unit location-map)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Recursion Cycle Detection
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun check-for-recursion-cycles ()
  "Iterates through the call graph to find any recursive cycles."
  (log:debug "Checking for recursion cycles in call graph: ~s" *call-graph*)
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

(defun find-variable-in-env (name env)
  "Finds a variable definition in the environment."
  (find name env :key #'parameter-def-name))

(defun validate-return-types (name body env context declared-return-types location)
  "Analyzes the function body and validates return types."
  (declare (ignore name))
  ;; Handle the case where a function promises a return value but has no body.
  (when (and (not (equal declared-return-types '(nil))) (null body))
        (error 'crisp-type-error :expected declared-return-types :inferred '(nil) :source-location location))

  (let* ((body-nodes (analyze-body-expressions body env context location))
         (return-node (first (last body-nodes)))
         (inferred-types (if return-node
                             (let ((node-type (semantic-node-type return-node)))
                               ;; If the node-type is a list, we need to distinguish between
                               ;; a multi-value return type like '(int int) and a single
                               ;; parameterized type like '(cell int).
                               (if (and (listp node-type) (not (valid-type-p node-type)))
                                   node-type ; It's a list of multiple return values, use as-is.
                                   (list node-type))) ; It's a single value, wrap it in a list.
                             '(nil))))

    (log:debug "Analyzed body nodes: ~s~% Return node: ~s~% Inferred types: ~s~% Declared return types: ~s" body-nodes return-node inferred-types declared-return-types)

    (log:debug "Type Check. Inferred: ~s (is list: ~s)~% Declared: ~s (is list: ~s)"
               inferred-types (listp inferred-types)
               declared-return-types (listp declared-return-types))

    ;; Check Types. This allows for a function returning multiple values
    ;; to be used in a context that expects fewer values (the extras are dropped).
    (let* ((num-declared (length declared-return-types))
           (num-inferred (length inferred-types))
           ;; Take the first N inferred types, where N is the number of declared types.
           (inferred-subset (if (>= num-inferred num-declared)
                                (subseq inferred-types 0 num-declared)
                                inferred-types)))
      (unless (and (>= num-inferred num-declared)
                   (type-lists-equivalent-p inferred-subset declared-return-types))
        (error 'crisp-type-error
          :expected declared-return-types
          :inferred inferred-types
          :source-location (if return-node
                               (semantic-node-source-location return-node)
                               location))))
    (values body-nodes inferred-types)))

(defun internal-compile-function (name explicit-env return-type params body declarations location context)
  "Core compilation logic for a function, accepting a pre-parsed environment."

  ;; 0-a. Reserved Name Validation (Accessors ~x~ are not overloadable unless system generated)
  (let ((name-str (symbol-name name)))
    (when (and (> (cl:length name-str) 2)
               (cl:char= (cl:char name-str 0) #\~)
               (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~))
          (unless (find 'crisp-system-generated declarations :key (lambda (x) (if (listp x) (car x) x)))
            (error 'crisp-compiler-error
              :source-location location
              :message (format nil "Function name '~a' is reserved (accessors ending in ~~ are not overloadable)." name)))))

  ;; 0-b. Implicit Template Detection
  (when (detect-and-register-implicit-template name explicit-env return-type params body declarations)
        (return-from internal-compile-function nil))

  ;; 1. Single-Pass Carrier Look-ahead
  (scan-for-carriers name body)

  ;; 2. Implicit Argument Handling
  (let ((env (inject-implicit-arguments name explicit-env)))
    ;; Save old declarations to restore after (for nested definitions support)
    (let ((old-declarations (compiler-context-declarations context)))
      (setf (compiler-context-declarations context) declarations)
      (let ((compilation-result
             (unwind-protect
                 ;; 3. Analyze Body and Validate Return Types
               (multiple-value-bind (body-nodes inferred-return-types)
                   (validate-return-types name body env context return-type location)

                 ;; Update the function registry if we inferred a return type and none was declared.
                 (when (and (or (null return-type) (equal return-type '(nil)))
                            (not (equal inferred-return-types '(nil))))
                       (log:info "Updating signature for ~a with inferred return types: ~a" name inferred-return-types)
                       (let* ((param-types (mapcar #'parameter-def-type explicit-env))
                              (sig (find-if (lambda (s) (equal (mapcar #'parameter-def-type (function-signature-parameters s)) param-types))
                                       (gethash name *function-table*))))
                         (when sig
                               (setf (function-signature-return-types sig) inferred-return-types))))

                 ;; Update implicit parameters in recursive registry
                 (let* ((num-explicit (length explicit-env))
                        (num-total (length env)))
                   (when (> num-total num-explicit)
                         (let* ((implicit-count (- num-total num-explicit))
                                (implicit-params (subseq env 0 implicit-count))
                                ;; Find the signature again (or reuse if I refactor, but robust to find it)
                                (param-types (mapcar #'parameter-def-type explicit-env))
                                (sig (find-if (lambda (s) (equal (mapcar #'parameter-def-type (function-signature-parameters s)) param-types))
                                         (gethash name *function-table*))))
                           (when sig
                                 (log:info "Persisting implicit parameters for ~a: ~s" name implicit-params)
                                 (setf (function-signature-implicit-parameters sig) implicit-params)))))

                 ;; 4. Build and return the "blueprint"
                 (let ((return-node (first (last body-nodes))))
                   (make-semantic-function
                    :name name
                    :param-list (loop for param in env
                                      collect (make-semantic-param :name (parameter-def-name param)
                                                                   :type (parameter-def-type param)
                                                                   :source-location location))
                    :return-type (cond
                                  ((or (null return-type) (equal return-type '(nil)))
                                    inferred-return-types)
                                  (t
                                    return-type))
                    :body (cond
                           ((null return-node)
                             (list (make-semantic-return :return-type '(nil) :value-node nil)))
                           ((typep return-node 'semantic-explicit-return)
                             body-nodes)
                           (t
                             (append (butlast body-nodes)
                               (list (make-semantic-return
                                      :return-type (let ((nt (semantic-node-type return-node)))
                                                     (if (and (listp nt) (not (valid-type-p nt)))
                                                         nt
                                                         (list nt)))
                                      ;; TRUNCATION LOGIC FOR IMPLICIT RETURN
                                      :value-node (let* ((nt (semantic-node-type return-node))
                                                         (val-types (if (and (listp nt) (not (valid-type-p nt))) nt (list nt)))
                                                         (target-types (cond ((or (null return-type) (equal return-type '(nil))) inferred-return-types)
                                                                             (t return-type)))
                                                         (target-list (if (and (listp target-types) (not (valid-type-p target-types))) target-types (list target-types))))

                                                    (cond
                                                     ;; Case: 1 value needed, >1 provided. Extract index 0.
                                                     ((and (= (length target-list) 1) (> (length val-types) 1))
                                                       (log:info "Implicit Return Truncation: ~a -> ~a" val-types target-list)
                                                       (make-semantic-extract-value
                                                        :type (first target-list)
                                                        :aggregate-node return-node
                                                        :index 0
                                                        :source-location (if return-node (semantic-node-source-location return-node) location)))

                                                     ;; TODO: Handle N -> M (where M > 1 and N > M) case if needed.
                                                     ;; For now return original node.
                                                     (t return-node)))

                                      :source-location (if return-node (semantic-node-source-location return-node) location))))))
                    :is-entry-point (loop for decl in declarations
                                            thereis (and (listp decl) (eq (first decl) 'entry-point)))
                    :source-location location)))
               ;; Cleanup
               (setf (compiler-context-declarations context) old-declarations))))
        (log:info "INTERNAL-COMPILE-FUNCTION RESULT ~s" (type-of compilation-result))
        compilation-result))))

(defun internal-def-function (name params declarations body location)
  "This is a wrapper around internal-compile-function that parses declarations."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let ((*compiler-context* (or *compiler-context* (make-compiler-context))))
      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))

(defun analyze-body-expressions (body-list env context location)
  "Recursively analyzes a list of expressions."
  (loop for expr in body-list
        for i from 0
          unless (null expr)
        collect (analyze-expression expr env context (append location (list i)))))

(defun analyze-expression (expr env context location)
  "Recursively analyzes a *single* expression."
  (log:debug "analyze-expression expr: ~s location: ~s" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
        (return-from analyze-expression (make-semantic-progn :type '(nil) :body nil :source-location location)))

  (let ((res
         (cond
          ;; Case 1: It's a literal, like 7
          ((integerp expr)
            (make-semantic-literal :value-type 'int :value expr :source-location location))

          ;; Case 1.1: It's a float literal, like 3.14
          ((floatp expr)
            ;; For now, all floating point literals default to the 'float' type.
            (make-semantic-literal :value-type 'float :value expr :source-location location))

          ;; Case 1.5: It's a keyword symbol, like :foo
          ((keywordp expr)
            (make-semantic-literal :value-type (list 'keyword expr) :value expr :source-location location))

          ;; Case 2: It's a variable, like 'a'
          ((symbolp expr)
            (let ((found (find-variable-in-env expr env)))
              (if found
                  (let ((type-val (parameter-def-type found)))
                    (log:warn "ANALYZE-EXPR VAR: ~a -> Type: ~a" expr type-val)
                    (make-semantic-var-read :name expr :type type-val :source-location location))
                  (progn
                   (log:error "Unknown Variable Lookup: ~a (pkg: ~a)" expr (package-name (symbol-package expr)))
                   (log:error "Env Keys: ~a" (mapcar (lambda (p) (let ((s (parameter-def-name p))) (if (symbolp s) (format nil "~a (pkg: ~a)" s (package-name (symbol-package s))) (format nil "NON-SYMBOL-KEY: ~a" s)))) env))
                   (error 'crisp-unknown-variable
                     :name expr
                     :source-location location)))))

          ;; Case 3: It's a function call, like '(+ a b)'
          ((listp expr) (let ((op (first expr)))
                          (log:warn "analyze-expression list op: ~a (pkg: ~a) macro-function: ~a" op (package-name (symbol-package op)) (macro-function op))
                          (when (eq op 'quote)
                                (log:warn "ANALYZE-EXPR (NEW): QUOTE check. Analyzer: ~a" (gethash op *expression-analyzers*)))
                          (log:debug "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)

                          ;; HOISTED CHECK: Try incomplete accessor first
                          (let ((hook-res (analyze-incomplete-type-accessor op expr env context location)))
                            (if hook-res
                                hook-res
                                ;; Otherwise continue with standard checks
                                (cond ;; Case 3a: Is there a specific handler for this operator (e.g., '+', 'to-char')?
                                     ((gethash op *expression-analyzers*)
                                       (funcall (gethash op *expression-analyzers*) expr env context location))
                                     ;; Case 3b: Is it a macro?
                                     ((macro-function op)
                                       (let ((expanded (macroexpand-1 expr)))
                                         (log:warn "ANALYZE-EXPR MACRO: ~s -> ~s" expr expanded)
                                         (analyze-expression expanded env context location)))
                                     ;; Case 3c: Is it a call to a known user-defined function?
                                     ;; Also check implicit *template-registry* for overloading
                                     ;; AND *generic-functions* for lazy instantiation
                                     ((or (gethash op *function-table*)
                                          (gethash op *template-registry*)
                                          (gethash op *generic-functions*))
                                       (analyze-function-call op expr env context location))
                                     ;; Case 3e: Otherwise, we don't know what this is.
                                     (t
                                       (let ((pkg (symbol-package op)))
                                         (log:debug "  UNSUPPORTED FORM: ~s (pkg: ~a)" op (if pkg (package-name pkg) "NIL"))
                                         (log:debug "  Macro Function? ~a" (macro-function op))
                                         (log:debug "  Bound Function? ~a" (fboundp op)))
                                       (log:debug "  Function Table Keys: ~a" (alexandria:hash-table-keys *function-table*))
                                       (error 'crisp-unsupported-form-error
                                         :form op
                                         :source-location (append location '(0)))))))))
          (t (error 'crisp-unsupported-form-error
               :form expr
               :source-location location)))))
    res))

(defun analyze-function-call (op expr env context location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))
  (if *call-graph*
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (member op (compiler-context-single-pass-call-stack context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (null *call-graph*) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        ;; BEFORE: Loop through keywords :storage
                        ;; AFTER: Loop through cons cells (name . type)
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          (make-semantic-call :name (function-signature-name augmented-signature)
                              :type (function-signature-return-types augmented-signature)
                              :args final-arg-nodes
                              :signature augmented-signature
                              :source-location location))))))

;; --- Helper to get the type from any node ---
(defun semantic-node-type (node)
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))))

(defun semantic-node-source-location (node)
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))))

;; --- Helper to get the type from a node expected to be a single value ---
(defun get-single-value-type (node)
  "Returns the type of a semantic node, assuming a single-value context.
  If the node's type is a list (e.g., from a multi-value function call),
  this returns the first type in the list. Otherwise, it returns the type as-is."
  ;; Safety: Ensure we have a semantic node, not a type specifier
  (when (and (listp node) (not (typep node 'structure-object)))
        (log:warn "get-single-value-type called with list (likely a type spec): ~a. Treating as type." node)
        (labels ((unwrap (t-spec)
                         (if (and (listp t-spec) (= (length t-spec) 1) (valid-type-p t-spec)
                                  (symbolp (first t-spec))
                                  (not (get-template-arity (first t-spec))))
                             (unwrap (first t-spec))
                             t-spec)))
          (return-from get-single-value-type (unwrap node))))

  (let ((type (semantic-node-type node)))
    (labels ((unwrap (t-spec)
                     (if (and (listp t-spec) (= (length t-spec) 1) (valid-type-p t-spec)
                              (symbolp (first t-spec))
                              (not (get-template-arity (first t-spec))))
                         (unwrap (first t-spec))
                         t-spec)))
      (if (and (listp type) (not (valid-type-p type))
               (not (eq (first type) 'keyword))) ;; Preserve keyword literal values
          (unwrap (first type))
          (unwrap type)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; DWARF Location Mapping
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun walk-and-map-locations (expr location map counter)
  "Recursively walks an S-expression, populating a map from location paths to line numbers."
  ;; Add the current expression's location to the map
  (setf (gethash location map) (incf counter))

  ;; For lists, recurse on children, but with a special check for `declare`.
  (when (listp expr)
        (loop for sub-expr in expr
              for i from 0
              do (setf counter
                   (if (and (eq (first expr) 'declare) (listp sub-expr))
                       ;; For forms inside a `declare` block (like `(return-type int)`),
                       ;; map them but do not recurse into them.
                       (progn
                        (setf (gethash (append location (list i)) map) (incf counter))
                        counter)
                       ;; For everything else, recurse normally.
                       (walk-and-map-locations sub-expr (append location (list i)) map counter)))))
  counter)

(defun generate-location-map (forms)
  "Creates a map from S-expression location paths to virtual line numbers."
  (let ((location-map (make-hash-table :test 'equal)) ; Use 'equal' for list keys
                                                     (line-counter 0))
    (loop for form in forms
          for i from 0
          do (setf line-counter (walk-and-map-locations form (list i) location-map line-counter)))
    location-map))

(defun compile-crisp-form-to-ir-string (crisp-form &key (debug-p nil))
  "Takes a single Crisp s-expression (like a def-function form),
  compiles it, and returns its LLVM IR as a string.
  This is a developer utility for REPL use and testing."
  (let* ((module (llvm-module-create "repl-module"))
         (builder (llvm-create-builder))
         (di-builder (when debug-p (llvm-create-di-builder module)))
         (location-map (when debug-p (generate-location-map (list crisp-form))))
         (di-compile-unit (when debug-p
                                (let* ((f "repl.crisp") (d "/tmp/")
                                                        (di-file (llvm-di-builder-create-file di-builder f (length f) d (length d))))
                                  (llvm-di-builder-create-compile-unit di-builder 32768 di-file "Crisp" 5 nil "" 0 0 "" 0 1 0 nil nil "" 0 "" 0)))))
    (unwind-protect
        (progn
         (let* ((*compiler-context* (make-compiler-context))
                (*compiler-session* (make-compiler-session :module module :builder builder :di-builder di-builder :di-compile-unit di-compile-unit :location-map location-map))
                (form-with-location (append crisp-form (list :source-location ''(0))))
                (expanded-form (macroexpand-1 form-with-location))
                (_ (format *error-output* "~&DEBUG CONTEXT is: ~s type: ~s~%" *compiler-context* (type-of *compiler-context*)))
                (_ (format *error-output* "~&DEBUG EXPANSION: ~s~%" expanded-form))
                (semantic-fn (let ((val (eval expanded-form)))
                               (format *error-output* "~&DEBUG EVAL RESULT: ~s~%" val)
                               val)))
           (generate-llvm-ir semantic-fn module builder di-builder di-compile-unit location-map))
         (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
      ;; Cleanup.
      (when di-builder (llvm-di-builder-finalize di-builder))
      (when di-builder (llvm-dispose-di-builder di-builder))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))
