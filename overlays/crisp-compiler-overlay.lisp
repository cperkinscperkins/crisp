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



;;;; ####################################################################################
;;;; ####  BEGIN CACHE-CONTROL BLOCK — READ THIS BEFORE FOLDING ANY OF IT INTO src/  ####
;;;; ####################################################################################
;;;;
;;;; Everything from here to the matching END fence is endeavour-158-adjacent probe machinery
;;;; from 2026-08-27.  It is INERT unless CRISP_CACHE_CONTROL is set, so it is harmless where it
;;;; sits — but it must NOT be folded into src/ wholesale, because the three pieces in it have
;;;; three different verdicts.
;;;;
;;;; ---- 1. THE FEATURE IT TESTS IS DEAD. -----------------------------------------------
;;;; Cache control was MEASURED and does nothing: -3.3% at N=4096 where the six-repeat spread is
;;;; 3.1%, and -0.8% at 2048.  The arm was verified genuine, not inert — the container built
;;;; probe_loads_cc.spv with 58x `CacheControlLoadINTEL 0 1` + 58x `1 1` plus the capability and
;;;; extension, against zero in the byte-identical probe_loads.spv.  So either IGC does not
;;;; consult a pointer decoration when lowering OpCooperativeMatrixLoadKHR, or the driver default
;;;; already matched SYCL-TLA's kL1C_L3C.  DO NOT RE-LITIGATE THIS WITHOUT NEW INFORMATION;
;;;; see benchmarks/matmul/_probe_roofline/README.md for the numbers.
;;;;
;;;; ---- 2. ONE PIECE IS PROVABLY DEAD CODE. --------------------------------------------
;;;; %attach-cache-control-load attaches the decoration during CODEGEN, and -O3 strips every one
;;;; of them (measured: 64 decorated GEPs in .temp.ll, 0 in .opt.ll).  It cannot work and never
;;;; will while the opt pipeline runs.  It is retained ONLY because it documents where the
;;;; decoration would naturally belong if LLVM ever preserved !spirv.Decorations.
;;;; >>> DECISION NEEDED AT FOLD TIME: delete it, or keep it with this comment attached.
;;;; Keeping unreachable code that looks reachable is its own hazard.
;;;;
;;;; ---- 3. ONE PIECE IS GENUINELY WORTH KEEPING. ---------------------------------------
;;;; %inject-cache-control-decorations is the mechanism that actually works, and the finding
;;;; behind it generalises well past cache control: **a SPIR-V decoration cannot be attached in
;;;; codegen at all — it must be re-attached AFTER opt**, as a text pass over the .ll, in the
;;;; same slot as inject-spir-kernel-metadata.  ANY future decoration Crisp wants to emit hits
;;;; this wall.  That mechanism should survive even if the cache-control feature is deleted.
;;;;
;;;; ---- 4. THE HIGHEST-RISK ITEM IS THE compile-to-spirv COPY. --------------------------
;;;; compile-to-spirv below is a WHOLE-FUNCTION copy of the src/compiler.lisp original with two
;;;; small additions: one call to %inject-cache-control-decorations, and one conditional
;;;; --spirv-ext=+SPV_INTEL_cache_controls (which is load-bearing: llvm-spirv REFUSES with
;;;; "RequiresExtension" rather than silently dropping the decoration).  A whole-function copy
;;;; DRIFTS: any edit to the src/ original is silently lost as long as this file loads last.
;;;; >>> AT FOLD TIME, DIFF THIS AGAINST src/compiler.lisp's compile-to-spirv BEFORE MERGING.
;;;;
;;;; ---- 5. GATING. ---------------------------------------------------------------------
;;;; CRISP_CACHE_CONTROL           l1c_l3c | l1s_l3c | l1uc_l3c | l1c_l3uc  (unset = no-op)
;;;; CRISP_CACHE_CONTROL_KERNELS   comma-separated source stems, exact match; unset = all
;;;; With CRISP_CACHE_CONTROL unset the emitted SPIR-V is byte-identical to before: zero
;;;; decorations, zero capability, zero extension.  No shipped kernel is affected.
;;;;
;;;; ####################################################################################
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
          ;; BOTH the coop-matrix load AND the 2D block PREFETCH.  The prefetch was omitted the
          ;; first time round, which is the operation whose entire job is warming cache -- so the
          ;; "cache control does nothing" result of 2026-08-27 was measured with the prefetch
          ;; undecorated.  SYCL-TLA asks for kL1C_L3C on its prefetches as well as its loads, at
          ;; all 26 call sites.  The pointer is the FIRST argument of the load and the FIFTH of
          ;; the prefetch, so find it positionally rather than assuming it leads.
          (loop for l across lines do
            (when (or (search "@__spirv_CooperativeMatrixLoadKHR" l)
                      (search "@__spirv_Subgroup2DBlockPrefetchINTEL" l))
              (let ((p (search "ptr addrspace(" l)))
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


;;;; ####################################################################################
;;;; ####  END CACHE-CONTROL BLOCK                                                   ####
;;;; ####                                                                            ####
;;;; ####  Summary of the four decisions the BEGIN fence spells out:                 ####
;;;; ####    1. the FEATURE is dead (measured -3.3%, inside the 3.1% spread)          ####
;;;; ####    2. %attach-cache-control-load is DEAD CODE (-O3 strips it) - keep/kill?  ####
;;;; ####    3. %inject-cache-control-decorations is the WORTH-KEEPING mechanism      ####
;;;; ####    4. compile-to-spirv is a whole-function COPY - diff before merging       ####
;;;; ####################################################################################

;;;; ============================================================================
;;;; prefetch-tile :warp-partitioned -- distribute a prefetch footprint across subgroups.
;;;; Endeavour 158.  Specs: tests/spec/158-prefetch-warps/.
;;;;
;;;; WHY.  Round-2 arm B measured prefetch at 2.6-2.9x SLOWER at the shipped 16-subgroup geometry.
;;;; That is not a result about prefetch: prefetch-tile had no notion of warps, so EVERY one of the
;;;; 16 subgroups issued EVERY one of the 24 prefetches -- 384 per workgroup per K-step against 256
;;;; loads.  SYCL-TLA slices its prefetch per thread (`prefetch_a.get_slice(thread_idx)`); Crisp
;;;; could not express that, which made the measurement uninterpretable.
;;;;
;;;; ONE BOOLEAN, NOT A MASK.  make-register-tile's :warps mask carries real information because
;;;; under warp specialization some warps genuinely do not hold the tile.  A prefetch has NO
;;;; destination, so there is nothing a warp can fail to hold; a mask there would be all-true in
;;;; every kernel forever -- a keyword that can only be got wrong.
;;;;
;;;; :size IS THE FOOTPRINT, not a hardware block.  It is in the same units as the matching
;;;; load-tile, which is what makes the two lines legible side by side:
;;;;     (prefetch-tile A (grid-y prefetch-k) :size (128 32) :warp-partitioned true)
;;;;     (load-tile     A A-tile (grid-y grid-k))
;;;; The compiler tiles the footprint into legal hardware blocks and deals them out.  The user
;;;; never writes a block index.
;;;;
;;;; BRANCH-FREE, DELIBERATELY.  The first prototype dispatched with a per-warp `when` chain and
;;;; hit BUG 051: sibling `when`s each holding one prefetch-tile emit only ONE prefetch, and a
;;;; nested `if` chain emits ZERO.  Each warp instead COMPUTES its own block index from warp-id,
;;;; which is what the peer does anyway (get_slice is index arithmetic, not a switch), generates
;;;; far less code, and cannot trip 051.
;;;; ============================================================================

;; src/mma.lisp
(defun %prefetch-block-shape (elem-bytes location)
  "The legal Subgroup2DBlockPrefetchINTEL block shape (ROWS . COLS) for an ELEM-BYTES element.

   Only 2-byte elements are supported, and that is a REFUSAL rather than a guess: the legal shape
   is element-width dependent, a 16-bit block is at most 16 COLUMNS wide, and an illegal :size
   resolves to an IGC builtin that does not exist (e.g.
   __internal_intel_sub_group_2d_block_prefetch_16b_32r32x1c).  That fails at MODULE BUILD, long
   after compilation, with a message about a missing symbol rather than about the kernel -- see
   benchmarks/matmul/_kdepth/pf1_k32.crisp.  Refusing here converts it into a compile-time error
   that names the cause.

   32x16 is the shape verified in use.  A 16x16 block would let a 128x32 footprint tile into
   exactly 16 blocks -- one per warp, with no duplication (see %prefetch-warp-plan) -- but its
   legality is unverified and can only be established on metal, so it is not assumed here."
  (case elem-bytes
    (2 (cons 32 16))
    (t (error 'crisp-compiler-error
         :message (format nil "prefetch-tile :warp-partitioned is implemented for 2-byte operands ~
                               (bfloat16 / half) only, got a ~a-byte element.  The legal 2D block ~
                               prefetch shape is element-width dependent, and an illegal one fails ~
                               at MODULE BUILD rather than at compile time, so Crisp refuses rather ~
                               than guessing.  Omit :warp-partitioned to keep the unpartitioned ~
                               one-block-per-subgroup behaviour." elem-bytes)
         :source-location location))))

;; src/mma.lisp
(defun %prefetch-warp-plan (h w br bc n-warps location)
  "Plan the distribution of an H x W footprint over N-WARPS, in BR x BC hardware blocks.
   Returns (values NBY NBX N-BLOCKS ROUNDS).

   ROUNDS is how many prefetches each warp issues: ceiling(n-blocks / n-warps).  Warp w handles
   block (w + j*n-warps) mod n-blocks for j below ROUNDS.

   THE `mod n-blocks` IS LOAD-BEARING AND IS NOT A ROUNDING ERROR.  Irregularity is the normal
   case, not an edge case -- in the shipped fp16 geometry the A footprint (128x32) is 8 blocks over
   16 warps while the B footprint (32x256) is exactly 16.  Both occur in ONE kernel.  When there
   are fewer blocks than warps the surplus warps re-prefetch a block someone else already asked
   for.  That DUPLICATION IS DELIBERATE: a prefetch is a hint, so the cost is one instruction and a
   second touch of an already-warm line, whereas the alternative -- letting surplus warps idle --
   needs a branch, and a branch around a prefetch is BUG 051."
  (unless (and (plusp h) (plusp w) (zerop (mod h br)) (zerop (mod w bc)))
    (error 'crisp-compiler-error
      :message (format nil "prefetch-tile :warp-partitioned: a ~ax~a footprint does not tile into ~
                            whole ~ax~a hardware prefetch blocks.  H must be a multiple of ~a and W ~
                            a multiple of ~a.  Rounding the footprint up would prefetch memory the ~
                            kernel never reads; truncating it would leave part of the operand ~
                            unwarmed and silently cost the speed the keyword exists to buy."
                       h w br bc br bc)
      :source-location location))
  (let* ((nby (floor h br))
         (nbx (floor w bc))
         (n-blocks (* nby nbx))
         (rounds (ceiling n-blocks n-warps)))
    (values nby nbx n-blocks rounds)))

;; src/mma.lisp  (REPLACES analyze-prefetch-tile -- adds the optional :warp-partitioned key.
;; With the key absent the behaviour is byte-identical to before, which spec 02 pins.)
(defun analyze-prefetch-tile (expr env context location)
  "Endeavor 142 (Phase B): (prefetch-tile SRC (COORD-Y COORD-X) :size (H W) &key warp-partitioned)
   -> an Intel 2D block cache prefetch (Subgroup2DBlockPrefetchINTEL).  A fire-and-forget hint with
   NO destination -- it warms the LSC so a subsequent register block-load (load-tile -> GRF) hits
   cache instead of stalling on global memory; it never changes results.  Intel/SPV-only +
   hardware-profile-required.  Lowered by reusing the coop-op node with a :prefetch kind.

   Endeavour 158: :warp-partitioned distributes the footprint across the workgroup's warps, each
   warp computing its own block index from warp-id.  See the block comment above."
  (unless (active-hardware-profile)
    (error 'crisp-compiler-error
      :message "prefetch-tile requires a hardware profile (pass --hardware-profile): its L1 / GRF limits drive the register-pipeline safety analysis."
      :source-location location))
  (unless (eq *target-backend* :spirv)
    (error 'crisp-compiler-error
      :message "prefetch-tile lowers to Subgroup2DBlockPrefetchINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping (NVIDIA's prefetch model is cp.async into SLM, a different concept)."
      :source-location location))
  (destructuring-bind (src coords &key size warp-partitioned) (cdr expr)
    (unless (and (listp coords) (= (length coords) 2))
      (error 'crisp-compiler-error
        :message (format nil "prefetch-tile: coords must be a two-element (COORD-Y COORD-X), got ~S" coords)
        :source-location location))
    (unless (and (listp size) (= (length size) 2) (every #'integerp size))
      (error 'crisp-compiler-error
        :message (format nil "prefetch-tile: :size must be a compile-time (H W) of integers, got ~S" size)
        :source-location location))
    (let* ((h (first size)) (w (second size))
           (ty (first coords)) (tx (second coords))
           ;; `true` reads as a symbol; accept 1 as well, matching %normalize-warp-mask.
           (partition-p (and warp-partitioned
                             (not (eql warp-partitioned 0))
                             (not (and (symbolp warp-partitioned)
                                       (string-equal (symbol-name warp-partitioned) "FALSE"))))))
      (if (not partition-p)
          ;; ---- unpartitioned: one block, every subgroup issues it.  UNCHANGED. ----
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (make-semantic-coop-op
             :type 'void :kind :prefetch
             :tensor-node tnode
             :rows h :cols w :use 0 :layout (%coop-layout-of tnode)
             :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
             :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
             :source-location location))
          ;; ---- partitioned: tile the footprint, each warp computes its own block index ----
          (let ((n-warps (%resolve-workgroup-warp-count context)))
            (unless n-warps
              (error 'crisp-compiler-error
                :message "prefetch-tile :warp-partitioned needs the workgroup's warp count (local-size / simd-width), and this kernel's local-size is not known at compile time.  Declare (local-size :set-to N).  Crisp refuses rather than falling back to an unpartitioned prefetch, because that fallback is exactly the every-subgroup-issues-everything behaviour the keyword exists to remove -- it would be a silent 16x over-issue rather than an error."
                :source-location location))
            (let* ((tnode (analyze-expression src env context (append location '(1))))
                   (elem-bytes (%elem-bytes (%coop-elem-of tnode)))
                   (shape (%prefetch-block-shape elem-bytes location))
                   (br (car shape)) (bc (cdr shape)))
              (multiple-value-bind (nby nbx n-blocks rounds)
                  (%prefetch-warp-plan h w br bc n-warps location)
                (let* ((cl        (find-package :crisp-language))
                       (progn-sym (intern "PROGN" cl))    (let-sym    (intern "LET" cl))
                       (plus-sym  (intern "+" cl))        (times-sym  (intern "*" cl))
                       (div-sym   (intern "/" cl))        (rem-sym    (intern "REM" cl))
                       (to-int-sym (intern "TO-INT" cl))  (warp-id-sym (intern "WARP-ID" cl))
                       (pf-sym    (intern "PREFETCH-TILE" cl))
                       (wp (gensym "WP")) (by (gensym "BY")) (bx (gensym "BX")))
                  (log:debug "prefetch-tile :warp-partitioned: ~ax~a -> ~ax~a blocks of ~ax~a, ~a block~:p ~
                              over ~a warps, ~a round~:p each" h w nby nbx br bc n-blocks n-warps rounds)
                  (labels ((bi (j)
                             ;; this warp's block index for round J: (wp + j*n-warps) mod n-blocks
                             (let ((raw (if (zerop j) wp `(,plus-sym ,wp ,(* j n-warps)))))
                               `(,rem-sym ,raw ,n-blocks))))
                    (analyze-expression
                     `(,let-sym ((,wp (,to-int-sym (,warp-id-sym)))
                                 (,by (,to-int-sym ,ty))
                                 (,bx (,to-int-sym ,tx)))
                        (,progn-sym
                         ,@(loop for j below rounds
                                 collect `(,pf-sym ,src
                                                   ((,plus-sym (,times-sym ,by ,nby)
                                                               (,div-sym ,(bi j) ,nbx))
                                                    (,plus-sym (,times-sym ,bx ,nbx)
                                                               (,rem-sym ,(bi j) ,nbx)))
                                                   :size (,br ,bc)))))
                     env context location))))))))))


;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 158 validators.  Same two-package delegation as 152/155/157: the body lives in
;;;; :crisp.compiler, and tests/run-specs.lisp (or overlays/spec-runner-overlay.lisp) defines a
;;;; same-named stub that funcalls into it, so the two can never drift.
;;;;
;;;; WHY A VALIDATOR AND NOT A BENCHMARK.  A 16x over-issued prefetch is still numerically CORRECT,
;;;; so no correctness check can catch it, and a timing can only say that something is wrong, never
;;;; what.  That is exactly why round-2 arm B measured 2.6x slower and was uninterpretable.  The
;;;; property has to be asserted on the emitted SPIR-V.
;;;; ---------------------------------------------------------------------------------------------

;; src/mma.lisp
(defun %spv-prefetch-shapes (txt)
  "List of (BLOCK-WIDTH . BLOCK-HEIGHT) for every Subgroup2DBlockPrefetchINTEL in TXT, with the
   constant IDs resolved to integers.  Operand order is
     ElementSize BlockWidth BlockHeight BlockCount SrcBase MemWidth MemHeight MemPitch Coord
   and %spv-lines keeps the leading word-count token, so BlockWidth is the FOURTH token and
   BlockHeight the FIFTH.

   Resolution goes through the EXISTING %spv-int-constants (src/mma.lisp), which returns an ALIST.
   An earlier version of this file defined its own hash-table-returning %spv-int-constants and
   silently clobbered that one, breaking validate-spv-bf16-coop / -fp16-coop with \"hash-table is
   not of type LIST\".  Check for an existing definition before adding a helper to this overlay."
  (cl:let ((consts (%spv-int-constants txt))
           (out    cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "Subgroup2DBlockPrefetchINTEL")
                       (cl:>= (cl:length toks) 5))
        (cl:push (cl:cons (cl:cdr (cl:assoc (cl:fourth toks) consts :test #'cl:string=))
                          (cl:cdr (cl:assoc (cl:fifth toks)  consts :test #'cl:string=)))
                 out)))))

;; src/mma.lisp
(defun %validate-prefetch-shape-list (shapes expected-count where)
  "Shared body for both 158 validators: SHAPES must have EXPECTED-COUNT entries and every one must
   be the 32x16 hardware block.  WHERE names the rung for the failure message."
  (cl:let ((ok cl:t))
    (cl:unless (cl:= (length shapes) expected-count)
      (format t "FAIL: ~a -- expected ~a Subgroup2DBlockPrefetchINTEL instruction~:p, found ~a.~%"
              where expected-count (length shapes))
      (cl:setf ok cl:nil))
    (cl:loop for s in shapes
             for n from 0
             do (cl:unless (cl:and (eql (car s) 16) (eql (cdr s) 32))
                  (format t "FAIL: ~a -- prefetch ~a has block shape ~ax~a, expected the 32x16 ~
                             HARDWARE block.  A shape equal to the :size FOOTPRINT means the ~
                             compiler passed the footprint straight through instead of tiling it, ~
                             and an illegal shape fails at MODULE BUILD rather than here.~%"
                          where n (cdr s) (car s))
                  (cl:setf ok cl:nil)))
    ok))

;; src/mma.lisp
(defun validate-spv-prefetch-partitioned (spv-path)
  "Endeavour 158 rung 01 — :warp-partitioned actually distributed the footprint.

   The kernel prefetches a 128x256 footprint, which is 4x16 = 64 blocks of 32x16, over 16 warps.
   That is 4 ROUNDS, so exactly FOUR prefetch instructions must be emitted, each of the hardware
   shape.  Partitioned: 4 static instructions x 16 warps = 64 issues, covering 64 blocks once
   each.  Unpartitioned, the same coverage needs 64 static forms that EVERY warp runs = 1024
   issues.  That 16x is what made round-2 arm B read 2.6x slower, and no correctness check can
   see it."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- prefetch-partitioned check skipped)~%") cl:t)
        (%validate-prefetch-shape-list (%spv-prefetch-shapes txt) 4 "158/01 :warp-partitioned"))))

;; src/mma.lisp
(defun validate-spv-prefetch-unpartitioned (spv-path)
  "Endeavour 158 rung 02 — prefetch-tile WITHOUT :warp-partitioned is untouched.

   A regression guard, not a feature test.  Adding a keyword to a form that has never had one is
   exactly the change that quietly alters the path without it, and every prefetch kernel Crisp has
   shipped (benchmarks/matmul/_kdepth/pf*.crisp, sec4_fused_relu) takes that path.  A 32x16 :size
   must still emit exactly ONE prefetch of that shape, issued by every subgroup."
  (cl:let ((txt (%spv-disasm spv-path)))
    (cl:if (cl:null txt)
        (cl:progn (format t "  (llvm-spirv unavailable -- prefetch-unpartitioned check skipped)~%") cl:t)
        (%validate-prefetch-shape-list (%spv-prefetch-shapes txt) 1 "158/02 unpartitioned"))))
