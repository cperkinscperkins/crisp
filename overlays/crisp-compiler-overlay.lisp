;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;;; ============================================================================
;;;; 083-vector-matrix-helpers: num-rows, num-cols, get-layout, transpose, col, row
;;;; ============================================================================

;; src/analysis/structs.lisp
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

;; src/analysis/structs.lisp
(defun analyze-transpose-expression (expr env context location)
  "Analyzes (transpose M) for 2D tensors.
   Returns semantic-stride-view with op=:transpose and result type (tensor elem 2 addr access :strided)."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "transpose expects exactly 1 argument: (transpose matrix)"
           :source-location location))
  (let* ((src-node (analyze-expression (second expr) env context location))
         (raw-type (semantic-node-type src-node))
         (canon    (%083-require-2d-tensor raw-type location))
         (elem     (second canon))
         (addr     (fourth canon))
         (access   (fifth canon)))
    (make-semantic-stride-view
     :op :transpose
     :source-node src-node
     :index-node nil
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 2 addr access :strided)
     :source-location location)))

;; src/analysis/structs.lisp
(defun analyze-col-expression (expr env context location)
  "Analyzes (col index M) for 2D tensors.
   Returns semantic-stride-view with op=:col and result type (tensor elem 1 addr access :strided)."
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
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr access :strided)
     :source-location location)))

;; src/analysis/structs.lisp
(defun analyze-row-expression (expr env context location)
  "Analyzes (row index M) for 2D tensors.
   Returns semantic-stride-view with op=:row and result type (tensor elem 1 addr access :strided)."
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
     :type (list (find-symbol "TENSOR" :crisp.compiler) elem 1 addr access :strided)
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

;; src/codegen.lisp
(defun %sv-to-i64 (builder val)
  "Sign-extends VAL to i64 if smaller than 64 bits; returns as-is if already i64.
   Avoids the invalid sext-to-same-width LLVM instruction."
  (let* ((tp   (llvm-type-of val))
         (kind (llvm-get-type-kind tp)))
    (if (= kind 8)  ; integer kind
        (let ((w (crisp.llvm-bindings::llvm-get-int-type-width tp)))
          (cond ((= w 64) val)
                ((< w 64) (llvm-build-sext builder val (llvm-int64-type) "sv_idx64"))
                (t        (llvm-build-trunc builder val (llvm-int64-type) "sv_trunc"))))
        val)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-stride-view)
                              builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for transpose, col, and row stride-view operations on 2D tensors.
   Produces a new tensor struct value with recomputed offsets, strides, extents, and length.
   :transpose — swaps dim0/dim1 in offsets, strides, and extents; length unchanged.
   :col c     — extracts column c as 1D vector (stride=row-stride, len=height).
   :row r     — extracts row r as 1D vector (stride=col-stride, len=width)."
  (let* ((op          (semantic-stride-view-op node))
         (src-node    (semantic-stride-view-source-node node))
         (idx-node    (semantic-stride-view-index-node node))
         (result-type (semantic-stride-view-type node))

         ;; Generate source tensor value (a fully-loaded struct)
         (src-val  (generate-node-ir src-node builder module var-env
                                     di-builder di-scope location-map))

         ;; Extract source tensor struct fields (physical indices 0–4)
         (src-parent  (llvm-build-extract-value builder src-val 0 "sv_parent"))
         (src-offsets (llvm-build-extract-value builder src-val 1 "sv_offsets"))
         (src-strides (llvm-build-extract-value builder src-val 2 "sv_strides"))
         (src-extents (llvm-build-extract-value builder src-val 3 "sv_extents"))

         ;; Extract individual i64 elements from the 2D [2 x i64] arrays
         (src-off0 (llvm-build-extract-value builder src-offsets 0 "sv_off0"))
         (src-off1 (llvm-build-extract-value builder src-offsets 1 "sv_off1"))
         (src-str0 (llvm-build-extract-value builder src-strides  0 "sv_str0"))
         (src-str1 (llvm-build-extract-value builder src-strides  1 "sv_str1"))
         (src-ext0 (llvm-build-extract-value builder src-extents  0 "sv_ext0"))
         (src-ext1 (llvm-build-extract-value builder src-extents  1 "sv_ext1"))

         ;; Resolve and instantiate the result tensor struct type (on-demand if needed)
         (mangled       (mangle-template-struct-name (first result-type) (rest result-type)))
         (result-llvm-t (crisp-type-to-llvm-type result-type module))
         (result-undef  (llvm-get-undef result-llvm-t))
         (i64           (llvm-int64-type)))

    (log:info "stride-view: op=~a result-type=~a mangled=~a" op result-type mangled)

    (ecase op

      (:transpose
       ;; Transpose swaps dim0↔dim1 in offsets, strides, and extents.
       ;; Length (total elements) is unchanged.
       (let* ((arr2-undef (llvm-get-undef (llvm-array-type i64 2)))
              (src-len    (llvm-build-extract-value builder src-val 4 "sv_t_len"))
              ;; new offsets = [off1, off0]
              (new-off (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-off1 0 "sv_t_no0")
                         src-off0 1 "sv_t_no1"))
              ;; new strides = [str1, str0]
              (new-str (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-str1 0 "sv_t_ns0")
                         src-str0 1 "sv_t_ns1"))
              ;; new extents = [ext1, ext0]
              (new-ext (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-ext1 0 "sv_t_ne0")
                         src-ext0 1 "sv_t_ne1")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent 0 "sv_t_r0"))
                (r1 (llvm-build-insert-value builder r0 new-off  1 "sv_t_r1"))
                (r2 (llvm-build-insert-value builder r1 new-str  2 "sv_t_r2"))
                (r3 (llvm-build-insert-value builder r2 new-ext  3 "sv_t_r3"))
                (r4 (llvm-build-insert-value builder r3 src-len  4 "sv_t_r4")))
           r4)))

      (:col
       ;; Column c slice from 2D matrix M.
       ;; result.offset[0] = M.off0 + M.off1 + c * M.str1  (start of column c)
       ;; result.strides[0] = M.str0  (step between rows in the column)
       ;; result.extents[0] = M.ext0  (height = number of rows)
       ;; result.length     = M.ext0
       (let* ((idx-raw      (generate-node-ir idx-node builder module var-env
                                              di-builder di-scope location-map))
              (idx-i64      (%sv-to-i64 builder idx-raw))
              ;; new offset[0] = off0 + off1 + c * str1
              (c-x-str1  (llvm-build-mul builder idx-i64 src-str1 "sv_c_cxs1"))
              (off1-plus (llvm-build-add builder src-off1 c-x-str1 "sv_c_o1p"))
              (new-off0  (llvm-build-add builder src-off0 off1-plus "sv_c_off0"))
              ;; Build [1 x i64] arrays
              (arr1-undef  (llvm-get-undef (llvm-array-type i64 1)))
              (res-offsets (llvm-build-insert-value builder arr1-undef new-off0  0 "sv_c_roff"))
              (res-strides (llvm-build-insert-value builder arr1-undef src-str0  0 "sv_c_rstr"))
              (res-extents (llvm-build-insert-value builder arr1-undef src-ext0  0 "sv_c_rext")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent   0 "sv_c_r0"))
                (r1 (llvm-build-insert-value builder r0 res-offsets 1 "sv_c_r1"))
                (r2 (llvm-build-insert-value builder r1 res-strides 2 "sv_c_r2"))
                (r3 (llvm-build-insert-value builder r2 res-extents 3 "sv_c_r3"))
                (r4 (llvm-build-insert-value builder r3 src-ext0    4 "sv_c_r4")))
           r4)))

      (:row
       ;; Row r slice from 2D matrix M.
       ;; result.offset[0] = M.off0 + M.off1 + r * M.str0  (start of row r)
       ;; result.strides[0] = M.str1  (step between columns in the row)
       ;; result.extents[0] = M.ext1  (width = number of columns)
       ;; result.length     = M.ext1
       (let* ((idx-raw      (generate-node-ir idx-node builder module var-env
                                              di-builder di-scope location-map))
              (idx-i64      (%sv-to-i64 builder idx-raw))
              ;; new offset[0] = off0 + off1 + r * str0
              (r-x-str0  (llvm-build-mul builder idx-i64 src-str0 "sv_r_rxs0"))
              (off1-plus (llvm-build-add builder src-off1 r-x-str0 "sv_r_o1p"))
              (new-off0  (llvm-build-add builder src-off0 off1-plus "sv_r_off0"))
              ;; Build [1 x i64] arrays
              (arr1-undef  (llvm-get-undef (llvm-array-type i64 1)))
              (res-offsets (llvm-build-insert-value builder arr1-undef new-off0  0 "sv_r_roff"))
              (res-strides (llvm-build-insert-value builder arr1-undef src-str1  0 "sv_r_rstr"))
              (res-extents (llvm-build-insert-value builder arr1-undef src-ext1  0 "sv_r_rext")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent   0 "sv_r_r0"))
                (r1 (llvm-build-insert-value builder r0 res-offsets 1 "sv_r_r1"))
                (r2 (llvm-build-insert-value builder r1 res-strides 2 "sv_r_r2"))
                (r3 (llvm-build-insert-value builder r2 res-extents 3 "sv_r_r3"))
                (r4 (llvm-build-insert-value builder r3 src-ext1    4 "sv_r_r4")))
           r4))))))

;; src/analysis/core.lisp
(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
Extended for 083-vector-matrix-helpers to handle semantic-stride-view."
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
    (semantic-make-view (semantic-make-view-type node))
    ;; 082 atomic RMW
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))
    ;; 083 stride-view (transpose, col, row)
    (semantic-stride-view (semantic-stride-view-type node))))

;; src/analysis/core.lisp
(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
Extended for 083-vector-matrix-helpers to handle semantic-stride-view."
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
    (semantic-make-view (semantic-make-view-source-location node))
    ;; 082 atomic RMW
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))
    ;; 083 stride-view
    (semantic-stride-view (semantic-stride-view-source-location node))))

;; src/analysis/core.lisp
(defun initialize-expression-analyzers ()
  "Registers all expression analyzers, extended for 083-vector-matrix-helpers."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  ;; ##(...) device vector literal
  (setf (gethash 'crisp-vec-literal *expression-analyzers*)
        #'analyze-crisp-dvec-literal)
  ;; Component accessors x~ / y~ / z~ / w~
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (name '("X~" "Y~" "Z~" "W~"))
      (let ((sym-cl (intern name cl-pkg))
            (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) #'analyze-dvec-component-ref)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) #'analyze-dvec-component-ref))))
    ;; 083 matrix helpers: transpose, col, row, transpose!
    (dolist (entry `(("TRANSPOSE"  . ,#'analyze-transpose-expression)
                     ("COL"        . ,#'analyze-col-expression)
                     ("ROW"        . ,#'analyze-row-expression)
                     ("TRANSPOSE!" . ,#'analyze-transpose-bang-expression)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg))
            (fn     (cdr entry)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))))

;; src/compiler.lisp
(defun register-builtins ()
  "Registers built-in types and templates.
   Extended for 083-vector-matrix-helpers to add num-rows, num-cols, get-layout."
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

  ;; 083: num-rows — return extents[0] (height dimension) of a 2D tensor.
  (register-template 'num-rows
    '(To (Addr address-space :global) (Acc access :read-write) (Aln align :compact))
    nil
    '(def-function num-rows (m)
       (declare (function ((tensor To 2 Addr Acc Aln) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 0)))
    '((tensor To 2 Addr Acc Aln) => ulong))

  ;; 083: num-cols — return extents[1] (width dimension) of a 2D tensor.
  (register-template 'num-cols
    '(To (Addr address-space :global) (Acc access :read-write) (Aln align :compact))
    nil
    '(def-function num-cols (m)
       (declare (function ((tensor To 2 Addr Acc Aln) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 1)))
    '((tensor To 2 Addr Acc Aln) => ulong))

  ;; 083: get-layout — classify 2D tensor layout at runtime.
  ;; Returns 0 (:row-major) if last stride==1, 1 (:col-major) if first stride==1, else 2 (:other-layout).
  (register-template 'get-layout
    '(To (Addr address-space :global) (Acc access :read-write) (Aln align :compact))
    nil
    '(def-function get-layout (m)
       (declare (function ((tensor To 2 Addr Acc Aln) => int)))
       (declare (crisp-system-generated))
       (if (= (~ (strides~ m) 1) 1ul)
           0
           (if (= (~ (strides~ m) 0) 1ul)
               1
               2)))
    '((tensor To 2 Addr Acc Aln) => int))

  (log:info "Built-in structs registered."))
