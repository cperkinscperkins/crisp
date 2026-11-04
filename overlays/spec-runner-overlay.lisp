;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;; tests/run-specs.lisp  (Endeavour 207 -- NVIDIA sync int8)
(defun %validate-ptx-sync-int8 (ptx-string want)
  "Shared body of the 207 sync int8 validators: the FULL m16n8k32 mnemonic WANT is present, no other
   m16n8k32 integer spelling is, and no float MMA survives in the module.  A prefix match would pass
   an unresolved NVVM call, which leaves an 'mma...m16n8k32' substring and emits no instruction."
  (let ((others (remove want '("mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32"
                               "mma.sync.aligned.m16n8k32.row.col.s32.u8.u8.s32"
                               "mma.sync.aligned.m16n8k32.row.col.s32.s8.u8.s32"
                               "mma.sync.aligned.m16n8k32.row.col.s32.u8.s8.s32")
                        :test #'string=)))
    (cond
      ((not (search want ptx-string))
       (format *error-output* "FAIL: sync int8 MMA absent -- expected ~s~%" want)
       nil)
      ((some (lambda (o) (search o ptx-string)) others)
       (format *error-output* "FAIL: a different int8 sign pairing is also present -- the operand signs did not reach the emitter~%")
       nil)
      ((or (search "tf32" ptx-string) (search ".f16.f16" ptx-string) (search ".bf16.bf16" ptx-string))
       (format *error-output* "FAIL: a float MMA survives alongside the int8 one~%")
       nil)
      (t t))))

;; tests/run-specs.lisp  (Endeavour 207)
(defun validate-ptx-int8-sync-mma (file ptx-string)
  "Endeavour 207: char x char -> int lowers to mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32."
  (declare (ignore file))
  (%validate-ptx-sync-int8 ptx-string "mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32"))

;; tests/run-specs.lisp  (Endeavour 207)
(defun validate-ptx-u8s8-sync-mma (file ptx-string)
  "Endeavour 207: uchar x char -> int lowers to mma.sync.aligned.m16n8k32.row.col.s32.u8.s8.s32 (the
   sign comes from the fragment RECORD name -- char and uchar are both LLVM i8)."
  (declare (ignore file))
  (%validate-ptx-sync-int8 ptx-string "mma.sync.aligned.m16n8k32.row.col.s32.u8.s8.s32"))
