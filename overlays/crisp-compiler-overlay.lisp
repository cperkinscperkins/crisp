;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)

;;; --- START PATCHES ---
;
;; src/compiler.lisp - Updated to use llvm-as with correct triple
(defun compile-to-spirv (module output-path)
  "Compiles an LLVM Module to SPIR-V using the external toolchain."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    ;; Set target triple for SPIR-V before writing IR
    (llvm-set-target module "spir64-unknown-unknown")

    ;; 1. Write Temporary .ll file
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    ;; 2. llvm-as (LL -> BC)
    (let* ((tool-name (if (uiop:os-windows-p) "bin/llvm-as.exe" "bin/llvm-as"))
           (tool (merge-pathnames tool-name *default-pathname-defaults*)))

      (unless (probe-file tool)
        (error "llvm-as tool not found in bin/"))

      (run-tool-command
       (list (namestring tool) (namestring ll-file) "-o" (namestring bc-file))
       :log-prefix "[SPIR-V] "))

    ;; 3. llvm-spirv (BC -> SPV)
    (let* ((tool-name (if (uiop:os-windows-p) "bin/llvm-spirv.exe" "bin/llvm-spirv"))
           (tool (merge-pathnames tool-name *default-pathname-defaults*)))

      (unless (probe-file tool)
        (error "llvm-spirv tool not found in bin/"))

      (run-tool-command
       (list (namestring tool) (namestring bc-file) "-o" (namestring spv-file))
       :log-prefix "[SPIR-V] "))

    ;; Cleanup temps
    (when (probe-file ll-file) (delete-file ll-file))
    (when (probe-file bc-file) (delete-file bc-file))

    (log:info "Generated SPIR-V: ~a" spv-file)))
