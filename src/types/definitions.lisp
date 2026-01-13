;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/types/definitions.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Definitions
;;; =========================================================

(defstruct enumeration-def
  name
  members ; Alist of (keyword . integer)
)
