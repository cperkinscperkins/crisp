;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)

;;; --- START PATCHES ---
;; src/compiler.lisp - PTX compilation support
(defun compile-to-ptx (module output-path &key (compute-capability "sm_50"))
  "Compiles an LLVM Module to PTX using llc.
   COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)
                       sm_50 = Maxwell (good default for compatibility)"
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ptx-file output-path))

    ;; Set target triple for NVPTX before writing IR
    (llvm-set-target module "nvptx64-nvidia-cuda")

    ;; 1. Write LLVM IR to .ll file
    (let ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module))))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir stream)))

    ;; 2. llc: IR -> PTX
    (let* ((tool-name (if (uiop:os-windows-p) "bin/llc.exe" "bin/llc"))
           (tool (merge-pathnames tool-name *default-pathname-defaults*)))

      (unless (probe-file tool)
        (error "llc tool not found in bin/"))

      (run-tool-command
       (list (namestring tool)
             "-march=nvptx64"
             (format nil "-mcpu=~a" compute-capability)
             (namestring ll-file)
             "-o" (namestring ptx-file))
       :log-prefix "[PTX] "))

    ;; Cleanup temp files
    (when (probe-file ll-file) (delete-file ll-file))

    (log:info "Generated PTX: ~a" ptx-file)))
