(in-package :crisp.hoist.l0)



(defvar *l0-selected-registers-per-thread* nil
  "Endeavor 144 Phase 4: the per-thread register allocation the COMPILER selected for this
   module, read from the metacrisp's (:hardware-profile ... :selected-registers-per-thread N).
   NIL when no profile was active or no kernel needed more than the default allocation.
   Consumed by generate-module-loading to set ze_module_desc_t.pBuildFlags.")

(defvar *l0-register-modes* nil
  "Endeavor 144 Phase 4: the profile's selectable :max-registers-per-thread modes (a list),
   so the hoist can tell whether the selected allocation IS the default (emit nothing) or a
   larger mode (emit the IGC flag).")

(defvar *l0-compute-units* nil
  "Endeavor 144 Phase 6: the active profile's :compute-units (Xe-cores on Intel), or NIL.
   Latched by %l0-latch-hardware-profile; consumed by %l0-emit-occupancy-and-strategy to
   replace the queried numSlices*numSubslicesPerSlice product.")

(defun %l0-latch-hardware-profile (data)
  "Endeavor 144: cache the active hardware profile's L0-relevant decisions in the specials
   above, from an already-parsed metacrisp plist.

   This lives HERE rather than in parse-metacrisp-file (src/hoist/common.lisp) on purpose.
   `common` is shared by BOTH hoist backends, and crisp-hoist-cuda depends only on
   crisp-hoist-common — it never loads this package.  An earlier version latched from
   common.lisp via (find-symbol ... :crisp.hoist.l0), which is a PACKAGE-ERROR in the CUDA
   binary and broke every TEST-HOIST spec on both backends.  Backend-specific state belongs in
   the backend; the dependency only ever points hoist-l0 -> hoist-common."
  (let* ((profile (metacrisp-hardware-profile data))
         (modes   (getf profile :max-registers-per-thread)))
    (setf *l0-register-modes*
          (if (listp modes) modes (and modes (list modes)))
          *l0-selected-registers-per-thread*
          (getf profile :selected-registers-per-thread)
          *l0-compute-units*
          (getf profile :compute-units))
    profile))

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
         ;; Endeavor 144: cache the profile's L0 decisions before any emitter runs.
         (ignore-profile (%l0-latch-hardware-profile data))
         (kernels (metacrisp-kernels data))
         (aliases (metacrisp-aliases data))
         (base-name (pathname-name metacrisp-path)))
    (declare (ignore ignore-profile))

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
  (format stream "#if __has_include(<level_zero/ze_api.h>)~%")
  (format stream "#include <level_zero/ze_api.h>~%")
  (format stream "#else~%")
  (format stream "#include <ze_api.h>~%")
  (format stream "#endif~%")
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
          (format stream "      for (uint64_t i = 0; i < (~dULL < 64 ? ~dULL : 64); i++) for (uint64_t j = 0; j < (~dULL < 64 ? ~dULL : 64); j++) {~%" m m n n)
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
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name)) (ptr (getf alloc :ptr)) (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 100) {~%" size-v)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
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




(defun %l0-register-build-flags ()
  "Endeavor 144 Phase 4: the IGC build-flag string for the compiler-selected register
   allocation, or NIL when nothing needs to be requested.

   Emits `-ze-opt-large-register-file` only when the selected allocation is ABOVE the
   profile's default (first) mode.  Returning NIL for the default case matters: large-GRF
   is not free — it halves threads-per-EU — so it must be requested only for kernels whose
   register demand actually exceeds the default allocation."
  (let ((sel   *l0-selected-registers-per-thread*)
        (modes *l0-register-modes*))
    (when (and sel modes (> sel (first modes)))
      "-ze-opt-large-register-file")))

(defun generate-module-loading (stream spv-path)
  "Generate SPIR-V module loading code.

   Endeavor 144 Phase 4: pBuildFlags now carries the compiler-selected register allocation
   (see %l0-register-build-flags) instead of being unconditionally nullptr."
  (format stream "    // Load SPIR-V module~%")
  (format stream "    const char* spv_path = \"~a\";~%" (namestring spv-path))
  (format stream "    std::vector<uint8_t> spirv_data;~%")
  (format stream "    try {~%")
  (format stream "        spirv_data = read_spirv_file(spv_path);~%")
  (format stream "    } catch (const std::exception& e) {~%")
  (format stream "        std::cerr << \"ERROR: \" << e.what() << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (let ((flags (%l0-register-build-flags)))
    (when flags
      (format stream "    // Endeavor 144: the kernel's register-tile demand (~a registers/thread)~%"
              *l0-selected-registers-per-thread*)
      (format stream "    // exceeds this target's default allocation (~a), so ask IGC for the larger~%"
              (first *l0-register-modes*))
      (format stream "    // register file.  Without this the JIT spills instead (measured 1.5-2x slower).~%")
      (format stream "    const char* _buildFlags = \"~a\";~%" flags))

    (format stream "    ze_module_desc_t moduleDesc = {~%")
    (format stream "        ZE_STRUCTURE_TYPE_MODULE_DESC,~%")
    (format stream "        nullptr,~%")
    (format stream "        ZE_MODULE_FORMAT_IL_SPIRV,~%")
    (format stream "        spirv_data.size(),~%")
    (format stream "        spirv_data.data(),~%")
    (format stream "        ~a,~%" (if flags "_buildFlags" "nullptr"))
    (format stream "        nullptr~%")
    (format stream "    };~%~%"))

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
;;                             so we compute it from zeDeviceGetProperties (numSlices ×
;;                             numSubslicesPerSlice × numEUsPerSubslice × numThreadsPerEU,
;;                             each thread physicalEUSimdWidth wide) plus optional
;;                             zeKernelGetProperties for register pressure awareness.
;;                             NOT zeDeviceGetComputeProperties — that returns dispatch
;;                             LIMITS (maxTotalGroupSize, maxGroupCountX/Y/Z, subGroupSizes)
;;                             and carries no thread count, so it cannot size occupancy.
;;                             This comment previously named it, and that error propagated
;;                             into ideal_001.md and into two 089-strategy specs that then
;;                             failed for months.  It is used, correctly, for the tile-grid
;;                             dispatch limit guard (Endeavor 143).
;;   :strategy :one-thread-per — grid = ceil(length / wg_x)
;;   :strategy :exact        — grid = ceil(length / local-size[0]) or ceil(length / tile-shape[0]) if present
;;   :tile-shape present     — grid is the rank-N tile grid, ceil(extent[k] / tile[k]), axis k
;;                             from dimension k.  Overrides the strategy's own sizing; see the
;;                             hoist-l0 overlay for the measurements behind that.

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
  "Emit strategy descriptions and max-occupancy calculation.

   Endeavor 144 Phase 6: when a hardware profile supplies :compute-units, it REPLACES the
   queried numSlices*numSubslicesPerSlice (Xe-core count) in the occupancy formula; the
   per-Xe-core terms stay queried.  See the decision block above."
  (when is-strided
        (let ((ratio (cond ((null occupancy) 1.0)
                           ((numberp occupancy) (float occupancy))
                           (t 1.0))))
          (format stream "    // Strategy: :strided — max occupancy~%")
          (format stream "    ze_device_properties_t _deviceProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };~%")
          (format stream "    zeDeviceGetProperties(device, &_deviceProps);~%")
          (if *l0-compute-units*
              (progn
                (format stream "    // Endeavor 144 Phase 6: hardware profile active — :compute-units (~a Xe-cores)~%"
                        *l0-compute-units*)
                (format stream "    //   replaces the queried numSlices*numSubslicesPerSlice; EUs/core and~%")
                (format stream "    //   threads/EU remain queried (micro-architectural, not user-shrinkable).~%")
                (format stream "    uint32_t _xe_cores = ~d;~%" *l0-compute-units*)
                (format stream "    uint32_t _hw_threads = _xe_cores * _deviceProps.numEUsPerSubslice * _deviceProps.numThreadsPerEU;~%"))
              (format stream "    uint32_t _hw_threads = _deviceProps.numSlices * _deviceProps.numSubslicesPerSlice * _deviceProps.numEUsPerSubslice * _deviceProps.numThreadsPerEU;~%"))
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


;;; =====================================================================
;;; Endeavor 143 — dispatch geometry for tiled kernels
;;;
;;; MEASURED ON BMG (Arc B580, _hw_threads=640), matmul_bmg_prefetch, tf32, TFLOPS:
;;;
;;;   size    tile grid   current (40,1)   occupancy-clamped     exact tile cover
;;;   1024      32x32          1.40        8.10  (32,20)        10.52  (32,32)
;;;   2048      64x64          1.40        6.26  (64,10)         8.64  (64,64)
;;;   4096    128x128          1.37        4.26  (128,5)         7.46  (128,128)
;;;
;;; Two independent defects, and they do NOT compose:
;;;
;;; 1. AXIS SERIALIZATION (the big one).  `:strided` emitted a 1-D group count
;;;    `{_hw_threads / wg_total, 1, 1}` and ignored :tile-shape entirely.  Under an
;;;    N-D `tile-stride` loop a 1-D grid does not merely under-dispatch — the axes with
;;;    extent 1 are SERIALIZED inside each workgroup.  At 1024 only the 32 column-tiles
;;;    had any parallelism, out of 640 resident hardware threads.  Every result was
;;;    still correct, which is why it survived: tile-stride covers the tiles either way.
;;;
;;; 2. A UNITS ERROR.  `_hw_threads` counts hardware threads, each executing
;;;    physicalEUSimdWidth (16) work-items, but it was divided by the workgroup size in
;;;    WORK-ITEMS.  With local-size 16 one workgroup *is* one hardware thread, so the
;;;    resident capacity is 640 groups and the code emitted 40 — 16x low.
;;;
;;; Measured (640,1,1) == (40,1,1) == 1537 us: fixing #2 alone buys exactly nothing,
;;; because #1 dominates.  Both are fixed below.
;;;
;;; WHY EXACT-COVER RATHER THAN OCCUPANCY.  The occupancy budget is 640 groups; the
;;; exact tile grid at 4096 is 16384 groups — 25x oversubscribed — and it still wins,
;;; by 75%.  The margin WIDENS with size, so there is no crossover to clamp at (up to
;;; 4096, the largest measured).  For tiled kernels "cover the tile grid" beats "fill
;;; the machine".  `:occupancy` remains available as a manual derate.
;;;
;;; AXIS MAPPING: dispatch axis k <- tensor dimension k.  Measured on a NON-SQUARE
;;; 512x2048 problem (16 row-tiles x 64 col-tiles): (16,64) = 12.28 TFLOPS vs
;;; (64,16) = 9.41.  So gx <- extent0 (ROWS), gy <- extent1 (COLS) — the opposite of
;;; the CUDA x=columns convention.  BOTH orderings return MMA_CORRECT; the only symptom
;;; of getting it backwards is 1.31x, so do not "fix" this without re-measuring.

;; src/hoist-l0/main.lisp
(defun %l0-tensor-extent-cpp-var (sym k)
  "Convert a tensor parameter symbol to its C++ extent variable for dimension K.
   The L0 hoist emits 'uint64_t <name>_ext<k> = N;' for each tensor param dimension
   (see generate-kernel-arguments-with-usm).  Companion to %l0-tensor-length-cpp-var,
   which yields the flat length and is therefore useless for rank-N grid geometry."
  (format nil "~a_ext~d" (substitute #\_ #\- (string-downcase (symbol-name sym))) k))

;; src/hoist-l0/main.lisp
(defun %l0-emit-tile-grid-limit-guard (stream can-stride declared-axes)
  "Emit the ze_device_compute_properties_t guard for a tile-grid dispatch.

   DECLARED-AXES is the subset of (var limit label) triples whose group-count variable was
   actually emitted — a rank-2 kernel declares only _gx/_gy, so guarding _gz would not compile.

   CAN-STRIDE distinguishes the two cases, and the distinction is a CORRECTNESS one:

     :strided — the kernel's tile-stride loop covers any tile the grid does not reach, so
                clamping the grid to the device limit is SAFE.  It costs throughput, not
                correctness.  We clamp and warn.
     :exact   — one workgroup per tile, no loop.  A clamped grid would SILENTLY SKIP TILES,
                so exceeding the limit must be a hard error, not a clamp.

   Measured on BMG (Arc B580) 2026-07-26: maxGroupCountX/Y/Z all report UINT32_MAX, so a
   32x32-tile cover would not reach the limit until N ~ 1.4e11.  This guard is therefore
   inert on that part — it is here because exact-cover dispatch made the grid scale with the
   PROBLEM rather than with the hardware, so the bound is now reachable in principle where
   it previously was not, and because the strided/exact split above must not be silent."
  (format stream "    // Device dispatch limits (Endeavor 143).  The tile grid scales with the~%")
  (format stream "    // problem, not the hardware, so bound it by what the device will accept.~%")
  (format stream "    ze_device_compute_properties_t _cmpProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
  (format stream "    if (zeDeviceGetComputeProperties(device, &_cmpProps) == ZE_RESULT_SUCCESS) {~%")
  (dolist (axis declared-axes)
    (destructuring-bind (var limit label) axis
      (format stream "        if (~a > _cmpProps.~a) {~%" var limit)
      (if can-stride
          (progn
            ;; Safe: the tile-stride loop picks up the remainder.
            (format stream "            std::cerr << \"NOTE: ~a group count \" << ~a << \" exceeds device ~a (\"~%" label var limit)
            (format stream "                      << _cmpProps.~a << \"); clamping — the tile-stride loop covers the rest.\" << std::endl;~%" limit)
            (format stream "            ~a = _cmpProps.~a;~%" var limit))
          (progn
            ;; Unsafe: :exact has no stride loop, so a clamp would drop tiles.
            (format stream "            std::cerr << \"ERROR: ~a group count \" << ~a << \" exceeds device ~a (\"~%" label var limit)
            (format stream "                      << _cmpProps.~a << \"). :strategy :exact has no stride loop, so clamping\"~%" limit)
            (format stream "                      << \" would skip tiles.  Use :strategy :strided for a problem this large.\" << std::endl;~%")
            (format stream "            return 1;~%")))
      (format stream "        }~%")))
  (format stream "    }~%"))

;; src/hoist-l0/main.lisp
(defun %l0-emit-tile-grid-group-count (stream derive-from derive-from-is-tensor tile-shape &optional can-stride)
  "Emit a rank-N ze_group_count_t covering the OUTPUT TILE GRID: one workgroup per tile,
   ceil(extent_k / tile_k) along each axis, with dispatch axis k drawn from dimension k
   of the :derive-from source.

   DERIVE-FROM-IS-TENSOR selects the source of each extent: a tensor contributes
   <name>_ext<k> (per-dimension), a scalar list contributes its k'th parameter.  Note the
   tensor case must NOT use <name>_length — the flat element count carries no shape, and
   dividing it by tile-x is what the old :exact tensor branch did.

   Rank comes from the length of TILE-SHAPE, clamped to the 3 axes L0 dispatches.  Axes
   beyond that rank are the literal 1 in the initializer rather than a declared variable,
   so a rank-2 kernel emits `{ _gx, _gy, 1 }` and carries no unused _gz."
  (let* ((axis-vars '("_gx" "_gy" "_gz"))
         (axis-limits '("maxGroupCountX" "maxGroupCountY" "maxGroupCountZ"))
         (axis-labels '("x" "y" "z"))
         (rank (min (length tile-shape) 3))
         (inits (list "1" "1" "1"))
         (declared '()))
    (format stream "    // :tile-shape ~a — one workgroup per output tile; axis k <- dimension k.~%"
      tile-shape)
    (format stream "    // Endeavor 143: exact tile cover measured strictly better than an~%")
    (format stream "    // occupancy-clamped grid at every size up to 4096 (see overlay notes).~%")
    (dotimes (k rank)
      (let* ((var (nth k axis-vars))
             (tk  (or (nth k tile-shape) 1))
             (src (if derive-from-is-tensor
                      (when (first derive-from)
                        (%l0-tensor-extent-cpp-var (first derive-from) k))
                      (when (nth k derive-from)
                        (%dispatch-sym-to-cpp-var (nth k derive-from))))))
        (when (and src (> tk 0))
          (format stream "    uint32_t ~a = (uint32_t)(((uint64_t)~a + ~d) / ~d);~%"
            var src (1- tk) tk)
          (format stream "    if (~a < 1) ~a = 1;~%" var var)
          (setf (nth k inits) var)
          (push (list var (nth k axis-limits) (nth k axis-labels)) declared))))
    ;; Guard before the initializer, so the clamp/error applies to the values actually used,
    ;; and only over axes we really declared.
    (when declared
      (%l0-emit-tile-grid-limit-guard stream can-stride (nreverse declared)))
    (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%"
      (first inits) (second inits) (third inits))))

(defun %l0-emit-group-count (stream is-strided is-interleaved is-exact is-one-thread-per dispatch-decl set-to derive-from derive-from-is-tensor tile-shape local-x local-y)
  "Emit group count logic for ze_group_count_t groupCount.

   Endeavor 143: when :tile-shape is present on a :strided or :exact kernel, the grid is
   the rank-N tile grid (see %l0-emit-tile-grid-group-count) regardless of strategy —
   :tile-shape now determines grid SHAPE, :strategy only sizing policy along it.  The
   bare :strided path (no tile-shape, e.g. 1-D vector grid-stride) keeps occupancy sizing
   but corrects the hardware-thread/work-item units error described in the overlay notes."
  (cond
   ;; :tile-shape — rank-N tile-grid dispatch.  Takes precedence over the strategy's own
   ;; sizing: a 1-D grid under an N-D tile-stride loop serializes the missing axes.
   ;; CAN-STRIDE = is-strided: only a strided kernel has the tile-stride loop that makes
   ;; clamping the grid safe.  :exact must hard-error instead of silently dropping tiles.
   ((and tile-shape derive-from (or is-strided is-exact))
     (%l0-emit-tile-grid-group-count stream derive-from derive-from-is-tensor tile-shape
                                     is-strided))

   ;; :strided without :tile-shape — occupancy-based 1-D grid (vector grid-stride).
   (is-strided
     (let ((wg-total (* local-x (max 1 local-y))))
       (format stream "    // Occupancy sizing: _hw_threads counts SIMD hardware threads, so~%")
       (format stream "    // convert the workgroup size from work-items to threads before dividing.~%")
       (format stream "    uint32_t _simd_w = _deviceProps.physicalEUSimdWidth ? _deviceProps.physicalEUSimdWidth : 16;~%")
       (format stream "    uint32_t _threads_per_group = (~d + _simd_w - 1) / _simd_w;~%" wg-total)
       (format stream "    if (_threads_per_group < 1) _threads_per_group = 1;~%")
       (format stream "    uint32_t _gx = _hw_threads / _threads_per_group;~%")
       (format stream "    if (_gx < 1) _gx = 1;~%")
       (format stream "    ze_group_count_t groupCount = { _gx, 1, 1 };~%")))

   (is-interleaved
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ((null dispatch-decl)
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ;; :exact with tensor :derive-from and NO tile-shape — flat length / local-x.  Only
   ;; meaningful for rank-1 work; a tiled kernel must declare :tile-shape to get shape.
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
     :strategy :strided        — max occupancy (zeDeviceGetProperties +
                                 optional zeKernelGetProperties)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)
     :strategy :interleaved    — not yet implemented (default dispatch)
   :set-to scalar/list       — fixed grid
   :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg).

   Endeavor 143: a :tile-shape on a :strided/:exact kernel makes the grid the rank-N tile grid,
   so the occupancy preamble is suppressed in that case — it would be dead code."
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
         (occupancy (when disp-rest (getf disp-rest :occupancy)))
         ;; True when %l0-emit-group-count will take the tile-grid branch below.
         (tile-grid-p (and tile-shape derive-from (or is-strided is-exact))))

    (%l0-emit-occupancy-and-strategy stream
                                     (and is-strided (not tile-grid-p))
                                     is-interleaved occupancy
                                     derive-from-is-tensor derive-from)

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
   Extended to accept dispatch-info plist with :global-size, :local-size, :num-groups.

   Endeavor 143: the --mma-bench block now times each launch individually via L0
   kernel-timestamp events and reports the median, replacing the batched-submit /
   single-sync loop whose repeats the driver coalesced (inflating GFLOPS by ITERS)."
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

    ;; Endeavor 142 (Q1) / fixed in 143: per-launch kernel-timestamp timing.  Each iteration is a
    ;; SEPARATE submit + sync of a measurement command list that signals a kernel-timestamp event,
    ;; so every sample is one real execution.  Report the median.  See the overlay header comment
    ;; for why the previous batched-submit loop measured one execution no matter the iteration count.
    (when (and *mma-bench-iters* *mma-test-dims*)
      (destructuring-bind (m n k) *mma-test-dims*
        (format stream "    // --mma-bench: per-launch kernel-timestamp timing (Endeavor 142; fixed 143)~%")
        (format stream "    {~%")
        (format stream "        const int BENCH_ITERS = ~d;~%" *mma-bench-iters*)
        (format stream "        ze_device_properties_t _bmProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };~%")
        (format stream "        zeDeviceGetProperties(device, &_bmProps);~%")
        (format stream "        uint64_t _timerRes  = _bmProps.timerResolution;~%")
        (format stream "        uint64_t _validBits = _bmProps.kernelTimestampValidBits;~%")
        (format stream "        uint64_t _clockMask = (_validBits >= 64) ? ~~0ULL : ((1ULL << _validBits) - 1ULL);~%")
        ;; timerResolution is cycles/sec on L0 1.0 and ns/tick from 1.1 on; disambiguate by magnitude
        ;; exactly as bench_harness_l0.cpp does.
        (format stream "        bool _timerInHz = (_timerRes > 1000000ULL);~%~%")

        (format stream "        ze_event_pool_desc_t _poolDesc = { ZE_STRUCTURE_TYPE_EVENT_POOL_DESC };~%")
        (format stream "        _poolDesc.flags = ZE_EVENT_POOL_FLAG_KERNEL_TIMESTAMP;~%")
        (format stream "        _poolDesc.count = 1;~%")
        (format stream "        ze_event_pool_handle_t _pool = nullptr;~%")
        (format stream "        ze_event_handle_t _tsEvent = nullptr;~%")
        (format stream "        ze_command_list_handle_t _measList = nullptr;~%")
        (format stream "        bool _poolOk = (zeEventPoolCreate(context, &_poolDesc, 1, &device, &_pool) == ZE_RESULT_SUCCESS);~%")
        (format stream "        bool _tsOk = _poolOk;~%")
        (format stream "        if (_tsOk) {~%")
        (format stream "            ze_event_desc_t _evDesc = { ZE_STRUCTURE_TYPE_EVENT_DESC };~%")
        (format stream "            _evDesc.index  = 0;~%")
        (format stream "            _evDesc.signal = ZE_EVENT_SCOPE_FLAG_HOST;~%")
        (format stream "            _evDesc.wait   = ZE_EVENT_SCOPE_FLAG_HOST;~%")
        (format stream "            _tsOk = (zeEventCreate(_pool, &_evDesc, &_tsEvent) == ZE_RESULT_SUCCESS);~%")
        (format stream "        }~%")
        (format stream "        if (_tsOk) {~%")
        (format stream "            zeCommandListCreate(context, device, &cmdListDesc, &_measList);~%")
        (format stream "            zeCommandListAppendLaunchKernel(_measList, kernel, &groupCount, _tsEvent, 0, nullptr);~%")
        (format stream "            zeCommandListClose(_measList);~%")
        (format stream "        }~%~%")

        (format stream "        // Warmup: real submit + sync pairs, so caches/clocks settle per execution.~%")
        (format stream "        for (int _w = 0; _w < 20; ++_w) {~%")
        (format stream "            zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
        (format stream "            zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "        }~%~%")

        (format stream "        double _kt[BENCH_ITERS];~%")
        (format stream "        int _kn = 0;~%")
        (format stream "        double _total_s = 0.0;~%")
        (format stream "        for (int _it = 0; _it < BENCH_ITERS; ++_it) {~%")
        (format stream "            if (_tsOk) {~%")
        (format stream "                zeEventHostReset(_tsEvent);~%")
        (format stream "                zeCommandQueueExecuteCommandLists(cmdQueue, 1, &_measList, nullptr);~%")
        (format stream "                zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "                zeEventHostSynchronize(_tsEvent, UINT64_MAX);~%")
        (format stream "                ze_kernel_timestamp_result_t _ts = {};~%")
        (format stream "                if (zeEventQueryKernelTimestamp(_tsEvent, &_ts) != ZE_RESULT_SUCCESS) continue;~%")
        (format stream "                uint64_t _s = _ts.context.kernelStart & _clockMask;~%")
        (format stream "                uint64_t _e = _ts.context.kernelEnd   & _clockMask;~%")
        (format stream "                uint64_t _d = (_e >= _s) ? (_e - _s) : (_clockMask + 1 - _s + _e);~%")
        (format stream "                double _ns = _timerInHz ? ((double)_d * 1e9 / (double)_timerRes)~%")
        (format stream "                                        : ((double)_d * (double)_timerRes);~%")
        (format stream "                _kt[_kn++] = _ns / 1000.0;~%")
        (format stream "                _total_s += _ns / 1e9;~%")
        (format stream "            } else {~%")
        (format stream "                // Fallback if timestamp events are unavailable: wall clock around ONE~%")
        (format stream "                // submit + sync.  Includes launch overhead, but is still one execution~%")
        (format stream "                // per sample rather than one execution divided by BENCH_ITERS.~%")
        (format stream "                auto _w0 = std::chrono::high_resolution_clock::now();~%")
        (format stream "                zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
        (format stream "                zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "                auto _w1 = std::chrono::high_resolution_clock::now();~%")
        (format stream "                double _ws = std::chrono::duration<double>(_w1 - _w0).count();~%")
        (format stream "                _kt[_kn++] = _ws * 1e6;~%")
        (format stream "                _total_s += _ws;~%")
        (format stream "            }~%")
        (format stream "        }~%~%")

        (format stream "        // Median via insertion sort (BENCH_ITERS is small; avoids an <algorithm> include).~%")
        (format stream "        for (int _i = 1; _i < _kn; ++_i) {~%")
        (format stream "            double _v = _kt[_i]; int _j = _i - 1;~%")
        (format stream "            while (_j >= 0 && _kt[_j] > _v) { _kt[_j + 1] = _kt[_j]; --_j; }~%")
        (format stream "            _kt[_j + 1] = _v;~%")
        (format stream "        }~%")
        (format stream "        double _med_us = (_kn > 0) ? _kt[_kn / 2] : 0.0;~%")
        (format stream "        double _min_us = (_kn > 0) ? _kt[0] : 0.0;~%")
        (format stream "        double _flops = 2.0 * ~d.0 * ~d.0 * ~d.0;~%" m n k)
        (format stream "        double _gflops = (_med_us > 0.0) ? (_flops / (_med_us / 1e6) / 1e9) : 0.0;~%")
        (format stream "        std::cout << \"BENCH ~d ~d ~d \" << _gflops << \" GFLOPS (\" << _kn << \" iters, \" << _total_s << \" s)\"~%" m n k)
        (format stream "                  << \" median_us=\" << _med_us << \" min_us=\" << _min_us~%")
        (format stream "                  << (_tsOk ? \" method=kernel_timestamp\" : \" method=wallclock_per_iter\")~%")
        (format stream "                  << std::endl;~%")
        (format stream "        if (_measList) zeCommandListDestroy(_measList);~%")
        (format stream "        if (_tsEvent)  zeEventDestroy(_tsEvent);~%")
        (format stream "        if (_poolOk)   zeEventPoolDestroy(_pool);~%")
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
