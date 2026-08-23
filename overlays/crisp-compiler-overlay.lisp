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
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
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
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                            (* (floor m fr) (floor n fc))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location)
                                    (values 1 0))
                              (let* ((per-warp (floor nfrags n-true))
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
                                     (rc      (getf keys :ring-count)))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                  (let* ((nfrags (* (floor m fr) (floor n fc)))
                                         (slot-syms-list
                                           (loop for slot below rc
                                                 collect (%register-tile-frag-syms
                                                          (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                  (symbol-package (first b)))
                                                          nfrags))))
                                    (push (list (first b) :ring m n slot-syms-list operand) tiles)
                                    (loop for syms in slot-syms-list
                                          append (loop for s in syms
                                                       collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand :elem ,elem)))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))



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


;; src/mma.lisp
(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; A = MxK; layout from the tensor's :contiguous-term.
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sn))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
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


;; src/mma.lisp
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
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sm))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
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



;; src/compiler.lisp
(defun %module-uses-bfloat-p (module)
  "T if MODULE contains the LLVM `bfloat` TYPE — used to add --spirv-ext=+SPV_KHR_bfloat16 only
   when needed, matching how the coop-matrix and 2d-block-io extensions are gated.

   Endeavour 155.  Once the element type actually reaches codegen, a bf16 register tile lowers to
   `target(\"spirv.CooperativeMatrixKHR\", bfloat, ...)`, and llvm-spirv refuses the module without
   this extension:

       RequiresExtension: Feature requires the following SPIR-V extension:
        SPV_KHR_bfloat16

   MATCHES THE TYPE, NOT THE SUBSTRING.  Crisp mangles element types into parameter names, so a
   bf16 kernel's IR contains `parent__tensor_bfloat16_2_global_compact_last` whether or not any
   bfloat VALUE exists — which is exactly what it looked like BEFORE this endeavour, when every
   matrix was silently float32.  A bare (search \"bfloat\" ir) would therefore report true for a
   module containing no bfloat type at all.  Requiring the next character to be a non-identifier
   character separates the type token `bfloat,` / `bfloat)` / `bfloat ` from the name fragment
   `bfloat16_2_...`.

   NOTE the CL: qualifications.  :crisp.compiler SHADOWS char (it is the Crisp scalar TYPE, not
   the accessor) and return, among others — see the shadow list in src/package.lisp.  The sibling
   predicates here use RETURN-FROM for the same reason."
  (cl:let* ((ir  (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
            (len (cl:length ir))
            (pos 0))
    (cl:loop
      (cl:let ((i (cl:search "bfloat" ir :start2 pos)))
        (cl:unless i (return-from %module-uses-bfloat-p nil))
        (cl:let* ((after (cl:+ i 6))
                  (ch    (cl:when (cl:< after len) (cl:char ir after))))
          (cl:when (cl:or (cl:null ch)
                          (cl:not (cl:or (cl:alphanumericp ch) (cl:char= ch #\_))))
            (return-from %module-uses-bfloat-p t)))
        (cl:setf pos (cl:1+ i))))))

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


;; src/mma.lisp
(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, 0) -> the MxN accumulator coop matrix.

   Endeavour 155.  The declared operand types are now taken from the ACTUAL VALUES via
   LLVMTypeOf, not rebuilt from a single ELEM-LLVM applied to all three.

   WHY.  A mixed-precision MMA has two element types, not one: XMX/DPAS and the NVIDIA tensor
   cores take bf16 (or fp16) OPERANDS and accumulate in fp32.  Rebuilding A, B and C from one
   element type can only ever express the uniform case, so once the operand loads started
   producing bfloat matrices the declaration still said float and llvm-spirv refused the module:

       FunctionPointers: Can't translate function pointer:
        declare target(\"spirv.CooperativeMatrixKHR\", float, 3, 8, 16, 2)
          @__spirv_CooperativeMatrixMulAddKHR(target(...float, 3, 8, 8, 0), ...)

   Deriving from the values makes the declaration correct BY CONSTRUCTION: whatever A, B and C
   actually are is what gets declared, so the signature cannot drift from the operands again --
   including for the fp32 case, where this is exactly what it built before.

   ELEM-LLVM is retained (unused) so the lambda list is unchanged for any other caller; M, N and
   K likewise remain for the fp32 path's shape, though the shapes now come from the values too."
  (declare (ignorable elem-llvm m n k))
  (let* ((a-ty (crisp.llvm-bindings::llvm-type-of a-val))
         (b-ty (crisp.llvm-bindings::llvm-type-of b-val))
         (c-ty (crisp.llvm-bindings::llvm-type-of c-val))
         (i32  (crisp.llvm-bindings::llvm-int32-type)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))


;;; ===================================================================
;;; ENDEAVOUR 155 — spec validator for the bf16 coop-matrix lowering.
;;;
;;; Lives in :CRISP.COMPILER and takes ONE argument, because that is what the --ir-target=spv
;;; runner path does: it resolves the validator name with (find-symbol ... :crisp.compiler) and
;;; calls it with the OUTPUT PATH.  (The PTX path resolves in :crisp.spec-runner and passes two
;;; arguments -- a long-standing asymmetry noted in endeavour 152.)
;;; ===================================================================

;; tests/run-specs.lisp  (spv validators are resolved in :crisp.compiler)
(defun validate-spv-bf16-coop (spv-path)
  "Endeavour 155 — assert a bf16 register tile reached the hardware AS bf16.

   THE ASSERTION A COMPILE CHECK CANNOT MAKE.  Before 155 the element type was discarded at
   make-register-tile, so a bf16 kernel compiled cleanly, emitted a valid .spv and ran — with
   every cooperative matrix silently float32.  The only symptom was benchmark result files
   containing `results: []`, which went unchased through six re-runs.  Exit codes cannot see
   this; only the emitted types can.

   Asserts, on the disassembled module:
     1. a 16-bit float type exists              — bf16 reached codegen at all
     2. a cooperative matrix names it           — it reached the MMA operands, not just the module
     3. a 32-bit float type ALSO exists         — the accumulator is still fp32
     4. SPV_KHR_bfloat16 is declared            — the module is self-consistent

   (3) is not padding.  Mixed-precision MMA is bf16 operands with an fp32 accumulator, so an
   all-bf16 module would be as wrong as the all-f32 one it replaced.  This fails both directions.

   DEGRADES TO PASS when llvm-spirv is unavailable (a CUDA-only box has no bundled bin/), matching
   %spv-contains-opcode-p: returns NIL only when the module WAS disassembled and the property is
   definitively absent."
  (cl:let* ((tool (resolve-tool-executable "llvm-spirv"))
            (txt-path (cl:format cl:nil "~a.155txt" (uiop:native-namestring spv-path))))
    (cl:multiple-value-bind (o e code)
        (uiop:run-program (cl:list (uiop:native-namestring tool) "--to-text"
                                   (uiop:native-namestring spv-path) "-o" txt-path)
                          :output :string :error-output :string :ignore-error-status cl:t)
      (cl:declare (cl:ignore o e))
      (cl:if (cl:or (cl:not (cl:zerop code)) (cl:not (probe-file txt-path)))
          (cl:progn
            (cl:format cl:*error-output*
                       "  (validate-spv-bf16-coop: llvm-spirv unavailable or failed — SKIPPING, not failing)~%")
            cl:t)
          (cl:let ((txt (uiop:read-file-string txt-path)))
            (cl:ignore-errors (cl:delete-file txt-path))
            ;; SPIR-V text form: "<id> TypeFloat <result-id> <width>" and
            ;; "<n> TypeCooperativeMatrixKHR <result> <component-type-id> ..."
            (cl:let* ((f16-ids (%spv-float-ids txt 16))
                      (f32-ids (%spv-float-ids txt 32))
                      (coop-16 (cl:some (cl:lambda (id) (%spv-coop-uses-p txt id)) f16-ids))
                      (has-ext (cl:search "SPV_KHR_bfloat16" txt)))
              (cl:cond
                ((cl:null f16-ids)
                 (cl:format cl:*error-output* "FAIL: no 16-bit float type in the module — the bf16 element type was discarded before codegen (the pre-155 behaviour: every matrix became float32).~%")
                 cl:nil)
                ((cl:not coop-16)
                 (cl:format cl:*error-output* "FAIL: a 16-bit float type exists but NO cooperative matrix uses it — bf16 reached the module but not the MMA operands.~%")
                 cl:nil)
                ((cl:null f32-ids)
                 (cl:format cl:*error-output* "FAIL: no 32-bit float type — a bf16 MMA accumulates in fp32, so an all-bf16 module is as wrong as an all-f32 one.~%")
                 cl:nil)
                ((cl:not has-ext)
                 (cl:format cl:*error-output* "FAIL: module contains bfloat but does not declare SPV_KHR_bfloat16 — llvm-spirv would refuse it.~%")
                 cl:nil)
                (cl:t cl:t))))))))

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
(defun %spv-coop-matrices (txt)
  "List of (RESULT-ID COMPONENT-WIDTH USE) for every TypeCooperativeMatrixKHR in TXT.

   COMPONENT-WIDTH is resolved through OpTypeFloat and USE through OpConstant, so the caller gets
   the two things it actually wants to assert about — how wide is it, and what is it for — rather
   than raw ids.  Either may be NIL when the operand is not a float type or not a resolvable
   constant; callers must treat NIL as 'unknown', never as 'fine'."
  (cl:let ((floats (%spv-float-widths txt))
           (consts (%spv-int-constants txt))
           (out cl:nil))
    (cl:dolist (toks (%spv-lines txt) (cl:nreverse out))
      (cl:when (cl:and (cl:string= (cl:second toks) "TypeCooperativeMatrixKHR")
                       (cl:>= (cl:length toks) 8))
        (cl:push (cl:list (cl:third toks)
                          (cl:cdr (cl:assoc (cl:fourth toks) floats :test #'cl:string=))
                          (cl:cdr (cl:assoc (cl:eighth toks) consts :test #'cl:string=)))
                 out)))))

;; tests/run-specs.lisp
(defun %spv-use-name (use)
  "Human name for a cooperative-matrix Use operand value."
  (cl:case use (0 "A") (1 "B") (2 "Accumulator") (cl:t (cl:format cl:nil "use=~a" use))))

;; tests/run-specs.lisp
(defun %validate-coop-operand-elem (spv-path want-width label &key require-ext)
  "Assert that EVERY A/B cooperative matrix in SPV-PATH has component width WANT-WIDTH, and that
   every Accumulator matrix is 32-bit.  LABEL names the element type for the failure text;
   REQUIRE-EXT, when given, must appear in the module.

   DEGRADES TO PASS when llvm-spirv is unavailable (a CUDA-only box has no bundled bin/), matching
   %spv-contains-opcode-p: returns NIL only when the module WAS disassembled and the property is
   definitively absent."
  (cl:let* ((tool (resolve-tool-executable "llvm-spirv"))
            (txt-path (cl:format cl:nil "~a.155txt" (uiop:native-namestring spv-path))))
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
                      (bad-ops (cl:remove-if (cl:lambda (m) (cl:eql (cl:second m) want-width)) ops))
                      (bad-acc (cl:remove-if (cl:lambda (m) (cl:eql (cl:second m) 32)) accs)))
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
                            "FAIL: ~d of ~d A/B cooperative matrices are NOT ~a (~d-bit).~%~
                             This is the element type reaching codegen on SOME paths only — the module~%~
                             carries both widths for the same operand, so most fragments still compute~%~
                             in the wrong precision.  Offenders (result-id, component-width, use):~%"
                            (cl:length bad-ops) (cl:length ops) label want-width)
                 (cl:dolist (m bad-ops)
                   (cl:format cl:*error-output* "    id ~a  component=~a-bit  use=~a~%"
                              (cl:first m) (cl:or (cl:second m) "?") (%spv-use-name (cl:third m))))
                 cl:nil)
                (bad-acc
                 (cl:format cl:*error-output*
                            "FAIL: ~d accumulator cooperative matrix/matrices are not fp32.  A ~a MMA~%~
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

;; tests/run-specs.lisp  (REPLACES the weaker version earlier in this overlay)
(defun validate-spv-bf16-coop (spv-path)
  "Endeavour 155 — assert a bf16 register tile reached the hardware AS bf16, on EVERY operand.

   See %validate-coop-operand-elem for why the per-operand form of this assertion is the only one
   that catches the real bug.  Also requires SPV_KHR_bfloat16 to be declared, without which
   llvm-spirv refuses the module.

   NOTE ON RUNNING THIS ON INTEL METAL: it cannot be, on the BMG driver present 2026-08-22.  The
   Level Zero SPIR-V reader (IGC 1.6.33578) does not implement SPV_KHR_bfloat16 — it reports
   `input SPIR-V module uses unknown extension` and then crashes.  That is a driver gap, not a
   Crisp defect: three independent translators accept the same module, and the identical kernel in
   fp16 builds and runs.  This validator therefore checks the EMITTED MODULE only."
  (%validate-coop-operand-elem spv-path 16 "bfloat16" :require-ext "SPV_KHR_bfloat16"))

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
(defun %coop-node-elem (node)
  "The CRISP element type of the cooperative matrix a coop-op node operates on.

   Reads the node's own `(coop-matrix ELEM rows cols use)` type.  A :store node's own type is
   'void — the matrix is its VALUE node — so fall back to that.  Anything unrecognised yields
   FLOAT, which is the pre-155 behaviour: an element type this has not been taught about degrades
   to what the compiler did before rather than erroring somewhere unrelated."
  (flet ((coop-elem (ty)
           (and (consp ty)
                (symbolp (first ty))
                (string= (symbol-name (first ty)) "COOP-MATRIX")
                (>= (length ty) 2)
                (second ty))))
    (or (coop-elem (semantic-coop-op-type node))
        (let ((vn (semantic-coop-op-value-node node)))
          (and vn (coop-elem (semantic-node-type vn))))
        'float)))

;; src/codegen.lisp
(defun %coop-op-elem-llvm (node)
  "The LLVM type for a coop-op node's component type (see %coop-node-elem)."
  (let ((e (%coop-node-elem node)))
    (cond ((string= (symbol-name e) "HALF")     (llvm-half-type))
          ((string= (symbol-name e) "BFLOAT16") (llvm-bfloat-type))
          ((string= (symbol-name e) "DOUBLE")   (llvm-double-type))
          (t                                    (llvm-float-type)))))

;; src/codegen.lisp  (REPLACES generate-node-ir for semantic-coop-op)
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
                                        (origin (semantic-coop-op-tx node) cols) layout)
             (values (%coop-load builder module ptr stride elem-llvm rows cols use layout) nil)))
          (:store
           (let* ((mat (gen (semantic-coop-op-value-node node)))
                  (tv  (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride elem-llvm rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%block-prefetch builder module ptr stride rows cols)
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


;; src/codegen.lisp
(defun %llvm-float-width (ty)
  "Bit width of an LLVM floating-point type, or NIL if TY is not one of the four Crisp knows.
   HALF and BFLOAT16 are both 16 bits and are DIFFERENT types — same width, not interchangeable."
  (cond ((cffi:pointer-eq ty (llvm-half-type))   16)
        ((cffi:pointer-eq ty (llvm-bfloat-type)) 16)
        ((cffi:pointer-eq ty (llvm-float-type))  32)
        ((cffi:pointer-eq ty (llvm-double-type)) 64)
        (t nil)))

;; src/codegen.lisp
(defun %coop-coerce-scalar (builder val want-ty name)
  "Coerce scalar VAL to WANT-TY, if it is not already that type.

   Endeavour 155.  A fill's init value comes from a Crisp literal — `(make-register-tile half
   (8 16) 0.0 ...)` reads 0.0 as an f32 constant — while the cooperative matrix it initialises is
   now correctly declared with the tile's own element type.  Without this coercion the emitted
   call is a type error that LLVM will not catch (the callee is a declare, so nothing checks the
   argument) and that llvm-spirv rejects only at translation time, with exit code 13:

       %27 = call target(\"spirv.CooperativeMatrixKHR\", half, 3, 8, 8, 0)
               @__spirv_CompositeConstruct_0_8_8(float 0.000000e+00)
                                                 ^^^^^ declared parameter is half

   LLVM has no direct cast between two DIFFERENT 16-bit float types, so half<->bfloat16 is routed
   through f32.  That path cannot arise from a literal today (literals are f32, so the common case
   is a single fptrunc) but writing it is cheaper than discovering it later."
  (let ((have (llvm-type-of val)))
    (if (cffi:pointer-eq have want-ty)
        val
        (let ((hw (%llvm-float-width have))
              (ww (%llvm-float-width want-ty)))
          (cond
            ((not (and hw ww)) val)                       ; not both float — leave it alone
            ((> hw ww) (llvm-build-fp-trunc builder val want-ty name))
            ((< hw ww) (llvm-build-fp-ext   builder val want-ty name))
            (t (llvm-build-fp-trunc builder
                                    (llvm-build-fp-ext builder val (llvm-float-type)
                                                       (format nil "~a_via_f32" name))
                                    want-ty name)))))))

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

;; src/mma.lisp  (REPLACES %explode-register-tiles -- 155 Phase C)
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
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location)
                                    (values 1 0))
                              (let* ((per-warp (floor nfrags n-true))
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
                                     (rc      (getf keys :ring-count)))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                  (let* ((nfrags (* (floor m fr) (floor n fc)))
                                         (slot-syms-list
                                           (loop for slot below rc
                                                 collect (%register-tile-frag-syms
                                                          (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                  (symbol-package (first b)))
                                                          nfrags))))
                                    (push (list (first b) :ring m n slot-syms-list operand) tiles)
                                    (loop for syms in slot-syms-list
                                          append (loop for s in syms
                                                       collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand :elem ,elem)))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))


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
                           (nth (+ (* mi (max 1 (floor (third ta) sk))) ks) (fourth ta))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (nth (+ (* ks (max 1 (floor (third tb) sn))) nj) (fourth tb))
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
                (progn
                  (when (or (%resolve-tile-ref a tiles) (%resolve-tile-ref b tiles))
                    (error 'crisp-compiler-error
                      :message "register-resident A/B operands are not yet supported with a warp-distributed accumulator (n-true > 1)."
                      :source-location nil))
                  (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))

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

;; src/mma.lisp  (REPLACES %explode-register-tiles -- 155 Phase C)
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
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location)
                                    (values 1 0))
                              (let* ((per-warp (floor nfrags n-true))
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
                                     (rc      (getf keys :ring-count)))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                  (let* ((nfrags (* (floor m fr) (floor n fc)))
                                         (slot-syms-list
                                           (loop for slot below rc
                                                 collect (%register-tile-frag-syms
                                                          (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                  (symbol-package (first b)))
                                                          nfrags))))
                                    (push (list (first b) :ring m n slot-syms-list operand) tiles)
                                    (loop for syms in slot-syms-list
                                          append (loop for s in syms
                                                       collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand :elem ,elem)))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))

;; src/mma.lisp  (REPLACES %emit-per-frag-block-load -- 155 Phase C)
(defun %emit-per-frag-block-load (src entry coords)
  "Endeavor 142 — per-fragment expansion of (load-tile SRC <register-tile> COORDS): load each fragment
   of the A/B register-tile from global SRC.  For the first MMA_CORRECT this reuses load-fragment-a/b
   (CooperativeMatrixLoadKHR); the Subgroup2DBlockLoad swap is Phase B.  COORDS is the tile's grid
   block position — its fragment-row/col offset (grid-idx × per-tile fragment count) is added to the
   in-tile fragment index."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) (operand :acc)) (cdr entry)
    (declare (ignore n-true first-true))
    (let ((cl (find-package :crisp-language)))
      ;; 155 Phase C: the tile's element type decides K, so it decides how many fragments
      ;; this load explodes into.  See *register-tile-elems*.
      (destructuring-bind (fr . fc) (%frag-mn-for-operand operand (%register-tile-elem-of (first entry)))
        (let ((frag-fn (ecase operand
                         (:a (intern "LOAD-FRAGMENT-A" cl))
                         (:b (intern "LOAD-FRAGMENT-B" cl))
                         (:acc (error 'crisp-compiler-error
                                 :message "load-tile into an accumulator register-tile is not supported (only :operand :a / :b tiles are load targets)."
                                 :source-location nil))))
              (to-int  (intern "TO-INT" cl))
              (n-rows  (floor m fr))
              (n-cols  (floor n fc))
              (gy      (first coords))
              (gx      (second coords)))
          `(progn
             ,@(loop for ri below n-rows append
                     (loop for ci below n-cols
                           for idx = (+ (* ri n-cols) ci)
                           collect `(set! ,(nth idx syms)
                                          (,frag-fn ,src
                                                    ((+ (* (,to-int ,gy) ,n-rows) ,ri)
                                                     (+ (* (,to-int ,gx) ,n-cols) ,ci))))))))))))


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
(defun %coop-tensor-ptr+stride (builder tensor-val orow ocol layout &optional elem-llvm)
  "From a Crisp tensor STRUCT value, return (values element-ptr stride-i64) for the coop
   tile whose element origin is (OROW, OCOL) — both i64 LLVM values.  Tensor layout: field0
   = parent storage {ptr,i64}, field2 = strides [N x i64].  Leading dim = strides[0]
   (RowMajor) / strides[1] (ColMajor)."
  ;; Endeavour 155: ELEM-LLVM is the tensor's element type and defaults to f32, which is what
  ;; this always used.  See header for why a wrong choice here is invisible until it is measured.
  (let* ((f32 (or elem-llvm (llvm-float-type)))
         (storage (llvm-build-extract-value builder tensor-val 0 "coop_storage"))
         (base    (llvm-build-extract-value builder storage 0 "coop_base"))
         (strides (llvm-build-extract-value builder tensor-val 2 "coop_strides"))
         (s0 (llvm-build-extract-value builder strides 0 "coop_s0"))
         (s1 (llvm-build-extract-value builder strides 1 "coop_s1"))
         (off0 (llvm-build-mul builder orow s0 "coop_off0"))
         (off1 (llvm-build-mul builder ocol s1 "coop_off1"))
         (flat (llvm-build-add builder off0 off1 "coop_flat"))
         (stride (if (= layout 0) s0 s1)))
    (cffi:with-foreign-object (idx :pointer 1)
      (setf (cffi:mem-aref idx :pointer 0) flat)
      (values (llvm-build-gep2 builder f32 base idx 1 "coop_elem_ptr") stride))))

;; src/codegen.lisp  (REPLACES generate-node-ir (semantic-coop-op) -- 155)
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
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride elem-llvm rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%block-prefetch builder module ptr stride rows cols)
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
(defun %elem-llvm-bytes (elem-llvm)
  "Bytes per element for an LLVM scalar type, defaulting to 4 — which is what every hardcoded
   constant this replaces assumed."
  (let ((bits (and elem-llvm (%llvm-float-width elem-llvm))))
    (if bits (max 1 (floor bits 8)) 4)))

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

;; src/codegen.lisp  (REPLACES generate-node-ir (semantic-coop-op) -- 155)
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
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride elem-llvm rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
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

;; src/mma.lisp  (REPLACES %coop-mma -- 155 bf16)
(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, <operands>) -> the MxN accumulator coop matrix.

   Operand types come from the ACTUAL VALUES via LLVMTypeOf, so the declaration cannot drift from
   what is passed (Endeavour 155, Phase 1).

   THE OPERANDS MASK.  Last argument of the MulAdd.  0 for f32/tf32 and for fp16, whose component
   type already says what it is.  0x40 (MatrixAAndBBFloat16ComponentsINTEL) when A and B are
   16-bit INTEGER matrices, which is how bf16 is represented — the integer type cannot say
   'bfloat' on its own, so the bit says it instead.

   Detection is by comparing A's type against a freshly built i16 A-type: LLVM uniques types, so
   pointer equality is exact and needs no string parsing.  M/K are the A operand's own dims."
  (declare (ignorable elem-llvm))
  (let* ((a-ty (crisp.llvm-bindings::llvm-type-of a-val))
         (b-ty (crisp.llvm-bindings::llvm-type-of b-val))
         (c-ty (crisp.llvm-bindings::llvm-type-of c-val))
         (i32  (crisp.llvm-bindings::llvm-int32-type))
         (i16  (crisp.llvm-bindings::llvm-int16-type))
         (bf16-p (cffi:pointer-eq a-ty (%coop-type i16 m k 0)))
         (operands (if bf16-p #x40 0)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 operands nil)))))

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
