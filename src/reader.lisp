;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/reader.lisp
(in-package :crisp.compiler)


;; Both the defun and the registration must be inside eval-when so the
;; function exists at compile time when ASDF compiles this overlay to fasl.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %read-device-vec-literal (stream char n)
    "Reader macro for ##(...). Transforms ##(e1 e2 ...) into
     (crisp-vec-literal e1 e2 ...) for the Crisp analyzer."
    (declare (ignore char n))
    (let ((elements (read stream t nil t)))
      (unless (listp elements)
        (error "##(...) device vector literal requires a list of elements, e.g. ##(1 2 3)"))
      (cons 'crisp-vec-literal elements)))
  (set-dispatch-macro-character #\# #\# #'%read-device-vec-literal))