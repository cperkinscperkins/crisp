;;;; crisp-compiler-overlay.lisp — late-bound fixes for the CRISP.COMPILER package.
;;;;
;;;; APPEND full replacement definitions here while developing; they are loaded after src/ and
;;;; win by late binding.  Do NOT patch in place -- append, and note above each one which src
;;;; file it belongs to, so it can be folded back later.
;;;;
;;;; TWO THINGS THAT BITE (both learned the hard way, endeavour 165):
;;;;
;;;;   * A HANDLER REGISTERED BY OBJECT IS NOT LATE-BOUND.  src/autodiff.lisp does
;;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile), which captures
;;;;     the function OBJECT at load time.  Redefining that defun here is DEAD CODE until you
;;;;     also re-register.  The failure is partial and therefore nasty: a callee overridden by
;;;;     name goes live while its caller stays stale.
;;;;
;;;;   * NEVER PUT A DOUBLE QUOTE INSIDE A DOCSTRING.  It closes the string early and the rest of
;;;;     the prose becomes BODY FORMS -- the first bare word is then an unbound variable, and the
;;;;     build emits no warning.  It fails only when the function is CALLED.  Cost: a red CI.
;;;;
;;;; Emptied 2026-09-08: everything folded into src/ (endeavour 165).

(in-package :crisp.compiler)

;;;; =============================================================================================
;;;; BUG 060 (endeavour 170): arithmetic on FLOATING-POINT device vectors emitted integer
;;;; instructions (mul <4 x float>, sdiv <2 x double>, ...) -- invalid IR.
;;;; The device-vector registry (src/types/registry.lisp) records only :device-vector and drops the
;;;; element category, so def-binary-op-codegen's `(eq category :float)` test was always false.
;;;; Fix: dispatch on the ARITHMETIC category -- the element's category for a device vector.
;;;; Regression: tests/spec/054-device-vectors/29-float-vec-arithmetic.crisp
;;;; =============================================================================================

;; src/codegen.lisp  (place just before def-binary-op-codegen)
(defun %arith-category (type-name)
  "Category that decides which ARITHMETIC instruction family applies to TYPE-NAME.
   Scalars: their own crisp-type-category. Device vectors (float4, ushort2, half3 ...): the
   category of their ELEMENT type, found by stripping the trailing lane count from the name --
   the registry names every device vector <element><width> and does not record the element
   category itself (BUG 060). Returns NIL when TYPE-NAME is unknown."
  (let ((ct (and type-name (gethash type-name *crisp-types*))))
    (cond
      ((null ct) nil)
      ((not (eq (crisp-type-category ct) :device-vector))
       (crisp-type-category ct))
      (t
       (let* ((name (symbol-name type-name))
              (end (or (position-if-not #'digit-char-p name :from-end t) -1))
              (base-name (subseq name 0 (1+ end)))
              (base-ct (or (let ((s (find-symbol base-name :crisp-language)))
                             (and s (gethash s *crisp-types*)))
                           (let ((s (find-symbol base-name :crisp.compiler)))
                             (and s (gethash s *crisp-types*))))))
         (log:debug "%arith-category: device vector ~a -> element ~a -> ~a"
                    type-name base-name (and base-ct (crisp-type-category base-ct)))
         (and base-ct (crisp-type-category base-ct)))))))

;; src/codegen.lisp  (replaces the def-binary-op-codegen macro; the four expansions follow)
(defmacro def-binary-op-codegen (node-type int-inst float-inst accessor-prefix)
  (let ((left-accessor (intern (format nil "~a-LEFT-ARG" accessor-prefix)))
        (right-accessor (intern (format nil "~a-RIGHT-ARG" accessor-prefix)))
        (type-accessor (intern (format nil "~a-TYPE" accessor-prefix))))
    `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
       ,(format nil "Generates IR for ~a. Float scalars AND float device vectors use the FP instruction (BUG 060)." node-type)
       (multiple-value-bind (lhs lhs-loc) (generate-node-ir (,left-accessor node) builder module var-env di-builder di-scope location-map)
         (declare (ignore lhs-loc))
         (multiple-value-bind (rhs rhs-loc) (generate-node-ir (,right-accessor node) builder module var-env di-builder di-scope location-map)
           (declare (ignore rhs-loc))
           (let* ((result-type-name (,type-accessor node))
                  (lhs-type-name (get-single-value-type (,left-accessor node)))
                  (rhs-type-name (get-single-value-type (,right-accessor node)))
                  ;; Ensure MVR structs are unpacked
                  (lhs-raw (extract-primary-value builder lhs (semantic-node-type (,left-accessor node))))
                  (rhs-raw (extract-primary-value builder rhs (semantic-node-type (,right-accessor node))))
                  (casted-lhs (build-cast-if-needed builder module lhs-raw lhs-type-name result-type-name))
                  (casted-rhs (build-cast-if-needed builder module rhs-raw rhs-type-name result-type-name))
                  (arith-cat (%arith-category result-type-name))
                  (inst (if (eq arith-cat :float)
                            (%apply-precision-fmf (,float-inst builder casted-lhs casted-rhs "fop_tmp"))
                            (,int-inst builder casted-lhs casted-rhs "iop_tmp")))
                  (di-location (%attach-debug-loc inst node module di-builder di-scope location-map)))
             (values inst di-location)))))))

;; src/codegen.lisp  (unchanged forms, re-expanded so they pick up the macro above)
(def-binary-op-codegen semantic-add llvm-build-add llvm-build-fadd "SEMANTIC-ADD")
(def-binary-op-codegen semantic-sub llvm-build-sub llvm-build-fsub "SEMANTIC-SUB")
(def-binary-op-codegen semantic-mul llvm-build-mul llvm-build-fmul "SEMANTIC-MUL")
(def-binary-op-codegen semantic-div llvm-build-sdiv llvm-build-fdiv "SEMANTIC-DIV")

;;;; =============================================================================================
;;;; Endeavour 170 -- hardware-supported math ops (op-fma, op-saturate, op-imad, ...).
;;;; Design + every judgment call: tests/spec/170-hardware-supported-math-ops/hardware-supported-math-ops.md
;;;;   D1 exports + node struct live here until folded (see put_temp_files_here/170-patches.md)
;;;;   D2 one generic node, semantic-hw-op, for every op
;;;;   D3 node dispatchers are extended by wrapping (each wrapper = one clause when folded)
;;;; =============================================================================================

;; src/analysis/ops.lisp  (the symbols themselves are exported/imported in src/package.lisp -- already patched)
(defparameter *hw-op-symbols*
  '(op-fma op-saturate op-imad op-imad-sat
    op-abs-diff op-abs-diff-add op-sad op-min3 op-max3
    op-rsqrt-approx op-rcp-approx op-log2-approx op-exp2-approx
    op-sin-approx op-cos-approx op-sincos-approx)
  "Endeavour 170: the hardware-supported math op symbols (exported from :crisp.compiler, imported
   into :crisp-language by src/package.lisp).")

;; src/semantic.lisp  (fold: after semantic-atan2)
(defstruct semantic-hw-op
  "Endeavour 170: one hardware-supported math op. OP is the op symbol (e.g. OP-FMA), TYPE the
   result type (a type symbol, or a list of two for op-sincos-approx), ARGS the analyzed
   argument nodes in source order."
  op type args source-location)

;;; ---------------------------------------------------------------------------------------------
;;; Type helpers
;;; ---------------------------------------------------------------------------------------------

;; src/analysis/ops.lisp
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

;; src/analysis/ops.lisp
(defun %hw-type-named (base-name lanes)
  "The registered type symbol for element BASE-NAME with LANES lanes (NIL = scalar), or NIL."
  (let* ((name (if lanes (format nil "~a~a" base-name lanes) base-name))
         (sym (or (find-symbol name :crisp-language) (find-symbol name :crisp.compiler))))
    (and sym (gethash sym *crisp-types*) sym)))

;; src/analysis/ops.lisp
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

;;; ---------------------------------------------------------------------------------------------
;;; Analyzer
;;; ---------------------------------------------------------------------------------------------

;; src/analysis/ops.lisp
(defun %hw-fail (location fmt &rest args)
  "Signal the endeavour-170 type error: a crisp-type-error whose message is FMT applied to ARGS."
  (error 'crisp-type-error :message (apply #'format nil fmt args) :source-location location))

;; src/analysis/ops.lisp
(defun %hw-check-multiplier-accumulator (op a-type b-type c-type location family)
  "Shared A3 rules for the accumulator ops (op-fma: FAMILY :float; op-imad / op-imad-sat: :int).
   a and b must be the same type of FAMILY; c must be the same family, the same lane count, and at
   least as wide. For :int, c must also have the same signedness (D4). For 16-bit floats, a c of
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

;; src/analysis/ops.lisp
(defun %hw-op-result-type (op arg-types location)
  "The result type of endeavour-170 OP applied to ARG-TYPES, or a crisp-type-error. See the
   endeavour doc (A3, A4, D4) for the rules."
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

;; src/analysis/ops.lisp
(defun analyze-hw-op-expression (expr env context location)
  "Analyzes an endeavour-170 hardware math op form, e.g. (op-fma a b c)."
  (let* ((op (find (symbol-name (first expr)) *hw-op-symbols* :key #'symbol-name :test #'string=))
         (arg-nodes (loop for arg in (rest expr)
                          for i from 1
                          collect (analyze-expression arg env context (append location (list i)))))
         (arg-types (mapcar #'get-single-value-type arg-nodes))
         (result-type (%hw-op-result-type op arg-types location)))
    (log:debug "analyze-hw-op-expression: ~a ~a -> ~a" op arg-types result-type)
    (make-semantic-hw-op :op op :type result-type :args arg-nodes :source-location location)))

;; src/analysis/ops.lisp  (fold: add the dolist to register-ops-analyzers)
;; NB: the original is captured in a DEFVAR via FDEFINITION. `(let ((original #'f)) (defun f ...))`
;; does NOT work: SBCL folds (funcall original) into a direct call to the global F -- the wrapper
;; itself -- and recurses until the stack overflows. DEFVAR also keeps a reload from re-capturing.
(defvar *hw-original-register-ops-analyzers* (fdefinition 'register-ops-analyzers))
(progn
  (defun register-ops-analyzers ()
    "Registers all expression analyzer functions (see the src definition), plus the endeavour 170
     hardware math ops."
    (funcall *hw-original-register-ops-analyzers*)
    (dolist (sym *hw-op-symbols*)
      (setf (gethash sym *expression-analyzers*) 'analyze-hw-op-expression))))

;;; ---------------------------------------------------------------------------------------------
;;; Node dispatchers (D3)
;;; ---------------------------------------------------------------------------------------------

;; src/analysis/core.lisp  (fold: a clause in semantic-node-type)
(defvar *hw-original-semantic-node-type* (fdefinition 'semantic-node-type))
(progn
  (defun semantic-node-type (node)
    "Returns the Crisp type of a semantic node (see the src definition); endeavour 170 adds
     semantic-hw-op."
    (if (semantic-hw-op-p node)
        (semantic-hw-op-type node)
        (funcall *hw-original-semantic-node-type* node))))

;; src/analysis/core.lisp  (fold: a clause in semantic-node-source-location)
(defvar *hw-original-semantic-node-source-location* (fdefinition 'semantic-node-source-location))
(progn
  (defun semantic-node-source-location (node)
    "Returns a semantic node's source location (see the src definition); endeavour 170 adds
     semantic-hw-op."
    (if (semantic-hw-op-p node)
        (semantic-hw-op-source-location node)
        (funcall *hw-original-semantic-node-source-location* node))))

;; src/analysis/core.lisp  (fold: a clause in calculate-uniformity-state)
(defvar *hw-original-calculate-uniformity-state* (fdefinition 'calculate-uniformity-state))
(progn
  (defun calculate-uniformity-state (node env)
    "Uniformity of a semantic node (see the src definition). Endeavour 170: a hardware math op
     combines its arguments like arithmetic -- divergent if any is, uniform if all are."
    (if (semantic-hw-op-p node)
        (let ((states (mapcar (lambda (a) (calculate-uniformity-state a env)) (semantic-hw-op-args node))))
          (cond ((member :divergent states) :divergent)
                ((every (lambda (s) (eq s :uniform)) states) :uniform)
                (t :unknown)))
        (funcall *hw-original-calculate-uniformity-state* node env))))

;; src/analysis/core.lisp  (fold: add the op names to %uni-analyze's arithmetic contagion list)
(defvar *hw-original-%uni-analyze* (fdefinition '%uni-analyze))
(progn
  (defun %uni-analyze (form env)
    "Uniformity walk of a raw body form (see the src definition). Endeavour 170: hardware math
     ops combine uniformity like arithmetic."
    (if (and (consp form) (symbolp (car form)) (car form)
             (member (symbol-name (car form)) *hw-op-symbols* :key #'symbol-name :test #'string=))
        (%uni-combine (mapcar (lambda (a) (%uni-analyze a env)) (cdr form)))
        (funcall *hw-original-%uni-analyze* form env))))

;;; ---------------------------------------------------------------------------------------------
;;; Codegen
;;; ---------------------------------------------------------------------------------------------

;; src/codegen.lisp
(defun %hw-llvm-int-type (bits)
  "The LLVM integer type of BITS (8/16/32/64) bits."
  (ecase bits
    (8 (llvm-int8-type)) (16 (llvm-int16-type)) (32 (llvm-int32-type)) (64 (llvm-int64-type))))

;; src/codegen.lisp
(defun %hw-intrinsic-suffix (cat bits lanes base-name)
  "LLVM intrinsic overload suffix for an element of CAT/BITS (BASE-NAME tells half from bfloat16),
   with LANES lanes or NIL: f32, bf16, i8, v4f32, v4i8 ..."
  (let ((elem (if (eq cat :float)
                  (if (string= base-name "BFLOAT16") "bf16" (format nil "f~a" bits))
                  (format nil "i~a" bits))))
    (if lanes (format nil "v~a~a" lanes elem) elem)))

;; src/codegen.lisp
(defun %hw-type-suffix (type-name)
  "LLVM intrinsic overload suffix for the Crisp scalar or device-vector TYPE-NAME."
  (multiple-value-bind (cat bits lanes base) (%hw-type-parts type-name)
    (%hw-intrinsic-suffix cat bits lanes base)))

;; src/codegen.lisp
(defun %hw-call (builder module name ret-type args &optional (label "hw_tmp"))
  "Declare (once) the function NAME : RET-TYPE(types of ARGS) and build a call to it with ARGS."
  (let ((n (length args)))
    (cffi:with-foreign-objects ((ptypes :pointer (max 1 n)) (avals :pointer (max 1 n)))
      (loop for i from 0 for v in args
            do (setf (cffi:mem-aref ptypes :pointer i) (llvm-type-of v)
                     (cffi:mem-aref avals :pointer i) v))
      (let* ((fnty (crisp.llvm-bindings::llvm-function-type ret-type ptypes n nil))
             (existing (crisp.llvm-bindings::llvm-get-named-function module name))
             (fn (if (cffi:null-pointer-p existing)
                     (crisp.llvm-bindings::llvm-add-function module name fnty)
                     existing)))
        (log:debug "%hw-call: ~a (~a args)" name n)
        (crisp.llvm-bindings::llvm-build-call2 builder fnty fn avals n label)))))

;; src/codegen.lisp
(defun %hw-intrinsic (builder module base type-name &rest args)
  "Call the overloaded intrinsic llvm.BASE.<suffix of TYPE-NAME> (returning TYPE-NAME's LLVM type)."
  (%hw-call builder module (format nil "llvm.~a.~a" base (%hw-type-suffix type-name))
            (crisp-type-to-llvm-type type-name module) args))

;; src/codegen.lisp
(defun %hw-widen (builder module value from-type to-type)
  "Widen VALUE from FROM-TYPE to TO-TYPE (same family and lane count): fpext for floats, sext for
   a signed source, zext for an unsigned source. Identity when the widths match."
  (multiple-value-bind (from-cat from-bits) (%hw-type-parts from-type)
    (multiple-value-bind (to-cat to-bits) (%hw-type-parts to-type)
      (declare (ignore to-cat))
      (let ((to-llvm (crisp-type-to-llvm-type to-type module)))
        (cond ((= from-bits to-bits) value)
              ((eq from-cat :float) (llvm-build-fp-ext builder value to-llvm "hw_fpext"))
              ((eq from-cat :signed-int) (llvm-build-sext builder value to-llvm "hw_sext"))
              (t (llvm-build-zext builder value to-llvm "hw_zext")))))))

;; src/codegen.lisp
(defun %hw-splat (builder elem-const lanes llvm-type)
  "ELEM-CONST as a value of LLVM-TYPE: the constant itself for a scalar (LANES NIL), else a vector
   with ELEM-CONST in every lane (insert-element on constants folds to a constant vector)."
  (if (null lanes)
      elem-const
      (let ((v (llvm-get-undef llvm-type)))
        (dotimes (i lanes v)
          (setf v (llvm-build-insert-element builder v elem-const
                                             (llvm-const-int (llvm-int32-type) i 0) "hw_splat"))))))

;; src/codegen.lisp
(defun %hw-float-const (builder module type-name value)
  "VALUE as a constant of float scalar/vector TYPE-NAME."
  (multiple-value-bind (cat bits lanes base) (%hw-type-parts type-name)
    (declare (ignore cat))
    (let ((elem-llvm (cond ((string= base "BFLOAT16") (llvm-bfloat-type))
                           ((= bits 16) (llvm-half-type))
                           ((= bits 32) (llvm-float-type))
                           (t (llvm-double-type)))))
      (%hw-splat builder (llvm-const-real elem-llvm (coerce value 'double-float)) lanes
                 (crisp-type-to-llvm-type type-name module)))))

;; src/codegen.lisp
(defun %hw-approx-flags (inst)
  "Stamp the approximate-function fast-math flag on INST (all flags under :fast precision).
   Endeavour 170: the *-approx ops grant approximation in EVERY precision context. Returns INST."
  (when (and inst (not (cffi:null-pointer-p inst))
             (/= 0 (llvm-can-value-use-fast-math-flags inst)))
    (llvm-set-fast-math-flags inst (if (eq *math-precision* :fast)
                                       +llvm-fast-math-all+
                                       +llvm-fast-math-approx-func+)))
  inst)

;; src/codegen.lisp
(defgeneric %hw-lower (op builder module arg-vals arg-types result-type)
  (:documentation "Endeavour 170: emit the IR for hardware math OP. ARG-VALS are the argument LLVM
   values, ARG-TYPES their Crisp types, RESULT-TYPE the node's type. Returns the result value."))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-hw-op) builder module var-env di-builder di-scope location-map)
  "Generates IR for an endeavour-170 hardware math op by dispatching %hw-lower on its op."
  (let* ((args (semantic-hw-op-args node))
         (arg-vals (mapcar (lambda (a)
                             (extract-primary-value
                              builder
                              (generate-node-ir a builder module var-env di-builder di-scope location-map)
                              (semantic-node-type a)))
                           args))
         (arg-types (mapcar #'get-single-value-type args))
         (op (semantic-hw-op-op node))
         (result (%hw-lower op builder module arg-vals arg-types (semantic-hw-op-type node))))
    (log:debug "generate-node-ir semantic-hw-op: ~a ~a -> ~a" op arg-types (semantic-hw-op-type node))
    (values result (%attach-debug-loc result node module di-builder di-scope location-map))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-fma)) builder module arg-vals arg-types result-type)
  "op-fma: widen a and b to the accumulator's type, then ONE llvm.fma call (guaranteed fused; never
   llvm.fmuladd, and no fast-math flags -- the op means the same in every precision context)."
  (destructuring-bind (a b c) arg-vals
    (destructuring-bind (a-type b-type c-type) arg-types
      (%hw-intrinsic builder module "fma" result-type
                     (%hw-widen builder module a a-type c-type)
                     (%hw-widen builder module b b-type c-type)
                     c))))

;;; ---------------------------------------------------------------------------------------------
;;; Endeavour 170, part 2: lowering for the remaining ops, the internal AD helper op, and autodiff.
;;; ---------------------------------------------------------------------------------------------

;; src/analysis/ops.lisp
(defparameter *hw-internal-op-symbols* '(%hw-sat-interior)
  "Endeavour 170: INTERNAL hardware-op forms that only the autodiff emits (never exported).
   (%hw-sat-interior R) => float mask, 1.0 where integer R lies STRICTLY inside its type's range.")

;; src/analysis/ops.lisp
(defun %hw-sat-interior-result-type (arg-types location)
  "Result type of the internal (%hw-sat-interior R): float for an integer scalar R, floatN for an
   integer device vector with N lanes."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
    (declare (ignore bits))
    (unless (and (= (length arg-types) 1) (member cat '(:signed-int :unsigned-int)))
      (%hw-fail location "%hw-sat-interior: expects one integer operand; got ~a" arg-types))
    (%hw-type-named "FLOAT" lanes)))

;; src/analysis/ops.lisp  (REPLACES the part-1 analyze-hw-op-expression: also resolves internal ops)
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

;; src/analysis/ops.lisp  (REPLACES the part-1 register-ops-analyzers wrapper)
(progn
  (defun register-ops-analyzers ()
    "Registers all expression analyzer functions (see the src definition), plus the endeavour 170
     hardware math ops and their internal AD helper ops."
    (funcall *hw-original-register-ops-analyzers*)
    (dolist (sym (append *hw-op-symbols* *hw-internal-op-symbols*))
      (setf (gethash sym *expression-analyzers*) 'analyze-hw-op-expression))))

;;; --- lowering helpers ------------------------------------------------------------------------

;; src/codegen.lisp
(defun %hw-int-llvm-type (bits lanes)
  "LLVM integer type of BITS bits, as a LANES-lane vector when LANES is non-NIL."
  (let ((elem (%hw-llvm-int-type bits)))
    (if lanes (llvm-vector-type elem lanes) elem)))

;; src/codegen.lisp
(defun %hw-int-const (builder bits lanes value signed-p)
  "Integer VALUE as a constant of BITS bits (a LANES-lane splat when LANES is non-NIL)."
  (%hw-splat builder
             (llvm-const-int (%hw-llvm-int-type bits) (ldb (byte 64 0) value) (if signed-p 1 0))
             lanes
             (%hw-int-llvm-type bits lanes)))

;; src/codegen.lisp
(defun %hw-int-intrinsic (builder module base cat bits lanes &rest args)
  "Call the integer intrinsic llvm.<s|u>BASE.<iBITS or vLANESiBITS> (signedness from CAT),
   returning that integer type. E.g. BASE \"min\" -> llvm.smin.i32 / llvm.umin.v4i8."
  (%hw-call builder module
            (format nil "llvm.~a~a.~a" (if (eq cat :signed-int) "s" "u") base
                    (%hw-intrinsic-suffix cat bits lanes nil))
            (%hw-int-llvm-type bits lanes)
            args))

;; src/codegen.lisp
(defun %hw-abs-diff-value (builder module a b a-type)
  "|a - b| as an unsigned value of A-TYPE's width: max(a,b) - min(a,b) with the signed or unsigned
   min/max intrinsics (branch-free). The wrapping subtraction is exact because the true difference
   always fits the unsigned result type."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts a-type)
    (llvm-build-sub builder
                    (%hw-int-intrinsic builder module "max" cat bits lanes a b)
                    (%hw-int-intrinsic builder module "min" cat bits lanes a b)
                    "hw_absdiff")))

;; src/codegen.lisp
(defun %hw-via-float (builder module x x-type fn)
  "Call FN with (value type) of X as a float -- fpext from half / bfloat16 first -- and return FN's
   result converted back to X-TYPE. Used by the library-routed *-approx ops, whose callees are
   f32 / f64 only."
  (multiple-value-bind (cat bits) (%hw-type-parts x-type)
    (declare (ignore cat))
    (if (/= bits 16)
        (funcall fn x x-type)
        (let* ((float-type (%hw-type-named "FLOAT" nil))
               (wide (llvm-build-fp-ext builder x (crisp-type-to-llvm-type float-type module) "hw_fpext"))
               (r (funcall fn wide float-type)))
          (llvm-build-fp-trunc builder r (crisp-type-to-llvm-type x-type module) "hw_fptrunc")))))

;; src/codegen.lisp
(defun %hw-approx-transcendental (builder module x x-type base native libdevice libdevice-fast)
  "Lower an approximate transcendental (BASE is \"sin\", \"cos\" or \"log2\") of float X.
   PTX f32 sin/cos: the llvm intrinsic + afn, which llc lowers to the NATIVE sin.approx.f32 /
   cos.approx.f32 instruction (probed; no libdevice). Everything else: the endeavour-128
   fast-precision callee (%math-call-name with precision bound to :fast): SPV f32 -> OpenCL
   native_*, PTX -> libdevice __nv_fast_*f / __nv_*, otherwise the llvm intrinsic. The afn flag is
   stamped in every case (the op grants approximation in every precision context)."
  (%hw-via-float
   builder module x x-type
   (lambda (xv xt)
     (multiple-value-bind (cat bits) (%hw-type-parts xt)
       (declare (ignore cat))
       (let* ((ty (crisp-type-to-llvm-type xt module))
              (name (if (and (eq *target-backend* :ptx) (= bits 32)
                             (member base '("sin" "cos") :test #'string=))
                        (format nil "llvm.~a.f32" base)
                        (let ((*math-precision* :fast))
                          (%math-call-name (format nil "llvm.~a" base) native libdevice libdevice-fast 1 bits)))))
         (log:debug "%hw-approx-transcendental: ~a ~a-bit on ~a -> ~a" base bits *target-backend* name)
         (%hw-approx-flags (%hw-call builder module name ty (list xv))))))))

;;; --- per-op lowering -------------------------------------------------------------------------

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-saturate)) builder module arg-vals arg-types result-type)
  "op-saturate: minnum(maxnum(x, 0), 1). maxnum returns the non-NaN operand, so a NaN input
   saturates to 0.0 (endeavour 170 decision D6)."
  (let* ((x (first arg-vals))
         (lo (%hw-intrinsic builder module "maxnum" result-type x (%hw-float-const builder module result-type 0.0))))
    (%hw-intrinsic builder module "minnum" result-type lo (%hw-float-const builder module result-type 1.0))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-imad)) builder module arg-vals arg-types result-type)
  "op-imad: widen a and b to the accumulator's type (sext / zext), multiply, add c. Wraps in c's
   type like ordinary integer arithmetic."
  (destructuring-bind (a b c) arg-vals
    (destructuring-bind (a-type b-type c-type) arg-types
      (declare (ignore result-type))
      (llvm-build-add builder
                      (llvm-build-mul builder
                                      (%hw-widen builder module a a-type c-type)
                                      (%hw-widen builder module b b-type c-type)
                                      "hw_imad_mul")
                      c "hw_imad"))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-imad-sat)) builder module arg-vals arg-types result-type)
  "op-imad-sat, reading (a) of the endeavour doc: the EXACT a*b+c, clamped once to c's range.
   W = max(2 * width(a), width(c)) bits (<= 64; the analyzer refuses 64-bit multipliers). a and b
   are extended to W, so their product is exact; c is extended to W; a saturating add in W is then
   the exact sum clamped to W's range; finally, if W is wider than c, clamp to c's range and
   truncate."
  (destructuring-bind (a b c) arg-vals
    (destructuring-bind (a-type b-type c-type) arg-types
      (declare (ignore b-type result-type))
      (multiple-value-bind (cat a-bits lanes) (%hw-type-parts a-type)
        (multiple-value-bind (c-cat c-bits) (%hw-type-parts c-type)
          (declare (ignore c-cat))
          (let* ((signed-p (eq cat :signed-int))
                 (w (max (* 2 a-bits) c-bits))
                 (wty (%hw-int-llvm-type w lanes))
                 (ext (lambda (v from-bits)
                        (cond ((= from-bits w) v)
                              (signed-p (llvm-build-sext builder v wty "hw_sext"))
                              (t (llvm-build-zext builder v wty "hw_zext")))))
                 (prod (llvm-build-mul builder (funcall ext a a-bits) (funcall ext b a-bits) "hw_sat_mul"))
                 (sum (%hw-int-intrinsic builder module "add.sat" cat w lanes prod (funcall ext c c-bits))))
            (log:debug "op-imad-sat lowering: ~a*~a+~a in W=~a bits" a-type a-type c-type w)
            (if (= w c-bits)
                sum
                (let* ((c-max (if signed-p (1- (expt 2 (1- c-bits))) (1- (expt 2 c-bits))))
                       (c-min (if signed-p (- (expt 2 (1- c-bits))) 0))
                       (clamped (%hw-int-intrinsic builder module "min" cat w lanes sum
                                                   (%hw-int-const builder w lanes c-max signed-p)))
                       (clamped (if signed-p
                                    (%hw-int-intrinsic builder module "max" cat w lanes clamped
                                                       (%hw-int-const builder w lanes c-min t))
                                    clamped)))
                  (llvm-build-trunc builder clamped (%hw-int-llvm-type c-bits lanes) "hw_sat_trunc")))))))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-abs-diff)) builder module arg-vals arg-types result-type)
  "op-abs-diff: |a - b| as the unsigned counterpart of a's type (A4)."
  (declare (ignore result-type))
  (%hw-abs-diff-value builder module (first arg-vals) (second arg-vals) (first arg-types)))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-abs-diff-add)) builder module arg-vals arg-types result-type)
  "op-abs-diff-add: |a - b| (unsigned), zero-extended to c's width, plus c."
  (destructuring-bind (a b c) arg-vals
    (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
      (declare (ignore cat))
      (multiple-value-bind (c-cat c-bits) (%hw-type-parts result-type)
        (declare (ignore c-cat))
        (let* ((d (%hw-abs-diff-value builder module a b (first arg-types)))
               (d (if (= c-bits bits) d (llvm-build-zext builder d (%hw-int-llvm-type c-bits lanes) "hw_zext"))))
          (llvm-build-add builder d c "hw_absdiffadd"))))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-sad)) builder module arg-vals arg-types result-type)
  "op-sad: per-lane |a_i - b_i| (unsigned), zero-extended to c's width, summed lane by lane into c.
   Lane extraction (not llvm.vector.reduce.add) keeps the IR in forms both translators accept."
  (destructuring-bind (a b c) arg-vals
    (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
      (declare (ignore cat))
      (multiple-value-bind (c-cat c-bits) (%hw-type-parts result-type)
        (declare (ignore c-cat))
        (let* ((d (%hw-abs-diff-value builder module a b (first arg-types)))
               (d (llvm-build-zext builder d (%hw-int-llvm-type c-bits lanes) "hw_zext"))
               (sum c))
          (declare (ignore bits))
          (dotimes (i lanes sum)
            (setf sum (llvm-build-add builder sum
                                      (llvm-build-extract-element builder d (llvm-const-int (llvm-int32-type) i 0) "hw_lane")
                                      "hw_sad"))))))))

;; src/codegen.lisp
(defun %hw-lower-min-max-3 (builder module arg-vals type-name float-base int-base)
  "Shared op-min3 / op-max3 lowering: f(f(a, b), c) with minnum/maxnum for floats and
   smin/umin (smax/umax) for integers."
  (destructuring-bind (a b c) arg-vals
    (multiple-value-bind (cat bits lanes) (%hw-type-parts type-name)
      (flet ((f (x y)
               (if (eq cat :float)
                   (%hw-intrinsic builder module float-base type-name x y)
                   (%hw-int-intrinsic builder module int-base cat bits lanes x y))))
        (f (f a b) c)))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-min3)) builder module arg-vals arg-types result-type)
  "op-min3: minnum (floats; returns the non-NaN operand) or smin/umin (integers)."
  (declare (ignore arg-types))
  (%hw-lower-min-max-3 builder module arg-vals result-type "minnum" "min"))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-max3)) builder module arg-vals arg-types result-type)
  "op-max3: maxnum (floats; returns the non-NaN operand) or smax/umax (integers)."
  (declare (ignore arg-types))
  (%hw-lower-min-max-3 builder module arg-vals result-type "maxnum" "max"))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-rsqrt-approx)) builder module arg-vals arg-types result-type)
  "op-rsqrt-approx: 1.0 / sqrt(x) with the afn flag on both instructions. On PTX llc fuses this
   into the native rsqrt.approx.f32 (probed); elsewhere it is an exact-ish value, which the op permits."
  (declare (ignore arg-types))
  (let ((s (%hw-approx-flags (%hw-intrinsic builder module "sqrt" result-type (first arg-vals)))))
    (%hw-approx-flags (llvm-build-fdiv builder (%hw-float-const builder module result-type 1.0) s "hw_rsqrt"))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-rcp-approx)) builder module arg-vals arg-types result-type)
  "op-rcp-approx: 1.0 / x with the afn flag (PTX: native rcp.approx.f32, probed)."
  (declare (ignore arg-types))
  (%hw-approx-flags (llvm-build-fdiv builder (%hw-float-const builder module result-type 1.0)
                                     (first arg-vals) "hw_rcp")))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-exp2-approx)) builder module arg-vals arg-types result-type)
  "op-exp2-approx: llvm.exp2 + afn (PTX f32/f16: native ex2.approx, probed). PTX f64 has no native
   lowering (llc: no libcall for fexp2), so it calls libdevice __nv_exp2."
  (declare (ignore arg-types))
  (multiple-value-bind (cat bits) (%hw-type-parts result-type)
    (declare (ignore cat))
    (if (and (eq *target-backend* :ptx) (= bits 64))
        (%hw-call builder module "__nv_exp2" (crisp-type-to-llvm-type result-type module) (list (first arg-vals)))
        (%hw-approx-flags (%hw-intrinsic builder module "exp2" result-type (first arg-vals))))))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-log2-approx)) builder module arg-vals arg-types result-type)
  "op-log2-approx: the fast-precision log2 callee (SPV native_log2, PTX __nv_fast_log2f) + afn."
  (declare (ignore arg-types))
  (%hw-approx-transcendental builder module (first arg-vals) result-type
                             "log2" "native_log2" "__nv_log2" "__nv_fast_log2"))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-sin-approx)) builder module arg-vals arg-types result-type)
  "op-sin-approx: PTX f32 native sin.approx; else the fast-precision sin callee; afn flag."
  (declare (ignore arg-types))
  (%hw-approx-transcendental builder module (first arg-vals) result-type
                             "sin" "native_sin" "__nv_sin" "__nv_fast_sin"))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-cos-approx)) builder module arg-vals arg-types result-type)
  "op-cos-approx: PTX f32 native cos.approx; else the fast-precision cos callee; afn flag."
  (declare (ignore arg-types))
  (%hw-approx-transcendental builder module (first arg-vals) result-type
                             "cos" "native_cos" "__nv_cos" "__nv_fast_cos"))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql 'op-sincos-approx)) builder module arg-vals arg-types result-type)
  "op-sincos-approx: both approximations, packed into the two-value aggregate a multi-value
   return uses (so `(let ((s c (op-sincos-approx x))) ...)` destructures it). RESULT-TYPE is the
   list (T T)."
  (let* ((x (first arg-vals))
         (x-type (first arg-types))
         (s (%hw-approx-transcendental builder module x x-type "sin" "native_sin" "__nv_sin" "__nv_fast_sin"))
         (c (%hw-approx-transcendental builder module x x-type "cos" "native_cos" "__nv_cos" "__nv_fast_cos"))
         (agg (llvm-get-undef (get-llvm-return-type module result-type))))
    (setf agg (llvm-build-insert-value builder agg s 0 "hw_sincos_0"))
    (llvm-build-insert-value builder agg c 1 "hw_sincos_1")))

;; src/codegen.lisp
(defmethod %hw-lower ((op (eql '%hw-sat-interior)) builder module arg-vals arg-types result-type)
  "Internal AD helper: 1.0 where integer R lies strictly inside its type's range, else 0.0, as
   RESULT-TYPE (float / floatN). Used as the gradient mask for op-imad-sat."
  (multiple-value-bind (cat bits lanes) (%hw-type-parts (first arg-types))
    (let* ((r (first arg-vals))
           (signed-p (eq cat :signed-int))
           (hi (if signed-p (1- (expt 2 (1- bits))) (1- (expt 2 bits))))
           (lo (if signed-p (- (expt 2 (1- bits))) 0))
           (above (llvm-build-icmp builder (if signed-p +llvm-int-sgt+ +llvm-int-ugt+)
                                   r (%hw-int-const builder bits lanes lo signed-p) "hw_above_min"))
           (below (llvm-build-icmp builder (if signed-p +llvm-int-slt+ +llvm-int-ult+)
                                   r (%hw-int-const builder bits lanes hi signed-p) "hw_below_max"))
           (inside (crisp.llvm-bindings::llvm-build-and builder above below "hw_interior")))
      (llvm-build-ui-to-fp builder inside (crisp-type-to-llvm-type result-type module) "hw_mask"))))

;;; --- autodiff --------------------------------------------------------------------------------

;; src/autodiff.lisp
(defun %hw-op-form-op (expr)
  "The endeavour-170 op symbol (public or internal) if EXPR is a hardware math op form, else NIL.
   Matched by symbol name, so it works whichever package the kernel's reader interned into."
  (and (consp expr) (car expr) (symbolp (car expr))
       (let ((name (symbol-name (car expr))))
         (or (find name *hw-op-symbols* :key #'symbol-name :test #'string=)
             (find name *hw-internal-op-symbols* :key #'symbol-name :test #'string=)))))

;; src/autodiff.lisp
(defun %hw-op-backward (v expr emit-fn local-adj-fn)
  "Backward rules for the endeavour-170 hardware math ops (v := EXPR). Each operand's adjoint
   accumulates d(op)/d(operand) * v_adj. Integer operands get promoted adjoints like any integer
   input. Kinks and ties use the conventions recorded in the endeavour doc (D7-D10). Returns T."
  (let ((op (%hw-op-form-op expr))
        (args (cdr expr))
        (g (funcall local-adj-fn v)))
    (flet ((acc (x term)
             (when (and x (symbolp x))
               (funcall emit-fn `(set! ,(funcall local-adj-fn x) (+ ,(funcall local-adj-fn x) ,term))))))
      (log:debug "%hw-op-backward: ~a := ~a" v expr)
      (destructuring-bind (a &optional b c) args
        (ecase op
          ((op-fma op-imad)
           (acc a `(* ,b ,g)) (acc b `(* ,a ,g)) (acc c g))
          (op-imad-sat
           (let ((mask `(%hw-sat-interior (op-imad-sat ,a ,b ,c))))
             (acc a `(* (* ,b ,g) ,mask)) (acc b `(* (* ,a ,g) ,mask)) (acc c `(* ,g ,mask))))
          (op-saturate
           ;; gradient 1 wherever the clamp is the identity (0 <= x <= 1, endpoints included), else 0
           (acc a `(* ,g (to-float (= (op-saturate ,a) ,a)))))
          ((op-abs-diff op-abs-diff-add)
           (let ((sign `(- (to-float (> ,a ,b)) (to-float (< ,a ,b)))))
             (acc a `(* ,sign ,g)) (acc b `(* (* -1.0 ,sign) ,g))
             (when (eq op 'op-abs-diff-add) (acc c g))))
          ((op-min3 op-max3)
           (let ((r `(,op ,a ,b ,c)))
             (acc a `(* (to-float (= ,a ,r)) ,g))
             (acc b `(* (to-float (* (= ,b ,r) (!= ,a ,r))) ,g))
             (acc c `(* (to-float (* (= ,c ,r) (* (!= ,a ,r) (!= ,b ,r)))) ,g))))
          (op-rsqrt-approx (acc a `(* (* -0.5 (pow ,a -1.5)) ,g)))
          (op-rcp-approx (acc a `(* (* -1.0 (/ 1.0 (* ,a ,a))) ,g)))
          (op-log2-approx (acc a `(* (/ 1.4426950408889634 ,a) ,g)))
          (op-exp2-approx (acc a `(* (* 0.6931471805599453 (pow 2.0 ,a)) ,g)))
          (op-sin-approx (acc a `(* (cos ,a) ,g)))
          (op-cos-approx (acc a `(* (* -1.0 (sin ,a)) ,g)))
          ((op-sad op-sincos-approx %hw-sat-interior)
           (error "~(~a~): no backward rule yet (endeavour 170 gap -- see the endeavour doc)." op)))))
    t))

;; src/autodiff.lisp  (fold: a clause near the top of %handle-single-value-backward's cond)
(defvar *hw-original-%handle-single-value-backward* (fdefinition '%handle-single-value-backward))
(progn
  (defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn &rest keys)
    "Generates backward-pass adjoint updates for a single ANF binding (see the src definition).
     Endeavour 170: hardware math op forms go to %hw-op-backward."
    (if (%hw-op-form-op expr)
        (%hw-op-backward v expr emit-fn local-adj-fn)
        (apply *hw-original-%handle-single-value-backward* v expr adjoint-map emit-fn local-adj-fn keys))))

;; src/autodiff.lisp  (fold: add the op names to the POW/ATAN2 union clause of %active-scalar-vars)
(defvar *hw-original-%active-scalar-vars* (fdefinition '%active-scalar-vars))
(progn
  (defun %active-scalar-vars (expr env)
    "Set of scalar symbols that differentiably affect EXPR (see the src definition). Endeavour 170:
     every operand of a hardware math op propagates."
    (if (%hw-op-form-op expr)
        (%asv-union (cdr expr) env)
        (funcall *hw-original-%active-scalar-vars* expr env))))

;;; ---------------------------------------------------------------------------------------------
;;; Endeavour 170, part 3: op-sincos-approx autodiff.
;;; A multi-value binding (S C (op-sincos-approx X)) reaches generate-backward-walk's multi-value
;;; clause, which only differentiates REGISTERED functions -- so the gradient was SILENTLY ZERO
;;; (put_temp_files_here/170-probe/sincos-ad.crisp: s_adj and c_adj accumulated, x_adj never did).
;;; The backward walk now sees the binding split into (S (op-sin-approx X)) and (C (op-cos-approx X)),
;;; which the per-op rules differentiate: dx = cos(x)*s_adj - sin(x)*c_adj.
;;; ---------------------------------------------------------------------------------------------

;; src/autodiff.lisp
(defun %hw-split-sincos-bindings (form)
  "Rewrite every multi-value binding (S C (op-sincos-approx X)) in FORM -- at any depth, since
   ANF leaves nested bodies (if / let / dotimes) inside the flat list -- into the two single
   bindings (S (op-sin-approx X)) and (C (op-cos-approx X)), spliced in its place. A form whose
   head is an operator (set!, let, ...) is never mistaken for a binding."
  (labels ((sincos-binding-p (f)
             (and (consp f) (= (length f) 3)
                  (symbolp (first f)) (symbolp (second f))
                  (first f) (second f)
                  (not (gethash (first f) *expression-analyzers*))
                  (not (member (symbol-name (first f)) '("SET!" "LET" "LET*" "IF" "WHEN" "UNLESS" "PROGN")
                               :test #'string=))
                  (consp (third f))
                  (eq (%hw-op-form-op (third f)) 'op-sincos-approx)))
           (walk-list (lst)
             (loop for f in lst
                   if (sincos-binding-p f)
                     append (let ((x (second (third f))))
                              (log:debug "%hw-split-sincos-bindings: ~a -> sin/cos bindings" f)
                              (list (list (first f) (list 'op-sin-approx x))
                                    (list (second f) (list 'op-cos-approx x))))
                   else collect (walk f)))
           (walk (f)
             (if (and (consp f) (null (cdr (last f))))   ; proper lists only
                 (walk-list f)
                 f)))
    (if (listp form) (walk-list form) form)))

;; src/autodiff.lisp  (fold: apply %hw-split-sincos-bindings to FLAT-ANF at the top of generate-backward-walk)
(defvar *hw-original-generate-backward-walk* (fdefinition 'generate-backward-walk))
(progn
  (defun generate-backward-walk (flat-anf inputs outputs input-types output-types &rest keys)
    "Walks an ANF body backwards to accumulate adjoints (see the src definition). Endeavour 170:
     op-sincos-approx multi-value bindings are split into sin / cos bindings first."
    (apply *hw-original-generate-backward-walk*
           (%hw-split-sincos-bindings flat-anf) inputs outputs input-types output-types keys)))

;;; ---------------------------------------------------------------------------------------------
;;; Endeavour 170, part 4 (decision D20, Chris 2026-09-16): the *-approx backward rules now evaluate
;;; the derivative with the APPROX ops instead of the exact functions. The derivative RULE is
;;; unchanged (d sin = cos); only its evaluation is approximate, matching the forward the user asked
;;; for. This removes a libdevice dependency on PTX: exact `cos` / `pow` are libdevice symbols there,
;;; so AD of an approx-trig kernel failed to compile without libdevice.10.bc linked
;;; (H100 run, 2026-09-16: 42-sincos-ad-cuda "backward compile failed", __nv_sinf unresolved).
;;; op-log2-approx keeps 1/(x ln2) -- plain division needs no library either way.
;;; ---------------------------------------------------------------------------------------------

;; src/autodiff.lisp  (REPLACES the part-2 %hw-op-backward)
(defun %hw-op-backward (v expr emit-fn local-adj-fn)
  "Backward rules for the endeavour-170 hardware math ops (v := EXPR). Each operand's adjoint
   accumulates d(op)/d(operand) * v_adj. Integer operands get promoted adjoints like any integer
   input. Kinks and ties use the conventions recorded in the endeavour doc (D7-D10); the *-approx
   derivatives are evaluated with the approx ops themselves (D20). Returns T."
  (let ((op (%hw-op-form-op expr))
        (args (cdr expr))
        (g (funcall local-adj-fn v)))
    (flet ((acc (x term)
             (when (and x (symbolp x))
               (funcall emit-fn `(set! ,(funcall local-adj-fn x) (+ ,(funcall local-adj-fn x) ,term))))))
      (log:debug "%hw-op-backward: ~a := ~a" v expr)
      (destructuring-bind (a &optional b c) args
        (ecase op
          ((op-fma op-imad)
           (acc a `(* ,b ,g)) (acc b `(* ,a ,g)) (acc c g))
          (op-imad-sat
           (let ((mask `(%hw-sat-interior (op-imad-sat ,a ,b ,c))))
             (acc a `(* (* ,b ,g) ,mask)) (acc b `(* (* ,a ,g) ,mask)) (acc c `(* ,g ,mask))))
          (op-saturate
           ;; gradient 1 wherever the clamp is the identity (0 <= x <= 1, endpoints included), else 0
           (acc a `(* ,g (to-float (= (op-saturate ,a) ,a)))))
          ((op-abs-diff op-abs-diff-add)
           (let ((sign `(- (to-float (> ,a ,b)) (to-float (< ,a ,b)))))
             (acc a `(* ,sign ,g)) (acc b `(* (* -1.0 ,sign) ,g))
             (when (eq op 'op-abs-diff-add) (acc c g))))
          ((op-min3 op-max3)
           (let ((r `(,op ,a ,b ,c)))
             (acc a `(* (to-float (= ,a ,r)) ,g))
             (acc b `(* (to-float (* (= ,b ,r) (!= ,a ,r))) ,g))
             (acc c `(* (to-float (* (= ,c ,r) (* (!= ,a ,r) (!= ,b ,r)))) ,g))))
          ;; d/dx x^-1/2 = -0.5 * x^-3/2 = -0.5 * rsqrt(x) / x
          (op-rsqrt-approx (acc a `(* (* -0.5 (/ (op-rsqrt-approx ,a) ,a)) ,g)))
          ;; d/dx 1/x = -(1/x)^2
          (op-rcp-approx (acc a `(* (* -1.0 (* (op-rcp-approx ,a) (op-rcp-approx ,a))) ,g)))
          ;; d/dx log2(x) = 1/(x ln2) -- division only, no library call on any target
          (op-log2-approx (acc a `(* (/ 1.4426950408889634 ,a) ,g)))
          ;; d/dx 2^x = ln2 * 2^x
          (op-exp2-approx (acc a `(* (* 0.6931471805599453 (op-exp2-approx ,a)) ,g)))
          (op-sin-approx (acc a `(* (op-cos-approx ,a) ,g)))
          (op-cos-approx (acc a `(* (* -1.0 (op-sin-approx ,a)) ,g)))
          ((op-sad op-sincos-approx %hw-sat-interior)
           (error "~(~a~): no backward rule yet (endeavour 170 gap -- see the endeavour doc)." op)))))
    t))
