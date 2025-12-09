;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/compiler.lisp
(in-package :crisp.compiler)

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


(defvar *template-instantiator-fn* nil
        "Hook for template instantiation.
   Called as (funcall *template-instantiator-fn* name arg-types callback).
   The callback is (funcall callback form location).")

(defvar *side-channel-originators* '(make-scratch-cell)
        "A list of function names that trigger the implicit side-channel argument passing mechanism.")

(defvar *originator-functions* nil
        "A hash table containing the names of all functions that directly use a side-channel originator.")

(defvar *implicit-arg-map* (make-hash-table)
        "A hash table mapping function names to the implicit side-channel arguments they require.")

(defvar *crisp-types* (make-hash-table)
        "A hash table mapping type names (symbols) to CRISP-TYPE structs.")


(defvar *current-compiling-function* nil)
(defvar *current-module* nil)
(defvar *current-builder* nil)
(defvar *current-di-builder* nil)
(defvar *current-di-compile-unit* nil)
(defvar *current-location-map* nil)
(defvar *allow-nested-def-function* nil)

(defstruct crisp-type
  "Represents a Crisp type."
  (name nil :type symbol)
  ;; The function to get the llvm-type-ref.
  ;; We use a function so we don't have to have a live LLVM context
  ;; when we first define all the types.
  (llvm-type-fn nil :type function)
  (size 0 :type integer) ; size in bits
  (category nil :type (member :signed-int :unsigned-int :float)))


(defstruct function-signature
  "Represents the full signature of a Crisp function."
  (name nil :type symbol)
  (parameters nil :type list)
  (return-types nil :type list)
  (source-location nil :type list)
  (is-template-p nil :type boolean)
  (template-params nil :type list))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Type System Initialization
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *expression-analyzers* (make-hash-table)
        "A dispatch table mapping operator symbols to their analyzer functions.")

(defmacro def-expression-analyzer (operator handler-fn)
  "A helper macro to register an operator's analyzer function."
  `(setf (gethash ',operator *expression-analyzers*) ',handler-fn))

(defun initialize-crisp-types ()
  "Populates the *crisp-types* hash table with built-in scalar types."
  (clrhash *crisp-types*)
  (let ((types
         `(;; Signed Integers
           (char ,#'llvm-int8-type 8 :signed-int)
           (short ,#'llvm-int16-type 16 :signed-int)
           (int ,#'llvm-int32-type 32 :signed-int)
           (long ,#'llvm-int64-type 64 :signed-int)
           ;; Unsigned Integers
           (uchar ,#'llvm-int8-type 8 :unsigned-int)
           (ushort ,#'llvm-int16-type 16 :unsigned-int)
           (uint ,#'llvm-int32-type 32 :unsigned-int)
           (ulong ,#'llvm-int64-type 64 :unsigned-int)
           ;; Floating Point
           (half ,#'llvm-half-type 16 :float)
           (bfloat16 ,#'llvm-bfloat-type 16 :float)
           (float ,#'llvm-float-type 32 :float)
           (double ,#'llvm-double-type 64 :float))))
    (loop for (name llvm-fn size category) in types
          do (setf (gethash name *crisp-types*)
               (make-crisp-type :name name
                                :llvm-type-fn llvm-fn
                                :size size
                                :category category)))))


(defun initialize-compiler (&key (log-level :info))
  "A master initialization function for the Crisp compiler.
  This should be called by any entry point into the system (REPL, executable, CI)."
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system.
  (log:config :sane2 log-level)

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized.")))


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
    (log:debug "which package?: ~a ~%" *package*)

    ;; Eagerly register the signature for single-pass compilation scenarios.
    ;; This ensures that when loading a file, function signatures are known
    ;; before they are called by subsequent functions in the same file.
    (register-function-signature `(def-function ,name ,params ,@body) source-location)

    (log:debug "name: ~a  params: ~a  body: ~a ~%source-location: ~a~%"
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
        ',declarations ;  '(((type a b int)) ((return-type int)))
        ',body-forms ;  '((+ a b))
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
     (expected :initarg :expected :reader type-error-expected :initform nil)
     (inferred :initarg :inferred :reader type-error-inferred :initform nil))
  (:report (lambda (condition stream)
             (format stream (type-error-message condition))
             (when (or (type-error-expected condition)
                       (type-error-inferred condition))
                   (format stream "Type mismatch! Expected ~a but inferred ~a."
                     (type-error-expected condition)
                     (type-error-inferred condition))))))

(define-condition crisp-unknown-type-error (crisp-compiler-error)
    ((type-name :initarg :type-name :reader unknown-type-name))
  (:report (lambda (condition stream)
             (format stream "Unknown type '~a'." (unknown-type-name condition)))))

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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Type System Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
  Handles simple types, parameterized types, and function literals/types."
  (cond
   ;; Standard types
   ((symbolp type-spec) (gethash type-spec *crisp-types*))
   ;; Function Type Literal: (:function-literal +)
   ((and (listp type-spec) (eq (first type-spec) :function-literal))
     (and (= (length type-spec) 2) (symbolp (second type-spec))))
   ;; Function Type Descriptor: (:function-type (int) :params (int int))
   ((and (listp type-spec) (eq (first type-spec) :function-type))
     t) ;; Relaxed check for now, assumed constructed correctly by parser.
   ;; Parameterized type like '(cell int)
   ((listp type-spec)
     (let ((base-type (first type-spec))
           (params (rest type-spec)))
       (cond
        ((and (eq base-type 'cell) (= (length params) 1) (gethash (first params) *crisp-types*)) t)
        (t nil))))
   (t nil)))


(defun analyze-function-literal (expr env location)
  "Analyzes a (function name) form, e.g., #'foo."
  (let ((fn-name (second expr)))
    ;; Check if the function exists (simplistic check for now)
    (unless (or (fboundp fn-name) (gethash fn-name *function-table*))
      (log:warn "Function literal ~a refers to unknown function (at compile time)." fn-name))

    (make-semantic-literal
     :value-type `(:function-literal ,fn-name)
     :value fn-name
     :source-location location)))


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
  (def-expression-analyzer /= analyze-neq-expression)

  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)

  (def-expression-analyzer set! analyze-set!-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression) ;; NEW

  (def-expression-analyzer atomic-add! analyze-atomic-add!-expression)
  (def-expression-analyzer to analyze-value-cast-expression)
  (def-expression-analyzer as analyze-bitcast-expression)
  (def-expression-analyzer as-bits analyze-bitcast-expression) ;; alias
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer aref analyze-aref-expression)
  ;; ~ is an alias for aref
  (def-expression-analyzer ~ analyze-aref-expression)

  ;; From duplicate definition:
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)

  ;; Register all possible `to-` and `as-` casts.
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (let* ((type-str (symbol-name type-name))
           (to-name (intern (concatenate 'string "TO-" type-str) :crisp.compiler))
           (as-name (intern (concatenate 'string "AS-" type-str) :crisp.compiler)))
      (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
      (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression)))
  ;; Register the special float-to-int conversion functions
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression))

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name ; 'my-func
  param-list ; A list of types
  return-type ; The *validated* type, e.g., 'i32
  body ; A list of *other* semantic nodes
  source-location)

;; blueprint for a 'return' statement
(defstruct semantic-return
  return-type ; 'i32
  value-node ; The node for the value being returned
  source-location)

(defstruct semantic-explicit-return
  "Represents an explicit (return ...) form."
  type ; A list of types, e.g., '(int int)
  value-nodes ; A list of semantic nodes for the values
  source-location)


;; blueprint for a literal
(defstruct semantic-literal
  value-type ; 'i32
  value ; 7
  source-location)

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
  type ; The *result* type (e.g., 'i32)
  left-arg ; The 'semantic-var-read' node for 'a'
  right-arg ; The 'semantic-var-read' node for 'b'
  source-location)

(defstruct semantic-sub
  type left-arg right-arg source-location)

(defstruct semantic-mul
  type left-arg right-arg source-location)

(defstruct semantic-div
  type left-arg right-arg source-location)

(defstruct semantic-lt
  type left-arg right-arg source-location)

(defstruct semantic-gt
  type left-arg right-arg source-location)

(defstruct semantic-le
  type left-arg right-arg source-location)

(defstruct semantic-ge
  type left-arg right-arg source-location)

(defstruct semantic-eq
  type left-arg right-arg source-location)

(defstruct semantic-neq
  type left-arg right-arg source-location)

(defstruct semantic-if
  type condition-node then-node else-node source-location)

(defstruct semantic-set!
  name value-node source-location)

(defstruct semantic-aref
  type array-node index-node source-location)

(defstruct semantic-value-cast
  "Represents a value-preserving cast (e.g., to-float)."
  type ; The target type
  arg ; The node being cast
  source-location)

(defstruct semantic-bitcast
  "Represents a bit reinterpretation cast (e.g., as-int)."
  type ; The target type
  arg ; The node being cast
  source-location)

(defstruct semantic-fp-truncate-cast
  "Represents a float-to-integer truncation cast."
  type ; The target integer type
  arg ; The float node being cast
  source-location)


(defstruct semantic-call
  "Represents a call to a user-defined function."
  name ; The symbol name of the function being called
  type ; The return type of the function
  args ; A list of semantic nodes for the arguments
  signature ; The specific FUNCTION-SIGNATURE struct that was resolved
  source-location)

(defstruct semantic-funcall
  "Represents a 'funcall' form."
  func-node ; The semantic node for the function expression (e.g. var-read or literal)
  type ; The return type of the call
  args ; A list of semantic nodes for arguments
  source-location)

(defstruct semantic-let
  "Represents a (let ...) expression."
  type ; The type of the *last* expression in the body
  bindings ; A list of (name . semantic-node) pairs
  body ; A list of semantic nodes for the body
  source-location)

(defstruct semantic-extract-value
  "Represents extracting a single value from an aggregate (struct)."
  type ; The type of the extracted value (e.g., 'int)
  aggregate-node ; The semantic node for the aggregate (e.g., a semantic-call)
  index ; The 0-based index to extract
  source-location)


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
    ;; After analysis, check the constructed graph for cycles.
    (check-for-recursion-cycles)))

(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers."
  (let ((worklist '()))
    ;; 1. Seed the map and worklist with all originator functions.
    (loop for fn-name being the hash-keys of *originator-functions*
          do (setf (gethash fn-name *implicit-arg-map*) '(:storage-ptr :storage-size))
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
                   (setf (gethash caller *implicit-arg-map*) '(:storage-ptr :storage-size))
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
  "Compiles a single def-function form."
  ;; In single-pass mode, the signature won't be registered yet.
  ;; We check and register it here to ensure forward calls work.
  ;; In multi-pass mode, this check prevents re-registration.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location)) (let ((*current-compiling-function* (second form)))
                                                   (push *current-compiling-function* *single-pass-call-stack*)
                                                   (unwind-protect
                                                       (let ((form-with-location (append form (list :source-location `',location))))
                                                         (let ((expanded-form (macroexpand-1 form-with-location)))
                                                           ;; Handle implicit templates which return nil
                                                           (let ((semantic-node (eval expanded-form)))
                                                             (when semantic-node
                                                                   (generate-llvm-ir semantic-node module builder di-builder di-compile-unit location-map)))))
                                                     (pop *single-pass-call-stack*))))

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

(defun parse-function-declarations (params declarations)
  "Parses a function's declarations and returns its environment and return type."
  (let* ((fn-decl (find 'function declarations :key #'car))
         (return-types (if fn-decl
                           (analyze-return-type-from-spec (second fn-decl))
                           (analyze-return-type-from-list declarations)))
         (env (if fn-decl
                  (analyze-environment-from-spec params (second fn-decl))
                  (analyze-environment-from-list params declarations))))
    (values env return-types)))

(defun register-function-signature (form location)
  "Extracts and registers a function's signature without analyzing its body."
  (let* ((name (second form))
         (params (third form))
         (body (cdddr form))
         (declare-forms (loop for f in body while (and (listp f) (eq (car f) 'declare)) collect f))
         (existing-signatures (gethash name *function-table*)))
    (multiple-value-bind (env return-types)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))
      ;(dump-env env)
      (let ((param-types (mapcar #'second env)))
        ;; Add the new signature to the list of existing ones.
        (setf (gethash name *function-table*)
          (append existing-signatures (list (make-function-signature :name name :parameters param-types :return-types return-types :source-location location))))))))

(defun inject-implicit-arguments (name explicit-env)
  "Injects implicit arguments into the environment if the function is a carrier."
  (let* ((implicit-args (gethash name *implicit-arg-map*))
         (implicit-env (when implicit-args
                             '((__storage_ptr ulong) (__storage_size ulong)))))
    (append implicit-env explicit-env)))

(defun scan-for-carriers (name body)
  "Performs a single-pass look-ahead to detect if the function is a carrier."
  (when (null *call-graph*)
        (multiple-value-bind (is-originator callees) (shallow-analyze-body body)
          (when (or is-originator (some (lambda (callee)
                                          (or (gethash callee *implicit-arg-map*)
                                              (member callee *side-channel-originators*)))
                                      callees))
                (log:debug "Single-pass: Pre-scan of ~s found call to a carrier/originator. Marking as carrier." name)
                (setf (gethash name *implicit-arg-map*) '(:storage-ptr :storage-size))))))

(defun validate-return-types (name body env declared-return-types location)
  "Analyzes the function body and validates return types."
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
                   (equal inferred-subset declared-return-types))
        (error 'crisp-type-error
          :expected declared-return-types
          :inferred inferred-types
          :source-location (if return-node
                               (semantic-node-source-location return-node)
                               location))))
    body-nodes))

(defun internal-def-function (name params declarations body location)
  "This is the 'Semantic Analyzer' (Pass 2)."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)

    ;; 0. Implicit Template Detection
    (let ((implicit-args (loop for (pname ptype) in explicit-env
                                 when (and (listp ptype) (eq (first ptype) :function-type))
                               collect (list pname ptype))))
      (when implicit-args
            (log:info "Detected implicit template candidates in function ~a: ~a" name implicit-args)
            ;; REMOVE from function table because register-function-signature already put it there!
            (remhash name *function-table*)

            ;; Convert to template
            (let* ((template-params (loop for i from 0 repeat (length implicit-args) collect (intern (format nil "<IMPLICIT-F-~a>" i))))
                   (subst-map (loop for (pname ptype) in implicit-args
                                    for tparam in template-params
                                    collect (cons pname tparam)))
                   ;; Reconstruct environment with template params
                   (new-env (loop for (pname ptype) in explicit-env
                                  collect (let ((match (assoc pname subst-map)))
                                            (if match
                                                (list pname (cdr match))
                                                (list pname ptype)))))
                   ;; Construct signature for inference
                   (signature-list (append (mapcar #'second new-env) '(=>) return-type))
                   ;; Reconstruct body form using signature
                   (new-def-form `(def-function ,name ,params (declare (function ,signature-list)) ,@body)))

              (log:info "Registering implicit template ~a with params ~a" name template-params)
              (register-template name template-params nil new-def-form signature-list)
              (return-from internal-def-function nil))))

    ;; 1. Single-Pass Carrier Look-ahead
    (scan-for-carriers name body)

    ;; 2. Implicit Argument Handling
    (let ((env (inject-implicit-arguments name explicit-env)))

      ;; 3. Analyze Body and Validate Return Types
      (let ((body-nodes (validate-return-types name body env return-type location)))

        ;; 4. Build and return the "blueprint"
        (let ((return-node (first (last body-nodes))))
          (make-semantic-function
           :name name
           :param-list (loop for (param-name param-type) in env
                             collect (make-semantic-param :name param-name :type param-type :source-location location))
           :return-type return-type
           :body (if (typep return-node 'semantic-explicit-return)
                     (list return-node)
                     (list (make-semantic-return
                            :return-type (if (listp (semantic-node-type return-node))
                                             (semantic-node-type return-node)
                                             (list (semantic-node-type return-node)))
                            :value-node return-node
                            :source-location (if return-node (semantic-node-source-location return-node) location))))
           :source-location location))))))


;; ### Helpers

;; --- #'(...) Syntax Parsers ---


(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   and function types like #'(int => int)."
  (cond
   ;; Standard symbol: e.g. 'int'
   ((valid-type-p spec) spec)
   ;; Function Type: #'(int => int) or (function int => int)
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     ;; Recursively parse the function signature? 
     ;; For now, let's just create a :function-type descriptor.
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                   (subseq sig 0 (position '=> sig))))))
   ;; List but not a function? Maybe a parameterized type like '(cell int)
   ((and (listp spec) (valid-type-p spec))
     spec)
   ;; Unknown?
   (t (error 'crisp-unknown-type-error :type-name spec))))

(defun analyze-return-type-from-spec (fn-spec)
  "Parses '(int int => int int)' and returns a list of types."
  (let ((arrow-pos (position '=> fn-spec)))
    (if arrow-pos
        (let ((return-types-list (nthcdr (1+ arrow-pos) fn-spec)))
          (if (null return-types-list)
              '(nil)
              (loop for type-spec in return-types-list
                    collect (cond
                             ((null type-spec) 'nil)
                             (t (parse-type-specifier type-spec))))))
        '(nil))))

(defun analyze-environment-from-spec (params fn-spec)
  "Builds the environment from the signature."
  (let ((arrow-pos (position '=> fn-spec)))
    (let ((param-type-specs (subseq fn-spec 0 (or arrow-pos (length fn-spec)))))
      (log:debug "Analyzing spec params: ~s, specs: ~s" params param-type-specs)
      (unless (= (length params) (length param-type-specs))
        (error 'crisp-signature-arity-error
          :expected (length param-type-specs)
          :inferred (length params)
          :source-location nil))
      (loop for p in params
            for ts in param-type-specs
            collect (list p (parse-type-specifier ts))))))


;; --- (type ...) Syntax Parsers (The Fallback) ---

(defun analyze-return-type-from-list (declarations)
  "Finds and returns the return-type(s) from a (return-type ...) decl."
  (let ((found (assoc 'return-type declarations)))
    (when found
          (let ((type-names (rest found)))
            ;; Special case for `(function ...)` syntax which is handled elsewhere
            (when (eq (first type-names) 'function)
                  (return-from analyze-return-type-from-list nil))
            (loop for type-name in type-names
                  collect (cond ((null type-name) 'nil)
                                ((valid-type-p type-name) type-name)
                                (t (error 'crisp-unknown-type-error :type-name type-name))))))))

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
                 (param-type-name (first (last type-decl))))
            (if (valid-type-p param-type-name)
                (mapcar #'(lambda (name) (list name param-type-name))
                  param-names)
                (error 'crisp-unknown-type-error :type-name param-type-name))))))


(defun get-promoted-type (type-a-name type-b-name)
  "Determines the result type of a binary operation, applying promotion rules."
  (if (eq type-a-name type-b-name)
      type-a-name
      (let ((type-a (gethash type-a-name *crisp-types*))
            (type-b (gethash type-b-name *crisp-types*)))
        (cond
         ;; Promotion within the same category (e.g., int -> long)
         ((and (eq (crisp-type-category type-a) (crisp-type-category type-b))
               (> (crisp-type-size type-b) (crisp-type-size type-a)))
           type-b-name)
         ((and (eq (crisp-type-category type-a) (crisp-type-category type-b))
               (> (crisp-type-size type-a) (crisp-type-size type-b)))
           type-a-name)
         ;; Promotion from any integer to float
         ((and (member (crisp-type-category type-a) '(:signed-int :unsigned-int))
               (eq (crisp-type-category type-b) :float))
           type-b-name)
         ((and (member (crisp-type-category type-b) '(:signed-int :unsigned-int))
               (eq (crisp-type-category type-a) :float))
           type-a-name)
         ;; No other implicit promotions allowed
         (t nil)))))

(defun analyze-add-expression (expr env location)
  "Analyzes a `(+ ...)` expression."
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2))))
         ;; Operators like '+' operate on single values. If the arguments are
         ;; function calls that return multiple values, we take the first one.
         (left-type (get-single-value-type left-node))
         (right-type (get-single-value-type right-node))
         (promoted-type (get-promoted-type left-type right-type)))

    (if promoted-type
        (let ((result-crisp-type (gethash promoted-type *crisp-types*)))
          ;; Ensure the resulting type is numeric and supports addition.
          (unless (and result-crisp-type (member (crisp-type-category result-crisp-type)
                                                 '(:signed-int :unsigned-int :float)))
            ;; If no promotion rule applies, it's a type error.
            (error 'crisp-type-error
              :message (format nil "Type mismatch for operator '+'. Cannot add ~a and ~a without explicit cast." left-type right-type)
              :source-location location))
          (make-semantic-add :type promoted-type :left-arg left-node :right-arg right-node :source-location location))
        (error 'crisp-type-error
          :message (format nil "Type mismatch for operator '+'. Cannot add ~a and ~a without explicit cast." left-type right-type)
          :source-location location))))

(defun analyze-sub-expression (expr env location)
  "Analyzes a `(- ...)` expression."
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2))))
         (left-type (get-single-value-type left-node))
         (right-type (get-single-value-type right-node))
         (promoted-type (get-promoted-type left-type right-type)))
    (if promoted-type
        (make-semantic-sub :type promoted-type :left-arg left-node :right-arg right-node :source-location location)
        (error 'crisp-type-error :message "Type mismatch for '-'" :source-location location))))

(defun analyze-mul-expression (expr env location)
  "Analyzes a `(* ...)` expression."
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2))))
         (left-type (get-single-value-type left-node))
         (right-type (get-single-value-type right-node))
         (promoted-type (get-promoted-type left-type right-type)))
    (if promoted-type
        (make-semantic-mul :type promoted-type :left-arg left-node :right-arg right-node :source-location location)
        (error 'crisp-type-error :message "Type mismatch for '*'" :source-location location))))

(defun analyze-div-expression (expr env location)
  "Analyzes a `(/ ...)` expression."
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2))))
         (left-type (get-single-value-type left-node))
         (right-type (get-single-value-type right-node))
         (promoted-type (get-promoted-type left-type right-type)))
    (if promoted-type
        (make-semantic-div :type promoted-type :left-arg left-node :right-arg right-node :source-location location)
        (error 'crisp-type-error :message "Type mismatch for '/'" :source-location location))))

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

(defun analyze-if-expression (expr env location)
  (let* ((cond-node (analyze-expression (second expr) env (append location '(1))))
         (then-node (analyze-expression (third expr) env (append location '(2))))
         (else-node (if (fourth expr) (analyze-expression (fourth expr) env (append location '(3))) nil)))
    (make-semantic-if :type (semantic-node-type then-node)
                      :condition-node cond-node
                      :then-node then-node
                      :else-node else-node
                      :source-location location)))

(defun analyze-when-expression (expr env location)
  (let ((cond-node (analyze-expression (second expr) env (append location '(1))))
        (body-node (analyze-progn-expression (cons 'progn (cddr expr)) env (append location '(2)))))
    (make-semantic-if :type 'void :condition-node cond-node :then-node body-node :else-node nil :source-location location)))

(defun analyze-unless-expression (expr env location)
  (let ((cond-node (analyze-expression (second expr) env (append location '(1))))
        (body-node (analyze-progn-expression (cons 'progn (cddr expr)) env (append location '(2)))))
    (make-semantic-if :type 'void :condition-node cond-node :then-node nil :else-node body-node :source-location location)))

(defun analyze-set!-expression (expr env location)
  (let* ((var-name (second expr))
         (val-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-set! :name var-name :value-node val-node :source-location location)))

(defun analyze-aref-expression (expr env location)
  (let* ((array-node (analyze-expression (second expr) env (append location '(1))))
         (index-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-aref :type (if (listp (semantic-node-type array-node)) (second (semantic-node-type array-node)) 'int)
                        :array-node array-node
                        :index-node index-node
                        :source-location location)))

(defun analyze-inc!-expression (expr env location)
  (error "inc! not implemented"))
(defun analyze-dec!-expression (expr env location)
  (error "dec! not implemented"))
(defun analyze-atomic-add!-expression (expr env location)
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
          '(:storage-ptr :storage-size)))

  (let ((inner-type (cadr expr)))
    (unless (gethash inner-type *crisp-types*)
      (error 'crisp-unknown-type-error :type-name inner-type :source-location location))
    (make-semantic-literal :value-type (list 'cell inner-type)
                           :value nil ; No real value yet
                           :source-location location)))

(defun analyze-progn-expression (expr env location)
  "Analyzes a `(progn ...)` expression."
  (let ((body (cdr expr))
        (last-node nil))
    (dolist (form body)
      (setf last-node (analyze-expression form env location)))
    ;; Return the last node, or a void literal if empty
    (or last-node
        (make-semantic-literal :value-type 'void :value nil :source-location location))))

(defun analyze-nested-def-function (expr env location)
  "Analyzes a nested `(def-function ...)` expression (e.g. from a template)."
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
    ;; The body is typically a PROGN or a single form.
    ;; We analyze it recursively.
    (analyze-expression body env location)))

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
                  (let* ((binding-vars (butlast binding 1))
                         (init-form (first (last binding)))
                         (init-node (analyze-expression init-form current-env (append location '(1) (list i) (list (length binding-vars)))))
                         (init-node-types (semantic-node-type init-node)))

                    (cond
                     ;; Case 1: Single variable binding, e.g., (let ((z 13)))
                     ((= (length binding-vars) 1)
                       (let* ((var-name (first binding-vars))
                              ;; For a single binding, we implicitly take the first return value's type.
                              (var-type (get-single-value-type init-node)))
                         (push (cons var-name init-node) bindings-list)
                         (setf current-env (cons (list var-name var-type) current-env))))

                     ;; Case 2: Multiple variable binding, e.g., (let ((x y z (m-v-r a))))
                     ((> (length binding-vars) 1)
                       (unless (listp init-node-types)
                         (error "Cannot destructure a single-value return into multiple variables at ~a" (semantic-node-source-location init-node)))
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
                                 (setf current-env (cons (list var-name var-type) current-env)))))
                     (t (error "Malformed let binding: ~a" binding)))))
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
         (return-types (mapcar #'semantic-node-type value-nodes)))
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
           ;; For truncate, floor, etc., the target is always 'int' for now.
           ;; This will need to be expanded if we support (truncate-to-long ...).
           ((member op '(truncate floor ceil round)) 'int)
           (t (error "Internal compiler error: analyze-cast-expression called with invalid operator ~a" op))))
         (target-crisp-type (gethash target-type-name *crisp-types*))
         (arg-node (analyze-expression arg-form env (append location '(1)))))

    (unless target-crisp-type
      (error 'crisp-unknown-type-error :type-name target-type-name))

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


(defun types-compatible-p (arg-type param-type)
  "Checks if an argument type is compatible with a parameter type."
  (or (equal arg-type param-type)
      (and (listp arg-type) (eq (first arg-type) :function-literal)
           (listp param-type) (eq (first param-type) :function-type)
           ;; Verify signature match
           (let* ((literal-name (second arg-type))
                  (expected-ret (second param-type))
                  (expected-params (getf (cddr param-type) :params))
                  (sigs (gethash literal-name *function-table*)))
             ;; Find ANY signature of literal-name that matches the expected type
             (some (lambda (sig)
                     (and (equal (function-signature-return-types sig) expected-ret)
                          (equal (function-signature-parameters sig) expected-params)))
                 sigs)))))

(defun types-list-compatible-p (arg-types param-types)
  "Checks if a list of argument types is compatible with a list of parameter types."
  (and (= (length arg-types) (length param-types))
       (every #'types-compatible-p arg-types param-types)))

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
           (signatures (gethash op *function-table*))
           (signature (find-if (lambda (sig)
                                 (types-list-compatible-p explicit-arg-types (function-signature-parameters sig)))
                          signatures)))      (unless signature
        (when *template-instantiator-fn*
              (loop repeat 3 until signature do
                    (if (funcall *template-instantiator-fn* op explicit-arg-types
                          (lambda (form location)
                            (compile-toplevel-form form location *current-module* *current-builder* *current-di-builder* *current-di-compile-unit* *current-location-map*)))
                        (progn
                          (setf signatures (gethash op *function-table*))
                          (setf signature (find-if (lambda (sig)
                                                     (types-list-compatible-p explicit-arg-types (function-signature-parameters sig)))
                                              signatures)))
                        (return))))

      (unless signature
        (error "No matching function overload found for '~a' with argument types ~a." op explicit-arg-types)))

    (let ((final-arg-nodes
           (if implicit-args-required
               (let ((implicit-arg-nodes
                      (loop for arg-name in '(__storage_ptr __storage_size)
                            collect (let ((found (assoc arg-name env)))
                                      (if found
                                          (make-semantic-var-read :name arg-name :type (second found) :source-location location)
                                          (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                            *current-compiling-function* arg-name))))))
                 (append implicit-arg-nodes explicit-arg-nodes))
               explicit-arg-nodes)))

      (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
        (error 'crisp-signature-arity-error
          :expected (length (function-signature-parameters signature))
          :inferred (length explicit-arg-types)
          :source-location location))

      (make-semantic-call :name op
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

(defun analyze-body-expressions (body-list env location)
  "Recursively analyzes a list of expressions."
  (loop for expr in body-list
        for i from 0
        collect (analyze-expression expr env (append location (list i)))))

(defun analyze-expression (expr env location)
  "Recursively analyzes a *single* expression."
  (log:debug "analyze-expression expr: ~s location: ~s" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
        (error 'crisp-unsupported-form-error :form expr :source-location location))

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
    (semantic-set! (semantic-node-type (semantic-set!-value-node node)))
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))))

(defun semantic-node-source-location (node)
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))))

;; --- Helper to get the type from a node expected to be a single value ---
(defun get-single-value-type (node)
  "Returns the type of a semantic node, assuming a single-value context.
  If the node's type is a list (e.g., from a multi-value function call),
  this returns the first type in the list. Otherwise, it returns the type as-is."
  (let ((type (semantic-node-type node)))
    ;; If the type is a list, we must check if it's a single parameterized type
    ;; (like '(cell int)') before assuming it's a list of multiple return values.
    (if (and (listp type) (not (valid-type-p type)))
        (first type) ; It's a multi-value list, take the first.
        type))) ; It's a single value (or a single parameterized type), return as-is.

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
         (let* ((form-with-location (append crisp-form (list :source-location ''(0))))
                (expanded-form (macroexpand-1 form-with-location))
                (semantic-fn (eval expanded-form)))
           (generate-llvm-ir semantic-fn module builder di-builder di-compile-unit location-map))
         (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
      ;; Cleanup.
      (when di-builder (llvm-di-builder-finalize di-builder))
      (when di-builder (llvm-dispose-di-builder di-builder))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))
  
