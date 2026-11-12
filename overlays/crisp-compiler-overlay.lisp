;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-11-11 -- endeavours 211 (shift-left / shift-right / rotate-left / rotate-right) and
;;;; 212 (warp-ballot / warp-any? / warp-all?; scratch sized by a folded expression) folded into src/ by
;;;; script (put_temp_files_here/212-fold/fold.py: LIVE copies by offset; no capture wrappers):
;;;;   * new      -> *211-shift-op-names*, analyze-211-shift-op, *212-vote-op-names*, analyze-212-vote-op
;;;;                 (analysis/ops); %211-shift-rotate-body, %211-lower, %212-pred-i1, %212-vote-lower and
;;;;                 seven %hw-lower methods (codegen, after %185-fmod); %212-vote-node-p (analysis/core);
;;;;                 %fold-scratch-size-expr (analysis/structs)
;;;;   * replaced -> %185-register-math-op-analyzers (ops), *warp-collective-operator-names* (codegen),
;;;;                 calculate-uniformity-state (core), %185-math-backward (autodiff),
;;;;                 %extract-scratch-size-expr (structs)
;;;;   * dropped  -> the dead 211 copies of %185-math-backward / %185-register-math-op-analyzers
;;;;
;;;; EMPTY as of 2026-11-09 -- endeavour 210 (tcgen05-misc: item 6 TMA descriptors by value, item 2
;;;; :transformF on accumulator stores, item 4 (even-columns C)) folded into src/ by script
;;;; (put_temp_files_here/210-fold/fold.py: LIVE copies by offset):
;;;;   * new            -> %210-tensor-map-spec-p, +210-tensor-map-bytes/align+,
;;;;                       %210-mark-grid-constant-tensor-maps (codegen); *210-store-transform*,
;;;;                       %210-split-transformF, %210-accumulator-kind, %210-replace-store-source,
;;;;                       %210-store-front, %210-map-store-fragment-sources, *210-pairs-only*,
;;;;                       %210-even-columns-names, %210-pairs-only-dest-p (mma);
;;;;                       %210-floating-transform-p, %210-find-store-transform (autodiff)
;;;;   * replaced       -> %tma-lookup-descriptor-ptr (codegen), %tcgen05-store-rewrite-origin,
;;;;                       %wgmma-store-rewrite-origin (mma), analyze-%store-pair-expression (control)
;;;;   * clauses        -> resolve-type-to-llvm's TENSOR-MAP clause (validation, addrspace 0);
;;;;                       generate-implicit-signature's TENSOR-MAP entry (metadata, by-value keys)
;;;;   * prepended      -> analyze-map-elements (control), generate-backward-walk (autodiff)
;;;;   * base + wrapper -> ensure-opencl-kernel-metadata (codegen), %208-analyze-store-tile(-at),
;;;;                       analyze-store-tile-mma (mma)
;;;;   * merged         -> %explode-rewrite-body-form: 196's wrapper body is the 210 wrapper's else arm
;;;;   * dropped        -> every *210-orig-* capture, the dead first copies
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

;; ---------------------------------------------------------------------------------------------------
;; conv2d_v2 / address codegen (2026-11-11): address a tensor element with a TYPED gep.
;; Before: gep inbounds i8, base, (sext idx) * sizeof(T).  The multiply hides `idx + c` from LLVM's
;; constant-offset splitting, so every load re-did its 64-bit address math (cgemm's loop: 49 IMAD per
;; 112 FFMA).  gep inbounds T, base, idx has the same address (GEP strides by T's alloc size, the same
;; number llvm-size-of returned) and lets `+ c` fold into the load's immediate offset: cgemm 218 -> 178
;; instructions per iteration, 1.55 -> 1.29 ms on the A100 (contests/gpu-mode/08-conv2d-v2/NOTES.md).
;; src/codegen.lisp
(defun %aref-tensor-ir (array-node cell-spec element-type index-val builder module var-env
                        di-builder di-scope location-map)
  "semantic-aref Case 3: a TENSOR.  The flat element index already folds in offsets and strides; the
   element pointer is a typed `getelementptr inbounds T, base, index` off the parent storage's base
   pointer (SROA field 0 of field 0) -- typed, so a constant term of the index folds into the access's
   immediate offset.  A read of a read-only kernel-parameter tensor gets !invariant.load.
   Returns (values loaded nil ptr)."
  (let* ((tensor-val     (generate-node-ir array-node builder module var-env
                                           di-builder di-scope location-map))
         (elem-type-spec element-type)
         (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
         (mangled-name   (mangle-template-struct-name (first cell-spec)
                                                      (rest cell-spec)))
         (mark-invariant-p (%array-node-readonly-tensor-param-p array-node)))
    (log:info "semantic-aref tensor: struct=~a elem=~a invariant=~a"
              mangled-name elem-type-spec mark-invariant-p)
    (ensure-struct-llvm-type mangled-name)
    (let* ((parent-val  (llvm-build-extract-value builder tensor-val 0 "t_parent_val"))
           (base-ptr    (llvm-build-extract-value builder parent-val 0 "t_base_ptr"))
           ;; flat element index already incorporates offsets and strides
           (flat-i64    (llvm-build-sext builder index-val (llvm-int64-type) "t_flat_i64")))
      (cffi:with-foreign-object (indices :pointer 1)
        (setf (cffi:mem-aref indices :pointer 0) flat-i64)
        (let* ((t-ptr  (llvm-build-in-bounds-gep2
                        builder elem-llvm-type base-ptr indices 1 "t_ptr"))
               (loaded (llvm-build-load2 builder elem-llvm-type t-ptr "t_elem")))
          (when mark-invariant-p
            (%attach-invariant-load loaded module))
          (values loaded nil t-ptr))))))

;; ===================================================================================================
;; Endeavour 213: tcgen05-accumulate-via-tile :b-major :mn -- a (K N) B tile read MN-major (2026-11-11).
;; tests/spec/213-tcgen05-transb/.  The B200 counterpart of endeavour 198 (wgmma :b-major :mn): GPU MODE
;; matmul_v2's b is (K N), and the B200 entry transposed it first (34 us of 251).
;; ===================================================================================================

;; src/mma.lisp (next to the other tcgen05 specials)
(defvar *213-tcgen05-b-mn* nil
  "Endeavour 213.  T while analyzing the %tcgen05-mma that a tcgen05-accumulate-via-tile with :b-major :mn
   rewrote to; analyze-%tcgen05-mma copies it into the node's plist as :b-mn.")

;; src/codegen.lisp (after %208-smem-desc)
(defun %213-smem-desc-mn (builder base-ptr kslice-byte-off lbo-bytes)
  "Endeavour 213.  The Blackwell shared-memory descriptor of an MN-MAJOR 16-bit operand under the 128-byte
   swizzle: 198's MN-major layout (CUTLASS Major::MN, B128 -- 64 MN elements per 128-byte row, 8 rows per
   1024-byte atom; LBO = the stride between 64-wide MN atoms = one TMA box, LBO-BYTES; SBO = the stride
   between 8-row K groups = 1024) with %208-smem-desc's Blackwell fields: VERSION 1 at [46,48) and
   SWIZZLE_128B = 2 at [61,64).  The k16 slice advances KSLICE-BYTE-OFF = 16 rows x 128 B per slice."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (logior (ash (floor lbo-bytes 16) 16) (ash (floor 1024 16) 32) (ash 1 46) (ash 2 61)))
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "tcmn_addr"))
         (addr  (if (zerop kslice-byte-off) addr0
                    (llvm-build-add builder addr0 (llvm-const-int i32 kslice-byte-off nil) "tcmn_addr_k")))
         (sh    (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "tcmn_sh"))
         (msk   (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "tcmn_start"))
         (st64  (llvm-build-zext builder msk i64 "tcmn_start64")))
    (log:debug "213 MN-major B descriptor: LBO=~a SBO=1024 kslice-off=~a" lbo-bytes kslice-byte-off)
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "tcmn_desc")))

;; src/mma.lisp
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
   tiles go to the block-scaled path first.

   Endeavour 213: :b-major :mn declares B as (K N) -- MN-major, the plain `a @ b` layout -- read with
   the instruction descriptor's transpose-B bit.  16-bit elements only (as wgmma's, endeavour 198).
   The flag reaches %tcgen05-mma's node through *213-tcgen05-b-mn*."
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
        (unless (and (symbolp bm) (member (symbol-name bm) '("K" "MN") :test #'string-equal))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major must be :k (B is (N K)) or :mn (B is (K N)); got ~s." bm)
                 :source-location location))
        (when (and (string-equal (symbol-name bm) "MN") (not (%tcgen05-16bit-elem-p elem)))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major :mn needs half or bfloat16 operands (the transpose-B bit is 16-bit only); got ~(~a~).  Stage B as (N K) instead." elem)
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
          (if (string-equal (symbol-name bm) "MN")
              (when (or (and b-r (/= b-r k)) (and b-c (/= b-c n)))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile :b-major :mn: B tile must be (K N) = (~a ~a), but it is (~a ~a)." k n (or b-r '?) (or b-c '?))
                       :source-location location))
              (when (or (and b-r (/= b-r n)) (and b-c (/= b-c k)))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile: B tile must be (N K) = (~a ~a), K-major as for wgmma, but it is (~a ~a).~:[~; A (K N) B tile is MN-major: say so with :b-major :mn.~]"
                                        n k (or b-r '?) (or b-c '?) (and (eql b-r k) (eql b-c n) (%tcgen05-16bit-elem-p elem)))
                       :source-location location))))
        (log:debug "213 tcgen05-accumulate-via-tile: b-major ~a" bm)
        (let ((*213-tcgen05-b-mn* (string-equal (symbol-name bm) "MN")))
          (analyze-expression `(set! ,d (%tcgen05-mma ,d ,a ,b ,k ,@(when bar (list bar))))
                              env context location))))))

;; src/mma.lisp
(defun analyze-%tcgen05-mma (expr env context location)
  "Endeavour 208.  (%tcgen05-mma D A B K [BAR]) -> the semantic-tcgen05-op :mma node, typed as D.
   A / B become (~ tile 0 0) so codegen's third value is the shared-memory base (as for wgmma).  A
   site without BAR is synchronous and gets its own mbarrier index in this kernel.
   Endeavour 213: :b-mn T in the plist when the enclosing accumulate said :b-major :mn."
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
                    :issue-warp (%208-issue-warp) :sync-site site :kernel key
                    :b-mn *213-tcgen05-b-mn*)
       :type d-type
       :source-location location))))

;; src/codegen.lisp
(defun %208-gen-mma-plain (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  The 16-bit / tf32 / int8 emitter (was %208-gen-mma).  D += A.B: lane 0 of the issuing warp builds the descriptors and issues K/16
   tcgen05.mma.kind::f16 (the first with enable-input-d = !FRESH, the rest accumulating), then commits
   -- to :on-complete's barrier, or to this site's own mbarrier, on which every executing thread then
   waits (parity from an entry-block visit counter) before fence::after_thread_sync.  Returns D with
   FRESH cleared.
   Endeavour 213: a :b-mn node sets the instruction descriptor's transpose-B bit (16) and reads B through
   %213-smem-desc-mn (LBO = one 64-wide TMA box of K rows, SBO 1024; the k16 slice advances 2048 bytes)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (destructuring-bind (d-node a-node b-node &optional bar-node) (semantic-tcgen05-op-args node)
      (let* ((pl     (semantic-tcgen05-op-plist node))
             (i32    (llvm-int32-type))
             (i64    (llvm-int64-type))
             (d-val  (extract-primary-value builder (gen d-node) (semantic-node-type d-node)))
             (col    (llvm-build-extract-value builder d-val 0 "tc_col"))
             (fresh  (llvm-build-extract-value builder d-val 1 "tc_fresh"))
             (a-ptr  (nth-value 2 (gen a-node)))
             (b-ptr  (nth-value 2 (gen b-node)))
             (bar-addr (and bar-node (%208-barrier-addr builder (gen bar-node))))
             (site   (getf pl :sync-site))
             (mbar-addr (and site
                             (let* ((info (%208-kernel-tc-info (getf pl :kernel)))
                                    (g (%208-sync-mbar-global module (getf pl :kernel) (getf info :sync-sites 1))))
                               (llvm-build-ptr-to-int builder (%gen-nvvm-mbar-slot-ptr builder g site) i32 "tc_sync_mbar"))))
             (tid    (%208-linear-tid builder module))
             (issuer (llvm-build-icmp builder +llvm-int-eq+ tid
                                      (llvm-const-int i32 (* 32 (getf pl :issue-warp)) nil) "tc_issuer"))
             (b-mn   (getf pl :b-mn))
             (idesc  (logior (%208-idesc (getf pl :m) (getf pl :n) (getf pl :elem) (getf pl :b-elem))
                             (if b-mn (ash 1 16) 0)))
             (kind   (%208-mma-kind (getf pl :elem)))
             (slices (floor (getf pl :k) (nth-value 1 (%208-mma-kind (getf pl :elem))))))
        ;; As for wgmma: a tf32 MMA under a non-fast precision silently does not honour IEEE.
        (when (and (string= kind "tf32") (not (eq *math-precision* :fast)))
          (format *error-output*
                  "WARNING: tcgen05-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                  *math-precision*))
        (unless (and a-ptr b-ptr)
          (error "tcgen05: A/B (~ tile 0 0) did not yield a shared-memory pointer (a ~a b ~a)" a-ptr b-ptr))
        (log:debug "208 gen mma: idesc #x~8,'0x slices ~a issue-warp ~a site ~a on-complete ~a b-mn ~a"
                   idesc slices (getf pl :issue-warp) site (and bar-node t) b-mn)
        (%208-if builder issuer
                 (lambda ()
                   (let* ((base (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base"))
                          (dt   (llvm-build-add builder base col "tc_d"))
                          (en0  (llvm-build-zext builder
                                                 (llvm-build-icmp builder +llvm-int-eq+ fresh (llvm-const-int i32 0 nil) "tc_acc")
                                                 i32 "tc_en0")))
                     (%208-asm builder "tcgen05.fence::after_thread_sync;")
                     (dotimes (kk slices)
                       (%208-asm builder
                                 (format nil "{ .reg .pred p; setp.ne.b32 p, $4, 0; tcgen05.mma.cta_group::1.kind::~a [$0], $1, $2, $3, p; }" kind)
                                 "r,l,l,r,r,~{memory}" nil (list i32 i64 i64 i32 i32)
                                 (list dt
                                       (%208-smem-desc builder a-ptr (* kk 32))
                                       (if b-mn
                                           (%213-smem-desc-mn builder b-ptr (* kk 2048) (* (getf pl :k) 128))
                                           (%208-smem-desc builder b-ptr (* kk 32)))
                                       (llvm-const-int i32 idesc nil)
                                       (if (zerop kk) en0 (llvm-const-int i32 1 nil)))))
                     (%208-commit-asm builder (or bar-addr mbar-addr))))
                 "tc_issue")
        (when site
          ;; Synchronous: every executing thread waits for this site's next phase.
          (let* ((ctr    (%208-entry-counter builder (format nil "tc_sync_ctr_~d" site)))
                 (visit  (llvm-build-load2 builder i32 ctr "tc_visit"))
                 (parity (crisp.llvm-bindings::llvm-build-and builder visit (llvm-const-int i32 1 nil) "tc_parity"))
                 (fn     (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                 (wait-bb (llvm-append-basic-block fn "tc_wait"))
                 (done-bb (llvm-append-basic-block fn "tc_wait_done")))
            (llvm-build-br builder wait-bb)
            (llvm-position-builder-at-end builder wait-bb)
            (let ((ok (%gen-nvvm-mbarrier-try-wait-parity builder mbar-addr parity)))
              (llvm-build-cond-br builder (llvm-build-icmp builder +llvm-int-ne+ ok (llvm-const-int i32 0 nil) "tc_done")
                                  done-bb wait-bb))
            (llvm-position-builder-at-end builder done-bb)
            (llvm-build-store builder (llvm-build-add builder visit (llvm-const-int i32 1 nil) "tc_visit_next") ctr)
            (%208-asm builder "tcgen05.fence::after_thread_sync;")))
        (values (llvm-build-insert-value builder d-val (llvm-const-int i32 0 nil) 1 "tc_d_used") nil)))))

;; ===================================================================================================
;; Endeavour 215: 16-byte epilogue stores for tcgen05 accumulators (2026-11-11).
;; tests/spec/215-tcgen05-vector-stores/.  The tcgen05 32x32b layout gives each thread a whole accumulator
;; ROW, but the store left as endeavour 197's 4-byte pairs: 128 st.global.b32 per thread, each warp
;; instruction touching 32 rows -- a third of the B200 matmul's scored time (226 -> 171 us with v4 stores,
;; measured by hand-edited PTX first).  New: (%run-ok-p P0 P1) and (%store-run P0..Pn-1 V0..Vn-1), and a
;; wide arm in front of the pair arm in %tcgen05-store-rewrite-origin.  The two nodes :include the 197
;; structs, so the semantic-node-type / -source-location etypecases take them unchanged; only
;; generate-node-ir has new (more specific) methods.
;; ===================================================================================================

;; src/semantic.lisp
(defstruct (semantic-store-run (:include semantic-store-pair))
  "Endeavour 215.  (%store-run P0 .. Pn-1 V0 .. Vn-1): the n values stored as 16-byte vector stores from
   P0's element address.  Only legal under a (%run-ok-p P0 P1) guard -- the lowering that emits it
   always puts it there.  Includes semantic-store-pair (PLACE-NODE = P0, LO-NODE / HI-NODE = V0 / V1,
   ELEM-BYTES), so every etypecase that knows the 197 node knows this one; VALUE-NODES holds all n."
  value-nodes)

;; src/semantic.lisp
(defstruct (semantic-run-ok-p (:include semantic-pair-ok-p))
  "Endeavour 215.  (%run-ok-p P0 P1) -> int 1 when P1's address is exactly one element past P0's (so the
   row's stride is 1 and any run from P0 is contiguous) AND P0 is 16-byte aligned, else 0.  Includes
   semantic-pair-ok-p; only its alignment mask differs.")

;; src/analysis/control.lisp
(defun analyze-%run-ok-p-expression (expr env context location)
  "Endeavour 215.  Analyzer for (%run-ok-p P0 P1), P0 / P1 aref forms naming adjacent elements of one
   storage.  Type int.  An element type that does not pack (endeavour 197's rule) analyses to the
   literal 0, so the guarded wide branch is dead and the pair / scalar arms behind it run."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error :message "%run-ok-p: expects two aref forms" :source-location location))
  (let* ((p0 (analyze-expression (second expr) env context (append location '(1))))
         (p1 (analyze-expression (third expr) env context (append location '(2))))
         (bytes (%197-pair-elem-bytes (semantic-node-type p0))))
    (log:debug "215 %run-ok-p: elem-type=~a bytes=~a" (semantic-node-type p0) bytes)
    (if (and bytes (semantic-aref-p p0) (semantic-aref-p p1))
        (make-semantic-run-ok-p :place0-node p0 :place1-node p1 :elem-bytes bytes
                                :type 'int :source-location location)
        (make-semantic-literal :value-type 'int :value 0 :source-location location))))

;; src/analysis/control.lisp
(defun analyze-%store-run-expression (expr env context location)
  "Endeavour 215.  Analyzer for (%store-run P0 .. Pn-1 V0 .. Vn-1): one semantic-store-run when every
   value already has P0's element type, that type packs, and the run is a whole number of 16-byte
   vectors; otherwise exactly (progn (set! P0 V0) ... (set! Pn-1 Vn-1)), so conversions and type errors
   are set!'s own.  Values are compared by their SINGLE-VALUE type (210's rule for :transformF calls).
   The caller guards it with (%run-ok-p P0 P1)."
  (let* ((args (rest expr))
         (n (floor (length args) 2)))
    (unless (and (evenp (length args)) (>= n 2))
      (error 'crisp-compiler-error :message "%store-run: expects (%store-run P0 .. Pn-1 V0 .. Vn-1), n >= 2"
             :source-location location))
    (let* ((place-forms (subseq args 0 n))
           (value-forms (subseq args n))
           (p0 (analyze-expression (first place-forms) env context (append location '(1))))
           (elem (semantic-node-type p0))
           (bytes (%197-pair-elem-bytes elem))
           (vals (loop for v in value-forms
                       for i from (1+ n)
                       collect (analyze-expression v env context (append location (list i))))))
      (if (and bytes (semantic-aref-p p0)
               (zerop (mod (* n bytes) 16))
               (every (lambda (v) (equal (get-single-value-type v) elem)) vals))
          (progn
            (log:debug "215 %store-run: ~a x ~a (~a bytes) -> ~a sixteen-byte store~:p"
                       n elem bytes (/ (* n bytes) 16))
            (make-semantic-store-run :place-node p0 :lo-node (first vals) :hi-node (second vals)
                                     :elem-bytes bytes :value-nodes vals
                                     :type 'nil :source-location location))
          (progn
            (log:debug "215 %store-run: falling back to ~a set!s (elem ~a, bytes ~a, value types ~a)"
                       n elem bytes (mapcar #'semantic-node-type vals))
            (analyze-expression `(progn ,@(mapcar (lambda (p v) `(set! ,p ,v)) place-forms value-forms))
                                env context location))))))

;; src/analysis/control.lisp
(defun register-197-pair-store-analyzers ()
  "Endeavour 197.  Registers %store-pair and %pair-ok-p (internal forms of the accumulator store
   lowering) in both packages, like the other % forms in register-control-analyzers.
   Endeavour 215: also %store-run / %run-ok-p (the tcgen05 store's 16-byte arm)."
  (dolist (entry (list (cons "%STORE-PAIR" #'analyze-%store-pair-expression)
                       (cons "%PAIR-OK-P"  #'analyze-%pair-ok-p-expression)
                       (cons "%STORE-RUN"  #'analyze-%store-run-expression)
                       (cons "%RUN-OK-P"   #'analyze-%run-ok-p-expression)))
    (let ((sym-cl (intern (car entry) (find-package :crisp-language)))
          (sym-cc (intern (car entry) (find-package :crisp.compiler))))
      (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
      (unless (eq sym-cl sym-cc)
        (setf (gethash sym-cc *expression-analyzers*) (cdr entry))))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-run-ok-p) builder module var-env
                              di-builder di-scope location-map)
  "Endeavour 215.  i32 (p1 - p0 == bytes) & ((p0 & 15) == 0), zero-extended like a comparison.  The
   adjacency test proves the row's stride is one element, so every run starting at P0 is contiguous."
  (let* ((bytes (semantic-run-ok-p-elem-bytes node))
         (i64 (llvm-int64-type))
         (p0 (%197-aref-element-pointer (semantic-run-ok-p-place0-node node) builder module var-env
                                         di-builder di-scope location-map "%run-ok-p"))
         (p1 (%197-aref-element-pointer (semantic-run-ok-p-place1-node node) builder module var-env
                                         di-builder di-scope location-map "%run-ok-p"))
         (a0 (llvm-build-ptr-to-int builder p0 i64 "run_a0"))
         (a1 (llvm-build-ptr-to-int builder p1 i64 "run_a1"))
         (adjacent (llvm-build-icmp builder +llvm-int-eq+ (llvm-build-sub builder a1 a0 "run_gap")
                                    (llvm-const-int i64 bytes nil) "run_adjacent"))
         (aligned (llvm-build-icmp builder +llvm-int-eq+
                                   (crisp.llvm-bindings::llvm-build-and builder a0 (llvm-const-int i64 15 nil)
                                                                         "run_misalign")
                                   (llvm-const-int i64 0 nil) "run_aligned"))
         (ok (crisp.llvm-bindings::llvm-build-and builder adjacent aligned "run_ok")))
    (log:debug "215 codegen %run-ok-p: elem-bytes=~a" bytes)
    (values (llvm-build-zext builder ok (llvm-int32-type) "run_ok_ext") nil)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-store-run) builder module var-env
                              di-builder di-scope location-map)
  "Endeavour 215.  The n values as n*bytes/16 stores of <16/bytes x T>, each aligned to 16, the k-th at
   element offset k*16/bytes from P0 (NVPTX: st.global.v4.b32 for 8 halves / bf16s or 4 floats,
   st.global.v2.b64 for 2 doubles)."
  (let* ((bytes (semantic-store-run-elem-bytes node))
         (per (floor 16 bytes))
         (ptr (%197-aref-element-pointer (semantic-store-run-place-node node) builder module var-env
                                          di-builder di-scope location-map "%store-run"))
         (vals (mapcar (lambda (vn)
                         (extract-primary-value builder (generate-node-ir vn builder module var-env
                                                                          di-builder di-scope location-map)
                                                (semantic-node-type vn)))
                       (semantic-store-run-value-nodes node)))
         (elem-ty (llvm-type-of (first vals)))
         (vec-ty (llvm-vector-type elem-ty per))
         (i32 (llvm-int32-type))
         (i64 (llvm-int64-type)))
    (loop for k from 0
          for group on vals by (lambda (l) (nthcdr per l))
          do (let ((v (llvm-get-undef vec-ty))
                   (addr (if (zerop k)
                             ptr
                             (cffi:with-foreign-object (indices :pointer 1)
                               (setf (cffi:mem-aref indices :pointer 0) (llvm-const-int i64 (* k per) nil))
                               (llvm-build-in-bounds-gep2 builder elem-ty ptr indices 1 "run_ptr")))))
               (loop for x in group
                     for i below per
                     do (setf v (llvm-build-insert-element builder v x (llvm-const-int i32 i nil) "run_elt")))
               (crisp.llvm-bindings::llvm-set-alignment (llvm-build-store builder v addr) 16)))
    (log:debug "215 codegen %store-run: ~a values, ~a x <~a x ~a-byte> align 16"
               (length vals) (floor (length vals) per) per bytes)
    (values nil nil)))

;; src/mma.lisp
(defun %tcgen05-store-rewrite-origin (tile dest row-origin col-origin n &optional convert elem)
  "Endeavour 208.  Store the 128 x N tcgen05 accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN).  Thread t of the warpgroup owns row 32(warp mod 4) + lane (Layout D: row
   m is tensor-memory lane m).  Per chunk of 32 columns: one tcgen05.ld into registers, then the
   row's 32 elements -- Endeavour 215: as 4 runs of 8 (%store-run, 16-byte vector stores) when the
   row is contiguous and the chunk's first element 16-byte aligned (%run-ok-p); else as 16 packed
   pairs (endeavour 197) when the first pair is adjacent and aligned; else as scalars.  A
   fence::after_thread_sync opens the store (the accumulator was completed by another thread's MMA)
   and a fence::before_thread_sync closes it (the next MMA into these columns must not overtake the
   reads).  CONVERT as in %wgmma-store-rewrite-origin.
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
      (log:debug "215 tcgen05 store rewrite: ~a chunk~:p of 32, wide arm (4 runs of 8) / pair arm / scalar arm"
                 chunks)
      `(let ((tcv ,tile))
         (let ((r0 (+ (,to-int ,row-origin) (+ (* (rem (,to-int (warp-id)) 4) 32) (,to-int (warp-lane)))))
               (c0 (,to-int ,col-origin)))
           (%tcgen05-fence-after)
           ,@(loop for c below chunks
                   for ch = (intern (format nil "TCROW~d" c) (find-package :crisp.compiler))
                   for base = (* 32 c)
                   collect `(let ((,ch (%tcgen05-ld tcv ,c)))
                              (,if-sym (%run-ok-p (~ ,dest r0 (+ c0 ,base)) (~ ,dest r0 (+ c0 ,(1+ base))))
                                ;; Endeavour 215: 4 runs of 8 contiguous elements, 16-byte stores.
                                (progn ,@(loop for j below 32 by 8
                                               collect `(%store-run
                                                         ,@(loop for i below 8
                                                                 collect `(~ ,dest r0 (+ c0 ,(+ base j i))))
                                                         ,@(loop for i below 8
                                                                 collect (elt-of ch (+ j i))))))
                                (,if-sym (%pair-ok-p (~ ,dest r0 (+ c0 ,base)) (~ ,dest r0 (+ c0 ,(1+ base))))
                                  (progn ,@(loop for j below 32 by 2
                                                 collect `(%store-pair (~ ,dest r0 (+ c0 ,(+ base j)))
                                                                       (~ ,dest r0 (+ c0 ,(+ base j 1)))
                                                                       ,(elt-of ch j) ,(elt-of ch (1+ j)))))
                                  (progn ,@(loop for j below 32
                                                 collect `(set! (~ ,dest r0 (+ c0 ,(+ base j))) ,(elt-of ch j))))))))
           (%tcgen05-fence-before))))))
