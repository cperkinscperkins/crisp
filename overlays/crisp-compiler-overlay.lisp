;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-12 -- adversarial sweep (tests/adversarial/issues.md, Resolved) folded:
;;;;   * c-t struct values (ADV-018) -> validate-and-reorder-struct-args, %split-ct-props-args,
;;;;                                  %member-access-struct-name (src/structs.lisp); analyze-struct-construction,
;;;;                                  analyze-extract/insert-struct-member-expression, get-struct-member-index
;;;;                                  (src/analysis/structs.lisp); generate-node-ir semantic-struct-construction
;;;;                                  (src/codegen.lisp); %generate-struct-accessor (src/macros.lisp);
;;;;                                  types-compatible-p (src/type-checker.lisp); types-assignable-p +
;;;;                                  %ct-qualified-arg-fits-bare-param-p (src/types/hierarchy.lisp)
;;;;   * enums (ADV-005/007)       -> ensure-template-instantiation, %keyword-literal-type->enum (src/templates.lisp);
;;;;                                  ensure-branch-compatibility, %enum-type-for-branch (src/analysis/control.lisp);
;;;;                                  %promote-to-float-adjoint, %ad-enum-type-p, %backward-value-expr (src/autodiff.lisp);
;;;;                                  crisp-unsupported-form-error + *unsupported-form-hints* (src/errors.lisp)
;;;;   * kernel boundary (014/015/019/020) -> %validate-kernel-parameters, marshall-cell/-tensor + helpers
;;;;                                  (src/macros.lisp); %instantiate-callable-template, initialize-templates,
;;;;                                  *explicit-instantiation-names* (src/templates.lisp)
;;;;   * c-t-output (ADV-006)      -> src/macros.lisp
;;;;   * shadowed lets in AD (ADV-001/002) -> anf-transform + %alpha-rename-shadowed-lets (src/anf-transform.lisp)
;;;; Before that, 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)

(in-package :crisp.compiler)

;;; =====================================================================================
;;; Endeavour 185 (math-ops) P0 -- integer division (chapter 32/06) and float -> int rounding.
;;;   * (floor a b) / (ceil a b) / (round a b) on integers were registered as float->int CASTS,
;;;     so the divisor was silently ignored; one-argument floor / ceil / round on a float BITCAST
;;;     the float's bits instead of converting.  Both silent.
;;;   * D1: the remainder exists only in a multiple-value binding, (let ((q r (floor a b))) ...);
;;;     everywhere else these forms (and /) stay single-valued.
;;;   * BUG 062: unsigned / (and rem / mod, which expand through /) used a SIGNED divide.
;;; Lowering is branch-free: the floor / ceil / round corrections are selects.
;;; =====================================================================================

(defparameter *185-divmod-ops*
  '(("/" . :trunc) ("FLOOR" . :floor) ("CEIL" . :ceil) ("ROUND" . :round))
  "Crisp operator name -> integer division rounding mode (endeavour 185).")

(defun %185-int-category-p (type-name)
  "T when TYPE-NAME is a signed or unsigned integer SCALAR type."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts type-name)
    (declare (ignore bits))
    (and (member cat '(:signed-int :unsigned-int)) (null lanes) t)))

(defun %185-float-category-p (type-name)
  "T when TYPE-NAME is a floating-point SCALAR type."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts type-name)
    (declare (ignore bits))
    (and (eq cat :float) (null lanes) t)))

(defun %185-analyze-int-operands (op-name a-form b-form env context location)
  "Analyzes the two operands of integer division OP-NAME and returns (values a-node b-node type).
   Both must be the same integer scalar type; an integer LITERAL operand is coerced to the other
   operand's type (as mod does), since a literal is INT only because of how the reader spells it.
   Float operands are an error: two-argument floor / ceil / round are integer division."
  (let* ((cl-pkg (find-package :crisp-language))
         (a-node (analyze-expression a-form env context (append location '(1))))
         (b-node (analyze-expression b-form env context (append location '(2))))
         (a-type (get-single-value-type a-node))
         (b-type (get-single-value-type b-node)))
    (when (or (%185-float-category-p a-type) (%185-float-category-p b-type))
      (error 'crisp-compiler-error
             :message (format nil "Two-argument ~(~a~) is integer division (chapter 32/06), but got ~(~a~) and ~(~a~).  For a float quotient rounded to an integer, write (~(~a~) (/ a b))"
                              op-name a-type b-type (if (string= op-name "/") "truncate" op-name))
             :source-location location))
    (flet ((coerce-literal (form node to-type pos)
             (let ((fn (find-symbol (format nil "TO-~a" (symbol-name to-type)) cl-pkg)))
               (if (and (integerp form) fn)
                   (analyze-expression (list fn form) env context (append location (list pos)))
                   node))))
      (unless (eq a-type b-type)
        (cond ((integerp b-form) (setf b-node (coerce-literal b-form b-node a-type 2) b-type a-type))
              ((integerp a-form) (setf a-node (coerce-literal a-form a-node b-type 1) a-type b-type)))))
    (unless (and (%185-int-category-p a-type) (eq a-type b-type))
      (error 'crisp-compiler-error
             :message (format nil "~(~a~): both operands must be the same integer type; got ~(~a~) and ~(~a~)"
                              op-name a-type b-type)
             :source-location location))
    (values a-node b-node a-type)))

(defun analyze-rounding-division-expression (expr env context location)
  "Analyzes floor / ceil / round (endeavour 185, decision D2):
     (floor x)    float x -> int, rounded toward -infinity (ceil: +infinity; round: nearest, ties even);
                  an integer x is returned unchanged
     (floor a b)  integer division, chapter 32/06 -- the QUOTIENT here; the remainder is available
                  through a multiple-value binding (see %185-maybe-divmod-node)."
  (let* ((op-name (symbol-name (first expr)))
         (mode (cdr (assoc op-name *185-divmod-ops* :test #'string=)))
         (args (rest expr)))
    (case (length args)
      (1 (let* ((x-node (analyze-expression (first args) env context (append location '(1))))
                (x-type (get-single-value-type x-node)))
           (cond ((%185-int-category-p x-type) x-node)
                 ((%185-float-category-p x-type)
                  (make-semantic-hw-op :op (ecase mode (:floor '%185-fp-floor-int) (:ceil '%185-fp-ceil-int)
                                                  (:round '%185-fp-round-int))
                                       :type 'int :args (list x-node) :source-location location))
                 (t (error 'crisp-compiler-error
                           :message (format nil "(~(~a~) x): x must be a float or integer scalar; got ~(~a~)" op-name x-type)
                           :source-location location)))))
      (2 (multiple-value-bind (a-node b-node type)
             (%185-analyze-int-operands op-name (first args) (second args) env context location)
           (make-semantic-hw-op :op (ecase mode (:floor '%185-idiv-floor) (:ceil '%185-idiv-ceil)
                                           (:round '%185-idiv-round))
                                :type type :args (list a-node b-node) :source-location location)))
      (t (error 'crisp-compiler-error
                :message (format nil "~(~a~) takes one argument (float -> int) or two (integer division); got ~a"
                                 op-name (length args))
                :source-location location)))))

(defun %185-maybe-divmod-node (init-form binding-vars env context location)
  "D1: when a let binds TWO OR MORE variables to (/ a b), (floor a b), (ceil a b) or (round a b),
   returns the two-value quotient / remainder node; otherwise NIL (the caller analyzes INIT-FORM
   normally).  Float operands of / are refused here: float division has no second value."
  (when (and (> (length binding-vars) 1)
             (consp init-form) (symbolp (first init-form)) (= (length init-form) 3))
    (let ((mode (cdr (assoc (symbol-name (first init-form)) *185-divmod-ops* :test #'string=))))
      (when mode
        (multiple-value-bind (a-node b-node type)
            (%185-analyze-int-operands (symbol-name (first init-form)) (second init-form) (third init-form)
                                       env context location)
          (log:debug "%185-maybe-divmod-node: ~a ~a -> (~a ~a)" (first init-form) mode type type)
          (make-semantic-hw-op :op (ecase mode (:trunc '%185-idivmod-trunc) (:floor '%185-idivmod-floor)
                                          (:ceil '%185-idivmod-ceil) (:round '%185-idivmod-round))
                               :type (list type type) :args (list a-node b-node) :source-location location))))))

(defun %185-int-divmod (builder module mode a b type-name)
  "Integer division of A by B (both TYPE-NAME) rounded per MODE (:trunc :floor :ceil :round, the
   last ties-to-even).  Returns (values quotient remainder) with remainder = a - q*b.
   Branch-free, written as integer arithmetic (sign masks from arithmetic shifts, a borrow bit for
   the unsigned compare); InstCombine is free to re-form icmp/select from it.
   OPEN (BUG 120): on the BMG, four of these written INLINE in one kernel and SLP-vectorized at -O3
   into <4 x i32> / <4 x i1> ran and stored nothing -- the IR and SPIR-V look correct, and the same
   code through a helper function is right.  Not yet understood."
  (multiple-value-bind (cat bits) (%hw-type-parts type-name)
    (let* ((unsigned-p (eq cat :unsigned-int))
           (ity (crisp-type-to-llvm-type type-name module))
           (k (lambda (v) (llvm-const-int ity (ldb (byte 64 0) v) (if (minusp v) 1 0))))
           (zero (funcall k 0))
           (one (funcall k 1))
           (top (funcall k (1- bits)))
           (q0 (if unsigned-p (llvm-build-udiv builder a b "idiv_q0") (llvm-build-sdiv builder a b "idiv_q0")))
           (r0 (if unsigned-p
                   (crisp.llvm-bindings::llvm-build-urem builder a b "idiv_r0")
                   (crisp.llvm-bindings::llvm-build-srem builder a b "idiv_r0"))))
      (labels ((add (x y) (llvm-build-add builder x y "idiv_add"))
               (sub (x y) (llvm-build-sub builder x y "idiv_sub"))
               (bxor (x y) (crisp.llvm-bindings::llvm-build-xor builder x y "idiv_xor"))
               (band (x y) (crisp.llvm-bindings::llvm-build-and builder x y "idiv_and"))
               (bor (x y) (crisp.llvm-bindings::llvm-build-or builder x y "idiv_or"))
               (bnot (x) (crisp.llvm-bindings::llvm-build-not builder x "idiv_not"))
               (sign-mask (x) (crisp.llvm-bindings::llvm-build-a-shr builder x top "idiv_sm")) ; 0 or -1
               (top-bit (x) (crisp.llvm-bindings::llvm-build-l-shr builder x top "idiv_tb"))                       ; 0 or 1
               (nonzero (x) (top-bit (bor x (sub zero x))))                                   ; 1 iff x /= 0
               (absval (x) (let ((m (sign-mask x))) (sub (bxor x m) m)))
               (remainder (q) (sub a (llvm-build-mul builder q b "idiv_qb"))))
        (let ((q (ecase mode
                   (:trunc q0)
                   (:floor
                    (if unsigned-p
                        q0
                        ;; r0 /= 0 and sign(r0) /= sign(b): truncation rounded UP, so subtract 1
                        (sub q0 (band (nonzero r0) (sign-mask (bxor r0 b))))))
                   (:ceil
                    (if unsigned-p
                        (add q0 (nonzero r0))
                        ;; r0 /= 0 and same signs: truncation rounded DOWN, so add 1
                        (add q0 (band (nonzero r0) (add (sign-mask (bxor r0 b)) one)))))
                   (:round
                    ;; |r0| against |b| - |r0| (no overflow: |r0| < |b|), compared UNSIGNED
                    (let* ((abs-r (if unsigned-p r0 (absval r0)))
                           (abs-b (if unsigned-p b (absval b)))
                           (rest (sub abs-b abs-r))
                           (diff (sub rest abs-r))
                           ;; borrow of rest - abs-r, i.e. abs-r > rest (unsigned)
                           (gt (top-bit (bor (band (bnot rest) abs-r) (band (bnot (bxor rest abs-r)) diff))))
                           (eq (sub one (nonzero (bxor rest abs-r))))
                           (up (bor gt (band eq (band q0 one)))))                             ; 0 or 1
                      (if unsigned-p
                          (add q0 up)
                          ;; move AWAY from zero: +up for a non-negative exact quotient, -up otherwise
                          (let ((s (sign-mask (bxor a b))))
                            (add q0 (sub (bxor up s) s)))))))))
          (values q (if (eq mode :trunc) r0 (remainder q))))))))

;;; Endeavour 185 P0, BUG 120 workaround (decision: option 3, agreed with Chris 2026-10-12).
;;; Integer floor / ceil / round are lowered as a CALL to one internal, noinline helper per
;;; (mode, type, one-or-two values) instead of inline.  Inline, four such divisions in one kernel
;;; were SLP-vectorized at -O3 and the BMG ran the kernel and stored nothing (BUG 120, open --
;;; correct IR and SPIR-V); the same code behind a function call is right on the BMG.  GPU
;;; compilers inline device functions themselves, so the call costs nothing at run time.
;;; Truncating / (and rem / mod) stays inline: it was never affected.

(defun %185-divmod-helper (module mode type-name two-values-p)
  "The internal helper function computing integer division MODE on TYPE-NAME, returning the
   quotient, or {quotient, remainder} when TWO-VALUES-P.  Created on first use in MODULE:
   internal linkage, noinline, SPIR_FUNC on SPIR-V.  Its body is %185-int-divmod."
  (let* ((name (format nil "__crisp_idiv_~(~a~)_~(~a~)~:[~;_qr~]" mode type-name two-values-p))
         (existing (crisp.llvm-bindings::llvm-get-named-function module name)))
    (if (not (cffi:null-pointer-p existing))
        existing
        (let* ((ity (crisp-type-to-llvm-type type-name module))
               (ret-type (if two-values-p (get-llvm-return-type module (list type-name type-name)) ity))
               (fn (cffi:with-foreign-objects ((ptypes :pointer 2))
                     (setf (cffi:mem-aref ptypes :pointer 0) ity
                           (cffi:mem-aref ptypes :pointer 1) ity)
                     (crisp.llvm-bindings::llvm-add-function
                      module name (crisp.llvm-bindings::llvm-function-type ret-type ptypes 2 nil))))
               (ctx (llvm-get-module-context module))
               (kind (crisp.llvm-bindings::llvm-get-enum-attribute-kind-for-name "noinline" 8))
               (tmp (llvm-create-builder)))
          (log:debug "%185-divmod-helper: creating ~a" name)
          (crisp.llvm-bindings::llvm-set-linkage fn 8)                 ; LLVMInternalLinkage
          (llvm-add-attribute-at-index fn +llvm-attribute-function-index+
                                       (crisp.llvm-bindings::llvm-create-enum-attribute ctx kind 0))
          (when (eq *target-backend* :spirv)
            (llvm-set-function-call-conv fn 75))                      ; SPIR_FUNC
          (unwind-protect
               (progn
                 (llvm-position-builder-at-end tmp (llvm-append-basic-block fn "entry"))
                 (multiple-value-bind (q r)
                     (%185-int-divmod tmp module mode
                                      (crisp.llvm-bindings::llvm-get-param fn 0)
                                      (crisp.llvm-bindings::llvm-get-param fn 1)
                                      type-name)
                   (llvm-build-ret tmp (if two-values-p
                                           (let ((agg (llvm-get-undef ret-type)))
                                             (setf agg (llvm-build-insert-value tmp agg q 0 "idivmod_q"))
                                             (llvm-build-insert-value tmp agg r 1 "idivmod_r"))
                                           q))))
            (llvm-dispose-builder tmp))
          fn))))

(defun %185-lower-divmod (builder module mode arg-vals arg-types result-type two-values-p)
  "Shared %hw-lower body for the endeavour-185 integer division ops.  :trunc is inline; floor /
   ceil / round call their helper (BUG 120 workaround, see %185-divmod-helper)."
  (if (eq mode :trunc)
      (multiple-value-bind (q r) (%185-int-divmod builder module mode (first arg-vals) (second arg-vals) (first arg-types))
        (if two-values-p
            (let ((agg (llvm-get-undef (get-llvm-return-type module result-type))))
              (setf agg (llvm-build-insert-value builder agg q 0 "idivmod_q"))
              (llvm-build-insert-value builder agg r 1 "idivmod_r"))
            q))
      (let* ((fn (%185-divmod-helper module mode (first arg-types) two-values-p))
             (ret-type (if two-values-p
                           (get-llvm-return-type module result-type)
                           (crisp-type-to-llvm-type (first arg-types) module)))
             (call (cffi:with-foreign-objects ((ptypes :pointer 2) (avals :pointer 2))
                     (loop for i from 0 for v in arg-vals
                           do (setf (cffi:mem-aref ptypes :pointer i) (llvm-type-of v)
                                    (cffi:mem-aref avals :pointer i) v))
                     (crisp.llvm-bindings::llvm-build-call2
                      builder (crisp.llvm-bindings::llvm-function-type ret-type ptypes 2 nil)
                      fn avals 2 "idiv_call"))))
        (%propagate-callee-cc-to-call call fn)
        call)))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%185-idiv-floor)) builder module arg-vals arg-types result-type)
  "(floor a b) on integers, quotient only (endeavour 185)."
  (%185-lower-divmod builder module :floor arg-vals arg-types result-type nil))
(defmethod %hw-lower ((op (eql '%185-idiv-ceil)) builder module arg-vals arg-types result-type)
  "(ceil a b) on integers, quotient only (endeavour 185)."
  (%185-lower-divmod builder module :ceil arg-vals arg-types result-type nil))
(defmethod %hw-lower ((op (eql '%185-idiv-round)) builder module arg-vals arg-types result-type)
  "(round a b) on integers, quotient only, ties to even (endeavour 185)."
  (%185-lower-divmod builder module :round arg-vals arg-types result-type nil))
(defmethod %hw-lower ((op (eql '%185-idivmod-trunc)) builder module arg-vals arg-types result-type)
  "(let ((q r (/ a b))) ...) on integers: quotient and remainder (endeavour 185)."
  (%185-lower-divmod builder module :trunc arg-vals arg-types result-type t))
(defmethod %hw-lower ((op (eql '%185-idivmod-floor)) builder module arg-vals arg-types result-type)
  "(let ((q r (floor a b))) ...) on integers (endeavour 185)."
  (%185-lower-divmod builder module :floor arg-vals arg-types result-type t))
(defmethod %hw-lower ((op (eql '%185-idivmod-ceil)) builder module arg-vals arg-types result-type)
  "(let ((q r (ceil a b))) ...) on integers (endeavour 185)."
  (%185-lower-divmod builder module :ceil arg-vals arg-types result-type t))
(defmethod %hw-lower ((op (eql '%185-idivmod-round)) builder module arg-vals arg-types result-type)
  "(let ((q r (round a b))) ...) on integers, ties to even (endeavour 185)."
  (%185-lower-divmod builder module :round arg-vals arg-types result-type t))

(defun %185-lower-fp-to-int (builder module base arg-vals arg-types result-type)
  "llvm.BASE (floor / ceil / rint) on the float argument, then fptosi to RESULT-TYPE."
  (let ((rounded (%hw-intrinsic builder module base (first arg-types) (first arg-vals))))
    (llvm-build-fp-to-si builder rounded (crisp-type-to-llvm-type result-type module) "fp_round_int")))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%185-fp-floor-int)) builder module arg-vals arg-types result-type)
  "(floor x) on a float: toward -infinity, then to int (endeavour 185)."
  (%185-lower-fp-to-int builder module "floor" arg-vals arg-types result-type))
(defmethod %hw-lower ((op (eql '%185-fp-ceil-int)) builder module arg-vals arg-types result-type)
  "(ceil x) on a float: toward +infinity, then to int (endeavour 185)."
  (%185-lower-fp-to-int builder module "ceil" arg-vals arg-types result-type))
(defmethod %hw-lower ((op (eql '%185-fp-round-int)) builder module arg-vals arg-types result-type)
  "(round x) on a float: nearest, ties to even (llvm.rint in the default rounding mode), then to int."
  (%185-lower-fp-to-int builder module "rint" arg-vals arg-types result-type))

;; src/codegen.lisp -- BUG 062: semantic-div used llvm-build-sdiv for every integer type.  Written
;; out from def-binary-op-codegen with the integer instruction chosen by signedness.
(defmethod generate-node-ir ((node semantic-div) builder module var-env di-builder di-scope location-map)
  "Generates IR for SEMANTIC-DIV.  Endeavour 185 / BUG 062: udiv for unsigned integer types."
  (multiple-value-bind (lhs lhs-loc) (generate-node-ir (semantic-div-left-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore lhs-loc))
    (multiple-value-bind (rhs rhs-loc) (generate-node-ir (semantic-div-right-arg node) builder module var-env di-builder di-scope location-map)
      (declare (ignore rhs-loc))
      (let* ((result-type-name (semantic-div-type node))
             (lhs-type-name (get-single-value-type (semantic-div-left-arg node)))
             (rhs-type-name (get-single-value-type (semantic-div-right-arg node)))
             (lhs-raw (extract-primary-value builder lhs (semantic-node-type (semantic-div-left-arg node))))
             (rhs-raw (extract-primary-value builder rhs (semantic-node-type (semantic-div-right-arg node))))
             (casted-lhs (build-cast-if-needed builder module lhs-raw lhs-type-name result-type-name))
             (casted-rhs (build-cast-if-needed builder module rhs-raw rhs-type-name result-type-name))
             (category (%arith-category result-type-name))
             (inst (case category
                     (:float (%apply-precision-fmf (llvm-build-fdiv builder casted-lhs casted-rhs "fop_tmp")))
                     (:unsigned-int (llvm-build-udiv builder casted-lhs casted-rhs "iop_tmp"))
                     (t (llvm-build-sdiv builder casted-lhs casted-rhs "iop_tmp"))))
             (di-location (%attach-debug-loc inst node module di-builder di-scope location-map)))
        (values inst di-location)))))

;;; Endeavour 185 P0: the let hook (decision D1) -- a two-variable binding to (/ a b), (floor a b),
;;; (ceil a b) or (round a b) gets the two-value quotient / remainder node.

;; src/analysis/control.lisp
(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression.
   Extended (091): strips leading declare forms from the body, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules.
   Extended (120): propagates each binding's uniformity from its init."
  (unless (and (>= (length expr) 2) (listp (cadr expr)))
    (error "Malformed let form: ~a" expr))

  (let* ((binding-forms (cadr expr))
         (raw-body (cddr expr)))

    ;; Strip leading declares and check for execution-context declarations
    (multiple-value-bind (body-forms decl-specs)
        (%strip-execution-context-declares raw-body)
      (multiple-value-bind (has-grid-level has-workgroup-level)
          (%check-context-declarations decl-specs location)

        ;; Bind context vars for the body analysis
        (let ((*in-grid-level-context* (or *in-grid-level-context* has-grid-level))
              (*in-workgroup-level-context* (or *in-workgroup-level-context* has-workgroup-level)))

          ;; Implement let* scoping by sequentially building the environment.
          (multiple-value-bind (final-env analyzed-bindings)
              (let ((current-env env)
                    (bindings-list '()))
                (loop for binding in binding-forms
                      for i from 0 do
                        (log:debug "Analyzing let binding form: ~s" binding)

                        (let ((is-flat-mvb (and (> (length binding) 2)
                                                (not (listp (first binding))))))

                          (let* ((binding-vars (if is-flat-mvb
                                                   (butlast binding)
                                                   (if (and (= (length binding) 2) (listp (first binding)))
                                                       (first binding)
                                                       (list (first binding)))))
                                 (init-form (first (last binding)))
                                 (current-binding-name (if (= (length binding-vars) 1) (first binding-vars) nil))
                                 (init-node
                                  (let ((old-name (compiler-context-current-binding-name context)))
                                    (when current-binding-name
                                          (setf (compiler-context-current-binding-name context) current-binding-name))
                                    (unwind-protect
                                        ;; Endeavor 120 gap #4: permit to-*-uniform only when it
                                        ;; is the direct initializer of this binding.
                                        (let ((*to-uniform-allowed* (%to-uniform-form-p init-form))
                                              (init-loc (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1)))))
                                          ;; Endeavour 185 D1: (q r (floor a b)) etc. -> quotient AND remainder.
                                          (or (%185-maybe-divmod-node init-form binding-vars current-env context init-loc)
                                              (analyze-expression init-form current-env context init-loc)))
                                      (when current-binding-name
                                            (setf (compiler-context-current-binding-name context) old-name)))))
                                 (init-node-types (semantic-node-type init-node))
                                 ;; Endeavor 120: uniformity of the init, computed in the
                                 ;; pre-binding environment (let* sequential scope).
                                 (init-uniformity (calculate-uniformity-state init-node current-env)))

                            (cond
                             ((= (length binding-vars) 1)
                               (let* ((var-name (first binding-vars))
                                      (var-type (get-single-value-type init-node)))
                                 (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a Uniformity: ~a" var-name var-type init-uniformity)
                                 (push (cons var-name init-node) bindings-list)
                                 (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                             :uniformity init-uniformity)
                                                         current-env))))

                             ((> (length binding-vars) 1)
                               (unless (listp init-node-types)
                                 (error "Cannot destructure a single-value return into multiple variables at ~a. Got type ~a for binding ~a."
                                   (semantic-node-source-location init-node) init-node-types binding))
                               (unless (>= (length init-node-types) (length binding-vars))
                                 (error "Not enough return values from ~a to bind ~a variables at ~a" init-form (length binding-vars) (semantic-node-source-location init-node)))

                               (loop for var-name in binding-vars
                                     for j from 0 do
                                       (let* ((var-type (nth j init-node-types))
                                              (extract-node (make-semantic-extract-value
                                                             :type var-type
                                                             :aggregate-node init-node
                                                             :index j
                                                             :source-location (semantic-node-source-location init-node))))
                                         (push (cons var-name extract-node) bindings-list)
                                         (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                                     :uniformity init-uniformity)
                                                                 current-env)))))
                             (t (error "Malformed let binding: ~a" binding))))))
                (values current-env (reverse bindings-list)))

            ;; Endeavor 120 gap #2/#3: apply (declare (uniform v)) hints from the
            ;; let block. Only let-bound variables are eligible (so the hint
            ;; cannot leak into an outer scope's shared parameter-def). A hint on
            ;; a provably-divergent binding is an error -- the user can always use
            ;; a plain if/when/dotimes instead, so an unsafe assertion buys
            ;; nothing.
            (let ((let-bound-names (mapcar #'car analyzed-bindings)))
              (dolist (uvar (loop for d in decl-specs
                                  when (and (consp d) (symbolp (car d))
                                            (string-equal (symbol-name (car d)) "UNIFORM"))
                                  append (rest d)))
                (cond
                 ((not (member uvar let-bound-names))
                  (log:warn "(declare (uniform ~s)) ignored: not a variable bound by this let." uvar))
                 (t
                  (let ((pd (find-variable-in-env uvar final-env)))
                    (cond
                     ((null pd)
                      (log:warn "(declare (uniform ~s)): binding not found." uvar))
                     ((eq (parameter-def-uniformity pd) :divergent)
                      (error 'crisp-compiler-error
                        :message (format nil "(declare (uniform ~a)) is invalid: ~a is provably divergent in this scope. Use a plain if/when/dotimes instead."
                                         uvar uvar)
                        :source-location location))
                     (t
                      (log:debug "Endeavor 120: (declare (uniform ~a)) -> :uniform (was ~a)"
                                 uvar (parameter-def-uniformity pd))
                      (setf (parameter-def-uniformity pd) :uniform))))))))

            (let* ((analyzed-body (analyze-body-expressions body-forms final-env context (append location '(2))))
                   (last-body-node (first (last analyzed-body)))
                   (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
              (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                         analyzed-bindings analyzed-body return-type)
              (make-semantic-let :type return-type
                                 :bindings analyzed-bindings
                                 :body analyzed-body
                                 :source-location location))))))))

;;; Endeavour 185 P0: floor / ceil / round get analyze-rounding-division-expression (was the cast analyzer).

;; src/analysis/ops.lisp
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
  ;; Endeavour 185: floor / ceil / round are float -> int rounding (one argument) AND integer
  ;; division (two arguments); they were the cast analyzer, which ignored a second argument.
  (setf (gethash 'floor *expression-analyzers*) 'analyze-rounding-division-expression)
  (setf (gethash 'ceil *expression-analyzers*) 'analyze-rounding-division-expression)
  (setf (gethash 'round *expression-analyzers*) 'analyze-rounding-division-expression)
  ;; Endeavour 185 P1: sqrt / rsqrt / abs / clamp / *!, by name in both packages.
  (%185-register-math-op-analyzers)

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
                        ("%CHECK-REDUCTION-IDENTITY" %analyze-check-reduction-identity)
                        ;; 178: the rank / element-type check a reduce-vec expansion carries.
                        ("%CHECK-REDUCE-VEC-ELEMENT" %analyze-check-reduce-vec-element)))
          (setf (gethash (intern (first pair) pkg) *expression-analyzers*)
                (second pair)))))))

;;; =====================================================================================
;;; Endeavour 185 (math-ops) P1 -- sqrt, rsqrt (chapter 32/02), abs, clamp, *! (chapter 32/04).
;;; Documented as implemented; were "Unsupported form".  One semantic-hw-op each (the endeavour-170
;;; node), registered BY NAME under both :crisp-language and :crisp.compiler (as the 173 shuffles
;;; are): sqrt and abs are COMMON-LISP symbols, and :crisp-language uses nothing, so user source
;;; reads them as fresh :crisp-language symbols.
;;; =====================================================================================

(defparameter *185-math-op-names* '("SQRT" "RSQRT" "ABS" "CLAMP" "*!" "TANH" "ERF" "EXP2")
  "Endeavour 185 P1: the math operator names analyzed by analyze-185-math-op.")

(defun %185-op-named-p (sym name)
  "T when SYM is a symbol whose name is NAME (any package)."
  (and (symbolp sym) (string= (symbol-name sym) name)))

(defun %185-crisp-sym (name)
  "The :crisp-language symbol NAME -- what the AD walk must emit so the backward source reads
   like user source."
  (intern name (find-package :crisp-language)))

(defun %185-coerce-literal-node (form node to-type env context location pos)
  "If FORM is a numeric literal whose node type is not TO-TYPE, re-analyze it as (TO-<TO-TYPE> FORM);
   otherwise return NODE.  A literal has no independent type worth defending."
  (let ((fn (and (numberp form) (symbolp to-type)
                 (find-symbol (format nil "TO-~a" (symbol-name to-type)) (find-package :crisp-language)))))
    (if (and fn (not (eq (get-single-value-type node) to-type)))
        (analyze-expression (list fn form) env context (append location (list pos)))
        node)))

(defun analyze-185-math-op (expr env context location)
  "Analyzes sqrt / rsqrt / abs / clamp / *! (endeavour 185 P1)."
  (let* ((name (symbol-name (first expr)))
         (args (rest expr))
         (want (cond ((member name '("SQRT" "RSQRT" "ABS" "TANH" "ERF" "EXP2") :test #'string=) 1)
                     ((string= name "CLAMP") 3)
                     (t 2))))
    (unless (= (length args) want)
      (error 'crisp-compiler-error
             :message (format nil "~(~a~) takes ~a argument~:p; got ~a" name want (length args))
             :source-location location))
    (if (string= name "*!")
        ;; D6: for the basic types (accum T) is T, so *! is *.
        (analyze-expression (list (%185-crisp-sym "*") (first args) (second args)) env context location)
        (let* ((nodes (loop for a in args for i from 1
                            collect (analyze-expression a env context (append location (list i)))))
               (x-type (get-single-value-type (first nodes))))
          (multiple-value-bind (cat bits lanes) (%hw-type-parts x-type)
            (cond
              ((member name '("SQRT" "RSQRT" "TANH" "ERF" "EXP2") :test #'string=)
               (unless (and (eq cat :float) (member bits '(32 64)) (null lanes))
                 (error 'crisp-compiler-error
                        :message (format nil "~(~a~): operand must be float or double; got ~(~a~).  Write (~(~a~) (to-float x)) for an integer."
                                         name x-type name)
                        :source-location location))
               (make-semantic-hw-op :op (cond ((string= name "SQRT") '%185-sqrt) ((string= name "RSQRT") '%185-rsqrt)
                                              ((string= name "TANH") '%185-tanh) ((string= name "ERF") '%185-erf)
                                              (t '%185-exp2))
                                    :type x-type :args nodes :source-location location))
              ((string= name "ABS")
               (unless (member cat '(:float :signed-int :unsigned-int))
                 (error 'crisp-compiler-error
                        :message (format nil "abs: operand must be numeric; got ~(~a~)" x-type)
                        :source-location location))
               (make-semantic-hw-op :op '%185-abs :type x-type :args nodes :source-location location))
              (t ; CLAMP
               (unless (member cat '(:float :signed-int :unsigned-int))
                 (error 'crisp-compiler-error
                        :message (format nil "clamp: x must be numeric; got ~(~a~)" x-type)
                        :source-location location))
               (let ((nodes (list (first nodes)
                                  (%185-coerce-literal-node (second args) (second nodes) x-type env context location 2)
                                  (%185-coerce-literal-node (third args) (third nodes) x-type env context location 3))))
                 (unless (every (lambda (n) (eq (get-single-value-type n) x-type)) (rest nodes))
                   (error 'crisp-compiler-error
                          :message (format nil "clamp: x, min-val and max-val must have the same type; got ~(~{~a~^, ~}~)"
                                           (mapcar #'get-single-value-type nodes))
                          :source-location location))
                 (make-semantic-hw-op :op '%185-clamp :type x-type :args nodes :source-location location)))))))))

(defparameter *185-bit-op-names* '("ASH" "LOGAND" "LOGIOR" "LOGXOR" "LOGNOT" "POPCOUNT")
  "Endeavour 185 P2: the integer bit operator names analyzed by analyze-185-bit-op.")

(defun %185-register-math-op-analyzers ()
  "Registers analyze-185-math-op under every *185-math-op-names* name, in both :crisp-language
   and :crisp.compiler.  Called from register-ops-analyzers."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (name *185-math-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-math-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-math-op))
    ;; P2: the integer bit operations
    (dolist (name *185-bit-op-names*)
      (setf (gethash (intern name cl-pkg) *expression-analyzers*) 'analyze-185-bit-op)
      (setf (gethash (intern name cc-pkg) *expression-analyzers*) 'analyze-185-bit-op))))

(defun %185-sqrt-call (builder module x type-name)
  "sqrt of X (float / double scalar) through the transcendental callee selection: llvm.sqrt under
   ieee on both backends (NVPTX: sqrt.rn; no libdevice); native_sqrt under fast on SPIR-V; fast
   flags (afn -> sqrt.approx) under fast on PTX."
  (multiple-value-bind (cat bits) (%hw-type-parts type-name)
    (declare (ignore cat))
    (%apply-precision-fmf
     (%hw-call builder module (%math-call-name "llvm.sqrt" "native_sqrt" nil nil 1 bits)
               (crisp-type-to-llvm-type type-name module) (list x) "sqrt_tmp"))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%185-sqrt)) builder module arg-vals arg-types result-type)
  "sqrt (endeavour 185): see %185-sqrt-call."
  (declare (ignore result-type))
  (%185-sqrt-call builder module (first arg-vals) (first arg-types)))

(defmethod %hw-lower ((op (eql '%185-rsqrt)) builder module arg-vals arg-types result-type)
  "rsqrt (endeavour 185, D4): ieee -> 1/sqrt(x), each step correctly rounded; fast -> the
   approximate hardware instruction (op-rsqrt-approx's lowering)."
  (if (eq *math-precision* :fast)
      (%hw-lower 'op-rsqrt-approx builder module arg-vals arg-types result-type)
      (%apply-precision-fmf
       (llvm-build-fdiv builder (%hw-float-const builder module (first arg-types) 1.0)
                        (%185-sqrt-call builder module (first arg-vals) (first arg-types)) "rsqrt_tmp"))))

(defmethod %hw-lower ((op (eql '%185-abs)) builder module arg-vals arg-types result-type)
  "abs (endeavour 185): llvm.fabs for floats, llvm.abs (INT_MIN stays INT_MIN) for signed
   integers, the value itself for unsigned."
  (declare (ignore result-type))
  (let ((x (first arg-vals)) (type-name (first arg-types)))
    (multiple-value-bind (cat bits lanes) (%hw-type-parts type-name)
      (ecase cat
        (:float (%hw-intrinsic builder module "fabs" type-name x))
        (:signed-int
         (%hw-call builder module (format nil "llvm.abs.~a" (%hw-intrinsic-suffix cat bits lanes nil))
                   (%hw-int-llvm-type bits lanes) (list x (llvm-const-int (llvm-int1-type) 0 0)) "abs_tmp"))
        (:unsigned-int x)))))

(defmethod %hw-lower ((op (eql '%185-clamp)) builder module arg-vals arg-types result-type)
  "clamp (endeavour 185): min(max(x, lo), hi) -- llvm.maxnum / minnum for floats, smax / smin or
   umax / umin for integers."
  (declare (ignore result-type))
  (destructuring-bind (x lo hi) arg-vals
    (let ((type-name (first arg-types)))
      (multiple-value-bind (cat bits lanes) (%hw-type-parts type-name)
        (if (eq cat :float)
            (%hw-intrinsic builder module "minnum" type-name
                           (%hw-intrinsic builder module "maxnum" type-name x lo) hi)
            (%hw-int-intrinsic builder module "min" cat bits lanes
                               (%hw-int-intrinsic builder module "max" cat bits lanes x lo) hi))))))

(defun %185-math-backward (v expr emit-fn local-adj-fn)
  "Backward rules for the endeavour-185 P1 ops, matched by NAME.  Returns T when EXPR is one of
   them (the clause handled it), else NIL."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x))
         (sym (n) (%185-crisp-sym n)))
    (let ((op (car expr)))
      (cond
        ((%185-op-named-p op "SQRT")            ; d/da sqrt(a) = 0.5 / sqrt(a)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 0.5 (,(sym "SQRT") ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "RSQRT")           ; d/da a^-1/2 = -0.5 rsqrt(a) / a
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* -0.5 (/ (,(sym "RSQRT") ,a) ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "TANH")            ; d/da tanh(a) = 1 - tanh(a)^2
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (- 1.0 (* (,(sym "TANH") ,a) (,(sym "TANH") ,a))) ,v-adj)))))
           t))
        ((%185-op-named-p op "ERF")             ; d/da erf(a) = 2/sqrt(pi) exp(-a^2)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* 1.1283791670955126 (exp (- 0.0 (* ,a ,a)))) ,v-adj)))))
           t))
        ((%185-op-named-p op "EXP2")            ; d/da 2^a = ln2 2^a
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (* 0.6931471805599453 (,(sym "EXP2") ,a)) ,v-adj)))))
           t))
        ((%185-op-named-p op "ABS")             ; d/da |a| = sign(a)  (0 at 0)
         (let ((a (cadr expr)) (v-adj (local-adj v)))
           (when (symbolp a)
             (emit `(set! ,(local-adj a) (+ ,(local-adj a)
                                            (* (- (to-float (> ,a 0.0)) (to-float (< ,a 0.0))) ,v-adj)))))
           t))
        ((%185-op-named-p op "CLAMP")           ; x passes through inside [lo,hi]; lo below; hi above
         (destructuring-bind (x lo hi) (cdr expr)
           (let ((v-adj (local-adj v)))
             (when (symbolp x)
               (emit `(set! ,(local-adj x) (+ ,(local-adj x) (* (to-float (* (>= ,x ,lo) (<= ,x ,hi))) ,v-adj)))))
             (when (symbolp lo)
               (emit `(set! ,(local-adj lo) (+ ,(local-adj lo) (* (to-float (< ,x ,lo)) ,v-adj)))))
             (when (symbolp hi)
               (emit `(set! ,(local-adj hi) (+ ,(local-adj hi) (* (to-float (> ,x ,hi)) ,v-adj)))))
             t)))
        ((%185-op-named-p op "*!")              ; D6: *! is *
         (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
           (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
           (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))
           t))
        ;; P2 + P0: integer results carry no gradient -- the bit operations, and floor / ceil /
        ;; round (float -> int rounding is piecewise constant: derivative 0 almost everywhere).
        ((some (lambda (n) (%185-op-named-p op n))
               '("ASH" "LOGAND" "LOGIOR" "LOGXOR" "LOGNOT" "POPCOUNT" "FLOOR" "CEIL" "ROUND"))
         t)
        (t nil)))))

;;; Endeavour 185 P1: the AD hook -- the P1 ops (matched by name) before the math gate.

;; src/autodiff.lisp
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                        &key hof-handler-fn (error-on-unknown t)
                                        tensor-inputs-ht
                                        scratch-tile-syms)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr)."
  (cond
   ;; BUG 099: a COPY binding, v := s.  The reverse walk has already processed every use of v, so
   ;; v's adjoint is final here and flows to s unchanged.  Without this clause the binding fell
   ;; through to (t nil) and v's adjoint was dropped -- (let ((v0 v)) (* v v0)) differentiated to x,
   ;; not 2x.  (%backward-value-expr has the same rule for let/if VALUE expressions; the top-level
   ;; walk never went there.)
   ;;
   ;; Scoped to SCALAR dataflow: a tensor input, a scratch tile, or a view alias keeps its adjoint
   ;; in a TENSOR named <sym>_ADJ, and minting a scalar of the same name here would shadow it (the
   ;; collision described at the accessor clause below).  And only when v already HAS an adjoint --
   ;; a copy nothing downstream reads contributes nothing, and must not mint a binding for s.
   ((and expr (symbolp expr) (not (keywordp expr)))
     (when (and (not (eq expr v))
                (gethash v adjoint-map)
                (not (and tensor-inputs-ht (gethash expr tensor-inputs-ht)))
                ;; scratch-tile-syms is a HASH TABLE here (a list elsewhere) -- accept either.
                (not (if (hash-table-p scratch-tile-syms)
                         (gethash expr scratch-tile-syms)
                         (member expr scratch-tile-syms)))
                (not (%ad-resolve-view-alias expr))
                (not (%ad-resolve-view-alias v)))
       (log:debug "099: copy binding ~a := ~a -- adjoint flows to ~a" v expr expr)
       (funcall emit-fn `(set! ,(funcall local-adj-fn expr)
                               (+ ,(funcall local-adj-fn expr) ,(funcall local-adj-fn v))))))
   ;; Endeavour 170: the hardware math ops carry their own backward rules.  First, because the
   ;; clauses below key on operator names this one does not share.
   ((%hw-op-form-op expr)
     (%hw-op-backward v expr emit-fn local-adj-fn))
   ;; Endeavour 173: likewise the warp shuffles.  Ahead of the catch-all below, which would
   ;; otherwise report a shuffle as simply not differentiable.
   ((%shuffle-form-op expr)
     (%shuffle-backward v expr emit-fn local-adj-fn))
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
   ;; Endeavour 185: sqrt / rsqrt / abs / clamp / *! (and the zero-gradient integer ops), by name.
   ((and (consp expr) (%185-math-backward v expr emit-fn local-adj-fn)) t)
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

;;; =====================================================================================
;;; Endeavour 185 P2: generic noinline-helper lowering (BUG 120 family).  On the BMG, inline
;;; popcount gave a wrong lane and inline ash made zeModuleCreate fail; inline floor / round
;;; stored nothing.  The same code behind a function call is right.

(defun %185-helper-call (builder module name ret-type arg-vals body-fn)
  "Call the internal noinline helper NAME : RET-TYPE(types of ARG-VALS), creating it in MODULE on
   first use with a body built by BODY-FN, called as (BODY-FN helper-builder param-values) and
   returning the value to ret.  SPIR_FUNC on SPIR-V; the call site gets the callee's CC."
  (let* ((n (length arg-vals))
         (existing (crisp.llvm-bindings::llvm-get-named-function module name))
         (fnty (cffi:with-foreign-objects ((ptypes :pointer (max 1 n)))
                 (loop for i from 0 for v in arg-vals
                       do (setf (cffi:mem-aref ptypes :pointer i) (llvm-type-of v)))
                 (crisp.llvm-bindings::llvm-function-type ret-type ptypes n nil)))
         (fn (if (not (cffi:null-pointer-p existing))
                 existing
                 (let ((fn (crisp.llvm-bindings::llvm-add-function module name fnty))
                       (tmp (llvm-create-builder)))
                   (log:debug "%185-helper-call: creating ~a" name)
                   (crisp.llvm-bindings::llvm-set-linkage fn 8)            ; LLVMInternalLinkage
                   (llvm-add-attribute-at-index
                    fn +llvm-attribute-function-index+
                    (crisp.llvm-bindings::llvm-create-enum-attribute
                     (llvm-get-module-context module)
                     (crisp.llvm-bindings::llvm-get-enum-attribute-kind-for-name "noinline" 8) 0))
                   (when (eq *target-backend* :spirv)
                     (llvm-set-function-call-conv fn 75))                 ; SPIR_FUNC
                   (unwind-protect
                        (progn
                          (llvm-position-builder-at-end tmp (llvm-append-basic-block fn "entry"))
                          (llvm-build-ret tmp (funcall body-fn tmp
                                                       (loop for i below n
                                                             collect (crisp.llvm-bindings::llvm-get-param fn i)))))
                     (llvm-dispose-builder tmp))
                   fn)))
         (call (cffi:with-foreign-objects ((avals :pointer (max 1 n)))
                 (loop for i from 0 for v in arg-vals do (setf (cffi:mem-aref avals :pointer i) v))
                 (crisp.llvm-bindings::llvm-build-call2 builder fnty fn avals n "helper_call"))))
    (%propagate-callee-cc-to-call call fn)
    call))

;;; Endeavour 185 (math-ops) P2 -- the integer bit operations, chapter 32/05:
;;; ash, logand, logior, logxor, lognot, popcount.  Registered by name like P1.
;;; ash follows Common Lisp (decision D3) and is DEFINED for every count: a shift by at least the
;;; bit width gives 0 (left), or 0 / -1 (right; sign fill for a negative signed value).  LLVM makes
;;; such shifts poison and the hardware disagrees, so the lowering clamps the shift amount and
;;; selects -- branch-free; constant counts fold away.
;;; =====================================================================================

(defun analyze-185-bit-op (expr env context location)
  "Analyzes ash / logand / logior / logxor / lognot / popcount (endeavour 185 P2)."
  (let* ((name (symbol-name (first expr)))
         (args (rest expr))
         (want (if (member name '("LOGNOT" "POPCOUNT") :test #'string=) 1 2)))
    (unless (= (length args) want)
      (error 'crisp-compiler-error
             :message (format nil "~(~a~) takes ~a argument~:p; got ~a" name want (length args))
             :source-location location))
    (let* ((nodes (loop for a in args for i from 1
                        collect (analyze-expression a env context (append location (list i)))))
           (x-type (get-single-value-type (first nodes))))
      (unless (%185-int-category-p x-type)
        (error 'crisp-compiler-error
               :message (format nil "~(~a~): operands must be integers (chapter 32/05); got ~(~a~)" name x-type)
               :source-location location))
      (cond
        ((string= name "ASH")
         ;; the count may be any integer type; codegen converts it to x's type
         (unless (%185-int-category-p (get-single-value-type (second nodes)))
           (error 'crisp-compiler-error
                  :message (format nil "ash: the count must be an integer; got ~(~a~)" (get-single-value-type (second nodes)))
                  :source-location location))
         (make-semantic-hw-op :op '%185-ash :type x-type :args nodes :source-location location))
        ((= want 1)
         (make-semantic-hw-op :op (if (string= name "LOGNOT") '%185-lognot '%185-popcount)
                              :type x-type :args nodes :source-location location))
        (t
         (let ((b (%185-coerce-literal-node (second args) (second nodes) x-type env context location 2)))
           (unless (eq (get-single-value-type b) x-type)
             (error 'crisp-compiler-error
                    :message (format nil "~(~a~): both operands must be the same integer type; got ~(~a~) and ~(~a~)"
                                     name x-type (get-single-value-type b))
                    :source-location location))
           (make-semantic-hw-op :op (cond ((string= name "LOGAND") '%185-logand)
                                          ((string= name "LOGIOR") '%185-logior)
                                          (t '%185-logxor))
                                :type x-type :args (list (first nodes) b) :source-location location)))))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%185-logand)) builder module arg-vals arg-types result-type)
  "logand (endeavour 185)."
  (declare (ignore module arg-types result-type))
  (crisp.llvm-bindings::llvm-build-and builder (first arg-vals) (second arg-vals) "logand"))
(defmethod %hw-lower ((op (eql '%185-logior)) builder module arg-vals arg-types result-type)
  "logior (endeavour 185)."
  (declare (ignore module arg-types result-type))
  (crisp.llvm-bindings::llvm-build-or builder (first arg-vals) (second arg-vals) "logior"))
(defmethod %hw-lower ((op (eql '%185-logxor)) builder module arg-vals arg-types result-type)
  "logxor (endeavour 185)."
  (declare (ignore module arg-types result-type))
  (crisp.llvm-bindings::llvm-build-xor builder (first arg-vals) (second arg-vals) "logxor"))
(defmethod %hw-lower ((op (eql '%185-lognot)) builder module arg-vals arg-types result-type)
  "lognot (endeavour 185)."
  (declare (ignore module arg-types result-type))
  (crisp.llvm-bindings::llvm-build-not builder (first arg-vals) "lognot"))
(defmethod %hw-lower ((op (eql '%185-popcount)) builder module arg-vals arg-types result-type)
  "popcount (endeavour 185): llvm.ctpop -- set bits of the two's-complement representation.
   Behind a noinline helper: inline, the BMG gave a wrong lane (BUG 120 family)."
  (declare (ignore result-type))
  (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
    (let ((ity (%hw-int-llvm-type bits lanes))
          (iname (format nil "llvm.ctpop.~a" (%hw-intrinsic-suffix cat bits lanes nil))))
      (%185-helper-call builder module (format nil "__crisp_popcount_~(~a~)" (first arg-types)) ity arg-vals
                        (lambda (b params) (%hw-call b module iname ity params "popcount"))))))

(defun %185-ash-body (builder module x c x-type)
  "ash (endeavour 185, D3) of X by C (already X-TYPE).  Branch-free:
     left  = count >= bits ? 0 : x << count
     right = x >> min(-count, bits-1)   (ashr: sign fill; lshr for unsigned, and 0 when -count >= bits)
     ash   = count >= 0 ? left : right"
  (multiple-value-bind (cat bits) (%hw-type-parts x-type)
    (let* ((unsigned-p (eq cat :unsigned-int))
           (ity (crisp-type-to-llvm-type x-type module))
           (zero (llvm-const-int ity 0 0))
           (width (llvm-const-int ity bits 0))
           (top (llvm-const-int ity (1- bits) 0)))
      (labels ((icmp (pred a b) (llvm-build-icmp builder pred a b "ash_c"))
               (sel (p a b) (crisp.llvm-bindings::llvm-build-select builder p a b "ash_sel"))
               (umin (a b) (sel (icmp +llvm-int-ult+ a b) a b)))
        (let* ((nonneg (icmp +llvm-int-sge+ c zero))
               (lc (umin (sel nonneg c zero) top))
               (left (sel (icmp +llvm-int-sge+ c width) zero
                          (crisp.llvm-bindings::llvm-build-shl builder x lc "ash_shl")))
               (n (llvm-build-sub builder zero c "ash_neg"))
               (rc (umin (sel nonneg zero n) top))
               (right (if unsigned-p
                          (sel (icmp +llvm-int-sge+ n width) zero
                               (crisp.llvm-bindings::llvm-build-l-shr builder x rc "ash_lshr"))
                          (crisp.llvm-bindings::llvm-build-a-shr builder x rc "ash_ashr"))))
          (sel nonneg left right))))))

(defmethod %hw-lower ((op (eql '%185-ash)) builder module arg-vals arg-types result-type)
  "ash (endeavour 185, D3): see %185-ash-body.  Behind a noinline helper: inline, the BMG failed
   zeModuleCreate (BUG 120 family)."
  (declare (ignore result-type))
  (let* ((x-type (first arg-types))
         (c (build-cast-if-needed builder module (second arg-vals) (second arg-types) x-type)))
    (%185-helper-call builder module (format nil "__crisp_ash_~(~a~)" x-type)
                      (crisp-type-to-llvm-type x-type module) (list (first arg-vals) c)
                      (lambda (b params) (%185-ash-body b module (first params) (second params) x-type)))))

;;; =====================================================================================
;;; Endeavour 185 (math-ops) P3 -- tanh, erf, exp2 (decision D5; not in the design doc, added for
;;; the contests).  Transcendentals like endeavour 128's: libdevice on PTX (__nv_tanhf / __nv_erff /
;;; __nv_exp2f), the platform's builtins on SPIR-V.  exp2 has an LLVM intrinsic and an OpenCL
;;; native_exp2 for :fast; tanh and erf are called as OpenCL builtins (_Z4tanhf, _Z3erff), which
;;; llvm-spirv maps to OpenCL.std.
;;; =====================================================================================

(defun %185-ocl-builtin-name (base bits)
  "The Itanium-mangled OpenCL builtin BASE for a float (32) or double (64) argument: _Z4tanhf."
  (format nil "_Z~a~a~a" (length base) base (if (= bits 64) "d" "f")))

(defun %185-transcendental-call (builder module x type-name base)
  "Call transcendental BASE (\"tanh\" \"erf\" \"exp2\") of X through the target's callee."
  (multiple-value-bind (cat bits) (%hw-type-parts type-name)
    (declare (ignore cat))
    (let ((callee (cond
                    ((string= base "exp2")
                     (%math-call-name "llvm.exp2" "native_exp2" "__nv_exp2" nil 1 bits))
                    ((eq *target-backend* :ptx)
                     (%libdevice-fn-name (format nil "__nv_~a" base) (= bits 32)))
                    (t (%185-ocl-builtin-name base bits)))))
      (log:debug "%185-transcendental-call: ~a ~a -> ~a" base type-name callee)
      (%apply-precision-fmf
       (%hw-call builder module callee (crisp-type-to-llvm-type type-name module) (list x)
                 (format nil "~a_tmp" base))))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%185-tanh)) builder module arg-vals arg-types result-type)
  "tanh (endeavour 185 P3)."
  (declare (ignore result-type))
  (%185-transcendental-call builder module (first arg-vals) (first arg-types) "tanh"))
(defmethod %hw-lower ((op (eql '%185-erf)) builder module arg-vals arg-types result-type)
  "erf (endeavour 185 P3)."
  (declare (ignore result-type))
  (%185-transcendental-call builder module (first arg-vals) (first arg-types) "erf"))
(defmethod %hw-lower ((op (eql '%185-exp2)) builder module arg-vals arg-types result-type)
  "exp2 (endeavour 185 P3)."
  (declare (ignore result-type))
  (%185-transcendental-call builder module (first arg-vals) (first arg-types) "exp2"))
