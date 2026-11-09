;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-11-08 -- endeavour 209 (B200 MMA bench: BUG 157 / F-209-3 persistent flat walk;
;;;; F-209-4 / D-209-13 signal fence) folded into src/ by script (put_temp_files_here/209-fold/fold.py:
;;;; LIVE copies by offset; no capture wrappers):
;;;;   * new     -> %ts-persistent-grid-p (src/analysis/control.lisp), %gen-nvvm-fence-acq-rel (src/codegen.lisp)
;;;;   * replaced -> %expand-tile-stride-form (control), generate-node-ir semantic-signal (codegen)
;;;;   * then D-209-14 (F-209-9: the signal fence is always fence.acq_rel.cta) -> generate-node-ir
;;;;     semantic-signal replaced again in src/codegen.lisp (put_temp_files_here/209-fold2/fold.py)
;;;;
;;;; EMPTY as of 2026-11-06 -- endeavour 208 (tcgen05 on the B200: phases 1-4, D-208-17 mmts, BUG 156
;;;; per-slot ring phase bits) folded into src/ by script (put_temp_files_here/208-fold/fold.py: LIVE
;;;; copies by offset; capture wrappers split base + wrapper):
;;;;   * new            -> semantic-tcgen05-op (src/semantic.lisp); the tcgen05 analyzers, block rewrite
;;;;                       and scale layouts (src/mma.lisp); the tcgen05 lowering (src/codegen.lisp);
;;;;                       %156-await-slot (codegen), %ll-needs-ptx87-p (compiler), *mmts-tcgen05-tile*
;;;;                       (control), %208-param-block-info (metadata)
;;;;   * replaced       -> %lower-warp-specialization, ensure-branch-compatibility, %mmts-reset-forms,
;;;;                       analyze-matrix-multiply-tile-stride-expression, analyze-await-expression-base
;;;;                       (control); generate-function-body, generate-node-ir semantic-nvvm-tma-wait
;;;;                       (codegen); %qint-mma-binding-elems, %qint-mma-walk, register-mma-analyzers
;;;;                       (mma); compile-to-ptx (compiler)
;;;;   * base + wrapper -> visit-toplevel-form (core), %tlc-check-elem-match (control),
;;;;                       generate-declared-signature (metadata), analyze-tcgen05-accumulate-via-tile (mma)
;;;;   * clauses        -> semantic-node-type / -source-location (core); def-microfloat-block passes
;;;;                       :shape to register-microfloat-block (macros)
;;;;   * dropped        -> every *208-orig-* capture, the %208-mma-kind declaim, the dead copies
;;;;
;;;; EMPTY as of 2026-11-04 -- endeavour 207 (int8 MMA lane: mma.sync m16n8k32, 1-byte prefetch, derived
;;;; register-tile gaps, scratch-ring width; then qint roles at the MMA and four typed mma.sync gaps) folded
;;;; into src/ by script (put_temp_files_here/207-fold/fold.py: LIVE copies by offset; no capture wrappers):
;;;;   * replaced in place -> 23 defuns in src/mma.lisp, src/codegen.lisp (%coop-coerce-scalar),
;;;;                          src/metadata.lisp (generate-implicit-signature),
;;;;                          src/analysis/control.lisp (%197-pair-elem-bytes)
;;;;   * new, src/mma.lisp -> *nvvm-int8-signs* + %nvvm-int8-signs-of + %emit-nvvm-mma-int8 + the
;;;;                          generate-node-ir :around (before %emit-nvvm-mma); the qint-role check
;;;;                          (before analyze-let-with-tile-explosion); %frag-src-derived-p / %frag8-read;
;;;;                          %store-frag-elem-cast
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


;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 210, item 6 (2026-11-08): CUDA TMA descriptors pass BY VALUE as __grid_constant__
;;;; kernel parameters (option B), replacing option A (a pointer to a device-global copy).
;;;;
;;;; Why: the CUDA Programming Guide (Asynchronous Data Copies, TMA) recommends a const
;;;; __grid_constant__ parameter, and says a tensor map in GLOBAL memory "requires a fence in each
;;;; thread block" (fence.proxy.tensormap::generic.acquire.sys when the host wrote it) and "may be
;;;; slower".  Crisp emitted no such fence.
;;;;
;;;; Shape: inside the compiler the descriptor is a GENERIC pointer everywhere (it used to be
;;;; addrspace 1).  Only the kernel's own parameter changes: `ptr byval([128 x i8]) align 64`, named
;;;; in !nvvm.annotations as "grid_constant".  NVPTX then emits `.param .align 64 .b8 k_param_N[128]`
;;;; and takes its address with cvta.param -- no local copy -- and that generic pointer is what the
;;;; TMA instructions and every helper function receive.  LLVM 21.1.5 IGNORES the
;;;; "nvvm.grid_constant" PARAMETER attribute (it copies the param to .local and hands TMA a local
;;;; address); only the annotation works (put_temp_files_here/210/gc/, ptxas-checked for sm_90a).
;;;; ---------------------------------------------------------------------------------------------

;; src/codegen.lisp (new, near %tma-lookup-descriptor-ptr)
(defun %210-tensor-map-spec-p (type-spec)
  "Endeavour 210.  True when TYPE-SPEC is a CUDA TMA descriptor type, (TENSOR-MAP SRC)."
  (and (consp type-spec) (symbolp (first type-spec))
       (string-equal (symbol-name (first type-spec)) "TENSOR-MAP")))

;; src/types/validation.lisp -- fold as the TENSOR-MAP clause of resolve-type-to-llvm (generic
;; pointer, addrspace 0, instead of addrspace 1)
(defvar *210-orig-resolve-type-to-llvm* (fdefinition 'resolve-type-to-llvm)
  "Endeavour 210 overlay capture -- dropped at fold time.")

(defun resolve-type-to-llvm (type-spec)
  "Endeavour 210 overlay wrapper: a (TENSOR-MAP SRC) descriptor is a GENERIC i8 pointer to the
   128-byte CUtensorMap.  In a kernel it is the address of the by-value __grid_constant__ parameter
   (%210-mark-grid-constant-tensor-maps); helper functions receive that same pointer.  Everything
   else resolves as before."
  (if (%210-tensor-map-spec-p type-spec)
      (llvm-pointer-type (llvm-int8-type) 0)
      (funcall *210-orig-resolve-type-to-llvm* type-spec)))

;; src/codegen.lisp
(defun %tma-lookup-descriptor-ptr (builder var-env src-name glob-ptr-type)
  "Endeavor 137 Phase 2b: reconstruct the CUtensorMap descriptor implicit-arg name
   (SRC_TENSORMAP_FROM_FN -- the same deterministic name the scan pass registered) and LOAD the
   descriptor pointer from its var-env slot (implicit params are alloca'd like every param).
   Returns the ptr or NIL if absent (no src symbol / not registered), so the caller falls back to
   the Phase-2a stand-in.

   Endeavour 210: the descriptor is a GENERIC pointer (the __grid_constant__ parameter's address),
   so it is loaded as addrspace 0 whatever GLOB-PTR-TYPE the caller passes -- loading it as
   addrspace 1 would reinterpret a param-space address as a global one.  The callers' addrspace
   casts to generic are then no-ops (LLVM returns the value unchanged).  GLOB-PTR-TYPE goes away
   at fold time."
  (declare (ignore glob-ptr-type))
  (when (and src-name (symbolp src-name) *compiler-context*)
    (let* ((fn    (compiler-context-current-compiling-function *compiler-context*))
           (uname (intern (format nil "~a_TENSORMAP_FROM_~a" src-name fn) (symbol-package src-name)))
           (slot  (gethash uname var-env)))
      (when slot
        (llvm-build-load2 builder (llvm-pointer-type (llvm-int8-type) 0) slot "tma_desc_ptr")))))

;; src/codegen.lisp (new, before ensure-opencl-kernel-metadata)
(defconstant +210-tensor-map-bytes+ 128
  "Endeavour 210.  sizeof(CUtensorMap): struct { alignas(64) cuuint64_t opaque[16]; }.")

(defconstant +210-tensor-map-align+ 64
  "Endeavour 210.  alignof(CUtensorMap).")

(defun %210-mark-grid-constant-tensor-maps (func semantic-function module)
  "Endeavour 210.  On PTX, give every TMA descriptor parameter of the kernel FUNC the by-value
   __grid_constant__ ABI: `byval([128 x i8]) align 64` on the parameter, and one
   !nvvm.annotations entry !{ptr @k, !\"grid_constant\", !{i32 i1, i32 i2 ...}} naming them
   (1-based parameter positions, as clang emits it).

   A parameter's LLVM position is counted the way %compute-kernel-cache-hints counts it -- each
   semantic parameter is (length (get-expanded-types TYPE MODULE)) LLVM parameters wide -- and the
   parameter found there must be a pointer, or this ERRORS: a descriptor marked at the wrong
   position would be a silently wrong launch ABI.  Not an entry point, or not PTX: nothing."
  (when (and (eq *target-backend* :ptx) (semantic-function-is-entry-point semantic-function))
    (let ((phys 0) (positions '()))
      (dolist (node (semantic-function-param-list semantic-function))
        (let* ((type  (semantic-param-type node))
               (width (or (ignore-errors (length (get-expanded-types type module))) 1)))
          (when (%210-tensor-map-spec-p type)
            (push (cons phys (semantic-param-name node)) positions))
          (incf phys width)))
      (when positions
        (setf positions (nreverse positions))
        (let* ((ctx      (llvm-get-module-context module))
               (i32      (llvm-int32-type))
               (byval-k  (llvm-get-enum-attribute-kind-for-name "byval" 5))
               (align-k  (llvm-get-enum-attribute-kind-for-name "align" 5))
               (map-type (llvm-array-type (llvm-int8-type) +210-tensor-map-bytes+))
               (n        (length positions)))
          (dolist (pos positions)
            (let* ((index (car pos))
                   (param (llvm-get-param func index)))
              (unless (and param (not (cffi:null-pointer-p param))
                           (crisp.llvm-bindings::llvm-type-kind-is-pointer? (llvm-type-of param)))
                (error "Endeavour 210: TMA descriptor ~a of kernel ~a should be LLVM parameter ~a, but that parameter is not a pointer -- the by-value ABI would be wrong."
                       (cdr pos) (semantic-function-name semantic-function) index))
              (llvm-add-attribute-at-index
               func (1+ index) (crisp.llvm-bindings::llvm-create-type-attribute ctx byval-k map-type))
              (llvm-add-attribute-at-index
               func (1+ index) (crisp.llvm-bindings::llvm-create-enum-attribute ctx align-k
                                                                                 +210-tensor-map-align+))
              (log:info "210: kernel ~a: TMA descriptor ~a = parameter ~a, by value (__grid_constant__)"
                        (semantic-function-name semantic-function) (cdr pos) index)))
          (cffi:with-foreign-objects ((idx-arr :pointer n) (entry :pointer 3))
            (loop for pos in positions for k from 0
                  do (setf (cffi:mem-aref idx-arr :pointer k)
                           (llvm-value-as-metadata (llvm-const-int i32 (1+ (car pos)) 0))))
            (let ((key "grid_constant"))
              (setf (cffi:mem-aref entry :pointer 0) (llvm-value-as-metadata func)
                    (cffi:mem-aref entry :pointer 1) (llvm-md-string-in-context2 ctx key (length key))
                    (cffi:mem-aref entry :pointer 2) (llvm-md-node-in-context2 ctx idx-arr n)))
            (llvm-add-named-metadata-operand
             module "nvvm.annotations"
             (crisp.llvm-bindings::llvm-metadata-as-value ctx (llvm-md-node-in-context2 ctx entry 3)))))))))

;; src/codegen.lisp -- fold as a call at the end of ensure-opencl-kernel-metadata's entry-point branch
(defvar *210-orig-ensure-opencl-kernel-metadata* (fdefinition 'ensure-opencl-kernel-metadata)
  "Endeavour 210 overlay capture -- dropped at fold time.")

(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Endeavour 210 overlay wrapper: the original, then the by-value __grid_constant__ ABI for the
   kernel's TMA descriptor parameters (%210-mark-grid-constant-tensor-maps)."
  (multiple-value-prog1 (funcall *210-orig-ensure-opencl-kernel-metadata* func semantic-function module)
    (%210-mark-grid-constant-tensor-maps func semantic-function module)))

;; src/metadata.lisp -- fold into generate-implicit-signature's TENSOR-MAP clause
(defvar *210-orig-generate-implicit-signature* (fdefinition 'generate-implicit-signature)
  "Endeavour 210 overlay capture -- dropped at fold time.")

(defun generate-implicit-signature (sig declared-params)
  "Endeavour 210 overlay wrapper: a :kind :tensor-map entry now says how it is passed --
   :address-space :param, :passing :by-value, :bytes 128, :align 64 -- because a host binds the
   128-byte CUtensorMap ITSELF (kernelParams[i] = &map), not a device pointer to a copy."
  (let ((entries (funcall *210-orig-generate-implicit-signature* sig declared-params)))
    (mapcar (lambda (e)
              (if (and (listp e) (eq (getf e :kind) :tensor-map))
                  (let ((e (copy-list e)))
                    (setf (getf e :address-space) :param
                          (getf e :passing) :by-value
                          (getf e :bytes) +210-tensor-map-bytes+
                          (getf e :align) +210-tensor-map-align+)
                    e)
                  e))
            entries)))

;; src/codegen.lisp  (REPLACES the copy above -- two bindings need their package prefix)
(defun %210-mark-grid-constant-tensor-maps (func semantic-function module)
  "Endeavour 210.  On PTX, give every TMA descriptor parameter of the kernel FUNC the by-value
   __grid_constant__ ABI: `byval([128 x i8]) align 64` on the parameter, and one
   !nvvm.annotations entry !{ptr @k, !\"grid_constant\", !{i32 i1, i32 i2 ...}} naming them
   (1-based parameter positions, as clang emits it).

   A parameter's LLVM position is counted the way %compute-kernel-cache-hints counts it -- each
   semantic parameter is (length (get-expanded-types TYPE MODULE)) LLVM parameters wide -- and the
   parameter found there must be a pointer, or this ERRORS: a descriptor marked at the wrong
   position would be a silently wrong launch ABI.  Not an entry point, or not PTX: nothing."
  (when (and (eq *target-backend* :ptx) (semantic-function-is-entry-point semantic-function))
    (let ((phys 0) (positions '()))
      (dolist (node (semantic-function-param-list semantic-function))
        (let* ((type  (semantic-param-type node))
               (width (or (ignore-errors (length (get-expanded-types type module))) 1)))
          (when (%210-tensor-map-spec-p type)
            (push (cons phys (semantic-param-name node)) positions))
          (incf phys width)))
      (when positions
        (setf positions (nreverse positions))
        (let* ((ctx      (llvm-get-module-context module))
               (i32      (llvm-int32-type))
               (byval-k  (crisp.llvm-bindings::llvm-get-enum-attribute-kind-for-name "byval" 5))
               (align-k  (crisp.llvm-bindings::llvm-get-enum-attribute-kind-for-name "align" 5))
               (map-type (llvm-array-type (llvm-int8-type) +210-tensor-map-bytes+))
               (n        (length positions)))
          (dolist (pos positions)
            (let* ((index (car pos))
                   (param (llvm-get-param func index)))
              (unless (and param (not (cffi:null-pointer-p param))
                           (crisp.llvm-bindings::llvm-type-kind-is-pointer? (llvm-type-of param)))
                (error "Endeavour 210: TMA descriptor ~a of kernel ~a should be LLVM parameter ~a, but that parameter is not a pointer -- the by-value ABI would be wrong."
                       (cdr pos) (semantic-function-name semantic-function) index))
              (llvm-add-attribute-at-index
               func (1+ index) (crisp.llvm-bindings::llvm-create-type-attribute ctx byval-k map-type))
              (llvm-add-attribute-at-index
               func (1+ index) (crisp.llvm-bindings::llvm-create-enum-attribute ctx align-k
                                                                                 +210-tensor-map-align+))
              (log:info "210: kernel ~a: TMA descriptor ~a = parameter ~a, by value (__grid_constant__)"
                        (semantic-function-name semantic-function) (cdr pos) index)))
          (cffi:with-foreign-objects ((idx-arr :pointer n) (entry :pointer 3))
            (loop for pos in positions for k from 0
                  do (setf (cffi:mem-aref idx-arr :pointer k)
                           (llvm-value-as-metadata (llvm-const-int i32 (1+ (car pos)) 0))))
            (let ((key "grid_constant"))
              (setf (cffi:mem-aref entry :pointer 0) (llvm-value-as-metadata func)
                    (cffi:mem-aref entry :pointer 1) (crisp.llvm-bindings::llvm-md-string-in-context2 ctx key (length key))
                    (cffi:mem-aref entry :pointer 2) (llvm-md-node-in-context2 ctx idx-arr n)))
            (llvm-add-named-metadata-operand
             module "nvvm.annotations"
             (crisp.llvm-bindings::llvm-metadata-as-value ctx (llvm-md-node-in-context2 ctx entry 3)))))))))

;;; ===================================================================
;;; Endeavour 210 item 2 (F-209-2, F-210-1, F-210-2) -- a store's :transformF on ACCUMULATORS.
;;; tests/spec/210-tcgen05-misc/ (02-07, errors/01-04); put_temp_files_here/210/item2/findings.md.
;;;
;;; ideal_001.md names `store-tile ... :transformF #'f` as the third fused-epilogue site, but only
;;; the generic tile store implemented it: the accumulator store analyzers never read their options,
;;; so on a tcgen05 / wgmma accumulator :transformF was SILENTLY DROPPED (byte-identical PTX), and on
;;; an exploded register tile it died as "Unknown variable C-TILE".  Now:
;;;   tcgen05          the function is applied per element as it leaves tensor memory
;;;                    (%tcgen05-store-rewrite-origin, via *210-store-transform*); refused on the
;;;                    :via :tma store, which converts inside one codegen node.
;;;   wgmma / fragment (let ((tmp SRC)) (map-elements! tmp F) (store.. tmp ..)) -- the existing
;;;                    map-elements! lowering, on a copy, so the accumulator is not mutated.
;;;   register tile    the same per fragment, in the tile explosion.
;;;   any other option on an accumulator store is refused instead of ignored.
;;;   map-elements! on a tcgen05 accumulator is refused, pointing at :transformF (D-210-5).
;;;   --differentiate refuses a floating :transformF by name (F-210-2: the backward ignored it).
;;; ===================================================================

;; src/mma.lisp
(defvar *210-store-transform* nil
  "Endeavour 210 (F-210-1).  The #'F of a tcgen05 accumulator store's :transformF while that store is
   analyzed (bound by %210-store-front), else NIL.  %tcgen05-store-rewrite-origin applies it to each
   element read from tensor memory, before any narrowing conversion.")

;; src/mma.lisp
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

;; src/mma.lisp
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

;; src/mma.lisp
(defun %210-replace-store-source (src-form new)
  "Endeavour 210.  SRC-FORM (a store's source: X, or a peelable conversion (to-half X) / (to-q8 X M))
   with its accumulator X replaced by NEW, so the rewritten store peels exactly as the original."
  (if (consp src-form)
      (list* (first src-form) new (cddr src-form))
      new))

;; src/mma.lisp
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

;; src/mma.lisp
(defvar *210-orig-208-analyze-store-tile* (fdefinition '%208-analyze-store-tile)
  "Endeavour 210.  208's store-tile analyzer, fronted by %210-store-front.")

;; src/mma.lisp  (fold: the front becomes the body of %208-analyze-store-tile)
(defun %208-analyze-store-tile (expr env context location)
  "Endeavour 208.  store-tile: a tcgen05 accumulator source is stored by %tcgen05-store-rewrite-origin
   at the tile-grid origin (BTY*M, BTX*N); anything else goes to analyze-store-tile-mma unchanged.
   Endeavour 210: fronted by %210-store-front (options on an accumulator store, :transformF)."
  (%210-store-front expr env context location *210-orig-208-analyze-store-tile* nil))

;; src/mma.lisp
(defvar *210-orig-208-analyze-store-tile-at* (fdefinition '%208-analyze-store-tile-at)
  "Endeavour 210.  208's store-tile-at analyzer, fronted by %210-store-front.")

;; src/mma.lisp  (fold: the front becomes the body of %208-analyze-store-tile-at)
(defun %208-analyze-store-tile-at (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin, directly or with :via :tma; anything else goes to analyze-store-tile-at-mma.
   Endeavour 210: fronted by %210-store-front (options on an accumulator store, :transformF)."
  (%210-store-front expr env context location *210-orig-208-analyze-store-tile-at* t))

;; src/mma.lisp
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

;; src/mma.lisp
(defvar *210-orig-explode-rewrite-body-form* (fdefinition '%explode-rewrite-body-form)
  "Endeavour 210.  196's %explode-rewrite-body-form, wrapped for a store-tile with options.")

;; src/mma.lisp  (fold: a clause at the top of 196's %explode-rewrite-body-form)
(defun %explode-rewrite-body-form (form tiles)
  "Endeavour 196 wrapper: (store-tile (to-half V) DEST (BTY BTX)) on an exploded register tile V
   expands exactly as (store-tile V DEST ...) does, with every emitted store-fragment's FRAG wrapped
   in the conversion.  Every other form goes to the original, which recurses back through this
   name.
   Endeavour 210 (F-210-1): (store-tile [CONV] V DEST (BTY BTX) :transformF #'F) on an exploded tile
   expands the same way with each fragment copied and mapped first (%210-map-store-fragment-sources);
   any other option on it is refused (it used to surface as \"Unknown variable V\")."
  (if (and (consp form) (symbolp (first form)) (%head-name-eq (first form) "STORE-TILE")
           (> (length form) 4))
      (multiple-value-bind (v convert) (%196-peel-store-conversion (second form))
        (let ((entry (and (symbolp v) (assoc v tiles))))
          (if (null entry)
              (funcall *210-orig-explode-rewrite-body-form* form tiles)
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
      (funcall *210-orig-explode-rewrite-body-form* form tiles)))

;; src/analysis/control.lisp
(defvar *210-orig-analyze-map-elements* (fdefinition 'analyze-map-elements)
  "Endeavour 210.  The map-elements! analyzer, wrapped to refuse a tcgen05 target by name.")

;; src/analysis/control.lisp  (fold: a clause before the PTX branch of analyze-map-elements)
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.
   See the original (src/analysis/control.lisp) for the PTX / SPV lowerings.
   Endeavour 210 (D-210-5): a tcgen05 accumulator TARGET is refused with the spelling that works --
   it lives in tensor memory, not registers, and its only readers are the stores, which take
   :transformF."
  (let* ((target (second expr))
         (ty (and (= (length (cdr expr)) 2)
                  (%208-source-type target env context location))))
    (when (and ty (%tcgen05-acc-type-p ty))
      (error 'crisp-compiler-error
             :message (format nil "map-elements!: ~(~a~) is a tcgen05 accumulator, which lives in tensor memory, not in registers.  Apply the function as it is stored instead: (store-tile ~(~a~) DEST (..) :transformF ~(~s~)) or (store-tile-at ~(~a~) DEST (ROW COL) :transformF ~(~s~))."
                              target target (third expr) target (third expr))
             :source-location location))
    (funcall *210-orig-analyze-map-elements* expr env context location)))

;; src/mma.lisp  (REPLACES %tcgen05-store-rewrite-origin; script-extracted, one binding changed)
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

;; src/autodiff.lisp
(defun %210-floating-transform-p (fn-form)
  "Endeavour 210 (F-210-2).  T when FN-FORM (a store's :transformF) can carry a gradient: a #'NAME
   whose registered signature returns a floating type, or anything whose signature is unknown (refused
   rather than silently mis-differentiated).  An integer function (111/08's ulong double-val) carries
   no gradient, so its store differentiates as before."
  (let* ((name (%map-elements-fn-name fn-form))
         (sigs (and name (gethash name *function-table*))))
    (log:debug "210 floating-transform-p ~a: ~d signature(s), returns ~s"
               fn-form (length sigs) (mapcar #'function-signature-return-types sigs))
    (or (null sigs)
        (some (lambda (s) (some #'%crisp-float-type-p (function-signature-return-types s))) sigs))))

;; src/autodiff.lisp
(defun %210-find-store-transform (form)
  "Endeavour 210 (F-210-2).  The first (store-tile ..) / (store-tile-at ..) form inside FORM whose
   options carry a floating :transformF (%210-floating-transform-p), or NIL."
  (cond ((atom form) nil)
        ((and (symbolp (first form))
              (member (symbol-name (first form)) '("STORE-TILE" "STORE-TILE-AT") :test #'string=)
              (> (length form) 4)
              (let ((fn (%210-split-transformF (nthcdr 4 form))))
                (and fn (%210-floating-transform-p fn))))
         form)
        (t (loop for x on form
                 thereis (and (consp x) (%210-find-store-transform (car x)))))))

;; src/autodiff.lisp
(defvar *210-orig-generate-backward-walk* (fdefinition 'generate-backward-walk)
  "Endeavour 210.  The backward walk, wrapped to refuse a store's :transformF (F-210-2).")

;; src/autodiff.lisp  (fold: a check at the top of generate-backward-walk)
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.  See the original (src/autodiff.lisp).
   Endeavour 210 (F-210-2): a store with a floating :transformF is REFUSED first.  The store-tile(-at)
   backward never read its options, so the gradient silently ignored the function (dX = dOUT for
   :transformF #'sq, where 2 X dOUT is right).  The message points at map-elements! before the
   store, which differentiates."
  (let ((st (%210-find-store-transform flat-anf)))
    (when st
      (error 'crisp-compiler-error
             :message (format nil "--differentiate: (~(~a~) ~(~a~) ~(~a~) ..) with :transformF ~(~s~): a store's :transformF has no backward yet (F-210-2) -- the gradient would ignore the function.  Apply it before the store, (map-elements! ~(~a~) ~(~s~)), which differentiates; or compile this kernel without --differentiate."
                              (first st) (second st) (third st)
                              (%210-split-transformF (nthcdr 4 st))
                              (second st) (%210-split-transformF (nthcdr 4 st)))
             :source-location nil)))
  (funcall *210-orig-generate-backward-walk* flat-anf inputs outputs input-types output-types
           :kernel-pkg kernel-pkg))

;; src/autodiff.lisp  (fold: a check at the top of generate-backward-walk)
;; SECOND COPY (only this one is live): the message names the PEELED source, not (to-bfloat16 D).
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.  See the original (src/autodiff.lisp).
   Endeavour 210 (F-210-2): a store with a floating :transformF is REFUSED first.  The store-tile(-at)
   backward never read its options, so the gradient silently ignored the function (dX = dOUT for
   :transformF #'sq, where 2 X dOUT is right).  The message points at map-elements! before the
   store, which differentiates."
  (let ((st (%210-find-store-transform flat-anf)))
    (when st
      (error 'crisp-compiler-error
             :message (format nil "--differentiate: (~(~a~) ~(~a~) ~(~a~) ..) with :transformF ~(~s~): a store's :transformF has no backward yet (F-210-2) -- the gradient would ignore the function.  Apply it before the store, (map-elements! ~(~a~) ~(~s~)), which differentiates; or compile this kernel without --differentiate."
                              (first st) (second st) (third st)
                              (%210-split-transformF (nthcdr 4 st))
                              (%196-peel-store-conversion (second st)) (%210-split-transformF (nthcdr 4 st)))
             :source-location nil)))
  (funcall *210-orig-generate-backward-walk* flat-anf inputs outputs input-types output-types
           :kernel-pkg kernel-pkg))

;; src/analysis/control.lisp  (REPLACES analyze-%store-pair-expression; one comparison changed)
(defun analyze-%store-pair-expression (expr env context location)
  "Analyzer for (%store-pair P0 P1 LO HI): one <2 x T> store when LO and HI already have P0's element
   type and that type packs; otherwise exactly (progn (set! P0 LO) (set! P1 HI)), so conversions
   and type errors are set!'s own.  The caller guards it with (%pair-ok-p P0 P1).
   Endeavour 210: LO / HI are compared by their SINGLE-VALUE type.  A function call's node type is the
   list of its return types -- (FLOAT) -- so an element passed through a store's :transformF never
   matched FLOAT and every pair fell back to two scalar stores (a B200 tcgen05 store lost all 128 of
   its st.global.v2)."
  (unless (= (length expr) 5)
    (error 'crisp-compiler-error :message "%store-pair: expects (%store-pair P0 P1 LO HI)"
           :source-location location))
  (destructuring-bind (p0-form p1-form lo-form hi-form) (rest expr)
    (let* ((p0 (analyze-expression p0-form env context (append location '(1))))
           (elem (semantic-node-type p0))
           (bytes (%197-pair-elem-bytes elem))
           (lo (analyze-expression lo-form env context (append location '(3))))
           (hi (analyze-expression hi-form env context (append location '(4)))))
      (if (and bytes (semantic-aref-p p0)
               (equal (get-single-value-type lo) elem) (equal (get-single-value-type hi) elem))
          (make-semantic-store-pair :place-node p0 :lo-node lo :hi-node hi :elem-bytes bytes
                                    :type 'nil :source-location location)
          (progn
            (log:debug "197 %store-pair: falling back to two set!s (elem ~a, lo ~a, hi ~a)"
                       elem (semantic-node-type lo) (semantic-node-type hi))
            (analyze-expression `(progn (set! ,p0-form ,lo-form) (set! ,p1-form ,hi-form))
                                env context location))))))

;;; ===================================================================
;;; Endeavour 210 item 4 (F-209-8, D-210-7) -- (even-columns C): a wgmma store-tile emits the packed
;;; arm ALONE.  tests/spec/210-tcgen05-misc/08 + errors/05; put_temp_files_here/210/item4/findings.md.
;;;
;;; 197's wgmma epilogue is (if (%pair-ok-p first pair) 64-x-%store-pair 128-x-set!).  The two arms
;;; together keep the accumulator and both arms' addresses live: sec3 164-168 registers, 96 for the
;;; packed arm alone (4 workgroups/SM instead of 2 at 160 threads; multicast +11..14% measured).  No
;;; CORRECT fallback stays light (122-128, findings.md), so the fallback is made unnecessary instead:
;;; the kernel DECLARES C's column count even.  With C :align :compact :contiguous-term :row-major and a
;;; grid-origin store (column origin = grid-x * N + 2*(lane mod 4), even), every pair is then one aligned
;;; word.  A false declaration faults loudly (misaligned address), it cannot store wrong values.
;;; ===================================================================

;; src/mma.lisp
(defvar *210-pairs-only* nil
  "Endeavour 210 (D-210-7).  T while a wgmma (store-tile D C (BTY BTX)) whose C is declared
   (even-columns C) is analyzed (bound by the analyze-store-tile-mma wrapper):
   %wgmma-store-rewrite-origin then emits only its packed arm.")

;; src/analysis/core.lisp
(defun %210-even-columns-names (declarations)
  "Endeavour 210 (D-210-7).  The parameter symbols named by every (even-columns P ...) in DECLARATIONS."
  (loop for d in declarations
        when (and (consp d) (symbolp (car d)) (string-equal (symbol-name (car d)) "EVEN-COLUMNS"))
          append (cdr d)))

;; src/mma.lisp
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

;; src/mma.lisp
(defvar *210-orig-analyze-store-tile-mma* (fdefinition 'analyze-store-tile-mma)
  "Endeavour 210.  196's analyze-store-tile-mma, wrapped to bind *210-pairs-only*.")

;; src/mma.lisp  (fold: the binding moves into analyze-store-tile-mma's wgmma clause)
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
    (funcall *210-orig-analyze-store-tile-mma* expr env context location)))

;; src/mma.lisp  (REPLACES %wgmma-store-rewrite-origin; script-extracted, the final IF made conditional)
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
