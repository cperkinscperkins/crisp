;;; src/analysis/ops.lisp
(in-package :crisp.compiler)

;; --- #'(...) Syntax Parsers ---

;; Redefine the macro with :device-vector added to the category whitelist,
;; then re-expand all four binary ops so the new check takes effect.
(defmacro def-binary-op-analyzer (name node-constructor op-string)
  `(defun ,name (expr env context location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node (analyze-expression (second expr) env context (append location '(1))))
            (right-node (analyze-expression (third expr) env context (append location '(2))))
            (left-type (get-single-value-type left-node))
            (right-type (get-single-value-type right-node))
            (promoted-type (get-promoted-type left-type right-type)))

       (if promoted-type
           (let ((result-crisp-type (gethash promoted-type *crisp-types*)))
             ;; Ensure the resulting type is numeric and supports the op.
             (unless (and result-crisp-type (member (crisp-type-category result-crisp-type)
                                                    '(:signed-int :unsigned-int :float :device-vector)))
               (error 'crisp-type-error
                 :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
                 :source-location location))
             (,node-constructor :type promoted-type :left-arg left-node :right-arg right-node :source-location location))
           (error 'crisp-type-error
             :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
             :source-location location)))))

(def-binary-op-analyzer analyze-add-expression make-semantic-add "+")
(def-binary-op-analyzer analyze-sub-expression make-semantic-sub "-")
(def-binary-op-analyzer analyze-mul-expression make-semantic-mul "*")
(def-binary-op-analyzer analyze-div-expression make-semantic-div "/")

(defmacro def-unary-math-analyzer (name node-constructor op-string)
  `(defun ,name (expr env context location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((arg-node (analyze-expression (second expr) env context (append location '(1))))
            (arg-type (get-single-value-type arg-node))
            (crisp-type (gethash arg-type *crisp-types*)))
       (unless (and crisp-type (eq (crisp-type-category crisp-type) :float))
         (error 'crisp-type-error
           :message (format nil "Type mismatch for operator '~a'. Expected float, got ~a." ,op-string arg-type)
           :source-location location))
       (,node-constructor :type arg-type :arg arg-node :source-location location))))

(def-unary-math-analyzer analyze-sin-expression make-semantic-sin "sin")
(def-unary-math-analyzer analyze-cos-expression make-semantic-cos "cos")
;; Endeavor 128: transcendentals (unary).
(def-unary-math-analyzer analyze-exp-expression  make-semantic-exp  "exp")
(def-unary-math-analyzer analyze-log-expression  make-semantic-log  "log")
(def-unary-math-analyzer analyze-log2-expression make-semantic-log2 "log2")
(def-unary-math-analyzer analyze-tan-expression  make-semantic-tan  "tan")
(def-unary-math-analyzer analyze-asin-expression make-semantic-asin "asin")
(def-unary-math-analyzer analyze-acos-expression make-semantic-acos "acos")
(def-unary-math-analyzer analyze-atan-expression make-semantic-atan "atan")

(defmacro def-binary-math-analyzer (name node-constructor op-string)
  "Endeavor 128: analyzer for a binary FP math intrinsic (pow, atan2). Both args
   must be float; the result type is the (promoted) argument type."
  `(defun ,name (expr env context location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node  (analyze-expression (second expr) env context (append location '(1))))
            (right-node (analyze-expression (third expr)  env context (append location '(2))))
            (left-type  (get-single-value-type left-node))
            (right-type (get-single-value-type right-node))
            (left-crisp (gethash left-type *crisp-types*)))
       (unless (and left-crisp (eq (crisp-type-category left-crisp) :float))
         (error 'crisp-type-error
           :message (format nil "Type mismatch for operator '~a'. Expected float, got ~a." ,op-string left-type)
           :source-location location))
       (let ((right-crisp (gethash right-type *crisp-types*)))
         (unless (and right-crisp (eq (crisp-type-category right-crisp) :float))
           (error 'crisp-type-error
             :message (format nil "Type mismatch for operator '~a'. Expected float, got ~a." ,op-string right-type)
             :source-location location)))
       (,node-constructor :type left-type :left-arg left-node :right-arg right-node
                          :source-location location))))

(def-binary-math-analyzer analyze-pow-expression   make-semantic-pow   "pow")
(def-binary-math-analyzer analyze-atan2-expression make-semantic-atan2 "atan2")

(defmacro def-comparison-analyzer (name node-constructor op-string)
  `(defun ,name (expr env context location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node (analyze-expression (second expr) env context (append location '(1))))
            (right-node (analyze-expression (third expr) env context (append location '(2))))
            (left-type (get-single-value-type left-node))
            (right-type (get-single-value-type right-node))
            (promoted-type (get-promoted-type left-type right-type)))
       (unless promoted-type
         (error 'crisp-type-error
           :message (format nil "Type mismatch for comparison '~a'. Cannot compare ~a and ~a." ,op-string left-type right-type)
           :source-location location))
       (let ((promoted-left (if (equal left-type promoted-type) left-node (create-implicit-cast left-node promoted-type location)))
             (promoted-right (if (equal right-type promoted-type) right-node (create-implicit-cast right-node promoted-type location))))
         (,node-constructor :type 'int :left-arg promoted-left :right-arg promoted-right :source-location location)))))

(defun try-constant-fold (node)
  "Attempts to reduce a semantic node to a semantic-literal if possible."
  (typecase node
    (semantic-lt
     (let ((l (try-constant-fold (semantic-lt-left-arg node)))
           (r (try-constant-fold (semantic-lt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (< (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-lt-source-location node))
           node)))
    (semantic-gt
     (let ((l (try-constant-fold (semantic-gt-left-arg node)))
           (r (try-constant-fold (semantic-gt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (> (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-gt-source-location node))
           node)))
    (semantic-le
     (let ((l (try-constant-fold (semantic-le-left-arg node)))
           (r (try-constant-fold (semantic-le-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (<= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-le-source-location node))
           node)))
    (semantic-ge
     (let ((l (try-constant-fold (semantic-ge-left-arg node)))
           (r (try-constant-fold (semantic-ge-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (>= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-ge-source-location node))
           node)))
    (semantic-eq
     (let ((l (try-constant-fold (semantic-eq-left-arg node)))
           (r (try-constant-fold (semantic-eq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-eq-source-location node))
           node)))
    (semantic-neq
     (let ((l (try-constant-fold (semantic-neq-left-arg node)))
           (r (try-constant-fold (semantic-neq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (/= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-neq-source-location node))
           node)))
    (t node)))

(def-comparison-analyzer analyze-lt-expression make-semantic-lt "<")
(def-comparison-analyzer analyze-gt-expression make-semantic-gt ">")
(def-comparison-analyzer analyze-le-expression make-semantic-le "<=")
(def-comparison-analyzer analyze-ge-expression make-semantic-ge ">=")
(def-comparison-analyzer analyze-eq-expression make-semantic-eq "=")
(def-comparison-analyzer analyze-neq-expression make-semantic-neq "!=")

(defun analyze-inc!-expression (expr env context location)
  (declare (ignore expr env context location))
  (error "inc! not implemented"))
(defun analyze-dec!-expression (expr env context location)
  (declare (ignore expr env context location))
  (error "dec! not implemented"))

(defun analyze-cast-expression (expr env context location)
  "Analyzes a to-XXXX or as-XXXX cast expression."
  (let* ((op (first expr))
         (op-name (symbol-name op))
         (arg-form (second expr))
         (target-type-name
          (cond
           ((alexandria:starts-with-subseq "TO-" op-name) (intern (subseq op-name 3) (symbol-package op)))
           ((alexandria:starts-with-subseq "AS-" op-name) (intern (subseq op-name 3) (symbol-package op)))
           ;; For floor, ceil, etc., the target is always 'int' for now.
           ((member op '(floor ceil round)) 'int)
           (t (error "Internal compiler error: analyze-cast-expression called with invalid operator ~a" op))))
         (target-crisp-type (gethash target-type-name *crisp-types*))
         (arg-node (analyze-expression arg-form env context (append location '(1)))))

    (unless target-crisp-type
      (error 'crisp-unknown-type-error :type-name target-type-name :source-location location))

    (let* ((source-type-name (get-single-value-type arg-node))
           (source-crisp-type (gethash source-type-name *crisp-types*)))

      (when (and (alexandria:starts-with-subseq "TO-" op-name)
                 (eq (crisp-type-category source-crisp-type) :float)
                 (member (crisp-type-category target-crisp-type) '(:signed-int :unsigned-int)))
            (error 'crisp-type-error :message "Invalid cast: Cannot use 'to-...' for float-to-integer conversion. Use 'truncate', 'floor', 'ceil', or 'round' instead."
              :source-location location))

      (let ((is-value-cast (or (alexandria:starts-with-subseq "TO-" op-name)
                               ;; An 'as-' cast between two integer types or two float types is a value cast (sext/zext/fpext), not a bitcast.
                               (and (alexandria:starts-with-subseq "AS-" op-name)
                                    (eq (crisp-type-category source-crisp-type)
                                        (crisp-type-category target-crisp-type))))))

        (cond
         ;; Handle `to-` casts and safe `as-` casts (like int->long)
         (is-value-cast
           (make-semantic-value-cast :type target-type-name :arg arg-node :source-location location))
         ((eq op 'truncate)
           (make-semantic-fp-truncate-cast :type target-type-name :arg arg-node :source-location location))
         ;; Handle unsafe `as-` bit reinterpretations
         (t ; Default for "AS-" and other currently unhandled float-to-int ops
           (make-semantic-bitcast :type target-type-name :arg arg-node :source-location location)))))))

(defun analyze-truncate-expression (expr env context location)
  "Analyzes (truncate val) -> (values int rem)."
  (let* ((arg-form (second expr))
         (arg-node (analyze-expression arg-form env context (append location '(1))))
         (arg-type (get-single-value-type arg-node))) ;; e.g. 'float
    (make-semantic-truncate :type (list 'int arg-type) ;; Returns (int float)
                            :arg arg-node
                            :source-location location)))

(defun analyze-value-cast-expression (expr env context location)
  "Analyzes the generic (to type value) form."
  (let* ((type-form (second expr))
         (value-form (third expr))
         (orig-type-name (if (symbolp type-form) type-form (error "Generic TO expects a type symbol, got ~a" type-form)))
         ;; Generic 'TO' Resolution
         (type-name (loop for name = orig-type-name then (gethash name *crisp-type-aliases*)
                          while (and (symbolp name) (gethash name *crisp-type-aliases*))
                          finally (cl:return name)))
         (target-type (gethash type-name *crisp-types*)))

    (unless target-type
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    (let ((arg-node (analyze-expression value-form env context (append location '(2)))))
      (make-semantic-value-cast :type type-name :arg arg-node :source-location location))))


(defun analyze-generic-as-expression (expr env context location)
  "Analyzes the generic (as type value) form.
   Extended to handle brand application forms like (index-t fc) where
   index-t is a brand, resolving to the concrete target type before validation."
  (let* ((raw-type-form (second expr))
         (value-form (third expr))

         ;; Pre-resolution: detect brand application (brand-name var-ref).
         ;; e.g. (as (index-t fc) delta) with active brand index-t resolves to
         ;; (as index-t delta), and with inactive brand resolves to (as ulong delta).
         (type-form
          (if (and (listp raw-type-form)
                   (= (length raw-type-form) 2)
                   (symbolp (first raw-type-form))
                   (symbolp (second raw-type-form))
                   (is-brand-type-p (first raw-type-form)))
              (let* ((brand-name (first raw-type-form))
                     (var-ref (second raw-type-form))
                     (brand-def (is-brand-type-p brand-name))
                     ;; Try to find per-owner brand def using var's type from env
                     (param (find var-ref env :key #'parameter-def-name))
                     (owner-type (and param (parameter-def-type param)))
                     (per-owner-def (and owner-type
                                         (find-brand-for-owner brand-name owner-type)))
                     (effective-brand-def (or per-owner-def brand-def)))
                (cond
                 ;; Active brand, globally registered in *crisp-types* (non-parameterized):
                 ;; cast to the brand type name directly.
                 ((and effective-brand-def
                       (brand-active-p effective-brand-def)
                       (gethash brand-name *crisp-types*))
                   (log:info "AS: resolved brand application (~a ~a) -> active brand ~a"
                             brand-name var-ref brand-name)
                   brand-name)
                 ;; Active brand, parameterized (not globally registered):
                 ;; use the per-owner base type.
                 ((and effective-brand-def
                       (brand-active-p effective-brand-def))
                   (let ((base (brand-definition-base-type effective-brand-def)))
                     (log:info "AS: resolved brand application (~a ~a) -> parameterized active base ~a"
                               brand-name var-ref base)
                     base))
                 ;; Inactive brand: resolve to the alias or base type.
                 ((and effective-brand-def
                       (not (brand-active-p effective-brand-def)))
                   (let ((base (or (gethash brand-name *crisp-type-aliases*)
                                   (brand-definition-base-type effective-brand-def))))
                     (log:info "AS: resolved brand application (~a ~a) -> inactive base ~a"
                               brand-name var-ref base)
                     base))
                 ;; No brand def found: leave as-is (will fail the valid-type-p check later)
                 (t
                   (log:warn "AS: brand application (~a ~a) - no brand def found, leaving as-is"
                             (first raw-type-form) (second raw-type-form))
                   raw-type-form)))
              raw-type-form))

         (orig-type-name (if (or (symbolp type-form) (listp type-form))
                             type-form
                             (error "Generic AS expects a type specifier, got ~a" type-form)))
         ;; Generic 'AS' alias resolution
         (type-name (loop for name = orig-type-name then (gethash name *crisp-type-aliases*)
                          while (and (symbolp name) (gethash name *crisp-type-aliases*))
                          finally (cl:return name)))
         (target-type (if (symbolp type-name) (gethash type-name *crisp-types*) nil))
         (arg-node (analyze-expression value-form env context (append location '(2)))))

    (unless (or target-type (valid-type-p type-name))
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; No casting of voidp
    (when (or (eq type-name 'voidp)
              (and target-type (eq (crisp-type-category target-type) :void)))
          (error 'crisp-compiler-error :message "Cannot cast to 'voidp'. Use a specific pointer type or handle." :source-location location))

    (make-semantic-value-cast :type type-name :arg arg-node :source-location location)))

(defun create-implicit-cast (node target-type location)
  "Wraps node in an implicit cast to target-type."
  (make-semantic-value-cast :type target-type
                            :arg node
                            :source-location location))

(defun analyze-bitcast-expression (expr env context location)
  "Handler for explicit (as-bits type val) or aliased calls."
  ;; Re-use logic or define simple wrapper.
  ;; The original file had a def-expression-analyzer for this but no distinct function body
  ;; other than what analyze-cast-expression does.
  ;; But wait, analyze-cast-expression expects "AS-..." or "TO-..." name.
  ;; If we call it for `as-bits`, the name doesn't match.
  ;; Let's implement specific logic here or delegate.
  (let* ((type-form (second expr))
         (val-form (third expr))
         (target-type (if (symbolp type-form) type-form (error "Invalid type")))
         (arg-node (analyze-expression val-form env context (append location '(2)))))
    (make-semantic-bitcast :type target-type :arg arg-node :source-location location)))




(defun %analyze-atomic-rmw-expression (op expr env context location &key no-delta)
  "Shared helper for all atomic RMW analyzers.
OP is a keyword (:add :sub :min :max :xchg).
Target (second element of EXPR) must be an aref expression like (~ vec idx).
When NO-DELTA is T (for atomic-inc!/atomic-dec!), synthesizes a literal-1 delta.

Target analysis runs with *analysis-access-mode* = :write so &out params can
serve as atomic-RMW targets — the read is part of the write.  Matches the
set!  analyzer's behavior in analysis/structs.lisp."
  ;; Validate argument count: inc!/dec! take 1 arg (target only); others take 2 (target + delta).
  (let ((expected-args (if no-delta 1 2))
        (actual-args   (1- (length expr))))
    (unless (= actual-args expected-args)
      (error 'crisp-type-error
        :message (format nil "~a: expected ~a argument~:p, got ~a"
                         (first expr) expected-args actual-args)
        :source-location location)))
  (let* ((target-form (second expr))
         (target-node (let ((*analysis-access-mode* :write))
                        (analyze-expression target-form env context (append location '(1))))))
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
         (y-tmp (gensym "MOD-Y")))
    ;; Endeavor 146: make the docstring's promise true for a LITERAL divisor.
    ;;
    ;; The expansion below runs through the ordinary +/-/*/ analyzers, and those refuse an
    ;; unpromotable pair — get-promoted-type returns NIL for ULONG vs INT, deliberately, since
    ;; mixing signedness silently is worse than refusing.  A Lisp integer literal reads as INT,
    ;; so `(mod <ulong> 2)` died with
    ;;     Type mismatch for operator '/'. Cannot operate on ULONG and INT.
    ;; even though every operand the user wrote was consistent.  This is a FORWARD bug, not an
    ;; AD one: it reproduces in a plain kernel with no --differentiate (endeavour 146 found it
    ;; via 142/12, whose forward escapes it only because the ring index is unrolled at compile
    ;; time so the mod never reaches this analyzer).
    ;;
    ;; Coercing only a LITERAL keeps the language's strictness where it earns its keep: two
    ;; mismatched VARIABLES still error, because that is where a silent signedness change would
    ;; actually surprise someone.  A literal has no independent type worth defending — it is
    ;; INT only because that is how the reader spells it.
    (let* ((x-node (when (integerp y-form)
                     (analyze-expression x-form env context (append location '(1)))))
           (x-type (when x-node (get-single-value-type x-node)))
           ;; NB: `to-ulong` and friends are ANALYZER-handled forms, not Lisp functions, so
           ;; find-symbol is the right existence check here — an fboundp guard silently never
           ;; fires and the coercion does nothing.
           (coerce-fn (when (and x-type (symbolp x-type)
                                 (not (string= (symbol-name x-type) "INT")))
                        (find-symbol (format nil "TO-~A" (symbol-name x-type)) cl-pkg)))
           (y-form (if coerce-fn (list coerce-fn y-form) y-form))
           (expansion (list let-sym
                            (list (list x-tmp x-form)
                                  (list y-tmp y-form))
                            (list sub-sym x-tmp
                                  (list mul-sym (list div-sym x-tmp y-tmp) y-tmp)))))
      (analyze-expression expansion env context location))))

;; src/analysis/ops.lisp
(defun analyze-rem-expression (expr env context location)
  "Analyzes (rem x y).  Currently identical to mod — both match C % / LLVM
   srem.  Split semantics later if needed."
  (let* ((x-form (second expr))
         (y-form (third expr))
         (cl-pkg (find-package :crisp-language))
         (mod-sym (intern "MOD" cl-pkg)))
    (analyze-mod-expression (list mod-sym x-form y-form) env context location)))


;;; ---------------------------------------------------------------------------------------------
;;; Endeavour 170: hardware-supported math ops (op-fma, op-saturate, op-imad, ... ).
;;;
;;; One analyzer for all of them; the per-op TYPE RULES are in %hw-op-result-type.  They are strict
;;; on purpose (see docs/ideal_001.md "Hardware Supported Math Operations" and the endeavour doc
;;; tests/spec/170-hardware-supported-math-ops/hardware-supported-math-ops.md):
;;;   - a and b must be exactly the same type; c (the accumulator) decides the result type;
;;;   - c must be the same family, same lane count, and at least as wide;
;;;   - integer multiply-adds also require c to have the SAME SIGNEDNESS as a and b.
;;; Everything else -- narrowing, mixed families, 64-bit op-imad-sat multipliers -- is a compile
;;; error with its own message, each covered by a spec in 170-.../errors.
;;; ---------------------------------------------------------------------------------------------

;; NB: *hw-op-symbols* / *hw-internal-op-symbols* live in src/semantic.lisp, which loads BEFORE
;; src/analysis/core.lisp -- core's %uni-analyze reads the list, and this file loads after core.

(defun %hw-type-parts (type-name)
  "Decompose TYPE-NAME for the endeavour-170 type rules. Returns
   (values ELEMENT-CATEGORY ELEMENT-BITS LANES BASE-NAME): LANES is NIL for a scalar, the lane count
   for a device vector; BASE-NAME is the element type's name string (\"HALF\", \"BFLOAT16\", ...).
   Returns NIL for anything that is not a known scalar or device vector."
  (let ((ct (and (symbolp type-name) type-name (gethash type-name *crisp-types*))))
    (cond
      ((null ct) nil)
      ((member (crisp-type-category ct) '(:float :signed-int :unsigned-int))
       (values (crisp-type-category ct) (crisp-type-size ct) nil (symbol-name type-name)))
      ((eq (crisp-type-category ct) :device-vector)
       (let* ((name (symbol-name type-name))
              (end (or (position-if-not #'digit-char-p name :from-end t) -1))
              (base-name (subseq name 0 (1+ end)))
              (lanes (parse-integer name :start (1+ end)))
              (base-sym (or (find-symbol base-name :crisp-language) (find-symbol base-name :crisp.compiler)))
              (base-ct (and base-sym (gethash base-sym *crisp-types*))))
         (when base-ct
           (values (crisp-type-category base-ct) (crisp-type-size base-ct) lanes base-name))))
      (t nil))))

(defun %hw-type-named (base-name lanes)
  "The registered type symbol for element BASE-NAME with LANES lanes (NIL = scalar), or NIL."
  (let* ((name (if lanes (format nil "~a~a" base-name lanes) base-name))
         (sym (or (find-symbol name :crisp-language) (find-symbol name :crisp.compiler))))
    (and sym (gethash sym *crisp-types*) sym)))

(defun %hw-unsigned-counterpart (type-name)
  "Unsigned type with the same width and lane count as integer TYPE-NAME (char4 -> uchar4).
   An unsigned TYPE-NAME is returned as-is."
  (multiple-value-bind (cat bits lanes base) (%hw-type-parts type-name)
    (declare (ignore bits))
    (if (eq cat :unsigned-int)
        type-name
        (%hw-type-named (cdr (assoc base '(("CHAR" . "UCHAR") ("SHORT" . "USHORT")
                                           ("INT" . "UINT") ("LONG" . "ULONG"))
                                    :test #'string=))
                        lanes))))

(defun %hw-fail (location fmt &rest args)
  "Signal the endeavour-170 type error: a crisp-type-error whose message is FMT applied to ARGS."
  (error 'crisp-type-error :message (apply #'format nil fmt args) :source-location location))

(defun %hw-check-multiplier-accumulator (op a-type b-type c-type location family)
  "Shared rules for the accumulator ops (op-fma: FAMILY :float; op-imad / op-imad-sat: :int).
   a and b must be the same type of FAMILY; c must be the same family, the same lane count, and at
   least as wide. For :int, c must also have the same signedness. For 16-bit floats, a c of
   equal width must be the SAME format (half and bfloat16 are not interchangeable)."
  (multiple-value-bind (a-cat a-bits a-lanes a-base) (%hw-type-parts a-type)
    (multiple-value-bind (c-cat c-bits c-lanes c-base) (%hw-type-parts c-type)
      (let ((family-ok (lambda (cat) (if (eq family :float)
                                         (eq cat :float)
                                         (member cat '(:signed-int :unsigned-int)))))
            (family-words (if (eq family :float)
                              "floating point (half, bfloat16, float, double, or their vectors)"
                              "integer (signed or unsigned, or their vectors)")))
        (unless (funcall family-ok a-cat)
          (%hw-fail location "~(~a~): operands must be ~a; got ~a" op family-words a-type))
        (unless (eq a-type b-type)
          (%hw-fail location "~(~a~): a and b must have the same type; got ~a and ~a" op a-type b-type))
        (unless (funcall family-ok c-cat)
          (%hw-fail location "~(~a~): accumulator c (~a) must be the same family as a and b (~a)" op c-type a-type))
        (unless (eql a-lanes c-lanes)
          (%hw-fail location "~(~a~): accumulator c (~a) must have the same lane count as a and b (~a)" op c-type a-type))
        (when (< c-bits a-bits)
          (%hw-fail location "~(~a~): accumulator c (~a) is narrower than a and b (~a); the accumulator must be at least as wide" op c-type a-type))
        (when (and (= c-bits a-bits) (string/= a-base c-base) (eq family :float))
          (%hw-fail location "~(~a~): accumulator c (~a) and a and b (~a) are different floating point formats" op c-type a-type))
        (when (and (eq family :int) (not (eq a-cat c-cat)))
          (%hw-fail location "~(~a~): accumulator c (~a) must have the same signedness as a and b (~a)" op c-type a-type))
        c-type))))

(defun %hw-op-result-type (op arg-types location)
  "The result type of endeavour-170 OP applied to ARG-TYPES, or a crisp-type-error."
  (let ((n (length arg-types))
        (want (case op
                ((op-saturate op-rsqrt-approx op-rcp-approx op-log2-approx op-exp2-approx
                  op-sin-approx op-cos-approx op-sincos-approx) 1)
                (op-abs-diff 2)
                (t 3))))
    (unless (= n want)
      (%hw-fail location "~(~a~) takes ~a argument~:p; got ~a" op want n))
    (destructuring-bind (a &optional b c) arg-types
      (multiple-value-bind (a-cat a-bits a-lanes) (%hw-type-parts a)
        (ecase op
          (op-fma (%hw-check-multiplier-accumulator op a b c location :float))
          ((op-imad op-imad-sat)
           (%hw-check-multiplier-accumulator op a b c location :int)
           (when (and (eq op 'op-imad-sat) (> (* 2 a-bits) 64))
             (%hw-fail location "op-imad-sat: 64-bit multipliers (~a) are not supported; the exact intermediate product would need 128 bits" a))
           c)
          (op-saturate
           (unless (eq a-cat :float)
             (%hw-fail location "op-saturate: operand must be floating point (half, bfloat16, float, double, or their vectors); got ~a" a))
           a)
          ((op-rsqrt-approx op-rcp-approx op-log2-approx op-exp2-approx op-sin-approx op-cos-approx op-sincos-approx)
           (unless (and (eq a-cat :float) (null a-lanes))
             (%hw-fail location "~(~a~): operand must be a floating point scalar (half, bfloat16, float or double); got ~a" op a))
           (if (eq op 'op-sincos-approx) (list a a) a))
          ((op-abs-diff op-abs-diff-add op-sad)
           (unless (member a-cat '(:signed-int :unsigned-int))
             (%hw-fail location "~(~a~): operands must be integer (signed or unsigned, or their vectors); got ~a" op a))
           (unless (eq a b)
             (%hw-fail location "~(~a~): a and b must have the same type; got ~a and ~a" op a b))
           (case op
             (op-abs-diff (%hw-unsigned-counterpart a))
             (op-abs-diff-add
              (multiple-value-bind (c-cat c-bits c-lanes) (%hw-type-parts c)
                (unless (member c-cat '(:signed-int :unsigned-int))
                  (%hw-fail location "op-abs-diff-add: accumulator c (~a) must be an integer type" c))
                (unless (eql c-lanes a-lanes)
                  (%hw-fail location "op-abs-diff-add: accumulator c (~a) must have the same lane count as a and b (~a)" c a))
                (when (or (< c-bits a-bits) (and (eq c-cat :signed-int) (= c-bits a-bits)))
                  (%hw-fail location "op-abs-diff-add: accumulator c (~a) is too narrow for |a-b| of ~a; use an unsigned accumulator at least as wide, or a strictly wider signed one" c a))
                c))
             (op-sad
              (multiple-value-bind (c-cat c-bits c-lanes) (%hw-type-parts c)
                (unless a-lanes
                  (%hw-fail location "op-sad: a and b must be integer device vectors (e.g. uchar4); got ~a" a))
                (unless (and (member c-cat '(:signed-int :unsigned-int)) (null c-lanes))
                  (%hw-fail location "op-sad: accumulator c (~a) must be an integer scalar" c))
                (unless (> c-bits a-bits)
                  (%hw-fail location "op-sad: accumulator c (~a) must be wider than the ~a-bit elements of ~a" c a-bits a))
                c))))
          ((op-min3 op-max3)
           (unless (member a-cat '(:float :signed-int :unsigned-int))
             (%hw-fail location "~(~a~): operands must be floating point or integer; got ~a" op a))
           (unless (and (eq a b) (eq b c))
             (%hw-fail location "~(~a~): all three operands must have the same type; got ~a, ~a and ~a" op a b c))
           a))))))

(defun %hw-sat-interior-result-type (arg-types location)
  "Result type of the internal (%hw-sat-interior R): float for an integer scalar R, floatN for an
   integer device vector with N lanes."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
    (declare (ignore bits))
    (unless (and (= (length arg-types) 1) (member cat '(:signed-int :unsigned-int)))
      (%hw-fail location "%hw-sat-interior: expects one integer operand; got ~a" arg-types))
    (%hw-type-named "FLOAT" lanes)))

(defun analyze-hw-op-expression (expr env context location)
  "Analyzes an endeavour-170 hardware math op form, e.g. (op-fma a b c), or an internal
   AD helper form such as (%hw-sat-interior r)."
  (let* ((name (symbol-name (first expr)))
         (op (or (find name *hw-op-symbols* :key #'symbol-name :test #'string=)
                 (find name *hw-internal-op-symbols* :key #'symbol-name :test #'string=)))
         (arg-nodes (loop for arg in (rest expr)
                          for i from 1
                          collect (analyze-expression arg env context (append location (list i)))))
         (arg-types (mapcar #'get-single-value-type arg-nodes))
         (result-type (if (eq op '%hw-sat-interior)
                          (%hw-sat-interior-result-type arg-types location)
                          (%hw-op-result-type op arg-types location))))
    (log:debug "analyze-hw-op-expression: ~a ~a -> ~a" op arg-types result-type)
    (make-semantic-hw-op :op op :type result-type :args arg-nodes :source-location location)))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — the four warp shuffles.
;;; ---------------------------------------------------------------------------
;;; The node itself is semantic-shuffle (src/semantic.lisp), which explains why these are not
;;; semantic-hw-ops.  Codegen is in src/codegen.lisp, the backward rules in src/autodiff.lisp.

(defparameter *shuffle-op-names*
  '(("SHUFFLE" . :idx) ("SHUFFLE-UP" . :up) ("SHUFFLE-DOWN" . :down) ("SHUFFLE-XOR" . :xor))
  "Crisp operator name -> shuffle op keyword.")

(defparameter *shuffle-value-types*
  '(int uint float long ulong double)
  "Scalar types a shuffle may move.  The 32-bit ones are one hardware instruction; the
   64-bit ones are decomposed into hi/lo halves by codegen (D9).")

(defun %shuffle-literal-integer (node)
  "The integer value of NODE if it is a compile-time integer literal, else NIL.
   (warp-size) folds to such a literal, so (shuffle v n (warp-size)) is accepted."
  (when (and (semantic-literal-p node)
             (integerp (semantic-literal-value node)))
    (semantic-literal-value node)))

(defun %shuffle-resolve-width (width-node op-name location)
  "Validates and returns the segment width for a shuffle (D4).  WIDTH-NODE may be NIL, in
   which case the width is the whole warp."
  (let ((warp (%173-warp-size)))
    (if (null width-node)
        warp
        (let ((w (%shuffle-literal-integer width-node)))
          (cond
            ((null w)
             (error 'crisp-compiler-error
                    :message (format nil "~a: the segment width must be a constant known at compile time. A lane-varying width is meaningless -- every lane has to agree which lanes it exchanges with -- and the power-of-two and not-wider-than-the-warp rules can only be checked statically"
                                     op-name)
                    :source-location location))
            ((or (<= w 0) (/= 0 (logand w (1- w))))
             (error 'crisp-compiler-error
                    :message (format nil "~a: the segment width must be a power of two, got ~a. The hardware divides the warp into ALIGNED blocks, so ~a has no lowering at all"
                                     op-name w w)
                    :source-location location))
            ((> w warp)
             (error 'crisp-compiler-error
                    :message (format nil "~a: a segment width of ~a is wider than the warp it segments (~a lanes under the active hardware profile). A segment cannot exceed the warp that contains it"
                                     op-name w warp)
                    :source-location location))
            (t w))))))

(defun %analyze-shuffle (expr env context location)
  "Analyzes (shuffle|shuffle-up|shuffle-down|shuffle-xor VALUE INDEX [WIDTH])."
  (let* ((op-name (symbol-name (first expr)))
         (op (cdr (assoc op-name *shuffle-op-names* :test #'string=)))
         (args (rest expr)))
    (unless (member (length args) '(2 3))
      (error 'crisp-compiler-error
             :message (format nil "~a expects <value> and <~a>, with an optional trailing width -- 2 or 3 arguments, got ~a"
                              op-name
                              (case op (:idx "target-lane") (:xor "lane-mask") (t "delta"))
                              (length args))
             :source-location location))
    (let* ((value-node (analyze-expression (first args) env context (append location '(1))))
           (index-node (analyze-expression (second args) env context (append location '(2))))
           (width-node (when (third args)
                         (analyze-expression (third args) env context (append location '(3)))))
           (value-type (get-single-value-type value-node))
           (width (%shuffle-resolve-width width-node op-name location)))
      (unless (member value-type *shuffle-value-types*)
        (error 'crisp-compiler-error
               :message (format nil "~a cannot move a value of type ~a. A shuffle exchanges a scalar register between lanes; the supported types are ~{~a~^, ~}"
                                op-name value-type *shuffle-value-types*)
               :source-location location))
      ;; D5 -- an xor mask that cannot stay inside its segment.  Checkable only when the mask
      ;; is a literal; a RUNTIME mask is the reduction idiom (it comes from dec-times-by-half+)
      ;; and is accepted.
      (when (eq op :xor)
        (let ((m (%shuffle-literal-integer index-node)))
          (when (and m (>= m width))
            (error 'crisp-compiler-error
                   :message (format nil "shuffle-xor: a lane-mask of ~a reaches outside its segment of ~a lanes. XOR by a mask SMALLER than the segment can never leave it, which is the only case with a meaning; ~a >= ~a asks to read a lane the segmentation forbids"
                                    m width m width)
                   :source-location location))))
      ;; D6 -- every lane must reach a warp collective.
      (%shuffle-check-not-divergent op-name location)
      (log:debug "173: ~a op=~a type=~a width=~a" op-name op value-type width)
      (make-semantic-shuffle :type value-type :op op :value value-node
                             :index index-node :width width
                             :source-location location))))


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
  ;; Endeavor 128: transcendentals
  (def-expression-analyzer exp   analyze-exp-expression)
  (def-expression-analyzer log   analyze-log-expression)
  (def-expression-analyzer log2  analyze-log2-expression)
  (def-expression-analyzer tan   analyze-tan-expression)
  (def-expression-analyzer asin  analyze-asin-expression)
  (def-expression-analyzer acos  analyze-acos-expression)
  (def-expression-analyzer atan  analyze-atan-expression)
  (def-expression-analyzer pow   analyze-pow-expression)
  (def-expression-analyzer atan2 analyze-atan2-expression)
  ;; Endeavour 170: the hardware math ops (and the internal AD helper ops) all share one analyzer.
  (dolist (sym (append *hw-op-symbols* *hw-internal-op-symbols*))
    (setf (gethash sym *expression-analyzers*) 'analyze-hw-op-expression))
  ;; Endeavour 173: the four warp shuffles, under both :crisp-language and :crisp.compiler.
  ;; Not def-expression-analyzer, which quotes one literal operator symbol -- these must be
  ;; interned into both packages at run time (user source reads in :crisp-language, where an
  ;; unregistered spelling is silently minted as a fresh symbol rather than reported).
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry *shuffle-op-names*)
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) '%analyze-shuffle)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) '%analyze-shuffle)))))
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
