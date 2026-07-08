;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for CUDA hoist improvements.
;;;; Applied via late binding - last definition wins.

(in-package :crisp.hoist.cuda)

;;; ===================================================================
;;; Endeavor 134 — MMA on-metal TEST mode (CUDA/PTX twin of the L0 path).
;;;
;;; `crisp-hoist-cuda --mma-test=M,N,K <metacrisp>` regenerates the launcher as a
;;; correctness test for a matmul kernel C[M×N] = A[M×K]·B[K×N]:
;;;   - the declared A/B/C tensor buffers are sized by ROLE (first input = A = M×K,
;;;     second input = B = K×N, &out = C = M×N) instead of the default 4×4;
;;;   - A/B get a deterministic non-uniform fill;
;;;   - after launch, A/B/C are copied back to the host and a STRIDE-AGNOSTIC host
;;;     reference C = A·B is computed and compared, printing MMA_CORRECT / MMA_WRONG.
;;; All other args (implicit SLM/scratch tuples, launch config) are emitted by the stock
;;; generator unchanged — so this works for SLM-staged kernels (the Chapters) too.
;;;
;;; NVIDIA B is :col-major, but the reference is stride-agnostic — it reads whatever
;;; a_str/b_str the hoist emitted (the SAME strides the kernel was compiled against),
;;; so the layout is handled automatically.
;;; ===================================================================

(defvar *mma-test-dims* nil "(M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.")
(defvar *mma-input-counter* 0 "Per-kernel input-tensor counter for A(0)/B(1) role assignment.")
(defvar *mma-scale* 1 "Reference scale factor (--mma-scale=S): expected C = S·(A·B).  Default 1.
   Used by kernels that fire the MMA more than once per fragment (e.g. accum-op body).")

(defun %mma-parse-args (args)
  "Return (values metacrisp-path (M N K)-or-NIL scale), extracting --mma-test=M,N,K and an
   optional --mma-scale=S flag."
  (let ((dims nil) (path nil) (scale 1))
    (dolist (a args)
      (cond
        ((and (>= (length a) 11) (string= (subseq a 0 11) "--mma-test="))
         (setf dims (mapcar #'parse-integer (uiop:split-string (subseq a 11) :separator ","))))
        ((and (>= (length a) 12) (string= (subseq a 0 12) "--mma-scale="))
         (setf scale (parse-integer (subseq a 12))))
        (t (unless path (setf path a)))))
    (values path dims scale)))

(defun %mma-out-dir-p (dir)
  "T if the param direction is an output (&out)."
  (and dir (search "out" (string-downcase (string dir)))))

(defun main ()
  "Entry point for crisp-hoist-cuda.exe.  Endeavor 134: accepts --mma-test=M,N,K."
  (handler-case
      (let ((args (uiop:command-line-arguments)))
        (format t "Crisp Hoist CUDA - CUDA Driver API C++ Launcher Generator~%")
        (format t "Version: 0.1.0~%~%")
        (unless args
          (format t "Usage: crisp-hoist-cuda [--mma-test=M,N,K] <path-to-metacrisp-file>~%")
          (uiop:quit 1))
        (multiple-value-bind (metacrisp-path dims scale) (%mma-parse-args args)
          (setf *mma-test-dims* dims)
          (setf *mma-scale* scale)
          (setf *mma-input-counter* 0)     ; reset role assignment for this run
          (unless (and metacrisp-path (probe-file metacrisp-path))
            (format t "Error: File not found: ~a~%" metacrisp-path)
            (uiop:quit 1))
          (when dims (format t "MMA test mode: M=~d N=~d K=~d~%" (first dims) (second dims) (third dims)))
          (format t "Processing: ~a~%" metacrisp-path)
          (generate-cuda-launcher metacrisp-path)
          (format t "Done!~%")
          (uiop:quit 0)))
    (error (e)
      (format t "Error: ~a~%" e)
      (uiop:quit 1))))

;;; src/hoist-cuda/main.lisp — %cuda-emit-tensor-arg: role-based sizing + fill under MMA test.
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
      (let* ((total-elems (* (first strides) (first extents)))
             (elem-bytes  (if (or (string-equal elem-str "double")
                                  (string-equal elem-str "int64_t")
                                  (string-equal elem-str "uint64_t")) 8 4))
             (byte-size   (* total-elems elem-bytes)))
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
           (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)(_i % ~d);~%"
                   total-elems elem-str (if (eq mma-role :a) 5 3)))
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

(defun %cuda-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B (copy A/B/C back to host, compare)."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let ((ab (getf a :base)) (ac (getf a :count))
              (bb (getf b :base)) (bc (getf b :count))
              (cb (getf c :base)) (cc (getf c :count)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    {~%")
          (format stream "      float* ~a_h = new float[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(float)));~%" ab ac ab ab ac)
          (format stream "      float* ~a_h = new float[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(float)));~%" bb bc bb bb bc)
          (format stream "      float* ~a_h = new float[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(float)));~%" cb cc cb cb cc)
          (format stream "      int mma_ok = 1; int mma_bad = 0;~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb)
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = ~a_h[i*~a_str0 + j*~a_str1];~%" cb cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl;~%")
          (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%" ab bb cb)
          (format stream "    }~%"))))))

;;; src/hoist-cuda/main.lisp — emit-readback: after the buffer print, emit the MMA reference.
(defun emit-readback (stream allocations)
  "Emit cuMemcpyDtoH and print buffer contents.  Endeavor 134: appends host-reference C=A·B."
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
        (format stream "            std::cout << h[i] << (i == (size_t)~a - 1 ? \"\" : \" \");~%" n)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "        delete[] h;~%")
        (format stream "    }~%"))))
  (when *mma-test-dims*
    (%cuda-emit-mma-reference stream allocations))
  (format stream "~%"))
