;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;;; ===========================================================================
;;; Endeavor 140 reconcile (2026-07-21) — auto-skip TEST-HOIST[L0] on non-Intel hardware.
;;; The CUDA on-metal validators skip-gate on nvcc availability (validate-cuda-compile-only ->
;;; "SKIP (nvcc not available)"), but the L0 validators had NO equivalent — so the -bmg (Intel
;;; Level-Zero) tests HARD-FAILED on an NVIDIA pod (H100) instead of skipping.  This restores the
;;; symmetry: run-spec-with-hoist auto-skips the L0 backend when no Intel GPU (vendor 0x8086) is
;;; present, so -bmg tests skip on NVIDIA (H100/B300) and still RUN on Intel (BMG) pods — real Intel
;;; regressions are NOT masked (an Intel pod detects its GPU -> does not skip).
;;; ===========================================================================

(defun %intel-l0-gpu-available-p ()
  "T if an Intel GPU (PCI vendor 0x8086) is present so TEST-HOIST[L0] can actually run on metal.
   Explicit override: CRISP_L0_AVAILABLE=true|false.  Linux: scan /sys/class/drm/*/device/vendor.
   Non-Linux (can't probe): assume available so local runs are unchanged (the explicit SKIP_L0_HOIST
   env still applies in the original run-spec-with-hoist)."
  (let ((ov (uiop:getenv "CRISP_L0_AVAILABLE")))
    (cond
      ((and ov (string-equal ov "false")) nil)
      ((and ov (plusp (length ov))) t)                 ; any non-empty, non-"false" value forces on
      ((not (uiop:os-unix-p)) t)                        ; Windows/local: don't auto-skip
      (t (and (ignore-errors
                (some (lambda (vf)
                        (let ((v (with-open-file (s vf :if-does-not-exist nil)
                                   (and s (read-line s nil "")))))
                          (and v (search "0x8086" v))))
                      (directory #P"/sys/class/drm/*/device/vendor")))
              t)))))

;; wrapper-capture: skip the L0 hoist backend on non-Intel HW, else delegate to the original
;; (which still honors SKIP_L0_HOIST and does the real hoist).
(unless (fboundp 'orig-run-spec-with-hoist)
  (setf (fdefinition 'orig-run-spec-with-hoist) (fdefinition 'run-spec-with-hoist)))
(defun run-spec-with-hoist (file backend &optional bc-files)
  "Endeavor 140 reconcile: auto-skip the L0 backend when no Intel L0 GPU is present (mirrors the CUDA
   validators' nvcc skip-gate); otherwise delegate to the original run-spec-with-hoist."
  (if (and (string-equal (symbol-name backend) "L0")
           (not (%intel-l0-gpu-available-p)))
      (progn
        (format t "SKIP (Intel L0 GPU not available — mirrors the CUDA nvcc skip-gate)~%")
        :skipped)
      (funcall 'orig-run-spec-with-hoist file backend bc-files)))
