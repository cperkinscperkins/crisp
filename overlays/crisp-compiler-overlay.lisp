;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-09-22 — endeavour 175 folded into src/.
;;;;
;;;; Four things did NOT move, and that is deliberate:
;;;;   * the REDUCE-WARP and REDUCE-WORKGROUP defmacros, and the two eval-whens that
;;;;     FMAKUNBOUND them.  Both constructs became analyzed forms so the VJP registry could
;;;;     see them (BUG 081); the macros existed only because an overlay cannot un-write its
;;;;     own earlier definition.  Folding them in would have resurrected dead code AND made
;;;;     anf-transform expand the form again before the backward walk.
;;;;   * the three eval-whens that copied MACRO-FUNCTION between packages.  src/package.lisp
;;;;     exports the two WHEN-THREAD-IN-* macros from :crisp.compiler and imports them into
;;;;     :crisp-language, so there is one symbol rather than two.
;;;;   * %WARP-SPEC-CHECK-SYNC, whose live copy was a pure pass-through (the BUG 082 revert),
;;;;     so folding it meant changing nothing.
;;;;   * the eleven chained REGISTER-OPS-ANALYZERS wrappers, collapsed into one block of 13
;;;;     registrations at the end of the real function in src/analysis/ops.lisp.

(in-package :crisp.compiler)


;; src/analysis/control.lisp  (new -- place just before analyze-if-expression-impl)
(defun %if-explicit-nil-else-is-false-p (expr then-node)
  "BUG 092.  True when the IF form EXPR was written WITH an else and that else is NIL, and its
   THEN branch THEN-NODE produces a scalar value a false 0 can unify with.  That is the shape
   CL's AND expands to -- (and X Y) => (IF X (AND Y) NIL) -- and it used to be analyzed as having
   NO else, so the false path never stored the IF's result and -O3 deleted X outright.

   Deliberately narrow:
     * (if x y) with no else at all is unchanged -- only a WRITTEN nil counts;
     * a void THEN (a statement IF, e.g. a SET! body) is unchanged -- NIL there means 'no value';
     * a THEN whose type cannot promote with int (struct, tensor, ...) is unchanged, since a 0
       else would be a type error; ensure-branch-compatibility keeps its old void-branch rule.
   The int 0 literal is promoted to THEN's type by ensure-branch-compatibility, the same path any
   mixed-type IF takes."
  (and (cdddr expr)
       (null (fourth expr))
       (let ((t-single (get-single-value-type then-node)))
         (and t-single
              (symbolp t-single)
              (get-promoted-type t-single 'int)
              t))))

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
      (let* ((*in-divergent-conditional* (if (eq cond-uniformity :uniform)
                                             *in-divergent-conditional*
                                             t))
             (*divergent-scope-depth* (if (not (eq cond-uniformity :uniform))
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
             (then-node (analyze-expression (third expr) env context (append location '(2))))
             (else-node
               (cond
                 ((fourth expr)
                  (analyze-expression (fourth expr) env context (append location '(3))))
                 ;; BUG 092: an else that is WRITTEN but is NIL -- (if x y nil), which is exactly
                 ;; what CL's AND expands to -- is a false VALUE when THEN produces one.  It used to
                 ;; be indistinguishable from a missing else, leaving the false path unstored.
                 ((%if-explicit-nil-else-is-false-p expr then-node)
                  (log:debug "BUG 092: explicit NIL else of a value IF analyzed as false (int 0): ~s" expr)
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


;; src/analysis/control.lisp  (new -- place just before analyze-if-expression-impl.
;;  SUPERSEDES %if-explicit-nil-else-is-false-p above, which was drafted on a wrong premise:
;;  the running compiler expands (and X Y) to (IF X Y) -- there is no written NIL to detect.)
(defun %if-missing-else-is-false-p (expr then-node)
  "BUG 092.  True when the IF form EXPR has no else, or a NIL else, and its THEN branch THEN-NODE
   produces a scalar value that a false 0 can unify with.  In CL, (if x y) means (if x y nil):
   the false path has a value, and it is false.  Crisp analyzed a missing else as NO branch, so the
   false path never stored the IF's result -- and CL's AND expands to exactly (IF X Y), so every
   (and X Y) used as a value read an uninitialised slot on the X-false path.  -O3 then deleted X
   outright, or (in the tile bounds checks) turned the path into an llvm.assume with no store.

   Deliberately narrow:
     * a void THEN (a statement IF, e.g. a SET! body) is unchanged -- there is no value to supply;
     * a THEN whose type cannot promote with int (struct, tensor, ...) is unchanged, since a 0
       else would be a type error; ensure-branch-compatibility keeps its old void-branch rule.
   The int 0 literal is promoted to THEN's type by ensure-branch-compatibility, the same path any
   mixed-type IF takes."
  (and (null (fourth expr))
       (let ((t-single (get-single-value-type then-node)))
         (and t-single
              (symbolp t-single)
              (get-promoted-type t-single 'int)
              t))))

;; src/analysis/control.lisp  (supersedes the copy above -- only the helper call and its comment changed)
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
      (let* ((*in-divergent-conditional* (if (eq cond-uniformity :uniform)
                                             *in-divergent-conditional*
                                             t))
             (*divergent-scope-depth* (if (not (eq cond-uniformity :uniform))
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
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


;; src/codegen.lisp  (new -- place just before the semantic-if generate-node-ir method)
(defun %if-result-llvm-type (type-spec module)
  "BUG 093.  The LLVM type of an IF's result slot.  An IF whose branches each return MULTIPLE values
   carries a multi-value type LIST, e.g. (float ulong); crisp-type-to-llvm-type reads that as a
   single spec and returns only the first type (`float`), so the slot, the merge load and the
   function's `ret` disagreed with the { float, i64 } the branches built, and llvm-as rejected the
   module.  A multi-value list gets the aggregate the multi-value `return` itself uses
   (get-llvm-return-type); every other spec -- a symbol, (int), (tensor ...), (cell ...) -- goes
   through crisp-type-to-llvm-type exactly as before.

   How a multi-value list is told apart from a compound spec (measured): valid-type-p is T for int,
   (int), (tensor ...), (vector ...), (cell ...) and NIL for (float ulong), (int int).  So: a list
   of length > 1 that is NOT itself a valid type, but whose elements all are."
  (if (and (consp type-spec)
           (> (length type-spec) 1)
           (not (valid-type-p type-spec))
           (every #'valid-type-p type-spec))
      (progn
        (log:debug "BUG 093: multi-value IF result ~s -> aggregate" type-spec)
        (get-llvm-return-type module type-spec))
      (crisp-type-to-llvm-type type-spec module)))

;; src/codegen.lisp  (only change: the two crisp-type-to-llvm-type calls -> %if-result-llvm-type)
(defmethod generate-node-ir ((node semantic-if) builder module var-env di-builder di-scope location-map)
  "Generates IR for an if expression."
  ;; 1. Evaluate the condition
  (multiple-value-bind (cond-val cond-loc)
      (generate-node-ir (semantic-if-condition-node node) builder module var-env di-builder di-scope location-map)
    (declare (ignore cond-loc))
    ;; Condition must be i1 (boolean) for cond_br.
    ;; Our language uses i32, so we truncate.
    ;; Note: In strict LLVM, 0 is false, non-zero is usually true. Truncating blindly might lose info
    ;; if the value is like 2 (binary 10), trunc to i1 is 0 (false)!
    ;; Correct logic: icmp ne %val, 0
    (let ((cond-bool (llvm-build-icmp builder +llvm-int-ne+ cond-val (llvm-const-int (llvm-int32-type) 0 nil) "ifcond")))

      (let ((then-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "then"))
            (else-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "else"))
            (merge-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "ifcont"))

            ;; Determine result type and allocate scratch space if needed (alloca trick)
            (result-type-spec (semantic-node-type node)))

        ;; Note: The result type might be 'void (nil).
        (let ((result-alloca
               (unless (or (null result-type-spec)
                           (eq result-type-spec :void)
                           (eq result-type-spec 'void)
                           (equal result-type-spec '(nil)))
                 (let ((type (%if-result-llvm-type result-type-spec module)))
                   (llvm-build-alloca builder type "if_result")))))

          ;; --- Create Conditional Branch ---
          (llvm-build-cond-br builder cond-bool then-block else-block)

          ;; --- Then Block ---
          (llvm-position-builder-at-end builder then-block)
          (if (semantic-if-then-node node)
              (multiple-value-bind (then-val then-loc)
                  (generate-node-ir (semantic-if-then-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore then-loc))
                ;; A branch may legitimately produce no value (a `nil` literal, as in
                ;; the then-arm of (unless+ cond body) => (if+ cond nil body)). Then
                ;; then-val is NIL; skip the store so this path leaves the result
                ;; alloca undef (the branch is untaken under the uniform condition,
                ;; so the value is never observed) — same as a missing then-clause.
                (when (and result-alloca then-val)
                      (llvm-build-store builder then-val result-alloca)))
              ;; No then clause (e.g. unless). Treat as void/nil.
              nil)

          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Else Block ---
          (llvm-position-builder-at-end builder else-block)
          (if (semantic-if-else-node node)
              (multiple-value-bind (else-val else-loc)
                  (generate-node-ir (semantic-if-else-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore else-loc))
                ;; As with the then-arm: a `nil` else-value (e.g. (when+ cond body) or
                ;; a plain (if cond x nil)) yields NIL — skip the store, leaving undef
                ;; on the untaken path rather than crashing on a NIL store operand.
                (when (and result-alloca else-val)
                      (llvm-build-store builder else-val result-alloca)))
              ;; No else clause. If result expected, this is undefined behavior or nil.
              nil)
          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Merge Block ---
          (llvm-position-builder-at-end builder merge-block)
          (if result-alloca
              (let* ((type (%if-result-llvm-type result-type-spec module))
                     (result-val (llvm-build-load2 builder type result-alloca "if_res")))
                (values result-val nil))
              (values nil nil)))))))


;; src/mangling.lisp  (new -- BUG 090 (b))
(defun %lazy-variant-name (base-name active-env)
  "BUG 090 (b).  The mangled name of a lazily instantiated &optional / &key variant.
   mangle-function-variant-name joins only the parameter TYPES, and bind-keyword-args represents
   each supplied keyword as a placeholder parameter of type KEYWORD followed by its value -- so
   (scale b :by 3) and (scale c :plus 5) both became SCALE_int_keyword_int, and the second call
   would run the first call's variant.  Here each KEYWORD placeholder is replaced by the NAME of the
   key it introduces (the parameter that follows it): SCALE_int_key-by_int vs SCALE_int_key-plus_int.
   Keys are named in CALL order, so (:by 1 :plus 2) and (:plus 2 :by 1) are separate, both correct,
   variants.  Non-keyword parameters mangle exactly as before."
  (let ((parts (loop for (p next) on active-env
                     collect (if (and (eq (parameter-def-type p) 'keyword) next)
                                 (format nil "key-~a" (string-downcase (symbol-name (parameter-def-name next))))
                                 (mangle-param-type-name (parameter-def-type p))))))
    (intern (format nil "~a_~{~a~^_~}" base-name parts) (symbol-package base-name))))

;; src/environment.lisp  (new -- BUG 090 (a))
(defun %lazy-variant-llvm-name (variant-name param-types)
  "The LLVM function name generate-function-prototype (codegen.lisp) gives a non-entry function
   named VARIANT-NAME with PARAM-TYPES: lower-cased, types appended with mangle-type-spec, and
   - and ~ replaced by _.  Kept in step with that function by hand -- if the two ever disagree, the
   memo below simply misses and the variant is generated again, which then collides loudly."
  (substitute #\_ #\~ (substitute #\_ #\- (string-downcase
                                            (format nil "~a~{_~a~}" variant-name
                                                    (mapcar #'mangle-type-spec param-types))))))

;; src/environment.lisp  (new -- BUG 090 (a))
(defun %lazy-variant-already-generated (variant-name param-types)
  "BUG 090 (a).  The registered signature of VARIANT-NAME with PARAM-TYPES if, and only if, the
   CURRENT module already holds a DEFINED function for it; otherwise NIL.  Keyed on the module
   itself rather than on compiler state, because the spec runner creates and disposes a module
   per compile and a fresh compiler session per top-level form: a registration left over from
   another module (or from Pass 1) must not suppress generating the variant into this one."
  (let ((module (and *compiler-session* (compiler-session-module *compiler-session*))))
    (when module
      (let ((fn (llvm-get-named-function module (%lazy-variant-llvm-name variant-name param-types))))
        (when (and fn (not (cffi:null-pointer-p fn))
                   (plusp (llvm-count-basic-blocks fn)))
          (find-if (lambda (sig)
                     (equal (mapcar #'parameter-def-type (function-signature-parameters sig))
                            param-types))
                   (gethash variant-name *function-table*)))))))

;; src/environment.lisp  (new -- BUG 090)
(defun %generate-lazy-variant-ir (ast-node variant-name)
  "BUG 090.  Emit the IR for a lazily instantiated variant whose AST instantiate-generic-function
   just analyzed.  Instantiation happens mid-analysis of the CALLER, so the builder's insertion
   point is saved and restored around generation.  Does nothing without a module (Pass 1 /
   signature-only analysis): the variant is then generated when Pass 2 instantiates it."
  (let ((session *compiler-session*))
    (if (not (and ast-node session (compiler-session-module session)))
        (log:debug "BUG 090: no module -- not generating lazy variant ~s now" variant-name)
        (let* ((builder (compiler-session-builder session))
               (saved (llvm-get-insert-block builder)))
          (log:info "BUG 090: generating IR for lazy variant ~s" variant-name)
          (unwind-protect
               (generate-llvm-ir ast-node (compiler-session-module session) builder
                                 (compiler-session-di-builder session)
                                 (compiler-session-di-compile-unit session)
                                 (compiler-session-location-map session))
            (unless (cffi:null-pointer-p saved)
              (llvm-position-builder-at-end builder saved)))))))

;; src/environment.lisp  (changes: %lazy-variant-name, the per-module reuse check, %generate-lazy-variant-ir)
(defun instantiate-generic-function (generic-def explicit-arg-types context location)
  "Instantiates a lazy generic function variant for the given argument types."
  (multiple-value-bind (active-env injected-bindings error-message)
      (resolve-argument-bindings generic-def explicit-arg-types)

    (when error-message
          (log:warn "~a" error-message)
          (return-from instantiate-generic-function nil))

    (let* ((name (generic-function-def-name generic-def))
           (declarations (generic-function-def-declarations generic-def))
           ;; Robustly filter declarations from body
           (body (loop for f in (generic-function-def-body generic-def)
                         unless (and (listp f) (eq (car f) 'declare))
                       collect f)))

      ;; Apply injected bindings (Defaults)
      (when injected-bindings
            (setf body (list `(let* ,injected-bindings ,@body))))

      (let* ((active-param-names (mapcar #'parameter-def-name active-env))
             (active-param-types (mapcar #'parameter-def-type active-env))
             (mangled-name (%lazy-variant-name name active-env)))

        ;; BUG 090 (a): one variant per call shape PER MODULE.  The signature is registered under the
        ;; MANGLED name, but calls look up the BASE name, so without this every call site re-analyzed
        ;; -- and, now that variants are generated, would re-define -- the same variant.
        (let ((reused (%lazy-variant-already-generated mangled-name active-param-types)))
          (when reused
            (log:debug "BUG 090: reusing lazy variant ~s, already generated in this module" mangled-name)
            (return-from instantiate-generic-function reused)))

        (log:info "Lazy Instantiating ~s (Arity ~a) with types ~s" mangled-name (length explicit-arg-types) active-param-types)

        ;; Compile the specific variant
        (let ((ast-node (internal-compile-function mangled-name
                                                   active-env
                                                   (generic-function-def-return-types generic-def)
                                                   active-param-names
                                                   body
                                                   declarations
                                                   (or (generic-function-def-source-location generic-def) location)
                                                   context)))

          ;; BUG 090: GENERATE the variant.  It used to be analyzed and then dropped, so the call site
          ;; emitted a bare `declare` and the module carried an unresolved import.
          (%generate-lazy-variant-ir ast-node mangled-name)

          ;; Register the signature now that compilation succeeded (and return types might differ/be inferred?)
          ;; Note: Generic def return types are authoritative if present, but AST might have inferred them.
          (let* ((final-ret-types (or (generic-function-def-return-types generic-def)
                                      (semantic-function-return-type ast-node))) ;; If list mismatch, might need validation.
                                                                                (sig (make-function-signature
                                                                                      :name mangled-name
                                                                                      :parameters active-env
                                                                                      :return-types final-ret-types
                                                                                      :source-location (or (generic-function-def-source-location generic-def) location))))

            (log:info "Registering Lazy Signature: ~s -> ~s" mangled-name final-ret-types)
            ;; Append to existing signatures (thread safety? single threaded)
            (setf (gethash mangled-name *function-table*)
              (append (gethash mangled-name *function-table*) (list sig)))

            sig))))))

;; src/environment.lisp  (BUG 091 -- only change: a positional parameter is :out only while NEITHER
;;  &optional NOR &key has been seen.  It used to be :out for everything after &out, so an &optional
;;  storage handle after &out was refused as a read of a write-only parameter.  Chapter 05: "Following
;;  &out there can be &optional and then &key parameters, these are NOT considered to be &out".)
(defun analyze-environment-from-spec (params fn-spec)
  "Builds the environment from the signature. Returns (values env optional-start-index defaults-alist)."
  (let ((arrow-pos (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) fn-spec)))
    (let ((param-type-specs (subseq fn-spec 0 (or arrow-pos (length fn-spec))))
          (env '())
          (defaults '())
          (optional-start nil)
          (key-start nil)
          (out-start nil)
          (idx 0))
      (log:debug "Analyzing spec params: ~s, specs: ~s" params param-type-specs)

      (loop while (and params param-type-specs)
            do (let ((p (first params))
                     (ts (first param-type-specs)))

                 ;; (format *error-output* "DEBUG ANALYZE-ENV: Param ~s TS ~s~%" p ts)
                 (finish-output *error-output*)

                 (cond
                  ;; Handle &optional in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&OPTIONAL"))
                    ;; If type spec also has &optional, skip it.
                    (when (and (symbolp ts) (string-equal (symbol-name ts) "&OPTIONAL"))
                          (pop param-type-specs))
                    (when optional-start (error "Multiple &optional keywords found."))
                    (when key-start (error "&optional cannot appear after &key."))
                    (setf optional-start idx)
                    (pop params))

                  ;; Handle &key in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&KEY"))
                    (unless (and (symbolp ts) (string-equal (symbol-name ts) "&KEY"))
                      (error "Signature Mismatch: &key present in parameter list but found ~s in type declaration." ts))
                    (when key-start (error "Multiple &key keywords found."))
                    (setf key-start idx)
                    (setf params (cdr params))
                    (setf param-type-specs (cdr param-type-specs)))

                  ;; Handle &out in params
                  ((and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                    (unless (and (symbolp ts) (string-equal (symbol-name ts) "&OUT"))
                      (error "Signature Mismatch: &out present in parameter list but found ~s in type declaration." ts))
                    (when out-start (error "Multiple &out keywords found."))
                    (when optional-start (error "&out cannot appear after &optional."))
                    (when key-start (error "&out cannot appear after &key."))
                    (setf out-start idx)
                    (pop params)
                    (pop param-type-specs))

                  ;; Handle markers in types (Error)
                  ((and (symbolp ts)
                        (or (string-equal (symbol-name ts) "&OPTIONAL")
                            (string-equal (symbol-name ts) "&KEY")
                            (string-equal (symbol-name ts) "&OUT")))
                    (error "Signature Mismatch: ~s present in type declaration but missing in parameter list." ts))

                  ;; Handle &key specialized syntax (:key type)
                  ((and key-start (keywordp ts))
                    (let ((name p) (def-val nil)
                                   (val-type (second param-type-specs)))
                      ;; Extract (name default) from params
                      (when (listp p)
                            (setf name (first p))
                            (setf def-val (second p))
                            (push (cons name def-val) defaults))

                      ;; Validate param-type-specs has enough elements
                      (unless val-type
                        (error "Signature Mismatch: &key keyword ~s missing type." ts))

                      ;; Validate name match (optional strictness, but good for sanity)
                      (unless (string-equal (symbol-name name) (symbol-name ts))
                        (log:warn "Signature key name mismatch: Param ~s vs Keyword spec ~s" name ts))

                      (push (make-parameter-def :name name
                                                :type (parse-type-specifier val-type)
                                                :kind :in
                                                :is-key t
                                                :default-value def-val) env)
                      (incf idx)
                      (pop params)
                      (pop param-type-specs) ;; Pop keyword
                      (pop param-type-specs))) ;; Pop value type

                  ;; Normal parameter (symbol or (name default))
                  (t
                    (let ((name p) (def-val nil))
                      ;; Extract (name default)
                      (when (listp p)
                            (setf name (first p))
                            (setf def-val (second p))
                            ;; Store default
                            (push (cons name def-val) defaults))

                      (push (make-parameter-def
                             :name name
                             :type (parse-type-specifier ts)
                             :kind (cond ((and out-start (not optional-start) (not key-start)) :out) ; BUG 091
                                         (t :in))
                             :is-optional (not (null optional-start))
                             :is-key (not (null key-start))
                             :default-value def-val)
                            env)
                      (incf idx)
                      (pop params)
                      (pop param-type-specs))))))

      (when (or params param-type-specs)
            (error 'crisp-signature-arity-error :expected (length fn-spec) :inferred (length env) :source-location nil))

      (values (nreverse env) optional-start (nreverse defaults) key-start))))

;;;; ===========================================================================
;;;; Endeavour 176 -- IMPLICIT SCRATCH for the reductions (stage B: workgroup-local scratch plus
;;;; last-man's counter and flag).  Design: tests/spec/176-reduce-multi/reduce-multi.md.
;;;;
;;;; When a reduction's scratch keys are omitted, the reduction is rewritten -- in BOTH passes, by the
;;;; same function -- into (let ((<var>-LOCAL-SCRATCH (make-scratch-vector T ...)) ...) (<reduction>
;;;; ... :local-scratch-vec <var>-LOCAL-SCRATCH ...)).  Pass 1 scans that let (so the existing
;;;; implicit-parameter plumbing registers the scratch and carries it to the kernel), and Pass 2
;;;; analyzes the same let (so codegen rebuilds the same <binding>_FROM_<fn>_<n> name).  The element
;;;; type T is read from the IDENTITY at scan time -- the one type the API guarantees and that is
;;;; visible before analysis.
;;;;
;;;; NOT YET: last-man's :global-scratch-vec.  It is sized by the number of workgroups, and both
;;;; hoisters reject any symbolic size for GLOBAL scratch (and :match-num-workgroups is unimplemented
;;;; everywhere).  Until that hoister work lands, last-man still needs an explicit :global-scratch-vec.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new)
(defparameter *176-implicit-scratch-specs*
  '(("REDUCE-WORKGROUP"          4 (:local-scratch-vec))
    ("GRID-REDUCE-ATOMIC!"       5 (:local-scratch-vec))
    ("GRID-REDUCE-CAS!"          5 (:local-scratch-vec))
    ;; :global-scratch-vec deliberately absent -- see the section header.
    ("GRID-REDUCE-LAST-MAN!"     5 (:local-scratch-vec :atomic-counter :election-flag-cell))
    ("GRID-REDUCE-SECOND-STAGE!" 6 (:local-scratch-vec)))
  "Endeavour 176.  For each reduction Crisp can supply scratch for: the operator's name, how many
   leading elements of the form (operator included) are positional, and the scratch keys Crisp
   allocates when the caller leaves them out.")

;; src/analysis/ops.lisp  (new)
(defun %implicit-scratch-spec (op)
  "The *176-implicit-scratch-specs* entry for operator symbol OP, or NIL.  Matched by name, since the
   reductions are interned in both :crisp.compiler and :crisp-language."
  (and (symbolp op)
       (assoc (symbol-name op) *176-implicit-scratch-specs* :test #'string-equal)))

;; src/analysis/ops.lisp  (new)
(defun %implicit-scratch-missing-keys (expr)
  "The scratch keys of reduction form EXPR that Crisp can supply and the caller left out, in table
   order; NIL when EXPR is not such a reduction or supplies them all.  Walks the keyword tail as
   pairs rather than with GETF, so a malformed tail is left for the expander to report."
  (let ((spec (%implicit-scratch-spec (car expr))))
    (when spec
      (let ((tail (nthcdr (second spec) expr)))
        (remove-if (lambda (key)
                     (loop for (k nil) on tail by #'cddr thereis (eq k key)))
                   (third spec))))))

;; src/analysis/ops.lisp  (new)
(defun %scan-type-by-name (name)
  "The Crisp type symbol whose name is NAME (a string), or NIL.  Looked up in *crisp-types* so the
   answer is the symbol the rest of the compiler uses."
  (loop for k being the hash-keys of *crisp-types*
        when (and (symbolp k) (string-equal (symbol-name k) name))
          return k))

;; src/analysis/ops.lisp  (new)
(defun %identity-scan-type (form)
  "Endeavour 176.  The Crisp type of identity FORM, read from the form ALONE -- no environment, since
   this runs in the Pass-1 scan, before any variable has a type.  NIL when the type is not visible.

   Recognised, mirroring the analyzer's own literal typing (analyze-expression Case 1/1.1/2):
     integer literal                      -> int
     float literal                        -> float   (all float literals are float)
     suffixed literal (0ul, 1.5f, 255uc)  -> its suffix type (%try-parse-typed-literal)
     (type-min T) (type-max T) (type-infinity T) -> T
     (- X)                                -> the type of X
     (to-T x)                             -> T, when T names a Crisp type"
  (cond
    ((integerp form) 'int)
    ((floatp form) 'float)
    ((and (symbolp form) form (not (keywordp form)))
     (let ((lit (ignore-errors (%try-parse-typed-literal form nil))))
       (and lit (semantic-node-type lit))))
    ((and (consp form) (symbolp (car form)))
     (let ((head (symbol-name (car form))))
       (cond
         ((and (member head '("TYPE-MIN" "TYPE-MAX" "TYPE-INFINITY") :test #'string-equal)
               (symbolp (second form)))
          (%scan-type-by-name (symbol-name (second form))))
         ((and (string= head "-") (= (length form) 2))
          (%identity-scan-type (second form)))
         ((and (> (length head) 3) (string-equal "TO-" head :end2 3))
          (%scan-type-by-name (subseq head 3)))
         (t nil))))
    (t nil)))

;; src/analysis/ops.lisp  (new)
(defun %implicit-scratch-binding-name (var key)
  "The DETERMINISTIC let-binding name for the scratch Crisp allocates for KEY of a reduction over VAR,
   e.g. CONTRIB-LOCAL-SCRATCH.  Deterministic because Pass 2 finds the implicit parameter by
   rebuilding <binding>_FROM_<fn>_<n>, so Pass 1 and Pass 2 must see the same name (a gensym would
   differ).  It also names the buffer readably in the generated host code."
  (intern (format nil "~a-~a" (symbol-name var)
                  (ecase key
                    (:local-scratch-vec  "LOCAL-SCRATCH")
                    (:atomic-counter     "COUNTER")
                    (:election-flag-cell "ELECTION-FLAG")))
          (or (symbol-package var) (find-package :crisp-language))))

;; src/analysis/ops.lisp  (new)
(defun %implicit-scratch-alloc-form (key elem-type)
  "The allocation form for scratch KEY: the same forms a caller writes by hand (see 175/25)."
  (ecase key
    (:local-scratch-vec  `(make-scratch-vector ,elem-type :match-num-warps-per-workgroup))
    (:atomic-counter     '(make-scratch-cell uint :address-space :global))
    (:election-flag-cell '(make-scratch-cell uint))))

;; src/analysis/ops.lisp  (new)
(defun %implicit-scratch-form (expr elem-type)
  "Endeavour 176.  Reduction form EXPR with its missing scratch supplied: a LET binding each missing
   buffer, around EXPR with the corresponding keys appended.  Used by BOTH the Pass-1 scan-operator
   methods and the analyzers, so the two passes see the same form (and the same scratch order)."
  (let* ((spec (%implicit-scratch-spec (car expr)))
         (var (third expr))
         (missing (%implicit-scratch-missing-keys expr))
         (names (mapcar (lambda (k) (%implicit-scratch-binding-name var k)) missing)))
    `(let ,(mapcar (lambda (name key) (list name (%implicit-scratch-alloc-form key elem-type))) names missing)
       (,@(subseq expr 0 (second spec))
        ,@(nthcdr (second spec) expr)
        ,@(loop for key in missing for name in names append (list key name))))))

;; src/analysis/ops.lisp  (new)
(defun %scan-reduction-maybe-implicit (op args next)
  "Pass 1.  Scan the implicit-scratch form of reduction (OP . ARGS) when Crisp will supply its scratch;
   otherwise call NEXT (the default scan).  An identity whose type is not visible is scanned as-is and
   refused by the analyzer, which can say why."
  (let* ((expr (cons op args))
         (missing (%implicit-scratch-missing-keys expr))
         (elem-type (and missing (symbolp (third expr)) (%identity-scan-type (fourth expr)))))
    (if elem-type
        (progn
          (log:debug "176: Pass 1 implicit scratch ~s for ~s (element type ~s)" missing op elem-type)
          (scan-form (%implicit-scratch-form expr elem-type)))
        (funcall next))))

;; src/analysis/ops.lisp  (new) -- REDUCE-WORKGROUP is a DIFFERENT symbol in the two packages, so both
;; methods are needed; for the others the two interns name one symbol and the second defmethod simply
;; replaces the first.
(macrolet ((def-implicit-scratch-scanners (&rest names)
             `(progn
                ,@(loop for name in names
                        append (loop for pkg in '(:crisp.compiler :crisp-language)
                                     collect `(defmethod scan-operator ((op (eql (intern ,name (find-package ,pkg)))) args)
                                                (%scan-reduction-maybe-implicit op args (lambda () (call-next-method)))))))))
  (def-implicit-scratch-scanners "REDUCE-WORKGROUP" "GRID-REDUCE-ATOMIC!" "GRID-REDUCE-CAS!"
                                 "GRID-REDUCE-LAST-MAN!" "GRID-REDUCE-SECOND-STAGE!"))

;; src/analysis/ops.lisp  (new)
(defun %check-identity-matches-variable (op-name var identity elem-type env context location)
  "Endeavour 176.  With implicit scratch the scratch is typed from the IDENTITY, so a variable of a
   different type would be reduced through mistyped scratch.  Refuse it, naming the fix."
  (let* ((var-type (semantic-node-type (analyze-expression var env context location)))
         (a (resolve-type-alias var-type))
         (b (resolve-type-alias elem-type)))
    (unless (if (and (symbolp a) (symbolp b))
                (string-equal (symbol-name a) (symbol-name b))
                (equal a b))
      (error 'crisp-compiler-error
             :message (format nil "~a: the identity ~s is ~(~a~) but ~a is ~(~a~).  The identity must have the variable's type when Crisp allocates the scratch for you, because the scratch is typed from it -- write the identity as a ~(~a~), e.g. (to-~(~a~) ~s)."
                              op-name identity b var a a a identity)
             :source-location location))))

;; src/analysis/ops.lisp  (new)
(defun %analyze-reduction-maybe-implicit (expr env context location expander)
  "Endeavour 176.  Analyze reduction EXPR, supplying its scratch when the caller left it out; else
   analyze (EXPANDER EXPR) exactly as before."
  (let ((missing (%implicit-scratch-missing-keys expr))
        (var (third expr)))
    (if (or (null missing) (not (symbolp var)))
        (analyze-expression (funcall expander expr) env context location)
        (let* ((op-name (string-downcase (symbol-name (car expr))))
               (identity (fourth expr))
               (elem-type (%identity-scan-type identity)))
          (unless elem-type
            (error 'crisp-compiler-error
                   :message (format nil "~a: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass ~{~s~^ ~} yourself."
                                    op-name identity missing)
                   :source-location location))
          (%check-identity-matches-variable op-name var identity elem-type env context location)
          (log:debug "176: implicit scratch ~s for ~a over ~s (element type ~s)" missing op-name var elem-type)
          (analyze-expression (%implicit-scratch-form expr elem-type) env context location)))))

;; src/analysis/ops.lisp  (the five analyzers: previously (analyze-expression (%X-expand expr) ...))
(defun %analyze-reduce-workgroup (expr env context location)
  "Analyzer for reduce-workgroup -- expands and delegates, supplying implicit scratch (176).  Being an
   ANALYZED form rather than a macro is what keeps the construct visible to the autodiff walk."
  (%analyze-reduction-maybe-implicit expr env context location #'%reduce-workgroup-expand))

(defun %analyze-grid-reduce-atomic (expr env context location)
  "Analyzer for grid-reduce-atomic! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-atomic-expand))

(defun %analyze-grid-reduce-last-man (expr env context location)
  "Analyzer for grid-reduce-last-man! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-last-man-expand))

(defun %analyze-grid-reduce-second-stage (expr env context location)
  "Analyzer for grid-reduce-second-stage! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-second-stage-expand))

(defun %analyze-grid-reduce-cas (expr env context location)
  "Analyzer for grid-reduce-cas! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-cas-expand))

;;;; ===========================================================================
;;;; Endeavour 176 -- IMPLICIT SCRATCH stage A: last-man's :global-scratch-vec.
;;;; SUPERSEDES the three definitions of the same names in stage B above (only the LAST copy is live).
;;;;
;;;; The partials buffer needs one slot per workgroup.  :match-num-workgroups is the exact size but is
;;;; unimplemented in both hoisters (BUG 094).  :match-workgroup-size is used instead, and is always
;;;; enough: last-man already REQUIRES num_workgroups <= local_work_size (its final sweep runs in one
;;;; workgroup), so a buffer of local_work_size slots can never be too small.  It over-allocates (64
;;;; slots for 4 workgroups in 175/57) -- a few hundred bytes of global memory.  If that limit is ever
;;;; lifted (a strided final sweep), this must move to :match-num-workgroups.
;;;;
;;;; Needs the L0 hoister's symbolic GLOBAL scratch support (overlays/hoist-l0, BUG 094).  The CUDA
;;;; hoister already resolves symbolic global sizes from the declared local size.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (supersedes the stage-B copy: :global-scratch-vec added for last-man)
(defparameter *176-implicit-scratch-specs*
  '(("REDUCE-WORKGROUP"          4 (:local-scratch-vec))
    ("GRID-REDUCE-ATOMIC!"       5 (:local-scratch-vec))
    ("GRID-REDUCE-CAS!"          5 (:local-scratch-vec))
    ("GRID-REDUCE-LAST-MAN!"     5 (:local-scratch-vec :global-scratch-vec :atomic-counter :election-flag-cell))
    ("GRID-REDUCE-SECOND-STAGE!" 6 (:local-scratch-vec)))
  "Endeavour 176.  For each reduction Crisp can supply scratch for: the operator's name, how many
   leading elements of the form (operator included) are positional, and the scratch keys Crisp
   allocates when the caller leaves them out, in the order they are bound.")

;; src/analysis/ops.lisp  (supersedes the stage-B copy: :global-scratch-vec added)
(defun %implicit-scratch-binding-name (var key)
  "The DETERMINISTIC let-binding name for the scratch Crisp allocates for KEY of a reduction over VAR,
   e.g. CONTRIB-LOCAL-SCRATCH.  Deterministic because Pass 2 finds the implicit parameter by
   rebuilding <binding>_FROM_<fn>_<n>, so Pass 1 and Pass 2 must see the same name (a gensym would
   differ).  It also names the buffer readably in the generated host code."
  (intern (format nil "~a-~a" (symbol-name var)
                  (ecase key
                    (:local-scratch-vec  "LOCAL-SCRATCH")
                    (:global-scratch-vec "GLOBAL-SCRATCH")
                    (:atomic-counter     "COUNTER")
                    (:election-flag-cell "ELECTION-FLAG")))
          (or (symbol-package var) (find-package :crisp-language))))

;; src/analysis/ops.lisp  (supersedes the stage-B copy: :global-scratch-vec added)
(defun %implicit-scratch-alloc-form (key elem-type)
  "The allocation form for scratch KEY: the same forms a caller writes by hand (see 175/25).  The
   global partials are sized :match-workgroup-size -- see the stage-A section header for why that is
   always enough."
  (ecase key
    (:local-scratch-vec  `(make-scratch-vector ,elem-type :match-num-warps-per-workgroup))
    (:global-scratch-vec `(make-scratch-vector ,elem-type :match-workgroup-size :address-space :global))
    (:atomic-counter     '(make-scratch-cell uint :address-space :global))
    (:election-flag-cell '(make-scratch-cell uint))))

;;;; ===========================================================================
;;;; Endeavour 176 -- SCRATCH AS AN &optional / &key DEFAULT (spec 016/10).
;;;;
;;;; (def-grid-function grid-sum (x &out o &optional (sv (make-scratch-vector ...))) ...)
;;;;
;;;; Pass 1 scanned only the BODY, so a scratch default was never registered and the kernel never got
;;;; the parameter.  Now:
;;;;   * Pass 1 also scans a generic function's make-scratch-* DEFAULTS, registering each under the
;;;;     BASE name as <PARAM>-DEFAULT_FROM_<fn>_1 (a private counter, so the module-wide scratch
;;;;     replay is undisturbed), and marks the function an originator; Pass 1.5 lifts it to callers.
;;;;   * Call sites are unchanged -- they look up the base name and already pass its implicit args.
;;;;   * A variant inherits the base name's implicit entries (so its definition accepts what the call
;;;;     passes), and a defaulted scratch parameter is bound to that implicit PARAMETER rather than
;;;;     allocated -- so no scratch is created inside the variant and no counter is replayed.
;;;; ===========================================================================

;; src/analysis/core.lisp  (new)
(defun %scratch-allocation-form-p (form)
  "T when FORM is a (make-scratch-vector|matrix|tensor|cell ...) allocation, by symbol name."
  (and (consp form) (symbolp (car form))
       (member (symbol-name (car form))
               '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
               :test #'string-equal)))

;; src/analysis/core.lisp  (new)
(defun %default-scratch-implicit-name (fn-name param-name)
  "The implicit-parameter name a scratch DEFAULT of PARAM-NAME in generic function FN-NAME is
   registered under: <PARAM>-DEFAULT_FROM_<FN>_1.  Built by the same rule the scratch scanners use
   (<binding>_FROM_<fn>_<n>, interned in the binding's package), with the binding <PARAM>-DEFAULT
   and a private counter of 1 -- so Pass 1 (which registers it) and instantiation (which binds the
   parameter to it) compute the same symbol without consulting any table."
  (let ((binding (intern (format nil "~a-DEFAULT" (symbol-name param-name))
                         (or (symbol-package param-name) (find-package :crisp-language)))))
    (intern (format nil "~a_FROM_~a_~d" binding fn-name 1) (symbol-package binding))))

;; src/analysis/core.lisp  (new)
(defun %scan-generic-default-scratch (fn-name)
  "Pass 1, endeavour 176.  When FN-NAME is a generic (&optional / &key) function, register every
   make-scratch-* DEFAULT of its parameters as an implicit argument of FN-NAME.  Returns T when any
   was registered (the caller then marks FN-NAME an originator).

   The scan runs with *scratch-cell-counter* rebound to 0: the scanners name scratch by counter, and
   Pass 2 replays the module-wide counter to find ordinary scratch again.  A default's scratch is
   never replayed (instantiation binds the parameter to the implicit argument directly), so it must
   not advance the module-wide count."
  (let ((generic-def (gethash fn-name *generic-functions*))
        (found nil))
    (when generic-def
      (loop for (param-name . default-form) in (generic-function-def-defaults generic-def)
            when (%scratch-allocation-form-p default-form)
              do (let ((*scratch-cell-counter* 0)
                       (prev (compiler-context-current-binding-name *compiler-context*)))
                   (setf (compiler-context-current-binding-name *compiler-context*)
                         (intern (format nil "~a-DEFAULT" (symbol-name param-name))
                                 (or (symbol-package param-name) (find-package :crisp-language))))
                   (unwind-protect (scan-form default-form)
                     (setf (compiler-context-current-binding-name *compiler-context*) prev))
                   (log:info "176: Pass 1 registered scratch default ~a of ~a as ~a"
                             param-name fn-name (%default-scratch-implicit-name fn-name param-name))
                   (setf found t))))
    found))

;; src/environment.lisp  (new)
(defun %bind-defaults-to-default-scratch (fn-name injected-bindings)
  "Endeavour 176.  INJECTED-BINDINGS ((param default-form) ...) with each make-scratch-* default that
   Pass 1 registered for FN-NAME replaced by the implicit parameter itself, so the variant binds
   the parameter to the scratch the caller passes instead of allocating its own."
  (let ((implicits (gethash fn-name *implicit-arg-map*)))
    (loop for (param form) in injected-bindings
          collect (let ((uname (and (%scratch-allocation-form-p form)
                                    (%default-scratch-implicit-name fn-name param))))
                    (if (and uname (find uname implicits :key #'car))
                        (progn
                          (log:debug "176: default ~a of ~a bound to implicit ~a" param fn-name uname)
                          (list param uname))
                        (list param form))))))

;; src/environment.lisp  (supersedes the BUG 090 copy above: optional LLVM-PARAM-TYPES)
(defun %lazy-variant-already-generated (variant-name param-types &optional (llvm-param-types param-types))
  "BUG 090 (a).  The registered signature of VARIANT-NAME with (explicit) PARAM-TYPES if, and only if,
   the CURRENT module already holds a DEFINED function for it; otherwise NIL.  Keyed on the module
   itself rather than on compiler state, because the spec runner creates and disposes a module per
   compile and a fresh compiler session per top-level form.

   LLVM-PARAM-TYPES (176) are the types the LLVM name is mangled from: a variant that inherits implicit
   scratch parameters is named with those types FIRST, exactly as any carrier function is."
  (let ((module (and *compiler-session* (compiler-session-module *compiler-session*))))
    (when module
      (let ((fn (llvm-get-named-function module (%lazy-variant-llvm-name variant-name llvm-param-types))))
        (when (and fn (not (cffi:null-pointer-p fn))
                   (plusp (llvm-count-basic-blocks fn)))
          (find-if (lambda (sig)
                     (equal (mapcar #'parameter-def-type (function-signature-parameters sig))
                            param-types))
                   (gethash variant-name *function-table*)))))))

;; src/analysis/core.lisp  (176: only change -- scan a generic function's scratch DEFAULTS)
(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052).
Also scans *template-registry* for HOF templates after walk-code-forms.

Endeavor 120: also captures each function's macro-expanded params/body and
runs infer-param-uniformity once the call graph is complete."
  ;; Endeavor 120: reset per-module uniformity/inert state.
  (clrhash *inert-functions*)
  (clrhash *fn-normalized-info*)
  (clrhash *inferred-param-uniformity*)
  ;; Step 1: Pre-populate from top-level def-function forms.
  (%pre-register-differentiable-fns forms)
  ;; Step 2: Walk all forms (registers templates, signatures, etc.)
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                               (body (cdddr form))
                               (body-forms (loop for f in body
                                                 unless (and (listp f) (eq (car f) 'declare))
                                                 collect f))
                               (decls (loop for f in body
                                            when (and (listp f) (eq (car f) 'declare))
                                            append (rest f)))
                               (entry-point-p (loop for d in decls
                                                    thereis (and (listp d) (symbolp (first d))
                                                                 (string-equal (symbol-name (first d)) "ENTRY-POINT")))))
                       ;; Endeavor 120: capture normalized info for inference.
                       (setf (gethash name *fn-normalized-info*)
                             (list :params (third form) :body body-forms :entry-point-p entry-point-p))
                       (register-function-signature form location)
                       (let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           ;; 176: a generic function's make-scratch-* DEFAULTS are scratch too.
                           (when (%scan-generic-default-scratch name)
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees))))))
  ;; Step 3: After walk-code-forms, scan template registry for HOF templates.
  (%pre-register-hof-templates)
  ;; Endeavor 120: interprocedural uniformity inference (call graph is ready).
  (infer-param-uniformity))

;; src/environment.lisp  (176, supersedes the BUG 090 copy above: scratch defaults bound to their
;;  implicit parameter; base implicits inherited; memo mangles with implicit types)
(defun instantiate-generic-function (generic-def explicit-arg-types context location)
  "Instantiates a lazy generic function variant for the given argument types."
  (multiple-value-bind (active-env injected-bindings error-message)
      (resolve-argument-bindings generic-def explicit-arg-types)

    (when error-message
          (log:warn "~a" error-message)
          (return-from instantiate-generic-function nil))

    (let* ((name (generic-function-def-name generic-def))
           (declarations (generic-function-def-declarations generic-def))
           ;; Robustly filter declarations from body
           (body (loop for f in (generic-function-def-body generic-def)
                         unless (and (listp f) (eq (car f) 'declare))
                       collect f)))

      ;; 176: a scratch DEFAULT is bound to the implicit parameter Pass 1 registered for it.
      (setf injected-bindings (%bind-defaults-to-default-scratch name injected-bindings))

      ;; Apply injected bindings (Defaults)
      (when injected-bindings
            (setf body (list `(let* ,injected-bindings ,@body))))

      (let* ((active-param-names (mapcar #'parameter-def-name active-env))
             (active-param-types (mapcar #'parameter-def-type active-env))
             (mangled-name (%lazy-variant-name name active-env)))

        ;; BUG 090 (a): one variant per call shape PER MODULE.  The signature is registered under the
        ;; MANGLED name, but calls look up the BASE name, so without this every call site re-analyzed
        ;; -- and, now that variants are generated, would re-define -- the same variant.
        ;; 176: the variant inherits the BASE name's implicit arguments (scratch defaults, and anything
        ;; propagated to the base), so its definition accepts what the call site passes -- calls look up
        ;; the base name.  Its LLVM name is then mangled with those types first, like any carrier.
        (let ((base-implicits (gethash name *implicit-arg-map*)))
          (when base-implicits
            (setf (gethash mangled-name *implicit-arg-map*) base-implicits)))

        (let ((reused (%lazy-variant-already-generated
                       mangled-name active-param-types
                       (append (mapcar #'cdr (gethash mangled-name *implicit-arg-map*)) active-param-types))))
          (when reused
            (log:debug "BUG 090: reusing lazy variant ~s, already generated in this module" mangled-name)
            (return-from instantiate-generic-function reused)))

        (log:info "Lazy Instantiating ~s (Arity ~a) with types ~s" mangled-name (length explicit-arg-types) active-param-types)

        ;; Compile the specific variant
        (let ((ast-node (internal-compile-function mangled-name
                                                   active-env
                                                   (generic-function-def-return-types generic-def)
                                                   active-param-names
                                                   body
                                                   declarations
                                                   (or (generic-function-def-source-location generic-def) location)
                                                   context)))

          ;; BUG 090: GENERATE the variant.  It used to be analyzed and then dropped, so the call site
          ;; emitted a bare `declare` and the module carried an unresolved import.
          (%generate-lazy-variant-ir ast-node mangled-name)

          ;; Register the signature now that compilation succeeded (and return types might differ/be inferred?)
          ;; Note: Generic def return types are authoritative if present, but AST might have inferred them.
          (let* ((final-ret-types (or (generic-function-def-return-types generic-def)
                                      (semantic-function-return-type ast-node))) ;; If list mismatch, might need validation.
                                                                                (sig (make-function-signature
                                                                                      :name mangled-name
                                                                                      :parameters active-env
                                                                                      :return-types final-ret-types
                                                                                      :source-location (or (generic-function-def-source-location generic-def) location))))

            (log:info "Registering Lazy Signature: ~s -> ~s" mangled-name final-ret-types)
            ;; Append to existing signatures (thread safety? single threaded)
            (setf (gethash mangled-name *function-table*)
              (append (gethash mangled-name *function-table*) (list sig)))

            sig))))))

;;;; ===========================================================================
;;;; Endeavour 176 -- SCRATCH IN THE BODY OF A GENERIC FUNCTION (016/11), and SINGLE-PASS (016/10).
;;;;
;;;; Scratch is matched across passes by name, <binding>_FROM_<fn>_<n>: Pass 1 registers it while
;;;; scanning a function's body, and codegen rebuilds the name from the CURRENT function and a
;;;; module-wide counter replayed in the same order.  A generic function breaks both halves:
;;;;   * its variants are generated in the middle of the CALLER's analysis, so the "current function"
;;;;     is the caller, and the counter is wherever the caller happens to be;
;;;;   * Pass 2 never compiles the generic body in place, so the counter Pass 1 advanced while
;;;;     scanning it is never advanced again -- every later scratch in the module would be off by that
;;;;     many (masked so far only because no spec had scratch after a generic function).
;;;; So: Pass 1 records, per generic function, the counter before its body scan and how far the scan
;;;; advanced it; Pass 2 advances the counter by that amount where it skips the definition; and each
;;;; variant is generated with the current function bound to the BASE name and the counter replayed
;;;; from the recorded start -- every variant then rebuilds the names Pass 1 registered.
;;;;
;;;; Single-pass mode has no Pass 1: a function is pre-scanned (scan-for-carriers) when it is compiled,
;;;; and a generic function never is.  Its skip point now does that scan (body and scratch defaults)
;;;; and records the counter there.  The single-pass scan only PEEKS at the counter, so nothing is
;;;; advanced in that mode.
;;;; ===========================================================================

;; src/specials.lisp  (new)
(defvar *176-generic-scratch-range* (make-hash-table :test 'eq)
  "Endeavour 176.  Generic (&optional / &key) function name -> (START . COUNT): the scratch counter
   before its body was scanned, and how many scratch buffers the scan registered.  Set by Pass 1
   (multi-pass) or at the function's skip point (single-pass); read when its variants are generated.")

;; src/analysis/core.lisp  (new)
(defun %176-generic-skip-scratch (name body)
  "Endeavour 176.  At the point where Pass 2 (or single-pass compilation) SKIPS generic function NAME,
   keep the scratch counter in step.  Multi-pass: advance it by the COUNT Pass 1 recorded, since Pass 1
   advanced it that far while scanning the body.  Single-pass: there was no Pass 1, so scan the body
   (scan-for-carriers) and the scratch defaults now, and record the counter as the START."
  (if (single-pass-mode-p)
      (progn
        (setf (gethash name *176-generic-scratch-range*) (cons *scratch-cell-counter* 0))
        (scan-for-carriers name body)
        (let ((*compiler-context* (make-compiler-context)))
          (setf (compiler-context-scanning-function-name *compiler-context*) name)
          (%scan-generic-default-scratch name))
        (log:info "176: single-pass pre-scan of generic ~a; implicit ~s"
                  name (mapcar #'car (gethash name *implicit-arg-map*))))
      (let ((range (gethash name *176-generic-scratch-range*)))
        (when (and range (plusp (cdr range)))
          (log:debug "176: skipping generic ~a -- advancing scratch counter by ~d" name (cdr range))
          (incf *scratch-cell-counter* (cdr range))))))

;; src/environment.lisp  (supersedes the BUG 090 copy above: optional BASE-NAME)
(defun %generate-lazy-variant-ir (ast-node variant-name &optional base-name)
  "BUG 090.  Emit the IR for a lazily instantiated variant whose AST instantiate-generic-function
   just analyzed.  Instantiation happens mid-analysis of the CALLER, so the builder's insertion
   point is saved and restored around generation.  Does nothing without a module (Pass 1 /
   signature-only analysis): the variant is then generated when Pass 2 instantiates it.

   176: with BASE-NAME (the generic function's own name), the current function is bound to it and the
   scratch counter replayed from the start Pass 1 recorded for it, so scratch in the variant's body
   rebuilds the names Pass 1 registered (<binding>_FROM_<base>_<n>) -- for every variant alike."
  (let ((session *compiler-session*))
    (if (not (and ast-node session (compiler-session-module session)))
        (log:debug "BUG 090: no module -- not generating lazy variant ~s now" variant-name)
        (let* ((builder (compiler-session-builder session))
               (saved (llvm-get-insert-block builder))
               (range (and base-name (gethash base-name *176-generic-scratch-range*)))
               (context *compiler-context*)
               (prev-fn (and context (compiler-context-current-compiling-function context)))
               (*scratch-cell-counter* (if range (car range) *scratch-cell-counter*)))
          (log:info "BUG 090: generating IR for lazy variant ~s (base ~s, scratch from ~s)"
                    variant-name base-name (and range (car range)))
          (unwind-protect
               (progn
                 (when (and context base-name)
                   (setf (compiler-context-current-compiling-function context) base-name))
                 (generate-llvm-ir ast-node (compiler-session-module session) builder
                                   (compiler-session-di-builder session)
                                   (compiler-session-di-compile-unit session)
                                   (compiler-session-location-map session)))
            (when (and context base-name)
              (setf (compiler-context-current-compiling-function context) prev-fn))
            (unless (cffi:null-pointer-p saved)
              (llvm-position-builder-at-end builder saved)))))))

;; src/analysis/core.lisp  (176, supersedes the copy above: also records each generic body's scratch range)
(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052).
Also scans *template-registry* for HOF templates after walk-code-forms.

Endeavor 120: also captures each function's macro-expanded params/body and
runs infer-param-uniformity once the call graph is complete."
  ;; Endeavor 120: reset per-module uniformity/inert state.
  (clrhash *176-generic-scratch-range*)   ; 176: per-module, like the tables below
  (clrhash *inert-functions*)
  (clrhash *fn-normalized-info*)
  (clrhash *inferred-param-uniformity*)
  ;; Step 1: Pre-populate from top-level def-function forms.
  (%pre-register-differentiable-fns forms)
  ;; Step 2: Walk all forms (registers templates, signatures, etc.)
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                               (body (cdddr form))
                               (body-forms (loop for f in body
                                                 unless (and (listp f) (eq (car f) 'declare))
                                                 collect f))
                               (decls (loop for f in body
                                            when (and (listp f) (eq (car f) 'declare))
                                            append (rest f)))
                               (entry-point-p (loop for d in decls
                                                    thereis (and (listp d) (symbolp (first d))
                                                                 (string-equal (symbol-name (first d)) "ENTRY-POINT")))))
                       ;; Endeavor 120: capture normalized info for inference.
                       (setf (gethash name *fn-normalized-info*)
                             (list :params (third form) :body body-forms :entry-point-p entry-point-p))
                       (register-function-signature form location)
                       (let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees scratch-before)
                             ;; 176: also capture the scratch counter BEFORE the body scan.
                             (let ((before *scratch-cell-counter*))
                               (multiple-value-call (lambda (&optional o c &rest ignore)
                                                      (declare (ignore ignore))
                                                      (values o c before))
                                 (shallow-analyze-body body)))
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           ;; 176: a generic function's make-scratch-* DEFAULTS are scratch too.
                           (when (%scan-generic-default-scratch name)
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees)
                           ;; 176: a generic body's scratch range, for its skip point and variants.
                           (when (gethash name *generic-functions*)
                             (setf (gethash name *176-generic-scratch-range*)
                                   (cons scratch-before (- *scratch-cell-counter* scratch-before)))))))))
  ;; Step 3: After walk-code-forms, scan template registry for HOF templates.
  (%pre-register-hof-templates)
  ;; Endeavor 120: interprocedural uniformity inference (call graph is ready).
  (infer-param-uniformity))

;; src/analysis/core.lisp  (176: only change -- the generic skip point keeps the scratch counter in step)
(defun compile-def-function (form location module builder di-builder di-compile-unit location-map)
  "Compiles a single def-function form. Handles optional parameters by generating
overloaded variants. When *differentiate-p* is T, also generates and compiles
the _GRAD backward companion after the forward function."
  ;; In single-pass mode, the signature won't be registered yet.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location))

  (let* ((name (second form))
            (params (third form))
            (body-and-loc (cdddr form))
            ;; Extract declarations manually to check for optional args and system flag.
            (declare-forms (loop for f in body-and-loc
                                    while (and (listp f) (eq (car f) 'declare))
                                    collect f))
            (declarations (loop for f in declare-forms append (rest f)))
            (is-system (member '(crisp-system-generated) declarations :test #'equal)))

    (multiple-value-bind (explicit-env return-types optional-idx defaults key-idx)
        (parse-function-declarations params declarations)
      (declare (ignore explicit-env return-types defaults))

      (cond
       ;; --- OPTIONAL/KEY PARAMETERS: Lazy Instantiation (Generic Template) ---
       ((or optional-idx key-idx)
         (log:info "Skipping eager compilation for GENERIC function template: ~a. Variants will be compiled on demand." name)
         ;; 176: keep the scratch counter in step (and, single-pass, scan the generic's scratch now).
         (%176-generic-skip-scratch name body-and-loc))

       ;; --- STANDARD Compilation (No Optionals) ---
       (t
         (%compile-standard-function form location module builder di-builder di-compile-unit location-map)
         ;; Feature 052: After compiling the forward function, generate and compile
         ;; the _GRAD backward companion when differentiating.
         (when (and *differentiate-p*
                    (not (%fn-name-is-grad-p name))
                    (not is-system))
           (let* ((body-forms (nthcdr (length declare-forms) body-and-loc))
                     (bkwd-form (%generate-backward-function-ast name params declarations body-forms)))
             (when bkwd-form
               (log:info "AUTODIFF: Compiling backward companion for ~a" name)
               (handler-case
                 (compile-def-function bkwd-form location module builder
                                       di-builder di-compile-unit location-map)
                 (error (e)
                   (log:info "AUTODIFF: ~a _GRAD compilation failed: ~a. Unregistering; will error if called from a differentiable kernel." name e)
                   (remhash name *differentiable-functions*)))))))))))

;; src/environment.lisp  (176, supersedes the copy above: variants generated with the BASE name)
(defun instantiate-generic-function (generic-def explicit-arg-types context location)
  "Instantiates a lazy generic function variant for the given argument types."
  (multiple-value-bind (active-env injected-bindings error-message)
      (resolve-argument-bindings generic-def explicit-arg-types)

    (when error-message
          (log:warn "~a" error-message)
          (return-from instantiate-generic-function nil))

    (let* ((name (generic-function-def-name generic-def))
           (declarations (generic-function-def-declarations generic-def))
           ;; Robustly filter declarations from body
           (body (loop for f in (generic-function-def-body generic-def)
                         unless (and (listp f) (eq (car f) 'declare))
                       collect f)))

      ;; 176: a scratch DEFAULT is bound to the implicit parameter Pass 1 registered for it.
      (setf injected-bindings (%bind-defaults-to-default-scratch name injected-bindings))

      ;; Apply injected bindings (Defaults)
      (when injected-bindings
            (setf body (list `(let* ,injected-bindings ,@body))))

      (let* ((active-param-names (mapcar #'parameter-def-name active-env))
             (active-param-types (mapcar #'parameter-def-type active-env))
             (mangled-name (%lazy-variant-name name active-env)))

        ;; BUG 090 (a): one variant per call shape PER MODULE.  The signature is registered under the
        ;; MANGLED name, but calls look up the BASE name, so without this every call site re-analyzed
        ;; -- and, now that variants are generated, would re-define -- the same variant.
        ;; 176: the variant inherits the BASE name's implicit arguments (scratch defaults, and anything
        ;; propagated to the base), so its definition accepts what the call site passes -- calls look up
        ;; the base name.  Its LLVM name is then mangled with those types first, like any carrier.
        (let ((base-implicits (gethash name *implicit-arg-map*)))
          (when base-implicits
            (setf (gethash mangled-name *implicit-arg-map*) base-implicits)))

        (let ((reused (%lazy-variant-already-generated
                       mangled-name active-param-types
                       (append (mapcar #'cdr (gethash mangled-name *implicit-arg-map*)) active-param-types))))
          (when reused
            (log:debug "BUG 090: reusing lazy variant ~s, already generated in this module" mangled-name)
            (return-from instantiate-generic-function reused)))

        (log:info "Lazy Instantiating ~s (Arity ~a) with types ~s" mangled-name (length explicit-arg-types) active-param-types)

        ;; Compile the specific variant
        (let ((ast-node (internal-compile-function mangled-name
                                                   active-env
                                                   (generic-function-def-return-types generic-def)
                                                   active-param-names
                                                   body
                                                   declarations
                                                   (or (generic-function-def-source-location generic-def) location)
                                                   context)))

          ;; BUG 090: GENERATE the variant.  It used to be analyzed and then dropped, so the call site
          ;; emitted a bare `declare` and the module carried an unresolved import.
          (%generate-lazy-variant-ir ast-node mangled-name name)

          ;; Register the signature now that compilation succeeded (and return types might differ/be inferred?)
          ;; Note: Generic def return types are authoritative if present, but AST might have inferred them.
          (let* ((final-ret-types (or (generic-function-def-return-types generic-def)
                                      (semantic-function-return-type ast-node))) ;; If list mismatch, might need validation.
                                                                                (sig (make-function-signature
                                                                                      :name mangled-name
                                                                                      :parameters active-env
                                                                                      :return-types final-ret-types
                                                                                      :source-location (or (generic-function-def-source-location generic-def) location))))

            (log:info "Registering Lazy Signature: ~s -> ~s" mangled-name final-ret-types)
            ;; Append to existing signatures (thread safety? single threaded)
            (setf (gethash mangled-name *function-table*)
              (append (gethash mangled-name *function-table*) (list sig)))

            sig))))))

;;;; ===========================================================================
;;;; Endeavour 176 -- (type-min T), (type-max T), (type-infinity T).
;;;;
;;;; Typed constants: each analyzes to a semantic-literal of type T, so they cost nothing at run time,
;;;; fold in comparisons like any literal, and AD sees a constant.  For floating-point T, type-min and
;;;; type-max are the most negative / positive FINITE values in EVERY precision context (:fast lets the
;;;; compiler assume no value is infinite, so an infinite extreme would be undefined there) -- not C's
;;;; FLT_MIN, which is the smallest positive normal.  (type-infinity T) is positive infinity, for
;;;; floating-point T only; negate it for negative infinity.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new)
(defun %type-extreme-scalar-info (expr location)
  "Validate (type-min|type-max|type-infinity T) and return (values T category bits) for T's scalar
   type, where category is :signed-int, :unsigned-int or :float and bits its width.  Refuses, naming
   what the argument must be, when T is missing or not a numeric scalar type."
  (let* ((op-name (string-downcase (symbol-name (car expr))))
         (type-arg (second expr))
         (resolved (and (= (length expr) 2) (symbolp type-arg) (resolve-type-alias type-arg)))
         (ct (and (symbolp resolved) (gethash resolved *crisp-types*)))
         (category (and ct (crisp-type-category ct))))
    (unless (member category '(:signed-int :unsigned-int :float))
      (error 'crisp-compiler-error
             :message (format nil "~a: ~s is not a numeric scalar type.  (~a T) takes one integer or floating-point type -- int, uint, long, ulong, float, double and the like -- and gives a constant of that type."
                              op-name (if (= (length expr) 2) type-arg (rest expr)) op-name)
             :source-location location))
    (values resolved category (crisp-type-size ct))))

;; src/analysis/ops.lisp  (new)
(defun %float-type-extreme (type-sym bits)
  "The largest FINITE value of floating-point type TYPE-SYM (BITS wide), as a Lisp float."
  (cond
    ((= bits 64) most-positive-double-float)
    ((= bits 32) most-positive-single-float)
    ;; 16-bit: the two formats differ, so tell them apart by name.
    ((string-equal (symbol-name type-sym) "BFLOAT16") 3.3895314e38) ; 0x7F7F
    (t 65504.0)))                                                    ; half, 0x7BFF

;; src/analysis/ops.lisp  (new)
(defun %analyze-type-min (expr env context location)
  "Analyzer for (type-min T): the most negative value of numeric scalar type T, as a constant of type
   T.  For a floating-point T that is the most negative FINITE value (see the section header)."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (make-semantic-literal :value-type type-sym
                           :value (ecase category
                                    (:signed-int   (- (expt 2 (1- bits))))
                                    (:unsigned-int 0)
                                    (:float        (- (%float-type-extreme type-sym bits))))
                           :source-location location)))

;; src/analysis/ops.lisp  (new)
(defun %analyze-type-max (expr env context location)
  "Analyzer for (type-max T): the most positive value of numeric scalar type T, as a constant of type
   T.  For a floating-point T that is the most positive FINITE value (see the section header)."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (make-semantic-literal :value-type type-sym
                           :value (ecase category
                                    (:signed-int   (1- (expt 2 (1- bits))))
                                    (:unsigned-int (1- (expt 2 bits)))
                                    (:float        (%float-type-extreme type-sym bits)))
                           :source-location location)))

;; src/analysis/ops.lisp  (new)
(defun %analyze-type-infinity (expr env context location)
  "Analyzer for (type-infinity T): positive infinity, as a constant of floating-point type T.  Negate it
   for negative infinity.  Meaningful under :ieee precision; an integer T has no infinity and is
   refused."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (unless (eq category :float)
      (error 'crisp-compiler-error
             :message (format nil "type-infinity: ~(~a~) has no infinity -- only floating-point types do.  The largest ~(~a~) is (type-max ~(~a~))."
                              type-sym type-sym type-sym)
             :source-location location))
    (make-semantic-literal :value-type type-sym
                           :value (if (= bits 64)
                                      sb-ext:double-float-positive-infinity
                                      sb-ext:single-float-positive-infinity)
                           :source-location location)))

;; src/analysis/ops.lisp  (176: only change -- TYPE-MIN, TYPE-MAX, TYPE-INFINITY registered)
(defun register-ops-analyzers ()
  "Registers all expression analyzer functions.
Redefined for 082-atomics to add atomic RMW op analyzers.
Endeavor 109: adds mod / rem under both :crisp-language and :crisp.compiler."
  (def-expression-analyzer + analyze-add-expression)
  (def-expression-analyzer - analyze-sub-expression)
  (def-expression-analyzer * analyze-mul-expression)
  (def-expression-analyzer / analyze-div-expression)
  (def-expression-analyzer sin analyze-sin-expression)
  (def-expression-analyzer cos analyze-cos-expression)
  ;; Endeavor 128: transcendentals
  (def-expression-analyzer exp   analyze-exp-expression)
  (def-expression-analyzer log   analyze-log-expression)
  (def-expression-analyzer log2  analyze-log2-expression)
  (def-expression-analyzer tan   analyze-tan-expression)
  (def-expression-analyzer asin  analyze-asin-expression)
  (def-expression-analyzer acos  analyze-acos-expression)
  (def-expression-analyzer atan  analyze-atan-expression)
  (def-expression-analyzer pow   analyze-pow-expression)
  (def-expression-analyzer atan2 analyze-atan2-expression)
  ;; Endeavour 170: the hardware math ops (and the internal AD helper ops) all share one analyzer.
  (dolist (sym (append *hw-op-symbols* *hw-internal-op-symbols*))
    (setf (gethash sym *expression-analyzers*) 'analyze-hw-op-expression))
  ;; Endeavour 173: the four warp shuffles, under both :crisp-language and :crisp.compiler.
  ;; Not def-expression-analyzer, which quotes one literal operator symbol -- these must be
  ;; interned into both packages at run time (user source reads in :crisp-language, where an
  ;; unregistered spelling is silently minted as a fresh symbol rather than reported).
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry *shuffle-op-names*)
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) '%analyze-shuffle)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) '%analyze-shuffle)))))
  (def-expression-analyzer < analyze-lt-expression)
  (def-expression-analyzer > analyze-gt-expression)
  (def-expression-analyzer <= analyze-le-expression)
  (def-expression-analyzer >= analyze-ge-expression)
  (def-expression-analyzer = analyze-eq-expression)
  (def-expression-analyzer != analyze-neq-expression)

  ;; 082-atomics: register under crisp.compiler package symbols
  (def-expression-analyzer atomic-add!  analyze-atomic-add!-expression)
  (def-expression-analyzer atomic-sub!  analyze-atomic-sub!-expression)
  (def-expression-analyzer atomic-inc!  analyze-atomic-inc!-expression)
  (def-expression-analyzer atomic-dec!  analyze-atomic-dec!-expression)
  (def-expression-analyzer atomic-min!  analyze-atomic-min!-expression)
  (def-expression-analyzer atomic-max!  analyze-atomic-max!-expression)
  (def-expression-analyzer atomic-xchg! analyze-atomic-xchg!-expression)
  (def-expression-analyzer atomic-set!  analyze-atomic-set!-expression)

  ;; 082-atomics: also register under crisp-language package symbols.
  (let ((lang (find-package :crisp-language)))
    (when lang
      (dolist (pair '(("ATOMIC-ADD!"  analyze-atomic-add!-expression)
                      ("ATOMIC-SUB!"  analyze-atomic-sub!-expression)
                      ("ATOMIC-INC!"  analyze-atomic-inc!-expression)
                      ("ATOMIC-DEC!"  analyze-atomic-dec!-expression)
                      ("ATOMIC-MIN!"  analyze-atomic-min!-expression)
                      ("ATOMIC-MAX!"  analyze-atomic-max!-expression)
                      ("ATOMIC-XCHG!" analyze-atomic-xchg!-expression)
                      ("ATOMIC-SET!"  analyze-atomic-set!-expression)))
        (setf (gethash (intern (first pair) lang) *expression-analyzers*)
              (second pair)))))

  ;; 109: mod / rem.  Register under both packages.  In :crisp-language
  ;; these names are fresh symbols (the package :uses nothing).  In
  ;; :crisp.compiler they shadow cl:mod / cl:rem.
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry '(("MOD" . analyze-mod-expression)
                     ("REM" . analyze-rem-expression)))
      (let* ((name (car entry))
             (fn-name (cdr entry))
             (sym-cl (intern name cl-pkg))
             (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) fn-name)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn-name)))))

  (def-expression-analyzer to  analyze-value-cast-expression)
  (def-expression-analyzer as  analyze-generic-as-expression)
  (def-expression-analyzer as-bits analyze-bitcast-expression)
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)

  ;; Register cast operators dynamically
  (log:info "Registering cast operators. *crisp-types* count: ~a" (hash-table-count *crisp-types*))
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (when (symbolp type-name)
          (let* ((type-str (symbol-name type-name))
                 (pkg (symbol-package type-name))
                 (to-name (intern (concatenate 'string "TO-" type-str) pkg))
                 (as-name (intern (concatenate 'string "AS-" type-str) pkg)))
            (log:debug "Registering cast/bitcast: ~s / ~s" to-name as-name)
            (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
            (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression))))

  ;; Float-to-int
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-truncate-expression)
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression)

  ;; ---- Endeavour 175: reductions, atomics, and the warp-collective check ----
  ;; Registered under BOTH packages by name, which is why none of these needed a
  ;; package.lisp change -- an analyzer is found by symbol name, not by an exported
  ;; symbol.  (The two WHEN-THREAD-IN-* macros DID need one: MACRO-FUNCTION is per
  ;; symbol, so those are exported from :crisp.compiler and imported into
  ;; :crisp-language rather than registered here.)
  ;;
  ;; MIN and MAX are in this list because Crisp had no scalar min/max at all; they are
  ;; not reductions, but they arrived with them.
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (dolist (pair '(
                        ("%WARP-COLLECTIVE-CHECK"    %analyze-warp-collective-check)
                        ("REDUCE-WARP"               %analyze-reduce-warp)
                        ("REDUCE-WORKGROUP"          %analyze-reduce-workgroup)
                        ("GRID-REDUCE-ATOMIC!"       %analyze-grid-reduce-atomic)
                        ("GRID-REDUCE-LAST-MAN!"     %analyze-grid-reduce-last-man)
                        ("GRID-REDUCE-SECOND-STAGE!" %analyze-grid-reduce-second-stage)
                        ("GRID-REDUCE-CAS!"          %analyze-grid-reduce-cas)
                        ("ATOMIC-CAS!"               analyze-atomic-cas!-expression)
                        ("%ATOMIC-CAS-OK!"           %analyze-atomic-cas-ok!-expression)
                        ("ATOMIC-BINOP!"             %analyze-atomic-binop!)
                        ("ATOMIC-OP!"                %analyze-atomic-op!)
                        ("MIN"                       %analyze-min-expression)
                        ("MAX"                       %analyze-max-expression)
                        ;; 176: typed constants for reduction identities (and anything else).
                        ("TYPE-MIN"                  %analyze-type-min)
                        ("TYPE-MAX"                  %analyze-type-max)
                        ("TYPE-INFINITY"             %analyze-type-infinity)))
          (setf (gethash (intern (first pair) pkg) *expression-analyzers*)
                (second pair)))))))


;;;; ===========================================================================
;;;; Endeavour 175 — reductions and atomics: analyzers and expanders.
;;;; ===========================================================================

(defparameter *grid-atomic-operator-map*
  '(("+" . "ATOMIC-ADD!") ("MIN" . "ATOMIC-MIN!") ("MAX" . "ATOMIC-MAX!"))
  "Operators grid-reduce-atomic! accepts, and the native atomic each lowers to.  The hardware
   provides exactly these three; anything else has no single-instruction form.")

;;;; ===========================================================================
;;;; Endeavour 176 / BUG 095 -- one-argument minus, (- x).
;;;;
;;;; The design doc uses it ((set! (~x~ p) (- newVal)) in chapters/07_crisp_types/17_def_setter.md), the
;;;; reductions doc negates (type-infinity T) with it, but the analyzer was binary-only: (- x) died with
;;;; "Type mismatch for operator '-'. Cannot operate on FLOAT and NIL."  (- x) is now (* x -1): exact IEEE
;;;; negation -- -0.0, infinities and all, which (- 0 x) would get wrong for 0.0 -- that LLVM lowers to
;;;; fneg, and whose derivative AD already knows.
;;;; ===========================================================================

;; src/analysis/ops.lisp  (new: the binary analyzer under its own name, built by the same macro)
(def-binary-op-analyzer %analyze-sub-binary make-semantic-sub "-")

;; src/analysis/ops.lisp  (replaces the (def-binary-op-analyzer analyze-sub-expression ...) expansion)
(defun analyze-sub-expression (expr env context location)
  "Analyzes a `(- ...)` expression.  With two arguments, subtraction.  With ONE, negation -- analyzed as
   (* x -1), exact IEEE negation including -0.0 and infinities (BUG 095)."
  (if (= (length expr) 2)
      (progn
        (log:debug "BUG 095: unary minus ~s analyzed as (* x -1)" expr)
        (analyze-expression (list '* (second expr) -1) env context location))
      (%analyze-sub-binary expr env context location)))
