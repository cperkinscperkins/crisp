;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)

;;; --- START PATCHES ---
;; src/compiler.lisp - PTX compilation support
;; (No changes needed for semantic-return as it was patched in src/compiler.lisp by user)

;; src/compiler.lisp - Robust tool resolution
(defun resolve-tool-executable (tool-base)
  "Resolves the path to a tool executable. 
   Prefers bundled version in bin/, falls back to system PATH.
   Robustness: 
   - Checks versioned suffixes (e.g. llc-21) if base name not in path.
   - Falls back to bundled tool if system tool is missing even if CRISP_USE_SYSTEM_TOOLS is set."
  (let* ((env-key (format nil "CRISP_~a" (string-upcase (substitute #\_ #\- tool-base))))
         (env-override (uiop:getenv env-key))
         (use-system (uiop:getenv "CRISP_USE_SYSTEM_TOOLS"))
         (ext (if (uiop:os-windows-p) ".exe" ""))
         (bundled-name (format nil "bin/~a~a" tool-base ext))
         (bundled-path (merge-pathnames bundled-name *default-pathname-defaults*)))
    (cond
     (env-override env-override)
     ((and use-system (string-not-equal use-system "false"))
       (let ((versioned (unless (uiop:os-windows-p)
                          (loop for ver in '("21" "20" "19" "18" "17" "16" "15" "14")
                                for v-name = (format nil "~a-~a" tool-base ver)
                                  ;; Manual PATH check or similar? Let's use which but ONLY on Unix.
                                  when (zerop (nth-value 2 (uiop:run-program (list "which" v-name) :ignore-error-status t)))
                                  return v-name))))
         (or versioned
             (if (probe-file bundled-path)
                 (namestring bundled-path)
                 tool-base))))
     (t
       (if (probe-file bundled-path)
           (namestring bundled-path)
           tool-base)))))
