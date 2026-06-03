;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)



(defun %emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg emit-fn local-adj-fn &optional (sym-prefix "BW"))
  "Emits the call to BKWD-FN and routes returned deltas / passed-through
   &out grad-tensors per the AD convention.

   - Scalar arg: one delta from multi-value return → accumulated into
     (local-adj arg).
   - Record/struct arg (looked up via *record-param-field-adjs*): N deltas
     in declaration order → accumulated into each per-field synth adj.
   - Tensor arg (identified via fn's :tensor-param-indices registry slot):
     pairs with an &out arg in the call.  The kernel's corresponding
     `<arg>_GRAD` is passed; the chain rule's atomic-add happens inside
     the sub-fn body.  No scalar delta to accumulate.

   The call is emitted whenever there's any accumulation OR any tensor
   arg (the tensor case writes via &out, not via accumulation, but the
   call itself still needs to happen)."
  (let* ((info (and fn (gethash fn *differentiable-functions*)))
         (tensor-indices (and info (getf info :tensor-param-indices)))
         (has-tensor-args (consp tensor-indices))
         (deltas (loop for i from 0 below n-fp
                       collect (intern (format nil "%~A_D~a" sym-prefix i) pkg)))
         (accum-forms nil)
         (delta-idx 0))
    (dolist (arg args)
      (cond
        ;; Record arg with per-field adjs: distribute the next N deltas
        ;; across the arg's fields in declaration order (alist iteration).
        ((and (symbolp arg)
              *record-param-field-adjs*
              (gethash arg *record-param-field-adjs*))
         (let ((field-alist (gethash arg *record-param-field-adjs*)))
           (loop for (field-name-str . field-adj-sym) in field-alist
                 when (< delta-idx n-fp)
                 do (push `(set! ,field-adj-sym
                                 (+ ,field-adj-sym ,(nth delta-idx deltas)))
                          accum-forms)
                    (incf delta-idx))))
        ;; Scalar symbol arg: single delta accumulation (existing behavior).
        ((symbolp arg)
         (when (< delta-idx n-fp)
           (push `(set! ,(funcall local-adj-fn arg)
                        (+ ,(funcall local-adj-fn arg) ,(nth delta-idx deltas)))
                 accum-forms)
           (incf delta-idx)))
        (t nil)))
    (setf accum-forms (nreverse accum-forms))
    (cond
      ;; Tensor-arg case: emit the call with grad-tensors appended.
      ;; The grad-tensor for each tensor arg is the kernel-side `<arg>_GRAD`
      ;; symbol (convention used at the kernel level for grad-out cells).
      ;; `&out` appears in the signature, not the call form.
      (has-tensor-args
       (let* ((grad-args
               (loop for i in tensor-indices
                     for arg = (nth i args)
                     when (symbolp arg)
                     collect (intern (format nil "~A_GRAD" (symbol-name arg))
                                     (symbol-package arg))))
              (call-form `(,bkwd-fn ,@args ,@t-adj-forms ,@grad-args)))
         (cond
           ;; Has scalar deltas too: multi-value bind, then accumulate, plus call.
           ((or accum-forms (> n-fp 0))
            (funcall emit-fn
                     `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                        (let (,(append deltas (list call-form)))
                          ,@accum-forms))))
           ;; Tensor-only: just emit the call as a statement.
           (t (funcall emit-fn call-form)))))
      ;; No tensors, has scalar accumulations: existing multi-value-bind path.
      (accum-forms
       (funcall emit-fn
                `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                   (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                     ,@accum-forms))))
      (t nil))))



(defun %crisp-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a tensor/vector/matrix
   storage handle. Vectors (N=1) and matrices (N=2) are syntactic sugar for tensor,
   so a single head check covers all three."
  (let* ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR"))))

(defun %crisp-float-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC resolves to a tensor/vector/matrix whose element type
   is a float type (float, double, etc.).  Non-float tensors (e.g. vector long)
   are not differentiable and should not receive gradient parameters."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR")
         (%crisp-float-type-p (second canonical)))))





(defun %ensure-tensor-read-write (type-spec)
  "For backwards compatibility: returns the canonical 6-tuple unchanged.
   Access was removed; tensors are always read-write."
  type-spec)




(defun %strip-accessor-tildes (accessor)
  "Strips trailing tilde, and leading tilde if present, from an accessor
   name string.  X~ → X, ~X~ → X."
  (let* ((no-trail (subseq accessor 0 (1- (length accessor)))))
    (if (and (> (length no-trail) 0)
             (cl:char= (cl:char no-trail 0) #\~))
        (subseq no-trail 1)
        no-trail)))




(defun %handle-math-and-trig-backward (v expr emit-fn local-adj-fn adjoint-map)
  "Handles mathematical operations (+, -, *, /) and trigonometric functions (sin, cos)."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (cond
      ((eq (car expr) '+)
       (let ((a (cadr expr)) (b (caddr expr)))
         (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
         (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))
         t))
      ((eq (car expr) '-)
       (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
         (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
         (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))
         t))
      ((eq (car expr) '*)
       (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
         (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
         (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))
         t))
      ((eq (car expr) '/)
       (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
         (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
         (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))
         t))
      ((eq (car expr) 'sin)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
           (let* ((a-adj (local-adj a))
                  (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
             (setf (gethash cos-a adjoint-map) cos-a)
             (emit `(set! ,cos-a (cos ,a)))
             (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj)))))
           t)))
      ((eq (car expr) 'cos)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
           (let* ((a-adj (local-adj a))
                  (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
             (setf (gethash sin-a adjoint-map) sin-a)
             (emit `(set! ,sin-a (sin ,a)))
             (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj)))))
           t)))
      (t nil))))

(defun %handle-tilde-backward (v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms)
  "Handles the tilde (~) indexing operation."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (let* ((src     (cadr expr))
           (indices (cddr expr))
           (v-adj   (local-adj v)))
      (when (symbolp src)
        (cond
          ((and indices tensor-inputs-ht (gethash src tensor-inputs-ht))
           (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                   (symbol-package src))))
             (emit `(atomic-add! (~ ,grad-sym ,@indices) ,v-adj))))
          ((and (null indices) tensor-inputs-ht (gethash src tensor-inputs-ht))
           (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                   (symbol-package src))))
             (emit `(atomic-add! (~ ,grad-sym) ,v-adj))))
          ((and indices scratch-tile-syms
                (gethash src scratch-tile-syms))
           (let ((src-adj (intern (format nil "~A_ADJ" (symbol-name src))
                                  (symbol-package src))))
             (emit `(set! (~ ,src-adj ,@indices)
                          (+ (~ ,src-adj ,@indices) ,v-adj)))))
          (t
           (emit `(set! ,(local-adj src) (+ ,(local-adj src) ,v-adj))))))
      t)))

(defun %handle-sub-fn-call-backward (v expr emit-fn local-adj-fn hof-handler-fn)
  "Handles differentiable sub-function calls."
  (flet ((local-adj (x) (funcall local-adj-fn x)))
    (let* ((fn   (car expr))
           (args (cdr expr))
           (info (gethash fn *differentiable-functions*)))
      (if (getf info :hof)
          (if hof-handler-fn
              (funcall hof-handler-fn fn args v)
              (error "HOF handler required for sub-function ~A but not provided" fn))
          (%emit-sub-fn-backward fn args
                                 (getf info :bkwd-name)
                                 (list (local-adj v))
                                 (getf info :n-float-params)
                                 (symbol-package v)
                                 emit-fn local-adj-fn
                                 (if (symbolp v) (symbol-name v) "BW"))))
    t))

(defun %is-accessor-p (expr)
  (and (consp expr)
       (symbolp (car expr))
       (= (length (cdr expr)) 1)
       (let ((fname (symbol-name (car expr))))
         (and (> (length fname) 1)
              (cl:char= (cl:char fname (1- (length fname))) #\~)))))

(defun %handle-accessor-backward (v expr emit-fn local-adj-fn adjoint-map)
  "Handles record and struct accessors."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (cond
      ((and *record-param-field-adjs*
            (symbolp (cadr expr))
            (gethash (cadr expr) *record-param-field-adjs*))
       (let* ((accessor (symbol-name (car expr)))
              (field-name-str (%strip-accessor-tildes accessor))
              (record-sym (cadr expr))
              (field-alist (gethash record-sym *record-param-field-adjs*))
              (field-entry (assoc field-name-str field-alist :test #'string-equal))
              (field-adj-sym (cdr field-entry))
              (v-adj (local-adj v)))
         (when field-adj-sym
           (setf (gethash field-adj-sym adjoint-map) field-adj-sym)
           (emit `(set! ,field-adj-sym (+ ,field-adj-sym ,v-adj))))
         t))
      ((and *struct-kernel-param-shadows*
            (symbolp (cadr expr))
            (gethash (cadr expr) *struct-kernel-param-shadows*))
       (let* ((accessor (symbol-name (car expr)))
              (field-name-str (%strip-accessor-tildes accessor))
              (struct-sym (cadr expr))
              (entry (gethash struct-sym *struct-kernel-param-shadows*))
              (field-alist (if (and (consp entry) (symbolp (car entry)))
                               (cdr entry)
                               entry))
              (field-entry (assoc field-name-str field-alist :test #'string-equal))
              (field-info (cdr field-entry))
              (v-adj (local-adj v)))
         (cond
           ((%nested-field-info-p field-info) nil)
           ((symbolp field-info)
            (setf (gethash field-info adjoint-map) field-info)
            (emit `(set! ,field-info (+ ,field-info ,v-adj))))
           (t nil))
         t))
      (t
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
           (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
         t)))))

(defun %handle-constructor-backward (v expr emit-fn local-adj-fn adjoint-map)
  "Handles %CONSTRUCT-STRUCT backward rule."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (let* ((ctor-args (cddr expr))
           (field-alist (gethash v *record-param-field-adjs*)))
      (loop for (field-name-str . field-adj-sym) in field-alist
            for ctor-arg in ctor-args
            when (and (symbolp ctor-arg) field-adj-sym)
            do (setf (gethash field-adj-sym adjoint-map) field-adj-sym)
               (emit `(set! ,(local-adj ctor-arg)
                            (+ ,(local-adj ctor-arg) ,field-adj-sym)))))
    t))

(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht
                                           scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
    ((and (consp expr) (member (car expr) '(+ - * / sin cos) :test #'eq))
     (%handle-math-and-trig-backward v expr emit-fn local-adj-fn adjoint-map))
    ((and (consp expr) (eq (car expr) '~))
     (%handle-tilde-backward v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms))
    ((and (consp expr)
          (symbolp (car expr))
          (gethash (car expr) *differentiable-functions*))
     (%handle-sub-fn-call-backward v expr emit-fn local-adj-fn hof-handler-fn))
    ((%is-accessor-p expr)
     (%handle-accessor-backward v expr emit-fn local-adj-fn adjoint-map))
    ((and (consp expr) (symbolp (car expr))
          (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
          *record-param-field-adjs*
          (gethash v *record-param-field-adjs*))
     (%handle-constructor-backward v expr emit-fn local-adj-fn adjoint-map))
    ((and (consp expr) (symbolp (car expr))
          (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
     nil)
    ((and (consp expr) (symbolp (car expr))
          (string= (symbol-name (car expr)) "IF"))
     nil)
    ((and (consp expr) (symbolp (car expr))
          (%backward-skip-fn-p (car expr)))
     nil)
    ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
       (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
    (t nil)))



;; 107 iteration-local adjoint reset fix.
;;
;; Bug: the structure-preserving walker mirrored forward (dotimes ...) into
;; backward (dotimes ...) correctly, but did not re-zero adjoint allocas that
;; belong to variables bound INSIDE the loop body.  The chain rule emits
;; `(set! adj (+ adj ...))` (accumulate), and the adj allocas are hoisted to
;; the function entry block with a one-time store-of-zero — so across
;; iterations they accumulate stale per-iteration contributions and produce
;; wrong gradients whenever a thread executes more than one iteration of the
;; backward dotimes (e.g. any grid-stride / tensor-stride kernel run with
;; gsize < len, which is the normal case).
;;
;; Fix: at the top of the backward dotimes body, store the appropriately-
;; typed zero into every adj that corresponds to a variable bound somewhere
;; inside the iteration body.  Vars bound outside the loop (kernel params,
;; outer let* bindings) are NOT iter-local — their adjoints are real
;; gradient accumulators and must persist across iterations.
;;
;; %collect-locally-bound-vars walks a list of body forms and returns the
;; set of symbols introduced by single-/multi-value bindings, the dotimes
;; induction var, and any let bindings inside (recurses through let,
;; dotimes, if, progn).
;;
;; The DOTIMES case in process-form runs the body walk first (so chain
;; rule populates adjoint-map), then emits a `(set! adv ZERO)` for each
;; iter-local var whose adj is actually used.  any-output-double is
;; precomputed once at the top of the function (used to pick `0.0` vs
;; `(as double 0.0)`) instead of being computed only at the post-walk
;; let-wrap stage.



(defun %collect-locally-bound-vars (body-forms)
  "Returns a list of distinct symbols introduced as bindings anywhere
   inside BODY-FORMS (a list of forms).  Includes single-value bindings
   `(v expr)`, multi-value bindings `(v0 v1 ... expr)`, the induction var
   of nested DOTIMES, and the bound vars of nested LET.  Recurses through
   LET / DOTIMES / IF / PROGN / WHEN / UNLESS bodies.  SET! and DECLARE
   introduce no bindings, so they are not scanned.  Used by the AD walker
   to identify adjoint allocas that must be reset at the top of each
   backward loop iteration."
  (let ((vars nil))
    (labels ((push-var (v)
               (when (and (symbolp v) (not (member v vars :test #'eq)))
                 (push v vars)))
             (scan (form)
               (cond
                 ((or (null form) (symbolp form) (not (consp form))) nil)
                 ((not (symbolp (car form))) nil)
                 ((or (string-equal (symbol-name (car form)) "DECLARE")
                      (string-equal (symbol-name (car form)) "SET!")) nil)
                 ((string-equal (symbol-name (car form)) "LET")
                  (dolist (b (cadr form))
                    (when (and (consp b) (symbolp (car b)))
                      (push-var (car b))))
                  (dolist (b (cddr form)) (scan b)))
                 ((string-equal (symbol-name (car form)) "DOTIMES")
                  (let ((binding (cadr form)))
                    (when (and (consp binding) (symbolp (car binding)))
                      (push-var (car binding))))
                  (dolist (b (cddr form)) (scan b)))
                 ((string-equal (symbol-name (car form)) "IF")
                  (when (caddr form) (scan (caddr form)))
                  (when (cadddr form) (scan (cadddr form))))
                 ((or (string-equal (symbol-name (car form)) "WHEN")
                      (string-equal (symbol-name (car form)) "UNLESS"))
                  (dolist (sub (cddr form)) (scan sub)))
                 ((string-equal (symbol-name (car form)) "PROGN")
                  (dolist (sub (cdr form)) (scan sub)))
                 ;; Single-value binding: (v expr)
                 ((and (= (length form) 2) (symbolp (car form)))
                  (push-var (car form)))
                 ;; Multi-value binding: (v0 v1 ... expr) where all but last are syms
                 ((and (>= (length form) 3)
                       (every #'symbolp (butlast form)))
                  (dolist (v (butlast form)) (push-var v)))
                 (t nil))))
      (dolist (f body-forms) (scan f)))
    (nreverse vars)))


(defun %augment-scratch-adj-bindings (bindings kernel-pkg)
  "For each binding (var (make-scratch-X ...)), inject a paired
   (var_ADJ (make-scratch-X ...)) binding right after.  For other bindings,
   pass through unchanged.  Phase 1c initial: assumes same-element-type
   adjoint (no ulong→double promotion yet)."
  (loop for b in bindings
        if (and (consp b) (= (length b) 2) (symbolp (car b))
                (consp (cadr b)) (symbolp (caadr b))
                (member (symbol-name (caadr b))
                        '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                          "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                        :test #'string=))
          append (list b
                       (let* ((var (car b))
                              (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                               (or kernel-pkg (symbol-package var))))
                              (init (cadr b)))
                         (list var-adj init)))
        else collect b))


(defun %tlc-bwd-adj-name (sym inputs outputs local-adj-fn kernel-pkg)
  "Returns the backward-pass adjoint symbol for a forward arg SYM:
     - if SYM is in INPUTS or OUTPUTS  → <SYM>_GRAD  (kernel param)
     - otherwise (let-bound local)     → <SYM>_ADJ  (direct intern; NOT
       via local-adj-fn, because local-adj-fn would add the sym to the
       adjoint-map, which causes the wrapping let to scalar-initialize it
       — wrong for tensor adjoints.  The auto-allocated LET binding for
       <var>_ADJ as a make-scratch-* is the only initializer needed.)"
  (declare (ignore local-adj-fn))
  (cond
    ((or (member sym inputs) (member sym outputs))
     (intern (format nil "~A_GRAD" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))
    (t
     (intern (format nil "~A_ADJ" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))))

(defun %tlc-extract-transpose-key (key-args)
  "Returns the value of :transpose in KEY-ARGS, or NIL if absent."
  (loop for (k v) on key-args by #'cddr
        when (eq k :transpose) return v
        finally (cl:return nil)))


(defun %gfw-process-set! (form emit-fn local-adj-fn inputs outputs scratch-tile-syms intermediate-zero kernel-pkg)
  (let ((place (cadr form))
        (val   (caddr form)))
    (when (and (consp place) (eq (car place) '~) (symbolp val))
      (let ((target  (cadr place))
            (indices (cddr place)))
        (cond
          ((member target outputs)
           (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                   (symbol-package target))))
             (funcall emit-fn `(set! ,(funcall local-adj-fn val)
                                     (+ ,(funcall local-adj-fn val) (~ ,tgt-grad ,@indices))))))
          ((member target inputs)
           (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                  target target))
          ((and scratch-tile-syms (gethash target scratch-tile-syms))
           (let ((tgt-adj (%tlc-bwd-adj-name target inputs outputs local-adj-fn kernel-pkg)))
             (funcall emit-fn `(set! ,(funcall local-adj-fn val)
                                     (+ ,(funcall local-adj-fn val) (~ ,tgt-adj ,@indices))))
             (funcall emit-fn `(set! (~ ,tgt-adj ,@indices) ,intermediate-zero))))
          (t nil))))))


(defun %gfw-process-let (form emit-fn process-form-fn bindings augmented-bindings body)
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
          (funcall process-form-fn b #'local-emit))))
    (funcall emit-fn `(let ,augmented-bindings ,@(nreverse local-forms)))))


(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit)))
    (let ((zero-resets
           (loop for v in local-vars
                 for adv = (gethash v adjoint-map)
                 when adv
                 collect `(set! ,adv ,intermediate-zero))))
      (funcall emit-fn `(dotimes ,binding ,@zero-resets ,@(nreverse local-forms))))))


(defun %gfw-process-if (form emit-fn process-form-fn cond-form then-form else-form)
  (declare (ignore form))
  (let ((then-local nil)
        (else-local nil))
    (when then-form
      (funcall process-form-fn then-form (lambda (f) (push f then-local))))
    (when (and else-form (not (null else-form)))
      (funcall process-form-fn else-form (lambda (f) (push f else-local))))
    (let ((then-body (cond
                       ((null then-local) nil)
                       ((= (length then-local) 1) (first then-local))
                       (t `(progn ,@(nreverse then-local)))))
          (else-body (cond
                       ((null else-local) nil)
                       ((= (length else-local) 1) (first else-local))
                       (t `(progn ,@(nreverse else-local))))))
      (funcall emit-fn
               (if else-body
                   `(if ,cond-form ,(or then-body 'nil) ,else-body)
                   `(if ,cond-form ,(or then-body 'nil)))))))


(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                               &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   Phase 1c: adds LOAD-TILE-COORDS / STORE-TILE-COORDS clauses to process-form
   that emit %load-tile-coords-bwd / %store-tile-coords-bwd with the correct
   adjoint symbols.  Also extends the LET case to auto-allocate paired
   <var>_ADJ scratch tensors for make-scratch-* bindings.

   Bug 032 fix: SET! on a local-scratch tile (target neither input nor
   output) now emits a proper consume + reset pair so the RHS chain rule
   propagates through tile mutations."
  (let* ((record-temp-entries
          (loop for form in flat-anf
                when (and (consp form) (= (length form) 2)
                          (symbolp (car form))
                          (consp (cadr form))
                          (symbolp (caadr form))
                          (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                (let* ((temp-sym (car form))
                       (expr (cadr form))
                       (record-name (second expr))
                       (pkg (or kernel-pkg (symbol-package temp-sym))))
                  (when (or (%crisp-record-type-p record-name)
                            (%crisp-struct-type-p record-name))
                    (let* ((fields (%get-record-runtime-fields record-name))
                           (field-alist
                            (loop for (fname ftype) in fields
                                  collect (cons (symbol-name fname)
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                        pkg)))))
                      (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (let ((ht (when (or record-temp-entries *record-param-field-adjs*)
                      (make-hash-table :test 'eq))))
            (when ht
              (when *record-param-field-adjs*
                (maphash (lambda (k v) (setf (gethash k ht) v))
                         *record-param-field-adjs*))
              (dolist (entry record-temp-entries)
                (setf (gethash (car entry) ht) (cdr entry))))
            ht)))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym  in inputs
                     for typ  in input-types
                     when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht))
            ;; Bug 032: collect locally-bound scratch tile syms (those
            ;; bound via make-scratch-vector / -matrix / -tensor / -cell
            ;; anywhere in flat-anf) so the `~` and SET! backward cases
            ;; can route indexed accesses on them to their _ADJ tensor
            ;; instead of polluting the scalar adjoint-map.
            (scratch-tile-syms
             (let ((ht (make-hash-table :test 'eq)))
               (loop for form in flat-anf
                     when (and (consp form) (= (length form) 2)
                               (symbolp (car form))
                               (consp (cadr form)) (symbolp (caadr form))
                               (member (symbol-name (caadr form))
                                       '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                         "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                                       :test #'string=))
                     do (setf (gethash (car form) ht) t))
               ht)))
        (flet ((promotes-to-double-p (t-spec)
                    (let ((promoted (%promote-to-float-adjoint t-spec)))
                      (or (eq promoted 'double)
                          (and (consp promoted) (eq (second promoted) 'double))))))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (intermediate-zero (if any-output-double '(as double 0.0) 0.0)))
            (labels ((local-adj (v)
                       (or (gethash v adjoint-map)
                           (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                              (or kernel-pkg (symbol-package v)))))
                             (setf (gethash v adjoint-map) adv)
                             adv)))
                     (emit (form)
                       (push form backward-forms))
                     (hof-inline-backward (fn args v)
                       (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                         (unless hof-data
                           (error "HOF ~A not found in *differentiable-hof-store*" fn))
                         (let* ((param-syms   (getf hof-data :param-syms))
                                (fn-param-idx (getf hof-data :fn-param-idx))
                                (body-forms   (getf hof-data :body-forms))
                                (fn-arg       (nth fn-param-idx args))
                                (concrete-fn  (cond
                                                ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                 (cadr fn-arg))
                                                ((symbolp fn-arg) fn-arg)
                                                (t nil))))
                           (unless concrete-fn
                             (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                           (let* ((fn-param      (nth fn-param-idx param-syms))
                                  (subst-alist
                                   (loop for p in param-syms
                                         for a in args
                                         for i from 0
                                         unless (= i fn-param-idx)
                                         collect (cons p a)))
                                  (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                  (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                         subst-body))
                                  (anf-body      (mapcar #'anf-transform concrete-body))
                                  (hof-flat      (flatten-anf-body anf-body))
                                  (hof-flat-norm
                                   (let ((last-f (car (last hof-flat))))
                                     (if (or (symbolp last-f)
                                             (and (consp last-f) (eq (first last-f) 'return)))
                                         hof-flat
                                         (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                (symbol-package v))))
                                           (append (butlast hof-flat)
                                                   (list (list ret-sym last-f) ret-sym))))))
                                  (return-vars   (%extract-return-vars hof-flat-norm)))
                             (dolist (rv return-vars)
                               (setf (gethash rv adjoint-map) (local-adj v)))
                             (dolist (hf-form (reverse hof-flat-norm))
                               (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                 (let ((hv    (car hf-form))
                                       (hexpr (cadr hf-form)))
                                   (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                  :hof-handler-fn #'hof-inline-backward
                                                                  :error-on-unknown t
                                                                  :tensor-inputs-ht nil
                                                                  :scratch-tile-syms scratch-tile-syms))))))))
                     (process-form (form emit-fn)
                       (cond
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DECLARE")) nil)

                         ;; Phase 1c: load-tile-coords forward → backward.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LOAD-TILE-COORDS"))
                          (let* ((src      (second form))
                                 (tile     (third form))
                                 (origins  (fourth form))
                                 (key-args (nthcdr 4 form))
                                 (transpose-v (%tlc-extract-transpose-key key-args))
                                 (src-adj (%tlc-bwd-adj-name src inputs outputs
                                                              #'local-adj kernel-pkg))
                                 (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                               #'local-adj kernel-pkg))
                                 (bwd-sym (intern "%LOAD-TILE-COORDS-BWD"
                                                  (find-package :crisp-language)))
                                 (bwd-form (if transpose-v
                                               (list bwd-sym src-adj tile-adj origins :transpose transpose-v)
                                               (list bwd-sym src-adj tile-adj origins))))
                            (funcall emit-fn bwd-form)))

                         ;; Phase 1c: store-tile-coords forward → backward.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "STORE-TILE-COORDS"))
                          (let* ((tile     (second form))
                                 (dest     (third form))
                                 (origins  (fourth form))
                                 (key-args (nthcdr 4 form))
                                 (transpose-v (%tlc-extract-transpose-key key-args))
                                 (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                               #'local-adj kernel-pkg))
                                 (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                #'local-adj kernel-pkg))
                                 (bwd-sym (intern "%STORE-TILE-COORDS-BWD"
                                                  (find-package :crisp-language)))
                                 (bwd-form (if transpose-v
                                               (list bwd-sym tile-adj dest-adj origins :transpose transpose-v)
                                               (list bwd-sym tile-adj dest-adj origins))))
                            (funcall emit-fn bwd-form)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "SET!"))
                          (%gfw-process-set! form emit-fn #'local-adj inputs outputs scratch-tile-syms intermediate-zero kernel-pkg))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LET"))
                          (let* ((bindings (cadr form))
                                 (augmented-bindings (%augment-scratch-adj-bindings bindings kernel-pkg))
                                 (body (cddr form)))
                            (%gfw-process-let form emit-fn #'process-form bindings augmented-bindings body)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DOTIMES"))
                          (let* ((binding (cadr form))
                                 (body (cddr form))
                                 (local-vars (%collect-locally-bound-vars body)))
                            (%gfw-process-dotimes form emit-fn #'process-form binding body local-vars adjoint-map intermediate-zero)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "IF"))
                          (let* ((cond-form (cadr form))
                                 (then-form (caddr form))
                                 (else-form (cadddr form)))
                            (%gfw-process-if form emit-fn #'process-form cond-form then-form else-form)))

                         ;; Bug 032 fix part 2: WHEN and UNLESS were not handled
                         ;; by the AD walker, so any forms inside them (including
                         ;; the load/store-tile-coords inner body's set!s after
                         ;; workgroup-stride expansion) were silently dropped.
                         ;; Desugar them to IF + PROGN here and let the IF case
                         ;; handle the rest.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "WHEN"))
                          (let* ((pkg     (find-package :crisp-language))
                                 (if-sym  (intern "IF"    pkg))
                                 (progn-sym (intern "PROGN" pkg))
                                 (cond-form (cadr form))
                                 (body      (cddr form))
                                 (then      (cond ((null body) 'nil)
                                                  ((= (length body) 1) (first body))
                                                  (t (cons progn-sym body)))))
                            (process-form (list if-sym cond-form then 'nil) emit-fn)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "UNLESS"))
                          (let* ((pkg     (find-package :crisp-language))
                                 (if-sym  (intern "IF"    pkg))
                                 (progn-sym (intern "PROGN" pkg))
                                 (cond-form (cadr form))
                                 (body      (cddr form))
                                 (then      (cond ((null body) 'nil)
                                                  ((= (length body) 1) (first body))
                                                  (t (cons progn-sym body)))))
                            ;; (unless C B) = (if C nil B) — pass B as the else slot.
                            (process-form (list if-sym cond-form 'nil then) emit-fn)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "PROGN"))
                          (dolist (sub (reverse (cdr form)))
                            (process-form sub emit-fn)))

                         ((and (listp form) (= (length form) 2) (symbolp (car form)))
                          (%handle-single-value-backward (car form) (cadr form)
                                                         adjoint-map emit-fn #'local-adj
                                                         :hof-handler-fn #'hof-inline-backward
                                                         :error-on-unknown t
                                                         :tensor-inputs-ht tensor-inputs-ht
                                                         :scratch-tile-syms scratch-tile-syms))

                         ((and (listp form) (>= (length form) 3)
                               (symbolp (car form))
                               (every #'symbolp (butlast form)))
                          (let* ((result-vars (butlast form))
                                 (expr        (car (last form))))
                            (when (and (consp expr)
                                       (symbolp (car expr))
                                       (gethash (car expr) *differentiable-functions*))
                              (let* ((fn   (car expr))
                                     (args (cdr expr))
                                     (info (gethash fn *differentiable-functions*))
                                     (bkwd (getf info :bkwd-name))
                                     (n-fp (getf info :n-float-params))
                                     (pkg  (symbol-package (car result-vars)))
                                     (t-adjs (mapcar #'local-adj result-vars)))
                                (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                       emit-fn #'local-adj "BW")))))

                         (t nil))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                                 (or kernel-pkg (symbol-package in))))
                             (canon-type (canonicalize-type-specifier
                                          (if (listp in-type) in-type (list in-type))))
                             (is-cell-input
                              (and (consp canon-type)
                                   (string-equal (symbol-name (first canon-type)) "CELL")))
                             (is-tensor-input
                              (or (%crisp-float-tensor-type-p in-type)
                                  (%crisp-integer-tensor-type-p in-type)))
                             (is-scalar-wrapped
                              (and (not is-cell-input) (not is-tensor-input)
                                   (or (%crisp-integer-scalar-type-p in-type)
                                       (%crisp-float-type-p in-type)))))
                        (cond
                          (is-tensor-input nil)
                          (is-cell-input     (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (t                 (emit `(set! ,in-grad ,(local-adj in)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          (cond
                            (in-type
                             (if (promotes-to-double-p in-type) '(as double 0.0) 0.0))
                            (any-output-double '(as double 0.0))
                            (t 0.0)))))
                     (local-bindings (loop for v being the hash-keys of adjoint-map
                                           using (hash-value adv)
                                           collect `(,adv ,(funcall typed-zero-for v))))
                     ;; Phase 1c: auto-allocate <var>_ADJ paired scratch
                     ;; tensors for each make-scratch-* binding in flat-anf.
                     ;; The forward let-bindings already give us <var>; the
                     ;; backward wants both <var> and <var>_ADJ.
                     ;; Phase 1c initial: assumes same element-type (no
                     ;; ulong→double promotion yet; defer to a sub-step).
                     (scratch-adj-bindings
                      (loop for form in flat-anf
                            when (and (consp form) (= (length form) 2)
                                      (symbolp (car form))
                                      (consp (cadr form)) (symbolp (caadr form))
                                      (member (symbol-name (caadr form))
                                              '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                                "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                                              :test #'string=))
                            collect (let* ((var (car form))
                                           (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                                            (or kernel-pkg (symbol-package var)))))
                                      (list var-adj (cadr form)))))
                     (result `(let ,(append scratch-adj-bindings local-bindings)
                                ,@(nreverse backward-forms))))
                result))))))))

;;; ----------------------------------------------------------
;;; %crisp-float-type-p
;;; ----------------------------------------------------------

(defun %crisp-float-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp
float-category scalar type (float, double, half, bfloat16).
Resolves def-type aliases via *crisp-type-aliases* first, then checks
*crisp-types* directly (for primitives like 'float), then falls back
to compute-base-type for derived types."
  (let* ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec))
         (direct-info (and (symbolp resolved) (gethash resolved *crisp-types*)))
         (base (if direct-info resolved (compute-base-type resolved)))
         (info (when base (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :float))))

;;; ----------------------------------------------------------
;;; %crisp-record-type-p
;;; ----------------------------------------------------------

(defun %crisp-record-type-p (type-spec)
  "Returns T if TYPE-SPEC names a def-record (category :record).
   Handles parameterized forms like (V-POINT :EARNESTNESS 3.0)."
  (let* ((base (if (consp type-spec) (first type-spec) type-spec))
             (info (gethash base *crisp-types*)))
    (and info (eq (crisp-type-category info) :record))))

;;; ----------------------------------------------------------
;;; %get-record-runtime-fields
;;; ----------------------------------------------------------

(defun %get-record-runtime-fields (rec-type-spec)
  "Returns a list of (FIELD-NAME RESOLVED-FIELD-TYPE) for the runtime
   (non-:c-t) members of the record type named by REC-TYPE-SPEC.
   Handles parameterised forms like (V-POINT :EARNESTNESS 3.0)."
  (let* ((base (if (consp rec-type-spec) (first rec-type-spec) rec-type-spec))
             (struct-def (or (gethash base *crisp-structs*)
                             (gethash (intern (symbol-name base) :crisp-language)
                                      *crisp-structs*))))
    (when struct-def
      (loop for m in (crisp-struct-definition-members struct-def)
               unless (and (consp m) (eq (third m) :c-t))
               collect (list (first m)
                                 (compute-base-type (second m)))))))

;;; ----------------------------------------------------------
;;; %record-accessor-system-generated-p
;;; ----------------------------------------------------------

(defun %record-accessor-system-generated-p (accessor-sym rec-type)
  "Returns T if ACCESSOR-SYM (e.g. X~) is the single system-generated
   accessor for REC-TYPE — i.e. it has NOT been user-overloaded.
   Heuristic: count *function-table* entries whose first parameter type
   matches REC-TYPE.  Exactly 1 means system-generated only."
  (let* ((sigs (gethash accessor-sym *function-table*))
             (base-name (symbol-name (if (consp rec-type) (first rec-type) rec-type)))
             (matching
              (loop for sig in sigs
                       when (let* ((params (function-signature-parameters sig))
                                      (first-param (first params))
                                      (first-type (and first-param
                                                        (parameter-def-type first-param))))
                              (and first-type
                                   (string-equal (symbol-name
                                                  (if (consp first-type)
                                                      (first first-type)
                                                      first-type))
                                                 base-name)))
                       collect sig)))
    (= (length matching) 1)))

;;; ----------------------------------------------------------
;;; %record-field-param-sym
;;; ----------------------------------------------------------

(defun %record-field-param-sym (param-sym field-name pkg)
  "Creates the exploded scalar symbol for PARAM-SYM's FIELD-NAME.
   E.g. VP + X -> VP_X."
  (intern (format nil "~a_~a"
                  (symbol-name param-sym)
                  (symbol-name field-name))
          pkg))

;;; ----------------------------------------------------------
;;; %substitute-record-accessors
;;; ----------------------------------------------------------

(defun %substitute-record-accessors (form record-subs-ht record-type-ht)
  "Recursively walks FORM (a raw Crisp body S-expression) and substitutes:
     (~field~ p)  -> p_field   (always, ~field~ is non-overloadable)
     (field~  p)  -> p_field   (only when field~ is system-generated for p's type)
   RECORD-SUBS-HT maps param-sym -> alist of (field-sym . exploded-sym).
   RECORD-TYPE-HT  maps param-sym -> rec-type-spec."
  (flet ((raw-accessor-p (name-str)
               ;; ~field~ : starts AND ends with ~, length > 2
               (and (> (length name-str) 2)
                    (cl:char= (cl:char name-str 0) #\~)
                    (cl:char= (cl:char name-str (1- (length name-str))) #\~)))
             (regular-accessor-p (name-str)
               ;; field~ : ends with ~ but does NOT start with ~
               (and (> (length name-str) 1)
                    (cl:char= (cl:char name-str (1- (length name-str))) #\~)
                    (cl:char/= (cl:char name-str 0) #\~))))
    (cond
      ;; ---- Atom: pass through --------------------------------
      ((atom form) form)

      ;; ---- (~field~ p) : raw accessor call -------------------
      ((and (= (length form) 2)
            (symbolp (first form))
            (raw-accessor-p (symbol-name (first form))))
       (let* ((op-name  (symbol-name (first form)))
                 (field-name (intern (subseq op-name 1 (1- (length op-name)))
                                     (symbol-package (first form))))
                 (arg     (second form))
                 (fld-map (gethash arg record-subs-ht)))
         (if fld-map
             (let ((hit (assoc field-name fld-map :test #'string-equal)))
               (if hit (cdr hit) form))
             ;; arg is not a record param — recurse normally
             (list (first form)
                      (%substitute-record-accessors arg record-subs-ht record-type-ht)))))

      ;; ---- (field~ p) : regular accessor call ----------------
      ((and (= (length form) 2)
            (symbolp (first form))
            (regular-accessor-p (symbol-name (first form))))
       (let* ((op      (first form))
                 (op-name (symbol-name op))
                 (field-name (intern (subseq op-name 0 (1- (length op-name)))
                                     (symbol-package op)))
                 (arg     (second form))
                 (fld-map (gethash arg record-subs-ht))
                 (rec-type (gethash arg record-type-ht)))
         (if (and fld-map rec-type
                  (%record-accessor-system-generated-p op rec-type))
             (let ((hit (assoc field-name fld-map :test #'string-equal)))
               (if hit (cdr hit)
                   ;; field name not in this record — recurse
                   (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form)))
             ;; not system-generated, or arg not a record param — recurse
             (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form))))

      ;; ---- General cons: recurse on all sub-forms ------------
      (t
       (mapcar (lambda (x) (%substitute-record-accessors x record-subs-ht record-type-ht)) form)))))

;;; ----------------------------------------------------------
;;; %fix-record-grad-cell-emissions
;;; ----------------------------------------------------------

(defun %fix-record-grad-cell-emissions (form grad-cell-syms)
  "Post-processes the backward-walk output.
   For any (SET! var expr) where VAR is in GRAD-CELL-SYMS,
   rewrites to (SET! (~ var) expr), since the gradient output
   for a record field is a cell, not a plain scalar.
   GRAD-CELL-SYMS is a list of symbols that need cell-style emission."
  (flet ((grad-cell-p (sym)
               (and (symbolp sym) (member sym grad-cell-syms :test #'eq))))
    (cond
      ((atom form) form)
      ;; (set! var expr) — var is a grad-cell sym
      ((and (consp form)
            (eq (first form) 'set!)
            (= (length form) 3)
            (grad-cell-p (second form)))
       (list 'set!
                (list '~ (second form))
                (%fix-record-grad-cell-emissions (third form) grad-cell-syms)))
      ;; recurse
      (t
       (mapcar (lambda (x) (%fix-record-grad-cell-emissions x grad-cell-syms)) form)))))

;;; ----------------------------------------------------------
;;; %expand-record-kernel-inputs
;;; ----------------------------------------------------------

(defun %expand-record-kernel-inputs (inputs input-types pkg)
  "Recursively expands record-typed inputs into their scalar fields,
   chasing through nested records.  Also handles struct kernel inputs
   per the Shadow Struct design: structs are NOT exploded; instead a
   single shadow-grad-cell is paired with each struct param.

   Returns 9 values: (flat-inputs flat-input-types reassembly-bindings
   grad-out-params grad-out-types record-subs-ht record-type-ht
   grad-cell-syms struct-shadow-info).

   The 9th value, struct-shadow-info, is an alist:
     ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)
   used by %fix-struct-shadow-writes to emit the final shadow-write.

   Leaf scalar fields (float or integer) produce grad cells per 101.
   Nested-record fields produce a synthetic intermediate sym that gets
   registered in record-subs-ht/record-type-ht so the substitution
   machinery walks through it; their leaf fields are further exploded."
  (let ((flat-inputs        '())
        (flat-input-types   '())
        (reassembly-bindings '())
        (grad-out-params    '())
        (grad-out-types     '())
        (record-subs-ht     (make-hash-table :test 'eq))
        (record-type-ht     (make-hash-table :test 'eq))
        (grad-cell-syms     '())
        (struct-shadow-info '()))
    (labels
        ((explode (p t-spec)
           "Destructure parameter P of type T-SPEC.  Side effects push to
            the closure-captured accumulators.  Returns no useful value."
           (cond
             ((%crisp-record-type-p t-spec)
              (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                     (fields    (%get-record-runtime-fields t-spec))
                     (make-sym  (intern (format nil "MAKE-~a" (symbol-name base-type)) pkg))
                     (field-info-list
                      (loop for (fname ftype) in fields
                            collect (list fname ftype
                                          (%record-field-param-sym p fname pkg)))))
                (setf (gethash p record-subs-ht)
                      (loop for (fname ftype fsym) in field-info-list
                            collect (cons fname fsym)))
                (setf (gethash p record-type-ht) t-spec)
                (loop for (fname ftype fsym) in field-info-list do
                  (cond
                    ((%crisp-record-type-p ftype)
                     ;; Nested record: recurse.
                     (explode fsym ftype))
                    ((%crisp-float-type-p ftype)
                     (push fsym flat-inputs)
                     (push ftype flat-input-types)
                     (let ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg)))
                       (push grad-sym grad-out-params)
                       (push '(cell float :address-space :global) grad-out-types)
                       (push grad-sym grad-cell-syms)))
                    ((%crisp-integer-scalar-type-p ftype)
                     (push fsym flat-inputs)
                     (push ftype flat-input-types)
                     (let* ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg))
                            (float-elem (%integer-scalar-to-float-scalar ftype)))
                       (push grad-sym grad-out-params)
                       (push (list 'cell float-elem :address-space :global) grad-out-types)
                       (push grad-sym grad-cell-syms)))
                    (t
                     ;; Other (non-diff'able) leaf: pass through as flat.
                     (push fsym flat-inputs)
                     (push ftype flat-input-types))))
                ;; After children: push THIS record's reassembly.  Inner-record
                ;; reassemblies have already been pushed by recursive `explode`
                ;; calls; we push outer LAST so (nreverse) yields inner-first
                ;; / outer-last — exactly what the let-binding chain needs.
                (push (list p (cons make-sym
                                    (loop for (fname ftype fsym) in field-info-list
                                          append (list (intern (symbol-name fname) :keyword)
                                                       fsym))))
                      reassembly-bindings)))
             ((%crisp-struct-type-p t-spec)
              ;; Struct kernel input: keep as struct value, pair with a single
              ;; shadow-grad-cell.  Field-adj synth syms are allocated for
              ;; the backward walk's accessor rule to accumulate into.
              ;; Shadow writeout is emitted later by the postprocessor.
              (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                     (shadow-type (%shadow-type-name-for base-type))
                     (shadow-grad-sym (intern (format nil "~A_GRAD" (symbol-name p)) pkg))
                     (field-adj-alist
                      (%build-struct-field-adj-alist p t-spec pkg)))
                (push p flat-inputs)
                (push t-spec flat-input-types)
                (push shadow-grad-sym grad-out-params)
                (push (list 'cell shadow-type :address-space :global) grad-out-types)
                (push (list p shadow-grad-sym shadow-type field-adj-alist)
                      struct-shadow-info)))
             (t
              (push p flat-inputs)
              (push t-spec flat-input-types)))))
      (loop for p in inputs
            for t-spec in input-types
            do (explode p t-spec)))

    ;; For nested records, %compute-backward-kernel-params builds
    ;; record-exploded-syms via (mapcar #'cdr (gethash orig record-subs-ht))
    ;; — which only sees one level deep.  Without intervention, the leaf
    ;; syms (e.g. vr_top-left_x) wouldn't appear in record-exploded-syms,
    ;; and non-rec-scalar-in-grad-params would generate DUPLICATE grad
    ;; cells for them (we already produced their grad cells via the
    ;; recursive explosion).
    ;;
    ;; Fix: post-process each ORIGINAL input's record-subs-ht entry to
    ;; also include `(:%nested-leaf% . leaf-sym)` sentinels for all leaf
    ;; descendants.  The substitution machinery uses field-name keyed
    ;; lookup (assoc :test string-equal), and ":%nested-leaf%" doesn't
    ;; match any real field accessor, so these sentinels are invisible
    ;; to substitution but visible to the (mapcar #'cdr ...) consumer.
    (labels ((collect-leaves (sym)
               (let ((children (gethash sym record-subs-ht))
                     (acc '()))
                 (dolist (entry children)
                   (let ((child-sym (cdr entry)))
                     (cond
                       ((gethash child-sym record-subs-ht)
                        (setf acc (append acc (collect-leaves child-sym))))
                       (t (push child-sym acc)))))
                 acc)))
      (dolist (orig inputs)
        (when (gethash orig record-subs-ht)
          (let ((leaves (collect-leaves orig)))
            (let* ((direct-syms (mapcar #'cdr (gethash orig record-subs-ht)))
                   (deep-leaves (remove-if (lambda (s) (member s direct-syms :test #'eq))
                                            leaves)))
              (setf (gethash orig record-subs-ht)
                    (append (gethash orig record-subs-ht)
                            (mapcar (lambda (s) (cons :%nested-leaf% s))
                                    deep-leaves))))))))

    (values (nreverse flat-inputs)
            (nreverse flat-input-types)
            (nreverse reassembly-bindings)
            (nreverse grad-out-params)
            (nreverse grad-out-types)
            record-subs-ht
            record-type-ht
            (nreverse grad-cell-syms)
            (nreverse struct-shadow-info))))






(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk."
  (let ((name (symbol-name fn-sym)))
    (cl:flet ((prefix-or-mangled-p (prefix)
                (let ((plen (length prefix)))
                  (or (string= name prefix)
                      (and (> (length name) plen)
                           (string= (subseq name 0 plen) prefix)
                           (cl:char= (cl:char name plen) #\_))))))
      (or
       (find #\% name)
       (string= name "AS")
       (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
       (loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
                when (and (>= (length name) (+ 3 (length suffix)))
                          (string= (subseq name 0 3) "TO-")
                          (string= (subseq name (- (length name) (length suffix))) suffix))
                return t)
       (loop for prefix in '("NUM-ROWS" "NUM-COLS" "GET-LAYOUT" "BYTES~"
                             "LENGTH~" "EXTENTS~" "STRIDES~" "PARENT~"
                             "CONTIGUOUS-TERM~" "ELEMENT-TYPE~" "ADDRESS-SPACE~"
                             "ALIGN~" "NUM-DIMS~" "OFFSET~"
                             "MAKE-MATRIX" "MAKE-VECTOR" "MAKE-CELL" "MAKE-TENSOR"
                             ;; 111 Phase 1c: scratch constructors are gradient-inert.
                             "MAKE-SCRATCH-CELL" "MAKE-SCRATCH-VECTOR"
                             "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR"
                             "TRANSPOSE" "TRANSPOSE!" "ROW" "COL" "SLICE"
                             "GET-GLOBAL-ID" "GET-LOCAL-ID" "GET-WORKGROUP-ID"
                             "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                             "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET"
                             "GET-GLOBAL-ID-ABS" "GET-WORK-DIM"
                             "GET-LOCAL-LINEAR-ID" "GET-LOCAL-LINEAR-SIZE"
                             "GET-GLOBAL-LINEAR-ID" "GET-GLOBAL-LINEAR-SIZE"
                             "GET-TOTAL-THREADS" "GET-TOTAL-GROUPS"
                             "LOCAL-BARRIER" "MEM-FENCE")
             when (prefix-or-mangled-p prefix) return t)))))

(defun %collect-record-param-info (env pkg)
  "Record/struct params + their field info, in declaration order."
  (loop for pd in env
        for resolved = (%resolve-to-base-type-for-structs-or-records (parameter-def-type pd))
        when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                  (not (%crisp-handle-param-type-p (parameter-def-type pd)))
                  (or (%crisp-record-type-p resolved)
                      (%crisp-struct-type-p resolved)))
        collect
        (let* ((rsym (parameter-def-name pd))
               (fields (%get-record-runtime-fields resolved)))
          (list rsym resolved
                (loop for field-info in fields
                      for field-name = (first field-info)
                      collect (cons field-name
                                    (intern (format nil "~a_~a_ADJ"
                                                    (symbol-name rsym)
                                                    (symbol-name field-name))
                                            pkg)))))))

(defun %collect-all-diff-param-syms-for-return (env record-param-info)
  "Full ordered list of 'differentiable param syms' used for emitting the multi-value return."
  (let ((result nil))
    (loop for pd in env
          do (let ((sym (parameter-def-name pd)))
               (when (not (string-equal (symbol-name sym) "&OUT"))
                 (let ((rec-entry (assoc sym record-param-info :test #'eq)))
                   (cond
                     (rec-entry
                      (setf result (append result (mapcar #'cdr (third rec-entry)))))
                     ((%crisp-float-type-p (parameter-def-type pd))
                      (setf result (append result (list sym))))
                     ((> (%count-differentiable-contributions (parameter-def-type pd)) 0)
                      (setf result (append result (list sym)))))))))
    result))

(defun %build-record-param-field-adjs-ht (record-param-info)
  "Build the hash table record-param-field-adjs-ht."
  (when record-param-info
    (let ((ht (make-hash-table :test 'eq)))
      (dolist (info record-param-info)
        (let ((field-alist
               (loop for (fname . fadj) in (third info)
                     collect (cons (symbol-name fname) fadj))))
          (setf (gethash (first info) ht) field-alist)))
      ht)))

(defun %collect-tensor-param-info (env pkg)
  "Handle params (tensors + cells) + their grad-out info, in declaration order."
  (loop for pd in env
        for ptype = (parameter-def-type pd)
        when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                  (%crisp-handle-param-type-p ptype))
        collect
        (let* ((psym (parameter-def-name pd))
               (grad-sym (intern (format nil "~A_GRAD" (symbol-name psym)) pkg))
               (grad-type (cond
                            ((%crisp-integer-tensor-type-p ptype)
                             (%integer-tensor-elem-to-float ptype))
                            ((%crisp-tensor-param-type-p ptype)
                             (%ensure-tensor-read-write ptype))
                            (t ptype))))
          (list psym ptype grad-sym grad-type))))

(defun %register-hof-differentiable-function (name env float-param-syms fn-param-entries n-return body-forms)
  "Register the HOF details for autodiff compilation."
  (let* ((fn-param-idx (car (car fn-param-entries)))
         (fn-param-sym (parameter-def-name (cdr (car fn-param-entries))))
         (clean-body  (loop for f in body-forms
                            unless (and (atom f) (not (symbolp f)))
                            collect f)))
    (log:info "AUTODIFF: ~a is HOF — storing for inline backward" name)
    (setf (gethash name *differentiable-hof-store*)
          (list :param-syms       (loop for pd in env collect (parameter-def-name pd))
                :fn-param-idx     fn-param-idx
                :fn-param-sym     fn-param-sym
                :float-param-syms float-param-syms
                :body-forms       clean-body))
    (setf (gethash name *differentiable-functions*)
          (list :hof t
                :n-float-params (length float-param-syms)
                :n-return n-return))
    nil))

(defun %generate-backward-companion-ast-body (name params env declarations body-forms pkg n-float-params n-return
                                               return-types-non-void record-param-info record-param-field-adjs-ht
                                               all-diff-param-syms-for-return)
  "Generate backward companion def-function AST body."
  (declare (ignore declarations))
  (let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
         (t-grad-syms (loop for i from 0 below n-return
                            collect (intern (format nil "T_GRAD~A" i) pkg)))
         (orig-param-types (mapcar #'parameter-def-type env))
         (t-grad-types (mapcar (lambda (t-spec) (%promote-to-float-adjoint t-spec))
                               return-types-non-void))
         (tensor-param-info (%collect-tensor-param-info env pkg))
         (tensor-grad-out-syms (mapcar #'third tensor-param-info))
         (tensor-grad-out-types (mapcar #'fourth tensor-param-info))
         (out-marker (intern "&OUT" :crisp-language))
         (bkwd-params (append params t-grad-syms
                              (when tensor-param-info (cons out-marker tensor-grad-out-syms))))
         (bkwd-fn-spec
          `(function (,@orig-param-types ,@t-grad-types
                      ,@(when tensor-param-info (cons out-marker tensor-grad-out-types))
                      => ,@(make-list n-float-params :initial-element 'float)))))

    (setf (gethash name *differentiable-functions*)
          (list :bkwd-name bkwd-name
                :n-float-params n-float-params
                :n-return n-return
                :tensor-param-indices
                (loop for pd in env
                      for i from 0
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-handle-param-type-p (parameter-def-type pd)))
                      collect i)))

    (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-fp=~a n-ret=~a n-tensor=~a)"
              bkwd-name name n-float-params n-return (length tensor-param-info))

    (handler-case
      (let* ((anf-body   (mapcar #'anf-transform body-forms))
             (raw-flat   (flatten-anf-body anf-body))
             (flat-anf
              (let ((last-f (car (last raw-flat))))
                (if (or (symbolp last-f)
                        (and (consp last-f) (eq (first last-f) 'return)))
                    raw-flat
                    (let ((ret-sym (intern "%RET-0" pkg)))
                      (append (butlast raw-flat)
                              (list (list ret-sym last-f)
                                    ret-sym))))))
             (return-vars (%extract-return-vars flat-anf))
             (tensor-inputs-ht
              (when tensor-param-info
                (let ((ht (make-hash-table :test 'eq)))
                  (dolist (entry tensor-param-info)
                    (setf (gethash (first entry) ht) (second entry)))
                  ht)))
             (bkwd-body
              (let ((*record-param-field-adjs* record-param-field-adjs-ht))
                (%check-fn-body-for-mutations body-forms
                                              (mapcar #'parameter-def-name env)
                                              name)
                (%generate-backward-function-walk
                 flat-anf all-diff-param-syms-for-return t-grad-syms return-vars
                 tensor-inputs-ht))))
        `(def-function ,bkwd-name ,bkwd-params
           (declare #'(,@(second bkwd-fn-spec)))
           ,bkwd-body))

      (error (e)
        (log:info "AUTODIFF: ~a — cannot generate _GRAD: ~a. Unregistering; will error if called from a differentiable kernel." name e)
        (remhash name *differentiable-functions*)
        nil))))

(defun %generate-backward-function-ast (name params declarations body-forms)
  "Generates the backward companion (def-function NAME_GRAD ...) for a
differentiable user function."
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  (when (%trivial-accessor-body-p body-forms)
    (log:info "AUTODIFF: ~a is a trivial field-extraction accessor — skipping _GRAD generation." name)
    (return-from %generate-backward-function-ast nil))
  (let* ((pkg (symbol-package name)))
    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)
      (let* ((float-param-entries
              (loop for pd in env
                    when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                              (%crisp-float-type-p (parameter-def-type pd)))
                    collect pd))
             (float-param-syms (mapcar #'parameter-def-name float-param-entries))
             (record-param-info (%collect-record-param-info env pkg))
             (all-diff-param-syms-for-return (%collect-all-diff-param-syms-for-return env record-param-info))
             (record-param-field-adjs-ht (%build-record-param-field-adjs-ht record-param-info))
             (n-float-params
              (loop for pd in env
                    when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                    sum (%count-differentiable-contributions (parameter-def-type pd))))
             (return-types-non-void (remove nil return-types))
             (n-return (length return-types-non-void))
             (fn-param-entries
              (loop for pd in env for i from 0
                    when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                              (%crisp-function-type-p (parameter-def-type pd)))
                    collect (cons i pd)))
             (is-hof (consp fn-param-entries)))

        (when (and (zerop n-float-params)
                   (not (%has-tensor-diff-param-p env)))
          (log:info "AUTODIFF: ~a has no differentiable params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        (if is-hof
            (%register-hof-differentiable-function name env float-param-syms fn-param-entries n-return body-forms)
            (%generate-backward-companion-ast-body name params env declarations body-forms pkg n-float-params n-return
                                                   return-types-non-void record-param-info record-param-field-adjs-ht all-diff-param-syms-for-return))))))




(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars
                                         &optional tensor-inputs-ht)
  "Generates the backward-pass body for a def-function.
FLAT-ANF         : flattened ANF of the forward function body.
FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).
T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).
RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).

101 extension: TENSOR-INPUTS-HT (optional hash-table mapping each tensor-sub-
fn-param symbol to its tensor type) is threaded into %handle-single-value-
backward so tensor reads inside the body emit atomic-add into the corresponding
&out grad-tensor.

Returns a (let (...) ...) form suitable as the body of the _GRAD companion function."
  (let ((backward-forms nil)
        (adjoint-map (make-hash-table :test 'equal))
        (return-var-seeds (make-hash-table :test 'eq)))

    (loop for rv in return-vars
          for tg in t-grad-syms do
            (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                      (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
             (let ((v    (car form))
                   (expr (cadr form)))
               (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                              :error-on-unknown t
                                              :tensor-inputs-ht tensor-inputs-ht)))
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
             (let* ((result-vars (butlast form))
                    (expr        (car (last form))))
               (when (and (consp expr)
                          (symbolp (car expr))
                          (gethash (car expr) *differentiable-functions*))
                 (let* ((fn      (car expr))
                        (args    (cdr expr))
                        (info    (gethash fn *differentiable-functions*))
                        (bkwd-fn (getf info :bkwd-name))
                        (n-fp    (getf info :n-float-params))
                        (n-ret   (getf info :n-return))
                        (pkg     (symbol-package fn)))
                   (declare (ignore n-ret))
                   (%emit-sub-fn-backward fn args bkwd-fn (mapcar #'local-adj result-vars) n-fp pkg #'emit #'local-adj "MV")))))
            (t nil))))

      (emit `(return ,@(mapcar #'local-adj float-param-syms)))

      (let* ((forward-bindings
              (loop for form in flat-anf
                    when (and (consp form)
                              (= (length form) 2)
                              (symbolp (car form))
                              (not (gethash (car form) return-var-seeds)))
                    collect form))
             (adjoint-bindings
              (loop for v being the hash-keys of adjoint-map
                    using (hash-value adv)
                    collect (let ((seed (gethash v return-var-seeds)))
                              `(,adv ,(if seed seed 0.0)))))
             (all-bindings (append forward-bindings adjoint-bindings)))
        `(let ,all-bindings
           ,@(nreverse backward-forms))))))




(defun %check-fn-body-for-mutations (body-forms param-names fn-name)
  "Walks BODY-FORMS looking for (set! (~ p) ...) where p is in PARAM-NAMES.
Signals a compiler error if any mutation is detected, naming FN-NAME."
  (labels ((walk (form)
             (when (consp form)
               (when (and (eq (first form) 'set!)
                          (consp (second form))
                          (eq (first (second form)) '~)
                          (symbolp (second (second form)))
                          (member (second (second form)) param-names :test #'string-equal))
                 (error "Cannot differentiate function ~A: it mutates parameter ~A via cell write (set! (~~ ~A) ...). This function is not valid in a differentiable kernel."
                        fn-name
                        (second (second form))
                        (second (second form))))
               (mapc #'walk (rest form)))))
    (mapc #'walk body-forms)))




(defun %crisp-function-type-p (type-spec)
  "Returns T if TYPE-SPEC is a parsed :function-type or :function-literal specifier."
  (and (consp type-spec)
       (or (eq (first type-spec) :function-type)
           (eq (first type-spec) :function-literal))))


(defun %subst-form (form subst-alist)
  "Recursively substitute atoms in FORM according to SUBST-ALIST (list of (sym . replacement))."
  (cond
    ((null form) nil)
    ((atom form)
     (let ((pair (assoc form subst-alist)))
       (if pair (cdr pair) form)))
    (t (cons (%subst-form (car form) subst-alist)
                (%subst-form (cdr form) subst-alist)))))


(defun %remove-funcall (form fn-param-sym concrete-fn-sym)
  "Recursively replace (funcall FN-PARAM-SYM ...) or (funcall (function X) ...)
with (CONCRETE-FN-SYM ...) in FORM."
  (cond
    ((atom form) form)
    ((and (eq (car form) 'funcall) (consp (cdr form)))
     (let* ((fn-arg    (cadr form))
               (call-args (mapcar (lambda (a) (%remove-funcall a fn-param-sym concrete-fn-sym))
                                  (cddr form)))
               (resolved  (cond
                             ((eq fn-arg fn-param-sym) concrete-fn-sym)
                             ((and (consp fn-arg) (eq (car fn-arg) 'function)) (cadr fn-arg))
                             (t nil))))
       (if resolved
           `(,resolved ,@call-args)
           `(funcall ,fn-arg ,@call-args))))
    (t (mapcar (lambda (x) (%remove-funcall x fn-param-sym concrete-fn-sym)) form))))



;;; Helper: is this function name already a _GRAD companion?
;;; Used to prevent recursive generation in the def-function macro patch.
;;; src/autodiff.lisp

(defun %fn-name-is-grad-p (name)
  "Returns T if NAME ends with the _GRAD suffix, indicating it is already
a backward companion and should not receive its own companion."
  (let ((s (symbol-name name)))
    (and (> (length s) 5)
            (string= (subseq s (- (length s) 5)) "_GRAD"))))


;;; Helper: extract return variable(s) from the last element of a flat ANF body.
;;; The last element is either a plain symbol (implicit return) or
;;; a (return v0 v1 ...) form.

(defun %extract-return-vars (flat-anf)
  "Returns the list of return-value symbols from FLAT-ANF.
Handles both implicit last-expression and explicit (return v0 v1 ...) forms."
  (let ((last-form (car (last flat-anf))))
    (cond
      ((symbolp last-form)
       (list last-form))
      ((and (consp last-form) (eq (first last-form) 'return))
       (rest last-form))
      (t
       (error "Cannot extract return vars from flat-ANF last form: ~s" last-form)))))



(defun %crisp-integer-tensor-type-p (type-spec)
  "Returns T if TYPE-SPEC resolves to a tensor whose element type is an integer
category (:signed-int or :unsigned-int). Mirrors %crisp-float-tensor-type-p."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (string-equal (symbol-name (first canonical)) "TENSOR")
         (let* ((elem (second canonical))
                   (info (gethash elem *crisp-types*)))
           (and info (member (crisp-type-category info)
                             '(:signed-int :unsigned-int)))))))





(defun %integer-tensor-elem-to-float (type-spec)
  "Replaces the element type of an integer tensor with its float analog:
   64-bit integers (long, ulong) → double; all others → float.
   Returns TYPE-SPEC unchanged if it is not an integer tensor."
  (if (%crisp-integer-tensor-type-p type-spec)
      (let* ((canonical (canonicalize-type-specifier type-spec))
             (elem      (second canonical))
             (info      (gethash elem *crisp-types*))
             (float-elem (if (and info (>= (crisp-type-size info) 64))
                             'double
                             'float)))
        ;; 6-tuple: (tensor elem N addr aln ct)
        (list (nth 0 canonical) float-elem (nth 2 canonical)
              (nth 3 canonical) (nth 4 canonical) (%get-tensor-ct canonical)))
      type-spec))

;;; ----------------------------------------------------------
;;; 101 endeavor: integer-input AD support — type promotion helpers
;;; ----------------------------------------------------------

(defun %crisp-integer-scalar-type-p (type-spec)
  "Returns T if TYPE-SPEC (possibly a type alias) resolves to an integer
scalar type (signed or unsigned).  Mirrors %crisp-float-type-p but for ints."
  (let* ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec))
         (info (and (symbolp resolved) (gethash resolved *crisp-types*))))
    (and info (member (crisp-type-category info) '(:signed-int :unsigned-int)))))

(defun %integer-scalar-to-float-scalar (type-spec)
  "Returns the float-analog scalar type for an integer scalar:
   64-bit (long, ulong) → double; smaller ints → float.  Type aliases are
   resolved.  Returns TYPE-SPEC unchanged if it is not an integer scalar."
  (if (%crisp-integer-scalar-type-p type-spec)
      (let* ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec))
             (info (gethash resolved *crisp-types*)))
        (if (and info (>= (crisp-type-size info) 64))
            'double
            'float))
      type-spec))

(defun %crisp-integer-cell-type-p (type-spec)
  "Returns T if TYPE-SPEC is a cell whose element type is an integer scalar."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (and (consp canonical)
         (symbolp (first canonical))
         (string-equal (symbol-name (first canonical)) "CELL")
         (%crisp-integer-scalar-type-p (second canonical)))))

(defun %integer-cell-elem-to-float (type-spec)
  "Replaces the element type of an integer cell with its float analog.
   Returns the keyword form (cell float-elem :address-space addr) — length 4 —
   to satisfy downstream consumers like marshall-cell that reject the canonical
   3-tuple positional form.  Returns TYPE-SPEC unchanged if it is not an
   integer cell."
  (if (%crisp-integer-cell-type-p type-spec)
      (let* ((canonical (canonicalize-type-specifier type-spec))
             (elem      (second canonical))
             (addr      (nth 2 canonical))
             (float-elem (%integer-scalar-to-float-scalar elem)))
        (list (nth 0 canonical) float-elem :address-space addr))
      type-spec))

(defun %promote-to-float-adjoint (type-spec)
  "Generalised float-adjoint type promotion for AD output gradient slots.
   - integer scalar      → float / double scalar
   - integer tensor      → float / double tensor (element-type promoted)
   - integer cell        → cell of float / double
   - everything else     → unchanged (already float, or non-numeric)
   Used to produce caller-supplied _GRAD seed types and input _GRAD output
   types that mirror the input shape with float adjoint values."
  (cond
    ((%crisp-integer-tensor-type-p type-spec) (%integer-tensor-elem-to-float type-spec))
    ((%crisp-integer-cell-type-p   type-spec) (%integer-cell-elem-to-float   type-spec))
    ((%crisp-integer-scalar-type-p type-spec) (%integer-scalar-to-float-scalar type-spec))
    (t type-spec)))


;; is this actually used?
(defun %autodiff-grad-cell-type ()
  "Returns the canonical cell type used for gradient output parameters."
  '(cell float :address-space :global))


;;; ===================================================================
;;; 101-revisit-autodiff: dynamic vars
;;; ===================================================================

(defvar *record-param-field-adjs* nil
  "Hash table: record-sym -> alist of (FIELD-NAME-STR . FIELD-ADJ-SYM)
   in declaration order.  Bound during backward walk for sub-functions
   with record params, and for kernels with record-valued ANF temps
   (constructed via make-RECORD).  Otherwise NIL.

   Consumers:
     - The accessor rule in %handle-single-value-backward routes adjoint
       flow from (FIELD~ p) to the per-field synth adj.
     - The %construct-struct case flows per-field adjs to constructor args.
     - %emit-sub-fn-backward distributes deltas per-field when an arg is
       a record-valued symbol.")

(defvar *struct-kernel-param-shadows* nil
  "Hash table: struct-kernel-param-sym -> (cons SHADOW-GRAD-SYM FIELD-ADJ-ALIST).
   FIELD-ADJ-ALIST is an alist of (FIELD-NAME-STR . FIELD-ADJ-SYM) in
   declaration order.  Bound by %generate-backward-kernel-ast around
   the backward walk when struct kernel params are present.  Used by:
     - The accessor rule in %handle-single-value-backward.
     - The shadow-write postprocessor.")


;;; ===================================================================
;;; 101-revisit-autodiff: pre-registration helpers
;;; ===================================================================
;;;
;;; Pre-registration runs BEFORE def-record / def-struct macros expand and
;;; register types in *crisp-types*.  To know a record's runtime-field count
;;; at pre-reg time, we scan the forms list ourselves and build an alist.
;;; Post-walk-code-forms paths can fall back to *crisp-types*.

(defun %scan-forms-for-record-info (forms)
  "Walks FORMS (recursing through progn / with-template-type) and returns
   an alist mapping (symbol-name TYPE-NAME) -> count of non-:c-t,
   non-brand runtime fields. Used during pre-registration when *crisp-types*
   isn't yet populated.

   Includes BOTH def-record AND def-struct (records and structs at the
   sub-function AD level both contribute their field count toward the
   differentiability gate).  Also includes derived-from-{record,struct}
   types: when (def-derived-type NEW BASE ...) is encountered and BASE is
   already in the alist, NEW is added with the same field count.

   The name `record-info` is historical; the alist now tracks structs too."
  (let ((info nil))
    (labels ((scan (forms)
               (dolist (f forms)
                 (cond
                   ((and (consp f)
                         (or (eq (car f) 'def-record)
                             (eq (car f) 'def-struct)))
                    (let* ((name (second f))
                           (members (cddr f))
                           (rt-count
                            (count-if
                             (lambda (m)
                               (and (consp m)
                                    (not (eq (car m) 'brand))
                                    (not (and (consp m) (eq (third m) :c-t)))))
                             members)))
                      (push (cons (symbol-name name) rt-count) info)))
                   ((and (consp f) (eq (car f) 'def-derived-type)
                         (>= (length f) 3)
                         (symbolp (second f))
                         (symbolp (third f)))
                    (let* ((new-name (second f))
                           (base-name (third f))
                           (base-entry (assoc (symbol-name base-name) info
                                              :test #'string-equal)))
                      (when base-entry
                        (push (cons (symbol-name new-name) (cdr base-entry)) info))))
                   ((and (consp f) (eq (car f) 'progn))
                    (scan (rest f)))
                   ((and (consp f) (eq (car f) 'with-template-type))
                    (scan (cddr f)))))))
      (scan forms))
    info))

(defun %resolve-to-base-type-for-records (pd-type)
  "If PD-TYPE names a derived type whose base is a record, returns the
   base record type symbol. Otherwise returns PD-TYPE unchanged.

   Records are SROA'd at every function boundary, and derived-type wrappers
   preserve that property. This helper lets the sub-function gate widening
   accept derived-from-record types (e.g. `coordinate` derived from `point`)."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type)))
    (or (cl:ignore-errors
         (cl:let ((computed (compute-base-type pd-type)))
           (cl:when (and (symbolp computed) (%crisp-record-type-p computed))
             computed)))
        base)))

(defun %resolve-to-base-type-for-structs-or-records (pd-type)
  "If PD-TYPE names a derived type whose base is a struct OR a record,
   returns the base type symbol.  Otherwise returns PD-TYPE unchanged.
   Used by sub-function gate widening to accept derived-from-struct types
   in addition to derived-from-record types."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type)))
    (or (cl:ignore-errors
         (cl:let ((computed (compute-base-type pd-type)))
           (cl:when (and (symbolp computed)
                         (or (%crisp-record-type-p computed)
                             (%crisp-struct-type-p computed)))
             computed)))
        base)))

(defun %count-differentiable-contributions (pd-type &optional record-info)
  "Returns the number of SCALAR-DELTA contributions this parameter type
   makes at the SUB-FUNCTION level (def-function).  Used to size the
   multi-value-return arity at the sub-fn _GRAD boundary.

   - Records / derived-from-records  -> runtime-field count (per-field deltas).
   - Structs  / derived-from-structs -> runtime-field count (same convention).
   - Float scalars                   -> 1.
   - Tensors, cells, integer scalars -> 0.  These contribute zero scalar
     deltas; tensors flow grad via &out grad-tensor params instead
     (see %has-tensor-diff-param-p and the tensor-sub-fn pipeline).

   RECORD-INFO (optional alist of (NAME-STR . FIELD-COUNT)) bridges the
   pre-registration ordering issue where *crisp-types* isn't yet
   populated. When supplied, it takes priority over the runtime registry."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type))
         (name-str (and (symbolp base) (symbol-name base)))
         (info-hit (and record-info name-str
                        (assoc name-str record-info :test #'string-equal)))
         (resolved (%resolve-to-base-type-for-structs-or-records pd-type)))
    (cond
      (info-hit (cdr info-hit))
      ;; Handles (tensors AND cells) flow grad via &out, not via scalar
      ;; deltas.  0 scalar deltas.
      ((%crisp-handle-param-type-p pd-type) 0)
      ((or (%crisp-record-type-p resolved)
           (%crisp-struct-type-p resolved))
       (length (or (%get-record-runtime-fields resolved) '())))
      ((%crisp-float-type-p pd-type) 1)
      (t 0))))

(defun %crisp-tensor-param-type-p (pd-type)
  "Returns T if PD-TYPE is a tensor (float-element or integer-element)
   at the sub-function level.  Used to decide whether a sub-fn param
   contributes a tensor grad-out (vs a scalar delta).

   Handles three forms:
   - List form: (tensor float 1 ...) — caught by the existing helpers.
   - Mangled-template-name symbol: TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST —
     produced by Crisp's template instantiation.  Detected by name prefix.
   - Plain symbol naming a registered tensor type."
  (or (%crisp-float-tensor-type-p pd-type)
      (%crisp-integer-tensor-type-p pd-type)
      (and (symbolp pd-type)
           (let ((name (symbol-name pd-type)))
             (and (>= (length name) 7)
                  (string-equal "TENSOR_" (subseq name 0 7)))))))

(defun %crisp-cell-param-type-p (pd-type)
  "Returns T if PD-TYPE is a cell of a SCALAR element type (float or
   integer) at the sub-function level.  Cells flow grad via &out
   grad-cell, same pattern as tensors.

   Cells of structs/records are NOT accepted here — their grad-cell
   would need to be a cell of the corresponding shadow type, and the
   chain rule for `(set! (field~ (~ c)) ...)` is structurally different
   (deferred).

   Recognizes three forms (mirrors %crisp-tensor-param-type-p):
   - List form: (cell float :address-space :global ...).
   - Mangled template name like CELL_FLOAT_GLOBAL — produced by Crisp's
     template instantiation.  Detected by name prefix + scalar element.
   - Plain symbol naming a registered cell type."
  (let ((canonical (canonicalize-type-specifier pd-type)))
    (cond
      ((and (consp canonical) (symbolp (first canonical))
            (string-equal (symbol-name (first canonical)) "CELL"))
       (let ((elem (second canonical)))
         (or (%crisp-float-type-p elem)
             (%crisp-integer-scalar-type-p elem))))
      ((and (symbolp pd-type)
            (let ((name (symbol-name pd-type)))
              (and (>= (length name) 5)
                   (string-equal "CELL_" (subseq name 0 5)))))
       (let ((name (symbol-name pd-type)))
         (let* ((after-cell (subseq name 5))
                (underscore (position #\_ after-cell))
                (elem-str (if underscore
                              (subseq after-cell 0 underscore)
                              after-cell)))
           (member elem-str '("FLOAT" "DOUBLE" "HALF" "BFLOAT16"
                              "INT" "LONG" "SHORT" "CHAR"
                              "UINT" "ULONG" "USHORT" "UCHAR")
                   :test #'string-equal))))
      (t nil))))

(defun %crisp-handle-param-type-p (pd-type)
  "Returns T for any sub-fn param type that flows grad via &out grad-handle:
   tensors AND cells.  Both go through the same convention — paired with
   an &out grad-handle of matching shape, body atomic-adds into it."
  (or (%crisp-tensor-param-type-p pd-type)
      (%crisp-cell-param-type-p pd-type)))

(defun %has-tensor-diff-param-p (env)
  "Returns T if ENV contains at least one non-&OUT parameter that flows
   grad via a paired &out grad-handle (tensor OR cell).  Used by the
   sub-function pre-reg + _GRAD generator gates: a sub-fn with such
   params is differentiable even when its scalar-delta count is zero.

   Name is historical (originally tensor-only); now covers cells too."
  (some (lambda (pd)
          (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
               (%crisp-handle-param-type-p (parameter-def-type pd))))
        env))

(defun %trivial-accessor-body-p (body-forms)
  "Returns T if BODY-FORMS is a single (return (%extract-struct-member obj idx))
   — i.e. a trivial field-extraction accessor.  Used to detect auto-generated
   accessors that def-derived-type emits without a `(crisp-system-generated)`
   declaration (def-record's accessors ARE marked, but def-derived-type's are
   not).  These accessors don't need their own _GRAD: the kernel-side accessor
   rule handles them inline."
  (let ((real-forms (remove-if (lambda (f)
                                 (and (consp f) (member (car f) '(declare))))
                               body-forms)))
    (and (= (length real-forms) 1)
         (let ((form (first real-forms)))
           (and (consp form) (eq (car form) 'return)
                (consp (second form))
                (symbolp (caadr form))
                (string-equal (symbol-name (caadr form)) "%EXTRACT-STRUCT-MEMBER"))))))


;;; ===================================================================
;;; 101: Shadow Struct generation (Part 1 of 3)
;;; ===================================================================
;;;
;;; Per the shadow-struct-plan: every (def-struct NAME ...) at top level
;;; gets a paired (def-struct NAME_ADJ ...) injected before compile-module
;;; processes the forms.  Shadow fields have adjoint-promoted types:
;;;
;;;   - float scalar          -> same
;;;   - integer scalar        -> float (or double for long/ulong)
;;;   - nested struct         -> <INNER>_ADJ
;;;   - branded primitive     -> base type, then promote
;;;
;;; Brand declarations on the forward are NOT copied to the shadow
;;; (gradients of brands aren't meaningful).

(defun %adj-type-for-field (forward-type &optional struct-name-set)
  "Returns the adjoint type for a forward struct field's TYPE, per
   the 101 promotion rules.

   STRUCT-NAME-SET (optional hash table, symbol->T) covers struct types
   that will be defined by upcoming def-struct forms in the same
   compilation unit but haven't been registered in *crisp-types* yet.
   At shadow-injection time (before any macro expansion), this is the
   only way to know which symbols are struct types."
  (cond
    ((%crisp-float-type-p forward-type) forward-type)
    ((%crisp-integer-scalar-type-p forward-type)
     (%integer-scalar-to-float-scalar forward-type))
    ((and (symbolp forward-type)
          (is-brand-type-p forward-type))
     (let* ((brand (is-brand-type-p forward-type))
            (base  (brand-definition-base-type brand)))
       (cond
         ((%crisp-float-type-p base) base)
         ((%crisp-integer-scalar-type-p base)
          (%integer-scalar-to-float-scalar base))
         (t forward-type))))
    ((and (symbolp forward-type)
          (or (let ((info (gethash forward-type *crisp-types*)))
                (and info (eq (crisp-type-category info) :struct)))
              (and struct-name-set
                   (gethash forward-type struct-name-set))))
     (intern (format nil "~A_ADJ" (symbol-name forward-type))
             (symbol-package forward-type)))
    (t forward-type)))

(defun %generate-shadow-def-struct-form (def-struct-form &optional struct-name-set)
  "Given (def-struct NAME (f0 t0) (f1 t1) ... brand-decls...), returns
   the matching (def-struct NAME_ADJ (f0 adj_t0) (f1 adj_t1) ...) form.
   Brand declarations are dropped.  :c-t members are preserved (their
   value is a forward-time constant; not differentiable but harmless).
   STRUCT-NAME-SET enables recognizing nested struct field types whose
   def-struct forms appear elsewhere in the compilation unit."
  (let* ((name (second def-struct-form))
         (members (cddr def-struct-form))
         (shadow-name (intern (format nil "~A_ADJ" (symbol-name name))
                              (symbol-package name)))
         (shadow-members
          (loop for m in members
                unless (and (consp m) (eq (car m) 'brand))
                collect (cond
                          ((and (consp m) (>= (length m) 2))
                           (list* (first m)
                                  (%adj-type-for-field (second m) struct-name-set)
                                  (cddr m)))
                          (t m)))))
    `(def-struct ,shadow-name ,@shadow-members)))

(defun %collect-struct-names-from-forms (forms)
  "Walks FORMS at the top level and returns a hash table mapping each
   (def-struct NAME ...) NAME (and only structs, not records) to T.
   Used by shadow-injection to recognize struct field types when
   *crisp-types* isn't yet populated."
  (let ((set (make-hash-table :test 'eq)))
    (dolist (f forms)
      (when (and (consp f) (eq (car f) 'def-struct) (symbolp (second f)))
        (setf (gethash (second f) set) t)))
    set))

(defun %inject-shadow-struct-forms (forms)
  "Walks FORMS at the top level.  After each (def-struct NAME ...) that
   defines a NON-shadow struct, appends (def-struct NAME_ADJ ...).
   Already-shadow structs (name ends with _ADJ) are passed through.
   def-record forms are left untouched (records SROA, no shadow needed).
   Other forms unchanged.

   First pass collects all struct names so the shadow generator can
   recognize nested struct field types."
  (let ((struct-names (%collect-struct-names-from-forms forms))
        (result nil))
    (dolist (f forms)
      (push f result)
      (when (and (consp f)
                 (eq (car f) 'def-struct)
                 (symbolp (second f))
                 (let ((n (symbol-name (second f))))
                   (or (< (length n) 4)
                       (not (string-equal "_ADJ" (subseq n (- (length n) 4)))))))
        (push (%generate-shadow-def-struct-form f struct-names) result)))
    (nreverse result)))


;;; ===================================================================
;;; 101: Struct kernel-param AD machinery (Shadow Struct, part 2 of 3)
;;; ===================================================================
;;;
;;; - %crisp-struct-type-p: predicate for struct-category types (not records).
;;; - %register-shadow-anf-intermediates: pre-scans flat-anf for synthetic
;;;   temps bound to nested-struct accessors, so their own accessor calls
;;;   route deeper into the shadow.
;;; - %fix-struct-shadow-writes: postprocesses the backward-walk output to
;;;   replace the default scalar input-grad-write with the correct shadow-
;;;   struct constructor write.

(defun %crisp-struct-type-p (type-spec)
  "Returns T if TYPE-SPEC names a registered def-struct (category :struct).
   Distinct from %crisp-record-type-p (which checks category :record)."
  (let* ((base (if (consp type-spec) (first type-spec) type-spec))
         (info (and (symbolp base) (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :struct))))

(defun %shadow-type-name-for (struct-type-name)
  "Returns the shadow struct's type symbol for STRUCT-TYPE-NAME."
  (intern (format nil "~A_ADJ" (symbol-name struct-type-name))
          (symbol-package struct-type-name)))

(defun %make-shadow-constructor-name-for (struct-type-name)
  "Returns the MAKE-<TYPE>_ADJ constructor symbol for STRUCT-TYPE-NAME."
  (intern (format nil "MAKE-~A_ADJ" (symbol-name struct-type-name))
          (symbol-package struct-type-name)))

(defun %nested-field-info-p (field-info)
  "T if FIELD-INFO from a struct-shadow alist refers to a nested struct
   (an alist), as opposed to a scalar leaf (a symbol)."
  (and (listp field-info)
       field-info
       (consp (first field-info))
       (stringp (caar field-info))))

(defun %register-shadow-anf-intermediates (flat-anf shadow-ht)
  "Pre-scans FLAT-ANF for bindings of the shape (TEMP (FIELD~ SHADOW-TRACKED-SYM))
   where SHADOW-TRACKED-SYM is in SHADOW-HT and the field's info is a
   nested-struct alist.  Registers TEMP in SHADOW-HT (with the nested
   alist as TEMP's field-adj-alist) so subsequent accessor calls on TEMP
   can route deeper.  Mutates SHADOW-HT in place.

   Must run BEFORE the backward walk so the accessor case can consult
   the augmented map."
  (dolist (form flat-anf)
    (when (and (consp form)
               (= (length form) 2)
               (symbolp (car form))
               (consp (cadr form))
               (symbolp (caadr form))
               (let ((fname (symbol-name (caadr form))))
                 (and (> (length fname) 1)
                      (cl:char= (cl:char fname (1- (length fname))) #\~)))
               (= (length (cadr form)) 2)
               (symbolp (cadadr form))
               (gethash (cadadr form) shadow-ht))
      (let* ((temp (car form))
             (expr (cadr form))
             (accessor-name (symbol-name (car expr)))
             (field-name-str (subseq accessor-name 0 (1- (length accessor-name))))
             (parent-sym (cadr expr))
             (parent-entry (gethash parent-sym shadow-ht))
             (parent-field-alist (if (and (consp parent-entry) (symbolp (car parent-entry)))
                                     (cdr parent-entry)
                                     parent-entry))
             (field-entry (assoc field-name-str parent-field-alist :test #'string-equal))
             (field-info (cdr field-entry)))
        (when (%nested-field-info-p field-info)
          (setf (gethash temp shadow-ht) field-info))))))

(defun %build-struct-field-adj-alist (param-sym struct-type pkg)
  "Recursively builds a field-adj-alist for a struct kernel param of
   STRUCT-TYPE.  Each entry is (FIELD-NAME-STR . FIELD-INFO) where:

   - For scalar fields: FIELD-INFO is the per-field adj symbol
     (e.g. r_top-left_x_adj).
   - For nested struct fields: FIELD-INFO is itself an alist of the
     same shape, recursively descended.

   PARAM-SYM is the prefix used when generating leaf adj sym names
   (so leaves nested under r.top-left get names like r_top-left_x_adj)."
  (let ((fields (%get-record-runtime-fields struct-type)))
    (loop for (fname ftype) in fields
          for fname-str = (symbol-name fname)
          collect
          (cons fname-str
                (cond
                  ((%crisp-struct-type-p ftype)
                   (let ((nested-prefix
                          (intern (format nil "~A_~A"
                                          (symbol-name param-sym)
                                          (symbol-name fname))
                                  pkg)))
                     (%build-struct-field-adj-alist nested-prefix ftype pkg)))
                  (t
                   (intern (format nil "~A_~A_ADJ"
                                   (symbol-name param-sym)
                                   (symbol-name fname))
                           pkg)))))))
  

(defun %build-shadow-ctor-form (struct-type-name field-adj-alist pkg)
  "Builds a (MAKE-<S>_ADJ :field1 val1 :field2 val2 ...) form recursively.
   For scalar leaf fields, val is wrapped in (%volatile-read SYM) — see
   IGC SROA-aliasing workaround commentary above."
  (let ((ctor (%make-shadow-constructor-name-for struct-type-name)))
    (cons ctor
          (loop for (fname-str . field-info) in field-adj-alist
                append
                (list (intern fname-str :keyword)
                      (cond
                        ((%nested-field-info-p field-info)
                         (let* ((fields (%get-record-runtime-fields struct-type-name))
                                (fentry (find fname-str fields
                                              :key (lambda (f) (symbol-name (first f)))
                                              :test #'string-equal))
                                (inner-type (when fentry (second fentry))))
                           (if (and inner-type (%crisp-struct-type-p inner-type))
                               (%build-shadow-ctor-form inner-type field-info pkg)
                               0)))
                        (t (list '%volatile-read field-info))))))))

(defun %collect-all-leaf-adj-syms (field-adj-alist)
  "Collects all leaf adj syms (scalars at the bottom of a nested alist)
   recursively."
  (loop for (fname-str . field-info) in field-adj-alist
        append (if (%nested-field-info-p field-info)
                   (%collect-all-leaf-adj-syms field-info)
                   (list field-info))))

(defun %ensure-leaf-adj-bindings (form leaf-adj-syms)
  "If FORM is `(let (bindings) body...)`, augments the bindings list with
   `(sym 0.0)` for each sym in LEAF-ADJ-SYMS not already bound.  Used to
   ensure that leaf adj syms referenced ONLY by the shadow-write
   postprocessor (i.e. unused in the kernel body) have valid zero-init
   bindings."
  (cond
    ((and (consp form) (eq (first form) 'let))
     (let* ((existing-bindings (second form))
            (existing-syms (mapcar (lambda (b)
                                     (if (consp b) (first b) b))
                                   existing-bindings))
            (missing (remove-if (lambda (s)
                                  (member s existing-syms :test #'eq))
                                leaf-adj-syms))
            (additions (mapcar (lambda (s) (list s 0.0)) missing)))
       (if additions
           `(let ,(append existing-bindings additions)
              ,@(cddr form))
           form)))
    (t form)))

(defun %fix-struct-shadow-writes (form struct-shadow-info)
  "Postprocesses the kernel backward walk's output.  For each struct
   kernel input S in STRUCT-SHADOW-INFO, replaces the default scalar
   input-grad-write `(set! S_GRAD S_ADJ)` with the correct shadow-
   struct write `(set! (~ S_GRAD) (MAKE-<S>_ADJ ...))` — building
   the shadow constructor recursively for nested struct fields.

   STRUCT-SHADOW-INFO is the alist returned as the 9th value of
   %expand-record-kernel-inputs:
     ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)

   Other (set! ...) forms are passed through unchanged."
  (labels ((rewrite (f)
             (cond
               ((atom f) f)
               ((and (consp f) (eq (first f) 'set!) (= (length f) 3)
                     (symbolp (second f)))
                (let ((entry (find (second f) struct-shadow-info
                                   :key #'second :test #'eq)))
                  (if entry
                      (let* ((shadow-type (third entry))
                             (field-alist (fourth entry))
                             (forward-type
                              (intern (subseq (symbol-name shadow-type)
                                              0 (- (length (symbol-name shadow-type)) 4))
                                      (symbol-package shadow-type))))
                        `(set! (~ ,(second f))
                               ,(%build-shadow-ctor-form forward-type field-alist
                                                         (symbol-package (second f)))))
                      f)))
               ((consp f) (mapcar #'rewrite f))
               (t f))))
    (rewrite form)))