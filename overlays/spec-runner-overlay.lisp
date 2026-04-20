;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; Support for TEST-WITH[--runtime-checks] : validate-has-llvm-trap
;;
;; The base run-specs.lisp compile-crisp-file-to-ir-string never passes
;; :runtime-checks to initialize-compiler, and run-single-spec-pass routes
;; --runtime-checks to run-spec-lisp-loader (which ignores the validator).
;;
;; We fix both here:
;;   1. *compile-runtime-checks* — dynamic var toggled by the new dispatch path.
;;   2. Redef of compile-crisp-file-to-ir-string to pass :runtime-checks.
;;   3. run-spec-runtime-checks-pass — dedicated helper that compiles with RT
;;      checks on and calls validate-has-llvm-trap(file ir-string).
;;   4. Redef of run-single-spec-pass to detect --runtime-checks and route
;;      to the new helper before the existing dispatch.

(defvar *compile-runtime-checks* nil
  "When T, pass :runtime-checks t to initialize-compiler in the in-process runner.")

;; src/tests/run-specs.lisp
;; Redefine to thread *compile-runtime-checks* through initialize-compiler.
(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string.
   Extended to support *compile-runtime-checks*."
  (let ((*standard-output* (make-broadcast-stream)))
    (let ((crisp.compiler::*struct-name-prefix*
           (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                   (crisp.compiler:initialize-compiler
                    :log-level cl-user::*log-level*
                    :differentiate *compile-differentiate*
                    :runtime-checks *compile-runtime-checks*)
                   (with-open-file (stream filepath)
                     (let ((*package* (find-package :crisp-language)))
                       (loop for form = (read stream nil :eof)
                             until (eq form :eof)
                             collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
              (if *compile-single-pass*
                  (let ((toplevel-index 0)
                        (crisp.compiler:*current-module* nil))
                    (loop for form in forms do
                      (crisp.compiler:compile-toplevel-form
                       form (list toplevel-index) module builder nil nil nil)
                      (incf toplevel-index)))
                  (crisp.compiler:compile-module forms module builder nil nil nil))
              (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                  (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))))

(defun run-spec-runtime-checks-pass (file validator)
  "Compiles FILE with *runtime-checks-enabled* = T, then calls VALIDATOR(file ir-string).
   Called when TEST-WITH[--runtime-checks] is present in the spec directives."
  (handler-case
      (let ((*compile-runtime-checks* t))
        (let ((ir-string (compile-crisp-file-to-ir-string file)))
          (if validator
              (let* ((validator-str (if (symbolp validator)
                                        (symbol-name validator)
                                        (string validator)))
                     (sym (find-symbol (string-upcase validator-str) :crisp.spec-runner)))
                (if (and sym (fboundp sym))
                    (if (funcall sym file ir-string)
                        (progn (format t "PASS~%") t)
                        (progn (format *error-output* "FAIL (Validator ~a)~%" validator) nil))
                    (progn (format *error-output* "FAIL (Validator ~a not found)~%" validator) nil)))
              (progn (format t "PASS~%") t))))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

;; src/tests/run-specs.lisp
;; Redefine run-single-spec-pass to detect --runtime-checks and route it to
;; run-spec-runtime-checks-pass before the existing ir-target dispatch.
(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active.
   Extended: --runtime-checks routes to run-spec-runtime-checks-pass."
  ;; NEW: --runtime-checks is handled as a dedicated path — compile with
  ;; runtime assertions enabled and call the validator with the IR string.
  (when (member "--runtime-checks" flags :test #'string=)
    (format t "(RT-Checks)... ")
    (return-from run-single-spec-pass
      (run-spec-runtime-checks-pass file validator)))

  ;; Original dispatch (unchanged from base run-specs.lisp):
  (let ((*use-binary*         (or *use-binary*         (member "--use-binary"    flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass"  flags :test #'string=)))
        (*compile-debug*       (or *compile-debug*       (member "--debug"        flags :test #'string=)))
        (*compile-differentiate* (or *compile-differentiate* (member "--differentiate" flags :test #'string=)))
        (emit-metadata (member "--metadata" flags :test #'string=))
        (ir-target (cond
                     ((member "--ir-target=spv"    flags :test #'string=) :spirv)
                     ((member "--ir-target=ptx"    flags :test #'string=) :ptx)
                     ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                     ((member "--metadata"         flags :test #'string=) :spirv)
                     (t nil))))

    (when (and (eq ir-target :spirv) (uiop:getenv "SKIP_SPIRV_TESTS"))
      (format t "SKIP (SPIRV tests disabled via SKIP_SPIRV_TESTS)~%")
      (return-from run-single-spec-pass t))

    (if *use-binary*
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-binary file))
          ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
          (t (run-spec-binary file)))
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-in-process file))
          ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
          (t (run-spec-lisp-loader file))))))
