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
