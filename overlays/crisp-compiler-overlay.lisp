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
;;;; Emptied 2026-09-19: everything folded into src/ (endeavour 172 -- the dotimes family,
;;;; semantic-loop-variant + BUG 065's dotimes stride gate -- into src/semantic.lisp,
;;;; src/anf-transform.lisp, src/analysis/control.lisp, src/autodiff.lisp and
;;;; src/codegen.lisp).  Previously emptied 2026-09-18 (endeavour 167).

(in-package :crisp.compiler)


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — reject `let*`.
;;; ---------------------------------------------------------------------------
;;; src/analysis/control.lisp  (register-control-analyzers, near the let entries)
;;;
;;; Crisp's LET is ALREADY SEQUENTIAL and destructures multiple values, so `let*` adds
;;; nothing.  :crisp-language deliberately does not import let/let* from CL, so `let*` in
;;; Crisp source is MINTED as a fresh symbol -- yet register-control-analyzers aliased it
;;; onto analyze-let-expression, so it compiled forward and emitted byte-identical SPIR-V.
;;;
;;; Only the expression analyzer knew.  The uniformity pre-pass matches the operator name
;;; "LET" exactly (%uni-analyze-let's caller, src/analysis/core.lisp), and the AD walk runs
;;; before semantic analysis and knows only `let`.  So `let*` worked until someone added
;;; --differentiate, then failed with "Function SET! is not differentiable" -- blaming an
;;; operator that differentiates fine.  Found in 173: all four A|D specs failed that way
;;; with no shuffle involved.  Forward-legal / backward-fatal / blames a bystander is worse
;;; than refused, so: refused.
;;;
;;; Done by name rather than by symbol because the registration and the reader disagree about
;;; which package LET* lands in; re-pointing every key whose symbol-name is "LET*" covers the
;;; crisp.compiler, common-lisp and crisp-language spellings without guessing.

(defun %analyze-let-star-rejected (expr env context location)
  "Signals a clear error for `let*`, which is not a Crisp form.  Crisp's LET is already
   sequential (later bindings see earlier ones) and destructures multiple values, so LET*
   is redundant; it was previously aliased onto LET in the expression analyzer only, which
   made it compile forward and fail under --differentiate naming an unrelated operator."
  (declare (ignore expr env context))
  (error 'crisp-compiler-error
         :message "Crisp has no LET*. Use LET — Crisp's LET is already sequential, so later bindings may refer to earlier ones"
         :source-location location))

;;; TWO registration sites alias LET*, and the SECOND one wins:
;;;   src/analysis/control.lisp  register-control-analyzers  -> analyze-let-expression
;;;   src/mma.lisp               register-mma-analyzers      -> analyze-let-with-tile-explosion
;;; The mma one interns "LET*" into :crisp-language, and THAT intern is what mints the very
;;; symbol the Crisp reader later reuses for user source.  Hooking only the control site is
;;; dead code -- mma overwrites it, by function OBJECT, moments later.  So both are hooked.
;;;
;;; ONLY the :crisp-language spelling is rejected.  `common-lisp::LET*` stays registered: no
;;; lowering generates a crisp-language LET* form (the tile/stride lowerings all intern "LET"),
;;; but leaving the CL spelling alone costs nothing and keeps this surgical.

(defun %173-reject-let-star ()
  "Re-points the :crisp-language LET* analyzer at %ANALYZE-LET-STAR-REJECTED.  Called from
   both registration wrappers below, since either may run last."
  (let* ((p (find-package :crisp-language))
         (sym (and p (intern "LET*" p))))
    (when sym
      (setf (gethash sym *expression-analyzers*) '%analyze-let-star-rejected)
      (log:debug "173: LET* rejected (~a in ~a)" sym (package-name (symbol-package sym))))))

(defvar *orig-register-control-analyzers*
  (fdefinition 'register-control-analyzers)
  "The src/ definition, captured once at overlay load so the wrapper cannot recurse into
   itself if this file is reloaded (a defvar does not re-evaluate).")

(defun register-control-analyzers ()
  "Overlay wrapper: original registration, then reject LET*.  Must hook a register-* fn
   rather than setf at top level -- initialize-compiler clrhashes *expression-analyzers*."
  (funcall *orig-register-control-analyzers*)
  (%173-reject-let-star))

(defvar *orig-register-mma-analyzers*
  (fdefinition 'register-mma-analyzers)
  "As above, for the site that actually wins the LET* key.")

(defun register-mma-analyzers ()
  "Overlay wrapper: original registration, then reject LET* again -- this site re-registers
   it by function object after register-control-analyzers has run."
  (funcall *orig-register-mma-analyzers*)
  (%173-reject-let-star))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — (warp-size), decision D2.
;;; ---------------------------------------------------------------------------
;;; src/analysis/core.lisp  (register-warp-builtins, beside warp-id/warp-lane/warp-count)
;;;
;;; warp-size is NOT a runtime builtin like its three siblings.  It folds to an integer
;;; LITERAL at analysis time, resolved from the active hardware profile's :simd-width (32
;;; with no profile).  That is the whole point of D2: a literal is legal where a runtime
;;; value is not -- as a loop limit, as the default `width` of a shuffle, and as the operand
;;; of a 172 `+` form, which requires every operand to be provably uniform.  A runtime
;;; SubgroupSize builtin could be none of those.
;;;
;;; Folding also means the uniformity pre-pass and the AD walk never see a WARP-SIZE operator
;;; at all -- by the time either runs it is an ordinary constant.  So, unlike the stale
;;; "GET-WARP-SIZE" entry sitting in %uni-builtin-state, no uniformity registration is needed.
;;;
;;; NOTE it is NOT (warp-count).  warp-count is warps per workgroup; warp-size is lanes per
;;; warp.  They will be confused; the error text below says so.

(defun %173-warp-size ()
  "Lanes per warp for the current compilation: the active hardware profile's :simd-width,
   else 32.  Single source of truth -- the shuffle width rules and the SPIR-V subgroup-size
   gate must agree with this, or a kernel could be checked against one width and run at
   another."
  (let ((profile (active-hardware-profile)))
    (or (and profile (getf profile :simd-width)) 32)))

(defun %analyze-warp-size (expr env context location)
  "Analyzer for (warp-size) -- folds to a uint literal.  See %173-WARP-SIZE."
  (declare (ignore env context))
  (when (cdr expr)
    (error 'crisp-compiler-error
           :message (format nil "(warp-size) takes no arguments, got ~a. It is lanes-per-warp, a compile-time constant from the hardware profile's :simd-width — you may be looking for (warp-count), which is warps-per-workgroup"
                            (length (cdr expr)))
           :source-location location))
  (let ((n (%173-warp-size)))
    (log:debug "173: (warp-size) folded to ~a" n)
    (make-semantic-literal :value-type 'uint :value n :source-location location)))

(defvar *orig-register-warp-builtins*
  (fdefinition 'register-warp-builtins)
  "Captured once at overlay load so the wrapper cannot recurse into itself on reload.")

(defun register-warp-builtins ()
  "Overlay wrapper: the original warp-id/warp-lane/warp-count registration, plus WARP-SIZE.
   Registered into BOTH :crisp-language and :crisp.compiler, as the original does -- user
   source reads in :crisp-language, and an unregistered spelling there is silently minted as
   a fresh symbol rather than reported (the trap that hid the LET* aliasing above)."
  (funcall *orig-register-warp-builtins*)
  (let* ((cl-pkg (find-package :crisp-language))
         (cc-pkg (find-package :crisp.compiler))
         (sym-cl (intern "WARP-SIZE" cl-pkg))
         (sym-cc (intern "WARP-SIZE" cc-pkg)))
    (setf (gethash sym-cl *expression-analyzers*) '%analyze-warp-size)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) '%analyze-warp-size))))
