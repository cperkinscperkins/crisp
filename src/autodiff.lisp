;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)



(defun %emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg emit-fn local-adj-fn &optional (sym-prefix "BW"))
  (declare (ignore fn))
  (cl:let* ((deltas (cl:loop for i from 0 below n-fp
                             collect (intern (format nil "%~A_D~a" sym-prefix i) pkg)))
            (accum-forms
             (cl:loop for arg in args
                      for i from 0 below n-fp
                      when (symbolp arg)
                      collect `(set! ,(funcall local-adj-fn arg)
                                     (+ ,(funcall local-adj-fn arg) ,(nth i deltas))))))
    (when accum-forms
      (funcall emit-fn `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                          (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                            ,@accum-forms))))))

(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn &key hof-handler-fn (error-on-unknown t))
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
      ;; Cell read: ~
      ((and (consp expr) (eq (car expr) '~))
        (cl:let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
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

(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
Returns a backward ANF body (a let form).
Extended for feature 052: handles differentiable sub-function calls (B1/B2),
multi-value bindings, HOF inline backward, errors for non-differentiable
functions (B3), and mutation errors (B4)."
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal)))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms))
             ;; Emit _GRAD call + adjoint accumulation for a normal sub-function.


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
                           ;; Resolve concrete function from call args
                           (fn-arg       (nth fn-param-idx args))
                           (concrete-fn  (cond
                                           ;; (function +) — inline atomic
                                           ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                            (cadr fn-arg))
                                           ;; Bare symbol
                                           ((symbolp fn-arg) fn-arg)
                                           (t nil))))
                   (unless concrete-fn
                     (error "Cannot inline-differentiate HOF ~A: ~
                             could not resolve concrete fn from arg ~A" fn fn-arg))
                   ;; Build substitution: non-fn params -> call-site args
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
                             ;; ANF + flatten the concrete body
                             (anf-body      (mapcar #'anf-transform concrete-body))
                             (hof-flat      (flatten-anf-body anf-body))
                             ;; Normalize last form if needed
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
                     ;; Seed return-var adjoints to v's adjoint
                     (cl:dolist (rv return-vars)
                       (setf (gethash rv adjoint-map) (local-adj v)))
                     ;; Process hof-flat-norm backwards (same primitive rules)
                     (cl:dolist (hf-form (cl:reverse hof-flat-norm))
                       (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                         (cl:let ((hv    (car hf-form))
                                  (hexpr (cadr hf-form)))
                           (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                          :hof-handler-fn #'hof-inline-backward
                                                          :error-on-unknown t))))))))

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
                                               :error-on-unknown t)))

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
                    (emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg)))))

            ;; ---- B4: Mutation of kernel input cell ----------------
            ((and (consp form) (eq (car form) 'set!))
              (cl:let ((place (cadr form))
                       (val   (caddr form)))
                (when (and (consp place) (eq (car place) '~) (symbolp val))
                  (cl:let ((target (cadr place)))
                    (cond
                      ((member target outputs)
                        (cl:let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                   (symbol-package target))))
                          (emit `(set! ,(local-adj val) (+ ,(local-adj val) (~ ,tgt-grad))))))
                      ((member target inputs)
                        (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                               target target))
                      (t nil))))))

            ;; ---- Everything else: skip ----------------------------
            (t nil))))

      ;; Emit gradient output writes for all inputs
      (cl:loop for in in inputs
               for in-type in input-types do
                 (cl:let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
                                            (symbol-package in)))
                           (canon-type (crisp.compiler::canonicalize-type-specifier
                                        (if (listp in-type) in-type (list in-type))))
                           (is-cell (eq (car canon-type) 'cell)))
                   (if is-cell
                       (emit `(set! (~ ,in-grad) ,(local-adj in)))
                       (emit `(set! ,in-grad ,(local-adj in))))))

      (cl:let* ((local-bindings (cl:loop for v being the hash-keys of adjoint-map
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
  (cl:let* ((direct-info (and (symbolp type-spec) (gethash type-spec *crisp-types*)))
            (base (if direct-info type-spec (compute-base-type type-spec)))
            (info (when base (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :float))))

;;; ----------------------------------------------------------
;;; %crisp-record-type-p
;;; ----------------------------------------------------------

(defun %crisp-record-type-p (type-spec)
  "Returns T if TYPE-SPEC names a def-record (category :record).
   Handles parameterized forms like (V-POINT :EARNESTNESS 3.0)."
  (cl:let* ((base (if (consp type-spec) (cl:first type-spec) type-spec))
             (info (gethash base *crisp-types*)))
    (and info (eq (crisp-type-category info) :record))))

;;; ----------------------------------------------------------
;;; %get-record-runtime-fields
;;; ----------------------------------------------------------

(defun %get-record-runtime-fields (rec-type-spec)
  "Returns a list of (FIELD-NAME RESOLVED-FIELD-TYPE) for the runtime
   (non-:c-t) members of the record type named by REC-TYPE-SPEC.
   Handles parameterised forms like (V-POINT :EARNESTNESS 3.0)."
  (cl:let* ((base (if (consp rec-type-spec) (cl:first rec-type-spec) rec-type-spec))
             (struct-def (or (gethash base *crisp-structs*)
                             (gethash (intern (symbol-name base) :crisp-language)
                                      *crisp-structs*))))
    (when struct-def
      (cl:loop for m in (crisp-struct-definition-members struct-def)
               unless (and (consp m) (eq (cl:third m) :c-t))
               collect (cl:list (cl:first m)
                                 (compute-base-type (cl:second m)))))))

;;; ----------------------------------------------------------
;;; %record-accessor-system-generated-p
;;; ----------------------------------------------------------

(defun %record-accessor-system-generated-p (accessor-sym rec-type)
  "Returns T if ACCESSOR-SYM (e.g. X~) is the single system-generated
   accessor for REC-TYPE — i.e. it has NOT been user-overloaded.
   Heuristic: count *function-table* entries whose first parameter type
   matches REC-TYPE.  Exactly 1 means system-generated only."
  (cl:let* ((sigs (gethash accessor-sym *function-table*))
             (base-name (symbol-name (if (consp rec-type) (cl:first rec-type) rec-type)))
             (matching
              (cl:loop for sig in sigs
                       when (cl:let* ((params (function-signature-parameters sig))
                                      (first-param (cl:first params))
                                      (first-type (and first-param
                                                        (parameter-def-type first-param))))
                              (and first-type
                                   (string-equal (symbol-name
                                                  (if (consp first-type)
                                                      (cl:first first-type)
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
  (cl:flet ((raw-accessor-p (name-str)
               ;; ~field~ : starts AND ends with ~, length > 2
               (and (> (cl:length name-str) 2)
                    (cl:char= (cl:char name-str 0) #\~)
                    (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~)))
             (regular-accessor-p (name-str)
               ;; field~ : ends with ~ but does NOT start with ~
               (and (> (cl:length name-str) 1)
                    (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~)
                    (cl:char/= (cl:char name-str 0) #\~))))
    (cond
      ;; ---- Atom: pass through --------------------------------
      ((atom form) form)

      ;; ---- (~field~ p) : raw accessor call -------------------
      ((and (= (length form) 2)
            (symbolp (cl:first form))
            (raw-accessor-p (symbol-name (cl:first form))))
       (cl:let* ((op-name  (symbol-name (cl:first form)))
                 (field-name (intern (cl:subseq op-name 1 (1- (length op-name)))
                                     (symbol-package (cl:first form))))
                 (arg     (cl:second form))
                 (fld-map (gethash arg record-subs-ht)))
         (if fld-map
             (cl:let ((hit (assoc field-name fld-map :test #'string-equal)))
               (if hit (cdr hit) form))
             ;; arg is not a record param — recurse normally
             (cl:list (cl:first form)
                      (%substitute-record-accessors arg record-subs-ht record-type-ht)))))

      ;; ---- (field~ p) : regular accessor call ----------------
      ((and (= (length form) 2)
            (symbolp (cl:first form))
            (regular-accessor-p (symbol-name (cl:first form))))
       (cl:let* ((op      (cl:first form))
                 (op-name (symbol-name op))
                 (field-name (intern (cl:subseq op-name 0 (1- (length op-name)))
                                     (symbol-package op)))
                 (arg     (cl:second form))
                 (fld-map (gethash arg record-subs-ht))
                 (rec-type (gethash arg record-type-ht)))
         (if (and fld-map rec-type
                  (%record-accessor-system-generated-p op rec-type))
             (cl:let ((hit (assoc field-name fld-map :test #'string-equal)))
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
  (cl:flet ((grad-cell-p (sym)
               (and (symbolp sym) (member sym grad-cell-syms :test #'eq))))
    (cond
      ((atom form) form)
      ;; (set! var expr) — var is a grad-cell sym
      ((and (consp form)
            (eq (cl:first form) 'set!)
            (= (length form) 3)
            (grad-cell-p (cl:second form)))
       (cl:list 'set!
                (cl:list '~ (cl:second form))
                (%fix-record-grad-cell-emissions (cl:third form) grad-cell-syms)))
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
  (cl:let ((flat-inputs        '())
           (flat-input-types   '())
           (reassembly-bindings '())
           (grad-out-params    '())
           (grad-out-types     '())
           (record-subs-ht     (make-hash-table :test 'eq))
           (record-type-ht     (make-hash-table :test 'eq))
           (grad-cell-syms     '()))

    (cl:loop for p in inputs
             for t-spec in input-types do
      (if (%crisp-record-type-p t-spec)
          ;; --- Record input: explode to scalar fields ---------
          (cl:let* ((base-type (if (consp t-spec) (cl:first t-spec) t-spec))
                    (fields    (%get-record-runtime-fields t-spec))
                    (make-sym  (intern (format nil "MAKE-~a" (symbol-name base-type)) pkg))
                    (field-syms
                     (cl:loop for (fname ftype) in fields
                              collect (cl:list fname
                                               ftype
                                               (%record-field-param-sym p fname pkg)))))
            ;; Register for substitution
            (setf (gethash p record-subs-ht)
                  (cl:loop for (fname ftype fsym) in field-syms
                           collect (cons fname fsym)))
            (setf (gethash p record-type-ht) t-spec)
            ;; Flat scalar params
            (cl:loop for (fname ftype fsym) in field-syms do
              (push fsym flat-inputs)
              (push ftype flat-input-types))
            ;; Reassembly binding: (p (make-base-type :field0 f0 :field1 f1 ...))
            ;; Uses keyword args to match the def-record constructor signature.
            (push (cl:list p (cons make-sym
                                   (cl:loop for (fname ftype fsym) in field-syms
                                            append (list (intern (symbol-name fname) :keyword)
                                                         fsym))))
                  reassembly-bindings)
            ;; Gradient cell outputs — float fields only
            (cl:loop for (fname ftype fsym) in field-syms do
              (when (%crisp-float-type-p ftype)
                (cl:let ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg)))
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
  (cl:let ((name (symbol-name fn-sym)))
    (or
     (cl:find #\% name)
     (string= name "AS")
     (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
     (cl:loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
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
  (cl:let* ((pkg (symbol-package name)))

    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)

      (cl:let* (;; Float-typed params (the differentiable ones)
                (float-param-entries
                 (cl:loop for pd in env
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
                 (cl:loop for pd in env
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
          (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                    (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                    ;; Strip any trailing source-location atom from body-forms
                    (clean-body    (cl:loop for f in body-forms
                                            unless (and (atom f) (not (symbolp f)))
                                            collect f)))
            (log:info "AUTODIFF: ~a is HOF (fn-param=~a idx=~a) — storing for inline backward"
                      name fn-param-sym fn-param-idx)
            (setf (gethash name *differentiable-hof-store*)
                  (list :param-syms       (cl:loop for pd in env
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
        (cl:let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
                  (t-grad-syms (cl:loop for i from 0 below n-return
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
            (cl:let* ((anf-body   (mapcar #'anf-transform body-forms))
                      (raw-flat   (flatten-anf-body anf-body))
                      (flat-anf
                       (cl:let ((last-f (cl:car (cl:last raw-flat))))
                         (if (or (symbolp last-f)
                                 (and (consp last-f) (eq (cl:first last-f) 'return)))
                             raw-flat
                             (cl:let ((ret-sym (intern "%RET-0" pkg)))
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
  (cl:let ((backward-forms nil)
           (adjoint-map (make-hash-table :test 'equal))
           (return-var-seeds (make-hash-table :test 'eq)))

    ;; Map each return-var to its t_grad seed
    (cl:loop for rv in return-vars
             for tg in t-grad-syms do
      (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (cl:let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                         (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (cl:let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ;; ---- Single-value binding: (v expr) -------------------
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
              (cl:let ((v    (car form))
                       (expr (cadr form)))
                (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                               :error-on-unknown t)))

            ;; ---- Multi-value binding: (v0 v1 ... expr) -----------
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
              (cl:let* ((result-vars (butlast form))
                        (expr        (car (last form))))
                (when (and (consp expr)
                           (symbolp (car expr))
                           (gethash (car expr) *differentiable-functions*))
                  (cl:let* ((fn      (car expr))
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
    (cl:let* ((forward-bindings
               (cl:loop for form in flat-anf
                        when (and (consp form)
                                  (= (length form) 2)
                                  (symbolp (car form))
                                  (not (gethash (car form) return-var-seeds)))
                        collect form))
              (adjoint-bindings
               (cl:loop for v being the hash-keys of adjoint-map
                        using (hash-value adv)
                        collect (cl:let ((seed (gethash v return-var-seeds)))
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
               (when (and (eq (cl:first form) 'set!)
                          (consp (cl:second form))
                          (eq (cl:first (cl:second form)) '~)
                          (symbolp (cl:second (cl:second form)))
                          (member (cl:second (cl:second form)) param-names :test #'string-equal))
                 (error "Cannot differentiate function ~A: it mutates parameter ~A via cell write (set! (~~ ~A) ...). This function is not valid in a differentiable kernel."
                        fn-name
                        (cl:second (cl:second form))
                        (cl:second (cl:second form))))
               (mapc #'walk (cl:rest form)))))
    (mapc #'walk body-forms)))




(defun %crisp-function-type-p (type-spec)
  "Returns T if TYPE-SPEC is a parsed :function-type or :function-literal specifier."
  (and (consp type-spec)
       (or (eq (cl:first type-spec) :function-type)
           (eq (cl:first type-spec) :function-literal))))


(defun %subst-form (form subst-alist)
  "Recursively substitute atoms in FORM according to SUBST-ALIST (list of (sym . replacement))."
  (cond
    ((null form) nil)
    ((atom form)
     (cl:let ((pair (cl:assoc form subst-alist)))
       (if pair (cdr pair) form)))
    (t (cl:cons (%subst-form (car form) subst-alist)
                (%subst-form (cdr form) subst-alist)))))


(defun %remove-funcall (form fn-param-sym concrete-fn-sym)
  "Recursively replace (funcall FN-PARAM-SYM ...) or (funcall (function X) ...)
with (CONCRETE-FN-SYM ...) in FORM."
  (cond
    ((atom form) form)
    ((and (eq (car form) 'funcall) (consp (cdr form)))
     (cl:let* ((fn-arg    (cadr form))
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
  (cl:let ((s (symbol-name name)))
    (cl:and (> (cl:length s) 5)
            (string= (cl:subseq s (- (cl:length s) 5)) "_GRAD"))))


;;; Helper: extract return variable(s) from the last element of a flat ANF body.
;;; The last element is either a plain symbol (implicit return) or
;;; a (return v0 v1 ...) form.

(defun %extract-return-vars (flat-anf)
  "Returns the list of return-value symbols from FLAT-ANF.
Handles both implicit last-expression and explicit (return v0 v1 ...) forms."
  (cl:let ((last-form (cl:car (cl:last flat-anf))))
    (cond
      ((symbolp last-form)
       (cl:list last-form))
      ((and (consp last-form) (eq (cl:first last-form) 'return))
       (cl:rest last-form))
      (t
       (error "Cannot extract return vars from flat-ANF last form: ~s" last-form)))))