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

(defvar *template-registry* (make-hash-table)
        "Maps template names (symbols) to a LIST of template-data structs.
This supports overloading templates by arity or other factors.")

(defvar *instantiated-templates* (make-hash-table :test 'equal)
        "Tracks which specializations have already been generated.")

(defvar *side-channel-originators* '(make-scratch-cell)
        "A list of function names that trigger the implicit side-channel argument passing mechanism.")

(defvar *originator-functions* nil
        "A hash table containing the names of all functions that directly use a side-channel originator.")

(defvar *implicit-arg-map* (make-hash-table)
        "A hash table mapping function names to the implicit side-channel arguments they require.")

(defvar *crisp-types* (make-hash-table)
        "A hash table mapping type names (symbols) to CRISP-TYPE structs.")

(defvar *crisp-structs* (make-hash-table)
        "A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.")


(defstruct enumeration-def
  name
  members ; Alist of (keyword . integer)
)

(defvar *crisp-enums* (make-hash-table :test 'eq))


(defvar *current-compiling-function* nil)
(defvar *current-module* nil)
(defvar *current-builder* nil)
(defvar *current-di-builder* nil)
(defvar *current-di-compile-unit* nil)
(defvar *current-location-map* nil)
(defvar *allow-nested-def-function* nil)


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
           (double ,#'llvm-double-type 64 :float)
           ;; Void
           (void ,#'llvm-void-type 0 :void))))
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

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

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


(defun excluded-template-base-type-p (base-type)
  "Returns true if the base-type should be excluded from struct template processing.
   Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations."
  (member base-type '(function quote common-lisp:function common-lisp:quote)))

(defun mangle-template-struct-name (name params)
  "Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT"
  (log:debug "mangle-template-struct-name: name=~s (type=~a) params=~s" name (type-of name) params)
  (unless name (return-from mangle-template-struct-name nil))
  (intern (format nil "~a_~{~a~^_~}" name params) (symbol-package name)))

(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, handling template struct canonicalization."
  (log:debug "types-equivalent-p: ~s vs ~s" t1 t2)
  (cond
   ((equal t1 t2) t)
   ;; Handle parameterized struct (POINT FLOAT) vs mangled name POINT_FLOAT equivalence
   ((and (consp t1) (symbolp t2))
     (let ((base-type (first t1))
           (params (rest t1)))
       (if (and (symbolp base-type)
                (not (excluded-template-base-type-p base-type)))
           (progn
            ;; Trigger auto-instantiation if template exists
            (when (gethash base-type *template-registry*)
                  (let ((instantiated-form
                         (funcall *template-instantiator-fn* base-type params
                           (lambda (form location)
                             (if (boundp '*current-module*)
                                 (compile-toplevel-form form location
                                                        *current-module*
                                                        *current-builder*
                                                        *current-di-builder*
                                                        *current-di-compile-unit*
                                                        *current-location-map*)
                                 (eval form))))))
                    instantiated-form
                    t))

            ;; Now check mangled name
            (let ((mangled (mangle-template-struct-name base-type params)))
              (cond
               ;; If t2 is the mangled name, they are equivalent
               ((eq mangled t2) t)
               ;; If t2 is also a struct, check if it maps to mangled?
               ;; Usually t2 is the resolved type symbol.
               (t nil))))
           nil)))
   ((and (symbolp t1) (consp t2))
     (types-equivalent-p t2 t1))
   (t nil)))

(defun type-lists-equivalent-p (l1 l2)
  (and (= (length l1) (length l2))
       (every #'types-equivalent-p l1 l2)))

(defun register-struct-definition (name members)
  "Registers a struct definition in the global registry."
  (multiple-value-bind (padded-members total-size)
      (compute-std140-layout members)
    (let ((indices (make-hash-table :test #'eq)))
      (loop for m in padded-members
            for i from 0
            do (setf (gethash (car m) indices) i))
      (setf (gethash name *crisp-structs*)
        (make-crisp-struct-definition
         :name name
         :members members
         :padded-members padded-members
         :field-indices indices
         :total-size total-size))

      ;; Register as a valid Crisp type for type checking
      (setf (gethash name *crisp-types*)
        (make-crisp-type
         :name name
         :llvm-type-fn (lambda () (ensure-struct-llvm-type name))
         :size (* total-size 8)
         :category :struct)))))

(defun parse-struct-member-spec (spec)
  "Parses a struct member specification.
   Supports (name type) and (name type :c-t [value])."
  (cond
   ;; (name type)
   ((and (listp spec) (= (length spec) 2))
     spec)
   ;; (name type :c-t [value])
   ((and (listp spec) (>= (length spec) 3) (eq (third spec) :c-t))
     spec)
   (t (error "Invalid struct member spec: ~a" spec))))


(defun compute-std140-layout (members)
  "Takes a list of (name type) members.
  Returns a list of:
    - Expanded members with `_pad` fields inserted.
    - Total struct size (padded to 16 bytes).
  
  Returns (values expanded-members total-size)"
  ;; Filter out compile-time properties (marked with :c-t)
  (let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
         (current-offset 0)
         (expanded-members '()))
    (dolist (member runtime-members)
      (let* ((name (first member))
             (type (second member))
             (alignment (get-std140-base-alignment type))
             (size (get-std140-size type))
             (padding (calculate-std140-padding current-offset alignment)))
        (declare (ignore name))

        ;; Insert padding if needed
        (when (> padding 0)
              (let ((pad-remaining padding)
                    (pad-idx 0)
                    (pad-current-offset current-offset))
                (loop while (> pad-remaining 0) do
                        (let* ((pad-member
                                (cond
                                 ;; Only use larger types if we are aligned for them!
                                 ((and (>= pad-remaining 8) (zerop (mod pad-current-offset 8))) (list 'double 8))
                                 ((and (>= pad-remaining 4) (zerop (mod pad-current-offset 4))) (list 'int 4))
                                 ((and (>= pad-remaining 2) (zerop (mod pad-current-offset 2))) (list 'short 2))
                                 (t (list 'char 1))))
                               (pad-type (first pad-member))
                               (pad-size (second pad-member))
                               (pad-name (intern (format nil "_PAD_~a_~a" current-offset pad-idx))))

                          (push (list pad-name pad-type) expanded-members)
                          (decf pad-remaining pad-size)
                          (incf pad-current-offset pad-size)
                          (incf pad-idx))))
              (incf current-offset padding))

        ;; Add the actual member
        (push member expanded-members)
        (incf current-offset size)))

    ;; Final structure padding to multiple of 16 (vec4 alignment)
    (let ((final-padding (calculate-std140-padding current-offset 16)))
      (when (> final-padding 0)
            (let ((pad-remaining final-padding)
                  (pad-idx 0)
                  (pad-current-offset current-offset))
              (loop while (> pad-remaining 0) do
                      (let* ((pad-member
                              (cond
                               ((and (>= pad-remaining 8) (zerop (mod pad-current-offset 8))) (list 'double 8))
                               ((and (>= pad-remaining 4) (zerop (mod pad-current-offset 4))) (list 'int 4))
                               ((and (>= pad-remaining 2) (zerop (mod pad-current-offset 2))) (list 'short 2))
                               (t (list 'char 1))))
                             (pad-type (first pad-member))
                             (pad-size (second pad-member))
                             (pad-name (intern (format nil "_PAD_EA_~a" pad-idx))))

                        (push (list pad-name pad-type) expanded-members)
                        (decf pad-remaining pad-size)
                        (incf pad-current-offset pad-size)
                        (incf pad-idx)))))
      (incf current-offset final-padding))

    (values (nreverse expanded-members) current-offset)))

;; Keep helper functions separate
(defun validate-and-reorder-struct-args (struct-name defined-members args)
  "Validates and reorders keyword arguments for a struct constructor macro."
  ;; 0. Filter out :c-t members from validation - they are not constructor args!
  ;; Or should they be accepted but ignored? 
  ;; Since they are compile-time constants fixed in the struct def, they should NOT be passed.
  (let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) defined-members))
         (processed-args (make-hash-table :test 'eq))
         (ordered-values '()))

    ;; 1. Parse into a hash table
    (let ((ptr args))
      (loop while ptr do
              (let ((key (first ptr))
                    (val (second ptr)))
                (unless (keywordp key)
                  (error "Struct constructor for ~a requires keyword arguments. Found: ~s" struct-name key))
                (unless (second ptr)
                  (error "Struct constructor for ~a has missing value for key: ~s" struct-name key))
                (when (gethash key processed-args)
                      (error "Struct constructor for ~a has duplicate key: ~s" struct-name key))

                (setf (gethash key processed-args) val)
                (setf ptr (cddr ptr)))))

    ;; 2. Validate and Reorder
    (loop for (member-name member-type) in runtime-members do
            (let* ((kw (intern (symbol-name member-name) :keyword))
                   (val (gethash kw processed-args)))
              (unless val
                (error "Struct constructor for ~a missing required argument: ~s" struct-name kw))
              (push val ordered-values)))

    ;; 3. Check for unknown keys (against runtime members only!)
    (maphash (lambda (k v)
               (declare (ignore v))
               (unless (find k runtime-members :key (lambda (m) (intern (symbol-name (first m)) :keyword)))
                 (error "Struct constructor for ~a has unknown or compile-time-only argument: ~s" struct-name k)))
             processed-args)

    (nreverse ordered-values)))

(defmacro with-struct-accessors (struct-type bindings &body body)
  "Iterates over the members of a struct type, binding accessor symbols to the provided variables.
   Bindings: (aos-var [soa-var] [:access type])
   Returns a PROGN containing the expanded body forms."
  (let* ((aos-var (first bindings))
         (rest-bindings (rest bindings))
         ;; Manual parsing of optional SOA-VAR and keys
         (soa-var (if (and rest-bindings (not (keywordp (first rest-bindings))))
                      (pop rest-bindings)
                      nil))
         (access (let ((k (getf rest-bindings :access)))
                   (if k k :public)))
         (struct-def (gethash struct-type *crisp-structs*)))

    (unless struct-def
      (error "Unknown struct type '~a' in with-struct-accessors." struct-type))

    (let ((forms '()))
      (dolist (member (crisp-struct-definition-members struct-def))
        (let* ((member-name (first member))
               (aos-accessor-name
                (ecase access
                  (:public (intern (format nil "~a~~" member-name)))
                  (:raw (intern (format nil "~~~a~~" member-name)))))
               (soa-accessor-name (intern (format nil "~a~~" member-name))))

          (let ((expanded-body
                 (mapcar (lambda (form)
                           (let ((f (subst aos-accessor-name aos-var form)))
                             (if soa-var
                                 (subst soa-accessor-name soa-var f)
                                 f)))
                     body)))
            (setf forms (append forms expanded-body)))))

      `(progn ,@forms))))

(defmacro def-struct (name &rest members)
  "Defines a new Crisp struct type."
  (let* ((parsed-members (mapcar #'parse-struct-member-spec members))
         (constructor-name (intern (format nil "MAKE-~a" name))))
    ;; Register at macro-expansion time (for visibility to subsequent code)
    (register-struct-definition name parsed-members)
    ;; Emit code to register using eval-when, AND the constructor MACRO
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-struct-definition ',name ',parsed-members))

      (defmacro ,constructor-name (&rest args)
        (let ((reordered (validate-and-reorder-struct-args ',name ',parsed-members args)))
          `(%construct-struct ,',name ,@reordered)))

      ,@(let ((runtime-index 0))
          (loop for member-spec in parsed-members
                collect
                  (let* ((member-name (first member-spec))
                         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
                         (value (when is-ct (fourth member-spec))) ;; (name type :c-t value)
                         (accessor-name (intern (format nil "~a~~" member-name))))
                    (if is-ct
                        ;; Generate Compile-Time Constant Accessor Macro
                        `(defmacro ,accessor-name (obj)
                           (declare (ignore obj))
                           ;; If a value is provided, return it as a constant.
                           (if ',value
                               '',value
                               ;; Otherwise error? Or return nil? User should provide value.
                               (error "Compile-time struct member ~a accessed but has no constant value defined." ',member-name)))
                        ;; Generate Runtime Accessor Function
                        (let ((idx runtime-index))
                          (incf runtime-index)
                          `(def-function ,accessor-name ((obj ,name))
                                         (return (%extract-struct-member obj ,idx))))))))
      ,@(let ((runtime-index 0))
          (loop for member-spec in parsed-members
                  unless (and (consp member-spec) (eq (third member-spec) :c-t))
                collect
                  (let* ((member-name (first member-spec))
                         (raw-accessor-name (intern (format nil "~~~a~~" member-name)))
                         (idx runtime-index))
                    (incf runtime-index)
                    `(def-function ,raw-accessor-name ((obj ,name))
                                   (declare (crisp-system-generated))
                                   (return (%extract-struct-member obj ,idx)))))))))

(defmacro def-setter (name args &body body)
  "Defines a setter function (which is just a def-function but semantically intended for use with set!).
   The return type is implicitly nil/void. We append (return) to ensure this."
  `(def-function ,name ,args ,@body (return)))

;; INTERNAL TO COMPILER
;; ====================

(define-condition crisp-compiler-error (error)
    ((source-location :initarg :source-location :reader error-source-location
                      :initform nil)
     (message :initarg :message :reader error-message :initform nil))
  (:report (lambda (condition stream)
             (if (error-message condition)
                 (format stream "~a~@[ at ~a~]." (error-message condition) (error-source-location condition))
                 (format stream "A Crisp compilation error occurred~@[ at ~a~]."
                   (error-source-location condition))))))

(define-condition crisp-type-error (crisp-compiler-error)
    ((message :initarg :message :initform "Type mismatch!" :reader type-error-message)
     (expected :initarg :expected :reader type-error-expected :initform nil)
     (inferred :initarg :inferred :reader type-error-inferred :initform nil))
  (:report (lambda (condition stream)
             ;; If we have specific expected/inferred types, use the standard format.
             ;; Otherwise, just print the message.
             (if (or (type-error-expected condition)
                     (type-error-inferred condition))
                 (format stream "~a Expected ~a but inferred ~a."
                   (type-error-message condition)
                   (type-error-expected condition)
                   (type-error-inferred condition))
                 (format stream "~a" (type-error-message condition))))))

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
;; Std140 Layout (GPU Alignment)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
  For scalars, N is the size of the scalar.
  For vectors, it is 2N or 4N.
  For arrays/structs, it is rounded up to vec4 alignment (16)."
  (cond
   ((or (eq type-spec 'float) (eq type-spec 'int) (eq type-spec 'uint)) 4)
   ((or (eq type-spec 'double) (eq type-spec 'long) (eq type-spec 'ulong)) 8)
   ((or (eq type-spec 'char) (eq type-spec 'uchar)) 1)
   ((or (eq type-spec 'short) (eq type-spec 'ushort) (eq type-spec 'half) (eq type-spec 'bfloat16)) 2)
   ;; TODO: Handle vectors here (will need vector support first)
   ((or (eq type-spec 'bool)) 4) ;; booleans are 4 bytes in std140
   ;; Structs align to 16 bytes (vec4)
   ((gethash type-spec *crisp-structs*) 16)
   (t (error "Unknown type for alignment: ~a" type-spec))))


(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type. Does not include padding for alignment context."
  (cond
   ((or (eq type-spec 'float) (eq type-spec 'int) (eq type-spec 'uint)) 4)
   ((or (eq type-spec 'double) (eq type-spec 'long) (eq type-spec 'ulong)) 8)
   ((or (eq type-spec 'char) (eq type-spec 'uchar)) 1)
   ((or (eq type-spec 'short) (eq type-spec 'ushort) (eq type-spec 'half) (eq type-spec 'bfloat16)) 2)
   ((eq type-spec 'bool) 4)
   ;; Structs - Retrieve cached size
   ((gethash type-spec *crisp-structs*)
     (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
   (t (error "Unknown type for size: ~a" type-spec))))

(defun calculate-std140-padding (current-offset alignment)
  "Calculates padding needed to reach the next alignment boundary."
  (let ((remainder (mod current-offset alignment)))
    (if (zerop remainder)
        0
        (- alignment remainder))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Type System Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun valid-basic-type-p (type-spec)
  "Checks if type-spec is a valid basic symbol type (built-in, struct, or function reference)."
  (and (symbolp type-spec)
       (or (gethash type-spec *crisp-types*)
           (gethash type-spec *crisp-structs*)
           (gethash type-spec *function-table*))))

(defun valid-function-type-p (type-spec)
  "Checks if type-spec is a valid function literal or descriptor."
  (or (and (consp type-spec) (eq (first type-spec) :function-literal)
           (= (length type-spec) 2) (symbolp (second type-spec)))
      (and (consp type-spec) (eq (first type-spec) :function-type))))

(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, etc)."
  (when (consp type-spec)
        (let ((base-type (first type-spec))
              (params (rest type-spec)))
          (cond
           ((not (symbolp base-type)) nil) ;; Base type must be a symbol
           ((excluded-template-base-type-p base-type) nil)
           ((and (string-equal (symbol-name base-type) "CELL")
                 (= (length params) 1)
                 (gethash (first params) *crisp-types*))
             t)
           ;; Generic Templated Structs: (POINT FLOAT) -> POINT_FLOAT
           ((symbolp base-type)
             (let ((mangled-name (mangle-template-struct-name base-type params)))
               (or (gethash mangled-name *crisp-structs*)
                   ;; Attempt Auto-Instantiation if it's a known template
                   (when (gethash base-type *template-registry*)
                         (log:info "Auto-instantiating struct template: ~a with params ~a" base-type params)
                         (if (and (boundp '*template-instantiator-fn*) *template-instantiator-fn*)
                             (progn
                              (funcall *template-instantiator-fn* base-type params
                                (lambda (form loc)
                                  (declare (ignore loc))
                                  (if (and (boundp '*current-module*) *current-module*)
                                      (compile-toplevel-form form nil
                                                             *current-module*
                                                             *current-builder*
                                                             *current-di-builder*
                                                             *current-di-compile-unit*
                                                             *current-location-map*)
                                      (eval form))))
                              (gethash mangled-name *crisp-structs*))
                             (progn (log:warn "Template instantiator not bound/found") nil))))))
           (t nil)))))

(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
   Handles simple types, parameterized types, and function literals/types."
  (or (valid-basic-type-p type-spec)
      (valid-function-type-p type-spec)
      (valid-parameterized-type-p type-spec)))

(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference."
  (cond
   ;; Built-in Scalar
   ((and (symbolp type-spec) (gethash type-spec *crisp-types*))
     (funcall (crisp-type-llvm-type-fn (gethash type-spec *crisp-types*))))

   ;; Struct
   ((and (symbolp type-spec) (gethash type-spec *crisp-structs*))
     (ensure-struct-llvm-type type-spec))

   ;; Pointer / Cell (simple version)
   ((and (listp type-spec) (eq (first type-spec) 'cell))
     ;; For now, treats cell as generic pointer.
     ;; ideally this should match runtime struct layout
     (llvm-int8-ptr-type (llvm-void-type) 0))

   (t (error "Cannot resolve type to LLVM: ~a" type-spec))))


(defun ensure-struct-llvm-type (name)
  "Ensures the LLVM struct type exists for the given struct name.
   Handles forward declarations and recursion."
  (let ((def (gethash name *crisp-structs*)))
    (unless def
      (error "Unknown struct type: ~a" name))

    ;; Return cached type if available
    (when (crisp-struct-definition-llvm-type def)
          (return-from ensure-struct-llvm-type (crisp-struct-definition-llvm-type def)))

    ;; Create the named struct (opaque first) to handle recursion
    (let* ((ctx (llvm-get-module-context *current-module*))
           (struct-type (llvm-struct-create-named ctx (symbol-name name))))
      ;; CACHE IT IMMEDIATELY
      (setf (crisp-struct-definition-llvm-type def) struct-type)

      (let ((element-types '()))
        (dolist (member-spec (crisp-struct-definition-padded-members def))
          (log:debug "Member-spec: ~a" member-spec)
          (let* ((type-name (second member-spec))
                 (resolved-type (resolve-type-to-llvm type-name)))
            (log:info "Member ~a (type ~a) resolved to LLVM type: ~a" (first member-spec) type-name resolved-type)
            (unless resolved-type
              (error "Failed to resolve type ~a for member ~a" type-name (first member-spec)))
            (push resolved-type element-types)))

        ;; Set the body
        (let ((types-array (cffi:foreign-alloc :pointer :count (length element-types))))
          (loop for type in (reverse element-types)
                for i from 0
                do (setf (cffi:mem-aref types-array :pointer i) type))
          (llvm-struct-set-body struct-type types-array (length element-types) nil) ; packed=nil
          (cffi:foreign-free types-array)))

      struct-type)))

(defun analyze-function-literal (expr env location)
  "Analyzes a (function name) form, e.g., #'foo."
  (declare (ignore env))
  (let ((fn-name (second expr)))
    ;; Check if the function exists (simplistic check for now)
    (unless (or (fboundp fn-name) (gethash fn-name *function-table*))
      (log:warn "Function literal ~a refers to unknown function (at compile time)." fn-name))

    (make-semantic-literal
     :value-type `(:function-literal ,fn-name)
     :value fn-name
     :source-location location)))
