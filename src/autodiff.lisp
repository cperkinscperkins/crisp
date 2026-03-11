;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)


(defun generate-backward-walk (flat-anf inputs outputs input-types output-types)
  "Walks a flattened ANF body backwards to accumulate adjoints.
   Returns a list of backward ANF forms."
  (let ((backward-forms nil)
        (adjoint-map (make-hash-table :test 'equal)))

    (labels ((local-adj (v)
                        (or (gethash v adjoint-map)
                            (let ((adv (intern (format nil "~A_ADJ" (symbol-name v)) (symbol-package v))))
                              (setf (gethash v adjoint-map) adv)
                              adv)))
             (emit (form)
                   (push form backward-forms)))

      (let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
           ((and (listp form) (= (length form) 2) (symbolp (car form)))
             (let ((v (car form))
                   (expr (cadr form)))
               (cond
                ((and (consp expr) (eq (car expr) '+))
                  (let ((a (cadr expr))
                        (b (caddr expr)))
                    (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
                    (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
                ((and (consp expr) (eq (car expr) '-))
                  (let* ((a (cadr expr))
                         (b (caddr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
                    (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
                ((and (consp expr) (eq (car expr) '*))
                  (let* ((a (cadr expr))
                         (b (caddr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
                    (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
                ((and (consp expr) (eq (car expr) '/))
                  (let* ((a (cadr expr))
                         (b (caddr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
                    ;; df/db = -a/b^2 * dv
                    (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
                ((and (consp expr) (eq (car expr) 'sin))
                  (let* ((a (cadr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a)
                          (let* ((a-adj (local-adj a))
                                 (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
                            (setf (gethash cos-a adjoint-map) cos-a)
                            (emit `(set! ,cos-a (cos ,a)))
                            (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
                ((and (consp expr) (eq (car expr) 'cos))
                  (let* ((a (cadr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a)
                          (let* ((a-adj (local-adj a))
                                 (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
                            (setf (gethash sin-a adjoint-map) sin-a)
                            (emit `(set! ,sin-a (sin ,a)))
                            (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
                ((and (consp expr) (eq (car expr) '~))
                  (let* ((a (cadr expr))
                         (v-adj (local-adj v)))
                    (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
                (t nil))))

           ((and (consp form) (eq (car form) 'set!))
             (let ((place (cadr form))
                   (val (caddr form)))
               (when (and (consp place) (eq (car place) '~) (symbolp val))
                     (let ((target (cadr place)))
                       (when (member target outputs)
                             (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target)) (symbol-package target))))
                               (emit `(set! ,(local-adj val) (+ ,(local-adj val) (~ ,tgt-grad))))))))))))) ; <-- closes dolist and cond

      (loop for in in inputs
            for in-type in input-types do
              (let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in)) (symbol-package in)))
                     (canon-type (crisp.compiler::canonicalize-type-specifier (if (listp in-type) in-type (list in-type))))
                     (is-cell (eq (car canon-type) 'cell)))
                (if is-cell
                    (emit `(set! (~ ,in-grad) ,(local-adj in)))
                    (emit `(set! ,in-grad ,(local-adj in))))))

      (let ((local-bindings (loop for v being the hash-keys of adjoint-map
                                  using (hash-value adv)
                                  collect `(,adv 0.0))))
        `(let ,local-bindings
           ,@(nreverse backward-forms))))))



;;; ----------------------------------------------------------
;;; %crisp-float-type-p
;;; ----------------------------------------------------------

(defun %crisp-float-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp
   float-category scalar type (float, double, half, bfloat16)."
  (cl:let* ((base (compute-base-type type-spec))
             (info (gethash base *crisp-types*)))
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