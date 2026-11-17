;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the Apache License v2.0 with LLVM Exceptions. See LICENSE file in the project root.
;;;; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

;; src/types/definitions.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Definitions
;;; =========================================================

(defstruct enumeration-def
  name
  members ; Alist of (keyword . integer)
)
