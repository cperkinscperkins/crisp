(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed

;;; ===================================================================
;;; Endeavor 134 — MMA on-metal TEST mode.
;;;
;;; `crisp-hoist-l0 --mma-test=M,N,K <metacrisp>` regenerates the launcher as a
;;; correctness test for a matmul kernel C[M×N] = A[M×K]·B[K×N]:
;;;   - the declared A/B/C tensor buffers are sized by ROLE (first input = A = M×K,
;;;     second input = B = K×N, &out = C = M×N) instead of the default 4×4;
;;;   - A/B get a deterministic non-uniform fill;
;;;   - after launch, a STRIDE-AGNOSTIC host reference C = A·B is computed and compared,
;;;     printing MMA_CORRECT / MMA_WRONG.
;;; All other args (implicit SLM/scratch tuples, launch config) are emitted by the stock
;;; generator unchanged — so this works for SLM-staged kernels (the Chapters) too.
;;; ===================================================================

(defvar *mma-test-dims* nil "(M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.")
(defvar *mma-input-counter* 0 "Per-kernel input-tensor counter for A(0)/B(1) role assignment.")

(defun %mma-parse-args (args)
  "Return (values metacrisp-path (M N K)-or-NIL), extracting a --mma-test=M,N,K flag."
  (let ((dims nil) (path nil))
    (dolist (a args)
      (if (and (>= (length a) 11) (string= (subseq a 0 11) "--mma-test="))
          (setf dims (mapcar #'parse-integer (uiop:split-string (subseq a 11) :separator ",")))
          (unless path (setf path a))))
    (values path dims)))

(defun %mma-out-dir-p (dir)
  "T if the param direction is an output (&out)."
  (and dir (search "out" (string-downcase (string dir)))))

(defun main ()
  "Entry point for crisp-hoist-l0.exe.  Endeavor 134: accepts --mma-test=M,N,K."
  (handler-case
      (let ((args (uiop:command-line-arguments)))
        (format t "Crisp Hoist L0 - Level Zero C++ Launcher Generator~%")
        (format t "Version: 0.3.0~%~%")
        (unless args
          (format t "Usage: crisp-hoist-l0 [--mma-test=M,N,K] <path-to-metacrisp-file>~%")
          (uiop:quit 1))
        (multiple-value-bind (metacrisp-path dims) (%mma-parse-args args)
          (setf *mma-test-dims* dims)
          (unless (and metacrisp-path (probe-file metacrisp-path))
            (format t "Error: File not found: ~a~%" metacrisp-path)
            (uiop:quit 1))
          (when dims (format t "MMA test mode: M=~d N=~d K=~d~%" (first dims) (second dims) (third dims)))
          (format t "Processing: ~a~%" metacrisp-path)
          (generate-l0-launcher metacrisp-path)
          (format t "Done!~%")
          (uiop:quit 0)))
    (error (e)
      (format t "Error: ~a~%" e)
      (uiop:quit 1))))

;;; src/hoist-l0/main.lisp — %l0-emit-tensor-arg: role-based sizing + fill under MMA test.
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
             (elem-bytes (if (or (string-equal elem-str "double")
                                 (string-equal elem-str "int64_t")
                                 (string-equal elem-str "uint64_t")) 8 4))
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
             (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)(_i % ~d);~%"
               total-elems ptr-var elem-str (if (eq mma-role :a) 5 3)))
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
                :mma-role mma-role :base param-name-cpp))))))

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
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += ~a_ptr[i*~a_str0 + kk*~a_str1] * ~a_ptr[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb)
          (format stream "        float got = ~a_ptr[i*~a_str0 + j*~a_str1];~%" cb cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))

;;; src/hoist-l0/main.lisp — generate-cpp-main: reset the input counter + emit the reference.
(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name)) (ptr (getf alloc :ptr)) (size-v (getf alloc :size-var)))
        (format stream "    std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "    for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "        std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "    }~%")
        (format stream "    std::cout << std::endl;~%")))
    (when *mma-test-dims*
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))

;;; ===================================================================
;;; Endeavor 134 — 2-D SLM scratch dims for the L0 hoist (port of the CUDA
;;; %cuda-scratch-dims fix).  The stock %l0-emit-local-scratch-tensor-arg only
;;; accepted a SCALAR :size-expr (square tile).  An SLM-staged tiled matmul uses
;;; non-square tiles like (make-scratch-matrix float (8 16)), whose :size-expr is a
;;; RANK-list.  This mirrors the CUDA emitter so the L0 Chapter-proof matmul hoists.
;;; ===================================================================

;;; src/hoist-l0/main.lisp — %l0-scratch-dims
(defun %l0-scratch-dims (size-expr rank param-name)
  "Per-dimension extents for a scratch tensor.  :size-expr may be a scalar (a SQUARE
   tensor: all RANK dims equal it) or a LIST of RANK integers (a non-square tensor,
   e.g. make-scratch-matrix float (8 16))."
  (cond
    ((integerp size-expr) (make-list rank :initial-element size-expr))
    ((and (listp size-expr) (= (length size-expr) rank) (every #'integerp size-expr))
     size-expr)
    (t (error "Scratch tensor ~a: :size-expr ~a is neither an integer nor a list of ~d integers."
              param-name size-expr rank))))

;;; src/hoist-l0/main.lisp — %l0-emit-local-scratch-tensor-arg: accept 2-D (rank-list) dims.
(defun %l0-emit-local-scratch-tensor-arg (stream param param-name param-type arg-index)
  (let* ((rank (let ((n3 (third param-type)))
                 (if (integerp n3) n3 1)))
         (size-expr (getf param :size-expr))
         (elem-type (second param-type))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (elem-bytes (if (or (string-equal elem-str "double")
                             (string-equal elem-str "int64_t")
                             (string-equal elem-str "uint64_t")) 8 4))
         (param-name-cpp (substitute #\_ #\- param-name))
         (dims (%l0-scratch-dims size-expr rank param-name)))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank dims)
      (let* ((length (reduce #'* dims))
             (bytesize (* length elem-bytes))
             (current-idx arg-index))
        (format stream "~%    // LOCAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes)~%"
          param-name rank elem-str length bytesize)
        ;; Arg N: local memory allocation — nullptr + bytesize
        (format stream "    // Arg ~d: local ptr (~d bytes of workgroup-local memory)~%"
          current-idx bytesize)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~dULL, nullptr);~%"
          current-idx bytesize)
        (incf current-idx)
        ;; Arg N+1: byte-size
        (format stream "    // Arg ~d: byte-size = ~d~%" current-idx bytesize)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
          current-idx param-name-cpp)
        (incf current-idx)
        ;; Args N+2 .. N+1+rank: offsets (all zero)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: offset[~d] = 0~%" current-idx k)
                (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Args N+2+rank .. N+1+2*rank: strides (compact element strides)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: stride[~d] = ~d (elements, compact)~%"
                  current-idx k (nth k strides))
                (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Args N+2+2*rank .. N+1+3*rank: extents
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: extent[~d] = ~d~%" current-idx k (nth k extents))
                (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Last arg: length
        (format stream "    // Arg ~d: length = ~d~%" current-idx length)
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
          current-idx param-name-cpp)
        (incf current-idx)
        current-idx))))
