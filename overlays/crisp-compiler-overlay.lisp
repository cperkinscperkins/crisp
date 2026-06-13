(in-package :crisp.compiler)

(defun %rewrite-bare-tile-in-form (form origin-binding-syms cl-pkg)
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
             form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((or (string-equal op-name "LOAD-TILE")
              (string-equal op-name "REQUEST-LOAD-TILE"))
          (if (>= (length form) 4)
              (cons (car form) (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg)) (cdr form)))
              (let ((sym (car form))
                    (src (second form))
                    (tile (third form))
                    (key-args (nthcdr 3 form)))
                (append (list sym src tile origin-binding-syms) key-args))))
         ((or (string-equal op-name "STORE-TILE")
              (string-equal op-name "REQUEST-STORE-TILE"))
          (if (>= (length form) 4)
              (cons (car form) (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg)) (cdr form)))
              (let ((sym (car form))
                    (tile (second form))
                    (dest (third form))
                    (key-args (nthcdr 3 form)))
                (append (list sym tile dest origin-binding-syms) key-args))))
         (t (cons (car form)
                  (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
                          (cdr form)))))))))

(defun %rewrite-bare-load-store-tile-in-body (body-forms origin-binding-syms cl-pkg)
  (mapcar (lambda (f) (%rewrite-bare-tile-in-form f origin-binding-syms cl-pkg))
          body-forms))

(defun %detect-bare-load-store-tile-in-form (form path)
  (cond
    ((atom form) nil)
    ((not (and (consp form) (symbolp (car form))))
     (dolist (sub form) (%detect-bare-load-store-tile-in-form sub path)))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((or (string-equal op-name "LOAD-TILE")
              (string-equal op-name "STORE-TILE")
              (string-equal op-name "REQUEST-LOAD-TILE")
              (string-equal op-name "REQUEST-STORE-TILE"))
          (when (< (length form) 4)
            (error 'crisp-compiler-error
                   :message (format nil "~A: bare ~A is not allowed inside ~A..." 
                                    (string-downcase op-name) (string-downcase op-name) path)
                   :source-location nil)))
         (t
          (dolist (sub (cdr form))
            (%detect-bare-load-store-tile-in-form sub path))))))))

(defun strip-barrier (key-args)
  (let ((res nil) (skip nil))
    (loop for x on key-args do
      (if skip
          (setf skip nil)
          (if (eq x :barrier)
              (setf skip t)
              (push x res))))
    (reverse res)))

(defun analyze-load-tile-at-expression (expr env context location)
  (let ((key-args (nthcdr 4 expr)))
    (when (and (getf key-args :barrier) (getf key-args :transformF))
      (error 'crisp-compiler-error :message "Cannot use :barrier and :transformF together" :source-location location))
    (let ((stripped-expr (append (subseq expr 0 4) (strip-barrier key-args))))
      (analyze-expression (cons (intern "LOAD-TILE-COORDS" (find-package :crisp-language)) (cdr stripped-expr))
                          env context location))))

(defun analyze-store-tile-at-expression (expr env context location)
  (let ((key-args (nthcdr 4 expr)))
    (when (and (getf key-args :barrier) (getf key-args :transformF))
      (error 'crisp-compiler-error :message "Cannot use :barrier and :transformF together" :source-location location))
    (let ((stripped-expr (append (subseq expr 0 4) (strip-barrier key-args))))
      (analyze-expression (cons (intern "STORE-TILE-COORDS" (find-package :crisp-language)) (cdr stripped-expr))
                          env context location))))

(defun analyze-load-tile-expression (expr env context location)
  (let* ((src (second expr))
         (tile (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg)))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "load-tile: origin must be a non-empty list of grid coords" :source-location location))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym g (list aref-sym (list extents-sym tile) i)))))
      (analyze-load-tile-at-expression
       (append (list (intern "LOAD-TILE-AT" cl-pkg) src tile pixel-coords) key-args)
       env context location))))

(defun analyze-store-tile-expression (expr env context location)
  (let* ((tile (second expr))
         (dest (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg)))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "store-tile: origin must be a non-empty list of grid coords" :source-location location))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym g (list aref-sym (list extents-sym tile) i)))))
      (analyze-store-tile-at-expression
       (append (list (intern "STORE-TILE-AT" cl-pkg) tile dest pixel-coords) key-args)
       env context location))))

(defun analyze-make-async-barrier-expression (expr env context location)
  (declare (ignore expr))
  (analyze-expression 0 env context location))

(defun analyze-await-expression (expr env context location)
  (declare (ignore expr))
  (analyze-expression nil env context location))

(let ((sym-cl (intern "LOAD-TILE-AT" (find-package :crisp-language)))
      (sym-cc (intern "LOAD-TILE-AT" (find-package :crisp.compiler))))
  (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-tile-at-expression)
  (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-tile-at-expression))
(let ((sym-cl (intern "STORE-TILE-AT" (find-package :crisp-language)))
      (sym-cc (intern "STORE-TILE-AT" (find-package :crisp.compiler))))
  (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-tile-at-expression)
  (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-at-expression))
(let ((sym-cl (intern "MAKE-ASYNC-BARRIER" (find-package :crisp-language)))
      (sym-cc (intern "MAKE-ASYNC-BARRIER" (find-package :crisp.compiler))))
  (setf (gethash sym-cl *expression-analyzers*) #'analyze-make-async-barrier-expression)
  (setf (gethash sym-cc *expression-analyzers*) #'analyze-make-async-barrier-expression))
(let ((sym-cl (intern "AWAIT" (find-package :crisp-language)))
      (sym-cc (intern "AWAIT" (find-package :crisp.compiler))))
  (setf (gethash sym-cl *expression-analyzers*) #'analyze-await-expression)
  (setf (gethash sym-cc *expression-analyzers*) #'analyze-await-expression))