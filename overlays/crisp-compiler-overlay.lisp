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
(defun %backward-skip-fn-p (fn-sym)
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
  (let ((mv-bindings (%collect-multi-value-anf-bindings anf-body)))
    (loop for form in flat-anf
            when (or (and (consp form) (= (length form) 2) (symbolp (car form)))
                     (member form mv-bindings :test #'eq))
          collect form)))

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
               (expanded-body
                (mapcar (lambda (form)
                          (%expand-stride-macros-in-form form kernel-type-resolver nil))
                    subst-body)))
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
                           (forward-bindings (%collect-forward-primal-bindings flat-anf anf-body))
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
