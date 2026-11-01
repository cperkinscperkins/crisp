;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
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

;;; ===================================================================
;;; Endeavour 202: derived types through handles, :enforce :always, operator definitions.
;;; ===================================================================

;; src/mangling.lisp
(defun %unmangled-symbol (token-str package)
  "The symbol a mangled template-name token stands for.  Prefers a type the user registered in
   :crisp-language over a same-named symbol in PACKAGE: a template such as CELL lives in
   crisp.compiler, so interning there minted CRISP.COMPILER::Q-C, which *crisp-types* has never heard
   of, and (+ (~ a) (~ b)) died with \"Cannot operate on Q-C and Q-C\" (endeavour 202).  A symbol
   PACKAGE already has registered wins, which keeps the shadowed primitives (CHAR, FLOAT) as they were."
  (let ((existing (find-symbol token-str package))
        (lang (find-symbol token-str :crisp-language)))
    (flet ((registered-p (sym)
             (and sym (boundp '*crisp-types*)
                  (or (gethash sym *crisp-types*) (gethash sym *crisp-type-aliases*)))))
      (cond ((and lang (not (eq lang existing))
                  (not (registered-p existing))
                  (registered-p lang))
             (log:debug "%unmangled-symbol: ~a resolves to the registered ~s" token-str lang)
             lang)
            (existing existing)
            (t (intern token-str package))))))

;; src/mangling.lisp
(defun reconstruct-one-arg (tokens package)
  "Reads exactly one logical form (atom or template-expr) from tokens."
  (if (null tokens) (values nil nil)
      (let* ((token-str (first tokens))
                (token-sym (if (char= (cl:char token-str 0) #\:)
                               (intern (subseq token-str 1) :keyword)
                               (%unmangled-symbol token-str package)))
                (arity (and *template-arity-lookup-fn*
                            (funcall *template-arity-lookup-fn* token-sym))))

        (if (and arity (> arity 0))
            (multiple-value-bind (args remaining)
                (reconstruct-n-args (rest tokens) arity package)
              (values (list (cons token-sym args)) remaining))
            (values (list token-sym) (rest tokens))))))

;; src/mangling.lisp
(defun reconstruct-template-args (tokens package)
  "Recursively groups tokens into lists based on template arity.
   tokens: list of strings.
   package: the fallback package for interning.
   Returns: (values property-list remaining-tokens)
   FIX: numeric token strings are parsed as integers before interning as symbols."
  (if (null tokens)
      (values nil nil)
      (let* ((token-str (first tokens))
                ;; Handle keywords specially
                (token-sym (if (char= (cl:char token-str 0) #\:)
                               (intern (subseq token-str 1) :keyword)
                               ;; Try parse as integer first, then find/intern as symbol
                               (multiple-value-bind (n end)
                                   (parse-integer token-str :junk-allowed t)
                                 (if (and n (= end (length token-str)))
                                        n  ; it's a numeric token — return the integer
                                        (%unmangled-symbol token-str package)))))
                (arity (and (not (integerp token-sym))
                               *template-arity-lookup-fn*
                               (funcall *template-arity-lookup-fn* token-sym))))

        (if (and arity (> arity 0))
            ;; It's a template! Consume 'arity' args.
            (multiple-value-bind (args remaining)
                (reconstruct-n-args (rest tokens) arity package)
              (multiple-value-bind (rest-processed rest-remaining)
                  (reconstruct-template-args remaining package)
                (values (cons (cons token-sym args) rest-processed) rest-remaining)))

            ;; Not a template (or arity 0), treat as atom
            (multiple-value-bind (rest-processed rest-remaining)
                (reconstruct-template-args (rest tokens) package)
              (values (cons token-sym rest-processed) rest-remaining))))))

;; src/environment.lisp
(defparameter *unoverloadable-operators* '("+" "-" "*" "/" "*!" "<" "<=" ">" ">=" "=" "MAX" "MIN")
  "Operators with an *expression-analyzers* entry that never consults *function-table*.  analyze-expression
   tries analyzers first, so a user def-function of one of these compiled and was then silently never
   called.  Measured per operator in endeavour 202.  Accessors (~, X~) are absent on purpose: their
   analyzers do look for overloads, and that is a feature.")

;; src/environment.lisp
(defun %refuse-operator-definition (form location)
  "Signals if FORM is a def-function of an operator the compiler lowers directly (endeavour 202)."
  (when (and (consp form) (symbolp (car form)) (string-equal (symbol-name (car form)) "DEF-FUNCTION")
             (symbolp (second form))
             (member (symbol-name (second form)) *unoverloadable-operators* :test #'string=))
    (error 'crisp-compiler-error
           :message (format nil "~(~a~) cannot be overloaded: the compiler lowers it directly, so this definition would never be called.  Use a named function instead."
                            (second form))
           :source-location location)))

;; src/environment.lisp
(defun register-function-signature (form location)
  "Registers the signature of a def-function / def-kernel FORM in the environment.
   Endeavour 177: also records a def-function's (declare (reduction-vjp f)) in *REDUCTION-VJPS* -- or clears
   a stale entry, so in-process runs that redefine a function without it never see an old one."
  (%refuse-operator-definition form location)
  (when (and (consp form) (symbolp (car form)) (string-equal (symbol-name (car form)) "DEF-FUNCTION")
             (second form) (symbolp (second form)))
    (let ((vjp (%declared-reduction-vjp form))
          (key (symbol-name (second form))))
      (if vjp
          (progn (log:debug "177: ~a declares reduction-vjp ~a" (second form) vjp)
                 (setf (gethash key *reduction-vjps*) vjp))
          (remhash key *reduction-vjps*))))
  (let* ((name (second form))
         (params (third form))
         (body (cdddr form))
         (declare-forms (loop for f in body
                              while (and (listp f) (eq (car f) 'declare))
                              collect f)))

    (finish-output *error-output*)
    ;; Debug logging
    ;; (log:info "REGISTER-FUNC (Overlay): ~s" name)

    (multiple-value-bind (env return-types optional-idx extracted-defaults key-idx)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))

      ;; --- NEW VALIDATION ---
      (validate-dependent-brand-types declare-forms env)
      ;; ----------------------

      (cond
       ((or optional-idx key-idx)
         (%register-generic-function name params env return-types declare-forms
                                     extracted-defaults key-idx body location))
       (t
         (%register-standard-function name env return-types declare-forms location))))))

;; src/analysis/core.lisp -- the brand checks below were gated on *differentiate-p*, which silently
;; disabled :enforce :always in every other pass.  Both already ask brand-active-p, so the gate goes.
(defun analyze-function-call (op expr env context location)
  "Analyzes a function call expression.
   Checks for struct immutability violations via %check-struct-mutating-call.
   Extended (091): grid functions can only be called from a dispatch context.
   Endeavour 193: a call to a function that may die makes the caller may-die too.  Multi-pass compiles
   know this from Pass 1.5 already; --single-pass relies on this.  (A lazily instantiated variant marks
   itself when its own body is analysed.)
   Endeavour 194 (D4, F3): a call reaches whatever its callee reaches.  A callee that contains a
   barrier is refused where only some threads of the workgroup arrive; one that contains a warp
   collective, where lanes may have split.  Both are recorded for the enclosing loop and the caller's
   own summary, so the rule is transitive."
  (let ((%194-node
         (progn
             (when (%193-may-die-p op)
               (let ((caller (%193-current-function context)))
                 (when (and caller (not (%193-may-die-p caller)))
                   (log:info "193: ~a may die (analysis: calls ~a)" caller op)
                   (setf (gethash caller *may-die-functions*) t))))
             (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

             ;; Recursion / call-graph tracking
             (if (multi-pass-mode-p)
                 (when (compiler-context-current-compiling-function context)
                       (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
                 (when (eq op (compiler-context-current-compiling-function context))
                       (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

             ;; Grid function dispatch-context check
             (when (and (gethash op *grid-functions*)
                        (not *in-dispatch-context*))
               (error 'crisp-compiler-error
                 :message (format nil "Grid function '~(~a~)' cannot be called outside a dispatch context. Use def-kernel or def-grid-function to provide a dispatch context." op)
                 :source-location location))

             ;; Implicit args
             (let ((implicit-args-required (gethash op *implicit-arg-map*)))
               (when (and (single-pass-mode-p) implicit-args-required)
                     (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

               (let* ((arg-forms (rest expr))
                      (explicit-arg-nodes (loop for arg-form in arg-forms
                                                for i from 1
                                                collect (analyze-expression arg-form env context (append location (list i)))))
                      (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
                      (signature (resolve-best-signature op explicit-arg-types context)))

                 ;; Struct mutating function check
                 (%check-struct-mutating-call op explicit-arg-nodes env context location)

                 (let ((final-arg-nodes
                        (if implicit-args-required
                            (let ((implicit-arg-nodes
                                   (loop for (param-name . param-type) in implicit-args-required
                                         collect (let ((found (find-variable-in-env param-name env)))
                                                   (if found
                                                       (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                                       (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                                         (compiler-context-current-compiling-function context) param-name))))))
                              (append implicit-arg-nodes explicit-arg-nodes))
                            explicit-arg-nodes)))

                   (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
                     (error 'crisp-signature-arity-error
                       :expected (length (function-signature-parameters signature))
                       :inferred (length explicit-arg-types)
                       :source-location location))

                   ;; === Uniformity Constraint Checking ===
                   (let ((sig-params (function-signature-parameters signature)))
                     (loop for param in sig-params
                           for arg-node in explicit-arg-nodes
                           do (when (eq (parameter-def-uniformity param) :uniform)
                                (let ((arg-uniformity (calculate-uniformity-state arg-node env)))
                                  (unless (eq arg-uniformity :uniform)
                                    (error 'crisp-compiler-error
                                      :message (format nil "Function ~a requires parameter ~a to be :uniform, but inferred state was ~a. Use (to-workgroup-uniform ...) if you must."
                                                       (function-signature-name signature)
                                                       (parameter-def-name param)
                                                       arg-uniformity)
                                      :source-location location))))))

                   (let ((augmented-signature
                          (if implicit-args-required
                              (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                           collect (make-parameter-def :name param-name :type param-type :kind :in))))
                                (make-function-signature
                                 :name (function-signature-name signature)
                                 :parameters (append implicit-params (function-signature-parameters signature))
                                 :return-types (function-signature-return-types signature)
                                 :source-location (function-signature-source-location signature)
                                 :is-template-p (function-signature-is-template-p signature)
                                 :template-params (function-signature-template-params signature)))
                              signature)))

                     ;; === Brand Instance Type Checking (when --differentiate is active) ===
                     (let ((refined-return-types (function-signature-return-types augmented-signature)))

                       (progn
                         (let ((sig-params (function-signature-parameters augmented-signature)))

                           ;; 1. Brand parameter type checking
                           (loop for param in sig-params
                                 for arg-node in final-arg-nodes
                                 for param-type = (parameter-def-type param)
                                 do (let ((brand-def (is-brand-type-p param-type)))
                                      (when (and brand-def (brand-active-p brand-def))
                                        (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                   sig-params final-arg-nodes)))
                                          (when owner-var
                                            (let* ((expected-type (resolve-brand-type param-type owner-var))
                                                      (actual-type (get-single-value-type arg-node)))
                                              (unless (or (eq actual-type expected-type)
                                                          (is-substitutable-for? actual-type expected-type))
                                                (error 'crisp-type-error
                                                  :expected (list expected-type)
                                                  :inferred (list actual-type)
                                                  :source-location location))))))))

                           ;; 2. Brand return type refinement
                           (setf refined-return-types
                             (loop for ret-type in (function-signature-return-types augmented-signature)
                                   collect (let ((brand-def (is-brand-type-p ret-type)))
                                             (if (and brand-def (brand-active-p brand-def))
                                                 (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                            sig-params final-arg-nodes)))
                                                   (if owner-var
                                                       (resolve-brand-type ret-type owner-var)
                                                       ret-type))
                                                 ret-type))))))

                       (make-semantic-call :name (function-signature-name augmented-signature)
                                           :type refined-return-types
                                           :args final-arg-nodes
                                           :signature augmented-signature
                                           :source-location location))))))))) 
    (when (semantic-call-p %194-node)
      (let ((summary (gethash (%194-summary-key (semantic-call-name %194-node)) *194-function-summaries*)))
        (if (null summary)
            (log:debug "194: no summary for callee ~a (not compiled yet) -- call site unchecked"
                       (semantic-call-name %194-node))
            (let ((barrier (%194-fn-summary-barrier summary))
                  (collective (%194-fn-summary-collective summary))
                  (callee (string-downcase (%194-summary-key (semantic-call-name %194-node)))))
              (when barrier
                (%194-note :barrier (format nil "~a (it reaches ~a)" callee barrier) location t)
                (when *in-divergent-conditional*
                  (%194-barrier-refusal (format nil "A call to ~a, which reaches ~a," callee barrier)
                                        "workgroup" location)))
              (when collective
                (%194-note :collective (format nil "~a (it reaches ~a)" callee collective) location t)
                (when *in-lane-divergent*
                  (%194-collective-refusal (format nil "A call to ~a, which reaches ~a," callee collective)
                                           location)))))))
    %194-node))

;; src/metadata.lisp
(defun %host-visible-type (type-spec)
  "TYPE-SPEC with every derived NUMERIC type replaced by its primitive.  A hoist reads metadata alone
   and has no type registry, so `(vector q-c ..)` reached the generated C++ as an undeclared `q_c`
   (endeavour 202).  The primitive is the true host ABI.  Derived STRUCT types are left alone: their
   name is what the host's struct lookup wants."
  (cond ((consp type-spec) (mapcar #'%host-visible-type type-spec))
        ((and type-spec (symbolp type-spec) (not (keywordp type-spec))
              (not (eq (get-type-base type-spec) type-spec)))
         (let* ((base (get-type-base type-spec))
                (ct (gethash base *crisp-types*)))
           (if (and ct (member (crisp-type-category ct) '(:signed-int :unsigned-int :float)))
               (progn (log:debug "%host-visible-type: ~a -> ~a" type-spec base) base)
               type-spec)))
        (t type-spec)))

;; src/metadata.lisp
(defun serialize-aliases (stream aliases-hash)
  (format stream "(:aliases~%")
  (let ((aliases (alexandria:hash-table-keys aliases-hash)))
    (setf aliases (sort aliases #'string< :key #'symbol-name))
    (dolist (alias aliases)
      (let ((target (gethash alias *crisp-type-aliases*)))
        (format stream "  (def-type ~a " (strip-package-qualifiers alias))
        (print-without-packages (%host-visible-type target) stream)
        (format stream ")~%"))))
  (format stream "  )~%~%"))

;; src/metadata.lisp
(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared-signature plist for a kernel's metadata.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Count implicit params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t)
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              (setf entry (append entry (list :type (strip-package-qualifiers (%host-visible-type type)))))
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              (when (%storage-handle-type-p type)
                (let* ((canonical (canonicalize-type-specifier type))
                       (base (if (consp canonical) (first canonical) canonical))
                       (is-cell   (and (symbolp base) (string-equal (symbol-name base) "CELL")))
                       (is-tensor (and (symbolp base) (string-equal (symbol-name base) "TENSOR")))
                       ;; CELL 3-tuple:   (cell elem ADDR)         — addr at index 2
                       ;; TENSOR 6-tuple: (tensor elem N ADDR aln ct) — addr at index 3
                       (as (if (and (consp canonical) is-cell (>= (length canonical) 3))
                               (nth 2 canonical)
                               (if (consp canonical)
                                   (let ((found (member :address-space canonical)))
                                     (if found (second found) :global))
                                   :global))))
                  (setf entry (append entry (list :address-space as)))
                  (when is-tensor
                    (let* ((n (if (integerp (third canonical))
                                  (third canonical)
                                  (parse-integer (symbol-name (third canonical)))))
                           ;; TENSOR 6-tuple: (tensor T N addr ALN ct) — aln at index 4
                           (alg (or (nth 4 canonical) :compact)))
                      (setf entry (append entry (list :rank n :align alg)))))))

              (setf entry (append entry (list :range (list start end))))
              ;; 179: a reduction output the host must set to the identity before every launch.
              (let ((launch-init (%reduction-launch-init-for (function-signature-name sig) name)))
                (when launch-init
                  (setf entry (append entry (list :launch-init launch-init)))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))

;;; ===================================================================
;;; Endeavour 203: accumulator types, widening *! +! -!, widen, to-sat.
;;; ===================================================================
;;; NOTE FOR THE FOLD: set-accum, widen, +!, -! and to-sat need exporting through src/package.lisp the
;;; way set-derived is.  An analyzer is found by symbol name, so only the set-accum macro depends on
;;; the crisp-language:: spelling used here.  "*!" also leaves *185-math-op-names*.

;; src/globals.lisp
(defvar *accum-registry* (make-hash-table :test 'equal)
  "(NAME-A . NAME-B) -> accumulator type symbol, filled by set-accum.  Keyed by symbol NAME so that a
   type read through a handle cannot miss on its package (endeavour 202).  Cleared per compile.")

;; src/globals.lisp
(defvar *accum-base-registry* (make-hash-table :test 'equal)
  "Accumulator type NAME -> its base type symbol, for a single-operand set-accum.  Cleared per compile.")

;; src/types/hierarchy.lisp
(defun %accum-key (a b)
  "The *accum-registry* key for the operand pair A, B, after alias resolution."
  (cons (symbol-name (resolve-type-alias a)) (symbol-name (resolve-type-alias b))))

;; src/types/hierarchy.lisp
(defun %accum-numeric-parts (type-name)
  "(values CATEGORY BITS) of TYPE-NAME's underlying primitive, or NIL if it is not numeric."
  (let ((ct (and (symbolp type-name) (gethash (get-type-base (resolve-type-alias type-name)) *crisp-types*))))
    (when (and ct (member (crisp-type-category ct) '(:signed-int :unsigned-int :float)))
      (values (crisp-type-category ct) (crisp-type-size ct)))))

;; src/types/hierarchy.lisp
(defun %validate-accum-pair (a b accum)
  "Signals unless ACCUM can hold every product of A and B exactly."
  (multiple-value-bind (a-cat a-bits) (%accum-numeric-parts a)
    (multiple-value-bind (b-cat b-bits) (%accum-numeric-parts b)
      (multiple-value-bind (acc-cat acc-bits) (%accum-numeric-parts accum)
        (unless (and a-cat b-cat acc-cat)
          (error 'crisp-compiler-error
                 :message (format nil "set-accum: ~a, ~a and ~a must all be numeric types." a b accum)))
        (let ((need (+ a-bits b-bits)))
          (unless (>= acc-bits need)
            (error 'crisp-compiler-error
                   :message (format nil "set-accum: accumulator ~a must be at least ~a bits to hold a product of ~a and ~a; it is ~a."
                                    accum need a b acc-bits))))
        (when (and (or (eq a-cat :signed-int) (eq b-cat :signed-int)) (eq acc-cat :unsigned-int))
          (error 'crisp-compiler-error
                 :message (format nil "set-accum: accumulator ~a must be signed: a product involving signed ~a can be negative."
                                  accum (if (eq a-cat :signed-int) a b))))))))

;; src/types/hierarchy.lisp
(defun register-accum-type (operands accum)
  "Records ACCUM as the accumulator of OPERANDS, a type name or a list of two.  (set-accum B A) also
   makes A its own accumulator and B its base; (set-accum (B C) A) is a mixed-operand product."
  (let* ((pair-p (consp operands))
         (a (if pair-p (first operands) operands))
         (b (if pair-p (second operands) operands))
         (key (%accum-key a b)))
    (%validate-accum-pair a b accum)
    (let ((existing (gethash key *accum-registry*)))
      (when (and existing (not (eq existing accum)))
        (error 'crisp-compiler-error
               :message (format nil "set-accum: ~a already has an accumulator, ~a." operands existing))))
    (setf (gethash key *accum-registry*) accum)
    (setf (gethash (%accum-key accum accum) *accum-registry*) accum)
    (unless pair-p
      (setf (gethash (symbol-name (resolve-type-alias accum)) *accum-base-registry*) a))
    (log:debug "register-accum-type: ~a -> ~a" operands accum)
    accum))

;; src/types/hierarchy.lisp
(defun accum-type-of (a &optional (b a))
  "(accum A B).  A declared accumulator, else A itself when A and B are the same type: for the basic
   types (accum T) is T.  NIL for an undeclared pair of different types."
  (or (gethash (%accum-key a b) *accum-registry*)
      (and (string= (symbol-name (resolve-type-alias a)) (symbol-name (resolve-type-alias b)))
           (resolve-type-alias a))))

;; src/types/hierarchy.lisp
(defun base-type-of (type-name)
  "(base T): the base of a declared accumulator, else T."
  (or (gethash (symbol-name (resolve-type-alias type-name)) *accum-base-registry*)
      (resolve-type-alias type-name)))

;; src/types/hierarchy.lisp
(defun %type-accessor-form-p (spec)
  "T for the type forms (accum T), (accum A B) and (base T)."
  (and (consp spec) (symbolp (first spec))
       (member (symbol-name (first spec)) '("ACCUM" "BASE") :test #'string=)
       t))

;; src/types/hierarchy.lisp
(defun resolve-type-accessor (spec)
  "The type named by the accessor form SPEC.  The one registry a future def-type-function would fill."
  (let* ((args (mapcar #'parse-type-specifier (rest spec)))
         (result (if (string= (symbol-name (first spec)) "BASE")
                     (base-type-of (first args))
                     (apply #'accum-type-of args))))
    (unless result
      (error 'crisp-compiler-error
             :message (format nil "(accum ~{~(~a~)~^ ~}): no accumulator is declared for these types.  Use set-accum." args)))
    (log:debug "resolve-type-accessor: ~s -> ~a" spec result)
    result))

;; src/macros.lisp
(defmacro crisp-language::set-accum (operands accum)
  "Declares ACCUM the accumulator type of OPERANDS, a type or a list of two types.
   Syntax: (set-accum q-a q-a-accum) or (set-accum (q-act q-wt) q-dot).
   Requirements:
   - All types are numeric.
   - ACCUM holds a full product: at least the sum of the operand widths.
   - ACCUM is signed if either operand is."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (register-accum-type ',operands ',accum)))

;; src/analysis/ops.lisp
(defun %cast-node (node to-type location)
  "NODE as a value cast to TO-TYPE, or NODE itself when it already has that type."
  (if (eq (get-single-value-type node) to-type)
      node
      (make-semantic-value-cast :type to-type :arg node :source-location location)))

;; src/analysis/ops.lisp
(defun %widen-node (node accum location)
  "NODE at ACCUM's underlying primitive, extended according to NODE's own signedness."
  (%cast-node node (get-type-base accum) location))

;; src/analysis/ops.lisp
(defun analyze-accum-op (expr env context location)
  "Analyzes (*! a b), (+! a b), (-! a b).  With a declared accumulator both operands widen by their own
   signedness and the op runs at the accumulator's width.  There is no widening add instruction: PTX
   has no add.wide, so sext + add IS the lowering.  Otherwise this is the plain operator (decision D6)."
  (let* ((name (symbol-name (first expr)))
         (plain (%185-crisp-sym (subseq name 0 1)))
         (args (rest expr)))
    (unless (= (length args) 2)
      (error 'crisp-compiler-error
             :message (format nil "~(~a~) takes 2 arguments; got ~a" name (length args))
             :source-location location))
    ;; No set-accum in this compile: nothing can widen, so take the plain path without analyzing twice.
    (when (zerop (hash-table-count *accum-registry*))
      (return-from analyze-accum-op
        (analyze-expression (list plain (first args) (second args)) env context location)))
    (let* ((left (analyze-expression (first args) env context (append location '(1))))
           (right (analyze-expression (second args) env context (append location '(2))))
           (left-type (get-single-value-type left))
           (right-type (get-single-value-type right))
           (accum (if (string= name "*!")
                      (and (gethash (%accum-key left-type right-type) *accum-registry*)
                           (accum-type-of left-type right-type))
                      (let ((la (accum-type-of left-type)) (ra (accum-type-of right-type)))
                        (and la ra (eq la ra)
                             (or (not (eq left-type la)) (not (eq right-type la))
                                 (gethash (%accum-key left-type right-type) *accum-registry*))
                             la)))))
      (log:debug "analyze-accum-op: ~a ~a ~a => accum ~a" name left-type right-type accum)
      (if (null accum)
          (analyze-expression (list plain (first args) (second args)) env context location)
          (let* ((l (%widen-node left accum location))
                 (r (%widen-node right accum location))
                 (prim (get-type-base accum))
                 (op-node (cond ((string= name "*!")
                                 (make-semantic-mul :type prim :left-arg l :right-arg r :source-location location))
                                ((string= name "+!")
                                 (make-semantic-add :type prim :left-arg l :right-arg r :source-location location))
                                (t
                                 (make-semantic-sub :type prim :left-arg l :right-arg r :source-location location)))))
            (%cast-node op-node accum location))))))

;; src/analysis/ops.lisp
(defun analyze-widen (expr env context location)
  "(widen x): x at its accumulator type, keeping its scale.  The identity on the basic types."
  (let* ((node (analyze-expression (second expr) env context (append location '(1))))
         (type (get-single-value-type node))
         (accum (accum-type-of type)))
    (if (eq accum type)
        node
        (%cast-node (%widen-node node accum location) accum location))))

;; src/analysis/ops.lisp
(defun analyze-to-sat (expr env context location)
  "(to-sat T x): float X rounded to nearest, ties to even, then saturated to integer type T, with NaN
   going to 0."
  (let* ((target (resolve-type-alias (second expr)))
         (node (analyze-expression (third expr) env context (append location '(2))))
         (source (get-single-value-type node)))
    (multiple-value-bind (cat bits) (%accum-numeric-parts target)
      (declare (ignore bits))
      (unless (member cat '(:signed-int :unsigned-int))
        (error 'crisp-compiler-error
               :message (format nil "to-sat needs an integer target; got ~(~a~)." target)
               :source-location location)))
    (multiple-value-bind (cat bits) (%hw-type-parts source)
      (unless (and (eq cat :float) (member bits '(32 64)))
        (error 'crisp-compiler-error
               :message (format nil "to-sat: operand must be float or double; got ~(~a~)." source)
               :source-location location)))
    (make-semantic-hw-op :op '%to-sat :type target :args (list node) :source-location location)))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%to-sat)) builder module arg-vals arg-types result-type)
  "to-sat: llvm.rint, which is nearest with ties to even in the default rounding mode, then
   llvm.fpto[su]i.sat, which clamps to the target's range and sends NaN to 0."
  (let* ((source (first arg-types))
         (prim (get-type-base result-type))
         (rounded (%hw-intrinsic builder module "rint" source (first arg-vals))))
    (multiple-value-bind (cat bits) (%hw-type-parts prim)
      (%hw-call builder module
                (format nil "llvm.fpto~ai.sat.i~a.~a" (if (eq cat :signed-int) "s" "u") bits (%hw-type-suffix source))
                (crisp-type-to-llvm-type prim module) (list rounded) "to_sat"))))

;; src/analysis/ops.lisp
(defun %register-accum-analyzers ()
  "Registers the endeavour 203 analyzers by name in both packages."
  (let ((pkgs (list (find-package :crisp-language) (find-package :crisp.compiler))))
    (dolist (entry '(("*!" . analyze-accum-op) ("+!" . analyze-accum-op) ("-!" . analyze-accum-op)
                     ("WIDEN" . analyze-widen) ("TO-SAT" . analyze-to-sat)))
      (dolist (pkg pkgs)
        (setf (gethash (intern (car entry) pkg) *expression-analyzers*) (cdr entry))))))

;; src/compiler.lisp -- clears the accumulator registries
(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil)
                                 (math-precision :ieee) (force-math-precision nil)
                                 (denormal-handling :preserve)
                                 (hardware-profile nil)
                                 (logging-output nil) (logging-size nil))
  "Initializes the compiler state.
   Extended to clear *grid-functions* for def-grid-function support.
   Endeavour 193: LOGGING-OUTPUT (--logging-output) implies RUNTIME-CHECKS; under DIFFERENTIATE the
   log is off (the gradient kernels are compiled without it) but RUNTIME-CHECKS is honoured.
   LOGGING-SIZE is the log's size in bytes (--logging-size, default 4M).
   Endeavour 194: also forgets the function summaries (%194-clear-summaries)."
  (%194-clear-summaries)
  (let ((logging (and logging-output (not differentiate))))
    (setf *logging-output-enabled* logging
          *logging-size-bytes* (or logging-size (* 4 1024 1024))
          *runtime-checks-enabled* (or runtime-checks logging)))
  (setf *differentiate-p* differentiate)
  ;; Endeavor 130: record the requested hardware profile (a name string) and clear
  ;; the profile registry (the current file's def-hardware-profile forms re-register).
  (setf *requested-hardware-profile* hardware-profile)
  (clrhash *hardware-profiles*)
  ;; Endeavor 126: force is the hard lock; the effective starting precision is
  ;; force (if given) else the --math-precision flag. declaim/with-precision may
  ;; later mutate *math-precision* only when *force-math-precision* is NIL.
  (setf *force-math-precision* force-math-precision)
  (setf *math-precision* (or force-math-precision math-precision))
  (setf *denormal-handling* denormal-handling)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (progn
        (log:config :sane :stream *error-output* log-level)
        (%drop-terminal-io-log-appender)))
  ;; Reproducible output: every compilation numbers its gensyms from the same base.
  (%reset-gensym-counter)

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
  (clrhash *accum-registry*)
  (clrhash *accum-base-registry*)
  (clrhash *crisp-template-aliases*)
  (clrhash *generic-functions*)
  (clrhash *kernel-declared-signatures*)
  (when (boundp '*record-definitions*) (clrhash *record-definitions*))

  (setf *compiled-kernels* nil)

  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)
  (clrhash *foreign-functions*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
        (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))
  ;; Endeavour 193: r-t-output's message node, and the per-compile die / log tables.
  (setf (gethash '%193-log-message *function-table*)
        (list (make-function-signature :name '%193-log-message :parameters nil :return-types '(nil))))
  (clrhash *may-die-functions*)
  (clrhash *die-messages*)
  (clrhash *193-location-sites*)
  (clrhash *193-log-messages*)
  (setf *die-sites* nil
        *log-sites* nil)

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  ;; 101 endeavor: clear parameterized-brand-names too — left-over state from a
  ;; prior test (e.g. value-t marked parameterized after cell+fake-cell both
  ;; defined value-t) was bleeding into later tests in 037-cell-branded, masking
  ;; the brand-instance mismatch that errors/02 and errors/04 expect to detect.
  (when (boundp '*parameterized-brand-names*) (clrhash *parameterized-brand-names*))

  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)
  ;; 179: clear the reduction launch-init side table (same lifetime)
  (clrhash *reduction-launch-init*)

  ;; Endeavor 137: clear the CUtensorMap descriptor metadata side table.  This is a PERSISTENT
  ;; global (not rebound per-module) so it survives to metadata-emission time, which runs after
  ;; compile-module returns — same lifetime as *implicit-scratch-size-expr-map*.
  (when (boundp '*tma-descriptor-info*)
    (clrhash *tma-descriptor-info*))
  (when (boundp '*tma-resolved*)
    (clrhash *tma-resolved*))

  ;; clear dispatch declarations side table
  (clrhash *kernel-dispatch-declarations*)

  ;; clear grid-function registry
  (clrhash *grid-functions*)

  (register-builtins)
  (register-mma-types)              ; Endeavor 132 — MMA fundamentals (src/mma.lisp)

  (log:info "Compiler initialized. differentiate=~a" differentiate))

;; src/environment.lisp -- (accum T) and (base T) in a type position
(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s).
   Extended: (array T N) is returned as-is (not mangled) before the generic path."
  (cond
   ;; (accum T), (accum A B), (base T) -- endeavour 203
   ((%type-accessor-form-p spec) (resolve-type-accessor spec))
   ;; (array T N) — return as a list spec unchanged, not mangled
   ((%array-type-p spec)
    spec)

   ;; 0. Type Aliases
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved)
       (if (and (consp resolved) (eq (first resolved) 'common-lisp:function))
           (let* ((sig (if (listp (second resolved)) (second resolved) (rest resolved)))
                     (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                              (string-equal (symbol-name x) "=>")))
                                             sig))
                     (param-types (if arrow-pos (subseq sig 0 arrow-pos) sig))
                     (return-types (if arrow-pos (nthcdr (1+ arrow-pos) sig) nil)))
             `(:function-type ,return-types :params ,(mapcar #'parse-type-specifier param-types)))
           spec)))

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (let* ((alias-name (first spec))
               (args (rest spec))
               (alias-def (gethash alias-name *crisp-template-aliases*))
               (params (car alias-def))
               (body-spec (cdr alias-def))
               (arity (length params))
               (required-args (subseq args 0 (min (length args) arity)))
               (rest-args (subseq args (length required-args)))
               (substitutions (pairlis params required-args)))
       (let ((expanded (sublis substitutions body-spec)))
         (let ((final-spec (if (and rest-args (consp expanded))
                                  (append expanded rest-args)
                                  (if rest-args
                                      (cons expanded rest-args)
                                      expanded))))
           (parse-type-specifier final-spec)))))

   ;; 0.15 Brand Type Application: (brand-name var-ref)
   ((and (listp spec)
         (= (length spec) 2)
         (symbolp (first spec))
         (symbolp (second spec))
         (is-brand-type-p (first spec)))
     (let* ((brand-name (first spec))
               (var-ref (second spec))
               (brand-def (is-brand-type-p brand-name)))
       (if (gethash brand-name *parameterized-brand-names*)
           (progn
             (log:info "PARSE: Parameterized brand application (~a ~a) - deferring resolution"
                       brand-name var-ref)
             spec)
           (progn
             (log:info "PARSE: Brand type application (~a ~a) -> ~a [~a]"
                       brand-name var-ref brand-name
                       (if (brand-active-p brand-def) "active" "inactive"))
             brand-name))))

   ;; 0.2 Simple Alias as List Head (e.g. (int-cell :access :read-only))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-type-aliases*))
     (let* ((alias-name (first spec))
               (args (rest spec))
               (expanded-base (gethash alias-name *crisp-type-aliases*)))
       (let ((final-spec (if (listp expanded-base)
                                (append expanded-base args)
                                (cons expanded-base args))))
         (log:info "EXPAND-ALIAS-HEAD: ~a -> ~a" spec final-spec)
         (parse-type-specifier final-spec))))

   ;; Standard symbol: e.g. 'int'
   ((and (symbolp spec) (valid-type-p spec)) spec)

   ;; Storage Handle Symbols (e.g. CELL, VECTOR...)
   ((and (symbolp spec) (member (symbol-name spec) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Promoting symbol ~a to list (~a)" spec spec)
     (parse-type-specifier (list spec)))

   ;; Function Type: #'(int => int) — raw (function ...) form from reader
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                    (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (let ((canonical (expand-storage-handle-type-specifier spec)))
       (cond
         ;; Incomplete: any positional slot is nil (e.g. (cell elem nil) or
         ;; (tensor elem N nil nil ct)).  Don't mangle — return as a list
         ;; so downstream incomplete-type-p / implicit-template detection
         ;; can recognize it as polymorphic.
         ((and (listp canonical) (some #'null (rest canonical)))
          canonical)
         ((valid-type-p canonical)
           (let ((base (first canonical))
                    (params (rest canonical)))
             (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params))))
         (t (error 'crisp-unknown-type-error :type-name spec)))))

   ;; Function Type/Literal (already parsed to :function-type or :function-literal)
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (let* ((base (first spec))
               (raw-params (rest spec))
               (arity (get-template-arity base))
               (params (if (and arity (> (length raw-params) arity))
                           (extract-positional-from-keyword-args raw-params arity)
                           raw-params)))
       (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))

;; src/analysis/ops.lisp -- registers the endeavour 203 analyzers, after the 185 entries
(defun %185-register-math-op-analyzers ()
  "Registers analyze-185-math-op under every *185-math-op-names* name, in both :crisp-language
   and :crisp.compiler.  Called from register-ops-analyzers."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (name *185-math-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-math-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-math-op))
    ;; P2: the integer bit operations
    (dolist (name *185-bit-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-bit-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-bit-op)))
  (%register-accum-analyzers))

;; src/autodiff.lisp -- +! -! widen differentiate as + - identity; to-sat has no gradient, like round
(defun %185-math-backward (v expr emit-fn local-adj-fn)
  "Backward rules for the endeavour-185 P1 ops, matched by NAME.  Returns T when EXPR is one of
   them (the clause handled it), else NIL."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x))
         (sym (n) (%185-crisp-sym n)))
    (let ((op (car expr)))
      (cond
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
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))
           t))
        ;; P2 + P0: integer results carry no gradient -- the bit operations, and floor / ceil /
        ;; round (float -> int rounding is piecewise constant: derivative 0 almost everywhere).
        ((some (lambda (n) (%185-op-named-p op n))
               '("ASH" "LOGAND" "LOGIOR" "LOGXOR" "LOGNOT" "POPCOUNT" "FLOOR" "CEIL" "ROUND" "TO-SAT"))
         t)
        (t nil)))))

;;; ===================================================================
;;; Endeavour 204: integer MMA.
;;; ===================================================================

;; src/mma.lisp
(defun %elem-prim-name (elem)
  "The name of ELEM's underlying primitive, as a string, for a Crisp element type that may be derived.
   Compared by NAME because CHAR and friends are shadowed differently across the packages."
  (and elem (symbolp elem) (symbol-name (get-type-base (resolve-type-alias elem)))))

;; src/mma.lisp
(defun %elem-integer-p (elem)
  "T for an element type whose primitive is an integer the MMA hardware takes."
  (and (member (%elem-prim-name elem) '("CHAR" "UCHAR" "INT" "UINT") :test #'equal) t))

;; src/mma.lisp
(defun %elem-signed-p (elem)
  "T for an element type whose primitive is a signed integer."
  (and (member (%elem-prim-name elem) '("CHAR" "INT") :test #'equal) t))

;; src/mma.lisp -- integers no longer fall through to FLOAT.  That fallback is what made an int8
;; kernel emit float cooperative matrices and die in llvm-spirv with no Crisp diagnostic.
(defun %elem-coop-type (elem)
  "The SPIR-V cooperative-matrix component type for a Crisp element type.

   Returns the Crisp type symbol to embed in a `(coop-matrix <T> rows cols use)` semantic type.
   Anything unrecognised falls back to FLOAT — the pre-155 behaviour — so an element type this
   function has not been taught about degrades to what the compiler did before rather than
   erroring in a code path that has nothing to do with the user's mistake.  Shape/type agreement
   is validated separately (see the typed :mma-shapes work); this is a lowering detail."
  (if (%elem-integer-p elem)
      (get-type-base (resolve-type-alias elem))
      (case elem
        ((bfloat16) 'bfloat16)
        ((half)     'half)
        ((float)    'float)
        ((double)   'double)
        (t          'float))))

;; src/mma.lisp
(defun %elem-bytes (elem)
  "Bytes per element for a Crisp element type, for the Intel GRF register model.

   This is the number that used to be a hardcoded 4 in %spv-kernel-register-demand.  It is only
   correct to consult it now that the element type actually reaches codegen -- before endeavour
   155 every fragment was float32 regardless of what the source asked for, so 4 was the truth
   about the emitted code even when it was a lie about the source."
  (let ((name (%elem-prim-name elem)))
    (cond ((member name '("CHAR" "UCHAR") :test #'equal) 1)
          ((member name '("BFLOAT16" "HALF") :test #'equal) 2)
          ((equal name "DOUBLE") 8)
          (t 4))))

;; src/mma.lisp -- CHAR / UCHAR, and a derived element resolves to its primitive
(defun %mma-elem-bits (elem)
  "Bit width of a Crisp MMA element type, or NIL if unknown."
  (let ((n (%elem-prim-name elem)))
    (and n
         (cond ((string= n "HALF")     16)
               ((string= n "BFLOAT16") 16)
               ((string= n "FLOAT")    32)
               ((string= n "DOUBLE")   64)
               ((string= n "INT8")      8)
               ((string= n "UINT8")     8)
               ((string= n "CHAR")      8)
               ((string= n "UCHAR")     8)
               ((string= n "INT")      32)
               ((string= n "UINT")     32)
               (t nil)))))

;; src/mma.lisp -- the node carries C's own coop type, so an integer accumulator stays integer
(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop matrix on
   :spirv, else the SAME RECORD AS C.  Codegen forks in generate-node-ir.

   Endeavour 165 (step 3): the NVIDIA type was hardcoded to the fp32 record, which made an fp64
   accumulate mistype itself.  Deriving it from C states the real rule and covers any accumulator
   record, present or future.  The fallback keeps the historical answer when C's type cannot be
   resolved to an accumulator record.

   Endeavour 204: on :spirv too, C's type is the answer when it is a coop matrix."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (let* ((c-node (analyze-expression c-arg env context location))
           (c-type (get-single-value-type c-node)))
      (make-semantic-mma-accumulate
       :type (if (eq *target-backend* :spirv)
                 (if (and (consp c-type) (eq (first c-type) 'coop-matrix))
                     c-type
                     (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                       (declare (ignore sk)) (list 'coop-matrix 'float sm sn 2)))
                 (if (and c-type (symbolp c-type)
                          (search "REGISTER-FRAGMENT-ACC-" (symbol-name c-type)))
                     c-type
                     'register-fragment-acc-f32-16x8))
       :c-node c-node
       :a-node (analyze-expression a-arg env context location)
       :b-node (analyze-expression b-arg env context location)
       :source-location location))))

;; src/codegen.lisp
(defvar *coop-mma-signs* 0
  "The signedness bits of the MulAdd operands mask for the multiply being emitted: A 1, B 2, C 4,
   Result 8.  LLVM integer types carry no sign, so the Crisp types have to supply them.")

;; src/codegen.lisp
(defun %coop-sign-mask (a-node b-node c-node)
  "The MatrixA/B/C/ResultSignedComponentsKHR bits for this multiply, from the operands' Crisp types."
  (flet ((signed-p (node)
           (let ((ty (semantic-node-type node)))
             (and (consp ty) (eq (first ty) 'coop-matrix) (%elem-signed-p (second ty))))))
    (let ((mask (logior (if (signed-p a-node) 1 0)
                        (if (signed-p b-node) 2 0)
                        (if (signed-p c-node) 12 0))))
      (log:debug "%coop-sign-mask: ~a" mask)
      mask)))

;; src/mma.lisp -- binds the sign bits around the SPIR-V multiply
(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type; swizzle/k from table).
   Endeavour 198: the table entry's 4th element (B-MAJOR) reaches %emit-nvvm-wgmma."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (progn
            ;; Endeavor 140 (precision): wgmma is tf32 by construction, so under a non-fast
            ;; precision context the requested IEEE accuracy is silently NOT honored (results are
            ;; tf32).  Warn.  *math-precision* here is the resolved effective precision at codegen
            ;; — it already respects the full chain (force > with-precision > declaim > flag >
            ;; default(:ieee)), the same value that stamps the fast-math flags in codegen.lisp.
            ;; Endeavour 160: the tf32 precision warning is only true for a 32-bit operand.
            ;; A bf16/fp16 wgmma is not silently downgrading anything -- the kernel ASKED for
            ;; 16-bit inputs -- so firing it there would be noise that teaches the reader
            ;; something untrue.
            (unless (or (eq *math-precision* :fast)
                        (eql (%mma-elem-bits (third (gethash node *wgmma-node-swizzle*))) 16))
              (format *error-output*
                      "WARNING: wgmma-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                      *math-precision*))
          (destructuring-bind (&optional swizzle-mode (k 8) elem (b-major :k)) (gethash node *wgmma-node-swizzle*)
            (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                  (swizzle-p (and swizzle-mode (string-equal (string swizzle-mode) "128B"))))
              (multiple-value-bind (av al a-ptr) (gen (semantic-mma-accumulate-a-node node))
                (declare (ignore av al))
                (multiple-value-bind (bv bl b-ptr) (gen (semantic-mma-accumulate-b-node node))
                  (declare (ignore bv bl))
                  (unless (and a-ptr b-ptr)
                    (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                  (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                    (second (gethash acc-type *wgmma-acc-dims*)) swizzle-p k elem b-major))))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (let ((*coop-mma-signs* (%coop-sign-mask (semantic-mma-accumulate-a-node node) (semantic-mma-accumulate-b-node node) (semantic-mma-accumulate-c-node node))))
                    (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil)))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;; src/codegen.lisp -- the operands mask carries the sign bits for integer matrices
(defmethod %coop-mma-impl ((lowering (eql :coop-matrix)) builder module a-val b-val c-val elem-llvm m n k)
  (declare (ignorable lowering))
  "Emit CooperativeMatrixMulAddKHR(A, B, C, <operands>) -> the MxN accumulator coop matrix.

   Operand types come from the ACTUAL VALUES via LLVMTypeOf, so the declaration cannot drift from
   what is passed (Endeavour 155, Phase 1).

   THE OPERANDS MASK.  0 for f32/tf32 and for fp16, whose component type already says what it is.
   0x40 (MatrixAAndBBFloat16ComponentsINTEL) when A and B are 16-bit INTEGER matrices, which is
   how Intel represents bf16 — an integer type cannot say 'bfloat' on its own, so the bit says it.

   DETECTION READS THE TYPE, IT DOES NOT REBUILD IT.  The first attempt compared A against a
   freshly constructed (%coop-type i16 m k 0), which failed for a reason worth recording: this
   function's M/N/K come from a caller that computes them with an UNTYPED (%spv-mma-shape) —
   src/mma.lisp:653 — so K is the tf32 8 even when the operands are 16-bit and K is really 16.
   Those arguments are otherwise unused here (the types come from the values), so the wrong shape
   is harmless to codegen and was harmless to fp16; it only defeated a check that trusted it.
   Printing the type and reading its component is exact and depends on nothing else."
  (declare (ignorable elem-llvm m n k))
  (let* ((a-ty (crisp.llvm-bindings::llvm-type-of a-val))
         (b-ty (crisp.llvm-bindings::llvm-type-of b-val))
         (c-ty (crisp.llvm-bindings::llvm-type-of c-val))
         (i32  (crisp.llvm-bindings::llvm-int32-type))
         (a-str (crisp.llvm-bindings::llvm-print-type-to-string a-ty))
         (bf16-p (and (eq *target-backend* :spirv)
                      a-str
                      (search ", i16," a-str)))
         (operands (logior (if bf16-p #x40 0) *coop-mma-signs*)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 operands nil)))))

;; src/codegen.lisp -- integers no longer fall through to float
(defun %coop-op-elem-llvm (node)
  "The LLVM type for a coop-op node's component type (see %coop-node-elem).

   Endeavour 155: BFLOAT16 lowers to a 16-BIT INTEGER, not to LLVM `bfloat`.  That is how Intel
   encodes a bf16 cooperative matrix (see header) — the type carries no float-ness and the MulAdd
   operands mask supplies it.  i16 is also the correct width for the tile ADDRESS arithmetic, so
   one answer serves both uses.

   Endeavour 204: CHAR / UCHAR are i8 and INT / UINT are i32; the sign is the operands mask's job."
  (let* ((e (%coop-node-elem node))
         (prim (%elem-prim-name e)))
    (cond ((member prim '("CHAR" "UCHAR") :test #'equal) (llvm-int8-type))
          ((member prim '("INT" "UINT") :test #'equal)   (llvm-int32-type))
          ((string= (symbol-name e) "HALF")     (llvm-half-type))
          ((string= (symbol-name e) "BFLOAT16") (crisp.llvm-bindings::llvm-int16-type))
          ((string= (symbol-name e) "DOUBLE")   (llvm-double-type))
          (t                                    (llvm-float-type)))))

;; src/mma.lisp
(defun %canonical-elem (elem)
  "ELEM with a type accessor such as (accum q-a) resolved to the type it names."
  (if (%type-accessor-form-p elem) (resolve-type-accessor elem) elem))

;; src/mma.lisp -- an element may be an accessor form
(defun %elem-prim-name (elem)
  "The name of ELEM's underlying primitive, as a string, for a Crisp element type that may be derived
   or an (accum T) form.  Compared by NAME because CHAR and friends are shadowed differently across
   the packages."
  (let ((e (%canonical-elem elem)))
    (and e (symbolp e) (symbol-name (get-type-base (resolve-type-alias e))))))

;; src/mma.lisp -- an element may be an accessor form
(defun %register-tile-type-name (m n &optional (elem 'float))
  "The minted record name for an M x N register tile of element type ELEM.

   Endeavour 165 (step 2a): the name now carries the ELEMENT TYPE.  It used to be
   REGISTER-TILE-ACC-F32-MxN unconditionally, which was a lie the moment a double tile existed
   and -- worse -- a COLLISION: two tiles with the same dims and different element types would
   have shared one record.  That is not hypothetical; it is exactly BUG 055, where %coop-call
   caches the coop-matrix declaration by name alone and two element types in one module silently
   collide.  One instance of that bug is enough.

   ELEM defaults to FLOAT so any caller not yet threading it keeps the pre-165 record."
  (intern (format nil "REGISTER-TILE-ACC-~a-~dX~d" (symbol-name (%canonical-elem elem)) m n)
          (find-package :crisp.compiler)))

;; src/mma.lisp -- an element may be an accessor form
(defun %elem-coop-type (elem)
  "The SPIR-V cooperative-matrix component type for a Crisp element type.

   Returns the Crisp type symbol to embed in a `(coop-matrix <T> rows cols use)` semantic type.
   Anything unrecognised falls back to FLOAT — the pre-155 behaviour — so an element type this
   function has not been taught about degrades to what the compiler did before rather than
   erroring in a code path that has nothing to do with the user's mistake.  Shape/type agreement
   is validated separately (see the typed :mma-shapes work); this is a lowering detail."
  (if (%elem-integer-p elem)
      (get-type-base (resolve-type-alias (%canonical-elem elem)))
      (case elem
        ((bfloat16) 'bfloat16)
        ((half)     'half)
        ((float)    'float)
        ((double)   'double)
        (t          'float))))

;;; -------------------------------------------------------------------
;;; Endeavour 204, PTX: integer wgmma.
;;; ptxas 12.4 facts, each probed at sm_90a: int8 wgmma exists at every N, only at K=32, takes D = N/2
;;; registers and ONE trailing immediate.  Signed and unsigned pairs assemble at PTX .version 8.0; a
;;; mixed pair needs .version 8.4.
;;; -------------------------------------------------------------------

;; src/mma.lisp
(defun %int-operand-p (elem)
  "T for an element type an integer MMA can take as an A or B operand: 8-bit."
  (eql (%mma-elem-bits elem) 8))

;; src/mma.lisp
(defun %check-mma-element-family (a b c location)
  "Refuses an MMA whose operands and accumulator do not belong together, where the failure used to
   surface as `Expected FLOAT but inferred INT` or as a llvm-spirv exit code.  No hardware mixes the
   two families, and no emulation is offered."
  (let ((a-int (%elem-integer-p a)) (b-int (%elem-integer-p b)) (c-int (%elem-integer-p c)))
    (when (or a-int b-int c-int)
      (unless (and a-int b-int c-int)
        (error 'crisp-compiler-error
               :message (format nil "MMA: integer and float do not mix: A is ~(~a~), B is ~(~a~), the accumulator is ~(~a~).  An integer MMA needs 8-bit operands and an integer accumulator."
                                a b c)
               :source-location location))
      (unless (and (%int-operand-p a) (%int-operand-p b))
        (error 'crisp-compiler-error
               :message (format nil "MMA: integer operands must be 8-bit (char or uchar); A is ~(~a~), B is ~(~a~)." a b)
               :source-location location))
      (unless (eql (%mma-elem-bits c) 32)
        (error 'crisp-compiler-error
               :message (format nil "MMA: an integer accumulator must be 32-bit; got ~(~a~)." c)
               :source-location location))
      (when (and (or (%elem-signed-p a) (%elem-signed-p b)) (not (%elem-signed-p c)))
        (error 'crisp-compiler-error
               :message (format nil "MMA: accumulator ~(~a~) must be signed: a product involving a signed operand can be negative." c)
               :source-location location)))))

;; src/mma.lisp -- SPIR-V checks the element family too
(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop matrix on
   :spirv, else the SAME RECORD AS C.  Codegen forks in generate-node-ir.

   Endeavour 165 (step 3): the NVIDIA type was hardcoded to the fp32 record, which made an fp64
   accumulate mistype itself.  Deriving it from C states the real rule and covers any accumulator
   record, present or future.  The fallback keeps the historical answer when C's type cannot be
   resolved to an accumulator record.

   Endeavour 204: on :spirv too, C's type is the answer when it is a coop matrix, and the three
   element types are checked against each other."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (let* ((c-node (analyze-expression c-arg env context location))
           (c-type (get-single-value-type c-node))
           (a-node (analyze-expression a-arg env context location))
           (b-node (analyze-expression b-arg env context location)))
      (flet ((coop-p (ty) (and (consp ty) (eq (first ty) 'coop-matrix))))
        (when (and (coop-p c-type) (coop-p (semantic-node-type a-node)) (coop-p (semantic-node-type b-node)))
          (%check-mma-element-family (second (semantic-node-type a-node)) (second (semantic-node-type b-node))
                                     (second c-type) location))
        (make-semantic-mma-accumulate
         :type (if (eq *target-backend* :spirv)
                   (if (coop-p c-type)
                       c-type
                       (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                         (declare (ignore sk)) (list 'coop-matrix 'float sm sn 2)))
                   (if (and c-type (symbolp c-type)
                            (search "REGISTER-FRAGMENT-ACC-" (symbol-name c-type)))
                       c-type
                       'register-fragment-acc-f32-16x8))
         :c-node c-node
         :a-node a-node
         :b-node b-node
         :source-location location)))))

;; src/mma.lisp -- sync MMA has no integer lowering here; say so where it is asked for
(defun %frag-record-for-acc (elem)
  "The ACCUMULATOR fragment record for element type ELEM.

   Endeavour 165 (2b-ii).  Sibling of %frag-record-for-operand, which has dispatched A and B
   records by element type since endeavour 159; the accumulator was the one role still naming
   register-fragment-acc-f32-16x8 outright at five sites.  One place decides this, so the tile
   minter and the fragment constructor cannot disagree about which record an element type maps
   to -- the same argument 159 made for the operands.

   A 16-bit MMA accumulates in fp32, so half/bfloat16 keep the f32 record on purpose.

   Endeavour 204: integer register tiles exist on SPIR-V only.  On NVIDIA, integer MMA is wgmma."
  (when (and (%elem-integer-p elem) (not (eq *target-backend* :spirv)))
    (error 'crisp-compiler-error
           :message (format nil "A ~(~a~) register tile has no NVIDIA lowering: integer MMA there is wgmma.  Use make-wgmma-accumulator with wgmma-accumulate-via-tile."
                            (%canonical-elem elem))))
  (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
      'register-fragment-acc-f64-8x8
      'register-fragment-acc-f32-16x8))

;; src/mma.lisp
(defvar *wgmma-node-b-elem* (make-hash-table :test 'eq)
  "semantic-mma-accumulate node -> B's element type, for the mnemonic of a mixed-sign wgmma.")

;; src/mma.lisp
(defvar *wgmma-b-elem* nil
  "B's element type for the wgmma being emitted, bound around %emit-nvvm-wgmma.")

;; src/mma.lisp
(defun %wgmma-acc-type-name (n &optional (elem 'float))
  "The minted accumulator record name.  Every float accumulator shares the F32 record, as before."
  (let ((e (%canonical-elem elem)))
    (intern (if (%elem-integer-p e)
                (format nil "WGMMA-ACC-~a-64X~d" (symbol-name e) n)
                (format nil "WGMMA-ACC-F32-64X~d" n))
            (find-package :crisp.compiler))))

;; src/mma.lisp
(defun %ensure-wgmma-acc-type (n &optional (elem 'float))
  "Mint (once) the wgmma accumulator record -- N/2 flat fields, one per register per thread across the
   128-thread warpgroup.  Fields are float, or ELEM for an integer accumulator, so a store of a field
   type-checks against the destination's own element type.  Returns the type symbol."
  (let* ((e (%canonical-elem elem))
         (int-p (%elem-integer-p e))
         (name (%wgmma-acc-type-name n e)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below (floor n 2)
             collect (list (intern (format nil "D~d" i) (find-package :crisp.compiler))
                           (if int-p e 'float)))
       :record))
    (setf (gethash name *wgmma-acc-dims*) (list 64 n 8 (and int-p e)))
    name))

;; src/mma.lisp
(defun %wgmma-acc-elem (acc-type)
  "The integer element of a wgmma accumulator type, or FLOAT."
  (or (fourth (gethash acc-type *wgmma-acc-dims*)) 'float))

;; src/mma.lisp
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 fields, each
   initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 occupancy report — keyed by SHAPE so a per-tile `(set! D (make-wgmma-accumulator ...))`
   re-initialization is not counted as a second accumulator.

   Endeavour 204: T selects an integer accumulator; any other T is fp32, as before."
  (destructuring-bind (elem dims init) (cdr expr)
    (destructuring-bind (m n) dims
      (if (%elem-integer-p elem)
          (%check-wgmma-shape (list m n 32) location nil 'char)
          (%check-wgmma-shape (list m n 8) location))
      (%wgmma-acc-fit-check m n location)
      (%ptx-note-register-demand-keyed (floor n 2) context (list :wgmma-acc m n))
      (let ((type-name (%ensure-wgmma-acc-type n elem)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))

;; src/mma.lisp
(defun %wgmma-k-per-slice (elem)
  "K covered by ONE wgmma instruction at element type ELEM: 8 at 32 bits, 16 at 16 bits, 32 at 8 bits.
   All are 32 BYTES of K per slice, which is why the descriptor's kk*32 advance is unchanged."
  (case (%mma-elem-bits elem)
    (8  32)
    (16 16)
    (t  8)))

;; src/mma.lisp
(defun %wgmma-operand-mnemonic (elem)
  "The <d>.<a>.<b> tail of the wgmma mnemonic for operand element type ELEM.  An integer multiply
   names A and B separately, because their signs are independent."
  (flet ((sign (e) (if (%elem-signed-p e) "s8" "u8")))
    (let ((n (and elem (symbolp elem) (symbol-name elem))))
      (cond ((%int-operand-p elem) (format nil "s32.~a.~a" (sign elem) (sign (or *wgmma-b-elem* elem))))
            ((and n (string= n "BFLOAT16")) "f32.bf16.bf16")
            ((and n (string= n "HALF"))     "f32.f16.f16")
            (t                              "f32.tf32.tf32")))))

;; src/mma.lisp
(defun %wgmma-asm-string (nacc n &optional elem)
  "wgmma.mma_async.sync.aligned.m64n{N}k{KPS}.<d>.<a>.<b> {$0..$nacc-1}, descA, descB, ...;
   Accumulator is an OUTPUT plus a tied INPUT, so the two 'l' descriptors are $2*nacc and
   $2*nacc+1.  tf32 takes three trailing immediates; the 16-bit forms take five, adding
   transA/transB from *wgmma-16-trans* while that pair is under investigation.  int8 takes one."
  (let* ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i)))
         (kps  (%wgmma-k-per-slice elem))
         (tail (case kps
                 (32 "1")
                 (16 (format nil "1, 1, 1, ~d, ~d" (first *wgmma-16-trans*) (second *wgmma-16-trans*)))
                 (t  "1, 1, 1"))))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk~d.~a {~a}, $~d, $~d, ~a;"
            n kps (%wgmma-operand-mnemonic elem) accs (* 2 nacc) (1+ (* 2 nacc)) tail)))

;; src/mma.lisp
(defun %wgmma-constraints (nacc &optional int-p)
  "NACC '=f' outputs ('=r' for an integer accumulator), NACC tied inputs (0..nacc-1), 2 'l' descriptor
   inputs, memory clobber."
  (let ((outs (loop for i below nacc collect (if int-p "=r" "=f")))
        (ties (loop for i below nacc collect (format nil "~d" i))))
    (format nil "~{~a~^,~},~{~a~^,~},l,l,~~{memory}" outs ties)))

;; src/mma.lisp
(defun %wgmma-struct-of-regs (module reg-ty nacc)
  "The LLVM struct type { REG-TY x NACC } — the wgmma inline-asm result (NACC = N/2 accumulators)."
  (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count nacc)))
    (dotimes (i nacc) (setf (cffi:mem-aref elts 'llvm-type-ref i) reg-ty))
    (llvm-struct-type-in-context (llvm-get-module-context module) elts nacc nil)))

;; src/mma.lisp -- the register type follows the accumulator
(defun %emit-wgmma-mma-only (builder module d-val a-ptr b-ptr acc-type n swizzle-p kslice-off
                             &optional elem b-mn-lbo)
  "Emit ONE m64nNk{8,16,32} wgmma.mma_async and nothing else -- no fence, no commit_group, no
   wait_group.  Those are GROUP-level operations and belong once around the whole k-slice
   sequence, not once per slice; see %emit-nvvm-wgmma.

   N/2 accumulators in and out, two shared-memory descriptors, and KSLICE-OFF (kk*32 bytes)
   advancing the descriptor start address.  ELEM selects the mnemonic; the 32-byte slice stride is
   the same at every width, which is why the descriptor build is untouched.  Returns the new D.

   Endeavour 198: B-MN-LBO non-NIL means B is MN-major: its descriptor is %198-wgmma-make-desc-mn
   (LBO = B-MN-LBO bytes), its slice advances 16 rows of 128 bytes (kk*2048 = KSLICE-OFF*64), and
   the instruction carries transB=1 (*wgmma-16-trans* bound to (0 1))."
  (declare (ignorable module))
  (let* ((int-p (%elem-integer-p (%wgmma-acc-elem acc-type)))
         (reg-ty (if int-p (llvm-int32-type) (llvm-float-type)))
         (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr swizzle-p kslice-off))
         (descB (if b-mn-lbo
                    (%198-wgmma-make-desc-mn builder b-ptr (* kslice-off 64) b-mn-lbo)
                    (%wgmma-make-desc builder b-ptr swizzle-p kslice-off)))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i))))
         (asm-str     (let ((*wgmma-16-trans* (if b-mn-lbo (list (first *wgmma-16-trans*) 1) *wgmma-16-trans*)))
                        (%wgmma-asm-string nacc n elem)))
         (constraints (%wgmma-constraints nacc int-p))
         (ret-ty      (%wgmma-struct-of-regs module reg-ty nacc))
         (ptypes      (append (loop repeat nacc collect reg-ty) (list i64 i64)))
         (args        (append c-ops (list descA descB)))
         (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints))
         (agg         (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
    (dotimes (i nacc)
      (setf agg (llvm-build-insert-value builder agg
                                         (llvm-build-extract-value builder call i (format nil "wo~d" i))
                                         i (format nil "wr~d" i))))
    agg))

;; src/mma.lisp -- records B element, and checks the element family
(defun analyze-wgmma-accumulate-base (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K]).  a/b -> (~ tile 0 [0]) with one 0 per tile dimension
   (rank-aware) so codegen's 3rd value is the addrspace(3) base — works for flat VECTOR tiles (scatter)
   AND MATRIX tiles (swizzle / Step-0 forms), independent of :swizzle.

   Endeavour 160: the per-node *wgmma-node-swizzle* entry gains a third element, the operand
   element type.  Codegen cannot recover it -- %emit-nvvm-wgmma receives an f32 accumulator type
   and raw SMEM pointers, with no fragment record to probe -- so it has to be recorded here.

   Endeavour 198: analyze-wgmma-accumulate (below) records :b-major in *wgmma-node-swizzle*."
  (destructuring-bind (d a b &rest kwargs) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node))
           (swz    (getf kwargs :swizzle))
           (a-node (analyze-expression a env context (append location '(2))))
           (a-rank (or (%get-tensor-arity (semantic-node-type a-node)) 1))
           (elem   (%coop-elem-of a-node))
           (b-rank (or (%get-tensor-arity
                        (semantic-node-type (analyze-expression b env context (append location '(3))))) 1))
           (aref-a (if (>= a-rank 2) `(~ ,a 0 0) `(~ ,a 0)))
           (aref-b (if (>= b-rank 2) `(~ ,b 0 0) `(~ ,b 0))))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (let ((node (make-semantic-mma-accumulate
                   :type d-type
                   :c-node d-node
                   :a-node (analyze-expression aref-a env context (append location '(2)))
                   :b-node (analyze-expression aref-b env context (append location '(3)))
                   :source-location location)))
        (let ((b-elem (%coop-elem-of (analyze-expression b env context (append location (quote (3)))))))
          (%check-mma-element-family elem b-elem (%wgmma-acc-elem d-type) location)
          (setf (gethash node *wgmma-node-b-elem*) b-elem))
        (setf (gethash node *wgmma-node-swizzle*)
              (list swz (or (getf kwargs :k) (%wgmma-k-per-slice elem)) elem))
        node))))

;; src/mma.lisp -- names int8 in its message
(defun %check-wgmma-shape-against-isa (shape location swizzle elem)
  "CAUSE TWO: nothing declares warpgroup shapes, so the sm_90a instruction constraints apply.

   THE THREE MESSAGES ARE DELIBERATELY UNCHANGED at their front.  tests/spec/140-wgmma/errors/
   01, 02 and 03 assert the substrings 'M must be 64', 'multiple of 8' and 'K'; those specs
   predate hardware profiles and none of them declares one, so this is the branch they take.
   The trailing sentence naming the fallback is ADDITIVE, which a substring match tolerates."
  (destructuring-bind (m n k) shape
    (unless (= m 64)
      (error 'crisp-compiler-error
             :message (format nil "wgmma: M must be 64 (wgmma is always m64), got ~a.  No active hardware profile declares :wgmma-shapes, so the sm_90a instruction constraints apply." m)
             :source-location location))
    (unless (and (>= n 8) (<= n 256) (zerop (mod n 8)))
      (error 'crisp-compiler-error
             :message (format nil "wgmma: N must be a multiple of 8 in [8,256], got ~a.  No active hardware profile declares :wgmma-shapes, so the sm_90a instruction constraints apply." n)
             :source-location location))
    (let* ((kps (%wgmma-k-per-slice elem))
           (what (case kps (32 "int8 m64nNk32") (16 "16-bit m64nNk16") (t "tf32 m64nNk8"))))
      (if swizzle
          (unless (and (plusp k) (zerop (mod k kps)))
            (error 'crisp-compiler-error
                   :message (format nil "wgmma: with :swizzle, K (the K-block) must be a positive multiple of ~a for ~a operands, got ~a." kps what k)
                   :source-location location))
          (unless (= k kps)
            (error 'crisp-compiler-error
                   :message (format nil "wgmma: K must be ~a (~a, a single k~a slice); use :swizzle :128b for a multi-slice K-block, got ~a." kps what kps k)
                   :source-location location))))))

;; src/mma.lisp -- no tf32 warning for int8, and B element bound for the mnemonic; sign bits as before
(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type; swizzle/k from table).
   Endeavour 198: the table entry's 4th element (B-MAJOR) reaches %emit-nvvm-wgmma."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (progn
            ;; Endeavor 140 (precision): wgmma is tf32 by construction, so under a non-fast
            ;; precision context the requested IEEE accuracy is silently NOT honored (results are
            ;; tf32).  Warn.  *math-precision* here is the resolved effective precision at codegen
            ;; — it already respects the full chain (force > with-precision > declaim > flag >
            ;; default(:ieee)), the same value that stamps the fast-math flags in codegen.lisp.
            ;; Endeavour 160: the tf32 precision warning is only true for a 32-bit operand.
            ;; A bf16/fp16 wgmma is not silently downgrading anything -- the kernel ASKED for
            ;; 16-bit inputs -- so firing it there would be noise that teaches the reader
            ;; something untrue.
            (unless (or (eq *math-precision* :fast)
                        (member (%mma-elem-bits (third (gethash node *wgmma-node-swizzle*))) (quote (8 16))))
              (format *error-output*
                      "WARNING: wgmma-accumulate-via-tile uses tf32 tensor cores, but math-precision is '~(~a~)' — the IEEE accuracy request is not honored (results are tf32). Use (with-precision (fast) ...), (declaim (precision fast)), or --math-precision=fast.~%"
                      *math-precision*))
          (destructuring-bind (&optional swizzle-mode (k 8) elem (b-major :k)) (gethash node *wgmma-node-swizzle*)
            (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                  (swizzle-p (and swizzle-mode (string-equal (string swizzle-mode) "128B"))))
              (multiple-value-bind (av al a-ptr) (gen (semantic-mma-accumulate-a-node node))
                (declare (ignore av al))
                (multiple-value-bind (bv bl b-ptr) (gen (semantic-mma-accumulate-b-node node))
                  (declare (ignore bv bl))
                  (unless (and a-ptr b-ptr)
                    (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                  (let ((*wgmma-b-elem* (gethash node *wgmma-node-b-elem*))) (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                    (second (gethash acc-type *wgmma-acc-dims*)) swizzle-p k elem b-major)))))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (let ((*coop-mma-signs* (%coop-sign-mask (semantic-mma-accumulate-a-node node) (semantic-mma-accumulate-b-node node) (semantic-mma-accumulate-c-node node))))
                    (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil)))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;; src/compiler.lisp
(defun %ll-needs-ptx84-p (ll-file)
  "T when LL-FILE holds a mixed-sign wgmma, which ptxas accepts only at PTX ISA 8.4.  Read from the
   emitted IR so that every other module keeps llc's default version."
  (let ((text (alexandria:read-file-into-string ll-file)))
    (and (or (search ".s32.s8.u8" text) (search ".s32.u8.s8" text)) t)))

;; src/compiler.lisp -- a mixed-sign wgmma needs PTX 8.4; every other module keeps the llc default
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
          (list (namestring llc-input)
                "-o" (namestring ptx-file)))
         :log-prefix "[PTX] ")))

    ;; Cleanup temp files
    (when (probe-file ll-file)     (delete-file ll-file))
    (when (probe-file ll-opt-file) (delete-file ll-opt-file))

    (log:info "Generated PTX: ~a" ptx-file)))

;; src/analysis/control.lisp -- a TMA copy is byte-level, so 8-bit elements fit
(defun %analyze-nvvm-tma-load-tile-at-base (expr env context location)
  "Endeavor 137 (Chapter 1.5, Phase 2) — analyze (load-tile-at SRC TILE (ORIGIN...) :barrier BAR)
   for a NVIDIA :block barrier into a semantic-nvvm-tma-tile-copy.  Codegen emits one bulk
   cp.async.bulk.tensor copy issued by an elected leader, tracked by BAR's mbarrier.  We build
   the dest/source as aref-at-base forms so codegen can reuse the aref element-address machinery
   for the SLM tile base (addrspace 3) and the source tensor base (addrspace 1, the STAND-IN
   tensormap pointer).  The ORIGIN coords become the TMA {x,y} tile-box operands (element units).

   Endeavour 159: 16-bit element types are accepted.  ELEM-BYTES feeds only the
   mbarrier.arrive.expect_tx byte count; the copy is descriptor-driven cp.async.bulk.tensor,
   whose tensormap encodes f16/bf16 directly.  See the header above for why the cp.async sibling
   site keeps its 4/8-byte restriction -- there it is a hardware limit, not a table omission."
  (let* ((src-form     (second expr))
         (tile-form    (third expr))
         (origin-list  (fourth expr))
         (key-args     (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil))
         (cl-pkg       (find-package :crisp-language))
         (aref-sym     (intern "~" cl-pkg))
         (length-sym   (intern "LENGTH~" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (rank         (length origin-list))
         (base-idx     (make-list rank :initial-element (list to-ulong-sym 0)))
         (dst-aref     (list* aref-sym tile-form base-idx))
         (src-aref     (list* aref-sym src-form base-idx))
         (dst-node     (analyze-expression dst-aref env context (append location '(1))))
         (src-node     (analyze-expression src-aref env context (append location '(2))))
         (coord-nodes  (loop for o in origin-list for i from 0
                             collect (analyze-expression o env context (append location (list 3 i)))))
         (barrier-node (analyze-expression barrier-form env context (append location '(4))))
         ;; tx byte count for mbarrier.arrive.expect_tx = (length~ TILE) * elem-bytes.
         (len-node     (analyze-expression (list length-sym tile-form) env context (append location '(5))))
         (elem-type    (semantic-node-type dst-node))
         (elem-bytes   (case (if (listp elem-type) (first elem-type) elem-type)
                         ((half bfloat16) 2)       ; Endeavour 159
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (if (eql (%mma-elem-bits (if (listp elem-type) (first elem-type) elem-type)) 8) 1 (error (quote crisp-compiler-error)
                              :message (format nil "load-tile :block: element type ~S needs 2, 4 or 8 bytes" elem-type)
                              :source-location location))))))
    ;; Endeavor 140 (warp-spec leader): tag the copy node when it is analyzed inside a
    ;; with-warp-specialization role block, so codegen elects laneid==0 of the producer warp
    ;; (not global tid==0) — making consumer-first warp specialization first-class and removing
    ;; the producer-first ordering constraint.
    (let ((node (make-semantic-nvvm-tma-tile-copy
                 :dst-aref-node dst-node
                 :src-aref-node src-node
                 :coord-nodes coord-nodes
                 :barrier-node barrier-node
                 :tile-length-node len-node
                 :elem-bytes elem-bytes
                 :src-name (and (symbolp src-form) src-form)
                 :type 'nil
                 :source-location location)))
      (when *in-warp-spec-block*
        (setf (gethash node *tma-copy-ws-leader*) t))
      node)))

;; src/metadata.lisp -- a tensor map names its element by primitive as well
(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared-signature plist for a kernel's metadata.
   Omits :access — storage handles are always treated as read-write by hoist code."
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Count implicit params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t)
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              (setf entry (append entry (list :type (strip-package-qualifiers (%host-visible-type type)))))
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              (when (%storage-handle-type-p type)
                (let* ((canonical (canonicalize-type-specifier type))
                       (base (if (consp canonical) (first canonical) canonical))
                       (is-cell   (and (symbolp base) (string-equal (symbol-name base) "CELL")))
                       (is-tensor (and (symbolp base) (string-equal (symbol-name base) "TENSOR")))
                       ;; CELL 3-tuple:   (cell elem ADDR)         — addr at index 2
                       ;; TENSOR 6-tuple: (tensor elem N ADDR aln ct) — addr at index 3
                       (as (if (and (consp canonical) is-cell (>= (length canonical) 3))
                               (nth 2 canonical)
                               (if (consp canonical)
                                   (let ((found (member :address-space canonical)))
                                     (if found (second found) :global))
                                   :global))))
                  (setf entry (append entry (list :address-space as)))
                  (when is-tensor
                    (let* ((n (if (integerp (third canonical))
                                  (third canonical)
                                  (parse-integer (symbol-name (third canonical)))))
                           ;; TENSOR 6-tuple: (tensor T N addr ALN ct) — aln at index 4
                           (alg (or (nth 4 canonical) :compact)))
                      (setf entry (append entry (list :rank n :align alg)))))))

              (setf entry (append entry (list :range (list start end))))
              ;; 179: a reduction output the host must set to the identity before every launch.
              (let ((launch-init (%reduction-launch-init-for (function-signature-name sig) name)))
                (when launch-init
                  (setf entry (append entry (list :launch-init launch-init)))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))

;; src/mma.lisp -- a derived accumulator's fields take a value of their own type
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 fields, each
   initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 occupancy report — keyed by SHAPE so a per-tile `(set! D (make-wgmma-accumulator ...))`
   re-initialization is not counted as a second accumulator.

   Endeavour 204: T selects an integer accumulator; any other T is fp32, as before."
  (destructuring-bind (elem dims init) (cdr expr)
    (destructuring-bind (m n) dims
      (let* ((int-p (%elem-integer-p elem))
             (field-init (if int-p
                             (list (intern "TO" (find-package :crisp-language)) (%canonical-elem elem) init)
                             init)))
        (if int-p
            (%check-wgmma-shape (list m n 32) location nil 'char)
            (%check-wgmma-shape (list m n 8) location))
        (%wgmma-acc-fit-check m n location)
        (%ptx-note-register-demand-keyed (floor n 2) context (list :wgmma-acc m n))
        (let ((type-name (%ensure-wgmma-acc-type n elem)))
          (analyze-expression
           `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect field-init))
           env context location))))))

;;; Unchanged copies, for the overlay build only: src/mma.lisp compiled these against the derived
;;; return type (member 8 16) of %wgmma-k-per-slice, and they would reject 32 at run time.
;;; Nothing to fold.  Folding %wgmma-k-per-slice into src makes them unnecessary.

(defun %check-wgmma-operands (shape a b location elem swizzle &optional (b-major :k))
  "Refuse a wgmma whose staged A or B tile is not the shape the instruction will read.

   THE RULE.  A is (M K) and B is (N K) -- both K-major.  This is not inferred from which
   kernels happen to verify; it is what CUTLASS declares for every tf32 GMMA trait in
   third_party/cutlass/include/cute/atom/mma_traits_sm90_gmma.hpp:
       FrgTypeA = FrgTypeB = GMMA::smem_desc<GMMA::Major::K>
       ALayout  = ABLayout<64, 8>      BLayout = ABLayout<64, 8>
   and the tf32 SS atoms exist ONLY in the _TN form (16 of them, no other suffix) because tf32
   wgmma carries no transpose immediate.

   ENDEAVOUR 198: at 16 bits B may instead be (K N) -- Major::MN, read with transB=1 -- when the
   kernel says so with :b-major :mn (B-MAJOR here).  A (K N) B without it is refused with a message
   naming the keyword; tf32 keeps refusing, because its wgmma has no transpose immediate.

   UNRESOLVABLE EXTENTS ARE NOT AN ERROR.  %mma-operand-extent returns NIL when a tile's shape is
   not compile-time known, and a wgmma operand is frequently (ring-get RING SLOT).  Refusing on
   NIL would reject the working pipelined kernels -- chapter 7, sec2_top, sec3, sec4 -- so an
   unknown extent skips silently, exactly as %mma-k-steps treats its own NIL.

   K IS THE PER-SLICE K, not the K-block: under :swizzle the staged tile spans several slices, so
   its K extent is the block and only A-vs-B agreement is checkable there."
  (destructuring-bind (m n k) shape
    (let ((a-r (%mma-operand-extent a nil :rows))
          (a-c (%mma-operand-extent a nil :cols))
          (b-r (%mma-operand-extent b nil :rows))
          (b-c (%mma-operand-extent b nil :cols)))
      ;; A must be (M K).  Under :swizzle the column extent is a K-block, so only M is fixed.
      (when (and a-r (/= a-r m))
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate-via-tile: A tile must be (M K) = (~a ~a) for shape ~a, but it is (~a ~a).  A is staged M-rows by K-columns, the same way mma-accumulate-via-tile stages it." m k shape a-r (or a-c '?))
               :source-location location))
      (when (and (not swizzle) a-c (/= a-c k))
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate-via-tile: A tile must be (M K) = (~a ~a) for shape ~a, but it is (~a ~a)." m k shape (or a-r '?) a-c)
               :source-location location))
      (if (eq b-major :mn)
          ;; Endeavour 198: B is (K N).  Its column extent is N; its row extent is the K-block.
          (progn
            (when (and b-c (/= b-c n))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile :b-major :mn: B tile must be (K N) = (~a ~a) for shape ~a, but it is (~a ~a)." k n shape (or b-r '?) b-c)
                     :source-location location))
            (when (and b-r (/= b-r k))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile :b-major :mn: B tile must be (K N) = (~a ~a) for shape ~a -- its K extent is the K-block -- but it is (~a ~a)." k n shape b-r (or b-c '?))
                     :source-location location)))
          (progn
            ;; B must be (N K).  This is where the two via-tile forms disagree, so say so.
            (when (and b-r (/= b-r n))
              (if (= (%wgmma-k-per-slice elem) 16)
                  (error 'crisp-compiler-error
                         :message (format nil "wgmma-accumulate-via-tile: B tile is (~a ~a), which is the Major::MN orientation.  The 16-bit wgmma reads that with transB=1: say so with :b-major :mn (it needs :swizzle :128b and N a multiple of 64), or declare B as (N K) = (~a ~a).  NOTE: mma-accumulate-via-tile takes B as (K N); the two via-tile forms differ here." b-r (or b-c '?) n k)
                         :source-location location)
                  (error 'crisp-compiler-error
                         :message (format nil "wgmma-accumulate-via-tile: B tile must be (N K) = (~a ~a) for shape ~a, but it is (~a ~a).  wgmma reads its SMEM B operand K-major (CUTLASS GMMA::Major::K) and tf32 wgmma has no transpose immediate, so (K N) is not a layout this instruction can read.  NOTE: mma-accumulate-via-tile takes B as (K N); the two via-tile forms differ here." n k shape b-r (or b-c '?))
                         :source-location location)))
            (when (and (not swizzle) b-c (/= b-c k))
              (error 'crisp-compiler-error
                     :message (format nil "wgmma-accumulate-via-tile: B tile must be (N K) = (~a ~a) for shape ~a, but it is (~a ~a)." n k shape (or b-r '?) b-c)
                     :source-location location)))))))

(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n &optional swizzle-p (k 8) elem (b-major :k))
  "Emit the wgmma accumulate as ONE GROUP: a fence before the first slice, K/KPS slices, then one
   commit_group + wait_group.  See the original for why the fence/commit/wait triple is emitted
   once per GROUP rather than once per slice (endeavour 154, worth 4-11%).

   Endeavour 160: KPS -- the K covered by one instruction -- is 8 at 32 bits and 16 at 16 bits.
   The per-slice BYTE advance stays kk*32 either way, because a tf32 k8 slice and a bf16 k16 slice
   occupy the same 32 bytes.  That is why %wgmma-make-desc is untouched by this endeavour.

   Endeavour 198: B-MAJOR :mn passes the MN-major B's LBO -- one TMA box, K rows x 128 bytes -- to
   every slice (see %emit-wgmma-mma-only)."
  (let* ((kps (%wgmma-k-per-slice elem))
         (n-slices (if swizzle-p (max 1 (floor k kps)) 1))
         (b-mn-lbo (and (eq b-major :mn) (* k 128))))
    (unless swizzle-p
      (%gen-nvvm-fence-proxy-async-shared builder)
      (%ptx-barrier builder module))
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let ((cur-d d-val))
      (dotimes (kk n-slices)
        (setf cur-d (%emit-wgmma-mma-only builder module cur-d a-ptr b-ptr acc-type n swizzle-p
                                          (* kk 32) elem b-mn-lbo)))
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      (values cur-d nil))))

(defun %wgmma-asm-string (nacc n &optional elem)
  "wgmma.mma_async.sync.aligned.m64n{N}k{KPS}.f32.<ab>.<ab> {$0..$nacc-1}, descA, descB, ...;
   Accumulator is an '=f' OUTPUT plus a tied INPUT, so the two 'l' descriptors are $2*nacc and
   $2*nacc+1.  tf32 takes three trailing immediates; the 16-bit forms take five, adding
   transA/transB from *wgmma-16-trans* while that pair is under investigation."
  (let* ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i)))
         (kps  (%wgmma-k-per-slice elem))
         (tail (if (= kps 16)
                   (format nil "1, 1, 1, ~d, ~d" (first *wgmma-16-trans*) (second *wgmma-16-trans*))
                   "1, 1, 1")))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk~d.~a {~a}, $~d, $~d, ~a;"
            n kps (%wgmma-operand-mnemonic elem) accs (* 2 nacc) (1+ (* 2 nacc)) tail)))

(defun analyze-wgmma-accumulate-via-tile (expr env context location)
  "(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b] [:b-major :k | :mn]) -> (set! D
   (wgmma-accumulate D A B :swizzle :128b :k K [:b-major :mn])).  K rule is swizzle- AND
   element-aware (see %check-wgmma-shape).

   Endeavour 160: the A tile's element type is resolved here and passed to the shape check, so a
   tf32 kernel asking for K=16 is still refused while a bf16 one is accepted.

   Endeavour 161: the OPERAND SHAPES are checked too.  Order matters -- the shape check runs
   first, so a kernel that is wrong about both its triple and its tiles still reports the triple,
   which is what tests/spec/140-wgmma/errors/01-03 assert.

   Endeavour 198: :b-major :mn declares B as (K N), read with transB=1.  It needs a 16-bit element
   (tf32 wgmma has no transpose), :swizzle :128b (the MN-major descriptor is built for the 128-byte
   swizzle atom: 64 N x 8 K), and N a multiple of 64 (one atom wide)."
  (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
    (let* ((elem (%coop-elem-of (analyze-expression a env context (append location '(3)))))
           (swz  (getf kwargs :swizzle))
           (bm-raw (getf kwargs :b-major :k))
           (b-major (if (and (symbolp bm-raw) (string-equal (symbol-name bm-raw) "MN")) :mn
                        (if (and (symbolp bm-raw) (string-equal (symbol-name bm-raw) "K")) :k
                            (error 'crisp-compiler-error
                                   :message (format nil "wgmma-accumulate-via-tile: :b-major must be :k (B is (N K), the default) or :mn (B is (K N), read with transB=1), not ~s." bm-raw)
                                   :source-location location)))))
      (log:debug "198 wgmma-accumulate-via-tile: shape=~a elem=~a swizzle=~a b-major=~a" shape elem swz b-major)
      (%check-wgmma-shape shape location swz elem)
      (when (eq b-major :mn)
        (unless (= (%wgmma-k-per-slice elem) 16)
          (error 'crisp-compiler-error
                 :message (format nil "wgmma-accumulate-via-tile :b-major :mn needs a 16-bit operand (half or bfloat16): tf32 wgmma has no transpose immediate, so a ~a B can only be read as (N K)." elem)
                 :source-location location))
        (unless (%198-swizzle-128b-p swz)
          (error 'crisp-compiler-error
                 :message "wgmma-accumulate-via-tile :b-major :mn needs :swizzle :128b -- the MN-major B descriptor is built for the 128-byte swizzle atom (64 N x 8 K) that a :128b TMA load lays down."
                 :source-location location))
        (unless (zerop (rem (second shape) 64))
          (error 'crisp-compiler-error
                 :message (format nil "wgmma-accumulate-via-tile :b-major :mn needs N to be a multiple of 64 (one 128-byte swizzle atom of 16-bit elements), but N is ~a." (second shape))
                 :source-location location)))
      (%check-wgmma-operands shape a b location elem swz b-major)
      (analyze-expression `(set! ,d (wgmma-accumulate ,d ,a ,b :swizzle ,swz :k ,(third shape)
                                                      ,@(when (eq b-major :mn) (list :b-major :mn))))
                          env context location))))

;; src/metadata.lisp -- a tensor map names its element by primitive as well
(defun generate-implicit-signature (sig declared-params)
  "Generates the :implicit-params plist for metadata serialization.  Endeavor 140: the CUtensorMap
   descriptor's :swizzle now comes from *tma-resolved* (:128b for wgmma tiles) instead of hardcoded."
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))
    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             (type-head (when (consp type) (symbol-name (first type)))))
        (cond
          ((and type-head (string-equal type-head "TENSOR-MAP"))
           (let ((info (gethash (cons (function-signature-name sig) name) *tma-resolved*)))
             (push (list :name (string-downcase (symbol-name name))
                         :kind :tensor-map
                         :describes (and (getf info :describes)
                                         (string-downcase (symbol-name (getf info :describes))))
                         :element-type (strip-package-qualifiers (%host-visible-type (getf info :element-type)))
                         :rank (getf info :rank)
                         :box-dims (getf info :box-dims)
                         :layout (or (getf info :layout) :row-major)
                         :swizzle (or (getf info :swizzle) :none)
                         :address-space :global
                         :range (list start end))
                   implicit-args)))
          (t
           (let ((address-space
                   (cond
                     ((and (consp type) (string-equal type-head "CELL") (>= (length type) 3))
                      (nth 2 type))
                     ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                                :test #'string-equal)
                           (>= (length type) 4))
                      (nth 3 type))
                     (t :local)))
                 (size-expr (gethash name *implicit-scratch-size-expr-map*)))
             (push (list :name (string-downcase (symbol-name name))
                         :type (strip-package-qualifiers type)
                         :size-expr size-expr
                         :address-space address-space
                         :range (list start end))
                   implicit-args))))
        (incf phys-index width)))
    (nreverse implicit-args)))

;; src/mma.lisp -- again: the unchanged copy above would otherwise win.  This is the one to fold.
(defun %wgmma-asm-string (nacc n &optional elem)
  "wgmma.mma_async.sync.aligned.m64n{N}k{KPS}.<d>.<a>.<b> {$0..$nacc-1}, descA, descB, ...;
   Accumulator is an OUTPUT plus a tied INPUT, so the two 'l' descriptors are $2*nacc and
   $2*nacc+1.  tf32 takes three trailing immediates; the 16-bit forms take five, adding
   transA/transB from *wgmma-16-trans* while that pair is under investigation.  int8 takes one."
  (let* ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i)))
         (kps  (%wgmma-k-per-slice elem))
         (tail (case kps
                 (32 "1")
                 (16 (format nil "1, 1, 1, ~d, ~d" (first *wgmma-16-trans*) (second *wgmma-16-trans*)))
                 (t  "1, 1, 1"))))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk~d.~a {~a}, $~d, $~d, ~a;"
            n kps (%wgmma-operand-mnemonic elem) accs (* 2 nacc) (1+ (* 2 nacc)) tail)))

;; src/mma.lisp
(defun %check-int-mma-k (mma-shape a env context location)
  "Refuses an int8 multiply at a K meant for another width.  (8 16 8) is a legal shape, but for tf32, so
   the profile check passes it, while the operands load at K=32.  That compiled silently."
  (when (eq *target-backend* :spirv)
    (let ((elem (%coop-elem-of (analyze-expression a env context location))))
      (when (%int-operand-p elem)
        (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)
          (declare (ignore sm sn))
          (unless (eql (third mma-shape) sk)
            (error 'crisp-compiler-error
                   :message (format nil "mma-accumulate-via-tile: ~(~a~) operands need K=~a on this profile; got ~a."
                                    elem sk (third mma-shape))
                   :source-location location)))))))

;; src/mma.lisp -- calls %check-int-mma-k
(defun analyze-mma-accumulate-via-tile (expr env context location)
  "P3b-1: (mma-accumulate-via-tile (M N K) C-TILE A B) — walk the register C-tile in
   16x8 fragments and accumulate ONE K-step (K = the shape's K) into each, set!-ing the
   accumulated tile back.  Bodyless (no accum-op / epilogue yet)."
  (destructuring-bind (mma-shape c-tile a b) (cdr expr)
    (%check-mma-shape mma-shape location)
    (%check-int-mma-k mma-shape a env context location)
    (let* ((c-node (analyze-expression c-tile env context (append location '(1))))
           (c-type (semantic-node-type c-node)))
      (unless (%register-tile-type-p c-type)
        (error 'crisp-compiler-error
               :message (format nil "mma-accumulate-via-tile: C-tile (2nd arg) must be a register-tile, got type ~a." c-type)
               :source-location location))
      (destructuring-bind (tm tn &optional (elem 'float)) (gethash c-type *register-tile-dims*)
        (let* ((fmn (%acc-frag-mn elem))
               (m-frags (floor tm (car fmn))) (n-frags (floor tn (cdr fmn))))
          (analyze-expression
           `(set! ,c-tile
              (let ((cv ,c-tile))
                (%construct-struct ,c-type
                  ,@(loop for mi below m-frags
                          append (loop for nj below n-frags
                                       for idx = (+ (* mi n-frags) nj)
                                       collect `(mma-accumulate
                                                 (%extract-struct-member cv ,idx)
                                                 (load-fragment-a ,a (,mi 0))
                                                 (load-fragment-b ,b (0 ,nj))))))))
           env context location))))))

;; src/mma.lisp
(defun %check-int-tile-k (shape elem)
  "Refuses a via-tile multiply into an integer tile at a K meant for another width.  (8 16 8) is a legal
   shape, but for tf32, while integer operands load at K=32.  A let-bound tile is rewritten here,
   before analysis, so this is the check real kernels reach; %check-int-mma-k covers the analyzed form."
  (when (and shape (eq *target-backend* :spirv) (%elem-integer-p elem))
    (multiple-value-bind (sm sn sk) (%spv-mma-shape 'char)
      (declare (ignore sm sn))
      (unless (eql (third shape) sk)
        (error 'crisp-compiler-error
               :message (format nil "mma-accumulate-via-tile: 8-bit operands need K=~a on this profile; got ~a."
                                sk (third shape)))))))

;; src/mma.lisp -- calls %check-int-tile-k
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body shape)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is a
   static per-warp switch (n-true threaded to %emit-frag-loop-distributed).  Endeavor 142: when A/B
   are register-tiles (present in TILES, pre-loaded via load-tile), the operand is read from its
   pre-loaded fragment var instead of load-fragment-a/b.

   Endeavor 145 P3a: the staged operands may span SEVERAL native K-steps (Kt / K_n, compile-time)
   and every one of them now fires.  Previously only K-index 0 was emitted and any surplus staged
   data was silently dropped.  For the F3 body/accum-op API this means (accum-op) fires the
   fragment's WHOLE contraction — all of its K-steps — which keeps the promise that the body
   controls WHEN a fragment accumulates, not how its contraction is chopped up."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (progn (%check-int-tile-k shape (%register-tile-elem-of (first entry))) (%frag-mn (%register-tile-elem-of (first entry))))
      ;; Endeavour 155 Phase C: honour the shape the KERNEL asked for.
      ;;
      ;; (mma-accumulate-via-tile (8 16 16) C A B) states K=16, which is the correct native
      ;; K-step for a 16-bit operand.  Re-deriving it from (first :mma-shapes) returned the TF32
      ;; K=8 instead, so the walker indexed fragments on a different K than the tiles were minted
      ;; with -- the A-tile held one K=16 fragment while the walker asked for two K=8 ones, and
      ;; the second came back NIL ("Unknown variable NIL").
      ;;
      ;; The requested shape was already in hand at the call site and already validated against
      ;; the profile by %check-mma-shape; it simply was not passed down.  Falling back to
      ;; %spv-mma-shape keeps every other caller behaving exactly as before.
      (multiple-value-bind (sm sn sk)
          (if (and shape (listp shape) (= (length shape) 3) (every #'integerp shape))
              (values-list shape)
              (%spv-mma-shape))
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (let* ((mp (%warp-slice-extent ta :a))          ; 155 Step 2b
                                  (row (if mp (mod mi mp) mi)))
                             (nth (+ (* row (max 1 (floor (third ta) sk))) ks) (fourth ta)))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (let* ((np (%warp-slice-extent tb :b))          ; 155 Step 2b
                                  (stride (or np (max 1 (floor (third tb) sn))))
                                  (col (if np (mod nj np) nj)))
                             (nth (+ (* ks stride) col) (fourth tb)))
                           `(load-fragment-b ,b (,ks ,nj)))))
                   (one-frag (fv mi-form nj-form)
                     (let* ((sets (loop for ks below k-steps
                                        collect `(set! ,fv (mma-accumulate ,fv
                                                                           ,(a-operand mi-form ks)
                                                                           ,(b-operand nj-form ks)))))
                            (acc-set (if (= (length sets) 1) (first sets) `(progn ,@sets))))
                       (if body
                           (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                           (list acc-set)))))
            (if (> n-true 1)
                ;; Endeavour 155: register-resident A/B ARE supported with a warp-distributed
                ;; accumulator.  The refusal this replaces was incidental, not essential --
                ;; %emit-frag-loop-distributed's own contract says so:
                ;;
                ;;   "PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS
                ;;    (same contract as the n-true=1 static path)."
                ;;
                ;; and it computes them as (floor logical n-frags) / (mod logical n-frags), both
                ;; compile-time.  a-operand/b-operand index the tile's fragment SYMBOL LIST with
                ;; (nth ...), which needs exactly that -- a constant.  139 step-4 made this path
                ;; static precisely so operand addressing could be static, so the machinery the
                ;; refusal was waiting for already existed when it was written.
                ;;
                ;; WHY THIS MATTERS.  It is the only route to a bigger workgroup tile that does
                ;; NOT go through SLM.  C is what limits tile size -- 64x64 in one subgroup spills
                ;; 112 registers and collapses to 20 TFLOPS -- and splitting C across subgroups
                ;; divides exactly that pressure, while A/B keep the register+prefetch path that
                ;; is the fastest thing on this hardware.  A/B are then loaded redundantly per
                ;; warp, which costs bandwidth the cache may absorb; that is the trade to measure.
                (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))
