;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; 049-auto-diff-record-at-kernel-boundary
;;; Option B: Explode record inputs to scalars before AD
;;;
;;; All helpers + redefined %generate-backward-kernel-ast.
;;; Target disposition: src/macros.lisp + src/autodiff.lisp
;;; =========================================================

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

;;; ----------------------------------------------------------
;;; %generate-backward-kernel-ast  (redefinition)
;;; src/macros.lisp
;;; ----------------------------------------------------------

(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Extends the original to handle def-record inputs at the kernel boundary
   via Option B (scalar explosion before AD)."
  (cl:let ((inputs nil) (input-types nil)
                        (outputs nil) (output-types nil)
                        (is-out nil))
    (cl:loop for p in params
             for t-spec in signature-types do
      (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
          (setf is-out t)
          (if is-out
              (progn (push p outputs) (push t-spec output-types))
              (progn (push p inputs)  (push t-spec input-types)))))
    (setf inputs      (nreverse inputs)      input-types  (nreverse input-types)
          outputs     (nreverse outputs)     output-types (nreverse output-types))

    (cl:let* ((pkg (symbol-package name))
              (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))

      ;; --- Expand record inputs to scalar fields --------------
      (multiple-value-bind (flat-inputs flat-input-types
                            record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht
                            grad-cell-syms)
          (%expand-record-kernel-inputs inputs input-types pkg)

        ;; --- Pre-substitute record accessor calls in raw body -
        (cl:let* ((subst-body
                   (mapcar (lambda (form)
                             (%substitute-record-accessors form record-subs-ht record-type-ht))
                           raw-body))

                  ;; Gradient output params for non-record inputs are built below
                  (non-rec-in-grads
                   (cl:loop for p in flat-inputs
                            unless (gethash p record-subs-ht) ; already exploded away
                            collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

                  ;; In-grads for the record-exploded scalars
                  (rec-field-in-grads
                   (cl:loop for p in flat-inputs
                            when (cl:let ((orig (cl:loop for orig in inputs thereis
                                                   (cl:let ((flds (gethash orig record-subs-ht)))
                                                     (and flds (find p (mapcar #'cdr flds) :test #'eq) orig)))))
                                   orig)
                            collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

                  ;; All in-grad syms (for backward walk) — flat inputs are now scalars
                  (all-in-grads
                   (cl:loop for p in flat-inputs
                            collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

                  ;; out-grads (for the cell outputs)
                  (out-grads
                   (cl:loop for p in outputs
                            collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

                  ;; Backward kernel params:
                  ;; flat-inputs + outputs + out-grads + &out + rec-grad-outs + non-rec-scalar-in-grads
                  ;; (Note: record-field scalar in-grads are CELLS, already in rec-grad-out-params)
                  ;; For non-record non-cell flat inputs, their _GRAD is a plain scalar &out
                  (non-rec-scalar-in-grad-params
                   (cl:loop for p in flat-inputs
                             for t-spec in flat-input-types
                             ;; Only float non-record scalars that are not record-exploded fields
                             when (and (%crisp-float-type-p t-spec)
                                       (not (%crisp-record-type-p t-spec))
                                       (not (%storage-handle-type-p t-spec))
                                       ;; record-exploded scalar: its grad is already in rec-grad-out-params
                                       (not (cl:loop for orig in inputs thereis
                                              (cl:let ((flds (gethash orig record-subs-ht)))
                                                (and flds (find p (mapcar #'cdr flds) :test #'eq))))))
                             collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
                  (non-rec-scalar-in-grad-types
                   (cl:loop for p in flat-inputs
                             for t-spec in flat-input-types
                             when (and (%crisp-float-type-p t-spec)
                                       (not (%crisp-record-type-p t-spec))
                                       (not (%storage-handle-type-p t-spec))
                                       (not (cl:loop for orig in inputs thereis
                                              (cl:let ((flds (gethash orig record-subs-ht)))
                                                (and flds (find p (mapcar #'cdr flds) :test #'eq))))))
                             collect t-spec))

                  ;; The &out section combines record-field grads + non-record scalar grads
                  (all-grad-out-params (append rec-grad-out-params non-rec-scalar-in-grad-params))
                  (all-grad-out-types  (append rec-grad-out-types  non-rec-scalar-in-grad-types))

                  (bwd-params (append flat-inputs outputs out-grads
                                      (when all-grad-out-params (list '&out))
                                      all-grad-out-params))
                  (bwd-types  (append flat-input-types output-types output-types
                                      (when all-grad-out-params (list '&out))
                                      all-grad-out-types))

                  ;; Only differentiate float-typed flat inputs.
                  ;; Integer fields from records (and non-record int scalars) are
                  ;; treated as non-differentiable constants in the backward pass.
                  (diff-flat-inputs
                   (cl:loop for p in flat-inputs
                            for t-spec in flat-input-types
                            when (%crisp-float-type-p t-spec)
                            collect p))
                  (diff-flat-input-types
                   (cl:loop for p in flat-inputs
                            for t-spec in flat-input-types
                            when (%crisp-float-type-p t-spec)
                            collect t-spec)))

          ;; --- Explode cell params (existing logic) -----------
          (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
              (%explode-kernel-args bwd-params bwd-types)

            ;; --- ANF + backward walk on substituted body ------
            (cl:let* ((anf-body      (mapcar #'anf-transform subst-body))
                      (flat-anf      (flatten-anf-body anf-body))
                      (forward-bindings
                       (cl:loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                      (raw-backward-walk
                       (generate-backward-walk flat-anf diff-flat-inputs outputs
                                               diff-flat-input-types output-types))
                      ;; Fix (set! vp_x_GRAD adj) -> (set! (~ vp_x_GRAD) adj)
                      (backward-walk
                       (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))

                      ;; Combined reassembly: cells first (from %explode-kernel-args),
                      ;; then record struct reconstruction
                      (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))

              `(progn
                (eval-when (:compile-toplevel :load-toplevel :execute)
                  (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                    (cl:loop for p in ',bwd-params
                             for t-spec in ',bwd-types
                             collect (cons p t-spec))))
                (def-kernel-exact ,bwd-name ,exploded-params
                                  (declare #'(,@exploded-types))
                                  (let (,@all-reassembly)
                                    (let (,@forward-bindings)
                                      ,backward-walk))
                                  (return))))))))))
