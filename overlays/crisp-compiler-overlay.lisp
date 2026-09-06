;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26, and
;;;; endeavour 163's 23 definitions were folded in on 2026-09-06 (15 replaced their src
;;;; originals in place, 8 new helpers were appended to their target files, and a
;;;; duplicate *ad-ring-slot-marker* identical to src/autodiff.lisp's was dropped).
;;;;
;;;; When you fold future contents back out, three things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.
;;;;   * A FORMAT string using ~<newline> continuation works in an LF overlay and DIES
;;;;     when folded into CRLF src/, and the error names the wrong place.  Both files are
;;;;     CRLF today, so this is only a hazard if an overlay is ever written as LF.

(in-package :crisp.compiler)
