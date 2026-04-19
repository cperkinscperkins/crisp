;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

(defun validate-has-llvm-trap (file ir-string)
  "Validator for TEST-WITH[--runtime-checks]: verifies that llvm.trap
   appears in the generated IR, confirming that r-t-assert forms were
   emitted (not elided) when --runtime-checks is active."
  (declare (ignore file))
  (if (search "llvm.trap" ir-string)
      (progn
        (format t "PASS (llvm.trap found)~%")
        t)
      (progn
        (format t "FAIL: llvm.trap not found in IR (expected from r-t-assert under --runtime-checks)~%")
        nil)))



