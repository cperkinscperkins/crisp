;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-11-11 -- the typed-GEP tensor addressing, endeavour 213 (tcgen05 :b-major :mn) and
;;;; endeavour 215 (16-byte tcgen05 epilogue stores) folded into src/ by script
;;;; (put_temp_files_here/215-fold/fold.py: LIVE copies by offset; no capture wrappers):
;;;;   * new      -> *213-tcgen05-b-mn* (mma); %213-smem-desc-mn (codegen); semantic-store-run,
;;;;                 semantic-run-ok-p (semantic, :include the 197 structs); analyze-%run-ok-p-expression,
;;;;                 analyze-%store-run-expression (analysis/control); generate-node-ir methods for
;;;;                 semantic-run-ok-p / semantic-store-run (codegen, after the 197 %store-pair method)
;;;;   * replaced -> %aref-tensor-ir, %208-gen-mma-plain (codegen); analyze-tcgen05-accumulate-via-tile-base,
;;;;                 analyze-%tcgen05-mma, %tcgen05-store-rewrite-origin (mma);
;;;;                 register-197-pair-store-analyzers (analysis/control)
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


;;;; ----------------------------------------------------------------------
;;;; Endeavour 216 -- ldmatrix for 16-bit mma.sync operand fragments read from shared memory
;;;; See tests/spec/216-ldmatrix/ldmatrix.md.
;;;; ----------------------------------------------------------------------

;; src/mma.lisp
(defvar *216-ldmatrix* t
  "Endeavour 216.  When true, a 16-bit load-fragment-a / -b whose source is an eligible shared-memory
   scratch matrix is ONE ldmatrix per fragment instead of 8 (A) / 4 (B) scalar ld.shared.b16.  NIL
   restores the per-element reads exactly -- the switch a twin-PTX A/B build flips.")

;; src/mma.lisp
(defun %216-ldmatrix-eligible-p (src probe elem operand context)
  "Endeavour 216.  T when load-fragment-OPERAND (:a or :b) of SRC (analyzed as PROBE, element ELEM) can
   be one ldmatrix: PTX, a 16-bit element, SRC a :local (shared-memory) ROW-MAJOR matrix whose static
   (ROWS COLS) are known and whose row is a multiple of 16 bytes -- ldmatrix takes each 8-element row
   segment from a 16-byte-aligned address, and a fragment's segments start at multiples of 8 columns,
   so the row pitch is the only thing that can break the alignment.  Every refusal is logged and keeps
   the per-element reads, which are correct for any layout."
  (let* ((canon (ignore-errors (%ts-canonicalize-tensor-type (get-single-value-type probe))))
         (addr (and (consp canon) (>= (length canon) 4) (fourth canon)))
         (ct (and canon (%get-tensor-ct canon)))
         (dims (ignore-errors (%198-tile-static-dims src 2 context)))
         (why (cond ((not *216-ldmatrix*) "disabled")
                    ((eq *target-backend* :spirv) "SPIR-V")
                    ((not (eql (%mma-elem-bits elem) 16)) "not a 16-bit element")
                    ((not (and addr (symbolp addr) (string= (symbol-name addr) "LOCAL"))) "not shared memory")
                    ((not (and ct (symbolp ct) (string= (symbol-name ct) "LAST"))) "not row-major")
                    ((null dims) "no static tile dims")
                    ((/= 0 (mod (* 2 (second dims)) 16)) "row pitch not a multiple of 16 bytes"))))
    (log:debug "216 ldmatrix ~a ~a: canon=~a dims=~a -> ~a" operand src canon dims (or why "ELIGIBLE"))
    (null why)))

;; src/mma.lisp
(defun %216-ldmatrix-node (operand src probe elem coords env context location)
  "Endeavour 216.  The semantic-hw-op for one ldmatrix fragment load.  Lane L supplies one 16-byte row
   address; ldmatrix hands each lane, per 8x8 matrix, row L/4 columns 2(L%4), 2(L%4)+1 -- the mma.sync
   pair (groupID, 2*tid) -- in one .b32 register, low column in the low half.

     :a  x4, matrices in Ra0..Ra3 order: (rows +0, cols +0) (rows +8, cols +0) (rows +0, cols +8)
         (rows +8, cols +8) of the 16x16 tile at (16 TY, 16 TK).  Lane L: row 16 TY + L%8 + 8((L/8)%2),
         col 16 TK + 8(L/16).
     :b  x2.trans on the row-major (K N) tile: matrices k +0 and k +8 at column 8 TX.  .trans gives lane
         L rows 2(L%4), 2(L%4)+1 of column L/4 -- the B pair (2*tid, groupID).  Lane L (L%16 used):
         row 16 TK + L%8 + 8((L/8)%2), col 8 TX."
  (let* ((lane '(to-int (warp-lane)))
         ;; A's row and B's K row follow the same rule: 16 per tile step, lane%8 within a matrix, and
         ;; +8 for the odd matrices (lanes 8-15, 24-31).
         (r-form `(+ (* ,(first coords) 16) (rem ,lane 8) (* (rem (/ ,lane 8) 2) 8)))
         (c-form (ecase operand
                   (:a `(+ (* ,(second coords) 16) (* (/ ,lane 16) 8)))
                   (:b `(* ,(second coords) 8))))
         (r-node (analyze-expression r-form env context (append location '(2))))
         (c-node (analyze-expression c-form env context (append location '(3))))
         (rec (%nvvm-frag-record operand elem)))
    (log:info "216: load-fragment-~(~a~) ~a ~a -> ldmatrix (~a)" operand src coords rec)
    (make-semantic-hw-op :op (ecase operand (:a '%216-ldmatrix-a) (:b '%216-ldmatrix-b))
                         :args (list probe r-node c-node)
                         :type rec
                         :source-location location)))

;; src/mma.lisp
(defvar *216-orig-analyze-load-fragment-a* (fdefinition 'analyze-load-fragment-a))
;; src/mma.lisp
(defvar *216-orig-analyze-load-fragment-b* (fdefinition 'analyze-load-fragment-b))

;; src/mma.lisp
(defun analyze-load-fragment-a (expr env context location)
  "Endeavour 216 wrapper: a 16-bit A fragment from an eligible shared-memory scratch matrix is one
   ldmatrix.x4 (%216-ldmatrix-node); everything else is the per-element read below it (the wrapped
   original, *216-orig-analyze-load-fragment-a*)."
  (destructuring-bind (src tile-id) (cdr expr)
    (if (eq *target-backend* :spirv)
        (funcall *216-orig-analyze-load-fragment-a* expr env context location)
        (let* ((probe (analyze-expression src env context (append location '(1))))
               (elem (%coop-elem-of probe)))
          (if (%216-ldmatrix-eligible-p src probe elem :a context)
              (%216-ldmatrix-node :a src probe elem tile-id env context location)
              (funcall *216-orig-analyze-load-fragment-a* expr env context location))))))

;; src/mma.lisp
(defun analyze-load-fragment-b (expr env context location)
  "Endeavour 216 wrapper: a 16-bit B fragment from an eligible row-major (K N) shared-memory scratch
   matrix is one ldmatrix.x2.trans (%216-ldmatrix-node); everything else is the per-element read (the
   wrapped original, *216-orig-analyze-load-fragment-b*)."
  (destructuring-bind (src tile-id) (cdr expr)
    (if (eq *target-backend* :spirv)
        (funcall *216-orig-analyze-load-fragment-b* expr env context location)
        (let* ((probe (analyze-expression src env context (append location '(1))))
               (elem (%coop-elem-of probe)))
          (if (%216-ldmatrix-eligible-p src probe elem :b context)
              (%216-ldmatrix-node :b src probe elem tile-id env context location)
              (funcall *216-orig-analyze-load-fragment-b* expr env context location))))))

;; src/mma.lisp
(defun %216-to-i64 (builder v)
  "Endeavour 216.  Integer LLVM value V widened (sign-extended) to i64; an i64 passes through."
  (let ((i64 (crisp.llvm-bindings::llvm-int64-type)))
    (if (= (crisp.llvm-bindings::llvm-get-int-type-width (crisp.llvm-bindings::llvm-type-of v)) 64)
        v
        (crisp.llvm-bindings::llvm-build-sext builder v i64 "ldm_i64"))))

;; src/mma.lisp
(defun %216-shared-elem-ptr (builder tensor-val r c elem-llvm)
  "Endeavour 216.  The shared-memory address of element (R, C) of the scratch matrix TENSOR-VAL (a Crisp
   tensor struct: field 0 = storage {ptr, i64}, field 2 = strides), as R*s0 + C*s1 elements of ELEM-LLVM
   from the base -- the addressing %coop-tensor-ptr+stride-impl uses.  A base outside addrspace(3) is a
   bug upstream of here, so it is refused rather than cast."
  (let* ((storage (llvm-build-extract-value builder tensor-val 0 "ldm_storage"))
         (base    (llvm-build-extract-value builder storage 0 "ldm_base"))
         (strides (llvm-build-extract-value builder tensor-val 2 "ldm_strides"))
         (s0 (llvm-build-extract-value builder strides 0 "ldm_s0"))
         (s1 (llvm-build-extract-value builder strides 1 "ldm_s1"))
         (flat (llvm-build-add builder
                               (llvm-build-mul builder (%216-to-i64 builder r) s0 "ldm_r")
                               (llvm-build-mul builder (%216-to-i64 builder c) s1 "ldm_c")
                               "ldm_flat")))
    (unless (= (%ptr-as base) 3)
      (error 'crisp-compiler-error
             :message (format nil "Endeavour 216 internal: ldmatrix source base is in addrspace(~a), not shared memory (3)." (%ptr-as base))))
    (cffi:with-foreign-object (idx :pointer 1)
      (setf (cffi:mem-aref idx :pointer 0) flat)
      (llvm-build-gep2 builder elem-llvm base idx 1 "ldm_ptr"))))

;; src/mma.lisp
(defun %216-ldmatrix-lower (builder module arg-vals result-type nregs trans)
  "Endeavour 216.  One ldmatrix.sync.aligned.m8n8.{x4,x2}[.trans].shared.b16 into the fragment record
   RESULT-TYPE: NREGS .b32 registers, each split into the record's two 16-bit fields in order (element 0
   of the <2 x half> = the low half = the lower column / row).  %emit-nvvm-mma re-packs those pairs, and
   LLVM folds the split and the re-pack away."
  (destructuring-bind (tensor-val r c) arg-vals
    (let* ((rec-ty (crisp-type-to-llvm-type result-type module))
           (elem-llvm (llvm-type-of (llvm-build-extract-value builder (llvm-get-undef rec-ty) 0 "ldm_probe")))
           (i32 (llvm-int32-type))
           (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count nregs)))
                     (dotimes (i nregs) (setf (cffi:mem-aref elts 'llvm-type-ref i) i32))
                     (llvm-struct-type-in-context (llvm-get-module-context module) elts nregs nil)))
           (name (format nil "llvm.nvvm.ldmatrix.sync.aligned.m8n8.x~d~:[~;.trans~].b16.p3" nregs trans))
           (ptr (%216-shared-elem-ptr builder tensor-val r c elem-llvm))
           (call (%coop-call builder module name ret-ty (list (llvm-type-of ptr)) (list ptr)))
           (v2 (llvm-vector-type elem-llvm 2))
           (agg (llvm-get-undef rec-ty)))
      (dotimes (i nregs)
        (let ((pair (llvm-build-bit-cast builder (llvm-build-extract-value builder call i (format nil "ldm_r~d" i))
                                         v2 (format nil "ldm_v~d" i))))
          (dotimes (h 2)
            (setf agg (llvm-build-insert-value
                       builder agg
                       (llvm-build-extract-element builder pair (llvm-const-int i32 h nil) (format nil "ldm_e~d~d" i h))
                       (+ (* 2 i) h) (format nil "ldm_f~d" (+ (* 2 i) h)))))))
      (log:debug "216 %216-ldmatrix-lower: ~a -> ~a" name result-type)
      agg)))

;; src/mma.lisp
(defmethod %hw-lower ((op (eql '%216-ldmatrix-a)) builder module arg-vals arg-types result-type)
  "Endeavour 216: load-fragment-a as ldmatrix.x4 (see %216-ldmatrix-node)."
  (declare (ignore arg-types))
  (%216-ldmatrix-lower builder module arg-vals result-type 4 nil))

;; src/mma.lisp
(defmethod %hw-lower ((op (eql '%216-ldmatrix-b)) builder module arg-vals arg-types result-type)
  "Endeavour 216: load-fragment-b as ldmatrix.x2.trans (see %216-ldmatrix-node)."
  (declare (ignore arg-types))
  (%216-ldmatrix-lower builder module arg-vals result-type 2 t))

;; src/mma.lisp
(defun %216-ldmatrix-eligible-p (src probe elem operand context)
  "Endeavour 216.  T when load-fragment-OPERAND (:a or :b) of SRC (analyzed as PROBE, element ELEM) can
   be one ldmatrix: PTX, a 16-bit element, SRC a :local (shared-memory) :COMPACT ROW-MAJOR matrix whose
   static (ROWS COLS) are known and whose row is a multiple of 16 bytes -- ldmatrix takes each 8-element
   row segment from a 16-byte-aligned address, and a fragment's segments start at multiples of 8 columns,
   so the row pitch is the only thing that can break the alignment.

   :COMPACT is checked on its own because a (transpose X) view keeps X's contiguous-term (:last) and marks
   only its alignment slot :strided -- its rows are NOT contiguous, and ldmatrix would read X's rows
   instead.  (Such a view also has no static scratch dims today, so it was refused already, but only by
   accident.)  Every refusal is logged and keeps the per-element reads, which are correct for any layout."
  (let* ((canon (ignore-errors (%ts-canonicalize-tensor-type (get-single-value-type probe))))
         (addr (and (consp canon) (>= (length canon) 4) (fourth canon)))
         (aln (and (consp canon) (>= (length canon) 5) (fifth canon)))
         (ct (and canon (%get-tensor-ct canon)))
         (dims (ignore-errors (%198-tile-static-dims src 2 context)))
         (why (cond ((not *216-ldmatrix*) "disabled")
                    ((eq *target-backend* :spirv) "SPIR-V")
                    ((not (eql (%mma-elem-bits elem) 16)) "not a 16-bit element")
                    ((not (and addr (symbolp addr) (string= (symbol-name addr) "LOCAL"))) "not shared memory")
                    ((not (and aln (symbolp aln) (string= (symbol-name aln) "COMPACT"))) "not compact (a strided view)")
                    ((not (and ct (symbolp ct) (string= (symbol-name ct) "LAST"))) "not row-major")
                    ((null dims) "no static tile dims")
                    ((/= 0 (mod (* 2 (second dims)) 16)) "row pitch not a multiple of 16 bytes"))))
    (log:debug "216 ldmatrix ~a ~a: canon=~a dims=~a -> ~a" operand src canon dims (or why "ELIGIBLE"))
    (null why)))

;;; ===================================================================================================
;;; Endeavour 217 -- compiler-owned XOR swizzle of the shared-memory tiles an ldmatrix reads.
;;; Plan and inventory: tests/spec/217-swizzle/swizzle.md.
;;; ===================================================================================================

;; src/mma.lisp
(defun %217-swizzle-shift (pitch-bytes tile-bytes)
  "Endeavour 217.  The swizzle shift S for a shared-memory tile whose rows are PITCH-BYTES apart and whose
   whole extent is TILE-BYTES, or NIL when the tile is not swizzled.

   The swizzle (see %217-swizzle-offset) XORs bits 4-6 of a byte offset with bits S..S+2, so it permutes
   the 16-byte chunks inside every aligned 2^(S+3)-byte block.  S = max(7, log2 PITCH): from S up, the
   offset bits count rows (or groups of rows sharing a 128-byte line), so the 8 rows an ldmatrix phase
   reads land in 8 different 16-byte bank groups.  Requires a power-of-two PITCH of at least 32 bytes (a
   16-byte pitch already puts 8 rows in 8 groups) and a tile that is a whole number of blocks, so the map
   is a bijection of the tile onto itself."
  (let ((s (and (integerp pitch-bytes) (integerp tile-bytes) (plusp tile-bytes)
                (>= pitch-bytes 32) (= (logcount pitch-bytes) 1)
                (max 7 (1- (integer-length pitch-bytes))))))
    (and s (zerop (mod tile-bytes (ash 1 (+ s 3)))) s)))

;; src/mma.lisp
(defun %217-swizzle-offset (off s)
  "Endeavour 217.  Byte offset OFF (from the tile / ring-slot base) under the swizzle with shift S:
   OFF xor (((OFF >> S) & 7) << 4).  Only bits 4-6 change, so a 16-byte chunk stays whole and aligned.
   The compile-time twin of the IR %217-swizzle-ptr emits; the unit spec checks its claims."
  (logxor off (ash (ldb (byte 3 s) off) 4)))

;;; ---- Endeavour 217 rungs 3-5: decide at the scratch LET, propagate through aliases, tag, address ----
;;; Mechanism = D-217-6 (swizzle.md): decide at the scratch LET with a whitelist scan of the body, publish
;;; ((SYM . S) ..) in *217-swizzled-names*, propagate through LET aliases (the *194-lane-index-names*
;;; pattern), tag aref array nodes / ldmatrix hw-ops at analysis, swizzle in the two PTX choke points
;;; (%aref-tensor-ir, %216-shared-elem-ptr) the rung-2 inventory proved.  Wrappers are marked with their
;;; fold target; at fold they become a few lines inside the wrapped function.

;; src/mma.lisp
(defvar *217-swizzle* t
  "Endeavour 217.  NIL turns the compiler-owned swizzle of ldmatrix scratch tiles off (twin builds).")

;; src/mma.lisp
(defvar *217-swizzled-names* nil
  "Endeavour 217.  ((SYM . S) ...): the scratch bindings (and their LET aliases) in scope whose tiles are
   XOR-swizzled with shift S.  Bound by analyze-let-with-tile-explosion (decisions) and
   analyze-let-expression (aliases).")

;; src/mma.lisp
(defvar *217-node-shift* (make-hash-table :test 'eq :weakness :key)
  "Endeavour 217.  semantic node -> S: an aref's array node, or an ldmatrix hw-op, that addresses a
   swizzled tile.")

;; src/mma.lisp
(defvar *217-shift* nil "Endeavour 217.  Bound around an ldmatrix hw-op's codegen: its S, or NIL.")

;;; ---- the shape side -------------------------------------------------------------------------------

;; src/mma.lisp
(defun %217-tile-ref-name (form names)
  "Endeavour 217.  The swizzled name FORM refers to -- FORM is a name in NAMES, or (ring-get NAME i) of
   one -- or NIL."
  (cond ((and (symbolp form) form (assoc form names)) form)
        ((and (consp form) (%head-name-eq (first form) "RING-GET") (symbolp (second form))
              (assoc (second form) names))
         (second form))))

;; src/mma.lisp
(defun %217-form-shift (form)
  "Endeavour 217.  S when FORM addresses a swizzled tile in the current scope, else NIL."
  (let ((name (%217-tile-ref-name form *217-swizzled-names*)))
    (and name (cdr (assoc name *217-swizzled-names*)))))

;; src/mma.lisp
(defun %217-binding-shift (binding)
  "Endeavour 217.  S for a (V (make-scratch-matrix[-ring] ELEM (ROWS COLS) ...)) BINDING whose tile the
   rule can swizzle, or NIL with the reason as a second value."
  (let* ((init (second binding))
         (elem (second init))
         (dims (third init))
         (bits (ignore-errors (%mma-elem-bits elem))))
    (cond ((not (and (listp dims) (= (length dims) 2) (every #'integerp dims))) (values nil "no literal (ROWS COLS)"))
          ((not (eql bits 16)) (values nil (format nil "~a is not a 16-bit element" elem)))
          (t (let* ((pitch (* 2 (second dims)))
                    (s (%217-swizzle-shift pitch (* pitch (first dims)))))
               (if s (values s nil)
                   (values nil (format nil "~ax~a: pitch ~a B / ~a B not swizzlable" (first dims) (second dims)
                                       pitch (* pitch (first dims))))))))))

;;; ---- the use side: whole-body scan --------------------------------------------------------------

;; src/mma.lisp
(defun %217-block-barrier-names (bindings)
  "Endeavour 217.  Names bound in BINDINGS to a :block / :cluster (TMA) barrier or barrier ring."
  (loop for b in bindings
        when (and (consp b) (symbolp (first b)) (consp (second b))
                  (or (%head-name-eq (first (second b)) "MAKE-ASYNC-BARRIER")
                      (%head-name-eq (first (second b)) "MAKE-ASYNC-BARRIER-RING"))
                  (let ((m (second (member :mode (cdr (second b))))))
                    (and m (symbolp m) (member (symbol-name m) '("BLOCK" "CLUSTER") :test #'string=))))
          collect (first b)))

;; src/mma.lisp
(defun %217-scan-uses (form refs tma-barriers)
  "Endeavour 217.  Walk FORM for the uses of the tile REFS (its name plus LET aliases).  Returns
   (values READER-P REFUSAL): READER-P when an mma-accumulate-via-tile takes the tile as an operand;
   REFUSAL a string naming the first use outside the whitelist --
     (~ / aref TILE i..)                      element access: the aref path swizzles
     (load-tile[-at] SRC TILE ..)             unless its barrier is :block (TMA writes the plain layout)
     (store-tile[-at] TILE DST ..)            unless :via (TMA store)
     (mma-accumulate-via-tile SHAPE C A B ..) the reader (ldmatrix) -- and (load-fragment-a/b TILE (i j) ..),
                                              what the register-tile explosion has turned it into
     (extents~ / strides~ TILE ..)            struct fields, no addressing
     (let ((ALIAS TILE)) ..)                  the alias joins REFS
   and (ring-get TILE i) in any of those TILE positions.  Anything else (a function call, a view, a
   transpose, a whole-tile set!, a shadowing rebinding) refuses: the tile stays plain."
  (let ((reader nil) (refusal nil))
    (labels ((ref-p (x refs) (%217-tile-ref-name x (mapcar #'list refs)))
             (refuse (fmt &rest args) (unless refusal (setf refusal (apply #'format nil fmt args))))
             (walk-args (args refs) (dolist (a args) (walk a refs)))
             (walk (f refs)
               (cond
                 (refusal nil)
                 ((atom f) (when (and (symbolp f) (member f refs)) (refuse "bare reference to ~a" f)))
                 ((not (symbolp (first f))) (walk-args f refs))
                 (t
                  (let ((h (symbol-name (first f))) (args (rest f)))
                    (cond
                      ((member h '("QUOTE" "DECLARE") :test #'string=) nil)
                      ((member h '("~" "AREF" "~REF~" "EXTENTS~" "STRIDES~") :test #'string=)
                       (if (ref-p (first args) refs) (walk-args (rest args) refs) (walk-args args refs)))
                      ((member h '("LOAD-TILE" "LOAD-TILE-AT") :test #'string=)
                       (when (ref-p (second args) refs)
                         (let ((bar (getf (cdddr args) :barrier)))
                           (when (and bar (%217-tile-ref-name bar (mapcar #'list tma-barriers)))
                             (refuse "filled by a :block (TMA) load-tile"))))
                       (walk (first args) refs)
                       (unless (ref-p (second args) refs) (walk (second args) refs))
                       (walk-args (cddr args) refs))
                      ((member h '("STORE-TILE" "STORE-TILE-AT") :test #'string=)
                       (when (ref-p (first args) refs)
                         (when (getf (cdddr args) :via) (refuse "read by a store-tile :via (TMA)")))
                       (unless (ref-p (first args) refs) (walk (first args) refs))
                       (walk-args (rest args) refs))
                      ((member h '("LOAD-FRAGMENT-A" "LOAD-FRAGMENT-B") :test #'string=)
                       (if (ref-p (first args) refs) (setf reader t) (walk (first args) refs))
                       (walk-args (rest args) refs))
                      ((string= h "MMA-ACCUMULATE-VIA-TILE")
                       (dolist (a (cddr args))
                         (if (ref-p a refs) (setf reader t) (walk a refs))))
                      ((member h '("LET" "LET*") :test #'string=)
                       (let ((inner refs))
                         (dolist (b (and (listp (first args)) (first args)))
                           (let ((name (if (consp b) (first b) b)) (init (and (consp b) (second b))))
                             (cond ((ref-p init inner) (push name inner))
                                   (t (walk init inner)
                                      (when (member name inner) (refuse "~a is rebound" name))))))
                         (walk-args (rest args) inner)))
                      (t (dolist (a args)
                           (if (ref-p a refs)
                               (refuse "passed to (~(~a~) ..)" h)
                               (walk a refs))))))))))
      (walk-args form refs))
    (values reader refusal)))

;; src/mma.lisp
(defun %217-let-swizzle-decisions (let-expr)
  "Endeavour 217.  ((SYM . S) ...) for the scratch bindings of LET-EXPR whose tiles are XOR-swizzled
   (see the header and swizzle.md), every decision and refusal logged."
  (when (and *217-swizzle* *216-ldmatrix* (eq *target-backend* :ptx)
             (consp let-expr) (listp (second let-expr)))
    (let* ((bindings (second let-expr))
           (body (cddr let-expr))
           (tma (%217-block-barrier-names bindings)))
      (loop for b in bindings
            when (and (consp b) (= (length b) 2) (symbolp (first b)) (consp (second b))
                      (or (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX")
                          (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX-RING")))
              append (multiple-value-bind (s why) (%217-binding-shift b)
                       (multiple-value-bind (reader refusal)
                           (if s (%217-scan-uses body (list (first b)) tma) (values nil nil))
                         (let ((why (or why refusal (and (not reader) "no mma-accumulate-via-tile reads it"))))
                           (log:info "217 swizzle ~a: ~a" (first b) (if why (format nil "plain -- ~a" why)
                                                                         (format nil "S = ~a" s)))
                           (and (null why) (list (cons (first b) s))))))))))

;;; ---- analysis hooks -----------------------------------------------------------------------------

;; src/mma.lisp  (re-definition: one added binding of *217-swizzled-names*)
(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: pre-lower register-tile matrix-multiply-tile-stride (endeavor 135),
   then explode register-tile bindings into per-fragment mutable variables (register residency,
   Endeavor 132), then defer to the normal let analysis.

   Endeavour 161: publishes this LET's compile-time SLM scratch-tile shapes for the duration of
   the body analysis, so operand-shape checks in the expression analyzers can see them.

   Endeavour 207: first checks the qint roles of every MMA in the LET (%qint-mma-walk), while the
   source element types are still visible.

   Endeavour 217: decides which of this LET's scratch tiles are XOR-swizzled and publishes them in
   *217-swizzled-names* for the body (%217-let-swizzle-decisions)."
  (%qint-mma-walk expr nil env location)
  (let ((lowered (%explode-register-tiles
                  (%expand-matmul-tile-stride-register-forms expr location)
                  location context)))
    (let ((*mma-scratch-tile-dims*
            (append (and (consp lowered)
                         (listp (second lowered))
                         (%mma-scratch-tile-dims-from-bindings (second lowered)))
                    *mma-scratch-tile-dims*))
          ;; this LET's own names shadow any outer swizzled binding of the same name
          (*217-swizzled-names*
            (append (%217-let-swizzle-decisions lowered)
                    (remove-if (lambda (e) (and (consp lowered) (listp (second lowered))
                                                (member (car e) (second lowered)
                                                        :key (lambda (b) (if (consp b) (first b) b)))))
                               *217-swizzled-names*))))
      (analyze-let-expression lowered env context location))))

;; src/analysis/control.lisp  (wrapper; fold: the same few lines at the top of analyze-let-expression,
;; beside the *194-lane-index-names* tracking)
(defvar *217-orig-analyze-let* (fdefinition 'analyze-let-expression))
(defun analyze-let-expression (expr env context location)
  "Endeavour 217 wrapper around the let analyzer: a binding whose init is a swizzled tile (or a ring-get
   of a swizzled ring) is swizzled too, for the body; rebinding a swizzled name to anything else hides it.
   Sequential, like the let."
  (if (null *217-swizzled-names*)
      (funcall *217-orig-analyze-let* expr env context location)
      (let ((names *217-swizzled-names*))
        (dolist (b (and (consp (cdr expr)) (listp (second expr)) (second expr)))
          (let ((name (if (consp b) (first b) b))
                (init (and (consp b) (second b))))
            (when (and name (symbolp name)
                       ;; a scratch binding's own decision was made by analyze-let-with-tile-explosion
                       (not (and (consp init)
                                 (or (%head-name-eq (first init) "MAKE-SCRATCH-MATRIX")
                                     (%head-name-eq (first init) "MAKE-SCRATCH-MATRIX-RING")))))
              (let ((src (%217-tile-ref-name init names)))
                (setf names (remove name names :key #'car))
                (when src
                  (log:debug "217 alias ~a -> ~a" name src)
                  (push (cons name (cdr (assoc src names))) names))))))
        (let ((*217-swizzled-names* names))
          (funcall *217-orig-analyze-let* expr env context location)))))

;; src/analysis/structs.lisp  (wrapper; fold: tag inside the tensor path of analyze-aref-expression)
(defvar *217-orig-analyze-aref* (fdefinition 'analyze-aref-expression))
(defun analyze-aref-expression (expr env context location)
  "Endeavour 217 wrapper: an element access of a swizzled tile records S on its array node, for
   %aref-tensor-ir."
  (let ((node (funcall *217-orig-analyze-aref* expr env context location))
        (s (and *217-swizzled-names* (%217-form-shift (second expr)))))
    (when s
      (if (semantic-aref-p node)
          (progn (setf (gethash (semantic-aref-array-node node) *217-node-shift*) s)
                 (log:debug "217 aref of ~a: S = ~a" (second expr) s))
          (error 'crisp-compiler-error
                 :message (format nil "Endeavour 217 internal: an access of the swizzled tile ~a did not analyze to an aref (~a)."
                                  (second expr) (type-of node))
                 :source-location location)))
    node))

;; src/mma.lisp  (wrapper; fold: in %216-ldmatrix-node)
(defvar *217-orig-ldm-node* (fdefinition '%216-ldmatrix-node))
(defun %216-ldmatrix-node (operand src probe elem coords env context location)
  "Endeavour 217 wrapper: an ldmatrix of a swizzled tile records S on its hw-op node."
  (let ((node (funcall *217-orig-ldm-node* operand src probe elem coords env context location))
        (s (%217-form-shift src)))
    (when s
      (setf (gethash node *217-node-shift*) s)
      (log:debug "217 ldmatrix ~(~a~) of ~a: S = ~a" operand src s))
    node))

;; src/analysis/control.lisp  (guard: a TMA fill of a swizzled tile is a compiler bug, never silent)
(defvar *217-orig-tma-load* (fdefinition '%analyze-nvvm-tma-load-tile-at))
(defun %analyze-nvvm-tma-load-tile-at (expr env context location)
  "Endeavour 217 guard around the TMA load-tile analyzer: its destination must not be a swizzled tile."
  (when (%217-form-shift (third expr))
    (error 'crisp-compiler-error
           :message (format nil "Endeavour 217 internal: TMA load-tile into the swizzled tile ~a." (third expr))
           :source-location location))
  (funcall *217-orig-tma-load* expr env context location))

;;; ---- codegen ------------------------------------------------------------------------------------

;; src/mma.lisp
(defun %217-swizzle-gep (builder base off-bytes s)
  "Endeavour 217.  BASE + swizzle(OFF-BYTES) as an i8 GEP: OFF xor (((OFF >> S) & 7) << 4), OFF-BYTES an
   i64 byte offset from the tile / ring-slot base.  The IR twin of %217-swizzle-offset."
  (let* ((i64 (llvm-int64-type))
         (row (crisp.llvm-bindings::llvm-build-and
               builder
               (crisp.llvm-bindings::llvm-build-l-shr builder off-bytes (llvm-const-int i64 s nil) "swz_sh")
               (llvm-const-int i64 7 nil) "swz_row"))
         (off2 (crisp.llvm-bindings::llvm-build-xor
                builder off-bytes
                (crisp.llvm-bindings::llvm-build-shl builder row (llvm-const-int i64 4 nil) "swz_x")
                "swz_off")))
    (cffi:with-foreign-object (idx :pointer 1)
      (setf (cffi:mem-aref idx :pointer 0) off2)
      (llvm-build-in-bounds-gep2 builder (llvm-int8-type) base idx 1 "swz_ptr"))))

;; src/codegen.lisp  (re-definition: the swizzled branch)
(defun %aref-tensor-ir (array-node cell-spec element-type index-val builder module var-env
                        di-builder di-scope location-map)
  "semantic-aref Case 3: a TENSOR.  The flat element index already folds in offsets and strides; the
   element pointer is a typed `getelementptr inbounds T, base, index` off the parent storage's base
   pointer (SROA field 0 of field 0) -- typed, so a constant term of the index folds into the access's
   immediate offset.  A read of a read-only kernel-parameter tensor gets !invariant.load.
   Endeavour 217: when ARRAY-NODE addresses a swizzled tile (*217-node-shift*), the byte offset is
   swizzled first (%217-swizzle-gep).
   Returns (values loaded nil ptr)."
  (let* ((tensor-val     (generate-node-ir array-node builder module var-env
                                           di-builder di-scope location-map))
         (elem-type-spec element-type)
         (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
         (mangled-name   (mangle-template-struct-name (first cell-spec)
                                                      (rest cell-spec)))
         (mark-invariant-p (%array-node-readonly-tensor-param-p array-node))
         (swz (gethash array-node *217-node-shift*)))
    (log:info "semantic-aref tensor: struct=~a elem=~a invariant=~a swizzle=~a"
              mangled-name elem-type-spec mark-invariant-p swz)
    (ensure-struct-llvm-type mangled-name)
    (let* ((parent-val  (llvm-build-extract-value builder tensor-val 0 "t_parent_val"))
           (base-ptr    (llvm-build-extract-value builder parent-val 0 "t_base_ptr"))
           ;; flat element index already incorporates offsets and strides
           (flat-i64    (llvm-build-sext builder index-val (llvm-int64-type) "t_flat_i64")))
      (when (and swz (/= (%ptr-as base-ptr) 3))
        (error 'crisp-compiler-error
               :message (format nil "Endeavour 217 internal: a swizzled tile's base is in addrspace(~a), not shared memory (3)."
                                (%ptr-as base-ptr))))
      (cffi:with-foreign-object (indices :pointer 1)
        (setf (cffi:mem-aref indices :pointer 0) flat-i64)
        (let* ((t-ptr  (if swz
                           (%217-swizzle-gep builder base-ptr
                                             (llvm-build-mul builder flat-i64 (llvm-size-of elem-llvm-type) "swz_bytes")
                                             swz)
                           (llvm-build-in-bounds-gep2
                            builder elem-llvm-type base-ptr indices 1 "t_ptr")))
               (loaded (llvm-build-load2 builder elem-llvm-type t-ptr "t_elem")))
          (when mark-invariant-p
            (%attach-invariant-load loaded module))
          (values loaded nil t-ptr))))))

;; src/mma.lisp  (re-definition of the 216 overlay copy: the swizzled branch)
(defun %216-shared-elem-ptr (builder tensor-val r c elem-llvm)
  "Endeavour 216.  The shared-memory address of element (R, C) of the 2-D tile TENSOR-VAL: base + (R*s0 +
   C*s1) elements.  Endeavour 217: swizzled when the ldmatrix being lowered reads a swizzled tile
   (*217-shift*, bound by the semantic-hw-op :around)."
  (let* ((storage (llvm-build-extract-value builder tensor-val 0 "ldm_storage"))
         (base    (llvm-build-extract-value builder storage 0 "ldm_base"))
         (strides (llvm-build-extract-value builder tensor-val 2 "ldm_strides"))
         (s0 (llvm-build-extract-value builder strides 0 "ldm_s0"))
         (s1 (llvm-build-extract-value builder strides 1 "ldm_s1"))
         (flat (llvm-build-add builder
                               (llvm-build-mul builder (%216-to-i64 builder r) s0 "ldm_r")
                               (llvm-build-mul builder (%216-to-i64 builder c) s1 "ldm_c")
                               "ldm_flat")))
    (unless (= (%ptr-as base) 3)
      (error 'crisp-compiler-error
             :message (format nil "Endeavour 216 internal: ldmatrix source base is in addrspace(~a), not shared memory (3)." (%ptr-as base))))
    (if *217-shift*
        (%217-swizzle-gep builder base (llvm-build-mul builder flat (llvm-size-of elem-llvm) "ldm_bytes") *217-shift*)
        (cffi:with-foreign-object (idx :pointer 1)
          (setf (cffi:mem-aref idx :pointer 0) flat)
          (llvm-build-gep2 builder elem-llvm base idx 1 "ldm_ptr")))))

;; src/mma.lisp
(defmethod generate-node-ir :around ((node semantic-hw-op) builder module var-env
                                     di-builder di-scope location-map)
  "Endeavour 217: expose a swizzled ldmatrix's shift to %216-shared-elem-ptr."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (let ((*217-shift* (gethash node *217-node-shift*)))
    (call-next-method)))
