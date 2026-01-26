(in-package :crisp.compiler)

;; 1. Permissive validate-template-arg
(defun validate-template-arg (arg type name)
  (cl:cond
    ((eq type 'T) t)
    ((typep arg type) t)
    ;; Permissive Fix: If arg is SYMBOL (but not keyword) and Type accepts the KEYWORD version
    ((cl:and (symbolp arg)
       (not (keywordp arg))
       (typep (intern (symbol-name arg) :keyword) type))
     t)
    (t (error "Template argument mismatch for ~a. Expected type ~a, got ~a (~a)"
         name type arg (type-of arg)))))

;; 2. Robust expand-storage-handle-type-specifier
(defun expand-storage-handle-type-specifier (spec)
  "Expands legacy/shorthand storage handle specs (cell, vector, etc) into their canonical struct form.
   e.g. (cell int) -> (cell int :global :read-write)
   e.g. (cell int :address-space :local) -> (cell int :local :read-write)
   
   ROBUSTNESS FIX (Regression Analysis):
   - Explicitly extracts known keys (:address-space, :access) and IGNORES others (like :direction).
   - Normalizes address-space symbols (GLOBAL) to keywords (:GLOBAL) to prevent type errors.
   - Ensures output is always a clean positional list for template instantiation."
  (log:info "EXPAND-STORAGE-HANDLE: ~s" spec)
  (cl:cond
    ((null spec) nil)
    ((symbolp spec) spec)
    ((consp spec)
     (cl:let ((base (first spec)))
       (if (and (symbolp base) (member (symbol-name base) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
           (if (null (rest spec))
               ;; Disallow bare (cell)
               (error 'crisp-incomplete-type-error :type-spec spec)

               (cl:let* ((args (rest spec))
                         (element-type (first args))
                         (rest-args (rest args)))

                 (if (null rest-args)
                     ;; Case: (CELL INT) -> Defaults
                     (list base element-type :global :read-write)

                     ;; Robust Parsing Logic
                     (cl:let ((addr :global)
                              (acc :read-write)
                              (remaining rest-args))
                       (cl:loop while remaining do
                         (cl:let ((item (pop remaining)))
                           (cl:cond
                             ;; 1. Address Space Flags/Keywords
                             ((cl:member (string item) '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC") :test #'string-equal)
                              (setf addr (intern (string-upcase (string item)) :keyword)))

                             ;; 2. Access Flags/Keywords
                             ((cl:member (string item) '("READ-WRITE" "READ-ONLY" "WRITE-ONLY" "READABLE" "WRITEABLE") :test #'string-equal)
                              (setf acc (intern (string-upcase (string item)) :keyword)))

                             ;; 3. Explicit Keys
                             ((string-equal (string item) "ADDRESS-SPACE")
                              (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
                              (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
                             ((string-equal (string item) "ACCESS")
                              (unless remaining (error "Missing value for :ACCESS in ~s" spec))
                              (setf acc (intern (string-upcase (string (pop remaining))) :keyword)))

                             ;; 4. Ignored Keys (Legacy compatibility if needed, strict otherwise)
                             ;; We MUST error on unknown keys to pass bad-type-constructor-02
                             (t
                              (error "Invalid type option: ~s in spec ~s" item spec)))))

                       ;; Return canonical positional form
                       (list base element-type addr acc)))))
           spec)))
    (t spec)))

;; Helper: Robust Template Lookup
(defun find-template-robust (name)
  (or (cl:gethash name *template-registry*)
      (cl:let ((found nil))
        (maphash (cl:lambda (k v)
                   (cl:when (and (symbolp k)
                                 (string-equal (symbol-name k) (symbol-name name)))
                     (cl:setf found v)))
                 *template-registry*)
        found)))

;; 3. Fixed resolve-type-to-llvm
(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference."
  (cl:let ((*resolve-depth* (1+ *resolve-depth*)))
    (cl:when (> *resolve-depth* 50)
      (cl:error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    (cl:cond
      ;; Built-in Scalar
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-types*))
       (cl:funcall (crisp-type-llvm-type-fn (cl:gethash type-spec *crisp-types*))))

      ;; Type Alias (Symbol)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-type-aliases*))
       (resolve-type-to-llvm (cl:gethash type-spec *crisp-type-aliases*)))

      ;; C-Pointer with properties: e.g. (c-pointer :address-space :global)
      ((cl:and (cl:consp type-spec) (cl:eq (cl:first type-spec) 'c-pointer))
       (cl:let* ((args (cl:rest type-spec))
                 (as-key (cl:getf args :address-space))
                 (as-val (encode-address-space as-key)))
         (llvm-pointer-type (llvm-int8-type) as-val)))

      ;; Struct (Pre-existing)
      ((cl:and (cl:symbolp type-spec) (find-struct-definition-by-name type-spec))
       (ensure-struct-llvm-type type-spec))

      ;; Enumerations (map to i32)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-enums*))
       (llvm-int32-type))

      ;; Keyword/Symbol/Quote (map to i32) - Handle Symbol and List forms
      ((cl:or (cl:member type-spec '(keyword symbol quote))
         (cl:and (cl:consp type-spec) (cl:member (cl:first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ;; We handle both (CELL ...) and CELL_INT_... here to support on-demand logic.
      ((cl:or (cl:and (cl:consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (cl:first type-spec)))
         (cl:and (cl:symbolp type-spec)
           (cl:let ((parts (unmangle-template-struct-name type-spec)))
             (cl:and parts (cl:consp parts) (find-template-robust (cl:first parts))))))

       ;; FIX: Ensure we use the CANONICALIZED specifier to instantiate/resolve
       ;; This leverages existing logic in expand-storage-handle-type-specifier
       ;; to clean up keywords and defaults.
       (cl:let* ((canonical (canonicalize-type-specifier type-spec))
                 (is-cons (cl:consp canonical))
                 (unmangled (cl:if is-cons canonical (unmangle-template-struct-name canonical)))
                 (base (cl:first unmangled))
                 (raw-args (cl:rest unmangled))
                 (mangled (mangle-template-struct-name base raw-args)))

         (cl:unless (find-struct-definition-by-name mangled)
           (cl:let ((crisp.compiler::*defer-struct-validation* nil))
             (ensure-template-instantiation base raw-args
                                            (cl:lambda (form location)
                                              (cl:eval form)
                                              (cl:when (cl:and (boundp '*current-module*) *current-module*)
                                                (compile-toplevel-form form location
                                                                       *current-module*
                                                                       *current-builder*
                                                                       *current-di-builder*
                                                                       *current-di-compile-unit*
                                                                       *current-location-map*))))))
         ;; Verify
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:error "Type Resolution: FAILED to instantiate struct ~a" mangled))

         ;; Recurse using the MANGLED name
         (resolve-type-to-llvm mangled)))

      ;; Generic List Wrapper
      ((cl:consp type-spec)
       (resolve-type-to-llvm (cl:first type-spec)))

      (t
       (cl:let ((alias-match (cl:loop for k being the hash-keys of *crisp-type-aliases*
                               when (cl:string-equal (cl:symbol-name k) (cl:symbol-name type-spec))
                               return k)))
         (cl:if alias-match
                (resolve-type-to-llvm (cl:gethash alias-match *crisp-type-aliases*))
                (cl:error "Cannot resolve type to LLVM: ~a" type-spec)))))))
