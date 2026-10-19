;; Endeavour 186 (contest fixes) -- the LLVM-IR claims for BUG 125: read-only loads carried through views.
;;
;; A spec's TEST-WITH validator sees only the shipped module, so the per-load claims live here: each spec
;; is compiled for the PTX backend and its loads are classified by whether they carry !invariant.load
;; (which NVPTX lowers to ld.global.nc).

(in-package :cl-user)

(defpackage :crisp.test.contest-fixes
  (:use :cl :parachute))

(in-package :crisp.test.contest-fixes)

(defun %186-compile-ptx-ir (spec)
  "LLVM IR (pre-opt) of tests/spec/186-contest-fixes/SPEC.crisp compiled for the PTX backend."
  (crisp.compiler:initialize-compiler :log-level :warn)
  (let* ((crisp.compiler:*target-backend* :ptx)
         (path (format nil "tests/spec/186-contest-fixes/~a.crisp" spec))
         (forms (let ((*package* (find-package :crisp-language)))
                  (with-open-file (s path)
                    (loop for f = (read s nil :eof) until (eq f :eof) collect f))))
         (module (crisp.llvm-bindings:llvm-module-create spec))
         (builder (crisp.llvm-bindings:llvm-create-builder)))
    (unwind-protect
         (progn
           (crisp.compiler:compile-module forms module builder nil nil nil)
           (let ((p (crisp.llvm-bindings:llvm-print-module-to-string module)))
             (unwind-protect (cffi:foreign-string-to-lisp p)
               (crisp.llvm-bindings:llvm-dispose-message p))))
      (crisp.llvm-bindings:llvm-dispose-builder builder)
      (crisp.llvm-bindings:llvm-dispose-module module))))

(defun %186-load-lines (needle ir)
  "The lines of IR that are loads whose text contains NEEDLE (e.g. \"load <4 x float>, ptr addrspace(1)\")."
  (with-input-from-string (s ir)
    (loop for line = (read-line s nil nil)
          while line
          when (search needle line) collect line)))

(defun %186-invariant-p (line)
  (and (search "!invariant.load" line) t))

(define-test contest-fixes-readonly-views

  ;; --- spec 03: float4 views of read-only inputs load invariant ----------------------------------
  ;; a4 is a view of A, b4 a view of the view bv of B: both read-only.  c4 (a view of the output C)
  ;; is the set! target -- its codegen also loads the element it overwrites (dead; -O removes it), and
  ;; that load of the OUTPUT must stay unmarked.  Before 186 none of the three carried the metadata.
  (let* ((ir    (%186-compile-ptx-ir "03-readonly-view-metal"))
         (loads (%186-load-lines "load <4 x float>, ptr addrspace(1)" ir)))
    (is = 3 (length loads)
        "Three float4 global loads: a4, b4, and the set! target c4.")
    (is = 2 (count-if #'%186-invariant-p loads)
        "The two loads of views of read-only inputs (a4, b4) -- and only those -- carry !invariant.load."))

  ;; --- spec 04: a let that shadows a read-only name takes it out of the set ------------------------
  ;; A is rebound to a workgroup scratch vector the kernel writes.  Its SLM load must not be marked;
  ;; B's global load, not shadowed, still is.
  (let* ((ir     (%186-compile-ptx-ir "04-readonly-name-shadowed"))
         (slm    (%186-load-lines "load float, ptr addrspace(3)" ir))
         (global (%186-load-lines "load float, ptr addrspace(1)" ir)))
    (true (plusp (length slm))    "The shadowing scratch A should be read from SLM.")
    (is = 0 (count-if #'%186-invariant-p slm)
        "A read of the shadowing scratch A must not carry !invariant.load.")
    ;; Two global loads: B's read, and the set! target C's (unmarked, it is the output).
    (is = 2 (length global) "Two global float loads: B's read and the set! target C.")
    (is = 1 (count-if #'%186-invariant-p global)
        "B's global read, outside any shadowing, still carries !invariant.load; C's does not.")))

;; GATING.  run-unit-tests reports a co-located .unit.lisp as PASS purely if it LOADS without error --
;; a quiet Parachute failure is invisible to CI -- so a failure is re-signalled as a load error.
(let* ((report   (test 'contest-fixes-readonly-views))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "CONTEST-FIXES-READONLY-VIEWS: ~d assertion~:p failed" (length failures))))
