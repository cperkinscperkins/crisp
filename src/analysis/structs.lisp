;;; src/analysis/structs.lisp
(in-package :crisp.compiler)
 

(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, cell, or tensor type.
   Returns NIL if unknown.
   Handles single-element list wrapping, e.g. ((array float 4)) → (array float 4)."
  (let* ((type (if (and (listp type) (= (length type) 1) (listp (first type)))
                   (first type)
                   type))
         (type (resolve-type-alias type)))
    (cond
     ((listp type)
      (let ((base (first type)))
        (if (and (symbolp base)
                 (member (symbol-name base)
                         '("CELL" "VECTOR" "MATRIX" "TENSOR" "PTR" "ARRAY" "POINTER")
                         :test #'string-equal))
            (second type)
            nil)))
     ((symbolp type)
      (let ((unmangled (unmangle-template-struct-name type)))
        (if (and (consp unmangled)
                 (symbolp (first unmangled))
                 (member (symbol-name (first unmangled))
                         '("CELL" "TENSOR" "VECTOR" "MATRIX")
                         :test #'string-equal))
            (second unmangled)
            nil)))
     (t nil))))

(defun get-struct-member-index (struct-type-name member-name)
  "Helper to find the physical index of a struct member, accounting for padding."
  ;; Resolve derived types to their base type first
  (let ((original-type struct-type-name)
        (struct-type-name (if (symbolp struct-type-name)
                              (get-type-base struct-type-name)
                              struct-type-name)))
    (when (and (symbolp original-type) (not (eq original-type struct-type-name)))
      (log:debug "Resolved derived type ~a to base type ~a" original-type struct-type-name))
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
        index)))))



(defun numeric-type-category (type-name)
  "Returns the category (:signed-int, :unsigned-int, :float) if TYPE-NAME is a numeric
   scalar in *crisp-types*, or NIL otherwise. Resolves aliases and derived types first."
  (let* ((resolved (resolve-type-alias type-name))
            (base (get-type-base resolved))
            (crisp-type (when (symbolp base) (gethash base *crisp-types*))))
    (when (and crisp-type
                  (member (crisp-type-category crisp-type) '(:signed-int :unsigned-int :float)))
      (crisp-type-category crisp-type))))



(defun analyze-struct-construction (expr env context location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form.
   Supports implicit promotion of base-type values to branded member types
   in struct constructors (the birthplace of branded values).
   Uses get-single-value-type to normalize function-call return type lists
   (e.g. ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)) before type comparison."
  (let* ((type-name (second expr))
         (args (cddr expr))
         (struct-def (lookup-struct-definition type-name)))
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
                             ;; get-single-value-type unwraps ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)
                             ;; for function-call nodes whose semantic-call-type is a return-types list
                             (let ((arg-type (get-single-value-type node)))
                               (log:debug "STRUCT-CTOR ~a member ~a: arg-type=~a expected=~a"
                                          type-name (first member) arg-type expected-type)
                               ;; Type check with branded type promotion
                               (unless (type-equal-p arg-type expected-type)
                                 (let ((brand-def (is-brand-type-p expected-type)))
                                   (if brand-def
                                       ;; Branded member: check numeric compatibility with base type
                                       (let* ((base-type (brand-definition-base-type brand-def))
                                                 (arg-cat (numeric-type-category arg-type))
                                                 (base-cat (numeric-type-category base-type)))
                                         (if (and arg-cat base-cat)
                                             ;; Compatible numeric types - wrap in a value cast to the base type
                                             (progn
                                              (log:debug "Constructor promotion: ~a -> ~a (base ~a) for member ~a"
                                                         arg-type expected-type base-type (first member))
                                              (setf node (make-semantic-value-cast
                                                          :type base-type
                                                          :arg node
                                                          :source-location (append location (list (+ 2 i))))))
                                             ;; Not numeric-compatible
                                             (error 'crisp-type-error
                                               :expected expected-type
                                               :inferred arg-type
                                               :source-location location)))
                                       ;; Not a branded member -> real type error
                                       (error 'crisp-type-error
                                         :expected expected-type
                                         :inferred arg-type
                                         :source-location location))))
                               node)))))

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

    ;; Lookup struct definition (handles derived types and package issues)
    (let* ((struct-def (lookup-struct-definition obj-type)))
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


(defun analyze-insert-struct-member-expression (expr env context location)
  "Analyzes a `%insert-struct-member` expression.
   Form: (%insert-struct-member object-node index-literal value-node)"
  (let* ((obj-node (analyze-expression (second expr) env context (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (value-node (analyze-expression (fourth expr) env context (append location '(3))))
         (obj-type (semantic-node-type obj-node)))

    (unless (symbolp obj-type)
      (error "Cannot insert member into non-struct type ~a" obj-type))

    (let ((struct-def (lookup-struct-definition obj-type)))
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



(defun %tensor-type-p (type)
  "Returns T if TYPE denotes a tensor (list or mangled-symbol form)."
  (cond
    ((and (listp type) (symbolp (first type)))
     (string-equal (symbol-name (first type)) "TENSOR"))
    ((symbolp type)
     (let ((name (symbol-name type)))
       (and (>= (length name) 7)
            (string-equal (subseq name 0 7) "TENSOR_"))))
    (t nil)))

(defun %get-tensor-arity (type)
  "Returns the compile-time arity N of TYPE as an integer, or NIL.
   Handles list form (tensor elem N ...) and mangled-symbol form."
  (labels ((coerce-n (raw)
             (etypecase raw
               (integer raw)
               (symbol  (ignore-errors (parse-integer (symbol-name raw) :junk-allowed nil)))
               (t nil))))
    (cond
      ((and (listp type) (symbolp (first type))
            (string-equal (symbol-name (first type)) "TENSOR"))
       (coerce-n (third type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (first unmangled))
                    (string-equal (symbol-name (first unmangled)) "TENSOR"))
           (coerce-n (third unmangled)))))
      (t nil))))

(defun %build-tensor-flat-index-form (target-sym index-forms)
  "Builds a Crisp expression computing the flat element index for a tensor access.
   flat = Σ_k( (~ (offset~ target) k) + index_k * (~ (strides~ target) k) )
   for k in 0..(N-1).  Returns a Crisp form ready for analyze-expression.
   All arithmetic is ulong: each index is wrapped in (to-ulong ...) to ensure
   consistent types when the caller passes bare integer literals (int by default)."
  (labels ((coerce-index (idx-form)
             ;; Wrap in to-ulong so literal 0/1/... (int) becomes ulong for arithmetic
             `(to-ulong ,idx-form))
           (dim-term (k)
             `(+ (~ (offset~ ,target-sym) ,k)
                 (* ,(coerce-index (nth k index-forms)) (~ (strides~ ,target-sym) ,k)))))
    (if (= (length index-forms) 1)
        (dim-term 0)
        (reduce (lambda (acc k) `(+ ,acc ,(dim-term k)))
                (loop for k from 1 below (length index-forms) collect k)
                :initial-value (dim-term 0)))))

          

(defun %get-tensor-align (type)
  "Extracts the :align keyword from a tensor type specifier.
   TYPE may be a list form (tensor elem N addr access align) or a
   mangled symbol TENSOR_ELEM_N_ADDR_ACCESS_ALIGN.
   Returns :compact, :compact-offset, :strided, or NIL (unknown / template)."
  (labels ((coerce-aln (raw)
             (cond
               ((eq raw :compact)         :compact)
               ((eq raw :compact-offset)  :compact-offset)
               ((eq raw :strided)         :strided)
               ((and (symbolp raw) (string-equal (symbol-name raw) "COMPACT"))         :compact)
               ((and (symbolp raw) (string-equal (symbol-name raw) "COMPACT-OFFSET"))  :compact-offset)
               ((and (symbolp raw) (string-equal (symbol-name raw) "STRIDED"))         :strided)
               (t nil))))
    (cond
      ((and (listp type) (symbolp (first type))
            (string-equal (symbol-name (first type)) "TENSOR"))
       (coerce-aln (sixth type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (first unmangled))
                    (string-equal (symbol-name (first unmangled)) "TENSOR"))
           (coerce-aln (sixth unmangled)))))
      (t nil))))


(defun %build-tensor-compact-flat-index-form (target-sym index-forms)
  "Builds the :compact flat-index form — Horner on extents only, NO offset reads.
   :compact guarantees all offsets are zero at the kernel boundary, so we skip them.
   N=1: flat = i_0
   N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1})"
  (let ((n (length index-forms)))
    (if (= n 1)
        ;; Vector: just the index, cast to ulong
        `(to-ulong ,(first index-forms))
        ;; Matrix / tensor: Horner only, no offset
        (let ((acc `(to-ulong ,(first index-forms))))
          (loop for k from 1 below n
                do (setf acc `(+ (* ,acc (~ (extents~ ,target-sym) ,k))
                                 (to-ulong ,(nth k index-forms)))))
          acc))))




(defun %build-tensor-compact-offset-flat-index-form (target-sym index-forms)
  "Builds the :compact-offset flat-index form — Horner on extents plus offset sum.
   Strides are ignored (compact layout), but per-dimension offsets are read.
   N=1: flat = offset[0] + i_0
   N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1}) + sum(offset[k])"
  (let ((n (length index-forms)))
    (if (= n 1)
        `(+ (~ (offset~ ,target-sym) 0)
            (to-ulong ,(first index-forms)))
        (let ((horner `(to-ulong ,(first index-forms)))
                 (offset-sum (reduce (lambda (a b) `(+ ,a ,b))
                                     (loop for k from 0 below n
                                           collect `(~ (offset~ ,target-sym) ,k)))))
          (loop for k from 1 below n
                do (setf horner `(+ (* ,horner (~ (extents~ ,target-sym) ,k))
                                    (to-ulong ,(nth k index-forms)))))
          `(+ ,horner ,offset-sum)))))

(defun analyze-aref-expression (expr env context location)
  "Analyzes (~ target [index...]) or (~ref~ ...) expressions.
   Tensor path dispatches on resolved :align:
     :compact        → %build-tensor-compact-flat-index-form  (no offset, no stride)
     :compact-offset → %build-tensor-compact-offset-flat-index-form (offset, no stride)
     :strided / NIL  → %build-tensor-flat-index-form (offset + stride, safe fallback)"
  (let* ((op          (first expr))
         (target-sym  (if (symbolp (second expr)) (second expr) nil))
         (array-node  (analyze-expression (second expr) env context (append location '(1))))
         (index-expr  (third expr))
         (index-node  (if index-expr
                          (analyze-expression index-expr env context (append location '(2)))
                          (make-semantic-literal :value-type 'int :value 0
                                                 :source-location location)))
         (array-type  (semantic-node-type array-node))
         (elem-type   (get-array-element-type array-type)))

    ;; Guard: no read from &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
      (let ((binding (find-variable-in-env target-sym env)))
        (when (and binding (eq (parameter-def-kind binding) :out))
          (error 'crisp-illegal-access-error
            :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only."
                             target-sym)
            :source-location location))))

    (if elem-type
        (progn
          ;; Guard: void element type
          (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "VOID"))
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "T"))
                             (and (consp elem-type)
                                  (let ((head (first elem-type)))
                                    (or (eq head 'void) (eq head 'T)
                                        (and (symbolp head)
                                             (string-equal (symbol-name head) "VOID"))))))))
            (when is-void
              (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

          (let ((tensor-n (%get-tensor-arity array-type)))
            (if (and tensor-n target-sym)

                ;; ── Tensor path ──────────────────────────────────────────────
                (let* ((index-forms (cddr expr)))
                  (unless (= (length index-forms) tensor-n)
                    (error "Tensor ~a requires ~a index~:p (arity ~a), got ~a."
                           target-sym tensor-n tensor-n (length index-forms)))
                  (let* ((align      (%get-tensor-align array-type))
                         (flat-form  (cond
                                       ((eq align :compact)
                                        (log:debug "AREF compact path (no offset): ~a (N=~a)" target-sym tensor-n)
                                        (%build-tensor-compact-flat-index-form target-sym index-forms))
                                       ((eq align :compact-offset)
                                        (log:debug "AREF compact-offset path: ~a (N=~a)" target-sym tensor-n)
                                        (%build-tensor-compact-offset-flat-index-form target-sym index-forms))
                                       (t
                                        (log:debug "AREF strided path: ~a (align=~s)" target-sym align)
                                        (%build-tensor-flat-index-form target-sym index-forms))))
                         (flat-node  (analyze-expression flat-form env context location))
                         (brand-def  (and (not (eq *analysis-access-mode* :write))
                                          (not (consp elem-type))
                                          (find-brand-for-owner 'value-t array-type)))
                         (is-rw      (and brand-def
                                          (let ((owner (brand-definition-owner-struct brand-def)))
                                            (and (symbolp owner)
                                                 (search "READ-WRITE" (symbol-name owner))))))
                         (resolved-type (if (and is-rw (brand-active-p brand-def))
                                            (resolve-brand-type 'value-t target-sym elem-type)
                                            elem-type)))
                    (make-semantic-aref :type resolved-type
                                        :array-node array-node
                                        :index-node flat-node
                                        :source-location location)))

                ;; ── Cell / array path: single index, brand-aware (unchanged) ──
                (let* ((cell-type    array-type)
                       (brand-def    (and target-sym
                                          (not (eq *analysis-access-mode* :write))
                                          (not (consp elem-type))
                                          (find-brand-for-owner 'value-t cell-type)))
                       (is-rw-cell   (and brand-def
                                          (let ((owner (brand-definition-owner-struct brand-def)))
                                            (and (symbolp owner)
                                                 (search "READ-WRITE" (symbol-name owner))))))
                       (resolved-type (if (and is-rw-cell (brand-active-p brand-def))
                                          (progn
                                            (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a [elem: ~a]"
                                                      cell-type target-sym elem-type)
                                            (resolve-brand-type 'value-t target-sym elem-type))
                                          elem-type)))
                  (make-semantic-aref :type resolved-type
                                      :array-node array-node
                                      :index-node index-node
                                      :source-location location)))))

        ;; Fallback: not a known array/cell/tensor type → try as overloadable call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))



(defun analyze-set!-expression (expr env context location)
  "Analyzes a (set! target value) expression.
   Enforces struct and array immutability at kernel boundary."
  (let* ((target-form (second expr))
         (value-form  (third expr))
         (value-node  (analyze-expression value-form env context (append location '(2)))))

    (cond
     ;; Case 1: Simple variable assignment  (set! x v)
     ((symbolp target-form)
       (let ((var-info (find-variable-in-env target-form env)))
         (unless var-info
           (error 'crisp-unknown-variable :name target-form :source-location location))
         (let ((var-type (parameter-def-type var-info))
               (val-type (semantic-node-type value-node)))
           (unless (types-compatible-p val-type var-type)
             (error 'crisp-type-error :expected var-type :inferred val-type
                    :source-location location)))
         (make-semantic-set!
          :target-node (make-semantic-var-read
                        :name target-form
                        :type (parameter-def-type var-info)
                        :source-location location)
          :value-node value-node
          :source-location location)))

     ;; Case 2: Function call / struct accessor
     ((and (listp target-form) (>= (length target-form) 1) (symbolp (first target-form)))
       (let* ((op           (first target-form))
              (op-args      (rest target-form))
              (arg-nodes    (loop for arg in op-args
                                  for i from 1
                                  collect (analyze-expression arg env context
                                                              (append location (list 1 i)))))
              (all-arg-nodes  (append arg-nodes (list value-node)))
              (all-arg-types  (mapcar #'semantic-node-type all-arg-nodes))
              (full-setter-name (intern (format nil "~a_SET!" op) (symbol-package op)))
              (signatures   (append (gethash op *function-table*)
                                    (gethash full-setter-name *function-table*)))
              (match        (find-if (lambda (sig)
                                       (types-list-compatible-p
                                        all-arg-types
                                        (mapcar #'parameter-def-type
                                                (function-signature-parameters sig))))
                                     signatures)))

         ;; Try template instantiation if no direct match
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*)
                                  full-setter-name op)))
             (when (gethash template-op *template-registry*)
               (ensure-template-instantiation
                template-op all-arg-types
                (lambda (f l) (declare (ignore l)) (eval f)))
               (setf signatures (append (gethash op *function-table*)
                                        (gethash full-setter-name *function-table*)))
               (setf match (find-if
                            (lambda (sig)
                              (types-list-compatible-p
                               all-arg-types
                               (mapcar #'parameter-def-type
                                       (function-signature-parameters sig))))
                            signatures)))))

         (cond
          ;; Sub-case 2a: Found an overloaded setter function -> call it.
          (match
            (make-semantic-call
             :name (function-signature-name match)
             :type (function-signature-return-types match)
             :args all-arg-nodes
             :signature match
             :source-location location))

          ;; Sub-case 2b: Expression analyzer — only if result is an assignable lvalue.
          ((gethash op *expression-analyzers*)
            (let ((target-node
                   (let ((*analysis-access-mode* :write))
                     (analyze-expression target-form env context (append location '(1))))))
              (if (or (semantic-extract-value-p target-node)
                      (semantic-aref-p target-node))
                  (progn
                    ;; Array boundary immutability check (errors 01 and 02)
                    (when (semantic-aref-p target-node)
                      (%check-aref-boundary-mutation target-node location))
                    (make-semantic-set!
                     :target-node target-node
                     :value-node value-node
                     :source-location location))
                  ;; Not an assignable lvalue — fall through to Sub-case 2c.
                  (let* ((op-name (symbol-name op))
                         (is-accessor
                          (or (alexandria:ends-with #\~ op-name)
                              (and (alexandria:starts-with #\~ op-name)
                                   (alexandria:ends-with #\~ op-name)))))
                    (unless is-accessor
                      (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                             target-form))
                    (unless (= (length arg-nodes) 1)
                      (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                             op (length arg-nodes)))
                    (let* ((clean-name  (string-trim "~" op-name))
                           (member-sym  (intern clean-name (symbol-package op)))
                           (struct-node (first arg-nodes))
                           (struct-type (semantic-node-type struct-node)))
                      (unless (or (semantic-var-read-p struct-node)
                                  (semantic-aref-p struct-node))
                        (error "Cannot set member of non-variable/non-reference struct form: ~a"
                               (second target-form)))
                      (%check-struct-boundary-mutation struct-node env context location)
                      (let ((update-node
                             (make-semantic-struct-member-update
                              :type struct-type
                              :struct-node struct-node
                              :member-index (get-struct-member-index struct-type member-sym)
                              :value-node value-node
                              :source-location location)))
                        (make-semantic-set!
                         :target-node struct-node
                         :value-node update-node
                         :source-location location)))))))

          ;; Sub-case 2c: Struct member update (legacy accessor logic).
          (t
            (let* ((op-name (symbol-name op))
                   (is-accessor
                    (or (alexandria:ends-with #\~ op-name)
                        (and (alexandria:starts-with #\~ op-name)
                             (alexandria:ends-with #\~ op-name)))))
              (unless is-accessor
                (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                       target-form))
              (unless (= (length arg-nodes) 1)
                (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                       op (length arg-nodes)))
              (let* ((clean-name  (string-trim "~" op-name))
                     (member-sym  (intern clean-name (symbol-package op)))
                     (struct-node (first arg-nodes))
                     (struct-type (semantic-node-type struct-node)))
                (unless (or (semantic-var-read-p struct-node)
                            (semantic-aref-p struct-node))
                  (error "Cannot set member of non-variable/non-reference struct form: ~a"
                         (second target-form)))
                (%check-struct-boundary-mutation struct-node env context location)
                (let ((update-node
                       (make-semantic-struct-member-update
                        :type struct-type
                        :struct-node struct-node
                        :member-index (get-struct-member-index struct-type member-sym)
                        :value-node value-node
                        :source-location location)))
                  (make-semantic-set!
                   :target-node struct-node
                   :value-node update-node
                   :source-location location))))))))

     (t (error "Invalid set! target structure: ~a" target-form)))))



(defun analyze-incomplete-type-accessor (op expr env context location)
  "Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).
   Returns a semantic-node (literal) if resolved, or NIL if not applicable.

   Fix: float values now return value-type 'float instead of 'quote."
  (let ((op-name (symbol-name op)))
    (when (and (> (length op-name) 1) (alexandria:ends-with #\~ op-name))
          (let* ((member-name (intern (string-trim "~" op-name) (symbol-package op)))
                 (obj-expr (second expr)))
            (when obj-expr
                  (let* ((obj-node (analyze-expression obj-expr env context (append location '(1))))
                         (obj-type (semantic-node-type obj-node)))
                    (when (and (consp obj-type) (valid-type-p obj-type))
                          (let* ((canon (canonicalize-type-specifier obj-type))
                                 (base (first canon))
                                 (params (rest canon)))
                            (log:info "  ObjType: ~s Canon: ~s Params: ~s" obj-type canon params)
                            (when (or (gethash base *crisp-structs*) (gethash base *crisp-types*))
                                  (let ((kw (intern (symbol-name member-name) "KEYWORD")))
                                    (let ((val (getf params kw)))
                                      (when val
                                            (cond
                                             ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
                                             ((symbolp val)  (make-semantic-literal :value-type 'symbol  :value val :source-location location))
                                             ((integerp val) (make-semantic-literal :value-type 'int     :value val :source-location location))
                                             ((floatp val)   (make-semantic-literal :value-type 'float   :value val :source-location location))
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

(defun analyze-%make-ct-array (expr env context location)
  "Analyzes (%make-ct-array elem-type val0 val1 ... valN-1).
   elem-type is taken as a literal type symbol (not evaluated).
   Returns a semantic-ct-array node of type (array elem-type N).
   Used internally by marshall-tensor to assemble offset/strides/extents fields."
  (let* ((elem-type (second expr))
         (val-exprs (cddr expr))
         (n (length val-exprs)))
    (unless (> n 0)
      (error "%make-ct-array requires at least one value argument"))
    (let* ((val-nodes (loop for v in val-exprs
                            for i from 0
                            collect (analyze-expression v env context (append location (list i)))))
           (array-type (list 'array elem-type n)))
      (dolist (vn val-nodes)
        (let ((vt (semantic-node-type vn)))
          (unless (types-equivalent-p vt elem-type)
            (error "%make-ct-array: expected element type ~a but got ~a" elem-type vt))))
      (make-semantic-ct-array
       :type array-type
       :val-nodes val-nodes
       :source-location location))))


(defun %extract-scratch-size-expr (op args)
  "Extracts the user-supplied size expression from make-scratch-* args."
  (case op
    ((make-scratch-vector make-scratch-matrix)
     ;; (make-scratch-vector elem-or-alias size-expr &key ...)
     (second args))
    (make-scratch-tensor
     (let* ((arg1 (first args))
            (arg2 (second args))
            ;; Form 1 if arg2 is an integer and arg1 is not a tensor alias
            (is-tensor-alias (and (symbolp arg1)
                                  (let ((resolved (resolve-type-alias arg1)))
                                    (and (consp resolved)
                                         (member (symbol-name (first resolved))
                                                 '("TENSOR" "VECTOR" "MATRIX")
                                                 :test #'string-equal)))))
            (form-1-p (and (integerp arg2) (not is-tensor-alias))))
       (if form-1-p
           (third args)    ; (make-scratch-tensor elem N size-expr ...)
           (second args)))) ; (make-scratch-tensor alias size-expr ...)
    (t nil)))


(defun %scratch-tensor-canonical-spec (op args)
  "Resolves the type arguments of a make-scratch-{vector,matrix,tensor} form
   to a canonical (tensor elem N addr access align) spec.

   OP is the operator symbol.  ARGS is the rest of the form (everything after
   the operator).  Returns the canonical spec or NIL if resolution fails.

   Dual-syntax disambiguation for make-scratch-tensor:
     - If the second positional arg (after the first type-ish arg) is an integer
       AND the first arg is NOT a registered tensor/vector/matrix type alias,
       we treat it as Form 1: (elem-type N sizeExpr ...).
     - Otherwise Form 2: (tensor-type sizeExpr ...)."
  (unless args
    (return-from %scratch-tensor-canonical-spec nil))
  (let* ((op-name (symbol-name op))
         ;; Implicit N from the operator name for vector/matrix
         (implicit-n (cond ((string-equal op-name "MAKE-SCRATCH-VECTOR") 1)
                           ((string-equal op-name "MAKE-SCRATCH-MATRIX") 2)
                           (t nil))) ; tensor: N from args
         (arg1 (first args)))

    (cond
      ;; ── make-scratch-vector / make-scratch-matrix ─────────────────────────
      ;; N is fixed by the operator; arg1 is elem-type or tensor-type alias.
      (implicit-n
       (let* ((is-tensor-alias
               ;; A def-type alias is in *crisp-type-aliases* (not *crisp-types*),
               ;; so we check resolve-type-alias directly — it returns the original
               ;; spec list for aliases whose value is a storage-handle type.
               (and (symbolp arg1)
                    (let ((resolved (resolve-type-alias arg1)))
                      (and (consp resolved)
                           (member (symbol-name (first resolved))
                                   '("TENSOR" "VECTOR" "MATRIX")
                                   :test #'string-equal)))))
              (raw-spec
               (if is-tensor-alias
                   ;; Form 2: use the alias directly
                   (resolve-type-alias arg1)
                   ;; Form 1: wrap bare element type
                   (list 'tensor arg1 implicit-n))))
         (expand-storage-handle-type-specifier
          ;; Normalize: force address-space :local (scratch default) if not set
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))   ; only elem + N, no addr/access/align yet
              (append raw-spec '(:address-space :local :access :read-write :align :compact))
              raw-spec))))

      ;; ── make-scratch-tensor ───────────────────────────────────────────────
      ;; Disambiguate Form 1 vs Form 2 by inspecting the second positional arg.
      (t
       (let* ((arg2 (second args))
              ;; Form 1 if arg2 is an integer AND arg1 is not a tensor type alias
              (is-tensor-alias
               (and (symbolp arg1)
                    (let ((resolved (resolve-type-alias arg1)))
                      (and (consp resolved)
                           (member (symbol-name (first resolved))
                                   '("TENSOR" "VECTOR" "MATRIX")
                                   :test #'string-equal)))))
              (form-1-p (and (integerp arg2) (not is-tensor-alias)))
              (raw-spec
               (if form-1-p
                   ;; Form 1: (make-scratch-tensor elem N sizeExpr ...)
                   (list 'tensor arg1 arg2)
                   ;; Form 2: (make-scratch-tensor tensor-type sizeExpr ...)
                   (if is-tensor-alias
                       (resolve-type-alias arg1)
                       (list 'tensor arg1)))))     ; degenerate: will error at expand
         (expand-storage-handle-type-specifier
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))
              (append raw-spec '(:address-space :local :access :read-write :align :compact))
              raw-spec)))))))

(defun %register-scratch-tensor-implicit (op args)
  "Shared logic for scan-operator methods on make-scratch-{vector,matrix,tensor}.
   Marks the current function as an originator and records the canonical-list type
   in *implicit-arg-map* and the size-expr in *implicit-scratch-size-expr-map*."
  (setf *scan-is-originator* t)
  (when args
    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (when canonical-spec
        (let* ((binding-name (or (compiler-context-current-binding-name *compiler-context*)
                                 '__storage))
               (fn-name (compiler-context-scanning-function-name *compiler-context*))
               (counter (incf *scratch-cell-counter*))
               (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
               (unique-name (intern unique-name-str (symbol-package binding-name)))
               (size-expr (%extract-scratch-size-expr op args)))

          (log:info "Pass 1: ~a ~a -> implicit: ~a (type: ~a, size-expr: ~a)"
                    op binding-name unique-name canonical-spec size-expr)

          (push (cons unique-name canonical-spec) (gethash fn-name *implicit-arg-map*))
          (when size-expr
            (setf (gethash unique-name *implicit-scratch-size-expr-map*) size-expr)))))))

(defun analyze-scratch-tensor-expression (expr env context location)
  "Analyzes a (make-scratch-{vector,matrix,tensor} ...) expression.
   Stores canonical-list type in *implicit-arg-map* and size-expr in
   *implicit-scratch-size-expr-map*."
  (declare (ignore env))
  (let* ((op (first expr))
         (args (rest expr)))

    (unless args
      (error "Malformed ~a form: expected at least a type argument." op))

    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (unless canonical-spec
        (error "Could not resolve type spec for ~a form: ~a" op expr))

      ;; Register in *implicit-arg-map* if not already there (single-pass or two-pass pass 2).
      (let* ((fn-name (compiler-context-current-compiling-function context))
             (implicit-name (or (compiler-context-current-binding-name context) '__storage))
             (existing (gethash fn-name *implicit-arg-map*))
             (size-expr (%extract-scratch-size-expr op args)))
        (if existing
            (log:warn "Structs: implicit-arg-map already has entries for ~a: ~a (adding ~a)"
                      fn-name existing implicit-name)
            (progn
              (log:warn "Structs: Detected ~a in ~a (implicit name: ~a, type: ~a, size-expr: ~a)"
                        op fn-name implicit-name canonical-spec size-expr)
              (setf (gethash fn-name *implicit-arg-map*)
                    (list (cons implicit-name canonical-spec)))
              (when size-expr
                (setf (gethash implicit-name *implicit-scratch-size-expr-map*) size-expr)))))

      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (from ~a)" canonical-spec expr))

      (log:debug "analyze-scratch-tensor-expression: ~a -> ~a" op canonical-spec)

      (make-semantic-literal :value-type canonical-spec
                             :value nil
                             :source-location location))))



;;; ============================================================
;;; 078-storage-handle-reinterpretation
;;; make-cell / make-vector / make-matrix / make-tensor
;;; ============================================================

;;; ── helpers ─────────────────────────────────────────────────


(defun %mv-source-head (canon)
  "Return the head keyword (:cell or :tensor) from a canonical type, or NIL."
  (when (consp canon)
    (let ((h (symbol-name (first canon))))
      (cond ((string-equal h "CELL")   :cell)
            ((string-equal h "TENSOR") :tensor)
            (t nil)))))

(defun %mv-source-elem (canon)
  "Return the element-type symbol from a canonical storage handle type."
  (second canon))

(defun %mv-source-addr (canon)
  "Return the address-space keyword from a canonical storage handle type."
  (cond ((eq (%mv-source-head canon) :cell)   (third canon))
        ((eq (%mv-source-head canon) :tensor)  (fourth canon))
        (t :global)))

(defun %mv-source-access (canon)
  "Return the access keyword from a canonical storage handle type."
  (cond ((eq (%mv-source-head canon) :cell)   (fourth canon))
        ((eq (%mv-source-head canon) :tensor)  (fifth canon))
        (t :read-write)))

(defun %mv-source-align (canon)
  "Return the :align keyword from a canonical storage handle type (tensors only)."
  (when (eq (%mv-source-head canon) :tensor)
    (sixth canon)))

(defun %mv-is-struct-elem (elem-type)
  "Returns T if ELEM-TYPE is a registered def-struct type."
  (let ((ct (gethash elem-type *crisp-types*)))
    (and ct (eq (crisp-type-category ct) :struct))))

(defun %mv-parse-kwargs (kwarg-list)
  "Parse a flat keyword-arg list like (:offset 2 :length 5 :major :row).
   Returns a plist."
  (let ((result '()))
    (loop for (k v) on kwarg-list by #'cddr
             when (keywordp k) do (setf (getf result k) v))
    result))

(defun %mv-eval-integer (form)
  "Evaluate a compile-time integer form (bare integer or quoted integer).
   Returns an integer or NIL."
  (cond ((integerp form) form)
        ((and (consp form) (eq (first form) 'quote) (integerp (second form)))
         (second form))
        (t nil)))

(defun %mv-eval-list (form)
  "Evaluate a compile-time list form like '(2 3 4) or (2 3 4) for extents/strides.
   Returns a list of integers or NIL."
  (cond ((and (consp form) (eq (first form) 'quote) (listp (second form)))
         (second form))
        ((and (consp form) (every #'integerp form))
         form)
        (t nil)))

;;; ── compile-time restrictions ────────────────────────────────

(defun %mv-check-restrictions (op src-canon new-elem location)
  "Enforce compile-time restrictions for view constructors.
   Signals a compiler-error on violation."
  (let* ((src-elem  (%mv-source-elem src-canon))
             (same-elem (or (eq src-elem new-elem)
                            (string-equal (symbol-name src-elem)
                                          (symbol-name new-elem))))
             (src-align (%mv-source-align src-canon)))
    (unless same-elem
      ;; Restriction 1: source element cannot be a struct type
      (when (%mv-is-struct-elem src-elem)
        (error "~a: Cannot reinterpret a struct-element storage handle to a different element type ~a (source element type ~a is a struct)" op new-elem src-elem))
      ;; Restriction 2: source alignment cannot be :strided
      (when (member src-align '(:strided strided) :test #'string-equal)
        (error "~a: Cannot reinterpret element type on a :strided storage handle (source is ~a, new type is ~a). Reinterpreting :strided views is mathematically undefined." op src-elem new-elem)))))

;;; ── result type computation ──────────────────────────────────

(defun %mv-result-align (src-align explicit-strides-p col-major-p)
  "Determine result alignment given source alignment and constructor options."
  (if (or explicit-strides-p col-major-p)
      :strided
      (or src-align :compact)))

(defun %mv-result-cell-type (new-elem addr access)
  "Build canonical cell result type."
  `(cell ,new-elem ,addr ,access))

#|
(defun %mv-result-tensor-type (new-elem rank addr access align)
  "Build canonical tensor result type."
  `(tensor ,new-elem ,rank ,addr ,access ,align))
  |#


(defun %mv-result-tensor-type (new-elem rank addr access align &optional (ct :last))
  "Build canonical tensor result type (7-tuple)."
  `(tensor ,new-elem ,rank ,addr ,access ,align ,ct))

;;; ── compute strides list (compile-time) ──────────────────────

(defun %mv-row-major-strides (extents)
  "Compute row-major strides for given extents list.
   Innermost stride = 1; stride[k] = product(extents[k+1..N-1])."
  (let* ((n (length extents))
             (strides (make-list n :initial-element 1)))
    (loop for k from (- n 2) downto 0
             do (setf (nth k strides)
                      (* (nth (1+ k) strides) (nth (1+ k) extents))))
    strides))

(defun %mv-col-major-strides (extents)
  "Compute col-major strides for a 2D matrix with extents [height width].
   stride_row=1, stride_col=height."
  (let ((height (first extents)))
    (list 1 height)))

;;; ── main analyzer ────────────────────────────────────────────

(defun analyze-make-view-expression (expr env context location)
  "Analyzes make-cell / make-vector / make-matrix / make-tensor.
   Extended for 097-contiguous-term: make-matrix passes ct=:first for :major :col."
  (let* ((op       (first expr))
         (args     (rest expr))
         (src-expr (first args))
         (src-node (analyze-expression src-expr env context (append location '(1))))
         (src-type (semantic-node-type src-node))
         (src-canon (%mv-resolve-src-type src-type)))

    (unless src-canon
      (error "~a: Cannot resolve source type ~a to a storage handle type" op src-type))
    (unless (%mv-source-head src-canon)
      (error "~a: Source type ~a is not a storage handle (cell/vector/matrix/tensor)" op src-type))

    (ecase op

      (make-cell
       (let* ((new-elem  (second args))
              (kwargs    (%mv-parse-kwargs (nthcdr 2 args)))
              (offset    (or (%mv-eval-integer (getf kwargs :offset)) 0))
              (addr      (%mv-source-addr src-canon))
              (access    (%mv-source-access src-canon)))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-cell-type new-elem addr access)
          :source-node src-node
          :element-type new-elem
          :rank        0
          :offset      offset
          :length      1
          :extents     nil
          :strides     nil
          :major       :row
          :source-location location)))

      (make-vector
       (let* ((new-elem  (second args))
              (kwargs    (%mv-parse-kwargs (nthcdr 2 args)))
              (offset    (or (%mv-eval-integer (getf kwargs :offset)) 0))
              (length    (%mv-eval-integer (getf kwargs :length)))
              (addr      (%mv-source-addr src-canon))
              (access    (%mv-source-access src-canon))
              (src-align (%mv-source-align src-canon))
              (align     (%mv-result-align src-align nil nil)))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 1 addr access align :last)
          :source-node src-node
          :element-type new-elem
          :rank        1
          :offset      offset
          :length      length
          :extents     (when length (list length))
          :strides     nil
          :major       :row
          :source-location location)))

      (make-matrix
       (let* ((new-elem  (second args))
              (width     (%mv-eval-integer (third args)))
              (height    (%mv-eval-integer (fourth args)))
              (kwargs    (%mv-parse-kwargs (nthcdr 4 args)))
              (offset    (or (%mv-eval-integer (getf kwargs :offset)) 0))
              (major-kw  (or (getf kwargs :major) :row))
              (strides-form (getf kwargs :strides))
              (strides   (%mv-eval-list strides-form))
              (explicit-strides-p (not (null strides)))
              (col-p     (member major-kw '(:col col) :test #'string-equal))
              (extents   (list height width))
              (result-strides
               (cond (explicit-strides-p strides)
                     (col-p (%mv-col-major-strides extents))
                     (t     (%mv-row-major-strides extents))))
              (length    (* width height))
              (addr      (%mv-source-addr src-canon))
              (access    (%mv-source-access src-canon))
              (src-align (%mv-source-align src-canon))
              (align     (%mv-result-align src-align explicit-strides-p col-p))
              (ct        (if col-p :first :last)))
         (unless (and width height)
           (error "make-matrix: width and height must be compile-time integer literals"))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 2 addr access align ct)
          :source-node src-node
          :element-type new-elem
          :rank        2
          :offset      offset
          :length      length
          :extents     extents
          :strides     result-strides
          :major       (if col-p :col :row)
          :source-location location)))

      (make-tensor
       (let* ((new-elem     (second args))
              (extents-form (third args))
              (extents      (%mv-eval-list extents-form))
              (kwargs       (%mv-parse-kwargs (nthcdr 3 args)))
              (offset       (or (%mv-eval-integer (getf kwargs :offset)) 0))
              (strides-form (getf kwargs :strides))
              (strides      (%mv-eval-list strides-form))
              (explicit-strides-p (not (null strides)))
              (rank         (when extents (length extents)))
              (result-strides (if explicit-strides-p strides
                                  (when extents (%mv-row-major-strides extents))))
              (length       (when extents (reduce #'* extents)))
              (addr         (%mv-source-addr src-canon))
              (access       (%mv-source-access src-canon))
              (src-align    (%mv-source-align src-canon))
              (align        (%mv-result-align src-align explicit-strides-p nil)))
         (unless extents
           (error "make-tensor: extents list must be a compile-time literal list like '(2 3 4)"))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem rank addr access align :last)
          :source-node src-node
          :element-type new-elem
          :rank        rank
          :offset      offset
          :length      length
          :extents     extents
          :strides     result-strides
          :major       :row
          :source-location location))))))



(defun register-struct-analyzers ()
  "Registers all struct/storage-handle expression analyzers.
   Extends the original to add make-cell/vector/matrix/tensor view constructors."
  (def-expression-analyzer %construct-struct analyze-struct-construction)
  (def-expression-analyzer %extract-struct-member analyze-extract-struct-member-expression)
  (def-expression-analyzer %insert-struct-member analyze-insert-struct-member-expression)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)
  (def-expression-analyzer make-scratch-vector analyze-scratch-tensor-expression)
  (def-expression-analyzer make-scratch-matrix analyze-scratch-tensor-expression)
  (def-expression-analyzer make-scratch-tensor analyze-scratch-tensor-expression)
  (def-expression-analyzer %make-ct-array analyze-%make-ct-array)

  (def-expression-analyzer aref analyze-aref-expression)
  (def-expression-analyzer ~ref~ analyze-aref-expression)
  (def-expression-analyzer ~ analyze-aref-expression)

  (def-expression-analyzer set! analyze-set!-expression)

  ;; view constructors (078)
  (def-expression-analyzer make-cell   analyze-make-view-expression)
  (def-expression-analyzer make-vector analyze-make-view-expression)
  (def-expression-analyzer make-matrix analyze-make-view-expression)
  (def-expression-analyzer make-tensor analyze-make-view-expression))


(defun %083-require-2d-tensor (raw-type location)
  "Validates that RAW-TYPE is a 2D tensor and returns the canonical 6-tuple list.
   Unwraps single-element list wrappers and mangled symbols.
   Signals crisp-compiler-error if the type is not a 2D tensor."
  (let* ((resolved (resolve-type-alias raw-type))
         (resolved (if (and (listp resolved) (= (length resolved) 1) (listp (first resolved)))
                       (first resolved)
                       resolved))
         (canon (cond
                  ;; Already in canonical list form
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (string-equal (symbol-name (first resolved)) "TENSOR"))
                   resolved)
                  ;; Mangled symbol form — unmangle it
                  ((symbolp resolved)
                   (let ((u (unmangle-template-struct-name resolved)))
                     (if (and (listp u) (symbolp (first u))
                              (string-equal (symbol-name (first u)) "TENSOR"))
                         u nil)))
                  ;; Sugar form like (matrix ...)
                  ((consp resolved)
                   (let ((exp (expand-storage-handle-type-specifier resolved)))
                     (if (and (listp exp) (symbolp (first exp))
                              (string-equal (symbol-name (first exp)) "TENSOR"))
                         exp nil)))
                  (t nil))))
    (unless (and canon (eql (third canon) 2))
      (error 'crisp-compiler-error
             :message (format nil "Expected a 2D tensor (matrix) type, got ~a" raw-type)
             :source-location location))
    canon))




(defun %get-tensor-ct (canon)
  "Extracts the :contiguous-term keyword (7th element, index 6) from a
   canonical tensor type tuple, defaulting to :last when absent."
  (if (and (listp canon) (>= (length canon) 7))
      (nth 6 canon)
      :last))

(defun analyze-transpose-expression (expr env context location)
  "Analyzes (transpose M) for 2D tensors.
   Result type: (tensor elem 2 addr access :strided src-ct)."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "transpose expects exactly 1 argument: (transpose matrix)"
           :source-location location))
  (let* ((src-node (analyze-expression (second expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon))
         (access   (fifth canon))
         (src-ct   (%get-tensor-ct canon)))
    (make-semantic-stride-view
     :op :transpose
     :source-node src-node
     :index-node nil
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 2 addr access :strided src-ct)
     :source-location location)))

(defun analyze-col-expression (expr env context location)
  "Analyzes (col index M) for 2D tensors.
   Result type: (tensor elem 1 addr access :strided :last)."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message "col expects exactly 2 arguments: (col index matrix)"
           :source-location location))
  (let* ((idx-node (analyze-expression (second expr) env context location))
         (src-node (analyze-expression (third expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon))
         (access   (fifth canon)))
    (make-semantic-stride-view
     :op :col
     :source-node src-node
     :index-node idx-node
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr access :strided :last)
     :source-location location)))

;; analyze-row-expression — 1D row result; :last (single dim, contiguity trivial)
(defun analyze-row-expression (expr env context location)
  "Analyzes (row index M) for 2D tensors.
   Result type: (tensor elem 1 addr access :strided :last)."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message "row expects exactly 2 arguments: (row index matrix)"
           :source-location location))
  (let* ((idx-node (analyze-expression (second expr) env context location))
         (src-node (analyze-expression (third expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon))
         (access   (fifth canon)))
    (make-semantic-stride-view
     :op :row
     :source-node src-node
     :index-node idx-node
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr access :strided :last)
     :source-location location)))

;; src/analysis/structs.lisp
(defun analyze-transpose-bang-expression (expr env context location)
  "Analyzes (transpose! M). Expands to (set! M (transpose M)).
   Signals a type error if M's type is :compact (result is :strided, incompatible)."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "transpose! expects exactly 1 argument: (transpose! matrix)"
           :source-location location))
  (let ((m (second expr)))
    (analyze-expression `(set! ,m (transpose ,m)) env context location)))


