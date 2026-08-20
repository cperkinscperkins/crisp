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

;;; ---- migrated from overlays/crisp-compiler-overlay.lisp (endeavour 152) ----

(defun %map-elements-fn-name (fn-form)
  "The function NAME out of a #'FOO argument to map-elements!, or NIL if FN-FORM is not
   that shape.  #'FOO reads as (FUNCTION FOO); the head is matched by name so it does not
   matter which package the reader interned it in."
  (and (consp fn-form)
       (%head-name-eq (first fn-form) "FUNCTION")
       (second fn-form)))

(defun %map-elements-check-unary (fn-form location)
  "Refuse a fused function that is not UNARY, before it reaches the funcall lowering.

   map-elements! applies its function to ONE element at a time, so there is no second
   argument to supply.  Checked against *function-table*, the same registry
   analyze-funcall-expression consults.  When the name is unknown (not a #'FOO form, or no
   signature registered yet) this stays silent and lets the normal path report — the goal is
   a better message for a real mistake, not a new source of false refusals."
  (let* ((name (%map-elements-fn-name fn-form))
         (sigs (and name (gethash name *function-table*))))
    (when sigs
      (unless (find 1 sigs :key (lambda (s) (length (function-signature-parameters s))))
        (error 'crisp-compiler-error
               :message (format nil "map-elements!: the fused function ~a must be unary — it is applied to one element at a time — but its declared signature takes ~{~a~^ or ~} argument(s)."
                                name
                                (remove-duplicates
                                 (mapcar (lambda (s) (length (function-signature-parameters s))) sigs)))
               :source-location location)))))

(defun %map-elements-coop-dims (ty)
  "(ROWS COLS USE) if TY is a (coop-matrix ELEM ROWS COLS USE) type spec, else NIL."
  (and (consp ty)
       (%head-name-eq (first ty) "COOP-MATRIX")
       (= (length ty) 5)
       (list (third ty) (fourth ty) (fifth ty))))

(defun %emit-per-frag-map (entry fn-form)
  "Per-fragment expansion of (map-elements! V #'FN) for a register tile: apply FN elementwise
   to every fragment of V that this warp holds.

   Mirrors %emit-per-frag-fill — no logical fragment index is needed, because an elementwise
   map is indifferent to which fragments of the tile this warp owns, so n-true / first-true
   are deliberately ignored."
  (destructuring-bind (m n syms &optional n-true first-true operand) (cdr entry)
    (declare (ignore m n n-true first-true operand))
    `(progn
       ,@(loop for s in syms
               collect `(map-elements! ,s ,fn-form)))))

(defun %map-elements-call (fn-form arg-form)
  "Build the call applying the fused function to ARG-FORM.

   Prefers a DIRECT call (FOO arg) when FN-FORM is #'FOO, because that is the form the AD
   engine can differentiate; falls back to (funcall FN-FORM arg) otherwise."
  (let ((name (%map-elements-fn-name fn-form)))
    (if name
        (list name arg-form)
        (list (intern "FUNCALL" (find-package :crisp-language)) fn-form arg-form))))

(defun %map-elements-grad-name (fn-form pkg)
  "The <NAME>_GRAD symbol for the fused function in FN-FORM (a #'NAME), interned in PKG.
   Matches the convention the AD walk itself uses (src/autodiff.lisp:2553)."
  (let ((name (%map-elements-fn-name fn-form)))
    (when name
      (intern (format nil "~a_GRAD" (symbol-name name))
              (or pkg (symbol-package name))))))

(defun %emit-per-frag-map-vjp (adj-entry primal-entry fn-form)
  "Per-fragment expansion of (%map-elements-vjp! ADJ PRIMAL #'F_GRAD) for register tiles:
   zip the two tiles' fragment lists and pair them positionally.  Positional pairing is right
   because both tiles carry the SAME shape and the same warp distribution, so fragment k of one
   corresponds to fragment k of the other."
  (let ((asyms (fourth adj-entry))
        (psyms (fourth primal-entry)))
    (unless (= (length asyms) (length psyms))
      (error 'crisp-compiler-error
             :message (format nil "%map-elements-vjp!: adjoint tile has ~a fragments but the primal tile has ~a — they must match."
                              (length asyms) (length psyms))
             :source-location nil))
    `(progn
       ,@(loop for a in asyms
               for p in psyms
               collect `(%map-elements-vjp! ,a ,p ,fn-form)))))

(defun %emit-map-vjp-explode (form tiles)
  "Rewrite (%map-elements-vjp! ADJ PRIMAL FN [IDX]) when EITHER operand names an exploded tile.

   Resolves ONE side per call, so the adjoint tile and the primal tile may be bound at
   different LET levels — which they always are, since the VJP binds the primal itself while
   the walk binds the adjoint outside.  See the header above for the three-step shape."
  (destructuring-bind (adj primal fn &optional idx) (cdr form)
    (let ((vjp-s (first form))
          (adj-e (assoc adj tiles))
          (prm-e (assoc primal tiles)))
      (cond
        ;; Both sides known here — pair positionally and we are done.  Positional pairing is
        ;; right because the two tiles carry the same shape and the same warp distribution.
        ((and adj-e prm-e)
         (let ((asyms (fourth adj-e)) (psyms (fourth prm-e)))
           (unless (= (length asyms) (length psyms))
             (error 'crisp-compiler-error
                    :message (format nil "%map-elements-vjp!: adjoint tile has ~a fragments but the primal tile has ~a — they must match."
                                     (length asyms) (length psyms))
                    :source-location nil))
           `(progn ,@(loop for a in asyms for p in psyms
                           collect `(,vjp-s ,a ,p ,fn)))))
        ;; Only the adjoint is known at this level.
        (adj-e
         (let ((asyms (fourth adj-e)))
           (if idx
               `(,vjp-s ,(nth idx asyms) ,primal ,fn ,idx)
               `(progn ,@(loop for a in asyms for i from 0
                               collect `(,vjp-s ,a ,primal ,fn ,i))))))
        ;; Only the primal is known at this level.
        (prm-e
         (let ((psyms (fourth prm-e)))
           (if idx
               `(,vjp-s ,adj ,(nth idx psyms) ,fn ,idx)
               `(progn ,@(loop for p in psyms for i from 0
                               collect `(,vjp-s ,adj ,p ,fn ,i))))))
        (t form)))))



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



(defun %spv-decide-register-mode (kernel-name profile)
  "Endeavor 144 Phase 4: pick the per-thread register allocation for KERNEL-NAME from the
   profile's selectable :max-registers-per-thread modes, and record it in
   *kernel-register-mode* for the metacrisp.

   Three outcomes:
     demand <= default mode       -> default; silent (nothing to trade).
     default < demand <= a larger -> select the SMALLEST mode that fits, and say so.
                                     This is the case that was silently costing 1.5-2x
                                     on BMG: IGC spilled rather than being asked for the
                                     larger allocation.
     demand > every mode          -> WARN; it will spill whatever we choose.
   Returns the chosen mode, or NIL when there is nothing to decide."
  (let ((modes (%hp-register-modes profile)))
    (when modes
      (multiple-value-bind (demand elements) (%spv-kernel-register-demand kernel-name)
        (when (plusp demand)
          (let* ((default-mode (first modes))
                 (fitting      (find-if (lambda (mode) (<= demand mode)) modes))
                 (chosen       (or fitting (reduce #'max modes))))
            (setf (gethash kernel-name *kernel-register-mode*) chosen)
            (cond
              ((null fitting)
               (format *error-output*
                       "WARNING: kernel ~a needs ~a registers/thread (~a register-tile elements x 4 B / ~a B per GRF register), exceeding every selectable allocation ~a in the hardware profile — it will SPILL in any mode.  Reduce the register-tile shape, the ring depth, or distribute the tile across more warps (:warps).~%"
                       kernel-name demand elements *spv-grf-register-bytes* modes))
              ((> demand default-mode)
               (format *error-output*
                       "NOTE: kernel ~a needs ~a registers/thread, above the default allocation of ~a — selecting the ~a-register mode.  (Larger allocations trade threads-per-EU for registers; without this the JIT would spill instead.)~%"
                       kernel-name demand default-mode chosen)))
            chosen))))))

(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float.

   Endeavor 144 Phase 0: also registers the BUILTIN hardware profiles, which must happen
   after initialize-compiler's clrhash of *hardware-profiles* — this is the first hook that
   runs there.  See register-builtin-hardware-profiles for the src-patch note."
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record)
  (register-builtin-hardware-profiles))




(defun register-builtin-hardware-profiles ()
  "Endeavor 144 Phase 0 (D2): register Crisp's predefined hardware profiles.

   Called from register-mma-types, which initialize-compiler invokes AFTER it clrhash-es
   *hardware-profiles* — so builtins survive the clear and a same-named user profile still
   overrides them.

   NOTE FOR THE SRC PATCH: this belongs as its own call in initialize-compiler next to
   register-builtins."
  ;; Intel Arc B580 (Battlemage / Xe2).  Device-queried 2026-07-27.
  ;; :tile-visit-strip-width 4 — MEASURED: grouped visit order is worth +63% at 2048 here
  ;; (linear 17.1 -> 27.9 TFLOPS), and 4 beat 2/8/16 across both sizes tested.
  (register-hardware-profile
   'bmg
   '(:simd-width 16                        ; subGroupSizes reports BOTH 16 and 32
     :compute-units 20                     ; Xe-cores (5 slices x 4 subslices)
     :max-registers-per-thread (128 256)   ; GRF registers (32 B each) — selectable modes
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 1024)
     :max-shared-memory-per-block 128KB
     :l2-cache-size 18MB
     :native-cache-line-size 64            ; Xe2 LSC line; not queryable
     :tile-visit-strip-width 4             ; measured; see the Phase 1 revision comment
     :mma-shapes ((8 16 8))))              ; XMX tf32
  ;; NVIDIA H100 PCIe (Hopper).  Device-queried 2026-07-28.
  ;; :compute-units 114 is the PCIe part (SXM is 132); this value OVERRIDES the device SM query
  ;; in the generated CUDA launch grid, so the variant distinction is load-bearing.
  ;; :max-shared-memory-per-block is the OPT-IN cap, not the 48KB default (chap2/chap3 exceed 48KB).
  ;; :mma-shapes MUST include (16 8 8) — chap0/1/1.5/2 all pass that tf32 shape.
  ;; NO :tile-visit-strip-width — MEASURED: grouped order is neutral-to-harmful here (chap2 worse
  ;; at every width; chap3_wgmma -8.3% at W=4 degrading monotonically to -14.4% at W=16), and no
  ;; cliff appears even at 4x L2.  Omitting the key means linear, which is what this part wants.
  (register-hardware-profile
   'h100
   '(:simd-width 32
     :compute-units 114
     :max-registers-per-cu 65536
     :max-registers-per-thread 255
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 64)
     :max-shared-memory-per-block 227KB
     :l2-cache-size 50MB
     :native-cache-line-size 128
     :mma-shapes ((16 8 8) (16 8 4) (16 8 16)))))



;; src/mma.lisp
(defvar *ptx-register-demand* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 3: (kernel-name . source-location) -> 32-bit registers/thread explicitly
   reserved at that site on the NVIDIA path (register tiles and wgmma accumulators).  Keyed per
   site and ASSIGNED, so Crisp's multipass re-analysis is idempotent — same discipline as
   *spv-register-demand*.")


;; src/mma.lisp
(defun %kernel-registers-per-thread (kernel-name)
  "Total explicitly-reserved registers/thread for KERNEL-NAME.  NVIDIA: 32-bit registers from
   *ptx-register-demand*.  Intel/SPV: derived from the GRF element tally.  0 when nothing was
   reserved."
  (if (eq *target-backend* :spirv)
      (values (%spv-kernel-register-demand kernel-name))
      (let ((total 0))
        (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf total v)))
                 *ptx-register-demand*)
        total)))


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



;; src/mma.lisp
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand).  :spirv -> a filled coop matrix;
   else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default acc) picks
   the coop-matrix Use + shape so an A/B operand tile mints fragments matching load-fragment-a/b.

   Endeavor 144: each fragment is tallied against the current kernel — as coop-matrix ELEMENTS on
   SPV (Phase 4's GRF model) and as 32-bit REGISTERS on PTX (Phase 3's occupancy model).  Both
   skip when the form carries :tally nil, which marks fill-tile's per-fragment set!s: those
   RE-INITIALIZE fragments the tile already owns and allocate nothing."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))
              (when tally-p (%spv-note-register-fragment fr fc context location))
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float fr fc use) :kind :fill
               :value-node (analyze-expression init env context (append location '(1)))
               :rows fr :cols fc :use use :layout 0 :source-location location)))
          (progn
            (unless (and (eql m 16) (eql n 8))
              (error 'crisp-compiler-error
                     :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
            ;; PTX fragment register counts, matching the records minted below:
            ;; acc 16x8 f32 -> 4, A tf32 16x8 -> 4, B tf32 8x8 -> 2 (per lane, 32-bit each).
            (when tally-p
              (%ptx-note-register-demand (ecase operand (:acc 4) (:a 4) (:b 2)) context location))
            (analyze-expression
             (ecase operand
               (:acc `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init))
               (:a   `(%construct-struct register-fragment-a-tf32-16x8 ,init ,init ,init ,init))
               (:b   `(%construct-struct register-fragment-b-tf32-8x8 ,init ,init)))
             env context location))))))

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



(defun %coop-refuse-col-major (tensor-node)
  "Signals the BUG 035 refusal for a :col-major cooperative-matrix operand on SPIR-V.

   Split out from %COOP-LAYOUT-OF so the message lives in one place and the
   negative spec has a stable substring to match."
  (error 'crisp-compiler-error
         :message
         (concatenate 'string
           "Intel cooperative-matrix (MMA) operands cannot be :col-major "
           "(:contiguous-term :first). IGC ships no PackedA_ColumnMajor / "
           "PackedB_ColumnMajor load builtin, so such a kernel fails to build on the "
           "device, and a ColumnMajor accumulator computes incorrectly. "
           "Declare the operand :row-major, or stage an explicit transpose into "
           "scratch and feed the MMA from there. (NVIDIA/PTX is unaffected.)")
         :source-location (ignore-errors (semantic-node-source-location tensor-node))))

(defun %coop-layout-of (tensor-node)
  "The coop load/store MemoryLayout for an operand, derived from its tensor type's
   :contiguous-term (NOT hardcoded): :last (row-major) -> 0 (RowMajor); :first (col-major)
   -> 1 (ColMajor).  So the layout matches how the matrix is actually stored — the stride
   in %coop-tensor-ptr+stride follows (s0 for RowMajor, s1 for ColMajor).

   Resolves the operand type with %TS-CANONICALIZE-TENSOR-TYPE rather than
   CANONICALIZE-TYPE-SPECIFIER: at a load site the operand is usually a kernel
   parameter carrying a MANGLED type symbol, which only the former can expand.
   The result is normalised to a keyword because the unmangler yields plain
   symbols.  Unresolvable types keep the historical :last / RowMajor default.

   On :spirv a resolved :first (col-major) is REFUSED at compile time rather than
   emitted — see %COOP-REFUSE-COL-MAJOR for the measurements behind that.
   See BUG 035."
  (let* ((canon (%ts-canonicalize-tensor-type (get-single-value-type tensor-node)))
         (raw   (and canon (%get-tensor-ct canon)))
         (ct    (cond ((keywordp raw) raw)
                      ((symbolp raw)  (intern (symbol-name raw) :keyword))
                      (t :last))))
    (cond
      ((not (eq ct :first)) 0)
      ((eq *target-backend* :spirv) (%coop-refuse-col-major tensor-node))
      (t 1))))


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

(defun analyze-prefetch-tile (expr env context location)
  "Endeavor 142 (Phase B): (prefetch-tile SRC (COORD-Y COORD-X) :size (H W)) -> an Intel L1 cache
   prefetch (Subgroup2DBlockPrefetchINTEL).  A fire-and-forget hint with NO destination — it warms the
   LSC so a subsequent register block-load (load-tile -> GRF) hits L1 instead of stalling on global
   memory; it never changes results.  Intel/SPV-only + hardware-profile-required (the profile's L1 size
   feeds the Phase-C thrash analysis).  Lowered by reusing the coop-op node with a :prefetch kind."
  (unless (active-hardware-profile)
    (error 'crisp-compiler-error
      :message "prefetch-tile requires a hardware profile (pass --hardware-profile): its L1 / GRF limits drive the register-pipeline safety analysis."
      :source-location location))
  (unless (eq *target-backend* :spirv)
    (error 'crisp-compiler-error
      :message "prefetch-tile lowers to Subgroup2DBlockPrefetchINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping (NVIDIA's prefetch model is cp.async into SLM, a different concept)."
      :source-location location))
  (destructuring-bind (src coords &key size) (cdr expr)
    (unless (and (listp coords) (= (length coords) 2))
      (error 'crisp-compiler-error
        :message (format nil "prefetch-tile: coords must be a two-element (COORD-Y COORD-X), got ~S" coords)
        :source-location location))
    (unless (and (listp size) (= (length size) 2) (every #'integerp size))
      (error 'crisp-compiler-error
        :message (format nil "prefetch-tile: :size must be a compile-time (H W) of integers, got ~S" size)
        :source-location location))
    (let* ((h (first size)) (w (second size))
           (ty (first coords)) (tx (second coords))
           (tnode (analyze-expression src env context (append location '(1)))))
      (make-semantic-coop-op
       :type 'void :kind :prefetch
       :tensor-node tnode
       :rows h :cols w :use 0 :layout (%coop-layout-of tnode)
       :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
       :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
       :source-location location))))

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

(defun %register-tile-ring-init-form-p (form)
  "T if FORM is a (make-register-tile-ring T (M N) &key ring-count operand) constructor (Endeavor 142).
   Distinct from make-register-tile: NO positional INIT (ring slots are load-targets), keys start at 4th."
  (and (consp form) (>= (length form) 4) (%head-name-eq (first form) "MAKE-REGISTER-TILE-RING")
       (listp (third form)) (= (length (third form)) 2)
       (keywordp (fourth form))))

(defun %resolve-tile-ref (ref tiles)
  "Endeavor 142: resolve a tile operand REF to a per-slot tiles entry (V m n syms n-true first-true
   operand).  REF is either a bare exploded register-tile symbol, or (ring-get RING SLOT) with a
   COMPILE-TIME integer SLOT into a register-tile-RING (a ring entry is (RSYM :ring m n slot-syms-list
   operand)).  The GRF cannot be runtime-indexed, so a register ring-get with a non-constant slot is a
   hard error here — the Phase-C pipeline supplies static slots by unrolling / phase-flip.  Returns NIL
   if REF names no exploded register tile/ring (a normal scratch operand)."
  (cond
    ((symbolp ref)
     (let ((e (assoc ref tiles)))
       (when (and e (eq (second e) :ring))
         (error 'crisp-compiler-error
           :message (format nil "~a is a register-tile-ring — index it with (ring-get ~a SLOT), it is not a plain tile." ref ref)
           :source-location nil))
       e))
    ((and (consp ref) (%head-name-eq (first ref) "RING-GET") (= (length ref) 3))
     (let ((ring-entry (assoc (second ref) tiles))
           (slot (third ref)))
       (when (and ring-entry (eq (second ring-entry) :ring))
         (destructuring-bind (rsym marker m n slot-syms-list operand) ring-entry
           (declare (ignore marker))
           (unless (integerp slot)
             (error 'crisp-compiler-error
               :message (format nil "ring-get into the REGISTER ring ~a needs a compile-time integer slot (the GRF is not runtime-indexable); got ~S.  Unroll the K-loop by :ring-count or use a static phase index."
                                rsym slot)
               :source-location nil))
           (unless (< -1 slot (length slot-syms-list))
             (error 'crisp-compiler-error
               :message (format nil "ring-get slot ~a is out of range 0..~a for ring ~a." slot (1- (length slot-syms-list)) rsym)
               :source-location nil))
           (list rsym m n (nth slot slot-syms-list) 1 0 operand)))))
    (t nil)))



(defun %frag-mn ()
  "Per-fragment (M . N) for register-tile decomposition: the active profile's mma-shape
   (M N) on :spirv, else NVIDIA 16x8."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (m n k) (%spv-mma-shape) (declare (ignore k)) (cons m n))
      (cons 16 8)))

(defun %frag-mn-for-operand (operand)
  "Endeavor 142 — per-fragment (rows . cols) for a register-tile of :operand (a|b|acc).  From the
   active profile's mma-shape (sm sn sk): A = sm×sk (Use 0), B = sk×sn (Use 1), Acc = sm×sn (Use 2)
   — matching load-fragment-a/b and make-register-fragment.  NVIDIA: 16x8 (A/B on PTX is rejected
   earlier for the block-load path)."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape)
        (ecase operand
          (:a   (cons sm sk))
          (:b   (cons sk sn))
          (:acc (cons sm sn))))
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
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/16)x(N/8) accumulator fragments x 4 fp32 regs <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes."
  (unless (eq *target-backend* :spirv)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (budget        (or (%hp-registers-per-thread-default)
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

;; Re-definition of the src/ original.  CHANGE: the operand readers take a K-step index, and a
;; fragment's accumulate is the compile-time SEQUENCE of its K-steps rather than one MMA at
;; K-index 0.
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is a
   static per-warp switch (n-true threaded to %emit-frag-loop-distributed).  Endeavor 142: when A/B
   are register-tiles (present in TILES, pre-loaded via load-tile), the operand is read from its
   pre-loaded fragment var instead of load-fragment-a/b.

   Endeavor 145 P3a: the staged operands may span SEVERAL native K-steps (Kt / K_n, compile-time)
   and every one of them now fires.  Previously only K-index 0 was emitted and any surplus staged
   data was silently dropped.  For the F3 body/accum-op API this means (accum-op) fires the
   fragment's WHOLE contraction — all of its K-steps — which keeps the promise that the body
   controls WHEN a fragment accumulates, not how its contraction is chopped up."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape)
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (nth (+ (* mi (max 1 (floor (third ta) sk))) ks) (fourth ta))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (nth (+ (* ks (max 1 (floor (third tb) sn))) nj) (fourth tb))
                           `(load-fragment-b ,b (,ks ,nj)))))
                   (one-frag (fv mi-form nj-form)
                     (let* ((sets (loop for ks below k-steps
                                        collect `(set! ,fv (mma-accumulate ,fv
                                                                           ,(a-operand mi-form ks)
                                                                           ,(b-operand nj-form ks)))))
                            (acc-set (if (= (length sets) 1) (first sets) `(progn ,@sets))))
                       (if body
                           (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                           (list acc-set)))))
            (if (> n-true 1)
                (progn
                  (when (or (%resolve-tile-ref a tiles) (%resolve-tile-ref b tiles))
                    (error 'crisp-compiler-error
                      :message "register-resident A/B operands are not yet supported with a warp-distributed accumulator (n-true > 1)."
                      :source-location nil))
                  (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).  Endeavor 139 step-4: distributed path
   is now a static per-warp switch."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
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


;; src/mma.lisp
(defparameter *wgmma-acc-occupancy-warn-fraction* 1/2
  "Endeavor 144 Phase 2: warn when a wgmma accumulator alone occupies at least this
   fraction of the per-thread register budget.  At 1/2, an m64n256 accumulator (128 of
   255 registers) warns and an m64n128 (64) does not — so the advisory fires precisely on
   the tile widths where occupancy, not fit, is the binding constraint.")

;; src/mma.lisp
(defun %wgmma-acc-fit-check (m n location)
  "Endeavor 144 Phase 2: register accounting for a wgmma (M N) warpgroup accumulator.

   A wgmma D accumulator holds N/2 flat f32 registers PER THREAD across the 128-thread
   warpgroup (the wgmma D thread->element mapping).  Errors when that alone exceeds the
   per-thread budget (the active profile's :max-registers-per-thread, else
   *default-max-registers-per-thread*); warns when it consumes at least
   *wgmma-acc-occupancy-warn-fraction* of it.

   Deliberately accounts for the ACCUMULATOR ONLY — operand fragments, addressing, and
   whatever ptxas adds ride on top, so the real per-thread count is strictly higher.  Like
   %register-tile-fit-check, this checks what the developer explicitly reserved."
  (let* ((threads-per-warpgroup 128)
         (regs-per-thread    (floor n 2))
         (regs-per-warpgroup (* regs-per-thread threads-per-warpgroup))
         (profile (active-hardware-profile))
         ;; Endeavor 144 D4: the key may now be a LIST of selectable modes, so read it
         ;; through the accessor.  A wgmma kernel is NVIDIA-only (one fixed allocation),
         ;; so the DEFAULT mode is the right budget here.
         (budget  (or (%hp-registers-per-thread-default profile)
                      *default-max-registers-per-thread*)))
    (when (> regs-per-thread budget)
      (error 'crisp-compiler-error
             :message (format nil "make-wgmma-accumulator: a ~ax~a warpgroup accumulator needs ~a registers/thread (N/2 flat f32), exceeding the register budget of ~a.  Use a smaller N, or a hardware profile with a larger :max-registers-per-thread."
                              m n regs-per-thread budget)
             :source-location location))
    (when (>= regs-per-thread (* budget *wgmma-acc-occupancy-warn-fraction*))
      (format *error-output*
              "WARNING: make-wgmma-accumulator ~ax~a reserves ~a of ~a registers/thread (~,1f%) for the ACCUMULATOR ALONE; operand fragments and addressing are additional.  That is ~a registers per 128-thread warpgroup, which bounds how many warpgroups can be resident per compute unit.  Consider a smaller N if occupancy matters more than arithmetic intensity for your problem size.~%"
              m n regs-per-thread budget
              (* 100.0 (/ regs-per-thread budget))
              regs-per-warpgroup))
    regs-per-thread))

;; src/mma.lisp
(defvar *spv-register-demand* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 4: (kernel-name . source-location) -> fragment ELEMENT count, for
   the SPV/Intel GRF model.  Keyed per source site and assigned (not incremented) so
   multipass re-analysis is idempotent.  Summed per kernel by %spv-kernel-register-demand.")

;; src/mma.lisp
(defvar *kernel-register-mode* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 4: kernel-name -> the selected per-thread register allocation (an
   element of the profile's :max-registers-per-thread modes).  Written by
   %spv-decide-register-mode and carried to the hoist via the metacrisp so the L0
   launcher can ask IGC for that allocation (-ze-opt-large-register-file).")

(defparameter *spv-grf-register-bytes* 32
  "Bytes per architectural GRF register on Intel Xe/Xe2.  A BACKEND fact, deliberately
   NOT a hardware-profile key: the profile counts registers, the target defines their
   width (4 B on NVIDIA, 32 B here).  See Endeavor 144 decision D4.")

;; src/mma.lisp
(defun %spv-note-register-fragment (rows cols context location)
  "Endeavor 144 Phase 4: record one register FRAGMENT's element count against the kernel
   being compiled, for the Intel GRF model.  No-op off the SPV backend or without a
   current function.  Assigned per (kernel . location) so re-analysis is idempotent.

   Only ALLOCATIONS reach here — see the :tally nil guard in analyze-make-register-fragment
   for why re-initializing an existing fragment must not be counted."
  (when (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when fn
        (setf (gethash (cons fn location) *spv-register-demand*) (* rows cols))))))


(defun %emit-per-frag-fill (entry val)
  "Per-fragment expansion of (fill-tile V VAL) for a register tile: reset every fragment
   of V to a fragment-of-VAL (matching make-register-tile's own 16x8 fragment init).

   Endeavor 144 Phase 4: tagged :tally nil.  These forms RE-INITIALIZE fragments the tile
   already owns — a set! of an existing register, not a new allocation — so counting them
   in the GRF demand model would inflate a tile's cost purely for having been filled."
  (destructuring-bind (m n syms &optional n-true first-true operand) (cdr entry)
    (declare (ignore m n n-true first-true operand))
    ;; fill just resets every fragment this warp holds — no logical index needed.
    `(progn
       ,@(loop for s in syms
               collect `(set! ,s (make-register-fragment 16 8 ,val :tally nil))))))

;; src/mma.lisp
(defun %spv-kernel-register-demand (kernel-name)
  "Endeavor 144 Phase 4: (values GRF-REGISTERS ELEMENTS) demanded per thread by
   KERNEL-NAME's register tiles / rings, or (values 0 0) if it has none."
  (let ((elements 0))
    (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf elements v)))
             *spv-register-demand*)
    (values (ceiling (* elements 4) *spv-grf-register-bytes*) elements)))


(defun %emit-per-frag-block-load (src entry coords)
  "Endeavor 142 — per-fragment expansion of (load-tile SRC <register-tile> COORDS): load each fragment
   of the A/B register-tile from global SRC.  For the first MMA_CORRECT this reuses load-fragment-a/b
   (CooperativeMatrixLoadKHR); the Subgroup2DBlockLoad swap is Phase B.  COORDS is the tile's grid
   block position — its fragment-row/col offset (grid-idx × per-tile fragment count) is added to the
   in-tile fragment index."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) (operand :acc)) (cdr entry)
    (declare (ignore n-true first-true))
    (let ((cl (find-package :crisp-language)))
      (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
        (let ((frag-fn (ecase operand
                         (:a (intern "LOAD-FRAGMENT-A" cl))
                         (:b (intern "LOAD-FRAGMENT-B" cl))
                         (:acc (error 'crisp-compiler-error
                                 :message "load-tile into an accumulator register-tile is not supported (only :operand :a / :b tiles are load targets)."
                                 :source-location nil))))
              (to-int  (intern "TO-INT" cl))
              (n-rows  (floor m fr))
              (n-cols  (floor n fc))
              (gy      (first coords))
              (gx      (second coords)))
          `(progn
             ,@(loop for ri below n-rows append
                     (loop for ci below n-cols
                           for idx = (+ (* ri n-cols) ci)
                           collect `(set! ,(nth idx syms)
                                          (,frag-fn ,src
                                                    ((+ (* (,to-int ,gy) ,n-rows) ,ri)
                                                     (+ (* (,to-int ,gx) ,n-cols) ,ci))))))))))))

;;; ---------------------------------------------------------------------------
;;; Endeavor 142 (Phase B, decision b): source-level unroll-by-ring-count.
;;; A register ring's slot must be a compile-time constant (the GRF is not runtime-indexable), yet the
;;; natural pipeline idiom (shared with the SLM scratch ring) writes it as (mod grid-k RING-COUNT).  We
;;; UNROLL the K-loop by the ring-count so each copy's slot folds to a literal (copy j -> slot j), while
;;; data coordinates keep the absolute block (grid-k + j).  Runs BEFORE %explode-rewrite-body-form, so
;;; the exploder then sees only static ring-get slots.
;;; ---------------------------------------------------------------------------

(defun %register-ring-ref-p (form tiles)
  "T if FORM is (ring-get RING ...) naming a REGISTER ring (a :ring entry) in TILES."
  (and (consp form) (%head-name-eq (first form) "RING-GET") (>= (length form) 3)
       (let ((e (assoc (second form) tiles))) (and e (eq (second e) :ring)))))

(defun %body-refs-register-ring-p (form tiles)
  "T if FORM contains any register-ring ring-get anywhere in its tree."
  (cond ((%register-ring-ref-p form tiles) t)
        ((consp form) (some (lambda (f) (%body-refs-register-ring-p f tiles)) form))
        (t nil)))

(defun %collect-register-ring-counts (form tiles)
  "List the :ring-counts of every register ring ring-getted in FORM (ring entry = (RSYM :ring m n
   slot-syms-list operand); (fifth entry) is the slot-syms-list, whose length is the ring-count)."
  (let ((counts '()))
    (labels ((walk (f)
               (when (consp f)
                 (when (%register-ring-ref-p f tiles)
                   (push (length (fifth (assoc (second f) tiles))) counts))
                 (mapc #'walk f))))
      (walk form))
    (nreverse counts)))

(defun %fold-static-slot (expr loop-var j)
  "Evaluate a register-ring SLOT EXPR to a compile-time integer with LOOP-VAR bound to J.  Supports
   integer literals, LOOP-VAR, (+ - * a b), (mod a b), and (to-ulong/to-int x) (identity).  Errors if
   EXPR does not fold — a register-ring slot MUST be static (the GRF is not runtime-indexable)."
  (labels ((nm (s) (and (symbolp s) (symbol-name s)))
           (ev (e)
             (cond
               ((integerp e) e)
               ((and (symbolp e) (string-equal (nm e) (nm loop-var))) j)
               ((and (consp e) (= (length e) 2)
                     (member (nm (first e)) '("TO-ULONG" "TO-INT") :test #'string-equal))
                (ev (second e)))
               ((and (consp e) (= (length e) 3)
                     (member (nm (first e)) '("+" "-" "*" "MOD") :test #'string-equal))
                (let ((a (ev (second e))) (b (ev (third e))))
                  (cond ((string-equal (nm (first e)) "+")   (+ a b))
                        ((string-equal (nm (first e)) "-")   (- a b))
                        ((string-equal (nm (first e)) "*")   (* a b))
                        (t                                   (mod a b)))))
               (t (error 'crisp-compiler-error
                    :message (format nil "register-ring ring-get slot ~S does not fold to a compile-time integer (with ~a := ~a).  A register-ring slot must be static — write it as (mod LOOPVAR ring-count) or a constant."
                                     expr loop-var j)
                    :source-location nil)))))
    (ev expr)))

(defun %subst-loop-body-copy (form loop-var j tiles)
  "Copy J of a register-ring loop body: register-ring ring-get SLOTS fold to the static literal
   (%fold-static-slot with LOOP-VAR:=J); every OTHER LOOP-VAR use becomes the absolute block
   (+ LOOP-VAR (to-ulong J)).  J=0 leaves data coords as bare LOOP-VAR."
  (let ((cl (find-package :crisp-language)))
    (cond
      ((and (symbolp form) (string-equal (symbol-name form) (symbol-name loop-var)))
       (if (zerop j) loop-var (list (intern "+" cl) loop-var (list (intern "TO-ULONG" cl) j))))
      ((not (consp form)) form)
      ((%register-ring-ref-p form tiles)
       (list (first form) (second form) (%fold-static-slot (third form) loop-var j)))
      (t (mapcar (lambda (f) (%subst-loop-body-copy f loop-var j tiles)) form)))))

(defun %unroll-register-ring-loops (form tiles)
  "Source->source: unroll any (dotimes (KVAR LIMIT) BODY...) whose BODY ring-gets a REGISTER ring by
   that ring's :ring-count RC — KVAR steps by RC and RC body-copies run per step (copy j: absolute block
   KVAR+j, slot j).  v1: the loop must be written stride-1 (we set the stride), all register rings in it
   must share RC, and LIMIT is assumed divisible by RC (K is a multiple of the tile-K)."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "DOTIMES") (>= (length form) 2)
          (consp (second form)) (>= (length (second form)) 2)
          (null (third (second form)))            ; user wrote stride-1; we install the RC stride
          (%body-refs-register-ring-p (cddr form) tiles))
     (let* ((binding  (second form))
            (loop-var (first binding))
            (limit    (second binding))
            (body     (cddr form))
            (rcs      (remove-duplicates (%collect-register-ring-counts body tiles)))
            (cl       (find-package :crisp-language)))
       (unless (= 1 (length rcs))
         (error 'crisp-compiler-error
           :message (format nil "register-ring K-loop mixes rings of different :ring-count ~S — v1 requires a single ring-count per pipelined loop." rcs)
           :source-location nil))
       (let ((rc (first rcs)))
         `(,(first form) (,loop-var ,limit (,(intern "TO-ULONG" cl) ,rc))
           ,@(loop for j below rc
                   append (mapcar (lambda (f) (%subst-loop-body-copy f loop-var j tiles)) body))))))
    (t (mapcar (lambda (f) (%unroll-register-ring-loops f tiles)) form))))

;; Re-definition of the src/ original.  CHANGE: one added clause for %load-register-tile-acc.
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! / %map-elements-vjp! references to any exploded tile in TILES with
   per-fragment progns; otherwise recurse structurally."
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
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "MAP-ELEMENTS!") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-map (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "%MAP-ELEMENTS-VJP!") (>= (length form) 4)
          (or (assoc (second form) tiles) (assoc (third form) tiles)))
     (%emit-map-vjp-explode form tiles))
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))

;; Re-definition of the src/ original.  CHANGE: one added LET* binding that makes the LET's
;; SLM scratch-tile shapes visible to %emit-per-frag-accumulate (145 P3a).  Because
;; *mma-scratch-tile-dims* is special, the LET* establishes a dynamic binding covering the
;; whole expansion, including the %explode-rewrite-body-form calls at the end.
(defun %explode-register-tiles (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range).
   Endeavor 145 P3a: also publishes the LET's SLM scratch-tile shapes in *mma-scratch-tile-dims* so
   the accumulate expansion can walk K within a staged tile."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             ;; 145 P3a: SLM tile shapes for the K-step count (special -> dynamically scoped).
             (*mma-scratch-tile-dims* (%mma-scratch-tile-dims-from-bindings bindings))
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
                                 (operand (getf (nthcdr 4 form) :operand :acc))
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                            (* (floor m fr) (floor n fc))))
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
                                (push (list (first b) m n syms n-true first-true operand) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init :operand ,operand))))))
                          (if (and (consp b) (= (length b) 2) (symbolp (first b))
                                   (%register-tile-ring-init-form-p (second b)))
                              (let* ((form    (second b))
                                     (dims    (third form))
                                     (m       (first dims)) (n (second dims))
                                     (keys    (nthcdr 3 form))
                                     (operand (getf keys :operand :acc))
                                     (rc      (getf keys :ring-count)))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                  (let* ((nfrags (* (floor m fr) (floor n fc)))
                                         (slot-syms-list
                                           (loop for slot below rc
                                                 collect (%register-tile-frag-syms
                                                          (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                  (symbol-package (first b)))
                                                          nfrags))))
                                    (push (list (first b) :ring m n slot-syms-list operand) tiles)
                                    (loop for syms in slot-syms-list
                                          append (loop for s in syms
                                                       collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand)))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))


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

;;; ===================================================================
;;; BUG 036 — matrix-multiply-tile-stride must reset the C-tile per OUTPUT TILE.
;;;
;;; %mmts-lower emitted  (tile-stride C <spec> (gy gx) (dotimes (gk ...) BODY) EPILOGUE)
;;; with nothing re-initialising the accumulator between tiles.  The register C-tile is
;;; initialised ONCE by its make-register-tile binding OUTSIDE the loop, so a workgroup that
;;; visits a second output tile keeps the first tile's partial sums and adds the new tile's
;;; contribution on top.  Measured on BMG with the SHIPPED 135/04 spec, widened to a 2-tile C:
;;; C[0][16]=60 against a reference of 30.  Invisible until now because every shipped spec
;;; uses exactly ONE output tile, so the stride body runs once.
;;;
;;; The requirement was already KNOWN: the scratch-C-tile spec 135/02-matmul-grid-stride does
;;; it by hand — `(when (= grid-k 0) (fill-tile C-tile 0.0))  ; reset accumulator at the start
;;; of each tile`.  The macro simply never provided it, so the register specs omitted it.
;;; Owning the tile-stride + K-loop bookkeeping is the macro's whole job, so it owns this too.
;;;
;;; RESET VALUE — a register tile resets to its DECLARED INIT, not to 0.0.  That makes
;;; multi-tile behave exactly like single-tile, which is what a bug fix should do; hardcoding
;;; 0.0 would silently change semantics for a non-zero init (endeavor 132's F3 accum-op API
;;; makes a bias-valued init a real use).  A SCRATCH C-tile has no declared init
;;; (make-scratch-matrix takes none), so it resets to 0.0.
;;;
;;; BARRIER — fill-tile on a scratch tile is a workgroup-COLLECTIVE write and its docstring is
;;; explicit that it inserts no barrier ("the caller syncs before reading").  The macro is that
;;; caller, so the scratch path gets a sync-workgroup after the fill.  The register path needs
;;; none: each lane owns its own fragments.
;;; ===================================================================
(defun %mmts-register-dims-map (bindings)
  "Alist var -> ((M N) INIT) for each register-tile binding in a let's BINDINGS.
   BUG 036: now carries the declared INIT as well as the dims, so the lowering can reset each
   output tile to the value the user actually asked for."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          ;; (make-register-tile elem (M N) INIT &key ...)
          collect (list (first b) (third (second b)) (fourth (second b)))))   ; (make-register-tile elem (M N) init)

(defun %expand-mmts-register-in-form (form reg-map location)
  "Rewrite matrix-multiply-tile-stride forms whose C-tile is a register tile (in REG-MAP)
   to their tile-stride + K-loop lowering with a compile-time (M N) size-list tile-spec,
   so the generated store-tile/mma are visible to the register-tile SROA explosion.
   BUG 036: forwards the tile's declared INIT as the per-output-tile reset value."
  (cond
    ((not (consp form)) form)
    ((and (%mmts-head-p form) (assoc (third form) reg-map))
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form location)
       (let ((entry (assoc c-tile reg-map)))
         (%mmts-lower c-form c-tile (second entry) k-form k-step gy gx gk
                      (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) body)
                      location
                      (third entry)))))
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




;; VERBATIM re-definition of the src/ original, with ONE added entry: LOAD-FRAGMENT-ACC.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
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



(defun %ptx-note-register-demand-keyed (regs context key)
  "Record REGS 32-bit registers/thread for the kernel being compiled, under KEY.  KEY is the
   identity of the RESERVATION: a source location where each site is distinct storage
   (fragments), or a shape where repeated construction means re-initialization (wgmma)."
  (unless (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when (and fn (plusp regs))
        (setf (gethash (cons fn key) *ptx-register-demand*) regs)))))

;; src/mma.lisp
(defun %ptx-note-register-demand (regs context location)
  "Per-SITE reservation (register fragments): each source location is distinct storage."
  (%ptx-note-register-demand-keyed regs context location))

;; src/mma.lisp
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 occupancy report — keyed by SHAPE so a per-tile `(set! D (make-wgmma-accumulator ...))`
   re-initialization is not counted as a second accumulator."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (%wgmma-acc-fit-check m n location)
      (%ptx-note-register-demand-keyed (floor n 2) context (list :wgmma-acc m n))
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

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P2: load-fragment-acc.
;;;
;;; The backward pass must get dC (the `C_grad` global matrix) INTO a register
;;; accumulator before either backward GEMM can run, and nothing did that:
;;;   - store-fragment is accumulator -> memory only.
;;;   - load-fragment-a / -b read the A / B OPERAND layouts, not the accumulator's.
;;;   - load-tile into a register tile is Intel/SPV-only (Subgroup2DBlockLoadINTEL) and
;;;     has no PTX mapping at all.
;;;
;;; So this is the exact inverse of store-fragment: same accumulator layout, same
;;; (TY TX) tile addressing, reads instead of writes.  Like its sibling it is a pure
;;; REWRITE on PTX (no new codegen) and a coop-op node on SPV.
;;;
;;; Specs: tests/spec/145-mma-autodiff/03-load-fragment-acc-bmg.crisp  (on-metal)
;;;        tests/spec/145-mma-autodiff/04-load-fragment-acc-ptx.crisp  (IR-checked)
;;; ===================================================================
(defun analyze-load-fragment-acc (expr env context location)
  "P2 (145): (load-fragment-acc SRC (TY TX)) reads a fp32 ACCUMULATOR fragment from the
   SRC matrix at logical tile (TY TX).  The exact inverse of store-fragment.

   :spirv -> CooperativeMatrixLoadKHR with Use=2 (accumulator), rows/cols from the active
   profile's shape and layout from the source tensor's :contiguous-term — mirroring
   analyze-store-fragment so a Load/Store pair always agrees.

   else   -> the NVIDIA per-lane read at the m16n8 fp32 accumulator layout.  With
   g = lane/4 and t = lane%4 this lane's four registers live at
     (g, 2t) (g, 2t+1) (g+8, 2t) (g+8, 2t+1)
   offset by the tile origin (TY*16, TX*8) — byte-for-byte the addresses store-fragment
   writes, only feeding %construct-struct instead of set!.

   The fragment is tallied against the kernel's register budget exactly as
   make-register-fragment tallies one: a LOADED accumulator occupies the same registers
   as a constructed one, and endeavor 144's fit-check must see both."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sk))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
              (%spv-note-register-fragment sm sn context location)
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float sm sn 2) :kind :load
               :tensor-node tnode
               :rows sm :cols sn :use 2 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          (progn
            (%ptx-note-register-demand 4 context location)
            (analyze-expression
             `(let ((lane (to-int (warp-lane))))
                (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                  (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                    (%construct-struct register-fragment-acc-f32-16x8
                      (~ ,src row col)
                      (~ ,src row (+ col 1))
                      (~ ,src (+ row 8) col)
                      (~ ,src (+ row 8) (+ col 1))))))
             env context location))))))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3a: mma-accumulate-via-tile walks K within a tile.
;;;
;;; A forward capability, but a hard PREREQUISITE for the backward — and a latent forward
;;; bug fix in its own right.
;;;
;;; With a workgroup tile (Mt x Nt) accumulating over K in steps of Kt:
;;;     forward   C-tile += A-tile . B-tile     -> (Mt, Nt, Kt)
;;;     backward  dA-tile = dC-tile . B-tileT   -> (Mt, Kt, Nt)
;;;     backward  dB-tile = A-tileT . dC-tile   -> (Kt, Nt, Mt)
;;; Every requirement of the two backward GEMMs is already implied by the forward EXCEPT
;;; Kt % N_n (from dA) and Kt % M_n (from dB) — i.e. Kt % lcm(M_n, N_n) == 0, which is 16 on
;;; both supported profiles.  K_n is 8, so a DIFFERENTIABLE tile spans at least two native
;;; K-steps.
;;;
;;; But %emit-per-frag-accumulate fired exactly ONE native K-step per fragment position: it
;;; read its operands at a hardcoded K tile-index 0.  Every shipped forward kernel got away
;;; with that by staging Kt = K_n = 8 and running the K-loop externally.  Stage anything
;;; WIDER and the surplus was silently ignored — no error, no warning, a wrong answer.
;;; (Measured on BMG: an 8x16 A-tile emitted ONE MulAdd and the host reference said
;;; MMA_WRONG.)
;;;
;;; The K-step count is COMPILE-TIME (scratch tile dims are compile-time constants), so this
;;; is a pure unroll — no new syntax, no runtime cost, and one-K-step tiles expand exactly as
;;; before.
;;;
;;; Spec: tests/spec/145-mma-autodiff/05-multi-k-step-tile-bmg.crisp
;;; ===================================================================
(defvar *mma-scratch-tile-dims* nil
  "Endeavor 145 P3a: alist (SYM ROWS COLS) of the SLM scratch tiles bound by the LET currently
   being exploded.  %emit-per-frag-accumulate reads it to learn a staged operand's K extent so it
   can walk K WITHIN the tile.  Bound by %explode-register-tiles; NIL elsewhere, in which case a
   staged operand is assumed to span exactly one native K-step (the pre-145 behaviour).

   A special variable rather than a threaded parameter so %explode-rewrite-body-form — which
   carries the endeavor-142 register block-load branches — does not have to change.")




(defun %mma-scratch-tile-dims-from-bindings (bindings)
  "Endeavor 145 P3a: the (SYM ROWS COLS) dims of every compile-time-shaped
   (V (make-scratch-matrix <elem> (ROWS COLS))) binding in BINDINGS.

   BUG 040: also records (V (make-scratch-matrix-ring <elem> (ROWS COLS) :ring-count N)),
   whose PER-SLOT shape sits at the same argument position.  Without it an MMA reading from
   a ring slot could not learn its operand's K extent and silently contracted over one
   native K-step.  Only the MATRIX ring is recognised -- vector and tensor rings are not
   valid 2-D MMA operands -- and the 2-integer-list guard filters anything else.

   Only literal integer 2-lists are recorded; a scratch tile whose shape is derived from another
   tensor contributes nothing and falls back to the one-K-step assumption."
  (loop for b in bindings
          when (and (consp b) (= (length b) 2) (symbolp (first b))
                    (consp (second b))
                    (or (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX")
                        (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX-RING"))
                    (let ((d (third (second b))))
                      (and (listp d) (= (length d) 2) (every #'integerp d))))
        collect (list (first b)
                      (first (third (second b)))
                      (second (third (second b))))))

(defun %mma-operand-extent (ref tiles which)
  "Endeavor 145 P3a: the compile-time extent (WHICH = :rows | :cols) of an
   mma-accumulate-via-tile operand REF, or NIL if not compile-time known.

   Handles both operand flavours: a register tile / ring slot (normalized to
   (V m n syms ...) by %resolve-tile-ref) and an SLM scratch tile (via
   *mma-scratch-tile-dims*).

   BUG 040: an SLM ring slot arrives as the FORM (ring-get RING SLOT) rather than a bare
   symbol, so it is unwrapped to RING before the *mma-scratch-tile-dims* lookup.  SLOT is
   intentionally not inspected: every slot has the same shape, so the extent does not depend
   on it, and demanding a compile-time slot would reject runtime-indexed SLM pipelines."
  (let ((rt (%resolve-tile-ref ref tiles)))
    (if rt
        (ecase which (:rows (second rt)) (:cols (third rt)))
        (let* ((sym (cond ((symbolp ref) ref)
                          ((and (consp ref)
                                (%head-name-eq (first ref) "RING-GET")
                                (>= (length ref) 2)
                                (symbolp (second ref)))
                           (second ref))
                          (t nil)))
               (sd (and sym (assoc sym *mma-scratch-tile-dims*))))
          (when sd
            (ecase which (:rows (second sd)) (:cols (third sd))))))))

(defun %mma-k-steps (a b tiles sk location)
  "Endeavor 145 P3a: how many native K-steps the staged operands span — A's COLUMN extent (Kt)
   divided by the instruction's K.  Defaults to 1 when the shape is not compile-time known,
   reproducing the pre-145 behaviour exactly.

   Also cross-checks the operands: A is Mt x Kt and B is Kt x Nt, so A's column extent must equal
   B's row extent.  Such a mismatch used to be silently truncated to one K-step; it is a hard error
   now, since it can only mean the staged tiles disagree about the contraction length."
  (let ((a-k (%mma-operand-extent a tiles :cols))
        (b-k (%mma-operand-extent b tiles :rows)))
    (when (and a-k b-k (/= a-k b-k))
      (error 'crisp-compiler-error
        :message (format nil "mma-accumulate-via-tile: operand K extents disagree — A is ~a wide but B is ~a tall.  A must be Mt x Kt and B must be Kt x Nt."
                         a-k b-k)
        :source-location location))
    (let ((kt (or a-k b-k)))
      (if (and kt (plusp sk)) (max 1 (floor kt sk)) 1))))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3b part 2: seeding a register accumulator from
;;; the output gradient.
;;;
;;; ROOT CAUSE this solves.  `store-tile` is a CL defmacro that scales tile-IDs by the
;;; tile's extents and expands to `store-tile-at`.  On the FORWARD path that expansion
;;; never happens — STORE-TILE has its own expression analyzer (analyze-store-tile-mma)
;;; and the SROA explosion matches the un-expanded form.  But the AD path runs ANF first,
;;; and anf-normalize (src/anf-transform.lisp:174) macroexpands ANY symbol carrying a
;;; macro-function before it reaches its own opaque-passthrough list — which DOES name
;;; "STORE-TILE" (line 187), so the intent was already there; the expansion just fires
;;; first and the entry is unreachable.
;;;
;;; The result for a REGISTER tile is nonsense in two ways: the coords become
;;; `(* (to-ulong G) (~ (extents~ C-tile) i))` and a register tile has no extents~, and
;;; the walk's scratch-tensor rule then emits %STORE-TILE-AT-BWD against C-TILE_ADJ,
;;; whose name no longer exists once the adjoint tile is SROA-exploded ("Unknown variable
;;; C-TILE_ADJ").
;;;
;;; FIXED IN THE WALK, NOT IN anf-normalize.  Removing STORE-TILE from that macroexpansion
;;; would change flat-anf for every SCRATCH-tile kernel that uses the sugar, and those rely
;;; on STORE-TILE-AT reaching the endeavor-111 rules — a silent gradient regression.  So the
;;; walk instead detects a register-tile store and recovers the original tile-IDs by
;;; unwrapping the scaling the macro applied.
;;; ===================================================================
(defun %emit-per-frag-acc-load (src tile-id entry)
  "Endeavor 145 P3b: per-fragment expansion of
   (%load-register-tile-acc TILE SRC (TY TX)) — the exact mirror of %emit-per-frag-store,
   reading each accumulator fragment back out of SRC with P2's load-fragment-acc instead of
   writing it.  This is where the fragment element->lane MAPPING finally becomes
   load-bearing: the seeded gradient is non-zero, so a wrong mapping changes the answer
   (unlike the zero-seed of P2's own spec)."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(set! ,fv (load-fragment-acc ,src
                                                     ((+ (* ,bty ,m-frags) ,mi-form)
                                                      (+ (* ,btx ,n-frags) ,nj-form)))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))
