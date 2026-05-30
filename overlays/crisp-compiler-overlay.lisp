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


