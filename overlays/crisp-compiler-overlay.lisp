;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;

(in-package :crisp.compiler)


;;; ===================================================================
;;; ENDEAVOR 144 Phase 2 — wgmma accumulator register accounting.
;;;
;;; Finding #2: `%register-tile-fit-check` is called only from the make-register-tile
;;; analyzers, so `make-wgmma-accumulator` — the form our best NVIDIA kernel (chap3,
;;; 63.6% of cuBLAS) is built on — had NO register accounting at all.  The N-sweep
;;; (128/192/256) was therefore pure empiricism.
;;;
;;; Two-tier diagnostic, matching the split established for this endeavor (decision D3):
;;;   - HARD OVERFLOW -> error.  The accumulator alone cannot fit a thread's register
;;;     budget, so the kernel cannot work.  Mirrors %register-tile-fit-check exactly.
;;;   - HIGH OCCUPANCY COST -> warning.  Occupancy is not a correctness bound, so this
;;;     must never break a kernel that works today.  Emitted with a raw `format` to
;;;     *error-output* (NOT log4cl) so it survives --log-level=off and can be asserted
;;;     with EXPECT-STDERR[...], exactly as endeavor 126's precision warnings are.
;;;
;;; The per-warpgroup register total is reported because it is the direct input to the
;;; Phase 3 occupancy model: resident warpgroups per CU = :max-registers-per-cu /
;;; regs-per-warpgroup.  Phase 3 turns this report into that division.
;;; ===================================================================

;; src/mma.lisp
(defparameter *wgmma-acc-occupancy-warn-fraction* 1/2
  "Endeavor 144 Phase 2: warn when a wgmma accumulator alone occupies at least this
   fraction of the per-thread register budget.  At 1/2, an m64n256 accumulator (128 of
   255 registers) warns and an m64n128 (64) does not — so the advisory fires precisely on
   the tile widths where occupancy, not fit, is the binding constraint.")

;; src/mma.lisp
(defun %wgmma-acc-fit-check (m n location)
  "Endeavor 144 Phase 2: register accounting for a wgmma (M N) warpgroup accumulator.

   A wgmma D accumulator holds N/2 flat f32 registers PER THREAD across the 128-thread
   warpgroup (the wgmma D thread->element mapping).  Errors when that alone exceeds the
   per-thread budget (the active profile's :max-registers-per-thread, else
   *default-max-registers-per-thread*); warns when it consumes at least
   *wgmma-acc-occupancy-warn-fraction* of it.

   Deliberately accounts for the ACCUMULATOR ONLY — operand fragments, addressing, and
   whatever ptxas adds ride on top, so the real per-thread count is strictly higher.  Like
   %register-tile-fit-check, this checks what the developer explicitly reserved."
  (let* ((threads-per-warpgroup 128)
         (regs-per-thread    (floor n 2))
         (regs-per-warpgroup (* regs-per-thread threads-per-warpgroup))
         (profile (active-hardware-profile))
         ;; Endeavor 144 D4: the key may now be a LIST of selectable modes, so read it
         ;; through the accessor.  A wgmma kernel is NVIDIA-only (one fixed allocation),
         ;; so the DEFAULT mode is the right budget here.
         (budget  (or (%hp-registers-per-thread-default profile)
                      *default-max-registers-per-thread*)))
    (when (> regs-per-thread budget)
      (error 'crisp-compiler-error
             :message (format nil "make-wgmma-accumulator: a ~ax~a warpgroup accumulator needs ~a registers/thread (N/2 flat f32), exceeding the register budget of ~a.  Use a smaller N, or a hardware profile with a larger :max-registers-per-thread."
                              m n regs-per-thread budget)
             :source-location location))
    (when (>= regs-per-thread (* budget *wgmma-acc-occupancy-warn-fraction*))
      (format *error-output*
              "WARNING: make-wgmma-accumulator ~ax~a reserves ~a of ~a registers/thread (~,1f%) for the ACCUMULATOR ALONE; operand fragments and addressing are additional.  That is ~a registers per 128-thread warpgroup, which bounds how many warpgroups can be resident per compute unit.  Consider a smaller N if occupancy matters more than arithmetic intensity for your problem size.~%"
              m n regs-per-thread budget
              (* 100.0 (/ regs-per-thread budget))
              regs-per-warpgroup))
    regs-per-thread))

;; src/mma.lisp
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144 Phase 2: now also runs %wgmma-acc-fit-check — the register accounting this
   form previously lacked entirely (finding #2)."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (%wgmma-acc-fit-check m n location)
      (let ((type-name (%ensure-wgmma-acc-type n)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))


;;; ===================================================================
;;; ENDEAVOR 144 Phase 4 — Intel GRF model + register-file mode selection.
;;;
;;; MEASURED MOTIVATION (results.md): all three BMG benchmark kernels spill —
;;; intel_prefetch 1792 B, chap0_sync 2560 B, chap1_async_linear 2752 B — because
;;; `%register-tile-fit-check` SKIPS :spirv entirely ("the driver owns register
;;; residency"), so Crisp had no GRF model on the one backend where register pressure
;;; is the stated binding constraint.  Rebuilding the SAME .spv with IGC's
;;; `-ze-opt-large-register-file` takes spill to 0 on all three and runs 1.5-2.07x
;;; faster (24.01 vs 11.61 TFLOPS at 1024), verified MMA_CORRECT.
;;;
;;; Step 1 of 4 (schema) + Step 2 (accounting & mode decision) live here.
;;; Steps 3 (metacrisp) and 4 (hoist pBuildFlags) follow.
;;;
;;; DECISION D4 (user, 2026-07-27, option B): `:max-registers-per-thread` accepts a
;;; SCALAR (NVIDIA: one fixed allocation) or a LIST of selectable modes (Intel:
;;; '(128 256) — default GRF and large GRF).  The key keeps ONE meaning throughout,
;;; "architectural registers per thread"; the register WIDTH (4 B on NVIDIA, 32 B on
;;; Xe2) is a backend fact the compiler knows from the target, NOT a profile key.
;;; ===================================================================

;; src/hardware-profile.lisp
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
    (:max-work-group-dims         . :dims3)     ; (x y z) positive ints
    (:mma-shapes                  . :mma-shapes)) ; list of (M N K) triples
  "Endeavor 130: canonical hardware-profile keys and their value types.  Every key
   is KNOWN from Phase 0 (so profiles are typo-checked and may be complete); the
   CONSUMERS that read each key are added phase by phase.  Unknown keys are a
   compile error; any subset may be specified (missing keys are fine).

   Endeavor 144 (D4): :max-registers-per-thread became :pos-int-or-modes — a scalar
   (a single fixed allocation, e.g. NVIDIA 255) or an ascending list of SELECTABLE
   allocations (e.g. Intel Xe2 '(128 256): default GRF and large GRF).  The list form
   exists because on Intel the per-thread register file is a MODE, chosen at JIT time,
   and trading registers against threads-per-EU is exactly the decision Phase 4 makes.")

;; src/hardware-profile.lisp
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
       shapes))))

;; src/hardware-profile.lisp
(defun %hp-register-modes (&optional (profile (active-hardware-profile)))
  "Endeavor 144 (D4): the active profile's :max-registers-per-thread as an ascending
   LIST of selectable per-thread register allocations.  A scalar becomes a one-element
   list, so every consumer can treat the value uniformly.  NIL when no profile is
   active or the key is absent."
  (let ((v (and profile (getf profile :max-registers-per-thread))))
    (cond ((null v) nil)
          ((integerp v) (list v))
          ((listp v) v)
          (t nil))))

;; src/hardware-profile.lisp
(defun %hp-registers-per-thread-default (&optional (profile (active-hardware-profile)))
  "The DEFAULT per-thread register allocation (the first / smallest selectable mode),
   or NIL.  This is what a plain fit-check should measure against — it is what the
   kernel gets unless a larger mode is deliberately selected."
  (first (%hp-register-modes profile)))

;; src/hardware-profile.lisp
(defun %hp-registers-per-thread-max (&optional (profile (active-hardware-profile)))
  "The LARGEST selectable per-thread register allocation, or NIL.  Exceeding this means
   the kernel will spill no matter which mode is chosen."
  (let ((modes (%hp-register-modes profile)))
    (and modes (reduce #'max modes))))

;; src/mma.lisp
(defun %register-tile-fit-check (m n location)
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile
   is opaque cooperative matrices (the driver owns register residency), so SKIP — the
   Intel GRF model is a SEPARATE accounting (Endeavor 144 Phase 4, see
   %spv-note-register-fragment / %spv-decide-register-mode).  Else:
   (M/16)x(N/8) accumulator fragments x 4 fp32 regs <= :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may now be a LIST of selectable modes."
  (unless (eq *target-backend* :spirv)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (budget        (or (%hp-registers-per-thread-default)
                              *default-max-registers-per-thread*)))
      (when (> total-regs budget)
        (error 'crisp-compiler-error
               :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                m n total-regs nfrags regs-per-frag budget)
               :source-location location)))))


;;; -------------------------------------------------------------------
;;; Phase 4 Step 2 — the SPV/Intel GRF accounting.
;;;
;;; WHY HERE.  %explode-register-tiles already emits exactly one
;;; `make-register-fragment` per fragment PER RING SLOT, and already divides a
;;; :warps-distributed tile by its participating warp count.  So tallying fragments
;;; inside analyze-make-register-fragment yields precise PER-THREAD demand for free,
;;; ring depth and warp distribution included — no need to redefine the 90-line
;;; explosion, and no risk of the ring-depth undercount the (m n)-only fit-check has.
;;;
;;; UNITS.  A register tile is SUBGROUP-collective and one Xe2 GRF register is 32 B, so
;;; a thread's demand is (total fragment elements x 4 B) / 32 B = elements / 8.  That is
;;; SIMD-width independent precisely because the EU thread *is* the subgroup.
;;; Cross-check against the measured kernel: intel_prefetch holds C 32x32 (1024) +
;;; A-ring 2x(32x8) (512) + B-ring 2x(8x32) (512) = 2048 elements -> 256 GRF registers,
;;; against 128 in default mode.  Exactly the 2x oversubscription IGC reported as spill.
;;;
;;; IDEMPOTENCE.  Crisp is multipass, so a let may be analyzed more than once.  The tally
;;; is keyed on (kernel . source-location) and ASSIGNED, not incremented — a re-analysis
;;; overwrites its own entry instead of double counting.
;;; -------------------------------------------------------------------

;; src/mma.lisp
(defvar *spv-register-demand* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 4: (kernel-name . source-location) -> fragment ELEMENT count, for
   the SPV/Intel GRF model.  Keyed per source site and assigned (not incremented) so
   multipass re-analysis is idempotent.  Summed per kernel by %spv-kernel-register-demand.")

;; src/mma.lisp
(defvar *kernel-register-mode* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 4: kernel-name -> the selected per-thread register allocation (an
   element of the profile's :max-registers-per-thread modes).  Written by
   %spv-decide-register-mode and carried to the hoist via the metacrisp so the L0
   launcher can ask IGC for that allocation (-ze-opt-large-register-file).")

;; src/mma.lisp
(defparameter *spv-grf-register-bytes* 32
  "Bytes per architectural GRF register on Intel Xe/Xe2.  A BACKEND fact, deliberately
   NOT a hardware-profile key: the profile counts registers, the target defines their
   width (4 B on NVIDIA, 32 B here).  See Endeavor 144 decision D4.")

;; src/mma.lisp
(defun %spv-note-register-fragment (rows cols context location)
  "Endeavor 144 Phase 4: record one register FRAGMENT's element count against the kernel
   being compiled, for the Intel GRF model.  No-op off the SPV backend or without a
   current function.  Assigned per (kernel . location) so re-analysis is idempotent.

   Only ALLOCATIONS reach here — see the :tally nil guard in analyze-make-register-fragment
   for why re-initializing an existing fragment must not be counted."
  (when (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when fn
        (setf (gethash (cons fn location) *spv-register-demand*) (* rows cols))))))

;; src/mma.lisp
(defun %emit-per-frag-fill (entry val)
  "Per-fragment expansion of (fill-tile V VAL) for a register tile: reset every fragment
   of V to a fragment-of-VAL (matching make-register-tile's own 16x8 fragment init).

   Endeavor 144 Phase 4: tagged :tally nil.  These forms RE-INITIALIZE fragments the tile
   already owns — a set! of an existing register, not a new allocation — so counting them
   in the GRF demand model would inflate a tile's cost purely for having been filled."
  (destructuring-bind (m n syms &optional n-true first-true operand) (cdr entry)
    (declare (ignore m n n-true first-true operand))
    ;; fill just resets every fragment this warp holds — no logical index needed.
    `(progn
       ,@(loop for s in syms
               collect `(set! ,s (make-register-fragment 16 8 ,val :tally nil))))))

;; src/mma.lisp
(defun %spv-kernel-register-demand (kernel-name)
  "Endeavor 144 Phase 4: (values GRF-REGISTERS ELEMENTS) demanded per thread by
   KERNEL-NAME's register tiles / rings, or (values 0 0) if it has none."
  (let ((elements 0))
    (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf elements v)))
             *spv-register-demand*)
    (values (ceiling (* elements 4) *spv-grf-register-bytes*) elements)))

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
      (multiple-value-bind (demand elements) (%spv-kernel-register-demand kernel-name)
        (when (plusp demand)
          (let* ((default-mode (first modes))
                 (fitting      (find-if (lambda (mode) (<= demand mode)) modes))
                 (chosen       (or fitting (reduce #'max modes))))
            (setf (gethash kernel-name *kernel-register-mode*) chosen)
            (cond
              ((null fitting)
               (format *error-output*
                       "WARNING: kernel ~a needs ~a registers/thread (~a register-tile elements x 4 B / ~a B per GRF register), exceeding every selectable allocation ~a in the hardware profile — it will SPILL in any mode.  Reduce the register-tile shape, the ring depth, or distribute the tile across more warps (:warps).~%"
                       kernel-name demand elements *spv-grf-register-bytes* modes))
              ((> demand default-mode)
               (format *error-output*
                       "NOTE: kernel ~a needs ~a registers/thread, above the default allocation of ~a — selecting the ~a-register mode.  (Larger allocations trade threads-per-EU for registers; without this the JIT would spill instead.)~%"
                       kernel-name demand default-mode chosen)))
            chosen))))))

;; src/mma.lisp
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand).  :spirv -> a filled coop matrix;
   else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default acc) picks
   the coop-matrix Use + shape so an A/B operand tile mints fragments matching load-fragment-a/b —
   A = sm×sk Use 0, B = sk×sn Use 1, Acc = sm×sn Use 2.

   Endeavor 144 Phase 4: on SPV, each fragment's element count is tallied against the
   current kernel (%spv-note-register-fragment) to build the Intel GRF demand model —
   EXCEPT when the form carries :tally nil, which marks a RE-INITIALIZATION of a fragment
   the tile already owns (fill-tile's per-fragment set!s).  Those allocate nothing, so
   counting them would charge a tile extra registers merely for being filled."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          ;; shape from the active profile's mma-shape (the source m/n is a logical hint; the
          ;; hardware shape wins so one source runs on both vendors).
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))    ; fragment rows
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))   ; fragment cols
              (when tally-p (%spv-note-register-fragment fr fc context location))
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float fr fc use) :kind :fill
               :value-node (analyze-expression init env context (append location '(1)))
               :rows fr :cols fc :use use :layout 0 :source-location location)))
          (progn
            (unless (and (eql m 16) (eql n 8))
              (error 'crisp-compiler-error
                     :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
            (analyze-expression
             (ecase operand
               (:acc `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init))
               (:a   `(%construct-struct register-fragment-a-tf32-16x8 ,init ,init ,init ,init))
               (:b   `(%construct-struct register-fragment-b-tf32-8x8 ,init ,init)))
             env context location))))))

;; src/hardware-profile.lisp
(defun %hp-check-all-shared-memory ()
  "Endeavor 130 Phase 2: after a module compiles (all signatures, incl. implicit
   scratch, finalized), validate every kernel's local memory against the active
   hardware profile.

   Endeavor 144 Phase 4 ALSO runs the SPV register-mode decision here.  NOTE FOR THE SRC
   PATCH: in src/ this belongs as its OWN call in compile-module (right after
   %hp-check-all-shared-memory, analysis/core.lisp:424) — it is folded in here only so the
   overlay does not have to redefine the whole compile-module function."
  (let ((profile (active-hardware-profile)))
    (when profile
      (dolist (k *compiled-kernels*)
        (%hp-check-shared-memory k profile))
      (when (eq *target-backend* :spirv)
        (dolist (k *compiled-kernels*)
          (%spv-decide-register-mode k profile))))))


;;; -------------------------------------------------------------------
;;; Phase 4 Step 3 — carry the selected register allocation to the hoist.
;;;
;;; It rides INSIDE the existing (:hardware-profile ...) metacrisp form rather than as a
;;; new top-level form, deliberately: parse-metacrisp-file's cond silently DROPS unknown
;;; top-level forms, so a new form would need a reader change, whereas the profile plist
;;; is already passed through whole (hoist/common.lisp:26) and reaches the hoist via
;;; metacrisp-hardware-profile.  Zero reader changes.
;;;
;;; The value is the MAX over the module's kernels, which is not an approximation: IGC's
;;; register-file mode is a MODULE build flag (ze_module_desc_t.pBuildFlags), and one
;;; module is one .spv, so the whole module must be built for its most demanding kernel.
;;; -------------------------------------------------------------------

;; src/hardware-profile.lisp
(defun %hp-selected-registers-per-thread ()
  "Endeavor 144 Phase 4: the largest register allocation any kernel in this module needs
   (from *kernel-register-mode*), or NIL if no kernel selected one.  MAX because IGC's
   register-file mode is a per-MODULE build flag, so the module must satisfy its most
   demanding kernel."
  (let ((best nil))
    (maphash (lambda (k v) (declare (ignore k))
               (when (or (null best) (> v best)) (setf best v)))
             *kernel-register-mode*)
    best))

;; src/hardware-profile.lisp
(defun %hp-serialize-active-profile (stream)
  "Emit the active hardware profile (the one --hardware-profile / a topology named)
   as a top-level metacrisp form, keeping its name.  Values are the normalized
   (already-parsed) form: sizes in bytes, lists resolved.  Emits nothing when no
   profile is active.

   Endeavor 144 Phase 4: also emits :selected-registers-per-thread — the per-thread
   register allocation the compiler chose for this module (see
   %hp-selected-registers-per-thread).  It is a DERIVED value, not a user-supplied profile
   key, so it is written only here and never accepted by register-hardware-profile."
  (let ((profile (active-hardware-profile)))
    (when profile
      (format stream "(:hardware-profile~%  (:name ~s" (string-upcase *requested-hardware-profile*))
      (loop for (k v) on profile by #'cddr
            do (format stream "~%   ~s ~s" k v))
      (let ((chosen (%hp-selected-registers-per-thread)))
        (when chosen
          (format stream "~%   :selected-registers-per-thread ~s" chosen)))
      (format stream "))~%~%"))))


;;; ===================================================================
;;; ENDEAVOR 144 Phase 0 — BUILTIN hardware profiles (decision D2).
;;;
;;; topology.md has always advertised `bmg` as a Crisp-predefined profile.  That was
;;; untrue: NOTHING was builtin, and the benchmark kernels each carried their own inline
;;; 2-key `def-hardware-profile bmg`.  That drift is exactly how Phase 4's win reached only
;;; ONE of the three BMG kernels — `matmul_bmg_prefetch.crisp` got
;;; `:max-registers-per-thread (128 256)` and chap0 / chap1 did not, so those two kept
;;; spilling (2560 B / 2752 B) and their numbers did not move.
;;;
;;; Both profiles are QUERIED, not spec-sheet — see results.md:
;;;   bmg   — Level Zero zeDeviceGetProperties on an Arc B580 (2026-07-27)
;;;   h100  — cudaGetDeviceProperties on an H100 PCIe on runpod (2026-07-28)
;;;
;;; A user's own `def-hardware-profile` with the same name still WINS: register-hardware-profile
;;; simply setf-s the hash entry, and the current file's forms register after
;;; initialize-compiler's clrhash.  So every existing spec that defines an inline `bmg`
;;; keeps its exact previous behaviour and needs no edit.
;;; ===================================================================

;; src/mma.lisp  (piggybacked — see the note below)
(defun register-builtin-hardware-profiles ()
  "Endeavor 144 Phase 0 (D2): register Crisp's predefined hardware profiles.

   Called from register-mma-types, which initialize-compiler invokes AFTER it clrhash-es
   *hardware-profiles* (src/compiler.lisp:938 vs :1022) — so builtins survive the clear and
   a same-named user profile still overrides them.

   NOTE FOR THE SRC PATCH: this belongs as its own call in initialize-compiler next to
   register-builtins; it is invoked from register-mma-types here only so the overlay does
   not have to redefine the whole initialize-compiler function."
  ;; Intel Arc B580 (Battlemage / Xe2).  Queried 2026-07-27.
  ;; :max-registers-per-thread is the SELECTABLE-MODE list form (D4): Xe2's register file is
  ;; a JIT-time choice — 128 GRF/thread default, 256 with -ze-opt-large-register-file, which
  ;; halves threads-per-EU.  Phase 4's model picks between them from register demand.
  (register-hardware-profile
   'bmg
   '(:simd-width 16                        ; subGroupSizes reports BOTH 16 and 32
     :compute-units 20                     ; Xe-cores (5 slices x 4 subslices)
     :max-registers-per-thread (128 256)   ; GRF registers (32 B each) — selectable modes
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 1024)
     :max-shared-memory-per-block 128KB
     :l2-cache-size 18MB
     :native-cache-line-size 64            ; Xe2 LSC line; not queryable
     :mma-shapes ((8 16 8))))              ; XMX tf32
  ;; NVIDIA H100 PCIe (Hopper).  Queried 2026-07-28.
  ;; :compute-units 114 is the PCIe part — the SXM is 132.  This value OVERRIDES the device
  ;; SM query in the generated CUDA launch grid, so the variant distinction is load-bearing.
  ;; :max-registers-per-thread is a SCALAR: NVIDIA's per-thread allocation is fixed at 255.
  ;; :max-shared-memory-per-block is the OPT-IN cap (227KB), not the 48KB default — chap2 and
  ;; chap3 both exceed 48KB.
  ;; :mma-shapes MUST include (16 8 8): chap0/1/1.5/2 all pass that tf32 shape.  (wgmma's
  ;; m64nNk8 family is validated by %check-wgmma-shape and does not consult this key.)
  (register-hardware-profile
   'h100
   '(:simd-width 32
     :compute-units 114
     :max-registers-per-cu 65536
     :max-registers-per-thread 255
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 64)
     :max-shared-memory-per-block 227KB
     :l2-cache-size 50MB
     :native-cache-line-size 128
     :mma-shapes ((16 8 8) (16 8 4) (16 8 16)))))

;; src/mma.lisp
(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float.

   Endeavor 144 Phase 0: also registers the BUILTIN hardware profiles, which must happen
   after initialize-compiler's clrhash of *hardware-profiles* — this is the first hook that
   runs there.  See register-builtin-hardware-profiles for the src-patch note."
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record)
  (register-builtin-hardware-profiles))


;;; ===================================================================
;;; ENDEAVOR 144 Phase 1 — L2-aware tile VISIT ORDER inside tile-stride.
;;;
;;; WHAT.  `tile-stride` currently maps workgroups to output tiles per-axis and
;;; independently: start_i = get-workgroup-id(i), stride_i = get-num-groups(i).  With an exact
;;; tile cover that is a row-major walk, so the workgroups resident at any instant span ONE
;;; row-band of C — they share an A row-block but collectively stream ALL of B.  Grouping the
;;; walk into column strips of width W makes the resident set a W-wide, (R/W)-tall
;;; NEIGHBOURHOOD, which re-reads A and B out of L2 instead of HBM.
;;;
;;; DECISION D1: no user-facing key.  `tile-stride`'s contract is COVERAGE, NOT ORDER — it
;;; promises every tile is visited, never that consecutive workgroups get consecutive tiles —
;;; so reordering is inside the existing contract.  The A/B switch is `--hardware-profile`
;;; itself (no profile -> no :l2-cache-size -> linear).  A survey of all 64 tile-stride kernels
;;; found ZERO order-dependence (exact set intersection with atomic-using kernels is empty).
;;;
;;; THE MAPPING (a bijection, so coverage is preserved exactly).  Linearize the workgroup id,
;;; grid-stride over the FLAT tile count, then delinearize through the strip:
;;;     tpg = W * nt_rows                      tiles per full strip
;;;     grp = tid / tpg ;  idg = tid mod tpg
;;;     fc  = grp * W                          first column of this strip
;;;     gc  = min(W, nt_cols - fc)             the LAST strip may be narrower
;;;     row = idg / gc ;  col = fc + (idg mod gc)
;;; Bijectivity holds because every strip but the last has exactly tpg tiles and the partial
;;; strip is last, so `tid / tpg` never mis-assigns.  (Worked example: nt=(3 rows,5 cols),
;;; W=2 -> strips of 6,6,3 tiles = 15 = 3*5, each tile hit once.)
;;;
;;; SCOPE.  Rank-2 tile-stride with a compile-time `(M N)` size-list only.  Anything else
;;; (rank != 2, a tile-TENSOR spec whose extents are runtime) falls through to the untouched
;;; linear expansion — which is also why this is a hook on the short %expand-tile-stride-form
;;; rather than a rewrite of the 100-line loop builder.
;;; ===================================================================

;; src/compiler.lisp
(defparameter *tile-visit-max-strip-width* 4
  "Endeavor 144 Phase 1: ceiling on the derived strip width.

   MEASUREMENT-FITTED, not derived.  Swept on a B580 at 2048 (working set 50 MB vs 18 MB L2),
   TFLOPS: linear 17.1, W=2 27.6, W=4 27.9, W=8 26.9, W=16 28.0.  So (a) essentially the WHOLE
   win is captured by any W >= 2 — the grouped/linear distinction is worth ~60%, the width
   within 2..16 only ~4% — and (b) W=8 sits in a reproducible local dip, confirmed at 1024 too
   (W=4 23.2 vs W=8 22.4).  Hence 4 rather than the 8 this started at.

   Because the win is essentially BINARY (grouped at all vs not), Phase 3's occupancy-derived
   width would be a refinement, NOT a prerequisite — which is the opposite of what the
   theory-first analysis suggested.  Re-check the clamp on H100: more SMs means a larger
   resident set, which may prefer a wider strip.")

;; src/compiler.lisp
(defun %tile-visit-override ()
  "Endeavor 144 Phase 1: read the CRISP_TILE_VISIT escape hatch.  Returns :linear (force the
   old order), an INTEGER (force that strip width), or NIL (derive it).

   Per decision D1 the escape hatch is a compiler-level knob, never kernel syntax — a kernel
   must not encode a machine-tuning constant.  It is an env var rather than a CLI flag only
   because that needs no main.lisp surgery; it should GRADUATE to `--tile-visit=linear|grouped|grouped:N`
   once the width formula settles.  Its real job right now is sweeping W empirically so the
   formula can be fitted to measurements instead of guessed."
  (let ((v (uiop:getenv "CRISP_TILE_VISIT")))
    (when (and v (plusp (length v)))
      (let ((s (string-downcase v)))
        (cond
          ((string= s "linear") :linear)
          ((string= s "grouped") nil)                  ; derive
          ((and (> (length s) 8) (string= (subseq s 0 8) "grouped:"))
           (let ((n (ignore-errors (parse-integer (subseq s 8)))))
             (if (and n (plusp n)) n :linear)))
          (t nil))))))

;; src/compiler.lisp
(defun %tile-visit-strip-width (n tile-sizes)
  "Endeavor 144 Phase 1: the column-strip width for a rank-N tile-stride whose tile is
   TILE-SIZES.  1 means 'walk linearly' (the caller then emits the untouched expansion).

   Gates: rank exactly 2, all tile dims compile-time integers, an active profile that supplies
   :l2-cache-size, and the whole thing overridable via CRISP_TILE_VISIT.

   WIDTH FORMULA — HONEST STATUS.  The theoretically right width comes from the RESIDENT block
   count R and the tile aspect ratio: minimizing the concurrent footprint
   (H*tile_M + W*tile_N)*K subject to H*W = R gives W = sqrt(R * tile_M / tile_N).  R is
   exactly what endeavor 144 PHASE 3 computes (:max-registers-per-cu + SLM + local-size), so
   this function is deliberately the ONE place that has to change when Phase 3 lands.
   Until then it uses the cache-capacity proxy sqrt(L2 / tile-bytes), clamped — which on both
   current targets saturates at the clamp (BMG 18MB/4KB -> 67; H100 50MB/16KB -> 56), i.e.
   today it is effectively 'the clamp'.  That is why the CRISP_TILE_VISIT sweep exists: measure
   the curve first, then fit."
  (let ((override (%tile-visit-override)))
    (cond
      ((eq override :linear) 1)
      ((integerp override) override)
      ((/= n 2) 1)
      ((not (and (listp tile-sizes) (= (length tile-sizes) 2)
                 (every (lambda (x) (and (integerp x) (plusp x))) tile-sizes)))
       1)
      (t
       (let* ((profile (active-hardware-profile))
              (l2      (and profile (getf profile :l2-cache-size))))
         (if (not (and l2 (plusp l2)))
             1
             (let* ((tile-bytes (* (first tile-sizes) (second tile-sizes) 4))
                    (w (isqrt (max 1 (floor l2 (max 1 tile-bytes))))))
               (max 1 (min *tile-visit-max-strip-width* w)))))))))


;; src/analysis/control.lisp
(defun %expand-tile-stride-swizzled (tensor-form bindings body-forms ts-syms
                                     tile-size-expr-fn strip-width location)
  "Endeavor 144 Phase 1: the GROUPED (column-strip) rank-2 tile-stride expansion.

   Replaces the per-axis nest with ONE grid-strided loop over the flat tile index, then
   delinearizes through a STRIP-WIDTH-wide column strip.  See the header block for the mapping
   and its bijectivity argument; because the map is a bijection over [0, nt_rows*nt_cols) and
   the loop grid-strides that flat range, coverage is exactly preserved for ANY grid size —
   including an oversubscribed or under-dispatched one, where a naive 'swizzle the per-axis
   start' would double-visit or miss tiles."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym      (intern "LET" cl-pkg))
         (declare-sym  (intern "DECLARE" cl-pkg))
         (wg-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym  (intern "DOTIMES" cl-pkg))
         (progn-sym    (intern "PROGN" cl-pkg))
         (aref-sym     (intern "~" cl-pkg))
         (extents-sym  (intern "EXTENTS~" cl-pkg))
         (wgid-sym     (intern "GET-WORKGROUP-ID" cl-pkg))
         (numgrp-sym   (intern "GET-NUM-GROUPS" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (if-sym       (intern "IF" cl-pkg))
         (lt-sym       (intern "<" cl-pkg))
         (plus-sym     (intern "+" cl-pkg))
         (minus-sym    (intern "-" cl-pkg))
         (mul-sym      (intern "*" cl-pkg))
         (div-sym      (intern "/" cl-pkg))
         (rem-sym      (intern "REM" cl-pkg))
         (t-sym    (gensym "TSW"))
         (e0 (gensym "E0")) (e1 (gensym "E1"))
         (nt0 (gensym "NT0")) (nt1 (gensym "NT1"))
         (total (gensym "TOTAL")) (lwg (gensym "LWG")) (nwg (gensym "NWG"))
         (iters (gensym "ITERS")) (k (gensym "K")) (tid (gensym "TID"))
         (wsym (gensym "W")) (tpg (gensym "TPG"))
         (grp (gensym "GRP")) (idg (gensym "IDG"))
         (fc (gensym "FC")) (gc (gensym "GC"))
         (row-sym (first bindings)) (col-sym (second bindings))
         (ts0 (first ts-syms)) (ts1 (second ts-syms))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms))))
    (list let-sym
          (list
           (list t-sym tensor-form)
           (list ts0 (funcall tile-size-expr-fn 0))
           (list ts1 (funcall tile-size-expr-fn 1))
           (list e0 (list aref-sym (list extents-sym t-sym) 0))
           (list e1 (list aref-sym (list extents-sym t-sym) 1))
           ;; nt_i = ceil(e_i / ts_i) — tile ROWS and tile COLS of the output
           (list nt0 (list div-sym (list plus-sym e0 (list minus-sym ts0 (list to-ulong-sym 1))) ts0))
           (list nt1 (list div-sym (list plus-sym e1 (list minus-sym ts1 (list to-ulong-sym 1))) ts1))
           (list total (list mul-sym nt0 nt1))
           ;; Flatten the workgroup id and the grid, so one loop grid-strides the flat tile range.
           (list lwg (list plus-sym
                           (list mul-sym (list wgid-sym 1) (list numgrp-sym 0))
                           (list wgid-sym 0)))
           (list nwg (list mul-sym (list numgrp-sym 0) (list numgrp-sym 1)))
           (list iters (%build-exact-iter-count-form lwg nwg total cl-pkg)))
          (list declare-sym (list wg-level-sym))
          (list dotimes-sym (list k iters)
                (list let-sym (list (list tid (list plus-sym lwg (list mul-sym k nwg)))
                                    (list wsym (list to-ulong-sym strip-width)))
                      (list let-sym (list (list tpg (list mul-sym wsym nt0)))
                            (list let-sym (list (list grp (list div-sym tid tpg))
                                                (list idg (list rem-sym tid tpg)))
                                  (list let-sym (list (list fc (list mul-sym grp wsym)))
                                        ;; gc = min(W, nt1 - fc): the final strip may be narrower.
                                        (list let-sym
                                              (list (list gc (list if-sym
                                                                   (list lt-sym (list minus-sym nt1 fc) wsym)
                                                                   (list minus-sym nt1 fc)
                                                                   wsym)))
                                              (list let-sym
                                                    (list (list row-sym (list div-sym idg gc))
                                                          (list col-sym (list plus-sym fc (list rem-sym idg gc))))
                                                    inner-body))))))))))

;; src/analysis/control.lisp
(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Outer loop over tile origins, workgroup-strided.  Phase 1b: pre-walks the
   body to rewrite bare load-tile / store-tile into their -coords forms using
   the tile-stride's binding syms as the origin.

   Endeavor 144 Phase 1: when the visit order should be GROUPED (rank 2, compile-time tile
   size-list, an active profile with :l2-cache-size — see %tile-visit-strip-width), emit the
   L2-aware column-strip walk instead.  Everything else takes the original linear expansion
   completely unchanged."
  (declare (ignore ct))
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore strict-p layout-tag))
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
        :message "Malformed tile-stride: expected (tile-stride TENSOR [LAYOUT-TAG] <TILE-SPEC> (BINDING ...) BODY...)"
        :source-location location))
    (let* ((n (length bindings))
           (cl-pkg (find-package :crisp-language))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (ts-syms (loop for i from 0 below n
                          collect (gensym (format nil "TS~A" i))))
           (tile-size-expr-fn
            (ecase tile-spec-kind
              (:size-list
               (let ((sizes tile-spec))
                 (lambda (k) (list to-ulong-sym (nth k sizes)))))
              (:tile-tensor
               (let ((tile-form tile-spec))
                 (lambda (k)
                   (list aref-sym (list extents-tilde-sym tile-form) k))))))
           (strip-width (%tile-visit-log-decision
                         n tile-spec-kind tile-spec
                         (%tile-visit-strip-width
                          n (when (eq tile-spec-kind :size-list) tile-spec)))))
      (if (> strip-width 1)
          (%expand-tile-stride-swizzled tensor-form bindings body-forms ts-syms
                                        tile-size-expr-fn strip-width location)
          (%expand-workgroup-strided-outer-loop-with-ts-syms
           tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)))))

;; src/analysis/control.lisp
;; Endeavor 144 Phase 1 — visibility on the visit-order decision.  Logged (log4cl, so it
;; costs nothing at --log-level=off) because "did the swizzle actually engage?" is otherwise
;; invisible: the choice leaves no trace in the kernel source and only a subtle one in the IR.
;; src/analysis/control.lisp
(defun %tile-visit-log-decision (n tile-spec-kind tile-spec strip-width)
  "Report the tile visit-order decision for one tile-stride expansion."
  (log:info "tile-visit: rank=~a spec-kind=~a spec=~a -> strip-width=~a (~a)"
            n tile-spec-kind tile-spec strip-width
            (if (> strip-width 1) "GROUPED" "linear"))
  strip-width)

;;; ===================================================================
;;; ENDEAVOR 144 Phase 1 REVISION (2026-07-28) — the visit-order gate becomes an
;;; EXPLICIT, MEASURED profile fact instead of an inference from :l2-cache-size.
;;;
;;; WHY.  The original gate was "the profile supplies :l2-cache-size", on the theory that the
;;; win appears once the working set outgrows L2.  Measured on two devices, that theory is
;;; REFUTED and the gate actively caused a regression:
;;;
;;;   Arc B580 (18 MB L2) @2048, 50 MB working set = 2.8x L2 : linear 17.1 -> W4 27.9  (+63%)
;;;   H100 PCIe (50 MB L2) @4096, 200 MB           = 4.0x L2 : linear 207.4 -> W4 190.2 (-8.3%)
;;;                                                            and W16 177.6 (-14.4%, MONOTONIC)
;;;
;;; H100 at 4096 is FURTHER past its cache than BMG was when it fell off, and shows no cliff at
;;; all — linear keeps scaling (36.95 -> 59.60 TFLOPS on one chapter, 207.4 on another).  So L2
;;; multiples do not govern this, and neither does bandwidth-per-FLOP (the two parts have broadly
;;; similar GB/s-per-TFLOP).  Tile shape matters too: the 64x256 wgmma tile degrades monotonically
;;; with width, because a W-wide strip spans 256*W columns and degenerates to the whole matrix.
;;;
;;; With two devices, opposite outcomes, and no predictor that survives both, the honest design is
;;; a measured per-machine number recorded where machine facts live — NOT a formula that is right
;;; half the time.  Absent key => linear, so a profile that says nothing gets the old behaviour.
;;;
;;; D1 is intact: this is a PROFILE key (a fact about the target), not kernel syntax.  A kernel
;;; still cannot encode a machine-tuning constant.
;;; ===================================================================

;; src/hardware-profile.lisp
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
    (:mma-shapes                  . :mma-shapes)) ; list of (M N K) triples
  "Endeavor 130: canonical hardware-profile keys and their value types.

   Endeavor 144 added two.  :max-registers-per-thread became :pos-int-or-modes (D4) — a scalar
   for a fixed per-thread allocation, or an ascending list of selectable modes for hardware whose
   register file is a JIT-time choice.  :tile-visit-strip-width (Phase 1 revision) is the
   MEASURED column-strip width for grouped tile-stride visit order on this machine; 1 or absent
   means walk linearly.  It is deliberately a measured constant rather than a derived one — see
   the block comment above for the two-device data that refuted the derivation.")

;; src/compiler.lisp
(defun %tile-visit-strip-width (n tile-sizes)
  "Endeavor 144 Phase 1: the column-strip width for a rank-N tile-stride whose tile is
   TILE-SIZES.  1 means 'walk linearly' (the caller then emits the untouched expansion).

   Reads the ACTIVE PROFILE's measured :tile-visit-strip-width.  Absent => 1 => linear, so any
   profile that does not explicitly opt in keeps the original behaviour.  This replaced a
   derivation from :l2-cache-size, which was refuted by measurement on two devices (+63% on one,
   -14% on the other, both supplying that key) — see the block comment above.

   Still gated to rank 2 with a compile-time (M N) size-list: the swizzled expansion is written
   for a 2-D tile grid, and the width is meaningless without knowing the tile shape.
   CRISP_TILE_VISIT overrides everything, for bisecting and for sweeping the width empirically."
  (let ((override (%tile-visit-override)))
    (cond
      ((eq override :linear) 1)
      ((integerp override) override)
      ((/= n 2) 1)
      ((not (and (listp tile-sizes) (= (length tile-sizes) 2)
                 (every (lambda (x) (and (integerp x) (plusp x))) tile-sizes)))
       1)
      (t (let* ((profile (active-hardware-profile))
                (w (and profile (getf profile :tile-visit-strip-width))))
           (if (and (integerp w) (plusp w))
               (min w *tile-visit-max-strip-width*)
               1))))))

;; src/mma.lisp
(defun register-builtin-hardware-profiles ()
  "Endeavor 144 Phase 0 (D2): register Crisp's predefined hardware profiles.

   Called from register-mma-types, which initialize-compiler invokes AFTER it clrhash-es
   *hardware-profiles* — so builtins survive the clear and a same-named user profile still
   overrides them.

   NOTE FOR THE SRC PATCH: this belongs as its own call in initialize-compiler next to
   register-builtins."
  ;; Intel Arc B580 (Battlemage / Xe2).  Device-queried 2026-07-27.
  ;; :tile-visit-strip-width 4 — MEASURED: grouped visit order is worth +63% at 2048 here
  ;; (linear 17.1 -> 27.9 TFLOPS), and 4 beat 2/8/16 across both sizes tested.
  (register-hardware-profile
   'bmg
   '(:simd-width 16                        ; subGroupSizes reports BOTH 16 and 32
     :compute-units 20                     ; Xe-cores (5 slices x 4 subslices)
     :max-registers-per-thread (128 256)   ; GRF registers (32 B each) — selectable modes
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 1024)
     :max-shared-memory-per-block 128KB
     :l2-cache-size 18MB
     :native-cache-line-size 64            ; Xe2 LSC line; not queryable
     :tile-visit-strip-width 4             ; measured; see the Phase 1 revision comment
     :mma-shapes ((8 16 8))))              ; XMX tf32
  ;; NVIDIA H100 PCIe (Hopper).  Device-queried 2026-07-28.
  ;; :compute-units 114 is the PCIe part (SXM is 132); this value OVERRIDES the device SM query
  ;; in the generated CUDA launch grid, so the variant distinction is load-bearing.
  ;; :max-shared-memory-per-block is the OPT-IN cap, not the 48KB default (chap2/chap3 exceed 48KB).
  ;; :mma-shapes MUST include (16 8 8) — chap0/1/1.5/2 all pass that tf32 shape.
  ;; NO :tile-visit-strip-width — MEASURED: grouped order is neutral-to-harmful here (chap2 worse
  ;; at every width; chap3_wgmma -8.3% at W=4 degrading monotonically to -14.4% at W=16), and no
  ;; cliff appears even at 4x L2.  Omitting the key means linear, which is what this part wants.
  (register-hardware-profile
   'h100
   '(:simd-width 32
     :compute-units 114
     :max-registers-per-cu 65536
     :max-registers-per-thread 255
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 64)
     :max-shared-memory-per-block 227KB
     :l2-cache-size 50MB
     :native-cache-line-size 128
     :mma-shapes ((16 8 8) (16 8 4) (16 8 16)))))

;;; ===================================================================
;;; ENDEAVOR 144 Phase 5 — RE-SCOPED (decision 2026-07-28, made unattended under standing
;;; authorization; rationale recorded so it can be reversed knowingly).
;;;
;;; PLANNED: `:ring-count :max` — the compiler picks the deepest pipeline ring that fits
;;; :max-shared-memory-per-block.  NOT SHIPPED.  Three reasons, two of them measured inside
;;; this very endeavor:
;;;
;;;   1. Endeavor 138 already measured a pipelining/occupancy CROSSOVER on this exact axis:
;;;      deeper rings bought +7-9% but cost -6% occupancy, and the sign flipped by 4096.
;;;      "Deepest that fits" is therefore not a maximum of anything the user cares about.
;;;   2. Phase 4 measured that granting more of a resource can LOSE badly: large-GRF is a
;;;      2.01x win on a register-resident kernel and a -38% loss on an occupancy-bound one.
;;;      Same shape of decision, opposite answers, from the same "more is better" instinct.
;;;   3. Phase 1 measured that occupancy REASONING (as opposed to occupancy measurement)
;;;      predicted the wrong sign twice in one session — the L2 cliff that wasn't, and the
;;;      strip width that didn't matter.
;;;
;;; The plan document's own framing was "the profile lets the compiler BOUND AND REPORT the
;;; tradeoff, not blindly maximize."  That is what ships.  (Secondary, but not the reason:
;;; `:max` would need src/macros.lisp patched, since the ring constructors are macros and the
;;; overlay cannot late-bind them.)
;;;
;;; WHAT SHIPS: per-kernel SLM utilization against the profile cap.
;;;   - Always logged (log4cl, free at --log-level=off).
;;;   - stderr WARNING only above *slm-high-water-fraction*, where the number is ACTIONABLE:
;;;     near the cap, SLM is what limits resident blocks.
;;;   - Low utilization is reported, NOT warned.  chap2_pipelined_block using 8 KB of a
;;;     227 KB budget is the observation that motivated this phase, but "you have headroom"
;;;     is information, not a defect — see reasons 1-3 for why we do not act on it for you.
;;; ===================================================================

;; src/hardware-profile.lisp
(defparameter *slm-high-water-fraction* 3/4
  "Endeavor 144 Phase 5: warn when a kernel's local/shared memory reaches this fraction of the
   profile's :max-shared-memory-per-block.  Above it, SLM (not registers) is what caps resident
   blocks per compute unit, which is worth saying out loud.  Below it the utilization is only
   logged.")

;; src/hardware-profile.lisp
(defun %hp-report-shared-memory (kernel-name profile)
  "Endeavor 144 Phase 5: report KERNEL-NAME's local/shared memory against the profile cap.

   Reports utilization; does NOT choose a ring depth or tile size.  Returns the byte total, or
   NIL when the profile omits the cap or the total is not compile-time-known (symbolic scratch
   sizes)."
  (let ((cap  (and profile (getf profile :max-shared-memory-per-block)))
        (used (%hp-kernel-shared-bytes kernel-name)))
    (when (and cap used (plusp cap))
      (let ((frac (/ (cl:float used) cap)))   ; cl: REQUIRED — `float` in :crisp.compiler is the Crisp TYPE symbol
        (log:info "slm: kernel ~a uses ~a of ~a bytes (~,1f%) of :max-shared-memory-per-block"
                  kernel-name used cap (* 100.0 frac))
        (when (>= frac *slm-high-water-fraction*)
          (format *error-output*
                  "WARNING: kernel ~a reserves ~a of ~a bytes of local/shared memory (~,1f%).  Above ~,0f% of the cap, SLM is what limits how many blocks can be resident per compute unit — deeper pipeline rings or larger tiles will now cost occupancy rather than add overlap.~%"
                  kernel-name used cap (* 100.0 frac)
                  (* 100.0 *slm-high-water-fraction*)))
        used))))

;; src/hardware-profile.lisp
(defun %hp-check-all-shared-memory ()
  "Endeavor 130 Phase 2: after a module compiles (all signatures, incl. implicit scratch,
   finalized), validate every kernel's local memory against the active hardware profile.

   Endeavor 144 also runs, from this same end-of-module hook: the SPV register-mode decision
   (Phase 4) and the SLM utilization report (Phase 5).

   NOTE FOR THE SRC PATCH: in src/ these belong as their OWN calls in compile-module (after
   %hp-check-all-shared-memory, analysis/core.lisp:424).  They are folded in here only so the
   overlay does not have to redefine the whole compile-module function."
  (let ((profile (active-hardware-profile)))
    (when profile
      (dolist (k *compiled-kernels*)
        (%hp-check-shared-memory k profile)
        (%hp-report-shared-memory k profile))
      (when (eq *target-backend* :spirv)
        (dolist (k *compiled-kernels*)
          (%spv-decide-register-mode k profile))))))

;;; ===================================================================
;;; ENDEAVOR 144 Phase 3 — RE-SCOPED (decision 2026-07-28, unattended, rationale recorded).
;;;
;;; PLANNED: a full occupancy model — resident blocks per compute unit from registers AND
;;; shared memory — feeding Phase 1's strip-width formula.
;;;
;;; WHY RE-SCOPED, two independent reasons:
;;;   1. Its consumer evaporated.  Phase 3 existed largely to supply
;;;      W = sqrt(R * tile_M / tile_N) for Phase 1.  Phase 1 then MEASURED that the width
;;;      barely matters (grouped-vs-linear ~60%, width within 2..16 ~4%) and that the whole
;;;      optimization is device-specific anyway.  Building a model to feed a formula we
;;;      retired would be building the wrong thing carefully.
;;;   2. The SLM half needs a NEW SCHEMA KEY.  Resident blocks per CU wants shared memory per
;;;      COMPUTE UNIT; `:max-shared-memory-per-block` is per BLOCK (227KB on H100, where the
;;;      per-SM figure is a different 228KB).  Inventing a schema key unattended is exactly
;;;      the class of decision the user asked to make deliberately (cf. D4), and Phase 5 now
;;;      reports SLM utilization directly, which covers the practical need.
;;;
;;; WHAT SHIPS: a REGISTER-side occupancy diagnostic built only from keys that already exist
;;; (`:max-registers-per-cu`, the per-thread demand this endeavor already tallies, and
;;; local-size).  It answers the one question the register work kept raising and could not
;;; answer — "how many blocks of this kernel actually fit on a compute unit?" — and it warns
;;; only when the answer is 1, which is the case where the kernel cannot hide any latency.
;;;
;;; Accounted demand is what the developer EXPLICITLY reserved (register tiles, rings, wgmma
;;; accumulators), never what ptxas finally allocates.  So the reported occupancy is an UPPER
;;; bound: the real figure can only be worse.  Stated in the message, because an occupancy
;;; number that looks authoritative but is optimistic would be worse than none.
;;; ===================================================================

;; src/mma.lisp
(defvar *ptx-register-demand* (make-hash-table :test 'equal)
  "Endeavor 144 Phase 3: (kernel-name . source-location) -> 32-bit registers/thread explicitly
   reserved at that site on the NVIDIA path (register tiles and wgmma accumulators).  Keyed per
   site and ASSIGNED, so Crisp's multipass re-analysis is idempotent — same discipline as
   *spv-register-demand*.")

;; src/mma.lisp
(defun %ptx-note-register-demand (regs context location)
  "Record REGS 32-bit registers/thread reserved at LOCATION for the kernel being compiled.
   No-op off the NVIDIA path or without a current function."
  (unless (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when (and fn (plusp regs))
        (setf (gethash (cons fn location) *ptx-register-demand*) regs)))))

;; src/mma.lisp
(defun %kernel-registers-per-thread (kernel-name)
  "Total explicitly-reserved registers/thread for KERNEL-NAME.  NVIDIA: 32-bit registers from
   *ptx-register-demand*.  Intel/SPV: derived from the GRF element tally.  0 when nothing was
   reserved."
  (if (eq *target-backend* :spirv)
      (values (%spv-kernel-register-demand kernel-name))
      (let ((total 0))
        (maphash (lambda (k v) (when (equal (car k) kernel-name) (incf total v)))
                 *ptx-register-demand*)
        total)))

;; src/hardware-profile.lisp
(defun %hp-report-register-occupancy (kernel-name profile)
  "Endeavor 144 Phase 3: report how many blocks of KERNEL-NAME fit on one compute unit, as
   limited by REGISTERS.

     blocks/CU = :max-registers-per-cu / (registers-per-thread * threads-per-block)

   Skipped unless the profile supplies :max-registers-per-cu, the kernel reserved registers,
   and local-size is compile-time known.  Warns only at 1 block/CU — the case where there is no
   second block to hide latency behind.  The figure is an UPPER bound (explicit reservations
   only, not the final ptxas allocation)."
  (let ((per-cu (and profile (getf profile :max-registers-per-cu)))
        (regs   (%kernel-registers-per-thread kernel-name))
        (dims   (let ((d (gethash kernel-name *kernel-dispatch-declarations*)))
                  (and d (%hp-local-size-dims (getf d :local-size))))))
    (when (and per-cu (plusp per-cu) regs (plusp regs) dims)
      (let* ((threads (reduce #'* dims))
             (per-block (* regs threads))
             (blocks (floor per-cu (max 1 per-block))))
        (log:info "occupancy: kernel ~a reserves ~a regs/thread x ~a threads = ~a regs/block; ~a of ~a regs/CU -> ~a block(s)/CU (upper bound)"
                  kernel-name regs threads per-block per-block per-cu blocks)
        (when (<= blocks 1)
          (format *error-output*
                  "WARNING: kernel ~a reserves ~a registers/thread x ~a threads = ~a registers per block, against ~a per compute unit — so at most ~a block~:p can be resident.  With a single resident block there is nothing to overlap its memory stalls against; consider a smaller tile/accumulator, or distributing it across more warps (:warps).  (Upper bound: counts only explicit reservations, not the final register allocation.)~%"
                  kernel-name regs threads per-block per-cu blocks))
        blocks))))

;; src/mma.lisp
(defun %register-tile-fit-check (m n location)
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/16)x(N/8) accumulator fragments x 4 fp32 regs <=
   :max-registers-per-thread.

   Endeavor 144: reads the budget through %hp-registers-per-thread-default (D4 made the key a
   scalar OR a list of selectable modes), and Phase 3 TALLIES the reservation for the
   per-compute-unit occupancy report."
  (unless (eq *target-backend* :spirv)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (budget        (or (%hp-registers-per-thread-default)
                              *default-max-registers-per-thread*)))
      (%ptx-note-register-demand total-regs *current-compiler-context* location)
      (when (> total-regs budget)
        (error 'crisp-compiler-error
               :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                m n total-regs nfrags regs-per-frag budget)
               :source-location location)))))

;;; --- Phase 3 correction: tally where CONTEXT is actually available -------------------------
;;; %register-tile-fit-check takes only (m n location) — there is no current-context special to
;;; reach the kernel name from, and adding a parameter would mean redefining the 90-line
;;; %explode-register-tiles.  The fragment/accumulator ANALYZERS already receive context and are
;;; already overridden here, so the PTX tally goes there instead — exactly mirroring how the SPV
;;; side works, which keeps one mental model for both backends.

;; src/mma.lisp
(defun %register-tile-fit-check (m n location)
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/16)x(N/8) accumulator fragments x 4 fp32 regs <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes."
  (unless (eq *target-backend* :spirv)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (budget        (or (%hp-registers-per-thread-default)
                              *default-max-registers-per-thread*)))
      (when (> total-regs budget)
        (error 'crisp-compiler-error
               :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                m n total-regs nfrags regs-per-frag budget)
               :source-location location)))))

;; src/mma.lisp
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand).  :spirv -> a filled coop matrix;
   else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default acc) picks
   the coop-matrix Use + shape so an A/B operand tile mints fragments matching load-fragment-a/b.

   Endeavor 144: each fragment is tallied against the current kernel — as coop-matrix ELEMENTS on
   SPV (Phase 4's GRF model) and as 32-bit REGISTERS on PTX (Phase 3's occupancy model).  Both
   skip when the form carries :tally nil, which marks fill-tile's per-fragment set!s: those
   RE-INITIALIZE fragments the tile already owns and allocate nothing."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))
              (when tally-p (%spv-note-register-fragment fr fc context location))
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float fr fc use) :kind :fill
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
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 per-compute-unit occupancy report."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (%wgmma-acc-fit-check m n location)
      (%ptx-note-register-demand (floor n 2) context location)
      (let ((type-name (%ensure-wgmma-acc-type n)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))

;; src/hardware-profile.lisp
(defun %hp-check-all-shared-memory ()
  "Endeavor 130 Phase 2: after a module compiles (all signatures, incl. implicit scratch,
   finalized), validate every kernel's local memory against the active hardware profile.

   Endeavor 144 runs three further per-kernel reports from this same end-of-module hook:
   the SPV register-mode decision (Phase 4), SLM utilization (Phase 5), and register-limited
   occupancy (Phase 3).

   NOTE FOR THE SRC PATCH: in src/ these belong as their OWN calls in compile-module (after
   %hp-check-all-shared-memory, analysis/core.lisp:424); they are folded in here only so the
   overlay need not redefine compile-module."
  (let ((profile (active-hardware-profile)))
    (when profile
      (dolist (k *compiled-kernels*)
        (%hp-check-shared-memory k profile)
        (%hp-report-shared-memory k profile)
        (%hp-report-register-occupancy k profile))
      (when (eq *target-backend* :spirv)
        (dolist (k *compiled-kernels*)
          (%spv-decide-register-mode k profile))))))

;;; --- Phase 3 correction #2: wgmma accumulators are keyed by SHAPE, not by site -------------
;;; Caught by the diagnostic's own first run: chap3_wgmma reported 256 regs/thread for a 128-reg
;;; accumulator, because the kernel legitimately contains TWO construction sites for ONE
;;; accumulator —
;;;     (let ((D (make-wgmma-accumulator float (64 256) 0.0))) ...
;;;       (:consumer (set! D (make-wgmma-accumulator float (64 256) 0.0)) ...
;;; — the second being a per-tile RE-INITIALIZATION of D's existing storage.  Same class as
;;; fill-tile's per-fragment set!s, but written by the USER, so it cannot be tagged :tally nil.
;;;
;;; Fix: key the wgmma tally on (kernel, shape) rather than (kernel, site), so repeated
;;; constructions of the same accumulator collapse to one reservation.  Register FRAGMENTS keep
;;; per-site keying, because there each site really is distinct storage.
;;;
;;; Known limitation, stated rather than hidden: a kernel holding two GENUINELY distinct
;;; accumulators of identical shape would be counted once.  That under-counts, which conflicts
;;; with the "upper bound" framing — so the report says "distinct reservations by shape".  The
;;; alternative (summing sites) demonstrably over-counted our best kernel by 2x and fired a
;;; spurious warning on it, and a diagnostic that cries wolf on the flagship kernel is worse
;;; than one with a documented edge case.
;;; ===================================================================

;; src/mma.lisp
(defun %ptx-note-register-demand-keyed (regs context key)
  "Record REGS 32-bit registers/thread for the kernel being compiled, under KEY.  KEY is the
   identity of the RESERVATION: a source location where each site is distinct storage
   (fragments), or a shape where repeated construction means re-initialization (wgmma)."
  (unless (eq *target-backend* :spirv)
    (let ((fn (and context (compiler-context-current-compiling-function context))))
      (when (and fn (plusp regs))
        (setf (gethash (cons fn key) *ptx-register-demand*) regs)))))

;; src/mma.lisp
(defun %ptx-note-register-demand (regs context location)
  "Per-SITE reservation (register fragments): each source location is distinct storage."
  (%ptx-note-register-demand-keyed regs context location))

;; src/mma.lisp
(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct.

   Endeavor 144: runs the Phase 2 register accounting, and tallies N/2 registers/thread for the
   Phase 3 occupancy report — keyed by SHAPE so a per-tile `(set! D (make-wgmma-accumulator ...))`
   re-initialization is not counted as a second accumulator."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (%wgmma-acc-fit-check m n location)
      (%ptx-note-register-demand-keyed (floor n 2) context (list :wgmma-acc m n))
      (let ((type-name (%ensure-wgmma-acc-type n)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))

;; src/hardware-profile.lisp
(defun %hp-report-register-occupancy (kernel-name profile)
  "Endeavor 144 Phase 3: report how many blocks of KERNEL-NAME fit on one compute unit, as
   limited by REGISTERS.

     blocks/CU = :max-registers-per-cu / (registers-per-thread * threads-per-block)

   Skipped unless the profile supplies :max-registers-per-cu, the kernel reserved registers, and
   local-size is compile-time known.  Warns only at 1 block/CU — the case where there is no
   second block to hide memory stalls behind.

   Counts DISTINCT explicit reservations (fragments per site, wgmma accumulators per shape) —
   never the final ptxas allocation, which can only be larger."
  (let ((per-cu (and profile (getf profile :max-registers-per-cu)))
        (regs   (%kernel-registers-per-thread kernel-name))
        (dims   (let ((d (gethash kernel-name *kernel-dispatch-declarations*)))
                  (and d (%hp-local-size-dims (getf d :local-size))))))
    (when (and per-cu (plusp per-cu) regs (plusp regs) dims)
      (let* ((threads (reduce #'* dims))
             (per-block (* regs threads))
             (blocks (floor per-cu (max 1 per-block))))
        (log:info "occupancy: kernel ~a reserves ~a regs/thread x ~a threads = ~a regs/block; ~a regs/CU -> ~a block(s)/CU"
                  kernel-name regs threads per-block per-cu blocks)
        (when (<= blocks 1)
          (format *error-output*
                  "WARNING: kernel ~a reserves ~a registers/thread x ~a threads = ~a registers per block, against ~a per compute unit — so at most ~a block~:p can be resident.  With a single resident block there is nothing to overlap its memory stalls against; consider a smaller tile/accumulator, or distributing it across more warps (:warps).  (Counts explicit reservations only; the final allocation can only be larger.)~%"
                  kernel-name regs threads per-block per-cu blocks))
        blocks))))
