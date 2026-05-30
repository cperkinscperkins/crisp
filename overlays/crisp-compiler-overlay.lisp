;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


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


;; ----------------------------------------------------------------------
;; src/compiler.lisp — whole-function redefine of compile-to-ptx
;; ----------------------------------------------------------------------

(defun compile-to-ptx (module output-path &key (compute-capability "sm_80") debug-p)
  "Compiles an LLVM Module to PTX using llc.
   Pipeline: IR -> opt -O3 (if available) -> llc -> PTX.
   COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)
                       sm_80 = Ampere (required for endeavor 114's cp.async path).
                       Pre-Ampere targets can pass an explicit value if needed,
                       but kernels using request-load-tile / await-request will
                       fail to compile on anything earlier."
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


;; ----------------------------------------------------------------------
;; src/compiler.lisp — whole-function redefine of compile-to-spv
;; ----------------------------------------------------------------------
;;
;; Adds opt -O3 before llvm-as.  Note: the SPV path has its own quirks
;; (kernel metadata injection, atomic-float extension flag) that we
;; preserve verbatim; only the new opt step is bracketed at the start.

(defun compile-to-spv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt -O3 -> llvm-as -> llvm-spirv.
   (bug 028 workaround Part 2)."
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

    ;; 2. opt -O3 on the IR (gracefully degrades if opt missing).
    ;;    Feed the optimized IR to llvm-as if opt succeeded, raw IR otherwise.
    (let* ((opt-ok      (%run-opt-O3 ll-file ll-opt-file))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))

      ;; 3. llvm-as (LL -> BC)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))

    ;; 4. llvm-spirv (BC -> SPV)
    ;; Backward kernels emit `atomicrmw fadd` for thread-safe gradient
    ;; accumulation into tensor _grad cells.  Under --differentiate, request
    ;; the SPV_EXT_shader_atomic_float_add extension so translation succeeds.
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ad-flags (if *differentiate-p*
                         '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                         nil))
           (flags (append debug-flags ad-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;; ======================================================================
;; src/analysis/control.lisp — %expand-loop-vector-stride-form
;; Exact-iter-count rewrite to close the kernel-perf gap with hand-written
;; CUDA grid-stride loops.
;; ======================================================================
;;
;; Old expansion:
;;
;;   (let ((gid    (get-global-id 0))
;;         (gsize  (get-global-work-size 0))
;;         (len    (length~ vec)))
;;     (declare (grid-level))
;;     (dotimes (k len gsize)               ; strided: k = 0, gsize, 2*gsize, ...
;;       (let ((i (+ k gid)))
;;         (if (< i len) BODY ()))))         ; per-iter guard
;;
;; The per-iteration `(if (< i len) ...)` is a runtime bounds check that
;; LLVM cannot always remove (the dotimes trip count covers all gid values,
;; so the predicate depends on gid + k * gsize and is not loop-invariant).
;; Hand-written CUDA writes the loop as:
;;
;;   for (int i = gid; i < n; i += gstride) { body; }
;;
;; — a single-counter loop with one exit check.  SCEV recognises it as an
;; affine recurrence and LLVM can unroll / vectorize aggressively.
;;
;; New expansion mirrors that shape: compute the exact iteration count
;; (handling the gid >= len edge case with a single outer guard), then run
;; a straight dotimes with `i = gid + k * gsize`:
;;
;;   (let ((gid    (get-global-id 0))
;;         (gsize  (get-global-work-size 0))
;;         (len    (length~ vec)))
;;     (declare (grid-level))
;;     (let ((iters (if (>= gid len)
;;                      (to-ulong 0)
;;                      (+ (to-ulong 1)
;;                         (/ (- (- len (to-ulong 1)) gid) gsize)))))
;;       (dotimes (k iters)
;;         (let ((i (+ gid (* k gsize))))
;;           BODY))))
;;
;; iters formula: 1 + floor((len - 1 - gid) / gsize) for gid < len, else 0.
;; The outer IF short-circuits the underflow on (len - 1 - gid) when gid
;; ≥ len (and equivalently when len = 0, since gid ≥ 0 ≥ len).
;;
;; AD compatibility (107 fix): the backward walker recognises LET, IF
;; (here in let-binding init position), DOTIMES, and the inner LET; the
;; old inner IF guard is now gone because every iteration is in-bounds
;; by construction, which strictly simplifies the backward walk (no
;; conditional accumulation across the body).

(defun %expand-loop-vector-stride-form (expr location)
  "Pure expansion of (loop-vector-stride VEC (VAR) BODY...).  Computes the
   exact per-thread iteration count up front, so the inner loop is a
   single-counter dotimes with no per-iteration bounds check.  Mirrors
   the canonical CUDA grid-stride loop shape, which LLVM SCEV / unroller
   can optimise aggressively.

   AD-safe: backward walker handles LET, IF, DOTIMES, LET (inner) — same
   form set as the prior expansion, but with the body unconditional."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form     (second expr))
         (var-name     (first (third expr)))
         (body-forms   (cdddr expr))
         (gid-sym      (gensym "GID"))
         (gsize-sym    (gensym "GSIZE"))
         (len-sym      (gensym "LEN"))
         (iters-sym    (gensym "ITERS"))
         (k-sym        (gensym "K"))
         (cl-pkg       (find-package :crisp-language))
         (let-sym         (intern "LET"                 cl-pkg))
         (declare-sym     (intern "DECLARE"             cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
         (dotimes-sym     (intern "DOTIMES"             cl-pkg))
         (if-sym          (intern "IF"                  cl-pkg))
         (progn-sym       (intern "PROGN"               cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"       cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym   (intern "LENGTH~"             cl-pkg))
         (plus-sym        (intern "+"                   cl-pkg))
         (minus-sym       (intern "-"                   cl-pkg))
         (mul-sym         (intern "*"                   cl-pkg))
         (div-sym         (intern "/"                   cl-pkg))
         (ge-sym          (intern ">="                  cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG"            cl-pkg))
         ;; (to-ulong 0) and (to-ulong 1) — small ulong literals used in
         ;; the iteration-count formula.
         (zero-ulong      (list to-ulong-sym 0))
         (one-ulong       (list to-ulong-sym 1))
         ;; iters = 1 + (len - 1 - gid) / gsize   (when gid < len)
         ;;       = 0                              (when gid >= len)
         (iters-true-branch
          (list plus-sym
                one-ulong
                (list div-sym
                      (list minus-sym
                            (list minus-sym len-sym one-ulong)
                            gid-sym)
                      gsize-sym)))
         (iters-form
          (list if-sym
                (list ge-sym gid-sym len-sym)
                zero-ulong
                iters-true-branch))
         ;; Inner body: rebind user's VAR to gid + k * gsize, then run body
         ;; unconditionally.
         (i-binding
          (list var-name
                (list plus-sym gid-sym (list mul-sym k-sym gsize-sym))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let
          (list let-sym (list i-binding) inner-body))
         (dotimes-form
          (list dotimes-sym (list k-sym iters-sym) inner-let))
         (iters-let
          (list let-sym (list (list iters-sym iters-form)) dotimes-form))
         (expansion
          (list let-sym
                (list (list gid-sym   (list get-gid-sym   0))
                      (list gsize-sym (list get-gsize-sym 0))
                      (list len-sym   (list len-tilde-sym vec-form)))
                (list declare-sym (list grid-level-sym))
                iters-let)))
    expansion))


;; ======================================================================
;; src/codegen.lisp — !invariant.load metadata for read-only kernel-param
;; tensor element loads.
;; ======================================================================
;;
;; Convention: when a def-kernel signature has an &out parameter, any
;; tensor parameter declared BEFORE &out (positional, &optional, or &key)
;; is treated as read-only.  Indexed reads via (~ T i) on such a tensor
;; get the LLVM `!invariant.load !{}` metadata, which NVPTX lowers to
;; `ld.global.nc.f32` — the non-coherent / texture-cache load path.
;; Hand-written CUDA gets this via `const float* __restrict__`.
;;
;; Documented limitations:
;;
;;   1. Kernels with no &out parameter are skipped (no read-only inference
;;      possible — kernel may write back through any of its params).
;;
;;   2. Only direct references `(~ paramsym i)` are detected.  Aliased
;;      references such as `(let ((x input)) (~ x i))` lose the optimisation
;;      — we conservatively don't propagate the read-only property through
;;      let-bindings or function calls.  No miscompile risk: missing the
;;      metadata is always safe, just slower.
;;
;;   3. Only tensor params benefit.  Cells written via `atomic-add!`
;;      would be miscompiled if marked, so we exclude them entirely.
;;
;; AD compatibility: under --differentiate, the backward kernel rebuilds
;; its param-list with the input/output split inverted (forward inputs
;; become _GRAD outputs and vice versa).  The same rule applies: any
;; tensor that's :in in the backward kernel can be marked read-only.

(defparameter *kernel-readonly-tensor-syms* nil
  "Hash-table set of kernel-param symbols whose indexed loads should be
   marked with !invariant.load metadata.  Bound by generate-function-body
   around the body codegen loop; read by the semantic-aref tensor case.
   NIL means no read-only inference applies (kernel has no &out, or non-
   kernel function).")

(defun %collect-readonly-tensor-param-syms (semantic-function)
  "Looks up SEMANTIC-FUNCTION's high-level (pre-flatten) declared
   signature in *KERNEL-DECLARED-SIGNATURES* and returns a hash-table
   of param symbols whose tensor reads can be marked invariant, or NIL
   if the convention doesn't apply.

   The convention applies iff the kernel's declared params include &OUT.
   Every param BEFORE the &OUT marker that is also a float or integer
   tensor goes into the returned set.

   Returns NIL when:
     - The function isn't a registered kernel (no entry in
       *KERNEL-DECLARED-SIGNATURES*).  Helper functions, accessors, and
       internally-generated functions all fall here — safe default.
     - The declared signature contains no &OUT marker (kernel may write
       through any param; no read-only inference possible).
     - No qualifying tensor params remain after filtering.

   Declared signature shape: a list of (PARAM-NAME . TYPE-SPEC) pairs,
   except &OUT itself which appears as (&OUT . &OUT)."
  (let* ((fn-name  (semantic-function-name semantic-function))
         (declared (gethash fn-name *kernel-declared-signatures*)))
    (when declared
      (let ((out-pos (position-if
                      (lambda (entry)
                        (and (consp entry)
                             (symbolp (car entry))
                             (string-equal (symbol-name (car entry)) "&OUT")))
                      declared)))
        (when out-pos
          (let ((ht (make-hash-table :test 'eq)))
            (loop for entry in declared
                  for i from 0
                  while (< i out-pos)
                  when (and (consp entry)
                            (symbolp (car entry))
                            (let ((t-spec (cdr entry)))
                              (or (crisp.compiler::%crisp-float-tensor-type-p t-spec)
                                  (crisp.compiler::%crisp-integer-tensor-type-p t-spec))))
                  do (setf (gethash (car entry) ht) t))
            (when (> (hash-table-count ht) 0) ht)))))))

(defun %attach-invariant-load (loaded-inst module)
  "Attach `!invariant.load !{}` metadata to the LLVM load instruction
   LOADED-INST.  The empty MD node is the LLVM convention for the
   invariant.load assertion.  NVPTX lowers `load` + `!invariant.load`
   to `ld.global.nc.f32` (texture-cache / non-coherent path).

   Note: LLVMMDNodeInContext2 returns an LLVMMetadataRef; LLVMSetMetadata
   expects an LLVMValueRef.  We wrap via LLVMMetadataAsValue."
  (let* ((ctx       (crisp.llvm-bindings::llvm-get-module-context module))
         (kind-name "invariant.load")
         (kind-id   (crisp.llvm-bindings::llvm-get-md-kind-id-in-context
                     ctx kind-name (length kind-name)))
         (empty-md-ref (crisp.llvm-bindings::llvm-md-node-in-context2
                        ctx (cffi:null-pointer) 0))
         (empty-md-val (crisp.llvm-bindings::llvm-metadata-as-value
                        ctx empty-md-ref)))
    (crisp.llvm-bindings::llvm-set-metadata loaded-inst kind-id empty-md-val)))

(defun %array-node-readonly-tensor-param-p (array-node)
  "Returns T if ARRAY-NODE is a direct reference (semantic-var-read)
   to a kernel-param symbol in *KERNEL-READONLY-TENSOR-SYMS*.  Aliased
   references (let-bindings, function-call results) return NIL — they
   degrade gracefully to a plain load."
  (and *kernel-readonly-tensor-syms*
       (semantic-var-read-p array-node)
       (gethash (semantic-var-read-name array-node)
                *kernel-readonly-tensor-syms*)))


;; ----------------------------------------------------------------------
;; src/codegen.lisp — whole-function redefine of generate-function-body
;; ----------------------------------------------------------------------
;;
;; Only change vs. src: wraps the body-codegen loop in a let that binds
;; *kernel-readonly-tensor-syms* to the set computed from PARAM-NODES.

(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function.
   Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the
   PTX kernel-entry receive site can inttoptr demoted i64 params back
   to their original-addrspace pointer.
   Binds *kernel-readonly-tensor-syms* around the body codegen so the
   semantic-aref tensor case can attach !invariant.load to direct
   reads of read-only kernel-param tensors."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function))
        (is-entry-point (semantic-function-is-entry-point semantic-function)))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env is-entry-point)

    (let ((*kernel-readonly-tensor-syms*
           (%collect-readonly-tensor-param-syms semantic-function)))
      (when *kernel-readonly-tensor-syms*
        (log:debug "Read-only tensor params for kernel ~a: ~a"
                   (semantic-function-name semantic-function)
                   (loop for k being the hash-keys of *kernel-readonly-tensor-syms*
                         collect k)))

      (let* ((body-nodes (semantic-function-body semantic-function))
             (is-void-return (or (null return-types)
                                 (equal return-types '(nil))
                                 (and (consp return-types) (symbolp (first return-types)) (string-equal (first return-types) "VOID"))))
             (last-val nil)
             (last-loc nil))
        (dolist (node body-nodes)
          (multiple-value-bind (val loc)
              (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
            (setf last-val val)
            (setf last-loc loc)))

        (let ((ret-inst (if is-void-return
                            (llvm-build-ret-void builder)
                            (let* ((ret-type-spec (first return-types))
                                   (expected-type (crisp-type-to-llvm-type ret-type-spec module))
                                   (actual-type (llvm-type-of last-val)))
                              (if (and (llvm-type-kind-is-pointer? actual-type)
                                       (not (llvm-type-kind-is-pointer? expected-type)))
                                  (llvm-build-ret builder (llvm-build-load2 builder expected-type last-val "ret_val"))
                                  (llvm-build-ret builder last-val))))))
          (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc)))))))


;; ----------------------------------------------------------------------
;; src/codegen.lisp — whole-defmethod redefine of generate-node-ir for
;; semantic-aref.
;; ----------------------------------------------------------------------
;;
;; Only change vs. src: in the TENSOR case, after the load is emitted,
;; check whether ARRAY-NODE is a direct ref to a read-only kernel-param
;; tensor symbol and, if so, attach !invariant.load metadata.  The two
;; other cases (fixed-size array, CELL) are copied verbatim.

(defmethod generate-node-ir ((node semantic-aref) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for array/cell/tensor element access (aref / ~ / ~ref~).
   Case 2: (array T N) fixed-size array — GEP into alloca (unchanged).
   Case 3: TENSOR — parent.address from SROA field 0; byte-off = flat_idx * sizeof(elem);
     GEP i8* + byte-off, bitcast, load.  Load gets !invariant.load when
     ARRAY-NODE is a direct ref to a read-only kernel-param tensor.
   Case 1: CELL — original behaviour unchanged.
   Returns (values loaded-val nil elem-ptr) so set! can store through the pointer."
  (let* ((array-node   (semantic-aref-array-node node))
         (index-node   (semantic-aref-index-node node))
         (array-type   (let ((raw (semantic-node-type array-node)))
                         (if (and (listp raw) (= (length raw) 1) (listp (first raw)))
                             (first raw)
                             raw)))
         (element-type (semantic-aref-type node))
         (index-val    (generate-node-ir index-node builder module var-env
                                         di-builder di-scope location-map)))

    (let ((cell-spec (let* ((resolved (resolve-type-alias array-type))
                            (canon    (canonicalize-type-specifier resolved)))
                       (cond
                        ((and (listp canon) (symbolp (first canon))
                              (string-equal (symbol-name (first canon)) "CELL")) canon)
                        ((and (listp canon) (= (length canon) 1) (symbolp (first canon)))
                         (unmangle-template-struct-name (first canon)))
                        ((symbolp canon)
                         (unmangle-template-struct-name canon))
                        (t canon)))))

      (cond
       ;; Case 2: (array T N) fixed-size array — GEP into alloca (unchanged)
       ((%array-type-p (resolve-type-alias array-type))
        (let* ((resolved-arr-type (resolve-type-alias array-type))
               (elem-type-spec    (second resolved-arr-type))
               (count-raw         (third  resolved-arr-type))
               (count             (etypecase count-raw
                                    (integer count-raw)
                                    (symbol  (parse-integer (symbol-name count-raw)))))
               (elem-llvm-type    (crisp-type-to-llvm-type elem-type-spec module))
               (arr-llvm-type     (crisp.llvm-bindings::llvm-array-type elem-llvm-type count))
               (arr-ptr
                (let ((inline-ptr (%try-inline-struct-array-field-ptr
                                   array-node builder module var-env
                                   di-builder di-scope location-map)))
                  (if inline-ptr
                      inline-ptr
                      (if (semantic-var-read-p array-node)
                          (let ((alloca (gethash (semantic-var-read-name array-node) var-env)))
                            (unless alloca
                              (error "array aref: variable ~a not found in var-env"
                                     (semantic-var-read-name array-node)))
                            alloca)
                          (multiple-value-bind (sub-val _loc sub-ptr)
                              (generate-node-ir array-node builder module var-env
                                                di-builder di-scope location-map)
                            (declare (ignore _loc))
                            (cond
                             (sub-ptr
                              (log:info "array-aref: using sub-ptr from inner aref (bug 029 path)")
                              sub-ptr)
                             ((llvm-type-kind-is-pointer? (llvm-type-of sub-val))
                              sub-val)
                             (t
                              (let ((slot (llvm-build-alloca builder arr-llvm-type "arr_tmp")))
                                (llvm-build-store builder sub-val slot)
                                slot))))))))
               (idx-i64 (llvm-build-sext builder index-val (llvm-int64-type) "arr_idx")))

          (log:info "array-aref: type=(array ~a ~a) ptr=~a idx=~a"
                    elem-type-spec count arr-ptr idx-i64)

          (cffi:with-foreign-object (indices :pointer 2)
            (setf (cffi:mem-aref indices :pointer 0)
                  (llvm-const-int (llvm-int32-type) 0 nil))
            (setf (cffi:mem-aref indices :pointer 1) idx-i64)
            (let* ((elem-ptr (llvm-build-in-bounds-gep2
                              builder arr-llvm-type arr-ptr indices 2 "arr_elem_ptr"))
                   (loaded   (llvm-build-load2 builder elem-llvm-type elem-ptr "arr_elem")))
              (values loaded nil elem-ptr)))))

       ;; Case 3: TENSOR — flat index pre-computed; GEP via parent storage pointer.
       ;; SROA field 0 of tensor is (storage Addr) → {address ptr, byte-size}.
       ;; Field 0 of storage is the raw pointer.
       ;; NEW: read-only kernel-param tensor reads get !invariant.load.
       ((and (listp cell-spec) (symbolp (first cell-spec))
             (string-equal (symbol-name (first cell-spec)) "TENSOR"))
        (let* ((tensor-val     (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-name   (mangle-template-struct-name (first cell-spec)
                                                            (rest cell-spec)))
               (mark-invariant-p (%array-node-readonly-tensor-param-p array-node)))
          (log:info "semantic-aref tensor: struct=~a elem=~a invariant=~a"
                    mangled-name elem-type-spec mark-invariant-p)
          (ensure-struct-llvm-type mangled-name)
          (let* ((parent-val  (llvm-build-extract-value builder tensor-val 0 "t_parent_val"))
                 (base-ptr    (llvm-build-extract-value builder parent-val 0 "t_base_ptr"))
                 ;; flat element index already incorporates offsets and strides
                 (flat-i64    (llvm-build-sext builder index-val (llvm-int64-type) "t_flat_i64"))
                 (elem-size   (llvm-size-of elem-llvm-type))
                 (byte-off    (llvm-build-mul builder flat-i64 elem-size "t_byte_off")))
            (cffi:with-foreign-object (indices :pointer 1)
              (setf (cffi:mem-aref indices :pointer 0) byte-off)
              (let* ((ptr-i8   (llvm-build-in-bounds-gep2
                                builder (llvm-int8-type) base-ptr indices 1 "t_ptr_i8"))
                     (ptr-as   (llvm-get-pointer-address-space (llvm-type-of ptr-i8)))
                     (t-ptr    (llvm-build-bit-cast
                                builder ptr-i8
                                (llvm-pointer-type elem-llvm-type ptr-as) "t_ptr"))
                     (loaded   (llvm-build-load2 builder elem-llvm-type t-ptr "t_elem")))
                (when mark-invariant-p
                  (%attach-invariant-load loaded module))
                (values loaded nil t-ptr))))))

       ;; Case 1: CELL parameterized type (unchanged)
       ((and (listp cell-spec) (symbolp (first cell-spec))
             (string-equal (symbol-name (first cell-spec)) "CELL"))
        (let* ((cell-val       (generate-node-ir array-node builder module var-env
                                                 di-builder di-scope location-map))
               (elem-type-spec element-type)
               (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
               (mangled-struct-name (mangle-template-struct-name (first cell-spec)
                                                                  (rest cell-spec))))
          (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
          (ensure-struct-llvm-type mangled-struct-name)
          (let ()
            (log:info "semantic-aref: Using ExtractValue to access Cell Record members.")
            (let* ((parent-val   (llvm-build-extract-value builder cell-val 0 "parent_val"))
                   (base-ptr     (llvm-build-extract-value builder parent-val 0 "base_ptr"))
                   (cell-offset  (llvm-build-extract-value builder cell-val 1 "cell_offset"))
                   (elem-size    (llvm-size-of elem-llvm-type))
                   (index-i64    (llvm-build-sext builder index-val (llvm-int64-type) "index_i64"))
                   (index-bytes  (llvm-build-mul builder index-i64 elem-size "index_bytes"))
                   (total-offset (llvm-build-add builder cell-offset index-bytes "total_offset")))
              (cffi:with-foreign-object (indices :pointer 1)
                (setf (cffi:mem-aref indices :pointer 0) total-offset)
                (let* ((final-ptr-i8 (llvm-build-in-bounds-gep2
                                      builder (llvm-int8-type) base-ptr indices 1 "final_ptr_i8"))
                       (ptr-as       (llvm-get-pointer-address-space
                                      (llvm-type-of final-ptr-i8)))
                       (target-ptr   (llvm-build-bit-cast
                                      builder final-ptr-i8
                                      (llvm-pointer-type elem-llvm-type ptr-as) "target_ptr"))
                       (loaded-val   (llvm-build-load2
                                      builder elem-llvm-type target-ptr "val")))
                  (values loaded-val nil target-ptr)))))))

       (t (error "generate-node-ir semantic-aref: Unsupported array type: ~a (unmangled: ~a)"
                 array-type cell-spec))))))


;; ======================================================================
;; Endeavor: stride macros — exact-iter-count rewrite (Group A)
;;
;; Group A is the 1-D family of grid-stride loops that all share the same
;; broken pattern:
;;
;;   (dotimes (k LEN GSIZE)            ; k = 0, GSIZE, 2*GSIZE, ...
;;     (let ((flat (+ k GID)))
;;       (if (< flat LEN) BODY ())))
;;
;; The per-iteration `if (< flat LEN)` is a runtime bounds check that
;; LLVM SCEV can't always remove (the dotimes trip count covers all gid
;; values, so the predicate depends on `gid + k * gsize` and is not
;; loop-invariant).  Hand-written CUDA writes the loop as
;; `for (int i = gid; i < n; i += gstride)` — a single-counter affine
;; loop the unroller / vectorizer handle aggressively.
;;
;; New shape mirrors that:
;;
;;   (let ((iters (if (>= GID LEN)
;;                    (to-ulong 0)
;;                    (+ (to-ulong 1) (/ (- (- LEN (to-ulong 1)) GID) GSIZE)))))
;;     (dotimes (k iters)
;;       (let ((flat (+ GID (* k GSIZE))))
;;         BODY)))
;;
;; iters formula: 1 + floor((len - 1 - gid) / gsize) for gid < len, else 0.
;; The outer guard short-circuits the (len - 1 - gid) underflow when
;; gid >= len or len = 0.
;;
;; Macros covered here (all share the shared helper):
;;   - tensor-stride        — N-D tensor walk (decode flat → coords inside)
;;   - grid-stride          — synthetic N-D walk over a size-list
;;   - hardware-stride
;;       :warp-idx          — 1D warp-strided walk over flattened linear domain
;;   - loop-vector-stride   — 1D walk over a vector (refactor for consistency)
;;
;; AD compatibility: backward walker recognises LET, IF (in let-binding
;; init position), DOTIMES, PROGN — all forms used here.  The IF in the
;; iters compute returns an integer count, not a differentiable value,
;; so AD handles it as straight control flow.

(defun %build-exact-iter-count-form (start-sym stride-sym len-sym cl-pkg)
  "Returns an expression that computes the exact iteration count for a
   grid-stride loop starting at START-SYM and stepping by STRIDE-SYM,
   visiting only positions < LEN-SYM.  All three symbols name ULONG values.

   Formula:
     iters = (start >= len) ? 0
                            : 1 + (len - 1 - start) / stride

   The outer (>= start len) guard short-circuits the (len - 1 - start)
   ulong underflow when start >= len or len = 0."
  (let ((if-sym       (intern "IF" cl-pkg))
        (ge-sym       (intern ">=" cl-pkg))
        (plus-sym     (intern "+" cl-pkg))
        (minus-sym    (intern "-" cl-pkg))
        (div-sym      (intern "/" cl-pkg))
        (to-ulong-sym (intern "TO-ULONG" cl-pkg)))
    (let ((zero (list to-ulong-sym 0))
          (one  (list to-ulong-sym 1)))
      (list if-sym
            (list ge-sym start-sym len-sym)
            zero
            (list plus-sym
                  one
                  (list div-sym
                        (list minus-sym
                              (list minus-sym len-sym one)
                              start-sym)
                        stride-sym))))))


;; ----------------------------------------------------------------------
;; src/analysis/control.lisp — %expand-tensor-stride-form
;; ----------------------------------------------------------------------

(defun %expand-tensor-stride-form (expr ct location)
  "Pure expansion of (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).
   CT must be :last or :first (already resolved by caller).  Returns the
   expanded let+dotimes tree.  Validates form shape only — strict-tag vs
   CT agreement and tensor-arity checks are the caller's job.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check)."
  (let* ((strict-p   (keywordp (third expr)))
         (bindings   (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings (listp bindings) (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message (if strict-p
                          "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                          "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
             :source-location location))
    (let* ((n           (length bindings))
           (t-sym       (gensym "T"))
           (gid-sym     (gensym "GID"))
           (gsize-sym   (gensym "GSIZE"))
           (len-sym     (gensym "LEN"))
           (iters-sym   (gensym "ITERS"))
           (k-sym       (gensym "K"))
           (flat-sym    (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           (cl-pkg          (find-package :crisp-language))
           (let-sym         (intern "LET"                 cl-pkg))
           (declare-sym     (intern "DECLARE"             cl-pkg))
           (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
           (dotimes-sym     (intern "DOTIMES"             cl-pkg))
           (progn-sym       (intern "PROGN"               cl-pkg))
           (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
           (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym   (intern "LENGTH~"             cl-pkg))
           (extents-tilde   (intern "EXTENTS~"            cl-pkg))
           (aref-sym        (intern "~"                   cl-pkg))
           (plus-sym        (intern "+"                   cl-pkg))
           (mul-sym         (intern "*"                   cl-pkg))
           (extent-bindings
            (loop for esym in extents-syms
                  for i from 0
                  collect (list esym (list aref-sym (list extents-tilde t-sym) i))))
           (stride-bindings (%ts-build-stride-bindings extents-syms ct))
           (decode-bindings (if (= n 1)
                                (list (list (first bindings) flat-sym))
                                (%ts-build-decode-bindings flat-sym bindings
                                                           (mapcar #'first stride-bindings)
                                                           ct)))
           (inner-body (if (= (length body-forms) 1)
                           (first body-forms)
                           (cons progn-sym body-forms)))
           ;; Decode multi-D coords + body, run unconditionally.
           (decode-let (list let-sym decode-bindings inner-body))
           ;; flat = gid + k * gsize
           (flat-let (list let-sym
                           (list (list flat-sym
                                       (list plus-sym gid-sym
                                             (list mul-sym k-sym gsize-sym))))
                           decode-let))
           (dotimes-form (list dotimes-sym
                               (list k-sym iters-sym)
                               flat-let))
           (iters-let (list let-sym
                            (list (list iters-sym
                                        (%build-exact-iter-count-form
                                         gid-sym gsize-sym len-sym cl-pkg)))
                            dotimes-form))
           (outer-let
            (list* let-sym
                   (append (list (list t-sym     tensor-form)
                                 (list gid-sym   (list get-gid-sym 0))
                                 (list gsize-sym (list get-gsize-sym 0))
                                 (list len-sym   (list len-tilde-sym t-sym)))
                           extent-bindings
                           stride-bindings)
                   (list (list declare-sym (list grid-level-sym))
                         iters-let))))
      outer-let)))


;; ----------------------------------------------------------------------
;; src/analysis/control.lisp — %expand-grid-stride-form
;; ----------------------------------------------------------------------

(defun %expand-grid-stride-form (expr location)
  "Pure expansion of (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  No type
   info needed — grid-stride is always rightmost-binding-gets-warp.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check)."
  (unless (and (>= (length expr) 4)
               (listp (second expr)) (listp (third expr))
               (every #'symbolp (third expr))
               (>= (length (second expr)) 1)
               (= (length (second expr)) (length (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed grid-stride: expected (grid-stride (SIZE ...) (BINDING ...) BODY...) with size and binding arity matching and >= 1"
           :source-location location))
  (let* ((size-forms     (second expr))
         (bindings       (third expr))
         (body-forms     (cdddr expr))
         (n              (length bindings))
         (cl-pkg          (find-package :crisp-language))
         (let-sym         (intern "LET"                 cl-pkg))
         (declare-sym     (intern "DECLARE"             cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
         (dotimes-sym     (intern "DOTIMES"             cl-pkg))
         (progn-sym       (intern "PROGN"               cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym        (intern "+"                   cl-pkg))
         (mul-sym         (intern "*"                   cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG"            cl-pkg))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (iters-sym       (gensym "ITERS"))
         (k-sym           (gensym "K"))
         (flat-sym        (gensym "FLAT"))
         (extents-syms    (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings   (loop for esym in extents-syms
                                for form in size-forms
                                collect (list esym (list to-ulong-sym form))))
         (len-form        (if (= n 1)
                              (first extents-syms)
                              (reduce (lambda (a b) (list mul-sym a b)) extents-syms)))
         (stride-bindings (%ts-build-stride-bindings extents-syms :last))
         (decode-bindings (if (= n 1)
                              (list (list (first bindings) flat-sym))
                              (%ts-build-decode-bindings flat-sym bindings
                                                         (mapcar #'first stride-bindings)
                                                         :last)))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (decode-let (list let-sym decode-bindings inner-body))
         (flat-let (list let-sym
                         (list (list flat-sym
                                     (list plus-sym gid-sym
                                           (list mul-sym k-sym gsize-sym))))
                         decode-let))
         (dotimes-form (list dotimes-sym
                             (list k-sym iters-sym)
                             flat-let))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       gid-sym gsize-sym len-sym cl-pkg)))
                          dotimes-form))
         (outer-let
          (list* let-sym
                 (append (list (list gid-sym   (list get-gid-sym 0))
                               (list gsize-sym (list get-gsize-sym 0)))
                         size-bindings
                         (list (list len-sym len-form))
                         stride-bindings)
                 (list (list declare-sym (list grid-level-sym))
                       iters-let))))
    outer-let))


;; ----------------------------------------------------------------------
;; src/analysis/control.lisp — %expand-hw-warp-idx-form
;; ----------------------------------------------------------------------

(defun %expand-hw-warp-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :warp-idx.  Always 1D.
   Bare load-tile / store-tile inside :warp-idx remain a compile error.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check).
   Loop start  = mywarp * ws         (warp-uniform within a warp)
   Loop stride = ws * numwarps       (warp-uniform across the device)
   Loop var    = start + k * stride."
  (declare (ignore location))
  (dolist (f body-forms)
    (%detect-bare-load-store-tile-in-form f "hardware-stride :warp-idx"))
  (let* ((cl-pkg              (find-package :crisp-language))
         (let-sym             (intern "LET"                    cl-pkg))
         (declare-sym         (intern "DECLARE"                cl-pkg))
         (grid-level-sym      (intern "GRID-LEVEL"             cl-pkg))
         (dotimes-sym         (intern "DOTIMES"                cl-pkg))
         (progn-sym           (intern "PROGN"                  cl-pkg))
         (to-ulong-sym        (intern "TO-ULONG"               cl-pkg))
         (len-tilde-sym       (intern "LENGTH~"                cl-pkg))
         (get-glid-sym        (intern "GET-GLOBAL-LINEAR-ID"   cl-pkg))
         (get-glsize-sym      (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (plus-sym            (intern "+"                      cl-pkg))
         (mul-sym             (intern "*"                      cl-pkg))
         (div-sym             (intern "/"                      cl-pkg))
         (t-sym         (gensym "T"))
         (ws-sym        (gensym "WSIZE"))
         (len-sym       (gensym "LEN"))
         (glid-sym      (gensym "GLID"))
         (glsize-sym    (gensym "GLSIZE"))
         (mywarp-sym    (gensym "MYWARP"))
         (numwarps-sym  (gensym "NUMWARPS"))
         (start-sym     (gensym "WSTART"))
         (stride-sym    (gensym "WSTRIDE"))
         (iters-sym     (gensym "ITERS"))
         (k-sym         (gensym "K"))
         (var-name      (first bindings))
         (rewritten-body (%tile-helpers-rewrite body-forms 1
                                                (lambda (k)
                                                  (declare (ignore k))
                                                  ws-sym)))
         (inner-body (if (= (length rewritten-body) 1)
                         (first rewritten-body)
                         (cons progn-sym rewritten-body)))
         (var-let (list let-sym
                        (list (list var-name
                                    (list plus-sym start-sym
                                          (list mul-sym k-sym stride-sym))))
                        inner-body))
         (dotimes-form (list dotimes-sym
                             (list k-sym iters-sym)
                             var-let))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       start-sym stride-sym len-sym cl-pkg)))
                          dotimes-form))
         (outer-let (list let-sym
                          (list (list t-sym        tensor-form)
                                (list ws-sym       (list to-ulong-sym 32))
                                (list len-sym      (list len-tilde-sym t-sym))
                                (list glid-sym     (list get-glid-sym))
                                (list glsize-sym   (list get-glsize-sym))
                                (list mywarp-sym   (list div-sym glid-sym ws-sym))
                                (list numwarps-sym (list div-sym glsize-sym ws-sym))
                                (list start-sym    (list mul-sym mywarp-sym ws-sym))
                                (list stride-sym   (list mul-sym ws-sym numwarps-sym)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    outer-let))


;; ----------------------------------------------------------------------
;; src/analysis/control.lisp — %expand-loop-vector-stride-form
;; (refactor: same algorithm as the earlier overlay redefinition, but
;;  uses the shared %build-exact-iter-count-form helper)
;; ----------------------------------------------------------------------

(defun %expand-loop-vector-stride-form (expr location)
  "Pure expansion of (loop-vector-stride VEC (VAR) BODY...).
   Refactored to use %build-exact-iter-count-form for consistency with
   the rest of Group A.  Same behaviour as the earlier rewrite — single
   counter dotimes, body runs unconditionally."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form        (second expr))
         (var-name        (first (third expr)))
         (body-forms      (cdddr expr))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (iters-sym       (gensym "ITERS"))
         (k-sym           (gensym "K"))
         (cl-pkg          (find-package :crisp-language))
         (let-sym         (intern "LET"                 cl-pkg))
         (declare-sym     (intern "DECLARE"             cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
         (dotimes-sym     (intern "DOTIMES"             cl-pkg))
         (progn-sym       (intern "PROGN"               cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym   (intern "LENGTH~"             cl-pkg))
         (plus-sym        (intern "+"                   cl-pkg))
         (mul-sym         (intern "*"                   cl-pkg))
         (i-binding       (list var-name
                                (list plus-sym gid-sym
                                      (list mul-sym k-sym gsize-sym))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let   (list let-sym (list i-binding) inner-body))
         (dotimes-form (list dotimes-sym (list k-sym iters-sym) inner-let))
         (iters-let   (list let-sym
                            (list (list iters-sym
                                        (%build-exact-iter-count-form
                                         gid-sym gsize-sym len-sym cl-pkg)))
                            dotimes-form))
         (expansion (list let-sym
                          (list (list gid-sym   (list get-gid-sym   0))
                                (list gsize-sym (list get-gsize-sym 0))
                                (list len-sym   (list len-tilde-sym vec-form)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    expansion))


;; ======================================================================
;; src/analysis/control.lisp — %expand-workgroup-stride-form (Group C)
;; ======================================================================
;;
;; Cooperative inner loop for a workgroup to walk a tile's coordinates.
;; Per dim, each thread strides by LWS_i starting at LID_i.
;;
;; Old shape (per dim):
;;
;;   (dotimes (k_i E_i LWS_i)            ; k_i = 0, LWS_i, 2*LWS_i, ...
;;     (let ((b_i (+ k_i LID_i)))
;;       (when (< b_i E_i)
;;         <inner-or-next-dim>)))
;;
;; Two scenarios the old `when` guards:
;;   A. tile > workgroup → some threads iterate multiple times; the tail
;;      iteration may go past extent for some threads.
;;   B. tile < workgroup → threads with LID_i ≥ E_i never enter the body.
;;
;; The `when (< b_i E_i)` is THREAD-DIVERGENT (different threads, different
;; LID_i) — the SCEV unroller can't remove it.
;;
;; New shape (per dim): exact per-thread iter count, no inner guard.
;;
;;   ITERS_i = (LID_i >= E_i) ? 0
;;                            : 1 + (E_i - 1 - LID_i) / LWS_i
;;   (dotimes (j_i ITERS_i)
;;     (let ((b_i (+ LID_i (* j_i LWS_i))))
;;       <inner-or-next-dim>))
;;
;; All ITERS_i bindings sit at the outer LET so the nest stays flat.
;; Threads in scenario B compute ITERS_i = 0 and skip the dim entirely.
;; In both scenarios the body is unconditional — no per-iter compare.
;;
;; Does NOT inject an end barrier (per chapter 13).  Caller inserts
;; (local-barrier) explicitly when needed.

(defun %expand-workgroup-stride-form (expr location)
  "Pure expansion of (workgroup-stride T (BINDINGS) BODY...).  N-dim nested
   per-thread cooperative loop.  Each dim's iter count is computed up
   front (per thread) so the inner dotimes is a single-counter, body-
   unconditional loop the unroller can attack."
  (multiple-value-bind (bindings body-forms tensor-form)
      (%workgroup-stride-parse expr)
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed workgroup-stride: expected (workgroup-stride TENSOR (BINDING ...) BODY...)"
             :source-location location))
    (let* ((n (length bindings))
           (cl-pkg              (find-package :crisp-language))
           (let-sym             (intern "LET"                 cl-pkg))
           (dotimes-sym         (intern "DOTIMES"             cl-pkg))
           (progn-sym           (intern "PROGN"               cl-pkg))
           (aref-sym            (intern "~"                   cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~"            cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID"        cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (plus-sym            (intern "+"                   cl-pkg))
           (mul-sym             (intern "*"                   cl-pkg))
           (t-sym (gensym "T"))
           (e-syms     (loop for i from 0 below n collect (gensym (format nil "E~A"     i))))
           (lid-syms   (loop for i from 0 below n collect (gensym (format nil "LID~A"   i))))
           (lws-syms   (loop for i from 0 below n collect (gensym (format nil "LWS~A"   i))))
           (iters-syms (loop for i from 0 below n collect (gensym (format nil "ITERS~A" i))))
           (k-syms     (loop for i from 0 below n collect (gensym (format nil "K~A"     i))))
           (inner-body (if (= (length body-forms) 1)
                           (first body-forms)
                           (cons progn-sym body-forms)))
           ;; Build the nest from innermost out.  At each level:
           ;;   (dotimes (K_i ITERS_i)
           ;;     (let ((b_i (+ LID_i (* K_i LWS_i))))
           ;;       <inner-or-next-dim>))
           (nest
            (let ((acc inner-body))
              (loop for i from (1- n) downto 0
                    for b-sym     = (nth i bindings)
                    for lid-sym   = (nth i lid-syms)
                    for lws-sym   = (nth i lws-syms)
                    for k-sym     = (nth i k-syms)
                    for iters-sym = (nth i iters-syms)
                    do (setf acc
                             (list dotimes-sym
                                   (list k-sym iters-sym)
                                   (list let-sym
                                         (list (list b-sym
                                                     (list plus-sym lid-sym
                                                           (list mul-sym k-sym lws-sym))))
                                         acc))))
              acc))
           (outer-bindings
            (append
             (list (list t-sym tensor-form))
             (loop for i from 0 below n
                   for e-sym in e-syms
                   collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
             (loop for i from 0 below n
                   for lid-sym in lid-syms
                   collect (list lid-sym (list get-local-id-sym i)))
             (loop for i from 0 below n
                   for lws-sym in lws-syms
                   collect (list lws-sym (list get-lws-sym i)))
             ;; Per-dim exact-iter-count, one per thread.
             (loop for i from 0 below n
                   for iters-sym in iters-syms
                   for lid-sym   in lid-syms
                   for lws-sym   in lws-syms
                   for e-sym     in e-syms
                   collect (list iters-sym
                                 (%build-exact-iter-count-form
                                  lid-sym lws-sym e-sym cl-pkg))))))
      (list let-sym outer-bindings nest))))


;; ======================================================================
;; src/analysis/control.lisp — %expand-workgroup-strided-outer-loop-with-ts-syms
;;   (used by tile-stride and hardware-stride :workgroup-idx — Group B)
;; ======================================================================
;;
;; Old shape (per dim):
;;
;;   (dotimes (k_i E_i (* TS_i NG_i))     ; k_i = 0, TS_i*NG_i, 2*TS_i*NG_i, ...
;;     (let ((b_i (+ k_i (* GID_i TS_i))))
;;       (%uniform-when (< b_i E_i)
;;         <next-dim-or-body>)))
;;
;; Where:
;;   GID_i = get-workgroup-id i      (workgroup-uniform)
;;   NG_i  = get-num-groups i        (workgroup-uniform)
;;   TS_i  = tile size               (workgroup-uniform / compile-time)
;;   E_i   = extents[i]              (workgroup-uniform)
;;
;; The `%uniform-when` is workgroup-uniform (b_i is workgroup-uniform),
;; but it's NOT loop-invariant — b_i changes every iteration.  llc emits
;; it as a per-iter `setp + @p bra` inside the body, and opt -O3 can only
;; sometimes elide it.
;;
;; New shape (per dim): per-workgroup exact-iter-count over chunk origins.
;;
;;   START_i  = GID_i * TS_i              (this WG's chunk origin in dim i)
;;   STRIDE_i = TS_i * NG_i               (distance between chunk origins)
;;   ITERS_i  = (START_i >= E_i) ? 0
;;                               : 1 + (E_i - 1 - START_i) / STRIDE_i
;;   (dotimes (j_i ITERS_i)
;;     (let ((b_i (+ START_i (* j_i STRIDE_i))))
;;       <next-dim-or-body>))
;;
;; No %uniform-when needed.  Divergence checker is happy because there's
;; no conditional to check.

(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Workgroup-strided outer loop over chunk origins.  Per-workgroup exact
   iter count per dim — body runs unconditionally."
  (declare (ignore location))
  (let* ((cl-pkg              (find-package :crisp-language))
         (let-sym             (intern "LET"                cl-pkg))
         (declare-sym         (intern "DECLARE"            cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL"    cl-pkg))
         (dotimes-sym         (intern "DOTIMES"            cl-pkg))
         (progn-sym           (intern "PROGN"              cl-pkg))
         (aref-sym            (intern "~"                  cl-pkg))
         (extents-tilde-sym   (intern "EXTENTS~"           cl-pkg))
         (get-wg-id-sym       (intern "GET-WORKGROUP-ID"   cl-pkg))
         (get-num-groups-sym  (intern "GET-NUM-GROUPS"     cl-pkg))
         (plus-sym            (intern "+"                  cl-pkg))
         (mul-sym             (intern "*"                  cl-pkg))
         (t-sym (gensym "T"))
         (e-syms      (loop for i from 0 below n collect (gensym (format nil "E~A"      i))))
         (gid-syms    (loop for i from 0 below n collect (gensym (format nil "WGID~A"   i))))
         (ng-syms     (loop for i from 0 below n collect (gensym (format nil "NG~A"     i))))
         (start-syms  (loop for i from 0 below n collect (gensym (format nil "START~A"  i))))
         (stride-syms (loop for i from 0 below n collect (gensym (format nil "STRIDE~A" i))))
         (iters-syms  (loop for i from 0 below n collect (gensym (format nil "ITERS~A"  i))))
         (k-syms      (loop for i from 0 below n collect (gensym (format nil "K~A"      i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (nest
          (let ((acc inner-body))
            (loop for i from (1- n) downto 0
                  for b-sym      = (nth i bindings)
                  for start-sym  = (nth i start-syms)
                  for stride-sym = (nth i stride-syms)
                  for iters-sym  = (nth i iters-syms)
                  for k-sym      = (nth i k-syms)
                  do (setf acc
                           (list dotimes-sym
                                 (list k-sym iters-sym)
                                 (list let-sym
                                       (list (list b-sym
                                                   (list plus-sym start-sym
                                                         (list mul-sym k-sym stride-sym))))
                                       acc))))
            acc))
         (outer-bindings
          (append
           (list (list t-sym tensor-form))
           ;; ts_i  = tile size (from caller)
           (loop for i from 0 below n
                 for ts-sym in ts-syms
                 collect (list ts-sym (funcall tile-size-expr-fn i)))
           ;; e_i   = extents[i]
           (loop for i from 0 below n
                 for e-sym in e-syms
                 collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
           ;; gid_i = get-workgroup-id i
           (loop for i from 0 below n
                 for gid-sym in gid-syms
                 collect (list gid-sym (list get-wg-id-sym i)))
           ;; ng_i  = get-num-groups i
           (loop for i from 0 below n
                 for ng-sym in ng-syms
                 collect (list ng-sym (list get-num-groups-sym i)))
           ;; start_i  = gid_i * ts_i
           (loop for i from 0 below n
                 for start-sym in start-syms
                 for gid-sym   in gid-syms
                 for ts-sym    in ts-syms
                 collect (list start-sym (list mul-sym gid-sym ts-sym)))
           ;; stride_i = ts_i * ng_i
           (loop for i from 0 below n
                 for stride-sym in stride-syms
                 for ts-sym     in ts-syms
                 for ng-sym     in ng-syms
                 collect (list stride-sym (list mul-sym ts-sym ng-sym)))
           ;; iters_i  = exact count given start_i, stride_i, e_i
           (loop for i from 0 below n
                 for iters-sym in iters-syms
                 for start-sym in start-syms
                 for stride-sym in stride-syms
                 for e-sym     in e-syms
                 collect (list iters-sym
                               (%build-exact-iter-count-form
                                start-sym stride-sym e-sym cl-pkg))))))
    (list let-sym outer-bindings
          (list declare-sym (list workgroup-level-sym))
          nest)))


