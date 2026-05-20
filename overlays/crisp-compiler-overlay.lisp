;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ============================================================================
;; Endeavor 109 — mod / rem operators.
;;
;; Crisp had `/` for integer/float division but no companion modulo operator.
;; Added here as expansion-based analyzers: (mod x y) and (rem x y) both
;; rewrite to (- x (* (/ x y) y)) via gensym'd let bindings (so x and y are
;; evaluated once even if they're side-effecting expressions).  LLVM's
;; peephole optimisation folds this idiom back to a native srem / urem / frem
;; instruction, so there is no runtime cost.
;;
;; Currently mod and rem have identical semantics — both match C's % and
;; LLVM's srem (sign of result follows the dividend).  This is the variant
;; that matters for GPU coordinate work where operands are non-negative.
;; The two names can be split later if a use case demands the Common-Lisp
;; mod-vs-rem distinction.

;; src/analysis/ops.lisp
(defun analyze-mod-expression (expr env context location)
  "Analyzes (mod x y).  Expands to (- x (* (/ x y) y)) with x and y bound
   to gensyms first, then delegates to analyze-expression.  Works for any
   numeric type via the standard +/-/*/ analyzers."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message (format nil "mod: expected (mod x y), got ~A arg(s)" (1- (length expr)))
           :source-location location))
  (let* ((x-form (second expr))
         (y-form (third expr))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (sub-sym (intern "-" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (div-sym (intern "/" cl-pkg))
         (x-tmp (gensym "MOD-X"))
         (y-tmp (gensym "MOD-Y"))
         (expansion (list let-sym
                          (list (list x-tmp x-form)
                                (list y-tmp y-form))
                          (list sub-sym x-tmp
                                (list mul-sym (list div-sym x-tmp y-tmp) y-tmp)))))
    (analyze-expression expansion env context location)))

;; src/analysis/ops.lisp
(defun analyze-rem-expression (expr env context location)
  "Analyzes (rem x y).  Currently identical to mod — both match C % / LLVM
   srem.  Split semantics later if needed."
  (let* ((x-form (second expr))
         (y-form (third expr))
         (cl-pkg (find-package :crisp-language))
         (mod-sym (intern "MOD" cl-pkg)))
    (analyze-mod-expression (list mod-sym x-form y-form) env context location)))


;; src/analysis/ops.lisp -- whole-function replacement of register-ops-analyzers
;; adding mod and rem registrations.
(defun register-ops-analyzers ()
  "Registers all expression analyzer functions.
Redefined for 082-atomics to add atomic RMW op analyzers.
Endeavor 109: adds mod / rem under both :crisp-language and :crisp.compiler."
  (def-expression-analyzer + analyze-add-expression)
  (def-expression-analyzer - analyze-sub-expression)
  (def-expression-analyzer * analyze-mul-expression)
  (def-expression-analyzer / analyze-div-expression)
  (def-expression-analyzer sin analyze-sin-expression)
  (def-expression-analyzer cos analyze-cos-expression)
  (def-expression-analyzer < analyze-lt-expression)
  (def-expression-analyzer > analyze-gt-expression)
  (def-expression-analyzer <= analyze-le-expression)
  (def-expression-analyzer >= analyze-ge-expression)
  (def-expression-analyzer = analyze-eq-expression)
  (def-expression-analyzer != analyze-neq-expression)

  ;; 082-atomics: register under crisp.compiler package symbols
  (def-expression-analyzer atomic-add!  analyze-atomic-add!-expression)
  (def-expression-analyzer atomic-sub!  analyze-atomic-sub!-expression)
  (def-expression-analyzer atomic-inc!  analyze-atomic-inc!-expression)
  (def-expression-analyzer atomic-dec!  analyze-atomic-dec!-expression)
  (def-expression-analyzer atomic-min!  analyze-atomic-min!-expression)
  (def-expression-analyzer atomic-max!  analyze-atomic-max!-expression)
  (def-expression-analyzer atomic-xchg! analyze-atomic-xchg!-expression)
  (def-expression-analyzer atomic-set!  analyze-atomic-set!-expression)

  ;; 082-atomics: also register under crisp-language package symbols.
  (let ((lang (find-package :crisp-language)))
    (when lang
      (dolist (pair '(("ATOMIC-ADD!"  analyze-atomic-add!-expression)
                      ("ATOMIC-SUB!"  analyze-atomic-sub!-expression)
                      ("ATOMIC-INC!"  analyze-atomic-inc!-expression)
                      ("ATOMIC-DEC!"  analyze-atomic-dec!-expression)
                      ("ATOMIC-MIN!"  analyze-atomic-min!-expression)
                      ("ATOMIC-MAX!"  analyze-atomic-max!-expression)
                      ("ATOMIC-XCHG!" analyze-atomic-xchg!-expression)
                      ("ATOMIC-SET!"  analyze-atomic-set!-expression)))
        (setf (gethash (intern (first pair) lang) *expression-analyzers*)
              (second pair)))))

  ;; 109: mod / rem.  Register under both packages.  In :crisp-language
  ;; these names are fresh symbols (the package :uses nothing).  In
  ;; :crisp.compiler they shadow cl:mod / cl:rem.
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry '(("MOD" . analyze-mod-expression)
                     ("REM" . analyze-rem-expression)))
      (let* ((name (car entry))
             (fn-name (cdr entry))
             (sym-cl (intern name cl-pkg))
             (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) fn-name)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn-name)))))

  (def-expression-analyzer to  analyze-value-cast-expression)
  (def-expression-analyzer as  analyze-generic-as-expression)
  (def-expression-analyzer as-bits analyze-bitcast-expression)
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)

  ;; Register cast operators dynamically
  (log:info "Registering cast operators. *crisp-types* count: ~a" (hash-table-count *crisp-types*))
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (when (symbolp type-name)
          (let* ((type-str (symbol-name type-name))
                 (pkg (symbol-package type-name))
                 (to-name (intern (concatenate 'string "TO-" type-str) pkg))
                 (as-name (intern (concatenate 'string "AS-" type-str) pkg)))
            (log:debug "Registering cast/bitcast: ~s / ~s" to-name as-name)
            (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
            (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression))))

  ;; Float-to-int
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-truncate-expression)
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression))


;; ============================================================================
;; Endeavor 109 — tile-stride (Pass 1: safe + size-list, no helpers yet).
;;
;; Per the chapter doc 14/11 implementation note, the iteration loop for
;; tile-stride is identical to tensor-stride.  The tile spec (size-list or
;; tile-tensor) is only consumed by the helper macros (tile-coords /
;; tile-indices / tensor-coords) which expand inside the body — those are
;; added in Pass 4.  For Pass 1, the analyzer parses the tile-spec for shape
;; validation, ignores it for codegen, and delegates the loop expansion
;; to %expand-tensor-stride-form.
;;
;; Form variants (parsing precedence):
;;   (tile-stride T (SIZE-LIST) (BINDINGS) BODY...)            ; safe + size-list
;;   (tile-stride T <tile-tensor> (BINDINGS) BODY...)          ; safe + tile-tensor (Pass 2)
;;   (tile-stride T :tag (SIZE-LIST) (BINDINGS) BODY...)       ; strict + size-list (Pass 3)
;;   (tile-stride T :tag <tile-tensor> (BINDINGS) BODY...)     ; strict + tile-tensor (Pass 3)

;; src/analysis/control.lisp
(defun %tile-stride-parse (expr)
  "Returns (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
   for a tile-stride EXPR.  TILE-SPEC-KIND is one of :size-list or :tile-tensor.
   Form-shape validation only — does not check arity vs tensor."
  (let* ((tensor-form (second expr))
         (third       (third expr))
         (strict-p    (keywordp third))
         (layout-tag  (when strict-p third))
         (tile-pos    (if strict-p 3 2))
         (tile-spec   (nth tile-pos expr))
         (bind-pos    (1+ tile-pos))
         (bindings    (nth bind-pos expr))
         (body-forms  (nthcdr (1+ bind-pos) expr))
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
    (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)))

;; src/analysis/control.lisp
;;
;; Pass 4: helper macro rewriter.
;;
;; tile-coords / tile-indices / tensor-coords are source-level macros that
;; are scoped to the tile-stride body.  Since Crisp has no first-class
;; (values ...) form, we rewrite their uses at expansion time:
;;
;;   (let ((a b (tile-coords x y)) ...)  →  (let ((a (mod x TY)) (b (mod y TX)) ...))
;;   (let ((a b (tile-indices x y)) ...) →  (let ((a (/ x TY))   (b (/ y TX))   ...))
;;   (let ((a b (tensor-coords (ix iy) (tx ty))) ...)
;;      →  (let ((a (+ (* ix TY) tx)) (b (+ (* iy TX) ty)) ...))
;;
;; In 1D contexts the helpers can also appear as standalone expressions:
;;
;;   (tile-coords i)        →  (mod i T0)
;;   (tile-indices i)       →  (/ i T0)
;;   (tensor-coords (ix) (t)) →  (+ (* ix T0) t)
;;
;; The tile-size-fn argument supplies the per-dim size form (literal int
;; for size-list variants, ulong-extent reads for tile-tensor variants,
;; declared local-size dims for hardware-stride :workgroup-idx, etc.).

(defun %tile-helper-name-p (sym)
  "Returns the helper keyword (:coords :indices :tensor-coords) if SYM is
   a tile-stride helper macro name, else NIL.  Matches by string."
  (when (symbolp sym)
    (let ((n (symbol-name sym)))
      (cond
        ((string-equal n "TILE-COORDS")   :coords)
        ((string-equal n "TILE-INDICES")  :indices)
        ((string-equal n "TENSOR-COORDS") :tensor-coords)
        (t nil)))))

(defun %tile-helper-build-coords (arg-forms tile-size-fn cl-pkg)
  "Builds (mod arg_k TILE_k) forms for tile-coords."
  (let ((mod-sym (intern "MOD" cl-pkg)))
    (loop for arg in arg-forms
          for k from 0
          collect (list mod-sym arg (funcall tile-size-fn k)))))

(defun %tile-helper-build-indices (arg-forms tile-size-fn cl-pkg)
  "Builds (/ arg_k TILE_k) forms for tile-indices."
  (let ((div-sym (intern "/" cl-pkg)))
    (loop for arg in arg-forms
          for k from 0
          collect (list div-sym arg (funcall tile-size-fn k)))))

(defun %tile-helper-build-tensor-coords (idx-forms t-forms tile-size-fn cl-pkg)
  "Builds (+ (* idx_k TILE_k) t_k) forms for tensor-coords."
  (let ((plus-sym (intern "+" cl-pkg))
        (mul-sym  (intern "*" cl-pkg)))
    (unless (= (length idx-forms) (length t-forms))
      (error 'crisp-compiler-error
             :message (format nil "tensor-coords: index list (~A) and coord list (~A) must have same arity"
                              (length idx-forms) (length t-forms))
             :source-location nil))
    (loop for idx in idx-forms
          for tc  in t-forms
          for k from 0
          collect (list plus-sym (list mul-sym idx (funcall tile-size-fn k)) tc))))

(defun %tile-helper-call-expansion (helper-kind helper-args tile-size-fn n-tile cl-pkg)
  "Returns a list of N expansion forms for a helper call, where N matches the
   helper's expected arity.  Caller decides whether to use it in single-value
   position (N=1) or multi-value let-binding (N>1)."
  (case helper-kind
    (:coords
     (unless (= (length helper-args) n-tile)
       (error 'crisp-compiler-error
              :message (format nil "tile-coords: expected ~A argument(s) to match tile arity, got ~A"
                               n-tile (length helper-args))
              :source-location nil))
     (%tile-helper-build-coords helper-args tile-size-fn cl-pkg))
    (:indices
     (unless (= (length helper-args) n-tile)
       (error 'crisp-compiler-error
              :message (format nil "tile-indices: expected ~A argument(s) to match tile arity, got ~A"
                               n-tile (length helper-args))
              :source-location nil))
     (%tile-helper-build-indices helper-args tile-size-fn cl-pkg))
    (:tensor-coords
     (unless (= (length helper-args) 2)
       (error 'crisp-compiler-error
              :message "tensor-coords: expected exactly 2 list arguments (indices and coords)"
              :source-location nil))
     (let ((idx-forms (first  helper-args))
           (t-forms   (second helper-args)))
       (unless (and (listp idx-forms) (listp t-forms))
         (error 'crisp-compiler-error
                :message "tensor-coords: both arguments must be lists, e.g. (tensor-coords (idx-y idx-x) (t-y t-x))"
                :source-location nil))
       (unless (= (length idx-forms) n-tile)
         (error 'crisp-compiler-error
                :message (format nil "tensor-coords: index list has ~A element(s), expected ~A"
                                 (length idx-forms) n-tile)
                :source-location nil))
       (%tile-helper-build-tensor-coords idx-forms t-forms tile-size-fn cl-pkg)))))

(defun %tile-helpers-rewrite (body-forms n-tile tile-size-fn)
  "Walks BODY-FORMS and rewrites tile-coords / tile-indices / tensor-coords
   calls.  Multi-value uses in let-bindings (flat MVB form) become multiple
   single-value bindings; standalone single-value uses are replaced inline.
   N-TILE is the stride/tile arity; TILE-SIZE-FN takes dim index k and
   returns a Crisp form for that dim's tile size."
  (let ((cl-pkg (find-package :crisp-language)))
    (labels ((walk-form (form)
               (cond
                 ((atom form) form)
                 ((not (consp form)) form)
                 ((and (symbolp (car form))
                       (let ((n (symbol-name (car form))))
                         (or (string-equal n "LET")
                             (string-equal n "LET*"))))
                  (walk-let form))
                 (t
                  ;; Detect helper call OR walk subforms.  Done as a single
                  ;; default clause to avoid a `cond` test-only quirk in the
                  ;; crisp.compiler `cond` macro (simplified vs cl:cond).
                  (let ((kind (%tile-helper-name-p (car form))))
                    (if kind
                        ;; Standalone helper expression: must be single-value.
                        (let ((expanded (%tile-helper-call-expansion
                                         kind (cdr form) tile-size-fn n-tile cl-pkg)))
                          (if (= (length expanded) 1)
                              (walk-form (first expanded))
                              (error 'crisp-compiler-error
                                     :message (format nil "~A used in single-value context but stride is multi-dim — use in a multi-value let binding"
                                                      (symbol-name (car form)))
                                     :source-location nil)))
                        (mapcar #'walk-form form))))))
             (walk-let (form)
               (let* ((binding-forms (second form))
                      (body-forms-let (cddr form))
                      (new-bindings (mapcan #'rewrite-binding binding-forms))
                      (new-body (mapcar #'walk-form body-forms-let)))
                 `(,(first form) ,new-bindings ,@new-body)))
             (rewrite-binding (binding)
               ;; binding shapes (from analyze-let-expression):
               ;;   flat MVB:           (var1 var2 ... varN init)   ; len > 2, first is symbol
               ;;   group MVB:          ((var1 ... varN) init)      ; first is a list
               ;;   single:             (var init)                  ; len 2, first is symbol
               (cond
                 ;; Flat MVB
                 ((and (> (length binding) 2)
                       (symbolp (first binding)))
                  (let* ((vars (butlast binding))
                         (init (car (last binding)))
                         (helper-kind (and (consp init) (%tile-helper-name-p (car init)))))
                    (if helper-kind
                        (let ((expanded (%tile-helper-call-expansion
                                         helper-kind (cdr init) tile-size-fn n-tile cl-pkg)))
                          (unless (= (length vars) (length expanded))
                            (error 'crisp-compiler-error
                                   :message (format nil "~A: ~A binding(s) vs ~A return value(s)"
                                                    (symbol-name (car init))
                                                    (length vars) (length expanded))
                                   :source-location nil))
                          (loop for v in vars
                                for e in expanded
                                collect (list v (walk-form e))))
                        ;; Not a helper init — walk it and keep as flat MVB
                        (list (append vars (list (walk-form init)))))))
                 ;; Group MVB
                 ((and (= (length binding) 2)
                       (listp (first binding)))
                  (let* ((vars (first binding))
                         (init (second binding))
                         (helper-kind (and (consp init) (%tile-helper-name-p (car init)))))
                    (if helper-kind
                        (let ((expanded (%tile-helper-call-expansion
                                         helper-kind (cdr init) tile-size-fn n-tile cl-pkg)))
                          (unless (= (length vars) (length expanded))
                            (error 'crisp-compiler-error
                                   :message (format nil "~A: ~A binding(s) vs ~A return value(s)"
                                                    (symbol-name (car init))
                                                    (length vars) (length expanded))
                                   :source-location nil))
                          (loop for v in vars
                                for e in expanded
                                collect (list v (walk-form e))))
                        (list (list vars (walk-form init))))))
                 ;; Single binding
                 ((= (length binding) 2)
                  (let* ((var (first binding))
                         (init (second binding))
                         (helper-kind (and (consp init) (%tile-helper-name-p (car init)))))
                    (if helper-kind
                        (let ((expanded (%tile-helper-call-expansion
                                         helper-kind (cdr init) tile-size-fn n-tile cl-pkg)))
                          (unless (= (length expanded) 1)
                            (error 'crisp-compiler-error
                                   :message (format nil "~A returns ~A values but bound to a single variable"
                                                    (symbol-name (car init)) (length expanded))
                                   :source-location nil))
                          (list (list var (walk-form (first expanded)))))
                        (list (list var (walk-form init))))))
                 (t (list binding)))))
      (mapcar #'walk-form body-forms))))

;; src/analysis/control.lisp
(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   For the stride loop, tile-stride is identical to tensor-stride.  Pass 4:
   the body is first walked to rewrite tile-stride helper macros (tile-coords,
   tile-indices, tensor-coords) using the tile spec as the per-dim size source."
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore layout-tag))
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed tile-stride: expected (tile-stride TENSOR [LAYOUT-TAG] <TILE-SPEC> (BINDING ...) BODY...)"
             :source-location location))
    (let* ((n-tile (length bindings))
           (cl-pkg (find-package :crisp-language))
           ;; Build the per-dim tile-size form supplier.
           ;; Stride binding values are ulong (per tensor-stride coord decode),
           ;; so size forms must also be ulong to keep arithmetic type-consistent.
           ;; For size-list (int literals) we wrap in (to-ulong ...).  For
           ;; tile-tensor (extents read), the values are already ulong.
           (tile-size-fn
            (ecase tile-spec-kind
              (:size-list
               (let ((sizes tile-spec)
                     (to-ulong-sym (intern "TO-ULONG" cl-pkg)))
                 (lambda (k) (list to-ulong-sym (nth k sizes)))))
              (:tile-tensor
               (let ((aref-sym    (intern "~" cl-pkg))
                     (extents-sym (intern "EXTENTS~" cl-pkg))
                     (tile-form   tile-spec))
                 (lambda (k)
                   (list aref-sym (list extents-sym tile-form) k))))))
           (rewritten-body (%tile-helpers-rewrite body-forms n-tile tile-size-fn))
           (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
           (synth  (if strict-p
                       (cons ts-sym (cons tensor-form (cons (third expr) (cons bindings rewritten-body))))
                       (cons ts-sym (cons tensor-form (cons bindings rewritten-body))))))
      (%expand-tensor-stride-form synth ct location))))

;; src/analysis/control.lisp
(defun analyze-tile-stride-expression (expr env context location)
  "Analyzes (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Validates tensor-arity-vs-bindings and tile-arity-vs-bindings, then
   delegates codegen via %expand-tile-stride-form."
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore layout-tag body-forms))
    (let* ((env-resolver
            (lambda (sym)
              (when (symbolp sym)
                (handler-case
                    (let ((node (analyze-expression sym env context (append location '(1)))))
                      (semantic-node-type node))
                  (error () nil)))))
           (cl-pkg (find-package :crisp-language))
           (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
           (synth-for-ct (if strict-p
                             (list ts-sym tensor-form (third expr) bindings)
                             (list ts-sym tensor-form bindings)))
           (ct (%tensor-stride-resolve-ct synth-for-ct env-resolver location))
           (n (length bindings))
           (canon (and (symbolp tensor-form)
                       (let ((ty (funcall env-resolver tensor-form)))
                         (and ty (%ts-canonicalize-tensor-type ty)))))
           (declared-n (when (and (listp canon) (>= (length canon) 3))
                         (third canon))))
      (when (and (integerp declared-n) (/= declared-n n))
        (error 'crisp-compiler-error
               :message (format nil
                                "tile-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                                declared-n n)
               :source-location location))
      (when (and (eq tile-spec-kind :size-list)
                 (/= (length tile-spec) n))
        (error 'crisp-compiler-error
               :message (format nil
                                "tile-stride: tile size-list has ~A dimension(s) but tensor has ~A dimension(s)"
                                (length tile-spec) n)
               :source-location location))
      (analyze-expression (%expand-tile-stride-form expr ct location)
                          env context location))))


;; src/analysis/control.lisp -- whole-function replacement of register-control-analyzers,
;; adding tile-stride registration (109 Pass 1).
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride,
   tensor-stride (105), grid-stride (105), and tile-stride (109)."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression)))
  (let ((sym-cl (intern "LOOP-VECTOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "LOOP-VECTOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-loop-vector-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-loop-vector-stride-expression)))
  (let ((sym-cl (intern "TENSOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TENSOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tensor-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tensor-stride-expression)))
  (let ((sym-cl (intern "GRID-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "GRID-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-grid-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-grid-stride-expression)))
  (let ((sym-cl (intern "TILE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TILE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tile-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tile-stride-expression)))
  ;; 109 Passes 5-7: hardware-stride
  (let ((sym-cl (intern "HARDWARE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "HARDWARE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-hardware-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-hardware-stride-expression))))


;; src/macros.lisp -- extend AD pre-pass to expand tile-stride too (109 Pass 1).
(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites tensor-stride / grid-stride /
   loop-vector-stride / tile-stride forms into their expansions."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%expand-stride-macros-in-form sub type-resolver-fn location)) form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "TENSOR-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (ct (%tensor-stride-resolve-ct walked type-resolver-fn location)))
            (%expand-tensor-stride-form walked ct location)))
         ((string-equal op-name "GRID-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-grid-stride-form walked location)))
         ((string-equal op-name "LOOP-VECTOR-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-loop-vector-stride-form walked location)))
         ((string-equal op-name "TILE-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (cl-pkg (find-package :crisp-language))
                 (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
                 (strict-p (keywordp (third walked)))
                 (tile-pos (if strict-p 3 2))
                 (bindings (nth (1+ tile-pos) walked))
                 (synth-for-ct (if strict-p
                                   (list ts-sym (second walked) (third walked) bindings)
                                   (list ts-sym (second walked) bindings)))
                 (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
            (%expand-tile-stride-form walked ct location)))
         ((string-equal op-name "HARDWARE-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (cl-pkg (find-package :crisp-language))
                 (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
                 ;; Detect strict variant: 3rd is layout-tag, 4th is hw-tag.
                 (third (third walked))
                 (strict-p (and (keywordp third)
                                (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
                 (hw-pos (if strict-p 3 2))
                 (bindings (nth (1+ hw-pos) walked))
                 (synth-for-ct (if strict-p
                                   (list ts-sym (second walked) (third walked) bindings)
                                   (list ts-sym (second walked) bindings)))
                 (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
            (%expand-hardware-stride-form walked ct location)))
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                        (cdr form)))))))))


;; ============================================================================
;; Endeavor 109 — hardware-stride (Passes 5-7).
;;
;; hardware-stride chunks the iteration by workgroup (:workgroup-idx) or by
;; warp (:warp-idx).  Per the chapter doc implementation note, the actual
;; stride loop is identical to tensor-stride; chunking only changes the
;; tile-size source consumed by the helper macros:
;;
;;   :workgroup-idx → tile size per dim = (get-local-work-size k)
;;   :warp-idx      → tile size = warp size; binding count must be 1
;;                     (warp iteration is always linear over the flattened
;;                      global execution space, regardless of global-size arity)
;;
;; Form variants:
;;   (hardware-stride T <HW-TAG> (BINDINGS) BODY...)             ; safe
;;   (hardware-stride T <LAYOUT-TAG> <HW-TAG> (BINDINGS) BODY...) ; strict
;;
;; Note: :warp-idx currently uses (to-ulong 32) as a placeholder for the warp
;; size.  When (get-warp-size) is added (SPIR-V SubgroupSize builtin), this
;; should switch to the real runtime call.  The placeholder is correct on
;; NVIDIA and Intel GPUs, incorrect on AMD (warp size 64).

;; src/analysis/control.lisp
(defun %hardware-stride-parse (expr)
  "Returns (values strict-p layout-tag hw-tag bindings body-forms tensor-form)
   for a hardware-stride EXPR.  Form-shape validation only — does not check
   arity vs tensor."
  (let* ((tensor-form (second expr))
         (third       (third expr))
         (strict-p    (and (keywordp third)
                           (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
         (layout-tag  (when strict-p third))
         (hw-tag-pos  (if strict-p 3 2))
         (hw-tag      (nth hw-tag-pos expr))
         (bind-pos    (1+ hw-tag-pos))
         (bindings    (nth bind-pos expr))
         (body-forms  (nthcdr (1+ bind-pos) expr)))
    (unless (member hw-tag '(:workgroup-idx :warp-idx))
      (error 'crisp-compiler-error
             :message (format nil "hardware-stride: unknown hw-tag ~S (expected :workgroup-idx or :warp-idx)" hw-tag)
             :source-location nil))
    (values strict-p layout-tag hw-tag bindings body-forms tensor-form)))

;; src/analysis/control.lisp
;;
;; Custom expansion for :warp-idx.  Unlike :workgroup-idx (which can delegate
;; to tensor-stride because dim-0 iteration aligns with single-dim global-size),
;; :warp-idx must iterate linearly over the FLATTENED global execution space.
;; This matters when global-size has arity > 1 — tensor-stride's gid/gsize
;; would only see dim 0, missing the rest of the enqueue.
(defun %expand-warp-idx-form (tensor-form bindings body-forms location)
  "Linear-flatten expansion for hardware-stride :warp-idx.  Always 1 binding."
  (declare (ignore location))
  (let* ((var-name (first bindings))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (k-sym (gensym "K"))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (if-sym (intern "IF" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-glid-sym   (intern "GET-GLOBAL-LINEAR-ID"   cl-pkg))
         (get-glsize-sym (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (len-tilde-sym  (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (lt-sym   (intern "<" cl-pkg))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-if  (list if-sym (list lt-sym var-name len-sym) inner-body))
         (inner-let (list let-sym
                          (list (list var-name (list plus-sym k-sym gid-sym)))
                          inner-if))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym gsize-sym)
                             inner-let))
         (expansion (list let-sym
                          (list (list gid-sym   (list get-glid-sym))
                                (list gsize-sym (list get-glsize-sym))
                                (list len-sym   (list len-tilde-sym tensor-form)))
                          (list declare-sym (list grid-level-sym))
                          dotimes-form)))
    expansion))

;; src/analysis/control.lisp
(defun %expand-hardware-stride-form (expr ct location)
  "Pure expansion of (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).
   Rewrites helper macros using the hw-tag-derived tile-size source, then
   dispatches by hw-tag:
     :workgroup-idx delegates to tensor-stride (chunking is implicit in the
                    workgroup scheduler; same N-D stride loop)
     :warp-idx      uses a custom linear-flatten expansion over the
                    global execution space (always 1 binding)."
  (multiple-value-bind (strict-p layout-tag hw-tag bindings body-forms tensor-form)
      (%hardware-stride-parse expr)
    (unless (and (listp bindings) (every #'symbolp bindings) (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed hardware-stride: expected (hardware-stride TENSOR [LAYOUT-TAG] <HW-TAG> (BINDING ...) BODY...)"
             :source-location location))
    (when (and (eq hw-tag :warp-idx) (/= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "hardware-stride :warp-idx must have exactly 1 binding — warp iteration is always linear over the flattened global execution space"
             :source-location location))
    (let* ((n-tile (length bindings))
           (cl-pkg (find-package :crisp-language))
           (tile-size-fn
            (ecase hw-tag
              (:workgroup-idx
               (let ((get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg)))
                 (lambda (k) (list get-lws-sym k))))
              (:warp-idx
               ;; Placeholder: should be (get-warp-size) once available.
               (let ((to-ulong-sym (intern "TO-ULONG" cl-pkg)))
                 (lambda (k) (declare (ignore k)) (list to-ulong-sym 32))))))
           (rewritten-body (%tile-helpers-rewrite body-forms n-tile tile-size-fn)))
      (ecase hw-tag
        (:workgroup-idx
         (let* ((ts-sym (intern "TENSOR-STRIDE" cl-pkg))
                (synth  (if strict-p
                            (cons ts-sym (cons tensor-form (cons layout-tag (cons bindings rewritten-body))))
                            (cons ts-sym (cons tensor-form (cons bindings rewritten-body))))))
           (%expand-tensor-stride-form synth ct location)))
        (:warp-idx
         ;; Layout-tag (if present) is irrelevant under :warp-idx — iteration
         ;; is already linear, so CT-driven decode doesn't apply.  Accepted
         ;; at parse time for syntactic regularity, dropped here.
         (%expand-warp-idx-form tensor-form bindings rewritten-body location))))))

;; src/analysis/control.lisp
(defun analyze-hardware-stride-expression (expr env context location)
  "Analyzes (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).
   Validates arity (:warp-idx must be 1 binding, :workgroup-idx must match
   tensor arity) and delegates codegen via %expand-hardware-stride-form."
  (multiple-value-bind (strict-p layout-tag hw-tag bindings body-forms tensor-form)
      (%hardware-stride-parse expr)
    (declare (ignore layout-tag body-forms))
    (let* ((env-resolver
            (lambda (sym)
              (when (symbolp sym)
                (handler-case
                    (let ((node (analyze-expression sym env context (append location '(1)))))
                      (semantic-node-type node))
                  (error () nil)))))
           (cl-pkg (find-package :crisp-language))
           (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
           (synth-for-ct (if strict-p
                             (list ts-sym tensor-form (third expr) bindings)
                             (list ts-sym tensor-form bindings)))
           (ct (%tensor-stride-resolve-ct synth-for-ct env-resolver location))
           (n (length bindings))
           (canon (and (symbolp tensor-form)
                       (let ((ty (funcall env-resolver tensor-form)))
                         (and ty (%ts-canonicalize-tensor-type ty)))))
           (declared-n (when (and (listp canon) (>= (length canon) 3))
                         (third canon))))
      (when (and (eq hw-tag :warp-idx) (/= n 1))
        (error 'crisp-compiler-error
               :message "hardware-stride :warp-idx must have exactly 1 binding — warp iteration is always linear over the flattened global execution space"
               :source-location location))
      (when (and (eq hw-tag :workgroup-idx)
                 (integerp declared-n) (/= declared-n n))
        (error 'crisp-compiler-error
               :message (format nil
                                "hardware-stride :workgroup-idx: tensor has ~A dimension(s) but ~A binding(s) provided"
                                declared-n n)
               :source-location location))
      (analyze-expression (%expand-hardware-stride-form expr ct location)
                          env context location))))

