;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;

(in-package :crisp.compiler)

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P1: gradient-inert shape queries.
;;;
;;; An MMA kernel does not fail to differentiate at the MMA — it fails at the SHAPE
;;; QUERY, well before it gets there.  132/06-tiled-matmul dies with
;;;   "Function INNER-DIMENSION is not differentiable"
;;; on its very first binding.
;;;
;;; `inner-dimension` and `outer-dimensions` read K / M / N out of the operands'
;;; extents.  They depend on the matrices' SHAPE, never on their VALUES, so their
;;; gradient contribution is identically zero — exactly like extents~ / strides~ /
;;; num-rows, which are already skipped.
;;;
;;; The two forms fail DIFFERENTLY, and the difference is the whole of P1:
;;;
;;;   inner-dimension  -> single-value binding.  The backward WALK rejects it.
;;;                       Fix: %backward-skip-fn-p.
;;;   outer-dimensions -> MULTI-value binding.  The walk already ignores it
;;;                       correctly, but the backward kernel's primal REPLAY drops
;;;                       it, so the bound vars are unbound in the backward body
;;;                       ("Unknown variable M").
;;;                       Fix: %collect-forward-primal-bindings, called from
;;;                       %generate-backward-kernel-ast.
;;;
;;; Specs: tests/spec/145-mma-autodiff/01-inner-dimension-inert.crisp
;;;        tests/spec/145-mma-autodiff/02-outer-dimensions-inert.crisp
;;; ===================================================================

;; src/autodiff.lisp
;; NOTE (145 P3b): this is the P1 body, renamed so the final %backward-skip-fn-p (further
;; down, which adds MAKE-REGISTER-TILE) can delegate to it instead of duplicating the list.
;; When folding back into src/, merge the two into one definition.
(defun %backward-skip-fn-p-145p1 (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.

   Endeavor 145 P1: INNER-DIMENSION / OUTER-DIMENSIONS join the gradient-inert shape
   queries.  Both are pure reads of a tensor's extents — `(inner-dimension A B)` is K,
   `(outer-dimensions A B)` is (values M N) — so they carry no value dependence and
   contribute exactly zero gradient, like EXTENTS~ / STRIDES~ / NUM-ROWS above them.
   Their forward values remain available to the backward via the primal replay in
   %generate-backward-kernel-ast."
  (let ((name (symbol-name fn-sym)))
    (cl:flet ((prefix-or-mangled-p (prefix)
                                   (let ((plen (length prefix)))
                                     (or (string= name prefix)
                                         (and (> (length name) plen)
                                              (string= (subseq name 0 plen) prefix)
                                              (cl:char= (cl:char name plen) #\_))))))
      (or
       (find #\% name)
       (string= name "AS")
       (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
       (loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
               when (and (>= (length name) (+ 3 (length suffix)))
                         (string= (subseq name 0 3) "TO-")
                         (string= (subseq name (- (length name) (length suffix))) suffix))
               return t)
       (loop for prefix in '("NUM-ROWS" "NUM-COLS" "GET-LAYOUT" "BYTES~"
                                        "LENGTH~" "EXTENTS~" "STRIDES~" "PARENT~"
                                        "CONTIGUOUS-TERM~" "ELEMENT-TYPE~" "ADDRESS-SPACE~"
                                        "ALIGN~" "NUM-DIMS~" "OFFSET~"
                                        "MAKE-MATRIX" "MAKE-VECTOR" "MAKE-CELL" "MAKE-TENSOR"
                                        ;; 111 Phase 1c: scratch constructors are gradient-inert.
                                        "MAKE-SCRATCH-CELL" "MAKE-SCRATCH-VECTOR"
                                        "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR"
                                        ;; 123 (FFI-AD): handle constructor / deref and the
                                        ;; pointer/handle TYPE constructors are gradient-inert.
                                        ;; (base-ptr~ is handled by the accessor path; FFI
                                        ;; buffer gradients flow via shadow pointers routed in
                                        ;; %emit-foreign-backward.)
                                        "MAKE-C-HANDLE" "GET-POINTER" "C-POINTER" "C-HANDLE"
                                        "TRANSPOSE" "TRANSPOSE!" "ROW" "COL" "SLICE"
                                        ;; 145 P1 (MMA autodiff): the MMA shape queries are pure
                                        ;; extent reads — zero value dependence, zero gradient.
                                        "INNER-DIMENSION" "OUTER-DIMENSIONS"
                                        "GET-GLOBAL-ID" "GET-LOCAL-ID" "GET-WORKGROUP-ID"
                                        "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                                        "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET"
                                        "GET-GLOBAL-ID-ABS" "GET-WORK-DIM"
                                        "GET-LOCAL-LINEAR-ID" "GET-LOCAL-LINEAR-SIZE"
                                        "GET-GLOBAL-LINEAR-ID" "GET-GLOBAL-LINEAR-SIZE"
                                        "GET-TOTAL-THREADS" "GET-TOTAL-GROUPS"
                                        "SYNC-WORKGROUP" "SYNC-WARP" "MEM-FENCE")
               when (prefix-or-mangled-p prefix) return t)))))



;; src/autodiff.lisp
(defun %mma-ad-prelower-mmts (form)
  "Endeavor 145 P8: pre-lower matrix-multiply-tile-stride ahead of the AD pre-pass.
   When FORM is a LET, its bindings supply the register-tile dims map first."
  (if (and (consp form) (symbolp (car form))
           (member (symbol-name (car form)) '("LET" "LET*") :test #'string=)
           (listp (second form)))
      (let ((reg-map (%mmts-register-dims-map (second form))))
        `(,(first form) ,(second form)
          ,@(mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) (cddr form))))
      (%mma-ad-expand-mmts-in-form form nil)))

;; src/macros.lisp
(defun %collect-multi-value-anf-bindings (anf-body)
  "The genuine MULTI-VALUE LET bindings in ANF-BODY, as the very cons cells that
   flatten-anf-body will go on to push into flat-anf.

   Endeavor 145 P1.  A multi-value binding CANNOT be recognized by shape once the body
   is flattened: flatten-anf-body (src/anf-transform.lisp:369) pushes real LET bindings
   and bare statement forms into the same flat list, and they are structurally
   identical.  `(M N (outer-dimensions A B))` is a binding; `(load-tile-at A tile (0))`
   and `(set! acc (+ acc x))` are statements — yet all three are \"symbols then a cons\".
   Matching on shape misreads the statements as bindings and splices them into a LET,
   which is how the first cut of this broke 111/14 and 111/15.

   So identify bindings where the distinction still EXISTS — walking the pre-flatten
   ANF, where a binding is by construction an element of a LET's binding list — and let
   the caller match by EQ.  This mirrors flatten-anf-body's own walk exactly."
  (let ((found nil))
    (labels ((walk (expr)
               (cond
                ((and (consp expr) (eq (car expr) 'let))
                  (dolist (b (cadr expr))
                    (when (and (consp b) (>= (length b) 3))
                      (push b found)))
                  (dolist (f (cddr expr))
                    (unless (and (consp f) (eq (car f) 'declare))
                      (walk f))))
                ((and (consp expr) (eq (car expr) 'progn))
                  (dolist (f (cdr expr)) (walk f)))
                ((and (consp expr) (eq (car expr) 'declare)) nil)
                (t nil))))
      (dolist (form anf-body) (walk form)))
    found))

(defun %vjp-form-mentions-any-p (form syms)
  "T when FORM references any symbol in SYMS."
  (cond ((symbolp form) (and form (member form syms) t))
        ((consp form) (some (lambda (x) (%vjp-form-mentions-any-p x syms)) form))
        (t nil)))

;; src/macros.lisp
(defun %collect-forward-primal-bindings (flat-anf anf-body)
  "The forward primal bindings replayed at the head of a backward kernel.

   Endeavor 145 P1.  This was an inline LOOP inside %generate-backward-kernel-ast that
   collected only TWO-element ANF forms `(sym expr)`.  A Crisp MULTI-VALUE binding
   flattens to a THREE-or-more element form — `(M N (outer-dimensions A B))` — so it
   was silently dropped and every var it bound was unbound in the backward body
   (\"Unknown variable M\").  Both shapes are valid Crisp LET bindings (Crisp's LET
   supports multiple-value binding directly), so both belong in the replay LET.

   The two-element rule is preserved VERBATIM from the original so existing kernels
   replay byte-identically; multi-value bindings are added by EQ against
   %collect-multi-value-anf-bindings (never by shape — see its docstring).

   Filtering FLAT-ANF rather than appending the multi-value bindings keeps them in
   SOURCE ORDER, so a later binding may still reference an earlier one."
  (log:debug "145: flat-anf handed to the backward walk:~%~{  ~s~%~}" flat-anf)
  (let* ((mv-bindings (%collect-multi-value-anf-bindings anf-body))
         (candidates (loop for form in flat-anf
                             when (or (and (consp form) (= (length form) 2) (symbolp (car form)))
                                      (member form mv-bindings :test #'eq))
                           collect form))
         ;; A binding whose VALUE is a cons with a NON-SYMBOL head is not a call — it is a bare
         ;; list that anf-normalize bound as if it were one.  Coordinate lists do exactly this:
         ;; (load-fragment-a A (0 0)) yields `(%ANF-T-1 (0 0))`, and replaying that makes the
         ;; backward try to analyze `(0 0)` as an expression.  Such a binding cannot be
         ;; replayed, and TRANSITIVELY neither can anything that references it.  Nothing in a
         ;; backward needs them: the VJPs that want those coordinates resolve them straight
         ;; out of flat-anf.
         (dropped (loop for b in candidates
                          for v = (car (last b))
                          when (and (consp v) (not (symbolp (car v))))
                        collect (car b)))
         (kept candidates))
    (loop for changed = nil
          do (setf kept
                   (loop for b in kept
                           if (or (member (car b) dropped)
                                  (%vjp-form-mentions-any-p (car (last b)) dropped))
                         do (progn (pushnew (car b) dropped) (setf changed t))
                         else collect b))
          while changed)
    kept))

;; src/macros.lisp
;; VERBATIM re-definition of the src/ original, with ONE change: the inline
;; `forward-bindings` LOOP is replaced by a call to %collect-forward-primal-bindings
;; (see above), so multi-value primal bindings are replayed into the backward kernel.
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
                    (let* ((anf-body (mapcar #'anf-transform expanded-body))
                           (flat-anf (flatten-anf-body anf-body))
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
                                            (let (,@forward-bindings)
                                              ,backward-walk))
                                          (return)))))))))))))



;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P2: load-fragment-acc.
;;;
;;; The backward pass must get dC (the `C_grad` global matrix) INTO a register
;;; accumulator before either backward GEMM can run, and nothing did that:
;;;   - store-fragment is accumulator -> memory only.
;;;   - load-fragment-a / -b read the A / B OPERAND layouts, not the accumulator's.
;;;   - load-tile into a register tile is Intel/SPV-only (Subgroup2DBlockLoadINTEL) and
;;;     has no PTX mapping at all.
;;;
;;; So this is the exact inverse of store-fragment: same accumulator layout, same
;;; (TY TX) tile addressing, reads instead of writes.  Like its sibling it is a pure
;;; REWRITE on PTX (no new codegen) and a coop-op node on SPV.
;;;
;;; Specs: tests/spec/145-mma-autodiff/03-load-fragment-acc-bmg.crisp  (on-metal)
;;;        tests/spec/145-mma-autodiff/04-load-fragment-acc-ptx.crisp  (IR-checked)
;;; ===================================================================

;; src/mma.lisp
(defun analyze-load-fragment-acc (expr env context location)
  "P2 (145): (load-fragment-acc SRC (TY TX)) reads a fp32 ACCUMULATOR fragment from the
   SRC matrix at logical tile (TY TX).  The exact inverse of store-fragment.

   :spirv -> CooperativeMatrixLoadKHR with Use=2 (accumulator), rows/cols from the active
   profile's shape and layout from the source tensor's :contiguous-term — mirroring
   analyze-store-fragment so a Load/Store pair always agrees.

   else   -> the NVIDIA per-lane read at the m16n8 fp32 accumulator layout.  With
   g = lane/4 and t = lane%4 this lane's four registers live at
     (g, 2t) (g, 2t+1) (g+8, 2t) (g+8, 2t+1)
   offset by the tile origin (TY*16, TX*8) — byte-for-byte the addresses store-fragment
   writes, only feeding %construct-struct instead of set!.

   The fragment is tallied against the kernel's register budget exactly as
   make-register-fragment tallies one: a LOADED accumulator occupies the same registers
   as a constructed one, and endeavor 144's fit-check must see both."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sk))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
              (%spv-note-register-fragment sm sn context location)
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float sm sn 2) :kind :load
               :tensor-node tnode
               :rows sm :cols sn :use 2 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          (progn
            (%ptx-note-register-demand 4 context location)
            (analyze-expression
             `(let ((lane (to-int (warp-lane))))
                (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                  (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                    (%construct-struct register-fragment-acc-f32-16x8
                      (~ ,src row col)
                      (~ ,src row (+ col 1))
                      (~ ,src (+ row 8) col)
                      (~ ,src (+ row 8) (+ col 1))))))
             env context location))))))

;; src/mma.lisp
;; VERBATIM re-definition of the src/ original, with ONE added entry: LOAD-FRAGMENT-ACC.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.  Overlay (Endeavor 140): adds the wgmma forms.
   Endeavor 145 P2: adds LOAD-FRAGMENT-ACC (the store-fragment inverse)."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         ;; Endeavor 145 (P2) — the accumulator READ, inverse of store-fragment.
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         ;; Endeavor 142 (Phase B) — Intel L1 prefetch (Subgroup2DBlockPrefetchINTEL)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         ;; Endeavor 140 (Chapter 4) -- wgmma forms
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3a: mma-accumulate-via-tile walks K within a tile.
;;;
;;; A forward capability, but a hard PREREQUISITE for the backward — and a latent forward
;;; bug fix in its own right.
;;;
;;; With a workgroup tile (Mt x Nt) accumulating over K in steps of Kt:
;;;     forward   C-tile += A-tile . B-tile     -> (Mt, Nt, Kt)
;;;     backward  dA-tile = dC-tile . B-tileT   -> (Mt, Kt, Nt)
;;;     backward  dB-tile = A-tileT . dC-tile   -> (Kt, Nt, Mt)
;;; Every requirement of the two backward GEMMs is already implied by the forward EXCEPT
;;; Kt % N_n (from dA) and Kt % M_n (from dB) — i.e. Kt % lcm(M_n, N_n) == 0, which is 16 on
;;; both supported profiles.  K_n is 8, so a DIFFERENTIABLE tile spans at least two native
;;; K-steps.
;;;
;;; But %emit-per-frag-accumulate fired exactly ONE native K-step per fragment position: it
;;; read its operands at a hardcoded K tile-index 0.  Every shipped forward kernel got away
;;; with that by staging Kt = K_n = 8 and running the K-loop externally.  Stage anything
;;; WIDER and the surplus was silently ignored — no error, no warning, a wrong answer.
;;; (Measured on BMG: an 8x16 A-tile emitted ONE MulAdd and the host reference said
;;; MMA_WRONG.)
;;;
;;; The K-step count is COMPILE-TIME (scratch tile dims are compile-time constants), so this
;;; is a pure unroll — no new syntax, no runtime cost, and one-K-step tiles expand exactly as
;;; before.
;;;
;;; Spec: tests/spec/145-mma-autodiff/05-multi-k-step-tile-bmg.crisp
;;; ===================================================================

;; src/mma.lisp
(defvar *mma-scratch-tile-dims* nil
  "Endeavor 145 P3a: alist (SYM ROWS COLS) of the SLM scratch tiles bound by the LET currently
   being exploded.  %emit-per-frag-accumulate reads it to learn a staged operand's K extent so it
   can walk K WITHIN the tile.  Bound by %explode-register-tiles; NIL elsewhere, in which case a
   staged operand is assumed to span exactly one native K-step (the pre-145 behaviour).

   A special variable rather than a threaded parameter so %explode-rewrite-body-form — which
   carries the endeavor-142 register block-load branches — does not have to change.")

;; src/mma.lisp
(defun %mma-scratch-tile-dims-from-bindings (bindings)
  "Endeavor 145 P3a: the (SYM ROWS COLS) dims of every compile-time-shaped
   (V (make-scratch-matrix <elem> (ROWS COLS))) binding in BINDINGS.

   Only literal integer 2-lists are recorded; a scratch tile whose shape is derived from another
   tensor contributes nothing and falls back to the one-K-step assumption."
  (loop for b in bindings
          when (and (consp b) (= (length b) 2) (symbolp (first b))
                    (consp (second b))
                    (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX")
                    (let ((d (third (second b))))
                      (and (listp d) (= (length d) 2) (every #'integerp d))))
        collect (list (first b)
                      (first (third (second b)))
                      (second (third (second b))))))

;; src/mma.lisp
(defun %mma-operand-extent (ref tiles which)
  "Endeavor 145 P3a: the compile-time extent (WHICH = :rows | :cols) of an
   mma-accumulate-via-tile operand REF, or NIL if not compile-time known.

   Handles both operand flavours: a register tile / ring slot (normalized to
   (V m n syms ...) by %resolve-tile-ref) and an SLM scratch tile (via
   *mma-scratch-tile-dims*)."
  (let ((rt (%resolve-tile-ref ref tiles)))
    (if rt
        (ecase which (:rows (second rt)) (:cols (third rt)))
        (let ((sd (and (symbolp ref) (assoc ref *mma-scratch-tile-dims*))))
          (when sd
            (ecase which (:rows (second sd)) (:cols (third sd))))))))

;; src/mma.lisp
(defun %mma-k-steps (a b tiles sk location)
  "Endeavor 145 P3a: how many native K-steps the staged operands span — A's COLUMN extent (Kt)
   divided by the instruction's K.  Defaults to 1 when the shape is not compile-time known,
   reproducing the pre-145 behaviour exactly.

   Also cross-checks the operands: A is Mt x Kt and B is Kt x Nt, so A's column extent must equal
   B's row extent.  Such a mismatch used to be silently truncated to one K-step; it is a hard error
   now, since it can only mean the staged tiles disagree about the contraction length."
  (let ((a-k (%mma-operand-extent a tiles :cols))
        (b-k (%mma-operand-extent b tiles :rows)))
    (when (and a-k b-k (/= a-k b-k))
      (error 'crisp-compiler-error
        :message (format nil "mma-accumulate-via-tile: operand K extents disagree — A is ~a wide but B is ~a tall.  A must be Mt x Kt and B must be Kt x Nt."
                         a-k b-k)
        :source-location location))
    (let ((kt (or a-k b-k)))
      (if (and kt (plusp sk)) (max 1 (floor kt sk)) 1))))

;; src/mma.lisp
;; Re-definition of the src/ original.  CHANGE: the operand readers take a K-step index, and a
;; fragment's accumulate is the compile-time SEQUENCE of its K-steps rather than one MMA at
;; K-index 0.
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is a
   static per-warp switch (n-true threaded to %emit-frag-loop-distributed).  Endeavor 142: when A/B
   are register-tiles (present in TILES, pre-loaded via load-tile), the operand is read from its
   pre-loaded fragment var instead of load-fragment-a/b.

   Endeavor 145 P3a: the staged operands may span SEVERAL native K-steps (Kt / K_n, compile-time)
   and every one of them now fires.  Previously only K-index 0 was emitted and any surplus staged
   data was silently dropped.  For the F3 body/accum-op API this means (accum-op) fires the
   fragment's WHOLE contraction — all of its K-steps — which keeps the promise that the body
   controls WHEN a fragment accumulates, not how its contraction is chopped up."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape)
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (nth (+ (* mi (max 1 (floor (third ta) sk))) ks) (fourth ta))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (nth (+ (* ks (max 1 (floor (third tb) sn))) nj) (fourth tb))
                           `(load-fragment-b ,b (,ks ,nj)))))
                   (one-frag (fv mi-form nj-form)
                     (let* ((sets (loop for ks below k-steps
                                        collect `(set! ,fv (mma-accumulate ,fv
                                                                           ,(a-operand mi-form ks)
                                                                           ,(b-operand nj-form ks)))))
                            (acc-set (if (= (length sets) 1) (first sets) `(progn ,@sets))))
                       (if body
                           (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                           (list acc-set)))))
            (if (> n-true 1)
                (progn
                  (when (or (%resolve-tile-ref a tiles) (%resolve-tile-ref b tiles))
                    (error 'crisp-compiler-error
                      :message "register-resident A/B operands are not yet supported with a warp-distributed accumulator (n-true > 1)."
                      :source-location nil))
                  (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))

;; src/mma.lisp
;; Re-definition of the src/ original.  CHANGE: one added LET* binding that makes the LET's
;; SLM scratch-tile shapes visible to %emit-per-frag-accumulate (145 P3a).  Because
;; *mma-scratch-tile-dims* is special, the LET* establishes a dynamic binding covering the
;; whole expansion, including the %explode-rewrite-body-form calls at the end.
(defun %explode-register-tiles (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range).
   Endeavor 145 P3a: also publishes the LET's SLM scratch-tile shapes in *mma-scratch-tile-dims* so
   the accumulate expansion can walk K within a staged tile."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             ;; 145 P3a: SLM tile shapes for the K-step count (special -> dynamically scoped).
             (*mma-scratch-tile-dims* (%mma-scratch-tile-dims-from-bindings bindings))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (let* ((form    (second b))
                                 (dims    (third form))
                                 (init    (fourth form))
                                 (m       (first dims)) (n (second dims))
                                 (operand (getf (nthcdr 4 form) :operand :acc))
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                            (* (floor m fr) (floor n fc))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location)
                                    (values 1 0))
                              (let* ((per-warp (floor nfrags n-true))
                                     (syms     (%register-tile-frag-syms (first b) per-warp)))
                                (push (list (first b) m n syms n-true first-true operand) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init :operand ,operand))))))
                          (if (and (consp b) (= (length b) 2) (symbolp (first b))
                                   (%register-tile-ring-init-form-p (second b)))
                              (let* ((form    (second b))
                                     (dims    (third form))
                                     (m       (first dims)) (n (second dims))
                                     (keys    (nthcdr 3 form))
                                     (operand (getf keys :operand :acc))
                                     (rc      (getf keys :ring-count)))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand)
                                  (let* ((nfrags (* (floor m fr) (floor n fc)))
                                         (slot-syms-list
                                           (loop for slot below rc
                                                 collect (%register-tile-frag-syms
                                                          (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                  (symbol-package (first b)))
                                                          nfrags))))
                                    (push (list (first b) :ring m n slot-syms-list operand) tiles)
                                    (loop for syms in slot-syms-list
                                          append (loop for s in syms
                                                       collect (list s `(make-register-fragment 16 8 0.0 :operand ,operand)))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3b: the tile-level backward rule.
;;;
;;; C-tile += A-tile . B-tile   =>   dA = dC . B^T   and   dB = A^T . dC
;;;
;;; Both backward GEMMs need one TRANSPOSED operand and the orientation is forced — the
;;; "transpose the output instead" reformulation fails the shape check on Intel (dA^T =
;;; B.dC^T is (Kt, Mt, Nt) and Mt=8 < N_n=16).  Rather than depend on ColumnMajor
;;; cooperative loads (BUG 035: :col-major is silently ignored on SPV), the transposed
;;; operands are STAGED into SLM explicitly, so every operand read is row-major and the
;;; emission is backend-neutral.
;;;
;;; A subtlety that shapes the whole design: the backward kernel replays the forward's
;;; BINDINGS but not its STATEMENTS, so the staged primal tiles (filled by load-tile-at)
;;; are EMPTY in the backward.  That would be fatal — dA needs B and dB needs A — except
;;; that both GEMMs need only the TRANSPOSES.  So the backward never reconstructs the
;;; primal tiles at all: it stages the transposes straight from the ORIGINAL GLOBAL source,
;;; recovered from the forward's load-tile-at forms.  Its origin expression is replayed
;;; verbatim, so a loop-dependent origin like (* kt 16) still resolves against the
;;; backward's own loop variable.
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-ad-walk-forms (tree fn)
  "Endeavor 145 P3b: apply FN to every cons subform of TREE, outermost first.

   The tile maps below MUST see the whole tree, not just the top level of flat-anf.
   `flatten-anf-body` flattens LET and PROGN but leaves a DOTIMES / IF / WHEN body NESTED —
   so in a K-looped matmul (the realistic shape) the load-tile-at forms live inside the loop
   and a top-level-only scan finds nothing."
  (labels ((walk (x)
             (when (consp x)
               (funcall fn x)
               (dolist (sub x) (walk sub)))))
    (walk tree)))

;; src/autodiff.lisp
(defun %mma-ad-tile-dims-map (flat-anf)
  "Endeavor 145 P3b: alist SYM -> (ROWS COLS) for every compile-time-shaped tile bound
   anywhere in FLAT-ANF — both `(V (make-register-tile T (M N) INIT))` and
   `(V (make-scratch-matrix T (R C)))`.

   The backward rule needs Mt/Nt from the accumulator tile and Kt from the A operand in
   order to size its own temporaries, and those shapes only exist at the source level."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-REGISTER-TILE" "MAKE-SCRATCH-MATRIX")
                          :test #'string=)
                  (let ((d (third (second form))))
                    (and (listp d) (= (length d) 2) (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (list (first form)
                     (first (third (second form)))
                     (second (third (second form))))
               acc))))
    (nreverse acc)))

;; src/autodiff.lisp
(defun %mma-ad-tile-source-map (flat-anf)
  "Endeavor 145 P3b: alist TILE-SYM -> (GLOBAL-SRC ORIGIN-FORMS) for every
   `(load-tile-at SRC TILE (ORIGIN...))` anywhere in FLAT-ANF.

   This is what lets the backward stage a TRANSPOSED operand without reconstructing the
   forward's staging: it reads the original global matrix at the same origin.  The origin
   forms are carried through verbatim, so a loop-dependent origin like (* kt 16) still
   resolves against the backward's own loop variable."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (>= (length form) 4) (symbolp (first form))
                  (string-equal (symbol-name (first form)) "LOAD-TILE-AT")
                  (symbolp (second form)) (symbolp (third form))
                  (listp (fourth form))
                  (not (assoc (third form) acc)))
         (push (list (third form) (second form) (fourth form)) acc))))
    (nreverse acc)))

;; src/autodiff.lisp
(defun %mma-ad-transposed-stage (dst src origin rows cols)
  "Endeavor 145 P3b: a workgroup-collective TRANSPOSING copy of the ROWS x COLS block of SRC
   at ORIGIN into DST (which is COLS x ROWS).

   Plain element moves via workgroup-stride — the same collective the scratch `fill-tile`
   uses — so it costs no MMA and needs no ColumnMajor support.  Emitted as source, so it
   lowers through the ordinary analyzer path on both backends."
  (let* ((cl-pkg (find-package :crisp-language))
         (ws  (intern "WORKGROUP-STRIDE" cl-pkg))
         (aref (intern "~" cl-pkg))
         (set! (intern "SET!" cl-pkg))
         (plus (intern "+" cl-pkg))
         (to-int (intern "TO-INT" cl-pkg))
         (i (intern "%MMA_BW_TI" cl-pkg))
         (j (intern "%MMA_BW_TJ" cl-pkg))
         (oy (first origin))
         (ox (second origin)))
    (declare (ignore rows cols))
    ;; Iterate DST's index space (COLS x ROWS): dst[j][i] = src[oy+i][ox+j].
    ;; Both addends are coerced to INT: the load-tile-at origin may be a ULONG expression
    ;; (extent arithmetic) while the collective's loop variables are INT, and `+` will not
    ;; mix the two.  Tile coordinates are small, so INT is the right common type — it is
    ;; also what the `~` accessor takes.
    (list ws dst (list j i)
          (list set! (list aref dst j i)
                (list aref src
                      (list plus (list to-int oy) (list to-int i))
                      (list plus (list to-int ox) (list to-int j)))))))

;; src/autodiff.lisp
(defun %mma-via-tile-backward (form dims-map src-map inputs outputs local-adj-fn kernel-pkg)
  "Endeavor 145 P3b: the backward for
   `(mma-accumulate-via-tile (M N K) C-TILE A-TILE B-TILE ...)`.

   Emits ONE nested LET holding the backward's temporaries and the two backward GEMMs:

       dC-slm (Mt x Nt) <- store-tile C-tile_ADJ      ; register accumulator -> SLM
       AT-slm (Kt x Mt) <- transposed stage of A's global source
       BT-slm (Nt x Kt) <- transposed stage of B's global source
         dA-reg (Mt x Kt) : mma-accumulate-via-tile  dA-reg  dC-slm  BT-slm
         dB-reg (Kt x Nt) : mma-accumulate-via-tile  dB-reg  AT-slm  dC-slm
       store-tile dA-reg -> A-tile_ADJ ;  store-tile dB-reg -> B-tile_ADJ

   From there the existing endeavor-111 machinery finishes the job: A-tile_ADJ / B-tile_ADJ
   are already auto-allocated, and %load-tile-at-bwd already scatters them into A_GRAD /
   B_GRAD.  Because the walk runs in reverse, this rule's emission lands BEFORE those
   scatters in the generated backward — which is the order the chain rule needs.

   ERRORS when a shape or a staging source is not compile-time recoverable.  It used to
   return NIL and let the caller fall through — but the walk's fallthrough DROPS the form,
   which hands back a silent ZERO gradient.  That is the same silent-wrong-answer class as
   the K-step bug P3a fixed, and it actually bit: a K-LOOPED matmul emitted a backward with
   no MMA in it at all, because the maps only scanned the top level of flat-anf and the
   loop body is nested.  Better to refuse to compile than to quietly return zeros."
  (destructuring-bind (shape c-tile a-tile b-tile &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((c-dims (assoc c-tile dims-map))
           (a-dims (assoc a-tile dims-map))
           (a-src  (assoc a-tile src-map))
           (b-src  (assoc b-tile src-map)))
      (log:debug "145 P3b via-tile bwd: c-tile=~a dims=~a | a-tile=~a dims=~a src=~a | b-tile=~a src=~a"
                 c-tile c-dims a-tile a-dims a-src b-tile b-src)
      (unless (and c-dims a-dims a-src b-src
                   (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        (error 'crisp-compiler-error
          :message (format nil "mma-accumulate-via-tile: cannot differentiate this tile multiply — ~a.  The backward needs the accumulator tile's (Mt Nt) and the A operand's Kt as COMPILE-TIME shapes, and needs each staged operand's originating global matrix (from its load-tile-at) so it can stage the transpose.  Give the tiles literal make-register-tile / make-scratch-matrix dimensions and stage both operands with load-tile-at."
                           (cond ((not c-dims) (format nil "the accumulator tile ~a has no compile-time (M N)" c-tile))
                                 ((not a-dims) (format nil "the A operand ~a has no compile-time shape" a-tile))
                                 ((not a-src)  (format nil "the A operand ~a was not staged by a load-tile-at" a-tile))
                                 (t            (format nil "the B operand ~a was not staged by a load-tile-at" b-tile))))
          :source-location nil))
      (when (and c-dims a-dims a-src b-src
                 (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        ;; INTERNAL INVARIANT (not a user-facing contract).  This function emits the MMA
        ;; lowering, which requires both backward accumulators (Mt x Kt and Kt x Nt) to
        ;; decompose into whole hardware fragments.  %vjp-mma-accumulate-via-tile has already
        ;; checked that via %mma-vjp-mma-admissible-p before routing here, so a violation means
        ;; the VJP dispatch is wrong, not the user's kernel.
        ;;
        ;; This USED to be a hard user-facing error called "the K-tile contract" — a claim that
        ;; a kernel with Kt=8 could not be differentiated at all.  That was wrong: dA = dC.B^T
        ;; and dB = A^T.dC hold at every shape, and only this LOWERING needs the dims to divide.
        ;; The condition now selects the scalar lowering instead.  See the retraction section in
        ;; tests/spec/145-mma-autodiff/mma-autodiff.md.
        (multiple-value-bind (sm sn sk) (%spv-mma-shape)
          (declare (ignore sk))
          (let ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims)))
            (unless (%mma-vjp-mma-admissible-p mt nt kt)
              (error 'crisp-compiler-error
                :message (format nil "INTERNAL: MMA backward lowering reached with a tile (Mt=~a Nt=~a Kt=~a) that does not decompose on shape (~a ~a) — the VJP should have selected the scalar lowering."
                                 mt nt kt sm sn)
                :source-location nil))))
        (let* ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims))
               (pkg (or kernel-pkg (symbol-package c-tile)))
               (cl-pkg (find-package :crisp-language))
               (nm (lambda (fmt sym) (intern (format nil fmt (symbol-name sym)) pkg)))
               (dc-slm (funcall nm "~A_BWDC"  c-tile))
               (at-slm (funcall nm "~A_BWT"   a-tile))
               (bt-slm (funcall nm "~A_BWT"   b-tile))
               (da-reg (funcall nm "~A_BWACC" a-tile))
               (db-reg (funcall nm "~A_BWACC" b-tile))
               (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj-fn kernel-pkg))
               (a-adj (%tlc-bwd-adj-name a-tile inputs outputs local-adj-fn kernel-pkg))
               (b-adj (%tlc-bwd-adj-name b-tile inputs outputs local-adj-fn kernel-pkg))
               (let-sym  (intern "LET" cl-pkg))
               (msm      (intern "MAKE-SCRATCH-MATRIX" cl-pkg))
               (mrt      (intern "MAKE-REGISTER-TILE" cl-pkg))
               (float-s  (intern "FLOAT" cl-pkg))
               (store-t  (intern "STORE-TILE" cl-pkg))
               (via      (intern "MMA-ACCUMULATE-VIA-TILE" cl-pkg))
               (sync     (intern "SYNC-WORKGROUP" cl-pkg)))
          `(,let-sym ((,dc-slm (,msm ,float-s (,mt ,nt)))
                      (,at-slm (,msm ,float-s (,kt ,mt)))
                      (,bt-slm (,msm ,float-s (,nt ,kt)))
                      (,da-reg (,mrt ,float-s (,mt ,kt) 0.0))
                      (,db-reg (,mrt ,float-s (,kt ,nt) 0.0)))
             ;; dC: the accumulator's adjoint, register -> SLM (so it can be an MMA operand).
             (,store-t ,c-adj ,dc-slm (0 0))
             ;; The transposed operands, staged from the ORIGINAL global sources.
             ,(%mma-ad-transposed-stage at-slm (second a-src) (third a-src) mt kt)
             ,(%mma-ad-transposed-stage bt-slm (second b-src) (third b-src) kt nt)
             (,sync)
             ;; dA = dC . B^T      (Mt, Kt, Nt)
             (,via ,shape ,da-reg ,dc-slm ,bt-slm)
             ;; dB = A^T . dC      (Kt, Nt, Mt)
             (,via ,shape ,db-reg ,at-slm ,dc-slm)
             (,sync)
             (,store-t ,da-reg ,a-adj (0 0))
             (,store-t ,db-reg ,b-adj (0 0)))))))
  )

;; src/autodiff.lisp
(defun %mma-via-tile-backward-logged (form dims-map src-map inputs outputs local-adj-fn kernel-pkg)
  "Endeavor 145 P3b: %mma-via-tile-backward plus a log of the emitted backward AST.
   The tile-level backward is the most intricate emission in the AD engine, and it is
   assembled from source forms that then go through the ordinary analyzer + SROA explosion —
   so seeing the pre-analysis AST is the single most useful debugging artifact when a
   backward fails to compile.  Run the compiler with --log-level=debug to see it."
  (let ((r (%mma-via-tile-backward form dims-map src-map inputs outputs local-adj-fn kernel-pkg)))
    (log:debug "145 P3b emitted backward AST:~%~s" r)
    r))

;; src/autodiff.lisp
(defun %mma-ad-adj-init (init-form)
  "Endeavor 145 P3b: the adjoint allocator paired with a forward tile binding.

   Scratch tiles keep the existing behaviour (%promote-scratch-init-for-ad, which also
   promotes e.g. ulong -> double).  A REGISTER tile gets a same-shaped register tile zeroed
   to 0.0 — fragments are fp32, and an adjoint always starts at zero."
  (if (and (consp init-form) (symbolp (car init-form))
           (string-equal (symbol-name (car init-form)) "MAKE-REGISTER-TILE"))
      (let ((cl-pkg (find-package :crisp-language)))
        (list (intern "MAKE-REGISTER-TILE" cl-pkg)
              (intern "FLOAT" cl-pkg)
              (third init-form)
              0.0))
      (%promote-scratch-init-for-ad init-form)))

;; src/autodiff.lisp
(defun %augment-scratch-adj-bindings (bindings kernel-pkg)
  "For each binding (var (make-scratch-X ...)), inject a paired (var_ADJ (make-scratch-X ...))
   binding right after.  For other bindings, pass through unchanged.  Promotes element type
   (e.g., ulong -> double) so gradients use correct FP precision.

   Endeavor 145 P3b: MAKE-REGISTER-TILE joins the list, so a register accumulator declared in
   a NESTED let gets its paired adjoint tile the same way a scratch tile does.  (A top-level
   register tile is handled by the scratch-adj-bindings collection in generate-backward-walk.)"
  (loop for b in bindings
          if (and (consp b) (= (length b) 2) (symbolp (car b))
                  (consp (cadr b)) (symbolp (caadr b))
                  (member (symbol-name (caadr b))
                          '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                            "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                            "MAKE-REGISTER-TILE")
                          :test #'string=))
          append (list b
                       (let* ((var (car b))
                              (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                               (or kernel-pkg (symbol-package var)))))
                         (list var-adj (%mma-ad-adj-init (cadr b)))))
          else collect b))

;; src/autodiff.lisp
(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.

   Endeavor 145 P1: INNER-DIMENSION / OUTER-DIMENSIONS are gradient-inert shape queries.
   Endeavor 145 P3b: MAKE-REGISTER-TILE is an ALLOCATOR, gradient-inert like the
   make-scratch-* constructors above it — its paired adjoint tile is created by
   %mma-ad-adj-init, not by the walk."
  (or (let ((name (symbol-name fn-sym)))
        (member name '("MAKE-REGISTER-TILE") :test #'string=))
      (%backward-skip-fn-p-145p1 fn-sym)))

;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   Phase 1c: adds LOAD-TILE-AT / STORE-TILE-AT clauses to process-form
   that emit %load-tile-at-bwd / %store-tile-at-bwd with the correct
   adjoint symbols.  Also extends the LET case to auto-allocate paired
   <var>_ADJ scratch tensors for make-scratch-* bindings.

   Bug 032 fix: SET! on a local-scratch tile (target neither input nor
   output) now emits a proper consume + reset pair so the RHS chain rule
   propagates through tile mutations."
  (let* ((record-temp-entries
          (loop for form in flat-anf
                  when (and (consp form) (= (length form) 2)
                            (symbolp (car form))
                            (consp (cadr form))
                            (symbolp (caadr form))
                            (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                  (let* ((temp-sym (car form))
                         (expr (cadr form))
                         (record-name (second expr))
                         (pkg (or kernel-pkg (symbol-package temp-sym))))
                    (when (or (%crisp-record-type-p record-name)
                              (%crisp-struct-type-p record-name))
                          (let* ((fields (%get-record-runtime-fields record-name))
                                 (field-alist
                                  (loop for (fname ftype) in fields
                                        collect (cons (symbol-name fname)
                                                      (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                              pkg)))))
                            (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (let ((ht (when (or record-temp-entries *record-param-field-adjs*)
                          (make-hash-table :test 'eq))))
            (when ht
                  (when *record-param-field-adjs*
                        (maphash (lambda (k v) (setf (gethash k ht) v))
                                 *record-param-field-adjs*))
                  (dolist (entry record-temp-entries)
                    (setf (gethash (car entry) ht) (cdr entry))))
            ht)))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht)
          ;; Endeavor 123 (FFI-AD): map each pointer temp bound via
          ;; (t (base-ptr~ src)) to its source storage sym, so a foreign call's
          ;; pointer arg can route its shadow to <src>_GRAD.
          (*ffi-baseptr-src*
           (let ((ht (make-hash-table :test 'eq)))
             (loop for form in flat-anf
                     when (and (consp form) (= (length form) 2)
                               (symbolp (car form))
                               (consp (cadr form)) (symbolp (caadr form))
                               (string-equal (symbol-name (caadr form)) "BASE-PTR~")
                               (symbolp (second (cadr form))))
                   do (setf (gethash (car form) ht) (second (cadr form))))
             ht)))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym in inputs
                     for typ in input-types
                       when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht))
            ;; Bug 032: collect locally-bound scratch tile syms (those
            ;; bound via make-scratch-vector / -matrix / -tensor / -cell
            ;; anywhere in flat-anf) so the `~` and SET! backward cases
            ;; can route indexed accesses on them to their _ADJ tensor
            ;; instead of polluting the scalar adjoint-map.
            (scratch-tile-syms
             (let ((ht (make-hash-table :test 'eq)))
               (loop for form in flat-anf
                       when (and (consp form) (= (length form) 2)
                                 (symbolp (car form))
                                 (consp (cadr form)) (symbolp (caadr form))
                                 (member (symbol-name (caadr form))
                                         '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                                                 "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                                         :test #'string=))
                     do (setf (gethash (car form) ht) t))
               ht)))
        ;; BUG 037: publish the staged-tile -> global-source map and the scratch-tile set so the
        ;; primal replay can read a staged tile's values from where they actually came from.
        (setf *ad-tile-src-map* (%mma-ad-tile-source-map flat-anf)
              *ad-scratch-syms* scratch-tile-syms)
        ;; Endeavor 124 C/A2: the adjoint-typing decision now lives in one place
        ;; (%ad-promotes-to-double-p / %ad-zero) shared with the sub-fn, FFI and
        ;; value-if/let paths.
        (flet ((promotes-to-double-p (t-spec) (%ad-promotes-to-double-p t-spec)))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (*ad-any-output-double* any-output-double)
                 (intermediate-zero (%ad-zero any-output-double)))
            (labels ((local-adj (v)
                                (or (gethash v adjoint-map)
                                    (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                                       (or kernel-pkg (symbol-package v)))))
                                      (setf (gethash v adjoint-map) adv)
                                      adv)))
                     (emit (form)
                           (push form backward-forms))
                     (hof-inline-backward (fn args v)
                                          (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                                            (unless hof-data
                                              (error "HOF ~A not found in *differentiable-hof-store*" fn))
                                            (let* ((param-syms (getf hof-data :param-syms))
                                                   (fn-param-idx (getf hof-data :fn-param-idx))
                                                   (body-forms (getf hof-data :body-forms))
                                                   (fn-arg (nth fn-param-idx args))
                                                   (concrete-fn (cond
                                                                 ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                                   (cadr fn-arg))
                                                                 ((symbolp fn-arg) fn-arg)
                                                                 (t nil))))
                                              (unless concrete-fn
                                                (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                                              (let* ((fn-param (nth fn-param-idx param-syms))
                                                     (subst-alist
                                                      (loop for p in param-syms
                                                            for a in args
                                                            for i from 0
                                                              unless (= i fn-param-idx)
                                                            collect (cons p a)))
                                                     (subst-body (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                                     (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                                        subst-body))
                                                     (anf-body (mapcar #'anf-transform concrete-body))
                                                     (hof-flat (flatten-anf-body anf-body))
                                                     (hof-flat-norm
                                                      (let ((last-f (car (last hof-flat))))
                                                        (if (or (symbolp last-f)
                                                                (and (consp last-f) (eq (first last-f) 'return)))
                                                            hof-flat
                                                            (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                                   (symbol-package v))))
                                                              (append (butlast hof-flat)
                                                                (list (list ret-sym last-f) ret-sym))))))
                                                     (return-vars (%extract-return-vars hof-flat-norm)))
                                                (dolist (rv return-vars)
                                                  (setf (gethash rv adjoint-map) (local-adj v)))
                                                (dolist (hf-form (reverse hof-flat-norm))
                                                  (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                                        (let ((hv (car hf-form))
                                                              (hexpr (cadr hf-form)))
                                                          (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                                         :hof-handler-fn #'hof-inline-backward
                                                                                         :error-on-unknown t
                                                                                         :tensor-inputs-ht nil
                                                                                         :scratch-tile-syms scratch-tile-syms))))))))
                     (process-form (form emit-fn)
                       ;; VJP REGISTRY DISPATCH (see the registry block in this overlay).
                       ;; Runs BEFORE the hand-written clauses and DECLINES (NIL) when nothing
                       ;; applies, so an empty registry is provably a no-op and migration can
                       ;; proceed one primitive at a time.
                       (let* ((%vjp-binding (when (and (consp form) (= (length form) 2)
                                                       (symbolp (car form)) (consp (cadr form)))
                                              (car form)))
                              (%vjp-target (if %vjp-binding (cadr form) form))
                              (%vjp (%try-vjp %vjp-target
                                             (list :flat-anf flat-anf
                                                   :inputs inputs
                                                   :outputs outputs
                                                   :local-adj #'local-adj
                                                   :binding-var %vjp-binding
                                                   :kernel-pkg kernel-pkg))))
                        (if %vjp
                            (unless (eq %vjp :inert) (funcall emit-fn %vjp))
                            (cond
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "DECLARE")) nil)

                                    ;; Endeavor 145 P8: a tile load/store in VALUE position.
                                    ;; ANF binds a compound form to a temp whenever it sits in
                                    ;; value position — and the epilogue of
                                    ;; matrix-multiply-tile-stride ends with
                                    ;; `(store-tile C-tile C (grid-y grid-x))`, so a
                                    ;; multi-workgroup matmul reaches the walk as
                                    ;; `(%t (store-tile-at ...))` rather than a bare statement.
                                    ;; Every tile-load/store rule below matches only the
                                    ;; STATEMENT shape, so the binding fell through to
                                    ;; %handle-single-value-backward and errored with
                                    ;; "Function STORE-TILE-AT is not differentiable".
                                    ;; These forms are void — their "value" is meaningless — so
                                    ;; unwrap the temp and re-dispatch as the statement it is.
                                    ;; Fixes the register-tile AND scratch paths uniformly.
                                    ((and (consp form) (= (length form) 2) (symbolp (car form))
                                          (consp (cadr form)) (symbolp (caadr form))
                                          (member (symbol-name (caadr form))
                                                  ;; All VOID forms.  make-register-tile is
                                                  ;; deliberately absent — that one really is a
                                                  ;; value binding and must keep its temp.
                                                  '("STORE-TILE-AT" "LOAD-TILE-AT"
                                                    "STORE-TILE" "LOAD-TILE"
                                                    "MMA-ACCUMULATE-VIA-TILE" "STORE-FRAGMENT")
                                                  :test #'string=))
                                      (process-form (cadr form) emit-fn))

                                    ;; Endeavor 145 P3b: the tile-level MMA backward.
                                    ;; C-tile += A-tile . B-tile  =>  dA = dC.B^T, dB = A^T.dC.
                                    ;; Falls through to the old silent-drop only when the
                                    ;; shapes / staging sources are not compile-time
                                    ;; recoverable, so a kernel we cannot differentiate
                                    ;; correctly is never given a bogus gradient.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form))
                                                        "MMA-ACCUMULATE-VIA-TILE")
                                          (>= (length form) 5))
                                      (let ((bwd (%mma-via-tile-backward-logged
                                                  form
                                                  (%mma-ad-tile-dims-map flat-anf)
                                                  (%mma-ad-tile-source-map flat-anf)
                                                  inputs outputs #'local-adj kernel-pkg)))
                                        (when bwd (funcall emit-fn bwd))))

                                    ;; Phase 1c: load-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "LOAD-TILE-AT"))
                                      (let* ((src (second form))
                                             (tile (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (src-adj (%tlc-bwd-adj-name src inputs outputs
                                                                         #'local-adj kernel-pkg))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-TILE-AT-BWD"
                                                              (find-package :crisp-language)))
                                             (bwd-form (if transpose-v
                                                           (list bwd-sym src-adj tile-adj origins :transpose transpose-v)
                                                           (list bwd-sym src-adj tile-adj origins))))
                                        (funcall emit-fn bwd-form)))

                                    ;; Endeavor 145 P3b: a REGISTER-tile store.  Must be caught
                                    ;; BEFORE the scratch-tensor rule below, which would emit
                                    ;; %STORE-TILE-AT-BWD against an adjoint whose name is about
                                    ;; to be SROA-exploded away.  The backward of "write the
                                    ;; accumulator out to C" is "seed the accumulator's adjoint
                                    ;; from C_GRAD", fragment by fragment.  The origin coords are
                                    ;; unscaled first: the store-tile macro multiplied the tile-ID
                                    ;; by (~ (extents~ TILE) i), which is meaningless for a
                                    ;; register tile — the tile-ID inside is what we want.
                                    ((and (consp form) (symbolp (car form))
                                          (or (string-equal (symbol-name (car form)) "STORE-TILE-AT")
                                              (string-equal (symbol-name (car form)) "STORE-TILE"))
                                          (%mma-ad-register-tile-p (second form) flat-anf))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (mapcar #'%mma-ad-unscale-tile-origin
                                                              (fourth form)))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-REGISTER-TILE-ACC"
                                                              (find-package :crisp-language))))
                                        (log:debug "145 P3b register-tile store bwd: ~a <- ~a origins=~a"
                                                   tile-adj dest-adj origins)
                                        (funcall emit-fn (list bwd-sym tile-adj dest-adj origins))))

                                    ;; Phase 1c: store-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "STORE-TILE-AT"))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%STORE-TILE-AT-BWD"
                                                              (find-package :crisp-language)))
                                             (bwd-form (if transpose-v
                                                           (list bwd-sym tile-adj dest-adj origins :transpose transpose-v)
                                                           (list bwd-sym tile-adj dest-adj origins))))
                                        (funcall emit-fn bwd-form)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "SET!"))
                                      (%gfw-process-set! form emit-fn #'local-adj inputs outputs scratch-tile-syms intermediate-zero kernel-pkg))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "LET"))
                                      (let* ((bindings (cadr form))
                                             (augmented-bindings (%augment-scratch-adj-bindings bindings kernel-pkg))
                                             (body (cddr form)))
                                        (%gfw-process-let form emit-fn #'process-form bindings augmented-bindings body)))

                                    ((and (consp form) (symbolp (car form))
                                          (or (string-equal (symbol-name (car form)) "DOTIMES")
                                              (string-equal (symbol-name (car form)) "DOTIMES+")))
                                      (let* ((binding (cadr form))
                                             (body (cddr form))
                                             (local-vars (%collect-locally-bound-vars body)))
                                        (%gfw-process-dotimes form emit-fn #'process-form binding body local-vars adjoint-map intermediate-zero)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "IF"))
                                      (let* ((cond-form (cadr form))
                                             (then-form (caddr form))
                                             (else-form (cadddr form)))
                                        (%gfw-process-if form emit-fn #'process-form cond-form then-form else-form)))

                                    ;; Bug 032 fix part 2: WHEN and UNLESS were not handled
                                    ;; by the AD walker, so any forms inside them (including
                                    ;; the load/store-tile-at inner body's set!s after
                                    ;; workgroup-stride expansion) were silently dropped.
                                    ;; Desugar them to IF + PROGN here and let the IF case
                                    ;; handle the rest.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "WHEN"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        (process-form (list if-sym cond-form then 'nil) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "UNLESS"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        ;; (unless C B) = (if C nil B) — pass B as the else slot.
                                        (process-form (list if-sym cond-form 'nil then) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "PROGN"))
                                      (dolist (sub (reverse (cdr form)))
                                        (process-form sub emit-fn)))

                                    ;; Endeavor 123 (FFI-AD): a foreign function called as a
                                    ;; VOID STATEMENT (=> nil), e.g. (c_vsin n inptr outptr).
                                    ;; It is not a value binding, so it must be recognized by
                                    ;; its head being a registered foreign function — otherwise
                                    ;; it is misparsed as a multi-value binding below and
                                    ;; silently dropped. There is no return seed (void).
                                    ((and (consp form) (symbolp (car form))
                                          (let ((info (gethash (car form) *differentiable-functions*)))
                                            (and info (getf info :foreign))))
                                      (%emit-foreign-backward (car form) (cdr form) nil
                                                              (symbol-package (car form))
                                                              emit-fn #'local-adj))

                                    ;; BUG 038: an ordinary differentiable SUB-FUNCTION called as
                                    ;; a VOID STATEMENT, e.g. (stage A tile) or (scale_into A C).
                                    ;; Endeavor 123 added the clause above for the FOREIGN case
                                    ;; and for exactly this reason; the non-foreign case never
                                    ;; got one, so such a call fell through to the multi-value
                                    ;; BINDING clause below — `(STAGE A TILE)` is length 3 with an
                                    ;; all-symbol butlast, so that clause read STAGE and A as
                                    ;; bound variables and TILE as the producing expression.  TILE
                                    ;; is a symbol rather than a cons, so its body never ran and
                                    ;; the call was SILENTLY DROPPED — no gradient flowed through
                                    ;; the sub-function at all (137/04's backward had zero global
                                    ;; writes).  Statements and multi-value bindings are
                                    ;; indistinguishable by shape after ANF, which is the same
                                    ;; trap as the 145 P1 replay bug.
                                    ;;
                                    ;; Void, so there is no return seed: t-adj-forms is NIL, as in
                                    ;; the foreign case.  Handle (tensor) contributions are routed
                                    ;; by %emit-sub-fn-backward through the callee's &out
                                    ;; grad-handles, so the chain rule lands inside the sub-fn.
                                    ;; A binding never matches here: its CAR is the bound temp,
                                    ;; not a registered function.
                                    ;; The second disjunct matters: a sub-function whose companion
                                    ;; could not be built has been UNREGISTERED, so the gethash
                                    ;; alone would miss it and the call would be dropped exactly
                                    ;; as before.  A retained body is sufficient on its own.
                                    ((and (consp form) (symbolp (car form))
                                          (or (let ((info (gethash (car form) *differentiable-functions*)))
                                                (and info (not (getf info :foreign))))
                                              (%ad-sub-fn-inlinable-p (car form))))
                                      (let* ((fn (car form))
                                             (info (gethash fn *differentiable-functions*)))
                                        (log:debug "038: void sub-fn call backward for ~a" fn)
                                        ;; Prefer INLINING the callee's body: it needs no
                                        ;; companion, so it is immune to every way companion
                                        ;; generation can quietly decline, and it gives the
                                        ;; body's statements (load-tile above all) the same
                                        ;; treatment they would get in a kernel.  Fall back to
                                        ;; the companion when there is no body to inline —
                                        ;; notably FFI, and recursion.
                                        (unless (%ad-inline-sub-fn-backward fn (cdr form)
                                                                            emit-fn #'process-form)
                                          (%emit-sub-fn-backward fn (cdr form)
                                                                 (getf info :bkwd-name)
                                                                 nil
                                                                 (getf info :n-float-params)
                                                                 (symbol-package fn)
                                                                 emit-fn #'local-adj "BW"))))

                                    ((and (listp form) (= (length form) 2) (symbolp (car form)))
                                      (%handle-single-value-backward (car form) (cadr form)
                                                                     adjoint-map emit-fn #'local-adj
                                                                     :hof-handler-fn #'hof-inline-backward
                                                                     :error-on-unknown t
                                                                     :tensor-inputs-ht tensor-inputs-ht
                                                                     :scratch-tile-syms scratch-tile-syms))

                                    ((and (listp form) (>= (length form) 3)
                                          (symbolp (car form))
                                          (every #'symbolp (butlast form)))
                                      (let* ((result-vars (butlast form))
                                             (expr (car (last form))))
                                        (when (and (consp expr)
                                                   (symbolp (car expr))
                                                   (gethash (car expr) *differentiable-functions*))
                                              (let* ((fn (car expr))
                                                     (args (cdr expr))
                                                     (info (gethash fn *differentiable-functions*))
                                                     (bkwd (getf info :bkwd-name))
                                                     (n-fp (getf info :n-float-params))
                                                     (pkg (symbol-package (car result-vars)))
                                                     (t-adjs (mapcar #'local-adj result-vars)))
                                                ;; Endeavor 123 (FFI-AD): foreign multi-return
                                                ;; routes through the shadow-aware emitter.
                                                (if (getf info :foreign)
                                                    (%emit-foreign-backward fn args t-adjs pkg
                                                                            emit-fn #'local-adj)
                                                    (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                                           emit-fn #'local-adj "BW"))))))

                                    (t nil))))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
                                              (or kernel-pkg (symbol-package in))))
                             (canon-type (canonicalize-type-specifier
                                          (if (listp in-type) in-type (list in-type))))
                             (is-cell-input
                              (and (consp canon-type)
                                   (string-equal (symbol-name (first canon-type)) "CELL")))
                             (is-tensor-input
                              (or (%crisp-float-tensor-type-p in-type)
                                  (%crisp-integer-tensor-type-p in-type)))
                             (is-scalar-wrapped
                              (and (not is-cell-input) (not is-tensor-input)
                                   (or (%crisp-integer-scalar-type-p in-type)
                                       (%crisp-float-type-p in-type)))))
                        ;; Endeavor 124 (AD issues) C: under any-output-double the
                        ;; adjoint runs in double, but a float/small-int input's grad
                        ;; cell is float — down-cast at the write to match the cell.
                        (let ((write-val
                               (if (and any-output-double
                                        (not (promotes-to-double-p in-type))
                                        (or is-cell-input is-scalar-wrapped))
                                   `(to-float ,(local-adj in))
                                   (local-adj in))))
                          (cond
                           (is-tensor-input nil)
                           (is-cell-input (emit `(set! (~ ,in-grad) ,write-val)))
                           (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,write-val)))
                           (t (emit `(set! ,in-grad ,write-val)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          ;; Endeavor 124 (AD issues) C: when ANY output promotes to
                          ;; double, the whole backward chain runs in double — INCLUDING
                          ;; float-input adjoints — so the adjoint accumulations don't mix
                          ;; float and double. The narrower grad cell is reconciled by a
                          ;; down-cast at the grad-cell write below.
                          (cond
                           (in-type
                             (%ad-zero (or (promotes-to-double-p in-type) any-output-double)))
                           (any-output-double (%ad-zero t))
                           (t (%ad-zero nil))))))
                     (local-bindings (loop for v being the hash-keys of adjoint-map
                                           using (hash-value adv)
                                           collect `(,adv ,(funcall typed-zero-for v))))
                     ;; Phase 1c: auto-allocate <var>_ADJ paired scratch
                     ;; tensors for each make-scratch-* binding in flat-anf.
                     ;; The forward let-bindings already give us <var>; the
                     ;; backward wants both <var> and <var>_ADJ.
                     ;; Phase 1c initial: assumes same element-type (no
                     ;; ulong→double promotion yet; defer to a sub-step).
                     (scratch-adj-bindings
                      (loop for form in flat-anf
                              when (and (consp form) (= (length form) 2)
                                        (symbolp (car form))
                                        (consp (cadr form)) (symbolp (caadr form))
                                        (member (symbol-name (caadr form))
                                                '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                                                        "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                                                                        "MAKE-REGISTER-TILE")
                                                :test #'string=))
                            collect (let* ((var (car form))
                                           (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                                            (or kernel-pkg (symbol-package var)))))
                                      (list var-adj (%mma-ad-adj-init (cadr form))))))
                     (result `(let ,(append scratch-adj-bindings local-bindings)
                                ,@(nreverse backward-forms))))
                (log:debug "145: assembled backward AST:~%~s" result)
                result))))))))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3b part 2: seeding a register accumulator from
;;; the output gradient.
;;;
;;; ROOT CAUSE this solves.  `store-tile` is a CL defmacro that scales tile-IDs by the
;;; tile's extents and expands to `store-tile-at`.  On the FORWARD path that expansion
;;; never happens — STORE-TILE has its own expression analyzer (analyze-store-tile-mma)
;;; and the SROA explosion matches the un-expanded form.  But the AD path runs ANF first,
;;; and anf-normalize (src/anf-transform.lisp:174) macroexpands ANY symbol carrying a
;;; macro-function before it reaches its own opaque-passthrough list — which DOES name
;;; "STORE-TILE" (line 187), so the intent was already there; the expansion just fires
;;; first and the entry is unreachable.
;;;
;;; The result for a REGISTER tile is nonsense in two ways: the coords become
;;; `(* (to-ulong G) (~ (extents~ C-tile) i))` and a register tile has no extents~, and
;;; the walk's scratch-tensor rule then emits %STORE-TILE-AT-BWD against C-TILE_ADJ,
;;; whose name no longer exists once the adjoint tile is SROA-exploded ("Unknown variable
;;; C-TILE_ADJ").
;;;
;;; FIXED IN THE WALK, NOT IN anf-normalize.  Removing STORE-TILE from that macroexpansion
;;; would change flat-anf for every SCRATCH-tile kernel that uses the sugar, and those rely
;;; on STORE-TILE-AT reaching the endeavor-111 rules — a silent gradient regression.  So the
;;; walk instead detects a register-tile store and recovers the original tile-IDs by
;;; unwrapping the scaling the macro applied.
;;; ===================================================================

;; src/mma.lisp
(defun %emit-per-frag-acc-load (src tile-id entry)
  "Endeavor 145 P3b: per-fragment expansion of
   (%load-register-tile-acc TILE SRC (TY TX)) — the exact mirror of %emit-per-frag-store,
   reading each accumulator fragment back out of SRC with P2's load-fragment-acc instead of
   writing it.  This is where the fragment element->lane MAPPING finally becomes
   load-bearing: the seeded gradient is non-zero, so a wrong mapping changes the answer
   (unlike the zero-seed of P2's own spec)."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn)
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(set! ,fv (load-fragment-acc ,src
                                                     ((+ (* ,bty ,m-frags) ,mi-form)
                                                      (+ (* ,btx ,n-frags) ,nj-form)))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

;; src/autodiff.lisp
(defun %mma-ad-register-tile-p (sym flat-anf)
  "Endeavor 145 P3b: T when SYM is bound in FLAT-ANF by a make-register-tile constructor.
   Distinguishes a register accumulator tile from an SLM scratch tile, which the AD walk
   must treat completely differently at a store."
  (and (symbolp sym)
       (loop for form in flat-anf
               thereis (and (consp form) (= (length form) 2)
                            (eq (first form) sym)
                            (consp (second form)) (symbolp (first (second form)))
                            (string-equal (symbol-name (first (second form)))
                                          "MAKE-REGISTER-TILE")))))

;; src/autodiff.lisp
(defun %mma-ad-unscale-tile-origin (origin)
  "Endeavor 145 P3b: recover the original tile-ID G from the coordinate the `store-tile`
   macro produced, `(* (to-ulong G) (~ (extents~ TILE) i))`.

   A register tile has no extents~, so that scaled coordinate is meaningless for it — but
   the tile-ID inside is exactly what the register store/load path wants.  Anything that
   does not match the shape is returned unchanged, so an already-absolute coordinate still
   works."
  (if (and (consp origin) (= (length origin) 3)
           (symbolp (first origin)) (string-equal (symbol-name (first origin)) "*")
           (consp (second origin)) (symbolp (first (second origin)))
           (string-equal (symbol-name (first (second origin))) "TO-ULONG"))
      (second (second origin))
      origin))

;; src/mma.lisp
;; Re-definition of the src/ original.  CHANGE: one added clause for %load-register-tile-acc.
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile references
   to any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;
   otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ;; Endeavor 145 P3b: (%load-register-tile-acc TILE SRC (TY TX)) — the inverse of the
    ;; store-tile clause above, and the only way to get a global matrix INTO a register
    ;; accumulator tile.  Emitted by the AD walk to seed C-tile_ADJ from C_GRAD.  Compiler-
    ;; internal (leading %), so it is gradient-inert to the backward walk by construction.
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ;; Endeavor 142 (Intel MMA prefetch): load-tile with a register-tile DEST (third form) -> Intel
    ;; block-load (Subgroup2DBlockLoadINTEL, global -> GRF, hardware-scoreboard async, no :barrier).
    ;; Handled in the explosion (like store-tile), before the whole-tile var is gone.  The tile's
    ;; :operand (A/B) picks the coop-matrix Use/layout.  Requires the SPV/Intel target + an active
    ;; hardware profile (its GRF/L1 limits drive the Phase-C register-pipeline safety analysis);
    ;; PTX has no mapping for this register-pipeline model.
    ;; Endeavor 142: the DEST may be a bare register-tile OR (ring-get RING SLOT) into a register ring —
    ;; %resolve-tile-ref handles both (and errors on a non-constant register-ring slot).
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))


;; src/autodiff.lisp
;; Re-definition of the src/ original.  CHANGE: one added clause giving the fragment-level
;; MMA forms an actionable error instead of the generic "not differentiable" advice.
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
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
   ;; Endeavor 145 P3c: the FRAGMENT-level MMA forms are forward-only by construction, and
   ;; the generic "not differentiable" message sends users toward `forward-only`, which is
   ;; the wrong advice — the operation IS differentiable, just at a different altitude.
   ;; Explain that instead.  (See mma-autodiff.md: on a single fragment M/N/K are the native
   ;; shape, so dA=(M,K,N) and dB=(K,N,M), and on either vendor exactly one of the two fails
   ;; the shape check — NVIDIA (16 8 8) fails dB, Intel (8 16 8) fails dA.  A non-MMA
   ;; fragment backward is no better: it contracts over an index that spans lanes.)
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr))
                 '("MMA-ACCUMULATE" "LOAD-FRAGMENT-A" "LOAD-FRAGMENT-B"
                   "LOAD-FRAGMENT-ACC" "STORE-FRAGMENT" "MAKE-REGISTER-FRAGMENT")
                 :test #'string=))
     (when error-on-unknown
       (error "~A is a FRAGMENT-level MMA form and has no backward: on a single fragment one of the two backward GEMMs (dA = dC.B^T, dB = A^T.dC) always violates the hardware shape contract.  Autodiff of MMA is supported at the TILE level -- express the multiply with mma-accumulate-via-tile over a register tile whose K spans at least lcm(M_n,N_n) (16 on both current profiles).  If this kernel really is forward-only, use the spec directive SKIP-WITH[--differentiate] or a (declare forward-only)."
              (car expr))))
   ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
           (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
   (t nil)))

;;; ===================================================================
;;; BUG 036 — matrix-multiply-tile-stride must reset the C-tile per OUTPUT TILE.
;;;
;;; %mmts-lower emitted  (tile-stride C <spec> (gy gx) (dotimes (gk ...) BODY) EPILOGUE)
;;; with nothing re-initialising the accumulator between tiles.  The register C-tile is
;;; initialised ONCE by its make-register-tile binding OUTSIDE the loop, so a workgroup that
;;; visits a second output tile keeps the first tile's partial sums and adds the new tile's
;;; contribution on top.  Measured on BMG with the SHIPPED 135/04 spec, widened to a 2-tile C:
;;; C[0][16]=60 against a reference of 30.  Invisible until now because every shipped spec
;;; uses exactly ONE output tile, so the stride body runs once.
;;;
;;; The requirement was already KNOWN: the scratch-C-tile spec 135/02-matmul-grid-stride does
;;; it by hand — `(when (= grid-k 0) (fill-tile C-tile 0.0))  ; reset accumulator at the start
;;; of each tile`.  The macro simply never provided it, so the register specs omitted it.
;;; Owning the tile-stride + K-loop bookkeeping is the macro's whole job, so it owns this too.
;;;
;;; RESET VALUE — a register tile resets to its DECLARED INIT, not to 0.0.  That makes
;;; multi-tile behave exactly like single-tile, which is what a bug fix should do; hardcoding
;;; 0.0 would silently change semantics for a non-zero init (endeavor 132's F3 accum-op API
;;; makes a bias-valued init a real use).  A SCRATCH C-tile has no declared init
;;; (make-scratch-matrix takes none), so it resets to 0.0.
;;;
;;; BARRIER — fill-tile on a scratch tile is a workgroup-COLLECTIVE write and its docstring is
;;; explicit that it inserts no barrier ("the caller syncs before reading").  The macro is that
;;; caller, so the scratch path gets a sync-workgroup after the fill.  The register path needs
;;; none: each lane owns its own fragments.
;;; ===================================================================

;; src/mma.lisp
(defun %mmts-register-dims-map (bindings)
  "Alist var -> ((M N) INIT) for each register-tile binding in a let's BINDINGS.
   BUG 036: now carries the declared INIT as well as the dims, so the lowering can reset each
   output tile to the value the user actually asked for."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          ;; (make-register-tile elem (M N) INIT &key ...)
          collect (list (first b) (third (second b)) (fourth (second b)))))

;; src/analysis/control.lisp
(defun %mmts-lower (c-form c-tile tile-spec k-form k-step grid-y grid-x grid-k body location
                    &optional (reset-value 0.0))
  "The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop.  Endeavor 137: NO
   auto-store — the body's :epilogue section (post-reduction, per tile) holds the explicit
   store + any fusion.  Warns if the C-tile is never stored.

   BUG 036: emits a per-OUTPUT-TILE reset of the accumulator to RESET-VALUE before the K-loop.
   Without it a workgroup that strides onto a second tile carries the first tile's partial sums.
   A scratch C-tile's fill is workgroup-collective, so it is followed by a sync-workgroup; a
   register tile's is per-lane and needs none."
  (declare (ignore location))
  (multiple-value-bind (reduction-body epilogue-body) (%mmts-split-epilogue body)
    (unless (%form-tree-mentions-store-tile-p epilogue-body)
      (format *error-output*
        "WARNING: matrix-multiply-tile-stride: the C-tile is computed but never stored — add an :epilogue with (store-tile ~a ~a (~a ~a)).~%"
        (if (symbolp c-tile) c-tile 'C-tile) (if (symbolp c-form) c-form 'C) grid-y grid-x))
    (let* ((cl-pkg          (find-package :crisp-language))
           (tile-stride-sym (intern "TILE-STRIDE" cl-pkg))
           (dotimes-sym     (intern "DOTIMES" cl-pkg))
           (div-sym         (intern "/" cl-pkg))
           (to-ulong-sym    (intern "TO-ULONG" cl-pkg))
           (fill-sym        (intern "FILL-TILE" cl-pkg))
           (sync-sym        (intern "SYNC-WORKGROUP" cl-pkg))
           ;; A register tile's spec is the compile-time (M N) size list; a scratch tile's is
           ;; the tile tensor itself.
           (register-p      (and (listp tile-spec) tile-spec (every #'integerp tile-spec)))
           ;; REGISTER TILES ONLY.  A scratch C-tile is deliberately left alone: endeavor 135
           ;; documented that contract in 135/01-macro-envelope — "The macro does NOT auto-reset
           ;; a scratch C-tile — the user owns init" — and 135/02 duly resets by hand.  The
           ;; measured bug was a REGISTER tile, whose init lives in a make-register-tile binding
           ;; OUTSIDE the loop where the user cannot reach it per-tile; that asymmetry is exactly
           ;; why the register path needs the macro to own the reset and the scratch path does
           ;; not.  (sync-sym is retained for the scratch path should that contract ever change;
           ;; a collective fill would need it.)
           (reset-forms     (when register-p
                              (list (list fill-sym c-tile reset-value)))))
      (declare (ignorable sync-sym))
      (append (list tile-stride-sym c-form tile-spec (list grid-y grid-x))
              reset-forms
              (list (list* dotimes-sym
                           (list grid-k
                                 (list div-sym (list to-ulong-sym k-form) (list to-ulong-sym k-step)))
                           reduction-body))
              epilogue-body))))

;; src/mma.lisp
(defun %expand-mmts-register-in-form (form reg-map location)
  "Rewrite matrix-multiply-tile-stride forms whose C-tile is a register tile (in REG-MAP)
   to their tile-stride + K-loop lowering with a compile-time (M N) size-list tile-spec,
   so the generated store-tile/mma are visible to the register-tile SROA explosion.
   BUG 036: forwards the tile's declared INIT as the per-output-tile reset value."
  (cond
    ((not (consp form)) form)
    ((and (%mmts-head-p form) (assoc (third form) reg-map))
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form location)
       (let ((entry (assoc c-tile reg-map)))
         (%mmts-lower c-form c-tile (second entry) k-form k-step gy gx gk
                      (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) body)
                      location
                      (third entry)))))
    (t (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) form))))

;; src/autodiff.lisp
(defun %mma-ad-expand-mmts-in-form (form reg-map)
  "Recursively lower every matrix-multiply-tile-stride in FORM (endeavor 145 P8: the AD path
   must do this before ANF).  BUG 036: forwards the register tile's declared INIT as the
   per-output-tile reset value; a scratch C-tile resets to the 0.0 default."
  (cond
    ((not (consp form)) form)
    ((%mmts-head-p form)
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form nil)
       (let ((entry (assoc c-tile reg-map)))
         (%mmts-lower c-form c-tile
                      (if entry (second entry) c-tile)
                      k-form k-step gy gx gk
                      (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) body)
                      nil
                      (if entry (third entry) 0.0)))))
    (t (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) form))))

;;; ===================================================================
;;; THE VJP REGISTRY  (endeavor 145, after the P3b post-mortem)
;;;
;;; WHY.  generate-backward-walk's process-form had grown ~12 special-case clauses, and every
;;; endeavor that adds a primitive adds another.  Worse, endeavor 145 derived MMA's backward
;;; THROUGH one chosen lowering (register accumulator tiles decomposed into native fragments)
;;; and then reported that lowering's shape requirements as if they were the hardware's — the
;;; "K-tile contract".  They are not.  dA = dD.B^T and dB = A^T.dD hold at every shape; only the
;;; MMA-instruction REALISATION of them needs the shapes to divide.
;;;
;;; The registry separates those two things, which is the whole point:
;;;   - WHAT the derivative is   -> one entry per primitive, math only.
;;;   - HOW it is computed       -> chosen INSIDE that entry.
;;; A VJP may return a shape-agnostic scalar lowering by default and an MMA lowering when the
;;; shapes admit it.  The walk neither knows nor cares, so the lowering's constraints can never
;;; again leak out as a language-level contract.
;;;
;;; SCOPE: PRIMITIVES, not control flow.  let / dotimes / if / when / progn must be structurally
;;; MIRRORED by the walk and are not lookups.  The registry absorbs the leaf cases only.
;;;
;;; It is deliberately general rather than MMA-private: %backward-skip-fn-p is already a
;;; degenerate registry ("these primitives have a zero VJP"), endeavor 123's FFI user-VJP is the
;;; same concept built bespoke, and the deferred chapter-1..4 AD work (async / ring /
;;; warp-specialisation / wgmma / prefetch) will each need entries.
;;; ===================================================================

;; src/autodiff.lisp
(defvar *vjp-registry* (make-hash-table :test 'equal)
  "Primitive NAME (upcased string) -> VJP function of (FORM CTX).

   CTX is a plist: :flat-anf :inputs :outputs :local-adj :kernel-pkg.

   The function returns one of:
     a FORM   -- the backward Crisp source to emit (wrap several in a progn);
     :inert   -- handled, contributes no gradient (emit nothing);
     NIL      -- DECLINE: not applicable to this particular form, so the walk's existing
                 clauses run unchanged.  Declining is what lets a VJP dispatch on a property
                 of its ARGUMENTS (e.g. store-tile on a register tile vs a scratch tile)
                 rather than on the head symbol alone.")

(defun register-vjp (name fn)
  "Register FN as the VJP for primitive NAME (a string, matched case-insensitively)."
  (setf (gethash (string-upcase name) *vjp-registry*) fn))

(defun find-vjp (head)
  "The registered VJP for form-head HEAD, or NIL."
  (and (symbolp head) (gethash (string-upcase (symbol-name head)) *vjp-registry*)))

(defun %try-vjp (form ctx)
  "Dispatch FORM to its registered VJP.  Returns the backward form, :inert, or NIL (decline).
   NIL is also returned when nothing is registered for the head, so the caller can fall
   through to the walk's own clauses."
  (when (and (consp form) (symbolp (car form)))
    (let ((fn (find-vjp (car form))))
      (when fn
        (let ((r (funcall fn form ctx)))
          (log:debug "VJP ~a -> ~a" (car form)
                     (cond ((null r) "DECLINE") ((eq r :inert) ":inert") (t (format nil "~s" r))))
          r)))))

;;; ===================================================================
;;; VJP for mma-accumulate-via-tile — SCALAR by default, MMA as a fast path.
;;;
;;; C-tile += A.B  =>  dA[m,k] += sum_n dC[m,n]*B[k,n],  dB[k,n] += sum_m A[m,k]*dC[m,n].
;;; That is true at EVERY shape.  Only the MMA realisation of it needs the tile dims to divide
;;; into whole hardware fragments, so that condition now selects a LOWERING instead of gating
;;; correctness.
;;;
;;; The scalar lowering is in some ways simpler than the MMA one: it indexes the ORIGINAL GLOBAL
;;; operands directly, so it needs none of the transposed SLM staging the MMA path requires.
;;; (It still reads the global sources rather than the staged primal tiles, because a backward
;;; kernel replays the forward's BINDINGS but not its STATEMENTS — the staged tiles are empty.)
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-vjp-operand-ref (op src-map dims-map inputs)
  "Resolve an mma-accumulate-via-tile operand to (values SRC OY OX KIND).

   Two flavours, both of which the scalar VJP indexes identically:
     - STAGED  : the operand is a scratch tile filled by load-tile-at.  SRC is the ORIGINAL
                 global matrix and (OY OX) the staging origin.
     - DIRECT  : the operand IS a global matrix (a kernel parameter read straight by the
                 fragment loads, as in 132/04-mma-via-tile).  Origin (0 0)."
  (let ((entry (assoc op src-map)))
    (cond
      (entry (values (second entry) (first (third entry)) (second (third entry)) :staged))
      ((and (symbolp op) (member op inputs)) (values op 0 0 :direct))
      ((assoc op dims-map) (values op 0 0 :staged))
      (t (values nil nil nil nil)))))

;; src/autodiff.lisp
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT."
  (declare (ignore a-op b-op))
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         (flt  (intern "FLOAT" cl))    (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         (dc   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl)))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (list (list dc (list msm flt (list mt nt))))
            (list st c-adj dc (list 0 0))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            (list ws a-adj (list m k)
                  (list dt (list n nt)
                        (list set! (list aref a-adj m k)
                              (list plus (list aref a-adj m k)
                                    (list mul (list aref dc m n)
                                          (list aref b-src (ix boy k) (ix box n)))))))
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]
            (list ws b-adj (list k n)
                  (list dt (list m mt)
                        (list set! (list aref b-adj k n)
                              (list plus (list aref b-adj k n)
                                    (list mul (list aref a-src (ix aoy m) (ix aox k))
                                          (list aref dc m n))))))
            (list sync)))))

;; src/autodiff.lisp
(defun %mma-vjp-mma-admissible-p (mt nt kt)
  "T when the MMA fast path can realise the backward: both backward accumulators (Mt x Kt and
   Kt x Nt) must decompose into whole hardware accumulator fragments.  This is a PERFORMANCE
   predicate — declining it selects the scalar lowering, never an error."
  (multiple-value-bind (sm sn sk) (%spv-mma-shape)
    (declare (ignore sk))
    (and (plusp sm) (plusp sn)
         (zerop (mod kt (lcm sm sn)))
         (zerop (mod mt sm))
         (zerop (mod nt sn)))))

;; src/autodiff.lisp
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B ...).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path's shape requirements, so they cannot leak back out as a
   language-level contract the way the 'K-tile contract' did.

     MMA fast path  -- when both backward accumulators decompose into whole fragments.
     Scalar path    -- otherwise.  Correct at any shape, slower.

   DECLINES (NIL) only when the tile shapes are not compile-time known, which the walk then
   reports through its existing error."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (c-dims   (assoc c-tile dims-map))
           (a-dims   (assoc a-op dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     ;; A staged operand's K is its own column extent.  A DIRECT global operand
                     ;; has runtime extents, and the forward reads exactly one native K-step
                     ;; from it, so its Kt is the instruction's K.
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package c-tile)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg)))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (if (%mma-vjp-mma-admissible-p mt nt kt)
                    (%mma-via-tile-backward form dims-map src-map inputs outputs
                                            local-adj kernel-pkg)
                    (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                              a-src aoy aox b-src boy box pkg))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)

;;; ===================================================================
;;; VJP for the FRAGMENT-level MMA chain  (133/02, 133/10, 132/02 — "hello mma")
;;;
;;; The earlier claim that no fragment-level backward exists was wrong in the same way the
;;; "K-tile contract" was: it argued from one chosen realisation (keep everything in registers,
;;; where dA's contraction over n spans lanes and needs shuffles) to a statement about the
;;; mathematics.  Route through memory instead — exactly as the tile-level VJP already routes
;;; dC — and the lane problem simply does not arise.
;;;
;;; WHY THIS IS FUSED RATHER THAN COMPOSITIONAL.  Measured from the ANF the walk actually
;;; receives:
;;;     (STORE-FRAGMENT (MMA-ACCUMULATE C-ACC A-FRAG B-FRAG) C (0 0))
;;; store-fragment is opaque to ANF, so its value argument is NOT split into its own binding —
;;; there is no intermediate variable to hang a fragment-valued adjoint on.  The whole chain
;;; arrives as one statement, so one fused VJP is the natural shape here, not a shortcut.
;;;
;;; SCOPE, stated plainly: this covers `store-fragment` applied directly to an
;;; `mma-accumulate` — the canonical hello-mma form.  An `mma-accumulate` whose result is held
;;; in a register across a loop before being stored is NOT covered and still reports its (now
;;; accurate) "no VJP registered" error.  That case wants genuine fragment-valued adjoints.
;;; ===================================================================

;; src/autodiff.lisp
(defun %vjp-resolve-anf-value (sym flat-anf)
  "Resolve an ANF temp back to the literal it was bound to.

   Coordinate lists reach the walk as temps — `(%ANF-T-1 (0 0))` — because anf-normalize treats
   a bare list like `(0 0)` as a call and binds it.  (The same pathology turned
   `(GRID-Y GRID-X GRID-K)` into a call in P8.)  Returns SYM unchanged if it is not such a temp."
  (if (symbolp sym)
      (or (loop for f in flat-anf
                  when (and (consp f) (= (length f) 2) (eq (first f) sym))
                return (second f))
          sym)
      sym))

;; src/autodiff.lisp
(defun %vjp-fragment-source (frag-sym flat-anf which)
  "For a fragment variable bound by (load-fragment-a/b SRC COORDS), return the list
   (SRC COORD-Y COORD-X), or NIL when FRAG-SYM was not bound that way.
   WHICH is :a or :b and only selects the expected head."
  (let ((head (ecase which (:a "LOAD-FRAGMENT-A") (:b "LOAD-FRAGMENT-B"))))
    (dolist (f flat-anf nil)
      (when (and (consp f) (= (length f) 2) (eq (first f) frag-sym)
                 (consp (second f)) (symbolp (first (second f)))
                 (string-equal (symbol-name (first (second f))) head))
        (let ((coords (%vjp-resolve-anf-value (third (second f)) flat-anf)))
          (cl:return (list (second (second f))
                           (if (consp coords) (first coords) 0)
                           (if (consp coords) (second coords) 0))))))))

;; src/autodiff.lisp
(defun %vjp-store-fragment (form ctx)
  "VJP for (store-fragment (mma-accumulate C A-FRAG B-FRAG) DEST (TY TX)).

   D = A.B + C stored to DEST, so with dD read from DEST_GRAD at the store's tile:
       dA[m,k] += sum_n dD[m,n] * B[k,n]
       dB[k,n] += sum_m A[m,k] * dD[m,n]
   over one instruction-shaped block (M_n x N_n accumulator, M_n x K_n A, K_n x N_n B), reading
   the ORIGINAL global operands at their load-fragment origins and scattering with atomic-add!
   — the same collective + atomic discipline %load-tile-at-bwd uses.

   DECLINES unless the stored value is literally an mma-accumulate over two load-fragment
   results; anything else falls through to the walk's existing (accurate) error."
  (destructuring-bind (value dest tile-id &rest ignored) (cdr form)
    (declare (ignore ignored))
    (when (and (consp value) (symbolp (car value))
               (string-equal (symbol-name (car value)) "MMA-ACCUMULATE")
               (= (length value) 4))
      (let* ((flat-anf (getf ctx :flat-anf))
             (inputs (getf ctx :inputs)) (outputs (getf ctx :outputs))
             (local-adj (getf ctx :local-adj)) (kernel-pkg (getf ctx :kernel-pkg))
             (a-frag (third value)) (b-frag (fourth value)))
        (let ((ainfo (%vjp-fragment-source a-frag flat-anf :a))
              (binfo (%vjp-fragment-source b-frag flat-anf :b)))
          (when (and ainfo binfo)
            (destructuring-bind (a-src ay ak) ainfo
              (destructuring-bind (b-src bk bx) binfo
              (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                (let* ((cl (find-package :crisp-language))
                       (ws (intern "WORKGROUP-STRIDE" cl)) (dt (intern "DOTIMES" cl))
                       (aref (intern "~" cl)) (aadd (intern "ATOMIC-ADD!" cl))
                       (plus (intern "+" cl)) (mul (intern "*" cl))
                       (ti (intern "TO-INT" cl)) (prog- (intern "PROGN" cl))
                       (m (intern "%FVJP_M" cl)) (n (intern "%FVJP_N" cl)) (k (intern "%FVJP_K" cl))
                       (d-adj (%tlc-bwd-adj-name dest inputs outputs local-adj kernel-pkg))
                       (a-adj (%tlc-bwd-adj-name a-src inputs outputs local-adj kernel-pkg))
                       (b-adj (%tlc-bwd-adj-name b-src inputs outputs local-adj kernel-pkg))
                       (cy (* (if (consp tile-id) (or (first tile-id) 0) 0) sm))
                       (cx (* (if (consp tile-id) (or (second tile-id) 0) 0) sn)))
                  (flet ((ix (base off) (list plus (list ti base) (list ti off))))
                    (list prog-
                          ;; dA[m,k] += sum_n dD[m,n] * B[k,n]
                          (list ws a-adj (list m k)
                                (list dt (list n sn)
                                      (list aadd (list aref a-adj (ix (* ay sm) m) (ix (* ak sk) k))
                                            (list mul
                                                  (list aref d-adj (ix cy m) (ix cx n))
                                                  (list aref b-src (ix (* bk sk) k) (ix (* bx sn) n))))))
                          ;; dB[k,n] += sum_m A[m,k] * dD[m,n]
                          (list ws b-adj (list k n)
                                (list dt (list m sm)
                                      (list aadd (list aref b-adj (ix (* bk sk) k) (ix (* bx sn) n))
                                            (list mul
                                                  (list aref a-src (ix (* ay sm) m) (ix (* ak sk) k))
                                                  (list aref d-adj (ix cy m) (ix cx n))))))))))))))))))

(register-vjp "STORE-FRAGMENT" #'%vjp-store-fragment)
(register-vjp "MAKE-REGISTER-FRAGMENT" (lambda (form ctx) (declare (ignore form ctx)) :inert))

;; src/autodiff.lisp
(defun %vjp-fragment-consumed-by-fused-store-p (frag-sym flat-anf)
  "T when FRAG-SYM is an operand of an `(mma-accumulate ...)` that is stored directly by a
   `store-fragment` — i.e. the chain %vjp-store-fragment already differentiates as a unit."
  (dolist (f flat-anf nil)
    (let ((form (if (and (consp f) (= (length f) 2) (consp (second f))) (second f) f)))
      (when (and (consp form) (symbolp (car form))
                 (string-equal (symbol-name (car form)) "STORE-FRAGMENT")
                 (>= (length form) 2)
                 (let ((v (second form)))
                   (and (consp v) (symbolp (car v))
                        (string-equal (symbol-name (car v)) "MMA-ACCUMULATE")
                        (member frag-sym (cddr v)))))
        (cl:return t)))))

;; src/autodiff.lisp
(defun %vjp-load-fragment (form ctx)
  "VJP for load-fragment-a / load-fragment-b.

   Returns :inert when this fragment feeds a fused store-fragment(mma-accumulate ...) chain —
   %vjp-store-fragment has already scattered the gradient into this operand's global gradient,
   so contributing again would double-count.

   DECLINES otherwise, so an un-fused fragment use still raises the (accurate) 'no VJP
   registered' error rather than silently yielding a zero gradient.  Silently dropping a
   gradient is the failure mode this endeavor hit three times; it is not repeated here."
  (declare (ignore form))
  (let ((flat-anf (getf ctx :flat-anf))
        (bound-to (getf ctx :binding-var)))
    (when (and bound-to (%vjp-fragment-consumed-by-fused-store-p bound-to flat-anf))
      :inert)))

(register-vjp "LOAD-FRAGMENT-A" #'%vjp-load-fragment)
(register-vjp "LOAD-FRAGMENT-B" #'%vjp-load-fragment)

;;; ===================================================================
;;; BUG 037 — the backward must read staged tiles' primals from their GLOBAL SOURCE.
;;;
;;; A backward kernel replays the forward's BINDINGS but not its STATEMENTS.
;;; `make-scratch-matrix` is a binding, so the tiles EXIST in the backward — but
;;; `load-tile-at`, which FILLS them, is a statement and is never replayed.  So a replayed
;;; primal like `(~ A-TILE i k)` read an EMPTY tile, and any gradient needing another operand's
;;; primal value came back SILENTLY ZERO.  Measured on a 4x4 scalar matmul: analytical 0.0
;;; against a correct finite difference of 0.06.
;;;
;;; Only visible when a primal is actually NEEDED: with a constant multiplier none is, which is
;;; why every pre-existing AD-over-tiles spec passed.  Bisected — overwrite, accumulate, and
;;; three-deep loops with ONE tile operand all give exact gradients; only TWO tile operands fail.
;;;
;;; FIX (option b, chosen over replaying the staging statements): rewrite the replayed primal
;;; to read the ORIGINAL GLOBAL matrix at the staging origin —
;;;     (~ A-TILE i k)  ->  (~ A (+ oy i) (+ ox k))
;;; This generalises what endeavor 145's MMA VJP already does (and which is numerically verified
;;; four ways).  It has the same coverage as replaying `load-tile-at` would, but costs no extra
;;; SLM traffic, needs no barriers in the backward, and does not touch the walk's loop structure.
;;;
;;; WHAT IT DOES NOT COVER: a tile filled by COMPUTATION has no global source, so its primal is
;;; still unavailable — e.g. `(set! (~ C i j) (* (~ C i j) (~ A i j)))`, where dA needs C's OLD
;;; value.  That case now ERRORS rather than silently returning zero (see the check below).
;;; Closing it properly means real primal recomputation / checkpointing, which is its own design.
;;; ===================================================================

;; src/autodiff.lisp
(defvar *ad-tile-src-map* nil
  "Alist TILE-SYM -> (GLOBAL-SRC ORIGIN-FORMS) for tiles filled by load-tile-at in the kernel
   being differentiated.  Bound by generate-backward-walk.")

(defvar *ad-scratch-syms* nil
  "Hash of scratch-tile symbols in the kernel being differentiated.  Bound by
   generate-backward-walk.")

;; src/autodiff.lisp
(defun %ad-tile-read-p (expr)
  "T when EXPR is an indexed tile read `(~ SYM idx ...)`."
  (and (consp expr) (symbolp (car expr))
       (string= (symbol-name (car expr)) "~")
       (symbolp (second expr)) (second expr)
       (cddr expr)))

;; src/autodiff.lisp
(defun %ad-rewrite-primal-tile-read (expr)
  "Rewrite a staged-tile read to the equivalent read of its ORIGINAL GLOBAL source, or return
   EXPR unchanged when the tile has no recoverable source.  Indices are coerced with to-int: a
   staging origin can be a ULONG extent expression while the loop variables are INT."
  (if (not (%ad-tile-read-p expr))
      expr
      (let ((entry (assoc (second expr) *ad-tile-src-map*)))
        (if (null entry)
            expr
            (let* ((cl (find-package :crisp-language))
                   (aref (intern "~" cl)) (plus (intern "+" cl)) (ti (intern "TO-INT" cl))
                   (src (second entry)) (origin (third entry))
                   (idxs (cddr expr)))
              (if (/= (length origin) (length idxs))
                  expr
                  (list* aref src
                         (loop for o in origin
                               for i in idxs
                               collect (list plus (list ti o) (list ti i))))))))))

;; src/autodiff.lisp
(defun %ad-rewrite-primal-bindings (bindings)
  "Apply %ad-rewrite-primal-tile-read to each primal binding's VALUE."
  (mapcar (lambda (b)
            (if (and (consp b) (= (length b) 2))
                (list (first b) (%ad-rewrite-primal-tile-read (second b)))
                b))
          bindings))

;; src/autodiff.lisp
(defun %ad-check-unresolved-primals (bindings body)
  "ERROR when a primal bound to an UNRESOLVABLE scratch-tile read is actually USED as a value by
   the backward BODY.

   Silence here is what bug 037 was: an unavailable primal read as zero.  A tile whose primal is
   never consumed (a pure accumulator like C-tile, whose old value matters only for its adjoint)
   is fine and must NOT error — hence the usage test rather than a blanket check."
  (dolist (b bindings)
    (when (and (consp b) (= (length b) 2)
               (%ad-tile-read-p (second b))
               *ad-scratch-syms*
               (gethash (second (second b)) *ad-scratch-syms*)
               (null (assoc (second (second b)) *ad-tile-src-map*))
               (%vjp-form-mentions-any-p body (list (first b))))
      (error 'crisp-compiler-error
        :message (format nil "cannot differentiate: the backward needs the PRIMAL value of ~a, a scratch tile that is not filled by load-tile-at, so its contents cannot be recovered (a backward kernel replays the forward's bindings but not its statements).  Tiles staged with load-tile-at are read back from their global source automatically; a tile filled by COMPUTATION is not recoverable.  Restructure so the value the gradient needs comes from a staged or global operand, or mark the kernel forward-only.  See plan/bugs.md #037."
                         (second (second b)))
        :source-location nil))))

;; src/autodiff.lisp
(defun %gfw-process-let (form emit-fn process-form-fn bindings augmented-bindings body)
  "BUG 037: the replayed primal bindings now read staged tiles from their ORIGINAL GLOBAL source
   instead of from the (empty) tile, and an unrecoverable primal that the backward actually uses
   is a hard error rather than a silent zero."
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
              (funcall process-form-fn b #'local-emit))))
    (let ((backward-body (nreverse local-forms)))
      (%ad-check-unresolved-primals augmented-bindings backward-body)
      (funcall emit-fn `(let ,(%ad-rewrite-primal-bindings augmented-bindings)
                          ,@backward-body)))))


;;; ======================================================================
;;; BUG 038 — gradients through a VOID SUB-FUNCTION call, by INLINING.
;;;
;;; 137/04's kernel copies a 4x4 tile of A into C through a staging sub-function.  That is the
;;; identity, dA = dC, and there is nothing in it that is not differentiable — yet it returned a
;;; gradient of exactly 0.0.  Three separate silent failures stacked on the one call; see
;;; tests/spec/145-mma-autodiff/17-void-subfn-vjp-bmg.crisp for the full account.
;;;
;;; THE SHAPE OF THE FIX.  Endeavor 111 Phase 1c already put the AD splice in the right place:
;;; `load-tile-at` -> %load-tile-at-bwd and `store-tile-at` -> %store-tile-at-bwd.  The kernel's
;;; `store-tile` already produced its backward edge.  The ONLY missing edge was the `load-tile`
;;; hidden inside the sub-function, which the walk never saw.  So rather than repair the _GRAD
;;; companion path, we stop needing it: INLINE the callee's body at the call site and walk it
;;; with the ordinary statement walker.  Every per-construct rule then applies inside a
;;; sub-function exactly as it does inside a kernel, automatically and for all of them.
;;;
;;; This is the endeavor-145 lesson applied again: the previous design derived a sub-function's
;;; backward THROUGH one chosen realisation (generate a companion, thread grad-outs through its
;;; &out params, call it), and that realisation's requirements — a recognisable tensor param
;;; type, a well-formed companion, correct tensor-param indices — became de-facto conditions for
;;; a gradient existing at all.  They are conditions on the LOWERING, not on the derivative.
;;; Inlining needs none of them.  The companion path is KEPT as the fallback: it is still the
;;; right lowering for scalar math sub-functions (one copy of the code, not one per call site)
;;; and it is MANDATORY for FFI, where there is no body to inline.
;;; ======================================================================

;; src/autodiff.lisp
(defun %crisp-tensor-param-type-p (pd-type)
  "Returns T if PD-TYPE is a tensor (float-element or integer-element) at the sub-function
   level.  Used to decide whether a sub-fn param contributes a tensor grad-out (vs a scalar
   delta).

   Handles four forms:
   - List form: (tensor float 1 ...) — caught by the existing helpers.
   - Mangled-template-name symbol: TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST — produced by Crisp's
     template instantiation.  Detected by name prefix.
   - Plain symbol naming a registered tensor type.
   - BUG 038: a user `def-type` ALIAS of a tensor/vector/matrix type.  The docstring always
     claimed the third case was handled, but nothing resolved aliases, so

         (def-type mat-t (matrix float ...))
         (def-function stage (src tile) (declare #'(mat-t tile-t => ulong)) ...)

     looked like a function with NO differentiable parameters at all.  %generate-backward-
     function-ast then took its `(zerop n-float-params)` early return, which does not merely skip
     the companion — it marks the function gradient-INERT, so calls to it are skipped in the
     backward walk deliberately and silently, as a documented zero.  Aliasing a parameter type is
     not a semantic change, so it must not be an AD-visible one.  %is-tensor-alias already
     existed for precisely this question."
  (or (%crisp-float-tensor-type-p pd-type)
      (%crisp-integer-tensor-type-p pd-type)
      (and (symbolp pd-type)
           (let ((name (symbol-name pd-type)))
             (and (>= (length name) 7)
                  (string-equal "TENSOR_" (subseq name 0 7)))))
      (%is-tensor-alias pd-type)))

;; src/autodiff.lisp
(defun %generate-backward-function-ast (name params declarations body-forms)
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable user
   function.

   BUG 038: additionally RETAINS the callee's parameter symbols and body in
   *differentiable-hof-store*, so the backward walk can inline it at a call site instead of
   calling a companion.  Stored for every differentiable def-function, not just HOFs, and stored
   BEFORE the gradient-inert early return — a function can be inline-differentiable even when it
   has no companion, which is exactly the 137/04 case.  Reusing the HOF store rather than adding
   a global keeps it on the existing initialize-compiler clrhash, so a body cannot leak between
   two specs compiled in the same image (run-specs runs in-process).  The HOF reader is not
   disturbed: it is only reached when *differentiable-functions* says :hof t."
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  (when (%trivial-accessor-body-p body-forms)
        (log:info "AUTODIFF: ~a is a trivial field-extraction accessor — skipping _GRAD generation." name)
        (return-from %generate-backward-function-ast nil))
  (let* ((pkg (symbol-package name)))
    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)
      (let* ((float-param-entries
              (loop for pd in env
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-float-type-p (parameter-def-type pd)))
                    collect pd))
             (float-param-syms (mapcar #'parameter-def-name float-param-entries))
             (record-param-info (%collect-record-param-info env pkg))
             (active-set (%active-scalar-param-set (mapcar #'parameter-def-name env) body-forms))
             (all-diff-param-syms-for-return
              (%collect-all-diff-param-syms-for-return env record-param-info active-set))
             (record-param-field-adjs-ht (%build-record-param-field-adjs-ht record-param-info))
             (n-float-params
              (loop for pd in env
                      when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                      sum (%count-active-contributions (parameter-def-type pd)
                                                       (parameter-def-name pd) active-set)))
             (return-types-non-void (remove nil return-types))
             (n-return (length return-types-non-void))
             (fn-param-entries
              (loop for pd in env for i from 0
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-function-type-p (parameter-def-type pd)))
                    collect (cons i pd)))
             (is-hof (consp fn-param-entries)))

        ;; BUG 038: retain the body for inline differentiation.  Cheap, additive, and done
        ;; before any early return.  &OUT is a marker in the parameter list rather than a
        ;; parameter, so it is dropped to keep :param-syms positionally aligned with the call
        ;; arguments the walk will substitute.
        (unless is-hof
          (setf (gethash name *differentiable-hof-store*)
                (list :param-syms (loop for pd in env
                                          unless (string-equal (symbol-name (parameter-def-name pd)) "&OUT")
                                        collect (parameter-def-name pd))
                      :body-forms body-forms
                      :inlinable t))
          (log:debug "038: retained body of ~a for inline backward (~a forms)" name (length body-forms)))

        (when (and (zerop n-float-params)
                   (not (%has-tensor-diff-param-p env)))
              (log:info "AUTODIFF: ~a has no differentiable params — skipping _GRAD generation (marking gradient-inert)." name)
              (setf (gethash name *inert-functions*) t)
              (return-from %generate-backward-function-ast nil))

        (if is-hof
            (%register-hof-differentiable-function name env float-param-syms fn-param-entries n-return body-forms)
            (%generate-backward-companion-ast-body name params env declarations body-forms pkg n-float-params n-return
                                                   return-types-non-void record-param-info record-param-field-adjs-ht all-diff-param-syms-for-return))))))

;; src/autodiff.lisp
(defvar *ad-inlining-fns* nil
  "Names of sub-functions currently being inlined by the backward walk, innermost last.
   Guards against unbounded expansion on a recursive or mutually-recursive call.")

;; src/autodiff.lisp
(defun %ad-sub-fn-inlinable-p (fn)
  "Returns T if FN's body was retained and can be inlined into a backward walk.
   NIL for foreign functions (no body exists), for HOFs (which have their own inline path keyed
   on the function-valued parameter), and for anything already on the inline stack."
  (let ((info (gethash fn *differentiable-functions*))
        (store (gethash fn *differentiable-hof-store*)))
    (and info
         (not (getf info :foreign))
         (not (getf info :hof))
         (getf store :inlinable)
         (getf store :body-forms)
         (not (member fn *ad-inlining-fns* :test #'eq)))))

;; src/autodiff.lisp
(defun %ad-inline-sub-fn-backward (fn args emit-fn process-form-fn)
  "BUG 038: emits the backward for a call to differentiable sub-function FN by INLINING its body
   at the call site and walking it with PROCESS-FORM-FN, the caller's ordinary STATEMENT walker.

   Why the statement walker and not %handle-single-value-backward.  The existing inline path,
   hof-inline-backward, walks only two-element value bindings, because a HOF's inlined body is
   consumed for its VALUE.  A staging sub-function has no value worth differentiating — its
   whole gradient content is in its STATEMENTS, `load-tile` above all.  Routing through
   process-form-fn means every construct the walker already knows (load/store-tile-at, set!,
   let, dotimes, if/when, nested calls) applies inside a sub-function body for free, and stays
   applying as the walker grows.

   The body is substituted (formals -> actual call arguments), ANF-transformed and flattened
   exactly as hof-inline-backward does, so the forms handed to the walker are the same shape it
   sees for a kernel body.  Adjoints are NOT renamed: substitution has already rewritten the
   callee's parameter references to the caller's symbols, so `(~ dst i j)` becomes `(~ C i j)`
   and the walker mints C_ADJ in the caller's frame, which is where the gradient must land.

   Statements are walked in reverse, matching the PROGN clause's convention that the CALLER
   reverses.  Returns T when it emitted, NIL when FN cannot be inlined (the caller then falls
   back to the _GRAD companion path)."
  (unless (%ad-sub-fn-inlinable-p fn)
    (return-from %ad-inline-sub-fn-backward nil))
  (let* ((store (gethash fn *differentiable-hof-store*))
         (param-syms (getf store :param-syms))
         (body-forms (getf store :body-forms)))
    (when (/= (length param-syms) (length args))
      ;; Arity disagreement means the substitution would be positionally wrong, which would
      ;; produce a confidently incorrect gradient rather than a missing one.  Decline instead.
      (log:warn "038: not inlining ~a — ~a params but ~a args" fn (length param-syms) (length args))
      (return-from %ad-inline-sub-fn-backward nil))
    (let* ((*ad-inlining-fns* (cons fn *ad-inlining-fns*))
           (subst-alist (loop for p in param-syms for a in args collect (cons p a)))
           (subst-body (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
           (anf-body (mapcar #'anf-transform subst-body))
           (flat (flatten-anf-body anf-body)))
      (log:debug "038: inlining ~a for backward — ~a body form(s) -> ~a flat form(s)"
                 fn (length body-forms) (length flat))
      (dolist (f (reverse flat))
        (funcall process-form-fn f emit-fn))
      t)))

;; src/autodiff.lisp
(defun %ad-sub-fn-inlinable-p (fn)
  "Returns T if FN's body was retained and can be inlined into a backward walk.

   Keyed on the RETAINED BODY rather than on *differentiable-functions*, deliberately.  When
   %generate-backward-companion-ast-body cannot build a companion it UNREGISTERS the function:

       Cannot differentiate function SCALE_INTO: it mutates parameter DST via cell write.
       This function is not valid in a differentiable kernel.  Unregistering.

   That message overstates its case.  Writing through a tensor parameter is what a staging or
   fill sub-function is FOR, and it is not a problem for the derivative — only for the companion
   lowering, whose chain rule threads gradients through returned values and &out grad-handles
   and so has nowhere to put an in-place write.  Inlining has no such difficulty: after
   substitution the write is `(set! (~ C i j) ...)` on the CALLER's symbol, which is the same
   form %gfw-process-set! already differentiates inside a kernel.  So a failed companion must
   not veto the inline path — otherwise the more expressive lowering is disabled by the less
   expressive one's limits.

   Excluded: foreign functions (no body exists), HOFs (their own inline path is keyed on the
   function-valued parameter), functions deliberately marked gradient-inert, and anything
   already on the inline stack."
  (let ((info (gethash fn *differentiable-functions*))
        (store (gethash fn *differentiable-hof-store*)))
    (and store
         (getf store :inlinable)
         (getf store :body-forms)
         (not (getf info :foreign))
         (not (getf info :hof))
         (not (gethash fn *inert-functions*))
         (not (member fn *ad-inlining-fns* :test #'eq)))))


;;; ======================================================================
;;; BUG 039 — N-D indexing inside a def-function silently dropped every index past the first.
;;;
;;; `(~ dst i j)` in a sub-function whose parameter type came from a `def-type` ALIAS compiled
;;; to `dst[i]`: a 4x4 fill wrote FOUR cells instead of sixteen, on hardware, with no error.
;;; The identical body in a KERNEL was correct, because kernel parameters are exploded and
;;; reassembled and so carry the mangled `TENSOR_*` type, while a sub-function parameter keeps
;;; whatever the declare said.
;;;
;;; analyze-aref-expression dispatches on (%get-tensor-arity array-type).  That helper knew the
;;; list form `(tensor elem N ...)` and mangled symbols but not aliases, returned NIL, and the
;;; analyzer fell through to the "Cell / array path: single index" — which uses only the first
;;; index and DISCARDS the rest.  %get-tensor-align had the same hole.
;;;
;;; TWO CHANGES, because the fix and the failure MODE are separate problems.
;;;
;;; 1. Resolve aliases in both helpers, via canonicalize-type-specifier — which already resolves
;;;    def-type aliases and re-mangles, and whose output %get-tensor-arity already understands.
;;;
;;;    NOT by canonicalising parameter types once at declaration, which was the other candidate.
;;;    The emitted symbol for the repro is `fill_seven_mat_t_mat_t`: the ALIAS NAME is
;;;    load-bearing for name mangling and overload resolution, so normalising param types at the
;;;    declaration would change mangled names.  The alias must survive; only the QUERIES about
;;;    it need to see through it.
;;;
;;; 2. Make the fall-through LOUD.  Silence here is not incidental — it is the whole reason 039
;;;    reached hardware, and it is the THIRD time this exact path has bitten: endeavor 138 fixed
;;;    it for compound tensor targets (see the comment above `target-form`, "silently DROPPED
;;;    every index past the first"), 039 is the alias case, and each was found only by chasing a
;;;    wrong NUMBER.  The tensor path already errors on a known-but-mismatched arity; the gap is
;;;    that an UNKNOWN arity took the single-index path instead.  A cell or 1-D array is never
;;;    indexed with two subscripts, so multiple indices arriving there now error with the type
;;;    named.  Any future member of this family fails at compile time instead of computing a
;;;    plausible wrong answer.
;;; ======================================================================

;; src/analysis/structs.lisp
(defun %get-tensor-arity (type)
  "Returns the compile-time arity N of TYPE as an integer, or NIL.
   Handles list form (tensor elem N ...), mangled-symbol form, and — BUG 039 — a `def-type`
   ALIAS, resolved through canonicalize-type-specifier."
  (labels ((coerce-n (raw)
             (etypecase raw
               (integer raw)
               (symbol  (ignore-errors (parse-integer (symbol-name raw) :junk-allowed nil)))
               (t nil))))
    (cond
      ((and (listp type) (symbolp (first type))
            (string-equal (symbol-name (first type)) "TENSOR"))
       (coerce-n (third type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (if (and (consp unmangled) (symbolp (first unmangled))
                  (string-equal (symbol-name (first unmangled)) "TENSOR"))
             (coerce-n (third unmangled))
             ;; BUG 039: a def-type alias reaches here unrecognised.  Canonicalize and retry
             ;; once.  Guarded and non-recursive: canonicalize-type-specifier can signal on a
             ;; malformed or incomplete spec, and a type we cannot canonicalize is simply one
             ;; whose arity is unknown — same answer as before, now reached deliberately.
             (let ((canon (ignore-errors (canonicalize-type-specifier type))))
               (when (and canon (not (equal canon type)))
                 (%get-tensor-arity canon))))))
      (t nil))))

;; src/analysis/structs.lisp
(defun %get-tensor-align (type)
  "Extracts the :align keyword from a tensor type specifier.
   New 6-tuple (tensor elem N addr aln ct): align at position 4 = (fifth type).
   Handles list form, mangled symbol, and — BUG 039 — a `def-type` ALIAS.

   This matters as much as the arity: with the arity fixed but the align still unresolved the
   analyzer would take the :strided fallback for a :compact tensor, which reads strides~ that a
   compact type is not obliged to carry."
  (labels ((coerce-aln (raw)
             (cond
               ((eq raw :compact)         :compact)
               ((eq raw :compact-offset)  :compact-offset)
               ((eq raw :strided)         :strided)
               ((and (symbolp raw) (string-equal (symbol-name raw) "COMPACT"))         :compact)
               ((and (symbolp raw) (string-equal (symbol-name raw) "COMPACT-OFFSET"))  :compact-offset)
               ((and (symbolp raw) (string-equal (symbol-name raw) "STRIDED"))         :strided)
               (t nil))))
    (cond
      ((and (listp type) (symbolp (first type))
            (string-equal (symbol-name (first type)) "TENSOR"))
       (coerce-aln (fifth type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (if (and (consp unmangled) (symbolp (first unmangled))
                  (string-equal (symbol-name (first unmangled)) "TENSOR"))
             (coerce-aln (fifth unmangled))
             (let ((canon (ignore-errors (canonicalize-type-specifier type))))
               (when (and canon (not (equal canon type)))
                 (%get-tensor-align canon))))))
      (t nil))))

;; src/analysis/structs.lisp
(defun analyze-aref-expression (expr env context location)
  "Analyzes (~ target [index...]) or (~ref~ ...) expressions.
   Tensor path dispatches on resolved :align:
     :compact        → %build-tensor-compact-flat-index-form  (no offset, no stride)
     :compact-offset → %build-tensor-compact-offset-flat-index-form (offset, no stride)
     :strided / NIL  → %build-tensor-flat-index-form (offset + stride, safe fallback)

   BUG 039: the cell / single-index fall-through now REJECTS multiple indices instead of
   silently discarding all but the first."
  (let* ((op          (first expr))
         (target-sym  (if (symbolp (second expr)) (second expr) nil))
         ;; Endeavor 138: the flat-index builders splice the target into (extents~ TARGET k)
         ;; etc.  A SYMBOL is the common case, but a compound tensor expression — notably
         ;; (ring-get ring i) passed straight into mma-accumulate-via-tile / load-tile — must
         ;; work too.  Splicing the whole FORM re-evaluates it once per extents~/strides~ read;
         ;; that is safe because such a target is a pure view constructor (make-view: address
         ;; arithmetic, no side effects, no implicit-arg/descriptor registration).  The element
         ;; POINTER the aref returns comes from ARRAY-NODE (analyzed once, below), NOT from this
         ;; re-evaluated form, so both read and pointer/set! contexts stay correct.  Without
         ;; this, a non-symbol tensor target fell through to the single-index cell path, which
         ;; silently DROPPED every index past the first (a ring slot read with row-stride 1).
         (target-form (second expr))
         (array-node  (analyze-expression (second expr) env context (append location '(1))))
         (index-expr  (third expr))
         (index-node  (if index-expr
                          (analyze-expression index-expr env context (append location '(2)))
                          (make-semantic-literal :value-type 'int :value 0
                                                 :source-location location)))
         (array-type  (semantic-node-type array-node))
         (elem-type   (get-array-element-type array-type)))

    ;; Guard: no read from &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
      (let ((binding (find-variable-in-env target-sym env)))
        (when (and binding (eq (parameter-def-kind binding) :out))
          (error 'crisp-illegal-access-error
            :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only."
                             target-sym)
            :source-location location))))

    (if elem-type
        (progn
          ;; Guard: void element type
          (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "VOID"))
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "T"))
                             (and (consp elem-type)
                                  (let ((head (first elem-type)))
                                    (or (eq head 'void) (eq head 'T)
                                        (and (symbolp head)
                                             (string-equal (symbol-name head) "VOID"))))))))
            (when is-void
              (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

          (let ((tensor-n (%get-tensor-arity array-type)))
            ;; Endeavor 138: fire the tensor path whenever the target is a tensor, whether it
            ;; is a symbol OR a compound expression (e.g. (ring-get ring i)).  The builders take
            ;; TARGET-FORM — a symbol splices as before; a compound form re-evaluates once per
            ;; extents~/strides~ read (safe: pure view constructor).
            (if tensor-n

                ;; ── Tensor path ──────────────────────────────────────────────
                (let* ((index-forms (cddr expr)))
                  (unless (= (length index-forms) tensor-n)
                    (error "Tensor ~a requires ~a index~:p (arity ~a), got ~a."
                           target-form tensor-n tensor-n (length index-forms)))
                  (let* ((align      (%get-tensor-align array-type))
                         (flat-form  (cond
                                       ((eq align :compact)
                                        (log:debug "AREF compact path (no offset): ~a (N=~a)" target-form tensor-n)
                                        (%build-tensor-compact-flat-index-form target-form index-forms))
                                       ((eq align :compact-offset)
                                        (log:debug "AREF compact-offset path: ~a (N=~a)" target-form tensor-n)
                                        (%build-tensor-compact-offset-flat-index-form target-form index-forms))
                                       (t
                                        (log:debug "AREF strided path: ~a (align=~s)" target-form align)
                                        (%build-tensor-flat-index-form target-form index-forms))))
                         (flat-node  (analyze-expression flat-form env context location)))
                    (make-semantic-aref :type elem-type
                                        :array-node array-node
                                        :index-node flat-node
                                        :source-location location)))

                ;; ── Cell / array path: single index ─────────────────────────
                ;; BUG 039: reaching here with more than one index means the target's ARITY
                ;; could not be determined — the type is not a recognisable tensor.  Previously
                ;; the extra indices were dropped without a word and the kernel computed a
                ;; confident wrong answer on hardware.  A cell or 1-D array genuinely takes at
                ;; most one index, so this is always a real error; naming the type is what makes
                ;; it actionable, since the usual cause is a type the arity query cannot see
                ;; through rather than a mis-written subscript.
                (let ((index-forms (cddr expr)))
                  (when (> (length index-forms) 1)
                    (error "~a index~:p supplied to ~a, but its type ~s is not a tensor of known arity — a cell or 1-D array takes at most one index.  If this IS a multi-dimensional tensor, its arity could not be resolved from the declared type; check the type declaration (a `def-type` alias must resolve to a (tensor|matrix|vector ...) form)."
                           (length index-forms) target-form array-type))
                  (make-semantic-aref :type elem-type
                                      :array-node array-node
                                      :index-node index-node
                                      :source-location location)))))

        ;; Fallback: not a known array/cell/tensor type → try as overloadable call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))


;;; ======================================================================
;;; 138 pipeline rings under --differentiate.
;;;
;;; Every 138 spec carried SKIP-WITH[--differentiate], and 03-06 failed with a raw Lisp type
;;; error rather than a Crisp diagnostic:
;;;
;;;     The value (CRISP.COMPILER:RING-GET TILES 0) is not of type SYMBOL
;;;
;;; Nothing about a ring is undifferentiable.  A ring is rank+1 scratch and `ring-get` is a pure
;;; VIEW selector — endeavor 138 says so itself, in the comment above `target-form` in
;;; analyze-aref-expression: a compound tensor target is "a pure view constructor (make-view:
;;; address arithmetic, no side effects)".  The forward path was taught that; the AD path was
;;; not.  Two gaps, both mechanical:
;;;
;;;   1. %tlc-bwd-adj-name assumed its argument was a SYMBOL and called symbol-name on it, so a
;;;      `(ring-get R i)` tile argument to load-tile / store-tile blew up.
;;;   2. %augment-scratch-adj-bindings did not know the ring constructors, so no adjoint ring
;;;      was allocated even once the naming worked.
;;;
;;; THE RULE, and it is the general one: THE ADJOINT OF A VIEW IS THE SAME VIEW OF THE ADJOINT.
;;; `(ring-get TILES 0)` has adjoint `(ring-get TILES_ADJ 0)`.  This holds because ring-get is
;;; pure address arithmetic: slot i of the adjoint ring is exactly the adjoint of slot i.  It
;;; needs no new backward machinery — the existing %load-tile-at-bwd / %store-tile-at-bwd edges
;;; then apply unchanged, which is why this is a naming fix and not a chapter of its own.
;;; ======================================================================

;; src/autodiff.lisp
(defun %tlc-bwd-adj-name (sym inputs outputs local-adj-fn kernel-pkg)
  "Returns the backward-pass adjoint for a forward tile argument SYM:
     - SYM in INPUTS or OUTPUTS   → <SYM>_GRAD  (kernel param)
     - other symbol (let-bound)   → <SYM>_ADJ   (direct intern; NOT via local-adj-fn, which
       would add the sym to the adjoint-map and make the wrapping let scalar-initialize it —
       wrong for a tensor adjoint.  The auto-allocated <var>_ADJ make-scratch-* binding is the
       only initializer needed.)
     - a VIEW form (ring-get R i) → the same view of R's adjoint, (ring-get <R-adj> i).

   The view case is endeavor 138's rings.  ring-get is a pure view selector — address
   arithmetic, no side effects — so slot i of the adjoint ring IS the adjoint of slot i, and
   recursing on the ring lets the ordinary %load-tile-at-bwd / %store-tile-at-bwd edges apply
   with no new machinery.  Recursion (rather than a single level) costs nothing and keeps the
   rule true for a view of a view.

   Anything else is a compound target we have no adjoint rule for.  That now raises a message
   naming the form instead of letting symbol-name signal `The value (RING-GET ...) is not of
   type SYMBOL`, which told the user nothing about what to do."
  (declare (ignore local-adj-fn))
  (cond
   ((and (consp sym) (symbolp (car sym))
         (string-equal (symbol-name (car sym)) "RING-GET"))
     (list (car sym)
           (%tlc-bwd-adj-name (second sym) inputs outputs nil kernel-pkg)
           (third sym)))
   ((not (symbolp sym))
     (error "No adjoint rule for the tile expression ~s.  A tile argument must be a tensor ~
             symbol or a view of one (e.g. (ring-get RING slot))." sym))
   ((or (member sym inputs) (member sym outputs))
     (intern (format nil "~A_GRAD" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))
   (t
     (intern (format nil "~A_ADJ" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))))

;; src/autodiff.lisp
(defun %augment-scratch-adj-bindings (bindings kernel-pkg)
  "For each binding (var (make-scratch-X ...)), inject a paired (var_ADJ (make-scratch-X ...))
   binding right after.  For other bindings, pass through unchanged.  Promotes element type
   (e.g., ulong -> double) so gradients use correct FP precision.

   Endeavor 145 P3b: MAKE-REGISTER-TILE joins the list, so a register accumulator declared in
   a NESTED let gets its paired adjoint tile the same way a scratch tile does.  (A top-level
   register tile is handled by the scratch-adj-bindings collection in generate-backward-walk.)

   Endeavor 138 rings: the RING constructors join too.  A ring is rank+1 scratch, so its adjoint
   is simply a ring of the same shape, and (ring-get R_ADJ i) is then the adjoint of
   (ring-get R i) — see %tlc-bwd-adj-name.  Note the BARRIER ring (make-async-barrier-ring) is
   deliberately NOT here: barriers are gradient-inert scheduling objects, and a barrier argument
   reaches the backward only as a :barrier key-arg, which the load/store-tile-at clauses ignore."
  (loop for b in bindings
          if (and (consp b) (= (length b) 2) (symbolp (car b))
                  (consp (cadr b)) (symbolp (caadr b))
                  (member (symbol-name (caadr b))
                          '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                            "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                            "MAKE-REGISTER-TILE"
                            "MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                            "MAKE-SCRATCH-TENSOR-RING")
                          :test #'string=))
          append (list b
                       (let* ((var (car b))
                              (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                               (or kernel-pkg (symbol-package var)))))
                         (list var-adj (%mma-ad-adj-init (cadr b)))))
          else collect b))

;; src/autodiff.lisp
(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.

   Endeavor 145 P1: INNER-DIMENSION / OUTER-DIMENSIONS are gradient-inert shape queries.
   Endeavor 145 P3b: MAKE-REGISTER-TILE is an ALLOCATOR, gradient-inert like the
   make-scratch-* constructors above it — its paired adjoint tile is created by
   %mma-ad-adj-init, not by the walk.

   Endeavor 138 rings: the SCRATCH-RING constructors are allocators exactly as their non-ring
   forms are (a ring is rank+1 scratch), and their paired adjoint rings likewise come from
   %augment-scratch-adj-bindings rather than from the walk.  The BARRIER ring is inert for a
   different reason: a barrier carries no value, only ordering.  Without these, 138/03 and
   138/06 failed with

       Function MAKE-ASYNC-BARRIER-RING is not differentiable.  Wrap the kernel in
       'forward-only' if differentiation is not needed...

   which is advice pointing away from the fix — the kernel IS differentiable; a scheduling
   object simply has no gradient.  MAKE-ASYNC-BARRIER is listed alongside it: the plain barrier
   only avoided this by never reaching the walk as a call, which is luck rather than design."
  (or (let ((name (symbol-name fn-sym)))
        (member name '("MAKE-REGISTER-TILE"
                       "MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                       "MAKE-SCRATCH-TENSOR-RING"
                       "MAKE-ASYNC-BARRIER" "MAKE-ASYNC-BARRIER-RING")
                :test #'string=))
      (%backward-skip-fn-p-145p1 fn-sym)))
