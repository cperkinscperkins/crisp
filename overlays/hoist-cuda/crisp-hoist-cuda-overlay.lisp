;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for CUDA hoist improvements.
;;;; Applied via late binding - last definition wins.

(in-package :crisp.hoist.cuda)


;;; =====================================================================
;;; Endeavor 152 rung 04 — clustered launch in the CUDA hoist
;;;
;;; WHAT THIS DOES *NOT* DO, and why.  It does not switch to cuLaunchKernelEx.
;;; Crisp bakes the cluster shape into the PTX (.reqnctapercluster, emitted by
;;; %apply-cluster-dims-attribute), so the size is COMPILE-TIME FIXED -- which is
;;; precisely the case a plain launch handles, and the reason CUDA C++ offers
;;; __cluster_dims__ alongside the ordinary <<<>>> syntax.  cuLaunchKernelEx with
;;; CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION is for setting the shape DYNAMICALLY at
;;; launch, which we deliberately do not support (there is no :derive-from).
;;;
;;;   *** ASSUMPTION TO VERIFY ON THE POD (rung 04). ***  If a .reqnctapercluster
;;;   kernel in fact requires cuLaunchKernelEx, the launch fails LOUDLY with
;;;   CUDA_ERROR_INVALID_CLUSTER_SIZE rather than silently mis-running, so this is a
;;;   safe thing to be wrong about -- but it is an assumption, not a measurement.
;;;
;;; WHAT IT DOES DO: enforce grid divisibility, which IS measured.  The driver
;;; rejects a non-divisible grid per axis with CUDA_ERROR_INVALID_CLUSTER_SIZE
;;; (H100 PCIe, CUDA 12.4 -- see 00-verification-findings.md).  So something must
;;; happen, and the two strategies must differ:
;;;   :strided -- PAD up.  The tile-stride loop covers every tile, so the surplus
;;;               blocks simply find nothing to claim and exit.
;;;   :exact   -- ERROR.  No stride loop: padding would launch blocks with no tile,
;;;               truncating would skip tiles.  Neither is acceptable.
;;;
;;; The grid fix-up is INJECTED into emit-launch's output rather than emit-launch
;;; being copied.  emit-launch is 208 lines with one caller; transcribing it into an
;;; overlay to add ten lines in the middle is a worse risk than a documented,
;;; single-anchor text insertion in what is already a C++ *text generator*.  The
;;; anchor is the sole `unsigned int gridX = ` line every strategy branch emits.
;;; =====================================================================

(in-package :crisp.hoist.cuda)



;; Capture the ORIGINAL emit-launch once, so reloading this overlay cannot wrap the
;; wrapper.  defvar does not re-initialise, and the `unless` guards a fresh image.
(defvar *crisp-152-orig-emit-launch* nil)
(unless *crisp-152-orig-emit-launch*
  (setf *crisp-152-orig-emit-launch* (fdefinition 'emit-launch)))
#|
;; src/hoist-cuda/main.lisp
(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 152 wrapper around the original emit-launch: renders it to a string and
   injects the cluster grid reconciliation immediately after the grid dimensions are
   computed and before the launch that consumes them.

   Wrapped rather than copied on purpose -- the original is 208 lines and this adds
   about ten in the middle of it."
  (let* ((body (with-output-to-string (s)
                 (funcall *crisp-152-orig-emit-launch*
                          s dispatch-info shared-bytes compute-units kernel-name out-tile)))
         (fixup (%cuda-cluster-grid-fixup-string dispatch-info)))
    (if (string= fixup "")
        (write-string body stream)
        ;; Anchor: the single `unsigned int gridX = ` line that every strategy branch
        ;; emits.  If the anchor ever disappears we must NOT silently drop the fix-up --
        ;; a clustered kernel would then launch with an unreconciled grid and be
        ;; rejected by the driver with no explanation of why.
        (let ((pos (search "unsigned int gridX = " body)))
          (cond
            ((null pos)
             (warn "Endeavor 152: could not find the gridX anchor in emit-launch output for kernel ~a; cluster grid reconciliation NOT emitted."
                   kernel-name)
             (write-string body stream))
            (t
             (let ((eol (position #\Newline body :start pos)))
               (write-string body stream :end (1+ eol))
               (write-string fixup stream)
               (write-string body stream :start (1+ eol)))))))))
               |#


;;; =====================================================================
;;; Endeavor 152 rung 04 (fix) — `%%` is a printf escape, not a CL format escape
;;;
;;; CL's FORMAT only treats `~` specially; `%` passes through verbatim.  Writing
;;; `%%` (C printf habit) therefore emitted a LITERAL `%%` into the generated C++.
;;; In the comment that is merely wrong-looking; in the :exact branch it produced
;;; `(gridX %% _ccx)`, which does not compile.
;;;
;;; It hid because no spec in this endeavor declares :strategy :exact WITH a cluster,
;;; so the broken branch is never generated -- and the :strided branch, which is the
;;; one every spec exercises, has no modulus in it at all.
;;; =====================================================================


;;; =====================================================================
;;; Endeavor 152 rung 04/11 (fix) — inject AFTER the grid is final, not after gridX
;;;
;;; FOUND ON METAL.  The first cut anchored on `unsigned int gridX = `, which is wrong
;;; twice over and each way was invisible locally:
;;;
;;;  1. The TILE-SHAPE dispatch path declares the axes on SEPARATE lines --
;;;         unsigned int gridX = ...;   <- anchor matched here
;;;         unsigned int gridY = ...;   <- declared AFTER the injected block
;;;         unsigned int gridZ = 1;
;;;     so the emitted C++ referenced gridY/gridZ before they existed:
;;;         error: identifier "gridY" is undefined
;;;     The :set-to path declares all three on ONE line, which is why rung 04 passed on
;;;     the H100 and rung 11 did not.
;;;
;;;  2. Even where all three existed, the injection preceded the DEVICE GRID LIMIT
;;;     clamping, which lowers gridX toward maxGridDimX -- and a clamp applied after a
;;;     divisibility pad can BREAK the divisibility again.  That one would not have been a
;;;     compile error; it would have been an intermittent CUDA_ERROR_INVALID_CLUSTER_SIZE
;;;     on large problems only.
;;;
;;; Both fixed by moving the anchor to `auto _crisp_launch`, the lambda every strategy
;;; emits once, immediately after ALL grid computation and immediately before the launch
;;; that consumes it.  Injecting BEFORE that line means the reconciliation always sees the
;;; final values of all three axes.
;;;
;;; WHY LOCAL TESTING MISSED IT: there is no nvcc on the dev box, so every TEST-HOIST[CUDA]
;;; spec SKIPs.  The broken .cu WAS generated locally and I read it -- but I checked only
;;; that the block appeared, not that the identifiers it referenced were in scope yet.
;;; Generating C++ and reading it is not the same as compiling it.
;;; =====================================================================

;; src/hoist-cuda/main.lisp
(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 152 wrapper around the original emit-launch: renders it to a string and injects the
   cluster grid reconciliation immediately BEFORE the launch lambda -- i.e. after every strategy
   has finished computing gridX/gridY/gridZ and after the device-limit clamping, so the
   reconciliation is the last word on the grid."
  (let* ((body (with-output-to-string (s)
                 (funcall *crisp-152-orig-emit-launch*
                          s dispatch-info shared-bytes compute-units kernel-name out-tile)))
         (fixup (%cuda-cluster-grid-fixup-string dispatch-info)))
    (if (string= fixup "")
        (write-string body stream)
        ;; Anchor: the launch lambda, emitted exactly once by every path.  If it ever moves we
        ;; must NOT silently drop the fix-up -- a clustered kernel would then launch with an
        ;; unreconciled grid and be rejected by the driver with no explanation.
        (let ((pos (search "auto _crisp_launch" body)))
          (cond
            ((null pos)
             (warn "Endeavor 152: could not find the _crisp_launch anchor in emit-launch output for kernel ~a; cluster grid reconciliation NOT emitted."
                   kernel-name)
             (write-string body stream))
            (t
             ;; Back up to the start of that line so the injected block is not spliced into it.
             (let ((line-start (let ((nl (position #\Newline body :end pos :from-end t)))
                                 (if nl (1+ nl) 0))))
               (write-string body stream :end line-start)
               (write-string fixup stream)
               (write-string body stream :start line-start))))))))



;; src/hoist-cuda/main.lisp
;;
;; WRAPPED, not transcribed: emit-kernel-args is ~120 lines with one job to add -- seed the
;; cell offset for this kernel.  Copying it into the overlay would put a second stale copy
;; of a busy function in the tree.  Same approach, and same reasoning, as the emit-launch
;; wrapper above.  The captured original still resets *cuda-shared-scratch-offset* itself.
(defvar *crisp-045-orig-emit-kernel-args* nil)
(unless *crisp-045-orig-emit-kernel-args*
  (setf *crisp-045-orig-emit-kernel-args* (fdefinition 'emit-kernel-args)))

(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "BUG 046 wrapper: seeds *cuda-shared-cell-offset* from %cuda-shared-layout so LOCAL
   cells are laid out ABOVE the scratch tensors rather than on top of the first one."
  ;; NOTE: no log4cl here on purpose -- the hoister is built as its own application and
  ;; does not depend on log4cl (src/hoist-cuda/main.lisp contains zero log: calls).  The
  ;; layout it chose is visible in the emitted .cu as a `shared offset` comment per param.
  (setf *cuda-shared-cell-offset* (nth-value 1 (%cuda-shared-layout declared-sig aliases)))
  (funcall *crisp-045-orig-emit-kernel-args* stream declared-sig aliases records dispatch-info))



