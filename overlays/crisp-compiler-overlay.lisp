;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;

(in-package :crisp.compiler)

;;; =====================================================================
;;; Endeavor 143 — infer :tile-shape from the tile-stride form
;;;
;;; The dispatch grid for a tiled kernel is ceil(extent[k] / tile[k]) per axis, so the host
;;; needs the tile extents.  Those extents are ALREADY written in the body:
;;;
;;;     (tile-stride C (32 32) (grid-y grid-x) ...)
;;;
;;; but until now the host only learned them if the user ALSO repeated them in a declaration:
;;;
;;;     (global-size :derive-from C :strategy :strided :tile-shape (32 32))
;;;
;;; and when the declaration was missing the hoist silently emitted a 1-D occupancy grid, which
;;; under an N-D tile-stride loop serializes an axis (measured: 7.6x on BMG — see the hoist-l0
;;; overlay notes).  A survey of this repo found **59 of 61** tile-stride kernels omitting the
;;; declaration, the author's own benchmarks included.  A 59/61 miss rate is not a discipline
;;; problem, it is a bad default: the compiler was discarding information it already had.
;;;
;;; So: infer it.  The explicit :tile-shape remains available and always wins; if it DISAGREES
;;; with the body we warn rather than silently preferring one.
;;;
;;; Conservative by design — inference only fires when all of these hold:
;;;   * the tile spec is a literal size-list (a :tile-tensor spec, as produced by
;;;     matrix-multiply-tile-stride, carries its extents in a tile tensor we cannot read here)
;;;   * the kernel declares :strategy :strided or :exact (the two the tile grid applies to)
;;;   * no :tile-shape is already present
;;;   * the tile-stride tensor matches :derive-from, or the scalar :derive-from list has the
;;;     same rank as the tile spec — otherwise we would be inferring a grid for a different
;;;     iteration space than the one declared
;;;
;;; Hooked into %tile-stride-parse rather than analyze-tile-stride-expression: the parser is the
;;; one place every tile-stride form funnels through, it already owns the grammar (including the
;;; optional layout tag), and it is 25 lines instead of 120.  Recording is idempotent, so being
;;; called again during codegen is harmless.

;; src/analysis/control.lisp  (new)
(defvar *kernel-inferred-tile-shapes* (make-hash-table :test #'eq)
  "Maps kernel name symbol -> the tile-shape this pass inferred from its tile-stride form.
   Lets us tell an inference/inference conflict (two tile-stride forms of different shape in
   one kernel) apart from a declaration/body conflict, so the warning can say which it is.")

;; src/analysis/control.lisp  (new)
(defun %ts-normalize-derive-from (derive)
  "Strip a (quote ...) wrapper from a :derive-from value — the docs show both
   `:derive-from (width height)` and `:derive-from '(width height)`."
  (if (and (consp derive) (symbolp (car derive))
           (string-equal (symbol-name (car derive)) "QUOTE"))
      (second derive)
      derive))

;; src/analysis/control.lisp  (new)
(defun %ts-derive-from-agrees-p (derive tensor-form tile-spec)
  "True when a tile grid built from TILE-SPEC describes the same iteration space the kernel
   declared with :derive-from.  A tensor :derive-from must name the very tensor being strided;
   a scalar list must have the same rank as the tile spec."
  (let ((d (%ts-normalize-derive-from derive)))
    (cond
     ((null d) nil)
     ((symbolp d) (and (symbolp tensor-form)
                       (string-equal (symbol-name d) (symbol-name tensor-form))))
     ((listp d) (= (length d) (length tile-spec)))
     (t nil))))

;; src/analysis/control.lisp  (new)
(defun %ts-maybe-infer-tile-shape (tensor-form tile-spec tile-spec-kind)
  "Enrich the current kernel's dispatch declaration with an inferred :tile-shape.

   Writes into *kernel-dispatch-declarations*, which is what both the metacrisp writer
   (src/metadata.lisp) and the MMA analyzers already read — so the inferred value reaches the
   hoist backends with no change to either.  Silent no-op unless every condition in the header
   comment holds."
  (when (eq tile-spec-kind :size-list)
    (let* ((ctx  *compiler-context*)
           (fn   (and ctx (compiler-context-current-compiling-function ctx)))
           (disp (and fn (gethash fn *kernel-dispatch-declarations*))))
      (when disp
        (let* ((key  (if (getf disp :global-size) :global-size :num-groups))
               (decl (getf disp key)))
          (when (consp decl)
            (let* ((opts     (cdr decl))
                   (strategy (getf opts :strategy))
                   (declared (getf opts :tile-shape))
                   (derive   (getf opts :derive-from))
                   (sname    (and strategy (symbolp strategy) (symbol-name strategy)))
                   (tiled-p  (and sname (or (string-equal sname "STRIDED")
                                            (string-equal sname "EXACT")))))
              (cond
               ((not tiled-p)
                 (log:debug "tile-shape inference: kernel ~a strategy ~a is not tiled; skipping"
                            fn strategy))
               ;; Already carries a shape — verify rather than overwrite.
               (declared
                 (unless (equal declared tile-spec)
                   (if (equal (gethash fn *kernel-inferred-tile-shapes*) declared)
                       (log:warn "Kernel ~a has tile-stride forms of DIFFERENT shapes (~a and ~a).  :tile-shape was inferred as ~a; declare it explicitly to choose."
                                 fn declared tile-spec declared)
                       (log:warn "Kernel ~a declares :tile-shape ~a but its tile-stride form uses ~a.  The declaration wins; one of them is wrong."
                                 fn declared tile-spec))))
               ((not (%ts-derive-from-agrees-p derive tensor-form tile-spec))
                 (log:debug "tile-shape inference: kernel ~a :derive-from ~a does not agree with  tile-stride over ~a ~a; skipping"
                            fn derive tensor-form tile-spec))
               (t
                 (let ((new-decl (append decl (list :tile-shape tile-spec))))
                   (setf (gethash fn *kernel-inferred-tile-shapes*) tile-spec)
                   (setf (gethash fn *kernel-dispatch-declarations*)
                         (let ((copy (copy-list disp)))
                           (setf (getf copy key) new-decl)
                           copy))
                   (log:info "Kernel ~a: inferred :tile-shape ~a from its tile-stride form  (no explicit declaration)."
                             fn tile-spec)))))))))))

;; src/analysis/control.lisp
(defun %tile-stride-parse (expr)
  "Returns (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
   for a tile-stride EXPR.  TILE-SPEC-KIND is one of :size-list or :tile-tensor.
   Form-shape validation only — does not check arity vs tensor.

   Endeavor 143: also infers :tile-shape into the kernel's dispatch declaration when the user
   did not write one (see %ts-maybe-infer-tile-shape).  Parsing is unchanged."
  (let* ((tensor-form (second expr))
         (third (third expr))
         (strict-p (keywordp third))
         (layout-tag (when strict-p third))
         (tile-pos (if strict-p 3 2))
         (tile-spec (nth tile-pos expr))
         (bind-pos (1+ tile-pos))
         (bindings (nth bind-pos expr))
         (body-forms (nthcdr (1+ bind-pos) expr))
         (tile-spec-kind
          (cond
           ((and (listp tile-spec)
                 (>= (length tile-spec) 1)
                 (every #'integerp tile-spec))
             :size-list)
           ((or (symbolp tile-spec)
                (and (consp tile-spec) (symbolp (car tile-spec))))
             :tile-tensor)
           (t
             (error 'crisp-compiler-error
               :message (format nil "tile-stride: tile spec must be a size-list of integers or a tile-tensor reference, got ~S" tile-spec)
               :source-location nil)))))
    (ignore-errors (%ts-maybe-infer-tile-shape tensor-form tile-spec tile-spec-kind))
    (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)))
