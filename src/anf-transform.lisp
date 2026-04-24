;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)

(defvar *anf-counter* 0)

(defun anf-fresh-temp ()
  (intern (format nil "%ANF-T-~D" (incf *anf-counter*))))

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
  "Returns (VALUES normalized-expr bindings-list).
Redefined for 082-atomics: atomic RMW ops (atomic-add! etc.) treat the first
argument as a place (not hoisted to a temp), matching the set! convention."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       ;; Macro-expansion hook: if op is a macro and not a built-in ANF primitive
       (when (and (symbolp op)
                  (macro-function op)
                  (not (member op '(when when+ unless unless+ cond cond+ if if+ return dotimes set! declare progn let
                                          template-instantiation def-function def-kernel def-kernel-exact make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor as quote compiler-no-op
                                          make-cell make-vector make-matrix make-tensor))))
             (multiple-value-bind (expanded changed) (macroexpand-1 expr)
               (when changed
                     (return-from anf-normalize (anf-normalize expanded is-nested?)))))
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
        ((member op '(if when unless))
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
        ((member op '(if+ when+ unless+))
          (let* ((cond-expr (cadr expr))
                 (true-branch (%anf-transform (caddr expr)))
                 (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
                 (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
                 (anf-if (if false-branch
                             `(,op ,cond-expr ,true-branch ,false-branch)
                             `(,op ,cond-expr ,true-branch))))
            (if is-nested?
                (let ((temp (anf-fresh-temp)))
                  (values temp `((,temp ,anf-if))))
                (values anf-if nil))))
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
          (let* ((orig-bindings (cadr expr))
                 (body-and-decls (cddr expr))
                 (decls (loop for f in body-and-decls while (and (listp f) (eq (car f) 'declare)) collect f))
                 (body-forms (nthcdr (length decls) body-and-decls))
                 (new-bindings nil))
            (dolist (bind orig-bindings)
              (let* ((vars (if (listp (car bind)) (car bind) (butlast bind)))
                     (val (if (listp (car bind)) (cadr bind) (car (last bind)))))
                (multiple-value-bind (new-val val-bindings) (anf-normalize val nil)
                  (setf new-bindings (append new-bindings val-bindings))
                  (setf new-bindings (append new-bindings (list `(,@vars ,new-val)))))))
            (let* ((anf-body (mapcar #'%anf-transform body-forms))
                   (hoisted-decls (loop for d in decls collect `(declare ,d)))
                   (anf-progn (if (> (length anf-body) 1) `(progn ,@anf-body) (car anf-body))))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append new-bindings hoisted-decls `((,temp ,anf-progn)))))
                  (values anf-progn (append new-bindings hoisted-decls))))))
        ((eq op 'declare)
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'return)
          (multiple-value-bind (new-args bindings) (anf-normalize-args (cdr expr))
            (let ((anf-ret `(return ,@new-args)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append bindings `((,temp ,anf-ret)))))
                  (values anf-ret bindings)))))
        ((eq op 'as)
          (let ((type-spec (cadr expr))
                (val (caddr expr)))
            (multiple-value-bind (new-val bindings) (anf-normalize val t)
              (let ((anf-as `(as ,type-spec ,new-val)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,anf-as)))))
                    (values anf-as bindings))))))
        ((eq op 'make-scratch-cell)
          (let ((type-spec (cadr expr)))
            (let ((anf-msc `(make-scratch-cell ,type-spec)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-msc))))
                  (values anf-msc nil)))))
        ((member op '(make-scratch-vector make-scratch-matrix make-scratch-tensor))
          (let ((anf-form `(,op ,@(cdr expr))))
            (if is-nested?
                (let ((temp (anf-fresh-temp)))
                  (values temp `((,temp ,anf-form))))
                (values anf-form nil))))
        ((member op '(make-cell make-vector make-matrix make-tensor))
          (let* ((source (cadr expr))
                 (rest-args (cddr expr)))
            (multiple-value-bind (new-source source-bindings)
                (anf-normalize source t)
              (let ((anf-form `(,op ,new-source ,@rest-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append source-bindings `((,temp ,anf-form)))))
                    (values anf-form source-bindings))))))
        ((member op '(quote template-instantiation compiler-no-op def-function def-kernel def-kernel-exact eval-when))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
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
        ;; 082-atomics: atomic RMW ops treat the first arg as a place (not hoisted).
        ;; Use string= to handle cross-package symbols (crisp.compiler vs crisp-language).
        ((and (symbolp op)
              (member (symbol-name op)
                      '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
                        "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!")
                      :test #'string=))
          (let ((place (cadr expr))
                (rest-args (cddr expr)))
            (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
              (multiple-value-bind (anf-args arg-bindings) (anf-normalize-args rest-args)
                (let ((call `(,op ,new-place ,@anf-args))
                      (all-bindings (append place-bindings arg-bindings)))
                  (if is-nested?
                      (let ((temp (anf-fresh-temp)))
                        (values temp (append all-bindings `((,temp ,call)))))
                      (values call all-bindings)))))))
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

(defun anf-transform-module (forms)
  "Iterates over top-level forms, running ANF transform on function/kernel bodies."
  (mapcar (lambda (form)
            (if (consp form)
                (let ((op (car form)))
                  (cond
                   ((member op '(def-function def-kernel def-kernel-exact))
                     ;; (op name args decls ...body)
                     (let* ((name (cadr form))
                            (args (caddr form))
                            (body-start 3)
                            (decls (loop for i from body-start below (length form)
                                         for f = (nth i form)
                                         while (and (consp f) (eq (car f) 'declare))
                                         collect f))
                            (actual-body-start (+ body-start (length decls)))
                            (body (nthcdr actual-body-start form))
                            (anf-body (mapcar #'anf-transform body)))
                       `(,op ,name ,args ,@decls ,@anf-body)))
                   ((eq op 'with-template-type)
                     ;; (with-template-type (params) inner-form)
                     `(with-template-type ,(cadr form) ,@(anf-transform-module (cddr form))))
                   (t form)))
                form))
      forms))



(defun flatten-anf-body (anf-body)
  "Flattens an ANF body into a sequential list of bindings and side-effects.
Returns a list of elements formatted as either (var expr), (var0 var1 expr) for
multi-value bindings, or just expr (for side-effects).
Accepts bindings of length >= 2 (fix: was = 2, dropping multi-value bindings)."
  (let ((flat nil))
    (labels ((walk (expr)
               (cond
                ((and (consp expr) (eq (car expr) 'let))
                  (let ((bindings (cadr expr))
                        (body (cddr expr)))
                    (dolist (b bindings)
                      ;; Accept length >= 2: covers (var expr) and (v0 v1 ... expr)
                      (when (and (consp b) (>= (length b) 2))
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