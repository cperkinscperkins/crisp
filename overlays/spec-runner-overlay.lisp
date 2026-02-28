;; overlays/spec-runner-overlay.lisp
;; This file is loaded by tests/run-specs.lisp just before (main) is called.
;; Use this file to APPEND new definitions or redefine functions in the spec runner
;; without modifying the main script structure, to avoid syntax errors from
;; partial file refactoring.

(in-package :crisp.spec-runner)
;; Note: The spec runner functions are defined in :crisp.spec-runner package

