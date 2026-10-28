;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-10-27 -- endeavour 195 folded into tests/run-specs.lisp (after validate-ptx-wait-checks-die-record):
;; %195-ptx-lines-with, %195-check-ptx-relaxed, validate-ptx-relaxed-load-store(-shared), validate-spv-relaxed-load-store.
;; EMPTY as of 2026-10-25 -- endeavour 193 folded into tests/run-specs.lisp: parse-hoist-flags + its clause in
;; run-spec-with-hoist; validate-has-die-check (replacing validate-has-llvm-trap), validate-ptx-wait-checks-die-record.

;; tests/run-specs.lisp -- Endeavour 196 (a), after validate-ptx-bf16-sync-mma.
(defun %196-validate-ptx-store-narrowed (ptx-string type-tag label)
  "Endeavour 196.  Two-sided check that an f32 MMA accumulator was stored NARROWED to a 16-bit
   matrix: a round-to-nearest convert to TYPE-TAG (\"f16\" / \"bf16\", scalar or packed x2) is
   present, the global stores are 16-bit (st.global.b16, or b32 when the packed form is used), and
   NO f32 global store survives -- an f32 store into a half matrix writes 4-byte elements at
   2-byte strides, which small-size numbers can miss.  Any other rounding mode on the convert
   fails too: the exact match against cuBLAS on GPU MODE depends on round-to-nearest-even."
  (flet ((n-of (needle)
           (loop with start = 0
                 for pos = (search needle ptx-string :start2 start)
                 while pos
                 count t
                 do (setf start (1+ pos)))))
  (let* ((scalar   (format nil "cvt.rn.~a.f32" type-tag))
         (packed   (format nil "cvt.rn.~ax2.f32" type-tag))
         (n-scalar (n-of scalar))
         (n-packed (n-of packed))
         (n-st16   (n-of "st.global.b16"))
         (n-st32b  (n-of "st.global.b32"))
         (f32-st   (plusp (+ (n-of "st.global.f32") (n-of "st.global.v2.f32") (n-of "st.global.v4.f32"))))
         (bad-rnd  (loop for rnd in '("rz" "rm" "rp" "rna")
                         thereis (plusp (+ (n-of (format nil "cvt.~a.~a.f32" rnd type-tag))
                                           (n-of (format nil "cvt.~a.~ax2.f32" rnd type-tag)))))))
    (cond
      ((zerop (+ n-scalar n-packed))
       (format *error-output* "FAIL: ~a store: no ~s (or ~s) -- the accumulator was not converted~%"
               label scalar packed)
       nil)
      (bad-rnd
       (format *error-output* "FAIL: ~a store: a non-round-to-nearest ~a convert is present~%" label type-tag)
       nil)
      (f32-st
       (format *error-output* "FAIL: ~a store: an f32 global store survives -- some element was stored unconverted~%" label)
       nil)
      ((and (zerop n-st16) (or (zerop n-packed) (zerop n-st32b)))
       (format *error-output* "FAIL: ~a store: no 16-bit global store (st.global.b16, or b32 after a packed convert)~%" label)
       nil)
      (t t)))))

;; tests/run-specs.lisp -- Endeavour 196 (a).
(defun validate-ptx-store-to-half (file ptx-string)
  "Endeavour 196: (store-tile (to-half D) C ...) -- f32 accumulator stored as fp16.  See
   %196-validate-ptx-store-narrowed."
  (declare (ignore file))
  (%196-validate-ptx-store-narrowed ptx-string "f16" "to-half"))

;; tests/run-specs.lisp -- Endeavour 196 (a).
(defun validate-ptx-store-to-bfloat16 (file ptx-string)
  "Endeavour 196: (store-tile (to-bfloat16 D) C ...) -- f32 accumulator stored as bf16.  See
   %196-validate-ptx-store-narrowed."
  (declare (ignore file))
  (%196-validate-ptx-store-narrowed ptx-string "bf16" "to-bfloat16"))

;; tests/run-specs.lisp -- Endeavour 196 (b), after validate-ptx-store-to-bfloat16.
(defun validate-ptx-cp-async-16 (file ptx-string)
  "Endeavour 196 (b): the Ampere cp.async load-tile of a HALF tile.  Two-sided: a 16-byte cp.async
   (`cp.async.ca.shared.global [..], [..], 16;`) is present -- the chunked copy, the only cp.async a
   2-byte element can use -- AND the fp16 m16n8k16 MMA is present, so the staged tile reached the tensor
   cores as half."
  (declare (ignore file))
  (let ((has16 (loop with start = 0
                     for pos = (search "cp.async.ca.shared.global" ptx-string :start2 start)
                     while pos
                     thereis (let ((semi (position #\; ptx-string :start pos)))
                               (and semi (search ", 16" ptx-string :start2 pos :end2 semi)))
                     do (setf start (1+ pos))))
        (mma (search "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" ptx-string)))
    (cond
      ((not has16)
       (format *error-output* "FAIL: no 16-byte cp.async -- the half tile was not copied in chunks~%")
       nil)
      ((not mma)
       (format *error-output* "FAIL: 16-byte cp.async present but no fp16 m16n8k16 MMA~%")
       nil)
      (t t))))

;; tests/run-specs.lisp -- Endeavour 196, after validate-ptx-cp-async-16.
(defun validate-ptx-cp-async-wait-then-barrier (file ptx-string)
  "Endeavour 196 (D-196-11): every `cp.async.wait_group` is immediately followed by a CTA barrier
   (`bar.sync` / `barrier.sync`), so no thread reads a tile chunk another thread is still copying."
  (declare (ignore file))
  (let ((lines (remove-if (lambda (l) (or (zerop (length (string-trim '(#\Space #\Tab #\Return) l)))
                                          (search "//" (string-trim '(#\Space #\Tab) l) :end2 (min 2 (length (string-trim '(#\Space #\Tab) l))))))
                          (uiop:split-string ptx-string :separator '(#\Newline))))
        (waits 0) (bad 0))
    (loop for (l next) on lines
          when (search "cp.async.wait_group" l)
            do (incf waits)
               (unless (and next (or (search "bar.sync" next) (search "barrier.sync" next)))
                 (incf bad)))
    (cond
      ((zerop waits)
       (format *error-output* "FAIL: no cp.async.wait_group at all~%") nil)
      ((plusp bad)
       (format *error-output* "FAIL: ~a of ~a cp.async.wait_group not followed by a CTA barrier~%" bad waits) nil)
      (t t))))

;; tests/run-specs.lisp -- Endeavour 197.
(defun %197-validate-ptx-store-packed (ptx-string packed-needles scalar-needle label)
  "Endeavour 197.  An MMA accumulator store that PACKS its column pairs: at least one of
   PACKED-NEEDLES (the pair store) is present AND SCALAR-NEEDLE (the per-element store) is still
   present -- the fallback branch under the %pair-ok-p guard.  A kernel with only packed stores has
   lost its guard; one with only scalar stores did not pack."
  (flet ((n-of (needle)
           (loop with start = 0
                 for pos = (search needle ptx-string :start2 start)
                 while pos
                 count t
                 do (setf start (1+ pos)))))
    (let ((n-packed (loop for p in packed-needles sum (n-of p)))
          (n-scalar (n-of scalar-needle)))
      (log:info "197 ~a: packed=~a scalar=~a" label n-packed n-scalar)
      (cond
        ((zerop n-packed)
         (format *error-output* "FAIL: ~a: no packed pair store (~{~a~^ / ~})~%" label packed-needles) nil)
        ((zerop n-scalar)
         (format *error-output* "FAIL: ~a: no scalar ~a -- the unaligned fallback is gone~%" label scalar-needle) nil)
        (t t)))))

;; tests/run-specs.lisp -- Endeavour 197.
(defun validate-ptx-store-packed-half (file ptx-string)
  "Endeavour 197: f32 accumulator -> half matrix, stored as 4-byte pairs, still converted
   round-to-nearest with no f32 store (the 196 checks)."
  (declare (ignore file))
  (and (%196-validate-ptx-store-narrowed ptx-string "f16" "to-half")
       (%197-validate-ptx-store-packed ptx-string '("st.global.v2.b16" "st.global.b32") "st.global.b16"
                                       "packed half")))

;; tests/run-specs.lisp -- Endeavour 197.
(defun validate-ptx-store-packed-bfloat16 (file ptx-string)
  "Endeavour 197: the bf16 twin of validate-ptx-store-packed-half."
  (declare (ignore file))
  (and (%196-validate-ptx-store-narrowed ptx-string "bf16" "to-bfloat16")
       (%197-validate-ptx-store-packed ptx-string '("st.global.v2.b16" "st.global.b32") "st.global.b16"
                                       "packed bfloat16")))

;; tests/run-specs.lisp -- Endeavour 197.
(defun validate-ptx-store-packed-float (file ptx-string)
  "Endeavour 197: f32 accumulator -> float matrix, stored as st.global.v2.f32 pairs."
  (declare (ignore file))
  (%197-validate-ptx-store-packed ptx-string '("st.global.v2.f32") "st.global.f32" "packed float"))

;; tests/run-specs.lisp -- Endeavour 197 (supersedes the copy above: SCALAR-NEEDLES is a list, since
;; NVPTX prints a float store bit-typed -- st.global.b32 / st.global.v2.b32, not .f32).
(defun %197-validate-ptx-store-packed (ptx-string packed-needles scalar-needles label)
  "Endeavour 197.  An MMA accumulator store that PACKS its column pairs: at least one of
   PACKED-NEEDLES (the pair store) is present AND one of SCALAR-NEEDLES (the per-element store) is
   still present -- the fallback branch under the %pair-ok-p guard.  A kernel with only packed
   stores has lost its guard; one with only scalar stores did not pack."
  (flet ((n-of (needle)
           (loop with start = 0
                 for pos = (search needle ptx-string :start2 start)
                 while pos
                 count t
                 do (setf start (1+ pos)))))
    (let ((n-packed (loop for p in packed-needles sum (n-of p)))
          (n-scalar (loop for s in (if (listp scalar-needles) scalar-needles (list scalar-needles))
                          sum (n-of s))))
      (log:info "197 ~a: packed=~a scalar=~a" label n-packed n-scalar)
      (cond
        ((zerop n-packed)
         (format *error-output* "FAIL: ~a: no packed pair store (~{~a~^ / ~})~%" label packed-needles) nil)
        ((zerop n-scalar)
         (format *error-output* "FAIL: ~a: no scalar store -- the unaligned fallback is gone~%" label) nil)
        (t t)))))

;; tests/run-specs.lisp -- Endeavour 197 (supersedes the copy above).
(defun validate-ptx-store-packed-float (file ptx-string)
  "Endeavour 197: f32 accumulator -> float matrix, stored as 8-byte pairs (st.global.v2.b32, which
   NVPTX prints for <2 x float>; .v2.f32 accepted too) with the scalar fallback still present."
  (declare (ignore file))
  (%197-validate-ptx-store-packed ptx-string '("st.global.v2.b32" "st.global.v2.f32")
                                  '("st.global.b32" "st.global.f32") "packed float"))
