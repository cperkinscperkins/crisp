;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ------------------------------------------------------------
;;; Endeavor 120 fix: correct GPU-builtin uniformity classification.
;;;
;;; The original semantic-gpu-builtin cond used names that don't exist as
;;; builtins (:get-workgroup-size, :get-warp-size, :get-global-size), so those
;;; clauses were dead and several REAL 087 builtins (get-local-work-size,
;;; get-global-work-size, get-global-offset, get-work-dim, the linear/total
;;; variants) fell through to :unknown. Now every registered builtin is
;;; classified: per-work-item ids are :divergent, everything constant across
;;; the workgroup is :uniform.
;;; ------------------------------------------------------------

;; src/analysis/core.lisp
(defun calculate-uniformity-state (node env)
  "Recursively determines the uniformity state of an analyzed semantic AST node.
   Returns :uniform, :divergent, or :unknown.
   - Literals are :uniform.
   - Variables are looked up in the env for their stored uniformity. If env lookup
     fails or missing, defaults to :unknown. Kernel arguments are initialized to :uniform.
   - GPU Builtins: per-work-item ids (get-global-id/get-local-id/*-linear-id/
     get-global-id-abs) are :divergent; ids/sizes/offsets constant across the
     workgroup (get-workgroup-id, get-num-groups, get-*-work-size, get-global-offset,
     get-work-dim, get-*-linear-size, get-total-*) are :uniform.
   - Math operations (add, sub, mul, etc): if all args are :uniform, it is :uniform.
     If any arg is :divergent, it is :divergent. Otherwise :unknown.
   - Casts/conversions (to-*, as-*) are passthrough: same uniformity as the operand.
   - Memory reads (aref) are :divergent (or :unknown) unless explicitly cast."
  (etypecase node
    (semantic-literal :uniform)
    (semantic-device-vec-literal
     (let ((states (mapcar (lambda (el) (calculate-uniformity-state el env))
                           (semantic-device-vec-literal-elements node))))
       (cond
         ((some (lambda (s) (eq s :divergent)) states) :divergent)
         ((every (lambda (s) (eq s :uniform)) states) :uniform)
         (t :unknown))))
    (semantic-var-read
     (let ((v (find-variable-in-env (semantic-var-read-name node) env)))
       (if v
           (parameter-def-uniformity v)
           :unknown)))
    (semantic-add
     (let ((ls (calculate-uniformity-state (semantic-add-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-add-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sub
     (let ((ls (calculate-uniformity-state (semantic-sub-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-sub-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-mul
     (let ((ls (calculate-uniformity-state (semantic-mul-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-mul-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-div
     (let ((ls (calculate-uniformity-state (semantic-div-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-div-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sin
     (calculate-uniformity-state (semantic-sin-arg node) env))
    (semantic-cos
     (calculate-uniformity-state (semantic-cos-arg node) env))
    ;; Endeavor 120: casts/conversions (to-*, as-*) are passthrough. Covers all
    ;; semantic-cast subtypes (value-cast, bitcast, fp-truncate-cast, truncate).
    (semantic-cast
     (calculate-uniformity-state (semantic-cast-arg node) env))
    ((or semantic-lt semantic-gt semantic-le semantic-ge semantic-eq semantic-neq)
     (let ((ls (calculate-uniformity-state (slot-value node 'left-arg) env))
           (rs (calculate-uniformity-state (slot-value node 'right-arg) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-if
     (let ((cs (calculate-uniformity-state (semantic-if-condition-node node) env))
           (ts (calculate-uniformity-state (semantic-if-then-node node) env))
           (es (calculate-uniformity-state (semantic-if-else-node node) env)))
       (cond ((or (eq cs :divergent) (eq ts :divergent) (eq es :divergent)) :divergent)
             ((and (eq cs :uniform) (eq ts :uniform) (eq es :uniform)) :uniform)
             (t :unknown))))
    (semantic-let
     :unknown)
    (semantic-gpu-builtin
     (let ((name (semantic-gpu-builtin-builtin-name node)))
       (cond
         ;; Per-work-item: differ across the workgroup.
         ((member name '(:get-global-id :get-local-id :get-global-id-abs
                         :get-local-linear-id :get-global-linear-id))
          :divergent)
         ;; Constant across the workgroup: ids/sizes/offsets/dims/totals.
         ((member name '(:get-workgroup-id :get-num-groups
                         :get-local-work-size :get-global-work-size
                         :get-global-offset :get-work-dim
                         :get-local-linear-size :get-global-linear-size
                         :get-total-threads :get-total-groups))
          :uniform)
         (t :unknown))))
    (semantic-to-workgroup-uniform :uniform)
    (semantic-to-warp-uniform :uniform)
    ;; Memory reads and anything else
    (t :unknown)))

