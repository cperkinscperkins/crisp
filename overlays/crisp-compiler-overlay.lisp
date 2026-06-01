;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; ROOT CAUSE of the SPV -O3 destruction bug (resolved 2026-05-31)
;; ======================================================================
;;
;; Symptom: any Crisp-emitted SPV kernel that called an accessor function
;; (e.g. `length__tensor_int_1_global_compact_last`) was collapsed by
;; opt -O3 to `entry: unreachable`, triggering `ZE_RESULT_ERROR_DEVICE_LOST`
;; at launch.  Loop-vector-stride, tile-stride, and the sum-reduction
;; benchmark all tripped it.
;;
;; Real root cause: Crisp marks accessor (non-kernel) functions
;; `spir_func` via `mark-function-as-kernel` (LLVM CC=75), but every
;; `llvm-build-call2` call instruction is built with the default C
;; calling convention (CC=0).  Modern LLVM (opt-21) treats a caller/
;; callee CC mismatch as immediate UB.  InstCombine inserts
;;   `store i1 true, ptr poison`
;; at the entry of any function containing such a call and turns every
;; downstream branch condition into `i1 poison`; subsequent passes prune
;; the unreachable body and the kernel becomes `entry: unreachable`.
;;
;; Earlier theories (SROA poison from aggregate allocas, the
;; insertvalue-from-undef chain in accessor functions, etc.) all turned
;; out to be downstream noise: the destruction happens with just
;; InstCombine on raw IR, no SROA needed, and reproduces on a hand-written
;; minimal repro with no aggregates at all (see put_temp_files_here/
;; test-bisect-min2.sh, T6).
;;
;; Fix: after every `llvm-build-call2`, copy the callee's CC onto the
;; call instruction.  This matches Clang's behaviour and is what
;; `LLVMBuildCall2` arguably should do automatically.  With the fix,
;; opt -O3 produces fully optimized SPV kernels — no destruction.
;;
;; Unaffected:
;;   - PTX path: opt loads the NVPTX target and runs with a proper data
;;     layout; the UB heuristic that fires on the data-layout-less SPV
;;     path doesn't trigger.  But the call-conv fix is still applied
;;     uniformly and is harmless on PTX (PTX kernels use ptx_kernel CC
;;     and non-kernel functions use the default CC, so the propagation
;;     is a no-op).
;;   - Intrinsic calls (llvm.trap, llvm.sin, etc.): these are declared
;;     with the default CC, so propagating their CC to the call site
;;     leaves it at 0.

(defparameter +spv-opt-pipeline+
  "default<O3>"
  "Full -O3 pipeline for SPV builds.  Safe now that the call-site CC
   mismatch (see overlay header) is fixed in `%build-function-call` and
   `generate-node-ir semantic-funcall` below.")

(defun %run-opt-pipeline (input-ll-file output-ll-file passes-string)
  "Run opt -passes=<passes-string> -S input -o output.
   Returns T on success, NIL if opt isn't available or the run failed."
  (let ((opt-tool (%opt-available-p)))
    (cond
      ((null opt-tool)
       (log:info "opt not available, skipping IR optimization pass")
       nil)
      (t
       (handler-case
           (progn
             (run-tool-command
              (list opt-tool
                    (format nil "-passes=~a" passes-string)
                    "-S"
                    (namestring input-ll-file)
                    "-o" (namestring output-ll-file))
              :log-prefix "[opt SPV] ")
             (log:info "opt produced ~a" output-ll-file)
             t)
         (error (e)
           (log:warn "opt failed (~a), using unoptimized IR" e)
           nil))))))

(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as ->
   llvm-spirv."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (bc-file     (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    ;; Bug 028 Part 2: remove dead array-returning functions before SPIR-V
    ;; so IGC never sees a TypeArray return type, even in dead code.
    (%remove-dead-array-returning-functions module)

    ;; Set target triple for SPIR-V before writing IR
    (llvm-set-target module "spir64-unknown-unknown")

    ;; 1. Write raw .ll with SPIR-V kernel metadata injected
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    ;; 2. opt -O3.  If opt isn't available, fall back to the raw IR.
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))

      ;; 3. llvm-as (LL -> BC)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))

    ;; 4. llvm-spirv (BC -> SPV).
    ;; Always request SPV_EXT_shader_atomic_float_add — forward kernels
    ;; can emit `atomicrmw fadd` too (e.g. the sum-reduction phase-3
    ;; atomic into a float result cell), not just backward _grad kernels.
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags '("--spirv-ext=+SPV_EXT_shader_atomic_float_add"))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;; ======================================================================
;; src/codegen.lisp — call-site calling-convention propagation
;; ======================================================================

(defun %propagate-callee-cc-to-call (call-inst callee-fn-val)
  "If CALLEE-FN-VAL is a function value, copy its calling convention to
   CALL-INST.  Safe to call even when callee is an arbitrary SSA value
   (e.g. a function pointer through generate-node-ir) — we only set CC
   when we have a concrete LLVM value in hand."
  (when (and call-inst callee-fn-val
             (not (cffi:null-pointer-p call-inst))
             (not (cffi:null-pointer-p callee-fn-val)))
    (let ((cc (crisp.llvm-bindings::llvm-get-function-call-conv callee-fn-val)))
      (crisp.llvm-bindings::llvm-set-instruction-call-conv call-inst cc))))

;; src/codegen.lisp
(defun %build-function-call (builder module var-env di-builder di-scope location-map node sig callee-name llvm-fn-type param-nodes param-count return-type-names)
  "Helper: Builds the actual function call instruction.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Required on SPV builds — see overlay
   header for the InstCombine UB bug this fix addresses."
  (declare (ignore sig))
  (let* ((arg-nodes (semantic-call-args node))
         (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                             arg-nodes param-nodes param-count))
         (callee-fn (let ((f (llvm-get-named-function module callee-name)))
                      (if (cffi:null-pointer-p f)
                          (llvm-add-function module callee-name llvm-fn-type)
                          f)))
         (call-inst (llvm-build-call2 builder
                                      llvm-fn-type
                                      callee-fn
                                      args-array
                                      param-count
                                      (if (or (null return-type-names)
                                              (equal return-type-names '(nil))
                                              (and (consp return-type-names) (eq (first return-type-names) 'void)))
                                          ""
                                          "call_tmp")))
         (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
    (%propagate-callee-cc-to-call call-inst callee-fn)
    (values call-inst di-location)))

;; src/codegen.lisp — also patch the semantic-funcall (function-pointer/literal) path
(defmethod generate-node-ir ((node semantic-funcall) builder module var-env di-builder di-scope location-map)
  "Generates IR for a funcall — function-pointer/function-literal style.

   Overlay change: propagate the callee's calling convention onto the
   resulting call instruction.  Same rationale as %build-function-call."
  (let* ((func-node (semantic-funcall-func-node node))
         (func-type-spec (semantic-node-type func-node))
         (return-type-names (semantic-funcall-type node))
         (has-return-value (not (null (remove 'nil return-type-names))))
         (param-types (cond
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-type))
                        (getf (cddr func-type-spec) :params))
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-literal))
                        (mapcar #'semantic-node-type (semantic-funcall-args node)))
                       (t (error "Codegen error: Invalid function type for funcall: ~a" func-type-spec)))))
    (multiple-value-bind (llvm-fn-type param-count)
        (%build-llvm-function-type module return-type-names param-types)
      (let* ((callee (generate-node-ir func-node builder module var-env di-builder di-scope location-map))
             (arg-nodes (semantic-funcall-args node))
             (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                                 arg-nodes param-types param-count)))
        (let* ((call-inst (llvm-build-call2 builder
                                            llvm-fn-type
                                            callee
                                            args-array
                                            param-count
                                            (if has-return-value "funcall_tmp" "")))
               (di-location (%attach-debug-loc call-inst node module di-builder di-scope location-map)))
          (%propagate-callee-cc-to-call call-inst callee)
          (values call-inst di-location))))))
