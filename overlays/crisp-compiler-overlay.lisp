;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;; ---------------------------------------------------------------------------
;;;; Empty by design.  Endeavour 152's contents were migrated into src/ on 2026-08-19;
;;;; endeavour 154's on 2026-08-22.
;;;;
;;;; 154 migrated SIX definitions into src/mma.lisp, all of them plain defuns (no defvars, no
;;;; macros, no structs), so unlike 152 this fold needed no insert-after-in-package care:
;;;;
;;;;   %emit-wgmma-mma-only        NEW    — beside %emit-nvvm-wgmma
;;;;   %emit-nvvm-wgmma            REPLACED — one fence / N mma_async / one commit / one wait
;;;;   %wgmma-store-rewrite-origin NEW    — absolute (ROW COL) origin + row-major emission
;;;;   %wgmma-store-rewrite        REPLACED — now a thin caller of -origin (behaviour unchanged)
;;;;   analyze-store-tile-at-mma   NEW    — placed BEFORE register-mma-analyzers, which #'-refs it
;;;;   register-mma-analyzers      REPLACED — STORE-TILE-AT added to the dispatch table
;;;;
;;;; Verified behaviour-preserving by md5 of the emitted PTX for four kernels plus spec 03,
;;;; before and after the fold — see tests/spec/154-nvidia-perf/nvidia-perf.md, Phase 11.
;;;;
;;;; The two spec validators that came with 154 live in overlays/spec-runner-overlay.lisp and
;;;; were NOT folded: run-specs.lisp calls (main) on its last line, so anything appended after
;;;; it is defined too late to be found.  They belong in that overlay or ahead of the (main)
;;;; call, not at end of file.
;;;;
;;;; INSTRUCTIONS (unchanged):
;;;; 1. Append new/fixed function definitions to the end of this file.
;;;; 2. Add a comment referencing the original file (e.g. ;; src/codegen.lisp)
;;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)
