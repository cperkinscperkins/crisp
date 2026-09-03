;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; tests/run-specs.lisp  (REPLACES run-spec-ptx-binary -- forwards --hardware-profile)
(defun run-spec-ptx-binary (file &key (validator nil) (flags nil))
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "ptx" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=ptx" (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))
    ;; Endeavor 137: forward --ir-target-arch=<ID> from the TEST-WITH flags to the binary — a
    ;; separate crisp-compile.exe process can't see the in-process *ir-target-arch* dynamic
    ;; binding, so a :block (sm_90+) test gates on the default sm_80 without this.
    (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
      (when af (push af args)))
    ;; Endeavour 159/162: forward --hardware-profile too.  run-spec-spirv-binary has done this
    ;; since endeavour 155, with a comment saying the BINARY path would otherwise "drop it, so
    ;; --use-binary and the in-process runner would disagree about which profile is active" --
    ;; and that is exactly what happened here, because 155 was SPV work and fixed only the SPV
    ;; path.  159's specs are the first PTX ones to need a profile: without this, %check-mma-shape
    ;; takes its NO-PROFILE branch and refuses the 16-bit shape with "only tf32 (16 8 8) is
    ;; supported without a hardware profile, got (16 8 16)", so --use-binary failed two specs that
    ;; pass in-process.  Note the pattern: this function already had --ir-target-arch bolted on by
    ;; 137 and --metadata by 152.  Flags reach it one forgotten flag at a time.
    (when *compile-hardware-profile*
      (push (format nil "--hardware-profile=~a" *compile-hardware-profile*) args))

    ;; Endeavor 152: forward --metadata too.  A spec that wants to assert on the
    ;; .metacrisp *and* pin an arch carries both flags; dropping this one meant the
    ;; metacrisp was never written and the validator failed on a missing file.
    (when (find-if (lambda (f) (and (stringp f) (string= f "--metadata"))) flags)
      (push "--metadata" args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         (let ((res (if validator
                        (let* ((ptx-content (uiop:read-file-string out-path))
                               (sym (if (symbolp validator) validator
                                        (find-symbol (string-upcase (string validator)) :crisp.spec-runner))))
                          (if (and sym (fboundp sym))
                              (funcall sym file ptx-content)
                              (progn
                                (format *error-output* "FAIL: Validator ~a not found~%" validator)
                                nil)))
                        t)))
           (when res
             (format t "PASS (Generated .ptx)~%"))
           (unless *keep-work* (delete-file out-path))
           res))
       (t
         (format *error-output* "FAIL (No PTX generated)~%~a~%" error-output)
         nil)))))
