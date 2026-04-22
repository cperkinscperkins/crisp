;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)



(defun %emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg emit-fn local-adj-fn &optional (sym-prefix "BW"))
  (declare (ignore fn))
  (let* ((deltas (loop for i from 0 below n-fp
                             collect (intern (format nil "%~A_D~a" sym-prefix i) pkg)))
            (accum-forms
             (loop for arg in args
                      for i from 0 below n-fp
                      when (symbolp arg)
                      collect `(set! ,(funcall local-adj-fn arg)
                                     (+ ,(funcall local-adj-fn arg) ,(nth i deltas))))))
    (when accum-forms
      (funcall emit-fn `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                          (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                            ,@accum-forms))))))



(defun %crisp-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a tensor/vector/matrix
   storage handle. Vectors (N=1) and matrices (N=2) are syntactic sugar for tensor,
   so a single head check covers all three."
  (let* ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR"))))

(defun %crisp-float-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC resolves to a tensor/vector/matrix whose element type
   is a float type (float, double, etc.).  Non-float tensors (e.g. vector long)
   are not differentiable and should not receive gradient parameters."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR")
         (%crisp-float-type-p (second canonical)))))

(defun %ensure-tensor-read-write (type-spec)
  "If TYPE-SPEC is a tensor/vector/matrix, returns the canonical 6-tuple with
   :access replaced by :read-write. Non-tensor types are returned unchanged."
  (if (%crisp-tensor-type-p type-spec)
      (let ((c (canonicalize-type-specifier type-spec)))
        ;; canonical form: (tensor elem N addr access align)
        ;;                   0      1    2  3    4      5
        (list (nth 0 c) (nth 1 c) (nth 2 c)
                 (nth 3 c) :read-write   (nth 5 c)))
      type-spec))


(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr).
TENSOR-INPUTS-HT, when provided, maps kernel-input symbols to their types for
tensor inputs. When (~ src idx...) is encountered and src has an entry in this
table, gradient accumulation is emitted directly as
  (set! (~ src_GRAD idx...) (+ (~ src_GRAD idx...) adj(v)))
rather than the scalar-adjoint path used for cells."
  (flet ((local-adj (x) (funcall local-adj-fn x))
            (emit (x) (funcall emit-fn x)))
    (cond
      ;; Primitive: +
      ((and (consp expr) (eq (car expr) '+))
        (let ((a (cadr expr)) (b (caddr expr)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
      ;; Primitive: -
      ((and (consp expr) (eq (car expr) '-))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
      ;; Primitive: *
      ((and (consp expr) (eq (car expr) '*))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
      ;; Primitive: /
      ((and (consp expr) (eq (car expr) '/))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
      ;; Primitive: sin
      ((and (consp expr) (eq (car expr) 'sin))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                      (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
              (setf (gethash cos-a adjoint-map) cos-a)
              (emit `(set! ,cos-a (cos ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
      ;; Primitive: cos
      ((and (consp expr) (eq (car expr) 'cos))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                      (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
              (setf (gethash sin-a adjoint-map) sin-a)
              (emit `(set! ,sin-a (sin ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
      ;; Cell or tensor read: ~
      ;; Distinguishes by index count:
      ;;   (~ src)          → cell read  → scalar adjoint accumulation (existing)
      ;;   (~ src idx...)   → tensor read → element-wise gradient write (new)
      ((and (consp expr) (eq (car expr) '~))
        (let* ((src     (cadr expr))
                  (indices (cddr expr))
                  (v-adj   (local-adj v)))
          (when (symbolp src)
            (cond
              ;; Tensor read with a known kernel input: emit element-wise grad accumulation.
              ;; The same index expressions from the forward read are reused in the backward.
              ((and indices tensor-inputs-ht (gethash src tensor-inputs-ht))
               (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
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
        (let* ((fn   (car expr))
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
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~))))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
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





(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a backward ANF body (a let form).
Extended for feature 052: handles differentiable sub-function calls (B1/B2),
multi-value bindings, HOF inline backward, errors for non-differentiable
functions (B3), and mutation errors (B4).
Extended for feature 080: tensor/vector/matrix inputs — element-wise gradient
accumulation via indexed (~ src_GRAD idx...) writes."
  (let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           ;; Build tensor-inputs-ht: maps each tensor-typed input symbol to its type.
           ;; Used by %handle-single-value-backward to distinguish tensor reads from
           ;; cell reads and emit element-wise gradient accumulation.
           (tensor-inputs-ht
            (let ((ht (make-hash-table :test 'eq)))
              (loop for sym  in inputs
                       for typ  in input-types
                       when (%crisp-float-tensor-type-p typ)
                       do (setf (gethash sym ht) typ))
              ht)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))

             ;; HOF inline backward: substitute concrete fn, remove funcall,
             ;; ANF-transform the concrete body, process backwards using
             ;; the kernel's own closures.
             (hof-inline-backward (fn args v)
               (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                 (unless hof-data
                   (error "HOF ~A not found in *differentiable-hof-store*" fn))
                 (let* ((param-syms   (getf hof-data :param-syms))
                           (fn-param-idx (getf hof-data :fn-param-idx))
                           (body-forms   (getf hof-data :body-forms))
                           (fn-arg       (nth fn-param-idx args))
                           (concrete-fn  (cond
                                           ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                            (cadr fn-arg))
                                           ((symbolp fn-arg) fn-arg)
                                           (t nil))))
                   (unless concrete-fn
                     (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                   (let* ((fn-param      (nth fn-param-idx param-syms))
                             (subst-alist
                              (loop for p in param-syms
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
                              (let ((last-f (car (last hof-flat))))
                                (if (or (symbolp last-f)
                                        (and (consp last-f) (eq (first last-f) 'return)))
                                    hof-flat
                                    (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                               (symbol-package v))))
                                      (append (butlast hof-flat)
                                              (list (list ret-sym last-f) ret-sym))))))
                             (return-vars   (%extract-return-vars hof-flat-norm)))
                     (dolist (rv return-vars)
                       (setf (gethash rv adjoint-map) (local-adj v)))
                     ;; HOF body has no tensor kernel inputs — pass nil for tensor-inputs-ht.
                     (dolist (hf-form (reverse hof-flat-norm))
                       (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                         (let ((hv    (car hf-form))
                                  (hexpr (cadr hf-form)))
                           (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                          :hof-handler-fn #'hof-inline-backward
                                                          :error-on-unknown t
                                                          :tensor-inputs-ht nil))))))))

             ) ; end labels binding list

      (let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (let ((v    (car form))
                       (expr (cadr form)))
                (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                               :hof-handler-fn #'hof-inline-backward
                                               :error-on-unknown t
                                               :tensor-inputs-ht tensor-inputs-ht)))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (let* ((fn   (car expr))
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
              (let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (let ((target  (cadr place))
                           (indices (cddr place)))   ; nil for cell, (i...) for tensor
                    (cond
                      ((member target outputs)
                       (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
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
      (loop for in in inputs
               for in-type in input-types do
                 (let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                               (symbol-package in)))
                           (canon-type (canonicalize-type-specifier
                                         (if (listp in-type) in-type (list in-type))))
                           (is-cell    (and (consp canon-type)
                                            (string-equal (symbol-name (first canon-type)) "CELL")))
                           (is-tensor  (%crisp-float-tensor-type-p in-type)))
                   (cond
                     (is-tensor nil)  ; per-element writes already done
                     (is-cell   (emit `(set! (~ ,in-grad) ,(local-adj in))))
                     (t         (emit `(set! ,in-grad ,(local-adj in)))))))

      (let* ((local-bindings (loop for v being the hash-keys of adjoint-map
                                         using (hash-value adv)
                                         collect `(,adv 0.0)))
                (result `(let ,local-bindings
                            ,@(nreverse backward-forms))))
        result))))



;;; ----------------------------------------------------------
;;; %crisp-float-type-p
;;; ----------------------------------------------------------

(defun %crisp-float-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp
float-category scalar type (float, double, half, bfloat16).
Checks *crisp-types* directly first (for primitives like 'float),
then falls back to compute-base-type for derived/alias types."
  (let* ((direct-info (and (symbolp type-spec) (gethash type-spec *crisp-types*)))
            (base (if direct-info type-spec (compute-base-type type-spec)))
            (info (when base (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :float))))

;;; ----------------------------------------------------------
;;; %crisp-record-type-p
;;; ----------------------------------------------------------

(defun %crisp-record-type-p (type-spec)
  "Returns T if TYPE-SPEC names a def-record (category :record).
   Handles parameterized forms like (V-POINT :EARNESTNESS 3.0)."
  (let* ((base (if (consp type-spec) (first type-spec) type-spec))
             (info (gethash base *crisp-types*)))
    (and info (eq (crisp-type-category info) :record))))

;;; ----------------------------------------------------------
;;; %get-record-runtime-fields
;;; ----------------------------------------------------------

(defun %get-record-runtime-fields (rec-type-spec)
  "Returns a list of (FIELD-NAME RESOLVED-FIELD-TYPE) for the runtime
   (non-:c-t) members of the record type named by REC-TYPE-SPEC.
   Handles parameterised forms like (V-POINT :EARNESTNESS 3.0)."
  (let* ((base (if (consp rec-type-spec) (first rec-type-spec) rec-type-spec))
             (struct-def (or (gethash base *crisp-structs*)
                             (gethash (intern (symbol-name base) :crisp-language)
                                      *crisp-structs*))))
    (when struct-def
      (loop for m in (crisp-struct-definition-members struct-def)
               unless (and (consp m) (eq (third m) :c-t))
               collect (list (first m)
                                 (compute-base-type (second m)))))))

;;; ----------------------------------------------------------
;;; %record-accessor-system-generated-p
;;; ----------------------------------------------------------

(defun %record-accessor-system-generated-p (accessor-sym rec-type)
  "Returns T if ACCESSOR-SYM (e.g. X~) is the single system-generated
   accessor for REC-TYPE — i.e. it has NOT been user-overloaded.
   Heuristic: count *function-table* entries whose first parameter type
   matches REC-TYPE.  Exactly 1 means system-generated only."
  (let* ((sigs (gethash accessor-sym *function-table*))
             (base-name (symbol-name (if (consp rec-type) (first rec-type) rec-type)))
             (matching
              (loop for sig in sigs
                       when (let* ((params (function-signature-parameters sig))
                                      (first-param (first params))
                                      (first-type (and first-param
                                                        (parameter-def-type first-param))))
                              (and first-type
                                   (string-equal (symbol-name
                                                  (if (consp first-type)
                                                      (first first-type)
                                                      first-type))
                                                 base-name)))
                       collect sig)))
    (= (length matching) 1)))

;;; ----------------------------------------------------------
;;; %record-field-param-sym
;;; ----------------------------------------------------------

(defun %record-field-param-sym (param-sym field-name pkg)
  "Creates the exploded scalar symbol for PARAM-SYM's FIELD-NAME.
   E.g. VP + X -> VP_X."
  (intern (format nil "~a_~a"
                  (symbol-name param-sym)
                  (symbol-name field-name))
          pkg))

;;; ----------------------------------------------------------
;;; %substitute-record-accessors
;;; ----------------------------------------------------------

(defun %substitute-record-accessors (form record-subs-ht record-type-ht)
  "Recursively walks FORM (a raw Crisp body S-expression) and substitutes:
     (~field~ p)  -> p_field   (always, ~field~ is non-overloadable)
     (field~  p)  -> p_field   (only when field~ is system-generated for p's type)
   RECORD-SUBS-HT maps param-sym -> alist of (field-sym . exploded-sym).
   RECORD-TYPE-HT  maps param-sym -> rec-type-spec."
  (flet ((raw-accessor-p (name-str)
               ;; ~field~ : starts AND ends with ~, length > 2
               (and (> (length name-str) 2)
                    (cl:char= (cl:char name-str 0) #\~)
                    (cl:char= (cl:char name-str (1- (length name-str))) #\~)))
             (regular-accessor-p (name-str)
               ;; field~ : ends with ~ but does NOT start with ~
               (and (> (length name-str) 1)
                    (cl:char= (cl:char name-str (1- (length name-str))) #\~)
                    (cl:char/= (cl:char name-str 0) #\~))))
    (cond
      ;; ---- Atom: pass through --------------------------------
      ((atom form) form)

      ;; ---- (~field~ p) : raw accessor call -------------------
      ((and (= (length form) 2)
            (symbolp (first form))
            (raw-accessor-p (symbol-name (first form))))
       (let* ((op-name  (symbol-name (first form)))
                 (field-name (intern (subseq op-name 1 (1- (length op-name)))
                                     (symbol-package (first form))))
                 (arg     (second form))
                 (fld-map (gethash arg record-subs-ht)))
         (if fld-map
             (let ((hit (assoc field-name fld-map :test #'string-equal)))
               (if hit (cdr hit) form))
             ;; arg is not a record param — recurse normally
             (list (first form)
                      (%substitute-record-accessors arg record-subs-ht record-type-ht)))))

      ;; ---- (field~ p) : regular accessor call ----------------
      ((and (= (length form) 2)
            (symbolp (first form))
            (regular-accessor-p (symbol-name (first form))))
       (let* ((op      (first form))
                 (op-name (symbol-name op))
                 (field-name (intern (subseq op-name 0 (1- (length op-name)))
                                     (symbol-package op)))
                 (arg     (second form))
                 (fld-map (gethash arg record-subs-ht))
                 (rec-type (gethash arg record-type-ht)))
         (if (and fld-map rec-type
                  (%record-accessor-system-generated-p op rec-type))
             (let ((hit (assoc field-name fld-map :test #'string-equal)))
               (if hit (cdr hit)
                   ;; field name not in this record — recurse
                   (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form)))
             ;; not system-generated, or arg not a record param — recurse
             (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form))))

      ;; ---- General cons: recurse on all sub-forms ------------
      (t
       (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form)))))

;;; ----------------------------------------------------------
;;; %fix-record-grad-cell-emissions
;;; ----------------------------------------------------------

(defun %fix-record-grad-cell-emissions (form grad-cell-syms)
  "Post-processes the backward-walk output.
   For any (SET! var expr) where VAR is in GRAD-CELL-SYMS,
   rewrites to (SET! (~ var) expr), since the gradient output
   for a record field is a cell, not a plain scalar.
   GRAD-CELL-SYMS is a list of symbols that need cell-style emission."
  (flet ((grad-cell-p (sym)
               (and (symbolp sym) (member sym grad-cell-syms :test #'eq))))
    (cond
      ((atom form) form)
      ;; (set! var expr) — var is a grad-cell sym
      ((and (consp form)
            (eq (first form) 'set!)
            (= (length form) 3)
            (grad-cell-p (second form)))
       (list 'set!
                (list '~ (second form))
                (%fix-record-grad-cell-emissions (third form) grad-cell-syms)))
      ;; recurse
      (t
       (mapcar (lambda (x) (%fix-record-grad-cell-emissions x grad-cell-syms)) form)))))

;;; ----------------------------------------------------------
;;; %expand-record-kernel-inputs
;;; ----------------------------------------------------------

(defun %expand-record-kernel-inputs (inputs input-types pkg)
  "Expands record-typed inputs into their scalar fields.
   Returns (values flat-inputs flat-input-types
                   reassembly-bindings
                   grad-out-params grad-out-types
                   record-subs-ht record-type-ht
                   grad-cell-syms).

   flat-inputs / flat-input-types : record params replaced by scalar field params.
   reassembly-bindings : let-bindings to reconstruct each record from its fields.
   grad-out-params / grad-out-types : gradient cell output params (float fields only).
   record-subs-ht : param-sym -> alist (field-sym . exploded-sym).
   record-type-ht  : param-sym -> rec-type-spec.
   grad-cell-syms  : list of _GRAD symbols that need (set! (~ ..) adj) emission."
  (let ((flat-inputs        '())
           (flat-input-types   '())
           (reassembly-bindings '())
           (grad-out-params    '())
           (grad-out-types     '())
           (record-subs-ht     (make-hash-table :test 'eq))
           (record-type-ht     (make-hash-table :test 'eq))
           (grad-cell-syms     '()))

    (loop for p in inputs
             for t-spec in input-types do
      (if (%crisp-record-type-p t-spec)
          ;; --- Record input: explode to scalar fields ---------
          (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                    (fields    (%get-record-runtime-fields t-spec))
                    (make-sym  (intern (format nil "MAKE-~a" (symbol-name base-type)) pkg))
                    (field-syms
                     (loop for (fname ftype) in fields
                              collect (list fname
                                               ftype
                                               (%record-field-param-sym p fname pkg)))))
            ;; Register for substitution
            (setf (gethash p record-subs-ht)
                  (loop for (fname ftype fsym) in field-syms
                           collect (cons fname fsym)))
            (setf (gethash p record-type-ht) t-spec)
            ;; Flat scalar params
            (loop for (fname ftype fsym) in field-syms do
              (push fsym flat-inputs)
              (push ftype flat-input-types))
            ;; Reassembly binding: (p (make-base-type :field0 f0 :field1 f1 ...))
            ;; Uses keyword args to match the def-record constructor signature.
            (push (list p (cons make-sym
                                   (loop for (fname ftype fsym) in field-syms
                                            append (list (intern (symbol-name fname) :keyword)
                                                         fsym))))
                  reassembly-bindings)
            ;; Gradient cell outputs — float fields only
            (loop for (fname ftype fsym) in field-syms do
              (when (%crisp-float-type-p ftype)
                (let ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg)))
                  (push grad-sym grad-out-params)
                  (push '(cell float :address-space :global :access :read-write) grad-out-types)
                  (push grad-sym grad-cell-syms)))))

          ;; --- Non-record input: pass through as-is -----------
          (progn
            (push p flat-inputs)
            (push t-spec flat-input-types))))

    (values (nreverse flat-inputs)
            (nreverse flat-input-types)
            (nreverse reassembly-bindings)
            (nreverse grad-out-params)
            (nreverse grad-out-types)
            record-subs-ht
            record-type-ht
            (nreverse grad-cell-syms))))




(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.
Skips: system-generated functions (name contains %), AS/AS-* type casts and
derived-type coercions, and TO-<int-type> integer conversions."
  (let ((name (symbol-name fn-sym)))
    (or
     (find #\% name)
     (string= name "AS")
     (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
     (loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
              when (and (>= (length name) (+ 3 (length suffix)))
                        (string= (subseq name 0 3) "TO-")
                        (string= (subseq name (- (length name) (length suffix))) suffix))
              return t))))



(defun %generate-backward-function-ast (name params declarations body-forms)
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable
user function. Also registers the function in *differentiable-functions*.

For HOF functions (those with a function-type parameter), stores info in
*differentiable-hof-store* and registers with :hof t. Returns NIL for HOFs
since no separate _GRAD function is generated — the backward is inlined at
the kernel call site.

If the function body contains non-differentiable operations, the backward
companion is not generated, the function is unregistered from
*differentiable-functions*, and NIL is returned. If a kernel later calls this
function in a differentiable context, compilation will error at that point.

Returns the backward def-function form, or NIL if the function has no
differentiable float params, is a HOF, or cannot be differentiated."
  (let* ((pkg (symbol-package name)))

    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)

      (let* (;; Float-typed params (the differentiable ones)
                (float-param-entries
                 (loop for pd in env
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-float-type-p (parameter-def-type pd)))
                          collect pd))
                (float-param-syms  (mapcar #'parameter-def-name float-param-entries))
                (n-float-params    (length float-param-syms))
                ;; Filter out nil (void) return types — void fns have no t-grad inputs.
                (return-types-non-void (remove nil return-types))
                (n-return          (length return-types-non-void))

                ;; HOF detection: any param has a function type?
                (fn-param-entries
                 (loop for pd in env
                          for i from 0
                          when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                    (%crisp-function-type-p (parameter-def-type pd)))
                          collect (cons i pd)))
                (is-hof (consp fn-param-entries)))

        ;; If no differentiable params, nothing to do.
        (when (zerop n-float-params)
          (log:info "AUTODIFF: ~a has no float params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        ;; If HOF: store info and register with :hof t. No _GRAD function generated.
        (when is-hof
          (let* ((fn-param-idx  (car (car fn-param-entries)))
                    (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                    ;; Strip any trailing source-location atom from body-forms
                    (clean-body    (loop for f in body-forms
                                            unless (and (atom f) (not (symbolp f)))
                                            collect f)))
            (log:info "AUTODIFF: ~a is HOF (fn-param=~a idx=~a) — storing for inline backward"
                      name fn-param-sym fn-param-idx)
            (setf (gethash name *differentiable-hof-store*)
                  (list :param-syms       (loop for pd in env
                                                   collect (parameter-def-name pd))
                        :fn-param-idx     fn-param-idx
                        :fn-param-sym     fn-param-sym
                        :float-param-syms float-param-syms
                        :body-forms       clean-body))
            (setf (gethash name *differentiable-functions*)
                  (list :hof t
                        :n-float-params n-float-params
                        :n-return n-return))
            (return-from %generate-backward-function-ast nil)))

        ;; Non-HOF: attempt backward function generation.
        ;; If the body contains non-differentiable operations, catch the error,
        ;; unregister the function, and return nil. The kernel backward walk
        ;; will error if this function is actually called in a diff context.
        (let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
                  (t-grad-syms (loop for i from 0 below n-return
                                        collect (intern (format nil "T_GRAD~A" i) pkg)))
                  (orig-param-types (mapcar #'parameter-def-type env))
                  (t-grad-types return-types-non-void)
                  (bkwd-params (append params t-grad-syms))
                  (bkwd-fn-spec
                   `(function (,@orig-param-types ,@t-grad-types
                               => ,@(make-list n-float-params :initial-element 'float)))))

          (setf (gethash name *differentiable-functions*)
                (list :bkwd-name bkwd-name
                      :n-float-params n-float-params
                      :n-return n-return))

          (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-fp=~a n-ret=~a)"
                    bkwd-name name n-float-params n-return)

          (handler-case
            (let* ((anf-body   (mapcar #'anf-transform body-forms))
                      (raw-flat   (flatten-anf-body anf-body))
                      (flat-anf
                       (let ((last-f (car (last raw-flat))))
                         (if (or (symbolp last-f)
                                 (and (consp last-f) (eq (first last-f) 'return)))
                             raw-flat
                             (let ((ret-sym (intern "%RET-0" pkg)))
                               (append (butlast raw-flat)
                                       (list (list ret-sym last-f)
                                             ret-sym))))))
                      (return-vars (%extract-return-vars flat-anf))
                      (bkwd-body  (progn
                                    (%check-fn-body-for-mutations body-forms
                                                                  (mapcar #'parameter-def-name env)
                                                                  name)
                                    (%generate-backward-function-walk
                                     flat-anf float-param-syms t-grad-syms return-vars))))

              `(def-function ,bkwd-name ,bkwd-params
                 (declare #'(,@(second bkwd-fn-spec)))
                 ,bkwd-body))

            (error (e)
              (log:info "AUTODIFF: ~a — cannot generate _GRAD: ~a. Unregistering; will error if called from a differentiable kernel." name e)
              (remhash name *differentiable-functions*)
              nil)))))))




(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars)
  "Generates the backward-pass body for a def-function.
FLAT-ANF         : flattened ANF of the forward function body.
FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).
T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).
RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).
Returns a (let (...) ...) form suitable as the body of the _GRAD companion function."
  (let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           (return-var-seeds (make-hash-table :test 'eq)))

    ;; Map each return-var to its t_grad seed
    (loop for rv in return-vars
             for tg in t-grad-syms do
      (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (let ((v    (car form))
                       (expr (cadr form)))
                (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                               :error-on-unknown t)))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (let* ((fn      (car expr))
                             (args    (cdr expr))
                             (info    (gethash fn *differentiable-functions*))
                             (bkwd-fn (getf info :bkwd-name))
                             (n-fp    (getf info :n-float-params))
                             (n-ret   (getf info :n-return))
                             (pkg     (symbol-package fn)))
                        (%emit-sub-fn-backward fn args bkwd-fn (mapcar #'local-adj result-vars) n-fp pkg #'emit #'local-adj "MV")))))

            ;; ---- (return ...) or plain symbol: skip ---------------
            (t nil))))

    ;; Emit the return of float-param adjoints
    (emit `(return ,@(mapcar #'local-adj float-param-syms)))

    ;; Build local bindings:
    ;;   - forward single-value bindings from flat-anf (so temps like %ANF-T-3 are in scope)
    ;;   - return-var adjoints: initialised to their t_grad seed
    ;;   - all other adjoints: initialised to 0.0
    (let* ((forward-bindings
               (loop for form in flat-anf
                        when (and (consp form)
                                  (= (length form) 2)
                                  (symbolp (car form))
                                  (not (gethash (car form) return-var-seeds)))
                        collect form))
              (adjoint-bindings
               (loop for v being the hash-keys of adjoint-map
                        using (hash-value adv)
                        collect (let ((seed (gethash v return-var-seeds)))
                                  `(,adv ,(if seed seed 0.0)))))
              (all-bindings (append forward-bindings adjoint-bindings)))
      `(let ,all-bindings
         ,@(nreverse backward-forms)))))
)




(defun %check-fn-body-for-mutations (body-forms param-names fn-name)
  "Walks BODY-FORMS looking for (set! (~ p) ...) where p is in PARAM-NAMES.
Signals a compiler error if any mutation is detected, naming FN-NAME."
  (labels ((walk (form)
             (when (consp form)
               (when (and (eq (first form) 'set!)
                          (consp (second form))
                          (eq (first (second form)) '~)
                          (symbolp (second (second form)))
                          (member (second (second form)) param-names :test #'string-equal))
                 (error "Cannot differentiate function ~A: it mutates parameter ~A via cell write (set! (~~ ~A) ...). This function is not valid in a differentiable kernel."
                        fn-name
                        (second (second form))
                        (second (second form))))
               (mapc #'walk (rest form)))))
    (mapc #'walk body-forms)))




(defun %crisp-function-type-p (type-spec)
  "Returns T if TYPE-SPEC is a parsed :function-type or :function-literal specifier."
  (and (consp type-spec)
       (or (eq (first type-spec) :function-type)
           (eq (first type-spec) :function-literal))))


(defun %subst-form (form subst-alist)
  "Recursively substitute atoms in FORM according to SUBST-ALIST (list of (sym . replacement))."
  (cond
    ((null form) nil)
    ((atom form)
     (let ((pair (assoc form subst-alist)))
       (if pair (cdr pair) form)))
    (t (cons (%subst-form (car form) subst-alist)
                (%subst-form (cdr form) subst-alist)))))


(defun %remove-funcall (form fn-param-sym concrete-fn-sym)
  "Recursively replace (funcall FN-PARAM-SYM ...) or (funcall (function X) ...)
with (CONCRETE-FN-SYM ...) in FORM."
  (cond
    ((atom form) form)
    ((and (eq (car form) 'funcall) (consp (cdr form)))
     (let* ((fn-arg    (cadr form))
               (call-args (mapcar (lambda (a) (%remove-funcall a fn-param-sym concrete-fn-sym))
                                  (cddr form)))
               (resolved  (cond
                             ((eq fn-arg fn-param-sym) concrete-fn-sym)
                             ((and (consp fn-arg) (eq (car fn-arg) 'function)) (cadr fn-arg))
                             (t nil))))
       (if resolved
           `(,resolved ,@call-args)
           `(funcall ,fn-arg ,@call-args))))
    (t (mapcar (lambda (x) (%remove-funcall x fn-param-sym concrete-fn-sym)) form))))



;;; Helper: is this function name already a _GRAD companion?
;;; Used to prevent recursive generation in the def-function macro patch.
;;; src/autodiff.lisp

(defun %fn-name-is-grad-p (name)
  "Returns T if NAME ends with the _GRAD suffix, indicating it is already
a backward companion and should not receive its own companion."
  (let ((s (symbol-name name)))
    (and (> (length s) 5)
            (string= (subseq s (- (length s) 5)) "_GRAD"))))


;;; Helper: extract return variable(s) from the last element of a flat ANF body.
;;; The last element is either a plain symbol (implicit return) or
;;; a (return v0 v1 ...) form.

(defun %extract-return-vars (flat-anf)
  "Returns the list of return-value symbols from FLAT-ANF.
Handles both implicit last-expression and explicit (return v0 v1 ...) forms."
  (let ((last-form (car (last flat-anf))))
    (cond
      ((symbolp last-form)
       (list last-form))
      ((and (consp last-form) (eq (first last-form) 'return))
       (rest last-form))
      (t
       (error "Cannot extract return vars from flat-ANF last form: ~s" last-form)))))