;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; =============================================================================
;; 082-atomics: Analysis helpers
;; src/analysis/ops.lisp
;; =============================================================================

(defun %analyze-atomic-rmw-expression (op expr env context location &key no-delta)
  "Shared helper for all atomic RMW analyzers.
OP is a keyword (:add :sub :min :max :xchg).
Target (second element of EXPR) must be an aref expression like (~ vec idx).
When NO-DELTA is T (for atomic-inc!/atomic-dec!), synthesizes a literal-1 delta."
  ;; Validate argument count: inc!/dec! take 1 arg (target only); others take 2 (target + delta).
  (let ((expected-args (if no-delta 1 2))
        (actual-args   (1- (length expr))))
    (unless (= actual-args expected-args)
      (error 'crisp-type-error
        :message (format nil "~a: expected ~a argument~:p, got ~a"
                         (first expr) expected-args actual-args)
        :source-location location)))
  (let* ((target-form (second expr))
         (target-node (analyze-expression target-form env context (append location '(1)))))
    (unless (semantic-aref-p target-node)
      (error 'crisp-type-error
        :message (format nil "~a: target must be a memory location like (~~ vec idx), got ~a"
                         (first expr) target-form)
        :source-location location))
    (let* ((elem-type  (semantic-aref-type target-node))
           (delta-node (if no-delta
                           ;; inc!/dec! synthesize a literal 1 of the appropriate type
                           (let* ((ct  (gethash elem-type *crisp-types*))
                                  (one (if (and ct (eq (crisp-type-category ct) :float))
                                           1.0d0 1)))
                             (make-semantic-literal :value-type elem-type
                                                    :value one
                                                    :source-location location))
                           ;; regular: analyze the delta argument
                           (analyze-expression (third expr) env context
                                               (append location '(2))))))
      (make-semantic-atomic-rmw :type elem-type
                                :op op
                                :target-node target-node
                                :delta-node delta-node
                                :source-location location))))

(defun analyze-atomic-add!-expression (expr env context location)
  "Analyzes (atomic-add! target delta) — atomic fetch-and-add."
  (%analyze-atomic-rmw-expression :add expr env context location))

(defun analyze-atomic-sub!-expression (expr env context location)
  "Analyzes (atomic-sub! target delta) — atomic fetch-and-subtract."
  (%analyze-atomic-rmw-expression :sub expr env context location))

(defun analyze-atomic-inc!-expression (expr env context location)
  "Analyzes (atomic-inc! target) — atomic increment by 1."
  (%analyze-atomic-rmw-expression :add expr env context location :no-delta t))

(defun analyze-atomic-dec!-expression (expr env context location)
  "Analyzes (atomic-dec! target) — atomic decrement by 1."
  (%analyze-atomic-rmw-expression :sub expr env context location :no-delta t))

(defun analyze-atomic-min!-expression (expr env context location)
  "Analyzes (atomic-min! target val) — atomic fetch-and-min."
  (%analyze-atomic-rmw-expression :min expr env context location))

(defun analyze-atomic-max!-expression (expr env context location)
  "Analyzes (atomic-max! target val) — atomic fetch-and-max."
  (%analyze-atomic-rmw-expression :max expr env context location))

(defun analyze-atomic-xchg!-expression (expr env context location)
  "Analyzes (atomic-xchg! target new-val) — atomic exchange."
  (%analyze-atomic-rmw-expression :xchg expr env context location))

(defun analyze-atomic-set!-expression (expr env context location)
  "Analyzes (atomic-set! target new-val) — alias for atomic-xchg!."
  (%analyze-atomic-rmw-expression :xchg expr env context location))


;; =============================================================================
;; 082-atomics: ANF transform — treat atomic-op first arg as a place, not a value
;; src/anf-transform.lisp
;; =============================================================================

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


;; =============================================================================
;; 082-atomics: Register all atomic op analyzers
;; src/analysis/ops.lisp — register-ops-analyzers redef
;; =============================================================================

(defun register-ops-analyzers ()
  "Registers all expression analyzer functions.
Redefined for 082-atomics to add atomic RMW op analyzers."
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
  ;; Source files are read in crisp-language context, so atomic-add! etc.
  ;; from source are crisp-language::atomic-add!, not crisp.compiler::atomic-add!.
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


;; =============================================================================
;; 082-atomics: semantic-node-type — add semantic-atomic-rmw case
;; src/analysis/core.lisp
;; =============================================================================

(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
Extended for 082-atomics to handle semantic-atomic-rmw."
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    ;; 078 view constructors
    (semantic-make-view (semantic-make-view-type node))
    ;; 082 atomic RMW — returns the old value (same type as the element)
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))))


;; =============================================================================
;; 082-atomics: semantic-node-source-location — add semantic-atomic-rmw case
;; src/analysis/core.lisp
;; =============================================================================

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
Extended for 082-atomics to handle semantic-atomic-rmw."
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    ;; 078 view constructors
    (semantic-make-view (semantic-make-view-source-location node))
    ;; 082 atomic RMW
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))))


;; =============================================================================
;; 082-atomics: codegen for semantic-atomic-rmw
;; src/codegen.lisp
;; =============================================================================

(defmethod generate-node-ir ((node semantic-atomic-rmw) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for atomic RMW operations (atomic-add!, atomic-sub!, etc.).
Returns the old value at the target location (fetch-and-op semantics).
LLVM AtomicRMWBinOp enum: xchg=0 add=1 sub=2 max=7 min=8 umax=9 umin=10
                           fadd=11 fsub=12 fmax=13 fmin=14
LLVMAtomicOrdering SequentiallyConsistent = 7"
  (let* ((target-aref     (semantic-atomic-rmw-target-node node))
         (delta-node      (semantic-atomic-rmw-delta-node node))
         (op              (semantic-atomic-rmw-op node))
         (elem-type       (semantic-atomic-rmw-type node))
         (elem-crisp-type (gethash elem-type *crisp-types*))
         (is-float        (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :float)))
         (is-unsigned     (and elem-crisp-type
                               (eq (crisp-type-category elem-crisp-type) :unsigned-int))))

    ;; Get the GEP pointer from the target aref (3rd return value)
    (multiple-value-bind (aref-val aref-loc ptr)
        (generate-node-ir target-aref builder module var-env di-builder di-scope location-map)
      (declare (ignore aref-val aref-loc))
      (unless ptr
        (error "Compiler error in atomic RMW: target ~a did not produce an address pointer"
               target-aref))

      ;; Compute the delta value
      (let* ((delta-raw (generate-node-ir delta-node builder module var-env
                                          di-builder di-scope location-map))
             (delta-val (extract-primary-value builder delta-raw elem-type))
             ;; Select the LLVM RMW opcode
             ;; Inline integer literals avoid defconstant redefinition issues in overlays.
             (rmw-op (ecase op
                       (:add  (if is-float 11 1))   ;; fadd=11, add=1
                       (:sub  (if is-float 12 2))   ;; fsub=12, sub=2
                       (:min  (cond (is-float 14)   ;; fmin=14
                                    (is-unsigned 10) ;; umin=10
                                    (t 8)))          ;; min=8 (signed)
                       (:max  (cond (is-float 13)   ;; fmax=13
                                    (is-unsigned 9)  ;; umax=9
                                    (t 7)))          ;; max=7 (signed)
                       (:xchg 0))))                 ;; xchg=0

        (log:info "atomic-rmw: op=~a elem-type=~a is-float=~a is-unsigned=~a rmw-op=~a"
                  op elem-type is-float is-unsigned rmw-op)

        (let ((result (crisp.llvm-bindings::llvm-build-atomic-rmw
                       builder rmw-op ptr delta-val
                       7  ;; LLVMAtomicOrderingSequentiallyConsistent
                       0))) ;; single-thread=0 (multi-threaded GPU)
          (values result nil))))))


;; =============================================================================
;; 082-atomics: AD backward pass — use atomic-add! for tensor gradient accumulation
;; src/autodiff.lisp — %handle-single-value-backward redef
;; =============================================================================

(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr).
TENSOR-INPUTS-HT, when provided, maps kernel-input symbols to their types for
tensor inputs. When (~ src idx...) is encountered and src has an entry in this
table, gradient accumulation is emitted as atomic-add! (atomicrmw fadd) to
avoid race conditions in parallel GPU threads (082-atomics)."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (cond
      ;; Primitive: +
      ((and (consp expr) (eq (car expr) '+))
        (let ((a (cadr expr)) (b (caddr expr)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
      ;; Primitive: -
      ((and (consp expr) (eq (car expr) '-))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
      ;; Primitive: *
      ((and (consp expr) (eq (car expr) '*))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
      ;; Primitive: /
      ((and (consp expr) (eq (car expr) '/))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
      ;; Primitive: sin
      ((and (consp expr) (eq (car expr) 'sin))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
              (setf (gethash cos-a adjoint-map) cos-a)
              (emit `(set! ,cos-a (cos ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
      ;; Primitive: cos
      ((and (consp expr) (eq (car expr) 'cos))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
              (setf (gethash sin-a adjoint-map) sin-a)
              (emit `(set! ,sin-a (sin ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
      ;; Cell or tensor read: ~
      ;; Distinguishes by index count:
      ;;   (~ src)          → cell read  → scalar adjoint accumulation (existing)
      ;;   (~ src idx...)   → tensor read → atomic gradient accumulation (082-atomics)
      ((and (consp expr) (eq (car expr) '~))
        (let* ((src     (cadr expr))
               (indices (cddr expr))
               (v-adj   (local-adj v)))
          (when (symbolp src)
            (cond
              ;; Tensor read with a known kernel input: emit atomic gradient accumulation.
              ;; atomic-add! avoids the race condition in the non-atomic set!+fadd pattern.
              ((and indices tensor-inputs-ht (gethash src tensor-inputs-ht))
               (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                       (symbol-package src))))
                 (emit `(atomic-add! (~ ,grad-sym ,@indices) ,v-adj))))
              ;; Cell read (no indices) or tensor not in known inputs: scalar adjoint path.
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
      ;; Struct accessor (name ends in ~): treat like identity.
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~))))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
      ;; Comparison/boolean ops: skip
      ((and (consp expr) (symbolp (car expr))
            (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
       nil)
      ;; If form: skip
      ((and (consp expr) (symbolp (car expr))
            (string= (symbol-name (car expr)) "IF"))
       nil)
      ;; System/integer-conversion functions: skip silently
      ((and (consp expr) (symbolp (car expr))
            (%backward-skip-fn-p (car expr)))
       nil)
      ;; Unknown user function
      ((and (consp expr) (symbolp (car expr)))
       (when error-on-unknown
         (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
      ;; Other
      (t nil))))


;; =============================================================================
;; 082-atomics: validator for test 10 (tensor AD backward uses atomicrmw)
;; src/metadata-val.lisp
;; =============================================================================

;; =============================================================================
;; 082-atomics: per-opcode IR validators for tests 01-09
;; src/metadata-val.lisp
;; =============================================================================

(defun validate-atomicrmw-add (ir-path)
  "Verifies atomicrmw add (integer fetch-and-add) is present in the IR.
Used by: 01-atomic-add-cell, 03-atomic-inc-cell."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-add: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-add nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw add" ir)
        (progn (log:error "validate-atomicrmw-add: 'atomicrmw add' not found in IR") nil))))

(defun validate-atomicrmw-sub (ir-path)
  "Verifies atomicrmw sub (integer fetch-and-sub) is present in the IR.
Used by: 02-atomic-sub-cell, 04-atomic-dec-cell."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-sub: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-sub nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw sub" ir)
        (progn (log:error "validate-atomicrmw-sub: 'atomicrmw sub' not found in IR") nil))))

(defun validate-atomicrmw-min (ir-path)
  "Verifies atomicrmw min (signed integer fetch-and-min) is present in the IR.
Used by: 05-atomic-min-cell."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-min: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-min nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw min" ir)
        (progn (log:error "validate-atomicrmw-min: 'atomicrmw min' not found in IR") nil))))

(defun validate-atomicrmw-max (ir-path)
  "Verifies atomicrmw max (signed integer fetch-and-max) is present in the IR.
Used by: 06-atomic-max-cell."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-max: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-max nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw max" ir)
        (progn (log:error "validate-atomicrmw-max: 'atomicrmw max' not found in IR") nil))))

(defun validate-atomicrmw-xchg (ir-path)
  "Verifies atomicrmw xchg (unconditional exchange) is present in the IR.
Used by: 07-atomic-xchg-cell, 09-atomic-set-alias."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-xchg: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-xchg nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw xchg" ir)
        (progn (log:error "validate-atomicrmw-xchg: 'atomicrmw xchg' not found in IR") nil))))

(defun validate-atomicrmw-fadd (ir-path)
  "Verifies atomicrmw fadd (float fetch-and-add) is present in the IR.
Used by: 08-atomic-add-float."
  (unless (probe-file ir-path)
    (log:error "validate-atomicrmw-fadd: IR file not found: ~a" ir-path)
    (return-from validate-atomicrmw-fadd nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (or (search "atomicrmw fadd" ir)
        (progn (log:error "validate-atomicrmw-fadd: 'atomicrmw fadd' not found in IR") nil))))

(defun validate-tensor-ad-atomic (ir-path)
  "Validates that tensor gradient accumulation in the backward kernel uses atomicrmw fadd.
Checks:
  - tensor_ad_atomic_grad function is defined
  - atomicrmw instruction is present (atomic gradient accumulation)
  - idx_GRAD is NOT present (integer index is non-differentiable)"
  (unless (probe-file ir-path)
    (log:error "validate-tensor-ad-atomic: IR file not found: ~a" ir-path)
    (return-from validate-tensor-ad-atomic nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "tensor_ad_atomic_grad" ir)
         (progn (log:error "validate-tensor-ad-atomic: tensor_ad_atomic_grad function not found") nil))
     (or (search "atomicrmw" ir)
         (progn (log:error "validate-tensor-ad-atomic: atomicrmw not found (expected atomic gradient accumulation)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-tensor-ad-atomic: idx_GRAD should not be emitted (integer index is non-differentiable)") nil))
     (progn (log:info "validate-tensor-ad-atomic: PASS") t))))
