;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; NOTE THE SHAPE CONSTRAINT, learned when this file was last emptied (2026-08-26): a
;;;; late-binding wrapper that captures (fdefinition 'f) into a defvar and then redefines f
;;;; CANNOT be pasted into src/ as-is, because there the capture would grab the function being
;;;; replaced and recurse forever.  Folding one back means splitting it into a base plus a
;;;; wrapper that calls the base BY NAME, as emit-launch / %emit-launch-base already are.
;;;;
;;;; EMPTY AGAIN as of 2026-09-22.  Endeavour 175 (symbolic scratch sizes, CUDA side) folded
;;;; into src/hoist-cuda/main.lisp:
;;;;   emit-main               -- split per the constraint above into %emit-main-base plus a
;;;;                             wrapper that binds *cuda-wg-size* and calls the base by name
;;;;   %cuda-scratch-dims     -- symbolic branch is now its first cond clause
;;;;   %cuda-local-param-bytes-- symbolic clause added to its inner count cond, so the sizer
;;;;                             and the emitters still resolve the size the same way

(in-package :crisp.hoist.cuda)
