;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; NOTE THE SHAPE CONSTRAINT, learned when this file was last emptied (2026-08-26): a
;;;; late-binding wrapper that captures (fdefinition 'f) into a defvar and then redefines f
;;;; CANNOT be pasted into src/ as-is, because there the capture would grab the function being
;;;; replaced and recurse forever.  Folding one back means splitting it into a base plus a
;;;; wrapper that calls the base BY NAME, as emit-launch / %emit-launch-base already are.
;;;;
;;;; EMPTY AGAIN as of 2026-09-22.  Endeavour 175 (symbolic scratch sizes, CUDA side) folded
;;;; into src/hoist-cuda/main.lisp:
;;;;   emit-main               -- split per the constraint above into %emit-main-base plus a
;;;;                             wrapper that binds *cuda-wg-size* and calls the base by name
;;;;   %cuda-scratch-dims     -- symbolic branch is now its first cond clause
;;;;   %cuda-local-param-bytes-- symbolic clause added to its inner count cond, so the sizer
;;;;                             and the emitters still resolve the size the same way

;;;;
;;;; EMPTY AGAIN as of 2026-10-08.  Endeavour 181 (:match-num-workgroups scratch) folded into
;;;; src/hoist-cuda/main.lisp: *cuda-deferred-scratch*, %cuda-num-workgroups-size-p,
;;;; %cuda-emit-num-workgroups-scratch-arg (the wrapper's branch, now a named function that
;;;; %cuda-emit-global-scratch-tensor-arg returns early into), and emit-launch (injects the
;;;; deferred blocks at the _crisp_launch anchor, after the cluster fix-up).
;;;; EMPTY as of 2026-10-25 -- endeavour 193 folded: %193-cuda-emit-die-report / -log-report, the site tables
;;;; bound in generate-cuda-launcher and reported at the top of emit-readback (src/hoist-cuda/main.lisp);
;;;; the shared helpers into src/hoist/common.lisp.
;;;; EMPTY as of 2026-10-30 -- endeavour 201 (:match-global-size scratch) folded into src/hoist-cuda/main.lisp:
;;;; %cuda-global-size-size-p (new), %cuda-num-workgroups-size-p (accepts it), %cuda-emit-num-workgroups-
;;;; scratch-arg (a SIZE-EXPR parameter; grid x *cuda-wg-size*), its caller passes it; the wrapper and
;;;; *201-scratch-size-expr* dropped.  %cuda-resolve-symbolic-size refuses it for LOCAL scratch.
;;;; EMPTY as of 2026-11-02 -- endeavours 204 / 205 (integer MMA reference, quantized buffers) and BUG 135
;;;; (a refused launch is fatal) folded into src/hoist-cuda/main.lisp.
;;;; EMPTY as of 2026-11-06 -- endeavour 208 (16-bit --mma-test fills, block-scaled operands and reference,
;;;; D-208-18 uchar width) folded into src/hoist-cuda/main.lisp: %hoist-elem-type-bytes replaced; the
;;;; captured copies of %cuda-emit-tensor-arg / %cuda-emit-mma-reference became the -base functions;
;;;; emit-kernel-args, %cuda-emit-tensor-map-encode, emit-structs split base + wrapper; the rest new.
(in-package :crisp.hoist.cuda)


;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 210, item 6 (2026-11-08): the CUtensorMap is passed BY VALUE (__grid_constant__,
;;;; option B).  Both copies were extracted from src by put_temp_files_here/210/gc/hoist_extract.py;
;;;; the only changes are the descriptor declaration, the encode target, and dropping the device copy.
;;;; ---------------------------------------------------------------------------------------------

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-tensor-map-encode-base (stream param)
  "Endeavor 137 Phase 2b.3 + 140 Step 3: emit the host cuTensorMapEncodeTiled for a :kind :tensor-map
   descriptor STRAIGHT INTO <name>, the CUtensorMap forward-declared at the descriptor's ABI slot.
   Endeavour 210 (option B): the kernel takes it BY VALUE as a __grid_constant__ parameter, so
   kernelParams[i] = &<name> and there is no device copy (option A's cuMemAlloc + cuMemcpyHtoD).  References the DESCRIBED tensor's
   already-emitted host variables (<d>_ptr, <d>_ext<k>, <d>_str<k>).
     - Swizzle from (getf param :swizzle): :128b -> CU_TENSOR_MAP_SWIZZLE_128B (wgmma), else NONE.
     - Layout: a 128B-swizzle col-major describes (wgmma's B) has K contiguous, so gdim = extents
       in-order and gstride = the outer (N) stride.  Otherwise the row-major reversal (extents reversed,
       gstride = dim-0 stride), matching the nvcc-verified H100 reference.  Gated on :128b so the
       battle-tested 137/138 :none col-major path (symmetric tiles) is untouched.

   Endeavour 208: %cuda-emit-tensor-map-encode (below) wraps this; a block operand's map uses its byte extents."
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
    (format stream "    CUDA_CHECK(cuTensorMapEncodeTiled(&~a, ~a, ~d,~%" name dtype rank)
    (format stream "        (void*)~a_ptr, ~a_gdim, ~a, ~a_box, ~a_elstr,~%"
            describes name (if (> rank 1) (format nil "~a_gstr" name) "nullptr") name name)
    (format stream "        CU_TENSOR_MAP_INTERLEAVE_NONE, ~a,~%" swz)
    (format stream "        CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));~%")))

;; src/hoist-cuda/main.lisp
(defun %emit-kernel-args-base (stream declared-sig aliases records dispatch-info)
  "Emit host-side variable declarations and fill the kernelParams[] array.
   Returns a list of allocation plists for readback.
   Bug 034: resets *cuda-shared-scratch-offset* so each kernel's LOCAL tiles get
   distinct, non-overlapping shared-memory offsets.
   Endeavor 140 (col-major B): pre-scans the sig for swizzle-fed col-major tensors into
   *mma-swizzle-describes* so %cuda-emit-tensor-arg emits K-contiguous strides for wgmma's B."
  ;; Endeavor 140: which tensors feed a :128b + :col-major swizzle descriptor (wgmma's B)?
  ;; Those must be K-contiguous in global memory (the wgmma descriptor reads SMEM directly).
  (setf *mma-swizzle-describes*
        (loop for p in declared-sig
              when (and (eq (getf p :kind) :tensor-map)
                        (eq (getf p :swizzle) :128b)
                        (eq (getf p :layout) :col-major)
                        (getf p :describes))
                collect (string (getf p :describes))))
  (format stream "    // Set up kernel arguments~%")
  (setf *cuda-shared-scratch-offset* 0)
  (let ((arg-index 0)
        (allocations '())
        (arg-names '())
        (deferred-tensor-maps '()))

    (dolist (param declared-sig)
      (let* ((param-name  (getf param :name))
             (raw-type    (getf param :type))
             (param-type  (resolve-type-alias raw-type aliases))
             (param-dir   (getf param :direction))
             (param-as    (getf param :address-space))
             (is-local    (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond
         ;; Endeavor 137: CUtensorMap descriptor -- Endeavour 210: option B, the descriptor ITSELF
         ;; (by value, __grid_constant__), not a device pointer.  Forward-declare it and
         ;; reserve its ABI slot now (it sorts first); the encode is emitted AFTER the loop, once
         ;; the DESCRIBED tensor's host vars (<d>_ptr / <d>_ext / <d>_str) have been emitted.
         ((eq (getf param :kind) :tensor-map)
          (let ((nm (substitute #\_ #\- (getf param :name))))
            (format stream "    CUtensorMap ~a;  // CUtensorMap descriptor, passed BY VALUE (__grid_constant__), encoded below~%" nm)
            (push nm arg-names)
            (incf arg-index)
            (push param deferred-tensor-maps)))

         ((cell-type-p param-type)
          (multiple-value-bind (new-idx names alloc)
              (%cuda-emit-cell-arg stream param param-name param-type param-dir is-local aliases arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))
            (when alloc (push alloc allocations))))

         ((and (tensor-type-p param-type) is-local)
          (multiple-value-bind (new-idx names)
              (%cuda-emit-local-scratch-tensor-arg stream param param-name param-type arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))))

         ((and (tensor-type-p param-type) (not is-local) (getf param :size-expr))
          (multiple-value-bind (new-idx names)
              (%cuda-emit-global-scratch-tensor-arg stream param param-name param-type arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))))

         ((tensor-type-p param-type)
          (multiple-value-bind (new-idx names alloc)
              (%cuda-emit-tensor-arg stream param param-name param-type param-dir arg-index dispatch-info)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))
            (when alloc (push alloc allocations))))

         ((struct-type-p param-type)
          (multiple-value-bind (new-idx names)
              (%cuda-emit-struct-arg stream param-name param-type aliases arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))))

         ((record-type-p param-type records)
          (multiple-value-bind (new-idx names)
              (%cuda-emit-record-arg stream param-name param-type records aliases arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names))))

         ((symbolp param-type)
          (multiple-value-bind (new-idx names)
              (%cuda-emit-scalar-arg stream param-name param-type arg-index)
            (setf arg-index new-idx)
            (setf arg-names (append (reverse names) arg-names)))))))

    ;; Endeavor 137: now that every described tensor is allocated, emit the CUtensorMap encodes
    ;; (assigning into the device pointers forward-declared at their ABI slots above).
    (dolist (tm-param (nreverse deferred-tensor-maps))
      (%cuda-emit-tensor-map-encode stream tm-param))

    ;; Build kernelParams[] array
    (let ((ordered-names (nreverse arg-names)))
      (format stream "~%    // Build kernelParams array (~d args)~%" (length ordered-names))
      (format stream "    void* kernelParams[~d] = {~%" (length ordered-names))
      (loop for name in ordered-names
            for i from 0
            do (format stream "        &~a~a~%" name
                       (if (< i (1- (length ordered-names))) "," "")))
      (format stream "    };~%~%"))

    (nreverse allocations)))

;; SPLIT rather than edited in place: emit-kernel-args is ~120 lines with one job to add --
;; seed the cell offset for this kernel.  Threading that into the middle of the base would
;; bury it; a two-line wrapper says exactly what is added and when.  Same shape as the
;; emit-launch wrapper above.  %emit-kernel-args-base still resets
;; *cuda-shared-scratch-offset* itself.
