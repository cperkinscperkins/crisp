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
