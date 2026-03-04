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