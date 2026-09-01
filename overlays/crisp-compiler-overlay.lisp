;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26.
;;;;
;;;; When you fold future contents back out, two things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.

(in-package :crisp.compiler)


;;;; ====================================================================
;;;; Endeavour 159 Phase B — 16-bit sync MMA on NVIDIA.
;;;;
;;;; Endeavour 155 built the typed-shape machinery (%mma-elem-bits, %mma-shape-for-elem, the
;;;; :elem keyword) and wired it to SPV only, saying so in analyze-make-register-fragment's own
;;;; docstring: "The PTX branch is UNCHANGED: its fragment records are tf32/f32 by construction
;;;; and endeavour 155 does not touch the NVIDIA path."  This is that missing half.
;;;;
;;;; THE INTRINSICS, VERIFIED BY COMPILATION (clang --target=nvptx64 -march=sm_90 on a
;;;; standalone .ll), not from documentation:
;;;;
;;;;   tf32  llvm.nvvm.mma.m16n8k8.row.col.tf32        i32 ops   -> ...m16n8k8.row.col.f32.tf32.tf32.f32
;;;;   fp16  llvm.nvvm.mma.m16n8k16.row.col.f32.f32    <2 x half> -> ...m16n8k16.row.col.f32.f16.f16.f32
;;;;   bf16  llvm.nvvm.mma.m16n8k16.row.col.bf16       i32 ops   -> ...m16n8k16.row.col.f32.bf16.bf16.f32
;;;;
;;;; NOTE fp16 and bf16 DISAGREE on operand type.  Also: two plausible spellings
;;;; (...f16.f32, ...bf16.f32) pass the LLVM verifier as UNRESOLVED EXTERNAL CALLS -- they emit
;;;; no instruction while still leaving an "mma.m16n8k16..." substring in the PTX.  Any check
;;;; here must match the FULL mnemonic.
;;;;
;;;; DESIGN: ONE RECORD FIELD PER ELEMENT, NOT PER REGISTER.
;;;; A 16-bit A fragment is 8 halves in 4 32-bit registers.  The records below declare EIGHT
;;;; half fields (four for B), not four/two packed ones, and the pair-packing into <2 x half>
;;;; happens in ONE place, %emit-nvvm-mma.  Reasons:
;;;;   - %construct-struct in load-fragment-a/b stays a natural read of N elements;
;;;;   - field count == ELEMENT count, so %map-elements-fragment-fields is right by
;;;;     construction rather than by a second hardcoded table;
;;;;   - registers stay DERIVABLE (fields * width / 32 = 4 and 2), so endeavour 144's
;;;;     accounting is unchanged and is no longer a separate magic number.
;;;; This is the "separate the two counts" option: registers and elements coincide at 32 bits
;;;; and diverge exactly 2:1 at 16, and only one of them was ever being tracked.
;;;;
;;;; FRAGMENT LAYOUTS are from the PTX ISA mma.m16n8k16 tables.  A store/load roundtrip CANNOT
;;;; validate them (a wrong-but-self-consistent layout roundtrips perfectly); only an MMA
;;;; against a host reference can.  So these are asserted by MMA_CORRECT on metal, not by any
;;;; local test -- the local rung proves the INSTRUCTION is emitted, nothing about its operands.
;;;; ====================================================================

;; src/mma.lisp
(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float.

   Endeavour 159: the fp16 m16n8k16 twins.  A is 16x16 = 8 halves/lane, B is 16x8 = 4
   halves/lane, both ONE FIELD PER ELEMENT (see the header).  The ACCUMULATOR is deliberately
   NOT twinned: a 16-bit MMA accumulates in fp32, so register-fragment-acc-f32-16x8 is reused
   unchanged -- the same reason %coop-elem-of does not route accumulators.

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
  ;; Endeavour 159 — fp16 m16n8k16.
  (register-struct-definition 'register-fragment-a-f16-16x16
                              '((a0 half) (a1 half) (a2 half) (a3 half)
                                (a4 half) (a5 half) (a6 half) (a7 half))
                              :record)
  (register-struct-definition 'register-fragment-b-f16-16x8
                              '((b0 half) (b1 half) (b2 half) (b3 half))
                              :record)
  (register-builtin-hardware-profiles))

;; src/mma.lisp
(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read.

   Endeavour 159: the NVIDIA branch now DISPATCHES ON THE OPERAND'S ELEMENT WIDTH, using the
   same %coop-elem-of the SPV branch already used.  A 16-bit operand reads the m16n8k16 A
   layout (8 halves/lane) instead of the m16n8k8 tf32 one (4 floats/lane).  Before this, a half
   source hit `Type mismatch! Expected FLOAT but inferred HALF` -- the four (~ src ...) reads
   inferred HALF while register-fragment-a-tf32-16x8's fields are declared FLOAT.

   PTX ISA mma.m16n8k16 A layout, 32 lanes, groupID = lane/4, tid = lane%4.  Each lane holds
   8 halves as 4 register pairs, and the PAIR ORDER IS LOAD-BEARING -- it is the order the
   intrinsic's 4 A operands are consumed in:
       Ra0 = (groupID,   2*tid), (groupID,   2*tid+1)
       Ra1 = (groupID+8, 2*tid), (groupID+8, 2*tid+1)
       Ra2 = (groupID,   2*tid+8), (groupID,   2*tid+9)
       Ra3 = (groupID+8, 2*tid+8), (groupID+8, 2*tid+9)
   Note the K stride is 16 (not 8) and each lane now spans TWO adjacent columns."
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
                 (bits  (or (%mma-elem-bits elem) 32)))
            (if (= bits 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 16) (* tg 2))))
                        (%construct-struct register-fragment-a-f16-16x16
                          (~ ,src r c)             (~ ,src r (+ c 1))
                          (~ ,src (+ r 8) c)       (~ ,src (+ r 8) (+ c 1))
                          (~ ,src r (+ c 8))       (~ ,src r (+ c 9))
                          (~ ,src (+ r 8) (+ c 8)) (~ ,src (+ r 8) (+ c 9))))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
                        (%construct-struct register-fragment-a-tf32-16x8
                          (~ ,src r c) (~ ,src (+ r 8) c) (~ ,src r (+ c 4)) (~ ,src (+ r 8) (+ c 4))))))
                 env context location)))))))

;; src/mma.lisp
(defun analyze-load-fragment-b (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,
   8x8, col-major); else the NVIDIA per-lane read.

   Endeavour 159: 16-bit dispatch, mirroring load-fragment-a.  PTX ISA mma.m16n8k16 B layout
   (16x8), 32 lanes, groupID = lane/4, tid = lane%4; each lane holds 4 halves as 2 pairs, and
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
                 (bits  (or (%mma-elem-bits elem) 32)))
            (if (= bits 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 16) (* tg 2))) (c (+ (* ,tx 8) g)))
                        (%construct-struct register-fragment-b-f16-16x8
                          (~ ,src r c)       (~ ,src (+ r 1) c)
                          (~ ,src (+ r 8) c) (~ ,src (+ r 9) c)))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                        (%construct-struct register-fragment-b-tf32-8x8
                          (~ ,src r c) (~ ,src (+ r 4) c)))))
                 env context location)))))))

;; src/mma.lisp
(defun %emit-nvvm-mma (builder module a-val b-val c-val)
  "The NVIDIA sync MMA.  Endeavour 159: dispatches on the A fragment's ELEMENT TYPE, so this
   emits either the tf32 m16n8k8 or the fp16 m16n8k16 instruction.  Returns (values acc nil).

   DETECTION is by probing the LLVM type of A's field 0 rather than by threading an :elem down:
   the caller (generate-node-ir on semantic-mma-accumulate) passes only LLVM values, and the
   fragment record already carries the answer.  The probe extract is REUSED as a0, so it costs
   no dead instruction.

   THE fp16 OPERAND TYPE IS <2 x half>, NOT i32.  This is the trap on this rung.  The tf32
   intrinsic takes i32 bit-containers, and the bf16 m16n8k16 sibling takes i32 as well -- but
   fp16 takes <2 x half>, verified by compiling each candidate through
   clang --target=nvptx64 -march=sm_90 and reading the emitted mnemonic.  Feeding the previous
   tf32 code a half fragment failed exactly here, and clearly:
       error: invalid cast opcode for cast from 'half' to 'i32'

   Fragment records declare ONE FIELD PER ELEMENT (8 halves for A, 4 for B), so the pair-packing
   into 4 A / 2 B vector registers happens HERE and only here.  The pairing order follows the
   PTX ISA register order documented on analyze-load-fragment-a/-b; those two must agree, and
   nothing local can prove they do -- MMA_CORRECT on metal is what checks it.

   The ACCUMULATOR is f32 in both paths: a 16-bit MMA accumulates in fp32."
  (let* ((f32 (llvm-float-type))
         (i32 (llvm-int32-type))
         (a0  (llvm-build-extract-value builder a-val 0 "a0"))
         (fp16-p (= (llvm-get-type-kind (llvm-type-of a0)) crisp.llvm-bindings::+llvm-half-type-kind+)))
    (if (not fp16-p)
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
        ;; ---------------- fp16 m16n8k16 (endeavour 159) ----------------
        (let* ((half-ty (llvm-half-type))
               (v2h     (llvm-vector-type half-ty 2))
               (a-elems (cons a0 (loop for i from 1 below 8
                                       collect (llvm-build-extract-value builder a-val i (format nil "a~d" i)))))
               (b-elems (loop for i below 4
                              collect (llvm-build-extract-value builder b-val i (format nil "b~d" i))))
               (pack (lambda (lo hi name)
                       ;; <2 x half> { lo, hi } -- lane 0 is the LOWER-numbered element, which is
                       ;; the order the ISA tables list the pair in.
                       (let ((v (llvm-get-undef v2h)))
                         (setf v (llvm-build-insert-element builder v lo (llvm-const-int i32 0 nil)
                                                            (format nil "~a_0" name)))
                         (setf v (llvm-build-insert-element builder v hi (llvm-const-int i32 1 nil)
                                                            (format nil "~a_1" name)))
                         v)))
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
                        (loop for i from 0 for ty in (list v2h v2h v2h v2h v2h v2h f32 f32 f32 f32)
                              do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                        (llvm-function-type ret-ty arr 10 nil)))
               (fn-name "llvm.nvvm.mma.m16n8k16.row.col.f32.f32")
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
          (values result nil)))))

;;;; ====================================================================
;;;; Endeavour 159 Phase B — map-elements!: one number was doing two jobs.
;;;;
;;;; %ptx-note-register-demand wants REGISTERS/thread; %map-elements-fragment-fields wants
;;;; scalar ELEMENTS/thread.  At 32 bits those coincide (4/4/2), so the conflation has been
;;;; invisible and free since endeavour 150.  At 16 bits they diverge exactly 2:1 -- a fp16 A
;;;; fragment is 8 elements in 4 registers.
;;;;
;;;; USER-VISIBLE CONSEQUENCE had this been left alone: analyze-map-elements dispatches on TYPE
;;;; with no accumulator-only guard, so (map-elements! a-frag #'relu) on a 16-bit operand would
;;;; have extracted 4 "float" fields that are really PACKED HALF PAIRS, applied the user's fn to
;;;; the reinterpreted bit pattern, and written it back.  Silent, numeric, no error.  The SPV
;;;; branch loops the TRUE component count, so the SAME SOURCE would have been correct on Intel
;;;; and wrong on NVIDIA -- the cross-vendor divergence class that produced 156's MMA_WRONG and
;;;; BUG 040's half dot product.
;;;;
;;;; TWO CHANGES, and the refusal is what actually closes it:
;;;;   1. the count is now DERIVED from the record's own member list, so a new fragment record
;;;;      (bf16 next) needs no second table entry and cannot disagree with itself;
;;;;   2. A/B OPERANDS are refused outright.  map-elements! was designed for the accumulator
;;;;      (endeavour 150 is the fused EPILOGUE) and every one of the 16 uses in tests/spec
;;;;      targets `acc` or `C-tile`; operands were reachable only by accident of the old case
;;;;      list.  With the refusal the 16-bit hazard is UNREACHABLE rather than merely handled.
;;;;      Refused on BOTH vendors deliberately: a form must mean the same thing on each, which
;;;;      is the lesson 155/02 paid for.  Cf. BUG 035, also closed as a refusal not a feature.
;;;; ====================================================================

;; src/analysis/control.lisp
(defun %mma-operand-fragment-p (ty coop-dims)
  "T when TY is an MMA *operand* (A or B) fragment rather than an accumulator.

   PTX: by record name -- the fragment records are register-fragment-{a,b,acc}-<elem>-<MxN>.
   SPV: by the cooperative matrix's Use operand, which COOP-DIMS carries as its third element
   (0 = A, 1 = B, 2 = Accumulator); that is the authoritative encoding, so it is read rather
   than re-derived from the type list."
  (or (and coop-dims (member (third coop-dims) '(0 1)) t)
      (and ty (symbolp ty)
           (let ((n (symbol-name ty)))
             (and (>= (length n) 20)
                  (or (string= "REGISTER-FRAGMENT-A-" (subseq n 0 20))
                      (string= "REGISTER-FRAGMENT-B-" (subseq n 0 20)))))
           t)))

;; src/analysis/control.lisp
(defun %map-elements-fragment-fields (frag-type)
  "The number of scalar ELEMENTS per invocation in a PTX fragment record type, or NIL if
   FRAG-TYPE is not one.

   Endeavour 159: DERIVED from the record's own member list instead of a hardcoded case.  The
   fragment records declare one field per element (tf32 A 16x8 -> 4, B 8x8 -> 2, acc -> 4;
   fp16 A 16x16 -> 8, B 16x8 -> 4), so the member count IS the element count and a new record
   cannot fall out of sync with a second table.  REGISTERS are a different number at 16 bits
   (elements * width / 32) and are tracked separately by %ptx-note-register-demand.

   Hopper wgmma accumulators are minted as flat f32 records by %ensure-wgmma-acc-type and keep
   their own dimension-derived count (N/2 f32 registers per thread across the warpgroup)."
  (or (when (and frag-type (symbolp frag-type)
                 (let ((n (symbol-name frag-type)))
                   (and (>= (length n) 18)
                        (string= "REGISTER-FRAGMENT-" (subseq n 0 18)))))
        (let ((def (find-struct-definition-by-name frag-type)))
          (and def (length (crisp-struct-definition-members def)))))
      (when (%wgmma-acc-type-p frag-type)
        (floor (second (gethash frag-type *wgmma-acc-dims*)) 2))))

;; src/analysis/control.lisp
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150.  TWO LOWERINGS, because the vendors represent a fragment differently:

     PTX   a record of scalar fields, count known at compile time -> UNROLLED fieldwise onto
           %construct-struct / %extract-struct-member, which already exist.
     SPV   an opaque cooperative matrix whose per-invocation component count is a RUNTIME
           value (OpCooperativeMatrixLengthKHR) -> a semantic-coop-op :map node that codegen
           turns into a LOOP, rewriting each component through the variable's own alloca via
           OpAccessChain.

   Both are elementwise and layout-agnostic: neither learns which logical (row, col) a register
   or component holds, which is why this is portable and why layout-aware epilogues are out of
   scope.  A whole register TILE is handled earlier, in %explode-rewrite-body-form, which
   expands it to one of these per fragment.

   Endeavour 159: A/B OPERAND fragments are REFUSED.  See the header above -- this was reachable
   by accident and silently wrong at 16 bits."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (%map-elements-check-unary fn-form location)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty))
           (coop (%map-elements-coop-dims ty)))
      ;; Endeavour 159 — operands are not epilogue targets.
      (when (%mma-operand-fragment-p ty coop)
        (error 'crisp-compiler-error
               :message (format nil "map-elements!: ~a is an MMA A/B OPERAND fragment, not an accumulator.  A fused epilogue applies to the RESULT of the contraction; transform an operand before it is loaded into fragments instead.  (At 16 bits an operand fragment's registers hold PACKED PAIRS, so an elementwise map over them would silently compute on reinterpreted bit patterns.)"
                               ty)
               :source-location location))
      (cond
        ;; ---- NVIDIA / PTX: unrolled fieldwise rewrite ----
        (nf
         (analyze-expression
          `(set! ,target
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect (%map-elements-call
                                                     fn-form
                                                     `(%extract-struct-member ,target ,i)))))
          env context location))
        ;; ---- Intel / SPV: runtime-length component loop ----
        (coop
         (unless (symbolp target)
           (error 'crisp-compiler-error
                  :message (format nil "map-elements!: on SPIR-V the target must be a cooperative-matrix VARIABLE (its storage is what OpAccessChain indexes), got ~a."
                                   target)
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((temp (gensym "CMELEM"))
                  (env2 (cons (make-parameter-def :name temp :type 'float :kind :local) env))
                  (body-node (analyze-expression (%map-elements-call fn-form temp)
                                                 env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map
              :ty target :tx temp :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Implemented for MMA fragments (PTX records and SPV cooperative matrices) and, via the tile explosion, whole register tiles."
                                 ty)
                :source-location location))))))

;;;; ====================================================================
;;;; Endeavour 159 Phase B — bf16 m16n8k16, the near-twin of fp16.
;;;;
;;;; VERIFIED BY COMPILATION (clang --target=nvptx64 -march=sm_90 on a standalone .ll):
;;;;   llvm.nvvm.mma.m16n8k16.row.col.bf16, operands i32 x6, C float x4
;;;;     -> mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32
;;;; and the packing route also verified end to end: <2 x bfloat> built by insertelement, then
;;;; BITCAST to i32.  fp16 hands <2 x half> to the intrinsic directly; bf16 must go the extra
;;;; bitcast.  That asymmetry is the whole difference between the two paths.
;;;;
;;;; THE FRAGMENT LAYOUT IS IDENTICAL to fp16 -- same m16n8k16 shape, same element-to-register
;;;; mapping (A 8 elements in 4 regs, B 4 in 2).  Only the element ENCODING differs.  So the two
;;;; formats share layout risk: if the fp16 ordering is wrong, bf16 is wrong the same way and one
;;;; fix corrects both.  That is why bf16 was written before any hardware validation rather than
;;;; after -- there is no independent bet being taken here.
;;;;
;;;; DETECTING WHICH 16-BIT FORMAT.  The bindings define +llvm-half-type-kind+ but NO bfloat
;;;; constant, and this LLVM install ships no llvm-c headers to read the enum from.  Rather than
;;;; hardcode a guessed value, the kinds are asked of LLVM AT RUNTIME and compared.  That cannot
;;;; drift when LLVM renumbers its enum, and it needs no constant this codebase does not have.
;;;; ====================================================================

;; src/mma.lisp
(defun %nvvm-frag-format (llvm-elem-type)
  "Which MMA operand format a fragment field's LLVM type implies: :FP16, :BF16, or :TF32.

   Endeavour 159.  Kinds are read from LLVM at runtime rather than compared against a constant --
   the bindings carry +llvm-half-type-kind+ but no bfloat equivalent, and no llvm-c header is
   installed to take the value from.  Anything that is neither half nor bfloat is the historical
   fp32-stored tf32 path."
  (let ((k (llvm-get-type-kind llvm-elem-type)))
    (cond ((= k (llvm-get-type-kind (llvm-half-type)))   :fp16)
          ((= k (llvm-get-type-kind (llvm-bfloat-type))) :bf16)
          (t :tf32))))

;; src/mma.lisp
(defun %nvvm-frag-record (operand elem)
  "The PTX fragment record name for OPERAND (:a or :b) at Crisp element type ELEM.

   Endeavour 159.  One place decides this, so analyze-load-fragment-a and -b cannot disagree
   about which record a given element type maps to.  A 32-bit (or unknown) element keeps the
   historical tf32 records."
  (let ((bits (%mma-elem-bits elem))
        (name (and elem (symbolp elem) (symbol-name elem))))
    (if (eql bits 16)
        (if (string= name "BFLOAT16")
            (ecase operand (:a 'register-fragment-a-bf16-16x16) (:b 'register-fragment-b-bf16-16x8))
            (ecase operand (:a 'register-fragment-a-f16-16x16)  (:b 'register-fragment-b-f16-16x8)))
        (ecase operand (:a 'register-fragment-a-tf32-16x8) (:b 'register-fragment-b-tf32-8x8)))))

;; src/mma.lisp
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
  (register-builtin-hardware-profiles))

;; src/mma.lisp
(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
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
                 (rec   (%nvvm-frag-record :a elem)))
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
                 env context location)))))))

;; src/mma.lisp
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
                 (rec   (%nvvm-frag-record :b elem)))
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
                 env context location)))))))

;; src/mma.lisp
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

   The ACCUMULATOR is f32 in every path: a 16-bit MMA accumulates in fp32."
  (let* ((f32 (llvm-float-type))
         (i32 (llvm-int32-type))
         (a0  (llvm-build-extract-value builder a-val 0 "a0"))
         (fmt (%nvvm-frag-format (llvm-type-of a0))))
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
          (values result nil)))))

;;;; ====================================================================
;;;; Endeavour 159 — TMA (:block) load-tile at 16-bit element widths.
;;;;
;;;; THE BLOCKER.  The NVIDIA 16-bit ladder stops dead at chapter 6 (warp specialization), which
;;;; is the highest rung reachable WITHOUT wgmma -- chap6 uses the sync MMA, so it needs no new
;;;; instruction, only its producer warp's TMA loads.  Those were refused:
;;;;
;;;;     load-tile :block: element type BFLOAT16 needs 4 or 8 bytes
;;;;
;;;; because the byte table listed only (int uint float)->4 and (long ulong double)->8.
;;;;
;;;; WHY WIDENING IT IS CORRECT HERE.  The number is used for ONE thing: the tx byte count on
;;;; `mbarrier.arrive.expect_tx`, computed as (length~ TILE) * elem-bytes.  For a 2-byte element
;;;; the correct count is simply 2 per element.  The copy itself is `cp.async.bulk.tensor`, which
;;;; is DESCRIPTOR-driven -- the CUtensorMap carries the element type, and f16/bf16 are among the
;;;; types it encodes.  Nothing in the bulk-tensor path is 4-byte-granular.
;;;;
;;;; WHY THE SIBLING SITE MUST **NOT** BE WIDENED THE SAME WAY.  `%cp-async-copy-elem`
;;;; (src/analysis/control.lisp:1135) raises the same message for the plain `cp.async` path, and
;;;; there the constraint is REAL HARDWARE: cp.async.ca.shared.global only accepts 4, 8 or 16
;;;; bytes.  That is the same limit endeavour 159 Phase A measured from the other side -- the CUDA
;;;; control staged a single 2-byte element per thread, never took the accelerated path, and read
;;;; a flat ~3.4 TFLOPS at every size.  A 2-byte element there needs TWO elements packed into one
;;;; 4-byte copy, which is a different change and not this one.
;;;;
;;;; So: identical error text, two different causes, and only one of them is a Crisp defect.
;;;; ====================================================================

;; src/analysis/control.lisp
(defun %analyze-nvvm-tma-load-tile-at-base (expr env context location)
  "Endeavor 137 (Chapter 1.5, Phase 2) — analyze (load-tile-at SRC TILE (ORIGIN...) :barrier BAR)
   for a NVIDIA :block barrier into a semantic-nvvm-tma-tile-copy.  Codegen emits one bulk
   cp.async.bulk.tensor copy issued by an elected leader, tracked by BAR's mbarrier.  We build
   the dest/source as aref-at-base forms so codegen can reuse the aref element-address machinery
   for the SLM tile base (addrspace 3) and the source tensor base (addrspace 1, the STAND-IN
   tensormap pointer).  The ORIGIN coords become the TMA {x,y} tile-box operands (element units).

   Endeavour 159: 16-bit element types are accepted.  ELEM-BYTES feeds only the
   mbarrier.arrive.expect_tx byte count; the copy is descriptor-driven cp.async.bulk.tensor,
   whose tensormap encodes f16/bf16 directly.  See the header above for why the cp.async sibling
   site keeps its 4/8-byte restriction -- there it is a hardware limit, not a table omission."
  (let* ((src-form     (second expr))
         (tile-form    (third expr))
         (origin-list  (fourth expr))
         (key-args     (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil))
         (cl-pkg       (find-package :crisp-language))
         (aref-sym     (intern "~" cl-pkg))
         (length-sym   (intern "LENGTH~" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (rank         (length origin-list))
         (base-idx     (make-list rank :initial-element (list to-ulong-sym 0)))
         (dst-aref     (list* aref-sym tile-form base-idx))
         (src-aref     (list* aref-sym src-form base-idx))
         (dst-node     (analyze-expression dst-aref env context (append location '(1))))
         (src-node     (analyze-expression src-aref env context (append location '(2))))
         (coord-nodes  (loop for o in origin-list for i from 0
                             collect (analyze-expression o env context (append location (list 3 i)))))
         (barrier-node (analyze-expression barrier-form env context (append location '(4))))
         ;; tx byte count for mbarrier.arrive.expect_tx = (length~ TILE) * elem-bytes.
         (len-node     (analyze-expression (list length-sym tile-form) env context (append location '(5))))
         (elem-type    (semantic-node-type dst-node))
         (elem-bytes   (case (if (listp elem-type) (first elem-type) elem-type)
                         ((half bfloat16) 2)       ; Endeavour 159
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (error 'crisp-compiler-error
                              :message (format nil "load-tile :block: element type ~S needs 2, 4 or 8 bytes" elem-type)
                              :source-location location)))))
    ;; Endeavor 140 (warp-spec leader): tag the copy node when it is analyzed inside a
    ;; with-warp-specialization role block, so codegen elects laneid==0 of the producer warp
    ;; (not global tid==0) — making consumer-first warp specialization first-class and removing
    ;; the producer-first ordering constraint.
    (let ((node (make-semantic-nvvm-tma-tile-copy
                 :dst-aref-node dst-node
                 :src-aref-node src-node
                 :coord-nodes coord-nodes
                 :barrier-node barrier-node
                 :tile-length-node len-node
                 :elem-bytes elem-bytes
                 :src-name (and (symbolp src-form) src-form)
                 :type 'nil
                 :source-location location)))
      (when *in-warp-spec-block*
        (setf (gethash node *tma-copy-ws-leader*) t))
      node)))
