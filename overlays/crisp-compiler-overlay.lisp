;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; ─────────────────────────────────────────────────────────────────────────
;;; 066-vector-matrix
;;;
;;; Change 1: expand-storage-handle-type-specifier
;;;   - Add VECTOR (N=1) and MATRIX (N=2) as syntactic sugar for tensor.
;;;     Both expand to the canonical (tensor T N addr acc aln) 6-tuple.
;;;   - Remove bare-value address-space/access/align matching from TENSOR path.
;;;     Replace with an intelligent "did you mean :key value?" error.
;;;   - CELL path is unchanged.
;;;
;;; Change 2: %incomplete-storage-handle-p
;;;   - Add a tensor fully-expanded case: 5 args (elem N addr acc aln) → not incomplete.
;;;     Previously the 5-arg form tripped the catch-all `(t t)` and returned T
;;;     (incomplete), which would cause a false error for vector/matrix in def-kernel.
;;; ─────────────────────────────────────────────────────────────────────────

;; src/types/validation.lisp

(defun %bare-storage-handle-value-error (item spec)
  "Raises an intelligent error when a bare address-space/access/align value
   is found in a storage handle type spec, suggesting the correct key-value form."
  (cl:cond
    ((cl:member (cl:string item)
                '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':address-space ~(~a~)'?"
            item spec item))
    ((cl:member (cl:string item)
                '("READ-WRITE" "READ-ONLY" "WRITE-ONLY" "READABLE" "WRITEABLE")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':access ~(~a~)'?"
            item spec item))
    ((cl:member (cl:string item)
                '("STD140" "COMPACT")
                :test #'string-equal)
     (error "Bare keyword ~s in type spec ~s. Did you mean ':align ~(~a~)'?"
            item spec item))
    (t
     (error "Unknown keyword ~s in type spec ~s." item spec))))

(defun expand-storage-handle-type-specifier (spec)
  "Expands storage handle type specs into canonical positional forms.
   Cell        → (cell  elem addr access)               [4-tuple, defaults :global :read-write].
   Vector      → (tensor elem 1 addr access align)      [6-tuple, sugar for tensor N=1].
   Matrix      → (tensor elem 2 addr access align)      [6-tuple, sugar for tensor N=2].
   Tensor      → (tensor elem N addr access align)      [6-tuple, defaults :global :read-write :compact].
   Vector/matrix with extra positional arg → error.
   Tensor missing N → crisp-incomplete-type-error.
   Bare address-space/access/align values → intelligent 'did you mean :key value?' error.
   Address-space / access / align MUST use key-value form: :address-space :local etc."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cl:cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (cl:let ((base (cl:first spec)))
       (cl:if (and (symbolp base)
                   (member (symbol-name base)
                           '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (progn
             (cl:when (null (rest spec))
               (error 'crisp-incomplete-type-error :type-spec spec))

             (cl:let* ((args         (rest spec))
                       (element-type (cl:first args))
                       (rest-args    (rest args)))

               (cl:cond

                ;; ── VECTOR: syntactic sugar for (tensor T 1 ...) ─────────────
                ((string-equal (symbol-name base) "VECTOR")
                 (cl:let* ((addr      :global)
                           (acc       :read-write)
                           (aln       :compact)
                           (remaining rest-args))
                   ;; Extra positional arg after element-type is an error.
                   (cl:when (and remaining
                                 (not (keywordp (cl:first remaining))))
                     (error "Invalid type option ~s in vector spec ~s. ~
                             Vector takes no arity argument; use (tensor ~s N) for N > 2."
                            (cl:first remaining) spec element-type))
                   (cl:loop while remaining do
                     (cl:let ((item (pop remaining)))
                       (cl:cond
                         ((string-equal (cl:string item) "ADDRESS-SPACE")
                          (cl:unless remaining
                            (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ACCESS")
                          (cl:unless remaining
                            (error "Missing value for :ACCESS in ~s" spec))
                          (setf acc (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ALIGN")
                          (cl:unless remaining
                            (error "Missing value for :ALIGN in ~s" spec))
                          (setf aln (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "DIRECTION")
                          (cl:when remaining (pop remaining)))
                         (t
                          (%bare-storage-handle-value-error item spec)))))
                   (cl:list (find-symbol "TENSOR" :crisp.compiler)
                            element-type 1 addr acc aln)))

                ;; ── MATRIX: syntactic sugar for (tensor T 2 ...) ─────────────
                ((string-equal (symbol-name base) "MATRIX")
                 (cl:let* ((addr      :global)
                           (acc       :read-write)
                           (aln       :compact)
                           (remaining rest-args))
                   ;; Extra positional arg after element-type is an error.
                   (cl:when (and remaining
                                 (not (keywordp (cl:first remaining))))
                     (error "Invalid type option ~s in matrix spec ~s. ~
                             Matrix takes no arity argument; use (tensor ~s N) for arbitrary arity."
                            (cl:first remaining) spec element-type))
                   (cl:loop while remaining do
                     (cl:let ((item (pop remaining)))
                       (cl:cond
                         ((string-equal (cl:string item) "ADDRESS-SPACE")
                          (cl:unless remaining
                            (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ACCESS")
                          (cl:unless remaining
                            (error "Missing value for :ACCESS in ~s" spec))
                          (setf acc (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ALIGN")
                          (cl:unless remaining
                            (error "Missing value for :ALIGN in ~s" spec))
                          (setf aln (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "DIRECTION")
                          (cl:when remaining (pop remaining)))
                         (t
                          (%bare-storage-handle-value-error item spec)))))
                   (cl:list (find-symbol "TENSOR" :crisp.compiler)
                            element-type 2 addr acc aln)))

                ;; ── TENSOR: bare-value matching retained for idempotency ──────
                ;; The canonical expanded form (tensor T N :global :read-write :compact)
                ;; uses bare positional keywords.  expand-storage-handle-type-specifier
                ;; is called multiple times on the same spec, so the tensor branch
                ;; must accept both key-value pairs (:address-space :local) AND bare
                ;; keyword values (:global, :read-write, :compact).
                ;; Vector and matrix are only ever user-written (once expanded they
                ;; become tensor), so they can enforce strict key-required form.
                ((string-equal (symbol-name base) "TENSOR")
                 (cl:let* ((n-arg        (and rest-args
                                              (not (keywordp (cl:first rest-args)))
                                              (cl:first rest-args)))
                           (rest-after-n (if n-arg (rest rest-args) rest-args))
                           (addr         :global)
                           (acc          :read-write)
                           (aln          :compact)
                           (remaining    rest-after-n))
                   (cl:unless n-arg
                     (error 'crisp-incomplete-type-error :type-spec spec))
                   (cl:loop while remaining do
                     (cl:let ((item (pop remaining)))
                       (cl:cond
                         ;; bare address-space values (canonical form idempotency)
                         ((cl:member (cl:string item)
                                     '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                     :test #'string-equal)
                          (setf addr (intern (string-upcase (cl:string item)) :keyword)))
                         ;; bare access values
                         ((cl:member (cl:string item)
                                     '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                       "READABLE" "WRITEABLE")
                                     :test #'string-equal)
                          (setf acc (intern (string-upcase (cl:string item)) :keyword)))
                         ;; bare align values
                         ((cl:member (cl:string item) '("STD140" "COMPACT")
                                     :test #'string-equal)
                          (setf aln (intern (string-upcase (cl:string item)) :keyword)))
                         ((string-equal (cl:string item) "ADDRESS-SPACE")
                          (cl:unless remaining
                            (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                          (setf addr (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ACCESS")
                          (cl:unless remaining
                            (error "Missing value for :ACCESS in ~s" spec))
                          (setf acc (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "ALIGN")
                          (cl:unless remaining
                            (error "Missing value for :ALIGN in ~s" spec))
                          (setf aln (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                         ((string-equal (cl:string item) "DIRECTION")
                          (cl:when remaining (pop remaining)))
                         (t
                          (error "Invalid type option: ~s in tensor spec ~s" item spec)))))
                   (list base element-type n-arg addr acc aln)))

                ;; ── CELL: original 4-tuple logic, unchanged ──────────────────
                (t
                 (cl:if (null rest-args)
                     (cl:list base element-type :global :read-write)
                     (cl:let ((addr      :global)
                              (acc       :read-write)
                              (remaining rest-args))
                       (cl:loop while remaining do
                         (cl:let ((item (pop remaining)))
                           (cl:cond
                             ((cl:member (cl:string item)
                                         '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                         :test #'string-equal)
                              (setf addr (intern (string-upcase (cl:string item)) :keyword)))
                             ((cl:member (cl:string item)
                                         '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                                           "READABLE" "WRITEABLE")
                                         :test #'string-equal)
                              (setf acc (intern (string-upcase (cl:string item)) :keyword)))
                             ((string-equal (cl:string item) "ADDRESS-SPACE")
                              (cl:unless remaining
                                (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                             ((string-equal (cl:string item) "ACCESS")
                              (cl:unless remaining
                                (error "Missing value for :ACCESS in ~s" spec))
                              (setf acc (intern (string-upcase (cl:string (pop remaining))) :keyword)))
                             ((string-equal (cl:string item) "DIRECTION")
                              (cl:when remaining (pop remaining)))
                             (t
                              (error "Invalid type option: ~s in spec ~s" item spec)))))
                       (cl:list base element-type addr acc)))))))
           spec)))))

;; src/macros.lisp

(defun %incomplete-storage-handle-p (type-spec)
  "Returns T if the type-spec is a storage handle but is missing explicit required keys
   (address-space, access). Handles both the cell 4-tuple and tensor 6-tuple canonical forms.
   A fully-expanded tensor spec (tensor elem N addr acc aln) — 5 args after head — is complete."
  (let ((resolved (%resolve-alias-strict type-spec)))
    (when (and (consp resolved) (%storage-handle-type-p resolved))
      (let* ((base (first resolved))
             (args (rest resolved)))
        (cond
          ;; Tensor fully expanded: 5 args (elem N addr acc aln) → complete.
          ;; This also covers vector and matrix after sugar expansion (both become tensor).
          ((and (symbolp base)
                (string-equal (symbol-name base) "TENSOR")
                (= (length args) 5))
           nil)
          ;; Cell/original: key-value form or 3-arg positional form.
          (t
           (let ((is-kw (or (member :address-space args) (member :access args))))
             (cond
               (is-kw
                (let ((has-addr (member :address-space args))
                      (has-acc  (member :access args)))
                  (not (and has-addr has-acc))))
               ((= (length args) 3) nil)
               (t t)))))))))

