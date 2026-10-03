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

;;; ===========================================================================================
;;; BUG 100 -- in-place scalar writes were invisible to AD.  Endeavour 177 Phase 1.
;;;
;;; A set! of a scalar local, and an in-place reduction, are bare STATEMENTS in the flat ANF.  The
;;; backward's primal replay is a LET of the forward's BINDINGS, so it never ran them: every later read
;;; of the variable saw its first value, and a set! carried no adjoint at all.
;;;
;;; The fix VERSIONS each such write on the AD path (the forward kernel is untouched):
;;;
;;;     (SET! V e)                ->  (V%V1 e)                          later reads use V%V1
;;;     (REDUCE-WARP #'+ V 0.0)   ->  (V%V1 V) (REDUCE-WARP #'+ V%V1 0.0)   later reads use V%V1
;;;
;;; A set! becomes an ordinary binding: the replay runs it, and its adjoint flows through the copy
;;; rule (BUG 099).  A reduction stays a statement, so the replay is SPLIT after the copy's binding and
;;; the statement re-runs there (%ad-assemble-primal-replay); its VJP works on V%V1's adjoint and the
;;; copy passes it back to V.  The reverse walk itself is unchanged.
;;;
;;; Deliberately narrow: top-level straight-line writes only.  A write is NOT versioned (and behaves as
;;; before) when the variable is rebound later, or appears later in a multi-value binding -- those are
;;; recognised by EQ downstream (%collect-forward-primal-bindings), and renaming would lose them.
;;; Grid reductions are not versioned: replaying one would write the outputs and counters again.
;;; ===========================================================================================

;; src/macros.lisp
(defparameter *ad-versioned-reductions* '("REDUCE-WARP" "REDUCE-WORKGROUP")
  "BUG 100.  The in-place reductions whose result the backward's primal replay re-runs: the
   all-reduces, which touch nothing but the variable and their scratch.")

;; src/macros.lisp
(defun %ad-form-head-name (form)
  "The symbol-name of FORM's head, or NIL."
  (and (consp form) (car form) (symbolp (car form)) (symbol-name (car form))))

;; src/macros.lisp
(defun %ad-tree-has-head-p (sym tree)
  "T if some list inside TREE (or TREE itself) has SYM as its head -- in an ANF body that is a
   binding of SYM, since a variable is never called."
  (and (consp tree)
       (or (eq (car tree) sym)
           (loop for x on tree
                 thereis (and (consp (car x)) (%ad-tree-has-head-p sym (car x)))))))

;; src/macros.lisp
(defun %ad-tree-mentions-p (sym tree)
  "T if SYM occurs anywhere in TREE."
  (cond ((eq tree sym) t)
        ((consp tree) (or (%ad-tree-mentions-p sym (car tree))
                          (%ad-tree-mentions-p sym (cdr tree))))
        (t nil)))

;; src/macros.lisp
(defun %ad-multi-value-binding-shape-p (form)
  "T if FORM looks like a flat-ANF multi-value binding (V1 V2 .. expr)."
  (and (consp form) (> (length form) 2)
       (not (equal (%ad-form-head-name form) "SET!"))
       (every #'symbolp (butlast form))
       (consp (car (last form)))))

;; src/macros.lisp
(defun %ad-versionable-p (v rest)
  "BUG 100.  May V be versioned, given REST (the flat-ANF forms after the write)?  Not if a later form
   rebinds it, nor if it appears in a later multi-value binding (see the section header)."
  (and v (symbolp v) (not (keywordp v))
       (not (%ad-tree-has-head-p v rest))
       (notany (lambda (f) (and (%ad-multi-value-binding-shape-p f) (%ad-tree-mentions-p v f)))
               rest)))

;; src/macros.lisp
(defun %ad-version-sym (v n)
  "The Nth version of variable V: V%VN."
  (intern (format nil "~A%V~D" (symbol-name v) n)
          (or (symbol-package v) (find-package :crisp.compiler))))

;; src/macros.lisp
(defun %ad-version-in-place-writes (flat-anf)
  "BUG 100.  Versions the top-level in-place scalar writes of FLAT-ANF (see the section header).
   Returns (values NEW-FLAT-ANF REPLAY-STATEMENTS), the latter an alist (VERSION-SYM . STATEMENT) of
   the reductions the primal replay must re-run, in order."
  (let ((out '()) (stmts '()) (scalars '()) (counter 0) (rest flat-anf))
    (loop while rest
          do (let* ((form (pop rest))
                    (head (%ad-form-head-name form)))
               (cond
                ;; (SET! V e) of a scalar local -> (V%Vn e)
                ((and (equal head "SET!") (= (length form) 3)
                      (symbolp (second form)) (member (second form) scalars)
                      (%ad-versionable-p (second form) rest))
                  (let* ((v (second form))
                         (nv (%ad-version-sym v (incf counter))))
                    (log:debug "BUG 100: set! ~a -> binding ~a" v nv)
                    (push (list nv (third form)) out)
                    (push nv scalars)
                    (setf rest (subst nv v rest))))
                ;; (REDUCE-xxx f V id ..) -> (V%Vn V) (REDUCE-xxx f V%Vn id ..)
                ((and (member head *ad-versioned-reductions* :test #'equal)
                      (>= (length form) 4)
                      (%ad-versionable-p (third form) rest))
                  (let* ((v (third form))
                         (nv (%ad-version-sym v (incf counter)))
                         (stmt (list* (first form) (second form) nv (cdddr form))))
                    (log:debug "BUG 100: ~a of ~a -> copy ~a + replayed statement" head v nv)
                    (push (list nv v) out)
                    (push stmt out)
                    (push (cons nv stmt) stmts)
                    (push nv scalars)
                    (setf rest (subst nv v rest))))
                (t
                  ;; a scalar local: bound by a two-element binding whose value is not a constructor
                  (when (and (consp form) (= (length form) 2) (car form) (symbolp (car form))
                             (let ((h (%ad-form-head-name (second form))))
                               (not (and h (>= (length h) 5) (string= "MAKE-" h :end2 5)))))
                    (push (car form) scalars))
                  (push form out)))))
    (values (nreverse out) (nreverse stmts))))

;; src/macros.lisp
(defun %ad-assemble-primal-replay (bindings stmts body)
  "BUG 100.  The backward's primal replay around BODY: a LET of BINDINGS, SPLIT after each version
   symbol's binding so the reduction in STMTS (VERSION-SYM . STATEMENT) re-runs exactly there --
       (let (b1 .. (V%V1 V)) (reduce-warp #'+ V%V1 0.0) (let (..rest..) BODY))
   A statement whose version binding was dropped from the replay (an unreplayable dependency) cannot
   run and is skipped -- every later binding reading it was dropped with it."
  (if (null stmts)
      `(let (,@bindings) ,body)
      (let* ((nv (car (first stmts)))
             (pos (position nv bindings :key (lambda (b) (and (consp b) (first b))))))
        (if pos
            (progn
              (log:debug "BUG 100: replaying ~a after binding ~a" (cdr (first stmts)) nv)
              `(let (,@(subseq bindings 0 (1+ pos)))
                 ,(cdr (first stmts))
                 ,(%ad-assemble-primal-replay (nthcdr (1+ pos) bindings) (rest stmts) body)))
            (progn
              (log:warn "BUG 100: version ~a is not in the primal replay; its reduction is not replayed" nv)
              (%ad-assemble-primal-replay bindings (rest stmts) body))))))

;; src/macros.lisp  (BUG 100: two edits -- the versioning pass after flatten-anf-body, and the
;; split primal replay at the def-kernel-exact body)
(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-
   boundary accessor calls route adj into the SROA'd field's adj sym.
   Endeavor 107: pre-expands stride macros (tensor-stride / grid-stride /
   loop-vector-stride) in the kernel body so AD walks the expansion.
   Endeavor 145 P1: the forward primal replay now collects MULTI-VALUE bindings
   too (via %collect-forward-primal-bindings), so `(M N (outer-dimensions A B))`
   is bound in the backward body instead of dangling as \"Unknown variable M\"."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                                        rec-grad-out-params rec-grad-out-types
                                        record-subs-ht record-type-ht grad-cell-syms
                                        struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let* ((subst-body
                (mapcar (lambda (form)
                          (%substitute-record-accessors form record-subs-ht record-type-ht))
                    raw-body))
               ;; 107: AD pre-pass — rewrite stride macros into their expansions
               ;; using a kernel-param-based type resolver for tensor-stride CT.
               ;; The resolver is built from the ORIGINAL inputs/input-types
               ;; (not flat-inputs) so tensor-stride forms over a record param
               ;; resolve against the record's type before SROA renaming.  In
               ;; practice the tensor expression is a bare param name; the
               ;; resolver handles that cleanly.
               (kernel-type-resolver (%make-kernel-param-type-resolver inputs input-types))
               ;; 145 P8: lower matrix-multiply-tile-stride FIRST — the 107 pre-pass below
               ;; does not know it, and ANF mangles it if it survives (see the block above).
               (mmts-lowered-body (mapcar #'%mma-ad-prelower-mmts subst-body))
               (expanded-body
                (mapcar (lambda (form)
                          (%expand-stride-macros-in-form form kernel-type-resolver nil))
                    mmts-lowered-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
                  (error 'crisp.compiler:crisp-compiler-error
                    :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                        (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                        (loop for entry in struct-shadow-info
                              for p = (first entry)
                              collect (nth (position p flat-inputs :test #'eq)
                                           flat-input-types)))))
                (if (and (null augmented-diff-flat-inputs)
                         (null struct-shadow-info))
                    `(progn
                      (eval-when (:compile-toplevel :load-toplevel :execute)
                        (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                          (loop for p in ',bwd-params
                                for t-spec in ',bwd-types
                                collect (cons p t-spec))))
                      (def-kernel-exact ,bwd-name ,exploded-params
                                        (declare #'(,@exploded-types))
                                        (return)))
                    ;; Endeavor 146 Gap 3: lower with-warp-specialization BEFORE anf-transform.
                    ;; anf-transform knows a fixed set of control forms (IF, DOTIMES,
                    ;; WITH-PRECISION ...) whose bodies it must NOT hoist.  with-warp-
                    ;; specialization is not among them, so its role bodies were lifted out
                    ;; into the flat statement sequence and the warp gating VANISHED:
                    ;;     (%ANF-T-6  (SET! (~ C W L) %ANF-T-5))   ; producer body, unconditional
                    ;;     (%ANF-T-7  (:PRODUCER %ANF-T-6))
                    ;;     (WITH-WARP-SPECIALIZATION %ANF-T-3 %ANF-T-7 %ANF-T-11)
                    ;; A backward built from that would run BOTH role bodies in every warp.
                    ;; The reported symptom was only "Function CONSUMER is not differentiable";
                    ;; the damage underneath it was worse and silent.
                    ;;
                    ;; Lowering here — with the ANALYZER's own %lower-warp-specialization —
                    ;; hands anf-transform an ordinary let/if it already treats as control flow,
                    ;; so nothing downstream needs to know the construct exists.  This is the AD
                    ;; path only; the forward still analyses the original form.
                    (let* ((anf-body (mapcar #'anf-transform
                                             (%ad-canonicalize-warp-specialization expanded-body)))
                           (versioned (multiple-value-list
                                       ;; BUG 100: version in-place scalar writes
                                       (%ad-version-in-place-writes (flatten-anf-body anf-body))))
                           (flat-anf (first versioned))
                           (replay-statements (second versioned))
                           ;; 145 P1: was an inline 2-element-only LOOP here.
                           ;; BUG 037: staged-tile primal reads resolve to their global source.
                           (forward-bindings
                            (let ((*ad-tile-src-map* (%mma-ad-tile-source-map flat-anf)))
                              (%ad-rewrite-primal-bindings
                               (%collect-forward-primal-bindings flat-anf anf-body))))
                           (struct-shadow-ht
                            (when struct-shadow-info
                                  (let ((ht (make-hash-table :test 'eq)))
                                    (dolist (entry struct-shadow-info)
                                      (setf (gethash (first entry) ht)
                                        (cons (second entry)
                                              (fourth entry))))
                                    (%register-shadow-anf-intermediates flat-anf ht)
                                    ht)))
                           (kernel-record-param-field-adjs-ht
                            (when (> (hash-table-count record-subs-ht) 0)
                                  (let ((ht (make-hash-table :test 'eq)))
                                    (maphash
                                      (lambda (rsym field-alist)
                                        (let ((adj-alist
                                               (loop for entry in field-alist
                                                     for fname = (car entry)
                                                     for fsym = (cdr entry)
                                                       unless (eq fname :%nested-leaf%)
                                                     collect (cons (symbol-name fname)
                                                                   (intern (format nil "~A_ADJ" (symbol-name fsym))
                                                                           pkg)))))
                                          (setf (gethash rsym ht) adj-alist)))
                                      record-subs-ht)
                                    ht)))
                           (raw-backward-walk
                            (let ((*struct-kernel-param-shadows* struct-shadow-ht)
                                  (*record-param-field-adjs* kernel-record-param-field-adjs-ht))
                              (generate-backward-walk flat-anf
                                                      augmented-diff-flat-inputs outputs
                                                      augmented-diff-flat-input-types output-types
                                                      :kernel-pkg pkg)))
                           (backward-walk-1
                            (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                           (backward-walk-2
                            (if struct-shadow-info
                                (let ((all-leaves
                                       (loop for entry in struct-shadow-info
                                               append (%collect-all-leaf-adj-syms (fourth entry)))))
                                  (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                                backward-walk-1))
                           (backward-walk
                            (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
                           (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))
                      `(progn
                        (eval-when (:compile-toplevel :load-toplevel :execute)
                          (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                            (loop for p in ',bwd-params
                                  for t-spec in ',bwd-types
                                  collect (cons p t-spec))))
                        (def-kernel-exact ,bwd-name ,exploded-params
                                          (declare #'(,@exploded-types))
                                          (let (,@all-reassembly)
                                            ,(%ad-assemble-primal-replay forward-bindings replay-statements backward-walk))
                                          (return)))))))))))))
