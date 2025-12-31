;;; src/analysis.lisp
(in-package :crisp.compiler)

(defvar *analysis-access-mode* :read)

(defun initialize-expression-analyzers ()
  "Registers all expression analyzers."
  (clrhash *expression-analyzers*)
  (def-expression-analyzer + analyze-add-expression)
  (def-expression-analyzer - analyze-sub-expression)
  (def-expression-analyzer * analyze-mul-expression)
  (def-expression-analyzer / analyze-div-expression)
  (def-expression-analyzer < analyze-lt-expression)
  (def-expression-analyzer > analyze-gt-expression)
  (def-expression-analyzer <= analyze-le-expression)
  (def-expression-analyzer >= analyze-ge-expression)
  (def-expression-analyzer = analyze-eq-expression)
  (def-expression-analyzer != analyze-neq-expression)

  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)

  (def-expression-analyzer set! analyze-set!-expression)

  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression) ;; NEW
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op) ;; NEW
  (def-expression-analyzer is-set? analyze-is-set-expression) ;; Compile-time predicate

  (def-expression-analyzer atomic-add! analyze-atomic-add!-expression)
  (def-expression-analyzer to analyze-value-cast-expression)
  (def-expression-analyzer to analyze-value-cast-expression)
  (def-expression-analyzer as analyze-generic-as-expression) ;; Generic (as type val)
  ;; (def-expression-analyzer as analyze-bitcast-expression) ;; OLD (as-*) handler
  (def-expression-analyzer as-bits analyze-bitcast-expression) ;; alias
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer aref analyze-aref-expression)
  ;; ~ is an alias for aref (handles Cells/Arrays directly, or falls back to ~ function)
  (def-expression-analyzer ~ref~ analyze-aref-expression)
  (def-expression-analyzer ~ analyze-aref-expression)
  (def-expression-analyzer quote analyze-quote)

  ;; Compile-time conditional aliases (same analyzers, rely on DCE)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)

  ;; From duplicate definition:
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)
  (def-expression-analyzer %construct-struct analyze-struct-construction)
  (def-expression-analyzer %extract-struct-member analyze-extract-struct-member-expression)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)

  ;; Register all possible `to-` and `as-` casts.
  (log:info "Registering cast operators. *crisp-types* count: ~a" (hash-table-count *crisp-types*))
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (when (symbolp type-name)
          (let* ((type-str (symbol-name type-name))
                 (pkg (symbol-package type-name))
                 (to-name (intern (concatenate 'string "TO-" type-str) pkg))
                 (as-name (intern (concatenate 'string "AS-" type-str) pkg)))
            (log:debug "Registering cast/bitcast: ~s / ~s" to-name as-name)
            (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
            (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression))))
  ;; Register the special float-to-int conversion functions
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-truncate-expression) ; NEW handler
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression))

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
    (analyze-signatures-pass forms)

    ;; Pass 1.5: Propagate implicit argument requirements up the call graph.
    (propagate-implicit-arguments)

    ;; Pass 2: Now that all signatures are known, compile the function bodies.
    (compile-forms-pass forms module builder di-builder di-compile-unit location-map)
    (check-for-recursion-cycles)))


(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers."
  (let ((worklist '()))
    ;; 1. Seed the map and worklist with all originator functions.
    (loop for fn-name being the hash-keys of *originator-functions*
          do (setf (gethash fn-name *implicit-arg-map*) '(:storage))
            (push fn-name worklist))

    ;; 2. Process the worklist until it's empty.
    (loop while worklist
          do (let* ((callee (pop worklist))
                    ;; Find all functions that call the current callee.
                    (callers (loop for caller being the hash-keys of *call-graph*
                                   using (hash-value callees)
                                     when (member callee callees)
                                   collect caller)))
               (dolist (caller callers)
                 ;; If this caller isn't already marked as a carrier, mark it and add to worklist.
                 (unless (gethash caller *implicit-arg-map*)
                   (setf (gethash caller *implicit-arg-map*) '(:storage))
                   (push caller worklist)))))))

(defun shallow-analyze-body (forms)
  "Performs a shallow, recursive walk of a function's body.
  Returns two values:
  1. A boolean indicating if a side-channel originator was found.
  2. A list of all unique symbols found in the 'car' of lists (potential function calls)."
  (let ((is-originator nil)
        (callees '()))
    (labels ((walk (form)
                   (when (consp form)
                         (let ((op (car form)))
                           (if (cond
                                ;; --- Special Forms (handle their own recursion) ---
                                ((eq op 'declare) t) ; Ignore declare forms completely.
                                ((member op '(let let*))
                                  ;; For let, walk the init-forms and the body.
                                  (let ((bindings (cadr form))
                                        (body (cddr form)))
                                    (dolist (binding bindings)
                                      (walk (cadr binding))) ; Walk the init-form
                                    (dolist (body-form body)
                                      (walk body-form)))
                                  t) ; Mark as handled.
                                ((eq op 'if)
                                  (walk (cadr form)) ; Walk condition.
                                  (walk (caddr form)) ; Walk then.
                                  (when (cadddr form) (walk (cadddr form))) ; Walk else.
                                  t) ; Mark as handled.
                                (t nil)) ; Not a special form.
                               nil ; If a special form was handled, do nothing more.
                               ;; --- Default Processing ---
                               (progn
                                (if (member op *side-channel-originators*)
                                    ;; It's an originator, set the flag and we're done with this form.
                                    (setf is-originator t)
                                    ;; Otherwise, it's a potential function call.
                                    (progn
                                     (when (and (symbolp op) (not (macro-function op)) (not (special-operator-p op))) (pushnew op callees))
                                     (dolist (sub-form (cdr form)) (walk sub-form))))))))))
      (dolist (form forms)
        (walk form))
      (values is-originator callees))))

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

(defun compile-def-function (form location module builder di-builder di-compile-unit location-map)
  "Compiles a single def-function form. Handles optional parameters by generating overloaded variants."
  ;; In single-pass mode, the signature won't be registered yet.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location))

  (let* ((name (second form))
         (params (third form))
         (body-and-loc (cdddr form))
         ;; Extract declarations manually to check for optional args
         (declare-forms (loop for f in body-and-loc while (and (listp f) (eq (car f) 'declare)) collect f))
         ;; Extract real body (remove declarations)
         (real-body (nthcdr (length declare-forms) body-and-loc)))

    (multiple-value-bind (explicit-env return-types optional-idx defaults key-idx)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))

      (if (or optional-idx key-idx)
          ;; --- OPTIONAL/KEY PARAMETERS: Lazy Instantiation (Generic Template) ---
          ;; We skip eager compilation here. The specific variants will be compiled
          ;; on-demand by instantiate-generic-function when called.
          (log:info "Skipping eager compilation for GENERIC function template: ~a. Variants will be compiled on demand." name)

          ;; --- STANDARD Compilation (No Optionals) ---
          (let ((*current-compiling-function* (second form)))
            (push *current-compiling-function* *single-pass-call-stack*)
            (unwind-protect
                (let ((form-with-location (append form (list :source-location `',location))))
                  (let ((expanded-form (macroexpand-1 form-with-location)))
                    ;; Handle implicit templates which return nil
                    (let ((semantic-node (eval expanded-form)))
                      (when semantic-node
                            (log:info "Generating IR for function ~a in module ~a" (second form) module)
                            (generate-llvm-ir semantic-node module builder di-builder di-compile-unit location-map)))))
              (pop *single-pass-call-stack*)))))))

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
                       (multiple-value-bind (is-originator callees)
                           (shallow-analyze-body body)
                         (when is-originator
                               (setf (gethash name *originator-functions*) t))
                         (setf (gethash name *call-graph*) callees))))))

(defun compile-forms-pass (forms module builder di-builder di-compile-unit location-map)
  "Pass 2: Iterates through forms to perform full analysis and codegen."
  (let ((*current-module* module)
        (*current-builder* builder)
        (*current-di-builder* di-builder)
        (*current-di-compile-unit* di-compile-unit)
        (*current-location-map* location-map))

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

  (let ((*current-module* module)
        (*current-builder* builder)
        (*current-di-builder* di-builder)
        (*current-di-compile-unit* di-compile-unit)
        (*current-location-map* location-map))
    (visit-toplevel-form form location
                         (lambda (form location)
                           (compile-def-function form location module builder di-builder di-compile-unit location-map)))))

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

(defun validate-return-types (name body env declared-return-types location)
  "Analyzes the function body and validates return types."
  (declare (ignore name))
  ;; Handle the case where a function promises a return value but has no body.
  (when (and (not (equal declared-return-types '(nil))) (null body))
        (error 'crisp-type-error :expected declared-return-types :inferred '(nil) :source-location location))

  (let* ((body-nodes (analyze-body-expressions body env location))
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


(defun internal-compile-function (name explicit-env return-type params body declarations location)
  "Core compilation logic for a function, accepting a pre-parsed environment."

  ;; Defensive Sanitation: Obsolete with parameter-def struct change.
  ;; (when (and explicit-env (listp (car explicit-env)) (listp (first (car explicit-env)))) ...

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

    ;; 3. Analyze Body and Validate Return Types
    (multiple-value-bind (body-nodes inferred-return-types)
        (validate-return-types name body env return-type location)

      ;; Update the function registry if we inferred a return type and none was declared.
      (when (and (or (null return-type) (equal return-type '(nil)))
                 (not (equal inferred-return-types '(nil))))
            (log:info "Updating signature for ~a with inferred return types: ~a" name inferred-return-types)
            (let* ((param-types (mapcar #'parameter-def-type explicit-env))
                   (sig (find-if (lambda (s) (equal (function-signature-parameters s) param-types))
                            (gethash name *function-table*))))
              (when sig
                    (setf (function-signature-return-types sig) inferred-return-types))))

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
         :body (if (typep return-node 'semantic-explicit-return)
                   body-nodes
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

                            :source-location (if return-node (semantic-node-source-location return-node) location)))))
         :source-location location)))))

(defun internal-def-function (name params declarations body location)
  "This is a wrapper around internal-compile-function that parses declarations."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (internal-compile-function name explicit-env return-type params body declarations location)))

;; ### Helpers

;; --- #'(...) Syntax Parsers ---

(defmacro def-binary-op-analyzer (name node-constructor op-string)
  `(defun ,name (expr env location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
            (right-node (analyze-expression (third expr) env (append location '(2))))
            (left-type (get-single-value-type left-node))
            (right-type (get-single-value-type right-node))
            (promoted-type (get-promoted-type left-type right-type)))

       (if promoted-type
           (let ((result-crisp-type (gethash promoted-type *crisp-types*)))
             ;; Ensure the resulting type is numeric and supports the op.
             (unless (and result-crisp-type (member (crisp-type-category result-crisp-type)
                                                    '(:signed-int :unsigned-int :float)))
               (error 'crisp-type-error
                 :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
                 :source-location location))
             (,node-constructor :type promoted-type :left-arg left-node :right-arg right-node :source-location location))
           (error 'crisp-type-error
             :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
             :source-location location)))))

(def-binary-op-analyzer analyze-add-expression make-semantic-add "+")
(def-binary-op-analyzer analyze-sub-expression make-semantic-sub "-")
(def-binary-op-analyzer analyze-mul-expression make-semantic-mul "*")
(def-binary-op-analyzer analyze-div-expression make-semantic-div "/")

(defun analyze-lt-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-lt :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-gt-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-gt :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-le-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-le :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-ge-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-ge :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-eq-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-eq :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-neq-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-neq :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-construct-struct-expression (expr env location)
  "Analyzes a `%construct-struct` expression."
  (analyze-struct-construction expr env location))

(defun analyze-extract-struct-member-expression (expr env location)
  "Analyzes a `%extract-struct-member` expression.
   Form: (%extract-struct-member object-node index-literal)"
  (let* ((obj-node (analyze-expression (second expr) env (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (obj-type (semantic-node-type obj-node)))

    (unless (symbolp obj-type)
      (error "Cannot extract member from non-struct type ~a" obj-type))

    (let ((struct-def (gethash obj-type *crisp-structs*)))
      (unless struct-def
        (error "Unknown struct type ~a in extraction." obj-type))

      (let* ((padded-members (crisp-struct-definition-padded-members struct-def))
             ;; We need to map the "logical" index i to the "physical" index in the padded struct.
             ;; However, our macro passes the 'logical' index.
             ;; But wait, the macro loop `for i from 0` matches `parsed-members`.
             ;; `padded-members` has EXTRA fields. We need to find the Nth *non-padding* member.
             ;; Let's iterate padded-members to find the Nth logical member's actual index.
             (physical-index -1)
             (logical-count -1)
             (target-member-type nil))

        (loop for m in padded-members
              for idx from 0
              do (unless (alexandria:starts-with-subseq "_PAD" (symbol-name (first m)))
                   (incf logical-count)
                   (when (= logical-count index)
                         (setf physical-index idx)
                         (setf target-member-type (second m))
                         (cl:return))))

        (when (= physical-index -1)
              (error "Invalid member index ~a for struct ~a" index obj-type))

        (make-semantic-extract-value
         :type target-member-type
         :aggregate-node obj-node
         :index physical-index
         :source-location location)))))

(defun analyze-is-set-expression (expr env location)
  "Analyzes (is-set? var). Returns 1 (true) if var is bound in env, 0 (false) otherwise."
  (let ((var (second expr)))
    (unless (symbolp var)
      (error "is-set? expects a symbol, got ~s" var))
    ;; Since this is a compile-time check for optional parameters in specialized templates,
    ;; the 'env' contains *only* the parameters present for this specific specialization.
    (if (find-variable-in-env var env)
        (make-semantic-literal :value-type 'int :value 1 :source-location location)
        (make-semantic-literal :value-type 'int :value 0 :source-location location))))

(defun try-constant-fold (node)
  "Attempts to reduce a semantic node to a semantic-literal if possible."
  (typecase node
    (semantic-lt
     (let ((l (try-constant-fold (semantic-lt-left-arg node)))
           (r (try-constant-fold (semantic-lt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (< (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-lt-source-location node))
           node)))
    (semantic-gt
     (let ((l (try-constant-fold (semantic-gt-left-arg node)))
           (r (try-constant-fold (semantic-gt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (> (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-gt-source-location node))
           node)))
    (semantic-le
     (let ((l (try-constant-fold (semantic-le-left-arg node)))
           (r (try-constant-fold (semantic-le-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (<= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-le-source-location node))
           node)))
    (semantic-ge
     (let ((l (try-constant-fold (semantic-ge-left-arg node)))
           (r (try-constant-fold (semantic-ge-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (>= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-ge-source-location node))
           node)))
    (semantic-eq
     (let ((l (try-constant-fold (semantic-eq-left-arg node)))
           (r (try-constant-fold (semantic-eq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-eq-source-location node))
           node)))
    (semantic-neq
     (let ((l (try-constant-fold (semantic-neq-left-arg node)))
           (r (try-constant-fold (semantic-neq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (/= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-neq-source-location node))
           node)))
    (t node)))

(defun create-implicit-cast (node target-type location)
  "Wraps node in an implicit cast to target-type."
  (make-semantic-value-cast :type target-type
                            :arg node
                            :source-location location))

(defun ensure-branch-compatibility (then-node else-node location)
  "Unifies types of then/else branches. Returns (values unified-type new-then new-else)."
  (let ((t-type (semantic-node-type then-node)))
    (unless else-node
      ;; Propagate THEN type if no ELSE (implicitly returns void/nil or 0? 
      ;; Actually, for IF expression correctness, missing else implies value is unlikely to be used
      ;; unless it matches the implicit else value (int 0). 
      ;; For now, just return t-type. 
      (return-from ensure-branch-compatibility (values t-type then-node nil)))

    (let ((e-type (semantic-node-type else-node))
          (t-single (get-single-value-type then-node))
          (e-single (get-single-value-type else-node)))
      (if (equal t-type e-type)
          (values t-type then-node else-node)
          (let ((promoted (get-promoted-type t-single e-single)))
            (cond
             (promoted
               ;; Insert Casts
               (values promoted
                 (if (equal t-type promoted) then-node (create-implicit-cast then-node promoted location))
                 (if (equal e-type promoted) else-node (create-implicit-cast else-node promoted location))))

             ;; Special Case: Literal 0 (Int) can promote to any Pointer -> NULL
             ((and (eq t-single 'int) (typep then-node 'semantic-literal) (= (semantic-literal-value then-node) 0)
                   (listp e-type) (member (first e-type) '(ptr array)))
               (values e-type (create-implicit-cast then-node e-type location) else-node))

             ((and (eq e-single 'int) (typep else-node 'semantic-literal) (= (semantic-literal-value else-node) 0)
                   (listp t-type) (member (first t-type) '(ptr array)))
               (values t-type then-node (create-implicit-cast else-node t-type location)))

             ;; Void Compatibility: If one branch is NIL (void), unify to NIL (void).
             ;; This supports (when ...) and (unless ...) which return NIL on one path.
             ((or (null t-single) (null e-single))
               (values '(nil) then-node else-node))

             (t
               (error "Branch type mismatch in IF expression. Then: ~a, Else: ~a" t-type e-type))))))))

(defun analyze-if-expression-impl (expr env location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    (let* ((then-node (analyze-expression (third expr) env (append location '(2))))
           (else-node (if (fourth expr) (analyze-expression (fourth expr) env (append location '(3))) nil)))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location)))))

(defun analyze-if-expression (expr env location)
  (analyze-if-expression-impl expr env location :enforce-constant nil))

(defun analyze-static-if-expression (expr env location)
  (analyze-if-expression-impl expr env location :enforce-constant t))

(defun analyze-when-expression (expr env location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (when cond body...) -> (if cond (progn body...) nil)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond ,body) env location)))

(defun analyze-static-when-expression (expr env location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond ,body) env location)))

(defun analyze-unless-expression (expr env location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (unless cond body...) -> (if cond nil (progn body...))
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond nil ,body) env location)))

(defun analyze-static-unless-expression (expr env location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond nil ,body) env location)))

(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, or cell type. Returns NIL if unknown."
  (cond
   ((listp type) (second type)) ;; e.g. (ptr float), (array float 10)
   ((symbolp type)
     ;; Check if it is a Mangled Cell
     (let ((unmangled (unmangle-template-struct-name type)))
       (if (and (consp unmangled) (eq (first unmangled) 'cell))
           (second unmangled)
           nil)))
   (t nil)))

(defun analyze-aref-expression-OLD (expr env location)
  (let* ((op (first expr))
         (array-node (analyze-expression (second expr) env (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env (append location '(2)))
                         ;; Default to index 0 if not provided (e.g. `(~ ptr)`)
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    (if elem-type
        (progn
         (when (or (eq elem-type 'void) (eq elem-type :void) (string-equal elem-type "VOID"))
               (error "Cannot dereference a Cell of type VOID. Cast it to a concrete type first."))
         (make-semantic-aref :type elem-type
                             :array-node array-node
                             :index-node index-node
                             :source-location location))
        ;; Fallback: If not an array/pointer, and op is ~, try to treat as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))

(defun analyze-inc!-expression (expr env location)
  (declare (ignore expr env location))
  (error "inc! not implemented"))
(defun analyze-dec!-expression (expr env location)
  (declare (ignore expr env location))
  (error "dec! not implemented"))
(defun analyze-atomic-add!-expression (expr env location)
  (declare (ignore expr env location))
  (error "atomic-add! not implemented"))

(defun analyze-scratch-expression (expr env location)
  "Analyzes a `(make-scratch-cell ...)` expression.
  In single-pass mode, this marks the current function as an originator."
  (declare (ignore env)) ; We don't use env yet.
  (unless (and (= (length expr) 2) (symbolp (cadr expr)))
    (error "Malformed make-scratch-cell form: ~a. Expected (make-scratch-cell <type>)" expr))

  ;; --- Phase 5: Single-Pass Originator Detection ---
  ;; If *call-graph* is nil, we are in single-pass mode.
  (when (null *call-graph*)
        (log:debug "Single-pass: Found originator form in ~s. Marking it." *current-compiling-function*)
        (setf (gethash *current-compiling-function* *implicit-arg-map*)
          '(:storage)))

  (let ((inner-type (cadr expr)))
    ;; Ensure the inner type is valid
    (unless (gethash inner-type *crisp-types*)
      (error 'crisp-unknown-type-error :type-name inner-type :source-location location))

    ;; Construct raw spec and expand/canonicalize it (e.g. inject defaults)
    ;; We use expand-storage-handle-type-specifier directly to get the LIST form, not the mangled symbol.
    (let* ((raw-spec (list 'cell inner-type))
           (canonical-spec (expand-storage-handle-type-specifier raw-spec)))

      ;; Ensure instantiation
      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (raw: ~a)" canonical-spec raw-spec))

      (make-semantic-literal :value-type canonical-spec
                             :value nil ; No real value yet
                             :source-location location))))

(defun analyze-compiler-no-op (expr env location)
  "Analyzes a (compiler-no-op) form, which results in a void literal.
   Used by compile-time macros (c-t-assert, c-t-output) to emit no code."
  (declare (ignore expr env))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(def-expression-analyzer compiler-no-op analyze-compiler-no-op)

(defun analyze-progn-expression (expr env location)
  "Analyzes a `(progn ...)` expression."
  (let ((body (cdr expr))
        (nodes '()))
    (dolist (form body)
      (push (analyze-expression form env location) nodes))
    (setf nodes (nreverse nodes))
    ;; Determine type from the last node
    (let ((last-node (first (last nodes))))
      (make-semantic-progn
       :type (if last-node (semantic-node-type last-node) 'void)
       :body nodes
       :source-location location))))

(defun analyze-nested-def-function (expr env location)
  "Analyzes a nested `(def-function ...)` expression (e.g. from a template)."
  (declare (ignore env))
  (unless *allow-nested-def-function*
    (error "Unsupported form 'DEF-FUNCTION' found in function body."))

  (unless (and *current-module* *current-builder*)
    (error "Cannot compile nested def-function without active LLVM context."))

  ;; Compile the function as a top-level form
  (compile-toplevel-form expr location *current-module* *current-builder* *current-di-builder* *current-di-compile-unit* *current-location-map*)

  ;; Return a void literal so it doesn't affect the expression value
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defmacro template-instantiation (&body body)
  "Wrapper to allow nested def-functions during template instantiation.
   At top-level, it expands to PROGN to allow evaluation."
  `(progn ,@body))

(defun analyze-template-instantiation (expr env location)
  "Analyzes a `(template-instantiation ...)` form, allowing nested def-functions."
  (let ((*allow-nested-def-function* t)
        (body (second expr)))
    (log:info "ANALYZE-TEMPLATE-INSTANTIATION: Body=~a" body)
    ;; Eval the body to ensure macros (defmacro) and struct definitions (eval-when)
    ;; are registered in the current environment BEFORE analysis proceeds.
    ;; This allows subsequent forms in the function to usage the newly defined macros.
    ;; This allows subsequent forms in the function to usage the newly defined macros.
    (eval body)

    (let ((sym (find-symbol "MAKE-POINT_FLOAT" "CRISP-LANGUAGE")))
      (if sym
          (log:info "Check: MAKE-POINT_FLOAT in CRISP-LANGUAGE. Macro? ~a" (macro-function sym))
          (log:info "Check: MAKE-POINT_FLOAT NOT FOUND in CRISP-LANGUAGE")))

    ;; The body is typically a PROGN or a single form.
    ;; We analyze it recursively to generate IR for functions.
    (analyze-expression body env location)))

(defun analyze-eval-when (expr env location)
  "Analyzes (eval-when ...) forms by ignoring them in the runtime IR.
   Side effects (like struct registration) should have already occurred during macro expansion."
  (declare (ignore expr env))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-let-expression (expr env location)
  "Analyzes a `(let ...)` expression."
  (unless (and (>= (length expr) 2) (listp (cadr expr)))
    (error "Malformed let form: ~a" expr))

  (let ((binding-forms (cadr expr))
        (body-forms (cddr expr)))
    ;; Implement let* scoping by sequentially building the environment.
    (multiple-value-bind (final-env analyzed-bindings)
        (let ((current-env env)
              (bindings-list '()))
          (loop for binding in binding-forms
                for i from 0 do
                  (log:debug "Analyzing let binding form: ~s" binding)

                  ;; Determine if this is a "flat" MVB binding like (a b (val))
                  ;; or a standard nested binding like ((a b) (val)) or (a (val)).
                  (let ((is-flat-mvb (and (> (length binding) 2)
                                          (not (listp (first binding))))))

                    (let* ((binding-vars (if is-flat-mvb
                                             (butlast binding)
                                             (if (and (= (length binding) 2) (listp (first binding)))
                                                 (first binding)
                                                 (list (first binding)))))
                           (init-form (first (last binding)))
                           ;; Analyze the value form
                           (init-node (analyze-expression init-form current-env
                                                          (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1)))))
                           (init-node-types (semantic-node-type init-node)))

                      (cond
                       ;; Case 1: Single variable binding (standard let)
                       ((= (length binding-vars) 1)
                         (let* ((var-name (first binding-vars))
                                ;; For a single binding, we implicitly take the first return value's type.
                                (var-type (get-single-value-type init-node)))
                           (push (cons var-name init-node) bindings-list)
                           (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env))))

                       ;; Case 2: Multiple variable binding (destructuring)
                       ((> (length binding-vars) 1)
                         (unless (listp init-node-types)
                           (error "Cannot destructure a single-value return into multiple variables at ~a. Got type ~a for binding ~a."
                             (semantic-node-source-location init-node) init-node-types binding))
                         (unless (>= (length init-node-types) (length binding-vars))
                           (error "Not enough return values from ~a to bind ~a variables at ~a" init-form (length binding-vars) (semantic-node-source-location init-node)))

                         ;; The init-node (the function call) is analyzed once.
                         ;; We then create `extract-value` nodes for each variable.
                         (loop for var-name in binding-vars
                               for j from 0 do
                                 (let* ((var-type (nth j init-node-types))
                                        (extract-node (make-semantic-extract-value
                                                       :type var-type
                                                       :aggregate-node init-node
                                                       :index j
                                                       :source-location (semantic-node-source-location init-node))))
                                   (push (cons var-name extract-node) bindings-list)
                                   (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env)))))
                       (t (error "Malformed let binding: ~a" binding))))))
          ;; The loop builds the bindings list in reverse, so we reverse it back.
          (values current-env (reverse bindings-list)))

      (let* ((analyzed-body (analyze-body-expressions body-forms final-env (append location '(2))))
             (last-body-node (first (last analyzed-body)))
             (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
        (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                   analyzed-bindings analyzed-body return-type)
        (make-semantic-let :type return-type
                           :bindings analyzed-bindings
                           :body analyzed-body
                           :source-location location)))))

(defun analyze-return-expression (expr env location)
  "Analyzes a `(return ...)` expression."
  (let* ((value-forms (rest expr))
         (value-nodes (loop for form in value-forms
                            for i from 1
                            collect (analyze-expression form env (append location (list i)))))

         ;; Flatten types to check against signature
         (all-inferred-types (if value-nodes
                                 (loop for node in value-nodes
                                         append (let ((t-spec (semantic-node-type node)))
                                                  (if (and (listp t-spec) (not (valid-type-p t-spec)))
                                                      t-spec
                                                      (list t-spec))))
                                 '(nil)))

         ;; Context
         (current-func *current-compiling-function*)
         (sig (if current-func (first (gethash current-func *function-table*)) nil))
         (declared-ret (if sig (function-signature-return-types sig) nil))

         ;; Initialize return-types default
         (return-types all-inferred-types))

    ;; Truncation Logic
    (when (and declared-ret (not (equal declared-ret '(nil))))
          (let ((num-declared (length declared-ret))
                (num-inferred (length all-inferred-types)))

            (when (> num-inferred num-declared)
                  (log:info "Truncating return values for ~a. declared: ~a inferred: ~a" current-func declared-ret all-inferred-types)
                  (let ((new-nodes '())
                        (captured 0))
                    (loop for node in value-nodes
                          while (< captured num-declared)
                          do (let* ((type (semantic-node-type node))
                                    (is-mv (and (listp type) (not (valid-type-p type))))
                                    (count (if is-mv (length type) 1)))
                               (cond
                                (is-mv
                                  (loop for i from 0 below count
                                        while (< captured num-declared)
                                        do (push (make-semantic-extract-value :type (nth i type) :aggregate-node node :index i :source-location (semantic-node-source-location node)) new-nodes)
                                          (incf captured)))
                                (t
                                  (push node new-nodes)
                                  (incf captured)))))
                    (setf value-nodes (nreverse new-nodes))
                    (setf return-types declared-ret)))))

    (make-semantic-explicit-return :type return-types
                                   :value-nodes value-nodes
                                   :source-location location)))

(defun analyze-cast-expression (expr env location)
  "Analyzes a to-XXXX or as-XXXX cast expression."
  (let* ((op (first expr))
         (op-name (symbol-name op))
         (arg-form (second expr))
         (target-type-name
          (cond
           ((alexandria:starts-with-subseq "TO-" op-name) (intern (subseq op-name 3)))
           ((alexandria:starts-with-subseq "AS-" op-name) (intern (subseq op-name 3)))
           ;; For floor, ceil, etc., the target is always 'int' for now.
           ((member op '(floor ceil round)) 'int)
           (t (error "Internal compiler error: analyze-cast-expression called with invalid operator ~a" op))))
         (target-crisp-type (gethash target-type-name *crisp-types*))
         (arg-node (analyze-expression arg-form env (append location '(1)))))

    (unless target-crisp-type
      (error 'crisp-unknown-type-error :type-name target-type-name :source-location location))

    (let* ((source-type-name (get-single-value-type arg-node))
           (source-crisp-type (gethash source-type-name *crisp-types*)))

      (when (and (alexandria:starts-with-subseq "TO-" op-name)
                 (eq (crisp-type-category source-crisp-type) :float)
                 (member (crisp-type-category target-crisp-type) '(:signed-int :unsigned-int)))
            (error 'crisp-type-error :message "Invalid cast: Cannot use 'to-...' for float-to-integer conversion. Use 'truncate', 'floor', 'ceil', or 'round' instead."
              :source-location location))

      (let ((is-value-cast (or (alexandria:starts-with-subseq "TO-" op-name)
                               ;; An 'as-' cast between two integer types or two float types is a value cast (sext/zext/fpext), not a bitcast.
                               (and (alexandria:starts-with-subseq "AS-" op-name)
                                    (eq (crisp-type-category source-crisp-type)
                                        (crisp-type-category target-crisp-type))))))

        (cond
         ;; Handle `to-` casts and safe `as-` casts (like int->long)
         (is-value-cast
           (make-semantic-value-cast :type target-type-name :arg arg-node :source-location location))
         ((eq op 'truncate)
           (make-semantic-fp-truncate-cast :type target-type-name :arg arg-node :source-location location))
         ;; Handle unsafe `as-` bit reinterpretations
         (t ; Default for "AS-" and other currently unhandled float-to-int ops
           (make-semantic-bitcast :type target-type-name :arg arg-node :source-location location)))))))

(defun analyze-truncate-expression (expr env location)
  "Analyzes (truncate val) -> (values int rem)."
  (let* ((arg-form (second expr))
         (arg-node (analyze-expression arg-form env (append location '(1))))
         (arg-type (get-single-value-type arg-node))) ;; e.g. 'float
    (make-semantic-truncate :type (list 'int arg-type) ;; Returns (int float)
                            :arg arg-node
                            :source-location location)))

(defun analyze-generic-as-expression (expr env location)
  "Analyzes the generic (as type value) form."
  (let* ((type-form (second expr))
         (value-form (third expr))
         (type-name (if (symbolp type-form) type-form (error "Generic AS expects a type symbol, got ~a" type-form)))
         ;; If it's a template parameter (like T), it should already be substituted? 
         ;; Or if T is bound in template-params passed down? 
         ;; For now assume substitution happened.
         (target-type (gethash type-name *crisp-types*)))

    (unless target-type
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Reuse analyze-cast-expression logic but fake the operator name
    ;; Or just reimplement dispatch. Reimplementing is cleaner for custom 'as' logic.
    (let ((arg-node (analyze-expression value-form env (append location '(2)))))
      (make-semantic-value-cast :type type-name :arg arg-node :source-location location))))

(defun get-struct-member-index (struct-type-name member-name)
  "Helper to find the physical index of a struct member, accounting for padding."
  (let ((search-key (if (and (consp struct-type-name) (valid-type-p struct-type-name))
                        (mangle-template-struct-name (first struct-type-name) (rest struct-type-name))
                        struct-type-name)))
    (log:info "Looking up struct member ~a in type ~a (key: ~a params?: ~a)" member-name struct-type-name search-key (valid-type-p struct-type-name))
    (let ((struct-def (or (find-struct-definition-by-name search-key)
                          ;; Fallback: If mangled name not found, try base type (for incomplete types with props)
                          (when (and (consp struct-type-name) (valid-type-p struct-type-name))
                                (find-struct-definition-by-name (first struct-type-name))))))
      ;; Robust Lookup: If not found by symbol, try by name (ignoring package)
      (unless struct-def
        (error "Unknown struct type '~a' during member lookup." struct-type-name))

      (let* ((indices (crisp-struct-definition-field-indices struct-def))
             (index (gethash member-name indices)))
        ;; Robust Member Lookup: If not found by symbol, try by name
        (unless index
          (maphash (lambda (k v)
                     (when (string-equal (symbol-name k) (symbol-name member-name))
                           (setf index v)))
                   indices))

        (unless index
          (error "Struct '~a' has no member named '~a'." struct-type-name member-name))
        index))))

(defun analyze-set!-expression (expr env location)
  "Analyzes a (set! target value) expression."
  (let* ((target-form (second expr))
         (value-form (third expr))
         (value-node (analyze-expression value-form env (append location '(2)))))

    (cond
     ;; Case 1: Simple variable assignment (set! x v)
     ((symbolp target-form)
       (let ((var-info (find-variable-in-env target-form env)))
         (unless var-info
           (error 'crisp-unknown-variable :name target-form :source-location location))

         ;; Verify types match
         (let ((var-type (parameter-def-type var-info))
               (val-type (semantic-node-type value-node)))
           (unless (types-compatible-p val-type var-type)
             (error 'crisp-type-error :expected var-type :inferred val-type :source-location location)))

         (make-semantic-set!
          :target-node (make-semantic-var-read :name target-form :type (parameter-def-type var-info) :source-location location)
          :value-node value-node
          :source-location location)))

     ;; Case 2: Function Call / Struct Accessor
     ((and (listp target-form) (>= (length target-form) 1) (symbolp (first target-form)))
       (let* ((op (first target-form))
              (op-args (rest target-form))
              ;; Analyze the arguments to `(op args...)`
              (arg-nodes (loop for arg in op-args
                               for i from 1
                               collect (analyze-expression arg env (append location (list 1 i)))))
              (all-arg-nodes (append arg-nodes (list value-node)))
              (all-arg-types (mapcar #'semantic-node-type all-arg-nodes))
              ;; Check for a matching setter function signature: (op arg1 ... argN value)
              (full-setter-name (intern (format nil "~a_SET!" op) (symbol-package op)))
              (signatures (append (gethash op *function-table*)
                            (gethash full-setter-name *function-table*)))
              (match (find-if (lambda (sig) (types-list-compatible-p all-arg-types (function-signature-parameters sig))) signatures)))

         ;; If no match found, try checking if it's a template we can instantiate
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*) full-setter-name op)))
             (when (gethash template-op *template-registry*)
                   (ensure-template-instantiation template-op all-arg-types (lambda (f l) (declare (ignore l)) (eval f)))
                   ;; Re-fetch signatures after possible instantiation
                   (setf signatures (append (gethash op *function-table*)
                                      (gethash full-setter-name *function-table*)))
                   (setf match (find-if (lambda (sig) (types-list-compatible-p all-arg-types (function-signature-parameters sig))) signatures)))))

         (cond
          ;; Sub-case 2a: Found an overloaded setter function -> Call it.
          (match
            (make-semantic-call
             :name (function-signature-name match)
             :type (function-signature-return-types match)
             :args all-arg-nodes
             :signature match
             :source-location location))

          ;; Sub-case 2b: It is an expression analyzer (e.g. `~`, `aref`)
          ((gethash op *expression-analyzers*)
            (let ((target-node
                   (let ((*analysis-access-mode* :write))
                     (analyze-expression target-form env (append location '(1))))))
              (make-semantic-set!
               :target-node target-node
               :value-node value-node
               :source-location location)))

          ;; Sub-case 2c: Fallback to Struct Member Update (Legacy Accessor Logic)
          ;; Only valid if default accessors are used and no explicit setter overrides it.
          (t
            (let* ((op-name (symbol-name op))
                   (is-accessor (or (alexandria:ends-with #\~ op-name)
                                    (and (alexandria:starts-with #\~ op-name)
                                         (alexandria:ends-with #\~ op-name)))))
              (unless is-accessor
                (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor." target-form))

              ;; The structure member update logic expects the FIRST arg to be the struct.
              (unless (= (length arg-nodes) 1)
                (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a." op (length arg-nodes)))

              (let* ((clean-name (string-trim "~" op-name))
                     (member-sym (intern clean-name (symbol-package op)))
                     (struct-node (first arg-nodes))
                     (struct-type (semantic-node-type struct-node)))

                ;; Verify struct node is a variable (l-value) or reference (aref)
                (unless (or (semantic-var-read-p struct-node)
                            (semantic-aref-p struct-node))
                  (error "Cannot set member of non-variable/non-reference struct form: ~a" (second target-form)))

                (let ((member-index (get-struct-member-index struct-type member-sym)))
                  ;; Create the update node
                  (let ((update-node (make-semantic-struct-member-update
                                      :type struct-type
                                      :struct-node struct-node
                                      :member-index member-index
                                      :value-node value-node
                                      :source-location location)))

                    ;; Wrap in a set! for the struct variable
                    (make-semantic-set!
                     :target-node struct-node
                     :value-node update-node
                     :source-location location)))))))))

     (t (error "Invalid set! target structure: ~a" target-form)))))


(defun analyze-function-call-OLD (op expr env location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op *current-compiling-function*)
  (if *call-graph*
      (when *current-compiling-function*
            (pushnew op (gethash *current-compiling-function* *call-graph*)))
      (when (member op *single-pass-call-stack*)
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (null *call-graph*) implicit-args-required)
          (setf (gethash *current-compiling-function* *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for arg-name in '(__storage_ptr __storage_size)
                              collect (let ((found (find-variable-in-env arg-name env)))
                                        (if found
                                            (make-semantic-var-read :name arg-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              *current-compiling-function* arg-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        ;; Check for invalid use of ~ on VOID cells
        (let ((ret-type (function-signature-return-types signature)))
          (when (and (or (string= (symbol-name op) "~") (string= (symbol-name op) "~REF~"))
                     (or (equal ret-type '(void)) (eq ret-type 'void)
                         (and (listp ret-type) (string-equal (symbol-name (first ret-type)) "VOID"))))
                (error "Cannot dereference a Cell of type VOID. Cast it to a concrete type first.")))

        ;; Check for invalid READ access on &out parameters
        (when (or (string= (symbol-name op) "~") (string= (symbol-name op) "~REF~"))
              (let ((first-arg (first arg-forms)))
                (when (symbolp first-arg)
                      (let ((binding (find-variable-in-env first-arg env)))
                        (when (and binding (eq (parameter-def-kind binding) :out))
                              (error 'crisp-illegal-access-error
                                :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." first-arg)
                                :source-location location))))))

        (make-semantic-call :name (function-signature-name signature)
                            :type (function-signature-return-types signature)
                            :args final-arg-nodes
                            :signature signature
                            :source-location location)))))

(defun analyze-funcall-expression (expr env location)
  "Analyzes a (funcall f args...) form."
  (let* ((func-expr (second expr))
         (args-exprs (cddr expr))
         (func-node (analyze-expression func-expr env location))
         (func-type (semantic-node-type func-node)))

    ;; Check if the function expression resolved to a function type or literal.
    ;; e.g. (:function-type (int) :params (int int)) 
    ;; or (:function-literal +)

    (let ((signature-return-type nil)
          (signature-params nil))

      (cond
       ;; Case 1: Function Type (e.g. from a parameter)
       ((and (listp func-type) (eq (first func-type) :function-type))
         (setf signature-return-type (second func-type)) ; (int)
         (setf signature-params (getf (cddr func-type) :params))) ;; Case 2: Function Literal (e.g. #'+)
       ((and (listp func-type) (eq (first func-type) :function-literal))
         (let ((name (second func-type)))
           ;; Sub-case 2a: It is a primitive/special-form with an analyzer (e.g. +)
           (when (gethash name *expression-analyzers*)
                 ;; Re-dispatch as if it were a direct call: (+ a b)
                 (let ((new-expr (cons name args-exprs)))
                   (return-from analyze-funcall-expression
                                (funcall (gethash name *expression-analyzers*) new-expr env location))))

           ;; Sub-case 2b: It is a user function. Lower to direct semantic-call.
           (let* ((arg-nodes (loop for arg in args-exprs collect (analyze-expression arg env location)))
                  (arg-types (mapcar #'semantic-node-type arg-nodes))
                  (signatures (gethash name *function-table*))
                  (match (find-if (lambda (sig)
                                    (equal arg-types (function-signature-parameters sig)))
                             signatures)))
             (unless match
               (error "No matching signature for funcall of literal ~a with types ~a. Table count: ~a" name arg-types (hash-table-count *function-table*)))

             (return-from analyze-funcall-expression
                          (make-semantic-call
                           :name name
                           :type (function-signature-return-types match)
                           :args arg-nodes
                           :signature match
                           :source-location location)))))

       (t
         (error "First argument to funcall must be a function type or literal. Got ~a" func-type)))

      ;; Continued Case 1 logic (Function Type)
      ;; Verify argument count
      (unless (= (length args-exprs) (length signature-params))
        (error 'crisp-signature-arity-error :expected (length signature-params) :inferred (length args-exprs)))

      ;; Analyze and check arguments
      (let ((arg-nodes
             (loop for arg-expr in args-exprs
                   for expected-type in signature-params
                   for i from 0
                   collect (let ((node (analyze-expression arg-expr env location)))
                             ;; Type check
                             (unless (equal (semantic-node-type node) expected-type)
                               (error 'crisp-type-error :expected expected-type :inferred (semantic-node-type node) :source-location location))
                             node))))
        (make-semantic-funcall
         :func-node func-node
         :type signature-return-type ; e.g. (int)
         :args arg-nodes
         :source-location location)))))

(defun analyze-parameters (params)
  "Builds the environment (a symbol table)."
  ;; For now, just a simple list.
  ;; '((a i32) (b i32))
  (mapcar #'(lambda (p) (list (first p) (second p))) params))

(defun analyze-struct-construction (expr env location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form."
  (let* ((type-name (second expr))
         (args (cddr expr))
         (struct-def (gethash type-name *crisp-structs*)))
    (unless struct-def
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Validate argument count against original members (excluding compile-time properties)
    (let* ((all-members (crisp-struct-definition-members struct-def))
           (members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) all-members)))
      (unless (= (length args) (length members))
        (error "Struct constructor for ~a expects ~a arguments, got ~a."
          type-name (length members) (length args)))

      ;; Analyze arguments
      (let ((arg-nodes
             (loop for arg in args
                   for member in members
                   for i from 0
                   collect (let ((node (analyze-expression arg env (append location (list (+ 2 i)))))
                                 (expected-type (second member)))
                             ;; Type check
                             (unless (type-equal-p (semantic-node-type node) expected-type)
                               ;; Relaxed check for literals behaving as types?
                               ;; For now strict equality (but robust to template mangling).
                               (error 'crisp-type-error
                                 :expected expected-type
                                 :inferred (semantic-node-type node)
                                 :source-location location))
                             node))))

        (make-semantic-struct-construction
         :type type-name
         :args arg-nodes
         :source-location location)))))

(def-expression-analyzer %construct-struct analyze-struct-construction)

(defun analyze-body-expressions (body-list env location)
  "Recursively analyzes a list of expressions."
  (loop for expr in body-list
        for i from 0
          unless (null expr)
        collect (analyze-expression expr env (append location (list i)))))

(defun analyze-expression-OLD (expr env location)
  "Recursively analyzes a *single* expression."
  (log:debug "analyze-expression expr: ~s location: ~s" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
        (return-from analyze-expression-OLD (make-semantic-progn :type '(nil) :body nil :source-location location)))

  (cond
   ;; Case 1: It's a literal, like 7
   ((integerp expr)
     (make-semantic-literal :value-type 'int :value expr :source-location location))

   ;; Case 1.1: It's a float literal, like 3.14
   ((floatp expr)
     ;; For now, all floating point literals default to the 'float' type.
     (make-semantic-literal :value-type 'float :value expr :source-location location))

   ;; Case 1.5: It's a keyword symbol, like :foo
   ;; Case 1.5: It's a keyword symbol, like :foo
   ((keywordp expr)
     (make-semantic-literal :value-type (list 'keyword expr) :value expr :source-location location))

   ;; Case 2: It's a variable, like 'a'
   ((symbolp expr)
     (let ((found (assoc expr env)))
       (if found
           (make-semantic-var-read :name expr :type (second found) :source-location location)
           (error 'crisp-unknown-variable
             :name expr
             :source-location location))))

   ;; Case 3: It's a function call, like '(+ a b)'
   ((listp expr) (let ((op (first expr)))
                   (log:info "analyze-expression list op: ~a (pkg: ~a) macro-function: ~a" op (package-name (symbol-package op)) (macro-function op))
                   (log:debug "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)
                   (cond ;; Case 3a: Is there a specific handler for this operator (e.g., '+', 'to-char')?
                        ((gethash op *expression-analyzers*)
                          (funcall (gethash op *expression-analyzers*) expr env location))
                        ;; Case 3b: Is it a macro?
                        ((macro-function op)
                          (analyze-expression (macroexpand-1 expr) env location))
                        ;; Case 3c: Is it a call to a known user-defined function?
                        ;; Also check implicit *template-registry* for overloading
                        ((or (gethash op *function-table*)
                             (gethash op *template-registry*))
                          (analyze-function-call op expr env location))
                        ;; Case 3c: Otherwise, we don't know what this is.
                        (t
                          (log:debug "  UNSUPPORTED FORM: ~a (pkg: ~a) (addr: ~x)" op (package-name (symbol-package op)) (sb-kernel:get-lisp-obj-address op))
                          (log:debug "  Function Table Keys: ~a" (alexandria:hash-table-keys *function-table*))
                          (error 'crisp-unsupported-form-error
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
         (let* ((*current-module* module)
                (form-with-location (append crisp-form (list :source-location ''(0))))
                (expanded-form (macroexpand-1 form-with-location))
                (semantic-fn (eval expanded-form)))
           (generate-llvm-ir semantic-fn module builder di-builder di-compile-unit location-map))
         (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
      ;; Cleanup.
      (when di-builder (llvm-di-builder-finalize di-builder))
      (when di-builder (llvm-dispose-di-builder di-builder))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))

;; PATCH: Redefine analyze-function-call to fix void cell dereference issue
(defun analyze-function-call (op expr env location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op *current-compiling-function*)
  (if *call-graph*
      (when *current-compiling-function*
            (pushnew op (gethash *current-compiling-function* *call-graph*)))
      (when (member op *single-pass-call-stack*)
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (null *call-graph*) implicit-args-required)
          (setf (gethash *current-compiling-function* *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for kw in implicit-args-required
                              collect (let ((arg-name (case kw
                                                        (:storage '__storage)
                                                        (t (error "Unknown implicit arg keyword: ~s" kw)))))
                                        (let ((found (find-variable-in-env arg-name env)))
                                          (if found
                                              (make-semantic-var-read :name arg-name :type (parameter-def-type found) :source-location location)
                                              (error "Compiler bug: Carrier function ~s is missing implicit argument ~s (for ~s)."
                                                *current-compiling-function* arg-name kw)))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        ;; Check for invalid use of ~ on VOID cells (Robust Check)
        (let ((ret-type (function-signature-return-types signature)))
          ;; Robust check for VOID (symbol, string, list wrapped)
          (let ((is-void (or (eq ret-type 'void)
                             (and (symbolp ret-type) (string-equal (symbol-name ret-type) "VOID"))
                             (and (consp ret-type)
                                  (let ((head (first ret-type)))
                                    (or (eq head 'void)
                                        (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
            (when (and (or (string= (symbol-name op) "~") (string= (symbol-name op) "~REF~"))
                       is-void)
                  (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~)."))))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-types (mapcar #'semantic-node-type (subseq final-arg-nodes 0 (length implicit-args-required)))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-types (function-signature-parameters signature))
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

;; PATCH: Redefine analyze-aref-expression to fix void cell dereference issue
(defun analyze-aref-expression (expr env location)
  (let* ((op (first expr))
         (target-sym (if (symbolp (second expr)) (second expr) nil))
         (array-node (analyze-expression (second expr) env (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env (append location '(2)))
                         ;; Default to index 0 if not provided (e.g. `(~ ptr)`)
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    ;; Check for invalid READ access on &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
          (let ((binding (find-variable-in-env target-sym env)))
            (when (and binding (eq (parameter-def-kind binding) :out))
                  (error 'crisp-illegal-access-error
                    :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." target-sym)
                    :source-location location))))

    (if elem-type
        (progn
         ;; Check for VOID element type
         (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "VOID"))
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "T"))
                            (and (consp elem-type)
                                 (let ((head (first elem-type)))
                                   (or (eq head 'void) (eq head 'T)
                                       (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
           (when is-void
                 (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

         (make-semantic-aref :type elem-type
                             :array-node array-node
                             :index-node index-node
                             :source-location location))
        ;; Fallback: If not an array/pointer, and op is ~, try to treat as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))


;; PATCH: Handle Struct/Record CT Accessors on Incomplete/Parameterized Types
(defun analyze-incomplete-type-accessor (op expr env location)
  "Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).
   Returns a semantic-node (literal) if resolved, or NIL if not applicable."
  (let ((op-name (symbol-name op)))
    ;; Check if it looks like an accessor (ends with ~)
    (when (and (> (length op-name) 1) (alexandria:ends-with #\~ op-name))
          (let* ((member-name (intern (string-trim "~" op-name) (symbol-package op)))
                 ;; Analyze the first argument (obj)
                 (obj-expr (second expr)))
            (when obj-expr
                  (log:info "Incomplete Accessor Check: Op=~s Member=~s ObjExpr=~s" op member-name obj-expr)
                  ;; To avoid double analysis if not resolved, we might need to be careful.
                  ;; But analyze-expression is side-effect free mostly.
                  ;; Actually, analyze-expression might error if var not found etc. 
                  ;; Safe to call.
                  (let* ((obj-node (analyze-expression obj-expr env (append location '(1))))
                         (obj-type (semantic-node-type obj-node)))

                    ;; Check if obj-type carries the value
                    (when (and (consp obj-type) (valid-type-p obj-type))
                          (let* ((canon (canonicalize-type-specifier obj-type))
                                 (base (first canon))
                                 (params (rest canon)))
                            (log:info "  ObjType: ~s Canon: ~s Params: ~s" obj-type canon params)

                            ;; Only proceed if it is a Record or Struct
                            (when (or (gethash base *crisp-structs*) (gethash base *crisp-types*))
                                  ;; Look for the member in the parameters (e.g. :color :blue)
                                  ;; params is list of args. If keywords used, getf works.
                                  ;; Note: canonicalize might return positional args too.
                                  ;; For now assume Keywords for incomplete types (def-record usually).

                                  (let ((kw (intern (symbol-name member-name) "KEYWORD")))
                                    (let ((val (getf params kw)))
                                      (when val
                                            ;; Return the literal value
                                            (cond
                                             ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
                                             ((symbolp val) (make-semantic-literal :value-type 'symbol :value val :source-location location))
                                             ((integerp val) (make-semantic-literal :value-type 'int :value val :source-location location))
                                             (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))))))))))))

;; Resurrect analyze-expression to force usage of new analyze-set!
(defun analyze-expression (expr env location)
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
                  (make-semantic-var-read :name expr :type (parameter-def-type found) :source-location location)
                  (progn
                   (log:error "Unknown Variable Lookup: ~a (pkg: ~a)" expr (package-name (symbol-package expr)))
                   (log:error "Env Keys: ~a" (mapcar (lambda (p) (let ((s (parameter-def-name p))) (if (symbolp s) (format nil "~a (pkg: ~a)" s (package-name (symbol-package s))) (format nil "NON-SYMBOL-KEY: ~a" s)))) env))
                   (error 'crisp-unknown-variable
                     :name expr
                     :source-location location)))))

          ;; Case 3: It's a function call, like '(+ a b)'
          ((listp expr) (let ((op (first expr)))
                          (log:debug "analyze-expression list op: ~a (pkg: ~a) macro-function: ~a" op (package-name (symbol-package op)) (macro-function op))
                          (when (eq op 'quote)
                                (log:debug "ANALYZE-EXPR (NEW): QUOTE check. Analyzer: ~a" (gethash op *expression-analyzers*)))
                          (log:debug "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)

                          ;; HOISTED CHECK: Try incomplete accessor first
                          (let ((hook-res (analyze-incomplete-type-accessor op expr env location)))
                            (if hook-res
                                hook-res
                                ;; Otherwise continue with standard checks
                                (cond ;; Case 3a: Is there a specific handler for this operator (e.g., '+', 'to-char')?
                                     ((gethash op *expression-analyzers*)
                                       (funcall (gethash op *expression-analyzers*) expr env location))
                                     ;; Case 3b: Is it a macro?
                                     ((macro-function op)
                                       (analyze-expression (macroexpand-1 expr) env location))
                                     ;; Case 3c: Is it a call to a known user-defined function?
                                     ;; Also check implicit *template-registry* for overloading
                                     ;; AND *generic-functions* for lazy instantiation
                                     ((or (gethash op *function-table*)
                                          (gethash op *template-registry*)
                                          (gethash op *generic-functions*))
                                       (analyze-function-call op expr env location))
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

(defun analyze-quote (expr env location)
  (declare (ignore env))
  (let ((val (second expr)))
    (cond
     ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
     ((symbolp val) (make-semantic-literal :value-type 'symbol :value val :source-location location))
     (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))

(def-expression-analyzer quote analyze-quote)

(defun analyze-sizeof-expression (expr env location)
  (declare (ignore env))
  (unless (= (length expr) 2)
    (error "sizeof expects exactly 1 argument: (sizeof type)"))
  (let* ((raw-type (second expr))
         (type-spec (parse-type-specifier raw-type)))
    (unless (valid-type-p type-spec)
      (error 'crisp-unknown-type-error :type-name raw-type :source-location location))
    (make-semantic-sizeof :type 'ulong
                          :target-type type-spec
                          :source-location location)))
