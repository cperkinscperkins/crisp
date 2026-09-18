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

(test 'matrix-multiply-tile-stride-4-eva)
