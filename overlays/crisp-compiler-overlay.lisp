;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
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
;;;; Endeavour 208 -- tcgen05 (Blackwell datacenter tensor cores), phase 1.
;;;; See tests/spec/208-tcgen05/tcgen05.md (the decisions) and isa-notes.md (the ISA facts).
;;;;
;;;; FOLD NOTES.  defstruct semantic-tcgen05-op goes to src/semantic.lisp; the two wrappers of
;;;; semantic-node-type / semantic-node-source-location become a clause in each etypecase of
;;;; src/analysis/core.lisp.  The defvars must precede every function that binds them (the
;;;; special-var compile-order hazard), and gen-specials must list them.
;;;; ======================================================================

;; src/semantic.lisp
(defstruct semantic-tcgen05-op
  "Endeavour 208.  One tcgen05 operation.  OP is :mma, :commit, :ld, :fence-after or :fence-before.
   ARGS are the child nodes; PLIST holds the compile-time facts the lowering needs (shape, element,
   issuing warp, the synchronous site's mbarrier index, the tensor-memory column chunk)."
  op
  args
  plist
  type
  source-location)

;; src/mma.lisp
(defvar *tcgen05-acc-dims* (make-hash-table :test 'eq)
  "Endeavour 208.  tcgen05 accumulator record type -> (M N ELEM).")

;; src/mma.lisp
(defvar *tcgen05-columns* (make-hash-table :test 'equal)
  "Endeavour 208.  (KERNEL . LOCATION) of a make-tcgen05-accumulator let binding -> its first
   tensor-memory column.  Keyed by SITE, so re-analysing the same binding reuses its columns and two
   bindings that happen to share a name do not.")

;; src/mma.lisp
(defvar *tcgen05-sync-sites* (make-hash-table :test 'equal)
  "Endeavour 208.  (KERNEL . LOCATION) of a synchronous tcgen05 accumulate -> its mbarrier index.")

;; src/mma.lisp
(defvar *tcgen05-kernels* (make-hash-table :test 'equal)
  "Endeavour 208.  KERNEL (upper-case string) -> plist (:columns C :sync-sites S): the tensor-memory
   columns its accumulators occupy and how many synchronous accumulate sites it has.  The kernel
   prologue and epilogue (generate-function-body) read it to allocate, initialise and free.")

;; src/mma.lisp
(defvar *tcgen05-role-warps* nil
  "Endeavour 208.  (FIRST-WARP . COUNT) of the with-warp-specialization role being analysed, NIL
   outside any role.  The issuing thread of an MMA is lane 0 of FIRST-WARP (warp 0 outside a role),
   and the epilogue rule reads COUNT.")

;; src/mma.lisp
(defun %208-kernel-key (context)
  "Endeavour 208.  The function being compiled, as an upper-case string, or NIL."
  (let ((f (and context (compiler-context-current-compiling-function context))))
    (and f (string-upcase (princ-to-string f)))))

;; src/mma.lisp
(defun %208-kernel-info (key)
  "Endeavour 208.  KEY's entry in *tcgen05-kernels*, created empty on first use."
  (or (gethash key *tcgen05-kernels*)
      (setf (gethash key *tcgen05-kernels*) (list :columns 0 :sync-sites 0))))

;; src/mma.lisp
(defun %tcgen05-arch-ok-p ()
  "Endeavour 208.  T when the target is PTX for an architecture with tcgen05: the sm_100a family.
   Plain sm_100 is NOT enough -- the tcgen05 instructions are architecture-specific, and PTX built
   for .target sm_100 refuses them."
  (and (eq *target-backend* :ptx)
       (member (string-downcase (ptx-compute-capability-string))
               '("sm_100a" "sm_100f" "sm_101a" "sm_101f" "sm_103a" "sm_103f" "sm_110a" "sm_110f")
               :test #'string=)
       t))

;; src/mma.lisp
(defun %tcgen05-require-arch (form-name location)
  "Endeavour 208.  Refuse FORM-NAME unless the target has tcgen05 (D-208-1)."
  (unless (%tcgen05-arch-ok-p)
    (error 'crisp-compiler-error
           :message (format nil "~a: tcgen05 is the Blackwell datacenter tensor core and needs an architecture-specific target: --ir-target=ptx --ir-target-arch=sm_100a (B200 / GB200).  The target here is ~a.  On sm_90a use make-wgmma-accumulator / wgmma-accumulate-via-tile; elsewhere make-register-tile / mma-accumulate-via-tile."
                            form-name
                            (if (eq *target-backend* :ptx) (ptx-compute-capability-string) (string-downcase (princ-to-string *target-backend*))))
           :source-location location)))

;; src/mma.lisp
(defun %tcgen05-acc-type-name (m n elem)
  "Endeavour 208.  The minted tcgen05 accumulator record name."
  (intern (format nil "TCGEN05-ACC-~a-~dX~d" (if (%elem-integer-p elem) "S32" "F32") m n)
          (find-package :crisp.compiler)))

;; src/mma.lisp
(defun %tcgen05-acc-type-p (type-name)
  "Endeavour 208.  T if TYPE-NAME is a minted tcgen05 accumulator record type."
  (and type-name (symbolp type-name) (nth-value 1 (gethash type-name *tcgen05-acc-dims*)) t))

;; src/mma.lisp
(defun %ensure-tcgen05-acc-type (m n elem)
  "Endeavour 208.  Mint (once) the record naming a tensor-memory accumulator.  It holds none of the
   M x N values -- those live in tensor memory -- only two uint fields:
     COLUMN  the accumulator's first column, relative to the kernel's tensor-memory allocation;
     FRESH   1 until the first MMA after (re)initialisation.  That MMA OVERWRITES D (the ISA's
             enable-input-d predicate is false), so tensor memory never needs zeroing (D-208-5)."
  (let ((name (%tcgen05-acc-type-name m n elem)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (list (list (intern "COLUMN" (find-package :crisp.compiler)) 'uint)
             (list (intern "FRESH" (find-package :crisp.compiler)) 'uint))
       :record))
    (setf (gethash name *tcgen05-acc-dims*) (list m n elem))
    name))

;; src/mma.lisp
(defun %ensure-tcgen05-row-type ()
  "Endeavour 208.  Mint (once) the record one tcgen05.ld.32x32b.x32 fills: 32 float fields, the
   32 consecutive columns of the calling thread's own tensor-memory lane (its accumulator row)."
  (let ((name (intern "TCGEN05-ROW32-F32" (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below 32 collect (list (intern (format nil "R~d" i) (find-package :crisp.compiler)) 'float))
       :record))
    name))

;; src/mma.lisp
(defun %tcgen05-check-acc-shape (m n location)
  "Endeavour 208, phase 1.  M = 128 (the full 128-lane datapath, 'Layout D'); N a multiple of 16 in
   [16, 256] -- the PTX table allows steps of 8 at M = 128 for kind::f16, but CUTLASS's tf32 atom asks
   16, and 16 is valid under both until metal says otherwise."
  (unless (eql m 128)
    (error 'crisp-compiler-error
           :message (format nil "tcgen05: M must be 128, got ~a.  A 128-row accumulator uses all 128 tensor-memory lanes, one per row; M = 64 uses half the datapath and is not supported yet." m)
           :source-location location))
  (unless (and (integerp n) (<= 16 n 256) (zerop (mod n 16)))
    (error 'crisp-compiler-error
           :message (format nil "tcgen05: N must be a multiple of 16 in [16, 256], got ~a." n)
           :source-location location)))

;; src/mma.lisp
(defun analyze-make-tcgen05-accumulator (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator float (M N) 0.0) -> a tensor-memory accumulator.
   It must initialise a let binding: its columns are assigned per binding SITE, N columns for a float
   accumulator, and the kernel's total may not exceed the 512 a CTA has (D-208-4).  The init must
   be zero (D-208-5).  `(set! D (make-tcgen05-accumulator ..))` re-initialises D in place: the let
   pre-pass rewrites it to (%tcgen05-reset D), which keeps D's columns and marks it FRESH."
  (%tcgen05-require-arch "make-tcgen05-accumulator" location)
  (unless (= (length expr) 4)
    (error 'crisp-compiler-error
           :message "make-tcgen05-accumulator: expected (make-tcgen05-accumulator float (M N) 0.0)."
           :source-location location))
  (destructuring-bind (elem dims init) (cdr expr)
    (unless (and (symbolp elem) (string-equal (symbol-name elem) "FLOAT"))
      (error 'crisp-compiler-error
             :message (format nil "make-tcgen05-accumulator: the element must be float (an f32 accumulator), got ~a.  Integer accumulators come with kind::i8." elem)
             :source-location location))
    (unless (and (listp dims) (= (length dims) 2))
      (error 'crisp-compiler-error
             :message (format nil "make-tcgen05-accumulator: the shape must be (M N), got ~s." dims)
             :source-location location))
    (destructuring-bind (m n) dims
      (%tcgen05-check-acc-shape m n location)
      (unless (and (numberp init) (zerop init))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator: the initial value must be 0, got ~s.  The first MMA after initialisation overwrites the accumulator instead of adding to it, so zero costs nothing; any other start would need a pass that stores it into tensor memory." init)
               :source-location location))
      (unless (and context (compiler-context-current-binding-name context))
        (error 'crisp-compiler-error
               :message "make-tcgen05-accumulator must initialise a let binding, e.g. (let ((D (make-tcgen05-accumulator float (128 256) 0.0))) ...).  Re-initialise it with (set! D (make-tcgen05-accumulator float (128 256) 0.0))."
               :source-location location))
      (let* ((key    (%208-kernel-key context))
             (site   (cons key location))
             (info   (%208-kernel-info key))
             (offset (or (gethash site *tcgen05-columns*)
                         (let* ((off   (getf info :columns 0))
                                (total (+ off n)))
                           (when (> total 512)
                             (error 'crisp-compiler-error
                                    :message (format nil "make-tcgen05-accumulator: this kernel's tcgen05 accumulators need ~a tensor-memory columns, over the 512 a CTA has.  A float (M N) accumulator takes N columns, so two 128 x 256 accumulators fill it." total)
                                    :source-location location))
                           (setf (getf (gethash key *tcgen05-kernels*) :columns) total)
                           (setf (gethash site *tcgen05-columns*) off))))
             (type-name (%ensure-tcgen05-acc-type m n elem))
             (to-uint (intern "TO-UINT" (find-package :crisp-language))))
        (log:debug "208 make-tcgen05-accumulator ~a (~a ~a) in ~a: columns ~a..~a"
                   (compiler-context-current-binding-name context) m n key offset (+ offset n -1))
        (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset) (,to-uint 1))
                            env context location)))))

;; src/mma.lisp
(defun analyze-%tcgen05-reset (expr env context location)
  "Endeavour 208.  (%tcgen05-reset D) -> D with its columns kept and FRESH set: the re-initialisation
   `(set! D (make-tcgen05-accumulator ..))` is rewritten to (set! D (%tcgen05-reset D)) by the let
   pre-pass, because a set!'s value is analysed without knowing its target."
  (let* ((d (second expr))
         (d-node (analyze-expression d env context (append location '(1))))
         (d-type (semantic-node-type d-node))
         (to-uint (intern "TO-UINT" (find-package :crisp-language))))
    (unless (%tcgen05-acc-type-p d-type)
      (error 'crisp-compiler-error
             :message (format nil "(set! ~a (make-tcgen05-accumulator ..)): ~a is not a tcgen05 accumulator (its type is ~a).  Bind it with make-tcgen05-accumulator in a let first." d d d-type)
             :source-location location))
    (analyze-expression `(%construct-struct ,d-type (%extract-struct-member ,d 0) (,to-uint 1))
                        env context location)))

;; src/mma.lisp
(defun %208-rewrite-acc-reinit (form)
  "Endeavour 208.  FORM with every (set! X (make-tcgen05-accumulator ...)) rewritten to
   (set! X (%tcgen05-reset X)).  A plain tree walk: the pattern has no other meaning."
  (cond ((atom form) form)
        ((and (symbolp (first form)) (string-equal (symbol-name (first form)) "SET!")
              (= (length form) 3) (symbolp (second form))
              (consp (third form)) (symbolp (first (third form)))
              (string-equal (symbol-name (first (third form))) "MAKE-TCGEN05-ACCUMULATOR"))
         (log:debug "208: (set! ~a (make-tcgen05-accumulator ..)) -> (%tcgen05-reset ~a)" (second form) (second form))
         (list (first form) (second form)
               (list (intern "%TCGEN05-RESET" (find-package :crisp.compiler)) (second form))))
        (t (mapcar #'%208-rewrite-acc-reinit form))))

;; src/mma.lisp
(defun %208-analyze-let (expr env context location)
  "Endeavour 208.  LET: the accumulator re-initialisation rewrite, then the existing let analyzer.
   Fold: a first line in analyze-let-with-tile-explosion."
  (analyze-let-with-tile-explosion (if (and (consp expr) (cddr expr))
                                       (list* (first expr) (second expr) (%208-rewrite-acc-reinit (cddr expr)))
                                       expr)
                                   env context location))

;; src/mma.lisp
(defun analyze-%in-warp-role (expr env context location)
  "Endeavour 208.  (%in-warp-role FIRST COUNT BODY..) -- with-warp-specialization's role body,
   analysed as (progn BODY..) with *tcgen05-role-warps* bound to (FIRST . COUNT).  The node is the
   progn's, so the IR is unchanged; only the tcgen05 forms read the binding."
  (destructuring-bind (first count &rest body) (cdr expr)
    (let ((*tcgen05-role-warps* (cons first count)))
      (analyze-expression (cons (intern "PROGN" (find-package :crisp-language)) body)
                          env context location))))

;; src/mma.lisp
(defun %tcgen05-16bit-elem-p (elem)
  "Endeavour 208.  T for half / bfloat16."
  (and elem (symbolp elem) (member (symbol-name elem) '("HALF" "BFLOAT16") :test #'string=) t))

;; src/mma.lisp
(defun analyze-tcgen05-accumulate-via-tile (expr env context location)
  "Endeavour 208.  (tcgen05-accumulate-via-tile (M N K) D A B :swizzle :128b [:on-complete BAR])
   -> (set! D (%tcgen05-mma D A B K [BAR])).  D += A.B over K, issued by one thread into tensor memory.

   Without :on-complete it is SYNCHRONOUS (D-208-2): the issuing thread commits to a compiler-owned
   mbarrier and every thread executing the form waits on it.  With :on-complete BAR it commits to BAR
   and returns at once.

   Phase 1: half / bfloat16 operands (kind::f16), M = 128, A (M K) and B (N K) K-major in shared
   memory as a :128b TMA load lays them down, K = 64 (one 128-byte swizzle atom wide, four K = 16
   instructions)."
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
        (unless (and (%tcgen05-16bit-elem-p elem) (%tcgen05-16bit-elem-p b-elem)
                     (string= (symbol-name elem) (symbol-name b-elem)))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: A and B must both be half or both bfloat16 (kind::f16), got ~a and ~a." elem b-elem)
                 :source-location location))
        (unless (and swz (symbolp swz) (string-equal (symbol-name swz) "128B"))
          (error 'crisp-compiler-error
                 :message "tcgen05-accumulate-via-tile needs :swizzle :128b: A and B are read through shared-memory descriptors built for the 128-byte swizzle that a (load-tile .. :swizzle :128b) TMA load lays down."
                 :source-location location))
        (unless (and (symbolp bm) (string-equal (symbol-name bm) "K"))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major ~s is not supported yet; B must be (N K), K-major." bm)
                 :source-location location))
        (unless (= k 64)
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: K must be 64 for half / bfloat16 (one 128-byte swizzle atom: four K = 16 instructions), got ~a." k)
                 :source-location location))
        ;; Operand extents, when known: A (M K), B (N K).
        (let ((a-r (%mma-operand-extent a nil :rows)) (a-c (%mma-operand-extent a nil :cols))
              (b-r (%mma-operand-extent b nil :rows)) (b-c (%mma-operand-extent b nil :cols)))
          (when (or (and a-r (/= a-r m)) (and a-c (/= a-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: A tile must be (M K) = (~a ~a), but it is (~a ~a)." m k (or a-r '?) (or a-c '?))
                   :source-location location))
          (when (or (and b-r (/= b-r n)) (and b-c (/= b-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: B tile must be (N K) = (~a ~a), K-major as for wgmma, but it is (~a ~a)." n k (or b-r '?) (or b-c '?))
                   :source-location location)))
        (analyze-expression `(set! ,d (%tcgen05-mma ,d ,a ,b ,k ,@(when bar (list bar))))
                            env context location)))))

;; src/mma.lisp
(defun %208-issue-warp ()
  "Endeavour 208.  The warp whose lane 0 issues tcgen05.mma / tcgen05.commit: the first warp of the
   enclosing with-warp-specialization role, else warp 0 (D-208-7).  MMA and commit must come from
   the SAME thread -- a commit tracks only the MMAs its own thread issued -- and this rule gives both
   the same one."
  (if *tcgen05-role-warps* (car *tcgen05-role-warps*) 0))

;; src/mma.lisp
(defun analyze-%tcgen05-mma (expr env context location)
  "Endeavour 208.  (%tcgen05-mma D A B K [BAR]) -> the semantic-tcgen05-op :mma node, typed as D.
   A / B become (~ tile 0 0) so codegen's third value is the shared-memory base (as for wgmma).  A
   site without BAR is synchronous and gets its own mbarrier index in this kernel."
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
                    :issue-warp (%208-issue-warp) :sync-site site :kernel key)
       :type d-type
       :source-location location))))

;; src/mma.lisp
(defun analyze-tcgen05-commit (expr env context location)
  "Endeavour 208.  (tcgen05-commit BAR): BAR arrives once every tcgen05 MMA the issuing thread has
   issued so far has finished (D-208-3).  Issued by the same thread as the MMAs (%208-issue-warp)."
  (%tcgen05-require-arch "tcgen05-commit" location)
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "tcgen05-commit: expected (tcgen05-commit BARRIER)."
           :source-location location))
  (make-semantic-tcgen05-op
   :op :commit
   :args (list (analyze-expression (second expr) env context (append location '(1))))
   :plist (list :issue-warp (%208-issue-warp))
   :type 'void
   :source-location location))

;; src/mma.lisp
(defun analyze-%tcgen05-ld (expr env context location)
  "Endeavour 208.  (%tcgen05-ld D CHUNK) -> the 32 columns [32*CHUNK, 32*CHUNK+32) of the calling
   thread's accumulator row, as a TCGEN05-ROW32-F32 record (tcgen05.ld.32x32b.x32 + wait::ld)."
  (destructuring-bind (d chunk) (cdr expr)
    (make-semantic-tcgen05-op
     :op :ld
     :args (list (analyze-expression d env context (append location '(1))))
     :plist (list :chunk chunk)
     :type (%ensure-tcgen05-row-type)
     :source-location location)))

;; src/mma.lisp
(defun analyze-%tcgen05-fence (expr env context location)
  "Endeavour 208.  (%tcgen05-fence-after) / (%tcgen05-fence-before): tcgen05.fence::after_thread_sync
   / ::before_thread_sync, ordering tensor-memory access against the thread synchronisation around it."
  (declare (ignore env context))
  (make-semantic-tcgen05-op
   :op (if (search "AFTER" (symbol-name (first expr))) :fence-after :fence-before)
   :args nil :plist nil :type 'void :source-location location))

;; src/mma.lisp
(defun %208-declared-local-size (context)
  "Endeavour 208.  The kernel's (local-size :set-to ..) thread count, or NIL when not a compile-time
   constant."
  (let* ((f    (and context (compiler-context-current-compiling-function context)))
         (decl (and f (getf (gethash f *kernel-dispatch-declarations*) :local-size)))
         (pos  (and (consp decl) (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "SET-TO"))) decl)))
         (dims (and pos (nth (1+ pos) decl))))
    (log:debug "208 local-size decl of ~a: ~s" f decl)
    (cond ((integerp dims) dims)
          ((and (consp dims) (every #'integerp dims)) (reduce #'* dims))
          (t nil))))

;; src/mma.lisp
(defun %tcgen05-check-epilogue-threads (context location)
  "Endeavour 208 (D-208-6).  Reading a tcgen05 accumulator back is a warpgroup's job: warp w of a
   warpgroup may read only tensor-memory lanes 32(w mod 4) .. +31, so it takes four consecutive warps
   to cover 128 rows.  Inside a role the role must be 4 warps; outside one the kernel must be 128
   threads."
  (let ((role *tcgen05-role-warps*))
    (if role
        (unless (= (cdr role) 4)
          (error 'crisp-compiler-error
                 :message (format nil "store-tile of a tcgen05 accumulator: the role storing it has ~a warp~:p, but it takes exactly 4 (one warpgroup).  Warp w may read only tensor-memory lanes 32(w mod 4) .. +31, so four consecutive warps cover the 128 rows." (cdr role))
                 :source-location location))
        (let ((ls (%208-declared-local-size context)))
          (unless (eql ls 128)
            (error 'crisp-compiler-error
                   :message (format nil "store-tile of a tcgen05 accumulator outside a with-warp-specialization role needs (local-size :set-to 128) -- exactly one warpgroup -- but the local size is ~a.  With more warps, store it from a 4-warp role." (or ls "not a compile-time constant"))
                   :source-location location))))))

;; src/mma.lisp
(defun %tcgen05-store-rewrite-origin (tile dest row-origin col-origin n &optional convert)
  "Endeavour 208.  Store the 128 x N tcgen05 accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN).  Thread t of the warpgroup owns row 32(warp mod 4) + lane (Layout D: row
   m is tensor-memory lane m).  Per chunk of 32 columns: one tcgen05.ld into registers, then the
   row's 32 elements -- as 16 packed pairs (endeavour 197) when the first pair is adjacent and
   aligned, else as scalars.  A fence::after_thread_sync opens the store (the accumulator was
   completed by another thread's MMA) and a fence::before_thread_sync closes it (the next MMA into
   these columns must not overtake the reads).  CONVERT as in %wgmma-store-rewrite-origin."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (if-sym (intern "IF" (find-package :crisp-language)))
         (chunks (floor n 32)))
    (flet ((elt-of (ch j) (%196-wrap-conversion convert `(%extract-struct-member ,ch ,j))))
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

;; src/mma.lisp
(defun %208-source-type (src env context location)
  "Endeavour 208.  The type of a store source SRC when it is a symbol, else NIL.  Only used to spot a
   tcgen05 accumulator; anything that fails to analyse here is left to the original analyzer."
  (and (symbolp src)
       (ignore-errors (semantic-node-type (analyze-expression src env context (append location '(1)))))))

;; src/mma.lisp
(defun %208-analyze-store-tile (expr env context location)
  "Endeavour 208.  store-tile: a tcgen05 accumulator source is stored by %tcgen05-store-rewrite-origin
   at the tile-grid origin (BTY*M, BTX*N); anything else goes to analyze-store-tile-mma unchanged.
   Fold: a clause in analyze-store-tile-mma."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (destructuring-bind (m n elem) (gethash src-type *tcgen05-acc-dims*)
            (declare (ignore elem))
            (%tcgen05-check-epilogue-threads context location)
            (let ((tile-id (fourth expr))
                  (to-int (intern "TO-INT" (find-package :crisp-language))))
              (analyze-expression
               (%tcgen05-store-rewrite-origin src (third expr)
                                              `(* (,to-int ,(first tile-id)) ,m)
                                              `(* (,to-int ,(second tile-id)) ,n)
                                              n convert)
               env context location)))
          (analyze-store-tile-mma expr env context location)))))

;; src/mma.lisp
(defun %208-analyze-store-tile-at (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin; :via :tma is not supported for it yet.  Anything else goes to analyze-store-tile-at-mma.
   Fold: a clause in analyze-store-tile-at-mma."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (let ((origin (fourth expr))
                (n (second (gethash src-type *tcgen05-acc-dims*))))
            (when (nthcdr 4 expr)
              (error 'crisp-compiler-error
                     :message (format nil "store-tile-at: options ~s are not supported for a tcgen05 accumulator yet (no :via :tma)." (nthcdr 4 expr))
                     :source-location location))
            (unless (and (listp origin) (= (length origin) 2))
              (error 'crisp-compiler-error
                     :message (format nil "store-tile-at: a tcgen05 accumulator needs a 2-D (ROW COL) element origin, got ~s." origin)
                     :source-location location))
            (%tcgen05-check-epilogue-threads context location)
            (analyze-expression (%tcgen05-store-rewrite-origin src (third expr) (first origin) (second origin) n convert)
                                env context location))
          (analyze-store-tile-at-mma expr env context location)))))

;; src/analysis/core.lisp -- fold: a clause in semantic-node-type's etypecase
(defvar *208-orig-semantic-node-type* (fdefinition 'semantic-node-type))
;; src/analysis/core.lisp
(defun semantic-node-type (node)
  "Endeavour 208 wrapper: semantic-tcgen05-op, then the original etypecase."
  (if (semantic-tcgen05-op-p node)
      (semantic-tcgen05-op-type node)
      (funcall *208-orig-semantic-node-type* node)))

;; src/analysis/core.lisp -- fold: a clause in semantic-node-source-location's etypecase
(defvar *208-orig-semantic-node-source-location* (fdefinition 'semantic-node-source-location))
;; src/analysis/core.lisp
(defun semantic-node-source-location (node)
  "Endeavour 208 wrapper: semantic-tcgen05-op, then the original etypecase."
  (if (semantic-tcgen05-op-p node)
      (semantic-tcgen05-op-source-location node)
      (funcall *208-orig-semantic-node-source-location* node)))

;;; ---------------------------------------------------------------- codegen

;; src/codegen.lisp
(defun %208-asm (builder asm &optional (constraints "~{memory}") ret-type ptypes args)
  "Endeavour 208.  One side-effecting inline-asm statement (void unless RET-TYPE)."
  (%build-inline-asm-call builder (or ret-type (llvm-void-type)) ptypes args asm constraints))

;; src/codegen.lisp
(defun %208-if (builder test thunk &optional (label "tc"))
  "Endeavour 208.  if (TEST) { THUNK } -- a then block and a merge block; the builder ends in the merge."
  (let* ((fn    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (then  (llvm-append-basic-block fn (format nil "~a_then" label)))
         (merge (llvm-append-basic-block fn (format nil "~a_merge" label))))
    (llvm-build-cond-br builder test then merge)
    (llvm-position-builder-at-end builder then)
    (funcall thunk)
    (llvm-build-br builder merge)
    (llvm-position-builder-at-end builder merge)))

;; src/codegen.lisp
(defun %208-linear-tid (builder module)
  "Endeavour 208.  The thread's linear index in the workgroup, i32."
  (let ((v (generate-node-ir (make-semantic-gpu-builtin :builtin-name :get-local-linear-id
                                                        :dimension nil :type 'ulong)
                             builder module nil nil nil nil)))
    (llvm-build-trunc builder v (llvm-int32-type) "tc_tid")))

;; src/codegen.lisp
(defun %208-shared-global (module name llvm-type)
  "Endeavour 208.  The addrspace(3) global NAME, created (undef, internal, 16-byte aligned) on first use."
  (let ((g (llvm-get-named-global module name)))
    (if (and g (not (cffi:null-pointer-p g)))
        g
        (let ((g (crisp.llvm-bindings:llvm-add-global-in-addrspace module llvm-type name 3)))
          (crisp.llvm-bindings:llvm-set-initializer g (llvm-get-undef llvm-type))
          (crisp.llvm-bindings::llvm-set-linkage g 8)      ; internal
          (crisp.llvm-bindings::llvm-set-alignment g 16)
          (log:debug "208: shared global ~a" name)
          g))))

;; src/codegen.lisp
(defun %208-tmem-slot (module)
  "Endeavour 208.  The shared word tcgen05.alloc writes the kernel's tensor-memory address into."
  (%208-shared-global module "__crisp_tmem_slot" (llvm-int32-type)))

;; src/codegen.lisp
(defun %208-sync-mbar-global (module kernel n)
  "Endeavour 208.  KERNEL's [N x i64] mbarriers, one per synchronous accumulate site."
  (%208-shared-global module
                      (format nil "__crisp_tc_mbar_~a"
                              (substitute-if #\_ (lambda (c) (not (alphanumericp c))) (string-downcase kernel)))
                      (if (> n 1) (crisp.llvm-bindings::llvm-array-type (llvm-int64-type) n) (llvm-int64-type))))

;; src/codegen.lisp
(defun %208-pow2-columns (columns)
  "Endeavour 208.  The tcgen05.alloc column count for COLUMNS: a power of two, at least 32."
  (loop for c = 32 then (* c 2) when (>= c columns) return c))

;; src/codegen.lisp
(defun %208-kernel-tc-info (kernel-name)
  "Endeavour 208.  KERNEL-NAME's *tcgen05-kernels* entry when it uses tensor memory on PTX, else NIL."
  (let ((info (gethash (string-upcase (princ-to-string kernel-name)) *tcgen05-kernels*)))
    (and info (eq *target-backend* :ptx) (plusp (getf info :columns 0)) info)))

;; src/codegen.lisp
(defun %208-emit-tmem-prologue (builder module kernel-name)
  "Endeavour 208 (D-208-4).  At kernel entry, for a kernel with tcgen05 accumulators:
     warp 0:   tcgen05.alloc of the kernel's columns (a power of two >= 32) into __crisp_tmem_slot,
               then relinquish_alloc_permit, so a second CTA on the SM is not kept waiting;
     thread 0: mbarrier.init (count 1) of each synchronous site's mbarrier;
     all:      fence::before_thread_sync, bar.sync, fence::after_thread_sync -- the alloc's store
               to shared memory is weak, and this is the ordering the PTX ISA prescribes."
  (let ((info (%208-kernel-tc-info kernel-name)))
    (when info
      (let* ((i32   (llvm-int32-type))
             (ncols (%208-pow2-columns (getf info :columns)))
             (nsync (getf info :sync-sites 0))
             (tid   (%208-linear-tid builder module))
             (slot-addr (llvm-build-ptr-to-int builder (%208-tmem-slot module) i32 "tmem_slot_addr")))
        (log:info "208: kernel ~a allocates ~a tensor-memory columns (~a used), ~a synchronous site~:p"
                  kernel-name ncols (getf info :columns) nsync)
        (%208-if builder (llvm-build-icmp builder +llvm-int-ult+ tid (llvm-const-int i32 32 nil) "tc_is_w0")
                 (lambda ()
                   (%208-asm builder (format nil "tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [$0], ~d;" ncols)
                             "r,~{memory}" nil (list i32) (list slot-addr))
                   (%208-asm builder "tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned;"))
                 "tc_alloc")
        (when (plusp nsync)
          (let ((mbar (%208-sync-mbar-global module (getf info :kernel (princ-to-string kernel-name)) nsync)))
            (%208-if builder (llvm-build-icmp builder +llvm-int-eq+ tid (llvm-const-int i32 0 nil) "tc_is_t0")
                     (lambda ()
                       (dotimes (i nsync)
                         (%gen-nvvm-mbarrier-init-shared builder module (%gen-nvvm-mbar-slot-ptr builder mbar i)
                                                         (llvm-const-int i32 1 nil)))
                       (%gen-nvvm-fence-proxy-async-shared builder))
                     "tc_mbar_init")))
        (%208-asm builder "tcgen05.fence::before_thread_sync;")
        (%ptx-barrier builder module)
        (%208-asm builder "tcgen05.fence::after_thread_sync;")))))

;; src/codegen.lisp
(defun %208-emit-tmem-epilogue (builder module kernel-name)
  "Endeavour 208 (D-208-4).  Before ret: every thread's tensor-memory work is ordered before a
   bar.sync (fence::before_thread_sync / bar.sync / fence::after_thread_sync), then warp 0 frees the
   allocation -- all of it must be freed before the kernel exits."
  (let ((info (%208-kernel-tc-info kernel-name)))
    (when info
      (let* ((i32   (llvm-int32-type))
             (ncols (%208-pow2-columns (getf info :columns)))
             (tid   nil))
        (%208-asm builder "tcgen05.fence::before_thread_sync;")
        (%ptx-barrier builder module)
        (%208-asm builder "tcgen05.fence::after_thread_sync;")
        (setf tid (%208-linear-tid builder module))
        (%208-if builder (llvm-build-icmp builder +llvm-int-ult+ tid (llvm-const-int i32 32 nil) "tc_is_w0")
                 (lambda ()
                   (let ((base (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base")))
                     (%208-asm builder (format nil "tcgen05.dealloc.cta_group::1.sync.aligned.b32 $0, ~d;" ncols)
                               "r,~{memory}" nil (list i32) (list base))))
                 "tc_dealloc")))))

;; src/codegen.lisp
(defun %208-smem-desc (builder base-ptr kslice-byte-off)
  "Endeavour 208.  The 64-bit Blackwell shared-memory descriptor (CUTLASS UMMA::SmemDescriptor) of a
   K-major operand under the 128-byte swizzle: start address >> 4 at [0,14), LBO 16 B (enc 1, unused
   when swizzled), SBO 1024 B (enc 64: eight 128-byte rows per swizzle atom) at [32,46), VERSION 1 at
   [46,48) -- the Blackwell marker -- base offset 0, layout SWIZZLE_128B = 2 at [61,64).  The K-slice
   advances the start address by KSLICE-BYTE-OFF (32 bytes per K = 16 slice), as on wgmma.
   NOTE that 2 at [61,64) is the same bit as wgmma's 1 at [62,64): only the version bit differs."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (logior (ash 1 16) (ash 64 32) (ash 1 46) (ash 2 61)))
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "tc_addr"))
         (addr  (if (zerop kslice-byte-off) addr0
                    (llvm-build-add builder addr0 (llvm-const-int i32 kslice-byte-off nil) "tc_addr_k")))
         (sh    (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "tc_sh"))
         (msk   (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "tc_start"))
         (st64  (llvm-build-zext builder msk i64 "tc_start64")))
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "tc_desc")))

;; src/codegen.lisp
(defun %208-idesc (m n elem b-elem)
  "Endeavour 208.  The 32-bit kind::f16 instruction descriptor (CUTLASS UMMA::InstrDescriptor):
   c_format F32 = 1 at [4,6); a_format / b_format at [7,10) / [10,13) (F16 0, BF16 1); A and B
   K-major (bits 15, 16 = 0); N >> 3 at [17,23); M >> 4 at [24,29)."
  (flet ((fmt (e) (if (string= (symbol-name e) "BFLOAT16") 1 0)))
    (logior (ash 1 4) (ash (fmt elem) 7) (ash (fmt b-elem) 10) (ash (ash n -3) 17) (ash (ash m -4) 24))))

;; src/codegen.lisp
(defun %208-entry-counter (builder name)
  "Endeavour 208.  An i32 counter alloca'd and zeroed in the entry block (it persists across loop
   iterations).  Returns the alloca; the builder is left where it was."
  (let* ((i32   (llvm-int32-type))
         (saved (llvm-get-insert-block builder))
         (fn    (llvm-get-basic-block-parent saved))
         (entry (crisp.llvm-bindings::llvm-get-entry-basic-block fn))
         (term  (llvm-get-basic-block-terminator entry)))
    (if (cffi:null-pointer-p term)
        (llvm-position-builder-at-end builder entry)
        (crisp.llvm-bindings::llvm-position-builder-before builder term))
    (let ((ctr (llvm-build-alloca builder i32 name)))
      (llvm-build-store builder (llvm-const-int i32 0 nil) ctr)
      (llvm-position-builder-at-end builder saved)
      ctr)))

;; src/codegen.lisp
(defun %208-commit-asm (builder mbar-addr-i32)
  "Endeavour 208.  tcgen05.commit: MBAR arrives (count 1) when every prior tcgen05 op of this thread
   has completed.  Implies fence::before_thread_sync."
  (%208-asm builder "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64 [$0];"
            "r,~{memory}" nil (list (llvm-int32-type)) (list mbar-addr-i32)))

;; src/codegen.lisp
(defun %208-barrier-addr (builder bar-val)
  "Endeavour 208.  A barrier value (i64 of an addrspace(3) mbarrier) as the i32 shared address asm takes."
  (let ((p (llvm-build-int-to-ptr builder bar-val (llvm-pointer-type (llvm-int8-type) 3) "tc_mbar")))
    (llvm-build-ptr-to-int builder p (llvm-int32-type) "tc_mbar_addr")))

;; src/codegen.lisp
(defun %208-gen-mma (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  D += A.B: lane 0 of the issuing warp builds the descriptors and issues K/16
   tcgen05.mma.kind::f16 (the first with enable-input-d = !FRESH, the rest accumulating), then commits
   -- to :on-complete's barrier, or to this site's own mbarrier, on which every executing thread then
   waits (parity from an entry-block visit counter) before fence::after_thread_sync.  Returns D with
   FRESH cleared."
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
             (idesc  (%208-idesc (getf pl :m) (getf pl :n) (getf pl :elem) (getf pl :b-elem)))
             (slices (floor (getf pl :k) 16)))
        (unless (and a-ptr b-ptr)
          (error "tcgen05: A/B (~ tile 0 0) did not yield a shared-memory pointer (a ~a b ~a)" a-ptr b-ptr))
        (log:debug "208 gen mma: idesc #x~8,'0x slices ~a issue-warp ~a site ~a on-complete ~a"
                   idesc slices (getf pl :issue-warp) site (and bar-node t))
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
                                 "{ .reg .pred p; setp.ne.b32 p, $4, 0; tcgen05.mma.cta_group::1.kind::f16 [$0], $1, $2, $3, p; }"
                                 "r,l,l,r,r,~{memory}" nil (list i32 i64 i64 i32 i32)
                                 (list dt
                                       (%208-smem-desc builder a-ptr (* kk 32))
                                       (%208-smem-desc builder b-ptr (* kk 32))
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

;; src/codegen.lisp
(defun %208-gen-ld (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  tcgen05.ld.sync.aligned.32x32b.x32 + wait::ld: the thread's own lane (32(warp mod 4)
   + lane) and the 32 columns of chunk C.  Address = base + COLUMN + 32C + (lane << 16); the lane's
   32(warp mod 4) part is (warp mod 4) << 21.  Returns the TCGEN05-ROW32-F32 record."
  (let* ((d-node (first (semantic-tcgen05-op-args node)))
         (chunk  (getf (semantic-tcgen05-op-plist node) :chunk))
         (i32    (llvm-int32-type))
         (d-val  (extract-primary-value builder
                                        (generate-node-ir d-node builder module var-env di-builder di-scope location-map)
                                        (semantic-node-type d-node)))
         (col    (llvm-build-extract-value builder d-val 0 "tc_col"))
         (tid    (%208-linear-tid builder module))
         (w4     (crisp.llvm-bindings::llvm-build-and
                  builder (crisp.llvm-bindings::llvm-build-l-shr builder tid (llvm-const-int i32 5 nil) "tc_warp")
                  (llvm-const-int i32 3 nil) "tc_wq"))
         (lane   (crisp.llvm-bindings::llvm-build-shl builder w4 (llvm-const-int i32 21 nil) "tc_lane_bits"))
         (base   (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base"))
         (addr   (llvm-build-add builder
                                 (llvm-build-add builder (llvm-build-add builder base col "tc_a0") lane "tc_a1")
                                 (llvm-const-int i32 (* 32 chunk) nil) "tc_taddr"))
         (asm    (format nil "tcgen05.ld.sync.aligned.32x32b.x32.b32 {~{$~d~^, ~}}, [$32];~%	tcgen05.wait::ld.sync.aligned;"
                         (loop for i below 32 collect i)))
         (cons   (format nil "~{~a~^,~},r,~~{memory}" (loop repeat 32 collect "=r")))
         (call   (%build-inline-asm-call builder (%wgmma-struct-of-regs module i32 32) (list i32) (list addr) asm cons))
         (row-type (semantic-tcgen05-op-type node))
         (agg    (llvm-get-undef (crisp-type-to-llvm-type row-type module))))
    (dotimes (i 32)
      (setf agg (llvm-build-insert-value
                 builder agg
                 (llvm-build-bit-cast builder (llvm-build-extract-value builder call i (format nil "tc_r~d" i))
                                      (llvm-float-type) (format nil "tc_f~d" i))
                 i (format nil "tc_row~d" i))))
    (values agg nil)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-tcgen05-op) builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  Dispatch on the tcgen05 operation."
  (let ((void (lambda () (values (llvm-const-int (llvm-int64-type) 0 nil) nil))))
    (ecase (semantic-tcgen05-op-op node)
      (:mma (%208-gen-mma node builder module var-env di-builder di-scope location-map))
      (:ld  (%208-gen-ld node builder module var-env di-builder di-scope location-map))
      (:commit
       (let* ((bar-addr (%208-barrier-addr builder (generate-node-ir (first (semantic-tcgen05-op-args node))
                                                                    builder module var-env di-builder di-scope location-map)))
              (i32 (llvm-int32-type))
              (tid (%208-linear-tid builder module)))
         (%208-if builder (llvm-build-icmp builder +llvm-int-eq+ tid
                                           (llvm-const-int i32 (* 32 (getf (semantic-tcgen05-op-plist node) :issue-warp)) nil)
                                           "tc_committer")
                  (lambda () (%208-commit-asm builder bar-addr))
                  "tc_commit")
         (funcall void)))
      (:fence-after  (%208-asm builder "tcgen05.fence::after_thread_sync;")  (funcall void))
      (:fence-before (%208-asm builder "tcgen05.fence::before_thread_sync;") (funcall void)))))

;; src/analysis/control.lisp
(defun %lower-warp-specialization (expr location &key (gated t))
  "Endeavor 139 / 146: the PURE SYNTACTIC lowering of with-warp-specialization.  Returns the
   replacement form; it analyses nothing and has no side effects.

   EXTRACTED FROM THE ANALYZER in endeavour 146 so the AD walk can reuse it.  The walk runs
   BEFORE semantic analysis, so without this it sees the raw construct and reads a role block
   `(:consumer ...)` as a call to a function named CONSUMER.

   TWO CONSUMERS, ONE LOWERING.  The alternative was a second, hand-written warp-gated rewrite
   inside the AD normalizer — which would be free to drift from this one, and a gradient that
   is correct for a kernel nobody runs is worse than no gradient at all.  Note this differs
   from how wgmma is handled in the same normalizer: there the backward deliberately uses a
   DIFFERENT instruction from the forward (sync MMA rather than warpgroup-async), which is a
   real semantic choice.  Here the backward wants the SAME expansion the forward gets, only
   earlier — reuse, not substitution.

   (with-warp-specialization (ROLE COUNT ...) (ROLE BODY...) ...).  Splits the
   workgroup by WARP — warp k runs the role whose cumulative count range contains k.  Lowers to a
   warp-id-gated nested if: (let ((wsid (to-int (warp-id)))) (if (< wsid t1) BODY1 (if (< wsid t2)
   BODY2 ...))) where t_i is the running sum of role counts.  Role blocks are warp-UNIFORM (all
   lanes of a warp take the same branch) but workgroup-DIVERGENT — so an internal workgroup
   collective (sync-workgroup, a cooperative load-tile) inside a block would DEADLOCK.  Forbidding
   those is decision B, enforced when the load path is added (Chapter 3 step 2); the skeleton here
   just lowers the branch."
  (multiple-value-bind (role-counts role-blocks) (%parse-warp-specialization expr location)
    (let* ((cl        (find-package :crisp-language))
           (let-sym   (intern "LET" cl))
           (if-sym    (intern "IF" cl))
           (lt-sym    (intern "<" cl))
           (progn-sym (intern "PROGN" cl))
           (to-int-sym (intern "TO-INT" cl))
           (warp-id-sym (intern "WARP-ID" cl))
           (wsid      (gensym "WSID"))
           (n         (length role-counts))
           ;; each role's body wrapped in a progn (in declaration order)
           ;; Endeavour 208: a GATED role body is (%in-warp-role FIRST COUNT BODY..), analysed as
           ;; (progn BODY..) with the role's warps bound for the tcgen05 forms -- same node, same IR.
           ;; The ungated (backward) lowering keeps plain progns: the AD walk runs before analysis.
           (bodies    (let ((first-warp 0))
                        (loop for (role . count) in role-counts
                              for body = (cdr (assoc role role-blocks :test #'%role-name-eq))
                              collect (prog1 (if gated
                                                 (list* (intern "%IN-WARP-ROLE" (find-package :crisp.compiler))
                                                        first-warp count body)
                                                 (cons progn-sym body))
                                        (incf first-warp count)))))
           ;; running-sum upper bounds t_1..t_n
           (thresholds (let ((acc 0))
                         (loop for (role . count) in role-counts
                               do (progn role) (incf acc count)
                               collect acc)))
           ;; Nested if with the LAST role as the final else — decision C guarantees warps
           ;; [t_{n-1}, t_n) are exactly that role and there are none beyond t_n, so we need no
           ;; numeric fall-through (which would clash types with the void role bodies).  For a
           ;; single role there is no branch at all.
           (nest (let ((acc (car (last bodies))))
                   (loop for i from (- n 2) downto 0
                         do (setf acc (list if-sym
                                            (list lt-sym wsid (nth i thresholds))
                                            (nth i bodies)
                                            acc)))
                   acc)))
      ;; (warp-id) is the STABLE block-local warp index — on PTX it now synthesizes
      ;; local-linear-id/32 (Endeavor 139 fixed it from the volatile %warpid); on SPV it is
      ;; SubgroupId.  Either way it is safe for the producer/consumer split.
      ;;
      ;; GATED NIL — endeavour 146, the BACKWARD lowering.  Roles partition WORK, not
      ;; mathematics, and every backward the engine emits for a tile-level operation is
      ;; WORKGROUP-COLLECTIVE by construction (workgroup-stride + sync-workgroup writing a
      ;; shared scratch adjoint).  Emitting that inside a warp-divergent gate is what the
      ;; divergence checker correctly rejects — only some warps would reach a barrier the
      ;; whole workgroup must reach.  So the backward runs the union of the role bodies
      ;; workgroup-wide.  Safe for collective bodies because workgroup-stride DISTRIBUTES
      ;; work rather than replicating it.  See the limitation noted in the 146 endeavor doc
      ;; for the case this does not cover.
      (if gated
          (list let-sym (list (list wsid (list to-int-sym (list warp-id-sym))))
                nest)
          (cons progn-sym bodies)))))

;; src/codegen.lisp
(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function.
   Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the
   PTX kernel-entry receive site can inttoptr demoted i64 params back
   to their original-addrspace pointer.
   Binds *kernel-readonly-tensor-syms* around the body codegen so the
   semantic-aref tensor case can attach !invariant.load to direct
   reads of read-only kernel-param tensors."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function))
        (is-entry-point (semantic-function-is-entry-point semantic-function))
        ;; Endeavour 193: the thread's die flag, set up below for a function that may die.
        (*die-flag-ptr* nil))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env is-entry-point)

    ;; Endeavour 208: a kernel with tcgen05 accumulators allocates its tensor memory here.
    (when is-entry-point
      (%208-emit-tmem-prologue builder module (semantic-function-name semantic-function)))

    ;; Endeavour 193: a function that may die gets the thread's die flag -- a kernel allocates and zeroes
    ;; it, a callee receives it as its trailing (LLVM-only) parameter.
    (when (%193-may-die-p (semantic-function-name semantic-function))
      (setf *die-flag-ptr*
            (if is-entry-point
                (let ((a (llvm-build-alloca builder (llvm-int32-type) "die_flag")))
                  (llvm-build-store builder (llvm-const-int (llvm-int32-type) 0 0) a)
                  a)
                (llvm-get-param func (1- (llvm-count-params func)))))
      (log:debug "193: die flag bound for ~a" (semantic-function-name semantic-function)))

    (let ((*kernel-readonly-tensor-syms*
           (%collect-readonly-tensor-param-syms semantic-function)))
      (when *kernel-readonly-tensor-syms*
        (log:debug "Read-only tensor params for kernel ~a: ~a"
                   (semantic-function-name semantic-function)
                   (loop for k being the hash-keys of *kernel-readonly-tensor-syms*
                         collect k)))

      (let* ((body-nodes (semantic-function-body semantic-function))
             (is-void-return (or (null return-types)
                                 (equal return-types '(nil))
                                 (and (consp return-types) (symbolp (first return-types)) (string-equal (first return-types) "VOID"))))
             (last-val nil)
             (last-loc nil))
        (dolist (node body-nodes)
          (multiple-value-bind (val loc)
              (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
            (setf last-val val)
            (setf last-loc loc)))

        ;; BUG 050: a CTA must not LEAVE its cluster while a peer may still be writing into
        ;; its shared memory.  With multicast that is exactly what happens -- the group leader
        ;; issues a copy whose destination is every member's SMEM -- so a member that finishes
        ;; its tiles and returns early can be written into after it is gone.  CUDA requires a
        ;; cluster sync before exit for precisely this reason.
        ;;
        ;; The existing fences are emitted at BARRIER CONSTRUCTION, i.e. in the prologue; there
        ;; was none before `ret`.  The failure is therefore a RACE, and shape-dependent: a narrow
        ;; output tile means less work per workgroup, which widens the window in which one member
        ;; can exit while peers are still streaming.  It reproduced as `unspecified launch
        ;; failure` at a 64x32 tile and vanished under compute-sanitizer, whose serialisation
        ;; closes the window -- the signature of a race rather than a bad address.
        ;; ARCH-GATED, and this was missed on the first cut: %module-has-cluster-p reports what
        ;; the SOURCE declared, not what codegen could build.  On a pre-Hopper target the cluster
        ;; is degraded to extent 1 (%apply-cluster-dims-attribute) and no .reqnctapercluster is
        ;; emitted -- but the fence was still emitted, putting a `barrier.cluster` instruction in
        ;; a module whose target has no clusters.  A degraded cluster needs no exit fence anyway:
        ;; with one workgroup per cluster there is no peer that could still be writing.
        ;; Endeavour 208: ...and frees it before ret.
        (when is-entry-point
          (%208-emit-tmem-epilogue builder module (semantic-function-name semantic-function)))
        (when (and (eq *target-backend* :ptx) is-entry-point (%module-has-cluster-p)
                   (%arch-supports-clusters-p (or *ir-target-arch* :sm_80)))
          (log:info "cluster kernel: emitting exit fence before ret (BUG 050)")
          (%gen-nvvm-cluster-barrier builder))
        (let ((ret-inst (if is-void-return
                            (llvm-build-ret-void builder)
                            (let* ((ret-type-spec (first return-types))
                                   (expected-type (crisp-type-to-llvm-type ret-type-spec module))
                                   (actual-type (llvm-type-of last-val)))
                              (if (and (llvm-type-kind-is-pointer? actual-type)
                                       (not (llvm-type-kind-is-pointer? expected-type)))
                                  (llvm-build-ret builder (llvm-build-load2 builder expected-type last-val "ret_val"))
                                  (llvm-build-ret builder last-val))))))
          (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc)))))))

;; src/mma.lisp
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!.
   Endeavour 154: adds STORE-TILE-AT, so a wgmma accumulator can be stored at an absolute origin
   (two cooperating consumer warpgroups); non-wgmma sources delegate unchanged."
  ;; Endeavour 208: tensor-memory bookkeeping is per compile.
  (clrhash *tcgen05-columns*)
  (clrhash *tcgen05-sync-sites*)
  (clrhash *tcgen05-kernels*)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         ;; Endeavour 208: tcgen05.  The store / let entries wrap the originals.
                         (cons "MAKE-TCGEN05-ACCUMULATOR"    #'analyze-make-tcgen05-accumulator)
                         (cons "TCGEN05-ACCUMULATE-VIA-TILE" #'analyze-tcgen05-accumulate-via-tile)
                         (cons "TCGEN05-COMMIT"              #'analyze-tcgen05-commit)
                         (cons "%TCGEN05-MMA"                #'analyze-%tcgen05-mma)
                         (cons "%TCGEN05-RESET"              #'analyze-%tcgen05-reset)
                         (cons "%TCGEN05-LD"                 #'analyze-%tcgen05-ld)
                         (cons "%TCGEN05-FENCE-AFTER"        #'analyze-%tcgen05-fence)
                         (cons "%TCGEN05-FENCE-BEFORE"       #'analyze-%tcgen05-fence)
                         (cons "%IN-WARP-ROLE"               #'analyze-%in-warp-role)
                         (cons "STORE-TILE"              #'%208-analyze-store-tile)
                         (cons "STORE-TILE-AT"           #'%208-analyze-store-tile-at)
                         (cons "LET"                     #'%208-analyze-let)
                         (cons "LET*"                    #'%208-analyze-let)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))
    ;; Endeavour 173 / BUG 069: Crisp has no LET* -- its LET is already sequential.  This is the
    ;; site that decides what `let*` means, because (intern "LET*" :crisp-language) HERE mints the
    ;; very symbol the Crisp reader later reuses for user source; the table above aliased it onto
    ;; LET, which compiled forward and then died under --differentiate blaming SET!.
    ;;
    ;; ONLY the :crisp-language spelling is rejected, which is why this sits outside the loop:
    ;; crisp.compiler uses :cl and does not shadow LET*, so (intern "LET*" cc-pkg) up there
    ;; returns COMMON-LISP:LET* -- a DIFFERENT symbol, which must stay pointed at the real LET
    ;; analyzer.  That is load-bearing, not merely tidy: instantiate-generic-function
    ;; (src/environment.lisp) injects `(let* ,bindings ,@body) to bind a &key parameter's
    ;; defaults, and that backquote is read in :crisp.compiler -- so a COMPILER LOWERING emits
    ;; the CL spelling.  Rejecting it too breaks every &key default (016-advanced-signatures/04).
    ;; User source, read in :crisp-language, reaches the rejected symbol instead.
    (setf (gethash (intern "LET*" cl-pkg) *expression-analyzers*) '%analyze-let-star-rejected)))

;; src/analysis/control.lisp
(defun ensure-branch-compatibility (then-node else-node location)
  "Unifies types of then/else branches. Returns (values unified-type new-then new-else).
   ADV-007: two enum-valued branches -- e.g. (if c :mul :add), whose keyword literals each
   have their own singleton type -- unify to their single common enumeration."
  (when else-node
    (let ((t-single (get-single-value-type then-node))
          (e-single (get-single-value-type else-node)))
      (unless (equal t-single e-single)
        (let* ((t-enums (%enum-type-for-branch t-single))
               (e-enums (%enum-type-for-branch e-single))
               (common (and t-enums e-enums (intersection t-enums e-enums))))
          (when (= (length common) 1)
            (log:debug "ensure-branch-compatibility: ~s / ~s unify to enum ~s" t-single e-single (first common))
            (return-from ensure-branch-compatibility
              (values (first common) then-node else-node)))))))
  (let ((t-type (semantic-node-type then-node)))
    (unless else-node
      ;; Propagate THEN type if no ELSE (implicitly returns void/nil or 0? 
      ;; Actually, for IF expression correctness, missing else implies value is unlikely to be used
      ;; unless it matches the implicit else value (int 0). 
      ;; For now, just return t-type. 
      (return-from ensure-branch-compatibility (values t-type then-node nil)))

    (let ((e-type (semantic-node-type else-node))
          (t-single (get-single-value-type then-node))
          (e-single (get-single-value-type else-node)))
      (if (equal t-type e-type)
          (values t-type then-node else-node)
          (let ((promoted (get-promoted-type t-single e-single)))
            (cond
             (promoted
               ;; Insert Casts
               (values promoted
                 (if (equal t-type promoted) then-node (create-implicit-cast then-node promoted location))
                 (if (equal e-type promoted) else-node (create-implicit-cast else-node promoted location))))

             ;; Special Case: Literal 0 (Int) can promote to any Pointer -> NULL
             ((and (eq t-single 'int) (typep then-node 'semantic-literal) (= (semantic-literal-value then-node) 0)
                   (listp e-type) (member (first e-type) '(ptr array)))
               (values e-type (create-implicit-cast then-node e-type location) else-node))

             ((and (eq e-single 'int) (typep else-node 'semantic-literal) (= (semantic-literal-value else-node) 0)
                   (listp t-type) (member (first t-type) '(ptr array)))
               (values t-type then-node (create-implicit-cast else-node t-type location)))

             ;; Void Compatibility. If BOTH branches are void, the if is void (a
             ;; statement (when ...) / (unless ...)).
             ((and (null t-single) (null e-single))
               (values '(nil) then-node else-node))
             ;; If only ONE branch is void — e.g. (if cond nil X), as produced by a
             ;; value-position (unless+ cond X) => (if+ cond nil X), or (if cond X nil)
             ;; — unify to the OTHER branch's real type. The void branch contributes
             ;; no value and its path is left undef by codegen (safe: under a uniform
             ;; if+/when+/unless+ condition that branch is untaken; for a plain
             ;; divergent if, using the value on the void path is the caller's
             ;; pre-existing undefined behaviour). This lets such an if be used as a
             ;; value, e.g. (set! (~ r) (unless+ ...)).
             ((null t-single)
               (values e-type then-node else-node))
             ((null e-single)
               (values t-type then-node else-node))

             ;; Endeavour 208: a statement node typed with the symbol VOID (dotimes, store-tile, the
             ;; tcgen05 forms) is void too.  The clauses above only knew NIL, so a warp-specialized kernel
             ;; whose role bodies end differently -- an epilogue ending in (signal ..), a producer ending
             ;; in a dotimes -- was refused here.  Only turns this error into the one-void-branch rule.
             ((and (symbolp t-single) (string= (symbol-name t-single) "VOID"))
               (values e-type then-node else-node))
             ((and (symbolp e-single) (string= (symbol-name e-single) "VOID"))
               (values t-type then-node else-node))
             (t
               (error "Branch type mismatch in IF expression. Then: ~a, Else: ~a" t-type e-type))))))))

;; src/mma.lisp
(defun %208-rewrite-acc-reinit (form)
  "Endeavour 208.  FORM with every (set! X (make-tcgen05-accumulator ...)) rewritten to
   (set! X (%tcgen05-reset X)).  STRUCTURE-PRESERVING: a subtree containing no such pattern is returned
   as the SAME conses (EQ), because source positions are looked up by cons identity -- copying every let
   body lost the file:line of every die / log site (193-logging-output printed `DIE ?:0`)."
  (cond ((atom form) form)
        ((and (symbolp (first form)) (string-equal (symbol-name (first form)) "SET!")
              (= (length form) 3) (symbolp (second form))
              (consp (third form)) (symbolp (first (third form)))
              (string-equal (symbol-name (first (third form))) "MAKE-TCGEN05-ACCUMULATOR"))
         (log:debug "208: (set! ~a (make-tcgen05-accumulator ..)) -> (%tcgen05-reset ~a)" (second form) (second form))
         (list (first form) (second form)
               (list (intern "%TCGEN05-RESET" (find-package :crisp.compiler)) (second form))))
        (t (let ((new-car (%208-rewrite-acc-reinit (car form)))
                 (new-cdr (%208-rewrite-acc-reinit (cdr form))))
             (if (and (eq new-car (car form)) (eq new-cdr (cdr form)))
                 form
                 (cons new-car new-cdr))))))

;; src/mma.lisp
(defun %208-analyze-let (expr env context location)
  "Endeavour 208.  LET: the accumulator re-initialisation rewrite, then the existing let analyzer.
   EXPR itself is passed through untouched (EQ) when nothing is rewritten.
   Fold: a first line in analyze-let-with-tile-explosion."
  (let* ((body (and (consp expr) (cddr expr)))
         (new-body (and body (%208-rewrite-acc-reinit body))))
    (analyze-let-with-tile-explosion (if (and body (not (eq new-body body)))
                                         (list* (first expr) (second expr) new-body)
                                         expr)
                                     env context location)))

;;;; ======================================================================
;;;; Endeavour 208 phase 2 -- tf32, the accumulator ring, and :via :tma from tensor memory.
;;;; See tests/spec/208-tcgen05/tcgen05.md.  Later copies of functions defined above REPLACE them.
;;;; ======================================================================

;; src/mma.lisp
(defvar *tcgen05-ring-dims* (make-hash-table :test 'eq)
  "Endeavour 208.  tcgen05 accumulator RING record type -> (M N ELEM RING-COUNT).")

;; src/mma.lisp
(defun %208-mma-kind (elem)
  "Endeavour 208.  For an operand element ELEM: (values KIND K-PER-INSTRUCTION FORMAT-CODE), the
   tcgen05.mma .kind, the K one instruction covers (always 32 bytes), and the a/b_format code of the
   instruction descriptor.  NIL for an element with no kind yet."
  (let ((n (and elem (symbolp elem) (symbol-name elem))))
    (cond ((null n) nil)
          ((string= n "HALF")     (values "f16"  16 0))
          ((string= n "BFLOAT16") (values "f16"  16 1))
          ((string= n "FLOAT")    (values "tf32"  8 2))
          (t nil))))

;; src/codegen.lisp
(defun %208-idesc (m n elem b-elem)
  "Endeavour 208.  The 32-bit instruction descriptor (CUTLASS UMMA::InstrDescriptor) for kind::f16 /
   kind::tf32: c_format F32 = 1 at [4,6); a_format / b_format at [7,10) / [10,13) (F16 0, BF16 1,
   TF32 2); A and B K-major (bits 15, 16 = 0); N >> 3 at [17,23); M >> 4 at [24,29)."
  (let ((af (nth-value 2 (%208-mma-kind elem)))
        (bf (nth-value 2 (%208-mma-kind b-elem))))
    (logior (ash 1 4) (ash af 7) (ash bf 10) (ash (ash n -3) 17) (ash (ash m -4) 24))))

;; src/mma.lisp
(defun %ensure-tcgen05-ring-type (m n elem count)
  "Endeavour 208.  Mint (once) the record naming a RING of COUNT tensor-memory accumulators: one uint
   field, COLUMN, the first column of slot 0.  Slot i starts at COLUMN + i*N."
  (let ((name (intern (format nil "TCGEN05-ACC-RING-~a-~dX~d-X~d" (if (%elem-integer-p elem) "S32" "F32") m n count)
                      (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name (list (list (intern "COLUMN" (find-package :crisp.compiler)) 'uint)) :record))
    (setf (gethash name *tcgen05-ring-dims*) (list m n elem count))
    name))

;; src/mma.lisp
(defun %tcgen05-ring-type-p (type-name)
  "Endeavour 208.  T if TYPE-NAME is a minted tcgen05 accumulator ring type."
  (and type-name (symbolp type-name) (nth-value 1 (gethash type-name *tcgen05-ring-dims*)) t))

;; src/mma.lisp
(defun %208-assign-columns (context location ncols form-name)
  "Endeavour 208.  The first tensor-memory column of the binding at LOCATION, assigned on first sight
   (NCOLS columns); refused when the kernel's total passes 512 (D-208-4)."
  (let* ((key  (%208-kernel-key context))
         (site (cons key location))
         (info (%208-kernel-info key)))
    (or (gethash site *tcgen05-columns*)
        (let* ((off   (getf info :columns 0))
               (total (+ off ncols)))
          (when (> total 512)
            (error 'crisp-compiler-error
                   :message (format nil "~a: this kernel's tcgen05 accumulators need ~a tensor-memory columns, over the 512 a CTA has.  A float (M N) accumulator takes N columns, so two 128 x 256 accumulators fill it." form-name total)
                   :source-location location))
          (setf (getf (gethash key *tcgen05-kernels*) :columns) total)
          (setf (gethash site *tcgen05-columns*) off)))))

;; src/mma.lisp
(defun analyze-make-tcgen05-accumulator-ring (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator-ring float (M N) :ring-count R) -> R accumulators in
   R*N consecutive tensor-memory columns.  (ring-get RING i) is accumulator i, FRESH: the first MMA
   into it overwrites.  Two slots let the epilogue drain tile t while the MMAs of tile t+1 run."
  (%tcgen05-require-arch "make-tcgen05-accumulator-ring" location)
  (destructuring-bind (elem dims &rest keys) (cdr expr)
    (let ((count (getf keys :ring-count)))
      (unless (and (symbolp elem) (string-equal (symbol-name elem) "FLOAT"))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: the element must be float, got ~a." elem)
               :source-location location))
      (unless (and (integerp count) (<= 1 count 4))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: :ring-count must be an integer from 1 to 4, got ~s." count)
               :source-location location))
      (unless (and (listp dims) (= (length dims) 2))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: the shape must be (M N), got ~s." dims)
               :source-location location))
      (destructuring-bind (m n) dims
        (%tcgen05-check-acc-shape m n location)
        (unless (and context (compiler-context-current-binding-name context))
          (error 'crisp-compiler-error
                 :message "make-tcgen05-accumulator-ring must initialise a let binding."
                 :source-location location))
        (%ensure-tcgen05-acc-type m n elem)
        (let ((offset (%208-assign-columns context location (* n count) "make-tcgen05-accumulator-ring"))
              (type-name (%ensure-tcgen05-ring-type m n elem count))
              (to-uint (intern "TO-UINT" (find-package :crisp-language))))
          (log:debug "208 make-tcgen05-accumulator-ring ~a x (~a ~a): columns ~a..~a"
                     count m n offset (+ offset (* n count) -1))
          (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset)) env context location))))))

;; src/mma.lisp
(defun %208-analyze-ring-get (expr env context location)
  "Endeavour 208.  (ring-get RING i) on a tcgen05 accumulator ring -> accumulator i, FRESH, at column
   COLUMN + i*N.  Every other ring goes to analyze-ring-get-expression unchanged.
   Fold: a first clause in analyze-ring-get-expression."
  (let* ((ring (second expr))
         (rtype (and (symbolp ring) (= (length expr) 3)
                     (ignore-errors (semantic-node-type (analyze-expression ring env context (append location '(1))))))))
    (if (%tcgen05-ring-type-p rtype)
        (destructuring-bind (m n elem count) (gethash rtype *tcgen05-ring-dims*)
          (declare (ignore count))
          (let ((acc-type (%ensure-tcgen05-acc-type m n elem))
                (to-uint (intern "TO-UINT" (find-package :crisp-language))))
            (log:debug "208 ring-get on tcgen05 ring ~a (~a)" ring rtype)
            (analyze-expression
             `(%construct-struct ,acc-type
                                 (+ (%extract-struct-member ,ring 0) (* (,to-uint ,(third expr)) (,to-uint ,n)))
                                 (,to-uint 1))
             env context location)))
        (analyze-ring-get-expression expr env context location))))

;; src/mma.lisp
(defun %208-source-type (src env context location)
  "Endeavour 208.  The type of a store source SRC when it is a symbol or a (ring-get ..) form, else
   NIL.  Only used to spot a tcgen05 accumulator; anything that fails to analyse here is left to the
   original analyzer."
  (and (or (symbolp src)
           (and (consp src) (symbolp (first src)) (string-equal (symbol-name (first src)) "RING-GET")))
       (ignore-errors (semantic-node-type (analyze-expression src env context (append location '(1)))))))

;; src/mma.lisp
(defun %208-analyze-tma-store (expr src convert env context location)
  "Endeavour 208.  (store-tile-at (to-bfloat16 D) C (ROW COL) :via :tma) for a tcgen05 accumulator D:
   the semantic-tcgen05-op :tma-store node.  Pass 1 (%199-scan-register-tma-store) already registered
   C's store descriptor (16 x 64 boxes, SWIZZLE_128B) and the function's staging buffer; the rules are
   199's -- a 16-bit conversion, N a multiple of 64, C a kernel tensor of that element, a compile-time
   local size -- plus the warpgroup rule (D-208-6)."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error
                  :message (format nil "store-tile-at :via :tma: ~?" fmt args)
                  :source-location location)))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node))
           (dest     (third expr))
           (origin   (fourth expr))
           (fn       (compiler-context-current-compiling-function context))
           (n        (second (gethash src-type *tcgen05-acc-dims*)))
           (elem     (and convert (%199-convert-element convert)))
           (dims     (%declared-local-size-dims (compiler-context-declarations context)))
           (threads  (and dims (reduce #'* dims)))
           (wgs      (and threads (floor threads 128)))
           (desc     (%199-descriptor-name dest fn))
           (stage    (%199-stage-name fn))
           (implicit (gethash fn *implicit-arg-map*))
           (info     (gethash desc *tma-descriptor-info*))
           (to-int   (intern "TO-INT" (find-package :crisp-language))))
      (log:debug "208 :via :tma: n=~a elem=~a dims=~a desc=~a stage=~a" n elem dims desc stage)
      (unless elem
        (fail "the TMA store moves 16-bit elements, so the f32 accumulator needs a conversion: write (to-half ~a) or (to-bfloat16 ~a)." src src))
      (unless (and dest (symbolp dest))
        (fail "the destination must be the kernel's tensor parameter (its TMA descriptor is built for it), got ~s." dest))
      (unless (and (listp origin) (= (length origin) 2))
        (fail "needs a 2-D (ROW COL) element origin, got ~s." origin))
      (unless (and n (zerop (mod n 64)))
        (fail "N must be a multiple of 64 (a TMA box is 64 16-bit columns = 128 bytes); this accumulator is 128x~a." n))
      (unless (and wgs (plusp wgs))
        (fail "needs the kernel's compile-time block size, (local-size :set-to N) with N at least 128: the staging buffer is 4 KB per warp."))
      (%tcgen05-check-epilogue-threads context location)
      (unless (and (find desc implicit :key #'car) (find stage implicit :key #'car))
        (fail "its TMA descriptor and staging buffer are registered in pass 1, which did not see this store (single-pass compile, or a store outside the kernel body)."))
      (unless (getf info :store-box)
        (fail "~a is also loaded with a :block load-tile in this kernel; a tensor has one TMA descriptor, and a load's box is not the store's." dest))
      (unless (valid-parameterized-type-p (cdr (find stage implicit :key #'car)))
        (fail "could not instantiate the staging buffer type ~a." (cdr (find stage implicit :key #'car))))
      (setf (gethash stage *implicit-scratch-size-expr-map*)
            (/ (+ (* wgs 4 *199-stage-bytes-per-warp*) 1024) 2))
      (log:info "208 store-tile-at :via :tma: 128x~a ~a into ~a; staging ~a = ~a warp slices x 4 KB + 1 KB"
                n elem dest stage (* 4 wgs))
      (make-semantic-tcgen05-op
       :op :tma-store
       :args (list src-node
                   (analyze-expression `(,to-int ,(first origin)) env context (append location '(3 0)))
                   (analyze-expression `(,to-int ,(second origin)) env context (append location '(3 1))))
       :plist (list :n n :element elem :dest-sym dest :stage stage
                    :stage-spec (cdr (find stage implicit :key #'car)) :slices (* 4 wgs))
       :type 'nil
       :source-location location))))

;; src/mma.lisp
(defun %208-analyze-store-tile-at (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin, directly or with :via :tma (%208-analyze-tma-store).  Anything else goes to
   analyze-store-tile-at-mma.  Fold: a clause in analyze-store-tile-at-mma."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (let* ((origin (fourth expr))
                 (keys   (nthcdr 4 expr))
                 (n      (second (gethash src-type *tcgen05-acc-dims*))))
            (cond ((null keys))
                  ((%199-via-tma-p keys)
                   (return-from %208-analyze-store-tile-at
                     (%208-analyze-tma-store expr src convert env context location)))
                  (t (error 'crisp-compiler-error
                            :message (format nil "store-tile-at: options ~s are not supported for a tcgen05 accumulator (only :via :tma)." keys)
                            :source-location location)))
            (unless (and (listp origin) (= (length origin) 2))
              (error 'crisp-compiler-error
                     :message (format nil "store-tile-at: a tcgen05 accumulator needs a 2-D (ROW COL) element origin, got ~s." origin)
                     :source-location location))
            (%tcgen05-check-epilogue-threads context location)
            (analyze-expression (%tcgen05-store-rewrite-origin src (third expr) (first origin) (second origin) n convert)
                                env context location))
          (analyze-store-tile-at-mma expr env context location)))))

;; src/codegen.lisp
(defun %208-tmem-ld32 (builder module taddr)
  "Endeavour 208.  tcgen05.ld.32x32b.x32 + wait::ld at TADDR: a list of 32 i32 values."
  (let* ((i32  (llvm-int32-type))
         (asm  (format nil "tcgen05.ld.sync.aligned.32x32b.x32.b32 {~{$~d~^, ~}}, [$32];~%	tcgen05.wait::ld.sync.aligned;"
                       (loop for i below 32 collect i)))
         (cons (format nil "~{~a~^,~},r,~~{memory}" (loop repeat 32 collect "=r")))
         (call (%build-inline-asm-call builder (%wgmma-struct-of-regs module i32 32) (list i32) (list taddr) asm cons)))
    (loop for i below 32 collect (llvm-build-extract-value builder call i (format nil "tc_v~d" i)))))

;; src/codegen.lisp
(defun %208-stage-base-i32 (builder var-env stage spec)
  "Endeavour 208.  The staging buffer's shared address (i32), as %199-stage-base-i32 finds it, from the
   implicit scratch record named STAGE with canonical type SPEC."
  (let ((slot (gethash stage var-env)))
    (unless slot
      (error "store-tile-at :via :tma: missing implicit staging argument ~a" stage))
    (let* ((sty (ensure-struct-llvm-type (mangle-template-struct-name (first spec) (rest spec))))
           (v   (llvm-build-load2 builder sty slot "tc_stage_rec")))
      (loop repeat 4
            for kind = (crisp.llvm-bindings::llvm-get-type-kind (llvm-type-of v))
            do (cl:cond
                 ((= kind crisp.llvm-bindings::+llvm-pointer-type-kind+)
                  (return-from %208-stage-base-i32
                    (llvm-build-ptr-to-int builder v (llvm-int32-type) "tc_stage_addr")))
                 ((= kind crisp.llvm-bindings::+llvm-struct-type-kind+)
                  (setf v (llvm-build-extract-value builder v 0 "tc_stage_field")))
                 (t (cl:return))))
      (error "store-tile-at :via :tma: could not find the staging buffer's pointer in ~a" stage))))

;; src/codegen.lisp
(defun %208-gen-tma-store (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  (store-tile-at (to-bfloat16 D) C (ROW COL) :via :tma) from tensor memory.  Each warp
   owns 32 accumulator rows (lane quarter warp mod 4), each thread one row.  Per 64-column chunk:
     tcgen05.ld two x32 -> 64 f32 -> 32 packed 16-bit pairs;
     the thread writes its 128-byte row into its warp's 4 KB staging slice -- two 16 x 64 boxes of
       2 KB, SWIZZLE_128B: 16-byte chunk j of box row r lives at chunk j ^ (r mod 8) -- as 8 x st.shared.v4;
     fence.proxy.async + bar.warp.sync; lane 0 issues the two box stores (rows +0 and +16), commit.
   Before a slice is rewritten, lane 0 waits for its previous reads; once more at the end.  The slice is
   warp mod (staging slices), so a warpgroup that is not at warp 0 still gets four distinct slices."
  (flet ((gen (n) (extract-primary-value builder
                                         (generate-node-ir n builder module var-env di-builder di-scope location-map)
                                         (semantic-node-type n))))
    (destructuring-bind (d-node row-node col-node) (semantic-tcgen05-op-args node)
      (let* ((pl     (semantic-tcgen05-op-plist node))
             (i32    (llvm-int32-type))
             (i64    (llvm-int64-type))
             (n      (getf pl :n))
             (bf16-p (string= (symbol-name (getf pl :element)) "BFLOAT16"))
             (h16    (if bf16-p (crisp.llvm-bindings::llvm-bfloat-type) (crisp.llvm-bindings::llvm-half-type)))
             (v2f    (llvm-vector-type (llvm-float-type) 2))
             (v2h    (llvm-vector-type h16 2))
             (d-val  (gen d-node))
             (row0   (gen row-node))
             (col0   (gen col-node))
             (desc   (%tma-lookup-descriptor-ptr builder var-env (getf pl :dest-sym)
                                                 (llvm-pointer-type (llvm-int8-type) 1))))
        (unless desc
          (error "store-tile-at :via :tma: no CUtensorMap descriptor for ~a in var-env" (getf pl :dest-sym)))
        (flet ((k (v) (llvm-const-int i32 v nil))
               (asm (types args text cons) (%build-inline-asm-call builder (llvm-void-type) types args text cons)))
          (let* ((tmap  (llvm-build-ptr-to-int
                         builder (llvm-build-addrspace-cast builder desc (llvm-pointer-type (llvm-int8-type) 0) "tc_map")
                         i64 "tc_map_i64"))
                 (tid   (%208-linear-tid builder module))
                 (lane  (crisp.llvm-bindings::llvm-build-and builder tid (k 31) "tc_lane"))
                 (warp  (crisp.llvm-bindings::llvm-build-l-shr builder tid (k 5) "tc_warp"))
                 (wq    (crisp.llvm-bindings::llvm-build-and builder warp (k 3) "tc_wq"))
                 (slice (crisp.llvm-bindings::llvm-build-urem builder warp (k (getf pl :slices)) "tc_slice"))
                 (stage (%208-stage-base-i32 builder var-env (getf pl :stage) (getf pl :stage-spec)))
                 (align (crisp.llvm-bindings::llvm-build-and builder (llvm-build-add builder stage (k 1023) "tc_pad")
                                                             (k #xFFFFFC00) "tc_1k"))
                 (base  (llvm-build-add builder align (llvm-build-mul builder slice (k *199-stage-bytes-per-warp*) "tc_soff")
                                        "tc_slice_base"))
                 (y0    (llvm-build-add builder row0 (crisp.llvm-bindings::llvm-build-shl builder wq (k 5) "tc_wq32") "tc_y"))
                 (box   (crisp.llvm-bindings::llvm-build-l-shr builder lane (k 4) "tc_box"))
                 (rr    (crisp.llvm-bindings::llvm-build-and builder lane (k 15) "tc_rr"))
                 (sw    (crisp.llvm-bindings::llvm-build-and builder rr (k 7) "tc_sw"))
                 (rowb  (llvm-build-add builder base
                                        (llvm-build-add builder (crisp.llvm-bindings::llvm-build-shl builder box (k 11) "tc_box2k")
                                                        (crisp.llvm-bindings::llvm-build-shl builder rr (k 7) "tc_rr128") "tc_rowoff")
                                        "tc_row_base"))
                 (tbase (llvm-build-add builder
                                        (llvm-build-add builder (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base")
                                                        (llvm-build-extract-value builder d-val 0 "tc_col") "tc_t0")
                                        (crisp.llvm-bindings::llvm-build-shl builder wq (k 21) "tc_lane_bits") "tc_tbase")))
            (%208-asm builder "tcgen05.fence::after_thread_sync;")
            (dotimes (c (floor n 64))
              (when (plusp c)
                (asm (list i32) (list lane)
                     "{ .reg .pred p; setp.eq.u32 p, $0, 0; @p cp.async.bulk.wait_group.read 0; }" "r")
                (asm nil nil "bar.warp.sync -1;" ""))
              (let* ((vals (append (%208-tmem-ld32 builder module (llvm-build-add builder tbase (k (* 64 c)) "tc_ta"))
                                   (%208-tmem-ld32 builder module (llvm-build-add builder tbase (k (+ (* 64 c) 32)) "tc_tb"))))
                     (packed (loop for (lo hi) on vals by #'cddr
                                   collect (let* ((v (llvm-build-insert-element
                                                      builder (llvm-get-undef v2f)
                                                      (llvm-build-bit-cast builder lo (llvm-float-type) "tc_lo") (k 0) "tc_p0"))
                                                  (v (llvm-build-insert-element
                                                      builder v (llvm-build-bit-cast builder hi (llvm-float-type) "tc_hi") (k 1) "tc_p1")))
                                             (llvm-build-bit-cast builder (llvm-build-fp-trunc builder v v2h "tc_cvt") i32 "tc_b32")))))
                (dotimes (j 8)
                  (let ((addr (llvm-build-add builder rowb
                                              (crisp.llvm-bindings::llvm-build-shl
                                               builder (crisp.llvm-bindings::llvm-build-xor builder (k j) sw "tc_jx") (k 4) "tc_j16")
                                              "tc_st")))
                    (asm (list i32 i32 i32 i32 i32)
                         (list addr (nth (* 4 j) packed) (nth (+ (* 4 j) 1) packed)
                               (nth (+ (* 4 j) 2) packed) (nth (+ (* 4 j) 3) packed))
                         "st.shared.v4.b32 [$0], {$1, $2, $3, $4};" "r,r,r,r,r"))))
              (asm nil nil "fence.proxy.async.shared::cta;" "")
              (asm nil nil "bar.warp.sync -1;" "")
              (dotimes (b 2)
                (asm (list i32 i64 i32 i32 i32)
                     (list lane tmap
                           (llvm-build-add builder col0 (k (* 64 c)) "tc_x")
                           (if (zerop b) y0 (llvm-build-add builder y0 (k 16) "tc_y16"))
                           (if (zerop b) base (llvm-build-add builder base (k 2048) "tc_src")))
                     "{ .reg .pred p; setp.eq.u32 p, $0, 0; @p cp.async.bulk.tensor.2d.global.shared::cta.bulk_group [$1, {$2, $3}], [$4]; }"
                     "r,l,r,r,r"))
              (asm (list i32) (list lane)
                   "{ .reg .pred p; setp.eq.u32 p, $0, 0; @p cp.async.bulk.commit_group; }" "r"))
            (asm (list i32) (list lane)
                 "{ .reg .pred p; setp.eq.u32 p, $0, 0; @p cp.async.bulk.wait_group.read 0; }" "r")
            (asm nil nil "bar.warp.sync -1;" "")
            (%208-asm builder "tcgen05.fence::before_thread_sync;")
            (log:debug "208 codegen :via :tma: N=~a chunks=~a ~a slices=~a" n (floor n 64) (if bf16-p "bf16" "f16") (getf pl :slices))
            (values (llvm-const-int i64 0 nil) nil)))))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-tcgen05-op) builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  Dispatch on the tcgen05 operation."
  (let ((void (lambda () (values (llvm-const-int (llvm-int64-type) 0 nil) nil))))
    (ecase (semantic-tcgen05-op-op node)
      (:mma (%208-gen-mma node builder module var-env di-builder di-scope location-map))
      (:ld  (%208-gen-ld node builder module var-env di-builder di-scope location-map))
      (:tma-store (%208-gen-tma-store node builder module var-env di-builder di-scope location-map))
      (:commit
       (let* ((bar-addr (%208-barrier-addr builder (generate-node-ir (first (semantic-tcgen05-op-args node))
                                                                    builder module var-env di-builder di-scope location-map)))
              (i32 (llvm-int32-type))
              (tid (%208-linear-tid builder module)))
         (%208-if builder (llvm-build-icmp builder +llvm-int-eq+ tid
                                           (llvm-const-int i32 (* 32 (getf (semantic-tcgen05-op-plist node) :issue-warp)) nil)
                                           "tc_committer")
                  (lambda () (%208-commit-asm builder bar-addr))
                  "tc_commit")
         (funcall void)))
      (:fence-after  (%208-asm builder "tcgen05.fence::after_thread_sync;")  (funcall void))
      (:fence-before (%208-asm builder "tcgen05.fence::before_thread_sync;") (funcall void)))))

;; src/mma.lisp
(defun analyze-tcgen05-accumulate-via-tile (expr env context location)
  "Endeavour 208.  (tcgen05-accumulate-via-tile (M N K) D A B :swizzle :128b [:on-complete BAR])
   -> (set! D (%tcgen05-mma D A B K [BAR])).  D += A.B over K, issued by one thread into tensor memory.

   Without :on-complete it is SYNCHRONOUS (D-208-2): the issuing thread commits to a compiler-owned
   mbarrier and every thread executing the form waits on it.  With :on-complete BAR it commits to BAR
   and returns at once.

   Operands: half / bfloat16 (kind::f16, K = 64) or float (kind::tf32, K = 32) -- either way one
   128-byte swizzle atom of K, four instructions.  M = 128; A (M K) and B (N K) K-major in shared
   memory as a :128b TMA load lays them down."
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
        (unless (and (%208-mma-kind elem) (%208-mma-kind b-elem)
                     (string= (symbol-name elem) (symbol-name b-elem)))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: A and B must both be half, both bfloat16 (kind::f16) or both float (kind::tf32), got ~a and ~a." elem b-elem)
                 :source-location location))
        (unless (and swz (symbolp swz) (string-equal (symbol-name swz) "128B"))
          (error 'crisp-compiler-error
                 :message "tcgen05-accumulate-via-tile needs :swizzle :128b: A and B are read through shared-memory descriptors built for the 128-byte swizzle that a (load-tile .. :swizzle :128b) TMA load lays down."
                 :source-location location))
        (unless (and (symbolp bm) (string-equal (symbol-name bm) "K"))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major ~s is not supported yet; B must be (N K), K-major." bm)
                 :source-location location))
        (let ((want (* 4 (nth-value 1 (%208-mma-kind elem)))))
          (unless (= k want)
            (error 'crisp-compiler-error
                   :message (if (= want 64)
                                (format nil "tcgen05-accumulate-via-tile: K must be 64 for half / bfloat16 (one 128-byte swizzle atom: four K = 16 instructions), got ~a." k)
                                (format nil "tcgen05-accumulate-via-tile: K must be 32 for float / tf32 (one 128-byte swizzle atom: four K = 8 instructions), got ~a." k))
                   :source-location location)))
        ;; Operand extents, when known: A (M K), B (N K).
        (let ((a-r (%mma-operand-extent a nil :rows)) (a-c (%mma-operand-extent a nil :cols))
              (b-r (%mma-operand-extent b nil :rows)) (b-c (%mma-operand-extent b nil :cols)))
          (when (or (and a-r (/= a-r m)) (and a-c (/= a-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: A tile must be (M K) = (~a ~a), but it is (~a ~a)." m k (or a-r '?) (or a-c '?))
                   :source-location location))
          (when (or (and b-r (/= b-r n)) (and b-c (/= b-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: B tile must be (N K) = (~a ~a), K-major as for wgmma, but it is (~a ~a)." n k (or b-r '?) (or b-c '?))
                   :source-location location)))
        (analyze-expression `(set! ,d (%tcgen05-mma ,d ,a ,b ,k ,@(when bar (list bar))))
                            env context location)))))

;; src/codegen.lisp
(defun %208-gen-mma (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  D += A.B: lane 0 of the issuing warp builds the descriptors and issues K/16
   tcgen05.mma.kind::f16 (the first with enable-input-d = !FRESH, the rest accumulating), then commits
   -- to :on-complete's barrier, or to this site's own mbarrier, on which every executing thread then
   waits (parity from an entry-block visit counter) before fence::after_thread_sync.  Returns D with
   FRESH cleared."
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
             (idesc  (%208-idesc (getf pl :m) (getf pl :n) (getf pl :elem) (getf pl :b-elem)))
             (kind   (%208-mma-kind (getf pl :elem)))
             (slices (floor (getf pl :k) (nth-value 1 (%208-mma-kind (getf pl :elem))))))
        ;; As for wgmma: a tf32 MMA under a non-fast precision silently does not honour IEEE.
        (when (and (string= kind "tf32") (not (eq *math-precision* :fast)))
          (format *error-output*
                  "WARNING: tcgen05-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                  *math-precision*))
        (unless (and a-ptr b-ptr)
          (error "tcgen05: A/B (~ tile 0 0) did not yield a shared-memory pointer (a ~a b ~a)" a-ptr b-ptr))
        (log:debug "208 gen mma: idesc #x~8,'0x slices ~a issue-warp ~a site ~a on-complete ~a"
                   idesc slices (getf pl :issue-warp) site (and bar-node t))
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
                                       (%208-smem-desc builder b-ptr (* kk 32))
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

;; src/mma.lisp
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!.
   Endeavour 154: adds STORE-TILE-AT, so a wgmma accumulator can be stored at an absolute origin
   (two cooperating consumer warpgroups); non-wgmma sources delegate unchanged."
  ;; Endeavour 208: tensor-memory bookkeeping is per compile.
  (clrhash *tcgen05-columns*)
  (clrhash *tcgen05-sync-sites*)
  (clrhash *tcgen05-kernels*)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         ;; Endeavour 208: tcgen05.  The store / let entries wrap the originals.
                         (cons "MAKE-TCGEN05-ACCUMULATOR"    #'analyze-make-tcgen05-accumulator)
                         (cons "TCGEN05-ACCUMULATE-VIA-TILE" #'analyze-tcgen05-accumulate-via-tile)
                         (cons "TCGEN05-COMMIT"              #'analyze-tcgen05-commit)
                         (cons "%TCGEN05-MMA"                #'analyze-%tcgen05-mma)
                         (cons "%TCGEN05-RESET"              #'analyze-%tcgen05-reset)
                         (cons "%TCGEN05-LD"                 #'analyze-%tcgen05-ld)
                         (cons "%TCGEN05-FENCE-AFTER"        #'analyze-%tcgen05-fence)
                         (cons "%TCGEN05-FENCE-BEFORE"       #'analyze-%tcgen05-fence)
                         (cons "%IN-WARP-ROLE"               #'analyze-%in-warp-role)
                         ;; Endeavour 208 phase 2: the accumulator ring.  RING-GET wraps the struct analyzer's.
                         (cons "MAKE-TCGEN05-ACCUMULATOR-RING" #'analyze-make-tcgen05-accumulator-ring)
                         (cons "RING-GET"                    #'%208-analyze-ring-get)
                         (cons "STORE-TILE"              #'%208-analyze-store-tile)
                         (cons "STORE-TILE-AT"           #'%208-analyze-store-tile-at)
                         (cons "LET"                     #'%208-analyze-let)
                         (cons "LET*"                    #'%208-analyze-let)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))
    ;; Endeavour 173 / BUG 069: Crisp has no LET* -- its LET is already sequential.  This is the
    ;; site that decides what `let*` means, because (intern "LET*" :crisp-language) HERE mints the
    ;; very symbol the Crisp reader later reuses for user source; the table above aliased it onto
    ;; LET, which compiled forward and then died under --differentiate blaming SET!.
    ;;
    ;; ONLY the :crisp-language spelling is rejected, which is why this sits outside the loop:
    ;; crisp.compiler uses :cl and does not shadow LET*, so (intern "LET*" cc-pkg) up there
    ;; returns COMMON-LISP:LET* -- a DIFFERENT symbol, which must stay pointed at the real LET
    ;; analyzer.  That is load-bearing, not merely tidy: instantiate-generic-function
    ;; (src/environment.lisp) injects `(let* ,bindings ,@body) to bind a &key parameter's
    ;; defaults, and that backquote is read in :crisp.compiler -- so a COMPILER LOWERING emits
    ;; the CL spelling.  Rejecting it too breaks every &key default (016-advanced-signatures/04).
    ;; User source, read in :crisp-language, reaches the rejected symbol instead.
    (setf (gethash (intern "LET*" cl-pkg) *expression-analyzers*) '%analyze-let-star-rejected)))

;;;; ======================================================================
;;;; Endeavour 208 phase 3 -- int8 / qint through tcgen05: kind::i8 into an s32 tensor-memory
;;;; accumulator.  See tests/spec/208-tcgen05/tcgen05.md.  Later copies of functions defined above
;;;; REPLACE them.
;;;; ======================================================================

;; src/mma.lisp
(defun %208-acc-elem (elem form-name location)
  "Endeavour 208 phase 3.  The canonical element type of a tcgen05 accumulator.  Accepted: float (an
   f32 accumulator, for 16-bit and tf32 operands), or a 32-bit integer -- int, uint, a type derived
   from one, or (accum Q) -- for kind::i8's s32 accumulator.  Anything else is refused, naming
   FORM-NAME."
  (let ((ce (%canonical-elem elem)))
    (log:debug "208 %208-acc-elem ~s -> ~s" elem ce)
    (cond ((and (symbolp ce) (string-equal (symbol-name ce) "FLOAT")) ce)
          ((and ce (%elem-integer-p ce) (eql (%mma-elem-bits ce) 32)) ce)
          (t (error 'crisp-compiler-error
                    :message (format nil "~a: the element must be float (an f32 accumulator, for half / bfloat16 / float operands) or a 32-bit integer such as int or (accum Q) (an s32 accumulator, for char / uchar operands); got ~(~a~)."
                                     form-name elem)
                    :source-location location)))))

;; src/mma.lisp
(defun %208-mma-kind (elem)
  "Endeavour 208.  For an operand element ELEM: (values KIND K-PER-INSTRUCTION FORMAT-CODE), the
   tcgen05.mma .kind, the K one instruction covers (always 32 bytes), and the a/b_format code of the
   instruction descriptor.  NIL for an element with no kind yet.

   Phase 3: an 8-bit integer (char, uchar, or a type derived from one, e.g. a def-qint) is kind::i8,
   K = 32, format INT8 = 1 / UINT8 = 0 (CUTLASS UMMA::S8Format).  A and B carry their own format,
   so the four sign pairs are one instruction."
  (let ((n (and elem (symbolp elem) (symbol-name elem))))
    (cond ((null n) nil)
          ((%int-operand-p elem) (values "i8" 32 (if (%elem-signed-p elem) 1 0)))
          ((string= n "HALF")     (values "f16"  16 0))
          ((string= n "BFLOAT16") (values "f16"  16 1))
          ((string= n "FLOAT")    (values "tf32"  8 2))
          (t nil))))

;; src/codegen.lisp
(defun %208-idesc (m n elem b-elem)
  "Endeavour 208.  The 32-bit instruction descriptor (CUTLASS UMMA::InstrDescriptor):
   c_format at [4,6) (F32 = 1, S32 = 2); a_format / b_format at [7,10) / [10,13) (F16 0, BF16 1,
   TF32 2; UINT8 0, INT8 1); A and B K-major (bits 15, 16 = 0); N >> 3 at [17,23); M >> 4 at
   [24,29).  Saturate (bit 3) stays 0: an s32 accumulator wraps, as mma.sync's does."
  (let ((af (nth-value 2 (%208-mma-kind elem)))
        (bf (nth-value 2 (%208-mma-kind b-elem)))
        (cf (if (%int-operand-p elem) 2 1)))
    (logior (ash cf 4) (ash af 7) (ash bf 10) (ash (ash n -3) 17) (ash (ash m -4) 24))))

;; src/mma.lisp
(defun %ensure-tcgen05-row-type-s32 ()
  "Endeavour 208 phase 3.  The s32 twin of TCGEN05-ROW32-F32: 32 int fields, the 32 consecutive
   columns of the calling thread's own tensor-memory lane, for an integer accumulator."
  (let ((name (intern "TCGEN05-ROW32-S32" (find-package :crisp.compiler))))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below 32 collect (list (intern (format nil "R~d" i) (find-package :crisp.compiler)) 'int))
       :record))
    name))

;; src/mma.lisp
(defun %208-acc-int-p (acc-type)
  "Endeavour 208 phase 3.  T when ACC-TYPE (a minted tcgen05 accumulator record) holds s32."
  (let ((dims (gethash acc-type *tcgen05-acc-dims*)))
    (and dims (%elem-integer-p (third dims)) t)))

;; src/mma.lisp
(defun analyze-%tcgen05-ld (expr env context location)
  "Endeavour 208.  (%tcgen05-ld D CHUNK) -> the 32 columns [32*CHUNK, 32*CHUNK+32) of the calling
   thread's accumulator row, as a TCGEN05-ROW32-F32 record (tcgen05.ld.32x32b.x32 + wait::ld).
   Phase 3: an s32 accumulator reads into TCGEN05-ROW32-S32 instead -- the same instruction, the
   32-bit cells taken as int."
  (destructuring-bind (d chunk) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (int-p  (%208-acc-int-p (semantic-node-type d-node))))
      (log:debug "208 %tcgen05-ld chunk ~a of ~a (~a)" chunk (semantic-node-type d-node) (if int-p "s32" "f32"))
      (make-semantic-tcgen05-op
       :op :ld
       :args (list d-node)
       :plist (list :chunk chunk :int int-p)
       :type (if int-p (%ensure-tcgen05-row-type-s32) (%ensure-tcgen05-row-type))
       :source-location location))))

;; src/mma.lisp
(defun analyze-make-tcgen05-accumulator (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator float (M N) 0.0) -> a tensor-memory accumulator.
   Phase 3: (make-tcgen05-accumulator int (M N) 0), or (accum Q) for a def-qint Q, is an s32
   accumulator for kind::i8; it also takes N columns (one 32-bit cell per element).
   It must initialise a let binding: its columns are assigned per binding SITE, N columns for a float
   accumulator, and the kernel's total may not exceed the 512 a CTA has (D-208-4).  The init must
   be zero (D-208-5).  `(set! D (make-tcgen05-accumulator ..))` re-initialises D in place: the let
   pre-pass rewrites it to (%tcgen05-reset D), which keeps D's columns and marks it FRESH."
  (%tcgen05-require-arch "make-tcgen05-accumulator" location)
  (unless (= (length expr) 4)
    (error 'crisp-compiler-error
           :message "make-tcgen05-accumulator: expected (make-tcgen05-accumulator float (M N) 0.0) or (make-tcgen05-accumulator int (M N) 0)."
           :source-location location))
  (destructuring-bind (elem dims init) (cdr expr)
    (setf elem (%208-acc-elem elem "make-tcgen05-accumulator" location))
    (unless (and (listp dims) (= (length dims) 2))
      (error 'crisp-compiler-error
             :message (format nil "make-tcgen05-accumulator: the shape must be (M N), got ~s." dims)
             :source-location location))
    (destructuring-bind (m n) dims
      (%tcgen05-check-acc-shape m n location)
      (unless (and (numberp init) (zerop init))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator: the initial value must be 0, got ~s.  The first MMA after initialisation overwrites the accumulator instead of adding to it, so zero costs nothing; any other start would need a pass that stores it into tensor memory." init)
               :source-location location))
      (unless (and context (compiler-context-current-binding-name context))
        (error 'crisp-compiler-error
               :message "make-tcgen05-accumulator must initialise a let binding, e.g. (let ((D (make-tcgen05-accumulator float (128 256) 0.0))) ...).  Re-initialise it with (set! D (make-tcgen05-accumulator float (128 256) 0.0))."
               :source-location location))
      (let* ((key    (%208-kernel-key context))
             (site   (cons key location))
             (info   (%208-kernel-info key))
             (offset (or (gethash site *tcgen05-columns*)
                         (let* ((off   (getf info :columns 0))
                                (total (+ off n)))
                           (when (> total 512)
                             (error 'crisp-compiler-error
                                    :message (format nil "make-tcgen05-accumulator: this kernel's tcgen05 accumulators need ~a tensor-memory columns, over the 512 a CTA has.  A float (M N) accumulator takes N columns, so two 128 x 256 accumulators fill it." total)
                                    :source-location location))
                           (setf (getf (gethash key *tcgen05-kernels*) :columns) total)
                           (setf (gethash site *tcgen05-columns*) off))))
             (type-name (%ensure-tcgen05-acc-type m n elem))
             (to-uint (intern "TO-UINT" (find-package :crisp-language))))
        (log:debug "208 make-tcgen05-accumulator ~a (~a ~a) in ~a: columns ~a..~a"
                   (compiler-context-current-binding-name context) m n key offset (+ offset n -1))
        (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset) (,to-uint 1))
                            env context location)))))

;; src/mma.lisp
(defun analyze-make-tcgen05-accumulator-ring (expr env context location)
  "Endeavour 208.  (make-tcgen05-accumulator-ring float (M N) :ring-count R) -> R accumulators in
   R*N consecutive tensor-memory columns.  (ring-get RING i) is accumulator i, FRESH: the first MMA
   into it overwrites.  Two slots let the epilogue drain tile t while the MMAs of tile t+1 run.
   Phase 3: an integer element (int, (accum Q)) makes s32 slots, as for make-tcgen05-accumulator."
  (%tcgen05-require-arch "make-tcgen05-accumulator-ring" location)
  (destructuring-bind (elem dims &rest keys) (cdr expr)
    (let ((count (getf keys :ring-count)))
      (setf elem (%208-acc-elem elem "make-tcgen05-accumulator-ring" location))
      (unless (and (integerp count) (<= 1 count 4))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: :ring-count must be an integer from 1 to 4, got ~s." count)
               :source-location location))
      (unless (and (listp dims) (= (length dims) 2))
        (error 'crisp-compiler-error
               :message (format nil "make-tcgen05-accumulator-ring: the shape must be (M N), got ~s." dims)
               :source-location location))
      (destructuring-bind (m n) dims
        (%tcgen05-check-acc-shape m n location)
        (unless (and context (compiler-context-current-binding-name context))
          (error 'crisp-compiler-error
                 :message "make-tcgen05-accumulator-ring must initialise a let binding."
                 :source-location location))
        (%ensure-tcgen05-acc-type m n elem)
        (let ((offset (%208-assign-columns context location (* n count) "make-tcgen05-accumulator-ring"))
              (type-name (%ensure-tcgen05-ring-type m n elem count))
              (to-uint (intern "TO-UINT" (find-package :crisp-language))))
          (log:debug "208 make-tcgen05-accumulator-ring ~a x (~a ~a): columns ~a..~a"
                     count m n offset (+ offset (* n count) -1))
          (analyze-expression `(%construct-struct ,type-name (,to-uint ,offset)) env context location))))))

;; src/mma.lisp
(defun analyze-tcgen05-accumulate-via-tile (expr env context location)
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
   memory as a :128b TMA load lays them down."
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
        (unless (and (symbolp bm) (string-equal (symbol-name bm) "K"))
          (error 'crisp-compiler-error
                 :message (format nil "tcgen05-accumulate-via-tile: :b-major ~s is not supported yet; B must be (N K), K-major." bm)
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
          (when (or (and b-r (/= b-r n)) (and b-c (/= b-c k)))
            (error 'crisp-compiler-error
                   :message (format nil "tcgen05-accumulate-via-tile: B tile must be (N K) = (~a ~a), K-major as for wgmma, but it is (~a ~a)." n k (or b-r '?) (or b-c '?))
                   :source-location location)))
        (analyze-expression `(set! ,d (%tcgen05-mma ,d ,a ,b ,k ,@(when bar (list bar))))
                            env context location)))))

;; src/codegen.lisp
(defun %208-gen-ld (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  tcgen05.ld.sync.aligned.32x32b.x32 + wait::ld: the thread's own lane (32(warp mod 4)
   + lane) and the 32 columns of chunk C.  Phase 3: an s32 row (plist :int) keeps the cells as i32;
   an f32 row bitcasts them.  Address = base + COLUMN + 32C + (lane << 16); the lane's
   32(warp mod 4) part is (warp mod 4) << 21.  Returns the TCGEN05-ROW32-F32 record."
  (let* ((d-node (first (semantic-tcgen05-op-args node)))
         (chunk  (getf (semantic-tcgen05-op-plist node) :chunk))
         (i32    (llvm-int32-type))
         (d-val  (extract-primary-value builder
                                        (generate-node-ir d-node builder module var-env di-builder di-scope location-map)
                                        (semantic-node-type d-node)))
         (col    (llvm-build-extract-value builder d-val 0 "tc_col"))
         (tid    (%208-linear-tid builder module))
         (w4     (crisp.llvm-bindings::llvm-build-and
                  builder (crisp.llvm-bindings::llvm-build-l-shr builder tid (llvm-const-int i32 5 nil) "tc_warp")
                  (llvm-const-int i32 3 nil) "tc_wq"))
         (lane   (crisp.llvm-bindings::llvm-build-shl builder w4 (llvm-const-int i32 21 nil) "tc_lane_bits"))
         (base   (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base"))
         (addr   (llvm-build-add builder
                                 (llvm-build-add builder (llvm-build-add builder base col "tc_a0") lane "tc_a1")
                                 (llvm-const-int i32 (* 32 chunk) nil) "tc_taddr"))
         (asm    (format nil "tcgen05.ld.sync.aligned.32x32b.x32.b32 {~{$~d~^, ~}}, [$32];~%	tcgen05.wait::ld.sync.aligned;"
                         (loop for i below 32 collect i)))
         (cons   (format nil "~{~a~^,~},r,~~{memory}" (loop repeat 32 collect "=r")))
         (call   (%build-inline-asm-call builder (%wgmma-struct-of-regs module i32 32) (list i32) (list addr) asm cons))
         (row-type (semantic-tcgen05-op-type node))
         (agg    (llvm-get-undef (crisp-type-to-llvm-type row-type module))))
    (dotimes (i 32)
      (setf agg (llvm-build-insert-value
                 builder agg
                 (let ((cell (llvm-build-extract-value builder call i (format nil "tc_r~d" i))))
                   (if (getf (semantic-tcgen05-op-plist node) :int)
                       cell
                       (llvm-build-bit-cast builder cell (llvm-float-type) (format nil "tc_f~d" i))))
                 i (format nil "tc_row~d" i))))
    (values agg nil)))

;; src/mma.lisp
(defun %qint-mma-binding-elems (bindings)
  "Alist (SYM . SOURCE-ELEM) for BINDINGS.  A tile / scratch / wgmma-accumulator constructor gives
   its element type; any other binding maps to NIL, so it SHADOWS an outer name as unknown.
   Endeavour 208: tcgen05 accumulators and accumulator rings too."
  (let ((out '()))
    (dolist (b bindings (nreverse out))
      (cond ((and (consp b) (symbolp (first b)))
             (let ((init (second b)))
               (push (cons (first b)
                           (and (consp init) (symbolp (first init))
                                (member (symbol-name (first init))
                                        '("MAKE-REGISTER-TILE" "MAKE-REGISTER-TILE-RING"
                                          "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-MATRIX-RING"
                                          "MAKE-WGMMA-ACCUMULATOR"
                                          "MAKE-TCGEN05-ACCUMULATOR" "MAKE-TCGEN05-ACCUMULATOR-RING")
                                        :test #'string=)
                                (%canonical-elem (second init))))
                     out)))
            ((and b (symbolp b))
             (push (cons b nil) out))))))

;; src/mma.lisp
(defun %qint-mma-walk (form lex env location)
  "Walks FORM applying %check-mma-qint-roles to every mma-accumulate-via-tile, wgmma-accumulate and
   wgmma-accumulate-via-tile, extending LEX through nested LETs.  A check runs only when A, B and C
   are all known.
   Endeavour 208: tcgen05-accumulate-via-tile too (D A B at the same positions)."
  (when (consp form)
    (let* ((head (first form))
           (hn (and (symbolp head) (symbol-name head))))
      (labels ((src (f) (%qint-mma-src-elem f lex env))
               (check (c a b)
                 (let ((cs (src c)) (as (src a)) (bs (src b)))
                   (when (and cs as bs)
                     (%check-mma-qint-roles as bs cs location))))
               (walk-all (forms l)
                 (loop for x on forms while (consp x) do (%qint-mma-walk (car x) l env location))))
        (cond
          ((and hn (member hn '("LET" "LET*") :test #'string=) (listp (second form)))
           (dolist (b (second form))
             (when (consp b) (walk-all (cdr b) lex)))
           (walk-all (cddr form) (append (%qint-mma-binding-elems (second form)) lex)))
          ((and hn (member hn '("MMA-ACCUMULATE-VIA-TILE" "WGMMA-ACCUMULATE-VIA-TILE"
                                  "TCGEN05-ACCUMULATE-VIA-TILE") :test #'string=)
                (>= (length form) 5))
           (check (nth 2 form) (nth 3 form) (nth 4 form))
           (walk-all (cdr form) lex))
          ((and hn (string= hn "WGMMA-ACCUMULATE") (>= (length form) 4))
           (check (nth 1 form) (nth 2 form) (nth 3 form))
           (walk-all (cdr form) lex))
          (t (walk-all form lex)))))))

;; src/mma.lisp -- NOTE for the fold: drop this declaim (and the copy above).  SBCL kept the phase-2
;; copy's derived return type, a 3- or 4-character string, and checked the phase-3 copy against it,
;; so "i8" failed at run time.  In src there is one definition and the problem does not arise.
(declaim (ftype (function (t) (values t t t &optional)) %208-mma-kind))
(defun %208-mma-kind (elem)
  "Endeavour 208.  For an operand element ELEM: (values KIND K-PER-INSTRUCTION FORMAT-CODE), the
   tcgen05.mma .kind, the K one instruction covers (always 32 bytes), and the a/b_format code of the
   instruction descriptor.  NIL for an element with no kind yet.

   Phase 3: an 8-bit integer (char, uchar, or a type derived from one, e.g. a def-qint) is kind::i8,
   K = 32, format INT8 = 1 / UINT8 = 0 (CUTLASS UMMA::S8Format).  A and B carry their own format,
   so the four sign pairs are one instruction."
  (let ((n (and elem (symbolp elem) (symbol-name elem))))
    (cond ((null n) nil)
          ((%int-operand-p elem) (values "i8" 32 (if (%elem-signed-p elem) 1 0)))
          ((string= n "HALF")     (values "f16"  16 0))
          ((string= n "BFLOAT16") (values "f16"  16 1))
          ((string= n "FLOAT")    (values "tf32"  8 2))
          (t nil))))


;; src/mma.lisp
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
   row record holds plain int, and the destination element holds exactly its own type."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (if-sym (intern "IF" (find-package :crisp-language)))
         (chunks (floor n 32)))
    (flet ((elt-of (ch j)
             (let ((x `(%extract-struct-member ,ch ,j)))
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

;; src/mma.lisp
(defun %208-analyze-store-tile (expr env context location)
  "Endeavour 208.  store-tile: a tcgen05 accumulator source is stored by %tcgen05-store-rewrite-origin
   at the tile-grid origin (BTY*M, BTX*N); anything else goes to analyze-store-tile-mma unchanged.
   Fold: a clause in analyze-store-tile-mma.
   Phase 3: passes the accumulator's element, for the derived-integer cast."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (destructuring-bind (m n elem) (gethash src-type *tcgen05-acc-dims*)
            (%tcgen05-check-epilogue-threads context location)
            (let ((tile-id (fourth expr))
                  (to-int (intern "TO-INT" (find-package :crisp-language))))
              (analyze-expression
               (%tcgen05-store-rewrite-origin src (third expr)
                                              `(* (,to-int ,(first tile-id)) ,m)
                                              `(* (,to-int ,(second tile-id)) ,n)
                                              n convert elem)
               env context location)))
          (analyze-store-tile-mma expr env context location)))))

;; src/mma.lisp
(defun %208-analyze-store-tile-at (expr env context location)
  "Endeavour 208.  store-tile-at: a tcgen05 accumulator source is stored at the absolute (ROW COL)
   origin, directly or with :via :tma (%208-analyze-tma-store).  Anything else goes to
   analyze-store-tile-at-mma.  Fold: a clause in analyze-store-tile-at-mma.
   Phase 3: passes the accumulator's element, for the derived-integer cast."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let ((src-type (%208-source-type src env context location)))
      (if (%tcgen05-acc-type-p src-type)
          (let* ((origin (fourth expr))
                 (keys   (nthcdr 4 expr))
                 (n      (second (gethash src-type *tcgen05-acc-dims*))))
            (cond ((null keys))
                  ((%199-via-tma-p keys)
                   (return-from %208-analyze-store-tile-at
                     (%208-analyze-tma-store expr src convert env context location)))
                  (t (error 'crisp-compiler-error
                            :message (format nil "store-tile-at: options ~s are not supported for a tcgen05 accumulator (only :via :tma)." keys)
                            :source-location location)))
            (unless (and (listp origin) (= (length origin) 2))
              (error 'crisp-compiler-error
                     :message (format nil "store-tile-at: a tcgen05 accumulator needs a 2-D (ROW COL) element origin, got ~s." origin)
                     :source-location location))
            (%tcgen05-check-epilogue-threads context location)
            (analyze-expression (%tcgen05-store-rewrite-origin src (third expr) (first origin) (second origin) n convert
                                                               (third (gethash src-type *tcgen05-acc-dims*)))
                                env context location))
          (analyze-store-tile-at-mma expr env context location)))))

;;;; ======================================================================
;;;; Endeavour 208 D-208-17 -- matrix-multiply-tile-stride with a tcgen05 accumulator.
;;;; See tests/spec/208-tcgen05/tcgen05.md.
;;;; ======================================================================

;; src/analysis/control.lisp
(defvar *mmts-tcgen05-tile* nil
  "Endeavour 208 (D-208-17).  While a matrix-multiply-tile-stride whose C-tile is a tcgen05 accumulator
   is lowered: that C-tile's symbol.  %mmts-reset-forms then resets it by re-initialisation instead of
   fill-tile + a workgroup sync.  NIL otherwise.")

;; src/analysis/control.lisp
(defun %mmts-reset-forms (c-tile let-bindings tile-spec reset-value fill-sym sync-sym)
  "The per-OUTPUT-TILE accumulator reset (BUG 036), decided by WHERE the C-tile is bound.

   Measured 2026-09-17 by compiling both shapes and reading the LLVM IR: a register tile
   bound INSIDE tile-stride emits its zero CompositeConstruct + store in the grid-x loop
   body, after grid-x is stored and before the K loop is entered -- precisely the slot this
   function's fill would occupy.  Bound in the ENCLOSING let it lands in the kernel entry
   block instead, once per WORKGROUP, which is the BUG 036 exposure.

   So:
     * register tile in :let      -> NOTHING.  The binding already is the per-tile reset;
                                    a fill here would be a redundant full-tile zero-write on
                                    the hot path, correct and invisible to MMA_CORRECT.
     * register tile outside      -> fill to its DECLARED INIT (pre-167 behaviour, kept).
     * scratch tile, either place -> fill to 0.0 PLUS a barrier.  make-scratch-matrix takes
                                    no init, so a scratch tile never self-resets wherever it
                                    is bound; and fill-tile on scratch is a workgroup-
                                    collective write that inserts no barrier of its own, so
                                    the macro (its caller) supplies one.  Endeavour 167
                                    behaviour change: before this, %mmts-lower gated the
                                    reset on REGISTER-P and scratch got nothing, leaving
                                    every scratch call site to hand-write it.
     * tcgen05 accumulator        -> Endeavour 208 (D-208-17), C-TILE eq *mmts-tcgen05-tile*.
                                    Bound in :let: NOTHING, the binding is fresh every tile.
                                    Bound outside: (set! D (%tcgen05-reset D)), which marks it
                                    FRESH so the first MMA overwrites -- no write to tensor
                                    memory, no barrier."
  (let* ((entry      (and (listp let-bindings) (assoc c-tile let-bindings)))
         (register-p (and (listp tile-spec) tile-spec (every #'integerp tile-spec))))
    (cond
      ;; Endeavour 208: a tcgen05 accumulator resets by re-initialisation (or its :let binding).
      ((and *mmts-tcgen05-tile* (eq c-tile *mmts-tcgen05-tile*))
       (if entry
           nil
           (list (list (intern "SET!" (find-package :crisp-language)) c-tile
                       (list (intern "%TCGEN05-RESET" (find-package :crisp.compiler)) c-tile)))))
      ;; Bound in :let and it is a register tile -> the binding resets it. Emit nothing.
      ((and entry (%register-tile-init-form-p (second entry))) nil)
      ;; Register tile bound in the enclosing let.
      ((and register-p (null entry)) (list (list fill-sym c-tile reset-value)))
      ;; Everything else is a scratch accumulator: fill + barrier.
      (t (list (list fill-sym c-tile 0.0) (list sync-sym))))))

;; src/analysis/control.lisp
(defun analyze-matrix-multiply-tile-stride-expression (expr env context location)
  "Analyzer for (matrix-multiply-tile-stride C C-tile K <k-step> (gy gx gk) SECTIONS...).

   A register C-tile needs a COMPILE-TIME (M N) size-list tile-spec (a register tile has no
   extents), a scratch C-tile is a real tensor and passes itself as the spec.  Pre-167 the
   register case could only be recognised by the pre-lowering in src/mma.lisp, which reads
   the ENCLOSING let; when the tile is bound in :let the constructor is right here, so this
   path handles it and the emitted inner let trips the SROA explosion on its own.

   Endeavour 208 (D-208-17): a tcgen05 accumulator C-tile -- bound in :let or outside -- takes its
   tile-spec from its (M N) (it has no extents~), and *mmts-tcgen05-tile* tells %mmts-reset-forms
   to reset it by re-initialisation."
  (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
      (%mmts-parse expr location)
    (let* ((entry     (%mmts-let-accumulator-entry c-tile body location))
           (ctor      (and entry (second entry)))
           (reg-ctor  (and ctor (%register-tile-init-form-p ctor) ctor))
           ;; A :let-bound C-tile cannot name ITSELF as the tile-spec: tile-stride reads the
           ;; spec outside the let the lowering emits, where the symbol is not yet bound
           ;; ("Unknown variable C-TILE").  Both tile constructors carry compile-time dims in
           ;; the same position -- (make-register-tile elem (M N) init) and
           ;; (make-scratch-matrix elem (M N)) -- so the spec comes from the binding.
           (tile-spec (if (and ctor (consp ctor) (listp (third ctor))
                               (every #'integerp (third ctor)))
                          (third ctor)
                          c-tile))
           (reset-val (if reg-ctor (fourth reg-ctor) 0.0))
           ;; Endeavour 208: an outer-bound tcgen05 accumulator (a :let one is caught above).
           (tc-type   (and (null entry) (symbolp c-tile) (%208-source-type c-tile env context location)))
           (tc-dims   (and tc-type (%tcgen05-acc-type-p tc-type) (gethash tc-type *tcgen05-acc-dims*)))
           (tc-p      (or tc-dims
                          (and ctor (consp ctor) (symbolp (first ctor))
                               (string-equal (symbol-name (first ctor)) "MAKE-TCGEN05-ACCUMULATOR")))))
      (when tc-dims
        (setf tile-spec (list (first tc-dims) (second tc-dims))))
      (log:debug "208 matrix-multiply-tile-stride: C-tile ~a tcgen05 ~a tile-spec ~a" c-tile (and tc-p t) tile-spec)
      (let ((*mmts-tcgen05-tile* (and tc-p c-tile)))
        (analyze-expression
         (%mmts-lower c-form c-tile tile-spec k-form k-step gy gx gk body location reset-val)
         env context location)))))

;;;; ======================================================================
;;;; Endeavour 208 phase 4 -- block-scaled microfloats (NVFP4 / MXFP4 / MXFP8) through tcgen05.
;;;; See tests/spec/208-tcgen05/tcgen05.md (D-208-10..17) and isa-notes.md ("Phase 4").
;;;;
;;;; A matrix whose element is a def-microfloat-block holds that block's packed codes, (M K) in
;;;; ELEMENTS (Chris, option (a)).  A scratch tile of a block type is rewritten -- before pass 1, so the
;;;; scratch sizes and TMA descriptors are right -- into a uchar codes tile (R K/epb) and a hidden scales
;;;; tile X%SF of 512-byte atoms; `load-tile .. :scales S` becomes a scale copy then the codes load; and
;;;; `tcgen05-accumulate-via-tile` on block tiles gains the hidden :%block / :%sf-a / :%sf-b options.
;;;; ======================================================================

;; src/macros.lisp -- fold: def-microfloat-block passes N to register-microfloat-block, which records
;; it as :shape.  A macro is not late-bound for compiled callers, but def-microfloat-block is only
;; expanded from Crisp source at compile time, so wrapping its macro function here works.
(defvar *208-orig-def-microfloat-block* (macro-function 'crisp-language::def-microfloat-block)
  "Endeavour 208.  def-microfloat-block's macro function before the :shape-recording wrapper.")

(setf (macro-function 'crisp-language::def-microfloat-block)
      (lambda (form env)
        (prog1 (funcall *208-orig-def-microfloat-block* form env)
          (let* ((key   (and (symbolp (second form)) (symbol-name (second form))))
                 (entry (and key (gethash key *microfloat-blocks*)))
                 (shape (getf (cddr form) :shape)))
            (when (and entry (consp shape) (integerp (first shape)))
              (setf (getf (gethash key *microfloat-blocks*) :shape) (first shape)))))))

;; src/mma.lisp
(defun %208-block-info (elem)
  "Endeavour 208 phase 4.  When ELEM names a def-microfloat-block, its tcgen05 plist:
     :name :base :scale :vec   the block (names as strings; :vec the block size in elements)
     :kind        the tcgen05.mma kind, with its scale_vec, or NIL when no kind fits the block
     :epb         codes per byte (2 for fp4, 1 for fp8)
     :fmt :sfmt   the a/b_format and scale_format codes of the block-scaled instruction descriptor
     :spi         scales per row one instruction consumes (4X 4, 2X 2, 1X 1)
   NIL when ELEM is not a block."
  (let* ((e (and elem (%canonical-elem elem)))
         (b (and e (symbolp e) (microfloat-block-p e))))
    (when b
      (let ((base (symbol-name (getf b :base)))
            (scale (symbol-name (getf b :scale)))
            (vec (getf b :shape)))
        (flet ((info (&rest kv) (list* :name (symbol-name e) :base base :scale scale :vec vec kv)))
          (cond ((and (string= base "FP4") (string= scale "FP8-E4M3") (eql vec 16))
                 (info :kind "mxf4nvf4.block_scale.scale_vec::4X" :epb 2 :fmt 1 :sfmt 0 :spi 4))
                ((and (string= base "FP4") (string= scale "FP8-E8M0") (eql vec 32))
                 (info :kind "mxf4.block_scale.scale_vec::2X" :epb 2 :fmt 1 :sfmt 1 :spi 2))
                ((and (member base '("FP8-E4M3" "FP8-E5M2") :test #'string=)
                      (string= scale "FP8-E8M0") (eql vec 32))
                 (info :kind "mxf8f6f4.block_scale" :epb 1 :fmt (if (string= base "FP8-E4M3") 0 1)
                       :sfmt 1 :spi 1))
                (t (info :kind nil))))))))

;; src/mma.lisp
(defun %208-block-step (info)
  "Endeavour 208 phase 4.  (values K-ELEMS SCALES-PER-ROW ATOMS-PER-STEP) of one tcgen05 call on block
   INFO: K is one 128-byte swizzle atom of codes (256 fp4, 128 fp8); a row then has K/vec scales, which
   is K/vec/4 512-byte scale atoms per 128 rows."
  (let* ((k   (* 128 (getf info :epb)))
         (spr (floor k (getf info :vec))))
    (values k spr (floor spr 4))))

;; src/mma.lisp
(defvar *208-scale-layouts* (make-hash-table :test 'equal)
  "Endeavour 208 phase 4.  Kernel name (string) -> list of (:scales S :of A :layout L), the kernel's
   (scale-layout S :of A L) declarations, names as downcased strings.  Set when the kernel's source is
   visited (before pass 1).")

;; src/mma.lisp
(defun %208-sym= (x name)
  "Endeavour 208.  T when X is a symbol named NAME (any package)."
  (and x (symbolp x) (string-equal (symbol-name x) name)))

;; src/mma.lisp
(defun %208-parse-scale-layouts (name params body)
  "Endeavour 208 phase 4.  Records kernel NAME's (scale-layout S :of A :blocked-128x4) declarations from
   the declare forms at the head of BODY in *208-scale-layouts*, refusing a malformed one, an unknown
   layout, or a name that is not one of PARAMS.  Q1 (b): the kernel declares the layout; the host
   provides it, and the generated hoist matches it."
  (let ((pnames (loop for p in params
                      when (and (symbolp p) (not (string= (symbol-name p) "&OUT")))
                        collect (string-downcase (symbol-name p))))
        (out '()))
    (dolist (f body)
      (when (and (consp f) (%208-sym= (first f) "DECLARE"))
        (dolist (d (rest f))
          (when (and (consp d) (%208-sym= (first d) "SCALE-LAYOUT"))
            (destructuring-bind (&optional s of a layout &rest more) (rest d)
              (unless (and (symbolp s) (%208-sym= of "OF") (symbolp a) (symbolp layout) (null more))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): expected (scale-layout SCALES :of MATRIX :blocked-128x4), got ~s." name d)))
              (unless (%208-sym= layout "BLOCKED-128X4")
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): (scale-layout ~(~a~) ..): the layout ~s is not supported.  The one layout is :blocked-128x4, cuBLASLt's and torchao's to_blocked: 512-byte atoms of 128 rows x 4 scales." name s layout)))
              (dolist (nm (list s a))
                (unless (member (string-downcase (symbol-name nm)) pnames :test #'string=)
                  (error 'crisp-compiler-error
                         :message (format nil "~(~a~): (scale-layout ~(~a~) :of ~(~a~) ..): ~(~a~) is not a parameter of the kernel." name s a nm))))
              (push (list :scales (string-downcase (symbol-name s)) :of (string-downcase (symbol-name a))
                          :layout :blocked-128x4)
                    out))))))
    (setf (gethash (string-downcase (symbol-name name)) *208-scale-layouts*) (nreverse out))
    (when out (log:debug "208 scale layouts of ~a: ~s" name out))))

;; src/mma.lisp
(defun %208-block-binding (b)
  "Endeavour 208 phase 4.  When the let binding B is (X (make-scratch-matrix BLOCK (R K))) or the -ring
   form, with BLOCK a def-microfloat-block: (values CODES-BINDING SCALES-BINDING ENTRY).
     CODES-BINDING   (X (make-scratch-matrix uchar (R K/epb) ..)) -- the packed codes, K-major
     SCALES-BINDING  (X%SF (make-scratch-matrix uchar (Q 512) ..)) -- Q = R/128 x atoms-per-step
                     512-byte scale atoms, row block j's atoms at j*atoms-per-step
     ENTRY           (X :info INFO :rows R :cols K :sf X%SF)
   NIL for any other binding.  R must be a multiple of 128 (a scale atom covers 128 rows) and K one
   128-byte atom of codes (D-208-14)."
  (let* ((init (and (consp b) (second b)))
         (head (and (consp init) (first init))))
    (when (and (or (%208-sym= head "MAKE-SCRATCH-MATRIX") (%208-sym= head "MAKE-SCRATCH-MATRIX-RING"))
               (consp (cdr init)))
      (let ((info (%208-block-info (second init))))
        (when info
          (let ((x (first b)) (dims (third init)))
            (unless (getf info :kind)
              (error 'crisp-compiler-error
                     :message (format nil "~(~a~): tcgen05 multiplies NVFP4 (:base fp4 :scale fp8-e4m3 :shape (16)), MXFP4 (:base fp4 :scale fp8-e8m0 :shape (32)) and MXFP8 (:base fp8-e4m3 or fp8-e5m2 :scale fp8-e8m0 :shape (32)) blocks; ~(~a~) is :base ~(~a~) :scale ~(~a~) :shape (~a)."
                                      x (getf info :name) (getf info :base) (getf info :scale) (getf info :vec))))
            (multiple-value-bind (kel spr aps) (%208-block-step info)
              (declare (ignore spr))
              (unless (and (listp dims) (= (length dims) 2) (every #'integerp dims)
                           (zerop (mod (first dims) 128)) (= (second dims) kel))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): a scratch tile of ~(~a~) for tcgen05 is (R ~a): R a multiple of 128 (a scale atom covers 128 rows) and K one 128-byte swizzle atom of codes; got ~s."
                                        x (getf info :name) kel dims)))
              (let* ((r (first dims))
                     (sf (intern (format nil "~a%SF" (symbol-name x)) (symbol-package x)))
                     (uchar (intern "UCHAR" (find-package :crisp-language)))
                     (rest (cdddr init)))
                (log:debug "208 block tile ~a: ~a (~a ~a) -> codes uchar (~a ~a), scales ~a (~a 512)"
                           x (getf info :name) r kel r (floor kel (getf info :epb)) sf (* (floor r 128) aps))
                (values (list x (list* head uchar (list r (floor kel (getf info :epb))) rest))
                        (list sf (list* head uchar (list (* (floor r 128) aps) 512) rest))
                        (list x :info info :rows r :cols kel :sf sf))))))))))

;; src/mma.lisp
(defun %208-block-tile-ref (form tiles)
  "Endeavour 208 phase 4.  When FORM is a block tile X or (ring-get X I) of TILES: (values ENTRY SF-FORM),
   SF-FORM naming the matching scales tile (X%SF, or (ring-get X%SF I))."
  (let ((e (cond ((and form (symbolp form)) (assoc form tiles))
                 ((and (consp form) (%208-sym= (first form) "RING-GET") (symbolp (second form)))
                  (assoc (second form) tiles)))))
    (when e
      (values e (if (symbolp form)
                    (getf (cdr e) :sf)
                    (list (first form) (getf (cdr e) :sf) (third form)))))))

;; src/mma.lisp
(defun %208-rw-list (list tiles)
  "Endeavour 208 phase 4.  %208-rw over the elements of LIST; the SAME conses back when nothing changed
   (source positions are keyed by cons identity)."
  (if (atom list)
      list
      (let ((a (%208-rw (car list) tiles))
            (d (%208-rw-list (cdr list) tiles)))
        (if (and (eq a (car list)) (eq d (cdr list))) list (cons a d)))))

;; src/mma.lisp
(defun %208-rw (form tiles)
  "Endeavour 208 phase 4.  The block-tile source rewrite of FORM, TILES the block tiles in scope (see
   the section header).  EQ-preserving."
  (cond
    ((atom form) form)
    ;; LET: block bindings split into codes + scales; the body sees them.
    ((and (%208-sym= (first form) "LET") (consp (cdr form)) (listp (second form)))
     (let ((out '()) (changed nil) (inner tiles))
       (dolist (b (second form))
         (multiple-value-bind (codes scales entry) (%208-block-binding b)
           (if codes
               (progn (setf changed t) (push codes out) (push scales out) (push entry inner))
               (let ((nb (if (consp b) (%208-rw-list b tiles) b)))
                 (unless (eq nb b) (setf changed t))
                 (push nb out)))))
       (let ((body (%208-rw-list (cddr form) inner)))
         (if (or changed (not (eq body (cddr form))))
             (list* (first form) (nreverse out) body)
             form))))
    ;; load-tile into a block tile: the scale copy FIRST (its expect_tx must precede the codes load's
    ;; arrive, from the same thread), then the codes load without :scales.
    ((%208-sym= (first form) "LOAD-TILE")
     (multiple-value-bind (entry sf) (%208-block-tile-ref (third form) tiles)
       (if (null entry)
           (%208-rw-list form tiles)
           (let* ((kw (nthcdr 4 form))
                  (scales (getf kw :scales))
                  (bar (getf kw :barrier))
                  (plain (loop for (k v) on kw by #'cddr unless (eq k :scales) append (list k v))))
             (unless scales
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) ..): ~(~a~) holds ~(~a~) blocks, so the load needs their scales: add :scales S, with (scale-layout S :of ~(~a~) :blocked-128x4) declared."
                                       (second form) (third form) (third form)
                                       (getf (getf (cdr entry) :info) :name) (second form))))
             (unless bar
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) .. :scales ..): a block tile is loaded by TMA and needs :barrier." (second form) (third form))))
             (list 'progn
                   (list (intern "%208-LOAD-SCALES" (find-package :crisp.compiler))
                         scales (second form) sf (fourth form) bar
                         (getf (getf (cdr entry) :info) :name) (getf (cdr entry) :rows))
                   (list* (first form) (second form) (third form) (fourth form) plain))))))
    ;; The accumulate on block tiles: the hidden options carry the block and the scales tiles.
    ((and (%208-sym= (first form) "TCGEN05-ACCUMULATE-VIA-TILE") (>= (length form) 5))
     (multiple-value-bind (ea sfa) (%208-block-tile-ref (nth 3 form) tiles)
       (multiple-value-bind (eb sfb) (%208-block-tile-ref (nth 4 form) tiles)
         (cond ((and (null ea) (null eb)) (%208-rw-list form tiles))
               ((not (and ea eb))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile: ~(~a~) is a block tile and ~(~a~) is not.  A block-scaled multiply takes two block tiles of the same block."
                                        (if ea (nth 3 form) (nth 4 form)) (if ea (nth 4 form) (nth 3 form)))))
               (t (append form
                          (list :%block-a (getf (getf (cdr ea) :info) :name) :%sf-a sfa
                                :%block-b (getf (getf (cdr eb) :info) :name) :%sf-b sfb)))))))
    (t (%208-rw-list form tiles))))

;; src/mma.lisp
(defun %208-tree-has-block-scratch-p (form)
  "Endeavour 208 phase 4.  T when FORM contains a make-scratch-matrix(-ring) of a microfloat block.
   The cheap test that keeps every other kernel's source untouched (EQ)."
  (cond ((atom form) nil)
        ((and (or (%208-sym= (first form) "MAKE-SCRATCH-MATRIX") (%208-sym= (first form) "MAKE-SCRATCH-MATRIX-RING"))
              (consp (cdr form)) (%208-block-info (second form)))
         t)
        (t (loop for x on form
                 thereis (if (consp x) (%208-tree-has-block-scratch-p (car x)) nil)))))

;; src/mma.lisp
(defun %208-rewrite-block-kernel (form)
  "Endeavour 208 phase 4.  A def-function FORM with its scale-layout declarations recorded and, when it
   holds block scratch tiles, its body rewritten (section header).  Any other FORM comes back EQ."
  (let ((name (second form)) (params (third form)) (body (cdddr form)))
    (when (and (symbolp name) (listp params))
      (%208-parse-scale-layouts name params body))
    (if (%208-tree-has-block-scratch-p body)
        (let ((new (%208-rw-list body nil)))
          (log:debug "208 block-scaled source rewrite of ~a" name)
          (if (eq new body) form (list* (first form) name params new)))
        form)))

;; src/analysis/core.lisp -- fold: the def-function case of visit-toplevel-form rewrites first.
(defvar *208-orig-visit-toplevel-form* (fdefinition 'visit-toplevel-form)
  "Endeavour 208.  visit-toplevel-form before the block-tile source rewrite.")

;; src/analysis/core.lisp
(defun visit-toplevel-form (form location visitor-fn)
  "Endeavour 208 wrapper: a def-function form passes through %208-rewrite-block-kernel (scale-layout
   declarations; block scratch tiles) before both passes see it; then the original walker."
  (funcall *208-orig-visit-toplevel-form*
           (if (and (consp form) (eq (car form) 'def-function)) (%208-rewrite-block-kernel form) form)
           location visitor-fn))

;;; ---------------------------------------------------------------- the scale copy

;; src/mma.lisp
(defun analyze-%208-load-scales (expr env context location)
  "Endeavour 208 phase 4.  (%208-load-scales S SRC SF (ROW-TILE K-TILE) BAR BLOCK ROWS): copy the scale
   atoms of SRC's tile (ROW-TILE K-TILE) from the :blocked-128x4 vector S into the scales tile SF, on
   BAR.  Emitted by the source rewrite in front of the codes load.  The atoms of one row block for one
   K-step are contiguous: (rb * K/(vec*4) + kt * aps) * 512, aps*512 bytes; ROWS/128 row blocks."
  (destructuring-bind (s src sf coords bar bname rows) (cdr expr)
    (let* ((info   (%208-block-info (make-symbol bname)))
           (kernel (compiler-context-current-compiling-function context))
           (decl   (find-if (lambda (d) (string-equal (getf d :scales) (symbol-name s)))
                            (gethash (string-downcase (symbol-name kernel)) *208-scale-layouts*)))
           (ct     (%kernel-param-contiguous-term kernel src))
           (ki     (if (eq ct :col-major) 0 1))
           (tu     (intern "TO-ULONG" (find-package :crisp-language)))
           (ex     (intern "EXTENTS~" (find-package :crisp-language))))
      (unless (and decl (string-equal (getf decl :of) (symbol-name src)))
        (error 'crisp-compiler-error
               :message (format nil "load-tile ~(~a~) .. :scales ~(~a~): declare the layout of the scales, (scale-layout ~(~a~) :of ~(~a~) :blocked-128x4)."
                                src s s src)
               :source-location location))
      (multiple-value-bind (kel spr aps) (%208-block-step info)
        (declare (ignore kel spr))
        (log:debug "208 %208-load-scales ~a of ~a (~a, ~a) rows ~a aps ~a K index ~a" s src bname ct rows aps ki)
        (make-semantic-tcgen05-op
         :op :load-scales
         :args (list (analyze-expression `(~ ,s 0) env context (append location '(1)))
                     (analyze-expression `(~ ,sf 0 0) env context (append location '(3)))
                     (analyze-expression `(,tu (~ (,ex ,src) ,ki)) env context (append location '(2)))
                     (analyze-expression `(,tu ,(first coords)) env context (append location '(4 0)))
                     (analyze-expression `(,tu ,(second coords)) env context (append location '(4 1)))
                     (analyze-expression bar env context (append location '(5))))
         :plist (list :vec (getf info :vec) :aps aps :row-blocks (floor rows 128)
                      :ws-leader (and *in-warp-spec-block* t))
         :type 'void
         :source-location location)))))

;; src/codegen.lisp
(defun %208-gen-load-scales (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208 phase 4.  One elected thread (lane 0 inside a warp-spec role, else thread 0 -- the
   TMA load's own rule, so it is the same thread and in program order before the codes load's
   arrive.expect_tx): mbarrier.expect_tx for every scale byte, then one cp.async.bulk per row block,
   completing on the barrier.  No arrival: the barrier's count is the codes loads', as before."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (destructuring-bind (s-ref sf-ref kext-node c0-node c1-node bar-node) (semantic-tcgen05-op-args node)
      (let* ((pl     (semantic-tcgen05-op-plist node))
             (i32    (llvm-int32-type))
             (i64    (llvm-int64-type))
             (aps    (getf pl :aps))
             (nb     (getf pl :row-blocks))
             (s-ptr  (nth-value 2 (gen s-ref)))
             (sf-ptr (nth-value 2 (gen sf-ref)))
             (kext   (gen kext-node))
             (c0     (gen c0-node))
             (c1     (gen c1-node))
             (mbar   (%208-barrier-addr builder (gen bar-node)))
             (katoms (crisp.llvm-bindings::llvm-build-udiv builder kext (llvm-const-int i64 (* 4 (getf pl :vec)) nil) "sf_katoms"))
             (leader (if (getf pl :ws-leader)
                         (llvm-build-icmp builder +llvm-int-eq+ (%ptx-read-warp-sreg builder module "laneid")
                                          (llvm-const-int i32 0 nil) "sf_lane0")
                         (llvm-build-icmp builder +llvm-int-eq+ (%208-linear-tid builder module)
                                          (llvm-const-int i32 0 nil) "sf_tid0"))))
        (unless (and s-ptr sf-ptr)
          (error "208 %208-load-scales: no pointer for the scales (~a) or the scales tile (~a)" s-ptr sf-ptr))
        (log:debug "208 gen load-scales: ~a row block~:p x ~a atom~:p" nb aps)
        (%208-if builder leader
                 (lambda ()
                   (let ((s-addr  (llvm-build-ptr-to-int builder s-ptr i64 "sf_src0"))
                         (sf-addr (llvm-build-ptr-to-int builder sf-ptr i32 "sf_dst0")))
                     (%208-asm builder "mbarrier.expect_tx.relaxed.cta.shared::cta.b64 [$0], $1;"
                               "r,r,~{memory}" nil (list i32 i32)
                               (list mbar (llvm-const-int i32 (* nb aps 512) nil)))
                     (dotimes (j nb)
                       (let* ((rb   (llvm-build-add builder (llvm-build-mul builder c0 (llvm-const-int i64 nb nil) "sf_rb0")
                                                    (llvm-const-int i64 j nil) "sf_rb"))
                              (atom (llvm-build-add builder (llvm-build-mul builder rb katoms "sf_rowatoms")
                                                    (llvm-build-mul builder c1 (llvm-const-int i64 aps nil) "sf_katom")
                                                    "sf_atom"))
                              (src  (llvm-build-add builder s-addr
                                                    (llvm-build-mul builder atom (llvm-const-int i64 512 nil) "sf_off")
                                                    "sf_src"))
                              (dst  (llvm-build-add builder sf-addr (llvm-const-int i32 (* j aps 512) nil) "sf_dst")))
                         (%208-asm builder
                                   "cp.async.bulk.shared::cluster.global.mbarrier::complete_tx::bytes [$0], [$1], $2, [$3];"
                                   "r,l,r,r,~{memory}" nil (list i32 i64 i32 i32)
                                   (list dst src (llvm-const-int i32 (* aps 512) nil) mbar))))))
                 "sf_issue")
        (values (llvm-const-int i64 0 nil) nil)))))

;;; ---------------------------------------------------------------- the block-scaled accumulate

;; src/mma.lisp
(defvar *208-orig-analyze-accumulate* (fdefinition 'analyze-tcgen05-accumulate-via-tile)
  "Endeavour 208 phase 4.  The 16-bit / tf32 / int8 accumulate analyzer.")

;; src/mma.lisp
(defun analyze-tcgen05-accumulate-via-tile (expr env context location)
  "Endeavour 208.  (tcgen05-accumulate-via-tile (M N K) D A B :swizzle :128b [:on-complete BAR]).
   Phase 4: A and B are block tiles (the source rewrite added :%block-a / :%sf-a / :%block-b / :%sf-b)
   -> (set! D (%tcgen05-mma-bs D A B SF-A SF-B K BLOCK [BAR])).  Rules: the same block on both sides
   (D-208-10); an f32 accumulator; M = 128, N 128 or 256 (B's scales come in 128-row atoms); K one
   128-byte atom of codes (D-208-14).  Anything else goes to the earlier analyzer."
  (let ((kw (nthcdr 5 expr)))
    (if (not (getf kw :%block-a))
        (funcall *208-orig-analyze-accumulate* expr env context location)
        (progn
          (%tcgen05-require-arch "tcgen05-accumulate-via-tile" location)
          (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
            (let* ((ba (getf kwargs :%block-a)) (bb (getf kwargs :%block-b))
                   (info (%208-block-info (make-symbol ba)))
                   (bar (getf kwargs :on-complete))
                   (swz (getf kwargs :swizzle))
                   (d-type (semantic-node-type (analyze-expression d env context (append location '(2))))))
              (flet ((fail (fmt &rest args)
                       (error 'crisp-compiler-error
                              :message (format nil "tcgen05-accumulate-via-tile: ~?" fmt args)
                              :source-location location)))
                (loop for (key nil) on kwargs by #'cddr
                      unless (member (symbol-name key) '("SWIZZLE" "ON-COMPLETE" "B-MAJOR" "%BLOCK-A" "%SF-A" "%BLOCK-B" "%SF-B")
                                     :test #'string=)
                        do (fail "unknown option ~s.  The options are :swizzle, :b-major and :on-complete." key))
                (unless (string-equal ba bb)
                  (fail "A holds ~(~a~) blocks and B holds ~(~a~) blocks.  Mixed formats are not supported yet; both must be the same block." ba bb))
                (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
                  (fail "the first argument is the (M N K) shape, as integers; got ~s." shape))
                (unless (%tcgen05-acc-type-p d-type)
                  (fail "D (2nd argument) must be a make-tcgen05-accumulator, got type ~a." d-type))
                (when (%208-acc-int-p d-type)
                  (fail "a block-scaled multiply accumulates in f32: D must be (make-tcgen05-accumulator float ..)."))
                (unless (and swz (symbolp swz) (string-equal (symbol-name swz) "128B"))
                  (fail "a block-scaled multiply needs :swizzle :128b, as the codes are loaded."))
                (destructuring-bind (m n k) shape
                  (destructuring-bind (dm dn delem) (gethash d-type *tcgen05-acc-dims*)
                    (declare (ignore delem))
                    (unless (and (= m dm) (= n dn))
                      (fail "shape ~a does not match the accumulator, which is (~a ~a)." shape dm dn)))
                  (unless (and (= m 128) (member n '(128 256)))
                    (fail "a block-scaled multiply is M = 128 and N = 128 or 256 (B's scales come in 128-row atoms); got (~a ~a)." m n))
                  (let ((want (%208-block-step info)))
                    (unless (= k want)
                      (fail "K must be ~a for ~(~a~) (one 128-byte swizzle atom of codes, four instructions), got ~a."
                            want ba k)))
                  (log:debug "208 block-scaled accumulate ~a (~a ~a ~a) on-complete ~a" ba m n k bar)
                  (analyze-expression
                   `(set! ,d (,(intern "%TCGEN05-MMA-BS" (find-package :crisp.compiler))
                              ,d ,a ,b ,(getf kwargs :%sf-a) ,(getf kwargs :%sf-b) ,k ,ba ,@(when bar (list bar))))
                   env context location)))))))))

;; src/mma.lisp
(defun analyze-%tcgen05-mma-bs (expr env context location)
  "Endeavour 208 phase 4.  (%tcgen05-mma-bs D A B SF-A SF-B K BLOCK [BAR]) -> the :mma node with :block.
   The site gets its own tensor-memory scale columns: A's atoms-per-step x 4, then B's x 4 per 128-row
   block (they count toward the 512, D-208-13).  Without BAR it is synchronous, as %tcgen05-mma."
  (destructuring-bind (d a b sfa sfb k bname &optional bar) (cdr expr)
    (flet ((ref (x i) (analyze-expression `(~ ,x 0 0) env context (append location (list i)))))
      (let* ((info   (%208-block-info (make-symbol bname)))
             (d-node (analyze-expression d env context (append location '(1))))
             (d-type (semantic-node-type d-node))
             (dims   (gethash d-type *tcgen05-acc-dims*))
             (nb     (floor (second dims) 128))
             (aps    (nth-value 2 (%208-block-step info)))
             (sf-col (%208-assign-columns context location (* 4 aps (1+ nb)) "tcgen05-accumulate-via-tile (its block scales)"))
             (bar-node (and bar (analyze-expression bar env context (append location '(8)))))
             (key    (%208-kernel-key context))
             (site   (unless bar
                       (let ((s (cons key location)))
                         (or (gethash s *tcgen05-sync-sites*)
                             (let ((i (getf (%208-kernel-info key) :sync-sites 0)))
                               (setf (getf (gethash key *tcgen05-kernels*) :sync-sites) (1+ i))
                               (setf (gethash s *tcgen05-sync-sites*) i)))))))
        (log:debug "208 %tcgen05-mma-bs ~a ~a K=~a scale columns ~a..~a issue-warp ~a sync-site ~a"
                   bname dims k sf-col (+ sf-col (* 4 aps (1+ nb)) -1) (%208-issue-warp) site)
        (make-semantic-tcgen05-op
         :op :mma
         :args (append (list d-node (ref a 2) (ref b 3) (ref sfa 4) (ref sfb 5)) (when bar-node (list bar-node)))
         :plist (list :m (first dims) :n (second dims) :k k :block info :aps aps :row-blocks-b nb
                      :sf-col sf-col :issue-warp (%208-issue-warp) :sync-site site :kernel key)
         :type d-type
         :source-location location)))))

;; src/codegen.lisp
(defun %208-cp-desc (builder base-ptr byte-off)
  "Endeavour 208 phase 4.  The tcgen05.cp source descriptor of one 512-byte scale atom: K-major,
   no swizzle (layout 0), start >> 4 at [0,14), LBO 0 (one core matrix along K), SBO 128 B (enc 8:
   8-row x 16-byte core matrices) at [32,46), version 1 at bit 46.  See isa-notes.md, Phase 4."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "sf_addr"))
         (addr  (if (zerop byte-off) addr0 (llvm-build-add builder addr0 (llvm-const-int i32 byte-off nil) "sf_addr_a")))
         (msk   (crisp.llvm-bindings::llvm-build-and
                 builder (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "sf_sh")
                 (llvm-const-int i32 #x3FFF nil) "sf_start")))
    (crisp.llvm-bindings::llvm-build-or builder (llvm-build-zext builder msk i64 "sf_start64")
                                        (llvm-const-int i64 (logior (ash 8 32) (ash 1 46)) nil) "sf_desc")))

;; src/codegen.lisp
(defun %208-idesc-bs (m n info a-sf-id b-sf-id)
  "Endeavour 208 phase 4.  The block-scaled instruction descriptor (CUTLASS InstrDescriptorBlockScaled):
   b_sf_id [4,6), a_format [7,10), b_format [10,13), K-major (15, 16 = 0), N >> 3 [17,23),
   scale_format bit 23 (UE4M3 0, UE8M0 1), M >> 4 [24,29), a_sf_id [29,31).  No c_format: D is f32."
  (let ((f (getf info :fmt)))
    (logior (ash b-sf-id 4) (ash f 7) (ash f 10) (ash (ash n -3) 17) (ash (getf info :sfmt) 23)
            (ash (ash m -4) 24) (ash a-sf-id 29))))

;; src/codegen.lisp
(defun %208-emit-sync-wait (builder site mbar-addr)
  "Endeavour 208.  A synchronous site's wait: every executing thread waits for the site mbarrier's next
   phase (parity from an entry-block visit counter), then fence::after_thread_sync.  Fold: %208-gen-mma
   has the same code inline; it should call this."
  (let* ((i32    (llvm-int32-type))
         (ctr    (%208-entry-counter builder (format nil "tc_sync_ctr_~d" site)))
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

;; src/codegen.lisp
(defun %208-gen-mma-bs (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208 phase 4.  The block-scaled D += (A*sA).(B*sB).  Lane 0 of the issuing warp:
     1. tcgen05.cp.32x128b.warpx4 each scale atom into the site's scale columns -- A's atom a at
        SF + 4a; B's row block j, atom a at SF + 4*aps + 4*(a*nb + j) (column n div 32 within a K atom);
     2. four tcgen05.mma.kind::<block kind>, instruction kk reading scale atom (kk*spi) div 4 at
        byte / half-word SF_ID (kk*spi) mod 4 -- a per-instruction instruction descriptor;
     3. commit, to :on-complete's barrier or to the site's own mbarrier (then every thread waits).
   The copies and MMAs come from one thread, so the tensor pipe keeps them in order (as CUTLASS)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (destructuring-bind (d-node a-node b-node sfa-node sfb-node &optional bar-node) (semantic-tcgen05-op-args node)
      (let* ((pl     (semantic-tcgen05-op-plist node))
             (info   (getf pl :block))
             (i32    (llvm-int32-type))
             (i64    (llvm-int64-type))
             (m (getf pl :m)) (n (getf pl :n))
             (aps    (getf pl :aps))
             (nb     (getf pl :row-blocks-b))
             (spi    (getf info :spi))
             (d-val  (extract-primary-value builder (gen d-node) (semantic-node-type d-node)))
             (col    (llvm-build-extract-value builder d-val 0 "tc_col"))
             (fresh  (llvm-build-extract-value builder d-val 1 "tc_fresh"))
             (a-ptr  (nth-value 2 (gen a-node)))
             (b-ptr  (nth-value 2 (gen b-node)))
             (sfa-ptr (nth-value 2 (gen sfa-node)))
             (sfb-ptr (nth-value 2 (gen sfb-node)))
             (bar-addr (and bar-node (%208-barrier-addr builder (gen bar-node))))
             (site   (getf pl :sync-site))
             (mbar-addr (and site
                             (let* ((kinfo (%208-kernel-tc-info (getf pl :kernel)))
                                    (g (%208-sync-mbar-global module (getf pl :kernel) (getf kinfo :sync-sites 1))))
                               (llvm-build-ptr-to-int builder (%gen-nvvm-mbar-slot-ptr builder g site) i32 "tc_sync_mbar"))))
             (tid    (%208-linear-tid builder module))
             (issuer (llvm-build-icmp builder +llvm-int-eq+ tid
                                      (llvm-const-int i32 (* 32 (getf pl :issue-warp)) nil) "tc_issuer")))
        (unless (and a-ptr b-ptr sfa-ptr sfb-ptr)
          (error "208 block-scaled MMA: an operand did not yield a shared-memory pointer (a ~a b ~a sfa ~a sfb ~a)"
                 a-ptr b-ptr sfa-ptr sfb-ptr))
        (log:debug "208 gen mma-bs ~a ~ax~a aps ~a nb ~a sf-col ~a" (getf info :kind) m n aps nb (getf pl :sf-col))
        (%208-if builder issuer
                 (lambda ()
                   (let* ((base (llvm-build-load2 builder i32 (%208-tmem-slot module) "tmem_base"))
                          (dt   (llvm-build-add builder base col "tc_d"))
                          (sfa  (llvm-build-add builder base (llvm-const-int i32 (getf pl :sf-col) nil) "tc_sfa"))
                          (sfb  (llvm-build-add builder sfa (llvm-const-int i32 (* 4 aps) nil) "tc_sfb"))
                          (en0  (llvm-build-zext builder
                                                 (llvm-build-icmp builder +llvm-int-eq+ fresh (llvm-const-int i32 0 nil) "tc_acc")
                                                 i32 "tc_en0")))
                     (%208-asm builder "tcgen05.fence::after_thread_sync;")
                     (flet ((cp (taddr src-ptr off)
                              (%208-asm builder "tcgen05.cp.cta_group::1.32x128b.warpx4 [$0], $1;"
                                        "r,l,~{memory}" nil (list i32 i64)
                                        (list taddr (%208-cp-desc builder src-ptr off)))))
                       (dotimes (a aps)
                         (cp (llvm-build-add builder sfa (llvm-const-int i32 (* 4 a) nil) "tc_sfa_a") sfa-ptr (* a 512)))
                       (dotimes (j nb)
                         (dotimes (a aps)
                           (cp (llvm-build-add builder sfb (llvm-const-int i32 (* 4 (+ (* a nb) j)) nil) "tc_sfb_a")
                               sfb-ptr (* (+ (* j aps) a) 512)))))
                     (dotimes (kk 4)
                       (let* ((s   (* kk spi))
                              (atm (floor s 4))
                              (id  (mod s 4)))
                         (%208-asm builder
                                   (format nil "{ .reg .pred p; setp.ne.b32 p, $4, 0; tcgen05.mma.cta_group::1.kind::~a [$0], $1, $2, $3, [$5], [$6], p; }"
                                           (getf info :kind))
                                   "r,l,l,r,r,r,r,~{memory}" nil (list i32 i64 i64 i32 i32 i32 i32)
                                   (list dt
                                         (%208-smem-desc builder a-ptr (* kk 32))
                                         (%208-smem-desc builder b-ptr (* kk 32))
                                         (llvm-const-int i32 (%208-idesc-bs m n info id id) nil)
                                         (if (zerop kk) en0 (llvm-const-int i32 1 nil))
                                         (llvm-build-add builder sfa (llvm-const-int i32 (* 4 atm) nil) "tc_sfa_k")
                                         (llvm-build-add builder sfb (llvm-const-int i32 (* 4 atm nb) nil) "tc_sfb_k")))))
                     (%208-commit-asm builder (or bar-addr mbar-addr))))
                 "tc_issue")
        (when site
          (%208-emit-sync-wait builder site mbar-addr))
        (values (llvm-build-insert-value builder d-val (llvm-const-int i32 0 nil) 1 "tc_d_used") nil)))))

;; src/codegen.lisp
(defvar *208-orig-gen-mma* (fdefinition '%208-gen-mma)
  "Endeavour 208 phase 4.  The 16-bit / tf32 / int8 MMA emitter.")

;; src/codegen.lisp
(defun %208-gen-mma (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  Phase 4: a block-scaled MMA node (plist :block) goes to %208-gen-mma-bs; every other
   one to the earlier emitter.  Fold: one emitter with the two issue sequences."
  (if (getf (semantic-tcgen05-op-plist node) :block)
      (%208-gen-mma-bs node builder module var-env di-builder di-scope location-map)
      (funcall *208-orig-gen-mma* node builder module var-env di-builder di-scope location-map)))

;;; ---------------------------------------------------------------- metadata

;; src/metadata.lisp -- fold: a clause in generate-declared-signature.
(defvar *208-orig-generate-declared-signature* (fdefinition 'generate-declared-signature)
  "Endeavour 208 phase 4.  generate-declared-signature before the :microfloat entries.")

;; src/metadata.lisp
(defun %208-param-block-info (type)
  "Endeavour 208 phase 4.  The block plist when the parameter TYPE is a matrix of a microfloat block."
  (let ((c (ignore-errors (canonicalize-type-specifier type))))
    (and (consp c) (symbolp (first c)) (string-equal (symbol-name (first c)) "TENSOR")
         (%208-block-info (second c)))))

;; src/metadata.lisp
(defun generate-declared-signature (sig &optional declared-params)
  "Endeavour 208 phase 4 wrapper.  The original entries, plus :microfloat on a parameter that holds a
   block's codes -- (:block :base :scale :vec :scales S :layout L) -- and on its scales vector --
   (:scales-of A :block .. :layout L) -- so the hoist sizes, fills and checks them (Q1 (b))."
  (let* ((entries (funcall *208-orig-generate-declared-signature* sig declared-params))
         (kname   (string-downcase (symbol-name (function-signature-name sig))))
         (decls   (gethash kname *208-scale-layouts*))
         (types   (loop for p in (or declared-params (function-signature-parameters sig))
                        for nm = (if (consp p) (car p) (parameter-def-name p))
                        unless (and (symbolp nm) (string-equal (symbol-name nm) "&OUT"))
                          collect (cons (string-downcase (symbol-name nm))
                                        (if (consp p) (cdr p) (parameter-def-type p))))))
    (if (null decls)
        entries
        (mapcar (lambda (e)
                  (let* ((nm   (getf e :name))
                         (info (%208-param-block-info (cdr (assoc nm types :test #'string=))))
                         (as-a (find nm decls :key (lambda (d) (getf d :of)) :test #'string=))
                         (as-s (find nm decls :key (lambda (d) (getf d :scales)) :test #'string=))
                         (s-of (and as-s (%208-param-block-info (cdr (assoc (getf as-s :of) types :test #'string=))))))
                    (flet ((blk (i) (list :block (string-downcase (getf i :name)) :base (string-downcase (getf i :base))
                                          :scale (string-downcase (getf i :scale)) :vec (getf i :vec))))
                      (cond ((and info as-a)
                             (append e (list :microfloat (append (blk info) (list :scales (getf as-a :scales) :layout (getf as-a :layout))))))
                            ((and as-s s-of)
                             (append e (list :microfloat (append (blk s-of) (list :scales-of (getf as-s :of) :layout (getf as-s :layout))))))
                            (t e)))))
                entries))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-tcgen05-op) builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  Dispatch on the tcgen05 operation.  Phase 4 adds :load-scales."
  (let ((void (lambda () (values (llvm-const-int (llvm-int64-type) 0 nil) nil))))
    (ecase (semantic-tcgen05-op-op node)
      (:mma (%208-gen-mma node builder module var-env di-builder di-scope location-map))
      (:ld  (%208-gen-ld node builder module var-env di-builder di-scope location-map))
      (:tma-store (%208-gen-tma-store node builder module var-env di-builder di-scope location-map))
      (:load-scales (%208-gen-load-scales node builder module var-env di-builder di-scope location-map))
      (:commit
       (let* ((bar-addr (%208-barrier-addr builder (generate-node-ir (first (semantic-tcgen05-op-args node))
                                                                    builder module var-env di-builder di-scope location-map)))
              (i32 (llvm-int32-type))
              (tid (%208-linear-tid builder module)))
         (%208-if builder (llvm-build-icmp builder +llvm-int-eq+ tid
                                           (llvm-const-int i32 (* 32 (getf (semantic-tcgen05-op-plist node) :issue-warp)) nil)
                                           "tc_committer")
                  (lambda () (%208-commit-asm builder bar-addr))
                  "tc_commit")
         (funcall void)))
      (:fence-after  (%208-asm builder "tcgen05.fence::after_thread_sync;")  (funcall void))
      (:fence-before (%208-asm builder "tcgen05.fence::before_thread_sync;") (funcall void)))))

;; src/mma.lisp
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!.
   Endeavour 154: adds STORE-TILE-AT, so a wgmma accumulator can be stored at an absolute origin
   (two cooperating consumer warpgroups); non-wgmma sources delegate unchanged."
  ;; Endeavour 208: tensor-memory bookkeeping is per compile.
  (clrhash *tcgen05-columns*)
  (clrhash *tcgen05-sync-sites*)
  (clrhash *tcgen05-kernels*)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         ;; Endeavour 208: tcgen05.  The store / let entries wrap the originals.
                         (cons "MAKE-TCGEN05-ACCUMULATOR"    #'analyze-make-tcgen05-accumulator)
                         (cons "TCGEN05-ACCUMULATE-VIA-TILE" #'analyze-tcgen05-accumulate-via-tile)
                         (cons "TCGEN05-COMMIT"              #'analyze-tcgen05-commit)
                         (cons "%208-LOAD-SCALES"            #'analyze-%208-load-scales)
                         (cons "%TCGEN05-MMA-BS"             #'analyze-%tcgen05-mma-bs)
                         (cons "%TCGEN05-MMA"                #'analyze-%tcgen05-mma)
                         (cons "%TCGEN05-RESET"              #'analyze-%tcgen05-reset)
                         (cons "%TCGEN05-LD"                 #'analyze-%tcgen05-ld)
                         (cons "%TCGEN05-FENCE-AFTER"        #'analyze-%tcgen05-fence)
                         (cons "%TCGEN05-FENCE-BEFORE"       #'analyze-%tcgen05-fence)
                         (cons "%IN-WARP-ROLE"               #'analyze-%in-warp-role)
                         ;; Endeavour 208 phase 2: the accumulator ring.  RING-GET wraps the struct analyzer's.
                         (cons "MAKE-TCGEN05-ACCUMULATOR-RING" #'analyze-make-tcgen05-accumulator-ring)
                         (cons "RING-GET"                    #'%208-analyze-ring-get)
                         (cons "STORE-TILE"              #'%208-analyze-store-tile)
                         (cons "STORE-TILE-AT"           #'%208-analyze-store-tile-at)
                         (cons "LET"                     #'%208-analyze-let)
                         (cons "LET*"                    #'%208-analyze-let)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))
    ;; Endeavour 173 / BUG 069: Crisp has no LET* -- its LET is already sequential.  This is the
    ;; site that decides what `let*` means, because (intern "LET*" :crisp-language) HERE mints the
    ;; very symbol the Crisp reader later reuses for user source; the table above aliased it onto
    ;; LET, which compiled forward and then died under --differentiate blaming SET!.
    ;;
    ;; ONLY the :crisp-language spelling is rejected, which is why this sits outside the loop:
    ;; crisp.compiler uses :cl and does not shadow LET*, so (intern "LET*" cc-pkg) up there
    ;; returns COMMON-LISP:LET* -- a DIFFERENT symbol, which must stay pointed at the real LET
    ;; analyzer.  That is load-bearing, not merely tidy: instantiate-generic-function
    ;; (src/environment.lisp) injects `(let* ,bindings ,@body) to bind a &key parameter's
    ;; defaults, and that backquote is read in :crisp.compiler -- so a COMPILER LOWERING emits
    ;; the CL spelling.  Rejecting it too breaks every &key default (016-advanced-signatures/04).
    ;; User source, read in :crisp-language, reaches the rejected symbol instead.
    (setf (gethash (intern "LET*" cl-pkg) *expression-analyzers*) '%analyze-let-star-rejected)))

;; src/mma.lisp -- corrected copy: after def-kernel's expansion the def-function parameter list is not
;; always a flat list of symbols, so the names are every symbol in it (a type name cannot collide with
;; the check's purpose: the scales and matrix named in the declare must be parameters).
(defun %208-param-names (params)
  "Endeavour 208 phase 4.  Every symbol in the def-function parameter form PARAMS, downcased."
  (let ((out '()))
    (labels ((walk (x) (cond ((and x (symbolp x)) (push (string-downcase (symbol-name x)) out))
                             ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk params))
    out))

;; src/mma.lisp
(defun %208-parse-scale-layouts (name params body)
  "Endeavour 208 phase 4.  Records kernel NAME's (scale-layout S :of A :blocked-128x4) declarations from
   the declare forms at the head of BODY in *208-scale-layouts*, refusing a malformed one, an unknown
   layout, or a name that is not one of PARAMS.  Q1 (b): the kernel declares the layout; the host
   provides it, and the generated hoist matches it."
  (let ((pnames (%208-param-names params))
        (out '()))
    (log:debug "208 scale-layout parse of ~a: params ~s" name params)
    (dolist (f body)
      (when (and (consp f) (%208-sym= (first f) "DECLARE"))
        (dolist (d (rest f))
          (when (and (consp d) (%208-sym= (first d) "SCALE-LAYOUT"))
            (destructuring-bind (&optional s of a layout &rest more) (rest d)
              (unless (and (symbolp s) (%208-sym= of "OF") (symbolp a) (symbolp layout) (null more))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): expected (scale-layout SCALES :of MATRIX :blocked-128x4), got ~s." name d)))
              (unless (%208-sym= layout "BLOCKED-128X4")
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): (scale-layout ~(~a~) ..): the layout ~s is not supported.  The one layout is :blocked-128x4, cuBLASLt's and torchao's to_blocked: 512-byte atoms of 128 rows x 4 scales." name s layout)))
              (dolist (nm (list s a))
                (unless (member (string-downcase (symbol-name nm)) pnames :test #'string=)
                  (error 'crisp-compiler-error
                         :message (format nil "~(~a~): (scale-layout ~(~a~) :of ~(~a~) ..): ~(~a~) is not a parameter of the kernel." name s a nm))))
              (push (list :scales (string-downcase (symbol-name s)) :of (string-downcase (symbol-name a))
                          :layout :blocked-128x4)
                    out))))))
    (setf (gethash (string-downcase (symbol-name name)) *208-scale-layouts*) (nreverse out))
    (when out (log:debug "208 scale layouts of ~a: ~s" name out))))

;; src/mma.lisp -- corrected copy (2nd): a kernel's def-function carries the PHYSICAL parameters
;; (A_PTR A_BYTE_SIZE A_OFFSET_0 ..), so a declared name matches any "_"-prefix of one, in either
;; spelling (my-scales <-> MY_SCALES_PTR).
(defun %208-param-names (params)
  "Endeavour 208 phase 4.  The names the def-function parameter form PARAMS answers to, downcased:
   every symbol in it, each '_'-prefix of one (A_BYTE_SIZE -> a, a_byte, a_byte_size), and the
   same with '-' for '_'."
  (let ((out '()))
    (labels ((add (s)
               (push s out)
               (push (substitute #\- #\_ s) out))
             (walk (x)
               (cond ((and x (symbolp x))
                      (let ((s (string-downcase (symbol-name x))))
                        (loop for p = (position #\_ s) then (position #\_ s :start (1+ p))
                              while p do (add (subseq s 0 p)))
                        (add s)))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk params))
    out))

;; src/analysis/control.lisp -- fold: a first clause in %tlc-check-elem-match.
(defvar *208-orig-tlc-check-elem-match* (fdefinition '%tlc-check-elem-match)
  "Endeavour 208 phase 4.  BUG 057's tile-copy element check, before block codes were allowed.")

;; src/analysis/control.lisp
(defun %tlc-check-elem-match (src tile env op-name location)
  "Endeavour 208 phase 4 wrapper.  A matrix of a microfloat block holds its packed codes, and the
   source rewrite stages them into a uchar tile: that pair is the byte copy it looks like, so it is
   accepted.  Every other pair goes to BUG 057's check."
  (let* ((src-pd  (and (symbolp src) (find-variable-in-env src env)))
         (tile-pd (and (symbolp tile) (find-variable-in-env tile env)))
         (se (and src-pd (get-array-element-type (parameter-def-type src-pd))))
         (te (and tile-pd (get-array-element-type (parameter-def-type tile-pd)))))
    (if (and se te (%208-block-info se) (%208-sym= te "UCHAR"))
        (log:debug "208 ~a: block codes ~a (~a) staged as bytes into ~a" op-name src se tile)
        (funcall *208-orig-tlc-check-elem-match* src tile env op-name location))))

;; src/mma.lisp -- corrected copy: the hidden scales tile was X%SF, and the hoist makes a C identifier
;; of every scratch name (a_tile%sf_from_.. does not compile).  It is X--SCALES (a_tile__scales_..).
(defun %208-block-binding (b)
  "Endeavour 208 phase 4.  When the let binding B is (X (make-scratch-matrix BLOCK (R K))) or the -ring
   form, with BLOCK a def-microfloat-block: (values CODES-BINDING SCALES-BINDING ENTRY).
     CODES-BINDING   (X (make-scratch-matrix uchar (R K/epb) ..)) -- the packed codes, K-major
     SCALES-BINDING  (X--SCALES (make-scratch-matrix uchar (Q 512) ..)) -- Q = R/128 x atoms-per-step
                     512-byte scale atoms, row block j's atoms at j*atoms-per-step
     ENTRY           (X :info INFO :rows R :cols K :sf X--SCALES)
   NIL for any other binding.  R must be a multiple of 128 (a scale atom covers 128 rows) and K one
   128-byte atom of codes (D-208-14)."
  (let* ((init (and (consp b) (second b)))
         (head (and (consp init) (first init))))
    (when (and (or (%208-sym= head "MAKE-SCRATCH-MATRIX") (%208-sym= head "MAKE-SCRATCH-MATRIX-RING"))
               (consp (cdr init)))
      (let ((info (%208-block-info (second init))))
        (when info
          (let ((x (first b)) (dims (third init)))
            (unless (getf info :kind)
              (error 'crisp-compiler-error
                     :message (format nil "~(~a~): tcgen05 multiplies NVFP4 (:base fp4 :scale fp8-e4m3 :shape (16)), MXFP4 (:base fp4 :scale fp8-e8m0 :shape (32)) and MXFP8 (:base fp8-e4m3 or fp8-e5m2 :scale fp8-e8m0 :shape (32)) blocks; ~(~a~) is :base ~(~a~) :scale ~(~a~) :shape (~a)."
                                      x (getf info :name) (getf info :base) (getf info :scale) (getf info :vec))))
            (multiple-value-bind (kel spr aps) (%208-block-step info)
              (declare (ignore spr))
              (unless (and (listp dims) (= (length dims) 2) (every #'integerp dims)
                           (zerop (mod (first dims) 128)) (= (second dims) kel))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): a scratch tile of ~(~a~) for tcgen05 is (R ~a): R a multiple of 128 (a scale atom covers 128 rows) and K one 128-byte swizzle atom of codes; got ~s."
                                        x (getf info :name) kel dims)))
              (let* ((r (first dims))
                     (sf (intern (format nil "~a--SCALES" (symbol-name x)) (symbol-package x)))
                     (uchar (intern "UCHAR" (find-package :crisp-language)))
                     (rest (cdddr init)))
                (log:debug "208 block tile ~a: ~a (~a ~a) -> codes uchar (~a ~a), scales ~a (~a 512)"
                           x (getf info :name) r kel r (floor kel (getf info :epb)) sf (* (floor r 128) aps))
                (values (list x (list* head uchar (list r (floor kel (getf info :epb))) rest))
                        (list sf (list* head uchar (list (* (floor r 128) aps) 512) rest))
                        (list x :info info :rows r :cols kel :sf sf))))))))))


;; src/compiler.lisp
(defun %ll-needs-ptx87-p (ll-file)
  "Endeavour 208 phase 4.  T when LL-FILE holds a block-scaled tcgen05.mma (kind::mxf8f6f4 / mxf4 /
   mxf4nvf4 .block_scale), which ptxas accepts only at PTX ISA 8.7.  Read from the emitted IR, as
   %ll-needs-ptx84-p, so every other module keeps llc's default version."
  (let ((text (alexandria:read-file-into-string ll-file)))
    (and (search ".block_scale" text) t)))

;; src/compiler.lisp
(defun compile-to-ptx (module output-path &key (compute-capability "sm_80") debug-p)
  "Compiles an LLVM Module to PTX using llc.
   Pipeline: IR -> opt -O3 (if available) -> llc -> PTX.
   COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)
                       sm_80 = Ampere (required for endeavor 114's cp.async path).
                       Pre-Ampere targets can pass an explicit value if needed,
                       but kernels using request-load-tile / await-request will
                       fail to compile on anything earlier."
  (declare (ignore debug-p))
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (ptx-file output-path))

    ;; Set target triple for NVPTX before writing IR
    (llvm-set-target module "nvptx64-nvidia-cuda")

    ;; Endeavor 128 (Phase 4): if any transcendental was lowered to a libdevice
    ;; __nv_* symbol, verify libdevice.10.bc was linked (else a clear error) and set
    ;; the nvvm-reflect-ftz module flag so llc's NVVMReflect resolves __CUDA_FTZ.
    (%ptx-finalize-libdevice module)

    ;; 1. Write raw LLVM IR to .ll file
    (let ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module))))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir stream)))

    ;; 2. Try opt -O3 on the IR.  If it succeeds, feed the optimized IR
    ;;    to llc; otherwise fall back to the raw IR.
    (let* ((opt-ok  (%run-opt-O3 ll-file ll-opt-file))
           (llc-input (if opt-ok ll-opt-file ll-file))
           ;; Endeavour 192: lower :cache hints on the FINAL (post-opt) IR -- -O3 drops metadata, so
           ;; nothing placed in codegen survives -- and re-apply !invariant.load (BUG 134).
           (hint-count (%apply-cache-hints-to-ll llc-input :ptx)))

      ;; 3. llc: IR -> PTX
      (let ((tool (resolve-tool-executable "llc")))
        (run-tool-command
         (append
          (list tool
                "-march=nvptx64"
                (format nil "-mcpu=~a" compute-capability))
          ;; Endeavour 192: eviction priorities and L2::NNNB need PTX ISA 7.4.  +ptx74 only ever
          ;; RAISES the version (sm_80 7.0 -> 7.4; sm_90 stays 7.8, sm_100 8.6).
          (when (plusp hint-count) (list "-mattr=+ptx74"))
          ;; Endeavour 204: +ptx84 only ever raises the version too.
          (when (%ll-needs-ptx84-p llc-input) (list "-mattr=+ptx84"))
          ;; Endeavour 208 phase 4: the block-scaled tcgen05 kinds need PTX ISA 8.7.  Raise-only.
          (when (%ll-needs-ptx87-p llc-input) (list "-mattr=+ptx87"))
          (list (namestring llc-input)
                "-o" (namestring ptx-file)))
         :log-prefix "[PTX] ")))

    ;; Cleanup temp files
    (when (probe-file ll-file)     (delete-file ll-file))
    (when (probe-file ll-opt-file) (delete-file ll-opt-file))

    (log:info "Generated PTX: ~a" ptx-file)))


;; src/mma.lisp -- corrected copy (2nd): the scales tile is a whole number of KB, keeping the next
;; swizzled codes tile 1024-byte aligned (an MXFP8 tile of one 512-byte atom put it at offset 512).
(defun %208-block-binding (b)
  "Endeavour 208 phase 4.  When the let binding B is (X (make-scratch-matrix BLOCK (R K))) or the -ring
   form, with BLOCK a def-microfloat-block: (values CODES-BINDING SCALES-BINDING ENTRY).
     CODES-BINDING   (X (make-scratch-matrix uchar (R K/epb) ..)) -- the packed codes, K-major
     SCALES-BINDING  (X--SCALES (make-scratch-matrix uchar (Q 512) ..)) -- R/128 x atoms-per-step
                     512-byte scale atoms, row block j's atoms at j*atoms-per-step, and Q that count
                     rounded up to EVEN: the hoist packs scratch tiles back to back, and a 512-byte
                     tile would leave the next 128-byte-swizzled codes tile off its 1024-byte alignment
     ENTRY           (X :info INFO :rows R :cols K :sf X--SCALES)
   NIL for any other binding.  R must be a multiple of 128 (a scale atom covers 128 rows) and K one
   128-byte atom of codes (D-208-14)."
  (let* ((init (and (consp b) (second b)))
         (head (and (consp init) (first init))))
    (when (and (or (%208-sym= head "MAKE-SCRATCH-MATRIX") (%208-sym= head "MAKE-SCRATCH-MATRIX-RING"))
               (consp (cdr init)))
      (let ((info (%208-block-info (second init))))
        (when info
          (let ((x (first b)) (dims (third init)))
            (unless (getf info :kind)
              (error 'crisp-compiler-error
                     :message (format nil "~(~a~): tcgen05 multiplies NVFP4 (:base fp4 :scale fp8-e4m3 :shape (16)), MXFP4 (:base fp4 :scale fp8-e8m0 :shape (32)) and MXFP8 (:base fp8-e4m3 or fp8-e5m2 :scale fp8-e8m0 :shape (32)) blocks; ~(~a~) is :base ~(~a~) :scale ~(~a~) :shape (~a)."
                                      x (getf info :name) (getf info :base) (getf info :scale) (getf info :vec))))
            (multiple-value-bind (kel spr aps) (%208-block-step info)
              (declare (ignore spr))
              (unless (and (listp dims) (= (length dims) 2) (every #'integerp dims)
                           (zerop (mod (first dims) 128)) (= (second dims) kel))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): a scratch tile of ~(~a~) for tcgen05 is (R ~a): R a multiple of 128 (a scale atom covers 128 rows) and K one 128-byte swizzle atom of codes; got ~s."
                                        x (getf info :name) kel dims)))
              (let* ((r (first dims))
                     (sf (intern (format nil "~a--SCALES" (symbol-name x)) (symbol-package x)))
                     (uchar (intern "UCHAR" (find-package :crisp-language)))
                     (rest (cdddr init)))
                (log:debug "208 block tile ~a: ~a (~a ~a) -> codes uchar (~a ~a), scales ~a (~a 512)"
                           x (getf info :name) r kel r (floor kel (getf info :epb)) sf (* (floor r 128) aps))
                (values (list x (list* head uchar (list r (floor kel (getf info :epb))) rest))
                        (list sf (list* head uchar (list (* 2 (ceiling (* (floor r 128) aps) 2)) 512) rest))
                        (list x :info info :rows r :cols kel :sf sf))))))))))


;; src/codegen.lisp -- the non-block MMA emitter, a fresh copy under its own name.  Phase 4's wrapper
;; called the phase-2 copy through a captured function object; that copy was compiled before phase
;; 3's (declaim (ftype .. %208-mma-kind)) and checks the old 3/4-character return type, so int8's
;; "i8" failed in the built executable (spec 10 / 11's hoist step).  Fold: one %208-gen-mma.
(defun %208-gen-mma-plain (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  The 16-bit / tf32 / int8 emitter (was %208-gen-mma).  D += A.B: lane 0 of the issuing warp builds the descriptors and issues K/16
   tcgen05.mma.kind::f16 (the first with enable-input-d = !FRESH, the rest accumulating), then commits
   -- to :on-complete's barrier, or to this site's own mbarrier, on which every executing thread then
   waits (parity from an entry-block visit counter) before fence::after_thread_sync.  Returns D with
   FRESH cleared."
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
             (idesc  (%208-idesc (getf pl :m) (getf pl :n) (getf pl :elem) (getf pl :b-elem)))
             (kind   (%208-mma-kind (getf pl :elem)))
             (slices (floor (getf pl :k) (nth-value 1 (%208-mma-kind (getf pl :elem))))))
        ;; As for wgmma: a tf32 MMA under a non-fast precision silently does not honour IEEE.
        (when (and (string= kind "tf32") (not (eq *math-precision* :fast)))
          (format *error-output*
                  "WARNING: tcgen05-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                  *math-precision*))
        (unless (and a-ptr b-ptr)
          (error "tcgen05: A/B (~ tile 0 0) did not yield a shared-memory pointer (a ~a b ~a)" a-ptr b-ptr))
        (log:debug "208 gen mma: idesc #x~8,'0x slices ~a issue-warp ~a site ~a on-complete ~a"
                   idesc slices (getf pl :issue-warp) site (and bar-node t))
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
                                       (%208-smem-desc builder b-ptr (* kk 32))
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


;; src/codegen.lisp
(defun %208-gen-mma (node builder module var-env di-builder di-scope location-map)
  "Endeavour 208.  Phase 4: a block-scaled MMA node (plist :block) goes to %208-gen-mma-bs; every other
   one to %208-gen-mma-plain (by name).  Fold: one emitter with the two issue sequences."
  (if (getf (semantic-tcgen05-op-plist node) :block)
      (%208-gen-mma-bs node builder module var-env di-builder di-scope location-map)
      (%208-gen-mma-plain node builder module var-env di-builder di-scope location-map)))

;;;; Endeavour 208 phase 4 -- the block-tile refusals move to rewrite time.  An error raised while pass 1
;;;; analyses a block kernel's body can stop it before the uchar LOCAL tensor struct of the rewritten
;;;; tiles is instantiated; pass 2 then builds the kernel's LLVM function type first and fails with
;;;; "Type Resolution: FAILED to instantiate struct TENSOR_UCHAR_2_LOCAL_COMPACT_LAST", masking the real
;;;; message (errors/16, 19, 21).  Every block-specific rule whose inputs are literal in the source is
;;;; now checked by the rewrite, before pass 1; the analysis-time checks stay as backstops.  The
;;;; masking itself is a general pass-1 hazard, recorded in tcgen05.md for review.

;; src/mma.lisp
(defvar *208-rw-kernel* nil
  "Endeavour 208 phase 4.  The kernel name (downcased string) whose source %208-rw is rewriting, for
   its scale-layout declarations.")

;; src/mma.lisp
(defun %208-acc-binding-elem (b)
  "Endeavour 208 phase 4.  When the let binding B makes a tcgen05 accumulator (or ring): (values SYM
   ELEM), the accumulator's element as written.  NIL otherwise."
  (let ((init (and (consp b) (second b))))
    (when (and (consp init) (consp (cdr init))
               (or (%208-sym= (first init) "MAKE-TCGEN05-ACCUMULATOR")
                   (%208-sym= (first init) "MAKE-TCGEN05-ACCUMULATOR-RING")))
      (values (first b) (second init)))))

;; src/mma.lisp
(defun %208-check-block-accumulate (form ea eb tiles)
  "Endeavour 208 phase 4.  Rewrite-time rules of a block-scaled (tcgen05-accumulate-via-tile SHAPE D A B
   ..) whose A and B are block tiles EA / EB: the same block, M = 128, N 128 or 256, K one atom of
   codes, and an f32 accumulator when D's binding is in TILES (as (D :acc ELEM))."
  (flet ((fail (fmt &rest args)
           (error 'crisp-compiler-error
                  :message (format nil "tcgen05-accumulate-via-tile: ~?" fmt args))))
    (let* ((ia (getf (cdr ea) :info)) (ib (getf (cdr eb) :info))
           (shape (second form))
           (d (third form))
           (dsym (if (consp d) (second d) d))
           (acc (and (symbolp dsym) (assoc dsym tiles))))
      (unless (string-equal (getf ia :name) (getf ib :name))
        (fail "A holds ~(~a~) blocks and B holds ~(~a~) blocks.  Mixed formats are not supported yet; both must be the same block."
              (getf ia :name) (getf ib :name)))
      (when (and acc (getf (cdr acc) :acc) (not (%208-sym= (getf (cdr acc) :acc) "FLOAT")))
        (fail "a block-scaled multiply accumulates in f32: D must be (make-tcgen05-accumulator float ..), not ~(~a~)."
              (getf (cdr acc) :acc)))
      (when (and (listp shape) (= (length shape) 3) (every #'integerp shape))
        (destructuring-bind (m n k) shape
          (unless (and (= m 128) (member n '(128 256)))
            (fail "a block-scaled multiply is M = 128 and N = 128 or 256 (B's scales come in 128-row atoms); got (~a ~a)." m n))
          (let ((want (%208-block-step ia)))
            (unless (= k want)
              (fail "K must be ~a for ~(~a~) (one 128-byte swizzle atom of codes, four instructions), got ~a."
                    want (getf ia :name) k))))))))

;; src/mma.lisp
(defun %208-parse-scale-layouts (name params body)
  "Endeavour 208 phase 4.  Records kernel NAME's (scale-layout S :of A :blocked-128x4) declarations from
   the declare forms at the head of BODY in *208-scale-layouts*, refusing a malformed one, an unknown
   layout, or a name that is not one of PARAMS.  Q1 (b): the kernel declares the layout; the host
   provides it, and the generated hoist matches it."
  (let ((pnames (%208-param-names params))
        (out '()))
    (log:debug "208 scale-layout parse of ~a: params ~s" name params)
    (dolist (f body)
      (when (and (consp f) (%208-sym= (first f) "DECLARE"))
        (dolist (d (rest f))
          (when (and (consp d) (%208-sym= (first d) "SCALE-LAYOUT"))
            (destructuring-bind (&optional s of a layout &rest more) (rest d)
              (unless (and (symbolp s) (%208-sym= of "OF") (symbolp a) (symbolp layout) (null more))
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): expected (scale-layout SCALES :of MATRIX :blocked-128x4), got ~s." name d)))
              (unless (%208-sym= layout "BLOCKED-128X4")
                (error 'crisp-compiler-error
                       :message (format nil "~(~a~): (scale-layout ~(~a~) ..): the layout ~s is not supported.  The one layout is :blocked-128x4, cuBLASLt's and torchao's to_blocked: 512-byte atoms of 128 rows x 4 scales." name s layout)))
              (dolist (nm (list s a))
                (unless (member (string-downcase (symbol-name nm)) pnames :test #'string=)
                  (error 'crisp-compiler-error
                         :message (format nil "~(~a~): (scale-layout ~(~a~) :of ~(~a~) ..): ~(~a~) is not a parameter of the kernel." name s a nm))))
              (push (list :scales (string-downcase (symbol-name s)) :of (string-downcase (symbol-name a))
                          :layout :blocked-128x4)
                    out))))))
    (let ((decls (setf (gethash (string-downcase (symbol-name name)) *208-scale-layouts*) (nreverse out))))
      ;; (the earlier copy logged OUT after NREVERSE, which shows only the last declaration)
      (when decls (log:debug "208 scale layouts of ~a: ~s" name decls)))))

;; src/mma.lisp
(defun %208-rw (form tiles)
  "Endeavour 208 phase 4.  The block-tile source rewrite of FORM, TILES the block tiles in scope (see
   the section header).  EQ-preserving.  TILES also carries the tcgen05 accumulator bindings, as
   (D :acc ELEM), and the block rules whose inputs are literal are checked here, before pass 1."
  (cond
    ((atom form) form)
    ;; LET: block bindings split into codes + scales; the body sees them.
    ((and (%208-sym= (first form) "LET") (consp (cdr form)) (listp (second form)))
     (let ((out '()) (changed nil) (inner tiles))
       (dolist (b (second form))
         (multiple-value-bind (codes scales entry) (%208-block-binding b)
           (if codes
               (progn (setf changed t) (push codes out) (push scales out) (push entry inner))
               (let ((nb (if (consp b) (%208-rw-list b tiles) b)))
                 (multiple-value-bind (asym aelem) (%208-acc-binding-elem b)
                   (when asym (push (list asym :acc aelem) inner)))
                 (unless (eq nb b) (setf changed t))
                 (push nb out)))))
       (let ((body (%208-rw-list (cddr form) inner)))
         (if (or changed (not (eq body (cddr form))))
             (list* (first form) (nreverse out) body)
             form))))
    ;; load-tile into a block tile: the scale copy FIRST (its expect_tx must precede the codes load's
    ;; arrive, from the same thread), then the codes load without :scales.
    ((%208-sym= (first form) "LOAD-TILE")
     (multiple-value-bind (entry sf) (%208-block-tile-ref (third form) tiles)
       (if (null entry)
           (%208-rw-list form tiles)
           (let* ((kw (nthcdr 4 form))
                  (scales (getf kw :scales))
                  (bar (getf kw :barrier))
                  (plain (loop for (k v) on kw by #'cddr unless (eq k :scales) append (list k v))))
             (unless scales
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) ..): ~(~a~) holds ~(~a~) blocks, so the load needs their scales: add :scales S, with (scale-layout S :of ~(~a~) :blocked-128x4) declared."
                                       (second form) (third form) (third form)
                                       (getf (getf (cdr entry) :info) :name) (second form))))
             (let ((decl (find-if (lambda (d) (string-equal (getf d :scales) (symbol-name scales)))
                                  (and *208-rw-kernel* (gethash *208-rw-kernel* *208-scale-layouts*)))))
               (unless (and (symbolp scales) decl (string-equal (getf decl :of) (symbol-name (second form))))
                 (error 'crisp-compiler-error
                        :message (format nil "load-tile ~(~a~) .. :scales ~(~a~): declare the layout of the scales, (scale-layout ~(~a~) :of ~(~a~) :blocked-128x4)."
                                         (second form) scales scales (second form)))))
             (unless bar
               (error 'crisp-compiler-error
                      :message (format nil "(load-tile ~(~a~) ~(~a~) .. :scales ..): a block tile is loaded by TMA and needs :barrier." (second form) (third form))))
             (list 'progn
                   (list (intern "%208-LOAD-SCALES" (find-package :crisp.compiler))
                         scales (second form) sf (fourth form) bar
                         (getf (getf (cdr entry) :info) :name) (getf (cdr entry) :rows))
                   (list* (first form) (second form) (third form) (fourth form) plain))))))
    ;; The accumulate on block tiles: the hidden options carry the block and the scales tiles.
    ((and (%208-sym= (first form) "TCGEN05-ACCUMULATE-VIA-TILE") (>= (length form) 5))
     (multiple-value-bind (ea sfa) (%208-block-tile-ref (nth 3 form) tiles)
       (multiple-value-bind (eb sfb) (%208-block-tile-ref (nth 4 form) tiles)
         (cond ((and (null ea) (null eb)) (%208-rw-list form tiles))
               ((not (and ea eb))
                (error 'crisp-compiler-error
                       :message (format nil "tcgen05-accumulate-via-tile: ~(~a~) is a block tile and ~(~a~) is not.  A block-scaled multiply takes two block tiles of the same block."
                                        (if ea (nth 3 form) (nth 4 form)) (if ea (nth 4 form) (nth 3 form)))))
               (t (%208-check-block-accumulate form ea eb tiles)
                  (append form
                          (list :%block-a (getf (getf (cdr ea) :info) :name) :%sf-a sfa
                                :%block-b (getf (getf (cdr eb) :info) :name) :%sf-b sfb)))))))
    (t (%208-rw-list form tiles))))

;; src/mma.lisp
(defun %208-rewrite-block-kernel (form)
  "Endeavour 208 phase 4.  A def-function FORM with its scale-layout declarations recorded and, when it
   holds block scratch tiles, its body rewritten (section header).  Any other FORM comes back EQ."
  (let ((name (second form)) (params (third form)) (body (cdddr form)))
    (when (and (symbolp name) (listp params))
      (%208-parse-scale-layouts name params body))
    (if (%208-tree-has-block-scratch-p body)
        (let ((new (let ((*208-rw-kernel* (string-downcase (symbol-name name)))) (%208-rw-list body nil))))
          (log:debug "208 block-scaled source rewrite of ~a" name)
          (if (eq new body) form (list* (first form) name params new)))
        form)))

;; src/mma.lisp -- corrected copy: TILES now also holds accumulator bindings (D :acc ELEM), which are
;; not block tiles.
(defun %208-block-tile-ref (form tiles)
  "Endeavour 208 phase 4.  When FORM is a block tile X or (ring-get X I) of TILES: (values ENTRY SF-FORM),
   SF-FORM naming the matching scales tile (X--SCALES, or (ring-get X--SCALES I)).  Entries without
   :info (accumulator bindings) are not block tiles."
  (let* ((sym (cond ((and form (symbolp form)) form)
                    ((and (consp form) (%208-sym= (first form) "RING-GET") (symbolp (second form))) (second form))))
         (e (and sym (find-if (lambda (x) (and (eq (car x) sym) (getf (cdr x) :info))) tiles))))
    (when e
      (values e (if (symbolp form)
                    (getf (cdr e) :sf)
                    (list (first form) (getf (cdr e) :sf) (third form)))))))
