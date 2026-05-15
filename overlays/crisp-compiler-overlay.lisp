;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/macros.lisp -- %generate-backward-kernel-ast
;;
;; Endeavor 103 / Phase A fix: bind *record-param-field-adjs* around the
;; backward walk for kernels with record-at-boundary inputs.  Without this,
;; accessor calls (x~ vp) inside the kernel body fall through to the generic
;; accessor rule in %handle-single-value-backward and route adj into the
;; collective vp_adj, which never propagates to the per-field vp_x_ADJ /
;; vp_y_ADJ that the input-grad-write loop expects.  Result was: backward
;; ran without error but every grad cell got written as 0.
;;
;; The fix mirrors what %generate-backward-function-ast does for sub-function
;; record params (see autodiff.lisp): build a record-sym -> (field-name-str .
;; field-adj-sym) alist and dyn-bind *record-param-field-adjs* during the
;; backward walk.  For kernel-level, the field-adj-sym is the SROA'd field
;; input's adj (e.g. VP_X_ADJ for the vp_x scalar input), which the existing
;; input-grad-write step already writes to the matching vp_x_grad cell.
;;
;; record-subs-ht entries can include `:%nested-leaf%` sentinels for nested
;; records (added in phase 5b/101); those are filtered out here.

(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-
   boundary accessor calls route adj into the SROA'd field's adj sym."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms
                            struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let ((subst-body
               (mapcar (lambda (form)
                         (%substitute-record-accessors form record-subs-ht record-type-ht))
                       raw-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                              (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                              (loop for entry in struct-shadow-info
                                    for p = (first entry)
                                    collect (nth (position p flat-inputs :test #'eq)
                                                 flat-input-types)))))
              (if (and (null augmented-diff-flat-inputs)
                       (null struct-shadow-info))
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  (let* ((anf-body      (mapcar #'anf-transform subst-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         (struct-shadow-ht
                          (when struct-shadow-info
                            (let ((ht (make-hash-table :test 'eq)))
                              (dolist (entry struct-shadow-info)
                                (setf (gethash (first entry) ht)
                                      (cons (second entry)
                                            (fourth entry))))
                              (%register-shadow-anf-intermediates flat-anf ht)
                              ht)))
                         ;; --- Phase A: record-param-field-adjs for record kernel inputs ----
                         ;; record-subs-ht maps RECORD-SYM -> ((field-sym . exploded-scalar-sym) ...)
                         ;; with possible (:%nested-leaf% . leaf-sym) sentinels we filter out.
                         ;; The field adj is the SROA'd field's <SYM>_ADJ name.
                         (kernel-record-param-field-adjs-ht
                          (when (> (hash-table-count record-subs-ht) 0)
                            (let ((ht (make-hash-table :test 'eq)))
                              (maphash
                               (lambda (rsym field-alist)
                                 (let ((adj-alist
                                        (loop for entry in field-alist
                                              for fname = (car entry)
                                              for fsym  = (cdr entry)
                                              unless (eq fname :%nested-leaf%)
                                              collect (cons (symbol-name fname)
                                                            (intern (format nil "~A_ADJ" (symbol-name fsym))
                                                                    pkg)))))
                                   (setf (gethash rsym ht) adj-alist)))
                               record-subs-ht)
                              ht)))
                         (raw-backward-walk
                          (let ((*struct-kernel-param-shadows* struct-shadow-ht)
                                (*record-param-field-adjs* kernel-record-param-field-adjs-ht))
                            (generate-backward-walk flat-anf
                                                    augmented-diff-flat-inputs outputs
                                                    augmented-diff-flat-input-types output-types
                                                    :kernel-pkg pkg)))
                         (backward-walk-1
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                         (backward-walk-2
                          (if struct-shadow-info
                              (let ((all-leaves
                                     (loop for entry in struct-shadow-info
                                           append (%collect-all-leaf-adj-syms (fourth entry)))))
                                (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                              backward-walk-1))
                         (backward-walk
                          (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
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
                                        (return)))))))))))))

