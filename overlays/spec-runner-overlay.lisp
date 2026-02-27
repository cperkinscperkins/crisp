;; overlays/spec-runner-overlay.lisp
;; This file is loaded by tests/run-specs.lisp just before (main) is called.
;; Use this file to APPEND new definitions or redefine functions in the spec runner
;; without modifying the main script structure, to avoid syntax errors from
;; partial file refactoring.

(in-package :crisp.spec-runner)
;; Note: The spec runner functions are defined in :crisp.spec-runner package

;; Fix: redefine compile-crisp-file-to-ir-string to use :crisp-language package
;; (matches compile-crisp-file-to-spirv behavior, fixes VALUE-T package symbol conflict
;;  that caused fake-cell brand tests to fail when run in-process)
;; tests/run-specs.lisp
(defun compile-crisp-file-to-ir-string (filepath)
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (let ((*standard-output* (make-broadcast-stream))) ; Discard stdout (redirect to null)
    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*) ;; Standard cleanup
                  (with-open-file (stream filepath)
                    ;; FIX: Use :crisp-language package to match binary compiler behavior.
                    ;; Previously used :crisp.compiler which caused user-defined names like
                    ;; VALUE-T to intern in CRISP.COMPILER:: namespace, conflicting with
                    ;; the real cell's brand registration and causing `:ancestor` semantics
                    ;; to be skipped by Fix B's skip-global check.
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
                           (crisp.compiler:compile-toplevel-form form (list toplevel-index) module builder nil nil nil)
                           (incf toplevel-index)))
                 (crisp.compiler:compile-module forms module builder nil nil nil))

             (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
               (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
                 (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))))
