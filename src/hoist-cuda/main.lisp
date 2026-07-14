(in-package :crisp.hoist.cuda)

;;; -----------------------------------------------------------------------
;;; CUDA Driver API hoist — generates a self-contained C++ launcher for
;;; Crisp-compiled PTX kernels.  Parallel to the L0 hoist
;;; (src/hoist-l0/main.lisp) with CUDA Driver API equivalents.
;;;
;;; Usage:  crisp-hoist-cuda.exe <path-to-metacrisp-file>
;;; Output: {kernel}_CUDA.cu
;;;
;;; Compile the output: nvcc -o runner {kernel}_CUDA.cu -lcuda
;;; (links the CUDA Driver API; -lcuda NOT -lcudart)
;;; -----------------------------------------------------------------------



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

;;; -----------------------------------------------------------------------
;;; Struct support (mirrors L0 hoist)
;;; -----------------------------------------------------------------------

(defvar *hoist-current-structs* nil
  "Dynamic variable: list of (def-struct NAME ...) forms from the current
   metacrisp :structs section.")

(defun %find-struct-def (name)
  "Find (def-struct NAME ...) in *hoist-current-structs*."
  (find name *hoist-current-structs*
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (first f))
                     (string-equal (symbol-name (first f)) "DEF-STRUCT")
                     (symbolp (second f))
                     (string-equal (symbol-name n) (symbol-name (second f)))))))

(defun struct-type-p (type)
  "Returns T if TYPE names a def-struct in *hoist-current-structs*."
  (let ((base (cond ((symbolp type) type)
                    ((and (consp type) (symbolp (first type))) (first type))
                    (t nil))))
    (and base (not (null (%find-struct-def base))))))

(defun %struct-base-type (param-type)
  "Extract the base struct name from PARAM-TYPE."
  (if (symbolp param-type) param-type (first param-type)))

(defun %array-type-p (type)
  "Returns T if TYPE is an (array T N) form."
  (and (consp type)
       (symbolp (first type))
       (string-equal (symbol-name (first type)) "ARRAY")))

(defun %array-element-type (type) (second type))
(defun %array-size (type) (third type))

(defun %struct-emit-fields (stream var-path members aliases)
  "Recursively emit C++ field assignments for a struct variable."
  (dolist (member members)
    (let* ((field-name     (first member))
           (field-type-raw (second member))
           (field-name-cpp (format-cpp-identifier field-name))
           (field-path     (format nil "~a.~a" var-path field-name-cpp))
           (field-type     (resolve-type-alias field-type-raw aliases)))
      (cond
       ((%array-type-p field-type)
        (let* ((elem-type (%array-element-type field-type))
               (arr-size  (%array-size field-type))
               (elem-str  (crisp-type-to-cpp-type elem-type)))
          (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                  arr-size field-path elem-str)))
       ((struct-type-p field-type)
        (let* ((nested-def     (%find-struct-def field-type))
               (nested-members (cddr nested-def)))
          (%struct-emit-fields stream field-path nested-members aliases)))
       (t
        (let* ((cpp-type (crisp-type-to-cpp-type field-type))
               (init-val (cond ((string= cpp-type "float")  "1.0f")
                               ((string= cpp-type "double") "1.0")
                               (t "1"))))
          (format stream "    ~a = ~a;~%" field-path init-val)))))))


;;; -----------------------------------------------------------------------
;;; Record type helpers (mirrors L0 hoist)
;;; -----------------------------------------------------------------------

(defun record-base-type (type)
  "Extract the base record type symbol."
  (if (symbolp type) type (first type)))

(defun find-record-def (type records)
  "Find the def-record entry matching TYPE in RECORDS."
  (let ((base (record-base-type type)))
    (find base records
          :key #'second
          :test (lambda (a b) (string-equal (symbol-name a) (symbol-name b))))))

(defun record-type-p (type records)
  "Returns true if TYPE refers to a def-record in RECORDS."
  (and (not (cell-type-p type))
       (not (null (find-record-def type records)))))


;;; -----------------------------------------------------------------------
;;; Tensor helpers (mirrors L0 hoist)
;;; -----------------------------------------------------------------------

(defun tensor-type-p (param-type)
  "Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier."
  (and (consp param-type)
       (symbolp (first param-type))
       (member (symbol-name (first param-type))
               '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))

(defun %tensor-compact-extents-strides (n extents-list)
  "Returns (values extents strides) for a compact N-dim tensor.
   Strides are in elements; innermost stride = 1."
  (let* ((extents (copy-list extents-list))
         (strides (make-list n :initial-element 1)))
    (loop for k from (- n 2) downto 0 do
            (setf (nth k strides) (* (nth (1+ k) strides) (nth (1+ k) extents))))
    (values extents strides)))


;;; -----------------------------------------------------------------------
;;; Device vector ostream operators for CUDA
;;;
;;; CUDA's <cuda.h> already defines ushort2, float4, etc. via vector_types.h.
;;; We must NOT re-declare the struct — only add the operator<< for output.
;;; -----------------------------------------------------------------------

(defun emit-cuda-dvec-ostream-operators (stream dvec-types)
  "Emit operator<< free functions for device vector types.
   Unlike the L0 hoist, does NOT emit struct definitions since CUDA already
   provides them via <cuda.h>."
  (when dvec-types
    (format stream "// Device vector output operators (types provided by <cuda.h>)~%")
    (dolist (type-sym dvec-types)
      (multiple-value-bind (base width) (%dvec-parse type-sym)
        (when base
          (let* ((type-str (string-downcase (symbol-name type-sym)))
                 (member-names (subseq (list "x" "y" "z" "w") 0 width)))
            (format stream "std::ostream& operator<<(std::ostream& os, const ~a& v) {~%" type-str)
            (let ((firstp t))
              (dolist (m member-names)
                (if firstp
                    (format stream "    os << v.~a" m)
                    (format stream " << \" \" << v.~a" m))
                (setf firstp nil)))
            (format stream ";~%")
            (format stream "    return os;~%")
            (format stream "}~%~%")))))))


;;; -----------------------------------------------------------------------
;;; Top-level launcher generator
;;; -----------------------------------------------------------------------

(defun generate-cuda-launcher (metacrisp-path)
  "Generate CUDA Driver API C++ launcher code from metacrisp file."
  (let* ((data     (parse-metacrisp-file metacrisp-path))
         (kernels  (metacrisp-kernels data))
         (aliases  (metacrisp-aliases data))
         ;; Endeavor 130 Phase 5: an active hardware profile's :compute-units
         ;; OVERRIDES the runtime device query for grid sizing (so a deliberately
         ;; shrunken profile actually takes effect host-side).
         (hw-profile (metacrisp-hardware-profile data))
         (hw-compute-units (getf hw-profile :compute-units))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    (when (null kernels)
      (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    (let ((*hoist-current-structs* (metacrisp-structs data)))
      (dolist (kernel kernels)
        (let* ((kernel-name    (getf kernel :name))
               (declared-sig  (getf kernel :declared-signature))
               (implicit-sig  (getf kernel :implicit-params))
               (dispatch-info (let ((gs (getf kernel :global-size))
                                    (ls (getf kernel :local-size))
                                    (ng (getf kernel :num-groups)))
                                 (when (or gs ls ng)
                                   (append (when gs (list :global-size gs))
                                           (when ls (list :local-size  ls))
                                           (when ng (list :num-groups  ng))))))
               (comparable-range-start
                 (lambda (param)
                   (let ((r (getf param :range)))
                     (if (listp r) (first r) -1))))
               (full-sig      (sort (append declared-sig implicit-sig) #'<
                                    :key comparable-range-start))
               (output-targets (getf kernel :output-targets)))

          (let* ((ptx-path-entry (assoc :ptx output-targets))
                 (ptx-path  (when ptx-path-entry (second ptx-path-entry)))
                 (suffix    (format nil "_~a" kernel-name))
                 (name-part (if (uiop:string-suffix-p base-name suffix)
                                base-name
                                (format nil "~a~a" base-name suffix)))
                 (output-name (format nil "~a_CUDA.cu" name-part))
                 (output-path (make-pathname :name (pathname-name output-name)
                                             :type "cu"
                                             :defaults metacrisp-path)))

            (if (null ptx-path)
                (format t "WARNING: No PTX target found for kernel ~a. Skipping host generation.~%"
                        kernel-name)
                (progn
                 (format t "  Generating: ~a~%" output-name)
                 (let ((dvec-types (%collect-dvec-types declared-sig aliases)))
                   (with-open-file (stream output-path :direction :output :if-exists :supersede)
                     (emit-preamble stream metacrisp-path kernel-name output-name)
                     (emit-includes stream)
                     (emit-typedefs stream aliases)
                     (emit-cuda-dvec-ostream-operators stream dvec-types)
                     (emit-structs stream (append (metacrisp-records data) (metacrisp-structs data)))
                     (emit-helpers stream)
                     (emit-main stream kernel-name ptx-path full-sig aliases
                                (metacrisp-records data) dispatch-info
                                hw-compute-units)))
                 (format t "  Done: ~a~%" (namestring output-path))))))))))


;;; -----------------------------------------------------------------------
;;; Code emission — preamble, includes, typedefs, structs, helpers
;;; -----------------------------------------------------------------------

(defun emit-preamble (stream metacrisp-path kernel-name output-name)
  "Generate C++ file preamble comment."
  (format stream "/*~%")
  (format stream " * Generated by crisp-hoist-cuda~%")
  (format stream " * Source: ~a~%" (namestring metacrisp-path))
  (format stream " * Kernel: ~a~%" kernel-name)
  (format stream " *~%")
  (format stream " * Compilation:~%")
  (format stream " *   nvcc -o launcher ~a -lcuda~%" output-name)
  (format stream " *~%")
  (format stream " * CUDA Driver API — links -lcuda (NOT -lcudart).~%")
  (format stream " */~%~%"))

(defun emit-includes (stream)
  "Generate C++ includes for CUDA Driver API."
  (format stream "#include <cuda.h>~%")
  (format stream "#include <iostream>~%")
  (format stream "#include <fstream>~%")
  (format stream "#include <vector>~%")
  (format stream "#include <cstring>~%")
  (format stream "#include <cstdint>~%~%"))

(defun emit-typedefs (stream aliases)
  "Generate C++ typedef declarations from type aliases."
  (when aliases
    (format stream "// Type aliases~%")
    (dolist (alias-def aliases)
      (when (and (listp alias-def) (>= (length alias-def) 3))
        (let ((alias-name (second alias-def))
              (target-type (third alias-def)))
          (if (symbolp target-type)
              (format stream "typedef ~a ~a;~%"
                      (string-downcase (symbol-name target-type))
                      (string-downcase (symbol-name alias-name)))
              (format t "Warning: Skipping complex typedef for ~a: ~a~%" alias-name target-type)))))
    (format stream "~%")))

(defun emit-structs (stream structs)
  "Generate C++ struct definitions from metadata (mirrors L0 hoist)."
  (when structs
    (format stream "// Struct Definitions~%")
    (dolist (struct-def structs)
      (let* ((struct-name     (second struct-def))
             (struct-name-str (substitute #\_ #\- (string-downcase (symbol-name struct-name))))
             (members         (cddr struct-def)))

        (unless (or (search "TENSOR_" (symbol-name struct-name) :test #'char-equal)
                    (search "STORAGE_" (symbol-name struct-name) :test #'char-equal))

          (format stream "struct ~a {~%" struct-name-str)
          (dolist (member members)
            (let* ((member-name     (first member))
                   (member-type     (second member))
                   (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name)))))
              (if (%array-type-p member-type)
                  (let* ((elem-type (%array-element-type member-type))
                         (arr-size  (%array-size member-type))
                         (elem-str  (crisp-type-to-cpp-type elem-type)))
                    (format stream "    ~a ~a[~a];~%" elem-str member-name-str arr-size))
                  (let ((member-type-str
                          (if (symbolp member-type)
                              (substitute #\_ #\- (string-downcase (symbol-name member-type)))
                              (substitute #\_ #\- (string-downcase (symbol-name (first member-type)))))))
                    (format stream "    ~a ~a;~%" member-type-str member-name-str)))))

          (format stream "    friend std::ostream& operator<<(std::ostream& os, const ~a& obj) {~%" struct-name-str)
          (let ((first-member t))
            (dolist (member members)
              (let* ((member-name     (first member))
                     (member-type     (second member))
                     (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name)))))
                (if (%array-type-p member-type)
                    (let ((arr-size (%array-size member-type)))
                      (unless first-member (format stream "        os << \" \";~%"))
                      (format stream "        for (int _i = 0; _i < ~a; _i++) {~%" arr-size)
                      (format stream "            if (_i > 0) os << \" \";~%")
                      (format stream "            os << obj.~a[_i];~%" member-name-str)
                      (format stream "        }~%"))
                    (progn
                      (unless first-member (format stream "        os << \" \";~%"))
                      (format stream "        os << obj.~a;~%" member-name-str)))
                (setf first-member nil))))
          (format stream "        return os;~%")
          (format stream "    }~%")
          (format stream "};~%~%"))))))

(defun emit-helpers (stream)
  "Generate C++ helper: read PTX file and CUDA error checking."
  (format stream "#define CUDA_CHECK(call) do { \\~%")
  (format stream "    CUresult _r = (call); \\~%")
  (format stream "    if (_r != CUDA_SUCCESS) { \\~%")
  (format stream "        const char* _e; cuGetErrorString(_r, &_e); \\~%")
  (format stream "        std::cerr << \"CUDA error at \" << __FILE__ << \":\" << __LINE__ \\~%")
  (format stream "                  << \" — \" << _e << std::endl; \\~%")
  (format stream "        return 1; \\~%")
  (format stream "    } \\~%")
  (format stream "} while(0)~%~%")

  (format stream "// Helper: Read PTX text from file~%")
  (format stream "std::string read_ptx_file(const char* filename) {~%")
  (format stream "    std::ifstream file(filename);~%")
  (format stream "    if (!file) {~%")
  (format stream "        throw std::runtime_error(std::string(\"Failed to open PTX file: \") + filename);~%")
  (format stream "    }~%")
  (format stream "    return std::string((std::istreambuf_iterator<char>(file)),~%")
  (format stream "                        std::istreambuf_iterator<char>());~%")
  (format stream "}~%~%"))


;;; -----------------------------------------------------------------------
;;; Main function emission — init, module load, arg setup, launch, readback
;;; -----------------------------------------------------------------------

(defun emit-main (stream kernel-name ptx-path declared-sig aliases records &optional dispatch-info compute-units)
  "Generate C++ main function for CUDA Driver API launcher.
COMPUTE-UNITS, when non-NIL, is the active hardware profile's :compute-units and
overrides the runtime SM-count query in the grid-size heuristic."
  (format stream "int main() {~%")
  (format stream "    std::cout << \"CUDA Driver API Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)

  ;; CUDA init
  (emit-cuda-init stream)

  ;; PTX module loading
  (emit-module-loading stream ptx-path)

  ;; Kernel function handle
  (format stream "    CUfunction kernel;~%")
  (format stream "    CUDA_CHECK(cuModuleGetFunction(&kernel, module, \"~a\"));~%" kernel-name)
  (format stream "    std::cout << \"Kernel function loaded\" << std::endl;~%~%")

  ;; Allocate and set up args; returns list of allocations for readback
  (let ((allocations (emit-kernel-args stream declared-sig aliases records dispatch-info)))

    ;; Compute shared memory total for local tiles
    (let ((shared-bytes (compute-total-shared-bytes declared-sig aliases)))

      ;; Launch
      (emit-launch stream dispatch-info shared-bytes compute-units)

      ;; Synchronize
      (format stream "    CUDA_CHECK(cuCtxSynchronize());~%")
      (format stream "    std::cout << \"Kernel executed successfully\" << std::endl;~%~%")

      ;; Readback and print
      (emit-readback stream allocations))

    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))

(defun emit-cuda-init (stream)
  "Emit CUDA Driver API initialization."
  (format stream "    // Initialize CUDA Driver API~%")
  (format stream "    CUDA_CHECK(cuInit(0));~%~%")

  (format stream "    CUdevice device;~%")
  (format stream "    CUDA_CHECK(cuDeviceGet(&device, 0));~%")
  (format stream "    char devName[256];~%")
  (format stream "    cuDeviceGetName(devName, sizeof(devName), device);~%")
  (format stream "    std::cout << \"Device: \" << devName << std::endl;~%~%")

  (format stream "    CUcontext context;~%")
  (format stream "    CUDA_CHECK(cuCtxCreate(&context, 0, device));~%~%"))

(defun emit-module-loading (stream ptx-path)
  "Emit PTX module loading via cuModuleLoadData (JIT)."
  (format stream "    // Load PTX module~%")
  (format stream "    const char* ptx_path = \"~a\";~%" (namestring ptx-path))
  (format stream "    std::string ptx_text;~%")
  (format stream "    try {~%")
  (format stream "        ptx_text = read_ptx_file(ptx_path);~%")
  (format stream "    } catch (const std::exception& e) {~%")
  (format stream "        std::cerr << \"ERROR: \" << e.what() << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (format stream "    CUmodule module;~%")
  (format stream "    CUDA_CHECK(cuModuleLoadData(&module, ptx_text.c_str()));~%")
  (format stream "    std::cout << \"PTX module loaded successfully\" << std::endl;~%~%"))


;;; -----------------------------------------------------------------------
;;; Argument emission — builds the kernelParams[] array
;;;
;;; CUDA Driver API passes arguments as void* kernelParams[].  Each element
;;; points to the memory holding the argument value.  We declare host
;;; variables, then build the array at the end.
;;; -----------------------------------------------------------------------

(defun compute-total-shared-bytes (declared-sig aliases)
  "Sum up all local-memory tensor byte-sizes for the sharedMemBytes launch param."
  (let ((total 0))
    (dolist (param declared-sig)
      (let* ((raw-type   (getf param :type))
             (param-type (resolve-type-alias raw-type aliases))
             (param-as   (getf param :address-space))
             (is-local   (member param-as '(:local "LOCAL" local) :test #'string-equal)))
        (when (and (or (tensor-type-p param-type) (cell-type-p param-type)) is-local)
          (let* ((is-tensor (tensor-type-p param-type))
                 (rank (if is-tensor
                           (let ((n3 (third param-type))) (if (integerp n3) n3 1))
                           1))
                 (size-expr (getf param :size-expr))
                 (elem-type (if is-tensor (second param-type) (cell-base-type param-type)))
                 (elem-str  (crisp-type-to-cpp-type elem-type))
                 (elem-bytes (if (or (string-equal elem-str "double")
                                     (string-equal elem-str "int64_t")
                                     (string-equal elem-str "uint64_t")) 8 4)))
            ;; size-expr: scalar (square: total = size^rank) or (rows cols) list
            ;; (non-square: total = product).  (Matches %cuda-scratch-dims below.)
            (when (and is-tensor (or (integerp size-expr)
                                     (and (listp size-expr) (every #'integerp size-expr))))
              (let ((count (if (integerp size-expr)
                               (expt size-expr rank)
                               (reduce #'* size-expr))))
                (incf total (* count elem-bytes))))
            (when (and (not is-tensor) is-local)
              (let ((count (if (%array-type-p (cell-base-type param-type))
                               (%array-size (cell-base-type param-type))
                               1)))
                (incf total (* count elem-bytes))))))))
    total))

(defun %cuda-emit-cell-arg (stream param param-name param-type param-dir is-local aliases arg-index)
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
        ;; LOCAL MEMORY — pass 0 as ptr, bytesize, and offset
        (progn
          (format stream "~%    // LOCAL cell: ~a~%" param-name)
          (format stream "    uint64_t ~a_local_ptr = 0;  // shared offset~%" param-name-cpp)
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
          ;; Host-side init buffer
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

(defun %cuda-scratch-dims (size-expr rank param-name)
  "Per-dimension extents for a scratch tensor.  :size-expr may be a scalar (a SQUARE
   tensor: all RANK dims equal it — e.g. make-scratch-matrix float 4 -> 4x4) or a LIST
   of RANK integers (a non-square tensor — e.g. make-scratch-matrix float (16 8))."
  (cond
    ((integerp size-expr) (make-list rank :initial-element size-expr))
    ((and (listp size-expr) (= (length size-expr) rank) (every #'integerp size-expr))
     size-expr)
    (t (error "Scratch tensor ~a: :size-expr ~a is neither an integer nor a list of ~d integers."
              param-name size-expr rank))))



(defvar *cuda-shared-scratch-offset* 0
  "Running byte offset into the kernel's dynamic shared memory, assigned to each
   LOCAL scratch tile in turn so multiple tiles do not alias.  Reset per kernel in
   emit-kernel-args.")

;;; src/hoist-cuda/main.lisp - %cuda-emit-local-scratch-tensor-arg: distinct SLM offsets.
(defun %cuda-emit-local-scratch-tensor-arg (stream param param-name param-type arg-index)
  (let* ((rank        (let ((n3 (third param-type))) (if (integerp n3) n3 1)))
         (size-expr   (getf param :size-expr))
         (elem-type   (second param-type))
         (elem-str    (crisp-type-to-cpp-type elem-type))
         (elem-bytes  (if (or (string-equal elem-str "double")
                              (string-equal elem-str "int64_t")
                              (string-equal elem-str "uint64_t")) 8 4))
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

(defun %cuda-emit-global-scratch-tensor-arg (stream param param-name param-type arg-index)
  (let* ((rank        (let ((n3 (third param-type))) (if (integerp n3) n3 1)))
         (size-expr   (getf param :size-expr))
         (elem-type   (second param-type))
         (elem-str    (crisp-type-to-cpp-type elem-type))
         (elem-bytes  (if (or (string-equal elem-str "double")
                              (string-equal elem-str "int64_t")
                              (string-equal elem-str "uint64_t")) 8 4))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var     (format nil "~a_ptr" param-name-cpp))
         (arg-names   '())
         (current-idx arg-index))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (%cuda-scratch-dims size-expr rank param-name))
      (let* ((length   (reduce #'* (%cuda-scratch-dims size-expr rank param-name)))
             (bytesize (* length elem-bytes)))
        (format stream "~%    // GLOBAL scratch tensor: ~a (rank=~d, ~a, ~d elems)~%"
                param-name rank elem-str length)
        (format stream "    CUdeviceptr ~a;~%" ptr-var)
        (format stream "    CUDA_CHECK(cuMemAlloc(&~a, ~dULL * sizeof(~a)));~%"
                ptr-var length elem-str)
        (format stream "    CUDA_CHECK(cuMemsetD8(~a, 0, ~dULL * sizeof(~a)));~%"
                ptr-var length elem-str)
        ;; ptr
        (push (format nil "~a" ptr-var) arg-names)
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

(defun %cuda-emit-struct-arg (stream param-name param-type aliases arg-index)
  (let* ((base-type      (%struct-base-type param-type))
         (resolved-base  (resolve-type-alias base-type aliases))
         (struct-def     (%find-struct-def resolved-base))
         (struct-members (cddr struct-def))
         (param-name-cpp (format-cpp-identifier param-name))
         (var-name       (format nil "~a_val" param-name-cpp))
         (struct-type-str (format-cpp-identifier resolved-base)))
    (format stream "~%    // Struct: ~a (~a)~%" param-name struct-type-str)
    (format stream "    ~a ~a;~%" struct-type-str var-name)
    (%struct-emit-fields stream var-name struct-members aliases)
    (values (+ arg-index 1) (list var-name))))

(defun %cuda-emit-record-arg (stream param-name param-type records aliases arg-index)
  (let* ((base-type       (record-base-type param-type))
         (record-def     (find-record-def param-type records))
         (record-members (cddr record-def))
         (param-name-cpp (format-cpp-identifier param-name))
         (var-name       (format nil "~a_val" param-name-cpp))
         (struct-type-str (format-cpp-identifier base-type)))
    (format stream "~%    // Record: ~a (~a, exploded)~%" param-name struct-type-str)
    (format stream "    ~a ~a;~%" struct-type-str var-name)
    (multiple-value-bind (new-idx new-names)
        (%record-field-args stream record-members var-name arg-index records aliases)
      (values new-idx new-names))))

(defun %cuda-emit-scalar-arg (stream param-name param-type arg-index)
  (let* ((type-str (crisp-type-to-cpp-type param-type))
         (param-name-cpp (substitute #\_ #\- param-name)))
    (multiple-value-bind (dvec-base dvec-width) (%dvec-parse param-type)
      (if dvec-base
          (let ((init-str (format nil "{~{~a~^, ~}}"
                                  (loop for i from 0 below dvec-width
                                        collect (+ arg-index 42 i)))))
            (format stream "    ~a ~a_arg = ~a;~%" type-str param-name-cpp init-str))
          (format stream "    ~a ~a_arg = ~d;~%" type-str param-name-cpp (+ arg-index 42))))
    (values (+ arg-index 1) (list (format nil "~a_arg" param-name-cpp)))))



(defun %cuda-tensor-map-data-type (elem-type)
  "Maps a Crisp element type to the CU_TENSOR_MAP_DATA_TYPE_* enum for cuTensorMapEncodeTiled."
  (let ((n (string-downcase (string elem-type))))
    (cond ((string= n "float")  "CU_TENSOR_MAP_DATA_TYPE_FLOAT32")
          ((string= n "double") "CU_TENSOR_MAP_DATA_TYPE_FLOAT64")
          (t (error "cuTensorMapEncodeTiled: unsupported element type ~a (need float/double)"
                    elem-type)))))

(defun %cuda-emit-tensor-map-encode (stream param)
  "Endeavor 137 Phase 2b.3: emit the host cuTensorMapEncodeTiled for a :kind :tensor-map
   descriptor and copy the 128-byte descriptor to device global (option A), leaving the device
   pointer in <name> (forward-declared earlier at the descriptor's ABI slot).  References the
   DESCRIBED tensor's already-emitted host variables (<d>_ptr, <d>_ext<k>, <d>_str<k>).  Uses the
   innermost-dimension-first convention (globalDim / boxDim reversed vs the row-major extents),
   matching the nvcc-verified H100 reference."
  (let* ((name      (substitute #\_ #\- (getf param :name)))
         (describes (substitute #\_ #\- (getf param :describes)))
         (rank      (getf param :rank))
         (box       (getf param :box-dims))
         (elem      (getf param :element-type))
         (elem-str  (crisp-type-to-cpp-type elem))
         (dtype     (%cuda-tensor-map-data-type elem)))
    (format stream "~%    // CUtensorMap descriptor for '~a' (box ~a) — Endeavor 137 :block TMA~%"
            describes box)
    (format stream "    CUtensorMap ~a_host;~%" name)
    ;; globalDim: fastest-varying (innermost) dim first -> reverse the row-major extents.
    (format stream "    uint64_t ~a_gdim[~d] = { ~{~a~^, ~} };~%" name rank
            (loop for k from (1- rank) downto 0 collect (format nil "~a_ext~d" describes k)))
    ;; globalStrides: tensorRank-1 entries, in BYTES.  For rank 2 row-major: { str0 * sizeof(e) }.
    (when (> rank 1)
      (format stream "    uint64_t ~a_gstr[~d] = { ~{~a~^, ~} };~%" name (1- rank)
              (loop for k from (- rank 2) downto 0
                    collect (format nil "~a_str~d * sizeof(~a)" describes k elem-str))))
    ;; boxDim: fastest-varying first -> reverse the tile box dims.
    (format stream "    uint32_t ~a_box[~d] = { ~{~a~^, ~} };~%" name rank
            (loop for k from (1- rank) downto 0 collect (nth k box)))
    (format stream "    uint32_t ~a_elstr[~d] = { ~{~a~^, ~} };~%" name rank
            (make-list rank :initial-element 1))
    (format stream "    CUDA_CHECK(cuTensorMapEncodeTiled(&~a_host, ~a, ~d,~%" name dtype rank)
    (format stream "        (void*)~a_ptr, ~a_gdim, ~a, ~a_box, ~a_elstr,~%"
            describes name (if (> rank 1) (format nil "~a_gstr" name) "nullptr") name name)
    (format stream "        CU_TENSOR_MAP_INTERLEAVE_NONE, CU_TENSOR_MAP_SWIZZLE_NONE,~%")
    (format stream "        CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));~%")
    (format stream "    CUDA_CHECK(cuMemAlloc(&~a, sizeof(CUtensorMap)));~%" name)
    (format stream "    CUDA_CHECK(cuMemcpyHtoD(~a, &~a_host, sizeof(CUtensorMap)));~%" name name)))

(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "Emit host-side variable declarations and fill the kernelParams[] array.
   Returns a list of allocation plists for readback.
   Bug 034: resets *cuda-shared-scratch-offset* so each kernel's LOCAL tiles get
   distinct, non-overlapping shared-memory offsets."
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
         ;; Endeavor 137: CUtensorMap descriptor (option A).  Forward-declare its device ptr and
         ;; reserve its ABI slot now (it sorts first); the encode is emitted AFTER the loop, once
         ;; the DESCRIBED tensor's host vars (<d>_ptr / <d>_ext / <d>_str) have been emitted.
         ((eq (getf param :kind) :tensor-map)
          (let ((nm (substitute #\_ #\- (getf param :name))))
            (format stream "    CUdeviceptr ~a;  // CUtensorMap descriptor (filled below)~%" nm)
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


(defun %record-field-args (stream members var-path arg-index records aliases)
  "Recursively emit field initialization for record args.
   Returns (values new-arg-index list-of-arg-names)."
  (let ((idx arg-index)
        (names '()))
    (dolist (member members)
      (let* ((field-sym       (first member))
             (field-type-raw  (second member))
             (field-type      (resolve-type-alias field-type-raw aliases))
             (field-name-cpp  (format-cpp-identifier field-sym))
             (field-path      (format nil "~a.~a" var-path field-name-cpp)))
        (cond
         ((%array-type-p field-type)
          (let* ((elem-type (%array-element-type field-type))
                 (arr-size  (%array-size field-type))
                 (elem-str  (crisp-type-to-cpp-type elem-type)))
            (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                    arr-size field-path elem-str)
            (loop for i from 0 below arr-size do
              (push (format nil "~a[~d]" field-path i) names)
              (incf idx))))
         ((record-type-p field-type records)
          (let* ((nested-def     (find-record-def field-type records))
                 (nested-members (cddr nested-def)))
            (multiple-value-bind (new-idx new-names)
                (%record-field-args stream nested-members field-path idx records aliases)
              (setf idx new-idx)
              (dolist (n new-names) (push n names)))))
         (t
          (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                 (init-val (cond ((string= cpp-type "float")  "1.0f")
                                 ((string= cpp-type "double") "1.0")
                                 (t "1"))))
            (format stream "    ~a = ~a;~%" field-path init-val)
            (push field-path names)
            (incf idx))))))
    (values idx (nreverse names))))


;;; -----------------------------------------------------------------------
;;; Launch emission
;;; -----------------------------------------------------------------------

(defun %dispatch-sym-to-cpp-var (sym)
  "Convert a dispatch param symbol to C++ variable name."
  (format nil "~a_arg" (substitute #\_ #\- (string-downcase (symbol-name sym)))))




;; ======================================================================
;; :derive-from <tensor> + :strategy expansion
;; ======================================================================
;;
;; Design:
;;   :derive-from <SYMBOL>   — single symbol = tensor parameter name.
;;                             Hoist references <symbol>_length at launch.
;;   :derive-from (a b ...)  — list of scalar parameter names.
;;                             Hoist references <a>_arg, etc.
;;
;;   :strategy :strided      — max occupancy via
;;                             cuOccupancyMaxActiveBlocksPerMultiprocessor.
;;                             Ignores tensor length (loop-vector-stride knows
;;                             where to stop via length~).
;;   :strategy :one-thread-per — gridX = ceil(length / block_x)
;;   :strategy :exact        — gridX = ceil(length / block_x) or ceil(length / tile-shape[0]) if present
;;
;; The block size used for occupancy comes from :local-size :set-to N.
;; If :local-size is missing, defaults to 256.

(defun %tensor-length-cpp-var (sym)
  "Convert a tensor parameter symbol to its C++ length variable.
   The CUDA hoist emits 'uint64_t <name>_length = N;' for each tensor param,
   which we reference at dispatch time."
  (format nil "~a_length" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %normalize-derive-from (raw)
  "Normalize :derive-from value into a list:
     <symbol>           -> (<symbol>)  ;; tensor case
     (sym1 sym2 ...)    -> (sym1 sym2 ...)
     nil                -> nil"
  (cond
    ((null raw) nil)
    ((symbolp raw) (list raw))
    ((consp raw) raw)
    (t nil)))

(defun %derive-from-is-tensor-p (raw)
  "Returns T if :derive-from was supplied as a bare symbol (tensor name)."
  (and raw (symbolp raw)))


(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units)
  "Emit cuLaunchKernel call with grid/block dims from dispatch-info.
   Supports:
     :strategy :strided        — max occupancy (cuOccupancyMaxActiveBlocksPerMultiprocessor)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)
     :set-to integer/list      — fixed grid
   And :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg).
   COMPUTE-UNITS, when non-NIL, is the active hardware profile's :compute-units;
   the :strided strategy then uses that fixed SM count instead of querying the
   device (CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT), so a shrunken profile takes
   effect host-side."
  (let* ((global-decl     (when dispatch-info (getf dispatch-info :global-size)))
         (local-decl      (when dispatch-info (getf dispatch-info :local-size)))
         (num-groups-decl (when dispatch-info (getf dispatch-info :num-groups)))

         (ls-rest    (when local-decl (cdr local-decl)))
         (ls-set-to  (when ls-rest (getf ls-rest :set-to)))
         (block-x    (cond ((integerp ls-set-to) ls-set-to)
                           ((and (consp ls-set-to) (first ls-set-to)) (first ls-set-to))
                           (t 1)))
         (block-y    (cond ((and (consp ls-set-to) (second ls-set-to)) (second ls-set-to))
                           (t 1)))

         (dispatch-decl (or global-decl num-groups-decl))
         (disp-rest  (when dispatch-decl (cdr dispatch-decl)))
         (set-to     (when disp-rest (getf disp-rest :set-to)))
         (raw-derive-from (when disp-rest (getf disp-rest :derive-from)))
         (derive-from-is-tensor (%derive-from-is-tensor-p raw-derive-from))
         (derive-from (%normalize-derive-from raw-derive-from))
         (strategy    (when disp-rest (getf disp-rest :strategy)))
         (strat-name  (when strategy (symbol-name strategy)))
         (is-strided  (and strat-name (string-equal strat-name "STRIDED")))
         (is-exact    (and strat-name (string-equal strat-name "EXACT")))
         (is-one-thread-per (or (and strat-name (string-equal strat-name "ONE-THREAD-PER"))
                                ;; default when :derive-from is present without explicit strategy
                                (and (null strat-name) derive-from)))
         (tile-shape  (when disp-rest (getf disp-rest :tile-shape)))
         ;; :occupancy <ratio> — manual derating for :strided (default 1.0)
         (occupancy   (when disp-rest (getf disp-rest :occupancy))))

    (format stream "    // Launch kernel~%")

    (cond
      ;; --- :strategy :strided — max occupancy (optionally derated by :occupancy) ---
      (is-strided
       (let ((block-size (* block-x (max 1 block-y)))
             (ratio (cond ((null occupancy) 1.0)
                          ((numberp occupancy) (float occupancy))
                          (t 1.0))))
         (format stream "    // Strategy: :strided — max occupancy via cuOccupancyMaxActiveBlocksPerMultiprocessor~%")
         (when derive-from-is-tensor
           (format stream "    // derive-from tensor '~a' (length=~a) used for check-thread-bounds; grid uses occupancy~%"
                   (first derive-from) (%tensor-length-cpp-var (first derive-from))))
         (format stream "    int _blocksPerSM;~%")
         (format stream "    CUDA_CHECK(cuOccupancyMaxActiveBlocksPerMultiprocessor(&_blocksPerSM, kernel, ~d, ~a));~%"
                 block-size shared-bytes)
         (if compute-units
             (progn
               (format stream "    // Hardware profile active: :compute-units overrides the device SM query~%")
               (format stream "    int _numSMs = ~d;~%" compute-units))
             (progn
               (format stream "    int _numSMs;~%")
               (format stream "    CUDA_CHECK(cuDeviceGetAttribute(&_numSMs, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device));~%")))
         (if (= ratio 1.0)
             (format stream "    unsigned int gridX = (unsigned int)(_blocksPerSM * _numSMs);~%")
             (progn
               (format stream "    // :occupancy ~a — user-requested derate from max~%" occupancy)
               (format stream "    unsigned int gridX = (unsigned int)((_blocksPerSM * _numSMs) * ~f);~%" ratio)
               (format stream "    if (gridX < 1) gridX = 1;~%")))
         (format stream "    unsigned int gridY = 1, gridZ = 1;~%")))

      ;; --- :set-to integer — fixed grid ---
      ((and (not is-exact) (integerp set-to))
       (let ((grid-x (if (> block-x 1)
                         (format nil "(~a + ~a) / ~a" set-to (1- block-x) block-x)
                         (format nil "~a" set-to))))
         (format stream "    unsigned int gridX = ~a, gridY = 1, gridZ = 1;~%" grid-x)))

      ;; --- :strategy :exact with :derive-from ---
      (is-exact
       (if derive-from-is-tensor
           ;; Tensor-derived exact: gridX = ceil(<tensor>_length / tx)
           (let ((tx (if tile-shape (or (first tile-shape) 1) block-x))
                 (tensor-var (%tensor-length-cpp-var (first derive-from))))
             (format stream "    unsigned int gridX = ((unsigned int)~a + ~d) / ~d;~%"
                     tensor-var (1- tx) tx)
             (format stream "    unsigned int gridY = 1, gridZ = 1;~%"))
           ;; Scalar list exact
           (let ((d0 (first derive-from))
                 (d1 (second derive-from))
                 (tx (if tile-shape (or (first tile-shape) 1) block-x))
                 (ty (if tile-shape (or (second tile-shape) 1) (if (> block-y 1) block-y 1))))
             (when d0
               (format stream "    unsigned int gridX = ((unsigned int)~a + ~a) / ~a;~%"
                       (%dispatch-sym-to-cpp-var d0) (1- tx) tx))
             (when d1
               (format stream "    unsigned int gridY = ((unsigned int)~a + ~a) / ~a;~%"
                       (%dispatch-sym-to-cpp-var d1) (1- ty) ty))
             (unless d0 (format stream "    unsigned int gridX = 1;~%"))
             (unless d1 (format stream "    unsigned int gridY = 1;~%"))
             (format stream "    unsigned int gridZ = 1;~%"))))

      ;; --- :strategy :one-thread-per (or unstated default) + :derive-from <tensor> ---
      ((and is-one-thread-per derive-from-is-tensor)
       (let ((tensor-var (%tensor-length-cpp-var (first derive-from))))
         (format stream "    // Strategy: :one-thread-per from tensor ~a~%" (first derive-from))
         (if (> block-x 1)
             (format stream "    unsigned int gridX = ((unsigned int)~a + ~d) / ~d;~%"
                     tensor-var (1- block-x) block-x)
             (format stream "    unsigned int gridX = (unsigned int)~a;~%" tensor-var))
         (format stream "    unsigned int gridY = 1, gridZ = 1;~%")))

      ;; --- :set-to list OR :derive-from (scalar list) ---
      ((or (consp set-to) derive-from)
       (let* ((dims (cond ((consp set-to) set-to)
                          (derive-from derive-from)
                          (t nil)))
              (d0 (first dims))
              (d1 (second dims)))
         (flet ((dim-gc (dim local-val)
                  (cond
                    ((null dim) "1")
                    ((integerp dim)
                     (if (> local-val 1)
                         (format nil "(~a + ~a) / ~a" dim (1- local-val) local-val)
                         (format nil "~a" dim)))
                    ((symbolp dim)
                     (let ((v (%dispatch-sym-to-cpp-var dim)))
                       (if (> local-val 1)
                           (format nil "((unsigned int)~a + ~a) / ~a" v (1- local-val) local-val)
                           (format nil "(unsigned int)~a" v))))
                    (t "1"))))
           (format stream "    unsigned int gridX = ~a, gridY = ~a, gridZ = 1;~%"
                   (dim-gc d0 block-x)
                   (dim-gc d1 (if (> block-y 1) block-y 1))))))

      ;; --- Default fallback ---
      (t
       (format stream "    unsigned int gridX = 1, gridY = 1, gridZ = 1;~%")))

    (format stream "    CUDA_CHECK(cuLaunchKernel(kernel,~%")
    (format stream "        gridX, gridY, gridZ,~%")
    (format stream "        ~a, ~a, 1,~%" block-x block-y)
    (format stream "        ~a, 0,~%" shared-bytes)
    (format stream "        kernelParams, nullptr));~%~%")))

;;; -----------------------------------------------------------------------
;;; Readback and output printing
;;; -----------------------------------------------------------------------


  
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
