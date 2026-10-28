;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
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

;;;; ===================================================================================================
;;;; Endeavour 195 -- atomic-load / atomic-store!  (tests/spec/195-atomic-load/atomic-load.md)
;;;;
;;;; Fold-back map:
;;;;   * analyzers  -> %195-check-atomic-access-elem, %195-check-arity, %195-analyze-atomic-place,
;;;;                   %195-check-store-value-type, analyze-atomic-load-expression,
;;;;                   analyze-atomic-store!-expression, register-195-atomic-access-analyzers
;;;;                   (src/analysis/ops.lisp, after analyze-atomic-set!-expression); the wrapper on
;;;;                   register-ops-analyzers folds as ONE call, (register-195-atomic-access-analyzers),
;;;;                   at the end of register-ops-analyzers -- drop the defvar.
;;;;   * ANF        -> *anf-atomic-op-names* (src/anf-transform.lisp): two names added.
;;;;   * codegen    -> %195-build-atomic-load / -store (src/codegen.lisp, after %184-device-sync-scope);
;;;;                   generate-node-ir semantic-atomic-rmw REPLACED (the :load / :store CASE).
;;;;   * AD         -> %ad-replay-fill-targets, %ad-replay-read-syms REPLACED ("ATOMIC-STORE!" in the
;;;;                   write list); %195-* VJP helpers + their register-vjp block (src/autodiff.lisp,
;;;;                   after the 175 atomic rules); the wrapper on generate-backward-walk folds as a
;;;;                   LET of *195-ad-param-types* around its body -- drop the defvar.
;;;;   * semantic   -> docstring of semantic-atomic-rmw (src/semantic.lisp): ops :load / :store.
;;;;   * bindings   -> LLVMSetAtomicSyncScopeID (overlays/crisp-llvm-bindings-overlay.lisp)
;;;; ===================================================================================================

;; src/analysis/ops.lisp
(defun %195-check-atomic-access-elem (op-name elem-type location)
  "Endeavour 195 D-195-4.  Refuse an atomic-load / atomic-store! whose element is not a 32- or 64-bit
   scalar -- int, uint, long, ulong, float or double.  An atomic load or store is one machine word."
  (multiple-value-bind (category bits lanes) (%hw-type-parts elem-type)
    (log:debug "195 ~a: element ~s -> category ~s, ~s bits, lanes ~s" op-name elem-type category bits lanes)
    (unless (and category (null lanes) (member bits '(32 64)))
      (error 'crisp-type-error
             :message (format nil "~a: the element type ~(~a~) is not a 32- or 64-bit scalar.  An atomic load or store moves one indivisible machine word: int, uint, long, ulong, float or double.  8- and 16-bit types are refused because the SPIR-V lowering would need 16-bit atomic extensions the PTX one does not, and a device vector or a struct is more than one word"
                              op-name elem-type)
             :source-location location))))

;; src/analysis/ops.lisp
(defun %195-check-arity (op-name expr expected location)
  "Endeavour 195.  EXPR must have exactly EXPECTED arguments."
  (let ((actual (1- (length expr))))
    (unless (= actual expected)
      (error 'crisp-type-error
             :message (format nil "~a: expected ~a argument~:p, got ~a" op-name expected actual)
             :source-location location))))

;; src/analysis/ops.lisp
(defun %195-analyze-atomic-place (op-name expr env context location)
  "Endeavour 195.  Analyse the PLACE of an atomic-load / atomic-store! (EXPR's second element) and
   return its semantic-aref.

   The place is analysed in WRITE access mode for BOTH operators (D-195-9).  A plain read of an &out
   parameter is refused, and every atomic RMW is exempt from that because it analyses its place in
   write mode.  The arrays a kernel publishes into and polls are its &outs, so atomic-load needs the
   same exemption or it could not replace an (atomic-add! place 0) poll."
  (let* ((target-form (second expr))
         (target-node (let ((*analysis-access-mode* :write))
                        (analyze-expression target-form env context (append location '(1))))))
    (unless (semantic-aref-p target-node)
      (error 'crisp-type-error
             :message (format nil "~a: target must be a memory location like (~~ vec idx), got ~a"
                              op-name target-form)
             :source-location location))
    (%195-check-atomic-access-elem op-name (semantic-aref-type target-node) location)
    target-node))

;; src/analysis/ops.lisp
(defun %195-check-store-value-type (target-node value-node location)
  "Endeavour 195.  atomic-store! obeys set!'s element rule (186, BUG 059): an element holds exactly its
   own type.  Reuses %check-element-store-type and renames the operator in its message."
  (handler-case (%check-element-store-type target-node value-node location)
    (crisp-type-error (e)
      (let ((msg (type-error-message e)))
        (error 'crisp-type-error
               :message (if (and (stringp msg) (eql 0 (search "set!:" msg)))
                            (concatenate 'string "atomic-store!:" (subseq msg 5))
                            msg)
               :source-location location)))))

;; src/analysis/ops.lisp
(defun analyze-atomic-load-expression (expr env context location)
  "Analyzes (atomic-load place) -- endeavour 195.  A RELAXED, DEVICE-scope atomic read of PLACE that
   returns its value.  Not a read-modify-write: PTX ld.relaxed.gpu, SPIR-V OpAtomicLoad.  Represented
   as a semantic-atomic-rmw with op :load and no delta (D-195-5)."
  (%195-check-arity "atomic-load" expr 1 location)
  (let ((target (%195-analyze-atomic-place "atomic-load" expr env context location)))
    (log:debug "195 atomic-load of a ~s element" (semantic-aref-type target))
    (make-semantic-atomic-rmw :type (semantic-aref-type target)
                              :op :load
                              :target-node target
                              :delta-node nil
                              :source-location location)))

;; src/analysis/ops.lisp
(defun analyze-atomic-store!-expression (expr env context location)
  "Analyzes (atomic-store! place value) -- endeavour 195.  A RELAXED, DEVICE-scope atomic write of
   VALUE to PLACE.  Not an exchange (that is atomic-xchg!): its type is void, like set! (D-195-3).
   PTX st.relaxed.gpu, SPIR-V OpAtomicStore.  A semantic-atomic-rmw with op :store; the value rides
   in the delta slot."
  (%195-check-arity "atomic-store!" expr 2 location)
  (let* ((target     (%195-analyze-atomic-place "atomic-store!" expr env context location))
         (value-node (analyze-expression (third expr) env context (append location '(2)))))
    (%195-check-store-value-type target value-node location)
    (log:debug "195 atomic-store! into a ~s element" (semantic-aref-type target))
    (make-semantic-atomic-rmw :type 'void
                              :op :store
                              :target-node target
                              :delta-node value-node
                              :source-location location)))

;; src/analysis/ops.lisp
(defun register-195-atomic-access-analyzers ()
  "Endeavour 195.  Registers atomic-load / atomic-store! under both packages, like the 082 atomics."
  (def-expression-analyzer atomic-load   analyze-atomic-load-expression)
  (def-expression-analyzer atomic-store! analyze-atomic-store!-expression)
  (let ((lang (find-package :crisp-language)))
    (when lang
      (dolist (pair '(("ATOMIC-LOAD"   analyze-atomic-load-expression)
                      ("ATOMIC-STORE!" analyze-atomic-store!-expression)))
        (setf (gethash (intern (first pair) lang) *expression-analyzers*)
              (second pair))))))

;; src/analysis/ops.lisp  (WRAPPER -- folds as one call at the end of register-ops-analyzers)
(defvar *195-orig-register-ops-analyzers* (fdefinition 'register-ops-analyzers))
(defun register-ops-analyzers ()
  "Endeavour 195 wrapper: the original registrations, then atomic-load / atomic-store!."
  (funcall *195-orig-register-ops-analyzers*)
  (register-195-atomic-access-analyzers))

;; src/anf-transform.lisp
(defparameter *anf-atomic-op-names*
  '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
    "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!"
    ;; Endeavour 175 -- see the header above anf-normalize.
    "ATOMIC-CAS!" "%ATOMIC-CAS-OK!" "ATOMIC-BINOP!" "ATOMIC-OP!"
    ;; Endeavour 195 -- place-taking too: flattening the place would turn the atomic load into a
    ;; plain one and hand atomic-load a temp.
    "ATOMIC-LOAD" "ATOMIC-STORE!")
  "The place-taking atomic operators, normalized by %anf-normalize-atomic.")

;; src/codegen.lisp
(defun %195-atomic-alignment (elem-type)
  "Endeavour 195.  The byte alignment of an atomic access to an ELEM-TYPE element (its own size).  LLVM
   requires an explicit alignment on every atomic load and store."
  (let ((bits (nth-value 1 (%hw-type-parts elem-type))))
    (if bits (floor bits 8) 4)))

;; src/codegen.lisp
(defun %195-make-relaxed-device (inst module elem-type)
  "Endeavour 195.  Turn the plain load / store INST into an atomic one: monotonic (relaxed) at the
   \"device\" sync scope -- the 184 rule -- aligned to its own size."
  (llvm-set-ordering inst 2)                                   ; LLVMAtomicOrderingMonotonic
  (crisp.llvm-bindings::llvm-set-atomic-sync-scope-id inst (%184-device-sync-scope module))
  (crisp.llvm-bindings::llvm-set-alignment inst (%195-atomic-alignment elem-type))
  inst)

;; src/codegen.lisp
(defun %195-build-atomic-load (builder module ptr llvm-type elem-type)
  "Endeavour 195.  `load atomic LLVM-TYPE, PTR syncscope(\"device\") monotonic` -- atomic-load."
  (log:debug "195 atomic-load: ~a element" elem-type)
  (%195-make-relaxed-device (llvm-build-load2 builder llvm-type ptr "atomic_load") module elem-type))

;; src/codegen.lisp
(defun %195-build-atomic-store (builder module ptr val elem-type)
  "Endeavour 195.  `store atomic VAL, PTR syncscope(\"device\") monotonic` -- atomic-store!."
  (log:debug "195 atomic-store!: ~a element" elem-type)
  (%195-make-relaxed-device (llvm-build-store builder val ptr) module elem-type))

;; src/codegen.lisp  (REPLACES the method -- the :load / :store CASE is the only change)
(defmethod generate-node-ir ((node semantic-atomic-rmw) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for atomic RMW operations (atomic-add!, atomic-sub!, etc.).
Returns the old value at the target location (fetch-and-op semantics).
LLVM AtomicRMWBinOp enum: xchg=0 add=1 sub=2 max=7 min=8 umax=9 umin=10
                           fadd=11 fsub=12 fmax=13 fmin=14
Endeavour 184: RELAXED (monotonic) at DEVICE scope -- see %184-device-sync-scope.  Ordering is
never implied by an atomic; it comes only from an explicit mem-fence.
Endeavour 195: op :load (atomic-load) and :store (atomic-store!) ride on this node too (D-195-5); they
become `load atomic` / `store atomic`, built by %195-build-atomic-load / -store, at the same order and scope."
  (let* ((target-aref     (semantic-atomic-rmw-target-node node))
         (delta-node      (semantic-atomic-rmw-delta-node node))
         (op              (semantic-atomic-rmw-op node))
         (elem-type       (semantic-atomic-rmw-type node))
         (elem-crisp-type (gethash elem-type *crisp-types*))
         (is-float        (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :float)))
         (is-unsigned     (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :unsigned-int))))

    ;; Get the GEP pointer from the target aref (3rd return value)
    (multiple-value-bind (aref-val aref-loc ptr)
        (generate-node-ir target-aref builder module var-env di-builder di-scope location-map)
      (declare (ignore aref-loc))
      (unless ptr
        (error "Compiler error in atomic ~(~a~): target ~a did not produce an address pointer"
               op target-aref))
      ;; Endeavour 195: atomic-load / atomic-store! -- no RMW opcode, no delta to combine.  The aref's
      ;; own plain load (AREF-VAL) is dead; it is used only for its LLVM type.
      (case op
        (:load
         (return-from generate-node-ir
           (values (%195-build-atomic-load builder module ptr (llvm-type-of aref-val)
                                           (semantic-aref-type target-aref))
                   nil)))
        (:store
         (let* ((store-type (semantic-aref-type target-aref))
                (raw (generate-node-ir delta-node builder module var-env di-builder di-scope location-map))
                (val (extract-primary-value builder raw store-type)))
           (%195-build-atomic-store builder module ptr val store-type)
           (return-from generate-node-ir (values val nil)))))

      ;; Compute the delta value
      (let* ((delta-raw (generate-node-ir delta-node builder module var-env
                                          di-builder di-scope location-map))
             (delta-val (extract-primary-value builder delta-raw elem-type))
             ;; Select the LLVM RMW opcode
             ;; Inline integer literals avoid defconstant redefinition issues in overlays.
             (rmw-op (ecase op
                       (:add  (if is-float 11 1))   ;; fadd=11, add=1
                       (:sub  (if is-float 12 2))   ;; fsub=12, sub=2
                       (:min  (cond (is-float 14)   ;; fmin=14
                                    (is-unsigned 10) ;; umin=10
                                    (t 8)))          ;; min=8 (signed)
                       (:max  (cond (is-float 13)   ;; fmax=13
                                    (is-unsigned 9)  ;; umax=9
                                    (t 7)))          ;; max=7 (signed)
                       (:xchg 0))))                 ;; xchg=0

        (log:info "atomic-rmw: op=~a elem-type=~a is-float=~a is-unsigned=~a rmw-op=~a"
                  op elem-type is-float is-unsigned rmw-op)

        (let ((result (crisp.llvm-bindings::llvm-build-atomic-rmw-sync-scope
                       builder rmw-op ptr delta-val
                       2  ;; Endeavour 184: LLVMAtomicOrderingMonotonic (relaxed)
                       (%184-device-sync-scope module))))
          (values result nil))))))


;; src/autodiff.lisp  (REPLACES -- "ATOMIC-STORE!" added to the write list)
(defun %ad-replay-fill-targets (form)
  "Symbols FORM writes through an INDEXED or whole-tile store, at any depth.

   These are the writes that can FILL a tile, so this drives slice selection; it is
   also what decides observability, since an indexed write to something that is not
   scratch is a write to memory somebody else can see.

   Bare `(set! SYM v)` is deliberately NOT collected here -- an ANF scalar temp is
   assigned constantly and none of it is observable.  Scalar writes are checked
   separately, and only against the &out list."
  (let ((acc nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((op (and (symbolp (car f)) (symbol-name (car f)))))
                   (cond
                     ((and op (member op '("SET!" "ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-MIN!"
                                           "ATOMIC-MAX!" "ATOMIC-EXCHANGE!" "ATOMIC-CAS!"
                                           "%ATOMIC-CAS-OK!" "ATOMIC-BINOP!" "ATOMIC-OP!"
                                           ;; Endeavour 195
                                           "ATOMIC-STORE!")
                                      :test #'string=))
                      (let ((s (%ad-replay-place-sym (second f))))
                        (when s (pushnew s acc))))
                     ;; (store-tile SRC DST ...) / (store-tile-at SRC DST ...)
                     ((and op (member op '("STORE-TILE" "STORE-TILE-AT") :test #'string=))
                      (let ((dst (third f)))
                        (cond ((symbolp dst) (when dst (pushnew dst acc)))
                              (t (let ((s (%ad-replay-place-sym dst)))
                                   (when s (pushnew s acc)))))))
                     ((and op (string= op "FILL-TILE"))
                      (let ((dst (second f)))
                        (when (symbolp dst) (pushnew dst acc)))))
                   ;; Descend into EVERY element, the head included.  Not (cdr f):
                   ;; a LET's binding list is itself a list whose CAR is the first
                   ;; binding, so skipping cars makes single-binding LETs -- which is
                   ;; what ANF produces constantly -- invisible to the walk.
                   (loop for sub = f then (cdr sub)
                         while (consp sub)
                         do (walk (car sub)))))))
      (walk form))
    acc))


;; src/autodiff.lisp  (REPLACES -- "ATOMIC-STORE!" added to the write list)
(defun %ad-replay-read-syms (form)
  "Symbols FORM READS, at any depth: the operand of `(~ SYM ...)` other than in a write
   place, and the SOURCE operand of load-tile / load-tile-at.

   The write place is skipped deliberately -- `(set! (~ D i) v)` reads nothing from D,
   and counting it would make every fill look like a read of its own destination."
  (let ((acc nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((op (and (symbolp (car f)) (symbol-name (car f)))))
                   (cond
                     ;; a write: skip the place, walk only the value operands
                     ((and op (member op '("SET!" "ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-MIN!"
                                           "ATOMIC-MAX!" "ATOMIC-EXCHANGE!" "ATOMIC-CAS!"
                                           "%ATOMIC-CAS-OK!" "ATOMIC-BINOP!" "ATOMIC-OP!"
                                           ;; Endeavour 195
                                           "ATOMIC-STORE!")
                                      :test #'string=))
                      ;; an index expression inside the place IS read; walk the place's
                      ;; subscripts but not its head symbol.
                      (when (consp (second f))
                        (dolist (idx (cddr (second f))) (walk idx)))
                      (dolist (sub (cddr f)) (walk sub)))
                     ((and op (member op '("LOAD-TILE" "LOAD-TILE-AT") :test #'string=))
                      (when (symbolp (second f)) (pushnew (second f) acc))
                      (dolist (sub (cdr f)) (walk sub)))
                     (t
                      (when (and op (string= op "~") (symbolp (second f)) (second f))
                        (pushnew (second f) acc))
                      ;; every element, head included.  This one is why rung 07 was
                      ;; missed at first: the read that made the slice unreplayable was
                      ;; `(%anf-t-N (~ D i))`, the sole binding of a LET, and a walk that
                      ;; skipped cars never saw it.  The kernel compiled, and the wrong
                      ;; gradient it would have produced was the exact silent failure the
                      ;; check exists to prevent.
                      (loop for sub = f then (cdr sub)
                            while (consp sub)
                            do (walk (car sub)))))))))
      (walk form))
    acc))


;; src/autodiff.lisp
(defvar *195-ad-param-types* nil
  "Endeavour 195.  Alist (PARAM-SYM . TYPE-SPEC) of the kernel being differentiated, bound around
   generate-backward-walk so a VJP can ask a place's element type (the VJP context carries none).")

;; src/autodiff.lisp  (WRAPPER -- folds as a LET of *195-ad-param-types* around the body)
(defvar *195-orig-generate-backward-walk* (fdefinition 'generate-backward-walk))
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types &key kernel-pkg)
  "Endeavour 195 wrapper: publishes the kernel's parameter types for the atomic-store! VJP."
  (let ((*195-ad-param-types* (append (mapcar #'cons inputs input-types)
                                      (mapcar #'cons outputs output-types))))
    (funcall *195-orig-generate-backward-walk* flat-anf inputs outputs input-types output-types
             :kernel-pkg kernel-pkg)))

;; src/autodiff.lisp
(defun %195-elem-category-of-type (type-spec)
  "Endeavour 195.  :INTEGER or :FLOAT for the element of a storage-handle (or bare scalar) TYPE-SPEC,
   else NIL."
  (let* ((canonical (ignore-errors (canonicalize-type-specifier type-spec)))
         (elem (cond ((and (consp canonical) (symbolp (first canonical))
                           (member (symbol-name (first canonical)) '("TENSOR" "CELL") :test #'string-equal))
                      (second canonical))
                     ((symbolp type-spec) type-spec)))
         (info (and elem (symbolp elem)
                    (or (gethash elem *crisp-types*)
                        (let ((cc (find-symbol (symbol-name elem) :crisp.compiler)))
                          (and cc (gethash cc *crisp-types*)))))))
    (and info (case (crisp-type-category info)
                ((:signed-int :unsigned-int) :integer)
                (:float :float)))))

;; src/autodiff.lisp
(defun %195-place-elem-category (place ctx)
  "Endeavour 195.  :INTEGER / :FLOAT for the element of PLACE ((~ SYM ...)), from the kernel's
   parameter types or, for scratch, the element type named by SYM's make-scratch-* binding in the
   flat ANF.  NIL when it cannot tell."
  (let ((sym (%ad-replay-place-sym place)))
    (when sym
      (let ((param (assoc sym *195-ad-param-types*)))
        (if param
            (%195-elem-category-of-type (cdr param))
            (let ((binding (find-if (lambda (b)
                                      (and (consp b) (eq (first b) sym) (consp (second b))
                                           (symbolp (first (second b)))
                                           (eql 0 (search "MAKE-SCRATCH-" (symbol-name (first (second b)))))))
                                    (getf ctx :flat-anf))))
              (and binding (%195-elem-category-of-type (second (second binding))))))))))

;; src/autodiff.lisp
(defun %195-vjp-atomic-load (form ctx)
  "Backward rule for atomic-load (endeavour 195, D-195-7): refuse, for EVERY element type.

   An atomic load exists to read a value that some other thread -- or an earlier statement of this
   one -- published.  Neither reaches the backward pass.  Cross-thread dataflow has no adjoint path
   at all.  And the backward kernel is a separate launch that replays the forward's BINDINGS but not
   its STATEMENTS, so a replayed atomic-load reads whatever the memory holds by then, not what the
   forward saw.  That holds for an integer flag too, whose value can steer the float computation."
  (declare (ignore ctx))
  (log:debug "195 VJP atomic-load: refused (~s)" form)
  (error "atomic-load is not differentiable.  It reads a value that another thread, or an earlier statement, published, and neither is visible to the backward pass: cross-thread dataflow has no adjoint path, and the backward kernel is a separate launch that replays the forward's bindings but not its statements, so a re-executed atomic-load would read whatever the memory holds by then.  That is true of an integer flag as well -- its value can steer the float computation.  Crisp refuses rather than differentiate against a value it cannot reproduce.  If this kernel is genuinely forward-only, mark it SKIP-WITH[--differentiate]."))

;; src/autodiff.lisp
(defun %195-vjp-atomic-store (form ctx)
  "Backward rule for atomic-store! (endeavour 195, D-195-7).  An INTEGER element: inert -- there is no
   derivative to carry, just as for atomic-inc!.  Anything else: refuse.  A float atomic-store! exists
   to hand a value to another thread, and that cross-thread dataflow is invisible to the backward walk;
   differentiating it as a plain set! would be a silently wrong gradient for whoever reads it."
  (let ((category (%195-place-elem-category (second form) ctx)))
    (log:debug "195 VJP atomic-store! into ~s: element ~s" (second form) category)
    (if (eq category :integer)
        :inert
        (error "atomic-store! of a ~(~a~) element is not differentiable.  A floating-point atomic store exists to hand a value to another thread, and that cross-thread dataflow is invisible to the backward pass -- differentiating it as a plain set! would give whoever reads it a silently wrong gradient.  (An integer atomic-store! is accepted: it carries no derivative.)  If this kernel is genuinely forward-only, mark it SKIP-WITH[--differentiate]."
               (or category "non-integer")))))

;; src/autodiff.lisp  (beside the 175 atomic registrations)
(eval-when (:load-toplevel :execute)
  (register-vjp "ATOMIC-LOAD"   (function %195-vjp-atomic-load))
  (register-vjp "ATOMIC-STORE!" (function %195-vjp-atomic-store)))

;; src/autodiff.lisp  (Endeavour 195 -- supersedes the copy above: the message named the CATEGORY, so a
;; double element read "a float element"; it now says floating-point)
(defun %195-vjp-atomic-store (form ctx)
  "Backward rule for atomic-store! (endeavour 195, D-195-7).  An INTEGER element: inert -- there is no
   derivative to carry, just as for atomic-inc!.  Anything else: refuse.  A float atomic-store! exists
   to hand a value to another thread, and that cross-thread dataflow is invisible to the backward walk;
   differentiating it as a plain set! would be a silently wrong gradient for whoever reads it."
  (let ((category (%195-place-elem-category (second form) ctx)))
    (log:debug "195 VJP atomic-store! into ~s: element ~s" (second form) category)
    (if (eq category :integer)
        :inert
        (error "atomic-store! of a ~a element is not differentiable.  A floating-point atomic store exists to hand a value to another thread, and that cross-thread dataflow is invisible to the backward pass -- differentiating it as a plain set! would give whoever reads it a silently wrong gradient.  (An integer atomic-store! is accepted: it carries no derivative.)  If this kernel is genuinely forward-only, mark it SKIP-WITH[--differentiate]."
               (if (eq category :float) "floating-point" "non-integer")))))

;; src/autodiff.lisp  (re-registered: the registry holds the function OBJECT, so a redefinition is dead
;; code until it is registered again -- see the overlay-override-needs-reregistration note)
(eval-when (:load-toplevel :execute)
  (register-vjp "ATOMIC-STORE!" (function %195-vjp-atomic-store)))
