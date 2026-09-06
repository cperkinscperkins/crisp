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

;;; ======================================================================
;;; Endeavour 163 — a 16-BIT kernel's BACKWARD needs SPV_EXT_shader_atomic_float16_add.
;;;
;;; Found while building the on-metal numeric gradient check that BUG 054's own note asked for.
;;; The forward of an fp16 MMA kernel translates fine.  Its BACKWARD does not:
;;;
;;;     RequiresExtension: Feature requires the following SPIR-V extension:
;;;      SPV_EXT_shader_atomic_float16_add            (llvm-spirv exit 18)
;;;
;;; because the gradient SCATTER accumulates into A_GRAD / B_GRAD, and those carry the INPUT's
;;; element type -- half -- so the scatter is a half-typed `atomicrmw fadd`.  The ext list asked
;;; for SPV_EXT_shader_atomic_float_add (fp32) and nothing else, so any 16-bit kernel was
;;; untranslatable under --differentiate.  Verified by hand: adding the extension to the exact
;;; failing invocation translates the same .bc cleanly.
;;;
;;; WHY A TEXT SCAN RATHER THAN A MODULE PREDICATE.  Its siblings (%module-uses-coop-matrix-p,
;;; %module-uses-2d-block-io-p) scan FUNCTION NAMES, which cannot see this: `atomicrmw` is an
;;; INSTRUCTION, not a named builtin call.  A module walk would need LLVMGetFirstBasicBlock /
;;; GetFirstInstruction bindings, none of which exist yet.  %inject-cache-control-decorations
;;; already text-scans the emitted .ll in this very function, so this follows local precedent
;;; instead of adding four bindings for one predicate.  Swap it for a module walk if those
;;; bindings ever land for another reason.
;;;
;;; SCOPED TIGHT: the clause fires only when a half-typed atomic fadd is actually present, so
;;; every fp32 and tf32 module gets byte-identical flags.
;;; ======================================================================

;; src/compiler.lisp
(defun %ll-uses-fp16-atomic-fadd-p (ll-path)
  "T when the emitted .ll text at LL-PATH contains a HALF-typed `atomicrmw fadd`, which is what
   requires SPV_EXT_shader_atomic_float16_add.

   This is the gradient-scatter shape: a backward kernel accumulates into <input>_GRAD, whose
   element type is the INPUT's, so differentiating any 16-bit kernel emits one of these.

   Deliberately narrow -- all three of `atomicrmw`, `fadd` and `half` must appear on the SAME
   line, which is how LLVM prints the instruction.  A module with fp32 atomics only answers NIL
   and its flag list is unchanged."
  (and ll-path
       (probe-file ll-path)
       (with-open-file (s ll-path :direction :input :if-does-not-exist cl:nil)
         (and s
              (loop for line = (read-line s cl:nil cl:nil)
                    while line
                      thereis (and (search "atomicrmw" line)
                                   (search "fadd" line)
                                   (search "half" line)))))))

;; src/compiler.lisp
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
    (when (or (%module-uses-native-builtin-p module)
              (%module-uses-async-copy-builtin-p module))
      (%emit-opencl-version-metadata module))
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))
      ;; ARM A: -O3 has just discarded the decorations codegen attached, so put them back on
      ;; the FINAL address arithmetic.  Inert unless CRISP_CACHE_CONTROL is set.
      (%inject-cache-control-decorations llvm-as-input)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags (append '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                              (when (%ll-uses-fp16-atomic-fadd-p
                                     (if (probe-file ll-opt-file) ll-opt-file ll-file))
                                '("--spirv-ext=+SPV_EXT_shader_atomic_float16_add"))
                              (when (%module-uses-coop-matrix-p module)
                                '("--spirv-ext=+SPV_KHR_cooperative_matrix"))
                              (when (%module-uses-2d-block-io-p module)
                                '("--spirv-ext=+SPV_INTEL_2d_block_io"))
                              (when (%module-uses-subgroup-mma-p module)
                                '("--spirv-ext=+SPV_INTEL_subgroup_matrix_multiply_accumulate"))
                              (when (%module-uses-split-barrier-p module)
                                '("--spirv-ext=+SPV_INTEL_split_barrier"))
                              (when (%module-uses-bfloat-p module)
                                '("--spirv-ext=+SPV_KHR_bfloat16"))
                              (when (and (%cache-control-spec)
                                         (%module-uses-coop-matrix-p module))
                                '("--spirv-ext=+SPV_INTEL_cache_controls"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))

;;;; ============================================================
;;;; Bug 028 Part 2 — diagnostic redef: verbose logging to confirm
;;;; %remove-dead-array-returning-functions is called and what it sees.
;;;; Remove once confirmed working.
;;;; ============================================================

;; src/compiler.lisp

;;; ======================================================================
;;; Endeavour 163 — 16-BIT GRADIENTS ACCUMULATE IN fp32 (the "path (a)" decision).
;;;
;;; THE PROBLEM.  A 16-bit input's _GRAD slot carried the INPUT's element type, so the gradient
;;; SCATTER was a half-typed `atomicrmw fadd`.  Two consequences, both bad:
;;;   1. BMG cannot run it at all.  The module must declare SPV_EXT_shader_atomic_float16_add,
;;;      and IGC's SPIR-V reader refuses to LOAD a module that declares it:
;;;         InvalidModule: ... uses extension 'SPV_EXT_shader_atomic_float16_add' which were
;;;         disabled by --spirv-ext option
;;;      Same shape as the bf16 gap in 155/02's header.  The tf32 twin 145/09, whose scatter is
;;;      fp32, verifies on the same box -- the ONLY difference is the atomic's element width.
;;;   2. Even where it runs, it is numerically poor: a gradient element accumulates one
;;;      contribution per (m,n) pair, and fp16 has ~3 decimal digits.  Summing hundreds of terms
;;;      into fp16 loses far more than the forward ever does.
;;;
;;; THE RULE, and it is the industry-standard one: 16-BIT WEIGHTS, 32-BIT GRADIENTS.  PyTorch's
;;; AMP keeps fp32 master gradients for fp16 forward weights for exactly these two reasons.
;;;
;;; WHERE IT LANDS.  %compute-backward-kernel-params already promoted INTEGER tensors to float
;;; ("integer-typed inputs receive float-typed _GRAD slots") and passed ANY float tensor through
;;; unchanged -- which silently included half and bfloat16.  A narrow-float clause now sits ahead
;;; of that passthrough, mirroring the integer one.  The bare-scalar branch gets the same
;;; treatment: a half scalar's gradient cell holds FLOAT.
;;;
;;; SCOPED DELIBERATELY NARROW -- this promotes the KERNEL-BOUNDARY _GRAD slots ONLY.  It does
;;; NOT touch the MMA operand staging: the tile-multiply VJP takes its staged operands' element
;;; type from the forward tile via the dims-map (endeavour 163 defect C), so dC/A^T/B^T stay
;;; 16-bit and the backward still issues 16-bit MMA.  Promoting those would have undone defect
;;; C's fix.  fp32 and tf32 kernels are unaffected: a float tensor is not narrow, so every
;;; existing signature is byte-for-byte what it was.
;;;
;;; ABI NOTE: a 16-bit kernel's backward now writes fp32 gradient buffers, so a host allocating
;;; them must size for 4 bytes/element.  That is the intended consequence, not a side effect.
;;; ======================================================================

;; src/autodiff.lisp
(defun %crisp-narrow-float-scalar-p (type-spec)
  "T if TYPE-SPEC resolves to a FLOAT-category SCALAR narrower than 32 bits -- i.e. `half` or
   `bfloat16`, both registered as (16 :float) in the type registry.

   Resolves def-type aliases first, exactly as %crisp-float-type-p does, so an alias for half
   answers T."
  (let* ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec))
         (direct-info (and (symbolp resolved) (gethash resolved *crisp-types*)))
         (base (if direct-info resolved (ignore-errors (compute-base-type resolved))))
         (info (when base (gethash base *crisp-types*))))
    (and info
         (eq (crisp-type-category info) :float)
         (< (crisp-type-size info) 32))))

;; src/autodiff.lisp
(defun %crisp-narrow-float-tensor-type-p (type-spec)
  "T if TYPE-SPEC resolves to a tensor whose element is a 16-bit float.  Mirrors
   %crisp-integer-tensor-type-p, which is the clause this one sits beside."
  (let ((canonical (ignore-errors (canonicalize-type-specifier type-spec))))
    (and (consp canonical)
         (symbolp (first canonical))
         (string-equal (symbol-name (first canonical)) "TENSOR")
         (%crisp-narrow-float-scalar-p (second canonical)))))

;; src/autodiff.lisp
(defun %narrow-float-tensor-elem-to-float (type-spec)
  "Replaces a 16-bit float tensor's element type with FLOAT, preserving rank, address space,
   alignment and contiguous-term.  Returns TYPE-SPEC unchanged if it is not one.
   The 6-tuple rebuild mirrors %integer-tensor-elem-to-float exactly."
  (if (%crisp-narrow-float-tensor-type-p type-spec)
      (let ((canonical (canonicalize-type-specifier type-spec)))
        ;; 6-tuple: (tensor elem N addr aln ct)
        (list (nth 0 canonical) 'float (nth 2 canonical)
              (nth 3 canonical) (nth 4 canonical) (%get-tensor-ct canonical)))
      type-spec))

;; src/macros.lisp
(defun %compute-backward-kernel-params (flat-inputs flat-input-types outputs output-types
                                                    record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
  "Computes the parameter lists and type lists for the backward (gradient) kernel.
085: integer tensor inputs now also receive _GRAD outputs, typed as float tensors
(64-bit integers → double, all others → float). The backward walk still only
processes float inputs — integer tensor inputs contribute zero gradient."
  (let* ((record-exploded-syms
          (loop for orig in inputs
                  append (cl:let ((flds (gethash orig record-subs-ht)))
                           (when flds (mapcar #'cdr flds)))))

         ;; Backward-walk participation: per the 101 endeavor, float AND
         ;; integer scalars, float AND integer tensors, cells (any element
         ;; type).  Integer-scalar inputs used purely as indices end up
         ;; with always-zero adjoints automatically — index operators
         ;; (aref, cell read at index) have no gradient rule for the
         ;; index argument, so the chain rule never reaches them.
         (differentiable-non-rec-p
          (lambda (t-spec)
            (cl:let ((canonical (canonicalize-type-specifier t-spec)))
              (or (%crisp-float-type-p t-spec)
                  (%crisp-integer-scalar-type-p t-spec)
                  (%crisp-float-tensor-type-p t-spec)
                  (%crisp-integer-tensor-type-p t-spec)
                  (and (consp canonical)
                       (string-equal (symbol-name (first canonical)) "CELL"))))))

         ;; Gets-grad-output: same set as differentiable-non-rec-p.
         ;; Integer-typed inputs receive float-typed _GRAD slots.  Index
         ;; uses produce always-zero gradients (correct semantics, free).
         (has-grad-output-p
          (lambda (t-spec) (funcall differentiable-non-rec-p t-spec)))

         (non-rec-scalar-in-grad-params
          (loop for p in flat-inputs
                for t-spec in flat-input-types
                  unless (or (%crisp-record-type-p t-spec)
                             (member p record-exploded-syms :test #'eq)
                             (not (funcall has-grad-output-p t-spec)))
                collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

         ;; Promote each input's _GRAD type to a writeable float-adjoint slot.
         ;; - integer/float tensor      → element-promoted tensor (read-write)
         ;; - integer/float cell        → element-promoted cell (keyword form)
         ;; - integer/float bare scalar → wrap in (cell <float-elem> :address-space :global)
         ;;   so the gradient can flow back to the caller via pointer indirection
         ;;   (bare scalar &out can't carry a value back).
         (non-rec-scalar-in-grad-types
          (loop for p in flat-inputs
                for t-spec in flat-input-types
                  unless (or (%crisp-record-type-p t-spec)
                             (member p record-exploded-syms :test #'eq)
                             (not (funcall has-grad-output-p t-spec)))
                collect (cond
                         ((%crisp-integer-tensor-type-p t-spec)
                           (%integer-tensor-elem-to-float t-spec))
                         ((%crisp-narrow-float-tensor-type-p t-spec)
                           (%narrow-float-tensor-elem-to-float t-spec))
                         ((%crisp-float-tensor-type-p t-spec)
                           (%ensure-tensor-read-write t-spec))
                         ((%crisp-integer-cell-type-p t-spec)
                           (%integer-cell-elem-to-float t-spec))
                         ((let ((c (canonicalize-type-specifier t-spec)))
                            (and (consp c) (symbolp (first c))
                                 (string-equal (symbol-name (first c)) "CELL")))
                           ;; Float-element cell: pass through unchanged.
                           t-spec)
                         ((%crisp-integer-scalar-type-p t-spec)
                           (list 'cell (%integer-scalar-to-float-scalar t-spec)
                                 :address-space :global))
                         ((%crisp-float-type-p t-spec)
                           (list 'cell (if (%crisp-narrow-float-scalar-p t-spec) 'float t-spec)
                                 :address-space :global))
                         (t (%ensure-tensor-read-write t-spec)))))

         (all-grad-out-params (append rec-grad-out-params non-rec-scalar-in-grad-params))
         (all-grad-out-types (append rec-grad-out-types non-rec-scalar-in-grad-types))
         (out-grads
          (loop for p in outputs
                collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
         ;; Output _GRAD seeds (passed in by caller, parallel to outputs).
         ;; Promote element type to float adjoint when the output is integer-typed.
         (out-grad-types
          (mapcar (lambda (t-spec) (%promote-to-float-adjoint t-spec)) output-types))
         (bwd-params (append flat-inputs outputs out-grads
                       (when all-grad-out-params (list '&out))
                       all-grad-out-params))
         (bwd-types (append flat-input-types output-types out-grad-types
                      (when all-grad-out-params (list '&out))
                      all-grad-out-types))

         ;; diff-flat-inputs: only float scalars and tensors — integers excluded.
         (diff-flat-inputs
          (loop for p in flat-inputs
                for t-spec in flat-input-types
                  when (if (member p record-exploded-syms :test #'eq)
                           (%crisp-float-type-p t-spec)
                           (funcall differentiable-non-rec-p t-spec))
                collect p))
         (diff-flat-input-types
          (loop for p in flat-inputs
                for t-spec in flat-input-types
                  when (if (member p record-exploded-syms :test #'eq)
                           (%crisp-float-type-p t-spec)
                           (funcall differentiable-non-rec-p t-spec))
                collect t-spec)))
    (values bwd-params bwd-types diff-flat-inputs diff-flat-input-types)))


;;; ======================================================================
;;; Endeavour 163 path (a), part 2 — the _ADJ SLM TILES accumulate in fp32 too.
;;;
;;; Promoting the kernel-boundary _GRAD slots (part 1) was necessary but NOT sufficient: the
;;; metadata showed a_grad / b_grad correctly `tensor float 2`, while the SPIR-V still declared
;;; SPV_EXT_shader_atomic_float16_add and its AtomicFAddEXT ops still had result type
;;; `TypeFloat 502 16`.  The remaining half atomics were on the OPERAND ADJOINT tiles
;;; (a-tile_adj / b-tile_adj, `tensor half 2 :local`), which accumulate gradient contributions
;;; in shared memory before the scatter.
;;;
;;; %promote-scratch-init-for-ad promoted INTEGER elements only ("ulong -> double") and passed
;;; every float element through, silently including half and bfloat16 -- the exact same omission
;;; %compute-backward-kernel-params had.  Same rule, same fix: an adjoint of a 16-bit value
;;; accumulates in fp32.
;;;
;;; WHY THIS DOES NOT UNDO DEFECT C.  An operand ADJOINT is never an MMA operand.  Per
;;; %mma-ad-adj-init's own contract, every consumer indexes it as MEMORY: the scalar lowering
;;; writes it with workgroup-stride, the MMA fast path uses it as a store-tile DESTINATION, and
;;; %load-tile-at-bwd reads it element-wise to scatter into the global gradient.  The tiles that
;;; ARE MMA operands -- dC / A^T / B^T -- are minted directly by %mma-via-tile-backward from the
;;; forward tile's element type and never pass through here, so they stay 16-bit and the backward
;;; still issues 16-bit MMA.
;;;
;;; Unchanged for every fp32/tf32 kernel: a float element is not narrow, so promoted-elem is
;;; what it always was.
;;; ======================================================================

;; src/autodiff.lisp
(defun %promote-scratch-init-for-ad (init)
  "Promotes the type in a make-scratch-* form to its float adjoint equivalent.
   E.g., (make-scratch-vector ulong 4) -> (make-scratch-vector double 4).

   Endeavour 163 path (a): a 16-BIT FLOAT element promotes to FLOAT for the same reason an
   integer one does -- an adjoint accumulates many contributions and must not do so in fp16.
   It is also what makes the gradient scatter an fp32 atomic, which is the only kind BMG's
   SPIR-V reader will load."
  (let* ((op (car init))
         (args (cdr init))
         (canonical (%scratch-tensor-canonical-spec op args))
         (elem-type (second canonical))
         (promoted-elem (cond
                          ((%crisp-integer-scalar-type-p elem-type)
                           (%integer-scalar-to-float-scalar elem-type))
                          ((%crisp-narrow-float-scalar-p elem-type) 'float)
                          (t elem-type))))
    (cond
     ((or (string-equal (symbol-name op) "MAKE-SCRATCH-VECTOR")
          (string-equal (symbol-name op) "MAKE-SCRATCH-MATRIX"))
      (let ((size-expr (%extract-scratch-size-expr op args)))
        `(,op ,promoted-elem ,size-expr ,@(cddr args))))
     ((string-equal (symbol-name op) "MAKE-SCRATCH-TENSOR")
      (let ((size-expr (%extract-scratch-size-expr op args))
            (n (third canonical)))
        `(,op ,promoted-elem ,n ,size-expr ,@(if (%has-explicit-n args) (cdddr args) (cddr args)))))
     ((string-equal (symbol-name op) "MAKE-SCRATCH-CELL")
      `(,op ,(%promote-to-float-adjoint canonical)))
     (t init))))

;;; ======================================================================
;;; BUG 057 — load-tile-at across an ELEMENT-TYPE mismatch is now REFUSED.
;;;
;;; It used to compile clean and corrupt memory: staging a `float` global into a `half` scratch
;;; tile emitted NO fptrunc and NOT ONE `store half` -- only `store float ... ptr addrspace(3)`,
;;; i.e. 4-byte values written into a 2-byte-element SLM tile, overrunning it by 2x while every
;;; element after the first sat at the wrong offset.  The coop-matrix types in the same module
;;; were half, so the MMA then read packed-half lanes out of float bit patterns.  Observed via
;;; VERIFY-AUTODIFF as analytical=30.87 / numerical=0.0 against an expected 1.2.
;;;
;;; REFUSED RATHER THAN CONVERTED, deliberately.  Emitting an implicit fptrunc here would bury
;;; per-element cast instructions inside a bulk staging loop that exists to be fast -- the one
;;; place in a GPU kernel where hidden work is least acceptable -- and it would silently change
;;; the numerics of a load the user believes is a copy.  Crisp already prefers a compile-time
;;; refusal to a helpful guess (see BUG 035, and 161's wgmma operand-shape refusal).  If a user
;;; genuinely wants a narrowing stage, they can write it explicitly with workgroup-stride and a
;;; cast, where the cost is visible in the source.
;;;
;;; SCOPED NARROW ON PURPOSE.  The check fires only when BOTH operands resolve to TENSOR types
;;; through a pure env lookup (find-variable-in-env / parameter-def-type -- no re-analysis, so
;;; no risk of duplicating a sub-expression's side effects).  A register tile, a view form like
;;; (ring-get R i), or anything whose type does not canonicalize to a tensor is left alone: this
;;; is a refusal being added to a green 1061-spec suite, and a false refusal is worse than a
;;; missed one.  The register-tile path is therefore still unguarded; noted in bugs.md.
;;; ======================================================================

;; src/analysis/control.lisp
(defun %tlc-tensor-elem-of (type-spec)
  "The ELEMENT type of a tensor-shaped TYPE-SPEC, or NIL if it is not one.
   Tolerant by design: anything that does not canonicalize to a (tensor ELEM ...) form answers
   NIL, which makes the caller skip its check rather than guess."
  (let ((canon (ignore-errors (canonicalize-type-specifier type-spec))))
    (and (consp canon)
         (symbolp (first canon))
         (string-equal (symbol-name (first canon)) "TENSOR")
         (second canon))))

;; src/analysis/control.lisp
(defun %tlc-check-elem-match (src tile env op-name location)
  "BUG 057: refuse a tile-staging op whose SOURCE and DESTINATION element types differ.

   Both operands are resolved by a pure environment lookup, so this never re-analyses a
   sub-expression.  The check is SKIPPED unless both sides are symbols bound in ENV whose types
   canonicalize to tensors -- see the header for why that conservatism is deliberate."
  (when (and (symbolp src) (symbolp tile))
    (let* ((src-pd  (find-variable-in-env src env))
           (tile-pd (find-variable-in-env tile env)))
      (when (and src-pd tile-pd)
        (let ((src-elem  (%tlc-tensor-elem-of (parameter-def-type src-pd)))
              (tile-elem (%tlc-tensor-elem-of (parameter-def-type tile-pd))))
          (when (and src-elem tile-elem
                     (not (eq src-elem tile-elem))
                     (not (types-equivalent-p src-elem tile-elem)))
            (error 'crisp-compiler-error
              :message (format nil "~a: element type mismatch — source ~a holds ~a but tile ~a holds ~a.  A tile stage is a COPY, not a conversion: it would write ~a-sized values into a ~a-sized buffer.  Give the tile the source's element type, or stage the conversion explicitly (workgroup-stride + a cast) so its cost is visible."
                               op-name src src-elem tile tile-elem src-elem tile-elem)
              :source-location location)))))))

;; src/analysis/control.lisp
(defun analyze-load-tile-at-expression (expr env context location)
  "Analyzer for (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose barrier).
   Rejects placement inside a thread-divergent conditional. If :barrier is provided
   and target is :ptx, emits semantic-nvvm-cp-async-tile-copy. Otherwise, delegates
   codegen via %expand-load-tile-at-form."
  ;; Endeavor 139: inside a warp-spec block, %warp-spec-check-block-only (after mode resolution)
  ;; governs instead of the thread-divergent check.
  (unless *in-warp-spec-block* (%tlc-check-not-divergent "load-tile-at" location))
  (%tlc-check-elem-match (second expr) (third expr) env "load-tile-at" location)
  (let* ((key-args (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil)))
    (when (and (getf key-args :barrier) (getf key-args :transformF))
       (error 'crisp-compiler-error :message "Cannot use :barrier and :transformF together" :source-location location))
    ;; Endeavor 137: the barrier's :mode (looked up via its binding) picks the lowering.
    (let ((mode (and barrier-form (async-barrier-mode-of barrier-form))))
      (%warp-spec-check-block-only "load-tile" mode location)
      (cond
        ;; :block on PTX (Chapter 1.5, Phase 2) — NVIDIA TMA: one bulk descriptor-driven copy
        ;; (cp.async.bulk.tensor...mbarrier::complete_tx::bytes) issued by an elected leader,
        ;; tracked by the barrier's SLM mbarrier.  Arch (sm_90+) already gated at barrier parse.
        ((and barrier-form (eq mode :block) (eq *target-backend* :ptx))
         (%analyze-nvvm-tma-load-tile-at expr env context location))
        ;; :block on any other target (the GENERIC compile-check pass; SPV is rejected at
        ;; barrier parse) — fall to the sync staging so the kernel still compiles + runs
        ;; correctly (just not block-optimized).
        ((and barrier-form (eq mode :block))
         (analyze-expression (%expand-load-tile-at-form expr location)
                             env context location))
        ((and barrier-form (eq mode :linear) (eq *target-backend* :ptx))
         ;; Endeavor 136 (Chapter 1): cooperative cp.async copy + commit_group.
         (analyze-expression (%expand-async-load-tile-at-form expr location)
                             env context location))
        ((and barrier-form (eq mode :linear) (eq *target-backend* :spirv)
              (<= (length (fourth expr)) 2))
         ;; Endeavor 136 (Chapter 1, SPV): 1D -> one OpGroupAsyncCopy; 2D -> per-row.
         (analyze-expression (%expand-spirv-async-load-tile-at-form expr location)
                             env context location))
        (t
         (analyze-expression (%expand-load-tile-at-form expr location)
                             env context location))))))

;;; Endeavour 152: this function was an OVERLAY WRAPPER around the original definition,
;;; captured with (fdefinition ...) at load time.  That trick cannot survive the move into
;;; src -- the capture would find the wrapper itself.  The original body is preserved
;;; verbatim as %analyze-nvvm-tma-load-tile-at-base, and the wrapper below calls it directly.




;; src/analysis/control.lisp  (163 — temporary instrumentation on the BUG 057 check)
(defun %tlc-check-elem-match (src tile env op-name location)
  "BUG 057 refusal, instrumented.  See the header above for the contract."
  (log:info "057-check: op=~a src=~a (sym=~a) tile=~a (sym=~a)"
            op-name src (symbolp src) tile (symbolp tile))
  (when (and (symbolp src) (symbolp tile))
    (let* ((src-pd  (find-variable-in-env src env))
           (tile-pd (find-variable-in-env tile env)))
      (log:info "057-check: src-pd=~a tile-pd=~a" (and src-pd t) (and tile-pd t))
      (when (and src-pd tile-pd)
        (let ((src-ty  (parameter-def-type src-pd))
              (tile-ty (parameter-def-type tile-pd)))
          (log:info "057-check: src-ty=~s tile-ty=~s" src-ty tile-ty)
          (let ((src-elem  (%tlc-tensor-elem-of src-ty))
                (tile-elem (%tlc-tensor-elem-of tile-ty)))
            (log:info "057-check: src-elem=~a tile-elem=~a" src-elem tile-elem)
            (when (and src-elem tile-elem
                       (not (eq src-elem tile-elem))
                       (not (types-equivalent-p src-elem tile-elem)))
              (error 'crisp-compiler-error
                :message (format nil "~a: element type mismatch — source ~a holds ~a but tile ~a holds ~a.  A tile stage is a COPY, not a conversion: it would write ~a-sized values into a ~a-sized buffer.  Give the tile the source's element type, or stage the conversion explicitly (workgroup-stride + a cast) so its cost is visible."
                                 op-name src src-elem tile tile-elem src-elem tile-elem)
                :source-location location))))))))

;; src/analysis/control.lisp
;; BUG 057, final form.  The first cut used a hand-rolled canonicalize + (tensor ELEM ...) match
;; and never fired: a KERNEL PARAM's type is not a list at all, it is the generated record name
;; TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, while the let-bound tile's type IS a (TENSOR ...) list.
;; get-array-element-type already handles BOTH -- it unmangles the template-struct name -- so it
;; replaces the bespoke extractor rather than teaching a second thing the same trick.
(defun %tlc-check-elem-match (src tile env op-name location)
  "BUG 057: refuse a tile-staging op whose SOURCE and DESTINATION element types differ.

   A tile stage is a COPY.  Staging a `float` global into a `half` tile emitted no fptrunc and
   no `store half`, only `store float ... ptr addrspace(3)` -- 4-byte values into a
   2-byte-element SLM tile, overrunning it 2x with every element past the first at the wrong
   offset.  It compiled clean and corrupted memory.

   Refused rather than converted: an implicit fptrunc would put per-element casts inside a bulk
   staging loop whose entire purpose is speed, and would silently change the numerics of a load
   the user reads as a copy.

   Both types come from a pure environment lookup, so no sub-expression is re-analysed and no
   side effect is duplicated.  Skipped whenever either side's element type cannot be determined,
   which keeps a false refusal off kernels this was never about."
  (when (and (symbolp src) (symbolp tile))
    (let ((src-pd  (find-variable-in-env src env))
          (tile-pd (find-variable-in-env tile env)))
      (when (and src-pd tile-pd)
        (let ((src-elem  (get-array-element-type (parameter-def-type src-pd)))
              (tile-elem (get-array-element-type (parameter-def-type tile-pd))))
          (log:debug "057 elem-check ~a: ~a=~a vs ~a=~a" op-name src src-elem tile tile-elem)
          (when (and src-elem tile-elem
                     (not (eq src-elem tile-elem))
                     (not (ignore-errors (types-equivalent-p src-elem tile-elem))))
            (error 'crisp-compiler-error
              :message (format nil "~a: element type mismatch — source ~a holds ~a but tile ~a holds ~a.  A tile stage is a COPY, not a conversion: it would write ~a-sized values into a ~a-sized buffer.  Give the tile the source's element type, or stage the conversion explicitly (workgroup-stride + a cast) so its cost is visible."
                               op-name src src-elem tile tile-elem src-elem tile-elem)
              :source-location location)))))))

;;; ======================================================================
;;; Endeavour 163 defect B, part 1 (B2) — %ad-tile-base did not see through an ANF TEMP.
;;;
;;; SYMPTOM.  154/03 refused with
;;;     cannot differentiate this tile multiply — the A operand %ANF-T-42 has no compile-time shape
;;; even though the operand's shape is right there in the binding:
;;;     (A1-ring (make-scratch-matrix-ring float (64 32) :ring-count 2))
;;;
;;; MEASURED CAUSE.  ANF hoists the view out of the wgmma call, so the operand reaching the VJP
;;; is not `(ring-get A1-RING SLOT)` but a temp bound to it:
;;;     (%ANF-T-42 (RING-GET A1-RING SLOT))            <- read out of the debug ANF
;;; %ad-tile-base resolves a RING-GET FORM to its ring, and returns a SYMBOL unchanged — so the
;;; temp resolved to itself, missed the dims map, and the VJP concluded "no compile-time shape".
;;;
;;; THE FIX IS ALREADY IN THE FILE, WHICH IS THE SECOND TIME THIS ENDEAVOUR.  *ad-view-alias-map*
;;; exists for exactly this hoist and documents it in its own docstring; %ad-resolve-view-alias
;;; reads it; %tlc-bwd-adj-name already consults it for ADJOINT naming.  Only the SHAPE/staging
;;; resolver did not.  Same shape as defect A: the helper existed and one consumer never called
;;; it.
;;;
;;; NOT a new derivative and not a ring rule — the ring's own dims were always recorded
;;; (%mma-ad-tile-dims-map has known MAKE-SCRATCH-MATRIX-RING since 138).  This is a lookup that
;;; failed to follow one alias.
;;;
;;; DOES NOT ADDRESS B1 (140/01, 140/02), which is a different cause in the same defect: there
;;; the operand is a flat `(make-scratch-vector float 512)` and NO 2-D shape is recorded
;;; anywhere, so there is nothing for an alias to resolve to.  That one needs the shape taken
;;; from the tile-multiply's own (M N K) instead, and is handled separately.
;;; ======================================================================

;; src/autodiff.lisp
(defun %ad-tile-base (op)
  "The underlying tile SYMBOL of a tile operand: itself if a symbol, the ring if a
   `(ring-get RING i)` view.  Shape and staging questions are asked of the base — every slot of
   a ring has the ring's element shape — while ADJOINT questions keep the view (see
   %tlc-bwd-adj-name), because slot i's adjoint is slot i of the adjoint ring, not the whole
   ring.

   Endeavour 163 defect B2: a SYMBOL is first resolved through *ad-view-alias-map*, because ANF
   hoists a view into a temp — `(%ANF-T-42 (RING-GET A1-RING SLOT))` — and the operand reaching
   the VJP is then that temp.  A symbol with no alias still answers itself, so an ordinary tile
   is unaffected."
  (cond
    ((and (symbolp op) (%ad-resolve-view-alias op))
      (%ad-tile-base (%ad-resolve-view-alias op)))
    ((symbolp op) op)
    ((and (consp op) (symbolp (car op))
          (string-equal (symbol-name (car op)) "RING-GET"))
      (%ad-tile-base (second op)))
    (t nil)))

;;; ======================================================================
;;; Endeavour 163 defect B, part 2 — the operand RESOLVER did not see through an ANF alias.
;;;
;;; %mma-vjp-operand-ref already knows how to resolve a RING operand: it looks the ring up in
;;; %ad-ring-load-sites and reconciles the stage origin.  Its ring branch is gated on
;;; `(consp op)` — an actual `(ring-get R i)` FORM.  But ANF hoists the view, so in a realistic
;;; pipelined kernel the operand arriving here is a TEMP:
;;;
;;;     (%ANF-T-42 (RING-GET A1-RING SLOT))
;;;
;;; A symbol takes the non-ring branch, finds nothing, and declines — which is what made 154/03
;;; report "no compile-time shape" even though the ring's dims and every load site were recorded.
;;;
;;; THE FIX IS ONE LINE OF RESOLUTION, NOT A NEW RULE.  Canonicalise the operand through
;;; *ad-view-alias-map* on entry, so a temp bound to a view becomes that view and the EXISTING
;;; ring branch — including `(third op)` for the slot index — applies unchanged.
;;;
;;; This is the "strip the ring context" guardrail, not reverse-ring logic: nothing here teaches
;;; AD to invert a ring.  It teaches the resolver to answer the two questions it was always
;;; asking — WHAT SHAPE and FROM WHERE — for an operand whose spelling ANF happened to change.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-vjp-operand-ref (op src-map dims-map inputs &optional ring-sites)
  "Resolve an mma-accumulate-via-tile operand to (values SRC OY OX KIND).

     - STAGED  : a scratch tile filled by load-tile-at.  SRC is the ORIGINAL global matrix and
                 (OY OX) the staging origin.
     - DIRECT  : the operand IS a global matrix (a kernel parameter read straight by the
                 fragment loads, as in 132/04-mma-via-tile).  Origin (0 0).
     - :RING   : a `(ring-get R i)` view.  SRC is the single global matrix every load site names;
                 the origin is those sites' agreed components with the stage component replaced
                 by the CONSUMING loop variable (see %ad-reconcile-ring-origin).  A pipelined
                 ring's own load sites record OTHER stages' origins, which is exactly what made
                 this look undifferentiable.

   RING-SITES is the %ad-ring-load-sites alist, threaded from the caller because it needs
   flat-anf.  Absent, ring operands decline, which is the previous behaviour.

   Endeavour 163 defect B: OP is first canonicalised through *ad-view-alias-map*, because ANF
   hoists a view into a temp and the operand reaching a realistic pipelined kernel's VJP is that
   temp rather than the view.  A symbol with no alias is unchanged, so every non-ring operand
   resolves exactly as before."
  (let* ((op   (or (%ad-resolve-view-alias op) op))
         (base (%ad-tile-base op)))
    (cond
      ((and (consp op) base)
        (let ((sites (cdr (assoc base ring-sites))))
          (if (null sites)
              (values nil nil nil nil)
              (multiple-value-bind (src origin)
                  (%ad-reconcile-ring-origin sites (first *ad-loop-vars*) (third op))
                (if (and src origin (= (length origin) 2))
                    (values src (first origin) (second origin) :ring)
                    (values nil nil nil nil))))))
      (t
        (let ((entry (assoc op src-map)))
          (cond
            (entry (values (second entry) (first (third entry)) (second (third entry)) :staged))
            ((and (symbolp op) (member op inputs)) (values op 0 0 :direct))
            ((assoc op dims-map) (values op 0 0 :staged))
            (t (values nil nil nil nil))))))))

;;; ======================================================================
;;; Endeavour 163 defect B, part 3 + BUG 044 — THE RING IS STRIPPED, NOT REPLICATED.
;;;
;;; With the two resolvers taught to see through ANF (parts 1 and 2), a ring operand can answer
;;; both questions the tile VJP asks: WHAT SHAPE (via %ad-tile-base -> the ring's own dims) and
;;; FROM WHERE (via %mma-vjp-operand-ref -> %ad-ring-load-sites -> %ad-reconcile-ring-origin).
;;; Two things then stood between it and the ordinary backward:
;;;
;;;   1. %mma-via-tile-backward RE-DERIVED provenance from src-map, which never contains ring
;;;      loads, so it could not see what its own caller had already resolved.  It now accepts the
;;;      resolved (SRC OY OX) per operand and only falls back to src-map when none is supplied —
;;;      so every existing non-ring call is byte-identical.
;;;   2. `ringp` gated the MMA path OFF for any ring operand, forcing the scalar lowering.
;;;      That gate is gone: admissibility is now the only question, which is the real one.
;;;
;;; WHY THIS FIXES BUG 044 AND NOT MERELY B.  The scalar fallback accumulates into the operand
;;; adjoint with `+=` and never resets it, so a ring slot reused across stages carried stage 0 +
;;; stage 2 and both scatter sites dumped the total at their own origin (1.20 + 83.12 = 84.32).
;;; The MMA path OVERWRITES the operand adjoint per stage (`store-tile da-reg a-adj`), so the
;;; aliasing has nothing to accumulate into.  044 is not fixed by teaching AD to invert a ring —
;;; it is fixed by routing rings to the path that never needed the ring in the first place.
;;;
;;; NO REVERSE-RING LOGIC EXISTS ANYWHERE IN THIS CHANGE.  The backward stages its transposes
;;; from the ORIGINAL GLOBAL SOURCE at the consuming stage's origin, exactly as it does for a
;;; plain scratch tile.  Whether the forward used a prologue, double buffering, or a
;;; warp-specialised producer is not represented in the derivative at all.  If the backward
;;; should later be pipelined, that is an optimisation over correct math, not a term in the AD
;;; generator.
;;;
;;; The tile arguments may now be VIEW FORMS rather than symbols, so the symbolp guards ask about
;;; the BASE, and the temp-naming lambda derives its prefix from the base — a `(ring-get R i)`
;;; has no symbol-name.  ADJOINT naming still keeps the VIEW, per %tlc-bwd-adj-name's rule that
;;; slot i's adjoint is slot i of the adjoint ring.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-via-tile-backward (form dims-map src-map inputs outputs local-adj-fn kernel-pkg
                               &optional a-src-in aoy-in aox-in b-src-in boy-in box-in)
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
    (let* ((c-dims (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims (assoc (%ad-tile-base a-tile) dims-map))
           (a-src  (if a-src-in (list a-tile a-src-in (list aoy-in aox-in))
                       (assoc a-tile src-map)))
           (b-src  (if b-src-in (list b-tile b-src-in (list boy-in box-in))
                       (assoc b-tile src-map))))
      (log:debug "145 P3b via-tile bwd: c-tile=~a dims=~a | a-tile=~a dims=~a src=~a | b-tile=~a src=~a"
                 c-tile c-dims a-tile a-dims a-src b-tile b-src)
      (unless (and c-dims a-dims a-src b-src
                   (symbolp (%ad-tile-base c-tile)) (symbolp (%ad-tile-base a-tile))
                   (symbolp (%ad-tile-base b-tile)))
        (error 'crisp-compiler-error
          :message (format nil "mma-accumulate-via-tile: cannot differentiate this tile multiply — ~a.  The backward needs the accumulator tile's (Mt Nt) and the A operand's Kt as COMPILE-TIME shapes, and needs each staged operand's originating global matrix (from its load-tile-at) so it can stage the transpose.  Give the tiles literal make-register-tile / make-scratch-matrix dimensions and stage both operands with load-tile-at."
                           (cond ((not c-dims) (format nil "the accumulator tile ~a has no compile-time (M N)" c-tile))
                                 ((not a-dims) (format nil "the A operand ~a has no compile-time shape" a-tile))
                                 ((not a-src)  (format nil "the A operand ~a was not staged by a load-tile-at" a-tile))
                                 (t            (format nil "the B operand ~a was not staged by a load-tile-at" b-tile))))
          :source-location nil))
      (when (and c-dims a-dims a-src b-src
                 (symbolp (%ad-tile-base c-tile)) (symbolp (%ad-tile-base a-tile))
                   (symbolp (%ad-tile-base b-tile)))
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
               (nm (lambda (fmt sym) (intern (format nil fmt (symbol-name (%ad-tile-base sym))) pkg)))
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

;;; ======================================================================
;;; Endeavour 163 — a 16-BIT kernel's BACKWARD needs SPV_EXT_shader_atomic_float16_add.
;;;
;;; Found while building the on-metal numeric gradient check that BUG 054's own note asked for.
;;; The forward of an fp16 MMA kernel translates fine.  Its BACKWARD does not:
;;;
;;;     RequiresExtension: Feature requires the following SPIR-V extension:
;;;      SPV_EXT_shader_atomic_float16_add            (llvm-spirv exit 18)
;;;
;;; because the gradient SCATTER accumulates into A_GRAD / B_GRAD, and those carry the INPUT's
;;; element type -- half -- so the scatter is a half-typed `atomicrmw fadd`.  The ext list asked
;;; for SPV_EXT_shader_atomic_float_add (fp32) and nothing else, so any 16-bit kernel was
;;; untranslatable under --differentiate.  Verified by hand: adding the extension to the exact
;;; failing invocation translates the same .bc cleanly.
;;;
;;; WHY A TEXT SCAN RATHER THAN A MODULE PREDICATE.  Its siblings (%module-uses-coop-matrix-p,
;;; %module-uses-2d-block-io-p) scan FUNCTION NAMES, which cannot see this: `atomicrmw` is an
;;; INSTRUCTION, not a named builtin call.  A module walk would need LLVMGetFirstBasicBlock /
;;; GetFirstInstruction bindings, none of which exist yet.  %inject-cache-control-decorations
;;; already text-scans the emitted .ll in this very function, so this follows local precedent
;;; instead of adding four bindings for one predicate.  Swap it for a module walk if those
;;; bindings ever land for another reason.
;;;
;;; SCOPED TIGHT: the clause fires only when a half-typed atomic fadd is actually present, so
;;; every fp32 and tf32 module gets byte-identical flags.
;;; ======================================================================

;; src/compiler.lisp

;; src/autodiff.lisp
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B [(acc) BODY...]).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path shape requirements, so they cannot leak back out as a
   language-level contract.

   Endeavor 150: if BODY fuses an activation onto the accum binding with map-elements!, the
   chain rule needs dP = dC * f'(P).  A prefix re-stages the operands from their GLOBAL sources,
   recomputes P into a fresh register tile, and scales the C adjoint through the function's
   _GRAD twin before the existing backward runs.  The forward kernel is untouched."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg))
                     (core (if (%mma-vjp-mma-admissible-p mt nt kt)
                               ;; Endeavour 163: a RING operand no longer forces the scalar
                               ;; fallback.  Its dims resolve through %ad-tile-base and its
                               ;; provenance is passed in from %mma-vjp-operand-ref just above,
                               ;; so by here it is indistinguishable from a staged tile.
                               (%mma-via-tile-backward form dims-map src-map inputs outputs
                                                       local-adj kernel-pkg
                                                       a-src aoy aox b-src boy box)
                               (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                                         a-src aoy aox b-src boy box pkg))))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (multiple-value-bind (acc-sym fn-form) (%vjp-via-tile-body-map form)
                  (if (not acc-sym)
                      core
                      (let* ((cl    (find-package :crisp-language))
                             (grad  (%map-elements-grad-name fn-form pkg))
                             (base  (symbol-name (or (%ad-tile-base c-tile) c-tile)))
                             (p-sym  (intern (format nil "~a_PRIMAL" base) pkg))
                             (ap-sym (intern (format nil "~a_PRIMAL_A" base) pkg))
                             (bp-sym (intern (format nil "~a_PRIMAL_B" base) pkg))
                             (progn-s (intern "PROGN" cl))
                             (let-s   (intern "LET" cl))
                             (mrt-s   (intern "MAKE-REGISTER-TILE" cl))
                             (msm-s   (intern "MAKE-SCRATCH-MATRIX" cl))
                             (lta-s   (intern "LOAD-TILE-AT" cl))
                             (sync-s  (intern "SYNC-WORKGROUP" cl))
                             (flt-s   (intern "FLOAT" cl))
                             (via-s   (intern "MMA-ACCUMULATE-VIA-TILE" cl))
                             (vjp-s   (intern "%MAP-ELEMENTS-VJP!" cl))
                             (fn-s    (intern "FUNCTION" cl)))
                        (unless grad
                          (error 'crisp-compiler-error
                                 :message "map-elements! in a via-tile body: the fused function must be a #'NAME form for its gradient twin to be nameable."
                                 :source-location nil))
                        (log:debug "VJP via-tile: fused activation ~a -> dP = dC * ~a(P, dC); re-staging P from ~a / ~a"
                                   fn-form grad a-src b-src)
                        `(,progn-s
                          (,let-s ((,ap-sym (,msm-s ,flt-s (,mt ,kt)))
                                   (,bp-sym (,msm-s ,flt-s (,kt ,nt)))
                                   (,p-sym  (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                  (,lta-s ,a-src ,ap-sym (,aoy ,aox))
                                  (,lta-s ,b-src ,bp-sym (,boy ,box))
                                  (,sync-s)
                                  (,via-s ,shape ,p-sym ,ap-sym ,bp-sym)
                                  (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                          ,core))))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)

;;; Ring pipelining, part 2 — comparing load-site origins MODULO the slot index.
;;;
;;; The first cut compared origins componentwise and found TWO differing components where there
;;; should be one.  The reason is that `load-tile` is rewritten to `load-tile-at` with PIXEL
;;; coordinates, and that rewrite embeds the tile expression itself:
;;;
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring (to-ulong i))) 0))   ; prologue
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring slot))        0))   ; steady state
;;;
;;; so the SLOT INDEX makes every component differ, including the ones that agree
;;; mathematically.  The slot is scheduling, exactly like the stage origin, so it is normalised
;;; away before comparing and substituted back afterwards from the CONSUMING operand's own
;;; index.  What remains differing is then the genuine stage coordinate, and there is one.
(defvar *ad-ring-slot-marker* '%ad-ring-slot
  "Placeholder standing in for a ring-get index while load-site origins are compared.")


;;; ======================================================================
;;; BUG 044 — AN ADJOINT MUST BELONG TO THE STAGE, NOT TO THE BUFFER.
;;;
;;; 145/19 reported analytical=84.32 against an expected 1.2.  Decomposed, that is stage 0's
;;; contribution (1.20) plus stage 2's (83.12) — the two stages that SHARE ring slot 0 — while
;;; stage 1 (42.16, the only stage on slot 1) was absent.  Every digit accounted for.
;;;
;;; WHY THE OBVIOUS FIXES DO NOT WORK, both established by measurement rather than argument:
;;;
;;;   * Routing rings to the MMA path (which OVERWRITES the operand adjoint) does not reach this
;;;     kernel.  145/19 is Mt=8 Nt=16 Kt=8, and %mma-vjp-mma-admissible-p needs
;;;     `kt mod lcm(sm sn) = 0` — on BMG that is 8 mod 16.  It takes the scalar lowering for a
;;;     SHAPE reason and would do so with no ring in the kernel at all.
;;;   * A consume-and-reset at the load site cannot work either.  The backward reverses each loop
;;;     BODY but iterates the loop in FORWARD order, and 145/19's refill is LAST in the forward
;;;     body, so the backward's scatter at iteration k would have to emit stage k+2's gradient —
;;;     two stages before it exists.  No placement of a zeroing repairs a pairing off by two.
;;;
;;; THE ACTUAL RULE.  The scalar lowering accumulated `+=` into the OPERAND ADJOINT, which is a
;;; property of the BUFFER.  When the buffer is reused, that is the wrong home for a per-stage
;;; quantity.  For a ring operand the lowering now accumulates the stage's contribution in a
;;; LOCAL and scatters it with atomic-add! straight into the GLOBAL gradient at this stage's
;;; origin — an origin %ad-reconcile-ring-origin already resolves to the CONSUMING loop variable
;;; rather than the prefetching one.  The slot adjoint is then never written, the load-site
;;; scatter contributes zero, and iteration order stops mattering.
;;;
;;; NO REVERSE-RING LOGIC.  Nothing here inverts a ring, mirrors a prologue, or models double
;;; buffering.  The derivative simply stops storing anything in a buffer whose lifetime the
;;; forward chose for reasons of latency.
;;;
;;; STRICTLY OPT-IN: both new arguments default to NIL, and NIL reproduces the previous emission
;;; exactly, so every non-ring use of the scalar lowering is byte-identical.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg
                                 &optional a-grad b-grad)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT."
  (declare (ignore a-op b-op))
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         (flt  (intern "FLOAT" cl))    (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         (dc   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg))
         (aadd (intern "ATOMIC-ADD!" cl))  (letf (intern "LET" cl))
         (acc  (intern "%VJP_ACC" cl))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl)))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (list (list dc (list msm flt (list mt nt))))
            (list st c-adj dc (list 0 0))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            ;; A-GRAD given => the operand is a REUSED buffer (a ring slot).  Accumulate the
            ;; stage's contribution in a LOCAL and scatter it straight into the global gradient
            ;; at this stage's origin, so nothing is ever left in the shared slot to be picked
            ;; up by another stage.  See BUG 044.
            (if a-grad
                (list ws a-adj (list m k)
                      (list letf (list (list acc 0.0))
                            (list dt (list n nt)
                                  (list set! acc
                                        (list plus acc
                                              (list mul (list aref dc m n)
                                                    (list aref b-src (ix boy k) (ix box n))))))
                            (list aadd (list aref a-grad (ix aoy m) (ix aox k)) acc)))
                (list ws a-adj (list m k)
                      (list dt (list n nt)
                            (list set! (list aref a-adj m k)
                                  (list plus (list aref a-adj m k)
                                        (list mul (list aref dc m n)
                                              (list aref b-src (ix boy k) (ix box n)))))))) 
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]   (same reuse rule as dA above)
            (if b-grad
                (list ws b-adj (list k n)
                      (list letf (list (list acc 0.0))
                            (list dt (list m mt)
                                  (list set! acc
                                        (list plus acc
                                              (list mul (list aref a-src (ix aoy m) (ix aox k))
                                                    (list aref dc m n)))))
                            (list aadd (list aref b-grad (ix boy k) (ix box n)) acc)))
                (list ws b-adj (list k n)
                      (list dt (list m mt)
                            (list set! (list aref b-adj k n)
                                  (list plus (list aref b-adj k n)
                                        (list mul (list aref a-src (ix aoy m) (ix aox k))
                                              (list aref dc m n)))))))
            (list sync)))))


;; src/autodiff.lisp
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B [(acc) BODY...]).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path shape requirements, so they cannot leak back out as a
   language-level contract.

   Endeavor 150: if BODY fuses an activation onto the accum binding with map-elements!, the
   chain rule needs dP = dC * f'(P).  A prefix re-stages the operands from their GLOBAL sources,
   recomputes P into a fresh register tile, and scales the C adjoint through the function's
   _GRAD twin before the existing backward runs.  The forward kernel is untouched."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg))
                     (core (if (and (not ringp) (%mma-vjp-mma-admissible-p mt nt kt))
                               (%mma-via-tile-backward form dims-map src-map inputs outputs
                                                       local-adj kernel-pkg)
                               (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                                         a-src aoy aox b-src boy box pkg
                                                         ;; BUG 044: a RING slot is reused across
                                                         ;; stages, so its adjoint cannot hold a
                                                         ;; per-stage value.  Hand the lowering
                                                         ;; the GLOBAL gradient and let it scatter
                                                         ;; each stage straight there.
                                                         (when (eq a-kind :ring)
                                                           (%tlc-bwd-adj-name a-src inputs outputs
                                                                              local-adj kernel-pkg))
                                                         (when (eq b-kind :ring)
                                                           (%tlc-bwd-adj-name b-src inputs outputs
                                                                              local-adj kernel-pkg))))))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (multiple-value-bind (acc-sym fn-form) (%vjp-via-tile-body-map form)
                  (if (not acc-sym)
                      core
                      (let* ((cl    (find-package :crisp-language))
                             (grad  (%map-elements-grad-name fn-form pkg))
                             (base  (symbol-name (or (%ad-tile-base c-tile) c-tile)))
                             (p-sym  (intern (format nil "~a_PRIMAL" base) pkg))
                             (ap-sym (intern (format nil "~a_PRIMAL_A" base) pkg))
                             (bp-sym (intern (format nil "~a_PRIMAL_B" base) pkg))
                             (progn-s (intern "PROGN" cl))
                             (let-s   (intern "LET" cl))
                             (mrt-s   (intern "MAKE-REGISTER-TILE" cl))
                             (msm-s   (intern "MAKE-SCRATCH-MATRIX" cl))
                             (lta-s   (intern "LOAD-TILE-AT" cl))
                             (sync-s  (intern "SYNC-WORKGROUP" cl))
                             (flt-s   (intern "FLOAT" cl))
                             (via-s   (intern "MMA-ACCUMULATE-VIA-TILE" cl))
                             (vjp-s   (intern "%MAP-ELEMENTS-VJP!" cl))
                             (fn-s    (intern "FUNCTION" cl)))
                        (unless grad
                          (error 'crisp-compiler-error
                                 :message "map-elements! in a via-tile body: the fused function must be a #'NAME form for its gradient twin to be nameable."
                                 :source-location nil))
                        (log:debug "VJP via-tile: fused activation ~a -> dP = dC * ~a(P, dC); re-staging P from ~a / ~a"
                                   fn-form grad a-src b-src)
                        `(,progn-s
                          (,let-s ((,ap-sym (,msm-s ,flt-s (,mt ,kt)))
                                   (,bp-sym (,msm-s ,flt-s (,kt ,nt)))
                                   (,p-sym  (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                  (,lta-s ,a-src ,ap-sym (,aoy ,aox))
                                  (,lta-s ,b-src ,bp-sym (,boy ,box))
                                  (,sync-s)
                                  (,via-s ,shape ,p-sym ,ap-sym ,bp-sym)
                                  (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                          ,core))))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)

;;; Ring pipelining, part 2 — comparing load-site origins MODULO the slot index.
;;;
;;; The first cut compared origins componentwise and found TWO differing components where there
;;; should be one.  The reason is that `load-tile` is rewritten to `load-tile-at` with PIXEL
;;; coordinates, and that rewrite embeds the tile expression itself:
;;;
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring (to-ulong i))) 0))   ; prologue
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring slot))        0))   ; steady state
;;;
;;; so the SLOT INDEX makes every component differ, including the ones that agree
;;; mathematically.  The slot is scheduling, exactly like the stage origin, so it is normalised
;;; away before comparing and substituted back afterwards from the CONSUMING operand's own
;;; index.  What remains differing is then the genuine stage coordinate, and there is one.
(defvar *ad-ring-slot-marker* '%ad-ring-slot
  "Placeholder standing in for a ring-get index while load-site origins are compared.")


;;; ======================================================================
;;; Endeavour 163 — AN OVERSIZED MMA ACCUMULATOR GETS AN SLM ADJOINT, NOT A REGISTER ONE.
;;;
;;; 154/03 stopped failing on shape resolution and started failing on arithmetic:
;;;
;;;     make-register-tile: a 64x256 accumulator tile needs 512 registers/thread
;;;     (128 fragments x 4 regs), exceeding the register budget of 255
;;;
;;; %ad-canonicalize-wgmma rewrites `(make-wgmma-accumulator float (64 256) 0.0)` into a sync-MMA
;;; `(make-register-tile float (64 256) 0.0)`.  A wgmma accumulator is WARPGROUP-wide — 128
;;; threads — while a sync register tile is per-warp, so a shape that fits the forward cannot fit
;;; the backward's register model.  The adjoint inherits the shape and the fit check refuses it.
;;;
;;; THE FORWARD KEEPS ITS ACCUMULATOR IN REGISTERS BECAUSE THAT IS WHERE THE SPEED IS.  The
;;; backward has no such need: the VJP stages dC into SLM immediately in both lowerings.  The
;;; register tile existed only because the canonicalisation replicated the forward's STORAGE
;;; choice along with its math — the same replication-instead-of-abstraction that BUG 044 turned
;;; out to be, one level up at the accumulator instead of the operand.
;;;
;;; TWO DECISIONS THAT MUST AGREE, so both now ask ONE predicate:
;;;   - %mma-ad-adj-init mints the adjoint: SLM when the accumulator does not fit.
;;;   - %mma-ad-register-accumulator-tile-p gates the walk's %load-register-tile-acc seeding.
;;;     That is a REGISTER operation and cannot address an SLM adjoint — exactly the
;;;     "Unsupported form '%LOAD-REGISTER-TILE-ACC'" failure endeavour 146 documented when the
;;;     two disagreed.  Answering NIL routes the store backward to the ordinary memory-shaped
;;;     %store-tile-at-bwd, which is what an SLM adjoint wants.
;;;
;;; BLAST RADIUS IS EXACTLY THE CASE THAT WAS BROKEN.  The fit check is SKIPPED on :spirv — there
;;; the tile is opaque cooperative matrices and the driver owns residency — so every BMG spec,
;;; including all 25 on-metal gradient checks, is byte-identical.  On PTX only an accumulator
;;; that ALREADY could not be built is affected.
;;; ======================================================================

;; src/autodiff.lisp
(defun %mma-ad-accumulator-fits-registers-p (dims)
  "T when an (M N) accumulator tile fits the per-thread register budget, so its ADJOINT can be a
   register tile rather than SLM.

   Mirrors %register-tile-fit-check's arithmetic — (M/16)x(N/8) fragments at 4 fp32 regs each —
   but ANSWERS rather than signals, because this is a representation choice and not a user error.
   Like that check it is vacuously true on :spirv, where the driver owns register residency.

   A non-literal or unknown shape answers T, preserving the previous behaviour for anything this
   cannot reason about."
  (or (eq *target-backend* :spirv)
      (let ((m (first dims)) (n (second dims)))
        (or (not (and (integerp m) (integerp n)))
            (<= (* (floor m 16) (floor n 8) 4)
                (or (%hp-registers-per-thread-default)
                    *default-max-registers-per-thread*))))))

;; src/autodiff.lisp
(defun %mma-ad-adj-init (init-form)
  "Endeavor 145 P3b: the adjoint allocator paired with a forward tile binding.

   Scratch tiles keep the existing behaviour (%promote-scratch-init-for-ad, which also
   promotes e.g. ulong -> double).

   Endeavor 146 Gap 4: a register tile's adjoint depends on WHICH ROLE the tile plays.

     ACCUMULATOR  (no :operand)  -> a same-shaped register tile zeroed to 0.0.
        The C adjoint is filled by %load-register-tile-acc from C_GRAD and then staged
        to SLM by the VJP itself, so registers are right for it.

     OPERAND      (:operand :a/:b) -> a same-shaped SCRATCH MATRIX.
        EVERY consumer of an operand adjoint indexes it as memory: the scalar lowering
        writes it with workgroup-stride + ~, the MMA fast path uses it as a store-tile
        DESTINATION, and %load-tile-at-bwd reads it element-wise to scatter into the
        global gradient.  A register tile cannot be written element-wise at all —
        %explode-register-tiles has replaced the whole-tile symbol with per-lane
        fragment vars by then, so `(~ TILE m k)` has no TILE to resolve.  This is not
        an AD-specific fact: the same write fails in a forward-only kernel.

   145 never hit this because its specs staged operands through make-scratch-matrix +
   load-tile-at, so operand adjoints were ALREADY scratch.  142 Phase A introduced
   register-resident operands via the load-tile overload, and this allocator had never
   learned about them.

   NOT a new derivative: dA = dC.B^T and dB = A^T.dC are unchanged and both lowerings
   already computed them correctly.  This decides only WHERE the result is allocated.

   Element type is FLOAT in both register cases: fragments are fp32 and an adjoint
   always starts at zero."
  (cond
    ((and (consp init-form) (symbolp (car init-form))
          (string-equal (symbol-name (car init-form)) "MAKE-REGISTER-TILE"))
     (let ((cl-pkg (find-package :crisp-language)))
       (if (or (%mma-ad-register-operand-tile-p init-form)
               ;; Endeavour 163: an accumulator whose shape exceeds the per-thread register
               ;; budget gets an SLM adjoint too.  The FORWARD keeps its accumulator in
               ;; registers because that is where the speed is; the backward has no such need --
               ;; the VJP stages dC into SLM immediately either way.  A wgmma accumulator is the
               ;; case that forced this: it is WARPGROUP-wide, so canonicalising it to a
               ;; per-warp sync-MMA register tile at the SAME shape asks for 512 registers.
               (not (%mma-ad-accumulator-fits-registers-p (third init-form))))
           (list (intern "MAKE-SCRATCH-MATRIX" cl-pkg)
                 (intern "FLOAT" cl-pkg)
                 (third init-form))
           (list (intern "MAKE-REGISTER-TILE" cl-pkg)
                 (intern "FLOAT" cl-pkg)
                 (third init-form)
                 0.0))))
    ;; Endeavor 146: RING constructors pass through UNCHANGED.
    ;;
    ;; %promote-scratch-init-for-ad opens with %scratch-tensor-canonical-spec, which knows
    ;; only the four scratch TILE forms; handed a ring it yields the stub type `(TENSOR FLOAT)`
    ;; and the caller dies with `Invalid incomplete type specifier`.  A ring adjoint needs no
    ;; promotion in any case: it is a ring of the SAME shape, and these are float already.
    ;;
    ;; This was first patched locally inside %ad-ensure-ring-adj-bindings, which fixed the
    ;; top-level-ring path and left this one — %augment-scratch-adj-bindings reaches the same
    ;; allocator for a ring bound in a NESTED let, which is 142/14's shape.  Fixed at the
    ;; allocator instead, so both paths are covered by one rule.
    ((and (consp init-form) (symbolp (car init-form))
          (member (symbol-name (car init-form))
                  '("MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                    "MAKE-SCRATCH-TENSOR-RING" "MAKE-REGISTER-TILE-RING")
                  :test #'string=))
     init-form)
    (t (%promote-scratch-init-for-ad init-form))))


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
   (lambda (init-form)
     (and (not (%mma-ad-register-operand-tile-p init-form))
          ;; Endeavour 163: an accumulator too large for the per-thread register budget gets a
          ;; SLM adjoint (see %mma-ad-adj-init), and %load-register-tile-acc is a REGISTER
          ;; operation that cannot address one.  Answering NIL here routes the store backward to
          ;; the ordinary memory-shaped %store-tile-at-bwd, which is what an SLM adjoint wants.
          ;; The two decisions MUST agree, so both ask this one predicate.
          (%mma-ad-accumulator-fits-registers-p (third init-form))))))

;;; ======================================================================
;;; Endeavour 163 defect D — A DEAD SHAPE TEMP REACHED THE ANALYZER AS A CALL.
;;;
;;;     The value 32 is not of type SYMBOL      (155/03)
;;;     The value 64 is not of type SYMBOL      (154/03)
;;;
;;; Both are TILE DIMENSIONS, and the backtrace named the site exactly:
;;;
;;;     0: (ANALYZE-INCOMPLETE-TYPE-ACCESSOR 32 (32 16) ...)
;;;        :CURRENT-COMPILING-FUNCTION FP16_RING_GRAD  :CURRENT-BINDING-NAME %ANF-T-27
;;;
;;; i.e. the backward contained a LET binding `(%ANF-T-27 (32 16))` and the analyzer read
;;; `(32 16)` as a function call with 32 in head position.
;;;
;;; WHY THE TEMP EXISTS.  ANF hoists a bare list argument because it cannot tell a shape from a
;;; call.  `make-register-tile` is on the ANF converter's opaque-argument list so ITS dims survive
;;; inline, but `make-register-tile-ring` is not — which is why this only ever bit RING kernels.
;;;
;;; WHY IT REACHED THE BACKWARD.  %ad-inline-literal-shape-temps substitutes the literal at every
;;; USE and deliberately leaves the binding alone, on the reasoning its own docstring records:
;;; "Leaving the now-dead binding is harmless: the backward contains only what the walk emits."
;;; **That stopped being true when endeavour 149's PRIMAL REPLAY began replaying the forward's
;;; STATEMENTS, bindings included.**  A pass and a later feature each correct alone, wrong
;;; together — and the note explaining why it was safe is exactly where the assumption was
;;; recorded, which is the argument for writing such notes down.
;;;
;;; THE FIX.  Neutralise the dead binding's VALUE to 0 rather than leaving the shape list in
;;; expression position.  The left-hand side is still not rewritten — that would produce the
;;; malformed `((32 16) (32 16))` the original comment warns about.  The binding is dead BY
;;; CONSTRUCTION: every occurrence of the symbol has just been replaced by the literal.
;;;
;;; Structurally inert for any kernel with no hoisted shape temp, which is every kernel that was
;;; already compiling.
;;; ======================================================================

;; src/autodiff.lisp
(defun %ad-inline-literal-shape-temps (flat-anf)
  "Substitute every ANF temp bound to a literal list of integers with that literal.

   `(%ANF-T-1 (64 64))` makes %ANF-T-1 a SHAPE, not a value -- the AD engine's shape
   maps require literals and a backward cannot reference a forward-only temp.  A
   binding is only inlined when its value is a non-empty list of integers, which no
   call form can be (a call's head is a symbol).

   The temp's OWN binding is left intact -- rewriting its left-hand side would produce
   the malformed `((64 64) (64 64))`.  Leaving the now-dead binding is harmless: the
   backward contains only what the walk emits."
  (let ((map nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form)) (first form)
                  (listp (second form)) (second form)
                  (every #'integerp (second form))
                  (not (assoc (first form) map)))
         (push (cons (first form) (second form)) map))))
    (if (null map)
        flat-anf
        (labels ((walk (f)
                   (cond
                     ((and f (symbolp f))
                      (let ((e (assoc f map))) (if e (cdr e) f)))
                     ((not (consp f)) f)
                     ;; A temp's own binding.  Its left-hand side must NOT be rewritten --
                     ;; that would produce the malformed `((64 64) (64 64))` -- but the VALUE
                     ;; is neutralised to 0.  Endeavour 163 defect D: leaving the dead binding
                     ;; intact stopped being harmless when endeavour 149's PRIMAL REPLAY began
                     ;; replaying the forward's STATEMENTS, bindings included.  The dead
                     ;; `(%ANF-T-27 (32 16))` then reached the analyzer, which read `(32 16)`
                     ;; as a CALL with 32 in head position:
                     ;;     The value 32 is not of type SYMBOL
                     ;; The binding is dead BY CONSTRUCTION -- every occurrence of the symbol
                     ;; has just been substituted with the literal -- so 0 is safe and keeps
                     ;; the binding-list shape the walk expects.
                     ((and (= (length f) 2) (symbolp (first f)) (first f)
                           (assoc (first f) map))
                      (list (first f) 0))
                     (t (mapcar #'walk f)))))
          (mapcar #'walk flat-anf)))))


;; src/autodiff.lisp  (163 defect D — QUOTE must not be collected as a shape temp)
(defun %ad-inline-literal-shape-temps (flat-anf)
  "Substitute every ANF temp bound to a literal list of integers with that literal.

   `(%ANF-T-1 (64 64))` makes %ANF-T-1 a SHAPE, not a value -- the AD engine's shape
   maps require literals and a backward cannot reference a forward-only temp.  A
   binding is only inlined when its value is a non-empty list of integers, which no
   call form can be (a call's head is a symbol).

   The temp's OWN binding is left intact -- rewriting its left-hand side would produce
   the malformed `((64 64) (64 64))`.  Leaving the now-dead binding is harmless: the
   backward contains only what the walk emits."
  (let ((map nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form)) (first form)
                  ;; `'(2 2)` reads as `(QUOTE (2 2))`, which has a BINDING's exact shape.
                  ;; Collecting it made QUOTE a map key; harmless while the binding clause
                  ;; returned the form untouched, fatal once that clause rewrites the value
                  ;; (it produced `(MAKE-TENSOR V INT (QUOTE 0) :STRIDES (QUOTE 0))`).
                  ;; A quoted literal is never an ANF shape temp, so exclude it outright.
                  (not (string-equal (symbol-name (first form)) "QUOTE"))
                  (listp (second form)) (second form)
                  (every #'integerp (second form))
                  (not (assoc (first form) map)))
         (push (cons (first form) (second form)) map))))
    (if (null map)
        flat-anf
        (labels ((walk (f)
                   (cond
                     ((and f (symbolp f))
                      (let ((e (assoc f map))) (if e (cdr e) f)))
                     ((not (consp f)) f)
                     ;; A temp's own binding.  Its left-hand side must NOT be rewritten --
                     ;; that would produce the malformed `((64 64) (64 64))` -- but the VALUE
                     ;; is neutralised to 0.  Endeavour 163 defect D: leaving the dead binding
                     ;; intact stopped being harmless when endeavour 149's PRIMAL REPLAY began
                     ;; replaying the forward's STATEMENTS, bindings included.  The dead
                     ;; `(%ANF-T-27 (32 16))` then reached the analyzer, which read `(32 16)`
                     ;; as a CALL with 32 in head position:
                     ;;     The value 32 is not of type SYMBOL
                     ;; The binding is dead BY CONSTRUCTION -- every occurrence of the symbol
                     ;; has just been substituted with the literal -- so 0 is safe and keeps
                     ;; the binding-list shape the walk expects.
                     ((and (= (length f) 2) (symbolp (first f)) (first f)
                           (assoc (first f) map))
                      (list (first f) 0))
                     (t (mapcar #'walk f)))))
          (mapcar #'walk flat-anf)))))

