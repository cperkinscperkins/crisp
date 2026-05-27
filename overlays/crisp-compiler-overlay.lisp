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
