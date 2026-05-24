;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/autodiff.lisp
;;
;; Bug 032 fix part 3: extend the (~ ...) clause of %handle-single-value-backward
;; to handle local-scratch tile reads with indices.  Previously the (t ...)
;; fallthrough emitted a scalar `tile_ADJ += v_adj` AND called (local-adj tile)
;; — the latter added tile to adjoint-map, which makes the wrapping let-bindings
;; allocate `(tile_ADJ 0.0)` and shadow the scratch-tensor binding created by
;; scratch-adj-bindings.  Result: `EXTENTS~ tile_ADJ` later sees a float and the
;; backward kernel fails to compile.  This is verbatim from src/autodiff.lisp
;; with one new (cond ...) branch added in the `~` rule.

;; src/autodiff.lisp
;;
;; Bug 032 fix part 4: %collect-locally-bound-vars walks LET / DOTIMES / IF /
;; PROGN but did NOT walk into WHEN / UNLESS bodies.  Result: bindings made
;; inside a WHEN (which is what workgroup-stride bodies turn into after ANF
;; lifts the per-iteration set! RHS into temps) were missed by the DOTIMES
;; case's iter-local-reset loop, so their adjoints accumulated across
;; iterations and produced exactly-wrong scaled gradients.
;;
;; This adds WHEN and UNLESS clauses that recurse into the body.

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


(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht
                                           scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr).
   Overlay change (049/11 fix): field-name extraction in the accessor rules
   strips both leading and trailing tildes so the raw `~X~` form routes
   correctly.

   Bug 032 fix: indexed `~` reads on a local-scratch tile (src is a member of
   SCRATCH-TILE-SYMS, the hash table of locally make-scratch-*-bound syms)
   emit an indexed `(set! (~ src_ADJ indices) ...)` into the auto-allocated
   tile_ADJ tensor instead of falling through to the scalar `(local-adj src)`
   path -- which would shadow the tensor binding in the wrap-let.

   SCRATCH-TILE-SYMS is built by GENERATE-BACKWARD-WALK from flat-anf and
   threaded through; absence (NIL or empty) keeps the original scalar path."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (cond
      ((and (consp expr) (eq (car expr) '+))
        (let ((a (cadr expr)) (b (caddr expr)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
      ((and (consp expr) (eq (car expr) '-))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
      ((and (consp expr) (eq (car expr) '*))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
      ((and (consp expr) (eq (car expr) '/))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
      ((and (consp expr) (eq (car expr) 'sin))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
              (setf (gethash cos-a adjoint-map) cos-a)
              (emit `(set! ,cos-a (cos ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
      ((and (consp expr) (eq (car expr) 'cos))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
              (setf (gethash sin-a adjoint-map) sin-a)
              (emit `(set! ,sin-a (sin ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
      ((and (consp expr) (eq (car expr) '~))
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
              ;; --- Bug 032 fix: local-scratch tile read. ---
              ;; SRC has indices, is not a tensor kernel-input, AND is a
              ;; known make-scratch-* local — its _ADJ has been auto-
              ;; allocated by scratch-adj-bindings.  Indexed add into the
              ;; tile_ADJ tensor (NOT a scalar add) and intern src_ADJ
              ;; directly (NOT via local-adj) so the wrap-let does not give
              ;; it a stale scalar-0.0 init that would shadow the real
              ;; tensor binding.
              ;;
              ;; The scratch-tile-syms gate matters: indexed reads on ANF
              ;; temps holding e.g. (EXTENTS~ T) arrays would otherwise
              ;; route here and emit nonsense `(set! (~ %anf-t-N_ADJ 0) ...)`
              ;; — those adjs are scalar, not tensors.
              ((and indices scratch-tile-syms
                    (gethash src scratch-tile-syms))
               (let ((src-adj (intern (format nil "~A_ADJ" (symbol-name src))
                                      (symbol-package src))))
                 (emit `(set! (~ ,src-adj ,@indices)
                              (+ (~ ,src-adj ,@indices) ,v-adj)))))
              (t
               (emit `(set! ,(local-adj src) (+ ,(local-adj src) ,v-adj))))))))
      ;; Differentiable sub-function call
      ((and (consp expr)
            (symbolp (car expr))
            (gethash (car expr) *differentiable-functions*))
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
                                     (if (symbolp v) (symbol-name v) "BW")))))
      ;; Record-aware accessor.  Field-name extraction trims both tildes
      ;; (049/11 fix) so X~ and ~X~ both yield the field name "X".
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~)))
            *record-param-field-adjs*
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
            (emit `(set! ,field-adj-sym (+ ,field-adj-sym ,v-adj))))))
      ;; Struct-kernel-param accessor.  Same tilde-strip fix applies.
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~)))
            *struct-kernel-param-shadows*
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
            (t nil))))
      ;; Record constructor backward rule.
      ((and (consp expr) (symbolp (car expr))
            (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
            *record-param-field-adjs*
            (gethash v *record-param-field-adjs*))
        (let* ((ctor-args (cddr expr))
               (field-alist (gethash v *record-param-field-adjs*)))
          (loop for (field-name-str . field-adj-sym) in field-alist
                for ctor-arg in ctor-args
                when (and (symbolp ctor-arg) field-adj-sym)
                do (setf (gethash field-adj-sym adjoint-map) field-adj-sym)
                   (emit `(set! ,(local-adj ctor-arg)
                                (+ ,(local-adj ctor-arg) ,field-adj-sym))))))
      ;; Existing accessor rule (identity flow to record/struct symbol)
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~))))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
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
      (t nil))))


;; src/autodiff.lisp
;;
;; Bug 032 fix: the SET! branch of process-form previously dropped writes
;; whose target was neither a kernel input nor output (e.g. a local-mem
;; scratch tile written to by a workgroup-stride body).  Emitting nothing
;; meant the chain rule for the RHS expression's upstream gradient never
;; got seeded, so any in-place transform on a scratch tile sandwiched
;; between load-tile-coords and store-tile-coords lost its derivative.
;;
;; This is a whole-function replacement of GENERATE-BACKWARD-WALK from
;; src/autodiff.lisp with one targeted change: the (t nil) fall-through
;; in the SET!-on-(~ TARGET INDICES) cond is replaced by an emit pair that
;; consumes target_ADJ[indices] into val_adj and resets target_ADJ[indices].
;;
;; All other code is verbatim from src/autodiff.lisp.

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
        (cl:flet ((promotes-to-double-p (t-spec)
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
                          (let ((place (cadr form))
                                (val   (caddr form)))
                            (when (and (consp place) (eq (car place) '~) (symbolp val))
                              (let ((target  (cadr place))
                                    (indices (cddr place)))
                                (cond
                                  ((member target outputs)
                                   (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                           (symbol-package target))))
                                     (funcall emit-fn `(set! ,(local-adj val)
                                                             (+ ,(local-adj val) (~ ,tgt-grad ,@indices))))))
                                  ((member target inputs)
                                   (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                                          target target))
                                  ;; --- Bug 032 fix: local-scratch target. ---
                                  ;; The forward overwrote tile[indices] with val.
                                  ;; The backward consumes the upstream
                                  ;; tile_ADJ[indices] into val_adj, then zeroes
                                  ;; tile_ADJ[indices] so subsequent chain-rule
                                  ;; contributions (from the backward of the RHS
                                  ;; expression's index reads) populate it fresh.
                                  ;; Without this, any in-place tile mutation
                                  ;; between load-tile-coords and store-tile-coords
                                  ;; silently loses its derivative.
                                  ;;
                                  ;; Gated on scratch-tile-syms membership; other
                                  ;; non-input/output set! targets fall through
                                  ;; (old behavior) to avoid emitting nonsense
                                  ;; indexed adjs for unrelated symbols.
                                  ((and scratch-tile-syms
                                        (gethash target scratch-tile-syms))
                                   (let ((tgt-adj (%tlc-bwd-adj-name
                                                   target inputs outputs
                                                   #'local-adj kernel-pkg)))
                                     (funcall emit-fn
                                              `(set! ,(local-adj val)
                                                     (+ ,(local-adj val)
                                                        (~ ,tgt-adj ,@indices))))
                                     (funcall emit-fn
                                              `(set! (~ ,tgt-adj ,@indices)
                                                     ,intermediate-zero))))
                                  (t nil))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LET"))
                          (let* ((bindings (cadr form))
                                 ;; Phase 1c: auto-allocate <var>_ADJ paired scratch.
                                 (augmented-bindings (%augment-scratch-adj-bindings bindings kernel-pkg))
                                 (body (cddr form))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit))
                              (dolist (b (reverse bindings))
                                (when (and (consp b) (= (length b) 2) (symbolp (car b)))
                                  (process-form b #'local-emit))))
                            (funcall emit-fn `(let ,augmented-bindings ,@(nreverse local-forms)))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DOTIMES"))
                          (let* ((binding (cadr form))
                                 (body (cddr form))
                                 (local-vars (%collect-locally-bound-vars body))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit)))
                            (let ((zero-resets
                                   (loop for v in local-vars
                                         for adv = (gethash v adjoint-map)
                                         when adv
                                         collect `(set! ,adv ,intermediate-zero))))
                              (funcall emit-fn
                                       `(dotimes ,binding
                                          ,@zero-resets
                                          ,@(nreverse local-forms))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "IF"))
                          (let* ((cond-form (cadr form))
                                 (then-form (caddr form))
                                 (else-form (cadddr form))
                                 (then-local nil)
                                 (else-local nil))
                            (when then-form
                              (process-form then-form (lambda (f) (push f then-local))))
                            (when (and else-form (not (null else-form)))
                              (process-form else-form (lambda (f) (push f else-local))))
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
