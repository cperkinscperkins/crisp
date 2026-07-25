(in-package :crisp.hoist.l0)



(defvar *mma-test-dims* nil "(M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.")
(defvar *mma-bench-iters* nil
  "Endeavor 142 (Phase B, Q1): iteration count when --mma-bench[=N] is passed — the launcher then wraps
   the (already-closed) command list in a warmup + timed re-execution loop and prints
   `BENCH M N K <gflops> GFLOPS`.  Requires --mma-test=M,N,K for the FLOPS count.  NIL = no benchmark.")
(defvar *mma-input-counter* 0 "Per-kernel input-tensor counter for A(0)/B(1) role assignment.")
(defvar *mma-scale* 1 "Reference scale factor (--mma-scale=S): expected C = S·(A·B).  Default 1.
   Used by kernels that fire the MMA more than once per fragment (e.g. accum-op body).")

(defun %mma-parse-args (args)
  "Return (values metacrisp-path (M N K)-or-NIL scale bench-iters), extracting --mma-test=M,N,K, an
   optional --mma-scale=S flag, and an optional --mma-bench[=N] flag (Endeavor 142; default 100 iters)."
  (let ((dims nil) (path nil) (scale 1) (bench nil))
    (dolist (a args)
      (cond
        ((and (>= (length a) 11) (string= (subseq a 0 11) "--mma-test="))
         (setf dims (mapcar #'parse-integer (uiop:split-string (subseq a 11) :separator ","))))
        ((and (>= (length a) 12) (string= (subseq a 0 12) "--mma-scale="))
         (setf scale (parse-integer (subseq a 12))))
        ((and (>= (length a) 12) (string= (subseq a 0 12) "--mma-bench="))
         (setf bench (parse-integer (subseq a 12))))
        ((string= a "--mma-bench")
         (setf bench 100))
        (t (unless path (setf path a)))))
    (values path dims scale bench)))

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
        (multiple-value-bind (metacrisp-path dims scale bench) (%mma-parse-args args)
          (setf *mma-test-dims* dims)
          (setf *mma-scale* scale)
          (setf *mma-bench-iters* bench)
          (when (and bench (not dims))
            (format t "Error: --mma-bench requires --mma-test=M,N,K (for the FLOPS count).~%")
            (uiop:quit 1))
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



;;; -----------------------------------------------------------------------
;;; Struct support for L0 hoist
;;; src/hoist-l0/main.lisp
;;;
;;; def-struct parameters appear as a single aggregate kernel argument
;;; (unlike def-record which is exploded to scalars).  The host must
;;; initialize a C++ struct variable and pass it via zeKernelSetArgumentValue
;;; with sizeof(TYPE).
;;;
;;; *hoist-current-structs* is bound by generate-l0-launcher to the :structs
;;; list from the metacrisp, so helpers can find struct definitions without
;;; modifying the call chain through generate-cpp-main / generate-kernel-launch.
;;; -----------------------------------------------------------------------

(defvar *hoist-current-structs* nil
        "Dynamic variable: list of (def-struct NAME ...) forms from the current
   metacrisp :structs section.  Bound by generate-l0-launcher.")


;; --- struct lookup helpers ---

(defun %find-struct-def-l0 (name)
  "Find (def-struct NAME ...) in *hoist-current-structs*.
   NAME is a symbol; all comparisons use string-equal to be package-agnostic.
   The metacrisp is parsed with standard READ (cl-user package), so symbols
   from the parsed data will not eq symbols from overlay source code."
  (find name *hoist-current-structs*
    :test (lambda (n f)
            (and (consp f)
                 (symbolp (first f))
                 (string-equal (symbol-name (first f)) "DEF-STRUCT")
                 (symbolp (second f))
                 (string-equal (symbol-name n) (symbol-name (second f)))))))

(defun struct-type-p-l0 (type)
  "Returns T if TYPE names a def-struct in *hoist-current-structs*.
   Accepts plain symbols or list forms like (POINT :EARNESTNESS 3.0)."
  (let ((base (cond ((symbolp type) type)
                    ((and (consp type) (symbolp (first type))) (first type))
                    (t nil))))
    (and base (not (null (%find-struct-def-l0 base))))))

(defun %struct-base-type (param-type)
  "Extract the base struct name from PARAM-TYPE (symbol or list form)."
  (if (symbolp param-type) param-type (first param-type)))


;; --- field initialization emitter ---

(defun %array-type-p (type)
  "Returns T if TYPE is an (array T N) form."
  (and (consp type)
       (symbolp (first type))
       (string-equal (symbol-name (first type)) "ARRAY")))

(defun %array-element-type (array-type)
  "Returns the element type T from an (array T N) form."
  (second array-type))

(defun %array-size (array-type)
  "Returns the compile-time size N from an (array T N) form."
  (third array-type))

(defun %struct-emit-fields (stream var-path members aliases)
  "Recursively emit C++ field assignments for a struct variable at VAR-PATH.
   MEMBERS is the member list from the (def-struct NAME ...) form.
   Array-typed fields are iota-initialized: field[i] = (T)i.
   Scalar fields use a type-appropriate constant (1 / 1.0f / 1.0).
   Nested structs are recursed into."
  (dolist (member members)
    (let* ((field-name (first member))
           (field-type-raw (second member))
           (field-name-cpp (format-cpp-identifier field-name))
           (field-path (format nil "~a.~a" var-path field-name-cpp))
           (field-type (resolve-type-alias field-type-raw aliases)))
      (cond
       ;; Array field — iota initialization: field[i] = (T)i
       ((%array-type-p field-type)
         (let* ((elem-type (%array-element-type field-type))
                (arr-size (%array-size field-type))
                (elem-str (crisp-type-to-cpp-type elem-type)))
           (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
             arr-size field-path elem-str)))
       ;; Nested struct — recurse
       ((struct-type-p-l0 field-type)
         (let* ((nested-def (%find-struct-def-l0 field-type))
                (nested-members (cddr nested-def)))
           (%struct-emit-fields stream field-path nested-members aliases)))
       ;; Scalar field — type-appropriate constant
       (t
         (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                (init-val (cond ((string= cpp-type "float") "1.0f")
                                ((string= cpp-type "double") "1.0")
                                (t "1"))))
           (format stream "    ~a = ~a;~%" field-path init-val)))))))


(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file.
   Extended to extract and pass dispatch declarations to generate-cpp-main."
  (let* ((data (parse-metacrisp-file metacrisp-path))
         (kernels (metacrisp-kernels data))
         (aliases (metacrisp-aliases data))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    (when (null kernels)
          (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    (let ((*hoist-current-structs* (metacrisp-structs data)))
      (dolist (kernel kernels)
        (let* ((kernel-name (getf kernel :name))
               (declared-sig (getf kernel :declared-signature))
               (implicit-sig (getf kernel :implicit-params))
               ;; Extract dispatch info from parsed metacrisp plist
               (dispatch-info (let ((gs (getf kernel :global-size))
                                    (ls (getf kernel :local-size))
                                    (ng (getf kernel :num-groups)))
                                (when (or gs ls ng)
                                      (append (when gs (list :global-size gs))
                                        (when ls (list :local-size ls))
                                        (when ng (list :num-groups ng))))))
               (comparable-range-start
                (lambda (param)
                  (let ((r (getf param :range)))
                    (if (listp r) (first r) -1))))
               (full-sig (sort (append declared-sig implicit-sig) #'<
                           :key comparable-range-start))
               (output-targets (getf kernel :output-targets)))

          (let* ((spv-path-entry (or (assoc :spirv output-targets)
                                     (assoc :spv output-targets)))
                 (spv-path (when spv-path-entry (second spv-path-entry)))
                 (suffix (format nil "_~a" kernel-name))
                 (name-part (if (uiop:string-suffix-p base-name suffix)
                                base-name
                                (format nil "~a~a" base-name suffix)))
                 (output-name (format nil "~a_L0.cpp" name-part))
                 (output-path (make-pathname :name (pathname-name output-name)
                                             :type "cpp"
                                             :defaults metacrisp-path)))

            (if (null spv-path)
                (format t "WARNING: No SPIR-V target found for kernel ~a. Skipping host generation.~%"
                  kernel-name)
                (progn
                 (format t "  Generating: ~a~%" output-name)
                 (let ((dvec-types (%collect-dvec-types declared-sig aliases)))
                   (with-open-file (stream output-path :direction :output :if-exists :supersede)
                     (generate-cpp-preamble stream metacrisp-path kernel-name output-name)
                     (generate-cpp-includes stream)
                     (generate-cpp-typedefs stream aliases)
                     (generate-cpp-dvec-typedefs stream dvec-types)
                     (generate-cpp-structs stream (append (metacrisp-records data) (metacrisp-structs data)))
                     (generate-cpp-helpers stream)
                     (generate-cpp-main stream kernel-name spv-path full-sig aliases (metacrisp-records data) dispatch-info)))
                 (format t "  Done: ~a~%" (namestring output-path))))))))))

(defun generate-cpp-preamble (stream metacrisp-path kernel-name output-name)
  "Generate C++ file preamble comment"
  (format stream "/*~%")
  (format stream " * Generated by crisp-hoist-l0~%")
  (format stream " * Source: ~a~%" (namestring metacrisp-path))
  (format stream " * Kernel: ~a~%" kernel-name)
  (format stream " *~%")
  (format stream " * Compilation:~%")
  (format stream " *   g++ -o launcher ~a -I<path-to-level-zero>/include -lze_loader~%" output-name)
  (format stream " *~%")
  (format stream " * Level Zero SDK: https://github.com/oneapi-src/level-zero/releases~%")
  (format stream " */~%~%"))

(defun generate-cpp-includes (stream)
  "Generate C++ includes"
  (format stream "#include <ze_api.h>~%")
  (format stream "#include <iostream>~%")
  (format stream "#include <fstream>~%")
  (format stream "#include <vector>~%")
  (format stream "#include <cstring>~%")
  (format stream "#include <cstdint>~%")
  (format stream "#include <chrono>~%~%"))


(defun generate-cpp-structs (stream structs)
  "Generate C++ struct definitions from metadata.
   For (array T N) member types: emits 'T name[N]' for the field declaration
   and a loop in operator<< to print all elements space-separated.
   operator<< prints values space-separated (no field names, no braces)
   so HOIST-EXPECT substring checks work correctly."
  (when structs
        (format stream "// Struct Definitions~%")
        (dolist (struct-def structs)
          (let* ((struct-name (second struct-def))
                 (struct-name-str (substitute #\_ #\- (string-downcase (symbol-name struct-name))))
                 (members (cddr struct-def)))

            ;; Skip internal tensor/storage records — not needed in host C++ code.
            ;; They are def-record entries that exist only for the compiler's ABI bookkeeping.
            (unless (or (search "TENSOR_" (symbol-name struct-name) :test #'char-equal)
                        (search "STORAGE_" (symbol-name struct-name) :test #'char-equal))

              ;; Struct body: native scalar layout — no alignas needed, C++ natural alignment matches.
              (format stream "struct ~a {~%" struct-name-str)
              (dolist (member members)
                (let* ((member-name (first member))
                       (member-type (second member))
                       (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name)))))
                  (if (%array-type-p member-type)
                      ;; Array field: T name[N]
                      (let* ((elem-type (%array-element-type member-type))
                             (arr-size (%array-size member-type))
                             (elem-str (crisp-type-to-cpp-type elem-type)))
                        (format stream "    ~a ~a[~a];~%" elem-str member-name-str arr-size))
                      ;; Scalar/nested-struct field (type may be a list like (STORAGE GLOBAL))
                      (let ((member-type-str
                             (if (symbolp member-type)
                                 (substitute #\_ #\- (string-downcase (symbol-name member-type)))
                                 ;; Nested record/struct: use the first element's name
                                 (substitute #\_ #\- (string-downcase (symbol-name (first member-type)))))))
                        (format stream "    ~a ~a;~%" member-type-str member-name-str)))))

              ;; operator<<
              (format stream "    friend std::ostream& operator<<(std::ostream& os, const ~a& obj) {~%" struct-name-str)
              (let ((first-member t))
                (dolist (member members)
                  (let* ((member-name (first member))
                         (member-type (second member))
                         (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name)))))
                    (if (%array-type-p member-type)
                        ;; Array field: loop over elements, space-separated
                        (let ((arr-size (%array-size member-type)))
                          (unless first-member
                            (format stream "        os << \" \";~%"))
                          (format stream "        for (int _i = 0; _i < ~a; _i++) {~%" arr-size)
                          (format stream "            if (_i > 0) os << \" \";~%")
                          (format stream "            os << obj.~a[_i];~%" member-name-str)
                          (format stream "        }~%"))
                        ;; Scalar/nested-struct field
                        (progn
                         (unless first-member
                           (format stream "        os << \" \";~%"))
                         (format stream "        os << obj.~a;~%" member-name-str)))
                    (setf first-member nil))))
              (format stream "        return os;~%")
              (format stream "    }~%")
              (format stream "};~%~%"))))))

(defun generate-cpp-typedefs (stream aliases)
  "Generate C++ typedef declarations from type aliases"
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

(defun generate-cpp-helpers (stream)
  "Generate C++ helper functions"
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
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = ~a_ptr[i*~a_str0 + j*~a_str1];~%" cb cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))


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

(defun generate-l0-init (stream)
  "Generate Level Zero initialization code"
  (format stream "    // Initialize Level Zero~%")
  (format stream "    result = zeInit(ZE_INIT_FLAG_GPU_ONLY);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeInit failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (format stream "    // Discover drivers~%")
  (format stream "    uint32_t driverCount = 0;~%")
  (format stream "    result = zeDriverGet(&driverCount, nullptr);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS || driverCount == 0) {~%")
  (format stream "        std::cerr << \"ERROR: No Level Zero drivers found\" << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (format stream "    ze_driver_handle_t driver;~%")
  (format stream "    driverCount = 1;~%")
  (format stream "    zeDriverGet(&driverCount, &driver);~%~%")

  (format stream "    // Discover devices~%")
  (format stream "    uint32_t deviceCount = 0;~%")
  (format stream "    result = zeDeviceGet(driver, &deviceCount, nullptr);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS || deviceCount == 0) {~%")
  (format stream "        std::cerr << \"ERROR: No Level Zero devices found\" << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (format stream "    ze_device_handle_t device;~%")
  (format stream "    deviceCount = 1;~%")
  (format stream "    zeDeviceGet(driver, &deviceCount, &device);~%")
  (format stream "    std::cout << \"Found Level Zero device\" << std::endl;~%~%")

  (format stream "    // Create context~%")
  (format stream "    ze_context_desc_t contextDesc = { ZE_STRUCTURE_TYPE_CONTEXT_DESC };~%")
  (format stream "    ze_context_handle_t context;~%")
  (format stream "    result = zeContextCreate(driver, &contextDesc, &context);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeContextCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%"))

(defun generate-module-loading (stream spv-path)
  "Generate SPIR-V module loading code"
  (format stream "    // Load SPIR-V module~%")
  (format stream "    const char* spv_path = \"~a\";~%" (namestring spv-path))
  (format stream "    std::vector<uint8_t> spirv_data;~%")
  (format stream "    try {~%")
  (format stream "        spirv_data = read_spirv_file(spv_path);~%")
  (format stream "    } catch (const std::exception& e) {~%")
  (format stream "        std::cerr << \"ERROR: \" << e.what() << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (format stream "    ze_module_desc_t moduleDesc = {~%")
  (format stream "        ZE_STRUCTURE_TYPE_MODULE_DESC,~%")
  (format stream "        nullptr,~%")
  (format stream "        ZE_MODULE_FORMAT_IL_SPIRV,~%")
  (format stream "        spirv_data.size(),~%")
  (format stream "        spirv_data.data(),~%")
  (format stream "        nullptr,~%")
  (format stream "        nullptr~%")
  (format stream "    };~%~%")

  (format stream "    ze_module_handle_t module;~%")
  (format stream "    result = zeModuleCreate(context, device, &moduleDesc, &module, nullptr);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeModuleCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%")
  (format stream "    std::cout << \"Module loaded successfully\" << std::endl;~%~%"))


(defun %dispatch-sym-to-cpp-var (sym)
  "Convert a dispatch param symbol (e.g. 'WIDTH or 'width) to C++ variable name 'width_arg'."
  (format nil "~a_arg" (substitute #\_ #\- (string-downcase (symbol-name sym)))))


;; ======================================================================
;; :derive-from <tensor> + :strategy expansion
;; ======================================================================
;;
;; Mirrors the CUDA hoist semantic upgrade:
;;   :derive-from <SYMBOL>   — tensor parameter; reference <name>_length
;;   :derive-from (a b ...)  — scalar parameter names; reference <name>_arg
;;
;;   :strategy :strided      — max occupancy.  L0 has no single-call equivalent
;;                             of CUDA's cuOccupancyMaxActiveBlocksPerMultiprocessor,
;;                             so we compute it from zeDeviceGetComputeProperties
;;                             plus optional zeKernelGetProperties for register
;;                             pressure awareness.
;;   :strategy :one-thread-per — grid = ceil(length / wg_x)
;;   :strategy :exact        — grid = ceil(length / local-size[0]) or ceil(length / tile-shape[0]) if present

(defun %l0-tensor-length-cpp-var (sym)
  "Convert a tensor parameter symbol to its C++ length variable.
   The L0 hoist emits 'uint64_t <name>_length = N;' for each tensor param."
  (format nil "~a_length" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %l0-normalize-derive-from (raw)
  "Normalize :derive-from value into a list:
     <symbol>           -> (<symbol>)  ;; tensor case
     (sym1 sym2 ...)    -> (sym1 sym2 ...)
     nil                -> nil"
  (cond
   ((null raw) nil)
   ((symbolp raw) (list raw))
   ((consp raw) raw)
   (t nil)))

(defun %l0-derive-from-is-tensor-p (raw)
  "Returns T if :derive-from was supplied as a bare symbol (tensor name)."
  (and raw (symbolp raw)))

(defun %l0-dim-to-gc (dim local-val)
  "Convert a dimension value (integer or symbol) to C++ expression for group count."
  (cond
   ((null dim) "1")
   ((integerp dim)
     (if (> local-val 1)
         (format nil "(~a + ~a) / ~a" dim (1- local-val) local-val)
         (format nil "~a" dim)))
   ((symbolp dim)
     (let ((cpp-var (%dispatch-sym-to-cpp-var dim)))
       (if (> local-val 1)
           (format nil "((uint32_t)~a + ~a) / ~a" cpp-var (1- local-val) local-val)
           (format nil "(uint32_t)~a" cpp-var))))
   (t "1")))

(defun %l0-emit-occupancy-and-strategy (stream is-strided is-interleaved occupancy derive-from-is-tensor derive-from)
  "Emit strategy descriptions and max-occupancy calculation."
  (when is-strided
        (let ((ratio (cond ((null occupancy) 1.0)
                           ((numberp occupancy) (float occupancy))
                           (t 1.0))))
          (format stream "    // Strategy: :strided — max occupancy~%")
          ;; Endeavor 130 Phase 5 (DEFERRED for L0): a CUDA hardware profile's
          ;; :compute-units overrides the device SM query (see hoist-cuda emit-launch,
          ;; `int _numSMs = <N>;`).  The active profile ALREADY travels into the
          ;; metacrisp (metacrisp-hardware-profile), so the wiring is ready here too.
          ;; What's undecided is the mapping: CUDA :compute-units == SM count (1:1 with
          ;; _numSMs), but Intel has no single "compute unit" — the occupancy below is
          ;; numSubslices × numEUsPerSubslice × numThreadsPerEU.  Whether :compute-units
          ;; should override numSubslices, map to Xe-cores, or use a distinct Intel key
          ;; is left until we actually benchmark on BMG (per user, 2026-07-04).  Until
          ;; then L0 keeps the runtime zeDeviceGetComputeProperties query unconditionally.
          (format stream "    ze_device_compute_properties_t _computeProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
          (format stream "    zeDeviceGetComputeProperties(device, &_computeProps);~%")
          (format stream "    uint32_t _hw_threads = _computeProps.numSubslices * _computeProps.numEUsPerSubslice * _computeProps.numThreadsPerEU;~%")
          (format stream "    // Refine with kernel resource footprint (privateMemSize, spillMemSize)~%")
          (format stream "    ze_kernel_properties_t _kernelProps = { ZE_STRUCTURE_TYPE_KERNEL_PROPERTIES };~%")
          (format stream "    zeKernelGetProperties(kernel, &_kernelProps);~%")
          (format stream "    // Derate occupancy by 2x if kernel spilled to private memory~%")
          (format stream "    if (_kernelProps.spillMemSize > 0) { _hw_threads /= 2; }~%")
          (unless (= ratio 1.0)
            (format stream "    // :occupancy ~a — user-requested derate from max~%" occupancy)
            (format stream "    _hw_threads = (uint32_t)(_hw_threads * ~f);~%" ratio)
            (format stream "    if (_hw_threads < 1) _hw_threads = 1;~%"))
          (when derive-from-is-tensor
                (format stream "    // :derive-from tensor '~a' (length=~a) used for check-thread-bounds; grid uses occupancy~%"
                  (first derive-from) (%l0-tensor-length-cpp-var (first derive-from))))
          (format stream "~%")))

  (when is-interleaved
        (format stream "    // Strategy: :interleaved not yet implemented — using default dispatch~%")))

(defun %l0-emit-group-count (stream is-strided is-interleaved is-exact is-one-thread-per dispatch-decl set-to derive-from derive-from-is-tensor tile-shape local-x local-y)
  "Emit group count logic for ze_group_count_t groupCount."
  (cond
   ;; :strided — occupancy-based grid
   (is-strided
     ;; Divide _hw_threads by workgroup size to get group count
     (let ((wg-total (* local-x (max 1 local-y))))
       (if (> wg-total 1)
           (format stream "    ze_group_count_t groupCount = { _hw_threads / ~d, 1, 1 };~%" wg-total)
           (format stream "    ze_group_count_t groupCount = { _hw_threads, 1, 1 };~%"))))

   (is-interleaved
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ((null dispatch-decl)
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ;; :exact with tensor :derive-from
   ((and is-exact derive-from-is-tensor)
     (let ((tx (if tile-shape (or (first tile-shape) 1) local-x))
           (tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
       (format stream "    uint32_t _gx = ((uint32_t)~a + ~d) / ~d;~%"
         tensor-var (1- tx) tx)
       (format stream "    ze_group_count_t groupCount = { _gx, 1, 1 };~%")))

   ;; :exact with scalar derive-from list
   (is-exact
     (let* ((d0 (first derive-from))
            (d1 (second derive-from))
            (d2 (third derive-from))
            (tx (if tile-shape (or (first tile-shape) 1) local-x))
            (ty (if tile-shape (or (second tile-shape) 1) (if (> local-y 1) local-y 1))))
       (when d0
             (format stream "    uint32_t _gx = ((uint32_t)~a + ~a) / ~a;~%"
               (%dispatch-sym-to-cpp-var d0) (1- tx) tx))
       (when d1
             (format stream "    uint32_t _gy = ((uint32_t)~a + ~a) / ~a;~%"
               (%dispatch-sym-to-cpp-var d1) (1- ty) ty))
       (when d2
             (format stream "    uint32_t _gz = ((uint32_t)~a + 0) / 1;~%"
               (%dispatch-sym-to-cpp-var d2)))
       (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%"
         (if d0 "_gx" "1")
         (if d1 "_gy" "1")
         (if d2 "_gz" "1"))))

   ;; :one-thread-per with tensor :derive-from
   ((and is-one-thread-per derive-from-is-tensor)
     (let ((tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
       (if (> local-x 1)
           (format stream "    ze_group_count_t groupCount = { ((uint32_t)~a + ~d) / ~d, 1, 1 };~%"
             tensor-var (1- local-x) local-x)
           (format stream "    ze_group_count_t groupCount = { (uint32_t)~a, 1, 1 };~%"
             tensor-var))))

   ((integerp set-to)
     (let ((g0 (%l0-dim-to-gc set-to local-x)))
       (format stream "    ze_group_count_t groupCount = { ~a, 1, 1 };~%" g0)))

   ;; :set-to list OR :derive-from (scalar list)
   (t
     (let* ((dims (cond
                   ((consp set-to) set-to)
                   (derive-from derive-from)
                   (t nil)))
            (d0 (first dims))
            (d1 (second dims))
            (d2 (third dims))
            (g0 (%l0-dim-to-gc d0 local-x))
            (g1 (%l0-dim-to-gc d1 (if (> local-y 1) local-y 1)))
            (g2 (%l0-dim-to-gc d2 1)))
       (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%" g0 g1 g2)))))

(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.
   Supports:
     :strategy :strided        — max occupancy (zeDeviceGetComputeProperties +
                                 optional zeKernelGetProperties)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)
     :strategy :interleaved    — not yet implemented (default dispatch)
   :set-to scalar/list       — fixed grid
   :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg)."
  (let* ((ls-rest (when local-decl (cdr local-decl)))
         (ls-set-to (when ls-rest (getf ls-rest :set-to)))
         (local-x (cond
                   ((integerp ls-set-to) ls-set-to)
                   ((and (listp ls-set-to) (first ls-set-to)) (first ls-set-to))
                   (t 1)))
         (local-y (cond
                   ((and (listp ls-set-to) (second ls-set-to)) (second ls-set-to))
                   (t 1)))

         (dispatch-decl (or global-decl num-groups-decl))
         (disp-rest (when dispatch-decl (cdr dispatch-decl)))
         (strategy (when disp-rest (getf disp-rest :strategy)))
         (strat-name (when strategy (symbol-name strategy)))

         (is-strided (and strat-name (string-equal strat-name "STRIDED")))
         (is-exact (and strat-name (string-equal strat-name "EXACT")))
         (is-interleaved (and strat-name (string-equal strat-name "INTERLEAVED")))
         (is-one-thread-per (and strat-name (string-equal strat-name "ONE-THREAD-PER")))

         (set-to (when disp-rest (getf disp-rest :set-to)))
         (raw-derive-from (when disp-rest (getf disp-rest :derive-from)))
         (derive-from-is-tensor (%l0-derive-from-is-tensor-p raw-derive-from))
         (derive-from (%l0-normalize-derive-from raw-derive-from))
         (tile-shape (when disp-rest (getf disp-rest :tile-shape)))
         ;; :occupancy <ratio> — manual derating for :strided (default 1.0)
         (occupancy (when disp-rest (getf disp-rest :occupancy))))

    (%l0-emit-occupancy-and-strategy stream is-strided is-interleaved occupancy derive-from-is-tensor derive-from)

    (let ((wg-x (format nil "~a" local-x))
          (wg-y (format nil "~a" local-y)))

      (format stream "    // Set group (workgroup) size~%")
      (format stream "    result = zeKernelSetGroupSize(kernel, ~a, ~a, 1);~%" wg-x wg-y)
      (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
      (format stream "        std::cerr << \"ERROR: zeKernelSetGroupSize failed: \" << result << std::endl;~%")
      (format stream "        return 1;~%")
      (format stream "    }~%~%")

      (format stream "    // Compute dispatch group count~%")
      (%l0-emit-group-count stream is-strided is-interleaved is-exact is-one-thread-per
                            dispatch-decl set-to derive-from derive-from-is-tensor tile-shape
                            local-x local-y))))


(defun generate-kernel-launch (stream kernel-name declared-sig aliases records &optional dispatch-info)
  "Generate kernel creation and launch code. Returns list of USM allocations.
   Extended to accept dispatch-info plist with :global-size, :local-size, :num-groups."
  (format stream "    // Create kernel~%")
  (format stream "    ze_kernel_desc_t kernelDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };~%")
  (format stream "    kernelDesc.pKernelName = \"~a\";~%" kernel-name)
  (format stream "    ze_kernel_handle_t kernel;~%")
  (format stream "    result = zeKernelCreate(module, &kernelDesc, &kernel);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeKernelCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  ;; Set kernel arguments if any
  (let ((allocations '()))
    (when declared-sig
          (setf allocations (generate-kernel-arguments-with-usm stream declared-sig aliases records "context" "device" dispatch-info)))

    ;; Create command list and queue
    (format stream "    // Create command list~%")
    (format stream "    ze_command_list_desc_t cmdListDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };~%")
    (format stream "    ze_command_list_handle_t cmdList;~%")
    (format stream "    result = zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandListCreate failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    (format stream "    // Create command queue~%")
    (format stream "    ze_command_queue_desc_t cmdQueueDesc = { ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC };~%")
    (format stream "    ze_command_queue_handle_t cmdQueue;~%")
    (format stream "    result = zeCommandQueueCreate(context, device, &cmdQueueDesc, &cmdQueue);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandQueueCreate failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    ;; Launch kernel — strategy-aware dispatch
    (format stream "    // Launch kernel~%")
    (let ((global-decl (when dispatch-info (getf dispatch-info :global-size)))
          (local-decl (when dispatch-info (getf dispatch-info :local-size)))
          (num-groups-decl (when dispatch-info (getf dispatch-info :num-groups))))
      (%l0-emit-dispatch stream global-decl local-decl num-groups-decl))

    (format stream "    result = zeCommandListAppendLaunchKernel(cmdList, kernel, &groupCount, nullptr, 0, nullptr);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandListAppendLaunchKernel failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    (format stream "    // Close and execute command list~%")
    (format stream "    zeCommandListClose(cmdList);~%")
    (format stream "    zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
    (format stream "    zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%~%")

    (format stream "    std::cout << \"Kernel executed successfully\" << std::endl;~%~%")

    ;; Endeavor 142 (Q1): timed re-execution of the (closed) command list.  Warm up, then time N
    ;; back-to-back submits on the single queue (they serialize) + one sync -> sustained throughput.
    ;; The correctness check (emitted after this) reads C from the LAST launch, still deterministic.
    (when (and *mma-bench-iters* *mma-test-dims*)
      (destructuring-bind (m n k) *mma-test-dims*
        (format stream "    // --mma-bench: warmup + timed launch loop (Endeavor 142)~%")
        (format stream "    {~%")
        (format stream "        const int BENCH_ITERS = ~d;~%" *mma-bench-iters*)
        (format stream "        for (int w = 0; w < 5; ++w) { zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr); }~%")
        (format stream "        zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "        auto _t0 = std::chrono::high_resolution_clock::now();~%")
        (format stream "        for (int it = 0; it < BENCH_ITERS; ++it) { zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr); }~%")
        (format stream "        zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "        auto _t1 = std::chrono::high_resolution_clock::now();~%")
        (format stream "        double _secs = std::chrono::duration<double>(_t1 - _t0).count();~%")
        (format stream "        double _flops = 2.0 * ~d.0 * ~d.0 * ~d.0 * (double)BENCH_ITERS;~%" m n k)
        (format stream "        double _gflops = (_secs > 0.0) ? (_flops / _secs / 1e9) : 0.0;~%")
        (format stream "        std::cout << \"BENCH ~d ~d ~d \" << _gflops << \" GFLOPS (\" << BENCH_ITERS << \" iters, \" << _secs << \" s)\" << std::endl;~%" m n k)
        (format stream "    }~%~%")))

    allocations))

(defun generate-kernel-arguments (stream declared-sig)
  "Generate kernel argument setup code"
  (format stream "    // Set kernel arguments~%")
  (let ((arg-index 0))
    (dolist (param declared-sig)
      (let ((param-name (getf param :name))
            (param-type (getf param :type)))
        ;; For now, just handle scalar types
        (when (symbolp param-type) ; Simple scalar type
              (format stream "    ~a ~a_arg = ~d;  // TODO: Set actual value~%"
                (string-downcase (symbol-name param-type))
                param-name
                (+ arg-index 42)) ; Placeholder value
              (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                arg-index
                (string-downcase (symbol-name param-type))
                param-name)
              (incf arg-index))))
    (when (> arg-index 0)
          (format stream "~%"))))


;; Record type helpers

(defun record-base-type (type)
  "Extract the base record type symbol from a plain symbol or a list-form like (V-POINT EARNESTNESS 3.0)."
  (if (symbolp type) type (first type)))

(defun find-record-def (type records)
  "Find the def-record entry matching TYPE in RECORDS.
   TYPE may be a plain symbol or a parameterized list form."
  (let ((base (record-base-type type)))
    (find base records
      :key #'second
      :test (lambda (a b) (string-equal (symbol-name a) (symbol-name b))))))

(defun record-type-p (type records)
  "Returns true if TYPE refers to a def-record in RECORDS."
  (and (not (cell-type-p type))
       (not (null (find-record-def type records)))))


(defun %record-field-args (stream members var-path arg-index records aliases)
  "Recursively emit field initialization and zeKernelSetArgumentValue calls
   for all leaf fields of a record, following nested records.
   Array-typed members are SROA'd: iota-initialized and passed as N
   individual scalar args (one per element), matching the compiler's
   physical signature which explodes (array T N) to N scalar slots.
   Returns the updated arg-index after consuming all fields."
  (let ((idx arg-index))
    (dolist (member members)
      (let* ((field-sym (first member))
             (field-type-raw (second member))
             (field-type (resolve-type-alias field-type-raw aliases))
             (field-name-cpp (format-cpp-identifier field-sym))
             (field-path (format nil "~a.~a" var-path field-name-cpp)))
        (cond
         ;; Array member — SROA: iota-init, then N individual zeKernelSetArgumentValue calls
         ((%array-type-p field-type)
           (let* ((elem-type (%array-element-type field-type))
                  (arr-size (%array-size field-type))
                  (elem-str (crisp-type-to-cpp-type elem-type)))
             (format stream "    // Iota-init array member ~a (~a elements, SROA'd to ~a scalar args)~%"
               field-path arr-size arr-size)
             (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
               arr-size field-path elem-str)
             (loop for i from 0 below arr-size do
                     (format stream "    // Arg ~d: ~a[~d]~%" idx field-path i)
                     (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a[~d]);~%"
                       idx elem-str field-path i)
                     (incf idx))))
         ;; Nested record — recurse into its members
         ((record-type-p field-type records)
           (let* ((nested-def (find-record-def field-type records))
                  (nested-members (cddr nested-def)))
             (setf idx (%record-field-args stream nested-members field-path idx records aliases))))
         ;; Scalar leaf — type-appropriate init, individual arg
         (t
           (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                  (init-val (cond ((string= cpp-type "float") "1.0f")
                                  ((string= cpp-type "double") "1.0")
                                  (t "1"))))
             (format stream "    ~a = ~a;~%" field-path init-val)
             (format stream "    // Arg ~d: ~a~%" idx field-path)
             (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a);~%"
               idx cpp-type field-path)
             (incf idx))))))
    idx))


;;; -----------------------------------------------------------------------
;;; Tensor support for L0 hoist
;;; src/hoist-l0/main.lisp
;;;
;;; Tensor (and vector/matrix sugar) parameters are exploded to 3N+3 scalar
;;; args at the ABI level:  PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1,
;;; EXT_0..N-1, LENGTH.
;;;
;;; The hoist harness:
;;;   1. Allocates USM for the element storage.
;;;   2. Initialises it (iota for :out, zeros for :in, both otherwise).
;;;   3. Emits zeKernelSetArgumentValue calls in ABI order.
;;;   4. Pushes an allocation record so copyback printing works.
;;;
;;; Layout strategy (test harness): always compact, EXTENT=4 per dim.
;;;
;;; :compact — tight row-major, strides in elements, innermost=1:
;;;   N=1: extents=[4],     strides=[1],      length=4
;;;   N=2: extents=[4,4],   strides=[4,1],    length=16
;;;   N=3: extents=[4,4,4], strides=[16,4,1], length=64
;;;
;;; :strided — the kernel accepts runtime strides, same compiled .spv;
;;;   the test harness always generates compact memory for :strided params.
;;;
;;; Total USM elements = stride_0 * extent_0.
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

(defun %l0-emit-cell-arg (stream param param-name param-type param-dir is-local aliases context-var device-var arg-index)
  (declare (ignore aliases))
  (let* ((base-type (cell-base-type param-type))
         (is-array-cell (%array-type-p base-type))
         (base-type-str (if is-array-cell
                            (crisp-type-to-cpp-type (%array-element-type base-type))
                            (crisp-type-to-cpp-type base-type)))
         (elem-count (if is-array-cell (%array-size base-type) 1))
         (param-name-cpp (substitute #\_ #\- param-name))
         (size-var (format nil "~a_size" param-name-cpp))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
         (alloc nil))
    (if is-local
        ;; --- LOCAL MEMORY ---
        (progn
         (format stream "~%    // Configure LOCAL memory for ~a~%" param-name)
         (format stream "    size_t ~a = ~a;  // ~a~%"
           size-var elem-count
           (if is-array-cell "Array cell: N elements" "Cell is a single scalar"))
         (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
         (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
         (format stream "    // Arg ~d: Local Pointer (Size=~a)~%" arg-index size-var)
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a_bytes, nullptr);~%"
           arg-index size-var)
         (format stream "    // Arg ~d: Size (bytes)~%" (+ arg-index 1))
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_bytes);~%"
           (+ arg-index 1) size-var)
         (format stream "    // Arg ~d: Offset (bytes)~%" (+ arg-index 2))
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_offset);~%~%"
           (+ arg-index 2) param-name-cpp))

        ;; --- GLOBAL MEMORY (USM) ---
        (progn
         (format stream "~%    // Allocate USM memory for ~a~%" param-name)
         (format stream "    size_t ~a = ~a;  // ~a~%"
           size-var elem-count
           (if is-array-cell "Array cell: N elements" "Cell is a single scalar"))
         (format stream "    ~a* ~a = nullptr;~%" base-type-str ptr-var)
         (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
           context-var)
         (format stream "        ~a * sizeof(~a), 1, ~a, (void**)&~a);~%"
           size-var base-type-str device-var ptr-var)
         (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
         (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
           param-name)
         (format stream "        return 1;~%")
         (format stream "    }~%")
         (format stream "    // Initialize data~%")
         (if is-array-cell
             (format stream "    for (size_t _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
               size-var ptr-var base-type-str)
             (format stream "    memset(~a, 0, ~a * sizeof(~a));~%" ptr-var size-var base-type-str))
         (format stream "    // Arg ~d: Base Pointer~%" arg-index)
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
           arg-index ptr-var)
         (format stream "    // Arg ~d: Size (bytes)~%" (+ arg-index 1))
         (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_bytes);~%"
           (+ arg-index 1) size-var)
         (format stream "    // Arg ~d: Offset (bytes)~%" (+ arg-index 2))
         (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
         (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_offset);~%~%"
           (+ arg-index 2) param-name-cpp)
         (setf alloc (list :name param-name
                           :ptr ptr-var
                           :size-var size-var
                           :direction param-dir
                           :access (getf param :access)))))
    (values (+ arg-index 3) alloc)))



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

(defun %l0-emit-global-scratch-tensor-arg (stream param param-name param-type context-var device-var arg-index)
  (let* ((rank (let ((n3 (third param-type)))
                 (if (integerp n3) n3 1)))
         (size-expr (getf param :size-expr))
         (elem-type (second param-type))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (elem-bytes (if (or (string-equal elem-str "double")
                             (string-equal elem-str "int64_t")
                             (string-equal elem-str "uint64_t")) 8 4))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp)))
    (unless (integerp size-expr)
      (error "Global scratch tensor ~a has non-integer :size-expr ~a. ~
              Only literal integer sizes are supported in the L0 hoist launcher."
        param-name size-expr))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (make-list rank :initial-element size-expr))
      (let* ((length (expt size-expr rank))
             (bytesize (* length elem-bytes))
             (current-idx arg-index))
        (format stream "~%    // GLOBAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes)~%"
          param-name rank elem-str length bytesize)
        ;; Allocate USM shared memory, zero-initialized
        (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
        (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
          context-var)
        (format stream "        ~dULL * sizeof(~a), 1, ~a, (void**)&~a);~%"
          length elem-str device-var ptr-var)
        (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
        (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
          param-name)
        (format stream "        return 1;~%")
        (format stream "    }~%")
        (format stream "    memset(~a, 0, ~dULL * sizeof(~a));  // scratch: zero-init~%"
          ptr-var length elem-str)
        ;; Arg 0: global USM pointer
        (format stream "    // Arg ~d: global scratch ptr~%" current-idx)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
          current-idx ptr-var)
        (incf current-idx)
        ;; Arg 1: byte-size
        (format stream "    // Arg ~d: byte-size = ~d~%" current-idx bytesize)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
          current-idx param-name-cpp)
        (incf current-idx)
        ;; Offsets (all zero)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: offset[~d] = 0~%" current-idx k)
                (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Strides (compact element strides)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: stride[~d] = ~d (elements, compact)~%"
                  current-idx k (nth k strides))
                (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Extents
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: extent[~d] = ~d~%" current-idx k (nth k extents))
                (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Length
        (format stream "    // Arg ~d: length = ~d~%" current-idx length)
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
          current-idx param-name-cpp)
        (incf current-idx)
        current-idx))))



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

(defun %l0-emit-struct-arg (stream param param-name param-type aliases arg-index)
  (declare (ignore param))
  (let* ((base-type (%struct-base-type param-type))
         (resolved-base (resolve-type-alias base-type aliases))
         (struct-def (%find-struct-def-l0 resolved-base))
         (struct-members (cddr struct-def))
         (param-name-cpp (format-cpp-identifier param-name))
         (var-name (format nil "~a_val" param-name-cpp))
         (struct-type-str (format-cpp-identifier resolved-base)))
    (format stream "~%    // Struct argument: ~a (~a)~%" param-name struct-type-str)
    (format stream "    ~a ~a;~%" struct-type-str var-name)
    (%struct-emit-fields stream var-name struct-members aliases)
    (format stream "    // Arg ~d: ~a~%" arg-index param-name)
    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a);~%~%"
      arg-index struct-type-str var-name)
    (incf arg-index)))

(defun %l0-emit-record-arg (stream param param-name param-type records aliases arg-index)
  (declare (ignore param))
  (let* ((base-type (record-base-type param-type))
         (record-def (find-record-def param-type records))
         (record-members (cddr record-def))
         (param-name-cpp (format-cpp-identifier param-name))
         (var-name (format nil "~a_val" param-name-cpp))
         (struct-type-str (format-cpp-identifier base-type)))
    (format stream "~%    // Record argument: ~a (~a)~%" param-name struct-type-str)
    (format stream "    ~a ~a;~%" struct-type-str var-name)
    (setf arg-index (%record-field-args stream record-members var-name arg-index records aliases))
    (format stream "~%")
    arg-index))

(defun %l0-emit-array-arg (stream param param-name param-type arg-index)
  (declare (ignore param))
  (let* ((elem-type (%array-element-type param-type))
         (arr-size (%array-size param-type))
         (elem-type-str (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (format-cpp-identifier param-name))
         (arr-var (format nil "~a_arg" param-name-cpp)))
    (format stream "~%    // Array argument: ~a (~a ~a[~a])~%"
      param-name elem-type-str param-name-cpp arr-size)
    (format stream "    ~a ~a[~a];~%" elem-type-str arr-var arr-size)
    (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
      arr-size arr-var elem-type-str)
    (format stream "    // Arg ~d: ~a~%" arg-index param-name)
    (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a * sizeof(~a), ~a);~%~%"
      arg-index arr-size elem-type-str arr-var)
    (incf arg-index)))

(defun %l0-emit-scalar-arg (stream param-name param-type arg-index)
  (let* ((type-str (crisp-type-to-cpp-type param-type)))
    (multiple-value-bind (dvec-base dvec-width) (%dvec-parse param-type)
      (if dvec-base
          (let ((init-str (format nil "{~{~a~^, ~}}"
                            (loop for i from 0 below dvec-width
                                  collect (+ arg-index 42 i)))))
            (format stream "    ~a ~a_arg = ~a;~%" type-str param-name init-str)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
              arg-index type-str param-name))
          (progn
           (format stream "    ~a ~a_arg = ~d;  // TODO: Set actual value~%"
             type-str param-name (+ arg-index 42))
           (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
             arg-index type-str param-name)))))
  (incf arg-index))

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var dispatch-info)
  "Generate kernel argument setup code with USM allocation for cells/tensors.
   Handles:
     cell                   — 3 args (ptr, byte-size, offset)
     local scratch tensor   — 3N+3 args; ptr as nullptr local alloc (NEW)
     tensor/vector/matrix   — 3N+3 args; USM allocation
     def-struct             — 1 arg (aggregate by value, sizeof struct)
     def-record             — exploded scalar args
     (array T N)            — 1 arg, passed by value (iota-initialized T[N])
     scalar/dvec            — 1 arg"
  (format stream "    // Set up kernel arguments~%")
  (format stream "    ze_device_mem_alloc_desc_t deviceDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };~%")
  (format stream "    ze_host_mem_alloc_desc_t hostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%~%")

  (let ((arg-index 0)
        (allocations '()))

    (dolist (param declared-sig)
      (let* ((param-name (getf param :name))
             (raw-type (getf param :type))
             (param-type (resolve-type-alias raw-type aliases))
             (param-dir (getf param :direction))
             (param-as (getf param :address-space))
             (is-local (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond
         ((cell-type-p param-type)
           (multiple-value-bind (new-idx alloc)
               (%l0-emit-cell-arg stream param param-name param-type param-dir is-local aliases context-var device-var arg-index)
             (setf arg-index new-idx)
             (when alloc (push alloc allocations))))

         ((and (tensor-type-p param-type) is-local)
           (setf arg-index (%l0-emit-local-scratch-tensor-arg stream param param-name param-type arg-index)))

         ((and (tensor-type-p param-type) (not is-local) (getf param :size-expr))
           (setf arg-index (%l0-emit-global-scratch-tensor-arg stream param param-name param-type context-var device-var arg-index)))

         ((tensor-type-p param-type)
           (multiple-value-bind (new-idx alloc)
               (%l0-emit-tensor-arg stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
             (setf arg-index new-idx)
             (when alloc (push alloc allocations))))

         ((struct-type-p-l0 param-type)
           (setf arg-index (%l0-emit-struct-arg stream param param-name param-type aliases arg-index)))

         ((record-type-p param-type records)
           (setf arg-index (%l0-emit-record-arg stream param param-name param-type records aliases arg-index)))

         ((%array-type-p param-type)
           (setf arg-index (%l0-emit-array-arg stream param param-name param-type arg-index)))

         ((symbolp param-type)
           (setf arg-index (%l0-emit-scalar-arg stream param-name param-type arg-index))))))

    (nreverse allocations)))
