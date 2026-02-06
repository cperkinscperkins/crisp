;; overlays/spec-runner-overlay.lisp
;; This file is loaded by tests/run-specs.lisp just before (main) is called.
;; Use this file to APPEND new definitions or redefine functions in the spec runner
;; without modifying the main script structure, to avoid syntax errors from
;; partial file refactoring.

(in-package :crisp.spec-runner)
;; Note: The spec runner functions are defined in :crisp.spec-runner package

;; Overlay loaded - redefining binary mode functions with validator support

;; tests/run-specs.lisp - run-spec-llvmir-binary
;; Add validator support to binary mode LLVM IR compilation
(defun run-spec-llvmir-binary (file &key (validator nil))
  "Runs the binary compiler with --ir-target=llvmir. Optionally runs a validator."
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "ll" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=llvmir"
                    (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))

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
         ;; File generated - now run validator if provided
         (let ((res (if validator
                        (progn
                          (format t "(Validator: ~a)... " validator)
                          (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                            (if (and sym (fboundp sym))
                                (if (funcall sym out-path)
                                    (progn (format t "Validator PASS.~%") t)
                                    (progn (format *error-output* "Validator FAIL.~%") nil))
                                (progn (format *error-output* "Validator fn ~a not found.~%" validator) nil))))
                        (progn (format t "PASS (Generated .ll)~%") t))))
           (when (probe-file out-path)
             (unless *keep-work* (delete-file out-path)))
           res))
       (t
         (format *error-output* "FAIL (No LLVM IR generated)~%~a~%" error-output)
         nil)))))


;; tests/run-specs.lisp - run-spec-spirv-binary
;; Add emit-metadata and validator support to binary mode SPIRV compilation
(defun run-spec-spirv-binary (file &key (emit-metadata nil) (validator nil))
  "Runs the binary compiler with --ir-target=spv. Optionally emits metadata and runs a validator."
  (let ((bin (get-binary-path))
        (out-path (make-pathname :type "spv" :defaults file))
        (args (list (uiop:native-namestring file) "--ir-target=spv"
                    (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when emit-metadata (push "--metadata" args))

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
         ;; File generated - now run validator if provided
         (let ((res (if validator
                        (progn
                          (format t "(Validator: ~a)... " validator)
                          ;; For metadata validators, collect .metacrisp files matching this test
                          (let* ((all-meta-files (directory (make-pathname :directory (pathname-directory file)
                                                                           :name :wild
                                                                           :type "metacrisp")))
                                 ;; Filter to only files matching this test's name prefix
                                 (meta-files (remove-if-not
                                               (lambda (mf)
                                                 (uiop:string-prefix-p (pathname-name file)
                                                                       (pathname-name mf)))
                                               all-meta-files))
                                 ;; Match in-process behavior: single file -> pathname, multiple -> list
                                 (val-arg (if emit-metadata
                                              (cond
                                               ((null meta-files) out-path)
                                               ((= (length meta-files) 1) (first meta-files))
                                               (t meta-files))
                                              out-path))
                                 (sym (find-symbol (symbol-name validator) :crisp.compiler)))
                            (if (and sym (fboundp sym))
                                (if (funcall sym val-arg)
                                    (progn (format t "Validator PASS.~%") t)
                                    (progn (format *error-output* "Validator FAIL.~%") nil))
                                (progn (format *error-output* "Validator fn ~a not found.~%" validator) nil))))
                        (progn (format t "PASS (Generated .spv)~%") t))))
           ;; Cleanup
           (when (probe-file out-path)
             (unless *keep-work* (delete-file out-path)))
           (dolist (mf (directory (make-pathname :directory (pathname-directory file)
                                                 :name :wild
                                                 :type "metacrisp")))
             (when (uiop:string-prefix-p (pathname-name file) (pathname-name mf))
               (unless *keep-work* (delete-file mf))))
           res))
       (t
         (format *error-output* "FAIL (No SPV generated)~%~a~%" error-output)
         nil)))))


;; tests/run-specs.lisp - run-single-spec-pass
;; Pass validator to binary mode functions
(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active."
  (let ((*use-binary* (or *use-binary* (member "--use-binary" flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass" flags :test #'string=)))
        (*compile-debug* (or *compile-debug* (member "--debug" flags :test #'string=)))
        (emit-metadata (member "--metadata" flags :test #'string=))

        ;; Determine IR Target from flags (default to nil/generic)
        (ir-target (cond
                    ((member "--ir-target=spv" flags :test #'string=) :spirv)
                    ((member "--ir-target=ptx" flags :test #'string=) :ptx)
                    ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                    ((member "--metadata" flags :test #'string=) :spirv) ;; Metadata usually implies SPIR-V for now
                    (t nil))))

    ;; Skip SPIRV tests if SKIP_SPIRV_TESTS env var is set
    (when (and (eq ir-target :spirv) (uiop:getenv "SKIP_SPIRV_TESTS"))
          (format t "SKIP (SPIRV tests disabled via SKIP_SPIRV_TESTS)~%")
          (return-from run-single-spec-pass t)) ;; Return success to not fail the build

    ;; Dispatch based on configuration
    (if *use-binary*
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
         ((eq ir-target :ptx) (run-spec-ptx-binary file))
         ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
         (t (run-spec-binary file)))

        ;; In-Process Runner
        (cond
         ((eq ir-target :spirv) (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
         ((eq ir-target :ptx) (run-spec-ptx-in-process file))
         ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
         (t (run-spec-lisp-loader file))))))
