;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;;;; ---------------------------------------------------------------------------------------
;;;; ENDEAVOUR 181 -- VERIFY-AUTODIFF sizes :match-num-workgroups scratch (last-man's implicit partials)
;;;; from the LAUNCH's group count, the directive's groups= (default 1).
;;;;
;;;; FOLD NOTE: the wrapper captures the src definition.  Folding: run-verify-autodiff-pass binds
;;;; *vad-group-count* itself, around its body.
;;;; ---------------------------------------------------------------------------------------

;; tests/run-specs.lisp
(defvar *vad-group-count* nil
  "Endeavour 181.  The number of workgroups the current VERIFY-AUTODIFF launch dispatches (groups=,
   default 1), bound by run-verify-autodiff-pass so %vad-resolve-symbolic-size can size
   :match-num-workgroups scratch.  NIL outside a VERIFY-AUTODIFF pass.")

;; tests/run-specs.lisp
(defun %vad-resolve-symbolic-size (size kern forms)
  "Endeavour 176.  SIZE (an implicit param's :size-expr) as an element COUNT.  An integer is returned as
   is.  A symbolic size -- implicit reduction scratch is :match-num-warps-per-workgroup (local sweep) or
   :match-num-workgroups (last-man's global partials, since 181) -- is resolved by the same rules as the
   hoisters (%l0-scratch-symbolic-expr): ceiling division for warps, warp width 32 when no profile is
   recorded, both from KERN's declared local size and the SIMD width found in FORMS; the group count is
   the LAUNCH's (*vad-group-count*), which is what the kernel's get-num-groups will report."
  (if (not (keywordp size))
      size
      (let* ((name (symbol-name size))
             (ls (getf kern :local-size))            ; (local-size :set-to N) or (local-size :set-to (A B))
             (n (and (consp ls) (third ls)))
             (n (cond ((integerp n) n)
                      ((and (consp n) (eq (car n) 'quote)) (reduce #'* (second n)))
                      ((and (consp n) (every #'integerp n)) (reduce #'* n))
                      (t nil)))
             (warp (or (%vad-find-simd-width forms) 32)))
        (cond ((string-equal name "MATCH-NUM-WORKGROUPS")
               (or *vad-group-count*
                   (error "%vad-resolve-symbolic-size: :match-num-workgroups needs the launch's group count, and no VERIFY-AUTODIFF pass is active")))
              ((null n)
               (error "%vad-resolve-symbolic-size: symbolic :size-expr ~s needs a compile-time (local-size :set-to N); kernel declares ~s"
                      size ls))
              ((string-equal name "MATCH-WORKGROUP-SIZE") n)
              ((string-equal name "MATCH-NUM-WARPS-PER-WORKGROUP") (ceiling n warp))
              (t (error "%vad-resolve-symbolic-size: unsupported symbolic :size-expr ~s" size))))))

;; tests/run-specs.lisp  (FOLD: run-verify-autodiff-pass binds *vad-group-count* itself)
(defvar *181-run-verify-autodiff-pass-base* (fdefinition 'run-verify-autodiff-pass))

;; tests/run-specs.lisp
(defun run-verify-autodiff-pass (file spec)
  "Endeavour 181 wrapper: binds *vad-group-count* to the directive's groups= (default 1) -- the group count
   every launch in this pass uses -- around the original pass."
  (let ((*vad-group-count* (or (getf spec :group-count) 1)))
    (funcall *181-run-verify-autodiff-pass-base* file spec)))

;;;; ENDEAVOUR 182 -- launch-bound validators: names in the runner's package, implementations in
;;;; :crisp.compiler (as for validate-ptx-has-nounroll-pragma).

;; tests/run-specs.lisp
(defun validate-ptx-minnctapersm-4 (file ptx-text)
  (funcall (find-symbol "VALIDATE-PTX-MINNCTAPERSM-4" :crisp.compiler) file ptx-text))

;; tests/run-specs.lisp
(defun validate-ptx-minnctapersm-2 (file ptx-text)
  (funcall (find-symbol "VALIDATE-PTX-MINNCTAPERSM-2" :crisp.compiler) file ptx-text))

;; tests/run-specs.lisp
(defun validate-ptx-no-minnctapersm (file ptx-text)
  (funcall (find-symbol "VALIDATE-PTX-NO-MINNCTAPERSM" :crisp.compiler) file ptx-text))
