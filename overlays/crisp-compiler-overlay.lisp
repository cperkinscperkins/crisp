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

