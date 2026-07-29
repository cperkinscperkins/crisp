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


