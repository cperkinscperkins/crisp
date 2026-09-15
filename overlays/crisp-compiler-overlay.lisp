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
