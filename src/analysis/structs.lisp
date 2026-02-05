;;; src/analysis/structs.lisp
(in-package :crisp.compiler)

(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, or cell type. Returns NIL if unknown."
  (let ((type (resolve-type-alias type)))
    (cond
     ((listp type) (second type)) ;; e.g. (ptr float), (array float 10)
     ((symbolp type)
       ;; Check if it is a Mangled Cell
       (let ((unmangled (unmangle-template-struct-name type)))
         (if (and (consp unmangled) (eq (first unmangled) 'cell))
             (second unmangled)
             nil)))
     (t nil))))

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

(defun analyze-struct-construction (expr env context location)
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
                   collect (let ((node (analyze-expression arg env context (append location (list (+ 2 i)))))
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

(defun analyze-extract-struct-member-expression (expr env context location)
  "Analyzes a `%extract-struct-member` expression.
   Form: (%extract-struct-member object-node index-literal)"
  (let* ((obj-node (analyze-expression (second expr) env context (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (obj-type (semantic-node-type obj-node)))

    (unless (symbolp obj-type)
      (error "Cannot extract member from non-struct type ~a" obj-type))

    ;; Resolve derived types to base type for struct lookup
    (let* ((base-type (get-type-base obj-type))
           (struct-def (gethash base-type *crisp-structs*)))
      (unless struct-def
        (error "Unknown struct type ~a (base: ~a) in extraction." obj-type base-type))

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


(defun analyze-insert-struct-member-expression (expr env context location)
  "Analyzes a `%insert-struct-member` expression.
   Form: (%insert-struct-member object-node index-literal value-node)"
  (let* ((obj-node (analyze-expression (second expr) env context (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (value-node (analyze-expression (fourth expr) env context (append location '(3))))
         (obj-type (semantic-node-type obj-node)))

    (unless (symbolp obj-type)
      (error "Cannot insert member into non-struct type ~a" obj-type))

    (let ((struct-def (gethash obj-type *crisp-structs*)))
      (unless struct-def
        (error "Unknown struct type ~a in insertion." obj-type))

      (let* ((padded-members (crisp-struct-definition-padded-members struct-def))
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

        ;; Type-check the value against the target member type
        (let ((value-type (semantic-node-type value-node)))
          (unless (types-compatible-p value-type target-member-type)
            (error 'crisp-type-error
              :expected target-member-type
              :inferred value-type
              :source-location location)))

        (make-semantic-insert-value
         :type obj-type
         :aggregate-node obj-node
         :index physical-index
         :value-node value-node
         :source-location location)))))


(defun analyze-aref-expression (expr env context location)
  (let* ((op (first expr))
         (target-sym (if (symbolp (second expr)) (second expr) nil))
         (array-node (analyze-expression (second expr) env context (append location '(1))))
         (index-expr (third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env context (append location '(2)))
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
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))


(defun analyze-set!-expression (expr env context location)
  "Analyzes a (set! target value) expression."
  (let* ((target-form (second expr))
         (value-form (third expr))
         (value-node (analyze-expression value-form env context (append location '(2)))))

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
                               collect (analyze-expression arg env context (append location (list 1 i)))))
              (all-arg-nodes (append arg-nodes (list value-node)))
              (all-arg-types (mapcar #'semantic-node-type all-arg-nodes))
              ;; Check for a matching setter function signature: (op arg1 ... argN value)
              (full-setter-name (intern (format nil "~a_SET!" op) (symbol-package op)))
              (signatures (append (gethash op *function-table*)
                            (gethash full-setter-name *function-table*)))
              (match (find-if (lambda (sig) (types-list-compatible-p all-arg-types (mapcar #'parameter-def-type (function-signature-parameters sig)))) signatures)))

         ;; If no match found, try checking if it's a template we can instantiate
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*) full-setter-name op)))
             (when (gethash template-op *template-registry*)
                   (ensure-template-instantiation template-op all-arg-types (lambda (f l) (declare (ignore l)) (eval f)))
                   ;; Re-fetch signatures after possible instantiation
                   (setf signatures (append (gethash op *function-table*)
                                      (gethash full-setter-name *function-table*)))
                   (setf match (find-if (lambda (sig) (types-list-compatible-p all-arg-types (mapcar #'parameter-def-type (function-signature-parameters sig)))) signatures)))))

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
                     (analyze-expression target-form env context (append location '(1))))))
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

(defun analyze-incomplete-type-accessor (op expr env context location)
  "Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).
   Returns a semantic-node (literal) if resolved, or NIL if not applicable."
  (let ((op-name (symbol-name op)))
    ;; Check if it is an accessor (ends with ~)
    (when (and (> (length op-name) 1) (alexandria:ends-with #\~ op-name))
          (let* ((member-name (intern (string-trim "~" op-name) (symbol-package op)))
                 ;; Analyze the first argument (obj)
                 (obj-expr (second expr)))
            (when obj-expr
                  ;; To avoid double analysis if not resolved, we might need to be careful.
                  ;; But analyze-expression is side-effect free mostly.
                  (let* ((obj-node (analyze-expression obj-expr env context (append location '(1))))
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
                                  (let ((kw (intern (symbol-name member-name) "KEYWORD")))
                                    (let ((val (getf params kw)))
                                      (when val
                                            ;; Return the literal value
                                            (cond
                                             ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
                                             ((symbolp val) (make-semantic-literal :value-type 'symbol :value val :source-location location))
                                             ((integerp val) (make-semantic-literal :value-type 'int :value val :source-location location))
                                             (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))))))))))))


(defun analyze-scratch-expression (expr env context location)
  "Analyzes a (make-scratch-cell ...) expression.
 This marks the current function as an originator in BOTH analysis modes."
  (declare (ignore env)) ; We don't use env yet.
  (unless (and (= (length expr) 2) (symbolp (cadr expr)))
    (error "Malformed make-scratch-cell form: ~a. Expected (make-scratch-cell <type>)" expr))

  ;; --- Originator Detection (both single-pass and two-pass) ---
  ;; Store the actual cell type and name in *implicit-arg-map*
  (log:debug "Originator: Found make-scratch-cell in ~s" (compiler-context-current-compiling-function context))
  (let* ((inner-type (cadr expr))
         (raw-spec (list 'cell inner-type))
         (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
    ;; Store: (name . type) - use current binding name if available
    (let ((implicit-name (or (compiler-context-current-binding-name context) '__storage))
          (existing (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*)))
      (if existing
          (log:warn "Structs: Implicit implicit-args already exist for ~a: ~a. Keeping existing."
                    (compiler-context-current-compiling-function context) existing)
          (progn
           (log:warn "Structs: Detected make-scratch-cell in ~a (Implicit Name: ~a)"
                     (compiler-context-current-compiling-function context) implicit-name)
           (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*)
             (list (cons implicit-name canonical-spec)))))))

  (let ((inner-type (cadr expr)))
    ;; Ensure the inner type is valid
    (unless (gethash inner-type *crisp-types*)
      (error 'crisp-unknown-type-error :type-name inner-type :source-location location))

    ;; Construct raw spec and expand/canonicalize it (e.g. inject defaults)
    (let* ((raw-spec (list 'cell inner-type))
           (canonical-spec (expand-storage-handle-type-specifier raw-spec)))

      ;; Ensure instantiation
      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (raw: ~a)" canonical-spec raw-spec))

      (make-semantic-literal :value-type canonical-spec
                             :value nil ; No real value yet
                             :source-location location))))

(defun register-struct-analyzers ()
  (def-expression-analyzer %construct-struct analyze-struct-construction)
  (def-expression-analyzer %extract-struct-member analyze-extract-struct-member-expression)
  (def-expression-analyzer %insert-struct-member analyze-insert-struct-member-expression)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)

  (def-expression-analyzer aref analyze-aref-expression)
  (def-expression-analyzer ~ref~ analyze-aref-expression)
  (def-expression-analyzer ~ analyze-aref-expression)

  (def-expression-analyzer set! analyze-set!-expression))
