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
(def-binary-op-analyzer %analyze-sub-binary make-semantic-sub "-")

;; BUG 095: one-argument minus.
(defun analyze-sub-expression (expr env context location)
  "Analyzes a `(- ...)` expression.  With two arguments, subtraction.  With ONE, negation -- analyzed as
   (* x -1), exact IEEE negation including -0.0 and infinities (BUG 095)."
  (if (= (length expr) 2)
      (progn
        (log:debug "BUG 095: unary minus ~s analyzed as (* x -1)" expr)
        (analyze-expression (list '* (second expr) -1) env context location))
      (%analyze-sub-binary expr env context location)))
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
;;;; Endeavour 176 -- (type-min T), (type-max T), (type-infinity T): typed constants.  For floating-point
;;;; T, type-min / type-max are the FINITE extremes in every precision context (not C's FLT_MIN).

(defun %type-extreme-scalar-info (expr location)
  "Validate (type-min|type-max|type-infinity T) and return (values T category bits) for T's scalar
   type, where category is :signed-int, :unsigned-int or :float and bits its width.  Refuses, naming
   what the argument must be, when T is missing or not a numeric scalar type."
  (let* ((op-name (string-downcase (symbol-name (car expr))))
         (type-arg (second expr))
         (resolved (and (= (length expr) 2) (symbolp type-arg) (resolve-type-alias type-arg)))
         (ct (and (symbolp resolved) (gethash resolved *crisp-types*)))
         (category (and ct (crisp-type-category ct))))
    (unless (member category '(:signed-int :unsigned-int :float))
      (error 'crisp-compiler-error
             :message (format nil "~a: ~s is not a numeric scalar type.  (~a T) takes one integer or floating-point type -- int, uint, long, ulong, float, double and the like -- and gives a constant of that type."
                              op-name (if (= (length expr) 2) type-arg (rest expr)) op-name)
             :source-location location))
    (values resolved category (crisp-type-size ct))))

(defun %float-type-extreme (type-sym bits)
  "The largest FINITE value of floating-point type TYPE-SYM (BITS wide), as a Lisp float."
  (cond
    ((= bits 64) most-positive-double-float)
    ((= bits 32) most-positive-single-float)
    ;; 16-bit: the two formats differ, so tell them apart by name.
    ((string-equal (symbol-name type-sym) "BFLOAT16") 3.3895314e38) ; 0x7F7F
    (t 65504.0)))                                                    ; half, 0x7BFF

(defun %analyze-type-min (expr env context location)
  "Analyzer for (type-min T): the most negative value of numeric scalar type T, as a constant of type
   T.  For a floating-point T that is the most negative FINITE value (see the section header)."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (make-semantic-literal :value-type type-sym
                           :value (ecase category
                                    (:signed-int   (- (expt 2 (1- bits))))
                                    (:unsigned-int 0)
                                    (:float        (- (%float-type-extreme type-sym bits))))
                           :source-location location)))

(defun %analyze-type-max (expr env context location)
  "Analyzer for (type-max T): the most positive value of numeric scalar type T, as a constant of type
   T.  For a floating-point T that is the most positive FINITE value (see the section header)."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (make-semantic-literal :value-type type-sym
                           :value (ecase category
                                    (:signed-int   (1- (expt 2 (1- bits))))
                                    (:unsigned-int (1- (expt 2 bits)))
                                    (:float        (%float-type-extreme type-sym bits)))
                           :source-location location)))

(defun %analyze-type-infinity (expr env context location)
  "Analyzer for (type-infinity T): positive infinity, as a constant of floating-point type T.  Negate it
   for negative infinity.  Meaningful under :ieee precision; an integer T has no infinity and is
   refused."
  (declare (ignore env context))
  (multiple-value-bind (type-sym category bits) (%type-extreme-scalar-info expr location)
    (unless (eq category :float)
      (error 'crisp-compiler-error
             :message (format nil "type-infinity: ~(~a~) has no infinity -- only floating-point types do.  The largest ~(~a~) is (type-max ~(~a~))."
                              type-sym type-sym type-sym)
             :source-location location))
    (make-semantic-literal :value-type type-sym
                           :value (if (= bits 64)
                                      sb-ext:double-float-positive-infinity
                                      sb-ext:single-float-positive-infinity)
                           :source-location location)))

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
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression)

  ;; ---- Endeavour 175: reductions, atomics, and the warp-collective check ----
  ;; Registered under BOTH packages by name, which is why none of these needed a
  ;; package.lisp change -- an analyzer is found by symbol name, not by an exported
  ;; symbol.  (The two WHEN-THREAD-IN-* macros DID need one: MACRO-FUNCTION is per
  ;; symbol, so those are exported from :crisp.compiler and imported into
  ;; :crisp-language rather than registered here.)
  ;;
  ;; MIN and MAX are in this list because Crisp had no scalar min/max at all; they are
  ;; not reductions, but they arrived with them.
  (let ((cc (find-package :crisp.compiler))
        (cl (find-package :crisp-language)))
    (dolist (pkg (list cc cl))
      (when pkg
        (dolist (pair '(
                        ("%WARP-COLLECTIVE-CHECK"    %analyze-warp-collective-check)
                        ("REDUCE-WARP"               %analyze-reduce-warp)
                        ("REDUCE-WORKGROUP"          %analyze-reduce-workgroup)
                        ("GRID-REDUCE-ATOMIC!"       %analyze-grid-reduce-atomic)
                        ("GRID-REDUCE-LAST-MAN!"     %analyze-grid-reduce-last-man)
                        ("GRID-REDUCE-SECOND-STAGE!" %analyze-grid-reduce-second-stage)
                        ("GRID-REDUCE-CAS!"          %analyze-grid-reduce-cas)
                        ("ATOMIC-CAS!"               analyze-atomic-cas!-expression)
                        ("%ATOMIC-CAS-OK!"           %analyze-atomic-cas-ok!-expression)
                        ("ATOMIC-BINOP!"             %analyze-atomic-binop!)
                        ("ATOMIC-OP!"                %analyze-atomic-op!)
                        ("MIN"                       %analyze-min-expression)
                        ("MAX"                       %analyze-max-expression)
                        ;; 176: typed constants for reduction identities (and anything else).
                        ("TYPE-MIN"                  %analyze-type-min)
                        ("TYPE-MAX"                  %analyze-type-max)
                        ("TYPE-INFINITY"             %analyze-type-infinity)
                        ;; 176 Phase 2b: the identity check a fused grid-reduce! expansion carries.
                        ("%CHECK-REDUCTION-IDENTITY" %analyze-check-reduction-identity)))
          (setf (gethash (intern (first pair) pkg) *expression-analyzers*)
                (second pair)))))))


;;;; ===========================================================================
;;;; Endeavour 175 — reductions and atomics: analyzers and expanders.
;;;; ===========================================================================

(defparameter *grid-atomic-operator-map*
  '(("+" . "ATOMIC-ADD!") ("MIN" . "ATOMIC-MIN!") ("MAX" . "ATOMIC-MAX!"))
  "Operators grid-reduce-atomic! accepts, and the native atomic each lowers to.  The hardware
   provides exactly these three; anything else has no single-instruction form.")

(defun %reduce-warp-check-active-threads (active-threads)
  "Refuses a LITERAL active-threads wider than the warp it reduces.  A runtime value is left
   alone -- same split as 173's D5 xor-mask rule, where a literal mask is checked and a runtime
   one is the reduction idiom.  The design doc calls this case undefined behaviour; there is no
   reason to leave it undefined when the value is right there at compile time, and a silently
   wrong sum is the worst of the available outcomes."
  (let ((warp (%173-warp-size)))
    (when (and (integerp active-threads) (> active-threads warp))
      (error 'crisp-compiler-error
             :message (format nil "reduce-warp: ~a active threads is wider than the warp it reduces (~a lanes under the active hardware profile). A warp reduction cannot reach beyond its own warp; to combine more threads than that, reduce within each warp and then across warps (reduce-workgroup)."
                              active-threads warp)
             :source-location nil))))

(defun %analyze-warp-collective-check (expr env context location)
  "Analyzer for (%warp-collective-check \"name\") -- runs D6 and emits nothing."
  (declare (ignore env context))
  (%shuffle-check-not-divergent (or (second expr) :|this warp collective|) location)
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

(defun %175-apply-binop (fn a b)
  "The form applying binop FN to A and B.  A LITERAL #'op is inlined as a DIRECT call rather
   than emitted as (funcall #'op a b) -- two reasons, the second decisive:

     * a direct call is simply better code than an indirect one through a function value;
     * FUNCALL IS NOT DIFFERENTIABLE.  The AD walk refuses it (\"Function FUNCALL is not
       differentiable\"), so a reduction emitting funcall cannot be differentiated at all --
       whereas (+ a b) is differentiated by the ordinary arithmetic rules.

   A non-literal FN (a variable holding a function value) still goes through funcall and is
   still not differentiable; that is a genuine AD gap, not something this can paper over."
  (if (and (consp fn) (symbolp (car fn)) (string-equal (symbol-name (car fn)) "FUNCTION"))
      (list (second fn) a b)
      (list 'funcall fn a b)))

(defun %175-apply-unop (fn a)
  "The form applying unary FN to A.  A LITERAL #'op becomes a DIRECT call, for the same two
   reasons %175-apply-binop does it: a direct call is better code, and FUNCALL IS NOT
   DIFFERENTIABLE -- the AD walk refuses it outright."
  (if (and (consp fn) (symbolp (car fn)) (string-equal (symbol-name (car fn)) "FUNCTION"))
      (list (second fn) a)
      (list 'funcall fn a)))

(defun %reduce-warp-expand (expr)
  "Forward lowering of (reduce-warp FN VAR IDENTITY &optional ACTIVE-THREADS).
   A plain function rather than a macro: keeping the construct unexpanded is what lets the VJP
   registry see it (BUG 081)."
  (let* ((fn (second expr))
         (var (third expr))
         (identity (fourth expr))
         (active-threads (fifth expr))
         (s (gensym "RW-S")))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (list `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       ;; Butterfly stride warp/2, resolved at ANALYSIS time to a literal: (warp-size) folds to a
       ;; UINT so `/` would reject the INT 2, and dec-times-by-half+ wants a provably uniform
       ;; limit, which a literal is by construction.
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         (set! ,var ,(%175-apply-binop fn `(shuffle-xor ,var ,s) var)))
       (compiler-no-op))))

;;;; Endeavour 176 Phases 1-3 -- grid-reduce! and the MULTI-VARIABLE reductions.
;;;;   grid-reduce! (a macro) rewrites into grid-reduce-atomic! / -cas! / -last-man! by :strategy.
;;;;   Shape decides the form: a clause list first is INDEPENDENT; #'f then a clause list is DEPENDENT.
;;;;   The FORWARD (analyzers + Pass-1 scanner, which see the same form) lowers both FUSED -- one sweep,
;;;;   one barrier sequence, one last-man election.  The AD path (ANF) SPLITS an independent call per
;;;;   clause so the existing VJPs apply; a dependent call is refused there (BUG 098).
;;;;   Design: tests/spec/176-reduce-multi/reduce-multi.md and the reductions excerpt.

(defparameter *176-grid-reduce-strategies*
  '((:atomic            "GRID-REDUCE-ATOMIC!"   (:local-scratch-vec :message))
    (:cas               "GRID-REDUCE-CAS!"      (:local-scratch-vec :message))
    (:last-man-standing "GRID-REDUCE-LAST-MAN!" (:local-scratch-vec :global-scratch-vec :atomic-counter
                                                 :election-flag-cell :message)))
  "Endeavour 176.  grid-reduce!'s strategies: the :strategy keyword, the construct it becomes, and the
   keys that construct accepts (:strategy itself is consumed by grid-reduce!).")

(defmacro grid-reduce! (&whole form &rest args)
  "(grid-reduce! fn var identity return-cell &key strategy message ...): a grid-wide reduction of VAR with
   binop FN and IDENTITY into RETURN-CELL.  Phase 1 is reduce-workgroup; Phase 2 is :strategy -- :atomic,
   :cas or :last-man-standing (the default).  Scratch is implicit unless passed.  See %grid-reduce!-expand."
  (declare (ignore args))
  (%grid-reduce!-expand form))

(defun %function-form-p (x)
  "T when X is #'f, i.e. (function f)."
  (and (consp x) (symbolp (car x)) (string-equal (symbol-name (car x)) "FUNCTION")))

(defun %reduction-call-shape (form)
  "Endeavour 176.  :independent when FORM's first argument is a list of clauses; :dependent when it is
   #'f followed by a list of clauses; :single otherwise.  Decided by shape alone, so it works in every
   pass, before anything is analyzed."
  (let ((a1 (second form)) (a2 (third form)))
    (cond ((and (consp a1) (consp (car a1))) :independent)
          ((and (%function-form-p a1) (consp a2) (consp (car a2))) :dependent)
          (t :single))))

(defun %independent-reduction-form-p (form)
  "T when FORM is an independent reduce-warp / reduce-workgroup / grid-reduce! call."
  (and (consp form) (symbolp (car form))
       (assoc (symbol-name (car form)) *176-independent-forms* :test #'string-equal)
       (eq (%reduction-call-shape form) :independent)))

(defun %independent-reduction-expand (form)
  "Endeavour 176 Phase 2a.  An independent reduction FORM as a PROGN of single-variable calls of the same
   operator (same symbol, so same package), one per clause.  Validates first: each clause's shape and
   keys, the call's keys, and that no variable appears in two clauses.  The per-reduction arguments --
   reduce-warp's ACTIVE-THREADS, the call's :strategy / :message -- go to every single call."
  (let* ((op (car form))
         (name (symbol-name op))
         (spec (assoc name *176-independent-forms* :test #'string-equal))
         (min-len (second spec))
         (clause-keys (third spec))
         (call-keys (fourth spec))
         (op-name (string-downcase name))
         (clauses (second form))
         (rest (cddr form))
         (seen '()))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      ;; the call's own arguments after the clause list
      (if (string-equal name "REDUCE-WARP")
          (when (> (length rest) 1)
            (fail "~a: an independent call is (reduce-warp (clause ...) &optional active-threads); got extra arguments ~s." op-name (rest rest)))
          (progn
            (unless (evenp (length rest))
              (fail "~a: the call's keyword arguments ~s are not key/value pairs." op-name rest))
            (loop for (k nil) on rest by #'cddr
                  unless (member k call-keys)
                    do (fail "~a: ~s is not a key of an independent call, which takes ~{~s~^, ~}.~@[  (A shared :atomic-counter / :election-flag-cell comes with the fused lowering.)~]"
                             op-name k call-keys (member k '(:atomic-counter :election-flag-cell))))))
      (let ((singles
              (loop for clause in clauses
                    collect
                    (progn
                      (unless (and (consp clause) (>= (length clause) min-len)
                                   (evenp (- (length clause) min-len))
                                   (%function-form-p (first clause))
                                   (symbolp (second clause)) (second clause))
                        (fail "~a: malformed clause ~s.  An independent clause is (fn var identity~a~@[ &key ~{~(~s~)~^ ~}~])."
                              op-name clause (if (= min-len 4) " return-cell" "") clause-keys))
                      (let ((var (second clause)))
                        (when (member var seen)
                          (fail "~a: the variable ~a appears in more than one clause.  Each clause overwrites its variable with its own result, so a variable may be reduced by only one clause." op-name var))
                        (push var seen))
                      (loop for (k nil) on (nthcdr min-len clause) by #'cddr
                            unless (member k clause-keys)
                              do (fail "~a: unknown clause key ~s in ~s.  A clause takes ~:[no keys~;~:*~{~s~^, ~}~]." op-name k clause clause-keys))
                      `(,op ,@clause ,@rest)))))
        (log:debug "176: independent ~a -> ~d single calls" op-name (length singles))
        `(progn ,@singles)))))

(defparameter *176-independent-forms*
  '(("REDUCE-WARP"      3 ()                                       ())
    ("REDUCE-WORKGROUP" 3 (:return-vec :local-scratch-vec)          (:message))
    ("GRID-REDUCE!"     4 (:local-scratch-vec :global-scratch-vec)
                          (:strategy :message :atomic-counter :election-flag-cell)))
  "Endeavour 176.  For each construct with an independent form: the clause's positional length, the keys a
   clause may carry (per-variable resources), and the keys the call may carry (per-reduction).")

(defun %clause-key (clause min-len key)
  "The value of KEY among CLAUSE's keywords (after its MIN-LEN positional elements), or NIL."
  (loop for (k v) on (nthcdr min-len clause) by #'cddr when (eq k key) return v))

(defun %fused-reduce-warp-form (expr)
  "Endeavour 176 Phase 2b.  An independent reduce-warp as ONE butterfly: per iteration, every clause's
   variable is combined with its shuffle partner.  Same steps as %reduce-warp-expand, k variables at once;
   ACTIVE-THREADS applies to every clause (its lanes past the count take that clause's identity)."
  (%independent-reduction-expand expr)            ; validation only
  (let* ((clauses (second expr))
         (active-threads (third expr))
         (s (gensym "RW-S")))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (loop for (nil var identity) in clauses
                 collect `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         ,@(loop for (fn var) in clauses
                 collect `(set! ,var ,(%175-apply-binop fn `(shuffle-xor ,var ,s) var))))
       (compiler-no-op))))

(defun %fused-reduce-workgroup-form (expr &optional env context location)
  "Endeavour 176 Phase 2b.  An independent reduce-workgroup as ONE sweep: a fused warp reduction of every
   clause, one barrier, one halving loop that combines every clause's per-warp partials, one read-back,
   and one leader block for every :return-vec -- %reduce-workgroup-expand's steps, k variables at once.
   A clause without :local-scratch-vec gets implicit scratch typed from ITS identity (a LET around the
   whole form, deterministic names, so the Pass-1 scan and the analyzer see the same buffers).  With ENV
   (the analyzer) each implicitly-scratched clause's identity is also checked against its variable."
  (%independent-reduction-expand expr)            ; validation only
  (let* ((op (car expr))
         (clauses (second expr))
         (implicit '())
         (scratch
           (loop for clause in clauses
                 collect (destructuring-bind (fn var identity &rest keys) clause
                           (declare (ignore fn keys))
                           (or (%clause-key clause 3 :local-scratch-vec)
                               (let ((elem-type (%identity-scan-type identity)))
                                 (unless elem-type
                                   (error 'crisp-compiler-error
                                          :message (format nil "reduce-workgroup: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass :local-scratch-vec in that clause yourself." identity)
                                          :source-location location))
                                 (when env
                                   (%check-identity-matches-variable "reduce-workgroup" var identity elem-type
                                                                     env context location))
                                 (let ((name (%implicit-scratch-binding-name var :local-scratch-vec)))
                                   (push (list name (%implicit-scratch-alloc-form :local-scratch-vec elem-type))
                                         implicit)
                                   name))))))
         (return-vecs (loop for clause in clauses collect (%clause-key clause 3 :return-vec)))
         (s (gensym "RWG-S")) (nw (gensym "RWG-NW")) (lid (gensym "RWG-LID"))
         (warp-op (intern "REDUCE-WARP" (or (symbol-package op) (find-package :crisp-language))))
         (body
           `(progn
              (,warp-op ,(loop for (fn var identity) in clauses collect (list fn var identity)))
              (when-thread-in-warp-is 0
                ,@(loop for (nil var) in clauses for sc in scratch
                        collect `(set! (~ ,sc (to-int (warp-id))) ,var)))
              (sync-workgroup)
              (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
                    (,lid (to-int (get-local-linear-id))))
                (dec-times-by-half+ (,s (/ ,nw 2ul))
                  (when (< ,lid (to-int ,s))
                    ,@(loop for (fn) in clauses for sc in scratch
                            collect `(set! (~ ,sc ,lid)
                                           ,(%175-apply-binop fn `(~ ,sc ,lid) `(~ ,sc (+ ,lid (to-int ,s)))))))
                  (sync-workgroup))
                ,@(loop for (nil var) in clauses for sc in scratch
                        collect `(set! ,var (~ ,sc 0))))
              ,@(when (some #'identity return-vecs)
                  `((when-thread-in-group-is 0
                      ,@(loop for (nil var) in clauses for rv in return-vecs
                              when rv collect `(set! (~ ,rv (to-int (get-workgroup-id 0))) ,var)))))
              (compiler-no-op))))
    (if implicit `(let ,(nreverse implicit) ,body) body)))

(defun %analyze-check-reduction-identity (expr env context location)
  "Analyzer for (%check-reduction-identity OP-NAME VAR IDENTITY TYPE): the identity-vs-variable type check
   for a fused grid-reduce!, whose macro expansion has no environment to do it in.  Emits nothing."
  (destructuring-bind (op-name var identity type) (rest expr)
    (%check-identity-matches-variable op-name var identity type env context location))
  (make-semantic-literal :value-type 'int :value 0 :source-location location))

(defun %fused-grid-reduce-form (form)
  "Endeavour 176 Phase 2b.  An independent grid-reduce!, lowered with its work done once for all clauses.
   Phase 1 is ONE independent reduce-workgroup (itself fused).  Phase 2 by :strategy --
     :atomic / :cas          one leader block applying each clause's atomic / CAS to its return cell;
     :last-man-standing      every partial written, ONE ticket from ONE counter, ONE election flag, and
                             the last workgroup's ONE fused sweep writing every return cell.
   Scratch a clause or the call leaves out is implicit (typed from each identity; the shared counter and
   flag are uint and named after the first clause's variable).  Refuses an unknown strategy, a key the
   strategy does not use, and (for :atomic) an operator with no hardware atomic -- each with the message
   the single-variable form gives."
  (%independent-reduction-expand form)            ; clause shape, clause keys, duplicates, call keys
  (let* ((op (car form))
         (pkg (or (symbol-package op) (find-package :crisp-language)))
         (clauses (second form))
         (rest (cddr form))
         (strategy-given (loop for (k v) on rest by #'cddr thereis (and (eq k :strategy) (list v))))
         (strategy (if strategy-given (first strategy-given) :last-man-standing))
         (rwg (intern "REDUCE-WORKGROUP" pkg)))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (unless (keywordp strategy)
        (fail "grid-reduce!: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy))
      (unless (member strategy '(:atomic :cas :last-man-standing))
        (fail "grid-reduce!: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  For a two-kernel reduction use grid-reduce-second-stage! in the second kernel." strategy))
      ;; keys the strategy does not use -- call level, then clause level
      (let ((call-ok (if (eq strategy :last-man-standing)
                         '(:strategy :message :atomic-counter :election-flag-cell)
                         '(:strategy :message)))
            (clause-ok (if (eq strategy :last-man-standing)
                           '(:local-scratch-vec :global-scratch-vec)
                           '(:local-scratch-vec))))
        (loop for (k nil) on rest by #'cddr
              unless (member k call-ok)
                do (fail "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy call-ok))
        (dolist (clause clauses)
          (loop for (k nil) on (nthcdr 4 clause) by #'cddr
                unless (member k clause-ok)
                  do (fail "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~} per clause." k strategy clause-ok))))
      (ecase strategy
        ((:atomic :cas)
         (when (eq strategy :atomic)
           (dolist (clause clauses)
             (unless (%grid-atomic-op-name (first clause))
               (fail "grid-reduce-atomic!: ~s has no native hardware atomic, so there is no instruction for phase 2 to emit.  Only +, min and max qualify -- the hardware provides exactly those.  For an arbitrary commutative operator use grid-reduce-cas! (a CAS loop; no extra memory, high contention) or grid-reduce-last-man! (a global scratch buffer; no contention)." (first clause)))))
         `(progn
            (,rwg ,(loop for clause in clauses
                         collect (destructuring-bind (fn var identity out &rest keys) clause
                                   (declare (ignore out))
                                   `(,fn ,var ,identity ,@keys))))
            (when-thread-in-group-is 0
              ,@(loop for (fn var nil out) in clauses
                      collect (if (eq strategy :atomic)
                                  `(,(intern (%grid-atomic-op-name fn) (find-package :crisp.compiler)) (~ ,out 0) ,var)
                                  `(atomic-binop! (~ ,out 0) ,fn ,var))))
            (compiler-no-op)))
        (:last-man-standing
         (let ((lets '()) (checks '())
               (v1 (second (first clauses))))
           (labels ((supply (given var identity key)
                      ;; GIVEN scratch, or an implicit LET binding with a deterministic name, typed from
                      ;; IDENTITY (the counter and flag are always uint)
                      (or given
                          (let ((elem-type (if (member key '(:atomic-counter :election-flag-cell))
                                               'uint
                                               (%identity-scan-type identity))))
                            (unless elem-type
                              (fail "grid-reduce!: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass that clause's scratch yourself." identity))
                            (let ((name (%implicit-scratch-binding-name var key)))
                              (push (list name (%implicit-scratch-alloc-form key elem-type)) lets)
                              (unless (member key '(:atomic-counter :election-flag-cell))
                                (pushnew `(%check-reduction-identity "grid-reduce!" ,var ,identity ,elem-type)
                                         checks :test #'equal))
                              name)))))
             (let* ((svs (loop for c in clauses
                               collect (supply (%clause-key c 4 :local-scratch-vec) (second c) (third c) :local-scratch-vec)))
                    (gvs (loop for c in clauses
                               collect (supply (%clause-key c 4 :global-scratch-vec) (second c) (third c) :global-scratch-vec)))
                    (ctr (supply (getf rest :atomic-counter) v1 nil :atomic-counter))
                    (flag (supply (getf rest :election-flag-cell) v1 nil :election-flag-cell))
                    (lid (gensym "LM-LID"))
                    (ng (gensym "LM-NG"))
                    (vals (loop repeat (length clauses) collect (gensym "LM-VAL")))
                    (body
                      `(progn
                         ,@(reverse checks)
                         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                                       "grid-reduce!: the number of workgroups exceeds local_work_size, so the last-man final sweep cannot cover every partial in one pass.")
                         ;; Phase 1 -- ONE fused workgroup reduction of every clause
                         (,rwg ,(loop for c in clauses for sv in svs
                                      collect `(,(first c) ,(second c) ,(third c) :local-scratch-vec ,sv)))
                         ;; every partial written, then ONE ticket, ONE election
                         (when-thread-in-group-is 0
                           ,@(loop for c in clauses for gv in gvs
                                   collect `(set! (~ ,gv (to-int (get-workgroup-id 0))) ,(second c))))
                         (mem-fence)
                         (when-thread-in-group-is 0
                           (set! (~ ,flag)
                                 (if (= (atomic-add! (~ ,ctr) 1u)
                                        (- (to-uint (get-num-groups 0)) 1u))
                                     1u 0u)))
                         (sync-workgroup)
                         ;; the LAST workgroup sweeps every clause's partials in ONE fused reduction
                         (when+ (= (~ ,flag) 1u)
                           (let ((,lid (to-int (get-local-linear-id)))
                                 (,ng  (to-int (get-num-groups 0))))
                             (let ,(loop for c in clauses for gv in gvs for val in vals
                                         collect `(,val (if (< ,lid ,ng) (~ ,gv ,lid) ,(third c))))
                               (,rwg ,(loop for c in clauses for sv in svs for val in vals
                                            collect `(,(first c) ,val ,(third c) :local-scratch-vec ,sv)))
                               (when-thread-in-group-is 0
                                 ,@(loop for c in clauses for val in vals
                                         collect `(set! (~ ,(fourth c) 0) ,val))))))
                         (compiler-no-op))))
               (if lets `(let ,(nreverse lets) ,body) body)))))))))

(defun %independent-reduction-split-for-ad (form)
  "Endeavour 176 Phase 2b.  The AD path's view of an independent call: the Phase-2a per-clause SPLIT, so the
   backward walk meets only single forms with their own VJPs.  A shared :atomic-counter /
   :election-flag-cell is DROPPED here -- the split runs one election per clause, and elections must not
   share a counter; each single then gets its own implicit one."
  (let ((rest (loop for (k v) on (cddr form) by #'cddr
                    unless (member k '(:atomic-counter :election-flag-cell)) append (list k v))))
    (%independent-reduction-expand (list* (car form) (second form)
                                          (if (string-equal (symbol-name (car form)) "REDUCE-WARP")
                                              (cddr form)
                                              rest)))))

(defparameter *176-dependent-forms*
  ;; name           min-clause-length  clause keys                               call keys
  '(("REDUCE-WARP"      2 ()                                       ())
    ("REDUCE-WORKGROUP" 2 (:return-vec :local-scratch-vec)          (:message))
    ("GRID-REDUCE!"     3 (:local-scratch-vec :global-scratch-vec)
                          (:strategy :message :atomic-counter :election-flag-cell)))
  "Endeavour 176.  For each construct with a dependent form: the clause's positional length (var identity,
   plus return-cell at grid level), the keys a clause may carry, and the keys the call may carry.")

(defun %dependent-reduction-form-p (form)
  "T when FORM is a dependent reduce-warp / reduce-workgroup / grid-reduce! call."
  (and (consp form) (symbolp (car form))
       (assoc (symbol-name (car form)) *176-dependent-forms* :test #'string-equal)
       (eq (%reduction-call-shape form) :dependent)))

(defun %dependent-reduction-validate (form)
  "Endeavour 176 Phase 3.  Validate a dependent call FORM: the call's own arguments, each clause's shape and
   keys, and that no variable appears in two clauses.  Returns the clause list."
  (let* ((op (car form))
         (name (symbol-name op))
         (spec (assoc name *176-dependent-forms* :test #'string-equal))
         (min-len (second spec))
         (clause-keys (third spec))
         (call-keys (fourth spec))
         (op-name (string-downcase name))
         (clauses (third form))
         (rest (cdddr form))
         (seen '()))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (if (string-equal name "REDUCE-WARP")
          (when (> (length rest) 1)
            (fail "~a: a dependent call is (reduce-warp combiner (clause ...) &optional active-threads); got extra arguments ~s." op-name (rest rest)))
          (progn
            (unless (evenp (length rest))
              (fail "~a: the call's keyword arguments ~s are not key/value pairs." op-name rest))
            (loop for (k nil) on rest by #'cddr
                  unless (member k call-keys)
                    do (fail "~a: ~s is not a key of a dependent call, which takes ~{~s~^, ~}." op-name k call-keys))))
      (dolist (clause clauses)
        (unless (and (consp clause) (>= (length clause) min-len)
                     (evenp (- (length clause) min-len))
                     (symbolp (first clause)) (first clause))
          (fail "~a: malformed clause ~s.  A dependent clause is (var identity~a~@[ &key ~{~(~s~)~^ ~}~])."
                op-name clause (if (= min-len 3) " return-cell" "") clause-keys))
        (let ((var (first clause)))
          (when (member var seen)
            (fail "~a: the variable ~a appears in more than one clause.  Each clause names one value of the state, so a variable may appear only once." op-name var))
          (push var seen))
        (loop for (k nil) on (nthcdr min-len clause) by #'cddr
              unless (member k clause-keys)
                do (fail "~a: unknown clause key ~s in ~s.  A clause takes ~:[no keys~;~:*~{~s~^, ~}~]." op-name k clause clause-keys)))
      clauses)))

(defun %combiner-call (combiner args)
  "The form calling COMBINER on ARGS: a direct call for a literal #'f (better code, and FUNCALL is not
   differentiable), else FUNCALL -- as %175-apply-binop does for the two-argument case."
  (if (%function-form-p combiner)
      (cons (second combiner) args)
      (list* 'funcall combiner args)))

(defun %check-dependent-combiner (op-name combiner clauses env context location)
  "Endeavour 176 Phase 3.  A literal #'COMBINER must have a signature #'(T1..Tk T1..Tk => T1..Tk) where Ti is
   the type of clause i's variable -- state A then state B, each in clause order.  Refused otherwise,
   showing the signature the clauses need and the one(s) the combiner has.  An unknown function is left
   for the ordinary call analysis to report."
  (when (%function-form-p combiner)
    (let* ((fname (second combiner))
           (sigs (gethash fname *function-table*))
           (norm (lambda (ty) (let ((r (resolve-type-alias ty))) (if (symbolp r) (symbol-name r) r))))
           (var-types (mapcar (lambda (c)
                                (resolve-type-alias
                                 (semantic-node-type (analyze-expression (first c) env context location))))
                              clauses))
           (want-params (append var-types var-types)))
      (when sigs
        (unless (find-if (lambda (sig)
                           (let ((ps (mapcar #'parameter-def-type (function-signature-parameters sig)))
                                 (rs (remove nil (function-signature-return-types sig))))
                             (and (= (length ps) (length want-params))
                                  (= (length rs) (length var-types))
                                  (every (lambda (a b) (equal (funcall norm a) (funcall norm b))) ps want-params)
                                  (every (lambda (a b) (equal (funcall norm a) (funcall norm b))) rs var-types))))
                         sigs)
          (error 'crisp-compiler-error
                 :message (format nil "~a: the combiner must be #'(~{~(~a~)~^ ~} ~{~(~a~)~^ ~} => ~{~(~a~)~^ ~}) to reduce these clauses -- two states, A then B, each in clause order -- but ~(~a~) is ~{#'(~{~(~a~)~^ ~} => ~{~(~a~)~^ ~})~^ or ~}."
                                  op-name var-types var-types var-types fname
                                  (mapcar (lambda (sig)
                                            (list (mapcar #'parameter-def-type (function-signature-parameters sig))
                                                  (remove nil (function-signature-return-types sig))))
                                          sigs))
                 :source-location location))))))

(defun %fused-reduce-warp-dependent-form (expr)
  "Endeavour 176 Phase 3.  A dependent reduce-warp as one butterfly: per iteration, every variable is
   shuffled, then the combiner is called ONCE with (partner's state, own state) and its k results replace
   the state.  ACTIVE-THREADS gives lanes past the count the IDENTITY STATE."
  (let* ((combiner (second expr))
         (clauses (%dependent-reduction-validate expr))
         (active-threads (fourth expr))
         (s (gensym "RWD-S"))
         (others (loop repeat (length clauses) collect (gensym "RWD-OTHER")))
         (news (loop repeat (length clauses) collect (gensym "RWD-NEW"))))
    (%reduce-warp-check-active-threads active-threads)
    `(progn
       (%warp-collective-check :reduce-warp)
       ,@(when active-threads
           (loop for (var identity) in clauses
                 collect `(set! ,var (if (< (to-int (warp-lane)) ,active-threads) ,var ,identity))))
       (dec-times-by-half+ (,s ,(floor (%173-warp-size) 2))
         (let ,(loop for (var) in clauses for o in others collect `(,o (shuffle-xor ,var ,s)))
           (let ((,@news ,(%combiner-call combiner (append others (mapcar #'first clauses)))))
             ,@(loop for (var) in clauses for n in news collect `(set! ,var ,n)))))
       (compiler-no-op))))

(defun %fused-reduce-workgroup-dependent-form (expr &optional env context location)
  "Endeavour 176 Phase 3.  A dependent reduce-workgroup: a dependent reduce-warp, every variable's per-warp
   partial written to its own scratch, one barrier, one halving loop whose step calls the combiner ONCE on
   (own partials, partner partials), one read-back, one leader block for every :return-vec.  Implicit
   scratch per clause is typed from its identity (with ENV, also checked against the variable)."
  (let* ((op (car expr))
         (combiner (second expr))
         (clauses (%dependent-reduction-validate expr))
         (implicit '())
         (scratch
           (loop for clause in clauses
                 collect (destructuring-bind (var identity &rest keys) clause
                           (declare (ignore keys))
                           (or (%clause-key clause 2 :local-scratch-vec)
                               (let ((elem-type (%identity-scan-type identity)))
                                 (unless elem-type
                                   (error 'crisp-compiler-error
                                          :message (format nil "reduce-workgroup: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass :local-scratch-vec in that clause yourself." identity)
                                          :source-location location))
                                 (when env
                                   (%check-identity-matches-variable "reduce-workgroup" var identity elem-type
                                                                     env context location))
                                 (let ((name (%implicit-scratch-binding-name var :local-scratch-vec)))
                                   (push (list name (%implicit-scratch-alloc-form :local-scratch-vec elem-type))
                                         implicit)
                                   name))))))
         (return-vecs (loop for clause in clauses collect (%clause-key clause 2 :return-vec)))
         (s (gensym "RWGD-S")) (nw (gensym "RWGD-NW")) (lid (gensym "RWGD-LID"))
         (news (loop repeat (length clauses) collect (gensym "RWGD-NEW")))
         (warp-op (intern "REDUCE-WARP" (or (symbol-package op) (find-package :crisp-language))))
         (body
           `(progn
              (,warp-op ,combiner ,(loop for (var identity) in clauses collect (list var identity)))
              (when-thread-in-warp-is 0
                ,@(loop for (var) in clauses for sc in scratch
                        collect `(set! (~ ,sc (to-int (warp-id))) ,var)))
              (sync-workgroup)
              (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
                    (,lid (to-int (get-local-linear-id))))
                (dec-times-by-half+ (,s (/ ,nw 2ul))
                  (when (< ,lid (to-int ,s))
                    (let ((,@news ,(%combiner-call combiner
                                                   (append (loop for sc in scratch collect `(~ ,sc ,lid))
                                                           (loop for sc in scratch
                                                                 collect `(~ ,sc (+ ,lid (to-int ,s))))))))
                      ,@(loop for sc in scratch for n in news collect `(set! (~ ,sc ,lid) ,n))))
                  (sync-workgroup))
                ,@(loop for (var) in clauses for sc in scratch
                        collect `(set! ,var (~ ,sc 0))))
              ,@(when (some #'identity return-vecs)
                  `((when-thread-in-group-is 0
                      ,@(loop for (var) in clauses for rv in return-vecs
                              when rv collect `(set! (~ ,rv (to-int (get-workgroup-id 0))) ,var)))))
              (compiler-no-op))))
    (if implicit `(let ,(nreverse implicit) ,body) body)))

(defun %fused-grid-reduce-dependent-form (form)
  "Endeavour 176 Phase 3.  A dependent grid-reduce!: :last-man-standing only (:atomic and :cas commit one
   word at a time, so they cannot keep a state together -- a Crisp limitation; packing a small state into
   one 64-bit CAS is possible in principle).  Phase 1 is a dependent reduce-workgroup; every variable's
   partial is written, ONE ticket from ONE counter decides the last workgroup, which runs a dependent
   reduce-workgroup over the partials and writes every return cell.  Scratch left out is implicit."
  (let* ((op (car form))
         (pkg (or (symbol-package op) (find-package :crisp-language)))
         (combiner (second form))
         (clauses (%dependent-reduction-validate form))
         (rest (cdddr form))
         (strategy-given (loop for (k v) on rest by #'cddr thereis (and (eq k :strategy) (list v))))
         (strategy (if strategy-given (first strategy-given) :last-man-standing))
         (rwg (intern "REDUCE-WORKGROUP" pkg))
         (lets '()) (checks '())
         (v1 (first (first clauses))))
    (flet ((fail (fmt &rest args)
             (error 'crisp-compiler-error :message (apply #'format nil fmt args) :source-location nil)))
      (unless (keywordp strategy)
        (fail "grid-reduce!: :strategy ~s must be known at compile time -- write :last-man-standing (the only strategy a dependent reduction allows)." strategy))
      (unless (eq strategy :last-man-standing)
        (fail "grid-reduce!: a dependent reduction works only with :last-man-standing, not ~s.  :atomic and :cas commit one word at a time, so they cannot keep a state's values together (a Crisp limitation: packing a small state into one 64-bit CAS is possible in principle, but Crisp does not do it)." strategy))
      (labels ((supply (given var identity key)
                 (or given
                     (let ((elem-type (if (member key '(:atomic-counter :election-flag-cell))
                                          'uint
                                          (%identity-scan-type identity))))
                       (unless elem-type
                         (fail "grid-reduce!: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass that clause's scratch yourself." identity))
                       (let ((name (%implicit-scratch-binding-name var key)))
                         (push (list name (%implicit-scratch-alloc-form key elem-type)) lets)
                         (unless (member key '(:atomic-counter :election-flag-cell))
                           (pushnew `(%check-reduction-identity "grid-reduce!" ,var ,identity ,elem-type)
                                    checks :test #'equal))
                         name)))))
        (let* ((svs (loop for c in clauses
                          collect (supply (%clause-key c 3 :local-scratch-vec) (first c) (second c) :local-scratch-vec)))
               (gvs (loop for c in clauses
                          collect (supply (%clause-key c 3 :global-scratch-vec) (first c) (second c) :global-scratch-vec)))
               (ctr (supply (getf rest :atomic-counter) v1 nil :atomic-counter))
               (flag (supply (getf rest :election-flag-cell) v1 nil :election-flag-cell))
               (lid (gensym "LMD-LID"))
               (ng (gensym "LMD-NG"))
               (vals (loop repeat (length clauses) collect (gensym "LMD-VAL")))
               (body
                 `(progn
                    ,@(reverse checks)
                    (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                                  "grid-reduce!: the number of workgroups exceeds local_work_size, so the last-man final sweep cannot cover every partial in one pass.")
                    (,rwg ,combiner ,(loop for c in clauses for sv in svs
                                           collect `(,(first c) ,(second c) :local-scratch-vec ,sv)))
                    (when-thread-in-group-is 0
                      ,@(loop for c in clauses for gv in gvs
                              collect `(set! (~ ,gv (to-int (get-workgroup-id 0))) ,(first c))))
                    (mem-fence)
                    (when-thread-in-group-is 0
                      (set! (~ ,flag)
                            (if (= (atomic-add! (~ ,ctr) 1u)
                                   (- (to-uint (get-num-groups 0)) 1u))
                                1u 0u)))
                    (sync-workgroup)
                    (when+ (= (~ ,flag) 1u)
                      (let ((,lid (to-int (get-local-linear-id)))
                            (,ng  (to-int (get-num-groups 0))))
                        (let ,(loop for c in clauses for gv in gvs for val in vals
                                    collect `(,val (if (< ,lid ,ng) (~ ,gv ,lid) ,(second c))))
                          (,rwg ,combiner ,(loop for c in clauses for sv in svs for val in vals
                                                 collect `(,val ,(second c) :local-scratch-vec ,sv)))
                          (when-thread-in-group-is 0
                            ,@(loop for c in clauses for val in vals
                                    collect `(set! (~ ,(third c) 0) ,val))))))
                    (compiler-no-op))))
          (if lets `(let ,(nreverse lets) ,body) body))))))

(defun %refuse-dependent-autodiff (form)
  "BUG 098.  The AD path meets a dependent reduction: refuse LOUDLY.  Its variables interact inside a user
   combiner, so the per-clause split the independent form uses does not apply, and a scratch-based
   cross-thread reduction differentiated mechanically is silently wrong."
  (error 'crisp-compiler-error
         :message (format nil "~(~a~): dependent reductions are not differentiable yet (BUG 098) -- the variables interact inside the combiner ~s, so the backward pass has no rule for them.  Keep this kernel out of differentiation."
                          (car form) (second form))
         :source-location nil))

(macrolet ((def-warp-scanners ()
             `(progn
                ,@(loop for pkg in '(:crisp.compiler :crisp-language)
                        collect `(defmethod scan-operator ((op (eql (intern "REDUCE-WARP" (find-package ,pkg)))) args)
                                   (let ((expr (cons op args)))
                                     (cond
                                       ((%independent-reduction-form-p expr)
                                        (scan-form (ignore-errors (%fused-reduce-warp-form expr))))
                                       ((%dependent-reduction-form-p expr)
                                        (scan-form (ignore-errors (%fused-reduce-warp-dependent-form expr))))
                                       (t (call-next-method)))))))))
  (def-warp-scanners))

(defun %grid-reduce!-expand (form)
  "Endeavour 176.  The expansion of grid-reduce!.  An INDEPENDENT call (a clause list) becomes a PROGN of
   single grid-reduce! calls (%independent-reduction-expand); the dependent form is refused until Phase 3.
   A single call (grid-reduce! FN VAR IDENTITY RETURN-CELL &key STRATEGY ...) becomes the construct STRATEGY
   names, minus :strategy -- refusing a missing argument, a non-literal or unknown strategy, and a key the
   chosen construct does not take.  The target is interned in the CALL's package, because the reductions
   are distinct symbols in :crisp-language and :crisp.compiler (each registered in both)."
  (case (%reduction-call-shape form)
    (:independent (return-from %grid-reduce!-expand (%fused-grid-reduce-form form)))      ; 176 Phase 2b
    (:dependent   (return-from %grid-reduce!-expand (%fused-grid-reduce-dependent-form form))))   ; 176 Phase 3
  (let ((op (first form)))
    (unless (>= (length form) 5)
      (error 'crisp-compiler-error
             :message (format nil "grid-reduce!: expected (grid-reduce! fn var identity return-cell &key strategy message), got ~s." form)
             :source-location nil))
    (destructuring-bind (fn var identity out &rest keys) (rest form)
      (unless (evenp (length keys))
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce!: the keyword arguments ~s are not key/value pairs." keys)
               :source-location nil))
      (let* ((strategy-given (loop for (k v) on keys by #'cddr thereis (and (eq k :strategy) (list v))))
             (strategy (if strategy-given (first strategy-given) :last-man-standing))
             (entry nil))
        (unless (keywordp strategy)
          (error 'crisp-compiler-error
                 :message (format nil "grid-reduce!: :strategy ~s must be known at compile time -- write one of :atomic, :cas or :last-man-standing.  The strategy decides which construct the call becomes, so a value computed at run time cannot choose it." strategy)
                 :source-location nil))
        (setf entry (assoc strategy *176-grid-reduce-strategies*))
        (unless entry
          (error 'crisp-compiler-error
                 :message (format nil "grid-reduce!: unknown :strategy ~s.  The strategy must be one of :atomic, :cas or :last-man-standing (the default).  For a two-kernel reduction use grid-reduce-second-stage! in the second kernel." strategy)
                 :source-location nil))
        (let ((pass-through '()))
          (loop for (k v) on keys by #'cddr
                unless (eq k :strategy)
                  do (unless (member k (third entry))
                       (error 'crisp-compiler-error
                              :message (format nil "grid-reduce!: ~s is not used by :strategy ~s, which takes ~{~s~^, ~}." k strategy (third entry))
                              :source-location nil))
                     (push v pass-through) (push k pass-through))
          (let ((target (intern (second entry) (or (and (symbolp op) (symbol-package op))
                                                   (find-package :crisp-language)))))
            (log:debug "176: ~s -> ~s" form (list* target fn var identity out pass-through))
            `(,target ,fn ,var ,identity ,out ,@pass-through)))))))

(defun %analyze-reduce-warp (expr env context location)
  "Analyzer for reduce-warp -- expands and delegates.  176: an independent call is lowered fused
   (%fused-reduce-warp-form); a dependent call has its combiner checked against the clauses and is lowered
   fused (%fused-reduce-warp-dependent-form).  Every dependent form reaches this analyzer, so the
   combiner check covers reduce-workgroup and grid-reduce! too."
  (case (%reduction-call-shape expr)
    (:independent (analyze-expression (%fused-reduce-warp-form expr) env context location))
    (:dependent
     (%check-dependent-combiner "reduce-warp" (second expr) (%dependent-reduction-validate expr)
                                env context location)
     (analyze-expression (%fused-reduce-warp-dependent-form expr) env context location))
    (t (analyze-expression (%reduce-warp-expand expr) env context location))))

(defun %reduce-workgroup-expand (expr)
  "The forward lowering of (reduce-workgroup FN VAR IDENTITY &key ...).  A plain function, not a
   macro: as a macro this expanded inside anf-transform and the backward walk never saw the
   construct.  The analyzer below calls it; the VJP registry sees the unexpanded form."
  (let* ((fn        (second expr))
         (var       (third expr))
         (identity  (fourth expr))
         (keys      (cddddr expr))
         (scratch   (getf keys :local-scratch-vec))
         (return-vec (getf keys :return-vec))
         (s   (gensym "RWG-S"))
         (nw  (gensym "RWG-NW"))
         (lid (gensym "RWG-LID")))
    (unless scratch
      (error 'crisp-compiler-error
             :message "reduce-workgroup: :local-scratch-vec is required in this build.  Auto-generating it needs VAR's element type at analysis time, which Crisp cannot yet supply.  Pass e.g. (make-scratch-vector float :match-num-warps-per-workgroup)."
             :source-location nil))
    `(progn
       ;; Phase 1 -- each warp reduces itself; every lane then holds its warp's partial.
       (reduce-warp ,fn ,var ,identity)
       (when-thread-in-warp-is 0
         (set! (~ ,scratch (to-int (warp-id))) ,var))
       (sync-workgroup)
       ;; Phase 2 -- halving sweep over the per-warp partials.  The barrier is INSIDE the loop
       ;; and OUTSIDE the guard: reductions-excerpt.md has it the other way round, which Crisp
       ;; refuses (a workgroup collective in divergent control flow) and which would also leave
       ;; successive passes unseparated.  The loop is the + variant so every thread runs the
       ;; same iteration count and meets the same barriers.
       (let ((,nw (/ (get-local-linear-size) (to-ulong (warp-size))))
             (,lid (to-int (get-local-linear-id))))
         (dec-times-by-half+ (,s (/ ,nw 2ul))
           (when (< ,lid (to-int ,s))
             (set! (~ ,scratch ,lid)
                   ,(%175-apply-binop fn
                                      `(~ ,scratch ,lid)
                                      `(~ ,scratch (+ ,lid (to-int ,s))))))
           (sync-workgroup))
         ;; Slot 0 holds the workgroup total; every thread reads it.  With one warp the sweep
         ;; runs zero iterations (BUG 065's gate) and slot 0 already holds that warp's partial,
         ;; separated from these reads by the barrier above.
         (set! ,var (~ ,scratch 0)))
       ,@(when return-vec
           (list `(when-thread-in-group-is 0
                    (set! (~ ,return-vec (to-int (get-workgroup-id 0))) ,var))))
       (compiler-no-op))))

;;;; Endeavour 176 -- IMPLICIT SCRATCH.  When a reduction's scratch keys are omitted, the reduction is
;;;; rewritten -- in BOTH passes, by %implicit-scratch-form -- into a LET of make-scratch-* around the
;;;; reduction with the keys supplied.  Pass 1 scans that let (scan-operator methods below), so the
;;;; existing implicit-parameter plumbing carries the scratch to the kernel; Pass 2 analyzes the same
;;;; let.  The element type comes from the IDENTITY, read at scan time.  Last-man's global partials are
;;;; sized :match-workgroup-size, which its num_workgroups <= local_work_size limit makes sufficient.
;;;; Design: tests/spec/176-reduce-multi/reduce-multi.md.

(defparameter *176-implicit-scratch-specs*
  '(("REDUCE-WORKGROUP"          4 (:local-scratch-vec))
    ("GRID-REDUCE-ATOMIC!"       5 (:local-scratch-vec))
    ("GRID-REDUCE-CAS!"          5 (:local-scratch-vec))
    ("GRID-REDUCE-LAST-MAN!"     5 (:local-scratch-vec :global-scratch-vec :atomic-counter :election-flag-cell))
    ("GRID-REDUCE-SECOND-STAGE!" 6 (:local-scratch-vec)))
  "Endeavour 176.  For each reduction Crisp can supply scratch for: the operator's name, how many
   leading elements of the form (operator included) are positional, and the scratch keys Crisp
   allocates when the caller leaves them out, in the order they are bound.")

(defun %implicit-scratch-spec (op)
  "The *176-implicit-scratch-specs* entry for operator symbol OP, or NIL.  Matched by name, since the
   reductions are interned in both :crisp.compiler and :crisp-language."
  (and (symbolp op)
       (assoc (symbol-name op) *176-implicit-scratch-specs* :test #'string-equal)))

(defun %implicit-scratch-missing-keys (expr)
  "The scratch keys of reduction form EXPR that Crisp can supply and the caller left out (or passed as
   NIL), in table order; NIL when EXPR is not such a reduction or supplies them all.  Walks the keyword
   tail as pairs rather than with GETF, so a malformed tail is left for the expander to report."
  (let ((spec (%implicit-scratch-spec (car expr))))
    (when spec
      (let ((tail (nthcdr (second spec) expr)))
        (remove-if (lambda (key)
                     (loop for (k v) on tail by #'cddr thereis (and (eq k key) v)))
                   (third spec))))))

(defun %scan-type-by-name (name)
  "The Crisp type symbol whose name is NAME (a string), or NIL.  Looked up in *crisp-types* so the
   answer is the symbol the rest of the compiler uses."
  (loop for k being the hash-keys of *crisp-types*
        when (and (symbolp k) (string-equal (symbol-name k) name))
          return k))

(defun %identity-scan-type (form)
  "Endeavour 176.  The Crisp type of identity FORM, read from the form ALONE -- no environment, since
   this runs in the Pass-1 scan, before any variable has a type.  NIL when the type is not visible.

   Recognised, mirroring the analyzer's own literal typing (analyze-expression Case 1/1.1/2):
     integer literal                      -> int
     float literal                        -> float   (all float literals are float)
     suffixed literal (0ul, 1.5f, 255uc)  -> its suffix type (%try-parse-typed-literal)
     (type-min T) (type-max T) (type-infinity T) -> T
     (- X)                                -> the type of X
     (to-T x)                             -> T, when T names a Crisp type"
  (cond
    ((integerp form) 'int)
    ((floatp form) 'float)
    ((and (symbolp form) form (not (keywordp form)))
     (let ((lit (ignore-errors (%try-parse-typed-literal form nil))))
       (and lit (semantic-node-type lit))))
    ((and (consp form) (symbolp (car form)))
     (let ((head (symbol-name (car form))))
       (cond
         ((and (member head '("TYPE-MIN" "TYPE-MAX" "TYPE-INFINITY") :test #'string-equal)
               (symbolp (second form)))
          (%scan-type-by-name (symbol-name (second form))))
         ((and (string= head "-") (= (length form) 2))
          (%identity-scan-type (second form)))
         ((and (> (length head) 3) (string-equal "TO-" head :end2 3))
          (%scan-type-by-name (subseq head 3)))
         (t nil))))
    (t nil)))

(defun %implicit-scratch-binding-name (var key)
  "The DETERMINISTIC let-binding name for the scratch Crisp allocates for KEY of a reduction over VAR,
   e.g. CONTRIB-LOCAL-SCRATCH.  Deterministic because Pass 2 finds the implicit parameter by
   rebuilding <binding>_FROM_<fn>_<n>, so Pass 1 and Pass 2 must see the same name (a gensym would
   differ).  It also names the buffer readably in the generated host code."
  (intern (format nil "~a-~a" (symbol-name var)
                  (ecase key
                    (:local-scratch-vec  "LOCAL-SCRATCH")
                    (:global-scratch-vec "GLOBAL-SCRATCH")
                    (:atomic-counter     "COUNTER")
                    (:election-flag-cell "ELECTION-FLAG")))
          (or (symbol-package var) (find-package :crisp-language))))

(defun %implicit-scratch-alloc-form (key elem-type)
  "The allocation form for scratch KEY: the same forms a caller writes by hand (see 175/25).  The
   global partials are sized :match-workgroup-size -- see the stage-A section header for why that is
   always enough."
  (ecase key
    (:local-scratch-vec  `(make-scratch-vector ,elem-type :match-num-warps-per-workgroup))
    (:global-scratch-vec `(make-scratch-vector ,elem-type :match-workgroup-size :address-space :global))
    (:atomic-counter     '(make-scratch-cell uint :address-space :global))
    (:election-flag-cell '(make-scratch-cell uint))))

(defun %implicit-scratch-form (expr elem-type)
  "Endeavour 176.  Reduction form EXPR with its missing scratch supplied: a LET binding each missing
   buffer, around EXPR with the corresponding keys appended (any NIL-valued copy of such a key removed).
   Used by BOTH the Pass-1 scan-operator methods and the analyzers, so the two passes see the same form
   (and the same scratch order)."
  (let* ((spec (%implicit-scratch-spec (car expr)))
         (var (third expr))
         (missing (%implicit-scratch-missing-keys expr))
         (names (mapcar (lambda (k) (%implicit-scratch-binding-name var k)) missing))
         (tail (loop for (k v) on (nthcdr (second spec) expr) by #'cddr
                     unless (and (member k missing) (null v)) append (list k v))))
    `(let ,(mapcar (lambda (name key) (list name (%implicit-scratch-alloc-form key elem-type))) names missing)
       (,@(subseq expr 0 (second spec))
        ,@tail
        ,@(loop for key in missing for name in names append (list key name))))))

(defun %scan-reduction-maybe-implicit (op args next)
  "Pass 1.  An independent or dependent reduce-workgroup is scanned as its fused form (the same form the
   analyzer sees).  Otherwise scan the implicit-scratch form of reduction (OP . ARGS) when Crisp will
   supply its scratch, or call NEXT (the default scan)."
  (let ((expr (cons op args)))
    (cond
      ((%independent-reduction-form-p expr)
       (scan-form (ignore-errors (%fused-reduce-workgroup-form expr))))
      ((%dependent-reduction-form-p expr)
       (scan-form (ignore-errors (%fused-reduce-workgroup-dependent-form expr))))
      (t
       (let* ((missing (%implicit-scratch-missing-keys expr))
              (elem-type (and missing (symbolp (third expr)) (%identity-scan-type (fourth expr)))))
         (if elem-type
             (progn
               (log:debug "176: Pass 1 implicit scratch ~s for ~s (element type ~s)" missing op elem-type)
               (scan-form (%implicit-scratch-form expr elem-type)))
             (funcall next)))))))

(macrolet ((def-implicit-scratch-scanners (&rest names)
             `(progn
                ,@(loop for name in names
                        append (loop for pkg in '(:crisp.compiler :crisp-language)
                                     collect `(defmethod scan-operator ((op (eql (intern ,name (find-package ,pkg)))) args)
                                                (%scan-reduction-maybe-implicit op args (lambda () (call-next-method)))))))))
  (def-implicit-scratch-scanners "REDUCE-WORKGROUP" "GRID-REDUCE-ATOMIC!" "GRID-REDUCE-CAS!"
                                 "GRID-REDUCE-LAST-MAN!" "GRID-REDUCE-SECOND-STAGE!"))

(defun %check-identity-matches-variable (op-name var identity elem-type env context location)
  "Endeavour 176.  With implicit scratch the scratch is typed from the IDENTITY, so a variable of a
   different type would be reduced through mistyped scratch.  Refuse it, naming the fix."
  (let* ((var-type (semantic-node-type (analyze-expression var env context location)))
         (a (resolve-type-alias var-type))
         (b (resolve-type-alias elem-type)))
    (unless (if (and (symbolp a) (symbolp b))
                (string-equal (symbol-name a) (symbol-name b))
                (equal a b))
      (error 'crisp-compiler-error
             :message (format nil "~a: the identity ~s is ~(~a~) but ~a is ~(~a~).  The identity must have the variable's type when Crisp allocates the scratch for you, because the scratch is typed from it -- write the identity as a ~(~a~), e.g. (to-~(~a~) ~s)."
                              op-name identity b var a a a identity)
             :source-location location))))

(defun %analyze-reduction-maybe-implicit (expr env context location expander)
  "Endeavour 176.  Analyze reduction EXPR: an independent or dependent reduce-workgroup FUSED (with its
   identity checks); otherwise supply its scratch when the caller left it out, else analyze
   (EXPANDER EXPR) as before."
  (case (%reduction-call-shape expr)
    (:independent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%fused-reduce-workgroup-form expr env context location) env context location)))
    (:dependent
     (return-from %analyze-reduction-maybe-implicit
       (analyze-expression (%fused-reduce-workgroup-dependent-form expr env context location) env context location))))
  (let ((missing (%implicit-scratch-missing-keys expr))
        (var (third expr)))
    (if (or (null missing) (not (symbolp var)))
        (analyze-expression (funcall expander expr) env context location)
        (let* ((op-name (string-downcase (symbol-name (car expr))))
               (identity (fourth expr))
               (elem-type (%identity-scan-type identity)))
          (unless elem-type
            (error 'crisp-compiler-error
                   :message (format nil "~a: cannot tell the type of the identity ~s before analysis, so Crisp cannot allocate the scratch memory for you.  Write the identity with a visible type -- 0.0, 0ul, (type-max int), (to-ulong x) -- or pass ~{~s~^ ~} yourself."
                                    op-name identity missing)
                   :source-location location))
          (%check-identity-matches-variable op-name var identity elem-type env context location)
          (log:debug "176: implicit scratch ~s for ~a over ~s (element type ~s)" missing op-name var elem-type)
          (analyze-expression (%implicit-scratch-form expr elem-type) env context location)))))

(defun %analyze-reduce-workgroup (expr env context location)
  "Analyzer for reduce-workgroup -- expands and delegates, supplying implicit scratch (176).  Being an
   ANALYZED form rather than a macro is what keeps the construct visible to the autodiff walk."
  (%analyze-reduction-maybe-implicit expr env context location #'%reduce-workgroup-expand))

(defun %grid-atomic-op-name (fn)
  "The atomic operator name for a literal #'op, or NIL if OP has no hardware atomic."
  (when (and (consp fn) (symbolp (car fn))
             (string-equal (symbol-name (car fn)) "FUNCTION")
             (symbolp (second fn)))
    (cdr (assoc (symbol-name (second fn)) *grid-atomic-operator-map* :test #'string-equal))))

(defun %grid-reduce-atomic-parts (expr)
  "Destructures (grid-reduce-atomic! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec scratch)."
  (let ((keys (cdr (cdddr (cdr expr)))))   ; everything after the four positional arguments
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec))))

(defun %grid-reduce-atomic-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (see the section header)."
  (multiple-value-bind (fn var identity return-vec scratch) (%grid-reduce-atomic-parts expr)
    (let ((atomic (%grid-atomic-op-name fn)))
      (unless return-vec
        (error 'crisp-compiler-error
               :message "grid-reduce-atomic!: a return-vec is required -- it is the single global element the grid accumulates into.  Call it as (grid-reduce-atomic! #'+ var identity return-vec :local-scratch-vec sv)."
               :source-location nil))
      (unless scratch
        (error 'crisp-compiler-error
               :message "grid-reduce-atomic!: :local-scratch-vec is required in this build.  Auto-generating it needs VAR's element type at analysis time, which Crisp cannot yet supply.  Pass e.g. (make-scratch-vector float :match-num-warps-per-workgroup)."
               :source-location nil))
      (unless atomic
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-atomic!: ~s has no native hardware atomic, so there is no instruction for phase 2 to emit.  Only +, min and max qualify -- the hardware provides exactly those.  For an arbitrary commutative operator use grid-reduce-cas! (a CAS loop; no extra memory, high contention) or grid-reduce-last-man! (a global scratch buffer; no contention)."
                                fn)
               :source-location nil))
      `(progn
         ;; Phase 1 -- every thread of the workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,scratch)
         ;; Phase 2 -- ONE leader per workgroup contributes that total to the grid cell.  Electing
         ;; a single thread is what makes the atomic correct: without it all 64 would add the same
         ;; workgroup total and the result would be scaled by the workgroup size.
         (when-thread-in-group-is 0
           (,(intern atomic (find-package :crisp.compiler)) (~ ,return-vec 0) ,var))
         (compiler-no-op)))))

(defun %analyze-grid-reduce-atomic (expr env context location)
  "Analyzer for grid-reduce-atomic! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-atomic-expand))

(defun %175-minmax-expand (expr which location)
  "Expands (min a b) / (max a b) into a single-evaluation comparison.
   WHICH is :min or :max."
  (unless (= (length (rest expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "~(~a~) takes exactly two arguments, got ~a. Crisp's ~(~a~) is BINARY, unlike Common Lisp's variadic one: it exists to be passed as a #(T T => T) binop to the reduction family, which requires a fixed arity. Nest the calls to combine more than two values."
                            which (length (rest expr)) which)
           :source-location location))
  (let ((a (gensym "MM-A"))
        (b (gensym "MM-B")))
    `(let ((,a ,(second expr))
           (,b ,(third expr)))
       ;; Bound first so each argument is evaluated exactly once -- see the section header.
       (if (,(if (eq which :max) '> '<) ,a ,b) ,a ,b))))

(defun %analyze-min-expression (expr env context location)
  "Analyzer for (min a b) -- expands to a comparison and delegates."
  (analyze-expression (%175-minmax-expand expr :min location) env context location))

(defun %analyze-max-expression (expr env context location)
  "Analyzer for (max a b) -- expands to a comparison and delegates."
  (analyze-expression (%175-minmax-expand expr :max location) env context location))

(defun %grid-reduce-last-man-parts (expr)
  "Destructures (grid-reduce-last-man! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec local global counter flag)."
  (let ((keys (cdr (cdddr (cdr expr)))))
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec)
            (getf keys :global-scratch-vec)
            (getf keys :atomic-counter)
            (getf keys :election-flag-cell))))

(defun %grid-reduce-last-man-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081)."
  (multiple-value-bind (fn var identity return-vec sv gv ctr flag)
      (%grid-reduce-last-man-parts expr)
    (dolist (pair (list (list return-vec "a return-vec" "the single global element the grid reduces into")
                        (list sv ":local-scratch-vec" "one element per warp, for the per-workgroup reduction")
                        (list gv ":global-scratch-vec" "one element per WORKGROUP, holding the partials")
                        (list ctr ":atomic-counter"   "a zero-initialised GLOBAL uint cell, used to draw tickets")
                        (list flag ":election-flag-cell" "a LOCAL uint cell, broadcasting the ticket result from thread 0 to its workgroup")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-last-man!: ~a is required -- ~a.  It must be allocated in the CALLER's scope: scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters."
                                (second pair) (third pair))
               :source-location nil)))
    (let ((lid (gensym "LM-LID"))
          (ng  (gensym "LM-NG"))
          (val (gensym "LM-VAL")))
      `(progn
         ;; The final sweep is ONE reduce-workgroup, so every partial must fit in one workgroup.
         (r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size))
                       "grid-reduce-last-man!: the number of workgroups exceeds local_work_size, so the final sweep cannot cover every partial in one pass")
         ;; Phase 1 -- every thread of this workgroup ends up holding the workgroup's total.
         (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
         ;; Phase 2 -- publish this workgroup's partial.
         (when-thread-in-group-is 0
           (set! (~ ,gv (to-int (get-workgroup-id 0))) ,var))
         ;; The store must be visible before the counter announces this workgroup has arrived.
         ;; OUTSIDE the election because a fence in divergent control flow is refused (BUG 082,
         ;; over-strict but load-bearing for sync-wait).  Ordering survives regardless: it is
         ;; thread 0's OWN program order that carries it -- store, then fence, then atomic.
         (mem-fence)
         (when-thread-in-group-is 0
           ;; atomic-add! yields the value BEFORE the addition, so exactly one workgroup in the
           ;; grid draws num_groups-1.  Verified on hardware, not assumed.
           (set! (~ ,flag)
                 (if (= (atomic-add! (~ ,ctr) 1u)
                        (- (to-uint (get-num-groups 0)) 1u))
                     1u 0u)))
         ;; Publish the verdict to the rest of the workgroup.
         (sync-workgroup)
         ;; Uniform by construction -- every thread reads the same cell after a barrier.  It has
         ;; to be when+ rather than when: the body contains a reduce-workgroup, and a workgroup
         ;; collective inside a merely thread-divergent conditional is refused.
         ;; THE LOSERS FALL STRAIGHT THROUGH HERE AND RETIRE.
         (when+ (= (~ ,flag) 1u)
           (let ((,lid (to-int (get-local-linear-id)))
                 (,ng  (to-int (get-num-groups 0))))
             (let ((,val (if (< ,lid ,ng) (~ ,gv ,lid) ,identity)))
               (reduce-workgroup ,fn ,val ,identity :local-scratch-vec ,sv)
               (when-thread-in-group-is 0
                 (set! (~ ,return-vec 0) ,val)))))
         (compiler-no-op)))))

(defun %analyze-grid-reduce-last-man (expr env context location)
  "Analyzer for grid-reduce-last-man! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-last-man-expand))

(defun %grid-reduce-second-stage-parts (expr)
  "Destructures (grid-reduce-second-stage! FN VAR IDENTITY IN-VEC RETURN-VEC &key ...).
   Returns (values fn var identity in-vec return-vec local-scratch-vec)."
  (let ((keys (nthcdr 6 expr)))
    (values (second expr) (third expr) (fourth expr) (fifth expr) (sixth expr)
            (getf keys :local-scratch-vec))))

(defun %grid-reduce-second-stage-expand (expr)
  "The forward lowering.  A plain function, not a macro -- see the header."
  (multiple-value-bind (fn var identity in-vec return-vec sv)
      (%grid-reduce-second-stage-parts expr)
    (dolist (pair (list (list fn "a binop") (list var "a var to reduce through")
                        (list identity "an identity") (list in-vec "an in-scratch-vec")
                        (list return-vec "a return-vec")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-second-stage!: ~a is required.  The form is (grid-reduce-second-stage! fn var identity in-scratch-vec return-vec :local-scratch-vec sv)."
                                (second pair))
               :source-location nil)))
    (unless sv
      (error 'crisp-compiler-error
             :message "grid-reduce-second-stage!: :local-scratch-vec is required -- one element per warp, for the final workgroup reduction.  It must be allocated in the CALLER's scope: scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters, so Crisp cannot generate it for you here."
             :source-location nil))
    (let ((lid (gensym "SS-LID"))
          (n   (gensym "SS-N")))
      `(progn
         ;; The construct sweeps in a SINGLE workgroup by definition -- it is the continuation
         ;; kernel of a dual pass.  Launched with more, every workgroup would store its own
         ;; partial answer over the others and the result would be a race, so this is refused
         ;; rather than silently producing one of several possible numbers.
         (r-t-assert-0 (= (get-num-groups 0) 1)
                       "grid-reduce-second-stage! must be launched with exactly one workgroup")
         ;; One thread reads one partial, so the workgroup must be at least as wide as the vector.
         (r-t-assert-0 (<= (length~ ,in-vec) (get-local-linear-size))
                       "grid-reduce-second-stage!: local_work_size must be >= the length of in-scratch-vec, or some partials would never be read")
         (let ((,lid (to-int (get-local-linear-id)))
               (,n   (to-int (length~ ,in-vec))))
           ;; Lanes past the end of the partials take the IDENTITY.  Reading past the end instead
           ;; would be undefined, and defaulting to a hardwired zero would be wrong for every
           ;; operator but +.
           (set! ,var (if (< ,lid ,n) (~ ,in-vec ,lid) ,identity))
           (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
           (when-thread-in-group-is 0
             (set! (~ ,return-vec 0) ,var)))
         (compiler-no-op)))))

(defun %analyze-grid-reduce-second-stage (expr env context location)
  "Analyzer for grid-reduce-second-stage! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-second-stage-expand))

(defun %grid-reduce-cas-parts (expr)
  "Destructures (grid-reduce-cas! FN VAR IDENTITY RETURN-VEC &key ...).
   Returns (values fn var identity return-vec local-scratch-vec)."
  (let ((keys (nthcdr 5 expr)))
    (values (second expr) (third expr) (fourth expr) (fifth expr)
            (getf keys :local-scratch-vec))))

(defun %grid-reduce-cas-expand (expr)
  "The forward lowering.  A plain function, not a macro: keeping the construct unexpanded is what
   lets the VJP registry see it (BUG 073/077/081)."
  (multiple-value-bind (fn var identity return-vec sv) (%grid-reduce-cas-parts expr)
    (dolist (pair (list (list fn "a binop") (list var "a var to reduce")
                        (list identity "an identity") (list return-vec "a return-vec")))
      (unless (first pair)
        (error 'crisp-compiler-error
               :message (format nil "grid-reduce-cas!: ~a is required.  The form is (grid-reduce-cas! fn var identity return-vec :local-scratch-vec sv)."
                                (second pair))
               :source-location nil)))
    (unless sv
      (error 'crisp-compiler-error
             :message "grid-reduce-cas!: :local-scratch-vec is required -- one element per warp, for the per-workgroup reduction.  It must be allocated in the CALLER's scope: scratch created inside an analyzer's expansion is invisible to the Pass-1 scanner that builds implicit parameters, so Crisp cannot generate it for you here."
             :source-location nil))
    `(progn
       ;; Phase 1 -- every thread of the workgroup ends up holding the workgroup's total.
       (reduce-workgroup ,fn ,var ,identity :local-scratch-vec ,sv)
       ;; Phase 2 -- one leader per workgroup folds that total into the single result cell.
       ;; The CAS loop, its derived bound and its exhaustion assert all live in atomic-binop!.
       (when-thread-in-group-is 0
         (atomic-binop! (~ ,return-vec 0) ,fn ,var))
       (compiler-no-op))))

(defun %analyze-grid-reduce-cas (expr env context location)
  "Analyzer for grid-reduce-cas! -- expands and delegates, supplying implicit scratch (176)."
  (%analyze-reduction-maybe-implicit expr env context location #'%grid-reduce-cas-expand))

(defun analyze-atomic-cas!-expression (expr env context location)
  "Analyzes (atomic-cas! target expected desired).
   The target is analysed in :write mode so an &out parameter can be a CAS target -- the read is
   part of the write, exactly as for the other atomics and for set!."
  (unless (= (length expr) 4)
    (error 'crisp-type-error
           :message (format nil "atomic-cas!: expected 3 arguments (location expected desired), got ~a"
                            (1- (length expr)))
           :source-location location))
  (let* ((target-form (second expr))
         (target-node (let ((*analysis-access-mode* :write))
                        (analyze-expression target-form env context (append location (list 1))))))
    (unless (semantic-aref-p target-node)
      (error 'crisp-type-error
             :message (format nil "atomic-cas!: target must be a memory location like (~~ vec idx), got ~a"
                              target-form)
             :source-location location))
    (let ((elem-type (semantic-aref-type target-node)))
      (make-semantic-atomic-cas
       :type elem-type
       :target-node target-node
       :expected-node (analyze-expression (third expr) env context (append location (list 2)))
       :desired-node  (analyze-expression (fourth expr) env context (append location (list 3)))
       :source-location location))))

(defun %analyze-atomic-cas-ok!-expression (expr env context location)
  "Analyzes (%atomic-cas-ok! target expected desired) -- a CAS yielding the SUCCESS FLAG as an int.

   COMPILER-INTERNAL, and named with a leading % to say so.  It exists because a bounded retry
   loop cannot correctly derive success from the returned old value: that test is numeric where
   CAS is bitwise, so a +0.0/-0.0 transition reads as success and loses the update.  Exposing the
   flag LLVM already computed is cheaper and exactly right."
  (let ((node (analyze-atomic-cas!-expression expr env context location)))
    (setf (semantic-atomic-cas-result-mode node) :success
          (semantic-atomic-cas-type node) 'int)
    node))

(defun %atomic-binop-parts (expr)
  "Destructures (atomic-binop! LOCATION BINOP-F ARG).  Returns (values location fn arg)."
  (values (second expr) (third expr) (fourth expr)))

(defun %atomic-binop-expand (expr)
  "The forward lowering: a bounded CAS retry loop that returns the prior value."
  (unless (= (length expr) 4)
    (error 'crisp-compiler-error
           :message (format nil "atomic-binop!: expected 3 arguments (location binop-f arg), got ~a.  The form is (atomic-binop! location #'op arg)."
                            (1- (length expr)))
           :source-location nil))
  (multiple-value-bind (loc fn arg) (%atomic-binop-parts expr)
    (let ((a    (gensym "AB-ARG"))
          (prev (gensym "AB-PREV"))
          (done (gensym "AB-DONE"))
          (r    (gensym "AB-R"))
          (old  (gensym "AB-OLD"))
          (new  (gensym "AB-NEW")))
      ;; ARG is bound ONCE outside the loop: it may be an arbitrary expression, and re-evaluating
      ;; it per retry would be both wasteful and wrong if it had side effects.
      `(let ((,a ,arg))
         ;; PREV is seeded from a read so it has the element type without needing a typed zero.
         ;; It is overwritten by the successful iteration; the seed value is never returned,
         ;; because the assert below refuses to let the loop finish unsuccessfully.
         (let ((,prev (~ ,@(cdr loc))))
           (let ((,done 0))
             ;; get-global-LINEAR-size, not get-global-size: the latter is named in
             ;; analysis/core.lisp's builtin list but has no analyzer, so it compiles to
             ;; "Unsupported form".  The linear form is the total thread count, which is exactly
             ;; the contender bound wanted here.
             (dotimes+ (,r (+ (to-int (get-global-linear-size)) 1))
               (when (= ,done 0)
                 (let ((,old (~ ,@(cdr loc))))
                   (let ((,new ,(%175-apply-binop fn old a)))
                     ;; The success FLAG, not the returned value -- see %atomic-cas-ok!.
                     (when (= (%atomic-cas-ok! ,loc ,old ,new) 1)
                       ;; On success memory held exactly OLD, which is what we read ourselves,
                       ;; so the "value before" needs nothing from the CAS itself.
                       (set! ,prev ,old)
                       (set! ,done 1))))))
             (r-t-assert-0 (= ,done 1)
                           "atomic-binop!: the bounded CAS retry loop exhausted without succeeding, so this update was LOST.  The bound is global_size + 1, which is sound when each thread performs the operation once; it can be exceeded if atomic-binop! runs inside a loop, so that total successes on this location exceed the grid size.")
             ,prev))))))

(defun %analyze-atomic-binop! (expr env context location)
  "Analyzer for atomic-binop! -- expands to the bounded CAS loop and delegates."
  (analyze-expression (%atomic-binop-expand expr) env context location))

(defun %atomic-op-parts (expr)
  "Destructures (atomic-op! LOCATION OP-F).  Returns (values location fn)."
  (values (second expr) (third expr)))

(defun %atomic-op-expand (expr)
  "The forward lowering: a bounded CAS retry loop returning the prior value.
   Mirrors %atomic-binop-expand exactly, minus the value argument."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
           :message (format nil "atomic-op!: expected 2 arguments (location op-f), got ~a.  The form is (atomic-op! location #'op), and the function is UNARY -- for a two-argument operator use (atomic-binop! location #'op arg)."
                            (1- (length expr)))
           :source-location nil))
  (multiple-value-bind (loc fn) (%atomic-op-parts expr)
    (let ((prev (gensym "AO-PREV"))
          (done (gensym "AO-DONE"))
          (r    (gensym "AO-R"))
          (old  (gensym "AO-OLD"))
          (new  (gensym "AO-NEW")))
      ;; No ARG to bind once here -- that is the whole difference from atomic-binop!.
      `(let ((,prev (~ ,@(cdr loc))))
         (let ((,done 0))
           ;; get-global-LINEAR-size: get-global-size is named in analysis/core.lisp's builtin
           ;; list but has no analyzer.  See %atomic-binop-expand for why the bound is the
           ;; contender count rather than a constant.
           (dotimes+ (,r (+ (to-int (get-global-linear-size)) 1))
             (when (= ,done 0)
               (let ((,old (~ ,@(cdr loc))))
                 (let ((,new ,(%175-apply-unop fn old)))
                   (when (= (%atomic-cas-ok! ,loc ,old ,new) 1)
                     (set! ,prev ,old)
                     (set! ,done 1))))))
           (r-t-assert-0 (= ,done 1)
                         "atomic-op!: the bounded CAS retry loop exhausted without succeeding, so this update was LOST.  The bound is global_size + 1, which is sound when each thread performs the operation once; it can be exceeded if atomic-op! runs inside a loop, so that total successes on this location exceed the grid size.")
           ,prev)))))

(defun %analyze-atomic-op! (expr env context location)
  "Analyzer for atomic-op! -- expands to the bounded CAS loop and delegates."
  (analyze-expression (%atomic-op-expand expr) env context location))
