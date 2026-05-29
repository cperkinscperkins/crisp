;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; ======================================================================
;; CUDA strategy content validator
;; ======================================================================
;;
;; Parallel to validate-l0-strategy-content — reads STRATEGY-EXPECT:
;; directives from the .crisp file and checks each one is present in
;; the generated .cu file(s).  No compilation or hardware needed.

(defun validate-cuda-strategy-content (crisp-file cu-files)
  "Validates generated .cu files contain expected strategy dispatch strings."
  (when (null cu-files)
    (format t "FAIL: No .cu files to validate~%")
    (return-from validate-cuda-strategy-content nil))
  (let* ((directives (extract-test-directives crisp-file))
         (expectations (parse-strategy-expect directives))
         (passed t))
    (when (null expectations)
      (format t "PASS: No STRATEGY-EXPECT directives (trivial pass).~%")
      (return-from validate-cuda-strategy-content t))
    (dolist (cu cu-files)
      (let ((content (uiop:read-file-string cu)))
        (dolist (exp expectations)
          (unless (search exp content)
            (format t "FAIL: Expected string not found in ~a:~%  '~a'~%"
                    (file-namestring cu) exp)
            (setf passed nil)))))
    (when passed
      (format t "PASS: All ~a strategy expectations met.~%" (length expectations)))
    passed))


