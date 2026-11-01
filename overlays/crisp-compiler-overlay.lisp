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
