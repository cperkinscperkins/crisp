;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

(defvar *anf-counter* 0)

(defun anf-fresh-temp ()
  (intern (format nil "T-~D" (incf *anf-counter*))))

(defun anf-is-atomic? (expr)
  "Returns true if EXPR is considered an atomic value in ANF."
  (or (numberp expr)
      (keywordp expr)
      (symbolp expr)
      (and (consp expr) (eq (car expr) 'function))))

(defun anf-normalize-args (args)
  "Returns (VALUES normalized-args bindings-list)"
  (if (null args)
      (values nil nil)
      (multiple-value-bind (anf-car car-bindings) (anf-normalize (car args) t)
        (multiple-value-bind (anf-cdr cdr-bindings) (anf-normalize-args (cdr args))
          (values (cons anf-car anf-cdr)
            (append car-bindings cdr-bindings))))))

(defun anf-normalize-place (place)
  "Returns (VALUES normalized-place bindings)
   Normalizes a place for mutation (e.g. the left side of a set!).
   An atomic place stays unchanged, while accessors have their parent argument hoisted."
  (cond
   ((symbolp place) (values place nil))
   ((consp place)
     (let ((acc (car place))
           (args (cdr place)))
       (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
         (values `(,acc ,@anf-args) bindings))))
   (t (error "Invalid place in set!: ~S" place))))

(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list)"
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       (cond
        ((eq op 'set!)
          (let ((place (cadr expr))
                (value (caddr expr)))
            (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
              (multiple-value-bind (new-val val-bindings) (anf-normalize value t)
                (let ((set-expr `(set! ,new-place ,new-val))
                      (all-bindings (append place-bindings val-bindings)))
                  (if is-nested?
                      (let ((temp (anf-fresh-temp)))
                        (values temp (append all-bindings `((,temp ,set-expr)))))
                      (values set-expr all-bindings)))))))
        ((member op '(if if+ when when+ unless unless+))
          (multiple-value-bind (cond-expr cond-bindings) (anf-normalize (cadr expr) t)
            (let* ((true-branch (%anf-transform (caddr expr)))
                   (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
                   (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
                   (anf-if (if false-branch
                               `(,op ,cond-expr ,true-branch ,false-branch)
                               `(,op ,cond-expr ,true-branch))))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append cond-bindings `((,temp ,anf-if)))))
                  (values anf-if cond-bindings)))))
        ((eq op 'cond)
          (let ((anf-clauses (mapcar (lambda (clause)
                                       (let* ((pred (car clause))
                                              (body (cadr clause))
                                              (anf-pred (if (eq pred 'else)
                                                            'else
                                                            (%anf-transform pred)))
                                              (anf-body (%anf-transform body)))
                                         `(,anf-pred ,anf-body)))
                                 (cdr expr))))
            (let ((anf-cond `(cond ,@anf-clauses)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-cond))))
                  (values anf-cond nil)))))
        ((eq op 'let)
          (let ((orig-bindings (cadr expr))
                (body-forms (cddr expr))
                (new-bindings nil))
            (dolist (bind orig-bindings)
              (let* ((vars (butlast bind))
                     (val (car (last bind))))
                (multiple-value-bind (new-val val-bindings) (anf-normalize val nil)
                  (setf new-bindings (append new-bindings val-bindings))
                  (setf new-bindings (append new-bindings (list `(,@vars ,new-val)))))))
            (let ((anf-body-forms nil))
              (loop for (form . rest) on body-forms do
                      (multiple-value-bind (new-form form-bindings) (anf-normalize form nil)
                        (setf new-bindings (append new-bindings form-bindings))
                        (push new-form anf-body-forms)))
              (let ((anf-let (if (or new-bindings (> (length anf-body-forms) 1))
                                 `(let ,new-bindings ,@(nreverse anf-body-forms))
                                 (car anf-body-forms))))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp `((,temp ,anf-let))))
                    (values anf-let nil))))))
        ((eq op 'declare)
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'return)
          (multiple-value-bind (new-val val-bindings) (anf-normalize (cadr expr) t)
            (let ((anf-ret `(return ,new-val)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append val-bindings `((,temp ,anf-ret)))))
                  (values anf-ret val-bindings)))))
        ((eq op 'progn)
          (let ((anf-body (mapcar #'%anf-transform (cdr expr))))
            (let ((anf-progn `(progn ,@anf-body)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-progn))))
                  (values anf-progn nil)))))
        ((eq op 'dotimes)
          (let* ((binding (cadr expr))
                 (var (car binding))
                 (limit (cadr binding))
                 (body (cddr expr)))
            (multiple-value-bind (new-limit limit-bindings) (anf-normalize limit t)
              (let* ((anf-body (mapcar #'%anf-transform body))
                     (anf-dotimes `(dotimes (,var ,new-limit) ,@anf-body)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append limit-bindings `((,temp ,anf-dotimes)))))
                    (values anf-dotimes limit-bindings))))))
        (t
          (let ((args (cdr expr)))
            (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
              (let ((call `(,op ,@anf-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,call)))))
                    (values call bindings)))))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))

(defun %anf-transform (expr)
  "Internal helper for recursive ANF transformation."
  (multiple-value-bind (normalized bindings) (anf-normalize expr nil)
    (if bindings
        `(let ,bindings ,normalized)
        normalized)))

(defun anf-transform (expr)
  "Transforms a Crisp expression into A-Normal Form."
  (let ((*anf-counter* 0))
    (%anf-transform expr)))
