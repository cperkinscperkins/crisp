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
      (multiple-value-bind (demand bytes) (%spv-kernel-register-demand kernel-name)
        (when (plusp demand)
          (let* ((default-mode (first modes))
                 (fitting      (find-if (lambda (mode) (<= demand mode)) modes))
                 (chosen       (or fitting (reduce #'max modes))))
            (setf (gethash kernel-name *kernel-register-mode*) chosen)
            (cond
              ((null fitting)
               (format *error-output*
                       "WARNING: kernel ~a needs ~a registers/thread (~a register-tile bytes / ~a B per GRF register), exceeding every selectable allocation ~a in the hardware profile — it will SPILL in any mode.  Reduce the register-tile shape, the ring depth, or distribute the tile across more warps (:warps).~%"
                       kernel-name demand bytes *spv-grf-register-bytes* modes))
              ((> demand default-mode)
               (format *error-output*
                       "NOTE: kernel ~a needs ~a registers/thread, above the default allocation of ~a — selecting the ~a-register mode.  (Larger allocations trade threads-per-EU for registers; without this the JIT would spill instead.)~%"
                       kernel-name demand default-mode chosen)))
            chosen))))))




;; src/mma.lisp
;;; ===================================================================
;;; Endeavour 165 step 3 — the fp64 MMA: operand loads + the m8n8k4 emitter.
;;;
;;; Step 2 made the register tile fp64-shaped.  This makes it MULTIPLY.
;;;
;;; LANE LAYOUTS ARE FROM CuTe, NOT FROM MEMORY.  MMA_Traits<SM80_8x8x4_F64F64F64F64_TN> gives
;;; ALayout = BLayout = SM80_8x4, i.e. A(M8,K4) at m = lane/4, k = lane%4 and B(N8,K4) at
;;; n = lane/4, k = lane%4, one double per lane.  The tf32 path already in this file reads B at
;;; rows tg and tg+4, column g = lane/4 -- the same family with K=8 instead of 4 -- so the two
;;; corroborate.  That is the only check available offline: NOTHING LOCAL CAN PROVE A LANE
;;; LAYOUT IS RIGHT.  A wrong one compiles, emits the right instruction, passes every mechanical
;;; check and computes garbage.  MMA_CORRECT on metal is the test, and this is the step that
;;; makes renting a pod worthwhile.
;;;
;;; THE INSTRUCTION NAME IS THE ONE VERIFIED SPELLING.  bin/llc.exe (LLVM 21.1.5, -mcpu=sm_90)
;;; lowers llvm.nvvm.mma.m8n8k4.row.col.f64 to a real mma.sync; the sm_90 f64 shapes
;;; (m16n8k4 / k8 / k16) assemble cleanly and emit an `.extern .func` CALL with NO diagnostic.
;;; So this name must never be checked by prefix -- 159 documented the same trap for the 16-bit
;;; spellings, where two plausible variants passed the verifier as unresolved external calls
;;; while still leaving an "mma.m16n8k16..." substring in the PTX.
;;;
;;; NOTE FOR THE SRC PATCH: %nvvm-frag-format REPLACES src/mma.lisp:203; %nvvm-frag-record
;;; REPLACES :216; register-mma-types REPLACES :230 (and supersedes the 2b-ii overlay copy);
;;; analyze-load-fragment-a REPLACES :552; analyze-load-fragment-b REPLACES :605;
;;; %emit-nvvm-mma-f64 is new; %emit-nvvm-mma REPLACES :821.
;;; ===================================================================

;; src/mma.lisp
(defun %nvvm-frag-format (llvm-elem-type)
  "Which MMA operand format a fragment field's LLVM type implies: :FP16, :BF16, :F64 or :TF32.

   Endeavour 159.  Kinds are read from LLVM at runtime rather than compared against a constant --
   the bindings carry +llvm-half-type-kind+ but no bfloat equivalent, and no llvm-c header is
   installed to take the value from.  Anything not otherwise recognised is the historical
   fp32-stored tf32 path.

   Endeavour 165 (step 3): :F64 joins them.  A double-typed field can only be an fp64 fragment --
   the tf32 path stores fp32 -- so the probe stays a pure function of the record's own LLVM type
   and no :elem has to be threaded down from the caller."
  (let ((k (llvm-get-type-kind llvm-elem-type)))
    (cond ((= k (llvm-get-type-kind (llvm-half-type)))   :fp16)
          ((= k (llvm-get-type-kind (llvm-bfloat-type))) :bf16)
          ((= k (llvm-get-type-kind (llvm-double-type))) :f64)
          ;; Endeavour 207: an i8 field can only be an int8 fragment (char and uchar alike).
          ((cffi:pointer-eq llvm-elem-type (llvm-int8-type)) :int8)
          (t :tf32))))

;; src/mma.lisp
(defun %nvvm-frag-record (operand elem)
  "The PTX fragment record name for OPERAND (:a or :b) at Crisp element type ELEM.

   Endeavour 159.  One place decides this, so analyze-load-fragment-a and -b cannot disagree
   about which record a given element type maps to.  A 32-bit (or unknown) element keeps the
   historical tf32 records.

   Endeavour 165 (step 3): fp64's m8n8k4 operands, A 8x4 and B 4x8, one double per lane each."
  (let ((bits (%mma-elem-bits elem))
        (name (or (%elem-prim-name elem) (and elem (symbolp elem) (symbol-name elem)))))
    (cond
      ;; Endeavour 207: int8 m16n8k32.  The record carries the sign (see register-mma-types).
      ((eql bits 8)
       (if (member name '("UCHAR" "UINT8") :test #'equal)
           (ecase operand (:a 'register-fragment-a-u8-16x32) (:b 'register-fragment-b-u8-32x8))
           (ecase operand (:a 'register-fragment-a-s8-16x32) (:b 'register-fragment-b-s8-32x8))))
      ((eql bits 64)
       (ecase operand (:a 'register-fragment-a-f64-8x4) (:b 'register-fragment-b-f64-4x8)))
      ((eql bits 16)
       (if (string= name "BFLOAT16")
           (ecase operand (:a 'register-fragment-a-bf16-16x16) (:b 'register-fragment-b-bf16-16x8))
           (ecase operand (:a 'register-fragment-a-f16-16x16)  (:b 'register-fragment-b-f16-16x8))))
      (t
       (ecase operand (:a 'register-fragment-a-tf32-16x8) (:b 'register-fragment-b-tf32-8x8))))))


(defun %frag-record-for-acc (elem)
  "The ACCUMULATOR fragment record for element type ELEM.

   Endeavour 165 (2b-ii).  Sibling of %frag-record-for-operand, which has dispatched A and B
   records by element type since endeavour 159; the accumulator was the one role still naming
   register-fragment-acc-f32-16x8 outright at five sites.  One place decides this, so the tile
   minter and the fragment constructor cannot disagree about which record an element type maps
   to -- the same argument 159 made for the operands.

   A 16-bit MMA accumulates in fp32, so half/bfloat16 keep the f32 record on purpose.

   Endeavour 204: integer register tiles existed on SPIR-V only.  Endeavour 207: on NVIDIA an int
   tile is the s32 accumulator of mma.sync m16n8k32 (a uint tile is refused)."
  ;; Endeavour 207: on NVIDIA an int register tile is the s32 accumulator of the sync int8 MMA.
  ;; mma.sync accumulates SIGNED 32-bit only, so a uint tile is still refused.
  (when (and (%elem-integer-p elem) (not (eq *target-backend* :spirv)))
    (unless (equal (%elem-prim-name elem) "INT")
      (error 'crisp-compiler-error
             :message (format nil "A ~(~a~) register tile has no NVIDIA lowering: mma.sync accumulates signed 32-bit, so declare the tile int."
                              (%canonical-elem elem))))
    (return-from %frag-record-for-acc 'register-fragment-acc-s32-16x8))
  (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
      'register-fragment-acc-f64-8x8
      'register-fragment-acc-f32-16x8))

(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float.

   Endeavour 159: the 16-bit m16n8k16 twins, fp16 and bf16.  A is 16x16 = 8 elements/lane, B is
   16x8 = 4, both ONE FIELD PER ELEMENT so the member count IS the element count that
   %map-elements-fragment-fields reads.  REGISTERS are half that at 16 bits (two elements per
   32-bit register) and are tracked separately by %ptx-note-register-demand.

   The ACCUMULATOR is deliberately NOT twinned: every 16-bit MMA here accumulates in fp32, so
   register-fragment-acc-f32-16x8 is reused unchanged -- the same reason %coop-elem-of does not
   route accumulators.

   Endeavor 144 Phase 0: also registers the BUILTIN hardware profiles, which must happen
   after initialize-compiler's clrhash of *hardware-profiles* — this is the first hook that
   runs there.  See register-builtin-hardware-profiles for the src-patch note."
  ;; Endeavour 165: the fp64 m8n8k4 family.  C/D is 8x8 = 64 elements over 32 lanes = 2
  ;; doubles per lane; A is 8x4 and B is 4x8 = 32 elements each = ONE double per lane.  These
  ;; match CUTLASS's own declarations for its single f64 tensor-op Mma (FragmentA/B =
  ;; Array<double,1>, FragmentC = Array<double,2>), which is a second source agreeing.
  ;; Fields are DOUBLE, not float: an fp64 MMA accumulates in fp64, unlike the 16-bit paths
  ;; which accumulate in fp32 and therefore reuse the f32 accumulator record.
  (register-struct-definition 'register-fragment-acc-f64-8x8
                              '((r0 double) (r1 double))
                              :record)
  (register-struct-definition 'register-fragment-a-f64-8x4
                              '((a0 double))
                              :record)
  (register-struct-definition 'register-fragment-b-f64-4x8
                              '((b0 double))
                              :record)
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record)
  ;; Endeavour 159 — fp16 m16n8k16.
  (register-struct-definition 'register-fragment-a-f16-16x16
                              '((a0 half) (a1 half) (a2 half) (a3 half)
                                (a4 half) (a5 half) (a6 half) (a7 half))
                              :record)
  (register-struct-definition 'register-fragment-b-f16-16x8
                              '((b0 half) (b1 half) (b2 half) (b3 half))
                              :record)
  ;; Endeavour 159 — bf16 m16n8k16, same shape, different encoding.
  (register-struct-definition 'register-fragment-a-bf16-16x16
                              '((a0 bfloat16) (a1 bfloat16) (a2 bfloat16) (a3 bfloat16)
                                (a4 bfloat16) (a5 bfloat16) (a6 bfloat16) (a7 bfloat16))
                              :record)
  (register-struct-definition 'register-fragment-b-bf16-16x8
                              '((b0 bfloat16) (b1 bfloat16) (b2 bfloat16) (b3 bfloat16))
                              :record)
  ;; Endeavour 207 -- int8 m16n8k32 (mma.sync).  A is 16x32 = 16 bytes per lane (4 registers), B is
  ;; 32x8 = 8 bytes per lane (2 registers), one field per element as for the 16-bit records.  The
  ;; SIGN lives in the record name (s8 / u8), because char and uchar are the same LLVM i8 and the
  ;; emitter must still choose between the .s8 and .u8 instructions.  The accumulator is s32 and
  ;; has the f32 accumulator's 16x8 lane layout exactly.
  (register-struct-definition 'register-fragment-a-s8-16x32
                              (loop for i below 16 collect (list (intern (format nil "A~d" i) :crisp.compiler) 'char))
                              :record)
  (register-struct-definition 'register-fragment-a-u8-16x32
                              (loop for i below 16 collect (list (intern (format nil "A~d" i) :crisp.compiler) 'uchar))
                              :record)
  (register-struct-definition 'register-fragment-b-s8-32x8
                              (loop for i below 8 collect (list (intern (format nil "B~d" i) :crisp.compiler) 'char))
                              :record)
  (register-struct-definition 'register-fragment-b-u8-32x8
                              (loop for i below 8 collect (list (intern (format nil "B~d" i) :crisp.compiler) 'uchar))
                              :record)
  (register-struct-definition 'register-fragment-acc-s32-16x8
                              '((r0 int) (r1 int) (r2 int) (r3 int))
                              :record)
  (register-builtin-hardware-profiles))


;; src/mma.lisp  (REPLACES register-builtin-hardware-profiles -- 156 Step 2: BMG offers :xe-native.
;; Must be done HERE and not by a top-level register-hardware-profile call: initialize-compiler
;; calls this function, so a top-level re-registration is overwritten a moment later.)
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
     :stream-bytes-in-flight 16            ; measured (180 probe 1): x4 fp32 / x2 fp64 streams
     ;; 156 Step 2: BMG offers a second code-generation strategy.  :coop-matrix stays FIRST
     ;; and is therefore still the default, so no existing kernel changes behaviour -- a
     ;; kernel gets :xe-native only by asking for it with (mma-lowering :xe-native).
     :mma-lowerings (:coop-matrix :xe-native)
     :mma-shapes ((8 16 8) (8 16 16) (8 16 32)))) ; XMX tf32, bf16/fp16, int8
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
     ;; THE ELEMENT TYPE IS A KEYWORD, NOT AN INTERNED SYMBOL, AND THAT IS LOAD-BEARING.
     ;; Writing it as `double` interns CRISP.COMPILER::DOUBLE, and the ACTIVE PROFILE IS
     ;; SERIALISED INTO EVERY .metacrisp -- so a plain tf32 kernel compiled with
     ;; --hardware-profile=h100 emitted `CRISP.COMPILER:DOUBLE` into its metadata, and
     ;; crisp-hoist-cuda (which has no such package) died reading it with "Package
     ;; CRISP.COMPILER does not exist".  That broke the CUDA hoist for EVERY benchmark chapter,
     ;; including ones with no doubles anywhere.  A keyword reads in any package.
     ;; The readers are unaffected: %mma-shape-for-elem compares SYMBOL-NAME, and
     ;; (symbol-name :double) is "DOUBLE" either way.
     ;; Endeavour 165: a TYPED fp64 entry, and it is load-bearing rather than tidy.  Without
     ;; it %mma-shape-for-elem falls to the width rule -- K x element-bits is a constant
     ;; fragment footprint -- and resolves `double` to (16 8 4).  That shape exists in the PTX
     ;; ISA but is NOT an NVVM intrinsic in LLVM 21.1.5: it assembles and llc emits an
     ;; `.extern .func` CALL with no diagnostic.  fp64 has exactly ONE tensor-core shape,
     ;; m8n8k4, so it is stated outright instead of being inferred from a rule that has no way
     ;; to know that.
     :mma-shapes ((16 8 8) (16 8 4) (16 8 16) (16 8 32) (:double 8 8 4)))))



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



(defun %spv-mma-shape (&optional elem)
  "The (values M N K) cooperative-matrix INSTRUCTION shape for the SPV path.

   Endeavour 155: takes an optional ELEMENT TYPE and selects the profile shape that matches it.
   The element type is genuinely part of the choice -- an fp16 fragment is not a tf32 fragment with
   different contents, it is a different instruction shape (K=16 vs K=8) -- and picking (first
   shapes) regardless is what produced 16-bit matrices in tf32 shapes, which no DPAS implements.

   ELEM is optional so the ~18 existing call sites that do not know an element type keep their
   previous behaviour exactly; only the sites that mint or load a typed fragment pass it."
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if (null shapes)
        (values 16 8 8)
        (let ((dims (or (and elem (%mma-shape-for-elem shapes elem))
                        (%mma-shape-entry-dims (first shapes)))))
          (if (and dims (= (length dims) 3))
              (values-list dims)
              (values 16 8 8))))))



;; src/mma.lisp
;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 2 — the call sites that KNOW the element type now pass it.
;;;;
;;;; %spv-mma-shape takes ELEM optionally, so the ~18 call sites that have no element type in hand
;;;; keep their exact previous behaviour.  These four are the ones that mint or load a typed
;;;; fragment, and they are the only ones whose answer was wrong:
;;;;
;;;;   analyze-make-register-fragment   the fill      -- :elem is already in its lambda list
;;;;   analyze-load-fragment-a / -b     the loads     -- element comes from the SOURCE TENSOR
;;;;   %explode-register-tiles          tile + ring   -- :elem from the tile constructor
;;;;
;;;; The two load analysers needed their nesting inverted: the shape was computed BEFORE the
;;;; tensor was analysed, so nothing yet knew what the shape was a shape of.  Analysing the tensor
;;;; first is the whole change; the body is otherwise untouched.
;;;; ------------------------------------------------------------------------------------------
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand elem tally).  :spirv -> a filled coop
   matrix; else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default
   acc) picks the coop-matrix Use + shape so an A/B operand tile mints fragments matching
   load-fragment-a/b.

   Endeavor 144: each fragment is tallied against the current kernel — as coop-matrix BYTES on
   SPV (Phase 4's GRF model) and as 32-bit REGISTERS on PTX (Phase 3's occupancy model).  Both
   skip when the form carries :tally nil, which marks fill-tile's per-fragment set!s: those
   RE-INITIALIZE fragments the tile already owns and allocate nothing.

   Endeavour 155: :elem carries the ELEMENT TYPE down from the register tile that generated this
   fragment, and reaches the coop-matrix component type and the GRF byte tally.  It defaults to
   FLOAT — exactly what every caller got before, since the type used to be discarded at
   make-register-tile and bf16 tiles silently produced float32 matrices.  The PTX branch is
   UNCHANGED: its fragment records are tf32/f32 by construction and endeavour 155 does not touch
   the NVIDIA path."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (elem    (getf kwargs :elem 'float))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)   ; 155 Phase C
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))
              (when tally-p (%spv-note-register-fragment fr fc context location elem))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%elem-coop-type elem) fr fc use) :kind :fill
               :value-node (analyze-expression init env context (append location '(1)))
               :rows fr :cols fc :use use :layout 0 :source-location location)))
          (progn
            ;; Endeavour 165 (2b-ii): the accepted geometry is the ELEMENT TYPE's own -- 16x8
            ;; for f32/tf32/16-bit-accumulate, 8x8 for fp64.  It was a flat 16x8 literal, which
            ;; refused every fp64 fragment before it could be built.
            (let ((want (%acc-frag-mn elem)))
              (unless (or (and (eql m (car want)) (eql n (cdr want)))
                          (member operand '(:a :b)))
                (error 'crisp-compiler-error
                       :message (format nil "make-register-fragment: ~a accumulator fragments are ~ax~a on this target (got ~a x ~a)." elem (car want) (cdr want) m n))))
            ;; PTX fragment register counts, matching the records minted below:
            ;; acc 16x8 f32 -> 4, A tf32 16x8 -> 4, B tf32 8x8 -> 2 (per lane, 32-bit each).
            ;; Endeavour 165 (2b-ii): an fp64 accumulator fragment is 2 doubles per lane = 4
            ;; 32-bit registers.  The SAME NUMBER as the f32 16x8 accumulator, but for a
            ;; different reason -- 2 values of 8 bytes rather than 4 of 4 -- so it is computed,
            ;; not inherited from the coincidence.
            (when tally-p
              (%ptx-note-register-demand
               (ecase operand
                 (:acc (let ((want (%acc-frag-mn elem)))
                         (/ (* (car want) (cdr want) (if (eql (%mma-elem-bits elem) 64) 2 1)) 32)))
                 (:a 4) (:b 2))
               context location))
            (analyze-expression
             (ecase operand
               (:acc (let* ((rec (%frag-record-for-acc elem))
                            (want (%acc-frag-mn elem))
                            (nvals (/ (* (car want) (cdr want)) 32)))
                       `(%construct-struct ,rec ,@(make-list nvals :initial-element init))))
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


;;;; ----------------------------------------------------------------------
;;;; Endeavour 207 -- a derived integer accumulator tile is stored through a raw cast
;;;; See tests/spec/207-int8-mma-bench/int8-mma-bench.md.
;;;; ----------------------------------------------------------------------

(defun %store-frag-elem-cast (elem form)
  "FORM, one fragment element being stored, raw-cast to ELEM when ELEM is a DERIVED integer type
   ((accum q-a) -> q-a-accum).  The s32 fragment record holds plain int; the destination element
   holds exactly its own type.  A plain element gets FORM back unchanged, so its code is as before.
   Endeavour 207 follow-up."
  (let ((c (%canonical-elem elem)))
    (if (and c (symbolp c) (%elem-integer-p c)
             (not (string= (symbol-name (resolve-type-alias c)) (or (%elem-prim-name c) ""))))
        (list (intern "TO" (find-package :crisp-language)) c form)
        form)))

(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes.

   Endeavour 196: FRAG may be (to-half F) / (to-bfloat16 F).  The conversion wraps each element
   read in the per-lane writes, so it costs one cvt per element at the store and nothing else.
   NVIDIA only: on SPIR-V the store is one CooperativeMatrixStoreKHR of the whole fragment, which
   would need the fragment converted first (OpFConvert on a cooperative matrix) -- not built.

   Endeavour 197: each lane's elements are adjacent column PAIRS (col, col+1), so on NVIDIA a pair
   is one (%store-pair ...) under a per-fragment (%pair-ok-p ...) of the lane's first pair; the
   scalar set!s are the fallback branch (odd origin, unaligned base, strided last dimension).  The
   row+8 pair shares the guard: 8 rows move the address by 8 x the row stride, an even number of
   elements.

   Endeavour 207 follow-up: an element of a DERIVED integer tile such as (accum q-a) is raw-cast
   to that type (%store-frag-elem-cast); the fragment record holds the primitive."
  ;; Endeavour 165 (2b-ii): an optional 4th argument carries the ELEMENT TYPE, supplied by
  ;; the store-tile walks (which know it) and defaulting to FLOAT for a hand-written
  ;; store-fragment.  The alternative -- inferring it from the fragment's own type -- would mean
  ;; analyzing FRAG once to ask, then again inside the rewritten form, and analyzing a form twice
  ;; is not safe in general.
  (destructuring-bind (frag-in dest tile-id &optional (elem 'float)) (cdr expr)
    (multiple-value-bind (frag convert) (%196-peel-store-conversion frag-in)
      (log:debug "196 store-fragment: convert=~a elem=~a target=~a" convert elem *target-backend*)
      (let ((ty (first tile-id)) (tx (second tile-id)))
        (if (eq *target-backend* :spirv)
            (progn
              (when convert
                (error 'crisp-compiler-error
                       :message (format nil "store-fragment / store-tile: (~(~a~) TILE) as a store source is not supported on SPIR-V yet.  The SPIR-V store is one CooperativeMatrixStoreKHR of the whole fragment, so the fragment would have to be converted first (OpFConvert on a cooperative matrix).  It is supported on PTX." convert)
                       :source-location location))
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
                   :source-location location))))
            (let ((if-sym (intern "IF" (find-package :crisp-language))))
            (flet ((elt-of (i) (%store-frag-elem-cast elem (%196-wrap-conversion convert `(%extract-struct-member frag-val ,i)))))
              (if (eql (%mma-elem-bits elem) 64)
                  ;; fp64 m8n8k4 C/D, decoded from CuTe MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>:
                  ;; CLayout = Layout<Shape<Shape<_4,_8>,_2>, Stride<Stride<_16,_1>,_8>> gives
                  ;; m = lane/4 and n = 2*(lane%4) + v for v in {0,1}.  Same column scheme as the
                  ;; tf32 fragment below (two adjacent columns at 2*(lane%4)); it differs only in
                  ;; having ONE row per lane instead of the g / g+8 pair, over a tile 8 rows tall.
                  (analyze-expression
                   `(let ((frag-val ,frag))
                      (let ((lane (to-int (warp-lane))))
                        (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                          (let ((row (+ (* ,ty 8) g)) (col (+ (* ,tx 8) t2)))
                            (,if-sym (%pair-ok-p (~ ,dest row col) (~ ,dest row (+ col 1)))
                              (%store-pair (~ ,dest row col) (~ ,dest row (+ col 1)) ,(elt-of 0) ,(elt-of 1))
                              (progn
                                (set! (~ ,dest row col)       ,(elt-of 0))
                                (set! (~ ,dest row (+ col 1)) ,(elt-of 1))))))))
                   env context location)
                  (analyze-expression
                   `(let ((frag-val ,frag))
                      (let ((lane (to-int (warp-lane))))
                        (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                          (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                            (,if-sym (%pair-ok-p (~ ,dest row col) (~ ,dest row (+ col 1)))
                              (progn
                                (%store-pair (~ ,dest row col) (~ ,dest row (+ col 1))
                                             ,(elt-of 0) ,(elt-of 1))
                                (%store-pair (~ ,dest (+ row 8) col) (~ ,dest (+ row 8) (+ col 1))
                                             ,(elt-of 2) ,(elt-of 3)))
                              (progn
                                (set! (~ ,dest row col)             ,(elt-of 0))
                                (set! (~ ,dest row (+ col 1))       ,(elt-of 1))
                                (set! (~ ,dest (+ row 8) col)       ,(elt-of 2))
                                (set! (~ ,dest (+ row 8) (+ col 1)) ,(elt-of 3))))))))
                   env context location)))))))))

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


;;;; ----------------------------------------------------------------------
;;;; Endeavour 207 -- a def-qint operand's int8 fragment reads are raw-cast to the record's primitive
;;;; See tests/spec/207-int8-mma-bench/int8-mma-bench.md.
;;;; ----------------------------------------------------------------------

(defun %frag-src-derived-p (probe elem)
  "T when the operand PROBE's SOURCE element type (a def-qint such as q-a) is not ELEM, the
   primitive its fragment record holds, so each read needs a raw cast.  Endeavour 207 follow-up."
  (let* ((canon (ignore-errors (%ts-canonicalize-tensor-type (get-single-value-type probe))))
         (src-elem (and (consp canon) (>= (length canon) 2) (second canon))))
    (and src-elem (symbolp src-elem) elem (symbolp elem)
         (not (string= (symbol-name src-elem) (symbol-name elem))))))

(defun %frag8-read (src elem cast-p rr cc)
  "One element read of an int8 fragment load: (~ SRC RR CC), raw-cast to ELEM when CAST-P.  A raw
   cast applies no scale -- the bytes are the bytes; the qint's scale lives in the accumulator's
   type.  Endeavour 207 follow-up."
  (if cast-p
      (list (intern "TO" (find-package :crisp-language)) elem (list '~ src rr cc))
      (list '~ src rr cc)))

(defun analyze-load-fragment-a (expr env context location)
  "Endeavour 207 follow-up: a def-qint operand's int8 reads are raw-cast to the
   fragment's primitive (%frag8-read).
   P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read.

   Endeavour 159: the NVIDIA branch DISPATCHES ON THE OPERAND'S ELEMENT WIDTH, using the same
   %coop-elem-of the SPV branch already used.  A 16-bit operand reads the m16n8k16 A layout
   (8 elements/lane) instead of the m16n8k8 tf32 one (4 floats/lane); fp16 and bf16 share that
   layout exactly and differ only in which record they fill.

   PTX ISA mma.m16n8k16 A layout, 32 lanes, groupID = lane/4, tid = lane%4.  Each lane holds
   8 elements as 4 register pairs, and the PAIR ORDER IS LOAD-BEARING -- it is the order the
   intrinsic's 4 A operands are consumed in:
       Ra0 = (groupID,   2*tid), (groupID,   2*tid+1)
       Ra1 = (groupID+8, 2*tid), (groupID+8, 2*tid+1)
       Ra2 = (groupID,   2*tid+8), (groupID,   2*tid+9)
       Ra3 = (groupID+8, 2*tid+8), (groupID+8, 2*tid+9)
   Note the K stride is 16 (not 8) and each lane spans TWO adjacent columns."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sn))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sm sk 0) :kind :load
               :tensor-node tnode
               :rows sm :cols sk :use 0 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tk) env context (append location '(3)))
               :source-location location)))
          ;; ---- NVIDIA / PTX ----
          (let* ((probe (analyze-expression src env context (append location '(1))))
                 (elem  (%coop-elem-of probe))
                 (frag-cast-p (%frag-src-derived-p probe elem))
                 (rec   (%nvvm-frag-record :a elem)))
            (if (eql (%mma-elem-bits elem) 64)
                ;; fp64 m8n8k4 A (8x4): m = lane/4, k = lane%4, ONE double per lane.
                ;; CuTe ALayout = SM80_8x4.  The tile coordinates scale by the fragment's own
                ;; extents -- 8 rows and 4 columns -- not by the tf32 path's 16 and 8.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 8) g)) (c (+ (* ,tk 4) tg)))
                        (%construct-struct ,rec (~ ,src r c)))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 8)
                ;; Endeavour 207: int8 m16n8k32 A (16x32).  PTX ISA: a0..a15 in four .b32 registers;
                ;; row = g (+8 for a4..a7, a12..a15), col = 4*tid + (i & 3) (+16 for a8..a15).
                ;; The 16-bit table with K doubled: each register holds FOUR adjacent K elements.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 32) (* tg 4))))
                        (%construct-struct ,rec
                          ,(%frag8-read src elem frag-cast-p 'r 'c)              ,(%frag8-read src elem frag-cast-p 'r '(+ c 1))        ,(%frag8-read src elem frag-cast-p 'r '(+ c 2))        ,(%frag8-read src elem frag-cast-p 'r '(+ c 3))
                          ,(%frag8-read src elem frag-cast-p '(+ r 8) 'c)        ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 1))  ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 2))  ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 3))
                          ,(%frag8-read src elem frag-cast-p 'r '(+ c 16))       ,(%frag8-read src elem frag-cast-p 'r '(+ c 17))       ,(%frag8-read src elem frag-cast-p 'r '(+ c 18))       ,(%frag8-read src elem frag-cast-p 'r '(+ c 19))
                          ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 16)) ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 17)) ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 18)) ,(%frag8-read src elem frag-cast-p '(+ r 8) '(+ c 19))))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 16) (* tg 2))))
                        (%construct-struct ,rec
                          (~ ,src r c)             (~ ,src r (+ c 1))
                          (~ ,src (+ r 8) c)       (~ ,src (+ r 8) (+ c 1))
                          (~ ,src r (+ c 8))       (~ ,src r (+ c 9))
                          (~ ,src (+ r 8) (+ c 8)) (~ ,src (+ r 8) (+ c 9))))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
                        (%construct-struct ,rec
                          (~ ,src r c) (~ ,src (+ r 8) c) (~ ,src r (+ c 4)) (~ ,src (+ r 8) (+ c 4))))))
                 env context location)))))))))

(defun analyze-load-fragment-b (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,
   8x8, col-major); else the NVIDIA per-lane read.

   Endeavour 159: 16-bit dispatch, mirroring load-fragment-a.  PTX ISA mma.m16n8k16 B layout
   (16x8), 32 lanes, groupID = lane/4, tid = lane%4; each lane holds 4 elements as 2 pairs, and
   the pair order is the intrinsic's B operand order:
       Rb0 = (2*tid,   groupID), (2*tid+1, groupID)
       Rb1 = (2*tid+8, groupID), (2*tid+9, groupID)
   B is K-major here (K=16 rows, N=8 cols), so the ROW stride is what doubles, not the column."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sm))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sk sn 1) :kind :load
               :tensor-node tnode
               :rows sk :cols sn :use 1 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,tk) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          ;; ---- NVIDIA / PTX ----
          (let* ((probe (analyze-expression src env context (append location '(1))))
                 (elem  (%coop-elem-of probe))
                 (frag-cast-p (%frag-src-derived-p probe elem))
                 (rec   (%nvvm-frag-record :b elem)))
            (if (eql (%mma-elem-bits elem) 64)
                ;; fp64 m8n8k4 B (4x8): k = lane%4, n = lane/4, ONE double per lane.
                ;; CuTe BLayout = SM80_8x4, the same layout as A with N in M's place.  Compare
                ;; the tf32 branch below, which reads rows tg and tg+4 at column g: same family,
                ;; but K=4 leaves exactly one element per lane instead of two.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 4) tg)) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec (~ ,src r c)))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 8)
                ;; Endeavour 207: int8 m16n8k32 B (32x8).  PTX ISA: b0..b7 in two .b32 registers;
                ;; row = 4*tid + (i & 3) (+16 for b4..b7), col = g.  K-major, so the ROW doubles.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 32) (* tg 4))) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec
                          ,(%frag8-read src elem frag-cast-p 'r 'c)        ,(%frag8-read src elem frag-cast-p '(+ r 1) 'c)  ,(%frag8-read src elem frag-cast-p '(+ r 2) 'c)  ,(%frag8-read src elem frag-cast-p '(+ r 3) 'c)
                          ,(%frag8-read src elem frag-cast-p '(+ r 16) 'c) ,(%frag8-read src elem frag-cast-p '(+ r 17) 'c) ,(%frag8-read src elem frag-cast-p '(+ r 18) 'c) ,(%frag8-read src elem frag-cast-p '(+ r 19) 'c)))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 16) (* tg 2))) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec
                          (~ ,src r c)       (~ ,src (+ r 1) c)
                          (~ ,src (+ r 8) c) (~ ,src (+ r 9) c)))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec
                          (~ ,src r c) (~ ,src (+ r 4) c)))))
                 env context location)))))))))



(defun %prefetch-block-shape (elem-bytes location)
  "The legal Subgroup2DBlockPrefetchINTEL block shape (ROWS . COLS) for an ELEM-BYTES element.

   Only verified widths are supported, and anything else is a REFUSAL rather than a guess: the
   legal shape is element-width dependent, a 16-bit block is at most 16 COLUMNS wide, and an
   illegal :size resolves to an IGC builtin that does not exist (e.g.
   __internal_intel_sub_group_2d_block_prefetch_16b_32r32x1c).  That fails at MODULE BUILD, long
   after compilation, with a message about a missing symbol rather than about the kernel -- see
   benchmarks/matmul/_kdepth/pf1_k32.crisp.  Refusing here converts it into a compile-time error
   that names the cause.

   2 bytes: 32x16 is the shape verified in use.  A 16x16 block would let a 128x32 footprint tile
   into exactly 16 blocks -- one per warp, with no duplication (see %prefetch-warp-plan) -- but its
   legality is unverified and can only be established on metal, so it is not assumed here.

   1 byte (Endeavour 207): 32x32 -- 32 rows of 32 bytes, the same 32-byte row as the 16-bit block.
   Verified with ocloc (-device bmg) on 2026-11-03: every 8-bit block of height <= 32 and width
   <= 64 builds (1x32, 8x32, 16x32, 32x16, 32x32, 32x64, 16x64, 4x64), while 64x32, 256x32 and
   32x128 fail with 'For element size of 8 bits, unsupported block configuration'."
  (case elem-bytes
    (2 (cons 32 16))
    (1 (cons 32 32))
    (t (error 'crisp-compiler-error
         :message (format nil "prefetch-tile :warp-partitioned is implemented for 1- and 2-byte ~
                               operands (char / uchar, bfloat16 / half) only, got a ~a-byte element.  ~
                               The legal 2D block prefetch shape is element-width dependent, and an ~
                               illegal one fails at MODULE BUILD rather than at compile time, so Crisp ~
                               refuses rather than guessing.  Omit :warp-partitioned to keep the ~
                               unpartitioned one-block-per-subgroup behaviour." elem-bytes)
         :source-location location))))

;; src/mma.lisp
(defun %prefetch-warp-plan (h w br bc n-warps location)
  "Plan the distribution of an H x W footprint over N-WARPS, in BR x BC hardware blocks.
   Returns (values NBY NBX N-BLOCKS ROUNDS).

   ROUNDS is how many prefetches each warp issues: ceiling(n-blocks / n-warps).  Warp w handles
   block (w + j*n-warps) mod n-blocks for j below ROUNDS.

   THE `mod n-blocks` IS LOAD-BEARING AND IS NOT A ROUNDING ERROR.  Irregularity is the normal
   case, not an edge case -- in the shipped fp16 geometry the A footprint (128x32) is 8 blocks over
   16 warps while the B footprint (32x256) is exactly 16.  Both occur in ONE kernel.  When there
   are fewer blocks than warps the surplus warps re-prefetch a block someone else already asked
   for.  That DUPLICATION IS DELIBERATE: a prefetch is a hint, so the cost is one instruction and a
   second touch of an already-warm line, whereas the alternative -- letting surplus warps idle --
   needs a branch, and a branch around a prefetch is BUG 051."
  (unless (and (plusp h) (plusp w) (zerop (mod h br)) (zerop (mod w bc)))
    (error 'crisp-compiler-error
      :message (format nil "prefetch-tile :warp-partitioned: a ~ax~a footprint does not tile into ~
                            whole ~ax~a hardware prefetch blocks.  H must be a multiple of ~a and W ~
                            a multiple of ~a.  Rounding the footprint up would prefetch memory the ~
                            kernel never reads; truncating it would leave part of the operand ~
                            unwarmed and silently cost the speed the keyword exists to buy."
                       h w br bc br bc)
      :source-location location))
  (let* ((nby (floor h br))
         (nbx (floor w bc))
         (n-blocks (* nby nbx))
         (rounds (ceiling n-blocks n-warps)))
    (values nby nbx n-blocks rounds)))

(defun analyze-prefetch-tile (expr env context location)
  "Endeavor 142 (Phase B): (prefetch-tile SRC (COORD-Y COORD-X) :size (H W) &key warp-partitioned)
   -> an Intel 2D block cache prefetch (Subgroup2DBlockPrefetchINTEL).  A fire-and-forget hint with
   NO destination -- it warms the LSC so a subsequent register block-load (load-tile -> GRF) hits
   cache instead of stalling on global memory; it never changes results.  Intel/SPV-only +
   hardware-profile-required.  Lowered by reusing the coop-op node with a :prefetch kind.

   Endeavour 158: :warp-partitioned distributes the footprint across the workgroup's warps, each
   warp computing its own block index from warp-id.  See the block comment above.

   Endeavour 192: a per-operation :cache key is refused (the hint comes from SRC's type)."
  ;; Endeavour 192: the cache hint comes from SRC's type; a per-operation :cache is refused.
  (%refuse-per-operation-cache "prefetch-tile" (nthcdr 3 expr) location)
  (unless (active-hardware-profile)
    (error 'crisp-compiler-error
      :message "prefetch-tile requires a hardware profile (pass --hardware-profile): its L1 / GRF limits drive the register-pipeline safety analysis."
      :source-location location))
  (unless (eq *target-backend* :spirv)
    (error 'crisp-compiler-error
      :message "prefetch-tile lowers to Subgroup2DBlockPrefetchINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping (NVIDIA's prefetch model is cp.async into SLM, a different concept)."
      :source-location location))
  (destructuring-bind (src coords &key size warp-partitioned) (cdr expr)
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
           ;; `true` reads as a symbol; accept 1 as well, matching %normalize-warp-mask.
           (partition-p (and warp-partitioned
                             (not (eql warp-partitioned 0))
                             (not (and (symbolp warp-partitioned)
                                       (string-equal (symbol-name warp-partitioned) "FALSE"))))))
      (if (not partition-p)
          ;; ---- unpartitioned: one block, every subgroup issues it.  UNCHANGED. ----
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (make-semantic-coop-op
             :type 'void :kind :prefetch
             :tensor-node tnode
             :rows h :cols w :use 0 :layout (%coop-layout-of tnode)
             :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
             :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
             :source-location location))
          ;; ---- partitioned: tile the footprint, each warp computes its own block index ----
          (let ((n-warps (%resolve-workgroup-warp-count context)))
            (unless n-warps
              (error 'crisp-compiler-error
                :message "prefetch-tile :warp-partitioned needs the workgroup's warp count (local-size / simd-width), and this kernel's local-size is not known at compile time.  Declare (local-size :set-to N).  Crisp refuses rather than falling back to an unpartitioned prefetch, because that fallback is exactly the every-subgroup-issues-everything behaviour the keyword exists to remove -- it would be a silent 16x over-issue rather than an error."
                :source-location location))
            (let* ((tnode (analyze-expression src env context (append location '(1))))
                   (elem-bytes (%elem-bytes (%coop-elem-of tnode)))
                   (shape (%prefetch-block-shape elem-bytes location))
                   (br (car shape)) (bc (cdr shape)))
              (multiple-value-bind (nby nbx n-blocks rounds)
                  (%prefetch-warp-plan h w br bc n-warps location)
                (let* ((cl        (find-package :crisp-language))
                       (progn-sym (intern "PROGN" cl))    (let-sym    (intern "LET" cl))
                       (plus-sym  (intern "+" cl))        (times-sym  (intern "*" cl))
                       (div-sym   (intern "/" cl))        (rem-sym    (intern "REM" cl))
                       (to-int-sym (intern "TO-INT" cl))  (warp-id-sym (intern "WARP-ID" cl))
                       (pf-sym    (intern "PREFETCH-TILE" cl))
                       (wp (gensym "WP")) (by (gensym "BY")) (bx (gensym "BX")))
                  (log:debug "prefetch-tile :warp-partitioned: ~ax~a -> ~ax~a blocks of ~ax~a, ~a block~:p ~
                              over ~a warps, ~a round~:p each" h w nby nbx br bc n-blocks n-warps rounds)
                  (labels ((bi (j)
                             ;; this warp's block index for round J: (wp + j*n-warps) mod n-blocks
                             (let ((raw (if (zerop j) wp `(,plus-sym ,wp ,(* j n-warps)))))
                               `(,rem-sym ,raw ,n-blocks))))
                    (analyze-expression
                     `(,let-sym ((,wp (,to-int-sym (,warp-id-sym)))
                                 (,by (,to-int-sym ,ty))
                                 (,bx (,to-int-sym ,tx)))
                        (,progn-sym
                         ,@(loop for j below rounds
                                 collect `(,pf-sym ,src
                                                   ((,plus-sym (,times-sym ,by ,nby)
                                                               (,div-sym ,(bi j) ,nbx))
                                                    (,plus-sym (,times-sym ,bx ,nbx)
                                                               (,rem-sym ,(bi j) ,nbx)))
                                                   :size (,br ,bc)))))
                     env context location))))))))))

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



;;; ===================================================================
;;; Endeavour 165 step 3 (cont) — mma-accumulate's RESULT TYPE follows its C operand.
;;;
;;; analyze-mma-accumulate typed its node as register-fragment-acc-f32-16x8 outright, so an fp64
;;; accumulate reported an f32 accumulator and the walk refused it:
;;;   "Type mismatch! Expected REGISTER-FRAGMENT-ACC-F64-8X8 but inferred
;;;    REGISTER-FRAGMENT-ACC-F32-16X8."
;;; Another loud refusal finding a hardcode, which is the pattern this endeavour keeps repeating.
;;;
;;; The fix is not "add an fp64 case" but to state the actual rule: an MMA accumulate returns an
;;; accumulator OF THE SAME TYPE AS ITS C OPERAND.  That was always true; it was merely
;;; unexpressible while only one accumulator record existed.  Written that way it needs no
;;; further edit when a third accumulator type appears.
;;; ===================================================================

;; src/mma.lisp
(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop matrix on
   :spirv, else the SAME RECORD AS C.  Codegen forks in generate-node-ir.

   Endeavour 165 (step 3): the NVIDIA type was hardcoded to the fp32 record, which made an fp64
   accumulate mistype itself.  Deriving it from C states the real rule and covers any accumulator
   record, present or future.  The fallback keeps the historical answer when C's type cannot be
   resolved to an accumulator record.

   Endeavour 204: on :spirv too, C's type is the answer when it is a coop matrix, and the three
   element types are checked against each other."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (let* ((c-node (analyze-expression c-arg env context location))
           (c-type (get-single-value-type c-node))
           (a-node (analyze-expression a-arg env context location))
           (b-node (analyze-expression b-arg env context location)))
      (flet ((coop-p (ty) (and (consp ty) (eq (first ty) 'coop-matrix))))
        (when (and (coop-p c-type) (coop-p (semantic-node-type a-node)) (coop-p (semantic-node-type b-node)))
          (%check-mma-element-family (second (semantic-node-type a-node)) (second (semantic-node-type b-node))
                                     (second c-type) location))
        (make-semantic-mma-accumulate
         :type (if (eq *target-backend* :spirv)
                   (if (coop-p c-type)
                       c-type
                       (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                         (declare (ignore sk)) (list 'coop-matrix 'float sm sn 2)))
                   (if (and c-type (symbolp c-type)
                            (search "REGISTER-FRAGMENT-ACC-" (symbol-name c-type)))
                       c-type
                       'register-fragment-acc-f32-16x8))
         :c-node c-node
         :a-node a-node
         :b-node b-node
         :source-location location)))))



(defun %emit-nvvm-mma-f64 (builder module a-val b-val c-val)
  "Emit the fp64 tensor-core MMA: llvm.nvvm.mma.m8n8k4.row.col.f64.

   Endeavour 165 step 3.  Operands are ONE double each and the accumulator is TWO, so unlike the
   tf32 and 16-bit paths there is no packing, no bitcast and no vector: doubles are passed as
   doubles.  That is the whole reason this is a separate function rather than another arm of
   %emit-nvvm-mma's operand-format cond -- it shares none of that machinery.

   THE NAME IS THE ONE VERIFIED SPELLING.  On bin/llc.exe (LLVM 21.1.5, -mcpu=sm_90) this lowers
   to `mma.sync.aligned.m8n8k4.row.col.f64.f64.f64.f64`, while the sm_90 f64 shapes
   (m16n8k4 / k8 / k16) assemble cleanly and emit an `.extern .func` CALL with no diagnostic at
   all.  A wrong spelling here is therefore SILENT, so this must never be checked by prefix --
   the same trap endeavour 159 documented for the 16-bit names."
  (let* ((f64 (llvm-double-type))
         (a0  (llvm-build-extract-value builder a-val 0 "fa0"))
         (b0  (llvm-build-extract-value builder b-val 0 "fb0"))
         (c-ops (loop for i below 2
                      collect (llvm-build-extract-value builder c-val i (format nil "fc~d" i))))
         (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                   (dotimes (i 2) (setf (cffi:mem-aref elts 'llvm-type-ref i) f64))
                   (llvm-struct-type-in-context (llvm-get-module-context module) elts 2 nil)))
         (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                  (dotimes (i 4) (setf (cffi:mem-aref arr 'llvm-type-ref i) f64))
                  (llvm-function-type ret-ty arr 4 nil)))
         (fn-name "llvm.nvvm.mma.m8n8k4.row.col.f64")
         (fn (let ((existing (llvm-get-named-function module fn-name)))
               (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
         (args (list* a0 b0 c-ops))
         (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 4)))
                     (loop for i from 0 for v in args
                           do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                     arr))
         (call (llvm-build-call2 builder fn-ty fn args-arr 4 "mmad"))
         (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f64-8x8 module))
         (result (let ((agg (llvm-get-undef acc-ty)))
                   (dotimes (i 2)
                     (setf agg (llvm-build-insert-value builder agg
                                (llvm-build-extract-value builder call i (format nil "fd~d" i))
                                i (format nil "facc~d" i))))
                   agg)))
    (values result nil)))

;;;; ----------------------------------------------------------------------
;;;; Endeavour 207 -- mma.sync int8 (m16n8k32): operand signs ride the fragment RECORD
;;;; See tests/spec/207-int8-mma-bench/int8-mma-bench.md.
;;;; ----------------------------------------------------------------------

(defvar *nvvm-int8-signs* nil
  "(A-SIGNED . B-SIGNED) for the sync int8 MMA being emitted, or NIL (= both signed).  Bound by the
   generate-node-ir :around method on semantic-mma-accumulate, because the emitter receives only LLVM
   values and char / uchar are the same LLVM i8.")

(defun %nvvm-int8-signs-of (node)
  "(A-SIGNED . B-SIGNED) of a sync MMA node, read from its operand FRAGMENT RECORD names (-U8- is
   unsigned).  NIL when the operands are not int8 fragments."
  (flet ((sign (n)
           (let ((ty (and n (semantic-node-type n))))
             (and ty (symbolp ty)
                  (let ((nm (symbol-name ty)))
                    (cond ((search "-U8-" nm) :u)
                          ((search "-S8-" nm) :s)))))))
    (let ((sa (sign (semantic-mma-accumulate-a-node node)))
          (sb (sign (semantic-mma-accumulate-b-node node))))
      (when (or sa sb)
        (cons (not (eq sa :u)) (not (eq sb :u)))))))

(defun %emit-nvvm-mma-int8 (builder module a-val b-val c-val)
  "The NVIDIA sync int8 MMA: llvm.nvvm.mma.m16n8k32.row.col.{s8|u8}[.{s8|u8}], s32 accumulate.

   OPERANDS ARE PACKED BYTES.  Each 32-bit register holds four adjacent K elements; they are built as
   a <4 x i8> with the LOWER-numbered element in lane 0 (the order the ISA tables list them and the
   order analyze-load-fragment-a/-b fill the fields in) and bitcast to i32, which puts element 0 in
   the low byte.  A is 4 registers, B is 2, C/D are 4 x i32.

   THE NAME.  Same-sign pairs are spelled once (.s8, .u8); mixed pairs name both (.s8.u8, .u8.s8).
   All four lower to mma.sync.aligned.m16n8k32.row.col.s32.<a>.<b>.s32 on bin/llc.exe -mcpu=sm_80
   (checked 2026-11-03).  As with every NVVM MMA name, a wrong spelling is SILENT (an external call),
   so the spec validator matches the full mnemonic.  No .satfinite: the accumulator wraps, as the
   wgmma integer path does."
  (let* ((i8  (llvm-int8-type))
         (i32 (llvm-int32-type))
         (v4  (llvm-vector-type i8 4))
         (a-elems (loop for i below 16 collect (llvm-build-extract-value builder a-val i (format nil "a~d" i))))
         (b-elems (loop for i below 8  collect (llvm-build-extract-value builder b-val i (format nil "b~d" i))))
         (pack (lambda (elems name)
                 (let ((v (llvm-get-undef v4)))
                   (loop for e in elems for j from 0
                         do (setf v (llvm-build-insert-element builder v e (llvm-const-int i32 j nil)
                                                               (format nil "~a_~d" name j))))
                   (llvm-build-bit-cast builder v i32 (format nil "~a_i" name)))))
         (a-ops (loop for r below 4 collect (funcall pack (subseq a-elems (* 4 r) (+ 4 (* 4 r))) (format nil "av~d" r))))
         (b-ops (loop for r below 2 collect (funcall pack (subseq b-elems (* 4 r) (+ 4 (* 4 r))) (format nil "bv~d" r))))
         (c-ops (loop for i below 4 collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
         (signs (or *nvvm-int8-signs* (cons t t)))
         (sa (if (car signs) "s8" "u8"))
         (sb (if (cdr signs) "s8" "u8"))
         (fn-name (if (string= sa sb)
                      (format nil "llvm.nvvm.mma.m16n8k32.row.col.~a" sa)
                      (format nil "llvm.nvvm.mma.m16n8k32.row.col.~a.~a" sa sb)))
         (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                   (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) i32))
                   (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
         (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                  (dotimes (i 10) (setf (cffi:mem-aref arr 'llvm-type-ref i) i32))
                  (llvm-function-type ret-ty arr 10 nil)))
         (fn (let ((existing (llvm-get-named-function module fn-name)))
               (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
         (args (append a-ops b-ops c-ops))
         (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                     (loop for i from 0 for v in args do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                     arr))
         (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma8"))
         (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-s32-16x8 module))
         (result (let ((agg (llvm-get-undef acc-ty)))
                   (dotimes (i 4)
                     (setf agg (llvm-build-insert-value builder agg
                                (llvm-build-extract-value builder call i (format nil "d~d" i))
                                i (format nil "acc~d" i))))
                   agg)))
    (log:debug "207 %emit-nvvm-mma-int8: ~a" fn-name)
    (values result nil)))

(defmethod generate-node-ir :around ((node semantic-mma-accumulate) builder module var-env di-builder di-scope location-map)
  "Endeavour 207: binds *nvvm-int8-signs* for the sync int8 emitter (NVIDIA only)."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (let ((*nvvm-int8-signs* (unless (eq *target-backend* :spirv) (%nvvm-int8-signs-of node))))
    (when *nvvm-int8-signs*
      (log:debug "207 sync int8 MMA signs: ~a" *nvvm-int8-signs*))
    (call-next-method)))

(defun %emit-nvvm-mma (builder module a-val b-val c-val)
  "The NVIDIA sync MMA.  Endeavour 159: dispatches on the A fragment's ELEMENT TYPE, emitting
   the tf32 m16n8k8, fp16 m16n8k16, or bf16 m16n8k16 instruction.  Returns (values acc nil).

   DETECTION is by probing the LLVM type of A's field 0 rather than by threading an :elem down:
   the caller (generate-node-ir on semantic-mma-accumulate) passes only LLVM values, and the
   fragment record already carries the answer.  The probe extract is REUSED as a0, so it costs
   no dead instruction.

   THE THREE PATHS DIFFER IN OPERAND REPRESENTATION, and that is the trap on this rung:
     tf32  i32          -- each float bitcast to i32
     fp16  <2 x half>   -- pairs packed into a vector, handed over AS a vector
     bf16  i32          -- pairs packed into <2 x bfloat> and then BITCAST to i32
   All three were verified by compiling a standalone .ll through clang --target=nvptx64 and
   reading the emitted mnemonic.  Two plausible spellings (...f16.f32, ...bf16.f32) pass the
   LLVM verifier as UNRESOLVED EXTERNAL CALLS -- they emit no instruction while still leaving an
   'mma.m16n8k16...' substring in the PTX -- so nothing here may be checked by prefix.

   Fragment records declare ONE FIELD PER ELEMENT, so all pair-packing happens HERE and only
   here.  The pairing order follows the PTX ISA register order documented on
   analyze-load-fragment-a/-b; those must agree, and nothing local can prove they do --
   MMA_CORRECT on metal is what checks it.

   The ACCUMULATOR is f32 in every path here: a 16-bit MMA accumulates in fp32.  fp64 is the
   exception and accumulates in fp64, which is one more reason it lives in its own emitter."
  (let* ((f32 (llvm-float-type))
         (i32 (llvm-int32-type))
         (a0  (llvm-build-extract-value builder a-val 0 "a0"))
         (fmt (%nvvm-frag-format (llvm-type-of a0))))
    (if (eq fmt :int8)
        ;; Endeavour 207: packed bytes, s32 accumulate -- its own emitter.
        (%emit-nvvm-mma-int8 builder module a-val b-val c-val)
    (if (eq fmt :f64)
        ;; Endeavour 165 step 3: fp64 shares none of the packing below -- one double per operand,
        ;; two for the accumulator -- so it is its own emitter rather than another arm here.
        (%emit-nvvm-mma-f64 builder module a-val b-val c-val)
    (if (eq fmt :tf32)
        ;; ---------------- tf32 m16n8k8 (unchanged) ----------------
        (let* ((a-ops (cons (llvm-build-bit-cast builder a0 i32 "a0i")
                            (loop for i from 1 below 4 collect
                                  (llvm-build-bit-cast builder (llvm-build-extract-value builder a-val i (format nil "a~d" i)) i32 (format nil "a~di" i)))))
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
          (values result nil))
        ;; ---------------- 16-bit m16n8k16 (fp16 / bf16) ----------------
        (let* ((bf16-p  (eq fmt :bf16))
               (elem-ty (if bf16-p (llvm-bfloat-type) (llvm-half-type)))
               (vec-ty  (llvm-vector-type elem-ty 2))
               ;; fp16 hands the vector straight to the intrinsic; bf16 must bitcast it to i32.
               (op-ty   (if bf16-p i32 vec-ty))
               (a-elems (cons a0 (loop for i from 1 below 8
                                       collect (llvm-build-extract-value builder a-val i (format nil "a~d" i)))))
               (b-elems (loop for i below 4
                              collect (llvm-build-extract-value builder b-val i (format nil "b~d" i))))
               (pack (lambda (lo hi name)
                       ;; lane 0 is the LOWER-numbered element -- the order the ISA tables list
                       ;; the pair in, and the order load-fragment-a/-b fills the fields in.
                       (let ((v (llvm-get-undef vec-ty)))
                         (setf v (llvm-build-insert-element builder v lo (llvm-const-int i32 0 nil)
                                                            (format nil "~a_0" name)))
                         (setf v (llvm-build-insert-element builder v hi (llvm-const-int i32 1 nil)
                                                            (format nil "~a_1" name)))
                         (if bf16-p
                             (llvm-build-bit-cast builder v i32 (format nil "~a_i" name))
                             v))))
               (a-ops (loop for i below 4
                            collect (funcall pack (nth (* 2 i) a-elems) (nth (1+ (* 2 i)) a-elems)
                                             (format nil "av~d" i))))
               (b-ops (loop for i below 2
                            collect (funcall pack (nth (* 2 i) b-elems) (nth (1+ (* 2 i)) b-elems)
                                             (format nil "bv~d" i))))
               (c-ops (loop for i below 4 collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
               (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                         (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) f32))
                         (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
               (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                        (loop for i from 0 for ty in (list op-ty op-ty op-ty op-ty op-ty op-ty f32 f32 f32 f32)
                              do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                        (llvm-function-type ret-ty arr 10 nil)))
               (fn-name (if bf16-p
                            "llvm.nvvm.mma.m16n8k16.row.col.bf16"
                            "llvm.nvvm.mma.m16n8k16.row.col.f32.f32"))
               (fn (let ((existing (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
               (args (append a-ops b-ops c-ops))
               (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                           (loop for i from 0 for v in args do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                           arr))
               (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma16"))
               (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f32-16x8 module))
               (result (let ((agg (llvm-get-undef acc-ty)))
                         (dotimes (i 4)
                           (setf agg (llvm-build-insert-value builder agg
                                      (llvm-build-extract-value builder call i (format nil "d~d" i))
                                      i (format nil "acc~d" i))))
                         agg)))
          (values result nil)))))))


(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Dispatches to %coop-mma-impl on the active lowering.  Kept as a plain function with its
   original signature so no call site changes."
  (%coop-mma-impl *mma-lowering* builder module a-val b-val c-val elem-llvm m n k))



(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type; swizzle/k from table).
   Endeavour 198: the table entry's 4th element (B-MAJOR) reaches %emit-nvvm-wgmma."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (progn
            ;; Endeavor 140 (precision): wgmma is tf32 by construction, so under a non-fast
            ;; precision context the requested IEEE accuracy is silently NOT honored (results are
            ;; tf32).  Warn.  *math-precision* here is the resolved effective precision at codegen
            ;; — it already respects the full chain (force > with-precision > declaim > flag >
            ;; default(:ieee)), the same value that stamps the fast-math flags in codegen.lisp.
            ;; Endeavour 160: the tf32 precision warning is only true for a 32-bit operand.
            ;; A bf16/fp16 wgmma is not silently downgrading anything -- the kernel ASKED for
            ;; 16-bit inputs -- so firing it there would be noise that teaches the reader
            ;; something untrue.
            (unless (or (eq *math-precision* :fast)
                        (member (%mma-elem-bits (third (gethash node *wgmma-node-swizzle*))) (quote (8 16))))
              (format *error-output*
                      "WARNING: wgmma-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                      *math-precision*))
          (destructuring-bind (&optional swizzle-mode (k 8) elem (b-major :k)) (gethash node *wgmma-node-swizzle*)
            (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                  (swizzle-p (and swizzle-mode (string-equal (string swizzle-mode) "128B"))))
              (multiple-value-bind (av al a-ptr) (gen (semantic-mma-accumulate-a-node node))
                (declare (ignore av al))
                (multiple-value-bind (bv bl b-ptr) (gen (semantic-mma-accumulate-b-node node))
                  (declare (ignore bv bl))
                  (unless (and a-ptr b-ptr)
                    (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                  (let ((*wgmma-b-elem* (gethash node *wgmma-node-b-elem*))) (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                    (second (gethash acc-type *wgmma-acc-dims*)) swizzle-p k elem b-major)))))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (let ((*coop-mma-signs* (%coop-sign-mask (semantic-mma-accumulate-a-node node) (semantic-mma-accumulate-b-node node) (semantic-mma-accumulate-c-node node))))
                    (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil)))
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

;;; ===================================================================
;;; Endeavour 165 step 2a — thread the ELEMENT TYPE through the register-tile path.
;;;
;;; NO GEOMETRY CHANGES HERE.  %acc-frag-mn returns 16x8 for every element type, so the emitted
;;; code is byte-identical to before; this step only makes the element type REACHABLE at the
;;; sites that will need it.  Step 2b changes %acc-frag-mn alone.
;;;
;;; WHY IT WAS UNREACHABLE.  The store-tile walk and the MMA walk recover a tile's geometry from
;;; *register-tile-dims* keyed by the minted TYPE NAME -- and that name was
;;; REGISTER-TILE-ACC-F32-MxN with only (M N) in the table.  The element type existed at the
;;; binding site and was gone by the time anything needed it.
;;;
;;; THE NAME IS NOW HONEST, and that is not cosmetic: a name that hardcodes F32 makes two tiles
;;; of different element types and identical dims COLLIDE on one record.  That is BUG 055
;;; (%coop-call caching a coop-matrix declaration by name alone) in a second location, and it is
;;; cheaper to not create it than to fix it twice.  Verified safe to rename: the string appears
;;; nowhere outside src/mma.lisp, and autodiff identifies register tiles from the ANF form
;;; (make-register-tile without :operand), never from the type name.
;;;
;;; These four definitions were EXTRACTED VERBATIM from src/mma.lisp by
;;; a one-off balanced-paren scan script (endeavour 165) and edited by exact-match
;;; replacement, each asserted to hit exactly once.  Nothing here was retyped by hand.
;;;
;;; NOTE FOR THE SRC PATCH: %acc-frag-mn is new (src/mma.lisp); %register-tile-type-name
;;; REPLACES src/mma.lisp:994; %ensure-register-tile-type REPLACES the 165 overlay copy above;
;;; analyze-make-register-tile REPLACES src/mma.lisp:1089; analyze-store-tile-mma REPLACES
;;; src/mma.lisp:1121; analyze-mma-accumulate-via-tile REPLACES src/mma.lisp:1182.
;;; ===================================================================


;; src/mma.lisp
;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26, and
;;;; endeavour 163's 23 definitions were folded in on 2026-09-06 (15 replaced their src
;;;; originals in place, 8 new helpers were appended to their target files, and a
;;;; duplicate *ad-ring-slot-marker* identical to src/autodiff.lisp's was dropped).
;;;;
;;;; When you fold future contents back out, three things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.
;;;;   * A FORMAT string using ~<newline> continuation works in an LF overlay and DIES
;;;;     when folded into CRLF src/, and the error names the wrong place.  Both files are
;;;;     CRLF today, so this is only a hazard if an overlay is ever written as LF.



;;; ===================================================================
;;; Endeavour 165 — a register tile that cannot hold a fragment must REFUSE, not vanish.
;;;
;;; THE DEFECT.  `analyze-make-register-tile` and the store/mma walks size a tile as
;;; (floor m 16) x (floor n 8) fragments, so ANY tile with M < 16 or N < 8 yields ZERO
;;; fragments.  There is nothing to fill, nothing to store and nothing to multiply, so the
;;; kernel legitimately optimises down to `ret;` -- and the compiler reports success.
;;; Demonstrated on the dev box with a plain fp32 8x8 tile (research/165-f64-mma-probe/):
;;; a fill + store-tile kernel emitted an empty body and exit code 0.
;;;
;;; `%ensure-register-tile-type` ALREADY guards exactly this and says so.  It never fires,
;;; because a LET-bound tile -- which is what every real kernel writes -- goes through
;;; `%explode-register-tiles` instead, and that path never re-checks.  The guard existed and
;;; was bypassed by the only route anyone uses.
;;;
;;; THE FIX.  One shared predicate, called from BOTH paths, so they cannot drift apart again.
;;; It is hooked into `%register-tile-fit-check` rather than into `%explode-register-tiles`
;;; because the fit-check is already invoked exactly once per register-tile binding on that
;;; path and already receives (m n location) -- a 15-line append instead of transcribing a
;;; 124-line function, which is its own class of risk.
;;;
;;; SCOPED TO THE NVIDIA PATH, deliberately.  On PTX `%frag-mn-for-operand` returns a
;;; hardcoded 16x8 for every operand and element type, so the geometry is unambiguous here.
;;; On SPIR-V it is derived per-element from `%spv-mma-shape`, and the fit-check does not
;;; receive the tile's element type or operand role -- guessing :acc would false-refuse a
;;; legitimate A or B tile and break shipped kernels.  SPIR-V can hit the same zero-fragment
;;; case with a mismatched shape; closing it there needs the elem threaded through, and is
;;; left as its own step rather than smuggled in behind a wrong default.
;;;
;;; NOTE FOR THE SRC PATCH: %register-tile-dims-must-divide is new (src/mma.lisp);
;;; %ensure-register-tile-type REPLACES src/mma.lisp:1001; %register-tile-fit-check
;;; REPLACES src/mma.lisp:1307.
;;; ===================================================================

;; src/mma.lisp
(defun %register-tile-dims-must-divide (m n location &optional (fr 16) (fc 8))
  "Refuse a register tile whose dims do not cover at least one whole FR x FC fragment.

   A tile of (M N) holds (floor M FR) x (floor N FC) fragments.  When either floor is zero the
   tile holds NOTHING, and every construct that walks it -- store-tile, fill-tile,
   mma-accumulate-via-tile -- expands to no code, so the kernel compiles clean and does nothing.
   That is the one outcome a compiler must never produce silently, so this is an error and not a
   warning: there is no reading of a zero-fragment tile under which the user got what they asked
   for.

   Endeavour 165.  fp64's only tensor-core shape is m8n8k4, whose accumulator is 8x8 -- under the
   hardcoded 16x8 fragment in BOTH dimensions -- so every fp64 MMA kernel would have walked into
   this.  The defect itself is older and has nothing to do with fp64: a plain fp32 8x8 tile
   reproduces it exactly."
  (unless (and (integerp m) (integerp n) (plusp m) (plusp n)
               (zerop (mod m fr)) (zerop (mod n fc)))
    (error 'crisp-compiler-error
           :message (format nil "make-register-tile: dims (~a ~a) must be multiples of the ~ax~a accumulator fragment. (~a ~a) holds ~a fragments, so the tile would carry no values and every store-tile / fill-tile / mma-accumulate-via-tile over it would expand to no code at all."
                            m n fr fc m n
                            (* (floor m fr) (floor n fc)))
           :source-location location)))

;;; ===================================================================
;;; Endeavour 165 step 2b-ii — FLIP the geometry: fp64 accumulator fragments are 8x8.
;;;
;;; 2a and 2b-i were each proved inert (14 IR files byte-identical).  This step changes emitted
;;; code, and it changes it for `double` ONLY: every f32 / f16 / bf16 path still resolves to
;;; 16x8 through the very same functions, so the byte-identical check must STILL hold for them.
;;; That is the whole return on having done the two inert steps first -- when the f32 IR moves
;;; here, it is a bug, not a judgement call.
;;;
;;; THE LANE MAPPING IS NOT GUESSED.  fp64 m8n8k4 C/D comes from CuTe's
;;; MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>: CLayout = Layout<Shape<Shape<_4,_8>,_2>,
;;; Stride<Stride<_16,_1>,_8>> over ThrID = Layout<_32>, which with t0 = lane%4, t1 = lane/4 and
;;; v in {0,1} gives m = lane/4, n = 2*(lane%4) + v.  It is the SAME column scheme the tf32 path
;;; already uses, with one row per lane instead of the g / g+8 pair -- corroboration, not
;;; coincidence.  A fragment lane layout is the textbook wrong-but-self-consistent failure: it
;;; compiles, emits the right instruction, passes every mechanical check and computes garbage
;;; that only metal catches.  Endeavour 159 lost a pod session to that class of thing, so this
;;; one came from a machine-readable primary source in the tree rather than from memory.
;;;
;;; STILL NOT DONE HERE: load-fragment-a / -b for fp64 and the m8n8k4 MMA emitter itself.  An
;;; fp64 register tile can now be built, filled and STORED; multiplying is step 3.
;;;
;;; NOTE FOR THE SRC PATCH: %acc-frag-mn and %frag-record-for-acc REPLACE/extend their 165
;;; overlay copies above; register-mma-types REPLACES src/mma.lisp:230;
;;; %ensure-register-tile-type REPLACES the 165 overlay copy; analyze-make-register-fragment
;;; REPLACES src/mma.lisp:~410; analyze-store-fragment REPLACES src/mma.lisp:508;
;;; %emit-per-frag-store REPLACES the 2b-i overlay copy; analyze-store-tile-mma REPLACES the 2a
;;; overlay copy.
;;; ===================================================================

;; src/mma.lisp
(defun %acc-frag-mn (elem)
  "The ACCUMULATOR fragment geometry (ROWS . COLS) for element type ELEM on the current backend.

   THE SINGLE SOURCE OF TRUTH.  Every geometry decision on the register-tile path -- the tile
   minter, the fit-check, the BUG 058 refusal, the store-tile walk, the MMA walk, the warp
   validator and the five %emit-per-frag-* emitters -- resolves here.  That is what steps 2a and
   2b-i built; this step is the payoff, because adding fp64 is now a change to one function.

   fp64: 8x8, because m8n8k4 is the ONLY fp64 tensor-core shape (LLVM 21.1.5 lowers only
   llvm.nvvm.mma.m8n8k4.row.col.f64; CUTLASS declares exactly one f64 tensor-op Mma, at
   GemmShape<8,8,4>).  Its accumulator is 8x8 = 64 elements over 32 lanes = 2 doubles per lane.

   Everything else keeps 16x8, the tf32/16-bit accumulator: 16x8 = 128 over 32 lanes = 4 fp32
   per lane.  16-bit operands accumulate in fp32 and so land here too, deliberately -- the same
   reason %coop-elem-of does not route accumulators through the operand element type.

   :spirv does not consult this; it derives its shape per-element from the profile via
   %spv-mma-shape, and was never 16x8-shaped."
  (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
      (cons 8 8)
      (cons 16 8)))

(defun %register-tile-type-name (m n &optional (elem 'float))
  "The minted record name for an M x N register tile of element type ELEM.

   Endeavour 165 (step 2a): the name now carries the ELEMENT TYPE.  It used to be
   REGISTER-TILE-ACC-F32-MxN unconditionally, which was a lie the moment a double tile existed
   and -- worse -- a COLLISION: two tiles with the same dims and different element types would
   have shared one record.  That is not hypothetical; it is exactly BUG 055, where %coop-call
   caches the coop-matrix declaration by name alone and two element types in one module silently
   collide.  One instance of that bug is enough.

   ELEM defaults to FLOAT so any caller not yet threading it keeps the pre-165 record."
  (intern (format nil "REGISTER-TILE-ACC-~a-~dX~d" (symbol-name (%canonical-elem elem)) m n)
          (find-package :crisp.compiler)))

(defun %register-tile-type-p (type-name)
  "T if TYPE-NAME is a minted register-tile type."
  (and (symbolp type-name) (nth-value 1 (gethash type-name *register-tile-dims*))))

(defun %ensure-register-tile-type (m n &optional (elem 'float))
  "Mint (once) the register-tile record for an M x N tile of ELEM -- (M/fr)x(N/fc) fragment
   fields -- and record its dims AND element type.  Returns the type symbol.

   Endeavour 165 (2a): ELEM is threaded through, and *register-tile-dims* stores (M N ELEM),
   because the store-tile and MMA walks recover their geometry from that table by TYPE NAME and
   had no other way to learn the element type.

   Endeavour 165 (2b-ii): the FIELD type now comes from %frag-record-for-acc rather than being
   hardcoded to the f32 record, so a double tile is a tile of fp64 fragments.

   Endeavour 165 (BUG 058): the divisibility guard delegates to %register-tile-dims-must-divide,
   which the LET-bound path checks too, at the element's own fragment geometry."
  (let ((fmn (%acc-frag-mn elem)))
    (%register-tile-dims-must-divide m n nil (car fmn) (cdr fmn))
    (let ((name (%register-tile-type-name m n elem)))
      (unless (gethash name *crisp-structs*)
        (let ((nfrags (* (floor m (car fmn)) (floor n (cdr fmn)))))
          (register-struct-definition
           name
           (loop for i below nfrags
                 collect (list (intern (format nil "F~d" i) (find-package :crisp.compiler))
                               (%frag-record-for-acc elem)))
           :record)))
      (setf (gethash name *register-tile-dims*) (list m n elem))
      name)))

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

(defun %validate-warp-mask (mask nfrags n-warps m n location &optional divisor)
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
    ;; Endeavour 155 Step 2: an OPERAND tile does not divide by the warp COUNT -- warps in a grid
    ;; row share A rows and warps in a column share B columns, so A divides by gm and B by gn.
    ;; DIVISOR carries that when the caller knows it; without it the original n-true rule stands.
    (unless (zerop (mod nfrags (or divisor n-true)))
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile: a ~ax~a tile is ~a (16x8) fragments, which ~a participating warps do not evenly divide.  Use a warp count that divides ~a (1/2/4/...)."
                         m n nfrags (or divisor n-true) nfrags)
        :source-location location))
    (values n-true first-true)))

(defun analyze-make-register-tile (expr env context location)
  "P3a: (make-register-tile T (M N) INIT &key warps) -> a record-of-fragments accumulator tile,
   each fragment initialized to INIT.  Mints the tile type on demand; rewrites to
   %construct-struct of make-register-fragment fields.
   Endeavour 165 (2a): ELEM now reaches the minted tile type and the fragment count.
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
    (destructuring-bind (m n) dims
      (let* ((tile-name (%ensure-register-tile-type m n elem))
             (fmn       (%acc-frag-mn elem))
             (nfrags    (* (floor m (car fmn)) (floor n (cdr fmn)))))
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
                             ,@(loop repeat nfrags collect `(make-register-fragment 16 8 ,init :elem ,elem)))
         env context location)))))

(defvar *210-pairs-only* nil
  "Endeavour 210 (D-210-7).  T while a wgmma (store-tile D C (BTY BTX)) whose C is declared
   (even-columns C) is analyzed (bound by the analyze-store-tile-mma wrapper):
   %wgmma-store-rewrite-origin then emits only its packed arm.")

(defun %210-even-columns-names (declarations)
  "Endeavour 210 (D-210-7).  The parameter symbols named by every (even-columns P ...) in DECLARATIONS."
  (loop for d in declarations
        when (and (consp d) (symbolp (car d)) (string-equal (symbol-name (car d)) "EVEN-COLUMNS"))
          append (cdr d)))

(defun %210-pairs-only-dest-p (dest context location)
  "Endeavour 210 (D-210-7).  T when the store destination DEST is declared (even-columns DEST) in the
   kernel being compiled.  The declaration is VALIDATED here: DEST must be a kernel matrix parameter of
   a type declared :align :compact with :contiguous-term :row-major (the default), else an error --
   only then does an even column count make every (even column, column + 1) pair one aligned word."
  (let ((names (%210-even-columns-names (compiler-context-declarations context))))
    (when (and (symbolp dest)
               (member (symbol-name dest) names :key #'symbol-name :test #'string=))
      (let* ((kernel   (compiler-context-current-compiling-function context))
             (decl     (cdr (assoc dest (gethash kernel *kernel-declared-signatures*))))
             (resolved (or (and decl (symbolp decl) (gethash decl *crisp-type-aliases*)) decl))
             (align    (and (listp resolved) (second (member :align resolved))))
             (ct       (%kernel-param-contiguous-term kernel dest)))
        (log:debug "210 even-columns ~a in ~a: type ~s align ~s contiguous-term ~s" dest kernel resolved align ct)
        (unless (and decl (eq align :compact) (eq ct :row-major))
          (error 'crisp-compiler-error
                 :message (format nil "(even-columns ~(~a~)): ~(~a~) must be a kernel matrix parameter whose type is declared :align :compact :contiguous-term :row-major -- only then does an even number of columns make every (even column, odd column) pair one aligned word.  Its declared type is ~(~s~)."
                                  dest dest resolved)
                 :source-location location))
        t))))

(defun analyze-store-tile-mma-base (expr env context location)
  "store-tile overload: register-tile (mma.sync) OR wgmma-accumulator (Endeavor 140) OR delegate.
   Endeavour 196: the source may be (to-half TILE) / (to-bfloat16 TILE) for either accumulator kind.
   (An exploded register tile never reaches here -- %explode-rewrite-body-form handles it -- so the
   register-tile branch below is the un-exploded path.)

   Endeavour 210: analyze-store-tile-mma (below) binds *210-pairs-only* around this."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node)))
      (log:debug "196 store-tile: src-type=~a convert=~a" src-type convert)
      (cond
        ((%wgmma-acc-type-p src-type)
         (let ((n (second (gethash src-type *wgmma-acc-dims*))))
           (analyze-expression (%wgmma-store-rewrite src (third expr) (fourth expr) n convert)
                               env context location)))
        ((%register-tile-type-p src-type)
         (destructuring-bind (m n &optional (elem 'float)) (gethash src-type *register-tile-dims*)
           (let* ((tile    src)
                  (dest    (third expr))
                  (tile-id (fourth expr))
                  (to-int-sym (intern "TO-INT" (find-package :crisp-language)))
                  (bty (list to-int-sym (first tile-id)))
                  (btx (list to-int-sym (second tile-id)))
                  (fmn (%acc-frag-mn elem))
                  (m-frags (floor m (car fmn))) (n-frags (floor n (cdr fmn))))
             (analyze-expression
              `(let ((tv ,tile))
                 (progn
                   ,@(loop for mi below m-frags
                           append (loop for nj below n-frags
                                        for idx = (+ (* mi n-frags) nj)
                                        collect `(store-fragment ,(%196-wrap-conversion
                                                                   convert
                                                                   `(%extract-struct-member tv ,idx))
                                                                 ,dest
                                                                 ((+ (* ,bty ,m-frags) ,mi)
                                                                  (+ (* ,btx ,n-frags) ,nj))
                                                                 ,elem)))))
              env context location))))
        (convert
         (%196-refuse-converted-non-accumulator "store-tile" convert src-type location))
        (t
         (analyze-store-tile-expression expr env context location))))))

(defun analyze-store-tile-mma (expr env context location)
  "store-tile overload: register-tile (mma.sync) OR wgmma-accumulator (Endeavor 140) OR delegate.
   See the original (src/mma.lisp).
   Endeavour 210 (D-210-7): a grid-origin (store-tile D C (BTY BTX)) whose C is declared
   (even-columns C) is analyzed with *210-pairs-only* bound, so a wgmma D stores with the packed arm
   alone (no %pair-ok-p fallback)."
  (let ((*210-pairs-only* (and (= (length expr) 4)
                               (%210-pairs-only-dest-p (third expr) context location))))
    (when *210-pairs-only*
      (log:info "210 store-tile ~a -> ~a: (even-columns ~a), packed stores only" (second expr) (third expr) (third expr)))
    (analyze-store-tile-mma-base expr env context location)))

;;; ===================================================================
;;; P3b — mma-accumulate-via-tile (bodyless): walk the register C-tile in MMA
;;; fragments, accumulate one K-step, set! the tile back.  Composes P2/P3a
;;; primitives (load-fragment-a/b, mma-accumulate, the tile record) — a rewrite.
;;; ===================================================================



;;; ===================================================================
;;; Endeavour 165 step 4 — the h100 profile tells the truth about fp64, and the shape check
;;; understands TYPED entries.
;;;
;;; THE TRAP THIS CLOSES (finding 3 in the endeavour doc).  h100's :mma-shapes was
;;; ((16 8 8) (16 8 4) (16 8 16)) with no typed entry, so %mma-shape-for-elem fell to its width
;;; rule -- K x element-bits is a constant fragment footprint -- and resolved `double` to
;;; **(16 8 4)**.  That shape is real in the PTX ISA and is NOT an NVVM intrinsic in LLVM 21.1.5:
;;; it assembles cleanly and llc emits an `.extern .func` CALL with no diagnostic.  So a benchmark
;;; kernel run under --hardware-profile=h100 would have picked an unemittable shape SILENTLY.
;;; The width rule is not wrong; it simply is not the constraint that binds for fp64, where the
;;; hardware offers exactly one shape.
;;;
;;; %check-mma-shape also had to learn typed entries.  It tested raw `member ... :test #'equal`
;;; against the 3-lists, so a TYPED 4-list `(double 8 8 4)` would never have matched the user's
;;; `(8 8 4)` -- adding the entry alone would have made the profile correct and the kernel
;;; un-compilable.  The two edits only work together, which is why they are one block.
;;;
;;; NOTE FOR THE SRC PATCH: %check-mma-shape REPLACES src/mma.lisp:1161;
;;; register-builtin-hardware-profiles REPLACES src/mma.lisp:282.
;;; ===================================================================

;; src/mma.lisp
(defun %check-mma-shape (mma-shape location)
  "Validate the (M N K) MMA shape: an int triple, and — if a hardware profile is active —
   a member of its :mma-shapes (the vendor's supported shape, e.g. Intel (8 16 8)); with
   NO profile, require the tf32 NVIDIA default (16 8 8).

   Endeavour 165: a profile entry may be TYPED — `(ELEM M N K)`, a 4-list — so membership is
   tested against each entry's DIMS via %mma-shape-entry-dims rather than against the entry
   itself.  Untyped 3-lists compare exactly as before."
  (unless (and (listp mma-shape) (= (length mma-shape) 3) (every #'integerp mma-shape))
    (error 'crisp-compiler-error
           :message (format nil "mma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." mma-shape)
           :source-location location))
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if shapes
        (unless (find mma-shape shapes :test #'equal :key #'%mma-shape-entry-dims)
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: shape ~a is not one of the active hardware profile's :mma-shapes ~a."
                                  mma-shape shapes)
                 :source-location location))
        (unless (equal mma-shape '(16 8 8))
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: only tf32 (16 8 8) is supported without a hardware profile, got ~a." mma-shape)
                 :source-location location)))))

;;;; ----------------------------------------------------------------------
;;;; Endeavour 204 -- integer MMA: K must fill the instruction
;;;; See tests/spec/204-integer-mma/integer-mma.md.
;;;; ----------------------------------------------------------------------

(defun %check-int-mma-k (mma-shape a env context location)
  "Refuses an int8 multiply at a K meant for another width.  (8 16 8) is a legal shape, but for tf32, so
   the profile check passes it, while the operands load at K=32.  That compiled silently.

   Endeavour 207: on NVIDIA the only int8 sync shape is (16 8 32) -- mma.sync m16n8k32."
  (let ((elem (%coop-elem-of (analyze-expression a env context location))))
    (when (%int-operand-p elem)
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)
            (declare (ignore sm sn))
            (unless (eql (third mma-shape) sk)
              (error 'crisp-compiler-error
                     :message (format nil "mma-accumulate-via-tile: ~(~a~) operands need K=~a on this profile; got ~a."
                                      elem sk (third mma-shape))
                     :source-location location)))
          (unless (equal mma-shape '(16 8 32))
            (error 'crisp-compiler-error
                   :message (format nil "mma-accumulate-via-tile: ~(~a~) operands on NVIDIA need the mma.sync shape (16 8 32); got ~a."
                                    elem mma-shape)
                   :source-location location))))))

(defun %check-int-tile-k (shape elem)
  "Refuses a via-tile multiply into an integer tile at a K meant for another width.  (8 16 8) is a legal
   shape, but for tf32, while integer operands load at K=32.  A let-bound tile is rewritten here,
   before analysis, so this is the check real kernels reach; %check-int-mma-k covers the analyzed form.

   Endeavour 207: on NVIDIA an int tile is the s32 accumulator of mma.sync (16 8 32), the only shape."
  (when (and shape (%elem-integer-p elem))
    (if (eq *target-backend* :spirv)
        (multiple-value-bind (sm sn sk) (%spv-mma-shape 'char)
          (declare (ignore sm sn))
          (unless (eql (third shape) sk)
            (error 'crisp-compiler-error
                   :message (format nil "mma-accumulate-via-tile: 8-bit operands need K=~a on this profile; got ~a."
                                    sk (third shape)))))
        (unless (equal shape '(16 8 32))
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: an int tile on NVIDIA is the mma.sync (16 8 32) accumulator; got ~a."
                                  shape))))))

(defun analyze-mma-accumulate-via-tile (expr env context location)
  "P3b-1: (mma-accumulate-via-tile (M N K) C-TILE A B) — walk the register C-tile in
   16x8 fragments and accumulate ONE K-step (K = the shape's K) into each, set!-ing the
   accumulated tile back.  Bodyless (no accum-op / epilogue yet)."
  (destructuring-bind (mma-shape c-tile a b) (cdr expr)
    (%check-mma-shape mma-shape location)
    (%check-int-mma-k mma-shape a env context location)
    (let* ((c-node (analyze-expression c-tile env context (append location '(1))))
           (c-type (semantic-node-type c-node)))
      (unless (%register-tile-type-p c-type)
        (error 'crisp-compiler-error
               :message (format nil "mma-accumulate-via-tile: C-tile (2nd arg) must be a register-tile, got type ~a." c-type)
               :source-location location))
      (destructuring-bind (tm tn &optional (elem 'float)) (gethash c-type *register-tile-dims*)
        (let* ((fmn (%acc-frag-mn elem))
               (m-frags (floor tm (car fmn))) (n-frags (floor tn (cdr fmn))))
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
         (destructuring-bind (rsym marker m n slot-syms-list operand
                              &optional (n-true 1) (first-true 0)) ring-entry
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
           ;; 156 Phase 2: carry the ring's slice fields through instead of the hardcoded
           ;; 1/0, which made every ring slot look unsliced to the emitters.
           (list rsym m n (nth slot slot-syms-list) n-true first-true operand)))))
    (t nil)))



;;; ===================================================================
;;; Endeavour 165 step 2b-i (v2) — reach the ELEMENT TYPE from the register-tile emitters.
;;;
;;; STILL NO GEOMETRY CHANGE.  %acc-frag-mn answers 16x8 for every element type; 2b-ii flips it.
;;;
;;; WHAT v1 GOT WRONG, kept here because the correction is the interesting part.  v1 appended
;;; ELEM as a seventh field on the tile ENTRY.  That broke src/codegen.lisp:5477 -- the load-tile
;;; per-fragment expansion -- because the survey had been scoped to src/mma.lisp while the entry
;;; shape is consumed across files.  Three Intel negative specs died with "too many elements ...
;;; to satisfy lambda list (M N SYMS &OPTIONAL (N-TRUE) (FIRST-TRUE) (OPERAND))", and two Intel
;;; on-metal specs failed with them.  A 14-file byte-identical IR check had said the change was
;;; inert; it was inert on the files sampled and not on the suite, which is the difference
;;; between a spot check and a proof.
;;;
;;; v1 was also fighting the design.  That same codegen site already asks the question properly:
;;;     (%frag-mn-for-operand operand (%register-tile-elem-of (first entry)))
;;; -- a side-table lookup keyed by the tile's own symbol, populated into *register-tile-elems*
;;; by %explode-register-tiles.  The entry deliberately does not carry the element type; there is
;;; an established way to ask.  v2 uses it, so the entry shape never changes and no consumer
;;; anywhere needs patching.
;;;
;;; NOTE FOR THE SRC PATCH: %frag-mn REPLACES src/mma.lisp:1268; %emit-per-frag-accumulate
;;; REPLACES :1403; %emit-per-frag-store REPLACES :1491; %emit-per-frag-acc-load REPLACES :2852;
;;; %register-tile-fit-check REPLACES the 165 overlay copy above; %explode-register-tiles
;;; REPLACES :1877.
;;; ===================================================================

;; src/mma.lisp
(defun %frag-mn (&optional (elem 'float))
  "Per-fragment (M . N) for register-tile decomposition: the active profile's mma-shape (M N) on
   :spirv, else the NVIDIA accumulator geometry for ELEM.

   Endeavour 165 (2b-i): takes ELEM and defers to %acc-frag-mn on the NVIDIA path instead of
   answering a flat 16x8 for everything.  ELEM defaults to FLOAT, so a caller that has not been
   taught to thread it keeps the pre-165 answer -- which is what makes this step inert."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (m n k) (%spv-mma-shape) (declare (ignore k)) (cons m n))
      (%acc-frag-mn elem)))

;;; ===================================================================
;;; Endeavour 165 step 2b-ii (cont) — the THIRD geometry function.
;;;
;;; %acc-frag-mn and %frag-mn were routed; %frag-mn-for-operand still answered a flat 16x8 for
;;; every operand and element type on the NVIDIA path, so the explode path built 16x8 fragments
;;; for a double tile and analyze-make-register-fragment correctly refused them:
;;;   "make-register-fragment: DOUBLE accumulator fragments are 8x8 on this target (got 16 x 8)."
;;; The refusal did its job -- this is what a loud guard buys over a silent one.
;;;
;;; OPERAND geometry is filled in here too rather than left at 16x8 for fp64.  A and B for
;;; m8n8k4 are 8x4 and 4x8 (CuTe ALayout/BLayout = SM80_8x4, 1 double per lane).  Operand tiles
;;; are not reachable for fp64 until step 3 wires load-fragment-a/-b, but a function that would
;;; answer 16x8 if asked is a trap left lying around, and this endeavour has already paid once
;;; for a geometry that was wrong in a place nobody was looking.
;;; ===================================================================

;; src/mma.lisp
(defun %frag-mn-for-operand (operand &optional elem)
  "Endeavor 142 — per-fragment (rows . cols) for a register-tile of :operand (a|b|acc).  From the
   active profile's mma-shape (sm sn sk): A = sm x sk (Use 0), B = sk x sn (Use 1),
   Acc = sm x sn (Use 2) — matching load-fragment-a/b and make-register-fragment.

   Endeavour 155: ELEM selects the shape, because K depends on the element width.

   Endeavour 165 (2b-ii): the NVIDIA branch stops answering a flat 16x8.  The accumulator defers
   to %acc-frag-mn, the single source of truth; fp64 operands take m8n8k4's own 8x4 / 4x8, from
   CuTe MMA_Traits<SM80_8x8x4_F64F64F64F64_TN> (ALayout = BLayout = SM80_8x4, one double per
   lane).  Non-fp64 operands keep 16x8 exactly as before."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)
        (ecase operand
          (:a   (cons sm sk))
          (:b   (cons sk sn))
          (:acc (cons sm sn))))
      (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
          (ecase operand
            (:a   (cons 8 4))
            (:b   (cons 4 8))
            (:acc (%acc-frag-mn elem)))
          (ecase operand
            (:a   (cons 16 8))
            (:b   (cons 16 8))
            (:acc (%acc-frag-mn elem))))))

(defun %register-tile-frag-syms (var count)
  "COUNT per-fragment variable symbols for tile VAR, interned in VAR's package with a `$F<i>`
   suffix.  Endeavor 139: COUNT is the PER-WARP fragment count (= nfrags / #participating-warps),
   so a warp-distributed tile allocates only its share (the register drop that raises occupancy)."
  (loop for i below count
        collect (intern (format nil "~a$F~d" (symbol-name var) i) (symbol-package var))))


(defparameter *default-max-registers-per-thread* 255
  "Fallback per-thread register budget for the register-tile fit-check when no
   hardware profile pins :max-registers-per-thread.  255 = NVIDIA architectural max.")




;;;; ----------------------------------------------------------------------
;;;; Endeavour 196 -- 16-bit stores of f32 accumulators; per-warp register-tile shares
;;;; See tests/spec/196-matmul-contest/matmul-contest.md.
;;;; ----------------------------------------------------------------------

;;;; ----------------------------------------------------------------------
;;;; Endeavour 205 -- tile narrowing to a quantized integer
;;;; See tests/spec/205-quantized-integers/quantized-integers-205.md.
;;;; ----------------------------------------------------------------------

(defun %qint-narrowing-target (op)
  "The def-qint base type behind the operator symbol TO-NAME, or NIL."
  (when (symbolp op)
    (let ((name (symbol-name op)))
      (when (and (> (length name) 3) (string= "TO-" name :end2 3))
        (let ((entry (gethash (subseq name 3) *qint-roles*)))
          (and (eq (car entry) :base) (cdr entry)))))))

(defun %196-peel-store-conversion (src)
  "Endeavour 196.  If SRC is (to-half X) or (to-bfloat16 X), return (values X CONVERT-SYMBOL);
   otherwise (values SRC NIL).  Only these two narrowing conversions are peeled: they are the two a
   16-bit MMA needs on the way out (f32 accumulator -> fp16 / bf16 output).  Anything else is left
   for the ordinary analysis, which refuses a conversion of a whole accumulator.
   Endeavour 205: (to-q X M) peels too, and CONVERT is then the list (%to-q-narrow Q M).  A SPIR-V
   store is one whole fragment with no per-element step, so that is refused here."
  (cond
    ((and (consp src) (symbolp (first src)) (= (length src) 2)
          (member (symbol-name (first src)) '("TO-HALF" "TO-BFLOAT16") :test #'string=))
     (values (second src) (first src)))
    ((and (consp src) (= (length src) 3) (%qint-narrowing-target (first src)))
     (when (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
              :message (format nil "(~(~a~) X M) as a store source: a SPIR-V store is one whole fragment.  Store X into an int matrix, then narrow its elements with (~(~a~) x m)."
                               (first src) (first src))))
     (values (second src) (list '%to-q-narrow (%qint-narrowing-target (first src)) (third src))))
    (t (values src nil))))

(defun %196-wrap-conversion (convert form)
  "Endeavour 196.  (CONVERT FORM) when CONVERT is non-NIL, else FORM unchanged.
   Endeavour 205: a list CONVERT, (%to-q-narrow Q M), wraps as (%to-q-narrow Q FORM M)."
  (cond ((null convert) form)
        ((consp convert) (list (first convert) (second convert) form (third convert)))
        (t (list convert form))))

(defun %196-convert-store-fragment-sources (form convert)
  "Endeavour 196.  Wrap the FRAG argument of every (store-fragment FRAG ...) in FORM with
   (CONVERT FRAG).  Applied to %emit-per-frag-store's expansion, which is the only producer of
   store-fragment forms there, so the per-fragment store logic (static arms, 2-D warp grid) is
   reused untouched rather than copied with a conversion parameter threaded through it."
  (cond
    ((not (consp form)) form)
    ((and (symbolp (first form)) (string= (symbol-name (first form)) "STORE-FRAGMENT"))
     (list* (first form) (%196-wrap-conversion convert (second form)) (cddr form)))
    (t (mapcar (lambda (f) (%196-convert-store-fragment-sources f convert)) form))))

(defun %196-refuse-converted-non-accumulator (op convert src-type location)
  "Endeavour 196.  (store-tile (to-half X) ...) where X is not an MMA accumulator: refuse here,
   naming the rule, rather than let the generic store analyze (to-half X) as a scalar cast of a
   whole tile (which fails later with an unrelated message)."
  (error 'crisp-compiler-error
         :message (let ((*print-pretty* nil)) (format nil "~(~a~): (~(~a~) X) as a store source needs X to be an MMA accumulator (a register tile or a wgmma accumulator), whose f32 elements are converted as they are stored.  X here is ~a.  To convert a scratch or global tile, convert its elements where they are written." op (if (consp convert) (format nil "to-~a" (second convert)) convert) src-type))
         :source-location location))

(defvar *196-tile-warp-shares* nil
  "Endeavour 196.  ((M N ELEM N-TRUE) ...) for the register tiles of the LET being exploded, so the fit
   check can charge a :warps-distributed tile per warp.  Bound by the %explode-register-tiles wrapper.")

(defun %196-tile-warp-shares (bindings location)
  "Endeavour 196.  For each (V (make-register-tile ELEM (M N) INIT ... :warps MASK)) binding, (M N ELEM
   N-TRUE); N-TRUE is 1 without :warps."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          collect (let* ((form (second b))
                         (warps-in (getf (nthcdr 4 form) :warps))
                         (mask (and warps-in (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                    (list (first (third form)) (second (third form)) (second form)
                          (max 1 (if mask (count t mask) 1))))))

(defun %register-tile-fit-check (m n location &optional (elem 'float))
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/fr)x(N/fc) accumulator fragments x regs-per-fragment <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes.

   Endeavour 165 (BUG 058): also refuses a tile too SMALL to hold one fragment.  A tile that
   overflows the register budget and a tile that holds nothing are the same kind of mistake and
   are named by the same function, at compile time, rather than discovered as a spill or as an
   empty kernel.

   Endeavour 165 (2b-i): takes ELEM so both bounds use the element type's own fragment geometry.
   Inert while %acc-frag-mn answers 16x8 for everything.

   Endeavour 196 (D-196-10): a tile distributed over N-TRUE warps (:warps) costs each thread
   ceil(fragments / N-TRUE) fragments -- the share it actually allocates -- looked up in
   *196-tile-warp-shares* by (M N ELEM).

   Endeavour 207: ELEM may be a type accessor such as (accum q-a); it and the share entries are
   compared after %canonical-elem."
  (unless (eq *target-backend* :spirv)
    (flet ((enm (x) (let ((c (%canonical-elem x)))
                      (if (symbolp c) (symbol-name c) (format nil "~a" c)))))
      (let ((elem (%canonical-elem elem)))
        (destructuring-bind (fr . fc) (%acc-frag-mn elem)
          (%register-tile-dims-must-divide m n location fr fc)
          (let* ((share         (or (fourth (find-if (lambda (e) (and (eql (first e) m) (eql (second e) n)
                                                                          (equal (enm (third e)) (enm elem))))
                                                         *196-tile-warp-shares*))
                                    1))
                 (nfrags-all    (* (floor m fr) (floor n fc)))
                 (nfrags        (ceiling nfrags-all share))
                 (regs-per-frag 4)
                 (total-regs    (* nfrags regs-per-frag))
                 (budget        (or (%hp-registers-per-thread-default)
                                    *default-max-registers-per-thread*)))
            (log:debug "196 fit-check ~ax~a ~a: ~a fragments over ~a warp(s) -> ~a regs (budget ~a)"
                       m n elem nfrags-all share total-regs budget)
            (when (> total-regs budget)
              (error 'crisp-compiler-error
                     :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs~a), exceeding the register budget of ~a.  Use a smaller tile shape, distribute it over more warps (:warps), or a hardware profile with a larger :max-registers-per-thread."
                                      m n total-regs nfrags regs-per-frag
                                      (if (> share 1) (format nil ", ~a-way :warps share" share) "")
                                      budget)
                     :source-location location))))))))

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
               ;; Endeavour 155: 2-D WARP GRID.  The linear form (kept as the fallback below)
               ;; gave warp k the logical range [k*per-warp, ...), which for a row-major (mi, nj)
               ;; flattening is a ROW STRIP -- and a strip shares operands along ONE axis only:
               ;; A slices by mi, but every warp still needs ALL of B.  SYCL-TLA's bf16 kernel uses
               ;; Layout<Shape<_8,_4,_1>>, an 8x4 grid of 32 subgroups over a 256x256 tile, so each
               ;; subgroup needs 1/8 of A AND 1/4 of B.  That is what makes both operands sliceable,
               ;; which is the prerequisite for a large workgroup tile that does not replicate
               ;; operands into every subgroup.
               ;; m-frags is not a parameter here -- the caller passes only n-frags -- but the
               ;; total fragment count is per-warp * n-true, so the M extent follows.
               (let* ((m-frags (floor (* per-warp n-true) (max 1 n-frags)))
                      (grid (%warp-grid-dims n-true m-frags n-frags))
                      (gm (car grid)) (gn (cdr grid)))
                 (declare (ignorable gm))
                 `(,progn-sym
                    ,@(if grid
                          (let* ((mp (floor m-frags gm))
                                 (np (floor n-frags gn))
                                 (wm (floor k gn))
                                 (wn (mod k gn)))
                            (loop for l below per-warp
                                  for fv = (nth l syms)
                                  for mi = (+ (* wm mp) (floor l np))
                                  for nj = (+ (* wn np) (mod l np))
                                  append (funcall per-frag-fn fv mi nj)))
                          (loop for l below per-warp
                                for fv = (nth l syms)
                                for logical = (+ (* k per-warp) l)
                                for mi = (floor logical n-frags)
                                for nj = (mod logical n-frags)
                                append (funcall per-frag-fn fv mi nj))))))
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
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body shape)
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
    (destructuring-bind (fm . fn) (progn (%check-int-tile-k shape (%register-tile-elem-of (first entry))) (%frag-mn (%register-tile-elem-of (first entry))))
      ;; Endeavour 155 Phase C: honour the shape the KERNEL asked for.
      ;;
      ;; (mma-accumulate-via-tile (8 16 16) C A B) states K=16, which is the correct native
      ;; K-step for a 16-bit operand.  Re-deriving it from (first :mma-shapes) returned the TF32
      ;; K=8 instead, so the walker indexed fragments on a different K than the tiles were minted
      ;; with -- the A-tile held one K=16 fragment while the walker asked for two K=8 ones, and
      ;; the second came back NIL ("Unknown variable NIL").
      ;;
      ;; The requested shape was already in hand at the call site and already validated against
      ;; the profile by %check-mma-shape; it simply was not passed down.  Falling back to
      ;; %spv-mma-shape keeps every other caller behaving exactly as before.
      (multiple-value-bind (sm sn sk)
          (if (and shape (listp shape) (= (length shape) 3) (every #'integerp shape))
              (values-list shape)
              (%spv-mma-shape))
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (let* ((mp (%warp-slice-extent ta :a))          ; 155 Step 2b
                                  (row (if mp (mod mi mp) mi)))
                             (nth (+ (* row (max 1 (floor (third ta) sk))) ks) (fourth ta)))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (let* ((np (%warp-slice-extent tb :b))          ; 155 Step 2b
                                  (stride (or np (max 1 (floor (third tb) sn))))
                                  (col (if np (mod nj np) nj)))
                             (nth (+ (* ks stride) col) (fourth tb)))
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
                ;; Endeavour 155: register-resident A/B ARE supported with a warp-distributed
                ;; accumulator.  The refusal this replaces was incidental, not essential --
                ;; %emit-frag-loop-distributed's own contract says so:
                ;;
                ;;   "PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS
                ;;    (same contract as the n-true=1 static path)."
                ;;
                ;; and it computes them as (floor logical n-frags) / (mod logical n-frags), both
                ;; compile-time.  a-operand/b-operand index the tile's fragment SYMBOL LIST with
                ;; (nth ...), which needs exactly that -- a constant.  139 step-4 made this path
                ;; static precisely so operand addressing could be static, so the machinery the
                ;; refusal was waiting for already existed when it was written.
                ;;
                ;; WHY THIS MATTERS.  It is the only route to a bigger workgroup tile that does
                ;; NOT go through SLM.  C is what limits tile size -- 64x64 in one subgroup spills
                ;; 112 registers and collapses to 20 TFLOPS -- and splitting C across subgroups
                ;; divides exactly that pressure, while A/B keep the register+prefetch path that
                ;; is the fastest thing on this hardware.  A/B are then loaded redundantly per
                ;; warp, which costs bandwidth the cache may absorb; that is the trade to measure.
                (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).

   Endeavour 155 Step 3: RUNTIME-ADDRESSED distributed store.

   139 step-4 made this a static per-warp switch, which is right at 2-3 warps and catastrophic at
   32.  Each arm stores to a DIFFERENT global address, so unlike the MMA walk -- whose arms became
   identical once operands were warp-sliced, and collapsed -- every arm survives:

       tile          instrs   MulAdd   stores
       32x64  nw=1     1001       16       16
       128x128 nw=8    2025       16      121
       256x256 nw=32   5168       16      481     <- 32 arms x 16 fragments

   481 static stores for 16 dynamic ones, and 5168 instructions against SYCL-TLA's 2219 for the
   same geometry.

   With the 2-D warp grid the address is REGULAR, so one arm suffices:

       mi = wm*mp + (l / np)      wm = wp / gn      (runtime)
       nj = wn*np + (l mod np)    wn = wp mod gn    (runtime)

   l/np and l mod np are compile-time per fragment; only wm and wn are runtime, and they are two
   scalar ops shared by every fragment.  The static path is kept for the no-grid case, where the
   arms are few and literal addresses are preferable."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn (%register-tile-elem-of (first entry)))
      (let* ((cl (find-package :crisp-language))
             (to-int-sym (intern "TO-INT" cl))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(store-fragment ,fv ,dest
                                        ((+ (* ,bty ,m-frags) ,mi-form)
                                         (+ (* ,btx ,n-frags) ,nj-form))
                                        ,(%register-tile-elem-of (first entry))))))
          (let ((grid (and (> n-true 1) (%warp-grid-dims n-true m-frags n-frags))))
            (cond
              ((and grid (> n-true 1))
               (let* ((let-sym (intern "LET" cl))
                      (progn-sym (intern "PROGN" cl))
                      (minus-sym (intern "-" cl))
                      (plus-sym (intern "+" cl))
                      (times-sym (intern "*" cl))
                      (warp-id (intern "WARP-ID" cl))
                      (gm (car grid)) (gn (cdr grid))
                      (mp (max 1 (floor m-frags gm)))
                      (np (max 1 (floor n-frags gn)))
                      (per-warp (length syms))
                      (wp (gensym "WP")) (wm (gensym "WM")) (wn (gensym "WN")))
                 `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id)) ,first-true)))
                    ;; Integer division/remainder via / and - : kernels use / for integer
                    ;; division throughout, whereas FLOOR/MOD in crisp-language are not verified
                    ;; for this use.  Previously they fed only comparisons (which tolerate a wrong
                    ;; value by selecting an arm); here they compute a global ADDRESS, where a
                    ;; wrong value is an out-of-bounds write.
                    ;; ISOLATED BY TEST: crisp-language FLOOR/MOD here yield a value that is fine
                    ;; for a COMPARISON but wrong as an ADDRESS -- almost certainly a float.  The
                    ;; step-2b load switch feeds its selector to (< ...) and is therefore correct;
                    ;; this store feeds a global index and was not.  Integer / and - instead.
                    (,let-sym ((,wm (,(intern "/" cl) ,wp ,gn)))
                      (,let-sym ((,wn (,minus-sym ,wp (,times-sym ,wm ,gn))))
                      (,progn-sym
                        ,@(loop for l below per-warp
                                for fv = (nth l syms)
                                append (one-frag fv
                                                 `(,plus-sym (,times-sym ,wm ,mp) ,(floor l np))
                                                 `(,plus-sym (,times-sym ,wn ,np) ,(mod l np))))))))))
              ((> n-true 1)
               (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
              (t
               `(progn
                  ,@(loop for mi below m-frags append
                          (loop for nj below n-frags
                                for idx = (+ (* mi n-frags) nj)
                                append (one-frag (nth idx syms) mi nj))))))))))))

                                                  


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
(defun %spv-note-register-fragment (rows cols context location &optional (elem 'float))
  "Endeavor 144 Phase 4: record one register FRAGMENT's BYTE demand against the kernel being
   compiled, for the Intel GRF model.  No-op off the SPV backend or without a current function.
   Assigned per (kernel . location) so re-analysis is idempotent.

   Endeavour 155: stores BYTES rather than elements, because element count alone cannot answer
   the question the model asks once tiles are no longer all float32.  ELEM defaults to FLOAT so
   any caller not yet passing a type keeps its previous accounting exactly.

   Only ALLOCATIONS reach here — see the :tally nil guard in analyze-make-register-fragment
   for why re-initializing an existing fragment must not be counted."
  (when (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when fn
        (setf (gethash (cons fn location) *spv-register-demand*)
              (* rows cols (%elem-bytes elem)))))))


;;; ===================================================================
;;; Endeavour 165 — fill-tile builds fragments at the TILE'S element type.
;;;
;;; %emit-per-frag-fill emitted `(make-register-fragment 16 8 ,val :tally nil)` -- a hardcoded
;;; geometry and NO :elem -- so the element type defaulted to FLOAT and the constructor picked
;;; register-fragment-acc-f32-16x8.  Handed a double init that is a type error, and it is how
;;; chapter 2 of the 64-bit ladder failed:
;;;   STRUCT-CTOR REGISTER-FRAGMENT-ACC-F32-16X8 member R0: arg-type=DOUBLE expected=FLOAT
;;;
;;; This is the SIXTH place in this endeavour where the 16x8-f32 fragment was assumed rather than
;;; asked for, and the fifth found by a loud refusal rather than by reading code.  It surfaced
;;; only now because fill-tile on a register tile is what matrix-multiply-tile-stride uses to
;;; RESET the accumulator per output tile (the BUG 036 fix) -- chapter 1 hand-rolls its loop and
;;; never resets, so it never reached here.
;;;
;;; The reset VALUE was already correct: a register tile resets to its DECLARED INIT, so the
;;; double `0.0d` arrived intact.  Only the fragment it was being poured into was wrong.
;;;
;;; NOTE FOR THE SRC PATCH: %emit-per-frag-fill REPLACES src/mma.lisp:1675.
;;; ===================================================================

;; src/mma.lisp
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
               collect (let ((fmn (%frag-mn (%register-tile-elem-of (first entry)))))
                          `(set! ,s (make-register-fragment ,(car fmn) ,(cdr fmn) ,val
                                      :elem ,(%register-tile-elem-of (first entry)) :tally nil)))))))

;; src/mma.lisp
(defun %spv-kernel-register-demand (kernel-name)
  "Endeavor 144 Phase 4: (values GRF-REGISTERS BYTES) demanded per thread by KERNEL-NAME's
   register tiles / rings, or (values 0 0) if it has none.

   Endeavour 155: the tally now holds BYTES (see %spv-note-register-fragment), so the element
   width is a property of each fragment's type rather than a constant 4 applied to everything.
   The second value changed meaning from ELEMENTS to BYTES; %spv-decide-register-mode's warning
   was updated to match."
  (let ((bytes 0))
    (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf bytes v)))
             *spv-register-demand*)
    (values (ceiling bytes *spv-grf-register-bytes*) bytes)))


(defun %emit-per-frag-block-load (src entry coords)
  "Dispatches to %emit-per-frag-block-load-impl on the active lowering.  Kept as a plain function with its
   original signature so no call site changes."
  (%emit-per-frag-block-load-impl *mma-lowering* src entry coords))

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
;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 3 — the MMA WALKER and the TILES must agree on K.
;;;;
;;;; Phase C part 2 made register tiles mint fragments at the element type's native K (16 for
;;;; fp16).  The via-tile walker still derived K from (first :mma-shapes) -- TF32's K=8 -- so it
;;;; walked twice as many K-steps as the tile actually had fragments for, and the surplus index
;;;; resolved to NIL:
;;;;
;;;;     Crisp compilation failed ... Unknown variable NIL.
;;;;
;;;; The fix is not to re-derive it more cleverly but to STOP re-deriving it: the kernel already
;;;; wrote the shape, `(mma-accumulate-via-tile (8 16 16) C A B)`, and %check-mma-shape had already
;;;; validated it against the hardware profile.  %explode-rewrite-body-form had it bound as SHAPE
;;;; and used it only for that check.  Now it is passed down.
;;;;
;;;; NOTE that %frag-mn is deliberately left alone.  It supplies the ACCUMULATOR fragment's (M . N),
;;;; and M/N do not vary with element width on either shipped profile -- only K does.  Changing it
;;;; would be motion without a reason.
;;;; ------------------------------------------------------------------------------------------

;; [superseded defun %emit-per-frag-accumulate removed in consolidation -- a later copy in this file is the live one]
(defun %explode-rewrite-body-form-base (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! / %map-elements-vjp! references to any exploded tile in TILES with
   per-fragment progns; otherwise recurse structurally.

   Endeavour 196: %explode-rewrite-body-form (below) handles a converted store-tile source."
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
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body shape))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles nil nil shape))))
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

(defun %210-map-store-fragment-sources (form fn-form)
  "Endeavour 210.  FORM (a per-fragment store expansion) with every (store-fragment FRAG . REST) made
   (let ((tmp FRAG)) (map-elements! tmp FN-FORM) (store-fragment tmp . REST)): each fragment is copied,
   mapped and stored, and the tile itself is not changed.  Mirrors %196-convert-store-fragment-sources,
   which then wraps the copies in the conversion."
  (cond
    ((not (consp form)) form)
    ((and (symbolp (first form)) (string= (symbol-name (first form)) "STORE-FRAGMENT"))
     (let ((tmp (intern (format nil "XFRAG-~a" (symbol-name (gensym "F"))) (find-package :crisp.compiler))))
       `(let ((,tmp ,(second form)))
          (map-elements! ,tmp ,fn-form)
          (,(first form) ,tmp ,@(cddr form)))))
    (t (mapcar (lambda (f) (%210-map-store-fragment-sources f fn-form)) form))))

(defun %explode-rewrite-body-form (form tiles)
  "Endeavour 196 wrapper: (store-tile (to-half V) DEST (BTY BTX)) on an exploded register tile V
   expands exactly as (store-tile V DEST ...) does, with every emitted store-fragment's FRAG wrapped
   in the conversion.  Every other form goes to %explode-rewrite-body-form-base, which recurses back
   through this name.
   Endeavour 210 (F-210-1): (store-tile [CONV] V DEST (BTY BTX) :transformF #'F) on an exploded tile
   expands the same way with each fragment copied and mapped first (%210-map-store-fragment-sources);
   any other option on it is refused (it used to surface as \"Unknown variable V\")."
  (if (and (consp form) (symbolp (first form)) (%head-name-eq (first form) "STORE-TILE")
           (> (length form) 4))
      (multiple-value-bind (v convert) (%196-peel-store-conversion (second form))
        (let ((entry (and (symbolp v) (assoc v tiles))))
          (if (null entry)
              (%explode-rewrite-body-form-base form tiles)
              (multiple-value-bind (fn other) (%210-split-transformF (nthcdr 4 form))
                (when (or other (null fn))
                  (error 'crisp-compiler-error
                         :message (format nil "store-tile: option ~{~(~s~)~^, ~} is not supported on an accumulator store (~(~a~) is an MMA register tile).  An accumulator store takes :transformF #'f."
                                          (or (loop for (k nil) on other by #'cddr collect k) (list :transformF))
                                          v)))
                (%map-elements-check-unary fn nil)
                (log:debug "210 explode: store-tile ~a :transformF ~a convert ~a -> per-fragment copy + map" v fn convert)
                (%196-convert-store-fragment-sources
                 (%210-map-store-fragment-sources
                  (%emit-per-frag-store (third form) (fourth form) entry)
                  fn)
                 convert)))))
      (if (and (consp form) (symbolp (first form)) (%head-name-eq (first form) "STORE-TILE")
               (= (length form) 4))
          (multiple-value-bind (v convert) (%196-peel-store-conversion (second form))
            (if (and convert (assoc v tiles))
                (progn
                  (log:debug "196 explode: store-tile (~a ~a) -> per-fragment stores" convert v)
                  (%196-convert-store-fragment-sources
                   (%emit-per-frag-store (third form) (fourth form) (assoc v tiles))
                   convert))
                (%explode-rewrite-body-form-base form tiles)))
          (%explode-rewrite-body-form-base form tiles))))

;; Re-definition of the src/ original.  CHANGE: one added LET* binding that makes the LET's
;; SLM scratch-tile shapes visible to %emit-per-frag-accumulate (145 P3a).  Because
;; *mma-scratch-tile-dims* is special, the LET* establishes a dynamic binding covering the
;; whole expansion, including the %explode-rewrite-body-form calls at the end.
(defun %explode-register-tiles-base (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range).
   Endeavor 145 P3a: also publishes the LET's SLM scratch-tile shapes in *mma-scratch-tile-dims* so
   the accumulate expansion can walk K within a staged tile.

   Endeavour 196: %explode-register-tiles (below) publishes each tile's warp share around it."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             ;; 145 P3a: SLM tile shapes for the K-step count (special -> dynamically scoped).
             (*mma-scratch-tile-dims* (%mma-scratch-tile-dims-from-bindings bindings))
             ;; 155 Step 2: the warp grid comes from the ACCUMULATOR and governs how the operand
             ;; tiles slice.  First pass over the same bindings; see the Step 2 header.
             (*warp-grid* (%warp-grid-from-bindings bindings context location))
             ;; 155 Phase C: publish each register tile's ELEMENT TYPE for the same reason and by
             ;; the same mechanism -- the load-tile expansion has only the tile entry, which does
             ;; not record it.
             (*register-tile-elems* (%register-tile-elems-from-bindings bindings))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (let* ((form    (second b))
                                 (elem    (second form))   ; 155: element type, was discarded
                                 (dims    (third form))
                                 (init    (fourth form))
                                 (m       (first dims)) (n (second dims))
                                 (operand (getf (nthcdr 4 form) :operand :acc))
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                            (* (floor m fr) (floor n fc))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location elem)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    ;; 155 Step 2: validate an operand tile against ITS divisor
                                    ;; (gm for :a, gn for :b), not the warp count.
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location
                                                         (and *warp-grid* (member operand '(:a :b))
                                                              (%operand-warp-divisor operand)))
                                    (values 1 0))
                              ;; 155 Step 2: an OPERAND tile slices by the grid axis its warps
                              ;; share, not by the total warp count -- gm slices for A, gn for B.
                              ;; The accumulator keeps n-true.  Guarded on *warp-grid*, so a tile
                              ;; without a distributed accumulator in scope allocates whole.
                              (let* ((div (if (and *warp-grid* mask (member operand '(:a :b)))
                                              (%operand-warp-divisor operand)
                                              n-true))
                                     (per-warp (max 1 (floor nfrags div)))
                                     (syms     (%register-tile-frag-syms (first b) per-warp)))
                                (push (list (first b) m n syms n-true first-true operand) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment ,(car (%frag-mn-for-operand operand elem)) ,(cdr (%frag-mn-for-operand operand elem)) ,init :operand ,operand :elem ,elem))))))
                          (if (and (consp b) (= (length b) 2) (symbolp (first b))
                                   (%register-tile-ring-init-form-p (second b)))
                              (let* ((form    (second b))
                                     (elem    (second form))   ; 155: element type, was discarded
                                     (dims    (third form))
                                     (m       (first dims)) (n (second dims))
                                     (keys    (nthcdr 3 form))
                                     (operand (getf keys :operand :acc))
                                     (rc      (getf keys :ring-count))
                                     ;; 156 Phase 2: a RING may carry :warps too.  Without this the
                                     ;; ring branch gave every warp the WHOLE tile and recorded no
                                     ;; slice fields, so :warps on a ring kernel was a silent no-op
                                     ;; -- 32 subgroups each computing the identical tile.  Every
                                     ;; shipped 16-bit kernel is a ring kernel, which is why none of
                                     ;; them could use more than one subgroup whatever local-size said.
                                     (warps-in (getf keys :warps))
                                     (mask     (and warps-in
                                                    (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location elem)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                  (let ((nfrags (* (floor m fr) (floor n fc))))
                                    ;; Mirror the plain register-tile branch exactly: validate the
                                    ;; mask against the tile's OWN divisor, then give each warp only
                                    ;; its slice, per SLOT.
                                    (multiple-value-bind (n-true first-true)
                                        (if mask
                                            (%validate-warp-mask mask nfrags
                                                                 (%resolve-workgroup-warp-count context)
                                                                 m n location
                                                                 (and *warp-grid* (member operand (list :a :b))
                                                                      (%operand-warp-divisor operand)))
                                            (values 1 0))
                                      (let* ((div (if (and *warp-grid* mask (member operand (list :a :b)))
                                                      (%operand-warp-divisor operand)
                                                      n-true))
                                             (per-warp (max 1 (floor nfrags div)))
                                             (slot-syms-list
                                               (loop for slot below rc
                                                     collect (%register-tile-frag-syms
                                                              (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                      (symbol-package (first b)))
                                                              per-warp))))
                                        (push (list (first b) :ring m n slot-syms-list operand n-true first-true) tiles)
                                        (loop for syms in slot-syms-list
                                              append (loop for s in syms
                                                           collect (list s `(make-register-fragment ,(car (%frag-mn-for-operand operand elem)) ,(cdr (%frag-mn-for-operand operand elem)) 0.0 :operand ,operand :elem ,elem)))))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))

(defun %explode-register-tiles (let-expr &optional location context)
  "Endeavour 196 wrapper: publishes each register tile's warp share for %register-tile-fit-check, then
   runs the original."
  (let ((*196-tile-warp-shares*
          (if (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr)))
              (%196-tile-warp-shares (second let-expr) location)
              *196-tile-warp-shares*)))
    (%explode-register-tiles-base let-expr location context)))


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



;;;; ----------------------------------------------------------------------
;;;; Endeavour 207 -- qint roles at the MMA
;;;; See tests/spec/207-int8-mma-bench/int8-mma-bench.md.
;;;; ----------------------------------------------------------------------

;;; The tile MMA path checked only the LOWERED element types (q-a is already char there), so no qint rule
;;; reached it: q-a operands into (accum q-b), q-a x q-b with no product, and q-a into a plain int all
;;; compiled.  The rule (agreed with Chris 2026-11-04) -- only operands that ARE qints count; plain
;;; bytes are untyped:
;;;   no qint operand             -> any 32-bit integer accumulator, including any (accum T)
;;;   one qint T (T.T or T.plain) -> the accumulator must be (accum T)
;;;   two different qints T, U    -> a def-qint-product must be declared; the accumulator is (accum T U)
;;; Checked from the LET analyzer BEFORE tile explosion, the one point where the constructors, kernel
;;; parameters (ENV) and the C tile's name are all still visible.  An operand that cannot be resolved
;;; there is SKIPPED: a missed refusal is a gap, a false one would break a valid kernel.
(defun %qint-type-display (ty)
  "TY as an author writes it: (accum T) for a qint's own accumulator, else its name."
  (let ((base (and (symbolp ty) (eq (qint-role ty) :accum) (base-type-of ty))))
    (if (and base (not (string= (symbol-name (resolve-type-alias base))
                                (symbol-name (resolve-type-alias ty)))))
        (format nil "(accum ~(~a~))" base)
        (format nil "~(~a~)" ty))))

(defun %check-mma-qint-roles (a b c location)
  "Refuses an MMA whose quantized operands A, B do not accumulate into C (all SOURCE element types,
   possibly accessor forms).  See the endeavour 207 follow-up header above for the rule.  Plain
   operands are untyped and accepted into any accumulator."
  (let* ((a (%canonical-elem a)) (b (%canonical-elem b)) (c (%canonical-elem c))
         (qa (and (symbolp a) (eq (qint-role a) :base) a))
         (qb (and (symbolp b) (eq (qint-role b) :base) b)))
    (flet ((nm (ty) (symbol-name (resolve-type-alias ty)))
           (refuse (fmt &rest args)
             (error 'crisp-type-error :message (apply #'format nil fmt args) :source-location location)))
      (log:debug "%check-mma-qint-roles: A ~a B ~a C ~a (qints ~a ~a)" a b c qa qb)
      (when (or qa qb)
        (let ((implied
                (if (and qa qb (string/= (nm qa) (nm qb)))
                    (if (gethash (%accum-key qa qb) *accum-registry*)
                        (accum-type-of qa qb)
                        (refuse "MMA: (~(~a~) x ~(~a~)): no product is declared.  Use def-qint-product."
                                qa qb))
                    (accum-type-of (or qa qb)))))
          (unless (and (symbolp c) implied (string= (nm c) (nm implied)))
            (refuse "MMA: operands ~(~a~) x ~(~a~) accumulate into ~a, not ~a.  The scale belongs to the data: declare the accumulator ~a, or make the operands plain."
                    a b (%qint-type-display implied) (%qint-type-display c)
                    (%qint-type-display implied))))))))

(defun %qint-mma-binding-elems (bindings)
  "Alist (SYM . SOURCE-ELEM) for BINDINGS.  A tile / scratch / wgmma-accumulator constructor gives
   its element type; any other binding maps to NIL, so it SHADOWS an outer name as unknown.
   Endeavour 208: tcgen05 accumulators and accumulator rings too."
  (let ((out '()))
    (dolist (b bindings (nreverse out))
      (cond ((and (consp b) (symbolp (first b)))
             (let ((init (second b)))
               (push (cons (first b)
                           (and (consp init) (symbolp (first init))
                                (member (symbol-name (first init))
                                        '("MAKE-REGISTER-TILE" "MAKE-REGISTER-TILE-RING"
                                          "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-MATRIX-RING"
                                          "MAKE-WGMMA-ACCUMULATOR"
                                          "MAKE-TCGEN05-ACCUMULATOR" "MAKE-TCGEN05-ACCUMULATOR-RING")
                                        :test #'string=)
                                (%canonical-elem (second init))))
                     out)))
            ((and b (symbolp b))
             (push (cons b nil) out))))))

(defun %qint-mma-elem-of-type (type)
  "The element type of a register tile, wgmma accumulator or tensor TYPE, or NIL."
  (let ((rt (gethash type *register-tile-dims*))
        (wa (gethash type *wgmma-acc-dims*)))
    (cond (rt (and (third rt) (%canonical-elem (third rt))))
          (wa (and (fourth wa) (%canonical-elem (fourth wa))))
          (t (let ((canon (ignore-errors (%ts-canonicalize-tensor-type type))))
               (and (consp canon) (>= (length canon) 2) (symbolp (second canon))
                    (%canonical-elem (second canon))))))))

(defun %qint-mma-src-elem (form lex env)
  "The SOURCE element type of an MMA operand or accumulator FORM: a symbol, or (ring-get SYM I).
   LEX (from enclosing LET bindings) wins over ENV.  NIL when it cannot be known here."
  (cond ((and (consp form) (symbolp (first form)) (string= (symbol-name (first form)) "RING-GET")
              (= (length form) 3))
         (%qint-mma-src-elem (second form) lex env))
        ((and form (symbolp form))
         (let ((hit (assoc form lex)))
           (if hit
               (cdr hit)
               (let ((pd (find-variable-in-env form env)))
                 (and pd (%qint-mma-elem-of-type (parameter-def-type pd)))))))
        (t nil)))

(defun %qint-mma-walk (form lex env location)
  "Walks FORM applying %check-mma-qint-roles to every mma-accumulate-via-tile, wgmma-accumulate and
   wgmma-accumulate-via-tile, extending LEX through nested LETs.  A check runs only when A, B and C
   are all known.
   Endeavour 208: tcgen05-accumulate-via-tile too (D A B at the same positions)."
  (when (consp form)
    (let* ((head (first form))
           (hn (and (symbolp head) (symbol-name head))))
      (labels ((src (f) (%qint-mma-src-elem f lex env))
               (check (c a b)
                 (let ((cs (src c)) (as (src a)) (bs (src b)))
                   (when (and cs as bs)
                     (%check-mma-qint-roles as bs cs location))))
               (walk-all (forms l)
                 (loop for x on forms while (consp x) do (%qint-mma-walk (car x) l env location))))
        (cond
          ((and hn (member hn '("LET" "LET*") :test #'string=) (listp (second form)))
           (dolist (b (second form))
             (when (consp b) (walk-all (cdr b) lex)))
           (walk-all (cddr form) (append (%qint-mma-binding-elems (second form)) lex)))
          ((and hn (member hn '("MMA-ACCUMULATE-VIA-TILE" "WGMMA-ACCUMULATE-VIA-TILE"
                                  "TCGEN05-ACCUMULATE-VIA-TILE") :test #'string=)
                (>= (length form) 5))
           (check (nth 2 form) (nth 3 form) (nth 4 form))
           (walk-all (cdr form) lex))
          ((and hn (string= hn "WGMMA-ACCUMULATE") (>= (length form) 4))
           (check (nth 1 form) (nth 2 form) (nth 3 form))
           (walk-all (cdr form) lex))
          (t (walk-all form lex)))))))

(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: pre-lower register-tile matrix-multiply-tile-stride (endeavor 135),
   then explode register-tile bindings into per-fragment mutable variables (register residency,
   Endeavor 132), then defer to the normal let analysis.

   Endeavour 161: publishes this LET's compile-time SLM scratch-tile shapes for the duration of
   the body analysis, so operand-shape checks in the expression analyzers can see them.

   Endeavour 207: first checks the qint roles of every MMA in the LET (%qint-mma-walk), while the
   source element types are still visible."
  (%qint-mma-walk expr nil env location)
  (let ((lowered (%explode-register-tiles
                  (%expand-matmul-tile-stride-register-forms expr location)
                  location context)))
    (let ((*mma-scratch-tile-dims*
            (append (and (consp lowered)
                         (listp (second lowered))
                         (%mma-scratch-tile-dims-from-bindings (second lowered)))
                    *mma-scratch-tile-dims*)))
      (analyze-let-expression lowered env context location))))




;;;; ----------------------------------------------------------------------
;;;; Endeavour 199 -- (store-tile-at ... :via :tma): analysis
;;;; See tests/spec/199-tma-store/tma-store.md.
;;;; ----------------------------------------------------------------------

(defparameter *199-stage-bytes-per-warp* 4096
  "Endeavour 199.  Staging shared memory per warp: two 16-row x 64-column 16-bit boxes (2 KB each).")

(defparameter *199-store-box* '(16 64)
  "Endeavour 199.  The TMA store box (rows cols): one warp's 16 rows x 64 16-bit columns = 128 bytes
   wide, the most a SWIZZLE_128B box may be.")

(defun %199-stage-name (fn)
  "Endeavour 199.  The implicit-arg name of FN's TMA-store staging buffer."
  (intern (format nil "__TMA_STAGE_FROM_~a" fn) (find-package :crisp.compiler)))

(defun %199-descriptor-name (dest fn)
  "Endeavour 199.  DEST's CUtensorMap descriptor in FN -- the name %tma-lookup-descriptor-ptr rebuilds."
  (intern (format nil "~a_TENSORMAP_FROM_~a" dest fn) (symbol-package dest)))

(defun %199-type-symbol (name)
  "Endeavour 199.  The Crisp type symbol NAME (\"HALF\", \"BFLOAT16\") as Crisp source spells it."
  (or (find-symbol name :crisp-language) (intern name (find-package :crisp.compiler))))

(defun %199-convert-element (convert)
  "Endeavour 199.  The 16-bit element type a peeled conversion (TO-HALF / TO-BFLOAT16) produces."
  (cond ((null convert) nil)
        ((consp convert)
         (error 'crisp-compiler-error
                :message "store-tile-at :via :tma: stmatrix moves 16-bit elements, so an 8-bit narrowing cannot use it.  Drop :via :tma."))
        ((string= (symbol-name convert) "TO-HALF") (%199-type-symbol "HALF"))
        (t (%199-type-symbol "BFLOAT16"))))

(defun %199-via-tma-p (keys)
  "Endeavour 199.  T when the option plist KEYS says :via :tma."
  (and (evenp (length keys))
       (let ((v (getf keys :via)))
         (and v (symbolp v) (string-equal (symbol-name v) "TMA")))))

(defun %199-analyze-tma-store (expr src convert env context location)
  "Endeavour 199.  (store-tile-at (CONVERT SRC) DEST (ROW COL) :via :tma) -> semantic-wgmma-tma-store.
   Refused with a message naming the rule: a non-PTX target, a source that is not a wgmma accumulator,
   no 16-bit conversion (stmatrix moves 16-bit elements), N not a multiple of 64 (one 128-byte box),
   a destination that is not a symbol or whose element type is not the conversion's, no compile-time
   local-size (the staging buffer is sized from it), or no pass-1 registration (single-pass, helper)."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error
                  :message (format nil "store-tile-at :via :tma: ~?" fmt args)
                  :source-location location)))
    (unless (eq *target-backend* :ptx)
      (fail "the Tensor Memory Accelerator is NVIDIA sm_90 and later; this is a ~(~a~) compile." *target-backend*))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node))
           (dest     (third expr))
           (origin   (fourth expr))
           (fn       (compiler-context-current-compiling-function context)))
      (unless (%wgmma-acc-type-p src-type)
        (fail "the source must be a wgmma accumulator (make-wgmma-accumulator); ~a is ~a." src src-type))
      (unless convert
        (fail "stmatrix moves 16-bit elements, so the f32 accumulator needs a conversion: write (to-half ~a) or (to-bfloat16 ~a)." src src))
      (unless (and dest (symbolp dest))
        (fail "the destination must be the kernel's tensor parameter (its TMA descriptor is built for it), got ~s." dest))
      (unless (and (listp origin) (= (length origin) 2))
        (fail "needs a 2-D (ROW COL) element origin, got ~s." origin))
      (let* ((n        (second (gethash src-type *wgmma-acc-dims*)))
             (elem     (%199-convert-element convert))
             (dims     (%declared-local-size-dims (compiler-context-declarations context)))
             (threads  (and dims (reduce #'* dims)))
             (wgs      (and threads (floor threads 128)))
             (desc     (%199-descriptor-name dest fn))
             (stage    (%199-stage-name fn))
             (implicit (gethash fn *implicit-arg-map*))
             (info     (gethash desc *tma-descriptor-info*))
             (dest-node (analyze-expression dest env context (append location '(2))))
             (dest-type (let ((ty (semantic-node-type dest-node)))
                          (cond ((consp ty) ty)
                                ((and ty (symbolp ty))
                                 (let ((parts (unmangle-template-struct-name ty)))
                                   (if (consp parts) parts (resolve-type-alias ty))))
                                (t ty))))
             (dest-elem (and (consp dest-type) (second dest-type)))
             (to-int   (intern "TO-INT" (find-package :crisp-language))))
        (log:debug "199 :via :tma: n=~a elem=~a dims=~a desc=~a stage=~a dest-type=~a"
                   n elem dims desc stage dest-type)
        (unless (and n (zerop (mod n 64)))
          (fail "N must be a multiple of 64 (a TMA box is 64 16-bit columns = 128 bytes); this accumulator is 64x~a." n))
        (unless (and wgs (plusp wgs))
          (fail "needs the kernel's compile-time block size, (local-size :set-to N) with N at least 128: the staging buffer is 16 KB per warpgroup."))
        (unless (and (find desc implicit :key #'car) (find stage implicit :key #'car))
          (fail "its TMA descriptor and staging buffer are registered in pass 1, which did not see this store (single-pass compile, or a store outside the kernel body)."))
        (unless (getf info :store-box)
          (fail "~a is also loaded with a :block load-tile in this kernel; a tensor has one TMA descriptor, and a load's box is not the store's." dest))
        (when (and dest-elem (symbolp dest-elem)
                   (not (string= (symbol-name dest-elem) (symbol-name elem))))
          (fail "the source is converted to ~(~a~) but ~a holds ~(~a~)." elem dest dest-elem))
        ;; the staging vector's tensor type is instantiated on demand, as analyze-scratch-tensor-expression
        ;; does for a user's scratch tile -- pass 1 only named it
        (unless (valid-parameterized-type-p (cdr (find stage implicit :key #'car)))
          (fail "could not instantiate the staging buffer type ~a." (cdr (find stage implicit :key #'car))))
        (setf (gethash stage *implicit-scratch-size-expr-map*)
              (/ (+ (* wgs 4 *199-stage-bytes-per-warp*) 1024) 2))
        (log:info "199 store-tile-at :via :tma: 64x~a ~a into ~a; staging ~a = ~a warpgroups x 16 KB + 1 KB"
                  n elem dest stage wgs)
        (make-semantic-wgmma-tma-store
         :tile-node src-node
         :row-node (analyze-expression `(,to-int ,(first origin)) env context (append location '(3 0)))
         :col-node (analyze-expression `(,to-int ,(second origin)) env context (append location '(3 1)))
         :n n :element elem :dest-sym dest
         :stage stage :stage-spec (cdr (find stage implicit :key #'car))
         :one-d-p (every (lambda (d) (= d 1)) (rest dims))
         :type 'nil :source-location location)))))

(defun analyze-store-tile-at-mma (expr env context location)
  "store-tile-at overload: wgmma-accumulator at an absolute (ROW COL) origin, OR delegate to the
   ordinary cooperative store-tile-at path.

   ENDEAVOUR 154.  %wgmma-store-rewrite computes its row base as `bty * 64`, the wgmma
   instruction's fixed M, which silently bakes in ONE WARPGROUP: with a second consumer warpgroup
   the row base is unchanged and both would write the SAME 64 rows.  A cooperative 128x256 tile
   (two warpgroups splitting M, sharing one B tile) was therefore not expressible -- store-tile-at
   looked like the escape hatch but had no wgmma overload and fell through to the cooperative
   element-loop path.  The two-warpgroup kernel now writes its row offsets explicitly:

     (:consumer0 ... (store-tile-at D C ((* grid-y 128)        (* grid-x 256))))
     (:consumer1 ... (store-tile-at D C ((+ (* grid-y 128) 64) (* grid-x 256))))

   It does NOT infer the warpgroup count.  Deriving it from the tile-stride tile shape (M/64) was
   considered and rejected as UNDER-DETERMINED: a 128-row tile served by ONE warpgroup looping over
   two row halves is a legal kernel the same rule would silently mis-address.

   Dispatches on the SOURCE TYPE before the generic path runs, exactly as analyze-store-tile-mma
   does -- which also keeps the wgmma store out of %warp-spec-check-block-only, whose
   workgroup-collective deadlock rationale does not apply to a warpgroup-private accumulator spill
   (and which store-tile already bypasses for the same reason).

   ENDEAVOUR 196: the source may be (to-half D) / (to-bfloat16 D); the conversion is fused into
   each element store.  A converted source that is not a wgmma accumulator is refused.

   ENDEAVOUR 199: options after the origin.  :via :tma sends the accumulator through staging shared
   memory and TMA stores (%199-analyze-tma-store); any other :via value is refused.  Without :via
   nothing changes.

   Spec: tests/spec/154-nvidia-perf/02-wgmma-store-at-origin.crisp (validate-ptx-wgmma-store-direct)
         tests/spec/154-nvidia-perf/03-wgmma-two-warpgroups.crisp  (the cooperative kernel)
         tests/spec/196-matmul-contest/04-wgmma-store-tile-at-to-half.crisp
         tests/spec/199-tma-store/."
  (let* ((keys (nthcdr 4 expr))
         (via  (and (evenp (length keys)) (getf keys :via))))
    (when via
      (unless (%199-via-tma-p keys)
        (error 'crisp-compiler-error
               :message (format nil "store-tile-at: :via must be :tma, got ~s." via)
               :source-location location))
      (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
        (return-from analyze-store-tile-at-mma
          (%199-analyze-tma-store expr src convert env context location)))))
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node)))
      (log:debug "196 store-tile-at: src-type=~a convert=~a" src-type convert)
      (cond
        ((%wgmma-acc-type-p src-type)
         (let ((n      (second (gethash src-type *wgmma-acc-dims*)))
               (origin (fourth expr)))
           (unless (and (listp origin) (= (length origin) 2))
             (error 'crisp-compiler-error
                    :message (format nil "store-tile-at: a wgmma accumulator needs a 2-D (ROW COL) element origin, got ~S.  The accumulator is a 64xN matrix; its origin is where its top-left element lands in the destination." origin)
                    :source-location location))
           (analyze-expression
            (%wgmma-store-rewrite-origin src (third expr)
                                         (first origin) (second origin) n convert)
            env context location)))
        (convert
         (%196-refuse-converted-non-accumulator "store-tile-at" convert src-type location))
        (t
         (analyze-store-tile-at-expression expr env context location))))))

;; VERBATIM re-definition of the src/ original, with ONE added entry: LOAD-FRAGMENT-ACC.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!.
   Endeavour 154: adds STORE-TILE-AT, so a wgmma accumulator can be stored at an absolute origin
   (two cooperating consumer warpgroups); non-wgmma sources delegate unchanged."
  ;; Endeavour 208: tensor-memory bookkeeping is per compile.
  (clrhash *tcgen05-columns*)
  (clrhash *tcgen05-sync-sites*)
  (clrhash *tcgen05-kernels*)
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
                         ;; Endeavour 208: tcgen05.  The store / let entries wrap the originals.
                         (cons "MAKE-TCGEN05-ACCUMULATOR"    #'analyze-make-tcgen05-accumulator)
                         (cons "TCGEN05-ACCUMULATE-VIA-TILE" #'analyze-tcgen05-accumulate-via-tile)
                         (cons "TCGEN05-COMMIT"              #'analyze-tcgen05-commit)
                         (cons "%208-LOAD-SCALES"            #'analyze-%208-load-scales)
                         (cons "%TCGEN05-MMA-BS"             #'analyze-%tcgen05-mma-bs)
                         (cons "%TCGEN05-MMA"                #'analyze-%tcgen05-mma)
                         (cons "%TCGEN05-RESET"              #'analyze-%tcgen05-reset)
                         (cons "%TCGEN05-LD"                 #'analyze-%tcgen05-ld)
                         (cons "%TCGEN05-FENCE-AFTER"        #'analyze-%tcgen05-fence)
                         (cons "%TCGEN05-FENCE-BEFORE"       #'analyze-%tcgen05-fence)
                         (cons "%IN-WARP-ROLE"               #'analyze-%in-warp-role)
                         ;; Endeavour 208 phase 2: the accumulator ring.  RING-GET wraps the struct analyzer's.
                         (cons "MAKE-TCGEN05-ACCUMULATOR-RING" #'analyze-make-tcgen05-accumulator-ring)
                         (cons "RING-GET"                    #'%208-analyze-ring-get)
                         (cons "STORE-TILE"              #'%208-analyze-store-tile)
                         (cons "STORE-TILE-AT"           #'%208-analyze-store-tile-at)
                         (cons "LET"                     #'%208-analyze-let)
                         (cons "LET*"                    #'%208-analyze-let)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))
    ;; Endeavour 173 / BUG 069: Crisp has no LET* -- its LET is already sequential.  This is the
    ;; site that decides what `let*` means, because (intern "LET*" :crisp-language) HERE mints the
    ;; very symbol the Crisp reader later reuses for user source; the table above aliased it onto
    ;; LET, which compiled forward and then died under --differentiate blaming SET!.
    ;;
    ;; ONLY the :crisp-language spelling is rejected, which is why this sits outside the loop:
    ;; crisp.compiler uses :cl and does not shadow LET*, so (intern "LET*" cc-pkg) up there
    ;; returns COMMON-LISP:LET* -- a DIFFERENT symbol, which must stay pointed at the real LET
    ;; analyzer.  That is load-bearing, not merely tidy: instantiate-generic-function
    ;; (src/environment.lisp) injects `(let* ,bindings ,@body) to bind a &key parameter's
    ;; defaults, and that backquote is read in :crisp.compiler -- so a COMPILER LOWERING emits
    ;; the CL spelling.  Rejecting it too breaks every &key default (016-advanced-signatures/04).
    ;; User source, read in :crisp-language, reaches the rejected symbol instead.
    (setf (gethash (intern "LET*" cl-pkg) *expression-analyzers*) '%analyze-let-star-rejected)))


;;; ===========================================================================
;;; Endeavor 140 (Chapter 4) — wgmma (Hopper warpgroup async MMA) support.
;;; Folded from overlays/crisp-compiler-overlay.lisp (2026-07-21).
;;; ===========================================================================

(defvar *wgmma-acc-dims* (make-hash-table :test 'eq)
  "wgmma accumulator type symbol -> (list M N K).")

;;;; ----------------------------------------------------------------------
;;;; Endeavour 204 -- integer wgmma: the B element and s32 accumulators
;;;; See tests/spec/204-integer-mma/integer-mma.md.
;;;; ----------------------------------------------------------------------

(defvar *wgmma-node-b-elem* (make-hash-table :test 'eq)
  "semantic-mma-accumulate node -> B's element type, for the mnemonic of a mixed-sign wgmma.")

(defvar *wgmma-b-elem* nil
  "B's element type for the wgmma being emitted, bound around %emit-nvvm-wgmma.")

(defun %wgmma-acc-elem (acc-type)
  "The integer element of a wgmma accumulator type, or FLOAT."
  (or (fourth (gethash acc-type *wgmma-acc-dims*)) 'float))

(defun %wgmma-struct-of-regs (module reg-ty nacc)
  "The LLVM struct type { REG-TY x NACC } — the wgmma inline-asm result (NACC = N/2 accumulators)."
  (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count nacc)))
    (dotimes (i nacc) (setf (cffi:mem-aref elts 'llvm-type-ref i) reg-ty))
    (llvm-struct-type-in-context (llvm-get-module-context module) elts nacc nil)))

(defun %wgmma-acc-type-name (n &optional (elem 'float))
  "The minted accumulator record name.  Every float accumulator shares the F32 record, as before."
  (let ((e (%canonical-elem elem)))
    (intern (if (%elem-integer-p e)
                (format nil "WGMMA-ACC-~a-64X~d" (symbol-name e) n)
                (format nil "WGMMA-ACC-F32-64X~d" n))
            (find-package :crisp.compiler))))

(defun %wgmma-acc-type-p (type-name)
  "T if TYPE-NAME is a minted wgmma accumulator record type."
  (and (symbolp type-name) (nth-value 1 (gethash type-name *wgmma-acc-dims*))))

(defun %ensure-wgmma-acc-type (n &optional (elem 'float))
  "Mint (once) the wgmma accumulator record -- N/2 flat fields, one per register per thread across the
   128-thread warpgroup.  Fields are float, or ELEM for an integer accumulator, so a store of a field
   type-checks against the destination's own element type.  Returns the type symbol."
  (let* ((e (%canonical-elem elem))
         (int-p (%elem-integer-p e))
         (name (%wgmma-acc-type-name n e)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below (floor n 2)
             collect (list (intern (format nil "D~d" i) (find-package :crisp.compiler))
                           (if int-p e 'float)))
       :record))
    (setf (gethash name *wgmma-acc-dims*) (list 64 n 8 (and int-p e)))
    name))



;; src/mma.lisp
(defun %wgmma-shapes-of-profile ()
  "The active hardware profile's :wgmma-shapes, or NIL when no profile is active or the active
   one is silent about warpgroup shapes.

   NIL IS THE COMMON CASE AND MUST STAY CHEAP.  Nine of the eleven wgmma specs in the tree
   declare no profile at all, as does every benchmark kernel, so 'no declared wgmma shapes' is
   the path almost every compile takes.  It means the sm_90a instruction constraints apply as a
   documented fallback -- never that the kernel is rejected."
  (let ((profile (active-hardware-profile)))
    (and profile (getf profile :wgmma-shapes))))

;; src/mma.lisp
(defun %check-wgmma-shape-against-profile (shape shapes location swizzle elem)
  "CAUSE ONE: a profile DECLARES its warpgroup shapes, so membership in that list is the rule.

   The declared entries are per-slice shapes.  Without :swizzle the kernel's shape must match one
   outright.  With :swizzle the K is a K-BLOCK spanning several slices, so (M N) must match an
   entry and K must be a positive multiple of that entry's K -- the same relaxation the sm_90a
   fallback makes, kept identical so a profile cannot silently change what :swizzle means."
  (declare (ignore elem))
  (destructuring-bind (m n k) shape
    (let ((ok (some (lambda (entry)
                      (let ((dims (%mma-shape-entry-dims entry)))
                        (and dims (= (length dims) 3)
                             (= m (first dims)) (= n (second dims))
                             (let ((ek (third dims)))
                               (if swizzle
                                   (and (plusp ek) (plusp k) (zerop (mod k ek)))
                                   (= k ek))))))
                    shapes)))
      (unless ok
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate-via-tile: shape ~a is not one of the active hardware profile's :wgmma-shapes ~a." shape shapes)
               :source-location location)))))

;; src/mma.lisp
(defun %check-wgmma-shape-against-isa (shape location swizzle elem)
  "CAUSE TWO: nothing declares warpgroup shapes, so the sm_90a instruction constraints apply.

   THE THREE MESSAGES ARE DELIBERATELY UNCHANGED at their front.  tests/spec/140-wgmma/errors/
   01, 02 and 03 assert the substrings 'M must be 64', 'multiple of 8' and 'K'; those specs
   predate hardware profiles and none of them declares one, so this is the branch they take.
   The trailing sentence naming the fallback is ADDITIVE, which a substring match tolerates."
  (destructuring-bind (m n k) shape
    (unless (= m 64)
      (error 'crisp-compiler-error
             :message (format nil "wgmma: M must be 64 (wgmma is always m64), got ~a.  No active hardware profile declares :wgmma-shapes, so the sm_90a instruction constraints apply." m)
             :source-location location))
    (unless (and (>= n 8) (<= n 256) (zerop (mod n 8)))
      (error 'crisp-compiler-error
             :message (format nil "wgmma: N must be a multiple of 8 in [8,256], got ~a.  No active hardware profile declares :wgmma-shapes, so the sm_90a instruction constraints apply." n)
             :source-location location))
    (let* ((kps (%wgmma-k-per-slice elem))
           (what (case kps (32 "int8 m64nNk32") (16 "16-bit m64nNk16") (t "tf32 m64nNk8"))))
      (if swizzle
          (unless (and (plusp k) (zerop (mod k kps)))
            (error 'crisp-compiler-error
                   :message (format nil "wgmma: with :swizzle, K (the K-block) must be a positive multiple of ~a for ~a operands, got ~a." kps what k)
                   :source-location location))
          (unless (= k kps)
            (error 'crisp-compiler-error
                   :message (format nil "wgmma: K must be ~a (~a, a single k~a slice); use :swizzle :128b for a multi-slice K-block, got ~a." kps what kps k)
                   :source-location location))))))

;; src/mma.lisp
(defun %check-wgmma-shape (shape location &optional swizzle elem)
  "Validate a wgmma (M N K) shape, from the hardware profile when one describes this part and
   from the sm_90a instruction constraints when none does.

   Endeavour 161 gave this the two-branch structure %check-mma-shape has had for the FRAGMENT
   form since endeavour 132.  wgmma was the last shape check still reasoning only from hardcoded
   constants, which meant a profile could describe a part accurately and be ignored here."
  (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
    (error 'crisp-compiler-error
           :message (format nil "wgmma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." shape)
           :source-location location))
  (let ((declared (%wgmma-shapes-of-profile)))
    (if declared
        (%check-wgmma-shape-against-profile shape declared location swizzle elem)
        (%check-wgmma-shape-against-isa shape location swizzle elem))))




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
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 fields, each
   initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 occupancy report — keyed by SHAPE so a per-tile `(set! D (make-wgmma-accumulator ...))`
   re-initialization is not counted as a second accumulator.

   Endeavour 204: T selects an integer accumulator; any other T is fp32, as before."
  (destructuring-bind (elem dims init) (cdr expr)
    (destructuring-bind (m n) dims
      (let* ((int-p (%elem-integer-p elem))
             (field-init (if int-p
                             (list (intern "TO" (find-package :crisp-language)) (%canonical-elem elem) init)
                             init)))
        (if int-p
            (%check-wgmma-shape (list m n 32) location nil 'char)
            (%check-wgmma-shape (list m n 8) location))
        (%wgmma-acc-fit-check m n location)
        (%ptx-note-register-demand-keyed (floor n 2) context (list :wgmma-acc m n))
        (let ((type-name (%ensure-wgmma-acc-type n elem)))
          (analyze-expression
           `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect field-init))
           env context location))))))



(defun %wgmma-k-per-slice (elem)
  "K covered by ONE wgmma instruction at element type ELEM: 8 at 32 bits, 16 at 16 bits, 32 at 8 bits.
   All are 32 BYTES of K per slice, which is why the descriptor's kk*32 advance is unchanged."
  (case (%mma-elem-bits elem)
    (8  32)
    (16 16)
    (t  8)))

;; src/mma.lisp
(defun %wgmma-operand-mnemonic (elem)
  "The <d>.<a>.<b> tail of the wgmma mnemonic for operand element type ELEM.  An integer multiply
   names A and B separately, because their signs are independent."
  (flet ((sign (e) (if (%elem-signed-p e) "s8" "u8")))
    (let ((n (and elem (symbolp elem) (symbol-name elem))))
      (cond ((%int-operand-p elem) (format nil "s32.~a.~a" (sign elem) (sign (or *wgmma-b-elem* elem))))
            ((and n (string= n "BFLOAT16")) "f32.bf16.bf16")
            ((and n (string= n "HALF"))     "f32.f16.f16")
            (t                              "f32.tf32.tf32")))))


(defun analyze-wgmma-accumulate-base (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K]).  a/b -> (~ tile 0 [0]) with one 0 per tile dimension
   (rank-aware) so codegen's 3rd value is the addrspace(3) base — works for flat VECTOR tiles (scatter)
   AND MATRIX tiles (swizzle / Step-0 forms), independent of :swizzle.

   Endeavour 160: the per-node *wgmma-node-swizzle* entry gains a third element, the operand
   element type.  Codegen cannot recover it -- %emit-nvvm-wgmma receives an f32 accumulator type
   and raw SMEM pointers, with no fragment record to probe -- so it has to be recorded here.

   Endeavour 198: analyze-wgmma-accumulate (below) records :b-major in *wgmma-node-swizzle*."
  (destructuring-bind (d a b &rest kwargs) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node))
           (swz    (getf kwargs :swizzle))
           (a-node (analyze-expression a env context (append location '(2))))
           (a-rank (or (%get-tensor-arity (semantic-node-type a-node)) 1))
           (elem   (%coop-elem-of a-node))
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
        (let ((b-elem (%coop-elem-of (analyze-expression b env context (append location (quote (3)))))))
          (%check-mma-element-family elem b-elem (%wgmma-acc-elem d-type) location)
          (setf (gethash node *wgmma-node-b-elem*) b-elem))
        (setf (gethash node *wgmma-node-swizzle*)
              (list swz (or (getf kwargs :k) (%wgmma-k-per-slice elem)) elem))
        node))))

(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K :b-major :mn]) -- see the original.
   Endeavour 198: the *wgmma-node-swizzle* entry gains a 4th element, B-MAJOR (:k or :mn)."
  (let* ((kwargs (nthcdr 4 expr))
         (bm (getf kwargs :b-major))
         (mn (and bm (symbolp bm) (string-equal (symbol-name bm) "MN")))
         (node (analyze-wgmma-accumulate-base expr env context location)))
    (let ((entry (gethash node *wgmma-node-swizzle*)))
      (setf (gethash node *wgmma-node-swizzle*)
            (append (subseq entry 0 (min 3 (length entry))) (list (if mn :mn :k)))))
    node))

;; src/mma.lisp
(defun %check-wgmma-operands (shape a b location elem swizzle &optional (b-major :k))
  "Refuse a wgmma whose staged A or B tile is not the shape the instruction will read.

   THE RULE.  A is (M K) and B is (N K) -- both K-major.  This is not inferred from which
   kernels happen to verify; it is what CUTLASS declares for every tf32 GMMA trait in
   third_party/cutlass/include/cute/atom/mma_traits_sm90_gmma.hpp:
       FrgTypeA = FrgTypeB = GMMA::smem_desc<GMMA::Major::K>
       ALayout  = ABLayout<64, 8>      BLayout = ABLayout<64, 8>
   and the tf32 SS atoms exist ONLY in the _TN form (16 of them, no other suffix) because tf32
   wgmma carries no transpose immediate.

   ENDEAVOUR 198: at 16 bits B may instead be (K N) -- Major::MN, read with transB=1 -- when the
   kernel says so with :b-major :mn (B-MAJOR here).  A (K N) B without it is refused with a message
   naming the keyword; tf32 keeps refusing, because its wgmma has no transpose immediate.

   UNRESOLVABLE EXTENTS ARE NOT AN ERROR.  %mma-operand-extent returns NIL when a tile's shape is
   not compile-time known, and a wgmma operand is frequently (ring-get RING SLOT).  Refusing on
   NIL would reject the working pipelined kernels -- chapter 7, sec2_top, sec3, sec4 -- so an
   unknown extent skips silently, exactly as %mma-k-steps treats its own NIL.

   K IS THE PER-SLICE K, not the K-block: under :swizzle the staged tile spans several slices, so
   its K extent is the block and only A-vs-B agreement is checkable there."
  (destructuring-bind (m n k) shape
    (let ((a-r (%mma-operand-extent a nil :rows))
          (a-c (%mma-operand-extent a nil :cols))
          (b-r (%mma-operand-extent b nil :rows))
          (b-c (%mma-operand-extent b nil :cols)))
      ;; A must be (M K).  Under :swizzle the column extent is a K-block, so only M is fixed.
      (when (and a-r (/= a-r m))
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate-via-tile: A tile must be (M K) = (~a ~a) for shape ~a, but it is (~a ~a).  A is staged M-rows by K-columns, the same way mma-accumulate-via-tile stages it." m k shape a-r (or a-c '?))
               :source-location location))
      (when (and (not swizzle) a-c (/= a-c k))
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate-via-tile: A tile must be (M K) = (~a ~a) for shape ~a, but it is (~a ~a)." m k shape (or a-r '?) a-c)
               :source-location location))
      (if (eq b-major :mn)
          ;; Endeavour 198: B is (K N).  Its column extent is N; its row extent is the K-block.
          (progn
            (when (and b-c (/= b-c n))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile :b-major :mn: B tile must be (K N) = (~a ~a) for shape ~a, but it is (~a ~a)." k n shape (or b-r '?) b-c)
                     :source-location location))
            (when (and b-r (/= b-r k))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile :b-major :mn: B tile must be (K N) = (~a ~a) for shape ~a -- its K extent is the K-block -- but it is (~a ~a)." k n shape b-r (or b-c '?))
                     :source-location location)))
          (progn
            ;; B must be (N K).  This is where the two via-tile forms disagree, so say so.
            (when (and b-r (/= b-r n))
              (if (= (%wgmma-k-per-slice elem) 16)
                  (error 'crisp-compiler-error
                         :message (format nil "wgmma-accumulate-via-tile: B tile is (~a ~a), which is the Major::MN orientation.  The 16-bit wgmma reads that with transB=1: say so with :b-major :mn (it needs :swizzle :128b and N a multiple of 64), or declare B as (N K) = (~a ~a).  NOTE: mma-accumulate-via-tile takes B as (K N); the two via-tile forms differ here." b-r (or b-c '?) n k)
                         :source-location location)
                  (error 'crisp-compiler-error
                         :message (format nil "wgmma-accumulate-via-tile: B tile must be (N K) = (~a ~a) for shape ~a, but it is (~a ~a).  wgmma reads its SMEM B operand K-major (CUTLASS GMMA::Major::K) and tf32 wgmma has no transpose immediate, so (K N) is not a layout this instruction can read.  NOTE: mma-accumulate-via-tile takes B as (K N); the two via-tile forms differ here." n k shape b-r (or b-c '?))
                         :source-location location)))
            (when (and (not swizzle) b-c (/= b-c k))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile: B tile must be (N K) = (~a ~a) for shape ~a, but it is (~a ~a)." n k shape (or b-r '?) b-c)
                     :source-location location)))))))

(defun analyze-wgmma-accumulate-via-tile (expr env context location)
  "(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b] [:b-major :k | :mn]) -> (set! D
   (wgmma-accumulate D A B :swizzle :128b :k K [:b-major :mn])).  K rule is swizzle- AND
   element-aware (see %check-wgmma-shape).

   Endeavour 160: the A tile's element type is resolved here and passed to the shape check, so a
   tf32 kernel asking for K=16 is still refused while a bf16 one is accepted.

   Endeavour 161: the OPERAND SHAPES are checked too.  Order matters -- the shape check runs
   first, so a kernel that is wrong about both its triple and its tiles still reports the triple,
   which is what tests/spec/140-wgmma/errors/01-03 assert.

   Endeavour 198: :b-major :mn declares B as (K N), read with transB=1.  It needs a 16-bit element
   (tf32 wgmma has no transpose), :swizzle :128b (the MN-major descriptor is built for the 128-byte
   swizzle atom: 64 N x 8 K), and N a multiple of 64 (one atom wide)."
  (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
    (let* ((elem (%coop-elem-of (analyze-expression a env context (append location '(3)))))
           (swz  (getf kwargs :swizzle))
           (bm-raw (getf kwargs :b-major :k))
           (b-major (if (and (symbolp bm-raw) (string-equal (symbol-name bm-raw) "MN")) :mn
                        (if (and (symbolp bm-raw) (string-equal (symbol-name bm-raw) "K")) :k
                            (error 'crisp-compiler-error
                                   :message (format nil "wgmma-accumulate-via-tile: :b-major must be :k (B is (N K), the default) or :mn (B is (K N), read with transB=1), not ~s." bm-raw)
                                   :source-location location)))))
      (log:debug "198 wgmma-accumulate-via-tile: shape=~a elem=~a swizzle=~a b-major=~a" shape elem swz b-major)
      (%check-wgmma-shape shape location swz elem)
      (when (eq b-major :mn)
        (unless (= (%wgmma-k-per-slice elem) 16)
          (error 'crisp-compiler-error
                 :message (format nil "wgmma-accumulate-via-tile :b-major :mn needs a 16-bit operand (half or bfloat16): tf32 wgmma has no transpose immediate, so a ~a B can only be read as (N K)." elem)
                 :source-location location))
        (unless (%198-swizzle-128b-p swz)
          (error 'crisp-compiler-error
                 :message "wgmma-accumulate-via-tile :b-major :mn needs :swizzle :128b -- the MN-major B descriptor is built for the 128-byte swizzle atom (64 N x 8 K) that a :128b TMA load lays down."
                 :source-location location))
        (unless (zerop (rem (second shape) 64))
          (error 'crisp-compiler-error
                 :message (format nil "wgmma-accumulate-via-tile :b-major :mn needs N to be a multiple of 64 (one 128-byte swizzle atom of 16-bit elements), but N is ~a." (second shape))
                 :source-location location)))
      (%check-wgmma-operands shape a b location elem swz b-major)
      (analyze-expression `(set! ,d (wgmma-accumulate ,d ,a ,b :swizzle ,swz :k ,(third shape)
                                                      ,@(when (eq b-major :mn) (list :b-major :mn))))
                          env context location))))

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



(defvar *wgmma-16-trans* '(0 0)
  "(transA transB) immediates for the 16-bit wgmma.  Probe hook -- see the comment above.")

(defun %wgmma-asm-string (nacc n &optional elem)
  "wgmma.mma_async.sync.aligned.m64n{N}k{KPS}.<d>.<a>.<b> {$0..$nacc-1}, descA, descB, ...;
   Accumulator is an OUTPUT plus a tied INPUT, so the two 'l' descriptors are $2*nacc and
   $2*nacc+1.  tf32 takes three trailing immediates; the 16-bit forms take five, adding
   transA/transB from *wgmma-16-trans* while that pair is under investigation.  int8 takes one."
  (let* ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i)))
         (kps  (%wgmma-k-per-slice elem))
         (tail (case kps
                 (32 "1")
                 (16 (format nil "1, 1, 1, ~d, ~d" (first *wgmma-16-trans*) (second *wgmma-16-trans*)))
                 (t  "1, 1, 1"))))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk~d.~a {~a}, $~d, $~d, ~a;"
            n kps (%wgmma-operand-mnemonic elem) accs (* 2 nacc) (1+ (* 2 nacc)) tail)))


(defun %wgmma-constraints (nacc &optional int-p)
  "NACC '=f' outputs ('=r' for an integer accumulator), NACC tied inputs (0..nacc-1), 2 'l' descriptor
   inputs, memory clobber."
  (let ((outs (loop for i below nacc collect (if int-p "=r" "=f")))
        (ties (loop for i below nacc collect (format nil "~d" i))))
    (format nil "~{~a~^,~},~{~a~^,~},l,l,~~{memory}" outs ties)))



;;;; ----------------------------------------------------------------------
;;;; Endeavour 198 -- the MN-major (transB) B descriptor
;;;; See tests/spec/198-wgmma-transb/wgmma-transb.md.
;;;; ----------------------------------------------------------------------

(defun %198-wgmma-make-desc-mn (builder base-ptr kslice-byte-off lbo-bytes)
  "Endeavour 198.  The 64-bit SMEM descriptor for an MN-MAJOR 16-bit operand under the 128-byte
   swizzle (CUTLASS make_gmma_desc<Major::MN>, LayoutType::B128): the canonical layout is
   ((8 elems x 8, m) , (8 K rows, k)) -- 64 MN elements per 128-byte row, 8 rows per 1024-byte
   swizzle atom.  LBO = the stride between 64-wide MN atoms = one TMA box (K-block rows x 128 B,
   LBO-BYTES); SBO = the stride between 8-row K groups = 1024 B; swizzle bits = 1 (128B).  The k16
   slice advances 16 rows = KSLICE-BYTE-OFF (kk*2048).  start = ((addr+off)>>4)&0x3FFF at [0:13]."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (logior (ash (floor lbo-bytes 16) 16) (ash (floor 1024 16) 32) (ash 1 62)))
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "wgmn_addr"))
         (addr  (if (zerop kslice-byte-off) addr0
                    (llvm-build-add builder addr0 (llvm-const-int i32 kslice-byte-off nil) "wgmn_addr_k")))
         (sh    (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "wgmn_sh"))
         (msk   (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "wgmn_start"))
         (st64  (llvm-build-zext builder msk i64 "wgmn_start64")))
    (log:debug "198 MN-major B descriptor: LBO=~a SBO=1024 kslice-off=~a" lbo-bytes kslice-byte-off)
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "wgmn_desc")))

(defun %emit-wgmma-mma-only (builder module d-val a-ptr b-ptr acc-type n swizzle-p kslice-off
                             &optional elem b-mn-lbo)
  "Emit ONE m64nNk{8,16,32} wgmma.mma_async and nothing else -- no fence, no commit_group, no
   wait_group.  Those are GROUP-level operations and belong once around the whole k-slice
   sequence, not once per slice; see %emit-nvvm-wgmma.

   N/2 accumulators in and out, two shared-memory descriptors, and KSLICE-OFF (kk*32 bytes)
   advancing the descriptor start address.  ELEM selects the mnemonic; the 32-byte slice stride is
   the same at every width, which is why the descriptor build is untouched.  Returns the new D.

   Endeavour 198: B-MN-LBO non-NIL means B is MN-major: its descriptor is %198-wgmma-make-desc-mn
   (LBO = B-MN-LBO bytes), its slice advances 16 rows of 128 bytes (kk*2048 = KSLICE-OFF*64), and
   the instruction carries transB=1 (*wgmma-16-trans* bound to (0 1))."
  (declare (ignorable module))
  (let* ((int-p (%elem-integer-p (%wgmma-acc-elem acc-type)))
         (reg-ty (if int-p (llvm-int32-type) (llvm-float-type)))
         (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr swizzle-p kslice-off))
         (descB (if b-mn-lbo
                    (%198-wgmma-make-desc-mn builder b-ptr (* kslice-off 64) b-mn-lbo)
                    (%wgmma-make-desc builder b-ptr swizzle-p kslice-off)))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i))))
         (asm-str     (let ((*wgmma-16-trans* (if b-mn-lbo (list (first *wgmma-16-trans*) 1) *wgmma-16-trans*)))
                        (%wgmma-asm-string nacc n elem)))
         (constraints (%wgmma-constraints nacc int-p))
         (ret-ty      (%wgmma-struct-of-regs module reg-ty nacc))
         (ptypes      (append (loop repeat nacc collect reg-ty) (list i64 i64)))
         (args        (append c-ops (list descA descB)))
         (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints))
         (agg         (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
    (dotimes (i nacc)
      (setf agg (llvm-build-insert-value builder agg
                                         (llvm-build-extract-value builder call i (format nil "wo~d" i))
                                         i (format nil "wr~d" i))))
    agg))

(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n &optional swizzle-p (k 8) elem (b-major :k))
  "Emit the wgmma accumulate as ONE GROUP: a fence before the first slice, K/KPS slices, then one
   commit_group + wait_group.  See the original for why the fence/commit/wait triple is emitted
   once per GROUP rather than once per slice (endeavour 154, worth 4-11%).

   Endeavour 160: KPS -- the K covered by one instruction -- is 8 at 32 bits and 16 at 16 bits.
   The per-slice BYTE advance stays kk*32 either way, because a tf32 k8 slice and a bf16 k16 slice
   occupy the same 32 bytes.  That is why %wgmma-make-desc is untouched by this endeavour.

   Endeavour 198: B-MAJOR :mn passes the MN-major B's LBO -- one TMA box, K rows x 128 bytes -- to
   every slice (see %emit-wgmma-mma-only)."
  (let* ((kps (%wgmma-k-per-slice elem))
         (n-slices (if swizzle-p (max 1 (floor k kps)) 1))
         (b-mn-lbo (and (eq b-major :mn) (* k 128))))
    (unless swizzle-p
      (%gen-nvvm-fence-proxy-async-shared builder)
      (%ptx-barrier builder module))
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let ((cur-d d-val))
      (dotimes (kk n-slices)
        (setf cur-d (%emit-wgmma-mma-only builder module cur-d a-ptr b-ptr acc-type n swizzle-p
                                          (* kk 32) elem b-mn-lbo)))
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      (values cur-d nil))))

(defun %wgmma-store-rewrite-origin (tile dest row-origin col-origin n &optional convert)
  "Store the m64xN wgmma accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN), both absolute element indices.

   Lane mapping (= wgmma_ref.cu, unchanged): warp w within the warpgroup owns rows
   [16w, 16w+16); within a warp, lane -> row lane/4 and column pair (lane mod 4)*2; each n8
   group contributes the standard mma m16n8 C fragment at rows r0 and r0+8.

   Both origins are coerced with TO-INT.  The lane arithmetic is INT throughout (wgw and rlo come
   from to-int of warp-id / warp-lane), so a ULONG origin -- which is what any tile-stride grid
   binding produces, e.g. (* grid-y (to-ulong 128)) -- would otherwise fail to type-check with
   \"Cannot operate on ULONG and INT\".  The grid-index caller has always passed an INT for the same
   reason; this makes the absolute spelling accept either.

   ENDEAVOUR 154: emission order is ROW-MAJOR.  The natural loop is j-outer, which interleaves r0
   and r8 and writes the tile column-strip by column-strip -- 32 passes revisiting the same two
   rows.  Emitting all of row r0 and then all of row r8 lets each WARP lay down a full contiguous
   row (4 lanes x 2 floats x n8 groups) before moving on.  Pure reordering: same stores, same
   values, same addresses.  Measured on an H100 NVL, interleaved, 3 reps: +1.5% at 2048, +0.7% at
   4096, +0.5% at 1024, neutral at 256/512, nothing regressing.

   ENDEAVOUR 196: optional CONVERT (TO-HALF / TO-BFLOAT16 symbol) wraps every element read, for
   (store-tile (to-half D) C ...) -- an f32 accumulator stored into a 16-bit matrix.

   ENDEAVOUR 197: each thread's elements come in adjacent column PAIRS (c, c+1), so a pair is one
   (%store-pair ...) -- a single <2 x T> store -- under ONE (%pair-ok-p ...) test of the thread's
   first pair.  One test covers them all: every other pair is 8k columns and/or 8 rows away, i.e. a
   multiple of 2 elements on both axes once the first pair is adjacent (unit last stride) and
   2-element aligned.  When the test fails (an odd column origin, an unaligned base, a strided last
   dimension) the original scalar stores run.  H100, 4096x5120x4096 fp16: 304 -> 252 us.

   ENDEAVOUR 210 (F-209-8, D-210-7): under *210-pairs-only* (a store-tile whose DEST is declared
   (even-columns DEST)) only the packed arm is emitted: the two arms together hold the accumulator and
   both arms' addresses live (sec3: 164-168 registers vs 96 for the packed arm alone)."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (if-sym (intern "IF" (find-package :crisp-language)))
         (n8 (floor n 8)))
    (flet ((elt-of (i) (%196-wrap-conversion convert `(%extract-struct-member wgv ,i))))
      (flet ((pairs (row base-offset)
               (loop for j below n8
                     for base = (+ (* j 4) base-offset)
                     collect `(%store-pair (~ ,dest ,row (+ c0 ,(* 8 j)))
                                           (~ ,dest ,row (+ (+ c0 ,(* 8 j)) 1))
                                           ,(elt-of base) ,(elt-of (1+ base)))))
             (scalars (row base-offset)
               (loop for j below n8
                     for base = (+ (* j 4) base-offset)
                     append (list
                             `(set! (~ ,dest ,row (+ c0 ,(* 8 j)))       ,(elt-of base))
                             `(set! (~ ,dest ,row (+ (+ c0 ,(* 8 j)) 1)) ,(elt-of (1+ base)))))))
        `(let ((wgv ,tile))
           (let ((wgw (rem (,to-int (warp-id)) 4))
                 (lane (,to-int (warp-lane))))
             (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
               (let ((r0 (+ (+ (,to-int ,row-origin) (* wgw 16)) rlo)))
                 (let ((r8 (+ r0 8))
                       (c0 (+ (,to-int ,col-origin) col)))
                   ,(if *210-pairs-only*
                        ;; Endeavour 210 (D-210-7): DEST is declared (even-columns DEST), :compact
                        ;; :row-major, and a grid-origin column is even, so every pair is aligned --
                        ;; the packed arm alone (the two-arm form costs ~70 registers, F-209-8).
                        `(progn ,@(pairs 'r0 0) ,@(pairs 'r8 2))
                        `(,if-sym (%pair-ok-p (~ ,dest r0 c0) (~ ,dest r0 (+ c0 1)))
                           (progn ,@(pairs 'r0 0) ,@(pairs 'r8 2))
                           (progn ,@(scalars 'r0 0) ,@(scalars 'r8 2)))))))))))))

(defun %wgmma-store-rewrite (tile dest tile-id n &optional convert)
  "Store the m64xN wgmma accumulator TILE to DEST at grid tile-id (BTY BTX).  warp w (within the
   warpgroup) -> rows [16w,16w+16); per n8 group the standard mma m16n8 C fragment.  (= wgmma_ref.cu.)

   ENDEAVOUR 154: a thin caller of %wgmma-store-rewrite-origin with the TILE-GRID origin
   (bty*64, btx*N).  Behaviour is unchanged -- deliberately, since addressing a tile by grid index
   only identifies a 64-row tile when ONE warpgroup owns it.  Two cooperating warpgroups use
   store-tile-at with explicit origins instead.

   ENDEAVOUR 196: optional CONVERT is passed through (see %wgmma-store-rewrite-origin)."
  (let ((to-int (intern "TO-INT" (find-package :crisp-language))))
    (%wgmma-store-rewrite-origin
     tile dest
     `(* (,to-int ,(first tile-id)) 64)
     `(* (,to-int ,(second tile-id)) ,n)
     n
     convert)))

(defvar *wgmma-node-swizzle* (make-hash-table :test 'eq)
  "semantic-mma-accumulate node -> (list swizzle-mode k-block) for the wgmma path.")


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
;;; ===================================================================
;;; Endeavour 165 — the fp64 MMA backward, part 3: load-fragment-acc.
;;;
;;; analyze-load-fragment-acc is the exact INVERSE of analyze-store-fragment and carried the same
;;; two fp32 assumptions the store did before 2b-ii: it built register-fragment-acc-f32-16x8
;;; outright and used the 16x8 lane mapping (rows g and g+8 over a 16-tall tile, four elements per
;;; lane).  Against an fp64 adjoint that reads four floats where the fragment holds two doubles.
;;;
;;; Its own docstring says "a Load/Store pair always agrees".  They now agree BY CONSTRUCTION,
;;; both taking m = lane/4, n = 2*(lane%4) + v from CuTe's CLayout, rather than by two people
;;; writing the same thing twice.
;;;
;;; ELEM arrives as an optional 4th argument from %emit-per-frag-acc-load, mirroring how
;;; store-fragment receives it from %emit-per-frag-store.  Default FLOAT reproduces the old
;;; emission exactly.
;;;
;;; NOTE FOR THE SRC PATCH: analyze-load-fragment-acc REPLACES src/mma.lisp:2676;
;;; %emit-per-frag-acc-load REPLACES src/mma.lisp:2852 (supersedes the 2b-i overlay copy).
;;; ===================================================================

;; src/mma.lisp
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
  (destructuring-bind (src tile-id &optional (elem 'float)) (cdr expr)
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
          ;; Endeavour 165: fp64 reads TWO doubles at the m8n8k4 C/D layout, over a tile 8
          ;; rows tall rather than 16.  The SAME mapping as analyze-store-fragment's fp64
          ;; branch -- m = lane/4, n = 2*(lane%4) + v -- because this function's own docstring
          ;; requires a Load/Store pair to agree.  They now agree by construction: both read it
          ;; from CuTe's CLayout, instead of two people writing the same thing twice.
          (if (eql (%mma-elem-bits elem) 64)
              (progn
                ;; 2 doubles per lane = 4 32-bit registers: the same count as the f32 4x1
                ;; accumulator, arrived at differently.
                (%ptx-note-register-demand 4 context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                      (let ((row (+ (* ,ty 8) g)) (col (+ (* ,tx 8) t2)))
                        (%construct-struct register-fragment-acc-f64-8x8
                          (~ ,src row col)
                          (~ ,src row (+ col 1))))))
                 env context location))
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
             env context location)))))))

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
    (destructuring-bind (fm . fn) (%frag-mn (%register-tile-elem-of (first entry)))
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(set! ,fv (load-fragment-acc ,src
                                                     ((+ (* ,bty ,m-frags) ,mi-form)
                                                      (+ (* ,btx ,n-frags) ,nj-form))
                                                     ,(%register-tile-elem-of (first entry)))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

;;;; ============================================================================================
;;;; Folded in from overlays/crisp-compiler-overlay.lisp on 2026-08-26.
;;;; These were appended to the overlay in this order and are kept in it, because
;;;; later definitions here reference earlier ones.
;;;; ============================================================================================
;;; ===================================================================
;;; ENDEAVOUR 155 — thread the ELEMENT TYPE through register tiles.
;;;
;;; THE DEFECT.  `analyze-make-register-tile` read the element type and then threw it away:
;;;
;;;     (elem (first args))
;;;     ...
;;;     (declare (ignore elem))          ; tf32/fp32 fixed for now
;;;
;;; so `(make-register-tile-ring bfloat16 (32 16) ...)` parsed and produced FLOAT32 fragments.
;;; Confirmed in the emitted SPIR-V for benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.spv:
;;; the module contains exactly ONE float type -- `TypeFloat 259 32` -- and all three
;;; `TypeCooperativeMatrixKHR` name it as their component type.  There is no 16-bit type of any
;;; kind.  `bfloat16` survived only in parameter NAMES, inherited from the def-type.
;;;
;;; So the tensors were bf16 in memory while the matrices consuming them were fp32.  That is a
;;; CORRECTNESS bug, and it explains the seven empty `sec2_top_bf16_Crisp_*.json` result files
;;; far better than the register-pressure warning that was the first suspect.
;;;
;;; NOT DONE HERE, DELIBERATELY: the GRF byte width.  `%spv-kernel-register-demand` multiplies
;;; the element count by a hardcoded 4, and an earlier plan proposed patching that to 2 for bf16.
;;; That would have been wrong while the compiler still EMITTED float32 -- a register model
;;; precisely wrong about real code is worse than one obviously broken, because it stops warning
;;; about a kernel that genuinely will spill.  With the element type threaded, the width becomes
;;; a property of the type; that follows as step 2 and is handled below.
;;;
;;; NOTE FOR THE SRC PATCH: %elem-coop-type and %elem-bytes are new (src/mma.lisp);
;;; analyze-make-register-fragment REPLACES src/mma.lisp:318; %spv-note-register-fragment
;;; REPLACES :1204; %spv-kernel-register-demand REPLACES :1232; %explode-register-tiles
;;; REPLACES :1424.
;;; ===================================================================
;;;; ----------------------------------------------------------------------
;;;; Endeavour 204 -- integer MMA: element families
;;;; See tests/spec/204-integer-mma/integer-mma.md.
;;;; ----------------------------------------------------------------------

(defun %elem-integer-p (elem)
  "T for an element type whose primitive is an integer the MMA hardware takes."
  (and (member (%elem-prim-name elem) '("CHAR" "UCHAR" "INT" "UINT") :test #'equal) t))

(defun %elem-signed-p (elem)
  "T for an element type whose primitive is a signed integer."
  (and (member (%elem-prim-name elem) '("CHAR" "INT") :test #'equal) t))

(defun %canonical-elem (elem)
  "ELEM with a type accessor such as (accum q-a) resolved to the type it names."
  (if (%type-accessor-form-p elem) (resolve-type-accessor elem) elem))

(defun %elem-prim-name (elem)
  "The name of ELEM's underlying primitive, as a string, for a Crisp element type that may be derived
   or an (accum T) form.  Compared by NAME because CHAR and friends are shadowed differently across
   the packages."
  (let ((e (%canonical-elem elem)))
    (and e (symbolp e) (symbol-name (get-type-base (resolve-type-alias e))))))

(defun %int-operand-p (elem)
  "T for an element type an integer MMA can take as an A or B operand: 8-bit."
  (eql (%mma-elem-bits elem) 8))

(defun %check-mma-element-family (a b c location)
  "Refuses an MMA whose operands and accumulator do not belong together, where the failure used to
   surface as `Expected FLOAT but inferred INT` or as a llvm-spirv exit code.  No hardware mixes the
   two families, and no emulation is offered."
  (let ((a-int (%elem-integer-p a)) (b-int (%elem-integer-p b)) (c-int (%elem-integer-p c)))
    (when (or a-int b-int c-int)
      (unless (and a-int b-int c-int)
        (error 'crisp-compiler-error
               :message (format nil "MMA: integer and float do not mix: A is ~(~a~), B is ~(~a~), the accumulator is ~(~a~).  An integer MMA needs 8-bit operands and an integer accumulator."
                                a b c)
               :source-location location))
      (unless (and (%int-operand-p a) (%int-operand-p b))
        (error 'crisp-compiler-error
               :message (format nil "MMA: integer operands must be 8-bit (char or uchar); A is ~(~a~), B is ~(~a~)." a b)
               :source-location location))
      (unless (eql (%mma-elem-bits c) 32)
        (error 'crisp-compiler-error
               :message (format nil "MMA: an integer accumulator must be 32-bit; got ~(~a~)." c)
               :source-location location))
      (when (and (or (%elem-signed-p a) (%elem-signed-p b)) (not (%elem-signed-p c)))
        (error 'crisp-compiler-error
               :message (format nil "MMA: accumulator ~(~a~) must be signed: a product involving a signed operand can be negative." c)
               :source-location location)))))

(defun %elem-coop-type (elem)
  "The SPIR-V cooperative-matrix component type for a Crisp element type.

   Returns the Crisp type symbol to embed in a `(coop-matrix <T> rows cols use)` semantic type.
   Anything unrecognised falls back to FLOAT — the pre-155 behaviour — so an element type this
   function has not been taught about degrades to what the compiler did before rather than
   erroring in a code path that has nothing to do with the user's mistake.  Shape/type agreement
   is validated separately (see the typed :mma-shapes work); this is a lowering detail."
  (if (%elem-integer-p elem)
      (get-type-base (resolve-type-alias (%canonical-elem elem)))
      (case elem
        ((bfloat16) 'bfloat16)
        ((half)     'half)
        ((float)    'float)
        ((double)   'double)
        (t          'float))))

(defun %elem-bytes (elem)
  "Bytes per element for a Crisp element type, for the Intel GRF register model.

   This is the number that used to be a hardcoded 4 in %spv-kernel-register-demand.  It is only
   correct to consult it now that the element type actually reaches codegen -- before endeavour
   155 every fragment was float32 regardless of what the source asked for, so 4 was the truth
   about the emitted code even when it was a lie about the source."
  (let ((name (%elem-prim-name elem)))
    (cond ((member name '("CHAR" "UCHAR") :test #'equal) 1)
          ((member name '("BFLOAT16" "HALF") :test #'equal) 2)
          ((equal name "DOUBLE") 8)
          (t 4))))

(defun %coop-elem-of (tensor-node)
  "The coop-matrix COMPONENT TYPE for an operand, derived from its tensor type's element type
   (NOT hardcoded).  Mirrors %coop-layout-of, which derives the MemoryLayout the same way and
   for the same reason: at a load site the operand is usually a kernel parameter carrying a
   MANGLED type symbol, which only %TS-CANONICALIZE-TENSOR-TYPE can expand.
   Endeavour 155.  load-fragment-a / -b previously built `(coop-matrix float ...)` outright, so
   a bf16 operand was loaded as float32 -- the emitted SPIR-V for the bf16 benchmark kernel
   contained exactly one float type (32-bit) and no 16-bit type at all.
   Unresolvable types keep FLOAT, the historical behaviour.  ACCUMULATORS ARE DELIBERATELY NOT
   ROUTED THROUGH HERE: XMX/DPAS and the NVIDIA tensor cores take bf16 operands and accumulate in
   fp32, so an f32 accumulator paired with bf16 operands is correct, not an oversight.

   Endeavour 207: an INTEGER element is returned as its primitive base (q-a -> CHAR), the same
   answer %elem-coop-type gives a register tile of that element.  A derived name here made a q-a
   operand load disagree with the q-a register tile it was loaded into.  Floats are unchanged."
  (let* ((canon (%ts-canonicalize-tensor-type (get-single-value-type tensor-node)))
         (elem  (and (consp canon) (>= (length canon) 2) (second canon))))
    (cond ((not (and elem (symbolp elem))) 'float)
          ((%elem-integer-p elem) (%elem-coop-type elem))
          (t elem))))

;; tests/run-specs.lisp
(defun %spv-float-ids (txt width)
  "Result-ids of every `TypeFloat <id> <width>` in a disassembled SPIR-V module, as strings."
  (cl:let ((ids cl:nil) (pos 0))
    (cl:loop
      (cl:let ((i (cl:search "TypeFloat " txt :start2 pos)))
        (cl:unless i (cl:return-from %spv-float-ids (cl:nreverse ids)))
        (cl:let* ((rest (cl:subseq txt (cl:+ i 10) (cl:min (cl:length txt) (cl:+ i 40))))
                  (toks (%spv-tokens rest)))
          (cl:when (cl:and (cl:>= (cl:length toks) 2)
                           (cl:equal (cl:second toks) (cl:princ-to-string width)))
            (cl:push (cl:first toks) ids)))
        (cl:setf pos (cl:1+ i))))))

;; tests/run-specs.lisp
(defun %spv-tokens (s)
  "Whitespace-split S into a list of strings."
  (cl:let ((out cl:nil) (cur (cl:make-string-output-stream)))
    (cl:loop for ch across s do
      (cl:if (cl:member ch (cl:list #\Space #\Tab #\Newline #\Return))
          (cl:let ((tok (cl:get-output-stream-string cur)))
            (cl:when (cl:plusp (cl:length tok)) (cl:push tok out)))
          (cl:write-char ch cur)))
    (cl:let ((tok (cl:get-output-stream-string cur)))
      (cl:when (cl:plusp (cl:length tok)) (cl:push tok out)))
    (cl:nreverse out)))

;; tests/run-specs.lisp
(defun %spv-coop-uses-p (txt type-id)
  "T if any TypeCooperativeMatrixKHR in TXT names TYPE-ID as its COMPONENT TYPE (the token
   immediately after the matrix's own result id)."
  (cl:let ((pos 0))
    (cl:loop
      (cl:let ((i (cl:search "TypeCooperativeMatrixKHR " txt :start2 pos)))
        (cl:unless i (cl:return-from %spv-coop-uses-p cl:nil))
        (cl:let* ((rest (cl:subseq txt (cl:+ i 25) (cl:min (cl:length txt) (cl:+ i 80))))
                  (toks (%spv-tokens rest)))
          (cl:when (cl:and (cl:>= (cl:length toks) 2) (cl:equal (cl:second toks) type-id))
            (cl:return-from %spv-coop-uses-p cl:t)))
        (cl:setf pos (cl:1+ i))))))

;;;; ============================================================================
;;;; Endeavour 155 Phase A — a coop-matrix element-type validator that is actually strong enough.
;;;;
;;;; WHY THE FIRST ONE WAS NOT.  validate-spv-bf16-coop asserted "a 16-bit float type exists, SOME
;;;; cooperative matrix uses it, and an f32 type also exists".  Every one of those is true of a
;;;; module in which MOST A/B operands are still float32 — which is exactly the module Crisp emits
;;;; today.  The validator was built to catch "the element type was discarded" and cannot see "the
;;;; element type was discarded ON SOME PATHS", which is the bug that was really there.
;;;;
;;;; THE ASSERTION THAT ACTUALLY PINS IT.  In SPIR-V a cooperative matrix declares its role:
;;;;
;;;;     7 TypeCooperativeMatrixKHR <result> <component> <scope> <rows> <cols> <use>
;;;;
;;;; where <use> is an ID naming an integer constant: 0 = A, 1 = B, 2 = Accumulator.  So the
;;;; module states, per matrix, both what it is FOR and what it is MADE OF.  The real invariant of
;;;; a mixed-precision MMA is therefore checkable exactly:
;;;;
;;;;     every A-use and B-use matrix has the DECLARED ELEMENT width
;;;;     every Accumulator-use matrix is fp32
;;;;
;;;; and a stray f32 A-operand — the actual defect — fails it.  Observed on probe_half.spv:
;;;;     360 comp=f32 use=A   <-- caught      363 comp=f16 use=A   ok
;;;;     372 comp=f32 use=B   <-- caught      374 comp=f16 use=B   ok
;;;;                                          383 comp=f32 use=Acc ok
;;;; ============================================================================

;; tests/run-specs.lisp
(defun %spv-lines (txt)
  "TXT split into lines, each tokenised.  The disassembled SPIR-V text form is one instruction per
   line, `<word-count> <Opcode> <operands...>`, so token 1 is the opcode and token 2 is normally
   the result id.  Parsing by line rather than by substring search matters: a bare (search
   \"Constant \" ...) also matches SpecConstant, ConstantComposite and ConstantNull."
  (cl:let ((out cl:nil) (start 0) (len (cl:length txt)))
    (cl:loop
      (cl:let ((nl (cl:position #\Newline txt :start start)))
        (cl:let ((line (cl:subseq txt start (cl:or nl len))))
          (cl:let ((toks (%spv-tokens line)))
            (cl:when (cl:>= (cl:length toks) 2) (cl:push toks out))))
        (cl:if nl (cl:setf start (cl:1+ nl)) (cl:return-from %spv-lines (cl:nreverse out)))))))

;; tests/run-specs.lisp
(defun %spv-int-constants (txt)
  "Alist of (result-id-string . integer-value) for every scalar OpConstant in TXT.

   Needed because a cooperative matrix's Use operand is not a literal — it is an ID pointing at a
   constant, so `use 130` means nothing until 130 is resolved to 0 / 1 / 2."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "Constant")
                       (cl:>= (cl:length toks) 5))
        (cl:let ((v (cl:ignore-errors (cl:parse-integer (cl:fifth toks)))))
          (cl:when v (cl:push (cl:cons (cl:fourth toks) v) out)))))))

;; tests/run-specs.lisp
(defun %spv-float-widths (txt)
  "Alist of (type-id-string . width) for every OpTypeFloat in TXT."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeFloat")
                       (cl:>= (cl:length toks) 4))
        (cl:let ((w (cl:ignore-errors (cl:parse-integer (cl:fourth toks)))))
          (cl:when w (cl:push (cl:cons (cl:third toks) w) out)))))))

;; tests/run-specs.lisp
(defun %spv-use-name (use)
  "Human name for a cooperative-matrix Use operand value."
  (cl:case use (0 "A") (1 "B") (2 "Accumulator") (cl:t (cl:format cl:nil "use=~a" use))))

;; tests/run-specs.lisp
(defun validate-spv-fp16-coop (spv-path)
  "Endeavour 155 — assert an fp16 (`half`) register tile reached the hardware AS fp16, on EVERY
   operand, with an fp32 accumulator.

   WHY fp16 CARRIES THE 16-BIT COVERAGE AND bf16 CANNOT.  bf16 cannot be loaded on the BMG driver
   at all (see validate-spv-bf16-coop), so a bf16 rung can never be taken to metal here.  fp16
   goes through the IDENTICAL typed path — same register tiles, same (8 16 16) shape, same DPAS
   rate — and DOES load and run.  So fp16 is what makes 16-bit MMA testable end to end on Intel,
   and bf16 rungs stay compile-and-inspect until the driver catches up.

   No extension is required: fp16 is core SPIR-V."
  (%validate-coop-operand-elem spv-path 16 "half/fp16"))

;;;; ============================================================================
;;;; Endeavour 155 Phase C — THE SHAPE IS PART OF THE TYPE.
;;;;
;;;; This is the endeavour's actual subject, arrived at from the other end.  Phase B made every
;;;; cooperative matrix carry its real element type; the fp16 kernel then failed to LOAD, and the
;;;; driver said exactly why:
;;;;
;;;;     undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_PackedA_RowMajor_
;;;;                             SG16_8x8_i16_4_global_v8i8_pi32_i32'
;;;;
;;;; IGC lowers KHR cooperative-matrix loads to internal JointMatrix builtins, and there is no
;;;; `8x8_i16` builtin because 8x8 IS NOT A VALID 16-BIT DPAS SHAPE.  A was 8x8 and B was 8x16 --
;;;; the K=8 TF32 shapes, carrying 16-bit elements.
;;;;
;;;; WHY.  %spv-mma-shape returned (first shapes) from the profile's :mma-shapes, ignoring both the
;;;; element type AND the shape the kernel asked for.  The kernel says (mma-accumulate-via-tile
;;;; (8 16 16) ...) -- K=16, correct for fp16 -- and got K=8 fragments anyway.
;;;;
;;;; THE UNDERLYING RULE, which the profiles have documented in a comment all along:
;;;;
;;;;     :mma-shapes ((8 16 8) (8 16 16) (8 16 32))  ; XMX tf32, bf16/fp16, int8
;;;;
;;;; K scales INVERSELY with element width, because K x element-bits is a fixed fragment footprint
;;;; -- 256 bits on both shipped profiles:
;;;;     bmg   tf32 8x32=256   fp16 16x16=256   int8 32x8=256
;;;;     h100  tf32 8x32=256   fp16 16x16=256
;;;; So a shape list is only meaningful WITH a type, which is what "typed :mma-shapes" means.
;;;;
;;;; TWO WAYS TO SAY IT, AND BOTH ARE ACCEPTED.  The honest long-term form is for a profile to
;;;; declare the type outright:
;;;;     :mma-shapes ((float 8 16 8) (half 8 16 16) (int8 8 16 32))
;;;; That format is supported here and takes precedence.  Existing untyped 3-lists keep working and
;;;; are matched by the width rule above.  One selection function is the single place that knows
;;;; either encoding, so migrating profiles later is a data change, not a code change.
;;;;
;;;; FALLBACK IS THE OLD BEHAVIOUR, DELIBERATELY.  When no entry matches the element -- e.g. the
;;;; many specs carrying (def-hardware-profile bmg :mma-shapes ((8 16 8))) -- selection returns
;;;; (first shapes), exactly what it returned before.  Those specs are all float, so they are
;;;; unaffected; a 16-bit tile on such a profile still gets the wrong shape, but it now fails at
;;;; load with the driver's own diagnostic rather than silently computing nonsense.  Making that a
;;;; compile-time refusal wants its own rung.
;;;; ============================================================================
(defun %mma-elem-bits (elem)
  "Bit width of a Crisp MMA element type, or NIL if unknown."
  (let ((n (%elem-prim-name elem)))
    (and n
         (cond ((string= n "HALF")     16)
               ((string= n "BFLOAT16") 16)
               ((string= n "FLOAT")    32)
               ((string= n "DOUBLE")   64)
               ((string= n "INT8")      8)
               ((string= n "UINT8")     8)
               ((string= n "CHAR")      8)
               ((string= n "UCHAR")     8)
               ((string= n "INT")      32)
               ((string= n "UINT")     32)
               (t nil)))))

(defun %mma-shape-entry-dims (entry)
  "The (M N K) triple of an :mma-shapes ENTRY, whether it is an untyped 3-list (8 16 8) or a
   TYPED 4-list (half 8 16 16)."
  (cond ((and (listp entry) (= (length entry) 3)) entry)
        ((and (listp entry) (= (length entry) 4)) (cdr entry))
        (t nil)))

(defun %mma-shape-entry-type (entry)
  "The declared element type of a TYPED :mma-shapes entry, or NIL for an untyped 3-list."
  (and (listp entry) (= (length entry) 4) (symbolp (first entry)) (first entry)))

(defun %mma-shape-for-elem (shapes elem)
  "The (M N K) entry of SHAPES appropriate to element type ELEM, or NIL if none is.

   A TYPED entry wins outright when its declared type matches.  Otherwise the width rule applies:
   K x element-bits is a constant fragment footprint, so the right entry is the one whose K equals
   that constant divided by the element width.  The constant is read off the profile's own float
   entry rather than hardcoded, so a part with a different footprint still resolves correctly."
  (let ((bits (%mma-elem-bits elem)))
    (when (and shapes bits)
      (or
       ;; 1. an explicitly typed entry for this element type
       (let ((hit (find-if (lambda (e)
                             (let ((ty (%mma-shape-entry-type e)))
                               (and ty (string= (symbol-name ty) (symbol-name elem)))))
                           shapes)))
         (and hit (%mma-shape-entry-dims hit)))
       ;; 2. the width rule, calibrated on this profile's own 32-bit entry
       (let* ((base (or (let ((typed-f (find-if (lambda (e)
                                                  (let ((ty (%mma-shape-entry-type e)))
                                                    (and ty (= (or (%mma-elem-bits ty) 0) 32))))
                                                shapes)))
                          (and typed-f (third (%mma-shape-entry-dims typed-f))))
                        (third (%mma-shape-entry-dims (first shapes)))))
              (footprint (and base (* base 32)))
              (want-k (and footprint (plusp bits) (/ footprint bits))))
         (when (and want-k (integerp want-k))
           (let ((hit (find-if (lambda (e)
                                 (let ((d (%mma-shape-entry-dims e)))
                                   (and d (null (%mma-shape-entry-type e)) (eql (third d) want-k))))
                               shapes)))
             (and hit (%mma-shape-entry-dims hit)))))))))

(defun %register-tile-elems-from-bindings (bindings)
  "Alist (SYM . ELEM) for every register-tile or register-tile-ring binding in BINDINGS.
   Both constructors put the element type in the same position: (make-register-tile* ELEM (M N) ...).

   Endeavour 207: ELEM may be a type ACCESSOR such as (accum q-a).  It is recorded resolved
   (%canonical-elem -> Q-A-ACCUM); before, anything but a symbol was dropped, and the tile then read
   back as FLOAT."
  (let ((out '()))
    (dolist (b bindings (nreverse out))
      (when (and (consp b) (= (length b) 2) (symbolp (first b))
                 (consp (second b))
                 (or (%register-tile-init-form-p (second b))
                     (%register-tile-ring-init-form-p (second b))))
        (let ((elem (%canonical-elem (second (second b)))))
          (when (symbolp elem)
            (push (cons (first b) elem) out)))))))

(defun %register-tile-elem-of (name)
  "The element type recorded for register tile NAME, or FLOAT when unknown (pre-155 behaviour)."
  (or (cdr (assoc name *register-tile-elems*)) 'float))

(defun %warp-grid-dims (n-warps m-frags n-frags)
  "Endeavour 155: factor N-WARPS into a (GM . GN) 2-D warp grid over an M-FRAGS x N-FRAGS fragment
   grid, or NIL when no factorisation divides both axes evenly (caller then walks linearly).

   Prefers the SQUAREST per-warp block, minimising |m-frags/GM - n-frags/GN|.  That is what
   maximises operand sharing: a warp holding an mp x np block needs mp A-fragments and np
   B-fragments, and for a fixed mp*np the SUM mp+np is smallest when they are equal.  A row strip
   (GM=1) is the degenerate worst case -- np = n-frags, so every warp needs the whole of B."
  (when (and (integerp n-warps) (> n-warps 1)
             (integerp m-frags) (integerp n-frags) (plusp m-frags) (plusp n-frags))
    (let ((best nil) (best-score nil))
      (loop for gm from 1 to n-warps do
        (when (zerop (mod n-warps gm))
          (let ((gn (floor n-warps gm)))
            (when (and (<= gm m-frags) (<= gn n-frags)
                       (zerop (mod m-frags gm)) (zerop (mod n-frags gn)))
              (let ((score (abs (- (floor m-frags gm) (floor n-frags gn)))))
                (when (or (null best-score) (< score best-score))
                  (setf best (cons gm gn) best-score score)))))))
      best)))

(defun %warp-grid-from-bindings (bindings context location)
  "Scan a LET's BINDINGS for the accumulator register-tile that carries :warps and return the
   (GM . GN) warp grid implied by its fragment grid and participating-warp count, else NIL.

   Only the ACCUMULATOR defines the grid: it is the tile whose fragments are partitioned one-per-
   warp, and the operands merely follow that partition."
  (declare (ignorable location) (ignore context))
  (let ((grid nil))
    (dolist (b bindings grid)
      (when (and (consp b) (= (length b) 2) (symbolp (first b))
                 (%register-tile-init-form-p (second b)))
        (let* ((form (second b))
               (elem (second form))
               (dims (third form))
               (m (first dims)) (n (second dims))
               (operand (getf (nthcdr 4 form) :operand :acc))
               (warps-in (getf (nthcdr 4 form) :warps)))
          (when (and (eq operand :acc) warps-in)
            (let* ((mask (%normalize-warp-mask (%warp-mask-unquote warps-in) location))
                   (n-true (and mask (count-if #'identity mask))))
              (when (and n-true (> n-true 1))
                (destructuring-bind (fr . fc) (%frag-mn-for-operand :acc elem)
                  (let ((g (%warp-grid-dims n-true (floor m fr) (floor n fc))))
                    (when g (setf grid g))))))))))))

(defun %operand-warp-divisor (operand)
  "How many DISTINCT slices an operand tile has under the current *WARP-GRID*: GM for :a (warps in
   a grid row share A rows), GN for :b (warps in a column share B columns), 1 otherwise."
  (let ((g *warp-grid*))
    (cond ((null g) 1)
          ((eq operand :a) (car g))
          ((eq operand :b) (cdr g))
          (t 1))))

;;;; ============================================================================
;;;; Endeavour 155 Step 2b — INDEXING AND LOADING A WARP-SLICED OPERAND.
;;;;
;;;; Step 2a made an operand tile allocate only its warp's slice.  Two consumers still assumed the
;;;; whole tile, and both must follow or the kernel indexes a fragment that no longer exists
;;;; ("Unknown variable NIL"):
;;;;
;;;;   a-operand / b-operand      map a LOGICAL (mi, ks) / (nj, ks) to the warp's LOCAL index.
;;;;                              mi and nj are compile-time integers and a warp's rows are the
;;;;                              contiguous range [wm*mp, (wm+1)*mp), so the local row is just
;;;;                              (mod mi mp) -- the warp's own position never has to be known.
;;;;
;;;;   %emit-per-frag-block-load  emit only the warp's fragments, at global coordinates offset by
;;;;                              its grid position.  This one CANNOT be arithmetic on compile-time
;;;;                              indices: load-tile appears ONCE in the body while each warp loads
;;;;                              a DIFFERENT slice, so it needs the static per-warp switch the MMA
;;;;                              walk uses.  A has gm distinct slices (selected by wp/gn), B has
;;;;                              gn (selected by wp mod gn) -- warps in a grid row share A rows,
;;;;                              warps in a column share B columns.
;;;; ============================================================================
(defun %warp-slice-extent (entry operand)
  "For a warp-sliced operand ENTRY, how many fragments along its SLICED axis one warp holds --
   mp for :a (rows), np for :b (columns) -- or NIL when the tile is not sliced.

   ENTRY is (NAME M N SYMS N-TRUE FIRST-TRUE OPERAND); sliced means a warp grid is in scope and
   this tile's N-TRUE exceeds 1, i.e. it carried its own :warps mask."
  (let ((g *warp-grid*)
        (n-true (fifth entry)))
    (when (and g (integerp n-true) (> n-true 1) (member operand '(:a :b)))
      (multiple-value-bind (sm sn sk) (%spv-mma-shape)
        (declare (ignorable sk))
        (if (eq operand :a)
            (max 1 (floor (max 1 (floor (second entry) sm)) (car g)))
            (max 1 (floor (max 1 (floor (third entry) sn)) (cdr g))))))))

;; tests/run-specs.lisp
(defun %spv-i64-type-ids (txt)
  "Result-ids of every 64-bit OpTypeInt in TXT."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeInt")
                       (cl:>= (cl:length toks) 4)
                       (cl:equal (cl:fourth toks) "64"))
        (cl:push (cl:third toks) out)))))

;; tests/run-specs.lisp
(defun validate-spv-tile-address-arith (spv-path)
  "Endeavour 155 rung 04 — assert tile address arithmetic does not scale PER FRAGMENT.

   Counts 64-bit OpIMul against OpCooperativeMatrixLoadKHR.  Address computation is per-TILE work
   and fragment loads are per-FRAGMENT work, so more 64-bit multiplies than loads means the
   arithmetic is being redone for every fragment -- which on Xe is an EMULATED multiply
   (mul/mach/macl, no native 64-bit multiply) and measured ~98% of the emitted instruction stream.

   A ratio rather than a threshold, deliberately: absolute instruction counts move with tile shape
   and compiler version, but 'address math must not be per-fragment' is the actual property.

   DEGRADES TO PASS when llvm-spirv is unavailable, matching the other .spv validators."
  (cl:let* ((tool (resolve-tool-executable "llvm-spirv"))
            (txt-path (cl:format cl:nil "~a.155addr" (uiop:native-namestring spv-path))))
    (cl:multiple-value-bind (o e code)
        (uiop:run-program (cl:list (uiop:native-namestring tool) "--to-text"
                                   (uiop:native-namestring spv-path) "-o" txt-path)
                          :output :string :error-output :string :ignore-error-status cl:t)
      (cl:declare (cl:ignore o e))
      (cl:if (cl:or (cl:not (cl:zerop code)) (cl:not (probe-file txt-path)))
          (cl:progn
            (cl:format cl:*error-output*
                       "  (validate-spv-tile-address-arith: llvm-spirv unavailable — SKIPPING)~%")
            cl:t)
          (cl:let ((txt (uiop:read-file-string txt-path)))
            (cl:ignore-errors (cl:delete-file txt-path))
            (cl:let* ((i64s (%spv-i64-type-ids txt))
                      (imul 0) (loads 0))
              (cl:dolist (toks (%spv-lines txt))
                (cl:when (cl:string= (cl:second toks) "IMul")
                  (cl:when (cl:member (cl:third toks) i64s :test #'cl:string=)
                    (cl:incf imul)))
                (cl:when (cl:string= (cl:second toks) "CooperativeMatrixLoadKHR")
                  (cl:incf loads)))
              (cl:cond
                ((cl:zerop loads)
                 (cl:format cl:*error-output*
                            "FAIL: no cooperative-matrix loads in the module — the tile did not lower.~%")
                 cl:nil)
                ((cl:>= imul loads)
                 (cl:format cl:*error-output*
                            "FAIL: ~d 64-bit integer multiplies for ~d cooperative-matrix loads.~%~
                             Address arithmetic is being recomputed PER FRAGMENT.  Xe has no native~%~
                             64-bit multiply, so each is emulated as mul/mach/macl -- measured ~~98%~
                             of the emitted instruction stream against 16 dpas.  Addresses within a~%~
                             tile differ by a fixed delta and should come from one per-tile base.~%"
                            imul loads)
                 cl:nil)
                (cl:t
                 (cl:format cl:*error-output* "  (~d i64 IMul for ~d coop loads)~%" imul loads)
                 cl:t))))))))

;;;; Endeavour 157 — split-barrier validators.
;;;;
;;;; Why a validator and not a correctness test: emitting a FUSED ControlBarrier where a split half
;;;; was asked for still computes the right answer.  It silently costs exactly what the feature
;;;; exists to save -- a stall per iteration per subgroup -- so no amount of MMA_CORRECT can catch
;;;; it.  The only place the difference is visible is the opcode.
(defun %spv-disasm (spv-path)
  "Disassembled SPIR-V text for SPV-PATH, or NIL when llvm-spirv is unavailable.

   Degrades to NIL rather than erroring, matching %validate-coop-operand-elem: a CUDA-only box has
   no bundled bin/llvm-spirv, and a missing tool should not read as a failing kernel."
  (cl:let ((tool (ignore-errors (resolve-tool-executable "llvm-spirv"))))
    (cl:when (cl:and tool (probe-file spv-path))
      (multiple-value-bind (out err code)
          (uiop:run-program (cl:list (uiop:native-namestring tool) "--to-text"
                                     (uiop:native-namestring spv-path) "-o" "-")
                            :output :string :error-output :string :ignore-error-status cl:t)
        (cl:declare (cl:ignore err))
        (cl:when (cl:zerop code) out)))))

(defun validate-spv-split-barrier (spv-path)
  "Endeavour 157 rung 01 — assert BOTH halves of the split barrier reached SPIR-V.

   Checks three things, because two of them can be right while the third is wrong:
     * ControlBarrierArriveINTEL is present   -- the announcement half
     * ControlBarrierWaitINTEL is present     -- the blocking half
     * Capability SplitBarrierINTEL declared  -- the driver is actually asked for the feature

   A module missing the capability may still load on a permissive driver and fail on a strict one,
   which is the kind of difference that shows up as someone else's bug report."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- split-barrier check skipped)~%") cl:t)
        (cl:let ((arrive (search "ControlBarrierArriveINTEL" txt))
                 (wait   (search "ControlBarrierWaitINTEL" txt))
                 (cap    (search "Capability SplitBarrierINTEL" txt))
                 (ok     cl:t))
          (cl:unless arrive
            (format t "FAIL: no ControlBarrierArriveINTEL -- (sync-workgroup :arrive) did not reach SPIR-V.~%")
            (cl:setf ok cl:nil))
          (cl:unless wait
            (format t "FAIL: no ControlBarrierWaitINTEL -- (sync-workgroup :wait) did not reach SPIR-V.~%")
            (cl:setf ok cl:nil))
          (cl:unless cap
            (format t "FAIL: SplitBarrierINTEL capability not declared -- the module uses the split ops without requesting SPV_INTEL_split_barrier.~%")
            (cl:setf ok cl:nil))
          ok))))

(defun validate-spv-fused-barrier-unchanged (spv-path)
  "Endeavour 157 rung 02 — assert the FUSED (sync-workgroup) is untouched.

   A regression guard.  Teaching a builtin that has always taken zero arguments to accept one is
   exactly the change that quietly alters the zero-argument path, and every kernel Crisp has ever
   shipped uses that path.  So: a plain ControlBarrier must be present, and NEITHER split op may
   appear -- a fused barrier that silently became a split pair would deadlock differently, not
   compute differently."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- fused-barrier check skipped)~%") cl:t)
        (cl:let ((fused  (search "ControlBarrier " txt))
                 (arrive (search "ControlBarrierArriveINTEL" txt))
                 (wait   (search "ControlBarrierWaitINTEL" txt))
                 (ok     cl:t))
          (cl:unless fused
            (format t "FAIL: no plain ControlBarrier -- the fused (sync-workgroup) stopped lowering.~%")
            (cl:setf ok cl:nil))
          (cl:when (cl:or arrive wait)
            (format t "FAIL: a split-barrier op appeared in a kernel that only uses the FUSED form.~%")
            (cl:setf ok cl:nil))
          ok))))

;;; Endeavour 180 spec validators: count the loads in the SHIPPED module.

(defun %spv-scalar-load-count (spv-path width)
  "Endeavour 180.  The number of OpLoad instructions in SPV-PATH whose result is the WIDTH-bit
   float type (32 or 64), read from `llvm-spirv --to-text`; NIL when llvm-spirv is unavailable.
   Counts only inside functions NOT named *_grad, so a --differentiate module (forward + gradient
   kernel) counts the forward kernel alone.  In the specs' streaming kernels (B[i] = 2*A[i]) every
   such load is a load of A: the loads per trip of the unrolled loop plus its remainder loop's one."
  (let ((txt (%spv-disasm spv-path)))
    (when txt
      (let ((float-ids nil) (names (make-hash-table :test 'equal)) (loads 0) (counting nil))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 4) (string= (second toks) "TypeFloat")
                                 (string= (fourth toks) (princ-to-string width)))
                            (push (third toks) float-ids))
                           ((and (>= (length toks) 4) (string= (second toks) "Name"))
                            (setf (gethash (third toks) names) (string-trim "\"" (fourth toks))))))))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 4) (string= (second toks) "Function"))
                            (let ((nm (gethash (fourth toks) names "")))
                              (setf counting (not (search "_grad" nm :test #'char-equal)))))
                           ((and (>= (length toks) 2) (string= (second toks) "FunctionEnd"))
                            (setf counting nil))
                           ((and counting (>= (length toks) 3) (string= (second toks) "Load")
                                 (member (third toks) float-ids :test #'string=))
                            (incf loads))))))
        (log:debug "180: ~a has ~d f~d load(s) outside *_grad functions" spv-path loads width)
        loads))))

;;;; ----------------------------------------------------------------------
;;;; Endeavour 192 (cache hints) -- SPIR-V spec validators (CacheControl{Load,Store}INTEL census)
;;;; See tests/spec/192-cache-hints/cache-hints.md.
;;;; ----------------------------------------------------------------------

;; src/mma.lisp
(defun %spv-cache-control-census (spv-path)
  "Endeavour 192.  Read SPV-PATH (llvm-spirv --to-text) and return, as a plist:
     :load-deco  hash id -> list of (level control) from `Decorate ID CacheControlLoadINTEL L C`
     :store-deco hash id -> list of (level control) from `Decorate ID CacheControlStoreINTEL L C`
     :load-ptrs  pointer ids of every OpLoad   (`N Load TYPE RESULT PTR ...`)
     :store-ptrs pointer ids of every OpStore  (`N Store PTR VALUE ...`)
   or NIL when llvm-spirv is unavailable."
  (let ((txt (%spv-disasm spv-path)))
    (when txt
      (let ((ld (make-hash-table :test 'equal)) (st (make-hash-table :test 'equal))
            (load-ptrs '()) (store-ptrs '()))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 6) (string= (second toks) "Decorate")
                                 (member (fourth toks) '("CacheControlLoadINTEL" "6442") :test #'string=))
                            (push (list (fifth toks) (sixth toks)) (gethash (third toks) ld)))
                           ((and (>= (length toks) 6) (string= (second toks) "Decorate")
                                 (member (fourth toks) '("CacheControlStoreINTEL" "6443") :test #'string=))
                            (push (list (fifth toks) (sixth toks)) (gethash (third toks) st)))
                           ((and (>= (length toks) 5) (string= (second toks) "Load"))
                            (push (fifth toks) load-ptrs))
                           ((and (>= (length toks) 4) (string= (second toks) "Store"))
                            (push (third toks) store-ptrs))))))
        (log:debug "192: ~a: ~d load-decorated id(s), ~d store-decorated id(s), ~d load(s), ~d store(s)"
                   spv-path (hash-table-count ld) (hash-table-count st) (length load-ptrs) (length store-ptrs))
        (list :load-deco ld :store-deco st :load-ptrs load-ptrs :store-ptrs store-ptrs)))))

;; src/mma.lisp
(defun %spv-cache-fail (fmt &rest args)
  "Endeavour 192.  Print a FAIL line (the SPIR-V validators report on stdout, like 180's) and return NIL."
  (format t "FAIL: ~?~%" fmt args)
  nil)

;; src/mma.lisp
(defun %spv-deco-is (deco level control)
  "Endeavour 192.  T when the decoration list DECO contains (LEVEL CONTROL)."
  (member (list (princ-to-string level) (princ-to-string control)) deco :test #'equal))

;; src/mma.lisp
(defun validate-spv-cache-streaming-loads (spv-path)
  "Endeavour 192 / spec 11: A is :streaming, B is not.  Some load goes through a CacheControlLoadINTEL
   pointer; every such pointer is L1 Streaming + L3 Streaming (0 2 / 1 2); no pointer is
   store-decorated."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let* ((ld (getf c :load-deco)) (st (getf c :store-deco))
               (hinted (remove-if-not (lambda (p) (gethash p ld)) (getf c :load-ptrs)))
               (plain (remove-if (lambda (p) (gethash p ld)) (getf c :load-ptrs))))
          (cond ((null hinted) (%spv-cache-fail "no load through a CacheControlLoadINTEL pointer"))
                ((null plain) (%spv-cache-fail "every load is decorated; B is not :streaming"))
                ((notevery (lambda (p) (and (%spv-deco-is (gethash p ld) 0 2) (%spv-deco-is (gethash p ld) 1 2)))
                           hinted)
                 (%spv-cache-fail "a decorated load is not L1 Streaming + L3 Streaming (0 2 / 1 2)"))
                ((plusp (hash-table-count st)) (%spv-cache-fail "a store is decorated (only A, an input, is :streaming)"))
                (t t))))))

;; src/mma.lisp
(defun validate-spv-cache-streaming-stores (spv-path)
  "Endeavour 192 / spec 12: C is :streaming.  Some store goes through a CacheControlStoreINTEL pointer;
   every such pointer is L1 Streaming + L3 Streaming (0 3 / 1 3); no pointer is load-decorated."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let* ((ld (getf c :load-deco)) (st (getf c :store-deco))
               (hinted (remove-if-not (lambda (p) (gethash p st)) (getf c :store-ptrs))))
          (cond ((null hinted) (%spv-cache-fail "no store through a CacheControlStoreINTEL pointer"))
                ((notevery (lambda (p) (and (%spv-deco-is (gethash p st) 0 3) (%spv-deco-is (gethash p st) 1 3)))
                           hinted)
                 (%spv-cache-fail "a decorated store is not L1 Streaming + L3 Streaming (0 3 / 1 3)"))
                ((plusp (hash-table-count ld)) (%spv-cache-fail "a load is decorated (only C, the output, is :streaming)"))
                (t t))))))

;; src/mma.lisp
(defun validate-spv-cache-coop-streaming (spv-path)
  "Endeavour 192 / spec 16: an Intel XMX matmul whose A, B, C are :streaming.  Some id carries
   CacheControlLoadINTEL L1+L3 Streaming (0 2 / 1 2) and some id CacheControlStoreINTEL L1+L3
   Streaming (0 3 / 1 3); no decoration names any other control."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let ((ld (getf c :load-deco)) (st (getf c :store-deco)))
          (flet ((streaming-ids (table l c3)
                   (loop for id being the hash-keys of table using (hash-value deco)
                         when (and (%spv-deco-is deco 0 l) (%spv-deco-is deco 1 c3)) collect id))
                 (odd-ids (table good)
                   (loop for id being the hash-keys of table using (hash-value deco)
                         unless (every (lambda (d) (string= (second d) good)) deco) collect id)))
            (cond ((null (streaming-ids ld 2 2))
                   (%spv-cache-fail "no CacheControlLoadINTEL 0 2 / 1 2 (streaming) decoration"))
                  ((null (streaming-ids st 3 3))
                   (%spv-cache-fail "no CacheControlStoreINTEL 0 3 / 1 3 (streaming) decoration"))
                  ((or (odd-ids ld "2") (odd-ids st "3"))
                   (%spv-cache-fail "a cache-control decoration names a non-streaming control"))
                  (t t)))))))

(defun %validate-spv-stream-loads (spv-path width lo hi what)
  "Endeavour 180.  T when SPV-PATH has between LO and HI (inclusive; HI NIL = no limit) WIDTH-bit
   float loads; prints WHAT on failure.  Skips (T) when llvm-spirv is unavailable."
  (let ((n (%spv-scalar-load-count spv-path width)))
    (cond ((null n)
           (format t "  (llvm-spirv unavailable -- load-count check skipped)~%") t)
          ((and (>= n lo) (or (null hi) (<= n hi))) t)
          (t (format t "FAIL: ~d f~d load(s) in the shipped SPIR-V; expected ~a.~%" n width what)
             nil))))

(defun validate-spv-stream-unrolled-x4 (spv-path)
  "Endeavour 180: the float stream loop is unrolled x4 -- at least 4 float loads (body), at most 5
   (plus the remainder loop's one)."
  (%validate-spv-stream-loads spv-path 32 4 5 "4 or 5 (x4 body + remainder) -- the stream default did not unroll"))

(defun validate-spv-stream-unrolled-x8 (spv-path)
  "Endeavour 180: the float stream loop is unrolled x8 -- 8 or 9 float loads."
  (%validate-spv-stream-loads spv-path 32 8 9 "8 or 9 (x8 body + remainder) -- (unroll 8) did not reach the loop"))

(defun validate-spv-stream-double-unrolled-x2 (spv-path)
  "Endeavour 180: the double stream loop is unrolled x2 (16 bytes in flight) -- 2 or 3 double loads,
   never the 4+ a fixed x4 would give."
  (%validate-spv-stream-loads spv-path 64 2 3 "2 or 3 (x2 body + remainder) -- the default is a byte budget, 16 bytes = 2 doubles"))

(defun validate-spv-stream-not-unrolled (spv-path)
  "Endeavour 180: (unroll nil) -- exactly one float load, the loop as it was."
  (%validate-spv-stream-loads spv-path 32 1 1 "exactly 1 -- (unroll nil) did not stop the unrolling"))

(defun validate-ptx-has-nounroll-pragma (file ptx-text)
  "Endeavour 180: {llvm.loop.unroll.disable} reached the PTX as .pragma \"nounroll\", so ptxas
   leaves the loop alone too."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((search ".pragma \"nounroll\"" ptx-text) t)
        (t (format t "FAIL: no .pragma \"nounroll\" in the PTX -- (unroll nil) was lost.~%") nil)))



;; Endeavour 182 -- launch-bound validators.
(defun %ptx-minnctapersm (ptx-text)
  "Endeavour 182.  The integer of the first .minnctapersm directive in PTX-TEXT, or NIL."
  (let ((p (search ".minnctapersm" ptx-text)))
    (and p (parse-integer ptx-text :start (+ p (length ".minnctapersm")) :junk-allowed t))))

(defun %validate-ptx-minnctapersm (ptx-text expected)
  (let ((got (%ptx-minnctapersm ptx-text)))
    (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
          ((eql got expected)
           (or (search ".maxntid" ptx-text)
               (progn (format t "FAIL: .minnctapersm ~a without a .maxntid~%" got) nil)))
          (t (format t "FAIL: expected .minnctapersm ~a in the PTX, found ~a.~%" expected got) nil))))

(defun validate-ptx-minnctapersm-4 (file ptx-text)
  "Endeavour 182: the entry carries launch bounds with .minnctapersm 4 (and a .maxntid)."
  (declare (ignore file))
  (%validate-ptx-minnctapersm ptx-text 4))

(defun validate-ptx-minnctapersm-2 (file ptx-text)
  "Endeavour 182: the entry carries launch bounds with .minnctapersm 2 (and a .maxntid)."
  (declare (ignore file))
  (%validate-ptx-minnctapersm ptx-text 2))

(defun validate-ptx-no-minnctapersm (file ptx-text)
  "Endeavour 182: the entry carries NO launch bounds -- ptxas keeps its default register budget."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((or (search ".minnctapersm" ptx-text) (search ".maxntid" ptx-text))
         (format t "FAIL: unexpected launch bounds (.maxntid / .minnctapersm) in the PTX.~%") nil)
        (t t)))

(defun %spv-prefetch-shapes (txt)
  "List of (BLOCK-WIDTH . BLOCK-HEIGHT) for every Subgroup2DBlockPrefetchINTEL in TXT, with the
   constant IDs resolved to integers.  Operand order is
     ElementSize BlockWidth BlockHeight BlockCount SrcBase MemWidth MemHeight MemPitch Coord
   and %spv-lines keeps the leading word-count token, so BlockWidth is the FOURTH token and
   BlockHeight the FIFTH.

   Resolution goes through the EXISTING %spv-int-constants (src/mma.lisp), which returns an ALIST.
   An earlier version of this file defined its own hash-table-returning %spv-int-constants and
   silently clobbered that one, breaking validate-spv-bf16-coop / -fp16-coop with \"hash-table is
   not of type LIST\".  Check for an existing definition before adding a helper to this overlay."
  (cl:let ((consts (%spv-int-constants txt))
           (out    cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "Subgroup2DBlockPrefetchINTEL")
                       (cl:>= (cl:length toks) 5))
        (cl:push (cl:cons (cl:cdr (cl:assoc (cl:fourth toks) consts :test #'cl:string=))
                          (cl:cdr (cl:assoc (cl:fifth toks)  consts :test #'cl:string=)))
                 out)))))

;; src/mma.lisp
(defun %validate-prefetch-shape-list (shapes expected-count where)
  "Shared body for both 158 validators: SHAPES must have EXPECTED-COUNT entries and every one must
   be the 32x16 hardware block.  WHERE names the rung for the failure message."
  (cl:let ((ok cl:t))
    (cl:unless (cl:= (length shapes) expected-count)
      (format t "FAIL: ~a -- expected ~a Subgroup2DBlockPrefetchINTEL instruction~:p, found ~a.~%"
              where expected-count (length shapes))
      (cl:setf ok cl:nil))
    (cl:loop for s in shapes
             for n from 0
             do (cl:unless (cl:and (eql (car s) 16) (eql (cdr s) 32))
                  (format t "FAIL: ~a -- prefetch ~a has block shape ~ax~a, expected the 32x16 ~
                             HARDWARE block.  A shape equal to the :size FOOTPRINT means the ~
                             compiler passed the footprint straight through instead of tiling it, ~
                             and an illegal shape fails at MODULE BUILD rather than here.~%"
                          where n (cdr s) (car s))
                  (cl:setf ok cl:nil)))
    ok))

;; src/mma.lisp
(defun validate-spv-prefetch-partitioned (spv-path)
  "Endeavour 158 rung 01 — :warp-partitioned actually distributed the footprint.

   The kernel prefetches a 128x256 footprint, which is 4x16 = 64 blocks of 32x16, over 16 warps.
   That is 4 ROUNDS, so exactly FOUR prefetch instructions must be emitted, each of the hardware
   shape.  Partitioned: 4 static instructions x 16 warps = 64 issues, covering 64 blocks once
   each.  Unpartitioned, the same coverage needs 64 static forms that EVERY warp runs = 1024
   issues.  That 16x is what made round-2 arm B read 2.6x slower, and no correctness check can
   see it."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- prefetch-partitioned check skipped)~%") cl:t)
        (%validate-prefetch-shape-list (%spv-prefetch-shapes txt) 4 "158/01 :warp-partitioned"))))

;; src/mma.lisp
(defun validate-spv-prefetch-unpartitioned (spv-path)
  "Endeavour 158 rung 02 — prefetch-tile WITHOUT :warp-partitioned is untouched.

   A regression guard, not a feature test.  Adding a keyword to a form that has never had one is
   exactly the change that quietly alters the path without it, and every prefetch kernel Crisp has
   shipped (benchmarks/matmul/_kdepth/pf*.crisp, sec4_fused_relu) takes that path.  A 32x16 :size
   must still emit exactly ONE prefetch of that shape, issued by every subgroup."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- prefetch-unpartitioned check skipped)~%") cl:t)
        (%validate-prefetch-shape-list (%spv-prefetch-shapes txt) 1 "158/02 unpartitioned"))))

;;;; ----------------------------------------------------------------------
;;;; Endeavour 208 -- tcgen05 (Blackwell tensor cores): accumulators in tensor memory, the synchronous / pipelined / ring forms, :via :tma, tf32, int8 + qint, block-scaled microfloats
;;;; See tests/spec/208-tcgen05/tcgen05.md.
;;;; ----------------------------------------------------------------------

(defvar *tcgen05-acc-dims* (make-hash-table :test 'eq)
  "Endeavour 208.  tcgen05 accumulator record type -> (M N ELEM).")

(defvar *tcgen05-columns* (make-hash-table :test 'equal)
  "Endeavour 208.  (KERNEL . LOCATION) of a make-tcgen05-accumulator let binding -> its first
   tensor-memory column.  Keyed by SITE, so re-analysing the same binding reuses its columns and two
   bindings that happen to share a name do not.")

(defvar *tcgen05-sync-sites* (make-hash-table :test 'equal)
  "Endeavour 208.  (KERNEL . LOCATION) of a synchronous tcgen05 accumulate -> its mbarrier index.")

(defvar *tcgen05-kernels* (make-hash-table :test 'equal)
  "Endeavour 208.  KERNEL (upper-case string) -> plist (:columns C :sync-sites S): the tensor-memory
   columns its accumulators occupy and how many synchronous accumulate sites it has.  The kernel
   prologue and epilogue (generate-function-body) read it to allocate, initialise and free.")

(defvar *tcgen05-role-warps* nil
  "Endeavour 208.  (FIRST-WARP . COUNT) of the with-warp-specialization role being analysed, NIL
   outside any role.  The issuing thread of an MMA is lane 0 of FIRST-WARP (warp 0 outside a role),
   and the epilogue rule reads COUNT.")

(defun %208-kernel-key (context)
  "Endeavour 208.  The function being compiled, as an upper-case string, or NIL."
  (let ((f (and context (compiler-context-current-compiling-function context))))
    (and f (string-upcase (princ-to-string f)))))

(defun %208-kernel-info (key)
  "Endeavour 208.  KEY's entry in *tcgen05-kernels*, created empty on first use."
  (or (gethash key *tcgen05-kernels*)
      (setf (gethash key *tcgen05-kernels*) (list :columns 0 :sync-sites 0))))

(defun %tcgen05-arch-ok-p ()
  "Endeavour 208.  T when the target is PTX for an architecture with tcgen05: the sm_100a family.
   Plain sm_100 is NOT enough -- the tcgen05 instructions are architecture-specific, and PTX built
   for .target sm_100 refuses them."
  (and (eq *target-backend* :ptx)
       (member (string-downcase (ptx-compute-capability-string))
               '("sm_100a" "sm_100f" "sm_101a" "sm_101f" "sm_103a" "sm_103f" "sm_110a" "sm_110f")
               :test #'string=)
       t))

(defun %tcgen05-require-arch (form-name location)
  "Endeavour 208.  Refuse FORM-NAME unless the target has tcgen05 (D-208-1)."
  (unless (%tcgen05-arch-ok-p)
    (error 'crisp-compiler-error
           :message (format nil "~a: tcgen05 is the Blackwell datacenter tensor core and needs an architecture-specific target: --ir-target=ptx --ir-target-arch=sm_100a (B200 / GB200).  The target here is ~a.  On sm_90a use make-wgmma-accumulator / wgmma-accumulate-via-tile; elsewhere make-register-tile / mma-accumulate-via-tile."
                            form-name
                            (if (eq *target-backend* :ptx) (ptx-compute-capability-string) (string-downcase (princ-to-string *target-backend*))))
           :source-location location)))

(defun %tcgen05-acc-type-name (m n elem)
  "Endeavour 208.  The minted tcgen05 accumulator record name."
  (intern (format nil "TCGEN05-ACC-~a-~dX~d" (if (%elem-integer-p elem) "S32" "F32") m n)
          (find-package :crisp.compiler)))

(defun %tcgen05-acc-type-p (type-name)
  "Endeavour 208.  T if TYPE-NAME is a minted tcgen05 accumulator record type."
  (and type-name (symbolp type-name) (nth-value 1 (gethash type-name *tcgen05-acc-dims*)) t))

(defun %ensure-tcgen05-acc-type (m n elem)
  "Endeavour 208.  Mint (once) the record naming a tensor-memory accumulator.  It holds none of the
   M x N values -- those live in tensor memory -- only two uint fields:
     COLUMN  the accumulator's first column, relative to the kernel's tensor-memory allocation;
     FRESH   1 until the first MMA after (re)initialisation.  That MMA OVERWRITES D (the ISA's
             enable-input-d predicate is false), so tensor memory never needs zeroing (D-208-5)."
  (let ((name (%tcgen05-acc-type-name m n elem)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (list (list (intern "COLUMN" (find-package :crisp.compiler)) 'uint)
             (list (intern "FRESH" (find-package :crisp.compiler)) 'uint))
       :record))
    (setf (gethash name *tcgen05-acc-dims*) (list m n elem))
    name))

(defun %ensure-tcgen05-row-type ()
  "Endeavour 208.  Mint (once) the record one tcgen05.ld.32x32b.x32 fills: 32 float fields, the
   32 consecutive columns of the calling thread's own tensor-memory lane (its accumulator row)."
  (let ((name (intern "TCGEN05-ROW32-F32" (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below 32 collect (list (intern (format nil "R~d" i) (find-package :crisp.compiler)) 'float))
       :record))
    name))

(defun %tcgen05-check-acc-shape (m n location)
  "Endeavour 208, phase 1.  M = 128 (the full 128-lane datapath, 'Layout D'); N a multiple of 16 in
   [16, 256] -- the PTX table allows steps of 8 at M = 128 for kind::f16, but CUTLASS's tf32 atom asks
   16, and 16 is valid under both until metal says otherwise."
  (unless (eql m 128)
    (error 'crisp-compiler-error
           :message (format nil "tcgen05: M must be 128, got ~a.  A 128-row accumulator uses all 128 tensor-memory lanes, one per row; M = 64 uses half the datapath and is not supported yet." m)
           :source-location location))
  (unless (and (integerp n) (<= 16 n 256) (zerop (mod n 16)))
    (error 'crisp-compiler-error
           :message (format nil "tcgen05: N must be a multiple of 16 in [16, 256], got ~a." n)
           :source-location location)))

(defun analyze-%tcgen05-reset (expr env context location)
  "Endeavour 208.  (%tcgen05-reset D) -> D with its columns kept and FRESH set: the re-initialisation
   `(set! D (make-tcgen05-accumulator ..))` is rewritten to (set! D (%tcgen05-reset D)) by the let
   pre-pass, because a set!'s value is analysed without knowing its target."
  (let* ((d (second expr))
         (d-node (analyze-expression d env context (append location '(1))))
         (d-type (semantic-node-type d-node))
         (to-uint (intern "TO-UINT" (find-package :crisp-language))))
    (unless (%tcgen05-acc-type-p d-type)
      (error 'crisp-compiler-error
             :message (format nil "(set! ~a (make-tcgen05-accumulator ..)): ~a is not a tcgen05 accumulator (its type is ~a).  Bind it with make-tcgen05-accumulator in a let first." d d d-type)
             :source-location location))
    (analyze-expression `(%construct-struct ,d-type (%extract-struct-member ,d 0) (,to-uint 1))
                        env context location)))

(defun analyze-%in-warp-role (expr env context location)
  "Endeavour 208.  (%in-warp-role FIRST COUNT BODY..) -- with-warp-specialization's role body,
   analysed as (progn BODY..) with *tcgen05-role-warps* bound to (FIRST . COUNT).  The node is the
   progn's, so the IR is unchanged; only the tcgen05 forms read the binding."
  (destructuring-bind (first count &rest body) (cdr expr)
    (let ((*tcgen05-role-warps* (cons first count)))
      (analyze-expression (cons (intern "PROGN" (find-package :crisp-language)) body)
                          env context location))))

(defun %tcgen05-16bit-elem-p (elem)
  "Endeavour 208.  T for half / bfloat16."
  (and elem (symbolp elem) (member (symbol-name elem) '("HALF" "BFLOAT16") :test #'string=) t))

(defun %208-issue-warp ()
  "Endeavour 208.  The warp whose lane 0 issues tcgen05.mma / tcgen05.commit: the first warp of the
   enclosing with-warp-specialization role, else warp 0 (D-208-7).  MMA and commit must come from
   the SAME thread -- a commit tracks only the MMAs its own thread issued -- and this rule gives both
   the same one."
  (if *tcgen05-role-warps* (car *tcgen05-role-warps*) 0))

(defun analyze-%tcgen05-mma (expr env context location)
  "Endeavour 208.  (%tcgen05-mma D A B K [BAR]) -> the semantic-tcgen05-op :mma node, typed as D.
   A / B become (~ tile 0 0) so codegen's third value is the shared-memory base (as for wgmma).  A
   site without BAR is synchronous and gets its own mbarrier index in this kernel."
  (destructuring-bind (d a b k &optional bar) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node))
           (a-rank (or (%get-tensor-arity (semantic-node-type (analyze-expression a env context (append location '(2))))) 1))
           (b-rank (or (%get-tensor-arity (semantic-node-type (analyze-expression b env context (append location '(3))))) 1))
           (a-ref  (analyze-expression (if (>= a-rank 2) `(~ ,a 0 0) `(~ ,a 0)) env context (append location '(2))))
           (b-ref  (analyze-expression (if (>= b-rank 2) `(~ ,b 0 0) `(~ ,b 0)) env context (append location '(3))))
           (elem   (%coop-elem-of (analyze-expression a env context (append location '(2)))))
           (b-elem (%coop-elem-of (analyze-expression b env context (append location '(3)))))
           (bar-node (and bar (analyze-expression bar env context (append location '(5)))))
           (key    (%208-kernel-key context))
           (site   (unless bar
                     (let ((s (cons key location)))
                       (or (gethash s *tcgen05-sync-sites*)
                           (let ((i (getf (%208-kernel-info key) :sync-sites 0)))
                             (setf (getf (gethash key *tcgen05-kernels*) :sync-sites) (1+ i))
                             (setf (gethash s *tcgen05-sync-sites*) i))))))
           (dims   (gethash d-type *tcgen05-acc-dims*)))
      (log:debug "208 %tcgen05-mma: ~a x ~a K=~a ~a issue-warp=~a sync-site=~a"
                 elem b-elem k dims (%208-issue-warp) site)
      (make-semantic-tcgen05-op
       :op :mma
       :args (if bar-node (list d-node a-ref b-ref bar-node) (list d-node a-ref b-ref))
       :plist (list :m (first dims) :n (second dims) :k k :elem elem :b-elem b-elem
                    :issue-warp (%208-issue-warp) :sync-site site :kernel key)
       :type d-type
       :source-location location))))

(defun analyze-tcgen05-commit (expr env context location)
  "Endeavour 208.  (tcgen05-commit BAR): BAR arrives once every tcgen05 MMA the issuing thread has
   issued so far has finished (D-208-3).  Issued by the same thread as the MMAs (%208-issue-warp)."
  (%tcgen05-require-arch "tcgen05-commit" location)
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "tcgen05-commit: expected (tcgen05-commit BARRIER)."
           :source-location location))
  (make-semantic-tcgen05-op
   :op :commit
   :args (list (analyze-expression (second expr) env context (append location '(1))))
   :plist (list :issue-warp (%208-issue-warp))
   :type 'void
   :source-location location))

(defun analyze-%tcgen05-fence (expr env context location)
  "Endeavour 208.  (%tcgen05-fence-after) / (%tcgen05-fence-before): tcgen05.fence::after_thread_sync
   / ::before_thread_sync, ordering tensor-memory access against the thread synchronisation around it."
  (declare (ignore env context))
  (make-semantic-tcgen05-op
   :op (if (search "AFTER" (symbol-name (first expr))) :fence-after :fence-before)
   :args nil :plist nil :type 'void :source-location location))

(defun %208-declared-local-size (context)
  "Endeavour 208.  The kernel's (local-size :set-to ..) thread count, or NIL when not a compile-time
   constant."
  (let* ((f    (and context (compiler-context-current-compiling-function context)))
         (decl (and f (getf (gethash f *kernel-dispatch-declarations*) :local-size)))
         (pos  (and (consp decl) (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "SET-TO"))) decl)))
         (dims (and pos (nth (1+ pos) decl))))
    (log:debug "208 local-size decl of ~a: ~s" f decl)
    (cond ((integerp dims) dims)
          ((and (consp dims) (every #'integerp dims)) (reduce #'* dims))
          (t nil))))

(defun %tcgen05-check-epilogue-threads (context location)
  "Endeavour 208 (D-208-6).  Reading a tcgen05 accumulator back is a warpgroup's job: warp w of a
   warpgroup may read only tensor-memory lanes 32(w mod 4) .. +31, so it takes four consecutive warps
   to cover 128 rows.  Inside a role the role must be 4 warps; outside one the kernel must be 128
   threads."
  (let ((role *tcgen05-role-warps*))
    (if role
        (unless (= (cdr role) 4)
          (error 'crisp-compiler-error
                 :message (format nil "store-tile of a tcgen05 accumulator: the role storing it has ~a warp~:p, but it takes exactly 4 (one warpgroup).  Warp w may read only tensor-memory lanes 32(w mod 4) .. +31, so four consecutive warps cover the 128 rows." (cdr role))
                 :source-location location))
        (let ((ls (%208-declared-local-size context)))
          (unless (eql ls 128)
            (error 'crisp-compiler-error
                   :message (format nil "store-tile of a tcgen05 accumulator outside a with-warp-specialization role needs (local-size :set-to 128) -- exactly one warpgroup -- but the local size is ~a.  With more warps, store it from a 4-warp role." (or ls "not a compile-time constant"))
                   :source-location location))))))

(defun %208-rewrite-acc-reinit (form)
  "Endeavour 208.  FORM with every (set! X (make-tcgen05-accumulator ...)) rewritten to
   (set! X (%tcgen05-reset X)).  STRUCTURE-PRESERVING: a subtree containing no such pattern is returned
   as the SAME conses (EQ), because source positions are looked up by cons identity -- copying every let
   body lost the file:line of every die / log site (193-logging-output printed `DIE ?:0`)."
  (cond ((atom form) form)
        ((and (symbolp (first form)) (string-equal (symbol-name (first form)) "SET!")
              (= (length form) 3) (symbolp (second form))
              (consp (third form)) (symbolp (first (third form)))
              (string-equal (symbol-name (first (third form))) "MAKE-TCGEN05-ACCUMULATOR"))
         (log:debug "208: (set! ~a (make-tcgen05-accumulator ..)) -> (%tcgen05-reset ~a)" (second form) (second form))
         (list (first form) (second form)
               (list (intern "%TCGEN05-RESET" (find-package :crisp.compiler)) (second form))))
        (t (let ((new-car (%208-rewrite-acc-reinit (car form)))
                 (new-cdr (%208-rewrite-acc-reinit (cdr form))))
             (if (and (eq new-car (car form)) (eq new-cdr (cdr form)))
                 form
                 (cons new-car new-cdr))))))

(defun %208-analyze-let (expr env context location)
  "Endeavour 208.  LET: the accumulator re-initialisation rewrite, then the existing let analyzer.
   EXPR itself is passed through untouched (EQ) when nothing is rewritten.
   Possible cleanup: a first line in analyze-let-with-tile-explosion."
  (let* ((body (and (consp expr) (cddr expr)))
         (new-body (and body (%208-rewrite-acc-reinit body))))
    (analyze-let-with-tile-explosion (if (and body (not (eq new-body body)))
                                         (list* (first expr) (second expr) new-body)
                                         expr)
                                     env context location)))

(defvar *tcgen05-ring-dims* (make-hash-table :test 'eq)
  "Endeavour 208.  tcgen05 accumulator RING record type -> (M N ELEM RING-COUNT).")

(defun %ensure-tcgen05-ring-type (m n elem count)
  "Endeavour 208.  Mint (once) the record naming a RING of COUNT tensor-memory accumulators: one uint
   field, COLUMN, the first column of slot 0.  Slot i starts at COLUMN + i*N."
  (let ((name (intern (format nil "TCGEN05-ACC-RING-~a-~dX~d-X~d" (if (%elem-integer-p elem) "S32" "F32") m n count)
                      (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name (list (list (intern "COLUMN" (find-package :crisp.compiler)) 'uint)) :record))
    (setf (gethash name *tcgen05-ring-dims*) (list m n elem count))
    name))

(defun %tcgen05-ring-type-p (type-name)
  "Endeavour 208.  T if TYPE-NAME is a minted tcgen05 accumulator ring type."
  (and type-name (symbolp type-name) (nth-value 1 (gethash type-name *tcgen05-ring-dims*)) t))

(defun %208-assign-columns (context location ncols form-name)
  "Endeavour 208.  The first tensor-memory column of the binding at LOCATION, assigned on first sight
   (NCOLS columns); refused when the kernel's total passes 512 (D-208-4)."
  (let* ((key  (%208-kernel-key context))
         (site (cons key location))
         (info (%208-kernel-info key)))
    (or (gethash site *tcgen05-columns*)
        (let* ((off   (getf info :columns 0))
               (total (+ off ncols)))
          (when (> total 512)
            (error 'crisp-compiler-error
                   :message (format nil "~a: this kernel's tcgen05 accumulators need ~a tensor-memory columns, over the 512 a CTA has.  A float (M N) accumulator takes N columns, so two 128 x 256 accumulators fill it." form-name total)
                   :source-location location))
          (setf (getf (gethash key *tcgen05-kernels*) :columns) total)
          (setf (gethash site *tcgen05-columns*) off)))))

(defun %208-analyze-ring-get (expr env context location)
  "Endeavour 208.  (ring-get RING i) on a tcgen05 accumulator ring -> accumulator i, FRESH, at column
   COLUMN + i*N.  Every other ring goes to analyze-ring-get-expression unchanged.
   Possible cleanup: a first clause in analyze-ring-get-expression."
  (let* ((ring (second expr))
         (rtype (and (symbolp ring) (= (length expr) 3)
                     (ignore-errors (semantic-node-type (analyze-expression ring env context (append location '(1))))))))
    (if (%tcgen05-ring-type-p rtype)
        (destructuring-bind (m n elem count) (gethash rtype *tcgen05-ring-dims*)
          (declare (ignore count))
          (let ((acc-type (%ensure-tcgen05-acc-type m n elem))
                (to-uint (intern "TO-UINT" (find-package :crisp-language))))
            (log:debug "208 ring-get on tcgen05 ring ~a (~a)" ring rtype)
            (analyze-expression
             `(%construct-struct ,acc-type
                                 (+ (%extract-struct-member ,ring 0) (* (,to-uint ,(third expr)) (,to-uint ,n)))
                                 (,to-uint 1))
             env context location)))
        (analyze-ring-get-expression expr env context location))))

(defun %208-source-type (src env context location)
  "Endeavour 208.  The type of a store source SRC when it is a symbol or a (ring-get ..) form, else
   NIL.  Only used to spot a tcgen05 accumulator; anything that fails to analyse here is left to the
   original analyzer."
  (and (or (symbolp src)
           (and (consp src) (symbolp (first src)) (string-equal (symbol-name (first src)) "RING-GET")))
       (ignore-errors (semantic-node-type (analyze-expression src env context (append location '(1)))))))

(defun %208-analyze-tma-store (expr src convert env context location)
  "Endeavour 208.  (store-tile-at (to-bfloat16 D) C (ROW COL) :via :tma) for a tcgen05 accumulator D:
   the semantic-tcgen05-op :tma-store node.  Pass 1 (%199-scan-register-tma-store) already registered
   C's store descriptor (16 x 64 boxes, SWIZZLE_128B) and the function's staging buffer; the rules are
   199's -- a 16-bit conversion, N a multiple of 64, C a kernel tensor of that element, a compile-time
   local size -- plus the warpgroup rule (D-208-6)."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error
                  :message (format nil "store-tile-at :via :tma: ~?" fmt args)
                  :source-location location)))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node))
           (dest     (third expr))
           (origin   (fourth expr))
           (fn       (compiler-context-current-compiling-function context))
           (n        (second (gethash src-type *tcgen05-acc-dims*)))
           (elem     (and convert (%199-convert-element convert)))
           (dims     (%declared-local-size-dims (compiler-context-declarations context)))
           (threads  (and dims (reduce #'* dims)))
           (wgs      (and threads (floor threads 128)))
           (desc     (%199-descriptor-name dest fn))
           (stage    (%199-stage-name fn))
           (implicit (gethash fn *implicit-arg-map*))
           (info     (gethash desc *tma-descriptor-info*))
           (to-int   (intern "TO-INT" (find-package :crisp-language))))
      (log:debug "208 :via :tma: n=~a elem=~a dims=~a desc=~a stage=~a" n elem dims desc stage)
      (unless elem
        (fail "the TMA store moves 16-bit elements, so the f32 accumulator needs a conversion: write (to-half ~a) or (to-bfloat16 ~a)." src src))
      (unless (and dest (symbolp dest))
        (fail "the destination must be the kernel's tensor parameter (its TMA descriptor is built for it), got ~s." dest))
      (unless (and (listp origin) (= (length origin) 2))
        (fail "needs a 2-D (ROW COL) element origin, got ~s." origin))
      (unless (and n (zerop (mod n 64)))
        (fail "N must be a multiple of 64 (a TMA box is 64 16-bit columns = 128 bytes); this accumulator is 128x~a." n))
      (unless (and wgs (plusp wgs))
        (fail "needs the kernel's compile-time block size, (local-size :set-to N) with N at least 128: the staging buffer is 4 KB per warp."))
      (%tcgen05-check-epilogue-threads context location)
      (unless (and (find desc implicit :key #'car) (find stage implicit :key #'car))
        (fail "its TMA descriptor and staging buffer are registered in pass 1, which did not see this store (single-pass compile, or a store outside the kernel body)."))
      (unless (getf info :store-box)
        (fail "~a is also loaded with a :block load-tile in this kernel; a tensor has one TMA descriptor, and a load's box is not the store's." dest))
      (unless (valid-parameterized-type-p (cdr (find stage implicit :key #'car)))
        (fail "could not instantiate the staging buffer type ~a." (cdr (find stage implicit :key #'car))))
      (setf (gethash stage *implicit-scratch-size-expr-map*)
            (/ (+ (* wgs 4 *199-stage-bytes-per-warp*) 1024) 2))
      (log:info "208 store-tile-at :via :tma: 128x~a ~a into ~a; staging ~a = ~a warp slices x 4 KB + 1 KB"
                n elem dest stage (* 4 wgs))
      (make-semantic-tcgen05-op
       :op :tma-store
       :args (list src-node
                   (analyze-expression `(,to-int ,(first origin)) env context (append location '(3 0)))
                   (analyze-expression `(,to-int ,(second origin)) env context (append location '(3 1))))
       :plist (list :n n :element elem :dest-sym dest :stage stage
                    :stage-spec (cdr (find stage implicit :key #'car)) :slices (* 4 wgs))
       :type 'nil
       :source-location location))))

(defun %208-acc-elem (elem form-name location)
  "Endeavour 208 phase 3.  The canonical element type of a tcgen05 accumulator.  Accepted: float (an
   f32 accumulator, for 16-bit and tf32 operands), or a 32-bit integer -- int, uint, a type derived
   from one, or (accum Q) -- for kind::i8's s32 accumulator.  Anything else is refused, naming
   FORM-NAME."
  (let ((ce (%canonical-elem elem)))
    (log:debug "208 %208-acc-elem ~s -> ~s" elem ce)
    (cond ((and (symbolp ce) (string-equal (symbol-name ce) "FLOAT")) ce)
          ((and ce (%elem-integer-p ce) (eql (%mma-elem-bits ce) 32)) ce)
          (t (error 'crisp-compiler-error
                    :message (format nil "~a: the element must be float (an f32 accumulator, for half / bfloat16 / float operands) or a 32-bit integer such as int or (accum Q) (an s32 accumulator, for char / uchar operands); got ~(~a~)."
                                     form-name elem)
                    :source-location location)))))

(defun %ensure-tcgen05-row-type-s32 ()
  "Endeavour 208 phase 3.  The s32 twin of TCGEN05-ROW32-F32: 32 int fields, the 32 consecutive
   columns of the calling thread's own tensor-memory lane, for an integer accumulator."
  (let ((name (intern "TCGEN05-ROW32-S32" (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below 32 collect (list (intern (format nil "R~d" i) (find-package :crisp.compiler)) 'int))
       :record))
    name))

(defun %208-acc-int-p (acc-type)
  "Endeavour 208 phase 3.  T when ACC-TYPE (a minted tcgen05 accumulator record) holds s32."
  (let ((dims (gethash acc-type *tcgen05-acc-dims*)))
    (and dims (%elem-integer-p (third dims)) t)))

(defun analyze-%tcgen05-ld (expr env context location)
  "Endeavour 208.  (%tcgen05-ld D CHUNK) -> the 32 columns [32*CHUNK, 32*CHUNK+32) of the calling
   thread's accumulator row, as a TCGEN05-ROW32-F32 record (tcgen05.ld.32x32b.x32 + wait::ld).
   Phase 3: an s32 accumulator reads into TCGEN05-ROW32-S32 instead -- the same instruction, the
   32-bit cells taken as int."
  (destructuring-bind (d chunk) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (int-p  (%208-acc-int-p (semantic-node-type d-node))))
      (log:debug "208 %tcgen05-ld chunk ~a of ~a (~a)" chunk (semantic-node-type d-node) (if int-p "s32" "f32"))
      (make-semantic-tcgen05-op
       :op :ld
       :args (list d-node)
       :plist (list :chunk chunk :int int-p)
       :type (if int-p (%ensure-tcgen05-row-type-s32) (%ensure-tcgen05-row-type))
       :source-location location))))

(defun analyze-make-tcgen05-accumulator (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator float (M N) 0.0) -> a tensor-memory accumulator.
   Phase 3: (make-tcgen05-accumulator int (M N) 0), or (accum Q) for a def-qint Q, is an s32
   accumulator for kind::i8; it also takes N columns (one 32-bit cell per element).
   It must initialise a let binding: its columns are assigned per binding SITE, N columns for a float
   accumulator, and the kernel's total may not exceed the 512 a CTA has (D-208-4).  The init must
   be zero (D-208-5).  `(set! D (make-tcgen05-accumulator ..))` re-initialises D in place: the let
   pre-pass rewrites it to (%tcgen05-reset D), which keeps D's columns and marks it FRESH."
  (%tcgen05-require-arch "make-tcgen05-accumulator" location)
  (unless (= (length expr) 4)
    (error 'crisp-compiler-error
           :message "make-tcgen05-accumulator: expected (make-tcgen05-accumulator float (M N) 0.0) or (make-tcgen05-accumulator int (M N) 0)."
           :source-location location))
  (destructuring-bind (elem dims init) (cdr expr)
    (setf elem (%208-acc-elem elem "make-tcgen05-accumulator" location))
    (unless (and (listp dims) (= (length dims) 2))
      (error 'crisp-compiler-error
             :message (format nil "make-tcgen05-accumulator: the shape must be (M N), got ~s." dims)
             :source-location location))
    (destructuring-bind (m n) dims
      (%tcgen05-check-acc-shape m n location)
      (unless (and (numberp init) (zerop init))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator: the initial value must be 0, got ~s.  The first MMA after initialisation overwrites the accumulator instead of adding to it, so zero costs nothing; any other start would need a pass that stores it into tensor memory." init)
               :source-location location))
      (unless (and context (compiler-context-current-binding-name context))
        (error 'crisp-compiler-error
               :message "make-tcgen05-accumulator must initialise a let binding, e.g. (let ((D (make-tcgen05-accumulator float (128 256) 0.0))) ...).  Re-initialise it with (set! D (make-tcgen05-accumulator float (128 256) 0.0))."
               :source-location location))
      (let* ((key    (%208-kernel-key context))
             (site   (cons key location))
             (info   (%208-kernel-info key))
             (offset (or (gethash site *tcgen05-columns*)
                         (let* ((off   (getf info :columns 0))
                                (total (+ off n)))
                           (when (> total 512)
                             (error 'crisp-compiler-error
                                    :message (format nil "make-tcgen05-accumulator: this kernel's tcgen05 accumulators need ~a tensor-memory columns, over the 512 a CTA has.  A float (M N) accumulator takes N columns, so two 128 x 256 accumulators fill it." total)
                                    :source-location location))
                           (setf (getf (gethash key *tcgen05-kernels*) :columns) total)
                           (setf (gethash site *tcgen05-columns*) off))))
             (type-name (%ensure-tcgen05-acc-type m n elem))
             (to-uint (intern "TO-UINT" (find-package :crisp-language))))
        (log:debug "208 make-tcgen05-accumulator ~a (~a ~a) in ~a: columns ~a..~a"
                   (compiler-context-current-binding-name context) m n key offset (+ offset n -1))
        (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset) (,to-uint 1))
                            env context location)))))

(defun analyze-make-tcgen05-accumulator-ring (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator-ring float (M N) :ring-count R) -> R accumulators in
   R*N consecutive tensor-memory columns.  (ring-get RING i) is accumulator i, FRESH: the first MMA
   into it overwrites.  Two slots let the epilogue drain tile t while the MMAs of tile t+1 run.
   Phase 3: an integer element (int, (accum Q)) makes s32 slots, as for make-tcgen05-accumulator."
  (%tcgen05-require-arch "make-tcgen05-accumulator-ring" location)
  (destructuring-bind (elem dims &rest keys) (cdr expr)
    (let ((count (getf keys :ring-count)))
      (setf elem (%208-acc-elem elem "make-tcgen05-accumulator-ring" location))
      (unless (and (integerp count) (<= 1 count 4))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: :ring-count must be an integer from 1 to 4, got ~s." count)
               :source-location location))
      (unless (and (listp dims) (= (length dims) 2))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: the shape must be (M N), got ~s." dims)
               :source-location location))
      (destructuring-bind (m n) dims
        (%tcgen05-check-acc-shape m n location)
        (unless (and context (compiler-context-current-binding-name context))
          (error 'crisp-compiler-error
                 :message "make-tcgen05-accumulator-ring must initialise a let binding."
                 :source-location location))
        (%ensure-tcgen05-acc-type m n elem)
        (let ((offset (%208-assign-columns context location (* n count) "make-tcgen05-accumulator-ring"))
              (type-name (%ensure-tcgen05-ring-type m n elem count))
              (to-uint (intern "TO-UINT" (find-package :crisp-language))))
          (log:debug "208 make-tcgen05-accumulator-ring ~a x (~a ~a): columns ~a..~a"
                     count m n offset (+ offset (* n count) -1))
          (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset)) env context location))))))

(defun %208-mma-kind (elem)
  "Endeavour 208.  For an operand element ELEM: (values KIND K-PER-INSTRUCTION FORMAT-CODE), the
   tcgen05.mma .kind, the K one instruction covers (always 32 bytes), and the a/b_format code of the
   instruction descriptor.  NIL for an element with no kind yet.

   Phase 3: an 8-bit integer (char, uchar, or a type derived from one, e.g. a def-qint) is kind::i8,
   K = 32, format INT8 = 1 / UINT8 = 0 (CUTLASS UMMA::S8Format).  A and B carry their own format,
   so the four sign pairs are one instruction."
  (let ((n (and elem (symbolp elem) (symbol-name elem))))
    (cond ((null n) nil)
          ((%int-operand-p elem) (values "i8" 32 (if (%elem-signed-p elem) 1 0)))
          ((string= n "HALF")     (values "f16"  16 0))
          ((string= n "BFLOAT16") (values "f16"  16 1))
          ((string= n "FLOAT")    (values "tf32"  8 2))
          (t nil))))

(defvar *210-store-transform* nil
  "Endeavour 210 (F-210-1).  The #'F of a tcgen05 accumulator store's :transformF while that store is
   analyzed (bound by %210-store-front), else NIL.  %tcgen05-store-rewrite-origin applies it to each
   element read from tensor memory, before any narrowing conversion.")

(defun %210-split-transformF (keys)
  "Endeavour 210.  (values FN-FORM OTHER-KEYS) for a store's keyword tail KEYS: FN-FORM is the value of
   :transformF (NIL when absent) and OTHER-KEYS the remaining key/value pairs, in order.  A KEYS of odd
   length is returned whole with FN-FORM NIL, for the analyzer to report."
  (if (oddp (length keys))
      (values nil keys)
      (let ((fn nil) (other '()))
        (loop for (k v) on keys by #'cddr
              do (if (eq k :transformF)
                     (setf fn v)
                     (progn (push k other) (push v other))))
        (values fn (nreverse other)))))

(defun %210-accumulator-kind (src env context location)
  "Endeavour 210.  What kind of MMA accumulator the (conversion-peeled) store source SRC is:
   :tcgen05, :wgmma, :register-tile (an un-exploded tile), :fragment (a PTX fragment record or a SPIR-V
   cooperative matrix), or NIL for anything else (a scratch tile, a global tensor ...)."
  (let ((ty (%208-source-type src env context location)))
    (cond ((null ty) nil)
          ((%tcgen05-acc-type-p ty) :tcgen05)
          ((%wgmma-acc-type-p ty) :wgmma)
          ((%register-tile-type-p ty) :register-tile)
          ((or (%map-elements-fragment-fields ty) (%map-elements-coop-dims ty)) :fragment)
          (t nil))))

(defun %210-replace-store-source (src-form new)
  "Endeavour 210.  SRC-FORM (a store's source: X, or a peelable conversion (to-half X) / (to-q8 X M))
   with its accumulator X replaced by NEW, so the rewritten store peels exactly as the original."
  (if (consp src-form)
      (list* (first src-form) new (cddr src-form))
      new))

(defun %210-store-front (expr env context location base at-p)
  "Endeavour 210 (F-210-1).  Front end of the store-tile (AT-P NIL) / store-tile-at (AT-P T) analyzers
   for an MMA ACCUMULATOR source; BASE is the analyzer it fronts (208's).  Non-accumulator sources go
   to BASE untouched -- the generic tile store implements its own options, :transformF included.
   For an accumulator:
     * an option it does not support is refused (it used to be ignored): store-tile takes only
       :transformF, store-tile-at also :via;
     * :transformF #'F on tcgen05 binds *210-store-transform* around BASE (refused with :via :tma);
     * :transformF #'F on wgmma / a fragment / an un-exploded register tile becomes
         (let ((tmp SRC)) (map-elements! tmp #'F) (store.. CONV(tmp) DEST COORDS OTHER-KEYS..))
       -- map-elements!'s own lowering, on a copy, so the accumulator itself is not changed."
  (multiple-value-bind (fn other) (%210-split-transformF (nthcdr 4 expr))
    (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
      (declare (ignore convert))
      (let ((kind (%210-accumulator-kind src env context location)))
        (log:debug "210 store front: ~a src=~a kind=~a transformF=~a other=~s"
                   (if at-p "store-tile-at" "store-tile") src kind fn other)
        (if (null kind)
            (funcall base expr env context location)
            (let* ((allowed (if at-p '(:via) '()))
                   (bad     (loop for (k nil) on other by #'cddr
                                  unless (member k allowed) collect k))
                   (stripped (append (subseq expr 0 4) other)))
              (when (or bad (oddp (length other)))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): option~a ~{~(~s~)~^, ~} ~a not supported on an accumulator store (~(~a~) is ~a).  ~a"
                                        (first expr) (if (cdr bad) "s" "") bad (if (cdr bad) "are" "is") src
                                        (ecase kind
                                          (:tcgen05 "a tcgen05 tensor-memory accumulator")
                                          (:wgmma "a wgmma accumulator")
                                          ((:register-tile :fragment) "an MMA register accumulator"))
                                        (if at-p
                                            "An accumulator store takes :transformF #'f and, for store-tile-at, :via :tma."
                                            "An accumulator store takes :transformF #'f."))
                       :source-location location))
              (cond
                ((null fn)
                 (funcall base stripped env context location))
                ((eq kind :tcgen05)
                 (%map-elements-check-unary fn location)
                 (when (and at-p (%199-via-tma-p other))
                   (error 'crisp-compiler-error
                          :message (format nil "store-tile-at ~(~a~) :via :tma: :transformF is not supported yet on the TMA store of a tcgen05 accumulator (it converts and stages the accumulator in one step, with no per-element hook).  Store with store-tile / store-tile-at without :via, which apply :transformF as each element leaves tensor memory."
                                           src)
                          :source-location location))
                 (let ((*210-store-transform* fn))
                   (funcall base stripped env context location)))
                (t
                 (%map-elements-check-unary fn location)
                 (let ((tmp (intern (format nil "XFORM-~a" (symbol-name (gensym "ACC")))
                                    (find-package :crisp.compiler))))
                   (log:debug "210 store front: ~a :transformF ~a -> copy ~a + map-elements!" src fn tmp)
                   (analyze-expression
                    `(let ((,tmp ,src))
                       (map-elements! ,tmp ,fn)
                       (,(first expr) ,(%210-replace-store-source (second expr) tmp)
                        ,(third expr) ,(fourth expr) ,@other))
                    env context location))))))))))

(defun %tcgen05-store-rewrite-origin (tile dest row-origin col-origin n &optional convert elem)
  "Endeavour 208.  Store the 128 x N tcgen05 accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN).  Thread t of the warpgroup owns row 32(warp mod 4) + lane (Layout D: row
   m is tensor-memory lane m).  Per chunk of 32 columns: one tcgen05.ld into registers, then the
   row's 32 elements -- as 16 packed pairs (endeavour 197) when the first pair is adjacent and
   aligned, else as scalars.  A fence::after_thread_sync opens the store (the accumulator was
   completed by another thread's MMA) and a fence::before_thread_sync closes it (the next MMA into
   these columns must not overtake the reads).  CONVERT as in %wgmma-store-rewrite-origin.
   Phase 3: ELEM is the accumulator's element type.  With no CONVERT, an element of a DERIVED
   integer accumulator such as (accum q-a) is raw-cast to it (207's %store-frag-elem-cast): the s32
   row record holds plain int, and the destination element holds exactly its own type.
   Endeavour 210 (F-210-1): when *210-store-transform* is bound (a store's :transformF), each element
   read from tensor memory is passed through that function first."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (if-sym (intern "IF" (find-package :crisp-language)))
         (chunks (floor n 32)))
    (flet ((elt-of (ch j)
             (let ((x (let ((raw `(%extract-struct-member ,ch ,j)))
                        ;; Endeavour 210 (F-210-1): the store's :transformF, applied to the raw
                        ;; element BEFORE any conversion or derived-integer cast.
                        (if *210-store-transform* (%map-elements-call *210-store-transform* raw) raw))))
               (if convert (%196-wrap-conversion convert x) (%store-frag-elem-cast elem x)))))
      `(let ((tcv ,tile))
         (let ((r0 (+ (,to-int ,row-origin) (+ (* (rem (,to-int (warp-id)) 4) 32) (,to-int (warp-lane)))))
               (c0 (,to-int ,col-origin)))
           (%tcgen05-fence-after)
           ,@(loop for c below chunks
                   for ch = (intern (format nil "TCROW~d" c) (find-package :crisp.compiler))
                   for base = (* 32 c)
                   collect `(let ((,ch (%tcgen05-ld tcv ,c)))
                              (,if-sym (%pair-ok-p (~ ,dest r0 (+ c0 ,base)) (~ ,dest r0 (+ c0 ,(1+ base))))
                                (progn ,@(loop for j below 32 by 2
                                               collect `(%store-pair (~ ,dest r0 (+ c0 ,(+ base j)))
                                                                     (~ ,dest r0 (+ c0 ,(+ base j 1)))
                                                                     ,(elt-of ch j) ,(elt-of ch (1+ j)))))
                                (progn ,@(loop for j below 32
                                               collect `(set! (~ ,dest r0 (+ c0 ,(+ base j))) ,(elt-of ch j)))))))
           (%tcgen05-fence-before))))))

(defun %208-analyze-store-tile-base (expr env context location)
  "Endeavour 208.  store-tile: a tcgen05 accumulator source is stored by %tcgen05-store-rewrite-origin
   at the tile-grid origin (BTY*M, BTX*N); anything else goes to analyze-store-tile-mma unchanged.
   Possible cleanup: a clause in analyze-store-tile-mma.
   Phase 3: passes the accumulator's element, for the derived-integer cast.

   Endeavour 210: %208-analyze-store-tile (below) fronts this with %210-store-front."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (destructuring-bind (m n elem) (gethash src-type *tcgen05-acc-dims*)
            (%tcgen05-check-epilogue-threads context location)
            (let ((tile-id (fourth expr))
                  (to-int (intern "TO-INT" (find-package :crisp-language))))
              (analyze-expression
               (%tcgen05-store-rewrite-origin src (third expr)
                                              `(* (,to-int ,(first tile-id)) ,m)
                                              `(* (,to-int ,(second tile-id)) ,n)
                                              n convert elem)
               env context location)))
          (analyze-store-tile-mma expr env context location)))))

(defun %208-analyze-store-tile (expr env context location)
  "Endeavour 208.  store-tile: a tcgen05 accumulator source is stored by %tcgen05-store-rewrite-origin
   at the tile-grid origin (BTY*M, BTX*N); anything else goes to analyze-store-tile-mma unchanged.
   Endeavour 210: fronted by %210-store-front (options on an accumulator store, :transformF)."
  (%210-store-front expr env context location #'%208-analyze-store-tile-base nil))

(defun %208-analyze-store-tile-at-base (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin, directly or with :via :tma (%208-analyze-tma-store).  Anything else goes to
   analyze-store-tile-at-mma.  Possible cleanup: a clause in analyze-store-tile-at-mma.
   Phase 3: passes the accumulator's element, for the derived-integer cast.

   Endeavour 210: %208-analyze-store-tile-at (below) fronts this with %210-store-front."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (let* ((origin (fourth expr))
                 (keys   (nthcdr 4 expr))
                 (n      (second (gethash src-type *tcgen05-acc-dims*))))
            (cond ((null keys))
                  ((%199-via-tma-p keys)
                   (return-from %208-analyze-store-tile-at-base
                     (%208-analyze-tma-store expr src convert env context location)))
                  (t (error 'crisp-compiler-error
                            :message (format nil "store-tile-at: options ~s are not supported for a tcgen05 accumulator (only :via :tma)." keys)
                            :source-location location)))
            (unless (and (listp origin) (= (length origin) 2))
              (error 'crisp-compiler-error
                     :message (format nil "store-tile-at: a tcgen05 accumulator needs a 2-D (ROW COL) element origin, got ~s." origin)
                     :source-location location))
            (%tcgen05-check-epilogue-threads context location)
            (analyze-expression (%tcgen05-store-rewrite-origin src (third expr) (first origin) (second origin) n convert
                                                               (third (gethash src-type *tcgen05-acc-dims*)))
                                env context location))
          (analyze-store-tile-at-mma expr env context location)))))

(defun %208-analyze-store-tile-at (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin, directly or with :via :tma; anything else goes to analyze-store-tile-at-mma.
   Endeavour 210: fronted by %210-store-front (options on an accumulator store, :transformF)."
  (%210-store-front expr env context location #'%208-analyze-store-tile-at-base t))

(defun %208-block-info (elem)
  "Endeavour 208 phase 4.  When ELEM names a def-microfloat-block, its tcgen05 plist:
     :name :base :scale :vec   the block (names as strings; :vec the block size in elements)
     :kind        the tcgen05.mma kind, with its scale_vec, or NIL when no kind fits the block
     :epb         codes per byte (2 for fp4, 1 for fp8)
     :fmt :sfmt   the a/b_format and scale_format codes of the block-scaled instruction descriptor
     :spi         scales per row one instruction consumes (4X 4, 2X 2, 1X 1)
   NIL when ELEM is not a block."
  (let* ((e (and elem (%canonical-elem elem)))
         (b (and e (symbolp e) (microfloat-block-p e))))
    (when b
      (let ((base (symbol-name (getf b :base)))
            (scale (symbol-name (getf b :scale)))
            (vec (getf b :shape)))
        (flet ((info (&rest kv) (list* :name (symbol-name e) :base base :scale scale :vec vec kv)))
          (cond ((and (string= base "FP4") (string= scale "FP8-E4M3") (eql vec 16))
                 (info :kind "mxf4nvf4.block_scale.scale_vec::4X" :epb 2 :fmt 1 :sfmt 0 :spi 4))
                ((and (string= base "FP4") (string= scale "FP8-E8M0") (eql vec 32))
                 (info :kind "mxf4.block_scale.scale_vec::2X" :epb 2 :fmt 1 :sfmt 1 :spi 2))
                ((and (member base '("FP8-E4M3" "FP8-E5M2") :test #'string=)
                      (string= scale "FP8-E8M0") (eql vec 32))
                 (info :kind "mxf8f6f4.block_scale" :epb 1 :fmt (if (string= base "FP8-E4M3") 0 1)
                       :sfmt 1 :spi 1))
                (t (info :kind nil))))))))

(defun %208-block-step (info)
  "Endeavour 208 phase 4.  (values K-ELEMS SCALES-PER-ROW ATOMS-PER-STEP) of one tcgen05 call on block
   INFO: K is one 128-byte swizzle atom of codes (256 fp4, 128 fp8); a row then has K/vec scales, which
   is K/vec/4 512-byte scale atoms per 128 rows."
  (let* ((k   (* 128 (getf info :epb)))
         (spr (floor k (getf info :vec))))
    (values k spr (floor spr 4))))

(defvar *208-scale-layouts* (make-hash-table :test 'equal)
  "Endeavour 208 phase 4.  Kernel name (string) -> list of (:scales S :of A :layout L), the kernel's
   (scale-layout S :of A L) declarations, names as downcased strings.  Set when the kernel's source is
   visited (before pass 1).")

(defun %208-sym= (x name)
  "Endeavour 208.  T when X is a symbol named NAME (any package)."
  (and x (symbolp x) (string-equal (symbol-name x) name)))

(defun %208-rw-list (list tiles)
  "Endeavour 208 phase 4.  %208-rw over the elements of LIST; the SAME conses back when nothing changed
   (source positions are keyed by cons identity)."
  (if (atom list)
      list
      (let ((a (%208-rw (car list) tiles))
            (d (%208-rw-list (cdr list) tiles)))
        (if (and (eq a (car list)) (eq d (cdr list))) list (cons a d)))))

(defun %208-tree-has-block-scratch-p (form)
  "Endeavour 208 phase 4.  T when FORM contains a make-scratch-matrix(-ring) of a microfloat block.
   The cheap test that keeps every other kernel's source untouched (EQ)."
  (cond ((atom form) nil)
        ((and (or (%208-sym= (first form) "MAKE-SCRATCH-MATRIX") (%208-sym= (first form) "MAKE-SCRATCH-MATRIX-RING"))
              (consp (cdr form)) (%208-block-info (second form)))
         t)
        (t (loop for x on form
                 thereis (if (consp x) (%208-tree-has-block-scratch-p (car x)) nil)))))

(defun analyze-%208-load-scales (expr env context location)
  "Endeavour 208 phase 4.  (%208-load-scales S SRC SF (ROW-TILE K-TILE) BAR BLOCK ROWS): copy the scale
   atoms of SRC's tile (ROW-TILE K-TILE) from the :blocked-128x4 vector S into the scales tile SF, on
   BAR.  Emitted by the source rewrite in front of the codes load.  The atoms of one row block for one
   K-step are contiguous: (rb * K/(vec*4) + kt * aps) * 512, aps*512 bytes; ROWS/128 row blocks."
  (destructuring-bind (s src sf coords bar bname rows) (cdr expr)
    (let* ((info   (%208-block-info (make-symbol bname)))
           (kernel (compiler-context-current-compiling-function context))
           (decl   (find-if (lambda (d) (string-equal (getf d :scales) (symbol-name s)))
                            (gethash (string-downcase (symbol-name kernel)) *208-scale-layouts*)))
           (ct     (%kernel-param-contiguous-term kernel src))
           (ki     (if (eq ct :col-major) 0 1))
           (tu     (intern "TO-ULONG" (find-package :crisp-language)))
           (ex     (intern "EXTENTS~" (find-package :crisp-language))))
      (unless (and decl (string-equal (getf decl :of) (symbol-name src)))
        (error 'crisp-compiler-error
               :message (format nil "load-tile ~(~a~) .. :scales ~(~a~): declare the layout of the scales, (scale-layout ~(~a~) :of ~(~a~) :blocked-128x4)."
                                src s s src)
               :source-location location))
      (multiple-value-bind (kel spr aps) (%208-block-step info)
        (declare (ignore kel spr))
        (log:debug "208 %208-load-scales ~a of ~a (~a, ~a) rows ~a aps ~a K index ~a" s src bname ct rows aps ki)
        (make-semantic-tcgen05-op
         :op :load-scales
         :args (list (analyze-expression `(~ ,s 0) env context (append location '(1)))
                     (analyze-expression `(~ ,sf 0 0) env context (append location '(3)))
                     (analyze-expression `(,tu (~ (,ex ,src) ,ki)) env context (append location '(2)))
                     (analyze-expression `(,tu ,(first coords)) env context (append location '(4 0)))
                     (analyze-expression `(,tu ,(second coords)) env context (append location '(4 1)))
                     (analyze-expression bar env context (append location '(5))))
         :plist (list :vec (getf info :vec) :aps aps :row-blocks (floor rows 128)
                      :ws-leader (and *in-warp-spec-block* t))
         :type 'void
         :source-location location)))))

(defun analyze-tcgen05-accumulate-via-tile-base (expr env context location)
  "Endeavour 208.  (tcgen05-accumulate-via-tile (M N K) D A B :swizzle :128b [:on-complete BAR])
   -> (set! D (%tcgen05-mma D A B K [BAR])).  D += A.B over K, issued by one thread into tensor memory.

   Without :on-complete it is SYNCHRONOUS (D-208-2): the issuing thread commits to a compiler-owned
   mbarrier and every thread executing the form waits on it.  With :on-complete BAR it commits to BAR
   and returns at once.

   Operands: half / bfloat16 (kind::f16, K = 64) or float (kind::tf32, K = 32) -- either way one
   128-byte swizzle atom of K, four instructions.
   Phase 3: char / uchar (or types derived from them, e.g. def-qint) are kind::i8, K = 128, into an
   s32 accumulator.  The signs of A and B are independent.  The element-family rule is 204's
   (%check-mma-element-family); the qint-role rule is 207's, applied by %qint-mma-walk over the LET.  M = 128; A (M K) and B (N K) K-major in shared
   memory as a :128b TMA load lays them down.

   Endeavour 208 phase 4: analyze-tcgen05-accumulate-via-tile (below) wraps this; block
   tiles go to the block-scaled path first."
  (%tcgen05-require-arch "tcgen05-accumulate-via-tile" location)
  (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
    (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
      (error 'crisp-compiler-error
             :message (format nil "tcgen05-accumulate-via-tile: the first argument is the (M N K) shape, as integers; got ~s." shape)
             :source-location location))
    (loop for (key nil) on kwargs by #'cddr
          unless (member (symbol-name key) '("SWIZZLE" "ON-COMPLETE" "B-MAJOR") :test #'string=)
            do (error 'crisp-compiler-error
                      :message (format nil "tcgen05-accumulate-via-tile: unknown option ~s.  The options are :swizzle, :b-major and :on-complete." key)
                      :source-location location))
    (destructuring-bind (m n k) shape
      (let* ((d-node (analyze-expression d env context (append location '(2))))
             (d-type (semantic-node-type d-node))
             (elem   (%coop-elem-of (analyze-expression a env context (append location '(3)))))
             (b-elem (%coop-elem-of (analyze-expression b env context (append location '(4)))))
             (swz    (getf kwargs :swizzle))
             (bm     (getf kwargs :b-major :k))
             (bar    (getf kwargs :on-complete)))
        (log:debug "208 tcgen05-accumulate-via-tile: shape=~a elem=~a/~a swizzle=~a on-complete=~a role=~a"
                   shape elem b-elem swz bar *tcgen05-role-warps*)
        (unless (%tcgen05-acc-type-p d-type)
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: D (2nd argument) must be a make-tcgen05-accumulator, got type ~a." d-type)
                 :source-location location))
        (%tcgen05-check-acc-shape m n location)
        (destructuring-bind (dm dn delem) (gethash d-type *tcgen05-acc-dims*)
          (declare (ignore delem))
          (unless (and (= m dm) (= n dn))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: shape ~a does not match the accumulator, which is (~a ~a)." shape dm dn)
                   :source-location location)))
        (let ((acc-elem (third (gethash d-type *tcgen05-acc-dims*))))
          (if (or (%elem-integer-p elem) (%elem-integer-p b-elem) (%elem-integer-p acc-elem))
              (%check-mma-element-family elem b-elem acc-elem location)
              (unless (and (%208-mma-kind elem) (%208-mma-kind b-elem)
                           (string= (symbol-name elem) (symbol-name b-elem)))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile: A and B must both be half, both bfloat16 (kind::f16), both float (kind::tf32), or 8-bit integers (kind::i8), got ~a and ~a." elem b-elem)
                       :source-location location))))
        (unless (and swz (symbolp swz) (string-equal (symbol-name swz) "128B"))
          (error 'crisp-compiler-error
                 :message "tcgen05-accumulate-via-tile needs :swizzle :128b: A and B are read through shared-memory descriptors built for the 128-byte swizzle that a (load-tile .. :swizzle :128b) TMA load lays down."
                 :source-location location))
        (unless (and (symbolp bm) (string-equal (symbol-name bm) "K"))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major ~s is not supported yet; B must be (N K), K-major." bm)
                 :source-location location))
        (let ((want (* 4 (nth-value 1 (%208-mma-kind elem)))))
          (unless (= k want)
            (error 'crisp-compiler-error
                   :message (case want
                              (64  (format nil "tcgen05-accumulate-via-tile: K must be 64 for half / bfloat16 (one 128-byte swizzle atom: four K = 16 instructions), got ~a." k))
                              (128 (format nil "tcgen05-accumulate-via-tile: K must be 128 for char / uchar (one 128-byte swizzle atom: four K = 32 instructions), got ~a." k))
                              (t   (format nil "tcgen05-accumulate-via-tile: K must be 32 for float / tf32 (one 128-byte swizzle atom: four K = 8 instructions), got ~a." k)))
                   :source-location location)))
        ;; Operand extents, when known: A (M K), B (N K).
        (let ((a-r (%mma-operand-extent a nil :rows)) (a-c (%mma-operand-extent a nil :cols))
              (b-r (%mma-operand-extent b nil :rows)) (b-c (%mma-operand-extent b nil :cols)))
          (when (or (and a-r (/= a-r m)) (and a-c (/= a-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: A tile must be (M K) = (~a ~a), but it is (~a ~a)." m k (or a-r '?) (or a-c '?))
                   :source-location location))
          (when (or (and b-r (/= b-r n)) (and b-c (/= b-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: B tile must be (N K) = (~a ~a), K-major as for wgmma, but it is (~a ~a)." n k (or b-r '?) (or b-c '?))
                   :source-location location)))
        (analyze-expression `(set! ,d (%tcgen05-mma ,d ,a ,b ,k ,@(when bar (list bar))))
                            env context location)))))

(defun analyze-tcgen05-accumulate-via-tile (expr env context location)
  "Endeavour 208.  (tcgen05-accumulate-via-tile (M N K) D A B :swizzle :128b [:on-complete BAR]).
   Phase 4: A and B are block tiles (the source rewrite added :%block-a / :%sf-a / :%block-b / :%sf-b)
   -> (set! D (%tcgen05-mma-bs D A B SF-A SF-B K BLOCK [BAR])).  Rules: the same block on both sides
   (D-208-10); an f32 accumulator; M = 128, N 128 or 256 (B's scales come in 128-row atoms); K one
   128-byte atom of codes (D-208-14).  Anything else goes to the earlier analyzer."
  (let ((kw (nthcdr 5 expr)))
    (if (not (getf kw :%block-a))
        (analyze-tcgen05-accumulate-via-tile-base expr env context location)
        (progn
          (%tcgen05-require-arch "tcgen05-accumulate-via-tile" location)
          (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
            (let* ((ba (getf kwargs :%block-a)) (bb (getf kwargs :%block-b))
                   (info (%208-block-info (make-symbol ba)))
                   (bar (getf kwargs :on-complete))
                   (swz (getf kwargs :swizzle))
                   (d-type (semantic-node-type (analyze-expression d env context (append location '(2))))))
              (flet ((fail (fmt &rest args)
                       (error 'crisp-compiler-error
                              :message (format nil "tcgen05-accumulate-via-tile: ~?" fmt args)
                              :source-location location)))
                (loop for (key nil) on kwargs by #'cddr
                      unless (member (symbol-name key) '("SWIZZLE" "ON-COMPLETE" "B-MAJOR" "%BLOCK-A" "%SF-A" "%BLOCK-B" "%SF-B")
                                     :test #'string=)
                        do (fail "unknown option ~s.  The options are :swizzle, :b-major and :on-complete." key))
                (unless (string-equal ba bb)
                  (fail "A holds ~(~a~) blocks and B holds ~(~a~) blocks.  Mixed formats are not supported yet; both must be the same block." ba bb))
                (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
                  (fail "the first argument is the (M N K) shape, as integers; got ~s." shape))
                (unless (%tcgen05-acc-type-p d-type)
                  (fail "D (2nd argument) must be a make-tcgen05-accumulator, got type ~a." d-type))
                (when (%208-acc-int-p d-type)
                  (fail "a block-scaled multiply accumulates in f32: D must be (make-tcgen05-accumulator float ..)."))
                (unless (and swz (symbolp swz) (string-equal (symbol-name swz) "128B"))
                  (fail "a block-scaled multiply needs :swizzle :128b, as the codes are loaded."))
                (destructuring-bind (m n k) shape
                  (destructuring-bind (dm dn delem) (gethash d-type *tcgen05-acc-dims*)
                    (declare (ignore delem))
                    (unless (and (= m dm) (= n dn))
                      (fail "shape ~a does not match the accumulator, which is (~a ~a)." shape dm dn)))
                  (unless (and (= m 128) (member n '(128 256)))
                    (fail "a block-scaled multiply is M = 128 and N = 128 or 256 (B's scales come in 128-row atoms); got (~a ~a)." m n))
                  (let ((want (%208-block-step info)))
                    (unless (= k want)
                      (fail "K must be ~a for ~(~a~) (one 128-byte swizzle atom of codes, four instructions), got ~a."
                            want ba k)))
                  (log:debug "208 block-scaled accumulate ~a (~a ~a ~a) on-complete ~a" ba m n k bar)
                  (analyze-expression
                   `(set! ,d (,(intern "%TCGEN05-MMA-BS" (find-package :crisp.compiler))
                              ,d ,a ,b ,(getf kwargs :%sf-a) ,(getf kwargs :%sf-b) ,k ,ba ,@(when bar (list bar))))
                   env context location)))))))))

(defun analyze-%tcgen05-mma-bs (expr env context location)
  "Endeavour 208 phase 4.  (%tcgen05-mma-bs D A B SF-A SF-B K BLOCK [BAR]) -> the :mma node with :block.
   The site gets its own tensor-memory scale columns: A's atoms-per-step x 4, then B's x 4 per 128-row
   block (they count toward the 512, D-208-13).  Without BAR it is synchronous, as %tcgen05-mma."
  (destructuring-bind (d a b sfa sfb k bname &optional bar) (cdr expr)
    (flet ((ref (x i) (analyze-expression `(~ ,x 0 0) env context (append location (list i)))))
      (let* ((info   (%208-block-info (make-symbol bname)))
             (d-node (analyze-expression d env context (append location '(1))))
             (d-type (semantic-node-type d-node))
             (dims   (gethash d-type *tcgen05-acc-dims*))
             (nb     (floor (second dims) 128))
             (aps    (nth-value 2 (%208-block-step info)))
             (sf-col (%208-assign-columns context location (* 4 aps (1+ nb)) "tcgen05-accumulate-via-tile (its block scales)"))
             (bar-node (and bar (analyze-expression bar env context (append location '(8)))))
             (key    (%208-kernel-key context))
             (site   (unless bar
                       (let ((s (cons key location)))
                         (or (gethash s *tcgen05-sync-sites*)
                             (let ((i (getf (%208-kernel-info key) :sync-sites 0)))
                               (setf (getf (gethash key *tcgen05-kernels*) :sync-sites) (1+ i))
                               (setf (gethash s *tcgen05-sync-sites*) i)))))))
        (log:debug "208 %tcgen05-mma-bs ~a ~a K=~a scale columns ~a..~a issue-warp ~a sync-site ~a"
                   bname dims k sf-col (+ sf-col (* 4 aps (1+ nb)) -1) (%208-issue-warp) site)
        (make-semantic-tcgen05-op
         :op :mma
         :args (append (list d-node (ref a 2) (ref b 3) (ref sfa 4) (ref sfb 5)) (when bar-node (list bar-node)))
         :plist (list :m (first dims) :n (second dims) :k k :block info :aps aps :row-blocks-b nb
                      :sf-col sf-col :issue-warp (%208-issue-warp) :sync-site site :kernel key)
         :type d-type
         :source-location location)))))

(defun %208-param-names (params)
  "Endeavour 208 phase 4.  The names the def-function parameter form PARAMS answers to, downcased:
   every symbol in it, each '_'-prefix of one (A_BYTE_SIZE -> a, a_byte, a_byte_size), and the
   same with '-' for '_'."
  (let ((out '()))
    (labels ((add (s)
               (push s out)
               (push (substitute #\- #\_ s) out))
             (walk (x)
               (cond ((and x (symbolp x))
                      (let ((s (string-downcase (symbol-name x))))
                        (loop for p = (position #\_ s) then (position #\_ s :start (1+ p))
                              while p do (add (subseq s 0 p)))
                        (add s)))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk params))
    out))

(defun %208-block-binding (b)
  "Endeavour 208 phase 4.  When the let binding B is (X (make-scratch-matrix BLOCK (R K))) or the -ring
   form, with BLOCK a def-microfloat-block: (values CODES-BINDING SCALES-BINDING ENTRY).
     CODES-BINDING   (X (make-scratch-matrix uchar (R K/epb) ..)) -- the packed codes, K-major
     SCALES-BINDING  (X--SCALES (make-scratch-matrix uchar (Q 512) ..)) -- R/128 x atoms-per-step
                     512-byte scale atoms, row block j's atoms at j*atoms-per-step, and Q that count
                     rounded up to EVEN: the hoist packs scratch tiles back to back, and a 512-byte
                     tile would leave the next 128-byte-swizzled codes tile off its 1024-byte alignment
     ENTRY           (X :info INFO :rows R :cols K :sf X--SCALES)
   NIL for any other binding.  R must be a multiple of 128 (a scale atom covers 128 rows) and K one
   128-byte atom of codes (D-208-14)."
  (let* ((init (and (consp b) (second b)))
         (head (and (consp init) (first init))))
    (when (and (or (%208-sym= head "MAKE-SCRATCH-MATRIX") (%208-sym= head "MAKE-SCRATCH-MATRIX-RING"))
               (consp (cdr init)))
      (let ((info (%208-block-info (second init))))
        (when info
          (let ((x (first b)) (dims (third init)))
            (unless (getf info :kind)
              (error 'crisp-compiler-error
                     :message (format nil "~(~a~): tcgen05 multiplies NVFP4 (:base fp4 :scale fp8-e4m3 :shape (16)), MXFP4 (:base fp4 :scale fp8-e8m0 :shape (32)) and MXFP8 (:base fp8-e4m3 or fp8-e5m2 :scale fp8-e8m0 :shape (32)) blocks; ~(~a~) is :base ~(~a~) :scale ~(~a~) :shape (~a)."
                                      x (getf info :name) (getf info :base) (getf info :scale) (getf info :vec))))
            (multiple-value-bind (kel spr aps) (%208-block-step info)
              (declare (ignore spr))
              (unless (and (listp dims) (= (length dims) 2) (every #'integerp dims)
                           (zerop (mod (first dims) 128)) (= (second dims) kel))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): a scratch tile of ~(~a~) for tcgen05 is (R ~a): R a multiple of 128 (a scale atom covers 128 rows) and K one 128-byte swizzle atom of codes; got ~s."
                                        x (getf info :name) kel dims)))
              (let* ((r (first dims))
                     (sf (intern (format nil "~a--SCALES" (symbol-name x)) (symbol-package x)))
                     (uchar (intern "UCHAR" (find-package :crisp-language)))
                     (rest (cdddr init)))
                (log:debug "208 block tile ~a: ~a (~a ~a) -> codes uchar (~a ~a), scales ~a (~a 512)"
                           x (getf info :name) r kel r (floor kel (getf info :epb)) sf (* (floor r 128) aps))
                (values (list x (list* head uchar (list r (floor kel (getf info :epb))) rest))
                        (list sf (list* head uchar (list (* 2 (ceiling (* (floor r 128) aps) 2)) 512) rest))
                        (list x :info info :rows r :cols kel :sf sf))))))))))

(defvar *208-rw-kernel* nil
  "Endeavour 208 phase 4.  The kernel name (downcased string) whose source %208-rw is rewriting, for
   its scale-layout declarations.")

(defun %208-acc-binding-elem (b)
  "Endeavour 208 phase 4.  When the let binding B makes a tcgen05 accumulator (or ring): (values SYM
   ELEM), the accumulator's element as written.  NIL otherwise."
  (let ((init (and (consp b) (second b))))
    (when (and (consp init) (consp (cdr init))
               (or (%208-sym= (first init) "MAKE-TCGEN05-ACCUMULATOR")
                   (%208-sym= (first init) "MAKE-TCGEN05-ACCUMULATOR-RING")))
      (values (first b) (second init)))))

(defun %208-check-block-accumulate (form ea eb tiles)
  "Endeavour 208 phase 4.  Rewrite-time rules of a block-scaled (tcgen05-accumulate-via-tile SHAPE D A B
   ..) whose A and B are block tiles EA / EB: the same block, M = 128, N 128 or 256, K one atom of
   codes, and an f32 accumulator when D's binding is in TILES (as (D :acc ELEM))."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error
                  :message (format nil "tcgen05-accumulate-via-tile: ~?" fmt args))))
    (let* ((ia (getf (cdr ea) :info)) (ib (getf (cdr eb) :info))
           (shape (second form))
           (d (third form))
           (dsym (if (consp d) (second d) d))
           (acc (and (symbolp dsym) (assoc dsym tiles))))
      (unless (string-equal (getf ia :name) (getf ib :name))
        (fail "A holds ~(~a~) blocks and B holds ~(~a~) blocks.  Mixed formats are not supported yet; both must be the same block."
              (getf ia :name) (getf ib :name)))
      (when (and acc (getf (cdr acc) :acc) (not (%208-sym= (getf (cdr acc) :acc) "FLOAT")))
        (fail "a block-scaled multiply accumulates in f32: D must be (make-tcgen05-accumulator float ..), not ~(~a~)."
              (getf (cdr acc) :acc)))
      (when (and (listp shape) (= (length shape) 3) (every #'integerp shape))
        (destructuring-bind (m n k) shape
          (unless (and (= m 128) (member n '(128 256)))
            (fail "a block-scaled multiply is M = 128 and N = 128 or 256 (B's scales come in 128-row atoms); got (~a ~a)." m n))
          (let ((want (%208-block-step ia)))
            (unless (= k want)
              (fail "K must be ~a for ~(~a~) (one 128-byte swizzle atom of codes, four instructions), got ~a."
                    want (getf ia :name) k))))))))

(defun %208-parse-scale-layouts (name params body)
  "Endeavour 208 phase 4.  Records kernel NAME's (scale-layout S :of A :blocked-128x4) declarations from
   the declare forms at the head of BODY in *208-scale-layouts*, refusing a malformed one, an unknown
   layout, or a name that is not one of PARAMS.  Q1 (b): the kernel declares the layout; the host
   provides it, and the generated hoist matches it."
  (let ((pnames (%208-param-names params))
        (out '()))
    (log:debug "208 scale-layout parse of ~a: params ~s" name params)
    (dolist (f body)
      (when (and (consp f) (%208-sym= (first f) "DECLARE"))
        (dolist (d (rest f))
          (when (and (consp d) (%208-sym= (first d) "SCALE-LAYOUT"))
            (destructuring-bind (&optional s of a layout &rest more) (rest d)
              (unless (and (symbolp s) (%208-sym= of "OF") (symbolp a) (symbolp layout) (null more))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): expected (scale-layout SCALES :of MATRIX :blocked-128x4), got ~s." name d)))
              (unless (%208-sym= layout "BLOCKED-128X4")
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): (scale-layout ~(~a~) ..): the layout ~s is not supported.  The one layout is :blocked-128x4, cuBLASLt's and torchao's to_blocked: 512-byte atoms of 128 rows x 4 scales." name s layout)))
              (dolist (nm (list s a))
                (unless (member (string-downcase (symbol-name nm)) pnames :test #'string=)
                  (error 'crisp-compiler-error
                         :message (format nil "~(~a~): (scale-layout ~(~a~) :of ~(~a~) ..): ~(~a~) is not a parameter of the kernel." name s a nm))))
              (push (list :scales (string-downcase (symbol-name s)) :of (string-downcase (symbol-name a))
                          :layout :blocked-128x4)
                    out))))))
    (let ((decls (setf (gethash (string-downcase (symbol-name name)) *208-scale-layouts*) (nreverse out))))
      ;; (the earlier copy logged OUT after NREVERSE, which shows only the last declaration)
      (when decls (log:debug "208 scale layouts of ~a: ~s" name decls)))))

(defun %208-rw (form tiles)
  "Endeavour 208 phase 4.  The block-tile source rewrite of FORM, TILES the block tiles in scope (see
   the section header).  EQ-preserving.  TILES also carries the tcgen05 accumulator bindings, as
   (D :acc ELEM), and the block rules whose inputs are literal are checked here, before pass 1."
  (cond
    ((atom form) form)
    ;; LET: block bindings split into codes + scales; the body sees them.
    ((and (%208-sym= (first form) "LET") (consp (cdr form)) (listp (second form)))
     (let ((out '()) (changed nil) (inner tiles))
       (dolist (b (second form))
         (multiple-value-bind (codes scales entry) (%208-block-binding b)
           (if codes
               (progn (setf changed t) (push codes out) (push scales out) (push entry inner))
               (let ((nb (if (consp b) (%208-rw-list b tiles) b)))
                 (multiple-value-bind (asym aelem) (%208-acc-binding-elem b)
                   (when asym (push (list asym :acc aelem) inner)))
                 (unless (eq nb b) (setf changed t))
                 (push nb out)))))
       (let ((body (%208-rw-list (cddr form) inner)))
         (if (or changed (not (eq body (cddr form))))
             (list* (first form) (nreverse out) body)
             form))))
    ;; load-tile into a block tile: the scale copy FIRST (its expect_tx must precede the codes load's
    ;; arrive, from the same thread), then the codes load without :scales.
    ((%208-sym= (first form) "LOAD-TILE")
     (multiple-value-bind (entry sf) (%208-block-tile-ref (third form) tiles)
       (if (null entry)
           (%208-rw-list form tiles)
           (let* ((kw (nthcdr 4 form))
                  (scales (getf kw :scales))
                  (bar (getf kw :barrier))
                  (plain (loop for (k v) on kw by #'cddr unless (eq k :scales) append (list k v))))
             (unless scales
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) ..): ~(~a~) holds ~(~a~) blocks, so the load needs their scales: add :scales S, with (scale-layout S :of ~(~a~) :blocked-128x4) declared."
                                       (second form) (third form) (third form)
                                       (getf (getf (cdr entry) :info) :name) (second form))))
             (let ((decl (find-if (lambda (d) (string-equal (getf d :scales) (symbol-name scales)))
                                  (and *208-rw-kernel* (gethash *208-rw-kernel* *208-scale-layouts*)))))
               (unless (and (symbolp scales) decl (string-equal (getf decl :of) (symbol-name (second form))))
                 (error 'crisp-compiler-error
                        :message (format nil "load-tile ~(~a~) .. :scales ~(~a~): declare the layout of the scales, (scale-layout ~(~a~) :of ~(~a~) :blocked-128x4)."
                                         (second form) scales scales (second form)))))
             (unless bar
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) .. :scales ..): a block tile is loaded by TMA and needs :barrier." (second form) (third form))))
             (list 'progn
                   (list (intern "%208-LOAD-SCALES" (find-package :crisp.compiler))
                         scales (second form) sf (fourth form) bar
                         (getf (getf (cdr entry) :info) :name) (getf (cdr entry) :rows))
                   (list* (first form) (second form) (third form) (fourth form) plain))))))
    ;; The accumulate on block tiles: the hidden options carry the block and the scales tiles.
    ((and (%208-sym= (first form) "TCGEN05-ACCUMULATE-VIA-TILE") (>= (length form) 5))
     (multiple-value-bind (ea sfa) (%208-block-tile-ref (nth 3 form) tiles)
       (multiple-value-bind (eb sfb) (%208-block-tile-ref (nth 4 form) tiles)
         (cond ((and (null ea) (null eb)) (%208-rw-list form tiles))
               ((not (and ea eb))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile: ~(~a~) is a block tile and ~(~a~) is not.  A block-scaled multiply takes two block tiles of the same block."
                                        (if ea (nth 3 form) (nth 4 form)) (if ea (nth 4 form) (nth 3 form)))))
               (t (%208-check-block-accumulate form ea eb tiles)
                  (append form
                          (list :%block-a (getf (getf (cdr ea) :info) :name) :%sf-a sfa
                                :%block-b (getf (getf (cdr eb) :info) :name) :%sf-b sfb)))))))
    (t (%208-rw-list form tiles))))

(defun %208-rewrite-block-kernel (form)
  "Endeavour 208 phase 4.  A def-function FORM with its scale-layout declarations recorded and, when it
   holds block scratch tiles, its body rewritten (section header).  Any other FORM comes back EQ."
  (let ((name (second form)) (params (third form)) (body (cdddr form)))
    (when (and (symbolp name) (listp params))
      (%208-parse-scale-layouts name params body))
    (if (%208-tree-has-block-scratch-p body)
        (let ((new (let ((*208-rw-kernel* (string-downcase (symbol-name name)))) (%208-rw-list body nil))))
          (log:debug "208 block-scaled source rewrite of ~a" name)
          (if (eq new body) form (list* (first form) name params new)))
        form)))

(defun %208-block-tile-ref (form tiles)
  "Endeavour 208 phase 4.  When FORM is a block tile X or (ring-get X I) of TILES: (values ENTRY SF-FORM),
   SF-FORM naming the matching scales tile (X--SCALES, or (ring-get X--SCALES I)).  Entries without
   :info (accumulator bindings) are not block tiles."
  (let* ((sym (cond ((and form (symbolp form)) form)
                    ((and (consp form) (%208-sym= (first form) "RING-GET") (symbolp (second form))) (second form))))
         (e (and sym (find-if (lambda (x) (and (eq (car x) sym) (getf (cdr x) :info))) tiles))))
    (when e
      (values e (if (symbolp form)
                    (getf (cdr e) :sf)
                    (list (first form) (getf (cdr e) :sf) (third form)))))))
