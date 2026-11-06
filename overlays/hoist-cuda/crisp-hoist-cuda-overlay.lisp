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
(in-package :crisp.hoist.cuda)

;;;; ======================================================================
;;;; Endeavour 208 -- the --mma-test harness at 16 bits.
;;;; The hoist maps half and bfloat16 to uint16_t, so the role fill `(uint16_t)((int)(_i % 5))` wrote
;;;; small integers as RAW BIT PATTERNS (fp16/bf16 denormals) and the host reference multiplied those
;;;; integers: every 16-bit MMA_CORRECT / MMA_WRONG was a statement about the harness, not the kernel
;;;; (the reason matmul_2wg_deep.crisp used its own bench harness).  Now a 16-bit A / B is filled
;;;; through an encoder and the reference decodes it.  Every other element type is unchanged.
;;;; ======================================================================

;; src/hoist-cuda/main.lisp
(defun %208-mma-16bit-kind (elem-type)
  "Endeavour 208.  :bf16 / :f16 for a bfloat16 / half Crisp element type, else NIL."
  (let ((n (and elem-type (symbolp elem-type) (symbol-name elem-type))))
    (cond ((null n) nil)
          ((string= n "BFLOAT16") :bf16)
          ((string= n "HALF") :f16)
          (t nil))))

;; src/hoist-cuda/main.lisp
(defun %208-emit-16bit-fill (stream total-elems kind modulus)
  "Endeavour 208.  Fill a 16-bit MMA operand with (_i % MODULUS) ENCODED as KIND.  Small integers are
   exact in both formats, so the reference is exact too."
  (format stream "        auto crisp_enc = [](float f) -> uint16_t { uint32_t x; std::memcpy(&x, &f, 4); ~a };~%"
          (if (eq kind :bf16)
              "return (uint16_t)(x >> 16);"
              "uint32_t s = (x >> 16) & 0x8000u; int e = (int)((x >> 23) & 0xffu) - 112; uint32_t m = x & 0x7fffffu; if (((x >> 23) & 0xffu) == 0u || e <= 0) return (uint16_t)s; if (e >= 31) return (uint16_t)(s | 0x7c00u); return (uint16_t)(s | ((uint32_t)e << 10) | (m >> 13));"))
  (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = crisp_enc((float)((int)(_i % ~d)));   // endeavour 208: ~(~a~) bits~%"
          total-elems modulus kind))

;; src/hoist-cuda/main.lisp
(defun %208-emit-16bit-decoder (stream kind)
  "Endeavour 208.  The reference's decoder for a 16-bit operand of KIND."
  (format stream "      auto crisp_dec = [](uint16_t h) -> float { ~a };   // endeavour 208: ~(~a~)~%"
          (if (eq kind :bf16)
              "uint32_t x = (uint32_t)h << 16; float f; std::memcpy(&f, &x, 4); return f;"
              "uint32_t s = ((uint32_t)h & 0x8000u) << 16, e = ((uint32_t)h >> 10) & 0x1fu, m = (uint32_t)h & 0x3ffu, x; if (e == 0u) x = s; else if (e == 31u) x = s | 0x7f800000u | (m << 13); else x = s | ((e + 112u) << 23) | (m << 13); float f; std::memcpy(&f, &x, 4); return f;")
          kind))

;; src/hoist-cuda/main.lisp
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
          ;; Endeavour 208: a 16-bit operand is filled with ENCODED small integers.
          ((and (member mma-role '(:a :b)) (%208-mma-16bit-kind elem-type))
           (%208-emit-16bit-fill stream total-elems (%208-mma-16bit-kind elem-type) (if (eq mma-role :a) 5 3)))
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
                          :mma-16bit (%208-mma-16bit-kind elem-type)   ; endeavour 208
                          :base      param-name-cpp))
        (values current-idx (nreverse arg-names) alloc)))))

;; src/hoist-cuda/main.lisp
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
          ;; Endeavour 208: a 16-bit A / B is decoded before it is multiplied.
          (when (getf a :mma-16bit)
            (%208-emit-16bit-decoder stream (getf a :mma-16bit)))
          (format stream "      uint64_t mma_bad = 0;~%")
          (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        ~a acc = ~a;~%" acct zero)
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (if (getf a :mma-16bit)
              (format stream "            acc += crisp_dec(~a_h[i*~a_str0 + kk*~a_str1]) * crisp_dec(~a_h[kk*~a_str0 + j*~a_str1]);~%" ab ab ab bb bb bb)
              (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb))
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
(defun %208-emit-16bit-decoder-named (stream kind name)
  "Endeavour 208.  A decoder lambda NAME for a 16-bit value of KIND (:bf16 / :f16)."
  (format stream "      auto ~a = [](uint16_t h) -> float { ~a };   // endeavour 208: ~(~a~)~%"
          name
          (if (eq kind :bf16)
              "uint32_t x = (uint32_t)h << 16; float f; std::memcpy(&f, &x, 4); return f;"
              "uint32_t s = ((uint32_t)h & 0x8000u) << 16, e = ((uint32_t)h >> 10) & 0x1fu, m = (uint32_t)h & 0x3ffu, x; if (e == 0u) x = s; else if (e == 31u) x = s | 0x7f800000u | (m << 13); else x = s | ((e + 112u) << 23) | (m << 13); float f; std::memcpy(&f, &x, 4); return f;")
          kind))

;; src/hoist-cuda/main.lisp
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
               ;; Endeavour 208: a 16-bit C is decoded and compared in float.
               (acct    (cond (narrowp "int") ((getf c :mma-16bit) "float") (t ct)))
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
          ;; Endeavour 208: a 16-bit A / B is decoded before it is multiplied.
          (when (getf a :mma-16bit)
            (%208-emit-16bit-decoder stream (getf a :mma-16bit)))
          (when (getf c :mma-16bit)
            (%208-emit-16bit-decoder-named stream (getf c :mma-16bit) "crisp_dec_c"))
          (format stream "      uint64_t mma_bad = 0;~%")
          (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        ~a acc = ~a;~%" acct zero)
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (if (getf a :mma-16bit)
              (format stream "            acc += crisp_dec(~a_h[i*~a_str0 + kk*~a_str1]) * crisp_dec(~a_h[kk*~a_str0 + j*~a_str1]);~%" ab ab ab bb bb bb)
              (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0~a;   // --mma-scale (MMA fired ~d times per fragment)~%"
                    *mma-scale* scale-suffix *mma-scale*))
          (when narrowp
            (multiple-value-bind (lo hi) (if (string-equal ct "char") (values -128 127) (values 0 255))
              (format stream "        if (acc < ~d) acc = ~d; if (acc > ~d) acc = ~d;~%" lo lo hi hi)))
          (if (getf c :mma-16bit)
              (format stream "        float got = crisp_dec_c(~a_h[i*~a_str0 + j*~a_str1]);~%" cb cb cb)
              (format stream "        ~a got = ~a_h[i*~a_str0 + j*~a_str1];~%" acct cb cb cb))
          (format stream "        ~a d = got - acc; if (d < 0) d = -d;~%" acct)
          (format stream "        if (d > ~a * (acc < 0 ? -acc : acc) + ~a) mma_bad++;~%" rel abs)
          (format stream "      }~%")
          (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
          (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
          (format stream "      std::cout << std::endl;~%")
          (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%" ab bb cb)
          (format stream "    }~%"))))))

;;;; ======================================================================
;;;; Endeavour 208 phase 4 -- block-scaled microfloat operands in the CUDA --mma-test harness.
;;;; A matrix of a def-microfloat-block holds packed codes, (M K) in ELEMENTS: the harness sizes, fills
;;;; and TMA-describes it in BYTES (K/2 per row for fp4).  Its scales vector is sized and filled in the
;;;; declared :blocked-128x4 layout (metadata :microfloat, from the compiler's scale-layout declares).
;;;; The reference decodes fp4 / e4m3 / e5m2 codes and ue4m3 / ue8m0 scales.  Shape constraint (header):
;;;; the fdefinition wrappers below must be split base + wrapper when folded.
;;;; ======================================================================

;; src/hoist-cuda/main.lisp
(defvar *208-mf-roles* nil
  "Endeavour 208 phase 4.  While a kernel's args are emitted under --mma-test: alist of parameter name
   (string) -> :a / :b, the rank-2 inputs in signature order (the harness's role rule), so a scales
   vector knows its matrix's role wherever it sits in the signature.")

;; src/hoist-cuda/main.lisp
(defvar *208-mf-params* nil
  "Endeavour 208 phase 4.  Alist of block-matrix parameter name (C spelling) -> plist (:epb ..), filled
   as their args are emitted; the tensor-map encoder uses the byte-space variables of these.")

;; src/hoist-cuda/main.lisp
(defun %208-mf-epb (mf)
  "Endeavour 208.  Codes per byte of the block described by the :microfloat plist MF."
  (if (string-equal (getf mf :base) "fp4") 2 1))

;; src/hoist-cuda/main.lisp
(defvar *208-orig-emit-kernel-args* (fdefinition 'emit-kernel-args)
  "Endeavour 208 phase 4.  emit-kernel-args before the block-operand roles.")

;; src/hoist-cuda/main.lisp
(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "Endeavour 208 phase 4 wrapper: binds *208-mf-roles* (rank-2 inputs in order -> :a, :b) and
   *208-mf-params*, then the original."
  (let ((*208-mf-roles* (let ((n 0))
                          (loop for p in declared-sig
                                when (and (eql (getf p :rank) 2) (eq (getf p :direction) :in)
                                          (not (eq (getf p :kind) :tensor-map)))
                                  collect (cons (getf p :name) (if (zerop (prog1 n (incf n))) :a :b)))))
        (*208-mf-params* nil))
    (funcall *208-orig-emit-kernel-args* stream declared-sig aliases records dispatch-info)))

;; src/hoist-cuda/main.lisp
(defun %208-emit-args-tail (stream nm ptr bytes rank strides extents length)
  "Endeavour 208.  The tensor ABI after the allocation, as %cuda-emit-tensor-arg emits it: ptr,
   byte_size, offsets, strides, extents, length.  Returns the arg names in order."
  (let ((args (list ptr)))
    (format stream "    uint64_t ~a_byte_size = ~dULL;~%" nm bytes)
    (push (format nil "~a_byte_size" nm) args)
    (dotimes (k rank)
      (format stream "    uint64_t ~a_off~d = 0ULL;~%" nm k) (push (format nil "~a_off~d" nm k) args))
    (dotimes (k rank)
      (format stream "    uint64_t ~a_str~d = ~dULL;~%" nm k (nth k strides)) (push (format nil "~a_str~d" nm k) args))
    (dotimes (k rank)
      (format stream "    uint64_t ~a_ext~d = ~dULL;~%" nm k (nth k extents)) (push (format nil "~a_ext~d" nm k) args))
    (format stream "    uint64_t ~a_length = ~dULL;~%" nm length)
    (push (format nil "~a_length" nm) args)
    (nreverse args)))

;; src/hoist-cuda/main.lisp
(defun %208-emit-mf-codes-arg (stream param-name mf arg-index)
  "Endeavour 208 phase 4.  A block matrix (role :a = (M K), :b = (K N) K-contiguous): allocated and
   filled as bytes -- fp4 two distinct codes per byte, every code reachable; fp8 finite codes with both
   signs -- with element extents and strides for the kernel and byte-space <nm>_bext<k> / <nm>_bstr<k>
   for its TMA descriptor."
  (let* ((nm   (substitute #\_ #\- param-name))
         (ptr  (format nil "~a_ptr" nm))
         (role (or (cdr (assoc param-name *208-mf-roles* :test #'string-equal)) :a))
         (epb  (%208-mf-epb mf))
         (base (string-downcase (getf mf :base))))
    (incf *mma-input-counter*)
    (destructuring-bind (m n k) *mma-test-dims*
      (let* ((extents (if (eq role :a) (list m k) (list k n)))
             (ci      (if (eq role :a) 1 0))                 ; the K-contiguous dimension
             (strides (if (eq role :a) (list k 1) (list 1 k)))
             (bext    (loop for e in extents for i from 0 collect (if (= i ci) (floor e epb) e)))
             (bstr    (loop for s in strides collect (if (= s 1) 1 (floor s epb))))
             (elems   (* (first extents) (second extents)))
             (bytes   (floor elems epb)))
        (format stream "~%    // Endeavour 208: ~a holds ~a codes (~a ~a block ~a): (~a ~a) elements, ~d bytes~%"
                param-name base (getf mf :block) (getf mf :scale) (getf mf :vec) (first extents) (second extents) bytes)
        (format stream "    CUdeviceptr ~a;~%    CUDA_CHECK(cuMemAlloc(&~a, ~d));~%" ptr ptr bytes)
        (format stream "    {~%        unsigned char* h = new unsigned char[~d];~%" bytes)
        (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = ~a;~%" bytes
                (cond ((= epb 2) (if (eq role :a)
                                     "(unsigned char)((((_i * 3 + 1) % 16)) | (((_i * 5 + 2) % 16) << 4))"
                                     "(unsigned char)((((_i * 7 + 3) % 16)) | (((_i * 11 + 5) % 16) << 4))"))
                      ((string= base "fp8-e4m3") "(unsigned char)(((_i * 37) % 0x70) | (((_i >> 3) & 1) << 7))")
                      (t "(unsigned char)(((_i * 29) % 0x78) | (((_i >> 3) & 1) << 7))")))
        (format stream "        CUDA_CHECK(cuMemcpyHtoD(~a, h, ~d));~%        delete[] h;~%    }~%" ptr bytes)
        (dotimes (i 2)
          (format stream "    uint64_t ~a_bext~d = ~dULL;  uint64_t ~a_bstr~d = ~dULL;~%" nm i (nth i bext) nm i (nth i bstr)))
        (push (cons nm (list :epb epb)) *208-mf-params*)
        (let ((args (%208-emit-args-tail stream nm ptr bytes 2 strides extents elems)))
          (values (+ arg-index (length args)) args
                  (list :name param-name :ptr ptr :count bytes :elem-type "unsigned char" :direction :in
                        :mma-role role :base nm :microfloat mf :ci ci :bstr bstr)))))))

;; src/hoist-cuda/main.lisp
(defun %208-emit-mf-scales-arg (stream param-name mf arg-index)
  "Endeavour 208 phase 4.  The scales of block matrix (:scales-of) in :blocked-128x4: rows R (M for A,
   N for B) padded to 128, K/vec scales per row padded to 4; R/128 x K/(4 vec) atoms of 512 bytes.
   Filled with finite positive scales near 1 (ue8m0 2^-2..2^2, ue4m3 0.5..1.9)."
  (let* ((nm   (substitute #\_ #\- param-name))
         (ptr  (format nil "~a_ptr" nm))
         (of   (getf mf :scales-of))
         (role (or (cdr (assoc of *208-mf-roles* :test #'string-equal)) :a))
         (vec  (getf mf :vec)))
    (destructuring-bind (m n k) *mma-test-dims*
      (let* ((rows   (if (eq role :a) m n))
             (katoms (ceiling (ceiling k vec) 4))
             (bytes  (* (ceiling rows 128) 128 katoms 4)))
        (format stream "~%    // Endeavour 208: ~a = the ~a scales of ~a, :blocked-128x4 (~a rows, ~a atoms per 128 rows), ~d bytes~%"
                param-name (getf mf :scale) of rows katoms bytes)
        (format stream "    CUdeviceptr ~a;~%    CUDA_CHECK(cuMemAlloc(&~a, ~d));~%" ptr ptr bytes)
        (format stream "    {~%        unsigned char* h = new unsigned char[~d];~%" bytes)
        (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = ~a;~%" bytes
                (if (string-equal (getf mf :scale) "fp8-e8m0")
                    "(unsigned char)(125 + (_i * 7) % 5)"
                    "(unsigned char)(0x30 + (_i * 3) % 16)"))
        (format stream "        CUDA_CHECK(cuMemcpyHtoD(~a, h, ~d));~%        delete[] h;~%    }~%" ptr bytes)
        (let ((args (%208-emit-args-tail stream nm ptr bytes 1 (list 1) (list bytes) bytes)))
          (values (+ arg-index (length args)) args
                  (list :name param-name :ptr ptr :count bytes :elem-type "unsigned char" :direction :in
                        :mma-role nil :base nm :mf-scales-of of :mf-katoms katoms :microfloat mf)))))))

;; src/hoist-cuda/main.lisp
(defvar *208-orig-cuda-emit-tensor-arg* (fdefinition '%cuda-emit-tensor-arg)
  "Endeavour 208 phase 4.  The tensor-arg emitter before block operands.")

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-tensor-arg (stream param param-name param-type param-dir arg-index dispatch-info)
  "Endeavour 208 phase 4 wrapper: under --mma-test, a block matrix or its scales vector (:microfloat in
   the metadata) is emitted by %208-emit-mf-codes-arg / %208-emit-mf-scales-arg; anything else by the
   original."
  (let ((mf (getf param :microfloat)))
    (cond ((and mf *mma-test-dims* (getf mf :scales))
           (%208-emit-mf-codes-arg stream param-name mf arg-index))
          ((and mf *mma-test-dims* (getf mf :scales-of))
           (%208-emit-mf-scales-arg stream param-name mf arg-index))
          (t (funcall *208-orig-cuda-emit-tensor-arg* stream param param-name param-type param-dir
                      arg-index dispatch-info)))))

;; src/hoist-cuda/main.lisp
(defvar *208-orig-cuda-emit-tensor-map-encode* (fdefinition '%cuda-emit-tensor-map-encode)
  "Endeavour 208 phase 4.  The tensor-map encoder before block operands.")

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-tensor-map-encode (stream param)
  "Endeavour 208 phase 4 wrapper: a descriptor of a block matrix is encoded over BYTES -- UINT8, the
   K-contiguous extent divided by codes-per-byte (<d>_bext / <d>_bstr) -- so the codes tile's 128-byte
   box is 256 fp4 or 128 fp8 codes.  The original emits it, with the byte variables in place of the
   element ones."
  (let* ((describes (substitute #\_ #\- (or (getf param :describes) "")))
         (blk (assoc describes *208-mf-params* :test #'string=)))
    (if (null blk)
        (funcall *208-orig-cuda-emit-tensor-map-encode* stream param)
        (let ((text (with-output-to-string (s)
                      (funcall *208-orig-cuda-emit-tensor-map-encode* s param))))
          (format stream "~%    // Endeavour 208: ~a is block codes -- the descriptor is in bytes~a"
                  describes
                  (reduce (lambda (acc pair) (%208-replace-all acc (car pair) (cdr pair)))
                          (list (cons (format nil "~a_ext" describes) (format nil "~a_bext" describes))
                                (cons (format nil "~a_str" describes) (format nil "~a_bstr" describes)))
                          :initial-value text))))))

;; src/hoist-cuda/main.lisp
(defun %208-replace-all (string old new)
  "Endeavour 208.  STRING with every occurrence of OLD replaced by NEW."
  (with-output-to-string (o)
    (loop with start = 0
          for p = (search old string :start2 start)
          do (write-string string o :start start :end (or p (length string)))
             (if p (progn (write-string new o) (setf start (+ p (length old)))) (return)))))

;; src/hoist-cuda/main.lisp
(defun %208-emit-mf-decoders (stream)
  "Endeavour 208 phase 4.  C decoders of the OCP microfloat formats, exact (powers of two)."
  (format stream "      auto mf_fp4  = [](unsigned v) -> float { unsigned m = v & 1, e = (v >> 1) & 3; float g = e == 0 ? 0.5f * m : ldexpf(1.0f + 0.5f * m, (int)e - 1); return (v & 8) ? -g : g; };~%")
  (format stream "      auto mf_e4m3 = [](unsigned v) -> float { unsigned m = v & 7, e = (v >> 3) & 15; float g = e == 0 ? ldexpf((float)m / 8.0f, -6) : ldexpf(1.0f + m / 8.0f, (int)e - 7); return (v & 128) ? -g : g; };~%")
  (format stream "      auto mf_e5m2 = [](unsigned v) -> float { unsigned m = v & 3, e = (v >> 2) & 31; float g = e == 0 ? ldexpf((float)m / 4.0f, -14) : ldexpf(1.0f + m / 4.0f, (int)e - 15); return (v & 128) ? -g : g; };~%")
  (format stream "      auto mf_e8m0 = [](unsigned v) -> float { return ldexpf(1.0f, (int)v - 127); };~%")
  (format stream "      auto mf_blk  = [](uint64_t r, uint64_t j, uint64_t katoms) -> uint64_t { return ((r / 128) * katoms + j / 4) * 512 + (r % 32) * 16 + ((r % 128) / 32) * 4 + (j % 4); };~%"))

;; src/hoist-cuda/main.lisp
(defun %208-mf-elem-expr (alloc row col)
  "Endeavour 208 phase 4.  C expression decoding element (ROW COL) of the block matrix ALLOC (role :a
   is (M K), :b is (K N)); fp4's even element is the low nibble (D-206-3)."
  (let* ((mf (getf alloc :microfloat)) (nm (getf alloc :base)) (epb (%208-mf-epb mf))
         (bstr (getf alloc :bstr)) (ci (getf alloc :ci))
         (kexpr (if (= ci 1) col row))
         (byte (if (= ci 1)
                   (format nil "~a_h[~a * ~dULL + (~a) / ~d]" nm row (first bstr) col epb)
                   (format nil "~a_h[(~a) / ~d + ~a * ~dULL]" nm row epb col (second bstr))))
         (base (string-downcase (getf mf :base))))
    (cond ((= epb 2) (format nil "mf_fp4(((~a) & 1) ? (~a >> 4) : (~a & 15))" kexpr byte byte))
          ((string= base "fp8-e4m3") (format nil "mf_e4m3(~a)" byte))
          (t (format nil "mf_e5m2(~a)" byte)))))

;; src/hoist-cuda/main.lisp
(defvar *208-orig-cuda-emit-mma-reference* (fdefinition '%cuda-emit-mma-reference)
  "Endeavour 208 phase 4.  The MMA reference before block operands.")

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-mma-reference (stream allocations)
  "Endeavour 208 phase 4 wrapper: with block-matrix operands, the reference is
     C[i][j] = sum_k (dec(A[i][k]) * sA(i, k/vec)) * (dec(B[k][j]) * sB(j, k/vec))
   with the scales read through the :blocked-128x4 layout, compared in float with a tolerance of 1e-3
   of the sum of |terms| (the products are exact; only the summation order may differ).  Anything
   else goes to the original."
  (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
        (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
        (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
    (if (not (and a b c (getf a :microfloat) (getf b :microfloat)))
        (funcall *208-orig-cuda-emit-mma-reference* stream allocations)
        (let* ((sa (find (getf a :name) allocations :key (lambda (x) (getf x :mf-scales-of)) :test #'equal))
               (sb (find (getf b :name) allocations :key (lambda (x) (getf x :mf-scales-of)) :test #'equal))
               (mf (getf a :microfloat))
               (vec (getf mf :vec))
               (sdec (if (string-equal (getf mf :scale) "fp8-e8m0") "mf_e8m0" "mf_e4m3")))
          (unless (and sa sb)
            (error "208 harness: block operands ~a / ~a need their scales vectors (scale-layout declares)" (getf a :name) (getf b :name)))
          (destructuring-bind (m n k) *mma-test-dims*
            (format stream "~%    // Endeavour 208: block-scaled host reference (~a, scales per ~a, :blocked-128x4)~%" (getf mf :block) vec)
            (format stream "    {~%")
            (dolist (x (list a sa b sb c))
              (let ((ty (if (eq x c) (or (getf c :elem-type) "float") "unsigned char")))
                (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%"
                        ty (getf x :base) ty (getf x :count) (getf x :base) (getf x :base) (getf x :count) ty)))
            (%208-emit-mf-decoders stream)
            (format stream "      uint64_t mma_bad = 0;~%")
            (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
            (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
            (format stream "        double acc = 0.0, mag = 0.0;~%")
            (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++) {~%" k)
            (format stream "          double t = (double)~a * ~a(~a_h[mf_blk(i, kk / ~d, ~dULL)]) * (double)~a * ~a(~a_h[mf_blk(j, kk / ~d, ~dULL)]);~%"
                    (%208-mf-elem-expr a "i" "kk") sdec (getf sa :base) vec (getf sa :mf-katoms)
                    (%208-mf-elem-expr b "kk" "j") sdec (getf sb :base) vec (getf sb :mf-katoms))
            (format stream "          acc += t; mag += t < 0 ? -t : t;~%        }~%")
            (format stream "        double got = ~a_h[i*~a_str0 + j*~a_str1];~%" (getf c :base) (getf c :base) (getf c :base))
            (format stream "        double d = got - acc; if (d < 0) d = -d;~%")
            (format stream "        if (d > 1e-3 * mag + 1e-6) { if (mma_bad < 4) printf(\"  C[%llu][%llu] = %g, expected %g\\n\", (unsigned long long)i, (unsigned long long)j, got, acc); mma_bad++; }~%")
            (format stream "      }~%")
            (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
            (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
            (format stream "      std::cout << std::endl;~%")
            (format stream "      printf(\"  C[0][0] = %g, C[~d][~d] = %g\\n\", (double)~a_h[0], ~d, ~d, (double)~a_h[(~dULL)*~a_str0 + (~dULL)*~a_str1]);~%"
                    (1- m) (1- n) (getf c :base) (1- m) (1- n) (getf c :base) (1- m) (getf c :base) (1- n) (getf c :base))
            (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%"
                    (getf a :base) (getf sa :base) (getf b :base) (getf sb :base) (getf c :base))
            (format stream "    }~%"))))))

;; src/hoist-cuda/main.lisp -- fold: a skip clause in emit-structs (beside TENSOR_ / STORAGE_).
(defvar *208-orig-emit-structs* (fdefinition 'emit-structs)
  "Endeavour 208 phase 4.  emit-structs before records of handles were skipped.")

;; src/hoist-cuda/main.lisp
(defun emit-structs (stream structs)
  "Endeavour 208 phase 4 wrapper: a record with a TENSOR member (a def-microfloat-block's codes and
   scales, or any record of handles) has no C spelling, and D-206-1 keeps it out of kernel
   signatures, so the host never needs it: it is skipped.  The rest go to the original."
  (funcall *208-orig-emit-structs* stream
           (remove-if (lambda (s)
                        (some (lambda (m) (and (consp m) (consp (second m)) (symbolp (first (second m)))
                                               (string-equal (symbol-name (first (second m))) "TENSOR")))
                              (cddr s)))
                      structs)))

;; src/hoist-cuda/main.lisp -- corrected copy: the sample printf passed the row and column twice.
(defun %cuda-emit-mma-reference (stream allocations)
  "Endeavour 208 phase 4 wrapper: with block-matrix operands, the reference is
     C[i][j] = sum_k (dec(A[i][k]) * sA(i, k/vec)) * (dec(B[k][j]) * sB(j, k/vec))
   with the scales read through the :blocked-128x4 layout, compared in float with a tolerance of 1e-3
   of the sum of |terms| (the products are exact; only the summation order may differ).  Anything
   else goes to the original."
  (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
        (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
        (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
    (if (not (and a b c (getf a :microfloat) (getf b :microfloat)))
        (funcall *208-orig-cuda-emit-mma-reference* stream allocations)
        (let* ((sa (find (getf a :name) allocations :key (lambda (x) (getf x :mf-scales-of)) :test #'equal))
               (sb (find (getf b :name) allocations :key (lambda (x) (getf x :mf-scales-of)) :test #'equal))
               (mf (getf a :microfloat))
               (vec (getf mf :vec))
               (sdec (if (string-equal (getf mf :scale) "fp8-e8m0") "mf_e8m0" "mf_e4m3")))
          (unless (and sa sb)
            (error "208 harness: block operands ~a / ~a need their scales vectors (scale-layout declares)" (getf a :name) (getf b :name)))
          (destructuring-bind (m n k) *mma-test-dims*
            (format stream "~%    // Endeavour 208: block-scaled host reference (~a, scales per ~a, :blocked-128x4)~%" (getf mf :block) vec)
            (format stream "    {~%")
            (dolist (x (list a sa b sb c))
              (let ((ty (if (eq x c) (or (getf c :elem-type) "float") "unsigned char")))
                (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%"
                        ty (getf x :base) ty (getf x :count) (getf x :base) (getf x :base) (getf x :count) ty)))
            (%208-emit-mf-decoders stream)
            (format stream "      uint64_t mma_bad = 0;~%")
            (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
            (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
            (format stream "        double acc = 0.0, mag = 0.0;~%")
            (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++) {~%" k)
            (format stream "          double t = (double)~a * ~a(~a_h[mf_blk(i, kk / ~d, ~dULL)]) * (double)~a * ~a(~a_h[mf_blk(j, kk / ~d, ~dULL)]);~%"
                    (%208-mf-elem-expr a "i" "kk") sdec (getf sa :base) vec (getf sa :mf-katoms)
                    (%208-mf-elem-expr b "kk" "j") sdec (getf sb :base) vec (getf sb :mf-katoms))
            (format stream "          acc += t; mag += t < 0 ? -t : t;~%        }~%")
            (format stream "        double got = ~a_h[i*~a_str0 + j*~a_str1];~%" (getf c :base) (getf c :base) (getf c :base))
            (format stream "        double d = got - acc; if (d < 0) d = -d;~%")
            (format stream "        if (d > 1e-3 * mag + 1e-6) { if (mma_bad < 4) printf(\"  C[%llu][%llu] = %g, expected %g\\n\", (unsigned long long)i, (unsigned long long)j, got, acc); mma_bad++; }~%")
            (format stream "      }~%")
            (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
            (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
            (format stream "      std::cout << std::endl;~%")
            (format stream "      printf(\"  C[0][0] = %g, C[~d][~d] = %g\\n\", (double)~a_h[0], (double)~a_h[(~dULL)*~a_str0 + (~dULL)*~a_str1]);~%"
                    (1- m) (1- n) (getf c :base) (getf c :base) (1- m) (getf c :base) (1- n) (getf c :base))
            (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%"
                    (getf a :base) (getf sa :base) (getf b :base) (getf sb :base) (getf c :base))
            (format stream "    }~%"))))))


;; src/hoist-cuda/main.lisp -- corrected copy: "unsigned char" is 1 byte.
(defun %hoist-elem-type-bytes (elem-str)
  "Bytes occupied by one element of the C++ type named ELEM-STR.

   The canonical width table for the CUDA hoist's sizer AND emitters, which must agree:
   %cuda-shared-layout computes the launch request and the per-tile offsets from the same
   numbers, and BUG 046 was exactly the divergence that results when they do not.
   Unknown types keep the historical 4, so a type this table has not met is sized as before.
   Endeavour 208: unsigned char -- what crisp-type-to-cpp-type gives for uchar -- was missing, so every
   uchar scratch tile was sized 4 bytes per element (found when a block-scaled ring asked for 648 KB)."
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
         (string-equal elem-str "unsigned char")   ; Endeavour 208: crisp-type-to-cpp-type's spelling of uchar
         (string-equal elem-str "signed char")
         (string-equal elem-str "uint8_t")
         (string-equal elem-str "int8_t")
         (string-equal elem-str "bool")) 1)
    (t 4)))

