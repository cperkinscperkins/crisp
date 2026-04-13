;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;;;; Fix: compile-crisp-file-to-llvmir must read source in :crisp-language package,
;;;; not :crisp.compiler, to avoid symbol conflicts (e.g. EXPLICIT-RETURN is a
;;;; crisp-language form but crisp.compiler has no CL function by that name).
;;;; Mirrors the same fix applied to compile-crisp-file-to-ir-string.

(defun compile-crisp-file-to-llvmir (filepath)
  "Compiles a .crisp file to .ll and returns the output path if successful.
   Reads source in :crisp-language package to match compile-crisp-file-to-spirv."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ll" :defaults filepath))
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let ((crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
                  (with-open-file (stream filepath)
                    ;; NOTE: use :crisp-language (not :crisp.compiler) so that
                    ;; Crisp forms like (return ...) are read as crisp-language::return,
                    ;; not as a CL function call.
                    (let ((*package* (find-package :crisp-language)))
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (crisp.compiler:compile-module forms module builder nil nil nil)
             ;; Write LLVM IR to file
             (let ((ir-string (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                                (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                                  (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))))
               (with-open-file (stream out-path :direction :output :if-exists :supersede)
                 (write-string ir-string stream))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path) out-path nil)))


