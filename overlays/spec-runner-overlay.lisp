;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; DEBUG: temporary validator to diagnose what the test runner passes
(in-package :crisp.compiler)
(defun validate-debug-050 (paths)
  "Debug validator: prints what it receives and returns T."
  (format t "~%[DEBUG] validate-debug-050: paths=~s type=~s~%" paths (type-of paths))
  (when (pathnamep paths)
    (format t "[DEBUG] single path, exists=~a~%" (probe-file paths))
    (when (probe-file paths)
      (format t "[DEBUG] content:~%~a~%" (uiop:read-file-string paths))))
  (when (listp paths)
    (format t "[DEBUG] list of ~a paths~%" (length paths))
    (dolist (p paths)
      (format t "[DEBUG]  ~a exists=~a~%" p (probe-file p))
      (when (probe-file p)
        (format t "[DEBUG] content:~%~a~%" (uiop:read-file-string p)))))
  t)

;; tests/run-specs.lisp
;; Fix: pass *compile-differentiate* to initialize-compiler so *differentiate-p* is set
;; correctly when TEST-WITH[--differentiate] is active. Without this, backward kernels
;; are not generated and metadata reflects the forward kernel only.
;;
;; NOTE: The previous attempt defined this in :cl-user by mistake; the function called
;; by the test runner lives in :crisp.spec-runner, so the fix must go there.
(in-package :crisp.spec-runner)

;; Ensure SBCL knows these are special at compile time so dynamic bindings are followed.
(declaim (special *compile-differentiate* *log-level* *keep-work*))

(defun compile-crisp-file-to-spirv (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .spv and returns the output path and metadata paths if successful."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "spv" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type "metacrisp" :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V, passing differentiate flag so *differentiate-p* is set
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
                  ;; FIX: Set *package* to :crisp-language to match binary compiler behavior
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :spirv)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-spirv module out-path)

               (when emit-metadata
                     (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file filepath meta-base-path
                                                                   :output-targets (list (list :spv out-path))
                                                                   :forms forms))))
             (crisp.llvm-bindings:llvm-dispose-builder builder)
             (crisp.llvm-bindings:llvm-dispose-module module)))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        nil)))
