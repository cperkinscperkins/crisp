;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; Endeavour 158.  Delegating stubs -- the bodies live in :crisp.compiler so the spec runner and
;; the compiler cannot drift.  Same convention as the 152/155/157 validators.
(defun validate-spv-prefetch-partitioned (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-PREFETCH-PARTITIONED" :crisp.compiler) spv-path))

(defun validate-spv-prefetch-unpartitioned (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-PREFETCH-UNPARTITIONED" :crisp.compiler) spv-path))
