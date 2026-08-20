;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;; ---------------------------------------------------------------------------
;;;; Empty by design.  Endeavour 152's contents were migrated into src/ on 2026-08-19:
;;;;
;;;;   51 new definitions INSERTED after each target file's (in-package ...) form -- not at
;;;;      end of file, because a defvar appended below its users turns their LET bindings
;;;;      lexical and the dynamic value silently stops propagating.
;;;;   20 definitions REPLACED in place, the four generate-node-ir methods matched by
;;;;      SPECIALIZER rather than by name (codegen.lisp has 49 methods of that name).
;;;;    3 fdefinition WRAPPERS rewritten: each original was renamed <name>-base and the
;;;;      wrapper now calls it directly.  Those could not move as text -- the capture
;;;;      (fdefinition 'foo) only found the real original because this file loaded AFTER
;;;;      src; moved in beside it, the wrapper would have captured itself.
;;;;
;;;; INSTRUCTIONS (unchanged):
;;;; 1. Append new/fixed function definitions to the end of this file.
;;;; 2. Add a comment referencing the original file (e.g. ;; src/codegen.lisp)
;;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)
