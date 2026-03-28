;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

(defun compile-crisp-files-to-ir-string (filepaths)
  "Compiles multiple .crisp files as a single unit (in order) and returns the LLVM IR as a string.
Forms from each file are concatenated in order before compilation, matching the behaviour of the
multi-file CLI: crisp-compile.exe file1.crisp file2.crisp ...

The LAST filepath is used as the primary (module name).
Respects the same *compile-single-pass* / *compile-differentiate* dynamic vars as
compile-crisp-file-to-ir-string."
  (let ((*standard-output* (make-broadcast-stream))) ; Discard stdout
    (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                        :differentiate *compile-differentiate*)
    (let* ((primary-file (car (last filepaths)))
           (forms (let ((*package* (find-package :crisp-language)))
                    (loop for filepath in filepaths
                          appending (with-open-file (stream filepath)
                                      (loop for form = (read stream nil :eof)
                                            until (eq form :eof)
                                            collect form)))))
           (module (crisp.llvm-bindings:llvm-module-create (pathname-name primary-file)))
           (builder (crisp.llvm-bindings:llvm-create-builder)))
      (unwind-protect
          (progn
           (if *compile-single-pass*
               (let ((toplevel-index 0))
                 (loop for form in forms do
                   (crisp.compiler:compile-toplevel-form form (list toplevel-index) module builder nil nil nil)
                   (incf toplevel-index)))
               (crisp.compiler:compile-module forms module builder nil nil nil))
           (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
             (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
               (crisp.llvm-bindings:llvm-dispose-message ir-ptr))))
        (crisp.llvm-bindings:llvm-dispose-builder builder)
        (crisp.llvm-bindings:llvm-dispose-module module)))))

