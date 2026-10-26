;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
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

;;;; ==========================================================================================
;;;; Endeavour 194 -- two-level uniformity: WORKGROUP-uniform vs WARP-uniform.
;;;; Design + decisions: tests/spec/194-uniformity/uniformity.md
;;;;
;;;; Two questions at every program point:
;;;;   does every thread of the WORKGROUP arrive here?  -- barriers need it  (*in-divergent-conditional*)
;;;;   does every lane of the WARP arrive here?         -- warp collectives need it (*in-lane-divergent*)
;;;; and a third uniformity value, :warp-uniform, between :uniform and :divergent.
;;;; ==========================================================================================

;; src/analysis/control.lisp
(defvar *in-lane-divergent* nil
  "Endeavour 194: T when some LANES of a warp may not reach the code being analysed -- inside a branch,
   a loop bound or a loop exit governed by a per-thread (:divergent or :unknown) value.  A warp
   collective (shuffle, reduce-warp, to-warp-uniform, sync-warp, or a call to a function containing one)
   is refused here.  Its workgroup-level partner is *in-divergent-conditional*, which a merely
   WARP-uniform condition also sets: a barrier needs the whole workgroup, a collective only the warp.")

;; src/analysis/control.lisp
(defvar *194-divergence-reason* nil
  "Endeavour 194: why *in-divergent-conditional* is set, for the refusal message -- :conditional (a
   per-thread if / when / unless / cond), :warp-conditional (a condition only WARP-uniform), or
   :loop-bound (a loop whose trip count is not uniform).  NIL outside any such scope.")

;; src/analysis/control.lisp
(defvar *194-loop-level* :uniform
  "Endeavour 194: the lowest uniformity of the conditions entered SINCE the innermost dotimes-family
   loop began.  A return-from-loop records it as the uniformity of that exit.")

;; src/analysis/control.lisp
(defstruct %194-loop-record
  "Endeavour 194: what the innermost dotimes-family loop's body contained, judged when the loop ends.
   EXITS  -- the scope level of each of its own return-from-loop forms.
   EVENTS -- (kind name location nested) for each barrier (:barrier) or warp collective (:collective)
             in it, nested loops included: an exit of THIS loop strands threads before all of them.
             NESTED is T when the event sits in a nested loop or behind a call (BUG 141, SPIR-V).
   SETS   -- the variables (parameter-defs) set! in it, lowered to the exit level afterwards."
  (exits nil) (events nil) (sets nil))

;; src/analysis/control.lisp
(defvar *194-loop* nil
  "Endeavour 194: the %194-loop-record of the innermost dotimes-family loop being analysed, or NIL.")

;; src/analysis/control.lisp
(defstruct %194-fn-summary
  "Endeavour 194: what a function's body does that its CALLERS must know (D3/D4).
   BARRIER    -- the name of a barrier it reaches (directly or through a callee), or NIL.
   COLLECTIVE -- the name of a warp collective it reaches, or NIL.
   RETURNS    -- the uniformity of each (return ...) it executes, joined with the scope it ran in."
  (barrier nil) (collective nil) (returns nil))

;; src/analysis/control.lisp
(defvar *194-fn-summary* nil
  "Endeavour 194: the %194-fn-summary of the function whose body is being analysed, or NIL.")

;; src/analysis/core.lisp
(defvar *194-function-summaries* (make-hash-table :test #'equal)
  "Endeavour 194: function NAME (string) -> %194-fn-summary, filled as each function is compiled.
   Overloads of one name share an entry, merged conservatively.  Cleared by initialize-compiler.")

;; src/analysis/control.lisp
(defvar *194-lane-index-names* nil
  "Endeavour 194 (D-194-15): names of let-bound variables holding the local thread index --
   (get-local-linear-id), or (get-local-id 0), through to-ulong / to-uint / to-long / to-int.  The
   provenance %194-warp-index-division-p needs to see that (/ tid 32ul) is warp-uniform; uniformity values
   alone cannot, since tid itself is just :divergent.")

;; src/analysis/control.lisp
(defun %194-lane-index-form-p (form)
  "Endeavour 194: T when the SOURCE FORM is the local thread index, possibly cast, or a variable already
   known to hold it (*194-lane-index-names*)."
  (cl:cond
    ((symbolp form) (and form (member form *194-lane-index-names*) t))
    ((not (consp form)) nil)
    (t (let ((h (and (symbolp (car form)) (symbol-name (car form)))))
         (cl:cond ((null h) nil)
                  ((string= h "GET-LOCAL-LINEAR-ID") (null (cdr form)))
                  ((string= h "GET-LOCAL-ID") (equal (cdr form) '(0)))
                  ((member h '("TO-ULONG" "TO-UINT" "TO-LONG" "TO-INT") :test #'string=)
                   (and (= (length form) 2) (%194-lane-index-form-p (second form))))
                  (t nil))))))

;; src/analysis/core.lisp
(defun %194-lane-index-node-p (n)
  "Endeavour 194: T when the analysed node N is the local thread index, through casts."
  (cl:cond ((semantic-cast-p n) (%194-lane-index-node-p (semantic-cast-arg n)))
           ((semantic-var-read-p n) (and (member (semantic-var-read-name n) *194-lane-index-names*) t))
           ((semantic-gpu-builtin-p n)
            (let ((b (semantic-gpu-builtin-builtin-name n)))
              (or (eq b :get-local-linear-id)
                  (and (eq b :get-local-id) (eql (semantic-gpu-builtin-dimension n) 0)))))
           (t nil)))

;; src/analysis/core.lisp
(defun %194-one-dimensional-workgroup-p ()
  "Endeavour 194: T when the function being compiled declares a compile-time workgroup that is 1-D
   (Y = Z = 1).  Warps are then consecutive runs of the local index on both targets."
  (let ((dims (and *compiler-context*
                   (%declared-local-size-dims (compiler-context-declarations *compiler-context*)))))
    (and dims (every (lambda (d) (= d 1)) (rest dims)))))

;; src/analysis/core.lisp
(defun %194-warp-index-division-p (node)
  "Endeavour 194 (D-194-15): T when the division NODE is (/ <local thread index> K) with K a literal the
   warp size divides, in a 1-D workgroup -- constant across every warp, so :warp-uniform.  (K need only
   be a multiple of the width the kernel is compiled against: a smaller real warp divides it too.)"
  (let ((r (semantic-div-right-arg node)))
    (and (semantic-literal-p r)
         (integerp (semantic-literal-value r))
         (plusp (semantic-literal-value r))
         (zerop (mod (semantic-literal-value r) (%173-warp-size)))
         (%194-lane-index-node-p (semantic-div-left-arg node))
         (%194-one-dimensional-workgroup-p))))

;; src/analysis/control.lisp
(defvar *194-orig-analyze-let-expression* (fdefinition 'analyze-let-expression)
  "Endeavour 194: analyze-let-expression as src defines it; the overlay wraps it.")

;; src/analysis/control.lisp
(defun analyze-let-expression (expr env context location)
  "Endeavour 194 wrapper (fold into the src function): tracks which bindings hold the local thread index
   (*194-lane-index-names*) for the body.  Sequential, like the let: a binding sees the ones before it,
   and rebinding a name shadows an outer index of that name."
  (let ((bindings (and (consp (cdr expr)) (listp (second expr)) (second expr)))
        (names *194-lane-index-names*))
    (dolist (b bindings)
      (let ((name (if (consp b) (first b) b))
            (init (and (consp b) (second b))))
        (when (and name (symbolp name))
          (setf names (remove name names))
          (when (let ((*194-lane-index-names* names)) (%194-lane-index-form-p init))
            (push name names)))))
    (let ((*194-lane-index-names* names))
      (funcall *194-orig-analyze-let-expression* expr env context location))))

;; src/analysis/core.lisp
(defun %194-level (u)
  "Endeavour 194: uniformity U as a SCOPE level -- :uniform, :warp-uniform or :divergent.  :unknown
   proves nothing, so it counts as :divergent."
  (cl:case u
    ((:uniform :warp-uniform) u)
    (t :divergent)))

;; src/analysis/core.lisp
(defun %194-meet (a b)
  "Endeavour 194: the lower of two scope levels, ordered :uniform > :warp-uniform > :divergent."
  (let ((a (%194-level a))
        (b (%194-level b)))
    (cl:cond ((or (eq a :divergent) (eq b :divergent)) :divergent)
             ((or (eq a :warp-uniform) (eq b :warp-uniform)) :warp-uniform)
             (t :uniform))))

;; src/analysis/core.lisp
(defun %194-current-level ()
  "Endeavour 194: the scope level of the code being analysed right now."
  (cl:cond ((or *in-lane-divergent* (> *divergent-scope-depth* 0)) :divergent)
           (*in-divergent-conditional* :warp-uniform)
           (t :uniform)))

;; src/analysis/core.lisp
(defun %uniformity-join (states)
  "The uniformity of a value computed from parts whose uniformity STATES are given: :divergent if any
   part is, :uniform only if every part is, :unknown otherwise.
   Endeavour 194: :warp-uniform when every part is :uniform or :warp-uniform (and not all :uniform)."
  (cl:cond ((member :divergent states) :divergent)
           ((every (lambda (s) (eq s :uniform)) states) :uniform)
           ((every (lambda (s) (member s '(:uniform :warp-uniform))) states) :warp-uniform)
           (t :unknown)))

;; src/analysis/control.lisp
(defun %194-call-in-scope (uniformity reason thunk)
  "Endeavour 194: calls THUNK to analyse code governed by a condition / bound / exit of UNIFORMITY.
     :uniform      -- every thread arrives together: nothing changes.
     :warp-uniform -- whole warps arrive together: barriers are refused (*in-divergent-conditional*),
                      warp collectives stay legal.
     otherwise     -- lanes may split: both are refused (*in-lane-divergent* too).
   REASON (:conditional or :loop-bound) only picks the refusal message.  Also lowers *194-loop-level*
   (the level a return-from-loop inside records) and bumps *divergent-scope-depth* (set! taint) for a
   lane-divergent scope, as the conditional and loop analysers always did."
  (let* ((level (%194-level uniformity))
         (*194-divergence-reason* (cl:cond ((eq level :uniform) *194-divergence-reason*)
                                           (*in-divergent-conditional* *194-divergence-reason*)
                                           ((eq level :warp-uniform) :warp-conditional)
                                           (t reason)))
         (*in-divergent-conditional* (or *in-divergent-conditional* (not (eq level :uniform))))
         (*in-lane-divergent* (or *in-lane-divergent* (eq level :divergent)))
         (*divergent-scope-depth* (if (eq level :divergent)
                                      (1+ *divergent-scope-depth*)
                                      *divergent-scope-depth*))
         (*194-loop-level* (%194-meet *194-loop-level* level)))
    (funcall thunk)))

;; src/analysis/control.lisp
(defun %194-note (kind name location &optional nested)
  "Endeavour 194: records that a barrier (KIND :barrier) or warp collective (:collective) named NAME was
   analysed at LOCATION -- into the innermost loop, which judges it against its exits when it ends, and
   into the summary of the function being compiled, which its call sites are checked against.  NESTED
   (a call: the callee may loop) marks it for the SPIR-V rule in %194-judge-loop."
  (when *194-loop*
    (push (list kind name location nested) (%194-loop-record-events *194-loop*)))
  (when *194-fn-summary*
    (if (eq kind :barrier)
        (unless (%194-fn-summary-barrier *194-fn-summary*)
          (setf (%194-fn-summary-barrier *194-fn-summary*) name))
        (unless (%194-fn-summary-collective *194-fn-summary*)
          (setf (%194-fn-summary-collective *194-fn-summary*) name)))))

;; src/analysis/control.lisp
(defun %194-barrier-refusal (name-str scope-word location)
  "Endeavour 194: the error for a barrier NAME-STR (every thread of the SCOPE-WORD must reach it) in code
   only some threads reach.  The :conditional wording is the original one (specs pin its phrases)."
  (error 'crisp-compiler-error
    :message
    (cl:case *194-divergence-reason*
      (:warp-conditional
       (format nil "~a cannot appear inside a branch that only some WARPS take.  It is a barrier every thread of the ~a must reach, and the condition here is only warp-uniform (to-warp-uniform, warp-id, reduce-warp, or a value set inside such a branch): the warps that skip it never arrive, so the ones that enter wait forever.  Use a workgroup-uniform condition (to-workgroup-uniform, get-workgroup-id, a kernel argument) -- or move the barrier out of the branch."
               name-str scope-word))
      (:loop-bound
       (format nil "~a cannot appear inside a loop whose trip count is not uniform across the ~a.  It is a barrier every thread of the ~a must reach on every iteration: a thread that runs fewer iterations stops arriving, so the others wait forever.  Make the bound uniform (to-workgroup-uniform, or (declare (uniform ...)) if it already is) and use dotimes+, or move the barrier out of the loop."
               name-str scope-word scope-word))
      (t
       (format nil "~a cannot appear inside a thread-divergent conditional (if / when / unless / cond).  It is a barrier every thread of the ~a must reach: threads that skip the branch never arrive, so the threads that enter it wait forever.  (sync-wait ends in a sync-workgroup, so it is refused here too.)  Compile-time conditionals (if+ / when+ / unless+) are safe, and so is a condition every thread of the ~a evaluates the same way (e.g. one based on get-workgroup-id, not get-local-id).  A mem-fence, which waits for no one, may appear here."
               name-str scope-word scope-word)))
    :source-location location))

;; src/analysis/control.lisp
(defun %194-collective-refusal (name location)
  "Endeavour 194: the error for warp collective NAME in code that only some lanes of a warp reach."
  (error 'crisp-compiler-error
    :message (format nil "~a is a warp collective and cannot appear ~a: the lanes that arrive would be asking for data from lanes that never will. Shuffle in every lane UNCONDITIONALLY and gate only what you do with the result, or use a uniform condition (if+ / when+ / unless+, a warp-uniform one such as to-warp-uniform, or one based on get-workgroup-id rather than get-local-id)"
                     name
                     (if (eq *194-divergence-reason* :loop-bound)
                         "inside a loop whose trip count differs between the lanes of a warp"
                         "inside a thread-divergent conditional (if / when / unless / cond)"))
    :source-location location))

;; src/analysis/control.lisp
(defun %warp-spec-check-sync (builtin-kw name-str location)
  "Endeavor 139 (decision B): the sync/fence builtins inside a role block.  A workgroup collective
   (sync-workgroup, sync-cluster) DEADLOCKS -- only one role's warps reach it -- so it is forbidden;
   warp-scoped ops (sync-warp, mem-fence) are fine.  Outside a warp-spec block, a BARRIER inside a
   thread-divergent conditional is refused.

   Endeavour 183 (BUG 082): a FENCE (mem-fence, mem-fence-workgroup) is exempt.  It orders the calling
   thread's own memory accesses and waits for no one, so there is nothing to deadlock.

   Endeavour 194: two levels.  sync-warp needs only its WARP converged (*in-lane-divergent*); a
   workgroup barrier needs the whole WORKGROUP (*in-divergent-conditional*, which a warp-uniform
   condition or a non-uniform loop bound now sets too).  A barrier inside a loop that can exit early is
   no longer refused HERE: it is recorded (%194-note) and judged when the loop ends, against the
   uniformity of the loop's exits (%194-judge-loop)."
  (cl:cond
    ((member builtin-kw '(:mem-fence :mem-fence-workgroup)) nil)
    ((eq builtin-kw :sync-warp)
     (%194-note :collective name-str location)
     (when *in-lane-divergent*
       (%194-collective-refusal name-str location)))
    (*in-warp-spec-block*
     (%194-note :barrier name-str location)
     (when (member builtin-kw '(:sync-workgroup :sync-cluster))
       (error 'crisp-compiler-error
         :message (format nil "~a cannot appear inside a with-warp-specialization role block — it is a COLLECTIVE and only one role's warps reach it, so it deadlocks.  Synchronize the producer and consumer through the barrier rings (await / signal) instead; sync-warp is fine for intra-warp ordering." name-str)
         :source-location location)))
    (t
     (%194-note :barrier name-str location)
     (when *in-divergent-conditional*
       (%194-barrier-refusal name-str
                             (if (eq builtin-kw :sync-cluster) "cluster" "workgroup")
                             location)))))

;; src/analysis/control.lisp
(defun %shuffle-check-not-divergent (op-name location)
  "Endeavour 173, D6: a shuffle is a warp collective and every lane must reach it.

   Endeavour 194: the test is *in-lane-divergent* -- whether LANES of one warp may have split.  A
   branch whole warps take or skip (a warp-uniform condition, or an Endeavour 139 role block, which used
   to be a special case here) leaves every warp converged, so the shuffle is legal there.  The
   collective is also recorded (%194-note) for the enclosing loop's exits and for call sites."
  (%194-note :collective op-name location)
  (when *in-lane-divergent*
    (%194-collective-refusal op-name location)))

;; src/analysis/control.lisp
(defun %tlc-check-not-divergent (op-name location)
  "Signals a clear compile error if (op-name) appears inside a thread-divergent
   conditional.  Call from load-tile-at / store-tile-at analyzers.
   NOTE (Endeavor 139): a with-warp-specialization role block ALSO sets *in-divergent-conditional*,
   but its callers gate this on (not *in-warp-spec-block*) and apply the mode-aware
   %warp-spec-check-block-only instead — a :block load there is leader-issued and safe.
   Endeavour 194: the internal sync-workgroup is recorded (%194-note) for loop exits and call sites."
  (%194-note :barrier op-name location)
  (when *in-divergent-conditional*
        (error 'crisp-compiler-error
          :message (format nil
                       "~A cannot appear inside a thread-divergent conditional (if / when / unless / cond).  It contains an internal sync-workgroup that would deadlock when only some threads enter the branch.  Compile-time conditionals (if+ / when+ / unless+) are safe.  If you need a guarded copy, use a non-divergent condition (e.g. one based on get-workgroup-id, not get-local-id) or restructure the kernel."
                     op-name)
          :source-location location)))

;; src/analysis/control.lisp
(defun analyze-to-workgroup-uniform (expr env context location)
  "Analyzes (to-workgroup-uniform X), legal only as a let initializer.
   Endeavour 194 (F7): it BROADCASTS -- local thread 0's X reaches every thread through workgroup memory
   and a barrier -- so it is a barrier: refused where only some threads arrive, and recorded for loop
   exits and call sites like one."
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-workgroup-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-workgroup-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-workgroup-uniform expects 1 argument" :source-location location))
  (%194-note :barrier "to-workgroup-uniform" location)
  (when *in-divergent-conditional*
    (%194-barrier-refusal "to-workgroup-uniform (it broadcasts through a barrier)" "workgroup" location))
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (make-semantic-to-workgroup-uniform :type type :value-node val-node :source-location location)))

;; src/analysis/control.lisp
(defun analyze-to-warp-uniform (expr env context location)
  "Analyzes (to-warp-uniform X), legal only as a let initializer.
   Endeavour 194 (F7): it BROADCASTS lane 0's X to its warp with a shuffle, so it is a warp collective:
   refused where lanes of a warp may have split, and recorded like one."
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-warp-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-warp-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-warp-uniform expects 1 argument" :source-location location))
  (%shuffle-check-not-divergent "to-warp-uniform (it broadcasts with a shuffle)" location)
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (unless (member (resolve-type-alias type) *shuffle-value-types*)
      (error 'crisp-compiler-error
        :message (format nil "to-warp-uniform broadcasts with a shuffle, which moves ~{~(~a~)~^, ~} -- ~(~a~) is not one of them.  Convert the value to one of those types first."
                         *shuffle-value-types* type)
        :source-location location))
    (make-semantic-to-warp-uniform :type type :value-node val-node :source-location location)))

;; src/analysis/control.lisp
(defun analyze-return-from-loop-expression (expr env context location)
  "Analyzes (return-from-loop).  Endeavour 184 D1-D3: legal only in the body of a dotimes or a non-+
   172 variant, lexically.  Returns a semantic-return-from-loop node (type void).
   Endeavour 194: records the exit's uniformity -- the lowest condition between it and its loop
   (*194-loop-level*) -- for %194-judge-loop."
  (declare (ignore env context))
  (unless (= (length expr) 1)
    (error 'crisp-compiler-error
      :message (format nil "return-from-loop takes no arguments, got ~a.  It leaves the loop and yields no value -- store a result in a variable before leaving." (1- (length expr)))
      :source-location location))
  (cl:case *loop-exit-context*
    (:plain
     (when *194-loop*
       (push *194-loop-level* (%194-loop-record-exits *194-loop*)))
     (make-semantic-return-from-loop :type 'void :source-location location))
    (:plus
     ;; Normally refused at the loop by %analyze-loop-with-unroll; this is the backstop.
     (error 'crisp-compiler-error
       :message "return-from-loop cannot appear in a + loop.  A + loop promises a uniform trip count, and an early exit taken per thread breaks that promise.  Use the plain form for a loop that may end early."
       :source-location location))
    (t
     (error 'crisp-compiler-error
       :message "return-from-loop has no enclosing loop.  It leaves the innermost dotimes-family loop (dotimes, dec-times, do-power-step, ...) that LEXICALLY contains it.  A function called from inside a loop cannot leave its caller's loop."
       :source-location location))))

;; src/analysis/control.lisp
(defun %194-judge-loop (record)
  "Endeavour 194: judges a finished loop's barriers and collectives against its exits (184 D4, made
   two-level).  The exit level is the lowest of the loop's return-from-loop levels (:uniform when it has
   none).
     A warp collective is refused only for a lane-divergent exit: a warp-uniform exit lets whole warps
     leave together, so every lane still inside has all of its warp (F1).
     On any target but PTX (SPIR-V, or :generic IR that may become SPIR-V) a collective in a NESTED loop
     (or behind a call) is refused even so: BMG mis-executes it (BUG 141, decision D-194-7).
     A BARRIER is refused for ANY exit, as 184 D4 had it.  A workgroup-uniform exit would be safe by the
     execution model, but BMG mis-executes a barrier in any loop holding a return-from-loop -- even one
     never taken (BUG 141) -- so the relaxation stops at collectives (decision D-194-6).
   Afterwards each variable the loop set! is lowered to the exit level: threads that left early hold an
   older value."
  (let* ((exits (%194-loop-record-exits record))
         (level (reduce #'%194-meet exits :initial-value :uniform)))
    (when exits
      (dolist (ev (reverse (%194-loop-record-events record)))
        (destructuring-bind (kind name loc nested) ev
          (cl:cond
            ((eq kind :barrier)
             (error 'crisp-compiler-error
               :message (format nil "~a cannot appear inside a loop that can exit early (one containing return-from-loop).  A thread that has left the loop never reaches this barrier on a later iteration, so the threads still inside wait for it forever.  ~a  Move the barrier out of the loop, or end the loop by its bound instead of by return-from-loop."
                                name
                                (cl:case level
                                  (:warp-uniform "Here an exit is warp-uniform: whole warps leave together, which keeps a warp collective legal but not a barrier.")
                                  (:uniform "Here every exit is workgroup-uniform, which the execution model allows -- but BMG mis-executes a barrier in a loop holding any return-from-loop (BUG 141), so Crisp refuses it.")
                                  (t "")))
               :source-location loc))
            ((and nested (not (eq *target-backend* :ptx)))
             (error 'crisp-compiler-error
               :message (format nil "~a is a warp collective inside a nested loop (or a called function) within a loop that can exit early.  The execution model allows it for a warp-uniform exit, but on SPIR-V BMG mis-executes it -- lanes see stale partners (BUG 141) -- so Crisp refuses it there.  Keep the collective directly in the early-exit loop's body (a flat shuffle is fine), do the reduction before or after the loop, or end the loop by its bound."
                                name)
               :source-location loc))
            ((eq level :divergent)
             (error 'crisp-compiler-error
               :message (format nil "~a is a warp collective and cannot appear inside a loop that can exit early on a per-lane condition: a lane that has left never reaches it on a later iteration, so the lanes still inside would ask for data from lanes that never will.  Make the exit condition warp-uniform (to-warp-uniform, or a reduce-warp result) -- whole warps then leave together -- or end the loop by its bound."
                                name)
               :source-location loc))))))
    (unless (eq level :uniform)
      (dolist (pd (%194-loop-record-sets record))
        (let ((u (parameter-def-uniformity pd)))
          (cl:cond ((eq level :divergent)
                    (setf (parameter-def-uniformity pd) :divergent))
                   ((eq u :uniform)
                    (setf (parameter-def-uniformity pd) :warp-uniform))))))
    level))

;; src/analysis/control.lisp
(defun %analyze-loop-with-unroll (analyzer expr env context location)
  "Endeavour 180.  Runs the counted-loop ANALYZER on EXPR with its body's leading declarations
   stripped, then records the unroll request on the node it returns.  The loop's own analysis
   never sees a declaration.
   Endeavour 184: every dotimes-family loop comes through here, so this is also where
   return-from-loop learns which loop it is in.
     D2 -- a + loop whose own body exits early is refused: a + loop promises a uniform trip count.
   Endeavour 194: D4 is now judged AFTER the body (%194-judge-loop), against the uniformity of the
   loop's exits, which only the analysis of the body can tell.  The body runs with a fresh
   %194-loop-record; what it recorded also goes to the enclosing loop, which an exit of its own would
   strand before this whole loop."
  (let ((plus-p (%rfl-plus-loop-p expr))
        (exits-p (%rfl-free-in-forms-p (cddr expr))))
    (log:debug "184 loop ~a: plus-p=~a exits-early=~a" (%rfl-head-name expr) plus-p exits-p)
    (when (and plus-p exits-p)
      (error 'crisp-compiler-error
        :message (format nil "return-from-loop cannot appear in ~(~a~).  A + loop promises a uniform trip count -- every thread of the workgroup runs the same iterations -- and an early exit taken per thread breaks that promise.  Use the plain form, ~(~a~), for a loop that may end early."
                         (%rfl-head-name expr)
                         (subseq (%rfl-head-name expr) 0 (1- (length (%rfl-head-name expr)))))
        :source-location location))
    (let ((outer *194-loop*)
          (record (make-%194-loop-record))
          (node nil))
      (let ((*loop-exit-context* (if plus-p :plus :plain))
            (*194-loop* record)
            (*194-loop-level* :uniform))
        (multiple-value-bind (body spec)
            (%split-loop-body-declarations (cddr expr) (car expr) location)
          (setf node (funcall analyzer
                              (if (eq body (cddr expr)) expr (list* (car expr) (cadr expr) body))
                              env context location))
          (when (and spec (semantic-dotimes-p node))
            (setf (semantic-dotimes-unroll node)
                  (%resolve-unroll-spec spec node (car expr) env context location)))))
      (let ((level (%194-judge-loop record)))
        (log:debug "194 loop ~a: exits ~s -> ~a; ~d barrier/collective event(s), ~d set!"
                   (%rfl-head-name expr) (%194-loop-record-exits record) level
                   (length (%194-loop-record-events record)) (length (%194-loop-record-sets record))))
      (when outer
        (setf (%194-loop-record-events outer)
              (append (mapcar (lambda (ev) (list (first ev) (second ev) (third ev) t))
                              (%194-loop-record-events record))
                      (%194-loop-record-events outer)))
        (setf (%194-loop-record-sets outer)
              (append (%194-loop-record-sets record) (%194-loop-record-sets outer))))
      node)))

;; src/analysis/structs.lisp
(defun %analyze-set!-simple-variable (target-form value-node env location)
  "Helper to analyze simple variable assignment (set! target-form value-node).
   Endeavor 120 (gap #5): taints the variable :divergent when mutated inside a
   divergent block, or when assigned a divergent value.
   Endeavour 194: two levels.  Set inside a scope only some WARPS reach, or to a warp-uniform value, a
   :uniform variable becomes :warp-uniform -- the other warps never saw the store.  The variable is also
   recorded for the enclosing loop, whose early exits lower it once more (%194-judge-loop)."
  (let ((var-info (find-variable-in-env target-form env)))
    (unless var-info
      (error 'crisp-unknown-variable :name target-form :source-location location))
    (let ((var-type (parameter-def-type var-info))
          (val-type (semantic-node-type value-node)))
      (unless (types-compatible-p val-type var-type)
        (error 'crisp-type-error :expected var-type :inferred val-type
               :source-location location)))
    ;; Endeavor 120: uniformity taint on mutation.
    (let ((val-uni (calculate-uniformity-state value-node env))
          (scope (%194-current-level)))
      (cl:cond
       ((eq scope :divergent)
        (log:debug "Endeavor 120: set! ~a inside divergent scope -> :divergent" target-form)
        (setf (parameter-def-uniformity var-info) :divergent))
       ((eq val-uni :divergent)
        (log:debug "Endeavor 120: set! ~a := divergent value -> :divergent" target-form)
        (setf (parameter-def-uniformity var-info) :divergent))
       ((and (or (eq scope :warp-uniform) (eq val-uni :warp-uniform))
             (eq (parameter-def-uniformity var-info) :uniform))
        (log:debug "194: set! ~a in a warp-level scope / to a warp-uniform value -> :warp-uniform" target-form)
        (setf (parameter-def-uniformity var-info) :warp-uniform))))
    (when *194-loop*
      (push var-info (%194-loop-record-sets *194-loop*)))
    (when (member target-form *194-lane-index-names*)
      (setf *194-lane-index-names* (remove target-form *194-lane-index-names*)))
    (make-semantic-set!
     :target-node (make-semantic-var-read
                   :name target-form
                   :type (parameter-def-type var-info)
                   :source-location location)
     :value-node value-node
     :source-location location)))

;; src/analysis/core.lisp
(defun %194-summary-key (name)
  "Endeavour 194: the *194-function-summaries* key for function NAME (a symbol or string)."
  (string-upcase (if (symbolp name) (symbol-name name) (princ-to-string name))))

;; src/analysis/core.lisp
(defun %194-record-summary (name summary)
  "Endeavour 194: stores SUMMARY for function NAME, merging with an overload already stored -- a call
   site cannot always tell overloads apart, so the merge is the conservative union."
  (let* ((key (%194-summary-key name))
         (old (gethash key *194-function-summaries*)))
    (setf (gethash key *194-function-summaries*)
          (if old
              (make-%194-fn-summary
               :barrier (or (%194-fn-summary-barrier old) (%194-fn-summary-barrier summary))
               :collective (or (%194-fn-summary-collective old) (%194-fn-summary-collective summary))
               :returns (append (%194-fn-summary-returns summary) (%194-fn-summary-returns old)))
              summary))))

;; src/analysis/core.lisp
(defun %194-summary-result (summary)
  "Endeavour 194: the uniformity of a call's result from its callee SUMMARY -- the join of every return
   it executes, whatever the arguments.  :unknown when nothing was recorded."
  (let ((rs (and summary (%194-fn-summary-returns summary))))
    (if rs (%uniformity-join rs) :unknown)))

;; src/analysis/core.lisp
(defvar *194-orig-internal-compile-function* (fdefinition 'internal-compile-function)
  "Endeavour 194: internal-compile-function as src defines it; the overlay wraps it.")

;; src/analysis/core.lisp
(defun internal-compile-function (name explicit-env return-type params body declarations location context)
  "Endeavour 194 wrapper (fold into the src function's body): every function body is analysed in a
   FRESH divergence context -- a template instantiated while its caller is mid-analysis must not inherit
   the caller's branch -- and leaves a %194-fn-summary its call sites are checked against (D3/D4)."
  (let ((summary (make-%194-fn-summary)))
    (multiple-value-prog1
        (let ((*in-divergent-conditional* nil)
              (*in-lane-divergent* nil)
              (*divergent-scope-depth* 0)
              (*194-divergence-reason* nil)
              (*194-loop* nil)
              (*194-loop-level* :uniform)
              (*loop-exit-context* nil)
              (*194-lane-index-names* nil)
              (*194-fn-summary* summary))
          (funcall *194-orig-internal-compile-function*
                   name explicit-env return-type params body declarations location context))
      (log:debug "194 summary ~a: barrier ~a, collective ~a, returns ~s" name
                 (%194-fn-summary-barrier summary) (%194-fn-summary-collective summary)
                 (%194-fn-summary-returns summary))
      (%194-record-summary name summary))))

;; src/analysis/control.lisp
(defvar *194-orig-analyze-return-expression* (fdefinition 'analyze-return-expression)
  "Endeavour 194: analyze-return-expression as src defines it; the overlay wraps it.")

;; src/analysis/control.lisp
(defun analyze-return-expression (expr env context location)
  "Endeavour 194 wrapper (fold into the src function): records the uniformity of what this (return ...)
   returns -- its values joined with the scope it runs in -- in the function's summary (D3)."
  (let ((node (funcall *194-orig-analyze-return-expression* expr env context location)))
    (when *194-fn-summary*
      (let* ((vals (cl:cond ((semantic-explicit-return-p node) (semantic-explicit-return-value-nodes node))
                            ((semantic-return-p node) (list (semantic-return-value-node node)))
                            (t nil)))
             (u (%uniformity-join
                 (cons (%194-current-level)
                       (mapcar (lambda (n) (if n (calculate-uniformity-state n env) :uniform)) vals)))))
        (push u (%194-fn-summary-returns *194-fn-summary*))))
    node))

;; src/analysis/core.lisp
(defvar *194-orig-analyze-function-call* (fdefinition 'analyze-function-call)
  "Endeavour 194: analyze-function-call as src defines it; the overlay wraps it.")

;; src/analysis/core.lisp
(defun analyze-function-call (op expr env context location)
  "Endeavour 194 wrapper (fold into the src function): a call reaches whatever its callee reaches (D4,
   F3).  A callee that contains a barrier is refused where only some threads of the workgroup arrive; one
   that contains a warp collective, where lanes may have split.  Both are recorded for the enclosing loop
   and the caller's own summary, so the rule is transitive."
  (let ((node (funcall *194-orig-analyze-function-call* op expr env context location)))
    (when (semantic-call-p node)
      (let ((summary (gethash (%194-summary-key (semantic-call-name node)) *194-function-summaries*)))
        (if (null summary)
            (log:debug "194: no summary for callee ~a (not compiled yet) -- call site unchecked"
                       (semantic-call-name node))
            (let ((barrier (%194-fn-summary-barrier summary))
                  (collective (%194-fn-summary-collective summary))
                  (callee (string-downcase (%194-summary-key (semantic-call-name node)))))
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
    node))

;; src/analysis/ops.lisp
(defvar *194-orig-analyze-reduce-warp* (fdefinition '%analyze-reduce-warp)
  "Endeavour 194: %analyze-reduce-warp as src defines it; the overlay wraps it.")

;; src/analysis/ops.lisp
(defun %194-reduced-variables (expr)
  "Endeavour 194: the variables a reduce-warp form EXPR leaves reduced -- VAR for a single call, the
   second element of each clause for an independent one.  A dependent call returns NIL (not inferred)."
  (cl:case (%reduction-call-shape expr)
    (:single (and (symbolp (third expr)) (list (third expr))))
    (:independent (loop for clause in (second expr)
                        when (and (consp clause) (symbolp (second clause)))
                          collect (second clause)))
    (t nil)))

;; src/analysis/ops.lisp
(defun %analyze-reduce-warp (expr env context location)
  "Endeavour 194 wrapper (fold into the src function): after the butterfly every lane of the warp holds
   the same value, so each reduced variable is :warp-uniform afterwards (D3) -- :uniform stays :uniform.
   reduce-warp is itself refused in lane-divergent code, so the butterfly always completes."
  (let ((node (funcall *194-orig-analyze-reduce-warp* expr env context location)))
    (dolist (v (%194-reduced-variables expr))
      (let ((pd (find-variable-in-env v env)))
        (when (and pd (not (eq (parameter-def-uniformity pd) :uniform)))
          (log:debug "194: ~a is :warp-uniform after reduce-warp" v)
          (setf (parameter-def-uniformity pd) :warp-uniform))))
    node))

;; src/compiler.lisp (initialize-compiler)
(defvar *194-orig-initialize-compiler* (fdefinition 'initialize-compiler)
  "Endeavour 194: initialize-compiler as src defines it; the overlay wraps it.")

;; src/compiler.lisp (initialize-compiler)
(defun initialize-compiler (&rest args)
  "Endeavour 194 wrapper (fold into the src function): also clears the function summaries."
  (clrhash *194-function-summaries*)
  (apply *194-orig-initialize-compiler* args))

;; src/analysis/control.lisp
(defun analyze-if-expression-impl (expr env context location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    ;; No runtime divergence — analyze the live branch without setting the divergent flag.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env context (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    ;; Calculate uniformity state of the condition
    (let ((cond-uniformity (calculate-uniformity-state cond-node env)))

      ;; Phase 1d: both branches will be analyzed → runtime divergence.  Bind
      ;; *in-divergent-conditional* to T for the branch analyses so that any
      ;; load-tile-at / store-tile-at inside either branch is rejected.
      ;;
      ;; Endeavor 138: ...but ONLY when the condition can actually diverge.  A
      ;; workgroup-UNIFORM condition takes every thread down the same branch, so an internal
      ;; sync-workgroup cannot deadlock and the tile op is safe.  We already compute
      ;; COND-UNIFORMITY and already trust it for *divergent-scope-depth* (right below); using
      ;; it here too is what makes this check's own advice ("use a non-divergent condition")
      ;; actually achievable — previously a uniform guard was rejected identically, which made
      ;; the guarded prefetch of a pipelined ring loop (`(when (< next-k n-k-steps) ...)`,
      ;; uniform in the K-loop counter) impossible to express.
      ;;
      ;; Endeavour 194: two levels.  A WARP-uniform condition takes whole warps down one branch:
      ;; barriers are refused inside (*in-divergent-conditional*), warp collectives are not
      ;; (*in-lane-divergent* stays clear).  Only a lane-divergent condition bumps the set! taint depth;
      ;; a warp-level scope taints through %194-current-level.
      (let* ((%194-lv (%194-level cond-uniformity))
             (*194-divergence-reason* (cl:cond ((eq %194-lv :uniform) *194-divergence-reason*)
                                               (*in-divergent-conditional* *194-divergence-reason*)
                                               ((eq %194-lv :warp-uniform) :warp-conditional)
                                               (t :conditional)))
             (*in-divergent-conditional* (or *in-divergent-conditional* (not (eq %194-lv :uniform))))
             (*in-lane-divergent* (or *in-lane-divergent* (eq %194-lv :divergent)))
             (*divergent-scope-depth* (if (eq %194-lv :divergent)
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
             (*194-loop-level* (%194-meet *194-loop-level* %194-lv))
             (then-node (analyze-expression (third expr) env context (append location '(2))))
             (else-node
               (cond
                 ((fourth expr)
                  (analyze-expression (fourth expr) env context (append location '(3))))
                 ;; BUG 092: a MISSING (or NIL) else is a false VALUE when THEN produces a scalar
                 ;; one -- CL semantics, where (if x y) means (if x y nil).  CL's AND expands to
                 ;; exactly (IF X Y), and the false path used to be left unstored.
                 ((%if-missing-else-is-false-p expr then-node)
                  (log:debug "BUG 092: missing/NIL else of a value IF analyzed as false (int 0): ~s" expr)
                  (make-semantic-literal :value-type 'int :value 0
                                         :source-location (append location '(3))))
                 (t nil))))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location))))))

;; src/analysis/control.lisp
(defun %analyze-dotimes-core (expr env context location)
  "Analyzes (dotimes (var limit [stride]) body...).
   VAR is bound as the limit's type (int, ulong, etc.) in the body.
   STRIDE is optional; defaults to literal 1 of the limit's type.
   Returns a semantic-dotimes node (type void).
   Endeavour 180: the CORE of analyze-dotimes-expression -- called with the body's leading declarations already
   stripped by %analyze-loop-with-unroll, which records the unroll request on the node."
  (unless (and (>= (length expr) 2) (listp (second expr)) (>= (length (second expr)) 2))
    (error 'crisp-compiler-error
      :message "Malformed dotimes: expected (dotimes (var limit [stride]) body...)"
      :source-location location))
  (let* ((binding (second expr))
         (var-name (first binding))
         (limit-form (second binding))
         (stride-form (third binding)) ;; NIL when omitted
         (body-forms (cddr expr))
         ;; Analyze limit
         (limit-node (analyze-expression limit-form env context (append location '(0))))
         (limit-type (get-single-value-type limit-node))
         (limit-ct (gethash limit-type *crisp-types*)))
    ;; Validate: limit must be a registered integer type
    (unless (and limit-ct (member (crisp-type-category limit-ct)
                                  '(:signed-int :unsigned-int)))
      (error 'crisp-compiler-error
        :message (format nil "dotimes limit must be an integer type, got ~a" limit-type)
        :source-location location))
    ;; Analyze stride if provided
    ;; Analyze stride if provided
    (let ((stride-node (when stride-form
                             (analyze-expression stride-form env context (append location '(0 1))))))
      ;; Endeavour 172: a literal stride of 0 (or negative) can never advance the loop variable
      ;; -- that is an unbounded loop, which Crisp forbids.  (A stride computed at runtime is
      ;; caught by the codegen guard instead: it runs ZERO iterations.)
      (when (and stride-node (semantic-literal-p stride-node)
                 (integerp (semantic-literal-value stride-node))
                 (< (semantic-literal-value stride-node) 1))
        (error 'crisp-compiler-error
          :message (format nil "dotimes: stride must be greater than 0, got ~a"
                           (semantic-literal-value stride-node))
          :source-location location))
      ;; Check uniformity
      (let* ((limit-uniformity (calculate-uniformity-state limit-node env))
             (stride-uniformity (if stride-node (calculate-uniformity-state stride-node env) :uniform))
             (bound-uniformity (%uniformity-join (list limit-uniformity stride-uniformity))))
        ;; Extend env: bind var as the limit's type, inheriting uniformity from the limit
        ;; Endeavour 194: a trip count that is not uniform divides threads exactly like a branch, so the
        ;; body is analysed in that scope -- barriers / collectives refused by level -- not only tainted.
        (let* ((body-env (cons (make-parameter-def :name var-name :type limit-type :kind :local :uniformity limit-uniformity) env))
               (body-nodes (%194-call-in-scope
                            bound-uniformity :loop-bound
                            (lambda ()
                              (analyze-body-expressions body-forms body-env context (append location '(1)))))))
          (make-semantic-dotimes :type 'void
                                 :var-name var-name
                                 :limit-node limit-node
                                 :stride-node stride-node
                                 :body body-nodes
                                 :source-location location))))))

;; src/analysis/control.lisp
(defun %analyze-loop-variant-core (expr env context location)
  "Analyzes every dotimes variant and its + form (endeavour 172):
     (dec-times            (i N [stride]) body...)    i = ((N-1)/s)*s ... 0, the exact reverse of dotimes
     (dec-times-by-half    (i N) body...)             i = N, N/2, ... 1
     (dec-times-by-factor  (i N factor) body...)      i = N, N/f, ... >= 1
     (do-times-by-doubling (i init N) body...)        i = init, 2*init, ... <= N
     (do-times-by-multiply (i init N factor) body...) i = init, init*f, ... <= N
     (do-power-step        (i N) body...)             i = 1, 2, 4, ... < N
     (dec-power-step       (i N) body...)             i = largest power of 2 below N, ... 1
   Operands must be unsigned (D2); literal gates per D3.  A + form requires every operand to
   be provably uniform (D5).  The loop variable takes N's type and the combined uniformity of
   all operands.  Returns a semantic-loop-variant.
   Endeavour 180: the CORE of analyze-loop-variant-expression -- called with the body's leading declarations already
   stripped by %analyze-loop-with-unroll, which records the unroll request on the node."
  (let* ((head (car expr))
         (head-name (symbol-name head))
         (plus-p (and (> (length head-name) 1)
                      (char= (cl:char head-name (1- (length head-name))) #\+)))
         (base-name (if plus-p (subseq head-name 0 (1- (length head-name))) head-name))
         (spec (find base-name *loop-variant-specs* :key #'first :test #'string-equal))
         (kind (second spec))
         (roles (third spec))
         (required (loop for r in roles until (eq r '&optional) collect r))
         (all-roles (remove '&optional roles))
         (binding (and (consp (cdr expr)) (second expr))))
    (unless spec
      (error 'crisp-compiler-error
             :message (format nil "Internal: no loop-variant spec for ~a" head-name)
             :source-location location))
    (unless (and (consp binding) (symbolp (first binding))
                 (<= (1+ (length required)) (length binding) (1+ (length all-roles))))
      (error 'crisp-compiler-error
             :message (format nil "Malformed ~(~a~): expected ~a"
                              head-name (%loop-variant-usage base-name roles))
             :source-location location))
    (let* ((var-name (first binding))
           (operand-forms (rest binding))
           (nodes (loop for form in operand-forms
                        for role in all-roles
                        for k from 1
                        collect (cons role (%analyze-loop-variant-operand
                                            form role base-name env context
                                            (append location (list 0 k))))))
           (n-node (cdr (assoc :n nodes)))
           (var-type (get-single-value-type n-node))
           (states (mapcar (lambda (p) (cons (car p) (calculate-uniformity-state (cdr p) env)))
                           nodes))
           ;; Endeavour 194: %uniformity-join, so warp-uniform operands give a warp-uniform loop.
           (combined (%uniformity-join (mapcar #'cdr states))))
      (log:debug "~a: kind ~s, var ~a : ~a, operand uniformity ~s" head-name kind var-name var-type states)
      (when plus-p
        (let ((bad (find-if-not (lambda (s) (eq (cdr s) :uniform)) states)))
          (when bad
            (error 'crisp-compiler-error
                   :message (format nil "~(~a~) requires every operand to be provably uniform; ~a is ~(~a~).~@[ ~a~]"
                                    head-name (%loop-variant-role-name (car bad)) (cdr bad)
                                    (when (eq (cdr bad) :unknown)
                                      "Use (declare (uniform ...)) if it is uniform."))
                   :source-location location))))
      (let* ((body-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                 :uniformity combined)
                             env))
             ;; Endeavour 194: analysed in the scope its operands give it, like dotimes.
             (body-nodes (%194-call-in-scope
                          combined :loop-bound
                          (lambda ()
                            (analyze-body-expressions (cddr expr) body-env context (append location '(1)))))))
        (make-semantic-loop-variant :type 'void
                                    :var-name var-name
                                    :var-type var-type
                                    :kind kind
                                    :limit-node n-node
                                    :stride-node (cdr (assoc :stride nodes))
                                    :init-node (cdr (assoc :init nodes))
                                    :factor-node (cdr (assoc :factor nodes))
                                    :body body-nodes
                                    :source-location location)))))

;; src/analysis/core.lisp
(defun calculate-uniformity-state (node env)
  "Recursively determines the uniformity state of an analyzed semantic AST node.
   Returns :uniform, :warp-uniform (Endeavour 194), :divergent, or :unknown.
   - Literals are :uniform.
   - Variables are looked up in the env for their stored uniformity. If env lookup
     fails or missing, defaults to :unknown. Kernel arguments are initialized to :uniform.
   - GPU Builtins: per-work-item ids (get-global-id/get-local-id/*-linear-id/
     get-global-id-abs) are :divergent; ids/sizes/offsets constant across the
     workgroup (get-workgroup-id, get-num-groups, get-*-work-size, get-global-offset,
     get-work-dim, get-*-linear-size, get-total-*) are :uniform.
   - Math operations (add, sub, mul, etc): if all args are :uniform, it is :uniform.
     If any arg is :divergent, it is :divergent. Otherwise :unknown.
   - Casts/conversions (to-*, as-*) are passthrough: same uniformity as the operand.
   - Memory reads (aref) are :divergent (or :unknown) unless explicitly cast."
  (etypecase node
    (semantic-literal :uniform)
    ;; Endeavor 132 (MMA): the accumulator fragment is per-lane (warp-distributed), so
    ;; the MMA result is divergent.
    (semantic-mma-accumulate :divergent)
    ;; Endeavor 133 (MMA on SPV): a cooperative-matrix op is subgroup-collective -> divergent.
    (semantic-coop-op :divergent)
    ;; Endeavor 132 (MMA) F2: a multi-value pack is as uniform as its least-uniform member.
    (semantic-values
     (%uniformity-of-all (semantic-values-value-nodes node) env))
    (semantic-device-vec-literal
     (%uniformity-of-all (semantic-device-vec-literal-elements node) env))
    (semantic-var-read
     (let ((v (find-variable-in-env (semantic-var-read-name node) env)))
       (if v
           (parameter-def-uniformity v)
           :unknown)))
    (semantic-add
     (%uniformity-of-all (list (semantic-add-left-arg node) (semantic-add-right-arg node)) env))
    (semantic-sub
     (%uniformity-of-all (list (semantic-sub-left-arg node) (semantic-sub-right-arg node)) env))
    (semantic-mul
     (%uniformity-of-all (list (semantic-mul-left-arg node) (semantic-mul-right-arg node)) env))
    ;; Endeavour 194 (D-194-15): (/ tid K) is WARP-uniform when tid is the local thread index of a 1-D
    ;; workgroup and the warp size divides K -- "warp 0 does X" written as (= (/ tid 32ul) 0ul).
    (semantic-div
     (if (%194-warp-index-division-p node)
         :warp-uniform
         (%uniformity-of-all (list (semantic-div-left-arg node) (semantic-div-right-arg node)) env)))
    (semantic-sin
     (calculate-uniformity-state (semantic-sin-arg node) env))
    (semantic-cos
     (calculate-uniformity-state (semantic-cos-arg node) env))
    ;; Endeavor 128: transcendentals. Unary intrinsics are passthrough on
    ;; uniformity; the binary ones combine both operands like mul/div.
    (semantic-exp  (calculate-uniformity-state (semantic-exp-arg node) env))
    (semantic-log  (calculate-uniformity-state (semantic-log-arg node) env))
    (semantic-log2 (calculate-uniformity-state (semantic-log2-arg node) env))
    (semantic-tan  (calculate-uniformity-state (semantic-tan-arg node) env))
    (semantic-asin (calculate-uniformity-state (semantic-asin-arg node) env))
    (semantic-acos (calculate-uniformity-state (semantic-acos-arg node) env))
    (semantic-atan (calculate-uniformity-state (semantic-atan-arg node) env))
    (semantic-pow
     (%uniformity-of-all (list (semantic-pow-left-arg node) (semantic-pow-right-arg node)) env))
    (semantic-atan2
     (%uniformity-of-all (list (semantic-atan2-left-arg node) (semantic-atan2-right-arg node)) env))
    ;; Endeavour 170: a hardware math op combines its arguments exactly like arithmetic --
    ;; divergent if any argument is, uniform only if all of them are.
    (semantic-hw-op
     (%uniformity-of-all (semantic-hw-op-args node) env))
    ;; Endeavor 120: casts/conversions (to-*, as-*) are passthrough. Covers all
    ;; semantic-cast subtypes (value-cast, bitcast, fp-truncate-cast, truncate).
    (semantic-cast
     (calculate-uniformity-state (semantic-cast-arg node) env))
    ((or semantic-lt semantic-gt semantic-le semantic-ge semantic-eq semantic-neq)
     (%uniformity-of-all (list (slot-value node 'left-arg) (slot-value node 'right-arg)) env))
    (semantic-if
     (%uniformity-of-all (list (semantic-if-condition-node node) (semantic-if-then-node node)
                               (semantic-if-else-node node))
                         env))
    ;; Endeavour 194: a let used as a VALUE (ANF wraps --differentiate's expressions this way) is as uniform
    ;; as its last body form, with each binding as uniform as its init.  It was a flat :unknown, which made
    ;; every tile-stride bound in a _GRAD kernel non-uniform once loop bounds started to count.
    (semantic-let
     (let ((e env))
       (dolist (b (semantic-let-bindings node))
         (when (and (consp b) (car b) (symbolp (car b)) (cdr b))
           (push (make-parameter-def :name (car b) :kind :local
                                     :uniformity (calculate-uniformity-state (cdr b) e))
                 e)))
       (let ((last-form (car (last (semantic-let-body node)))))
         (if last-form (calculate-uniformity-state last-form e) :unknown))))
    (semantic-gpu-builtin
     (let ((name (semantic-gpu-builtin-builtin-name node)))
       (cond
         ;; Per-work-item: differ across the workgroup.
         ((member name '(:get-global-id :get-local-id :get-global-id-abs
                         :get-local-linear-id :get-global-linear-id))
          :divergent)
         ;; Constant across the workgroup: ids/sizes/offsets/dims/totals.
         ((member name '(:get-workgroup-id :get-num-groups
                         :get-local-work-size :get-global-work-size
                         :get-global-offset :get-work-dim
                         :get-local-linear-size :get-global-linear-size
                         :get-total-threads :get-total-groups))
          :uniform)
         ;; Endeavour 194: the warp (sub-group) index is shared by every lane of a warp.
         ((eq name :warp-id) :warp-uniform)
         (t :unknown))))
    (semantic-to-workgroup-uniform :uniform)
    ;; Endeavour 194: a warp broadcast makes a value uniform across its WARP only.
    (semantic-to-warp-uniform :warp-uniform)
    ;; Endeavor 124: a memory read (~ src [idx]) is UNIFORM when every thread reads
    ;; the same location — a uniform storage handle at a uniform index. The common
    ;; case is a whole-cell read (~ x) of a scalar kernel-input cell: x's handle is
    ;; a uniform kernel arg and the index is the literal 0. This lets such a value
    ;; be used as an if+ condition / uniform sub-fn arg without a (declare (uniform))
    ;; assertion. Conservative: only the :uniform case is asserted; every other read
    ;; stays :unknown (as before), so no NEW :divergent flags are introduced.
    (semantic-aref
     (let ((as (calculate-uniformity-state (semantic-aref-array-node node) env))
           (is (calculate-uniformity-state (semantic-aref-index-node node) env)))
       (if (and (eq as :uniform) (eq is :uniform))
           :uniform
           :unknown)))
    ;; Endeavour 194: a struct is as uniform as its fields, and a field as its struct.  Kernel entry
    ;; re-binds every storage-handle parameter as a struct built from its (uniform) NAME_PTR / extents /
    ;; strides arguments, so without these a kernel's own tensor read as :unknown -- and with it every
    ;; extent, and the hidden loop of every tile-stride (D-194-5 fallout).
    (semantic-struct-construction
     (%uniformity-of-all (semantic-struct-construction-args node) env))
    (semantic-extract-value
     (calculate-uniformity-state (semantic-extract-value-aggregate-node node) env))
    (semantic-ct-array
     (%uniformity-of-all (semantic-ct-array-val-nodes node) env))
    ;; Endeavour 194: a view (make-matrix / make-vector / ... over a handle) is as uniform as its source
    ;; and whichever of its offset / length / extents / strides are runtime NODES (literals are fixed).
    (semantic-make-view
     (flet ((nodes (x) (remove-if-not (lambda (v) (typep v 'structure-object))
                                      (if (listp x) x (list x)))))
       (%uniformity-of-all (append (list (semantic-make-view-source-node node))
                                   (nodes (semantic-make-view-offset node))
                                   (nodes (semantic-make-view-offset-node node))
                                   (nodes (semantic-make-view-length node))
                                   (nodes (semantic-make-view-extents node))
                                   (nodes (semantic-make-view-strides node)))
                           env)))
    ;; Endeavour 194 (D3): a shuffle FROM one lane every lane names, across the whole warp, hands every
    ;; lane the same value.
    (semantic-shuffle
     (let ((iu (calculate-uniformity-state (semantic-shuffle-index node) env)))
       (if (and (eq (semantic-shuffle-op node) :idx)
                (member iu '(:uniform :warp-uniform))
                (>= (semantic-shuffle-width node) (%173-warp-size)))
           (if (eq (calculate-uniformity-state (semantic-shuffle-value node) env) :uniform)
               :uniform
               :warp-uniform)
           :unknown)))
    ;; Endeavour 194 (D3): a call is as uniform as every return its callee executes -- its summary,
    ;; which does not depend on the arguments.  :unknown for a callee not compiled yet.
    ;; A generated ACCESSOR (EXTENTS~, LENGTH~, ~OFFSET~ ...) is a pure function of the storage handle,
    ;; so it is exactly as uniform as its arguments: (~ (extents~ T) 0) of a kernel argument is :uniform,
    ;; which is what makes tile-stride's hidden loop provably uniform (D-194-5 fallout).
    (semantic-call
     (let ((key (%194-summary-key (semantic-call-name node))))
       (if (and (plusp (length key)) (char= (cl:char key (1- (length key))) #\~))
           (%uniformity-of-all (semantic-call-args node) env)
           (%194-summary-result (gethash key *194-function-summaries*)))))
    ;; Memory reads and anything else
    (t :unknown)))

;; src/codegen.lisp
(defun %194-workgroup-slot (module llvm-type)
  "Endeavour 194 (F7): a fresh workgroup-memory (addrspace 3) global of LLVM-TYPE for one
   to-workgroup-uniform site -- `.shared` on PTX, a Workgroup OpVariable on SPIR-V.  Internal and undef:
   workgroup memory has no initializer on either target, and the slot is always written before it is read."
  (let ((name (loop for i from 0
                    for n = (format nil "__crisp_wgu_~d" i)
                    when (cffi:null-pointer-p (crisp.llvm-bindings::llvm-get-named-global module n))
                      return n)))
    (let ((g (crisp.llvm-bindings::llvm-add-global-in-addrspace module llvm-type name 3)))
      (crisp.llvm-bindings::llvm-set-linkage g 8) ; LLVMInternalLinkage
      (crisp.llvm-bindings::llvm-set-initializer g (crisp.llvm-bindings::llvm-get-undef llvm-type))
      (crisp.llvm-bindings::llvm-set-alignment g 16)
      (log:debug "194: workgroup broadcast slot ~a" name)
      g)))

;; src/codegen.lisp
(defun %194-workgroup-barrier (builder module)
  "Endeavour 194: a workgroup barrier on the current target."
  (if (eq *target-backend* :ptx)
      (%ptx-barrier builder module)
      (%gen-spirv-control-barrier builder module)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-to-workgroup-uniform) builder module var-env di-builder di-scope location-map)
  "Emits IR to make a value uniform across the workgroup.
   Endeavour 194 (F7) -- the broadcast ideal_001 specifies (it used to be a barrier and a pass-through,
   which left a per-thread value labelled uniform):
     barrier                  -- a previous pass through this site (a loop) has finished reading the slot
     if local id == 0: slot <- X
     barrier                  -- the store is visible
     every thread: X <- slot
   Two barriers always: the cost the doc warns of.  (declare (uniform x)) is the free assertion."
  (let* ((val-node (semantic-to-workgroup-uniform-value-node node))
         (val (generate-node-ir val-node builder module var-env di-builder di-scope location-map))
         (llvm-ty (crisp.llvm-bindings::llvm-type-of val))
         (slot (%194-workgroup-slot module llvm-ty))
         (lid (generate-node-ir (make-semantic-gpu-builtin :builtin-name :get-local-linear-id
                                                           :dimension nil :type 'ulong)
                                builder module var-env di-builder di-scope location-map))
         (is0 (crisp.llvm-bindings::llvm-build-icmp
               builder +llvm-int-eq+ lid
               (crisp.llvm-bindings::llvm-const-int (crisp.llvm-bindings::llvm-type-of lid) 0 nil)
               "wgu_is0"))
         (fn (crisp.llvm-bindings::llvm-get-basic-block-parent
              (crisp.llvm-bindings::llvm-get-insert-block builder)))
         (bb-store (crisp.llvm-bindings::llvm-append-basic-block fn "wgu_store"))
         (bb-join (crisp.llvm-bindings::llvm-append-basic-block fn "wgu_join")))
    (%194-workgroup-barrier builder module)
    (crisp.llvm-bindings::llvm-build-cond-br builder is0 bb-store bb-join)
    (crisp.llvm-bindings::llvm-position-builder-at-end builder bb-store)
    (crisp.llvm-bindings::llvm-build-store builder val slot)
    (crisp.llvm-bindings::llvm-build-br builder bb-join)
    (crisp.llvm-bindings::llvm-position-builder-at-end builder bb-join)
    (%194-workgroup-barrier builder module)
    (values (crisp.llvm-bindings::llvm-build-load2 builder llvm-ty slot "wgu_val") nil)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-to-warp-uniform) builder module var-env di-builder di-scope location-map)
  "Emits IR to make a value uniform across the warp.
   Endeavour 194 (F7) -- the broadcast ideal_001 specifies (it used to be a __syncwarp and a
   pass-through): every lane takes LANE 0's value with a full-width index shuffle.  Floats ride the
   integer path by bitcast and 64-bit values are split, exactly as a user shuffle (173 D9).  The
   analyser admits only *shuffle-value-types*."
  (let* ((ty (resolve-type-alias (semantic-to-warp-uniform-type node)))
         (val (generate-node-ir (semantic-to-warp-uniform-value-node node)
                                builder module var-env di-builder di-scope location-map))
         (i32 (crisp.llvm-bindings::llvm-int32-type))
         (i64 (crisp.llvm-bindings::llvm-int64-type))
         (lane0 (crisp.llvm-bindings::llvm-const-int i32 0 nil))
         (width (%173-warp-size)))
    (log:debug "194 codegen to-warp-uniform: ty=~a width=~a backend=~a" ty width *target-backend*)
    (values
     (ecase ty
       ((int uint)
        (%shuffle-emit-i32 builder module :idx val lane0 width))
       ((float)
        (let* ((bits (crisp.llvm-bindings::llvm-build-bit-cast builder val i32 "wu_fbits"))
               (res (%shuffle-emit-i32 builder module :idx bits lane0 width)))
          (crisp.llvm-bindings::llvm-build-bit-cast builder res (resolve-type-to-llvm 'float) "wu_fval")))
       ((long ulong)
        (%shuffle-emit-i64 builder module :idx val lane0 width))
       ((double)
        (let* ((bits (crisp.llvm-bindings::llvm-build-bit-cast builder val i64 "wu_dbits"))
               (res (%shuffle-emit-i64 builder module :idx bits lane0 width)))
          (crisp.llvm-bindings::llvm-build-bit-cast builder res (resolve-type-to-llvm 'double) "wu_dval"))))
     nil)))
