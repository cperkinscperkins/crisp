;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/codegen.lisp
;; Forced update to clear stale FASL
(in-package :crisp.compiler)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun get-or-create-di-type (crisp-type di-builder di-type-cache)
  "Gets a DIBasicType from a cache or creates it if it doesn't exist."
  (if crisp-type
      ;; It's a known, simple type.
      (or (gethash (crisp-type-name crisp-type) di-type-cache)
          (let* ((name-str (string-downcase (symbol-name (crisp-type-name crisp-type))))
                 (encoding (ecase (crisp-type-category crisp-type)
                             (:signed-int 5)     ; DW_ATE_signed
                             (:unsigned-int 7)   ; DW_ATE_unsigned
                             (:float 4)          ; DW_ATE_float
                             (:struct 7)         ; Fallback: unsigned blob
                             (:record 7)         ; Treat record as struct/unsigned
                             (:pointer 7)
                             (:device-vector 7)  ; SIMD vector: treat as unsigned blob
                             (:void (return-from get-or-create-di-type (cffi:null-pointer)))))
                 (di-type (llvm-di-builder-create-basic-type
                           di-builder name-str (length name-str)
                           (crisp-type-size crisp-type) encoding 0)))
            (setf (gethash (crisp-type-name crisp-type) di-type-cache) di-type)
            di-type))
      ;; It's an unknown or parameterized type. Create a placeholder.
      (or (gethash :unspecified di-type-cache)
          (let ((di-type (llvm-di-builder-create-basic-type di-builder "unspecified" (length "unspecified") 0 0 0)))
            (setf (gethash :unspecified di-type-cache) di-type)
            di-type))))


(defun generate-debug-info (di-builder di-compile-unit func fn-name fn-loc return-type param-nodes location-map)
  "Generates and attaches DWARF debug info for the function."
  (when di-builder
        (let ((di-type-cache (make-hash-table)))
          ;; File info
          (let* ((di-file (when di-compile-unit
                                (llvm-di-builder-create-file di-builder
                                                             "test.crisp" (length "test.crisp")
                                                             "/tmp/" (length "/tmp/"))))
                 (line-num (if location-map (or (gethash fn-loc location-map) 0) 0)))

            ;; Type info
            (let* ((di-return-type (get-or-create-di-type (gethash return-type *crisp-types*)
                                                          di-builder
                                                          di-type-cache))
                   (di-param-types (cons di-return-type
                                         (loop for param in param-nodes
                                               collect (get-or-create-di-type
                                                        (gethash (semantic-param-type param) *crisp-types*)
                                                        di-builder
                                                        di-type-cache)))))

              ;; Parameter array
              (let* ((di-param-array (let ((ptr (cffi:foreign-alloc :pointer :count (length di-param-types))))
                                       (loop for i from 0
                                             for type in di-param-types
                                             do (setf (cffi:mem-aref ptr :pointer i) type))
                                       ptr))
                     ;; Function type
                     (di-fn-type (llvm-di-builder-create-subroutine-type
                                  di-builder di-file di-param-array (length di-param-types) 0))
                     ;; Subprogram
                     (subprogram (llvm-di-builder-create-function
                                  di-builder di-compile-unit
                                  fn-name (length fn-name)
                                  fn-name (length fn-name)
                                  di-file line-num di-fn-type nil t 0 0 nil)))

                (llvm-set-subprogram func subprogram)
                subprogram))))))



(defun %ptx-entry-illegal-addrspace-p (as)
  "PTX kernel entry-point param pointers may not target shared (NVPTX
   addrspace 3) or local (NVPTX addrspace 5).  Both are per-block /
   per-thread state spaces with no addressable launch-time value, and
   the CUDA driver rejects any cubin whose entry sig declares such
   a pointer."
  (or (= as 3) (= as 5)))

(defun %ptx-entry-demote-type (ty)
  "If TY is a pointer in an illegal-for-PTX-entry addrspace, returns
   i64 (the demoted form Crisp passes at the kernel boundary).
   Otherwise returns TY unchanged."
  (if (and (llvm-type-kind-is-pointer? ty)
           (%ptx-entry-illegal-addrspace-p (llvm-get-pointer-address-space ty)))
      (progn
        (log:info "PTX kernel-entry demoter: replacing addrspace(~A) ptr with i64"
                  (llvm-get-pointer-address-space ty))
        (llvm-int64-type))
      ty))

(defun %verify-ptx-entry-expanded-types (expanded-types fn-name)
  "Walks an already-demoted EXPANDED-TYPES list and ERRORs if any entry
   is still an illegal-for-entry pointer (shared/local).  Called from
   inside CREATE-LLVM-FUNCTION-TYPE on the post-demotion list, so this
   should never fire in correct code — it's a belt-and-suspenders check
   for future regressions where a new pointer-producing path slips past
   %PTX-ENTRY-DEMOTE-TYPE.

   We check expanded LLVM types rather than walking the live func via
   llvm-count-params because we already have the list at the demotion
   site and there's no Crisp binding for LLVMCountParams (avoiding the
   need to plumb a new foreign binding through llvm-bindings-overlay)."
  (loop for ty in expanded-types
        for i from 0
        when (and (llvm-type-kind-is-pointer? ty)
                  (%ptx-entry-illegal-addrspace-p
                   (llvm-get-pointer-address-space ty)))
        do (error "PTX kernel-entry verifier: kernel '~A' expanded-param #~A is~%~
                   a pointer in illegal addrspace ~A.  CUDA driver would~%~
                   reject this kernel image (`.ptr .shared` / `.ptr .local`~%~
                   are not legal on kernel entry).  This is a compiler bug —~%~
                   %PTX-ENTRY-DEMOTE-TYPE should have caught it in~%~
                   CREATE-LLVM-FUNCTION-TYPE."
                  fn-name i (llvm-get-pointer-address-space ty))))

(defun %ptx-entry-restore-shared-ptrs-for-implode
    (builder components type-spec module is-entry-point)
  "Counterpart to the demoter: at the receive site, the kernel's LLVM
   param at a demoted slot is now an i64.  IMPLODE-VALUE expects a
   pointer in the original addrspace there, so inttoptr each demoted
   component back before packing.  No-op for non-PTX, non-entry, and
   for params whose expanded types had no demotable pointer."
  (if (and (eq *target-backend* :ptx) is-entry-point)
      (let ((expected-types (get-expanded-types type-spec module)))
        (loop for comp in components
              for exp-ty in expected-types
              collect (if (and (llvm-type-kind-is-pointer? exp-ty)
                               (%ptx-entry-illegal-addrspace-p
                                (llvm-get-pointer-address-space exp-ty)))
                          (progn
                            (log:info "PTX kernel-entry receive: inttoptr i64 -> addrspace(~A) ptr"
                                      (llvm-get-pointer-address-space exp-ty))
                            (llvm-build-int-to-ptr builder comp exp-ty
                                                   "demoted_param_to_ptr"))
                          comp)))
      components))



(defun initialize-function-parameters (builder func param-nodes module var-env
                                       &optional is-entry-point)
  "Allocates stack space and stores function parameters.
   When IS-ENTRY-POINT is non-NIL and *TARGET-BACKEND* is :PTX, restores
   any param components that the kernel-entry demoter swapped from
   shared/local pointer to i64 (see header comment in this overlay)."
    (let ((llvm-param-index 0))
      (loop for param-node in param-nodes
            for param-name = (semantic-param-name param-node)
            for type-spec = (semantic-param-type param-node)
            do
            (let* ((expanded-types (get-expanded-types type-spec module))
                   (num-expanded (length expanded-types))
                   (raw-components
                    (loop for i from 0 below num-expanded
                          for p = (llvm-get-param func (+ llvm-param-index i))
                          do (log:debug "llvm-get-param ~a -> ~a" (+ llvm-param-index i) p)
                          collect p))
                   (components
                    (%ptx-entry-restore-shared-ptrs-for-implode
                     builder raw-components type-spec module is-entry-point))
                   (imploded-val (implode-value builder components type-spec module))
                   (alloca (llvm-build-alloca builder (crisp-type-to-llvm-type type-spec module) (string-downcase param-name))))
              (log:info "imploded-val: ~a, alloca: ~a" imploded-val alloca)
              (unless imploded-val (error "imploded-val is NIL for type ~a" type-spec))
              (unless alloca (error "alloca is NIL for type ~a" type-spec))
              (llvm-build-store builder imploded-val alloca)
              (setf (gethash param-name var-env) alloca)
              (incf llvm-param-index num-expanded)))))

;; Patch to add SPIR-V kernel metadata functions to codegen.lisp
;; Insert BEFORE the line: (defun generate-function-prototype

(defun %apply-denormal-attribute (func module)
  "Endeavor 126: stamp the `denormal-fp-math` (and `-f32`) function attribute on FUNC
   per *denormal-handling* — :ftz -> \"preserve-sign,preserve-sign\" (flush subnormals),
   :preserve -> \"ieee,ieee\" (strict IEEE). NVPTX honours these directly; the SPIR-V
   DenormFlushToZero execution mode is emitted separately. Applied to every function."
  (let* ((val (if (eq *denormal-handling* :ftz) "preserve-sign,preserve-sign" "ieee,ieee"))
         (ctx (llvm-get-module-context module)))
    (dolist (key '("denormal-fp-math" "denormal-fp-math-f32"))
      (let ((attr (llvm-create-string-attribute ctx key (length key) val (length val))))
        (llvm-add-attribute-at-index func +llvm-attribute-function-index+ attr)))))

(defun %emit-spirv-denorm-execution-mode (func module)
  "Endeavor 126: emit an !spirv.ExecutionMode metadata entry on kernel FUNC so the
   LLVM->SPIR-V translator emits DenormFlushToZero (4460, :ftz) or DenormPreserve
   (4459, :preserve) at width 32. The `denormal-fp-math` attribute alone does NOT
   reach SPIR-V (verified 2026-07-01), so this is required for the choice to take
   effect on the SPV/L0 path. Per-entry-point; SPV target only."
  (let* ((ctx (llvm-get-module-context module))
         (mode-id (if (eq *denormal-handling* :ftz) 4460 4459))
         (i32 (llvm-int32-type))
         (func-md  (llvm-value-as-metadata func))
         (mode-md  (llvm-value-as-metadata (llvm-const-int i32 mode-id 0)))
         (width-md (llvm-value-as-metadata (llvm-const-int i32 32 0))))
    (cffi:with-foreign-object (arr :pointer 3)
      (setf (cffi:mem-aref arr :pointer 0) func-md
            (cffi:mem-aref arr :pointer 1) mode-md
            (cffi:mem-aref arr :pointer 2) width-md)
      (let* ((node (llvm-md-node-in-context2 ctx arr 3))
             (node-val (crisp.llvm-bindings::llvm-metadata-as-value ctx node)))
        (llvm-add-named-metadata-operand module "spirv.ExecutionMode" node-val)))))

(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0))))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))

(defun %check-existing-function (existing fn-name di-builder di-compile-unit func crisp-return-type param-nodes location-map fn-loc module fn-type)
  "Helper: Handles redefinition or forward declaration of existing functions."
  (declare (ignore func))
  (cond
   ;; Case 1: Redefinition (Function has a body already). We must Replace it.
   ((> (llvm-count-basic-blocks existing) 0)
     (log:warn "Redefining function ~a (replacing existing definition)." fn-name)
     (llvm-delete-function existing)
     (let ((new-func (llvm-add-function module fn-name fn-type)))
       (let ((di-subprogram (generate-debug-info di-builder di-compile-unit new-func fn-name fn-loc crisp-return-type param-nodes location-map)))
         (values new-func di-subprogram))))

   ;; Case 2: Forward Declaration (Function has no body). Reuse it.
   (t
     (values existing nil)))) ; TODO: Debug info for definition of forward decl?

(defun %create-new-function (fn-name fn-type module di-builder di-compile-unit crisp-return-type param-nodes location-map fn-loc)
  "Helper: Creates a new function and its debug info."
  (let ((func (llvm-add-function module fn-name fn-type)))
    (let ((di-subprogram (generate-debug-info di-builder di-compile-unit func fn-name fn-loc crisp-return-type param-nodes location-map)))
      (values func di-subprogram))))


(defun generate-function-prototype (semantic-function module di-builder di-compile-unit location-map)
  "Generates the LLVM function prototype and debug info.
   For PTX entry points, threads IS-ENTRY-POINT and FN-NAME into
   CREATE-LLVM-FUNCTION-TYPE so shared/local pointer params get demoted
   to i64 at the kernel boundary, and the post-demotion verifier can
   error with the kernel name (see header comment)."
  (let* ((return-types (semantic-function-return-type semantic-function))
         (crisp-return-type (first return-types))
         (base-name (semantic-function-name semantic-function))
         (is-entry-point (semantic-function-is-entry-point semantic-function))

         (mangled-name (if is-entry-point
                           (string-downcase (symbol-name base-name))
                           (let ((param-type-specs (mapcar #'semantic-param-type (semantic-function-param-list semantic-function))))
                             (format nil "~a~{_~a~}" base-name (mapcar #'mangle-type-spec param-type-specs)))))

         (fn-name (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name))))
         (fn-loc (semantic-function-source-location semantic-function))
         (param-nodes (semantic-function-param-list semantic-function))
         (fn-type (create-llvm-function-type module return-types param-nodes is-entry-point fn-name)))

    (log:info "llvm-add-function: ~a Module: ~a" fn-name module)

    (setf *cached-int32-type* (llvm-int32-type))
    (setf *cached-int64-type* (llvm-int64-type))
    (log:debug "Cached INT32 (Global): ~a" *cached-int32-type*)

    (when (eq *target-backend* :ptx)
          (let ((type-obj (gethash crisp-return-type *crisp-types*)))
            (when (and type-obj (member (crisp-type-category type-obj) '(:struct :record)))
                  (log:warn "Skipping generation of function ~a on PTX due to struct return value (unsupported)." fn-name)
                  (return-from generate-function-prototype (values nil nil)))))

    (let ((existing (llvm-get-named-function module fn-name)))
      (if (and existing (not (cffi:null-pointer-p existing)))
          (%check-existing-function existing fn-name di-builder di-compile-unit
                                    (llvm-add-function module fn-name fn-type)
                                    crisp-return-type param-nodes location-map fn-loc module fn-type)
          (%create-new-function fn-name fn-type module di-builder di-compile-unit
                                crisp-return-type param-nodes location-map fn-loc)))))




;; Convention: when a def-kernel signature has an &out parameter, any
;; tensor parameter declared BEFORE &out (positional, &optional, or &key)
;; is treated as read-only.  Indexed reads via (~ T i) on such a tensor
;; get the LLVM `!invariant.load !{}` metadata, which NVPTX lowers to
;; `ld.global.nc.f32` — the non-coherent / texture-cache load path.
;; Hand-written CUDA gets this via `const float* __restrict__`.
;;
;; Documented limitations:
;;
;;   1. Kernels with no &out parameter are skipped (no read-only inference
;;      possible — kernel may write back through any of its params).
;;
;;   2. Only direct references `(~ paramsym i)` are detected.  Aliased
;;      references such as `(let ((x input)) (~ x i))` lose the optimisation
;;      — we conservatively don't propagate the read-only property through
;;      let-bindings or function calls.  No miscompile risk: missing the
;;      metadata is always safe, just slower.
;;
;;   3. Only tensor params benefit.  Cells written via `atomic-add!`
;;      would be miscompiled if marked, so we exclude them entirely.
;;
;; AD compatibility: under --differentiate, the backward kernel rebuilds
;; its param-list with the input/output split inverted (forward inputs
;; become _GRAD outputs and vice versa).  The same rule applies: any
;; tensor that's :in in the backward kernel can be marked read-only.

(defparameter *kernel-readonly-tensor-syms* nil
  "Hash-table set of kernel-param symbols whose indexed loads should be
   marked with !invariant.load metadata.  Bound by generate-function-body
   around the body codegen loop; read by the semantic-aref tensor case.
   NIL means no read-only inference applies (kernel has no &out, or non-
   kernel function).")

(defun %collect-readonly-tensor-param-syms (semantic-function)
  "Looks up SEMANTIC-FUNCTION's high-level (pre-flatten) declared
   signature in *KERNEL-DECLARED-SIGNATURES* and returns a hash-table
   of param symbols whose tensor reads can be marked invariant, or NIL
   if the convention doesn't apply.

   The convention applies iff the kernel's declared params include &OUT.
   Every param BEFORE the &OUT marker that is also a float or integer
   tensor goes into the returned set.

   Returns NIL when:
     - The function isn't a registered kernel (no entry in
       *KERNEL-DECLARED-SIGNATURES*).  Helper functions, accessors, and
       internally-generated functions all fall here — safe default.
     - The declared signature contains no &OUT marker (kernel may write
       through any param; no read-only inference possible).
     - No qualifying tensor params remain after filtering.

   Declared signature shape: a list of (PARAM-NAME . TYPE-SPEC) pairs,
   except &OUT itself which appears as (&OUT . &OUT)."
  (let* ((fn-name  (semantic-function-name semantic-function))
         (declared (gethash fn-name *kernel-declared-signatures*)))
    (when declared
      (let ((out-pos (position-if
                      (lambda (entry)
                        (and (consp entry)
                             (symbolp (car entry))
                             (string-equal (symbol-name (car entry)) "&OUT")))
                      declared)))
        (when out-pos
          (let ((ht (make-hash-table :test 'eq)))
            (loop for entry in declared
                  for i from 0
                  while (< i out-pos)
                  when (and (consp entry)
                            (symbolp (car entry))
                            (let ((t-spec (cdr entry)))
                              (or (crisp.compiler::%crisp-float-tensor-type-p t-spec)
                                  (crisp.compiler::%crisp-integer-tensor-type-p t-spec))))
                  do (setf (gethash (car entry) ht) t))
            (when (> (hash-table-count ht) 0) ht)))))))

(defun %attach-invariant-load (loaded-inst module)
  "Attach `!invariant.load !{}` metadata to the LLVM load instruction
   LOADED-INST.  The empty MD node is the LLVM convention for the
   invariant.load assertion.  NVPTX lowers `load` + `!invariant.load`
   to `ld.global.nc.f32` (texture-cache / non-coherent path).

   Note: LLVMMDNodeInContext2 returns an LLVMMetadataRef; LLVMSetMetadata
   expects an LLVMValueRef.  We wrap via LLVMMetadataAsValue."
  (let* ((ctx       (crisp.llvm-bindings::llvm-get-module-context module))
         (kind-name "invariant.load")
         (kind-id   (crisp.llvm-bindings::llvm-get-md-kind-id-in-context
                     ctx kind-name (length kind-name)))
         (empty-md-ref (crisp.llvm-bindings::llvm-md-node-in-context2
                        ctx (cffi:null-pointer) 0))
         (empty-md-val (crisp.llvm-bindings::llvm-metadata-as-value
                        ctx empty-md-ref)))
    (crisp.llvm-bindings::llvm-set-metadata loaded-inst kind-id empty-md-val)))

(defun %array-node-readonly-tensor-param-p (array-node)
  "Returns T if ARRAY-NODE is a direct reference (semantic-var-read)
   to a kernel-param symbol in *KERNEL-READONLY-TENSOR-SYMS*.  Aliased
   references (let-bindings, function-call results) return NIL — they
   degrade gracefully to a plain load."
  (and *kernel-readonly-tensor-syms*
       (semantic-var-read-p array-node)
       (gethash (semantic-var-read-name array-node)
                *kernel-readonly-tensor-syms*)))


(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function.
   Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the
   PTX kernel-entry receive site can inttoptr demoted i64 params back
   to their original-addrspace pointer.
   Binds *kernel-readonly-tensor-syms* around the body codegen so the
   semantic-aref tensor case can attach !invariant.load to direct
   reads of read-only kernel-param tensors."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function))
        (is-entry-point (semantic-function-is-entry-point semantic-function)))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env is-entry-point)

    (let ((*kernel-readonly-tensor-syms*
           (%collect-readonly-tensor-param-syms semantic-function)))
      (when *kernel-readonly-tensor-syms*
        (log:debug "Read-only tensor params for kernel ~a: ~a"
                   (semantic-function-name semantic-function)
                   (loop for k being the hash-keys of *kernel-readonly-tensor-syms*
                         collect k)))

      (let* ((body-nodes (semantic-function-body semantic-function))
             (is-void-return (or (null return-types)
                                 (equal return-types '(nil))
                                 (and (consp return-types) (symbolp (first return-types)) (string-equal (first return-types) "VOID"))))
             (last-val nil)
             (last-loc nil))
        (dolist (node body-nodes)
          (multiple-value-bind (val loc)
              (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
            (setf last-val val)
            (setf last-loc loc)))

        (let ((ret-inst (if is-void-return
                            (llvm-build-ret-void builder)
                            (let* ((ret-type-spec (first return-types))
                                   (expected-type (crisp-type-to-llvm-type ret-type-spec module))
                                   (actual-type (llvm-type-of last-val)))
                              (if (and (llvm-type-kind-is-pointer? actual-type)
                                       (not (llvm-type-kind-is-pointer? expected-type)))
                                  (llvm-build-ret builder (llvm-build-load2 builder expected-type last-val "ret_val"))
                                  (llvm-build-ret builder last-val))))))
          (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc)))))))

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



(defun %try-inline-struct-array-field-ptr
    (array-node builder module var-env di-builder di-scope location-map)
  "Bypass for array-returning struct field accessors (e.g. extents~, strides~).
   Resolves type aliases and canonical list types to mangled symbols so that
   scratch tensors (with def-type alias or with list type) get the same GEP
   treatment as named tensors.

   Returns a GEP pointer to the array field, or NIL if the pattern is not matched."
  (when (and (semantic-call-p array-node)
             (= (length (semantic-call-args array-node)) 1))
    (let* ((call-type (semantic-call-type array-node))
           (raw-type  (if (and (listp call-type)
                               (= (length call-type) 1)
                               (listp (first call-type)))
                          (first call-type)
                          call-type)))
      (when (%array-type-p (resolve-type-alias raw-type))
        (let* ((call-name    (semantic-call-name array-node))
               (name-str     (symbol-name call-name)))
          (when (and (> (length name-str) 1)
                     (char= (cl:char name-str (1- (length name-str))) #\~))
            (let* ((field-name-str  (subseq name-str 0 (1- (length name-str))))
                   (arg-node        (first (semantic-call-args array-node)))
                   (raw-type-sym    (semantic-node-type arg-node))
                   ;; NEW v2: resolve alias then expand storage handle spec,
                   ;; then mangle if it's a tensor/vector/matrix family.
                   (struct-type-sym
                    (let* (;; 1. Resolve type alias (e.g. SC-INT-MAT -> (matrix int ...))
                              (resolved-alias (resolve-type-alias raw-type-sym))
                              ;; 2. Expand storage handle (e.g. (matrix ...) -> (tensor ... 2 ...))
                              (expanded (if (consp resolved-alias)
                                            (expand-storage-handle-type-specifier resolved-alias)
                                            resolved-alias))
                              ;; 3. Check for tensor-family canonical head
                              (head (when (consp expanded) (first expanded))))
                      (if (and head
                               (symbolp head)
                               (member (symbol-name head)
                                          '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal))
                          ;; Mangle to symbol (result interned in same pkg as head)
                          (mangle-template-struct-name head (rest expanded))
                          ;; Otherwise keep original (already-mangled symbol or non-tensor type)
                          raw-type-sym)))
                   (struct-def      (when (symbolp struct-type-sym)
                                      (lookup-struct-definition struct-type-sym))))
              (when struct-def
                (let ((physical-index (%lookup-field-physical-index struct-def field-name-str)))
                  (when physical-index
                    (log:info "028-fix v2: inlining struct accessor ~a (field '~a' idx=~a, resolved from ~a)"
                              call-name field-name-str physical-index raw-type-sym)
                    (let* ((struct-llvm-type (ensure-struct-llvm-type struct-type-sym))
                           (struct-ptr
                             (if (semantic-var-read-p arg-node)
                                 (let ((alloca (gethash (semantic-var-read-name arg-node) var-env)))
                                   (log:info "028-fix v2: using alloca for var ~a" (semantic-var-read-name arg-node))
                                   alloca)
                                 (multiple-value-bind (sv _loc global-ptr)
                                     (generate-node-ir arg-node builder module var-env
                                                       di-builder di-scope location-map)
                                   (declare (ignore _loc))
                                   (if (and global-ptr (not (cffi:null-pointer-p global-ptr)))
                                       (progn
                                         (log:info "029-fix v2: cell-of-struct accessor: using global ptr directly")
                                         global-ptr)
                                       (let ((spill (llvm-build-alloca builder struct-llvm-type "struct_spill")))
                                         (log:info "028-fix v2: spilling struct value to local alloca")
                                         (llvm-build-store builder sv spill)
                                         spill))))))
                      (cffi:with-foreign-object (gep-indices :pointer 2)
                        (setf (cffi:mem-aref gep-indices :pointer 0)
                              (llvm-const-int (llvm-int32-type) 0 nil))
                        (setf (cffi:mem-aref gep-indices :pointer 1)
                              (llvm-const-int (llvm-int32-type) physical-index nil))
                        (llvm-build-in-bounds-gep2
                         builder struct-llvm-type struct-ptr gep-indices 2 "arr_field_ptr")))))))))))))


(defun generate-llvm-ir (semantic-function module builder di-builder di-compile-unit location-map)
  "Top-level function to generate LLVM IR for a given semantic function."
  (log:warn "GENERATE-LLVM-IR: ~a Params: ~a Ret: ~a"
            (semantic-function-name semantic-function)
            (semantic-function-param-list semantic-function)
            (semantic-function-return-type semantic-function))
  (log:warn "BODY: ~a" (semantic-function-body semantic-function))

  (multiple-value-bind (func di-subprogram)
      (generate-function-prototype semantic-function module di-builder di-compile-unit location-map)
    (when func
          ;; Attach SPIR-V/PTX kernel metadata if this is an entry point
          (ensure-opencl-kernel-metadata func semantic-function module)
          (generate-function-body semantic-function func di-subprogram builder module di-builder location-map))))

(defgeneric generate-node-ir (node builder module var-env di-builder di-scope location-map)
  (:documentation "Generates LLVM IR for a single semantic node."))

(defun %get-di-location (node module di-builder di-scope location-map)
  "Helper: Creates and returns a debug location if debug metadata is available."
  (when (and di-builder di-scope location-map)
    (let* ((loc (semantic-node-source-location node))
           (line (gethash loc location-map 0)))
      (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                             line 0 di-scope (cffi:null-pointer)))))

(defun %attach-debug-loc (inst node module di-builder di-scope location-map)
  "Helper: Creates and attaches a debug location to the instruction if metadata is available."
  (let ((di-loc (%get-di-location node module di-builder di-scope location-map)))
    (when di-loc
      (llvm-instruction-set-debug-loc inst di-loc))
    di-loc))

(defun generate-expression-ir (builder module var-env di-builder di-scope location-map node)
  "Recursively generates IR for a single expression node."
  (generate-node-ir node builder module var-env di-builder di-scope location-map))

(defmethod generate-node-ir ((node semantic-return) builder module var-env di-builder di-scope location-map)
  "Generates IR for an implicit return. The value is just the value of the inner node."
  (generate-node-ir (semantic-return-value-node node) builder module var-env di-builder di-scope location-map))

(defmethod generate-node-ir ((node semantic-explicit-return) builder module var-env di-builder di-scope location-map)
  "Generates IR for an explicit (return ...) form."
  (let* ((return-types (semantic-explicit-return-type node))
         (value-nodes (semantic-explicit-return-value-nodes node)))
    (cond
     ;; Single return value, just generate the value.
     ((and return-types (= (length return-types) 1) (not (null (first return-types))))
       (generate-node-ir (first value-nodes) builder module var-env di-builder di-scope location-map))
     ;; Multiple return values, build a struct.
     ((> (length return-types) 1)
       (log:debug "MVR Codegen: Building struct for types: ~s" return-types)
       (let* ((struct-type (get-llvm-return-type module return-types))
              ;; Start with an undefined struct value. We will build it up.
              (agg-val (llvm-get-undef struct-type)))
         (log:debug "MVR Codegen: Struct type: ~s, initial undef value: ~s" struct-type agg-val)

         ;; Iteratively insert each value into the aggregate.
         ;; Each `insertvalue` returns a *new* aggregate value.
         (loop for i from 0
               for val-node in value-nodes
               do (multiple-value-bind (val-ir val-loc)
                      (generate-node-ir val-node builder module var-env di-builder di-scope location-map)
                    (declare (ignore val-loc))
                    (log:debug "MVR Codegen: Inserting value ~s into index ~a of aggregate ~s" val-ir i agg-val)
                    (setf agg-val (llvm-build-insert-value builder agg-val val-ir i (format nil "mvr_val_~a" i)))))
         (values agg-val nil)))
     ;; No return values (void return)
     (t (values nil nil)))))

(defun resolve-keyword-constant (kw)
  "Resolves a keyword to its integer value by searching all registered enumerations."
  (if (integerp kw) kw
      (progn
       (maphash (lambda (name enum-def)
                  (declare (ignore name))
                  (let ((memb (assoc kw (crisp.compiler::enumeration-def-members enum-def))))
                    (when memb (return-from resolve-keyword-constant (cdr memb)))))
                *crisp-enums*)
       ;; Fallback: Hash the keyword for generic usage (e.g. &key tags)
       (ldb (byte 32 0) (sxhash kw)))))

;; -- literal value --

(defun %generate-keyword-literal-ir (value)
  "Helper: Generates IR for keyword/symbol/quote literals."
  (let ((ival (resolve-keyword-constant value)))
    (llvm-const-int (llvm-int32-type) ival nil)))

(defun %generate-cell-literal-ir (builder module var-env type-spec value)
  "Helper: Generates IR for cell literals (scratch cells)."
  (declare (ignore value))
  ;; Need to find the implicit argument corresponding to this cell literal.
  ;; We rely on the unique-name generated in Pass 1 (which used a deterministic counter).
  ;; So long as we traverse in the exact same order (which we do), we can reconstruct the ID.
  (let* ((base-type (first type-spec))
         (context crisp.compiler::*compiler-context*) ;; Access global context for function name
         (binding-name (or (crisp.compiler::compiler-context-current-binding-name context) '__storage))
         (fn-name (and context (crisp.compiler::compiler-context-current-compiling-function context))) ;; Use compiling-function, not scanning
         (counter (incf crisp.compiler::*scratch-cell-counter*))
         ;; Reconstruct the Unique Name
         (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
         (unique-name (intern unique-name-str (symbol-package binding-name)))

         ;; Lookup directly in environment (injected by internal-compile-function)
         (storage-alloca (gethash unique-name var-env)))

    (log:info "Pass 2: make-scratch-cell ~a -> looking for implicit: ~a (Found? ~a)" binding-name unique-name (not (null storage-alloca)))

    (unless storage-alloca
      (error "Missing implicit argument ~a for make-scratch-cell. Environment keys: ~s"
        unique-name (alexandria:hash-table-keys var-env)))

    (let* ((as (if (consp type-spec) (nth 2 type-spec) :global))
           ;; Use the specific storage type (templated logic)
           (storage-spec `(storage ,as))
           (storage-type (crisp-type-to-llvm-type storage-spec module))
           ;; Bitcast the alloca (which is a cell*) to a storage* to load the first member
           (storage-ptr-type (llvm-pointer-type storage-type 0))
           (casted-ptr (llvm-build-bit-cast builder storage-alloca storage-ptr-type "cast_sc_storage"))
           (storage-val (llvm-build-load2 builder storage-type casted-ptr "storage_val"))
           (mangled-name (mangle-template-struct-name base-type (rest type-spec)))
           (cell-struct-type (ensure-struct-llvm-type mangled-name))
           (cell-undef (llvm-get-undef cell-struct-type))
           (cell-0 (llvm-build-insert-value builder cell-undef storage-val 0 "parent"))
           (cell-1 (llvm-build-insert-value builder cell-0
                                            (llvm-const-int (llvm-int64-type) 0 nil)
                                            1 "offset"))
           (cell-handle (llvm-build-alloca builder cell-struct-type "cell_lit_handle")))
      (llvm-build-store builder cell-1 cell-handle)
      ;; RETURN THE VALUE (cell-1), NOT THE POINTER (cell-handle).
      ;; The alloca above is still useful if this literal is being bound to a variable 
      ;; (the caller's let-binding logic might expect an alloca to be available in var-env, 
      ;; but generate-expression-ir returns the VALUE). 
      ;; Wait, let-binding logic uses the returned value to store into ITS own alloca. 
      ;; So returning the value is correct.
      cell-1)))

(defun %generate-enum-literal-ir (builder value llvm-type)
  "Helper: Generates IR for enum literals."
  (let* ((val (resolve-keyword-constant value))
         (target-type (or llvm-type (llvm-int32-type)))
         (val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) val) nil)))
    (llvm-build-trunc builder val-i64 target-type "enum_trunc")))

(defun %generate-scalar-literal-ir (builder value llvm-type crisp-type)
  "Helper: Generates IR for scalar (int/float) literals."
  (cond
   ;; Integer types
   ((member (crisp-type-category crisp-type) '(:signed-int :unsigned-int))
     (if (zerop value)
         (llvm-const-null llvm-type)
         (let ((val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) value) nil)))
           (if (= (crisp-type-size crisp-type) 64)
               val-i64
               (llvm-build-trunc builder val-i64 llvm-type "int_trunc")))))

   ;; Float types
   ((eq (crisp-type-category crisp-type) :float)
     (llvm-const-real llvm-type (coerce value 'double-float)))

   ;; Void
   ((eq (crisp-type-category crisp-type) :void)
     nil)

   (t
     (error "Codegen for literal of unknown type category: ~a" (crisp-type-name crisp-type)))))



(defun %generate-tensor-scratch-literal-ir (builder module var-env type-spec value)
  "Generates IR for a scratch tensor/vector/matrix literal.

   Unlike scratch cells, scratch tensors use Option B (full SROA): the host
   passes every field of the tensor record individually (ptr, bytesize, each
   offset, stride, extent, and length).  The SROA/reconstruction machinery
   in internal-compile-function therefore delivers a fully-assembled tensor
   record value into var-env under the unique implicit-arg name.

   All we need to do here is:
     1. Reconstruct the deterministic unique name (same counter + ordering as Pass 1).
     2. Look up the tensor alloca in var-env.
     3. Load and return the tensor value."
  (declare (ignore module value))
  (let* ((context *compiler-context*)
         (binding-name (or (compiler-context-current-binding-name context) '__storage))
         (fn-name (and context (compiler-context-current-compiling-function context)))
         (counter (incf *scratch-cell-counter*))
         (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
         (unique-name (intern unique-name-str (symbol-package binding-name)))
         (tensor-alloca (gethash unique-name var-env)))

    (log:info "Pass 2: scratch tensor ~a -> implicit: ~a (found? ~a)"
              binding-name unique-name (not (null tensor-alloca)))

    (unless tensor-alloca
      (error "Missing implicit argument ~a for ~a. var-env keys: ~s"
             unique-name type-spec (alexandria:hash-table-keys var-env)))

    ;; The alloca holds the fully-assembled tensor record (all fields provided
    ;; by the host via SROA expansion).  Load and return the value.
    (let* ((mangled-name (mangle-template-struct-name (first type-spec) (rest type-spec)))
           (tensor-struct-type (ensure-struct-llvm-type mangled-name))
           (tensor-val (llvm-build-load2 builder tensor-struct-type tensor-alloca "scratch_tensor_val")))
      tensor-val)))




(defmethod generate-node-ir ((node semantic-literal) builder module var-env
                             di-builder di-scope location-map)
  "Generates IR for a literal value.
   Extended to handle scratch tensor/vector/matrix literals."
  (let* ((type-spec (semantic-literal-value-type node))
         (value (semantic-literal-value node))
         (llvm-type (unless (member type-spec '(keyword symbol quote))
                      (crisp-type-to-llvm-type type-spec module)))
         (result
          (cond
           ;; Keywords/symbols/quotes (simple case)
           ((or (eq type-spec 'keyword) (eq type-spec 'symbol) (eq type-spec 'quote))
             (%generate-keyword-literal-ir value))

           ;; Parameterized types (lists)
           ((listp type-spec)
             (let ((base-type (first type-spec)))
               (cond
                ;; Function literals
                ((or (eq base-type :function-literal) (eq base-type :function-type))
                  (llvm-get-undef llvm-type))

                ;; Keywords/symbols in list form
                ((or (eq base-type 'keyword) (eq base-type 'symbol))
                  (%generate-keyword-literal-ir value))

                ;; Cell literals (scratch cell)
                ((eq base-type 'cell)
                  (%generate-cell-literal-ir builder module var-env type-spec value))

                ;; Tensor/vector/matrix scratch literals
                ((string-equal (symbol-name base-type) "TENSOR")
                  (%generate-tensor-scratch-literal-ir builder module var-env type-spec value))

                (t
                  (error "Codegen not implemented for literal of type ~a" type-spec)))))

           ;; Simple or singleton types
           ((or (symbolp type-spec)
                (and (consp type-spec) (member (first type-spec) '(keyword symbol quote))))
             (let ((type-sym (if (consp type-spec) (first type-spec) type-spec)))
               (cond
                ;; Enums
                ((or (gethash type-spec *crisp-enums*)
                     (member type-sym '(keyword symbol quote)))
                  (%generate-enum-literal-ir builder value llvm-type))
                ;; Scalars (int/float/etc.)
                (t
                  (let ((crisp-type (gethash type-sym *crisp-types*)))
                    (unless crisp-type
                      (error "Codegen: Literal type ~a not found in *crisp-types* or *crisp-enums*"
                             type-spec))
                    (%generate-scalar-literal-ir builder value llvm-type crisp-type))))))

           (t
             (error "Codegen not implemented for literal of type ~a" type-spec))))

         (di-location (%get-di-location node module di-builder di-scope location-map)))
    (values result di-location)))


;; -- reading a variable --

(defmethod generate-node-ir ((node semantic-var-read) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for reading a variable.
   IGC workaround: emits a volatile load when NODE is tagged in
   *volatile-var-reads*."
  (declare (ignore di-builder di-scope location-map))
  (log:debug "Generating IR for var-read: ~s" (semantic-var-read-name node))
  (let* ((var-name (semantic-var-read-name node))
         (alloca (gethash var-name var-env)))
    (when (null alloca)
      (log:error "CRITICAL: Var ~a not found in var-env!" var-name)
      (log:error "Var-env keys: ~a" (alexandria:hash-table-keys var-env)))
    (let* ((type (crisp-type-to-llvm-type (semantic-var-read-type node) module))
           (loaded-name (string-downcase (format nil "~a" var-name)))
           (load-inst (llvm-build-load2 builder type alloca loaded-name)))
      (log:info "Var-read: ~a. Alloca: ~a. Type: ~a" var-name alloca type)
      (when (gethash node *volatile-var-reads*)
        (log:debug "Var-read ~a marked volatile (IGC workaround)" var-name)
        (crisp.llvm-bindings::llvm-set-volatile load-inst 1))
      (values load-inst nil))))

;; -- addition --
(defun get-type-cat-safe (type-name type-obj)
  (cond
   (type-obj (crisp-type-category type-obj))
   ((and (symbolp type-name) (gethash type-name *crisp-enums*)) :signed-int)
   ((and (consp type-name) (eq (first type-name) 'c-pointer)) :pointer)
   (t nil)))




(defun build-cast-if-needed (builder module from-val from-type-name to-type-name)
  "Builds LLVM cast instruction if types differ, with alias resolution.
   MODULE is required to resolve types correctly.
   Cross-package same-name fix: USHORT2 may be in :crisp-language or :crisp.compiler;
   treat same symbol-name as no-op cast."
  ;; Resolve aliases first
  (let ((from-type-name (resolve-type-alias from-type-name))
           (to-type-name (resolve-type-alias to-type-name)))
    ;; Fast path: identical (eq)
    (if (equal from-type-name to-type-name)
        (progn
         (log:debug "build-cast-if-needed: No cast needed for ~s" from-type-name)
         from-val)
        ;; Cross-package same-name: CRISP.COMPILER::USHORT2 == CRISP-LANGUAGE::USHORT2
        (if (and (symbolp from-type-name) (symbolp to-type-name)
                 (string= (symbol-name from-type-name) (symbol-name to-type-name)))
            (progn
             (log:debug "build-cast-if-needed: cross-package same-name, no cast needed for ~s" from-type-name)
             from-val)
            (let* ((from-type (if (symbolp from-type-name) (gethash from-type-name *crisp-types*) nil))
                   (to-type (if (symbolp to-type-name) (gethash to-type-name *crisp-types*) nil))
                   (to-llvm-type (crisp-type-to-llvm-type to-type-name module))
                   (from-cat (get-type-cat-safe from-type-name from-type))
                   (to-cat (get-type-cat-safe to-type-name to-type)))
              (log:debug "build-cast-if-needed: Casting from ~s to ~s" from-type-name to-type-name)
              (cond
               ;; Keywords and symbols cast to int
               ((and (or (member from-type-name '(keyword symbol quote))
                         (and (listp from-type-name) (member (first from-type-name) '(keyword symbol quote))))
                     (member to-cat '(:signed-int :unsigned-int)))
                 (let ((to-size (if to-type (crisp-type-size to-type) 32)))
                   (cond
                    ((< to-size 32)
                      (llvm-build-trunc builder from-val to-llvm-type "trunc_kw_cast"))
                    ((> to-size 32)
                      (llvm-build-sext builder from-val to-llvm-type "sext_kw_cast"))
                    (t from-val))))
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (eq to-cat :float))
                 (if (eq from-cat :signed-int)
                     (llvm-build-si-to-fp builder from-val to-llvm-type "si2fp_cast")
                     (llvm-build-ui-to-fp builder from-val to-llvm-type "ui2fp_cast")))
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (member to-cat '(:signed-int :unsigned-int)))
                 (let ((from-size (crisp-type-size from-type))
                       (to-size (crisp-type-size to-type)))
                   (cond
                    ((< to-size from-size)
                      (llvm-build-trunc builder from-val to-llvm-type "trunc_cast"))
                    ((> to-size from-size)
                      (if (eq from-cat :signed-int)
                          (llvm-build-sext builder from-val to-llvm-type "sext_cast")
                          (llvm-build-zext builder from-val to-llvm-type "zext_cast")))
                    (t from-val))))
               ((and (eq from-cat :float) (eq to-cat :float))
                 (let ((from-size (crisp-type-size from-type))
                       (to-size (crisp-type-size to-type)))
                   (cond
                    ((< to-size from-size)
                      (llvm-build-fp-trunc builder from-val to-llvm-type "fptrunc_cast"))
                    ((> to-size from-size)
                      (llvm-build-fp-ext builder from-val to-llvm-type "fpext_cast"))
                    (t from-val))))
               ((and (eq from-cat :float) (member to-cat '(:signed-int :unsigned-int)))
                 (if (eq to-cat :signed-int)
                     (llvm-build-fp-to-si builder from-val to-llvm-type "fp2si_cast")
                     (llvm-build-fp-to-ui builder from-val to-llvm-type "fp2ui_cast")))
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (eq to-cat :pointer))
                 (let ((as (llvm-get-pointer-address-space to-llvm-type)))
                   (if (= as 0)
                       (llvm-build-int-to-ptr builder from-val to-llvm-type "int2ptr_cast")
                       (let* ((generic-ptr-type (crisp-type-to-llvm-type '(c-pointer) module))
                              (tmp-ptr (llvm-build-int-to-ptr builder from-val generic-ptr-type "int2generic")))
                         (llvm-build-addrspace-cast builder tmp-ptr to-llvm-type "generic2as_cast")))))
               ((and (eq from-cat :pointer) (member to-cat '(:signed-int :unsigned-int)))
                 (llvm-build-ptr-to-int builder from-val to-llvm-type "ptr2int_cast"))
               ((and (eq from-cat :pointer) (eq to-cat :pointer))
                 (let ((from-as (llvm-get-pointer-address-space (llvm-type-of from-val)))
                       (to-as (llvm-get-pointer-address-space to-llvm-type)))
                   (if (= from-as to-as)
                       (llvm-build-bit-cast builder from-val to-llvm-type "ptr2ptr_cast")
                       (llvm-build-addrspace-cast builder from-val to-llvm-type "ptr2ptr_ascast"))))
               ;; Handle casts between derived types with same base type (same memory layout)
               ((and (symbolp from-type-name) (symbolp to-type-name))
                 (let ((from-base (get-type-base from-type-name))
                          (to-base (get-type-base to-type-name)))
                   (if (eq from-base to-base)
                       (progn
                        (log:debug "Derived type cast: ~a -> ~a (same base ~a, no-op)"
                                   from-type-name to-type-name from-base)
                        from-val)
                       (progn
                        (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
                        (log:error "  From Type: ~a (cat: ~a, base: ~a)" from-type from-cat from-base)
                        (log:error "  To Type:   ~a (cat: ~a, base: ~a)" to-type to-cat to-base)
                        (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
                        (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name)))))
               (t
                (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
                (log:error "  From Type: ~a (cat: ~a)" from-type from-cat)
                (log:error "  To Type:   ~a (cat: ~a)" to-type to-cat)
                (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
                (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name))))))))

(defun %apply-precision-fmf (inst)
  "Endeavor 126: when *math-precision* is :fast, stamp all fast-math flags on the
   FP-math instruction INST (guarded by llvm-can-value-use-fast-math-flags). Returns
   INST so it can wrap a build call inline. No-op under :ieee (plain FP left as-is).
   Per-instruction FMF is the only path the LLVM->SPIR-V translator honours."
  (when (and (eq *math-precision* :fast)
             inst (not (cffi:null-pointer-p inst))
             (/= 0 (llvm-can-value-use-fast-math-flags inst)))
    (llvm-set-fast-math-flags inst +llvm-fast-math-all+))
  inst)

;;; ---------------------------------------------------------------------------
;;; Endeavor 128 (Phase 2): fast-precision transcendentals on SPV -> OpenCL
;;; native_* builtins.
;;;
;;; Under `fast`, a transcendental with a native variant (sin/cos/tan/exp/log/
;;; log2/powr) is emitted as a call to the Itanium-mangled OpenCL builtin
;;; (e.g. _Z10native_sinf) instead of the precise `llvm.*` intrinsic. The
;;; LLVM->SPIR-V translator maps such calls to the native_* OpenCL.std ExtInst,
;;; BUT ONLY when the module carries !opencl.ocl.version metadata (otherwise the
;;; call stays an imported OpFunctionCall -> unresolved on L0). native_ builtins
;;; are f32-only and SPV-only; f64 / non-SPV / no-native-variant fall back to the
;;; precise intrinsic (still FMF-stamped under fast).
;;; ---------------------------------------------------------------------------

(defun %native-builtin-mangled-name (base-name arity)
  "Itanium-mangled name of an OpenCL native builtin taking ARITY float args.
   native_sin/1 -> _Z10native_sinf ; native_powr/2 -> _Z11native_powrff."
  (format nil "_Z~d~a~a" (length base-name) base-name
          (make-string arity :initial-element #\f)))

(defparameter *native-builtin-mangled-names*
  '("_Z10native_sinf" "_Z10native_cosf" "_Z10native_tanf"
    "_Z10native_expf" "_Z10native_logf" "_Z11native_log2f"
    "_Z11native_powrff")
  "The mangled OpenCL native builtins Crisp may emit under fast precision on SPV.")

(defun %module-uses-native-builtin-p (module)
  "T if MODULE declares any OpenCL native_* builtin. Used to decide whether to
   inject !opencl.ocl.version so the translator recognises the mangled calls.
   (NB: `return` is shadowed to Crisp's RETURN in :crisp.compiler, so use `some`.)"
  (some (lambda (n)
          (not (cffi:null-pointer-p (llvm-get-named-function module n))))
        *native-builtin-mangled-names*))

(defun %emit-opencl-version-metadata (module)
  "Endeavor 128: add !opencl.ocl.version / !opencl.spir.version = {2,0} so the
   LLVM->SPIR-V translator runs OpenCL-builtin recognition and maps native_*
   mangled calls to native_* OpenCL.std ExtInst. Without this metadata the calls
   translate to imported OpFunctionCall (unresolved at zeKernelCreate on L0)."
  (let* ((ctx (llvm-get-module-context module))
         (i32 (llvm-int32-type))
         (major-md (llvm-value-as-metadata (llvm-const-int i32 2 0)))
         (minor-md (llvm-value-as-metadata (llvm-const-int i32 0 0))))
    (cffi:with-foreign-object (arr :pointer 2)
      (setf (cffi:mem-aref arr :pointer 0) major-md
            (cffi:mem-aref arr :pointer 1) minor-md)
      (let* ((node (llvm-md-node-in-context2 ctx arr 2))
             (node-val (crisp.llvm-bindings::llvm-metadata-as-value ctx node)))
        (llvm-add-named-metadata-operand module "opencl.ocl.version" node-val)
        (llvm-add-named-metadata-operand module "opencl.spir.version" node-val)))))

;;; ---------------------------------------------------------------------------
;;; Endeavor 128 (Phase 4): transcendentals on PTX -> NVIDIA libdevice.
;;;
;;; NVPTX has no IEEE-precise native instruction for the transcendentals, and a
;;; bare `llvm.sin.f32` CRASHES llc. So on the PTX target a transcendental is
;;; emitted as a call to the libdevice symbol (__nv_sinf / __nv_sin, …); the user
;;; links libdevice.10.bc (reusing the FFI .bc plumbing), llc's NVPTX backend runs
;;; NVVMReflect from the nvvm-reflect-ftz module flag (driven by *denormal-handling*)
;;; and lowers the specialised body to native PTX. If libdevice is not linked the
;;; __nv_* symbol stays an undefined declaration -> we raise a clear compile error.
;;; ---------------------------------------------------------------------------

(defun %libdevice-fn-name (base f32-p)
  "libdevice symbol for BASE at the given width: __nv_sin -> __nv_sinf (f32) / __nv_sin (f64)."
  (format nil "~a~a" base (if f32-p "f" "")))

(defun %math-call-name (intrinsic-name native-name libdevice-base arity size)
  "Select the concrete callee for a math intrinsic given target + precision:
   PTX -> libdevice __nv_*; SPV + fast + f32 (with a native variant) -> OpenCL
   native_*; everything else (SPV ieee, f64, generic) -> the precise llvm.* intrinsic."
  (cond
   ((and (eq *target-backend* :ptx) libdevice-base)
     (%libdevice-fn-name libdevice-base (= size 32)))
   ((and native-name (eq *math-precision* :fast) (eq *target-backend* :spirv) (= size 32))
     (%native-builtin-mangled-name native-name arity))
   (t (format nil "~a.~a" intrinsic-name (if (= size 64) "f64" "f32")))))

(defun %set-nvvm-reflect-ftz (module ftz-p)
  "Set the nvvm-reflect-ftz module flag (Override behavior): 1 = flush-to-zero,
   0 = preserve. llc's NVPTX NVVMReflect pass reads it to resolve libdevice's
   __nvvm_reflect(\"__CUDA_FTZ\") calls at codegen time."
  (let* ((i32 (llvm-int32-type))
         (val-md (llvm-value-as-metadata (llvm-const-int i32 (if ftz-p 1 0) 0)))
         (key "nvvm-reflect-ftz"))
    ;; behavior 3 = LLVMModuleFlagBehaviorOverride (the C enum is 0-based: Error=0,
    ;; Warning=1, Require=2, Override=3 — this maps to IR-encoding 4). The binding's
    ;; comment lists the IR encoding; LLVMAddModuleFlag wants the C enum.
    (crisp.llvm-bindings::llvm-add-module-flag module 3 key (length key) val-md)))

(defun %ptx-finalize-libdevice (module)
  "PTX finalization for libdevice transcendentals. If the module calls any __nv_*
   (a transcendental lowered to a libdevice symbol): (1) error if it is still an
   undefined declaration -- libdevice.10.bc was not linked -- and (2) set the
   nvvm-reflect-ftz module flag from *denormal-handling*."
  (let ((uses-libdevice nil)
        (fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop until (cffi:null-pointer-p fn) do
      (let ((name (crisp.llvm-bindings::llvm-get-value-name fn)))
        (when (and name (uiop:string-prefix-p "__nv_" name))
          (setf uses-libdevice t)
          (when (zerop (crisp.llvm-bindings::llvm-count-basic-blocks fn))
            (error "Transcendental on the PTX target requires libdevice: '~a' is unresolved. Pass libdevice.10.bc (e.g. $CUDA_HOME/nvvm/libdevice/libdevice.10.bc) to the compiler." name))))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    (when uses-libdevice
      (%set-nvvm-reflect-ftz module (eq *denormal-handling* :ftz)))))

(defmacro def-binary-op-codegen (node-type int-inst float-inst accessor-prefix)
  (let ((left-accessor (intern (format nil "~a-LEFT-ARG" accessor-prefix)))
        (right-accessor (intern (format nil "~a-RIGHT-ARG" accessor-prefix)))
        (type-accessor (intern (format nil "~a-TYPE" accessor-prefix))))
    `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
       ,(format nil "Generates IR for ~a." node-type)
       (multiple-value-bind (lhs lhs-loc) (generate-node-ir (,left-accessor node) builder module var-env di-builder di-scope location-map)
         (declare (ignore lhs-loc))
         (multiple-value-bind (rhs rhs-loc) (generate-node-ir (,right-accessor node) builder module var-env di-builder di-scope location-map)
           (declare (ignore rhs-loc))
           (let* ((result-type-name (,type-accessor node))
                  (lhs-type-name (get-single-value-type (,left-accessor node)))
                  (rhs-type-name (get-single-value-type (,right-accessor node)))
                  ;; Ensure MVR structs are unpacked
                  (lhs-raw (extract-primary-value builder lhs (semantic-node-type (,left-accessor node))))
                  (rhs-raw (extract-primary-value builder rhs (semantic-node-type (,right-accessor node))))
                  (casted-lhs (build-cast-if-needed builder module lhs-raw lhs-type-name result-type-name))
                  (casted-rhs (build-cast-if-needed builder module rhs-raw rhs-type-name result-type-name))
                  (crisp-type (gethash result-type-name *crisp-types*))
                  (inst (if (eq (crisp-type-category crisp-type) :float)
                            (%apply-precision-fmf (,float-inst builder casted-lhs casted-rhs "fop_tmp"))
                            (,int-inst builder casted-lhs casted-rhs "iop_tmp")))
                  (di-location (%attach-debug-loc inst node module di-builder di-scope location-map)))
             (values inst di-location)))))))

(def-binary-op-codegen semantic-add llvm-build-add llvm-build-fadd "SEMANTIC-ADD")
(def-binary-op-codegen semantic-sub llvm-build-sub llvm-build-fsub "SEMANTIC-SUB")
(def-binary-op-codegen semantic-mul llvm-build-mul llvm-build-fmul "SEMANTIC-MUL")
;; Note: Div logic might need special handling for signed/unsigned later (sdiv vs udiv),
;; but simpler macro assumes sdiv for now or that llvm-build-sdiv is distinct.
;; Assuming signed integers for now as per initialized types.
(def-binary-op-codegen semantic-div llvm-build-sdiv llvm-build-fdiv "SEMANTIC-DIV")

(defmacro def-unary-math-codegen (node-type intrinsic-name &optional native-name libdevice-base)
  "Codegen for a unary FP math intrinsic. INTRINSIC-NAME is the precise `llvm.*`
   used under ieee (and for f64 / generic). NATIVE-NAME (SPV fast f32) and
   LIBDEVICE-BASE (PTX) select alternate callees; see %math-call-name."
  `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
     ,(format nil "Generates IR for ~a (~a; SPV-fast ~a; PTX ~a)." node-type intrinsic-name (or native-name "n/a") (or libdevice-base "n/a"))
     (multiple-value-bind (arg-val arg-loc) (generate-node-ir (slot-value node 'arg) builder module var-env di-builder di-scope location-map)
       (declare (ignore arg-loc))
       (let* ((arg-type-name (semantic-node-type (slot-value node 'arg)))
              (arg-crisp-type (gethash arg-type-name *crisp-types*))
              (arg-llvm-type (crisp-type-to-llvm-type arg-type-name module))
              (call-name (%math-call-name ,intrinsic-name ,native-name ,libdevice-base
                                          1 (crisp-type-size arg-crisp-type))))
         (flet ((mk1 () (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 1)))
                          (setf (cffi:mem-aref arr 'llvm-type-ref 0) arg-llvm-type)
                          arr)))
           (let ((f (llvm-get-named-function module call-name)))
             (when (cffi:null-pointer-p f)
                   (setf f (llvm-add-function module call-name
                                              (llvm-function-type arg-llvm-type (mk1) 1 nil))))
             (let* ((args-array (cffi:foreign-alloc 'llvm-value-ref :count 1))
                    (_ (setf (cffi:mem-aref args-array 'llvm-value-ref 0) arg-val))
                    ;; FMF under fast: no-op for native (already fast), but lets the
                    ;; precise-fallback ones (asin/acos/atan) hint approximation.
                    (inst (%apply-precision-fmf
                           (llvm-build-call2 builder
                                             (llvm-function-type arg-llvm-type (mk1) 1 nil)
                                             f args-array 1 "math_tmp")))
                    (di-location (%attach-debug-loc inst node module di-builder di-scope location-map)))
               (declare (ignore _))
               (values inst di-location))))))))

;;                        node          llvm.*      SPV-fast(native_*)  PTX(libdevice __nv_*)
(def-unary-math-codegen semantic-sin  "llvm.sin"  "native_sin"  "__nv_sin")
(def-unary-math-codegen semantic-cos  "llvm.cos"  "native_cos"  "__nv_cos")
(def-unary-math-codegen semantic-exp  "llvm.exp"  "native_exp"  "__nv_exp")
(def-unary-math-codegen semantic-log  "llvm.log"  "native_log"  "__nv_log")
(def-unary-math-codegen semantic-log2 "llvm.log2" "native_log2" "__nv_log2")
(def-unary-math-codegen semantic-tan  "llvm.tan"  "native_tan"  "__nv_tan")
;; No native_asin/acos/atan in OpenCL — precise ExtInst + FMF under fast on SPV.
;; On PTX they still need libdevice (like all transcendentals).
(def-unary-math-codegen semantic-asin "llvm.asin" nil "__nv_asin")
(def-unary-math-codegen semantic-acos "llvm.acos" nil "__nv_acos")
(def-unary-math-codegen semantic-atan "llvm.atan" nil "__nv_atan")

(defmacro def-binary-math-codegen (node-type intrinsic-name &optional native-name libdevice-base)
  "Endeavor 128: codegen for a binary FP math intrinsic (pow, atan2). Precise
   `llvm.*` under ieee; SPV fast f32 -> NATIVE-NAME (native_powr, base>=0); PTX ->
   libdevice LIBDEVICE-BASE (__nv_pow / __nv_atan2). See %math-call-name."
  `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
     ,(format nil "Generates IR for ~a (~a; SPV-fast ~a; PTX ~a)." node-type intrinsic-name (or native-name "n/a") (or libdevice-base "n/a"))
     (multiple-value-bind (lhs-val lhs-loc) (generate-node-ir (slot-value node 'left-arg) builder module var-env di-builder di-scope location-map)
       (declare (ignore lhs-loc))
       (multiple-value-bind (rhs-val rhs-loc) (generate-node-ir (slot-value node 'right-arg) builder module var-env di-builder di-scope location-map)
         (declare (ignore rhs-loc))
         (let* ((arg-type-name (semantic-node-type (slot-value node 'left-arg)))
                (arg-crisp-type (gethash arg-type-name *crisp-types*))
                (arg-llvm-type (crisp-type-to-llvm-type arg-type-name module))
                (call-name (%math-call-name ,intrinsic-name ,native-name ,libdevice-base
                                            2 (crisp-type-size arg-crisp-type))))
           (flet ((mk-param-array ()
                    (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                      (setf (cffi:mem-aref arr 'llvm-type-ref 0) arg-llvm-type)
                      (setf (cffi:mem-aref arr 'llvm-type-ref 1) arg-llvm-type)
                      arr)))
             (let ((f (llvm-get-named-function module call-name)))
               (when (cffi:null-pointer-p f)
                     (setf f (llvm-add-function module call-name
                                                (llvm-function-type arg-llvm-type (mk-param-array) 2 nil))))
               (let* ((args-array (cffi:foreign-alloc 'llvm-value-ref :count 2))
                      (_  (setf (cffi:mem-aref args-array 'llvm-value-ref 0) lhs-val))
                      (__ (setf (cffi:mem-aref args-array 'llvm-value-ref 1) rhs-val))
                      (inst (%apply-precision-fmf
                             (llvm-build-call2 builder
                                               (llvm-function-type arg-llvm-type (mk-param-array) 2 nil)
                                               f args-array 2 "math_tmp")))
                      (di-location (%attach-debug-loc inst node module di-builder di-scope location-map)))
                 (declare (ignore _ __))
                 (values inst di-location)))))))))

(def-binary-math-codegen semantic-pow   "llvm.pow"   "native_powr" "__nv_pow")
;; No native_atan2 in OpenCL — precise ExtInst + FMF under fast on SPV. PTX -> libdevice.
(def-binary-math-codegen semantic-atan2 "llvm.atan2" nil           "__nv_atan2")

;; -- comparisons --
(defun generate-comparison-ir (builder module var-env di-builder di-scope location-map node op-node-int op-node-float)
  "Helper to generate IR for comparison operators (<, >, =, etc)."
  (let (;; Oops, semantic-lt etc don't store signature effectively in common way, 
        ;; but they do store left-arg and right-arg. Let's assume standard accessors.
        (left-arg (slot-value node 'left-arg))
        (right-arg (slot-value node 'right-arg)))

    (multiple-value-bind (lhs lhs-loc) (generate-node-ir left-arg builder module var-env di-builder di-scope location-map)
      (declare (ignore lhs-loc))
      (multiple-value-bind (rhs rhs-loc) (generate-node-ir right-arg builder module var-env di-builder di-scope location-map)
        (declare (ignore rhs-loc))
        (let* ((lhs-type-name (get-single-value-type left-arg))
               ;; Determine common type (promote to float if mixed, else largest int)
               ;; For simplicity, we enforce strict typing or assume implicit cast logic is handled by semantic analysis?
               ;; Semantic analysis usually inserts casts. Let's assume types match or casts are explicit.
               ;; BUT wait, semantic-add handles implicit casts. Let's reuse build-cast-if-needed logic if possible.
               ;; Wait, semantic-lt structure: type, left-arg, right-arg.
               ;; But type is 'int (result). We need args types.
               (lhs-crisp-type (gethash lhs-type-name *crisp-types*))
               (cmp-inst
                (cond
                 ((member (crisp-type-category lhs-crisp-type) '(:signed-int :unsigned-int))
                   (llvm-build-icmp builder op-node-int lhs rhs "icmp_tmp"))
                 ((eq (crisp-type-category lhs-crisp-type) :float)
                   (llvm-build-fcmp builder op-node-float lhs rhs "fcmp_tmp"))
                 (t (error "Unsupported comparison type: ~a" lhs-type-name)))))

          ;; Convert i1 result to i32 (0 or 1) because Crisp uses int for booleans
          (let ((result (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext")))
            (values result nil)))))))

;; Redefining to be more generic and careful about accessors
(defmacro def-comparison-codegen (type-name int-pred float-pred accessor-prefix)
  (let ((left-accessor (intern (format nil "~a-LEFT-ARG" accessor-prefix)))
        (right-accessor (intern (format nil "~a-RIGHT-ARG" accessor-prefix))))
    `(defmethod generate-node-ir ((node ,type-name) builder module var-env di-builder di-scope location-map)
       (multiple-value-bind (lhs lhs-loc) (generate-node-ir (,left-accessor node) builder module var-env di-builder di-scope location-map)
         (declare (ignore lhs-loc))
         (multiple-value-bind (rhs rhs-loc) (generate-node-ir (,right-accessor node) builder module var-env di-builder di-scope location-map)
           (declare (ignore rhs-loc))
           (let* ((lhs-type-name (get-single-value-type (,left-accessor node)))
                  (lhs-type (gethash lhs-type-name *crisp-types*))
                  ;; Ensure MVR structs are unpacked (comparing primary values)
                  (lhs (extract-primary-value builder lhs (semantic-node-type (,left-accessor node))))
                  (rhs (extract-primary-value builder rhs (semantic-node-type (,right-accessor node))))
                  ;; Determine predicate based on type. Note: Signed vs Unsigned integers might need different predicates!
                  ;; This is a simplification. Ideally semantic analysis distinguishes signed/unsigned ops
                  ;; or we check the type category here.
                  (is-unsigned (eq (crisp-type-category lhs-type) :unsigned-int))
                  (int-pred-val ,int-pred)
                  ;; Adjust for unsigned if needed (e.g., UGT vs SGT)
                  (final-int-pred (if is-unsigned
                                      (case int-pred-val
                                        (,+llvm-int-sgt+ ,+llvm-int-ugt+)
                                        (,+llvm-int-sge+ ,+llvm-int-uge+)
                                        (,+llvm-int-slt+ ,+llvm-int-ult+)
                                        (,+llvm-int-sle+ ,+llvm-int-ule+)
                                        (t int-pred-val))
                                      int-pred-val))

                  (cmp-inst
                   (cond
                    ((member (crisp-type-category lhs-type) '(:signed-int :unsigned-int))
                      (llvm-build-icmp builder final-int-pred lhs rhs "icmp_tmp"))
                    ((eq (crisp-type-category lhs-type) :float)
                      (llvm-build-fcmp builder ,float-pred lhs rhs "fcmp_tmp"))
                    (t (error "Unsupported comparison type: ~a" lhs-type-name)))))

             (let ((result (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext")))
               (values result nil))))))))

(def-comparison-codegen semantic-eq +llvm-int-eq+ +llvm-real-oeq+ "SEMANTIC-EQ")
(def-comparison-codegen semantic-neq +llvm-int-ne+ +llvm-real-one+ "SEMANTIC-NEQ")
(def-comparison-codegen semantic-lt +llvm-int-slt+ +llvm-real-olt+ "SEMANTIC-LT")
(def-comparison-codegen semantic-le +llvm-int-sle+ +llvm-real-ole+ "SEMANTIC-LE")
(def-comparison-codegen semantic-gt +llvm-int-sgt+ +llvm-real-ogt+ "SEMANTIC-GT")
(def-comparison-codegen semantic-ge +llvm-int-sge+ +llvm-real-oge+ "SEMANTIC-GE")

(defun prepare-call-arguments (builder module var-env di-builder di-scope location-map arg-nodes param-types param-count)
  "Prepares arguments for a function call by generating IR, exploding values, and filling a CFFI array."
  (let ((args-array (cffi:foreign-alloc 'llvm-value-ref :count param-count))
        (idx 0))
    (loop for arg-node in arg-nodes
          for param-type-spec in param-types ; param-types is already a list of type-specs
          do (multiple-value-bind (arg-val arg-loc) (generate-node-ir arg-node builder module var-env di-builder di-scope location-map)
               (declare (ignore arg-loc))
               (let* ((arg-type-spec (semantic-node-type arg-node))
                      (prim-val (extract-primary-value builder arg-val arg-type-spec))
                      (exploded-vals (explode-value builder prim-val param-type-spec)))
                 (dolist (val exploded-vals)
                   (setf (cffi:mem-aref args-array 'llvm-value-ref idx) val)
                   (incf idx)))))
    args-array))

(defmacro def-cast-codegen (node-type docstring arg-accessor type-accessor &body body)
  `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
     ,docstring
     (multiple-value-bind (raw-arg-val arg-loc)
         (generate-node-ir (,arg-accessor node) builder module var-env di-builder di-scope location-map)
       (declare (ignore arg-loc))
       (let* ((arg-node (,arg-accessor node))
              (arg-type (semantic-node-type arg-node))
              (arg-val (extract-primary-value builder raw-arg-val arg-type))
              (from-type-spec (get-single-value-type arg-node))
              (to-type-spec (,type-accessor node))
              (to-llvm-type (ignore-errors (crisp-type-to-llvm-type to-type-spec module))))
         (declare (ignorable from-type-spec to-type-spec to-llvm-type))
         (values (progn ,@body) nil)))))

(def-cast-codegen semantic-value-cast "Generates IR for a value-preserving cast."
  semantic-value-cast-arg semantic-value-cast-type
  (build-cast-if-needed builder module arg-val from-type-spec to-type-spec))

(def-cast-codegen semantic-bitcast "Generates IR for a bitcast."
  semantic-bitcast-arg semantic-bitcast-type
  (llvm-build-bit-cast builder arg-val to-llvm-type "bitcast"))

(def-cast-codegen semantic-fp-truncate-cast "Generates IR for a float-to-integer truncation cast."
  semantic-fp-truncate-cast-arg semantic-fp-truncate-cast-type
  (llvm-build-fp-to-si builder arg-val to-llvm-type "fptosi"))

(def-cast-codegen semantic-truncate "Generates IR for (truncate val) -> (values int rem)."
  semantic-truncate-arg semantic-truncate-type
  (let* ((quot-type (or *cached-int32-type* (llvm-int32-type)))
         (rem-type (llvm-float-type)) ;; Assuming float input for now
         (quot-val (llvm-build-fp-to-si builder arg-val quot-type "quot"))
         (quot-float (llvm-build-si-to-fp builder quot-val rem-type "quot_f"))
         (rem-val (llvm-build-fsub builder arg-val quot-float "rem"))
         (struct-type (get-llvm-return-type module to-type-spec))
         (agg-undef (llvm-get-undef struct-type))
         (agg-0 (llvm-build-insert-value builder agg-undef quot-val 0 "res_q")))
    (llvm-build-insert-value builder agg-0 rem-val 1 "res_r")))


(defun %handle-die-intrinsic (builder module)
  "Helper: Handles the compiler intrinsic DIE (llvm.trap)."
  (let ((trap-name "llvm.trap"))
    (let ((f (llvm-get-named-function module trap-name)))
      (when (cffi:null-pointer-p f)
            (let ((ft (llvm-function-type (llvm-void-type) (cffi:null-pointer) 0 nil)))
              (setf f (llvm-add-function module trap-name ft))))
      (llvm-build-call2 builder
                        (llvm-function-type (llvm-void-type) (cffi:null-pointer) 0 nil)
                        f
                        (cffi:null-pointer)
                        0
                        ""))
    (values nil nil)))

(defun %build-llvm-function-type (module return-type-names param-types)
  "Helper: Constructs an llvm-function-type and parameter count from a list of return types and parameter types."
  (let* ((llvm-return-type (get-llvm-return-type module return-type-names))
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types p module)) param-types))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))
    (values (llvm-function-type llvm-return-type param-types-array param-count nil)
            param-count)))



(defun %propagate-callee-cc-to-call (call-inst callee-fn-val)
  "If CALLEE-FN-VAL is a function value, copy its calling convention to
   CALL-INST.  Safe to call even when callee is an arbitrary SSA value
   (e.g. a function pointer through generate-node-ir) — we only set CC
   when we have a concrete LLVM value in hand."
  (when (and call-inst callee-fn-val
             (not (cffi:null-pointer-p call-inst))
             (not (cffi:null-pointer-p callee-fn-val)))
    (let ((cc (crisp.llvm-bindings::llvm-get-function-call-conv callee-fn-val)))
      (crisp.llvm-bindings::llvm-set-instruction-call-conv call-inst cc))))

(defun %build-function-call (builder module var-env di-builder di-scope location-map node sig callee-name llvm-fn-type param-nodes param-count return-type-names)
  "Helper: Builds the actual function call instruction.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Required on SPV builds — see overlay
   header for the InstCombine UB bug this fix addresses."
  (declare (ignore sig))
  (let* ((arg-nodes (semantic-call-args node))
         (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                             arg-nodes param-nodes param-count))
         (callee-fn (let ((f (llvm-get-named-function module callee-name)))
                      (if (cffi:null-pointer-p f)
                          (llvm-add-function module callee-name llvm-fn-type)
                          f)))
         (call-inst (llvm-build-call2 builder
                                      llvm-fn-type
                                      callee-fn
                                      args-array
                                      param-count
                                      (if (or (null return-type-names)
                                              (equal return-type-names '(nil))
                                              (and (consp return-type-names) (eq (first return-type-names) 'void)))
                                          ""
                                          "call_tmp")))
         (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
    (%propagate-callee-cc-to-call call-inst callee-fn)
    (values call-inst di-location)))



(defmethod generate-node-ir ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Generates IR for a function call.

   Endeavor 122 (FFI): a call to a function registered in *foreign-functions*
   uses its verbatim C name (no Crisp type-mangling), and its external
   declaration is given the target's device calling convention (SPIR_FUNC=75 on
   SPV; default on PTX) so the call instruction (which copies the callee's CC)
   matches the definition merged in from the linked .bc."
  ;; Special handling for compiler intrinsic DIE
  (when (eq (semantic-call-name node) 'die)
        (return-from generate-node-ir (%handle-die-intrinsic builder module)))

  (let* ((sig (semantic-call-signature node))
         (return-type-names (function-signature-return-types sig))
         (param-types (mapcar #'parameter-def-type (function-signature-parameters sig))))

    (multiple-value-bind (llvm-fn-type param-count)
        (%build-llvm-function-type module return-type-names param-types)

      (let* ((foreign-c-name (gethash (semantic-call-name node) *foreign-functions*))
             (callee-name
              (if foreign-c-name
                  foreign-c-name
                  (let ((mangled-name (format nil "~a~{_~a~}" (semantic-call-name node)
                                        (mapcar #'mangle-type-spec param-types))))
                    (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name)))))))

        ;; Foreign: pre-declare with the device calling convention so the call's
        ;; propagated CC matches the linked definition.
        (when foreign-c-name
          (let ((f (llvm-get-named-function module callee-name)))
            (when (cffi:null-pointer-p f)
              (setf f (llvm-add-function module callee-name llvm-fn-type)))
            (when (eq *target-backend* :spirv)
              (llvm-set-function-call-conv f 75))))

        (%build-function-call builder module var-env di-builder di-scope location-map node sig
                              callee-name llvm-fn-type param-types param-count return-type-names)))))



(defmethod generate-node-ir ((node semantic-progn) builder module var-env di-builder di-scope location-map)
  "Generates IR for a progn expression."
  (let ((last-val nil))
    (dolist (sub-node (semantic-progn-body node))
      (setf last-val (generate-node-ir sub-node builder module var-env di-builder di-scope location-map)))
    (values last-val nil)))

(defmethod generate-node-ir ((node semantic-with-precision) builder module var-env di-builder di-scope location-map)
  "Endeavor 126 (pass 5): per-region precision. Dynamically bind *math-precision* to
   the region's mode for the body's codegen — so the FMF stamped on the body's FP ops
   (via %apply-precision-fmf) reflects the region — UNLESS --force-math-precision is
   active (force locks precision; the region is ignored). Returns the last body
   form's value (like progn)."
  (let ((*math-precision* (if *force-math-precision*
                              *math-precision*
                              (semantic-with-precision-mode node))))
    (let ((last-val nil))
      (dolist (sub-node (semantic-with-precision-body node))
        (setf last-val (generate-node-ir sub-node builder module var-env di-builder di-scope location-map)))
      (values last-val nil))))


(defun %generate-let-binding (binding builder module let-env di-builder di-scope location-map memoized-aggregates)
  "Helper: Generates IR for a single let binding.
   Updates let-env with the new binding and returns the alloca.
   Extended to use llvm-build-extract-element for device-vector aggregates
   instead of llvm-build-extract-value (which is for struct aggregates only)."
  (let* ((var-name (car binding))
         (val-node (cdr binding))
         (llvm-type-name (get-single-value-type val-node)))

    (let ((val-ir
           (if (typep val-node 'semantic-extract-value)
               ;; If it's an extract, check if we've already generated the aggregate.
               (let* ((agg-node  (semantic-extract-value-aggregate-node val-node))
                      (agg-type  (semantic-node-type agg-node))
                      (ct        (%dvec-type-lookup agg-type))
                      (is-dvec   (and ct (eq (crisp-type-category ct) :device-vector)))
                      (agg-val   (or (gethash agg-node memoized-aggregates)
                                     ;; If not, generate and memoize it.
                                     (let ((new-agg-val (generate-expression-ir builder module let-env di-builder di-scope location-map agg-node)))
                                       (setf (gethash agg-node memoized-aggregates) new-agg-val)
                                       new-agg-val)))
                      (index     (semantic-extract-value-index val-node)))
                 (if is-dvec
                     ;; Device-vector: use extractelement (takes i32 index value)
                     (llvm-build-extract-element builder agg-val
                                                 (llvm-const-int (llvm-int32-type) index nil)
                                                 (format nil "comp_~d" index))
                     ;; Struct aggregate: use extractvalue (existing behaviour)
                     (llvm-build-extract-value builder agg-val index (format nil "extract_~a" index))))
               ;; Otherwise, it's a simple binding.
               ;; SENSITIVE CONTEXT UPDATE: We must set *compiler-context* binding name
               ;; so that make-scratch-cell can reconstruct the unique ID (sc_from_Fn_N).
               (let ((old-binding (compiler-context-current-binding-name *compiler-context*)))
                 (setf (compiler-context-current-binding-name *compiler-context*) var-name)
                 (unwind-protect
                     (generate-expression-ir builder module let-env di-builder di-scope location-map val-node)
                   (setf (compiler-context-current-binding-name *compiler-context*) old-binding))))))

      ;; Allocate and store
      (let ((alloca (llvm-build-alloca builder (crisp-type-to-llvm-type llvm-type-name module) (string-downcase var-name))))
        (llvm-build-store builder val-ir alloca)
        (setf (gethash var-name let-env) alloca)
        alloca))))

(defmethod generate-node-ir ((node semantic-let) builder module var-env di-builder di-scope location-map)
  "Generates IR for a let expression."
  ;; Create a new environment for the let block that inherits from the outer one.
  (let ((let-env (alexandria:copy-hash-table var-env))
        (memoized-aggregates (make-hash-table :test 'eq)))

    ;; Generate code for each binding
    (dolist (binding (semantic-let-bindings node))
      (%generate-let-binding binding builder module let-env di-builder di-scope location-map memoized-aggregates))

    ;; Generate code for the body, using the extended environment.
    ;; The result of the let is the result of the last expression in the body.
    (let ((last-val nil)
          (last-loc nil))
      (dolist (body-node (semantic-let-body node))
        (multiple-value-bind (val loc) (generate-expression-ir builder module let-env di-builder di-scope location-map body-node)
          (setf last-val val)
          (setf last-loc loc)))
      (values last-val last-loc))))




(defmethod generate-node-ir ((node semantic-funcall) builder module var-env di-builder di-scope location-map)
  "Generates IR for a funcall — function-pointer/function-literal style.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Same rationale as %build-function-call."
  (let* ((func-node (semantic-funcall-func-node node))
         (func-type-spec (semantic-node-type func-node))
         (return-type-names (semantic-funcall-type node))
         (has-return-value (not (null (remove 'nil return-type-names))))
         (param-types (cond
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-type))
                        (getf (cddr func-type-spec) :params))
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-literal))
                        (mapcar #'semantic-node-type (semantic-funcall-args node)))
                       (t (error "Codegen error: Invalid function type for funcall: ~a" func-type-spec)))))
    (multiple-value-bind (llvm-fn-type param-count)
        (%build-llvm-function-type module return-type-names param-types)
      (let* ((callee (generate-node-ir func-node builder module var-env di-builder di-scope location-map))
             (arg-nodes (semantic-funcall-args node))
             (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                                 arg-nodes param-types param-count)))
        (let* ((call-inst (llvm-build-call2 builder
                                            llvm-fn-type
                                            callee
                                            args-array
                                            param-count
                                            (if has-return-value "funcall_tmp" "")))
               (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
          (%propagate-callee-cc-to-call call-inst callee)
          (values call-inst di-location))))))


(defun terminator-p (block)
  "Checks if a basic block already has a terminator instruction."
  (not (cffi:null-pointer-p (llvm-get-basic-block-terminator block))))

(defmethod generate-node-ir ((node semantic-if) builder module var-env di-builder di-scope location-map)
  "Generates IR for an if expression."
  ;; 1. Evaluate the condition
  (multiple-value-bind (cond-val cond-loc)
      (generate-node-ir (semantic-if-condition-node node) builder module var-env di-builder di-scope location-map)
    (declare (ignore cond-loc))
    ;; Condition must be i1 (boolean) for cond_br.
    ;; Our language uses i32, so we truncate.
    ;; Note: In strict LLVM, 0 is false, non-zero is usually true. Truncating blindly might lose info
    ;; if the value is like 2 (binary 10), trunc to i1 is 0 (false)!
    ;; Correct logic: icmp ne %val, 0
    (let ((cond-bool (llvm-build-icmp builder +llvm-int-ne+ cond-val (llvm-const-int (llvm-int32-type) 0 nil) "ifcond")))

      (let ((then-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "then"))
            (else-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "else"))
            (merge-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "ifcont"))

            ;; Determine result type and allocate scratch space if needed (alloca trick)
            (result-type-spec (semantic-node-type node)))

        ;; Note: The result type might be 'void (nil).
        (let ((result-alloca
               (unless (or (null result-type-spec)
                           (eq result-type-spec :void)
                           (eq result-type-spec 'void)
                           (equal result-type-spec '(nil)))
                 (let ((type (crisp-type-to-llvm-type result-type-spec module)))
                   (llvm-build-alloca builder type "if_result")))))

          ;; --- Create Conditional Branch ---
          (llvm-build-cond-br builder cond-bool then-block else-block)

          ;; --- Then Block ---
          (llvm-position-builder-at-end builder then-block)
          (if (semantic-if-then-node node)
              (multiple-value-bind (then-val then-loc)
                  (generate-node-ir (semantic-if-then-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore then-loc))
                ;; A branch may legitimately produce no value (a `nil` literal, as in
                ;; the then-arm of (unless+ cond body) => (if+ cond nil body)). Then
                ;; then-val is NIL; skip the store so this path leaves the result
                ;; alloca undef (the branch is untaken under the uniform condition,
                ;; so the value is never observed) — same as a missing then-clause.
                (when (and result-alloca then-val)
                      (llvm-build-store builder then-val result-alloca)))
              ;; No then clause (e.g. unless). Treat as void/nil.
              nil)

          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Else Block ---
          (llvm-position-builder-at-end builder else-block)
          (if (semantic-if-else-node node)
              (multiple-value-bind (else-val else-loc)
                  (generate-node-ir (semantic-if-else-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore else-loc))
                ;; As with the then-arm: a `nil` else-value (e.g. (when+ cond body) or
                ;; a plain (if cond x nil)) yields NIL — skip the store, leaving undef
                ;; on the untaken path rather than crashing on a NIL store operand.
                (when (and result-alloca else-val)
                      (llvm-build-store builder else-val result-alloca)))
              ;; No else clause. If result expected, this is undefined behavior or nil.
              nil)
          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Merge Block ---
          (llvm-position-builder-at-end builder merge-block)
          (if result-alloca
              (let* ((type (crisp-type-to-llvm-type result-type-spec module))
                     (result-val (llvm-build-load2 builder type result-alloca "if_res")))
                (values result-val nil))
              (values nil nil)))))))

(defmethod generate-node-ir ((node semantic-struct-construction) builder module var-env di-builder di-scope location-map)
  (let* ((type-name (semantic-struct-construction-type node))
         (struct-def (lookup-struct-definition type-name))
         (llvm-type (ensure-struct-llvm-type type-name))
         (agg-val (llvm-get-undef llvm-type))
         (args (semantic-struct-construction-args node))
         (original-members (crisp-struct-definition-members struct-def))
         (field-indices (crisp-struct-definition-field-indices struct-def)))

    (log:info "Struct Construction: ~a" type-name)
    (log:info "  LLVM Type: ~a" (llvm-print-type-to-string llvm-type))
    (log:info "  Agg Val Type: ~a" (llvm-print-type-to-string (llvm-type-of agg-val)))

    (loop for arg in args
          for member in original-members
          for i from 0
          for field-name = (first member)
          for field-idx = (gethash field-name field-indices)
          do (let ((val (generate-node-ir arg builder module var-env di-builder di-scope location-map)))
               (setf agg-val (llvm-build-insert-value builder agg-val val field-idx (format nil "insert_~a" field-name)))))

    ;; Phase 5: If the logical type is a Handle (ptr) (e.g. Cell), but we constructed an Aggregate,
    ;; we must return the Handle (pointer to the aggregate).
    (let ((logical-type (resolve-type-to-llvm type-name)))
      (if (and (llvm-type-kind-is-pointer? logical-type)
               (not (llvm-type-kind-is-pointer? llvm-type)))
          (let ((handle (llvm-build-alloca builder llvm-type "cell_handle")))
            (llvm-build-store builder agg-val handle)
            (values handle nil))
          (values agg-val nil)))))

(defmethod generate-node-ir ((node semantic-ct-array) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for constructing a (array T N) value from N scalar T values.
   Emits a chain of insertvalue operations into an undef array of the appropriate LLVM type."
  (let* ((array-type (semantic-ct-array-type node))
         (val-nodes  (semantic-ct-array-val-nodes node))
         (llvm-type  (crisp-type-to-llvm-type array-type module))
         (result     (llvm-get-undef llvm-type)))
    (log:debug "CT-ARRAY codegen: type=~s, N=~a, llvm-type=~a" array-type (length val-nodes) (llvm-print-type-to-string llvm-type))
    (loop for vn in val-nodes
          for i from 0
          do (let ((val (generate-node-ir vn builder module var-env di-builder di-scope location-map)))
               (setf result (llvm-build-insert-value builder result val i
                                                     (format nil "arr_ins_~d" i)))))
    (values result nil)))



(defmethod generate-node-ir ((node semantic-extract-value) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for extracting a value from an aggregate.
   Device-vector aggregates use LLVMBuildExtractElement; struct aggregates
   use LLVMBuildExtractValue (existing behaviour)."
  (let* ((agg-node  (semantic-extract-value-aggregate-node node))
         (index     (semantic-extract-value-index node))
         (agg-type  (semantic-node-type agg-node))
         (ct        (%dvec-type-lookup agg-type))
         (is-dvec   (and ct (eq (crisp-type-category ct) :device-vector)))
         (agg-val   (generate-node-ir agg-node builder module var-env
                                      di-builder di-scope location-map)))

    (if is-dvec
        ;; Device-vector path: extractelement
        (let ((i32-idx (llvm-const-int (llvm-int32-type) index nil)))
          (log:debug "extract-element ~a[~a] (dvec ~a)" agg-type index agg-val)
          (values (llvm-build-extract-element
                   builder agg-val i32-idx (format nil "comp_~d" index))
                  nil))

        ;; Struct aggregate path (original logic)
        (let ((final-agg-val
               (if (llvm-type-kind-is-pointer? (llvm-type-of agg-val))
                   (let* ((crisp-type  agg-type)
                          (struct-type (if (and (listp crisp-type)
                                                (eq (first crisp-type) 'cell))
                                           (ensure-struct-llvm-type
                                            (mangle-template-struct-name
                                             'cell (rest crisp-type)))
                                           (if (symbolp crisp-type)
                                               (ensure-struct-llvm-type crisp-type)
                                               (error "Cannot extract from non-struct/handle type: ~a"
                                                      crisp-type)))))
                     (llvm-build-load2 builder struct-type agg-val "loaded_agg"))
                   agg-val)))
          (values (llvm-build-extract-value builder final-agg-val index
                                            (format nil "extract_~d" index))
                  nil)))))

(defmethod generate-node-ir ((node semantic-insert-value) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for inserting a value into an aggregate.
   Device-vector aggregates use LLVMBuildInsertElement; struct aggregates
   use LLVMBuildInsertValue (existing behaviour)."
  (let* ((agg-node   (semantic-insert-value-aggregate-node node))
         (index      (semantic-insert-value-index node))
         (value-node (semantic-insert-value-value-node node))
         (agg-type   (semantic-node-type agg-node))
         (ct         (%dvec-type-lookup agg-type))
         (is-dvec    (and ct (eq (crisp-type-category ct) :device-vector)))
         (agg-val    (generate-node-ir agg-node builder module var-env
                                       di-builder di-scope location-map))
         (value-val  (generate-node-ir value-node builder module var-env
                                       di-builder di-scope location-map)))

    (if is-dvec
        ;; Device-vector path: insertelement
        (let* ((final-val (extract-primary-value builder value-val
                                                 (semantic-node-type value-node)))
               (i32-idx  (llvm-const-int (llvm-int32-type) index nil)))
          (log:debug "insert-element ~a[~a] (dvec)" agg-type index)
          (values (llvm-build-insert-element builder agg-val final-val i32-idx
                                             (format nil "vec_ins_~d" index))
                  nil))

        ;; Struct aggregate path (original logic)
        (let ((final-agg-val
               (if (llvm-type-kind-is-pointer? (llvm-type-of agg-val))
                   (let* ((struct-type (if (symbolp agg-type)
                                          (ensure-struct-llvm-type agg-type)
                                          (error "Cannot insert into non-struct type: ~a"
                                                 agg-type))))
                     (llvm-build-load2 builder struct-type agg-val "loaded_agg"))
                   agg-val)))
          (let ((final-value-val (extract-primary-value builder value-val
                                                        (semantic-node-type value-node))))
            (values (llvm-build-insert-value builder final-agg-val final-value-val index
                                             (format nil "insert_~d" index))
                    nil))))))

(defmethod generate-node-ir ((node semantic-set!) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for (set! target value).
   Case 1: simple variable store.
   Case 2: cell/pointer store via aref.
   Case 3: device-vector component write via semantic-extract-value target.
     Sub-case A — aggregate is a local var: load-insertelement-store on the alloca.
     Sub-case B — aggregate is a cell deref: load-insertelement-store via the cell pointer."
  (let* ((target-node (semantic-set!-target-node node))
         (value-node  (semantic-set!-value-node node))
         (new-val     (generate-node-ir value-node builder module var-env
                                        di-builder di-scope location-map))
         (new-val     (extract-primary-value builder new-val
                                             (semantic-node-type value-node))))

    (cond
     ;; Case 1: Variable assignment.  We need the ALLOCA, not the loaded value.
     ((semantic-var-read-p target-node)
       (let* ((var-name (semantic-var-read-name target-node))
              (var-ptr  (gethash var-name var-env)))
         (unless var-ptr
           (error "Compiler error in set!: Variable ~a not found in environment."
                  var-name))
         (llvm-build-store builder new-val var-ptr)
         (values new-val nil)))

     ;; Case 2: Array/Pointer assignment  (set! (aref x i) v)  or  (set! (~ cell) v)
     ((semantic-aref-p target-node)
       (multiple-value-bind (val loc ptr)
           (generate-node-ir target-node builder module var-env
                              di-builder di-scope location-map)
         (declare (ignore val loc))
         (unless ptr
           (error "Compiler error in set!: Target ~a did not return an address."
                  target-node))
         (llvm-build-store builder new-val ptr)
         (values new-val nil)))

     ;; Case 3: Device-vector component write
     ;;   (set! (x~ local-var)   val)  — sub-case A: load-insert-store on alloca
     ;;   (set! (x~ (~ cell))    val)  — sub-case B: load-insert-store via cell ptr
     ((semantic-extract-value-p target-node)
       (let* ((agg-node (semantic-extract-value-aggregate-node target-node))
              (index    (semantic-extract-value-index target-node))
              (i32-idx  (llvm-const-int (llvm-int32-type) index nil)))
         (cond
          ;; Sub-case A: aggregate is a local variable (alloca in var-env)
          ((semantic-var-read-p agg-node)
            (let* ((var-name   (semantic-var-read-name agg-node))
                   (alloca     (gethash var-name var-env))
                   (vec-type   (crisp-type-to-llvm-type
                                (semantic-node-type agg-node) module))
                   (loaded-vec (llvm-build-load2 builder vec-type alloca
                                                 (format nil "~a_load" var-name)))
                   (new-vec    (llvm-build-insert-element builder loaded-vec
                                                          new-val i32-idx "vec_ins")))
              (log:debug "set! (x~~ local) sub-case A: var=~a index=~a" var-name index)
              (llvm-build-store builder new-vec alloca)
              (values new-vec nil)))

          ;; Sub-case B: aggregate is a cell dereference — load-modify-store
          ((semantic-aref-p agg-node)
            (multiple-value-bind (loaded-vec _loc cell-ptr)
                (generate-node-ir agg-node builder module var-env
                                  di-builder di-scope location-map)
              (declare (ignore _loc))
              (unless cell-ptr
                (error "Compiler error: (set! (x~ (~ cell)) val) — aref gave no pointer."))
              (log:debug "set! (x~~ (~~ cell)) sub-case B: index=~a" index)
              (let ((new-vec (llvm-build-insert-element builder loaded-vec
                                                        new-val i32-idx "vec_ins")))
                (llvm-build-store builder new-vec cell-ptr)
                (values new-vec nil))))

          (t (error "Unsupported aggregate kind in (set! (x~ ...) val): ~a" agg-node)))))

     (t (error "Unsupported target for set! codegen: ~a" target-node)))))




(defmethod generate-node-ir ((node semantic-struct-member-update) builder module var-env di-builder di-scope location-map)
  "Generates IR for updating a struct member: inserts value into struct and returns new struct.
   Casts the new value to match the field's LLVM type if they differ (e.g. i32 -> i64)."
  (let* ((struct-node  (semantic-struct-member-update-struct-node node))
         (member-index (semantic-struct-member-update-member-index node))
         (value-node   (semantic-struct-member-update-value-node node))
         ;; Generate the ORIGINAL struct value (load it)
         (struct-val (generate-node-ir struct-node builder module var-env di-builder di-scope location-map))
         ;; Generate the NEW member value
         (new-member-val-raw (generate-node-ir value-node builder module var-env di-builder di-scope location-map))
         (new-member-val (extract-primary-value builder new-member-val-raw (semantic-node-type value-node)))
         ;; Determine expected field LLVM type by extracting the existing member
         (existing-member (crisp.llvm-bindings:llvm-build-extract-value builder struct-val member-index "existing_field"))
         (expected-type   (crisp.llvm-bindings:llvm-type-of existing-member))
         (actual-type     (crisp.llvm-bindings:llvm-type-of new-member-val))
         ;; Cast if both are integers of different widths
         (cast-val
          (let ((expected-kind (crisp.llvm-bindings:llvm-get-type-kind expected-type))
                (actual-kind   (crisp.llvm-bindings:llvm-get-type-kind actual-type)))
            ;; Integer type kind = 8 in LLVM
            (if (and (= expected-kind 8) (= actual-kind 8))
                (let ((expected-width (crisp.llvm-bindings::llvm-get-int-type-width expected-type))
                      (actual-width   (crisp.llvm-bindings::llvm-get-int-type-width actual-type)))
                  (cond
                   ((= expected-width actual-width) new-member-val)
                   ((> expected-width actual-width)
                    (log:debug "struct-member-update: zext from ~a to ~a bits at index ~a" actual-width expected-width member-index)
                    (crisp.llvm-bindings:llvm-build-zext builder new-member-val expected-type "field_cast"))
                   (t
                    (log:debug "struct-member-update: trunc from ~a to ~a bits at index ~a" actual-width expected-width member-index)
                    (crisp.llvm-bindings:llvm-build-trunc builder new-member-val expected-type "field_cast"))))
                ;; Non-integer types: use as-is (pointer/float fields shouldn't need casting here)
                new-member-val)))
         ;; Insert the (possibly cast) value
         (new-struct-val (crisp.llvm-bindings:llvm-build-insert-value builder struct-val cast-val member-index "struct_update")))

    ;; Runtime bounds check: when *runtime-checks-enabled*, verify the new value doesn't
    ;; exceed the storage capacity.
    ;;   CELL,   member-index=1 (offset, bytes): cast-val < extractvalue(parent, 1)
    ;;   TENSOR, member-index=4 (length, elems): cast-val * sizeof(elem) <= extractvalue(parent, 1)
    (when *runtime-checks-enabled*
      (let* ((struct-type (semantic-struct-member-update-type node))
             (resolved-type (if (symbolp struct-type)
                                (unmangle-template-struct-name struct-type)
                                struct-type))
             (sh-head (when (and (consp resolved-type) (symbolp (first resolved-type)))
                        (first resolved-type)))
             (is-cell   (and sh-head (string-equal (symbol-name sh-head) "CELL")))
             (is-tensor (and sh-head (not is-cell)
                             (member (symbol-name sh-head) '("TENSOR" "VECTOR" "MATRIX")
                                     :test #'string-equal)))
             ;; Only check cell-offset (index 1) and tensor-length (index 4)
             (should-check (or (and is-cell   (= member-index 1))
                               (and is-tensor (= member-index 4)))))
        (when should-check
          (let* (;; Extract parent storage byte-capacity: extractvalue(extractvalue(struct_val,0),1)
                 (parent-val    (llvm-build-extract-value builder struct-val 0 "rt_parent"))
                 (storage-bytes (llvm-build-extract-value builder parent-val 1 "rt_capacity"))
                 ;; For cell offset (bytes): compare cast-val < storage-bytes  [strict less-than]
                 ;; For tensor length (elems): compare cast-val*sizeof(elem) <= storage-bytes
                 (check-lhs
                  (if is-cell
                      cast-val
                      (let* ((elem-type-sym (second resolved-type))
                             (elem-llvm-t   (crisp-type-to-llvm-type elem-type-sym module))
                             (elem-size     (llvm-size-of elem-llvm-t)))
                        (llvm-build-mul builder cast-val elem-size "rt_total_bytes"))))
                 (pred  (if is-cell +llvm-int-ult+ +llvm-int-ule+))
                 (cmp   (llvm-build-icmp builder pred check-lhs storage-bytes "rt_bounds_ok"))
                 (curr-fn    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                 (trap-block (llvm-append-basic-block curr-fn "rt_trap"))
                 (ok-block   (llvm-append-basic-block curr-fn "rt_ok")))
            ;; cmp=true means in-bounds → go to ok; false means OOB → go to trap
            (llvm-build-cond-br builder cmp ok-block trap-block)
            ;; Trap block: call llvm.trap then fall through (unreachable in practice)
            (llvm-position-builder-at-end builder trap-block)
            (%handle-die-intrinsic builder module)
            (llvm-build-br builder ok-block)
            ;; Resume in ok block
            (llvm-position-builder-at-end builder ok-block)
            (log:debug "rt-bounds-check emitted: ~a member-index=~a" sh-head member-index)))))

    (values new-struct-val nil)))





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


(defmethod generate-node-ir ((node semantic-aref) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for array/cell/tensor element access (aref / ~ / ~ref~).
   Case 2: (array T N) fixed-size array — GEP into alloca (unchanged).
   Case 3: TENSOR — parent.address from SROA field 0; byte-off = flat_idx * sizeof(elem);
     GEP i8* + byte-off, bitcast, load.  Load gets !invariant.load when
     ARRAY-NODE is a direct ref to a read-only kernel-param tensor.
   Case 1: CELL — original behaviour unchanged.
   Returns (values loaded-val nil elem-ptr) so set! can store through the pointer."
  (let* ((array-node   (semantic-aref-array-node node))
         (index-node   (semantic-aref-index-node node))
         (array-type   (let ((raw (semantic-node-type array-node)))
                         (if (and (listp raw) (= (length raw) 1) (listp (first raw)))
                             (first raw)
                             raw)))
         (element-type (semantic-aref-type node))
         (index-val    (generate-node-ir index-node builder module var-env
                                         di-builder di-scope location-map)))

    (let ((cell-spec (let* ((resolved (resolve-type-alias array-type))
                            (canon    (canonicalize-type-specifier resolved)))
                       (cond
                        ((and (listp canon) (symbolp (first canon))
                              (string-equal (symbol-name (first canon)) "CELL")) canon)
                        ((and (listp canon) (= (length canon) 1) (symbolp (first canon)))
                         (unmangle-template-struct-name (first canon)))
                        ((symbolp canon)
                         (unmangle-template-struct-name canon))
                        (t canon)))))

      (multiple-value-bind (loaded-val _loc target-ptr)
          (cond
       ;; Case 2: (array T N) fixed-size array — GEP into alloca (unchanged)
       ((%array-type-p (resolve-type-alias array-type))
        (let* ((resolved-arr-type (resolve-type-alias array-type))
               (elem-type-spec    (second resolved-arr-type))
               (count-raw         (third  resolved-arr-type))
               (count             (etypecase count-raw
                                    (integer count-raw)
                                    (symbol  (parse-integer (symbol-name count-raw)))))
               (elem-llvm-type    (crisp-type-to-llvm-type elem-type-spec module))
               (arr-llvm-type     (crisp.llvm-bindings::llvm-array-type elem-llvm-type count))
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
                             (sub-ptr
                              (log:info "array-aref: using sub-ptr from inner aref (bug 029 path)")
                              sub-ptr)
                             ((llvm-type-kind-is-pointer? (llvm-type-of sub-val))
                              sub-val)
                             (t
                              (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                                (llvm-build-store builder sub-val slot)
                                slot))))))))
               (idx-i64 (llvm-build-sext builder index-val (llvm-int64-type) "arr_idx")))

          (log:info "array-aref: type=(array ~a ~a) ptr=~a idx=~a"
                    elem-type-spec count arr-ptr idx-i64)

          (cffi:with-foreign-object (indices :pointer 2)
            (setf (cffi:mem-aref indices :pointer 0)
                  (llvm-const-int (llvm-int32-type) 0 nil))
            (setf (cffi:mem-aref indices :pointer 1) idx-i64)
            (let* ((elem-ptr (llvm-build-in-bounds-gep2
                              builder arr-llvm-type arr-ptr indices 2 "arr_elem_ptr"))
                   (loaded   (llvm-build-load2 builder elem-llvm-type elem-ptr "arr_elem")))
              (values loaded nil elem-ptr)))))

       ;; Case 3: TENSOR — flat index pre-computed; GEP via parent storage pointer.
       ;; SROA field 0 of tensor is (storage Addr) → {address ptr, byte-size}.
       ;; Field 0 of storage is the raw pointer.
       ;; NEW: read-only kernel-param tensor reads get !invariant.load.
       ((and (listp cell-spec) (symbolp (first cell-spec))
             (string-equal (symbol-name (first cell-spec)) "TENSOR"))
        (let* ((tensor-val     (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-name   (mangle-template-struct-name (first cell-spec)
                                                            (rest cell-spec)))
               (mark-invariant-p (%array-node-readonly-tensor-param-p array-node)))
          (log:info "semantic-aref tensor: struct=~a elem=~a invariant=~a"
                    mangled-name elem-type-spec mark-invariant-p)
          (ensure-struct-llvm-type mangled-name)
          (let* ((parent-val  (llvm-build-extract-value builder tensor-val 0 "t_parent_val"))
                 (base-ptr    (llvm-build-extract-value builder parent-val 0 "t_base_ptr"))
                 ;; flat element index already incorporates offsets and strides
                 (flat-i64    (llvm-build-sext builder index-val (llvm-int64-type) "t_flat_i64"))
                 (elem-size   (llvm-size-of elem-llvm-type))
                 (byte-off    (llvm-build-mul builder flat-i64 elem-size "t_byte_off")))
            (cffi:with-foreign-object (indices :pointer 1)
              (setf (cffi:mem-aref indices :pointer 0) byte-off)
              (let* ((ptr-i8   (llvm-build-in-bounds-gep2
                                builder (llvm-int8-type) base-ptr indices 1 "t_ptr_i8"))
                     (ptr-as   (llvm-get-pointer-address-space (llvm-type-of ptr-i8)))
                     (t-ptr    (llvm-build-bit-cast
                                builder ptr-i8
                                (llvm-pointer-type elem-llvm-type ptr-as) "t_ptr"))
                     (loaded   (llvm-build-load2 builder elem-llvm-type t-ptr "t_elem")))
                (when mark-invariant-p
                  (%attach-invariant-load loaded module))
                (values loaded nil t-ptr))))))

       ;; Case 1: CELL parameterized type (unchanged)
       ((and (listp cell-spec) (symbolp (first cell-spec))
             (string-equal (symbol-name (first cell-spec)) "CELL"))
        (let* ((cell-val       (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-struct-name (mangle-template-struct-name (first cell-spec)
                                                                  (rest cell-spec))))
          (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
          (ensure-struct-llvm-type mangled-struct-name)
          (let ()
            (log:info "semantic-aref: Using ExtractValue to access Cell Record members.")
            (let* ((parent-val   (llvm-build-extract-value builder cell-val 0 "parent_val"))
                   (base-ptr     (llvm-build-extract-value builder parent-val 0 "base_ptr"))
                   (cell-offset  (llvm-build-extract-value builder cell-val 1 "cell_offset"))
                   (elem-size    (llvm-size-of elem-llvm-type))
                   (index-i64    (llvm-build-sext builder index-val (llvm-int64-type) "index_i64"))
                   (index-bytes  (llvm-build-mul builder index-i64 elem-size "index_bytes"))
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
                 array-type cell-spec)))
        (declare (ignore _loc))
        (when (gethash node *volatile-var-reads*)
          (log:debug "aref marked volatile (IGC workaround)")
          (crisp.llvm-bindings::llvm-set-volatile loaded-val 1))
        (values loaded-val nil target-ptr)))))
(defmethod generate-node-ir ((node semantic-sizeof) builder module var-env di-builder di-scope location-map)
  "Generates IR for a sizeof(T) expression. Returns an i64 constant."
  (declare (ignore builder var-env di-builder di-scope location-map))
  (log:info "Generating SIZEOF IR for type node: ~s" node)
  (let* ((target-type-spec (semantic-sizeof-target-type node))
         (llvm-type (crisp-type-to-llvm-type target-type-spec module))
         (size-val (llvm-size-of llvm-type)))
    ;; size-val is an LLVM Value (ConstantInt), so it's ready to use.
    (values size-val nil)))

(defmethod generate-node-ir ((node null) builder module var-env di-builder di-scope location-map)
  "Explict handler for NIL nodes (e.g. empty body return values or missing value nodes)."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (values nil))


(defun %dvec-coerce-element-ir (elem-node comp-type comp-llvm-type builder module var-env di-builder di-scope location-map)
  "Generates the LLVM value for one element of a ##(...) literal.
   If the element type already matches COMP-TYPE, generates normally.
   If the element is a plain-int or plain-float constant being coerced to
   a different integral/float type, produces the correctly-typed constant
   directly without emitting a conversion instruction."
  (let ((elem-type (semantic-node-type elem-node)))
    (if (eq elem-type comp-type)
        ;; Exact match — generate normally
        (nth-value 0 (generate-node-ir elem-node builder module var-env
                                       di-builder di-scope location-map))
        ;; Coercion needed — only constant literals are supported here
        (if (typep elem-node 'semantic-literal)
            (let* ((val (semantic-literal-value elem-node))
                   (ct  (gethash comp-type *crisp-types*)))
              (cond
                ((member (crisp-type-category ct) '(:signed-int :unsigned-int))
                 (llvm-const-int comp-llvm-type val nil))
                ((eq (crisp-type-category ct) :float)
                 (llvm-const-real comp-llvm-type (coerce val 'double-float)))
                (t
                 (error "##(...): cannot coerce element of type ~a to ~a" elem-type comp-type))))
            (error "##(...): non-literal element of type ~a cannot be coerced to ~a"
                   elem-type comp-type)))))

(defmethod generate-node-ir ((node semantic-device-vec-literal) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a ##(...) device vector literal via insertelement chain."
  (let* ((vec-type-sym  (semantic-device-vec-literal-vec-type node))
         (elem-type-sym (semantic-device-vec-literal-element-type node))
         (elements      (semantic-device-vec-literal-elements node))
         (llvm-vec-type (crisp-type-to-llvm-type vec-type-sym module))
         (llvm-elem-type (crisp-type-to-llvm-type elem-type-sym module))
         ;; Start from an undef vector and fold insertions left-to-right
         (result (llvm-get-undef llvm-vec-type)))
    (log:debug "generate-node-ir dvec: ~a" vec-type-sym)
    (loop for elem-node in elements
          for i from 0
          do (let* ((elem-ir (%dvec-coerce-element-ir elem-node elem-type-sym llvm-elem-type
                                                      builder module var-env
                                                      di-builder di-scope location-map))
                    (idx-ir  (llvm-const-int (llvm-int32-type) i nil))
                    (name    (format nil "dvec_~a" i)))
               (setf result
                     (llvm-build-insert-element builder result elem-ir idx-ir name))))
    (values result nil)))



(defun %mv-build-const-i64-array (builder rank values)
  "Build an LLVM [rank x i64] constant array from a list of integers.
   If VALUES is shorter than rank, remaining slots are filled with 0."
  (let* ((i64      (llvm-int64-type))
             (arr-type (llvm-array-type i64 rank))
             (undef    (llvm-get-undef arr-type)))
    (loop for k from 0 below rank
             with result = undef
             for v = (or (nth k values) 0)
             do (setf result
                      (llvm-build-insert-value builder result
                                               (llvm-const-int i64 v nil)
                                               k (format nil "arr_~d" k)))
             finally (cl:return result))))

(defun %mv-build-zero-i64-array (rank)
  "Build a constant all-zero [rank x i64] array."
  (llvm-const-null (llvm-array-type (llvm-int64-type) rank)))

(defun %mv-bump-ptr (builder base-ptr offset-bytes addr-space)
  "GEP base-ptr by offset-bytes (an i64 LLVM value).
   Returns the new ptr in the same address space."
  (declare (ignore addr-space))
  (cffi:with-foreign-object (indices :pointer 1)
    (setf (cffi:mem-aref indices :pointer 0) offset-bytes)
    (let* ((ptr-i8 (llvm-build-in-bounds-gep2
                       builder (llvm-int8-type) base-ptr indices 1 "mv_bumped_i8"))
               (ptr-as (llvm-get-pointer-address-space (llvm-type-of ptr-i8))))
      (declare (ignore ptr-as))
      ptr-i8)))

(defun %mv-build-storage (builder module addr-space src-parent new-ptr new-bytesize)
  "Build a new STORAGE_{addr} struct value from ptr and bytesize."
  (declare (ignore src-parent))
  (let* ((storage-type (crisp-type-to-llvm-type `(storage ,addr-space) module))
             (s0 (llvm-build-insert-value builder (llvm-get-undef storage-type)
                                          new-ptr 0 "mv_storage_ptr"))
             (s1 (llvm-build-insert-value builder s0 new-bytesize 1 "mv_storage_bs")))
    s1))




(defmethod generate-node-ir ((node semantic-make-view)
                               builder module var-env
                               di-builder di-scope location-map)
  "Generates IR for make-cell / make-vector / make-matrix / make-tensor.
   Extended: emits a bounds-check (llvm.trap) when *runtime-checks-enabled* is T."
  (let* ((result-type   (semantic-make-view-type node))
             (src-node      (semantic-make-view-source-node node))
             (elem-type-sym (semantic-make-view-element-type node))
             (rank          (semantic-make-view-rank node))
             (offset-elems  (or (semantic-make-view-offset node) 0))
             (explicit-len  (semantic-make-view-length node))
             (extents       (semantic-make-view-extents node))
             (strides       (semantic-make-view-strides node))

             (src-val (generate-node-ir src-node builder module var-env
                                        di-builder di-scope location-map))

             (src-parent   (llvm-build-extract-value builder src-val 0 "mv_src_parent"))
             (src-ptr      (llvm-build-extract-value builder src-parent 0 "mv_src_ptr"))
             (src-bytesize (llvm-build-extract-value builder src-parent 1 "mv_src_bs"))

             (elem-llvm-type (crisp-type-to-llvm-type elem-type-sym module))
             (elem-size      (llvm-size-of elem-llvm-type))

             (offset-bytes
              (if (zerop offset-elems)
                  (llvm-const-int (llvm-int64-type) 0 nil)
                  (llvm-build-mul builder
                                  (llvm-const-int (llvm-int64-type) offset-elems nil)
                                  elem-size "mv_off_bytes")))
             (new-ptr
              (if (zerop offset-elems)
                  src-ptr
                  (%mv-bump-ptr builder src-ptr offset-bytes
                                (%mv-source-addr (list (first result-type) nil
                                                       (third result-type))))))
             (new-bytesize
              (if (zerop offset-elems)
                  src-bytesize
                  (llvm-build-sub builder src-bytesize offset-bytes "mv_new_bs")))

             (addr-space (cond ((string-equal (symbol-name (first result-type)) "CELL")
                                (third result-type))
                               (t (fourth result-type))))

             (new-storage (%mv-build-storage builder module addr-space
                                             src-parent new-ptr new-bytesize))

             (mangled-name (mangle-template-struct-name (first result-type)
                                                        (rest result-type)))
             (result-struct-type (ensure-struct-llvm-type mangled-name))
             (result-undef (llvm-get-undef result-struct-type)))

    (log:info "make-view: op=~a rank=~d elem=~a mangled=~a offset=~d"
              (first result-type) rank elem-type-sym mangled-name offset-elems)

    ;; Runtime bounds check: verify (offset_bytes + view_bytes) <= src_bytesize.
    ;; view_bytes = len_elems * sizeof(elem):
    ;;   make-cell: 1 element
    ;;   make-vector/matrix/tensor with explicit-len: that count
    ;;   auto-length: 1 element (just verify offset fits)
    (when *runtime-checks-enabled*
      (let* ((len-elems (cond ((= rank 0) 1)
                              (explicit-len explicit-len)
                              (t 1)))
             (len-bytes    (llvm-build-mul builder
                                           (llvm-const-int (llvm-int64-type) len-elems nil)
                                           elem-size "mv_len_bytes"))
             (required     (llvm-build-add builder offset-bytes len-bytes "mv_required"))
             (cmp          (llvm-build-icmp builder +llvm-int-ule+
                                            required src-bytesize "mv_bounds_ok"))
             (curr-fn      (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
             (trap-block   (llvm-append-basic-block curr-fn "mv_trap"))
             (ok-block     (llvm-append-basic-block curr-fn "mv_ok")))
        (llvm-build-cond-br builder cmp ok-block trap-block)
        (llvm-position-builder-at-end builder trap-block)
        (%handle-die-intrinsic builder module)
        (llvm-build-br builder ok-block)
        (llvm-position-builder-at-end builder ok-block)
        (log:debug "make-view rt-bounds-check emitted: rank=~a offset=~a len=~a"
                   rank offset-elems len-elems)))

    (cond

     ;; ── cell (rank=0): { STORAGE, byte-offset-i64 } ──────────────────
     ((= rank 0)
      (let* ((orig-storage (%mv-build-storage builder module addr-space
                                                 src-parent src-ptr src-bytesize))
                (byte-offset-val
                 (if (zerop offset-elems)
                     (llvm-const-int (llvm-int64-type) 0 nil)
                     (llvm-build-mul builder
                                     (llvm-const-int (llvm-int64-type) offset-elems nil)
                                     elem-size "mv_cell_off_bytes")))
                (c0 (llvm-build-insert-value builder result-undef orig-storage 0 "mv_cell_parent"))
                (c1 (llvm-build-insert-value builder c0 byte-offset-val 1 "mv_cell_offset")))
        c1))

     ;; ── tensor/vector/matrix (rank>=1) ────────────────────────────────
     (t
      (let* ((zero-offsets (%mv-build-zero-i64-array rank))
                (stride-vals (or strides (%mv-row-major-strides (or extents (make-list rank :initial-element 1)))))
                (stride-arr  (%mv-build-const-i64-array builder rank stride-vals))
                (extent-vals (or extents (make-list rank :initial-element 0)))
                (extent-arr  (%mv-build-const-i64-array builder rank extent-vals))
                (length-val
                 (if explicit-len
                     (llvm-const-int (llvm-int64-type) explicit-len nil)
                     (llvm-build-udiv builder new-bytesize elem-size "mv_auto_len")))
                (t0 (llvm-build-insert-value builder result-undef new-storage  0 "mv_t_parent"))
                (t1 (llvm-build-insert-value builder t0 zero-offsets  1 "mv_t_offsets"))
                (t2 (llvm-build-insert-value builder t1 stride-arr    2 "mv_t_strides"))
                (t3 (llvm-build-insert-value builder t2 extent-arr    3 "mv_t_extents"))
                (t4 (llvm-build-insert-value builder t3 length-val    4 "mv_t_length")))
        t4)))))



(defmethod generate-node-ir ((node semantic-atomic-rmw) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for atomic RMW operations (atomic-add!, atomic-sub!, etc.).
Returns the old value at the target location (fetch-and-op semantics).
LLVM AtomicRMWBinOp enum: xchg=0 add=1 sub=2 max=7 min=8 umax=9 umin=10
                           fadd=11 fsub=12 fmax=13 fmin=14
LLVMAtomicOrdering SequentiallyConsistent = 7"
  (let* ((target-aref     (semantic-atomic-rmw-target-node node))
         (delta-node      (semantic-atomic-rmw-delta-node node))
         (op              (semantic-atomic-rmw-op node))
         (elem-type       (semantic-atomic-rmw-type node))
         (elem-crisp-type (gethash elem-type *crisp-types*))
         (is-float        (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :float)))
         (is-unsigned     (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :unsigned-int))))

    ;; Get the GEP pointer from the target aref (3rd return value)
    (multiple-value-bind (aref-val aref-loc ptr)
        (generate-node-ir target-aref builder module var-env di-builder di-scope location-map)
      (declare (ignore aref-val aref-loc))
      (unless ptr
        (error "Compiler error in atomic RMW: target ~a did not produce an address pointer"
               target-aref))

      ;; Compute the delta value
      (let* ((delta-raw (generate-node-ir delta-node builder module var-env
                                          di-builder di-scope location-map))
             (delta-val (extract-primary-value builder delta-raw elem-type))
             ;; Select the LLVM RMW opcode
             ;; Inline integer literals avoid defconstant redefinition issues in overlays.
             (rmw-op (ecase op
                       (:add  (if is-float 11 1))   ;; fadd=11, add=1
                       (:sub  (if is-float 12 2))   ;; fsub=12, sub=2
                       (:min  (cond (is-float 14)   ;; fmin=14
                                    (is-unsigned 10) ;; umin=10
                                    (t 8)))          ;; min=8 (signed)
                       (:max  (cond (is-float 13)   ;; fmax=13
                                    (is-unsigned 9)  ;; umax=9
                                    (t 7)))          ;; max=7 (signed)
                       (:xchg 0))))                 ;; xchg=0

        (log:info "atomic-rmw: op=~a elem-type=~a is-float=~a is-unsigned=~a rmw-op=~a"
                  op elem-type is-float is-unsigned rmw-op)

        (let ((result (crisp.llvm-bindings::llvm-build-atomic-rmw
                       builder rmw-op ptr delta-val
                       7  ;; LLVMAtomicOrderingSequentiallyConsistent
                       0))) ;; single-thread=0 (multi-threaded GPU)
          (values result nil))))))


(defun %sv-to-i64 (builder val)
  "Sign-extends VAL to i64 if smaller than 64 bits; returns as-is if already i64.
   Avoids the invalid sext-to-same-width LLVM instruction."
  (let* ((tp   (llvm-type-of val))
         (kind (llvm-get-type-kind tp)))
    (if (= kind 8)  ; integer kind
        (let ((w (crisp.llvm-bindings::llvm-get-int-type-width tp)))
          (cond ((= w 64) val)
                ((< w 64) (llvm-build-sext builder val (llvm-int64-type) "sv_idx64"))
                (t        (llvm-build-trunc builder val (llvm-int64-type) "sv_trunc"))))
        val)))

        
(defmethod generate-node-ir ((node semantic-stride-view)
                              builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for transpose, col, and row stride-view operations on 2D tensors.
   Produces a new tensor struct value with recomputed offsets, strides, extents, and length.
   :transpose — swaps dim0/dim1 in offsets, strides, and extents; length unchanged.
   :col c     — extracts column c as 1D vector (stride=row-stride, len=height).
   :row r     — extracts row r as 1D vector (stride=col-stride, len=width)."
  (let* ((op          (semantic-stride-view-op node))
         (src-node    (semantic-stride-view-source-node node))
         (idx-node    (semantic-stride-view-index-node node))
         (result-type (semantic-stride-view-type node))

         ;; Generate source tensor value (a fully-loaded struct)
         (src-val  (generate-node-ir src-node builder module var-env
                                     di-builder di-scope location-map))

         ;; Extract source tensor struct fields (physical indices 0–4)
         (src-parent  (llvm-build-extract-value builder src-val 0 "sv_parent"))
         (src-offsets (llvm-build-extract-value builder src-val 1 "sv_offsets"))
         (src-strides (llvm-build-extract-value builder src-val 2 "sv_strides"))
         (src-extents (llvm-build-extract-value builder src-val 3 "sv_extents"))

         ;; Extract individual i64 elements from the 2D [2 x i64] arrays
         (src-off0 (llvm-build-extract-value builder src-offsets 0 "sv_off0"))
         (src-off1 (llvm-build-extract-value builder src-offsets 1 "sv_off1"))
         (src-str0 (llvm-build-extract-value builder src-strides  0 "sv_str0"))
         (src-str1 (llvm-build-extract-value builder src-strides  1 "sv_str1"))
         (src-ext0 (llvm-build-extract-value builder src-extents  0 "sv_ext0"))
         (src-ext1 (llvm-build-extract-value builder src-extents  1 "sv_ext1"))

         ;; Resolve and instantiate the result tensor struct type (on-demand if needed)
         (mangled       (mangle-template-struct-name (first result-type) (rest result-type)))
         (result-llvm-t (crisp-type-to-llvm-type result-type module))
         (result-undef  (llvm-get-undef result-llvm-t))
         (i64           (llvm-int64-type)))

    (log:info "stride-view: op=~a result-type=~a mangled=~a" op result-type mangled)

    (ecase op

      (:transpose
       ;; Transpose swaps dim0↔dim1 in offsets, strides, and extents.
       ;; Length (total elements) is unchanged.
       (let* ((arr2-undef (llvm-get-undef (llvm-array-type i64 2)))
              (src-len    (llvm-build-extract-value builder src-val 4 "sv_t_len"))
              ;; new offsets = [off1, off0]
              (new-off (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-off1 0 "sv_t_no0")
                         src-off0 1 "sv_t_no1"))
              ;; new strides = [str1, str0]
              (new-str (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-str1 0 "sv_t_ns0")
                         src-str0 1 "sv_t_ns1"))
              ;; new extents = [ext1, ext0]
              (new-ext (llvm-build-insert-value builder
                         (llvm-build-insert-value builder arr2-undef src-ext1 0 "sv_t_ne0")
                         src-ext0 1 "sv_t_ne1")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent 0 "sv_t_r0"))
                (r1 (llvm-build-insert-value builder r0 new-off  1 "sv_t_r1"))
                (r2 (llvm-build-insert-value builder r1 new-str  2 "sv_t_r2"))
                (r3 (llvm-build-insert-value builder r2 new-ext  3 "sv_t_r3"))
                (r4 (llvm-build-insert-value builder r3 src-len  4 "sv_t_r4")))
           r4)))

      (:col
       ;; Column c slice from 2D matrix M.
       ;; result.offset[0] = M.off0 + M.off1 + c * M.str1  (start of column c)
       ;; result.strides[0] = M.str0  (step between rows in the column)
       ;; result.extents[0] = M.ext0  (height = number of rows)
       ;; result.length     = M.ext0
       (let* ((idx-raw      (generate-node-ir idx-node builder module var-env
                                              di-builder di-scope location-map))
              (idx-i64      (%sv-to-i64 builder idx-raw))
              ;; new offset[0] = off0 + off1 + c * str1
              (c-x-str1  (llvm-build-mul builder idx-i64 src-str1 "sv_c_cxs1"))
              (off1-plus (llvm-build-add builder src-off1 c-x-str1 "sv_c_o1p"))
              (new-off0  (llvm-build-add builder src-off0 off1-plus "sv_c_off0"))
              ;; Build [1 x i64] arrays
              (arr1-undef  (llvm-get-undef (llvm-array-type i64 1)))
              (res-offsets (llvm-build-insert-value builder arr1-undef new-off0  0 "sv_c_roff"))
              (res-strides (llvm-build-insert-value builder arr1-undef src-str0  0 "sv_c_rstr"))
              (res-extents (llvm-build-insert-value builder arr1-undef src-ext0  0 "sv_c_rext")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent   0 "sv_c_r0"))
                (r1 (llvm-build-insert-value builder r0 res-offsets 1 "sv_c_r1"))
                (r2 (llvm-build-insert-value builder r1 res-strides 2 "sv_c_r2"))
                (r3 (llvm-build-insert-value builder r2 res-extents 3 "sv_c_r3"))
                (r4 (llvm-build-insert-value builder r3 src-ext0    4 "sv_c_r4")))
           r4)))

      (:row
       ;; Row r slice from 2D matrix M.
       ;; result.offset[0] = M.off0 + M.off1 + r * M.str0  (start of row r)
       ;; result.strides[0] = M.str1  (step between columns in the row)
       ;; result.extents[0] = M.ext1  (width = number of columns)
       ;; result.length     = M.ext1
       (let* ((idx-raw      (generate-node-ir idx-node builder module var-env
                                              di-builder di-scope location-map))
              (idx-i64      (%sv-to-i64 builder idx-raw))
              ;; new offset[0] = off0 + off1 + r * str0
              (r-x-str0  (llvm-build-mul builder idx-i64 src-str0 "sv_r_rxs0"))
              (off1-plus (llvm-build-add builder src-off1 r-x-str0 "sv_r_o1p"))
              (new-off0  (llvm-build-add builder src-off0 off1-plus "sv_r_off0"))
              ;; Build [1 x i64] arrays
              (arr1-undef  (llvm-get-undef (llvm-array-type i64 1)))
              (res-offsets (llvm-build-insert-value builder arr1-undef new-off0  0 "sv_r_roff"))
              (res-strides (llvm-build-insert-value builder arr1-undef src-str1  0 "sv_r_rstr"))
              (res-extents (llvm-build-insert-value builder arr1-undef src-ext1  0 "sv_r_rext")))
         (let* ((r0 (llvm-build-insert-value builder result-undef src-parent   0 "sv_r_r0"))
                (r1 (llvm-build-insert-value builder r0 res-offsets 1 "sv_r_r1"))
                (r2 (llvm-build-insert-value builder r1 res-strides 2 "sv_r_r2"))
                (r3 (llvm-build-insert-value builder r2 res-extents 3 "sv_r_r3"))
                (r4 (llvm-build-insert-value builder r3 src-ext1    4 "sv_r_r4")))
           r4))))))



(defun %spirv-get-or-create-fn (module fn-name llvm-ret-type param-types param-count)
  "Gets or creates an LLVM function declaration in MODULE."
  (let ((existing (llvm-get-named-function module fn-name)))
    (if (cffi:null-pointer-p existing)
        (let ((ft (llvm-function-type llvm-ret-type param-types param-count nil)))
          (llvm-add-function module fn-name ft))
        existing)))




(defun %call-spirv-vec3-builtin (builder module spirv-name)
  "Emits a load from @__spirv_BuiltIn<SPIRV-NAME> addrspace(1) global with zeroinitializer.
   The LLVM-SPIRV translator maps addrspace(1) globals named __spirv_BuiltIn* to SPIR-V
   OpVariable BuiltIn decorations.  Using a zeroinitializer (CommonLinkage) suppresses the
   import linkage that an external declaration generates, preventing the
   ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED error from Level Zero at runtime."
  (let* ((gvar-name (format nil "__spirv_BuiltIn~a" spirv-name))
         (vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (existing  (llvm-get-named-global module gvar-name))
         (gvar      (if (cffi:null-pointer-p existing)
                        (let ((g (llvm-add-global-in-addrspace module vec3-type gvar-name 1)))
                          ;; zeroinitializer → CommonLinkage (8); suppresses import linkage attr
                          (llvm-set-initializer g (llvm-const-null vec3-type))
                          g)
                        existing)))
    (llvm-build-load2 builder vec3-type gvar (string-downcase spirv-name))))

(defun %call-spirv-uint-builtin (builder module spirv-name)
  "Emits a call to @__spirv_BuiltIn<SPIRV-NAME>() returning i32 (uint)."
  (let* ((fn-name  (format nil "__spirv_BuiltIn~a" spirv-name))
         (i32-type (llvm-int32-type))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type (cffi:null-pointer) 0)))
    (llvm-build-call2 builder
                      (llvm-function-type i32-type (cffi:null-pointer) 0 nil)
                      fn (cffi:null-pointer) 0
                      (string-downcase spirv-name))))

(defun %extract-vec3-i64 (builder vec-val dim name-suffix)
  "Extracts element at DIM (0/1/2) from a <3 x i64> LLVM value."
  (llvm-build-extract-element builder vec-val
                               (llvm-const-int (llvm-int32-type) dim nil)
                               name-suffix))



(defun %gen-product-of-vec3 (builder module spirv-name result-name)
  "Computes x*y*z for the <3 x i64> builtin named SPIRV-NAME.
   Backend-aware: uses %get-builtin-vec3 for PTX dispatch."
  (let* ((vec (%get-builtin-vec3 builder module spirv-name))
         (x   (%extract-vec3-i64 builder vec 0 "x"))
         (y   (%extract-vec3-i64 builder vec 1 "y"))
         (z   (%extract-vec3-i64 builder vec 2 "z"))
         (xy  (llvm-build-mul builder x y "xy")))
    (llvm-build-mul builder xy z result-name)))

(defun %gen-flat-linear-id-from-vecs (builder lid-vec lws-vec name)
  "Synthesizes z*lws.y*lws.x + y*lws.x + x from two <3 x i64> values."
  (let* ((x    (%extract-vec3-i64 builder lid-vec 0 "lx"))
         (y    (%extract-vec3-i64 builder lid-vec 1 "ly"))
         (z    (%extract-vec3-i64 builder lid-vec 2 "lz"))
         (lwsx (%extract-vec3-i64 builder lws-vec 0 "lwsx"))
         (lwsy (%extract-vec3-i64 builder lws-vec 1 "lwsy"))
         (lwsy_lwsx (llvm-build-mul builder lwsy lwsx "lwsy_x"))
         (z_part    (llvm-build-mul builder z lwsy_lwsx "z_part"))
         (y_part    (llvm-build-mul builder y lwsx "y_part"))
         (yx        (llvm-build-add builder y_part x "yx")))
    (llvm-build-add builder z_part yx name)))



(defun %gen-local-linear-id (builder module)
  "Synthesizes get-local-linear-id: z*lws.y*lws.x + y*lws.x + x.
   Backend-aware: uses %get-builtin-vec3 for PTX dispatch."
  (let ((lid-vec (%get-builtin-vec3 builder module "LocalInvocationId"))
        (lws-vec (%get-builtin-vec3 builder module "WorkgroupSize")))
    (%gen-flat-linear-id-from-vecs builder lid-vec lws-vec "local_linear_id")))

(defun %gen-global-linear-id (builder module)
  "Synthesizes get-global-linear-id: flat_wg * lws_total + flat_lid.
   Backend-aware: uses %get-builtin-vec3 for PTX dispatch."
  (let* ((lid-vec  (%get-builtin-vec3 builder module "LocalInvocationId"))
         (lws-vec  (%get-builtin-vec3 builder module "WorkgroupSize"))
         (flat-lid (%gen-flat-linear-id-from-vecs builder lid-vec lws-vec "flat_lid"))
         (lwsx     (%extract-vec3-i64 builder lws-vec 0 "lwsx"))
         (lwsy     (%extract-vec3-i64 builder lws-vec 1 "lwsy"))
         (lwsz     (%extract-vec3-i64 builder lws-vec 2 "lwsz"))
         (lws-xy   (llvm-build-mul builder lwsx lwsy "lws_xy"))
         (lws-tot  (llvm-build-mul builder lws-xy lwsz "lws_tot"))
         (wgid-vec (%get-builtin-vec3 builder module "WorkgroupId"))
         (ng-vec   (%get-builtin-vec3 builder module "NumWorkgroups"))
         (flat-wg  (%gen-flat-linear-id-from-vecs builder wgid-vec ng-vec "flat_wg"))
         (base     (llvm-build-mul builder flat-wg lws-tot "base")))
    (llvm-build-add builder base flat-lid "global_linear_id")))

(defun %gen-spirv-warp-barrier (builder module)
  "Emits @__spirv_ControlBarrier(i32 3, i32 3, i32 264).
   Scope=Subgroup(3) MemScope=Subgroup(3) Semantics=AcquireRelease(8)|WorkgroupMemory(256)."
  (let* ((i32-type (llvm-int32-type))
         (fn-name  "__spirv_ControlBarrier")
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 3)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) i32-type)
                        arr))
         (fn-type  (llvm-function-type (llvm-void-type) param-types 3 nil))
         (fn       (let ((ex (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p ex)
                         (llvm-add-function module fn-name fn-type)
                         ex)))
         (args     (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 3)))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type 3 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 1) (llvm-const-int i32-type 3 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 2) (llvm-const-int i32-type 264 nil))
                     arr)))
    (llvm-build-call2 builder fn-type fn args 3 "")
    (cffi:foreign-free args)
    (cffi:foreign-free param-types)
    (values nil nil)))

(defun %gen-spirv-control-barrier (builder module)
  "Emits @__spirv_ControlBarrier(i32 2, i32 2, i32 264).
   Scope=Workgroup(2) MemScope=Workgroup(2) Semantics=AcquireRelease(8)|WorkgroupMemory(256)."
  (let* ((i32-type (llvm-int32-type))
         (fn-name  "__spirv_ControlBarrier")
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 3)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) i32-type)
                        arr))
         (fn-type  (llvm-function-type (llvm-void-type) param-types 3 nil))
         (fn       (let ((ex (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p ex)
                         (llvm-add-function module fn-name fn-type)
                         ex)))
         (args     (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 3)))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type 2 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 1) (llvm-const-int i32-type 2 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 2) (llvm-const-int i32-type 264 nil))
                     arr)))
    (llvm-build-call2 builder fn-type fn args 3 "")
    (values nil nil)))

(defun %gen-spirv-memory-barrier (builder module)
  "Emits @__spirv_MemoryBarrier(i32 1, i32 520).
   MemScope=CrossWorkgroup(1) Semantics=AcquireRelease(8)|CrossWorkgroupMemory(512)."
  (let* ((i32-type (llvm-int32-type))
         (fn-name  "__spirv_MemoryBarrier")
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        arr))
         (fn-type  (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn       (let ((ex (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p ex)
                         (llvm-add-function module fn-name fn-type)
                         ex)))
         (args     (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 2)))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type 1 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 1) (llvm-const-int i32-type 520 nil))
                     arr)))
    (llvm-build-call2 builder fn-type fn args 2 "")
    (values nil nil)))

;;; ----- generate-node-ir for semantic-gpu-builtin -----

;; L0-safe scalar SPIR-V builtin: load from an addrspace(1) i32 global
;; @__spirv_BuiltIn<NAME> with zeroinitializer.  Mirrors the vec3 helper
;; (%call-spirv-vec3-builtin) so the LLVM-SPIRV translator emits a
;; SPIR-V OpVariable BuiltIn decoration rather than an import-linkage
;; function declaration (which causes ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED
;; on Level Zero).
(defun %call-spirv-uint-global-builtin (builder module spirv-name)
  "Loads from an addrspace(1) i32 global @__spirv_BuiltIn<SPIRV-NAME>."
  (let* ((gvar-name (format nil "__spirv_BuiltIn~a" spirv-name))
         (i32-type  (crisp.llvm-bindings::llvm-int32-type))
         (existing  (crisp.llvm-bindings::llvm-get-named-global module gvar-name))
         (gvar      (if (cffi:null-pointer-p existing)
                        (let ((g (crisp.llvm-bindings::llvm-add-global-in-addrspace module i32-type gvar-name 1)))
                          (crisp.llvm-bindings::llvm-set-initializer g (crisp.llvm-bindings::llvm-const-null i32-type))
                          g)
                        existing)))
    (crisp.llvm-bindings::llvm-build-load2 builder i32-type gvar (string-downcase spirv-name))))


;; --- PTX synthesis helpers ---

(defun %ptx-synthesize-global-id-vec3 (builder module)
  "Synthesizes GlobalInvocationId = ctaid * ntid + tid as a <3 x i64>."
  (let* ((vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (i32-type  (llvm-int32-type))
         (acc       (llvm-get-undef vec3-type)))
    (loop for dim from 0 below 3
          do (let* ((ctaid (%ptx-read-sreg-scalar builder module "ctaid" dim))
                    (ntid  (%ptx-read-sreg-scalar builder module "ntid"  dim))
                    (tid   (%ptx-read-sreg-scalar builder module "tid"   dim))
                    (prod  (llvm-build-mul builder ctaid ntid "gid_mul"))
                    (gid   (llvm-build-add builder prod tid "gid_dim")))
               (setf acc (llvm-build-insert-element
                          builder acc gid
                          (llvm-const-int i32-type dim nil)
                          (format nil "gid_vec_~d" dim)))))
    acc))

(defun %ptx-synthesize-global-size-vec3 (builder module)
  "Synthesizes GlobalSize = nctaid * ntid as a <3 x i64>."
  (let* ((vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (i32-type  (llvm-int32-type))
         (acc       (llvm-get-undef vec3-type)))
    (loop for dim from 0 below 3
          do (let* ((nctaid (%ptx-read-sreg-scalar builder module "nctaid" dim))
                    (ntid   (%ptx-read-sreg-scalar builder module "ntid"   dim))
                    (gs     (llvm-build-mul builder nctaid ntid "gs_dim")))
               (setf acc (llvm-build-insert-element
                          builder acc gs
                          (llvm-const-int i32-type dim nil)
                          (format nil "gs_vec_~d" dim)))))
    acc))

(defun %ptx-zero-vec3 (builder module)
  "Returns a <3 x i64> of all zeros (PTX has no GlobalOffset)."
  (let* ((vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (i64-type  (llvm-int64-type))
         (i32-type  (llvm-int32-type))
         (zero      (llvm-const-int i64-type 0 nil))
         (acc       (llvm-get-undef vec3-type)))
    (loop for dim from 0 below 3
          do (setf acc (llvm-build-insert-element
                        builder acc zero
                        (llvm-const-int i32-type dim nil)
                        (format nil "zero_vec_~d" dim))))
    acc))


;; --- Backend-dispatched vec3 read ---

(defun %get-builtin-vec3 (builder module spirv-name)
  "Backend-aware vec3 builtin read.  On SPV, delegates to
   %call-spirv-vec3-builtin.  On PTX, maps SPV names to NVVM
   special-register intrinsics or synthesizes the value from
   component registers."
  (if (eq *target-backend* :ptx)
      (cond
        ((string-equal spirv-name "LocalInvocationId")
         (%ptx-read-sreg-vec3 builder module "tid"))
        ((string-equal spirv-name "WorkgroupSize")
         (%ptx-read-sreg-vec3 builder module "ntid"))
        ((string-equal spirv-name "WorkgroupId")
         (%ptx-read-sreg-vec3 builder module "ctaid"))
        ((string-equal spirv-name "NumWorkgroups")
         (%ptx-read-sreg-vec3 builder module "nctaid"))
        ((string-equal spirv-name "GlobalInvocationId")
         (%ptx-synthesize-global-id-vec3 builder module))
        ((string-equal spirv-name "GlobalSize")
         (%ptx-synthesize-global-size-vec3 builder module))
        ((string-equal spirv-name "GlobalOffset")
         (%ptx-zero-vec3 builder module))
        (t
         (log:warn "PTX: no mapping for vec3 builtin '~a', falling back to SPV path" spirv-name)
         (%call-spirv-vec3-builtin builder module spirv-name)))
      (%call-spirv-vec3-builtin builder module spirv-name)))


;; --- PTX barrier and fence intrinsics ---

(defun %ptx-syncwarp (builder module)
  "Emits @llvm.nvvm.bar.warp.sync(i32) - PTX bar.warp.sync 0xFFFFFFFF."
  (let* ((i32-type (llvm-int32-type))
         (fn-name "llvm.nvvm.bar.warp.sync")
         (void-type (llvm-void-type))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 1)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        arr))
         (fn-type   (llvm-function-type void-type param-types 1 nil))
         (fn        (%spirv-get-or-create-fn module fn-name void-type param-types 1)))
    (let ((args (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 1)))
                  (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type #xFFFFFFFF nil))
                  arr)))
      (llvm-build-call2 builder fn-type fn args 1 "")
      (cffi:foreign-free args))
    (cffi:foreign-free param-types)
    (values nil nil)))

(defun %ptx-barrier (builder module)
  "Emits @llvm.nvvm.barrier0() — PTX bar.sync 0 (workgroup barrier)."
  (let* ((fn-name "llvm.nvvm.barrier0")
         (void-type (llvm-void-type))
         (fn-type   (llvm-function-type void-type (cffi:null-pointer) 0 nil))
         (fn        (%spirv-get-or-create-fn module fn-name void-type
                                             (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "")
    (values nil nil)))

(defun %ptx-membar-cta (builder module)
  "Emits @llvm.nvvm.membar.cta() — PTX membar.cta (workgroup memory fence)."
  (let* ((fn-name "llvm.nvvm.membar.cta")
         (void-type (llvm-void-type))
         (fn-type   (llvm-function-type void-type (cffi:null-pointer) 0 nil))
         (fn        (%spirv-get-or-create-fn module fn-name void-type
                                             (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "")
    (values nil nil)))

;; --- NVPTX special-register helpers --------------------------------

(defun %ptx-read-sreg-scalar (builder module sreg-base dim)
  "Reads @llvm.nvvm.read.ptx.sreg.<SREG-BASE>.<X|Y|Z> and zext-promotes
   the i32 result to i64 (Crisp's ulong contract).
   SREG-BASE: \"tid\" / \"ntid\" / \"ctaid\" / \"nctaid\".
   DIM: 0=x, 1=y, 2=z."
  (let* ((suffix (nth dim '("x" "y" "z")))
         (fn-name (format nil "llvm.nvvm.read.ptx.sreg.~A.~A" sreg-base suffix))
         (i32-type (llvm-int32-type))
         (i64-type (llvm-int64-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0))
         (i32-val  (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0
                                     (format nil "~A_~A" sreg-base suffix))))
    (llvm-build-zext builder i32-val i64-type
                     (format nil "~A_~A_i64" sreg-base suffix))))

(defun %ptx-read-sreg-vec3 (builder module sreg-base)
  "Builds a <3 x i64> vector from x/y/z reads of the NVPTX special
   register family SREG-BASE.  Mirrors the shape of %call-spirv-vec3-builtin
   so the rest of the gpu-builtin codegen can treat both backends
   uniformly."
  (let* ((vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (x (%ptx-read-sreg-scalar builder module sreg-base 0))
         (y (%ptx-read-sreg-scalar builder module sreg-base 1))
         (z (%ptx-read-sreg-scalar builder module sreg-base 2))
         (i32-type (llvm-int32-type))
         (acc0 (llvm-get-undef vec3-type))
         (acc1 (llvm-build-insert-element builder acc0 x
                 (llvm-const-int i32-type 0 nil)
                 (format nil "~A_vec_0" sreg-base)))
         (acc2 (llvm-build-insert-element builder acc1 y
                 (llvm-const-int i32-type 1 nil)
                 (format nil "~A_vec_1" sreg-base)))
         (acc3 (llvm-build-insert-element builder acc2 z
                 (llvm-const-int i32-type 2 nil)
                 (format nil "~A_vec_2" sreg-base))))
    acc3))



;; --- PTX warp helper sreg reads (return i32, matching SPV uint convention) ---

(defun %ptx-read-warp-sreg (builder module sreg-name)
  "Reads a single NVPTX warp special register (warpid, laneid) as i32.
   Unlike %ptx-read-sreg-scalar which zext's to i64, this returns i32
   to match the SPV uint convention used by warp builtins."
  (let* ((fn-name (format nil "llvm.nvvm.read.ptx.sreg.~a" sreg-name))
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 sreg-name)))

(defun %ptx-synthesize-warp-count (builder module)
  "Synthesizes warp count per block: ceil(ntid.x * ntid.y * ntid.z / 32).
   Returns i32 to match SPV uint convention."
  (let* ((i32-type (llvm-int32-type))
         ;; Read ntid.x, ntid.y, ntid.z as i32 (before zext)
         (fn-x-name "llvm.nvvm.read.ptx.sreg.ntid.x")
         (fn-y-name "llvm.nvvm.read.ptx.sreg.ntid.y")
         (fn-z-name "llvm.nvvm.read.ptx.sreg.ntid.z")
         (fn-type   (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn-x      (%spirv-get-or-create-fn module fn-x-name i32-type (cffi:null-pointer) 0))
         (fn-y      (%spirv-get-or-create-fn module fn-y-name i32-type (cffi:null-pointer) 0))
         (fn-z      (%spirv-get-or-create-fn module fn-z-name i32-type (cffi:null-pointer) 0))
         (nx        (llvm-build-call2 builder fn-type fn-x (cffi:null-pointer) 0 "ntid_x_i32"))
         (ny        (llvm-build-call2 builder fn-type fn-y (cffi:null-pointer) 0 "ntid_y_i32"))
         (nz        (llvm-build-call2 builder fn-type fn-z (cffi:null-pointer) 0 "ntid_z_i32"))
         (nxy       (llvm-build-mul builder nx ny "nxy"))
         (total     (llvm-build-mul builder nxy nz "block_size"))
         (c31       (llvm-const-int i32-type 31 nil))
         (c32       (llvm-const-int i32-type 32 nil))
         (sum       (llvm-build-add builder total c31 "block_plus_31")))
    (llvm-build-udiv builder sum c32 "warp_count")))

(defmethod generate-node-ir ((node semantic-gpu-builtin) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a GPU built-in function call.
   Endeavor 115 Phase 2: full PTX dispatch for all builtins."
  (declare (ignore var-env di-builder di-scope location-map))
  (let* ((bname (semantic-gpu-builtin-builtin-name node))
         (dim   (semantic-gpu-builtin-dimension node)))
    (log:info "Generating GPU builtin IR: ~a dim=~a backend=~a" bname dim *target-backend*)
    (labels
        ((vec3-or-scalar (spirv-name)
           (let ((vec (%get-builtin-vec3 builder module spirv-name)))
             (if dim
                 (values (%extract-vec3-i64 builder vec dim
                                            (format nil "~a_~a" (string-downcase spirv-name) dim))
                         nil)
                 (values vec nil)))))
      (case bname
        ;; --- Primitive 3D/scalar vector builtins ---
        (:get-global-id       (vec3-or-scalar "GlobalInvocationId"))
        (:get-local-id        (vec3-or-scalar "LocalInvocationId"))
        (:get-workgroup-id    (vec3-or-scalar "WorkgroupId"))
        (:get-num-groups      (vec3-or-scalar "NumWorkgroups"))
        (:get-local-work-size (vec3-or-scalar "WorkgroupSize"))
        (:get-global-work-size (vec3-or-scalar "GlobalSize"))
        (:get-global-offset   (vec3-or-scalar "GlobalOffset"))
        ;; --- Synthesized: GlobalInvocationId + GlobalOffset ---
        (:get-global-id-abs
         (if (eq *target-backend* :ptx)
             ;; PTX has no GlobalOffset — same as get-global-id
             (vec3-or-scalar "GlobalInvocationId")
             (let* ((gid  (%call-spirv-vec3-builtin builder module "GlobalInvocationId"))
                    (goff (%call-spirv-vec3-builtin builder module "GlobalOffset")))
               (if dim
                   (let* ((gid-n  (%extract-vec3-i64 builder gid  dim "gid_n"))
                          (goff-n (%extract-vec3-i64 builder goff dim "goff_n")))
                     (values (crisp.llvm-bindings::llvm-build-add builder gid-n goff-n "gid_abs_n") nil))
                   (values (crisp.llvm-bindings::llvm-build-add builder gid goff "gid_abs") nil)))))
        ;; --- WorkDim (hidden kernel parameter, uint) ---
        (:get-work-dim
         (values (%call-spirv-uint-builtin builder module "WorkDim") nil))
        ;; --- Synthesized scalar builtins ---
        (:get-local-linear-id
         (values (%gen-local-linear-id builder module) nil))
        (:get-local-linear-size
         (values (%gen-product-of-vec3 builder module "WorkgroupSize" "local_linear_size") nil))
        (:get-global-linear-id
         (values (%gen-global-linear-id builder module) nil))
        ((:get-global-linear-size :get-total-threads)
         (values (%gen-product-of-vec3 builder module "GlobalSize" "total_threads") nil))
        (:get-total-groups
         (values (%gen-product-of-vec3 builder module "NumWorkgroups" "total_groups") nil))
        ;; --- 110: warp helpers ---
        (:warp-id
         (if (eq *target-backend* :ptx)
             (values (%ptx-read-warp-sreg builder module "warpid") nil)
             (values (%call-spirv-uint-global-builtin builder module "SubgroupId") nil)))
        (:warp-lane
         (if (eq *target-backend* :ptx)
             (values (%ptx-read-warp-sreg builder module "laneid") nil)
             (values (%call-spirv-uint-global-builtin builder module "SubgroupLocalInvocationId") nil)))
        (:warp-count
         (if (eq *target-backend* :ptx)
             (values (%ptx-synthesize-warp-count builder module) nil)
             (values (%call-spirv-uint-global-builtin builder module "NumSubgroups") nil)))
        ;; --- Barriers (void) ---
        (:sync-workgroup
         (if (eq *target-backend* :ptx)
             (%ptx-barrier builder module)
             (%gen-spirv-control-barrier builder module)))
        (:sync-warp
         (if (eq *target-backend* :ptx)
             (%ptx-syncwarp builder module)
             (%gen-spirv-warp-barrier builder module)))
        (:mem-fence
         (if (eq *target-backend* :ptx)
             (%ptx-membar-cta builder module)
             (%gen-spirv-memory-barrier builder module)))
        (t (error "Unknown GPU builtin ~a" builtin-name))))))

(defmethod generate-node-ir ((node semantic-to-workgroup-uniform) builder module var-env di-builder di-scope location-map)
  "Emits IR to make a value uniform across the workgroup.
   Phase 1a: This is currently a pass-through that emits a workgroup barrier."
  (let* ((val-node (semantic-to-workgroup-uniform-value-node node))
         (val (generate-node-ir val-node builder module var-env di-builder di-scope location-map)))
    (log:warn "to-workgroup-uniform codegen is currently a pass-through with a barrier.")
    (if (eq *target-backend* :ptx)
        (%ptx-barrier builder module)
        (%gen-spirv-control-barrier builder module))
    (values val nil)))

(defmethod generate-node-ir ((node semantic-to-warp-uniform) builder module var-env di-builder di-scope location-map)
  "Emits IR to make a value uniform across the warp.
   Phase 1a: This is currently a pass-through that emits a warp barrier."
  (let* ((val-node (semantic-to-warp-uniform-value-node node))
         (val (generate-node-ir val-node builder module var-env di-builder di-scope location-map)))
    (log:warn "to-warp-uniform codegen is currently a pass-through.")
    (if (eq *target-backend* :ptx)
        (%ptx-syncwarp builder module)
        (%gen-spirv-warp-barrier builder module))
    (values val nil)))



(defmethod generate-node-ir ((node semantic-dotimes) builder module var-env di-builder di-scope location-map)
  "Generates IR for (dotimes (var limit [stride]) body...).
   Uses alloca+branch loop pattern (consistent with semantic-if).
   LLVM mem2reg promotes the alloca to a phi node during optimization."
  (let* ((limit-node  (semantic-dotimes-limit-node node))
         (stride-node (semantic-dotimes-stride-node node))
         (var-name    (semantic-dotimes-var-name node))
         (body        (semantic-dotimes-body node))
         ;; Determine LLVM type and signed/unsigned comparison from limit type
         (limit-type  (get-single-value-type limit-node))
         (limit-ct    (gethash limit-type *crisp-types*))
         (is-unsigned (and limit-ct (eq (crisp-type-category limit-ct) :unsigned-int)))
         (cmp-pred    (if is-unsigned +llvm-int-ult+ +llvm-int-slt+))
         (llvm-type   (crisp-type-to-llvm-type limit-type module))
         ;; Current function
         (current-fn  (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         ;; Generate limit value in current block
         (limit-val   (generate-node-ir limit-node builder module var-env di-builder di-scope location-map))
         ;; Generate stride value (or constant 1)
         (stride-val  (if stride-node
                          (generate-node-ir stride-node builder module var-env di-builder di-scope location-map)
                          (llvm-const-int llvm-type 1 0)))
         ;; Alloca for the loop variable; initialize to 0
         (i-alloca    (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
         (_           (llvm-build-store builder (llvm-const-int llvm-type 0 0) i-alloca))
         ;; Basic blocks
         (check-block (llvm-append-basic-block current-fn "dt_check"))
         (body-block  (llvm-append-basic-block current-fn "dt_body"))
         (exit-block  (llvm-append-basic-block current-fn "dt_exit")))
    (declare (ignore _))
    ;; Branch from current block into loop check
    (llvm-build-br builder check-block)
    ;; --- Check Block: if i < limit goto body else goto exit ---
    (llvm-position-builder-at-end builder check-block)
    (let* ((i-val   (llvm-build-load2 builder llvm-type i-alloca "i"))
           (cond-v  (llvm-build-icmp builder cmp-pred i-val limit-val "dt_cond")))
      (llvm-build-cond-br builder cond-v body-block exit-block))
    ;; --- Body Block ---
    (llvm-position-builder-at-end builder body-block)
    (let ((body-env (alexandria:copy-hash-table var-env)))
      ;; Expose the loop variable via the alloca so var-read loads from it
      (setf (gethash var-name body-env) i-alloca)
      ;; Generate body expressions
      (dolist (body-node body)
        (generate-node-ir body-node builder module body-env di-builder di-scope location-map))
      ;; Increment: i += stride
      (let* ((i-cur  (llvm-build-load2 builder llvm-type i-alloca "i_cur"))
             (i-next (llvm-build-add builder i-cur stride-val "i_next")))
        (llvm-build-store builder i-next i-alloca)))
    ;; Branch back to check (unless body already terminated, e.g. explicit return)
    (unless (terminator-p (llvm-get-insert-block builder))
      (llvm-build-br builder check-block))
    ;; --- Exit Block ---
    (llvm-position-builder-at-end builder exit-block)
    ;; dotimes returns void
    (values nil nil)))

(defmethod generate-node-ir ((node semantic-while) builder module var-env di-builder di-scope location-map)
  "Generates IR for (while condition body...)."
  (let* ((condition-node (semantic-while-condition-node node))
         (body           (semantic-while-body node))
         (current-fn     (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (check-block    (llvm-append-basic-block current-fn "wh_check"))
         (body-block     (llvm-append-basic-block current-fn "wh_body"))
         (exit-block     (llvm-append-basic-block current-fn "wh_exit")))
    
    (llvm-build-br builder check-block)
    ;; --- Check Block ---
    (llvm-position-builder-at-end builder check-block)
    (let* ((cond-val (generate-node-ir condition-node builder module var-env di-builder di-scope location-map))
           (cond-bool (llvm-build-icmp builder +llvm-int-ne+ cond-val (llvm-const-int (llvm-int32-type) 0 nil) "wh_cond")))
      (llvm-build-cond-br builder cond-bool body-block exit-block))
    
    ;; --- Body Block ---
    (llvm-position-builder-at-end builder body-block)
    (dolist (body-node body)
      (generate-node-ir body-node builder module var-env di-builder di-scope location-map))
    (unless (terminator-p (llvm-get-insert-block builder))
      (llvm-build-br builder check-block))
      
    ;; --- Exit Block ---
    (llvm-position-builder-at-end builder exit-block)
    (values nil nil)))

(defmethod generate-node-ir ((node semantic-eq) builder module var-env di-builder di-scope location-map)
  "Generates IR for =, guarding against NIL lhs-type for enum/keyword operands."
  (multiple-value-bind (lhs lhs-loc)
      (generate-node-ir (semantic-eq-left-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore lhs-loc))
    (multiple-value-bind (rhs rhs-loc)
        (generate-node-ir (semantic-eq-right-arg node) builder module var-env di-builder di-scope location-map)
      (declare (ignore rhs-loc))
      (let* ((lhs-type-name (get-single-value-type (semantic-eq-left-arg node)))
             (lhs-type (gethash lhs-type-name *crisp-types*))
             (lhs (extract-primary-value builder lhs (semantic-node-type (semantic-eq-left-arg node))))
             (rhs (extract-primary-value builder rhs (semantic-node-type (semantic-eq-right-arg node))))
             ;; Guard: enums and keywords are NOT in *crisp-types*; they compile to i32 → signed int.
             (is-float    (and lhs-type (eq (crisp-type-category lhs-type) :float)))
             (cmp-inst
              (if is-float
                  (llvm-build-fcmp builder +llvm-real-oeq+ lhs rhs "fcmp_tmp")
                  (llvm-build-icmp builder +llvm-int-eq+ lhs rhs "icmp_tmp"))))
        (values (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext") nil)))))






(defun %gen-nvvm-cp-async-elem (builder module dst-ptr src-ptr elem-bytes)
  "Emits @llvm.nvvm.cp.async.ca.shared.global.{4|8|16}(dst, src).
   ELEM-BYTES picks the right intrinsic variant."
  (let* ((fn-name (case elem-bytes
                    (4  "llvm.nvvm.cp.async.ca.shared.global.4")
                    (8  "llvm.nvvm.cp.async.ca.shared.global.8")
                    (16 "llvm.nvvm.cp.async.ca.shared.global.16")
                    (t (error "%gen-nvvm-cp-async-elem: unsupported elem-bytes ~A (need 4, 8, or 16)"
                              elem-bytes))))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (ptr-as1    (llvm-pointer-type i8-type 1))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as1)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 2))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 2)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) dst-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) src-ptr)
    (llvm-build-call2 builder fn-type fn args 2 "")))

(defun %gen-nvvm-mbarrier-init-shared (builder module mbarrier-ptr count-val)
  "Emits @llvm.nvvm.mbarrier.init.shared(ptr addrspace(3), i32 count)."
  (let* ((fn-name    "llvm.nvvm.mbarrier.init.shared")
         (i32-type   (llvm-int32-type))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 2))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 2)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) mbarrier-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) count-val)
    (llvm-build-call2 builder fn-type fn args 2 "")))

(defun %gen-nvvm-cp-async-mbarrier-arrive-noinc-shared (builder module mbarrier-ptr)
  "Emits @llvm.nvvm.cp.async.mbarrier.arrive.noinc.shared(ptr addrspace(3))."
  (let* ((fn-name    "llvm.nvvm.cp.async.mbarrier.arrive.noinc.shared")
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 1)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 1 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 1))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 1)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) mbarrier-ptr)
    (llvm-build-call2 builder fn-type fn args 1 "")))

(defun %gen-nvvm-mbarrier-arrive-shared (builder module mbarrier-ptr)
  "Emits @llvm.nvvm.mbarrier.arrive.shared(ptr addrspace(3)) -> i64 state."
  (let* ((fn-name    "llvm.nvvm.mbarrier.arrive.shared")
         (i64-type   (llvm-int64-type))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 1)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        arr))
         (fn-type    (llvm-function-type i64-type param-types 1 nil))
         (fn         (%spirv-get-or-create-fn module fn-name i64-type param-types 1))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 1)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) mbarrier-ptr)
    (llvm-build-call2 builder fn-type fn args 1 "mbar_state")))

(defun %gen-nvvm-mbarrier-test-wait-shared (builder module mbarrier-ptr state-val)
  "Emits @llvm.nvvm.mbarrier.test.wait.shared(ptr addrspace(3), i64 state) -> i1 bool."
  (let* ((fn-name    "llvm.nvvm.mbarrier.test.wait.shared")
         (i1-type    (llvm-int1-type))
         (i64-type   (llvm-int64-type))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i64-type)
                        arr))
         (fn-type    (llvm-function-type i1-type param-types 2 nil))
         (fn         (%spirv-get-or-create-fn module fn-name i1-type param-types 2))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 2)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) mbarrier-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) state-val)
    (llvm-build-call2 builder fn-type fn args 2 "mbar_ready")))

(defun %gen-nvvm-read-tid-x (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.tid.x() → i32 (per-thread tid in X)."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.tid.x")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "tid_x")))

(defun %gen-nvvm-read-tid-y (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.tid.y() → i32."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.tid.y")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "tid_y")))

(defun %gen-nvvm-read-tid-z (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.tid.z() → i32."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.tid.z")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "tid_z")))

(defun %gen-nvvm-read-ntid-x (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.ntid.x() → i32."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.ntid.x")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "ntid_x")))

(defun %gen-nvvm-read-ntid-y (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.ntid.y() → i32."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.ntid.y")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "ntid_y")))

(defun %gen-nvvm-read-ntid-z (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.ntid.z() → i32."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.ntid.z")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "ntid_z")))

(defun %vector-elem-type (tile-type-spec)
  "Returns the element type symbol from a (vector ELEM ...) or (tensor
   ELEM ...) type spec, walking through aliases."
  (let* ((resolved (resolve-type-alias tile-type-spec))
         (canon    (canonicalize-type-specifier resolved)))
    (cond
     ((and (listp canon) (>= (length canon) 2)
           (symbolp (first canon))
           (or (string-equal (symbol-name (first canon)) "VECTOR")
               (string-equal (symbol-name (first canon)) "TENSOR")))
      (second canon))
     ((and (listp canon) (= (length canon) 1) (symbolp (first canon))
           (let ((name (symbol-name (first canon))))
             (or (alexandria:starts-with-subseq "TENSOR_" name)
                 (alexandria:starts-with-subseq "VECTOR_" name))))
      (let* ((name (symbol-name (first canon)))
             (parts (uiop:split-string name :separator "_")))
        (intern (second parts) :crisp.compiler)))
     (t (error "%vector-elem-type: can't extract element type from ~S" canon)))))

(defmethod generate-node-ir ((node semantic-make-async-barrier) builder module var-env
                              di-builder di-scope location-map)
  "Phase B.1 NVPTX: alloc mbarrier and emit mbarrier.init."
  (let* ((cell-val (generate-node-ir (semantic-make-async-barrier-cell-node node) builder module var-env
                                     di-builder di-scope location-map))
         (i32-type (llvm-int32-type))
         (tid-x    (%gen-nvvm-read-tid-x builder module))
         (tid-y    (%gen-nvvm-read-tid-y builder module))
         (tid-z    (%gen-nvvm-read-tid-z builder module))
         (tid-sum  (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz"))
         (is-zero  (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "is_tid_0"))
         (init-bb  (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_init"))
         (merge-bb (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_cont")))
    (llvm-build-cond-br builder is-zero init-bb merge-bb)
    (llvm-position-builder-at-end builder init-bb)
    (let* ((ntid-x (%gen-nvvm-read-ntid-x builder module))
           (ntid-y (%gen-nvvm-read-ntid-y builder module))
           (ntid-z (%gen-nvvm-read-ntid-z builder module))
           (wg-size (llvm-build-mul builder (llvm-build-mul builder ntid-x ntid-y "nxy") ntid-z "nxyz"))
           (cell-storage (llvm-build-extract-value builder cell-val 0 "cell_storage"))
           (cell-ptr     (llvm-build-extract-value builder cell-storage 0 "cell_ptr")))
      (%gen-nvvm-mbarrier-init-shared builder module cell-ptr wg-size)
      (llvm-build-br builder merge-bb))
    (llvm-position-builder-at-end builder merge-bb)
    (%ptx-barrier builder module)
    (values cell-val nil)))

(defmethod generate-node-ir ((node semantic-nvvm-cp-async-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Phase B.1 NVPTX: emit cp.async.ca.shared.global + mbarrier.arrive.noinc."
  (let* ((src-node     (semantic-nvvm-cp-async-tile-copy-src-node node))
         (tile-node    (semantic-nvvm-cp-async-tile-copy-tile-node node))
         (origin-node  (first (semantic-nvvm-cp-async-tile-copy-origin-nodes node)))
         (barrier-node (semantic-nvvm-cp-async-tile-copy-barrier-node node))
         (src-val      (generate-node-ir src-node builder module var-env
                                         di-builder di-scope location-map))
         (tile-val     (generate-node-ir tile-node builder module var-env
                                         di-builder di-scope location-map))
         (barrier-val  (if barrier-node
                           (generate-node-ir barrier-node builder module var-env
                                             di-builder di-scope location-map)
                           nil))
         (origin-raw   (generate-node-ir origin-node builder module var-env
                                         di-builder di-scope location-map))
         (elem-type    (%vector-elem-type (semantic-node-type tile-node)))
         (elem-bytes   (case elem-type
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (error "nvvm cp.async: unsupported element type ~S (need 4 or 8 bytes)"
                                   elem-type))))
         (src-parent   (llvm-build-extract-value builder src-val 0 "src_parent"))
         (src-base     (llvm-build-extract-value builder src-parent 0 "src_base"))
         (tile-parent  (llvm-build-extract-value builder tile-val 0 "tile_parent"))
         (tile-base    (llvm-build-extract-value builder tile-parent 0 "tile_base"))
         (i32-type     (llvm-int32-type))
         (i64-type     (llvm-int64-type))
         (elem-bytes-v (llvm-const-int i64-type elem-bytes nil))
         (tid-i32      (%gen-nvvm-read-tid-x builder module))
         (tid-i64      (llvm-build-sext builder tid-i32 i64-type "tid_i64"))
         (origin-i64   (llvm-build-sext builder origin-raw i64-type "origin_i64"))
         (src-flat     (llvm-build-add builder origin-i64 tid-i64 "src_flat"))
         (src-byte-off (llvm-build-mul builder src-flat elem-bytes-v "src_byte_off"))
         (src-elt-ptr  (let ((indices (cffi:foreign-alloc :pointer :count 1)))
                         (setf (cffi:mem-aref indices :pointer 0) src-byte-off)
                         (llvm-build-in-bounds-gep2
                          builder (llvm-int8-type) src-base indices 1 "src_elt_ptr")))
         (tile-byte-off (llvm-build-mul builder tid-i64 elem-bytes-v "tile_byte_off"))
         (tile-elt-ptr  (let ((indices (cffi:foreign-alloc :pointer :count 1)))
                          (setf (cffi:mem-aref indices :pointer 0) tile-byte-off)
                          (llvm-build-in-bounds-gep2
                           builder (llvm-int8-type) tile-base indices 1 "tile_elt_ptr"))))
    (declare (ignore i32-type))
    (%gen-nvvm-cp-async-elem builder module tile-elt-ptr src-elt-ptr elem-bytes)
    (if barrier-val
        (let* ((barrier-storage (llvm-build-extract-value builder barrier-val 0 "barrier_storage"))
               (barrier-ptr     (llvm-build-extract-value builder barrier-storage 0 "barrier_ptr")))
          (%gen-nvvm-cp-async-mbarrier-arrive-noinc-shared builder module barrier-ptr))
        (error "load-tile-coords missing barrier-node!"))
    (values (llvm-const-int i64-type 0 nil) nil)))

(defmethod generate-node-ir ((node semantic-nvvm-cp-async-wait) builder module var-env
                              di-builder di-scope location-map)
  "Phase B.1 NVPTX: emit mbarrier.arrive and loop on mbarrier.test_wait."
  (let* ((barrier-node (semantic-nvvm-cp-async-wait-barrier-node node))
         (barrier-val  (if barrier-node
                           (generate-node-ir barrier-node builder module var-env
                                             di-builder di-scope location-map)
                           (error "await missing barrier-node!")))
         (barrier-storage (llvm-build-extract-value builder barrier-val 0 "barrier_storage"))
         (barrier-ptr     (llvm-build-extract-value builder barrier-storage 0 "barrier_ptr"))
         (state-val    (%gen-nvvm-mbarrier-arrive-shared builder module barrier-ptr))
         (loop-bb      (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "wait_loop"))
         (cont-bb      (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "wait_cont")))
    (llvm-build-br builder loop-bb)
    (llvm-position-builder-at-end builder loop-bb)
    (let ((is-ready (%gen-nvvm-mbarrier-test-wait-shared builder module barrier-ptr state-val)))
      (llvm-build-cond-br builder is-ready cont-bb loop-bb))
    (llvm-position-builder-at-end builder cont-bb)
    (values (llvm-const-int (llvm-int64-type) 0 nil) nil)))



(defmethod generate-node-ir ((node semantic-make-c-handle) builder module var-env di-builder di-scope location-map)
  "Allocate a local slot (alloca) typed by the held pointer type; the value is
   the slot's address (an addrspace-0 pointer)."
  (declare (ignore var-env di-builder di-scope location-map))
  (let ((held-llvm (crisp-type-to-llvm-type (semantic-make-c-handle-held-type node) module)))
    (crisp.llvm-bindings::llvm-build-alloca builder held-llvm "c_handle_slot")))

(defmethod generate-node-ir ((node semantic-get-pointer) builder module var-env di-builder di-scope location-map)
  "Load the held pointer out of a c-handle slot."
  (let ((held-llvm   (crisp-type-to-llvm-type (semantic-get-pointer-type node) module))
        (handle-val  (generate-node-ir (semantic-get-pointer-handle-node node)
                                       builder module var-env di-builder di-scope location-map)))
    (crisp.llvm-bindings::llvm-build-load2 builder held-llvm handle-val "c_handle_load")))
