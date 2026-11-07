;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
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


;;;; ======================================================================
;;;; Endeavour 209, F-209-3 -- a PERSISTENT 1-D grid takes the flat tile walk.
;;;; See tests/spec/209-b200-mma-bench/b200-mma-bench.md.
;;;;
;;;; tile-stride's default lowering strides each tile dimension by THAT dimension's group count
;;;; (START_i = GID_i, STRIDE_i = NG_i).  A kernel that declares (global-size :set-to N) is
;;;; launched 1-D, so NG_1 = 1 and only the workgroups whose x id is below the number of tile
;;;; ROWS ever own a tile: 32 of 148 on a B200 at 4096, 64 at 8192 (measured 3.8x / 2.3x slow).
;;;; Results stay correct, which is why nothing caught it.  Endeavour 144's column-strip walk
;;;; (%expand-tile-stride-swizzled) already flattens the workgroup id over every grid dimension
;;;; and grid-strides one flat tile index -- exact coverage for ANY launch shape -- so a
;;;; persistent declaration now selects it, at the profile's measured strip width or 1.
;;;; ======================================================================

;; src/analysis/control.lisp
(defun %ts-persistent-grid-p ()
  "Endeavour 209 (F-209-3): true when the kernel being compiled declares a FIXED 1-D global
   size, (global-size :set-to N) with N an integer -- the persistent shape, launched as one
   row of workgroups.  Read from *kernel-dispatch-declarations*, as %ts-maybe-infer-tile-shape
   reads it."
  (let* ((ctx  *compiler-context*)
         (fn   (and ctx (compiler-context-current-compiling-function ctx)))
         (disp (and fn (gethash fn *kernel-dispatch-declarations*)))
         (decl (and disp (getf disp :global-size))))
    (and (consp decl)
         (integerp (getf (cdr decl) :set-to)))))

;; src/analysis/control.lisp
(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Outer loop over tile origins, workgroup-strided.  Phase 1b: pre-walks the
   body to rewrite bare load-tile / store-tile into their -coords forms using
   the tile-stride's binding syms as the origin.

   Endeavor 144 Phase 1: when the visit order should be GROUPED (rank 2, compile-time tile
   size-list, an active profile with :l2-cache-size — see %tile-visit-strip-width), emit the
   L2-aware column-strip walk instead.  Everything else takes the original linear expansion
   completely unchanged.

   Endeavour 209 (F-209-3): a rank-2 compile-time tile-stride in a kernel that declares a FIXED
   1-D global size (%ts-persistent-grid-p) also takes the column-strip walk -- at the measured
   strip width when the profile has one, else 1 (one tile column at a time) -- because the
   per-axis walk hands every tile column to the single y group.  A rank-3 tile-stride there
   keeps the per-axis walk and is warned about."
  (declare (ignore ct))
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore strict-p layout-tag))
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
        :message "Malformed tile-stride: expected (tile-stride TENSOR [LAYOUT-TAG] <TILE-SPEC> (BINDING ...) BODY...)"
        :source-location location))
    (let* ((n (length bindings))
           (cl-pkg (find-package :crisp-language))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (ts-syms (loop for i from 0 below n
                          collect (gensym (format nil "TS~A" i))))
           (tile-size-expr-fn
            (ecase tile-spec-kind
              (:size-list
               (let ((sizes tile-spec))
                 (lambda (k) (list to-ulong-sym (nth k sizes)))))
              (:tile-tensor
               (let ((tile-form tile-spec))
                 (lambda (k)
                   (list aref-sym (list extents-tilde-sym tile-form) k))))))
           (strip-width (%tile-visit-log-decision
                         n tile-spec-kind tile-spec
                         (%tile-visit-strip-width
                          n (when (eq tile-spec-kind :size-list) tile-spec))))
           (persistent (%ts-persistent-grid-p))
           (flat-ok (and (= n 2) (eq tile-spec-kind :size-list)
                         (not (eq (%tile-visit-override) :linear)))))
      (when (and persistent (> n 1) (not flat-ok))
        (log:warn "tile-stride rank ~a (~a) in a kernel with a fixed 1-D global size keeps the per-axis walk: only the workgroups with x id below the tile count of axis 0 will own tiles (F-209-3)."
                  n tile-spec-kind))
      (cond
        ((> strip-width 1)
         (%expand-tile-stride-swizzled tensor-form bindings body-forms ts-syms
                                       tile-size-expr-fn strip-width location))
        ((and persistent flat-ok)
         (log:info "tile-visit: fixed 1-D global size -> flat walk, strip-width 1 (F-209-3)")
         (%expand-tile-stride-swizzled tensor-form bindings body-forms ts-syms
                                       tile-size-expr-fn 1 location))
        (t
         (%expand-workgroup-strided-outer-loop-with-ts-syms
          tensor-form n bindings body-forms ts-syms tile-size-expr-fn location))))))
