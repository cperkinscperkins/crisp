;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

(defun flatten-anf-body (anf-body)
  "Flattens an ANF body into a sequential list of bindings and side-effects.
   Returns a list of elements formated as either (var expr) or just expr (for side-effects)."
  (let ((flat nil))
    (labels ((walk (expr)
                   (cond
                    ((and (consp expr) (eq (car expr) 'let))
                      (let ((bindings (cadr expr))
                            (body (cddr expr)))
                        (dolist (b bindings)
                          (if (and (consp b) (= (length b) 2))
                              (push b flat)))
                        (dolist (f body)
                          (unless (and (consp f) (eq (car f) 'declare))
                            (walk f)))))
                    ((and (consp expr) (eq (car expr) 'progn))
                      (dolist (f (cdr expr))
                        (walk f)))
                    ((and (consp expr) (eq (car expr) 'declare))
                      nil)
                    (t
                      (push expr flat)))))
      (dolist (form anf-body)
        (walk form))
      (nreverse flat))))

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

(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Helper: Generates the def-kernel-exact AST for the backward pass."
  (let ((inputs nil) (input-types nil)
                     (outputs nil) (output-types nil)
                     (is-out nil))
    (loop for p in params
          for t-spec in signature-types do
            (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                (setf is-out t)
                (if is-out
                    (progn (push p outputs) (push t-spec output-types))
                    (progn (push p inputs) (push t-spec input-types)))))
    (setf inputs (nreverse inputs) input-types (nreverse input-types)
      outputs (nreverse outputs) output-types (nreverse output-types))

    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg))
           (in-grads (loop for p in inputs collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
           (out-grads (loop for p in outputs collect (intern (format nil "~a_GRAD" (symbol-name p)) pkg)))
           (bwd-params (append inputs outputs out-grads (if in-grads (list '&out) nil) in-grads))
           (bwd-types (append input-types output-types output-types (if input-types (list '&out) nil) input-types)))

      (multiple-value-bind (exploded-params exploded-types bwd-reassembly-bindings)
          (%explode-kernel-args bwd-params bwd-types)

        (let* ((anf-body (mapcar #'anf-transform raw-body))
               (flat-anf (flatten-anf-body anf-body))
               (forward-bindings
                (loop for form in flat-anf
                        when (and (consp form) (= (length form) 2) (symbolp (car form)))
                      collect form))
               (forward-side-effects
                (loop for form in flat-anf
                        when (or (not (consp form))
                                 (not (= (length form) 2))
                                 (not (symbolp (car form))))
                      collect form))
               (backward-walk (generate-backward-walk flat-anf inputs outputs input-types output-types)))

          `(progn
            (eval-when (:compile-toplevel :load-toplevel :execute)
              (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                (loop for p in ',bwd-params
                      for t-spec in ',bwd-types
                      collect (cons p t-spec))))
            (def-kernel-exact ,bwd-name ,exploded-params
                              (declare #'(,@exploded-types))
                              (let (,@bwd-reassembly-bindings)
                                (let (,@forward-bindings)
                                  ,backward-walk))
                              (return))))))))

(defmacro def-kernel (name params &rest body)
  "Defines a GPU Kernel (Entry Point).
   
   Constraint: All parameter types MUST be complete.
   Incomplete types (missing compile-time properties) are forbidden at the kernel boundary
   because the host must know the exact layout to marshall arguments."

  ;; Use the helper to parse and validate, avoiding code duplication and monolithic macros
  (multiple-value-bind (exploded-params exploded-types reassembly-bindings raw-body other-decls signature-types is-differentiable)
      (parse-kernel-signature name params body)

    ;; Expand to def-kernel-exact
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (setf (gethash ',name crisp.compiler::*kernel-declared-signatures*)
          (loop for p in ',params
                for t-spec in ',signature-types
                collect (cons p t-spec))))
      (def-kernel-exact ,name ,exploded-params
                        (declare #'(,@exploded-types))
                        ,@(when other-decls `((declare ,@other-decls)))
                        (let (,@reassembly-bindings)
                          ,@raw-body))

      ;; Inject the Backward Kernel AST if differentiation is enabled and allowed
      ,@(when is-differentiable
              (list (%generate-backward-kernel-ast name params signature-types raw-body))))))
