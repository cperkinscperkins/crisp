;;;; src/hardware-profile.lisp
;;;;
;;;; Endeavor 130 — hardware profiles.
;;;;
;;;; A `def-hardware-profile` names a plist of hardware capabilities / limits that
;;;; is selected at *deployment* time (via the --hardware-profile flag), NOT chosen
;;;; in source (there is deliberately no declaim / with- form — a hardware profile
;;;; is a fact about the target, not an algorithmic choice like precision).
;;;;
;;;; This file owns: the canonical key schema + per-key value validation, profile
;;;; registration (register-hardware-profile, the target of the def-hardware-profile
;;;; macro), active-profile resolution, and the compile-time consumers — workgroup
;;;; bounds (Phase 1), shared-memory / SLM bounds (Phase 2), and the metacrisp
;;;; serializer that carries the active profile to the hoist (Phase 5).
;;;;
;;;; The registry vars *hardware-profiles* and *requested-hardware-profile* live in
;;;; src/compiler.lisp (with the other compiler-session state), because
;;;; initialize-compiler references them.

(in-package :crisp.compiler)


;;; ===================================================================
;;; Phase 0 — def-hardware-profile registration + canonical key schema
;;; + per-key value validation.
;;; ===================================================================

(defparameter *hardware-profile-schema*
  '((:simd-width                  . :pos-int)
    (:compute-units               . :pos-int)
    (:max-registers-per-cu        . :pos-int)
    (:max-registers-per-thread    . :pos-int)
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
   compile error; any subset may be specified (missing keys are fine).")

(defun %hp-parse-size (v)
  "Parse a size value into bytes: a positive integer, or a size-literal symbol
   like 227KB / 50MB / 8GB / 2TB.  Returns the byte count, or NIL if unparseable."
  (cond
    ((and (integerp v) (plusp v)) v)
    ((symbolp v)
     (let* ((name (string-upcase (symbol-name v)))
            (n (length name)))
       (when (> n 2)
         (let ((mult (cond ((string= (subseq name (- n 2)) "KB") 1024)
                           ((string= (subseq name (- n 2)) "MB") (expt 1024 2))
                           ((string= (subseq name (- n 2)) "GB") (expt 1024 3))
                           ((string= (subseq name (- n 2)) "TB") (expt 1024 4))
                           (t nil))))
           (when mult
             (let ((num (ignore-errors (parse-integer name :end (- n 2)))))
               (when (and num (plusp num)) (* num mult))))))))
    (t nil)))

(defun %hp-unquote (v)
  "Unwrap (quote X) -> X; otherwise return V unchanged."
  (if (and (consp v) (eq (car v) 'quote)) (cadr v) v))

(defun %hp-3-pos-ints-p (x)
  "T if X is a list of exactly 3 positive integers."
  (and (listp x) (= (length x) 3)
       (every (lambda (e) (and (integerp e) (plusp e))) x)))




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

(defun register-hardware-profile (name proplist)
  "Endeavor 130 Phase 0: parse, validate, and register a hardware profile.
   Unknown key -> error; malformed value -> error; duplicate key within one
   profile -> error; missing keys are fine (a partial profile is valid).  Keyed in
   *hardware-profiles* by the upcased profile name (package-agnostic)."
  (unless (symbolp name)
    (error "def-hardware-profile: expected a name symbol, got ~s." name))
  (when (oddp (length proplist))
    (error "def-hardware-profile ~a: keys and values must pair up (odd number of elements)." name))
  (let ((normalized nil)
        (seen nil))
    (loop for (key val) on proplist by #'cddr do
      (unless (keywordp key)
        (error "def-hardware-profile ~a: expected a keyword key, got ~s." name key))
      (let ((entry (assoc key *hardware-profile-schema*)))
        (unless entry
          (error "def-hardware-profile ~a: unknown key ~a.  Valid keys: ~{~a~^ ~}."
                 name key (mapcar #'car *hardware-profile-schema*)))
        (when (member key seen)
          (error "def-hardware-profile ~a: duplicate key ~a." name key))
        (push key seen)
        (setf (getf normalized key) (%hp-validate-value name key (cdr entry) val))))
    (setf (gethash (string-upcase (symbol-name name)) *hardware-profiles*) normalized)
    name))


;;; ===================================================================
;;; Phase 1 — selection + first consumer (workgroup / local-size bounds).
;;; ===================================================================

(defun active-hardware-profile ()
  "Resolve the requested hardware profile (--hardware-profile) to its normalized
   plist, or NIL if none was requested.  Errors if a profile was requested but is
   not registered (a typo'd flag, or a name no def-hardware-profile defines)."
  (when *requested-hardware-profile*
    (let ((p (gethash (string-upcase *requested-hardware-profile*) *hardware-profiles*)))
      (unless p
        (error "Hardware profile ~s not found.  Define it with def-hardware-profile (in a .crisp file passed to the compiler).  Known profiles: ~{~a~^ ~}."
               *requested-hardware-profile*
               (loop for k being the hash-keys of *hardware-profiles* collect k)))
      p)))

(defun %hp-local-size-dims (local-size-decl)
  "Extract concrete (X Y Z) workgroup dims from a (local-size :set-to <val>) decl,
   normalizing a scalar or short list to three dims.  Returns NIL when the local
   size is not compile-time-known (:derive-from / :strategy / absent), in which
   case profile bounds can't be checked."
  (when (consp local-size-decl)
    (let ((v (getf (cdr local-size-decl) :set-to)))
      (cond
        ((and (integerp v) (plusp v)) (list v 1 1))
        ((and (listp v) v (<= 1 (length v) 3)
              (every (lambda (x) (and (integerp x) (plusp x))) v))
         (append v (make-list (- 3 (length v)) :initial-element 1)))
        (t nil)))))

(defun %hp-check-workgroup-bounds (kernel-name local-size-decl profile)
  "Endeavor 130 Phase 1: when PROFILE is active and the local size is
   compile-time-known, error if the workgroup exceeds the profile's
   :max-total-threads-per-block or any :max-work-group-dims axis.  Missing keys are
   skipped (a partial profile simply checks less)."
  (when profile
    (let ((dims (%hp-local-size-dims local-size-decl)))
      (when dims
        (let ((max-total (getf profile :max-total-threads-per-block))
              (max-dims   (getf profile :max-work-group-dims)))
          (when max-total
            (let ((total (reduce #'* dims)))
              (when (> total max-total)
                (error "Kernel ~a: local-size ~a = ~a threads exceeds the hardware profile's :max-total-threads-per-block (~a)."
                       kernel-name dims total max-total))))
          (when max-dims
            (loop for d in dims for m in max-dims for axis from 0
                  when (> d m)
                  do (error "Kernel ~a: local-size axis ~a (~a) exceeds the hardware profile's :max-work-group-dims axis ~a (~a)."
                            kernel-name axis d axis m))))))))


;;; ===================================================================
;;; Phase 2 — :max-shared-memory-per-block (local / SLM bounds).  Reuses
;;; generate-implicit-signature to enumerate a kernel's local scratch and
;;; sums bytes like the hoist's compute-total-shared-bytes.
;;; ===================================================================

(defun %hp-scratch-elem-bytes (elem-type)
  "Bytes per scratch element, matching the hoist's rule (compute-total-shared-bytes):
   64-bit element types -> 8, everything else -> 4 (the width the launcher reserves)."
  (let ((n (cond ((symbolp elem-type) (symbol-name elem-type))
                 ((consp elem-type)   (symbol-name (first elem-type)))
                 (t ""))))
    (if (member (string-upcase n) '("DOUBLE" "LONG" "ULONG" "INT64" "UINT64" "F64" "I64" "U64")
                :test #'string=)
        8 4)))

(defun %hp-kernel-shared-bytes (kernel-name)
  "Total local (shared) memory bytes a kernel reserves, summed from its implicit
   scratch signature (matching the hoist's `(* (expt size-expr rank) elem-bytes)`).
   Returns the byte total, or NIL if any local scratch size is not a compile-time
   integer (then the bound can't be checked and is skipped)."
  (let ((sig (first (gethash kernel-name *function-table*))))
    (when sig
      (let ((total 0) (known t))
        (dolist (p (generate-implicit-signature sig nil))
          (let ((as        (getf p :address-space))
                (type      (getf p :type))
                (size-expr (getf p :size-expr)))
            (when (and as (string-equal (string as) "LOCAL"))
              ;; size-expr is a SCALAR (vector: total = size^rank) or a LIST of dims
              ;; (matrix/tensor: total = product).  Symbolic sizes -> can't check (skip).
              (let* ((is-tensor (and (consp type)
                                     (member (symbol-name (first type))
                                             '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))
                     (rank (if (and is-tensor (integerp (third type))) (third type) 1))
                     (elem (if (consp type) (second type) type))
                     (count (cond
                              ((integerp size-expr) (expt size-expr rank))
                              ((and (listp size-expr) size-expr (every #'integerp size-expr))
                               (reduce #'* size-expr))
                              (t nil))))
                (if count
                    (incf total (* count (%hp-scratch-elem-bytes elem)))
                    (setf known nil))))))
        (when known total)))))

(defun %hp-check-shared-memory (kernel-name profile)
  "Endeavor 130 Phase 2: error if KERNEL-NAME's local/shared memory exceeds the
   profile's :max-shared-memory-per-block.  Skipped if the profile omits that key or
   the total isn't compile-time-known."
  (let ((cap (and profile (getf profile :max-shared-memory-per-block))))
    (when cap
      (let ((used (%hp-kernel-shared-bytes kernel-name)))
        (when (and used (> used cap))
          (error "Kernel ~a: uses ~a bytes of local/shared memory, exceeding the hardware profile's :max-shared-memory-per-block (~a bytes)."
                 kernel-name used cap))))))




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


;;; ===================================================================
;;; Phase 5 — carry the ACTIVE profile into the metacrisp so the hoist
;;; (and, later, runtime compilation) can use it.  Only the SELECTED
;;; profile is emitted (like structs / aliases, on need); the whole
;;; normalized profile is copied (not a subset), so it never has to be
;;; reparsed downstream.
;;; ===================================================================



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

;;;; ============================================================================================
;;;; Folded in from overlays/crisp-compiler-overlay.lisp on 2026-08-26.
;;;; These were appended to the overlay in this order and are kept in it, because
;;;; later definitions here reference earlier ones.
;;;; ============================================================================================
(defun %hp-mma-lowerings (profile)
  "The lowerings PROFILE offers, most-preferred first.  Absent means (:coop-matrix) -- the portable
   path every backend has had until now, which keeps every existing profile valid and unchanged."
  (or (and profile (getf profile :mma-lowerings))
      (list :coop-matrix)))
