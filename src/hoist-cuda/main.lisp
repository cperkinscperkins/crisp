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

(defun main ()
  "Entry point for crisp-hoist-cuda.exe"
  (handler-case
      (let ((args (uiop:command-line-arguments)))
        (format t "Crisp Hoist CUDA - CUDA Driver API C++ Launcher Generator~%")
        (format t "Version: 0.1.0~%~%")

        (unless args
          (format t "Usage: crisp-hoist-cuda <path-to-metacrisp-file>~%")
          (uiop:quit 1))

        (let ((metacrisp-path (first args)))
          (unless (probe-file metacrisp-path)
            (format t "Error: File not found: ~a~%" metacrisp-path)
            (uiop:quit 1))

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
                                (metacrisp-records data) dispatch-info)))
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

(defun emit-main (stream kernel-name ptx-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main function for CUDA Driver API launcher."
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
      (emit-launch stream dispatch-info shared-bytes)

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
            (when (and is-tensor (integerp size-expr))
              (incf total (* (expt size-expr rank) elem-bytes)))
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
    (unless (integerp size-expr)
      (error "Local scratch tensor ~a has non-integer :size-expr ~a." param-name size-expr))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (make-list rank :initial-element size-expr))
      (let* ((length   (expt size-expr rank))
             (bytesize (* length elem-bytes)))
        (format stream "~%    // LOCAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes)~%"
                param-name rank elem-str length bytesize)
        ;; Arg: ptr (shared offset = 0)
        (format stream "    uint64_t ~a_ptr = 0;  // shared mem offset~%" param-name-cpp)
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
    (unless (integerp size-expr)
      (error "Global scratch tensor ~a has non-integer :size-expr ~a." param-name size-expr))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (make-list rank :initial-element size-expr))
      (let* ((length   (expt size-expr rank))
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
         (extents-list (let ((lst (make-list rank :initial-element 4)))
                         (let* ((global-decl (getf dispatch-info :global-size))
                                (strategy (getf (cdr global-decl) :strategy))
                                (derive-from (getf (cdr global-decl) :derive-from))
                                (tile-shape (getf (cdr global-decl) :tile-shape)))
                           (when (and tile-shape
                                      derive-from
                                      (member param-name (if (listp derive-from) derive-from (list derive-from))
                                              :test (lambda (a b) (string-equal (string a) (string b)))))
                             (loop for k from 0 below (min rank (length tile-shape)) do
                               (let* ((tx (nth k tile-shape))
                                      (base (nth k lst))
                                      (padded (* (ceiling base tx) tx)))
                                 (setf (nth k lst) padded)))))
                         lst)))
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
        ;; Init: iota
        (format stream "    {~%")
        (format stream "        ~a* h = new ~a[~d];~%" elem-str elem-str total-elems)
        (format stream "        for (size_t _i = 0; _i < ~d; _i++) h[_i] = (~a)_i;~%"
                total-elems elem-str)
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
                          :direction param-dir))
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

(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "Emit host-side variable declarations and fill the kernelParams[] array.
   Returns a list of allocation plists for readback."
  (format stream "    // Set up kernel arguments~%")
  (let ((arg-index 0)
        (allocations '())
        (arg-names '()))

    (dolist (param declared-sig)
      (let* ((param-name  (getf param :name))
             (raw-type    (getf param :type))
             (param-type  (resolve-type-alias raw-type aliases))
             (param-dir   (getf param :direction))
             (param-as    (getf param :address-space))
             (is-local    (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond
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


(defun emit-launch (stream dispatch-info shared-bytes)
  "Emit cuLaunchKernel call with grid/block dims from dispatch-info.
   Supports:
     :strategy :strided        — max occupancy (cuOccupancyMaxActiveBlocksPerMultiprocessor)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)
     :set-to integer/list      — fixed grid
   And :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg)."
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
         (format stream "    int _numSMs;~%")
         (format stream "    CUDA_CHECK(cuDeviceGetAttribute(&_numSMs, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device));~%")
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

(defun emit-readback (stream allocations)
  "Emit cuMemcpyDtoH and print buffer contents."
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
  (format stream "~%"))
