;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-06 -- endeavour 208's tcgen05 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-04 -- endeavour 207's sync int8 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;; tests/run-specs.lisp  (new, Endeavour 210 item 6, beside validate-ptx-tma)
(defun validate-ptx-tma-grid-constant (file ptx-string)
  "Endeavour 210 (option B): every CUDA TMA descriptor is a BY-VALUE __grid_constant__ kernel
   parameter.  Checks, over the whole PTX:
     * at least one `.param .align 64 .b8 NAME[128]` (a 128-byte CUtensorMap by value);
     * each such NAME's address is taken with `mov.b64 %rdA, NAME;` and `cvta.param.u64 %rdB, %rdA;`
       -- the generic param-space address the TMA instructions and helper functions receive;
     * no `st.local.b8`: the signature of the lowering LLVM 21 gives a byval parameter WITHOUT the
       grid_constant annotation (a byte-by-byte copy into .local, whose address TMA cannot use);
     * no TMA descriptor still arriving as a `.ptr .global` parameter -- option A's shape -- which
       shows up as the kernel having fewer by-value maps than cp.async.bulk.tensor sources need
       is not checkable textually, so this only requires that SOME map exists and is used right."
  (declare (ignore file))
  (let* ((lines (uiop:split-string ptx-string :separator '(#\Newline)))
         (names (loop for l in lines
                      for p = (search ".param .align 64 .b8 " l)
                      when (and p (search "[128]" l))
                        collect (let* ((s (+ p (length ".param .align 64 .b8 ")))
                                       (e (search "[128]" l :start2 s)))
                                  (subseq l s e)))))
    (when (null names)
      (format *error-output* "FAIL: no 128-byte by-value (.param .align 64 .b8 X[128]) descriptor parameter~%")
      (return-from validate-ptx-tma-grid-constant nil))
    (dolist (nm names)
      (let* ((mov (find-if (lambda (l) (and (search "mov.b64" l)
                                             (search (format nil ", ~a;" nm) l)))
                           lines))
             (reg (and mov (let* ((s (position #\% mov)) (e (position #\, mov :start s)))
                             (subseq mov s e)))))
        (unless (and reg (find-if (lambda (l) (and (search "cvta.param.u64" l)
                                                    (search (format nil ", ~a;" reg) l)))
                                  lines))
          (format *error-output* "FAIL: descriptor ~a: no mov.b64 + cvta.param.u64 taking its address~%" nm)
          (return-from validate-ptx-tma-grid-constant nil))))
    (when (find-if (lambda (l) (search "st.local.b8" l)) lines)
      (format *error-output* "FAIL: st.local.b8 present -- a descriptor was copied to .local (no grid_constant)~%")
      (return-from validate-ptx-tma-grid-constant nil))
    (format t "PASS: ~d TMA descriptor(s) by value, address via cvta.param, no local copy~%" (length names))
    t))
