;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-01 -- endeavour 176 Phases 1-3 folded into src/ (grid-reduce!, the independent and
;;;; dependent multi-variable reductions, BUG 096/097, the :fast type-infinity warning).  The spec-runner
;;;; overlay (VERIFY-AUTODIFF symbolic scratch sizes) was folded into tests/run-specs.lisp in the same pass.
;;;;
;;;; Two things did NOT move, deliberately:
;;;;   * the MACRO-FUNCTION copy that put grid-reduce! on a separate :crisp-language symbol -- src/package.lisp
;;;;     now exports GRID-REDUCE! from :crisp.compiler and imports it into :crisp-language, so there is one
;;;;     symbol and one defmacro (as for WHEN-THREAD-IN-*).
;;;;   * %REFUSE-DEPENDENT-FORM -- Phase 2's placeholder refusal of the dependent shape; Phase 3 replaced
;;;;     every caller.

(in-package :crisp.compiler)

;; src/autodiff.lisp  (BUG 099: one new clause at the head of the cond)
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
   ;; BUG 099: a COPY binding, v := s.  The reverse walk has already processed every use of v, so
   ;; v's adjoint is final here and flows to s unchanged.  Without this clause the binding fell
   ;; through to (t nil) and v's adjoint was dropped -- (let ((v0 v)) (* v v0)) differentiated to x,
   ;; not 2x.  (%backward-value-expr has the same rule for let/if VALUE expressions; the top-level
   ;; walk never went there.)
   ;;
   ;; Scoped to SCALAR dataflow: a tensor input, a scratch tile, or a view alias keeps its adjoint
   ;; in a TENSOR named <sym>_ADJ, and minting a scalar of the same name here would shadow it (the
   ;; collision described at the accessor clause below).  And only when v already HAS an adjoint --
   ;; a copy nothing downstream reads contributes nothing, and must not mint a binding for s.
   ((and expr (symbolp expr) (not (keywordp expr)))
     (when (and (not (eq expr v))
                (gethash v adjoint-map)
                (not (and tensor-inputs-ht (gethash expr tensor-inputs-ht)))
                (not (member expr scratch-tile-syms))
                (not (%ad-resolve-view-alias expr))
                (not (%ad-resolve-view-alias v)))
       (log:debug "099: copy binding ~a := ~a -- adjoint flows to ~a" v expr expr)
       (funcall emit-fn `(set! ,(funcall local-adj-fn expr)
                               (+ ,(funcall local-adj-fn expr) ,(funcall local-adj-fn v))))))
   ;; Endeavour 170: the hardware math ops carry their own backward rules.  First, because the
   ;; clauses below key on operator names this one does not share.
   ((%hw-op-form-op expr)
     (%hw-op-backward v expr emit-fn local-adj-fn))
   ;; Endeavour 173: likewise the warp shuffles.  Ahead of the catch-all below, which would
   ;; otherwise report a shuffle as simply not differentiable.
   ((%shuffle-form-op expr)
     (%shuffle-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146 Gap 2: rem / mod.  Kept as its own clause rather than added to the
   ;; member list below because that list tests with #'eq against symbols read in THIS
   ;; package, and a kernel's reader may intern `rem` elsewhere.  Matching by symbol-name
   ;; sidesteps the question entirely.
   ((%ad-rem-or-mod-form-p expr)
     (%ad-handle-rem-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: int -> float is the identity on value, so the adjoint passes through.
   ;; (float -> int truncates and stays inert — see %ad-widening-conversion-form-p.)
   ((%ad-widening-conversion-form-p expr)
     (%ad-handle-widening-conversion-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: (ring-get BARRIER-RING i) is a scheduling object, not a value.  Scoped by
   ;; the ring's constructor rather than by the operator name — see %ad-inert-ring-get-p.
   ((%ad-inert-ring-get-p expr) nil)
   ;; Endeavor 146: (V (ring-get TILE-RING i)) is an ALIAS, not a computation — ANF hoisted a
   ;; pure view selector into its own binding.  Nothing to emit here; the use sites see through
   ;; it via *ad-view-alias-map* (see %handle-tilde-backward).  Distinct from the barrier case
   ;; above, which is inert because a barrier carries no value at all.
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "RING-GET"))
     nil)
   ((and (consp expr) (member (car expr)
                              ;; Endeavor 128: transcendentals join the math/trig backward.
                              '(+ - * / sin cos exp log log2 tan asin acos atan pow atan2)
                              :test #'eq))
     (%handle-math-and-trig-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (eq (car expr) '~))
     (%handle-tilde-backward v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms))
   ((and (consp expr)
         (symbolp (car expr))
         (gethash (car expr) *differentiable-functions*))
     (%handle-sub-fn-call-backward v expr emit-fn local-adj-fn hof-handler-fn))
   ;; An accessor that is GRADIENT-INERT must not be claimed here.  `extents~` ends in a
   ;; tilde, so %is-accessor-p takes it and %handle-accessor-backward mints a SCALAR adjoint
   ;; for its source.  On a scratch tile that scalar `<tile>_ADJ` COLLIDES with the tensor
   ;; `<tile>_ADJ` from scratch-adj-bindings, and since Crisp's LET is let*-like the scalar
   ;; (bound second) SHADOWS the tensor — after which every `(~ <tile>_ADJ i j)` indexes a
   ;; float.  That is what "No matching function overload for '~' / 'EXTENTS~' with argument
   ;; types (FLOAT ...)" meant, and it hit any differentiable kernel reading a scratch tile's
   ;; extents, i.e. every tile-stride matmul.
   ;;
   ;; Guarded HERE rather than by hoisting the skip clause to the top of the cond: that was
   ;; tried first and cost 11 specs (101/05, 101/06, 031/05 — record-field adjoints like
   ;; PA_X_ADJ went missing), because the skip predicate also matches mangled sub-function
   ;; names that the clauses below need to see.
   ((and (%is-accessor-p expr)
         (not (and (consp expr) (symbolp (car expr))
                   (%backward-skip-fn-p (car expr)))))
     (%handle-accessor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
         *record-param-field-adjs*
         (gethash v *record-param-field-adjs*))
     (%handle-constructor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
     nil)
   ;; Endeavor 124 (AD issues) A1: value-producing if / if+ / when[+] / unless[+]
   ;; and value-producing let. These bind a compound expression to V; the seed
   ;; V_adj must flow through the branches / let body (previously dropped, giving
   ;; a silent zero gradient, or erroring for the + variants).
   ((%value-if-p expr)
     (%handle-value-if-backward v expr adjoint-map emit-fn local-adj-fn
                                :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ((%value-let-p expr)
     (%handle-value-let-backward v expr adjoint-map emit-fn local-adj-fn
                                 :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                 :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ;; Endeavor 120: gradient-inert calls.
   ;;  - *inert-functions*: user functions with no differentiable params
   ;;    (zero gradient), recorded by %generate-backward-function-ast.
   ;;  - the compile-time uniformity intrinsics, which fold to constants and
   ;;    carry no gradient.
   ((and (consp expr) (symbolp (car expr))
         (%backward-skip-fn-p (car expr)))
     nil)
   ((and (consp expr) (symbolp (car expr))
         (or (gethash (car expr) *inert-functions*)
             (member (symbol-name (car expr))
                     '("PROVABLY-UNIFORM?" "PROVABLY-DIVERGENT?" "UNIFORMITY-STATE"
                       "TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
                     :test #'string=)))
     nil)
   ;; FRAGMENT-level MMA forms that no VJP claims.
   ;;
   ;; Endeavor 146: this message used to argue that a fragment backward is IMPOSSIBLE — "on a
   ;; single fragment one of the two backward GEMMs always violates the hardware shape
   ;; contract".  That claim was RETRACTED by 145 itself and is now demonstrably false:
   ;; 145/13 gradient-checks a fragment MMA on BMG (expect.A=1.2) and 145/07, which was written
   ;; as a NEGATIVE test asserting the impossibility, is now a positive one.  The retraction
   ;; routed the fragment backward through MEMORY, exactly as the tile VJP already routed dC,
   ;; and the lane-spanning reduction the old argument rested on does not arise.
   ;;
   ;; What is actually true is narrower and is about COVERAGE, not mathematics: the registry
   ;; has a VJP for `store-fragment` applied DIRECTLY to an `mma-accumulate` (the canonical
   ;; hello-mma chain), and not for other fragment shapes — an accumulator loaded by
   ;; `load-fragment-acc` and carried across a loop, for instance.
   ;;
   ;; The distinction matters because an over-broad diagnostic is how "MMA is forward-only"
   ;; became folklore in the first place: users read a claim about the hardware, believed it,
   ;; and wrote `forward-only` into kernels that did not need it.  Say what is missing, not
   ;; what is impossible.
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr))
                 '("MMA-ACCUMULATE" "LOAD-FRAGMENT-A" "LOAD-FRAGMENT-B"
                   "LOAD-FRAGMENT-ACC" "STORE-FRAGMENT" "MAKE-REGISTER-FRAGMENT")
                 :test #'string=))
     (when error-on-unknown
       (error "~A: no VJP is registered for this FRAGMENT-level MMA form.  This is a gap in COVERAGE, not a limit of the mathematics -- dA = dC.B^T and dB = A^T.dC hold at every shape, and a fragment-level backward IS supported for the canonical chain, `(store-fragment (mma-accumulate ACC A-frag B-frag) DST coords)`, which is gradient-checked on metal by 145/13.  Options: (1) express the multiply at TILE level with mma-accumulate-via-tile over a register tile -- the best-covered surface, with numeric proof in 142/01 and 145/12; (2) reshape into the covered fragment chain above; (3) if this kernel really is forward-only, use SKIP-WITH[--differentiate] or (declare forward-only).  If you need this form differentiated, the fix is to register a VJP for it, not to work around a limit that does not exist."
              (car expr))))
   ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
           (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
   (t nil)))

;; src/autodiff.lisp  (BUG 101: gate the input adjoint of padding lanes)
(defun %175-vjp-reduce-warp (form ctx)
  "VJP for reduce-warp: a warp all-reduce is self-transposing, so the backward pass is another
   reduce-warp of the adjoint.  See the section header."
  (let* ((fn  (second form))
         (var (third form))
         (local-adj (getf ctx :local-adj)))
    (unless (and (consp fn) (symbolp (car fn))
                 (string-equal (symbol-name (car fn)) "FUNCTION")
                 (string= (symbol-name (second fn)) "+"))
      (error "reduce-warp: autodiff is supported only for the + reduction.  The transpose of a SUM all-reduce is another sum all-reduce, which is exact and needs nothing recorded from the forward pass.  min/max would route the adjoint to the lane that supplied the winning value, which requires the forward pass to stash an argmin/argmax; an arbitrary binop needs the partial derivatives of that op at every butterfly step.  Neither is recorded.  Use the + reduction, or mark the kernel with a differentiate-skip if it is forward-only."))
    (unless (and var (symbolp var))
      (return-from %175-vjp-reduce-warp nil))
    (let ((vadj (funcall local-adj var)))
      (log:debug "175 VJP reduce-warp: all-reduce of ~a" vadj)
      ;; In place, mirroring the forward.
      ;; The SUM runs WITHOUT active-threads: a padding lane holds the result too, so its output
      ;; adjoint is real and belongs in the sum.  But the sum is then every lane's INPUT adjoint,
      ;; and a padding lane's input never entered the reduction -- BUG 101: it must get zero.
      ;; (Before the gate, a padding lane read the full gradient: 16.0 where FD gives 0.0.)
      (let ((active (fifth form)))
        (if active
            `(progn
               (reduce-warp ,fn ,vadj 0.0)
               (when (>= (to-int (warp-lane)) (to-int ,active))
                 (set! ,vadj (- ,vadj ,vadj))))
            `(reduce-warp ,fn ,vadj 0.0))))))

;; src/autodiff.lisp  (BUG 101: re-register -- the VJP is captured by function OBJECT, so the
;; redefinition above is dead code without this.  At fold time the src registration already covers it.)
(eval-when (:load-toplevel :execute)
  (register-vjp "REDUCE-WARP" (function %175-vjp-reduce-warp)))

;; src/autodiff.lisp  (BUG 099: one new clause at the head of the cond -- SUPERSEDES the copy above)
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
   ;; BUG 099: a COPY binding, v := s.  The reverse walk has already processed every use of v, so
   ;; v's adjoint is final here and flows to s unchanged.  Without this clause the binding fell
   ;; through to (t nil) and v's adjoint was dropped -- (let ((v0 v)) (* v v0)) differentiated to x,
   ;; not 2x.  (%backward-value-expr has the same rule for let/if VALUE expressions; the top-level
   ;; walk never went there.)
   ;;
   ;; Scoped to SCALAR dataflow: a tensor input, a scratch tile, or a view alias keeps its adjoint
   ;; in a TENSOR named <sym>_ADJ, and minting a scalar of the same name here would shadow it (the
   ;; collision described at the accessor clause below).  And only when v already HAS an adjoint --
   ;; a copy nothing downstream reads contributes nothing, and must not mint a binding for s.
   ((and expr (symbolp expr) (not (keywordp expr)))
     (when (and (not (eq expr v))
                (gethash v adjoint-map)
                (not (and tensor-inputs-ht (gethash expr tensor-inputs-ht)))
                ;; scratch-tile-syms is a HASH TABLE here (a list elsewhere) -- accept either.
                (not (if (hash-table-p scratch-tile-syms)
                         (gethash expr scratch-tile-syms)
                         (member expr scratch-tile-syms)))
                (not (%ad-resolve-view-alias expr))
                (not (%ad-resolve-view-alias v)))
       (log:debug "099: copy binding ~a := ~a -- adjoint flows to ~a" v expr expr)
       (funcall emit-fn `(set! ,(funcall local-adj-fn expr)
                               (+ ,(funcall local-adj-fn expr) ,(funcall local-adj-fn v))))))
   ;; Endeavour 170: the hardware math ops carry their own backward rules.  First, because the
   ;; clauses below key on operator names this one does not share.
   ((%hw-op-form-op expr)
     (%hw-op-backward v expr emit-fn local-adj-fn))
   ;; Endeavour 173: likewise the warp shuffles.  Ahead of the catch-all below, which would
   ;; otherwise report a shuffle as simply not differentiable.
   ((%shuffle-form-op expr)
     (%shuffle-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146 Gap 2: rem / mod.  Kept as its own clause rather than added to the
   ;; member list below because that list tests with #'eq against symbols read in THIS
   ;; package, and a kernel's reader may intern `rem` elsewhere.  Matching by symbol-name
   ;; sidesteps the question entirely.
   ((%ad-rem-or-mod-form-p expr)
     (%ad-handle-rem-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: int -> float is the identity on value, so the adjoint passes through.
   ;; (float -> int truncates and stays inert — see %ad-widening-conversion-form-p.)
   ((%ad-widening-conversion-form-p expr)
     (%ad-handle-widening-conversion-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: (ring-get BARRIER-RING i) is a scheduling object, not a value.  Scoped by
   ;; the ring's constructor rather than by the operator name — see %ad-inert-ring-get-p.
   ((%ad-inert-ring-get-p expr) nil)
   ;; Endeavor 146: (V (ring-get TILE-RING i)) is an ALIAS, not a computation — ANF hoisted a
   ;; pure view selector into its own binding.  Nothing to emit here; the use sites see through
   ;; it via *ad-view-alias-map* (see %handle-tilde-backward).  Distinct from the barrier case
   ;; above, which is inert because a barrier carries no value at all.
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "RING-GET"))
     nil)
   ((and (consp expr) (member (car expr)
                              ;; Endeavor 128: transcendentals join the math/trig backward.
                              '(+ - * / sin cos exp log log2 tan asin acos atan pow atan2)
                              :test #'eq))
     (%handle-math-and-trig-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (eq (car expr) '~))
     (%handle-tilde-backward v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms))
   ((and (consp expr)
         (symbolp (car expr))
         (gethash (car expr) *differentiable-functions*))
     (%handle-sub-fn-call-backward v expr emit-fn local-adj-fn hof-handler-fn))
   ;; An accessor that is GRADIENT-INERT must not be claimed here.  `extents~` ends in a
   ;; tilde, so %is-accessor-p takes it and %handle-accessor-backward mints a SCALAR adjoint
   ;; for its source.  On a scratch tile that scalar `<tile>_ADJ` COLLIDES with the tensor
   ;; `<tile>_ADJ` from scratch-adj-bindings, and since Crisp's LET is let*-like the scalar
   ;; (bound second) SHADOWS the tensor — after which every `(~ <tile>_ADJ i j)` indexes a
   ;; float.  That is what "No matching function overload for '~' / 'EXTENTS~' with argument
   ;; types (FLOAT ...)" meant, and it hit any differentiable kernel reading a scratch tile's
   ;; extents, i.e. every tile-stride matmul.
   ;;
   ;; Guarded HERE rather than by hoisting the skip clause to the top of the cond: that was
   ;; tried first and cost 11 specs (101/05, 101/06, 031/05 — record-field adjoints like
   ;; PA_X_ADJ went missing), because the skip predicate also matches mangled sub-function
   ;; names that the clauses below need to see.
   ((and (%is-accessor-p expr)
         (not (and (consp expr) (symbolp (car expr))
                   (%backward-skip-fn-p (car expr)))))
     (%handle-accessor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
         *record-param-field-adjs*
         (gethash v *record-param-field-adjs*))
     (%handle-constructor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
     nil)
   ;; Endeavor 124 (AD issues) A1: value-producing if / if+ / when[+] / unless[+]
   ;; and value-producing let. These bind a compound expression to V; the seed
   ;; V_adj must flow through the branches / let body (previously dropped, giving
   ;; a silent zero gradient, or erroring for the + variants).
   ((%value-if-p expr)
     (%handle-value-if-backward v expr adjoint-map emit-fn local-adj-fn
                                :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ((%value-let-p expr)
     (%handle-value-let-backward v expr adjoint-map emit-fn local-adj-fn
                                 :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                 :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ;; Endeavor 120: gradient-inert calls.
   ;;  - *inert-functions*: user functions with no differentiable params
   ;;    (zero gradient), recorded by %generate-backward-function-ast.
   ;;  - the compile-time uniformity intrinsics, which fold to constants and
   ;;    carry no gradient.
   ((and (consp expr) (symbolp (car expr))
         (%backward-skip-fn-p (car expr)))
     nil)
   ((and (consp expr) (symbolp (car expr))
         (or (gethash (car expr) *inert-functions*)
             (member (symbol-name (car expr))
                     '("PROVABLY-UNIFORM?" "PROVABLY-DIVERGENT?" "UNIFORMITY-STATE"
                       "TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
                     :test #'string=)))
     nil)
   ;; FRAGMENT-level MMA forms that no VJP claims.
   ;;
   ;; Endeavor 146: this message used to argue that a fragment backward is IMPOSSIBLE — "on a
   ;; single fragment one of the two backward GEMMs always violates the hardware shape
   ;; contract".  That claim was RETRACTED by 145 itself and is now demonstrably false:
   ;; 145/13 gradient-checks a fragment MMA on BMG (expect.A=1.2) and 145/07, which was written
   ;; as a NEGATIVE test asserting the impossibility, is now a positive one.  The retraction
   ;; routed the fragment backward through MEMORY, exactly as the tile VJP already routed dC,
   ;; and the lane-spanning reduction the old argument rested on does not arise.
   ;;
   ;; What is actually true is narrower and is about COVERAGE, not mathematics: the registry
   ;; has a VJP for `store-fragment` applied DIRECTLY to an `mma-accumulate` (the canonical
   ;; hello-mma chain), and not for other fragment shapes — an accumulator loaded by
   ;; `load-fragment-acc` and carried across a loop, for instance.
   ;;
   ;; The distinction matters because an over-broad diagnostic is how "MMA is forward-only"
   ;; became folklore in the first place: users read a claim about the hardware, believed it,
   ;; and wrote `forward-only` into kernels that did not need it.  Say what is missing, not
   ;; what is impossible.
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr))
                 '("MMA-ACCUMULATE" "LOAD-FRAGMENT-A" "LOAD-FRAGMENT-B"
                   "LOAD-FRAGMENT-ACC" "STORE-FRAGMENT" "MAKE-REGISTER-FRAGMENT")
                 :test #'string=))
     (when error-on-unknown
       (error "~A: no VJP is registered for this FRAGMENT-level MMA form.  This is a gap in COVERAGE, not a limit of the mathematics -- dA = dC.B^T and dB = A^T.dC hold at every shape, and a fragment-level backward IS supported for the canonical chain, `(store-fragment (mma-accumulate ACC A-frag B-frag) DST coords)`, which is gradient-checked on metal by 145/13.  Options: (1) express the multiply at TILE level with mma-accumulate-via-tile over a register tile -- the best-covered surface, with numeric proof in 142/01 and 145/12; (2) reshape into the covered fragment chain above; (3) if this kernel really is forward-only, use SKIP-WITH[--differentiate] or (declare forward-only).  If you need this form differentiated, the fix is to register a VJP for it, not to work around a limit that does not exist."
              (car expr))))
   ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
           (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
   (t nil)))
