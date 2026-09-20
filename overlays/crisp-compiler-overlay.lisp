;;;; crisp-compiler-overlay.lisp — late-bound fixes for the CRISP.COMPILER package.
;;;;
;;;; APPEND full replacement definitions here while developing; they are loaded after src/ and
;;;; win by late binding.  Do NOT patch in place -- append, and note above each one which src
;;;; file it belongs to, so it can be folded back later.
;;;;
;;;; TWO THINGS THAT BITE (both learned the hard way, endeavour 165):
;;;;
;;;;   * A HANDLER REGISTERED BY OBJECT IS NOT LATE-BOUND.  src/autodiff.lisp does
;;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile), which captures
;;;;     the function OBJECT at load time.  Redefining that defun here is DEAD CODE until you
;;;;     also re-register.  The failure is partial and therefore nasty: a callee overridden by
;;;;     name goes live while its caller stays stale.
;;;;
;;;;   * NEVER PUT A DOUBLE QUOTE INSIDE A DOCSTRING.  It closes the string early and the rest of
;;;;     the prose becomes BODY FORMS -- the first bare word is then an unbound variable, and the
;;;;     build emits no warning.  It fails only when the function is CALLED.  Cost: a red CI.
;;;;
;;;; Emptied 2026-09-20: everything folded into src/ (endeavour 173 -- the four warp shuffles,
;;;; (warp-size), the let* rejection and BUG 066's _GRAD dispatch-declaration fix -- into
;;;; src/semantic.lisp, src/package.lisp, src/analysis/core.lisp, src/analysis/ops.lisp,
;;;; src/analysis/control.lisp, src/autodiff.lisp, src/codegen.lisp and src/mma.lisp).
;;;; Previously emptied 2026-09-19 (endeavour 172) and 2026-09-18 (endeavour 167).

(in-package :crisp.compiler)
