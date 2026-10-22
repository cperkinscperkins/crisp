;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-13 -- the "/=" entry in *unsupported-form-hints* folded into src/errors.lisp.
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

;; src/codegen.lisp -- REPLACES ensure-opencl-kernel-metadata (endeavour 190: BUG 066 on PTX -- a _GRAD kernel inherits its forward kernel's launch geometry on EVERY backend, not only inside the SPIR-V subgroup emitter)
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).
   Endeavor 152: stamps cluster dimensions on capable PTX entry points, and records
   the EFFECTIVE extent (warning on degrade) for every entry point on every backend.
   Endeavour 156: pins the SPIR-V subgroup size to the profile's :simd-width.

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)
        ;; Endeavour 190 (BUG 066 on PTX): a _GRAD kernel inherits its forward kernel's launch
        ;; geometry on EVERY backend.  It used to happen only inside the SPIR-V subgroup emitter
        ;; below, so on PTX every gradient kernel's .metacrisp carried no global/local size and a
        ;; caller had to guess.  Measured before the change: the PTX of all 903 specs that compile
        ;; with --differentiate is byte-identical; only the metadata of 379 _grad kernels changes.
        ;; (The SPIR-V call below stays -- the inherit only fills a missing entry, so it is a no-op.)
        (%173-ensure-grad-dispatch-decls semantic-function)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module)
           ;; Endeavour 156 Phase 0: so does the subgroup size, and for the same reason --
           ;; the function attribute does not survive the translator.
           (%emit-spirv-subgroup-size-execution-mode func module semantic-function))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0)))

        ;; Endeavor 152: OUTSIDE the case on purpose.  This must run for every entry
        ;; point on every backend -- it is what records the effective cluster extent
        ;; and warns when a declared cluster could not be formed.  Gating it per
        ;; backend is what let the SPIR-V degrade go silent.
        (%apply-cluster-dims-attribute func semantic-function module)
        ;; Endeavour 182: launch bounds for the kernel's occupancy target (PTX only; a no-op elsewhere).
        (%apply-occupancy-bound func (semantic-function-name semantic-function) module))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))

