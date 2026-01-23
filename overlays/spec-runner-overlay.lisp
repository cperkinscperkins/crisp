;; overlays/spec-runner-overlay.lisp
;; This file is loaded by tests/run-specs.lisp just before (main) is called.
;; Use this file to APPEND new definitions or redefine functions in the spec runner
;; without modifying the main script structure, to avoid syntax errors from
;; partial file refactoring.

(in-package :cl-user)
;; Note: most string runner code is in :cl-user or :crisp.spec-runner (if defined)
;; Check run-specs.lisp for the active package, but usually scripts start in cl-user.
