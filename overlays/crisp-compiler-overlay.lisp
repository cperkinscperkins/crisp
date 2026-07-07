;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 130's hardware-profile logic graduated to
;;;;  src/hardware-profile.lisp.  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;;; ===================================================================
;;; Endeavor 133 (MMA on SPV) — cooperative-matrix codegen emitters.
;;;
;;; Derived from the validated IR contract (put_temp_files_here/coop*.ll round-trips):
;;;   type   target("spirv.CooperativeMatrixKHR", <elem>, 3, <rows>, <cols>, <use>)
;;;   fill   %acc = __spirv_CompositeConstruct(<init scalar>)
;;;   load   %m   = __spirv_CooperativeMatrixLoadKHR_<suffix>(ptr as(1), i32 layout, i64 stride, i32 0)
;;;   mma    %d   = __spirv_CooperativeMatrixMulAddKHR(%a, %b, %c, i32 0)
;;;   store        __spirv_CooperativeMatrixStoreKHR(ptr as(1), %m, i32 layout, i64 stride, i32 0)
;;; use: 0=A 1=B 2=Accumulator ; scope 3=Subgroup ; layout 0=RowMajor 1=ColMajor.
;;; ===================================================================

(defun %coop-type (elem-llvm rows cols use)
  "Build target(\"spirv.CooperativeMatrixKHR\", ELEM-LLVM, 3, ROWS, COLS, USE) in the
   global context (= the module's context, so the type matches)."
  (let ((ctx (crisp.llvm-bindings::llvm-get-global-context)))
    (cffi:with-foreign-objects ((tps :pointer 1) (ips :unsigned-int 4))
      (setf (cffi:mem-aref tps :pointer 0) elem-llvm
            (cffi:mem-aref ips :unsigned-int 0) 3          ; Subgroup scope
            (cffi:mem-aref ips :unsigned-int 1) rows
            (cffi:mem-aref ips :unsigned-int 2) cols
            (cffi:mem-aref ips :unsigned-int 3) use)
      (crisp.llvm-bindings::llvm-target-ext-type-in-context
       ctx "spirv.CooperativeMatrixKHR" tps 1 ips 4))))

(defun %coop-call (builder module name ret-type param-types arg-vals)
  "Declare (once) NAME : RET-TYPE(PARAM-TYPES…) and build a call with ARG-VALS."
  (let ((np (length param-types)) (na (length arg-vals)))
    (cffi:with-foreign-objects ((ptypes :pointer (max 1 np)) (args :pointer (max 1 na)))
      (loop for i from 0 for ty in param-types do (setf (cffi:mem-aref ptypes :pointer i) ty))
      (loop for i from 0 for v in arg-vals do (setf (cffi:mem-aref args :pointer i) v))
      (let* ((fnty (crisp.llvm-bindings::llvm-function-type ret-type ptypes np nil))
             (existing (crisp.llvm-bindings::llvm-get-named-function module name))
             (fn (if (cffi:null-pointer-p existing)
                     (crisp.llvm-bindings::llvm-add-function module name fnty)
                     existing)))
        (crisp.llvm-bindings::llvm-build-call2 builder fnty fn args na "")))))

(defun %coop-ptr-type (&optional (as 1))
  "ptr addrspace(AS) — memory pointer for coop load/store (global=1, SLM/local=3)."
  (crisp.llvm-bindings::llvm-pointer-type (crisp.llvm-bindings::llvm-int8-type) as))

(defun %ptr-as (ptr-val)
  "The address space of a pointer VALUE (global=1, SLM=3)."
  (crisp.llvm-bindings::llvm-get-pointer-address-space (crisp.llvm-bindings::llvm-type-of ptr-val)))

(defun %coop-fill (builder module init-val elem-llvm rows cols use)
  "Construct a coop matrix filled with INIT-VAL (scalar) via __spirv_CompositeConstruct."
  (%coop-call builder module
              (format nil "__spirv_CompositeConstruct_~d_~d_~d" use rows cols)
              (%coop-type elem-llvm rows cols use)
              (list elem-llvm) (list init-val)))

(defun %coop-load (builder module ptr stride-val elem-llvm rows cols use layout)
  "Emit CooperativeMatrixLoadKHR(PTR, LAYOUT, STRIDE, 0) -> coop(elem,rows,cols,use).
   STRIDE-VAL is an i64 LLVM value (leading dimension in elements)."
  (let ((i32 (crisp.llvm-bindings::llvm-int32-type))
        (i64 (crisp.llvm-bindings::llvm-int64-type))
        (as  (%ptr-as ptr)))
    (%coop-call builder module
                (format nil "__spirv_CooperativeMatrixLoadKHR_~d_~d_~d_as~d" use rows cols as)
                (%coop-type elem-llvm rows cols use)
                (list (%coop-ptr-type as) i32 i64 i32)
                (list ptr
                      (crisp.llvm-bindings::llvm-const-int i32 layout nil)
                      stride-val
                      (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, 0) -> the MxN accumulator coop matrix."
  (let* ((a-ty (%coop-type elem-llvm m k 0))
         (b-ty (%coop-type elem-llvm k n 1))
         (c-ty (%coop-type elem-llvm m n 2))
         (i32  (crisp.llvm-bindings::llvm-int32-type)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

(defun %coop-store (builder module ptr matrix-val stride-val elem-llvm rows cols use layout)
  "Emit CooperativeMatrixStoreKHR(PTR, MATRIX, LAYOUT, STRIDE, 0)."
  (let ((i32 (crisp.llvm-bindings::llvm-int32-type))
        (i64 (crisp.llvm-bindings::llvm-int64-type))
        (as  (%ptr-as ptr)))
    (%coop-call builder module
                (format nil "__spirv_CooperativeMatrixStoreKHR_~d_~d_~d_as~d" use rows cols as)
                (crisp.llvm-bindings::llvm-void-type)
                (list (%coop-ptr-type as) (%coop-type elem-llvm rows cols use) i32 i64 i32)
                (list ptr matrix-val
                      (crisp.llvm-bindings::llvm-const-int i32 layout nil)
                      stride-val
                      (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

;;; --- coop-op codegen: element pointer + leading-dim stride from a Crisp tensor -------

(defun %coop-tensor-ptr+stride (builder tensor-val orow ocol layout)
  "From a Crisp tensor STRUCT value, return (values element-ptr stride-i64) for the coop
   tile whose element origin is (OROW, OCOL) — both i64 LLVM values.  Tensor layout: field0
   = parent storage {ptr,i64}, field2 = strides [N x i64].  Leading dim = strides[0]
   (RowMajor) / strides[1] (ColMajor)."
  (let* ((f32 (llvm-float-type))
         (storage (llvm-build-extract-value builder tensor-val 0 "coop_storage"))
         (base    (llvm-build-extract-value builder storage 0 "coop_base"))
         (strides (llvm-build-extract-value builder tensor-val 2 "coop_strides"))
         (s0 (llvm-build-extract-value builder strides 0 "coop_s0"))
         (s1 (llvm-build-extract-value builder strides 1 "coop_s1"))
         (off0 (llvm-build-mul builder orow s0 "coop_off0"))
         (off1 (llvm-build-mul builder ocol s1 "coop_off1"))
         (flat (llvm-build-add builder off0 off1 "coop_flat"))
         (stride (if (= layout 0) s0 s1)))
    (cffi:with-foreign-object (idx :pointer 1)
      (setf (cffi:mem-aref idx :pointer 0) flat)
      (values (llvm-build-gep2 builder f32 base idx 1 "coop_elem_ptr") stride))))

(defmethod generate-node-ir ((node semantic-coop-op) builder module var-env di-builder di-scope location-map)
  "Endeavor 133: lower a cooperative-matrix op (fill / load / store)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((kind (semantic-coop-op-kind node))
          (rows (semantic-coop-op-rows node))
          (cols (semantic-coop-op-cols node))
          (use  (semantic-coop-op-use node))
          (layout (semantic-coop-op-layout node))
          (i64 (llvm-int64-type))
          (f32 (llvm-float-type)))
      (labels ((origin (dim-node dim)
                 ;; element origin along an axis = (tile-id * DIM), computed at runtime:
                 ;; generate the tile-id int node, sext to i64, multiply by the compile-time DIM.
                 (llvm-build-mul builder
                                 (llvm-build-sext builder (gen dim-node) i64 "coop_tid")
                                 (llvm-const-int i64 dim nil) "coop_orig")))
        (ecase kind
          (:fill
           (values (%coop-fill builder module (gen (semantic-coop-op-value-node node))
                               f32 rows cols use)
                   nil))
          (:load
           (multiple-value-bind (ptr stride)
               (%coop-tensor-ptr+stride builder (gen (semantic-coop-op-tensor-node node))
                                        (origin (semantic-coop-op-ty node) rows)
                                        (origin (semantic-coop-op-tx node) cols) layout)
             (values (%coop-load builder module ptr stride f32 rows cols use layout) nil)))
          (:store
           (let* ((mat (gen (semantic-coop-op-value-node node)))
                  (tv  (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride f32 rows cols use layout)
               (values nil nil)))))))))

;;; --- the 5 fragment-form analyzers, forked on *target-backend* ----------------------
;;; :spirv -> cooperative-matrix nodes; else the existing NVIDIA per-lane rewrites (copied
;;; verbatim from src/mma.lisp so this stays a drop-in whole-function replacement).

(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT).  :spirv -> a filled accumulator coop
   matrix; else the NVIDIA %construct-struct record."
  (destructuring-bind (m n init) (cdr expr)
    (unless (and (eql m 16) (eql n 8))
      (error 'crisp-compiler-error
             :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
    (if (eq *target-backend* :spirv)
        (make-semantic-coop-op
         :type (list 'coop-matrix 'float m n 2) :kind :fill
         :value-node (analyze-expression init env context (append location '(1)))
         :rows m :cols n :use 2 :layout 0 :source-location location)
        (analyze-expression
         `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init)
         env context location))))

(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          (make-semantic-coop-op
           :type (list 'coop-matrix 'float 16 8 0) :kind :load
           :tensor-node (analyze-expression src env context (append location '(1)))
           :rows 16 :cols 8 :use 0 :layout 0
           :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
           :tx (analyze-expression `(to-int ,tk) env context (append location '(3)))
           :source-location location)
          (analyze-expression
           `(let ((lane (to-int (warp-lane))))
              (let ((g (/ lane 4)) (tg (rem lane 4)))
                (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
                  (%construct-struct register-fragment-a-tf32-16x8
                    (~ ,src r c) (~ ,src (+ r 8) c) (~ ,src r (+ c 4)) (~ ,src (+ r 8) (+ c 4))))))
           env context location)))))

(defun analyze-load-fragment-b (expr env context location)
  "P2 / F-SPV: (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,
   8x8, col-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (make-semantic-coop-op
           :type (list 'coop-matrix 'float 8 8 1) :kind :load
           :tensor-node (analyze-expression src env context (append location '(1)))
           :rows 8 :cols 8 :use 1 :layout 1
           :ty (analyze-expression `(to-int ,tk) env context (append location '(2)))
           :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
           :source-location location)
          (analyze-expression
           `(let ((lane (to-int (warp-lane))))
              (let ((g (/ lane 4)) (tg (rem lane 4)))
                (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                  (%construct-struct register-fragment-b-tf32-8x8
                    (~ ,src r c) (~ ,src (+ r 4) c)))))
           env context location)))))

(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes."
  (destructuring-bind (frag dest tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (make-semantic-coop-op
           :type 'void :kind :store
           :value-node  (analyze-expression frag env context (append location '(1)))
           :tensor-node (analyze-expression dest env context (append location '(2)))
           :rows 16 :cols 8 :use 2 :layout 0
           :ty (analyze-expression `(to-int ,ty) env context (append location '(3)))
           :tx (analyze-expression `(to-int ,tx) env context (append location '(4)))
           :source-location location)
          (analyze-expression
           `(let ((frag-val ,frag))
              (let ((lane (to-int (warp-lane))))
                (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                  (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                    (set! (~ ,dest row col)             (%extract-struct-member frag-val 0))
                    (set! (~ ,dest row (+ col 1))       (%extract-struct-member frag-val 1))
                    (set! (~ ,dest (+ row 8) col)       (%extract-struct-member frag-val 2))
                    (set! (~ ,dest (+ row 8) (+ col 1)) (%extract-struct-member frag-val 3))))))
           env context location)))))

(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop
   matrix on :spirv, else the fp32 record.  Codegen forks in the generate-node-ir below."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (make-semantic-mma-accumulate
     :type (if (eq *target-backend* :spirv)
               (list 'coop-matrix 'float 16 8 2)
               'register-fragment-acc-f32-16x8)
     :c-node (analyze-expression c-arg env context location)
     :a-node (analyze-expression a-arg env context location)
     :b-node (analyze-expression b-arg env context location)
     :source-location location)))

(defun %emit-nvvm-mma (builder module a-val b-val c-val)
  "The NVIDIA tf32 m16n8k8 MMA (@llvm.nvvm.mma.m16n8k8.row.col.tf32) — copied from the
   original src/mma.lisp semantic-mma-accumulate codegen; A-VAL/B-VAL/C-VAL are the fp32
   fragment records.  Returns (values acc-record nil)."
  (let* ((f32 (llvm-float-type))
         (i32 (llvm-int32-type))
         (a-ops (loop for i below 4 collect
                      (llvm-build-bit-cast builder (llvm-build-extract-value builder a-val i (format nil "a~d" i)) i32 (format nil "a~di" i))))
         (b-ops (loop for i below 2 collect
                      (llvm-build-bit-cast builder (llvm-build-extract-value builder b-val i (format nil "b~d" i)) i32 (format nil "b~di" i))))
         (c-ops (loop for i below 4 collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
         (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                   (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) f32))
                   (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
         (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                  (loop for i from 0 for ty in (list i32 i32 i32 i32 i32 i32 f32 f32 f32 f32)
                        do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                  (llvm-function-type ret-ty arr 10 nil)))
         (fn-name "llvm.nvvm.mma.m16n8k8.row.col.tf32")
         (fn (let ((existing (llvm-get-named-function module fn-name)))
               (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
         (args (append a-ops b-ops c-ops))
         (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                     (loop for i from 0 for v in args do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                     arr))
         (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma"))
         (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f32-16x8 module))
         (result (let ((agg (llvm-get-undef acc-ty)))
                   (dotimes (i 4)
                     (setf agg (llvm-build-insert-value builder agg
                                (llvm-build-extract-value builder call i (format nil "d~d" i))
                                i (format nil "acc~d" i))))
                   agg)))
    (values result nil)))

(defun %module-uses-coop-matrix-p (module)
  "T if MODULE declares/calls any __spirv_CooperativeMatrix* builtin (Endeavor 133) — used
   to add --spirv-ext=+SPV_KHR_cooperative_matrix only when needed."
  (let ((fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop until (cffi:null-pointer-p fn) do
      (let ((name (crisp.llvm-bindings::llvm-get-value-name fn)))
        (when (and name (search "CooperativeMatrix" name))
          (return-from %module-uses-coop-matrix-p t)))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    nil))

;; src/compiler.lisp — add SPV_KHR_cooperative_matrix to the llvm-spirv ext-flags when the
;; module uses cooperative matrices (Endeavor 133).  Whole-function replacement.
(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as -> llvm-spirv."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (bc-file     (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))
    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")
    (when (%module-uses-native-builtin-p module)
      (%emit-opencl-version-metadata module))
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags (append '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                              (when (%module-uses-coop-matrix-p module)
                                '("--spirv-ext=+SPV_KHR_cooperative_matrix"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))

(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV: on :spirv emit CooperativeMatrixMulAddKHR; else the tf32 NVVM intrinsic (132)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
          (a-val (gen (semantic-mma-accumulate-a-node node)))
          (b-val (gen (semantic-mma-accumulate-b-node node))))
      (if (eq *target-backend* :spirv)
          (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) 16 8 8) nil)
          (%emit-nvvm-mma builder module a-val b-val c-val)))))

