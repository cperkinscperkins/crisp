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
;; Corrected functions for src/structs.lisp
;; Replace lines 11-90

(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
  For scalars, N is the size of the scalar.
  For vectors, it is 2N or 4N.
  For arrays/structs, it is rounded up to vec4 alignment (16)."
  ;; Resolve type aliases first
  (let ((resolved-type (if (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
                           (loop for name = type-spec then (gethash name *crisp-type-aliases*)
                                 while (and (symbolp name) (gethash name *crisp-type-aliases*))
                                 finally (return name))
                           type-spec)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ;; TODO: Handle vectors here (will need vector support first)
      ((or (eq resolved-type 'bool)) 4) ;; booleans are 4 bytes in std140
      ((eq type-spec 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs align to 16 bytes (vec4)
      ((gethash type-spec *crisp-structs*) 16)
      ;; Parameterized Structs (e.g. (POINT INT))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ;; Cells are pointers (8 bytes aligned to 8)
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  16
                  (error "Valid type ~a but struct def not found after check alignment." type-spec)))))))
      (t
       (error "Unknown type for alignment: ~a" type-spec)))))

(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type. Does not include padding for alignment context."
  ;; Resolve type aliases first
  (let ((resolved-type (if (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
                           (loop for name = type-spec then (gethash name *crisp-type-aliases*)
                                 while (and (symbolp name) (gethash name *crisp-type-aliases*))
                                 finally (return name))
                           type-spec)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs - Retrieve cached size
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ;; Parameterized Structs
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ;; Cells are pointers (8 bytes)
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  (crisp-struct-definition-total-size (gethash mangled *crisp-structs*))
                  (error "Valid type ~a but struct def not found after check size." type-spec)))))))
      (t (error "Unknown type for size: ~a" type-spec)))))

#|
;; src/macros.lisp - Define explicit-return placeholder for analyzer interception
(in-package :crisp.compiler)
(defmacro explicit-return (&optional value)
  "Placeholder macro for return - intercepted by semantic analyzer.
   This should never actually be expanded; the analyzer intercepts it."
  (declare (ignore value))
  (error "EXPLICIT-RETURN should have been intercepted by the semantic analyzer"))

  |#
