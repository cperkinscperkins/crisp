(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;; -----------------------------------------------------------------------
;; Device vector type support in generated C++
;; src/hoist-l0/main.lisp  (generate-l0-launcher, generate-kernel-arguments-with-usm)
;; src/hoist/codegen-base.lisp  (support helpers)
;; -----------------------------------------------------------------------
#|
(defun %dvec-parse (type-sym)
  "If TYPE-SYM names a device vector type (e.g. USHORT2, FLOAT4), returns
   (values base-name width) where base-name is a lowercase string (e.g. \"ushort\")
   and width is an integer (2, 3, or 4).  Returns NIL if not a device vector type."
  (when (symbolp type-sym)
    (let* ((name (string-downcase (symbol-name type-sym)))
           (len (length name)))
      (when (> len 1)
        (let ((last-ch (char name (1- len))))
          (when (member last-ch (list #\2 #\3 #\4))
            (let* ((width (digit-char-p last-ch))
                   (base (subseq name 0 (1- len))))
              (when (member base
                            '("char" "uchar" "short" "ushort" "int" "uint"
                              "long" "ulong" "half" "float" "double")
                            :test #'string=)
                (values base width)))))))))

(defun %dvec-cpp-scalar-type (base-name)
  "Map a Crisp scalar base name (e.g. \"ushort\") to a C++ <cstdint> type string."
  (cond
    ((string= base-name "char")   "int8_t")
    ((string= base-name "uchar")  "uint8_t")
    ((string= base-name "short")  "int16_t")
    ((string= base-name "ushort") "uint16_t")
    ((string= base-name "int")    "int32_t")
    ((string= base-name "uint")   "uint32_t")
    ((string= base-name "long")   "int64_t")
    ((string= base-name "ulong")  "uint64_t")
    ((string= base-name "half")   "uint16_t")
    ((string= base-name "float")  "float")
    ((string= base-name "double") "double")
    (t base-name)))

(defun %emit-dvec-typedef (stream type-sym)
  "Emit a C++ struct definition for a device vector type (e.g. ushort2).
   Uses <cstdint> types for the members.
   Uses 'struct NAME { };' (not typedef struct) so that the type name is in scope
   inside the body, which is required for the friend operator<< declaration.
   The operator<< prints space-separated components, matching the HOIST-EXPECT
   substring-match convention."
  (multiple-value-bind (base width) (%dvec-parse type-sym)
    (when base
      (let* ((type-str (string-downcase (symbol-name type-sym)))
             (scalar-type (%dvec-cpp-scalar-type base))
             (member-names (subseq (list "x" "y" "z" "w") 0 width)))
        (format stream "struct ~a {~%" type-str)
        (dolist (m member-names)
          (format stream "    ~a ~a;~%" scalar-type m))
        (format stream "    friend std::ostream& operator<<(std::ostream& os, const ~a& v) {~%" type-str)
        (let ((firstp t))
          (dolist (m member-names)
            (if firstp
                (format stream "        os << v.~a" m)
                (format stream " << \" \" << v.~a" m))
            (setf firstp nil)))
        (format stream ";~%")
        (format stream "        return os;~%")
        (format stream "    }~%")
        (format stream "};~%~%" type-str)))))

(defun %collect-dvec-types (declared-sig aliases)
  "Collect all distinct device vector type symbols used in DECLARED-SIG and ALIASES.
   Checks cell element types from aliases and direct scalar param types.
   Returns a deduplicated list ordered by first appearance."
  (let ((seen (make-hash-table :test #'equal))
        (result '()))
    (flet ((add-if-dvec (type-sym)
             (when (and (symbolp type-sym)
                        (%dvec-parse type-sym)
                        (not (gethash (symbol-name type-sym) seen)))
               (setf (gethash (symbol-name type-sym) seen) t)
               (push type-sym result))))
      ;; From aliases: (def-type NAME (CELL TYPE ...)) — extract cell element type
      (dolist (alias aliases)
        (when (and (listp alias) (>= (length alias) 3))
          (let ((cell-spec (third alias)))
            (when (cell-type-p cell-spec)
              (add-if-dvec (second cell-spec))))))
      ;; From declared-sig: direct scalar params whose type is a device vector
      (dolist (param declared-sig)
        (add-if-dvec (getf param :type))))
    (nreverse result)))

(defun generate-cpp-dvec-typedefs (stream dvec-types)
  "Emit C++ typedef structs for all device vector types in DVEC-TYPES.
   Called from generate-l0-launcher after generate-cpp-typedefs."
  (when dvec-types
    (format stream "// Device vector type definitions~%")
    (dolist (type-sym dvec-types)
      (%emit-dvec-typedef stream type-sym))))

      |#

;; src/hoist-l0/main.lisp
;; Fix: collect device vector types used in the kernel and emit C++ typedef structs
;; so that ushort2, float4, etc. are defined before they are referenced in the
;; USM allocation and kernel argument code.
#|
(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file"
  (let* ((data (parse-metacrisp-file metacrisp-path))
         (kernels (metacrisp-kernels data))
         (aliases (metacrisp-aliases data))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    (when (null kernels)
      (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    (dolist (kernel kernels)
      (let* ((kernel-name (getf kernel :name))
             (declared-sig (getf kernel :declared-signature))
             (implicit-sig (getf kernel :implicit-params))
             (comparable-range-start (lambda (param)
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
              (format t "WARNING: No SPIR-V target found for kernel ~a. Skipping host generation.~%" kernel-name)
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
               (format t "  Done: ~a~%" (namestring output-path)))))))))
               |#

;; src/hoist-l0/main.lisp
;; Fix: device vector scalar params (e.g. ushort2 v2_arg) cannot be initialized
;; as a plain integer literal.  Use aggregate init {N, N+1, ...} matching the
;; existing (+ arg-index 42) placeholder pattern so the values are non-zero
;; and distinguishable for manual inspection.
#|
(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells"
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
         ;; Handle cell parameters (pointers/buffers)
         ((cell-type-p param-type)
           (let* ((base-type (cell-base-type param-type))
                  (base-type-str (string-downcase (symbol-name base-type)))
                  (param-name-cpp (substitute #\_ #\- param-name))
                  (size-var (format nil "~a_size" param-name-cpp))
                  (ptr-var (format nil "~a_ptr" param-name-cpp)))

             (if is-local
                 ;; --- LOCAL MEMORY ---
                 (progn
                  (format stream "~%    // Configure LOCAL memory for ~a~%" param-name)
                  (format stream "    size_t ~a = 1;  // Cell is a single scalar~%" size-var)
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
                  (format stream "    size_t ~a = 1;  // Cell is a single scalar~%" size-var)
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
                  (format stream "    memset(~a, 0, ~a * sizeof(~a));~%" ptr-var size-var base-type-str)

                  (when (or (eq param-dir :in) (eq param-dir :read-write))
                        (format stream "    for (size_t i = 0; i < ~a; i++) {~%" size-var)
                        (format stream "        // Dangerous for structs if index exceeds member bounds, but fine for now~%")
                        (format stream "    }~%"))

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

                  (push (list :name param-name
                              :ptr ptr-var
                              :size-var size-var
                              :direction param-dir
                              :access (getf param :access))
                        allocations)))

             (incf arg-index 3)))

         ;; Handle record parameters (exploded to individual scalar kernel args)
         ((record-type-p param-type records)
           (let* ((base-type (record-base-type param-type))
                  (record-def (find-record-def param-type records))
                  (record-members (cddr record-def))
                  (param-name-cpp (format-cpp-identifier param-name))
                  (var-name (format nil "~a_val" param-name-cpp))
                  (struct-type-str (format-cpp-identifier base-type)))
             (format stream "~%    // Record argument: ~a (~a)~%" param-name struct-type-str)
             (format stream "    ~a ~a;~%" struct-type-str var-name)
             (setf arg-index (%record-field-args stream record-members var-name arg-index records aliases))
             (format stream "~%")))

         ;; Handle scalar parameters
         ((symbolp param-type)
           (let* ((type-str (string-downcase (symbol-name param-type))))
             (multiple-value-bind (dvec-base dvec-width) (%dvec-parse param-type)
               (if dvec-base
                   ;; Device vector: aggregate init {N, N+1, ...} matching the
                   ;; existing (+ arg-index 42) placeholder pattern
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
    |#
