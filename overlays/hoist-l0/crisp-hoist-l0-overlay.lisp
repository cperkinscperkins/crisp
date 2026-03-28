(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


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

(defun %struct-emit-fields (stream var-path members aliases)
  "Recursively emit C++ field assignments for a struct variable at VAR-PATH.
   MEMBERS is the member list from the (def-struct NAME ...) form: each member
   is (FIELD-NAME TYPE).  Nested structs are recursed into."
  (dolist (member members)
    (let* ((field-name     (first member))
           (field-type-raw (second member))
           (field-name-cpp (format-cpp-identifier field-name))
           (field-path     (format nil "~a.~a" var-path field-name-cpp))
           (field-type     (resolve-type-alias field-type-raw aliases)))
      (cond
        ;; Nested struct — recurse
        ((struct-type-p-l0 field-type)
         (let* ((nested-def     (%find-struct-def-l0 field-type))
                (nested-members (cddr nested-def)))
           (%struct-emit-fields stream field-path nested-members aliases)))
        ;; Scalar field — use type-appropriate default
        (t
         (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                (init-val (cond ((string= cpp-type "float")  "1.0f")
                                ((string= cpp-type "double") "1.0")
                                (t "1"))))
           (format stream "    ~a = ~a;~%" field-path init-val)))))))


;;; -----------------------------------------------------------------------
;;; Redefine generate-l0-launcher to bind *hoist-current-structs*
;;; src/hoist-l0/main.lisp
;;; -----------------------------------------------------------------------

;; src/hoist-l0/main.lisp
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


;;; -----------------------------------------------------------------------
;;; Redefine generate-kernel-arguments-with-usm to add struct branch
;;; src/hoist-l0/main.lisp
;;;
;;; Struct params are a single aggregate argument.  The host declares a
;;; local C++ struct variable, sets all runtime fields to default values,
;;; and calls zeKernelSetArgumentValue(kernel, idx, sizeof(TYPE), &var).
;;; -----------------------------------------------------------------------

;; src/hoist-l0/main.lisp
(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells.
   Handles cell (3 args: ptr, size, offset), def-struct (1 arg: aggregate),
   def-record (exploded scalar args), and plain scalar parameters."
  (format stream "    // Set up kernel arguments~%")
  (format stream "    ze_device_mem_alloc_desc_t deviceDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };~%")
  (format stream "    ze_host_mem_alloc_desc_t hostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%~%")

  (let ((arg-index 0)
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
          (let* ((base-type     (cell-base-type param-type))
                 (base-type-str (string-downcase (symbol-name base-type)))
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (size-var  (format nil "~a_size" param-name-cpp))
                 (ptr-var   (format nil "~a_ptr" param-name-cpp)))

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

         ;; ---- def-struct parameters (1 kernel arg: aggregate by value) ----
         ((struct-type-p-l0 param-type)
          (let* ((base-type     (%struct-base-type param-type))
                 (resolved-base (resolve-type-alias base-type aliases))
                 (struct-def    (%find-struct-def-l0 resolved-base))
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

         ;; ---- def-record parameters (exploded to individual scalar args) ----
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

         ;; ---- scalar parameters ----
         ((symbolp param-type)
          (let* ((type-str (string-downcase (symbol-name param-type))))
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


;;; -----------------------------------------------------------------------
;;; Redefine generate-cpp-structs to print struct values space-separated
;;; src/hoist-l0/main.lisp
;;;
;;; The original operator<< format is "{x=15 y=0}" which is incompatible
;;; with HOIST-EXPECT substring checks like "BUFFER c: 15".
;;; New format: values only, space-separated → "15 0"
;;; This makes "BUFFER c: 15 0" contain "BUFFER c: 15" as substring. ✓
;;; -----------------------------------------------------------------------

;; src/hoist-l0/main.lisp
(defun generate-cpp-structs (stream structs)
  "Generate C++ struct definitions from metadata.
   operator<< prints field values space-separated (no field names, no braces)
   so HOIST-EXPECT substring checks like 'BUFFER c: 15' work correctly."
  (when structs
    (format stream "// Struct Definitions~%")
    (dolist (struct-def structs)
      (let* ((struct-name (second struct-def))
             (struct-name-str (substitute #\_ #\- (string-downcase (symbol-name struct-name))))
             (members (cddr struct-def)))
        (format stream "struct alignas(16) ~a {~%" struct-name-str)
        (dolist (member members)
          (let* ((member-name (first member))
                 (member-type (second member))
                 (member-name-str (substitute #\_ #\- (string-downcase (symbol-name member-name))))
                 (member-type-str (substitute #\_ #\- (string-downcase (symbol-name member-type)))))
            (format stream "    ~a ~a;~%" member-type-str member-name-str)))
        (format stream "    friend std::ostream& operator<<(std::ostream& os, const ~a& obj) {~%" struct-name-str)
        (let ((first-member t))
          (dolist (member members)
            (let ((member-name-str (substitute #\_ #\- (string-downcase (symbol-name (first member))))))
              (unless first-member
                (format stream "        os << \" \";~%"))
              (setf first-member nil)
              (format stream "        os << obj.~a;~%" member-name-str))))
        (format stream "        return os;~%")
        (format stream "    }~%")
        (format stream "};~%~%")))))
