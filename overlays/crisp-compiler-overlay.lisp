;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; Fix: compile-toplevel-form — single-pass HOF pre-registration.
;;; In single-pass mode, analyze-signatures-pass (and thus %pre-register-hof-templates)
;;; is never called. When (with-template-type (T) ...) is eval'd it populates
;;; *template-registry*, but *differentiable-functions* remains empty. The kernel
;;; backward walk then fails with B3 on HOF function names (e.g. HOF-OPERATION).
;;;
;;; Fix: after each visit-toplevel-form call, when *differentiate-p* is T, run
;;; %pre-register-hof-templates to pick up any newly registered HOF templates.
;;; This is idempotent (guarded by (not (gethash name *differentiable-functions*))).
;;; src/analysis/core.lisp
(defun compile-toplevel-form (form location module builder di-builder di-compile-unit location-map)
  "Analyzes and compiles a single top-level form (used in Pass 2 and single-pass mode).
When *differentiate-p* is T, also calls %pre-register-hof-templates after each form
so that with-template-type HOF definitions are available before kernel backward walks
in single-pass mode."
  (log:debug "Compiling top-level form at ~a: ~s" location form)

  (let ((*compiler-session* (make-compiler-session :module module
                                                   :builder builder
                                                   :di-builder di-builder
                                                   :di-compile-unit di-compile-unit
                                                   :location-map location-map))
        (*compiler-context* (make-compiler-context)))
    (prog1
      (visit-toplevel-form form location
                           (lambda (form location)
                             (compile-def-function form location module builder di-builder di-compile-unit location-map)))
      ;; After processing any form, re-scan the template registry for HOF templates.
      ;; This ensures that HOFs registered by with-template-type are available to
      ;; kernel backward walks in single-pass mode before the next form is processed.
      (when *differentiate-p*
        (%pre-register-hof-templates)))))


