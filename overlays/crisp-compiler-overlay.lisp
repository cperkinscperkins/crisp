;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26.
;;;;
;;;; When you fold future contents back out, two things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.

(in-package :crisp.compiler)


;;;; ============================================================================
;;;; ROOFLINE PROBE, ARM A — SPV_INTEL_cache_controls on the coop-matrix load path.
;;;;
;;;; WHY.  benchmarks/matmul/_probe_roofline measured the shipped fp16 kernel as LOAD-bound:
;;;; T_loads is 95% of T_full, and fetch/math are already ~95% overlapped.  So the win has to
;;;; come from making T_loads itself smaller.  Cache control is the only candidate that costs
;;;; ZERO instructions -- it is a decoration, not an instruction.
;;;;
;;;; WHAT SYCL-TLA DOES.  It overrides the driver default on EVERY block load and prefetch with
;;;; exactly one value, at all 26 call sites, with no variation: CacheControl::kL1C_L3C --
;;;; cached at L1 AND L3.  Crisp currently specifies NOTHING and takes whatever the driver picks.
;;;;
;;;; THE RISK THIS IS BUILT TO TEST.  The peer does NOT use this route: it calls
;;;; __builtin_IB_subgroup_block_read_cacheopts_* with the enum as an explicit ARGUMENT.  Our
;;;; OpSubgroup2DBlockReadINTEL / OpCooperativeMatrixLoadKHR have no cache operand, so a pointer
;;;; DECORATION is our only in-band route -- and whether IGC consults it when lowering is
;;;; unverified.  The realistic bad outcome is not a compile error: it is that this compiles
;;;; cleanly, emits valid SPIR-V, and changes nothing.  A FLAT T_loads is therefore a real
;;;; result (IGC ignored it), and the fallback is the peer's builtin family.
;;;;
;;;; GATED BY ENVIRONMENT, following the CRISP_TILE_VISIT precedent, so this is inert unless
;;;; asked for and no shipped kernel changes behaviour:
;;;;
;;;;     CRISP_CACHE_CONTROL=l1c_l3c    both levels Cached      (the peer's choice)
;;;;     CRISP_CACHE_CONTROL=l1s_l3c    L1 Streaming, L3 Cached
;;;;     CRISP_CACHE_CONTROL=l1uc_l3c   L1 Uncached,  L3 Cached
;;;;     CRISP_CACHE_CONTROL=l1c_l3uc   L1 Cached,    L3 Uncached
;;;;   (unset)                          no decoration -- current behaviour
;;;;
;;;; Names mirror SYCL-TLA's CacheControl enum so the mapping stays legible.  Load cache-control
;;;; values are 0 Uncached / 1 Cached / 2 Streaming / 3 InvalidateAfterRead / 4 ConstCached;
;;;; cache LEVEL 0 is nearest the EU, 1 is the next one out, and a level the part does not have
;;;; is ignored by spec.
;;;; ============================================================================

;; src/codegen.lisp
(defun %cache-control-spec ()
  "Parse CRISP_CACHE_CONTROL into a list of (CACHE-LEVEL . LOAD-CACHE-CONTROL) pairs for
   CacheControlLoadINTEL, or NIL when unset/unrecognised (meaning: emit no decoration, which
   is Crisp's historical behaviour of letting the driver choose)."
  (let ((v (uiop:getenv "CRISP_CACHE_CONTROL")))
    (when (and v (plusp (length v)))
      (let ((k (string-downcase (string-trim " " v))))
        (cond ((string= k "l1c_l3c")   '((0 . 1) (1 . 1)))
              ((string= k "l1s_l3c")   '((0 . 2) (1 . 1)))
              ((string= k "l1uc_l3c")  '((0 . 0) (1 . 1)))
              ((string= k "l1c_l3uc")  '((0 . 1) (1 . 0)))
              (t (log:warn "CRISP_CACHE_CONTROL=~a not recognised; emitting no cache-control ~
                            decoration.  Known: l1c_l3c l1s_l3c l1uc_l3c l1c_l3uc" v)
                 nil))))))

;; src/codegen.lisp
(defun %attach-cache-control-load (ptr module)
  "Decorate PTR with CacheControlLoadINTEL for each (level . control) in %CACHE-CONTROL-SPEC.

   Emits, in LLVM IR terms, `!spirv.Decorations !{!{i32 6442, i32 LEVEL, i32 CONTROL}, ...}`
   on the pointer-producing instruction; SPIRV-LLVM-Translator turns each inner node into an
   OpDecorate CacheControlLoadINTEL.  6442 is the decoration's SPIR-V token.

   GUARDED WITH LLVMIsAInstruction for the BUG 033 reason: LLVM's IRBuilder constant-folds, so
   a `ptr` that came out of folding may be a Constant rather than an Instruction, and
   LLVMSetMetadata is an unchecked unwrap<Instruction> that would corrupt or crash rather than
   report.  A non-instruction pointer is simply left undecorated.

   Returns PTR either way so it can be used inline."
  (let ((spec (%cache-control-spec)))
    (when (and spec ptr (not (cffi:null-pointer-p ptr))
               (not (cffi:null-pointer-p (crisp.llvm-bindings::llvm-is-a-instruction ptr))))
      (let* ((ctx  (crisp.llvm-bindings::llvm-get-module-context module))
             (i32  (crisp.llvm-bindings::llvm-int32-type))
             (kind "spirv.Decorations")
             (kind-id (crisp.llvm-bindings::llvm-get-md-kind-id-in-context
                       ctx kind (length kind)))
             (inner
               (mapcar
                (lambda (pair)
                  (cffi:with-foreign-object (ops :pointer 3)
                    (loop for w in (list 6442 (car pair) (cdr pair))
                          for i from 0
                          do (setf (cffi:mem-aref ops :pointer i)
                                   (crisp.llvm-bindings::llvm-value-as-metadata
                                    (crisp.llvm-bindings::llvm-const-int i32 w nil))))
                    (crisp.llvm-bindings::llvm-md-node-in-context2 ctx ops 3)))
                spec)))
        (cffi:with-foreign-object (outer :pointer (length inner))
          (loop for md in inner for i from 0
                do (setf (cffi:mem-aref outer :pointer i) md))
          (let ((node (crisp.llvm-bindings::llvm-md-node-in-context2
                       ctx outer (length inner))))
            (crisp.llvm-bindings::llvm-set-metadata
             ptr kind-id (crisp.llvm-bindings::llvm-metadata-as-value ctx node))
            (log:debug "cache-control: decorated coop load pointer with ~a (~{~a~^ ~})"
                       (uiop:getenv "CRISP_CACHE_CONTROL")
                       (mapcar (lambda (p) (format nil "L~d=~d" (car p) (cdr p))) spec))))))
    ptr))

;; src/codegen.lisp  (REPLACES the :coop-matrix method of %coop-load-impl -- adds the
;; cache-control decoration on the folded pointer; behaviour is IDENTICAL when
;; CRISP_CACHE_CONTROL is unset, which is how every shipped kernel builds.)
(defmethod %coop-load-impl ((lowering (eql :coop-matrix)) builder module tensor-val orow ocol elem-llvm rows cols use layout)
  (declare (ignorable lowering))
  "Fold the origin into a pointer, optionally decorate it with CacheControlLoadINTEL, then
   CooperativeMatrixLoadKHR."
  (multiple-value-bind (ptr stride-val)
      (%coop-tensor-ptr+stride builder tensor-val orow ocol layout elem-llvm)
    (%attach-cache-control-load ptr module)
    (let ((i32 (crisp.llvm-bindings::llvm-int32-type))
          (i64 (crisp.llvm-bindings::llvm-int64-type))
          (as  (%ptr-as ptr)))
      (%coop-call builder module
                  (format nil "__spirv_CooperativeMatrixLoadKHR_~d_~d_~d_as~d" use rows cols as)
                  (%coop-type elem-llvm rows cols use)
                  (list (%coop-ptr-type as) i32 i64 i32)
                  (list ptr
                        (crisp.llvm-bindings::llvm-const-int i32 layout nil)
                        stride-val
                        (crisp.llvm-bindings::llvm-const-int i32 0 nil))))))



;;;; ----------------------------------------------------------------------------
;;;; ARM A, PART 2 -- re-attach the decorations AFTER -O3.
;;;;
;;;; MEASURED: codegen attaches !spirv.Decorations to 64 GEPs correctly, and the opt pipeline
;;;; strips every one of them (64 -> 0 between .temp.ll and .opt.ll).  LLVM has no idea
;;;; !spirv.Decorations is semantic -- it is not in the set of metadata preserved across
;;;; transforms -- so folding, CSE and reassociation of the address arithmetic drop it.
;;;; Attaching before -O3 therefore cannot work, no matter how correct the attachment is.
;;;;
;;;; So we re-attach after opt, as a text pass over the .ll.  That is the same class of thing
;;;; inject-spir-kernel-metadata already is, and it has the advantage of running on the FINAL
;;;; address arithmetic rather than the pre-optimisation form.  Post-opt there are exactly 16
;;;; distinct pointer operands feeding CooperativeMatrixLoadKHR in the probe kernel, and every
;;;; one is a getelementptr, so this is a small well-defined rewrite, not a general IR edit.
;;;;
;;;; Load pointers ONLY.  Store pointers share the %coop_elem_ptr naming, and a *load*
;;;; cache-control decoration on a store pointer would be at best ignored and at worst
;;;; misleading, so the operand set is taken from the CALL SITES, never from the names.
;;;; ----------------------------------------------------------------------------

;; src/compiler.lisp
(defun %inject-cache-control-decorations (ll-path)
  "Re-attach CacheControlLoadINTEL !spirv.Decorations to the pointer operands of every
   __spirv_CooperativeMatrixLoadKHR call in the post-opt LLVM IR at LL-PATH, in place.

   No-op when CRISP_CACHE_CONTROL is unset.  Returns the number of pointer definitions
   decorated, so the caller can log it and a zero can be NOTICED rather than assumed away."
  (let ((spec (%cache-control-spec))
        (only (uiop:getenv "CRISP_CACHE_CONTROL_KERNELS")))
    ;; Optional per-kernel filter, so a decorated and an undecorated arm can be measured in the
    ;; SAME container session -- which is the rule that platform drift keeps punishing us for
    ;; breaking.  Unset means "every kernel", matching CRISP_TILE_VISIT's behaviour.
    (when (and spec only (plusp (length only)))
      (let* ((fn   (file-namestring ll-path))
             (base (subseq fn 0 (or (position #\. fn) (length fn)))))
        ;; EXACT stem match, not a substring test: "probe_loads" is a prefix of
        ;; "probe_loads_cc", so a substring test would decorate both arms and silently
        ;; destroy the comparison this filter exists to make.
        (unless (member base (uiop:split-string only :separator ",") :test (function string=))
          (setf spec nil))))
    (when spec
      (let ((lines '()))
        (with-open-file (in ll-path :direction :input)
          (loop for l = (read-line in nil nil) while l do (push l lines)))
        (setf lines (coerce (nreverse lines) 'vector))
        (let ((wanted (make-hash-table :test #'equal))
              (max-md 0))
          ;; Pass 1 -- pointer operands of coop-matrix LOADS, taken from the call sites.
          (loop for l across lines do
            (when (search "@__spirv_CooperativeMatrixLoadKHR" l)
              (let ((p (search "(ptr addrspace(" l)))
                (when p
                  (let ((pc (position #\% l :start p)))
                    (when pc
                      (let ((end (position-if (lambda (c) (member c (list #\, #\Space #\))))
                                              l :start pc)))
                        (setf (gethash (subseq l pc (or end (length l))) wanted) t)))))))
            (cl-ppcre:register-groups-bind ((#'parse-integer n))
                ("^!(\\d+) = " l)
              (when (> n max-md) (setf max-md n))))
          ;; Pass 2 -- append the attachment to each pointer's DEFINING instruction.
          (let* ((deco-id (1+ max-md))
                 (ids (loop for i from (+ deco-id 1) repeat (length spec) collect i))
                 (n 0))
            (loop for i from 0 below (length lines)
                  for l = (aref lines i) do
              (let ((trimmed (string-left-trim " " l)))
                (when (and (plusp (length trimmed)) (char= (aref trimmed 0) #\%)
                           (not (search "!spirv.Decorations" l)))
                  (let ((eq-pos (search " = " trimmed)))
                    (when (and eq-pos (gethash (subseq trimmed 0 eq-pos) wanted))
                      (setf (aref lines i)
                            (format nil "~a, !spirv.Decorations !~d" l deco-id))
                      (incf n))))))
            ;; Pass 3 -- the metadata definitions themselves.
            (with-open-file (out ll-path :direction :output :if-exists :supersede)
              (loop for l across lines do (write-line l out))
              (format out "!~d = !{~{!~d~^, ~}}~%" deco-id ids)
              (loop for pair in spec for id in ids
                    do (format out "!~d = !{i32 6442, i32 ~d, i32 ~d}~%"
                               id (car pair) (cdr pair))))
            (log:info "cache-control: re-attached ~d CacheControlLoadINTEL decoration sites after -O3 (~a)"
                      n (uiop:getenv "CRISP_CACHE_CONTROL"))
            (when (zerop n)
              (log:warn "cache-control: CRISP_CACHE_CONTROL is set but NO coop-matrix load pointer was decorated -- the arm is INERT; do not read its timing as a result about cache control."))
            n))))))

;; src/compiler.lisp  (REPLACES compile-to-spirv again -- adds the post-opt injection call.
;; This is the LAST definition in the file and therefore the live one; the earlier copy above
;; is dead.  See the file header: a definition that replaces another must not leave both live.)
(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as -> llvm-spirv."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (bc-file     (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))
    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")
    (when (or (%module-uses-native-builtin-p module)
              (%module-uses-async-copy-builtin-p module))
      (%emit-opencl-version-metadata module))
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))
      ;; ARM A: -O3 has just discarded the decorations codegen attached, so put them back on
      ;; the FINAL address arithmetic.  Inert unless CRISP_CACHE_CONTROL is set.
      (%inject-cache-control-decorations llvm-as-input)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags (append '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                              (when (%module-uses-coop-matrix-p module)
                                '("--spirv-ext=+SPV_KHR_cooperative_matrix"))
                              (when (%module-uses-2d-block-io-p module)
                                '("--spirv-ext=+SPV_INTEL_2d_block_io"))
                              (when (%module-uses-subgroup-mma-p module)
                                '("--spirv-ext=+SPV_INTEL_subgroup_matrix_multiply_accumulate"))
                              (when (%module-uses-split-barrier-p module)
                                '("--spirv-ext=+SPV_INTEL_split_barrier"))
                              (when (%module-uses-bfloat-p module)
                                '("--spirv-ext=+SPV_KHR_bfloat16"))
                              (when (and (%cache-control-spec)
                                         (%module-uses-coop-matrix-p module))
                                '("--spirv-ext=+SPV_INTEL_cache_controls"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))
