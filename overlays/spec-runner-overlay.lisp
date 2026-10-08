;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
;; Endeavour 180.  Two-package delegation, as for the 155/157 SPIR-V validators: the runner resolves
;; validator names in its own package; the implementations live in :crisp.compiler.
(defun validate-spv-stream-unrolled-x4 (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-STREAM-UNROLLED-X4" :crisp.compiler) spv-path))
(defun validate-spv-stream-unrolled-x8 (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-STREAM-UNROLLED-X8" :crisp.compiler) spv-path))
(defun validate-spv-stream-double-unrolled-x2 (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-STREAM-DOUBLE-UNROLLED-X2" :crisp.compiler) spv-path))
(defun validate-spv-stream-not-unrolled (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-STREAM-NOT-UNROLLED" :crisp.compiler) spv-path))


;; tests/run-specs.lisp -- SUPERSEDES the 1-argument delegator above (PTX validators take FILE PTX-TEXT).
(defun validate-ptx-has-nounroll-pragma (file ptx-text)
  (funcall (find-symbol "VALIDATE-PTX-HAS-NOUNROLL-PRAGMA" :crisp.compiler) file ptx-text))
