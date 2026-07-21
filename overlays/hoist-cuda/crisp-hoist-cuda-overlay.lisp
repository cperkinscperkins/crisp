;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for CUDA hoist improvements.
;;;; Applied via late binding - last definition wins.

(in-package :crisp.hoist.cuda)


;;; src/hoist-cuda/main.lisp — Endeavor 140 Step 3: honor the descriptor's :swizzle field so a wgmma
;;; tile's CuTensorMap gets CU_TENSOR_MAP_SWIZZLE_128B (was hardcoded SWIZZLE_NONE).  The box innermost
;;; must be 32 tf32 (128 bytes) for 128B swizzle — already true for a 64x32 K-block load-tile.
(defun %cuda-emit-tensor-map-encode (stream param)
  "Endeavor 137 + 140: emit cuTensorMapEncodeTiled; swizzle from (getf param :swizzle) (:128b|:none)."
  (let* ((name      (substitute #\_ #\- (getf param :name)))
         (describes (substitute #\_ #\- (getf param :describes)))
         (rank      (getf param :rank))
         (box       (getf param :box-dims))
         (elem      (getf param :element-type))
         (elem-str  (crisp-type-to-cpp-type elem))
         (dtype     (%cuda-tensor-map-data-type elem))
         (swz       (if (eq (getf param :swizzle) :128b)
                        "CU_TENSOR_MAP_SWIZZLE_128B" "CU_TENSOR_MAP_SWIZZLE_NONE")))
    (format stream "~%    // CUtensorMap descriptor for '~a' (box ~a, swizzle ~a) — Endeavor 137/140~%"
            describes box swz)
    (format stream "    CUtensorMap ~a_host;~%" name)
    (format stream "    uint64_t ~a_gdim[~d] = { ~{~a~^, ~} };~%" name rank
            (loop for k from (1- rank) downto 0 collect (format nil "~a_ext~d" describes k)))
    (when (> rank 1)
      (format stream "    uint64_t ~a_gstr[~d] = { ~{~a~^, ~} };~%" name (1- rank)
              (loop for k from (- rank 2) downto 0
                    collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str))))
    (format stream "    uint32_t ~a_box[~d] = { ~{~a~^, ~} };~%" name rank
            (loop for k from (1- rank) downto 0 collect (nth k box)))
    (format stream "    uint32_t ~a_elstr[~d] = { ~{~a~^, ~} };~%" name rank
            (make-list rank :initial-element 1))
    (format stream "    CUDA_CHECK(cuTensorMapEncodeTiled(&~a_host, ~a, ~d,~%" name dtype rank)
    (format stream "        (void*)~a_ptr, ~a_gdim, ~a, ~a_box, ~a_elstr,~%"
            describes name (if (> rank 1) (format nil "~a_gstr" name) "nullptr") name name)
    (format stream "        CU_TENSOR_MAP_INTERLEAVE_NONE, ~a,~%" swz)
    (format stream "        CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));~%")
    (format stream "    CUDA_CHECK(cuMemAlloc(&~a, sizeof(CUtensorMap)));~%" name)
    (format stream "    CUDA_CHECK(cuMemcpyHtoD(~a, &~a_host, sizeof(CUtensorMap)));~%" name name)))

;;; Endeavor 140 Step 3 fix — col-major descriptors on the SWIZZLE (wgmma) path need K (the contiguous
;;; dim) as the CuTensorMap innermost, so gdim is NOT reversed and gstride uses the N (outer) stride.
;;; The default reversal assumes row-major (innermost = last dim); it is right for A (row-major) but for
;;; col-major B it put N innermost, so box[0] read only 32 of 64 N (right half of C came back zero).
;;; GATED on :128b so the battle-tested 137/138 :none col-major path (symmetric tiles) is untouched.
(defun %cuda-emit-tensor-map-encode (stream param)
  "Emit the host cuTensorMapEncodeTiled for a :kind :tensor-map implicit.  For a 128B-swizzle col-major
   describes, K is contiguous so gdim = extents in-order and gstride = the outer (N) stride; otherwise
   the row-major reversal (extents reversed, gstride = dim-0 stride) as before."
  (let* ((name      (substitute #\_ #\- (getf param :name)))
         (describes (substitute #\_ #\- (getf param :describes)))
         (rank      (getf param :rank))
         (box       (getf param :box-dims))
         (elem      (getf param :element-type))
         (elem-str  (crisp-type-to-cpp-type elem))
         (dtype     (%cuda-tensor-map-data-type elem))
         (swz-p     (eq (getf param :swizzle) :128b))
         (col-p     (and swz-p (eq (getf param :layout) :col-major)))
         (swz       (if swz-p "CU_TENSOR_MAP_SWIZZLE_128B" "CU_TENSOR_MAP_SWIZZLE_NONE")))
    (format stream "~%    // CUtensorMap descriptor for '~a' (box ~a, swizzle ~a, ~a) — Endeavor 137/140~%"
            describes box swz (if col-p "col-major K-contiguous" "row-major"))
    (format stream "    CUtensorMap ~a_host;~%" name)
    ;; gdim: col-major swizzle -> in-order (K innermost); else reversed (row-major, last dim innermost).
    (format stream "    uint64_t ~a_gdim[~d] = { ~{~a~^, ~} };~%" name rank
            (if col-p
                (loop for k from 0 below rank collect (format nil "~a_ext~d" describes k))
                (loop for k from (1- rank) downto 0 collect (format nil "~a_ext~d" describes k))))
    (when (> rank 1)
      ;; gstride: byte stride of the non-innermost dims.  col-major -> dims 1..rank-1 (outer=N=str1);
      ;; row-major -> dims 0..rank-2 (outer=M=str0).
      (format stream "    uint64_t ~a_gstr[~d] = { ~{~a~^, ~} };~%" name (1- rank)
              (if col-p
                  (loop for k from (1- rank) downto 1
                        collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str))
                  (loop for k from (- rank 2) downto 0
                        collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str)))))
    ;; box: tile dims innermost-first (reversed) — correct for both layouts (see overlay note).
    (format stream "    uint32_t ~a_box[~d] = { ~{~a~^, ~} };~%" name rank
            (loop for k from (1- rank) downto 0 collect (nth k box)))
    (format stream "    uint32_t ~a_elstr[~d] = { ~{~a~^, ~} };~%" name rank
            (make-list rank :initial-element 1))
    (format stream "    CUDA_CHECK(cuTensorMapEncodeTiled(&~a_host, ~a, ~d,~%" name dtype rank)
    (format stream "        (void*)~a_ptr, ~a_gdim, ~a, ~a_box, ~a_elstr,~%"
            describes name (if (> rank 1) (format nil "~a_gstr" name) "nullptr") name name)
    (format stream "        CU_TENSOR_MAP_INTERLEAVE_NONE, ~a,~%" swz)
    (format stream "        CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));~%")
    (format stream "    CUDA_CHECK(cuMemAlloc(&~a, sizeof(CUtensorMap)));~%" name)
    (format stream "    CUDA_CHECK(cuMemcpyHtoD(~a, &~a_host, sizeof(CUtensorMap)));~%" name name)))

;;; ===========================================================================
;;; Endeavor 140 Step 4 — two mma-bench/launch harness fixes (wrapper-capture overlays; the clean
;;; src fold is documented in put_temp_files_here/PATCH-wgmma-harness-col-major-B.md).  Both delegate
;;; to the captured original, so no big-function reproduction.
;;; ===========================================================================

(defvar *mma-swizzle-describes* nil
  "Tensor names (strings) feeding a :128b + :col-major swizzle descriptor (wgmma's B).  Such a matrix
   must be K-CONTIGUOUS in global memory (the wgmma descriptor reads SMEM directly), so the mma-test/
   bench harness emits col-major (dim-0 contiguous) strides for it.  GATED on swizzle-fed + col-major
   so 137/138's nominal :col-major (mma.sync, row-major SMEM) path is untouched.")
(defvar *param-col-major-p* nil
  "Bound non-NIL while %cuda-emit-tensor-arg emits a swizzle-fed col-major tensor's strides.")

;; Capture the src originals once per image (idempotent across reloads).
(unless (fboundp 'orig-emit-kernel-args)
  (setf (fdefinition 'orig-emit-kernel-args) (fdefinition 'emit-kernel-args)))
(unless (fboundp 'orig-cuda-emit-tensor-arg)
  (setf (fdefinition 'orig-cuda-emit-tensor-arg) (fdefinition '%cuda-emit-tensor-arg)))
(unless (fboundp 'orig-tensor-compact-extents-strides)
  (setf (fdefinition 'orig-tensor-compact-extents-strides) (fdefinition '%tensor-compact-extents-strides)))
(unless (fboundp 'orig-emit-launch)
  (setf (fdefinition 'orig-emit-launch) (fdefinition 'emit-launch)))

(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "Endeavor 140 (col-major B): pre-scan the sig for swizzle-fed col-major tensors -> *mma-swizzle-
   describes*, then delegate to the original arg emitter."
  (setf *mma-swizzle-describes*
        (loop for p in declared-sig
              when (and (eq (getf p :kind) :tensor-map)
                        (eq (getf p :swizzle) :128b)
                        (eq (getf p :layout) :col-major)
                        (getf p :describes))
                collect (string (getf p :describes))))
  (funcall 'orig-emit-kernel-args stream declared-sig aliases records dispatch-info))

;; Full reproduction of %cuda-emit-tensor-arg (src line 744) with ONE change: for a swizzle-fed
;; col-major tensor (wgmma B) the emitted strides are swapped to col-major (K-contiguous {1, ext0})
;; AFTER total-elems is sized from the row-major strides — so the buffer stays full-size while the
;; addressing becomes K-contiguous.  (The earlier %tensor-compact-extents-strides override was wrong:
;; it swapped BEFORE sizing, so total-elems = 1*ext0 undersized B's buffer -> MMA_WRONG.)
(defun %cuda-emit-tensor-arg (stream param param-name param-type param-dir arg-index dispatch-info)
  (let* ((rank        (or (getf param :rank)
                          (let ((n3 (third param-type))) (if (integerp n3) n3 1))))
         (elem-type   (second param-type))
         (elem-str    (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var     (format nil "~a_ptr" param-name-cpp))
         (arg-names   '())
         (current-idx arg-index)
         (alloc       nil)
         (mma-role (when (and *mma-test-dims* (= rank 2))
                     (if (%mma-out-dir-p param-dir)
                         :c
                         (prog1 (if (zerop *mma-input-counter*) :a :b)
                           (incf *mma-input-counter*)))))
         (extents-list
           (if mma-role
               (destructuring-bind (m n k) *mma-test-dims*
                 (ecase mma-role (:a (list m k)) (:b (list k n)) (:c (list m n))))
               (let ((lst (make-list rank :initial-element 4)))
                 (let* ((global-decl (getf dispatch-info :global-size))
                        (strategy (getf (cdr global-decl) :strategy))
                        (derive-from (getf (cdr global-decl) :derive-from))
                        (tile-shape (getf (cdr global-decl) :tile-shape)))
                   (declare (ignore strategy))
                   (when (and tile-shape
                              derive-from
                              (member param-name (if (listp derive-from) derive-from (list derive-from))
                                      :test (lambda (a b) (string-equal (string a) (string b)))))
                     (loop for k from 0 below (min rank (length tile-shape)) do
                       (let* ((tx (nth k tile-shape))
                              (base (nth k lst))
                              (padded (* (ceiling base tx) tx)))
                         (setf (nth k lst) padded)))))
                 lst))))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank extents-list)
      (let* ((total-elems (* (first strides) (first extents)))   ; row-major sizing FIRST
             (elem-bytes  (if (or (string-equal elem-str "double")
                                  (string-equal elem-str "int64_t")
                                  (string-equal elem-str "uint64_t")) 8 4))
             (byte-size   (* total-elems elem-bytes)))
        ;; Endeavor 140: swap to col-major (K-contiguous) AFTER sizing, for wgmma's B.
        (when (and (= rank 2)
                   (member param-name *mma-swizzle-describes* :test #'string-equal))
          (setf strides (list 1 (first extents))))
        (format stream "~%    // Tensor: ~a (rank=~d, ~a, ~d elements)~%"
                param-name rank elem-str total-elems)
        (format stream "    CUdeviceptr ~a;~%" ptr-var)
        (format stream "    CUDA_CHECK(cuMemAlloc(&~a, ~d * sizeof(~a)));~%"
                ptr-var total-elems elem-str)
        (format stream "    {~%")
        (format stream "        ~a* h = new ~a[~d];~%" elem-str elem-str total-elems)
        (cond
          ((member mma-role '(:a :b))
           (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)(_i % ~d);~%"
                   total-elems elem-str (if (eq mma-role :a) 5 3)))
          ((eq mma-role :c)
           (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)0;~%"
                   total-elems elem-str))
          (t
           (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)_i;~%"
                   total-elems elem-str)))
        (format stream "        CUDA_CHECK(cuMemcpyHtoD(~a, h, ~d * sizeof(~a)));~%"
                ptr-var total-elems elem-str)
        (format stream "        delete[] h;~%")
        (format stream "    }~%")
        (push (format nil "~a" ptr-var) arg-names)
        (incf current-idx)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
        (push (format nil "~a_byte_size" param-name-cpp) arg-names)
        (incf current-idx)
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
          (push (format nil "~a_off~d" param-name-cpp k) arg-names)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
          (push (format nil "~a_str~d" param-name-cpp k) arg-names)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
          (push (format nil "~a_ext~d" param-name-cpp k) arg-names)
          (incf current-idx))
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp total-elems)
        (push (format nil "~a_length" param-name-cpp) arg-names)
        (incf current-idx)
        (setf alloc (list :name      param-name
                          :ptr       ptr-var
                          :count     total-elems
                          :elem-type elem-str
                          :direction param-dir
                          :mma-role  mma-role
                          :base      param-name-cpp))
        (values current-idx (nreverse arg-names) alloc)))))

(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 140 (dynamic-SMEM opt-in): a kernel needing >48KB SMEM (n128-pipe, n256, ...) must
   cuFuncSetAttribute MAX_DYNAMIC_SHARED_SIZE_BYTES or the launch silently fails.  Emit it, then
   delegate to the original launch emitter."
  ;; sm_90 reserves ~1KB of the 48KB default, so even exactly-48KB (49152) dynamic SMEM needs the
  ;; opt-in.  n64-pipe (32768) launches fine without it, so 32768 is the safe cutoff.
  (when (and shared-bytes (> shared-bytes 32768))
    (format stream "    CUDA_CHECK(cuFuncSetAttribute(kernel, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, ~d));~%"
            shared-bytes))
  (funcall 'orig-emit-launch stream dispatch-info shared-bytes compute-units kernel-name out-tile))
