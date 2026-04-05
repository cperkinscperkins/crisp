;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;;; ============================================================
;;;; Bug 028 workaround: inline struct array-field GEP to avoid
;;;; SPIR-V functions with TypeArray return types (IGC bug).
;;;; ============================================================

;; src/codegen.lisp
(defun %lookup-field-physical-index (struct-def field-name-str)
  "Returns the physical (LLVM struct) index of a field identified by
   FIELD-NAME-STR, using string-equal so package differences don't matter.
   Returns NIL if not found."
  (let ((result nil))
    (maphash (lambda (k v)
               (when (string-equal (symbol-name k) field-name-str)
                 (setf result v)))
             (crisp-struct-definition-field-indices struct-def))
    result))

;; src/codegen.lisp
(defun %try-inline-struct-array-field-ptr
    (array-node builder module var-env di-builder di-scope location-map)
  "Workaround for IGC bug 028.

   If ARRAY-NODE is a call to a struct field accessor (name ends with ~)
   whose return type is (array T N), emits a GEP directly into the struct's
   alloca to produce a pointer to the array field — completely bypassing the
   accessor function call.

   This avoids generating a SPIR-V function with TypeArray return type, which
   IGC (Intel Graphics Compiler) silently miscompiles.

   Returns the GEP pointer (ptr to [N x T]) if the pattern is recognized, or
   NIL otherwise so the caller can fall through to the normal path."
  (when (and (semantic-call-p array-node)
             (= (cl:length (semantic-call-args array-node)) 1))
    (let* ((call-type (semantic-call-type array-node))
           ;; Unwrap single-element list return types: ((array T N)) -> (array T N)
           (raw-type  (if (and (listp call-type)
                               (= (cl:length call-type) 1)
                               (listp (cl:first call-type)))
                          (cl:first call-type)
                          call-type)))
      (when (%array-type-p (resolve-type-alias raw-type))
        (let* ((call-name    (semantic-call-name array-node))
               (name-str     (symbol-name call-name)))
          ;; Only intercept accessor calls (name ends with ~)
          (when (and (> (cl:length name-str) 1)
                     (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~))
            (let* ((field-name-str  (subseq name-str 0 (1- (cl:length name-str))))
                   (arg-node        (cl:first (semantic-call-args array-node)))
                   (struct-type-sym (semantic-node-type arg-node))
                   (struct-def      (when (symbolp struct-type-sym)
                                      (lookup-struct-definition struct-type-sym))))
              (when struct-def
                (let ((physical-index (%lookup-field-physical-index struct-def field-name-str)))
                  (when physical-index
                    (log:info "028-fix: inlining struct accessor ~a (field '~a' idx=~a) to avoid array-returning fn"
                              call-name field-name-str physical-index)
                    (let* ((struct-llvm-type (ensure-struct-llvm-type struct-type-sym))
                           ;; Obtain a pointer to the struct in the function frame.
                           ;; If the arg is a simple var-read its alloca is already in var-env.
                           ;; Otherwise generate the struct value and spill it.
                           (struct-ptr
                             (if (semantic-var-read-p arg-node)
                                 (let ((alloca (gethash (semantic-var-read-name arg-node) var-env)))
                                   (log:info "028-fix: using alloca for var ~a" (semantic-var-read-name arg-node))
                                   alloca)
                                 (let ((sv (generate-node-ir arg-node builder module var-env
                                                             di-builder di-scope location-map)))
                                   (let ((spill (llvm-build-alloca builder struct-llvm-type "struct_spill")))
                                     (llvm-build-store builder sv spill)
                                     spill)))))
                      ;; Two-level GEP: struct_ptr[0].physical_index -> ptr to [N x T]
                      (cffi:with-foreign-object (gep-indices :pointer 2)
                        (setf (cffi:mem-aref gep-indices :pointer 0)
                              (llvm-const-int (llvm-int32-type) 0 nil))
                        (setf (cffi:mem-aref gep-indices :pointer 1)
                              (llvm-const-int (llvm-int32-type) physical-index nil))
                        (llvm-build-in-bounds-gep2
                         builder struct-llvm-type struct-ptr gep-indices 2 "arr_field_ptr")))))))))))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-aref) builder module var-env di-builder di-scope location-map)
  "Generates IR for array/cell access (aref / ~).
   Case 1: CELL parameterized type  — existing behaviour unchanged.
   Case 2: (array T N) fixed-size array — GEP into the alloca (or pointer).
     For a direct var-read of type (array T N), the alloca is fetched directly
     from var-env so we never load the aggregate value before GEP-ing into it.
     For a struct accessor call returning (array T N), %try-inline-struct-array-field-ptr
     GEPs directly into the struct's alloca — no array-returning function call emitted
     (workaround for IGC bug 028, see tests/spec/061-place-semantics/DESIGN.md).
     For a nested aref (e.g. cell-of-array), the inner generate-node-ir returns
     the addrspace(1) pointer as its third value — use that directly so that
     stores go back to GPU memory (fixes bug 029).
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
               ;; New (bug 028): if array-node is a struct accessor call returning an array
               ;;   type, GEP directly into the struct's alloca — no function call emitted.
               ;; Existing: for a direct var-read, grab the alloca from var-env.
               ;; Existing: for a nested aref returning a pointer (bug 029 path), use it.
               ;; Existing: for any other aggregate value, spill to a temp alloca.
               (arr-ptr
                (let ((inline-ptr (%try-inline-struct-array-field-ptr
                                   array-node builder module var-env
                                   di-builder di-scope location-map)))
                  (if inline-ptr
                      inline-ptr
                      (if (semantic-var-read-p array-node)
                          (let ((alloca (gethash (semantic-var-read-name array-node) var-env)))
                            (unless alloca
                              (error "array aref: variable ~a not found in var-env"
                                     (semantic-var-read-name array-node)))
                            alloca)
                          (multiple-value-bind (sub-val _loc sub-ptr)
                              (generate-node-ir array-node builder module var-env
                                                di-builder di-scope location-map)
                            (declare (ignore _loc))
                            (cond
                             ;; Inner node returned a direct pointer (e.g. cell-of-array) — use it.
                             (sub-ptr
                              (log:info "array-aref: using sub-ptr from inner aref (bug 029 path)")
                              sub-ptr)
                             ;; sub-val is already a pointer type (bare pointer expression)
                             ((llvm-type-kind-is-pointer? (llvm-type-of sub-val))
                              sub-val)
                             ;; Aggregate value — spill to temp alloca
                             (t
                              (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                                (llvm-build-store builder sub-val slot)
                                slot))))))))
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

       ;; Case 1: CELL parameterized type — original behaviour unchanged
       ((and (listp cell-spec) (eq (cl:first cell-spec) 'cell))
        (let* ((cell-val       (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-struct-name (mangle-template-struct-name (cl:first cell-spec)
                                                                  (cl:rest cell-spec))))
          (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
          (ensure-struct-llvm-type mangled-struct-name)
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


;;;; ============================================================
;;;; Bug 028 Part 2: delete dead array-returning functions before
;;;; SPIR-V translation so IGC never sees them.
;;;; ============================================================

;; src/compiler.lisp
(defun %remove-dead-array-returning-functions (module)
  "Scans MODULE for functions whose return type is an LLVM array type
   ([N x T]) and that have no uses (no callers in this module).
   Deletes each such function.

   This is Part 2 of the IGC bug 028 workaround. Part 1 (in
   %try-inline-struct-array-field-ptr) removes all CALLS to these
   functions. Part 2 removes the DEFINITIONS so that IGC never sees
   a SPIR-V OpFunction with TypeArray return type, even as dead code.

   Returns the number of functions deleted."
  (let ((to-delete '())
        (fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop while (and fn (not (cffi:null-pointer-p fn))) do
      (let* ((fn-type  (crisp.llvm-bindings::llvm-global-get-value-type fn))
             (ret-type (crisp.llvm-bindings::llvm-get-return-type fn-type)))
        (when (and (crisp.llvm-bindings::llvm-type-kind-is-array? ret-type)
                   (cffi:null-pointer-p (crisp.llvm-bindings::llvm-get-first-use fn)))
          (log:info "028-cleanup: queuing dead array-returning fn ~a for deletion"
                    (crisp.llvm-bindings::llvm-get-value-name fn))
          (push fn to-delete)))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    (dolist (fn to-delete)
      (crisp.llvm-bindings::llvm-delete-function fn))
    (let ((n (cl:length to-delete)))
      (when (> n 0)
        (log:info "028-cleanup: deleted ~a dead array-returning function(s)" n))
      n)))

;; src/compiler.lisp
(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V using the external toolchain.
   Runs %remove-dead-array-returning-functions before translation to
   prevent IGC from miscompiling dead TypeArray-returning functions
   (bug 028 workaround Part 2)."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    ;; Bug 028 Part 2: remove dead array-returning functions before SPIR-V
    ;; so IGC never sees a TypeArray return type, even in dead code.
    (%remove-dead-array-returning-functions module)

    ;; Set target triple for SPIR-V before writing IR
    (llvm-set-target module "spir64-unknown-unknown")

    ;; 1. Write Temporary .ll file
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    ;; 2. llvm-as (LL -> BC)
    (let ((tool (resolve-tool-executable "llvm-as")))
      (run-tool-command
       (list tool (namestring ll-file) "-o" (namestring bc-file))
       :log-prefix "[SPIR-V] "))

    ;; 3. llvm-spirv (BC -> SPV)
    (let ((tool (resolve-tool-executable "llvm-spirv"))
          (flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    (unless debug-p
      (when (probe-file ll-file) (delete-file ll-file))
      (when (probe-file bc-file) (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;;;; ============================================================
;;;; Bug 028 Part 2 — diagnostic redef: verbose logging to confirm
;;;; %remove-dead-array-returning-functions is called and what it sees.
;;;; Remove once confirmed working.
;;;; ============================================================

;; src/compiler.lisp
(defun %remove-dead-array-returning-functions (module)
  "Scans MODULE for functions whose return type is an LLVM array type
   ([N x T]) and that have no uses (no callers in this module).
   Deletes each such function.

   This is Part 2 of the IGC bug 028 workaround.
   Returns the number of functions deleted."
  (log:info "028-cleanup: starting scan of module for dead array-returning functions")
  (let ((to-delete '())
        (fn-count 0)
        (fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop while (and fn (not (cffi:null-pointer-p fn))) do
      (incf fn-count)
      (let* ((fn-name  (crisp.llvm-bindings::llvm-get-value-name fn))
             (fn-type  (crisp.llvm-bindings::llvm-global-get-value-type fn))
             (ret-type (crisp.llvm-bindings::llvm-get-return-type fn-type))
             (is-arr   (crisp.llvm-bindings::llvm-type-kind-is-array? ret-type))
             (no-uses  (cffi:null-pointer-p (crisp.llvm-bindings::llvm-get-first-use fn))))
        (log:info "028-cleanup: fn=~a is-array-ret=~a no-uses=~a" fn-name is-arr no-uses)
        (when (and is-arr no-uses)
          (log:info "028-cleanup: queuing dead array-returning fn ~a for deletion" fn-name)
          (push fn to-delete)))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    (log:info "028-cleanup: scanned ~a function(s), queued ~a for deletion" fn-count (cl:length to-delete))
    (dolist (fn to-delete)
      (crisp.llvm-bindings::llvm-delete-function fn))
    (let ((n (cl:length to-delete)))
      (when (> n 0)
        (log:info "028-cleanup: deleted ~a dead array-returning function(s)" n))
      n)))


;;;; ============================================================
;;;; def-record SROA for (array T N) fields at kernel boundary.
;;;; An array field in a record must be exploded to N individual
;;;; scalar parameters rather than passed as a bare [N x T] type
;;;; (which is invalid at an OpenCL/SPIR-V kernel entry point).
;;;; ============================================================

;; src/codegen/abi.lisp
(defun get-expanded-types (type-spec module)
  "Returns a list of LLVM types for a given Crisp type spec.
   For cell/storage, returns exploded ptr+i64 types. For records, explodes recursively.
   For (array T N), explodes to N copies of T's expanded types (SROA for record fields).
   For others, returns (type).
   If *target-backend* is :spirv or :ptx, upgrades pointers to Global Address Space (1)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (is-storage-list (and (consp type-spec)
                               (symbolp (first type-spec))
                               (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                       :test #'string-equal)))
         (lookup-spec (cond
                        (record-base record-base)
                        (is-storage-list
                         (let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
                           mangled))
                        (t type-spec)))
         (ignored (ignore-errors (resolve-type-to-llvm lookup-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when (and record-base (symbolp lookup-spec))
                         (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt *crisp-types*)))
                       (when (and is-storage-list (symbolp lookup-spec))
                         (let ((alt-symbol (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt-symbol *crisp-types*)))))
         (struct-def (lookup-struct-definition lookup-spec))
         (actual-key (cond
                       ((gethash lookup-spec *crisp-types*) lookup-spec)
                       ((and (or record-base is-storage-list) (symbolp lookup-spec))
                        (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                          (if (gethash alt *crisp-types*) alt lookup-spec)))
                       (t lookup-spec)))
         (expanded
          (progn
            (log:debug "GET-EXPANDED-TYPES: type-spec=~s lookup=~s found-type=~a found-struct=~a category=~a"
                       type-spec actual-key
                       (if type-rec "YES" "NO")
                       (if struct-def "YES" "NO")
                       (when type-rec (crisp-type-category type-rec)))
            (cond
              ;; Case 1: Record Type -> Explode recursively
              ((and type-rec (eq (crisp-type-category type-rec) :record))
               (when struct-def
                 (let* ((members (crisp-struct-definition-members struct-def))
                        (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members)))
                   (mapcan (lambda (m) (get-expanded-types (second m) module)) runtime-members))))
              ;; Case 1.5: (array T N) field — explode to N individual T values (SROA)
              ((%array-type-p lookup-spec)
               (let* ((elem-type (cl:second lookup-spec))
                      (count-raw (cl:third lookup-spec))
                      (count (etypecase count-raw
                               (integer count-raw)
                               (symbol (parse-integer (symbol-name count-raw))))))
                 (log:info "get-expanded-types: SROA array ~a -> ~a x ~a" lookup-spec count elem-type)
                 (loop repeat count append (get-expanded-types elem-type module))))
              ;; Case 2: Standard Type (Struct/Scalar) -> Return as is
              (t (list (crisp-type-to-llvm-type actual-key module)))))))

    (if (and (or (eq *target-backend* :spirv) (eq *target-backend* :ptx))
             (is-global-storage-handle-p type-spec))
        (mapcar (lambda (ty)
                  (if (llvm-type-kind-is-pointer? ty)
                      (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module))
                                         (encode-address-space :global))
                      ty))
                expanded)
        expanded)))

;; src/codegen/abi.lisp
(defun explode-value (builder agg-val type-spec)
  "Extracts components from an aggregate value if necessary. Returns a list of LLVM values.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).
   For (array T N) fields: extracts N individual element values (SROA)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (values '()))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (extracted (llvm-build-extract-value builder agg-val i (format nil "~a_val" (first m)))))
                    (setf values (append values (explode-value builder extracted member-type)))))
         values))
      ;; (array T N): extract each element individually (SROA for record fields)
      ((%array-type-p lookup-spec)
       (let* ((count-raw (cl:third lookup-spec))
              (count (etypecase count-raw
                       (integer count-raw)
                       (symbol (parse-integer (symbol-name count-raw))))))
         (loop for i from 0 below count
               collect (llvm-build-extract-value builder agg-val i (format nil "arr_elem_~a" i)))))
      (t (list agg-val)))))

;; src/codegen/abi.lisp
(defun implode-value (builder components type-spec module)
  "Combines components into an aggregate value if necessary. Returns a single LLVM value.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).
   For (array T N) fields: assembles N scalar components into an array value (SROA)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (record-type (crisp-type-to-llvm-type lookup-spec module))
              (agg (llvm-get-undef record-type))
              (current-components components))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (member-val (implode-value builder current-components member-type module))
                         (consumed-count (length (get-expanded-types member-type module))))
                    (setf agg (llvm-build-insert-value builder agg member-val i (format nil "~a_ins" (first m))))
                    (setf current-components (subseq current-components consumed-count))))
         agg))
      ;; (array T N): assemble N scalar components back into an array value (SROA)
      ((%array-type-p lookup-spec)
       (let* ((elem-type (cl:second lookup-spec))
              (count-raw (cl:third lookup-spec))
              (count (etypecase count-raw
                       (integer count-raw)
                       (symbol (parse-integer (symbol-name count-raw)))))
              (arr-llvm-type (crisp-type-to-llvm-type lookup-spec module))
              (result (llvm-get-undef arr-llvm-type))
              (current-components components))
         (loop for i from 0 below count
               do (let* ((elem-val (implode-value builder current-components elem-type module))
                         (consumed (length (get-expanded-types elem-type module))))
                    (setf result (llvm-build-insert-value builder result elem-val i
                                                         (format nil "arr_build_~a" i)))
                    (setf current-components (subseq current-components consumed))))
         result))
      (t (first components)))))

;;;; ============================================================
;;;; Bug 029 fix: %try-inline-struct-array-field-ptr — use the
;;;; addrspace(1) global pointer returned by the inner generate-node-ir
;;;; call (e.g. a cell dereference) instead of spilling to a local alloca.
;;;;
;;;; When arg-node is (~ c) where c is a cell, generate-node-ir returns:
;;;;   (values loaded-struct nil global-ptr)
;;;; The global-ptr is the addrspace(1) pointer into GPU memory.
;;;; The old code ignored it and spilled the loaded value to a local alloca,
;;;; causing the subsequent element store to write to local memory only.
;;;; The fix: if generate-node-ir returns a non-nil third value (the ptr),
;;;; use it directly as struct-ptr for the two-level GEP.
;;;; This ensures (set! (~ (values~ (~ c)) 2) 42) stores through the
;;;; global pointer and reaches GPU memory (fixes bug 029).
;;;; See: tests/spec/061-place-semantics/DESIGN.md
;;;; ============================================================

;; src/codegen.lisp
(defun %try-inline-struct-array-field-ptr
    (array-node builder module var-env di-builder di-scope location-map)
  "Workaround for IGC bug 028 + fix for bug 029 (place semantics).

   If ARRAY-NODE is a call to a struct field accessor (name ends with ~)
   whose return type is (array T N), emits a GEP directly into the struct's
   memory to produce a pointer to the array field — completely bypassing the
   accessor function call.

   Bug 029 fix: if the struct arg is not a simple var-read (e.g. it is a
   cell dereference like (~ c)), call generate-node-ir with multiple-value-bind
   to capture the third return value (the addrspace(1) global pointer).
   Use that pointer directly rather than spilling the loaded struct value to a
   local alloca, so that subsequent element stores write back to GPU memory.

   Returns the GEP pointer (ptr to [N x T]) if the pattern is recognized, or
   NIL otherwise so the caller can fall through to the normal path."
  (when (and (semantic-call-p array-node)
             (= (cl:length (semantic-call-args array-node)) 1))
    (let* ((call-type (semantic-call-type array-node))
           ;; Unwrap single-element list return types: ((array T N)) -> (array T N)
           (raw-type  (if (and (listp call-type)
                               (= (cl:length call-type) 1)
                               (listp (cl:first call-type)))
                          (cl:first call-type)
                          call-type)))
      (when (%array-type-p (resolve-type-alias raw-type))
        (let* ((call-name    (semantic-call-name array-node))
               (name-str     (symbol-name call-name)))
          ;; Only intercept accessor calls (name ends with ~)
          (when (and (> (cl:length name-str) 1)
                     (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~))
            (let* ((field-name-str  (subseq name-str 0 (1- (cl:length name-str))))
                   (arg-node        (cl:first (semantic-call-args array-node)))
                   (struct-type-sym (semantic-node-type arg-node))
                   (struct-def      (when (symbolp struct-type-sym)
                                      (lookup-struct-definition struct-type-sym))))
              (when struct-def
                (let ((physical-index (%lookup-field-physical-index struct-def field-name-str)))
                  (when physical-index
                    (log:info "028-fix: inlining struct accessor ~a (field '~a' idx=~a) to avoid array-returning fn"
                              call-name field-name-str physical-index)
                    (let* ((struct-llvm-type (ensure-struct-llvm-type struct-type-sym))
                           ;; Obtain a pointer to the struct in the function frame.
                           ;; If the arg is a simple var-read its alloca is already in var-env.
                           ;; Otherwise generate the struct value; if the inner node returns a
                           ;; global pointer (e.g. from a cell deref), use that directly (bug 029
                           ;; place-semantics fix).  Fall back to spilling to a local alloca only
                           ;; if no global pointer is available.
                           (struct-ptr
                             (if (semantic-var-read-p arg-node)
                                 (let ((alloca (gethash (semantic-var-read-name arg-node) var-env)))
                                   (log:info "028-fix: using alloca for var ~a" (semantic-var-read-name arg-node))
                                   alloca)
                                 (multiple-value-bind (sv _loc global-ptr)
                                     (generate-node-ir arg-node builder module var-env
                                                       di-builder di-scope location-map)
                                   (declare (ignore _loc))
                                   (if (and global-ptr (not (cffi:null-pointer-p global-ptr)))
                                       (progn
                                         (log:info "029-fix: cell-of-struct accessor: using global ptr directly (place-semantics write-back fix)")
                                         global-ptr)
                                       (let ((spill (llvm-build-alloca builder struct-llvm-type "struct_spill")))
                                         (log:info "028-fix: spilling struct value to local alloca (no global ptr)")
                                         (llvm-build-store builder sv spill)
                                         spill))))))
                      ;; Two-level GEP: struct_ptr[0].physical_index -> ptr to [N x T]
                      (cffi:with-foreign-object (gep-indices :pointer 2)
                        (setf (cffi:mem-aref gep-indices :pointer 0)
                              (llvm-const-int (llvm-int32-type) 0 nil))
                        (setf (cffi:mem-aref gep-indices :pointer 1)
                              (llvm-const-int (llvm-int32-type) physical-index nil))
                        (llvm-build-in-bounds-gep2
                         builder struct-llvm-type struct-ptr gep-indices 2 "arr_field_ptr")))))))))))))

