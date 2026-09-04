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



;;; ======================================================================
;;; Endeavour 163 defect A — a register tile bound INSIDE a tile-stride body got no adjoint.
;;;
;;; SYMPTOM.  `Unknown variable C-TILE_ADJ` under --differentiate for every 155 rung, and for
;;; a tf32 twin of the same kernel — so neither an MMA defect nor a 16-bit one.  Hoisting the
;;; identical bindings to the enclosing let compiled clean.
;;;
;;; MEASURED CAUSE, not assumed.  Both role predicates scanned flat-anf with
;;;     (loop for form in flat-anf thereis ...)
;;; which sees only the TOP LEVEL of the list.  `flatten-anf-body` flattens LET and PROGN but
;;; leaves a DOTIMES / IF / WHEN body NESTED, and `tile-stride` expands to a workgroup-strided
;;; outer LOOP — so a tile bound in its body is invisible to a top-level scan.
;;;
;;; The consequence was NOT a missing binding.  The adjoint WAS minted (verified in the debug
;;; ANF: `(C-TILE_ADJ (MAKE-REGISTER-TILE FLOAT (8 16) 0.0))` present in both cases).  What
;;; changed was the DISPATCH: with the predicate answering NIL, generate-backward-walk's
;;; register-accumulator clause never fired (0 hits vs 4 when hoisted), so the store fell
;;; through to the generic %STORE-TILE-AT-BWD (42 hits vs 2) — and %explode-rewrite-body-form
;;; rewrites only %LOAD-REGISTER-TILE-ACC / FILL-TILE / LOAD-TILE / MMA-ACCUMULATE-VIA-TILE /
;;; STORE-TILE.  %STORE-TILE-AT-BWD is not on that list, so it kept the WHOLE-TILE symbol and
;;; indexed it as memory, and the name died with the SROA explosion.
;;;
;;; THE FIX IS THE ONE THIS FILE ALREADY KNOWS.  %mma-ad-walk-forms exists for precisely this
;;; blind spot and says so in its own docstring; 145 P3b applied it to the tile MAPS and left
;;; the two role PREDICATES on the flat scan.  This finishes that job.  No new derivative, no
;;; new backward machinery: a scheduling construct's nesting had hidden the math, which is the
;;; whole thesis of endeavour 163.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-ad-register-tile-binding-exists-p (sym flat-anf extra-test)
  "T when SYM has a `(SYM (make-register-tile ...))` binding ANYWHERE in FLAT-ANF -- nested
   loop and branch bodies included -- whose init form also satisfies EXTRA-TEST (NIL to
   accept any).

   Mirrors the `thereis` semantics of the flat scans it replaces: it asks whether SOME
   binding of SYM qualifies, so a symbol bound in two roles answers exactly as before."
  (and (symbolp sym)
       (let ((found nil))
         (%mma-ad-walk-forms
          flat-anf
          (lambda (form)
            (when (and (not found)
                       (consp form) (= (length form) 2)
                       (eq (first form) sym)
                       (consp (second form)) (symbolp (first (second form)))
                       (string-equal (symbol-name (first (second form)))
                                     "MAKE-REGISTER-TILE")
                       (or (null extra-test) (funcall extra-test (second form))))
              (setf found t))))
         found)))

;; src/autodiff.lisp
(defun %mma-ad-register-tile-p (sym flat-anf)
  "Endeavor 145 P3b: T when SYM is bound in FLAT-ANF by a make-register-tile constructor.
   Distinguishes a register accumulator tile from an SLM scratch tile, which the AD walk
   must treat completely differently at a store.

   Endeavour 163 defect A: the scan now descends into nested bodies, so a tile bound inside
   a tile-stride (or any loop / branch) body is found.  See the header above."
  (%mma-ad-register-tile-binding-exists-p sym flat-anf nil))

;; src/autodiff.lisp
(defun %mma-ad-register-accumulator-tile-p (sym flat-anf)
  "T when SYM is a register tile in the ACCUMULATOR role — a make-register-tile with no
   :operand key.

   Endeavor 146: the store backward needs this narrower question, not %mma-ad-register-tile-p.
   Gap 4 split the two roles apart at the ADJOINT: an accumulator's adjoint is still a
   register tile (it is seeded from the destination's gradient by %load-register-tile-acc and
   staged to SLM by the VJP), while an OPERAND's adjoint is a scratch matrix, because every
   consumer indexes it as memory and a register tile cannot be written element-wise.

   Asking the broad question after that split emitted %load-register-tile-acc — a REGISTER
   operation — against a scratch-matrix adjoint, which the analyzer then rejected with
   `Unsupported form '%LOAD-REGISTER-TILE-ACC' found in function body`.  Operand tiles now
   fall through to the ordinary store-tile-at backward, which is the memory-shaped edge their
   memory-shaped adjoint wants.

   Endeavour 163 defect A: the scan now descends into nested bodies, so a tile bound inside
   a tile-stride (or any loop / branch) body is found.  See the header above."
  (%mma-ad-register-tile-binding-exists-p
   sym flat-anf
   (lambda (init-form) (not (%mma-ad-register-operand-tile-p init-form)))))

;;; ======================================================================
;;; Endeavour 163 defect C = BUG 054 — AD MINTED TF32 TILES FOR 16-BIT OPERANDS.
;;;
;;; The tile-multiply VJP built every backward temporary with a hardcoded FLOAT:
;;;
;;;     (float-s (intern "FLOAT" cl-pkg))
;;;     ((dc-slm (make-scratch-matrix FLOAT (mt nt)))    ; an MMA OPERAND
;;;      (at-slm (make-scratch-matrix FLOAT (kt mt)))    ; an MMA OPERAND
;;;      (bt-slm (make-scratch-matrix FLOAT (nt kt)))    ; an MMA OPERAND
;;;      (da-reg (make-register-tile  FLOAT (mt kt) 0.0)) ; accumulator — correct
;;;      (db-reg (make-register-tile  FLOAT (kt nt) 0.0)))
;;;
;;; For an fp16/bf16 kernel the first three are wrong: they are the OPERANDS of the two
;;; backward GEMMs and must carry the forward's element type.  The accumulators are right as
;;; they stand — XMX and the tensor cores take 16-bit operands and accumulate in fp32.
;;;
;;; HOW IT SURFACED, and why it was reported as two different bugs.  The symptom is
;;; backend-dependent because the SPIR-V builtin is NOT type-mangled and %coop-call caches the
;;; declaration by NAME alone (src/codegen.lisp): the first emission wins the signature and
;;; every later caller reuses that function with its OWN type.  So a module holding a half
;;; FORWARD and a float BACKWARD ends up calling one symbol at two signatures:
;;;
;;;     declare ... @__spirv_CooperativeMatrixMulAddKHR(half 8x16, half 16x16, float 8x16)
;;;       forward call  -> half  8x16   (matches)
;;;       3 backward calls -> float 8x8 (TF32 native fragment — does NOT match)
;;;
;;; LLVM bitcasts the callee and llvm-spirv refuses with "FunctionPointers: Can't translate
;;; function pointer".  On PTX there is no such check, so the same defect reads the wrong bytes
;;; and returns a SILENT WRONG GRADIENT — which is how 159 filed it.  One cause, two faces.
;;;
;;; SAFETY PROPERTY.  When the operand element IS float, op-elem resolves to FLOAT and the
;;; emission is byte-for-byte identical to before.  Every tf32 kernel is therefore untouched,
;;; which is what makes this safe to land against a green 1060-spec suite.
;;;
;;; STILL OPEN, and deliberately not fixed here: %coop-call's name-only declaration cache is a
;;; latent hazard for ANY module that legitimately mixes coop-matrix element types.  Making the
;;; operands homogeneous removes today's collision but not the trap.  Noted in the endeavour doc.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-ad-tile-dims-map (flat-anf)
  "Alist SYM -> (ROWS COLS) for every compile-time-shaped tile bound anywhere in FLAT-ANF:
   `(V (make-register-tile T (M N) INIT))`, `(V (make-scratch-matrix T (R C)))`, and — endeavor
   138 — the RING constructors, whose per-slot dimensions sit in the same position.  A ring is
   keyed by its own symbol; every slot has the ring's element shape, so a `(ring-get R i)`
   operand resolves through %ad-tile-base.

   Endeavour 163 defect C: each entry now carries the tile's ELEMENT TYPE as a fourth
   element, (SYM ROWS COLS ELEM).  Every existing consumer reads only SECOND and THIRD, so
   the extension is backward compatible; the tile-multiply VJP needs it to stage its backward
   operands in the forward's element type instead of a hardcoded FLOAT."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-REGISTER-TILE" "MAKE-SCRATCH-MATRIX"
                            "MAKE-SCRATCH-MATRIX-RING")
                          :test #'string=)
                  (let ((d (third (second form))))
                    (and (listp d) (= (length d) 2) (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (list (first form)
                     (first (third (second form)))
                     (second (third (second form)))
                     (second (second form)))
               acc))))
    (nreverse acc)))


;; src/autodiff.lisp
(defun %mma-via-tile-backward (form dims-map src-map inputs outputs local-adj-fn kernel-pkg)
  "Endeavor 145 P3b: the backward for
   `(mma-accumulate-via-tile (M N K) C-TILE A-TILE B-TILE ...)`.

   Emits ONE nested LET holding the backward's temporaries and the two backward GEMMs:

       dC-slm (Mt x Nt) <- store-tile C-tile_ADJ      ; register accumulator -> SLM
       AT-slm (Kt x Mt) <- transposed stage of A's global source
       BT-slm (Nt x Kt) <- transposed stage of B's global source
         dA-reg (Mt x Kt) : mma-accumulate-via-tile  dA-reg  dC-slm  BT-slm
         dB-reg (Kt x Nt) : mma-accumulate-via-tile  dB-reg  AT-slm  dC-slm
       store-tile dA-reg -> A-tile_ADJ ;  store-tile dB-reg -> B-tile_ADJ

   From there the existing endeavor-111 machinery finishes the job: A-tile_ADJ / B-tile_ADJ
   are already auto-allocated, and %load-tile-at-bwd already scatters them into A_GRAD /
   B_GRAD.  Because the walk runs in reverse, this rule's emission lands BEFORE those
   scatters in the generated backward — which is the order the chain rule needs.

   ERRORS when a shape or a staging source is not compile-time recoverable.  It used to
   return NIL and let the caller fall through — but the walk's fallthrough DROPS the form,
   which hands back a silent ZERO gradient.  That is the same silent-wrong-answer class as
   the K-step bug P3a fixed, and it actually bit: a K-LOOPED matmul emitted a backward with
   no MMA in it at all, because the maps only scanned the top level of flat-anf and the
   loop body is nested.  Better to refuse to compile than to quietly return zeros.

   Endeavour 163 defect C (BUG 054): the three STAGED tiles are MMA OPERANDS, so they take the
   forward operand's ELEMENT TYPE, not a hardcoded FLOAT.  The two register accumulators stay
   FLOAT, which is correct mixed precision -- XMX and the tensor cores take 16-bit operands and
   accumulate in fp32.  When the operand element IS float the emission is byte-for-byte what it
   was, so every tf32 kernel is unaffected."
  (destructuring-bind (shape c-tile a-tile b-tile &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((c-dims (assoc c-tile dims-map))
           (a-dims (assoc a-tile dims-map))
           (a-src  (assoc a-tile src-map))
           (b-src  (assoc b-tile src-map)))
      (log:debug "145 P3b via-tile bwd: c-tile=~a dims=~a | a-tile=~a dims=~a src=~a | b-tile=~a src=~a"
                 c-tile c-dims a-tile a-dims a-src b-tile b-src)
      (unless (and c-dims a-dims a-src b-src
                   (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        (error 'crisp-compiler-error
          :message (format nil "mma-accumulate-via-tile: cannot differentiate this tile multiply — ~a.  The backward needs the accumulator tile's (Mt Nt) and the A operand's Kt as COMPILE-TIME shapes, and needs each staged operand's originating global matrix (from its load-tile-at) so it can stage the transpose.  Give the tiles literal make-register-tile / make-scratch-matrix dimensions and stage both operands with load-tile-at."
                           (cond ((not c-dims) (format nil "the accumulator tile ~a has no compile-time (M N)" c-tile))
                                 ((not a-dims) (format nil "the A operand ~a has no compile-time shape" a-tile))
                                 ((not a-src)  (format nil "the A operand ~a was not staged by a load-tile-at" a-tile))
                                 (t            (format nil "the B operand ~a was not staged by a load-tile-at" b-tile))))
          :source-location nil))
      (when (and c-dims a-dims a-src b-src
                 (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        ;; INTERNAL INVARIANT (not a user-facing contract).  This function emits the MMA
        ;; lowering, which requires both backward accumulators (Mt x Kt and Kt x Nt) to
        ;; decompose into whole hardware fragments.  %vjp-mma-accumulate-via-tile has already
        ;; checked that via %mma-vjp-mma-admissible-p before routing here, so a violation means
        ;; the VJP dispatch is wrong, not the user's kernel.
        ;;
        ;; This USED to be a hard user-facing error called "the K-tile contract" — a claim that
        ;; a kernel with Kt=8 could not be differentiated at all.  That was wrong: dA = dC.B^T
        ;; and dB = A^T.dC hold at every shape, and only this LOWERING needs the dims to divide.
        ;; The condition now selects the scalar lowering instead.  See the retraction section in
        ;; tests/spec/145-mma-autodiff/mma-autodiff.md.
        (multiple-value-bind (sm sn sk) (%spv-mma-shape)
          (declare (ignore sk))
          (let ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims)))
            (unless (%mma-vjp-mma-admissible-p mt nt kt)
              (error 'crisp-compiler-error
                :message (format nil "INTERNAL: MMA backward lowering reached with a tile (Mt=~a Nt=~a Kt=~a) that does not decompose on shape (~a ~a) — the VJP should have selected the scalar lowering."
                                 mt nt kt sm sn)
                :source-location nil))))
        (let* ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims))
               (pkg (or kernel-pkg (symbol-package c-tile)))
               (cl-pkg (find-package :crisp-language))
               (nm (lambda (fmt sym) (intern (format nil fmt (symbol-name sym)) pkg)))
               (dc-slm (funcall nm "~A_BWDC"  c-tile))
               (at-slm (funcall nm "~A_BWT"   a-tile))
               (bt-slm (funcall nm "~A_BWT"   b-tile))
               (da-reg (funcall nm "~A_BWACC" a-tile))
               (db-reg (funcall nm "~A_BWACC" b-tile))
               (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj-fn kernel-pkg))
               (a-adj (%tlc-bwd-adj-name a-tile inputs outputs local-adj-fn kernel-pkg))
               (b-adj (%tlc-bwd-adj-name b-tile inputs outputs local-adj-fn kernel-pkg))
               (let-sym  (intern "LET" cl-pkg))
               (msm      (intern "MAKE-SCRATCH-MATRIX" cl-pkg))
               (mrt      (intern "MAKE-REGISTER-TILE" cl-pkg))
               (float-s  (intern "FLOAT" cl-pkg))
               (op-elem  (or (fourth (assoc a-tile dims-map))
                             (fourth (assoc b-tile dims-map))
                             float-s))
               (store-t  (intern "STORE-TILE" cl-pkg))
               (via      (intern "MMA-ACCUMULATE-VIA-TILE" cl-pkg))
               (sync     (intern "SYNC-WORKGROUP" cl-pkg)))
          `(,let-sym ((,dc-slm (,msm ,op-elem (,mt ,nt)))
                      (,at-slm (,msm ,op-elem (,kt ,mt)))
                      (,bt-slm (,msm ,op-elem (,nt ,kt)))
                      (,da-reg (,mrt ,float-s (,mt ,kt) 0.0))
                      (,db-reg (,mrt ,float-s (,kt ,nt) 0.0)))
             ;; dC: the accumulator's adjoint, register -> SLM (so it can be an MMA operand).
             (,store-t ,c-adj ,dc-slm (0 0))
             ;; The transposed operands, staged from the ORIGINAL global sources.
             ,(%mma-ad-transposed-stage at-slm (second a-src) (third a-src) mt kt)
             ,(%mma-ad-transposed-stage bt-slm (second b-src) (third b-src) kt nt)
             (,sync)
             ;; dA = dC . B^T      (Mt, Kt, Nt)
             (,via ,shape ,da-reg ,dc-slm ,bt-slm)
             ;; dB = A^T . dC      (Kt, Nt, Mt)
             (,via ,shape ,db-reg ,at-slm ,dc-slm)
             (,sync)
             (,store-t ,da-reg ,a-adj (0 0))
             (,store-t ,db-reg ,b-adj (0 0)))))))
  )
