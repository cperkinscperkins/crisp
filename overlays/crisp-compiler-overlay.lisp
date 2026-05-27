;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; Endeavor 115 Phase 1 — NVPTX dispatch for GPU built-ins
;; ======================================================================
;;
;; Crisp's GPU built-ins currently lower to SPV `__spirv_BuiltIn*`
;; global-variable reads.  On SPV/L0 the driver auto-populates these
;; per-thread from launch geometry; on NVPTX/CUDA they stay as reads
;; from undefined globals, producing garbage at runtime.  This blocked
;; the first PTX-runtime verification of Crisp output on RunPod.
;;
;; Phase 1 scope: the two built-ins the 113/01 test kernel actually
;; uses — `get-local-id` and `get-local-work-size`.  Lowers to the
;; corresponding NVPTX special-register reads (i32) sext'd to i64
;; (so Crisp's ulong contract is preserved).  All other built-ins
;; stay on the SPV path for Phase 2.
;;
;; src/codegen.lisp


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


;; --- generate-node-ir for semantic-gpu-builtin (whole-function redefine)
;;
;; Verbatim from src/codegen.lisp with two changes:
;;   - vec3-or-scalar takes an optional PTX-SREG-BASE argument
;;   - When PTX-SREG-BASE is supplied AND *target-backend* = :ptx, emit
;;     NVPTX special-register reads instead of SPV global loads.
;;   - For Phase 1 only :get-local-id and :get-local-work-size pass
;;     the PTX-SREG-BASE; everything else stays SPV-only.

(defmethod generate-node-ir ((node semantic-gpu-builtin) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a GPU built-in function call.
   Endeavor 115 Phase 1: PTX dispatch for :get-local-id and :get-local-work-size."
  (declare (ignore var-env di-builder di-scope location-map))
  (let* ((bname (semantic-gpu-builtin-builtin-name node))
         (dim   (semantic-gpu-builtin-dimension node)))
    (log:info "Generating GPU builtin IR: ~a dim=~a backend=~a" bname dim *target-backend*)
    (labels
        ((vec3-or-scalar (spirv-name &optional ptx-sreg-base)
           (let ((vec
                  (if (and (eq *target-backend* :ptx) ptx-sreg-base)
                      (%ptx-read-sreg-vec3 builder module ptx-sreg-base)
                      (%call-spirv-vec3-builtin builder module spirv-name))))
             (if dim
                 (values (%extract-vec3-i64 builder vec dim
                                            (format nil "~a_~a" (string-downcase spirv-name) dim))
                         nil)
                 (values vec nil)))))
      (case bname
        ;; --- Primitive 3D/scalar vector builtins ---
        (:get-global-id       (vec3-or-scalar "GlobalInvocationId"))
        (:get-local-id        (vec3-or-scalar "LocalInvocationId" "tid"))
        (:get-workgroup-id    (vec3-or-scalar "WorkgroupId"))
        (:get-num-groups      (vec3-or-scalar "NumWorkgroups"))
        (:get-local-work-size (vec3-or-scalar "WorkgroupSize" "ntid"))
        (:get-global-work-size (vec3-or-scalar "GlobalSize"))
        (:get-global-offset   (vec3-or-scalar "GlobalOffset"))
        ;; --- Synthesized: GlobalInvocationId + GlobalOffset ---
        (:get-global-id-abs
         (let* ((gid  (%call-spirv-vec3-builtin builder module "GlobalInvocationId"))
                (goff (%call-spirv-vec3-builtin builder module "GlobalOffset")))
           (if dim
               (let* ((gid-n  (%extract-vec3-i64 builder gid  dim "gid_n"))
                      (goff-n (%extract-vec3-i64 builder goff dim "goff_n")))
                 (values (crisp.llvm-bindings::llvm-build-add builder gid-n goff-n "gid_abs_n") nil))
               (values (crisp.llvm-bindings::llvm-build-add builder gid goff "gid_abs") nil))))
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
        ;; --- 110: warp helpers (scalar uint, L0-safe addrspace(1) globals) ---
        (:warp-id
         (values (%call-spirv-uint-global-builtin builder module "SubgroupId") nil))
        (:warp-lane
         (values (%call-spirv-uint-global-builtin builder module "SubgroupLocalInvocationId") nil))
        (:warp-count
         (values (%call-spirv-uint-global-builtin builder module "NumSubgroups") nil))
        ;; --- Barriers (void) ---
        (:local-barrier (%gen-spirv-control-barrier builder module))
        (:mem-fence     (%gen-spirv-memory-barrier  builder module))
        (t (error "generate-node-ir: unknown GPU builtin ~a" bname))))))


;; ======================================================================
;; Endeavor 115 Phase 1.5 — PTX kernel-entry shared-pointer demotion
;; ======================================================================
;;
;; The CUDA driver rejects any kernel image whose entry signature declares
;; a parameter as `.ptr .shared` or `.ptr .local` — shared and local
;; address spaces have no addressable launch-time value, so pointers there
;; aren't legal kernel arguments.  ptxas accepts the PTX, but
;; cuModuleLoadDataEx fails with `device kernel image is invalid`.
;;
;; Crisp's tile parameter (a tensor over :local) caused exactly this when
;; passed at the kernel boundary: the parent-of-storage field's pointer
;; was typed `i8 addrspace(3)*`, and NVPTX faithfully lowered it to
;; `.ptr .shared .align 1`.  Symptom appeared on RunPod (RTX 4000 Ada,
;; driver 550.127.05 / CUDA 12.4) during the first PTX runtime
;; verification of 113/01.
;;
;; Fix (option 2): at the kernel-entry marshalling layer, demote any
;; pointer in addrspace 3 (shared) or 5 (NVPTX local) to plain i64.  The
;; kernel body already treats these as 64-bit values (it loads as u64,
;; adds thread offsets, and uses as a shared address directly); we just
;; need to inttoptr back to the original addrspace at the receive site so
;; the body's IR type-checks.  This is PTX-only and entry-point-only —
;; non-kernel functions and SPV are unaffected.
;;
;; Verifier (option 3): inside CREATE-LLVM-FUNCTION-TYPE, walk the
;; post-demotion expanded-param-types list and error if any entry is
;; still an illegal-for-entry pointer.  Belt-and-suspenders: if a future
;; change adds a new path that produces such a pointer without going
;; through %PTX-ENTRY-DEMOTE-TYPE, the verifier catches it before the
;; kernel image hits the driver.  We check expanded types rather than
;; walking the live llvm-function via LLVMCountParams to avoid plumbing
;; a new foreign binding through llvm-bindings-overlay.


;; --- helpers (no src/codegen.lisp counterpart yet) ---

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


;; --- src/codegen/abi.lisp
;;
;; Whole-function redefine adding optional IS-ENTRY-POINT parameter.
;; When PTX + entry-point: post-processes EXPANDED-PARAM-TYPES to
;; demote any shared/local pointer to i64.  Identical to the original
;; otherwise.

(defun create-llvm-function-type (module return-types param-nodes &optional is-entry-point fn-name)
  "Calculates the LLVM function type, handling parameter explosion.
   When IS-ENTRY-POINT is non-NIL and *TARGET-BACKEND* is :PTX, demotes
   shared (addrspace 3) and local (addrspace 5) pointer params to i64
   so the resulting kernel image will be accepted by the CUDA driver
   (see header comment in this overlay).  After demotion, runs the
   PTX-entry verifier as a belt-and-suspenders check.  FN-NAME is used
   only in the verifier's error message."
  (let* ((return-type (get-llvm-return-type module return-types))
         (expanded-param-types
          (mapcan (lambda (p)
                    (let ((type-spec (semantic-param-type p))
                          (expanded (get-expanded-types (semantic-param-type p) module)))
                      (log:debug "PARAM: ~a TYPE: ~a EXPANDED-COUNT: ~a"
                                 (semantic-param-name p)
                                 type-spec
                                 (length expanded))
                      expanded))
                  param-nodes))
         (expanded-param-types
          (if (and (eq *target-backend* :ptx) is-entry-point)
              (mapcar #'%ptx-entry-demote-type expanded-param-types)
              expanded-param-types)))
    (when (and (eq *target-backend* :ptx) is-entry-point)
      (%verify-ptx-entry-expanded-types expanded-param-types
                                        (or fn-name "<unknown>")))
    (let* ((param-count (length expanded-param-types))
           (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
      (loop for i from 0
            for type in expanded-param-types
            do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))
      (llvm-function-type return-type param-types-array param-count nil))))


;; --- src/codegen.lisp
;;
;; Whole-function redefine adding optional IS-ENTRY-POINT parameter.
;; When PTX + entry-point: restores demoted i64 params back to their
;; original-addrspace pointers via inttoptr before IMPLODE-VALUE packs
;; them into the storage-handle record.  Identical to the original
;; otherwise.

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
            (log:debug "Init-func-params: param-name='~s' (type: ~a) type-spec='~s'"
                       param-name (type-of param-name) type-spec)
            (log:debug "Cached INT32: ~a" *cached-int32-type*)
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


;; --- src/codegen.lisp
;;
;; Whole-function redefine threading IS-ENTRY-POINT to
;; CREATE-LLVM-FUNCTION-TYPE and running the post-creation verifier.

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


;; --- src/codegen.lisp
;;
;; Whole-function redefine threading IS-ENTRY-POINT into
;; INITIALIZE-FUNCTION-PARAMETERS.

(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function.
   Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the
   PTX kernel-entry receive site can inttoptr demoted i64 params back
   to their original-addrspace pointer (see header comment)."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function))
        (is-entry-point (semantic-function-is-entry-point semantic-function)))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env is-entry-point)

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
        (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc))))))
