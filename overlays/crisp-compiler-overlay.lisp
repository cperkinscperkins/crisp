;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; Remove :access from storage handle types
;;; =========================================================
;;;
;;; Storage handle canonical forms change:
;;;   CELL:   (cell  elem addr)            [3-tuple, was 4]
;;;   TENSOR: (tensor elem N addr aln ct)  [6-tuple, was 7]
;;;
;;; :access never affected LLVM-IR; hoist code defaults to read-write.
;;; =========================================================

;; src/types/validation.lisp
(defun expand-storage-handle-type-specifier (spec)
  "Expands storage handle type specs into canonical positional forms.
   Cell   → (cell  elem addr)              [3-tuple].
   Vector → (tensor elem 1 addr align ct)  [6-tuple, sugar for tensor N=1].
   Matrix → (tensor elem 2 addr align ct)  [6-tuple, sugar for tensor N=2].
   Tensor → (tensor elem N addr align ct)  [6-tuple].
   ct defaults to :last; :row-major/:col-major are matrix-only aliases for :last/:first."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (let ((base (first spec)))
       (if (and (symbolp base)
                (member (symbol-name base)
                        '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (progn
             (when (null (rest spec))
               (error 'crisp-incomplete-type-error :type-spec spec))

             (let* ((args         (rest spec))
                    (element-type (first args))
                    (rest-args    (rest args)))

               (cond

                ;; ── VECTOR ──────────────────────────────────────────
                ((string-equal (symbol-name base) "VECTOR")
                 (let* ((addr      :global)
                        (aln       :compact)
                        (ct        :last)
                        (remaining rest-args))
                   (when (and remaining (not (keywordp (first remaining))))
                     (error "Invalid type option ~s in vector spec ~s. Vector takes no arity argument; use (tensor ~s N) for N > 2."
                            (first remaining) spec element-type))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          ;; :access has been removed; skip the value but signal a warning
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((member v '(:row-major :col-major))
                               (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last or :first." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (%bare-storage-handle-value-error item spec)))))
                   (list (find-symbol "TENSOR" :crisp.compiler)
                         element-type 1 addr aln ct)))

                ;; ── MATRIX ──────────────────────────────────────────
                ((string-equal (symbol-name base) "MATRIX")
                 (let* ((addr      :global)
                        (aln       :compact)
                        (ct        :last)
                        (remaining rest-args))
                   (when (and remaining (not (keywordp (first remaining))))
                     (error "Invalid type option ~s in matrix spec ~s. Matrix takes no arity argument; use (tensor ~s N) for arbitrary arity."
                            (first remaining) spec element-type))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((eq v :row-major) (setf ct :last))
                              ((eq v :col-major) (setf ct :first))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major, or :col-major." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (%bare-storage-handle-value-error item spec)))))
                   (list (find-symbol "TENSOR" :crisp.compiler)
                         element-type 2 addr aln ct)))

                ;; ── TENSOR ──────────────────────────────────────────
                ((string-equal (symbol-name base) "TENSOR")
                 (let* ((n-arg        (and rest-args
                                           (not (keywordp (first rest-args)))
                                           (first rest-args)))
                        (rest-after-n (if n-arg (rest rest-args) rest-args))
                        (addr         :global)
                        (aln          :compact)
                        (ct           :last)
                        (remaining    rest-after-n))
                   (unless n-arg
                     (error 'crisp-incomplete-type-error :type-spec spec))
                   (loop while remaining do
                     (let ((item (pop remaining)))
                       (cond
                         ;; bare address-space values (canonical form idempotency)
                         ((member (string item)
                                  '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                  :test #'string-equal)
                          (setf addr (intern (string-upcase (string item)) :keyword)))
                         ;; bare access values — ignore silently (canonical idempotency for old forms)
                         ((member (string item)
                                  '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                    "READABLE" "WRITEABLE")
                                  :test #'string-equal)
                          (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
                         ;; bare align values (canonical form idempotency)
                         ((member (string item) '("COMPACT" "COMPACT-OFFSET" "STRIDED")
                                  :test #'string-equal)
                          (setf aln (intern (string-upcase (string item)) :keyword)))
                         ;; bare contiguous-term values (canonical form idempotency)
                         ((member (string item) '("LAST" "FIRST")
                                  :test #'string-equal)
                          (setf ct (intern (string-upcase (string item)) :keyword)))
                         ((string-equal (string item) "ADDRESS-SPACE")
                          (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                         ((string-equal (string item) "ACCESS")
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (pop remaining)
                          (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                         ((string-equal (string item) "ALIGN")
                          (unless remaining (error "Missing value for :ALIGN in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (unless (member v '(:compact :compact-offset :strided))
                              (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
                            (setf aln v)))
                         ((string-equal (string item) "CONTIGUOUS-TERM")
                          (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
                          (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
                            (cond
                              ((member v '(:last :first)) (setf ct v))
                              ((eq v :row-major)
                               (let ((n (if (integerp n-arg) n-arg
                                            (ignore-errors (parse-integer (string n-arg))))))
                                 (unless (eql n 2)
                                   (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                               (setf ct :last))
                              ((eq v :col-major)
                               (let ((n (if (integerp n-arg) n-arg
                                            (ignore-errors (parse-integer (string n-arg))))))
                                 (unless (eql n 2)
                                   (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                               (setf ct :first))
                              (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major (2D only), or :col-major (2D only)." v spec)))))
                         ((string-equal (string item) "DIRECTION")
                          (when remaining (pop remaining)))
                         (t (error "Invalid type option: ~s in tensor spec ~s" item spec)))))
                   (list base element-type n-arg addr aln ct)))

                ;; ── CELL ────────────────────────────────────────────
                (t
                 (if (null rest-args)
                     (list base element-type :global)
                     (let ((addr      :global)
                           (remaining rest-args))
                       (loop while remaining do
                         (let ((item (pop remaining)))
                           (cond
                             ((member (string item)
                                      '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                      :test #'string-equal)
                              (setf addr (intern (string-upcase (string item)) :keyword)))
                             ((member (string item)
                                      '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                        "READABLE" "WRITEABLE")
                                      :test #'string-equal)
                              (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                              (pop remaining)
                              (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
                             ((string-equal (string item) "DIRECTION")
                              (when remaining (pop remaining)))
                             (t (error "Invalid type option: ~s in spec ~s" item spec)))))
                       (list base element-type addr)))))))
           spec)))))


;; src/macros.lisp
(defun %incomplete-storage-handle-p (type-spec)
  "Returns T if the type-spec is a storage handle but is missing :address-space.
   Canonical 3-tuple (cell elem addr) and 6-tuple (tensor elem N addr aln ct) are complete."
  (let ((resolved (%resolve-alias-strict type-spec)))
    (when (and (consp resolved) (%storage-handle-type-p resolved))
      (let* ((base (first resolved))
             (args (rest resolved)))
        (cond
          ;; Tensor fully expanded: 5 args (elem N addr aln ct) -> complete.
          ((and (symbolp base)
                (string-equal (symbol-name base) "TENSOR")
                (= (length args) 5))
           nil)
          ;; Cell/original: key-value form, 2-arg new canonical, or 3-arg old positional.
          (t
           (let ((is-kw (member :address-space args)))
             (cond
               (is-kw nil)  ; :address-space keyword present — complete (value check deferred)
               ((>= (length args) 2) nil)  ; (elem addr ...) positional = complete
               (t t)))))))))


;; src/macros.lisp
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


;; src/compiler.lisp — register-builtins without Acc
(defun register-builtins ()
  "Registers built-in storage handle templates (storage, cell, tensor) and
   their system-generated accessor functions.  Called by initialize-compiler."
  (log:info "Registering built-in structs...")

  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  (when (boundp '*brand-cache-last-function*) (setf *brand-cache-last-function* nil))

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
           (def-record storage
             (address (c-pointer :address-space Addr))
             (byte-size ulong)
             (address-space address-space :c-t Addr))))

  ;; CELL: opaque handle to a storage slice.
  (eval '(with-template-type ((To T) (Addr address-space :global))
           (def-record cell
             (brand value-t To :subst :descendant :enforce :diff)
             (parent (storage Addr))
             (offset ulong)
             (element-type type-spec :c-t To)
             (address-space address-space :c-t Addr))))

  ;; bytes~ helper for cell.
  (register-template 'bytes~ '(To (Addr address-space :global)) nil
    '(def-function bytes~ (c)
       (declare (function ((cell To Addr) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((cell To Addr) => ulong))

  ;; TENSOR: N-dimensional strided view over a storage handle.
  (eval '(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                               (Aln align :compact) (Ct contiguity :last))
           (def-record tensor
             (brand value-t To :subst :descendant :enforce :diff)
             (parent  (storage Addr))
             (offset (array ulong N))
             (strides (array ulong N))
             (extents (array ulong N))
             (length  ulong)
             (element-type      type-spec   :c-t To)
             (num-dims          ulong       :c-t N)
             (address-space     address-space :c-t Addr)
             (align             align       :c-t Aln)
             (contiguous-term   contiguity  :c-t Ct))))

  ;; bytes~ helper for tensor.
  (register-template 'bytes~
    '(To (N integer 1) (Addr address-space :global)
      (Aln align :compact) (Ct contiguity :last)) nil
    '(def-function bytes~ (t1)
       (declare (function ((tensor To N Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((tensor To N Addr Aln Ct) => ulong))

  ;; num-rows — return extents[0] (height dimension) of a 2D tensor.
  (register-template 'num-rows
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-rows (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 0)))
    '((tensor To 2 Addr Aln Ct) => ulong))

  ;; num-cols — return extents[1] (width dimension) of a 2D tensor.
  (register-template 'num-cols
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-cols (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 1)))
    '((tensor To 2 Addr Aln Ct) => ulong))

  ;; get-layout — classify 2D tensor layout at runtime via stride inspection.
  (register-template 'get-layout
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function get-layout (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => int)))
       (declare (crisp-system-generated))
       (if (= (~ (strides~ m) 1) 1ul)
           0
           (if (= (~ (strides~ m) 0) 1ul)
               1
               2)))
    '((tensor To 2 Addr Aln Ct) => int))

  ;; contiguous-term~ — returns compile-time contiguity value for any tensor.
  (register-template 'contiguous-term~
    '(To (N integer 1) (Addr address-space :global)
      (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function contiguous-term~ (t1)
       (declare (function ((tensor To N Addr Aln Ct) => contiguity)))
       (declare (crisp-system-generated))
       (return Ct))
    '((tensor To N Addr Aln Ct) => contiguity))

  (log:info "Built-in structs registered."))


;; src/analysis/structs.lisp — %get-tensor-align updated for 6-tuple (no access),
;; %mv-source-access removed, %mv-source-align updated,
;; %mv-result-cell-type / %mv-result-tensor-type updated, %get-tensor-ct updated.

(defun %get-tensor-align (type)
  "Extracts the :align keyword from a tensor type specifier.
   New 6-tuple (tensor elem N addr aln ct): align at position 4 = (fifth type).
   Handles both list form and mangled symbol."
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
       (coerce-aln (fifth type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (first unmangled))
                    (string-equal (symbol-name (first unmangled)) "TENSOR"))
           (coerce-aln (fifth unmangled)))))
      (t nil))))


(defun %mv-source-align (canon)
  "Return the :align keyword from a canonical storage handle type (tensors only).
   New 6-tuple (tensor elem N addr aln ct): align at position 4 = (fifth canon)."
  (when (eq (%mv-source-head canon) :tensor)
    (fifth canon)))

(defun %mv-result-cell-type (new-elem addr)
  "Build canonical cell result type: (cell elem addr)."
  `(cell ,new-elem ,addr))

(defun %mv-result-tensor-type (new-elem rank addr align &optional (ct :last))
  "Build canonical tensor result type: (tensor elem rank addr align ct)."
  `(tensor ,new-elem ,rank ,addr ,align ,ct))

(defun %get-tensor-ct (canon)
  "Extracts the :contiguous-term keyword (6th element, index 5) from a
   canonical tensor type 6-tuple, defaulting to :last when absent."
  (if (and (listp canon) (>= (length canon) 6))
      (nth 5 canon)
      :last))

(defun analyze-make-view-expression (expr env context location)
  "Analyzes make-cell / make-vector / make-matrix / make-tensor."
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
              (addr      (%mv-source-addr src-canon)))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-cell-type new-elem addr)
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
              (src-align (%mv-source-align src-canon))
              (align     (%mv-result-align src-align nil nil)))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 1 addr align :last)
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
              (src-align (%mv-source-align src-canon))
              (align     (%mv-result-align src-align explicit-strides-p col-p))
              (ct        (if col-p :first :last)))
         (unless (and width height)
           (error "make-matrix: width and height must be compile-time integer literals"))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 2 addr align ct)
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
              (src-align    (%mv-source-align src-canon))
              (align        (%mv-result-align src-align explicit-strides-p nil)))
         (unless extents
           (error "make-tensor: extents list must be a compile-time literal list like '(2 3 4)"))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem rank addr align :last)
          :source-node src-node
          :element-type new-elem
          :rank        rank
          :offset      offset
          :length      length
          :extents     extents
          :strides     result-strides
          :major       :row
          :source-location location))))))


;; src/analysis/structs.lisp — transpose/col/row without access
(defun analyze-transpose-expression (expr env context location)
  "Analyzes (transpose M) for 2D tensors.
   Result type: (tensor elem 2 addr :strided src-ct)."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "transpose expects exactly 1 argument: (transpose matrix)"
           :source-location location))
  (let* ((src-node (analyze-expression (second expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon))
         (src-ct   (%get-tensor-ct canon)))
    (make-semantic-stride-view
     :op :transpose
     :source-node src-node
     :index-node nil
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 2 addr :strided src-ct)
     :source-location location)))

(defun analyze-col-expression (expr env context location)
  "Analyzes (col index M) for 2D tensors.
   Result type: (tensor elem 1 addr :strided :last)."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message "col expects exactly 2 arguments: (col index matrix)"
           :source-location location))
  (let* ((idx-node (analyze-expression (second expr) env context location))
         (src-node (analyze-expression (third expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon)))
    (make-semantic-stride-view
     :op :col
     :source-node src-node
     :index-node idx-node
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr :strided :last)
     :source-location location)))

(defun analyze-row-expression (expr env context location)
  "Analyzes (row index M) for 2D tensors.
   Result type: (tensor elem 1 addr :strided :last)."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message "row expects exactly 2 arguments: (row index matrix)"
           :source-location location))
  (let* ((idx-node (analyze-expression (second expr) env context location))
         (src-node (analyze-expression (third expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon)))
    (make-semantic-stride-view
     :op :row
     :source-node src-node
     :index-node idx-node
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr :strided :last)
     :source-location location)))


;; src/analysis/structs.lisp — scratch tensor canonical spec without :access
(defun %scratch-tensor-canonical-spec (op args)
  "Resolves type arguments of a make-scratch-{vector,matrix,tensor} form
   to a canonical (tensor elem N addr align ct) spec."
  (unless args
    (return-from %scratch-tensor-canonical-spec nil))
  (let* ((op-name (symbol-name op))
         (implicit-n (cond ((string-equal op-name "MAKE-SCRATCH-VECTOR") 1)
                           ((string-equal op-name "MAKE-SCRATCH-MATRIX") 2)
                           (t nil)))
         (arg1 (first args)))

    (cond
      (implicit-n
       (let* ((is-tensor-alias
               (and (symbolp arg1)
                    (let ((resolved (resolve-type-alias arg1)))
                      (and (consp resolved)
                           (member (symbol-name (first resolved))
                                   '("TENSOR" "VECTOR" "MATRIX")
                                   :test #'string-equal)))))
              (raw-spec
               (if is-tensor-alias
                   (resolve-type-alias arg1)
                   (list 'tensor arg1 implicit-n))))
         (expand-storage-handle-type-specifier
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))
              (append raw-spec '(:address-space :local :align :compact))
              raw-spec))))

      (t
       (let* ((arg2 (second args))
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
                   (list 'tensor arg1 arg2)
                   (if is-tensor-alias
                       (resolve-type-alias arg1)
                       (list 'tensor arg1)))))
         (expand-storage-handle-type-specifier
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))
              (append raw-spec '(:address-space :local :align :compact))
              raw-spec)))))))


;; src/autodiff.lisp — %ensure-tensor-read-write simplified (no access to force)
(defun %ensure-tensor-read-write (type-spec)
  "For backwards compatibility: returns the canonical 6-tuple unchanged.
   Access was removed; tensors are always read-write."
  type-spec)

;; src/autodiff.lisp — %integer-tensor-elem-to-float updated for 6-tuple
(defun %integer-tensor-elem-to-float (type-spec)
  "Replaces the element type of an integer tensor with its float analog:
   64-bit integers (long, ulong) → double; all others → float.
   Returns TYPE-SPEC unchanged if it is not an integer tensor."
  (if (%crisp-integer-tensor-type-p type-spec)
      (let* ((canonical (canonicalize-type-specifier type-spec))
             (elem      (second canonical))
             (info      (gethash elem *crisp-types*))
             (float-elem (if (and info (>= (crisp-type-size info) 64))
                             'double
                             'float)))
        ;; 6-tuple: (tensor elem N addr aln ct)
        (list (nth 0 canonical) float-elem (nth 2 canonical)
              (nth 3 canonical) (nth 4 canonical) (%get-tensor-ct canonical)))
      type-spec))

;; src/autodiff.lisp — fix grad-out-types to not include :access
(defun %autodiff-grad-cell-type ()
  "Returns the canonical cell type used for gradient output parameters."
  '(cell float :address-space :global))


;; src/metadata.lisp — generate-declared-signature without :access
(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared-signature plist for a kernel's metadata.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Count implicit params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t)
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              (setf entry (append entry (list :type (strip-package-qualifiers type))))
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              (when (%storage-handle-type-p type)
                (let* ((canonical (canonicalize-type-specifier type))
                       (base (if (consp canonical) (first canonical) canonical))
                       (is-cell   (and (symbolp base) (string-equal (symbol-name base) "CELL")))
                       (is-tensor (and (symbolp base) (string-equal (symbol-name base) "TENSOR")))
                       ;; CELL 3-tuple:   (cell elem ADDR)         — addr at index 2
                       ;; TENSOR 6-tuple: (tensor elem N ADDR aln ct) — addr at index 3
                       (as (if (and (consp canonical) is-cell (>= (length canonical) 3))
                               (nth 2 canonical)
                               (if (consp canonical)
                                   (let ((found (member :address-space canonical)))
                                     (if found (second found) :global))
                                   :global))))
                  (setf entry (append entry (list :address-space as)))
                  (when is-tensor
                    (let* ((n (if (integerp (third canonical))
                                  (third canonical)
                                  (parse-integer (symbol-name (third canonical)))))
                           ;; TENSOR 6-tuple: (tensor T N addr ALN ct) — aln at index 4
                           (alg (or (nth 4 canonical) :compact)))
                      (setf entry (append entry (list :rank n :align alg)))))))

              (setf entry (append entry (list :range (list start end))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))


;; src/metadata.lisp — generate-implicit-signature without :access
(defun generate-implicit-signature (sig declared-params)
  "Generates the :implicit-params plist for metadata serialization.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))

    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             (type-head (when (consp type) (symbol-name (first type))))
             ;; Extract address-space:
             ;;   CELL:   (cell elem ADDR)       — addr at index 2
             ;;   TENSOR: (tensor elem N ADDR aln ct) — addr at index 3
             (address-space
              (cond
                ((and (consp type) (string-equal type-head "CELL") (>= (length type) 3))
                 (nth 2 type))
                ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                           :test #'string-equal)
                      (>= (length type) 4))
                 (nth 3 type))
                (t :local)))
             (size-expr (gethash name *implicit-scratch-size-expr-map*)))
        (let ((entry (list :name (string-downcase (symbol-name name))
                           :type (strip-package-qualifiers type)
                           :size-expr size-expr
                           :address-space address-space
                           :range (list start end))))
          (push entry implicit-args))
        (incf phys-index width))

    (nreverse implicit-args))))


;; src/metadata.lisp — %bwd-resolve-type simplified (no access replacement needed)
(defun %bwd-resolve-type (type-spec &optional new-access)
  "Resolves TYPE-SPEC alias to its inline form.
   NEW-ACCESS is accepted for signature compatibility but ignored."
  (declare (ignore new-access))
  (resolve-type-alias type-spec))


;; src/metadata.lisp — %bwd-fixup-declared-types simplified
(defun %bwd-fixup-declared-types (bwd-k-name)
  "Reads BWD-K-NAME's entry in *kernel-declared-signatures*, resolves
   aliases to inline types, and updates the entry in place."
  (let ((raw-types (gethash bwd-k-name *kernel-declared-signatures*)))
    (when raw-types
      (let* ((semantic-types
              (mapcar (lambda (pair)
                        (let* ((p  (car pair))
                               (ts (cdr pair)))
                          (cond
                            ((and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                             pair)
                            (t
                             (cons p (%bwd-resolve-type ts))))))
                      raw-types)))
        (setf (gethash bwd-k-name *kernel-declared-signatures*) semantic-types)
        semantic-types))))


;; src/metadata-val.lisp — validators updated to not check :access
(defun validate-multiply-grad-metadata (paths)
  "Validates the backward grad metacrisp for 01-multiply.
   Checks: kernel name, physical sig (18 params), declared sig (6 params with
   correct names and directions), and source path present."
  (let* ((paths (if (listp paths) paths (list paths)))
         (meta-path (find "multiply_grad_cell_mult.metacrisp" paths
                          :test #'search :key #'namestring)))
    (unless meta-path
      (log:error "validate-multiply-grad-metadata: no *multiply_grad_cell_mult.metacrisp* in ~a" paths)
      (return-from validate-multiply-grad-metadata nil))
    (let* ((content (uiop:read-file-forms meta-path))
           (kernels (find :kernels content :key #'car))
           (k-def   (find-if (lambda (k) (string-equal (getf k :name) "cell_mult_grad"))
                             (cdr kernels))))
      (unless k-def
        (log:error "validate-multiply-grad-metadata: kernel 'cell_mult_grad' not found in ~a" meta-path)
        (return-from validate-multiply-grad-metadata nil))
      (let ((phys-sig (getf k-def :physical-signature)))
        (unless (= (length phys-sig) 18)
          (log:error "validate-multiply-grad-metadata: expected 18 physical-sig entries, got ~a"
                     (length phys-sig))
          (return-from validate-multiply-grad-metadata nil)))
      (let ((decl-sig (getf k-def :declared-signature)))
        (unless (= (length decl-sig) 6)
          (log:error "validate-multiply-grad-metadata: expected 6 declared-sig params, got ~a"
                     (length decl-sig))
          (return-from validate-multiply-grad-metadata nil))
        (flet ((check-cell (param expected-name expected-dir)
                 (let ((name (getf param :name))
                       (dir  (getf param :direction)))
                   (unless (and (string-equal name expected-name) (eq dir expected-dir))
                     (log:error "validate-multiply-grad-metadata: param ~s: expected dir=~s, got name=~s dir=~s"
                                expected-name expected-dir name dir)
                     (return-from validate-multiply-grad-metadata nil)))))
          (check-cell (nth 0 decl-sig) "a"      :in)
          (check-cell (nth 1 decl-sig) "b"      :in)
          (check-cell (nth 2 decl-sig) "c"      :in)
          (check-cell (nth 3 decl-sig) "c_grad" :in)
          (check-cell (nth 4 decl-sig) "a_grad" :out)
          (check-cell (nth 5 decl-sig) "b_grad" :out)))
      (unless (getf k-def :source)
        (log:error "validate-multiply-grad-metadata: no :source in kernel def")
        (return-from validate-multiply-grad-metadata nil))
      t)))

(defun validate-record-grad-metadata (paths)
  "Validates the backward grad metacrisp for 03-record-at-boundary.
   Checks: kernel name, physical sig (14 params), declared sig (6 params with
   correct names and directions), and source path present."
  (let* ((paths (if (listp paths) paths (list paths)))
         (meta-path (find "_grad_non_overloadable_accessor_k.metacrisp" paths
                         :test #'search :key #'namestring)))
    (unless meta-path
      (log:error "validate-record-grad-metadata: no *_grad_non_overloadable_accessor_k.metacrisp* in ~a" paths)
      (return-from validate-record-grad-metadata nil))
    (let* ((content (uiop:read-file-forms meta-path))
           (kernels (find :kernels content :key #'car))
           (k-def   (find-if (lambda (k)
                               (string-equal (getf k :name) "non_overloadable_accessor_k_grad"))
                             (cdr kernels))))
      (unless k-def
        (log:error "validate-record-grad-metadata: kernel 'non_overloadable_accessor_k_grad' not found in ~a"
                   meta-path)
        (return-from validate-record-grad-metadata nil))
      (let ((phys-sig (getf k-def :physical-signature)))
        (unless (= (length phys-sig) 14)
          (log:error "validate-record-grad-metadata: expected 14 physical-sig entries, got ~a"
                     (length phys-sig))
          (return-from validate-record-grad-metadata nil)))
      (let ((decl-sig (getf k-def :declared-signature)))
        (unless (= (length decl-sig) 6)
          (log:error "validate-record-grad-metadata: expected 6 declared-sig params, got ~a"
                     (length decl-sig))
          (return-from validate-record-grad-metadata nil))
        (flet ((check-scalar-in (param expected-name)
                 (let ((name (getf param :name))
                       (dir  (getf param :direction)))
                   (unless (and (string-equal name expected-name) (eq dir :in))
                     (log:error "validate-record-grad-metadata: param ~s: expected float :in, got name=~s dir=~s"
                                expected-name name dir)
                     (return-from validate-record-grad-metadata nil))))
               (check-cell (param expected-name expected-dir)
                 (let ((name (getf param :name))
                       (dir  (getf param :direction)))
                   (unless (and (string-equal name expected-name) (eq dir expected-dir))
                     (log:error "validate-record-grad-metadata: param ~s: expected dir=~s, got name=~s dir=~s"
                                expected-name expected-dir name dir)
                     (return-from validate-record-grad-metadata nil)))))
          (check-scalar-in (nth 0 decl-sig) "vp_x")
          (check-scalar-in (nth 1 decl-sig) "vp_y")
          (check-cell      (nth 2 decl-sig) "c"         :in)
          (check-cell      (nth 3 decl-sig) "c_grad"    :in)
          (check-cell      (nth 4 decl-sig) "vp_x_grad" :out)
          (check-cell      (nth 5 decl-sig) "vp_y_grad" :out)))
      (unless (getf k-def :source)
        (log:error "validate-record-grad-metadata: no :source in kernel def")
        (return-from validate-record-grad-metadata nil))
      t)))


;; src/metadata.lisp — generate-physical-signature: fix tensor addr-space extraction.
;; New 6-tuple (tensor elem N ADDR aln ct): addr at index 3 = (fourth canonical).
;; Old code used (member :address-space canonical) which always returns NIL for
;; positional canonicals, defaulting everything to :global.
(defun generate-physical-signature (sig-or-params)
  "Generates the physical ABI signature from kernel parameters.
   Records are flattened to primitive scalar entries.
   Fixed: tensor address-space is at (fourth canonical) in the positional 6-tuple."
  (let ((params (if (typep sig-or-params 'function-signature)
                    (append (function-signature-implicit-parameters sig-or-params)
                      (function-signature-parameters sig-or-params))
                    sig-or-params))
        (physical-args nil)
        (current-index 0))
    (dolist (param params)
      (let ((type (if (typep param 'parameter-def)
                      (parameter-def-type param)
                      param)))
        (unless (and (symbolp type) (string-equal (symbol-name type) "&OUT"))
          (cond
           ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
                (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
             (push (list current-index (strip-package-qualifiers '(c-pointer address-space global))) physical-args)
             (incf current-index)
             (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
             (incf current-index))
           ((%storage-handle-type-p type)
             (let* ((canonical (canonicalize-type-specifier type))
                    (base (if (consp canonical) (first canonical) canonical)))
               (cond
                ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'voidp)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index))
                ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
                  ;; ABI: PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1, EXT_0..N-1, LENGTH
                  (let* ((n (if (integerp (third canonical))
                                (third canonical)
                                (parse-integer (symbol-name (third canonical)))))
                         ;; 6-tuple: (tensor elem N ADDR aln ct) — addr positionally at index 3
                         (as (or (fourth canonical) :global))
                         (ptr-type (strip-package-qualifiers `(c-pointer :address-space ,as))))
                    (push (list current-index ptr-type) physical-args) (incf current-index)
                    (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index)
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index)))
                (t
                  (push (list current-index (strip-package-qualifiers type)) physical-args)
                  (incf current-index)))))
           ((%user-record-type-p type)
             (dolist (prim-type (%enumerate-physical-types type))
               (push (list current-index (strip-package-qualifiers prim-type)) physical-args)
               (incf current-index)))
           (t
             (push (list current-index (strip-package-qualifiers type)) physical-args)
             (incf current-index))))))
    (nreverse physical-args)))


;; src/metadata.lisp — generate-implicit-signature corrected.
;; Bug in overlay version: (nreverse implicit-args) was inside the dolist body
;; due to a paren error, so dolist returned NIL and the function always returned NIL.
;; Fix: close the dolist before (nreverse implicit-args).
(defun generate-implicit-signature (sig declared-params)
  "Generates the :implicit-params plist for metadata serialization.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))
    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             (type-head (when (consp type) (symbol-name (first type))))
             ;; Extract address-space positionally:
             ;;   CELL:   (cell elem ADDR)             — addr at index 2
             ;;   TENSOR: (tensor elem N ADDR aln ct)  — addr at index 3
             (address-space
              (cond
                ((and (consp type) (string-equal type-head "CELL") (>= (length type) 3))
                 (nth 2 type))
                ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                           :test #'string-equal)
                      (>= (length type) 4))
                 (nth 3 type))
                (t :local)))
             (size-expr (gethash name *implicit-scratch-size-expr-map*)))
        (push (list :name (string-downcase (symbol-name name))
                    :type (strip-package-qualifiers type)
                    :size-expr size-expr
                    :address-space address-space
                    :range (list start end))
              implicit-args)
        (incf phys-index width)))
    (nreverse implicit-args)))


;; src/metadata-val.lisp — validators updated for 6-tuple tensor names (no read_write).
;; After removing :access, mangled names no longer include read_write / READ-WRITE.

(defun validate-074-02-scratch-vector-propagation-ir (ir-path)
  "Validates scratch vector propagation IR (updated for 6-tuple tensor names, no access)."
  (unless (probe-file ir-path)
    (log:error "validate-074-02: IR file not found: ~a" ir-path)
    (return-from validate-074-02-scratch-vector-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-02: kernel_a not found in IR")
      (return-from validate-074-02-scratch-vector-propagation-ir nil))
    (and
     (or (= ka-count 7)
         (progn (log:error "validate-074-02: kernel_a expected 7 params, got ~a" ka-count) nil))
     (or (search "ptr addrspace(3)" ir)
         (progn (log:error "validate-074-02: expected local (addrspace 3) scratch pointer") nil))
     (or (search "fun_c_tensor_int_1_local_compact_last_int" ir)
         (progn (log:error "validate-074-02: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-02: PASS") t))))

(defun validate-074-03-scratch-tensor-propagation-ir (ir-path)
  "Validates scratch tensor (N=3) propagation IR (updated for 6-tuple tensor names, no access)."
  (unless (probe-file ir-path)
    (log:error "validate-074-03: IR file not found: ~a" ir-path)
    (return-from validate-074-03-scratch-tensor-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-03: kernel_a not found in IR")
      (return-from validate-074-03-scratch-tensor-propagation-ir nil))
    (and
     (or (= ka-count 13)
         (progn (log:error "validate-074-03: kernel_a expected 13 params, got ~a" ka-count) nil))
     (or (search "TENSOR_FLOAT_3_LOCAL_COMPACT_LAST" ir)
         (progn (log:error "validate-074-03: expected TENSOR_FLOAT_3_LOCAL_COMPACT_LAST type in IR") nil))
     (or (search "fun_c_tensor_float_3_local_compact_last_int" ir)
         (progn (log:error "validate-074-03: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-03: PASS") t))))

(defun validate-074-04-scratch-matrix-propagation-ir (ir-path)
  "Validates scratch matrix (N=2) propagation IR (updated for 6-tuple tensor names, no access)."
  (unless (probe-file ir-path)
    (log:error "validate-074-04: IR file not found: ~a" ir-path)
    (return-from validate-074-04-scratch-matrix-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-04: kernel_a not found in IR")
      (return-from validate-074-04-scratch-matrix-propagation-ir nil))
    (and
     (or (= ka-count 11)
         (progn (log:error "validate-074-04: kernel_a expected 11 params, got ~a" ka-count) nil))
     (or (search "TENSOR_FLOAT_2_LOCAL_COMPACT_LAST" ir)
         (progn (log:error "validate-074-04: expected TENSOR_FLOAT_2_LOCAL_COMPACT_LAST type in IR") nil))
     (or (search "fun_c_tensor_float_2_local_compact_last_ulong_ulong" ir)
         (progn (log:error "validate-074-04: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-04: PASS") t))))

(defun validate-vec-add-grad (ir-path)
  "Validates the backward kernel for 01-vec-add (vector addition):
     - @vec_add_grad is defined
     - TENSOR_FLOAT_1_GLOBAL_COMPACT type present (gradient tensors, no access in name)
     - fadd instruction present (addition backward)
     - idx_GRAD is NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-vec-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_add_grad(" ir)
         (progn (log:error "validate-vec-add-grad: @vec_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_COMPACT" ir)
         (progn (log:error "validate-vec-add-grad: gradient tensor type COMPACT not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-vec-add-grad: fadd not found in backward body") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-add-grad: idx_GRAD should not be emitted (integer scalar)") nil))
     (progn (log:info "validate-vec-add-grad: PASS") t))))

(defun validate-vec-multiply-grad (ir-path)
  "Validates the backward kernel for 02-vec-multiply (vector product rule):
     - @vec_mult_grad is defined
     - fmul instruction present
     - TENSOR_FLOAT_1_GLOBAL_COMPACT type present (no access in name)
     - idx_GRAD is NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-multiply-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-multiply-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_mult_grad(" ir)
         (progn (log:error "validate-vec-multiply-grad: @vec_mult_grad not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-multiply-grad: fmul not found (product rule requires multiply)") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_COMPACT" ir)
         (progn (log:error "validate-vec-multiply-grad: gradient tensor type COMPACT not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-multiply-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-multiply-grad: PASS") t))))

(defun validate-vec-mixed-grad (ir-path)
  "Validates the backward kernel for 03-vec-mixed (scalar float + tensor inputs):
     - @vec_scale_grad is defined
     - %scale_grad present
     - TENSOR_FLOAT_1_GLOBAL_COMPACT present (no access in name)
     - fmul present
     - idx_GRAD is NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mixed-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mixed-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_scale_grad(" ir)
         (progn (log:error "validate-vec-mixed-grad: @vec_scale_grad not found") nil))
     (or (search "%scale_grad" ir)
         (progn (log:error "validate-vec-mixed-grad: scale_grad adjoint variable not found") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_COMPACT" ir)
         (progn (log:error "validate-vec-mixed-grad: A_GRAD tensor type COMPACT not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-mixed-grad: fmul not found (scale*A product rule)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mixed-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mixed-grad: PASS") t))))

(defun validate-matrix-add-grad (ir-path)
  "Validates the backward kernel for 04-matrix-add (2D matrix, two indices):
     - @mat_add_grad is defined
     - TENSOR_FLOAT_2_GLOBAL_COMPACT type present (no access in name)
     - fadd present
     - row_GRAD and col_GRAD are NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-matrix-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-matrix-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @mat_add_grad(" ir)
         (progn (log:error "validate-matrix-add-grad: @mat_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_2_GLOBAL_COMPACT" ir)
         (progn (log:error "validate-matrix-add-grad: 2D gradient tensor type COMPACT not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-matrix-add-grad: fadd not found in backward body") nil))
     (or (not (search "row_GRAD" ir))
         (progn (log:error "validate-matrix-add-grad: row_GRAD should not be emitted (integer)") nil))
     (or (not (search "col_GRAD" ir))
         (progn (log:error "validate-matrix-add-grad: col_GRAD should not be emitted (integer)") nil))
     (progn (log:info "validate-matrix-add-grad: PASS") t))))

(defun validate-tensor-add-grad (ir-path)
  "Validates the backward kernel for 05-tensor-add (3D tensor, three indices):
     - @tensor_add_grad is defined
     - TENSOR_FLOAT_3_GLOBAL_COMPACT type present (no access in name)
     - fadd present
     - d0_GRAD, d1_GRAD, d2_GRAD are NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-tensor-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-tensor-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @tensor_add_grad(" ir)
         (progn (log:error "validate-tensor-add-grad: @tensor_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_3_GLOBAL_COMPACT" ir)
         (progn (log:error "validate-tensor-add-grad: 3D gradient tensor type COMPACT not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-tensor-add-grad: fadd not found in backward body") nil))
     (or (not (search "d0_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d0_GRAD should not be emitted (integer)") nil))
     (or (not (search "d1_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d1_GRAD should not be emitted (integer)") nil))
     (or (not (search "d2_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d2_GRAD should not be emitted (integer)") nil))
     (progn (log:info "validate-tensor-add-grad: PASS") t))))

;; src/macros.lisp — %incomplete-storage-handle-p: fix tensor incomplete detection
;; The previous version fell through to the catch-all for (tensor int 3) which has
;; args length=2, so (>= 2 2) returned NIL (complete) when it should be incomplete.
(defun %incomplete-storage-handle-p (type-spec)
  "Returns T if the type-spec is a storage handle but is missing :address-space.
   Canonical 6-tuple (tensor elem N addr aln ct) and 3-tuple (cell elem addr) are complete."
  (let ((resolved (%resolve-alias-strict type-spec)))
    (when (and (consp resolved) (%storage-handle-type-p resolved))
      (let* ((base (first resolved))
             (args (rest resolved)))
        (cond
          ;; Tensor: only complete when exactly 5 positional args OR :address-space keyword present
          ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
           (cond
             ((= (length args) 5) nil)           ; (elem N addr aln ct): complete
             ((member :address-space args) nil)  ; keyword form: complete
             (t t)))                             ; (elem N) or any other form: INCOMPLETE
          ;; CELL/VECTOR/MATRIX: key-value form or 2+ positional args = complete
          (t
           (let ((is-kw (member :address-space args)))
             (cond
               (is-kw nil)
               ((>= (length args) 2) nil)
               (t t)))))))))


;; src/analysis/structs.lisp
;; Fix: don't fire ensure-template-instantiation for the bare reader op
;; when that op has a registered expression analyzer.  Sub-case 2b
;; handles (set! (op ...) v) correctly via the expression analyzer in
;; :write mode.  Calling ensure-template-instantiation here passes
;; all-arg-types (target-args + value type), which the arity-only
;; fallback inside ensure-template-instantiation can wrongly accept,
;; producing a garbage substitution and a validate-template-arg crash.
;;
;; This was previously masked by arity: when storage handles carried an
;; access template parameter, target-arg count (1) + value-type (1) = 2
;; never matched a 3-param ~ template.  Removing :access dropped the
;; reader template down to 2 params and exposed the latent bug.
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

         ;; Try template instantiation if no direct match.  GUARD:
         ;; Skip when template-op IS the bare op AND op has an expression
         ;; analyzer.  Sub-case 2b will route this through analyze-aref-expression
         ;; in :write mode, which is the correct path for accessor-style ops.
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*)
                                  full-setter-name op)))
             (when (and (gethash template-op *template-registry*)
                        (not (and (eq template-op op)
                                  (gethash op *expression-analyzers*))))
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

