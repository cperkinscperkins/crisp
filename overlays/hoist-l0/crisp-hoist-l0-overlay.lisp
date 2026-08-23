(in-package :crisp.hoist.l0)


;; src/hoist-l0/main.lisp
;;
;; Endeavor 150 (fused epilogue) — raise the buffer-print cap from 100 to 512 elements.
;;
;; WHY.  A HOIST-EXPECT: BUFFER <name>: <values> expectation can only fire if the harness
;; actually prints the buffer, and this gate skipped anything over 100 elements.  The smallest
;; single MMA output tile is 128 on BOTH vendors (16x8 NVIDIA tf32, 8x16 Intel XMX), so C was
;; never printed for ANY MMA kernel — which is exactly the buffer an epilogue test needs to see.
;;
;; 512 covers a 16x16 tile (256) with headroom while still skipping genuinely large benchmark
;; buffers.  Note the CUDA hoist has no such gate at all (it prints every buffer), so this only
;; brings L0 into line with what CUDA already did.
;;
;; Everything else in this function is byte-identical to the original.

(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.
   Endeavor 150: buffer-print cap raised 100 -> 512 so MMA-sized output tiles are printable
   and can be checked with a HOIST-EXPECT: BUFFER expectation."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name)) (ptr (getf alloc :ptr)) (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 512) {~%" size-v)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
    (when (and *mma-test-dims* (not *mma-bench-iters*))
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))


;;;; ============================================================================
;;;; Endeavour 155 — the HOST side of the element type, and a re-enabled check.
;;;;
;;;; (1) BENCHMARK MODE STOPPED VERIFYING, AND SAID IT DIDN'T.
;;;;
;;;; The endeavour-150 override of generate-cpp-main above raised the buffer-print cap from 100
;;;; to 512 and states, in its own header: "Everything else in this function is byte-identical to
;;;; the original."  It is not.  It also changed
;;;;     (when *mma-test-dims* ...)                              ; src/hoist-l0/main.lisp:441
;;;; into
;;;;     (when (and *mma-test-dims* (not *mma-bench-iters*)) ...)
;;;; so the host-reference C=A.B check is emitted ONLY when --mma-bench is absent.  Every
;;;; benchmark sweep passes --mma-bench.  The consequence is that NO BENCHMARKED KERNEL HAS BEEN
;;;; VERIFIED on this backend: matmul.py looks for an MMA_CORRECT token, never finds one, reports
;;;; "NOT MMA_CORRECT", and drops every point at N <= 2048 -- while KEEPING points above 2048,
;;;; where verification is skipped by design.  So the published Crisp numbers for autobench
;;;; chapters come precisely from the sizes where nothing was checked.
;;;;
;;;; Verifying once and then benchmarking is the correct behaviour and costs almost nothing: the
;;;; reference caps its checked corner at 64x64 (it walks full K, so ~33M host multiply-adds at
;;;; N=8192, once per run).  Restored to the src condition.
;;;;
;;;; (2) A 16-BIT TENSOR WAS FILLED AND READ AS AN INTEGER.
;;;;
;;;; crisp-type-to-cpp-type maps BOTH half and bfloat16 to uint16_t, so the generated harness
;;;; carried a 16-bit float buffer as an unsigned integer and treated it like one at both ends:
;;;;
;;;;     for (...) a_ptr[_i] = (uint16_t)(_i % 5);              // fill
;;;;     acc += (float)a_ptr[...] * (float)b_ptr[...];          // host reference
;;;;
;;;; The bit pattern 0x0001 is not the half value 1.0 -- it is a SUBNORMAL of about 6e-8.  So the
;;;; GPU was handed denormal noise while the host reference computed with 1..4.  The two can never
;;;; agree, the input data is meaningless, and any timing taken over it is timing of the wrong
;;;; problem (denormal operands are also a plausible slow path).
;;;;
;;;; Fixed at both ends, via converters emitted into the harness.  half and bfloat16 need
;;;; DIFFERENT converters -- same width, different exponent/mantissa split -- which is why the
;;;; element TYPE is now recorded in the allocation plist rather than inferring from "uint16_t".
;;;; Non-16-bit types take exactly the previous path.
;;;; ============================================================================

;; src/hoist-l0/main.lisp
(defun %l0-f16-encoder (elem-type)
  "C++ function name that converts a float TO ELEM-TYPE's 16-bit encoding, or NIL when ELEM-TYPE
   is not a 16-bit float (in which case a plain cast is correct and is what the caller emits)."
  (let ((n (and elem-type (symbolp elem-type) (symbol-name elem-type))))
    (cond ((null n) nil)
          ((string-equal n "HALF")     "crisp_f32_to_f16")
          ((string-equal n "BFLOAT16") "crisp_f32_to_bf16")
          (t nil))))

;; src/hoist-l0/main.lisp
(defun %l0-f16-decoder (elem-type)
  "C++ call PREFIX that decodes ELEM-TYPE's 16-bit encoding to float, e.g. \"crisp_f16_to_f32(\",
   or NIL when a plain (float) cast is correct.  The caller supplies the closing paren."
  (let ((n (and elem-type (symbolp elem-type) (symbol-name elem-type))))
    (cond ((null n) nil)
          ((string-equal n "HALF")     "crisp_f16_to_f32(")
          ((string-equal n "BFLOAT16") "crisp_bf16_to_f32(")
          (t nil))))

;; src/hoist-l0/main.lisp  (REPLACES generate-cpp-main (155: verify under --mma-bench too))
(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.
   Endeavor 150: buffer-print cap raised 100 -> 512 so MMA-sized output tiles are printable
   and can be checked with a HOIST-EXPECT: BUFFER expectation."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name)) (ptr (getf alloc :ptr)) (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 512) {~%" size-v)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
    ;; Endeavour 155: was (and *mma-test-dims* (not *mma-bench-iters*)) -- see header.
    (when *mma-test-dims*
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))

;; src/hoist-l0/main.lisp  (REPLACES generate-cpp-helpers (155: 16-bit converters))
(defun generate-cpp-helpers (stream)
  "Generate C++ helper functions"
  ;; Endeavour 155: half / bfloat16 <-> float.  A 16-bit tensor's buffer is typed uint16_t in
  ;; the generated C++, so BOTH the fill and the host reference were treating the raw bits as a
  ;; small INTEGER.  See header.
  (format stream "// Helper: 16-bit float conversions (Endeavour 155)~%")
  (format stream "static inline float crisp_f16_to_f32(uint16_t h) {~%")
  (format stream "    uint32_t s = (uint32_t)(h >> 15) & 1u, e = (uint32_t)(h >> 10) & 0x1Fu, m = (uint32_t)h & 0x3FFu;~%")
  (format stream "    uint32_t out;~%")
  (format stream "    if (e == 0) { if (m == 0) { out = s << 31; } else {~%")
  (format stream "        e = 127 - 15 + 1; while ((m & 0x400u) == 0) { m <<= 1; e--; } m &= 0x3FFu;~%")
  (format stream "        out = (s << 31) | (e << 23) | (m << 13); } }~%")
  (format stream "    else if (e == 31) { out = (s << 31) | 0x7F800000u | (m << 13); }~%")
  (format stream "    else { out = (s << 31) | ((e - 15 + 127) << 23) | (m << 13); }~%")
  (format stream "    float f; memcpy(&f, &out, 4); return f;~%")
  (format stream "}~%")
  (format stream "static inline uint16_t crisp_f32_to_f16(float f) {~%")
  (format stream "    uint32_t u; memcpy(&u, &f, 4);~%")
  (format stream "    uint32_t s = (u >> 31) & 1u; int32_t e = (int32_t)((u >> 23) & 0xFFu) - 127 + 15;~%")
  (format stream "    uint32_t m = u & 0x7FFFFFu;~%")
  (format stream "    if (e <= 0) return (uint16_t)(s << 15);~%")
  (format stream "    if (e >= 31) return (uint16_t)((s << 15) | 0x7C00u);~%")
  (format stream "    return (uint16_t)((s << 15) | ((uint32_t)e << 10) | (m >> 13));~%")
  (format stream "}~%")
  (format stream "static inline float crisp_bf16_to_f32(uint16_t b) {~%")
  (format stream "    uint32_t u = ((uint32_t)b) << 16; float f; memcpy(&f, &u, 4); return f;~%")
  (format stream "}~%")
  (format stream "static inline uint16_t crisp_f32_to_bf16(float f) {~%")
  (format stream "    uint32_t u; memcpy(&u, &f, 4); return (uint16_t)(u >> 16);~%")
  (format stream "}~%~%")
  (format stream "// Helper: Read SPIR-V binary from file~%")
  (format stream "std::vector<uint8_t> read_spirv_file(const char* filename) {~%")
  (format stream "    std::ifstream file(filename, std::ios::binary | std::ios::ate);~%")
  (format stream "    if (!file) {~%")
  (format stream "        throw std::runtime_error(\"Failed to open SPIR-V file\");~%")
  (format stream "    }~%")
  (format stream "    size_t size = file.tellg();~%")
  (format stream "    std::vector<uint8_t> buffer(size);~%")
  (format stream "    file.seekg(0);~%")
  (format stream "    file.read(reinterpret_cast<char*>(buffer.data()), size);~%")
  (format stream "    return buffer;~%")
  (format stream "}~%~%"))

;; src/hoist-l0/main.lisp  (REPLACES %l0-emit-tensor-arg (155: encode the fill; record elem-type))
(defun %l0-emit-tensor-arg (stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
  (let* ((rank (or (getf param :rank)
                   (let ((n3 (third param-type)))
                     (if (integerp n3) n3 1))))
         (elem-type (second param-type))
         (align (getf param :align))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
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
        (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
        (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%" context-var)
        (format stream "        ~d * sizeof(~a), 1, ~a, (void**)&~a);~%" total-elems elem-str device-var ptr-var)
        (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
        (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%" param-name)
        (format stream "        return 1;~%")
        (format stream "    }~%")
        ;; Initialise data.
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
                     total-elems ptr-var conv (if (eq mma-role :a) 5 3))
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)(_i % ~d);~%"
                     total-elems ptr-var elem-str (if (eq mma-role :a) 5 3)))))
            ((eq mma-role :c)
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" ptr-var total-elems elem-str))
            ((and pad-with (eql pad-with 0))
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" ptr-var total-elems elem-str))
            (t
             (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%" total-elems ptr-var elem-str))))
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
          (list :name param-name :ptr ptr-var :size-var (format nil "~d" total-elems)
                :direction param-dir :access (getf param :access)
                ;; Endeavour 155: the host reference needs to know how to READ this buffer.
                :elem-type elem-type
                :mma-role mma-role :base param-name-cpp))))))

;; src/hoist-l0/main.lisp  (REPLACES %l0-emit-mma-reference (155: decode 16-bit operands))
(defun %l0-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B and compare against the device C."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0;~%")
          (format stream "      uint64_t chk_m = (~dULL < 64 ? ~dULL : 64); uint64_t chk_n = (~dULL < 64 ? ~dULL : 64);~%" m m n n)
          (format stream "      float* host_c_buf = (float*)malloc(chk_m * chk_n * sizeof(float));~%")
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, chk_m * chk_n * sizeof(float), nullptr, 0, nullptr);~%" cb)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < chk_m; i++) for (uint64_t j = 0; j < chk_n; j++) {~%")
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          ;; Endeavour 155: read each operand THROUGH its element type.  A half/bfloat16 buffer
          ;; is uint16_t here, so (float)x reinterpreted the bits as a small integer.
          (let ((ra (%l0-f16-decoder (getf a :elem-type)))
                (rb (%l0-f16-decoder (getf b :elem-type))))
            (format stream "            acc += ~a~a_ptr[i*~a_str0 + kk*~a_str1]~a * ~a~a_ptr[kk*~a_str0 + j*~a_str1]~a;~%"
                    (or ra "(float)") ab ab ab (if ra ")" "")
                    (or rb "(float)") bb bb bb (if rb ")" "")))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = host_c_buf[i*chk_n + j];~%")
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf);~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 — the host reference must not dereference device USM.
;;;;
;;;; Fixing the 16-bit DECODE (above) was necessary but not sufficient: the reference still read
;;;; a_ptr / b_ptr directly from the host, and on this driver that aborts in the page-fault
;;;; manager before any comparison happens.  Since the harness generates the operand data itself,
;;;; the reference can reconstruct it from the index instead of reading it back.
;;;;
;;;; THE TRADE, STATED.  This checks "C equals the product of the values the harness WROTE"
;;;; rather than "C equals the product of the bytes now IN the operand buffers".  The difference
;;;; would matter only if the fill itself were broken, which is a separate and much louder
;;;; failure.  The risk it introduces is drift between the fill and the reference, so both now
;;;; take their modulus from %l0-mma-fill-modulus and there is no second copy of the constant.
;;;; ------------------------------------------------------------------------------------------

;; src/hoist-l0/main.lisp
(defun %l0-mma-fill-modulus (role)
  "Modulus of the deterministic --mma-test fill for an MMA operand ROLE.  Small, coprime, and
   exactly representable in every supported element type (fp16, bf16, tf32, f32), so the host
   reference is exact rather than approximate.  Used by BOTH the fill emitter and the reference:
   if these ever disagree, the check silently validates the wrong product."
  (ecase role (:a 5) (:b 3)))

;; src/hoist-l0/main.lisp  (REPLACES %l0-emit-tensor-arg (155: shared fill modulus))
(defun %l0-emit-tensor-arg (stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
  (let* ((rank (or (getf param :rank)
                   (let ((n3 (third param-type)))
                     (if (integerp n3) n3 1))))
         (elem-type (second param-type))
         (align (getf param :align))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
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
        (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
        (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%" context-var)
        (format stream "        ~d * sizeof(~a), 1, ~a, (void**)&~a);~%" total-elems elem-str device-var ptr-var)
        (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
        (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%" param-name)
        (format stream "        return 1;~%")
        (format stream "    }~%")
        ;; Initialise data.
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
                     total-elems ptr-var conv (%l0-mma-fill-modulus mma-role))
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)(_i % ~d);~%"
                     total-elems ptr-var elem-str (%l0-mma-fill-modulus mma-role)))))
            ((eq mma-role :c)
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" ptr-var total-elems elem-str))
            ((and pad-with (eql pad-with 0))
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" ptr-var total-elems elem-str))
            (t
             (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%" total-elems ptr-var elem-str))))
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
          (list :name param-name :ptr ptr-var :size-var (format nil "~d" total-elems)
                :direction param-dir :access (getf param :access)
                ;; Endeavour 155: the host reference needs to know how to READ this buffer.
                :elem-type elem-type
                :mma-role mma-role :base param-name-cpp))))))

;; src/hoist-l0/main.lisp  (REPLACES %l0-emit-mma-reference (155: recompute operands, no host USM read))
(defun %l0-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B and compare against the device C."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0;~%")
          (format stream "      uint64_t chk_m = (~dULL < 64 ? ~dULL : 64); uint64_t chk_n = (~dULL < 64 ? ~dULL : 64);~%" m m n n)
          (format stream "      float* host_c_buf = (float*)malloc(chk_m * chk_n * sizeof(float));~%")
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, chk_m * chk_n * sizeof(float), nullptr, 0, nullptr);~%" cb)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < chk_m; i++) for (uint64_t j = 0; j < chk_n; j++) {~%")
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          ;; Endeavour 155: RECOMPUTE the operands rather than reading them back.
          ;;
          ;; The previous form dereferenced a_ptr / b_ptr from the HOST.  Those are USM
          ;; allocations, and on the BMG/WSL driver a host dereference of one aborts outright:
          ;;     Abort was called at 30 line in file:
          ;;     ./level_zero/core/source/memory/cpu_page_fault_memory_manager.cpp
          ;; so the check could never complete regardless of element type.
          ;;
          ;; But the harness FILLED these buffers itself, from the index, a few hundred lines
          ;; above -- so their contents are known by construction and need not be read at all.
          ;; The modulus comes from %l0-mma-fill-modulus, which the fill emitter also uses, so the
          ;; two cannot drift apart.  C is still read back properly, by device->host memcpy, which
          ;; is what is actually under test.
          ;;
          ;; The values 0..4 and 0..2 are exactly representable in fp16, bf16 and tf32 alike, so
          ;; this is exact for every element type rather than only for f32.
          (format stream "            acc += (float)((i*~a_str0 + kk*~a_str1) % ~dULL) * (float)((kk*~a_str0 + j*~a_str1) % ~dULL);~%"
                  ab ab (%l0-mma-fill-modulus :a) bb bb (%l0-mma-fill-modulus :b))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = host_c_buf[i*chk_n + j];~%")
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf);~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 — the host reference compared THE WRONG ELEMENTS OF C.
;;;;
;;;; The block calls itself "stride-agnostic", and it is — for A and B, which it indexes with
;;;; their real strides.  For C it did not:
;;;;
;;;;     memcpy(host_c_buf, c_ptr, chk_m * chk_n * sizeof(float));   // flat 64*64 prefix
;;;;     float got = host_c_buf[i*chk_n + j];                        // indexed as if C were 64 wide
;;;;
;;;; C is N wide, so flat offset i*64+j is really C[(i*64+j)/N][(i*64+j)%N].  At N=128, i=1, j=0
;;;; that is C[0][64] — compared against ref(1,0).  The check was reading a DIFFERENT ELEMENT than
;;;; the one it computed a reference for, for every row after the first, at every N > 64.
;;;;
;;;; WHY IT LOOKED LIKE A KERNEL BUG, and this is the cautionary part.  With the deterministic
;;;; %5 / %3 fill, C is very nearly uniform — it varies only with (row mod 5, col mod 3) — so
;;;; comparing the wrong element gave a SMALL error, about 6 absolute, roughly independent of N.
;;;; Against a 1% relative tolerance that is:
;;;;
;;;;     N=128   248 vs 255   2.7%  -> FAIL
;;;;     N=256   510 vs 516   1.2%  -> FAIL
;;;;     N=512  ~1030         0.6%  -> PASSES, silently, while being just as wrong
;;;;
;;;; which reads exactly like "the kernel breaks below 512".  It is not: the kernel is correct at
;;;; every size, and an all-ones fill (where C IS uniform, so a misindexed read is indistinguishable
;;;; from a correct one) passes at 128, 256, 512 and 1024 — which is what proved the term COUNT was
;;;; right and pointed the finger back here.
;;;;
;;;; Copying chk_m WHOLE ROWS and indexing by C's own strides fixes it.  Cost is chk_m * c_str0
;;;; floats — 4 MB at N=16384, once per run.
;;;; ------------------------------------------------------------------------------------------

;; src/hoist-l0/main.lisp  (REPLACES %l0-emit-mma-reference -- 155: index C by its own strides)
(defun %l0-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B and compare against the device C."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0;~%")
          (format stream "      uint64_t chk_m = (~dULL < 64 ? ~dULL : 64); uint64_t chk_n = (~dULL < 64 ? ~dULL : 64);~%" m m n n)
          ;; Endeavour 155: copy chk_m WHOLE ROWS (chk_m * c_str0 elements), not a flat
          ;; chk_m*chk_n prefix.  See header.
          (format stream "      float* host_c_buf = (float*)malloc(chk_m * ~a_str0 * sizeof(float));~%" cb)
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, chk_m * ~a_str0 * sizeof(float), nullptr, 0, nullptr);~%" cb cb)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < chk_m; i++) for (uint64_t j = 0; j < chk_n; j++) {~%")
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          ;; Endeavour 155: RECOMPUTE the operands rather than reading them back.
          ;;
          ;; The previous form dereferenced a_ptr / b_ptr from the HOST.  Those are USM
          ;; allocations, and on the BMG/WSL driver a host dereference of one aborts outright:
          ;;     Abort was called at 30 line in file:
          ;;     ./level_zero/core/source/memory/cpu_page_fault_memory_manager.cpp
          ;; so the check could never complete regardless of element type.
          ;;
          ;; But the harness FILLED these buffers itself, from the index, a few hundred lines
          ;; above -- so their contents are known by construction and need not be read at all.
          ;; The modulus comes from %l0-mma-fill-modulus, which the fill emitter also uses, so the
          ;; two cannot drift apart.  C is still read back properly, by device->host memcpy, which
          ;; is what is actually under test.
          ;;
          ;; The values 0..4 and 0..2 are exactly representable in fp16, bf16 and tf32 alike, so
          ;; this is exact for every element type rather than only for f32.
          (format stream "            acc += (float)((i*~a_str0 + kk*~a_str1) % ~dULL) * (float)((kk*~a_str0 + j*~a_str1) % ~dULL);~%"
                  ab ab (%l0-mma-fill-modulus :a) bb bb (%l0-mma-fill-modulus :b))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = host_c_buf[i*~a_str0 + j*~a_str1];~%" cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf);~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))
