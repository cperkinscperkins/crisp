;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; =============================================================================
;; TENSOR SUPPORT
;; Six changes: align enum, register-builtins, expand-storage-handle-type-specifier,
;; get-array-element-type, analyze-aref-expression, generate-node-ir (semantic-aref).
;; Design record: tests/spec/064-tensor/discuss.md
;; =============================================================================


;; -----------------------------------------------------------------------------
;; Change 0: types-equivalent-p — package-agnostic cons-vs-cons comparison.
;; src/types/validation.lisp
;;
;; Problem: (array ulong 2) declared in :crisp-language context vs inferred from
;; strides~/extents~ accessor (registered in :crisp.compiler context). The symbols
;; print identically but fail cl:equal due to package differences.
;; Fix: Replace cl:equal with %type-spec-equal-p for the cons-cons case.
;; -----------------------------------------------------------------------------

(defun %type-atom-equal-p (a b)
  "Package-agnostic atom comparison for type specs.
   Symbols compared by name (string-equal); others compared by equal."
  (or (equal a b)
      (and (symbolp a) (symbolp b)
           (string-equal (symbol-name a) (symbol-name b)))))

(defun %type-spec-equal-p (t1 t2)
  "Recursive package-agnostic comparison of type spec trees.
   Used in types-equivalent-p for the cons-vs-cons case."
  (cond
    ((and (null t1) (null t2)) t)
    ((or (null t1) (null t2)) nil)
    ((and (consp t1) (consp t2))
     (and (%type-spec-equal-p (car t1) (car t2))
          (%type-spec-equal-p (cdr t1) (cdr t2))))
    (t (%type-atom-equal-p t1 t2))))

(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling.
   FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels
   before mangling comparison. This supports def-type aliases for any template type.
   FIX2: Use %type-spec-equal-p (package-agnostic) for cons-vs-cons case."
  (cl:let ((t1 (resolve-type-alias t1))
           (t2 (resolve-type-alias t2)))
    (cl:cond
      ((or (equal t1 t2)
           (and (symbolp t1) (symbolp t2) (string-equal (symbol-name t1) (symbol-name t2))))
       t)
      ((or (and (symbolp t1) (string-equal t1 "VOID") (null t2))
           (and (null t1) (symbolp t2) (string-equal t2 "VOID")))
       t)
      ((and (consp t1) (symbolp t2))
       (let* ((expanded (canonicalize-type-specifier t1))
              (base-type (cl:first expanded))
              (params (rest expanded)))
         (if (and (symbolp base-type)
                  (not (excluded-template-base-type-p base-type)))
             (progn
              (cl:when (gethash base-type *template-registry*)
                (cl:let ((instantiated-form
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
              (cl:let ((mangled (mangle-template-struct-name base-type params)))
                (cl:cond
                  ((eq mangled t2) t)
                  ((string-equal (symbol-name mangled) (symbol-name t2)) t)
                  (t nil))))
             nil)))
      ((and (symbolp t1) (consp t2))
       (types-equivalent-p t2 t1))
      ;; Parameterized struct vs parameterized struct — use package-agnostic comparison
      ((and (cl:consp t1) (cl:consp t2))
       (cl:let ((e1 (canonicalize-type-specifier t1))
                (e2 (canonicalize-type-specifier t2)))
         (%type-spec-equal-p e1 e2)))
      ((and (or (member t1 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t1) (member (symbol-name t1) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t2 *crisp-enums*)) t)
      ((and (or (member t2 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t2) (member (symbol-name t2) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t1 *crisp-enums*)) t)
      ((and (consp t1) (= (length t1) 1) (valid-type-p (cl:first t1)) (types-equivalent-p (cl:first t1) t2)) t)
      ((and (consp t2) (= (length t2) 1) (valid-type-p (cl:first t2)) (types-equivalent-p t1 (cl:first t2))) t)
      (t nil))))


;; -----------------------------------------------------------------------------
;; Change 1: align enumeration
;; src/enums.lisp
;; -----------------------------------------------------------------------------

(def-enumeration align :std140 :compact)


;; -----------------------------------------------------------------------------
;; Change 2: register-builtins — adds tensor def-record template + bytes~.
;; src/compiler.lisp
;; -----------------------------------------------------------------------------

(defun register-builtins ()
  "Registers built-in types: storage, cell, and tensor def-record templates.
   Cell and tensor carry the value-t brand for --differentiate mode.
   Tensor: N-dimensional strided view; offset/strides/extents are virtual
   fixed arrays of length N (SROA to N ulong registers each at boundaries)."
  (log:info "Registering built-in structs (storage, cell, tensor)...")

  ;; Clear brand-specific state that is NOT cleared by initialize-compiler.
  (when (boundp '*parameterized-brand-names*) (clrhash *parameterized-brand-names*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  (when (boundp '*brand-cache-last-function*) (setf *brand-cache-last-function* nil))

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
           (def-record storage
             (address (c-pointer :address-space Addr))
             (byte-size ulong)
             (address-space address-space :c-t Addr)
             (access access :c-t :read-write))))

  ;; CELL: opaque handle to a storage slice.
  ;;   value-t brand enables --differentiate provenance tracking.
  ;;   NOTE: index-t intentionally omitted (package-symbol conflict avoidance with fake-cell).
  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
           (def-record cell
             (brand value-t To :subst :descendant :enforce :diff)
             (parent (storage Addr))
             (offset ulong)
             (element-type type-spec :c-t To)
             (address-space address-space :c-t Addr)
             (access access :c-t Acc))))

  ;; bytes~ helper for cell.
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
    '(def-function bytes~ (c)
       (declare (function ((cell To Addr Acc) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((cell To Addr Acc) => ulong))

  ;; TENSOR: N-dimensional strided view over a storage handle.
  ;;   offset, strides, extents: virtual fixed arrays of length N.
  ;;   length: product of extents, stored as a field for O(1) (length~ t).
  ;;   value-t brand follows the same pattern as cell.
  (eval '(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                               (Acc access :read-write) (Aln align :compact))
           (def-record tensor
             (brand value-t To :subst :descendant :enforce :diff)
             (parent  (storage Addr))
             (offset (array ulong N))
             (strides (array ulong N))
             (extents (array ulong N))
             (length  ulong)
             (element-type  type-spec     :c-t To)
             (num-dims      ulong         :c-t N)
             (address-space address-space :c-t Addr)
             (access        access        :c-t Acc)
             (align         align         :c-t Aln))))

  ;; bytes~ helper for tensor.
  (register-template 'bytes~
    '(To (N integer 1) (Addr address-space :global)
      (Acc access :read-write) (Aln align :compact)) nil
    '(def-function bytes~ (t1)
       (declare (function ((tensor To N Addr Acc Aln) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((tensor To N Addr Acc Aln) => ulong))

  (log:info "Built-in structs registered."))


;; -----------------------------------------------------------------------------
;; Change 3: expand-storage-handle-type-specifier — adds tensor 6-tuple.
;; Tensor canonical form: (tensor elem N addr access align).
;; Cell/vector/matrix unchanged (4-tuple).
;; src/types/validation.lisp
;; -----------------------------------------------------------------------------

(defun expand-storage-handle-type-specifier (spec)
  "Expands storage handle type specs into canonical positional forms.
   Cell/vector/matrix → (base elem addr access)         [4-tuple, :global :read-write].
   Tensor             → (tensor elem N addr access align) [6-tuple, :global :read-write :compact].
   Tensor missing N → crisp-incomplete-type-error.
   Address-space / access / align bare symbols normalised to keywords."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cl:cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (cl:let ((base (cl:first spec)))
       (if (and (symbolp base)
                (member (symbol-name base)
                        '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (progn
             (when (null (rest spec))
               (error 'crisp-incomplete-type-error :type-spec spec))

             (cl:let* ((args         (rest spec))
                       (element-type (cl:first args))
                       (rest-args    (rest args)))

               (cond
                ;; ── TENSOR: second positional arg is the arity N ─────────────
                ((string-equal (symbol-name base) "TENSOR")
                 (cl:let* (;; N present when next arg is NOT a keyword/nil
                            (n-arg       (and rest-args
                                              (not (keywordp (cl:first rest-args)))
                                              (cl:first rest-args)))
                            (rest-after-n (if n-arg (rest rest-args) rest-args))
                            (addr :global)
                            (acc  :read-write)
                            (aln  :compact)
                            (remaining rest-after-n))
                   (unless n-arg
                     (error 'crisp-incomplete-type-error :type-spec spec))
                   (cl:loop while remaining do
                     (cl:let ((item (pop remaining)))
                       (cl:cond
                         ((cl:member (string item) '("GLOBAL" "LOCAL" "PRIVATE"
                                                     "CONSTANT" "GENERIC")
                                     :test #'string-equal)
                          (setf addr (intern (string-upcase (string item)) :keyword)))
                         ((cl:member (string item) '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                                     "READABLE" "WRITEABLE")
                                     :test #'string-equal)
                          (setf acc (intern (string-upcase (string item)) :keyword)))
                         ((cl:member (string item) '("STD140" "COMPACT")
                                     :test #'string-equal)
                          (setf aln (intern (string-upcase (string item)) :keyword)))
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (cl:unless remaining
                            (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          (cl:unless remaining
                            (error "Missing value for :ACCESS in ~s" spec))
                          (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ALIGN")
                          (cl:unless remaining
                            (error "Missing value for :ALIGN in ~s" spec))
                          (setf aln (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "DIRECTION")
                          (cl:when remaining (pop remaining)))
                         (t
                          (error "Invalid type option: ~s in tensor spec ~s" item spec)))))
                   (list base element-type n-arg addr acc aln)))

                ;; ── CELL / VECTOR / MATRIX: original 4-tuple logic ───────────
                (t
                 (if (null rest-args)
                     (list base element-type :global :read-write)
                     (cl:let ((addr :global)
                              (acc  :read-write)
                              (remaining rest-args))
                       (cl:loop while remaining do
                         (cl:let ((item (pop remaining)))
                           (cl:cond
                             ((cl:member (string item) '("GLOBAL" "LOCAL" "PRIVATE"
                                                         "CONSTANT" "GENERIC")
                                         :test #'string-equal)
                              (setf addr (intern (string-upcase (string item)) :keyword)))
                             ((cl:member (string item) '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                                         "READABLE" "WRITEABLE")
                                         :test #'string-equal)
                              (setf acc (intern (string-upcase (string item)) :keyword)))
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (cl:unless remaining
                                (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (cl:unless remaining
                                (error "Missing value for :ACCESS in ~s" spec))
                              (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "DIRECTION")
                              (cl:when remaining (pop remaining)))
                             (t
                              (error "Invalid type option: ~s in spec ~s" item spec)))))
                       (list base element-type addr acc)))))))
           spec)))
    (t spec)))


;; -----------------------------------------------------------------------------
;; Change 4: get-array-element-type — extend symbolp branch to handle tensor.
;; src/analysis/structs.lisp
;; -----------------------------------------------------------------------------

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


;; -----------------------------------------------------------------------------
;; Tensor helpers used by analyze-aref-expression and generate-node-ir.
;; src/analysis/structs.lisp
;; -----------------------------------------------------------------------------

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


;; -----------------------------------------------------------------------------
;; Change 5: analyze-aref-expression — tensor multi-index desugaring.
;; src/analysis/structs.lisp
;; -----------------------------------------------------------------------------

(defun analyze-aref-expression (expr env context location)
  "Analyzes (~ target [index...]) or (~ref~ ...) expressions.
   Cell/array path: single index, brand-aware type resolution (unchanged).
   Tensor path: N index forms from (cddr expr) are desugared to a flat element
   index (sum of offsets[k] + index_k * strides[k]) via recursive analysis,
   then a semantic-aref is returned with the tensor node and flat-index node."
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

                ;; ── Tensor path: desugar N indices to flat element index ──────
                (let* ((index-forms (cddr expr)))
                  (unless (= (cl:length index-forms) tensor-n)
                    (error "Tensor ~a requires ~a index~:p (arity ~a), got ~a."
                           target-sym tensor-n tensor-n (cl:length index-forms)))
                  (let* ((flat-form     (%build-tensor-flat-index-form target-sym index-forms))
                         (flat-node     (analyze-expression flat-form env context location))
                         ;; Brand-aware type resolution (same pattern as cell)
                         (brand-def     (and (not (eq *analysis-access-mode* :write))
                                             (not (consp elem-type))
                                             (find-brand-for-owner 'value-t array-type)))
                         (is-rw         (and brand-def
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


;; -----------------------------------------------------------------------------
;; Change 6: generate-node-ir (semantic-aref) — adds Case 3 for tensor.
;; src/codegen.lisp
;; -----------------------------------------------------------------------------

(defmethod generate-node-ir ((node semantic-aref) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for array/cell/tensor element access (aref / ~ / ~ref~).
   Case 2: (array T N) fixed-size array — GEP into alloca (unchanged).
   Case 3: TENSOR — parent.address from SROA field 0; byte-off = flat_idx * sizeof(elem);
     GEP i8* + byte-off, bitcast, load.  The flat element index is pre-computed by
     analyze-aref-expression (strides and offsets already folded in).
   Case 1: CELL — original behaviour unchanged.
   Returns (values loaded-val nil elem-ptr) so set! can store through the pointer."
  (let* ((array-node   (semantic-aref-array-node node))
         (index-node   (semantic-aref-index-node node))
         (array-type   (let ((raw (semantic-node-type array-node)))
                         (if (and (listp raw) (= (cl:length raw) 1) (listp (cl:first raw)))
                             (cl:first raw)
                             raw)))
         (element-type (semantic-aref-type node))
         (index-val    (generate-node-ir index-node builder module var-env
                                         di-builder di-scope location-map)))

    (let ((cell-spec (let* ((resolved (resolve-type-alias array-type))
                            (canon    (canonicalize-type-specifier resolved)))
                       (cond
                        ((and (listp canon) (symbolp (cl:first canon))
                              (string-equal (symbol-name (cl:first canon)) "CELL")) canon)
                        ((and (listp canon) (= (cl:length canon) 1) (symbolp (cl:first canon)))
                         (unmangle-template-struct-name (cl:first canon)))
                        ((symbolp canon)
                         (unmangle-template-struct-name canon))
                        (t canon)))))

      (cond
       ;; Case 2: (array T N) fixed-size array — GEP into alloca (unchanged)
       ((%array-type-p (resolve-type-alias array-type))
        (let* ((resolved-arr-type (resolve-type-alias array-type))
               (elem-type-spec    (cl:second resolved-arr-type))
               (count-raw         (cl:third  resolved-arr-type))
               (count             (etypecase count-raw
                                    (integer count-raw)
                                    (symbol  (parse-integer (symbol-name count-raw)))))
               (elem-llvm-type    (crisp-type-to-llvm-type elem-type-spec module))
               (arr-llvm-type     (crisp.llvm-bindings::llvm-array-type elem-llvm-type count))
               (arr-ptr
                (let ((inline-ptr (%try-inline-struct-array-field-ptr
                                   array-node builder module var-env
                                   di-builder di-scope location-map)))
                  (if inline-ptr
                      inline-ptr
                      (if (semantic-var-read-p array-node)
                          (let ((alloca (gethash (semantic-var-read-name array-node) var-env)))
                            (unless alloca
                              (error "array aref: variable ~a not found in var-env"
                                     (semantic-var-read-name array-node)))
                            alloca)
                          (multiple-value-bind (sub-val _loc sub-ptr)
                              (generate-node-ir array-node builder module var-env
                                                di-builder di-scope location-map)
                            (declare (ignore _loc))
                            (cond
                             (sub-ptr
                              (log:info "array-aref: using sub-ptr from inner aref (bug 029 path)")
                              sub-ptr)
                             ((llvm-type-kind-is-pointer? (llvm-type-of sub-val))
                              sub-val)
                             (t
                              (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                                (llvm-build-store builder sub-val slot)
                                slot))))))))
               (idx-i64 (llvm-build-sext builder index-val (llvm-int64-type) "arr_idx")))

          (log:info "array-aref: type=(array ~a ~a) ptr=~a idx=~a"
                    elem-type-spec count arr-ptr idx-i64)

          (cffi:with-foreign-object (indices :pointer 2)
            (setf (cffi:mem-aref indices :pointer 0)
                  (llvm-const-int (llvm-int32-type) 0 nil))
            (setf (cffi:mem-aref indices :pointer 1) idx-i64)
            (let* ((elem-ptr (llvm-build-in-bounds-gep2
                              builder arr-llvm-type arr-ptr indices 2 "arr_elem_ptr"))
                   (loaded   (llvm-build-load2 builder elem-llvm-type elem-ptr "arr_elem")))
              (values loaded nil elem-ptr)))))

       ;; Case 3: TENSOR — flat index pre-computed; GEP via parent storage pointer.
       ;; SROA field 0 of tensor is (storage Addr) → {address ptr, byte-size}.
       ;; Field 0 of storage is the raw pointer.
       ((and (listp cell-spec) (symbolp (cl:first cell-spec))
             (string-equal (symbol-name (cl:first cell-spec)) "TENSOR"))
        (let* ((tensor-val     (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-name   (mangle-template-struct-name (cl:first cell-spec)
                                                            (cl:rest cell-spec))))
          (log:info "semantic-aref tensor: struct=~a elem=~a" mangled-name elem-type-spec)
          (ensure-struct-llvm-type mangled-name)
          (let* ((parent-val  (llvm-build-extract-value builder tensor-val 0 "t_parent_val"))
                 (base-ptr    (llvm-build-extract-value builder parent-val 0 "t_base_ptr"))
                 ;; flat element index already incorporates offsets and strides
                 (flat-i64    (llvm-build-sext builder index-val (llvm-int64-type) "t_flat_i64"))
                 (elem-size   (llvm-size-of elem-llvm-type))
                 (byte-off    (llvm-build-mul builder flat-i64 elem-size "t_byte_off")))
            (cffi:with-foreign-object (indices :pointer 1)
              (setf (cffi:mem-aref indices :pointer 0) byte-off)
              (let* ((ptr-i8   (llvm-build-in-bounds-gep2
                                builder (llvm-int8-type) base-ptr indices 1 "t_ptr_i8"))
                     (ptr-as   (llvm-get-pointer-address-space (llvm-type-of ptr-i8)))
                     (t-ptr    (llvm-build-bit-cast
                                builder ptr-i8
                                (llvm-pointer-type elem-llvm-type ptr-as) "t_ptr"))
                     (loaded   (llvm-build-load2 builder elem-llvm-type t-ptr "t_elem")))
                (values loaded nil t-ptr))))))

       ;; Case 1: CELL parameterized type (unchanged)
       ((and (listp cell-spec) (symbolp (cl:first cell-spec))
             (string-equal (symbol-name (cl:first cell-spec)) "CELL"))
        (let* ((cell-val       (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-struct-name (mangle-template-struct-name (cl:first cell-spec)
                                                                  (cl:rest cell-spec))))
          (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
          (ensure-struct-llvm-type mangled-struct-name)
          (let ()
            (log:info "semantic-aref: Using ExtractValue to access Cell Record members.")
            (let* ((parent-val   (llvm-build-extract-value builder cell-val 0 "parent_val"))
                   (base-ptr     (llvm-build-extract-value builder parent-val 0 "base_ptr"))
                   (cell-offset  (llvm-build-extract-value builder cell-val 1 "cell_offset"))
                   (elem-size    (llvm-size-of elem-llvm-type))
                   (index-i64    (llvm-build-sext builder index-val (llvm-int64-type) "index_i64"))
                   (index-bytes  (llvm-build-mul builder index-i64 elem-size "index_bytes"))
                   (total-offset (llvm-build-add builder cell-offset index-bytes "total_offset")))
              (cffi:with-foreign-object (indices :pointer 1)
                (setf (cffi:mem-aref indices :pointer 0) total-offset)
                (let* ((final-ptr-i8 (llvm-build-in-bounds-gep2
                                      builder (llvm-int8-type) base-ptr indices 1 "final_ptr_i8"))
                       (ptr-as       (llvm-get-pointer-address-space
                                      (llvm-type-of final-ptr-i8)))
                       (target-ptr   (llvm-build-bit-cast
                                      builder final-ptr-i8
                                      (llvm-pointer-type elem-llvm-type ptr-as) "target_ptr"))
                       (loaded-val   (llvm-build-load2
                                      builder elem-llvm-type target-ptr "val")))
                  (values loaded-val nil target-ptr)))))))

       (t (error "generate-node-ir semantic-aref: Unsupported array type: ~a (unmangled: ~a)"
                 array-type cell-spec))))))

;; -----------------------------------------------------------------------------
;; Change 7: analyze-length-tilde-expression — extend to handle tensor types.
;; src/analysis/control.lisp
;;
;; For arrays (array T N): existing compile-time constant behaviour.
;; For tensors: delegate to analyze-function-call → the runtime length~ accessor.
;; -----------------------------------------------------------------------------

(defun analyze-length-tilde-expression (expr env context location)
  "Analyzes (length~ arr).
   For (array T N): returns compile-time constant N as ulong literal.
   For tensor types: dispatches to the runtime length~ accessor function.
   Signals crisp-compiler-error if argument is neither array nor tensor."
  (unless (= (cl:length expr) 2)
    (error 'crisp-compiler-error
           :message "length~ expects exactly 1 argument: (length~ arr)"
           :source-location location))
  (let* ((arg-node (analyze-expression (cl:second expr) env context location))
         (raw-type (semantic-node-type arg-node))
         (arg-type (resolve-type-alias
                    (if (and (listp raw-type) (= (cl:length raw-type) 1) (listp (cl:first raw-type)))
                        (cl:first raw-type)
                        raw-type)))
         ;; Check if this is a tensor type (mangled symbol or canonical list starting with TENSOR)
         (is-tensor (let ((resolved (resolve-type-alias arg-type)))
                      (or (and (symbolp resolved)
                               (let* ((parts (unmangle-template-struct-name resolved))
                                      (base (cl:first parts)))
                                 (and base (string-equal (symbol-name base) "TENSOR"))))
                          (and (listp resolved)
                               (symbolp (cl:first resolved))
                               (string-equal (symbol-name (cl:first resolved)) "TENSOR"))))))
    (cond
     ;; Tensor: delegate to the runtime length~ accessor in the function table
     (is-tensor
      (log:info "length~~: tensor type ~a → delegating to runtime accessor" arg-type)
      (analyze-function-call 'length~ expr env context location))
     ;; Array: compile-time constant
     ((%array-type-p arg-type)
      (let* ((n-raw (cl:third arg-type))
             (n (etypecase n-raw
                  (integer n-raw)
                  (symbol  (parse-integer (symbol-name n-raw))))))
        (log:info "length~~: array type ~a -> N=~a" arg-type n)
        (make-semantic-literal :value-type 'ulong
                               :value (coerce n '(unsigned-byte 64))
                               :source-location location)))
     ;; Neither: error
     (t
      (error 'crisp-compiler-error
             :message (format nil "length~~ requires an (array T N) or tensor type, got ~a" arg-type)
             :source-location location)))))


;; -----------------------------------------------------------------------------
;; Change 8: reconstruct-template-args — parse numeric strings as integers.
;; src/mangling.lisp
;;
;; Problem: when unmangling TENSOR_LONG_3_GLOBAL_READ-WRITE_COMPACT, the token
;; "3" is interned as symbol |3| rather than parsed as integer 3.
;; The bytes~ template has param (N integer 1) which fails (typep '|3| 'integer).
;; Fix: try parse-integer on each token before interning as symbol.
;; Also fix validate-template-arg to handle symbol->integer coercion as fallback.
;; -----------------------------------------------------------------------------

(cl:defun reconstruct-template-args (tokens package)
  "Recursively groups tokens into lists based on template arity.
   tokens: list of strings.
   package: the fallback package for interning.
   Returns: (values property-list remaining-tokens)
   FIX: numeric token strings are parsed as integers before interning as symbols."
  (cl:if (cl:null tokens)
      (cl:values nil nil)
      (cl:let* ((token-str (cl:first tokens))
                ;; Handle keywords specially
                (token-sym (cl:if (cl:char= (cl:char token-str 0) #\:)
                               (cl:intern (cl:subseq token-str 1) :keyword)
                               ;; Try parse as integer first, then find/intern as symbol
                               (cl:multiple-value-bind (n end)
                                   (cl:parse-integer token-str :junk-allowed t)
                                 (cl:if (cl:and n (cl:= end (cl:length token-str)))
                                        n  ; it's a numeric token — return the integer
                                        (cl:let ((existing (cl:find-symbol token-str package)))
                                          (cl:if existing existing
                                                 (cl:intern token-str package)))))))
                (arity (cl:and (cl:not (cl:integerp token-sym))
                               *template-arity-lookup-fn*
                               (cl:funcall *template-arity-lookup-fn* token-sym))))

        (cl:if (cl:and arity (cl:> arity 0))
            ;; It's a template! Consume 'arity' args.
            (cl:multiple-value-bind (args remaining)
                (reconstruct-n-args (cl:rest tokens) arity package)
              (cl:multiple-value-bind (rest-processed rest-remaining)
                  (reconstruct-template-args remaining package)
                (cl:values (cl:cons (cl:cons token-sym args) rest-processed) rest-remaining)))

            ;; Not a template (or arity 0), treat as atom
            (cl:multiple-value-bind (rest-processed rest-remaining)
                (reconstruct-template-args (cl:rest tokens) package)
              (cl:values (cl:cons token-sym rest-processed) rest-remaining))))))
