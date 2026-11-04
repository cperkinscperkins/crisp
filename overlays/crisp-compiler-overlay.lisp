;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-11-02 -- endeavours 202-206 (derived types through handles, accumulator types, integer
;;;; MMA, quantized integers, microfloat blocks) and BUG 135 (register budgets, launch bounds) folded into src/
;;;; by script (put_temp_files_here/206-fold/fold.py: LIVE copies by offset, plus the earlier copies an
;;;; (fdefinition 'x) capture kept alive; every *...-206* / -204 / -135 capture defvar dropped):
;;;;   * prepended    -> internal-def-function (%mf-refuse-block-at-boundary, %record-register-budgets),
;;;;                     generate-backward-walk, %analyze-min/max-expression, register-struct-definition,
;;;;                     analyze-accum-op, %check-qint-arith
;;;;   * first clause -> analyze-scaled-float-cast, analyze-aref-expression, resolve-type-accessor,
;;;;                     %185-math-backward (two clauses), %register-accum-analyzers (merged)
;;;;   * base+wrapper -> canonicalize-type-specifier-base, %expand-stride-macros-in-form-base
;;;;   * replaced / new -> everything else, under per-endeavour headers in the file its comment named
;;;; EMPTY as of 2026-10-30 -- endeavours 200 (sort_v2 contest: BUG 138 / 145 / 148 / 149) and 201 (look-back-scan,
;;;; phase 1) folded into src/ (put_temp_files_here/201-fold/fold.py: verbatim copies; wrappers folded, their
;;;; *200-orig-* / *201-orig-* defvars dropped):
;;;;   * BUG 138  -> %185-helper-call (noinline on SPIR-V only) replaced (src/codegen.lisp)
;;;;   * BUG 145  -> semantic-while clauses in semantic-node-type / -source-location (src/analysis/core.lisp)
;;;;   * BUG 148  -> WHILE hint in *unsupported-form-hints* (src/errors.lisp); register-control-analyzers registers
;;;;                 only %WHILE (src/analysis/control.lisp); anf-normalize refuses WHILE / %WHILE at the top of
;;;;                 its cons branch (src/anf-transform.lisp); sync-wait spins with %while (src/macros.lisp)
;;;;   * BUG 149  -> make-scratch-cell keeps its keywords in anf-normalize; SYNC-ARRIVE / SYNC-WAIT in
;;;;                 *anf-unexpanded-macros* and *anf-opaque-statement-names* (src/anf-transform.lisp); the
;;;;                 %200-vjp-* rules and their register-vjp blocks at the end of src/autodiff.lisp
;;;;   * 201      -> ordered-workgroup-id / look-back-scan macros after sync-wait (src/macros.lisp), exported from
;;;;                 crisp.compiler and imported into crisp-language (src/package.lisp, all three lists); the
;;;;                 %lbs-* / analyze-lbs-* helpers at the end of src/analysis/ops.lisp, registered in
;;;;                 register-control-analyzers; both names in *anf-unexpanded-macros*; %201-vjp-* at the end
;;;;                 of src/autodiff.lisp
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: the 200 helper validators before main,
;;;;    %vad-resolve-symbolic-size with :match-global-size; the hoist overlays -> src/hoist-*/main.lisp)
;;;; EMPTY as of 2026-10-29 -- endeavours 196-199 (matmul contest: 16-bit stores, packed stores, wgmma transB,
;;;; :via :tma) folded into src/ by script (put_temp_files_here/199-fold/fold.py: LIVE copies by offset; wrappers
;;;; folded, their *orig* defvars dropped):
;;;;   * clean folds   -> semantic-node-type / -source-location (three etypecase clauses), register-control-
;;;;                      analyzers (a trailing call), %tlc-bwd-adj-name (a first COND clause, D-196-12), the
;;;;                      scan-operator :before (a STORE-TILE-AT clause beside LOAD-TILE in the default method)
;;;;   * base+wrapper  -> X-base + X for %explode-rewrite-body-form, %explode-register-tiles,
;;;;                      analyze-await-expression, analyze-wgmma-accumulate, %gen-nvvm-tma-bulk-tensor-g2s-2d;
;;;;                      resolve-tma-descriptors-base -> %resolve-tma-load-descriptors -> resolve-tma-descriptors;
;;;;                      %analyze-nvvm-tma-load-tile-at-base (152) -> -multicast -> %analyze-nvvm-tma-load-tile-at
;;;;   * replaced      -> analyze-store-fragment, %wgmma-store-rewrite[-origin], analyze-store-tile[-at]-mma,
;;;;                      %register-tile-fit-check, %check-wgmma-operands, analyze-wgmma-accumulate-via-tile,
;;;;                      %emit-wgmma-mma-only, %emit-nvvm-wgmma, the semantic-mma-accumulate method (mma.lisp);
;;;;                      analyze-%cp-async-copy-elem-expression, analyze-load-tile-at-expression (control.lisp);
;;;;                      %mma-vjp-mma-admissible-p (autodiff.lisp)
;;;;   * new           -> %196-* / %197-* / %198-* / %199-* helpers, three structs (semantic.lisp), the 197 / 199
;;;;                      codegen methods and 198's :around (codegen.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: the 196-199 validators)
;;;; EMPTY as of 2026-10-27 -- endeavour 195 (atomic-load / atomic-store!) folded into src/ (only the LAST copy
;;;; of %195-vjp-atomic-store was taken; both wrappers merged into their originals, *195-orig-* dropped):
;;;;   * analyzers  -> %195-check-* / %195-analyze-atomic-place, analyze-atomic-load-expression,
;;;;                   analyze-atomic-store!-expression, register-195-atomic-access-analyzers after
;;;;                   analyze-atomic-set!-expression; called at the end of register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * ANF        -> *anf-atomic-op-names* (src/anf-transform.lisp)
;;;;   * codegen    -> %195-atomic-alignment, %195-make-relaxed-device, %195-build-atomic-load / -store after
;;;;                   %184-device-sync-scope; the :load / :store CASE in generate-node-ir semantic-atomic-rmw (src/codegen.lisp)
;;;;   * AD         -> "ATOMIC-STORE!" in %ad-replay-fill-targets / %ad-replay-read-syms; *195-ad-param-types*
;;;;                   (defvar before generate-backward-walk, bound in its outer LET); the %195-* VJP helpers
;;;;                   and their register-vjp block at the end of src/autodiff.lisp
;;;;   * semantic   -> semantic-atomic-rmw docstring (src/semantic.lisp)
;;;;   * bindings   -> LLVMSetAtomicSyncScopeID after LLVMSetOrdering (src/llvm-bindings.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: %195-ptx-lines-with,
;;;;    %195-check-ptx-relaxed, validate-ptx-relaxed-load-store(-shared), validate-spv-relaxed-load-store)
;;;;
;;;; EMPTY as of 2026-10-26 -- endeavour 194 (two-level uniformity) folded into src/ (one copy of each
;;;; definition existed; the six wrappers merged into their originals, *194-orig-* scaffolding dropped):
;;;;   * state, structs, lattice, summaries, (/ tid K) inference -> top of src/analysis/core.lisp, with a
;;;;                          (declaim (special ...)) for the specials internal-compile-function binds
;;;;   * calculate-uniformity-state, %uniformity-join, internal-compile-function (fresh context + summary),
;;;;     analyze-function-call (call-site check)                  -> src/analysis/core.lisp
;;;;   * %194-call-in-scope / -note / -judge-loop / refusals, the if / dotimes / loop-variant / unroll-loop /
;;;;     return-from-loop / to-*-uniform / sync / shuffle / tile checks, analyze-return-expression,
;;;;     analyze-let-expression                                   -> src/analysis/control.lisp
;;;;   * %analyze-set!-simple-variable                            -> src/analysis/structs.lisp
;;;;   * %194-reduced-variables, %analyze-reduce-warp            -> src/analysis/ops.lisp
;;;;   * initialize-compiler calls %194-clear-summaries           -> src/compiler.lisp
;;;;   * the two broadcasts, %194-workgroup-slot / -barrier      -> src/codegen.lisp
;;;;
;;;; EMPTY as of 2026-10-25 -- endeavour 193 (logging-output) folded into src/ (only the LAST copy of each
;;;; re-appended function was taken; wrappers folded into their originals, *193-orig-* scaffolding dropped):
;;;;   * state + helpers   -> the die / log defvars, %193-die-symbol-p, %193-may-die-p, %193-body-dies-directly-p,
;;;;                          %193-parse-size, %193-log-capacity-words; :logging-output / :logging-size on
;;;;                          initialize-compiler (src/compiler.lisp)
;;;;   * analysis          -> %193-compute-may-die-functions (called from propagate-implicit-arguments),
;;;;                          %193-current-function, %193-site-of; analyze-function-call marks callers;
;;;;                          analyze-expression tracks the enclosing site (src/analysis/core.lisp)
;;;;   * analyzers         -> +193-die-id-forms+, analyze-die-expression, %193-log-kind,
;;;;                          analyze-log-message-expression, registered in register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * macros            -> when-thread-is, %193-assert-message, r-t-assert, r-t-assert-0, r-t-output(-0),
;;;;                          is-logging?, is-runtime-checking? (src/macros.lisp; exported/imported in src/package.lisp)
;;;;   * codegen           -> the %193-* die / check / log lowering block replacing %handle-die-intrinsic; die and
;;;;                          the log message in generate-node-ir (semantic-call); %build-function-call,
;;;;                          generate-function-prototype; the die flag in generate-function-body; the die check in
;;;;                          %gen-nvvm-mbarrier-try-wait-parity (src/codegen.lisp)
;;;;   * AD                -> the inactive clause in %active-scalar-vars (src/autodiff.lisp)
;;;;   * metadata          -> %193-serialize-die-sites / -log-sites, called from serialize-kernels (src/metadata.lisp)
;;;;   * reader            -> the `(` reader that records source lines, %193-with-read-file (src/reader.lisp);
;;;;                          used by %read-crisp-forms / %compile-files-single-pass; parse-cli-args (src/main.lisp)
;;;;   * bindings          -> LLVMCountParamTypes, GetParamTypes, CountParams, SetOrdering, GetGlobalParent
;;;;                          (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-24 -- endeavour 192 (cache hints) folded into src/ (only the LAST copy of each
;;;; re-appended function was taken; wrappers folded as one call each, their defvar scaffolding dropped):
;;;;   * :cache parsing      -> +cache-intents+, %cache-intent-keyword, %parse-cache-hint,
;;;;                            %check-cache-hint-address-space, %cache-hint-of-type, and a CACHE clause in
;;;;                            the four %expand-*-type-specifier (src/types/validation.lisp)
;;;;   * hint table          -> *kernel-cache-hint-table*, %kernel-llvm-name, %compute-kernel-cache-hints;
;;;;                            ensure-opencl-kernel-metadata records it (src/codegen.lisp)
;;;;   * post-opt pass       -> the %ll-* / %ptx-* / %spv-cache-controls block + %apply-cache-hints-to-ll,
;;;;                            called from compile-to-ptx (+ptx74) and compile-to-spirv (src/compiler.lisp)
;;;;   * tile ops            -> %refuse-per-operation-cache, called by analyze-load-tile-at-expression /
;;;;                            analyze-store-tile-at-expression (src/analysis/control.lisp) and
;;;;                            analyze-prefetch-tile (src/mma.lisp)
;;;;   * spec validators     -> %spv-cache-control-census + validate-spv-cache-* (src/mma.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: the %c192-* / validate-ptx-cache-*
;;;;    validators)
;;;; Before that, EMPTY as of 2026-10-22 -- endeavour 190 (compile API) folded into src/:
;;;;   * BUG 066 on PTX  -> ensure-opencl-kernel-metadata calls %173-ensure-grad-dispatch-decls on every backend (src/codegen.lisp)
;;;;   * BUG 133         -> %physical-array-split (new), %enumerate-physical-types (src/metadata-val.lisp);
;;;;                        get-physical-width, generate-physical-signature (src/metadata.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: --hoist-kernel=source)
;;;; Before that, EMPTY as of 2026-10-13 -- the "/=" entry in *unsupported-form-hints* folded into src/errors.lisp.
;;;; Before that, 2026-10-12 (later) -- endeavour 185 (math-ops) folded into src/:
;;;;   * overrides          -> analyze-let-expression (src/analysis/control.lisp); register-ops-analyzers,
;;;;                           analyze-mod-expression, analyze-rem-expression (src/analysis/ops.lisp);
;;;;                           %handle-single-value-backward (src/autodiff.lisp); semantic-div written out
;;;;                           in place of its def-binary-op-codegen line (src/codegen.lisp)
;;;;   * analyzers          -> the %185-* / analyze-185-* block before register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * lowering           -> the %185-* block + %hw-lower methods after %hw-sat-interior (src/codegen.lisp)
;;;;   * AD                 -> %185-math-backward (src/autodiff.lisp)
;;;;   * bindings           -> select xor srem urem ashr not enum-attribute frem (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-12 -- adversarial sweep (tests/adversarial/issues.md, Resolved) folded:
;;;;   * c-t struct values (ADV-018) -> validate-and-reorder-struct-args, %split-ct-props-args,
;;;;                                  %member-access-struct-name (src/structs.lisp); analyze-struct-construction,
;;;;                                  analyze-extract/insert-struct-member-expression, get-struct-member-index
;;;;                                  (src/analysis/structs.lisp); generate-node-ir semantic-struct-construction
;;;;                                  (src/codegen.lisp); %generate-struct-accessor (src/macros.lisp);
;;;;                                  types-compatible-p (src/type-checker.lisp); types-assignable-p +
;;;;                                  %ct-qualified-arg-fits-bare-param-p (src/types/hierarchy.lisp)
;;;;   * enums (ADV-005/007)       -> ensure-template-instantiation, %keyword-literal-type->enum (src/templates.lisp);
;;;;                                  ensure-branch-compatibility, %enum-type-for-branch (src/analysis/control.lisp);
;;;;                                  %promote-to-float-adjoint, %ad-enum-type-p, %backward-value-expr (src/autodiff.lisp);
;;;;                                  crisp-unsupported-form-error + *unsupported-form-hints* (src/errors.lisp)
;;;;   * kernel boundary (014/015/019/020) -> %validate-kernel-parameters, marshall-cell/-tensor + helpers
;;;;                                  (src/macros.lisp); %instantiate-callable-template, initialize-templates,
;;;;                                  *explicit-instantiation-names* (src/templates.lisp)
;;;;   * c-t-output (ADV-006)      -> src/macros.lisp
;;;;   * shadowed lets in AD (ADV-001/002) -> anf-transform + %alpha-rename-shadowed-lets (src/anf-transform.lisp)
;;;; Before that, 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)


(in-package :crisp.compiler)

;;;; ==========================================================================================
;;;; Endeavour 207 -- int8 operand tiles.  (tests/spec/207-int8-mma-bench/int8-mma-bench.md)
;;;; ==========================================================================================

;; src/codegen.lisp  (REPLACES %coop-coerce-scalar -- 207: integer-to-integer resizing)
(defun %coop-coerce-scalar (builder val want-ty name)
  "Coerce scalar VAL to WANT-TY, if it is not already that type.

   Float-to-float goes by fptrunc / fpext (Endeavour 155, fp16).

   FLOAT TO i16 IS THE bf16 FILL.  A bf16 cooperative matrix has INTEGER components, so filling
   one with a literal `0.0` means storing that float's BF16 BIT PATTERN as an i16.  bfloat16 is
   the top half of an IEEE f32, so the encoding is a bitcast to i32, a 16-bit logical shift right,
   and a truncate — no bfloat type is introduced anywhere, which is the entire point (see the bf16
   header).  This truncates rather than round-to-nearest; for the 0.0 that fills every accumulator
   and operand tile it is exact, and a rounding form would need a bfloat type or a carry chain to
   express.

   INTEGER TO INTEGER IS THE int8 FILL (Endeavour 207).  A `char` operand tile filled with the
   literal `0` arrives as an i32 and must become an i8, or the CompositeConstruct call disagrees
   with its own declaration and llvm-spirv refuses the module ('Can't translate function
   pointer').  Narrowing truncates and widening sign-extends; the sign of a cooperative-matrix
   element is the MulAdd operands mask's job, so sign-extension is only ever applied to a literal.

   LLVM has no direct cast between two DIFFERENT 16-bit float types, so half<->bfloat16 would route
   through f32; that path cannot arise from a literal today."
  (let* ((have (llvm-type-of val))
         (i16  (crisp.llvm-bindings::llvm-int16-type))
         (i32  (crisp.llvm-bindings::llvm-int32-type))
         (int-kind 8)                                   ; LLVMIntegerTypeKind
         (have-int (= (llvm-get-type-kind have) int-kind))
         (want-int (= (llvm-get-type-kind want-ty) int-kind)))
    (cond
      ((cffi:pointer-eq have want-ty) val)
      ;; f32 -> bf16 bits, carried as i16
      ((and (cffi:pointer-eq want-ty i16) (%llvm-float-width have))
       (let* ((as-f32 (if (cffi:pointer-eq have (llvm-float-type))
                          val
                          (llvm-build-fp-ext builder val (llvm-float-type) "bf_f32")))
              (bits (crisp.llvm-bindings::llvm-build-bit-cast builder as-f32 i32 "bf_bits"))
              (hi   (crisp.llvm-bindings::llvm-build-l-shr
                     builder bits (crisp.llvm-bindings::llvm-const-int i32 16 nil) "bf_hi")))
         (crisp.llvm-bindings::llvm-build-trunc builder hi i16 name)))
      ;; integer -> integer of another width (207: the int8 operand fill)
      ((and have-int want-int)
       (let ((hw (crisp.llvm-bindings::llvm-get-int-type-width have))
             (ww (crisp.llvm-bindings::llvm-get-int-type-width want-ty)))
         (log:debug "207 %coop-coerce-scalar: i~d -> i~d (~a)" hw ww name)
         (if (> hw ww)
             (crisp.llvm-bindings::llvm-build-trunc builder val want-ty name)
             (crisp.llvm-bindings::llvm-build-sext builder val want-ty name))))
      (t
       (let ((hw (%llvm-float-width have))
             (ww (%llvm-float-width want-ty)))
         (cond
           ((not (and hw ww)) val)
           ((> hw ww) (llvm-build-fp-trunc builder val want-ty name))
           ((< hw ww) (llvm-build-fp-ext   builder val want-ty name))
           (t (llvm-build-fp-trunc builder
                                   (llvm-build-fp-ext builder val (llvm-float-type)
                                                      (format nil "~a_via_f32" name))
                                   want-ty name))))))))

;; src/mma.lisp  (REPLACES %prefetch-block-shape -- 207: 1-byte elements)
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
;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 207 -- NVIDIA sync int8: mma.sync.aligned.m16n8k32.row.col.s32.{s8,u8}.{s8,u8}.s32
;;;; (A100 / Ada / Hopper).  204 refused it because the per-lane layouts could only be proven on metal;
;;;; the layouts below are the PTX ISA's m16n8k32 .s8/.u8 fragment tables, which are the m16n8k16
;;;; 16-bit tables with every K coordinate doubled (four bytes per 32-bit register instead of two
;;;; halves).  All four NVVM spellings were checked with bin/llc.exe -mcpu=sm_80 (2026-11-03).
;;;; NOTE FOR THE SRC FOLD: every function here REPLACES its namesake in src/mma.lisp, except
;;;; *nvvm-int8-signs*, %nvvm-int8-signs-of, %emit-nvvm-mma-int8 and the :around method, which are new.
;;;; ------------------------------------------------------------------------------------------


;; src/mma.lisp  (REPLACES register-mma-types -- 207: the int8 m16n8k32 records)
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

;; src/mma.lisp  (REPLACES register-builtin-hardware-profiles -- 207: h100 lists the int8 sync shape (16 8 32))
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

;; src/mma.lisp  (REPLACES %nvvm-frag-format -- 207: :int8)
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

;; src/mma.lisp  (REPLACES %nvvm-frag-record -- 207: int8 records)
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

;; src/mma.lisp  (REPLACES %frag-record-for-acc -- 207: int tiles on NVIDIA)
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

;; src/mma.lisp  (REPLACES analyze-load-fragment-a -- 207: the int8 m16n8k32 A layout)
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
                          (~ ,src r c)              (~ ,src r (+ c 1))        (~ ,src r (+ c 2))        (~ ,src r (+ c 3))
                          (~ ,src (+ r 8) c)        (~ ,src (+ r 8) (+ c 1))  (~ ,src (+ r 8) (+ c 2))  (~ ,src (+ r 8) (+ c 3))
                          (~ ,src r (+ c 16))       (~ ,src r (+ c 17))       (~ ,src r (+ c 18))       (~ ,src r (+ c 19))
                          (~ ,src (+ r 8) (+ c 16)) (~ ,src (+ r 8) (+ c 17)) (~ ,src (+ r 8) (+ c 18)) (~ ,src (+ r 8) (+ c 19))))))
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

;; src/mma.lisp  (REPLACES analyze-load-fragment-b -- 207: the int8 m16n8k32 B layout)
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
                          (~ ,src r c)        (~ ,src (+ r 1) c)  (~ ,src (+ r 2) c)  (~ ,src (+ r 3) c)
                          (~ ,src (+ r 16) c) (~ ,src (+ r 17) c) (~ ,src (+ r 18) c) (~ ,src (+ r 19) c)))))
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

;; src/mma.lisp  (NEW -- 207)
(defvar *nvvm-int8-signs* nil
  "(A-SIGNED . B-SIGNED) for the sync int8 MMA being emitted, or NIL (= both signed).  Bound by the
   generate-node-ir :around method on semantic-mma-accumulate, because the emitter receives only LLVM
   values and char / uchar are the same LLVM i8.")

;; src/mma.lisp  (NEW -- 207)
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

;; src/mma.lisp  (NEW -- 207)
(defmethod generate-node-ir :around ((node semantic-mma-accumulate) builder module var-env di-builder di-scope location-map)
  "Endeavour 207: binds *nvvm-int8-signs* for the sync int8 emitter (NVIDIA only)."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (let ((*nvvm-int8-signs* (unless (eq *target-backend* :spirv) (%nvvm-int8-signs-of node))))
    (when *nvvm-int8-signs*
      (log:debug "207 sync int8 MMA signs: ~a" *nvvm-int8-signs*))
    (call-next-method)))

;; src/mma.lisp  (NEW -- 207)
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


;; src/mma.lisp  (REPLACES %emit-nvvm-mma -- 207: the :int8 arm)
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

;; src/mma.lisp  (REPLACES %check-int-mma-k -- 207: NVIDIA too)
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

;; src/mma.lisp  (REPLACES %check-int-tile-k -- 207: NVIDIA too)
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

;; src/mma.lisp  (RECOMPILED VERBATIM -- 207: SBCL had derived %frag-record-for-acc's return type as
;; (MEMBER ...-F32-16X8 ...-F64-8X8) when compiling these callers, so the s32 record failed their type
;; check.  No change to the text; drop on the src fold.)
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


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 207 -- derived (def-qint) element types in register-tile kernels.  Two gaps found by
;;;; writing the BMG int8 benchmark kernel with q-a operands and an (accum q-a) tile:
;;;;   1. an (accum q-a) TILE lost its element type in the tile-stride macros (a list is not a symbol),
;;;;      so the per-tile reset minted FLOAT fragments: 'Expected (COOP-MATRIX INT ..) but inferred
;;;;      (COOP-MATRIX FLOAT ..)'.
;;;;   2. a q-a OPERAND loaded as (COOP-MATRIX Q-A ..) while the q-a register tile it lands in is
;;;;      (COOP-MATRIX CHAR ..) -- %elem-coop-type resolves an integer element to its base, and
;;;;      %coop-elem-of did not.
;;;; ------------------------------------------------------------------------------------------

;; src/mma.lisp  (REPLACES %register-tile-elems-from-bindings -- 207: accessor elements)
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

;; src/mma.lisp  (REPLACES %coop-elem-of -- 207: integer elements resolve to their base)
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
