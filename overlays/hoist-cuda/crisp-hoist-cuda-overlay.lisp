;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; EMPTY BY DESIGN.  Its contents were folded into src/hoist-cuda/main.lisp on 2026-08-26.
;;;;
;;;; The two residents were late-binding WRAPPERS -- they captured (fdefinition 'emit-launch)
;;;; and (fdefinition 'emit-kernel-args) into a defvar and then redefined those names.  That
;;;; shape cannot be pasted into src/, where there is only one definition: the capture would
;;;; grab the function being replaced and the wrapper would recurse forever.  So each was
;;;; split into a base plus a wrapper that calls the base by name:
;;;;
;;;;     %emit-launch-base       + emit-launch
;;;;     %emit-kernel-args-base  + emit-kernel-args
;;;;
;;;; Callers were untouched -- both public names keep their signature and return value.
;;;;
;;;; If you add a patch here, remember the same constraint applies on the way back out.

(in-package :crisp.hoist.cuda)

;; src/hoist-cuda/main.lisp
;; Endeavour 159 — CUtensorMap data types for 16-bit operands.
;;
;; The map listed float and double only, so `--hoist=cuda` on any 16-bit TMA kernel died with
;;   Error: cuTensorMapEncodeTiled: unsupported element type BFLOAT16 (need float/double)
;; and produced no launcher.  CUDA has had CU_TENSOR_MAP_DATA_TYPE_FLOAT16 and _BFLOAT16 since
;; the tensor-map API shipped; nothing about TMA is 32-bit-only.  This was simply an omission,
;; and the same shape as the `load-tile :block` byte table that blocked chapters 4/5/6.
;;
;; NOTE the failure was PARTIALLY MASKED: the metacrisp sidecar is written before the .cu is
;; generated, so a caller that only wanted the metadata (run_cuda_fixed_sweep does) still got
;; what it needed and saw an error it could ignore.  The generated launcher, which is what a
;; TEST-HOIST[CUDA] spec would use, was never produced at all.
;; DECLAIM FIRST, and redefine the CALLER below.  SBCL derived the original function's return
;; type as (SIMPLE-ARRAY CHARACTER (31)) -- the exact length of "CU_TENSOR_MAP_DATA_TYPE_FLOAT64"
;; -- and compiled %cuda-emit-tensor-map-encode against it.  "..._BFLOAT16" is 32 characters, so
;; simply redefining this function produced a type error at the CALL SITE rather than a working
;; hoister.  A late-bound redefinition cannot relax a type the caller already baked in; the caller
;; has to be recompiled too.
(declaim (ftype (function (t) simple-string) %cuda-tensor-map-data-type))

(defun %cuda-tensor-map-data-type (elem-type)
  "Maps a Crisp element type to the CU_TENSOR_MAP_DATA_TYPE_* enum for cuTensorMapEncodeTiled.
   Endeavour 159: 16-bit operands included -- TMA is descriptor-driven and encodes f16/bf16
   directly."
  (let ((n (string-downcase (string elem-type))))
    (cond ((string= n "float")    "CU_TENSOR_MAP_DATA_TYPE_FLOAT32")
          ((string= n "double")   "CU_TENSOR_MAP_DATA_TYPE_FLOAT64")
          ((string= n "half")     "CU_TENSOR_MAP_DATA_TYPE_FLOAT16")
          ((string= n "bfloat16") "CU_TENSOR_MAP_DATA_TYPE_BFLOAT16")
          (t (error "cuTensorMapEncodeTiled: unsupported element type ~a (need float/double/half/bfloat16)"
                    elem-type)))))

;; src/hoist-cuda/main.lisp -- reappended VERBATIM so it recompiles against the widened ftype
;; above.  Nothing in its body changed.
(defun %cuda-emit-tensor-map-encode (stream param)
  "Endeavor 137 Phase 2b.3 + 140 Step 3: emit the host cuTensorMapEncodeTiled for a :kind :tensor-map
   descriptor and copy the 128-byte descriptor to device global (option A), leaving the device pointer
   in <name> (forward-declared earlier at the descriptor's ABI slot).  References the DESCRIBED tensor's
   already-emitted host variables (<d>_ptr, <d>_ext<k>, <d>_str<k>).
     - Swizzle from (getf param :swizzle): :128b -> CU_TENSOR_MAP_SWIZZLE_128B (wgmma), else NONE.
     - Layout: a 128B-swizzle col-major describes (wgmma's B) has K contiguous, so gdim = extents
       in-order and gstride = the outer (N) stride.  Otherwise the row-major reversal (extents reversed,
       gstride = dim-0 stride), matching the nvcc-verified H100 reference.  Gated on :128b so the
       battle-tested 137/138 :none col-major path (symmetric tiles) is untouched."
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
    ;; gstride: tensorRank-1 entries, in BYTES, of the non-innermost dims.  col-major -> dims
    ;; 1..rank-1 (outer=N=str1); row-major -> dims 0..rank-2 (outer=M=str0).
    (when (> rank 1)
      (format stream "    uint64_t ~a_gstr[~d] = { ~{~a~^, ~} };~%" name (1- rank)
              (if col-p
                  (loop for k from (1- rank) downto 1
                        collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str))
                  (loop for k from (- rank 2) downto 0
                        collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str)))))
    ;; boxDim: tile dims innermost-first (reversed) — correct for both layouts.
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

