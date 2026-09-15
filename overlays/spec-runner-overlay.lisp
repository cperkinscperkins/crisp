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
