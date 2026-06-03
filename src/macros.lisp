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
         ',declarations  ;  '(((type a b int)) ((return-type int)))
         ',body-forms    ;  '((+ a b))
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
  "Returns T if the type-spec is a storage handle missing a required :c-t property.
   Canonical 6-tuple (tensor elem N addr aln ct) is complete only when addr and aln
   are both non-nil; canonical 3-tuple (cell elem addr) is complete only when addr
   is non-nil.  ct always has a default of :last so it's never the incompleteness
   trigger."
  (let* ((resolved (%resolve-alias-strict type-spec))
         ;; Canonicalize via expand so we always inspect the positional form,
         ;; regardless of whether the alias produced keyword or positional shape.
         (canonical (if (and (consp resolved) (%storage-handle-type-p resolved))
                        (expand-storage-handle-type-specifier resolved)
                        resolved)))
    (when (and (consp canonical) (%storage-handle-type-p canonical))
      (let* ((base (first canonical))
             (args (rest canonical)))
        (cond
          ;; Tensor: canonical positional 6-tuple (elem N addr aln ct).
          ;; Incomplete if addr or aln is nil (or fewer than 5 args, meaning
          ;; the user's keyword form wasn't fully canonicalized).
          ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
           (cond
             ;; 5 positional args: check for nil in addr (3rd) or aln (4th)
             ((= (length args) 5)
              (or (null (third args))   ; addr
                  (null (fourth args)))) ; aln
             ;; Anything else: not yet canonical — treat as incomplete
             (t t)))
          ;; CELL: canonical positional 3-tuple (elem addr).
          ;; Incomplete if addr is nil or fewer than 2 args.
          (t
           (cond
             ((= (length args) 2) (null (second args)))  ; addr
             (t t))))))))

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
                     ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
                      ;; Tensor (also covers vector/matrix after sugar expansion).
                      ;; N-dimensional: explode to (2 + 3N + 1) scalars.
                      ;; Order: p_PTR, p_BYTE_SIZE, p_OFFSET_0..N-1, p_STRIDE_0..N-1, p_EXTENT_0..N-1, p_LENGTH
                      (let* ((n   (if (integerp (third canonical)) (third canonical)
                                      (parse-integer (symbol-name (third canonical)))))
                             (as  (fourth canonical))
                             (p-name (symbol-name p))
                             (pkg    (symbol-package p))
                             (ptr-sym    (intern (format nil "~a_PTR"       p-name) pkg))
                             (size-sym   (intern (format nil "~a_BYTE_SIZE" p-name) pkg))
                             (off-syms   (loop for k from 0 below n
                                               collect (intern (format nil "~a_OFFSET_~a" p-name k) pkg)))
                             (str-syms   (loop for k from 0 below n
                                               collect (intern (format nil "~a_STRIDE_~a" p-name k) pkg)))
                             (ext-syms   (loop for k from 0 below n
                                               collect (intern (format nil "~a_EXTENT_~a" p-name k) pkg)))
                             (len-sym    (intern (format nil "~a_LENGTH"    p-name) pkg)))
                        ;; Push params in reverse of desired ABI order.
                        ;; Each push prepends; the outer (reverse ...) flips back.
                        ;; Desired final ABI: PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1, EXT_0..N-1, LENGTH
                        ;; Push order (reversed by outer reverse):
                        ;;   ptr, size, off_0..N-1, str_0..N-1, ext_0..N-1, len
                        (push ptr-sym  exploded-params)
                        (push size-sym exploded-params)
                        (dolist (s off-syms) (push s exploded-params))
                        (dolist (s str-syms) (push s exploded-params))
                        (dolist (s ext-syms) (push s exploded-params))
                        (push len-sym  exploded-params)
                        ;; Push types in matching order
                        (if (and (boundp '*target-backend*) (member *target-backend* '(:ptx :cuda)))
                            (push 'ulong exploded-types)
                            (push `(c-pointer :address-space ,as) exploded-types)) ; ptr
                        (push 'ulong exploded-types)           ; byte-size
                        (dotimes (_ n) (push 'ulong exploded-types)) ; offsets 0..N-1
                        (dotimes (_ n) (push 'ulong exploded-types)) ; strides 0..N-1
                        (dotimes (_ n) (push 'ulong exploded-types)) ; extents 0..N-1
                        (push 'ulong exploded-types)           ; length
                        ;; Reassembly
                        (push `(,p (%marshall-tensor ,type ,size-sym ,ptr-sym
                                     ,@off-syms ,@str-syms ,@ext-syms ,len-sym))
                              reassembly-bindings)))
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
  "Helper: Validates that kernel parameters are complete, not voidp,
   and that records do not appear in &out position."
  (dolist (p params)
    (let ((t-spec (gethash p type-map)))
      (when (and t-spec (%incomplete-storage-handle-p t-spec))
            (error "def-kernel parameter '~a' has incomplete storage handle type ~a. Kernels require fully specified types (e.g. specify :address-space)."
              p t-spec))))

  ;; Build signature types
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

    ;; Check all params have types
    (unless (every #'identity signature-types)
      (error "def-kernel ~a: Missing type declarations for parameters: ~a" name
        (loop for p in params for t-spec in signature-types unless t-spec collect p)))

    ;; Validate each type (completeness and voidp)
    (loop for t-spec in signature-types
          do (when (incomplete-type-p t-spec)
                   (error "Kernel parameters must be COMPLETE types. Found incomplete: ~a" t-spec))
             (let ((canon (canonicalize-type-specifier t-spec)))
               (when (or (eq canon 'voidp)
                         (and (symbolp canon) (string-equal (symbol-name canon) "VOIDP")))
                 (error "Kernel parameters cannot be of type 'voidp'. Use a specific pointer type with address space or a storage handle."))))

    ;; Records must NOT appear in &out position
    (let ((sig-ptr (copy-list signature-types)))
      (loop while sig-ptr do
              (let ((t-spec (pop sig-ptr)))
                (when (and (symbolp t-spec) (string-equal (symbol-name t-spec) "&OUT"))
                  (let ((next-type (first sig-ptr)))
                    (when (and next-type (%user-record-type-p next-type))
                      (error "Record type ~a cannot appear in &out position at the kernel boundary. Only storage handles (cell, vector, matrix) support &out position."
                        next-type)))))))

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
                (error "Kernel ~a has no '&out' parameter and is not differentiable. To compile under --differentiate, either add an '&out' parameter, or declare it 'forward-only' (the latter is appropriate for kernels performing non-differentiable operations like printing or shuffling)." name))))
      nil))




(defun %split-kernel-inputs-outputs (params signature-types)
  (let ((inputs nil) (input-types nil)
        (outputs nil) (output-types nil)
        (is-out nil))
    (loop for p in params
          for t-spec in signature-types do
      (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
          (setf is-out t)
          (if is-out
              (progn (push p outputs) (push t-spec output-types))
              (progn (push p inputs)  (push t-spec input-types)))))
    (values (nreverse inputs) (nreverse input-types)
            (nreverse outputs) (nreverse output-types))))



(defun %compute-backward-kernel-params (flat-inputs flat-input-types outputs output-types
                                        record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
  "Computes the parameter lists and type lists for the backward (gradient) kernel.
085: integer tensor inputs now also receive _GRAD outputs, typed as float tensors
(64-bit integers → double, all others → float). The backward walk still only
processes float inputs — integer tensor inputs contribute zero gradient."
  (let* ((record-exploded-syms
             (loop for orig in inputs
                      append (cl:let ((flds (gethash orig record-subs-ht)))
                               (when flds (mapcar #'cdr flds)))))

            ;; Backward-walk participation: per the 101 endeavor, float AND
            ;; integer scalars, float AND integer tensors, cells (any element
            ;; type).  Integer-scalar inputs used purely as indices end up
            ;; with always-zero adjoints automatically — index operators
            ;; (aref, cell read at index) have no gradient rule for the
            ;; index argument, so the chain rule never reaches them.
            (differentiable-non-rec-p
             (lambda (t-spec)
               (cl:let ((canonical (canonicalize-type-specifier t-spec)))
                 (or (%crisp-float-type-p t-spec)
                     (%crisp-integer-scalar-type-p t-spec)
                     (%crisp-float-tensor-type-p t-spec)
                     (%crisp-integer-tensor-type-p t-spec)
                     (and (consp canonical)
                          (string-equal (symbol-name (first canonical)) "CELL"))))))

            ;; Gets-grad-output: same set as differentiable-non-rec-p.
            ;; Integer-typed inputs receive float-typed _GRAD slots.  Index
            ;; uses produce always-zero gradients (correct semantics, free).
            (has-grad-output-p
             (lambda (t-spec) (funcall differentiable-non-rec-p t-spec)))

            (non-rec-scalar-in-grad-params
             (loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall has-grad-output-p t-spec)))
                      collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

            ;; Promote each input's _GRAD type to a writeable float-adjoint slot.
            ;; - integer/float tensor      → element-promoted tensor (read-write)
            ;; - integer/float cell        → element-promoted cell (keyword form)
            ;; - integer/float bare scalar → wrap in (cell <float-elem> :address-space :global)
            ;;   so the gradient can flow back to the caller via pointer indirection
            ;;   (bare scalar &out can't carry a value back).
            (non-rec-scalar-in-grad-types
             (loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall has-grad-output-p t-spec)))
                      collect (cond
                                ((%crisp-integer-tensor-type-p t-spec)
                                 (%integer-tensor-elem-to-float t-spec))
                                ((%crisp-float-tensor-type-p t-spec)
                                 (%ensure-tensor-read-write t-spec))
                                ((%crisp-integer-cell-type-p t-spec)
                                 (%integer-cell-elem-to-float t-spec))
                                ((let ((c (canonicalize-type-specifier t-spec)))
                                   (and (consp c) (symbolp (first c))
                                        (string-equal (symbol-name (first c)) "CELL")))
                                 ;; Float-element cell: pass through unchanged.
                                 t-spec)
                                ((%crisp-integer-scalar-type-p t-spec)
                                 (list 'cell (%integer-scalar-to-float-scalar t-spec)
                                       :address-space :global))
                                ((%crisp-float-type-p t-spec)
                                 (list 'cell t-spec :address-space :global))
                                (t (%ensure-tensor-read-write t-spec)))))

            (all-grad-out-params (append rec-grad-out-params non-rec-scalar-in-grad-params))
            (all-grad-out-types  (append rec-grad-out-types  non-rec-scalar-in-grad-types))
            (out-grads
             (loop for p in outputs
                      collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
            ;; Output _GRAD seeds (passed in by caller, parallel to outputs).
            ;; Promote element type to float adjoint when the output is integer-typed.
            (out-grad-types
             (mapcar (lambda (t-spec) (%promote-to-float-adjoint t-spec)) output-types))
            (bwd-params (append flat-inputs outputs out-grads
                                (when all-grad-out-params (list '&out))
                                all-grad-out-params))
            (bwd-types  (append flat-input-types output-types out-grad-types
                                (when all-grad-out-params (list '&out))
                                all-grad-out-types))

            ;; diff-flat-inputs: only float scalars and tensors — integers excluded.
            (diff-flat-inputs
             (loop for p in flat-inputs
                      for t-spec in flat-input-types
                      when (if (member p record-exploded-syms :test #'eq)
                               (%crisp-float-type-p t-spec)
                               (funcall differentiable-non-rec-p t-spec))
                      collect p))
            (diff-flat-input-types
             (loop for p in flat-inputs
                      for t-spec in flat-input-types
                      when (if (member p record-exploded-syms :test #'eq)
                               (%crisp-float-type-p t-spec)
                               (funcall differentiable-non-rec-p t-spec))
                      collect t-spec)))
    (values bwd-params bwd-types diff-flat-inputs diff-flat-input-types)))

(defun %has-diff-capable-scalar-input-p (flat-input-types)
  "Returns T if flat-input-types contains at least one integer scalar
   (signed/unsigned), including branded int scalars.  Used by the
   relaxed gate in %generate-backward-kernel-ast."
  (some (lambda (t-spec)
          (or (%crisp-integer-scalar-type-p t-spec)
              ;; Brand types: resolve to base and re-check.
              (let ((brand (is-brand-type-p t-spec)))
                (and brand
                     (%crisp-integer-scalar-type-p
                      (brand-definition-base-type brand))))))
        flat-input-types))




;; --------------------------------------------------------------------------
;; CT resolution helpers — used by both analyzer (env-based) and AD pre-pass
;; (signature-types-based).

(defun %resolve-tensor-form-ct (tensor-form type-resolver-fn)
  "Returns the static :contiguous-term keyword (:last/:first) of TENSOR-FORM,
   or NIL when it can't be determined.  TYPE-RESOLVER-FN: (sym -> static-type-or-nil).
   Only works when TENSOR-FORM is a bare symbol (the common case)."
  (when (and tensor-form (symbolp tensor-form) type-resolver-fn)
    (let ((ty (funcall type-resolver-fn tensor-form)))
      (when ty
        (let* ((canon (%ts-canonicalize-tensor-type ty))
               (raw (when (listp canon) (%get-tensor-ct canon))))
          (cond
            ((keywordp raw) raw)
            ((symbolp raw) (intern (symbol-name raw) :keyword))
            (t nil)))))))

(defun %tensor-stride-resolve-ct (expr type-resolver-fn location)
  "Determines the effective CT for expanding a tensor-stride EXPR.
   Handles both safe and strict variants:
     - Safe: returns the tensor's static CT, or :last with log:warn if
       it can't be resolved.
     - Strict: validates LAYOUT-TAG agrees with the tensor's static CT
       (when known) and returns the tag-implied CT."
  (let* ((strict-p (keywordp (third expr)))
         (layout-tag (when strict-p (third expr)))
         (bindings (if strict-p (fourth expr) (third expr)))
         (n (length bindings))
         (tensor-form (second expr))
         (static-ct (%resolve-tensor-form-ct tensor-form type-resolver-fn))
         (tag-ct (when strict-p (%ts-layout-tag-to-ct layout-tag n location))))
    (cond
      ((not strict-p)
       (or static-ct
           (progn
             (log:warn "tensor-stride: cannot statically determine contiguous-term for ~S; defaulting to :last (use the strict variant to make the layout explicit)"
                       tensor-form)
             :last)))
      ((null static-ct) tag-ct)
      ((eq tag-ct static-ct) tag-ct)
      (t (error 'crisp-compiler-error
                :message (format nil "tensor-stride: layout-tag ~S implies contiguous-term ~S but the tensor's static type has contiguous-term ~S"
                                 layout-tag tag-ct static-ct)
                :source-location location)))))

;; --------------------------------------------------------------------------
;; Recursive walker — used by the AD pre-pass.

(defun %make-kernel-param-type-resolver (params types)
  "Returns a closure (sym -> static-type-or-nil) built from the kernel's
   PARAMS and their declared TYPES.  Used by the AD pre-pass to resolve
   tensor-stride CT without an env."
  (let ((map (make-hash-table :test 'eq)))
    (loop for p in params for ty in types
          when (symbolp p) do (setf (gethash p map) ty))
    (lambda (sym) (and (symbolp sym) (gethash sym map)))))




(defun %expand-tensor-stride-op (form type-resolver-fn location)
  "Expand TENSOR-STRIDE form."
  (let* ((walked (cons (car form)
                       (mapcar (lambda (sub)
                                 (%expand-stride-macros-in-form sub type-resolver-fn location))
                               (cdr form))))
         (ct (%tensor-stride-resolve-ct walked type-resolver-fn location)))
    (%expand-tensor-stride-form walked ct location)))

(defun %expand-grid-stride-op (form type-resolver-fn location)
  "Expand GRID-STRIDE form."
  (let ((walked (cons (car form)
                      (mapcar (lambda (sub)
                                (%expand-stride-macros-in-form sub type-resolver-fn location))
                              (cdr form)))))
    (%expand-grid-stride-form walked location)))

(defun %expand-loop-vector-stride-op (form type-resolver-fn location)
  "Expand LOOP-VECTOR-STRIDE form."
  (let ((walked (cons (car form)
                      (mapcar (lambda (sub)
                                (%expand-stride-macros-in-form sub type-resolver-fn location))
                              (cdr form)))))
    (%expand-loop-vector-stride-form walked location)))

(defun %expand-tile-stride-op (form type-resolver-fn location)
  "Expand TILE-STRIDE form."
  (let* ((walked (cons (car form)
                       (mapcar (lambda (sub)
                                 (%expand-stride-macros-in-form sub type-resolver-fn location))
                               (cdr form))))
         (cl-pkg (find-package :crisp-language))
         (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
         (strict-p (keywordp (third walked)))
         (tile-pos (if strict-p 3 2))
         (bindings (nth (1+ tile-pos) walked))
         (synth-for-ct (if strict-p
                           (list ts-sym (second walked) (third walked) bindings)
                           (list ts-sym (second walked) bindings)))
         (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
    (%expand-tile-stride-form walked ct location)))

(defun %expand-hardware-stride-op (form type-resolver-fn location)
  "Expand HARDWARE-STRIDE form."
  (let* ((walked (cons (car form)
                       (mapcar (lambda (sub)
                                 (%expand-stride-macros-in-form sub type-resolver-fn location))
                               (cdr form))))
         (cl-pkg (find-package :crisp-language))
         (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
         ;; Detect strict variant: 3rd is layout-tag, 4th is hw-tag.
         (third (third walked))
         (strict-p (and (keywordp third)
                        (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
         (hw-pos (if strict-p 3 2))
         (bindings (nth (1+ hw-pos) walked))
         (synth-for-ct (if strict-p
                           (list ts-sym (second walked) (third walked) bindings)
                           (list ts-sym (second walked) bindings)))
         (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
    (%expand-hardware-stride-form walked ct location)))

(defun %expand-workgroup-stride-op (form type-resolver-fn location)
  "Expand WORKGROUP-STRIDE form."
  (let ((walked (cons (car form)
                      (mapcar (lambda (sub)
                                (%expand-stride-macros-in-form sub type-resolver-fn location))
                              (cdr form)))))
    (%expand-workgroup-stride-form walked location)))

(defun %expand-let-stride-op (form type-resolver-fn location)
  "Expand LET form, hoisting tile-coords binding values out of let-bindings."
  (let* ((bindings (cadr form))
         (body (cddr form))
         (rewritten-bindings
          (mapcar (lambda (b)
                    (if (and (consp b) (= (length b) 2) (symbolp (car b)))
                        ;; Recurse only into the VALUE position so the
                        ;; binding-name isn't accidentally rewritten.
                        (list (car b)
                              (%expand-stride-macros-in-form
                               (cadr b) type-resolver-fn location))
                        (%expand-stride-macros-in-form b type-resolver-fn location)))
                  bindings))
         (rewritten-body
          (mapcar (lambda (b) (%expand-stride-macros-in-form b type-resolver-fn location))
                  body))
         (hoisted-calls nil)
         (kept-bindings nil))
    (dolist (b rewritten-bindings)
      (let* ((val (and (consp b) (= (length b) 2) (cadr b)))
             (op (and (consp val) (symbolp (car val)) (car val)))
             (op-name (and op (symbol-name op))))
        (cond
          ((and op-name
                (or (string-equal op-name "LOAD-TILE-COORDS")
                    (string-equal op-name "STORE-TILE-COORDS")))
           (push val hoisted-calls))
          (t
           (push b kept-bindings)))))
    (setf hoisted-calls (nreverse hoisted-calls)
          kept-bindings (nreverse kept-bindings))
    (cond
      (hoisted-calls
       (let* ((cl-pkg (find-package :crisp-language))
              (progn-sym (intern "PROGN" cl-pkg))
              (let-sym (intern "LET" cl-pkg)))
         (if (null kept-bindings)
             `(,progn-sym ,@hoisted-calls ,@rewritten-body)
             `(,progn-sym ,@hoisted-calls
                          (,let-sym ,kept-bindings ,@rewritten-body)))))
      (t
       (cons (car form) (cons rewritten-bindings rewritten-body))))))

(defun %expand-request-load-tile-coords-op (form type-resolver-fn location)
  "Normalize request-load-tile-coords -> load-tile-coords (sync)."
  (let ((sync-sym (intern "LOAD-TILE-COORDS" (find-package :crisp-language))))
    (cons sync-sym
          (mapcar (lambda (sub)
                    (%expand-stride-macros-in-form sub type-resolver-fn location))
                  (cdr form)))))

(defun %expand-request-store-tile-coords-op (form type-resolver-fn location)
  "Normalize request-store-tile-coords -> store-tile-coords."
  (let ((sync-sym (intern "STORE-TILE-COORDS" (find-package :crisp-language))))
    (cons sync-sym
          (mapcar (lambda (sub)
                    (%expand-stride-macros-in-form sub type-resolver-fn location))
                  (cdr form)))))

(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites tensor-stride / grid-stride /
   loop-vector-stride / tile-stride / hardware-stride / workgroup-stride
   forms into their expansions.  Endeavor 113: also normalises
   request-load-tile-coords -> load-tile-coords and await-request -> nil
   for the backward pass."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%expand-stride-macros-in-form sub type-resolver-fn location)) form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "TENSOR-STRIDE")
          (%expand-tensor-stride-op form type-resolver-fn location))
         ((string-equal op-name "GRID-STRIDE")
          (%expand-grid-stride-op form type-resolver-fn location))
         ((string-equal op-name "LOOP-VECTOR-STRIDE")
          (%expand-loop-vector-stride-op form type-resolver-fn location))
         ((string-equal op-name "TILE-STRIDE")
          (%expand-tile-stride-op form type-resolver-fn location))
         ((string-equal op-name "HARDWARE-STRIDE")
          (%expand-hardware-stride-op form type-resolver-fn location))
         ((string-equal op-name "WORKGROUP-STRIDE")
          (%expand-workgroup-stride-op form type-resolver-fn location))
         ((string-equal op-name "LET")
          (%expand-let-stride-op form type-resolver-fn location))
         ((string-equal op-name "REQUEST-LOAD-TILE-COORDS")
          (%expand-request-load-tile-coords-op form type-resolver-fn location))
         ((string-equal op-name "REQUEST-STORE-TILE-COORDS")
          (%expand-request-store-tile-coords-op form type-resolver-fn location))
         ((string-equal op-name "AWAIT-REQUEST")
          nil)
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                        (cdr form)))))))))



(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-
   boundary accessor calls route adj into the SROA'd field's adj sym.
   Endeavor 107: pre-expands stride macros (tensor-stride / grid-stride /
   loop-vector-stride) in the kernel body so AD walks the expansion."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms
                            struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let* ((subst-body
                (mapcar (lambda (form)
                          (%substitute-record-accessors form record-subs-ht record-type-ht))
                        raw-body))
               ;; 107: AD pre-pass — rewrite stride macros into their expansions
               ;; using a kernel-param-based type resolver for tensor-stride CT.
               ;; The resolver is built from the ORIGINAL inputs/input-types
               ;; (not flat-inputs) so tensor-stride forms over a record param
               ;; resolve against the record's type before SROA renaming.  In
               ;; practice the tensor expression is a bare param name; the
               ;; resolver handles that cleanly.
               (kernel-type-resolver (%make-kernel-param-type-resolver inputs input-types))
               (expanded-body
                (mapcar (lambda (form)
                          (%expand-stride-macros-in-form form kernel-type-resolver nil))
                        subst-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                              (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                              (loop for entry in struct-shadow-info
                                    for p = (first entry)
                                    collect (nth (position p flat-inputs :test #'eq)
                                                 flat-input-types)))))
              (if (and (null augmented-diff-flat-inputs)
                       (null struct-shadow-info))
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  (let* ((anf-body      (mapcar #'anf-transform expanded-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         (struct-shadow-ht
                          (when struct-shadow-info
                            (let ((ht (make-hash-table :test 'eq)))
                              (dolist (entry struct-shadow-info)
                                (setf (gethash (first entry) ht)
                                      (cons (second entry)
                                            (fourth entry))))
                              (%register-shadow-anf-intermediates flat-anf ht)
                              ht)))
                         (kernel-record-param-field-adjs-ht
                          (when (> (hash-table-count record-subs-ht) 0)
                            (let ((ht (make-hash-table :test 'eq)))
                              (maphash
                               (lambda (rsym field-alist)
                                 (let ((adj-alist
                                        (loop for entry in field-alist
                                              for fname = (car entry)
                                              for fsym  = (cdr entry)
                                              unless (eq fname :%nested-leaf%)
                                              collect (cons (symbol-name fname)
                                                            (intern (format nil "~A_ADJ" (symbol-name fsym))
                                                                    pkg)))))
                                   (setf (gethash rsym ht) adj-alist)))
                               record-subs-ht)
                              ht)))
                         (raw-backward-walk
                          (let ((*struct-kernel-param-shadows* struct-shadow-ht)
                                (*record-param-field-adjs* kernel-record-param-field-adjs-ht))
                            (generate-backward-walk flat-anf
                                                    augmented-diff-flat-inputs outputs
                                                    augmented-diff-flat-input-types output-types
                                                    :kernel-pkg pkg)))
                         (backward-walk-1
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                         (backward-walk-2
                          (if struct-shadow-info
                              (let ((all-leaves
                                     (loop for entry in struct-shadow-info
                                           append (%collect-all-leaf-adj-syms (fourth entry)))))
                                (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                              backward-walk-1))
                         (backward-walk
                          (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
                         (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))
                    `(progn
                      (eval-when (:compile-toplevel :load-toplevel :execute)
                        (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                          (loop for p in ',bwd-params
                                   for t-spec in ',bwd-types
                                   collect (cons p t-spec))))
                      (def-kernel-exact ,bwd-name ,exploded-params
                                        (declare #'(,@exploded-types))
                                        (let (,@all-reassembly)
                                          (let (,@forward-bindings)
                                            ,backward-walk))
                                        (return)))))))))))))

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

    ;; Expand to def-kernel-exact.
    ;; When the kernel is forward-only (not differentiable), add a (non-differentiable)
    ;; declaration so that internal-def-function can suppress the ANF transformation.
    ;; This mirrors the (entry-point) declare pattern -- a list form, safe for
    ;; parse-function-declarations which calls (car x) on each declaration.
    (let ((non-diff-decl (unless is-differentiable '((non-differentiable)))))
      `(progn
        (eval-when (:compile-toplevel :load-toplevel :execute)
          (setf (gethash ',name crisp.compiler::*kernel-declared-signatures*)
            (loop for p in ',params
                  for t-spec in ',signature-types
                  collect (cons p t-spec))))
        (def-kernel-exact ,name ,exploded-params
                          (declare #'(,@exploded-types))
                          ,@(when (or other-decls non-diff-decl)
                              `((declare ,@other-decls ,@non-diff-decl)))
                          (let (,@reassembly-bindings)
                            ,@raw-body))

        ;; Inject the Backward Kernel AST if differentiation is enabled and allowed
        ,@(when is-differentiable
                (list (%generate-backward-kernel-ast name params signature-types raw-body)))))))


(defmacro def-grid-function (name params &rest body)
  "Defines a grid-level function.
   Grid functions have a dispatch-level context in their body: they can call both
   thread-level (def-function) and grid-level functions.

   Unlike def-function:
   - Cannot return values (void).
   - Cannot be called from def-function (thread-level context).

   Unlike def-kernel:
   - Lisp-style naming allowed (dashes ok, case-insensitive).
   - Supports &optional and &key parameters.
   - Not an entry point; cannot be enqueued by the host directly."
  (let* ((declare-forms (loop for f in body
                              while (and (listp f) (eq (car f) 'declare))
                              collect f))
         (body-forms (nthcdr (length declare-forms) body)))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (setf (gethash ',name crisp.compiler::*grid-functions*) t))
       (def-function ,name ,params
         ,@declare-forms
         (declare (grid-function))
         ,@body-forms
         (return)))))


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

(defun %parse-ct-literal (value)
  "If VALUE is a symbol whose name looks like a typed numeric literal (e.g. 2.0F,
   100UC), parse and return the underlying number.  Otherwise return VALUE unchanged."
  (if (not (symbolp value))
      value
      (let* ((name (symbol-name value))
             ;; Longest-first so BF is checked before F, UL before L, etc.
             (suffixes '("BF" "UC" "UL" "US" "U" "S" "L" "C" "H" "F" "D"))
             (suffix (some (lambda (s)
                             (let ((sl (length s)) (nl (length name)))
                               (when (and (> nl sl)
                                          (string= s (subseq name (- nl sl))))
                                 s)))
                           suffixes)))
        (if suffix
            (let* ((num-str (subseq name 0 (- (length name) (length suffix))))
                   (parsed  (ignore-errors (read-from-string num-str))))
              (if (numberp parsed) parsed value))
            value))))



(defun %generate-struct-accessor (member-spec name pkg runtime-index)
  "Helper: Generates accessor (and setter) for a single struct member.
   Returns (values accessor-form new-runtime-index).
   Fix: typed-literal symbols in :c-t defaults are resolved to their numeric values."
  (let* ((member-name (first member-spec))
         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
         (raw-value (when is-ct (fourth member-spec)))
         ;; Resolve typed-literal symbols (e.g. 2.0F -> 2.0) for c-t defaults.
         (value (when is-ct (%parse-ct-literal raw-value)))
         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
    (cond
     ;; Compile-time member with value -> constant accessor macro
     ((and is-ct value)
       (values `(defmacro ,accessor-name (obj)
                  (declare (ignore obj))
                  ',value)
         runtime-index))
     ;; Compile-time member without value -> skip (incomplete type)
     (is-ct
       (values nil runtime-index))
     ;; Runtime member -> function accessor
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
             (sfxs '("BF" "UC" "UL" "US" "U" "S" "L" "C" "H" "F" "D"))
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
                                           (return ,(cl:let* ((v (%ct-resolve-value value))
                                                              ;; Cast integer literals to numeric c-t types
                                                              ;; to avoid int vs ulong/uint/long etc. mismatch.
                                                              (cast-fn (cl:when (cl:and (cl:integerp v)
                                                                                        (cl:member type '(ulong uint ushort uchar long short char)))
                                                                         (cl:intern (cl:format nil "TO-~a" type) pkg))))
                                                       (cl:if cast-fn
                                                              `(,cast-fn ,v)
                                                              (if (or (numberp v) (stringp v) (eq v t) (eq v nil))
                                                                  v
                                                                  `',v))))))
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
      (declare (ignore ignored))
      (log:warn "MARSHALL-CELL EXPANSION: ~S. Macro? ~a" result (macro-function constructor-name))
      result)))


(defmacro %marshall-tensor (type-alias byte-size ptr &rest flat-args)
  "Internal workhorse: assembles a tensor struct from flat positional scalar args.
   Form: (%marshall-tensor type byte-size ptr off0..N-1 str0..N-1 ext0..N-1 length)
   flat-args must contain exactly 3N+1 values: N offsets, N strides, N extents, 1 length.
   Used by %explode-kernel-args, marshall-vector, marshall-matrix, and marshall-tensor."
  (let* ((canonical (canonicalize-type-specifier type-alias))
         (base      (first canonical))
         (params    (rest canonical)))
    (unless (and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
      (error "%marshall-tensor: type must be a tensor type, got ~a" type-alias))
    (let* ((n    (if (integerp (third canonical)) (third canonical)
                     (parse-integer (symbol-name (third canonical)))))
           (as   (fourth canonical))
           (expected (+ (* 3 n) 1)))
      (unless (= (length flat-args) expected)
        (error "%marshall-tensor: expected ~a flat args (3*N+1 for N=~a) but got ~a" expected n (length flat-args)))
      (let* ((off-args  (subseq flat-args 0 n))
             (str-args  (subseq flat-args n (* 2 n)))
             (ext-args  (subseq flat-args (* 2 n) (* 3 n)))
             (len-arg   (nth (* 3 n) flat-args))
             (mangled   (mangle-template-struct-name base params))
             (ctor      (intern (format nil "MAKE-~a" mangled) (symbol-package base)))
             (storage-base   (find-symbol "STORAGE" (symbol-package base)))
             (storage-params (list as))
             (stor-mangled   (mangle-template-struct-name storage-base storage-params))
             (stor-ctor      (intern (format nil "MAKE-~a" stor-mangled) (symbol-package base))))
        ;; Ensure templates are instantiated so constructors are available
        (eval (instantiate-template base params))
        (eval (instantiate-template storage-base storage-params))
        (log:debug "%MARSHALL-TENSOR: type=~a mangled=~a ctor=~a N=~a" type-alias mangled ctor n)
        `(,ctor
          :parent (,stor-ctor
                   :address  (as (c-pointer :address-space ,as) ,ptr)
                   :byte-size ,byte-size)
          :offset  (%make-ct-array ulong ,@off-args)
          :strides (%make-ct-array ulong ,@str-args)
          :extents (%make-ct-array ulong ,@ext-args)
          :length  ,len-arg)))))


(defmacro marshall-tensor (type-alias byte-size ptr &rest kwargs)
  "Assembles a tensor struct from keyword-grouped scalar args.

   Form:
     (marshall-tensor type byte-size ptr
       :offsets (o0 o1 ... oN-1)
       :strides (s0 s1 ... sN-1)
       :extents (e0 e1 ... eN-1)
       :length  len)

   type-alias must be a fully-specified tensor (or expanded vector/matrix) type.
   Each sublist must contain exactly N elements matching the tensor arity.
   All four keywords are required."
  (let* ((canonical (canonicalize-type-specifier type-alias))
         (base      (first canonical)))
    (unless (and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
      (error "marshall-tensor: type must be a tensor type, got ~a" type-alias))
    (let ((n (if (integerp (third canonical)) (third canonical)
                 (parse-integer (symbol-name (third canonical))))))
      ;; Parse keyword args
      (let ((offsets nil) (strides nil) (extents nil) (length-val nil)
            (ptr-kwargs (copy-list kwargs)))
        (loop while ptr-kwargs do
          (let ((key (pop ptr-kwargs)))
            (unless ptr-kwargs
              (error "marshall-tensor: keyword ~a has no value" key))
            (let ((val (pop ptr-kwargs)))
              (cond
                ((eq key :offsets) (setf offsets val))
                ((eq key :strides) (setf strides val))
                ((eq key :extents) (setf extents val))
                ((eq key :length)  (setf length-val val))
                (t (error "marshall-tensor: unknown keyword ~a. Expected :offsets, :strides, :extents, :length" key))))))
        ;; Validate all keys present
        (unless offsets   (error "marshall-tensor missing required keyword :offsets"))
        (unless strides   (error "marshall-tensor missing required keyword :strides"))
        (unless extents   (error "marshall-tensor missing required keyword :extents"))
        (unless length-val (error "marshall-tensor missing required keyword :length"))
        ;; Validate sublist lengths
        (unless (= (length offsets) n)
          (error "marshall-tensor :offsets list length ~a does not match tensor arity N=~a" (length offsets) n))
        (unless (= (length strides) n)
          (error "marshall-tensor :strides list length ~a does not match tensor arity N=~a" (length strides) n))
        (unless (= (length extents) n)
          (error "marshall-tensor :extents list length ~a does not match tensor arity N=~a" (length extents) n))
        ;; Delegate to the flat internal workhorse
        `(%marshall-tensor ,type-alias ,byte-size ,ptr
           ,@offsets ,@strides ,@extents ,length-val)))))


(defmacro marshall-vector (type-alias byte-size ptr off_0 str_0 ext_0 length)
  "Assembles a vector (tensor N=1) from 6 flat scalar args.
   type-alias must be a fully-specified vector or tensor N=1 type.
   Delegates to %marshall-tensor after validating N=1."
  (let* ((canonical (canonicalize-type-specifier type-alias))
         (base      (first canonical))
         (n         (if (integerp (third canonical)) (third canonical)
                        (parse-integer (symbol-name (third canonical))))))
    (unless (and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
      (error "marshall-vector: type must be a vector/tensor type, got ~a" type-alias))
    (unless (= n 1)
      (error "marshall-vector requires a vector (N=1) type, got N=~a. Use marshall-matrix for N=2 or marshall-tensor for general N." n))
    `(%marshall-tensor ,type-alias ,byte-size ,ptr ,off_0 ,str_0 ,ext_0 ,length)))


(defmacro marshall-matrix (type-alias byte-size ptr off_0 off_1 str_0 str_1 ext_0 ext_1 length)
  "Assembles a matrix (tensor N=2) from 9 flat scalar args.
   type-alias must be a fully-specified matrix or tensor N=2 type.
   Delegates to %marshall-tensor after validating N=2."
  (let* ((canonical (canonicalize-type-specifier type-alias))
         (base      (first canonical))
         (n         (if (integerp (third canonical)) (third canonical)
                        (parse-integer (symbol-name (third canonical))))))
    (unless (and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
      (error "marshall-matrix: type must be a matrix/tensor type, got ~a" type-alias))
    (unless (= n 2)
      (error "marshall-matrix requires a matrix (N=2) type, got N=~a. Use marshall-vector for N=1 or marshall-tensor for general N." n))
    `(%marshall-tensor ,type-alias ,byte-size ,ptr ,off_0 ,off_1 ,str_0 ,str_1 ,ext_0 ,ext_1 ,length)))


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
