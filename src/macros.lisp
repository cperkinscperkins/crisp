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


(defmacro with-peek-scratch-counter (&body body)
  "Executes body while insulating the global *scratch-cell-counter* from changes.
   Used for look-ahead scans that shouldn't affect the main codegen counter state.
   This is critical for single-pass compilation where we scan AND then codegen immediately."
  (let ((save-var (gensym "SAVE")))
    `(let ((,save-var *scratch-cell-counter*))
       (unwind-protect
           (progn ,@body)
         (setf *scratch-cell-counter* ,save-var)))))

;; Core Language Macros
;; ====================

(defmacro def-function (name params &rest body-and-location)
  "Defines a new, thread-level Crisp function."
  (when (string-equal (symbol-name name) "~REF~")
        (log:error "Illegal Overload Detected: Name=~s Pkg=~s Body=~s" name (symbol-package name) body-and-location)
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
            (log:error "Illegal Overload Detected (Pattern): Name=~s Str=~s Pkg=~s IsSystem=~a" name name-str (symbol-package name) is-system)
            (error 'crisp-illegal-overload-error :name name)))

    ;; Check for forward-only in def-function
    (when (find "FORWARD-ONLY" declarations :key (lambda (x) (when (symbolp x) (symbol-name x))) :test #'string-equal)
          (error "The 'forward-only' declaration is only allowed in kernels (def-kernel or def-grid-function), not in def-function."))

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
          (let ((args (rest resolved)))
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
                         ;; ABI FIX: For PTX/CUDA, pass pointers as ulong (i64) to avoid "invalid address space" on Generic->Global cast.
                         ;; For SPIR-V/OpenCL, we MUST use standard pointers (ptr) as per OpenCL kernel spec.
                         (if (and (boundp '*target-backend*) (member *target-backend* '(:ptx :cuda)))
                             (push 'ulong exploded-types)
                             (push `(c-pointer :address-space ,as) exploded-types))
                         (push 'ulong exploded-types)
                         (push 'ulong exploded-types)
                         (push `(,p (marshall-cell ,type ,size-sym ,ptr-sym ,off-sym)) reassembly-bindings)))
                     (t (error "Unsupported storage handle: ~a" base))))
                  (progn
                   (push p exploded-params)
                   (push type exploded-types)))))

    (values (reverse exploded-params) (reverse exploded-types) (reverse reassembly-bindings))))


(defun %parse-kernel-type-declarations (params declarations)
  "Helper: Parses type declarations and builds a hash map of param -> type."
  (let ((type-map (make-hash-table :test 'eq)))

    ;; Parse (type ...) declarations
    (loop for d in declarations
            when (and (consp d) (eq (car d) 'type))
          do (let* ((args (rest d))
                    (first-arg (first args))
                    (last-arg (car (last args))))
               (cond
                ((strict-valid-type-p first-arg)
                  (dolist (v (rest args))
                    (setf (gethash v type-map) first-arg)))
                ((strict-valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg)))
                ((valid-type-p first-arg)
                  (dolist (v (rest args)) (setf (gethash v type-map) first-arg)))
                ((valid-type-p last-arg)
                  (dolist (v (butlast args)) (setf (gethash v type-map) last-arg))))))

    ;; Parse (function ...) declaration
    (let ((fn-decl (find "FUNCTION" declarations
                     :key (lambda (x) (and (consp x) (symbol-name (car x))))
                     :test #'string-equal)))
      (when fn-decl
            (let* ((sig (second fn-decl))
                   (arrow-pos (position '=> sig))
                   (param-types (subseq sig 0 (or arrow-pos (length sig))))
                   (p-ptr params)
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
                            (setf (gethash p type-map) ts)))))))

    type-map))

(defun %validate-kernel-parameters (params type-map name)
  "Helper: Validates that kernel parameters are complete and not voidp."
  (dolist (p params)
    (let ((t-spec (gethash p type-map)))
      ;; Check for incomplete storage handles
      (when (and t-spec (%incomplete-storage-handle-p t-spec))
            (error "def-kernel parameter '~a' has incomplete storage handle type ~a. Kernels require fully specified types (e.g. specify :address-space and :access)."
              p t-spec))))

  ;; Build signature types for validation
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

    ;; Check completeness
    (unless (every #'identity signature-types)
      (error "def-kernel ~a: Missing type declarations for parameters: ~a" name
        (loop for p in params for t-spec in signature-types unless t-spec collect p)))

    ;; Validate types
    (loop for t-spec in signature-types
          do (when (incomplete-type-p t-spec)
                   (error "Kernel parameters must be COMPLETE types. Found incomplete: ~a" t-spec))
            (let ((canon (canonicalize-type-specifier t-spec)))
              (when (or (eq canon 'voidp)
                        (and (symbolp canon) (string-equal (symbol-name canon) "VOIDP")))
                    (error "Kernel parameters cannot be of type 'voidp'. Use a specific pointer type with address space or a storage handle."))))

    signature-types))

(defun %check-differentiate-kernel-signature (name signature-types declarations)
  "Helper: Enforces kernel requirements when Auto-Differentiation is enabled.
   Returns T if the kernel should be differentiated, NIL if it is forward-only."
  (if *differentiate-p*
      (let ((is-forward-only (find "FORWARD-ONLY" declarations :key (lambda (x) (when (symbolp x) (symbol-name x))) :test #'string-equal)))
        (if is-forward-only
            nil
            (if (member '&out signature-types)
                t
                (error "Differentiable Kernels require an '&out' parameter. If this kernel performs non-differentiable operations (like printing or shuffling), declare it as 'forward-only'. (~a)" name))))
      nil))


(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Helper: Generates the def-kernel-exact AST for the backward pass."
  (let ((inputs nil) (input-types nil)
                     (outputs nil) (output-types nil)
                     (is-out nil))
    (loop for p in params
          for t-spec in signature-types do
            (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                (setf is-out t)
                (if is-out
                    (progn (push p outputs) (push t-spec output-types))
                    (progn (push p inputs) (push t-spec input-types)))))
    (setf inputs (nreverse inputs) input-types (nreverse input-types)
      outputs (nreverse outputs) output-types (nreverse output-types))

    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg))
           (in-grads (loop for p in inputs collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
           (out-grads (loop for p in outputs collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
           (bwd-params (append inputs outputs out-grads (if in-grads (list '&out) nil) in-grads))
           (bwd-types (append input-types output-types output-types (if input-types (list '&out) nil) input-types)))

      (multiple-value-bind (exploded-params exploded-types bwd-reassembly-bindings)
          (%explode-kernel-args bwd-params bwd-types)

        (let* ((anf-body (mapcar #'anf-transform raw-body))
               (flat-anf (flatten-anf-body anf-body))
               (forward-bindings
                (loop for form in flat-anf
                        when (and (consp form) (= (length form) 2) (symbolp (car form)))
                      collect form))
               (forward-side-effects
                (loop for form in flat-anf
                        when (or (not (consp form))
                                 (not (= (length form) 2))
                                 (not (symbolp (car form))))
                      collect form))
               (backward-walk (generate-backward-walk flat-anf inputs outputs input-types output-types)))

          `(progn
            (eval-when (:compile-toplevel :load-toplevel :execute)
              (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                (loop for p in ',bwd-params
                      for t-spec in ',bwd-types
                      collect (cons p t-spec))))
            (def-kernel-exact ,bwd-name ,exploded-params
                              (declare #'(,@exploded-types))
                              (let (,@bwd-reassembly-bindings)
                                (let (,@forward-bindings)
                                  ,backward-walk))
                              (return))))))))


(defun parse-kernel-signature (name params body)
  "Parses kernel parameters and body, performing validation and type extraction.
   Returns (values exploded-params exploded-types reassembly-bindings raw-body other-decls)."

  ;; Validate C-Style Name
  (let ((name-str (symbol-name name)))
    (when (find #\- name-str)
          (error "Invalid Kernel Name '~a': Kernels requires C-style identifiers (no dashes)." name)))

  (when (or (member '&optional params) (member '&key params))
        (error "Kernels (def-kernel/def-kernel-exact) do not support &optional or &key parameters."))

  ;; Extract declarations
  (let* ((declare-forms (loop for f in body while (and (listp f) (eq (car f) 'declare)) collect f))
         (raw-body (nthcdr (length declare-forms) body))
         (declarations (loop for d in declare-forms append (rest d))))

    ;; Parse type declarations into a map
    (let ((type-map (%parse-kernel-type-declarations params declarations)))

      ;; Validate parameters and build signature types
      (let ((signature-types (%validate-kernel-parameters params type-map name)))

        (log:debug "DEBUG PARSE-KERNEL: ~a Params: ~a Types: ~a" name params signature-types)

        ;; Explode parameters
        (multiple-value-bind (exploded-params exploded-types reassembly-bindings)
            (%explode-kernel-args params signature-types)

          ;; Check AD constraints for kernels
          (let ((is-differentiable (%check-differentiate-kernel-signature name signature-types declarations)))

            ;; Determine other declarations to preserve
            (let ((other-decls (loop for d in declarations
                                       unless (or (and (consp d) (member (car d) '(function type)))
                                                  (and (symbolp d) (string-equal (symbol-name d) "FORWARD-ONLY")))
                                     collect d)))
              (values exploded-params exploded-types reassembly-bindings raw-body other-decls signature-types is-differentiable))))))))


(defmacro def-kernel (name params &rest body)
  "Defines a GPU Kernel (Entry Point).
   
   Constraint: All parameter types MUST be complete.
   Incomplete types (missing compile-time properties) are forbidden at the kernel boundary
   because the host must know the exact layout to marshall arguments."

  ;; Use the helper to parse and validate, avoiding code duplication and monolithic macros
  (multiple-value-bind (exploded-params exploded-types reassembly-bindings raw-body other-decls signature-types is-differentiable)
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
                          ,@raw-body))

      ;; Inject the Backward Kernel AST if differentiation is enabled and allowed
      ,@(when is-differentiable
              (list (%generate-backward-kernel-ast name params signature-types raw-body))))))


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

    (let ((forms '())
          (pkg (symbol-package struct-type)))
      (dolist (member (crisp-struct-definition-members struct-def))
        (let* ((member-name (first member))
               (aos-accessor-name
                (ecase access
                  (:public (intern (format nil "~a~~" member-name) pkg))
                  (:raw (intern (format nil "~~~a~~" member-name) pkg))))
               (soa-accessor-name (intern (format nil "~a~~" member-name) pkg)))

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
(defun %generate-struct-accessor (member-spec name pkg runtime-index)
  "Helper: Generates accessor (and setter) for a single struct member.
   Returns (values accessor-form new-runtime-index)."
  (let* ((member-name (first member-spec))
         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
         (value (when is-ct (fourth member-spec)))
         (accessor-name (intern (format nil "~a~~" member-name) pkg)))

    (cond
     ;; Compile-time member with value -> constant accessor macro
     ((and is-ct value)
       (values `(defmacro ,accessor-name (obj)
                  (declare (ignore obj))
                  '',value)
         runtime-index))

     ;; Compile-time member without value -> skip (incomplete type)
     (is-ct
       (values nil runtime-index))

     ;; Runtime member -> function accessor ONLY
     ;; We rely on set! analyzing the accessor form to generate update logic.
     ;; We DO NOT generate a def-setter because struct updates are functional
     ;; and must be wrapped in a set! for the holding variable.
     (t
       (let ((idx runtime-index))
         (values `(def-function ,accessor-name ((obj ,name))
                                (return (%extract-struct-member obj ,idx)))
           (1+ runtime-index)))))))

(defun %generate-raw-accessor (member-spec name pkg runtime-index)
  "Helper: Generates raw accessor for a runtime struct member.
   Returns (values accessor-form new-runtime-index)."
  (let* ((is-ct (and (consp member-spec) (eq (third member-spec) :c-t))))
    (if is-ct
        (values nil runtime-index)
        (let* ((member-name (first member-spec))
               (raw-accessor-name (intern (format nil "~~~a~~" member-name) pkg))
               (idx runtime-index))
          (values `(def-function ,raw-accessor-name ((obj ,name))
                                 (declare (crisp-system-generated))
                                 (return (%extract-struct-member obj ,idx)))
            (1+ runtime-index))))))


(defmacro def-struct (name &rest members)
  "Defines a new Crisp struct type. Supports brand declarations."
  (let* (;; Separate brand declarations from regular members
         (brand-decls (remove-if-not (lambda (m) (and (consp m) (eq (car m) 'brand))) members))
         (regular-members (remove-if (lambda (m) (and (consp m) (eq (car m) 'brand))) members))
         (parsed-members (mapcar #'parse-struct-member-spec regular-members))
         (constructor-name (intern (format nil "MAKE-~a" name) (symbol-package name))))
    ;; Register brands at macro-expansion time
    (dolist (brand brand-decls)
      (register-brand-definition name brand))
    ;; Register struct at macro-expansion time (for visibility to subsequent code)
    (register-struct-definition name parsed-members)
    ;; Emit code to register using eval-when, AND the constructor MACRO
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        ;; Register brands
        ,@(mapcar (lambda (brand)
                    `(register-brand-definition ',name ',brand))
              brand-decls)
        ;; Register struct
        (register-struct-definition ',name ',parsed-members))

      (defmacro ,constructor-name (&rest args)
        (let ((reordered (validate-and-reorder-struct-args ',name ',parsed-members args)))
          `(%construct-struct ,',name ,@reordered)))

      ;; Generate accessors
      ,@(let ((runtime-index 0)
              (pkg (symbol-package name))
              (forms '()))
          (dolist (member-spec parsed-members)
            (multiple-value-bind (accessor-form new-idx)
                (%generate-struct-accessor member-spec name pkg runtime-index)
              (cl:when accessor-form
                (push accessor-form forms))
              (setf runtime-index new-idx)))
          (nreverse forms))

      ;; Generate raw accessors
      ,@(let ((runtime-index 0)
              (pkg (symbol-package name))
              (forms '()))
          (dolist (member-spec parsed-members)
            (multiple-value-bind (raw-form new-idx)
                (%generate-raw-accessor member-spec name pkg runtime-index)
              (cl:when raw-form
                (push raw-form forms))
              (setf runtime-index new-idx)))
          (nreverse forms)))))


(defun %ct-resolve-value (value)
  "Resolve VALUE to a Lisp number if it is a typed-literal symbol (e.g. 2.0F, 100UC).
   SBCL reads suffix-notation literals as symbols; this converts them to the
   underlying number so :c-t default accessors have the right return type.
   Returns VALUE unchanged if it is not a recognisable typed literal."
  (if (and (symbolp value) (not (null value)) (not (eq value t)))
      (let* ((nm (symbol-name value))
             (sfxs '("BF" "UC" "UL" "US" "U" "S" "L" "H" "F"))
             (sfx (some (lambda (s)
                          (let ((sl (length s)) (nl (length nm)))
                            (when (and (> nl sl) (string= s (subseq nm (- nl sl)))) s)))
                        sfxs))
             (num (when sfx (ignore-errors (read-from-string (subseq nm 0 (- (length nm) (length sfx))))))))
        (if (numberp num) num value))
      value))

(defmacro def-record (name &rest members)
  "Defines a new Crisp record type (virtual struct). Supports brand declarations."
  (let* (;; Separate brand declarations from regular members
         (brand-decls (remove-if-not (lambda (m) (and (consp m) (eq (car m) 'brand))) members))
         (regular-members (remove-if (lambda (m) (and (consp m) (eq (car m) 'brand))) members))
         (parsed-members (mapcar #'parse-struct-member-spec regular-members))
         (constructor-name (intern (format nil "MAKE-~a" name) (symbol-package name))))
    ;; Register brands at macro-expansion time
    (dolist (brand brand-decls)
      (register-brand-definition name brand))
    ;; Register at macro-expansion time
    (register-struct-definition name parsed-members :record)
    ;; Emit code
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        ;; Register brands
        ,@(mapcar (lambda (brand)
                    `(register-brand-definition ',name ',brand))
              brand-decls)
        ;; Register record
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
                         (value (cl:when is-ct (fourth member-spec)))
                         (type (second member-spec))
                         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
                    (if is-ct
                        (if (or (eq type 'type-spec) (eq type 'symbol) (null value))
                            ;; Skip generating accessors for non-runtime types or undefined values (incomplete types)
                            nil
                            `(def-function ,accessor-name ((obj ,name))
                                           (declare (function ((,name) => ,type)))
                                           (declare (crisp-system-generated))
                                           (return ,(cl:let ((v (%ct-resolve-value value)))
                                                      (if (or (numberp v) (stringp v) (eq v t) (eq v nil))
                                                          v
                                                          `',v)))))
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

(defmacro def-derived-type (new-name original-type &key (subst nil subst-p))
  "Defines a new derived type from an existing type.

   Parameters:
   - new-name: Symbol for the new type
   - original-type: Type to derive from (must exist)
   - :subst: Substitution mode - :no, :equal, :descendant, :ancestor

   Automatically generates:
   - make-<new-name> constructor (for structural types)
   - as-<new-name> and as-<original> casting functions
   - is-<new-name>? type predicate
   - Property accessors (for struct types) - delegates to base type accessors

   Example:
     (def-derived-type meters float :subst :ancestor)"

  ;; Validate mandatory subst key
  (unless subst-p
    (error "def-derived-type: :subst parameter is mandatory. Please specify :subst (:no, :equal, :descendant, or :ancestor)."))

  ;; Validate at macro-expansion time
  (unless (member subst '(:no :equal :descendant :ancestor))
    (error "def-derived-type: :subst must be :no, :equal, :descendant, or :ancestor, got ~a" subst))

  ;; Note: We do NOT register at macro-expansion time explicitly anymore, because
  ;; doing so + the eval-when below causes double-registration which triggers
  ;; the "type already exists" error for valid code. The eval-when :compile-toplevel
  ;; handles registration during compilation.
  ;; (register-derived-type new-name original-type subst)

  (cl:let* ((pkg (symbol-package new-name))
            (make-name (intern (format nil "MAKE-~a" new-name) (symbol-package new-name)))
            (as-new-name (intern (format nil "AS-~a" new-name) (symbol-package new-name)))
            (as-orig-name (intern (format nil "AS-~a" original-type) (symbol-package new-name)))
            (is-new-name (intern (format nil "IS-~a?" new-name) (symbol-package new-name)))
            ;; Determine base type for struct lookup - try both original-type and computed base
            (base-type (compute-base-type original-type))
            ;; Package-agnostic struct lookup (records and structs both in *crisp-structs*)
            ;; Try: 1) base-type directly, 2) original-type directly,
            ;;      3) base-type in :crisp-language, 4) original-type in :crisp-language
            (struct-def (or (gethash base-type *crisp-structs*)
                            (gethash original-type *crisp-structs*)
                            (when (symbolp base-type)
                                  (gethash (intern (symbol-name base-type)
                                                   (find-package :crisp-language))
                                           *crisp-structs*))
                            (when (and (symbolp original-type)
                                       (not (eq original-type base-type)))
                                  (gethash (intern (symbol-name original-type)
                                                   (find-package :crisp-language))
                                           *crisp-structs*)))))

    `(progn
      ;; Register at load time too
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-derived-type ',new-name ',original-type ',subst))

      ;; Generate make-XXXX constructor (only for structural types)
      ;; For scalars, skip this - users will use as-XXXX instead
      ,@(when struct-def
              (cl:let ((orig-make-name (intern (format nil "MAKE-~a" original-type)
                                               (symbol-package original-type))))
                `((defmacro ,make-name (&rest args)
                    "Constructor for derived type - delegates to base type constructor."
                    `(,',as-new-name (,',orig-make-name ,@args))))))

      ;; Generate property accessors for struct types
      ;; Each accessor accepts the derived type and extracts the member directly
      ,@(when struct-def
              (cl:let ((runtime-index 0)
                       (members (crisp-struct-definition-members struct-def))
                       (forms '()))
                (dolist (member-spec members)
                  (cl:let* ((member-name (first member-spec))
                            (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
                            (value (when is-ct (fourth member-spec)))
                            (accessor-name (intern (format nil "~a~~" member-name) pkg))
                            (raw-accessor-name (intern (format nil "~~~a~~" member-name) pkg)))
                    (cl:cond
                      ;; Compile-time member with value -> constant accessor macro
                      ((and is-ct value)
                       (push `(defmacro ,accessor-name (obj)
                                (declare (ignore obj))
                                '',value)
                             forms))

                      ;; Compile-time member without value -> skip
                      (is-ct nil)

                      ;; Runtime member -> generate accessor function
                      (t
                       (cl:let ((idx runtime-index))
                         (push `(def-function ,accessor-name ((obj ,new-name))
                                              (return (%extract-struct-member obj ,idx)))
                               forms)
                         (push `(def-function ,raw-accessor-name ((obj ,new-name))
                                              (declare (crisp-system-generated))
                                              (return (%extract-struct-member obj ,idx)))
                               forms)
                         (incf runtime-index))))))
                (nreverse forms)))

      ;; Register as-<new-name> expression analyzer for casting
      ;; This allows (as-coordinate ...) to work like (as-int ...)
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (setf (gethash ',as-new-name *expression-analyzers*)
          #'analyze-cast-expression)
        (log:debug "Registered expression analyzer for ~a" ',as-new-name))

      ;; Also register as-<original> for reverse casting
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (setf (gethash ',as-orig-name *expression-analyzers*)
          #'analyze-cast-expression)
        (log:debug "Registered expression analyzer for ~a" ',as-orig-name))

      ;; Generate is-<new-name>? predicate
      (defun ,is-new-name (type-spec)
        ,(format nil "Returns T if TYPE-SPEC is exactly type ~a (does not accept substitutions)" new-name)
        (or (eq type-spec ',new-name)
            (and (consp type-spec) (eq (first type-spec) ',new-name)))))))

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
           ;; Instantiate STORAGE template for the specific address space
           (storage-base 'storage)
           (storage-params (list as))
           (storage-mangled (mangle-template-struct-name storage-base storage-params))
           (storage-constructor (intern (format nil "MAKE-~a" storage-mangled) (symbol-package base)))

           ;; Ensure storage template is instantiated
           (ignored (let ((code (instantiate-template storage-base storage-params)))
                      (eval code)))

           (result `(,constructor-name
                      :parent (,storage-constructor :address (as (c-pointer :address-space ,as) ,ptr) :byte-size ,byte-size)
                      :offset ,offset)))
      (log:warn "MARSHALL-CELL EXPANSION: ~S. Macro? ~a" result (macro-function constructor-name))
      result)))


(defmacro set-derived (ancestor-type descendant-type)
  "Links two existing struct types in a type hierarchy.
   The descendant can implicitly pass where the ancestor is expected.
   Generates as-<ancestor> and as-<descendant> casting functions.

   Syntax: (set-derived ancestor-type descendant-type)

   Requirements:
   - Both types must be structs (or derived from structs)
   - Ancestor size <= Descendant size
   - Shape compatible (flattened data members match in type and byte offset)
   - No cycles in the type DAG"

  (cl:let* ((pkg (cl:symbol-package ancestor-type))
            (as-ancestor-name (cl:intern (format nil "AS-~a" ancestor-type) pkg))
            (as-descendant-name (cl:intern (format nil "AS-~a" descendant-type) pkg)))
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-set-derived ',ancestor-type ',descendant-type))

      ;; Register expression analyzers for casting (if not already present)
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (cl:unless (gethash ',as-ancestor-name *expression-analyzers*)
          (setf (gethash ',as-ancestor-name *expression-analyzers*)
            #'analyze-cast-expression)
          (log:debug "set-derived: registered expression analyzer for ~a" ',as-ancestor-name))
        (cl:unless (gethash ',as-descendant-name *expression-analyzers*)
          (setf (gethash ',as-descendant-name *expression-analyzers*)
            #'analyze-cast-expression)
          (log:debug "set-derived: registered expression analyzer for ~a" ',as-descendant-name))))))

(defmacro brand (&rest args)
  "Catches invalid usage of BRAND outside of DEF-STRUCT or DEF-RECORD."
  (declare (ignore args))
  (error "BRAND can only be used within DEF-STRUCT or DEF-RECORD."))
