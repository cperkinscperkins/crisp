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
