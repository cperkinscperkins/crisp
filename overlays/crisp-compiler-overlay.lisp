;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

(defun anf-is-atomic? (expr)
  "Returns true if EXPR is considered an atomic value in ANF."
  (or (numberp expr)
      (keywordp expr)
      (symbolp expr)
      (and (consp expr) (eq (car expr) 'function))))

(defun anf-transform (expr)
  "Transforms a Crisp expression into A-Normal Form."
  (cond
   ((anf-is-atomic? expr) expr)
   (t (error "Unsupported form for anf-transform: ~S" expr))))
