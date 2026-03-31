(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;;; =========================================================
;;; Array type support for L0 hoisting
;;; Fixes: generate-cpp-structs, %struct-emit-fields,
;;;        %record-field-args, generate-kernel-arguments-with-usm
;;; New:   %array-type-p, %array-element-type, %array-size,
;;;        crisp-type-to-cpp-type (array case)
;;; =========================================================


;; ---- Array type predicates / accessors ---- (src/hoist-l0/main.lisp)

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


;; ---- crisp-type-to-cpp-type extended for arrays ---- (src/hoist/codegen-base.lisp)

(in-package :crisp.hoist)

(defun crisp-type-to-cpp-type (crisp-type)
  "Convert a Crisp type to a C++ type string.
   For (array T N) returns the element type's C++ name — used for sizeof
   and pointer declarations in array argument handling."
  (cond
   ((symbolp crisp-type)
     (case crisp-type
       (int    "int")
       (uint   "unsigned int")
       (long   "long")
       (ulong  "unsigned long")
       (float  "float")
       (double "double")
       (voidp  "void*")
       (t (string-downcase (symbol-name crisp-type)))))
   ;; (array T N) — resolve to element C++ type
   ((and (consp crisp-type)
         (symbolp (first crisp-type))
         (string-equal (symbol-name (first crisp-type)) "ARRAY"))
     (crisp-type-to-cpp-type (second crisp-type)))
   ((consp crisp-type)
     (format nil "/* TODO: ~a */" crisp-type))
   (t (format nil "/* UNKNOWN: ~a */" crisp-type))))

(in-package :crisp.hoist.l0)


;; ---- generate-cpp-structs: handle (array T N) members ---- (src/hoist-l0/main.lisp)

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
                ;; Scalar/nested-struct field
                (let ((member-type-str (substitute #\_ #\- (string-downcase (symbol-name member-type)))))
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
                  ;; Scalar field
                  (progn
                    (unless first-member
                      (format stream "        os << \" \";~%"))
                    (format stream "        os << obj.~a;~%" member-name-str)))
              (setf first-member nil))))
        (format stream "        return os;~%")
        (format stream "    }~%")
        (format stream "};~%~%")))))


;; ---- %struct-emit-fields: iota-init for array-typed fields ---- (src/hoist-l0/main.lisp)

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


;; ---- %record-field-args: array member as single by-value arg ---- (src/hoist-l0/main.lisp)

(defun %record-field-args (stream members var-path arg-index records aliases)
  "Recursively emit field initialization and zeKernelSetArgumentValue calls
   for all leaf fields of a record, following nested records.
   Array-typed members are iota-initialized and passed as a single by-value arg
   (matching the physical signature which keeps (array T N) as one slot).
   Returns the updated arg-index after consuming all fields."
  (let ((idx arg-index))
    (dolist (member members)
      (let* ((field-sym       (first member))
             (field-type-raw  (second member))
             (field-type      (resolve-type-alias field-type-raw aliases))
             (field-name-cpp  (format-cpp-identifier field-sym))
             (field-path      (format nil "~a.~a" var-path field-name-cpp)))
        (cond
         ;; Array member — iota init, single by-value zeKernelSetArgumentValue
         ((%array-type-p field-type)
          (let* ((elem-type (%array-element-type field-type))
                 (arr-size  (%array-size field-type))
                 (elem-str  (crisp-type-to-cpp-type elem-type)))
            (format stream "    // Iota-init array member ~a~%" field-path)
            (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                    arr-size field-path elem-str)
            (format stream "    // Arg ~d: ~a (array ~a[~a] by value)~%"
                    idx field-path elem-str arr-size)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a * sizeof(~a), ~a);~%"
                    idx arr-size elem-str field-path)
            (incf idx)))
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


;; ---- generate-kernel-arguments-with-usm: array branch + cell-of-array fix ----
;; (src/hoist-l0/main.lisp)

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells.
   Handles:
     cell           — 3 args (ptr, byte-size, offset); cell-of-(array T N) uses N-element USM
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
                 (base-type-str  (if is-array-cell
                                     (crisp-type-to-cpp-type (%array-element-type base-type))
                                     (string-downcase (symbol-name base-type))))
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
                     (progn
                       (format stream "    memset(~a, 0, ~a * sizeof(~a));~%" ptr-var size-var base-type-str)
                       (when (or (eq param-dir :in) (eq param-dir :read-write))
                         (format stream "    for (size_t i = 0; i < ~a; i++) {~%" size-var)
                         (format stream "        // Dangerous for structs if index exceeds member bounds, but fine for now~%")
                         (format stream "    }~%"))))

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


;;; =========================================================
;;; Fix: crisp-type-to-cpp-type — package-agnostic + long→int64_t
;;; The earlier version used `case` (eql), which fails when metacrisp-parsed
;;; symbols are interned in :crisp.hoist.l0, not :crisp.hoist. Replace with
;;; cond + string-equal. Also fix: long→int64_t, ulong→uint64_t (Windows ABI).
;;; =========================================================

(in-package :crisp.hoist)

;; src/hoist/codegen-base.lisp
(defun crisp-type-to-cpp-type (crisp-type)
  "Convert a Crisp type to a C++ type string.
   Uses string-equal for package-agnostic symbol comparison so that
   symbols interned in any package (e.g. :crisp.hoist.l0 during metacrisp
   parsing) are handled correctly.
   Maps long→int64_t, ulong→uint64_t (64-bit on all platforms).
   Fallback: hyphens converted to underscores (safe for C++ identifiers).
   For (array T N): resolves element type."
  (cond
    ((null crisp-type) "void")
    ((symbolp crisp-type)
     (let ((name (symbol-name crisp-type)))
       (cond
         ((string-equal name "INT")    "int")
         ((string-equal name "UINT")   "unsigned int")
         ((string-equal name "LONG")   "int64_t")
         ((string-equal name "ULONG")  "uint64_t")
         ((string-equal name "FLOAT")  "float")
         ((string-equal name "DOUBLE") "double")
         ((string-equal name "CHAR")   "char")
         ((string-equal name "UCHAR")  "unsigned char")
         ((string-equal name "SHORT")  "short")
         ((string-equal name "USHORT") "unsigned short")
         ((string-equal name "BOOL")   "bool")
         ((string-equal name "VOIDP")  "void*")
         (t (substitute #\_ #\- (string-downcase name))))))
    ;; (array T N) — resolve to element C++ type
    ((and (consp crisp-type)
          (symbolp (first crisp-type))
          (string-equal (symbol-name (first crisp-type)) "ARRAY"))
     (crisp-type-to-cpp-type (second crisp-type)))
    ((consp crisp-type)
     (format nil "/* TODO: ~a */" crisp-type))
    (t (format nil "/* UNKNOWN: ~a */" crisp-type))))

(in-package :crisp.hoist.l0)


;;; =========================================================
;;; Fix: generate-kernel-arguments-with-usm — cell branch
;;; Use crisp-type-to-cpp-type for base-type-str in non-array cell case.
;;; The earlier version used (string-downcase (symbol-name base-type)) which:
;;;   (a) leaves hyphens in C++ identifiers (e.g. "data-block" → compile error)
;;;   (b) gets long wrong (stays "long", should be "int64_t")
;;; =========================================================

;; src/hoist-l0/main.lisp
(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells.
   Handles:
     cell           — 3 args (ptr, byte-size, offset); cell-of-(array T N) uses N-element USM
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
