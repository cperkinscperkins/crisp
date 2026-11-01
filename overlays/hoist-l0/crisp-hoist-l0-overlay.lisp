;;;; EMPTY as of 2026-10-25 -- endeavour 193 folded: the shared report helpers into src/hoist/common.lisp
;;;; (exported from crisp.hoist); %193-l0-emit-die-report / -log-report, and the site tables bound in
;;;; generate-l0-launcher and reported at the end of generate-kernel-launch (src/hoist-l0/main.lisp).
;;;; EMPTY as of 2026-10-30 -- endeavour 201 (:match-global-size scratch) folded into src/hoist-l0/main.lisp:
;;;; %l0-global-size-size-p (new), %l0-num-workgroups-size-p (accepts it), %l0-deferred-global-scratch-block
;;;; (a SIZE-EXPR parameter; group count x wg_size), its caller passes it; the wrapper and
;;;; *201-scratch-size-expr* dropped.  %l0-scratch-symbolic-expr refuses it for LOCAL scratch.
(in-package :crisp.hoist.l0)

;;; ===================================================================
;;; Endeavour 204: integer MMA in the L0 harness.
;;; ===================================================================

;; src/hoist-l0/main.lisp
(defun %l0-mma-int-elem-p (elem)
  "T for an integer MMA element type.  Metadata has already reduced a derived type to its primitive."
  (and elem (symbolp elem)
       (member (symbol-name elem) '("CHAR" "UCHAR" "INT" "UINT") :test #'string-equal)
       t))

;; src/hoist-l0/main.lisp
(defun %l0-mma-int-offset (role elem)
  "Added to an integer operand's fill, so the values can expose a wrong sign bit.  CHAR straddles zero,
   so reading it unsigned gives a wrong product.  UCHAR sits above 127, so reading it signed does too.
   Used by BOTH the fill and the reference, like %l0-mma-fill-modulus."
  (let ((n (symbol-name elem)))
    (cond ((string-equal n "CHAR") (ecase role (:a -2) (:b -1)))
          ((string-equal n "UCHAR") 200)
          (t 0))))

;; src/hoist-l0/main.lisp
(defun %l0-mma-int-reference-p (allocations)
  "T when C's element is an integer, so the host reference must be exact integer math."
  (let ((c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
    (and c (%l0-mma-int-elem-p (getf c :elem-type)))))

;; src/hoist-l0/main.lisp
(defun %l0-emit-mma-int-reference (stream allocations)
  "The integer form of %l0-emit-mma-reference: same strided sample, exact comparison, and operands
   recomputed from the fill formula through their own C++ type, so the sign of the reference is the
   sign the host wrote."
  (destructuring-bind (m n k) *mma-test-dims*
    (let* ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
           (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
           (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let* ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base))
               (a-elem (getf a :elem-type)) (b-elem (getf b :elem-type))
               (a-str (crisp-type-to-cpp-type a-elem))
               (b-str (crisp-type-to-cpp-type b-elem))
               (c-str (crisp-type-to-cpp-type (getf c :elem-type))))
          (format stream "~%    // Endeavour 204: exact integer MMA reference C = A.B, STRIDED 64x64 sample~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0; uint64_t mma_checked = 0;~%")
          (format stream "      const uint64_t mma_M = ~dULL, mma_N = ~dULL;~%" m n)
          (format stream "      uint64_t mma_si = (mma_M + 63) / 64; if (mma_si == 0) mma_si = 1;~%")
          (format stream "      uint64_t mma_sj = (mma_N + 63) / 64; if (mma_sj == 0) mma_sj = 1;~%")
          (format stream "      uint64_t mma_c_extent = (mma_M - 1) * ~a_str0 + (mma_N - 1) * ~a_str1 + 1;~%" cb cb)
          (format stream "      ~a* host_c_buf = (~a*)malloc(mma_c_extent * sizeof(~a));~%" c-str c-str c-str)
          (format stream "      if (!host_c_buf) { mma_ok = 0; std::cout << \"  host readback allocation failed\" << std::endl; } else {~%")
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, mma_c_extent * sizeof(~a), nullptr, 0, nullptr);~%" cb c-str)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < mma_M; i += mma_si) for (uint64_t j = 0; j < mma_N; j += mma_sj) {~%")
          (format stream "        ++mma_checked;~%")
          (format stream "        int64_t acc = 0;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += (int64_t)(~a)((int)((i*~a_str0 + kk*~a_str1) % ~dULL) + (~d)) * (int64_t)(~a)((int)((kk*~a_str0 + j*~a_str1) % ~dULL) + (~d));~%"
                  a-str ab ab (%l0-mma-fill-modulus :a) (%l0-mma-int-offset :a a-elem)
                  b-str bb bb (%l0-mma-fill-modulus :b) (%l0-mma-int-offset :b b-elem))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d;   // --mma-scale~%" *mma-scale*))
          (format stream "        int64_t got = (int64_t)host_c_buf[i*~a_str0 + j*~a_str1];~%" cb cb)
          (format stream "        if (got != acc) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf); }~%")
          (format stream "      std::cout << \"  mma reference: \" << mma_checked << \" strided samples, exact\" << std::endl;~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))

;; src/hoist-l0/main.lisp -- an integer C takes the exact reference
(defun %l0-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B, checked on a STRIDED 64x64 sample of C.

   2026-09-12: this used to check only the TOP-LEFT 64x64 corner of C.  That is the same cost as
   a strided sample and blind to every tile it does not reach -- a kernel that wrote only its
   first tile printed MMA_CORRECT.  It mattered more than it looked: on BMG six of the twelve
   section-1 ladder kernels (chap1..chap3, tf32 and bf16) are measured through THIS harness,
   because the reviewed fixture cannot bind SLM tensor arguments.  The strided form mirrors
   benchmarks/matmul/crisp/bench_harness_l0.cpp, which made the same change for the same reason.

   Cost is unchanged in kind: ~64x64 samples x K, well under a second at N=16384.  C is read back
   over its whole extent, so the sample can land anywhere; the operands are still RECOMPUTED from
   the fill formula rather than read (see endeavour 155: a host dereference of USM aborts on the
   BMG/WSL driver).  The final line is still exactly MMA_CORRECT / MMA_WRONG, which is what
   HOIST-EXPECT and matmul.py match; the sample count is printed on the line before it."
  (when (%l0-mma-int-reference-p allocations)
    (%l0-emit-mma-int-reference stream allocations)
    (return-from %l0-emit-mma-reference nil))
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      ;; No log4cl here: crisp-hoist-l0 is a standalone app that does not load it.
      (when (and a b c)
        (let ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic), STRIDED 64x64 sample~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0; uint64_t mma_checked = 0;~%")
          (format stream "      const uint64_t mma_M = ~dULL, mma_N = ~dULL;~%" m n)
          (format stream "      uint64_t mma_si = (mma_M + 63) / 64; if (mma_si == 0) mma_si = 1;~%")
          (format stream "      uint64_t mma_sj = (mma_N + 63) / 64; if (mma_sj == 0) mma_sj = 1;~%")
          ;; The whole extent of C under ITS strides, so any sampled (i, j) is in the buffer
          ;; whether C is row- or column-major.
          (format stream "      uint64_t mma_c_extent = (mma_M - 1) * ~a_str0 + (mma_N - 1) * ~a_str1 + 1;~%" cb cb)
          (format stream "      float* host_c_buf = (float*)malloc(mma_c_extent * sizeof(float));~%")
          (format stream "      if (!host_c_buf) { mma_ok = 0; std::cout << \"  host readback allocation failed\" << std::endl; } else {~%")
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, mma_c_extent * sizeof(float), nullptr, 0, nullptr);~%" cb)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < mma_M; i += mma_si) for (uint64_t j = 0; j < mma_N; j += mma_sj) {~%")
          (format stream "        ++mma_checked;~%")
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += (float)((i*~a_str0 + kk*~a_str1) % ~dULL) * (float)((kk*~a_str0 + j*~a_str1) % ~dULL);~%"
                  ab ab (%l0-mma-fill-modulus :a) bb bb (%l0-mma-fill-modulus :b))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = host_c_buf[i*~a_str0 + j*~a_str1];~%" cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf); }~%")
          (format stream "      std::cout << \"  mma reference: \" << mma_checked << \" strided samples\" << std::endl;~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))

;; src/hoist-l0/main.lisp -- integer operands are filled through %l0-mma-int-offset
(defun %l0-emit-tensor-arg (stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
  "Emit the 3N+3 kernel arguments for a declared tensor parameter.

   Endeavour 166: device memory plus a host staging mirror.  Every fill this function
   emits -- the deterministic --mma-test fill for A/B, the zero for C, the pad-with zero,
   the plain iota -- now writes the MIRROR and is staged to the device before the launch.
   The MMA host reference (%L0-EMIT-MMA-REFERENCE) is unaffected: it already copies C back
   itself and recomputes A/B rather than reading them, so it works against a device pointer
   exactly as it did against a shared one."
  (let* ((rank (or (getf param :rank)
                   (let ((n3 (third param-type)))
                     (if (integerp n3) n3 1))))
         (elem-type (second param-type))
         (align (getf param :align))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
         (host-var (format nil "~a_host" param-name-cpp))
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
                   (when (and tile-shape derive-from
                              (member param-name (if (listp derive-from) derive-from (list derive-from))
                                      :test (lambda (a b) (string-equal (string a) (string b)))))
                     (loop for k from 0 below (min rank (length tile-shape)) do
                       (let* ((tx (nth k tile-shape)) (base (nth k lst)) (padded (* (ceiling base tx) tx)))
                         (setf (nth k lst) padded)))))
                 lst))))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank extents-list)
      (let* ((total-elems (* (first strides) (first extents)))
             (offsets (make-list rank :initial-element 0))
             (elem-bytes (%elem-type-bytes elem-str))
             (byte-size (* total-elems elem-bytes))
             (layout-str (if (member align '(:strided strided)
                                     :test (lambda (a b) (string-equal (string a) (string b))))
                             "compact (strided param, harness uses compact)" "compact"))
             (current-idx arg-index))
        (format stream "~%    // Tensor argument: ~a (rank=~d, ~a, ~d elements, ~a)~%"
          param-name rank elem-str total-elems layout-str)
        (%l0-emit-staged-alloc stream context-var device-var elem-str
                               ptr-var host-var (format nil "~d" total-elems) param-name)
        ;; Initialise data -- into the host mirror.
        (let* ((global-decl (getf dispatch-info :global-size))
               (pad-with (getf (cdr global-decl) :pad-with)))
          (cond
            ;; MMA test: A/B get a deterministic non-uniform fill; C is zeroed.
            ((member mma-role '(:a :b))
             ;; Endeavour 155: a 16-bit float buffer is uint16_t in C++, so a plain cast wrote
             ;; the INTEGER 1..4 as a bit pattern -- which reads back as a SUBNORMAL near 6e-8,
             ;; not as 1..4.  The GPU then multiplied denormal noise while the host reference
             ;; computed with 1..4, so they could never agree.  Encode properly instead.
             (let ((conv (%l0-f16-encoder elem-type)))
               (if conv
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = ~a((float)(_i % ~d));~%"
                     total-elems host-var conv (%l0-mma-fill-modulus mma-role))
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)((int)(_i % ~d) + (~d));~%"
                     total-elems host-var elem-str (%l0-mma-fill-modulus mma-role)
                     (if (%l0-mma-int-elem-p elem-type) (%l0-mma-int-offset mma-role elem-type) 0)))))
            ((eq mma-role :c)
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" host-var total-elems elem-str))
            ((and pad-with (eql pad-with 0))
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" host-var total-elems elem-str))
            (t
             (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%" total-elems host-var elem-str))))
        (format stream "    // Arg ~d: ~a PTR~%" current-idx param-name)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%" current-idx ptr-var)
        (incf current-idx)
        (format stream "    // Arg ~d: ~a BYTE_SIZE = ~d~%" current-idx param-name byte-size)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%" current-idx param-name-cpp)
        (incf current-idx)
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a OFFSET_~d = ~d~%" current-idx param-name k (nth k offsets))
          (format stream "    uint64_t ~a_off~d = ~dULL;~%" param-name-cpp k (nth k offsets))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a STRIDE_~d = ~d~%" current-idx param-name k (nth k strides))
          (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a EXTENT_~d = ~d~%" current-idx param-name k (nth k extents))
          (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (format stream "    // Arg ~d: ~a LENGTH = ~d~%" current-idx param-name total-elems)
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp total-elems)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%" current-idx param-name-cpp)
        (incf current-idx)
        (values current-idx
          (list :name param-name :ptr ptr-var :host host-var
                :size-var (format nil "~d" total-elems)
                :direction param-dir :access (getf param :access)
                ;; Endeavour 155: the host reference needs to know how to READ this buffer.
                :elem-type elem-type
                :mma-role mma-role :base param-name-cpp))))))

;; src/hoist-l0/main.lisp
(defun %l0-print-prefix (elem-type)
  "Unary + for an 8-bit element, so C++ prints a number rather than a raw byte.  Empty otherwise,
   because + does not apply to a struct."
  (if (and elem-type (symbolp elem-type)
           (member (symbol-name elem-type) (quote ("CHAR" "UCHAR")) :test (function string-equal)))
      "+"
      ""))

;; src/hoist-l0/main.lisp -- 8-bit buffers print as numbers
(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.
   Endeavor 150: buffer-print cap raised 100 -> 512 so MMA-sized output tiles are printable
   and can be checked with a HOIST-EXPECT: BUFFER expectation.

   Endeavour 166: the buffer print reads the HOST MIRROR, and copies the device buffer into
   it first.  Printing `X_ptr[i]` would now be a host dereference of device memory -- which
   on Level Zero is not a compile error and not necessarily a crash, so getting this wrong
   would have shown up as wrong NUMBERS in HOIST-EXPECT rather than as a failure that names
   itself."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name))
            (ptr (getf alloc :ptr))
            (host (getf alloc :host))
            (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 512) {~%" size-v)
        (%l0-emit-d2h-readback stream alloc)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a~a[i] << (i == ~a - 1 ? \"\" : \" \");~%"
          (%l0-print-prefix (getf alloc :elem-type)) (or host ptr) size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
    ;; Endeavour 155: was (and *mma-test-dims* (not *mma-bench-iters*)) -- see header.  (--mma-bench
    ;; itself was retired 2026-10-16.)
    (when *mma-test-dims*
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))
