;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
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

;;;; =====================================================================================
;;;; Endeavour 211 -- shift-left / shift-right / rotate-left / rotate-right
;;;; (plan/proposal-warp-ballot-and-shifts.md; tests/spec/211-shift-rotate/)
;;;; =====================================================================================

;; src/autodiff.lisp  (whole-function copy, script-extracted; only change: the 211 names join the
;; integer-operator list -- integer results carry no gradient)
(defun %185-math-backward (v expr emit-fn local-adj-fn)
  "Backward rules for the endeavour-185 P1 ops, matched by NAME.  Returns T when EXPR is one of
   them (the clause handled it), else NIL.
   Endeavour 206: %mf-block-scale is a constant and %mf-ste is straight-through."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x))
         (sym (n) (%185-crisp-sym n)))
    (let ((op (car expr)))
      (cond
        ;; Endeavour 206: (%mf-block-scale ..) is a constant; (%mf-ste NAME X SV) passes V's adjoint to X.
        ((%185-op-named-p op "%MF-BLOCK-SCALE") t)
        ((%185-op-named-p op "%MF-STE")
         (let ((x (third expr)))
           (when (symbolp x)
             (funcall emit-fn `(set! ,(funcall local-adj-fn x)
                                     (+ ,(funcall local-adj-fn x) ,(funcall local-adj-fn v)))))
           t))
        ((and (%qint-narrowing-target op) (= (length expr) 2)) ; endeavour 205: a raw cast truncates
         (when (symbolp (cadr expr))           ; here, not the skip list: q-int ends in INT, a silent zero
           (error 'crisp-compiler-error
                  :message (format nil "(~(~a~) ~(~a~)): a raw cast has no gradient.  Use (~(~a~) x scale) or (~(~a~) acc multiplier)."
                                   op (cadr expr) op op)))
         t)
        ((or (%185-op-named-p op "MAX") (%185-op-named-p op "MIN")) ; endeavour 205: follows the winner
         (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v))
                (ge (%185-crisp-sym ">=")) (lt (%185-crisp-sym "<"))
                (if-sym (%185-crisp-sym "IF"))
                (a-wins (if (%185-op-named-p op "MAX") `(,ge ,a ,b) `(,lt ,a ,b)))
                (a-share `(%q-raw-float (,if-sym ,a-wins 1 0) ,v-adj))
                (b-share `(%q-raw-float (,if-sym ,a-wins 0 1) ,v-adj)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,a-share ,v-adj)))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,b-share ,v-adj)))))
           t))
        ((and (%qint-narrowing-target op) (= (length expr) 3)) ; endeavour 205: straight-through
         (let ((x (cadr expr)) (y (caddr expr)) (q (%qint-narrowing-target op)) (v-adj (local-adj v)))
           (when (symbolp x)
             (emit `(set! ,(local-adj x) (+ ,(local-adj x) (* (%q-ste :value ,q ,x ,y) ,v-adj)))))
           (when (symbolp y)
             (emit `(set! ,(local-adj y) (+ ,(local-adj y) (* (%q-ste :scale ,q ,x ,y) ,v-adj)))))
           t))
        ((and (%185-op-named-p op "TO-FLOAT") (= (length expr) 3)) ; endeavour 205: scale * q is exact
         (let ((q (cadr expr)) (s (caddr expr)) (v-adj (local-adj v)))
           (when (symbolp q) (emit `(set! ,(local-adj q) (+ ,(local-adj q) (* ,s ,v-adj)))))
           (when (symbolp s) (emit `(set! ,(local-adj s) (+ ,(local-adj s) (* (%q-raw-float ,q ,s) ,v-adj)))))
           t))
        ((%185-op-named-p op "SQRT")            ; d/da sqrt(a) = 0.5 / sqrt(a)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 0.5 (,(sym "SQRT") ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "RSQRT")           ; d/da a^-1/2 = -0.5 rsqrt(a) / a
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* -0.5 (/ (,(sym "RSQRT") ,a) ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "TANH")            ; d/da tanh(a) = 1 - tanh(a)^2
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (- 1.0 (* (,(sym "TANH") ,a) (,(sym "TANH") ,a))) ,v-adj)))))
           t))
        ((%185-op-named-p op "ERF")             ; d/da erf(a) = 2/sqrt(pi) exp(-a^2)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* 1.1283791670955126 (exp (- 0.0 (* ,a ,a)))) ,v-adj)))))
           t))
        ((%185-op-named-p op "EXP2")            ; d/da 2^a = ln2 2^a
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* 0.6931471805599453 (,(sym "EXP2") ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "ABS")             ; d/da |a| = sign(a)  (0 at 0)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a)
                                            (* (- (to-float (> ,a 0.0)) (to-float (< ,a 0.0))) ,v-adj)))))
           t))
        ((%185-op-named-p op "CLAMP")           ; x passes through inside [lo,hi]; lo below; hi above
         (destructuring-bind (x lo hi) (cdr expr)
           (let ((v-adj (local-adj v)))
             (when (symbolp x)
               (emit `(set! ,(local-adj x) (+ ,(local-adj x) (* (to-float (* (>= ,x ,lo) (<= ,x ,hi))) ,v-adj)))))
             (when (symbolp lo)
               (emit `(set! ,(local-adj lo) (+ ,(local-adj lo) (* (to-float (< ,x ,lo)) ,v-adj)))))
             (when (symbolp hi)
               (emit `(set! ,(local-adj hi) (+ ,(local-adj hi) (* (to-float (> ,x ,hi)) ,v-adj)))))
             t)))
        ((%185-op-named-p op "+!")              ; endeavour 203: on the basic types +! is +
         (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,v-adj))))
           t))
        ((%185-op-named-p op "-!")              ; endeavour 203: on the basic types -! is -
         (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (- ,(local-adj b) ,v-adj))))
           t))
        ((%185-op-named-p op "WIDEN")           ; endeavour 203: the identity on basic types
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
           t))
        ((%185-op-named-p op "*!")              ; D6: *! is *
         (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (%q-raw-float ,b ,v-adj) ,v-adj)))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (%q-raw-float ,a ,v-adj) ,v-adj)))))
           t))
        ;; P2 + P0: integer results carry no gradient -- the bit operations, and floor / ceil /
        ;; round (float -> int rounding is piecewise constant: derivative 0 almost everywhere).
        ((some (lambda (n) (%185-op-named-p op n))
               '("ASH" "LOGAND" "LOGIOR" "LOGXOR" "LOGNOT" "POPCOUNT" "FLOOR" "CEIL" "ROUND" "TO-SAT"
                 "SHIFT-LEFT" "SHIFT-RIGHT" "ROTATE-LEFT" "ROTATE-RIGHT"))   ; endeavour 211
         t)
        (t nil)))))

;; src/analysis/ops.lisp  (NEW, endeavour 211)
(defparameter *211-shift-op-names* '("SHIFT-LEFT" "SHIFT-RIGHT" "ROTATE-LEFT" "ROTATE-RIGHT")
  "Endeavour 211: the shift / rotate operators analyzed by analyze-211-shift-op.  Each takes (x count);
   the count is taken modulo x's width.")

;; src/analysis/ops.lisp  (NEW, endeavour 211)
(defun analyze-211-shift-op (expr env context location)
  "Analyzes (shift-left x n) / (shift-right x n) / (rotate-left x n) / (rotate-right x n) (endeavour 211).
   X is a scalar integer and fixes the result type; N may be any integer type (codegen converts it to X's
   type, which cannot change its low bits, so 'N mod width' is the same either way).  shift-right is
   logical for an unsigned X, arithmetic for a signed one."
  (let* ((name (symbol-name (first expr)))
         (args (rest expr)))
    (unless (= (length args) 2)
      (error 'crisp-compiler-error
             :message (format nil "~(~a~) takes 2 arguments (x count); got ~a" name (length args))
             :source-location location))
    (let* ((nodes (loop for a in args for i from 1
                        collect (analyze-expression a env context (append location (list i)))))
           (x-type (get-single-value-type (first nodes)))
           (n-type (get-single-value-type (second nodes))))
      (unless (%185-int-category-p x-type)
        (error 'crisp-compiler-error
               :message (format nil "~(~a~): operands must be integers (chapter 32/05); got ~(~a~)" name x-type)
               :source-location location))
      (unless (%185-int-category-p n-type)
        (error 'crisp-compiler-error
               :message (format nil "~(~a~): the count must be an integer; got ~(~a~)" name n-type)
               :source-location location))
      (log:debug "analyze-211-shift-op: ~a x=~a count=~a" name x-type n-type)
      (make-semantic-hw-op :op (cond ((string= name "SHIFT-LEFT") '%211-shift-left)
                                     ((string= name "SHIFT-RIGHT") '%211-shift-right)
                                     ((string= name "ROTATE-LEFT") '%211-rotate-left)
                                     (t '%211-rotate-right))
                           :type x-type :args nodes :source-location location))))

;; src/analysis/ops.lisp  (whole-function copy; only change: registers the endeavour-211 names too)
(defun %185-register-math-op-analyzers ()
  "Registers analyze-185-math-op under every *185-math-op-names* name, in both :crisp-language
   and :crisp.compiler.  Called from register-ops-analyzers.
   Endeavour 211: also analyze-211-shift-op under every *211-shift-op-names* name."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (name *185-math-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-math-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-math-op))
    ;; P2: the integer bit operations
    (dolist (name *185-bit-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-bit-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-bit-op))
    ;; Endeavour 211: shifts and rotates, count modulo the width
    (dolist (name *211-shift-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-211-shift-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-211-shift-op)))
  (%register-accum-analyzers))

;; src/codegen.lisp  (NEW, endeavour 211)
(defun %211-shift-rotate-body (builder module kind x c x-type)
  "Endeavour 211: the body of a shift / rotate of X by C (already X-TYPE), KIND one of :shl :shr :rotl
   :rotr.  The count is taken modulo the width:
     shifts  -> (and c (bits - 1)) then shl / lshr (unsigned) / ashr (signed).  LLVM drops the and when it
                can prove c's range; on PTX the shift is then one instruction.
     rotates -> llvm.fshl / llvm.fshr (x, x, c), whose count is ALREADY modulo the width by definition;
                NVPTX makes a 32-bit one a single shf.l.wrap / shf.r.wrap."
  (multiple-value-bind (cat bits) (%hw-type-parts x-type)
    (let ((ity (crisp-type-to-llvm-type x-type module)))
      (log:debug "%211-shift-rotate-body: ~a ~a (~a bits, ~a)" kind x-type bits cat)
      (ecase kind
        ((:shl :shr)
         (let ((m (crisp.llvm-bindings::llvm-build-and builder c (llvm-const-int ity (1- bits) 0) "sh_cnt")))
           (cond ((eq kind :shl) (crisp.llvm-bindings::llvm-build-shl builder x m "shift_left"))
                 ((eq cat :unsigned-int) (crisp.llvm-bindings::llvm-build-l-shr builder x m "shift_right"))
                 (t (crisp.llvm-bindings::llvm-build-a-shr builder x m "shift_right")))))
        ((:rotl :rotr)
         (%hw-call builder module
                   (format nil "llvm.~a.~a" (if (eq kind :rotl) "fshl" "fshr") (%hw-intrinsic-suffix cat bits nil nil))
                   ity (list x x c) "rotate"))))))

;; src/codegen.lisp  (NEW, endeavour 211)
(defun %211-lower (kind builder module arg-vals arg-types)
  "Endeavour 211: lower shift / rotate KIND through an internal helper __crisp_<kind>_<type> -- noinline
   on SPIR-V only (the BMG needs it for inline integer bodies, BUG 120 family), inlined on PTX
   (%185-helper-call).  The count is converted to the operand's type first, as for ash."
  (let* ((x-type (first arg-types))
         (c (build-cast-if-needed builder module (second arg-vals) (second arg-types) x-type))
         (helper (format nil "__crisp_~a_~(~a~)"
                         (ecase kind (:shl "shift_left") (:shr "shift_right") (:rotl "rotate_left") (:rotr "rotate_right"))
                         x-type)))
    (%185-helper-call builder module helper (crisp-type-to-llvm-type x-type module) (list (first arg-vals) c)
                      (lambda (b params)
                        (%211-shift-rotate-body b module kind (first params) (second params) x-type)))))

;; src/codegen.lisp  (NEW, endeavour 211)
(defmethod %hw-lower ((op (eql '%211-shift-left)) builder module arg-vals arg-types result-type)
  "shift-left (endeavour 211): x << (n mod width)."
  (declare (ignore result-type))
  (%211-lower :shl builder module arg-vals arg-types))

;; src/codegen.lisp  (NEW, endeavour 211)
(defmethod %hw-lower ((op (eql '%211-shift-right)) builder module arg-vals arg-types result-type)
  "shift-right (endeavour 211): x >> (n mod width); logical for unsigned, arithmetic for signed."
  (declare (ignore result-type))
  (%211-lower :shr builder module arg-vals arg-types))

;; src/codegen.lisp  (NEW, endeavour 211)
(defmethod %hw-lower ((op (eql '%211-rotate-left)) builder module arg-vals arg-types result-type)
  "rotate-left (endeavour 211): llvm.fshl(x, x, n), n mod width."
  (declare (ignore result-type))
  (%211-lower :rotl builder module arg-vals arg-types))

;; src/codegen.lisp  (NEW, endeavour 211)
(defmethod %hw-lower ((op (eql '%211-rotate-right)) builder module arg-vals arg-types result-type)
  "rotate-right (endeavour 211): llvm.fshr(x, x, n), n mod width."
  (declare (ignore result-type))
  (%211-lower :rotr builder module arg-vals arg-types))
