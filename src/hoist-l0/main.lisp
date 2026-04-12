(in-package :crisp.hoist.l0)

(defun main ()
  "Entry point for crisp-hoist-l0.exe"
  (handler-case
      (let ((args (uiop:command-line-arguments)))
        (format t "Crisp Hoist L0 - Level Zero C++ Launcher Generator~%")
        (format t "Version: 0.3.0~%~%")

        (unless args
          (format t "Usage: crisp-hoist-l0 <path-to-metacrisp-file>~%")
          (uiop:quit 1))

        (let ((metacrisp-path (first args)))
          (unless (probe-file metacrisp-path)
            (format t "Error: File not found: ~a~%" metacrisp-path)
            (uiop:quit 1))

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
    (let* ((field-name     (first member))
           (field-type-raw (second member))
           (field-name-cpp (format-cpp-identifier field-name))
           (field-path     (format nil "~a.~a" var-path field-name-cpp))
           (field-type     (resolve-type-alias field-type-raw aliases)))
      (cond
       ;; Array field — iota initialization: field[i] = (T)i
       ((%array-type-p field-type)
        (let* ((elem-type (%array-element-type field-type))
               (arr-size  (%array-size field-type))
               (elem-str  (crisp-type-to-cpp-type elem-type)))
          (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                  arr-size field-path elem-str)))
       ;; Nested struct — recurse
       ((struct-type-p-l0 field-type)
        (let* ((nested-def     (%find-struct-def-l0 field-type))
               (nested-members (cddr nested-def)))
          (%struct-emit-fields stream field-path nested-members aliases)))
       ;; Scalar field — type-appropriate constant
       (t
        (let* ((cpp-type (crisp-type-to-cpp-type field-type))
               (init-val (cond ((string= cpp-type "float")  "1.0f")
                               ((string= cpp-type "double") "1.0")
                               (t "1"))))
          (format stream "    ~a = ~a;~%" field-path init-val)))))))

(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file.
   Binds *hoist-current-structs* so generate-kernel-arguments-with-usm
   can identify and handle def-struct parameters."
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
               (comparable-range-start
                 (lambda (param)
                   (let ((r (getf param :range)))
                     (if (listp r) (first r) -1))))
               (full-sig      (sort (append declared-sig implicit-sig) #'<
                                    :key comparable-range-start))
               (output-targets (getf kernel :output-targets)))

          (let* ((spv-path-entry (or (assoc :spirv output-targets)
                                     (assoc :spv output-targets)))
                 (spv-path  (when spv-path-entry (second spv-path-entry)))
                 (suffix    (format nil "_~a" kernel-name))
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
                     (generate-cpp-main stream kernel-name spv-path full-sig aliases (metacrisp-records data))))
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
  (format stream "#include <cstdint>~%~%"))




(defun generate-cpp-structs (stream structs)
  "Generate C++ struct definitions from metadata.
   For (array T N) member types: emits 'T name[N]' for the field declaration
   and a loop in operator<< to print all elements space-separated.
   operator<< prints values space-separated (no field names, no braces)
   so HOIST-EXPECT substring checks work correctly."
  (when structs
    (format stream "// Struct Definitions~%")
    (dolist (struct-def structs)
      (let* ((struct-name     (second struct-def))
             (struct-name-str (substitute #\_ #\- (string-downcase (symbol-name struct-name))))
             (members         (cddr struct-def)))

        ;; Skip internal tensor/storage records — not needed in host C++ code.
        ;; They are def-record entries that exist only for the compiler's ABI bookkeeping.
        (unless (or (search "TENSOR_" (symbol-name struct-name) :test #'char-equal)
                    (search "STORAGE_" (symbol-name struct-name) :test #'char-equal))

          ;; Struct body
          (format stream "struct alignas(16) ~a {~%" struct-name-str)
          (dolist (member members)
            (let* ((member-name     (first member))
                   (member-type     (second member))
                   (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name)))))
              (if (%array-type-p member-type)
                  ;; Array field: T name[N]
                  (let* ((elem-type (%array-element-type member-type))
                         (arr-size  (%array-size member-type))
                         (elem-str  (crisp-type-to-cpp-type elem-type)))
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
              (let* ((member-name     (first member))
                     (member-type     (second member))
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

(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records)
  "Generate C++ main function"
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)

  ;; L0 Initialization
  (generate-l0-init stream)

  ;; Module loading
  (when spv-path
        (generate-module-loading stream spv-path))

  ;; Kernel creation and launch
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records)))

    ;; Print output buffers
    (format stream "    // Verify Output~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name))
            (ptr (getf alloc :ptr))
            (size-v (getf alloc :size-var)) ;; Need to capture size variable name
            (dir (getf alloc :direction))
            (access (getf alloc :access)))

        ;; Determine if we should print this buffer
        ;; Criterion: Explicit :out OR (no explicit :out exist AND is writeable)
        ;; For now, simplistic approach: Print anything that is NOT pure input.
        ;; :in pointers are initialized but USM is shared, so technically readable?
        ;; But usually we only care about side effects.
        ;; Let's try printing ALL buffers correctly typed.

        (format stream "    std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "    for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "        std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "    }~%")
        (format stream "    std::cout << std::endl;~%")))

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

(defun generate-kernel-launch (stream kernel-name declared-sig aliases records)
  "Generate kernel creation and launch code. Returns list of USM allocations."
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
          (setf allocations (generate-kernel-arguments-with-usm stream declared-sig aliases records "context" "device")))

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

    ;; Launch kernel
    (format stream "    // Launch kernel~%")
    (format stream "    // Set group size~%")
    (format stream "    result = zeKernelSetGroupSize(kernel, 1, 1, 1);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeKernelSetGroupSize failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")
    (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%")
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
      (let* ((field-sym       (first member))
             (field-type-raw  (second member))
             (field-type      (resolve-type-alias field-type-raw aliases))
             (field-name-cpp  (format-cpp-identifier field-sym))
             (field-path      (format nil "~a.~a" var-path field-name-cpp)))
        (cond
         ;; Array member — SROA: iota-init, then N individual zeKernelSetArgumentValue calls
         ((%array-type-p field-type)
          (let* ((elem-type (%array-element-type field-type))
                 (arr-size  (%array-size field-type))
                 (elem-str  (crisp-type-to-cpp-type elem-type)))
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
          (let* ((nested-def     (find-record-def field-type records))
                 (nested-members (cddr nested-def)))
            (setf idx (%record-field-args stream nested-members field-path idx records aliases))))
         ;; Scalar leaf — type-appropriate init, individual arg
         (t
          (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                 (init-val (cond ((string= cpp-type "float")  "1.0f")
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
;;; Layout strategy (test harness): EXTENT=4 per dim.
;;;
;;; :compact — tight row-major, strides in elements, innermost=1:
;;;   N=1: extents=[4],     strides=[1],      length=4
;;;   N=2: extents=[4,4],   strides=[4,1],    length=16
;;;   N=3: extents=[4,4,4], strides=[16,4,1], length=64
;;;
;;; :std140  — each innermost element padded to vec4 (4 elements = 16 bytes
;;;            for float/int, or 2 elements for double/int64):
;;;   N=1: extents=[4],     strides=[4],       length=16
;;;   N=2: extents=[4,4],   strides=[16,4],    length=64
;;;   N=3: extents=[4,4,4], strides=[64,16,4], length=256
;;;
;;; In both cases total USM elements = stride_0 * extent_0.
;;; The kernel uses runtime strides, so the same compiled .spv works for both;
;;; only the host-side stride values differ.
;;; -----------------------------------------------------------------------

(defun tensor-type-p (param-type)
  "Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier."
  (and (consp param-type)
       (symbolp (first param-type))
       (member (symbol-name (first param-type))
               '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))

(defun %tensor-compact-extents-strides (n dim-extent)
  "Returns (values extents strides) for a compact N-dim tensor.
   Strides are in elements; innermost stride = 1."
  (let* ((extents (make-list n :initial-element dim-extent))
         (strides (make-list n :initial-element 1)))
    (loop for k from (- n 2) downto 0 do
      (setf (nth k strides) (* (nth (1+ k) strides) dim-extent)))
    (values extents strides)))

(defun %tensor-std140-extents-strides (n dim-extent elem-str)
  "Returns (values extents strides) for a std140 N-dim tensor.
   Each innermost element is padded to a vec4 boundary.
   ELEM-STR is the C++ element type string used to determine the padding unit:
     double / int64_t / uint64_t -> padding-unit = 2 (2 × 8 bytes = 16 bytes)
     all others (float, int, ...)  -> padding-unit = 4 (4 × 4 bytes = 16 bytes)"
  (let* ((padding-unit (if (or (string-equal elem-str "double")
                               (string-equal elem-str "int64_t")
                               (string-equal elem-str "uint64_t"))
                           2
                           4))
         (extents (make-list n :initial-element dim-extent))
         ;; innermost stride = padding-unit (vec4 boundary)
         (strides (make-list n :initial-element padding-unit)))
    (loop for k from (- n 2) downto 0 do
      (setf (nth k strides) (* (nth (1+ k) strides) dim-extent)))
    (values extents strides)))

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells/tensors.
   Handles:
     cell           — 3 args (ptr, byte-size, offset); cell-of-(array T N) uses N-element USM
     tensor/vector/matrix — 3N+3 args (ptr, byte-size, off×N, str×N, ext×N, length)
     def-struct     — 1 arg (aggregate by value, sizeof struct)
     def-record     — exploded scalar args; array members are single by-value args
     (array T N)    — 1 arg, passed by value (iota-initialized T[N])
     scalar/dvec    — 1 arg"
  (format stream "    // Set up kernel arguments~%")
  (format stream "    ze_device_mem_alloc_desc_t deviceDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };~%")
  (format stream "    ze_host_mem_alloc_desc_t hostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%~%")

  (let ((arg-index  0)
        (allocations '()))

    (dolist (param declared-sig)
      (let* ((param-name  (getf param :name))
             (raw-type    (getf param :type))
             (param-type  (resolve-type-alias raw-type aliases))
             (param-dir   (getf param :direction))
             (param-as    (getf param :address-space))
             (is-local    (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond

         ;; ---- cell parameters (3 kernel args: ptr, byte-size, offset) ----
         ((cell-type-p param-type)
          (let* ((base-type      (cell-base-type param-type))
                 (is-array-cell  (%array-type-p base-type))
                 ;; Use crisp-type-to-cpp-type for both cases: fixes hyphens and long→int64_t
                 (base-type-str  (if is-array-cell
                                     (crisp-type-to-cpp-type (%array-element-type base-type))
                                     (crisp-type-to-cpp-type base-type)))
                 (elem-count     (if is-array-cell (%array-size base-type) 1))
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (size-var       (format nil "~a_size" param-name-cpp))
                 (ptr-var        (format nil "~a_ptr"  param-name-cpp)))

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
                     ;; Iota initialization for array cells: ptr[i] = (T)i
                     (format stream "    for (size_t _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                       size-var ptr-var base-type-str)
                     ;; Original initialization for scalar cells
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

                 (push (list :name     param-name
                             :ptr      ptr-var
                             :size-var size-var
                             :direction param-dir
                             :access   (getf param :access))
                       allocations)))

            (incf arg-index 3)))

         ;; ---- tensor/vector/matrix parameters (3N+3 kernel args) ----
         ((tensor-type-p param-type)
          (let* ((rank        (or (getf param :rank) 1))
                 (elem-type   (second param-type))
                 (align       (getf param :align))
                 (elem-str    (crisp-type-to-cpp-type elem-type))
                 (dim-extent  4)  ; test harness: 4 elements per dimension
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (ptr-var     (format nil "~a_ptr" param-name-cpp))
                 (size-var    (format nil "~a_len" param-name-cpp)))

            (let ((is-std140 (member align '(:std140 std140) :test
                                            (lambda (a b) (string-equal (string a) (string b))))))
            (multiple-value-bind (extents strides)
                (if is-std140
                    (%tensor-std140-extents-strides rank dim-extent elem-str)
                    (%tensor-compact-extents-strides rank dim-extent))
              (let* (;; total USM elements = stride_0 * extent_0 (works for both layouts)
                     (total-elems (* (first strides) (first extents)))
                     (offsets     (make-list rank :initial-element 0))
                     (elem-bytes  (if (or (string-equal elem-str "double")
                                         (string-equal elem-str "int64_t")
                                         (string-equal elem-str "uint64_t")) 8 4))
                     (byte-size   (* total-elems elem-bytes))
                     (layout-str  (if is-std140 "std140" "compact")))

                (format stream "~%    // Tensor argument: ~a (rank=~d, ~a, ~d elements, ~a)~%"
                        param-name rank elem-str total-elems layout-str)

                ;; Allocate USM
                (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
                (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
                        context-var)
                (format stream "        ~d * sizeof(~a), 1, ~a, (void**)&~a);~%"
                        total-elems elem-str device-var ptr-var)
                (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
                (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
                        param-name)
                (format stream "        return 1;~%")
                (format stream "    }~%")
                ;; Initialize: iota
                (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%"
                        total-elems ptr-var elem-str)

                ;; ABI order: PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1, EXT_0..N-1, LENGTH
                (format stream "    // Arg ~d: ~a PTR~%" arg-index param-name)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
                        arg-index ptr-var)
                (incf arg-index)

                (format stream "    // Arg ~d: ~a BYTE_SIZE = ~d~%" arg-index param-name byte-size)
                (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a OFFSET_~d = ~d~%" arg-index param-name k (nth k offsets))
                  (format stream "    uint64_t ~a_off~d = ~dULL;~%" param-name-cpp k (nth k offsets))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a STRIDE_~d = ~d~%" arg-index param-name k (nth k strides))
                  (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a EXTENT_~d = ~d~%" arg-index param-name k (nth k extents))
                  (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (format stream "    // Arg ~d: ~a LENGTH = ~d~%" arg-index param-name total-elems)
                (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp total-elems)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                ;; Push to allocations for copyback
                (push (list :name      param-name
                            :ptr       ptr-var
                            :size-var  (format nil "~d" total-elems)
                            :direction param-dir
                            :access    (getf param :access))
                      allocations))))))

         ;; ---- def-struct parameters (1 kernel arg: aggregate by value) ----
         ((struct-type-p-l0 param-type)
          (let* ((base-type      (%struct-base-type param-type))
                 (resolved-base  (resolve-type-alias base-type aliases))
                 (struct-def     (%find-struct-def-l0 resolved-base))
                 (struct-members (cddr struct-def))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (var-name       (format nil "~a_val" param-name-cpp))
                 (struct-type-str (format-cpp-identifier resolved-base)))
            (format stream "~%    // Struct argument: ~a (~a)~%" param-name struct-type-str)
            (format stream "    ~a ~a;~%" struct-type-str var-name)
            (%struct-emit-fields stream var-name struct-members aliases)
            (format stream "    // Arg ~d: ~a~%" arg-index param-name)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a);~%~%"
              arg-index struct-type-str var-name)
            (incf arg-index)))

         ;; ---- def-record parameters (exploded to scalar args) ----
         ((record-type-p param-type records)
          (let* ((base-type    (record-base-type param-type))
                 (record-def   (find-record-def param-type records))
                 (record-members (cddr record-def))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (var-name       (format nil "~a_val" param-name-cpp))
                 (struct-type-str (format-cpp-identifier base-type)))
            (format stream "~%    // Record argument: ~a (~a)~%" param-name struct-type-str)
            (format stream "    ~a ~a;~%" struct-type-str var-name)
            (setf arg-index (%record-field-args stream record-members var-name arg-index records aliases))
            (format stream "~%")))

         ;; ---- (array T N) direct parameters (1 arg, by value, iota-initialized) ----
         ((%array-type-p param-type)
          (let* ((elem-type      (%array-element-type param-type))
                 (arr-size       (%array-size param-type))
                 (elem-type-str  (crisp-type-to-cpp-type elem-type))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (arr-var        (format nil "~a_arg" param-name-cpp)))
            (format stream "~%    // Array argument: ~a (~a ~a[~a])~%"
                    param-name elem-type-str param-name-cpp arr-size)
            (format stream "    ~a ~a[~a];~%" elem-type-str arr-var arr-size)
            (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                    arr-size arr-var elem-type-str)
            (format stream "    // Arg ~d: ~a~%" arg-index param-name)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a * sizeof(~a), ~a);~%~%"
                    arg-index arr-size elem-type-str arr-var)
            (incf arg-index)))

         ;; ---- scalar parameters ----
         ((symbolp param-type)
          (let* ((type-str (crisp-type-to-cpp-type param-type)))
            (multiple-value-bind (dvec-base dvec-width) (%dvec-parse param-type)
              (if dvec-base
                  ;; Device vector: aggregate init {N, N+1, ...}
                  (let ((init-str (format nil "{~{~a~^, ~}}"
                                          (loop for i from 0 below dvec-width
                                                collect (+ arg-index 42 i)))))
                    (format stream "    ~a ~a_arg = ~a;~%" type-str param-name init-str)
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name))
                  ;; Regular scalar
                  (progn
                    (format stream "    ~a ~a_arg = ~d;  // TODO: Set actual value~%"
                      type-str param-name (+ arg-index 42))
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name)))))
          (incf arg-index)))))

    (nreverse allocations)))
