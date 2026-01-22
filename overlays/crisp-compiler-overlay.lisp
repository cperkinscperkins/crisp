;; overlays/crisp-compiler-overlay.lisp
;; Overlay for crisp.compiler package
;; This file is loaded with warning muffling (see crisp.asd)
;; All code has been promoted to src/ - this file is kept for the .asd hook

(in-package :crisp.compiler)
;; src/macros.lisp - Fix struct setter generation (remove buggy functional setter)
(defun %generate-struct-accessor (member-spec name pkg runtime-index)
  "Helper: Generates accessor (and setter) for a single struct member.
   Returns (values accessor-form new-runtime-index)."
  (let* ((member-name (first member-spec))
         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
         (value (when is-ct (fourth member-spec)))
         (accessor-name (intern (format nil "~a~~" member-name) pkg)))

    (cond
     ;; Compile-time member with value -> constant accessor macro
     ((and is-ct value)
       (values `(defmacro ,accessor-name (obj)
                  (declare (ignore obj))
                  '',value)
         runtime-index))

     ;; Compile-time member without value -> skip (incomplete type)
     (is-ct
       (values nil runtime-index))

     ;; Runtime member -> function accessor ONLY
     ;; We rely on set! analyzing the accessor form to generate update logic.
     ;; We DO NOT generate a def-setter because struct updates are functional
     ;; and must be wrapped in a set! for the holding variable.
     (t
       (let ((idx runtime-index))
         (values `(def-function ,accessor-name ((obj ,name))
                                (return (%extract-struct-member obj ,idx)))
           (1+ runtime-index)))))))
