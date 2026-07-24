;;;; src/mma.lisp
;;;;
;;;; Endeavor 132 — MMA fundamentals (tensor-core / DPAS matrix multiply).
;;;;
;;;; This file owns the register-fragment type family and the MMA forms:
;;;;   make-register-fragment / store-fragment  (P1)
;;;;   load-fragment-a / load-fragment-b / mma-accumulate   (P2, later)
;;;;   make-register-tile / mma-accumulate-via-tile         (P3, later)
;;;;
;;;; A register-fragment is a WARP-COLLECTIVE MMA operand/accumulator represented as
;;;; a record — "a collection of registers", non-contiguous (records are registers;
;;;; structs are contiguous memory). One warp's worth of the logical fragment is
;;;; distributed across its lanes (for m16n8 fp32 accumulate: 16*8 / 32 lanes = 4
;;;; fp32 per lane). The warp-collective meaning lives in the ops (store-fragment,
;;;; later mma-accumulate / ldmatrix), NOT in the data — so the storage is a plain
;;;; thread-local record.

(in-package :crisp.compiler)


;;; ===================================================================
;;; P1 — the register-fragment record type.
;;;
;;; Concrete first shape: a 16x8 fp32 ACCUMULATOR fragment for a 32-lane warp
;;; (4 fp32 registers per lane). Generalized minting per (role, dtype, M, N,
;;; simd-width) comes later; P1 pins one shape to drive the vertical slice.
;;; ===================================================================

;; P1 slice: minimal record — just the 4 per-lane accumulator registers.
;;
;; NOTE: we register the record type PROGRAMMATICALLY rather than via the def-record
;; macro.  def-record emits user-facing MAKE-/accessor def-functions that compile
;; immediately; loaded from a build-time src file (no active compiler session) those
;; accessors fail to analyze.  A *system* type needs none of that — codegen builds and
;; reads fields with the low-level %construct-struct / %extract-struct-member primitives
;; — so we call register-struct-definition directly.
;;
;; MMA metadata (role / shape / regs-per-lane / layout) is carried by the analyzer +
;; codegen keyed on the record NAME for now (it encodes acc / f32 / 16x8 / 4-regs);
;; it graduates to a richer minting when we generalize across shapes.
(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float."
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record))


;;; ===================================================================
;;; P1 — make-register-fragment analyzer.
;;;
;;; (make-register-fragment M N INIT) mints a warp-collective accumulator fragment.
;;; We rewrite it to the low-level %construct-struct primitive (splatting INIT across
;;; the per-lane registers) and analyze that, so all the existing record
;;; construction / typing / codegen machinery is reused for free.
;;; ===================================================================



(defun %spv-mma-shape ()
  "The (values M N K) cooperative-matrix INSTRUCTION shape for the SPV path.  Vendor-
   specific: from the active hardware profile's :mma-shapes (first entry) — e.g. Intel
   BMG tf32 is (8 16 8) — else the NVIDIA default (16 8 8).  So the SAME kernel source
   picks the right hardware shape per --hardware-profile.  A/B/C coop dims derive from
   it: A = MxK, B = KxN, C(accumulator) = MxN."
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if (and shapes (consp (first shapes)) (= (length (first shapes)) 3))
        (values-list (first shapes))
        (values 16 8 8))))

(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT).  :spirv -> a filled accumulator coop
   matrix; else the NVIDIA %construct-struct record."
  (destructuring-bind (m n init) (cdr expr)
    (if (eq *target-backend* :spirv)
        ;; accumulator = MxN from the active profile's mma-shape (the source m/n is a
        ;; logical hint; the hardware shape wins so one source runs on both vendors).
        (multiple-value-bind (sm sn sk) (%spv-mma-shape)
          (declare (ignore sk))
          (make-semantic-coop-op
           :type (list 'coop-matrix 'float sm sn 2) :kind :fill
           :value-node (analyze-expression init env context (append location '(1)))
           :rows sm :cols sn :use 2 :layout 0 :source-location location))
        (progn
          (unless (and (eql m 16) (eql n 8))
            (error 'crisp-compiler-error
                   :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
          (analyze-expression
           `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init)
           env context location)))))

;;; ===================================================================
;;; P1 — store-fragment analyzer.
;;;
;;; (store-fragment FRAG DEST (TY TX)) writes a 16x8 fp32 accumulator fragment to the
;;; DEST matrix at logical tile (TY TX).  Like make-register-fragment, it REWRITES to
;;; existing forms (warp-lane / arithmetic / matrix element set / %extract-struct-member)
;;; — no new codegen.
;;;
;;; The real m16n8 fp32 accumulator layout: with lane in 0..31,
;;;   g = lane/4 (group), t = lane%4 (thread-in-group), the lane's 4 registers land at
;;;   (g, 2t) (g, 2t+1) (g+8, 2t) (g+8, 2t+1)  — a 16x8 tile — offset by the tile
;;;   origin (TY*16, TX*8).  (A uniform fragment makes P1's 01 pass regardless of this
;;;   mapping; the real layout is here so P2's non-uniform load->store validates it.)
;;; ===================================================================



(defun %coop-layout-of (tensor-node)
  "The coop load/store MemoryLayout for an operand, derived from its tensor type's
   :contiguous-term (NOT hardcoded): :last (row-major) -> 0 (RowMajor); :first (col-major)
   -> 1 (ColMajor).  So the layout matches how the matrix is actually stored — the stride
   in %coop-tensor-ptr+stride follows (s0 for RowMajor, s1 for ColMajor).  NOTE: Intel has
   no ColumnMajor-B coop builtin, so an Intel B operand must be declared :row-major."
  (if (eq (%get-tensor-ct (canonicalize-type-specifier (get-single-value-type tensor-node)))
          :first)
      1 0))

(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes."
  (destructuring-bind (frag dest tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; C(accumulator) = MxN; layout from the dest tensor's :contiguous-term.
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sk))
            (let ((dnode (analyze-expression dest env context (append location '(2)))))
              (make-semantic-coop-op
               :type 'void :kind :store
               :value-node  (analyze-expression frag env context (append location '(1)))
               :tensor-node dnode
               :rows sm :cols sn :use 2 :layout (%coop-layout-of dnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(3)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(4)))
               :source-location location)))
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

;;; ===================================================================
;;; P2 — load-fragment-a / load-fragment-b analyzers.
;;;
;;; (load-fragment-a SRC (TY TK)) / (load-fragment-b SRC (TK TX)) read this lane's
;;; tf32 A / B fragment elements from SRC (global or SLM — the layout is the same) at
;;; the m16n8k8 operand layout, and construct the A / B fragment record.  Rewrites to
;;; per-lane matrix reads (ldmatrix is a later perf optimization).
;;;
;;; m16n8k8 tf32 operand layouts (g = lane/4, tg = lane%4):
;;;   A (16x8, row): a0=(g,tg) a1=(g+8,tg) a2=(g,tg+4) a3=(g+8,tg+4)
;;;   B (8x8, col):  b0=(tg,g) b1=(tg+4,g)
;;; ===================================================================



(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; A = MxK; layout from the tensor's :contiguous-term.
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sn))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float sm sk 0) :kind :load
               :tensor-node tnode
               :rows sm :cols sk :use 0 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tk) env context (append location '(3)))
               :source-location location)))
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
          ;; B = KxN; layout from the tensor's :contiguous-term.  NOTE: Intel has no
          ;; ColumnMajor-B coop builtin, so an Intel B operand must be declared :row-major
          ;; (NVIDIA's canonical row.col MMA wants B :col-major — a genuine per-vendor
          ;; storage difference, like the shape).
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sm))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float sk sn 1) :kind :load
               :tensor-node tnode
               :rows sk :cols sn :use 1 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,tk) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          (analyze-expression
           `(let ((lane (to-int (warp-lane))))
              (let ((g (/ lane 4)) (tg (rem lane 4)))
                (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                  (%construct-struct register-fragment-b-tf32-8x8
                    (~ ,src r c) (~ ,src (+ r 4) c)))))
           env context location)))))

;;; ===================================================================
;;; P2 — mma-accumulate: the one GENUINE-codegen piece.
;;;
;;; (mma-accumulate C-FRAG A-FRAG B-FRAG) -> new accumulator = A*B + C via a single
;;; tf32 m16n8k8 MMA, lowering to @llvm.nvvm.mma.m16n8k8.row.col.tf32.
;;;
;;; The intrinsic signature: {f32,f32,f32,f32} (i32,i32,i32,i32,  i32,i32,  f32,f32,f32,f32)
;;;   A operands (4) and B operands (2) are tf32 values passed as i32 (bit-reinterpret
;;;   of the fp32 storage); C operands (4) and the {..} result are f32.
;;; ===================================================================

;; (defstruct semantic-mma-accumulate ...) lives in src/semantic.lisp so it is defined
;; before analysis/core.lisp references it in the node-dispatch etypecases.



(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop
   matrix on :spirv, else the fp32 record.  Codegen forks in the generate-node-ir below."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (make-semantic-mma-accumulate
     :type (if (eq *target-backend* :spirv)
               (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                 (declare (ignore sk)) (list 'coop-matrix 'float sm sn 2))
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


(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, 0) -> the MxN accumulator coop matrix."
  (let* ((a-ty (%coop-type elem-llvm m k 0))
         (b-ty (%coop-type elem-llvm k n 1))
         (c-ty (%coop-type elem-llvm m n 2))
         (i32  (crisp.llvm-bindings::llvm-int32-type)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))


(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type; swizzle/k from table)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (progn
            ;; Endeavor 140 (precision): wgmma is tf32 by construction, so under a non-fast
            ;; precision context the requested IEEE accuracy is silently NOT honored (results are
            ;; tf32).  Warn.  *math-precision* here is the resolved effective precision at codegen
            ;; — it already respects the full chain (force > with-precision > declaim > flag >
            ;; default(:ieee)), the same value that stamps the fast-math flags in codegen.lisp.
            (unless (eq *math-precision* :fast)
              (format *error-output*
                      "WARNING: wgmma-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                      *math-precision*))
          (destructuring-bind (&optional swizzle-mode (k 8)) (gethash node *wgmma-node-swizzle*)
            (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                  (swizzle-p (and swizzle-mode (string-equal (string swizzle-mode) "128B"))))
              (multiple-value-bind (av al a-ptr) (gen (semantic-mma-accumulate-a-node node))
                (declare (ignore av al))
                (multiple-value-bind (bv bl b-ptr) (gen (semantic-mma-accumulate-b-node node))
                  (declare (ignore bv bl))
                  (unless (and a-ptr b-ptr)
                    (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                  (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                    (second (gethash acc-type *wgmma-acc-dims*)) swizzle-p k))))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;;; ===================================================================
;;; P3a — make-register-tile (record-of-fragments) + store-tile overload.
;;;
;;; A register-tile is a workgroup-collective MxN accumulator: a record whose fields
;;; are (M/16)x(N/8) accumulator fragments (register-fragment-acc-f32-16x8), row-major
;;; (fragment idx = mi*(N/8) + nj).  Single-warp for now (one warp holds all fragments).
;;; Minted on demand per (M N).
;;; ===================================================================

(defvar *register-tile-dims* (make-hash-table :test 'eq)
  "Maps a minted register-tile type symbol -> (list M N); used by store-tile's walk.")

(defun %register-tile-type-name (m n)
  (intern (format nil "REGISTER-TILE-ACC-F32-~dX~d" m n) (find-package :crisp.compiler)))

(defun %register-tile-type-p (type-name)
  "T if TYPE-NAME is a minted register-tile type."
  (and (symbolp type-name) (nth-value 1 (gethash type-name *register-tile-dims*))))

(defun %ensure-register-tile-type (m n)
  "Mint (once) the register-tile-acc-f32-MxN record — (M/16)x(N/8) fragment fields —
   and record its dims.  Returns the type symbol."
  (unless (and (zerop (mod m 16)) (zerop (mod n 8)))
    (error "make-register-tile: dims (~a ~a) must be multiples of the 16x8 accumulator fragment." m n))
  (let ((name (%register-tile-type-name m n)))
    (unless (gethash name *crisp-structs*)
      (let ((nfrags (* (floor m 16) (floor n 8))))
        (register-struct-definition
         name
         (loop for i below nfrags
               collect (list (intern (format nil "F~d" i) (find-package :crisp.compiler))
                             'register-fragment-acc-f32-16x8))
         :record)))
    (setf (gethash name *register-tile-dims*) (list m n))
    name))

(defun %normalize-warp-mask (mask location)
  "Endeavor 139 (decision A): normalize a :warps topology mask to a list of booleans (t/nil).
   Elements are true/false or 1/0 (Crisp's bool-is-int).  Any other element errors."
  (unless (and (listp mask) mask)
    (error 'crisp-compiler-error
      :message (format nil "make-register-tile: :warps must be a non-empty list, got ~S" mask)
      :source-location location))
  (mapcar (lambda (e)
            (cond ((eql e 1) t)
                  ((eql e 0) nil)
                  ((null e) nil)
                  ((and (symbolp e) (string-equal (symbol-name e) "TRUE"))  t)
                  ((and (symbolp e) (string-equal (symbol-name e) "FALSE")) nil)
                  (t (error 'crisp-compiler-error
                       :message (format nil "make-register-tile: :warps element must be true/false or 1/0, got ~S" e)
                       :source-location location))))
          mask))

(defun %resolve-workgroup-warp-count (context)
  "The workgroup's warp count = local-size / warp-size, or NIL if local-size is not statically
   known.  warp-size is the active profile's :simd-width, else 32."
  (let* ((fn      (and context (compiler-context-current-compiling-function context)))
         (disp    (and fn (gethash fn *kernel-dispatch-declarations*)))
         (ls-decl (getf disp :local-size))
         (dims    (and ls-decl (%hp-local-size-dims ls-decl))))
    (when dims
      (let* ((total     (reduce #'* dims))
             (profile   (active-hardware-profile))
             (warp-size (or (and profile (getf profile :simd-width)) 32)))
        (max 1 (floor total warp-size))))))

(defun %warp-mask-unquote (v)
  "The :warps value is a quoted literal — '(false true) reads as (quote (false true)).  Unwrap."
  (if (and (consp v) (symbolp (car v)) (string-equal (symbol-name (car v)) "QUOTE"))
      (cadr v)
      v))

(defun %warp-mask-contiguous-true-p (mask)
  "T if the TRUE entries of MASK form a single contiguous run — the only layout the fragment
   distribution supports today (warp_position = warp_id - first_true)."
  (let ((f (position t mask)) (l (position t mask :from-end t)))
    (and f (loop for i from f to l always (nth i mask)))))

(defun %validate-warp-mask (mask nfrags n-warps m n location)
  "Endeavor 139 (decision A): validate a normalized :warps mask.  Returns (values n-true first-true).
   Checks: length == n-warps (when statically known); >= 1 true; contiguous true run; n-true evenly
   divides nfrags."
  (let ((n-true (count t mask)) (first-true (position t mask)))
    (when (and n-warps (/= (length mask) n-warps))
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile :warps has ~a entries but the workgroup has ~a warp~:p (local-size / warp-size).  The mask must name every warp."
                         (length mask) n-warps)
        :source-location location))
    (when (zerop n-true)
      (error 'crisp-compiler-error
        :message "make-register-tile :warps must mark at least one warp true (some warp must hold the tile)."
        :source-location location))
    (unless (%warp-mask-contiguous-true-p mask)
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile :warps: the participating (true) warps must be contiguous, got ~S.  A non-contiguous participation mask is not yet supported." mask)
        :source-location location))
    (unless (zerop (mod nfrags n-true))
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile: a ~ax~a tile is ~a (16x8) fragments, which ~a participating warps do not evenly divide.  Use a warp count that divides ~a (1/2/4/...)."
                         m n nfrags n-true nfrags)
        :source-location location))
    (values n-true first-true)))

(defun analyze-make-register-tile (expr env context location)
  "P3a: (make-register-tile T (M N) INIT &key warps) -> a record-of-fragments accumulator tile,
   each fragment initialized to INIT.  Mints the tile type on demand; rewrites to
   %construct-struct of make-register-fragment fields.
   Endeavor 139 (decision A): :warps is a flat topology mask of which warps hold the tile.  For a
   single participating warp (or no mask) the tile is the full (M/16)x(N/8) fragment set on that
   warp — the current build.  Distributing across >= 2 participating warps (the occupancy lever)
   is sub-step 2."
  (let* ((args     (cdr expr))
         (elem     (first args))
         (dims     (second args))
         (init     (third args))
         (kwargs   (nthcdr 3 args))
         (warps-in (getf kwargs :warps)))
    (declare (ignore elem))          ; tf32/fp32 fixed for now
    (destructuring-bind (m n) dims
      (let* ((tile-name (%ensure-register-tile-type m n))
             (nfrags    (* (floor m 16) (floor n 8))))
        (when warps-in
          ;; This (%construct-struct, non-exploded) path is only reached for a make-register-tile
          ;; NOT bound in a let — a let binding is EXPLODED, and %explode-register-tiles does the
          ;; distribution.  Validate here; distribution needs the explosion, so >=2 warps errors.
          (let* ((mask   (%normalize-warp-mask (%warp-mask-unquote warps-in) location))
                 (n-true (%validate-warp-mask mask nfrags (%resolve-workgroup-warp-count context) m n location)))
            (when (> n-true 1)
              (error 'crisp-compiler-error
                :message "make-register-tile with :warps distributing across >= 2 warps must be a let binding (so the compiler can split the fragments)."
                :source-location location))))
        (analyze-expression
         `(%construct-struct ,tile-name
                             ,@(loop repeat nfrags collect `(make-register-fragment 16 8 ,init)))
         env context location)))))

(defun analyze-store-tile-mma (expr env context location)
  "store-tile overload: register-tile (mma.sync) OR wgmma-accumulator (Endeavor 140) OR delegate."
  (let* ((src-node (analyze-expression (second expr) env context (append location '(1))))
         (src-type (semantic-node-type src-node)))
    (cond
      ((%wgmma-acc-type-p src-type)
       (let ((n (second (gethash src-type *wgmma-acc-dims*))))
         (analyze-expression (%wgmma-store-rewrite (second expr) (third expr) (fourth expr) n)
                             env context location)))
      ((%register-tile-type-p src-type)
       (destructuring-bind (m n) (gethash src-type *register-tile-dims*)
         (let* ((tile    (second expr))
                (dest    (third expr))
                (tile-id (fourth expr))
                (to-int-sym (intern "TO-INT" (find-package :crisp-language)))
                (bty (list to-int-sym (first tile-id)))
                (btx (list to-int-sym (second tile-id)))
                (m-frags (floor m 16)) (n-frags (floor n 8)))
           (analyze-expression
            `(let ((tv ,tile))
               (progn
                 ,@(loop for mi below m-frags
                         append (loop for nj below n-frags
                                      for idx = (+ (* mi n-frags) nj)
                                      collect `(store-fragment (%extract-struct-member tv ,idx)
                                                               ,dest
                                                               ((+ (* ,bty ,m-frags) ,mi)
                                                                (+ (* ,btx ,n-frags) ,nj)))))))
            env context location))))
      (t
       (analyze-store-tile-expression expr env context location)))))

;;; ===================================================================
;;; P3b — mma-accumulate-via-tile (bodyless): walk the register C-tile in MMA
;;; fragments, accumulate one K-step, set! the tile back.  Composes P2/P3a
;;; primitives (load-fragment-a/b, mma-accumulate, the tile record) — a rewrite.
;;; ===================================================================



(defun %check-mma-shape (mma-shape location)
  "Validate the (M N K) MMA shape: an int triple, and — if a hardware profile is active —
   a member of its :mma-shapes (the vendor's supported shape, e.g. Intel (8 16 8)); with
   NO profile, require the tf32 NVIDIA default (16 8 8)."
  (unless (and (listp mma-shape) (= (length mma-shape) 3) (every #'integerp mma-shape))
    (error 'crisp-compiler-error
           :message (format nil "mma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." mma-shape)
           :source-location location))
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if shapes
        (unless (member mma-shape shapes :test #'equal)
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: shape ~a is not one of the active hardware profile's :mma-shapes ~a."
                                  mma-shape shapes)
                 :source-location location))
        (unless (equal mma-shape '(16 8 8))
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: only tf32 (16 8 8) is supported without a hardware profile, got ~a." mma-shape)
                 :source-location location)))))

(defun analyze-mma-accumulate-via-tile (expr env context location)
  "P3b-1: (mma-accumulate-via-tile (M N K) C-TILE A B) — walk the register C-tile in
   16x8 fragments and accumulate ONE K-step (K = the shape's K) into each, set!-ing the
   accumulated tile back.  Bodyless (no accum-op / epilogue yet)."
  (destructuring-bind (mma-shape c-tile a b) (cdr expr)
    (%check-mma-shape mma-shape location)
    (let* ((c-node (analyze-expression c-tile env context (append location '(1))))
           (c-type (semantic-node-type c-node)))
      (unless (%register-tile-type-p c-type)
        (error 'crisp-compiler-error
               :message (format nil "mma-accumulate-via-tile: C-tile (2nd arg) must be a register-tile, got type ~a." c-type)
               :source-location location))
      (destructuring-bind (tm tn) (gethash c-type *register-tile-dims*)
        (let ((m-frags (floor tm 16)) (n-frags (floor tn 8)))
          (analyze-expression
           `(set! ,c-tile
              (let ((cv ,c-tile))
                (%construct-struct ,c-type
                  ,@(loop for mi below m-frags
                          append (loop for nj below n-frags
                                       for idx = (+ (* mi n-frags) nj)
                                       collect `(mma-accumulate
                                                 (%extract-struct-member cv ,idx)
                                                 (load-fragment-a ,a (,mi 0))
                                                 (load-fragment-b ,b (0 ,nj))))))))
           env context location))))))

;;; ===================================================================
;;; P4 — matmul helpers.  inner-dimension = the matmul contraction extent K.
;;; ===================================================================


(defun %head-name-eq (head name)
  "T if HEAD is a symbol whose name is NAME (package-insensitive)."
  (and (symbolp head) (string-equal (symbol-name head) name)))

(defun %register-tile-init-form-p (form)
  "T if FORM is a (make-register-tile T (M N) INIT &key warps) constructor."
  (and (consp form) (>= (length form) 4) (%head-name-eq (first form) "MAKE-REGISTER-TILE")
       (listp (third form)) (= (length (third form)) 2)
       (or (= (length form) 4)
           (and (>= (length form) 6) (keywordp (fifth form))))))



(defun %frag-mn ()
  "Per-fragment (M . N) for register-tile decomposition: the active profile's mma-shape
   (M N) on :spirv, else NVIDIA 16x8."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (m n k) (%spv-mma-shape) (declare (ignore k)) (cons m n))
      (cons 16 8)))

(defun %register-tile-frag-syms (var count)
  "COUNT per-fragment variable symbols for tile VAR, interned in VAR's package with a `$F<i>`
   suffix.  Endeavor 139: COUNT is the PER-WARP fragment count (= nfrags / #participating-warps),
   so a warp-distributed tile allocates only its share (the register drop that raises occupancy)."
  (loop for i below count
        collect (intern (format nil "~a$F~d" (symbol-name var) i) (symbol-package var))))


(defparameter *default-max-registers-per-thread* 255
  "Fallback per-thread register budget for the register-tile fit-check when no
   hardware profile pins :max-registers-per-thread.  255 = NVIDIA architectural max.")



(defun %register-tile-fit-check (m n location)
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile
   is opaque cooperative matrices (the driver owns register residency), so SKIP.  Else:
   (M/16)x(N/8) accumulator fragments x 4 fp32 regs <= :max-registers-per-thread."
  (unless (eq *target-backend* :spirv)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (profile       (active-hardware-profile))
           (budget        (or (and profile (getf profile :max-registers-per-thread))
                              *default-max-registers-per-thread*)))
      (when (> total-regs budget)
        (error 'crisp-compiler-error
               :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                m n total-regs nfrags regs-per-frag budget)
               :source-location location)))))

(defun %subst-accum (form binding-sym frag-var acc-set)
  "F3: substitute a mma-accumulate-via-tile body per fragment — the accum-binding symbol
   BINDING-SYM -> FRAG-VAR, and any (accum-op …) call -> ACC-SET (that fragment's
   accumulate set!).  Walks FORM structurally (cons-cell recursion, so dotted/improper
   tails are preserved)."
  (cond
    ((symbolp form) (if (eq form binding-sym) frag-var form))
    ((consp form)
     (if (%head-name-eq (first form) "ACCUM-OP")
         acc-set
         (cons (%subst-accum (car form) binding-sym frag-var acc-set)
               (%subst-accum (cdr form) binding-sym frag-var acc-set))))
    (t form)))





(defun %emit-frag-loop-distributed (syms n-frags first-true n-true per-frag-fn)
  "Endeavor 139 step-4 perf: emit a COMPILE-TIME-STATIC per-warp switch (was a runtime
   fragment-index loop).  wp = warp-position is runtime, so branch on it once via a `<`-cascade
   (the role-branch pattern, last warp = bare else since wp is gated into [0,n-true)); inside each
   arm the fragment (mi nj) fold to integer LITERALS so the SMEM operand loads get static addresses
   and ptxas can CSE them.  PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS (same
   contract as the n-true=1 static path)."
  (let* ((cl        (find-package :crisp-language))
         (progn-sym (intern "PROGN" cl))  (let-sym (intern "LET" cl))
         (if-sym    (intern "IF" cl))     (lt-sym  (intern "<" cl))
         (minus-sym (intern "-" cl))      (to-int-sym (intern "TO-INT" cl))
         (warp-id-sym (intern "WARP-ID" cl))
         (per-warp  (length syms))
         (wp        (gensym "WP")))
    (labels ((arm (k)
               `(,progn-sym
                  ,@(loop for l below per-warp
                          for fv = (nth l syms)
                          for logical = (+ (* k per-warp) l)
                          for mi = (floor logical n-frags)
                          for nj = (mod logical n-frags)
                          append (funcall per-frag-fn fv mi nj))))
             (chain (k)
               (if (>= k (1- n-true))
                   (arm k)                                   ; last warp = bare else
                   `(,if-sym (,lt-sym ,wp ,(1+ k))
                             ,(arm k)
                             ,(chain (1+ k))))))
      `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id-sym)) ,first-true)))
         ,(chain 0)))))

(defun %emit-per-frag-accumulate (a b entry &optional accum-binding body)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is now
   a static per-warp switch (n-true threaded to %emit-frag-loop-distributed)."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0)) (cdr entry)
    (destructuring-bind (fm . fn) (%frag-mn)
      (let ((m-frags (floor m fm)) (n-frags (floor n fn)))
        (flet ((one-frag (fv mi-form nj-form)
                 (let ((acc-set `(set! ,fv (mma-accumulate ,fv
                                                           (load-fragment-a ,a (,mi-form 0))
                                                           (load-fragment-b ,b (0 ,nj-form))))))
                   (if body
                       (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                       (list acc-set)))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).  Endeavor 139 step-4: distributed path
   is now a static per-warp switch."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0)) (cdr entry)
    (destructuring-bind (fm . fn) (%frag-mn)
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(store-fragment ,fv ,dest
                                        ((+ (* ,bty ,m-frags) ,mi-form)
                                         (+ (* ,btx ,n-frags) ,nj-form))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

                                                   #|

(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile references to
   any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;
   otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       ;; Still enforce the shape check the analyzer would have run — the explosion
       ;; pre-empts analyze-mma-accumulate-via-tile, so validate here too.
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           ;; F3 body form: (via-tile shape v a b (binding) body…)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) binding-sym body))
           ;; bodyless (implicit single accum-op)
           (%emit-per-frag-accumulate a b (assoc v tiles)))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))
    |#


;; ======================================================================
;; Endeavor 135 — fill-tile  (aka clear-tile: fill T's every element with V)
;;
;; src/analysis/control.lisp (scratch analyzer) + src/mma.lisp (register-tile case in
;; %explode-rewrite-body-form + register in register-control-analyzers / the mma wrapper)
;;
;;   (fill-tile <tile> <value>)   ; value must match the tile's element type
;;
;; Two paths, dispatched like store-tile:
;;   - Register tile (record-of-fragments, SROA-exploded): reset each fragment to a
;;     fragment-of-VALUE.  Handled in the explosion (%explode-rewrite-body-form), before
;;     the whole-tile variable is gone.  Register fragments are f32 → VALUE must be float.
;;   - Scratch/SLM tile (real tensor): a workgroup-collective write of every element.
;;     NO barrier is inserted — the caller syncs before reading.

(defun %emit-per-frag-fill (entry val)
  "Per-fragment expansion of (fill-tile V VAL) for a register tile: reset every fragment
   of V to a fragment-of-VAL (matching make-register-tile's own 16x8 fragment init)."
  (destructuring-bind (m n syms &optional n-true first-true) (cdr entry)
    (declare (ignore m n n-true first-true))
    ;; fill just resets every fragment this warp holds — no logical index needed.
    `(progn
       ,@(loop for s in syms
               collect `(set! ,s (make-register-fragment 16 8 ,val))))))


(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile references to
   any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;
   otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles)))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))

(defun %explode-register-tiles (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range)."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (let* ((form    (second b))
                                 (dims    (third form))
                                 (init    (fourth form))
                                 (m       (first dims)) (n (second dims))
                                 ;; nfrags MUST use the target's per-fragment dims (%frag-mn):
                                 ;; NVIDIA 16x8, Intel BMG 8x16 — the emit functions use the same,
                                 ;; so the syms count and the emit loop must agree (hardcoding 16x8
                                 ;; here broke BMG: nth returned NIL -> "Unknown variable NIL").
                                 (nfrags  (destructuring-bind (fm . fn) (%frag-mn)
                                            (* (floor m fm) (floor n fn))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location)
                                    (values 1 0))
                              (let* ((per-warp (floor nfrags n-true))
                                     (syms     (%register-tile-frag-syms (first b) per-warp)))
                                (push (list (first b) m n syms n-true first-true) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init))))))
                          (list b)))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) body)))))))


(defun analyze-inner-dimension (expr env context location)
  "(inner-dimension A B) -> the contraction extent K (A is M×K row-major, so K is A's
   inner/column extent = extents[1]).  Rewrites to (~ (extents~ A) 1)."
  (destructuring-bind (a b) (cdr expr)
    (declare (ignore b))
    (let* ((cl (find-package :crisp-language))
           (tilde   (intern "~" cl))
           (extents (intern "EXTENTS~" cl)))
      (analyze-expression (list tilde (list extents a) 1) env context location))))


(defun analyze-outer-dimensions-expression (expr env context location)
  "(outer-dimensions A B) => M N.  M = A's outer/row extent (~ (extents~ A) 0);
   N = B's outer/col extent (~ (extents~ B) 1).  Produces a semantic-values 2-value node."
  (destructuring-bind (a b) (cdr expr)
    (let* ((cl      (find-package :crisp-language))
           (tilde   (intern "~" cl))
           (extents (intern "EXTENTS~" cl))
           (m-node  (analyze-expression (list tilde (list extents a) 0) env context
                                        (append location '(1))))
           (n-node  (analyze-expression (list tilde (list extents b) 1) env context
                                        (append location '(2)))))
      (make-semantic-values
       :type (list (get-single-value-type m-node) (get-single-value-type n-node))
       :value-nodes (list m-node n-node)
       :source-location location))))


;; ======================================================================
;; Endeavor 135 — matrix-multiply-tile-stride register-tile pre-lowering.
;;
;; A register-tile C-tile is a record-of-fragments the SROA explosion (%explode-register-tiles)
;; turns into C-tile$Fi + rewrites the store-tile/mma forms that name it.  So a register-tile
;; matmul must be lowered to those forms BEFORE the explosion, and its outer tile-spec must be a
;; compile-time (M N) size-list (a register tile has no extents~ for tile-stride to read).
;; %mmts-parse / %mmts-lower live in src/analysis/control.lisp (loaded first); the scratch path
;; goes through analyze-matrix-multiply-tile-stride-expression there.
(defun %mmts-head-p (form)
  "T if FORM is a matrix-multiply-tile-stride call."
  (and (consp form) (symbolp (car form))
       (string-equal (symbol-name (car form)) "MATRIX-MULTIPLY-TILE-STRIDE")))

(defun %mmts-register-dims-map (bindings)
  "Alist var -> (M N) for each register-tile binding in a let's BINDINGS."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          collect (cons (first b) (third (second b)))))   ; (make-register-tile elem (M N) init)

(defun %expand-mmts-register-in-form (form reg-map location)
  "Rewrite matrix-multiply-tile-stride forms whose C-tile is a register tile (in REG-MAP)
   to their tile-stride + auto-store lowering with a compile-time (M N) size-list tile-spec,
   so the generated store-tile/mma are visible to the register-tile SROA explosion."
  (cond
    ((not (consp form)) form)
    ((and (%mmts-head-p form) (assoc (third form) reg-map))
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form location)
       (%mmts-lower c-form c-tile (cdr (assoc c-tile reg-map)) k-form k-step gy gx gk
                    (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) body)
                    location)))
    (t (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) form))))

(defun %expand-matmul-tile-stride-register-forms (let-expr location)
  "If LET-EXPR binds register tiles, pre-lower the matrix-multiply-tile-stride forms in its
   body that target them (endeavor 135).  No-op when no register tile is bound."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let ((reg-map (%mmts-register-dims-map (second let-expr))))
        (if (null reg-map)
            let-expr
            `(,(first let-expr) ,(second let-expr)
              ,@(mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location))
                        (cddr let-expr)))))))

(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: pre-lower register-tile matrix-multiply-tile-stride (endeavor 135),
   then explode register-tile bindings into per-fragment mutable variables (register residency,
   Endeavor 132), then defer to the normal let analysis."
  (analyze-let-expression
   (%explode-register-tiles
    (%expand-matmul-tile-stride-register-forms expr location)
    location context)
   env context location))




(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.  Overlay (Endeavor 140): adds the wgmma forms."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         ;; Endeavor 140 (Chapter 4) -- wgmma forms
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))


;;; ===========================================================================
;;; Endeavor 140 (Chapter 4) — wgmma (Hopper warpgroup async MMA) support.
;;; Folded from overlays/crisp-compiler-overlay.lisp (2026-07-21).
;;; ===========================================================================

(defvar *wgmma-acc-dims* (make-hash-table :test 'eq)
  "wgmma accumulator type symbol -> (list M N K).")

(defun %wgmma-acc-type-name (n)
  (intern (format nil "WGMMA-ACC-F32-64X~d" n) (find-package :crisp.compiler)))

(defun %wgmma-acc-type-p (type-name)
  "T if TYPE-NAME is a minted wgmma accumulator record type."
  (and (symbolp type-name) (nth-value 1 (gethash type-name *wgmma-acc-dims*))))

(defun %ensure-wgmma-acc-type (n)
  "Mint (once) the WGMMA-ACC-F32-64xN record -- N/2 flat f32 fields (the wgmma D accumulator, N/2
   f32 registers per thread across the 128-thread warpgroup).  Returns the type symbol."
  (let ((name (%wgmma-acc-type-name n)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below (floor n 2)
             collect (list (intern (format nil "D~d" i) (find-package :crisp.compiler)) 'float))
       :record))
    (setf (gethash name *wgmma-acc-dims*) (list 64 n 8))
    name))

(defun %check-wgmma-shape (shape location &optional swizzle)
  "Validate a wgmma (M N K) shape.  M fixed 64; N a multiple of 8 in [8,256].  K: with :swizzle a
   positive multiple of 8 (the K-block = K/8 k8 slices); without :swizzle exactly 8 (a single k8 wgmma)."
  (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
    (error 'crisp-compiler-error
           :message (format nil "wgmma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." shape)
           :source-location location))
  (destructuring-bind (m n k) shape
    (unless (= m 64)
      (error 'crisp-compiler-error :message (format nil "wgmma: M must be 64 (wgmma is always m64), got ~a." m)
             :source-location location))
    (unless (and (>= n 8) (<= n 256) (zerop (mod n 8)))
      (error 'crisp-compiler-error :message (format nil "wgmma: N must be a multiple of 8 in [8,256], got ~a." n)
             :source-location location))
    (if swizzle
        (unless (and (plusp k) (zerop (mod k 8)))
          (error 'crisp-compiler-error
                 :message (format nil "wgmma: with :swizzle, K (the K-block) must be a positive multiple of 8, got ~a." k)
                 :source-location location))
        (unless (= k 8)
          (error 'crisp-compiler-error
                 :message (format nil "wgmma: K must be 8 (tf32 m64nNk8, a single k8 slice); use :swizzle :128b for a multi-k8 K-block, got ~a." k)
                 :source-location location)))))

(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (let ((type-name (%ensure-wgmma-acc-type n)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))

(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K]).  a/b -> (~ tile 0 [0]) with one 0 per tile dimension
   (rank-aware) so codegen's 3rd value is the addrspace(3) base — works for flat VECTOR tiles (scatter)
   AND MATRIX tiles (swizzle / Step-0 forms), independent of :swizzle."
  (destructuring-bind (d a b &rest kwargs) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node))
           (swz    (getf kwargs :swizzle))
           (a-rank (or (%get-tensor-arity
                        (semantic-node-type (analyze-expression a env context (append location '(2))))) 1))
           (b-rank (or (%get-tensor-arity
                        (semantic-node-type (analyze-expression b env context (append location '(3))))) 1))
           (aref-a (if (>= a-rank 2) `(~ ,a 0 0) `(~ ,a 0)))
           (aref-b (if (>= b-rank 2) `(~ ,b 0 0) `(~ ,b 0))))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (let ((node (make-semantic-mma-accumulate
                   :type d-type
                   :c-node d-node
                   :a-node (analyze-expression aref-a env context (append location '(2)))
                   :b-node (analyze-expression aref-b env context (append location '(3)))
                   :source-location location)))
        (setf (gethash node *wgmma-node-swizzle*) (list swz (or (getf kwargs :k) 8)))
        node))))

(defun analyze-wgmma-accumulate-via-tile (expr env context location)
  "(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b]) -> (set! D (wgmma-accumulate D A B
   :swizzle MODE :k K)).  K rule is swizzle-aware (see %check-wgmma-shape)."
  (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
    (%check-wgmma-shape shape location (getf kwargs :swizzle))
    (analyze-expression `(set! ,d (wgmma-accumulate ,d ,a ,b :swizzle ,(getf kwargs :swizzle) :k ,(third shape)))
                        env context location)))

(defun %wgmma-make-desc (builder base-ptr &optional swizzle-p (kslice-byte-off 0))
  "Build the 64-bit wgmma SMEM matrix descriptor.  NO-SWIZZLE (Step 1, scatter/core-matrix): LBO=128B
   (enc 8), SBO=256B (enc 16), swizzle=0.  128B-SWIZZLE (Step 3, TMA, CUTLASS make_gmma_desc<K>):
   LBO=16B (enc 1), SBO=1024B (enc 64), swizzle bits=1, base_offset=0; the k-slice ADVANCES the start
   address by KSLICE-BYTE-OFF (kk*32).  start = ((addr+off)>>4)&0x3FFF at [0:13]."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (if swizzle-p
                        (logior (ash 1 16) (ash 64 32) (ash 1 62))    ; LBO=16,SBO=1024,swz=128B,base=0
                        (logior (ash 8 16) (ash 16 32))))             ; LBO=128,SBO=256,swz=0
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "wg_addr"))
         (addr  (if (zerop kslice-byte-off) addr0
                    (llvm-build-add builder addr0 (llvm-const-int i32 kslice-byte-off nil) "wg_addr_k")))
         (sh    (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "wg_sh"))
         (msk   (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "wg_start"))
         (st64  (llvm-build-zext builder msk i64 "wg_start64")))
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "wg_desc")))

(defun %wgmma-struct-of-floats (module nacc)
  "The LLVM struct type { float x NACC } — the wgmma inline-asm result (NACC = N/2 accumulators)."
  (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count nacc)))
    (dotimes (i nacc) (setf (cffi:mem-aref elts 'llvm-type-ref i) (llvm-float-type)))
    (llvm-struct-type-in-context (llvm-get-module-context module) elts nacc nil)))

(defun %wgmma-asm-string (nacc n)
  "wgmma.mma_async.sync.aligned.m64nNk8.f32.tf32.tf32 {$0..$nacc-1}, descA, descB, 1,1,1;
   NB on operand numbering: LLVM IR inline-asm has no '+f'; a read-write accumulator is an '=f'
   OUTPUT ($0..$nacc-1) PLUS a matching tied INPUT ($nacc..$2*nacc-1).  The tied inputs DO occupy
   operand slots, so the two 'l' descriptors are $2*nacc and $2*nacc+1 (not $nacc/$nacc+1)."
  (let ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i))))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk8.f32.tf32.tf32 {~a}, $~d, $~d, 1, 1, 1;"
            n accs (* 2 nacc) (1+ (* 2 nacc)))))

(defun %wgmma-constraints (nacc)
  "NACC '=f' outputs, NACC tied inputs (0..nacc-1), 2 'l' descriptor inputs, memory clobber."
  (let ((outs (loop for i below nacc collect "=f"))
        (ties (loop for i below nacc collect (format nil "~d" i))))
    (format nil "~{~a~^,~},~{~a~^,~},l,l,~~{memory}" outs ties)))

(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n &optional swizzle-p (k 8))
  "Emit the wgmma accumulate.  NO-SWIZZLE (scatter): a proxy fence + barrier (generic->async proxy
   visibility) + ONE k8 wgmma.  128B-SWIZZLE (TMA): NO proxy fence (both async proxy) + K/8 k-slice
   wgmmas, D accumulating across them (scaleD=1), each with the start advanced kk*32 bytes.
   Returns (values D nil)."
  (let ((n-slices (if swizzle-p (max 1 (floor k 8)) 1)))
    (unless swizzle-p
      ;; scatter path: generic st.shared writes must be made visible to wgmma's async-proxy read.
      (%gen-nvvm-fence-proxy-async-shared builder)
      (%ptx-barrier builder module))
    (let ((cur-d d-val))
      (dotimes (kk n-slices)
        (setf cur-d (%emit-one-wgmma builder module cur-d a-ptr b-ptr acc-type n swizzle-p (* kk 32))))
      (values cur-d nil))))

(defun %wgmma-store-rewrite (tile dest tile-id n)
  "Store the m64xN wgmma accumulator TILE to DEST at grid tile-id (BTY BTX).  warp w (within the
   warpgroup) -> rows [16w,16w+16); per n8 group the standard mma m16n8 C fragment.  (= wgmma_ref.cu.)"
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (n8 (floor n 8))
         (bty `(,to-int ,(first tile-id)))
         (btx `(,to-int ,(second tile-id))))
    `(let ((wgv ,tile))
       (let ((wgw (rem (,to-int (warp-id)) 4))
             (lane (,to-int (warp-lane))))
         (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
           (let ((r0 (+ (+ (* ,bty 64) (* wgw 16)) rlo)))
             (let ((r8 (+ r0 8))
                   (c0 (+ (* ,btx ,n) col)))
               (progn
                 ,@(loop for j below n8
                         for base = (* j 4)
                         append (list
                                 `(set! (~ ,dest r0 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 0)))
                                 `(set! (~ ,dest r0 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 1)))
                                 `(set! (~ ,dest r8 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 2)))
                                 `(set! (~ ,dest r8 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 3)))))))))))))

(defvar *wgmma-node-swizzle* (make-hash-table :test 'eq)
  "semantic-mma-accumulate node -> (list swizzle-mode k-block) for the wgmma path.")

(defun %emit-one-wgmma (builder module d-val a-ptr b-ptr acc-type n swizzle-p kslice-off)
  "One m64nNk8 wgmma: fence + mma_async (N/2 accumulators in/out + 2 descs) + commit + wait; return
   the new D record.  The k-slice offset (kk*32 bytes) advances the swizzle descriptor start address."
  (let* ((f32 (llvm-float-type)) (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr swizzle-p kslice-off))
         (descB (%wgmma-make-desc builder b-ptr swizzle-p kslice-off))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i)))))
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let* ((asm-str     (%wgmma-asm-string nacc n))
           (constraints (%wgmma-constraints nacc))
           (ret-ty      (%wgmma-struct-of-floats module nacc))
           (ptypes      (append (loop repeat nacc collect f32) (list i64 i64)))
           (args        (append c-ops (list descA descB)))
           (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints)))
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      (let ((agg (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
        (dotimes (i nacc)
          (setf agg (llvm-build-insert-value builder agg
                      (llvm-build-extract-value builder call i (format nil "wo~d" i))
                      i (format nil "wr~d" i))))
        agg))))

