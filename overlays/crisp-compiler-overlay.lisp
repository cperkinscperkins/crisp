;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; 078-storage-handle-reinterpretation
;;; make-cell / make-vector / make-matrix / make-tensor
;;; ============================================================

;;; ── helpers ─────────────────────────────────────────────────

(defun %mv-resolve-src-type (src-type)
  "Resolve a source storage-handle type to a canonical list.
   Handles type aliases, mangled symbols, (vector ...), (matrix ...) sugar,
   and already-canonical (tensor ...) / (cell ...) lists.
   Always returns the fully-expanded canonical form:
     (CELL   elem addr access)
     (TENSOR elem N addr access align)
   Returns NIL on failure."
  (cl:labels ((fully-expand (x)
                "Recursively resolve alias then expand sugar (vector/matrix -> tensor)."
                (cl:let* ((r  (resolve-type-alias x))
                           (ex (cond
                                 ;; Already a list — try expanding sugar
                                 ((consp r)
                                  (cl:let ((h (symbol-name (cl:first r))))
                                    (cond
                                      ;; CELL: already canonical
                                      ((string-equal h "CELL") r)
                                      ;; TENSOR: already canonical
                                      ((string-equal h "TENSOR") r)
                                      ;; VECTOR/MATRIX: expand via standard expander
                                      ((or (string-equal h "VECTOR")
                                           (string-equal h "MATRIX"))
                                       (expand-storage-handle-type-specifier r))
                                      (t r))))
                                 ;; Symbol: try expand-storage-handle-type-specifier
                                 ((symbolp r)
                                  (cl:let ((e (expand-storage-handle-type-specifier r)))
                                    (if (consp e) (fully-expand e) r)))
                                 (t r))))
                  ex)))
    (cl:let ((result (fully-expand src-type)))
      (when (consp result) result))))

(defun %mv-source-head (canon)
  "Return the head keyword (:cell or :tensor) from a canonical type, or NIL."
  (when (consp canon)
    (cl:let ((h (symbol-name (cl:first canon))))
      (cond ((string-equal h "CELL")   :cell)
            ((string-equal h "TENSOR") :tensor)
            (t nil)))))

(defun %mv-source-elem (canon)
  "Return the element-type symbol from a canonical storage handle type."
  (cl:second canon))

(defun %mv-source-addr (canon)
  "Return the address-space keyword from a canonical storage handle type."
  (cond ((eq (%mv-source-head canon) :cell)   (cl:third canon))
        ((eq (%mv-source-head canon) :tensor)  (cl:fourth canon))
        (t :global)))

(defun %mv-source-access (canon)
  "Return the access keyword from a canonical storage handle type."
  (cond ((eq (%mv-source-head canon) :cell)   (cl:fourth canon))
        ((eq (%mv-source-head canon) :tensor)  (cl:fifth canon))
        (t :read-write)))

(defun %mv-source-align (canon)
  "Return the :align keyword from a canonical storage handle type (tensors only)."
  (when (eq (%mv-source-head canon) :tensor)
    (cl:sixth canon)))

(defun %mv-is-struct-elem (elem-type)
  "Returns T if ELEM-TYPE is a registered def-struct type."
  (cl:let ((ct (gethash elem-type *crisp-types*)))
    (and ct (eq (crisp-type-category ct) :struct))))

(defun %mv-parse-kwargs (kwarg-list)
  "Parse a flat keyword-arg list like (:offset 2 :length 5 :major :row).
   Returns a plist."
  (cl:let ((result '()))
    (cl:loop for (k v) on kwarg-list by #'cl:cddr
             when (keywordp k) do (setf (cl:getf result k) v))
    result))

(defun %mv-eval-integer (form)
  "Evaluate a compile-time integer form (bare integer or quoted integer).
   Returns an integer or NIL."
  (cond ((integerp form) form)
        ((and (consp form) (eq (cl:first form) 'quote) (integerp (cl:second form)))
         (cl:second form))
        (t nil)))

(defun %mv-eval-list (form)
  "Evaluate a compile-time list form like '(2 3 4) or (2 3 4) for extents/strides.
   Returns a list of integers or NIL."
  (cond ((and (consp form) (eq (cl:first form) 'quote) (listp (cl:second form)))
         (cl:second form))
        ((and (consp form) (every #'integerp form))
         form)
        (t nil)))

;;; ── compile-time restrictions ────────────────────────────────

(defun %mv-check-restrictions (op src-canon new-elem location)
  "Enforce compile-time restrictions for view constructors.
   Signals a compiler-error on violation."
  (cl:let* ((src-elem  (%mv-source-elem src-canon))
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

(defun %mv-result-tensor-type (new-elem rank addr access align)
  "Build canonical tensor result type."
  `(tensor ,new-elem ,rank ,addr ,access ,align))

;;; ── compute strides list (compile-time) ──────────────────────

(defun %mv-row-major-strides (extents)
  "Compute row-major strides for given extents list.
   Innermost stride = 1; stride[k] = product(extents[k+1..N-1])."
  (cl:let* ((n (cl:length extents))
             (strides (make-list n :initial-element 1)))
    (cl:loop for k from (- n 2) downto 0
             do (setf (cl:nth k strides)
                      (* (cl:nth (1+ k) strides) (cl:nth (1+ k) extents))))
    strides))

(defun %mv-col-major-strides (extents)
  "Compute col-major strides for a 2D matrix with extents [height width].
   stride_row=1, stride_col=height."
  (cl:let ((height (cl:first extents)))
    (list 1 height)))

;;; ── main analyzer ────────────────────────────────────────────

(defun analyze-make-view-expression (expr env context location)
  "Analyzes make-cell / make-vector / make-matrix / make-tensor view constructors.
   These create a new Storage Handle struct that reinterprets existing storage.
   No memory is allocated; the result is a new tensor/cell value derived from
   the source's parent storage pointer.

   Syntax:
     (make-cell   src elem-type &key (offset 0))
     (make-vector src elem-type &key length (offset 0))
     (make-matrix src elem-type width height &key (major :row) (offset 0) strides)
     (make-tensor src elem-type extents-list &key (offset 0) strides)

   Returns a semantic-make-view node."
  (cl:let* ((op       (cl:first expr))
             (args     (cl:rest expr))
             ;; --- source ---
             (src-expr (cl:first args))
             (src-node (analyze-expression src-expr env context (append location '(1))))
             (src-type (semantic-node-type src-node))
             (src-canon (%mv-resolve-src-type src-type)))

    (unless src-canon
      (error "~a: Cannot resolve source type ~a to a storage handle type" op src-type))
    (unless (%mv-source-head src-canon)
      (error "~a: Source type ~a is not a storage handle (cell/vector/matrix/tensor)" op src-type))

    (cl:ecase op

      ;; ── make-cell ────────────────────────────────────────────────────
      (make-cell
       (cl:let* ((new-elem  (cl:second args))
                 (kwargs    (%mv-parse-kwargs (cl:nthcdr 2 args)))
                 (offset    (or (%mv-eval-integer (cl:getf kwargs :offset)) 0))
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

      ;; ── make-vector ──────────────────────────────────────────────────
      (make-vector
       (cl:let* ((new-elem  (cl:second args))
                 (kwargs    (%mv-parse-kwargs (cl:nthcdr 2 args)))
                 (offset    (or (%mv-eval-integer (cl:getf kwargs :offset)) 0))
                 (length    (%mv-eval-integer (cl:getf kwargs :length))) ; NIL = auto
                 (addr      (%mv-source-addr src-canon))
                 (access    (%mv-source-access src-canon))
                 (src-align (%mv-source-align src-canon))
                 (align     (%mv-result-align src-align nil nil)))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 1 addr access align)
          :source-node src-node
          :element-type new-elem
          :rank        1
          :offset      offset
          :length      length  ; NIL means auto-compute at runtime
          :extents     (when length (list length))
          :strides     nil
          :major       :row
          :source-location location)))

      ;; ── make-matrix ──────────────────────────────────────────────────
      (make-matrix
       (cl:let* ((new-elem  (cl:second args))
                 (width     (%mv-eval-integer (cl:third args)))
                 (height    (%mv-eval-integer (cl:fourth args)))
                 (kwargs    (%mv-parse-kwargs (cl:nthcdr 4 args)))
                 (offset    (or (%mv-eval-integer (cl:getf kwargs :offset)) 0))
                 (major-kw  (or (cl:getf kwargs :major) :row))
                 (strides-form (cl:getf kwargs :strides))
                 (strides   (%mv-eval-list strides-form))
                 (explicit-strides-p (not (null strides)))
                 (col-p     (cl:member major-kw '(:col col) :test #'string-equal))
                 (extents   (list height width))
                 (result-strides
                  (cond (explicit-strides-p strides)
                        (col-p (%mv-col-major-strides extents))
                        (t     (%mv-row-major-strides extents))))
                 (length    (* width height))
                 (addr      (%mv-source-addr src-canon))
                 (access    (%mv-source-access src-canon))
                 (src-align (%mv-source-align src-canon))
                 (align     (%mv-result-align src-align explicit-strides-p col-p)))
         (unless (and width height)
           (error "make-matrix: width and height must be compile-time integer literals"))
         (%mv-check-restrictions op src-canon new-elem location)
         (make-semantic-make-view
          :type        (%mv-result-tensor-type new-elem 2 addr access align)
          :source-node src-node
          :element-type new-elem
          :rank        2
          :offset      offset
          :length      length
          :extents     extents
          :strides     result-strides
          :major       (if col-p :col :row)
          :source-location location)))

      ;; ── make-tensor ──────────────────────────────────────────────────
      (make-tensor
       (cl:let* ((new-elem     (cl:second args))
                 (extents-form (cl:third args))
                 (extents      (%mv-eval-list extents-form))
                 (kwargs       (%mv-parse-kwargs (cl:nthcdr 3 args)))
                 (offset       (or (%mv-eval-integer (cl:getf kwargs :offset)) 0))
                 (strides-form (cl:getf kwargs :strides))
                 (strides      (%mv-eval-list strides-form))
                 (explicit-strides-p (not (null strides)))
                 (rank         (when extents (cl:length extents)))
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
          :type        (%mv-result-tensor-type new-elem rank addr access align)
          :source-node src-node
          :element-type new-elem
          :rank        rank
          :offset      offset
          :length      length
          :extents     extents
          :strides     result-strides
          :major       :row
          :source-location location))))))

;;; ── register analyzers ───────────────────────────────────────

;; src/analysis/structs.lisp
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

;;; ── semantic-node-type / semantic-node-source-location redefs ─
;;; src/analysis/core.lisp

(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
   Extended to handle semantic-make-view (078)."
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    ;; 078 view constructors
    (semantic-make-view (semantic-make-view-type node))))

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
   Extended to handle semantic-make-view (078)."
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    ;; 078 view constructors
    (semantic-make-view (semantic-make-view-source-location node))))


;;; ── codegen ─────────────────────────────────────────────────
;;; src/codegen.lisp

(defun %mv-build-const-i64-array (builder rank values)
  "Build an LLVM [rank x i64] constant array from a list of integers.
   If VALUES is shorter than rank, remaining slots are filled with 0."
  (cl:let* ((i64      (llvm-int64-type))
             (arr-type (llvm-array-type i64 rank))
             (undef    (llvm-get-undef arr-type)))
    (cl:loop for k from 0 below rank
             with result = undef
             for v = (or (cl:nth k values) 0)
             do (setf result
                      (llvm-build-insert-value builder result
                                               (llvm-const-int i64 v nil)
                                               k (format nil "arr_~d" k)))
             finally (cl:return result))))

(defun %mv-build-zero-i64-array (rank)
  "Build a constant all-zero [rank x i64] array."
  (llvm-const-null (llvm-array-type (llvm-int64-type) rank)))

(defun %mv-bump-ptr (builder base-ptr offset-bytes addr-space)
  "GEP base-ptr by offset-bytes (an i64 LLVM value).
   Returns the new ptr in the same address space."
  (cffi:with-foreign-object (indices :pointer 1)
    (setf (cffi:mem-aref indices :pointer 0) offset-bytes)
    (cl:let* ((ptr-i8 (llvm-build-in-bounds-gep2
                       builder (llvm-int8-type) base-ptr indices 1 "mv_bumped_i8"))
               (ptr-as (llvm-get-pointer-address-space (llvm-type-of ptr-i8))))
      (declare (ignore addr-space ptr-as))
      ptr-i8)))

(defun %mv-build-storage (builder module addr-space src-parent new-ptr new-bytesize)
  "Build a new STORAGE_{addr} struct value from ptr and bytesize."
  (declare (ignore module))
  (cl:let* ((storage-type (crisp-type-to-llvm-type `(storage ,addr-space) module))
             (s0 (llvm-build-insert-value builder (llvm-get-undef storage-type)
                                          new-ptr 0 "mv_storage_ptr"))
             (s1 (llvm-build-insert-value builder s0 new-bytesize 1 "mv_storage_bs")))
    (declare (ignore src-parent))
    s1))

(defmethod generate-node-ir ((node semantic-make-view)
                              builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for make-cell / make-vector / make-matrix / make-tensor.
   Builds a new Storage Handle struct value that reinterprets existing storage.
   No allocation occurs; the result is computed entirely from the source value."
  (cl:let* ((result-type   (semantic-make-view-type node))
             (src-node      (semantic-make-view-source-node node))
             (elem-type-sym (semantic-make-view-element-type node))
             (rank          (semantic-make-view-rank node))
             (offset-elems  (or (semantic-make-view-offset node) 0))
             (explicit-len  (semantic-make-view-length node))
             (extents       (semantic-make-view-extents node))
             (strides       (semantic-make-view-strides node))

             ;; load source value
             (src-val (generate-node-ir src-node builder module var-env
                                        di-builder di-scope location-map))

             ;; extract source parent storage: field 0 of any tensor/cell struct
             (src-parent  (llvm-build-extract-value builder src-val 0 "mv_src_parent"))
             (src-ptr     (llvm-build-extract-value builder src-parent 0 "mv_src_ptr"))
             (src-bytesize (llvm-build-extract-value builder src-parent 1 "mv_src_bs"))

             ;; element size
             (elem-llvm-type (crisp-type-to-llvm-type elem-type-sym module))
             (elem-size      (llvm-size-of elem-llvm-type))

             ;; compute byte offset and new ptr/bytesize
             (offset-bytes
              (if (zerop offset-elems)
                  (llvm-const-int (llvm-int64-type) 0 nil)
                  (llvm-build-mul builder
                                  (llvm-const-int (llvm-int64-type) offset-elems nil)
                                  elem-size "mv_off_bytes")))
             (new-ptr
              (if (zerop offset-elems)
                  src-ptr
                  (%mv-bump-ptr builder src-ptr offset-bytes
                                (%mv-source-addr (list (cl:first result-type) nil
                                                       (cl:third result-type))))))
             (new-bytesize
              (if (zerop offset-elems)
                  src-bytesize
                  (llvm-build-sub builder src-bytesize offset-bytes "mv_new_bs")))

             ;; address space from result type
             (addr-space (cond ((string-equal (symbol-name (cl:first result-type)) "CELL")
                                (cl:third result-type))
                               (t (cl:fourth result-type))))

             ;; new parent storage struct
             (new-storage (%mv-build-storage builder module addr-space
                                             src-parent new-ptr new-bytesize))

             ;; result struct type
             (mangled-name (mangle-template-struct-name (cl:first result-type)
                                                        (cl:rest result-type)))
             (result-struct-type (ensure-struct-llvm-type mangled-name))
             (result-undef (llvm-get-undef result-struct-type)))

    (log:info "make-view: op=~a rank=~d elem=~a mangled=~a offset=~d"
              (cl:first result-type) rank elem-type-sym mangled-name offset-elems)

    (cond

     ;; ── cell (rank=0): { STORAGE, byte-offset-i64 } ──────────────────
     ((= rank 0)
      (cl:let* (;; For cell we keep original ptr, store offset in field 1
                ;; (consistent with existing cell struct convention)
                (orig-storage (%mv-build-storage builder module addr-space
                                                 src-parent src-ptr src-bytesize))
                (byte-offset-val
                 (if (zerop offset-elems)
                     (llvm-const-int (llvm-int64-type) 0 nil)
                     (llvm-build-mul builder
                                     (llvm-const-int (llvm-int64-type) offset-elems nil)
                                     elem-size "mv_cell_off_bytes")))
                (c0 (llvm-build-insert-value builder result-undef orig-storage 0 "mv_cell_parent"))
                (c1 (llvm-build-insert-value builder c0 byte-offset-val 1 "mv_cell_offset")))
        c1))

     ;; ── tensor/vector/matrix (rank>=1) ────────────────────────────────
     (t
      (cl:let* (;; all offset dims = 0 (ptr was already bumped)
                (zero-offsets (%mv-build-zero-i64-array rank))

                ;; strides: explicit or row-major computed
                (stride-vals (or strides (%mv-row-major-strides (or extents (make-list rank :initial-element 1)))))
                (stride-arr  (%mv-build-const-i64-array builder rank stride-vals))

                ;; extents
                (extent-vals (or extents (make-list rank :initial-element 0)))
                (extent-arr  (%mv-build-const-i64-array builder rank extent-vals))

                ;; length: explicit constant or runtime udiv
                (length-val
                 (if explicit-len
                     (llvm-const-int (llvm-int64-type) explicit-len nil)
                     ;; auto-length: floor(new_bytesize / sizeof(elem))
                     (llvm-build-udiv builder new-bytesize elem-size "mv_auto_len")))

                ;; assemble tensor struct: { STORAGE, offsets, strides, extents, length }
                (t0 (llvm-build-insert-value builder result-undef new-storage  0 "mv_t_parent"))
                (t1 (llvm-build-insert-value builder t0 zero-offsets  1 "mv_t_offsets"))
                (t2 (llvm-build-insert-value builder t1 stride-arr    2 "mv_t_strides"))
                (t3 (llvm-build-insert-value builder t2 extent-arr    3 "mv_t_extents"))
                (t4 (llvm-build-insert-value builder t3 length-val    4 "mv_t_length")))
        t4)))))

;;; ── %mv-resolve-src-type v2: handle mangled symbols ──────────────
;;; Appended after the initial definition to override it.
;;; In HOIST tests, kernel parameters of tensor type appear as mangled
;;; symbols (e.g. TENSOR_INT_1_GLOBAL_READ-WRITE_COMPACT) rather than
;;; as canonical lists. The original version didn't handle those.
;;; src/analysis/core.lisp (conceptually)
(defun %mv-resolve-src-type (src-type)
  "Resolve a source storage-handle type to a canonical list.
   Handles type aliases, mangled symbols (e.g. TENSOR_INT_1_...),
   (vector ...) / (matrix ...) sugar, and already-canonical lists.
   Returns (CELL elem addr access) or (TENSOR elem N addr access align), or NIL."
  (cl:labels ((fully-expand (x)
                "Recursively resolve alias or unmangle, then expand sugar."
                (cl:let* ((r  (resolve-type-alias x))
                           (ex (cond
                                 ;; Already a canonical list
                                 ((consp r)
                                  (cl:let ((h (symbol-name (cl:first r))))
                                    (cond
                                      ((string-equal h "CELL")   r)
                                      ((string-equal h "TENSOR") r)
                                      ((or (string-equal h "VECTOR")
                                           (string-equal h "MATRIX"))
                                       (expand-storage-handle-type-specifier r))
                                      (t r))))
                                 ;; Symbol: try unmangle first (for mangled names like
                                 ;; TENSOR_INT_1_GLOBAL_READ-WRITE_COMPACT), then alias expand
                                 ((symbolp r)
                                  (cl:let* ((unmangled (unmangle-template-struct-name r))
                                             ;; unmangle returns a list like (TENSOR INT 1 ...) or nil
                                             (unm-head  (and (consp unmangled)
                                                             (symbolp (cl:first unmangled))
                                                             (symbol-name (cl:first unmangled)))))
                                    (cond
                                      ;; Successfully unmangled to a TENSOR or CELL form
                                      ((and unm-head (string-equal unm-head "TENSOR"))
                                       ;; reconstruct canonical 6-tuple from unmangled args
                                       (expand-storage-handle-type-specifier unmangled))
                                      ((and unm-head (string-equal unm-head "CELL"))
                                       (expand-storage-handle-type-specifier unmangled))
                                      ;; Not a mangled name — try normal expansion
                                      (t
                                       (cl:let ((e (expand-storage-handle-type-specifier r)))
                                         (if (consp e) (fully-expand e) r))))))
                                 (t r))))
                  ex)))
    (cl:let ((result (fully-expand src-type)))
      (when (consp result) result))))


;;; ── Fix boundp '*current-module* broken for symbol macros ───────────────────
;;; (boundp '*current-module*) always returns NIL because *current-module* is
;;; defined via define-symbol-macro, not defvar.  The correct check is whether
;;; *compiler-session* is bound and has a module.  The broken check caused
;;; template callbacks to always take the (eval form) path (analysis only, no IR),
;;; so template accessor functions like length~ never got LLVM function bodies.
;;; This manifested as test 17 producing a `declare` instead of a `define` for
;;; @length__tensor_short_1_global_read_write_compact.
;;;
;;; Fix: redefine %instantiate-template-if-needed and types-equivalent-p with
;;; the correct module availability check.

;; src/types/validation.lisp
(defun %instantiate-template-if-needed (base-type template-args mangled-name)
  "Helper: Attempts to instantiate a template if not already instantiated.
   Returns T if template exists/instantiated successfully, NIL otherwise.
   FIX3: Use (and *compiler-session* (compiler-session-module *compiler-session*))
   instead of (boundp '*current-module*) — the latter always returns NIL because
   *current-module* is a define-symbol-macro, not a defvar special variable."
  (cl:let ((templates (or (gethash base-type *template-registry*)
                          (cl:let ((found nil))
                            (maphash (cl:lambda (k v)
                                       (cl:when (and (symbolp k)
                                                     (string-equal (symbol-name k)
                                                                   (symbol-name base-type)))
                                         (cl:setf found v)))
                                     *template-registry*)
                            found))))
    (cl:cond
      ;; No templates found for this base type
      ((null templates) nil)

      ;; Template instantiator not available
      ((not (and (boundp '*template-instantiator-fn*)
                 *template-instantiator-fn*))
       (log:warn "Template instantiator not bound/found")
       nil)

      ;; Instantiate the template
      (t
       (funcall *template-instantiator-fn* base-type template-args
         (lambda (form loc)
           (declare (ignore loc))
           ;; Skip the constructor _WRAPPER function when compiling to IR.
           ;; The wrapper has compile-time fields (e.g. type-spec) whose LLVM
           ;; mapping is void — valid as return type but INVALID as a parameter.
           ;; The wrapper is never called at GPU runtime, so it needs no IR body.
           ;; We still eval it so the overload gets registered in *function-table*.
           (let ((is-wrapper
                  (and (consp form)
                       (symbolp (car form))
                       (string-equal (symbol-name (car form)) "DEF-FUNCTION")
                       (symbolp (second form))
                       (search "_WRAPPER" (symbol-name (second form))
                               :test #'char-equal))))
             (if (and (not is-wrapper)
                      *compiler-session*
                      (compiler-session-module *compiler-session*))
                 (compile-toplevel-form form nil
                                        *current-module*
                                        *current-builder*
                                        *current-di-builder*
                                        *current-di-compile-unit*
                                        *current-location-map*)
                 (eval form)))))
       ;; Return T if template was found and instantiated
       t))))

;; src/types/validation.lisp
(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling.
   FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels
   before mangling comparison. This supports def-type aliases for any template type.
   FIX2: Use %type-spec-equal-p (package-agnostic) for cons-vs-cons case.
   FIX3: Use compiler-session check instead of broken (boundp '*current-module*)."
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
                              (let ((is-wrapper
                                     (and (consp form)
                                          (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "DEF-FUNCTION")
                                          (symbolp (second form))
                                          (search "_WRAPPER" (symbol-name (second form))
                                                  :test #'char-equal))))
                                (if (and (not is-wrapper)
                                         *compiler-session*
                                         (compiler-session-module *compiler-session*))
                                    (compile-toplevel-form form location
                                                           *current-module*
                                                           *current-builder*
                                                           *current-di-builder*
                                                           *current-di-compile-unit*
                                                           *current-location-map*)
                                    (eval form)))))))
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
