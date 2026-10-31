;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
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

;;; ==========================================================================================================
;;; Endeavour 200 (sort_v2 contest): BUG 138 -- the BUG 120 noinline workaround only on SPIR-V.
;;; ==========================================================================================================

;; src/codegen.lisp
(defun %185-helper-call (builder module name ret-type arg-vals body-fn)
  "Call the internal helper NAME : RET-TYPE(types of ARG-VALS), creating it in MODULE on first use with a
   body built by BODY-FN, called as (BODY-FN helper-builder param-values) and returning the value to ret.
   SPIR_FUNC on SPIR-V; the call site gets the callee's CC.

   Endeavour 200 (BUG 138): the helper is noinline ON SPIR-V ONLY.  The noinline exists for the BMG,
   which failed zeModuleCreate when these bodies were inlined (BUG 120 family).  On PTX it bought nothing
   and cost a call per ash / popcount in the hottest loops -- and kept ptxas from fusing (logand (ash w -8)
   255u) into bfe.u32.  With internal linkage and no noinline, LLVM inlines the helper on PTX."
  (let* ((n (length arg-vals))
         (existing (crisp.llvm-bindings::llvm-get-named-function module name))
         (fnty (cffi:with-foreign-objects ((ptypes :pointer (max 1 n)))
                 (loop for i from 0 for v in arg-vals
                       do (setf (cffi:mem-aref ptypes :pointer i) (llvm-type-of v)))
                 (crisp.llvm-bindings::llvm-function-type ret-type ptypes n nil)))
         (fn (if (not (cffi:null-pointer-p existing))
                 existing
                 (let ((fn (crisp.llvm-bindings::llvm-add-function module name fnty))
                       (tmp (llvm-create-builder)))
                   (log:debug "%185-helper-call: creating ~a (noinline: ~a)" name (eq *target-backend* :spirv))
                   (crisp.llvm-bindings::llvm-set-linkage fn 8)            ; LLVMInternalLinkage
                   (when (eq *target-backend* :spirv)
                     (llvm-add-attribute-at-index
                      fn +llvm-attribute-function-index+
                      (crisp.llvm-bindings::llvm-create-enum-attribute
                       (llvm-get-module-context module)
                       (crisp.llvm-bindings::llvm-get-enum-attribute-kind-for-name "noinline" 8) 0))
                     (llvm-set-function-call-conv fn 75))                 ; SPIR_FUNC
                   (unwind-protect
                        (progn
                          (llvm-position-builder-at-end tmp (llvm-append-basic-block fn "entry"))
                          (llvm-build-ret tmp (funcall body-fn tmp
                                                       (loop for i below n
                                                             collect (crisp.llvm-bindings::llvm-get-param fn i)))))
                     (llvm-dispose-builder tmp))
                   fn)))
         (call (cffi:with-foreign-objects ((avals :pointer (max 1 n)))
                 (loop for i from 0 for v in arg-vals do (setf (cffi:mem-aref avals :pointer i) v))
                 (crisp.llvm-bindings::llvm-build-call2 builder fnty fn avals n "helper_call"))))
    (%propagate-callee-cc-to-call call fn)
    call))

;;; Endeavour 200: BUG 145 -- semantic-while was missing from semantic-node-type and
;;; semantic-node-source-location.  A while whose type is asked for (the last form of a let body, which
;;; takes its type from it) died with a raw ETYPECASE fall-through printing the whole semantic tree.
;;; FOLD: add the two clauses to the etypecases in src/analysis/core.lisp and drop these wrappers.

;; src/analysis/core.lisp
(defvar *200-orig-semantic-node-type* (fdefinition 'semantic-node-type))

;; src/analysis/core.lisp
(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.  Endeavour 200 (BUG 145): semantic-while (void)."
  (if (semantic-while-p node)
      (semantic-while-type node)
      (funcall *200-orig-semantic-node-type* node)))

;; src/analysis/core.lisp
(defvar *200-orig-semantic-node-source-location* (fdefinition 'semantic-node-source-location))

;; src/analysis/core.lisp
(defun semantic-node-source-location (node)
  "The source location of a semantic node.  Endeavour 200 (BUG 145): semantic-while."
  (if (semantic-while-p node)
      (semantic-while-source-location node)
      (funcall *200-orig-semantic-node-source-location* node)))

;;; Endeavour 200 follow-up -- `while` is compiler-internal (%while), and the forms that hide one
;;; carry a VJP.  Crisp is not Turing-complete: an author never writes an unbounded loop.  A
;;; compiler form may hide one (sync-wait's spin) only behind a form the A|D pass sees whole.

;; src/errors.lisp
(defparameter *unsupported-form-hints*
  '(("EQ" . "compare values, including enum keywords, with =")
    ("EQL" . "compare values, including enum keywords, with =")
    ("EQUAL" . "compare values, including enum keywords, with =")
    ("EQUALP" . "compare values, including enum keywords, with =")
    ("/=" . "not-equal is !=")
    ("SETF" . "assign with set!, e.g. (set! x v) or (set! (~ v i) x)")
    ("SETQ" . "assign with set!")
    ("AREF" . "index a storage handle with ~, e.g. (~ v i)")
    ("DEFUN" . "define functions at top level with def-function")
    ("LET*" . "Crisp's let is already sequential; use let")
    ("PROGN" . "a function or let body is already a sequence of forms")
    ("INCF" . "write (set! x (+ x 1))")
    ("DECF" . "write (set! x (- x 1))")
    ("DOLIST" . "loop with dotimes or one of the stride macros")
    ("LOOP" . "loop with dotimes or one of the stride macros")
    ("WHILE" . "every Crisp loop is bounded, so kernels always terminate -- loop with dotimes or one of the stride macros, and leave early with return-from-loop"))
  "Common Lisp operator name -> what to write in Crisp instead.  Appended to the
   unsupported-form error (ADV-007).  Endeavour 200: WHILE -- an author never writes an unbounded
   loop; the compiler's own spin (sync-wait) is %while, which no user form names.")

;; src/analysis/control.lisp
(defvar *200-orig-register-control-analyzers* (fdefinition 'register-control-analyzers))

;; src/analysis/control.lisp
(defun register-control-analyzers ()
  "Endeavour 200: the while analyzer is registered ONLY as crisp.compiler::%while.  It was also
   registered as crisp-language::while, so authors could write unbounded loops (Crisp is not
   Turing-complete).  FOLD: in register-control-analyzers replace the WHILE block with the single
   %WHILE registration below."
  (funcall *200-orig-register-control-analyzers*)
  (remhash (intern "WHILE" (find-package :crisp-language)) *expression-analyzers*)
  (remhash (intern "WHILE" (find-package :crisp.compiler)) *expression-analyzers*)
  (setf (gethash (intern "%WHILE" (find-package :crisp.compiler)) *expression-analyzers*)
        #'analyze-while-expression)
  (log:debug "200: while analyzer registered as %WHILE only"))

;; src/macros.lisp  (MACRO -- patch src directly; it is expanded only at Crisp-compile time, so the
;; overlay copy is live for testing)
(defmacro sync-wait (handle)
  "Blocks until count units have been put into the sync bucket.  The spin is the compiler-internal
   %while (endeavour 200); under --differentiate sync-wait is opaque to ANF and has its own VJP."
  `(progn
    (%while (< (crisp.compiler::%volatile-read (~ (arrival-sync-handle-counter ,handle))) (arrival-sync-handle-count ,handle))
            (mem-fence))
    (sync-workgroup)))

;; src/anf-transform.lisp
(defvar *200-orig-anf-normalize* (fdefinition 'anf-normalize))

;; src/anf-transform.lisp
(defun anf-normalize (expr is-nested?)
  "Endeavour 200 wrapper.  FOLD into anf-normalize's dispatch:
    * MAKE-SCRATCH-CELL keeps its trailing arguments.  The clause rebuilt it as
      (make-scratch-cell TYPE), dropping :address-space :global, so a global cell became a LOCAL one
      in the backward walk (make-arrival-sync: 'Expected (CELL INT ADDRESS-SPACE GLOBAL) but
      inferred (CELL INT LOCAL)').
    * WHILE is refused as the analyzer refuses it (A|D runs before the forward kernel is analyzed).
    * %WHILE must never reach ANF: the compiler hides a spin only inside a form that has a VJP and
      is opaque here (sync-wait).  Reaching this is a compiler bug, not an author's."
  (let ((name (and (consp expr) (symbolp (car expr)) (symbol-name (car expr)))))
    (cond ((equal name "MAKE-SCRATCH-CELL")
           (%anf-bind-if-nested (copy-list expr) nil is-nested?))
          ((equal name "WHILE")
           (error 'crisp-unsupported-form-error :form (car expr)))
          ((equal name "%WHILE")
           (error "Internal compiler error: a %while reached the A|D pass (~s).  The compiler hides an unbounded spin only inside a form that is opaque to ANF and has a registered VJP (see sync-wait); whichever form expanded to this one needs both."
                  expr))
          (t (funcall *200-orig-anf-normalize* expr is-nested?)))))

;; src/anf-transform.lisp  (FOLD: add SYNC-ARRIVE / SYNC-WAIT to both defparameter lists)
(pushnew 'sync-arrive *anf-unexpanded-macros*)
(pushnew 'sync-wait *anf-unexpanded-macros*)
(pushnew "SYNC-ARRIVE" *anf-opaque-statement-names* :test #'string=)
(pushnew "SYNC-WAIT" *anf-opaque-statement-names* :test #'string=)

;; src/autodiff.lisp
(defun %200-vjp-sync-wait (form ctx)
  "Backward rule for sync-wait (endeavour 200).  An arrival sync orders the work BEFORE every arrive
   ahead of the work AFTER every wait.  The adjoints flow the other way, so in the backward the roles
   swap: at the mirror of its wait a thread SIGNALS that the adjoints of its after-wait work are
   published, and at the mirror of its arrive it WAITS for every thread's signal before running the
   adjoints of its before-arrive work.  The walk runs in reverse, so this wait's mirror is an arrive.
   Both forms are refused under divergent control, so the arriving and the waiting threads are the same
   set and the forward's count still applies.  The backward kernel replays the forward's bindings but
   not its statements, so the replayed handle is a fresh, zeroed counter."
  (declare (ignore ctx))
  (log:debug "200 VJP sync-wait ~s -> sync-arrive" (second form))
  `(sync-arrive ,(second form)))

;; src/autodiff.lisp
(defun %200-vjp-sync-arrive (form ctx)
  "Backward rule for sync-arrive (endeavour 200): the mirror of an arrive is a wait -- see
   %200-vjp-sync-wait."
  (declare (ignore ctx))
  (log:debug "200 VJP sync-arrive ~s -> sync-wait" (second form))
  `(sync-wait ,(second form)))

;; src/autodiff.lisp
(eval-when (:load-toplevel :execute)
  (register-vjp "SYNC-WAIT"   (function %200-vjp-sync-wait))
  (register-vjp "SYNC-ARRIVE" (function %200-vjp-sync-arrive)))

;; src/autodiff.lisp
(defun %200-vjp-construct-struct (form ctx)
  "Backward rule for %construct-struct (endeavour 200): building an ARRIVAL-SYNC-HANDLE is gradient-inert.
   The handle is a scheduling object -- an integer counter cell and an integer count -- exactly as a
   barrier is.  Walked as a struct, its counter CELL was given a scalar adjoint 0.0 that shadowed the
   cell's paired scratch adjoint ('No matching function overload found for ~ with argument types
   (FLOAT)').  Every other struct DECLINES, so the walk's own constructor clauses run unchanged."
  (declare (ignore ctx))
  (when (and (symbolp (second form)) (string-equal (symbol-name (second form)) "ARRIVAL-SYNC-HANDLE"))
    (log:debug "200 VJP %construct-struct arrival-sync-handle: inert")
    :inert))

;; src/autodiff.lisp
(eval-when (:load-toplevel :execute)
  (register-vjp "%CONSTRUCT-STRUCT" (function %200-vjp-construct-struct)))
