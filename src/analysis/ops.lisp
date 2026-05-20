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

(defmacro def-comparison-analyzer (name node-constructor op-string)
  `(defun ,name (expr env context location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node (analyze-expression (second expr) env context (append location '(1))))
            (right-node (analyze-expression (third expr) env context (append location '(2)))))
       ;; We intentionally do not enforce strict numeric types here yet,
       ;; allowing for potential future pointer comparisons etc.
       ;; Result is always INT (boolean 0/1).
       (,node-constructor :type 'int :left-arg left-node :right-arg right-node :source-location location))))

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
