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


;;; ===================================================================
;;; Endeavour 162 — CUDA shared-memory sizing at the true element width.
;;;
;;; Three functions govern the shared blob and MUST move together, because
;;; %cuda-shared-layout computes the launch request AND the offsets from the same numbers:
;;;   %cuda-local-param-bytes            - the sizer (launch total + tile offsets)
;;;   %cuda-emit-local-scratch-tensor-arg - the shared-tensor emitter
;;;   %cuda-emit-cell-arg                 - local cells, which sit above the tensors
;;; Each is reproduced verbatim from src/hoist-cuda/main.lisp with ONE change: the inline
;;; "8 else 4" is replaced by %hoist-elem-type-bytes.
;;;
;;; STILL CARRYING THE NAIVE RULE, deliberately out of scope here because neither touches
;;; SHARED memory: %cuda-emit-global-scratch-tensor-arg (line 838) and %cuda-emit-tensor-arg
;;; (line 926).  They over-allocate GLOBAL memory for 16-bit types, which is waste rather than
;;; occupancy.  Recorded in the endeavour doc rather than fixed blind.
;;; ===================================================================

;; src/hoist-cuda/main.lisp  (NEW -- endeavour 162)
;; Defined HERE, in :crisp.hoist.cuda, rather than in the shared :crisp.hoist overlay: 
;; build/build-hoist-cuda.lisp loads ONLY overlays/hoist-cuda/, so anything appended to
;; overlays/hoist-common/crisp-hoist-common-overlay.lisp never reaches this binary at all.
;; When the Intel GLOBAL-scratch path is fixed too, this table should move somewhere shared
;; AND both build-hoist-*.lisp must be taught to load that overlay -- until then a second
;; copy would be the very duplication that caused this bug, so Intel's fix is deferred, not
;; forked.  src/hoist-l0/main.lisp's %elem-type-bytes is the model this follows.
(defun %hoist-elem-type-bytes (elem-str)
  "Bytes occupied by one element of the C++ type named ELEM-STR.

   The canonical width table for the CUDA hoist's sizer AND emitters, which must agree:
   %cuda-shared-layout computes the launch request and the per-tile offsets from the same
   numbers, and BUG 046 was exactly the divergence that results when they do not.
   Unknown types keep the historical 4, so a type this table has not met is sized as before."
  (cond
    ((or (string-equal elem-str "double")
         (string-equal elem-str "int64_t")
         (string-equal elem-str "uint64_t")) 8)
    ((or (string-equal elem-str "bfloat16")
         (string-equal elem-str "half")
         (string-equal elem-str "__half")
         (string-equal elem-str "__nv_bfloat16")
         (string-equal elem-str "uint16_t")
         (string-equal elem-str "int16_t")
         (string-equal elem-str "short")
         (string-equal elem-str "ushort")) 2)
    ((or (string-equal elem-str "char")
         (string-equal elem-str "uchar")
         (string-equal elem-str "uint8_t")
         (string-equal elem-str "int8_t")
         (string-equal elem-str "bool")) 1)
    (t 4)))

;; src/hoist-cuda/main.lisp
(defun %cuda-local-param-bytes (param param-type)
  "Bytes of dynamic shared memory one LOCAL param occupies, or NIL if it occupies none.
   Returns a second value, :tensor or :cell, naming which region it belongs to.

   The element-size rule mirrors the one the emitters use, deliberately: this function
   exists so the sizer and the emitters cannot disagree, which is only true if it computes
   what they compute.  Endeavour 162: both now call %hoist-elem-type-bytes, so a 16-bit
   element is sized at 2 bytes instead of 4."
  (let* ((is-tensor (tensor-type-p param-type))
         (elem-type (if is-tensor (second param-type) (cell-base-type param-type)))
         (elem-str  (crisp-type-to-cpp-type elem-type))
         (elem-bytes (%hoist-elem-type-bytes elem-str)))
    (if is-tensor
        (let* ((rank (let ((n3 (third param-type))) (if (integerp n3) n3 1)))
               (size-expr (getf param :size-expr))
               (count (cond ((integerp size-expr) (expt size-expr rank))
                            ((and (listp size-expr) (every (function integerp) size-expr))
                             (reduce (function *) size-expr))
                            ;; %cuda-scratch-dims hard-errors on anything else, so such a
                            ;; tensor never reaches an emitter and contributes nothing.
                            (t nil))))
          (when count (values (* count elem-bytes) :tensor)))
        (let ((count (if (%array-type-p (cell-base-type param-type))
                         (%array-size (cell-base-type param-type))
                         1)))
          (values (* count elem-bytes) :cell)))))

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-local-scratch-tensor-arg (stream param param-name param-type arg-index)
  "Endeavour 162: BYTESIZE and the running shared offset now use the element's TRUE width, so a
   16-bit scratch tile occupies half what it did.  Every other line is unchanged."
  (let* ((rank        (let ((n3 (third param-type))) (if (integerp n3) n3 1)))
         (size-expr   (getf param :size-expr))
         (elem-type   (second param-type))
         (elem-str    (crisp-type-to-cpp-type elem-type))
         (elem-bytes  (%hoist-elem-type-bytes elem-str))
         (param-name-cpp (substitute #\_ #\- param-name))
         (arg-names   '())
         (current-idx arg-index))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (%cuda-scratch-dims size-expr rank param-name))
      (let* ((length   (reduce #'* (%cuda-scratch-dims size-expr rank param-name)))
             (bytesize (* length elem-bytes))
             ;; Bug 034: this tile's slice of the shared blob starts at the running
             ;; offset; advance it past this tile for the next one.
             (offset   *cuda-shared-scratch-offset*))
        (setf *cuda-shared-scratch-offset* (+ *cuda-shared-scratch-offset* bytesize))
        (format stream "~%    // LOCAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes, shared offset ~d)~%"
                param-name rank elem-str length bytesize offset)
        ;; Arg: ptr (distinct shared-mem byte offset - bug 034)
        (format stream "    uint64_t ~a_ptr = ~dULL;  // shared mem offset~%" param-name-cpp offset)
        (push (format nil "~a_ptr" param-name-cpp) arg-names)
        (incf current-idx)
        ;; byte-size
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
        (push (format nil "~a_byte_size" param-name-cpp) arg-names)
        (incf current-idx)
        ;; offsets
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
          (push (format nil "~a_off~d" param-name-cpp k) arg-names)
          (incf current-idx))
        ;; strides
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
          (push (format nil "~a_str~d" param-name-cpp k) arg-names)
          (incf current-idx))
        ;; extents
        (loop for k from 0 below rank do
          (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
          (push (format nil "~a_ext~d" param-name-cpp k) arg-names)
          (incf current-idx))
        ;; length
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
        (push (format nil "~a_length" param-name-cpp) arg-names)
        (incf current-idx)
        (values current-idx (nreverse arg-names))))))

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-cell-arg (stream param param-name param-type param-dir is-local aliases arg-index)
  "BUG 046: a LOCAL cell now draws a DISTINCT shared-memory offset from
   *cuda-shared-cell-offset* instead of hard-coding 0 on top of the first scratch tile.
   The GLOBAL branch is untouched.

   Endeavour 162: the LOCAL branch's offset advance uses the element's TRUE width.  It had a
   live divergence -- BYTESIZE advanced the offset by count*4 while the very next line handed the
   kernel `count * sizeof(uint16_t)` = count*2.  Those agreed only for 4-byte types."
  (declare (ignore param aliases))
  (let* ((base-type      (cell-base-type param-type))
         (is-array-cell  (%array-type-p base-type))
         (base-type-str  (if is-array-cell
                             (crisp-type-to-cpp-type (%array-element-type base-type))
                             (crisp-type-to-cpp-type base-type)))
         (elem-count     (if is-array-cell (%array-size base-type) 1))
         (param-name-cpp (substitute #\_ #\- param-name))
         (size-var       (format nil "~a_size" param-name-cpp))
         (ptr-var        (format nil "~a_ptr"  param-name-cpp))
         (arg-names      '())
         (alloc          nil))
    (if is-local
        ;; LOCAL MEMORY — a distinct slice of the shared blob, above the scratch tensors
        (let* ((elem-bytes (%hoist-elem-type-bytes base-type-str))
               (bytesize (* elem-count elem-bytes))
               (offset   *cuda-shared-cell-offset*))
          (setf *cuda-shared-cell-offset* (+ *cuda-shared-cell-offset* bytesize))
          (format stream "~%    // LOCAL cell: ~a (~d bytes, shared offset ~d)~%"
                  param-name bytesize offset)
          (format stream "    uint64_t ~a_local_ptr = ~dULL;  // shared offset~%"
                  param-name-cpp offset)
          (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var elem-count base-type-str)
          (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
          (push (format nil "~a_local_ptr" param-name-cpp) arg-names)
          (push (format nil "~a_bytes" size-var) arg-names)
          (push (format nil "~a_offset" param-name-cpp) arg-names))

        ;; GLOBAL MEMORY — cuMemAlloc + cuMemcpyHtoD
        (progn
          (format stream "~%    // Cell: ~a (~a)~%" param-name base-type-str)
          (format stream "    size_t ~a = ~a;~%" size-var elem-count)
          (format stream "    CUdeviceptr ~a;~%" ptr-var)
          (format stream "    CUDA_CHECK(cuMemAlloc(&~a, ~a * sizeof(~a)));~%"
                  ptr-var size-var base-type-str)
          (format stream "    {~%")
          (format stream "        ~a* h = new ~a[~a];~%" base-type-str base-type-str size-var)
          (if is-array-cell
              (format stream "        for (size_t _i = 0; _i < ~a; _i++) h[_i] = (~a)_i;~%"
                      size-var base-type-str)
              (format stream "        memset(h, 0, ~a * sizeof(~a));~%" size-var base-type-str))
          (format stream "        CUDA_CHECK(cuMemcpyHtoD(~a, h, ~a * sizeof(~a)));~%"
                  ptr-var size-var base-type-str)
          (format stream "        delete[] h;~%")
          (format stream "    }~%")
          (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
          (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
          (push (format nil "~a" ptr-var) arg-names)
          (push (format nil "~a_bytes" size-var) arg-names)
          (push (format nil "~a_offset" param-name-cpp) arg-names)
          (setf alloc (list :name      param-name
                            :ptr       ptr-var
                            :size-var  (format nil "~a" size-var)
                            :elem-type base-type-str
                            :direction param-dir))))
    (values (+ arg-index 3) (nreverse arg-names) alloc)))
