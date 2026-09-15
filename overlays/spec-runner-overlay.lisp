;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)




;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 170 -- op-fma validators.
;;;; op-fma must lower to the GUARANTEED-fused @llvm.fma.<ty>, never the permissive
;;;; @llvm.fmuladd, in every precision context. Widened forms must fpext the multipliers
;;;; BEFORE the fma (no narrow-width multiply). These run on the --differentiate pass too, so
;;;; they only assert on things the backward kernel cannot disturb (plain fmul is legal there).
;;;; ---------------------------------------------------------------------------------------------

(defun %count-substring (needle haystack)
  "Number of non-overlapping occurrences of NEEDLE in HAYSTACK."
  (loop with start = 0
        for pos = (search needle haystack :start2 start)
        while pos
        count t
        do (setf start (+ pos (length needle)))))

(defun %validate-fma-ir (ir-string intrinsic &key fpext-from fpext-to)
  "Shared check for the op-fma validators. IR must contain a call to INTRINSIC (e.g.
   \"@llvm.fma.f32(\") and no llvm.fmuladd. When FPEXT-FROM/FPEXT-TO are given (widening),
   at least two `fpext FROM ... to TO` instructions must be present and there must be no
   `fmul FROM` (the product must not be rounded at the narrow width)."
  (let* ((ir (string-downcase ir-string))
         (has-fma (search (string-downcase intrinsic) ir))
         (has-muladd (search "fmuladd" ir))
         (fpext-count (if fpext-from
                          (loop for line in (uiop:split-string ir :separator '(#\Newline))
                                count (and (search (format nil "fpext ~a " fpext-from) line)
                                           (search (format nil " to ~a" fpext-to) line)))
                          0))
         (narrow-fmul (and fpext-from
                           (search (format nil "fmul ~a " fpext-from) ir))))
    (cond ((not has-fma)
           (format t "FAIL: no ~a call in IR (op-fma must emit the guaranteed-fused intrinsic)~%" intrinsic)
           nil)
          (has-muladd
           (format t "FAIL: llvm.fmuladd present (op-fma must emit llvm.fma, not the permissive fmuladd)~%")
           nil)
          ((and fpext-from (< fpext-count 2))
           (format t "FAIL: expected >=2 `fpext ~a .. to ~a` (widening a and b), found ~a~%"
                   fpext-from fpext-to fpext-count)
           nil)
          (narrow-fmul
           (format t "FAIL: `fmul ~a` present -- product rounded at the narrow width before widening~%"
                   fpext-from)
           nil)
          (t
           (format t "PASS (~a~@[, ~a fpext ~a->~a~])~%" intrinsic
                   (and fpext-from fpext-count) fpext-from fpext-to)
           t))))

(defun validate-fma-f32 (file ir-string)
  "Endeavour 170: op-fma on float lowers to @llvm.fma.f32, never llvm.fmuladd."
  (declare (ignore file))
  (%validate-fma-ir ir-string "@llvm.fma.f32("))

(defun validate-fma-f64 (file ir-string)
  "Endeavour 170: op-fma on double lowers to @llvm.fma.f64, never llvm.fmuladd."
  (declare (ignore file))
  (%validate-fma-ir ir-string "@llvm.fma.f64("))

(defun validate-fma-widen-half-float (file ir-string)
  "Endeavour 170: (op-fma half half float) fpexts both multipliers to float, then one
   @llvm.fma.f32. No half-width fmul."
  (declare (ignore file))
  (%validate-fma-ir ir-string "@llvm.fma.f32(" :fpext-from "half" :fpext-to "float"))

(defun validate-fma-widen-float-double (file ir-string)
  "Endeavour 170: (op-fma float float double) fpexts both multipliers to double, then one
   @llvm.fma.f64. No float-width fmul."
  (declare (ignore file))
  (%validate-fma-ir ir-string "@llvm.fma.f64(" :fpext-from "float" :fpext-to "double"))

(defun validate-fma-v4f32 (file ir-string)
  "Endeavour 170: op-fma on float4 lowers to ONE lane-wise @llvm.fma.v4f32 on <4 x float>."
  (declare (ignore file))
  (%validate-fma-ir ir-string "@llvm.fma.v4f32("))

;;;; ---------------------------------------------------------------------------------------------
;;;; BUG 060 (endeavour 170) -- float device-vector arithmetic must use the FP instructions.
;;;; ---------------------------------------------------------------------------------------------

(defun validate-float-dvec-arithmetic (file ir-string)
  "BUG 060: for each float device-vector LLVM type used by 054/29 (<4 x float>, <2 x double>,
   <3 x half>) the IR must contain fadd/fsub/fmul/fdiv on that type, and NO integer
   add/sub/mul/sdiv/udiv on it (those are invalid IR on a float vector)."
  (declare (ignore file))
  (let ((ir (string-downcase ir-string))
        (ok t))
    (dolist (vty '("<4 x float>" "<2 x double>" "<3 x half>"))
      (dolist (fop '("fadd" "fsub" "fmul" "fdiv"))
        (unless (search (format nil " ~a ~a " fop vty) ir)
          (format t "FAIL: missing `~a ~a`~%" fop vty)
          (setf ok nil)))
      (dolist (iop '("add" "sub" "mul" "sdiv" "udiv"))
        (when (search (format nil "= ~a ~a " iop vty) ir)
          (format t "FAIL: integer `~a ~a` emitted on a float vector (invalid IR)~%" iop vty)
          (setf ok nil))))
    (when ok (format t "PASS (FP instructions on float/double/half device vectors)~%"))
    ok))

;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 170 -- table-driven IR validators for specs 06-25 (hand-checked IR shapes).
;;;; Each asserts REQUIRED substrings are present and FORBIDDEN ones absent. They also run on the
;;;; --differentiate pass, so they only forbid what no backward kernel can legitimately contain.
;;;; ---------------------------------------------------------------------------------------------

(defun %validate-ir-substrings (ir-string required forbidden)
  "T when every REQUIRED substring occurs in IR-STRING and no FORBIDDEN one does; prints each miss."
  (let ((ok t))
    (dolist (r required)
      (unless (search r ir-string)
        (format t "FAIL: expected `~a` in IR~%" r)
        (setf ok nil)))
    (dolist (f forbidden)
      (when (search f ir-string)
        (format t "FAIL: `~a` must not appear in IR~%" f)
        (setf ok nil)))
    (when ok (format t "PASS (~a required substrings, ~a forbidden)~%" (length required) (length forbidden)))
    ok))

(defmacro def-hw-ir-validator (name doc &key require forbid)
  "Define validator NAME (file ir-string) checking REQUIRE / FORBID substrings via %validate-ir-substrings."
  `(defun ,name (file ir-string)
     ,doc
     (declare (ignore file))
     (%validate-ir-substrings ir-string ',require ',forbid)))

(def-hw-ir-validator validate-hw-06-saturate-float "170/06: op-saturate float = minnum(maxnum(x,0),1)."
  :require ("@llvm.maxnum.f32(" "@llvm.minnum.f32("))
(def-hw-ir-validator validate-hw-07-saturate-half "170/07: op-saturate half uses the f16 overloads."
  :require ("@llvm.maxnum.f16(" "@llvm.minnum.f16("))
(def-hw-ir-validator validate-hw-08-saturate-float4 "170/08: op-saturate float4 is lane-wise with a splat 1.0."
  :require ("@llvm.maxnum.v4f32(" "@llvm.minnum.v4f32(" "splat (float 1.000000e+00)"))
(def-hw-ir-validator validate-hw-09-imad-int "170/09: op-imad int = wrapping mul + add, no saturation."
  :require ("= mul i32 " "= add i32 ") :forbid ("add.sat"))
(def-hw-ir-validator validate-hw-10-imad-uint "170/10: op-imad uint = wrapping mul + add, no saturation."
  :require ("= mul i32 " "= add i32 ") :forbid ("add.sat"))
(def-hw-ir-validator validate-hw-11-imad-short-widen-int "170/11: short multipliers are sign-extended to int BEFORE the multiply."
  :require ("sext i16 " "= mul i32 ") :forbid ("= mul i16 "))
(def-hw-ir-validator validate-hw-12-imad-sat-int "170/12: exact product in i64, 64-bit saturating add, clamp to int, truncate."
  :require ("@llvm.sadd.sat.i64(" "@llvm.smin.i64(" "@llvm.smax.i64(" "trunc i64 "))
(def-hw-ir-validator validate-hw-13-imad-sat-short-widen-int "170/13: short*short into int needs only the 32-bit saturating add."
  :require ("@llvm.sadd.sat.i32(") :forbid ("@llvm.smin.i32(" "= mul i16 "))
(def-hw-ir-validator validate-hw-14-abs-diff-int "170/14: op-abs-diff int = smax - smin."
  :require ("@llvm.smax.i32(" "@llvm.smin.i32(" "= sub i32 "))
(def-hw-ir-validator validate-hw-15-abs-diff-uchar "170/15: op-abs-diff uchar = umax - umin."
  :require ("@llvm.umax.i8(" "@llvm.umin.i8("))
(def-hw-ir-validator validate-hw-16-abs-diff-add-char-widen-int "170/16: |a-b| at 8 bits, zero-extended to int."
  :require ("@llvm.smax.i8(" "zext i8 "))
(def-hw-ir-validator validate-hw-17-sad-uchar4-uint "170/17: lane-wise umax-umin, zext to <4 x i32>, lanes summed."
  :require ("@llvm.umax.v4i8(" "zext <4 x i8> " "extractelement <4 x i32>"))
(def-hw-ir-validator validate-hw-18-min3-max3-float "170/18: nested minnum / maxnum."
  :require ("@llvm.minnum.f32(" "@llvm.maxnum.f32("))
(def-hw-ir-validator validate-hw-19-min3-max3-int "170/19: signed and unsigned min/max intrinsics."
  :require ("@llvm.smin.i32(" "@llvm.smax.i32(" "@llvm.umin.i32(" "@llvm.umax.i32("))
(def-hw-ir-validator validate-hw-20-rsqrt-approx "170/20: 1/sqrt with afn on both instructions under ieee."
  :require ("call afn float @llvm.sqrt.f32(" "fdiv afn float 1.000000e+00"))
(def-hw-ir-validator validate-hw-21-rcp-approx "170/21: fdiv afn 1.0, x under ieee."
  :require ("fdiv afn float 1.000000e+00"))
(def-hw-ir-validator validate-hw-22-log2-approx "170/22: log2 with afn under ieee."
  :require ("call afn float @llvm.log2.f32("))
(def-hw-ir-validator validate-hw-23-exp2-approx "170/23: exp2 with afn under ieee."
  :require ("call afn float @llvm.exp2.f32("))
(def-hw-ir-validator validate-hw-24-sin-cos-approx "170/24: sin and cos with afn under ieee."
  :require ("call afn float @llvm.sin.f32(" "call afn float @llvm.cos.f32("))
(def-hw-ir-validator validate-hw-25-sincos-approx "170/25: sin + cos (afn) packed into a two-value aggregate."
  :require ("call afn float @llvm.sin.f32(" "call afn float @llvm.cos.f32(" "insertvalue { float, float }"))

;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 170 -- the precision pass must honor --differentiate in its TEST-WITH flags.
;;;; A TEST-WITH[--force-math-precision=ieee --differentiate] validator was handed FORWARD-only IR:
;;;; run-spec-precision-pass bound the precision/denormal specials but dropped --differentiate
;;;; (another instance of "flags in a TEST-WITH list are a promise", see run-single-spec-pass).
;;;; ---------------------------------------------------------------------------------------------

;; tests/run-specs.lisp  (REPLACES run-spec-precision-pass: adds the *compile-differentiate* binding)
(defun run-spec-precision-pass (file flags validator)
  "Compiles FILE with the precision + denormal flags active, then hands the LLVM IR
   to VALIDATOR. Used by TEST-WITH[--force-math-precision=KEY] / [--math-precision=KEY]
   / [--denormal-handling=KEY] (Endeavor 126). Modes are parsed from FLAGS and
   forwarded to the compiler via the *compile-* specials -> initialize-compiler.
   Endeavour 170: --differentiate in FLAGS is honored too, so the validator sees the backward."
  (handler-case
      (let* ((math   (%precision-flag-value flags "--math-precision="))
             (force  (%precision-flag-value flags "--force-math-precision="))
             (denorm (%denormal-mode-from-flags flags))
             (*compile-math-precision* (or math *compile-math-precision*))
             (*compile-force-math-precision* (or force *compile-force-math-precision*))
             (*compile-denormal-handling* (or denorm *compile-denormal-handling*))
             (*compile-differentiate* (or *compile-differentiate*
                                          (member "--differentiate" flags :test #'string=))))
      (let ((ir-string (compile-crisp-file-to-ir-string file)))
        (if validator
            (let ((sym (find-symbol (string-upcase (string validator)) :crisp.spec-runner)))
              (if (and sym (fboundp sym))
                  (if (funcall sym file ir-string)
                      (progn (format t "PASS~%") t)
                      (progn (format *error-output* "FAIL (Validator ~a)~%" validator) nil))
                  (progn (format *error-output* "FAIL (Validator ~a not found)~%" validator) nil)))
            (progn (format t "PASS~%") t))))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

;;;; Endeavour 170 -- backward-kernel IR validators for the INTEGER ops (32-34). VERIFY-AUTODIFF only
;;;; feeds float cells, so integer adjoints are checked in the IR: promoted (sitofp/uitofp) operands in
;;;; the chain-rule multiply, and the mask / sign comparisons.
(def-hw-ir-validator validate-hw-32-imad-ad "170/32: op-imad backward: da = to-float(b)*g, db = to-float(a)*g, dc = g."
  :require ("define void @k_grad" "sitofp i32 " "fmul float "))
(def-hw-ir-validator validate-hw-33-imad-sat-ad "170/33: op-imad-sat backward masks the gradient where the result clamped."
  :require ("define void @k_grad" "icmp sgt i32 " "icmp slt i32 " "uitofp i1 " "@llvm.sadd.sat.i64("))
(def-hw-ir-validator validate-hw-34-abs-diff-ad "170/34: op-abs-diff backward uses sign(a-b) from two comparisons."
  :require ("define void @k_grad" "icmp sgt i32 " "icmp slt i32 " "fsub float "))
