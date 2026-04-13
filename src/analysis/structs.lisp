;;; src/analysis/structs.lisp
(in-package :crisp.compiler)
 

(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, cell, or tensor type.
   Returns NIL if unknown.
   Handles single-element list wrapping, e.g. ((array float 4)) → (array float 4)."
  (let* ((type (if (and (listp type) (= (cl:length type) 1) (listp (cl:first type)))
                   (cl:first type)
                   type))
         (type (resolve-type-alias type)))
    (cond
     ((listp type)
      (let ((base (cl:first type)))
        (if (and (symbolp base)
                 (member (symbol-name base)
                         '("CELL" "VECTOR" "MATRIX" "TENSOR" "PTR" "ARRAY" "POINTER")
                         :test #'string-equal))
            (cl:second type)
            nil)))
     ((symbolp type)
      (let ((unmangled (unmangle-template-struct-name type)))
        (if (and (consp unmangled)
                 (symbolp (cl:first unmangled))
                 (member (symbol-name (cl:first unmangled))
                         '("CELL" "TENSOR" "VECTOR" "MATRIX")
                         :test #'string-equal))
            (cl:second unmangled)
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
  (cl:let* ((resolved (resolve-type-alias type-name))
            (base (get-type-base resolved))
            (crisp-type (cl:when (symbolp base) (gethash base *crisp-types*))))
    (cl:when (and crisp-type
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
                                 (cl:let ((brand-def (is-brand-type-p expected-type)))
                                   (if brand-def
                                       ;; Branded member: check numeric compatibility with base type
                                       (cl:let* ((base-type (brand-definition-base-type brand-def))
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
    ((and (listp type) (symbolp (cl:first type)))
     (string-equal (symbol-name (cl:first type)) "TENSOR"))
    ((symbolp type)
     (let ((name (symbol-name type)))
       (and (>= (cl:length name) 7)
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
      ((and (listp type) (symbolp (cl:first type))
            (string-equal (symbol-name (cl:first type)) "TENSOR"))
       (coerce-n (cl:third type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (cl:first unmangled))
                    (string-equal (symbol-name (cl:first unmangled)) "TENSOR"))
           (coerce-n (cl:third unmangled)))))
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
                 (* ,(coerce-index (cl:nth k index-forms)) (~ (strides~ ,target-sym) ,k)))))
    (if (= (cl:length index-forms) 1)
        (dim-term 0)
        (reduce (lambda (acc k) `(+ ,acc ,(dim-term k)))
                (loop for k from 1 below (cl:length index-forms) collect k)
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
      ((and (listp type) (symbolp (cl:first type))
            (string-equal (symbol-name (cl:first type)) "TENSOR"))
       (coerce-aln (cl:sixth type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (cl:first unmangled))
                    (string-equal (symbol-name (cl:first unmangled)) "TENSOR"))
           (coerce-aln (cl:sixth unmangled)))))
      (t nil))))


(defun %build-tensor-compact-flat-index-form (target-sym index-forms)
  "Builds the :compact flat-index form — Horner on extents only, NO offset reads.
   :compact guarantees all offsets are zero at the kernel boundary, so we skip them.
   N=1: flat = i_0
   N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1})"
  (let ((n (cl:length index-forms)))
    (if (= n 1)
        ;; Vector: just the index, cast to ulong
        `(to-ulong ,(cl:first index-forms))
        ;; Matrix / tensor: Horner only, no offset
        (cl:let ((acc `(to-ulong ,(cl:first index-forms))))
          (loop for k from 1 below n
                do (setf acc `(+ (* ,acc (~ (extents~ ,target-sym) ,k))
                                 (to-ulong ,(cl:nth k index-forms)))))
          acc))))




(defun %build-tensor-compact-offset-flat-index-form (target-sym index-forms)
  "Builds the :compact-offset flat-index form — Horner on extents plus offset sum.
   Strides are ignored (compact layout), but per-dimension offsets are read.
   N=1: flat = offset[0] + i_0
   N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1}) + sum(offset[k])"
  (let ((n (cl:length index-forms)))
    (if (= n 1)
        `(+ (~ (offset~ ,target-sym) 0)
            (to-ulong ,(cl:first index-forms)))
        (cl:let ((horner `(to-ulong ,(cl:first index-forms)))
                 (offset-sum (reduce (lambda (a b) `(+ ,a ,b))
                                     (loop for k from 0 below n
                                           collect `(~ (offset~ ,target-sym) ,k)))))
          (loop for k from 1 below n
                do (setf horner `(+ (* ,horner (~ (extents~ ,target-sym) ,k))
                                    (to-ulong ,(cl:nth k index-forms)))))
          `(+ ,horner ,offset-sum)))))

(defun analyze-aref-expression (expr env context location)
  "Analyzes (~ target [index...]) or (~ref~ ...) expressions.
   Tensor path dispatches on resolved :align:
     :compact        → %build-tensor-compact-flat-index-form  (no offset, no stride)
     :compact-offset → %build-tensor-compact-offset-flat-index-form (offset, no stride)
     :strided / NIL  → %build-tensor-flat-index-form (offset + stride, safe fallback)"
  (let* ((op          (cl:first expr))
         (target-sym  (if (symbolp (cl:second expr)) (cl:second expr) nil))
         (array-node  (analyze-expression (cl:second expr) env context (append location '(1))))
         (index-expr  (cl:third expr))
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
                                  (let ((head (cl:first elem-type)))
                                    (or (eq head 'void) (eq head 'T)
                                        (and (symbolp head)
                                             (string-equal (symbol-name head) "VOID"))))))))
            (when is-void
              (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

          (let ((tensor-n (%get-tensor-arity array-type)))
            (if (and tensor-n target-sym)

                ;; ── Tensor path ──────────────────────────────────────────────
                (let* ((index-forms (cddr expr)))
                  (unless (= (cl:length index-forms) tensor-n)
                    (error "Tensor ~a requires ~a index~:p (arity ~a), got ~a."
                           target-sym tensor-n tensor-n (cl:length index-forms)))
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
     ((and (listp target-form) (>= (length target-form) 1) (symbolp (cl:first target-form)))
       (let* ((op           (cl:first target-form))
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
                    (let* ((clean-name  (cl:string-trim "~" op-name))
                           (member-sym  (intern clean-name (symbol-package op)))
                           (struct-node (cl:first arg-nodes))
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
              (let* ((clean-name  (cl:string-trim "~" op-name))
                     (member-sym  (intern clean-name (symbol-package op)))
                     (struct-node (cl:first arg-nodes))
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

(defun register-struct-analyzers ()
  (def-expression-analyzer %construct-struct analyze-struct-construction)
  (def-expression-analyzer %extract-struct-member analyze-extract-struct-member-expression)
  (def-expression-analyzer %insert-struct-member analyze-insert-struct-member-expression)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)
  (def-expression-analyzer %make-ct-array analyze-%make-ct-array)

  (def-expression-analyzer aref analyze-aref-expression)
  (def-expression-analyzer ~ref~ analyze-aref-expression)
  (def-expression-analyzer ~ analyze-aref-expression)

  (def-expression-analyzer set! analyze-set!-expression))
