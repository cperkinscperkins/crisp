;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;; ---------------------------------------------------------------------------
;;;; Empty by design.  Endeavour 152's contents were migrated into src/ on 2026-08-19;
;;;; endeavour 154's on 2026-08-22.
;;;;
;;;; 154 migrated SIX definitions into src/mma.lisp, all of them plain defuns (no defvars, no
;;;; macros, no structs), so unlike 152 this fold needed no insert-after-in-package care:
;;;;
;;;;   %emit-wgmma-mma-only        NEW    — beside %emit-nvvm-wgmma
;;;;   %emit-nvvm-wgmma            REPLACED — one fence / N mma_async / one commit / one wait
;;;;   %wgmma-store-rewrite-origin NEW    — absolute (ROW COL) origin + row-major emission
;;;;   %wgmma-store-rewrite        REPLACED — now a thin caller of -origin (behaviour unchanged)
;;;;   analyze-store-tile-at-mma   NEW    — placed BEFORE register-mma-analyzers, which #'-refs it
;;;;   register-mma-analyzers      REPLACED — STORE-TILE-AT added to the dispatch table
;;;;
;;;; Verified behaviour-preserving by md5 of the emitted PTX for four kernels plus spec 03,
;;;; before and after the fold — see tests/spec/154-nvidia-perf/nvidia-perf.md, Phase 11.
;;;;
;;;; The two spec validators that came with 154 live in overlays/spec-runner-overlay.lisp and
;;;; were NOT folded: run-specs.lisp calls (main) on its last line, so anything appended after
;;;; it is defined too late to be found.  They belong in that overlay or ahead of the (main)
;;;; call, not at end of file.
;;;;
;;;; INSTRUCTIONS (unchanged):
;;;; 1. Append new/fixed function definitions to the end of this file.
;;;; 2. Add a comment referencing the original file (e.g. ;; src/codegen.lisp)
;;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)


;;; ===================================================================
;;; ENDEAVOUR 155 — thread the ELEMENT TYPE through register tiles.
;;;
;;; THE DEFECT.  `analyze-make-register-tile` read the element type and then threw it away:
;;;
;;;     (elem (first args))
;;;     ...
;;;     (declare (ignore elem))          ; tf32/fp32 fixed for now
;;;
;;; so `(make-register-tile-ring bfloat16 (32 16) ...)` parsed and produced FLOAT32 fragments.
;;; Confirmed in the emitted SPIR-V for benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.spv:
;;; the module contains exactly ONE float type -- `TypeFloat 259 32` -- and all three
;;; `TypeCooperativeMatrixKHR` name it as their component type.  There is no 16-bit type of any
;;; kind.  `bfloat16` survived only in parameter NAMES, inherited from the def-type.
;;;
;;; So the tensors were bf16 in memory while the matrices consuming them were fp32.  That is a
;;; CORRECTNESS bug, and it explains the seven empty `sec2_top_bf16_Crisp_*.json` result files
;;; far better than the register-pressure warning that was the first suspect.
;;;
;;; NOT DONE HERE, DELIBERATELY: the GRF byte width.  `%spv-kernel-register-demand` multiplies
;;; the element count by a hardcoded 4, and an earlier plan proposed patching that to 2 for bf16.
;;; That would have been wrong while the compiler still EMITTED float32 -- a register model
;;; precisely wrong about real code is worse than one obviously broken, because it stops warning
;;; about a kernel that genuinely will spill.  With the element type threaded, the width becomes
;;; a property of the type; that follows as step 2 and is handled below.
;;;
;;; NOTE FOR THE SRC PATCH: %elem-coop-type and %elem-bytes are new (src/mma.lisp);
;;; analyze-make-register-fragment REPLACES src/mma.lisp:318; %spv-note-register-fragment
;;; REPLACES :1204; %spv-kernel-register-demand REPLACES :1232; %explode-register-tiles
;;; REPLACES :1424.
;;; ===================================================================

;; src/mma.lisp
(defun %elem-coop-type (elem)
  "The SPIR-V cooperative-matrix component type for a Crisp element type.

   Returns the Crisp type symbol to embed in a `(coop-matrix <T> rows cols use)` semantic type.
   Anything unrecognised falls back to FLOAT — the pre-155 behaviour — so an element type this
   function has not been taught about degrades to what the compiler did before rather than
   erroring in a code path that has nothing to do with the user's mistake.  Shape/type agreement
   is validated separately (see the typed :mma-shapes work); this is a lowering detail."
  (case elem
    ((bfloat16) 'bfloat16)
    ((half)     'half)
    ((float)    'float)
    ((double)   'double)
    (t          'float)))

;; src/mma.lisp
(defun %elem-bytes (elem)
  "Bytes per element for a Crisp element type, for the Intel GRF register model.

   This is the number that used to be a hardcoded 4 in %spv-kernel-register-demand.  It is only
   correct to consult it now that the element type actually reaches codegen -- before endeavour
   155 every fragment was float32 regardless of what the source asked for, so 4 was the truth
   about the emitted code even when it was a lie about the source."
  (case elem
    ((bfloat16 half) 2)
    ((float)         4)
    ((double)        8)
    (t               4)))

;; src/mma.lisp
(defun %spv-note-register-fragment (rows cols context location &optional (elem 'float))
  "Endeavor 144 Phase 4: record one register FRAGMENT's BYTE demand against the kernel being
   compiled, for the Intel GRF model.  No-op off the SPV backend or without a current function.
   Assigned per (kernel . location) so re-analysis is idempotent.

   Endeavour 155: stores BYTES rather than elements, because element count alone cannot answer
   the question the model asks once tiles are no longer all float32.  ELEM defaults to FLOAT so
   any caller not yet passing a type keeps its previous accounting exactly.

   Only ALLOCATIONS reach here — see the :tally nil guard in analyze-make-register-fragment
   for why re-initializing an existing fragment must not be counted."
  (when (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when fn
        (setf (gethash (cons fn location) *spv-register-demand*)
              (* rows cols (%elem-bytes elem)))))))

;; src/mma.lisp
(defun %spv-kernel-register-demand (kernel-name)
  "Endeavor 144 Phase 4: (values GRF-REGISTERS BYTES) demanded per thread by KERNEL-NAME's
   register tiles / rings, or (values 0 0) if it has none.

   Endeavour 155: the tally now holds BYTES (see %spv-note-register-fragment), so the element
   width is a property of each fragment's type rather than a constant 4 applied to everything.
   The second value changed meaning from ELEMENTS to BYTES; %spv-decide-register-mode's warning
   was updated to match."
  (let ((bytes 0))
    (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf bytes v)))
             *spv-register-demand*)
    (values (ceiling bytes *spv-grf-register-bytes*) bytes)))


;; src/mma.lisp
(defun analyze-make-register-tile (expr env context location)
  "P3a: (make-register-tile T (M N) INIT &key warps) -> a record-of-fragments accumulator tile,
   each fragment initialized to INIT.  Mints the tile type on demand; rewrites to
   %construct-struct of make-register-fragment fields.
   Endeavor 139 (decision A): :warps is a flat topology mask of which warps hold the tile.  For a
   single participating warp (or no mask) the tile is the full (M/16)x(N/8) fragment set on that
   warp — the current build.  Distributing across >= 2 participating warps (the occupancy lever)
   is sub-step 2."
  (let* ((args     (cdr expr))
         (elem     (first args))
         (dims     (second args))
         (init     (third args))
         (kwargs   (nthcdr 3 args))
         (warps-in (getf kwargs :warps)))
    (destructuring-bind (m n) dims
      (let* ((tile-name (%ensure-register-tile-type m n))
             (nfrags    (* (floor m 16) (floor n 8))))
        (when warps-in
          ;; This (%construct-struct, non-exploded) path is only reached for a make-register-tile
          ;; NOT bound in a let — a let binding is EXPLODED, and %explode-register-tiles does the
          ;; distribution.  Validate here; distribution needs the explosion, so >=2 warps errors.
          (let* ((mask   (%normalize-warp-mask (%warp-mask-unquote warps-in) location))
                 (n-true (%validate-warp-mask mask nfrags (%resolve-workgroup-warp-count context) m n location)))
            (when (> n-true 1)
              (error 'crisp-compiler-error
                :message "make-register-tile with :warps distributing across >= 2 warps must be a let binding (so the compiler can split the fragments)."
                :source-location location))))
        (analyze-expression
         `(%construct-struct ,tile-name
                             ,@(loop repeat nfrags collect `(make-register-fragment 16 8 ,init :elem ,elem)))
         env context location)))))



;; src/mma.lisp
(defun %spv-decide-register-mode (kernel-name profile)
  "Endeavor 144 Phase 4: pick the per-thread register allocation for KERNEL-NAME from the
   profile's selectable :max-registers-per-thread modes, and record it in
   *kernel-register-mode* for the metacrisp.

   Three outcomes:
     demand <= default mode       -> default; silent (nothing to trade).
     default < demand <= a larger -> select the SMALLEST mode that fits, and say so.
                                     This is the case that was silently costing 1.5-2x
                                     on BMG: IGC spilled rather than being asked for the
                                     larger allocation.
     demand > every mode          -> WARN; it will spill whatever we choose.
   Returns the chosen mode, or NIL when there is nothing to decide."
  (let ((modes (%hp-register-modes profile)))
    (when modes
      (multiple-value-bind (demand bytes) (%spv-kernel-register-demand kernel-name)
        (when (plusp demand)
          (let* ((default-mode (first modes))
                 (fitting      (find-if (lambda (mode) (<= demand mode)) modes))
                 (chosen       (or fitting (reduce #'max modes))))
            (setf (gethash kernel-name *kernel-register-mode*) chosen)
            (cond
              ((null fitting)
               (format *error-output*
                       "WARNING: kernel ~a needs ~a registers/thread (~a register-tile bytes / ~a B per GRF register), exceeding every selectable allocation ~a in the hardware profile — it will SPILL in any mode.  Reduce the register-tile shape, the ring depth, or distribute the tile across more warps (:warps).~%"
                       kernel-name demand bytes *spv-grf-register-bytes* modes))
              ((> demand default-mode)
               (format *error-output*
                       "NOTE: kernel ~a needs ~a registers/thread, above the default allocation of ~a — selecting the ~a-register mode.  (Larger allocations trade threads-per-EU for registers; without this the JIT would spill instead.)~%"
                       kernel-name demand default-mode chosen)))
            chosen))))))


;; src/mma.lisp
(defun %coop-elem-of (tensor-node)
  "The coop-matrix COMPONENT TYPE for an operand, derived from its tensor type's element type
   (NOT hardcoded).  Mirrors %coop-layout-of, which derives the MemoryLayout the same way and
   for the same reason: at a load site the operand is usually a kernel parameter carrying a
   MANGLED type symbol, which only %TS-CANONICALIZE-TENSOR-TYPE can expand.

   Endeavour 155.  load-fragment-a / -b previously built `(coop-matrix float ...)` outright, so
   a bf16 operand was loaded as float32 -- the emitted SPIR-V for the bf16 benchmark kernel
   contained exactly one float type (32-bit) and no 16-bit type at all.

   Unresolvable types keep FLOAT, the historical behaviour.  ACCUMULATORS ARE DELIBERATELY NOT
   ROUTED THROUGH HERE: XMX/DPAS and the NVIDIA tensor cores take bf16 operands and accumulate in
   fp32, so an f32 accumulator paired with bf16 operands is correct, not an oversight."
  (let* ((canon (%ts-canonicalize-tensor-type (get-single-value-type tensor-node)))
         (elem  (and (consp canon) (>= (length canon) 2) (second canon))))
    (if (and elem (symbolp elem)) elem 'float)))

;; src/compiler.lisp  (REPLACES the one at src/compiler.lisp:605)
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
                              ;; 155: a bf16 register tile lowers to a `bfloat` coop matrix,
                              ;; which llvm-spirv refuses without this extension.
                              (when (%module-uses-bfloat-p module)
                                '("--spirv-ext=+SPV_KHR_bfloat16"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))

;; tests/run-specs.lisp
(defun %spv-float-ids (txt width)
  "Result-ids of every `TypeFloat <id> <width>` in a disassembled SPIR-V module, as strings."
  (cl:let ((ids cl:nil) (pos 0))
    (cl:loop
      (cl:let ((i (cl:search "TypeFloat " txt :start2 pos)))
        (cl:unless i (cl:return-from %spv-float-ids (cl:nreverse ids)))
        (cl:let* ((rest (cl:subseq txt (cl:+ i 10) (cl:min (cl:length txt) (cl:+ i 40))))
                  (toks (%spv-tokens rest)))
          (cl:when (cl:and (cl:>= (cl:length toks) 2)
                           (cl:equal (cl:second toks) (cl:princ-to-string width)))
            (cl:push (cl:first toks) ids)))
        (cl:setf pos (cl:1+ i))))))

;; tests/run-specs.lisp
(defun %spv-tokens (s)
  "Whitespace-split S into a list of strings."
  (cl:let ((out cl:nil) (cur (cl:make-string-output-stream)))
    (cl:loop for ch across s do
      (cl:if (cl:member ch (cl:list #\Space #\Tab #\Newline #\Return))
          (cl:let ((tok (cl:get-output-stream-string cur)))
            (cl:when (cl:plusp (cl:length tok)) (cl:push tok out)))
          (cl:write-char ch cur)))
    (cl:let ((tok (cl:get-output-stream-string cur)))
      (cl:when (cl:plusp (cl:length tok)) (cl:push tok out)))
    (cl:nreverse out)))

;; tests/run-specs.lisp
(defun %spv-coop-uses-p (txt type-id)
  "T if any TypeCooperativeMatrixKHR in TXT names TYPE-ID as its COMPONENT TYPE (the token
   immediately after the matrix's own result id)."
  (cl:let ((pos 0))
    (cl:loop
      (cl:let ((i (cl:search "TypeCooperativeMatrixKHR " txt :start2 pos)))
        (cl:unless i (cl:return-from %spv-coop-uses-p cl:nil))
        (cl:let* ((rest (cl:subseq txt (cl:+ i 25) (cl:min (cl:length txt) (cl:+ i 80))))
                  (toks (%spv-tokens rest)))
          (cl:when (cl:and (cl:>= (cl:length toks) 2) (cl:equal (cl:second toks) type-id))
            (cl:return-from %spv-coop-uses-p cl:t)))
        (cl:setf pos (cl:1+ i))))))


;;;; ============================================================================
;;;; Endeavour 155 Phase A — a coop-matrix element-type validator that is actually strong enough.
;;;;
;;;; WHY THE FIRST ONE WAS NOT.  validate-spv-bf16-coop asserted "a 16-bit float type exists, SOME
;;;; cooperative matrix uses it, and an f32 type also exists".  Every one of those is true of a
;;;; module in which MOST A/B operands are still float32 — which is exactly the module Crisp emits
;;;; today.  The validator was built to catch "the element type was discarded" and cannot see "the
;;;; element type was discarded ON SOME PATHS", which is the bug that was really there.
;;;;
;;;; THE ASSERTION THAT ACTUALLY PINS IT.  In SPIR-V a cooperative matrix declares its role:
;;;;
;;;;     7 TypeCooperativeMatrixKHR <result> <component> <scope> <rows> <cols> <use>
;;;;
;;;; where <use> is an ID naming an integer constant: 0 = A, 1 = B, 2 = Accumulator.  So the
;;;; module states, per matrix, both what it is FOR and what it is MADE OF.  The real invariant of
;;;; a mixed-precision MMA is therefore checkable exactly:
;;;;
;;;;     every A-use and B-use matrix has the DECLARED ELEMENT width
;;;;     every Accumulator-use matrix is fp32
;;;;
;;;; and a stray f32 A-operand — the actual defect — fails it.  Observed on probe_half.spv:
;;;;     360 comp=f32 use=A   <-- caught      363 comp=f16 use=A   ok
;;;;     372 comp=f32 use=B   <-- caught      374 comp=f16 use=B   ok
;;;;                                          383 comp=f32 use=Acc ok
;;;; ============================================================================

;; tests/run-specs.lisp
(defun %spv-lines (txt)
  "TXT split into lines, each tokenised.  The disassembled SPIR-V text form is one instruction per
   line, `<word-count> <Opcode> <operands...>`, so token 1 is the opcode and token 2 is normally
   the result id.  Parsing by line rather than by substring search matters: a bare (search
   \"Constant \" ...) also matches SpecConstant, ConstantComposite and ConstantNull."
  (cl:let ((out cl:nil) (start 0) (len (cl:length txt)))
    (cl:loop
      (cl:let ((nl (cl:position #\Newline txt :start start)))
        (cl:let ((line (cl:subseq txt start (cl:or nl len))))
          (cl:let ((toks (%spv-tokens line)))
            (cl:when (cl:>= (cl:length toks) 2) (cl:push toks out))))
        (cl:if nl (cl:setf start (cl:1+ nl)) (cl:return-from %spv-lines (cl:nreverse out)))))))

;; tests/run-specs.lisp
(defun %spv-int-constants (txt)
  "Alist of (result-id-string . integer-value) for every scalar OpConstant in TXT.

   Needed because a cooperative matrix's Use operand is not a literal — it is an ID pointing at a
   constant, so `use 130` means nothing until 130 is resolved to 0 / 1 / 2."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "Constant")
                       (cl:>= (cl:length toks) 5))
        (cl:let ((v (cl:ignore-errors (cl:parse-integer (cl:fifth toks)))))
          (cl:when v (cl:push (cl:cons (cl:fourth toks) v) out)))))))

;; tests/run-specs.lisp
(defun %spv-float-widths (txt)
  "Alist of (type-id-string . width) for every OpTypeFloat in TXT."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeFloat")
                       (cl:>= (cl:length toks) 4))
        (cl:let ((w (cl:ignore-errors (cl:parse-integer (cl:fourth toks)))))
          (cl:when w (cl:push (cl:cons (cl:third toks) w) out)))))))

;; tests/run-specs.lisp
(defun %spv-use-name (use)
  "Human name for a cooperative-matrix Use operand value."
  (cl:case use (0 "A") (1 "B") (2 "Accumulator") (cl:t (cl:format cl:nil "use=~a" use))))

;; tests/run-specs.lisp
(defun validate-spv-fp16-coop (spv-path)
  "Endeavour 155 — assert an fp16 (`half`) register tile reached the hardware AS fp16, on EVERY
   operand, with an fp32 accumulator.

   WHY fp16 CARRIES THE 16-BIT COVERAGE AND bf16 CANNOT.  bf16 cannot be loaded on the BMG driver
   at all (see validate-spv-bf16-coop), so a bf16 rung can never be taken to metal here.  fp16
   goes through the IDENTICAL typed path — same register tiles, same (8 16 16) shape, same DPAS
   rate — and DOES load and run.  So fp16 is what makes 16-bit MMA testable end to end on Intel,
   and bf16 rungs stay compile-and-inspect until the driver catches up.

   No extension is required: fp16 is core SPIR-V."
  (%validate-coop-operand-elem spv-path 16 "half/fp16"))


;;;; ============================================================================
;;;; Endeavour 155 Phase B — the element type reaches CODEGEN, not just the analyzer.
;;;;
;;;; THE DEFECT.  Phase 1 threaded the element type through the ANALYZER, so a semantic coop-op
;;;; node carries `(coop-matrix half 8 8 0)`.  Codegen then ignored it and passed a literal F32:
;;;;
;;;;     (:fill (values (%coop-fill builder module (gen ...) f32 rows cols use) nil))
;;;;     (:load          (%coop-load builder module ptr stride f32 rows cols use layout))
;;;;
;;;; so the emitted module was INTERNALLY INCONSISTENT — and silently so, because opaque pointers
;;;; mean LLVM never objects:
;;;;
;;;;     %"a-tile$f0" = alloca target("spirv.CooperativeMatrixKHR", half,  3, 8, 8, 0)
;;;;     %27 = call   target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0) @__spirv_CompositeConstruct_0_8_8(float 0.0)
;;;;     store        target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0) %27, ptr %"a-tile$f0"
;;;;
;;;; An f32 cooperative matrix stored into an f16 slot and read back as f16 — a REINTERPRET, not a
;;;; conversion.  That is why the disassembly showed both widths for every operand and ZERO
;;;; FConvert ops, and why the fp16 matmul measured 0.27 TFLOPS against oneMKL's 110.
;;;;
;;;; Note which parts were already right, because it explains why the bug was so quiet: the ALLOCA
;;;; came from the fragment's semantic type (half, correct), and __spirv_CooperativeMatrixMulAddKHR
;;;; derives its signature from LLVMTypeOf of the actual values (half, correct — Phase 1's %coop-mma
;;;; fix).  Only the producers disagreed, so every individual piece looked defensible in isolation.
;;;;
;;;; The mangled names gave it away: `__spirv_CompositeConstruct_0_8_8` and
;;;; `__spirv_CooperativeMatrixLoadKHR_0_8_8_as1` encode use/rows/cols and NO element type, so one
;;;; name necessarily served every element type — the signature could not be anything but wrong for
;;;; all but one of them.  %coop-call interns by name, so the FIRST declaration wins and the rest
;;;; silently alias it.  The mangling is left alone here (changing it is a wider change than the
;;;; failing rungs justify); what changes is that the type passed is now the matrix's own.
;;;;
;;;; THE MAP PATH IS REFUSED, NOT FIXED.  :map / :map2 extract scalar elements through f32 allocas
;;;; (cm_elem, cm_prm, cm_adj).  Making those width-correct is a real change to a path that no
;;;; failing rung exercises and that autodiff depends on, and this endeavour has already been
;;;; lengthened twice by fixing things it could not test.  A compile-time refusal that names the
;;;; limitation is the honest option — and it cannot regress anything today, since every kernel in
;;;; the tree that uses map is float.
;;;; ============================================================================

;; src/codegen.lisp
;; [superseded defun %coop-node-elem removed in consolidation -- a later copy in this file is the live one]




;; src/codegen.lisp
(defun %llvm-float-width (ty)
  "Bit width of an LLVM floating-point type, or NIL if TY is not one of the four Crisp knows.
   HALF and BFLOAT16 are both 16 bits and are DIFFERENT types — same width, not interchangeable."
  (cond ((cffi:pointer-eq ty (llvm-half-type))   16)
        ((cffi:pointer-eq ty (llvm-bfloat-type)) 16)
        ((cffi:pointer-eq ty (llvm-float-type))  32)
        ((cffi:pointer-eq ty (llvm-double-type)) 64)
        (t nil)))

;; src/codegen.lisp  (REPLACES %coop-fill)
(defun %coop-fill (builder module init-val elem-llvm rows cols use)
  "Construct a coop matrix filled with INIT-VAL (scalar) via __spirv_CompositeConstruct.

   Endeavour 155: INIT-VAL is coerced to ELEM-LLVM first.  Before the element type reached
   codegen this was vacuous — everything was f32, so the literal already matched.  Now that the
   matrix carries the tile's real element type, the literal has to follow it."
  (%coop-call builder module
              (format nil "__spirv_CompositeConstruct_~d_~d_~d" use rows cols)
              (%coop-type elem-llvm rows cols use)
              (list elem-llvm)
              (list (%coop-coerce-scalar builder init-val elem-llvm "coop_init"))))


;;;; ============================================================================
;;;; Endeavour 155 Phase C — THE SHAPE IS PART OF THE TYPE.
;;;;
;;;; This is the endeavour's actual subject, arrived at from the other end.  Phase B made every
;;;; cooperative matrix carry its real element type; the fp16 kernel then failed to LOAD, and the
;;;; driver said exactly why:
;;;;
;;;;     undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_PackedA_RowMajor_
;;;;                             SG16_8x8_i16_4_global_v8i8_pi32_i32'
;;;;
;;;; IGC lowers KHR cooperative-matrix loads to internal JointMatrix builtins, and there is no
;;;; `8x8_i16` builtin because 8x8 IS NOT A VALID 16-BIT DPAS SHAPE.  A was 8x8 and B was 8x16 --
;;;; the K=8 TF32 shapes, carrying 16-bit elements.
;;;;
;;;; WHY.  %spv-mma-shape returned (first shapes) from the profile's :mma-shapes, ignoring both the
;;;; element type AND the shape the kernel asked for.  The kernel says (mma-accumulate-via-tile
;;;; (8 16 16) ...) -- K=16, correct for fp16 -- and got K=8 fragments anyway.
;;;;
;;;; THE UNDERLYING RULE, which the profiles have documented in a comment all along:
;;;;
;;;;     :mma-shapes ((8 16 8) (8 16 16) (8 16 32))  ; XMX tf32, bf16/fp16, int8
;;;;
;;;; K scales INVERSELY with element width, because K x element-bits is a fixed fragment footprint
;;;; -- 256 bits on both shipped profiles:
;;;;     bmg   tf32 8x32=256   fp16 16x16=256   int8 32x8=256
;;;;     h100  tf32 8x32=256   fp16 16x16=256
;;;; So a shape list is only meaningful WITH a type, which is what "typed :mma-shapes" means.
;;;;
;;;; TWO WAYS TO SAY IT, AND BOTH ARE ACCEPTED.  The honest long-term form is for a profile to
;;;; declare the type outright:
;;;;     :mma-shapes ((float 8 16 8) (half 8 16 16) (int8 8 16 32))
;;;; That format is supported here and takes precedence.  Existing untyped 3-lists keep working and
;;;; are matched by the width rule above.  One selection function is the single place that knows
;;;; either encoding, so migrating profiles later is a data change, not a code change.
;;;;
;;;; FALLBACK IS THE OLD BEHAVIOUR, DELIBERATELY.  When no entry matches the element -- e.g. the
;;;; many specs carrying (def-hardware-profile bmg :mma-shapes ((8 16 8))) -- selection returns
;;;; (first shapes), exactly what it returned before.  Those specs are all float, so they are
;;;; unaffected; a 16-bit tile on such a profile still gets the wrong shape, but it now fails at
;;;; load with the driver's own diagnostic rather than silently computing nonsense.  Making that a
;;;; compile-time refusal wants its own rung.
;;;; ============================================================================

;; src/mma.lisp
(defun %mma-elem-bits (elem)
  "Bit width of a Crisp MMA element type, or NIL if unknown."
  (and elem (symbolp elem)
       (let ((n (symbol-name elem)))
         (cond ((string= n "HALF")     16)
               ((string= n "BFLOAT16") 16)
               ((string= n "FLOAT")    32)
               ((string= n "DOUBLE")   64)
               ((string= n "INT8")      8)
               ((string= n "UINT8")     8)
               (t nil)))))

;; src/mma.lisp
(defun %mma-shape-entry-dims (entry)
  "The (M N K) triple of an :mma-shapes ENTRY, whether it is an untyped 3-list (8 16 8) or a
   TYPED 4-list (half 8 16 16)."
  (cond ((and (listp entry) (= (length entry) 3)) entry)
        ((and (listp entry) (= (length entry) 4)) (cdr entry))
        (t nil)))

;; src/mma.lisp
(defun %mma-shape-entry-type (entry)
  "The declared element type of a TYPED :mma-shapes entry, or NIL for an untyped 3-list."
  (and (listp entry) (= (length entry) 4) (symbolp (first entry)) (first entry)))

;; src/mma.lisp
(defun %mma-shape-for-elem (shapes elem)
  "The (M N K) entry of SHAPES appropriate to element type ELEM, or NIL if none is.

   A TYPED entry wins outright when its declared type matches.  Otherwise the width rule applies:
   K x element-bits is a constant fragment footprint, so the right entry is the one whose K equals
   that constant divided by the element width.  The constant is read off the profile's own float
   entry rather than hardcoded, so a part with a different footprint still resolves correctly."
  (let ((bits (%mma-elem-bits elem)))
    (when (and shapes bits)
      (or
       ;; 1. an explicitly typed entry for this element type
       (let ((hit (find-if (lambda (e)
                             (let ((ty (%mma-shape-entry-type e)))
                               (and ty (string= (symbol-name ty) (symbol-name elem)))))
                           shapes)))
         (and hit (%mma-shape-entry-dims hit)))
       ;; 2. the width rule, calibrated on this profile's own 32-bit entry
       (let* ((base (or (let ((typed-f (find-if (lambda (e)
                                                  (let ((ty (%mma-shape-entry-type e)))
                                                    (and ty (= (or (%mma-elem-bits ty) 0) 32))))
                                                shapes)))
                          (and typed-f (third (%mma-shape-entry-dims typed-f))))
                        (third (%mma-shape-entry-dims (first shapes)))))
              (footprint (and base (* base 32)))
              (want-k (and footprint (plusp bits) (/ footprint bits))))
         (when (and want-k (integerp want-k))
           (let ((hit (find-if (lambda (e)
                                 (let ((d (%mma-shape-entry-dims e)))
                                   (and d (null (%mma-shape-entry-type e)) (eql (third d) want-k))))
                               shapes)))
             (and hit (%mma-shape-entry-dims hit)))))))))

;; src/mma.lisp  (REPLACES %spv-mma-shape)
(defun %spv-mma-shape (&optional elem)
  "The (values M N K) cooperative-matrix INSTRUCTION shape for the SPV path.

   Endeavour 155: takes an optional ELEMENT TYPE and selects the profile shape that matches it.
   The element type is genuinely part of the choice -- an fp16 fragment is not a tf32 fragment with
   different contents, it is a different instruction shape (K=16 vs K=8) -- and picking (first
   shapes) regardless is what produced 16-bit matrices in tf32 shapes, which no DPAS implements.

   ELEM is optional so the ~18 existing call sites that do not know an element type keep their
   previous behaviour exactly; only the sites that mint or load a typed fragment pass it."
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if (null shapes)
        (values 16 8 8)
        (let ((dims (or (and elem (%mma-shape-for-elem shapes elem))
                        (%mma-shape-entry-dims (first shapes)))))
          (if (and dims (= (length dims) 3))
              (values-list dims)
              (values 16 8 8))))))

;; src/mma.lisp  (REPLACES %frag-mn-for-operand)
(defun %frag-mn-for-operand (operand &optional elem)
  "Endeavor 142 — per-fragment (rows . cols) for a register-tile of :operand (a|b|acc).  From the
   active profile's mma-shape (sm sn sk): A = sm×sk (Use 0), B = sk×sn (Use 1), Acc = sm×sn (Use 2)
   — matching load-fragment-a/b and make-register-fragment.  NVIDIA: 16x8 (A/B on PTX is rejected
   earlier for the block-load path).

   Endeavour 155: ELEM selects the shape, because K depends on the element width."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)
        (ecase operand
          (:a   (cons sm sk))
          (:b   (cons sk sn))
          (:acc (cons sm sn))))
      (cons 16 8)))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 2 — the call sites that KNOW the element type now pass it.
;;;;
;;;; %spv-mma-shape takes ELEM optionally, so the ~18 call sites that have no element type in hand
;;;; keep their exact previous behaviour.  These four are the ones that mint or load a typed
;;;; fragment, and they are the only ones whose answer was wrong:
;;;;
;;;;   analyze-make-register-fragment   the fill      -- :elem is already in its lambda list
;;;;   analyze-load-fragment-a / -b     the loads     -- element comes from the SOURCE TENSOR
;;;;   %explode-register-tiles          tile + ring   -- :elem from the tile constructor
;;;;
;;;; The two load analysers needed their nesting inverted: the shape was computed BEFORE the
;;;; tensor was analysed, so nothing yet knew what the shape was a shape of.  Analysing the tensor
;;;; first is the whole change; the body is otherwise untouched.
;;;; ------------------------------------------------------------------------------------------

;; src/mma.lisp  (REPLACES analyze-make-register-fragment -- 155 Phase C)
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand elem tally).  :spirv -> a filled coop
   matrix; else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default
   acc) picks the coop-matrix Use + shape so an A/B operand tile mints fragments matching
   load-fragment-a/b.

   Endeavor 144: each fragment is tallied against the current kernel — as coop-matrix BYTES on
   SPV (Phase 4's GRF model) and as 32-bit REGISTERS on PTX (Phase 3's occupancy model).  Both
   skip when the form carries :tally nil, which marks fill-tile's per-fragment set!s: those
   RE-INITIALIZE fragments the tile already owns and allocate nothing.

   Endeavour 155: :elem carries the ELEMENT TYPE down from the register tile that generated this
   fragment, and reaches the coop-matrix component type and the GRF byte tally.  It defaults to
   FLOAT — exactly what every caller got before, since the type used to be discarded at
   make-register-tile and bf16 tiles silently produced float32 matrices.  The PTX branch is
   UNCHANGED: its fragment records are tf32/f32 by construction and endeavour 155 does not touch
   the NVIDIA path."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (elem    (getf kwargs :elem 'float))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)   ; 155 Phase C
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))
              (when tally-p (%spv-note-register-fragment fr fc context location elem))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%elem-coop-type elem) fr fc use) :kind :fill
               :value-node (analyze-expression init env context (append location '(1)))
               :rows fr :cols fc :use use :layout 0 :source-location location)))
          (progn
            (unless (and (eql m 16) (eql n 8))
              (error 'crisp-compiler-error
                     :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
            ;; PTX fragment register counts, matching the records minted below:
            ;; acc 16x8 f32 -> 4, A tf32 16x8 -> 4, B tf32 8x8 -> 2 (per lane, 32-bit each).
            (when tally-p
              (%ptx-note-register-demand (ecase operand (:acc 4) (:a 4) (:b 2)) context location))
            (analyze-expression
             (ecase operand
               (:acc `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init))
               (:a   `(%construct-struct register-fragment-a-tf32-16x8 ,init ,init ,init ,init))
               (:b   `(%construct-struct register-fragment-b-tf32-8x8 ,init ,init)))
             env context location))))))

;; src/mma.lisp  (REPLACES analyze-load-fragment-a -- 155 Phase C)
(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; A = MxK; layout from the tensor's :contiguous-term.
          ;; 155 Phase C: the tensor is analysed FIRST, because its ELEMENT TYPE selects
          ;; the fragment shape -- K=8 for a 32-bit operand, K=16 for a 16-bit one.  The two
          ;; were previously nested the other way round, so the shape was fixed before anything
          ;; knew what it was a shape OF.
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sn))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sm sk 0) :kind :load
               :tensor-node tnode
               :rows sm :cols sk :use 0 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tk) env context (append location '(3)))
               :source-location location)))
          (analyze-expression
           `(let ((lane (to-int (warp-lane))))
              (let ((g (/ lane 4)) (tg (rem lane 4)))
                (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
                  (%construct-struct register-fragment-a-tf32-16x8
                    (~ ,src r c) (~ ,src (+ r 8) c) (~ ,src r (+ c 4)) (~ ,src (+ r 8) (+ c 4))))))
           env context location)))))

;; src/mma.lisp  (REPLACES analyze-load-fragment-b -- 155 Phase C)
(defun analyze-load-fragment-b (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,
   8x8, col-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; B = KxN; layout from the tensor's :contiguous-term.  NOTE: Intel has no
          ;; ColumnMajor-B coop builtin, so an Intel B operand must be declared :row-major
          ;; (NVIDIA's canonical row.col MMA wants B :col-major — a genuine per-vendor
          ;; storage difference, like the shape).
          ;; 155 Phase C: the tensor is analysed FIRST, because its ELEMENT TYPE selects
          ;; the fragment shape -- K=8 for a 32-bit operand, K=16 for a 16-bit one.  The two
          ;; were previously nested the other way round, so the shape was fixed before anything
          ;; knew what it was a shape OF.
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sm))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sk sn 1) :kind :load
               :tensor-node tnode
               :rows sk :cols sn :use 1 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,tk) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          (analyze-expression
           `(let ((lane (to-int (warp-lane))))
              (let ((g (/ lane 4)) (tg (rem lane 4)))
                (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                  (%construct-struct register-fragment-b-tf32-8x8
                    (~ ,src r c) (~ ,src (+ r 4) c)))))
           env context location)))))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 3 — the MMA WALKER and the TILES must agree on K.
;;;;
;;;; Phase C part 2 made register tiles mint fragments at the element type's native K (16 for
;;;; fp16).  The via-tile walker still derived K from (first :mma-shapes) -- TF32's K=8 -- so it
;;;; walked twice as many K-steps as the tile actually had fragments for, and the surplus index
;;;; resolved to NIL:
;;;;
;;;;     Crisp compilation failed ... Unknown variable NIL.
;;;;
;;;; The fix is not to re-derive it more cleverly but to STOP re-deriving it: the kernel already
;;;; wrote the shape, `(mma-accumulate-via-tile (8 16 16) C A B)`, and %check-mma-shape had already
;;;; validated it against the hardware profile.  %explode-rewrite-body-form had it bound as SHAPE
;;;; and used it only for that check.  Now it is passed down.
;;;;
;;;; NOTE that %frag-mn is deliberately left alone.  It supplies the ACCUMULATOR fragment's (M . N),
;;;; and M/N do not vary with element width on either shipped profile -- only K does.  Changing it
;;;; would be motion without a reason.
;;;; ------------------------------------------------------------------------------------------

;; src/mma.lisp  (REPLACES %emit-per-frag-accumulate -- 155 Phase C)
;; [superseded defun %emit-per-frag-accumulate removed in consolidation -- a later copy in this file is the live one]



;; src/mma.lisp  (REPLACES %explode-rewrite-body-form -- 155 Phase C)
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! / %map-elements-vjp! references to any exploded tile in TILES with
   per-fragment progns; otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body shape))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles nil nil shape))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "MAP-ELEMENTS!") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-map (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "%MAP-ELEMENTS-VJP!") (>= (length form) 4)
          (or (assoc (second form) tiles) (assoc (third form) tiles)))
     (%emit-map-vjp-explode form tiles))
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 4 — the LOAD-TILE expansion needs the element type too.
;;;;
;;;; %emit-per-frag-block-load explodes (load-tile SRC <register-tile> COORDS) into one
;;;; load-fragment-a/b per fragment, and sizes that expansion with %frag-mn-for-operand.  Passing
;;;; no element type there means an fp16 A-tile of (8 16) is walked at the TF32 K=8 -- two
;;;; fragments -- while Phase C part 2 minted it with exactly ONE K=16 fragment.  The second index
;;;; resolves to NIL, and the compiler reports:
;;;;
;;;;     Crisp compilation failed ... Unknown variable NIL.
;;;;
;;;; WHY NOT PUT THE ELEMENT TYPE IN THE TILE ENTRY.  That was the first instinct: the entry is
;;;; (NAME M N SYMS N-TRUE FIRST-TRUE OPERAND) and appending ELEM would be the obvious change.  But
;;;; several functions destructure that entry with fixed lambda lists, so an extra element makes
;;;; every one of them an error -- a wide, brittle change for a narrow need.
;;;;
;;;; This codebase already solved the identical problem once, in 145 P3a: *mma-scratch-tile-dims*
;;;; publishes the LET's staged-tile shapes so the accumulate expansion can see them, bound by
;;;; %explode-register-tiles and NIL elsewhere.  *REGISTER-TILE-ELEMS* is the same mechanism for
;;;; the same reason, which also means it degrades the same way: NIL outside an explosion, and a
;;;; tile that is not in the alist falls back to FLOAT -- the pre-155 behaviour.
;;;; ------------------------------------------------------------------------------------------

;; src/mma.lisp
(defvar *register-tile-elems* nil
  "Endeavour 155: alist (SYM . ELEM) of the ELEMENT TYPE of every register tile / tile-ring bound
   by the LET currently being exploded.  %emit-per-frag-block-load reads it so a load-tile
   expansion walks the operand at ITS element type's native K (8 for a 32-bit operand, 16 for a
   16-bit one) rather than at the profile's first shape.  Bound by %explode-register-tiles; NIL
   elsewhere, in which case FLOAT is assumed — exactly the pre-155 behaviour.")

;; src/mma.lisp
(defun %register-tile-elems-from-bindings (bindings)
  "Alist (SYM . ELEM) for every register-tile or register-tile-ring binding in BINDINGS.
   Both constructors put the element type in the same position: (make-register-tile* ELEM (M N) ...)."
  (let ((out '()))
    (dolist (b bindings (nreverse out))
      (when (and (consp b) (= (length b) 2) (symbolp (first b))
                 (consp (second b))
                 (or (%register-tile-init-form-p (second b))
                     (%register-tile-ring-init-form-p (second b))))
        (let ((elem (second (second b))))
          (when (symbolp elem)
            (push (cons (first b) elem) out)))))))

;; src/mma.lisp
(defun %register-tile-elem-of (name)
  "The element type recorded for register tile NAME, or FLOAT when unknown (pre-155 behaviour)."
  (or (cdr (assoc name *register-tile-elems*)) 'float))


;;;; ============================================================================
;;;; Endeavour 155 — THE TILE ADDRESS WAS COMPUTED IN THE WRONG ELEMENT SIZE.
;;;;
;;;; %coop-tensor-ptr+stride turns a Crisp tensor plus a tile origin into the pointer a
;;;; cooperative-matrix load/store starts from.  It computed a FLAT ELEMENT INDEX correctly and
;;;; then indexed it with a hardcoded f32:
;;;;
;;;;     %coop_elem_ptr = getelementptr float, ptr addrspace(1) %coop_base, i64 %coop_flat
;;;;
;;;; On a 16-bit tensor that scales the offset by 4 bytes instead of 2, so every tile after the
;;;; first lands at TWICE its intended element offset.  The STRIDE operand is separate and was
;;;; already right, which is why the first tile of every kernel read perfectly and nothing looked
;;;; wrong until a K-loop ran more than one step.
;;;;
;;;; HOW IT WAS FOUND, because the arithmetic is the proof.  Filling A and B with all ones makes
;;;; the result equal the NUMBER OF CONTRACTED TERMS, so a partial contraction is readable
;;;; directly.  For an 8xK operand the tile at step k should start at element 16k but starts at
;;;; 32k; a tile whose last element (base + 7*K + 15) exceeds the allocation reads past the buffer
;;;; and contributes nothing:
;;;;
;;;;     K=16   bases 0                    1 of 1 in bounds   ->  16    measured 16   (correct)
;;;;     K=32   bases 0,32                 1 of 2             ->  16    measured 16
;;;;     K=64   bases 0,32,64,96           2 of 4             ->  32    measured 32
;;;;     K=128  bases 0,32,...,224         4 of 8             ->  64    measured 64
;;;;
;;;; All four predicted values match what the GPU produced, which is what makes this the cause
;;;; rather than a candidate.  It also explains why K=16 passed: a single step never needs a
;;;; second base.
;;;;
;;;; WHY IT SURVIVED EVERY EXISTING TEST.  Every kernel in the tree until now was f32, and for f32
;;;; the hardcoded type is the RIGHT one — the bug is exactly zero-cost at 32 bits.  It could not
;;;; be found by any amount of f32 testing, only by running a 16-bit kernel on hardware.  That is
;;;; the argument for rung 04 (on-metal fp16) rather than more compile-and-inspect rungs: the
;;;; emitted TYPES were already correct here, and the types are all a .spv-reading validator can
;;;; see.
;;;; ============================================================================

;; src/codegen.lisp  (REPLACES %coop-tensor-ptr+stride -- 155)
;; [superseded defun %coop-tensor-ptr+stride removed in consolidation -- a later copy in this file is the live one]




;;;; ============================================================================
;;;; Endeavour 155 — the 2D-BLOCK PREFETCH also described every surface as f32.
;;;;
;;;; %block-prefetch emitted Subgroup2DBlockPrefetchINTEL with a hardcoded ElementSize of 4 bytes
;;;; and a MemoryPitch of leading-dim * 4.  On a 16-bit tensor both are double the truth, so the
;;;; region handed to the driver is twice as wide as the data and runs off the end of the
;;;; allocation.
;;;;
;;;; A PREFETCH IS SUPPOSED TO BE HARMLESS -- its own docstring calls it "a fire-and-forget L1
;;;; cache hint... never changes data".  That is true of a VALID prefetch.  An invalid one is a
;;;; memory access like any other, and the benchmark kernel (which prefetches; the simple kernel
;;;; does not) is precisely the one that took a CONSTANT 500 ms at every problem size from 256 to
;;;; 8192 and returned garbage -- the signature of a GPU fault and reset rather than of slow work.
;;;; The simple fp16 kernel, same MMA path but no prefetch, ran in 3.5 MICROSECONDS.
;;;;
;;;; So the element type had to reach one more place.  Counting the layers this endeavour has now
;;;; threaded it through: the analyzer (Phase 1), the coop-matrix TYPE in codegen (Phase B), the
;;;; instruction SHAPE (Phase C), the tile ADDRESS (the getelementptr), the PREFETCH surface, and
;;;; on the host side the fill and the reference.  Each was invisible to the layer above it.
;;;; ============================================================================

;; src/codegen.lisp
;; [superseded defun %elem-llvm-bytes removed in consolidation -- a later copy in this file is the live one]



;; src/codegen.lisp  (REPLACES %block-prefetch -- 155)
(defun %block-prefetch (builder module ptr stride-val rows cols &optional (elem-bytes 4))
  "Endeavor 142 (Phase B): emit Subgroup2DBlockPrefetchINTEL for an f32 ROWS x COLS block whose
   element origin is PTR (addrspace(1)), STRIDE-VAL the i64 leading dim in elements.  A fire-and-forget
   L1 cache hint — no result, never changes data (so it can be interleaved freely into the K-loop).
   ABI (verified against llvm-spirv --spirv-ext=+SPV_INTEL_2d_block_io -> OpSubgroup2DBlockPrefetchINTEL):
     void __spirv_Subgroup2DBlockPrefetchINTEL(i32 ElementSize, i32 BlockWidth, i32 BlockHeight,
       i32 BlockCount, ptr addrspace(N) SrcBase, i32 MemWidth, i32 MemHeight, i32 MemPitch, <2 x i32> Coord)
   The surface is described AS the block itself (origin PTR, MemW/H = block, Coord = <0,0>); the driver
   only needs a valid region to warm — the operand values are perf hints, not correctness."
  (let* ((i32   (crisp.llvm-bindings::llvm-int32-type))
         (i64   (crisp.llvm-bindings::llvm-int64-type))
         (as    (%ptr-as ptr))
         (v2i32 (crisp.llvm-bindings::llvm-vector-type i32 2))
         ;; MemoryPitch is in BYTES: leading-dim-elements * sizeof(element).
         ;; Endeavour 155: was sizeof(f32) unconditionally.  See header.
         (pitch-bytes (crisp.llvm-bindings::llvm-build-trunc
                       builder
                       (crisp.llvm-bindings::llvm-build-mul
                        builder stride-val (crisp.llvm-bindings::llvm-const-int i64 elem-bytes nil) "pf_pitch64")
                       i32 "pf_pitch")))
    (%coop-call builder module
                "__spirv_Subgroup2DBlockPrefetchINTEL"
                (crisp.llvm-bindings::llvm-void-type)
                (list i32 i32 i32 i32 (%coop-ptr-type as) i32 i32 i32 v2i32)
                (list (crisp.llvm-bindings::llvm-const-int i32 elem-bytes nil) ; ElementSize (bytes)
                      (crisp.llvm-bindings::llvm-const-int i32 cols nil)   ; BlockWidth  (cols)
                      (crisp.llvm-bindings::llvm-const-int i32 rows nil)   ; BlockHeight (rows)
                      (crisp.llvm-bindings::llvm-const-int i32 1 nil)      ; BlockCount
                      ptr                                                  ; SrcBasePointer
                      (crisp.llvm-bindings::llvm-const-int i32 cols nil)   ; MemoryWidth  (elements)
                      (crisp.llvm-bindings::llvm-const-int i32 rows nil)   ; MemoryHeight (rows)
                      pitch-bytes                                          ; MemoryPitch  (bytes)
                      (crisp.llvm-bindings::llvm-const-null v2i32)))))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 — a PREFETCH node has no matrix, so it fell back to f32.
;;;;
;;;; %coop-node-elem answered the question "what is this coop-op's element type?" by reading the
;;;; node's own `(coop-matrix ELEM rows cols use)` type, falling back to the VALUE node for a
;;;; :store (whose own type is 'void).  A :prefetch node has NEITHER -- it names a tensor and a
;;;; region, and produces no matrix at all -- so it fell through to FLOAT.
;;;;
;;;; The consequence was visible in the emitted IR of the benchmark kernel even after the address
;;;; and prefetch-size fixes landed:
;;;;
;;;;     8 call void @__spirv_Subgroup2DBlockPrefetchINTEL(i32 4, i32 16, i32 16 ...
;;;;    20 getelementptr float, ptr addrspace(1) %coop_base     <- 8 correct C stores + 12 prefetches
;;;;    18 getelementptr half,  ptr addrspace(1) %coop_base
;;;;
;;;; i.e. the A/B LOADS were correct while every PREFETCH of the same tensors still described them
;;;; as f32 -- twice as wide as the data, running off the end of the allocation.
;;;;
;;;; The fix is to ask the TENSOR when there is no matrix to ask.  That is the same source
;;;; %coop-elem-of uses on the analysis side; doing it here keeps codegen from needing a separate
;;;; notion of what a prefetch is prefetching.
;;;; ------------------------------------------------------------------------------------------

;; src/codegen.lisp  (REPLACES %coop-node-elem -- 155)
(defun %coop-node-elem (node)
  "The CRISP element type of the cooperative matrix a coop-op node operates on.

   Sources, in order:
     1. the node's own `(coop-matrix ELEM rows cols use)` type   — :fill / :load
     2. its VALUE node's type                                    — :store, whose own type is 'void
     3. its TENSOR node's element type                           — :prefetch, which has no matrix
   Anything unrecognised yields FLOAT, the pre-155 behaviour."
  (flet ((coop-elem (ty)
           (and (consp ty)
                (symbolp (first ty))
                (string= (symbol-name (first ty)) "COOP-MATRIX")
                (>= (length ty) 2)
                (second ty)))
         (tensor-elem (ty)
           ;; A tensor/matrix type spec carries its element type second: (tensor ELEM N ...).
           (and (consp ty)
                (symbolp (first ty))
                (member (symbol-name (first ty)) '("TENSOR" "MATRIX") :test #'string=)
                (>= (length ty) 2)
                (symbolp (second ty))
                (second ty))))
    (or (coop-elem (semantic-coop-op-type node))
        (let ((vn (semantic-coop-op-value-node node)))
          (and vn (coop-elem (semantic-node-type vn))))
        (let ((tn (semantic-coop-op-tensor-node node)))
          (and tn (tensor-elem (%ts-canonicalize-tensor-type (semantic-node-type tn)))))
        (let ((tn (semantic-coop-op-tensor-node node)))
          (and tn (tensor-elem (semantic-node-type tn))))
        'float)))


;; src/codegen.lisp  (REPLACES generate-node-ir (semantic-coop-op) -- 155)
;;
;; Endeavour 155: the :STORE and :PREFETCH branches call %coop-tensor-ptr+stride through a shorter
;; form than :LOAD does, so the earlier edit -- which matched on the :load call's argument layout
;; -- reached only one of the three sites.  The emitted IR said so plainly: A/B loads indexed by
;; `half` while every prefetch of the SAME tensor still indexed by `float`.
;;
;;     20 getelementptr float, ptr addrspace(1) %coop_base    <- 8 C stores (right) + 12 prefetches (wrong)
;;     18 getelementptr half,  ptr addrspace(1) %coop_base    <- the A/B loads
;;
;; Passing ELEM-LLVM at all three is a no-op for :store (C really is f32) and the fix for
;; :prefetch.  Worth noting that counting the GEPs by element type was what made this visible --
;; the totals had to add up, and 20 was too many.
(defmethod generate-node-ir ((node semantic-coop-op) builder module var-env di-builder di-scope location-map)
  "Cooperative-matrix op: fill / load / store / prefetch / map / map2."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((kind (semantic-coop-op-kind node))
          (rows (semantic-coop-op-rows node))
          (cols (semantic-coop-op-cols node))
          (use  (semantic-coop-op-use node))
          (layout (semantic-coop-op-layout node))
          (i64 (llvm-int64-type))
          (f32 (llvm-float-type))
          ;; Endeavour 155: the matrix's REAL component type.  See header.
          (elem-llvm (%coop-op-elem-llvm node)))
      (labels ((origin (dim-node dim)
                 (llvm-build-mul builder
                                 (llvm-build-sext builder (gen dim-node) i64 "coop_tid")
                                 (llvm-const-int i64 dim nil) "coop_orig"))
               (ptr-of (name)
                 (or (gethash name var-env)
                     (error 'crisp-compiler-error
                            :message (format nil "cooperative-matrix map: no storage found for variable ~a." name)
                            :source-location (semantic-coop-op-source-location node))))
               (map-loop (primary-ptr per-elem)
                 ;; Endeavour 155: the map loops extract SCALAR elements into f32 allocas
                 ;; (cm_elem / cm_prm / cm_adj below).  For a 16-bit matrix those would be the
                 ;; wrong width, so refuse rather than miscompile.  See header for why this is a
                 ;; refusal and not a fix.
                 (unless (eq (%coop-node-elem node) 'float)
                   (error 'crisp-compiler-error
                          :message (format nil "cooperative-matrix elementwise map is only implemented for float (fp32) matrices; this one is ~a.  The map loop extracts scalar elements through f32 temporaries, which would silently truncate a ~:*~a matrix."
                                           (%coop-node-elem node))
                          :source-location (semantic-coop-op-source-location node)))
                 (let* ((i32 (llvm-int32-type))
                        (coop-ty (%coop-type f32 rows cols use))
                        (mat (llvm-build-load2 builder coop-ty primary-ptr "cm_map_mat"))
                        (len (%coop-length builder module mat f32 rows cols use))
                        (current-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                        (i-alloca (llvm-build-alloca builder i32 "cm_i"))
                        (check-block (llvm-append-basic-block current-fn "cm_check"))
                        (body-block  (llvm-append-basic-block current-fn "cm_body"))
                        (exit-block  (llvm-append-basic-block current-fn "cm_exit")))
                   (llvm-build-store builder (llvm-const-int i32 0 0) i-alloca)
                   (llvm-build-br builder check-block)
                   (llvm-position-builder-at-end builder check-block)
                   (let* ((i-val  (llvm-build-load2 builder i32 i-alloca "cm_i_v"))
                          (cond-v (llvm-build-icmp builder +llvm-int-slt+ i-val len "cm_cond")))
                     (llvm-build-cond-br builder cond-v body-block exit-block))
                   (llvm-position-builder-at-end builder body-block)
                   (let* ((i-val (llvm-build-load2 builder i32 i-alloca "cm_i_b"))
                          (i-x   (llvm-build-sext builder i-val i64 "cm_i64")))
                     (funcall per-elem i-x)
                     (let* ((i-cur  (llvm-build-load2 builder i32 i-alloca "cm_i_c"))
                            (i-next (llvm-build-add builder i-cur (llvm-const-int i32 1 0) "cm_i_n")))
                       (llvm-build-store builder i-next i-alloca)))
                   (unless (terminator-p (llvm-get-insert-block builder))
                     (llvm-build-br builder check-block))
                   (llvm-position-builder-at-end builder exit-block)
                   (values nil nil))))
        (ecase kind
          (:fill
           (values (%coop-fill builder module (gen (semantic-coop-op-value-node node))
                               elem-llvm rows cols use)
                   nil))
          (:load
           (multiple-value-bind (ptr stride)
               (%coop-tensor-ptr+stride builder (gen (semantic-coop-op-tensor-node node))
                                        (origin (semantic-coop-op-ty node) rows)
                                        (origin (semantic-coop-op-tx node) cols) layout elem-llvm)
             (values (%coop-load builder module ptr stride elem-llvm rows cols use layout) nil)))
          (:store
           (let* ((mat (gen (semantic-coop-op-value-node node)))
                  (tv  (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout elem-llvm)
               (%coop-store builder module ptr mat stride elem-llvm rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout elem-llvm)
               (%block-prefetch builder module ptr stride rows cols (%elem-llvm-bytes elem-llvm))
               (values nil nil))))
          (:map
           (let* ((tgt (ptr-of (semantic-coop-op-ty node)))
                  (temp-name (semantic-coop-op-tx node))
                  (body-node (semantic-coop-op-tensor-node node))
                  (t-alloca (llvm-build-alloca builder f32 "cm_elem")))
             (map-loop tgt
                       (lambda (i-x)
                         (let* ((ep   (%coop-access-chain builder module tgt i-x))
                                (elem (llvm-build-load2 builder f32 ep "cm_elem_v"))
                                (benv (alexandria:copy-hash-table var-env)))
                           (llvm-build-store builder elem t-alloca)
                           (setf (gethash temp-name benv) t-alloca)
                           (let ((res (generate-node-ir body-node builder module benv
                                                        di-builder di-scope location-map)))
                             (llvm-build-store builder res ep)))))))
          (:map2
           (let* ((adj-ptr (ptr-of (semantic-coop-op-ty node)))
                  (prm-ptr (ptr-of (semantic-coop-op-tx node)))
                  (temps   (semantic-coop-op-layout node))
                  (tp-name (first temps))
                  (ta-name (second temps))
                  (body-node (semantic-coop-op-tensor-node node))
                  (tp-alloca (llvm-build-alloca builder f32 "cm_prm"))
                  (ta-alloca (llvm-build-alloca builder f32 "cm_adj")))
             (map-loop adj-ptr
                       (lambda (i-x)
                         (let* ((ep-a (%coop-access-chain builder module adj-ptr i-x))
                                (ep-p (%coop-access-chain builder module prm-ptr i-x))
                                (v-a  (llvm-build-load2 builder f32 ep-a "cm_adj_v"))
                                (v-p  (llvm-build-load2 builder f32 ep-p "cm_prm_v"))
                                (benv (alexandria:copy-hash-table var-env)))
                           (llvm-build-store builder v-p tp-alloca)
                           (llvm-build-store builder v-a ta-alloca)
                           (setf (gethash tp-name benv) tp-alloca)
                           (setf (gethash ta-name benv) ta-alloca)
                           (let ((res (generate-node-ir body-node builder module benv
                                                        di-builder di-scope location-map)))
                             (llvm-build-store builder res ep-a))))))))))))


;; tests/run-specs.lisp
(defun %spv-int-widths (txt)
  "Alist of (type-id-string . width) for every OpTypeInt in TXT.
   Endeavour 155: needed because a bf16 cooperative matrix's component type is an INTEGER."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeInt")
                       (cl:>= (cl:length toks) 4))
        (cl:let ((w (cl:ignore-errors (cl:parse-integer (cl:fourth toks)))))
          (cl:when w (cl:push (cl:cons (cl:third toks) w) out)))))))

;; tests/run-specs.lisp  (REPLACES %spv-coop-matrices -- 155 bf16)
(defun %spv-coop-matrices (txt)
  "List of (RESULT-ID COMPONENT-WIDTH USE KIND) for every TypeCooperativeMatrixKHR in TXT.

   KIND is :FLOAT or :INT — Endeavour 155, because Intel encodes a bf16 matrix as 16-bit INTEGER
   components with the bfloat-ness carried by the MulAdd operands mask, so width alone no longer
   identifies the element type.  Either field may be NIL when the operand is not a scalar type or
   not a resolvable constant; callers must treat NIL as 'unknown', never as 'fine'."
  (cl:let ((floats (%spv-float-widths txt))
           (ints   (%spv-int-widths txt))
           (consts (%spv-int-constants txt))
           (out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeCooperativeMatrixKHR")
                       (cl:>= (cl:length toks) 8))
        (cl:let* ((comp (cl:fourth toks))
                  (fw (cl:cdr (cl:assoc comp floats :test #'cl:string=)))
                  (iw (cl:cdr (cl:assoc comp ints   :test #'cl:string=))))
          (cl:push (cl:list (cl:third toks)
                            (cl:or fw iw)
                            (cl:cdr (cl:assoc (cl:eighth toks) consts :test #'cl:string=))
                            (cl:cond (fw :float) (iw :int) (cl:t cl:nil)))
                   out))))))

;; tests/run-specs.lisp  (REPLACES %validate-coop-operand-elem -- 155 bf16)
(defun %validate-coop-operand-elem (spv-path want-width label &key require-ext int-components)
  "Assert that EVERY A/B cooperative matrix in SPV-PATH has component width WANT-WIDTH — and, when
   INT-COMPONENTS, that they are INTEGER components rather than float ones — and that every
   Accumulator is 32-bit float.  LABEL names the element type for the failure text; REQUIRE-EXT,
   when given, must appear in the module.

   Endeavour 155: the INT-COMPONENTS distinction is the difference between fp16 and bf16 on Intel.
   Both are 16 bits wide; only the KIND separates them, so checking width alone would let a bf16
   kernel silently emit fp16 matrices and still pass.

   DEGRADES TO PASS when llvm-spirv is unavailable (a CUDA-only box has no bundled bin/), matching
   %spv-contains-opcode-p: returns NIL only when the module WAS disassembled and the property is
   definitively absent."
  (cl:let* ((tool (resolve-tool-executable "llvm-spirv"))
            (txt-path (cl:format cl:nil "~a.155txt" (uiop:native-namestring spv-path)))
            (want-kind (cl:if int-components :int :float)))
    (cl:multiple-value-bind (o e code)
        (uiop:run-program (cl:list (uiop:native-namestring tool) "--to-text"
                                   (uiop:native-namestring spv-path) "-o" txt-path)
                          :output :string :error-output :string :ignore-error-status cl:t)
      (cl:declare (cl:ignore o e))
      (cl:if (cl:or (cl:not (cl:zerop code)) (cl:not (probe-file txt-path)))
          (cl:progn
            (cl:format cl:*error-output*
                       "  (~a: llvm-spirv unavailable or failed — SKIPPING, not failing)~%" label)
            cl:t)
          (cl:let ((txt (uiop:read-file-string txt-path)))
            (cl:ignore-errors (cl:delete-file txt-path))
            (cl:let* ((mats (%spv-coop-matrices txt))
                      (ops  (cl:remove-if-not (cl:lambda (m) (cl:member (cl:third m) (cl:list 0 1))) mats))
                      (accs (cl:remove-if-not (cl:lambda (m) (cl:eql (cl:third m) 2)) mats))
                      (bad-ops (cl:remove-if (cl:lambda (m)
                                               (cl:and (cl:eql (cl:second m) want-width)
                                                       (cl:eq (cl:fourth m) want-kind)))
                                             ops))
                      (bad-acc (cl:remove-if (cl:lambda (m)
                                               (cl:and (cl:eql (cl:second m) 32)
                                                       (cl:eq (cl:fourth m) :float)))
                                             accs)))
              (cl:cond
                ((cl:null mats)
                 (cl:format cl:*error-output*
                            "FAIL: no cooperative matrix in the module at all — the MMA did not lower.~%")
                 cl:nil)
                ((cl:null ops)
                 (cl:format cl:*error-output*
                            "FAIL: no A/B-use cooperative matrix — operands did not reach the MMA.~%")
                 cl:nil)
                (bad-ops
                 (cl:format cl:*error-output*
                            "FAIL: ~d of ~d A/B cooperative matrices are not ~a (~d-bit ~a).~%~
                             Offenders (result-id, component-width, kind, use):~%"
                            (cl:length bad-ops) (cl:length ops) label want-width
                            (cl:string-downcase (cl:symbol-name want-kind)))
                 (cl:dolist (m bad-ops)
                   (cl:format cl:*error-output* "    id ~a  component=~a-bit ~a  use=~a~%"
                              (cl:first m) (cl:or (cl:second m) "?")
                              (cl:or (cl:fourth m) "?") (%spv-use-name (cl:third m))))
                 cl:nil)
                (bad-acc
                 (cl:format cl:*error-output*
                            "FAIL: ~d accumulator matrix/matrices are not fp32.  A ~a MMA~%~
                             accumulates in fp32; an all-~a module is as wrong as an all-f32 one.~%"
                            (cl:length bad-acc) label label)
                 cl:nil)
                ((cl:null accs)
                 (cl:format cl:*error-output*
                            "FAIL: no Accumulator cooperative matrix — nothing is accumulating in fp32.~%")
                 cl:nil)
                ((cl:and require-ext (cl:not (cl:search require-ext txt)))
                 (cl:format cl:*error-output*
                            "FAIL: module uses ~a but does not declare ~a — llvm-spirv would refuse it.~%"
                            label require-ext)
                 cl:nil)
                (cl:t cl:t))))))))


;;;; ============================================================================
;;;; Endeavour 155 — bf16 ON INTEL, THE WAY INTEL ACTUALLY ENCODES IT.
;;;;
;;;; Crisp emitted bf16 as a genuine bfloat cooperative-matrix component type and requested
;;;; SPV_KHR_bfloat16.  The BMG driver's SPIR-V reader does not implement that extension: it
;;;; reports `unknown extension 'SPV_KHR_bfloat16'` and then dies.  The obvious readings were
;;;; "wait for a driver" or "switch to SPV_INTEL_subgroup_matrix_multiply_accumulate".  BOTH ARE
;;;; WRONG, and compiling Intel's own bf16 joint_matrix kernel and disassembling it shows why.
;;;;
;;;; WHAT INTEL EMITS.  Same extension Crisp uses, same opcode Crisp uses:
;;;;
;;;;    bf16:   TypeInt 25 16 0                      <- a 16-bit INTEGER, not a float type
;;;;            TypeCooperativeMatrixKHR 27 25 ...   <- A and B use the INTEGER component
;;;;            CooperativeMatrixMulAddKHR 22 35 30 34 23 64
;;;;                                                      ^^ operands mask 0x40
;;;;            extensions: SPV_KHR_cooperative_matrix ONLY
;;;;
;;;;    half:   TypeFloat 25 16                      <- a real f16 float type
;;;;            CooperativeMatrixMulAddKHR ... 0     <- mask 0
;;;;
;;;; So bf16 is carried as raw 16-bit integers and its bfloat-ness is signalled by ONE BIT on the
;;;; MulAdd: 0x40, MatrixAAndBBFloat16ComponentsINTEL.  No bfloat type exists in the module, so no
;;;; SPV_KHR_bfloat16 is needed — and SPV_INTEL_bfloat16_conversion is not needed either (it
;;;; provides SCALAR f32<->bf16 conversion ops, which an MMA does not use; Intel's own kernel does
;;;; not declare it).
;;;;
;;;; This also explains why fp16 started working the moment the element type reached codegen:
;;;; Crisp's fp16 encoding was ALREADY byte-for-byte what Intel emits — real f16 components,
;;;; mask 0.  Only bf16 differed, and it differed by choosing the newer, more principled encoding
;;;; that this driver does not yet read.
;;;;
;;;; PORTABILITY, STATED.  0x40 is an INTEL-vendored value in the KHR operands enum, and the
;;;; module declares no INTEL extension for it — that is what Intel's own output does and it works
;;;; here.  Whether another KHR cooperative-matrix implementation accepts it is unknown, so this
;;;; is applied on the SPIR-V backend only, which is the Intel path.  A different vendor reaching
;;;; the SPV backend would want this behind a hardware-profile key.
;;;; ============================================================================

;; src/codegen.lisp  (REPLACES %coop-op-elem-llvm -- 155 bf16)
(defun %coop-op-elem-llvm (node)
  "The LLVM type for a coop-op node's component type (see %coop-node-elem).

   Endeavour 155: BFLOAT16 lowers to a 16-BIT INTEGER, not to LLVM `bfloat`.  That is how Intel
   encodes a bf16 cooperative matrix (see header) — the type carries no float-ness and the MulAdd
   operands mask supplies it.  i16 is also the correct width for the tile ADDRESS arithmetic, so
   one answer serves both uses."
  (let ((e (%coop-node-elem node)))
    (cond ((string= (symbol-name e) "HALF")     (llvm-half-type))
          ((string= (symbol-name e) "BFLOAT16") (crisp.llvm-bindings::llvm-int16-type))
          ((string= (symbol-name e) "DOUBLE")   (llvm-double-type))
          (t                                    (llvm-float-type)))))

;; src/compiler.lisp  (REPLACES %module-uses-bfloat-p -- 155 bf16)
(defun %module-uses-bfloat-p (module)
  "Always NIL now.

   Endeavour 155: Crisp no longer emits the LLVM `bfloat` TYPE at all — a bf16 cooperative matrix
   is a 16-bit INTEGER matrix plus an operands-mask bit (see the bf16 header).  So no module needs
   SPV_KHR_bfloat16, and requesting it is what the BMG driver refused to read.

   Kept as a function rather than deleted because compile-to-spirv calls it, and because the day a
   backend DOES want a real bfloat type this is the single place that decides."
  (declare (ignore module))
  cl:nil)

;; tests/run-specs.lisp  (REPLACES validate-spv-bf16-coop -- 155 bf16)
(defun validate-spv-bf16-coop (spv-path)
  "Endeavour 155 — assert a bf16 register tile reached the hardware in INTEL'S bf16 ENCODING.

   That encoding is: A/B cooperative matrices with 16-BIT INTEGER components, an fp32 accumulator,
   and NO SPV_KHR_bfloat16 (there is no bfloat type in the module to require it).  Verified
   against what Intel's own bf16 joint_matrix kernel emits.

   This rung previously asserted the opposite — a 16-bit FLOAT component and a declared
   SPV_KHR_bfloat16 — which is the encoding this driver refuses.  The change is not a relaxation:
   it is the same per-operand strictness applied to the correct target."
  (%validate-coop-operand-elem spv-path 16 "bfloat16 (as i16)" :int-components cl:t))


;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 — bf16 becomes i16 AT THE ONE PLACE COOP TYPES ARE BUILT.
;;;;
;;;; Changing %coop-op-elem-llvm covered the fill / load / store / address paths, but not the
;;;; FRAGMENT ALLOCA, which reaches LLVM by a different route: resolve-type-to-llvm sees the
;;;; semantic `(coop-matrix bfloat16 8 16 0)` and resolves the element through the type registry,
;;;; where bfloat16 maps to LLVM `bfloat`.  The result was a module that disagreed with itself —
;;;; i16 matrices from the fill, `bfloat` matrices in the MulAdd operands:
;;;;
;;;;     %27 = call target("spirv.CooperativeMatrixKHR", i16, 3, 8, 16, 0) @__spirv_CompositeConstruct_0_8_16(float 0.0)
;;;;     ... @__spirv_CooperativeMatrixMulAddKHR(target("spirv.CooperativeMatrixKHR", bfloat, 3, 8, 16, 0) ...
;;;;
;;;; %coop-type is the single choke point every cooperative-matrix LLVM type passes through — the
;;;; alloca path calls it via resolve-type-to-llvm, and codegen calls it directly.  Making the
;;;; substitution HERE means every route agrees by construction, rather than requiring each route
;;;; to remember.  That is the same lesson as the six element-type layers: put the decision where
;;;; the thing is CONSTRUCTED, not at each site that consumes it.
;;;;
;;;; Scoped to :spirv because it is an Intel encoding (see the bf16 header); on any other backend
;;;; a bfloat element passes through untouched.
;;;; ------------------------------------------------------------------------------------------

;; src/codegen.lisp  (REPLACES %coop-type -- 155 bf16)
(defun %coop-type (elem-llvm rows cols use)
  "Build target(\"spirv.CooperativeMatrixKHR\", ELEM-LLVM, 3, ROWS, COLS, USE) in the
   global context (= the module's context, so the type matches).

   Endeavour 155: an LLVM `bfloat` element is rewritten to i16 on the SPIR-V backend, because that
   is how Intel encodes a bf16 cooperative matrix — raw 16-bit integers, with the bfloat-ness
   carried by the MulAdd operands mask (0x40).  Emitting a real bfloat type instead requires
   SPV_KHR_bfloat16, which the BMG driver's SPIR-V reader does not implement."
  (let* ((bf (crisp.llvm-bindings::llvm-bfloat-type))
         (elem (if (and (eq *target-backend* :spirv)
                        elem-llvm
                        (cffi:pointer-eq elem-llvm bf))
                   (crisp.llvm-bindings::llvm-int16-type)
                   elem-llvm))
         (ctx (crisp.llvm-bindings::llvm-get-global-context)))
    (cffi:with-foreign-objects ((tps :pointer 1) (ips :unsigned-int 4))
      (setf (cffi:mem-aref tps :pointer 0) elem
            (cffi:mem-aref ips :unsigned-int 0) 3          ; Subgroup scope
            (cffi:mem-aref ips :unsigned-int 1) rows
            (cffi:mem-aref ips :unsigned-int 2) cols
            (cffi:mem-aref ips :unsigned-int 3) use)
      (crisp.llvm-bindings::llvm-target-ext-type-in-context
       ctx "spirv.CooperativeMatrixKHR" tps 1 ips 4))))

;; src/codegen.lisp  (REPLACES %coop-coerce-scalar -- 155 bf16)
(defun %coop-coerce-scalar (builder val want-ty name)
  "Coerce scalar VAL to WANT-TY, if it is not already that type.

   Float-to-float goes by fptrunc / fpext (Endeavour 155, fp16).

   FLOAT TO i16 IS THE bf16 FILL.  A bf16 cooperative matrix has INTEGER components, so filling
   one with a literal `0.0` means storing that float's BF16 BIT PATTERN as an i16.  bfloat16 is
   the top half of an IEEE f32, so the encoding is a bitcast to i32, a 16-bit logical shift right,
   and a truncate — no bfloat type is introduced anywhere, which is the entire point (see the bf16
   header).  This truncates rather than round-to-nearest; for the 0.0 that fills every accumulator
   and operand tile it is exact, and a rounding form would need a bfloat type or a carry chain to
   express.

   LLVM has no direct cast between two DIFFERENT 16-bit float types, so half<->bfloat16 would route
   through f32; that path cannot arise from a literal today."
  (let ((have (llvm-type-of val))
        (i16  (crisp.llvm-bindings::llvm-int16-type))
        (i32  (crisp.llvm-bindings::llvm-int32-type)))
    (cond
      ((cffi:pointer-eq have want-ty) val)
      ;; f32 -> bf16 bits, carried as i16
      ((and (cffi:pointer-eq want-ty i16) (%llvm-float-width have))
       (let* ((as-f32 (if (cffi:pointer-eq have (llvm-float-type))
                          val
                          (llvm-build-fp-ext builder val (llvm-float-type) "bf_f32")))
              (bits (crisp.llvm-bindings::llvm-build-bit-cast builder as-f32 i32 "bf_bits"))
              (hi   (crisp.llvm-bindings::llvm-build-l-shr
                     builder bits (crisp.llvm-bindings::llvm-const-int i32 16 nil) "bf_hi")))
         (crisp.llvm-bindings::llvm-build-trunc builder hi i16 name)))
      (t
       (let ((hw (%llvm-float-width have))
             (ww (%llvm-float-width want-ty)))
         (cond
           ((not (and hw ww)) val)
           ((> hw ww) (llvm-build-fp-trunc builder val want-ty name))
           ((< hw ww) (llvm-build-fp-ext   builder val want-ty name))
           (t (llvm-build-fp-trunc builder
                                   (llvm-build-fp-ext builder val (llvm-float-type)
                                                      (format nil "~a_via_f32" name))
                                   want-ty name))))))))

;; src/mma.lisp  (REPLACES %coop-mma -- 155 bf16, corrected detection)
(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, <operands>) -> the MxN accumulator coop matrix.

   Operand types come from the ACTUAL VALUES via LLVMTypeOf, so the declaration cannot drift from
   what is passed (Endeavour 155, Phase 1).

   THE OPERANDS MASK.  0 for f32/tf32 and for fp16, whose component type already says what it is.
   0x40 (MatrixAAndBBFloat16ComponentsINTEL) when A and B are 16-bit INTEGER matrices, which is
   how Intel represents bf16 — an integer type cannot say 'bfloat' on its own, so the bit says it.

   DETECTION READS THE TYPE, IT DOES NOT REBUILD IT.  The first attempt compared A against a
   freshly constructed (%coop-type i16 m k 0), which failed for a reason worth recording: this
   function's M/N/K come from a caller that computes them with an UNTYPED (%spv-mma-shape) —
   src/mma.lisp:653 — so K is the tf32 8 even when the operands are 16-bit and K is really 16.
   Those arguments are otherwise unused here (the types come from the values), so the wrong shape
   is harmless to codegen and was harmless to fp16; it only defeated a check that trusted it.
   Printing the type and reading its component is exact and depends on nothing else."
  (declare (ignorable elem-llvm m n k))
  (let* ((a-ty (crisp.llvm-bindings::llvm-type-of a-val))
         (b-ty (crisp.llvm-bindings::llvm-type-of b-val))
         (c-ty (crisp.llvm-bindings::llvm-type-of c-val))
         (i32  (crisp.llvm-bindings::llvm-int32-type))
         (a-str (crisp.llvm-bindings::llvm-print-type-to-string a-ty))
         (bf16-p (and (eq *target-backend* :spirv)
                      a-str
                      (search ", i16," a-str)))
         (operands (if bf16-p #x40 0)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 operands nil)))))

;; src/codegen.lisp  (REPLACES %elem-llvm-bytes -- 155 bf16)
(defun %elem-llvm-bytes (elem-llvm)
  "Bytes per element for an LLVM scalar type, defaulting to 4 — which is what every hardcoded
   constant this replaces assumed.

   Endeavour 155 (bf16): must handle INTEGER types, not just floats.  Once bf16 lowered to i16,
   the float-only lookup returned NIL and fell back to 4, so %block-prefetch again described a
   2-byte surface as 4-byte — twice as wide as the data, off the end of the allocation.  The
   symptom was the one already seen for fp16: a constant ~500 ms at every problem size with wrong
   results, i.e. a GPU fault and reset, in the kernel that prefetches and not in the one that
   does not."
  (let ((bits (and elem-llvm
                   (or (%llvm-float-width elem-llvm)
                       (cond ((cffi:pointer-eq elem-llvm (crisp.llvm-bindings::llvm-int8-type))   8)
                             ((cffi:pointer-eq elem-llvm (crisp.llvm-bindings::llvm-int16-type)) 16)
                             ((cffi:pointer-eq elem-llvm (crisp.llvm-bindings::llvm-int32-type)) 32)
                             ((cffi:pointer-eq elem-llvm (crisp.llvm-bindings::llvm-int64-type)) 64)
                             (t nil))))))
    (if bits (max 1 (floor bits 8)) 4)))

;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 — bfloat16 lowers to i16 EVERYWHERE on SPIR-V, not only inside a coop type.
;;;;
;;;; Phase G put the bf16 -> i16 substitution in %coop-type, which is where cooperative-matrix
;;;; types are built.  That covered the MMA operands and missed everything else that can hold a
;;;; bf16: `(make-scratch-matrix bfloat16 ...)` allocates ordinary SLM STORAGE, resolved through
;;;; the type registry's thunk, and never passes through %coop-type at all.  The result was a
;;;; module carrying a real `bfloat` array, which llvm-spirv refuses:
;;;;
;;;;     RequiresExtension: SPV_KHR_bfloat16
;;;;     NOTE: LLVM module contains bfloat type, translation of which requires this extension
;;;;
;;;; -- the same extension the BMG driver cannot read, arrived at from a different direction.
;;;; SLM staging is the prerequisite for multi-subgroup tiles, so this blocked the whole
;;;; structural direction for bf16 while fp16 sailed through.
;;;;
;;;; The rule is simply broader than it was implemented: ON SPIR-V, bfloat16 IS i16.  Applying it
;;;; at the registry thunk makes every consumer agree by construction -- scratch matrices, plain
;;;; arrays, struct fields, anything -- rather than requiring each to remember, which is the
;;;; lesson this endeavour has now learned at six separate layers.
;;;;
;;;; PTX is untouched: NVIDIA has a real bfloat and will want it when 16-bit lands there.
;;;; ------------------------------------------------------------------------------------------

;; src/llvm-bindings.lisp / src/types/registry.lisp
(cl:unless (cl:fboundp '%llvm-bfloat-type-native)
  ;; Capture the REAL binding once.  Guarded so re-loading the overlay cannot wrap the wrapper
  ;; and recurse -- the overlay is loaded on every build, and this is a symbol-function swap.
  (cl:setf (cl:symbol-function '%llvm-bfloat-type-native)
           (cl:symbol-function 'crisp.llvm-bindings::llvm-bfloat-type)))

(cl:setf (cl:symbol-function 'crisp.llvm-bindings::llvm-bfloat-type)
         (cl:lambda ()
           "LLVM type for Crisp's BFLOAT16.  On SPIR-V this is i16: Intel encodes a bf16
            cooperative matrix as raw 16-bit integers with the bfloat-ness carried by the MulAdd
            operands mask (0x40), and emitting a real bfloat type instead requires
            SPV_KHR_bfloat16, which the BMG driver's SPIR-V reader does not implement.  On every
            other backend this is the native bfloat."
           (cl:if (cl:and (cl:boundp 'crisp.compiler::*target-backend*)
                          (cl:eq crisp.compiler::*target-backend* :spirv))
               (crisp.llvm-bindings::llvm-int16-type)
               (%llvm-bfloat-type-native))))


;; src/mma.lisp
(defun %warp-grid-dims (n-warps m-frags n-frags)
  "Endeavour 155: factor N-WARPS into a (GM . GN) 2-D warp grid over an M-FRAGS x N-FRAGS fragment
   grid, or NIL when no factorisation divides both axes evenly (caller then walks linearly).

   Prefers the SQUAREST per-warp block, minimising |m-frags/GM - n-frags/GN|.  That is what
   maximises operand sharing: a warp holding an mp x np block needs mp A-fragments and np
   B-fragments, and for a fixed mp*np the SUM mp+np is smallest when they are equal.  A row strip
   (GM=1) is the degenerate worst case -- np = n-frags, so every warp needs the whole of B."
  (when (and (integerp n-warps) (> n-warps 1)
             (integerp m-frags) (integerp n-frags) (plusp m-frags) (plusp n-frags))
    (let ((best nil) (best-score nil))
      (loop for gm from 1 to n-warps do
        (when (zerop (mod n-warps gm))
          (let ((gn (floor n-warps gm)))
            (when (and (<= gm m-frags) (<= gn n-frags)
                       (zerop (mod m-frags gm)) (zerop (mod n-frags gn)))
              (let ((score (abs (- (floor m-frags gm) (floor n-frags gn)))))
                (when (or (null best-score) (< score best-score))
                  (setf best (cons gm gn) best-score score)))))))
      best)))

;; src/mma.lisp  (REPLACES %emit-frag-loop-distributed -- 155: 2-D warp grid)
(defun %emit-frag-loop-distributed (syms n-frags first-true n-true per-frag-fn)
  "Endeavor 139 step-4 perf: emit a COMPILE-TIME-STATIC per-warp switch (was a runtime
   fragment-index loop).  wp = warp-position is runtime, so branch on it once via a `<`-cascade
   (the role-branch pattern, last warp = bare else since wp is gated into [0,n-true)); inside each
   arm the fragment (mi nj) fold to integer LITERALS so the SMEM operand loads get static addresses
   and ptxas can CSE them.  PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS (same
   contract as the n-true=1 static path)."
  (let* ((cl        (find-package :crisp-language))
         (progn-sym (intern "PROGN" cl))  (let-sym (intern "LET" cl))
         (if-sym    (intern "IF" cl))     (lt-sym  (intern "<" cl))
         (minus-sym (intern "-" cl))      (to-int-sym (intern "TO-INT" cl))
         (warp-id-sym (intern "WARP-ID" cl))
         (per-warp  (length syms))
         (wp        (gensym "WP")))
    (labels ((arm (k)
               ;; Endeavour 155: 2-D WARP GRID.  The linear form (kept as the fallback below)
               ;; gave warp k the logical range [k*per-warp, ...), which for a row-major (mi, nj)
               ;; flattening is a ROW STRIP -- and a strip shares operands along ONE axis only:
               ;; A slices by mi, but every warp still needs ALL of B.  SYCL-TLA's bf16 kernel uses
               ;; Layout<Shape<_8,_4,_1>>, an 8x4 grid of 32 subgroups over a 256x256 tile, so each
               ;; subgroup needs 1/8 of A AND 1/4 of B.  That is what makes both operands sliceable,
               ;; which is the prerequisite for a large workgroup tile that does not replicate
               ;; operands into every subgroup.
               ;; m-frags is not a parameter here -- the caller passes only n-frags -- but the
               ;; total fragment count is per-warp * n-true, so the M extent follows.
               (let* ((m-frags (floor (* per-warp n-true) (max 1 n-frags)))
                      (grid (%warp-grid-dims n-true m-frags n-frags))
                      (gm (car grid)) (gn (cdr grid)))
                 (declare (ignorable gm))
                 `(,progn-sym
                    ,@(if grid
                          (let* ((mp (floor m-frags gm))
                                 (np (floor n-frags gn))
                                 (wm (floor k gn))
                                 (wn (mod k gn)))
                            (loop for l below per-warp
                                  for fv = (nth l syms)
                                  for mi = (+ (* wm mp) (floor l np))
                                  for nj = (+ (* wn np) (mod l np))
                                  append (funcall per-frag-fn fv mi nj)))
                          (loop for l below per-warp
                                for fv = (nth l syms)
                                for logical = (+ (* k per-warp) l)
                                for mi = (floor logical n-frags)
                                for nj = (mod logical n-frags)
                                append (funcall per-frag-fn fv mi nj))))))
             (chain (k)
               (if (>= k (1- n-true))
                   (arm k)                                   ; last warp = bare else
                   `(,if-sym (,lt-sym ,wp ,(1+ k))
                             ,(arm k)
                             ,(chain (1+ k))))))
      `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id-sym)) ,first-true)))
         ,(chain 0)))))


;;;; ============================================================================
;;;; Endeavour 155 Step 2 — WARP-SLICED OPERAND TILES.
;;;;
;;;; The blocker measured in Phase L: Crisp allocates the FULL workgroup-tile operands in EVERY
;;;; subgroup's registers, so the per-subgroup footprint scales with the WORKGROUP tile instead of
;;;; the subgroup's slice:
;;;;
;;;;     32x64  nw=1     6KB   no spill
;;;;     128x128 nw=8   16KB   spilled 220
;;;;     256x256 nw=32  32KB   spilled 508
;;;;
;;;; SYCL-TLA holds a 256x256 tile at 6KB per subgroup -- the same as our SMALLEST config -- because
;;;; subgroup (wm, wn) of its 8x4 grid loads only A[its 32 rows] and B[its 64 columns].
;;;;
;;;; THE SLICE DIVIDES DIFFERENTLY PER OPERAND, which is the thing to get right:
;;;;     A : warps in the same grid ROW need the SAME rows      -> gm distinct slices
;;;;     B : warps in the same grid COLUMN need the same cols   -> gn distinct slices
;;;;     C : every warp is distinct                             -> n-true slices
;;;;
;;;; THE COUPLING.  An operand tile's slice depends on the ACCUMULATOR's fragment grid, which the
;;;; operand binding cannot see on its own (A knows its row count -- which equals C's m-frags, both
;;;; being TM/8 -- but not C's n-frags).  %explode-register-tiles processes every binding of one LET
;;;; together, so it can compute the grid from the accumulator in a first pass and slice the
;;;; operands in a second.  *WARP-GRID* publishes it to the walk and the load emitter, exactly as
;;;; *mma-scratch-tile-dims* publishes staged-tile shapes (145 P3a).
;;;;
;;;; GUARDED: nothing changes unless an operand tile carries :warps.  Existing kernels are
;;;; untouched by construction.
;;;; ============================================================================

;; src/mma.lisp
(defvar *warp-grid* nil
  "Endeavour 155: (GM . GN) warp grid of the LET currently being exploded, derived from its
   accumulator register-tile's fragment grid and warp count, or NIL when there is no distributed
   accumulator.  Read by the operand-slicing paths so A/B, C and the loads all agree on which warp
   owns what.  Bound by %explode-register-tiles; NIL elsewhere, in which case operands are
   allocated whole -- the pre-Step-2 behaviour.")

;; src/mma.lisp
(defun %warp-grid-from-bindings (bindings context location)
  "Scan a LET's BINDINGS for the accumulator register-tile that carries :warps and return the
   (GM . GN) warp grid implied by its fragment grid and participating-warp count, else NIL.

   Only the ACCUMULATOR defines the grid: it is the tile whose fragments are partitioned one-per-
   warp, and the operands merely follow that partition."
  (declare (ignorable location))
  (let ((grid nil))
    (dolist (b bindings grid)
      (when (and (consp b) (= (length b) 2) (symbolp (first b))
                 (%register-tile-init-form-p (second b)))
        (let* ((form (second b))
               (elem (second form))
               (dims (third form))
               (m (first dims)) (n (second dims))
               (operand (getf (nthcdr 4 form) :operand :acc))
               (warps-in (getf (nthcdr 4 form) :warps)))
          (when (and (eq operand :acc) warps-in)
            (let* ((mask (%normalize-warp-mask (%warp-mask-unquote warps-in) location))
                   (n-true (and mask (count-if #'identity mask))))
              (when (and n-true (> n-true 1))
                (destructuring-bind (fr . fc) (%frag-mn-for-operand :acc elem)
                  (let ((g (%warp-grid-dims n-true (floor m fr) (floor n fc))))
                    (when g (setf grid g))))))))))))

;; src/mma.lisp
(defun %operand-warp-divisor (operand)
  "How many DISTINCT slices an operand tile has under the current *WARP-GRID*: GM for :a (warps in
   a grid row share A rows), GN for :b (warps in a column share B columns), 1 otherwise."
  (let ((g *warp-grid*))
    (cond ((null g) 1)
          ((eq operand :a) (car g))
          ((eq operand :b) (cdr g))
          (t 1))))


;;;; ============================================================================
;;;; Endeavour 155 Step 2b — INDEXING AND LOADING A WARP-SLICED OPERAND.
;;;;
;;;; Step 2a made an operand tile allocate only its warp's slice.  Two consumers still assumed the
;;;; whole tile, and both must follow or the kernel indexes a fragment that no longer exists
;;;; ("Unknown variable NIL"):
;;;;
;;;;   a-operand / b-operand      map a LOGICAL (mi, ks) / (nj, ks) to the warp's LOCAL index.
;;;;                              mi and nj are compile-time integers and a warp's rows are the
;;;;                              contiguous range [wm*mp, (wm+1)*mp), so the local row is just
;;;;                              (mod mi mp) -- the warp's own position never has to be known.
;;;;
;;;;   %emit-per-frag-block-load  emit only the warp's fragments, at global coordinates offset by
;;;;                              its grid position.  This one CANNOT be arithmetic on compile-time
;;;;                              indices: load-tile appears ONCE in the body while each warp loads
;;;;                              a DIFFERENT slice, so it needs the static per-warp switch the MMA
;;;;                              walk uses.  A has gm distinct slices (selected by wp/gn), B has
;;;;                              gn (selected by wp mod gn) -- warps in a grid row share A rows,
;;;;                              warps in a column share B columns.
;;;; ============================================================================

;; src/mma.lisp
(defun %warp-slice-extent (entry operand)
  "For a warp-sliced operand ENTRY, how many fragments along its SLICED axis one warp holds --
   mp for :a (rows), np for :b (columns) -- or NIL when the tile is not sliced.

   ENTRY is (NAME M N SYMS N-TRUE FIRST-TRUE OPERAND); sliced means a warp grid is in scope and
   this tile's N-TRUE exceeds 1, i.e. it carried its own :warps mask."
  (let ((g *warp-grid*)
        (n-true (fifth entry)))
    (when (and g (integerp n-true) (> n-true 1) (member operand '(:a :b)))
      (multiple-value-bind (sm sn sk) (%spv-mma-shape)
        (declare (ignorable sk))
        (if (eq operand :a)
            (max 1 (floor (max 1 (floor (second entry) sm)) (car g)))
            (max 1 (floor (max 1 (floor (third entry) sn)) (cdr g))))))))

;; src/mma.lisp  (REPLACES %emit-per-frag-accumulate -- 155 Step 2b)
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body shape)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is a
   static per-warp switch (n-true threaded to %emit-frag-loop-distributed).  Endeavor 142: when A/B
   are register-tiles (present in TILES, pre-loaded via load-tile), the operand is read from its
   pre-loaded fragment var instead of load-fragment-a/b.

   Endeavor 145 P3a: the staged operands may span SEVERAL native K-steps (Kt / K_n, compile-time)
   and every one of them now fires.  Previously only K-index 0 was emitted and any surplus staged
   data was silently dropped.  For the F3 body/accum-op API this means (accum-op) fires the
   fragment's WHOLE contraction — all of its K-steps — which keeps the promise that the body
   controls WHEN a fragment accumulates, not how its contraction is chopped up."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      ;; Endeavour 155 Phase C: honour the shape the KERNEL asked for.
      ;;
      ;; (mma-accumulate-via-tile (8 16 16) C A B) states K=16, which is the correct native
      ;; K-step for a 16-bit operand.  Re-deriving it from (first :mma-shapes) returned the TF32
      ;; K=8 instead, so the walker indexed fragments on a different K than the tiles were minted
      ;; with -- the A-tile held one K=16 fragment while the walker asked for two K=8 ones, and
      ;; the second came back NIL ("Unknown variable NIL").
      ;;
      ;; The requested shape was already in hand at the call site and already validated against
      ;; the profile by %check-mma-shape; it simply was not passed down.  Falling back to
      ;; %spv-mma-shape keeps every other caller behaving exactly as before.
      (multiple-value-bind (sm sn sk)
          (if (and shape (listp shape) (= (length shape) 3) (every #'integerp shape))
              (values-list shape)
              (%spv-mma-shape))
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (let* ((mp (%warp-slice-extent ta :a))          ; 155 Step 2b
                                  (row (if mp (mod mi mp) mi)))
                             (nth (+ (* row (max 1 (floor (third ta) sk))) ks) (fourth ta)))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (let* ((np (%warp-slice-extent tb :b))          ; 155 Step 2b
                                  (stride (or np (max 1 (floor (third tb) sn))))
                                  (col (if np (mod nj np) nj)))
                             (nth (+ (* ks stride) col) (fourth tb)))
                           `(load-fragment-b ,b (,ks ,nj)))))
                   (one-frag (fv mi-form nj-form)
                     (let* ((sets (loop for ks below k-steps
                                        collect `(set! ,fv (mma-accumulate ,fv
                                                                           ,(a-operand mi-form ks)
                                                                           ,(b-operand nj-form ks)))))
                            (acc-set (if (= (length sets) 1) (first sets) `(progn ,@sets))))
                       (if body
                           (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                           (list acc-set)))))
            (if (> n-true 1)
                ;; Endeavour 155: register-resident A/B ARE supported with a warp-distributed
                ;; accumulator.  The refusal this replaces was incidental, not essential --
                ;; %emit-frag-loop-distributed's own contract says so:
                ;;
                ;;   "PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS
                ;;    (same contract as the n-true=1 static path)."
                ;;
                ;; and it computes them as (floor logical n-frags) / (mod logical n-frags), both
                ;; compile-time.  a-operand/b-operand index the tile's fragment SYMBOL LIST with
                ;; (nth ...), which needs exactly that -- a constant.  139 step-4 made this path
                ;; static precisely so operand addressing could be static, so the machinery the
                ;; refusal was waiting for already existed when it was written.
                ;;
                ;; WHY THIS MATTERS.  It is the only route to a bigger workgroup tile that does
                ;; NOT go through SLM.  C is what limits tile size -- 64x64 in one subgroup spills
                ;; 112 registers and collapses to 20 TFLOPS -- and splitting C across subgroups
                ;; divides exactly that pressure, while A/B keep the register+prefetch path that
                ;; is the fastest thing on this hardware.  A/B are then loaded redundantly per
                ;; warp, which costs bandwidth the cache may absorb; that is the trade to measure.
                (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))

;; src/mma.lisp  (REPLACES %validate-warp-mask -- 155 Step 2: operand divisor)
(defun %validate-warp-mask (mask nfrags n-warps m n location &optional divisor)
  "Endeavor 139 (decision A): validate a normalized :warps mask.  Returns (values n-true first-true).
   Checks: length == n-warps (when statically known); >= 1 true; contiguous true run; n-true evenly
   divides nfrags."
  (let ((n-true (count t mask)) (first-true (position t mask)))
    (when (and n-warps (/= (length mask) n-warps))
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile :warps has ~a entries but the workgroup has ~a warp~:p (local-size / warp-size).  The mask must name every warp."
                         (length mask) n-warps)
        :source-location location))
    (when (zerop n-true)
      (error 'crisp-compiler-error
        :message "make-register-tile :warps must mark at least one warp true (some warp must hold the tile)."
        :source-location location))
    (unless (%warp-mask-contiguous-true-p mask)
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile :warps: the participating (true) warps must be contiguous, got ~S.  A non-contiguous participation mask is not yet supported." mask)
        :source-location location))
    ;; Endeavour 155 Step 2: an OPERAND tile does not divide by the warp COUNT -- warps in a grid
    ;; row share A rows and warps in a column share B columns, so A divides by gm and B by gn.
    ;; DIVISOR carries that when the caller knows it; without it the original n-true rule stands.
    (unless (zerop (mod nfrags (or divisor n-true)))
      (error 'crisp-compiler-error
        :message (format nil "make-register-tile: a ~ax~a tile is ~a (16x8) fragments, which ~a participating warps do not evenly divide.  Use a warp count that divides ~a (1/2/4/...)."
                         m n nfrags (or divisor n-true) nfrags)
        :source-location location))
    (values n-true first-true)))

;; src/mma.lisp  (REPLACES %emit-per-frag-store -- 155 Step 3: runtime-addressed distributed store)
(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).

   Endeavour 155 Step 3: RUNTIME-ADDRESSED distributed store.

   139 step-4 made this a static per-warp switch, which is right at 2-3 warps and catastrophic at
   32.  Each arm stores to a DIFFERENT global address, so unlike the MMA walk -- whose arms became
   identical once operands were warp-sliced, and collapsed -- every arm survives:

       tile          instrs   MulAdd   stores
       32x64  nw=1     1001       16       16
       128x128 nw=8    2025       16      121
       256x256 nw=32   5168       16      481     <- 32 arms x 16 fragments

   481 static stores for 16 dynamic ones, and 5168 instructions against SYCL-TLA's 2219 for the
   same geometry.

   With the 2-D warp grid the address is REGULAR, so one arm suffices:

       mi = wm*mp + (l / np)      wm = wp / gn      (runtime)
       nj = wn*np + (l mod np)    wn = wp mod gn    (runtime)

   l/np and l mod np are compile-time per fragment; only wm and wn are runtime, and they are two
   scalar ops shared by every fragment.  The static path is kept for the no-grid case, where the
   arms are few and literal addresses are preferable."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      (let* ((cl (find-package :crisp-language))
             (to-int-sym (intern "TO-INT" cl))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(store-fragment ,fv ,dest
                                        ((+ (* ,bty ,m-frags) ,mi-form)
                                         (+ (* ,btx ,n-frags) ,nj-form))))))
          (let ((grid (and (> n-true 1) (%warp-grid-dims n-true m-frags n-frags))))
            (cond
              ((and grid (> n-true 1))
               (let* ((let-sym (intern "LET" cl))
                      (progn-sym (intern "PROGN" cl))
                      (minus-sym (intern "-" cl))
                      (plus-sym (intern "+" cl))
                      (times-sym (intern "*" cl))
                      (floor-sym (intern "FLOOR" cl))
                      (mod-sym (intern "MOD" cl))
                      (warp-id (intern "WARP-ID" cl))
                      (gm (car grid)) (gn (cdr grid))
                      (mp (max 1 (floor m-frags gm)))
                      (np (max 1 (floor n-frags gn)))
                      (per-warp (length syms))
                      (wp (gensym "WP")) (wm (gensym "WM")) (wn (gensym "WN")))
                 `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id)) ,first-true)))
                    ;; Integer division/remainder via / and - : kernels use / for integer
                    ;; division throughout, whereas FLOOR/MOD in crisp-language are not verified
                    ;; for this use.  Previously they fed only comparisons (which tolerate a wrong
                    ;; value by selecting an arm); here they compute a global ADDRESS, where a
                    ;; wrong value is an out-of-bounds write.
                    ;; ISOLATED BY TEST: crisp-language FLOOR/MOD here yield a value that is fine
                    ;; for a COMPARISON but wrong as an ADDRESS -- almost certainly a float.  The
                    ;; step-2b load switch feeds its selector to (< ...) and is therefore correct;
                    ;; this store feeds a global index and was not.  Integer / and - instead.
                    (,let-sym ((,wm (,(intern "/" cl) ,wp ,gn)))
                      (,let-sym ((,wn (,minus-sym ,wp (,times-sym ,wm ,gn))))
                      (,progn-sym
                        ,@(loop for l below per-warp
                                for fv = (nth l syms)
                                append (one-frag fv
                                                 `(,plus-sym (,times-sym ,wm ,mp) ,(floor l np))
                                                 `(,plus-sym (,times-sym ,wn ,np) ,(mod l np))))))))))
              ((> n-true 1)
               (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
              (t
               `(progn
                  ,@(loop for mi below m-frags append
                          (loop for nj below n-frags
                                for idx = (+ (* mi n-frags) nj)
                                append (one-frag (nth idx syms) mi nj))))))))))))

;; tests/run-specs.lisp
(defun %spv-i64-type-ids (txt)
  "Result-ids of every 64-bit OpTypeInt in TXT."
  (cl:let ((out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeInt")
                       (cl:>= (cl:length toks) 4)
                       (cl:equal (cl:fourth toks) "64"))
        (cl:push (cl:third toks) out)))))

;; tests/run-specs.lisp
(defun validate-spv-tile-address-arith (spv-path)
  "Endeavour 155 rung 04 — assert tile address arithmetic does not scale PER FRAGMENT.

   Counts 64-bit OpIMul against OpCooperativeMatrixLoadKHR.  Address computation is per-TILE work
   and fragment loads are per-FRAGMENT work, so more 64-bit multiplies than loads means the
   arithmetic is being redone for every fragment -- which on Xe is an EMULATED multiply
   (mul/mach/macl, no native 64-bit multiply) and measured ~98% of the emitted instruction stream.

   A ratio rather than a threshold, deliberately: absolute instruction counts move with tile shape
   and compiler version, but 'address math must not be per-fragment' is the actual property.

   DEGRADES TO PASS when llvm-spirv is unavailable, matching the other .spv validators."
  (cl:let* ((tool (resolve-tool-executable "llvm-spirv"))
            (txt-path (cl:format cl:nil "~a.155addr" (uiop:native-namestring spv-path))))
    (cl:multiple-value-bind (o e code)
        (uiop:run-program (cl:list (uiop:native-namestring tool) "--to-text"
                                   (uiop:native-namestring spv-path) "-o" txt-path)
                          :output :string :error-output :string :ignore-error-status cl:t)
      (cl:declare (cl:ignore o e))
      (cl:if (cl:or (cl:not (cl:zerop code)) (cl:not (probe-file txt-path)))
          (cl:progn
            (cl:format cl:*error-output*
                       "  (validate-spv-tile-address-arith: llvm-spirv unavailable — SKIPPING)~%")
            cl:t)
          (cl:let ((txt (uiop:read-file-string txt-path)))
            (cl:ignore-errors (cl:delete-file txt-path))
            (cl:let* ((i64s (%spv-i64-type-ids txt))
                      (imul 0) (loads 0))
              (cl:dolist (toks (%spv-lines txt))
                (cl:when (cl:string= (cl:second toks) "IMul")
                  (cl:when (cl:member (cl:third toks) i64s :test #'cl:string=)
                    (cl:incf imul)))
                (cl:when (cl:string= (cl:second toks) "CooperativeMatrixLoadKHR")
                  (cl:incf loads)))
              (cl:cond
                ((cl:zerop loads)
                 (cl:format cl:*error-output*
                            "FAIL: no cooperative-matrix loads in the module — the tile did not lower.~%")
                 cl:nil)
                ((cl:>= imul loads)
                 (cl:format cl:*error-output*
                            "FAIL: ~d 64-bit integer multiplies for ~d cooperative-matrix loads.~%~
                             Address arithmetic is being recomputed PER FRAGMENT.  Xe has no native~%~
                             64-bit multiply, so each is emulated as mul/mach/macl -- measured ~~98%~
                             of the emitted instruction stream against 16 dpas.  Addresses within a~%~
                             tile differ by a fixed delta and should come from one per-tile base.~%"
                            imul loads)
                 cl:nil)
                (cl:t
                 (cl:format cl:*error-output* "  (~d i64 IMul for ~d coop loads)~%" imul loads)
                 cl:t))))))))

;;;; ============================================================================
;;;; Endeavour 155 Step 4 — BASE-PLUS-DELTA TILE ADDRESSING.
;;;;
;;;; THE MEASUREMENT.  ISA opcode histogram for a Crisp 256x256 bf16 matmul (IGC, Arc B580):
;;;;
;;;;     mov 727    mul 311    macl 224    mach 75    dpas 16
;;;;
;;;; `mach`/`macl` are the halves of an EMULATED 64-bit multiply -- Xe has no native one -- and the
;;;; kernel issues hundreds of them to address SIXTEEN dpas.  Every fragment of every tile recomputes
;;;; its whole flat offset from scratch, and both multiplies have a RUNTIME stride as an operand.
;;;;
;;;; THE STRUCTURE THAT WAS BEING THROWN AWAY.  %emit-per-frag-block-load emits each fragment's
;;;; coordinate as (+ (* (to-int gy) n-rows) ri) -- a per-tile base plus a COMPILE-TIME fragment
;;;; index -- and codegen then multiplies by the fragment extent and by the stride:
;;;;
;;;;     off0 = ((base + ri) * dim) * s0        <- s0 runtime, so emulated, once PER FRAGMENT
;;;;
;;;; but that distributes:
;;;;
;;;;     off0 = (base * dim) * s0  +  (ri * dim) * s0
;;;;            ^^^^^^^^^^^^^^^^^     ^^^^^^^^^^^^^^^
;;;;            identical for every    constant x stride: IGC strength-reduces this to
;;;;            fragment -> CSE'd      shifts and adds, with no mach/macl at all
;;;;
;;;; so the emulated multiplies fall from two per FRAGMENT to two per TILE.
;;;;
;;;; WHY LLVM WILL NOT DO THIS ITSELF.  Distributing a multiply over an add is normally a
;;;; PESSIMISATION -- it turns one multiply into two.  It pays here only because the first term is
;;;; shared across every fragment of the tile, which is not visible at the point where reassociate
;;;; runs.  Doing it at emission is not a workaround for a missed optimisation; emission is the only
;;;; place the sharing is known.
;;;;
;;;; WHY NOT SIMPLY NARROW TO 32-BIT.  That makes each multiply native rather than emulated, and it
;;;; is correct for realistic sizes -- but an element offset at N=65536 is 4.3e9, which wraps
;;;; SILENTLY in uint32.  This endeavour has produced enough silent-wrongness traps already.
;;;; Hoisting is correct at every size and REMOVES the multiplies rather than cheapening them.
;;;;
;;;; Pinned by tests/spec/155-typed-mma-shapes/04-tile-address-arithmetic.crisp.
;;;; ============================================================================

;; src/codegen.lisp
(defconstant +llvm-opcode-add+ 8 "LLVMOpcode enum value for the integer Add instruction.")
(defconstant +llvm-opcode-mul+ 12 "LLVMOpcode enum value for the integer Mul instruction.")
(defconstant +llvm-opcode-sext+ 32 "LLVMOpcode enum value for the SExt cast instruction.")

;; src/codegen.lisp
(defun %llvm-const-int-value (val)
  "If VAL is an LLVM ConstantInt, its signed value; otherwise NIL."
  (when (and val (not (cffi:null-pointer-p val)))
    (let ((ci (crisp.llvm-bindings::llvm-is-a-constant-int val)))
      (unless (cffi:null-pointer-p ci)
        (crisp.llvm-bindings::llvm-const-int-get-sext-value ci)))))

;; src/codegen.lisp
(defun %llvm-instr-opcode (val)
  "If VAL is an LLVM Instruction, its opcode as an LLVMOpcode integer; otherwise NIL.

   Guarded by LLVMIsAInstruction because LLVMGetInstructionOpcode is an unchecked
   unwrap<Instruction> -- handing it a constant or a function argument crashes the process.  That
   exact trap is what BUG 033 turned out to be, in LLVMInstructionSetDebugLoc."
  (when (and val (not (cffi:null-pointer-p val)))
    (let ((i (crisp.llvm-bindings::llvm-is-a-instruction val)))
      (unless (cffi:null-pointer-p i)
        (crisp.llvm-bindings::llvm-get-instruction-opcode i)))))

;; src/codegen.lisp
(defun %llvm-binop-with-const (val opcode)
  "Match VAL as `<OPCODE> %x, <const>` and return (values %x const), or NIL when it does not match.

   Only the SECOND operand is tested for constness: LLVM canonicalises commutative operations to put
   the constant on the right, and both producers here -- the fragment-index add and the
   fragment-extent multiply -- are built that way explicitly."
  (when (eql (%llvm-instr-opcode val) opcode)
    (let* ((op0 (crisp.llvm-bindings::llvm-get-operand val 0))
           (op1 (crisp.llvm-bindings::llvm-get-operand val 1))
           (c   (%llvm-const-int-value op1)))
      (when c (values op0 c)))))

;; src/codegen.lisp  (REPLACES %coop-tensor-ptr+stride -- 155 Step 4, derived from the LIVE 6-arg
;; overlay copy, not from src/.  The previous append dropped ELEM-LLVM, which is the GEP's element
;; type: defaulting it to f32 scales every 16-bit tile address by 4 instead of 2.  That is the
;; overlay-duplicate-definition trap -- only the LAST copy is live, so an extraction must come from
;; the overlay whenever one exists there.)
(defun %coop-tensor-ptr+stride (builder tensor-val orow ocol layout &optional elem-llvm)
  "From a Crisp tensor STRUCT value, return (values element-ptr stride-i64) for the coop tile whose
   element origin is (OROW, OCOL) -- both i64 LLVM values.  Tensor layout: field0 = parent storage
   {ptr,i64}, field2 = strides [N x i64].  Leading dim = strides[0] (RowMajor) / strides[1]
   (ColMajor).  ELEM-LLVM is the tensor's element type for the GEP and defaults to f32.

   Endeavour 155 Step 4: the flat offset is computed as BASE PLUS DELTA rather than from scratch.
   Each origin arrives as (tile-base + compile-time-fragment-index) * extent, so

       flat = (tb_r*ext_r)*s0 + (tb_c*ext_c)*s1   +   (fr*ext_r)*s0 + (fc*ext_c)*s1

   The first bracket is identical for every fragment of the tile and collapses to one computation;
   each multiply in the second has a compile-time constant operand, which IGC strength-reduces to
   shifts.  Xe has no native 64-bit multiply, so the runtime-by-runtime products in the first
   bracket are the expensive ones -- and there are now two per TILE instead of two per FRAGMENT.

   When an origin does not have that shape the split degrades to (origin, 0) and this emits exactly
   what it always did."
  (let* ((elem (or elem-llvm (llvm-float-type)))
         (i64 (crisp.llvm-bindings::llvm-int64-type))
         (storage (llvm-build-extract-value builder tensor-val 0 "coop_storage"))
         (base    (llvm-build-extract-value builder storage 0 "coop_base"))
         (strides (llvm-build-extract-value builder tensor-val 2 "coop_strides"))
         (s0 (llvm-build-extract-value builder strides 0 "coop_s0"))
         (s1 (llvm-build-extract-value builder strides 1 "coop_s1"))
         (stride (if (= layout 0) s0 s1)))
    (multiple-value-bind (row-base row-delta) (%coop-split-origin builder orow)
      (multiple-value-bind (col-base col-delta) (%coop-split-origin builder ocol)
        (let* ((off0 (llvm-build-mul builder row-base s0 "coop_off0"))
               (off1 (llvm-build-mul builder col-base s1 "coop_off1"))
               (flat (llvm-build-add builder off0 off1 "coop_flat"))
               ;; The deltas are compile-time element counts, so these multiply a runtime stride by
               ;; a CONSTANT -- strength-reducible, unlike the runtime-by-runtime products above.
               (flat (if (zerop row-delta)
                         flat
                         (llvm-build-add builder flat
                                         (llvm-build-mul builder (llvm-const-int i64 row-delta nil)
                                                         s0 "coop_dr")
                                         "coop_flat_r")))
               (flat (if (zerop col-delta)
                         flat
                         (llvm-build-add builder flat
                                         (llvm-build-mul builder (llvm-const-int i64 col-delta nil)
                                                         s1 "coop_dc")
                                         "coop_flat_c"))))
          (log:debug "coop addr: row-delta=~a col-delta=~a hoisted=~a"
                     row-delta col-delta (or (/= row-delta 0) (/= col-delta 0)))
          (cffi:with-foreign-object (idx :pointer 1)
            (setf (cffi:mem-aref idx :pointer 0) flat)
            (values (llvm-build-gep2 builder elem base idx 1 "coop_elem_ptr") stride)))))))

;;;; ============================================================================
;;;; Endeavour 156 Phase 0 — PIN THE SUBGROUP SIZE.
;;;;
;;;; THE HOLE.  Crisp computes a workgroup's warp count as local-size / :simd-width
;;;; (%resolve-workgroup-warp-count, src/mma.lisp), and every :warps mask, warp-id reference and
;;;; per-warp switch arm is built on that number.  But the generated SPIR-V requests NO subgroup
;;;; size: before this change the only OpExecutionMode in a Crisp kernel was 4459 (DenormPreserve).
;;;;
;;;; Unlike CUDA, where a warp is 32 by hardware definition, an Intel subgroup is one hardware
;;;; thread executing the kernel at its COMPILED SIMD width, and IGC chooses that width per kernel
;;;; from {8, 16, 32}.  BMG's subGroupSizes advertises both 16 and 32.  So Crisp was assuming 16
;;;; while IGC decided independently -- and they agree today only by luck of a heuristic.  Verified
;;;; 2026-08-24: both the shipped 16-work-item kernel and the 512-work-item 32-subgroup probe dump
;;;; as ..._simd16_entry_0001.asm, which is the right answer arrived at by the wrong route.
;;;;
;;;; If IGC ever picks SIMD32, a 32-entry :warps mask describes SIXTEEN actual subgroups, every
;;;; switch arm selects the wrong slice, and the kernel is silently wrong.  Endeavour 156 is about
;;;; to make kernels much larger, which is exactly the input that moves IGC's heuristic.
;;;;
;;;; SIMD16 is also the width XMX/DPAS wants on Xe2, so pinning it is not a tradeoff -- it closes a
;;;; hole and asks for the width the matrix engines want anyway.
;;;;
;;;; WHY THE GUARD IS NARROW.  A required subgroup size is a CONTRACT: a workgroup smaller than the
;;;; subgroup, or not a whole multiple of it, is at best a partial subgroup and at worst a compile
;;;; error in the driver.  1028 shipped specs run through this path, many with tiny or
;;;; runtime-derived local sizes.  So the mode is emitted only when all four hold:
;;;;
;;;;     - a hardware profile is active and names a :simd-width
;;;;     - the kernel's local-size is COMPILE-TIME known
;;;;     - total work-items >= the simd width
;;;;     - total work-items is a whole multiple of it
;;;;
;;;; Any kernel failing those emits exactly what it did before.  That deliberately leaves the
;;;; profile-less case unpinned -- %resolve-workgroup-warp-count defaults warp-size to 32 there,
;;;; which is a separate inconsistency and not Phase 0's to fix.
;;;; ============================================================================

;; src/codegen.lisp
(defconstant +spirv-execution-mode-subgroup-size+ 35
  "SPIR-V ExecutionMode SubgroupSize.  Takes one literal operand: the required size.")

;; src/codegen.lisp
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).
   Endeavor 152: stamps cluster dimensions on capable PTX entry points, and records
   the EFFECTIVE extent (warning on degrade) for every entry point on every backend.
   Endeavour 156: pins the SPIR-V subgroup size to the profile's :simd-width.

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module)
           ;; Endeavour 156 Phase 0: so does the subgroup size, and for the same reason --
           ;; the function attribute does not survive the translator.
           (%emit-spirv-subgroup-size-execution-mode func module semantic-function))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0)))

        ;; Endeavor 152: OUTSIDE the case on purpose.  This must run for every entry
        ;; point on every backend -- it is what records the effective cluster extent
        ;; and warns when a declared cluster could not be formed.  Gating it per
        ;; backend is what let the SPIR-V degrade go silent.
        (%apply-cluster-dims-attribute func semantic-function module))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))

;; src/codegen.lisp  (REPLACES %emit-spirv-subgroup-size-execution-mode -- 156 Phase 0, fourth cut)
;;
;; The first cut wrote an !spirv.ExecutionMode entry, exactly as endeavour 126 does for the denorm
;; modes, and the log confirmed it ran -- but the mode never reached the SPIR-V.  The translator
;; drops it: ExecutionMode SubgroupSize (35) requires the SubgroupDispatch capability, which Crisp
;; does not declare, and the translator will not invent a capability to satisfy a raw execution-mode
;; request.  Its supported route from LLVM is the FUNCTION-LEVEL metadata that OpenCL C's
;; __attribute__((intel_reqd_sub_group_size(N))) lowers to; the translator recognises that, emits
;; the execution mode AND declares the capability that makes it legal.
;;
;; Two further traps, both of which produced a stale .spt rather than a loud failure:
;;   - FUNC was passed to llvm-get-module-context, which takes a MODULE.  Unchecked unwrap,
;;     same family as BUG 033.
;;   - llvm-global-set-metadata / llvm-get-md-kind-id-in-context are NOT exported from
;;     crisp.llvm-bindings, so unqualified references are undefined in crisp.compiler.  That
;;     aborted the compile, left the previous .spv in place, and every check read the old file.
;;
;; So this is not "a different way to write the same thing" -- it is the difference between asking
;; for a mode and asking for the FEATURE, and only the latter brings its capability with it.
(defun %emit-spirv-subgroup-size-execution-mode (func module semantic-function)
  "Endeavour 156 Phase 0: pin kernel FUNC's subgroup size to the active hardware profile's
   :simd-width, so the width Crisp ASSUMES when computing warp counts and the width IGC COMPILES
   are the same value by contract rather than by coincidence.

   Attaches !intel_reqd_sub_group_size to the kernel.  The LLVM->SPIR-V translator turns that into
   OpExecutionMode SubgroupSize together with the SubgroupDispatch capability it requires; writing
   the execution mode directly does NOT work, because the capability would be missing and the
   translator silently drops the mode (observed 2026-08-24).

   Emits nothing -- preserving pre-156 behaviour exactly -- unless a profile names a :simd-width and
   the kernel's compile-time local-size is a whole multiple of it that is at least as large.  See
   the Phase 0 header for why that guard is deliberately narrow."
  (let* ((profile (active-hardware-profile))
         (simd    (and profile (getf profile :simd-width)))
         (kname   (semantic-function-name semantic-function))
         (disp    (and kname (gethash kname *kernel-dispatch-declarations*)))
         (dims    (and disp (%hp-local-size-dims (getf disp :local-size))))
         (total   (and dims (reduce #'* dims))))
    (cond
      ((not (integerp simd))
       (log:debug "subgroup-size: no :simd-width in the active profile for ~a; not pinning." kname))
      ((not total)
       (log:debug "subgroup-size: local-size for ~a is not compile-time known; not pinning." kname))
      ((or (< total simd) (not (zerop (mod total simd))))
       (log:info "subgroup-size: local-size ~a for ~a is not a whole multiple of simd-width ~a; not pinning."
                 total kname simd))
      (t
       (let* ((ctx  (llvm-get-module-context module))
              (i32  (llvm-int32-type))
              (name "intel_reqd_sub_group_size")
              (kind (crisp.llvm-bindings::llvm-get-md-kind-id-in-context ctx name (length name)))
              (size-md (llvm-value-as-metadata (llvm-const-int i32 simd 0))))
         (cffi:with-foreign-object (arr :pointer 1)
           (setf (cffi:mem-aref arr :pointer 0) size-md)
           (let ((node (llvm-md-node-in-context2 ctx arr 1)))
             (crisp.llvm-bindings::llvm-global-set-metadata func kind node)))
         (log:info "subgroup-size: pinned ~a to SubgroupSize ~a (local-size ~a = ~a subgroup~:p)."
                   kname simd total (floor total simd)))))))

;; src/compiler.lisp  (REPLACES inject-spir-kernel-metadata -- 156 Phase 0)
;;
;; WHY THIS CHANGED.  This function splices the OpenCL !kernel_arg_* refs into a kernel's define
;; line by taking everything from the signature's closing paren to the opening brace and REPLACING
;; it.  Anything LLVM had already attached to that function is silently discarded -- which is why
;; endeavour 156's !intel_reqd_sub_group_size vanished between the module and the .ll even though
;; the attachment demonstrably ran.
;;
;; The discarded tail is not only ours.  A kernel define line normally carries `#0 !dbg !N` there:
;; the attribute-group reference and the debug-info reference.  Both were being dropped for entry
;; points while every non-kernel function kept them.  That is a very plausible explanation for the
;; endeavour-126 observation that the `denormal-fp-math` function attribute "does NOT reach SPIR-V"
;; -- the attribute was fine; the reference to its attribute group was being deleted here.  126
;; worked around it with an explicit execution mode, which is why denormals still behave correctly
;; and why this went unnoticed.
;;
;; The fix is to APPEND rather than replace: keep whatever LLVM emitted, then add our refs.  That is
;; strictly more information in the IR, and it is what lets function-level metadata survive to the
;; SPIR-V translator at all.
(defun inject-spir-kernel-metadata (ir-text)
  "Inject OpenCL kernel metadata for all SPIR kernels found in IR text.
Returns modified IR text with metadata.

Endeavour 156: PRESERVES any metadata LLVM already attached to the kernel (attribute-group refs,
!dbg, !intel_reqd_sub_group_size) instead of overwriting it -- see the comment above."
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
                        ;; Endeavour 156: keep the existing tail (#N, !dbg, !intel_reqd_sub_group_size,
                        ;; anything else LLVM attached) and append our refs after it.
                        (let ((existing (string-trim '(#\Space #\Tab)
                                                     (subseq result (1+ close-paren-pos) new-brace-pos))))
                          (log:debug "  preserving existing kernel metadata for ~a: ~s" func-name existing)
                          (setf result (concatenate 'string
                                         (subseq result 0 (1+ close-paren-pos))
                                         (if (string= existing "")
                                             ""
                                             (concatenate 'string " " existing))
                                         metadata-refs
                                         " "
                                         (string #\{)
                                         (subseq result (1+ new-brace-pos))))
                          (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                          (setf metadata-id-base next-id))))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))

;; src/mma.lisp  (REPLACES %emit-per-frag-block-load -- 156 Phase 1: integer warp selectors)
(defun %emit-per-frag-block-load (src entry coords)
  "Endeavor 142 — per-fragment expansion of (load-tile SRC <register-tile> COORDS).

   Endeavour 155 Step 2b: when the tile is WARP-SLICED, each warp loads only its own rows (:a) or
   columns (:b), at global coordinates offset by its grid position.  load-tile appears once in the
   body, so the choice is a STATIC per-warp switch -- static so the offsets fold to literals and the
   block-load addresses stay compile-time, which is the same reason 139 step-4 made the MMA walk
   static."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) (operand :acc)) (cdr entry)
    (declare (ignore n-true))
    (let ((cl (find-package :crisp-language)))
      (destructuring-bind (fr . fc) (%frag-mn-for-operand operand (%register-tile-elem-of (first entry)))
        (let* ((frag-fn (ecase operand
                          (:a (intern "LOAD-FRAGMENT-A" cl))
                          (:b (intern "LOAD-FRAGMENT-B" cl))
                          (:acc (error 'crisp-compiler-error
                                  :message "load-tile into an accumulator register-tile is not supported (only :operand :a / :b tiles are load targets)."
                                  :source-location nil))))
               (to-int  (intern "TO-INT" cl))
               (n-rows  (floor m fr))
               (n-cols  (floor n fc))
               (gy      (first coords))
               (gx      (second coords))
               (slice   (%warp-slice-extent entry operand))
               (grid    *warp-grid*))
          (flet ((one (idx row col)
                   `(set! ,(nth idx syms)
                          (,frag-fn ,src
                                    ((+ (* (,to-int ,gy) ,n-rows) ,row)
                                     (+ (* (,to-int ,gx) ,n-cols) ,col))))))
            (if (not (and slice grid))
                `(progn
                   ,@(loop for ri below n-rows append
                           (loop for ci below n-cols
                                 for idx = (+ (* ri n-cols) ci)
                                 collect (one idx ri ci))))
                (let* ((progn-sym (intern "PROGN" cl))
                       (let-sym   (intern "LET" cl))
                       (if-sym    (intern "IF" cl))
                       (lt-sym    (intern "<" cl))
                       (minus-sym (intern "-" cl))
                       (div-sym   (intern "/" cl))
                       (times-sym (intern "*" cl))
                       (warp-id   (intern "WARP-ID" cl))
                       (gn        (cdr grid))
                       (nslice    (if (eq operand :a) (car grid) (cdr grid)))
                       (wp        (gensym "WP"))
                       (sl        (gensym "SL")))
                  (labels ((arm (w)
                             `(,progn-sym
                                ,@(if (eq operand :a)
                                      (loop for lr below slice append
                                            (loop for ci below n-cols
                                                  for idx = (+ (* lr n-cols) ci)
                                                  collect (one idx (+ (* w slice) lr) ci)))
                                      (loop for ri below n-rows append
                                            (loop for lc below slice
                                                  for idx = (+ (* ri slice) lc)
                                                  collect (one idx ri (+ (* w slice) lc)))))))
                           (chain (w)
                             (if (>= w (1- nslice))
                                 (arm w)
                                 `(,if-sym (,lt-sym ,sl ,(1+ w))
                                           ,(arm w)
                                           ,(chain (1+ w))))))
                    `(,let-sym ((,wp (,minus-sym (,to-int (,warp-id)) ,first-true)))
                       ;; 156 Phase 1: INTEGER / and - , not FLOOR/MOD.
                       ;;
                       ;; (intern "FLOOR" :crisp-language) resolves to CRISP.COMPILER:FLOOR, which
                       ;; returns a FLOAT -- %emit-per-frag-store already documents that and moved
                       ;; to / and - for its addresses.  (intern "MOD" :crisp-language) is worse:
                       ;; MOD does not exist there at all, so the intern MINTS a fresh symbol with
                       ;; no operator behind it.  The load switch was never updated with the store.
                       ;;
                       ;; It survived because single-axis slicing never exercises either one: when
                       ;; gm=1 or gn=1 the un-sliced operand emits a bare arm with NO selector, and
                       ;; the sliced one divides by 1, which is exact under any semantics.  A 2-D
                       ;; grid is the first case where a selector divides by something >1 -- which
                       ;; is exactly where MMA_WRONG starts (verified: correct at 1 and 2 warps,
                       ;; wrong from 4; correct at every 1-D-forced shape at 4 warps).
                       (,let-sym ((,sl ,(if (eq operand :a)
                                            `(,div-sym ,wp ,gn)
                                            `(,minus-sym ,wp (,times-sym (,div-sym ,wp ,gn) ,gn)))))
                         ,(chain 0))))))))))))

;; TEMPORARY BISECTION PROBE -- not a fix.  Neuters the Step 4 split so %coop-tensor-ptr+stride
;; emits exactly the pre-155-Step-4 address arithmetic, to determine whether the 256x256 :warps
;; probe's MMA_WRONG is caused by base-plus-delta or was already there.
(defun %coop-split-origin (builder origin)
  "BISECTION STUB: always declines to split."
  (declare (ignore builder))
  (values origin 0))

;; src/mma.lisp  (REPLACES %explode-register-tiles -- 156 Phase 2: rings honour :warps)
(defun %explode-register-tiles (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range).
   Endeavor 145 P3a: also publishes the LET's SLM scratch-tile shapes in *mma-scratch-tile-dims* so
   the accumulate expansion can walk K within a staged tile."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             ;; 145 P3a: SLM tile shapes for the K-step count (special -> dynamically scoped).
             (*mma-scratch-tile-dims* (%mma-scratch-tile-dims-from-bindings bindings))
             ;; 155 Step 2: the warp grid comes from the ACCUMULATOR and governs how the operand
             ;; tiles slice.  First pass over the same bindings; see the Step 2 header.
             (*warp-grid* (%warp-grid-from-bindings bindings context location))
             ;; 155 Phase C: publish each register tile's ELEMENT TYPE for the same reason and by
             ;; the same mechanism -- the load-tile expansion has only the tile entry, which does
             ;; not record it.
             (*register-tile-elems* (%register-tile-elems-from-bindings bindings))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (let* ((form    (second b))
                                 (elem    (second form))   ; 155: element type, was discarded
                                 (dims    (third form))
                                 (init    (fourth form))
                                 (m       (first dims)) (n (second dims))
                                 (operand (getf (nthcdr 4 form) :operand :acc))
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                            (* (floor m fr) (floor n fc))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    ;; 155 Step 2: validate an operand tile against ITS divisor
                                    ;; (gm for :a, gn for :b), not the warp count.
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location
                                                         (and *warp-grid* (member operand '(:a :b))
                                                              (%operand-warp-divisor operand)))
                                    (values 1 0))
                              ;; 155 Step 2: an OPERAND tile slices by the grid axis its warps
                              ;; share, not by the total warp count -- gm slices for A, gn for B.
                              ;; The accumulator keeps n-true.  Guarded on *warp-grid*, so a tile
                              ;; without a distributed accumulator in scope allocates whole.
                              (let* ((div (if (and *warp-grid* mask (member operand '(:a :b)))
                                              (%operand-warp-divisor operand)
                                              n-true))
                                     (per-warp (max 1 (floor nfrags div)))
                                     (syms     (%register-tile-frag-syms (first b) per-warp)))
                                (push (list (first b) m n syms n-true first-true operand) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init :operand ,operand :elem ,elem))))))
                          (if (and (consp b) (= (length b) 2) (symbolp (first b))
                                   (%register-tile-ring-init-form-p (second b)))
                              (let* ((form    (second b))
                                     (elem    (second form))   ; 155: element type, was discarded
                                     (dims    (third form))
                                     (m       (first dims)) (n (second dims))
                                     (keys    (nthcdr 3 form))
                                     (operand (getf keys :operand :acc))
                                     (rc      (getf keys :ring-count))
                                     ;; 156 Phase 2: a RING may carry :warps too.  Without this the
                                     ;; ring branch gave every warp the WHOLE tile and recorded no
                                     ;; slice fields, so :warps on a ring kernel was a silent no-op
                                     ;; -- 32 subgroups each computing the identical tile.  Every
                                     ;; shipped 16-bit kernel is a ring kernel, which is why none of
                                     ;; them could use more than one subgroup whatever local-size said.
                                     (warps-in (getf keys :warps))
                                     (mask     (and warps-in
                                                    (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                  (let ((nfrags (* (floor m fr) (floor n fc))))
                                    ;; Mirror the plain register-tile branch exactly: validate the
                                    ;; mask against the tile's OWN divisor, then give each warp only
                                    ;; its slice, per SLOT.
                                    (multiple-value-bind (n-true first-true)
                                        (if mask
                                            (%validate-warp-mask mask nfrags
                                                                 (%resolve-workgroup-warp-count context)
                                                                 m n location
                                                                 (and *warp-grid* (member operand (list :a :b))
                                                                      (%operand-warp-divisor operand)))
                                            (values 1 0))
                                      (let* ((div (if (and *warp-grid* mask (member operand (list :a :b)))
                                                      (%operand-warp-divisor operand)
                                                      n-true))
                                             (per-warp (max 1 (floor nfrags div)))
                                             (slot-syms-list
                                               (loop for slot below rc
                                                     collect (%register-tile-frag-syms
                                                              (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                      (symbol-package (first b)))
                                                              per-warp))))
                                        (push (list (first b) :ring m n slot-syms-list operand n-true first-true) tiles)
                                        (loop for syms in slot-syms-list
                                              append (loop for s in syms
                                                           collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand :elem ,elem)))))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))

;; src/mma.lisp  (REPLACES %resolve-tile-ref -- 156 Phase 2: ring slots carry n-true/first-true)
(defun %resolve-tile-ref (ref tiles)
  "Endeavor 142: resolve a tile operand REF to a per-slot tiles entry (V m n syms n-true first-true
   operand).  REF is either a bare exploded register-tile symbol, or (ring-get RING SLOT) with a
   COMPILE-TIME integer SLOT into a register-tile-RING (a ring entry is (RSYM :ring m n slot-syms-list
   operand)).  The GRF cannot be runtime-indexed, so a register ring-get with a non-constant slot is a
   hard error here — the Phase-C pipeline supplies static slots by unrolling / phase-flip.  Returns NIL
   if REF names no exploded register tile/ring (a normal scratch operand)."
  (cond
    ((symbolp ref)
     (let ((e (assoc ref tiles)))
       (when (and e (eq (second e) :ring))
         (error 'crisp-compiler-error
           :message (format nil "~a is a register-tile-ring — index it with (ring-get ~a SLOT), it is not a plain tile." ref ref)
           :source-location nil))
       e))
    ((and (consp ref) (%head-name-eq (first ref) "RING-GET") (= (length ref) 3))
     (let ((ring-entry (assoc (second ref) tiles))
           (slot (third ref)))
       (when (and ring-entry (eq (second ring-entry) :ring))
         (destructuring-bind (rsym marker m n slot-syms-list operand
                              &optional (n-true 1) (first-true 0)) ring-entry
           (declare (ignore marker))
           (unless (integerp slot)
             (error 'crisp-compiler-error
               :message (format nil "ring-get into the REGISTER ring ~a needs a compile-time integer slot (the GRF is not runtime-indexable); got ~S.  Unroll the K-loop by :ring-count or use a static phase index."
                                rsym slot)
               :source-location nil))
           (unless (< -1 slot (length slot-syms-list))
             (error 'crisp-compiler-error
               :message (format nil "ring-get slot ~a is out of range 0..~a for ring ~a." slot (1- (length slot-syms-list)) rsym)
               :source-location nil))
           ;; 156 Phase 2: carry the ring's slice fields through instead of the hardcoded
           ;; 1/0, which made every ring slot look unsliced to the emitters.
           (list rsym m n (nth slot slot-syms-list) n-true first-true operand)))))
    (t nil)))


;;;; ============================================================================
;;;; Endeavour 156 — MMA LOWERING SELECTION.
;;;;
;;;; Measured across 155 + 156: the Crisp/SYCL-TLA gap on BMG is a LOWERING gap, not a tuning gap.
;;;; Every geometry the levers can express lands in the same 40-60 TFLOPS band (32x64 single-subgroup
;;;; 60.8, 256x256 over 32 subgroups 34.6, SLM staging 0.9), and the peer is INDIFFERENT to register
;;;; budget -- forced from grf_count 128 with 3904 bytes of spill to 256 with none, it went 185 ->
;;;; 190 TFLOPS at 4096.  Occupancy is not its secret.
;;;;
;;;; What it does instead is not expressible in kernel source: no cooperative-matrix operations at
;;;; all (11 AsmCallINTEL -- hand-written Xe assembly DPAS), the createBlock2DAddressPayload +
;;;; setBlockX/setBlockY load convention, and SPV_INTEL_split_barrier.  Those are codegen choices,
;;;; so Crisp needs a way to NAME a lowering.  This is that surface.
;;;;
;;;; THE RULE THAT MATTERS: REFUSAL, NEVER FALLBACK.  Both endeavours were derailed by silent
;;;; no-ops -- :warps did nothing at all on ring tiles for months, and (intern "MOD" :crisp-language)
;;;; minted a meaningless symbol.  A lowering that quietly downgraded to the portable path would be
;;;; the same failure in better clothes: a slow kernel and no explanation.  Asking for a lowering the
;;;; active profile does not offer is a compile-time error naming both sides.
;;;; ============================================================================

;; src/hardware-profile.lisp
(defparameter *known-mma-lowerings* (list :coop-matrix :xe-native)
  "Every MMA lowering NAME the compiler understands, whether or not a given backend implements it.

   :coop-matrix  SPV_KHR_cooperative_matrix / the portable path.  Implemented; the default.
   :xe-native    Intel Xe: inline-assembly DPAS + the Block2D address-payload load convention.
                 NAMED but NOT YET IMPLEMENTED -- no profile lists it, so requesting it is refused
                 with the profile's actual offering.  It is named here so the value type validates
                 and so the intent is documented in one place.

   A profile's :mma-lowerings is checked against this list, which turns a typo into an error at
   def-hardware-profile time rather than a kernel that silently never selects its lowering.")

;; src/hardware-profile.lisp
(defun %hp-mma-lowerings (profile)
  "The lowerings PROFILE offers, most-preferred first.  Absent means (:coop-matrix) -- the portable
   path every backend has had until now, which keeps every existing profile valid and unchanged."
  (or (and profile (getf profile :mma-lowerings))
      (list :coop-matrix)))

;; src/analysis/control.lisp
(defun %parse-mma-lowering-decl (decl kernel-name profile)
  "Validate a (mma-lowering <keyword>) declaration and return the chosen lowering keyword.

   DECL absent -> the active profile's default (its first :mma-lowerings entry, else :coop-matrix).
   DECL present -> that lowering, if the profile offers it; otherwise a compile-time REFUSAL.

   The refusal is the point.  Silently falling back to the portable path would hand the user a slow
   kernel with no way to tell that their request was ignored -- exactly the failure mode that hid
   :warps-on-a-ring being a no-op through two endeavours."
  (let ((available (%hp-mma-lowerings profile)))
    (if (null decl)
        (first available)
        (let ((v (second decl)))
          (unless (and (= (length decl) 2) (keywordp v))
            (error 'crisp-compiler-error
              :message (format nil "mma-lowering takes exactly one keyword (kernel ~a), e.g. (mma-lowering :coop-matrix).  Got ~S."
                               kernel-name decl)
              :source-location nil))
          (unless (member v *known-mma-lowerings*)
            (error 'crisp-compiler-error
              :message (format nil "mma-lowering ~s is not a lowering Crisp knows (kernel ~a).  Known lowerings: ~{~s~^, ~}"
                               v kernel-name *known-mma-lowerings*)
              :source-location nil))
          (unless (member v available)
            (error 'crisp-compiler-error
              :message (format nil "mma-lowering ~s is not available on the active hardware profile (kernel ~a).  This profile offers: ~{~s~^, ~}.  Crisp REFUSES rather than falling back to a different lowering, because a silent downgrade would give you a slow kernel and no way to see why.  Either pick an offered lowering, or add ~s to the profile's :mma-lowerings once a backend implements it"
                               v kernel-name available v)
              :source-location nil))
          v))))

;; 156 lowering selector: REPLACES *hardware-profile-schema* -- adds :mma-lowerings
(defparameter *hardware-profile-schema*
  '((:simd-width                  . :pos-int)
    (:compute-units               . :pos-int)
    (:max-registers-per-cu        . :pos-int)
    (:max-registers-per-thread    . :pos-int-or-modes)  ; 144 D4: scalar OR (mode ...)
    (:max-total-threads-per-block . :pos-int)
    (:max-concurrent-kernels      . :pos-int)
    (:native-cache-line-size      . :pos-int)   ; bytes
    (:max-shared-memory-per-block . :size)      ; KB/MB/GB/TB literal -> bytes
    (:l2-cache-size               . :size)
    (:tile-visit-strip-width      . :pos-int)   ; 144 Phase 1: measured; absent/1 => linear
    (:max-work-group-dims         . :dims3)     ; (x y z) positive ints
    (:mma-shapes                  . :mma-shapes)  ; list of (M N K) triples
    (:mma-lowerings               . :lowerings))  ; 156: ordered; first is the default
  "Endeavor 130: canonical hardware-profile keys and their value types.

   Endeavour 156 added :mma-lowerings -- the code-generation strategies this hardware can
   drive its matrix engines with, most-preferred first.  Absent means (:coop-matrix), the
   portable SPV_KHR_cooperative_matrix path every backend has had until now.

   Endeavor 144 added two.  :max-registers-per-thread became :pos-int-or-modes (D4) — a scalar
   for a fixed per-thread allocation, or an ascending list of selectable modes for hardware whose
   register file is a JIT-time choice.  :tile-visit-strip-width (Phase 1 revision) is the
   MEASURED column-strip width for grouped tile-stride visit order on this machine; 1 or absent
   means walk linearly.  It is deliberately a measured constant rather than a derived one — see
   the block comment above for the two-device data that refuted the derivation.")

;; 156 lowering selector: REPLACES %hp-validate-value -- adds the :lowerings value type
(defun %hp-validate-value (profile-name key type raw)
  "Validate/normalize RAW for KEY of TYPE.  Signals a clear compile error on a
   malformed value; returns the normalized value (sizes in bytes, lists unquoted).

   Endeavor 144 (D4): :pos-int-or-modes accepts a positive integer OR a list of
   positive integers in STRICTLY ASCENDING order (selectable register-file modes;
   ascending so 'first' is the default mode and 'last' is the largest)."
  (ecase type
    (:pos-int
     (unless (and (integerp raw) (plusp raw))
       (error "def-hardware-profile ~a: key ~a expects a positive integer, got ~s."
              profile-name key raw))
     raw)
    (:pos-int-or-modes
     (let ((v (%hp-unquote raw)))
       (cond
         ((and (integerp v) (plusp v)) v)
         ((and (listp v) v (every (lambda (e) (and (integerp e) (plusp e))) v))
          (unless (apply #'< v)
            (error "def-hardware-profile ~a: key ~a expects selectable modes in strictly ascending order (the first is the default allocation, the last the largest), got ~s."
                   profile-name key raw))
          v)
         (t
          (error "def-hardware-profile ~a: key ~a expects a positive integer or a list of positive integers in ascending order (selectable modes, e.g. (128 256)), got ~s."
                 profile-name key raw)))))
    (:size
     (let ((bytes (%hp-parse-size raw)))
       (unless bytes
         (error "def-hardware-profile ~a: key ~a expects a byte count or size literal (e.g. 227KB, 50MB, 8GB), got ~s."
                profile-name key raw))
       bytes))
    (:dims3
     (let ((d (%hp-unquote raw)))
       (unless (%hp-3-pos-ints-p d)
         (error "def-hardware-profile ~a: key ~a expects a list of 3 positive integers, got ~s."
                profile-name key raw))
       d))
    (:mma-shapes
     (let ((shapes (%hp-unquote raw)))
       (unless (and (listp shapes) shapes (every #'%hp-3-pos-ints-p shapes))
         (error "def-hardware-profile ~a: key ~a expects a non-empty list of (M N K) positive-integer triples, got ~s."
                profile-name key raw))
       shapes))
    ;; 156: an ordered list of code-generation strategies, most-preferred first.  Validated against
    ;; the names the COMPILER knows, so a typo is caught in the profile rather than surfacing later
    ;; as a kernel that mysteriously will not select its lowering.
    (:lowerings
     (let ((ls (%hp-unquote raw)))
       (unless (and (listp ls) ls (every #'keywordp ls))
         (error "def-hardware-profile ~a: key ~a expects a non-empty list of lowering keywords, got ~s."
                profile-name key raw))
       (let ((bad (remove-if (lambda (l) (member l *known-mma-lowerings*)) ls)))
         (when bad
           (error "def-hardware-profile ~a: key ~a names unknown lowering~p ~{~s~^, ~}.  Known lowerings: ~{~s~^, ~}."
                  profile-name key (length bad) bad *known-mma-lowerings*)))
       ls))))

;; 156 lowering selector: REPLACES internal-def-function -- parses (mma-lowering ...)
(defun internal-def-function (name params declarations body location)
  "Endeavor 152: binds *current-kernel-cluster-dims* and *current-kernel-is-backward* around the
   body analysis.  Otherwise identical to the Phase 2 definition."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d) (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d) (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*))
           (*current-kernel-is-backward*
             (and name (symbolp name)
                  (let ((n (symbol-name name)))
                    (and (>= (length n) 5)
                         (string-equal "_GRAD" (subseq n (- (length n) 5)))))))
           (cluster-dims nil))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))
      (when is-entry-p
        (let* ((global-size-decl (find "GLOBAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (local-size-decl  (find "LOCAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (num-groups-decl  (find "NUM-GROUPS" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (cluster-size-decl (find "CLUSTER-SIZE" declarations
                                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                        :test #'string-equal))
               ;; 156: (mma-lowering :xe-native) -- which code-generation strategy this kernel wants
               ;; for its matrix-engine operations.  Parsed here so an unavailable request is refused
               ;; at analysis time, next to the other dispatch declarations.
               (mma-lowering-decl (find "MMA-LOWERING" declarations
                                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                        :test #'string-equal))
               (mma-lowering (%parse-mma-lowering-decl mma-lowering-decl name
                                                       (active-hardware-profile))))
          (setf cluster-dims (%parse-cluster-size-decl cluster-size-decl name declarations))
          (when (or global-size-decl local-size-decl num-groups-decl cluster-size-decl
                    mma-lowering-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl))
                            (when cluster-size-decl (list :cluster-size-decl cluster-size-decl))
                            (when cluster-dims      (list :cluster-size cluster-dims))
                            ;; Recorded even when defaulted, so the metacrisp -- and therefore any
                            ;; benchmark row -- can say which lowering produced a number.  A figure
                            ;; you cannot attribute to a code path is not evidence.
                            (when mma-lowering      (list :mma-lowering mma-lowering)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))
          (%hp-check-workgroup-bounds name local-size-decl (active-hardware-profile))))
      (let ((*current-kernel-cluster-dims* cluster-dims))
        (internal-compile-function name explicit-env return-type params body declarations
                                   location *compiler-context*)))))
