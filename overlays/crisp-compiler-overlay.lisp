;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;;; ============================================================================
;;;; 085-auto-diff-int-to-float-grad
;;;; Integer tensor inputs get float-typed _GRAD outputs; backward body is a
;;;; no-op (zero gradient is mathematically correct for integer computations).
;;;; ============================================================================

;; src/autodiff.lisp
(defun %crisp-integer-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC resolves to a tensor whose element type is an integer
category (:signed-int or :unsigned-int). Mirrors %crisp-float-tensor-type-p."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR")
         (cl:let* ((elem (second canonical))
                   (info (gethash elem *crisp-types*)))
           (and info (member (crisp-type-category info)
                             '(:signed-int :unsigned-int)))))))

;; src/autodiff.lisp
(defun %integer-tensor-elem-to-float (type-spec)
  "Replaces the element type of an integer tensor with its float analog:
   64-bit integers (long, ulong) → double; all others → float.
   Also forces :access to :read-write (gradient tensors are always writable).
   Returns TYPE-SPEC unchanged if it is not an integer tensor."
  (if (%crisp-integer-tensor-type-p type-spec)
      (cl:let* ((canonical (canonicalize-type-specifier type-spec))
                (elem      (second canonical))
                (info      (gethash elem *crisp-types*))
                (float-elem (if (and info (>= (crisp-type-size info) 64))
                                'double
                                'float)))
        (list (nth 0 canonical) float-elem (nth 2 canonical)
              (nth 3 canonical) :read-write  (nth 5 canonical)))
      (%ensure-tensor-read-write type-spec)))

;; src/macros.lisp
(defun %compute-backward-kernel-params (flat-inputs flat-input-types outputs output-types
                                        record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
  "Computes the parameter lists and type lists for the backward (gradient) kernel.
085: integer tensor inputs now also receive _GRAD outputs, typed as float tensors
(64-bit integers → double, all others → float). The backward walk still only
processes float inputs — integer tensor inputs contribute zero gradient."
  (cl:let* ((record-exploded-syms
             (cl:loop for orig in inputs
                      append (cl:let ((flds (gethash orig record-subs-ht)))
                               (when flds (mapcar #'cdr flds)))))

            ;; Backward-walk participation: float scalars, float tensors, cells only.
            (differentiable-non-rec-p
             (lambda (t-spec)
               (cl:let ((canonical (canonicalize-type-specifier t-spec)))
                 (or (%crisp-float-type-p t-spec)
                     (%crisp-float-tensor-type-p t-spec)
                     (and (consp canonical)
                          (string-equal (symbol-name (cl:first canonical)) "CELL"))))))

            ;; Gets-grad-output: everything above PLUS integer tensors.
            ;; Integer scalars (ulong indices, etc.) are still excluded.
            (has-grad-output-p
             (lambda (t-spec)
               (or (funcall differentiable-non-rec-p t-spec)
                   (%crisp-integer-tensor-type-p t-spec))))

            (non-rec-scalar-in-grad-params
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall has-grad-output-p t-spec)))
                      collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))

            ;; For integer tensors: promote element type to float analog.
            ;; For float tensors/scalars/cells: same as before.
            (non-rec-scalar-in-grad-types
             (cl:loop for p in flat-inputs
                      for t-spec in flat-input-types
                      unless (or (%crisp-record-type-p t-spec)
                                 (member p record-exploded-syms :test #'eq)
                                 (not (funcall has-grad-output-p t-spec)))
                      collect (if (%crisp-integer-tensor-type-p t-spec)
                                  (%integer-tensor-elem-to-float t-spec)
                                  (%ensure-tensor-read-write t-spec))))

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

            ;; diff-flat-inputs: only float scalars and tensors — integers excluded.
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

;; src/macros.lisp
(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
085: when diff-flat-inputs is empty but integer tensor inputs exist, emits a
trivial backward kernel (just return). The float-typed _GRAD tensors declared
in the signature remain zero — the correct gradient for integer arithmetic."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let ((subst-body
               (mapcar (lambda (form)
                         (%substitute-record-accessors form record-subs-ht record-type-ht))
                       raw-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            ;; 085: only error when there are truly no grad outputs at all —
            ;; i.e. no float inputs AND no integer tensor inputs.
            ;; Integer tensor inputs produce float-typed _GRAD outputs (zero gradient).
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              ;; 085: when diff-flat-inputs is empty (all-integer-tensor case), emit a
              ;; trivial backward kernel. Avoids generating an ill-formed empty (let ())
              ;; from generate-backward-walk. The _GRAD tensors stay zero (correct).
              (if (null diff-flat-inputs)
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  ;; Normal path: generate ANF and backward walk.
                  (let* ((anf-body      (mapcar #'anf-transform subst-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         (raw-backward-walk
                          (generate-backward-walk flat-anf diff-flat-inputs outputs
                                                  diff-flat-input-types output-types))
                         (backward-walk
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
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
                                        (return))))))))))))

