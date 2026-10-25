;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
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
;;;; ENDEAVOUR 193 (logging-output) -- PHASE A: die halts the thread (BUG 136).
;;;;
;;;; die no longer lowers to llvm.trap (OpUnreachable on SPIR-V, deleted by IGC).  Instead:
;;;;   * every function that MAY DIE (its body has a die, or it calls one that may) takes a
;;;;     trailing LLVM-only `ptr` parameter: the thread's die flag.  NOT a Crisp parameter --
;;;;     mangling, overloads and metadata are untouched.  A kernel that may die allocas the flag.
;;;;   * die = CAS the site id into the module-scope @__crisp_die_record (first death wins),
;;;;     store 1 to the flag, return zero of the function's return type.
;;;;   * after every call to a may-die function: load the flag, return if it is set.
;;;; Same lowering on both backends.  Probes: put_temp_files_here/logging-probes/FINDINGS.md.
;;;; The --runtime-checks bounds checks still use %handle-die-intrinsic (llvm.trap) until Phase C.
;;;; =====================================================================================

;; src/llvm-bindings.lisp (endeavour 193) -- defined in crisp.compiler so no export is needed
(cffi:defcfun ("LLVMCountParamTypes" llvm-count-param-types) :unsigned-int
  (fn-type :pointer))
(cffi:defcfun ("LLVMGetParamTypes" llvm-get-param-types) :void
  (fn-type :pointer)
  (dest    :pointer))
(cffi:defcfun ("LLVMCountParams" llvm-count-params) :unsigned-int
  (fn :pointer))

;; src/compiler.lisp (endeavour 193)
(defvar *may-die-functions* (make-hash-table)
  "Endeavour 193.  Function name -> T for every function that may reach a die: directly, or by
   calling one that may.  Filled by the Pass-1 scan (%193-compute-may-die-functions, multi-pass)
   and by analysis (analyze-die-expression / analyze-function-call, both modes).  Such a function
   gets the trailing die-flag parameter.")

;; src/compiler.lisp (endeavour 193)
(defvar *die-messages* (make-hash-table :test 'equal)
  "Endeavour 193.  Source location of a die -> its compile-time message string (or NIL).
   Phase B turns these into the site table.")

;; src/compiler.lisp (endeavour 193)
(defvar *die-sites* nil
  "Endeavour 193.  Per-module list of (site-id location message), newest first.  Site ids start
   at 1; 0 in the die record means nobody died.")

;; src/codegen.lisp (endeavour 193)
(defvar *die-flag-ptr* nil
  "Endeavour 193.  While a may-die function's body is generated: the LLVM pointer to the thread's
   i32 die flag (the kernel's entry alloca, or the function's trailing parameter).  NIL otherwise.")

;; src/codegen.lisp (endeavour 193)
(defvar *193-flag-pending* nil
  "Endeavour 193.  Set by generate-function-body for a may-die function: :ALLOCA (kernel) or
   :PARAM (function).  initialize-function-parameters consumes it and binds *die-flag-ptr*.")

;; src/codegen.lisp (endeavour 193)
(defvar *193-flag-func* nil
  "Endeavour 193.  The LLVM function *193-flag-pending* belongs to.")

;; src/compiler.lisp (endeavour 193)
(defun %193-die-symbol-p (sym)
  "Endeavour 193.  T when SYM names die (by name: user code is read in :crisp-language)."
  (and (symbolp sym) (string= (symbol-name sym) "DIE")))

;; src/compiler.lisp (endeavour 193)
(defun %193-may-die-p (name)
  "Endeavour 193.  T when the function NAME may reach a die (see *may-die-functions*)."
  (and name (gethash name *may-die-functions*) t))

;; src/compiler.lisp (endeavour 193)
(defun %193-body-dies-directly-p (body)
  "Endeavour 193.  T when the SURFACE forms BODY contain (die ...) -- or, under --runtime-checks,
   an r-t-assert / r-t-assert-0, which then expand to (unless test (die)).  A raw walk: no macro
   expansion, because expanding Crisp macros in Pass 1 has side effects (scratch counters).  A die
   that only a user macro produces is caught at analysis instead (analyze-die-expression), which
   covers every case except a caller compiled BEFORE such a callee -- and that one fails loudly in
   %193-call-flag-arg rather than miscompiling."
  (labels ((walk (f depth)
             (cond ((or (atom f) (> depth 400)) nil)
                   ((%193-die-symbol-p (car f)) t)
                   ((and *runtime-checks-enabled* (symbolp (car f))
                         (member (symbol-name (car f)) '("R-T-ASSERT" "R-T-ASSERT-0") :test #'string=))
                    t)
                   (t (loop for tail on f
                            thereis (and (consp tail) (walk (car tail) (1+ depth))))))))
    (walk body 0)))

;; src/analysis/core.lisp (endeavour 193)
(defun %193-compute-may-die-functions ()
  "Endeavour 193, Pass 1.5 (multi-pass only).  Seeds *may-die-functions* from every function body
   Pass 1 captured in *fn-normalized-info* that dies directly, then propagates to callers over
   *call-graph* -- the same walk propagate-implicit-arguments does for scratch.  Crisp has no
   recursion, so this terminates."
  (clrhash *may-die-functions*)
  (let ((worklist '()))
    (maphash (lambda (name info)
               (when (%193-body-dies-directly-p (getf info :body))
                 (log:info "193: ~a dies directly" name)
                 (setf (gethash name *may-die-functions*) t)
                 (push name worklist)))
             *fn-normalized-info*)
    (loop while worklist
          do (let ((callee (pop worklist)))
               (loop for caller being the hash-keys of *call-graph* using (hash-value callees)
                     when (and (member callee callees) (not (gethash caller *may-die-functions*)))
                       do (log:info "193: ~a may die (calls ~a)" caller callee)
                          (setf (gethash caller *may-die-functions*) t)
                          (push caller worklist))))
    (log:info "193: may-die functions: ~s" (alexandria:hash-table-keys *may-die-functions*))))

;; src/analysis/core.lisp (endeavour 193) -- FOLD: call %193-compute-may-die-functions at the end of
;; propagate-implicit-arguments (or beside it in the Pass 1.5 step of the module compile).
(defvar *193-orig-propagate-implicit-arguments* (fdefinition 'propagate-implicit-arguments))
(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers.
   Endeavour 193: then computes *may-die-functions* over the same call graph."
  (funcall *193-orig-propagate-implicit-arguments*)
  (%193-compute-may-die-functions))

;; src/compiler.lisp (endeavour 193) -- FOLD: three reset lines in initialize-compiler.
(defvar *193-orig-initialize-compiler* (fdefinition 'initialize-compiler))
(defun initialize-compiler (&rest args)
  "Endeavour 193 wrapper: also resets the die tables (single-pass compiles have no Pass 1 to do it)."
  (prog1 (apply *193-orig-initialize-compiler* args)
    (clrhash *may-die-functions*)
    (clrhash *die-messages*)
    (setf *die-sites* nil)))

;; src/analysis/ops.lisp (endeavour 193)
(defun analyze-die-expression (expr env context location)
  "Endeavour 193.  (die) or (die \"message\").  The message must be a compile-time string: the
   die record carries only a site id, which the metadata maps back to file, line and message.
   Marks the function being compiled as may-die (this is what --single-pass relies on, and what
   catches a die produced by a user macro)."
  (declare (ignore env))
  (let ((args (rest expr)))
    (when (> (length args) 1)
      (error 'crisp-compiler-error
        :message (format nil "die takes at most one argument, a message, but was given ~d." (length args))
        :source-location location))
    (when (and args (not (stringp (first args))))
      (error 'crisp-compiler-error
        :message (format nil "die's message must be a compile-time string, not ~s.  The die record carries only a site id; the message is looked up in the metadata." (first args))
        :source-location location))
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (log:debug "193: analyzing die ~s in ~a at ~s" (first args) fn location)
      (when fn
        (setf (gethash fn *may-die-functions*) t)))
    (setf (gethash location *die-messages*) (first args))
    (make-semantic-call :name 'die
                        :type '(nil)
                        :args nil
                        :signature (first (gethash 'die *function-table*))
                        :source-location location)))

;; src/analysis/ops.lisp (endeavour 193) -- FOLD: two setf lines at the end of register-ops-analyzers.
(defvar *193-orig-register-ops-analyzers* (fdefinition 'register-ops-analyzers))
(defun register-ops-analyzers ()
  "Endeavour 193 wrapper: also registers analyze-die-expression for die."
  (funcall *193-orig-register-ops-analyzers*)
  (setf (gethash 'die *expression-analyzers*) #'analyze-die-expression)
  (let ((lang-die (find-symbol "DIE" :crisp-language)))
    (when (and lang-die (not (eq lang-die 'die)))
      (setf (gethash lang-die *expression-analyzers*) #'analyze-die-expression))))

;; src/analysis/core.lisp (endeavour 193) -- FOLD: the marking at the end of analyze-function-call.
(defvar *193-orig-analyze-function-call* (fdefinition 'analyze-function-call))
(defun analyze-function-call (op expr env context location)
  "Endeavour 193 wrapper: a call to a may-die function makes the caller may-die too.  In
   multi-pass compiles Pass 1.5 already knows; this is what --single-pass relies on.  A lazily
   instantiated variant (a different callee name) inherits the base function's status."
  (let ((node (funcall *193-orig-analyze-function-call* op expr env context location)))
    (when (%193-may-die-p op)
      (let ((caller (and context (compiler-context-current-compiling-function context))))
        (when (and (semantic-call-p node) (not (eq (semantic-call-name node) op)))
          (setf (gethash (semantic-call-name node) *may-die-functions*) t))
        (when (and caller (not (%193-may-die-p caller)))
          (log:info "193: ~a may die (analysis: calls ~a)" caller op)
          (setf (gethash caller *may-die-functions*) t))))
    node))

;; src/codegen.lisp (endeavour 193)
(defun %193-append-flag-param (fn-type)
  "Endeavour 193.  FN-TYPE with one more parameter at the end: the die flag pointer (ptr, addrspace 0
   -- the thread's private memory on both backends)."
  (let* ((n (llvm-count-param-types fn-type))
         (arr (cffi:foreign-alloc 'llvm-type-ref :count (1+ n))))
    (when (plusp n)
      (llvm-get-param-types fn-type arr))
    (setf (cffi:mem-aref arr 'llvm-type-ref n) (llvm-pointer-type (llvm-int32-type) 0))
    (llvm-function-type (crisp.llvm-bindings::llvm-get-return-type fn-type) arr (1+ n) nil)))

;; src/codegen.lisp (endeavour 193) -- FOLD: the one `when` after fn-type in generate-function-prototype.
(defun generate-function-prototype (semantic-function module di-builder di-compile-unit location-map)
  "Generates the LLVM function prototype and debug info.
   For PTX entry points, threads IS-ENTRY-POINT and FN-NAME into
   CREATE-LLVM-FUNCTION-TYPE so shared/local pointer params get demoted
   to i64 at the kernel boundary, and the post-demotion verifier can
   error with the kernel name (see header comment).
   Endeavour 193: a non-entry function that may die gets the trailing die-flag parameter."
  (let* ((return-types (semantic-function-return-type semantic-function))
         (crisp-return-type (first return-types))
         (base-name (semantic-function-name semantic-function))
         (is-entry-point (semantic-function-is-entry-point semantic-function))

         (mangled-name (if is-entry-point
                           (string-downcase (symbol-name base-name))
                           (let ((param-type-specs (mapcar #'semantic-param-type (semantic-function-param-list semantic-function))))
                             (format nil "~a~{_~a~}" base-name (mapcar #'mangle-type-spec param-type-specs)))))

         (fn-name (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name))))
         (fn-loc (semantic-function-source-location semantic-function))
         (param-nodes (semantic-function-param-list semantic-function))
         (fn-type (create-llvm-function-type module return-types param-nodes is-entry-point fn-name)))

    (when (and (not is-entry-point) (%193-may-die-p base-name))
      (log:info "193: ~a may die -- adding the die-flag parameter" fn-name)
      (setf fn-type (%193-append-flag-param fn-type)))

    (log:info "llvm-add-function: ~a Module: ~a" fn-name module)

    (setf *cached-int32-type* (llvm-int32-type))
    (setf *cached-int64-type* (llvm-int64-type))
    (log:debug "Cached INT32 (Global): ~a" *cached-int32-type*)

    (when (eq *target-backend* :ptx)
          (let ((type-obj (gethash crisp-return-type *crisp-types*)))
            (when (and type-obj (member (crisp-type-category type-obj) '(:struct :record)))
                  (log:warn "Skipping generation of function ~a on PTX due to struct return value (unsupported)." fn-name)
                  (return-from generate-function-prototype (values nil nil)))))

    (let ((existing (llvm-get-named-function module fn-name)))
      (if (and existing (not (cffi:null-pointer-p existing)))
          (%check-existing-function existing fn-name di-builder di-compile-unit
                                    (llvm-add-function module fn-name fn-type)
                                    crisp-return-type param-nodes location-map fn-loc module fn-type)
          (%create-new-function fn-name fn-type module di-builder di-compile-unit
                                crisp-return-type param-nodes location-map fn-loc)))))

;; src/codegen.lisp (endeavour 193) -- FOLD: bind the three specials at the top of generate-function-body.
(defvar *193-orig-generate-function-body* (fdefinition 'generate-function-body))
(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Endeavour 193 wrapper: for a may-die function, arranges for initialize-function-parameters to
   bind *die-flag-ptr* -- a fresh entry alloca (kernel) or the trailing parameter (function)."
  (let* ((name (semantic-function-name semantic-function))
         (entry-p (semantic-function-is-entry-point semantic-function))
         (*die-flag-ptr* nil)
         (*193-flag-pending* (when (%193-may-die-p name) (if entry-p :alloca :param)))
         (*193-flag-func* func))
    (when *193-flag-pending*
      (log:debug "193: body of ~a (may die, flag via ~a)" name *193-flag-pending*))
    (funcall *193-orig-generate-function-body*
             semantic-function func di-subprogram builder module di-builder location-map)))

;; src/codegen.lisp (endeavour 193) -- FOLD: the flag set-up at the end of initialize-function-parameters.
(defvar *193-orig-initialize-function-parameters* (fdefinition 'initialize-function-parameters))
(defun initialize-function-parameters (builder func param-nodes module var-env &optional is-entry-point)
  "Allocates stack space and stores function parameters.
   Endeavour 193 wrapper: then, for a may-die function, binds *die-flag-ptr*.  A kernel allocas
   the flag and zeroes it; a function takes it from its last parameter."
  (prog1 (funcall *193-orig-initialize-function-parameters*
                  builder func param-nodes module var-env is-entry-point)
    (when (and *193-flag-pending* (cffi:pointer-eq func *193-flag-func*))
      (setf *die-flag-ptr*
            (ecase *193-flag-pending*
              (:alloca (let ((a (llvm-build-alloca builder (llvm-int32-type) "die_flag")))
                         (llvm-build-store builder (llvm-const-int (llvm-int32-type) 0 0) a)
                         a))
              (:param (llvm-get-param func (1- (llvm-count-params func))))))
      (log:debug "193: die flag bound (~a)" *193-flag-pending*)
      (setf *193-flag-pending* nil))))

;; src/codegen.lisp (endeavour 193)
(defun %193-die-record-global (module)
  "Endeavour 193.  The module-scope die record: @__crisp_die_record, [4 x i32] in addrspace(1),
   zero-initialised, external (Export) linkage so the host can find it by name
   (zeModuleGetGlobalPointer / cuModuleGetGlobal).  Layout: site_id, group_id, local_id, reserved."
  (let ((g (llvm-get-named-global module "__crisp_die_record")))
    (if (and g (not (cffi:null-pointer-p g)))
        g
        (let* ((ty (llvm-array-type (llvm-int32-type) 4))
               (g (llvm-add-global-in-addrspace module ty "__crisp_die_record" 1)))
          (llvm-set-initializer g (llvm-const-null ty))
          (log:info "193: created @__crisp_die_record")
          g))))

;; src/codegen.lisp (endeavour 193)
(defun %193-build-bail-return (builder)
  "Endeavour 193.  Returns from the function BUILDER is in with zero of its return type (ret void
   for a void function or kernel).  The value is never used: every caller bails out after it."
  (let* ((fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (ret-ty (crisp.llvm-bindings::llvm-get-return-type (crisp.llvm-bindings::llvm-global-get-value-type fn))))
    (if (= (llvm-get-type-kind ret-ty) 0)     ; LLVMVoidTypeKind
        (llvm-build-ret-void builder)
        (llvm-build-ret builder (llvm-const-null ret-ty)))))

;; src/codegen.lisp (endeavour 193)
(defun %193-emit-die (builder module location)
  "Endeavour 193.  The die lowering: claim the die record (CAS site id over 0, relaxed), set this
   thread's die flag, return.  Code after it goes into a fresh block with no predecessors, as
   return-from-loop does.  Phase B fills group/local ids for the CAS winner."
  (unless *die-flag-ptr*
    (error "Compiler bug (endeavour 193): die reached codegen in a function that was not marked may-die (location ~s)." location))
  (let* ((site-id (1+ (length *die-sites*)))
         (message (gethash location *die-messages*))
         (rec (%193-die-record-global module))
         (i32 (llvm-int32-type)))
    (push (list site-id location message) *die-sites*)
    (log:info "193: die site ~d at ~s ~s" site-id location message)
    (crisp.llvm-bindings::llvm-build-atomic-cmpxchg builder rec (llvm-const-int i32 0 0) (llvm-const-int i32 site-id 0)
                               2 2 0)       ; monotonic / monotonic, not single-thread
    (llvm-build-store builder (llvm-const-int i32 1 0) *die-flag-ptr*)
    (%193-build-bail-return builder)
    (let ((fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
      (llvm-position-builder-at-end builder (llvm-append-basic-block fn "after_die")))
    (values nil nil)))

;; src/codegen.lisp (endeavour 193) -- FOLD: replace the %handle-die-intrinsic special case at the top
;; of generate-node-ir (semantic-call) with a call to %193-emit-die.
(defmethod generate-node-ir :around ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Endeavour 193: die lowers to %193-emit-die, not llvm.trap."
  (if (eq (semantic-call-name node) 'die)
      (%193-emit-die builder module (semantic-call-source-location node))
      (call-next-method)))

;; src/codegen.lisp (endeavour 193)
(defun %193-call-flag-arg (callee caller-fn)
  "Endeavour 193.  The die flag a call to may-die CALLEE passes.  The caller must itself be
   may-die (propagation guarantees it); if not, the call graph was incomplete -- fail loudly."
  (or *die-flag-ptr*
      (error "Compiler bug (endeavour 193): ~a calls may-die function ~a but has no die flag.  (A die that only a macro produces, in a callee defined AFTER its caller, is not seen by Pass 1.)"
             (crisp.llvm-bindings::llvm-get-value-name caller-fn) callee)))

;; src/codegen.lisp (endeavour 193) -- FOLD: the may-die branches into %build-function-call.
(defun %build-function-call (builder module var-env di-builder di-scope location-map node sig callee-name llvm-fn-type param-nodes param-count return-type-names)
  "Helper: Builds the actual function call instruction.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Required on SPV builds — see overlay
   header for the InstCombine UB bug this fix addresses.
   Endeavour 193: a call to a may-die function passes the die flag as a trailing argument, then
   loads it and returns from the caller if the callee died."
  (declare (ignore sig))
  (let* ((callee-sym (semantic-call-name node))
         (dies-p (and (%193-may-die-p callee-sym)
                      (not (gethash callee-sym *foreign-functions*))))
         (fn-type (if dies-p (%193-append-flag-param llvm-fn-type) llvm-fn-type))
         (arg-nodes (semantic-call-args node))
         (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                             arg-nodes param-nodes param-count))
         (caller-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (n-args (if dies-p (1+ param-count) param-count))
         (final-args (if dies-p
                         (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count n-args)))
                           (dotimes (i param-count)
                             (setf (cffi:mem-aref arr 'llvm-value-ref i) (cffi:mem-aref args-array 'llvm-value-ref i)))
                           (setf (cffi:mem-aref arr 'llvm-value-ref param-count) (%193-call-flag-arg callee-sym caller-fn))
                           arr)
                         args-array))
         (callee-fn (let ((f (llvm-get-named-function module callee-name)))
                      (if (cffi:null-pointer-p f)
                          (llvm-add-function module callee-name fn-type)
                          f)))
         (call-inst (llvm-build-call2 builder
                                      fn-type
                                      callee-fn
                                      final-args
                                      n-args
                                      (if (or (null return-type-names)
                                              (equal return-type-names '(nil))
                                              (and (consp return-type-names) (eq (first return-type-names) 'void)))
                                          ""
                                          "call_tmp")))
         (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
    (%propagate-callee-cc-to-call call-inst callee-fn)
    (when dies-p
      (log:debug "193: call to may-die ~a -- checking the die flag after it" callee-name)
      (let* ((flag (llvm-build-load2 builder (llvm-int32-type) *die-flag-ptr* "die_flag_val"))
             (dead (llvm-build-icmp builder +llvm-int-ne+ flag (llvm-const-int (llvm-int32-type) 0 0) "died"))
             (bail (llvm-append-basic-block caller-fn "die_bail"))
             (cont (llvm-append-basic-block caller-fn "die_cont")))
        (llvm-build-cond-br builder dead bail cont)
        (llvm-position-builder-at-end builder bail)
        (%193-build-bail-return builder)
        (llvm-position-builder-at-end builder cont)))
    (values call-inst di-location)))

;; src/analysis/ops.lisp (endeavour 193) -- the function being analysed.  *analyzing-function* is
;; bound by internal-def-function in BOTH modes; the context's current-compiling-function is NIL in
;; a single-pass compile-crisp-form-to-ir-string (found by tests/test-runtime-checks.lisp).
(defun %193-current-function (context)
  "Endeavour 193.  The name of the function whose body is being analysed, or NIL."
  (or *analyzing-function*
      (and context (compiler-context-current-compiling-function context))))

;; src/analysis/ops.lisp (endeavour 193) -- supersedes the copy above (uses %193-current-function).
(defun analyze-die-expression (expr env context location)
  "Endeavour 193.  (die) or (die \"message\").  The message must be a compile-time string: the
   die record carries only a site id, which the metadata maps back to file, line and message.
   Marks the function being compiled as may-die (this is what --single-pass relies on, and what
   catches a die produced by a user macro)."
  (declare (ignore env))
  (let ((args (rest expr)))
    (when (> (length args) 1)
      (error 'crisp-compiler-error
        :message (format nil "die takes at most one argument, a message, but was given ~d." (length args))
        :source-location location))
    (when (and args (not (stringp (first args))))
      (error 'crisp-compiler-error
        :message (format nil "die's message must be a compile-time string, not ~s.  The die record carries only a site id; the message is looked up in the metadata." (first args))
        :source-location location))
    (let ((fn (%193-current-function context)))
      (log:debug "193: analyzing die ~s in ~a at ~s" (first args) fn location)
      (if fn
          (setf (gethash fn *may-die-functions*) t)
          (log:warn "193: die at ~s analysed outside any function" location)))
    (setf (gethash location *die-messages*) (first args))
    (make-semantic-call :name 'die
                        :type '(nil)
                        :args nil
                        :signature (first (gethash 'die *function-table*))
                        :source-location location)))

;; src/analysis/core.lisp (endeavour 193) -- supersedes the copy above (uses %193-current-function).
(defun analyze-function-call (op expr env context location)
  "Endeavour 193 wrapper: a call to a may-die function makes the caller may-die too.  In
   multi-pass compiles Pass 1.5 already knows; this is what --single-pass relies on.  A lazily
   instantiated variant (a different callee name) inherits the base function's status."
  (let ((node (funcall *193-orig-analyze-function-call* op expr env context location)))
    (when (%193-may-die-p op)
      (let ((caller (%193-current-function context)))
        (when (and (semantic-call-p node) (not (eq (semantic-call-name node) op)))
          (setf (gethash (semantic-call-name node) *may-die-functions*) t))
        (when (and caller (not (%193-may-die-p caller)))
          (log:info "193: ~a may die (analysis: calls ~a)" caller op)
          (setf (gethash caller *may-die-functions*) t))))
    node))

;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE B: the die record report.
;;;;   * real source lines: while crisp.main reads a .crisp file, the `(` reader records every
;;;;     list it reads (cons -> (file . line)) in a weak table.  analyze-expression tracks the
;;;;     innermost enclosing form with a line, so a die that a macro builds (r-t-assert) takes
;;;;     the macro call's line.  (The --debug location-map holds VIRTUAL lines, so it can't be used.)
;;;;   * die carries two argument nodes -- (to-int group-linear-id) and (to-int local-linear-id) --
;;;;     generated only by the CAS winner, into words 1 and 2 of @__crisp_die_record.
;;;;   * the .metacrisp gains a top-level (:die-sites :record "__crisp_die_record" :sites
;;;;     ((id "file" line "message-or-nil") ...)) section; the launchers print the DIE line.
;;;; =====================================================================================

;; src/reader.lisp (endeavour 193)
(defvar *193-form-sites* (make-hash-table :test 'eq :weakness :key)
  "Endeavour 193.  A list read from a .crisp file -> (FILE-NAMESTRING . LINE).  Weak, so it never
   holds a form alive; filled only while *193-read-file* is bound.")

;; src/reader.lisp (endeavour 193)
(defvar *193-read-file* nil
  "Endeavour 193.  While crisp.main reads a .crisp file: (FILE-NAMESTRING . NEWLINE-OCTET-OFFSETS).
   NIL otherwise, and the `(` reader then does nothing extra.")

;; src/analysis/core.lisp (endeavour 193)
(defvar *193-enclosing-site* nil
  "Endeavour 193.  (FILE . LINE) of the innermost form being analysed that came from a file.")

;; src/reader.lisp (endeavour 193)
(defun %193-newline-offsets (path)
  "Endeavour 193.  A vector of the octet offsets of every LF in the file at PATH."
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8)))
          (out (make-array 64 :adjustable t :fill-pointer 0)))
      (read-sequence buf s)
      (loop for i from 0 below (length buf)
            when (= (aref buf i) 10) do (vector-push-extend i out))
      out)))

;; src/reader.lisp (endeavour 193)
(defun %193-line-of (offset newlines)
  "Endeavour 193.  1-based line of octet OFFSET, given the LF offsets NEWLINES (sorted)."
  (1+ (or (position-if (lambda (nl) (>= nl offset)) newlines) (length newlines))))

;; src/reader.lisp (endeavour 193)
(defvar *193-orig-paren-reader* (get-macro-character #\())

;; src/reader.lisp (endeavour 193)
(defun %193-paren-reader (stream char)
  "Endeavour 193.  The `(` reader macro, recording where each list came from while a .crisp file is
   read (*193-read-file*).  FILE-POSITION is just past the `(`."
  (if *193-read-file*
      (let* ((pos (ignore-errors (file-position stream)))
             (form (funcall *193-orig-paren-reader* stream char)))
        (when (and pos (consp form))
          (setf (gethash form *193-form-sites*)
                (cons (car *193-read-file*) (%193-line-of (1- pos) (cdr *193-read-file*)))))
        form)
      (funcall *193-orig-paren-reader* stream char)))

(set-macro-character #\( #'%193-paren-reader)

;; src/reader.lisp (endeavour 193)
(defmacro %193-with-read-file ((path) &body body)
  "Endeavour 193.  Runs BODY with *193-read-file* bound for the .crisp file at PATH."
  `(let ((*193-read-file* (cons (file-namestring ,path) (%193-newline-offsets ,path))))
     ,@body))

;; src/main.lisp (endeavour 193) -- FOLD: the %193-with-read-file around each file's read.
(defun crisp.main::%read-crisp-forms (files)
  "Every top-level form of FILES, in order, read in :crisp-language.
   Endeavour 193: records each list's file and line (*193-form-sites*) for the die report."
  (let ((*package* (find-package :crisp-language)))
    (loop for f in files
          appending (%193-with-read-file (f)
                      (with-open-file (stream f)
                        (loop for form = (read stream nil :eof)
                              until (eq form :eof)
                              collect form))))))

;; src/main.lisp (endeavour 193) -- FOLD: the %193-with-read-file around each file's read.
(defun crisp.main::%compile-files-single-pass (files module builder di-builder di-compile-unit)
  "--single-pass: compile each file's forms as they are read, with one shared toplevel index so that
   location indices are unique across the entire compilation unit.
   Endeavour 193: records each list's file and line (*193-form-sites*) for the die report."
  (let ((toplevel-index 0)
        (*package* (find-package :crisp-language)))
    (dolist (f files)
      (%193-with-read-file (f)
        (with-open-file (stream f)
          (loop for form = (read stream nil :eof)
                until (eq form :eof)
                do (let ((location (list toplevel-index)))
                     (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit nil)
                     (incf toplevel-index))))))))

;; src/analysis/core.lisp (endeavour 193) -- FOLD: bind *193-enclosing-site* at the top of analyze-expression.
(defvar *193-orig-analyze-expression* (fdefinition 'analyze-expression))
(defun analyze-expression (expr env context location)
  "Recursively analyzes a *single* expression.
   Endeavour 193 wrapper: tracks the innermost form that came from a file (*193-enclosing-site*)."
  (let ((*193-enclosing-site* (or (and (consp expr) (gethash expr *193-form-sites*))
                                  *193-enclosing-site*)))
    (funcall *193-orig-analyze-expression* expr env context location)))

;; src/analysis/ops.lisp (endeavour 193)
(defparameter +193-die-id-forms+
  '((to-int (+ (get-workgroup-id 0)
               (* (get-num-groups 0)
                  (+ (get-workgroup-id 1)
                     (* (get-num-groups 1) (get-workgroup-id 2))))))
    (to-int (get-local-linear-id)))
  "Endeavour 193.  What the CAS winner writes into words 1 and 2 of the die record: the linear
   workgroup id and the linear local id.")

;; src/analysis/ops.lisp (endeavour 193) -- supersedes both copies above.
(defun analyze-die-expression (expr env context location)
  "Endeavour 193.  (die) or (die \"message\").  The message must be a compile-time string: the
   die record carries only a site id, which the metadata maps back to file, line and message.
   Marks the function being compiled as may-die (this is what --single-pass relies on, and what
   catches a die produced by a user macro).  Phase B: records the site's file and line, and
   carries the group/local id expressions as the call's argument nodes."
  (let ((args (rest expr)))
    (when (> (length args) 1)
      (error 'crisp-compiler-error
        :message (format nil "die takes at most one argument, a message, but was given ~d." (length args))
        :source-location location))
    (when (and args (not (stringp (first args))))
      (error 'crisp-compiler-error
        :message (format nil "die's message must be a compile-time string, not ~s.  The die record carries only a site id; the message is looked up in the metadata." (first args))
        :source-location location))
    (let ((fn (%193-current-function context))
          (site (or (gethash expr *193-form-sites*) *193-enclosing-site*)))
      (log:debug "193: analyzing die ~s in ~a at ~s (source ~s)" (first args) fn location site)
      (if fn
          (setf (gethash fn *may-die-functions*) t)
          (log:warn "193: die at ~s analysed outside any function" location))
      (setf (gethash location *die-messages*) (list (first args) (car site) (cdr site))))
    (make-semantic-call :name 'die
                        :type '(nil)
                        :args (loop for f in +193-die-id-forms+
                                    for i from 1
                                    collect (analyze-expression f env context (append location (list i))))
                        :signature (first (gethash 'die *function-table*))
                        :source-location location)))

;; src/codegen.lisp (endeavour 193) -- supersedes the copy above.
(defun %193-emit-die (builder module location &optional node var-env di-builder di-scope location-map)
  "Endeavour 193.  The die lowering: claim the die record (CAS site id over 0, relaxed); the winner
   writes its linear group id and local id into words 1 and 2.  Then set this thread's die flag and
   return.  Code after it goes into a fresh block with no predecessors, as return-from-loop does."
  (unless *die-flag-ptr*
    (error "Compiler bug (endeavour 193): die reached codegen in a function that was not marked may-die (location ~s)." location))
  (let* ((info (gethash location *die-messages*))
         ;; One id per source location: a two-target compile (spv + ptx) generates the module
         ;; twice, and a template body may be instantiated more than once.
         (existing (find location *die-sites* :key #'fifth :test #'equal))
         (site-id (if existing (first existing) (1+ (length *die-sites*))))
         (rec (%193-die-record-global module))
         (rec-ty (llvm-array-type (llvm-int32-type) 4))
         (i32 (llvm-int32-type))
         (fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
    (unless existing
      (push (list site-id (second info) (third info) (first info) location) *die-sites*))
    (log:info "193: die site ~d: ~a:~a ~s" site-id (second info) (third info) (first info))
    (let* ((pair (crisp.llvm-bindings::llvm-build-atomic-cmpxchg
                  builder rec (llvm-const-int i32 0 0) (llvm-const-int i32 site-id 0) 2 2 0))
           (won (llvm-build-extract-value builder pair 1 "die_won"))
           (fill (llvm-append-basic-block fn "die_fill"))
           (done (llvm-append-basic-block fn "die_done")))
      (llvm-build-cond-br builder won fill done)
      (llvm-position-builder-at-end builder fill)
      (when node
        (loop for arg in (semantic-call-args node)
              for word from 1
              do (let* ((v (generate-node-ir arg builder module var-env di-builder di-scope location-map))
                        (idx (cffi:foreign-alloc 'llvm-value-ref :count 2)))
                   (setf (cffi:mem-aref idx 'llvm-value-ref 0) (llvm-const-int i32 0 0)
                         (cffi:mem-aref idx 'llvm-value-ref 1) (llvm-const-int i32 word 0))
                   (llvm-build-store builder v
                                     (llvm-build-in-bounds-gep2 builder rec-ty rec idx 2 "die_word")))))
      (llvm-build-br builder done)
      (llvm-position-builder-at-end builder done))
    (llvm-build-store builder (llvm-const-int i32 1 0) *die-flag-ptr*)
    (%193-build-bail-return builder)
    (llvm-position-builder-at-end builder (llvm-append-basic-block fn "after_die"))
    (values nil nil)))

;; src/codegen.lisp (endeavour 193) -- supersedes the method above.
(defmethod generate-node-ir :around ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Endeavour 193: die lowers to %193-emit-die, not llvm.trap."
  (if (eq (semantic-call-name node) 'die)
      (%193-emit-die builder module (semantic-call-source-location node)
                     node var-env di-builder di-scope location-map)
      (call-next-method)))

;; src/metadata.lisp (endeavour 193)
(defun %193-serialize-die-sites (stream)
  "Endeavour 193.  The (:die-sites ...) section: the record's global name and every site, oldest
   first, as (ID \"FILE\" LINE \"MESSAGE\"-or-NIL).  Nothing when the module cannot die."
  (when *die-sites*
    (format stream "(:die-sites :record \"__crisp_die_record\"~%  :sites (")
    (dolist (s (reverse *die-sites*))
      (format stream "~%    (~d ~s ~s ~s)" (first s) (or (second s) "?") (or (third s) 0) (fourth s)))
    (format stream "))~%")))

;; src/metadata.lisp (endeavour 193) -- FOLD: call %193-serialize-die-sites after the kernels section.
(defvar *193-orig-serialize-kernels* (fdefinition 'serialize-kernels))
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Endeavour 193 wrapper: then the (:die-sites ...) section."
  (prog1 (funcall *193-orig-serialize-kernels* output-stream kernel-names
                  :source source :output-targets output-targets)
    (%193-serialize-die-sites output-stream)))

;; src/analysis/ops.lisp (endeavour 193) -- supersedes the copies above: the id expressions are analysed
;; as if in a dispatch context -- the record is the compiler's own bookkeeping, and a die in a
;; def-function (spec 13) must still name its thread; GPU builtins are refused there for USER code.
(defun analyze-die-expression (expr env context location)
  "Endeavour 193.  (die) or (die \"message\").  The message must be a compile-time string: the
   die record carries only a site id, which the metadata maps back to file, line and message.
   Marks the function being compiled as may-die (this is what --single-pass relies on, and what
   catches a die produced by a user macro).  Phase B: records the site's file and line, and
   carries the group/local id expressions as the call's argument nodes."
  (let ((args (rest expr)))
    (when (> (length args) 1)
      (error 'crisp-compiler-error
        :message (format nil "die takes at most one argument, a message, but was given ~d." (length args))
        :source-location location))
    (when (and args (not (stringp (first args))))
      (error 'crisp-compiler-error
        :message (format nil "die's message must be a compile-time string, not ~s.  The die record carries only a site id; the message is looked up in the metadata." (first args))
        :source-location location))
    (let ((fn (%193-current-function context))
          (site (or (gethash expr *193-form-sites*) *193-enclosing-site*)))
      (log:debug "193: analyzing die ~s in ~a at ~s (source ~s)" (first args) fn location site)
      (if fn
          (setf (gethash fn *may-die-functions*) t)
          (log:warn "193: die at ~s analysed outside any function" location))
      (setf (gethash location *die-messages*) (list (first args) (car site) (cdr site))))
    (make-semantic-call :name 'die
                        :type '(nil)
                        :args (let ((*in-dispatch-context* t))
                                (loop for f in +193-die-id-forms+
                                      for i from 1
                                      collect (analyze-expression f env context (append location (list i)))))
                        :signature (first (gethash 'die *function-table*))
                        :source-location location)))


;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE C: --runtime-checks.
;;;;   * when-thread-is (ideal_001 "when-thread-is / abs-when-thread-is", never built): global
;;;;     thread election, relative to the global offset.
;;;;   * r-t-assert: nothing without a flag; under --runtime-checks (unless test (die "strings")) --
;;;;     the compile-time strings reach the die report, runtime values are dropped.
;;;;   * r-t-assert-0: the same, guarded by (when-thread-is 0 ...) -- GLOBAL thread 0.
;;;;   * the codegen bounds checks (make-view, storage struct updates) lower through die too, so
;;;;     they halt on L0 (BUG 136) and report a site.  Under --runtime-checks every function gets
;;;;     the die flag: the checks are placed at codegen, after prototypes are fixed.
;;;; =====================================================================================

;; src/macros.lisp (endeavour 193) -- FOLD: beside when-thread-in-group-is, and export it from
;; :crisp.compiler / import it into :crisp-language like the other two (src/package.lisp).
(defmacro crisp-language::when-thread-is (&rest ids-and-body)
  "Runs BODY only in the thread whose global id (relative to the global offset) is the given one --
   a per-LAUNCH election.  (when-thread-is id body...) compares the linear global id;
   (when-thread-is x y body...) and (when-thread-is x y z body...) compare each dimension.
   The ids must be literal integers.  sync-workgroup in BODY is refused (divergent)."
  (let* ((n-ids (loop for x in ids-and-body while (integerp x) count t))
         (ids (subseq ids-and-body 0 n-ids))
         (body (nthcdr n-ids ids-and-body)))
    (unless (<= 1 n-ids 3)
      (error "when-thread-is takes 1 to 3 literal integer ids before its body, got ~s" ids-and-body))
    (if (= n-ids 1)
        `(when (= (get-global-linear-id) (to-ulong ,(first ids)))
           ,@body)
        `(when (and ,@(loop for id in ids
                            for d from 0
                            collect `(= (- (get-global-id ,d) (get-global-offset ,d)) (to-ulong ,id))))
           ,@body))))

;; src/macros.lisp (endeavour 193)
(defun %193-assert-message (args)
  "Endeavour 193.  The compile-time strings among an assert's ARGS, joined by spaces, or NIL."
  (let ((strings (remove-if-not #'stringp args)))
    (when strings (format nil "~{~a~^ ~}" strings))))

;; src/macros.lisp (endeavour 193) -- replaces r-t-assert.
(defmacro r-t-assert (test &rest args)
  "Asserts that TEST is true at runtime; if not, the thread dies (see die).  Compiled ONLY under
   --runtime-checks (or --logging-output); otherwise it disappears, test and all.  Its compile-time
   string arguments become the die site's message; runtime values need --logging-output."
  (if *runtime-checks-enabled*
      `(unless ,test (die ,@(let ((m (%193-assert-message args))) (when m (list m)))))
      nil))

;; src/macros.lisp (endeavour 193) -- replaces r-t-assert-0.
(defmacro r-t-assert-0 (test &rest args)
  "r-t-assert evaluated by GLOBAL thread 0 only (when-thread-is 0).  For conditions every thread
   sees the same way -- lengths, dispatch geometry.  Compiled only under --runtime-checks."
  (if *runtime-checks-enabled*
      `(crisp-language::when-thread-is 0 (r-t-assert ,test ,@args))
      nil))

;; src/compiler.lisp (endeavour 193)
(defvar *193-location-sites* (make-hash-table :test 'equal)
  "Endeavour 193.  Under --runtime-checks: analysis location -> (FILE . LINE) of the innermost
   enclosing source form, so a check placed at codegen can name its line.")

;; src/codegen.lisp (endeavour 193)
(defvar *193-check-site* nil
  "Endeavour 193.  While a node that may emit a bounds check is generated: (LOCATION . MESSAGE).")

;; src/compiler.lisp (endeavour 193) -- supersedes the copy above.
(defun %193-may-die-p (name)
  "Endeavour 193.  T when the function NAME may reach a die (see *may-die-functions*).  Under
   --runtime-checks every function may: bounds checks are placed at codegen, after prototypes."
  (and name (or *runtime-checks-enabled* (gethash name *may-die-functions*)) t))

;; src/compiler.lisp (endeavour 193) -- supersedes the copy above.
(defun initialize-compiler (&rest args)
  "Endeavour 193 wrapper: also resets the die tables (single-pass compiles have no Pass 1 to do it)."
  (prog1 (apply *193-orig-initialize-compiler* args)
    (clrhash *may-die-functions*)
    (clrhash *die-messages*)
    (clrhash *193-location-sites*)
    (setf *die-sites* nil)))

;; src/analysis/core.lisp (endeavour 193) -- supersedes the copy above.
(defun analyze-expression (expr env context location)
  "Recursively analyzes a *single* expression.
   Endeavour 193 wrapper: tracks the innermost form that came from a file (*193-enclosing-site*);
   under --runtime-checks also records it per location (*193-location-sites*)."
  (let ((*193-enclosing-site* (or (and (consp expr) (gethash expr *193-form-sites*))
                                  *193-enclosing-site*)))
    (when (and *runtime-checks-enabled* *193-enclosing-site* (consp expr))
      (setf (gethash location *193-location-sites*) *193-enclosing-site*))
    (funcall *193-orig-analyze-expression* expr env context location)))

;; src/codegen.lisp (endeavour 193)
(defun %193-call-passes-flag-p (callee-sym callee-name module param-count)
  "Endeavour 193.  Does this call pass the die flag?  The callee must be may-die and not foreign,
   and if it is already in the module its LLVM signature must have the extra parameter -- a
   function created some other way never gets a mismatched call."
  (and (%193-may-die-p callee-sym)
       (not (gethash callee-sym *foreign-functions*))
       (let ((f (llvm-get-named-function module callee-name)))
         (or (cffi:null-pointer-p f)
             (= (llvm-count-params f) (1+ param-count))))))
;; src/codegen.lisp (endeavour 193) -- FOLD: the may-die branches into %build-function-call.
;; Supersedes the copy above: whether to pass the flag is %193-call-passes-flag-p.
(defun %build-function-call (builder module var-env di-builder di-scope location-map node sig callee-name llvm-fn-type param-nodes param-count return-type-names)
  "Helper: Builds the actual function call instruction.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Required on SPV builds — see overlay
   header for the InstCombine UB bug this fix addresses.
   Endeavour 193: a call to a may-die function passes the die flag as a trailing argument, then
   loads it and returns from the caller if the callee died."
  (declare (ignore sig))
  (let* ((callee-sym (semantic-call-name node))
         (dies-p (%193-call-passes-flag-p callee-sym callee-name module param-count))
         (fn-type (if dies-p (%193-append-flag-param llvm-fn-type) llvm-fn-type))
         (arg-nodes (semantic-call-args node))
         (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                             arg-nodes param-nodes param-count))
         (caller-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (n-args (if dies-p (1+ param-count) param-count))
         (final-args (if dies-p
                         (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count n-args)))
                           (dotimes (i param-count)
                             (setf (cffi:mem-aref arr 'llvm-value-ref i) (cffi:mem-aref args-array 'llvm-value-ref i)))
                           (setf (cffi:mem-aref arr 'llvm-value-ref param-count) (%193-call-flag-arg callee-sym caller-fn))
                           arr)
                         args-array))
         (callee-fn (let ((f (llvm-get-named-function module callee-name)))
                      (if (cffi:null-pointer-p f)
                          (llvm-add-function module callee-name fn-type)
                          f)))
         (call-inst (llvm-build-call2 builder
                                      fn-type
                                      callee-fn
                                      final-args
                                      n-args
                                      (if (or (null return-type-names)
                                              (equal return-type-names '(nil))
                                              (and (consp return-type-names) (eq (first return-type-names) 'void)))
                                          ""
                                          "call_tmp")))
         (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
    (%propagate-callee-cc-to-call call-inst callee-fn)
    (when dies-p
      (log:debug "193: call to may-die ~a -- checking the die flag after it" callee-name)
      (let* ((flag (llvm-build-load2 builder (llvm-int32-type) *die-flag-ptr* "die_flag_val"))
             (dead (llvm-build-icmp builder +llvm-int-ne+ flag (llvm-const-int (llvm-int32-type) 0 0) "died"))
             (bail (llvm-append-basic-block caller-fn "die_bail"))
             (cont (llvm-append-basic-block caller-fn "die_cont")))
        (llvm-build-cond-br builder dead bail cont)
        (llvm-position-builder-at-end builder bail)
        (%193-build-bail-return builder)
        (llvm-position-builder-at-end builder cont)))
    (values call-inst di-location)))

;; src/codegen.lisp (endeavour 193) -- supersedes the copies above: INFO (message file line) may be
;; given directly, for a check placed at codegen.  Without NODE (a bounds check) nobody computes the
;; ids, so the winner's group/local words stay 0.
(defun %193-emit-die (builder module location &optional node var-env di-builder di-scope location-map info)
  "Endeavour 193.  The die lowering: claim the die record (CAS site id over 0, relaxed); the winner
   writes its linear group id and local id into words 1 and 2.  Then set this thread's die flag and
   return.  Code after it goes into a fresh block with no predecessors, as return-from-loop does.
   INFO, when given, is the site's (MESSAGE FILE LINE); otherwise analysis recorded it."
  (unless *die-flag-ptr*
    (error "Compiler bug (endeavour 193): die reached codegen in a function that was not marked may-die (location ~s)." location))
  (let* ((info (or info (gethash location *die-messages*)))
         ;; One id per source location: a two-target compile (spv + ptx) generates the module
         ;; twice, and a template body may be instantiated more than once.
         (existing (find location *die-sites* :key #'fifth :test #'equal))
         (site-id (if existing (first existing) (1+ (length *die-sites*))))
         (rec (%193-die-record-global module))
         (rec-ty (llvm-array-type (llvm-int32-type) 4))
         (i32 (llvm-int32-type))
         (fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
    (unless existing
      (push (list site-id (second info) (third info) (first info) location) *die-sites*))
    (log:info "193: die site ~d: ~a:~a ~s" site-id (second info) (third info) (first info))
    (let* ((pair (crisp.llvm-bindings::llvm-build-atomic-cmpxchg
                  builder rec (llvm-const-int i32 0 0) (llvm-const-int i32 site-id 0) 2 2 0))
           (won (llvm-build-extract-value builder pair 1 "die_won"))
           (fill (llvm-append-basic-block fn "die_fill"))
           (done (llvm-append-basic-block fn "die_done")))
      (llvm-build-cond-br builder won fill done)
      (llvm-position-builder-at-end builder fill)
      (when node
        (loop for arg in (semantic-call-args node)
              for word from 1
              do (let* ((v (generate-node-ir arg builder module var-env di-builder di-scope location-map))
                        (idx (cffi:foreign-alloc 'llvm-value-ref :count 2)))
                   (setf (cffi:mem-aref idx 'llvm-value-ref 0) (llvm-const-int i32 0 0)
                         (cffi:mem-aref idx 'llvm-value-ref 1) (llvm-const-int i32 word 0))
                   (llvm-build-store builder v
                                     (llvm-build-in-bounds-gep2 builder rec-ty rec idx 2 "die_word")))))
      (llvm-build-br builder done)
      (llvm-position-builder-at-end builder done))
    (llvm-build-store builder (llvm-const-int i32 1 0) *die-flag-ptr*)
    (%193-build-bail-return builder)
    (llvm-position-builder-at-end builder (llvm-append-basic-block fn "after_die"))
    (values nil nil)))

;; src/codegen.lisp (endeavour 193)
(defun %193-check-id-nodes (location)
  "Endeavour 193.  The die record's id expressions for a check placed at CODEGEN: analysed on the
   spot (the builtin analyzers need no environment), as if in a dispatch context."
  (let ((*in-dispatch-context* t))
    (loop for f in +193-die-id-forms+
          for i from 1
          collect (analyze-expression f nil (or *compiler-context* (make-compiler-context))
                                      (append location (list :check i))))))

;; src/codegen.lisp (endeavour 193) -- replaces %handle-die-intrinsic: the --runtime-checks bounds
;; checks (make-view, storage struct updates) lower through die, not llvm.trap (BUG 136).
(defun %handle-die-intrinsic (builder module)
  "Endeavour 193.  A failed codegen-placed runtime check: die at the check's site
   (*193-check-site*, bound by the node being generated).  Was llvm.trap -- a silent no-op on L0."
  (let* ((site (or *193-check-site* (cons '(:unknown-check) "runtime check failed")))
         (location (car site))
         (file-line (gethash location *193-location-sites*))
         (info (list (cdr site) (car file-line) (cdr file-line)))
         (node (make-semantic-call :name 'die :type '(nil)
                                   :args (%193-check-id-nodes location)
                                   :signature (first (gethash 'die *function-table*))
                                   :source-location location)))
    (log:info "193: runtime check site at ~s: ~a (~a)" location (cdr site) file-line)
    (%193-emit-die builder module (list :check location) node (make-hash-table) nil nil nil info)))

;; src/codegen.lisp (endeavour 193)
(defmethod generate-node-ir :around ((node semantic-make-view) builder module var-env di-builder di-scope location-map)
  "Endeavour 193: names the site of make-view's --runtime-checks bounds check."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (let ((*193-check-site* (cons (semantic-make-view-source-location node)
                                "bounds check: the view does not fit its source")))
    (call-next-method)))

;; src/codegen.lisp (endeavour 193)
(defmethod generate-node-ir :around ((node semantic-struct-member-update) builder module var-env di-builder di-scope location-map)
  "Endeavour 193: names the site of a storage handle update's --runtime-checks bounds check."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (let ((*193-check-site* (cons (semantic-struct-member-update-source-location node)
                                "bounds check: storage handle offset or length out of range")))
    (call-next-method)))

;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE D (part 1): the --logging-output switch.
;;;;   * --logging-output implies --runtime-checks; --differentiate ignores both (doc: Three Levels).
;;;;   * (is-logging?) / (is-runtime-checking?) -- plain functions, so if+ can eval them.
;;;;   * r-t-output / r-t-output-0 compile away without the flag.
;;;; =====================================================================================

;; src/compiler.lisp (endeavour 193)
(defvar *logging-output-enabled* nil
  "Endeavour 193.  T when compiling with --logging-output (r-t-output and assert messages go to the
   log).  Set by initialize-compiler; implies *runtime-checks-enabled*.")

;; src/main.lisp (endeavour 193)
(defvar *193-cli-logging* nil
  "Endeavour 193.  T while crisp.main::parse-cli-args handles a command line with --logging-output.")

;; src/compiler.lisp (endeavour 193)
(defun %193-plist-remove (plist key)
  "Endeavour 193.  PLIST without KEY and its value."
  (loop for (k v) on plist by #'cddr
        unless (eq k key) append (list k v)))

;; src/compiler.lisp (endeavour 193) -- supersedes the copies above.  FOLD: a :logging-output key on
;; initialize-compiler; --logging-output implies :runtime-checks; --differentiate clears both.
(defun initialize-compiler (&rest args)
  "Endeavour 193 wrapper: accepts :LOGGING-OUTPUT (also taken from the command line), which
   implies :RUNTIME-CHECKS.  Under :DIFFERENTIATE both are off -- the gradient kernels are compiled
   as if neither flag had been given.  Also resets the die tables."
  (let* ((differentiate (getf args :differentiate))
         (logging (and (or (getf args :logging-output) *193-cli-logging*) (not differentiate)))
         (args (%193-plist-remove args :logging-output))
         (args (cond (differentiate (list* :runtime-checks nil (%193-plist-remove args :runtime-checks)))
                     (logging (list* :runtime-checks t (%193-plist-remove args :runtime-checks)))
                     (t args))))
    (prog1 (apply *193-orig-initialize-compiler* args)
      (setf *logging-output-enabled* logging)
      (when logging (log:info "193: --logging-output (implies --runtime-checks)"))
      (clrhash *may-die-functions*)
      (clrhash *die-messages*)
      (clrhash *193-location-sites*)
      (setf *die-sites* nil))))

;; src/main.lisp (endeavour 193) -- FOLD: a logging-output-p binding beside runtime-checks-p in
;; parse-cli-args, passed as :logging-output.
(defvar *193-orig-parse-cli-args* (fdefinition 'crisp.main::parse-cli-args))
(defun crisp.main::parse-cli-args (args)
  "Endeavour 193 wrapper: --logging-output reaches initialize-compiler."
  (let ((*193-cli-logging* (and (member "--logging-output" args :test #'string=) t)))
    (funcall *193-orig-parse-cli-args* args)))

;; src/macros.lisp (endeavour 193) -- FOLD: export from :crisp.compiler, import into :crisp-language.
(defun crisp-language::is-logging? ()
  "True at compile time when compiling with --logging-output.  Use with if+ / when+."
  *logging-output-enabled*)

;; src/macros.lisp (endeavour 193) -- FOLD: export from :crisp.compiler, import into :crisp-language.
(defun crisp-language::is-runtime-checking? ()
  "True at compile time when compiling with --runtime-checks (and so also under --logging-output)."
  *runtime-checks-enabled*)

;; src/macros.lisp (endeavour 193) -- FOLD: export from :crisp.compiler, import into :crisp-language.
(defmacro crisp-language::r-t-output (&rest args)
  "Writes one message, made of ARGS (compile-time strings and scalar values), into the log.  Only
   under --logging-output; otherwise it disappears along with its arguments.  Engaged by EVERY
   thread -- choose who logs with a guard (when-thread-is, when-thread-in-group-is, ...)."
  (if *logging-output-enabled*
      `(%193-log-message ,@args)
      nil))

;; src/macros.lisp (endeavour 193) -- FOLD: export from :crisp.compiler, import into :crisp-language.
(defmacro crisp-language::r-t-output-0 (&rest args)
  "r-t-output from GLOBAL thread 0 only (when-thread-is 0): one message per launch."
  (if *logging-output-enabled*
      `(crisp-language::when-thread-is 0 (crisp-language::r-t-output ,@args))
      nil))

;; src/macros.lisp (endeavour 193) -- supersedes the two DEFUNs above: if+ ANALYSES its condition as
;; Crisp and constant-folds it, so the predicates must expand to a foldable comparison (as the
;; existing if+ specs write (> 10 5)), not be host functions.  FOLD: defmacros only.
(fmakunbound 'crisp-language::is-logging?)
(defmacro crisp-language::is-logging? ()
  "True at compile time when compiling with --logging-output.  Use with if+ / when+."
  (if *logging-output-enabled* '(> 1 0) '(< 1 0)))

(fmakunbound 'crisp-language::is-runtime-checking?)
(defmacro crisp-language::is-runtime-checking? ()
  "True at compile time when compiling with --runtime-checks (and so also under --logging-output)."
  (if *runtime-checks-enabled* '(> 1 0) '(< 1 0)))

;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE D (part 2): the log -- a module-scope global (option G, 2026-10-25).
;;;;   @__crisp_log : [4 + C x i32] addrspace(1), align 16, zero.  Words 0-1 = the 64-bit cursor
;;;;   (words claimed, counting past the end), 2-3 reserved, then C data words.
;;;;   A message = [SITE][GROUP][LOCAL][v1 lo][v1 hi]...: claimed with one atomicrmw add on the
;;;;   cursor; written only if it fits.  Strings and value types live in the site table:
;;;;   (:log-sites :record "__crisp_log" :capacity-words C :sites ((id "file" line pieces) ...)).
;;;; =====================================================================================

;; src/compiler.lisp (endeavour 193)
(defvar *logging-size-bytes* (* 4 1024 1024)
  "Endeavour 193.  --logging-size: the bytes reserved for @__crisp_log (header included).")

;; src/main.lisp (endeavour 193)
(defvar *193-cli-logging-size* nil
  "Endeavour 193.  The --logging-size= value of the command line being handled, or NIL.")

;; src/compiler.lisp (endeavour 193)
(defvar *log-sites* nil
  "Endeavour 193.  Per-module list of (site-id file line pieces location), newest first.  PIECES is
   the message in order: compile-time strings, and a type keyword (:int :uint :long :ulong :float
   :double) for each runtime value.")

;; src/compiler.lisp (endeavour 193)
(defvar *193-log-messages* (make-hash-table :test 'equal)
  "Endeavour 193.  Analysis location of a log message -> (PIECES FILE LINE).")

;; src/main.lisp (endeavour 193)
(defun %193-parse-size (text)
  "Endeavour 193.  \"4M\" / \"512K\" / \"1G\" / \"65536\" -> bytes."
  (let* ((s (string-trim " " text))
         (last (char-upcase (cl:char s (1- (length s)))))
         (mult (case last (#\K 1024) (#\M (* 1024 1024)) (#\G (* 1024 1024 1024)) (t 1)))
         (digits (if (= mult 1) s (subseq s 0 (1- (length s))))))
    (* mult (parse-integer digits))))

;; src/compiler.lisp (endeavour 193)
(defun %193-log-capacity-words ()
  "Endeavour 193.  Data words in the log: the size, less the 4-word header (at least 64)."
  (max 64 (- (cl:floor *logging-size-bytes* 4) 4)))

;; src/main.lisp (endeavour 193) -- supersedes the copy above: also --logging-size=.
(defun crisp.main::parse-cli-args (args)
  "Endeavour 193 wrapper: --logging-output and --logging-size= reach initialize-compiler."
  (let* ((*193-cli-logging* (and (member "--logging-output" args :test #'string=) t))
         (size-arg (find-if (lambda (a) (alexandria:starts-with-subseq "--logging-size=" a)) args))
         (*193-cli-logging-size* (when size-arg (%193-parse-size (subseq size-arg (length "--logging-size="))))))
    (funcall *193-orig-parse-cli-args* args)))

;; src/compiler.lisp (endeavour 193) -- supersedes the copies above: the log tables, the log size,
;; and the %193-log-message function-table entry (beside die's).
(defun initialize-compiler (&rest args)
  "Endeavour 193 wrapper: accepts :LOGGING-OUTPUT (also taken from the command line), which
   implies :RUNTIME-CHECKS, and :LOGGING-SIZE (bytes).  Under :DIFFERENTIATE both flags are off --
   the gradient kernels are compiled as if neither had been given.  Also resets the die and log tables."
  (let* ((differentiate (getf args :differentiate))
         (logging (and (or (getf args :logging-output) *193-cli-logging*) (not differentiate)))
         (size (or (getf args :logging-size) *193-cli-logging-size*))
         (args (%193-plist-remove (%193-plist-remove args :logging-output) :logging-size))
         (args (cond (differentiate (list* :runtime-checks nil (%193-plist-remove args :runtime-checks)))
                     (logging (list* :runtime-checks t (%193-plist-remove args :runtime-checks)))
                     (t args))))
    (prog1 (apply *193-orig-initialize-compiler* args)
      (setf *logging-output-enabled* logging
            *logging-size-bytes* (or size (* 4 1024 1024)))
      (when logging (log:info "193: --logging-output (implies --runtime-checks), log ~d bytes" *logging-size-bytes*))
      (setf (gethash '%193-log-message *function-table*)
            (list (make-function-signature :name '%193-log-message :parameters nil :return-types '(nil))))
      (clrhash *may-die-functions*)
      (clrhash *die-messages*)
      (clrhash *193-location-sites*)
      (clrhash *193-log-messages*)
      (setf *die-sites* nil
            *log-sites* nil))))

;; src/analysis/ops.lisp (endeavour 193)
(defun %193-log-kind (type)
  "Endeavour 193.  The log's decoding kind for a scalar Crisp TYPE, or NIL (not loggable)."
  (when (and type (symbolp type))
    (let ((n (symbol-name type)))
      (cond ((member n '("INT" "SHORT" "CHAR") :test #'string-equal) :int)
            ((member n '("UINT" "USHORT" "UCHAR" "BOOL" "BOOLEAN") :test #'string-equal) :uint)
            ((string-equal n "LONG") :long)
            ((string-equal n "ULONG") :ulong)
            ((string-equal n "FLOAT") :float)
            ((string-equal n "DOUBLE") :double)))))

;; src/analysis/ops.lisp (endeavour 193)
(defun analyze-log-message-expression (expr env context location)
  "Endeavour 193.  (%193-log-message arg ...) -- what r-t-output expands to under --logging-output.
   Compile-time strings stay in the site table; every other argument must be a scalar, and is
   carried as an argument node after the two id nodes (the writer's group and local ids)."
  (let ((pieces '()) (value-nodes '())
        (site (or (gethash expr *193-form-sites*) *193-enclosing-site*)))
    (loop for a in (rest expr)
          for i from 1
          do (if (stringp a)
                 (push a pieces)
                 (let* ((node (analyze-expression a env context (append location (list i))))
                        (type (get-single-value-type node))
                        (kind (%193-log-kind type)))
                   (unless kind
                     (error 'crisp-compiler-error
                       :message (format nil "r-t-output: ~s has type ~s.  Each argument must be a scalar or a compile-time string." a type)
                       :source-location location))
                   (push kind pieces)
                   (push node value-nodes))))
    (setf (gethash location *193-log-messages*) (list (nreverse pieces) (car site) (cdr site)))
    (log:debug "193: log message at ~s (~a): ~s" location site (gethash location *193-log-messages*))
    (make-semantic-call :name '%193-log-message
                        :type '(nil)
                        :args (append (let ((*in-dispatch-context* t))
                                        (loop for f in +193-die-id-forms+
                                              for i from 1
                                              collect (analyze-expression f env context (append location (list :id i)))))
                                      (nreverse value-nodes))
                        :signature (first (gethash '%193-log-message *function-table*))
                        :source-location location)))

;; src/analysis/ops.lisp (endeavour 193) -- supersedes the copy above: also the log message analyzer.
(defun register-ops-analyzers ()
  "Endeavour 193 wrapper: also registers the die and log-message analyzers."
  (funcall *193-orig-register-ops-analyzers*)
  (setf (gethash 'die *expression-analyzers*) #'analyze-die-expression)
  (setf (gethash '%193-log-message *expression-analyzers*) #'analyze-log-message-expression)
  (let ((lang-die (find-symbol "DIE" :crisp-language)))
    (when (and lang-die (not (eq lang-die 'die)))
      (setf (gethash lang-die *expression-analyzers*) #'analyze-die-expression))))

;; src/macros.lisp (endeavour 193) -- supersedes the copy above: under --logging-output a failed
;; assert first writes its message, runtime values included, into the log.
(defmacro r-t-assert (test &rest args)
  "Asserts that TEST is true at runtime; if not, the thread dies (see die).  Compiled ONLY under
   --runtime-checks (or --logging-output); otherwise it disappears, test and all.  Its compile-time
   string arguments become the die site's message; under --logging-output the whole message,
   runtime values included, is written to the log first."
  (if *runtime-checks-enabled*
      `(unless ,test
         ,@(when (and *logging-output-enabled* args) `((%193-log-message ,@args)))
         (die ,@(let ((m (%193-assert-message args))) (when m (list m)))))
      nil))

;; src/codegen.lisp (endeavour 193)
(defun %193-log-global (module)
  "Endeavour 193.  @__crisp_log: [4 + C x i32] in addrspace(1), align 16, zero-initialised, Export
   linkage (the host reads it by name).  Words 0-1 are the 64-bit cursor."
  (let ((g (llvm-get-named-global module "__crisp_log")))
    (if (and g (not (cffi:null-pointer-p g)))
        g
        (let* ((ty (llvm-array-type (llvm-int32-type) (+ 4 (%193-log-capacity-words))))
               (g (llvm-add-global-in-addrspace module ty "__crisp_log" 1)))
          (llvm-set-initializer g (llvm-const-null ty))
          (crisp.llvm-bindings::llvm-set-alignment g 16)
          (log:info "193: created @__crisp_log (~d data words)" (%193-log-capacity-words))
          g))))

;; src/codegen.lisp (endeavour 193)
(defun %193-log-slot (builder value kind)
  "Endeavour 193.  VALUE (of decoding KIND) as an i64 log slot: integers sign- or zero-extended,
   floats by their bits."
  (let* ((i64 (llvm-int64-type))
         (ty (llvm-type-of value))
         (int-p (= (llvm-get-type-kind ty) 8)))          ; LLVMIntegerTypeKind
    (ecase kind
      ((:int :uint :long :ulong)
       (unless int-p
         (error "Compiler bug (endeavour 193): a ~a log value is not an LLVM integer" kind))
       (if (= (crisp.llvm-bindings::llvm-get-int-type-width ty) 64)
           value
           (if (eq kind :int)
               (llvm-build-sext builder value i64 "log_sext")
               (llvm-build-zext builder value i64 "log_zext"))))
      (:float
       (llvm-build-zext builder
                        (crisp.llvm-bindings::llvm-build-bit-cast builder value (llvm-int32-type) "log_fbits")
                        i64 "log_fslot"))
      (:double
       (crisp.llvm-bindings::llvm-build-bit-cast builder value i64 "log_dbits")))))

;; src/codegen.lisp (endeavour 193)
(defun %193-emit-log-message (node builder module var-env di-builder di-scope location-map)
  "Endeavour 193.  Writes one log message: claim 3 + 2N words with an atomic add on the cursor
   (relaxed; the cursor keeps counting past the end), and write the packet only if it fits."
  (let* ((location (semantic-call-source-location node))
         (info (gethash location *193-log-messages*))
         (pieces (first info))
         (kinds (remove-if #'stringp pieces))
         (existing (find location *log-sites* :key #'fifth :test #'equal))
         (site-id (if existing (first existing) (1+ (length *log-sites*))))
         (cap (%193-log-capacity-words))
         (nwords (+ 3 (* 2 (length kinds))))
         (i32 (llvm-int32-type))
         (i64 (llvm-int64-type))
         (log-ty (llvm-array-type i32 (+ 4 cap)))
         (g (%193-log-global module))
         (fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
    (unless existing
      (push (list site-id (second info) (third info) pieces location) *log-sites*))
    (log:info "193: log site ~d: ~a:~a ~s" site-id (second info) (third info) pieces)
    ;; values first (in the current block), then claim, then write
    (let* ((args (semantic-call-args node))
           (gid (generate-node-ir (first args) builder module var-env di-builder di-scope location-map))
           (lid (generate-node-ir (second args) builder module var-env di-builder di-scope location-map))
           (slots (loop for arg in (cddr args)
                        for kind in kinds
                        collect (let ((v (generate-node-ir arg builder module var-env di-builder di-scope location-map)))
                                  (%193-log-slot builder (extract-primary-value builder v (semantic-node-type arg)) kind))))
           (off (crisp.llvm-bindings::llvm-build-atomic-rmw builder 1 g (llvm-const-int i64 nwords 0) 2 0)) ; add, monotonic
           (end (llvm-build-add builder off (llvm-const-int i64 nwords 0) "log_end"))
           (fits (llvm-build-icmp builder +llvm-int-ule+ end (llvm-const-int i64 cap 0) "log_fits"))
           (write (llvm-append-basic-block fn "log_write"))
           (done (llvm-append-basic-block fn "log_done")))
      (llvm-build-cond-br builder fits write done)
      (llvm-position-builder-at-end builder write)
      (let ((words (append (list (llvm-const-int i32 site-id 0) gid lid)
                           (loop for s in slots
                                 append (list (llvm-build-trunc builder s i32 "log_lo")
                                              (llvm-build-trunc builder
                                                                (crisp.llvm-bindings::llvm-build-l-shr builder s (llvm-const-int i64 32 0) "log_hi64")
                                                                i32 "log_hi"))))))
        (loop for w in words
              for k from 0
              do (let ((idx (cffi:foreign-alloc 'llvm-value-ref :count 2)))
                   (setf (cffi:mem-aref idx 'llvm-value-ref 0) (llvm-const-int i64 0 0)
                         (cffi:mem-aref idx 'llvm-value-ref 1)
                         (llvm-build-add builder off (llvm-const-int i64 (+ 4 k) 0) "log_idx"))
                   (llvm-build-store builder w (llvm-build-in-bounds-gep2 builder log-ty g idx 2 "log_word")))))
      (llvm-build-br builder done)
      (llvm-position-builder-at-end builder done))
    (values nil nil)))

;; src/codegen.lisp (endeavour 193) -- supersedes the method above: die AND the log message.
(defmethod generate-node-ir :around ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Endeavour 193: die lowers to %193-emit-die (not llvm.trap); a log message to %193-emit-log-message."
  (cond ((eq (semantic-call-name node) 'die)
         (%193-emit-die builder module (semantic-call-source-location node)
                        node var-env di-builder di-scope location-map))
        ((eq (semantic-call-name node) '%193-log-message)
         (%193-emit-log-message node builder module var-env di-builder di-scope location-map))
        (t (call-next-method))))

;; src/metadata.lisp (endeavour 193)
(defun %193-serialize-log-sites (stream)
  "Endeavour 193.  The (:log-sites ...) section: the log's global name, its data capacity in words,
   and every site, oldest first, as (ID \"FILE\" LINE PIECES).  Nothing when the module never logs."
  (when *log-sites*
    (format stream "(:log-sites :record \"__crisp_log\" :capacity-words ~d~%  :sites (" (%193-log-capacity-words))
    (dolist (s (reverse *log-sites*))
      (format stream "~%    (~d ~s ~s ~s)" (first s) (or (second s) "?") (or (third s) 0) (fourth s)))
    (format stream "))~%")))

;; src/metadata.lisp (endeavour 193) -- supersedes the copy above: also the log sites.
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Endeavour 193 wrapper: then the (:die-sites ...) and (:log-sites ...) sections."
  (prog1 (funcall *193-orig-serialize-kernels* output-stream kernel-names
                  :source source :output-targets output-targets)
    (%193-serialize-die-sites output-stream)
    (%193-serialize-log-sites output-stream)))

;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE E: a dead producer must not hang its consumers.
;;;; The only unbounded waits Crisp generates are the mbarrier try_wait spins of (await ...)
;;;; (semantic-nvvm-tma-wait, both paths); the CAS retry loops are bounded and last-man does not
;;;; spin.  H100 probe (FINDINGS.md): an mbarrier wait on a producer that died hangs; a die-record
;;;; check in the spin fixes it.  So, in a module that can die, every try_wait spin also loads the
;;;; record's site word (relaxed):
;;;;   * the waiting function may die  -> set its die flag and unwind, as if it had died itself;
;;;;   * otherwise                     -> leave the wait (results are undefined after a death).
;;;; =====================================================================================

;; src/llvm-bindings.lisp (endeavour 193) -- defined in crisp.compiler so no export is needed
(cffi:defcfun ("LLVMSetOrdering" llvm-set-ordering) :void
  (inst     :pointer)
  (ordering :int))
(cffi:defcfun ("LLVMGetGlobalParent" llvm-get-global-parent) :pointer
  (global :pointer))

;; src/codegen.lisp (endeavour 193)
(defun %193-module-can-die-p ()
  "Endeavour 193.  T when anything in the module may reach a die."
  (or *runtime-checks-enabled* (plusp (hash-table-count *may-die-functions*))))

;; src/codegen.lisp (endeavour 193)
(defun %193-load-die-site-relaxed (builder module)
  "Endeavour 193.  A relaxed atomic load of the die record's site word (non-zero once anyone died)."
  (let ((ld (llvm-build-load2 builder (llvm-int32-type) (%193-die-record-global module) "die_site_seen")))
    (llvm-set-ordering ld 2)                       ; monotonic
    (crisp.llvm-bindings::llvm-set-alignment ld 4)
    ld))

;; src/codegen.lisp (endeavour 193) -- FOLD: the die check inside the two try_wait spins of
;; generate-node-ir (semantic-nvvm-tma-wait), right after %gen-nvvm-mbarrier-try-wait-parity.
(defvar *193-orig-mbarrier-try-wait-parity* (fdefinition '%gen-nvvm-mbarrier-try-wait-parity))
(defun %gen-nvvm-mbarrier-try-wait-parity (builder mbar-addr-i32 phase-i32)
  "Inline PTX: try_wait.parity -> i32 (1 if the barrier's phase flipped, else 0).  Wrapped so
   the caller can spin in an LLVM loop (no label in the asm).
   Endeavour 193 wrapper: in a module that can die, each spin also checks the die record.  A
   may-die waiter unwinds (flag + return); any other waiter leaves the wait (returns 1)."
  (let ((complete (funcall *193-orig-mbarrier-try-wait-parity* builder mbar-addr-i32 phase-i32)))
    (if (not (%193-module-can-die-p))
        complete
        (let* ((fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
               (module (llvm-get-global-parent fn))
               (i32 (llvm-int32-type))
               (site (%193-load-die-site-relaxed builder module))
               (dead (llvm-build-icmp builder +llvm-int-ne+ site (llvm-const-int i32 0 0) "someone_died")))
          (log:info "193: die check in an mbarrier wait (~a)" (if *die-flag-ptr* "unwind" "leave the wait"))
          (if *die-flag-ptr*
              (let ((bail (llvm-append-basic-block fn "wait_die_bail"))
                    (cont (llvm-append-basic-block fn "wait_die_cont")))
                (llvm-build-cond-br builder dead bail cont)
                (llvm-position-builder-at-end builder bail)
                (llvm-build-store builder (llvm-const-int i32 1 0) *die-flag-ptr*)
                (%193-build-bail-return builder)
                (llvm-position-builder-at-end builder cont)
                complete)
              (crisp.llvm-bindings::llvm-build-or builder complete (llvm-build-zext builder dead i32 "died_i32") "done_or_died"))))))
