;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; =========================================================
;;; Fix (bug 029): cell-of-array and cell-of-struct-with-array write-back
;;;
;;; src/codegen.lisp — generate-node-ir (semantic-aref)
;;;
;;; Root cause: in the (array T N) branch, when array-node is a nested expression
;;; (e.g. (~ c) for a cell-of-array), the old code called generate-node-ir and
;;; captured only the primary return value (the loaded array aggregate). It then
;;; checked whether that value was a pointer type — but it never is, because
;;; generate-node-ir for a cell aref returns the LOADED VALUE as primary, with
;;; the addrspace(1) pointer as the THIRD return value.
;;;
;;; So the old code always fell into the "spill to local alloca" branch, and any
;;; subsequent store went to that local copy, never back to GPU memory.
;;;
;;; Fix: use multiple-value-bind to capture all three returns from the inner
;;; generate-node-ir call. If the third return (sub-ptr) is non-nil, use it
;;; directly as arr-ptr — it is already the correct addrspace(1) pointer into
;;; the cell's USM allocation. Only fall back to the pointer-value check or
;;; the alloca spill if sub-ptr is nil.
;;; =========================================================

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-aref) builder module var-env di-builder di-scope location-map)
  "Generates IR for array/cell access (aref / ~).
   Case 1: CELL parameterized type  — existing behaviour unchanged.
   Case 2: (array T N) fixed-size array — GEP into the alloca (or pointer).
     For a simple var-read of type (array T N), the alloca is fetched directly
     from var-env so we never load the aggregate value before GEP-ing into it.
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
               ;; For a direct var-read, grab the alloca from var-env — no load needed.
               ;; For a nested expression, call generate-node-ir with multiple-value-bind:
               ;;   - If the third return (sub-ptr) is non-nil, it is already an addrspace(1)
               ;;     pointer (e.g. from a cell-of-array deref) — use it directly.
               ;;     This is the bug 029 fix: the old code ignored sub-ptr and fell into
               ;;     the alloca spill branch, so stores never reached GPU memory.
               ;;   - If sub-val is a pointer type (bare pointer expression), use it.
               ;;   - Otherwise spill the aggregate value to a local alloca for GEP.
               (arr-ptr
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
                       ;; Aggregate value (e.g. struct member accessor) — spill to temp alloca
                       (t
                        (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                          (llvm-build-store builder sub-val slot)
                          slot))))))
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

