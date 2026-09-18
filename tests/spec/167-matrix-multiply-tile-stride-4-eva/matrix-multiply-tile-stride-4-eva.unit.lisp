;; Endeavor 167 — matrix-multiply-tile-stride sections: front-end wiring unit test.
;;
;; Two things the E2E specs cannot show cheaply:
;;
;;   1. That the new grammar reaches codegen at all (the 135 unit test's job, repeated here
;;      for the :let shape on the generic pass, with no target and no GPU).
;;   2. That the SPLITTER itself is right.  The sections are found positionally, and a
;;      splitter that mis-assigns one form quietly moves code across the K loop -- a spec
;;      would then fail somewhere far from the cause, if at all.  Asserting the split
;;      directly is what localises that.
;;
;; The splitter is shared: all three %mmts-lower callers (the scratch analyzer in
;; analysis/control.lisp, the register pre-lowering in mma.lisp, the AD pre-pass in
;; autodiff.lisp) destructure through %mmts-parse, so one wrong split reaches all of them.

(in-package :cl-user)

(defpackage :crisp.test.matrix-multiply-tile-stride-4-eva
  (:use :cl :parachute))

(in-package :crisp.test.matrix-multiply-tile-stride-4-eva)

(define-test matrix-multiply-tile-stride-4-eva

  ;; --- 1. the :let shape compiles end-to-end on the generic pass -------------------
  (let ((file "tests/spec/167-matrix-multiply-tile-stride-4-eva/01-let-envelope.crisp"))
    (setf crisp.compiler::*function-table* (make-hash-table))
    (let ((ir (crisp.spec-runner::compile-crisp-file-to-ir-string file)))
      (true (and (stringp ir) (plusp (length ir)))
            ":let envelope kernel should compile to IR.")
      ;; Source is read in :crisp-language, so the kernel name interns there.
      (let* ((sigs (gethash (intern "MM_LET_ENVELOPE" :crisp-language)
                            crisp.compiler::*function-table*))
             (kernel-func (first sigs)))
        (true kernel-func
              "Kernel 'mm_let_envelope' should be registered after expansion."))))

  ;; --- 2. the splitter assigns each form to the right section ----------------------
  ;; A synthetic body standing in for the shape 05 uses: bindings, a warm-up, a three-form
  ;; reduction, a store.  Marker symbols are keywords, so they need no package care.
  (let ((body '(:let ((a-tile (make-scratch-matrix float (8 8)))
                      (c-tile (make-register-tile float (8 16) 0.0)))
                :prologue
                (prefetch-tile a 0)
                :body
                (load-tile a a-tile 0)
                (load-tile b b-tile 1)
                (mma-accumulate-via-tile (8 16 8) c-tile a-tile b-tile)
                :epilogue
                (store-tile c-tile c 0))))
    (multiple-value-bind (bindings prologue reduction epilogue)
        (crisp.compiler::%mmts-split-sections body)
      (is equal '((a-tile (make-scratch-matrix float (8 8)))
                  (c-tile (make-register-tile float (8 16) 0.0)))
          bindings
          ":let should yield the binding group verbatim.")
      (is equal '((prefetch-tile a 0)) prologue
          ":prologue should hold only the warm-up form.")
      (is = 3 (length reduction)
          ":body should hold exactly the three reduction forms.")
      (is equal '((store-tile c-tile c 0)) epilogue
          ":epilogue should hold only the store.")))

  ;; --- 3. the legacy shape still splits: unmarked body, trailing :epilogue ---------
  ;; This is what keeps the 41 pre-167 call sites compiling; see spec 08.
  (let ((body '((load-tile a a-tile 0)
                (mma-accumulate-via-tile (8 16 8) c-tile a-tile b-tile)
                :epilogue
                (store-tile c-tile c 0))))
    (multiple-value-bind (bindings prologue reduction epilogue)
        (crisp.compiler::%mmts-split-sections body)
      (true (null bindings) "legacy shape has no :let bindings.")
      (true (null prologue) "legacy shape has no :prologue.")
      (is = 2 (length reduction) "legacy unmarked body should be the reduction.")
      (is equal '((store-tile c-tile c 0)) epilogue
          "legacy :epilogue should still split off the trailing forms."))))

(defun %167-compile-bmg-ir (spec)
  "Compile SPEC (a 167 spec basename) for the bmg profile on the SPIR-V backend and return
   the LLVM IR as a string.

   WHY NOT A SPEC VALIDATOR.  A TEST-WITH validator on a target pass is handed the emitted
   MODULE PATH, and with --ir-target=spv that is a binary .spv -- the LLVM IR these claims
   are about is never written to disk.  In process the IR string is simply available."
  (crisp.compiler:initialize-compiler :log-level :warn :hardware-profile "bmg")
  (let* ((crisp.compiler:*target-backend* :spirv)
         (path (format nil "tests/spec/167-matrix-multiply-tile-stride-4-eva/~a.crisp" spec))
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

(defun %167-tally (needle text)
  "Number of non-overlapping occurrences of NEEDLE in TEXT."
  (let ((n 0) (start 0))
    (loop for pos = (search needle text :start2 start)
          while pos do (incf n) (setf start (+ pos (length needle))))
    n))

(define-test matrix-multiply-tile-stride-4-eva-ir

  ;; --- spec 04: a :let register accumulator is reset EXACTLY ONCE ------------------
  ;; Measured 2026-09-17: the binding already emits its zero CompositeConstruct in the
  ;; grid-x body, before the K loop -- the slot %mmts-lower would fill.  A second reset
  ;; would be correct, invisible to MMA_CORRECT, and pure cost, so it is asserted here.
  (let ((ir (%167-compile-bmg-ir "04-let-no-redundant-reset-bmg")))
    (is = 1 (%167-tally "@__spirv_CompositeConstruct_2_8_16(float 0.000000e+00)" ir)
        "A :let-bound register accumulator should be zero-initialised exactly once.")
    (is = 0 (%167-tally "store float 0.000000e+00" ir)
        "No scalar fill loop should be emitted for a register accumulator."))

  ;; --- spec 07: a :let SCRATCH accumulator gets the macro's fill + barrier ---------
  ;; make-scratch-matrix takes no init, so a scratch tile never self-resets wherever it is
  ;; bound.  Endeavour 167 made that the macro's job (pre-167 the reset was gated on
  ;; REGISTER-P and scratch got nothing).
  (let ((ir (%167-compile-bmg-ir "07-scratch-accumulator-reset-bmg")))
    (true (plusp (%167-tally "store float 0.000000e+00" ir))
          "A scratch accumulator should be filled by the macro.")
    (true (plusp (%167-tally "ControlBarrier" ir))
          "The scratch fill is workgroup-collective, so the macro supplies a barrier."))

  ;; --- spec 06: the reset precedes the :prologue -----------------------------------
  ;; This is what makes a bias-seeded matmul expressible.  It cannot be shown on metal --
  ;; the hoist reference is A*B scaled by an INTEGER MMA-SCALE, with no way to express an
  ;; additive seed -- and metal would show only the sum, never the sequence.
  (let* ((ir    (%167-compile-bmg-ir "06-reset-precedes-prologue-bmg"))
         (reset (search "@__spirv_CompositeConstruct_2_8_16(float 0.000000e+00)" ir))
         (seed  (search "@__spirv_CompositeConstruct_2_8_16(float 5.000000e+00)" ir))
         (mma   (search "@__spirv_CooperativeMatrixMulAddKHR" ir)))
    (true reset "The declared 0.0 init should be emitted.")
    (true seed  "The :prologue 5.0 seed should be emitted.")
    (true mma   "The MMA should be emitted.")
    (when (and reset seed mma)
      (true (< reset seed)
            "The reset must precede the :prologue seed, or the macro would clobber it.")
      (true (< seed mma)
            "The :prologue seed must precede the K-loop MMA."))))

;; GATING.  run-unit-tests in tests/run-specs.lisp reports a co-located .unit.lisp as PASS
;; purely if it LOADS without error -- a quiet Parachute (is ...) failure is invisible to CI.
;; So the report is inspected and a failure is re-signalled as a load error, which the runner
;; does catch.  Without this wrapper every assertion above could fail and the suite would
;; still be green.
(dolist (suite '(matrix-multiply-tile-stride-4-eva
                 matrix-multiply-tile-stride-4-eva-ir))
  (let* ((report   (test suite))
         (failures (parachute:results-with-status :failed report)))
    (when failures
      (error "~a: ~d assertion~:p failed" suite (length failures)))))
