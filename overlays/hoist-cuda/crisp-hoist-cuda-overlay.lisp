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
(in-package :crisp.hoist.cuda)

;; src/hoist-cuda/main.lisp
(defun %cuda-print-prefix (elem-type)
  "Unary + for an 8-bit element, so C++ prints a number rather than a raw byte.  Empty otherwise."
  (if (member (string elem-type) (quote ("char" "unsigned char" "uchar" "CHAR" "UCHAR")) :test (function string-equal))
      "+"
      ""))

;; src/hoist-cuda/main.lisp -- 8-bit buffers print as numbers
(defun emit-readback (stream allocations)
  "Emit cuMemcpyDtoH and print buffer contents.  Endeavor 134: appends host-reference C=A·B.
   Endeavour 193: first the log (if the module logs) and the die report (if it can die) -- the kernel
   has synchronised."
  (when *193-log-sites*
    (%193-cuda-emit-log-report stream))
  (when *193-die-sites*
    (%193-cuda-emit-die-report stream))
  (format stream "    // Read back and print output buffers~%")
  (dolist (alloc allocations)
    (let ((name      (getf alloc :name))
          (ptr       (getf alloc :ptr))
          (count     (getf alloc :count))
          (size-var  (getf alloc :size-var))
          (elem-type (getf alloc :elem-type)))
      (let ((n (or count size-var)))
        (format stream "    {~%")
        (format stream "        ~a* h = new ~a[~a];~%" elem-type elem-type n)
        (format stream "        CUDA_CHECK(cuMemcpyDtoH(h, ~a, ~a * sizeof(~a)));~%" ptr n elem-type)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < (size_t)~a; i++) {~%" n)
        (format stream "            std::cout << ~ah[i] << (i == (size_t)~a - 1 ? \"\" : \" \");~%" (%cuda-print-prefix elem-type) n)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "        delete[] h;~%")
        (format stream "    }~%"))))
  (when *mma-test-dims*
    (%cuda-emit-mma-reference stream allocations))
  (format stream "~%"))

;;; ===================================================================
;;; Endeavour 204: integer MMA in the CUDA harness.
;;; ===================================================================

;; src/hoist-cuda/main.lisp
(defun %cuda-mma-int-offset (role elem-str)
  "Added to an integer operand's fill, so the values can expose a wrong sign.  CHAR straddles zero and
   UCHAR sits above 127.  The same values as the L0 harness's %l0-mma-int-offset."
  (cond ((string-equal elem-str "char") (if (eq role :a) -2 -1))
        ((string-equal elem-str "unsigned char") 200)
        (t 0)))

;; src/hoist-cuda/main.lisp -- int8 tensor maps
(defun %cuda-tensor-map-data-type (elem-type)
  "Maps a Crisp element type to the CU_TENSOR_MAP_DATA_TYPE_* enum for cuTensorMapEncodeTiled.
   Endeavour 159: 16-bit operands included -- TMA is descriptor-driven and encodes f16/bf16
   directly."
  (let ((n (string-downcase (string elem-type))))
    (cond ((string= n "float")    "CU_TENSOR_MAP_DATA_TYPE_FLOAT32")
          ((string= n "double")   "CU_TENSOR_MAP_DATA_TYPE_FLOAT64")
          ((string= n "half")     "CU_TENSOR_MAP_DATA_TYPE_FLOAT16")
          ((string= n "bfloat16") "CU_TENSOR_MAP_DATA_TYPE_BFLOAT16")
          ((string= n "char")     "CU_TENSOR_MAP_DATA_TYPE_UINT8")   ; TMA moves bytes; cuda.h has no INT8
          ((member n (quote ("uchar" "unsigned char")) :test (function string=)) "CU_TENSOR_MAP_DATA_TYPE_UINT8")
          (t (error "cuTensorMapEncodeTiled: unsupported element type ~a (need float/double/half/bfloat16)"
                    elem-type)))))

;; src/hoist-cuda/main.lisp -- integer operands are filled through %cuda-mma-int-offset
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
         ;; Endeavor 134: assign an MMA role (A=first input, B=second input, C=&out) and
         ;; override the tensor extents accordingly.
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
             (elem-bytes  (%hoist-elem-type-bytes elem-str))
             (byte-size   (* total-elems elem-bytes)))
        ;; Endeavor 140 (wgmma B): swap to col-major (K-contiguous) strides AFTER row-major
        ;; sizing, so the buffer stays full-size while addressing becomes K-contiguous (the
        ;; wgmma descriptor reads SMEM directly).  Gated on *mma-swizzle-describes* (swizzle-fed
        ;; col-major tensors) so 137/138's row-major SMEM path is untouched.  (Swapping BEFORE
        ;; sizing was the earlier bug: total-elems = 1*ext0 undersized B's buffer -> MMA_WRONG.)

        (when (and (= rank 2)
                   (member param-name *mma-swizzle-describes* :test #'string-equal))
          (setf strides (list 1 (first extents))))
        (format stream "~%    // Tensor: ~a (rank=~d, ~a, ~d elements)~%"
                param-name rank elem-str total-elems)
        (format stream "    CUdeviceptr ~a;~%" ptr-var)
        (format stream "    CUDA_CHECK(cuMemAlloc(&~a, ~d * sizeof(~a)));~%"
                ptr-var total-elems elem-str)

        ;; Init: iota, or (MMA) role-based fill.
        (format stream "    {~%")
        (format stream "        ~a* h = new ~a[~d];~%" elem-str elem-str total-elems)
        (cond
          ((member mma-role '(:a :b))
           (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)((int)(_i % ~d) + (~d));~%"
                   total-elems elem-str (if (eq mma-role :a) 5 3) (%cuda-mma-int-offset mma-role elem-str)))
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

        ;; ptr
        (push (format nil "~a" ptr-var) arg-names)
        (incf current-idx)

        ;; byte-size
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
        (push (format nil "~a_byte_size" param-name-cpp) arg-names)
        (incf current-idx)
        ;; offsets (all zero)

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

;; src/hoist-cuda/main.lisp -- an integer C is compared exactly
(defun %cuda-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A.B (copy A/B/C back to host, compare).

   Endeavour 165: the reference follows the kernel's ELEMENT TYPE instead of being emitted in
   float throughout.  Against an fp64 kernel the old form read 8-byte buffers as 4-byte floats,
   so MMA_WRONG would have been a statement about the HARNESS, not the kernel -- and would have
   burned a GPU rental to say nothing.

   :elem-type is already on every allocation as a C++ type string; emit-readback beside this
   function has always used it.  Only this reference hardcoded float.

   THE TOLERANCE FOLLOWS THE TYPE, which is the whole point at 64 bits.  tf32 keeps 1e-2 relative
   because tf32 carries ~10 mantissa bits.  fp64 gets 1e-10 -- tight enough that a path which
   silently computed in single precision FAILS, the same discriminating property the endeavour's
   benchmark oracle has.  Run at tf32's tolerance an fp64 check would pass on an fp32 result and
   tell us nothing.

   Float emission is byte-identical to before."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let* ((ab (getf a :base)) (ac (getf a :count)) (at (or (getf a :elem-type) "float"))
               (bb (getf b :base)) (bc (getf b :count)) (bt (or (getf b :elem-type) "float"))
               (cb (getf c :base)) (cc (getf c :count)) (ct (or (getf c :elem-type) "float"))
               (doublep (string= ct "double"))
               (intp (and (member ct (quote ("int" "unsigned int")) :test (function string-equal)) t))
               ;; The accumulator is the OUTPUT's type: that is what the kernel actually
               ;; produced and what we are checking.
               (acct    ct)
               (zero    (cond (intp "0") (doublep "0.0") (t "0.0f")))
               (rel     (cond (intp "0") (doublep "1e-10") (t "1e-2f")))
               (abs     (cond (intp "0") (doublep "1e-12") (t "1e-3f")))
               (scale-suffix (if doublep "" "f")))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    // Endeavour 165: element type ~a, tolerance ~a rel / ~a abs~%" ct rel abs)
          (format stream "    {~%")
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" at ab at ac ab ab ac at)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" bt bb bt bc bb bb bc bt)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" ct cb ct cc cb cb cc ct)
          ;; OpenMP-parallel: this O(N^3) host C=A.B check dominated the large-size sweep (68
          ;; GFLOP at 4096 = minutes single-threaded).  reduction(+:mma_bad) avoids data races;
          ;; the pragma is a harmless no-op if the harness is built without -fopenmp.
          (format stream "      uint64_t mma_bad = 0;~%")
          (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        ~a acc = ~a;~%" acct zero)
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb)
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0~a;   // --mma-scale (MMA fired ~d times per fragment)~%"
                    *mma-scale* scale-suffix *mma-scale*))
          (format stream "        ~a got = ~a_h[i*~a_str0 + j*~a_str1];~%" acct cb cb cb)
          (format stream "        ~a d = got - acc; if (d < 0) d = -d;~%" acct)
          (format stream "        if (d > ~a * (acc < 0 ? -acc : acc) + ~a) mma_bad++;~%" rel abs)
          (format stream "      }~%")
          (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
          (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
          (format stream "      std::cout << std::endl;~%")
          (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%" ab bb cb)
          (format stream "    }~%"))))))

;; src/hoist-cuda/main.lisp -- an 8-bit C is the product clamped to its range
(defun %cuda-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A.B (copy A/B/C back to host, compare).

   Endeavour 165: the reference follows the kernel's ELEMENT TYPE instead of being emitted in
   float throughout.  Against an fp64 kernel the old form read 8-byte buffers as 4-byte floats,
   so MMA_WRONG would have been a statement about the HARNESS, not the kernel -- and would have
   burned a GPU rental to say nothing.

   :elem-type is already on every allocation as a C++ type string; emit-readback beside this
   function has always used it.  Only this reference hardcoded float.

   THE TOLERANCE FOLLOWS THE TYPE, which is the whole point at 64 bits.  tf32 keeps 1e-2 relative
   because tf32 carries ~10 mantissa bits.  fp64 gets 1e-10 -- tight enough that a path which
   silently computed in single precision FAILS, the same discriminating property the endeavour's
   benchmark oracle has.  Run at tf32's tolerance an fp64 check would pass on an fp32 result and
   tell us nothing.

   Float emission is byte-identical to before."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let* ((ab (getf a :base)) (ac (getf a :count)) (at (or (getf a :elem-type) "float"))
               (bb (getf b :base)) (bc (getf b :count)) (bt (or (getf b :elem-type) "float"))
               (cb (getf c :base)) (cc (getf c :count)) (ct (or (getf c :elem-type) "float"))
               (doublep (string= ct "double"))
               (narrowp (and (member ct (quote ("char" "unsigned char")) :test (function string-equal)) t))
               (intp (and (or narrowp (member ct (quote ("int" "unsigned int")) :test (function string-equal))) t))
               ;; The accumulator is the OUTPUT's type: that is what the kernel actually
               ;; produced and what we are checking.
               (acct    (if narrowp "int" ct))
               (zero    (cond (intp "0") (doublep "0.0") (t "0.0f")))
               (rel     (cond (intp "0") (doublep "1e-10") (t "1e-2f")))
               (abs     (cond (intp "0") (doublep "1e-12") (t "1e-3f")))
               (scale-suffix (if doublep "" "f")))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    // Endeavour 165: element type ~a, tolerance ~a rel / ~a abs~%" ct rel abs)
          (format stream "    {~%")
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" at ab at ac ab ab ac at)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" bt bb bt bc bb bb bc bt)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" ct cb ct cc cb cb cc ct)
          ;; OpenMP-parallel: this O(N^3) host C=A.B check dominated the large-size sweep (68
          ;; GFLOP at 4096 = minutes single-threaded).  reduction(+:mma_bad) avoids data races;
          ;; the pragma is a harmless no-op if the harness is built without -fopenmp.
          (format stream "      uint64_t mma_bad = 0;~%")
          (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        ~a acc = ~a;~%" acct zero)
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb)
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0~a;   // --mma-scale (MMA fired ~d times per fragment)~%"
                    *mma-scale* scale-suffix *mma-scale*))
          (when narrowp
            (multiple-value-bind (lo hi) (if (string-equal ct "char") (values -128 127) (values 0 255))
              (format stream "        if (acc < ~d) acc = ~d; if (acc > ~d) acc = ~d;~%" lo lo hi hi)))
          (format stream "        ~a got = ~a_h[i*~a_str0 + j*~a_str1];~%" acct cb cb cb)
          (format stream "        ~a d = got - acc; if (d < 0) d = -d;~%" acct)
          (format stream "        if (d > ~a * (acc < 0 ? -acc : acc) + ~a) mma_bad++;~%" rel abs)
          (format stream "      }~%")
          (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
          (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
          (format stream "      std::cout << std::endl;~%")
          (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%" ab bb cb)
          (format stream "    }~%"))))))

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-launch-lambda (stream block-x block-y shared-bytes)
  "The launch itself: an `_crisp_launch` lambda over the final gridX/gridY/gridZ, called once for the
   correctness readback that follows.  emit-launch anchors its cluster-grid fix-up on this lambda's
   first line, so it must stay the first thing after ALL grid computation.  (The lambda also served
   the --mma-bench timed relaunch loop, retired 2026-10-16.)

   BUG 135: a failed launch is fatal.  The lambda returns the result and CUDA_CHECK ends the program.
   It used to print to stderr and carry on, so the harness reported success and compared buffers
   nothing had written.  cuCtxSynchronize does not report a launch that never happened."
  (format stream "    auto _crisp_launch = [&]() {~%")
  (format stream "      return cuLaunchKernel(kernel,~%")
  (format stream "          gridX, gridY, gridZ,~%")
  (format stream "          ~a, ~a, 1,~%" block-x block-y)
  (format stream "          ~a, 0,~%" shared-bytes)
  (format stream "          kernelParams, nullptr);~%")
  (format stream "    };~%")
  (format stream "    CUresult _crisp_launch_result = _crisp_launch();~%")
  (format stream "    if (_crisp_launch_result == CUDA_ERROR_LAUNCH_OUT_OF_RESOURCES) {~%")
  (format stream "        std::cerr << \"This kernel needs more registers per thread than one workgroup can have.  \"~%")
  (format stream "                  << \"Fix its workgroup size with (local-size :set-to N), or set (declare (max-registers N)).\" << std::endl;~%")
  (format stream "    }~%")
  (format stream "    CUDA_CHECK(_crisp_launch_result);~%~%"))
