;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; EMPTY BY DESIGN.  Its contents were folded into src/hoist-cuda/main.lisp on 2026-08-26.
;;;;
;;;; The two residents were late-binding WRAPPERS -- they captured (fdefinition 'emit-launch)
;;;; and (fdefinition 'emit-kernel-args) into a defvar and then redefined those names.  That
;;;; shape cannot be pasted into src/, where there is only one definition: the capture would
;;;; grab the function being replaced and the wrapper would recurse forever.  So each was
;;;; split into a base plus a wrapper that calls the base by name:
;;;;
;;;;     %emit-launch-base       + emit-launch
;;;;     %emit-kernel-args-base  + emit-kernel-args
;;;;
;;;; Callers were untouched -- both public names keep their signature and return value.
;;;;
;;;; If you add a patch here, remember the same constraint applies on the way back out.

(in-package :crisp.hoist.cuda)
