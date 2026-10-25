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
