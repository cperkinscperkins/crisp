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
