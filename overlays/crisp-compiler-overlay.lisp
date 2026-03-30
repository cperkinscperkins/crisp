;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; Phase 1: (array T N) type system support
;;; ============================================================

;;; src/types/validation.lisp
(defun %array-type-p (type-spec)
  "Returns T if TYPE-SPEC is a list form whose head is the symbol ARRAY.
   Used throughout the array implementation to identify (array T N) type specs."
  (and (consp type-spec)
       (symbolp (cl:first type-spec))
       (string-equal (symbol-name (cl:first type-spec)) "ARRAY")))

;;; src/types/validation.lisp
(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, array, etc).
   Extended to recognise (array T N) where T is a valid non-array basic type
   and N is a positive integer.  Nested arrays signal a crisp-compiler-error."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (cl:rest expanded)))
      (cl:cond
        ;; Base type must be a symbol
        ((not (symbolp base-type)) nil)

        ;; Exclude special forms (FUNCTION, QUOTE, etc.)
        ((excluded-template-base-type-p base-type) nil)

        ;; (array T N) — compile-time fixed array type
        ((%array-type-p expanded)
         (cl:let ((elem-type (cl:first params))
                  (count     (cl:second params)))
           ;; Nesting is illegal — signal a named error so CHECK-FAIL: "nested" matches
           (cl:when (%array-type-p elem-type)
             (error 'crisp-compiler-error
                    :message (format nil "Array type cannot be nested: ~s is illegal. Use def-struct or a cell instead."
                                     type-spec)))
           ;; Validate: exactly 2 args, valid non-array element type, positive integer count
           (and (= (cl:length params) 2)
                (valid-basic-type-p elem-type)
                (integerp count)
                (> count 0))))

        ;; Handle valid struct/type with optional keyword properties
        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params)
                  (keywordp (cl:first params))))
         t)

        ;; Standard template instantiation
        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

        (t nil)))))

;;; src/types/validation.lisp
(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference.
   Extended to handle (array T N) → LLVM [N x T_llvm]."
  (cl:let ((*resolve-depth* (1+ *resolve-depth*)))
    (cl:when (> *resolve-depth* 50)
      (cl:error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    (cl:cond
      ;; (array T N) → [N x T_llvm]
      ((%array-type-p type-spec)
       (cl:let* ((elem-type (cl:second type-spec))
                 (count-raw (cl:third type-spec))
                 ;; count may be a symbol like |5| after unmangle; coerce to integer
                 (count (etypecase count-raw
                          (integer count-raw)
                          (symbol  (parse-integer (symbol-name count-raw))))))
         (log:info "resolve-type-to-llvm: (array ~a ~a) -> [~a x ...]" elem-type count count)
         ;; llvm-array-type not yet exported from package.lisp — use :: until patched
         (crisp.llvm-bindings::llvm-array-type (resolve-type-to-llvm elem-type) count)))

      ;; Derived Type - resolve to base type (MUST come before *crisp-types* check)
      ((cl:and (cl:symbolp type-spec)
         (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                   (node-alt (cl:when (not node-direct)
                               (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                      (cl:find-package :crisp-language))
                                           *type-derivation-graph*)))
                   (node (or node-direct node-alt)))
           (and node (type-node-original-type node))))
       (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                 (node-alt (cl:when (not node-direct)
                             (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                    (cl:find-package :crisp-language))
                                         *type-derivation-graph*)))
                 (actual-type (if node-direct type-spec
                                  (cl:intern (cl:symbol-name type-spec)
                                             (cl:find-package :crisp-language))))
                 (base-type (get-type-base actual-type)))
         (resolve-type-to-llvm base-type)))

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

      ;; Keyword/Symbol/Quote (map to i32)
      ((cl:or (cl:member type-spec '(keyword symbol quote))
         (cl:and (cl:consp type-spec) (cl:member (cl:first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ((cl:or (cl:and (cl:consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (cl:first type-spec)))
         (cl:and (cl:symbolp type-spec)
           (cl:let ((parts (unmangle-template-struct-name type-spec)))
             (cl:and parts (cl:consp parts) (find-template-robust (cl:first parts))))))
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
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:error "Type Resolution: FAILED to instantiate struct ~a" mangled))
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

;;; ============================================================
;;; Phase 5: (array T N) as def-struct member
;;; ============================================================

;;; src/structs.lisp
(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
   Extended to handle (array T N): arrays align to 16 bytes (vec4) per std140."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> 16-byte alignment per std140 array rules
      ((%array-type-p type-spec) 16)
      ((%array-type-p alias-resolved) 16)
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((or (eq resolved-type 'bool)) 4)
      ((eq type-spec 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ((gethash type-spec *crisp-structs*) 16)
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (cl:first type-spec) (cl:rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  16
                  (error "Valid type ~a but struct def not found after check alignment." type-spec)))))))
      (t (error "Unknown type for alignment: ~a" type-spec)))))

;;; src/structs.lisp
(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type.
   Extended to handle (array T N): size is N * element-size, rounded up to 16-byte stride per std140."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> N * ceil(elem-size, 16) per std140 array element stride
      ((%array-type-p type-spec)
       (cl:let* ((elem-type (cl:second type-spec))
                 (n         (cl:third type-spec))
                 (elem-size (get-std140-size elem-type))
                 ;; std140: each array element is padded to vec4 (16-byte) stride
                 (stride    (+ elem-size (calculate-std140-padding elem-size 16))))
         (* n stride)))
      ((%array-type-p alias-resolved)
       (get-std140-size alias-resolved))
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let* ((mangled (mangle-template-struct-name (cl:first type-spec) (cl:rest type-spec)))
                      (struct-info (gethash mangled *crisp-structs*)))
              (if struct-info
                  (crisp-struct-definition-total-size struct-info)
                  (error "Valid type ~a but struct def not found for size." type-spec)))))))
      (t (error "Unknown type for size: ~a" type-spec)))))

;;; ============================================================
;;; Phase 2: length~ special form
;;; ============================================================

;;; src/analysis/control.lisp  (register in src/analysis/control.lisp register-control-analyzers)
(defun analyze-length-tilde-expression (expr env context location)
  "Analyzes (length~ arr) — returns the compile-time array length N as a ulong literal.
   The argument must be a variable or expression whose type resolves to (array T N).
   Signals a crisp-compiler-error if the argument is not an array type."
  (unless (= (cl:length expr) 2)
    (error 'crisp-compiler-error
           :message "length~ expects exactly 1 argument: (length~ arr)"
           :source-location location))
  (let* ((arg-node  (analyze-expression (cl:second expr) env context location))
         (arg-type  (let ((raw (semantic-node-type arg-node)))
                      ;; Unwrap single-element list from function call return types
                      (resolve-type-alias
                       (if (and (listp raw) (= (cl:length raw) 1) (listp (cl:first raw)))
                           (cl:first raw)
                           raw)))))
    (unless (%array-type-p arg-type)
      (error 'crisp-compiler-error
             :message (format nil "length~~ requires an (array T N) type, got ~a" arg-type)
             :source-location location))
    (let* ((n-raw (cl:third arg-type))
           ;; n-raw may be a symbol like |5| after unmangle; coerce to integer
           (n (etypecase n-raw
                (integer n-raw)
                (symbol  (parse-integer (symbol-name n-raw))))))
      (log:info "length~~: type=~a -> N=~a" arg-type n)
      (make-semantic-literal :value-type 'ulong
                             :value (coerce n '(unsigned-byte 64))
                             :source-location location))))

;;; src/analysis/control.lisp
;;; Redefine register-control-analyzers to include length~.
;;; Must mirror the original body exactly and append the new registration.
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including length~ for arrays."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  ;; Phase 2: array length~ special form
  ;; Register in both packages: source is read in :crisp-language, overlay runs in :crisp.compiler.
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression)))

;;; ============================================================
;;; Phase 3: (array T N) aref / set! codegen
;;; ============================================================

;;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-aref) builder module var-env di-builder di-scope location-map)
  "Generates IR for array/cell access (aref / ~).
   Case 1: CELL parameterized type  — existing behaviour unchanged.
   Case 2: (array T N) fixed-size array — GEP into the alloca (or pointer).
     For a simple var-read of type (array T N), the alloca is fetched directly
     from var-env so we never load the aggregate value before GEP-ing into it.
     Returns (loaded-elem, nil, elem-ptr) so that set! can store through the pointer."
  (let* ((array-node   (semantic-aref-array-node node))
         (index-node   (semantic-aref-index-node node))
         ;; Unwrap single-element list types produced by function-call return types
         ;; e.g. ((array float 4)) -> (array float 4)
         (array-type   (let ((raw (semantic-node-type array-node)))
                         (if (and (listp raw) (= (cl:length raw) 1) (listp (cl:first raw)))
                             (cl:first raw)
                             raw)))
         (element-type (semantic-aref-type node))
         (index-val    (generate-node-ir index-node builder module var-env
                                         di-builder di-scope location-map)))

    (let ((cell-spec (let* ((resolved (resolve-type-alias array-type))
                            (canon    (canonicalize-type-specifier resolved)))
                       (cond
                        ((and (listp canon) (eq (cl:first canon) 'cell)) canon)
                        ((and (listp canon) (= (cl:length canon) 1) (symbolp (cl:first canon)))
                         (unmangle-template-struct-name (cl:first canon)))
                        ((symbolp canon)
                         (unmangle-template-struct-name canon))
                        (t canon)))))

      (cond
       ;; Case 2: (array T N) — fixed-size array GEP
       ((%array-type-p (resolve-type-alias array-type))
        (let* ((resolved-arr-type (resolve-type-alias array-type))
               (elem-type-spec    (cl:second resolved-arr-type))
               ;; count may be a symbol like |5| after unmangle; coerce to integer
               (count-raw         (cl:third  resolved-arr-type))
               (count             (etypecase count-raw
                                    (integer count-raw)
                                    (symbol  (parse-integer (symbol-name count-raw)))))
               (elem-llvm-type    (crisp-type-to-llvm-type elem-type-spec module))
               (arr-llvm-type     (crisp.llvm-bindings::llvm-array-type elem-llvm-type count))
               ;; Get the array pointer.
               ;; For a direct var-read, grab the alloca from var-env so we avoid
               ;; loading the aggregate value (which is useless for GEP).
               ;; For a nested expression that returns a pointer (e.g. cell-of-array),
               ;; use that pointer directly.
               ;; For a nested expression that returns an aggregate value (e.g. struct member
               ;; extraction via extractvalue), alloca a temp slot, store the value, and
               ;; use the slot pointer for GEP.
               (arr-ptr
                (if (semantic-var-read-p array-node)
                    (let ((alloca (gethash (semantic-var-read-name array-node) var-env)))
                      (unless alloca
                        (error "array aref: variable ~a not found in var-env"
                               (semantic-var-read-name array-node)))
                      alloca)
                    (let ((sub-val (generate-node-ir array-node builder module var-env
                                                     di-builder di-scope location-map)))
                      (if (llvm-type-kind-is-pointer? (llvm-type-of sub-val))
                          ;; Already a pointer (e.g. cell-of-array returns ptr)
                          sub-val
                          ;; Aggregate value (e.g. struct member) — spill to a temp alloca
                          (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                            (llvm-build-store builder sub-val slot)
                            slot)))))
               ;; Extend index to i64 for GEP
               (idx-i64 (llvm-build-sext builder index-val (llvm-int64-type) "arr_idx")))

          (log:info "array-aref: type=(array ~a ~a) ptr=~a idx=~a"
                    elem-type-spec count arr-ptr idx-i64)

          ;; GEP [N x T]* arr-ptr, i32 0, i64 idx
          (cffi:with-foreign-object (indices :pointer 2)
            (setf (cffi:mem-aref indices :pointer 0)
                  (llvm-const-int (llvm-int32-type) 0 nil))  ; outer deref
            (setf (cffi:mem-aref indices :pointer 1) idx-i64) ; element index
            (let* ((elem-ptr (llvm-build-in-bounds-gep2
                              builder arr-llvm-type arr-ptr indices 2 "arr_elem_ptr"))
                   (loaded   (llvm-build-load2 builder elem-llvm-type elem-ptr "arr_elem")))
              (values loaded nil elem-ptr)))))

       ;; Case 1: CELL parameterized type — original behaviour
       ((and (listp cell-spec) (eq (cl:first cell-spec) 'cell))
        (let* ((cell-val       (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-struct-name (mangle-template-struct-name (cl:first cell-spec)
                                                                  (cl:rest cell-spec))))
          (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
          (ensure-struct-llvm-type mangled-struct-name) ; ensure the LLVM type is registered
          (let ()
            (log:info "semantic-aref: Using ExtractValue to access Cell Record members.")
            (let* ((parent-val  (llvm-build-extract-value builder cell-val 0 "parent_val"))
                   (base-ptr    (llvm-build-extract-value builder parent-val 0 "base_ptr"))
                   (cell-offset (llvm-build-extract-value builder cell-val 1 "cell_offset"))
                   (elem-size   (llvm-size-of elem-llvm-type))
                   (index-i64   (llvm-build-sext builder index-val (llvm-int64-type) "index_i64"))
                   (index-bytes (llvm-build-mul builder index-i64 elem-size "index_bytes"))
                   (total-offset (llvm-build-add builder cell-offset index-bytes "total_offset")))
              (cffi:with-foreign-object (indices :pointer 1)
                (setf (cffi:mem-aref indices :pointer 0) total-offset)
                (let* ((final-ptr-i8 (llvm-build-in-bounds-gep2
                                      builder (llvm-int8-type) base-ptr indices 1 "final_ptr_i8"))
                       (ptr-as       (llvm-get-pointer-address-space
                                      (llvm-type-of final-ptr-i8)))
                       (target-ptr   (llvm-build-bit-cast
                                      builder final-ptr-i8
                                      (llvm-pointer-type elem-llvm-type ptr-as) "target_ptr"))
                       (loaded-val   (llvm-build-load2
                                      builder elem-llvm-type target-ptr "val")))
                  (values loaded-val nil target-ptr)))))))

       (t (error "generate-node-ir semantic-aref: Unsupported array type: ~a (unmangled: ~a)"
                 array-type cell-spec))))))

;;; src/analysis/structs.lisp
;;; Redefine analyze-aref-expression to guard brand-aware typing from compound elem types.
;;; When elem-type is a list (e.g. (array long 5)), resolve-brand-type must NOT be called:
;;; brand gensyms are opaque symbols, get-array-element-type returns NIL for them, causing
;;; the outer (~ %ANF-T 1) to fall through to analyze-function-call with bare type ARRAY.
(defun analyze-aref-expression (expr env context location)
  "Analyzes a cell dereference expression (~ cell-var [index]).
   Brand-aware typing applies only for scalar element types (not compound types like
   (array T N)), preventing brand gensyms from masking compound type structure."
  (let* ((op (cl:first expr))
         (target-sym (if (symbolp (cl:second expr)) (cl:second expr) nil))
         (array-node (analyze-expression (cl:second expr) env context (append location '(1))))
         (index-expr (cl:third expr))
         (index-node (if index-expr
                         (analyze-expression index-expr env context (append location '(2)))
                         (make-semantic-literal :value-type 'int :value 0 :source-location location)))
         (elem-type (get-array-element-type (semantic-node-type array-node))))

    ;; Check for invalid READ access on &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
          (let ((binding (find-variable-in-env target-sym env)))
            (when (and binding (eq (parameter-def-kind binding) :out))
                  (error 'crisp-illegal-access-error
                    :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only." target-sym)
                    :source-location location))))

    (if elem-type
        (progn
         ;; Check for VOID element type
         (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "VOID"))
                            (and (symbolp elem-type) (string-equal (symbol-name elem-type) "T"))
                            (and (consp elem-type)
                                 (let ((head (cl:first elem-type)))
                                   (or (eq head 'void) (eq head 'T)
                                       (and (symbolp head) (string-equal (symbol-name head) "VOID"))))))))
           (when is-void
                 (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

         ;; Brand-aware type resolution for --differentiate mode.
         ;; Only applies to :read-write cell types with SCALAR element types.
         ;; Compound element types (e.g. (array T N)) are excluded: resolve-brand-type
         ;; returns an opaque gensym symbol that get-array-element-type cannot handle,
         ;; causing the outer (~ temp index) to fail with bare-symbol ARRAY type.
         (let* ((cell-type (semantic-node-type array-node))
                (brand-def (and target-sym
                                (not (eq *analysis-access-mode* :write))
                                ;; Only brand scalars, not compound types like (array T N)
                                (not (consp elem-type))
                                (find-brand-for-owner 'value-t cell-type)))
                ;; Check that the owning cell struct is :read-write (not :read-only/:write-only)
                (is-rw-cell (and brand-def
                                 (let ((owner (brand-definition-owner-struct brand-def)))
                                   (and (symbolp owner)
                                        (search "READ-WRITE" (symbol-name owner))))))
                (resolved-type (if (and is-rw-cell (brand-active-p brand-def))
                                   (progn
                                     (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a [elem: ~a]"
                                               cell-type target-sym elem-type)
                                     (resolve-brand-type 'value-t target-sym elem-type))
                                   elem-type)))
           (make-semantic-aref :type resolved-type
                               :array-node array-node
                               :index-node index-node
                               :source-location location)))
        ;; Fallback: If not an array/pointer, and op is ~, try as overloadable function call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))


;;; src/analysis/structs.lisp
;;; Redefinition: handle single-element list wrapping from function-call return types.
;;; e.g. get-array-element-type of ((array float 4)) must return float, not nil.
(defun get-array-element-type (type)
  "Determines the element type of an array, pointer, or cell type. Returns NIL if unknown.
   Handles single-element list wrapping produced by function-call return types,
   e.g. ((array float 4)) is unwrapped to (array float 4) before dispatch."
  ;; Unwrap single-element list of lists (function return type wrapping)
  (let* ((type (if (and (listp type) (= (cl:length type) 1) (listp (cl:first type)))
                   (cl:first type)
                   type))
         (type (resolve-type-alias type)))
    (cond
     ((listp type)
       (let ((base (cl:first type)))
         (if (and (symbolp base)
                  (member (symbol-name base)
                          '("CELL" "VECTOR" "MATRIX" "TENSOR" "PTR" "ARRAY" "POINTER")
                          :test #'string-equal))
             (cl:second type)
             nil)))
     ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (if (and (consp unmangled) (eq (cl:first unmangled) 'cell))
             (cl:second unmangled)
             nil)))
     (t nil))))

;;; src/templates.lisp
;;; Redefine initialize-templates to report arity 2 for ARRAY in the arity lookup fn.
;;; This allows unmangle-template-struct-name to correctly reconstruct
;;; CELL_ARRAY_LONG_5_GLOBAL_READ-WRITE -> (cell (array long 5) ...) .
;;; The side-effect of mangle in parse-type-specifier is blocked by the
;;; early (array T N) case added in the parse-type-specifier redefinition below.
(defun initialize-templates ()
  "Initializes the template system and hooks into the compiler.
   Extended to register ARRAY as a built-in arity-2 form for unmangle support."
  (clrhash *instantiated-templates*)
  (clrhash *template-registry*)
  (setf crisp.compiler::*template-instantiator-fn* #'ensure-template-instantiation)
  (setf crisp.compiler::*template-arity-lookup-fn*
    (lambda (name)
      ;; Built-in: ARRAY always has arity 2 (element-type count)
      (if (and (symbolp name) (string-equal (symbol-name name) "ARRAY"))
          2
          ;; Normal template registry lookup
          (let ((tmpls (gethash name *template-registry*)))
            (unless tmpls
              (maphash (lambda (k v)
                         (when (string-equal (symbol-name k) (symbol-name name))
                               (setf tmpls v)))
                       *template-registry*))
            (when tmpls
                  (length (template-data-parameters (first tmpls))))))))
  (log:info "Template system initialized (with ARRAY arity-2 unmangle support)."))

;;; ============================================================
;;; Phase 7: Kernel boundary immutability for (array T N) params
;;; ============================================================

;;; src/analysis/core.lisp
(defvar *boundary-array-params* nil
  "Dynamic variable: list of uppercase param name strings that are (array T N)
   params at the current kernel boundary. Non-nil only when compiling an
   entry-point kernel. Nil in regular functions.")

;;; src/analysis/core.lisp
(defun %check-aref-boundary-mutation (aref-node location)
  "Called when a semantic-aref is the target of a set!.
   Error 01: If the array-node is a direct var-read in *boundary-array-params*, error.
   Error 02: If the array-node is a call (accessor) whose first arg is a boundary struct, error."
  (when (semantic-aref-p aref-node)
    (let ((array-node (semantic-aref-array-node aref-node)))
      ;; Error 01: direct kernel boundary array param
      (when (and *boundary-array-params* (semantic-var-read-p array-node))
        (let ((vname-str (string-upcase (symbol-name (semantic-var-read-name array-node)))))
          (when (member vname-str *boundary-array-params* :test #'string=)
            (error 'crisp-compiler-error
                   :message (format nil "Cannot write to array parameter '~(~a~)': (array T N) parameters at kernel boundary are immutable"
                                    vname-str)
                   :source-location location))))
      ;; Error 02: array extracted from a boundary struct param
      (when (and *boundary-struct-params* (semantic-call-p array-node))
        (dolist (arg (semantic-call-args array-node))
          (when (semantic-var-read-p arg)
            (let ((vname-str (string-upcase (symbol-name (semantic-var-read-name arg)))))
              (when (member vname-str *boundary-struct-params* :test #'string=)
                (error 'crisp-compiler-error
                       :message (format nil "Cannot write to array member of boundary struct '~(~a~)': struct parameters at kernel boundary are immutable"
                                        vname-str)
                       :source-location location)))))))))

;;; src/analysis/core.lisp
;;; Redefine internal-def-function to also populate *boundary-array-params*.
(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params* and *boundary-array-params* to enforce immutability."
  (log:info "Analyzing function ~s" name)

  (when *differentiate-p*
        (log:info "Applying ANF to function body")
        (let* ((progn-body `(progn ,@body))
               (anf-body (anf-normalize progn-body nil))
               (unwrapped-body (if (and (consp anf-body) (eq (car anf-body) 'progn))
                                   (cdr anf-body)
                                   (list anf-body))))
          (setf body unwrapped-body)))

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (cl:first d))
                                          (string-equal (symbol-name (cl:first d)) "ENTRY-POINT"))))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))
      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))

;;; src/analysis/structs.lisp
;;; Redefine analyze-set!-expression to also call %check-aref-boundary-mutation
;;; in sub-case 2b when the target is a semantic-aref.
(defun analyze-set!-expression (expr env context location)
  "Analyzes a (set! target value) expression.
   Enforces struct and array immutability at kernel boundary."
  (let* ((target-form (second expr))
         (value-form  (third expr))
         (value-node  (analyze-expression value-form env context (append location '(2)))))

    (cond
     ;; Case 1: Simple variable assignment  (set! x v)
     ((symbolp target-form)
       (let ((var-info (find-variable-in-env target-form env)))
         (unless var-info
           (error 'crisp-unknown-variable :name target-form :source-location location))
         (let ((var-type (parameter-def-type var-info))
               (val-type (semantic-node-type value-node)))
           (unless (types-compatible-p val-type var-type)
             (error 'crisp-type-error :expected var-type :inferred val-type
                    :source-location location)))
         (make-semantic-set!
          :target-node (make-semantic-var-read
                        :name target-form
                        :type (parameter-def-type var-info)
                        :source-location location)
          :value-node value-node
          :source-location location)))

     ;; Case 2: Function call / struct accessor
     ((and (listp target-form) (>= (length target-form) 1) (symbolp (cl:first target-form)))
       (let* ((op           (cl:first target-form))
              (op-args      (rest target-form))
              (arg-nodes    (loop for arg in op-args
                                  for i from 1
                                  collect (analyze-expression arg env context
                                                              (append location (list 1 i)))))
              (all-arg-nodes  (append arg-nodes (list value-node)))
              (all-arg-types  (mapcar #'semantic-node-type all-arg-nodes))
              (full-setter-name (intern (format nil "~a_SET!" op) (symbol-package op)))
              (signatures   (append (gethash op *function-table*)
                                    (gethash full-setter-name *function-table*)))
              (match        (find-if (lambda (sig)
                                       (types-list-compatible-p
                                        all-arg-types
                                        (mapcar #'parameter-def-type
                                                (function-signature-parameters sig))))
                                     signatures)))

         ;; Try template instantiation if no direct match
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*)
                                  full-setter-name op)))
             (when (gethash template-op *template-registry*)
               (ensure-template-instantiation
                template-op all-arg-types
                (lambda (f l) (declare (ignore l)) (eval f)))
               (setf signatures (append (gethash op *function-table*)
                                        (gethash full-setter-name *function-table*)))
               (setf match (find-if
                            (lambda (sig)
                              (types-list-compatible-p
                               all-arg-types
                               (mapcar #'parameter-def-type
                                       (function-signature-parameters sig))))
                            signatures)))))

         (cond
          ;; Sub-case 2a: Found an overloaded setter function -> call it.
          (match
            (make-semantic-call
             :name (function-signature-name match)
             :type (function-signature-return-types match)
             :args all-arg-nodes
             :signature match
             :source-location location))

          ;; Sub-case 2b: Expression analyzer — only if result is an assignable lvalue.
          ((gethash op *expression-analyzers*)
            (let ((target-node
                   (let ((*analysis-access-mode* :write))
                     (analyze-expression target-form env context (append location '(1))))))
              (if (or (semantic-extract-value-p target-node)
                      (semantic-aref-p target-node))
                  (progn
                    ;; Array boundary immutability check (errors 01 and 02)
                    (when (semantic-aref-p target-node)
                      (%check-aref-boundary-mutation target-node location))
                    (make-semantic-set!
                     :target-node target-node
                     :value-node value-node
                     :source-location location))
                  ;; Not an assignable lvalue — fall through to Sub-case 2c.
                  (let* ((op-name (symbol-name op))
                         (is-accessor
                          (or (alexandria:ends-with #\~ op-name)
                              (and (alexandria:starts-with #\~ op-name)
                                   (alexandria:ends-with #\~ op-name)))))
                    (unless is-accessor
                      (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                             target-form))
                    (unless (= (length arg-nodes) 1)
                      (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                             op (length arg-nodes)))
                    (let* ((clean-name  (cl:string-trim "~" op-name))
                           (member-sym  (intern clean-name (symbol-package op)))
                           (struct-node (cl:first arg-nodes))
                           (struct-type (semantic-node-type struct-node)))
                      (unless (or (semantic-var-read-p struct-node)
                                  (semantic-aref-p struct-node))
                        (error "Cannot set member of non-variable/non-reference struct form: ~a"
                               (second target-form)))
                      (%check-struct-boundary-mutation struct-node env context location)
                      (let ((update-node
                             (make-semantic-struct-member-update
                              :type struct-type
                              :struct-node struct-node
                              :member-index (get-struct-member-index struct-type member-sym)
                              :value-node value-node
                              :source-location location)))
                        (make-semantic-set!
                         :target-node struct-node
                         :value-node update-node
                         :source-location location)))))))

          ;; Sub-case 2c: Struct member update (legacy accessor logic).
          (t
            (let* ((op-name (symbol-name op))
                   (is-accessor
                    (or (alexandria:ends-with #\~ op-name)
                        (and (alexandria:starts-with #\~ op-name)
                             (alexandria:ends-with #\~ op-name)))))
              (unless is-accessor
                (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                       target-form))
              (unless (= (length arg-nodes) 1)
                (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                       op (length arg-nodes)))
              (let* ((clean-name  (cl:string-trim "~" op-name))
                     (member-sym  (intern clean-name (symbol-package op)))
                     (struct-node (cl:first arg-nodes))
                     (struct-type (semantic-node-type struct-node)))
                (unless (or (semantic-var-read-p struct-node)
                            (semantic-aref-p struct-node))
                  (error "Cannot set member of non-variable/non-reference struct form: ~a"
                         (second target-form)))
                (%check-struct-boundary-mutation struct-node env context location)
                (let ((update-node
                       (make-semantic-struct-member-update
                        :type struct-type
                        :struct-node struct-node
                        :member-index (get-struct-member-index struct-type member-sym)
                        :value-node value-node
                        :source-location location)))
                  (make-semantic-set!
                   :target-node struct-node
                   :value-node update-node
                   :source-location location))))))))

     (t (error "Invalid set! target structure: ~a" target-form)))))

;;; src/types/validation.lisp
;;; Phase 7: Cap check for (array T N) in def-record — N must be <= 16.
;;; Redefine valid-parameterized-type-p to add this check.
(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, array, etc).
   Extended to recognise (array T N), reject nested arrays, and reject N > 16 in records."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (cl:rest expanded)))
      (cl:cond
        ((not (symbolp base-type)) nil)
        ((excluded-template-base-type-p base-type) nil)

        ;; (array T N) — compile-time fixed array type
        ((%array-type-p expanded)
         (cl:let ((elem-type (cl:first params))
                  (count     (cl:second params)))
           ;; Nesting is illegal
           (cl:when (%array-type-p elem-type)
             (error 'crisp-compiler-error
                    :message (format nil "Array type cannot be nested: ~s is illegal. Use def-struct or a cell instead."
                                     type-spec)))
           ;; Validate: exactly 2 args, valid non-array element type, positive integer count
           (and (= (cl:length params) 2)
                (valid-basic-type-p elem-type)
                (integerp count)
                (> count 0))))

        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params)
                  (keywordp (cl:first params))))
         t)

        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

        (t nil)))))

;;; src/types/validation.lisp
;;; Final valid-parameterized-type-p redef: accept symbol counts from unmangle.
;;; When an (array T N) type is reconstructed from a mangled name like
;;; CELL_ARRAY_LONG_5_GLOBAL_READ-WRITE, the count comes back as the symbol |5|
;;; (not the integer 5). The integerp check at line 840 above rejects that,
;;; causing valid-type-p to return NIL for (array long |5|), which in turn causes
;;; get-single-value-type to strip the type to the bare symbol ARRAY.
(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, array, etc).
   Extended to recognise (array T N), reject nested arrays, and accept symbol counts
   (e.g. the symbol |5| produced by unmangle-template-struct-name)."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (cl:rest expanded)))
      (cl:cond
        ((not (symbolp base-type)) nil)
        ((excluded-template-base-type-p base-type) nil)

        ;; (array T N) — compile-time fixed array type
        ;; count may be an integer (from source) or a symbol like |5| (from unmangle)
        ((%array-type-p expanded)
         (cl:let* ((elem-type (cl:first params))
                   (count-raw (cl:second params))
                   (count (cl:cond
                            ((integerp count-raw) count-raw)
                            ((and (symbolp count-raw)
                                  (ignore-errors (parse-integer (symbol-name count-raw)))))
                            (t nil))))
           ;; Nesting is illegal
           (cl:when (%array-type-p elem-type)
             (error 'crisp-compiler-error
                    :message (format nil "Array type cannot be nested: ~s is illegal. Use def-struct or a cell instead."
                                     type-spec)))
           ;; Validate: exactly 2 args, valid non-array element type, positive integer count
           (and (= (cl:length params) 2)
                (valid-basic-type-p elem-type)
                count
                (> count 0))))

        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params)
                  (keywordp (cl:first params))))
         t)

        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

        (t nil)))))

;;; src/structs.lisp
;;; Redefine register-struct-definition to add cap check for record virtual arrays.
;;; N > 16 in a def-record member array signals a crisp-compiler-error with "exceeds".
(defun register-struct-definition (name members &optional (category :struct))
  "Registers a struct or record definition in the global registry.
   Extended: for records, validates that no (array T N) member has N > 16."
  ;; Cap check: virtual arrays in records are limited to N <= 16
  (when (eq category :record)
    (dolist (m members)
      (let ((type (if (and (consp m) (>= (cl:length m) 2)) (cl:second m) nil)))
        (when (and type (%array-type-p type))
          (let* ((count-raw (cl:third type))
                 (count (etypecase count-raw
                          (integer count-raw)
                          (symbol  (parse-integer (symbol-name count-raw))))))
            (when (> count 16)
              (error 'crisp-compiler-error
                     :message (format nil "Record virtual array '~a' exceeds maximum size: N=~a > 16. Use def-struct or a cell for large arrays."
                                      (cl:first m) count))))))))
  (cl:let ((name (if (consp name)
                     (mangle-template-struct-name (cl:first name) (cl:rest name))
                     name)))
    (handler-case
        (multiple-value-bind (padded-members total-size)
            (if (eq category :record)
                (compute-record-layout members)
                (compute-std140-layout members))
          (cl:let ((indices (make-hash-table :test #'eq)))
            (loop for m in padded-members
                  for i from 0
                  do (setf (gethash (car m) indices) i))
            (setf (gethash name *crisp-structs*)
              (make-crisp-struct-definition
               :name name
               :members members
               :padded-members padded-members
               :field-indices indices
               :total-size total-size))
            (setf (gethash name *crisp-types*)
              (make-crisp-type
               :name name
               :llvm-type-fn (lambda () (ensure-struct-llvm-type name))
               :size (* total-size 8)
               :category category))))
      (error (c)
        (cl:when *defer-struct-validation*
          (log:info "Deferring struct registration for ~a. dependency missing/error: ~a" name c)
          (return-from register-struct-definition
                       (push (list name members category) *pending-struct-definitions*)))
        (error c)))))

;;; src/environment.lisp
;;; Redefine parse-type-specifier to handle (array T N) before the generic
;;; parameterized-type path would mangle it to ARRAY_LONG_4.
;;; We add an early case that returns the list spec unchanged.
(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s).
   Extended: (array T N) is returned as-is (not mangled) before the generic path."
  (cond
   ;; (array T N) — return as a list spec unchanged, not mangled
   ((%array-type-p spec)
    spec)

   ;; 0. Type Aliases
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (cl:let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved)
       (if (and (consp resolved) (eq (cl:first resolved) 'common-lisp:function))
           (cl:let* ((sig (if (listp (second resolved)) (second resolved) (rest resolved)))
                     (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                              (string-equal (symbol-name x) "=>")))
                                             sig))
                     (param-types (if arrow-pos (subseq sig 0 arrow-pos) sig))
                     (return-types (if arrow-pos (nthcdr (1+ arrow-pos) sig) nil)))
             `(:function-type ,return-types :params ,(mapcar #'parse-type-specifier param-types)))
           spec)))

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (cl:let* ((alias-name (first spec))
               (args (rest spec))
               (alias-def (gethash alias-name *crisp-template-aliases*))
               (params (car alias-def))
               (body-spec (cdr alias-def))
               (arity (length params))
               (required-args (subseq args 0 (min (length args) arity)))
               (rest-args (subseq args (length required-args)))
               (substitutions (pairlis params required-args)))
       (cl:let ((expanded (sublis substitutions body-spec)))
         (cl:let ((final-spec (if (and rest-args (consp expanded))
                                  (append expanded rest-args)
                                  (if rest-args
                                      (cons expanded rest-args)
                                      expanded))))
           (parse-type-specifier final-spec)))))

   ;; 0.15 Brand Type Application: (brand-name var-ref)
   ((and (listp spec)
         (= (length spec) 2)
         (symbolp (first spec))
         (symbolp (second spec))
         (is-brand-type-p (first spec)))
     (cl:let* ((brand-name (first spec))
               (var-ref (second spec))
               (brand-def (is-brand-type-p brand-name)))
       (if (gethash brand-name *parameterized-brand-names*)
           (progn
             (log:info "PARSE: Parameterized brand application (~a ~a) - deferring resolution"
                       brand-name var-ref)
             spec)
           (progn
             (log:info "PARSE: Brand type application (~a ~a) -> ~a [~a]"
                       brand-name var-ref brand-name
                       (if (brand-active-p brand-def) "active" "inactive"))
             brand-name))))

   ;; 0.2 Simple Alias as List Head (e.g. (int-cell :access :read-only))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-type-aliases*))
     (cl:let* ((alias-name (first spec))
               (args (rest spec))
               (expanded-base (gethash alias-name *crisp-type-aliases*)))
       (cl:let ((final-spec (if (listp expanded-base)
                                (append expanded-base args)
                                (cons expanded-base args))))
         (log:info "EXPAND-ALIAS-HEAD: ~a -> ~a" spec final-spec)
         (parse-type-specifier final-spec))))

   ;; Standard symbol: e.g. 'int'
   ((and (symbolp spec) (valid-type-p spec)) spec)

   ;; Storage Handle Symbols (e.g. CELL, VECTOR...)
   ((and (symbolp spec) (member (symbol-name spec) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Promoting symbol ~a to list (~a)" spec spec)
     (parse-type-specifier (list spec)))

   ;; Function Type: #'(int => int) — raw (function ...) form from reader
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (cl:let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                    (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (cl:let ((canonical (expand-storage-handle-type-specifier spec)))
       (if (valid-type-p canonical)
           (cl:let ((base (first canonical))
                    (params (rest canonical)))
             (cl:let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params)))
           (error 'crisp-unknown-type-error :type-name spec))))

   ;; Function Type/Literal (already parsed to :function-type or :function-literal)
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (cl:let* ((base (first spec))
               (raw-params (rest spec))
               (arity (get-template-arity base))
               (params (if (and arity (> (length raw-params) arity))
                           (extract-positional-from-keyword-args raw-params arity)
                           raw-params)))
       (cl:let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))

;;; src/types/validation.lisp
;;; Redefine canonicalize-type-specifier to early-return for (array T N).
;;; Without this, get-template-arity 'array = 2 causes the generic template
;;; path to mangle (array long 5) to ARRAY_LONG_5, making valid-type-p return NIL
;;; for array types. This breaks get-single-value-type which then strips
;;; (array long 5) to the bare symbol ARRAY when binding ANF temps.
(defun canonicalize-type-specifier (spec)
  "Canonicalizes type specifiers.
   Extended: (array T N) is returned as-is before the template path, preventing
   mangle to ARRAY_LONG_5 via the get-template-arity=2 path."

  ;; Early exit for (array T N): never mangle, preserve as list
  (when (and (consp spec) (%array-type-p spec))
    (return-from canonicalize-type-specifier spec))

  ;; First, apply storage handle expansion
  (cl:when (consp spec)
    (setf spec (expand-storage-handle-type-specifier spec)))

  ;; After expansion, check again (in case alias expanded to array)
  (when (and (consp spec) (%array-type-p spec))
    (return-from canonicalize-type-specifier spec))

  (cl:let ((base (if (consp spec) (cl:first spec) spec))
           (args (if (consp spec) (rest spec) nil)))
    (cl:cond
      ((symbolp base)
       ;; 1. Check Template Aliases (def-type)
       (cl:let ((alias-def (gethash base *crisp-template-aliases*)))
         (cl:if alias-def
                (cl:let ((params (car alias-def))
                         (type-spec (cdr alias-def)))
                  (cl:if params
                         (cl:let* ((arity (length params))
                                   (required-args (subseq args 0 (min (length args) arity)))
                                   (rest-args (subseq args (length required-args)))
                                   (substitutions (pairlis params required-args)))
                           (cl:let ((expanded-base (sublis substitutions type-spec)))
                             (cl:if (and rest-args (consp expanded-base))
                                    (canonicalize-type-specifier (append expanded-base rest-args))
                                    (canonicalize-type-specifier expanded-base))))
                         (cl:if args
                                (canonicalize-type-specifier (append (cl:if (consp type-spec) type-spec (list type-spec)) args))
                                (cl:let ((resolved (resolve-type-alias base)))
                                  (cl:if (equal resolved base)
                                         (progn
                                          (log:warn "[canonicalize-type-specifier] Alias Cycle detected for ~a, returning base." base)
                                          (list base))
                                         (canonicalize-type-specifier resolved))))))

                ;; 2. Standard Templates (With Validation)
                (cl:let* ((template-data (first (gethash base *template-registry*)))
                          (raw-params (and template-data (template-data-parameters template-data))))
                  (cl:if raw-params
                         (cl:let* ((parsed-params (mapcar #'parse-template-parameter-spec raw-params))
                                   (clean-args (extract-positional-from-keyword-args args (length parsed-params)))
                                   (full-args (cl:loop for (p-name p-type p-default) in parsed-params
                                              for i from 0
                                              for arg = (if (< i (length clean-args))
                                                            (nth i clean-args)
                                                            (or p-default
                                                                (error "Missing required type argument for template ~a: ~a (index ~d)" base p-name i)))
                                              do (validate-template-arg arg p-type p-name)
                                              collect arg)))
                           (cons base full-args))

                         ;; Not a template, return as is (normalized to list)
                         (cl:if (consp spec) spec (list spec)))))))
      ((consp spec) spec)
      (t (list spec)))))

