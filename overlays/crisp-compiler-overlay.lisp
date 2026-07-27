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
         (budget  (or (and profile (getf profile :max-registers-per-thread))
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

