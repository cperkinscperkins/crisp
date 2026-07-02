;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/compiler.lisp
(in-package :crisp.compiler)

;; Initialization
;; ==============


(defvar *grid-functions* (make-hash-table :test #'eq)
  "Maps grid function name → T.
   Used to enforce that grid functions can only be called from
   dispatch contexts (def-kernel or def-grid-function bodies).")

(defun run-tool-command (args &key (log-prefix ""))
  "Runs a command using uiop:run-program."
  (log:info "~aRunning: ~{~a~^ ~}" log-prefix args)
  (let ((output (make-string-output-stream))
        (error-output (make-string-output-stream)))
    (handler-case
        (uiop:run-program args :output output :error-output error-output :force-shell t)
      (error (e)
        (let ((out-str (get-output-stream-string output))
              (err-str (get-output-stream-string error-output)))
          (log:error "Command failed: ~a" e)
          (unless (uiop:emptyp out-str) (log:error "Stdout: ~a" out-str))
          (unless (uiop:emptyp err-str) (log:error "Stderr: ~a" err-str))
          (error "Tool invocation failed: ~{~a~^ ~} (Reason: ~a)" args e))))
    (get-output-stream-string output)))

(defun resolve-tool-executable (tool-base)
  "Resolves the path to a tool executable. 
   Prefers bundled version in bin/, falls back to system PATH.
   Robustness: 
   - Checks versioned suffixes (e.g. llc-21) if base name not in path.
   - Falls back to bundled tool if system tool is missing even if CRISP_USE_SYSTEM_TOOLS is set."
  (let* ((env-key (format nil "CRISP_~a" (string-upcase (substitute #\_ #\- tool-base))))
         (env-override (uiop:getenv env-key))
         (use-system (uiop:getenv "CRISP_USE_SYSTEM_TOOLS"))
         (ext (if (uiop:os-windows-p) ".exe" ""))
         (bundled-name (format nil "bin/~a~a" tool-base ext))
         (bundled-path (merge-pathnames bundled-name *default-pathname-defaults*)))
    (cond
     (env-override env-override)
     ((and use-system (string-not-equal use-system "false"))
       (let ((versioned (unless (uiop:os-windows-p)
                          (loop for ver in '("-21" "-20" "-19" "-18" "-17" "-16" "-15" "-14" "")
                                for v-name = (format nil "~a~a" tool-base ver)
                                  ;; Manual PATH check or similar? Let's use which but ONLY on Unix.
                                  when (zerop (nth-value 2 (uiop:run-program (list "which" v-name) :ignore-error-status t)))
                                  return v-name))))
         (or versioned
             (if (probe-file bundled-path)
                 (namestring bundled-path)
                 tool-base))))
     (t
       (if (probe-file bundled-path)
           (namestring bundled-path)
           tool-base)))))

(defun %extract-spir-kernel-info (ir-text kernel-pos)
  "Extracts (values func-name define-pos brace-pos) for a kernel-pos in LLVM IR text."
  (let* ((define-pos (search "define" ir-text :start2 (max 0 (- kernel-pos 100)) :end2 kernel-pos :from-end t))
         (at-pos (position #\@ ir-text :start (or define-pos kernel-pos)))
         (paren-pos (position #\( ir-text :start at-pos))
         (func-name (subseq ir-text (1+ at-pos) paren-pos))
         (brace-pos (position #\{ ir-text :start paren-pos)))
    (values func-name define-pos brace-pos)))

(defun find-spir-kernels (ir-text)
  "Find all SPIR kernel functions in LLVM IR text.
   Returns list of (function-name start-pos end-pos-of-signature)."
  (let ((kernels '())
        (pos 0))
    (loop
     (let ((kernel-pos (search "spir_kernel" ir-text :start2 pos)))
       (unless kernel-pos
         (cl:return kernels))

       (multiple-value-bind (func-name define-pos brace-pos)
           (%extract-spir-kernel-info ir-text kernel-pos)
         (when (and func-name brace-pos)
               (push (list func-name define-pos brace-pos) kernels)))

       (setf pos (1+ kernel-pos))))))




(defun extract-kernel-params (ir-text func-start func-end)
  "Extract parameter types from a kernel function signature.
Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64', '%POINT')."
  (let* ((sig-text (subseq ir-text func-start func-end))
         (paren-start (position #\( sig-text))
         (paren-end (position #\) sig-text :from-end t)))

    (unless (and paren-start paren-end (< paren-start paren-end))
      (log:warn "Could not find parameter parens!")
      (return-from extract-kernel-params nil))

    (let* ((params-text (subseq sig-text (1+ paren-start) paren-end))
           (params '()))

      (log:info "extract-kernel-params: params-text = ~s" params-text)

      (dolist (param-str (uiop:split-string params-text :separator ","))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) param-str)))
          (when (> (length trimmed) 0)
                (let ((percent-pos (position #\% trimmed)))
                  (if percent-pos
                      (if (zerop percent-pos)
                          ;; Struct type: starts with %, e.g. "%POINT %0".
                          ;; Use the LAST % as the name boundary.
                          (let* ((last-percent (position #\% trimmed :from-end t))
                                 (type-text (string-trim '(#\Space #\Tab)
                                                         (subseq trimmed 0 last-percent))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted struct type: ~s" type-text)
                                  (push type-text params)))
                          ;; Normal case: type precedes the first %.
                          (let ((type-text (string-trim '(#\Space #\Tab)
                                                        (subseq trimmed 0 percent-pos))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted type: ~s" type-text)
                                  (push type-text params))))
                      (progn
                       (log:info "  extracted type (no name): ~s" trimmed)
                       (push trimmed params)))))))

      (nreverse params))))

(defun ir-type-to-opencl-metadata (ir-type)
  "Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).
Returns (values addr-space-int access-qual-string type-name-string)."
  (let ((addr-space 0)
        (access-qual "none")
        (type-name "void*"))

    (cond
     ;; Struct types: start with % (e.g. \"%POINT\")
     ;; Passed by value, addr-space 0, type-name is the struct name without %
     ((and (> (length ir-type) 0) (char= (cl:char ir-type 0) #\%))
       (setf addr-space 0
             type-name (subseq ir-type 1)))

     ;; Pointer types: ptr addrspace(N)
     ((search "ptr" ir-type)
       (cond
        ((search "addrspace(1)" ir-type)
          (setf addr-space 1 type-name "int*"))
        ((search "addrspace(2)" ir-type)
          (setf addr-space 2 type-name "int*"))
        ((search "addrspace(3)" ir-type)
          (setf addr-space 3 type-name "int*"))
        (t
          (setf addr-space 0 type-name "int*"))))

     ;; Integer types
     ((search "i64" ir-type)
       (setf addr-space 0 type-name "ulong"))
     ((search "i32" ir-type)
       (setf addr-space 0 type-name "uint"))
     ((search "i8" ir-type)
       (setf addr-space 0 type-name "uchar"))

     ;; Floating point
     ((search "float" ir-type)
       (setf addr-space 0 type-name "float"))
     ((search "double" ir-type)
       (setf addr-space 0 type-name "double")))

    (values addr-space access-qual type-name)))

(defun generate-kernel-metadata (params metadata-id-base)
  "Generate LLVM metadata definitions for kernel parameters.
 Returns (values metadata-refs-string metadata-defs-string next-id)."
  (let ((addr-spaces '())
        (access-quals '())
        (type-names '())
        (base-types '())
        (type-quals '()))

    ;; Extract metadata for each parameter
    (dolist (param params)
      (multiple-value-bind (addr-space access-qual type-name)
          (ir-type-to-opencl-metadata param)
        (push addr-space addr-spaces)
        (push access-qual access-quals)
        (push type-name type-names)
        (push type-name base-types) ; base-type same as type-name
        (push "" type-quals))) ; empty type qualifiers

    ;; Reverse to maintain parameter order
    (setf addr-spaces (nreverse addr-spaces))
    (setf access-quals (nreverse access-quals))
    (setf type-names (nreverse type-names))
    (setf base-types (nreverse base-types))
    (setf type-quals (nreverse type-quals))

    ;; Generate metadata IDs
    (let* ((id-addr (+ metadata-id-base 0))
           (id-access (+ metadata-id-base 1))
           (id-type (+ metadata-id-base 2))
           (id-base (+ metadata-id-base 3))
           (id-qual (+ metadata-id-base 4))
           (next-id (+ metadata-id-base 5)))

      ;; Build metadata reference string
      (let ((metadata-refs
             (format nil " !kernel_arg_addr_space !~a !kernel_arg_access_qual !~a !kernel_arg_type !~a !kernel_arg_base_type !~a !kernel_arg_type_qual !~a"
               id-addr id-access id-type id-base id-qual)))

        ;; Build metadata definitions string
        (let ((metadata-defs
               (format nil "!~a = !{~{i32 ~a~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%"
                 id-addr addr-spaces
                 id-access access-quals
                 id-type type-names
                 id-base base-types
                 id-qual type-quals)))

          (values metadata-refs metadata-defs next-id))))))




(defun inject-spir-kernel-metadata (ir-text)
  "Inject OpenCL kernel metadata for all SPIR kernels found in IR text.
Returns modified IR text with metadata."
  (let ((kernels (find-spir-kernels ir-text)))
    (if (null kernels)
        ir-text
        (let ((result ir-text)
              (metadata-id-base 100)
              (all-metadata-defs ""))

          (dolist (kernel-info kernels)
            (destructuring-bind (func-name func-start brace-pos) kernel-info
              (log:info "Injecting metadata for kernel: ~a" func-name)

              (let ((params (extract-kernel-params result func-start brace-pos)))
                (log:info "  Parameters: ~a" params)

                (multiple-value-bind (metadata-refs metadata-defs next-id)
                    (generate-kernel-metadata params metadata-id-base)

                  (let* (;; Search for @funcname( to find the definition, not occurrences
                         ;; of func-name inside struct type names like S_file_funcname_TYPE
                         (at-name-str (format nil "@~a(" func-name))
                         (kernel-sig-start (search at-name-str result))
                         (new-brace-pos (when kernel-sig-start
                                          (position #\{ result :start kernel-sig-start)))
                         ;; Search for ) only AFTER kernel-sig-start to stay within the signature
                         (close-paren-pos (when (and kernel-sig-start new-brace-pos)
                                            (position #\) result
                                                      :start kernel-sig-start
                                                      :end new-brace-pos
                                                      :from-end t))))

                    (log:info "  at-name-str=~s kernel-sig-start=~a new-brace-pos=~a close-paren-pos=~a"
                              at-name-str kernel-sig-start new-brace-pos close-paren-pos)

                    (if (null close-paren-pos)
                        (log:warn "inject-spir-kernel-metadata: could not find ) for ~a, skipping" func-name)
                        (progn
                          (setf result (concatenate 'string
                                         (subseq result 0 (1+ close-paren-pos))
                                         metadata-refs
                                         " "
                                         (string #\{)
                                         (subseq result (1+ new-brace-pos))))
                          (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                          (setf metadata-id-base next-id))))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))



;; ======================================================================
;; opt -O3 pass between LLVM IR generation and target codegen
;; ======================================================================
;;
;; Crisp's existing pipeline went straight from emitted LLVM IR to llc /
;; llvm-spirv.  llc has its own -O2 default but it only does target-
;; codegen optimizations (regalloc, instruction selection, peephole) —
;; NOT whole-module IR optimizations like mem2reg, loop-unroll, DCE, etc.
;;
;; nvcc internally runs `opt -O3` (or equivalent) BEFORE llc.  Without
;; that step we leave significant performance on the table: dead allocas
;; survive, constant-trip-count loops don't unroll, runtime bounds checks
;; don't get eliminated.  Measured impact on the reduction benchmark:
;; ~13% kernel time improvement, with Phase 2 (tree-reduce) becoming
;; fully unrolled instead of a tight loop.
;;
;; Graceful fallback: if `opt` is not on the system, the pipeline runs
;; unchanged (just llc / llvm-spirv).  Local Windows builds without opt
;; in the toolchain still work; on Linux/CI/RunPod with `opt-21` on PATH
;; (via CRISP_USE_SYSTEM_TOOLS) the optimization runs automatically.

(defun %opt-available-p ()
  "Returns the resolved opt tool path if findable, NIL otherwise.
   We probe rather than assume, so machines without opt installed still
   produce PTX / SPV (just unoptimized)."
  (let ((tool (resolve-tool-executable "opt")))
    ;; If resolve returns a bundled path, it's definitively present.
    ;; If it returns a bare name (versioned or not), probe with --version.
    (cond
      ((probe-file tool) tool)
      (t
       (handler-case
           (multiple-value-bind (out err code)
               (uiop:run-program (list tool "--version")
                                 :output nil :error-output nil
                                 :ignore-error-status t)
             (declare (ignore out err))
             (when (zerop code) tool))
         (error () nil))))))

(defun %run-opt-O3 (input-ll-file output-ll-file)
  "Run opt -O3 -S input-ll-file -o output-ll-file.
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
                    "-O3"
                    "-S"
                    (namestring input-ll-file)
                    "-o" (namestring output-ll-file))
              :log-prefix "[opt -O3] ")
             (log:info "opt -O3 produced ~a" output-ll-file)
             t)
         (error (e)
           (log:warn "opt -O3 failed (~a), using unoptimized IR" e)
           nil))))))




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

;;;; ============================================================
;;;; Bug 028 Part 2 — diagnostic redef: verbose logging to confirm
;;;; %remove-dead-array-returning-functions is called and what it sees.
;;;; Remove once confirmed working.
;;;; ============================================================

;; src/compiler.lisp
(defun %remove-dead-array-returning-functions (module)
  "Scans MODULE for functions whose return type is an LLVM array type
   ([N x T]) and that have no uses (no callers in this module).
   Deletes each such function.

   This is Part 2 of the IGC bug 028 workaround.
   Returns the number of functions deleted."
  (log:info "028-cleanup: starting scan of module for dead array-returning functions")
  (let ((to-delete '())
        (fn-count 0)
        (fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop while (and fn (not (cffi:null-pointer-p fn))) do
      (incf fn-count)
      (let* ((fn-name  (crisp.llvm-bindings::llvm-get-value-name fn))
             (fn-type  (crisp.llvm-bindings::llvm-global-get-value-type fn))
             (ret-type (crisp.llvm-bindings::llvm-get-return-type fn-type))
             (is-arr   (crisp.llvm-bindings::llvm-type-kind-is-array? ret-type))
             (no-uses  (cffi:null-pointer-p (crisp.llvm-bindings::llvm-get-first-use fn))))
        (log:info "028-cleanup: fn=~a is-array-ret=~a no-uses=~a" fn-name is-arr no-uses)
        (when (and is-arr no-uses)
          (log:info "028-cleanup: queuing dead array-returning fn ~a for deletion" fn-name)
          (push fn to-delete)))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    (log:info "028-cleanup: scanned ~a function(s), queued ~a for deletion" fn-count (length to-delete))
    (dolist (fn to-delete)
      (crisp.llvm-bindings::llvm-delete-function fn))
    (let ((n (length to-delete)))
      (when (> n 0)
        (log:info "028-cleanup: deleted ~a dead array-returning function(s)" n))
      n)))



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

    ;; 1. Write raw LLVM IR to .ll file
    (let ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module))))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir stream)))

    ;; 2. Try opt -O3 on the IR.  If it succeeds, feed the optimized IR
    ;;    to llc; otherwise fall back to the raw IR.
    (let* ((opt-ok  (%run-opt-O3 ll-file ll-opt-file))
           (llc-input (if opt-ok ll-opt-file ll-file)))

      ;; 3. llc: IR -> PTX
      (let ((tool (resolve-tool-executable "llc")))
        (run-tool-command
         (list tool
               "-march=nvptx64"
               (format nil "-mcpu=~a" compute-capability)
               (namestring llc-input)
               "-o" (namestring ptx-file))
         :log-prefix "[PTX] ")))

    ;; Cleanup temp files
    (when (probe-file ll-file)     (delete-file ll-file))
    (when (probe-file ll-opt-file) (delete-file ll-opt-file))

    (log:info "Generated PTX: ~a" ptx-file)))


(defun register-builtins ()
  "Registers built-in storage handle templates (storage, cell, tensor) and
   their system-generated accessor functions.  Called by initialize-compiler."
  (log:info "Registering built-in structs...")

  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  (when (boundp '*brand-cache-last-function*) (setf *brand-cache-last-function* nil))

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
           (def-record storage
             (address (c-pointer :address-space Addr))
             (byte-size ulong)
             (address-space address-space :c-t Addr))))

  ;; CELL: opaque handle to a storage slice.
  (eval '(with-template-type ((To T) (Addr address-space :global))
           (def-record cell
             (parent (storage Addr))
             (offset ulong)
             (element-type type-spec :c-t To)
             (address-space address-space :c-t Addr))))

  ;; ARRIVAL-SYNC-HANDLE: opaque handle to a sync point.
  (eval '(def-struct crisp-language:arrival-sync-handle
           (crisp-language::counter (cell int :address-space :global))
           (crisp-language::count int)))

  ;; bytes~ helper for cell.
  (register-template 'bytes~ '(To (Addr address-space :global)) nil
    '(def-function bytes~ (c)
       (declare (function ((cell To Addr) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((cell To Addr) => ulong))

  ;; TENSOR: N-dimensional strided view over a storage handle.
  (eval '(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                               (Aln align :compact) (Ct contiguity :last))
           (def-record tensor
             (parent  (storage Addr))
             (offset (array ulong N))
             (strides (array ulong N))
             (extents (array ulong N))
             (length  ulong)
             (element-type      type-spec   :c-t To)
             (num-dims          ulong       :c-t N)
             (address-space     address-space :c-t Addr)
             (align             align       :c-t Aln)
             (contiguous-term   contiguity  :c-t Ct))))

  ;; bytes~ helper for tensor.
  (register-template 'bytes~
    '(To (N integer 1) (Addr address-space :global)
      (Aln align :compact) (Ct contiguity :last)) nil
    '(def-function bytes~ (t1)
       (declare (function ((tensor To N Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((tensor To N Addr Aln Ct) => ulong))

  ;; Endeavor 122 (FFI) Pass 3: base-ptr~ — returns a storage handle's underlying
  ;; pointer in its NATIVE address space (a (c-pointer :address-space Addr)).
  ;; Pass-through like bytes~: works on a cell/tensor (via parent~) or on a
  ;; storage directly. Used to pass a buffer's base pointer to a foreign function.
  (register-template 'base-ptr~ '(To (Addr address-space :global)) nil
    '(def-function base-ptr~ (c)
       (declare (function ((cell To Addr) => (c-pointer :address-space Addr))))
       (declare (crisp-system-generated))
       (return (address~ (parent~ c))))
    '((cell To Addr) => (c-pointer :address-space Addr)))

  (register-template 'base-ptr~
    '(To (N integer 1) (Addr address-space :global)
      (Aln align :compact) (Ct contiguity :last)) nil
    '(def-function base-ptr~ (t1)
       (declare (function ((tensor To N Addr Aln Ct) => (c-pointer :address-space Addr))))
       (declare (crisp-system-generated))
       (return (address~ (parent~ t1))))
    '((tensor To N Addr Aln Ct) => (c-pointer :address-space Addr)))

  (register-template 'base-ptr~ '((Addr address-space :global)) nil
    '(def-function base-ptr~ (s)
       (declare (function ((storage Addr) => (c-pointer :address-space Addr))))
       (declare (crisp-system-generated))
       (return (address~ s)))
    '((storage Addr) => (c-pointer :address-space Addr)))

  ;; num-rows — return extents[0] (height dimension) of a 2D tensor.
  (register-template 'num-rows
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-rows (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 0)))
    '((tensor To 2 Addr Aln Ct) => ulong))

  ;; num-cols — return extents[1] (width dimension) of a 2D tensor.
  (register-template 'num-cols
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function num-cols (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => ulong)))
       (declare (crisp-system-generated))
       (return (~ (extents~ m) 1)))
    '((tensor To 2 Addr Aln Ct) => ulong))

  ;; get-layout — classify 2D tensor layout at runtime via stride inspection.
  (register-template 'get-layout
    '(To (Addr address-space :global) (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function get-layout (m)
       (declare (function ((tensor To 2 Addr Aln Ct) => int)))
       (declare (crisp-system-generated))
       (if (= (~ (strides~ m) 1) 1ul)
           0
           (if (= (~ (strides~ m) 0) 1ul)
               1
               2)))
    '((tensor To 2 Addr Aln Ct) => int))

  ;; contiguous-term~ — returns compile-time contiguity value for any tensor.
  (register-template 'contiguous-term~
    '(To (N integer 1) (Addr address-space :global)
      (Aln align :compact) (Ct contiguity :last))
    nil
    '(def-function contiguous-term~ (t1)
       (declare (function ((tensor To N Addr Aln Ct) => contiguity)))
       (declare (crisp-system-generated))
       (return Ct))
    '((tensor To N Addr Aln Ct) => contiguity))

  (log:info "Built-in structs registered."))


(defvar *differentiable-hof-store* (make-hash-table :test 'eq)
  "Maps HOF function name to info plist for inline backward differentiation.")


(defvar *implicit-scratch-size-expr-map* (make-hash-table)
  "Maps implicit scratch tensor param-name → size-expr form as written by the user
   (e.g. :match-warp-tile, 1, 4).  Used by generate-implicit-signature for metadata.")



(defvar *kernel-dispatch-declarations* (make-hash-table :test #'eq)
  "Maps kernel name symbol → plist of dispatch declarations extracted from def-kernel.
   Keys: :global-size, :local-size, :num-groups. Values: the raw s-expression forms
   e.g. :global-size = (global-size :derive-from (width height) :strategy :one-thread-per).")
  

(defun register-foreign-function (c-name signature &optional backward-name)
  "Registers a (def-foreign-function C-NAME SIGNATURE [BACKWARD-NAME]). SIGNATURE
   is a Crisp arrow spec, possibly wrapped as (function (...)) from #'(...).
   Builds a single function-signature in *function-table* (synthetic param names;
   only the types matter for resolution) and records the verbatim C name in
   *foreign-functions*.

   Endeavor 123 (FFI-AD): when BACKWARD-NAME is supplied, also wires the foreign
   function into *differentiable-functions* (via %register-foreign-backward) so a
   call to it inside a --differentiate kernel routes its backward pass through
   BACKWARD-NAME (the user-supplied VJP)."
  (let* ((spec (if (and (consp signature) (symbolp (first signature))
                        (string-equal (symbol-name (first signature)) "FUNCTION"))
                   (second signature)
                   signature))
         (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                  (string-equal (symbol-name x) "=>")))
                                 spec))
         (param-type-specs (subseq spec 0 (or arrow-pos (length spec))))
         (return-types (analyze-return-type-from-spec spec))
         (params (loop for ty in param-type-specs
                       for i from 0
                       collect (make-parameter-def
                                :name (intern (format nil "ARG~a" i) (symbol-package c-name))
                                :type (parse-type-specifier ty)
                                :kind :in)))
         (sig (make-function-signature :name c-name
                                       :parameters params
                                       :return-types return-types)))
    (setf (gethash c-name *function-table*) (list sig))
    (setf (gethash c-name *foreign-functions*) (%foreign-c-name c-name))
    (log:info "FFI: registered foreign function ~a -> C name ~s (~a params, returns ~a)"
              c-name (gethash c-name *foreign-functions*) (length params) return-types)
    (when backward-name
      (%register-foreign-backward c-name params return-types backward-name))
    c-name))

(defun %register-foreign-backward (c-name params return-types backward-name)
  "Endeavor 123 (FFI-AD): registers C-NAME in *differentiable-functions* so the
   backward walk (%handle-sub-fn-call-backward / the void-statement branch ->
   %emit-foreign-backward) drives the user-supplied VJP BACKWARD-NAME.

   Unlike the sub-function convention (%count-differentiable-contributions, which
   treats integer scalars as gradient-inert), FFI treats every active scalar
   input — float AND integer — as differentiable, matching Crisp's kernel-level
   integer differentiation.

   Stored slots:
   - :ACTIVE-SCALAR-INDICES — param positions of float/int scalars, in forward
     order. The VJP returns one gradient per such input (accumulated into that
     input's adjoint). :N-FLOAT-PARAMS mirrors the count for legacy callers.
   - :POINTER-PARAM-INDICES — param positions of c-pointer / voidp (active
     memory) inputs. Each gets a shadow pointer appended to the VJP call,
     sourced from <storage>_GRAD (Pass 2 shadow routing).
   - Handles (c-handle) and other types are passive: in neither list, so they
     contribute no seed, no shadow, and no returned gradient."
  (let* ((active-scalar-indices
          (loop for p in params for i from 0
                  when (%ffi-active-scalar-param-p (parameter-def-type p))
                collect i))
         (pointer-param-indices
          (loop for p in params for i from 0
                  when (%ffi-pointer-param-p (parameter-def-type p))
                collect i))
         (n-return (length (remove nil return-types))))
    (setf (gethash c-name *differentiable-functions*)
          (list :bkwd-name backward-name
                :n-float-params (length active-scalar-indices)
                :active-scalar-indices active-scalar-indices
                :pointer-param-indices pointer-param-indices
                :n-return n-return
                :tensor-param-indices nil
                :foreign t))
    (log:info "FFI-AD: registered VJP ~a for foreign ~a (active-scalars=~a pointers=~a n-return=~a)"
              backward-name c-name active-scalar-indices pointer-param-indices n-return)))

(defun %ffi-active-scalar-param-p (type-spec)
  "T if TYPE-SPEC is an active (differentiable) scalar for FFI VJP purposes:
   a float-category OR integer-category scalar. Integers are active here (Crisp
   differentiates them, promoting gradients to float/double), in contrast to the
   sub-function delta convention which treats integer scalars as inert."
  (or (%crisp-float-type-p type-spec)
      (%crisp-integer-scalar-type-p type-spec)))

(defun %ffi-pointer-param-p (type-spec)
  "T if TYPE-SPEC is a c-pointer / voidp (active memory) for FFI shadow routing.
   voidp is matched by name (it is a convenience alias for a generic c-pointer
   and may not canonicalize to a (c-pointer ...) head)."
  (let ((canon (ignore-errors (canonicalize-type-specifier type-spec))))
    (or (and (symbolp canon) (string-equal (symbol-name canon) "VOIDP"))
        (and (symbolp type-spec) (string-equal (symbol-name type-spec) "VOIDP"))
        (and (consp canon) (symbolp (first canon))
             (string-equal (symbol-name (first canon)) "C-POINTER")))))



(defvar *math-precision* :ieee
  "Endeavor 126: active math-precision mode for FP codegen — :ieee (plain, strict FP)
   or :fast (per-instruction fast-math flags stamped on FP ops). Set by
   initialize-compiler from --math-precision / --force-math-precision. Default :ieee
   (PENDING DECISION 2026-07-02): the language's stated default is `fast`, but
   flipping it globally breaks every numerical-correctness check (HOIST-EXPECT exact
   output, VERIFY-AUTODIFF finite-difference) — those must run under :ieee. Kept :ieee
   until we decide precise-default (nvcc/clang style, fast opt-in) vs. fast-default +
   forcing :ieee for all correctness runs.")

(defvar *force-math-precision* nil
  "Endeavor 126: when non-NIL (:fast/:ieee), the --force-math-precision hard override
   is active — it LOCKS the precision, so in-source `(declaim (precision …))` and
   `with-precision` choices are ignored. NIL means no force: declaim (pass 4) /
   with-precision (pass 5) may set *math-precision*. Precedence:
   --force > with-precision > declaim > --math-precision > default(:ieee).")

(defvar *denormal-handling* :preserve
  "Endeavor 126: subnormal handling for FP codegen — :preserve (strict IEEE gradual
   underflow) or :ftz (flush subnormals to sign-preserved zero). Orthogonal to
   *math-precision*. Set by initialize-compiler from --denormal-handling. Stamped as
   the `denormal-fp-math` function attribute (PTX/NVPTX honours it directly; SPIR-V
   needs a DenormFlushToZero execution mode, emitted separately). Default :preserve
   matches the precise (:ieee) default and nvcc (-ftz=false).")

(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil)
                                 (math-precision :ieee) (force-math-precision nil)
                                 (denormal-handling :preserve))
  "Initializes the compiler state.
   Extended to clear *grid-functions* for def-grid-function support."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Endeavor 126: force is the hard lock; the effective starting precision is
  ;; force (if given) else the --math-precision flag. declaim/with-precision may
  ;; later mutate *math-precision* only when *force-math-precision* is NIL.
  (setf *force-math-precision* force-math-precision)
  (setf *math-precision* (or force-math-precision math-precision))
  (setf *denormal-handling* denormal-handling)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
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

  ;; clear dispatch declarations side table
  (clrhash *kernel-dispatch-declarations*)

  ;; clear grid-function registry
  (clrhash *grid-functions*)

  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))