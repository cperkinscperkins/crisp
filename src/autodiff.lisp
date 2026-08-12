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
              `(let (,@(mapcar (lambda (d) `(,d ,(%ad-zero *ad-any-output-double*))) deltas))
                 (let (,(append deltas (list call-form)))
                   ,@accum-forms))))
          ;; Tensor-only: just emit the call as a statement.
          (t (funcall emit-fn call-form)))))
     ;; No tensors, has scalar accumulations: existing multi-value-bind path.
     (accum-forms
       (funcall emit-fn
         `(let (,@(mapcar (lambda (d) `(,d ,(%ad-zero *ad-any-output-double*))) deltas))
            (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
              ,@accum-forms))))
     (t nil))))


(defvar *ffi-baseptr-src* nil
  "Endeavor 123 (FFI-AD) backward-walk dynamic map: pointer-temp-sym -> source
   storage sym, built from (temp (base-ptr~ src)) ANF bindings. Lets
   %emit-foreign-backward route a foreign pointer argument's gradient SHADOW to
   the source storage's grad cell, <src>_GRAD. Bound in generate-backward-walk.")

(defun %emit-foreign-backward (fn args t-adj-forms pkg emit-fn local-adj-fn)
  "Endeavor 123 (FFI-AD): emits the user-supplied VJP call for foreign function
   FN. Call shape mirrors the mechanically-derived VJP signature:

       (BKWD  primals...  seeds...  shadows...)

     - primals = ARGS (the original forward args, in order)
     - seeds   = T-ADJ-FORMS (adjoints of the active returns; empty for => nil)
     - shadows = (base-ptr~ <src>_GRAD) for each c-pointer/voidp param, where
                 <src> is the storage the forward pointer came from via
                 (base-ptr~ <src>), resolved through *ffi-baseptr-src*.

   The VJP returns one delta per ACTIVE SCALAR input (float/int), in forward
   order; each is accumulated into that input arg's local adjoint. Pointer-input
   gradients are written through the shadow pointers by the VJP body, not
   returned. Handles and other passive params get nothing."
  (let* ((info (gethash fn *differentiable-functions*))
         (bkwd (getf info :bkwd-name))
         (ptr-indices (getf info :pointer-param-indices))
         (scalar-indices (getf info :active-scalar-indices))
         (base-ptr-sym (or (find-symbol "BASE-PTR~" (find-package :crisp-language))
                           (intern "BASE-PTR~" (find-package :crisp-language))))
         (shadow-args
          (loop for i in ptr-indices
                for arg = (nth i args)
                for src = (and (symbolp arg) (gethash arg *ffi-baseptr-src*))
                collect (if src
                            (list base-ptr-sym
                                  (intern (format nil "~A_GRAD" (symbol-name src))
                                          (symbol-package src)))
                            (error "FFI-AD: cannot route a gradient shadow for pointer argument ~A of foreign function ~A inside a differentiable kernel. FFI pointer arguments must be produced by (base-ptr~~ <storage>) so the shadow can target <storage>_GRAD." arg fn))))
         (call-form `(,bkwd ,@args ,@t-adj-forms ,@shadow-args))
         (n-fp (length scalar-indices))
         (deltas (loop for i from 0 below n-fp
                       collect (intern (format nil "%FBW_D~a" i) pkg))))
    (if (zerop n-fp)
        ;; No active scalar inputs (e.g. all-pointer / void-return): the shadow
        ;; writes are the whole backward effect; emit the call as a statement.
        (funcall emit-fn call-form)
        ;; Bind the returned deltas, then accumulate each into its active scalar
        ;; argument's adjoint (skipping pointer/handle args by index).
        (let ((accum (loop for d in deltas
                           for idx in scalar-indices
                           for arg = (nth idx args)
                             when (symbolp arg)
                           collect `(set! ,(funcall local-adj-fn arg)
                                          (+ ,(funcall local-adj-fn arg) ,d)))))
          (funcall emit-fn
            `(let (,@(mapcar (lambda (d) `(,d ,(%ad-zero *ad-any-output-double*))) deltas))
               (let (,(append deltas (list call-form)))
                 ,@accum)))))))


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


(defvar *ad-barrier-ring-syms* nil
  "Symbols bound by make-async-barrier / make-async-barrier-ring in the kernel being
   differentiated.  Bound by generate-backward-walk.")

(defun %ad-collect-view-aliases (flat-anf)
  "Alist TEMP -> `(ring-get R i)` for every ANF temp bound to a view selector.
   Feeds *ad-view-alias-map* so accessors can see through the hoist ANF introduces."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form)) (first form)
                  (consp (second form)) (symbolp (first (second form)))
                  (string-equal (symbol-name (first (second form))) "RING-GET")
                  (not (assoc (first form) acc)))
         (push (cons (first form) (second form)) acc))))
    acc))

(defun %ad-collect-barrier-ring-syms (flat-anf)
  "The symbols in FLAT-ANF bound to a BARRIER (ring) constructor.

   Needed because `ring-get` means two different things depending on what it indexes, and the
   walk cannot tell them apart from the call alone."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-ASYNC-BARRIER" "MAKE-ASYNC-BARRIER-RING")
                          :test #'string=))
         (pushnew (first form) acc))))
    acc))

(defun %ad-inert-ring-get-p (expr)
  "T when EXPR is `(ring-get R i)` and R is a BARRIER ring.

   RING-GET MUST NOT BE DECLARED INERT AS AN OPERATOR.  It means two different things:

     (ring-get BARRIER-RING i) -> a barrier.  Carries ordering, not value; gradient is
                                  exactly zero, same footing as make-async-barrier itself.
     (ring-get TILE-RING i)    -> a VIEW of slot i.  Its adjoint is slot i of the adjoint
                                  ring, and the engine already relies on that in
                                  %ad-tile-base / %tlc-bwd-adj-name.

   Declaring the operator inert would silently zero the gradient of every ring-staged tile —
   the exact failure mode endeavour 146 Gap 2 removed for rem/mod.  So the distinction is made
   from the RING's constructor, which *ad-barrier-ring-syms* records."
  (and (consp expr) (symbolp (car expr))
       (string-equal (symbol-name (car expr)) "RING-GET")
       (symbolp (second expr))
       (member (second expr) *ad-barrier-ring-syms*)))

(defun %ad-rem-or-mod-form-p (expr)
  "T when EXPR is a two-argument (rem a b) or (mod a b) call.
   Matched by symbol-NAME so it holds whichever package the kernel's reader interned
   the operator into."
  (and (consp expr) (symbolp (car expr))
       (member (symbol-name (car expr)) '("REM" "MOD") :test #'string=)
       (= (length expr) 3)))

(defun %ad-widening-conversion-form-p (expr)
  "T when EXPR is a conversion to a FLOAT type — `(to-float x)`, `(to-double x)`,
   `(to-half x)`, `(to-bfloat16 x)`.

   The asymmetry with the INTEGER conversions is mathematical, not arbitrary, and worth
   stating because the two look alike:

     int -> float   is the IDENTITY on value.  d/dx = 1, so the adjoint passes straight
                    through.  That is this predicate.
     float -> int   TRUNCATES.  It is a step function, so d/dx = 0 almost everywhere, and
                    treating it as gradient-inert is CORRECT rather than a convenience —
                    which is why %backward-skip-fn-p-145p1's TO-<int-type> suffix rule is
                    sound where an operator-level claim about, say, rem would not have been."
  (and (consp expr) (symbolp (car expr))
       (member (symbol-name (car expr))
               '("TO-FLOAT" "TO-DOUBLE" "TO-HALF" "TO-BFLOAT16")
               :test #'string=)
       (= (length expr) 2)))

(defun %ad-handle-widening-conversion-backward (v expr emit-fn local-adj-fn)
  "Backward rule for a float-widening conversion: d/dx = 1, so `x_adj += v_adj`.

   Endeavor 146: before this, `to-float` had no rule at all and reported
   `Function TO-FLOAT is not differentiable` — which 132/08 carried as a skip reason
   describing it, correctly, as a gap the engine simply lacked rather than an MMA limit.

   The `symbolp` guard matches the other math rules: a literal operand has no adjoint to
   update.  Note that when the argument is itself gradient-inert — a shape query, as in
   132/08's `(to-float M)` where M comes from outer-dimensions — the adjoint flows into
   something the walk already skips, and the result is a correct zero reached by the
   analysis rather than asserted by a special case."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (let ((a (cadr expr)))
      (when (symbolp a)
        (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
      t)))

(defun %ad-handle-rem-backward (v expr emit-fn local-adj-fn)
  "Backward rule for (rem a b) / (mod a b) — endeavor 146 Gap 2.

       rem(a,b) = a - b*q,  q = trunc(a/b)
       d/da = 1                    ->  a_adj += v_adj
       d/db = -q = -((a - v)/b)    ->  b_adj += -((a-v)/b) * v_adj

   q is reconstructed from the already-bound result V rather than recomputed, which keeps
   this EXACT for integers: a - v is exactly b*q, so the division cannot truncate away
   anything.  Crisp does mathematically accurate derivatives for integer types too; the
   result being trivially zero downstream is the activeness analysis's conclusion to draw,
   not this rule's assumption to make.

   MOD shares the formula — it differs from REM only in taking floor rather than trunc for
   negative operands, and q = (a - v)/b holds for either.

   d/da = 1 holds almost everywhere: rem is piecewise linear with slope 1, discontinuous at
   multiples of b.  That is the same a.e. footing abs() already stands on.

   Mirrors the shape of the '/' rule below, including the `symbolp` guards — a literal
   operand has no adjoint to update, which is why the overwhelmingly common `(rem li 8)`
   emits only the d/da term.

   Before this, rem/mod sat in %backward-skip-fn-p and contributed zero gradient ALWAYS.
   See that function's docstring for why an entry there was the wrong shape of fix."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
      (when (symbolp a)
        (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
      (when (symbolp b)
        (emit `(set! ,(local-adj b)
                     (+ ,(local-adj b)
                        (* (* -1.0 (/ (- ,a ,v) ,b)) ,v-adj)))))
      t)))

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
     ;; Endeavor 128: transcendental derivatives. The derivative sub-expressions are
     ;; plain forward ops in the backward kernel (recomputed from the primal input),
     ;; not re-differentiated. asin/acos use pow(1-a^2, -0.5) rather than a sqrt op,
     ;; which isn't wired.
     ((eq (car expr) 'exp)   ; d/da exp(a) = exp(a)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (exp ,a) ,v-adj)))))
         t))
     ((eq (car expr) 'log)   ; d/da log(a) = 1/a
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,a) ,v-adj)))))
         t))
     ((eq (car expr) 'log2)  ; d/da log2(a) = 1/(a*ln2) = log2(e)/a
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.4426950408889634 ,a) ,v-adj)))))
         t))
     ((eq (car expr) 'tan)   ; d/da tan(a) = 1 + tan^2(a)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (+ 1.0 (* (tan ,a) (tan ,a))) ,v-adj)))))
         t))
     ((eq (car expr) 'asin)  ; d/da asin(a) = 1/sqrt(1-a^2) = (1-a^2)^-0.5
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (pow (- 1.0 (* ,a ,a)) -0.5) ,v-adj)))))
         t))
     ((eq (car expr) 'acos)  ; d/da acos(a) = -1/sqrt(1-a^2)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* -1.0 (pow (- 1.0 (* ,a ,a)) -0.5)) ,v-adj)))))
         t))
     ((eq (car expr) 'atan)  ; d/da atan(a) = 1/(1+a^2)
       (let* ((a (cadr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 (+ 1.0 (* ,a ,a))) ,v-adj)))))
         t))
     ((eq (car expr) 'pow)   ; v = a^b: d/da = b*a^(b-1); d/db = a^b*log(a)
       (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
         (when (symbolp a)
               (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* ,b (pow ,a (- ,b 1.0))) ,v-adj)))))
         (when (symbolp b)
               (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* (pow ,a ,b) (log ,a)) ,v-adj)))))
         t))
     ((eq (car expr) 'atan2) ; v = atan2(y,x): d/dy = x/(x^2+y^2); d/dx = -y/(x^2+y^2)
       (let* ((y (cadr expr)) (x (caddr expr)) (v-adj (local-adj v)))
         (when (symbolp y)
               (emit `(set! ,(local-adj y) (+ ,(local-adj y) (* (/ ,x (+ (* ,x ,x) (* ,y ,y))) ,v-adj)))))
         (when (symbolp x)
               (emit `(set! ,(local-adj x) (+ ,(local-adj x) (* (/ (* -1.0 ,y) (+ (* ,x ,x) (* ,y ,y))) ,v-adj)))))
         t))
     (t nil))))

(defvar *ad-view-alias-map* nil
  "Alist TEMP -> VIEW-FORM for ANF temps bound to a pure view selector, currently
   `(ring-get R i)`.  Bound by generate-backward-walk.

   ANF hoists a view out of its enclosing expression:

       (LET ((%ANF-T-3 (RING-GET TILES 0)) (%ANF-T-4 (~ %ANF-T-3 0)))
         (SET! (~ C 0) %ANF-T-4))

   so the accessor's source is a TEMP rather than the view the engine was taught about in
   endeavour 138.  This map lets the accessor see through it.")

(defun %ad-resolve-view-alias (sym)
  "SYM's view form if it is an ANF temp bound to one, else NIL."
  (and (symbolp sym) (cdr (assoc sym *ad-view-alias-map*))))

(defun %ad-view-adjoint (view)
  "The adjoint of a pure view is THE SAME VIEW OF THE ADJOINT — endeavour 138's rule.
   `(ring-get TILES 0)` -> `(ring-get TILES_ADJ 0)`.

   Holds because ring-get is address arithmetic with no side effects, so slot i of the
   adjoint ring IS the adjoint of slot i.  Recurses so a view of a view still works."
  (if (and (consp view) (symbolp (car view))
           (string-equal (symbol-name (car view)) "RING-GET"))
      (let ((base (second view)))
        (list (car view)
              (if (symbolp base)
                  (intern (format nil "~A_ADJ" (symbol-name base)) (symbol-package base))
                  (%ad-view-adjoint base))
              (third view)))
      view))

(defun %handle-tilde-backward (v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms)
  "Handles the tilde (~) indexing operation.

   Endeavor 146: the source may be an ANF temp aliasing a VIEW (see *ad-view-alias-map*).
   Before this, such a source was not a symbol the branches below recognised and the whole
   `when` simply fell through — dropping the gradient SILENTLY rather than erroring, which is
   the worst of the two.  A view source now scatters into the same view of the adjoint."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (let* ((src (cadr expr))
           (indices (cddr expr))
           (v-adj (local-adj v))
           (view (or (%ad-resolve-view-alias src)
                     (and (consp src) (symbolp (car src))
                          (string-equal (symbol-name (car src)) "RING-GET")
                          src))))
      (when view
        (let ((dst (%ad-view-adjoint view)))
          (emit `(set! (~ ,dst ,@indices) (+ (~ ,dst ,@indices) ,v-adj))))
        (return-from %handle-tilde-backward t))
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
    (let* ((fn (car expr))
           (args (cdr expr))
           (info (gethash fn *differentiable-functions*)))
      (cond
       ((getf info :hof)
         (if hof-handler-fn
             (funcall hof-handler-fn fn args v)
             (error "HOF handler required for sub-function ~A but not provided" fn)))
       ;; Endeavor 123 (FFI-AD): a foreign function with a single active return
       ;; bound as (v (c_foo ...)). The seed is v's adjoint; shadows + scalar
       ;; deltas are handled by %emit-foreign-backward.
       ((getf info :foreign)
         (%emit-foreign-backward fn args
                                 (list (local-adj v))
                                 (symbol-package v)
                                 emit-fn local-adj-fn))
       (t
         (%emit-sub-fn-backward fn args
                                (getf info :bkwd-name)
                                (list (local-adj v))
                                (getf info :n-float-params)
                                (symbol-package v)
                                emit-fn local-adj-fn
                                (if (symbolp v) (symbol-name v) "BW")))))
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


  
;; Re-definition of the src/ original.  CHANGE: one added clause giving the fragment-level
;; MMA forms an actionable error instead of the generic "not differentiable" advice.
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
   ;; Endeavor 146 Gap 2: rem / mod.  Kept as its own clause rather than added to the
   ;; member list below because that list tests with #'eq against symbols read in THIS
   ;; package, and a kernel's reader may intern `rem` elsewhere.  Matching by symbol-name
   ;; sidesteps the question entirely.
   ((%ad-rem-or-mod-form-p expr)
     (%ad-handle-rem-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: int -> float is the identity on value, so the adjoint passes through.
   ;; (float -> int truncates and stays inert — see %ad-widening-conversion-form-p.)
   ((%ad-widening-conversion-form-p expr)
     (%ad-handle-widening-conversion-backward v expr emit-fn local-adj-fn))
   ;; Endeavor 146: (ring-get BARRIER-RING i) is a scheduling object, not a value.  Scoped by
   ;; the ring's constructor rather than by the operator name — see %ad-inert-ring-get-p.
   ((%ad-inert-ring-get-p expr) nil)
   ;; Endeavor 146: (V (ring-get TILE-RING i)) is an ALIAS, not a computation — ANF hoisted a
   ;; pure view selector into its own binding.  Nothing to emit here; the use sites see through
   ;; it via *ad-view-alias-map* (see %handle-tilde-backward).  Distinct from the barrier case
   ;; above, which is inert because a barrier carries no value at all.
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "RING-GET"))
     nil)
   ((and (consp expr) (member (car expr)
                              ;; Endeavor 128: transcendentals join the math/trig backward.
                              '(+ - * / sin cos exp log log2 tan asin acos atan pow atan2)
                              :test #'eq))
     (%handle-math-and-trig-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (eq (car expr) '~))
     (%handle-tilde-backward v expr emit-fn local-adj-fn tensor-inputs-ht scratch-tile-syms))
   ((and (consp expr)
         (symbolp (car expr))
         (gethash (car expr) *differentiable-functions*))
     (%handle-sub-fn-call-backward v expr emit-fn local-adj-fn hof-handler-fn))
   ;; An accessor that is GRADIENT-INERT must not be claimed here.  `extents~` ends in a
   ;; tilde, so %is-accessor-p takes it and %handle-accessor-backward mints a SCALAR adjoint
   ;; for its source.  On a scratch tile that scalar `<tile>_ADJ` COLLIDES with the tensor
   ;; `<tile>_ADJ` from scratch-adj-bindings, and since Crisp's LET is let*-like the scalar
   ;; (bound second) SHADOWS the tensor — after which every `(~ <tile>_ADJ i j)` indexes a
   ;; float.  That is what "No matching function overload for '~' / 'EXTENTS~' with argument
   ;; types (FLOAT ...)" meant, and it hit any differentiable kernel reading a scratch tile's
   ;; extents, i.e. every tile-stride matmul.
   ;;
   ;; Guarded HERE rather than by hoisting the skip clause to the top of the cond: that was
   ;; tried first and cost 11 specs (101/05, 101/06, 031/05 — record-field adjoints like
   ;; PA_X_ADJ went missing), because the skip predicate also matches mangled sub-function
   ;; names that the clauses below need to see.
   ((and (%is-accessor-p expr)
         (not (and (consp expr) (symbolp (car expr))
                   (%backward-skip-fn-p (car expr)))))
     (%handle-accessor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
         *record-param-field-adjs*
         (gethash v *record-param-field-adjs*))
     (%handle-constructor-backward v expr emit-fn local-adj-fn adjoint-map))
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
     nil)
   ;; Endeavor 124 (AD issues) A1: value-producing if / if+ / when[+] / unless[+]
   ;; and value-producing let. These bind a compound expression to V; the seed
   ;; V_adj must flow through the branches / let body (previously dropped, giving
   ;; a silent zero gradient, or erroring for the + variants).
   ((%value-if-p expr)
     (%handle-value-if-backward v expr adjoint-map emit-fn local-adj-fn
                                :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ((%value-let-p expr)
     (%handle-value-let-backward v expr adjoint-map emit-fn local-adj-fn
                                 :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                 :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ;; Endeavor 120: gradient-inert calls.
   ;;  - *inert-functions*: user functions with no differentiable params
   ;;    (zero gradient), recorded by %generate-backward-function-ast.
   ;;  - the compile-time uniformity intrinsics, which fold to constants and
   ;;    carry no gradient.
   ((and (consp expr) (symbolp (car expr))
         (%backward-skip-fn-p (car expr)))
     nil)
   ((and (consp expr) (symbolp (car expr))
         (or (gethash (car expr) *inert-functions*)
             (member (symbol-name (car expr))
                     '("PROVABLY-UNIFORM?" "PROVABLY-DIVERGENT?" "UNIFORMITY-STATE"
                       "TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
                     :test #'string=)))
     nil)
   ;; FRAGMENT-level MMA forms that no VJP claims.
   ;;
   ;; Endeavor 146: this message used to argue that a fragment backward is IMPOSSIBLE — "on a
   ;; single fragment one of the two backward GEMMs always violates the hardware shape
   ;; contract".  That claim was RETRACTED by 145 itself and is now demonstrably false:
   ;; 145/13 gradient-checks a fragment MMA on BMG (expect.A=1.2) and 145/07, which was written
   ;; as a NEGATIVE test asserting the impossibility, is now a positive one.  The retraction
   ;; routed the fragment backward through MEMORY, exactly as the tile VJP already routed dC,
   ;; and the lane-spanning reduction the old argument rested on does not arise.
   ;;
   ;; What is actually true is narrower and is about COVERAGE, not mathematics: the registry
   ;; has a VJP for `store-fragment` applied DIRECTLY to an `mma-accumulate` (the canonical
   ;; hello-mma chain), and not for other fragment shapes — an accumulator loaded by
   ;; `load-fragment-acc` and carried across a loop, for instance.
   ;;
   ;; The distinction matters because an over-broad diagnostic is how "MMA is forward-only"
   ;; became folklore in the first place: users read a claim about the hardware, believed it,
   ;; and wrote `forward-only` into kernels that did not need it.  Say what is missing, not
   ;; what is impossible.
   ((and (consp expr) (symbolp (car expr))
         (member (symbol-name (car expr))
                 '("MMA-ACCUMULATE" "LOAD-FRAGMENT-A" "LOAD-FRAGMENT-B"
                   "LOAD-FRAGMENT-ACC" "STORE-FRAGMENT" "MAKE-REGISTER-FRAGMENT")
                 :test #'string=))
     (when error-on-unknown
       (error "~A: no VJP is registered for this FRAGMENT-level MMA form.  This is a gap in COVERAGE, not a limit of the mathematics -- dA = dC.B^T and dB = A^T.dC hold at every shape, and a fragment-level backward IS supported for the canonical chain, `(store-fragment (mma-accumulate ACC A-frag B-frag) DST coords)`, which is gradient-checked on metal by 145/13.  Options: (1) express the multiply at TILE level with mma-accumulate-via-tile over a register tile -- the best-covered surface, with numeric proof in 142/01 and 145/12; (2) reshape into the covered fragment chain above; (3) if this kernel really is forward-only, use SKIP-WITH[--differentiate] or (declare forward-only).  If you need this form differentiated, the fix is to register a VJP for it, not to work around a limit that does not exist."
              (car expr))))
   ((and (consp expr) (symbolp (car expr)))
     (when error-on-unknown
           (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
   (t nil)))


;;; ===================================================================
;;; Endeavor 124 (AD issues) A1: value-producing if / let backward.
;;;
;;; ANF binds compound expressions (if / if+ / when[+] / unless[+] / let) to a
;;; temp: e.g. (%t (if+ cond (let ((u (~ x))) (* u 2.0)) (~ x))). The seed %t_adj
;;; must flow through whichever branch was taken, and through the let body into
;;; its (branch-local) bindings. Previously %handle-single-value-backward dropped
;;; these (silent zero gradient for plain if; hard error for the + variants).
;;; ===================================================================

(defun %value-if-p (expr)
  "T if EXPR is a value-producing conditional: if / if+ / when / when+ /
   unless / unless+."
  (and (consp expr) (symbolp (car expr))
       (member (symbol-name (car expr))
               '("IF" "IF+" "WHEN" "WHEN+" "UNLESS" "UNLESS+")
               :test #'string=)))

(defun %value-let-p (expr)
  "T if EXPR is a value-producing LET."
  (and (consp expr) (symbolp (car expr))
       (string-equal (symbol-name (car expr)) "LET")))

(defun %forms->progn (forms)
  "NIL for no forms, the single form, else a (progn ...) wrapper."
  (cond ((null forms) nil)
        ((null (cdr forms)) (first forms))
        (t `(progn ,@forms))))

(defun %backward-value-expr (v expr adjoint-map emit-fn local-adj-fn
                             &key hof-handler-fn (error-on-unknown t)
                                  tensor-inputs-ht scratch-tile-syms)
  "Backward-AD for a VALUE expression EXPR whose result is bound to V (so V's
   adjoint is the incoming seed). Endeavor 124 A1: handles the symbol-copy and
   literal cases plus compound value exprs (if / let), recursing; leaf exprs
   (math, ~, calls, accessors) delegate to %handle-single-value-backward."
  (cond
   ;; copy: v <- s  =>  s_adj += v_adj  (skip self-copy)
   ((symbolp expr)
     (unless (eq expr v)
       (funcall emit-fn `(set! ,(funcall local-adj-fn expr)
                               (+ ,(funcall local-adj-fn expr) ,(funcall local-adj-fn v))))))
   ;; literal (number / non-symbol atom): no gradient
   ((not (consp expr)) nil)
   ((%value-if-p expr)
     (%handle-value-if-backward v expr adjoint-map emit-fn local-adj-fn
                                :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ((%value-let-p expr)
     (%handle-value-let-backward v expr adjoint-map emit-fn local-adj-fn
                                 :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                 :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   (t
     (%handle-single-value-backward v expr adjoint-map emit-fn local-adj-fn
                                    :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                    :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))))

(defun %handle-value-if-backward (v expr adjoint-map emit-fn local-adj-fn
                                  &key hof-handler-fn (error-on-unknown t)
                                       tensor-inputs-ht scratch-tile-syms)
  "Backward for a value-producing (if[+]/when[+]/unless[+] COND THEN ELSE): the
   result adjoint V_adj flows into whichever branch was taken. Emits a plain `if`
   mirroring the forward (the uniform-ness of if+ is irrelevant to the backward),
   each arm carrying its value's chain-rule contribution into V_adj."
  (let* ((head (symbol-name (car expr)))
         (cond-form (cadr expr))
         (when-like (member head '("WHEN" "WHEN+") :test #'string=))
         (unless-like (member head '("UNLESS" "UNLESS+") :test #'string=))
         (then-expr (cond (unless-like nil) (t (caddr expr))))
         (else-expr (cond (when-like nil)
                          (unless-like (caddr expr))
                          (t (cadddr expr))))
         (then-forms nil)
         (else-forms nil))
    (flet ((rec (branch collect)
             (when branch
               (%backward-value-expr v branch adjoint-map collect local-adj-fn
                                     :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                     :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))))
      (rec then-expr (lambda (f) (push f then-forms)))
      (rec else-expr (lambda (f) (push f else-forms)))
      (let ((then-body (%forms->progn (nreverse then-forms)))
            (else-body (%forms->progn (nreverse else-forms))))
        ;; Only emit if some branch contributes; both-empty is a no-op.
        (when (or then-body else-body)
          (funcall emit-fn
            (if else-body
                `(if ,cond-form ,(or then-body 'nil) ,else-body)
                `(if ,cond-form ,then-body)))))))
  t)

(defun %handle-value-let-backward (v expr adjoint-map emit-fn local-adj-fn
                                   &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht scratch-tile-syms)
  "Backward for a value-producing (let (BINDS) ... BODY-EXPR): the let's value is
   V. Recompute BINDS (forward), declare BRANCH-LOCAL adjoints for the bind temps,
   push V_adj through BODY-EXPR, then push each bind temp's adjoint through its rhs.
   The local adjoints are scoped to the emitted let so they don't collide with the
   global adjoint-map / top-level adjoint declarations. Endeavor 124 A1.

   NOTE: zero-inits the local adjoints with 0.0 (float). Double-chain interaction
   is deferred to the mixed-precision pass (Phase C)."
  (let* ((raw (cdr expr))
         (binds (car raw))
         (body-tail (cdr raw))
         (body-forms (remove-if (lambda (f) (and (consp f)
                                                 (symbolp (car f))
                                                 (string-equal (symbol-name (car f)) "DECLARE")))
                                body-tail))
         (body-expr (car (last body-forms)))
         (bind-pairs (remove-if-not (lambda (b) (and (consp b) (= (length b) 2) (symbolp (car b))))
                                    binds))
         (bind-syms (mapcar #'car bind-pairs))
         (pkg (or (symbol-package v) (find-package :crisp.compiler)))
         (local-map (make-hash-table :test 'eq))
         (collected nil))
    (flet ((blocal-adj (s)
             (if (member s bind-syms :test #'eq)
                 (or (gethash s local-map)
                     (setf (gethash s local-map)
                           (intern (format nil "~A_ADJ" (symbol-name s)) pkg)))
                 (funcall local-adj-fn s)))
           (bcollect (f) (push f collected)))
      ;; body value = v: push v_adj into the body expression
      (when body-expr
        (%backward-value-expr v body-expr adjoint-map #'bcollect #'blocal-adj
                              :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                              :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
      ;; backward of each binding in reverse: bind-temp adjoint -> rhs's vars
      (dolist (b (reverse bind-pairs))
        (%backward-value-expr (car b) (cadr b) adjoint-map #'bcollect #'blocal-adj
                              :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                              :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
      ;; emit: forward recompute of BINDS + local adjoint inits + backward forms
      (funcall emit-fn
        `(let (,@binds
               ,@(loop for adv being the hash-values of local-map
                       collect `(,adv ,(%ad-zero *ad-any-output-double*))))
           ,@(nreverse collected)))))
  t)


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
                    ((or (string-equal (symbol-name (car form)) "DOTIMES")
                         (string-equal (symbol-name (car form)) "DOTIMES+"))
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



(defun %is-tensor-alias (sym)
  (and (symbolp sym)
       (let ((res (resolve-type-alias sym)))
         (and (consp res)
              (member (symbol-name (first res)) '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))))

(defun %has-explicit-n (args)
  (and (integerp (second args))
       (not (%is-tensor-alias (first args)))))

(defun %promote-scratch-init-for-ad (init)
  "Promotes the type in a make-scratch-* form to its float adjoint equivalent.
   E.g., (make-scratch-vector ulong 4) -> (make-scratch-vector double 4)."
  (let* ((op (car init))
         (args (cdr init))
         (canonical (%scratch-tensor-canonical-spec op args))
         (elem-type (second canonical))
         (promoted-elem (if (%crisp-integer-scalar-type-p elem-type)
                            (%integer-scalar-to-float-scalar elem-type)
                            elem-type)))
    (cond
     ((or (string-equal (symbol-name op) "MAKE-SCRATCH-VECTOR")
          (string-equal (symbol-name op) "MAKE-SCRATCH-MATRIX"))
      (let ((size-expr (%extract-scratch-size-expr op args)))
        `(,op ,promoted-elem ,size-expr ,@(cddr args))))
     ((string-equal (symbol-name op) "MAKE-SCRATCH-TENSOR")
      (let ((size-expr (%extract-scratch-size-expr op args))
            (n (third canonical)))
        `(,op ,promoted-elem ,n ,size-expr ,@(if (%has-explicit-n args) (cdddr args) (cddr args)))))
     ((string-equal (symbol-name op) "MAKE-SCRATCH-CELL")
      `(,op ,(%promote-to-float-adjoint canonical)))
     (t init))))


(defun %augment-scratch-adj-bindings (bindings kernel-pkg)
  "For each binding (var (make-scratch-X ...)), inject a paired (var_ADJ (make-scratch-X ...))
   binding right after.  For other bindings, pass through unchanged.  Promotes element type
   (e.g., ulong -> double) so gradients use correct FP precision.

   Endeavor 145 P3b: MAKE-REGISTER-TILE joins the list, so a register accumulator declared in
   a NESTED let gets its paired adjoint tile the same way a scratch tile does.  (A top-level
   register tile is handled by the scratch-adj-bindings collection in generate-backward-walk.)

   Endeavor 138 rings: the RING constructors join too.  A ring is rank+1 scratch, so its adjoint
   is simply a ring of the same shape, and (ring-get R_ADJ i) is then the adjoint of
   (ring-get R i) — see %tlc-bwd-adj-name.  Note the BARRIER ring (make-async-barrier-ring) is
   deliberately NOT here: barriers are gradient-inert scheduling objects, and a barrier argument
   reaches the backward only as a :barrier key-arg, which the load/store-tile-at clauses ignore."
  (loop for b in bindings
          if (and (consp b) (= (length b) 2) (symbolp (car b))
                  (consp (cadr b)) (symbolp (caadr b))
                  (member (symbol-name (caadr b))
                          '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                            "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                            "MAKE-REGISTER-TILE"
                            "MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                            "MAKE-SCRATCH-TENSOR-RING")
                          :test #'string=))
          append (list b
                       (let* ((var (car b))
                              (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                               (or kernel-pkg (symbol-package var)))))
                         (list var-adj (%mma-ad-adj-init (cadr b)))))
          else collect b))



;;; ======================================================================
;;; 138 pipeline rings under --differentiate.
;;;
;;; Every 138 spec carried SKIP-WITH[--differentiate], and 03-06 failed with a raw Lisp type
;;; error rather than a Crisp diagnostic:
;;;
;;;     The value (CRISP.COMPILER:RING-GET TILES 0) is not of type SYMBOL
;;;
;;; Nothing about a ring is undifferentiable.  A ring is rank+1 scratch and `ring-get` is a pure
;;; VIEW selector — endeavor 138 says so itself, in the comment above `target-form` in
;;; analyze-aref-expression: a compound tensor target is "a pure view constructor (make-view:
;;; address arithmetic, no side effects)".  The forward path was taught that; the AD path was
;;; not.  Two gaps, both mechanical:
;;;
;;;   1. %tlc-bwd-adj-name assumed its argument was a SYMBOL and called symbol-name on it, so a
;;;      `(ring-get R i)` tile argument to load-tile / store-tile blew up.
;;;   2. %augment-scratch-adj-bindings did not know the ring constructors, so no adjoint ring
;;;      was allocated even once the naming worked.
;;;
;;; THE RULE, and it is the general one: THE ADJOINT OF A VIEW IS THE SAME VIEW OF THE ADJOINT.
;;; `(ring-get TILES 0)` has adjoint `(ring-get TILES_ADJ 0)`.  This holds because ring-get is
;;; pure address arithmetic: slot i of the adjoint ring is exactly the adjoint of slot i.  It
;;; needs no new backward machinery — the existing %load-tile-at-bwd / %store-tile-at-bwd edges
;;; then apply unchanged, which is why this is a naming fix and not a chapter of its own.
;;; ======================================================================
(defun %tlc-bwd-adj-name (sym inputs outputs local-adj-fn kernel-pkg)
  "Returns the backward-pass adjoint for a forward tile argument SYM:
     - SYM in INPUTS or OUTPUTS   → <SYM>_GRAD  (kernel param)
     - other symbol (let-bound)   → <SYM>_ADJ   (direct intern; NOT via local-adj-fn, which
       would add the sym to the adjoint-map and make the wrapping let scalar-initialize it —
       wrong for a tensor adjoint.  The auto-allocated <var>_ADJ make-scratch-* binding is the
       only initializer needed.)
     - a VIEW form (ring-get R i) → the same view of R's adjoint, (ring-get <R-adj> i).

   The view case is endeavor 138's rings.  ring-get is a pure view selector — address
   arithmetic, no side effects — so slot i of the adjoint ring IS the adjoint of slot i, and
   recursing on the ring lets the ordinary %load-tile-at-bwd / %store-tile-at-bwd edges apply
   with no new machinery.  Recursion (rather than a single level) costs nothing and keeps the
   rule true for a view of a view.

   Anything else is a compound target we have no adjoint rule for.  That now raises a message
   naming the form instead of letting symbol-name signal `The value (RING-GET ...) is not of
   type SYMBOL`, which told the user nothing about what to do."
  (declare (ignore local-adj-fn))
  (cond
   ((and (consp sym) (symbolp (car sym))
         (string-equal (symbol-name (car sym)) "RING-GET"))
     (list (car sym)
           (%tlc-bwd-adj-name (second sym) inputs outputs nil kernel-pkg)
           (third sym)))
   ((not (symbolp sym))
     (error "No adjoint rule for the tile expression ~s.  A tile argument must be a tensor ~
             symbol or a view of one (e.g. (ring-get RING slot))." sym))
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
        (val (caddr form)))
    (when (and (consp place) (eq (car place) '~) (symbolp val))
          (let ((target (cadr place))
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
  "BUG 037: the replayed primal bindings now read staged tiles from their ORIGINAL GLOBAL source
   instead of from the (empty) tile, and an unrecoverable primal that the backward actually uses
   is a hard error rather than a silent zero."
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
              (funcall process-form-fn b #'local-emit))))
    (let ((backward-body (nreverse local-forms)))
      (%ad-check-unresolved-primals augmented-bindings backward-body)
      (funcall emit-fn `(let ,(%ad-rewrite-primal-bindings augmented-bindings)
                          ,@backward-body)))))


(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  "Unchanged except that it publishes the loop variable in *ad-loop-vars* while walking the
   body, so a VJP dispatched inside can ask what coordinate it is being evaluated at.  A
   pipelined ring operand needs this: its primal lives at the CONSUMING iteration, and the
   forward's load sites record other stages' origins."
  (declare (ignore form))
  (let ((local-forms nil)
        (*ad-loop-vars* (if (and (consp binding) (symbolp (car binding)))
                            (cons (car binding) *ad-loop-vars*)
                            *ad-loop-vars*)))
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


;;; ===================================================================
;;; ANF NORMALIZATION FOR THE BACKWARD WALK  (endeavor 146)
;;;
;;; generate-backward-walk normalizes the flat ANF before walking it.  Every step
;;; below removes a distinction the DERIVATIVE does not care about, so that ONE
;;; VJP serves every scheduling variant of the same mathematics.
;;;
;;; WHY THIS IS A SINGLE SEAM RATHER THAN PER-RULE FIXES.  Endeavor 146 first
;;; patched each emitter that mishandled a register tile — the scalar lowering's
;;; origins, %mma-ad-transposed-stage, the %load-tile-at-bwd scatter — and a
;;; fourth site turned up immediately.  Every backward emitter reads its operands,
;;; shapes and origins from this ANF, so normalizing here fixes all of them at
;;; once, and an emitter added later is correct without knowing this exists.
;;;
;;; THE UNDERLYING FACT, which is easy to re-derive wrongly: the AD walk is a
;;; source-to-source transform that runs BEFORE semantic analysis, while
;;; %explode-register-tiles runs later from the LET analyzer.  A backward replays
;;; the forward's BINDINGS but not its STATEMENTS.  So in the backward a register
;;; tile has no binding (its symbol was replaced by per-lane fragment vars) and a
;;; staged tile is empty.  Scratch tiles keep their bindings, which is why 145's
;;; specs never hit any of this and 142's register-resident operands hit all of it.
;;;
;;; ORDER IS LOAD-BEARING — see %ad-normalize-anf-for-backward.
;;; ===================================================================

(defun %ad-inline-literal-shape-temps (flat-anf)
  "Substitute every ANF temp bound to a literal list of integers with that literal.

   `(%ANF-T-1 (64 64))` makes %ANF-T-1 a SHAPE, not a value -- the AD engine's shape
   maps require literals and a backward cannot reference a forward-only temp.  A
   binding is only inlined when its value is a non-empty list of integers, which no
   call form can be (a call's head is a symbol).

   The temp's OWN binding is left intact -- rewriting its left-hand side would produce
   the malformed `((64 64) (64 64))`.  Leaving the now-dead binding is harmless: the
   backward contains only what the walk emits."
  (let ((map nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form)) (first form)
                  (listp (second form)) (second form)
                  (every #'integerp (second form))
                  (not (assoc (first form) map)))
         (push (cons (first form) (second form)) map))))
    (if (null map)
        flat-anf
        (labels ((walk (f)
                   (cond
                     ((and f (symbolp f))
                      (let ((e (assoc f map))) (if e (cdr e) f)))
                     ((not (consp f)) f)
                     ;; a temp's own binding: leave entirely alone
                     ((and (= (length f) 2) (symbolp (first f)) (first f)
                           (assoc (first f) map))
                      f)
                     (t (mapcar #'walk f)))))
          (mapcar #'walk flat-anf)))))

(defun %ad-canonicalize-wgmma (form)
  "Rewrite Hopper wgmma forms to their synchronous MMA equivalents for the backward walk.

     (V (make-wgmma-accumulator T (M N) INIT))
       -> (V (make-register-tile T (M N) INIT))

     (wgmma-accumulate-via-tile (WM WN WK) D A B ...)
       -> (mma-accumulate-via-tile (NM NN NK) D A B ...)

   where (NM NN NK) is %spv-mma-shape -- the active profile's NATIVE instruction shape.
   The wgmma argument is a WARPGROUP TILE shape and is not a legal sync-MMA instruction
   shape; substituting the native one is what makes the emitted backward compilable.
   The VJP takes Mt/Nt/Kt from the tiles' dims-map entries, never from this argument,
   so tile geometry and the derivative are unaffected.

   Trailing keys (:swizzle and friends) are preserved; the via-tile VJP destructures
   (SHAPE C A B &rest ignored).

   Structural no-op for any kernel without wgmma."
  (let* ((cl (find-package :crisp-language))
         (mrt (intern "MAKE-REGISTER-TILE" cl))
         (mvt (intern "MMA-ACCUMULATE-VIA-TILE" cl)))
    (labels ((head-is (f name)
               (and (consp f) (symbolp (first f))
                    (string-equal (symbol-name (first f)) name)))
             (native-shape ()
               (multiple-value-bind (m n k) (%spv-mma-shape) (list m n k)))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((head-is f "MAKE-WGMMA-ACCUMULATOR")
                  (cons mrt (mapcar #'walk (rest f))))
                 ((head-is f "WGMMA-ACCUMULATE-VIA-TILE")
                  (list* mvt (native-shape) (mapcar #'walk (cddr f))))
                 (t (mapcar #'walk f)))))
      (walk form))))

(defun %ad-register-ring-dims-map (flat-anf)
  "Alist SYM -> (d0 d1) for every `(make-register-tile-ring T (D0 D1) ...)` binding.

   Must be computed from the ORIGINAL anf, BEFORE %ad-canonicalize-register-rings turns
   these into scratch rings -- afterwards they are indistinguishable from rings the user
   really wrote as scratch, whose extents must be left alone."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (string-equal (symbol-name (first (second form)))
                                "MAKE-REGISTER-TILE-RING")
                  (let ((d (third (second form))))
                    (and (listp d) d (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (cons (first form) (third (second form))) acc))))
    (nreverse acc)))

(defun %ad-normalize-ring-view-extents (form ring-dims)
  "Replace `(~ (extents~ (ring-get RING I)) J)` with RING's compile-time per-slot extent J,
   emitted as `(to-ulong N)`, for every RING in RING-DIMS.

   Every slot of a ring has the ring's element shape (138), so the slot index is irrelevant
   to the answer and is not examined.  The ULONG wrap is required for the same reason as in
   %ad-normalize-register-extents: these reads sit inside `(* (to-ulong G) <extent>)`.

   No-op when RING-DIMS is empty."
  (if (null ring-dims)
      form
      (let ((tu (intern "TO-ULONG" (find-package :crisp-language))))
        (labels ((ring-base (f)
                   ;; (ring-get SYM i) -> SYM, else NIL
                   (and (consp f) (symbolp (first f))
                        (string-equal (symbol-name (first f)) "RING-GET")
                        (symbolp (second f))
                        (second f)))
                 (static-extent (f)
                   (and (consp f) (= (length f) 3)
                        (symbolp (first f))
                        (string-equal (symbol-name (first f)) "~")
                        (consp (second f))
                        (symbolp (first (second f)))
                        (string-equal (symbol-name (first (second f))) "EXTENTS~")
                        (integerp (third f))
                        (let ((base (ring-base (second (second f)))))
                          (and base
                               (nth (third f) (cdr (assoc base ring-dims)))))))
                 (walk (f)
                   (cond ((not (consp f)) f)
                         ((static-extent f) (list tu (static-extent f)))
                         (t (mapcar #'walk f)))))
          (walk form)))))

(defun %ad-canonicalize-register-rings (form)
  "Rewrite `(make-register-tile-ring T (M N) :ring-count N :operand :a)` to
   `(make-scratch-matrix-ring T (M N) :ring-count N)` for the backward walk.

   A ring of MMA operand tiles has the same adjoint requirement a single operand tile
   has (Gap 4): every consumer indexes the adjoint as memory.  A ring being rank+1
   scratch, the scratch matrix ring is that answer one dimension up, and it is a form
   the AD engine has understood since 138.

   :operand is dropped -- it picks a GRF fragment layout, which scratch has no use for.
   :ring-count is kept; it is the ring's real depth.

   The replacement symbol is resolved in :crisp.compiler, where the defmacro lives, so
   the analyzer actually macroexpands what we emit.

   Structural no-op for any kernel without register-tile rings."
  (let* ((cc (find-package :crisp.compiler))
         (msmr (or (find-symbol "MAKE-SCRATCH-MATRIX-RING" cc)
                   (intern "MAKE-SCRATCH-MATRIX-RING" cc))))
    (labels ((drop-operand (keys)
               ;; keys is a flat &key plist tail; drop the :operand pair only.
               (cond ((null keys) nil)
                     ((and (symbolp (first keys))
                           (string-equal (symbol-name (first keys)) "OPERAND"))
                      (drop-operand (cddr keys)))
                     (t (cons (first keys) (drop-operand (rest keys))))))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((and (symbolp (first f))
                       (string-equal (symbol-name (first f)) "MAKE-REGISTER-TILE-RING"))
                  (list* msmr (second f) (third f) (drop-operand (cdddr f))))
                 (t (mapcar #'walk f)))))
      (walk form))))

(defun %ad-register-tile-dims-map (flat-anf)
  "Alist SYM -> (d0 d1 ...) for every `(V (make-register-tile T (D0 D1) INIT ...))`
   binding anywhere in FLAT-ANF, including nested bodies.

   Deliberately NARROWER than %mma-ad-tile-dims-map: only register tiles, because only
   they lose their binding before the backward is analysed.  Scratch tiles keep their
   runtime extents~ and must be left exactly as they are."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (string-equal (symbol-name (first (second form))) "MAKE-REGISTER-TILE")
                  (let ((d (third (second form))))
                    (and (listp d) d (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (cons (first form) (third (second form))) acc))))
    (nreverse acc)))

(defun %ad-normalize-register-extents (form reg-dims)
  "Replace every `(~ (extents~ TILE) I)` where TILE is a register tile in REG-DIMS
   with its compile-time extent, emitted as `(to-ulong N)`.

   The ULONG wrap is required: extents~ yields ULONG and these reads sit inside
   `(* (to-ulong G) <extent>)`, while a Lisp integer literal reads as Crisp INT --
   a bare literal gives `Cannot operate on ULONG and INT`.

   Any form that does not match is returned structurally unchanged, so this is a
   no-op for every kernel with no register tiles."
  (if (null reg-dims)
      form
      (let ((tu (intern "TO-ULONG" (find-package :crisp-language))))
        (labels ((static-extent (f)
                   (and (consp f) (= (length f) 3)
                        (symbolp (first f))
                        (string-equal (symbol-name (first f)) "~")
                        (consp (second f))
                        (symbolp (first (second f)))
                        (string-equal (symbol-name (first (second f))) "EXTENTS~")
                        (symbolp (second (second f)))
                        (integerp (third f))
                        (nth (third f) (cdr (assoc (second (second f)) reg-dims)))))
                 (walk (f)
                   (cond ((not (consp f)) f)
                         ((static-extent f) (list tu (static-extent f)))
                         (t (mapcar #'walk f)))))
          (walk form)))))

(defun %ad-canonicalize-warp-specialization (form)
  "Rewrite every `(with-warp-specialization ...)` in FORM to the warp-id-gated let/if that
   the ANALYZER produces — by calling the analyzer's own %lower-warp-specialization rather
   than re-implementing it.

   WHY THE WALK NEEDS THIS.  with-warp-specialization is not a macro; it is handled by
   analyze-with-warp-specialization-expression, and the AD walk runs BEFORE semantic
   analysis.  So the walk sees the raw construct and reads a role block `(:consumer ...)`
   as a call to a function named CONSUMER — which is exactly the error 139/02, /05 and /06
   reported, and why they were mislabelled 'warp specialization is forward-only'.

   REUSE, NOT SUBSTITUTION — the distinction matters and the two live side by side in this
   chain.  %ad-canonicalize-wgmma SUBSTITUTES: the backward deliberately uses a different
   instruction from the forward (sync MMA rather than warpgroup-async), because a backward
   is under no obligation to schedule itself the way its forward did.  Warp specialization
   is the opposite case: the backward wants the SAME expansion the forward gets, just
   earlier.  Calling the analyzer's lowering is what keeps the two paths from drifting; a
   second hand-written copy here would eventually produce a gradient that is correct for a
   kernel nobody runs.

   Recurses into the result so a nested construct is lowered too; terminates because the
   lowered form no longer has WITH-WARP-SPECIALIZATION at its head."
  (labels ((walk (f)
             (cond
               ((not (consp f)) f)
               ((and (symbolp (first f))
                     (string-equal (symbol-name (first f)) "WITH-WARP-SPECIALIZATION"))
                ;; :gated nil — the backward does not honour the role split.  See
                ;; %lower-warp-specialization for why, and the 146 endeavor doc for the
                ;; limitation this carries.
                (walk (%lower-warp-specialization f nil :gated nil)))
               (t (mapcar #'walk f)))))
    (walk form)))

(defun %ad-normalize-anf-for-backward (flat-anf)
  "Apply every backward-walk ANF normalization, in the one order that works.

     1. literal shape temps -> inlined       (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                    (%ad-canonicalize-wgmma)
     3. register ring VIEW extents~ -> literals
                                             (%ad-normalize-ring-view-extents)
     4. register-tile ring -> scratch ring   (%ad-canonicalize-register-rings)
     5. register-tile extents~ -> literals   (%ad-normalize-register-extents)

   NOTE: with-warp-specialization is NOT normalized here.  It has to be lowered before
   anf-transform runs (see the call to %ad-canonicalize-warp-specialization in
   src/macros.lisp), because ANF would otherwise hoist its role bodies out and lose the
   warp gating entirely — by the time this function sees flat-anf the damage is done.

   ORDER, and why each constraint is real:

   (1) FIRST, so every shape test below sees literals rather than ANF temps.  Only
       make-register-tile is on the ANF converter's opaque-argument list, so a wgmma
       accumulator's dims arrive as `(%ANF-T-1 (64 64))` and every shape map — which
       tests `(every #'integerp dims)` — would reject them.

   (3) MUST precede (4).  Once a register-tile ring has become a scratch ring it is
       indistinguishable from one the user actually wrote, and a genuine scratch ring's
       binding DOES survive into the backward, so its runtime extents~ must be preserved.
       Devirtualizing those would change specs that pass for the right reason (138, 145/18).

   (2) precedes (5) for the mirror-image reason: a wgmma accumulator is a make-register-tile
       by then, so it must be in the register-tile map that (5) builds.

   Returns FLAT-ANF structurally unchanged for any kernel using none of these forms."
  (let* ((inlined   (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (ringfixed (%ad-normalize-ring-view-extents
                     canonical
                     (%ad-register-ring-dims-map canonical)))
         (deringed  (%ad-canonicalize-register-rings ringfixed)))
    (%ad-normalize-register-extents deringed
                                    (%ad-register-tile-dims-map deringed))))

(defun %ad-ring-ctor-bindings (flat-anf)
  "Alist SYM -> CONSTRUCTOR for every ring binding in FLAT-ANF.

   Run on the CANONICALIZED anf, so register-tile rings have already become scratch
   matrix rings and only the scratch ring constructors need matching here."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                            "MAKE-SCRATCH-TENSOR-RING")
                          :test #'string=)
                  (not (assoc (first form) acc)))
         (push (cons (first form) (second form)) acc))))
    (nreverse acc)))

(defun %ad-form-mentions-p (form sym)
  "T if SYM occurs anywhere in FORM."
  (cond ((eq form sym) t)
        ((not (consp form)) nil)
        (t (some (lambda (f) (%ad-form-mentions-p f sym)) form))))

(defun %ad-ensure-ring-adj-bindings (backward flat-anf kernel-pkg)
  "Add a paired `<RING>_ADJ` binding to BACKWARD's outer LET for every ring the backward
   NAMES but does not BIND.

   Only rings actually mentioned get a binding, so a kernel whose backward never touches
   a ring is returned untouched.

   The adjoint is the forward ring's own constructor, used verbatim: a ring adjoint is a
   ring of identical shape, which is what makes `(ring-get R_ADJ i)` the adjoint of
   `(ring-get R i)` (see %tlc-bwd-adj-name).  Deliberately NOT routed through
   %mma-ad-adj-init -- its %promote-scratch-init-for-ad branch does not understand ring
   constructors and reduces them to the stub type `(TENSOR FLOAT)`.  No promotion is
   needed regardless: these rings are float already."
  (if (not (and (consp backward) (symbolp (first backward))
                (string-equal (symbol-name (first backward)) "LET")))
      backward
      (let* ((bindings (second backward))
             (bound (mapcar (lambda (b) (if (consp b) (first b) b)) bindings))
             (missing
              (loop for (sym . ctor) in (%ad-ring-ctor-bindings flat-anf)
                    for adj = (intern (format nil "~A_ADJ" (symbol-name sym))
                                      (or kernel-pkg (symbol-package sym)))
                    when (and (not (member adj bound))
                              (%ad-form-mentions-p (cddr backward) adj))
                      collect (list adj ctor))))
        (if (null missing)
            backward
            (list* (first backward)
                   (append missing bindings)
                   (cddr backward))))))


(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   Phase 1c: adds LOAD-TILE-AT / STORE-TILE-AT clauses to process-form
   that emit %load-tile-at-bwd / %store-tile-at-bwd with the correct
   adjoint symbols.  Also extends the LET case to auto-allocate paired
   <var>_ADJ scratch tensors for make-scratch-* bindings.

   Bug 032 fix: SET! on a local-scratch tile (target neither input nor
   output) now emits a proper consume + reset pair so the RHS chain rule
   propagates through tile mutations.

   Endeavor 146: FLAT-ANF is normalized before anything reads it, and the assembled
   backward gets one fixup on the way out.  See %ad-normalize-anf-for-backward for what
   the normalizations are and why their order matters, and %ad-ensure-ring-adj-bindings
   for the gap the fixup covers (the top-level adjoint collection below does not know the
   ring constructors, so a ring bound at kernel top level otherwise gets no adjoint)."
  (setf flat-anf (%ad-normalize-anf-for-backward flat-anf))
  (let ((*ad-barrier-ring-syms* (%ad-collect-barrier-ring-syms flat-anf))
        (*ad-view-alias-map*    (%ad-collect-view-aliases flat-anf)))
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
    (let ((*record-param-field-adjs* record-param-field-adjs-ht)
          ;; Endeavor 123 (FFI-AD): map each pointer temp bound via
          ;; (t (base-ptr~ src)) to its source storage sym, so a foreign call's
          ;; pointer arg can route its shadow to <src>_GRAD.
          (*ffi-baseptr-src*
           (let ((ht (make-hash-table :test 'eq)))
             (loop for form in flat-anf
                     when (and (consp form) (= (length form) 2)
                               (symbolp (car form))
                               (consp (cadr form)) (symbolp (caadr form))
                               (string-equal (symbol-name (caadr form)) "BASE-PTR~")
                               (symbolp (second (cadr form))))
                   do (setf (gethash (car form) ht) (second (cadr form))))
             ht)))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym in inputs
                     for typ in input-types
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
        ;; BUG 037: publish the staged-tile -> global-source map and the scratch-tile set so the
        ;; primal replay can read a staged tile's values from where they actually came from.
        (setf *ad-tile-src-map* (%mma-ad-tile-source-map flat-anf)
              *ad-scratch-syms* scratch-tile-syms)
        ;; Endeavor 124 C/A2: the adjoint-typing decision now lives in one place
        ;; (%ad-promotes-to-double-p / %ad-zero) shared with the sub-fn, FFI and
        ;; value-if/let paths.
        (flet ((promotes-to-double-p (t-spec) (%ad-promotes-to-double-p t-spec)))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (*ad-any-output-double* any-output-double)
                 (intermediate-zero (%ad-zero any-output-double)))
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
                                            (let* ((param-syms (getf hof-data :param-syms))
                                                   (fn-param-idx (getf hof-data :fn-param-idx))
                                                   (body-forms (getf hof-data :body-forms))
                                                   (fn-arg (nth fn-param-idx args))
                                                   (concrete-fn (cond
                                                                 ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                                   (cadr fn-arg))
                                                                 ((symbolp fn-arg) fn-arg)
                                                                 (t nil))))
                                              (unless concrete-fn
                                                (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                                              (let* ((fn-param (nth fn-param-idx param-syms))
                                                     (subst-alist
                                                      (loop for p in param-syms
                                                            for a in args
                                                            for i from 0
                                                              unless (= i fn-param-idx)
                                                            collect (cons p a)))
                                                     (subst-body (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                                     (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                                        subst-body))
                                                     (anf-body (mapcar #'anf-transform concrete-body))
                                                     (hof-flat (flatten-anf-body anf-body))
                                                     (hof-flat-norm
                                                      (let ((last-f (car (last hof-flat))))
                                                        (if (or (symbolp last-f)
                                                                (and (consp last-f) (eq (first last-f) 'return)))
                                                            hof-flat
                                                            (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                                   (symbol-package v))))
                                                              (append (butlast hof-flat)
                                                                (list (list ret-sym last-f) ret-sym))))))
                                                     (return-vars (%extract-return-vars hof-flat-norm)))
                                                (dolist (rv return-vars)
                                                  (setf (gethash rv adjoint-map) (local-adj v)))
                                                (dolist (hf-form (reverse hof-flat-norm))
                                                  (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                                        (let ((hv (car hf-form))
                                                              (hexpr (cadr hf-form)))
                                                          (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                                         :hof-handler-fn #'hof-inline-backward
                                                                                         :error-on-unknown t
                                                                                         :tensor-inputs-ht nil
                                                                                         :scratch-tile-syms scratch-tile-syms))))))))
                     (process-form (form emit-fn)
                       ;; VJP REGISTRY DISPATCH (see the registry block in this overlay).
                       ;; Runs BEFORE the hand-written clauses and DECLINES (NIL) when nothing
                       ;; applies, so an empty registry is provably a no-op and migration can
                       ;; proceed one primitive at a time.
                       (let* ((%vjp-binding (when (and (consp form) (= (length form) 2)
                                                       (symbolp (car form)) (consp (cadr form)))
                                              (car form)))
                              (%vjp-target (if %vjp-binding (cadr form) form))
                              (%vjp (%try-vjp %vjp-target
                                             (list :flat-anf flat-anf
                                                   :inputs inputs
                                                   :outputs outputs
                                                   :local-adj #'local-adj
                                                   :binding-var %vjp-binding
                                                   :kernel-pkg kernel-pkg))))
                        (if %vjp
                            (unless (eq %vjp :inert) (funcall emit-fn %vjp))
                            (cond
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "DECLARE")) nil)

                                    ;; Endeavor 145 P8: a tile load/store in VALUE position.
                                    ;; ANF binds a compound form to a temp whenever it sits in
                                    ;; value position — and the epilogue of
                                    ;; matrix-multiply-tile-stride ends with
                                    ;; `(store-tile C-tile C (grid-y grid-x))`, so a
                                    ;; multi-workgroup matmul reaches the walk as
                                    ;; `(%t (store-tile-at ...))` rather than a bare statement.
                                    ;; Every tile-load/store rule below matches only the
                                    ;; STATEMENT shape, so the binding fell through to
                                    ;; %handle-single-value-backward and errored with
                                    ;; "Function STORE-TILE-AT is not differentiable".
                                    ;; These forms are void — their "value" is meaningless — so
                                    ;; unwrap the temp and re-dispatch as the statement it is.
                                    ;; Fixes the register-tile AND scratch paths uniformly.
                                    ((and (consp form) (= (length form) 2) (symbolp (car form))
                                          (consp (cadr form)) (symbolp (caadr form))
                                          (member (symbol-name (caadr form))
                                                  ;; All VOID forms.  make-register-tile is
                                                  ;; deliberately absent — that one really is a
                                                  ;; value binding and must keep its temp.
                                                  '("STORE-TILE-AT" "LOAD-TILE-AT"
                                                    "STORE-TILE" "LOAD-TILE"
                                                    "MMA-ACCUMULATE-VIA-TILE" "STORE-FRAGMENT")
                                                  :test #'string=))
                                      (process-form (cadr form) emit-fn))

                                    ;; Endeavor 145 P3b: the tile-level MMA backward.
                                    ;; C-tile += A-tile . B-tile  =>  dA = dC.B^T, dB = A^T.dC.
                                    ;; Falls through to the old silent-drop only when the
                                    ;; shapes / staging sources are not compile-time
                                    ;; recoverable, so a kernel we cannot differentiate
                                    ;; correctly is never given a bogus gradient.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form))
                                                        "MMA-ACCUMULATE-VIA-TILE")
                                          (>= (length form) 5))
                                      (let ((bwd (%mma-via-tile-backward-logged
                                                  form
                                                  (%mma-ad-tile-dims-map flat-anf)
                                                  (%mma-ad-tile-source-map flat-anf)
                                                  inputs outputs #'local-adj kernel-pkg)))
                                        (when bwd (funcall emit-fn bwd))))

                                    ;; Phase 1c: load-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "LOAD-TILE-AT"))
                                      (let* ((src (second form))
                                             (tile (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (src-adj (%tlc-bwd-adj-name src inputs outputs
                                                                         #'local-adj kernel-pkg))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-TILE-AT-BWD"
                                                              (find-package :crisp-language)))
                                             (bwd-form (if transpose-v
                                                           (list bwd-sym src-adj tile-adj origins :transpose transpose-v)
                                                           (list bwd-sym src-adj tile-adj origins))))
                                        (funcall emit-fn bwd-form)))

                                    ;; Endeavor 145 P3b: a REGISTER-tile store.  Must be caught
                                    ;; BEFORE the scratch-tensor rule below, which would emit
                                    ;; %STORE-TILE-AT-BWD against an adjoint whose name is about
                                    ;; to be SROA-exploded away.  The backward of "write the
                                    ;; accumulator out to C" is "seed the accumulator's adjoint
                                    ;; from C_GRAD", fragment by fragment.  The origin coords are
                                    ;; unscaled first: the store-tile macro multiplied the tile-ID
                                    ;; by (~ (extents~ TILE) i), which is meaningless for a
                                    ;; register tile — the tile-ID inside is what we want.
                                    ((and (consp form) (symbolp (car form))
                                          (or (string-equal (symbol-name (car form)) "STORE-TILE-AT")
                                              (string-equal (symbol-name (car form)) "STORE-TILE"))
                                          (%mma-ad-register-tile-p (second form) flat-anf))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (mapcar #'%mma-ad-unscale-tile-origin
                                                              (fourth form)))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-REGISTER-TILE-ACC"
                                                              (find-package :crisp-language))))
                                        (log:debug "145 P3b register-tile store bwd: ~a <- ~a origins=~a"
                                                   tile-adj dest-adj origins)
                                        (funcall emit-fn (list bwd-sym tile-adj dest-adj origins))))

                                    ;; Phase 1c: store-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "STORE-TILE-AT"))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%STORE-TILE-AT-BWD"
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
                                          (or (string-equal (symbol-name (car form)) "DOTIMES")
                                              (string-equal (symbol-name (car form)) "DOTIMES+")))
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
                                    ;; the load/store-tile-at inner body's set!s after
                                    ;; workgroup-stride expansion) were silently dropped.
                                    ;; Desugar them to IF + PROGN here and let the IF case
                                    ;; handle the rest.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "WHEN"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        (process-form (list if-sym cond-form then 'nil) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "UNLESS"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        ;; (unless C B) = (if C nil B) — pass B as the else slot.
                                        (process-form (list if-sym cond-form 'nil then) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "PROGN"))
                                      (dolist (sub (reverse (cdr form)))
                                        (process-form sub emit-fn)))

                                    ;; Endeavor 123 (FFI-AD): a foreign function called as a
                                    ;; VOID STATEMENT (=> nil), e.g. (c_vsin n inptr outptr).
                                    ;; It is not a value binding, so it must be recognized by
                                    ;; its head being a registered foreign function — otherwise
                                    ;; it is misparsed as a multi-value binding below and
                                    ;; silently dropped. There is no return seed (void).
                                    ((and (consp form) (symbolp (car form))
                                          (let ((info (gethash (car form) *differentiable-functions*)))
                                            (and info (getf info :foreign))))
                                      (%emit-foreign-backward (car form) (cdr form) nil
                                                              (symbol-package (car form))
                                                              emit-fn #'local-adj))

                                    ;; BUG 038: an ordinary differentiable SUB-FUNCTION called as
                                    ;; a VOID STATEMENT, e.g. (stage A tile) or (scale_into A C).
                                    ;; Endeavor 123 added the clause above for the FOREIGN case
                                    ;; and for exactly this reason; the non-foreign case never
                                    ;; got one, so such a call fell through to the multi-value
                                    ;; BINDING clause below — `(STAGE A TILE)` is length 3 with an
                                    ;; all-symbol butlast, so that clause read STAGE and A as
                                    ;; bound variables and TILE as the producing expression.  TILE
                                    ;; is a symbol rather than a cons, so its body never ran and
                                    ;; the call was SILENTLY DROPPED — no gradient flowed through
                                    ;; the sub-function at all (137/04's backward had zero global
                                    ;; writes).  Statements and multi-value bindings are
                                    ;; indistinguishable by shape after ANF, which is the same
                                    ;; trap as the 145 P1 replay bug.
                                    ;;
                                    ;; Void, so there is no return seed: t-adj-forms is NIL, as in
                                    ;; the foreign case.  Handle (tensor) contributions are routed
                                    ;; by %emit-sub-fn-backward through the callee's &out
                                    ;; grad-handles, so the chain rule lands inside the sub-fn.
                                    ;; A binding never matches here: its CAR is the bound temp,
                                    ;; not a registered function.
                                    ;; The second disjunct matters: a sub-function whose companion
                                    ;; could not be built has been UNREGISTERED, so the gethash
                                    ;; alone would miss it and the call would be dropped exactly
                                    ;; as before.  A retained body is sufficient on its own.
                                    ((and (consp form) (symbolp (car form))
                                          (or (let ((info (gethash (car form) *differentiable-functions*)))
                                                (and info (not (getf info :foreign))))
                                              (%ad-sub-fn-inlinable-p (car form))))
                                      (let* ((fn (car form))
                                             (info (gethash fn *differentiable-functions*)))
                                        (log:debug "038: void sub-fn call backward for ~a" fn)
                                        ;; Prefer INLINING the callee's body: it needs no
                                        ;; companion, so it is immune to every way companion
                                        ;; generation can quietly decline, and it gives the
                                        ;; body's statements (load-tile above all) the same
                                        ;; treatment they would get in a kernel.  Fall back to
                                        ;; the companion when there is no body to inline —
                                        ;; notably FFI, and recursion.
                                        (unless (%ad-inline-sub-fn-backward fn (cdr form)
                                                                            emit-fn #'process-form)
                                          (%emit-sub-fn-backward fn (cdr form)
                                                                 (getf info :bkwd-name)
                                                                 nil
                                                                 (getf info :n-float-params)
                                                                 (symbol-package fn)
                                                                 emit-fn #'local-adj "BW"))))

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
                                             (expr (car (last form))))
                                        (when (and (consp expr)
                                                   (symbolp (car expr))
                                                   (gethash (car expr) *differentiable-functions*))
                                              (let* ((fn (car expr))
                                                     (args (cdr expr))
                                                     (info (gethash fn *differentiable-functions*))
                                                     (bkwd (getf info :bkwd-name))
                                                     (n-fp (getf info :n-float-params))
                                                     (pkg (symbol-package (car result-vars)))
                                                     (t-adjs (mapcar #'local-adj result-vars)))
                                                ;; Endeavor 123 (FFI-AD): foreign multi-return
                                                ;; routes through the shadow-aware emitter.
                                                (if (getf info :foreign)
                                                    (%emit-foreign-backward fn args t-adjs pkg
                                                                            emit-fn #'local-adj)
                                                    (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                                           emit-fn #'local-adj "BW"))))))

                                    (t nil))))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
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
                        ;; Endeavor 124 (AD issues) C: under any-output-double the
                        ;; adjoint runs in double, but a float/small-int input's grad
                        ;; cell is float — down-cast at the write to match the cell.
                        (let ((write-val
                               (if (and any-output-double
                                        (not (promotes-to-double-p in-type))
                                        (or is-cell-input is-scalar-wrapped))
                                   `(to-float ,(local-adj in))
                                   (local-adj in))))
                          (cond
                           (is-tensor-input nil)
                           (is-cell-input (emit `(set! (~ ,in-grad) ,write-val)))
                           (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,write-val)))
                           (t (emit `(set! ,in-grad ,write-val)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          ;; Endeavor 124 (AD issues) C: when ANY output promotes to
                          ;; double, the whole backward chain runs in double — INCLUDING
                          ;; float-input adjoints — so the adjoint accumulations don't mix
                          ;; float and double. The narrower grad cell is reconciled by a
                          ;; down-cast at the grad-cell write below.
                          (cond
                           (in-type
                             (%ad-zero (or (promotes-to-double-p in-type) any-output-double)))
                           (any-output-double (%ad-zero t))
                           (t (%ad-zero nil))))))
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
                                                                        "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                                                                        "MAKE-REGISTER-TILE")
                                                :test #'string=))
                            collect (let* ((var (car form))
                                           (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                                            (or kernel-pkg (symbol-package var)))))
                                      (list var-adj (%mma-ad-adj-init (cadr form))))))
                     (result `(let ,(append scratch-adj-bindings local-bindings)
                                ,@(nreverse backward-forms))))
                (log:debug "145: assembled backward AST:~%~s" result)
                ;; Endeavor 146: bind any ring adjoint the walk NAMED but did not BIND.
                ;; FLAT-ANF here is the normalized anf (see the setf at the top), so ring
                ;; constructors are already in their canonical scratch-ring form.
                (let ((final (%ad-ensure-ring-adj-bindings result flat-anf kernel-pkg)))
                  (log:debug "146: backward after ring-adjoint fixup:~%~s" final)
                  final))))))))))

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
       (let* ((op-name (symbol-name (first form)))
              (field-name (intern (subseq op-name 1 (1- (length op-name)))
                                  (symbol-package (first form))))
              (arg (second form))
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
       (let* ((op (first form))
              (op-name (symbol-name op))
              (field-name (intern (subseq op-name 0 (1- (length op-name)))
                                  (symbol-package op)))
              (arg (second form))
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
  (let ((flat-inputs '())
        (flat-input-types '())
        (reassembly-bindings '())
        (grad-out-params '())
        (grad-out-types '())
        (record-subs-ht (make-hash-table :test 'eq))
        (record-type-ht (make-hash-table :test 'eq))
        (grad-cell-syms '())
        (struct-shadow-info '()))
    (labels
        ((explode (p t-spec)
                  "Destructure parameter P of type T-SPEC.  Side effects push to
            the closure-captured accumulators.  Returns no useful value."
                  (cond
                   ((%crisp-record-type-p t-spec)
                     (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                            (fields (%get-record-runtime-fields t-spec))
                            (make-sym (intern (format nil "MAKE-~a" (symbol-name base-type)) pkg))
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
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.

   Endeavor 145 P1: INNER-DIMENSION / OUTER-DIMENSIONS are gradient-inert shape queries.
   Endeavor 145 P3b: MAKE-REGISTER-TILE is an ALLOCATOR, gradient-inert like the
   make-scratch-* constructors above it — its paired adjoint tile is created by
   %mma-ad-adj-init, not by the walk.

   Endeavor 138 rings: the SCRATCH-RING constructors are allocators exactly as their non-ring
   forms are (a ring is rank+1 scratch), and their paired adjoint rings likewise come from
   %augment-scratch-adj-bindings.  The BARRIER ring is inert for a different reason: a barrier
   carries no value, only ordering.  Without these, 138/03 and 138/06 failed with

       Function MAKE-ASYNC-BARRIER-RING is not differentiable.  Wrap the kernel in
       'forward-only' if differentiation is not needed...

   which points away from the fix — the kernel IS differentiable; a scheduling object simply has
   no gradient.  MAKE-ASYNC-BARRIER is listed alongside it: the plain barrier only avoided this
   by never reaching the walk as a call, which is luck rather than design.

   Endeavor 146 Gap 2: MOD is GONE from this list, and REM never joined it.  138 put MOD here
   as \"INDEX arithmetic\" with a caveat admitting the treatment was wrong for floats — a float
   mod has derivative 1 almost everywhere, so a mod in a value position got a silent ZERO.
   Both now have real rules in %handle-math-and-trig-backward instead.

   The general point, since this list attracts shortcuts: an entry here is a claim about an
   OPERATOR, namely that it produces no value a gradient could flow through.  That is true of
   allocators, barriers and shape queries — genuine non-values.  It was never true of rem/mod.
   What actually made `(mod grid-k 2)` contribute nothing is that its OPERAND is inactive, and
   %active-scalar-vars already determines that on its own without anyone declaring anything."
  (or (let ((name (symbol-name fn-sym)))
        (member name '("MAKE-REGISTER-TILE"
                       "MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                       "MAKE-SCRATCH-TENSOR-RING"
                       "MAKE-ASYNC-BARRIER" "MAKE-ASYNC-BARRIER-RING")
                :test #'string=))
      (%backward-skip-fn-p-145p1 fn-sym)))

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

(defun %collect-all-diff-param-syms-for-return (env record-param-info &optional active-set)
  "Full ordered list of 'differentiable param syms' used for emitting the multi-value
   return. ACTIVE-SET (A2) gates integer scalar params: an int is included only when
   active (differentiably reaches the return)."
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
                        ((> (%count-active-contributions (parameter-def-type pd) sym active-set) 0)
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
         (clean-body (loop for f in body-forms
                             unless (and (atom f) (not (symbolp f)))
                           collect f)))
    (log:info "AUTODIFF: ~a is HOF — storing for inline backward" name)
    (setf (gethash name *differentiable-hof-store*)
      (list :param-syms (loop for pd in env collect (parameter-def-name pd))
            :fn-param-idx fn-param-idx
            :fn-param-sym fn-param-sym
            :float-param-syms float-param-syms
            :body-forms clean-body))
    (setf (gethash name *differentiable-functions*)
      (list :hof t
            :n-float-params (length float-param-syms)
            :n-return n-return))
    nil))

(defun %generate-backward-companion-ast-body (name params env declarations body-forms pkg n-float-params n-return
                                                   return-types-non-void record-param-info record-param-field-adjs-ht
                                                   all-diff-param-syms-for-return)
  "Generate backward companion def-function AST body."
  (declare (ignore declarations record-param-info))
  (let* ((bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
         (t-grad-syms (loop for i from 0 below n-return
                            collect (intern (format nil "T_GRAD~A" i) pkg)))
         (orig-param-types (mapcar #'parameter-def-type env))
         (t-grad-types (mapcar (lambda (t-spec) (%promote-to-float-adjoint t-spec))
                           return-types-non-void))
         ;; A2/C: does this sub-fn's adjoint chain run in double? (any param or
         ;; return promotes to double: long / ulong / double).
         (any-double (or (some #'%ad-promotes-to-double-p orig-param-types)
                         (some #'%ad-promotes-to-double-p return-types-non-void)))
         ;; A2/C: the returned-gradient slot type per active param, in order —
         ;; double for a ulong/long param, float otherwise. (Record-field-adj syms
         ;; that are not params keep the float default.)
         (return-adj-types
          (loop for sym in all-diff-param-syms-for-return
                for pd = (find sym env :key #'parameter-def-name)
                collect (if pd (%ad-scalar-adjoint-type (parameter-def-type pd)) 'float)))
         (tensor-param-info (%collect-tensor-param-info env pkg))
         (tensor-grad-out-syms (mapcar #'third tensor-param-info))
         (tensor-grad-out-types (mapcar #'fourth tensor-param-info))
         (out-marker (intern "&OUT" :crisp-language))
         (bkwd-params (append params t-grad-syms
                        (when tensor-param-info (cons out-marker tensor-grad-out-syms))))
         (bkwd-fn-spec
          `(function (,@orig-param-types ,@t-grad-types
                        ,@(when tensor-param-info (cons out-marker tensor-grad-out-types))
                        => ,@return-adj-types))))

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
        (let* ((anf-body (mapcar #'anf-transform body-forms))
               (raw-flat (flatten-anf-body anf-body))
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
                   tensor-inputs-ht any-double return-adj-types))))
          `(def-function ,bkwd-name ,bkwd-params
                         (declare #'(,@(second bkwd-fn-spec)))
                         ,bkwd-body))

      (error (e)
        (log:info "AUTODIFF: ~a — cannot generate _GRAD: ~a. Unregistering; will error if called from a differentiable kernel." name e)
        (remhash name *differentiable-functions*)
        nil))))



(defun %generate-backward-function-ast (name params declarations body-forms)
  "Generates the backward companion (def-function NAME_GRAD ...) for a differentiable user
   function.

   BUG 038: additionally RETAINS the callee's parameter symbols and body in
   *differentiable-hof-store*, so the backward walk can inline it at a call site instead of
   calling a companion.  Stored for every differentiable def-function, not just HOFs, and stored
   BEFORE the gradient-inert early return — a function can be inline-differentiable even when it
   has no companion, which is exactly the 137/04 case.  Reusing the HOF store rather than adding
   a global keeps it on the existing initialize-compiler clrhash, so a body cannot leak between
   two specs compiled in the same image (run-specs runs in-process).  The HOF reader is not
   disturbed: it is only reached when *differentiable-functions* says :hof t."
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
             (active-set (%active-scalar-param-set (mapcar #'parameter-def-name env) body-forms))
             (all-diff-param-syms-for-return
              (%collect-all-diff-param-syms-for-return env record-param-info active-set))
             (record-param-field-adjs-ht (%build-record-param-field-adjs-ht record-param-info))
             (n-float-params
              (loop for pd in env
                      when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                      sum (%count-active-contributions (parameter-def-type pd)
                                                       (parameter-def-name pd) active-set)))
             (return-types-non-void (remove nil return-types))
             (n-return (length return-types-non-void))
             (fn-param-entries
              (loop for pd in env for i from 0
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-function-type-p (parameter-def-type pd)))
                    collect (cons i pd)))
             (is-hof (consp fn-param-entries)))

        ;; BUG 038: retain the body for inline differentiation.  Cheap, additive, and done
        ;; before any early return.  &OUT is a marker in the parameter list rather than a
        ;; parameter, so it is dropped to keep :param-syms positionally aligned with the call
        ;; arguments the walk will substitute.
        (unless is-hof
          (setf (gethash name *differentiable-hof-store*)
                (list :param-syms (loop for pd in env
                                          unless (string-equal (symbol-name (parameter-def-name pd)) "&OUT")
                                        collect (parameter-def-name pd))
                      :body-forms body-forms
                      :inlinable t))
          (log:debug "038: retained body of ~a for inline backward (~a forms)" name (length body-forms)))

        (when (and (zerop n-float-params)
                   (not (%has-tensor-diff-param-p env)))
              (log:info "AUTODIFF: ~a has no differentiable params — skipping _GRAD generation (marking gradient-inert)." name)
              (setf (gethash name *inert-functions*) t)
              (return-from %generate-backward-function-ast nil))

        (if is-hof
            (%register-hof-differentiable-function name env float-param-syms fn-param-entries n-return body-forms)
            (%generate-backward-companion-ast-body name params env declarations body-forms pkg n-float-params n-return
                                                   return-types-non-void record-param-info record-param-field-adjs-ht all-diff-param-syms-for-return))))))


(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars
                                                  &optional tensor-inputs-ht any-double return-adj-types)
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
        (return-var-seeds (make-hash-table :test 'eq))
        ;; A2/C: expose the double-chain flag to value-if/let inside the body.
        (*ad-any-output-double* any-double))

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
             (let ((v (car form))
                   (expr (cadr form)))
               (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                              :error-on-unknown t
                                              :tensor-inputs-ht tensor-inputs-ht)))
           ((and (listp form) (>= (length form) 3)
                 (symbolp (car form))
                 (every #'symbolp (butlast form)))
             (let* ((result-vars (butlast form))
                    (expr (car (last form))))
               (when (and (consp expr)
                          (symbolp (car expr))
                          (gethash (car expr) *differentiable-functions*))
                     (let* ((fn (car expr))
                            (args (cdr expr))
                            (info (gethash fn *differentiable-functions*))
                            (bkwd-fn (getf info :bkwd-name))
                            (n-fp (getf info :n-float-params))
                            (n-ret (getf info :n-return))
                            (pkg (symbol-package fn)))
                       (declare (ignore n-ret))
                       (%emit-sub-fn-backward fn args bkwd-fn (mapcar #'local-adj result-vars) n-fp pkg #'emit #'local-adj "MV")))))
           (t nil))))

      ;; A2/C: return each active-param adjoint in its declared adjoint slot type.
      ;; Under a double chain (any-double) a param adjoint runs in double; if its
      ;; return slot is float (e.g. a float param in a mixed sub-fn), down-cast.
      (emit `(return
              ,@(loop for sym in float-param-syms
                      for slot in (or return-adj-types
                                      (make-list (length float-param-syms) :initial-element 'float))
                      collect (if (and any-double (eq slot 'float))
                                  `(to-float ,(local-adj sym))
                                  (local-adj sym)))))

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
                              ;; A2/C: non-seed adjoints init to the typed zero
                              ;; (double under a double chain); seeds carry their
                              ;; already-promoted t_grad type.
                              `(,adv ,(if seed seed (%ad-zero any-double))))))
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
     (let* ((fn-arg (cadr form))
            (call-args (mapcar (lambda (a) (%remove-funcall a fn-param-sym concrete-fn-sym))
                           (cddr form)))
            (resolved (cond
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
             (elem (second canonical))
             (info (gethash elem *crisp-types*))
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
             (elem (second canonical))
             (addr (nth 2 canonical))
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
   ((%crisp-integer-cell-type-p type-spec) (%integer-cell-elem-to-float type-spec))
   ((%crisp-integer-scalar-type-p type-spec) (%integer-scalar-to-float-scalar type-spec))
   (t type-spec)))

;;; ===================================================================
;;; Endeavor 124 (AD issues) C/A2 — the ONE source of truth for adjoint typing.
;;;
;;; An adjoint's type is %promote-to-float-adjoint of the value it shadows:
;;; float/small-int -> float, double/long/ulong -> DOUBLE. These two helpers
;;; centralize that decision (and the typed zero-init) so every backward site —
;;; the kernel walk, the sub-function walk, the FFI VJP path, and the value-if/let
;;; branch handlers — shares one rule instead of hardcoding 0.0 / 'float.
;;; ===================================================================

(defun %ad-promotes-to-double-p (type-spec)
  "T if the ADJOINT of a value of TYPE-SPEC is DOUBLE (double / long / ulong, or a
   cell/tensor thereof). Canonicalizes first, because %promote-to-float-adjoint
   leaves a non-integer type ALIAS unresolved (e.g. a (cell double) alias)."
  (let* ((promoted (%promote-to-float-adjoint type-spec))
         (canon (or (ignore-errors (canonicalize-type-specifier promoted)) promoted)))
    (or (eq promoted 'double)                    ; bare scalar double (e.g. ulong/long param)
        (eq canon 'double)
        (and (consp canon) (eq (second canon) 'double)))))

(defun %ad-zero (double-p)
  "The typed zero literal for a fresh adjoint accumulator: (as double 0.0) when
   DOUBLE-P, else 0.0."
  (if double-p '(as double 0.0) 0.0))

(defun %ad-scalar-adjoint-type (type-spec)
  "The SCALAR adjoint type ('float or 'double) for a scalar value of TYPE-SPEC."
  (if (%ad-promotes-to-double-p type-spec) 'double 'float))

(defvar *ad-any-output-double* nil
  "Dynamically bound (by the kernel walk and the sub-function walk) to T when the
   backward chain runs in double — any output/param/return promotes to double. Read
   by the value-if/let and FFI paths so their fresh adjoints get the typed zero
   (%ad-zero) too, without threading the flag through every call.")


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

;;; ===================================================================
;;; Endeavor 124 (AD issues) A2 — activity analysis for integer sub-fn params.
;;;
;;; Integer scalar sub-function params are gradient-inert by default (the sub-fn
;;; multi-value-return ABI counts float=1, int=0). Crisp differentiates integers
;;; at the KERNEL boundary but the rule was never ported to the sub-fn boundary.
;;; A blanket "count ints as 1" corrupts STRUCTURAL ints (indices / tensor
;;; metadata / tile descriptors in generated functions). So we count an int param
;;; only when it is ACTIVE — it differentiably reaches the function's return value.
;;;
;;; %active-scalar-vars is a lightweight backward-reachability pass over the SOURCE
;;; body (pure syntax — no types/semantic tree). Per-op EDGE TABLE decides which
;;; operand positions propagate activeness (the index of ~, the condition of if,
;;; and comparison results do NOT). Structural ints fall out as "inactive" for
;;; free — no special-casing.
;;; ===================================================================

(defun %asv-union (exprs env)
  "Union of %active-scalar-vars over EXPRS."
  (let ((acc nil))
    (dolist (e exprs acc)
      (setf acc (union acc (%active-scalar-vars e env) :test #'eq)))))

(defun %active-scalar-vars (expr env)
  "Set (list) of scalar symbols that DIFFERENTIABLY affect EXPR's value. ENV is an
   alist mapping a let-bound symbol to its own active-scalar-var set."
  (cond
   ((symbolp expr) (let ((e (assoc expr env))) (if e (cdr e) (list expr))))
   ((not (consp expr)) nil)                         ; numbers / other atoms
   (t
     (let ((name (and (symbolp (car expr)) (symbol-name (car expr)))))
       (cond
        ((null name) nil)
        ;; differentiable arithmetic — every operand propagates.
        ;; Endeavor 146 Gap 2: REM and MOD belong here, not in a skip list.  d(rem)/da = 1
        ;; and d(rem)/db = -trunc(a/b), so BOTH positions genuinely carry activeness.  An
        ;; integer index expression like (rem li 8) still contributes nothing, because `li`
        ;; is inactive — which is exactly the "structural ints fall out as inactive for
        ;; free" property this table is built on.
        ((member name '("+" "-" "*" "/" "REM" "MOD") :test #'string-equal)
          (%asv-union (cdr expr) env))
        ;; Endeavor 128: unary transcendentals propagate through their single arg.
        ((member name '("SIN" "COS" "SQRT" "EXP" "LOG" "LOG2" "TAN"
                        "ASIN" "ACOS" "ATAN" "TANH" "ABS") :test #'string-equal)
          (%active-scalar-vars (cadr expr) env))
        ;; Endeavor 128: binary transcendentals — both operands propagate.
        ((member name '("POW" "ATAN2") :test #'string-equal)
          (%asv-union (cdr expr) env))
        ;; numeric conversions propagate (conservative).
        ((and (>= (length name) 3) (string-equal (subseq name 0 3) "TO-"))
          (%active-scalar-vars (cadr expr) env))
        ;; tensor/cell read: no SCALAR activity (the index does not propagate; the
        ;; tensor/cell itself flows grad via its own &out grad-handle).
        ((string-equal name "~") nil)
        ;; comparisons: 0 gradient — nothing propagates.
        ((member name '("<" ">" "<=" ">=" "=" "/=") :test #'string-equal) nil)
        ;; conditionals: the branches propagate, the CONDITION does not.
        ((member name '("IF" "IF+") :test #'string-equal)
          (union (%active-scalar-vars (caddr expr) env)
                 (%active-scalar-vars (cadddr expr) env) :test #'eq))
        ((member name '("WHEN" "WHEN+" "UNLESS" "UNLESS+") :test #'string-equal)
          (%active-scalar-vars (caddr expr) env))
        ;; let: bind each var to its init's active set, then evaluate the body.
        ((string-equal name "LET")
          (let ((new-env env))
            (dolist (b (cadr expr))
              (when (and (consp b) (= (length b) 2) (symbolp (car b)))
                    (push (cons (car b) (%active-scalar-vars (cadr b) new-env)) new-env)))
            (%active-scalar-vars (car (last (cddr expr))) new-env)))
        ((string-equal name "RETURN") (%asv-union (cdr expr) env))
        ((string-equal name "PROGN") (%active-scalar-vars (car (last (cdr expr))) env))
        ;; sub-fn / other call: over-approximate — all args propagate. Safe (a
        ;; spuriously-active int just gets a 0-gradient slot); never runs on the
        ;; generated structural-int machinery (this pass is source-only).
        (t (%asv-union (cdr expr) env)))))))

(defun %active-scalar-param-set (params body-forms)
  "Subset of PARAMS (symbols) that are ACTIVE — differentiably affect the value of
   BODY-FORMS' final form (the function's return)."
  (when body-forms
    (intersection params (%active-scalar-vars (car (last body-forms)) nil) :test #'eq)))

(defun %count-active-contributions (pd-type sym active-set &optional record-info)
  "Like %count-differentiable-contributions, but an INTEGER scalar param counts 1
   only when SYM is in ACTIVE-SET (A2 activity analysis). Float / tensor / cell /
   record behavior is unchanged — this only ADDS active-int contributions."
  (let ((base (%count-differentiable-contributions pd-type record-info)))
    (if (and (zerop base)
             (%crisp-integer-scalar-type-p pd-type)
             (member sym active-set :test #'eq))
        1
        base)))

;;; ======================================================================
;;; BUG 038 — gradients through a VOID SUB-FUNCTION call, by INLINING.
;;;
;;; 137/04's kernel copies a 4x4 tile of A into C through a staging sub-function.  That is the
;;; identity, dA = dC, and there is nothing in it that is not differentiable — yet it returned a
;;; gradient of exactly 0.0.  Three separate silent failures stacked on the one call; see
;;; tests/spec/145-mma-autodiff/17-void-subfn-vjp-bmg.crisp for the full account.
;;;
;;; THE SHAPE OF THE FIX.  Endeavor 111 Phase 1c already put the AD splice in the right place:
;;; `load-tile-at` -> %load-tile-at-bwd and `store-tile-at` -> %store-tile-at-bwd.  The kernel's
;;; `store-tile` already produced its backward edge.  The ONLY missing edge was the `load-tile`
;;; hidden inside the sub-function, which the walk never saw.  So rather than repair the _GRAD
;;; companion path, we stop needing it: INLINE the callee's body at the call site and walk it
;;; with the ordinary statement walker.  Every per-construct rule then applies inside a
;;; sub-function exactly as it does inside a kernel, automatically and for all of them.
;;;
;;; This is the endeavor-145 lesson applied again: the previous design derived a sub-function's
;;; backward THROUGH one chosen realisation (generate a companion, thread grad-outs through its
;;; &out params, call it), and that realisation's requirements — a recognisable tensor param
;;; type, a well-formed companion, correct tensor-param indices — became de-facto conditions for
;;; a gradient existing at all.  They are conditions on the LOWERING, not on the derivative.
;;; Inlining needs none of them.  The companion path is KEPT as the fallback: it is still the
;;; right lowering for scalar math sub-functions (one copy of the code, not one per call site)
;;; and it is MANDATORY for FFI, where there is no body to inline.
;;; ======================================================================
(defun %crisp-tensor-param-type-p (pd-type)
  "Returns T if PD-TYPE is a tensor (float-element or integer-element) at the sub-function
   level.  Used to decide whether a sub-fn param contributes a tensor grad-out (vs a scalar
   delta).

   Handles four forms:
   - List form: (tensor float 1 ...) — caught by the existing helpers.
   - Mangled-template-name symbol: TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST — produced by Crisp's
     template instantiation.  Detected by name prefix.
   - Plain symbol naming a registered tensor type.
   - BUG 038: a user `def-type` ALIAS of a tensor/vector/matrix type.  The docstring always
     claimed the third case was handled, but nothing resolved aliases, so

         (def-type mat-t (matrix float ...))
         (def-function stage (src tile) (declare #'(mat-t tile-t => ulong)) ...)

     looked like a function with NO differentiable parameters at all.  %generate-backward-
     function-ast then took its `(zerop n-float-params)` early return, which does not merely skip
     the companion — it marks the function gradient-INERT, so calls to it are skipped in the
     backward walk deliberately and silently, as a documented zero.  Aliasing a parameter type is
     not a semantic change, so it must not be an AD-visible one.  %is-tensor-alias already
     existed for precisely this question."
  (or (%crisp-float-tensor-type-p pd-type)
      (%crisp-integer-tensor-type-p pd-type)
      (and (symbolp pd-type)
           (let ((name (symbol-name pd-type)))
             (and (>= (length name) 7)
                  (string-equal "TENSOR_" (subseq name 0 7)))))
      (%is-tensor-alias pd-type)))

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
            (base (brand-definition-base-type brand)))
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

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P1: gradient-inert shape queries.
;;;
;;; An MMA kernel does not fail to differentiate at the MMA — it fails at the SHAPE
;;; QUERY, well before it gets there.  132/06-tiled-matmul dies with
;;;   "Function INNER-DIMENSION is not differentiable"
;;; on its very first binding.
;;;
;;; `inner-dimension` and `outer-dimensions` read K / M / N out of the operands'
;;; extents.  They depend on the matrices' SHAPE, never on their VALUES, so their
;;; gradient contribution is identically zero — exactly like extents~ / strides~ /
;;; num-rows, which are already skipped.
;;;
;;; The two forms fail DIFFERENTLY, and the difference is the whole of P1:
;;;
;;;   inner-dimension  -> single-value binding.  The backward WALK rejects it.
;;;                       Fix: %backward-skip-fn-p.
;;;   outer-dimensions -> MULTI-value binding.  The walk already ignores it
;;;                       correctly, but the backward kernel's primal REPLAY drops
;;;                       it, so the bound vars are unbound in the backward body
;;;                       ("Unknown variable M").
;;;                       Fix: %collect-forward-primal-bindings, called from
;;;                       %generate-backward-kernel-ast.
;;;
;;; Specs: tests/spec/145-mma-autodiff/01-inner-dimension-inert.crisp
;;;        tests/spec/145-mma-autodiff/02-outer-dimensions-inert.crisp
;;; ===================================================================

;; NOTE (145 P3b): this is the P1 body, renamed so the final %backward-skip-fn-p (further
;; down, which adds MAKE-REGISTER-TILE) can delegate to it instead of duplicating the list.
;; When folding back into src/, merge the two into one definition.
(defun %backward-skip-fn-p-145p1 (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.

   Endeavor 145 P1: INNER-DIMENSION / OUTER-DIMENSIONS join the gradient-inert shape
   queries.  Both are pure reads of a tensor's extents — `(inner-dimension A B)` is K,
   `(outer-dimensions A B)` is (values M N) — so they carry no value dependence and
   contribute exactly zero gradient, like EXTENTS~ / STRIDES~ / NUM-ROWS above them.
   Their forward values remain available to the backward via the primal replay in
   %generate-backward-kernel-ast."
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
                                        ;; 123 (FFI-AD): handle constructor / deref and the
                                        ;; pointer/handle TYPE constructors are gradient-inert.
                                        ;; (base-ptr~ is handled by the accessor path; FFI
                                        ;; buffer gradients flow via shadow pointers routed in
                                        ;; %emit-foreign-backward.)
                                        "MAKE-C-HANDLE" "GET-POINTER" "C-POINTER" "C-HANDLE"
                                        "TRANSPOSE" "TRANSPOSE!" "ROW" "COL" "SLICE"
                                        ;; 145 P1 (MMA autodiff): the MMA shape queries are pure
                                        ;; extent reads — zero value dependence, zero gradient.
                                        "INNER-DIMENSION" "OUTER-DIMENSIONS"
                                        "GET-GLOBAL-ID" "GET-LOCAL-ID" "GET-WORKGROUP-ID"
                                        "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                                        "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET"
                                        "GET-GLOBAL-ID-ABS" "GET-WORK-DIM"
                                        "GET-LOCAL-LINEAR-ID" "GET-LOCAL-LINEAR-SIZE"
                                        "GET-GLOBAL-LINEAR-ID" "GET-GLOBAL-LINEAR-SIZE"
                                        "GET-TOTAL-THREADS" "GET-TOTAL-GROUPS"
                                        "SYNC-WORKGROUP" "SYNC-WARP" "MEM-FENCE"
                                        ;; Endeavor 146: the WARP builtins are thread
                                        ;; coordinates exactly as GET-LOCAL-ID is — structural,
                                        ;; not functions of the kernel's inputs, so their
                                        ;; derivative is EXACTLY zero.  They arrived with the
                                        ;; 111/115 warp work and were simply never added here,
                                        ;; which is the whole reason a warp-specialised kernel
                                        ;; could not even stage its operands under AD
                                        ;; ("Function WARP-LANE is not differentiable").
                                        "WARP-ID" "WARP-LANE" "WARP-COUNT")
               when (prefix-or-mangled-p prefix) return t)))))

(defun %mma-ad-prelower-mmts (form)
  "Endeavor 145 P8: pre-lower matrix-multiply-tile-stride ahead of the AD pre-pass.
   When FORM is a LET, its bindings supply the register-tile dims map first."
  (if (and (consp form) (symbolp (car form))
           (member (symbol-name (car form)) '("LET" "LET*") :test #'string=)
           (listp (second form)))
      (let ((reg-map (%mmts-register-dims-map (second form))))
        `(,(first form) ,(second form)
          ,@(mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) (cddr form))))
      (%mma-ad-expand-mmts-in-form form nil)))

;;; ===================================================================
;;; Endeavor 145 (MMA autodiff) — P3b: the tile-level backward rule.
;;;
;;; C-tile += A-tile . B-tile   =>   dA = dC . B^T   and   dB = A^T . dC
;;;
;;; Both backward GEMMs need one TRANSPOSED operand and the orientation is forced — the
;;; "transpose the output instead" reformulation fails the shape check on Intel (dA^T =
;;; B.dC^T is (Kt, Mt, Nt) and Mt=8 < N_n=16).  Rather than depend on ColumnMajor
;;; cooperative loads (BUG 035: :col-major is silently ignored on SPV), the transposed
;;; operands are STAGED into SLM explicitly, so every operand read is row-major and the
;;; emission is backend-neutral.
;;;
;;; A subtlety that shapes the whole design: the backward kernel replays the forward's
;;; BINDINGS but not its STATEMENTS, so the staged primal tiles (filled by load-tile-at)
;;; are EMPTY in the backward.  That would be fatal — dA needs B and dB needs A — except
;;; that both GEMMs need only the TRANSPOSES.  So the backward never reconstructs the
;;; primal tiles at all: it stages the transposes straight from the ORIGINAL GLOBAL source,
;;; recovered from the forward's load-tile-at forms.  Its origin expression is replayed
;;; verbatim, so a loop-dependent origin like (* kt 16) still resolves against the
;;; backward's own loop variable.
;;; ===================================================================
(defun %mma-ad-walk-forms (tree fn)
  "Endeavor 145 P3b: apply FN to every cons subform of TREE, outermost first.

   The tile maps below MUST see the whole tree, not just the top level of flat-anf.
   `flatten-anf-body` flattens LET and PROGN but leaves a DOTIMES / IF / WHEN body NESTED —
   so in a K-looped matmul (the realistic shape) the load-tile-at forms live inside the loop
   and a top-level-only scan finds nothing."
  (labels ((walk (x)
             (when (consp x)
               (funcall fn x)
               (dolist (sub x) (walk sub)))))
    (walk tree)))

(defun %mma-ad-tile-source-map (flat-anf)
  "Endeavor 145 P3b: alist TILE-SYM -> (GLOBAL-SRC ORIGIN-FORMS) for every
   `(load-tile-at SRC TILE (ORIGIN...))` anywhere in FLAT-ANF.

   This is what lets the backward stage a TRANSPOSED operand without reconstructing the
   forward's staging: it reads the original global matrix at the same origin.  The origin
   forms are carried through verbatim, so a loop-dependent origin like (* kt 16) still
   resolves against the backward's own loop variable."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (>= (length form) 4) (symbolp (first form))
                  (string-equal (symbol-name (first form)) "LOAD-TILE-AT")
                  (symbolp (second form)) (symbolp (third form))
                  (listp (fourth form))
                  (not (assoc (third form) acc)))
         (push (list (third form) (second form) (fourth form)) acc))))
    (nreverse acc)))

(defun %mma-ad-transposed-stage (dst src origin rows cols)
  "Endeavor 145 P3b: a workgroup-collective TRANSPOSING copy of the ROWS x COLS block of SRC
   at ORIGIN into DST (which is COLS x ROWS).

   Plain element moves via workgroup-stride — the same collective the scratch `fill-tile`
   uses — so it costs no MMA and needs no ColumnMajor support.  Emitted as source, so it
   lowers through the ordinary analyzer path on both backends."
  (let* ((cl-pkg (find-package :crisp-language))
         (ws  (intern "WORKGROUP-STRIDE" cl-pkg))
         (aref (intern "~" cl-pkg))
         (set! (intern "SET!" cl-pkg))
         (plus (intern "+" cl-pkg))
         (to-int (intern "TO-INT" cl-pkg))
         (i (intern "%MMA_BW_TI" cl-pkg))
         (j (intern "%MMA_BW_TJ" cl-pkg))
         (oy (first origin))
         (ox (second origin)))
    (declare (ignore rows cols))
    ;; Iterate DST's index space (COLS x ROWS): dst[j][i] = src[oy+i][ox+j].
    ;; Both addends are coerced to INT: the load-tile-at origin may be a ULONG expression
    ;; (extent arithmetic) while the collective's loop variables are INT, and `+` will not
    ;; mix the two.  Tile coordinates are small, so INT is the right common type — it is
    ;; also what the `~` accessor takes.
    (list ws dst (list j i)
          (list set! (list aref dst j i)
                (list aref src
                      (list plus (list to-int oy) (list to-int i))
                      (list plus (list to-int ox) (list to-int j)))))))

(defun %mma-via-tile-backward (form dims-map src-map inputs outputs local-adj-fn kernel-pkg)
  "Endeavor 145 P3b: the backward for
   `(mma-accumulate-via-tile (M N K) C-TILE A-TILE B-TILE ...)`.

   Emits ONE nested LET holding the backward's temporaries and the two backward GEMMs:

       dC-slm (Mt x Nt) <- store-tile C-tile_ADJ      ; register accumulator -> SLM
       AT-slm (Kt x Mt) <- transposed stage of A's global source
       BT-slm (Nt x Kt) <- transposed stage of B's global source
         dA-reg (Mt x Kt) : mma-accumulate-via-tile  dA-reg  dC-slm  BT-slm
         dB-reg (Kt x Nt) : mma-accumulate-via-tile  dB-reg  AT-slm  dC-slm
       store-tile dA-reg -> A-tile_ADJ ;  store-tile dB-reg -> B-tile_ADJ

   From there the existing endeavor-111 machinery finishes the job: A-tile_ADJ / B-tile_ADJ
   are already auto-allocated, and %load-tile-at-bwd already scatters them into A_GRAD /
   B_GRAD.  Because the walk runs in reverse, this rule's emission lands BEFORE those
   scatters in the generated backward — which is the order the chain rule needs.

   ERRORS when a shape or a staging source is not compile-time recoverable.  It used to
   return NIL and let the caller fall through — but the walk's fallthrough DROPS the form,
   which hands back a silent ZERO gradient.  That is the same silent-wrong-answer class as
   the K-step bug P3a fixed, and it actually bit: a K-LOOPED matmul emitted a backward with
   no MMA in it at all, because the maps only scanned the top level of flat-anf and the
   loop body is nested.  Better to refuse to compile than to quietly return zeros."
  (destructuring-bind (shape c-tile a-tile b-tile &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((c-dims (assoc c-tile dims-map))
           (a-dims (assoc a-tile dims-map))
           (a-src  (assoc a-tile src-map))
           (b-src  (assoc b-tile src-map)))
      (log:debug "145 P3b via-tile bwd: c-tile=~a dims=~a | a-tile=~a dims=~a src=~a | b-tile=~a src=~a"
                 c-tile c-dims a-tile a-dims a-src b-tile b-src)
      (unless (and c-dims a-dims a-src b-src
                   (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        (error 'crisp-compiler-error
          :message (format nil "mma-accumulate-via-tile: cannot differentiate this tile multiply — ~a.  The backward needs the accumulator tile's (Mt Nt) and the A operand's Kt as COMPILE-TIME shapes, and needs each staged operand's originating global matrix (from its load-tile-at) so it can stage the transpose.  Give the tiles literal make-register-tile / make-scratch-matrix dimensions and stage both operands with load-tile-at."
                           (cond ((not c-dims) (format nil "the accumulator tile ~a has no compile-time (M N)" c-tile))
                                 ((not a-dims) (format nil "the A operand ~a has no compile-time shape" a-tile))
                                 ((not a-src)  (format nil "the A operand ~a was not staged by a load-tile-at" a-tile))
                                 (t            (format nil "the B operand ~a was not staged by a load-tile-at" b-tile))))
          :source-location nil))
      (when (and c-dims a-dims a-src b-src
                 (symbolp c-tile) (symbolp a-tile) (symbolp b-tile))
        ;; INTERNAL INVARIANT (not a user-facing contract).  This function emits the MMA
        ;; lowering, which requires both backward accumulators (Mt x Kt and Kt x Nt) to
        ;; decompose into whole hardware fragments.  %vjp-mma-accumulate-via-tile has already
        ;; checked that via %mma-vjp-mma-admissible-p before routing here, so a violation means
        ;; the VJP dispatch is wrong, not the user's kernel.
        ;;
        ;; This USED to be a hard user-facing error called "the K-tile contract" — a claim that
        ;; a kernel with Kt=8 could not be differentiated at all.  That was wrong: dA = dC.B^T
        ;; and dB = A^T.dC hold at every shape, and only this LOWERING needs the dims to divide.
        ;; The condition now selects the scalar lowering instead.  See the retraction section in
        ;; tests/spec/145-mma-autodiff/mma-autodiff.md.
        (multiple-value-bind (sm sn sk) (%spv-mma-shape)
          (declare (ignore sk))
          (let ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims)))
            (unless (%mma-vjp-mma-admissible-p mt nt kt)
              (error 'crisp-compiler-error
                :message (format nil "INTERNAL: MMA backward lowering reached with a tile (Mt=~a Nt=~a Kt=~a) that does not decompose on shape (~a ~a) — the VJP should have selected the scalar lowering."
                                 mt nt kt sm sn)
                :source-location nil))))
        (let* ((mt (second c-dims)) (nt (third c-dims)) (kt (third a-dims))
               (pkg (or kernel-pkg (symbol-package c-tile)))
               (cl-pkg (find-package :crisp-language))
               (nm (lambda (fmt sym) (intern (format nil fmt (symbol-name sym)) pkg)))
               (dc-slm (funcall nm "~A_BWDC"  c-tile))
               (at-slm (funcall nm "~A_BWT"   a-tile))
               (bt-slm (funcall nm "~A_BWT"   b-tile))
               (da-reg (funcall nm "~A_BWACC" a-tile))
               (db-reg (funcall nm "~A_BWACC" b-tile))
               (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj-fn kernel-pkg))
               (a-adj (%tlc-bwd-adj-name a-tile inputs outputs local-adj-fn kernel-pkg))
               (b-adj (%tlc-bwd-adj-name b-tile inputs outputs local-adj-fn kernel-pkg))
               (let-sym  (intern "LET" cl-pkg))
               (msm      (intern "MAKE-SCRATCH-MATRIX" cl-pkg))
               (mrt      (intern "MAKE-REGISTER-TILE" cl-pkg))
               (float-s  (intern "FLOAT" cl-pkg))
               (store-t  (intern "STORE-TILE" cl-pkg))
               (via      (intern "MMA-ACCUMULATE-VIA-TILE" cl-pkg))
               (sync     (intern "SYNC-WORKGROUP" cl-pkg)))
          `(,let-sym ((,dc-slm (,msm ,float-s (,mt ,nt)))
                      (,at-slm (,msm ,float-s (,kt ,mt)))
                      (,bt-slm (,msm ,float-s (,nt ,kt)))
                      (,da-reg (,mrt ,float-s (,mt ,kt) 0.0))
                      (,db-reg (,mrt ,float-s (,kt ,nt) 0.0)))
             ;; dC: the accumulator's adjoint, register -> SLM (so it can be an MMA operand).
             (,store-t ,c-adj ,dc-slm (0 0))
             ;; The transposed operands, staged from the ORIGINAL global sources.
             ,(%mma-ad-transposed-stage at-slm (second a-src) (third a-src) mt kt)
             ,(%mma-ad-transposed-stage bt-slm (second b-src) (third b-src) kt nt)
             (,sync)
             ;; dA = dC . B^T      (Mt, Kt, Nt)
             (,via ,shape ,da-reg ,dc-slm ,bt-slm)
             ;; dB = A^T . dC      (Kt, Nt, Mt)
             (,via ,shape ,db-reg ,at-slm ,dc-slm)
             (,sync)
             (,store-t ,da-reg ,a-adj (0 0))
             (,store-t ,db-reg ,b-adj (0 0)))))))
  )

(defun %mma-via-tile-backward-logged (form dims-map src-map inputs outputs local-adj-fn kernel-pkg)
  "Endeavor 145 P3b: %mma-via-tile-backward plus a log of the emitted backward AST.
   The tile-level backward is the most intricate emission in the AD engine, and it is
   assembled from source forms that then go through the ordinary analyzer + SROA explosion —
   so seeing the pre-analysis AST is the single most useful debugging artifact when a
   backward fails to compile.  Run the compiler with --log-level=debug to see it."
  (let ((r (%mma-via-tile-backward form dims-map src-map inputs outputs local-adj-fn kernel-pkg)))
    (log:debug "145 P3b emitted backward AST:~%~s" r)
    r))

(defun %mma-ad-register-operand-tile-p (init-form)
  "T when INIT-FORM is a make-register-tile carrying an :operand key — i.e. an MMA
   A/B operand tile (endeavor 142's register-resident load-tile overload) rather than
   an accumulator.

   Scans by symbol-name rather than comparing to a keyword object: the form is read in
   the kernel's package, and this stays correct if :operand ever arrives as a non-keyword
   symbol.  The scan starts past the dims/init positions so a literal init value can
   never be mistaken for the key."
  (and (consp init-form)
       (loop for x in (cdddr init-form)
             thereis (and (symbolp x)
                          (string-equal (symbol-name x) "OPERAND")))))

(defun %mma-ad-adj-init (init-form)
  "Endeavor 145 P3b: the adjoint allocator paired with a forward tile binding.

   Scratch tiles keep the existing behaviour (%promote-scratch-init-for-ad, which also
   promotes e.g. ulong -> double).

   Endeavor 146 Gap 4: a register tile's adjoint depends on WHICH ROLE the tile plays.

     ACCUMULATOR  (no :operand)  -> a same-shaped register tile zeroed to 0.0.
        The C adjoint is filled by %load-register-tile-acc from C_GRAD and then staged
        to SLM by the VJP itself, so registers are right for it.

     OPERAND      (:operand :a/:b) -> a same-shaped SCRATCH MATRIX.
        EVERY consumer of an operand adjoint indexes it as memory: the scalar lowering
        writes it with workgroup-stride + ~, the MMA fast path uses it as a store-tile
        DESTINATION, and %load-tile-at-bwd reads it element-wise to scatter into the
        global gradient.  A register tile cannot be written element-wise at all —
        %explode-register-tiles has replaced the whole-tile symbol with per-lane
        fragment vars by then, so `(~ TILE m k)` has no TILE to resolve.  This is not
        an AD-specific fact: the same write fails in a forward-only kernel.

   145 never hit this because its specs staged operands through make-scratch-matrix +
   load-tile-at, so operand adjoints were ALREADY scratch.  142 Phase A introduced
   register-resident operands via the load-tile overload, and this allocator had never
   learned about them.

   NOT a new derivative: dA = dC.B^T and dB = A^T.dC are unchanged and both lowerings
   already computed them correctly.  This decides only WHERE the result is allocated.

   Element type is FLOAT in both register cases: fragments are fp32 and an adjoint
   always starts at zero."
  (if (and (consp init-form) (symbolp (car init-form))
           (string-equal (symbol-name (car init-form)) "MAKE-REGISTER-TILE"))
      (let ((cl-pkg (find-package :crisp-language)))
        (if (%mma-ad-register-operand-tile-p init-form)
            (list (intern "MAKE-SCRATCH-MATRIX" cl-pkg)
                  (intern "FLOAT" cl-pkg)
                  (third init-form))
            (list (intern "MAKE-REGISTER-TILE" cl-pkg)
                  (intern "FLOAT" cl-pkg)
                  (third init-form)
                  0.0)))
      (%promote-scratch-init-for-ad init-form)))

(defun %mma-ad-register-tile-p (sym flat-anf)
  "Endeavor 145 P3b: T when SYM is bound in FLAT-ANF by a make-register-tile constructor.
   Distinguishes a register accumulator tile from an SLM scratch tile, which the AD walk
   must treat completely differently at a store."
  (and (symbolp sym)
       (loop for form in flat-anf
               thereis (and (consp form) (= (length form) 2)
                            (eq (first form) sym)
                            (consp (second form)) (symbolp (first (second form)))
                            (string-equal (symbol-name (first (second form)))
                                          "MAKE-REGISTER-TILE")))))

(defun %mma-ad-unscale-tile-origin (origin)
  "Endeavor 145 P3b: recover the original tile-ID G from the coordinate the `store-tile`
   macro produced, `(* (to-ulong G) (~ (extents~ TILE) i))`.

   A register tile has no extents~, so that scaled coordinate is meaningless for it — but
   the tile-ID inside is exactly what the register store/load path wants.  Anything that
   does not match the shape is returned unchanged, so an already-absolute coordinate still
   works."
  (if (and (consp origin) (= (length origin) 3)
           (symbolp (first origin)) (string-equal (symbol-name (first origin)) "*")
           (consp (second origin)) (symbolp (first (second origin)))
           (string-equal (symbol-name (first (second origin))) "TO-ULONG"))
      (second (second origin))
      origin))

(defun %mma-ad-expand-mmts-in-form (form reg-map)
  "Recursively lower every matrix-multiply-tile-stride in FORM (endeavor 145 P8: the AD path
   must do this before ANF).  BUG 036: forwards the register tile's declared INIT as the
   per-output-tile reset value; a scratch C-tile resets to the 0.0 default."
  (cond
    ((not (consp form)) form)
    ((%mmts-head-p form)
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form nil)
       (let ((entry (assoc c-tile reg-map)))
         (%mmts-lower c-form c-tile
                      (if entry (second entry) c-tile)
                      k-form k-step gy gx gk
                      (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) body)
                      nil
                      (if entry (third entry) 0.0)))))
    (t (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) form))))

;;; ===================================================================
;;; THE VJP REGISTRY  (endeavor 145, after the P3b post-mortem)
;;;
;;; WHY.  generate-backward-walk's process-form had grown ~12 special-case clauses, and every
;;; endeavor that adds a primitive adds another.  Worse, endeavor 145 derived MMA's backward
;;; THROUGH one chosen lowering (register accumulator tiles decomposed into native fragments)
;;; and then reported that lowering's shape requirements as if they were the hardware's — the
;;; "K-tile contract".  They are not.  dA = dD.B^T and dB = A^T.dD hold at every shape; only the
;;; MMA-instruction REALISATION of them needs the shapes to divide.
;;;
;;; The registry separates those two things, which is the whole point:
;;;   - WHAT the derivative is   -> one entry per primitive, math only.
;;;   - HOW it is computed       -> chosen INSIDE that entry.
;;; A VJP may return a shape-agnostic scalar lowering by default and an MMA lowering when the
;;; shapes admit it.  The walk neither knows nor cares, so the lowering's constraints can never
;;; again leak out as a language-level contract.
;;;
;;; SCOPE: PRIMITIVES, not control flow.  let / dotimes / if / when / progn must be structurally
;;; MIRRORED by the walk and are not lookups.  The registry absorbs the leaf cases only.
;;;
;;; It is deliberately general rather than MMA-private: %backward-skip-fn-p is already a
;;; degenerate registry ("these primitives have a zero VJP"), endeavor 123's FFI user-VJP is the
;;; same concept built bespoke, and the deferred chapter-1..4 AD work (async / ring /
;;; warp-specialisation / wgmma / prefetch) will each need entries.
;;; ===================================================================
(defvar *vjp-registry* (make-hash-table :test 'equal)
  "Primitive NAME (upcased string) -> VJP function of (FORM CTX).

   CTX is a plist: :flat-anf :inputs :outputs :local-adj :kernel-pkg.

   The function returns one of:
     a FORM   -- the backward Crisp source to emit (wrap several in a progn);
     :inert   -- handled, contributes no gradient (emit nothing);
     NIL      -- DECLINE: not applicable to this particular form, so the walk's existing
                 clauses run unchanged.  Declining is what lets a VJP dispatch on a property
                 of its ARGUMENTS (e.g. store-tile on a register tile vs a scratch tile)
                 rather than on the head symbol alone.")

(defun register-vjp (name fn)
  "Register FN as the VJP for primitive NAME (a string, matched case-insensitively)."
  (setf (gethash (string-upcase name) *vjp-registry*) fn))

(defun find-vjp (head)
  "The registered VJP for form-head HEAD, or NIL."
  (and (symbolp head) (gethash (string-upcase (symbol-name head)) *vjp-registry*)))

(defun %try-vjp (form ctx)
  "Dispatch FORM to its registered VJP.  Returns the backward form, :inert, or NIL (decline).
   NIL is also returned when nothing is registered for the head, so the caller can fall
   through to the walk's own clauses."
  (when (and (consp form) (symbolp (car form)))
    (let ((fn (find-vjp (car form))))
      (when fn
        (let ((r (funcall fn form ctx)))
          (log:debug "VJP ~a -> ~a" (car form)
                     (cond ((null r) "DECLINE") ((eq r :inert) ":inert") (t (format nil "~s" r))))
          r)))))

;;; ===================================================================
;;; VJP for mma-accumulate-via-tile — SCALAR by default, MMA as a fast path.
;;;
;;; C-tile += A.B  =>  dA[m,k] += sum_n dC[m,n]*B[k,n],  dB[k,n] += sum_m A[m,k]*dC[m,n].
;;; That is true at EVERY shape.  Only the MMA realisation of it needs the tile dims to divide
;;; into whole hardware fragments, so that condition now selects a LOWERING instead of gating
;;; correctness.
;;;
;;; The scalar lowering is in some ways simpler than the MMA one: it indexes the ORIGINAL GLOBAL
;;; operands directly, so it needs none of the transposed SLM staging the MMA path requires.
;;; (It still reads the global sources rather than the staged primal tiles, because a backward
;;; kernel replays the forward's BINDINGS but not its STATEMENTS — the staged tiles are empty.)
;;; ===================================================================
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT."
  (declare (ignore a-op b-op))
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         (flt  (intern "FLOAT" cl))    (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         (dc   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl)))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (list (list dc (list msm flt (list mt nt))))
            (list st c-adj dc (list 0 0))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            (list ws a-adj (list m k)
                  (list dt (list n nt)
                        (list set! (list aref a-adj m k)
                              (list plus (list aref a-adj m k)
                                    (list mul (list aref dc m n)
                                          (list aref b-src (ix boy k) (ix box n)))))))
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]
            (list ws b-adj (list k n)
                  (list dt (list m mt)
                        (list set! (list aref b-adj k n)
                              (list plus (list aref b-adj k n)
                                    (list mul (list aref a-src (ix aoy m) (ix aox k))
                                          (list aref dc m n))))))
            (list sync)))))

(defun %mma-vjp-mma-admissible-p (mt nt kt)
  "T when the MMA fast path can realise the backward: both backward accumulators (Mt x Kt and
   Kt x Nt) must decompose into whole hardware accumulator fragments.  This is a PERFORMANCE
   predicate — declining it selects the scalar lowering, never an error."
  (multiple-value-bind (sm sn sk) (%spv-mma-shape)
    (declare (ignore sk))
    (and (plusp sm) (plusp sn)
         (zerop (mod kt (lcm sm sn)))
         (zerop (mod mt sm))
         (zerop (mod nt sn)))))

;;; ===================================================================
;;; VJP for the FRAGMENT-level MMA chain  (133/02, 133/10, 132/02 — "hello mma")
;;;
;;; The earlier claim that no fragment-level backward exists was wrong in the same way the
;;; "K-tile contract" was: it argued from one chosen realisation (keep everything in registers,
;;; where dA's contraction over n spans lanes and needs shuffles) to a statement about the
;;; mathematics.  Route through memory instead — exactly as the tile-level VJP already routes
;;; dC — and the lane problem simply does not arise.
;;;
;;; WHY THIS IS FUSED RATHER THAN COMPOSITIONAL.  Measured from the ANF the walk actually
;;; receives:
;;;     (STORE-FRAGMENT (MMA-ACCUMULATE C-ACC A-FRAG B-FRAG) C (0 0))
;;; store-fragment is opaque to ANF, so its value argument is NOT split into its own binding —
;;; there is no intermediate variable to hang a fragment-valued adjoint on.  The whole chain
;;; arrives as one statement, so one fused VJP is the natural shape here, not a shortcut.
;;;
;;; SCOPE, stated plainly: this covers `store-fragment` applied directly to an
;;; `mma-accumulate` — the canonical hello-mma form.  An `mma-accumulate` whose result is held
;;; in a register across a loop before being stored is NOT covered and still reports its (now
;;; accurate) "no VJP registered" error.  That case wants genuine fragment-valued adjoints.
;;; ===================================================================
(defun %vjp-resolve-anf-value (sym flat-anf)
  "Resolve an ANF temp back to the literal it was bound to.

   Coordinate lists reach the walk as temps — `(%ANF-T-1 (0 0))` — because anf-normalize treats
   a bare list like `(0 0)` as a call and binds it.  (The same pathology turned
   `(GRID-Y GRID-X GRID-K)` into a call in P8.)  Returns SYM unchanged if it is not such a temp."
  (if (symbolp sym)
      (or (loop for f in flat-anf
                  when (and (consp f) (= (length f) 2) (eq (first f) sym))
                return (second f))
          sym)
      sym))

(defun %vjp-fragment-source (frag-sym flat-anf which)
  "For a fragment variable bound by (load-fragment-a/b SRC COORDS), return the list
   (SRC COORD-Y COORD-X), or NIL when FRAG-SYM was not bound that way.
   WHICH is :a or :b and only selects the expected head."
  (let ((head (ecase which (:a "LOAD-FRAGMENT-A") (:b "LOAD-FRAGMENT-B"))))
    (dolist (f flat-anf nil)
      (when (and (consp f) (= (length f) 2) (eq (first f) frag-sym)
                 (consp (second f)) (symbolp (first (second f)))
                 (string-equal (symbol-name (first (second f))) head))
        (let ((coords (%vjp-resolve-anf-value (third (second f)) flat-anf)))
          (cl:return (list (second (second f))
                           (if (consp coords) (first coords) 0)
                           (if (consp coords) (second coords) 0))))))))

(defun %vjp-store-fragment (form ctx)
  "VJP for (store-fragment (mma-accumulate C A-FRAG B-FRAG) DEST (TY TX)).

   D = A.B + C stored to DEST, so with dD read from DEST_GRAD at the store's tile:
       dA[m,k] += sum_n dD[m,n] * B[k,n]
       dB[k,n] += sum_m A[m,k] * dD[m,n]
   over one instruction-shaped block (M_n x N_n accumulator, M_n x K_n A, K_n x N_n B), reading
   the ORIGINAL global operands at their load-fragment origins and scattering with atomic-add!
   — the same collective + atomic discipline %load-tile-at-bwd uses.

   DECLINES unless the stored value is literally an mma-accumulate over two load-fragment
   results; anything else falls through to the walk's existing (accurate) error."
  (destructuring-bind (value dest tile-id &rest ignored) (cdr form)
    (declare (ignore ignored))
    (when (and (consp value) (symbolp (car value))
               (string-equal (symbol-name (car value)) "MMA-ACCUMULATE")
               (= (length value) 4))
      (let* ((flat-anf (getf ctx :flat-anf))
             (inputs (getf ctx :inputs)) (outputs (getf ctx :outputs))
             (local-adj (getf ctx :local-adj)) (kernel-pkg (getf ctx :kernel-pkg))
             (a-frag (third value)) (b-frag (fourth value)))
        (let ((ainfo (%vjp-fragment-source a-frag flat-anf :a))
              (binfo (%vjp-fragment-source b-frag flat-anf :b)))
          (when (and ainfo binfo)
            (destructuring-bind (a-src ay ak) ainfo
              (destructuring-bind (b-src bk bx) binfo
              (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                (let* ((cl (find-package :crisp-language))
                       (ws (intern "WORKGROUP-STRIDE" cl)) (dt (intern "DOTIMES" cl))
                       (aref (intern "~" cl)) (aadd (intern "ATOMIC-ADD!" cl))
                       (plus (intern "+" cl)) (mul (intern "*" cl))
                       (ti (intern "TO-INT" cl)) (prog- (intern "PROGN" cl))
                       (m (intern "%FVJP_M" cl)) (n (intern "%FVJP_N" cl)) (k (intern "%FVJP_K" cl))
                       (d-adj (%tlc-bwd-adj-name dest inputs outputs local-adj kernel-pkg))
                       (a-adj (%tlc-bwd-adj-name a-src inputs outputs local-adj kernel-pkg))
                       (b-adj (%tlc-bwd-adj-name b-src inputs outputs local-adj kernel-pkg))
                       (cy (* (if (consp tile-id) (or (first tile-id) 0) 0) sm))
                       (cx (* (if (consp tile-id) (or (second tile-id) 0) 0) sn)))
                  (flet ((ix (base off) (list plus (list ti base) (list ti off))))
                    (list prog-
                          ;; dA[m,k] += sum_n dD[m,n] * B[k,n]
                          (list ws a-adj (list m k)
                                (list dt (list n sn)
                                      (list aadd (list aref a-adj (ix (* ay sm) m) (ix (* ak sk) k))
                                            (list mul
                                                  (list aref d-adj (ix cy m) (ix cx n))
                                                  (list aref b-src (ix (* bk sk) k) (ix (* bx sn) n))))))
                          ;; dB[k,n] += sum_m A[m,k] * dD[m,n]
                          (list ws b-adj (list k n)
                                (list dt (list m sm)
                                      (list aadd (list aref b-adj (ix (* bk sk) k) (ix (* bx sn) n))
                                            (list mul
                                                  (list aref a-src (ix (* ay sm) m) (ix (* ak sk) k))
                                                  (list aref d-adj (ix cy m) (ix cx n))))))))))))))))))

(register-vjp "STORE-FRAGMENT" #'%vjp-store-fragment)

(register-vjp "MAKE-REGISTER-FRAGMENT" (lambda (form ctx) (declare (ignore form ctx)) :inert))

(defun %vjp-fragment-consumed-by-fused-store-p (frag-sym flat-anf)
  "T when FRAG-SYM is an operand of an `(mma-accumulate ...)` that is stored directly by a
   `store-fragment` — i.e. the chain %vjp-store-fragment already differentiates as a unit."
  (dolist (f flat-anf nil)
    (let ((form (if (and (consp f) (= (length f) 2) (consp (second f))) (second f) f)))
      (when (and (consp form) (symbolp (car form))
                 (string-equal (symbol-name (car form)) "STORE-FRAGMENT")
                 (>= (length form) 2)
                 (let ((v (second form)))
                   (and (consp v) (symbolp (car v))
                        (string-equal (symbol-name (car v)) "MMA-ACCUMULATE")
                        (member frag-sym (cddr v)))))
        (cl:return t)))))

(defun %vjp-load-fragment (form ctx)
  "VJP for load-fragment-a / load-fragment-b.

   Returns :inert when this fragment feeds a fused store-fragment(mma-accumulate ...) chain —
   %vjp-store-fragment has already scattered the gradient into this operand's global gradient,
   so contributing again would double-count.

   DECLINES otherwise, so an un-fused fragment use still raises the (accurate) 'no VJP
   registered' error rather than silently yielding a zero gradient.  Silently dropping a
   gradient is the failure mode this endeavor hit three times; it is not repeated here."
  (declare (ignore form))
  (let ((flat-anf (getf ctx :flat-anf))
        (bound-to (getf ctx :binding-var)))
    (when (and bound-to (%vjp-fragment-consumed-by-fused-store-p bound-to flat-anf))
      :inert)))

(register-vjp "LOAD-FRAGMENT-A" #'%vjp-load-fragment)

(register-vjp "LOAD-FRAGMENT-B" #'%vjp-load-fragment)

;;; ===================================================================
;;; BUG 037 — the backward must read staged tiles' primals from their GLOBAL SOURCE.
;;;
;;; A backward kernel replays the forward's BINDINGS but not its STATEMENTS.
;;; `make-scratch-matrix` is a binding, so the tiles EXIST in the backward — but
;;; `load-tile-at`, which FILLS them, is a statement and is never replayed.  So a replayed
;;; primal like `(~ A-TILE i k)` read an EMPTY tile, and any gradient needing another operand's
;;; primal value came back SILENTLY ZERO.  Measured on a 4x4 scalar matmul: analytical 0.0
;;; against a correct finite difference of 0.06.
;;;
;;; Only visible when a primal is actually NEEDED: with a constant multiplier none is, which is
;;; why every pre-existing AD-over-tiles spec passed.  Bisected — overwrite, accumulate, and
;;; three-deep loops with ONE tile operand all give exact gradients; only TWO tile operands fail.
;;;
;;; FIX (option b, chosen over replaying the staging statements): rewrite the replayed primal
;;; to read the ORIGINAL GLOBAL matrix at the staging origin —
;;;     (~ A-TILE i k)  ->  (~ A (+ oy i) (+ ox k))
;;; This generalises what endeavor 145's MMA VJP already does (and which is numerically verified
;;; four ways).  It has the same coverage as replaying `load-tile-at` would, but costs no extra
;;; SLM traffic, needs no barriers in the backward, and does not touch the walk's loop structure.
;;;
;;; WHAT IT DOES NOT COVER: a tile filled by COMPUTATION has no global source, so its primal is
;;; still unavailable — e.g. `(set! (~ C i j) (* (~ C i j) (~ A i j)))`, where dA needs C's OLD
;;; value.  That case now ERRORS rather than silently returning zero (see the check below).
;;; Closing it properly means real primal recomputation / checkpointing, which is its own design.
;;; ===================================================================
(defvar *ad-tile-src-map* nil
  "Alist TILE-SYM -> (GLOBAL-SRC ORIGIN-FORMS) for tiles filled by load-tile-at in the kernel
   being differentiated.  Bound by generate-backward-walk.")

(defvar *ad-scratch-syms* nil
  "Hash of scratch-tile symbols in the kernel being differentiated.  Bound by
   generate-backward-walk.")

(defun %ad-tile-read-p (expr)
  "T when EXPR is an indexed tile read `(~ SYM idx ...)`."
  (and (consp expr) (symbolp (car expr))
       (string= (symbol-name (car expr)) "~")
       (symbolp (second expr)) (second expr)
       (cddr expr)))

(defun %ad-rewrite-primal-tile-read (expr)
  "Rewrite a staged-tile read to the equivalent read of its ORIGINAL GLOBAL source, or return
   EXPR unchanged when the tile has no recoverable source.  Indices are coerced with to-int: a
   staging origin can be a ULONG extent expression while the loop variables are INT."
  (if (not (%ad-tile-read-p expr))
      expr
      (let ((entry (assoc (second expr) *ad-tile-src-map*)))
        (if (null entry)
            expr
            (let* ((cl (find-package :crisp-language))
                   (aref (intern "~" cl)) (plus (intern "+" cl)) (ti (intern "TO-INT" cl))
                   (src (second entry)) (origin (third entry))
                   (idxs (cddr expr)))
              (if (/= (length origin) (length idxs))
                  expr
                  (list* aref src
                         (loop for o in origin
                               for i in idxs
                               collect (list plus (list ti o) (list ti i))))))))))

(defun %ad-rewrite-primal-bindings (bindings)
  "Apply %ad-rewrite-primal-tile-read to each primal binding's VALUE."
  (mapcar (lambda (b)
            (if (and (consp b) (= (length b) 2))
                (list (first b) (%ad-rewrite-primal-tile-read (second b)))
                b))
          bindings))

(defun %ad-check-unresolved-primals (bindings body)
  "ERROR when a primal bound to an UNRESOLVABLE scratch-tile read is actually USED as a value by
   the backward BODY.

   Silence here is what bug 037 was: an unavailable primal read as zero.  A tile whose primal is
   never consumed (a pure accumulator like C-tile, whose old value matters only for its adjoint)
   is fine and must NOT error — hence the usage test rather than a blanket check."
  (dolist (b bindings)
    (when (and (consp b) (= (length b) 2)
               (%ad-tile-read-p (second b))
               *ad-scratch-syms*
               (gethash (second (second b)) *ad-scratch-syms*)
               (null (assoc (second (second b)) *ad-tile-src-map*))
               (%vjp-form-mentions-any-p body (list (first b))))
      (error 'crisp-compiler-error
        :message (format nil "cannot differentiate: the backward needs the PRIMAL value of ~a, a scratch tile that is not filled by load-tile-at, so its contents cannot be recovered (a backward kernel replays the forward's bindings but not its statements).  Tiles staged with load-tile-at are read back from their global source automatically; a tile filled by COMPUTATION is not recoverable.  Restructure so the value the gradient needs comes from a staged or global operand, or mark the kernel forward-only.  See plan/bugs.md #037."
                         (second (second b)))
        :source-location nil))))

(defvar *ad-inlining-fns* nil
  "Names of sub-functions currently being inlined by the backward walk, innermost last.
   Guards against unbounded expansion on a recursive or mutually-recursive call.")

(defun %ad-inline-sub-fn-backward (fn args emit-fn process-form-fn)
  "BUG 038: emits the backward for a call to differentiable sub-function FN by INLINING its body
   at the call site and walking it with PROCESS-FORM-FN, the caller's ordinary STATEMENT walker.

   Why the statement walker and not %handle-single-value-backward.  The existing inline path,
   hof-inline-backward, walks only two-element value bindings, because a HOF's inlined body is
   consumed for its VALUE.  A staging sub-function has no value worth differentiating — its
   whole gradient content is in its STATEMENTS, `load-tile` above all.  Routing through
   process-form-fn means every construct the walker already knows (load/store-tile-at, set!,
   let, dotimes, if/when, nested calls) applies inside a sub-function body for free, and stays
   applying as the walker grows.

   The body is substituted (formals -> actual call arguments), ANF-transformed and flattened
   exactly as hof-inline-backward does, so the forms handed to the walker are the same shape it
   sees for a kernel body.  Adjoints are NOT renamed: substitution has already rewritten the
   callee's parameter references to the caller's symbols, so `(~ dst i j)` becomes `(~ C i j)`
   and the walker mints C_ADJ in the caller's frame, which is where the gradient must land.

   Statements are walked in reverse, matching the PROGN clause's convention that the CALLER
   reverses.  Returns T when it emitted, NIL when FN cannot be inlined (the caller then falls
   back to the _GRAD companion path)."
  (unless (%ad-sub-fn-inlinable-p fn)
    (return-from %ad-inline-sub-fn-backward nil))
  (let* ((store (gethash fn *differentiable-hof-store*))
         (param-syms (getf store :param-syms))
         (body-forms (getf store :body-forms)))
    (when (/= (length param-syms) (length args))
      ;; Arity disagreement means the substitution would be positionally wrong, which would
      ;; produce a confidently incorrect gradient rather than a missing one.  Decline instead.
      (log:warn "038: not inlining ~a — ~a params but ~a args" fn (length param-syms) (length args))
      (return-from %ad-inline-sub-fn-backward nil))
    (let* ((*ad-inlining-fns* (cons fn *ad-inlining-fns*))
           (subst-alist (loop for p in param-syms for a in args collect (cons p a)))
           (subst-body (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
           (anf-body (mapcar #'anf-transform subst-body))
           (flat (flatten-anf-body anf-body)))
      (log:debug "038: inlining ~a for backward — ~a body form(s) -> ~a flat form(s)"
                 fn (length body-forms) (length flat))
      (dolist (f (reverse flat))
        (funcall process-form-fn f emit-fn))
      t)))

(defun %ad-sub-fn-inlinable-p (fn)
  "Returns T if FN's body was retained and can be inlined into a backward walk.

   Keyed on the RETAINED BODY rather than on *differentiable-functions*, deliberately.  When
   %generate-backward-companion-ast-body cannot build a companion it UNREGISTERS the function:

       Cannot differentiate function SCALE_INTO: it mutates parameter DST via cell write.
       This function is not valid in a differentiable kernel.  Unregistering.

   That message overstates its case.  Writing through a tensor parameter is what a staging or
   fill sub-function is FOR, and it is not a problem for the derivative — only for the companion
   lowering, whose chain rule threads gradients through returned values and &out grad-handles
   and so has nowhere to put an in-place write.  Inlining has no such difficulty: after
   substitution the write is `(set! (~ C i j) ...)` on the CALLER's symbol, which is the same
   form %gfw-process-set! already differentiates inside a kernel.  So a failed companion must
   not veto the inline path — otherwise the more expressive lowering is disabled by the less
   expressive one's limits.

   Excluded: foreign functions (no body exists), HOFs (their own inline path is keyed on the
   function-valued parameter), functions deliberately marked gradient-inert, and anything
   already on the inline stack."
  (let ((info (gethash fn *differentiable-functions*))
        (store (gethash fn *differentiable-hof-store*)))
    (and store
         (getf store :inlinable)
         (getf store :body-forms)
         (not (getf info :foreign))
         (not (getf info :hof))
         (not (gethash fn *inert-functions*))
         (not (member fn *ad-inlining-fns* :test #'eq)))))

;;; ======================================================================
;;; Ring PIPELINING under --differentiate (138/04, 138/05).
;;;
;;; The kernel computes C = A.B.  The ring, the prologue, the two-deep prefetch and the barrier
;;; phases are SCHEDULE, not semantics.  Reverse-mode AD is determined by the function, not by
;;; how the operands were staged, so any correct matmul backward pairs with this forward.
;;;
;;; The previous refusal ("the ring is loaded from TWO sites with DIFFERENT origins, so the
;;; primal origin is ambiguous — decline") asked the wrong question.  "Which load site filled
;;; this slot?" is a question about the SCHEDULE and genuinely has two answers.  The derivative
;;; needs a different one:
;;;
;;;     what global matrix does this operand DENOTE, and at what tile coordinate is it CONSUMED?
;;;
;;; Both have exactly one answer.  A-ring is only ever loaded from A; B-ring only ever from B.
;;; And the consumption coordinate is (grid-y grid-k) — the enclosing loops the backward already
;;; mirrors.  The prefetch origin (grid-y next-k), which the whole objection was built on, belongs
;;; to a DIFFERENT PIPELINE STAGE than the one being consumed; reading it was reading the
;;; producer's bookkeeping instead of the consumer's meaning.
;;;
;;; WHAT ACTUALLY NEEDED FIXING — only the PRIMAL.  The adjoint flow was already right: a
;;; faithful reverse of the pipeline scatters slot-adjoint to A at the prefetch's origin
;;; next-k, and the slot consumed at iteration grid-k is precisely the one the prefetch of
;;; iteration grid-k-2 wrote with next-k = grid-k.  The mirror lands on the correct stage by
;;; construction.  It is the operand PRIMAL — `(~ a-src (+ aoy m) (+ aox k))` in the scalar
;;; lowering — that needs the consuming coordinate, and that is what was wrong.
;;;
;;; HOW THE CONSUMING COORDINATE IS RECOVERED, without new bookkeeping: across a ring's load
;;; sites the origin components AGREE except in the K position — A is staged at
;;; (grid-y <k>) from both sites, B at (<k> grid-x).  So the differing component IS the K index,
;;; and it is replaced by the innermost enclosing loop variable at the consuming site.  Exactly
;;; one component may differ; more than one is a genuine ambiguity and still declines.
;;; ======================================================================
(defvar *ad-loop-vars* nil
  "Loop variables enclosing the form currently being walked backward, INNERMOST FIRST.
   Bound by %gfw-process-dotimes.  Used to recover the coordinate at which a ring-staged
   operand is CONSUMED, which is not recoverable from the forward's load sites (a pipelined
   ring is filled by a prologue and a prefetch, both for other stages).")

(defun %ad-tile-base (op)
  "The underlying tile SYMBOL of a tile operand: itself if a symbol, the ring if a
   `(ring-get RING i)` view.  Shape and staging questions are asked of the base — every slot of
   a ring has the ring's element shape — while ADJOINT questions keep the view (see
   %tlc-bwd-adj-name), because slot i's adjoint is slot i of the adjoint ring, not the whole
   ring."
  (cond
    ((symbolp op) op)
    ((and (consp op) (symbolp (car op))
          (string-equal (symbol-name (car op)) "RING-GET"))
      (%ad-tile-base (second op)))
    (t nil)))

(defun %ad-ring-load-sites (flat-anf)
  "Alist RING-SYM -> list of (GLOBAL-SRC ORIGIN-FORMS), one entry per `load-tile-at` whose TILE
   argument is a `(ring-get RING i)` view.  ALL sites are kept, unlike %mma-ad-tile-source-map
   which keeps the first per tile: a pipelined ring has several, and it is their AGREEMENT that
   carries the information (see %ad-reconcile-ring-origin)."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (>= (length form) 4) (symbolp (first form))
                  (string-equal (symbol-name (first form)) "LOAD-TILE-AT")
                  (symbolp (second form))
                  (listp (fourth form)))
         (let ((base (and (consp (third form)) (%ad-tile-base (third form)))))
           (when base
             (let ((entry (assoc base acc)))
               (if entry
                   (setf (cdr entry) (append (cdr entry) (list (list (second form) (fourth form)))))
                   (push (list base (list (second form) (fourth form))) acc))))))))
    (nreverse acc)))

(defun %mma-ad-tile-dims-map (flat-anf)
  "Alist SYM -> (ROWS COLS) for every compile-time-shaped tile bound anywhere in FLAT-ANF:
   `(V (make-register-tile T (M N) INIT))`, `(V (make-scratch-matrix T (R C)))`, and — endeavor
   138 — the RING constructors, whose per-slot dimensions sit in the same position.  A ring is
   keyed by its own symbol; every slot has the ring's element shape, so a `(ring-get R i)`
   operand resolves through %ad-tile-base."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-REGISTER-TILE" "MAKE-SCRATCH-MATRIX"
                            "MAKE-SCRATCH-MATRIX-RING")
                          :test #'string=)
                  (let ((d (third (second form))))
                    (and (listp d) (= (length d) 2) (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (list (first form)
                     (first (third (second form)))
                     (second (third (second form))))
               acc))))
    (nreverse acc)))

(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B ...).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path's shape requirements, so they cannot leak back out as a
   language-level contract the way the 'K-tile contract' did.

     MMA fast path  -- when both backward accumulators decompose into whole fragments.
     Scalar path    -- otherwise.  Correct at any shape, slower.

   Endeavor 138: operands may be RING VIEWS.  Shape and source questions resolve through
   %ad-tile-base to the ring (every slot has the ring's element shape); the ADJOINT keeps the
   view, because slot i's adjoint is slot i of the adjoint ring.  A ring operand also forces the
   SCALAR lowering: the MMA path stages a transposed operand out of the tile it was given, and
   for a pipelined ring that tile holds a DIFFERENT stage than the one being differentiated.
   The scalar lowering indexes the original global operands directly, so it is immune — and
   correct-but-slow was always the default anyway.

   DECLINES (NIL) when the tile shapes are not compile-time known, or when a ring's load sites
   do not agree on one global source, which the walk then reports through its existing error."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored shape))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     ;; A staged operand's K is its own column extent.  A DIRECT global operand
                     ;; has runtime extents, and the forward reads exactly one native K-step
                     ;; from it, so its Kt is the instruction's K.
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg)))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (if (and (not ringp) (%mma-vjp-mma-admissible-p mt nt kt))
                    (%mma-via-tile-backward form dims-map src-map inputs outputs
                                            local-adj kernel-pkg)
                    (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                              a-src aoy aox b-src boy box pkg))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)

;;; Ring pipelining, part 2 — comparing load-site origins MODULO the slot index.
;;;
;;; The first cut compared origins componentwise and found TWO differing components where there
;;; should be one.  The reason is that `load-tile` is rewritten to `load-tile-at` with PIXEL
;;; coordinates, and that rewrite embeds the tile expression itself:
;;;
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring (to-ulong i))) 0))   ; prologue
;;;     (* (to-ulong grid-y) (~ (extents~ (ring-get A-ring slot))        0))   ; steady state
;;;
;;; so the SLOT INDEX makes every component differ, including the ones that agree
;;; mathematically.  The slot is scheduling, exactly like the stage origin, so it is normalised
;;; away before comparing and substituted back afterwards from the CONSUMING operand's own
;;; index.  What remains differing is then the genuine stage coordinate, and there is one.
(defvar *ad-ring-slot-marker* '%ad-ring-slot
  "Placeholder standing in for a ring-get index while load-site origins are compared.")

(defun %ad-canon-ring-slots (form marker)
  "Rewrite every `(ring-get R <idx>)` in FORM to `(ring-get R MARKER)`.
   Two load sites of the same ring differ in their slot index by construction — that is what a
   ring IS — so the index must be normalised away before their origins can be compared."
  (cond
    ((and (consp form) (symbolp (car form))
          (string-equal (symbol-name (car form)) "RING-GET"))
      (list (car form) (%ad-canon-ring-slots (second form) marker) marker))
    ((consp form) (mapcar (lambda (f) (%ad-canon-ring-slots f marker)) form))
    (t form)))

(defun %ad-subst-ring-slot (form marker idx)
  "Inverse of %ad-canon-ring-slots: put the consuming operand's own slot index back."
  (cond
    ((and (symbolp form) (eq form marker)) idx)
    ((consp form) (mapcar (lambda (f) (%ad-subst-ring-slot f marker idx)) form))
    (t form)))

(defun %ad-form-merge (a b repl)
  "A copy of A with the ONE subtree where A and B differ replaced by REPL, or :AMBIGUOUS when
   they differ in more than one place.

   Used to turn two load sites' stage coordinates into the CONSUMING one: the sites are
   identical apart from the stage expression, so replacing exactly that with the enclosing loop
   variable yields the coordinate at which the slot is actually read."
  (cond
    ((equal a b) a)
    ((and (consp a) (consp b) (= (length a) (length b)))
      (let ((diffs (loop for x in a for y in b count (not (equal x y)))))
        (if (> diffs 1)
            :ambiguous
            (let ((merged (loop for x in a for y in b
                                collect (if (equal x y) x (%ad-form-merge x y repl)))))
              (if (find :ambiguous merged) :ambiguous merged)))))
    (t repl)))

(defun %ad-reconcile-ring-origin (sites k-var &optional slot-idx)
  "Given a ring's load SITES (each (SRC ORIGIN-FORMS)), the innermost enclosing loop variable
   K-VAR at the consuming site, and the consuming operand's own SLOT-IDX, return
   (values SRC ORIGIN) or (values NIL NIL) to decline.

   All sites must name the same GLOBAL SOURCE — that is the operand's identity, and a ring fed
   from two different matrices is genuinely ambiguous.  Origins are compared MODULO the ring
   slot index (see %ad-canon-ring-slots); components that then agree are kept verbatim, and the
   single component that still differs is the pipeline stage, replaced by K-VAR.  Zero differing
   components means an unpipelined ring whose common origin is already right."
  (let* ((marker *ad-ring-slot-marker*)
         (srcs (remove-duplicates (mapcar #'first sites)))
         (origins (mapcar (lambda (s) (%ad-canon-ring-slots (second s) marker)) sites)))
    (cond
      ((/= (length srcs) 1)
        (log:debug "ring origin: declining — ~a distinct sources ~a" (length srcs) srcs)
        (values nil nil))
      ((null origins) (values nil nil))
      ((not (apply #'= (mapcar #'length origins)))
        (log:debug "ring origin: declining — load sites disagree on rank")
        (values nil nil))
      (t
        (let* ((n (length (first origins)))
               (base (first origins))
               (diff (loop for i from 0 below n
                             unless (let ((c (mapcar (lambda (o) (nth i o)) origins)))
                                      (every (lambda (x) (equal x (first c))) c))
                           collect i)))
          (cond
            ((null diff)
              (values (first srcs) (%ad-subst-ring-slot base marker slot-idx)))
            ((> (length diff) 1)
              (log:debug "ring origin: declining — ~a components differ across sites (~a)"
                         (length diff) diff)
              (values nil nil))
            ((null k-var)
              (log:debug "ring origin: declining — no enclosing loop var for the stage component")
              (values nil nil))
            (t
              ;; Merge the differing component across every pair of sites, replacing the stage
              ;; expression with the consuming loop variable.
              (let* ((idx (first diff))
                     (variants (remove-duplicates (mapcar (lambda (o) (nth idx o)) origins)
                                                  :test #'equal))
                     (merged (reduce (lambda (acc v) (if (eq acc :ambiguous)
                                                         :ambiguous
                                                         (%ad-form-merge acc v k-var)))
                                     (rest variants) :initial-value (first variants))))
                (if (eq merged :ambiguous)
                    (progn
                      (log:debug "ring origin: declining — stage component differs in >1 place")
                      (values nil nil))
                    (values (first srcs)
                            (%ad-subst-ring-slot
                             (loop for i from 0 below n
                                   collect (if (= i idx) merged (nth i base)))
                             marker slot-idx)))))))))))

(defun %mma-vjp-operand-ref (op src-map dims-map inputs &optional ring-sites)
  "Resolve an mma-accumulate-via-tile operand to (values SRC OY OX KIND).

     - STAGED  : a scratch tile filled by load-tile-at.  SRC is the ORIGINAL global matrix and
                 (OY OX) the staging origin.
     - DIRECT  : the operand IS a global matrix (a kernel parameter read straight by the
                 fragment loads, as in 132/04-mma-via-tile).  Origin (0 0).
     - :RING   : a `(ring-get R i)` view.  SRC is the single global matrix every load site names;
                 the origin is those sites' agreed components with the stage component replaced
                 by the CONSUMING loop variable (see %ad-reconcile-ring-origin).  A pipelined
                 ring's own load sites record OTHER stages' origins, which is exactly what made
                 this look undifferentiable.

   RING-SITES is the %ad-ring-load-sites alist, threaded from the caller because it needs
   flat-anf.  Absent, ring operands decline, which is the previous behaviour."
  (let ((base (%ad-tile-base op)))
    (cond
      ((and (consp op) base)
        (let ((sites (cdr (assoc base ring-sites))))
          (if (null sites)
              (values nil nil nil nil)
              (multiple-value-bind (src origin)
                  (%ad-reconcile-ring-origin sites (first *ad-loop-vars*) (third op))
                (if (and src origin (= (length origin) 2))
                    (values src (first origin) (second origin) :ring)
                    (values nil nil nil nil))))))
      (t
        (let ((entry (assoc op src-map)))
          (cond
            (entry (values (second entry) (first (third entry)) (second (third entry)) :staged))
            ((and (symbolp op) (member op inputs)) (values op 0 0 :direct))
            ((assoc op dims-map) (values op 0 0 :staged))
            (t (values nil nil nil nil))))))))
