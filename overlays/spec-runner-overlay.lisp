;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)




;;; ---------------------------------------------------------------------------
;;; Endeavour 166 — device memory
;;; tests/run-specs.lisp
;;; ---------------------------------------------------------------------------

(defun validate-l0-device-memory (crisp-file cpp-files)
  "Validates that a generated L0 launcher allocates DEVICE memory and stages it.

   Three claims, checked as text so this runs with no GPU present:
     1. no `zeMemAllocShared` anywhere -- shared USM is no longer the hoist ABI;
     2. at least one `zeMemAllocDevice`;
     3. at least one `zeCommandListAppendMemoryCopy` -- device memory the host never
        stages to or from is device memory holding nothing, and every kernel this
        validator is pointed at has host-visible inputs or outputs.

   A launcher that allocates NOTHING (an empty kernel, a kernel whose every parameter is
   local or by-value) passes trivially: there is no allocation to get wrong.  Saying so
   explicitly matters, because the alternative -- failing it -- would push future specs
   toward adding a dummy buffer just to satisfy the validator."
  (declare (ignore crisp-file))
  (when (null cpp-files)
    (format t "FAIL: No C++ files to validate~%")
    (return-from validate-l0-device-memory nil))
  (let ((passed t))
    (dolist (cpp cpp-files)
      (let* ((content (uiop:read-file-string cpp))
             (name    (file-namestring cpp))
             (shared  (search "zeMemAllocShared" content))
             (devmem  (search "zeMemAllocDevice" content))
             (copy    (search "zeCommandListAppendMemoryCopy" content))
             (any-alloc (search "zeMemAlloc" content)))
        (cond
          ((null any-alloc)
           (format t "PASS: ~a allocates no USM (nothing to stage).~%" name))
          (t
           (when shared
             (format t "FAIL: ~a still calls zeMemAllocShared~%" name)
             (setf passed nil))
           (unless devmem
             (format t "FAIL: ~a allocates USM but never calls zeMemAllocDevice~%" name)
             (setf passed nil))
           (unless copy
             (format t "FAIL: ~a allocates device memory but never stages it ~
                       (no zeCommandListAppendMemoryCopy)~%" name)
             (setf passed nil))))))
    (when passed
      (format t "PASS: device memory + staging in all ~a file(s).~%" (length cpp-files)))
    passed))
