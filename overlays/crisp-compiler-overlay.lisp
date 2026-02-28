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

(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list)"
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr))
           (args (cdr expr)))
       (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
         (let ((call `(,op ,@anf-args)))
           (if is-nested?
               (let ((temp (anf-fresh-temp)))
                 (values temp (append bindings `((,temp ,call)))))
               (values call bindings))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))

(defun anf-transform (expr)
  "Transforms a Crisp expression into A-Normal Form."
  (let ((*anf-counter* 0))
    (multiple-value-bind (normalized bindings) (anf-normalize expr nil)
      (if bindings
          `(let ,bindings ,normalized)
          normalized))))
