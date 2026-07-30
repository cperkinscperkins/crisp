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

;;; ===================================================================
;;; Endeavor 145 (P8) — matrix-multiply-tile-stride must be pre-lowered for AD.
;;;
;;; The FORWARD path lowers this macro in analyze-let-with-tile-explosion
;;; (%expand-matmul-tile-stride-register-forms).  The AD path has its own pre-pass —
;;; %expand-stride-macros-in-form, endeavor 107 — which knows TENSOR-STRIDE / GRID-STRIDE /
;;; LOOP-VECTOR-STRIDE / TILE-STRIDE / HARDWARE-STRIDE / WORKGROUP-STRIDE, but NOT the
;;; endeavor-135 matmul macro.  So it survived into ANF, where it was treated as an ordinary
;;; function call and comprehensively mangled — the BINDING-NAME LIST became a call:
;;;
;;;   (%ANF-T-1 (GRID-Y GRID-X GRID-K))                       <- "Function GRID-Y ..."
;;;   (%ANF-T-2 (LOAD-TILE-AT A A-TILE ...))                  <- body hoisted OUT of the loop
;;;   (MATRIX-MULTIPLY-TILE-STRIDE C C-TILE K 16 %ANF-T-1 ... :EPILOGUE %ANF-T-7)
;;;
;;; i.e. every body form hoisted out of the very loop that binds grid-y/grid-x/grid-k.  Lowering
;;; it before ANF — exactly as the forward does before analysis — makes the whole multi-workgroup
;;; matmul just a tile-stride + dotimes the walk already understands.
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-ad-expand-mmts-in-form (form reg-map)
  "Recursively lower every matrix-multiply-tile-stride in FORM to its tile-stride + K-loop
   expansion.  The tile-spec is the compile-time (M N) for a REGISTER C-tile (from REG-MAP,
   which is what the SROA explosion needs to see) and the tile tensor itself otherwise —
   matching the two forward paths in src/mma.lisp and src/analysis/control.lisp respectively."
  (cond
    ((not (consp form)) form)
    ((%mmts-head-p form)
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form nil)
       (%mmts-lower c-form c-tile
                    (or (cdr (assoc c-tile reg-map)) c-tile)
                    k-form k-step gy gx gk
                    (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) body)
                    nil)))
    (t (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) form))))

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

                                    (t nil))))

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
   ((%is-accessor-p expr)
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
   ((and (consp expr) (symbolp (car expr))
         (%backward-skip-fn-p (car expr)))
     nil)
   ;; Endeavor 120: gradient-inert calls.
   ;;  - *inert-functions*: user functions with no differentiable params
   ;;    (zero gradient), recorded by %generate-backward-function-ast.
   ;;  - the compile-time uniformity intrinsics, which fold to constants and
   ;;    carry no gradient.
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
