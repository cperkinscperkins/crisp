;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; Endeavor 115 Phase 2 — Full PTX builtin coverage
;; ======================================================================
;;
;; Phase 1 wired :get-local-id (tid) and :get-local-work-size (ntid).
;; Phase 2 covers everything else: workgroup-id, num-groups, global-id
;; (synthesized), global-work-size (synthesized), global-offset (zero),
;; barriers, mem-fence, warp helpers, and all synthesized scalar
;; builtins (local-linear-id, global-linear-id, product-of-vec3).
;;
;; Approach: introduce %get-builtin-vec3 which maps SPV builtin names
;; to PTX equivalents (simple sregs AND synthesis), then make all the
;; existing helpers use it instead of calling %call-spirv-vec3-builtin
;; directly.  This way the entire GPU-builtin codegen becomes
;; backend-aware with minimal changes.


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


;; --- Whole-function redefines: make synthesized helpers backend-aware ---

;; src/codegen.lisp
(defun %gen-product-of-vec3 (builder module spirv-name result-name)
  "Computes x*y*z for the <3 x i64> builtin named SPIRV-NAME.
   Backend-aware: uses %get-builtin-vec3 for PTX dispatch."
  (let* ((vec (%get-builtin-vec3 builder module spirv-name))
         (x   (%extract-vec3-i64 builder vec 0 "x"))
         (y   (%extract-vec3-i64 builder vec 1 "y"))
         (z   (%extract-vec3-i64 builder vec 2 "z"))
         (xy  (llvm-build-mul builder x y "xy")))
    (llvm-build-mul builder xy z result-name)))

;; src/codegen.lisp
(defun %gen-local-linear-id (builder module)
  "Synthesizes get-local-linear-id: z*lws.y*lws.x + y*lws.x + x.
   Backend-aware: uses %get-builtin-vec3 for PTX dispatch."
  (let ((lid-vec (%get-builtin-vec3 builder module "LocalInvocationId"))
        (lws-vec (%get-builtin-vec3 builder module "WorkgroupSize")))
    (%gen-flat-linear-id-from-vecs builder lid-vec lws-vec "local_linear_id")))

;; src/codegen.lisp
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


;; --- Whole-function redefine: generate-node-ir for semantic-gpu-builtin ---
;;
;; src/codegen.lisp
;;
;; Full PTX dispatch for all GPU builtins.  The vec3-or-scalar local
;; function now uses %get-builtin-vec3 (which handles the SPV→PTX
;; mapping internally), so no ptx-sreg-base parameter is needed.
;; Barriers, mem-fence, and warp helpers dispatch to PTX-specific
;; implementations when *target-backend* = :ptx.

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
        (:local-barrier
         (if (eq *target-backend* :ptx)
             (%ptx-barrier builder module)
             (%gen-spirv-control-barrier builder module)))
        (:mem-fence
         (if (eq *target-backend* :ptx)
             (%ptx-membar-cta builder module)
             (%gen-spirv-memory-barrier builder module)))
        (t (error "generate-node-ir: unknown GPU builtin ~a" bname))))))

