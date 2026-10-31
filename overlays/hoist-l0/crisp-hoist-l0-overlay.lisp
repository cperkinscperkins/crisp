;;;; EMPTY as of 2026-10-25 -- endeavour 193 folded: the shared report helpers into src/hoist/common.lisp
;;;; (exported from crisp.hoist); %193-l0-emit-die-report / -log-report, and the site tables bound in
;;;; generate-l0-launcher and reported at the end of generate-kernel-launch (src/hoist-l0/main.lisp).
;;;; EMPTY as of 2026-10-30 -- endeavour 201 (:match-global-size scratch) folded into src/hoist-l0/main.lisp:
;;;; %l0-global-size-size-p (new), %l0-num-workgroups-size-p (accepts it), %l0-deferred-global-scratch-block
;;;; (a SIZE-EXPR parameter; group count x wg_size), its caller passes it; the wrapper and
;;;; *201-scratch-size-expr* dropped.  %l0-scratch-symbolic-expr refuses it for LOCAL scratch.
(in-package :crisp.hoist.l0)
