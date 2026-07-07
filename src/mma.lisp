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

(defun analyze-make-register-fragment (expr env context location)
  "P1: (make-register-fragment M N INIT) -> a register-fragment accumulator record.
   Only the 16x8 fp32 shape is minted for now; rewrite to %construct-struct with INIT
   splatted across the 4 per-lane registers and analyze that."
  (destructuring-bind (m n init) (cdr expr)
    (unless (and (eql m 16) (eql n 8))
      (error 'crisp-compiler-error
             :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
    (analyze-expression
     `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init)
     env context location)))

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

(defun analyze-store-fragment (expr env context location)
  "P1/P2: rewrite (store-fragment FRAG DEST (TY TX)) to per-lane matrix element writes
   using the m16n8 fp32 accumulator layout, then analyze that.  FRAG is bound to a temp
   FIRST so a value-producing FRAG (e.g. an inline mma-accumulate) is evaluated ONCE,
   not once per field extraction."
  (destructuring-bind (frag dest tile-id) (cdr expr)
    (let ((ty (first tile-id))
          (tx (second tile-id)))
      (analyze-expression
       `(let ((frag-val ,frag))
          (let ((lane (to-int (warp-lane))))
            (let ((g  (/ lane 4))
                  (t2 (* 2 (rem lane 4))))
              (let ((row (+ (* ,ty 16) g))
                    (col (+ (* ,tx 8) t2)))
                (set! (~ ,dest row col)               (%extract-struct-member frag-val 0))
                (set! (~ ,dest row (+ col 1))         (%extract-struct-member frag-val 1))
                (set! (~ ,dest (+ row 8) col)         (%extract-struct-member frag-val 2))
                (set! (~ ,dest (+ row 8) (+ col 1))   (%extract-struct-member frag-val 3))))))
       env context location))))

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
  "P2: rewrite (load-fragment-a SRC (TY TK)) to a per-lane read of the 16x8 tf32 A
   fragment, offset by the tile origin (TY*16, TK*8), then analyze."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (analyze-expression
       `(let ((lane (to-int (warp-lane))))
          (let ((g (/ lane 4)) (tg (rem lane 4)))
            (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
              (%construct-struct register-fragment-a-tf32-16x8
                (~ ,src r       c)
                (~ ,src (+ r 8) c)
                (~ ,src r       (+ c 4))
                (~ ,src (+ r 8) (+ c 4))))))
       env context location))))

(defun analyze-load-fragment-b (expr env context location)
  "P2: rewrite (load-fragment-b SRC (TK TX)) to a per-lane read of the 8x8 tf32 B
   fragment, offset by the tile origin (TK*8, TX*8), then analyze."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (analyze-expression
       `(let ((lane (to-int (warp-lane))))
          (let ((g (/ lane 4)) (tg (rem lane 4)))
            (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
              (%construct-struct register-fragment-b-tf32-8x8
                (~ ,src r       c)
                (~ ,src (+ r 4) c)))))
       env context location))))

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
  "P2: (mma-accumulate C A B) -> a semantic-mma-accumulate node typed as the fp32
   accumulator fragment."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (make-semantic-mma-accumulate
     :type 'register-fragment-acc-f32-16x8
     :c-node (analyze-expression c-arg env context location)
     :a-node (analyze-expression a-arg env context location)
     :b-node (analyze-expression b-arg env context location)
     :source-location location)))

(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "P2: emit one tf32 m16n8k8 MMA (@llvm.nvvm.mma.m16n8k8.row.col.tf32)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let* ((c-val (gen (semantic-mma-accumulate-c-node node)))
           (a-val (gen (semantic-mma-accumulate-a-node node)))
           (b-val (gen (semantic-mma-accumulate-b-node node)))
           (f32 (llvm-float-type))
           (i32 (llvm-int32-type))
           ;; A: 4 f32 fields -> bitcast to i32 (tf32 passed as i32)
           (a-ops (loop for i below 4
                        collect (llvm-build-bit-cast
                                 builder
                                 (llvm-build-extract-value builder a-val i (format nil "a~d" i))
                                 i32 (format nil "a~di" i))))
           ;; B: 2 f32 fields -> i32
           (b-ops (loop for i below 2
                        collect (llvm-build-bit-cast
                                 builder
                                 (llvm-build-extract-value builder b-val i (format nil "b~d" i))
                                 i32 (format nil "b~di" i))))
           ;; C: 4 f32 fields (accumulator, passed as f32)
           (c-ops (loop for i below 4
                        collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
           ;; intrinsic return type {f32 x 4}
           (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                     (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) f32))
                     (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
           ;; param types: i32 x6, f32 x4
           (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                    (loop for i from 0 for ty in (list i32 i32 i32 i32 i32 i32 f32 f32 f32 f32)
                          do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                    (llvm-function-type ret-ty arr 10 nil)))
           (fn-name "llvm.nvvm.mma.m16n8k8.row.col.tf32")
           (fn (let ((existing (llvm-get-named-function module fn-name)))
                 (if (cffi:null-pointer-p existing)
                     (llvm-add-function module fn-name fn-ty)
                     existing)))
           (args (append a-ops b-ops c-ops))       ; 4 + 2 + 4 = 10
           (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                       (loop for i from 0 for v in args
                             do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                       arr))
           (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma"))
           ;; rebuild the accumulator fragment record from the 4 result f32
           (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f32-16x8 module))
           (result (let ((agg (llvm-get-undef acc-ty)))
                     (dotimes (i 4)
                       (setf agg (llvm-build-insert-value
                                  builder agg
                                  (llvm-build-extract-value builder call i (format nil "d~d" i))
                                  i (format nil "acc~d" i))))
                     agg)))
      (values result nil))))

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

(defun analyze-make-register-tile (expr env context location)
  "P3a: (make-register-tile T (M N) INIT) -> a record-of-fragments accumulator tile,
   each fragment initialized to INIT.  Mints the tile type on demand; rewrites to
   %construct-struct of make-register-fragment fields."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))          ; tf32/fp32 fixed for now
    (destructuring-bind (m n) dims
      (let* ((tile-name (%ensure-register-tile-type m n))
             (nfrags (* (floor m 16) (floor n 8))))
        (analyze-expression
         `(%construct-struct ,tile-name
                             ,@(loop repeat nfrags collect `(make-register-fragment 16 8 ,init)))
         env context location)))))

(defun analyze-store-tile-mma (expr env context location)
  "Overload of store-tile: if the source is a register-tile, store each fragment via
   store-fragment at its (row-tile, col-tile) offset; otherwise delegate to the existing
   (SLM / async) store-tile analyzer."
  (let* ((src-node (analyze-expression (second expr) env context (append location '(1))))
         (src-type (semantic-node-type src-node)))
    (if (%register-tile-type-p src-type)
        (destructuring-bind (m n) (gethash src-type *register-tile-dims*)
          (let* ((tile    (second expr))
                 (dest    (third expr))
                 (tile-id (fourth expr))
                 (bty (first tile-id)) (btx (second tile-id))
                 (m-frags (floor m 16)) (n-frags (floor n 8)))
            (analyze-expression
             `(let ((tv ,tile))
                (progn
                  ,@(loop for mi below m-frags
                          append (loop for nj below n-frags
                                       for idx = (+ (* mi n-frags) nj)
                                       ;; tile-id (bty btx) may be RUNTIME (e.g. gy/gx
                                       ;; from workgroup-id), so emit the offset as a FORM
                                       ;; (bty*m-frags + mi), not an evaluated constant.
                                       collect `(store-fragment (%extract-struct-member tv ,idx)
                                                                ,dest
                                                                ((+ (* ,bty ,m-frags) ,mi)
                                                                 (+ (* ,btx ,n-frags) ,nj)))))))
             env context location)))
        (analyze-store-tile-expression expr env context location))))

;;; ===================================================================
;;; P3b — mma-accumulate-via-tile (bodyless): walk the register C-tile in MMA
;;; fragments, accumulate one K-step, set! the tile back.  Composes P2/P3a
;;; primitives (load-fragment-a/b, mma-accumulate, the tile record) — a rewrite.
;;; ===================================================================

(defun %check-mma-shape (mma-shape location)
  "Validate the (M N K) MMA shape: a positive-int triple, in the P3 supported set
   (tf32 (16 8 8) for now), and — if a hardware profile is active — a member of its
   :mma-shapes (endeavor 130 key; precision is implicit in K)."
  (unless (and (listp mma-shape) (= (length mma-shape) 3) (every #'integerp mma-shape))
    (error 'crisp-compiler-error
           :message (format nil "mma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." mma-shape)
           :source-location location))
  (unless (equal mma-shape '(16 8 8))
    (error 'crisp-compiler-error
           :message (format nil "mma-accumulate-via-tile: only tf32 (16 8 8) is supported so far, got ~a." mma-shape)
           :source-location location))
  (let ((profile (active-hardware-profile)))
    (when profile
      (let ((shapes (getf profile :mma-shapes)))
        (when (and shapes (not (member mma-shape shapes :test #'equal)))
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: shape ~a is not one of the active hardware profile's :mma-shapes ~a."
                                  mma-shape shapes)
                 :source-location location))))))

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
  "T if FORM is a (make-register-tile T (M N) INIT) constructor."
  (and (consp form) (= (length form) 4) (%head-name-eq (first form) "MAKE-REGISTER-TILE")
       (listp (third form)) (= (length (third form)) 2)))

(defun %register-tile-frag-syms (var m n)
  "The N per-fragment variable symbols for tile VAR of shape MxN (row-major
   fragment grid), interned in VAR's package with a `$F<i>' suffix."
  (let ((nfrags (* (floor m 16) (floor n 8))))
    (loop for i below nfrags
          collect (intern (format nil "~a$F~d" (symbol-name var) i) (symbol-package var)))))

(defparameter *default-max-registers-per-thread* 255
  "Fallback per-thread register budget for the register-tile fit-check when no
   hardware profile pins :max-registers-per-thread.  255 = NVIDIA architectural max.")

(defun %register-tile-fit-check (m n location)
  "F1 (Endeavor 132) — register FIT-CHECK.  A register-tile accumulator is now
   register-resident (residency fix, 2026-07-06), so its size is bounded by the
   per-thread register file.  Error if the (M/16)×(N/8) accumulator fragments — 4 fp32
   regs each (tf32 m16n8k8) — exceed :max-registers-per-thread (from the active hardware
   profile, else the NVIDIA default 255).  Single-warp for now, so fragments/warp = total."
  (let* ((nfrags        (* (floor m 16) (floor n 8)))
         (regs-per-frag 4)                        ; fp32 accumulator, tf32 m16n8k8
         (total-regs    (* nfrags regs-per-frag))
         (profile       (active-hardware-profile))
         (budget        (or (and profile (getf profile :max-registers-per-thread))
                            *default-max-registers-per-thread*)))
    (when (> total-regs budget)
      (error 'crisp-compiler-error
             :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                              m n total-regs nfrags regs-per-frag budget)
             :source-location location))))

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

(defun %emit-per-frag-accumulate (a b entry &optional accum-binding body)
  "Per-fragment expansion of mma-accumulate-via-tile, matching the index/layout math.
   Bodyless: one accumulate set!/frag (implicit accum-op).  With ACCUM-BINDING + BODY
   (F3): splice BODY per fragment, substituting the binding symbol -> the fragment var
   and (accum-op) -> that fragment's accumulate set! (so the body controls when/how often
   the MMA fires and can fuse an epilogue on the bound accumulator, in registers)."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       for fv = (nth idx syms)
                       for acc-set = `(set! ,fv (mma-accumulate ,fv
                                                                (load-fragment-a ,a (,mi 0))
                                                                (load-fragment-b ,b (0 ,nj))))
                       append (if body
                                  (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                                  (list acc-set))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)): one store-fragment
   per fragment, matching analyze-store-tile-mma's runtime-offset math."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8))
          (bty (first tile-id)) (btx (second tile-id)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       collect `(store-fragment ,(nth idx syms)
                                                ,dest
                                                ((+ (* ,bty ,m-frags) ,mi)
                                                 (+ (* ,btx ,n-frags) ,nj)))))))))

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

(defun %explode-register-tiles (let-expr &optional location)
  "Source->source: explode any (V (make-register-tile T (M N) INIT)) binding in
   LET-EXPR into N (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite
   the body's via-tile/store-tile references to V into per-fragment progns.  Runs the
   register FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no
   register-tile binding is present."
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
                          (destructuring-bind (mrt elem dims init) (second b)
                            (declare (ignore mrt elem))
                            (destructuring-bind (m n) dims
                              (%register-tile-fit-check m n location)
                              (let ((syms (%register-tile-frag-syms (first b) m n)))
                                (push (list (first b) m n syms) tiles)
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


(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: explode register-tile bindings into per-fragment
   mutable variables (register residency, Endeavor 132), then defer to the
   normal let analysis."
  (analyze-let-expression (%explode-register-tiles expr location) env context location))




(defun register-mma-analyzers ()
  "Registers the MMA expression analyzers in *expression-analyzers* for both
   :crisp-language and :crisp.compiler.  Called from initialize-expression-analyzers
   (which clrhash-es the table on every compiler init, so a load-time setf would not
   survive).  Overlay: adds the let/let* wrapper for register-tile residency."
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
                         ;; store-tile OVERLOAD: runs after register-control-analyzers,
                         ;; so this wins; it delegates to the SLM store-tile for non-tiles.
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         ;; let/let* WRAPPER: explode register-tile accumulators into
                         ;; per-fragment mutable vars before the normal let analysis.
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))
