;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ===========================================================================
;;; Feature 080: Tensor / Vector / Matrix Auto-Differentiation
;;; ===========================================================================

;;; ---------------------------------------------------------------------------
;;; %crisp-tensor-type-p
;;; Returns T if TYPE-SPEC resolves to a tensor/vector/matrix storage handle.
;;; vector (N=1) and matrix (N=2) both expand to (tensor T N ...) so one check
;;; covers all three. Uses string-equal on the head symbol-name to be safe
;;; across packages.
;;; ---------------------------------------------------------------------------
;; src/autodiff.lisp
(defun %crisp-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a tensor/vector/matrix
   storage handle. Vectors (N=1) and matrices (N=2) are syntactic sugar for tensor,
   so a single head check covers all three."
  (cl:let* ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (cl:first canonical)) "TENSOR"))))

;;; ---------------------------------------------------------------------------
;;; %crisp-float-tensor-type-p
;;; Returns T only if the type is a tensor/vector/matrix AND its element type
;;; is a float type.  Non-float tensors (vector long, etc.) are not
;;; differentiable and must not receive gradient output parameters.
;;; ---------------------------------------------------------------------------
;; src/autodiff.lisp
(defun %crisp-float-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC resolves to a tensor/vector/matrix whose element type
   is a float type (float, double, etc.).  Non-float tensors (e.g. vector long)
   are not differentiable and should not receive gradient parameters."
  (cl:let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (cl:first canonical)) "TENSOR")
         (%crisp-float-type-p (cl:second canonical)))))

;;; ---------------------------------------------------------------------------
;;; %ensure-tensor-read-write
;;; Returns a copy of a tensor canonical type spec with :access forced to
;;; :read-write. Used when building gradient output tensor parameters —
;;; the backward kernel reads the accumulated gradient AND writes to it.
;;; ---------------------------------------------------------------------------
;; src/autodiff.lisp
(defun %ensure-tensor-read-write (type-spec)
  "If TYPE-SPEC is a tensor/vector/matrix, returns the canonical 6-tuple with
   :access replaced by :read-write. Non-tensor types are returned unchanged."
  (if (%crisp-tensor-type-p type-spec)
      (cl:let ((c (canonicalize-type-specifier type-spec)))
        ;; canonical form: (tensor elem N addr access align)
        ;;                   0      1    2  3    4      5
        (cl:list (cl:nth 0 c) (cl:nth 1 c) (cl:nth 2 c)
                 (cl:nth 3 c) :read-write   (cl:nth 5 c)))
      type-spec))

;;; ---------------------------------------------------------------------------
;;; %handle-single-value-backward  (extended for tensors)
;;;
;;; Change from original (src/autodiff.lisp line 25):
;;;   The ~ case now distinguishes cell reads (1 arg) from tensor reads (>1 arg).
;;;   For tensor reads where src is a known kernel input, gradient accumulation
;;;   is emitted element-wise at the same indices — no scalar adjoint involved.
;;;   A new keyword :tensor-inputs-ht (hash-table sym→type) carries that context.
;;; ---------------------------------------------------------------------------
;; src/autodiff.lisp
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr).
TENSOR-INPUTS-HT, when provided, maps kernel-input symbols to their types for
tensor inputs. When (~ src idx...) is encountered and src has an entry in this
table, gradient accumulation is emitted directly as
  (set! (~ src_GRAD idx...) (+ (~ src_GRAD idx...) adj(v)))
rather than the scalar-adjoint path used for cells."
  (cl:flet ((local-adj (x) (funcall local-adj-fn x))
            (emit (x) (funcall emit-fn x)))
    (cond
      ;; Primitive: +
      ((and (consp expr) (eq (car expr) '+))
        (cl:let ((a (cadr expr)) (b (caddr expr)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
      ;; Primitive: -
      ((and (consp expr) (eq (car expr) '-))
        (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
      ;; Primitive: *
      ((and (consp expr) (eq (car expr) '*))
        (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
      ;; Primitive: /
      ((and (consp expr) (eq (car expr) '/))
        (cl:let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
      ;; Primitive: sin
      ((and (consp expr) (eq (car expr) 'sin))
        (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (cl:let* ((a-adj (local-adj a))
                      (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
              (setf (gethash cos-a adjoint-map) cos-a)
              (emit `(set! ,cos-a (cos ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
      ;; Primitive: cos
      ((and (consp expr) (eq (car expr) 'cos))
        (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (cl:let* ((a-adj (local-adj a))
                      (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
              (setf (gethash sin-a adjoint-map) sin-a)
              (emit `(set! ,sin-a (sin ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
      ;; Cell or tensor read: ~
      ;; Distinguishes by index count:
      ;;   (~ src)          → cell read  → scalar adjoint accumulation (existing)
      ;;   (~ src idx...)   → tensor read → element-wise gradient write (new)
      ((and (consp expr) (eq (car expr) '~))
        (cl:let* ((src     (cadr expr))
                  (indices (cddr expr))
                  (v-adj   (local-adj v)))
          (when (symbolp src)
            (cond
              ;; Tensor read with a known kernel input: emit element-wise grad accumulation.
              ;; The same index expressions from the forward read are reused in the backward.
              ((and indices tensor-inputs-ht (gethash src tensor-inputs-ht))
               (cl:let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                          (symbol-package src))))
                 (emit `(set! (~ ,grad-sym ,@indices)
                              (+ (~ ,grad-sym ,@indices) ,v-adj)))))
              ;; Cell read (no indices) or tensor not in known inputs: scalar adjoint path.
              (t
               (emit `(set! ,(local-adj src) (+ ,(local-adj src) ,v-adj))))))))
      ;; Differentiable sub-function call
      ((and (consp expr)
            (symbolp (car expr))
            (gethash (car expr) *differentiable-functions*))
        (cl:let* ((fn   (car expr))
                   (args (cdr expr))
                   (info (gethash fn *differentiable-functions*)))
          (if (getf info :hof)
              (if hof-handler-fn
                  (funcall hof-handler-fn fn args v)
                  (error "HOF handler required for sub-function ~A but not provided" fn))
              (%emit-sub-fn-backward fn args
                                    (getf info :bkwd-name)
                                    (list (local-adj v))
                                    (getf info :n-float-params)
                                    (symbol-package v)
                                    emit-fn local-adj-fn
                                    (if (symbolp v) (symbol-name v) "BW")))))
      ;; Struct accessor (name ends in ~): treat like identity.
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (cl:let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~))))
        (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
      ;; Comparison/boolean ops: skip
      ((and (consp expr) (symbolp (car expr))
            (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
       nil)
      ;; If form: skip
      ((and (consp expr) (symbolp (car expr))
            (string= (symbol-name (car expr)) "IF"))
       nil)
      ;; System/integer-conversion functions: skip silently
      ((and (consp expr) (symbolp (car expr))
            (%backward-skip-fn-p (car expr)))
       nil)
      ;; Unknown user function
      ((and (consp expr) (symbolp (car expr)))
       (when error-on-unknown
         (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
      ;; Other
      (t nil))))

;;; ---------------------------------------------------------------------------
;;; generate-backward-walk  (extended for tensors)
;;;
;;; Changes from original (src/autodiff.lisp line 116):
;;;   1. Builds tensor-inputs-ht (sym→type) from inputs/input-types at entry.
;;;   2. Passes tensor-inputs-ht to all %handle-single-value-backward call sites.
;;;   3. B4 case extended: (set! (~ target idx...) val) now carries indices
;;;      through to the gradient seed read: (~ target_GRAD idx...).
;;;   4. Final emit loop: tensor inputs are skipped — per-element gradient writes
;;;      were already emitted inside the backward walk (change 2 above).
;;; ---------------------------------------------------------------------------
;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a backward ANF body (a let form).
Extended for feature 052: handles differentiable sub-function calls (B1/B2),
multi-value bindings, HOF inline backward, errors for non-differentiable
functions (B3), and mutation errors (B4).
Extended for feature 080: tensor/vector/matrix inputs — element-wise gradient
accumulation via indexed (~ src_GRAD idx...) writes."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           ;; Build tensor-inputs-ht: maps each tensor-typed input symbol to its type.
           ;; Used by %handle-single-value-backward to distinguish tensor reads from
           ;; cell reads and emit element-wise gradient accumulation.
           (tensor-inputs-ht
            (cl:let ((ht (make-hash-table :test 'eq)))
              (cl:loop for sym  in inputs
                       for typ  in input-types
                       when (%crisp-float-tensor-type-p typ)
                       do (setf (gethash sym ht) typ))
              ht)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))

             ;; HOF inline backward: substitute concrete fn, remove funcall,
             ;; ANF-transform the concrete body, process backwards using
             ;; the kernel's own closures.
             (hof-inline-backward (fn args v)
               (cl:let* ((hof-data (gethash fn *differentiable-hof-store*)))
                 (unless hof-data
                   (error "HOF ~A not found in *differentiable-hof-store*" fn))
                 (cl:let* ((param-syms   (getf hof-data :param-syms))
                           (fn-param-idx (getf hof-data :fn-param-idx))
                           (body-forms   (getf hof-data :body-forms))
                           (fn-arg       (nth fn-param-idx args))
                           (concrete-fn  (cond
                                           ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                            (cadr fn-arg))
                                           ((symbolp fn-arg) fn-arg)
                                           (t nil))))
                   (unless concrete-fn
                     (error "Cannot inline-differentiate HOF ~A: ~
                             could not resolve concrete fn from arg ~A" fn fn-arg))
                   (cl:let* ((fn-param      (nth fn-param-idx param-syms))
                             (subst-alist
                              (cl:loop for p in param-syms
                                       for a in args
                                       for i from 0
                                       unless (= i fn-param-idx)
                                       collect (cons p a)))
                             (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                             (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                    subst-body))
                             (anf-body      (mapcar #'anf-transform concrete-body))
                             (hof-flat      (flatten-anf-body anf-body))
                             (hof-flat-norm
                              (cl:let ((last-f (cl:car (cl:last hof-flat))))
                                (if (or (symbolp last-f)
                                        (and (consp last-f) (eq (cl:first last-f) 'return)))
                                    hof-flat
                                    (cl:let ((ret-sym (intern (format nil "%HOF_RET_%A" (symbol-name v))
                                                               (symbol-package v))))
                                      (append (butlast hof-flat)
                                              (list (list ret-sym last-f) ret-sym))))))
                             (return-vars   (%extract-return-vars hof-flat-norm)))
                     (cl:dolist (rv return-vars)
                       (setf (gethash rv adjoint-map) (local-adj v)))
                     ;; HOF body has no tensor kernel inputs — pass nil for tensor-inputs-ht.
                     (cl:dolist (hf-form (cl:reverse hof-flat-norm))
                       (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                         (cl:let ((hv    (car hf-form))
                                  (hexpr (cadr hf-form)))
                           (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                          :hof-handler-fn #'hof-inline-backward
                                                          :error-on-unknown t
                                                          :tensor-inputs-ht nil))))))))

             ) ; end labels binding list

      (cl:let ((reversed-body (reverse flat-anf)))
        (cl:dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                               :hof-handler-fn #'hof-inline-backward
                                               :error-on-unknown t
                                               :tensor-inputs-ht tensor-inputs-ht)))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn   (car expr))
                             (args (cdr expr))
                             (info (gethash fn *differentiable-functions*))
                             (bkwd (getf info :bkwd-name))
                             (n-fp (getf info :n-float-params))
                             (pkg  (symbol-package (car result-vars)))
                             (t-adjs (mapcar #'local-adj result-vars)))
                    (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg #'emit #'local-adj "BW")))))

            ;; ---- B4: set! on a storage handle ----------------------
            ;; Handles both cell writes (~ target) and tensor writes (~ target idx...).
            ;; For outputs: seed adj(val) from the output gradient tensor/cell.
            ;; For inputs:  error — inputs may not be mutated in a differentiable kernel.
            ((and (consp form) (eq (car form) 'set!))
              (cl:let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (cl:let ((target  (cadr place))
                           (indices (cddr place)))   ; nil for cell, (i...) for tensor
                    (cond
                      ((member target outputs)
                       (cl:let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                  (symbol-package target))))
                         ;; Seed adj(val) from the output gradient at the same indices.
                         ;; For cells: (~ tgt-grad) — no indices.
                         ;; For tensors: (~ tgt-grad idx...) — same indices as forward write.
                         (emit `(set! ,(local-adj val)
                                      (+ ,(local-adj val) (~ ,tgt-grad ,@indices))))))
                      ((member target inputs)
                       (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                              target target))
                      (t nil))))))

            ;; ---- Everything else: skip ----------------------------
            (t nil))))

      ;; Emit gradient output writes for all inputs.
      ;; Tensor inputs: SKIP — per-element writes were already emitted in the
      ;;   ~ case of %handle-single-value-backward when tensor-inputs-ht was consulted.
      ;; Cell inputs:   (set! (~ in_GRAD) adj(in))
      ;; Float scalar:  (set! in_GRAD adj(in))
      (cl:loop for in in inputs
               for in-type in input-types do
                 (cl:let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                               (symbol-package in)))
                           (canon-type (canonicalize-type-specifier
                                         (if (listp in-type) in-type (list in-type))))
                           (is-cell    (and (consp canon-type)
                                            (string-equal (symbol-name (cl:first canon-type)) "CELL")))
                           (is-tensor  (%crisp-float-tensor-type-p in-type)))
                   (cond
                     (is-tensor nil)  ; per-element writes already done
                     (is-cell   (emit `(set! (~ ,in-grad) ,(local-adj in))))
                     (t         (emit `(set! ,in-grad ,(local-adj in)))))))

      (cl:let* ((local-bindings (cl:loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv 0.0)))
                (result `(let ,local-bindings
                            ,@(nreverse backward-forms))))
        result))))

;;; ---------------------------------------------------------------------------
;;; %compute-backward-kernel-params  (extended for tensors)
;;;
;;; Changes from original (src/macros.lisp line 536):
;;;   1. non-rec-scalar-in-grad-params: integer scalar inputs (ulong idx etc.)
;;;      are now excluded. Only float scalars and tensor/vector/matrix inputs
;;;      receive _GRAD output parameters. This prevents type-mismatch errors
;;;      from (set! idx_GRAD 0.0) in the backward body.
;;;   2. non-rec-scalar-in-grad-types: tensor gradient types are forced to
;;;      :access :read-write via %ensure-tensor-read-write (backward both reads
;;;      and writes the gradient tensor).
;;;   3. diff-flat-inputs / diff-flat-input-types: same differentiability filter
;;;      as (1) — integer scalars are excluded so the final emit loop in
;;;      generate-backward-walk never attempts to write an integer adjoint.
;;; ---------------------------------------------------------------------------
;; src/macros.lisp
(defun %compute-backward-kernel-params (flat-inputs flat-input-types outputs output-types
                                        record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
  "Computes the parameter lists and type lists for the backward (gradient) kernel.
Extended for feature 080: filters integer scalar inputs from gradient outputs,
and ensures tensor gradient outputs have :access :read-write."
  (cl:let* ((record-exploded-syms
             (cl:loop for orig in inputs
                      append (cl:let ((flds (gethash orig record-subs-ht)))
                               (when flds (mapcar #'cdr flds)))))

            ;; Differentiability predicate for a non-record-exploded input.
            ;; Only float scalars and float tensor/vector/matrix inputs get _GRAD outputs.
            ;; Integer scalars (ulong row, ulong col, etc.) and non-float tensors do not.
            (differentiable-non-rec-p
             (lambda (t-spec)
               (or (%crisp-float-type-p t-spec)
                   (%crisp-float-tensor-type-p t-spec))))

            (non-rec-scalar-in-grad-params
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall differentiable-non-rec-p t-spec)))
                      collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

            ;; Tensor gradient outputs must be :read-write — the backward kernel
            ;; reads the current accumulated value and adds to it.
            (non-rec-scalar-in-grad-types
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall differentiable-non-rec-p t-spec)))
                      collect (%ensure-tensor-read-write t-spec)))

            (all-grad-out-params (append rec-grad-out-params non-rec-scalar-in-grad-params))
            (all-grad-out-types  (append rec-grad-out-types  non-rec-scalar-in-grad-types))
            (out-grads
             (cl:loop for p in outputs
                      collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
            (bwd-params (append flat-inputs outputs out-grads
                                (when all-grad-out-params (list '&out))
                                all-grad-out-params))
            (bwd-types  (append flat-input-types output-types output-types
                                (when all-grad-out-params (list '&out))
                                all-grad-out-types))

            ;; diff-flat-inputs: the inputs that generate-backward-walk should process.
            ;; For record-exploded syms: only float fields (unchanged).
            ;; For others: only float scalars and tensors — integer scalars excluded.
            (diff-flat-inputs
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      when (if (member p record-exploded-syms :test #'eq)
                               (%crisp-float-type-p t-spec)
                               (funcall differentiable-non-rec-p t-spec))
                      collect p))
            (diff-flat-input-types
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      when (if (member p record-exploded-syms :test #'eq)
                               (%crisp-float-type-p t-spec)
                               (funcall differentiable-non-rec-p t-spec))
                      collect t-spec)))
    (values bwd-params bwd-types diff-flat-inputs diff-flat-input-types)))

