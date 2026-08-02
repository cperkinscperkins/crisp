;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)




;; tests/run-specs.lisp
(defun validate-ptx-tma-grad (file ptx-string)
  "Endeavor 145 / BUG 038 — validates that the BACKWARD of a TMA-staging sub-function actually
   scatters a gradient, rather than merely compiling.

   137/04 cannot be gradient-checked numerically ANYWHERE: VERIFY-AUTODIFF has only :l0 and
   :opencl runtimes so it cannot drive a PTX backward, and the kernel cannot be lowered on
   SPV/GENERIC at all because a :block load inside a device sub-function falls back to a sync
   path needing `get-local-id`.  The mechanism it exercises IS proven numerically, by 145/17
   (void sub-function, exact gradient on BMG); what is unproven here is only that the TMA
   staging variant reaches the same place.

   So this validator asserts the one thing structural evidence CAN establish, and asserts it
   rather than leaving it to be eyeballed.  Before the 038 fix the backward kernel was EMPTY —
   zero global writes — because a void sub-function call was silently dropped by the AD walk.
   The fix inlines the callee, so the `load-tile` inside `stage` now produces its
   %load-tile-at-bwd edge: read the tile's adjoint from SHARED, atomically accumulate it into
   the GLOBAL source.  That pair of opcodes is the signature of a gradient actually flowing
   through the sub-function, and its ABSENCE is the exact regression that hid for a whole
   endeavor.

   Deliberately NOT a correctness proof — a wrong-but-present scatter would pass.  It is a
   guard against the backward silently becoming empty again."
  (declare (ignore file))
  (unless (search "tma_subfn_grad" ptx-string)
    (format *error-output* "FAIL: no backward kernel 'tma_subfn_grad' in the PTX.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; The gradient scatter itself.  f32 atomic add into global = adjoint accumulation.
  (unless (search "atom.global.add.f32" ptx-string)
    (format *error-output*
            "FAIL: backward has NO gradient scatter (expected 'atom.global.add.f32').~%~
             This is BUG 038's signature: an empty backward that still compiles.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; ...sourced from the staged tile in shared memory, which is what makes it the tile's
  ;; adjoint rather than some unrelated accumulation.
  (unless (search "ld.shared" ptx-string)
    (format *error-output*
            "FAIL: gradient scatter is not fed from shared memory — the staged tile's adjoint~%~
             is not what is being accumulated.~%")
    (return-from validate-ptx-tma-grad nil))
  ;; The forward TMA staging must still be there: the point is that AD did not cost us the
  ;; descriptor-driven copy.
  (unless (search "cp.async.bulk.tensor" ptx-string)
    (format *error-output* "FAIL: forward TMA staging (cp.async.bulk.tensor) lost under --differentiate.~%")
    (return-from validate-ptx-tma-grad nil))
  t)
