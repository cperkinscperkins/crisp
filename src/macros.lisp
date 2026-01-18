;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/macros.lisp
(in-package :crisp.compiler)

(log:info "Loading macros.lisp in package: ~a. RETURN symbol package: ~a" *package* (symbol-package 'return))

(defmacro let (bindings &body body)
  "A unified 'let' for Crisp that works in both Kernels and Macros.
   - It is SEQUENTIAL (like CL:LET*).
   - It supports Multi-Value-Binding (MVB) destructuring.
   
   Example:
     (let ((a 1)
           (b 2)
           ((q r) (floor 10 3)))
       (+ a b q r))

   This macro expands into a nest of CL:LET* and CL:MULTIPLE-VALUE-BIND
   forms, suitable for execution in the Lisp host (macros/tests).
   
   When compiling Kernels, the Crisp Compiler intercepts the 'let' symbol
   directly and uses its own semantic analyzer, ignoring this macro."

  (cl:cond
    ;; Base Case: No bindings left -> just the body (in a progn)
    ((null bindings)
     `(progn ,@body))

    ;; Recursive Case: Process one binding
    (t
     (cl:let* ((binding (first bindings))
               (rest-bindings (rest bindings)))
       (cl:cond
         ;; Case 1: Explicit Destructuring -> ((a b) (values 1 2))
         ((and (listp binding) (listp (first binding)))
          (cl:let ((vars (first binding))
                   (val-form (second binding)))
            `(multiple-value-bind ,vars ,val-form
               (let ,rest-bindings ,@body))))

         ;; Case 2: Flattened Destructuring -> (a b (values 1 2))
         ((and (listp binding) (> (length binding) 2))
          (cl:let* ((vars (butlast binding))
                    (val-form (first (last binding))))
            `(multiple-value-bind ,vars ,val-form
               (let ,rest-bindings ,@body))))

         ;; Case 3: Standard Binding -> (a 1) or (a) or a
         (t
          ;; Normalize 'a' to '(a nil)' and '(a)' to '(a nil)' if needed, 
          ;; but CL:LET* handles (a) and a natively.
          `(cl:let* (,binding)
             (let ,rest-bindings ,@body))))))))
;; --- Branching Macros ---

(defmacro when (test &body body)
  `(if ,test (progn ,@body)))

(defmacro unless (test &body body)
  `(if (not ,test) (progn ,@body)))

(defmacro cond (&rest clauses)
  (if (null clauses)
      nil
      (let* ((clause (first clauses))
             (rest (rest clauses))
             (test (first clause))
             (forms (rest clause)))
        (if (or (eq test 'else) (eq test t))
            `(progn ,@forms)
            `(if ,test
                 (progn ,@forms)
                 (cond ,@rest))))))

(defmacro return (&optional value)
  "Crisp's special RETURN form. Expands to an explicit-return node."
  ;; This macro is intercepted by the semantic analyzer.
  ;; It should NOT expand to CL:RETURN-FROM.
  ;; It is processed directly by analyze-expression.
  `(explicit-return ,value))

(defmacro if+ (test then &optional else)
  "Compile-time conditional. Evaluates TEST at macro-expansion time.
   Errors if TEST cannot be evaluated (e.g. relies on runtime values)."
  (cl:let ((val (handler-case (eval test)
                  (error (e)
                    (error "IF+ condition failed to evaluate at compile time: ~s.~%Error: ~a" test e)))))
    (if val
        then
        else)))

;; --- Compile-Time Utilities ---

(defun compiler-no-op ()
  "A no-op function that returns no values. 
   Used as the expansion target for compile-time macros when evaluated in the host environment."
  (values))

(defmacro c-t-output (&rest args)
  "Compile-Time Output. Evaluates arguments at macro-expansion time and prints them."
  (let ((output-string
         (with-output-to-string (s)
           (dolist (arg args)
             (let ((val (eval arg)))
               (format s "~a " val))))))
    (format *standard-output* "~&~a~%" output-string)
    ;; Return a no-op form for the compiler to process (and ignore)
    `(compiler-no-op)))


;; Core Language Macros
;; ====================

(defmacro def-function (name params &rest body-and-location)
  "Defines a new, thread-level Crisp function."
  (when (string-equal (symbol-name name) "~REF~")
        (error 'crisp-illegal-overload-error :name name))
  ;; Find the position of our injected :source-location keyword.
  (let* ((loc-pos (position :source-location body-and-location))
         ;; The source location is the value right after the keyword.
         (source-location (when loc-pos (nth (1+ loc-pos) body-and-location)))
         ;; The "real" body is everything before the keyword.
         (body (if loc-pos (subseq body-and-location 0 loc-pos) body-and-location))
         (declarations (loop for form in body
                             while (and (listp form) (eq (car form) 'declare))
                               append (rest form)))
         (is-system (member '(crisp-system-generated) declarations :test #'equal)))

    (let ((name-str (symbol-name name)))
      (when (and (not is-system)
                 (or (string-equal name-str "~REF~")
                     (and (> (length name-str) 2)
                          (cl:char= (cl:char name-str 0) #\~)
                          (cl:char= (cl:char name-str (1- (length name-str))) #\~))))
            (error 'crisp-illegal-overload-error :name name)))

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

;; Helper for disambiguation (Pass 1 relaxation makes valid-type-p too permissive for symbols)
(defun strict-valid-type-p (spec)
  (cond
   ((symbolp spec)
     (or (gethash spec *crisp-types*)
         (gethash spec *crisp-structs*)
         (gethash spec *crisp-enums*)
         (gethash spec *crisp-type-aliases*)
         (gethash spec *crisp-template-aliases*)
         (and (boundp '*pending-struct-definitions*)
              (find spec *pending-struct-definitions* :key #'first))))
   (t (valid-type-p spec))))

(defmacro def-kernel-exact (name params &rest body)
  "Defines a GPU Kernel with exact ABI control (Raw Scalars).
   - Name must be valid C identifier (no dashes).
   - No implicit arguments or marshalling by the compiler.
   - Return type is implicitly NIL (void)."

  ;; 1. Validate C-Style Name
  (let ((name-str (symbol-name name)))
    (when (find #\- name-str)
          (error "Invalid Kernel Name '~a': def-kernel-exact requires C-style identifiers (no dashes)." name)))

  (when (or (member '&optional params) (member '&key params))
        (error "Kernels (def-kernel/def-kernel-exact) do not support &optional or &key parameters."))

  ;; 2. Validate Parameter Types (No Storage Handles)
  (let* ((declare-forms (loop for f in body while (and (listp f) (eq (car f) 'declare)) collect f))
         (declarations (loop for d in declare-forms append (rest d)))
         (type-map (make-hash-table :test 'eq)))

    ;; 2.1 Parse (type ...) declarations
    (loop for d in declarations
            when (and (consp d) (eq (car d) 'type))
          do (let* ((args (rest d))
                    (first-arg (first args))
                    (last-arg (car (last args))))
               (cond
                ;; Disambiguate using strict check first
                ((strict-valid-type-p first-arg)
                  (dolist (v (rest args)) (setf (gethash v type-map) first-arg)))
                ((strict-valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg)))
                ;; Fallback to relaxed check if neither is strictly known (e.g. forward ref)
                ((valid-type-p first-arg)
                  (dolist (v (rest args)) (setf (gethash v type-map) first-arg)))
                ((valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg))))))

    ;; 2.2 Parse (function ...) or #'(...) signatures
    (let ((sig (find-if (lambda (d) (or (eq (car d) 'function) (eq (car d) 'common-lisp:function))) declarations)))
      (when sig
            ;; (function (args...) => ret)
            (let* ((spec (second sig))
                   (arrow-pos (position '=> spec))
                   (arg-types (subseq spec 0 (or arrow-pos (length spec)))))
              (loop for p in params
                    for t-spec in arg-types
                    do (setf (gethash p type-map) t-spec)))))

    ;; 2.3 Check against storage handles
    (dolist (p params)
      (let ((t-spec (gethash p type-map)))
        (when (and t-spec (%storage-handle-type-p t-spec))
              (error "def-kernel-exact parameter '~a' cannot be a storage handle type (~a). Use def-kernel for implicit marshalling or pass raw pointers/sizes." p t-spec)))))

  ;; 3. Expand to def-function with entry-point
  `(progn
    (eval-when (:compile-toplevel :load-toplevel :execute)
      (pushnew ',name crisp.compiler::*compiled-kernels*))
    (def-function ,name ,params
                  (declare (entry-point))
                  ,@body
                  (return))))

(defun %storage-handle-type-p (type-spec)
  "Returns T if the type-spec refers to a storage handle (cell, tensor, etc.)."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (let ((base (if (consp canonical) (first canonical) canonical)))
      (and (symbolp base)
           (member (symbol-name base) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal)))))

(defun %resolve-alias-strict (spec)
  (%resolve-alias-strict-checked spec nil))

(defun %resolve-alias-strict-checked (spec seen)
  (if (member spec seen :test #'equal)
      (error "Recursive type alias detected during macro expansion: ~a" spec)
      (let ((base (if (consp spec) (first spec) spec))
            (args (if (consp spec) (rest spec) nil))
            (new-seen (cons spec seen)))
        (if (symbolp base)
            (let ((alias-def (gethash base *crisp-template-aliases*)))
              (if alias-def
                  (let ((params (car alias-def))
                        (type-spec (cdr alias-def)))
                    (if params
                        (let* ((arity (length params))
                               (required-args (subseq args 0 (min (length args) arity)))
                               (rest-args (subseq args (length required-args)))
                               (substitutions (pairlis params required-args)))
                          (let ((expanded (sublis substitutions type-spec)))
                            (if (and rest-args (consp expanded))
                                (%resolve-alias-strict-checked (append expanded rest-args) new-seen)
                                (%resolve-alias-strict-checked expanded new-seen))))
                        (if args
                            (%resolve-alias-strict-checked (append (if (consp type-spec) type-spec (list type-spec)) args) new-seen)
                            (%resolve-alias-strict-checked type-spec new-seen))))
                  (let ((simple (gethash base *crisp-type-aliases*)))
                    (if simple
                        (%resolve-alias-strict-checked simple new-seen)
                        spec))))
            spec))))

(defun %incomplete-storage-handle-p (type-spec)
  "Returns T if the type-spec is a storage handle but is missing explicit required keys (address-space, access)."
  (let ((resolved (%resolve-alias-strict type-spec)))
    (when (and (consp resolved) (%storage-handle-type-p resolved))
          (let ((base (first resolved))
                (args (rest resolved)))
            (let ((is-kw (or (member :address-space args) (member :access args))))
              (cond
               (is-kw
                 (let ((has-addr (member :address-space args))
                       (has-acc (member :access args)))
                   (not (and has-addr has-acc))))
               ((= (length args) 3) nil)
               (t t)))))))
(defun %explode-kernel-args (params signature)
  "Explodes storage handle parameters into raw scalars.
   Returns (VALUES exploded-params exploded-signature-types reassembly-bindings)."
  (let (exploded-params
        exploded-types
        reassembly-bindings
        (current-params params)
        (current-types signature))

    (loop while current-params do
            (let ((p (pop current-params))
                  (type (pop current-types)))

              ;; Sync &out marker
              (when (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                    (unless (and (symbolp type) (string-equal (symbol-name type) "&OUT"))
                      (error "Signature mismatch for &out: found ~s in type-spec." type))
                    (setf p (pop current-params))
                    (setf type (pop current-types)))

              (if (%storage-handle-type-p type)
                  (let* ((canonical (canonicalize-type-specifier type))
                         (base (if (consp canonical) (first canonical) canonical)))
                    (cond
                     ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
                       (let ((size-sym (intern (format nil "~a_BYTE_SIZE" (symbol-name p)) (symbol-package p)))
                             (ptr-sym (intern (format nil "~a_PTR" (symbol-name p)) (symbol-package p)))
                             (off-sym (intern (format nil "~a_OFFSET" (symbol-name p)) (symbol-package p)))
                             (as (if (consp canonical) (nth 2 canonical) :global)))
                         (push ptr-sym exploded-params)
                         (push size-sym exploded-params)
                         (push off-sym exploded-params)
                         (push `(c-pointer :address-space ,as) exploded-types)
                         (push 'ulong exploded-types)
                         (push 'ulong exploded-types)
                         (push `(,p (marshall-cell ,type ,size-sym ,ptr-sym ,off-sym)) reassembly-bindings)))
                     (t (error "Unsupported storage handle: ~a" base))))
                  (progn
                   (push p exploded-params)
                   (push type exploded-types)))))

    (values (reverse exploded-params) (reverse exploded-types) (reverse reassembly-bindings))))

(defun parse-kernel-signature (name params body)
  "Parses kernel parameters and body, performing validation and type extraction.
   Returns (values exploded-params exploded-types reassembly-bindings raw-body other-decls)."

  ;; 1. Validate C-Style Name (no dashes)
  (let ((name-str (symbol-name name)))
    (when (find #\- name-str)
          (error "Invalid Kernel Name '~a': Kernels requires C-style identifiers (no dashes)." name)))

  (when (or (member '&optional params) (member '&key params))
        (error "Kernels (def-kernel/def-kernel-exact) do not support &optional or &key parameters."))

  ;; 2. Extract Types from Body Declarations
  (let* ((declare-forms (loop for f in body while (and (listp f) (eq (car f) 'declare)) collect f))
         (raw-body (nthcdr (length declare-forms) body))
         (declarations (loop for d in declare-forms append (rest d)))
         (type-map (make-hash-table :test 'eq)))

    ;; 2.1 Parse (type ...) declarations
    (loop for d in declarations
            when (and (consp d) (eq (car d) 'type))
          do (let* ((args (rest d))
                    (first-arg (first args))
                    (last-arg (car (last args))))
               (cond
                ;; Disambiguate using strict check first
                ((strict-valid-type-p first-arg)
                  (dolist (v (rest args)) (setf (gethash v type-map) first-arg)))
                ((strict-valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg)))
                ;; Fallback
                ((valid-type-p first-arg)
                  (dolist (v (rest args)) (setf (gethash v type-map) first-arg)))
                ((valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg))))))

    ;; 2.2 Parse (function ...) declaration (Overriding or providing standard signature)
    (let ((fn-decl (find "FUNCTION" declarations :key (lambda (x) (and (consp x) (symbol-name (car x)))) :test #'string-equal)))
      (when fn-decl
            (let* ((sig (second fn-decl))
                   (arrow-pos (position '=> sig))
                   (param-types (subseq sig 0 (or arrow-pos (length sig)))))
              (let ((p-ptr params)
                    (t-ptr param-types))
                (loop while (and p-ptr t-ptr) do
                        (let ((p (pop p-ptr))
                              (ts (pop t-ptr)))
                          (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                              (let ((real-p (pop p-ptr))
                                    (real-ts (if (and (symbolp ts) (string-equal (symbol-name ts) "&OUT"))
                                                 (pop t-ptr)
                                                 ts)))
                                (setf (gethash real-p type-map) `(&out ,real-ts)))
                              (setf (gethash p type-map) ts))))))))

    ;; 2.3 Validate Completeness of Kernel Parameters
    (dolist (p params)
      (let ((t-spec (gethash p type-map)))
        (when (and t-spec (%incomplete-storage-handle-p t-spec))
              (error "def-kernel parameter '~a' has incomplete storage handle type ~a. Kernels require fully specified types (e.g. specify :address-space and :access)." p t-spec))))

    ;; 2.3 Reconstruct Signature Types in parameter order
    (let ((signature-types nil)
          (p-ptr params))
      (loop while p-ptr do
              (let ((p (pop p-ptr)))
                (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                    (let* ((real-p (pop p-ptr))
                           (type (gethash real-p type-map)))
                      (push '&out signature-types)
                      (push (if (and (consp type) (eq (car type) '&out)) (second type) type) signature-types))
                    (push (gethash p type-map) signature-types))))
      (setf signature-types (nreverse signature-types))

      (log:debug "DEBUG PARSE-KERNEL: ~a Params: ~a Types: ~a" name params signature-types)

      (unless (every #'identity signature-types)
        (error "def-kernel ~a: Missing type declarations for parameters: ~a" name
          (loop for p in params for t-spec in signature-types unless t-spec collect p)))

      ;; 2.4 Validate Completeness and VoidP
      (loop for t-spec in signature-types
            do (progn
                (when (incomplete-type-p t-spec)
                      (error "Kernel parameters must be COMPLETE types. Found incomplete: ~a" t-spec))
                (let ((canon (canonicalize-type-specifier t-spec)))
                  (when (or (eq canon 'voidp)
                            (and (symbolp canon) (string-equal (symbol-name canon) "VOIDP")))
                        (error "Kernel parameters cannot be of type 'voidp'. Use a specific pointer type with address space or a storage handle.")))))
      ;; 3. Explode Parameters
      (multiple-value-bind (exploded-params exploded-types reassembly-bindings)
          (%explode-kernel-args params signature-types)

        ;; Determine other declarations to preserve
        (let ((other-decls (loop for d in declarations
                                   unless (member (car d) '(function type))
                                 collect d)))
          (values exploded-params exploded-types reassembly-bindings raw-body other-decls signature-types))))))

(defmacro def-kernel (name params &rest body)
  "Defines a GPU Kernel (Entry Point).
   
   Constraint: All parameter types MUST be complete.
   Incomplete types (missing compile-time properties) are forbidden at the kernel boundary
   because the host must know the exact layout to marshall arguments."

  ;; Use the helper to parse and validate, avoiding code duplication and monolithic macros
  (multiple-value-bind (exploded-params exploded-types reassembly-bindings raw-body other-decls signature-types)
      (parse-kernel-signature name params body)

    ;; Expand to def-kernel-exact
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (setf (gethash ',name crisp.compiler::*kernel-declared-signatures*)
          (loop for p in ',params
                for t-spec in ',signature-types
                collect (cons p t-spec))))
      (def-kernel-exact ,name ,exploded-params
                        (declare #'(,@exploded-types))
                        ,@(when other-decls `((declare ,@other-decls)))
                        (let (,@reassembly-bindings)
                          ,@raw-body)))))

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

(defmacro def-type (name type-spec)
  "Defines a type alias.
   Example: (def-type T int)"
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (unless (crisp.compiler::valid-type-p ',type-spec)
       (error "Unknown type '~a'." ',type-spec))
     (setf (gethash ',name crisp.compiler::*crisp-template-aliases*) (cons nil ',type-spec))
     (setf (gethash ',name crisp.compiler::*crisp-type-aliases*) ',type-spec)))

;; Corrected def-struct macro for src/macros.lisp
;; Replace the existing def-struct starting at line 452

(defmacro def-struct (name &rest members)
  "Defines a new Crisp struct type."
  (let* ((parsed-members (mapcar #'parse-struct-member-spec members))
         (constructor-name (intern (format nil "MAKE-~a" name) (symbol-package name))))
    ;; Register at macro-expansion time (for visibility to subsequent code)
    (register-struct-definition name parsed-members)
    ;; Emit code to register using eval-when, AND the constructor MACRO
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-struct-definition ',name ',parsed-members))

      (defmacro ,constructor-name (&rest args)
        (let ((reordered (validate-and-reorder-struct-args ',name ',parsed-members args)))
          `(%construct-struct ,',name ,@reordered)))

      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                collect
                  (let* ((member-name (first member-spec))
                         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
                         (value (when is-ct (fourth member-spec))) ;; (name type :c-t value)
                         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
                    (if is-ct
                        (if value
                            ;; Generate Compile-Time Constant Accessor Macro
                            `(defmacro ,accessor-name (obj)
                               (declare (ignore obj))
                               '',value)
                            ;; No value provided (incomplete type) -> Do NOT generate macro. Let analyzer handle it.
                            nil)
                        ;; Generate Runtime Accessor Function
                        (let ((idx runtime-index))
                          (incf runtime-index)
                          `(progn
                            (def-function ,accessor-name ((obj ,name))
                                          (return (%extract-struct-member obj ,idx)))
                            ;; Generate Setter for Runtime Member
                            (def-setter ,accessor-name ((obj ,name) (val ,(second member-spec)))
                                        ;; Execute insert but don't return the result; return void instead
                                        (%insert-struct-member obj ,idx val)
                                        (return nil))))))))
      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                  unless (and (consp member-spec) (eq (third member-spec) :c-t))
                collect
                  (let* ((member-name (first member-spec))
                         (raw-accessor-name (intern (format nil "~~~a~~" member-name) pkg))
                         (idx runtime-index))
                    (incf runtime-index)
                    `(def-function ,raw-accessor-name ((obj ,name))
                                   (declare (crisp-system-generated))
                                   (return (%extract-struct-member obj ,idx)))))))))


(defmacro def-record (name &rest members)
  "Defines a new Crisp record type (virtual struct)."
  (let* ((parsed-members (mapcar #'parse-struct-member-spec members))
         (constructor-name (intern (format nil "MAKE-~a" name) (symbol-package name))))
    ;; Register at macro-expansion time
    (register-struct-definition name parsed-members :record)
    ;; Emit code
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-struct-definition ',name ',parsed-members :record))

      (defmacro ,constructor-name (&rest args)
        (let ((reordered (validate-and-reorder-struct-args ',name ',parsed-members args)))
          `(%construct-struct ,',name ,@reordered)))

      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                collect
                  (let* ((member-name (first member-spec))
                         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
                         (value (when is-ct (fourth member-spec)))
                         (type (second member-spec))
                         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
                    (if is-ct
                        (if (or (eq type 'type-spec) (eq type 'symbol) (null value))
                            ;; Skip generating accessors for non-runtime types or undefined values (incomplete types)
                            nil
                            `(def-function ,accessor-name ((obj ,name))
                                           (declare (function ((,name) => ,type)))
                                           (declare (crisp-system-generated))
                                           (return ,(if (or (numberp value) (stringp value) (eq value t) (eq value nil))
                                                        value
                                                        `',value))))
                        (let ((idx runtime-index))
                          (incf runtime-index)
                          `(def-function ,accessor-name ((obj ,name))
                                         (declare (crisp-system-generated))
                                         (return (%extract-struct-member obj ,idx))))))))
      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                  unless (and (consp member-spec) (eq (third member-spec) :c-t))
                collect
                  (let* ((member-name (first member-spec))
                         (raw-accessor-name (intern (format nil "~~~a~~" member-name) pkg))
                         (idx runtime-index))
                    (incf runtime-index)
                    `(def-function ,raw-accessor-name ((obj ,name))
                                   (declare (crisp-system-generated))
                                   (return (%extract-struct-member obj ,idx)))))))))

(defmacro def-setter (name args &body body)
  "Defines a setter function (which is just a def-function but semantically intended for use with set!).
   The return type is determined by the body."
  (let ((name-str (symbol-name name)))
    (when (or (string-equal name-str "~REF~")
              (and (> (length name-str) 2)
                   (cl:char= (cl:char name-str 0) #\~)
                   (cl:char= (cl:char name-str (1- (length name-str))) #\~)))
          (error 'crisp-illegal-overload-error :name name)))
  (let ((setter-name (intern (format nil "~a_SET!" (symbol-name name)) (symbol-package name))))
    `(def-function ,setter-name ,args
                   (declare (return-type nil))
                   ,@body)))

(defmacro crisp-language::setf (place value &rest pairs)
  "Custom setf implementation mapping (setf (f x) y) to (f_set! x y)."
  (if pairs
      `(progn
        (setf ,place ,value)
        (setf ,@pairs))
      (cond
       ((symbolp place)
         `(set! ,place ,value))
       ((consp place)
         (let ((op (car place))
               (args (cdr place)))
           (if (and (symbolp op) (eq (symbol-package op) (find-package :common-lisp)))
               `(common-lisp:setf ,place ,value)
               (let ((setter-name (intern (format nil "~a_SET!" (symbol-name op)) (symbol-package op))))
                 `(,setter-name ,@args ,value)))))
       (t (error "Invalid place for setf: ~a" place)))))

(defmacro r-t-assert (test &rest args)
  "Asserts that TEST is true at runtime. If not, terminates kernel.
   Args (message strings etc) are currently ignored."
  (declare (ignore args))
  (if *runtime-checks-enabled*
      `(unless ,test (die))
      nil))

(defmacro c-t-assert (condition message)
  "Compile-Time Assertion."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (unless ,condition
       (error "Compile-Time Assertion Failed: ~a" ,message))))

(defmacro r-t-assert-0 (test &rest args)
  "Asserts that TEST is true at runtime (placeholder for thread-0 check)."
  `(r-t-assert ,test ,@args))

(defmacro marshall-cell (type-alias byte-size ptr offset)
  "Marshals raw kernel arguments into a Cell struct.
   Usage: (marshall-cell out-c byte-size ptr offset)"
  (when (and (consp type-alias)
             (symbolp (first type-alias))
             (string-equal (symbol-name (first type-alias)) "CELL")
             (< (length type-alias) 4))
        (error "marshall-cell argument must be a complete type specification (e.g. (cell int :global :read-write)). Found: ~a" type-alias))

  (let* ((canonical (crisp.compiler::canonicalize-type-specifier type-alias))

         (base (first canonical))
         (params (rest canonical))
         (mangled-symbol (mangle-template-struct-name base params))
         (constructor-name (intern (format nil "MAKE-~a" mangled-symbol) (symbol-package base))))

    ;; Ensure the specific Cell struct is instantiated in the compiler environment
    ;; so that the constructor macro (make-cell_...) is defined.
    (let ((code (instantiate-template base params)))
      (eval code))

    (let* ((as (if (consp canonical) (nth 2 canonical) :global))
           (result `(,constructor-name
                      :parent (make-storage :address (as (c-pointer :address-space ,as) ,ptr) :byte-size ,byte-size)
                      :offset ,offset)))
      (log:warn "MARSHALL-CELL EXPANSION: ~S. Macro? ~a" result (macro-function constructor-name))
      result)))
