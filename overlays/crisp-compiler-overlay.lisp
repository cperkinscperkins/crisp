;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;;; ============================================================
;;;; 097-contiguous-term
;;;; ============================================================

;; NOTE: (def-enumeration contiguity :last :first) must live in src/enums.lisp
;; (not here) because def-enumeration exports symbols that would cause a
;; package-at-variance fatal error when asdf:make recompiles src/package.lisp.
;; Apply put_temp_files_here/patch-enums-contiguous-term.md to src/enums.lisp
;; and put_temp_files_here/patch-package-contiguous-term.md to src/package.lisp
;; before rebuilding.

;; ── Helper ────────────────────────────────────────────────────
(defun %get-tensor-ct (canon)
  "Extracts the :contiguous-term keyword (7th element, index 6) from a
   canonical tensor type tuple, defaulting to :last when absent."
  (if (and (listp canon) (>= (length canon) 7))
      (nth 6 canon)
      :last))

;; ── src/types/validation.lisp ─────────────────────────────────
;; expand-storage-handle-type-specifier — extends the canonical form from a
;; 6-tuple (tensor elem N addr access align) to a 7-tuple by appending
;; :contiguous-term. Accepts :last, :first, and the 2D-matrix-only aliases
;; :row-major (→ :last) and :col-major (→ :first).
(defun expand-storage-handle-type-specifier (spec)
  "Expands storage handle type specs into canonical positional forms.
   Cell        → (cell  elem addr access)                  [4-tuple].
   Vector      → (tensor elem 1 addr access align ct)      [7-tuple, sugar for tensor N=1].
   Matrix      → (tensor elem 2 addr access align ct)      [7-tuple, sugar for tensor N=2].
   Tensor      → (tensor elem N addr access align ct)      [7-tuple].
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
                           (acc       :read-write)
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
                          (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                          (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
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
                            element-type 1 addr acc aln ct)))

                ;; ── MATRIX ──────────────────────────────────────────
                ((string-equal (symbol-name base) "MATRIX")
                 (let* ((addr      :global)
                           (acc       :read-write)
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
                          (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
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
                            element-type 2 addr acc aln ct)))

                ;; ── TENSOR ──────────────────────────────────────────
                ;; Canonical form idempotency: accepts both key-value pairs and
                ;; bare keyword values (for :last / :first too, so re-expansion is stable).
                ((string-equal (symbol-name base) "TENSOR")
                 (let* ((n-arg        (and rest-args
                                              (not (keywordp (first rest-args)))
                                              (first rest-args)))
                           (rest-after-n (if n-arg (rest rest-args) rest-args))
                           (addr         :global)
                           (acc          :read-write)
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
                         ;; bare access values
                         ((member (string item)
                                     '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                       "READABLE" "WRITEABLE")
                                     :test #'string-equal)
                          (setf acc (intern (string-upcase (string item)) :keyword)))
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
                          (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
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
                               ;; :row-major is only valid for 2D; guard with n-arg
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
                   (list base element-type n-arg addr acc aln ct)))

                ;; ── CELL ────────────────────────────────────────────
                (t
                 (if (null rest-args)
                     (list base element-type :global :read-write)
                     (let ((addr      :global)
                              (acc       :read-write)
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
                              (setf acc (intern (string-upcase (string item)) :keyword)))
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                              (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "DIRECTION")
                              (when remaining (pop remaining)))
                             (t (error "Invalid type option: ~s in spec ~s" item spec)))))
                       (list base element-type addr acc)))))))
           spec)))))

;; ── src/compiler.lisp ─────────────────────────────────────────
;; register-builtins — adds (Ct contiguity :last) to the tensor template and
;; updates all tensor-using template signatures to include the Ct parameter.
(defun register-builtins ()
  "Registers built-in types and templates.
   Extended for 097-contiguous-term: tensor now has Ct (contiguity) as a 6th template param."
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
  ;; Ct is the contiguous-term compile-time property (:last = row-major, :first = col-major).
  (eval '(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                               (Acc access :read-write) (Aln align :compact)
                               (Ct contiguity :last))
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
             (access            access      :c-t Acc)
             (align             align       :c-t Aln)
             (contiguous-term   contiguity  :c-t Ct))))

  ;; bytes~ helper for tensor.
  (register-template 'bytes~
    '(To (N integer 1) (Addr address-space :global)
      (Acc access :read-write) (Aln align :compact) (Ct contiguity :last)) nil
    '(def-function bytes~ (t1)
       (declare (function ((tensor To N Addr Acc Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((tensor To N Addr Acc Aln Ct) => ulong))

  ;; num-rows — return extents[0] (height dimension) of a 2D tensor.
  (register-template 'num-rows
    '(To (Addr address-space :global) (Acc access :read-write)
      (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-rows (m)
       (declare (function ((tensor To 2 Addr Acc Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 0)))
    '((tensor To 2 Addr Acc Aln Ct) => ulong))

  ;; num-cols — return extents[1] (width dimension) of a 2D tensor.
  (register-template 'num-cols
    '(To (Addr address-space :global) (Acc access :read-write)
      (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-cols (m)
       (declare (function ((tensor To 2 Addr Acc Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 1)))
    '((tensor To 2 Addr Acc Aln Ct) => ulong))

  ;; get-layout — classify 2D tensor layout at runtime via stride inspection.
  (register-template 'get-layout
    '(To (Addr address-space :global) (Acc access :read-write)
      (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function get-layout (m)
       (declare (function ((tensor To 2 Addr Acc Aln Ct) => int)))
       (declare (crisp-system-generated))
       (if (= (~ (strides~ m) 1) 1ul)
           0
           (if (= (~ (strides~ m) 0) 1ul)
               1
               2)))
    '((tensor To 2 Addr Acc Aln Ct) => int))

  ;; contiguous-term~ — returns compile-time contiguity value for any tensor.
  ;; When instantiated with Ct=:last, body becomes (return :last) → enum integer 0.
  (register-template 'contiguous-term~
    '(To (N integer 1) (Addr address-space :global)
      (Acc access :read-write) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function contiguous-term~ (t1)
       (declare (function ((tensor To N Addr Acc Aln Ct) => contiguity)))
       (declare (crisp-system-generated))
       (return Ct))
    '((tensor To N Addr Acc Aln Ct) => contiguity))

  (log:info "Built-in structs registered."))

;; ── src/autodiff.lisp ─────────────────────────────────────────
;; Preserve 7th element (contiguous-term) when reconstructing tensor types.
(defun %ensure-tensor-read-write (type-spec)
  "If TYPE-SPEC is a tensor/vector/matrix, returns the canonical 7-tuple with
   :access replaced by :read-write. Non-tensor types are returned unchanged."
  (if (%crisp-tensor-type-p type-spec)
      (let ((c (canonicalize-type-specifier type-spec)))
        ;; canonical form: (tensor elem N addr access align ct)
        ;;                   0      1    2  3    4      5     6
        (list (nth 0 c) (nth 1 c) (nth 2 c)
                 (nth 3 c) :read-write (nth 5 c) (%get-tensor-ct c)))
      type-spec))

(defun %integer-tensor-elem-to-float (type-spec)
  "Replaces the element type of an integer tensor with its float analog:
   64-bit integers (long, ulong) → double; all others → float.
   Also forces :access to :read-write (gradient tensors are always writable).
   Returns TYPE-SPEC unchanged if it is not an integer tensor."
  (if (%crisp-integer-tensor-type-p type-spec)
      (let* ((canonical (canonicalize-type-specifier type-spec))
                (elem      (second canonical))
                (info      (gethash elem *crisp-types*))
                (float-elem (if (and info (>= (crisp-type-size info) 64))
                                'double
                                'float)))
        (list (nth 0 canonical) float-elem (nth 2 canonical)
              (nth 3 canonical) :read-write  (nth 5 canonical) (%get-tensor-ct canonical)))
      (%ensure-tensor-read-write type-spec)))

;; ── src/analysis/structs.lisp ─────────────────────────────────
;; %mv-result-tensor-type — canonical 7-tuple builder (adds ct parameter).
(defun %mv-result-tensor-type (new-elem rank addr access align &optional (ct :last))
  "Build canonical tensor result type (7-tuple)."
  `(tensor ,new-elem ,rank ,addr ,access ,align ,ct))

;; analyze-transpose-expression — ct is preserved, not flipped.
;; contiguous-term reflects the backing data's declared storage order,
;; which does not change when applying a stride-view transpose.
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

;; analyze-col-expression — 1D column result; :last (single dim, contiguity trivial)
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

;; ── src/analysis/structs.lisp ─────────────────────────────────
;; analyze-make-view-expression — sets contiguous-term based on :major keyword.
;; Only make-matrix changes: col-major → ct=:first, row-major → ct=:last.
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

;; ── src/metadata-val.lisp ────────────────────────────────────
;; 074 validator functions updated for 7-tuple tensor names (with _LAST suffix).
(defun validate-074-02-scratch-vector-propagation-ir (ir-path)
  "Validates scratch vector propagation IR (updated for 7-tuple tensor names)."
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
     (or (search "fun_c_tensor_int_1_local_read_write_compact_last_int" ir)
         (progn (log:error "validate-074-02: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-02: PASS") t))))

(defun validate-074-03-scratch-tensor-propagation-ir (ir-path)
  "Validates scratch tensor (N=3) propagation IR (updated for 7-tuple tensor names)."
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
     (or (search "TENSOR_FLOAT_3_LOCAL_READ-WRITE_COMPACT_LAST" ir)
         (progn (log:error "validate-074-03: expected TENSOR_FLOAT_3_LOCAL_READ-WRITE_COMPACT_LAST type in IR") nil))
     (or (search "fun_c_tensor_float_3_local_read_write_compact_last_int" ir)
         (progn (log:error "validate-074-03: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-03: PASS") t))))

(defun validate-074-04-scratch-matrix-propagation-ir (ir-path)
  "Validates scratch matrix (N=2) propagation IR (updated for 7-tuple tensor names)."
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
     (or (search "TENSOR_FLOAT_2_LOCAL_READ-WRITE_COMPACT_LAST" ir)
         (progn (log:error "validate-074-04: expected TENSOR_FLOAT_2_LOCAL_READ-WRITE_COMPACT_LAST type in IR") nil))
     (or (search "fun_c_tensor_float_2_local_read_write_compact_last_ulong_ulong" ir)
         (progn (log:error "validate-074-04: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-04: PASS") t))))

;; ── src/codegen.lisp ──────────────────────────────────────────
;; Override generate-node-ir for semantic-eq to handle enum/keyword lhs types.
;; The generated defmethod from def-comparison-codegen calls (crisp-type-category lhs-type)
;; unconditionally. When lhs-type is NIL (e.g. 'contiguity' is in *crisp-enums* not
;; *crisp-types*), that crashes with "NIL is not of type CRISP-TYPE".
;; Enums and keywords compile to i32, so nil lhs-type → treat as signed integer comparison.
(defmethod generate-node-ir ((node semantic-eq) builder module var-env di-builder di-scope location-map)
  "Generates IR for =, guarding against NIL lhs-type for enum/keyword operands."
  (multiple-value-bind (lhs lhs-loc)
      (generate-node-ir (semantic-eq-left-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore lhs-loc))
    (multiple-value-bind (rhs rhs-loc)
        (generate-node-ir (semantic-eq-right-arg node) builder module var-env di-builder di-scope location-map)
      (declare (ignore rhs-loc))
      (let* ((lhs-type-name (get-single-value-type (semantic-eq-left-arg node)))
             (lhs-type (gethash lhs-type-name *crisp-types*))
             (lhs (extract-primary-value builder lhs (semantic-node-type (semantic-eq-left-arg node))))
             (rhs (extract-primary-value builder rhs (semantic-node-type (semantic-eq-right-arg node))))
             ;; Guard: enums and keywords are NOT in *crisp-types*; they compile to i32 → signed int.
             (is-float    (and lhs-type (eq (crisp-type-category lhs-type) :float)))
             (cmp-inst
              (if is-float
                  (llvm-build-fcmp builder +llvm-real-oeq+ lhs rhs "fcmp_tmp")
                  (llvm-build-icmp builder +llvm-int-eq+ lhs rhs "icmp_tmp"))))
        (values (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext") nil)))))

